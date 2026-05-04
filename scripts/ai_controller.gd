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
## Safety net against the 'AI never attacks' failure mode -- if no
## attack has launched for this many seconds since either match
## start or the last attack, the AI force-pushes ATTACK with
## whatever it has. Prevents the loop where wave_size never gets
## reached because attrition keeps the unit count below the
## threshold. Per-personality overrides below shorten / lengthen
## this for RUSH / TURRET_HEAVY etc. Hard difficulty also scales
## it down (more aggressive timeout).
const MAX_DORMANT_SEC_BASE: float = 150.0
## Match-wall-clock seconds since this AI spawned. Independent of
## _state_timer so it survives state transitions, REBUILD pauses
## etc. Drives the dormant-attack safety net.
var _match_clock_sec: float = 0.0
## Wall-clock seconds since this AI last LAUNCHED an attack
## (entered ATTACK state). Initialised to 0 so the first attack
## still has to satisfy the normal wave-size / dormant-timer
## thresholds.
var _last_attack_clock_sec: float = 0.0

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

## Oil-contest dispatch -- every OIL_CONTEST_INTERVAL seconds the AI
## picks a fuel deposit (neutral preferred, otherwise enemy-held) near
## its base and detaches a small attack-move detachment to claim it.
## Keeps the AI from leaving deposits to the player by default. The
## per-tick chance scales with aggression so Hard contests almost
## every interval while Easy only sometimes bothers.
const OIL_CONTEST_INTERVAL: float = 18.0
## Detachment size when the AI actively claims an oil field.
## Bumped 3 -> 4 so a contested deposit (player camping with a
## small force) is more likely to actually flip rather than the
## AI bouncing off and respawning the same dispatch in 18s.
const OIL_CONTEST_DETACHMENT_SIZE: int = 4
var _oil_contest_timer: float = 0.0

var _salvage_accumulator: float = 0.0

## --- Per-match strategy variation ---------------------------------------
## Each AIController rolls a strategy archetype + jittered building offsets
## at _setup time so two runs of the same match (or two AIs in 2v2) don't
## produce visually identical bases. Resource buildings are NEVER skipped —
## every archetype builds a generator, foundry, and salvage yard early.
## The archetype shifts the *secondary* timing and footprint shape.
enum Strategy { BALANCED, TURRET_HEAVY, ECONOMY_HEAVY, RUSH, AIR }
var _strategy: int = Strategy.BALANCED
## World-space offsets from HQ for each placed building. Filled at _setup
## with randomly jittered values keyed by the same string the build flow
## uses ("generator", "foundry", "salvage_yard", etc.).
var _building_offsets: Dictionary = {}

## Cached difficulty multipliers from the MatchSettings autoload (defaults to
## Normal if the autoload isn't present, e.g. when running the test arena
## scene directly from the editor).
var _econ_mul: float = 1.0
var _agg_mul: float = 1.0
## Turret resource path picked at startup based on the AI's faction.
## Anvil AI gets the specialised emplacement; Sable AI gets the basic
## ground-only variant. Resolved here so every _try_place(turret_*)
## call below can use the same path without re-querying MatchSettings.
var _turret_path: String = "res://resources/buildings/gun_emplacement.tres"

## AI's own FactionId (0 = Anvil, 1 = Sable). Resolved in _enter_tree
## from MatchSettings + PlayerRegistry team. Drives every unit-resource
## lookup below so a Sable AI never tries to queue an Anvil unit at its
## HQ / foundry (which silently fails the producibility check inside
## Building.queue_unit, dropping the salvage cost on the floor — the
## cause of the "AI keeps draining to 0 with nothing to show" bug).
var _my_faction: int = 0


func _enter_tree() -> void:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings:
		# Per-AI difficulty override if the menu set one for this slot;
		# otherwise the global match difficulty.
		if settings.has_method("get_ai_difficulty"):
			var d: int = settings.get_ai_difficulty(owner_id)
			_econ_mul = _econ_mul_for_difficulty(d)
			_agg_mul = _agg_mul_for_difficulty(d)
		else:
			_econ_mul = settings.get_ai_economy_multiplier()
			_agg_mul = settings.get_ai_aggression_multiplier()
		# Sable AI picks the basic ground turret; Anvil keeps the
		# specialised one. Faction id 1 = Sable (per MatchSettings.FactionId).
		_my_faction = _resolve_my_faction(settings)
		if _my_faction == 1:
			_turret_path = "res://resources/buildings/gun_emplacement_basic.tres"


func _resolve_my_faction(settings: Node) -> int:
	## Mirrors test_arena_controller._faction_for_player so the AI
	## resolves its own faction the same way the spawner does — checks
	## the per-AI override first, then falls back to team-based default
	## (team 0 = ally → player_faction; team 1 = enemy → enemy_faction).
	if not settings:
		return 0
	if settings.has_method("has_ai_faction") and settings.call("has_ai_faction", owner_id):
		return settings.call("get_ai_faction", owner_id) as int
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("get_state"):
		var st: Variant = registry.call("get_state", owner_id)
		if st and "team_id" in st and (st.team_id as int) == 0:
			return settings.get("player_faction") as int
	return settings.get("enemy_faction") as int


func _engineer_path() -> String:
	## Per-faction engineer resource. Sable's HQ producible list does NOT
	## contain anvil_ratchet, so a hardcoded Anvil path silently fails the
	## queue and bleeds salvage every tick.
	if _my_faction == 1:
		return "res://resources/units/sable_rigger.tres"
	return "res://resources/units/anvil_ratchet.tres"


func _basic_foundry_unit_paths() -> Array[String]:
	## Per-faction roster the AI can queue at basic_foundry. Mirrors the
	## Sable producibility list in Building._faction_producible_list. Order
	## here is { light, medium, heavy } so callers can index the same way
	## across factions even though Sable basic has no heavy (returns ""
	## for the heavy slot — caller must handle).
	if _my_faction == 1:
		return ["res://resources/units/sable_specter.tres", "res://resources/units/sable_jackal.tres", ""]
	return ["res://resources/units/anvil_rook.tres", "res://resources/units/anvil_hound.tres", "res://resources/units/anvil_bulwark.tres"]


func _adv_foundry_heavy_path() -> String:
	## Per-faction heavy unit path used at advanced_foundry. Sable's
	## Harbinger sits in the adv list, not basic — same role as Bulwark.
	if _my_faction == 1:
		return "res://resources/units/sable_harbinger.tres"
	return "res://resources/units/anvil_bulwark.tres"


func _econ_mul_for_difficulty(d: int) -> float:
	# Hard cap pulled 2.0 -> 1.4 so the AI doesn't outpace its
	# build-plan with stockpiled income. Income trickle now sits
	# closer to a player's typical economy and the AI has to
	# actually convert it into structures + units rather than
	# burying salvage under a single wave.
	match d:
		0: return 0.65  # EASY
		2: return 1.4   # HARD
		_: return 1.1   # NORMAL


func _agg_mul_for_difficulty(d: int) -> float:
	match d:
		0: return 0.75
		2: return 1.8
		_: return 1.15


func _resolve_strategy_from_settings() -> int:
	## Honours MatchSettings.get_ai_personality(owner_id) when set, with
	## RANDOM falling back to the original randi() roll. Maps the
	## menu's AiPersonality enum onto the local Strategy enum.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.has_method("get_ai_personality"):
		var pick: int = settings.get_ai_personality(owner_id)
		# AiPersonality: RANDOM=0, BALANCED=1, TURRET_HEAVY=2, ECONOMY_HEAVY=3, RUSH=4, AIR=5
		# Strategy:                 BALANCED=0, TURRET_HEAVY=1, ECONOMY_HEAVY=2, RUSH=3, AIR=4
		if pick == 1:
			return Strategy.BALANCED
		elif pick == 2:
			return Strategy.TURRET_HEAVY
		elif pick == 3:
			return Strategy.ECONOMY_HEAVY
		elif pick == 4:
			return Strategy.RUSH
		elif pick == 5:
			return Strategy.AIR
	return randi() % Strategy.size()


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

	# Roll personality + base layout for this match. Done here (not in
	# _enter_tree) so each AI's RNG draw is independent and a 2v2 scene
	# gets two AIs with different archetypes / offsets.
	_roll_strategy_and_layout()

	# Transition out of SETUP into ECONOMY now that we have a HQ. Without
	# this, the state machine sits in SETUP forever and `_process`'s
	# match block has no case for SETUP — so the AI does literally
	# nothing. (Regression caught after a refactor briefly orphaned this
	# block outside `_setup`.)
	if _hq:
		_state = AIState.ECONOMY
		_state_timer = 0.0


func _roll_strategy_and_layout() -> void:
	## Picks one of four archetypes and generates jittered building offsets
	## within the archetype's footprint shape. Resource buildings (generator,
	## foundry, salvage_yard) are always present; what changes is *where*
	## they sit and *when* the secondary buildings come online.
	## Honours `MatchSettings.ai_personalities[owner_id]` if the menu set
	## an override; otherwise rolls random.
	_strategy = _resolve_strategy_from_settings()

	# Archetype-specific footprint character. Pull radii drive how far each
	# building sits from the HQ; the angle is randomised per-call so even
	# two AIs that roll BALANCED look different.
	var pull: float
	match _strategy:
		Strategy.TURRET_HEAVY:
			pull = randf_range(13.0, 17.0)  # tighter cluster, room out front for turrets
		Strategy.ECONOMY_HEAVY:
			pull = randf_range(20.0, 26.0)  # wider footprint to fit extra yards
		Strategy.RUSH:
			pull = randf_range(12.0, 16.0)  # tight + forward, no defensive ring
		_:
			pull = randf_range(15.0, 20.0)  # balanced default

	# Generate offsets on a randomly-rotated cardinal cross + back/front
	# slots. The whole layout is rotated by a random angle so it isn't
	# always axis-aligned (a foundry on the left vs the right vs behind
	# the HQ reads as a meaningfully different base at a glance).
	var base_angle: float = randf_range(0.0, TAU)
	var slot_angles: Dictionary = {
		"generator": base_angle + randf_range(0.55, 0.85),
		"foundry": base_angle + PI + randf_range(-0.30, 0.30),
		"salvage_yard": base_angle + PI * 0.5 + randf_range(-0.25, 0.25),
		"generator2": base_angle - randf_range(0.55, 0.85),
		"turret": base_angle + PI * 1.5 + randf_range(-0.4, 0.4),
		"adv_foundry": base_angle + PI + randf_range(0.6, 1.0),
		# Air production goes opposite the basic foundry (so the cluster
		# spreads). SAM site sits forward like the turret but a bit
		# further out and on a different angle slot.
		"aerodrome": base_angle + randf_range(-0.5, -0.2),
		"sam_site": base_angle + PI * 1.5 + randf_range(0.4, 0.8),
		# Three Turret-Heavy turret-cluster anchors. A is the home cluster
		# (dead-front of HQ, same angle band as the regular turret slot).
		# B and C deploy farther out on the forward flanks at separate
		# bearings so their kill-zones cover distinct slices of the map
		# rather than triple-stacking on one spot.
		"turret_a": base_angle + PI * 1.5 + randf_range(-0.3, 0.3),
		"turret_b": base_angle + PI * 1.5 + randf_range(0.55, 0.85),
		"turret_c": base_angle + PI * 1.5 + randf_range(-0.85, -0.55),
	}
	# Per-building radius jitter so the cluster isn't a perfect ring.
	for key: String in slot_angles.keys():
		var ang: float = slot_angles[key] as float
		var r: float = pull * randf_range(0.85, 1.15)
		# Forward-flank turret groups sit deliberately far out — they're
		# meant to extend the AI's range coverage past its base footprint,
		# so we override the per-cluster radius with a much bigger pull.
		if key == "turret_b" or key == "turret_c":
			r = randf_range(45.0, 55.0)
		_building_offsets[key] = Vector3(cos(ang) * r, 0.0, sin(ang) * r)


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


## Throttle for the AI's state-tick. The AI's decision loop runs
## at multi-second timescales (state durations measured in 5-30s
## blocks); ticking it at 60Hz wasted ~58 frames out of every 60
## walking the owner group + checking timers that hadn't moved
## meaningfully. 5Hz is fast enough that any in-flight transition
## still feels reactive.
const AI_TICK_INTERVAL: float = 0.20
var _ai_tick_accum: float = 0.0


func _process(delta: float) -> void:
	if _hq_destroyed:
		return
	if not _hq or not is_instance_valid(_hq):
		_hq_destroyed = true
		return

	# Passive income — scaled by difficulty's economy multiplier so Easy
	# starves the AI a bit and Hard makes it tech up faster. Income
	# accumulator stays on the per-frame path because it integrates
	# fractional salvage that we don't want to drop on throttled ticks.
	if _ai_resource_manager and _ai_resource_manager.has_method("add_salvage"):
		_salvage_accumulator += AI_SALVAGE_TRICKLE * _econ_mul * delta
		if _salvage_accumulator >= 1.0:
			var trickle: int = int(_salvage_accumulator)
			_salvage_accumulator -= float(trickle)
			_ai_resource_manager.add_salvage(trickle)
			# Also give some fuel
			if _ai_resource_manager.has_method("add_fuel"):
				_ai_resource_manager.add_fuel(max(trickle / 3, 1))

	# Throttle the rest of the AI tick (state machine + group walks
	# + expansion timer) to ~5Hz. Below this point `delta` is the
	# accumulated delta since the last tick, NOT the per-frame
	# delta, so any per-second math stays correct.
	_ai_tick_accum += delta
	if _ai_tick_accum < AI_TICK_INTERVAL:
		return
	delta = _ai_tick_accum
	_ai_tick_accum = 0.0

	# Update unit list
	_units.clear()
	var all_nodes: Array[Node] = get_tree().get_nodes_in_group("owner_%d" % owner_id)
	for node: Node in all_nodes:
		if node.is_in_group("units") and is_instance_valid(node):
			if "alive_count" in node and node.get("alive_count") > 0:
				_units.append(node)

	# Match wall-clock advances regardless of state. Drives the
	# dormant-attack safety net so a stuck ECONOMY/ARMY/REBUILD
	# loop can't keep the AI passive forever.
	_match_clock_sec += delta

	_state_timer += delta

	# Forward-yard expansion ticks across all states except REBUILD (when
	# the AI's been wiped and is reconstituting). Drops one new yard per
	# interval, far from existing infrastructure, in safe territory.
	if _state != AIState.REBUILD:
		_expansion_timer += delta
		if _expansion_timer >= EXPANSION_INTERVAL:
			_expansion_timer = 0.0
			_try_expansion_yard()
		# Oil contest: try to claim / re-flip nearby deposits. Skipped
		# in SETUP (no army yet) and REBUILD (just got wiped).
		if _state != AIState.SETUP:
			_oil_contest_timer += delta
			if _oil_contest_timer >= OIL_CONTEST_INTERVAL:
				_oil_contest_timer = 0.0
				_try_contest_oil()

	match _state:
		AIState.ECONOMY:
			_process_economy()
		AIState.ARMY:
			_process_army()
		AIState.ATTACK:
			_process_attack()
		AIState.REBUILD:
			_process_rebuild()


func _personality_wave_size_base() -> int:
	## Per-personality base wave size before _agg_mul + _wave_count
	## scaling. RUSH attacks earlier with smaller waves to chip the
	## opponent constantly; ECONOMY_HEAVY masses up bigger pushes.
	match _strategy:
		Strategy.RUSH:           return 5
		Strategy.TURRET_HEAVY:   return 9
		Strategy.ECONOMY_HEAVY:  return 11
		_:                       return 7  # BALANCED


func _personality_dormant_timeout_sec() -> float:
	## Per-personality 'I MUST attack now even if I'm under-massed'
	## ceiling. Hard difficulty pulls these down further via the
	## aggression multiplier so a Hard AI is never silent for long.
	var base: float = MAX_DORMANT_SEC_BASE
	match _strategy:
		Strategy.RUSH:           base = 90.0
		Strategy.TURRET_HEAVY:   base = 200.0
		Strategy.ECONOMY_HEAVY:  base = 180.0
		_:                       base = 150.0  # BALANCED
	# Aggression multiplier inversely scales the timeout: Hard
	# (1.8) shrinks 150s -> ~83s; Easy (0.75) lengthens to 200s.
	# Floor at 60s so a hyper-aggro AI still gives the player a
	# beat to react.
	return maxf(base / maxf(_agg_mul, 0.5), 60.0)


func _force_attack_if_dormant() -> bool:
	## Returns true (and transitions to ATTACK) if more than the
	## personality's dormant-timeout seconds have passed since the
	## last attack and we have AT LEAST one combat unit. Acts as
	## the safety net against the wave-size-never-reached failure
	## mode -- the AI will always attack eventually, even if the
	## ARMY phase keeps eating losses to defensive harassment.
	var since_last: float = _match_clock_sec - _last_attack_clock_sec
	if since_last < _personality_dormant_timeout_sec():
		return false
	# Need at least MIN_DORMANT_FORCE_UNITS combat units (skip
	# engineers / crawlers). Bumped from 1 -> 3 so the dormant
	# safety net doesn't trickle a single unit at the enemy base
	# the moment the timeout expires -- the previous single-unit
	# floor produced the player-visible "AI trains 1, sends 1, it
	# dies, repeat" pattern. With 3 units the AI at least shows up
	# as a recognisable squad.
	const MIN_DORMANT_FORCE_UNITS: int = 3
	var combat_count: int = 0
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if node.has_method("get_builder") and node.get_builder():
			continue
		combat_count += 1
		if combat_count >= MIN_DORMANT_FORCE_UNITS:
			break
	if combat_count < MIN_DORMANT_FORCE_UNITS:
		return false
	_state = AIState.ATTACK
	_state_timer = 0.0
	_last_attack_clock_sec = _match_clock_sec
	return true


func _process_economy() -> void:
	# Replenish engineers if we're running low — they're built at the HQ.
	_maintain_engineers()
	# Queue and pilot a Crawler.
	_maintain_crawlers()

	# Phase 1 — resource trio (generator + foundry + salvage yard). Always
	# placed regardless of archetype; only their offsets vary per match
	# (filled in by `_roll_strategy_and_layout`). AIR personality skips
	# the second generator + advanced foundry entirely; its plan is
	# handled below.
	_try_place("generator", "res://resources/buildings/basic_generator.tres", _offset_for("generator", Vector3(15, 0, 10)))
	_try_place("foundry", "res://resources/buildings/basic_foundry.tres", _offset_for("foundry", Vector3(-15, 0, 10)))
	_try_place("salvage_yard", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard", Vector3(0, 0, 22)))

	# Phase 2+ — secondary buildings, ordered by archetype. The wave-
	# count gate that previously held back turrets / adv foundry until
	# `_wave_count >= 1` was the reason the player never saw the AI
	# build them: most matches don't last long enough for the AI to
	# complete a full attack-and-die cycle, and `_wave_count` only
	# increments at the END of a wave. Secondary buildings now queue
	# as soon as the basic three are placed, and the personality just
	# chooses the ORDER and which extras (turret / aerodrome / SAM)
	# come early. _try_place internally serialises through the single
	# engineer + the AI's salvage budget, so the calls below act as
	# a priority queue — the highest-priority unbuilt structure that
	# the AI can currently afford gets placed each tick.
	#
	# Aerodrome + SAM site were missing from every personality's plan
	# entirely, so the AI never built air or anti-air. Now wired in.
	match _strategy:
		Strategy.TURRET_HEAVY:
			# Defensive opener: three groups of three turrets at distinct
			# sites. Group A clusters at the AI's home (in front of HQ),
			# groups B and C deploy on opposite forward flanks far enough
			# away that the cluster kill-zones don't overlap (~50u apart
			# given the gun_emplacement's ~25u range), so each cluster
			# covers a different slice of the map and contests scattered
			# salvage targets instead of triple-stacking on one spot.
			# Group A — home cluster, tight 3-turret triangle in front of HQ.
			_try_place("turret_a1", _turret_path, _offset_for("turret_a", Vector3(0, 0, -14)))
			_try_place("turret_a2", _turret_path, _offset_for("turret_a", Vector3(0, 0, -14)) + Vector3(8, 0, -2))
			_try_place("turret_a3", _turret_path, _offset_for("turret_a", Vector3(0, 0, -14)) + Vector3(-8, 0, -2))
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_try_place("salvage_yard_2", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			# Group B — forward right cluster. Far enough from Group A
			# that the two range-circles don't kiss; protects the right-
			# flank lane / scrap-pile cluster.
			_try_place("turret_b1", _turret_path, _offset_for("turret_b", Vector3(35, 0, -45)))
			_try_place("turret_b2", _turret_path, _offset_for("turret_b", Vector3(35, 0, -45)) + Vector3(7, 0, -3))
			_try_place("turret_b3", _turret_path, _offset_for("turret_b", Vector3(35, 0, -45)) + Vector3(-3, 0, -7))
			_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", _offset_for("adv_foundry", Vector3(-22, 0, 18)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			# Group C — forward left cluster, mirror of B. Holds the
			# opposite flank so the AI's defensive footprint covers the
			# whole front.
			_try_place("turret_c1", _turret_path, _offset_for("turret_c", Vector3(-35, 0, -45)))
			_try_place("turret_c2", _turret_path, _offset_for("turret_c", Vector3(-35, 0, -45)) + Vector3(-7, 0, -3))
			_try_place("turret_c3", _turret_path, _offset_for("turret_c", Vector3(-35, 0, -45)) + Vector3(3, 0, -7))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place("salvage_yard_3", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
			_place_next_power_building("generator3", _offset_for("generator3", Vector3(28, 0, 8)))
		Strategy.ECONOMY_HEAVY:
			# Eco opener: 2nd generator + advanced foundry early,
			# then aerodrome (extra production), then defensive
			# structures. Uses the smart-power picker so the 3rd+
			# generator slots place Reactors instead of basic
			# generators. Salvage-yard cap raised to 5 (yard_2..5).
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", _offset_for("adv_foundry", Vector3(-22, 0, 18)))
			_try_place("salvage_yard_2", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place("salvage_yard_3", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
			_try_place("turret", _turret_path, _offset_for("turret", Vector3(0, 0, -14)))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_place_next_power_building("generator3", _offset_for("generator3", Vector3(28, 0, 8)))
			_try_place("salvage_yard_4", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_4", Vector3(-22, 0, 32)))
			_try_place("salvage_yard_5", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_5", Vector3(22, 0, 32)))
		Strategy.RUSH:
			# Aggressive: extra production fast (gen + adv foundry +
			# aerodrome for air rush), basic armory for branch
			# unlocks, then defensive structures.
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", _offset_for("adv_foundry", Vector3(-22, 0, 18)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_try_place("salvage_yard_2", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place("salvage_yard_3", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
		Strategy.AIR:
			# Air doctrine: ONLY one basic foundry (the starter),
			# then go straight into 2 aerodromes, THEN add a second
			# basic foundry as ground-defence backup. Never builds
			# advanced_foundry. Power + armoury still scale via the
			# generic helpers.
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place("aerodrome_2", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome_2", Vector3(-28, 0, -8)))
			_try_place("foundry_2", "res://resources/buildings/basic_foundry.tres", _offset_for("foundry_2", Vector3(0, 0, 14)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("salvage_yard_2", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("turret", _turret_path, _offset_for("turret", Vector3(0, 0, -14)))
			_try_place("salvage_yard_3", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
			_place_next_power_building("generator3", _offset_for("generator3", Vector3(28, 0, 8)))
		_:
			# BALANCED — covers everything in a stable order.
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("turret", _turret_path, _offset_for("turret", Vector3(0, 0, -14)))
			_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", _offset_for("adv_foundry", Vector3(-22, 0, 18)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("salvage_yard_2", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place("salvage_yard_3", "res://resources/buildings/salvage_yard.tres", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))

	# Dormant-attack safety net -- if we've had ANY combat units
	# for too long without launching an attack, push out now.
	if _force_attack_if_dormant():
		return
	if _state_timer >= ECONOMY_DURATION:
		_state = AIState.ARMY
		_state_timer = 0.0


func _process_army() -> void:
	# Maintain economy in parallel with army production — engineers + Crawler
	# keep working through the army-build state.
	_maintain_engineers()
	_maintain_crawlers()
	# Queue at every constructed friendly foundry, not just the
	# first basic + first advanced one tracked in _foundry /
	# _adv_foundry. With 2+ basic foundries (which the ally on a
	# big map naturally builds for parallel production), the older
	# code only fed the first one, leaving the rest idle and
	# salvage piling up uncollected. The wave_count >= 2 gate on
	# adv_foundry is gone too -- it never tripped for an ally
	# losing single units (wave_count only increments on a
	# completed attack), which kept the entire adv production
	# offline.
	for foundry: Node in _all_friendly_foundries():
		_try_queue_at(foundry)

	# Wave size pulls from the personality base, scaled by wave
	# count + aggression. Personality drives the OPENING wave size:
	# RUSH attacks with smaller waves earlier; ECONOMY_HEAVY masses
	# bigger pushes.
	var base_wave: float = float(_personality_wave_size_base() + _wave_count * 2) * _agg_mul
	var wave_size: int = maxi(int(round(base_wave)), 2)
	if _units.size() >= wave_size or _state_timer >= ARMY_DURATION / _agg_mul:
		_state = AIState.ATTACK
		_state_timer = 0.0
		_last_attack_clock_sec = _match_clock_sec
		return
	# Dormant-attack safety net -- if the army phase has dragged
	# on too long because attrition keeps the count below
	# wave_size, push with what we have.
	_force_attack_if_dormant()


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

	# Send attackers toward the chosen enemy HQ. Spread the actual attack-move
	# target across a small ring per unit so the squads don't all converge on
	# the exact same point and pile up at the navmesh entry — visible as
	# "huge clumps of units forming". Offsets are deterministic per unit
	# (instance_id-derived) so repeated re-issues don't slosh the squad.
	for n_idx: int in attack_units.size():
		var node: Node = attack_units[n_idx]
		if not is_instance_valid(node):
			continue
		var combat: Node = node.get_node_or_null("CombatComponent")
		if combat and combat.has_method("command_attack_move"):
			if combat.get("attack_move_target") == Vector3.INF:
				var seed_id: int = node.get_instance_id()
				var ring_angle: float = float(seed_id % 360) / 360.0 * TAU
				var ring_radius: float = 4.0 + float((seed_id / 7) % 8)  # 4..11u
				var spread: Vector3 = Vector3(cos(ring_angle), 0.0, sin(ring_angle)) * ring_radius
				combat.command_attack_move(_player_hq_pos + spread)

	# If most attackers are dead, rebuild
	if attack_units.size() <= 1:
		_wave_count += 1
		_state = AIState.REBUILD
		_state_timer = 0.0


func _process_rebuild() -> void:
	# Even during REBUILD the dormant safety net stays armed -- a
	# match where the AI keeps losing every wave shouldn't end up
	# with the AI passively rebuilding forever between attacks.
	if _force_attack_if_dormant():
		return
	if _state_timer >= REBUILD_DURATION:
		_state = AIState.ECONOMY
		_state_timer = 0.0


func _offset_for(key: String, fallback: Vector3) -> Vector3:
	## Returns the per-match jittered offset for `key`, or `fallback` if the
	## strategy roller didn't produce one (e.g. a key was added later and
	## `_roll_strategy_and_layout` doesn't know about it yet).
	if _building_offsets.has(key):
		return _building_offsets[key] as Vector3
	return fallback


func _ai_prerequisites_met(bstats: BuildingStatResource) -> bool:
	## True if every prerequisite building_id on `bstats` has at least one
	## fully-constructed instance owned by THIS AI player. Buildings still
	## under construction don't count — the player rule is the same, so
	## both sides chain through basic → advanced.
	if bstats.prerequisites.is_empty():
		return true
	var have: Dictionary = {}
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if "owner_id" in node and (node.get("owner_id") as int) != owner_id:
			continue
		if not node.get("is_constructed"):
			continue
		var stat: BuildingStatResource = node.get("stats") as BuildingStatResource
		if stat:
			have[stat.building_id] = true
	for req_v: Variant in bstats.prerequisites:
		var req: StringName = StringName(req_v)
		if not have.has(req):
			return false
	return true


func _place_next_power_building(key: String, offset: Vector3) -> void:
	## Smart power-building placer. Once the AI owns 2+ basic
	## generators (player rule: each must sit on a vent), every
	## subsequent power slot tries the Reactor (advanced_generator)
	## first since it puts more capacity per vent. Falls back to
	## basic_generator if the Reactor isn't reachable yet (no
	## prerequisites met) or no Reactor-eligible vent is free.
	## Skips entirely if `key` is already in `_buildings_placed`.
	if _buildings_placed.has(key):
		return
	var basic_count: int = _count_constructed("basic_generator")
	var reactor_path: String = "res://resources/buildings/advanced_generator.tres"
	if basic_count >= 2:
		var reactor_stats: BuildingStatResource = load(reactor_path) as BuildingStatResource
		# _try_place will quietly bail if the prereq chain isn't met
		# (Reactor needs basic_generator first, which is satisfied at
		# basic_count >= 2). If it fails for any other reason we'll
		# pick it up next tick instead of falling through.
		if reactor_stats and _ai_prerequisites_met(reactor_stats):
			_try_place(key, reactor_path, offset)
			if _buildings_placed.has(key):
				return
	# Default / fallback: basic generator on a vent.
	_try_place(key, "res://resources/buildings/basic_generator.tres", offset)


func _count_constructed(building_id: String) -> int:
	## Counts every constructed friendly building matching the given
	## building_id. Used by _place_next_power_building to switch from
	## basic generators to Reactors after the second generator lands.
	var bid: StringName = StringName(building_id)
	var n: int = 0
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue
		if not node.get("is_constructed"):
			continue
		var bstats: BuildingStatResource = node.get("stats") as BuildingStatResource
		if bstats and bstats.building_id == bid:
			n += 1
	return n


func _try_place(key: String, stats_path: String, offset: Vector3) -> void:
	if _buildings_placed.has(key):
		return
	var bstats: BuildingStatResource = load(stats_path) as BuildingStatResource
	if not bstats:
		return
	# Tech-tree gate: skip if any prerequisite isn't yet constructed.
	# Same rule the player follows, so the AI naturally chains through
	# basic_foundry → advanced_foundry → aerodrome instead of teleporting
	# straight to the late-tier structure.
	if not _ai_prerequisites_met(bstats):
		return
	# AI must afford the building, just like the player. _ai_resource_manager
	# handles the spending inside builder.place_building.
	if _ai_resource_manager and _ai_resource_manager.has_method("can_afford"):
		if not _ai_resource_manager.can_afford(bstats.cost_salvage, bstats.cost_fuel):
			return

	# AI now needs an engineer to build. If none are free, skip — the AI
	# will retry next tick (or after producing more engineers).
	var engineer: Node = _find_free_engineer()
	if not engineer:
		return

	# Geothermic-vent gate -- generators (basic + advanced) snap to the
	# nearest free vent that doesn't already host a generator. The
	# player follows the same rule (selection_manager enforces it via
	# requires_geothermic_vent), and the AI used to bypass it because
	# place_building doesn't re-check the gate. With this snap the AI
	# also chains correctly on bigger maps: when a vent near home is
	# taken, the picker walks outward to the next-closest free vent
	# that's nearer to OUR HQ than to any allied HQ — so we don't
	# steal the ally's expansion vent or sprint into hostile territory.
	var desired: Vector3 = _hq.global_position + offset
	if bstats.get("requires_geothermic_vent"):
		var vent_pos: Vector3 = _pick_free_generator_vent()
		if vent_pos == Vector3.INF:
			return  # No free vent right now; retry next tick.
		desired = vent_pos
	var pos: Vector3 = _find_clear_placement(desired, bstats.footprint_size)
	if pos == Vector3.INF:
		return  # retry next tick once the area clears
	# For vent-gated buildings, snapping to anything but the vent
	# centre invalidates the placement (selection_manager allows a
	# 1.4u tolerance). If _find_clear_placement spiralled too far,
	# bail and retry next tick.
	if bstats.get("requires_geothermic_vent") and pos.distance_to(desired) > 1.4:
		return
	# Symmetric vent keepout for non-generator buildings -- the AI
	# can't drop a foundry / yard / turret on or right next to a
	# vent, since that would block the generator that should later
	# go on that vent. Mirrors selection_manager's keepout rule.
	if not bstats.get("requires_geothermic_vent"):
		var vent_keepout: float = maxf(bstats.footprint_size.x, bstats.footprint_size.z) * 0.5 + 1.4
		if GeothermicVent.find_vent_at(get_tree().current_scene, pos, vent_keepout) != null:
			return
	# Plateau / ramp keepout. Building right at the foot of a ramp
	# wedges the AI's Crawlers + military between the building and
	# the slope, where pathing fails and units bounce / stall. Use
	# a wider keepout for plateaus (footprints are large) and a
	# tight keepout for hills (~footprint_half + 4u).
	if not bstats.get("requires_geothermic_vent"):
		var plat_keepout: float = maxf(bstats.footprint_size.x, bstats.footprint_size.z) * 0.5 + 4.0
		for plat: Node in get_tree().get_nodes_in_group("elevation"):
			if not is_instance_valid(plat):
				continue
			var p3: Node3D = plat as Node3D
			if not p3:
				continue
			if pos.distance_to(Vector3(p3.global_position.x, 0.0, p3.global_position.z)) < plat_keepout:
				return

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


func notify_pre_seeded_building(key: String, building: Node) -> void:
	## Called by scenario / campaign seeding paths that place a
	## ready-built base around the AI before _process starts. Marks
	## the matching `_buildings_placed` slot so the AI's normal build
	## flow doesn't try to re-place that structure on top, and points
	## the role-specific reference (`_generator`, `_foundry`, etc) at
	## the seeded building so production / power / yard tracking
	## treats it as if the AI had built it itself.
	if key == "" or not is_instance_valid(building):
		return
	_buildings_placed[key] = true
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
	# Don't pile up engineers in the queue; only request one at a time.
	if _hq.has_method("get_queue_size") and _hq.get_queue_size() > 0:
		return
	var engineer_stats: UnitStatResource = load(_engineer_path()) as UnitStatResource
	if not engineer_stats:
		return
	if not _ai_resource_manager:
		return
	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage < engineer_stats.cost_salvage:
		return
	# Queue first, spend only on success. queue_unit returns false when
	# the unit isn't in the HQ's faction-resolved producible list — for
	# example a Sable HQ rejecting an Anvil Ratchet — and pre-spending
	# would silently drain salvage every tick until the AI bankrupts.
	if _hq.queue_unit(engineer_stats):
		_ai_resource_manager.spend(engineer_stats.cost_salvage, engineer_stats.cost_fuel)


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
	# Queue first, spend only on success — same drain-prevention pattern
	# as _maintain_engineers. Crawler is currently in both factions'
	# rosters, but the defensive check costs nothing and inoculates
	# against future roster splits.
	if _hq.queue_unit(crawler_stats):
		_ai_resource_manager.spend(crawler_stats.cost_salvage, crawler_stats.cost_fuel)


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
func _try_contest_oil() -> void:
	## Strictly picks the nearest fuel deposit the AI doesn't own
	## (neutral OR enemy-held) and detaches a small attack-move
	## group to capture / contest it. Runs every OIL_CONTEST_INTERVAL
	## seconds with NO probabilistic skip and NO distance cap --
	## the AI should actively claim oil instead of waiting for it
	## to drop into its lap. The dispatch interval already throttles
	## how often we redirect units; per-tick variance there is enough.
	if not _hq or not is_instance_valid(_hq):
		return
	var hq_pos: Vector3 = _hq.global_position
	var deposits: Array[Node] = get_tree().get_nodes_in_group("fuel_deposits")
	if deposits.is_empty():
		return
	# Pure nearest-non-owned pick. No bonus for neutral over enemy-
	# held -- the player asked for 'nearest one we don't own',
	# capture-time difference is minor compared to lost income from
	# never claiming a contested field.
	var best: Node3D = null
	var best_dist: float = INF
	for d_node: Node in deposits:
		if not is_instance_valid(d_node):
			continue
		var dep: Node3D = d_node as Node3D
		if not dep:
			continue
		var dep_owner: int = (dep.get("owner_id") as int) if "owner_id" in dep else -1
		if dep_owner == owner_id:
			continue  # already ours
		var dist: float = hq_pos.distance_to(dep.global_position)
		if dist < best_dist:
			best_dist = dist
			best = dep
	if not best:
		return
	# Pick a small detachment from idle / non-engaged units. We don't
	# want to gut the main army, so cap to OIL_CONTEST_DETACHMENT_SIZE
	# and skip engineers.
	var detachment: Array[Node] = []
	for unit: Node in _units:
		if detachment.size() >= OIL_CONTEST_DETACHMENT_SIZE:
			break
		if not is_instance_valid(unit):
			continue
		if unit.has_method("get_builder") and unit.get("get_builder"):
			continue
		# Skip units that already have a forced attack target -- they're
		# busy. Pull from "available" pool instead.
		var c: Node = unit.get_node_or_null("CombatComponent")
		if c and c.get("forced_target"):
			continue
		detachment.append(unit)
	if detachment.is_empty():
		return
	for unit: Node in detachment:
		var combat: Node = unit.get_node_or_null("CombatComponent")
		if combat and combat.has_method("command_attack_move"):
			combat.command_attack_move(best.global_position)


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
		# Read the target through Variant + typeof so a freed Building
		# reference (queue_free'd but still cached on the builder) can't
		# crash the cast. `target_var is Object` raised
		# 'Left operand of "is" is a previously freed instance' on stale
		# Variant slots; typeof() operates on the Variant container
		# without dereferencing, then is_instance_valid is documented
		# safe on freed references. Treat freed targets as free-to-build.
		var target_var: Variant = builder.get("_target_building")
		if typeof(target_var) == TYPE_OBJECT and is_instance_valid(target_var):
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


func _pick_free_generator_vent() -> Vector3:
	## Returns the world position of the closest geothermic vent that
	## (a) doesn't already host one of our generators and
	## (b) sits closer to OUR HQ than to any allied HQ
	##     (so we don't poach the ally's expansion vent on shared maps).
	## Returns Vector3.INF when nothing qualifies — _try_place will
	## just retry next tick.
	if not is_instance_valid(_hq):
		return Vector3.INF
	var my_hq: Vector3 = _hq.global_position
	var ally_hq_positions: Array[Vector3] = _ally_hq_positions()
	var taken: Array[Vector3] = _existing_generator_positions()
	var best: Vector3 = Vector3.INF
	var best_dist: float = INF
	for node: Node in get_tree().get_nodes_in_group("geothermic_vents"):
		if not is_instance_valid(node):
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		var vp: Vector3 = n3.global_position
		# Skip vents that already have a generator on them (within
		# the same 1.4u tolerance the player gate uses).
		var occupied: bool = false
		for tp: Vector3 in taken:
			if vp.distance_to(tp) < 1.6:
				occupied = true
				break
		if occupied:
			continue
		# Don't pick vents that are closer to an allied HQ than to
		# ours — the ally should get those for their own expansion.
		var d_self: float = my_hq.distance_to(vp)
		var poach: bool = false
		for ahq: Vector3 in ally_hq_positions:
			if ahq.distance_to(vp) < d_self - 1.0:
				poach = true
				break
		if poach:
			continue
		if d_self < best_dist:
			best_dist = d_self
			best = vp
	return best


func _ally_hq_positions() -> Array[Vector3]:
	## Returns world positions of all friendly HQs other than ours.
	## Used by the vent picker to avoid stealing an ally's expansion vent.
	var out: Array[Vector3] = []
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if not registry or not registry.has_method("get_state"):
		return out
	var my_team: int = -1
	var my_state: Variant = registry.call("get_state", owner_id)
	if my_state and "team_id" in my_state:
		my_team = my_state.team_id as int
	if my_team < 0:
		return out
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var oid: int = node.get("owner_id") as int
		if oid == owner_id:
			continue
		var stats_v: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not stats_v or stats_v.building_id != &"headquarters":
			continue
		var st: Variant = registry.call("get_state", oid)
		if not st or not ("team_id" in st):
			continue
		if (st.team_id as int) != my_team:
			continue
		var b: Node3D = node as Node3D
		if b:
			out.append(b.global_position)
	return out


func _existing_generator_positions() -> Array[Vector3]:
	## Returns world positions of every constructed-or-being-built
	## generator owned by anyone -- vent picker avoids any vent that
	## already has one (regardless of owner; vents are exclusive).
	var out: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var stats_v: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not stats_v:
			continue
		if not stats_v.get("requires_geothermic_vent"):
			continue
		var b: Node3D = node as Node3D
		if b:
			out.append(b.global_position)
	return out


func _find_clear_placement(desired: Vector3, footprint: Vector3) -> Vector3:
	if _is_placement_clear(desired, footprint):
		return desired
	# Spiral search — expanding rings around the desired anchor. Step
	# bumped from 2.5u → 4.0u so adjacent rings actually clear the
	# wider PLACEMENT_GAP and the AI doesn't end up nestling buildings
	# right next to each other once the desired spot is taken.
	for ring: int in range(1, 8):
		for step: int in 12:
			var ang: float = float(step) / 12.0 * TAU
			var test_offset := Vector3(cos(ang), 0.0, sin(ang)) * float(ring) * 4.0
			var pos: Vector3 = desired + test_offset
			if _is_placement_clear(pos, footprint):
				return pos
	return Vector3.INF


## Required clear gap between adjacent buildings — keeps AI bases from looking
## visually packed and gives Crawlers room to drive out of the base. Wider
## than the player's BUILD_PLACEMENT_GAP because the AI's foundation grid is
## tighter and a Crawler that can't egress its spawn corner is dead weight.
## A Salvage Crawler is ~5 units wide; the gap needs to clear both half-widths
## of the neighbour buildings PLUS the Crawler's full width with breathing
## room, otherwise a freshly-spawned Crawler boxed between an Advanced Foundry
## and a Generator can't path around either of them. Bumped from 5.5 -> 9.0
## after a player report showing a Sable Crawler stuck against the HQ.
const PLACEMENT_GAP: float = 9.0


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


func _all_friendly_foundries() -> Array[Node]:
	## Returns every constructed basic_foundry / advanced_foundry /
	## aerodrome owned by us. Replaces the legacy _foundry +
	## _adv_foundry singleton tracking so a third / fourth foundry
	## the AI builds on bigger maps actually contributes to the
	## production budget instead of sitting idle while salvage piles
	## up. Aerodromes also produce units, so they queue through the
	## same path -- their producible list resolves to the aircraft
	## roster in Building._faction_producible_list, which our
	## faction-correct unit picker then queues from.
	var out: Array[Node] = []
	var production_ids: Array[StringName] = [&"basic_foundry", &"advanced_foundry", &"aerodrome"]
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue
		if not node.get("is_constructed"):
			continue
		var bstats: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not bstats:
			continue
		if bstats.building_id in production_ids:
			out.append(node)
	return out


func _try_queue_at(foundry_node: Node) -> void:
	if not foundry_node or not is_instance_valid(foundry_node):
		return
	if not foundry_node.get("is_constructed"):
		return
	if not foundry_node.has_method("get_queue_size"):
		return
	if foundry_node.get_queue_size() >= 2:
		return
	# Use the foundry's OWN producibility list as the source of
	# truth -- this resolves through Building._faction_producible_list
	# so a Sable adv_foundry returns Harbinger / Pulsefont, an Anvil
	# basic returns Rook / Hound, an Aerodrome returns aircraft, etc.
	# Avoids the previous trap where the AI hardcoded Rook+Hound for
	# every foundry kind and adv_foundry / aerodrome silently
	# rejected 80% of attempts (no spend, but a wasted tick + a
	# silent 'why isn't the AI building anything').
	var roster: Array = []
	if foundry_node.has_method("get_producible_units"):
		roster = foundry_node.call("get_producible_units")
	if roster.is_empty():
		return
	# Strategy + foundry-kind weighting. Heavies live at adv tier
	# (Bulwark, Forgemaster); the basic tier is light/medium only.
	# The picker's job here is just 'roll within the foundry's
	# actual roster' -- we no longer try to fish a Bulwark out of
	# a basic foundry that never had one.
	var foundry_stats: BuildingStatResource = foundry_node.get("stats") as BuildingStatResource
	var foundry_id: StringName = foundry_stats.building_id if foundry_stats else &""
	var unit_stats: UnitStatResource = _pick_unit_for_foundry(roster, foundry_id)
	if not unit_stats:
		return
	# Affordability gate. The AI doesn't reserve population (player
	# does), so we only check salvage / fuel here. Pop overflow
	# affects the player but the AI has its own resource manager.
	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage < unit_stats.cost_salvage:
		return
	var fuel: int = _ai_resource_manager.get("fuel")
	if fuel < unit_stats.cost_fuel:
		return
	# Queue first, spend only on success — see _maintain_engineers
	# for the drain-prevention rationale.
	if foundry_node.queue_unit(unit_stats):
		_ai_resource_manager.spend(unit_stats.cost_salvage, unit_stats.cost_fuel)


func _pick_unit_for_foundry(roster: Array, foundry_id: StringName) -> UnitStatResource:
	## Picks a unit from the foundry's actual producible list,
	## weighted by strategy. roster[0] is treated as the
	## light/scout option, roster[1] as the medium/main, roster[2+]
	## as heavies/specialists. With aerodrome (3+ entries -- bomber,
	## escort, drone) the heavies bucket folds the late-tier
	## variants together so the AI doesn't fixate on one frame.
	if roster.is_empty():
		return null
	# Drop locked entries (tech-gated units the AI hasn't unlocked
	# yet would queue-reject and waste the tick). get_producible_units
	# already filters these in the building, but be defensive.
	var available: Array[UnitStatResource] = []
	for r: Variant in roster:
		var u: UnitStatResource = r as UnitStatResource
		if u:
			available.append(u)
	if available.is_empty():
		return null
	# Weights by index slot (0 = light, 1 = medium, 2+ = heavy/spec)
	# blended with the AI's strategy. RUSH spams the cheapest slot;
	# ECONOMY / TURRET lean into the heaviest available.
	var w_light: int = 5
	var w_med: int = 3
	var w_heavy: int = 2
	match _strategy:
		Strategy.TURRET_HEAVY:
			w_light = 2; w_med = 4; w_heavy = 4
		Strategy.RUSH:
			w_light = 7; w_med = 3; w_heavy = 0
		Strategy.ECONOMY_HEAVY:
			w_light = 3; w_med = 5; w_heavy = 2
	# Aerodrome / advanced foundry should bias heavier; basic stays
	# light-led.
	if foundry_id == &"advanced_foundry" or foundry_id == &"aerodrome":
		w_light = 0
		w_med = 5
		w_heavy = 5
	var total: int = w_light + w_med + w_heavy
	if total <= 0:
		return available[0]
	var roll: int = randi() % total
	var bucket: int = 0
	if roll < w_light:
		bucket = 0
	elif roll < w_light + w_med:
		bucket = 1
	else:
		bucket = 2
	# Map bucket onto the actual roster, clamping to roster size.
	var idx: int = mini(bucket, available.size() - 1)
	return available[idx]
