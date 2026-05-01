class_name PlayerRegistry
extends Node
## Central directory of every PlayerState in the current match plus the
## ResourceManager wired up for each. Kept as a scene-level Node so any
## system can do `get_tree().current_scene.get_node_or_null("PlayerRegistry")`
## and ask "who's allied to player X?" or "where do player Y's resources live?"
## without each subsystem rebuilding that knowledge.
##
## Convention for the v1 → v2 transition: the existing nodes named
## `ResourceManager` (player) and `AIResourceManager` (AI) are still where
## the resource numbers live; the registry just *records* which player_id
## each maps to so callers can stop hardcoding string lookups.

const NEUTRAL_PLAYER_ID: int = 2
const NEUTRAL_TEAM_ID: int = 2

## Perspective categories for the local player. The minimap, selection
## rings, and any other "this is mine / theirs / friend / hostile" UI
## reads from this enum so the color rule lives in one place.
enum Relation { SELF, ALLY, ENEMY, NEUTRAL }

## Default tints used when a state-specific override hasn't been set.
## Self uses the local player's `player_color`; ally / enemy / neutral
## are perspective colors picked to read at a glance regardless of what
## faction shows underneath.
const COLOR_ALLY: Color = Color(0.3, 0.85, 0.4, 1.0)        # green
const COLOR_ENEMY: Color = Color(0.85, 0.2, 0.15, 1.0)      # red
const COLOR_NEUTRAL: Color = Color(0.85, 0.7, 0.3, 1.0)     # amber
const COLOR_SELF_FALLBACK: Color = Color(0.10, 0.32, 1.0, 1.0)  # saturated royal blue (away from Sable cyan)

## Whose perspective drives `get_relation` / `get_perspective_color`. For
## now this is the local human player; observer / split-screen modes can
## reassign at runtime.
@export var local_player_id: int = 0

signal player_eliminated(player_id: int)

var _players_by_id: Dictionary = {}        # int -> PlayerState
var _resource_mgr_by_id: Dictionary = {}   # int -> Node (ResourceManager)
## Cache for `are_allied` results keyed on the encoded (a_id, b_id) pair.
## Hostility is fixed for the whole match (no team-switching), so once a
## pair is resolved we can hand back the cached bool. Profiling showed
## these getters being called 3000-7000 times per frame at high unit
## counts; the dict lookup is far cheaper than the `get_state` chain it
## avoids.
var _allied_cache: Dictionary = {}


func register(state: PlayerState, resource_manager: Node = null) -> void:
	if not state:
		return
	_players_by_id[state.player_id] = state
	if resource_manager:
		_resource_mgr_by_id[state.player_id] = resource_manager


func get_state(player_id: int) -> PlayerState:
	return _players_by_id.get(player_id, null) as PlayerState


func get_resource_manager(player_id: int) -> Node:
	return _resource_mgr_by_id.get(player_id, null) as Node


func get_team(player_id: int) -> int:
	# Neutrals fall back to the dedicated neutral team rather than -1 so the
	# "are these two on the same team?" check has a single shape everywhere.
	var s: PlayerState = get_state(player_id)
	if s:
		return s.team_id
	return NEUTRAL_TEAM_ID


func are_allied(a_id: int, b_id: int) -> bool:
	# Same-player counts as allied (so a unit doesn't "fight itself" in any
	# accidental self-targeting case), and neutrals are *not* allied with
	# anyone — they're a separate team that engages everything.
	if a_id == b_id:
		return true
	# Encode the unordered pair as a single int — small player ids fit
	# easily into the lower / upper halves of a 32-bit value. Symmetric
	# under swap so (a,b) and (b,a) hit the same cache slot.
	var lo: int = a_id if a_id < b_id else b_id
	var hi: int = b_id if a_id < b_id else a_id
	var key: int = (hi << 16) | (lo & 0xFFFF)
	if _allied_cache.has(key):
		return _allied_cache[key] as bool
	var ta: int = get_team(a_id)
	var tb: int = get_team(b_id)
	var result: bool
	if ta == NEUTRAL_TEAM_ID or tb == NEUTRAL_TEAM_ID:
		result = false
	else:
		result = ta == tb
	_allied_cache[key] = result
	return result


func are_enemies(a_id: int, b_id: int) -> bool:
	# "Not allied" rather than "different team" so a player and a neutral
	# are correctly treated as enemies (they share no team, but neutrals
	# explicitly engage non-neutrals).
	return not are_allied(a_id, b_id)


func get_relation(other_player_id: int) -> int:
	if other_player_id == local_player_id:
		return Relation.SELF
	if get_team(other_player_id) == NEUTRAL_TEAM_ID:
		return Relation.NEUTRAL
	if are_allied(local_player_id, other_player_id):
		return Relation.ALLY
	return Relation.ENEMY


func get_perspective_color(other_player_id: int) -> Color:
	## Returns the on-screen color that "other_player_id" should appear
	## as from the local player's point of view: own player_color for
	## SELF, green for ALLY, red for ENEMY, amber for NEUTRAL. Centralizes
	## the rule so minimap / selection ring / banner code doesn't each
	## invent its own version.
	match get_relation(other_player_id):
		Relation.SELF:
			var s: PlayerState = get_state(local_player_id)
			return s.player_color if s else COLOR_SELF_FALLBACK
		Relation.ALLY:
			return COLOR_ALLY
		Relation.NEUTRAL:
			return COLOR_NEUTRAL
		_:
			return COLOR_ENEMY


func mark_eliminated(player_id: int) -> void:
	var s: PlayerState = get_state(player_id)
	if not s or not s.is_alive:
		return
	s.is_alive = false
	player_eliminated.emit(player_id)


func get_all_player_ids() -> Array[int]:
	var ids: Array[int] = []
	for k: Variant in _players_by_id.keys():
		ids.append(k as int)
	return ids


## Resource gifting (v2 §"Pillar 3" — Resource gifting). Salvage and fuel
## can be transferred between teammates; power is infrastructure-bound and
## intentionally non-transferable per the design.
func transfer_resources(from_id: int, to_id: int, salvage: int, fuel: int) -> bool:
	if from_id == to_id:
		return false
	if not are_allied(from_id, to_id):
		return false
	var src: Node = get_resource_manager(from_id)
	var dst: Node = get_resource_manager(to_id)
	if not src or not dst:
		return false
	salvage = maxi(salvage, 0)
	fuel = maxi(fuel, 0)
	if salvage == 0 and fuel == 0:
		return false
	if not src.has_method("can_afford") or not src.can_afford(salvage, fuel):
		return false
	if src.has_method("spend"):
		src.spend(salvage, fuel)
	if salvage > 0 and dst.has_method("add_salvage"):
		dst.add_salvage(salvage)
	if fuel > 0 and dst.has_method("add_fuel"):
		dst.add_fuel(fuel)
	return true
