class_name AIController
extends Node
## AI opponent with varied behavior: builds economy, mixed army, defends and attacks.

enum AIState { SETUP, ECONOMY, ARMY, ATTACK, REBUILD }

@export var owner_id: int = 1

var _state: AIState = AIState.SETUP
var _state_timer: float = 0.0
var _wave_count: int = 0

var _hq: Node = null
var _foundry: Node = null
var _adv_foundry: Node = null
var _generator: Node = null
var _generator2: Node = null
var _salvage_yard: Node = null
var _turret: Node = null
var _units: Array[Node] = []

var _player_hq_pos: Vector3 = Vector3.ZERO
var _ai_resource_manager: Node = null
var _hq_destroyed: bool = false

## Building placement tracking — each placed once.
var _buildings_placed: Dictionary = {}

const AI_SALVAGE_TRICKLE: float = 15.0
const ECONOMY_DURATION: float = 40.0
## Bumped 35 → 90 so the AI actually masses up before attacking. The old
## 35s fallback let the timer trip before INITIAL_WAVE_SIZE was hit, and
## the AI then attacked with whatever 2-3 stragglers it had — effectively
## drip-feeding single units into the meat grinder. With 90s the AI
## almost always reaches the wave size first; the timer is just a "stuck
## anyway" safety net.
const ARMY_DURATION: float = 90.0
const REBUILD_DURATION: float = 20.0
## Bumped from 4 to 7 — the v2 1v1 map has neutral patrols sitting on
## every deposit lane, and a 4-unit wave reliably gets ground down by
## one Hound + one Bulwark before reaching the player. 7 gives the AI
## enough mass to actually push through and start hitting structures.
const INITIAL_WAVE_SIZE: int = 7
const DEFENDERS: int = 2

## Forward-yard expansion: every EXPANSION_INTERVAL seconds the AI looks
## for a wreck-rich, enemy-free spot far from its existing economy and
## drops a Salvage Yard there. This is what lets the AI actually claim
## map territory instead of building 3-4 buildings near home and freezing.
const EXPANSION_INTERVAL: float = 35.0
## Minimum distance a new yard has to be from any existing friendly yard
## or Crawler. Prevents the AI from stacking yards on top of each other.
const EXPANSION_MIN_FRIENDLY_DIST: float = 38.0
## How close an enemy unit can be before the AI considers an expansion
## site too dangerous and skips it.
const EXPANSION_MAX_ENEMY_DIST: float = 25.0
var _expansion_timer: float = 0.0

var _salvage_accumulator: float = 0.0

## Cached difficulty multipliers from the MatchSettings autoload (defaults to
## Normal if the autoload isn't present, e.g. when running the test arena
## scene directly from the editor).
var _econ_mul: float = 1.0
var _agg_mul: float = 1.0


func _enter_tree() -> void:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings:
		_econ_mul = settings.get_ai_economy_multiplier()
		_agg_mul = settings.get_ai_aggression_multiplier()


func _ready() -> void:
	call_deferred("_setup")


func _setup() -> void:
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if node.get("owner_id") == owner_id:
			if node.get("stats") and node.get("stats").get("building_id") == &"headquarters":
				_hq = node
				break

	# Find the nearest enemy HQ to attack-move toward. In 1v1 that's the
	# player; in 2v2 it's whichever enemy team's HQ is closer to ours so
	# the AI doesn't traipse across the entire map past a closer target.
	_player_hq_pos = _find_nearest_enemy_hq_pos(buildings)

	# Resource manager: prefer the registry lookup (works regardless of
	# how many AIs are in the scene) and fall back to the legacy node-name
	# convention for headless/test scenes.
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("get_resource_manager"):
		_ai_resource_manager = registry.get_resource_manager(owner_id)
	if not _ai_resource_manager:
		_ai_resource_manager = get_parent().get_node_or_null("AIResourceManager")

	# Transition out of SETUP into ECONOMY now that we have a HQ. Without
	# this, the state machine sits in SETUP forever and `_process`'s
	# match block has no case for SETUP — so the AI does literally
	# nothing. (Regression caught after a refactor briefly orphaned this
	# block outside `_setup`.)
	if _hq:
		_state = AIState.ECONOMY
		_state_timer = 0.0


func _find_nearest_enemy_hq_pos(buildings: Array[Node]) -> Vector3:
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	var origin: Vector3 = (_hq.global_position if _hq else Vector3.ZERO)
	var best_pos: Vector3 = origin
	var best_dist: float = INF
	for node: Node in buildings:
		var node_owner: int = node.get("owner_id") as int
		var hostile: bool = (
			registry.are_enemies(owner_id, node_owner)
			if registry and registry.has_method("are_enemies")
			else node_owner != owner_id
		)
		if not hostile:
			continue
		var stats: Variant = node.get("stats")
		if not stats or stats.get("building_id") != &"headquarters":
			continue
		var pos: Vector3 = (node as Node3D).global_position
		var d: float = origin.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best_pos = pos
	return best_pos


func _process(delta: float) -> void:
	if _hq_destroyed:
		return
	if not _hq or not is_instance_valid(_hq):
		_hq_destroyed = true
		return

	# Passive income — scaled by difficulty's economy multiplier so Easy
	# starves the AI a bit and Hard makes it tech up faster.
	if _ai_resource_manager and _ai_resource_manager.has_method("add_salvage"):
		_salvage_accumulator += AI_SALVAGE_TRICKLE * _econ_mul * delta
		if _salvage_accumulator >= 1.0:
			var trickle: int = int(_salvage_accumulator)
			_salvage_accumulator -= float(trickle)
			_ai_resource_manager.add_salvage(trickle)
			# Also give some fuel
			if _ai_resource_manager.has_method("add_fuel"):
				_ai_resource_manager.add_fuel(max(trickle / 3, 1))

	# Update unit list
	_units.clear()
	var all_nodes: Array[Node] = get_tree().get_nodes_in_group("owner_%d" % owner_id)
	for node: Node in all_nodes:
		if node.is_in_group("units") and is_instance_valid(node):
			if "alive_count" in node and node.get("alive_count") > 0:
				_units.append(node)

	_state_timer += delta

	# Forward-yard expansion ticks across all states except REBUILD (when
	# the AI's been wiped and is reconstituting). Drops one new yard per
	# interval, far from existing infrastructure, in safe territory.
	if _state != AIState.REBUILD:
		_expansion_timer += delta
		if _expansion_timer >= EXPANSION_INTERVAL:
			_expansion_timer = 0.0
			_try_expansion_yard()

	match _state:
		AIState.ECONOMY:
			_process_economy()
		AIState.ARMY:
			_process_army()
		AIState.ATTACK:
			_process_attack()
		AIState.REBUILD:
			_process_rebuild()


func _process_economy() -> void:
	# Replenish engineers if we're running low — they're built at the HQ.
	_maintain_engineers()
	# Queue and pilot a Crawler.
	_maintain_crawlers()

	# Phase 1: Basic buildings — offsets pushed out so the AI base lays
	# out as a real footprint with units able to thread between
	# buildings instead of getting wedged against tight 5u clearances.
	_try_place("generator", "res://resources/buildings/basic_generator.tres", Vector3(9, 0, 6))
	_try_place("foundry", "res://resources/buildings/basic_foundry.tres", Vector3(-9, 0, 6))
	_try_place("salvage_yard", "res://resources/buildings/salvage_yard.tres", Vector3(0, 0, 13))

	# Phase 2: After first wave, build advanced structures
	if _wave_count >= 1:
		_try_place("generator2", "res://resources/buildings/basic_generator.tres", Vector3(13, 0, 13))
		_try_place("turret", "res://resources/buildings/gun_emplacement.tres", Vector3(0, 0, -9))

	if _wave_count >= 2:
		_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", Vector3(-13, 0, 13))

	if _state_timer >= ECONOMY_DURATION:
		_state = AIState.ARMY
		_state_timer = 0.0


func _process_army() -> void:
	# Maintain economy in parallel with army production — engineers + Crawler
	# keep working through the army-build state.
	_maintain_engineers()
	_maintain_crawlers()
	# Queue at basic foundry (validate not destroyed)
	if is_instance_valid(_foundry):
		_try_queue_at(_foundry)

	# Queue at advanced foundry if available
	if _wave_count >= 2 and is_instance_valid(_adv_foundry):
		_try_queue_at(_adv_foundry)

	# Wave size scales with the aggression multiplier — Hard sends bigger
	# pushes, Easy sends fewer units before attacking.
	var base_wave: float = float(INITIAL_WAVE_SIZE + _wave_count * 2) * _agg_mul
	var wave_size: int = maxi(int(round(base_wave)), 2)
	if _units.size() >= wave_size or _state_timer >= ARMY_DURATION / _agg_mul:
		_state = AIState.ATTACK
		_state_timer = 0.0


func _process_attack() -> void:
	# Keep economy + Crawler logistics ticking even mid-attack — without
	# this the Crawler stops getting relocate orders once the AI commits
	# to a push and just sits idle next to its HQ for the rest of the
	# match.
	_maintain_engineers()
	_maintain_crawlers()
	if is_instance_valid(_foundry):
		_try_queue_at(_foundry)
	if _wave_count >= 2 and is_instance_valid(_adv_foundry):
		_try_queue_at(_adv_foundry)

	# Refresh the target HQ each wave — in 2v2 one enemy might have fallen
	# already, in which case we want to attack-move toward whoever's left
	# instead of an empty rubble pile.
	var fresh_hq: Vector3 = _find_nearest_enemy_hq_pos(get_tree().get_nodes_in_group("buildings"))
	if fresh_hq != Vector3.ZERO or _player_hq_pos == Vector3.ZERO:
		_player_hq_pos = fresh_hq

	# Keep some units near base as defenders
	var attack_units: Array[Node] = []
	var defender_count: int = 0

	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		# Engineers stay home — they need to keep building, not march on the
		# enemy. Same rule the player follows by intuition.
		if node.has_method("get_builder") and node.get_builder():
			continue
		if defender_count < DEFENDERS:
			# Keep defenders near HQ
			var dist_to_hq: float = node.global_position.distance_to(_hq.global_position)
			if dist_to_hq < 25.0:
				defender_count += 1
				continue
		attack_units.append(node)

	# Send attackers toward the chosen enemy HQ
	for node: Node in attack_units:
		if not is_instance_valid(node):
			continue
		var combat: Node = node.get_node_or_null("CombatComponent")
		if combat and combat.has_method("command_attack_move"):
			if combat.get("attack_move_target") == Vector3.INF:
				combat.command_attack_move(_player_hq_pos)

	# If most attackers are dead, rebuild
	if attack_units.size() <= 1:
		_wave_count += 1
		_state = AIState.REBUILD
		_state_timer = 0.0


func _process_rebuild() -> void:
	if _state_timer >= REBUILD_DURATION:
		_state = AIState.ECONOMY
		_state_timer = 0.0


func _try_place(key: String, stats_path: String, offset: Vector3) -> void:
	if _buildings_placed.has(key):
		return
	var bstats: BuildingStatResource = load(stats_path) as BuildingStatResource
	if not bstats:
		return
	# AI must afford the building, just like the player. _ai_resource_manager
	# handles the spending inside builder.place_building.
	if _ai_resource_manager and _ai_resource_manager.has_method("can_afford_salvage"):
		if not _ai_resource_manager.can_afford_salvage(bstats.cost_salvage):
			return

	# AI now needs an engineer to build. If none are free, skip — the AI
	# will retry next tick (or after producing more engineers).
	var engineer: Node = _find_free_engineer()
	if not engineer:
		return

	# Find a placement that doesn't overlap a building, unit, fuel deposit,
	# or wreck. Hard-coded offsets occasionally collide; spiral outward from
	# the desired position until something fits.
	var desired: Vector3 = _hq.global_position + offset
	var pos: Vector3 = _find_clear_placement(desired, bstats.footprint_size)
	if pos == Vector3.INF:
		return  # retry next tick once the area clears

	# Use the same path as the player: BuilderComponent.place_building spends
	# resources, instantiates the building, calls begin_construction, and
	# assigns this engineer as its builder.
	var builder: Node = engineer.get_builder()
	if not builder or not builder.has_method("place_building"):
		return
	builder.place_building(bstats, pos, _ai_resource_manager)

	# Find the building we just placed so we can hold a reference for
	# production / state tracking.
	var building: Node = _find_building_at(pos, bstats.footprint_size)
	if not building:
		return
	_buildings_placed[key] = true

	# Keep references for production
	match key:
		"foundry": _foundry = building
		"adv_foundry": _adv_foundry = building
		"generator": _generator = building
		"generator2": _generator2 = building
		"salvage_yard": _salvage_yard = building
		"turret": _turret = building


func _maintain_engineers() -> void:
	## Keep at least one Ratchet engineer alive. Built at the HQ, just like
	## the player builds them. Without this the AI permanently loses build
	## capability if the player wipes out the starting engineers.
	if not is_instance_valid(_hq) or not _hq.get("is_constructed"):
		return
	var engineer_count: int = 0
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if node.has_method("get_builder") and node.get_builder():
			engineer_count += 1
	if engineer_count >= 1:
		return
	# Don't pile up Ratchets in the queue; only request one at a time.
	if _hq.has_method("get_queue_size") and _hq.get_queue_size() > 0:
		return
	var ratchet: UnitStatResource = load("res://resources/units/anvil_ratchet.tres") as UnitStatResource
	if not ratchet:
		return
	if not _ai_resource_manager:
		return
	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage < ratchet.cost_salvage:
		return
	_ai_resource_manager.spend(ratchet.cost_salvage, ratchet.cost_fuel)
	_hq.queue_unit(ratchet)


func _maintain_crawlers() -> void:
	## Queue a Salvage Crawler at the HQ when the AI doesn't have one and has
	## the salvage to afford it. Once the Crawler exists, command it toward
	## the nearest wreck-rich zone so it stops parking next to its own HQ.
	if not is_instance_valid(_hq) or not _hq.get("is_constructed"):
		return
	if not _ai_resource_manager:
		return

	# Count alive AI-owned Crawlers + any in queue.
	var crawler_count: int = 0
	for node: Node in get_tree().get_nodes_in_group("crawlers"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") == owner_id:
			crawler_count += 1
	if _hq.has_method("get_queue_unit_count"):
		crawler_count += _hq.get_queue_unit_count(&"crawler")
	if crawler_count >= 1:
		# Already have / building one — keep an idle one moving to wrecks.
		_command_idle_crawler_to_wreck()
		return

	var crawler_stats: UnitStatResource = load("res://resources/units/anvil_crawler.tres") as UnitStatResource
	if not crawler_stats:
		return
	# Don't spam queue — wait for production to finish.
	if _hq.has_method("get_queue_size") and _hq.get_queue_size() > 0:
		return
	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage < crawler_stats.cost_salvage:
		return
	# Reserve a healthy buffer above the Crawler cost so we don't bankrupt
	# the rest of the economy on a single buy.
	if salvage < crawler_stats.cost_salvage + 150:
		return
	_ai_resource_manager.spend(crawler_stats.cost_salvage, crawler_stats.cost_fuel)
	_hq.queue_unit(crawler_stats)


## How fresh "took damage" must be to count as under-fire (seconds).
const CRAWLER_RETREAT_WINDOW: float = 4.0
## Damage HP each Crawler had last poll, keyed by instance id. Used to
## detect "Crawler is being shot at this tick".
var _crawler_last_hp: Dictionary = {}
## Last time each Crawler took damage, keyed by instance id.
var _crawler_last_damage_at: Dictionary = {}
## "Idle" radius — narrower than the Crawler's actual harvest reach so a
## cluster has to be genuinely close (visibly being worked) before we say
## "the Crawler is busy here". Anything outside this counts as "no work,
## go relocate" and triggers a move toward the nearest fresh wreck.
const CRAWLER_LOCAL_HARVEST_RADIUS: float = 10.0
## When a Crawler takes damage we sweep this radius around it for the
## attacker and steer nearby AI military toward the threat. Big enough
## to catch most weapon ranges; small enough that a fight on the other
## side of the map doesn't pull defenders away.
const CRAWLER_DEFENSE_SCAN_RADIUS: float = 30.0
const CRAWLER_DEFENDER_DRAW_RADIUS: float = 65.0
## Sweep across the whole map when the local radius is dry. ±150 nav.
const CRAWLER_RELOCATE_SEARCH_RADIUS: float = 400.0


func _command_idle_crawler_to_wreck() -> void:
	## Shepherds each AI Crawler:
	## - Track damage so we can detect "under fire" and force a retreat to
	##   the HQ. Anchored Crawlers ride out the hit since unanchoring is
	##   itself vulnerable.
	## - When workers have nothing to harvest (no wrecks within local
	##   harvest range), relocate to the nearest wreck anywhere on the map.
	##   Without this, an AI Crawler harvests the safe-zone wrecks, runs
	##   them dry, and then sits parked next to its HQ forever.
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	for node: Node in get_tree().get_nodes_in_group("crawlers"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue

		var iid: int = node.get_instance_id()
		var cur_hp: int = node.get("current_hp") as int
		var prev_hp: int = (_crawler_last_hp.get(iid, cur_hp) as int)
		if cur_hp < prev_hp:
			_crawler_last_damage_at[iid] = now
		_crawler_last_hp[iid] = cur_hp

		var anchored: bool = node.has_method("is_anchored") and node.is_anchored()
		var under_fire: bool = (now - (_crawler_last_damage_at.get(iid, -999.0) as float)) < CRAWLER_RETREAT_WINDOW

		# Retreat takes priority — we route home even if a move order is
		# already in flight (it might be heading toward the threat).
		if under_fire and not anchored:
			if is_instance_valid(_hq):
				var retreat_pos: Vector3 = _hq.global_position + Vector3(0.0, 0.0, 8.0)
				if node.has_method("command_move"):
					node.command_move(retreat_pos)
			# Rally nearby military to intercept the threat — gives the
			# Crawler a fighting chance to make it home.
			_dispatch_crawler_defenders((node as Node3D).global_position)
			continue

		# Nothing to override the retreat — only push relocate orders when
		# the Crawler is genuinely idle.
		if node.get("has_move_order") == true:
			continue
		if anchored:
			continue

		var local_wreck: Node3D = _find_nearest_wreck(node.global_position, CRAWLER_LOCAL_HARVEST_RADIUS)
		if local_wreck:
			# Plenty to chew on right here — let workers do their job.
			continue

		# Relocation target. In 2v2 we skip wrecks already inside an ally's
		# harvest reach so the two AIs don't dogpile the same cluster.
		var target_wreck: Node3D = _find_relocation_target(node.global_position, CRAWLER_RELOCATE_SEARCH_RADIUS)
		if not target_wreck:
			continue
		var dir: Vector3 = (target_wreck.global_position - node.global_position)
		dir.y = 0.0
		var dist: float = dir.length()
		if dist < 6.0:
			continue
		var target_pos: Vector3 = target_wreck.global_position - dir.normalized() * 4.0
		if node.has_method("command_move"):
			node.command_move(target_pos)


func _dispatch_crawler_defenders(crawler_pos: Vector3) -> void:
	## Find the nearest enemy (likely the attacker) within CRAWLER_DEFENSE_SCAN_RADIUS
	## of the Crawler's position, then send every non-engineer AI unit
	## within CRAWLER_DEFENDER_DRAW_RADIUS at that target via attack-move.
	## Engineers stay home so the base keeps building. Attack-move means
	## defenders engage anything they pass on the way too — fine, that's
	## the threat's escort.
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	var attacker_pos: Vector3 = Vector3.INF
	var nearest_enemy_dist: float = CRAWLER_DEFENSE_SCAN_RADIUS
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var node_owner: int = node.get("owner_id") as int
		var hostile: bool = (
			registry.are_enemies(owner_id, node_owner)
			if registry and registry.has_method("are_enemies")
			else node_owner != owner_id
		)
		if not hostile:
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var d: float = crawler_pos.distance_to((node as Node3D).global_position)
		if d < nearest_enemy_dist:
			nearest_enemy_dist = d
			attacker_pos = (node as Node3D).global_position
	if attacker_pos == Vector3.INF:
		return  # Damage source moved off / was a building / out of scan range.

	# Now send any nearby military units toward the attacker.
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		# Skip engineers — they stay home and keep building.
		if node.has_method("get_builder") and node.get_builder():
			continue
		var d: float = (node as Node3D).global_position.distance_to(crawler_pos)
		if d > CRAWLER_DEFENDER_DRAW_RADIUS:
			continue
		var combat: Node = node.get_node_or_null("CombatComponent")
		if combat and combat.has_method("command_attack_move"):
			combat.command_attack_move(attacker_pos)


## Yard-expansion helper. Looks for a wreck cluster center far from any
## existing friendly yard / Crawler, with no enemies nearby, and drops
## a Salvage Yard there. Returns silently when no good candidate exists
## (no engineer free, no resources, no safe spot) — the next interval
## will retry.
func _try_expansion_yard() -> void:
	if not is_instance_valid(_hq) or not _hq.get("is_constructed"):
		return
	if not _ai_resource_manager:
		return
	var yard_stats: BuildingStatResource = load("res://resources/buildings/salvage_yard.tres") as BuildingStatResource
	if not yard_stats:
		return
	# Need enough salvage to also keep paying for combat units. Reserve
	# 200 above the yard cost so the yard doesn't bankrupt the AI.
	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage < yard_stats.cost_salvage + 200:
		return
	var engineer: Node = _find_free_engineer()
	if not engineer:
		return

	var pos: Vector3 = _find_expansion_site()
	if pos == Vector3.INF:
		return

	# Place via the existing builder pipeline so resources are spent and
	# the engineer is auto-assigned to the construction.
	var builder: Node = engineer.get_builder()
	if not builder or not builder.has_method("place_building"):
		return
	builder.place_building(yard_stats, pos, _ai_resource_manager)


func _find_expansion_site() -> Vector3:
	## Returns a candidate position with a wreck cluster nearby, no
	## enemies inside EXPANSION_MAX_ENEMY_DIST, and no friendly yards /
	## Crawlers inside EXPANSION_MIN_FRIENDLY_DIST. Scans wrecks as
	## anchor points (they're where harvesters want to be).
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	var friendly_centers: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.stats:
			continue
		if b.owner_id != owner_id:
			continue
		if b.stats.building_id != &"salvage_yard":
			continue
		friendly_centers.append(b.global_position)
	for node: Node in get_tree().get_nodes_in_group("crawlers"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") == owner_id:
			friendly_centers.append((node as Node3D).global_position)

	var enemy_positions: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var node_owner: int = node.get("owner_id") as int
		var hostile: bool = (
			registry.are_enemies(owner_id, node_owner)
			if registry and registry.has_method("are_enemies")
			else node_owner != owner_id
		)
		if not hostile:
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		enemy_positions.append((node as Node3D).global_position)

	# Sample wrecks in ascending distance from HQ (we want close-ish
	# expansions first, not the far enemy side). For each candidate
	# wreck, validate the safety / spacing rules and try to place a
	# yard near it.
	var hq_pos: Vector3 = _hq.global_position
	var wreck_list: Array[Node] = get_tree().get_nodes_in_group("wrecks").duplicate()
	wreck_list.sort_custom(func(a: Node, b: Node) -> bool:
		if not (a is Node3D) or not (b is Node3D):
			return false
		return hq_pos.distance_to((a as Node3D).global_position) < hq_pos.distance_to((b as Node3D).global_position)
	)
	for w: Node in wreck_list:
		if not is_instance_valid(w):
			continue
		var wp: Vector3 = (w as Node3D).global_position
		# Must be far enough from any existing friendly yard / Crawler.
		var too_close_friendly: bool = false
		for c: Vector3 in friendly_centers:
			if wp.distance_to(c) < EXPANSION_MIN_FRIENDLY_DIST:
				too_close_friendly = true
				break
		if too_close_friendly:
			continue
		# Must be safe — no enemy unit within EXPANSION_MAX_ENEMY_DIST.
		var hostile_nearby: bool = false
		for ep: Vector3 in enemy_positions:
			if wp.distance_to(ep) < EXPANSION_MAX_ENEMY_DIST:
				hostile_nearby = true
				break
		if hostile_nearby:
			continue
		# Find a clear footprint within a couple of units of the wreck.
		var stats: BuildingStatResource = load("res://resources/buildings/salvage_yard.tres") as BuildingStatResource
		if not stats:
			return Vector3.INF
		# Build a few units back from the wreck so the yard doesn't
		# stamp on top of it.
		var to_hq: Vector3 = (hq_pos - wp)
		to_hq.y = 0.0
		var anchor: Vector3 = wp
		if to_hq.length_squared() > 0.01:
			anchor = wp + to_hq.normalized() * 4.0
		var pos: Vector3 = _find_clear_placement(anchor, stats.footprint_size)
		if pos != Vector3.INF:
			return pos
	return Vector3.INF


func _find_nearest_wreck(from: Vector3, max_dist: float) -> Node3D:
	var best: Node3D = null
	var best_dist: float = max_dist
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		var d: float = from.distance_to(n3.global_position)
		if d < best_dist:
			best_dist = d
			best = n3
	return best


## Match SalvageCrawler.HARVEST_RADIUS — same number, different file. If a
## wreck is within this distance of any allied Crawler / Yard, treat it as
## "already being chewed on" and let the ally finish the job.
const ALLY_CLAIM_RADIUS: float = 45.0


func _find_relocation_target(from: Vector3, max_dist: float) -> Node3D:
	## Like `_find_nearest_wreck` but skips wrecks already inside an ally's
	## harvest claim. Keeps the two AI players from racing to the same pile
	## in 2v2 (and stops a future AI ally from siphoning off the player's
	## near-base wrecks).
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	var ally_centers: Array[Vector3] = []
	if registry and registry.has_method("are_allied"):
		# Allied Crawlers (different player_id, same team).
		for node: Node in get_tree().get_nodes_in_group("crawlers"):
			if not is_instance_valid(node):
				continue
			var node_owner: int = node.get("owner_id") as int
			if node_owner == owner_id:
				continue
			if registry.are_allied(owner_id, node_owner):
				ally_centers.append((node as Node3D).global_position)
		# Allied Salvage Yards (buildings of building_id == salvage_yard).
		for node: Node in get_tree().get_nodes_in_group("buildings"):
			if not is_instance_valid(node):
				continue
			var b: Building = node as Building
			if not b or not b.stats:
				continue
			if b.stats.building_id != &"salvage_yard":
				continue
			if b.owner_id == owner_id:
				continue
			if registry.are_allied(owner_id, b.owner_id):
				ally_centers.append(b.global_position)

	var best: Node3D = null
	var best_dist: float = max_dist
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		var pos: Vector3 = n3.global_position
		var claimed: bool = false
		for c: Vector3 in ally_centers:
			if pos.distance_to(c) < ALLY_CLAIM_RADIUS:
				claimed = true
				break
		if claimed:
			continue
		var d: float = from.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = n3
	return best


func _find_free_engineer() -> Node:
	## Returns an idle AI engineer (Ratchet) — one with a builder component
	## that isn't currently constructing or moving to a build site.
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue
		if "alive_count" in node and node.get("alive_count") <= 0:
			continue
		var builder: Node = node.get_builder() if node.has_method("get_builder") else null
		if not builder:
			continue
		# Read the target through Variant + is_instance_valid so a freed
		# Building reference (queue_free'd but still cached on the builder)
		# can't crash the cast. If it's freed, the engineer is treated as
		# free-to-build.
		var target_var: Variant = builder.get("_target_building")
		if target_var is Object and is_instance_valid(target_var):
			var target_node: Node = target_var as Node
			if target_node and not target_node.get("is_constructed"):
				continue  # Builder is genuinely busy on a live, unfinished site.
		return node
	return null


func _find_building_at(pos: Vector3, footprint: Vector3) -> Node:
	## Find the freshly-placed building (matching position within the
	## footprint half-extent) so _try_place can cache references.
	var half_x: float = footprint.x * 0.5 + 0.5
	var half_z: float = footprint.z * 0.5 + 0.5
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue
		var b: Node3D = node as Node3D
		if not b:
			continue
		if absf(b.global_position.x - pos.x) < half_x and absf(b.global_position.z - pos.z) < half_z:
			return node
	return null


func _find_clear_placement(desired: Vector3, footprint: Vector3) -> Vector3:
	if _is_placement_clear(desired, footprint):
		return desired
	# Spiral search — expanding rings around the desired anchor.
	for ring: int in range(1, 8):
		for step: int in 12:
			var ang: float = float(step) / 12.0 * TAU
			var test_offset := Vector3(cos(ang), 0.0, sin(ang)) * float(ring) * 2.5
			var pos: Vector3 = desired + test_offset
			if _is_placement_clear(pos, footprint):
				return pos
	return Vector3.INF


## Required clear gap between adjacent buildings — keeps AI bases from looking
## visually packed even when AABBs technically don't overlap.
## Same rationale as selection_manager.gd's BUILD_PLACEMENT_GAP — wide
## enough that a unit's collision capsule fits through the gap between
## two adjacent buildings without wedging.
const PLACEMENT_GAP: float = 2.6


## How far units / fuel deposits / wrecks must be from the placement footprint.
const UNIT_PLACEMENT_MARGIN: float = 0.5

## Keep-out radius around any *allied* HQ (other than this AI's own) so the
## ally doesn't crowd the human player's base in 2v2. The player should be
## able to walk around their HQ without bumping into an AI ally's foundry.
const ALLY_HQ_KEEPOUT: float = 30.0


func _is_placement_clear(pos: Vector3, footprint: Vector3) -> bool:
	## Same rules the player follows in SelectionManager — check against
	## buildings (with PLACEMENT_GAP buffer), units, fuel deposits, and
	## wrecks. Plus a keep-out around teammate HQs in 2v2.
	var half_x: float = footprint.x * 0.5
	var half_z: float = footprint.z * 0.5

	# Allied HQ keep-out — skip our own HQ, but stay clear of any teammate's.
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("are_allied"):
		for node: Node in get_tree().get_nodes_in_group("buildings"):
			if not is_instance_valid(node):
				continue
			var b: Building = node as Building
			if not b or not b.stats:
				continue
			if b.stats.building_id != &"headquarters":
				continue
			var b_owner: int = b.owner_id
			if b_owner == owner_id:
				continue
			if not registry.are_allied(owner_id, b_owner):
				continue
			if pos.distance_to(b.global_position) < ALLY_HQ_KEEPOUT:
				return false

	# Buildings (AABB-vs-AABB with spacing gap).
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.stats:
			continue
		var their_hx: float = b.stats.footprint_size.x * 0.5
		var their_hz: float = b.stats.footprint_size.z * 0.5
		var dx: float = absf(b.global_position.x - pos.x)
		var dz: float = absf(b.global_position.z - pos.z)
		if dx < (half_x + their_hx + PLACEMENT_GAP) and dz < (half_z + their_hz + PLACEMENT_GAP):
			return false

	# Units — friendly OR enemy. The AI shouldn't be allowed to drop a
	# foundry on top of player units mid-raid either.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var u: Node3D = node as Node3D
		if not u:
			continue
		var dx: float = absf(u.global_position.x - pos.x)
		var dz: float = absf(u.global_position.z - pos.z)
		if dx < (half_x + UNIT_PLACEMENT_MARGIN) and dz < (half_z + UNIT_PLACEMENT_MARGIN):
			return false

	# Fuel deposits, wrecks, and terrain. Terrain pieces are static so AI
	# foundations dropped on top would clip into them and never finish.
	for group_name: String in ["fuel_deposits", "wrecks", "terrain", "elevation"]:
		for node: Node in get_tree().get_nodes_in_group(group_name):
			if not is_instance_valid(node):
				continue
			var f: Node3D = node as Node3D
			if not f:
				continue
			var dx: float = absf(f.global_position.x - pos.x)
			var dz: float = absf(f.global_position.z - pos.z)
			if dx < (half_x + UNIT_PLACEMENT_MARGIN) and dz < (half_z + UNIT_PLACEMENT_MARGIN):
				return false

	return true


func _try_queue_at(foundry_node: Node) -> void:
	if not foundry_node or not is_instance_valid(foundry_node):
		return
	if not foundry_node.get("is_constructed"):
		return
	if not foundry_node.has_method("get_queue_size"):
		return
	if foundry_node.get_queue_size() >= 2:
		return

	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource
	var hound_stats: UnitStatResource = load("res://resources/units/anvil_hound.tres") as UnitStatResource
	var bulwark_stats: UnitStatResource = load("res://resources/units/anvil_bulwark.tres") as UnitStatResource

	# Choose unit type based on wave count and randomness
	var unit_stats: UnitStatResource = rook_stats
	var roll: int = randi() % 10

	if _wave_count >= 2 and bulwark_stats and roll < 2:
		unit_stats = bulwark_stats
	elif hound_stats and roll < 5:
		unit_stats = hound_stats

	if not unit_stats:
		return

	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage >= unit_stats.cost_salvage:
		_ai_resource_manager.spend(unit_stats.cost_salvage, unit_stats.cost_fuel)
		foundry_node.queue_unit(unit_stats)
