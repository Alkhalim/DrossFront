class_name AIController
extends Node
## AI opponent with varied behavior: builds economy, mixed army, defends and attacks.

enum AIState { SETUP, ECONOMY, ARMY, ATTACK, REBUILD }

@export var owner_id: int = 1

var _state: AIState = AIState.SETUP
var _state_timer: float = 0.0
var _wave_count: int = 0

var _hq: Node = null
## Scene-level singletons cached on first need. The AI tick fetches
## PlayerRegistry (and a few others) from many helper functions each
## 5 Hz tick; profiling showed those scene-tree lookups adding up
## even though each call is individually cheap. The helpers route
## through `_get_registry()` so the lookup happens once and gets
## reused for the rest of the match.
var _registry_cached: Node = null
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

## Passive salvage trickle. Pulled 15.0 -> 5.0 to MATCH the player's
## ResourceManager.HQ_SALVAGE_TRICKLE -- the AI used to pile up income
## 3x the player's rate at the same _econ_mul, which felt like a
## stealth resource cheat regardless of what the difficulty setting
## advertised. Now HARD (_econ_mul = 1.0) really is 1.0x with no
## hidden bonus; NORMAL / EASY scale below via the difficulty
## multiplier.
const AI_SALVAGE_TRICKLE: float = 5.0
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
## Hard cap on how long the AI is allowed to stay in ATTACK before
## forcibly transitioning to REBUILD. Without this the state could
## stick indefinitely when 2-3 surviving attackers got wedged on
## terrain or stalled on the navmesh -- the size <= 1 exit
## condition only fires after attrition takes them all out, which
## never happens for a stuck idler. 75s is generous enough for a
## successful push to land its hits but tight enough that a stalled
## one resets the loop within a wave-and-a-half.
const ATTACK_MAX_DURATION: float = 75.0
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

## Counter-training bookkeeping. Rebuilt each AI tick from the
## current scene-wide enemy unit list. Maps armor_class
## (StringName) -> count. When the most-common class accounts
## for >50% of >= COUNTER_MIN_SEEN units, _pick_unit_for_foundry
## flips to a 75/25 weighted choice favouring the AI's best
## counter to that armor class.
const COUNTER_MIN_SEEN: int = 4
const COUNTER_FOCUS_PROB: float = 0.75
var _enemy_armor_counts: Dictionary = {}
var _enemy_total_seen: int = 0

## Production-building cadence gate. Each new foundry / aerodrome
## placement increments _production_buildings_built; each
## successful military-unit queue increments _military_units_trained.
## A new production building is only allowed when trained_count
## >= placed_count * PRODUCTION_BUILDING_TRAINING_GATE so the AI
## can't carpet the base with foundries before fielding any army.
const PRODUCTION_BUILDING_TRAINING_GATE: int = 2
var _production_buildings_built: int = 0
var _military_units_trained: int = 0
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

## --- Debug harness state ---------------------------------------------
## Surface points the AIDebugOverlay reads via get_debug_snapshot(). All
## off-by-default behaviour is gated on the overlay's own DEBUG_HARNESS_
## ENABLED const; the controller always tracks the values so toggling the
## overlay back on doesn't require any other change. Costs are negligible.
enum BuildBlocker {
	NONE,
	RESOURCE_LOAD_FAIL,
	PREREQ_NOT_MET,
	PRODUCTION_GATE,
	CANT_AFFORD,
	NO_ENGINEER,
	NO_FREE_VENT,
	NO_CLEAR_SPOT,
	VENT_SNAP_TOO_FAR,
	VENT_KEEPOUT,
	NEAR_PLATEAU,
}
## Most recent un-placed building plan + why it didn't go down this tick.
## Captured for the FIRST not-yet-placed `_try_place` call that hit a
## blocker per tick (priority order), so the overlay shows the highest-
## priority pending build, not the lowest.
var _next_build_key: String = ""
var _next_build_blocker: int = BuildBlocker.NONE
var _blocker_captured_this_tick: bool = false
## Most recent successful placement -- shown in the debug overlay
## alongside the next-blocked entry so the user can see what the
## AI just did, not only what it can't do.
var _last_placed_key: String = ""
var _last_placed_clock_sec: float = -INF
## Cumulative kill / loss tallies surfaced by the overlay. Both update
## via squad_destroyed signal connections that we attach lazily in
## _track_unit_lifecycle().
var _kills: int = 0
var _losses: int = 0
## Map of unit instance_id -> "ally" / "enemy" so we know which counter
## to bump when squad_destroyed fires.
var _tracked_units: Dictionary = {}


func _enter_tree() -> void:
	add_to_group("ai_controllers")
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


func _get_registry() -> Node:
	## Lazy cache for PlayerRegistry. The AI's per-tick helpers used
	## to fetch this from the scene tree on every call (a dozen
	## scene-traversals per 5 Hz tick); the cache reduces that to
	## one lookup per match.
	if _registry_cached and is_instance_valid(_registry_cached):
		return _registry_cached
	if not get_tree():
		return null
	_registry_cached = get_tree().current_scene.get_node_or_null("PlayerRegistry")
	return _registry_cached


func _resolve_my_faction(settings: Node) -> int:
	## Mirrors test_arena_controller._faction_for_player so the AI
	## resolves its own faction the same way the spawner does — checks
	## the per-AI override first, then falls back to team-based default
	## (team 0 = ally → player_faction; team 1 = enemy → enemy_faction).
	if not settings:
		return 0
	if settings.has_method("has_ai_faction") and settings.call("has_ai_faction", owner_id):
		return settings.call("get_ai_faction", owner_id) as int
	var registry: Node = _get_registry()
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
	## Resource cheating cap: HARD now plays on equal economy with
	## the player (1.0x trickle, no bonus salvage / fuel). The AI's
	## challenge has to come from how well it USES its income, not
	## from outright income bonuses. Lower difficulties scale below
	## 1.0 so the AI starves a bit more visibly. Intentionally
	## slower than the player on EASY so an inexperienced player
	## isn't crushed by raw resource volume.
	match d:
		0: return 0.55  # EASY
		2: return 1.0   # HARD -- no resource cheat
		_: return 0.80  # NORMAL


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
	var registry: Node = _get_registry()
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
	var registry: Node = _get_registry()
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

	# Passive income — matched to the player's HQ trickle (5/sec) and
	# scaled by difficulty's economy multiplier. HARD is now genuinely
	# 1.0x with no hidden bonus; NORMAL (0.80) and EASY (0.55) scale
	# below. Fuel is NOT trickled here -- the player has to capture
	# deposits to gain fuel, so the AI does too. Removing the AI's
	# free fuel drip closes the last "stealth income" gap; the AI's
	# active _try_contest_oil dispatch already grabs deposits, so an
   	# AI that's playing well stays fuel-positive without the cheat.
	if _ai_resource_manager and _ai_resource_manager.has_method("add_salvage"):
		_salvage_accumulator += AI_SALVAGE_TRICKLE * _econ_mul * delta
		if _salvage_accumulator >= 1.0:
			var trickle: int = int(_salvage_accumulator)
			_salvage_accumulator -= float(trickle)
			_ai_resource_manager.add_salvage(trickle)

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
	# Refresh the enemy-composition tally for counter training.
	_refresh_enemy_armor_counts()
	# Wire kill / loss tracking onto any newly seen units (debug harness).
	_track_unit_lifecycle()
	# Snapshot engineer pool states for the overlay. Done up here so
	# the overlay reads a clean tick-time view, decoupled from the
	# downstream _try_place / _find_free_engineer calls which can
	# change individual engineer states (start_building sets
	# _target_building) within a single tick.
	_refresh_engineer_diagnostics()
	# Reset the per-tick "first blocked build" capture so each tick starts
	# fresh. Cleared up here, populated by _try_place's early-returns below.
	_blocker_captured_this_tick = false

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

	# Hard-difficulty target composition runs in every state so
	# the late-game expansion keeps adding production / power
	# even while the AI is mid-attack or rebuilding. Calls early-
	# out on already-placed keys so the cost is just a counter
	# scan when the targets are met.
	if _difficulty_is_hard() and _state != AIState.SETUP:
		_try_hard_target_composition()
		# Salvage-cap dump: Hard AIs that pile up resources beyond
		# HARD_SALVAGE_CAP must spend the surplus on a combat unit
		# at the first idle foundry / advanced foundry / aerodrome
		# they own. Prevents the late-game "AI is sitting on 5000
		# salvage" pattern that reads as the AI not knowing what
		# to do with itself.
		_dump_excess_salvage_into_units()

	# Idle-yard reaper. Demolishes any of our salvage yards that
	# haven't taken a worker delivery in IDLE_YARD_TIMEOUT_SEC --
	# usually because the surrounding wreck pile dried up. Stops
	# late-game power drain from yards that are paying upkeep
	# without producing anything.
	if _state != AIState.SETUP:
		_reap_idle_salvage_yards()
	# Threat response. Rallies nearby idle units when enemies are
	# inside our HQ defence radius or pressing one of our
	# buildings -- runs in every state except SETUP so the AI
	# defends itself even mid-attack.
	if _state != AIState.SETUP:
		_check_threat_response()


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
			_try_place_salvage_yard("salvage_yard_2", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
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
			_try_place_salvage_yard("salvage_yard_3", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
			_place_next_power_building("generator3", _offset_for("generator3", Vector3(28, 0, 8)))
		Strategy.ECONOMY_HEAVY:
			# Eco opener: 2nd generator + advanced foundry early,
			# then aerodrome (extra production), then defensive
			# structures. Uses the smart-power picker so the 3rd+
			# generator slots place Reactors instead of basic
			# generators. Salvage-yard cap raised to 5 (yard_2..5).
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", _offset_for("adv_foundry", Vector3(-22, 0, 18)))
			_try_place_salvage_yard("salvage_yard_2", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place_salvage_yard("salvage_yard_3", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
			_try_place("turret", _turret_path, _offset_for("turret", Vector3(0, 0, -14)))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_place_next_power_building("generator3", _offset_for("generator3", Vector3(28, 0, 8)))
			_try_place_salvage_yard("salvage_yard_4", _offset_for("salvage_yard_4", Vector3(-22, 0, 32)))
			_try_place_salvage_yard("salvage_yard_5", _offset_for("salvage_yard_5", Vector3(22, 0, 32)))
		Strategy.RUSH:
			# Aggressive: extra production fast (gen + adv foundry +
			# aerodrome for air rush), basic armory for branch
			# unlocks, then defensive structures.
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", _offset_for("adv_foundry", Vector3(-22, 0, 18)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_try_place_salvage_yard("salvage_yard_2", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place_salvage_yard("salvage_yard_3", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
		Strategy.AIR:
			# Air doctrine: ONLY one basic foundry (the starter),
			# then go straight into 2 aerodromes, THEN add a second
			# basic foundry as ground-defence backup. Never builds
			# advanced_foundry. First aerodrome comes BEFORE basic
			# armory so Phalanx drones (no tech gate) start
			# producing ~75s into the match instead of waiting on
			# the armory's ~50s build first. Adv armory still in
			# the chain so Hammerhead unlocks for the second wave.
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place("aerodrome_2", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome_2", Vector3(-28, 0, -8)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place("foundry_2", "res://resources/buildings/basic_foundry.tres", _offset_for("foundry_2", Vector3(0, 0, 14)))
			_try_place_salvage_yard("salvage_yard_2", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("turret", _turret_path, _offset_for("turret", Vector3(0, 0, -14)))
			_try_place_salvage_yard("salvage_yard_3", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))
			_place_next_power_building("generator3", _offset_for("generator3", Vector3(28, 0, 8)))
			_place_next_power_building("generator4", _offset_for("generator4", Vector3(-28, 0, 8)))
		_:
			# BALANCED — covers everything in a stable order.
			_place_next_power_building("generator2", _offset_for("generator2", Vector3(22, 0, 18)))
			_try_place("turret", _turret_path, _offset_for("turret", Vector3(0, 0, -14)))
			_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", _offset_for("adv_foundry", Vector3(-22, 0, 18)))
			_try_place("basic_armory", "res://resources/buildings/basic_armory.tres", _offset_for("basic_armory", Vector3(18, 0, -4)))
			_try_place_salvage_yard("salvage_yard_2", _offset_for("salvage_yard_2", Vector3(-12, 0, 28)))
			_try_place("aerodrome", "res://resources/buildings/aerodrome.tres", _offset_for("aerodrome", Vector3(28, 0, -8)))
			_try_place("sam_site", "res://resources/buildings/sam_site.tres", _offset_for("sam_site", Vector3(0, 0, -22)))
			_try_place("advanced_armory", "res://resources/buildings/advanced_armory.tres", _offset_for("advanced_armory", Vector3(-18, 0, -4)))
			_try_place_salvage_yard("salvage_yard_3", _offset_for("salvage_yard_3", Vector3(12, 0, 28)))

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

	# Build the attacker list. Two filters layer on the standard
	# 'engineers stay home' rule:
	#
	# (a) Any unit currently inside HQ_RALLY_RADIUS of our HQ
	#     stays put. This keeps freshly-produced reinforcements
	#     massed at the foundry rally point instead of getting
	#     trickled forward one at a time the moment they spawn
	#     during an ATTACK -- they'll join the next wave when
	#     the ARMY->ATTACK transition picks them up. The
	#     previous DEFENDERS=2 cap let only the first two close
	#     units stay; #3+ got pushed forward immediately.
	# (b) Units already attacking (forced or attack-move target
	#     set) are still funnelled toward the enemy HQ so they
	#     keep pressing the front, regardless of where they are.
	const HQ_RALLY_RADIUS: float = 35.0
	var attack_units: Array[Node] = []
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if node.has_method("get_builder") and node.get_builder():
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		var dist_to_hq: float = n3.global_position.distance_to(_hq.global_position)
		var combat: Node = node.get_node_or_null("CombatComponent")
		var already_attacking: bool = false
		if combat:
			var amt: Variant = combat.get("attack_move_target")
			already_attacking = typeof(amt) == TYPE_VECTOR3 and (amt as Vector3) != Vector3.INF
			if not already_attacking:
				var ft: Variant = combat.get("forced_target")
				already_attacking = typeof(ft) == TYPE_OBJECT and is_instance_valid(ft)
		if dist_to_hq < HQ_RALLY_RADIUS and not already_attacking:
			# Reinforcement still rallying near the base; leave it
			# alone for the next wave.
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

	# Exit ATTACK when one of three things is true:
	#   1. Only one (or zero) attacker is left -- the wave is spent.
	#   2. ATTACK has been running too long -- the survivors are
	#      stuck on terrain or otherwise non-productive; cycle back
	#      to REBUILD so the AI can mass up again instead of sitting
	#      on a dead push.
	#   3. No attacker is anywhere near the enemy HQ AND the state
	#      has been going long enough for them to have arrived --
	#      catches the "wave got bullied off course and is wandering"
	#      pattern that wouldn't trip the size threshold but also
	#      isn't actually attacking.
	var stuck_too_long: bool = _state_timer >= ATTACK_MAX_DURATION
	var no_progress: bool = false
	if not stuck_too_long and _state_timer >= 25.0 and _player_hq_pos != Vector3.ZERO:
		var any_close: bool = false
		for u: Node in attack_units:
			if not is_instance_valid(u):
				continue
			if (u as Node3D).global_position.distance_to(_player_hq_pos) < 50.0:
				any_close = true
				break
		no_progress = not any_close
	if attack_units.size() <= 1 or stuck_too_long or no_progress:
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


func _refresh_enemy_armor_counts() -> void:
	## Walks every alive enemy unit (any owner that isn't ours and
	## isn't an ally per PlayerRegistry) and tallies them by
	## armor_class. Stored on _enemy_armor_counts so the
	## counter-training pick can read it without re-walking the
	## scene per foundry per tick.
	_enemy_armor_counts.clear()
	_enemy_total_seen = 0
	var registry: Node = _get_registry()
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var node_owner: int = (node.get("owner_id") as int) if "owner_id" in node else 0
		if node_owner == owner_id:
			continue
		var hostile: bool = true
		if registry and registry.has_method("are_enemies"):
			hostile = registry.call("are_enemies", owner_id, node_owner)
		if not hostile:
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var stats_v: UnitStatResource = node.get("stats") as UnitStatResource
		if not stats_v:
			continue
		var armor: StringName = stats_v.armor_class
		_enemy_armor_counts[armor] = (_enemy_armor_counts.get(armor, 0) as int) + 1
		_enemy_total_seen += 1


func _dominant_enemy_armor() -> StringName:
	## Returns the armor_class accounting for >50% of seen enemies
	## when at least COUNTER_MIN_SEEN have been observed. Empty
	## StringName means no clear dominant class -- the picker
	## falls back to the normal weighted choice.
	if _enemy_total_seen < COUNTER_MIN_SEEN:
		return &""
	@warning_ignore("integer_division")
	var threshold: int = int(_enemy_total_seen / 2) + 1  # > 50%
	for k_v: Variant in _enemy_armor_counts.keys():
		var k: StringName = k_v as StringName
		if (_enemy_armor_counts[k_v] as int) >= threshold:
			return k
	return &""


func _best_counter_in_roster(roster: Array, target_armor: StringName) -> UnitStatResource:
	## Picks the unit in the roster whose primary weapon yields the
	## highest get_role_mult_for(target_armor). Tiebreaker is roster
	## order. Returns null if the roster is empty.
	var best: UnitStatResource = null
	var best_mult: float = -1.0
	for r: Variant in roster:
		var u: UnitStatResource = r as UnitStatResource
		if not u or not u.primary_weapon:
			continue
		var m: float = u.primary_weapon.get_role_mult_for(target_armor)
		if m > best_mult:
			best_mult = m
			best = u
	return best


func _is_production_building_id(bid: StringName) -> bool:
	return bid == &"basic_foundry" or bid == &"advanced_foundry" or bid == &"aerodrome"


func _difficulty_is_hard() -> bool:
	## Returns true when this AI's difficulty is HARD. The target-
	## composition phase only runs on Hard so easy / normal AIs stay
	## intentionally less productive.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.has_method("get_ai_difficulty"):
		return (settings.get_ai_difficulty(owner_id) as int) == 2
	return false


func _count_constructed_owned(building_ids: Array[StringName]) -> int:
	## Counts buildings owned by us whose stats.building_id is in
	## `building_ids`. Includes in-progress + constructed. Used by
	## the hard-target composition phase to decide which slots are
	## still missing.
	var n: int = 0
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.stats:
			continue
		if b.owner_id != owner_id:
			continue
		if building_ids.has(b.stats.building_id):
			n += 1
	return n


## --- Hard-difficulty target composition --------------------------------
## Hard's target composition (per the design spec):
##   Minimum (mid-game): >=3 production facilities, basic armory,
##                       >=2 generators, >=1 reactor.
##   Late game:          5-7 production facilities, 5 energy
##                       buildings (any mix of generators + reactors).
## Late-game kicks in when the match has been running >= 6 minutes
## AND the AI has launched at least one attack wave -- before that
## the archetype's curated plan is doing its job. Padding builds use
## unique keys (pad_*) so they don't collide with the archetype's
## entries; the existing _buildings_placed dedup keeps each pad
## attempted only once per match.

const HARD_PROD_MIN: int = 3
const HARD_PROD_LATE_MIN: int = 5
const HARD_PROD_LATE_MAX: int = 7
const HARD_GEN_MIN: int = 2
const HARD_REACTOR_MIN: int = 1
const HARD_ENERGY_LATE_MIN: int = 5
const HARD_LATE_GAME_CLOCK_SEC: float = 360.0  # 6 minutes


func _try_hard_target_composition() -> void:
	## Tops up production / energy / armory slots beyond what the
	## archetype plan placed. Runs every AI tick; each individual
	## _try_place call early-outs on already-placed keys so the
	## cost is a few group walks when targets are met.
	if not is_instance_valid(_hq):
		return
	var prod_count: int = _count_constructed_owned([&"basic_foundry", &"advanced_foundry", &"aerodrome"])
	var basic_gen_count: int = _count_constructed_owned([&"basic_generator"])
	var reactor_count: int = _count_constructed_owned([&"advanced_generator"])
	var energy_count: int = basic_gen_count + reactor_count
	var has_basic_armory: bool = _count_constructed_owned([&"basic_armory"]) > 0
	var late_game: bool = _match_clock_sec >= HARD_LATE_GAME_CLOCK_SEC and _wave_count >= 1

	# --- Mid-game minimums (always applied on Hard) ---
	# Basic Armory -- ensure even archetypes that defer the
	# armory eventually get one. The standard build plan's key
	# is "basic_armory"; we use a separate "pad_armory" so this
	# call doesn't conflict if the archetype already queued the
	# canonical key.
	if not has_basic_armory:
		_try_place("pad_armory", "res://resources/buildings/basic_armory.tres",
			_offset_for("basic_armory", Vector3(18, 0, -4)))

	# Production minimum: pad up to HARD_PROD_MIN if the archetype
	# left us short. Round-robin between basic_foundry / adv_foundry
	# / aerodrome based on what's already lowest in the mix.
	var prod_targets: int = HARD_PROD_LATE_MAX if late_game else HARD_PROD_MIN
	if prod_count < prod_targets:
		_try_place_pad_production(prod_count, prod_targets)

	# Energy minimum: at least HARD_GEN_MIN basic generators + 1
	# reactor, then in late game pad to HARD_ENERGY_LATE_MIN total.
	# _place_next_power_building auto-picks reactor when 2+ basic
	# generators are already up, so threading more pad calls just
	# means more total energy.
	var energy_target: int = HARD_ENERGY_LATE_MIN if late_game else (HARD_GEN_MIN + HARD_REACTOR_MIN)
	if energy_count < energy_target:
		_try_place_pad_energy(energy_count, energy_target)


func _try_place_pad_production(current: int, target: int) -> void:
	## Drops one extra production facility per missing slot. The
	## offsets cycle around the base ring so successive pads don't
	## stack on top of each other; _find_clear_placement spirals out
	## from each anchor.
	const PAD_RING_RADIUS: float = 24.0
	var pad_offsets: Array[Vector3] = [
		Vector3(0, 0, -22),
		Vector3(22, 0, 0),
		Vector3(0, 0, 22),
		Vector3(-22, 0, 0),
	]
	var paths: Array[String] = [
		"res://resources/buildings/basic_foundry.tres",
		"res://resources/buildings/advanced_foundry.tres",
		"res://resources/buildings/aerodrome.tres",
	]
	for i: int in range(current, target):
		var key: String = "pad_prod_%d" % i
		if _buildings_placed.has(key):
			continue
		var off: Vector3 = pad_offsets[i % pad_offsets.size()]
		# Push out a touch with the ring radius so successive pads
		# don't overlap each other's anchor points.
		off += Vector3(cos(float(i) * 1.7) * 4.0, 0.0, sin(float(i) * 1.7) * 4.0).normalized() * PAD_RING_RADIUS * 0.0
		var path: String = paths[i % paths.size()]
		_try_place(key, path, _offset_for(key, off))


## --- Idle-yard reaper -------------------------------------------------
## Salvage yards keep their power upkeep regardless of throughput, so a
## yard that's outlived its surrounding wreck pile silently drains the
## AI's energy grid in the late game. Track each yard's most recent
## delivery (stamped by salvage_worker on dock) and queue a demolish
## call once it's been silent for IDLE_YARD_TIMEOUT_SEC.
const IDLE_YARD_TIMEOUT_SEC: float = 150.0  # 2.5 minutes
## Grace window after a yard finishes construction before the reaper
## even considers it -- a freshly-placed yard hasn't had time to send
## workers and dock a delivery yet, so we'd otherwise demolish it on
## the first AI tick.
const IDLE_YARD_GRACE_SEC: float = 90.0


func _reap_idle_salvage_yards() -> void:
	## Walks our salvage yards and demolishes any whose
	## last_delivery_msec was longer than IDLE_YARD_TIMEOUT_SEC ago.
	## Buildings without a recorded delivery use their construction
	## complete time + IDLE_YARD_GRACE_SEC as the deadline.
	var now_msec: int = Time.get_ticks_msec()
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
		# Skip yards still being built; the reaper only acts on
		# operational yards.
		if "is_constructed" in b and not (b.get("is_constructed") as bool):
			continue
		var last_msec: int = b.get_meta("last_delivery_msec", -1) as int
		var deadline_msec: int = -1
		if last_msec >= 0:
			deadline_msec = last_msec + int(IDLE_YARD_TIMEOUT_SEC * 1000.0)
		else:
			# Never delivered. Use the yard's existence age via the
			# spawn-time meta the building stamps in _ready, falling
			# back to a one-time grace mark we set here so the timer
			# starts ticking from now if there's nothing else.
			var spawn_msec: int = b.get_meta("ai_spawn_msec", -1) as int
			if spawn_msec < 0:
				spawn_msec = now_msec
				b.set_meta("ai_spawn_msec", spawn_msec)
			deadline_msec = spawn_msec + int((IDLE_YARD_GRACE_SEC + IDLE_YARD_TIMEOUT_SEC) * 1000.0)
		if now_msec < deadline_msec:
			continue
		_demolish_yard(b)


func _demolish_yard(yard: Building) -> void:
	## Drops a yard. Calls take_damage with its remaining HP so the
	## standard collapse path runs (wreck spawn + power recompute +
	## navmesh rebake). Done over manual queue_free so the player
	## sees a real demolition rather than a silent vanish.
	if not yard or not is_instance_valid(yard):
		return
	# Free up the AI's _buildings_placed key so a future yard can
	# claim that slot. Walk the dictionary in case the same yard
	# was registered under multiple keys (rare, but possible from
	# scenario-seeding paths).
	var node_iid: int = yard.get_instance_id()
	for k_v: Variant in _buildings_placed.keys().duplicate():
		var k: String = k_v as String
		# We don't store node refs in _buildings_placed -- it's
		# string keys only. A salvage yard's keys are
		# 'salvage_yard', 'salvage_yard_2', etc. Free them all so
		# the AI can re-place; the wreck blocks the spot for a
		# few seconds either way.
		if k.begins_with("salvage_yard") or k.begins_with("pad_") and k.find("yard") >= 0:
			_buildings_placed.erase(k)
	if yard.has_method("take_damage"):
		var hp_v: Variant = yard.get("current_hp")
		var hp: int = (hp_v as int) if typeof(hp_v) == TYPE_INT else 1
		yard.take_damage(maxi(hp, 1), null)
	else:
		yard.queue_free()
	# Suppress the unused warning by referencing iid (kept for
	# future-extension where we might dedupe demolish calls).
	var _iid: int = node_iid


func _try_place_pad_energy(current: int, target: int) -> void:
	## Drops one extra power building per missing slot.
	## _place_next_power_building flips to Reactor automatically
	## once 2+ basic generators are up, so the pads naturally
	## become reactors in late-game once the basic-gen quota is
	## met. A blocked vent falls through to the next-closest one
	## via the buildable-vent picker.
	var pad_offsets: Array[Vector3] = [
		Vector3(28, 0, 8),
		Vector3(-28, 0, 8),
		Vector3(28, 0, -8),
		Vector3(-28, 0, -8),
		Vector3(0, 0, 28),
	]
	for i: int in range(current, target):
		var key: String = "pad_energy_%d" % i
		if _buildings_placed.has(key):
			continue
		var off: Vector3 = pad_offsets[i % pad_offsets.size()]
		_place_next_power_building(key, _offset_for(key, off))


func _try_place_salvage_yard(key: String, offset: Vector3) -> void:
	## Wraps _try_place for salvage yards with two gates:
	##   (a) ROI: at least 150 salvage worth of reachable wrecks
	##       within ~30u of the placement spot, so the yard isn't
	##       dropped on dead map terrain.
	##   (b) Power efficiency: skip when our yards would already be
	##       running at <= 65% productivity from the existing power
	##       deficit. A new yard adds workers (and worker upkeep)
	##       to a brownout grid; we'd burn 100 salvage on a
	##       structure that returns next-to-nothing until the AI
	##       fixes the deficit by placing more generators.
	if _buildings_placed.has(key):
		return
	# Compute the candidate world position we'd actually place at
	# (HQ-relative offset, like _try_place does) so the ROI scan
	# matches what the player sees.
	if not is_instance_valid(_hq):
		return
	# Power-efficiency gate.
	if _ai_resource_manager and _ai_resource_manager.has_method("get_power_efficiency"):
		var eff: float = _ai_resource_manager.call("get_power_efficiency") as float
		if eff < 0.65:
			# Tag the blocker so the debug overlay can surface
			# 'training gate' style feedback for low power.
			_record_blocker(key, BuildBlocker.PRODUCTION_GATE)
			return
	var anchor: Vector3 = _hq.global_position + offset
	const YARD_HARVEST_SCAN_RADIUS: float = 30.0
	const YARD_ROI_THRESHOLD: int = 150
	var nearby_salvage: int = 0
	for w_node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(w_node):
			continue
		var w3: Node3D = w_node as Node3D
		if not w3:
			continue
		if anchor.distance_to(w3.global_position) > YARD_HARVEST_SCAN_RADIUS:
			continue
		var sv: int = (w_node.get("salvage_remaining") as int) if "salvage_remaining" in w_node else 0
		nearby_salvage += sv
		if nearby_salvage >= YARD_ROI_THRESHOLD:
			break
	if nearby_salvage < YARD_ROI_THRESHOLD:
		return
	_try_place(key, "res://resources/buildings/salvage_yard.tres", offset)


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
		_record_blocker(key, BuildBlocker.RESOURCE_LOAD_FAIL)
		return
	# Tech-tree gate: skip if any prerequisite isn't yet constructed.
	# Same rule the player follows, so the AI naturally chains through
	# basic_foundry → advanced_foundry → aerodrome instead of teleporting
	# straight to the late-tier structure.
	if not _ai_prerequisites_met(bstats):
		_record_blocker(key, BuildBlocker.PREREQ_NOT_MET)
		return
	# Production-building cadence gate: the AI can't carpet the
	# base with foundries / aerodromes before fielding any army.
	# Each new production building requires PRODUCTION_BUILDING_TRAINING_GATE
	# combat units to have been queued since the previous one.
	# The very first production building (the starter foundry)
	# falls through because _production_buildings_built starts at
	# 0 and the gate compares 0 >= 0 * 2.
	if _is_production_building_id(bstats.building_id):
		if _military_units_trained < _production_buildings_built * PRODUCTION_BUILDING_TRAINING_GATE:
			_record_blocker(key, BuildBlocker.PRODUCTION_GATE)
			return
	# AI must afford the building, just like the player. _ai_resource_manager
	# handles the spending inside builder.place_building.
	if _ai_resource_manager and _ai_resource_manager.has_method("can_afford"):
		if not _ai_resource_manager.can_afford(bstats.cost_salvage, bstats.cost_fuel):
			_record_blocker(key, BuildBlocker.CANT_AFFORD)
			return

	# AI now needs an engineer to build. If none are free, skip — the AI
	# will retry next tick (or after producing more engineers).
	var engineer: Node = _find_free_engineer()
	if not engineer:
		_record_blocker(key, BuildBlocker.NO_ENGINEER)
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
	# Per-building vent keepout. Non-generator buildings keep a
	# unit-corridor's worth of distance (+6u) from any vent so the
	# AI base doesn't crowd vents and lock itself out of future
	# Reactor upgrades. Generators don't have a keepout (their
	# centre IS the vent). Pre-computed here so the placement
	# search below honours it.
	var vent_keepout_radius: float = 0.0
	if not bstats.get("requires_geothermic_vent"):
		vent_keepout_radius = maxf(bstats.footprint_size.x, bstats.footprint_size.z) * 0.5 + 6.0

	var desired: Vector3 = _hq.global_position + offset
	if bstats.get("requires_geothermic_vent"):
		# For vent-gated buildings: pick the CLOSEST buildable vent.
		# _find_buildable_generator_vent walks all vents in distance
		# order and returns the first one whose footprint is clear,
		# so a blocked nearby vent automatically falls through to a
		# slightly farther one that works.
		var vent_pos: Vector3 = _find_buildable_generator_vent(bstats.footprint_size, bstats.building_id)
		if vent_pos == Vector3.INF:
			_record_blocker(key, BuildBlocker.NO_FREE_VENT)
			return  # No buildable vent right now; retry next tick.
		desired = vent_pos
	# Find a clear placement near `desired`. The vent_keepout_radius
	# is honoured by the spiral search itself, so a non-generator
	# building whose desired anchor sits next to a vent will spiral
	# OUT to clear ground rather than failing the post-check the
	# old code did. candidate_id flows through so energy-vs-energy
	# pairs can sit closer than the standard PLACEMENT_GAP allows
	# (the starter vent pair is intentionally 10u apart).
	var pos: Vector3 = _find_clear_placement(desired, bstats.footprint_size, vent_keepout_radius, bstats.building_id)
	if pos == Vector3.INF:
		# Distinguish "vent area was the only blocker" from "nothing
		# was clear" by re-running once with the keepout off; if
		# THAT succeeds, the vent keepout is what blocked us so the
		# overlay can surface VENT_KEEPOUT instead of NO_CLEAR_SPOT.
		if vent_keepout_radius > 0.0:
			var fallback_pos: Vector3 = _find_clear_placement(desired, bstats.footprint_size, 0.0, bstats.building_id)
			if fallback_pos != Vector3.INF:
				_record_blocker(key, BuildBlocker.VENT_KEEPOUT)
				return
		_record_blocker(key, BuildBlocker.NO_CLEAR_SPOT)
		return  # retry next tick once the area clears
	# For vent-gated buildings, snapping to anything but the vent
	# centre invalidates the placement (selection_manager allows a
	# 1.4u tolerance). If _find_clear_placement spiralled too far,
	# bail and retry next tick.
	if bstats.get("requires_geothermic_vent") and pos.distance_to(desired) > 1.4:
		_record_blocker(key, BuildBlocker.VENT_SNAP_TOO_FAR)
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
				_record_blocker(key, BuildBlocker.NEAR_PLATEAU)
				return
	# Map-edge clamp -- mirrors the player's check in
	# selection_manager._is_valid_build_position. AI used to hand
	# the engineer a build site whose footprint clipped past the
	# playable area, which left the engineer trying to path to a
	# point the navmesh ends short of (engineer wedged against
	# the edge forever). Reject any candidate position whose
	# half-extent crosses the +/- 150u boundary.
	const MAP_HALF_FOR_AI: float = 150.0
	const AI_EDGE_MARGIN: float = 1.5
	var bx_h: float = bstats.footprint_size.x * 0.5
	var bz_h: float = bstats.footprint_size.z * 0.5
	if pos.x - bx_h < -MAP_HALF_FOR_AI + AI_EDGE_MARGIN \
			or pos.x + bx_h > MAP_HALF_FOR_AI - AI_EDGE_MARGIN \
			or pos.z - bz_h < -MAP_HALF_FOR_AI + AI_EDGE_MARGIN \
			or pos.z + bz_h > MAP_HALF_FOR_AI - AI_EDGE_MARGIN:
		_record_blocker(key, BuildBlocker.NO_CLEAR_SPOT)
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
	# Track the most-recent successful placement so the debug
	# overlay can show "Last placed: X (Ns ago)" alongside the
	# "Next build: Y (blocker)" line. Without this the overlay
	# can read as inaccurate: 'next build' shows a permanently-
	# blocked entry like generator2 even while several other
	# builds (yards, turrets) succeed in the same minute.
	_last_placed_key = key
	_last_placed_clock_sec = _match_clock_sec
	# Production-building cadence counter -- bumped after a
	# successful place so the gate above blocks the NEXT one
	# until enough units are trained.
	if _is_production_building_id(bstats.building_id):
		_production_buildings_built += 1

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
	## Keep three USABLE Ratchet engineers alive. The cap counts only
	## engineers actually available for placement -- garrisoned ones
	## (riding inside a transport) are excluded so a fully-loaded
	## Courier Tank doesn't trick the cap into thinking the AI is
	## fully staffed when no engineer can actually break ground.
	##
	## Queueing priority is tiered by urgency so the HQ doesn't sit
	## on a Crawler build while the AI has zero engineers:
	##   count == 0  -> ALWAYS queue regardless of HQ queue state
	##                  (engineer goes in even if a Crawler is
	##                  already mid-build behind it).
	##   count <  2  -> queue alongside other items in the HQ queue.
	##   count <  3  -> only queue when the HQ queue is empty so we
	##                  don't crowd out tactical Crawler / starter-
	##                  unit production for a third utility unit.
	if not is_instance_valid(_hq) or not _hq.get("is_constructed"):
		return
	var usable_engineer_count: int = 0
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if not (node.has_method("get_builder") and node.get_builder()):
			continue
		# Garrisoned engineers can't reach build sites -- exclude
		# them from the staffing count so an engineer riding inside
		# a Courier Tank doesn't lock the AI out of replenishing.
		var garrisoned_var: Variant = node.get("_garrisoned_in") if "_garrisoned_in" in node else null
		if typeof(garrisoned_var) == TYPE_OBJECT and is_instance_valid(garrisoned_var):
			continue
		usable_engineer_count += 1
	if usable_engineer_count >= 3:
		return
	# Tiered queueing -- urgency drops the empty-queue gate when
	# the AI is critically understaffed.
	var queue_size: int = _hq.get_queue_size() if _hq.has_method("get_queue_size") else 0
	if usable_engineer_count == 0:
		pass  # Always queue when we have none -- urgent.
	elif usable_engineer_count < 2:
		# Allow queueing alongside one other item, not a deep stack.
		if queue_size >= 2:
			return
	else:
		# Topping up to 3: wait for the queue to clear so we don't
		# crowd out tactical production.
		if queue_size > 0:
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
## Per-crawler aggregated escort HP tracker. Maps crawler iid ->
## summed HP across its escort units last AI tick. Compared each
## tick to detect "an escort took damage" so the retreat / defender
## dispatch logic treats hits on escorts the same as hits on the
## chassis.
var _crawler_escort_last_hp: Dictionary = {}
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

		# Escort attacks count as attacks on the Crawler itself.
		# Walks the recorded escort ids for THIS crawler, sums their
		# total HP, compares to last tick. Any drop -> stamp the
		# damage-at timestamp so the retreat / defender-dispatch
		# logic treats it the same way as a direct hit on the
		# chassis. Cheap (escorts capped at 1-3 units per crawler).
		var escort_total_hp: int = 0
		var current_escort_ids: Array = _crawler_escorts.get(iid, []) as Array
		for esc_id_v: Variant in current_escort_ids:
			var esc_id: int = esc_id_v as int
			var esc_node: Node = instance_from_id(esc_id) as Node
			if not esc_node or not is_instance_valid(esc_node):
				continue
			# Use the unit's per-member HP sum if available, falling
			# back to current_hp for single-cell units. Both fields
			# decrement on damage.
			if "member_hp" in esc_node:
				for h_v: Variant in (esc_node.get("member_hp") as Array):
					escort_total_hp += h_v as int
			elif "current_hp" in esc_node:
				escort_total_hp += esc_node.get("current_hp") as int
		var prev_escort_hp_v: Variant = _crawler_escort_last_hp.get(iid, -1)
		var prev_escort_hp: int = (prev_escort_hp_v as int) if typeof(prev_escort_hp_v) == TYPE_INT else escort_total_hp
		if prev_escort_hp >= 0 and escort_total_hp < prev_escort_hp:
			_crawler_last_damage_at[iid] = now
		_crawler_escort_last_hp[iid] = escort_total_hp

		var anchored: bool = node.has_method("is_anchored") and node.is_anchored()
		var under_fire: bool = (now - (_crawler_last_damage_at.get(iid, -999.0) as float)) < CRAWLER_RETREAT_WINDOW

		# Escort assignment -- the Crawler always travels with N
		# nearby combat units depending on difficulty (Easy 1,
		# Normal 2, Hard 3). Re-checked every shepherd tick so
		# casualties are replaced from the available pool.
		_assign_crawler_escort(node as Node3D)

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


## Per-Crawler escort assignments. Keyed by Crawler instance id;
## value is an Array[int] of escort unit instance ids that this
## Crawler currently 'owns'. Cleared / refilled per shepherd
## tick so dead escorts get replaced from the available pool.
var _crawler_escorts: Dictionary = {}
## Per-escort "still engaged" timestamps. Maps escort instance_id ->
## match_clock_sec at which the escort's combat-lock expires. Refreshed
## each tick the escort has a live combat target; once its target dies
## or breaks line of sight we keep the lock for ESCORT_COMBAT_GRACE_SEC
## so a brief target swap doesn't yank the escort back into formation
## mid-fight.
const ESCORT_COMBAT_GRACE_SEC: float = 7.0
var _escort_combat_lock_until: Dictionary = {}
## Crawler stuck-detection for escort displacement. Tracks each
## crawler's last-recorded position + the match-clock sec it was
## first seen there. When the crawler stays inside a 1.5u radius for
## CRAWLER_STUCK_NUDGE_SEC, the escort logic pushes its escorts
## OUT of the comfort band (50% beyond ESC_MAX) so the crawler has
## space to manoeuvre. Cleared once the crawler moves again.
const CRAWLER_STUCK_RADIUS: float = 1.5
const CRAWLER_STUCK_NUDGE_SEC: float = 5.0
var _crawler_stuck_anchor: Dictionary = {}        # crawler iid -> Vector3
var _crawler_stuck_since_sec: Dictionary = {}     # crawler iid -> match_clock


func _crawler_escort_count() -> int:
	## Difficulty-driven escort size. Easy 1, Normal 2, Hard 3.
	## Mirrors the AiDifficulty enum mapping used by _econ_mul.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.has_method("get_ai_difficulty"):
		var d: int = settings.get_ai_difficulty(owner_id)
		match d:
			0: return 1  # EASY
			2: return 3  # HARD
			_: return 2  # NORMAL
	return 2


func _assign_crawler_escort(crawler: Node3D) -> void:
	## Ensures the Crawler always travels with `_crawler_escort_count`
	## non-engineer combat units. Scans the AI's available unit pool
	## (skipping engineers + units already locked into another
	## Crawler escort) and pulls the nearest ones into a follow
	## order on this Crawler's position. Re-issued every shepherd
	## tick so the Crawler's escort updates as it moves and
	## casualties are replaced.
	if not is_instance_valid(crawler):
		return
	var target_count: int = _crawler_escort_count()
	if target_count <= 0:
		return
	var iid: int = crawler.get_instance_id()
	# Filter the existing escort list to surviving units only.
	var current_ids: Array = _crawler_escorts.get(iid, []) as Array
	var alive_escorts: Array[Node] = []
	var alive_ids: Array[int] = []
	for esc_id_v: Variant in current_ids:
		var esc_id: int = esc_id_v as int
		var esc: Node = instance_from_id(esc_id) as Node
		if not esc or not is_instance_valid(esc):
			continue
		if "alive_count" in esc and (esc.get("alive_count") as int) <= 0:
			continue
		alive_escorts.append(esc)
		alive_ids.append(esc_id)
	# Top up if we lost escorts.
	if alive_escorts.size() < target_count:
		# Build the set of unit ids currently committed to ANY
		# Crawler escort so we don't poach an escort from another
		# Crawler.
		var taken_ids: Dictionary = {}
		for crawler_id_v: Variant in _crawler_escorts.keys():
			var ids_v: Array = _crawler_escorts[crawler_id_v] as Array
			for tid_v: Variant in ids_v:
				taken_ids[tid_v as int] = true
		var crawler_pos: Vector3 = crawler.global_position
		# Collect candidates: own non-engineer units, not already
		# escorting, sorted by distance to the Crawler.
		var candidates: Array[Dictionary] = []
		for unit: Node in _units:
			if not is_instance_valid(unit):
				continue
			if unit.has_method("get_builder") and unit.get_builder():
				continue  # skip engineers / builders
			if unit.is_in_group("crawlers"):
				continue
			var uid: int = unit.get_instance_id()
			if taken_ids.has(uid):
				continue
			candidates.append({
				"unit": unit,
				"d": crawler_pos.distance_to((unit as Node3D).global_position),
			})
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return (a["d"] as float) < (b["d"] as float)
		)
		for cand: Dictionary in candidates:
			if alive_escorts.size() >= target_count:
				break
			var u: Node = cand["unit"] as Node
			alive_escorts.append(u)
			alive_ids.append(u.get_instance_id())
	# Issue follow orders only when escorts drift OUT of a
	# comfortable distance band [ESC_MIN, ESC_MAX] from the
	# crawler. Inside the band the escort is left to its own
	# combat / idle behaviour so it doesn't constantly chase a
	# moving target point and clip into the crawler. Outside
	# the band, attack-move to a ring-position at the band's
	# midpoint so the escort eases back into formation.
	#
	# Combat-lock override: an escort with an active combat
	# target (or one whose last-known target died within
	# ESCORT_COMBAT_GRACE_SEC ago) is left alone regardless
	# of distance. The previous logic would yank an attacker-
	# chasing escort back into formation as soon as it crossed
	# ESC_MAX, which made the convoys 'glance and disengage'
	# instead of finishing fights.
	# Comfort-band radii. Each bumped 50% from the original
	# 4..11 spread so escorts stand farther off the chassis by
	# default, leaving the crawler more room to navigate. The
	# stuck-displacement override below pushes escorts out
	# even further when the crawler can't make progress.
	const ESC_MIN_DIST: float = 6.0
	const ESC_MAX_DIST: float = 16.5
	const ESC_REASSIGN_DIST: float = (ESC_MIN_DIST + ESC_MAX_DIST) * 0.5  # ~11.25u
	const ESC_STUCK_PUSH: float = ESC_MAX_DIST * 1.5  # ~24.75u
	var crawler_pos2: Vector3 = crawler.global_position
	# Crawler stuck-detection: if the chassis hasn't moved more
	# than CRAWLER_STUCK_RADIUS in CRAWLER_STUCK_NUDGE_SEC, we
	# clear the comfort band entirely and push escorts out to
	# ESC_STUCK_PUSH so the crawler has space. Cleared once the
	# chassis moves again.
	var crawler_stuck: bool = false
	var anchor_v: Variant = _crawler_stuck_anchor.get(iid, null)
	if typeof(anchor_v) == TYPE_VECTOR3:
		var anchor: Vector3 = anchor_v as Vector3
		var moved: float = Vector2(crawler_pos2.x - anchor.x, crawler_pos2.z - anchor.z).length()
		if moved > CRAWLER_STUCK_RADIUS:
			# Reset anchor + timer; chassis is mobile.
			_crawler_stuck_anchor[iid] = crawler_pos2
			_crawler_stuck_since_sec[iid] = _match_clock_sec
		else:
			var since: float = _crawler_stuck_since_sec.get(iid, _match_clock_sec) as float
			if _match_clock_sec - since >= CRAWLER_STUCK_NUDGE_SEC:
				crawler_stuck = true
	else:
		_crawler_stuck_anchor[iid] = crawler_pos2
		_crawler_stuck_since_sec[iid] = _match_clock_sec
	for esc_i: int in alive_escorts.size():
		var esc_unit: Node = alive_escorts[esc_i]
		if not is_instance_valid(esc_unit):
			continue
		var combat: Node = esc_unit.get_node_or_null("CombatComponent") as Node
		if not combat or not combat.has_method("command_attack_move"):
			continue
		var esc_iid: int = esc_unit.get_instance_id()
		# Refresh the combat-lock as long as the escort has a
		# live target. The lock decays to ESCORT_COMBAT_GRACE_SEC
		# the moment the last target goes invalid -- after that
		# window the escort accepts rejoin orders again.
		var live_target: bool = false
		var t_var: Variant = combat.get("_current_target")
		if typeof(t_var) == TYPE_OBJECT and is_instance_valid(t_var):
			var tnode: Node = t_var as Node
			var t_alive: bool = true
			if "alive_count" in tnode:
				t_alive = (tnode.get("alive_count") as int) > 0
			if t_alive:
				live_target = true
		if live_target:
			_escort_combat_lock_until[esc_iid] = _match_clock_sec + ESCORT_COMBAT_GRACE_SEC
		var lock_until: float = _escort_combat_lock_until.get(esc_iid, 0.0) as float
		if _match_clock_sec < lock_until:
			# Escort is mid-engagement (or within the 7s grace
			# after its last target died / went out of sight).
			# Leave it alone so it can finish the fight before
			# we rope it back into formation.
			continue
		var d_to_crawler: float = (esc_unit as Node3D).global_position.distance_to(crawler_pos2)
		if crawler_stuck:
			# Chassis has been wedged for CRAWLER_STUCK_NUDGE_SEC.
			# Kick this escort outward to ESC_STUCK_PUSH so the
			# crawler has manoeuvring room. Skip if the escort is
			# already past the push radius.
			if d_to_crawler < ESC_STUCK_PUSH:
				var ang_s: float = float(esc_i) / float(maxi(target_count, 1)) * TAU
				var ring_s: Vector3 = Vector3(cos(ang_s), 0.0, sin(ang_s)) * ESC_STUCK_PUSH
				combat.command_attack_move(crawler_pos2 + ring_s)
			continue
		if d_to_crawler >= ESC_MIN_DIST and d_to_crawler <= ESC_MAX_DIST:
			# Inside the comfort band. Don't churn its current
			# move/combat order -- if it's busy fighting an
			# attacker it should stay there.
			continue
		# Outside the band -- pick a ring-position at the band's
		# midpoint and send the escort to soft-rejoin.
		var ang: float = float(esc_i) / float(maxi(target_count, 1)) * TAU
		var ring: Vector3 = Vector3(cos(ang), 0.0, sin(ang)) * ESC_REASSIGN_DIST
		var post: Vector3 = crawler_pos2 + ring
		combat.command_attack_move(post)
	_crawler_escorts[iid] = alive_ids


func _dispatch_crawler_defenders(crawler_pos: Vector3) -> void:
	## Find the nearest enemy (likely the attacker) within CRAWLER_DEFENSE_SCAN_RADIUS
	## of the Crawler's position, then send every non-engineer AI unit
	## within CRAWLER_DEFENDER_DRAW_RADIUS at that target via attack-move.
	## Engineers stay home so the base keeps building. Attack-move means
	## defenders engage anything they pass on the way too — fine, that's
	## the threat's escort.
	var registry: Node = _get_registry()
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


## Threat-response: rallies nearby idle AI units when own buildings or
## the HQ are under threat. Runs every AI tick. Two scan stages:
##   (1) Enemies within HQ_DEFENSE_RADIUS of our HQ -- standing
##       harassers in the home base.
##   (2) Enemies within BUILDING_DEFENSE_RADIUS of any owned building --
##       a turret push, a yard raid, an aerodrome poke etc.
## Each detected threat dispatches non-engineer non-escort idle units
## within DEFENSE_DRAW_RADIUS to attack-move on the threat. Engineers
## keep building; crawler escorts keep escorting; everything else
## counter-attacks.
const HQ_DEFENSE_RADIUS: float = 35.0
const BUILDING_DEFENSE_RADIUS: float = 18.0
const DEFENSE_DRAW_RADIUS: float = 60.0
const DEFENSE_DISPATCH_PER_THREAT: int = 4
## Throttle (msec) per threat position so the dispatcher doesn't
## re-issue the same attack-move every tick. Keyed by quantized
## XZ position so a moving threat re-fires a dispatch when it
## drifts to a new cell.
var _threat_dispatch_at_msec: Dictionary = {}


func _check_threat_response() -> void:
	if not is_instance_valid(_hq):
		return
	var registry: Node = _get_registry()
	var hq_pos: Vector3 = _hq.global_position
	var hq_radius_sq: float = HQ_DEFENSE_RADIUS * HQ_DEFENSE_RADIUS
	var bldg_radius_sq: float = BUILDING_DEFENSE_RADIUS * BUILDING_DEFENSE_RADIUS
	# Pre-collect own buildings so we don't walk the buildings group
	# once per enemy in the inner loop.
	var own_buildings: Array[Vector3] = []
	for b_node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(b_node):
			continue
		if b_node.get("owner_id") != owner_id:
			continue
		# Skip damaged-out / unfinished buildings? Both still count
		# -- a half-built foundation under attack should still rally
		# defenders.
		own_buildings.append((b_node as Node3D).global_position)
	# Scan hostile units once. For each one, check whether they're
	# inside the HQ radius OR within building radius of any of our
	# buildings; if so, fire a dispatch at their position.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var n_owner: int = (node.get("owner_id") as int) if "owner_id" in node else -1
		if n_owner == owner_id:
			continue
		var hostile: bool = (
			registry.are_enemies(owner_id, n_owner)
			if registry and registry.has_method("are_enemies")
			else n_owner != owner_id
		)
		if not hostile:
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var enemy_pos: Vector3 = (node as Node3D).global_position
		var threat: bool = enemy_pos.distance_squared_to(hq_pos) < hq_radius_sq
		if not threat:
			for b_pos: Vector3 in own_buildings:
				if enemy_pos.distance_squared_to(b_pos) < bldg_radius_sq:
					threat = true
					break
		if not threat:
			continue
		_dispatch_threat_response(enemy_pos)


func _dispatch_threat_response(threat_pos: Vector3) -> void:
	## Fires up to DEFENSE_DISPATCH_PER_THREAT non-engineer non-escort
	## idle units at the threat position. Throttled per-position so
	## we don't keep re-issuing the same attack-move every tick.
	var key: String = "%d_%d" % [int(threat_pos.x / 6.0), int(threat_pos.z / 6.0)]
	var now_msec: int = Time.get_ticks_msec()
	var next_at_msec: int = (_threat_dispatch_at_msec.get(key, 0) as int)
	if now_msec < next_at_msec:
		return
	# Build the set of units currently locked into a Crawler escort
	# so the threat dispatcher doesn't poach them.
	var taken: Dictionary = {}
	for esc_ids_v: Variant in _crawler_escorts.values():
		var esc_ids: Array = esc_ids_v as Array
		for tid_v: Variant in esc_ids:
			taken[tid_v as int] = true
	var dispatched: int = 0
	for node: Node in _units:
		if dispatched >= DEFENSE_DISPATCH_PER_THREAT:
			break
		if not is_instance_valid(node):
			continue
		# Skip engineers (let them keep building) and escorts
		# (their crawler still needs them).
		if node.has_method("get_builder") and node.get_builder():
			continue
		var iid: int = node.get_instance_id()
		if taken.has(iid):
			continue
		var d: float = (node as Node3D).global_position.distance_to(threat_pos)
		if d > DEFENSE_DRAW_RADIUS:
			continue
		var combat: Node = node.get_node_or_null("CombatComponent")
		if combat and combat.has_method("command_attack_move"):
			combat.command_attack_move(threat_pos)
			dispatched += 1
	# Throttle this threat-cell for ~3s so the dispatch stays
	# stable. A fresh enemy in a different cell still fires its own
	# dispatch immediately.
	if dispatched > 0:
		_threat_dispatch_at_msec[key] = now_msec + 3000


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
		# Skip engineers. The previous check called .get("get_builder")
		# (property lookup) instead of .get_builder() (method call),
		# which always returned null -- engineers were silently being
		# pulled into the oil-contest detachment, gutting the build
		# pool. Method call now actually filters them out.
		if unit.has_method("get_builder") and unit.get_builder():
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
	var registry: Node = _get_registry()
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
	var registry: Node = _get_registry()
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


## Per-tick engineer pool diagnostic. Refreshed once per AI tick via
## _refresh_engineer_diagnostics() so the overlay reflects the current
## moment, NOT the last _try_place call's view. Counts each engineer's
## state: total alive, busy on a real build site, busy repairing,
## garrisoned (riding inside a transport), moving (walking with no
## active build target -- usually transient), or idle.
var _engineer_total: int = 0
var _engineer_idle: int = 0
var _engineer_busy_build: int = 0
var _engineer_busy_repair: int = 0
var _engineer_garrisoned: int = 0
var _engineer_moving: int = 0


func _refresh_engineer_diagnostics() -> void:
	## Snapshot the engineer pool's per-state counts ONCE at the top
	## of each AI tick. Previously the counters were updated as a
	## side-effect of _find_free_engineer, which ran multiple times
	## per tick (once per _try_place call) and left the overlay
	## reading the LAST call's state -- by then, earlier successful
	## placements had already locked engineers into _target_building,
	## so a "no free engineer" blocker captured at one call could
	## coexist with a stale "2 idle" overlay reading from a later
	## call where new builds had completed mid-tick.
	##
	## Now the counter is a clean per-tick snapshot read straight off
	## each engineer's current state, decoupled from the placement
	## flow. The "moving" classification covers an engineer that has
	## a unit-level move order but no builder target -- usually
	## transient (just-finished build heading home, or stuck-rescue
	## reset) but called out so the user can see it explicitly.
	_engineer_total = 0
	_engineer_idle = 0
	_engineer_busy_build = 0
	_engineer_busy_repair = 0
	_engineer_garrisoned = 0
	_engineer_moving = 0
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
		_engineer_total += 1
		# Garrisoned: physically inside a transport, can't break
		# ground until disembarked.
		var garrisoned_var: Variant = node.get("_garrisoned_in") if "_garrisoned_in" in node else null
		if typeof(garrisoned_var) == TYPE_OBJECT and is_instance_valid(garrisoned_var):
			_engineer_garrisoned += 1
			continue
		# Build-locked: builder has a live, unfinished _target_building.
		var target_var: Variant = builder.get("_target_building")
		var target_alive: bool = typeof(target_var) == TYPE_OBJECT and is_instance_valid(target_var)
		if target_alive:
			var target_node: Node = target_var as Node
			if target_node and not target_node.get("is_constructed"):
				_engineer_busy_build += 1
				continue
		# Repair-locked: BuilderComponent's auto-repair holds a
		# valid _repair_target while it's healing.
		var repair_var: Variant = builder.get("_repair_target") if "_repair_target" in builder else null
		var repair_alive: bool = typeof(repair_var) == TYPE_OBJECT and is_instance_valid(repair_var)
		if repair_alive:
			_engineer_busy_repair += 1
			continue
		# Moving: unit has a move order but no builder target. Usually
		# transient (just finished a build and walking home) and the
		# engineer IS available for placement (the AI's command_move
		# in start_building will overwrite the destination).
		var move_target_v: Variant = node.get("move_target") if "move_target" in node else null
		var has_move_order: bool = typeof(move_target_v) == TYPE_VECTOR3 and (move_target_v as Vector3) != Vector3.INF
		if has_move_order:
			_engineer_moving += 1
			continue
		_engineer_idle += 1


func _find_free_engineer() -> Node:
	## Returns the first AI engineer (Ratchet) eligible for a new
	## build assignment. Eligibility tiers, in priority order:
	##   1. Idle (no target, no move order).
	##   2. Moving (has move order but no target -- finishing or
	##      retreating; safe to redirect).
	##   3. Repairing (has _repair_target -- placement preempts
	##      auto-repair so the base keeps growing).
	## Excluded: garrisoned engineers (can't break ground inside
	## a transport) and engineers with a live unfinished target
	## building (genuinely committed to a build).
	##
	## NOTE: this function does NOT update the diagnostic counters
	## any more -- those are refreshed once per AI tick via
	## _refresh_engineer_diagnostics so the overlay reflects current
	## state instead of the last-call's stale state.
	var idle_pick: Node = null
	var moving_pick: Node = null
	var repair_pick: Node = null
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
		var garrisoned_var: Variant = node.get("_garrisoned_in") if "_garrisoned_in" in node else null
		if typeof(garrisoned_var) == TYPE_OBJECT and is_instance_valid(garrisoned_var):
			continue
		var target_var: Variant = builder.get("_target_building")
		if typeof(target_var) == TYPE_OBJECT and is_instance_valid(target_var):
			var target_node: Node = target_var as Node
			if target_node and not target_node.get("is_constructed"):
				continue
		var repair_var: Variant = builder.get("_repair_target") if "_repair_target" in builder else null
		if typeof(repair_var) == TYPE_OBJECT and is_instance_valid(repair_var):
			if repair_pick == null:
				repair_pick = node
			continue
		var move_target_v: Variant = node.get("move_target") if "move_target" in node else null
		var has_move_order: bool = typeof(move_target_v) == TYPE_VECTOR3 and (move_target_v as Vector3) != Vector3.INF
		if has_move_order:
			if moving_pick == null:
				moving_pick = node
			continue
		if idle_pick == null:
			idle_pick = node
	if idle_pick:
		return idle_pick
	if moving_pick:
		return moving_pick
	return repair_pick


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
	## Legacy single-best-vent picker -- preserved for any caller
	## that doesn't need a buildability check (e.g. the build-plan
	## offset calculator). New placement code should call
	## _find_buildable_generator_vent which falls through to the
	## next-closest vent when the closest is blocked.
	var sorted: Array[Vector3] = _list_eligible_vents_sorted()
	if sorted.is_empty():
		return Vector3.INF
	return sorted[0]


func _find_buildable_generator_vent(footprint: Vector3, candidate_id: StringName = &"basic_generator") -> Vector3:
	## Returns the closest eligible vent whose 1.4u-radius placement
	## footprint is currently clear of obstacles. Walks vents in
	## ascending distance from our HQ so a blocked nearby vent
	## automatically falls through to the next-closest one rather
	## than failing the whole placement attempt this tick. The 1.4u
	## tolerance matches selection_manager._is_valid_build_position
	## -- a generator must snap to its vent's centre to register.
	## candidate_id is forwarded to _is_placement_clear so the
	## relaxed energy-vs-energy spacing applies (the second starter
	## vent sits 10u from the first, inside the standard
	## PLACEMENT_GAP rejection threshold).
	var sorted: Array[Vector3] = _list_eligible_vents_sorted()
	for vp: Vector3 in sorted:
		if _is_placement_clear(vp, footprint, 0.0, candidate_id):
			return vp
	return Vector3.INF


func _list_eligible_vents_sorted() -> Array[Vector3]:
	## Vents we're allowed to claim, sorted ascending by distance to
	## our HQ. "Eligible" = not currently occupied by any generator
	## AND closer to our HQ than to any allied HQ (so we don't poach
	## the ally's expansion vent on shared maps).
	var out: Array[Vector3] = []
	if not is_instance_valid(_hq):
		return out
	var my_hq: Vector3 = _hq.global_position
	var ally_hq_positions: Array[Vector3] = _ally_hq_positions()
	var taken: Array[Vector3] = _existing_generator_positions()
	var with_dist: Array[Dictionary] = []
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
		with_dist.append({"pos": vp, "d": d_self})
	with_dist.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["d"] as float) < (b["d"] as float)
	)
	for entry: Dictionary in with_dist:
		out.append(entry["pos"] as Vector3)
	return out


func _ally_hq_positions() -> Array[Vector3]:
	## Returns world positions of all friendly HQs other than ours.
	## Used by the vent picker to avoid stealing an ally's expansion vent.
	var out: Array[Vector3] = []
	var registry: Node = _get_registry()
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


func _find_clear_placement(desired: Vector3, footprint: Vector3, vent_keepout: float = 0.0, candidate_id: StringName = &"") -> Vector3:
	if _is_placement_clear(desired, footprint, vent_keepout, candidate_id):
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
			if _is_placement_clear(pos, footprint, vent_keepout, candidate_id):
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


func _is_placement_clear(pos: Vector3, footprint: Vector3, vent_keepout: float = 0.0, candidate_id: StringName = &"") -> bool:
	## Same rules the player follows in SelectionManager — check against
	## buildings (with PLACEMENT_GAP buffer), units, fuel deposits, and
	## wrecks. Plus a keep-out around teammate HQs in 2v2. When
	## vent_keepout > 0, also reject positions whose centre sits within
	## that radius of any geothermic vent so non-generator buildings
	## naturally spiral OUT of the vent's keepout zone instead of
	## failing the post-check.
	var half_x: float = footprint.x * 0.5
	var half_z: float = footprint.z * 0.5

	# Vent keepout for non-generator buildings.
	if vent_keepout > 0.0:
		for v_node: Node in get_tree().get_nodes_in_group("geothermic_vents"):
			if not is_instance_valid(v_node):
				continue
			var v3: Node3D = v_node as Node3D
			if not v3:
				continue
			if pos.distance_to(v3.global_position) < vent_keepout:
				return false

	# Allied HQ keep-out — skip our own HQ, but stay clear of any teammate's.
	var registry: Node = _get_registry()
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

	# Energy-producing buildings get a relaxed gap when both the
	# candidate and the existing building are energy types -- the
	# starter vent pair sits 10u apart, but the standard
	# PLACEMENT_GAP (9u) plus two basic-generator half-extents
	# (2.5u total) gives an 11.5u rejection threshold, which made
	# the AI never place a second generator on the second vent of
	# its starting pair. Vent placement already enforces the
	# minimum spacing the layout designer chose, so for
	# energy-vs-energy pairs we can drop the manual gap entirely.
	var candidate_is_energy: bool = candidate_id == &"basic_generator" or candidate_id == &"advanced_generator"

	# Hostile-fire keepout. Reject placements whose centre sits
	# inside an enemy weapon's range. Without this the AI happily
	# drops foundries / yards inside a player turret's kill zone
	# and watches them die during construction. Uses each hostile
	# unit's resolved primary-weapon range so a long-range Bulwark
	# pushes the keepout further out than a short-range Rook.
	# Buildings under construction count as friendly (they're not
	# threatening anyone yet), so we skip them. `registry` was
	# already resolved up top for the allied-HQ keepout; reuse it.
	for u_node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u_node):
			continue
		var u_owner: int = (u_node.get("owner_id") as int) if "owner_id" in u_node else -1
		if u_owner == owner_id:
			continue
		var hostile: bool = (
			registry.are_enemies(owner_id, u_owner)
			if registry and registry.has_method("are_enemies")
			else u_owner != owner_id
		)
		if not hostile:
			continue
		if "alive_count" in u_node and (u_node.get("alive_count") as int) <= 0:
			continue
		var u_pos: Vector3 = (u_node as Node3D).global_position
		# Per-unit weapon range from stats. Falls back to 18u when
		# the unit has no primary_weapon (workers, engineers) so
		# the keepout still rejects placements inside a typical
		# unit's threat radius.
		var threat_range: float = 18.0
		var u_stats_v: Variant = u_node.get("stats")
		if typeof(u_stats_v) == TYPE_OBJECT and is_instance_valid(u_stats_v):
			var weapon_v: Variant = u_stats_v.get("primary_weapon")
			if typeof(weapon_v) == TYPE_OBJECT and is_instance_valid(weapon_v) and weapon_v.has_method("resolved_range"):
				threat_range = weapon_v.call("resolved_range") as float
		# Plus a small footprint margin so the building isn't right
		# at the edge of the kill zone.
		var keepout: float = threat_range + maxf(half_x, half_z) + 2.0
		if u_pos.distance_to(pos) < keepout:
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
		# Per-pair gap. Energy-vs-energy uses 0u extra so the AI can
		# fill both vents of the starter pair (and any other
		# closely-spaced vent cluster). Everything else keeps the
		# wider PLACEMENT_GAP for unit traffic between buildings.
		var pair_gap: float = PLACEMENT_GAP
		if candidate_is_energy and (b.stats.building_id == &"basic_generator" or b.stats.building_id == &"advanced_generator"):
			pair_gap = 0.0
		if dx < (half_x + their_hx + pair_gap) and dz < (half_z + their_hz + pair_gap):
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


## --- Hard-difficulty salvage cap --------------------------------------
## Hard AIs aren't allowed to pile up more than HARD_SALVAGE_CAP. When
## they do, _dump_excess_salvage_into_units finds an idle production
## building (empty queue) and queues a unit through the standard
## strategy-weighted picker. Production buildings are scanned in
## priority order matching the AI's normal composition: advanced
## foundry first (heavies), then basic foundry (mediums + lights),
## then aerodrome (air). The picker inside _try_queue_at handles the
## actual unit choice + faction-aware roster, so this just picks WHERE
## to spend.
const HARD_SALVAGE_CAP: int = 1500


func _dump_excess_salvage_into_units() -> void:
	if not _ai_resource_manager:
		return
	var salvage: int = (_ai_resource_manager.get("salvage") as int) if "salvage" in _ai_resource_manager else 0
	if salvage <= HARD_SALVAGE_CAP:
		return
	# Pick an idle production building, prioritised so the dump
	# leans into the AI's late-game composition (heavies first).
	var prio_order: Array[StringName] = [&"advanced_foundry", &"basic_foundry", &"aerodrome"]
	var foundries: Array[Node] = _all_friendly_foundries()
	for prio_id: StringName in prio_order:
		for f: Node in foundries:
			if not is_instance_valid(f):
				continue
			var fs: BuildingStatResource = f.get("stats") as BuildingStatResource
			if not fs or fs.building_id != prio_id:
				continue
			if not f.has_method("get_queue_size"):
				continue
			if f.get_queue_size() > 0:
				continue  # not idle
			# Hand off to the standard queue path; it picks a
			# faction-correct strategy-weighted unit + spends.
			# Returning after the first success caps the dump at
			# one queue per tick (we'll fire again next tick if
			# we're still over the cap), so a sudden injection
			# doesn't queue six units across every foundry in
			# one frame.
			_try_queue_at(f)
			return


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
		# Production-cadence counter -- bumped on a successful
		# combat-unit queue. Builders / Crawlers go through
		# _maintain_engineers / _maintain_crawlers respectively
		# and don't satisfy the gate (the gate exists to make sure
		# the AI fields actual ARMY before committing more
		# production capacity).
		_military_units_trained += 1


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
	# Counter-training: when the enemy army is dominated by one
	# armor class, with COUNTER_FOCUS_PROB chance pick the roster
	# entry whose primary weapon scores best vs that class. Falls
	# through to the strategy-weighted bucket pick the rest of
	# the time so we still field a mixed army.
	var dominant: StringName = _dominant_enemy_armor()
	if dominant != &"" and randf() < COUNTER_FOCUS_PROB:
		var counter: UnitStatResource = _best_counter_in_roster(available, dominant)
		if counter:
			return counter
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


## --- Debug harness helpers -------------------------------------------
## All read-only / observer code below. Always-on (zero cost when no
## overlay is reading the snapshot); the overlay itself is gated by its
## own DEBUG_HARNESS_ENABLED const so this stays cheap to leave in place.

func _record_blocker(key: String, blocker: int) -> void:
	## First not-yet-placed `_try_place` call that hits a blocker each
	## tick wins -- everything called after it stays silent so the
	## overlay surfaces the highest-priority pending build, not the
	## last one in the call list. Cleared at the top of _process via
	## _blocker_captured_this_tick.
	if _blocker_captured_this_tick:
		return
	_blocker_captured_this_tick = true
	_next_build_key = key
	_next_build_blocker = blocker


func _track_unit_lifecycle() -> void:
	## Lazily wires squad_destroyed signal connections so we can tally
	## kills (enemy units that died) and losses (our units that died)
	## across the match. Walks the units group once per AI tick, only
	## connecting newly seen units. The dictionary is keyed by
	## get_instance_id so we don't re-connect on each tick.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var iid: int = node.get_instance_id()
		if _tracked_units.has(iid):
			continue
		var n_owner: int = -1
		if "owner_id" in node:
			n_owner = node.get("owner_id") as int
		if n_owner < 0:
			continue
		# Treat anything not on our team as an enemy -- 2v2 alliances are
		# resolved via PlayerRegistry.are_enemies(...) when present, else
		# straight owner_id comparison.
		var is_enemy: bool = (n_owner != owner_id)
		var registry: Node = _get_registry()
		if registry and registry.has_method("are_allied"):
			is_enemy = not registry.are_allied(owner_id, n_owner) and n_owner != owner_id
		_tracked_units[iid] = "enemy" if is_enemy else "ally"
		if node.has_signal("squad_destroyed"):
			node.connect("squad_destroyed", Callable(self, "_on_tracked_unit_destroyed").bind(iid))


func _on_tracked_unit_destroyed(iid: int) -> void:
	if not _tracked_units.has(iid):
		return
	var side: String = _tracked_units[iid] as String
	if side == "enemy":
		_kills += 1
	else:
		_losses += 1
	_tracked_units.erase(iid)


func _state_label() -> String:
	match _state:
		AIState.SETUP:    return "SETUP"
		AIState.ECONOMY:  return "ECONOMY"
		AIState.ARMY:     return "ARMY"
		AIState.ATTACK:   return "ATTACK"
		AIState.REBUILD:  return "REBUILD"
	return "?"


func _strategy_label() -> String:
	match _strategy:
		Strategy.BALANCED:       return "BAL"
		Strategy.TURRET_HEAVY:   return "TURRET"
		Strategy.ECONOMY_HEAVY:  return "ECON"
		Strategy.RUSH:           return "RUSH"
		Strategy.AIR:            return "AIR"
	return "?"


func _blocker_label(b: int) -> String:
	match b:
		BuildBlocker.NONE:               return ""
		BuildBlocker.RESOURCE_LOAD_FAIL: return "resource load failed"
		BuildBlocker.PREREQ_NOT_MET:     return "prereq missing"
		BuildBlocker.PRODUCTION_GATE:    return "training gate"
		BuildBlocker.CANT_AFFORD:        return "can't afford"
		BuildBlocker.NO_ENGINEER:        return "no free engineer"
		BuildBlocker.NO_FREE_VENT:       return "no free vent"
		BuildBlocker.NO_CLEAR_SPOT:      return "no clear spot"
		BuildBlocker.VENT_SNAP_TOO_FAR:  return "vent too crowded"
		BuildBlocker.VENT_KEEPOUT:       return "blocks a vent"
		BuildBlocker.NEAR_PLATEAU:       return "ramp keepout"
	return "?"


func _time_until_next_attack() -> float:
	## Best-effort estimate of seconds until the AI's next ATTACK
	## transition. Returns negative when already attacking. The dormant
	## safety-net path is reliable; the wave-size path can't be predicted
	## exactly because it depends on production + attrition rates, so
	## we expose the dormant timer as the worst-case upper bound.
	if _state == AIState.ATTACK:
		return -1.0
	var dormant_left: float = _personality_dormant_timeout_sec() - (_match_clock_sec - _last_attack_clock_sec)
	# REBUILD must finish before we can re-enter ECONOMY, then ARMY.
	if _state == AIState.REBUILD:
		var rebuild_left: float = REBUILD_DURATION - _state_timer
		dormant_left = maxf(dormant_left, rebuild_left)
	return maxf(dormant_left, 0.0)


func get_debug_snapshot() -> Dictionary:
	## One-shot read of every value the AIDebugOverlay renders. Cheap to
	## call: all the work happens in the regular AI tick. Returning a
	## plain Dictionary keeps the overlay decoupled from this file's
	## internals so future refactors don't break the harness.
	var salvage_now: int = 0
	var fuel_now: int = 0
	var income: Vector2 = Vector2.ZERO
	if _ai_resource_manager:
		if "salvage" in _ai_resource_manager:
			salvage_now = _ai_resource_manager.get("salvage") as int
		if "fuel" in _ai_resource_manager:
			fuel_now = _ai_resource_manager.get("fuel") as int
		if _ai_resource_manager.has_method("get_average_income"):
			income = _ai_resource_manager.get_average_income() as Vector2
	var wave_target: int = maxi(int(round(float(_personality_wave_size_base() + _wave_count * 2) * _agg_mul)), 2)
	return {
		"owner_id": owner_id,
		"faction": _my_faction,
		"strategy": _strategy_label(),
		"state": _state_label(),
		"salvage": salvage_now,
		"fuel": fuel_now,
		"salvage_per_sec": income.x,
		"fuel_per_sec": income.y,
		"unit_count": _units.size(),
		"wave_target": wave_target,
		"wave_count": _wave_count,
		"kills": _kills,
		"losses": _losses,
		"next_build": _next_build_key,
		"next_build_blocker": _blocker_label(_next_build_blocker),
		"last_placed": _last_placed_key,
		"last_placed_age_sec": (_match_clock_sec - _last_placed_clock_sec) if _last_placed_clock_sec > -INF * 0.5 else -1.0,
		"sec_until_attack": _time_until_next_attack(),
		"match_clock": _match_clock_sec,
		"eng_total": _engineer_total,
		"eng_idle": _engineer_idle,
		"eng_build": _engineer_busy_build,
		"eng_repair": _engineer_busy_repair,
		"eng_garrison": _engineer_garrisoned,
		"eng_moving": _engineer_moving,
	}
