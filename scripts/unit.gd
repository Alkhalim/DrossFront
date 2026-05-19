class_name Unit
extends CharacterBody3D
## Base unit controller. Represents a full squad with individual member visuals.

signal arrived
signal selected
signal deselected
signal squad_destroyed
signal member_died(index: int)

@export var stats: UnitStatResource
@export var owner_id: int = 0

const SPEED_MAP: Dictionary = {
	&"static": 0.0, &"very_slow": 3.0, &"slow": 5.0,
	&"moderate": 8.0, &"fast": 12.0, &"very_fast": 16.0,
}
const ARRIVE_THRESHOLD: float = 0.5
## Gravity applied to airborne units — keeps them from floating after
## ending up above floor level. Tuned for "feels right" rather than
## physical correctness; the prototype's scale is small.
const GRAVITY: float = 18.0
## Idle-spread tuning: how close two same-team units have to be before
## the spread push kicks in, and how strong the push is.
const IDLE_SPREAD_MIN_DIST: float = 1.6
const IDLE_SPREAD_FORCE: float = 1.4

var move_target: Vector3 = Vector3.INF
## Optional waypoint chain — populated when the player issues Ctrl-clicked
## move commands. Each waypoint is consumed when reached; the unit then
## proceeds to the next without any further input. Empty under normal
## (non-queued) commands.
var move_queue: Array[Vector3] = []
var is_selected: bool = false
var has_move_order: bool = false
## Wall-clock timestamp (msec) until which combat re-engagement is
## suppressed. Set by command_move(clear_combat=true) so the player's
## retreat command isn't immediately overridden by retaliation.
## Plan D's stance system will replace this with a proper Move vs
## Attack-move stance.
var _move_priority_until_ms: int = 0
## Stand-ground state. When true the combat component skips auto-acquire
## scanning and the movement loop refuses to chase out-of-range enemies.
## The unit still fires at anything that wanders into actual weapon range,
## just doesn't reposition itself. Cleared by any explicit move/attack/
## attack-move/patrol order.
var is_holding_position: bool = false
## Patrol state — when both ends are set the unit walks A → B → A → B in a
## loop, scanning for enemies along the way (same engagement rules as
## attack-move, which is functionally what each leg is).
var patrol_a: Vector3 = Vector3.INF
var patrol_b: Vector3 = Vector3.INF
var _move_speed: float = 8.0

## How fast the unit's body slews around Y, in lerp factor per second.
## Lower = sluggish (heavies), higher = snappy (lights). Set per-class in _ready.
var _turn_speed: float = 6.0

## Per-member HP.
var member_hp: Array[int] = []
var alive_count: int = 0

## Wall-clock timestamp of the most recent damage taken. Used by the
## nanite-regen passive (stats.nanite_regen_per_sec > 0) to gate
## heal-while-out-of-combat. Initialised to 0 so a fresh unit that
## has never been hit is considered out-of-combat from spawn.
var _last_damage_taken_msec: int = 0

## Hover-tank visual phase counter (Inquisitor Tank). Advances at
## HOVER_BOB_RATE rad/s in _per_frame_bookkeeping so the chassis
## bobs on a slow sine-wave Y offset.
var _hover_phase: float = 0.0
const HOVER_BOB_RATE: float = 2.4        # rad/sec — ~2.6 s full bob cycle
const HOVER_BOB_AMPL: float = 0.10       # ±0.10 u vertical sway
const HOVER_BANK_PER_UNIT_SPEED: float = 0.10  # rad of lean per 1 u/s lateral
const HOVER_BANK_MAX_RAD: float = 0.35   # ~20° max lean
const HOVER_BANK_LERP_RATE: float = 4.0  # smoothing factor for bank changes
## Fractional HP that hasn't yet rounded up to a full point. Lets
## sub-1-HP/sec regen rates accumulate cleanly across physics ticks.
var _nanite_regen_accum: float = 0.0
## Seconds without taking damage before the unit is considered
## out-of-combat for regen purposes. Long enough that mid-skirmish
## pauses (between volleys) don't trickle HP back, short enough
## that disengaging to retreat starts the heal before the player
## gives up on the unit.
const NANITE_OUT_OF_COMBAT_SEC: float = 6.0

## Seconds remaining on an EChO override / EMP paralysis. While
## > 0 the unit's velocity is forced to zero in _physics_process
## (movement halts even if a move command is queued) and the
## attached CombatComponent's silence timer prevents firing.
var _emp_paralysis_remaining: float = 0.0

## Visual state.
var _member_meshes: Array[Node3D] = []
var _color_shell: MeshInstance3D = null
var _hp_bar: Node3D = null
var _hp_bar_fill: MeshInstance3D = null
var _hp_bar_bg: MeshInstance3D = null
## Reload progress bar drawn under the HP bar — fills as the unit's
## weapon cooldown progresses, so the player can see at a glance which
## squad is mid-reload and which is ready to fire. Whitegrey for a
## neutral, non-distracting read.
var _reload_bar: Node3D = null
var _reload_bar_fill: MeshInstance3D = null
var _reload_bar_bg: MeshInstance3D = null
var _anim_time: float = 0.0
## Continuously advancing clock for idle sway (never resets, unlike _anim_time).
var _idle_time: float = 0.0
## Round-robin throttle for the idle-animation work. Stagger across units
## (random init in _ready) so the perf cost spreads instead of clumping
## on the same physics frame. _reset_walk_bob and the friend-spread idle
## logic only run on the matching frame; off-frames just bump the counter.
var _idle_anim_throttle: int = 0
const IDLE_ANIM_THROTTLE_FRAMES: int = 4
## Independent throttle for the slope-aware per-member surface raycast.
## Increments every physics frame regardless of move/idle state, so a
## moving unit on a ramp doesn't pay the full O(squad_size) raycast cost
## at 60Hz — only every BOB_RAYCAST_THROTTLE_FRAMES tick. Stagger seeded
## per-unit in _ready.
var _bob_raycast_throttle: int = 0
const BOB_RAYCAST_THROTTLE_FRAMES: int = 6

## Walk-bob is the dominant per-frame cost on moving units (squad-member
## leg sin updates + position writes). We halve it by running at 30Hz with
## round-robin staggering — units with even ids update on even physics
## frames, odd ids on odd frames. A 1-frame leg-pose lag is invisible.
var _walk_bob_phase: int = 0
var _physics_frame_counter: int = 0

## Cache the CombatComponent reference so the per-frame idle/combat
## branch in `_physics_process` doesn't pay a `get_node_or_null` lookup
## every tick. Set in `_ready` (or stays null for combat-less engineers).
var _combat_cached: Node = null

## Cache the MovementComponent reference. _physics_process did
## `get_node_or_null("MovementComponent")` per tick to decide between
## the new and legacy movement paths, AND _per_frame_bookkeeping did
## another lookup inside the has_move_order branch. With combat
## constantly issuing chase commands, has_move_order stays true
## indefinitely — so the bookkeeping branch's lookup fires at full
## tick rate per unit. Caching once on _ready collapses both into
## a typed field access.
var _movement_cached: MovementComponent = null

## `_mech_total_height` is constant per unit (depends only on stats), so
## the HP-bar repositioning block can read this cached value instead of
## doing a CLASS_SHAPES dict lookup every frame.
var _cached_total_height: float = -1.0

## Bail out of `_tick_recoil`'s outer member loop when no recoil is
## active. `play_shoot_anim` arms this for ~250ms (covers the 8/s decay).
var _recoil_active_until_msec: int = 0

## Camera cached for the animation-distance cull below. Lazy-init on
## first use so we don't fight the scene boot order.
var _camera_cached: Camera3D = null
## Skip per-frame walk-bob, HP-bar repositioning, and dust spawning for
## units further than this from the camera. Squared so we avoid sqrt on
## the hot path. 80u covers most of the player's view at typical camera
## zoom; units beyond that aren't visible enough for the animation cost
## to be worth it.
const ANIM_CULL_DIST_SQ: float = 80.0 * 80.0

## Engineer is currently working on a construction site. BuilderComponent toggles
## this; the visual claw animates and emits sparks while it's true.
var is_building: bool = false
var _build_spark_timer: float = 0.0

## Active-ability state. _ability_cd_remaining counts down each frame
## while > 0; the HUD shows the remaining seconds on the ability
## button so the player knows when it's available again.
var _ability_cd_remaining: float = 0.0

## Wächter deploy mode state. Exposed as a plain bool so CombatComponent
## can read it via duck-typing. _deploy_progress tracks the 0→1 transition
## (deploy) or 1→0 (undeploy) over DEPLOY_TRANSITION_SEC seconds.
## During transition _deploy_locked prevents movement and re-toggling.
var is_deployed: bool = false
var _deploy_progress: float = 0.0  # 0 = undeployed, 1 = deployed
var _deploy_locked: bool = false    # true while transition is in progress
const DEPLOY_TRANSITION_SEC: float = 3.0

## Accumulator for healing overflow — used by Factory Pulse to
## convert "wasted" heal (everyone already at full HP) into
## restored squad members. Once this passes hp_per_unit, one
## dead member comes back with full HP. Persists across casts so
## a partial top-up adds to the next.
var _heal_overflow_accum: int = 0

## Courier passenger list — populated when this unit casts
## Garrison and emptied on the second press (disembark). Each entry
## is the passenger Unit. Empty when the tank isn't carrying anyone
## or when this unit isn't a transport at all.
var _garrison_passengers: Array[Unit] = []

## Courier track ribs — flat list of MeshInstance3D nodes
## across all squad members. Each entry is { node, length } where
## length is the track segment they wrap around. Scrolled per
## frame in _process when the tank is moving.
var _courier_track_ribs: Array[Dictionary] = []
## Reverse pointer for passengers: the carrier unit they're riding
## inside. While set, the passenger's _physics_process skips
## movement / combat and the passenger is hidden + non-targetable.
var _garrisoned_in: Unit = null

## SelectionManager flags this true while the mouse is hovering over the unit
## so we can pop up the HP bar even if the unit is at full health.
var hp_bar_hovered: bool = false

## Timer for walking dust. Heavier mechs raise more dust per stride.
var _dust_timer: float = 0.0

## Damage flash.
var _flash_timer: float = 0.0
const FLASH_DURATION: float = 0.12

## Navigation.
var _nav_agent: NavigationAgent3D = null
var _stuck_timer: float = 0.0
var _settled_frames: int = 0
## Set when a squad member dies while the squad is standing still.
## Triggers a one-shot _rebalance_formation on the next command_move
## so the surviving members close ranks as part of the next motion
## instead of teleport-shuffling at rest.
var _rebalance_pending: bool = false
## Throttle (msec timestamp) for the zero-movement repath in
## _physics_process. Prevents spamming NavigationServer with a
## new target_position every physics frame while the unit is
## wedged against geometry; the half-second gap is short enough
## that a freshly-blocked path resolves in the same beat the
## player notices it stopping.
var _zero_move_repath_at_msec: int = 0
## Throttle (msec) for the ramp-stuck self-rescue so we don't
## re-issue command_move every frame while the deflection ladder
## is also tweaking the agent.
var _ramp_rescue_at_msec: int = 0
## Throttle (msec) for the detour-around-building attempts. Once a
## unit triggers the 1.4s building-detour, suppress further detour
## attempts on this unit for ~3s so the inserted side-step has time
## to play out before another one stacks behind it.
var _detour_attempted_at_msec: int = 0

## Movement-aware collision shrink. While the unit is actively
## moving, the leader collision box is rescaled to
## MOVING_COLLISION_SCALE of its rest-state XZ extent so squads
## can pass through each other on the way to a destination. At
## rest (and when stopped) the shape returns to full size so
## stacked units physically separate.
var _movement_collision_shape: BoxShape3D = null
var _movement_collision_rest_size: Vector3 = Vector3.ZERO
var _movement_collision_currently_moving: bool = false
const MOVING_COLLISION_SCALE: float = 0.55
const MOVING_VELOCITY_THRESHOLD_SQ: float = 1.0

## V3 Stealth — see UnitStatResource.is_stealth_capable. `is_revealed`
## is true while an enemy is within detection range OR the unit took
## damage in the last `stealth_restore_time` seconds. Auto-targeting
## (CombatComponent._find_nearest_enemy) skips stealth-capable units
## with is_revealed == false.
var stealth_revealed: bool = true
var _stealth_damage_timer: float = 0.0
var _stealth_check_throttle: float = 0.0
const STEALTH_CHECK_INTERVAL: float = 0.4

## Active-camo pulse — per-material alpha oscillates while concealed so
## the controller can still pick out their own stealth squads (playtest
## 2026-05-15: a flat 0.35 alpha was too easy to lose in the terrain).
var _stealth_pulse_mats: Array[StandardMaterial3D] = []
var _stealth_pulse_phase: float = 0.0
const STEALTH_PULSE_BASE: float = 0.35
const STEALTH_PULSE_AMP: float = 0.20
const STEALTH_PULSE_PERIOD: float = 2.4
var _last_position: Vector3 = Vector3.ZERO

## Home position used by neutral patrol behaviour. When set (i.e. not
## Vector3.INF) the unit's combat component:
## - applies a 0.8× multiplier to its engage range (looser aggro);
## - returns to this position whenever it has no current target and is
##   more than ~2.5u away from home, instead of standing wherever its
##   last fight ended.
## Set externally after spawning a neutral patrol mech.
var home_position: Vector3 = Vector3.INF
## Wall-deflection state. When the unit has been head-on stuck against
## geometry for ~0.3s, we rotate the desired direction sideways for a short
## window so slide-along-wall produces real lateral progress instead of
## zeroing out against a flat surface. `_deflect_until_msec` is the absolute
## clock time the deflection expires; `_deflect_sign` chooses left vs right;
## `_deflect_angle_deg` lets the stuck-rescue ladder crank the rotation up
## from a gentle 50° (slip past a corner) to >90° (almost backtracking
## past a thick wall).
var _deflect_until_msec: int = 0
var _deflect_sign: float = 0.0
var _deflect_angle_deg: float = 50.0

## Heliarch Heat HP drain + Emergency Cooldown.
## Heat drain accumulates floating-point damage and applies whole-HP chunks
## so self-damage respects the integer take_damage path. Only active on
## Heliarch units (_faction_id() == HELIARCH) — all branches are gated.
var _heat_drain_accum: float = 0.0
## Per-shot heat ramp added to a Heliarch unit's heat_pct each time it
## fires a weapon (called from CombatComponent._fire_weapon via
## notify_heat_ramp_fire). 5 % per primary shot means a unit reaches
## Tier 2 (66 %) in ~14 shots of sustained fire and Tier 3 (100 %) at
## ~20 shots. Balance: a slow heavy weapon (Cremator flame, 3-4 ticks
## per second on the salvo) hits the cap in under 6 s of continuous
## fire, which is the spec's intent — sustained combat punishes Heliarch
## via the Heat tax.
const HEAT_RAMP_PER_FIRE: float = 0.05
## Per-second passive heat decay applied in _tick_heliarch_heat_drain
## while NOT in emergency cooldown. ~4 %/s → unit goes from 100 % to
## 0 % in 25 s of disengagement. Slower than the per-shot ramp so a
## firing unit climbs toward the tier thresholds.
const HEAT_PASSIVE_DECAY_PER_SEC: float = 0.04
## Seconds remaining in Emergency Cooldown. While > 0 the unit is:
##   - immobile (EMP-paralysis mechanism re-used)
##   - fire-suppressed (silence re-applied each tick as a watchdog)
##   - draining EMERGENCY_COOLDOWN_DRAIN_PER_SEC HP/sec
## When it hits 0 the unit's heat resets to 0% via _on_emergency_cooldown_end.
var _emergency_cooldown_remaining: float = 0.0
const EMERGENCY_COOLDOWN_DURATION: float = 6.0
const EMERGENCY_COOLDOWN_DRAIN_PER_SEC: float = 8.0
## Set for one physics tick after heat first reaches 100%, cleared immediately.
## If meltdown (player-triggered ability that kills the unit) fires before
## the per-tick check, the meltdown path sets this flag so the auto-cooldown
## does not ALSO trigger on the same frame.
var _meltdown_triggered_this_cycle: bool = false

## Player colors.
const PLAYER_COLOR := Color(0.08, 0.25, 0.85, 1.0)
const ENEMY_COLOR := Color(0.80, 0.10, 0.10, 1.0)
const NEUTRAL_COLOR := Color(0.85, 0.7, 0.3, 1.0)
## Anvil faction identity band — additive accent layered on top of the
## team-color stripe per READABILITY_PASS.md §Task 7. When other factions
## land in v3+ this is replaced with a per-faction lookup.
const ANVIL_BRASS := Color(0.78, 0.62, 0.18, 1.0)
## Sable neon accent — bright violet. Distinguishes Sable from Anvil
## at a glance (matte black chassis + single violet emissive line vs.
## Anvil's olive grey + warm brass band) and stays out of the player
## team-blue's hue range so emission doesn't blend with team color.
const SABLE_NEON := Color(0.78, 0.35, 1.0, 1.0)


static func team_color_for(owner_idx: int) -> Color:
	# Static fallback when the PlayerRegistry isn't reachable (headless
	# test scenes, units instantiated before the scene tree settles).
	# Real perspective coloring goes through `_resolve_team_color` below.
	if owner_idx == 0:
		return PLAYER_COLOR
	if owner_idx == 2:
		return NEUTRAL_COLOR
	return ENEMY_COLOR


func _resolve_team_color() -> Color:
	# Routes through PlayerRegistry.get_perspective_color so allies in 2v2
	# show in green and enemies in red regardless of which faction
	# they're playing. Falls back to the static rule when the registry
	# isn't present.
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("get_perspective_color"):
		return registry.get_perspective_color(owner_id)
	return Unit.team_color_for(owner_id)

## Unit-vector formation offsets per squad size (XZ plane, magnitude ~1).
## Multiplied by each class's formation_spacing in _build_squad_visuals so
## bigger mechs get proportionally wider squads and don't overlap.
const FORMATION_OFFSETS: Dictionary = {
	1: [Vector2.ZERO],
	2: [Vector2(-1.0, 0.0), Vector2(1.0, 0.0)],
	3: [Vector2(-1.0, 0.55), Vector2(1.0, 0.55), Vector2(0.0, -0.85)],
	4: [Vector2(-1.0, 0.85), Vector2(1.0, 0.85), Vector2(-1.0, -0.85), Vector2(1.0, -0.85)],
	# 5-member formation: 4 corners + 1 center, so the squad still reads
	# as a coherent group rather than a line.
	5: [Vector2(-1.0, 0.85), Vector2(1.0, 0.85), Vector2(-1.0, -0.85), Vector2(1.0, -0.85), Vector2(0.0, 0.0)],
	# 6-member formation: 2 rows of 3, slightly staggered so the squad
	# reads as a wider phalanx (Ashigaru bumped to squad_size=6).
	6: [Vector2(-1.20, 0.85), Vector2(0.0, 0.85), Vector2(1.20, 0.85),
		Vector2(-1.20, -0.85), Vector2(0.0, -0.85), Vector2(1.20, -0.85)],
}

## Mech anatomy per class. All values are sizes/positions in member-local space.
## leg: dimensions of each leg, hip_y: where legs hang from, leg_x: half-spacing of legs.
## torso: dimensions, head: dimensions, head_shape: "box" or "sphere".
## cannon: dimensions of each shoulder weapon, cannon_x: half-spacing of shoulders,
##   cannon_kind: "twin", "single_left", "claw" (engineer tool arm), "none".
## antenna: height (0 = none).
## formation_spacing: distance from squad center to each member (multiplied with FORMATION_OFFSETS).
## turn_speed: rad/s body slew speed (lower = sluggish, higher = snappy).
const CLASS_SHAPES: Dictionary = {
	&"engineer": {
		# Ratchet — small hexapod utility mech. Per readability-pass spec
		# (READABILITY_PASS.md §Task 3): scaled 0.7× from the medium baseline
		# so it visibly reads as the smallest unit class. Squad still 5
		# members for combat per a separate tuning pass.
		"leg": Vector3(0.056, 0.385, 0.056), "hip_y": 0.238, "leg_x": 0.098,
		"torso": Vector3(0.294, 0.21, 0.546), "head": Vector3(0.182, 0.154, 0.21), "head_shape": "sphere",
		"cannon": Vector3(0.084, 0.084, 0.266), "cannon_x": 0.161, "cannon_kind": "claw",
		"antenna": 0.0,
		"color": Color(0.5, 0.46, 0.28),
		"formation_spacing": 0.7,
		# turn_speed is now rad/sec under the constant-velocity
		# turn rule (was a smoothstep factor). Engineers feel
		# nimble; bumped to 9 so they pivot ~1.5x as fast as
		# the medium baseline.
		"turn_speed": 9.0,
		"leg_kind": "spider",
		"torso_lean": 0.0,
	},
	&"light": {
		# Rook — agile biped scout. Scaled 0.85× of the original baseline
		# so it sits between Engineer and Medium in silhouette weight.
		"leg": Vector3(0.094, 0.468, 0.094), "hip_y": 0.468, "leg_x": 0.128,
		"torso": Vector3(0.323, 0.51, 0.323), "head": Vector3(0.204, 0.204, 0.306), "head_shape": "box",
		"cannon": Vector3(0.102, 0.102, 0.383), "cannon_x": 0.238, "cannon_kind": "twin",
		"antenna": 0.425,
		"color": Color(0.32, 0.34, 0.4),
		"formation_spacing": 0.85,
		# Light scout pivot: ~9 rad/s = ~520 deg/s. Snaps facing
		# in under half a second across any angle.
		"turn_speed": 9.0,
		"leg_kind": "biped",
		"torso_lean": 0.0,
	},
	&"medium": {
		# Hound — Sentinel-style: tall chicken legs dominate, larger cockpit on
		# top, single cannon mounted on the right at cockpit height. Red visor.
		# 1.0× baseline — the size every other class is calibrated against.
		"leg": Vector3(0.18, 0.6, 0.18), "hip_y": 1.15, "leg_x": 0.3,
		"torso": Vector3(0.65, 0.6, 0.7), "head": Vector3(0.55, 0.42, 0.6), "head_shape": "box",
		"cannon": Vector3(0.16, 0.16, 0.75), "cannon_x": 0.34, "cannon_kind": "single_right",
		"cannon_mount": "head_top",
		"antenna": 0.5,
		"color": Color(0.38, 0.32, 0.32),
		"formation_spacing": 1.4,
		# Medium chicken-walker baseline: ~7 rad/s = ~400 deg/s.
		"turn_speed": 7.0,
		"leg_kind": "chicken",
		"torso_lean": 0.0,
	},
	&"heavy": {
		# Bulwark — walking tank destroyer: low elongated chassis, sloped front
		# armor, single large cannon mounted in the front-center of the hull
		# (no turret). Cylindrical barrel with a muzzle brake. Detail bulges,
		# side skirts, and engine deck make it read as a proper war machine.
		# Scaled 1.4× of the original baseline so it dominates a Rook squad.
		"leg": Vector3(0.392, 0.98, 0.392), "hip_y": 0.98, "leg_x": 0.77,
		"torso": Vector3(1.54, 0.77, 2.38), "head": Vector3(0.7, 0.56, 0.77), "head_shape": "box",
		"cannon": Vector3(0.224, 0.224, 1.47), "cannon_x": 0.0, "cannon_kind": "platform",
		"antenna": 0.42,
		"color": Color(0.42, 0.4, 0.35),
		"formation_spacing": 2.0,
		# Heavy mech: ~4 rad/s = ~230 deg/s. Visibly slower than
		# lights but still finishes a 180 in <1s.
		"turn_speed": 4.0,
		"leg_kind": "quadruped",
		"torso_lean": 0.0,
	},
	&"apex": {
		# Apex titan — huge biped, kept default silhouette.
		"leg": Vector3(0.5, 0.95, 0.5), "hip_y": 0.95, "leg_x": 0.6,
		"torso": Vector3(1.6, 1.6, 1.6), "head": Vector3(0.9, 0.85, 1.0), "head_shape": "box",
		"cannon": Vector3(0.55, 0.6, 1.55), "cannon_x": 1.15, "cannon_kind": "twin",
		"antenna": 0.85,
		"color": Color(0.48, 0.42, 0.35),
		"formation_spacing": 2.4,
		# Apex titan: slowest pivot, ~3.5 rad/s = ~200 deg/s.
		"turn_speed": 3.5,
		"leg_kind": "biped",
		"torso_lean": 0.0,
	},
	&"transport": {
		# Courier — tracked transport, custom mesh built via
		# _build_courier_tank_member. Most of these fields are
		# unused (the dedicated builder ignores leg / torso / cannon
		# placeholders), but formation_spacing IS read by
		# _build_squad_visuals and turn_speed by the chassis turn
		# code, so they need real values. Tracks are ~3u long and
		# each tank is ~2.5u wide, so 3.5u between centres keeps
		# the trio visibly separated rather than touching tracks.
		"leg": Vector3(0.0, 0.0, 0.0), "hip_y": 0.0, "leg_x": 0.0,
		"torso": Vector3(2.4, 0.5, 2.85), "head": Vector3(0.0, 0.0, 0.0), "head_shape": "box",
		"cannon": Vector3(0.0, 0.0, 0.0), "cannon_x": 0.0, "cannon_kind": "none",
		"antenna": 0.0,
		"color": Color(0.18, 0.18, 0.22),
		# Spacing tightened from 3.5 to 3.0 to match the 0.9× tank
		# visual scale applied in the build dispatcher (see Courier /
		# Breacher tank scaling below). Tanks now read smaller and
		# their squad clusters tighter.
		"formation_spacing": 3.0,
		# Tracked tank: ~5 rad/s = ~290 deg/s. Tracks pivot in
		# place faster than legs need to reposition.
		"turn_speed": 5.0,
		"leg_kind": "tracked",
		"torso_lean": 0.0,
	},
}

## Per-member animation state. Parallel to _member_meshes.
## Each entry: { legs:[left,right], shoulders:[left,right], cannons:[left,right],
##              torso:Node3D, head:Node3D, mats:Array[StandardMaterial3D],
##              recoil:[float,float], stride_phase: float }
var _member_data: Array[Dictionary] = []

## Walking animation accumulator (synced from velocity).
var _stride_speed: float = 0.0


func _ready() -> void:
	add_to_group("units")
	add_to_group("owner_%d" % owner_id)
	# CharacterBody3D floor handling. Default floor_snap_length=0
	# means the body never auto-snaps to a slightly-lower / -higher
	# floor — at ramp-top-to-plateau seams (or any small Y step in
	# the navmesh stitching) the unit lifts off, gravity pulls it
	# down, sometimes oscillates and stalls there. 0.5u of snap lets
	# the body smoothly track a step up to 0.5m without losing floor
	# contact. Matches the crawler pattern (1.0u snap there because
	# the chassis is larger). floor_max_angle limits unintended
	# climbing of near-vertical surfaces.
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(45.0)
	up_direction = Vector3.UP
	# Random offset so idle-animation work is staggered across units.
	_idle_anim_throttle = randi() % IDLE_ANIM_THROTTLE_FRAMES
	_bob_raycast_throttle = randi() % BOB_RAYCAST_THROTTLE_FRAMES
	# Round-robin physics work across THREE-frame slots (~20Hz per unit
	# instead of 60Hz). At 360+ active units, even a 30Hz half-frame
	# stagger blew the frame budget on `Unit._physics_process` — bumping
	# to a 1-in-3 cadence drops the per-frame batch from 180 units to
	# 120 with no visible quality loss for movement / animation.
	_walk_bob_phase = int(get_instance_id() % 3)
	# Navigation agent / movement component setup.
	# Ground unit predicate — every ground class uses the new MovementComponent
	# when the feature flag is on. Aircraft and crawlers stay on legacy through
	# Plan B. The is_aircraft / is_crawler flags on UnitStatResource are the
	# canonical source of truth (see PA-21 backfill).
	var _is_ground: bool = stats != null and not stats.is_aircraft and not stats.is_crawler
	if MovementFlags.use_new_system() and _is_ground:
		# New system: GroundMovement
		var gm := GroundMovement.new()
		gm.name = "MovementComponent"
		gm.max_speed = stats.speed
		gm.max_accel = stats.speed * 6.0  # TODO(PA-21): tune accel curve per-class via UnitStatResource
		gm.max_turn_rate_rad_s = TAU * 1.0  # TODO(PA-21): per-class turn rate via UnitStatResource (default ≈ 1 rotation/sec)
		gm.agent_profile = AgentProfile.new(0.6, 0.5, 35.0, &"squad_default")  # TODO(PA-21): per-class agent profile (radius/climb/slope)
		add_child(gm)
		# Engineer build/repair docking: the GroundMovement default
		# arrival_radius (6.0u, sized for the outer ring of a crowd combat
		# arrival) leaves engineers frozen 6u from their build/repair
		# approach point — well outside BUILD_BUFFER (3.5u) so construction
		# never starts. Tight 1.5u arrival drives the engineer all the way
		# to the approach point. RANGE_TOLERANCE in BuilderComponent (also
		# 1.5u) absorbs any residual jitter once docked.
		# MUST be set AFTER add_child(gm) — gm._ready() resets arrival_radius
		# to the GroundMovement default of 6.0u, which would clobber any
		# pre-add_child override. Same pattern salvage_worker.gd uses.
		if stats.can_build:
			gm.arrival_radius = 1.5
		# Melee combat units need to physically reach their target —
		# the GroundMovement 6 u default leaves them stranded outside
		# weapon range. Tightened to 0.3 u (was 0.7, originally 1.5) so
		# the unit pushes hard against the enemy's collision until
		# separation pins it at touch distance. Combined with the
		# group_aura 1.0 u melee ring and chase_position returning
		# enemy_pos directly, this should close the "clumps up but
		# doesn't reach" gap (playtest 2026-05-18).
		if stats.primary_weapon != null:
			var pw: WeaponResource = stats.primary_weapon
			if pw.range_tier == &"melee" or pw.resolved_range() <= 3.0:
				gm.arrival_radius = 0.3
		_movement_cached = gm
	else:
		# Legacy NavigationAgent3D path
		_nav_agent = NavigationAgent3D.new()
		_nav_agent.name = "NavAgent"
		_nav_agent.path_desired_distance = 0.8
		_nav_agent.target_desired_distance = 1.2
		_nav_agent.avoidance_enabled = true
		_nav_agent.radius = 1.5
		_nav_agent.neighbor_distance = 10.0
		_nav_agent.max_neighbors = 8
		_nav_agent.max_speed = 16.0
		add_child(_nav_agent)

	if stats:
		_move_speed = stats.resolved_speed()
		# Anvil units run 5% slower than the speed-tier baseline so
		# the heavy industrial silhouette also reads in motion — Sable
		# units feel measurably quicker side-by-side without needing
		# to bump every tier up. Applied at unit init so commit-time
		# branch swaps re-pick up the modifier through their own
		# _ready / _build_squad_visuals re-init path.
		if _faction_id() == 0:
			_move_speed *= 0.95

		# The Courier is the FACTION transport for Meridian, so the
		# speed gap "on foot vs in the tank" needs to live on Meridian's
		# side of the roster. Meridian infantry / engineers eat a small
		# nerf so embarking actually saves travel time, but the cuts
		# stay small enough that Sable still outpaces Anvil's
		# equivalents (Sable light goes from 12.0 -> 11.52 vs Anvil
		# light at 12.0 * 0.95 = 11.4; Sable engineer goes from
		# fast-tier 12.0 -> 10.8, still well ahead of Anvil's
		# moderate-tier 8.0 * 0.95 = 7.6).
		if _faction_id() == 1:
			if stats.unit_class == &"light":
				_move_speed *= 0.96
			elif stats.unit_class == &"engineer":
				_move_speed *= 0.90

		# Transports (Courier) get a small speed bump on top of
		# their tier so the embark loop reads as a real upgrade over
		# walking. Applies regardless of faction since "transport" is
		# a unit-class concept, but in practice only Sable ships one
		# right now.
		if stats.unit_class == &"transport":
			_move_speed *= 1.10
		# New-system MovementComponent: mirror the multiplied _move_speed
		# onto gm.max_speed so the new path uses the same effective speed
		# the legacy path does. Without this, gm.max_speed stays at the
		# raw stats.speed (Anvil units would run 5% faster than intended,
		# Sable engineers 10%, and transports would lose their +10% bump).
		var mc_speed_sync: Node = get_node_or_null("MovementComponent")
		if mc_speed_sync != null and mc_speed_sync is MovementComponent:
			(mc_speed_sync as MovementComponent).max_speed = _move_speed
			(mc_speed_sync as MovementComponent).max_accel = _move_speed * 6.0
		var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
		shape = _maybe_override_shape_for_unit(shape)
		_turn_speed = shape.get("turn_speed", 6.0) as float
		# Avoidance radius — covers the LEADER's collision capsule with
		# a small buffer, NOT the whole squad formation. The leader is
		# the only physics body; squad members are visual children
		# orbiting around it. Sizing the avoidance radius to the squad
		# spread caused RVO to push agents 3u from any wall, but the
		# baked navmesh only carves 1.5u clearance — agents oscillated
		# against ramp walls and tight building corridors instead of
		# walking through. Tighter avoidance gets the agent through.
		# Capped at the navmesh bake's agent_radius so heavy mechs
		# don't request more clearance than the navmesh provides
		# (which strands them against terrain corners).
		var torso_w: float = (shape["torso"] as Vector3).x
		if _nav_agent != null:
			_nav_agent.radius = minf(torso_w * 0.5 + 0.4, 1.4)
		_init_hp()
		_build_squad_visuals()
		_build_hp_bar()
		if stats.can_build:
			var builder := BuilderComponent.new()
			builder.name = "BuilderComponent"
			add_child(builder)
		if stats.primary_weapon:
			var combat_script: GDScript = load("res://scripts/combat_component.gd") as GDScript
			var combat: Node = combat_script.new()
			combat.name = "CombatComponent"
			add_child(combat)
			_combat_cached = combat
		# `_mech_total_height` only depends on stats, so compute it once
		# here and reuse from the HP-bar repositioning hot path instead
		# of a CLASS_SHAPES lookup per frame.
		_cached_total_height = _mech_total_height()

		# Stealth-capable units start concealed; the periodic stealth
		# check below will reveal them when an enemy detector closes
		# the distance.
		if stats.is_stealth_capable:
			stealth_revealed = false
			_apply_stealth_visual(true)
		# V3 Pillar 2 — Mesh provider aura ring on the ground around
		# any unit whose stat sheet declares it a Mesh source.
		if stats.mesh_provider_radius > 0.0:
			_add_mesh_aura_ring(stats.mesh_provider_radius)


func _init_hp() -> void:
	alive_count = stats.squad_size
	member_hp.clear()
	for i: int in stats.squad_size:
		member_hp.append(stats.hp_per_unit)


## --- Squad Visuals ---

func _build_squad_visuals() -> void:
	# Remove old visuals
	for mesh: Node3D in _member_meshes:
		if is_instance_valid(mesh):
			mesh.queue_free()
	_member_meshes.clear()
	_member_data.clear()
	if _color_shell and is_instance_valid(_color_shell):
		_color_shell.queue_free()
		_color_shell = null

	# Remove the scene's default mesh/collision (we replace them)
	var old_mesh: Node = get_node_or_null("MeshInstance3D")
	if old_mesh:
		old_mesh.queue_free()

	var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	# Per-unit shape overrides -- lets a single named unit diverge
	# from its class baseline without needing a whole new
	# CLASS_SHAPES entry (which would also impact every other
	# heavy chassis). Currently used by the Forgemaster to swap
	# its leg layout to a 6-leg side-mount + run a taller chassis
	# that visually separates the support / caster mech from the
	# Bulwark gunline.
	shape_data = _maybe_override_shape_for_unit(shape_data)
	var team_color: Color = _resolve_team_color()

	var squad: int = stats.squad_size
	var unit_offsets: Array = FORMATION_OFFSETS.get(squad, FORMATION_OFFSETS[1])
	var spacing: float = shape_data.get("formation_spacing", 1.5) as float

	for i: int in squad:
		var u: Vector2 = unit_offsets[i] as Vector2
		var offset := Vector3(u.x * spacing, 0.0, u.y * spacing)
		var member_info: Dictionary = _build_mech_member(i, offset, shape_data, team_color)
		_member_meshes.append(member_info["root"])
		_member_data.append(member_info)
		# Per-pivot mesh bake — deferred. _bake_member_pivots enqueues
		# the work into _pending_bake_tasks; _process drains it one
		# entry per frame. Bake count is the same as before
		# (~12 pivots/member × 5 members = ~60 tasks per squad spawn)
		# but the cost is spread across ~60 frames instead of running
		# synchronously inside _ready and freezing the game for a
		# multi-second window on every spawn.
		_bake_member_pivots(member_info)
		# X-ray silhouette REMAINS DISABLED. A second attempt with a
		# FRAGCOORD.z vs DEPTH_TEXTURE.r comparison (avoiding the
		# INV_PROJECTION_MATRIX reconstruction) still drew the silhouette
		# everywhere — units appeared as white orbs over their own
		# meshes. The DEPTH_TEXTURE sample seems to return inconsistent
		# values during the transparent pass in Forward+. Until a
		# reliable approach is found (likely building-side: a
		# next_pass material on the Building that draws unit
		# silhouettes through itself), the feature stays off.

	# Collision shape covers the squad footprint, sized to the actual mech bulk.
	var torso_size: Vector3 = shape_data["torso"] as Vector3
	var hip_y: float = shape_data["hip_y"] as float
	var head_size: Vector3 = shape_data["head"] as Vector3
	var total_h: float = hip_y + torso_size.y + head_size.y
	var col_node: CollisionShape3D = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_node:
		var col_shape := BoxShape3D.new()
		# Collision shape tracks the LEADER body only — not the whole
		# formation. Heavies were getting wedged in narrow corridors
		# because the bounding box was sized to the squad spread (e.g.
		# Bulwark = ~6u wide), much wider than the navmesh's planning
		# clearance (1.5u). Shrinking the box to ~ the leader's torso
		# means heavy squads thread through the same paths the planner
		# routed for them; squad members are visual orbiters with no
		# collision of their own, so this doesn't make them clip
		# anything physically meaningful.
		var leader_box: float = maxf(torso_size.x, torso_size.z) + 0.4
		col_shape.size = Vector3(leader_box, total_h, leader_box)
		col_node.shape = col_shape
		col_node.position.y = total_h / 2.0
		# Cache the rest-state size + shape ref so the per-frame
		# move-shrink can resize cheaply without re-allocating.
		# Moving units shrink to MOVING_COLLISION_SCALE of their
		# rest-state XZ extent so squads can pass through each other
		# in transit while still reading as solid bodies at rest.
		_movement_collision_shape = col_shape
		_movement_collision_rest_size = col_shape.size
		_movement_collision_currently_moving = false

	# Per-member click area -- the body's collision shape only covers
	# the leader (intentional for movement so heavies thread narrow
	# corridors). Without an extra hitbox at every member position the
	# player's right-click ray would miss the off-formation members
	# and the click silently failed. Area3D on UNIT_LAYER makes every
	# member individually pickable; both _raycast_unit and the click
	# resolver walk up to recover the parent Unit.
	var prev_area: Node = get_node_or_null("ClickArea")
	if prev_area:
		prev_area.queue_free()
	var click_area := Area3D.new()
	click_area.name = "ClickArea"
	click_area.collision_layer = 2
	click_area.collision_mask = 0
	click_area.monitoring = false
	click_area.monitorable = false
	# Pick-sphere radius enlarged ~47% from original (0.6×+0.25) so clicks
	# landing on the edge of any visible mech model register cleanly.
	# Formula: (max chassis XZ extent) * 0.9 + 0.35. Representative values:
	#   engineer  ~0.84u (was ~0.58u), medium ~0.98u (was ~0.67u),
	#   heavy     ~2.49u (was ~1.68u)
	var member_radius: float = maxf(torso_size.x, torso_size.z) * 0.9 + 0.35
	for i: int in stats.squad_size:
		var u: Vector2 = unit_offsets[i] as Vector2
		var member_col := CollisionShape3D.new()
		var member_sphere := SphereShape3D.new()
		member_sphere.radius = member_radius
		member_col.shape = member_sphere
		member_col.position = Vector3(u.x * spacing, total_h * 0.5, u.y * spacing)
		click_area.add_child(member_col)
	add_child(click_area)

	# Drone bay marker -- combat_component looks up a 'DroneBay'
	# Marker3D child on the carrier and launches drones from it
	# instead of a random offset. Carriers (currently the Harbinger
	# family) get a marker positioned just above and behind the
	# squad so drones visibly leave the chassis from a real bay.
	var prev_bay: Node = get_node_or_null("DroneBay")
	if prev_bay:
		prev_bay.queue_free()
	if stats.unit_name.findn("Harbinger") >= 0:
		var bay := Marker3D.new()
		bay.name = "DroneBay"
		# Align with the new visible drone backpack: torso-level on the
		# REAR face (+Z is back per the head-visor convention). Drones
		# launch from where the player can see the hatches.
		bay.position = Vector3(0.0, hip_y + torso_size.y * 0.78, torso_size.z * 0.5 + 0.45)
		add_child(bay)

	# Pass 1 MultiMesh verification probe was removed — the
	# MeshCombiner.bake_stats() call ran the full recursive combine
	# synchronously just to print stat numbers (~79 ms in report 610),
	# undoing the per-pivot deferred-bake fix on first-spawn-of-each-
	# unit-type. The deferred bake queue handles the real work; we
	# don't need the diagnostic anymore.

	# Re-apply stealth concealment if this unit is already cloaked.
	# _build_squad_visuals rebuilds all member meshes with fresh
	# materials (alpha = 1.0 by default). If the unit was concealed
	# before the rebuild — e.g. because _refresh_starter_unit_visuals
	# calls _build_squad_visuals AFTER _ready already set stealth — the
	# new materials must be faded immediately so starter Specters don't
	# appear fully visible until the next _tick_stealth pass.
	if stats and stats.is_stealth_capable and not stealth_revealed:
		_apply_stealth_visual(true)


func _bake_member_pivots(member_info: Dictionary) -> void:
	## Per-pivot mesh bake. Walks the member's Node3D subtree and
	## folds each pivot's IMMEDIATE MeshInstance3D children into a
	## single combined ArrayMesh on that pivot. Animated pivots
	## (legs / head / cannons / shoulders) keep their Node3D wrapper
	## so animation still works.
	##
	## DEFERRED: the actual MeshCombiner.combine_immediate call is
	## ~50-100ms per pivot. Running ~60 of them synchronously inside
	## Unit._ready froze the game for ~3 seconds on every squad spawn
	## (error report 601). Now we collect bake tasks and pop one per
	## process tick, spreading the cost across ~60 frames (~1 sec of
	## slight stutter instead of a multi-second hard freeze).
	var member_root: Node3D = member_info.get("root", null) as Node3D
	if member_root == null or not is_instance_valid(member_root):
		return
	# Build the skip set: any MeshInstance3D the animation tick
	# rotates directly.
	var skip_ids: Dictionary = {}
	var head_val: Variant = member_info.get("head", null)
	if head_val is MeshInstance3D:
		skip_ids[(head_val as MeshInstance3D).get_instance_id()] = true
	for key: String in ["legs", "cannons", "shoulders", "track_ribs"]:
		var arr: Array = member_info.get(key, []) as Array
		for n: Variant in arr:
			if n is MeshInstance3D:
				skip_ids[(n as MeshInstance3D).get_instance_id()] = true
	# Build a cache-key prefix scoped to this (unit_class, team_color)
	# pair. The recursive collector appends the per-pivot node-name
	# path so the final key identifies a specific (class, color, pivot)
	# combination — second-and-later instances of the same combo hit
	# MeshCombiner._per_class_bake_cache and reuse the ArrayMesh
	# instead of re-running combine_immediate.
	var color_packed: int = _pack_color_for_bake_key(_resolve_team_color())
	var class_name_str: String = stats.unit_name if stats else ""
	var key_prefix: String = "%s|%d" % [class_name_str, color_packed]
	_collect_bake_tasks(member_root, skip_ids, key_prefix)
	if not _pending_bake_tasks.is_empty():
		set_process(true)


## Deferred-bake queue. Each entry is { node: Node3D, skip_ids: Dictionary, cache_key: String }.
var _pending_bake_tasks: Array[Dictionary] = []


static func _pack_color_for_bake_key(c: Color) -> int:
	return int(c.r * 255.0) | (int(c.g * 255.0) << 8) | (int(c.b * 255.0) << 16) | (int(c.a * 255.0) << 24)


func _collect_bake_tasks(node: Node3D, skip_ids: Dictionary, key_prefix: String) -> void:
	## Tree-walk that enqueues a bake task for `node` and recurses
	## into the same children _bake_pivot_subtree used to recurse into.
	## Cheap (no mesh work) — the actual MeshCombiner cost happens
	## later, one task at a time, in _process.
	if not is_instance_valid(node):
		return
	var node_name: String = str(node.name)
	# Auto-generated names start with '@' and embed the instance id —
	# they differ per spawn, so the cache key would never hit. Skip
	# caching for those by passing an empty key (MeshCombiner falls
	# back to the uncached path).
	var path_here: String = key_prefix + "|" + node_name
	var cache_key: String = path_here if not node_name.contains("@") and not key_prefix.contains("@") else ""
	_pending_bake_tasks.append({
		"node": node,
		"skip_ids": skip_ids,
		"cache_key": cache_key,
	})
	for child: Node in node.get_children():
		if child is MeshInstance3D:
			# Skipped MI3D (e.g. head) — recurse so nested static
			# decorations parented to it still get baked.
			if skip_ids.has((child as MeshInstance3D).get_instance_id()):
				_collect_bake_tasks(child as Node3D, skip_ids, path_here)
		elif child is Node3D:
			_collect_bake_tasks(child as Node3D, skip_ids, path_here)


func _process(_delta: float) -> void:
	## Drains _pending_bake_tasks one entry per frame. Disables itself
	## once the queue is empty so idle units pay no _process cost.
	if _pending_bake_tasks.is_empty():
		set_process(false)
		return
	var task: Dictionary = _pending_bake_tasks.pop_front()
	# Read as Variant FIRST and validate before any typed cast. Casting
	# a freed Object via `as Node3D` errors with "Trying to cast a freed
	# object" before the null/is_instance_valid check can fire (scene
	# transitions where the unit dies mid-bake-queue triggered this).
	var node_v: Variant = task.get("node")
	if not is_instance_valid(node_v):
		return
	var node: Node3D = node_v as Node3D
	if node == null:
		return
	var skip_ids: Dictionary = task.get("skip_ids") as Dictionary
	var cache_key: String = task.get("cache_key", "") as String
	_bake_one_pivot(node, skip_ids, cache_key)


func _bake_one_pivot(node: Node3D, skip_ids: Dictionary, cache_key: String) -> void:
	## Fold this node's IMMEDIATE MeshInstance3D children (minus
	## skip_ids) into one combined ArrayMesh on the node. No recursion
	## — children's bakes are separate queue entries that ran (or
	## will run) on their own ticks. Uses the per-class bake cache
	## when cache_key is non-empty.
	var to_bake: Array[MeshInstance3D] = []
	for child: Node in node.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child as MeshInstance3D
			if not skip_ids.has(mi.get_instance_id()) and mi.mesh != null:
				to_bake.append(mi)
	if to_bake.size() < 2:
		# Single mesh (or none): nothing useful to merge. Same gate
		# the synchronous version used.
		return
	var combined: ArrayMesh = MeshCombiner.combine_immediate_cached(node, skip_ids, cache_key)
	if combined == null or combined.get_surface_count() == 0:
		return
	var baked := MeshInstance3D.new()
	baked.name = "BakedMesh"
	baked.mesh = combined
	node.add_child(baked)
	for mi: MeshInstance3D in to_bake:
		mi.free()


## Cached x-ray shader instance -- one ShaderMaterial parent that
## every silhouette mesh inherits via `next_pass`. Each member
## clones the material so it can carry its own team-colour
## uniform without back-propagating to the parent.
static var _xray_shader: Shader = null
func _attach_xray_silhouette(member: Node3D, shape: Dictionary, team_color: Color) -> void:
	## Spawns a single capsule mesh per squad member that renders
	## only when occluded by something in front of it (the shader
	## samples DEPTH_TEXTURE and discards fragments that AREN'T
	## behind an opaque occluder). Cheap proxy for a full chassis
	## silhouette -- a single capsule sized to the unit's bounding
	## box reads as 'unit position behind the building' without
	## the cost of duplicating every barrel + leg.
	if _xray_shader == null:
		_xray_shader = load("res://shaders/x_ray_silhouette.gdshader") as Shader
	if _xray_shader == null:
		return
	# Bounding capsule sized off the chassis dimensions in the
	# class shape. For mechs hip_y + torso.y is the body height;
	# for transport / tank shapes torso.y is small but we add a
	# minimum so tracked vehicles still get a readable silhouette.
	var hip_y: float = shape.get("hip_y", 0.0) as float
	var torso: Vector3 = shape.get("torso", Vector3(1.0, 1.0, 1.0)) as Vector3
	var head: Vector3 = shape.get("head", Vector3.ZERO) as Vector3
	var height: float = maxf(hip_y + torso.y + head.y, 1.6)
	var radius: float = maxf(maxf(torso.x, torso.z) * 0.55, 0.55)
	var sil := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = height
	sil.mesh = cap
	# Capsule's pivot is its centre; lift it so the bottom sits
	# at member Y=0 (ground level relative to the squad member).
	sil.position.y = height * 0.5
	# Don't cast shadows from the silhouette -- it's a UI element
	# not a physical mesh.
	sil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Render priority above the standard 3D pass so the silhouette
	# samples the depth texture AFTER buildings have written their
	# depth. Without this the silhouette can sample its own / a
	# co-pass mesh's depth and behave inconsistently.
	sil.set("sorting_offset", 0.5)
	var mat := ShaderMaterial.new()
	mat.shader = _xray_shader
	# Per-team colour with comfortable alpha so the silhouette
	# reads as identity without overwhelming the underlying
	# building behind it.
	var tinted: Color = Color(team_color.r, team_color.g, team_color.b, 0.85)
	mat.set_shader_parameter("outline_color", tinted)
	mat.set_shader_parameter("depth_bias", 0.05)
	sil.material_override = mat
	member.add_child(sil)


func _build_mech_member(index: int, offset: Vector3, shape: Dictionary, team_color: Color) -> Dictionary:
	## Builds one mech member and returns references to its animatable parts.
	# Wächter — Inheritor medium tracked tank. Built off the same
	# tank-builder pattern as Breacher/Courier but with a tesla-coil
	# mast turret instead of cannons. Lives in the medium unit_class
	# (so stat formulas keep treating it as a medium) but dispatches
	# to the tracked builder by name.
	if stats and stats.unit_name.findn("Wächter") >= 0:
		var wachter_result: Dictionary = _build_wachter_tank_member(index, offset, team_color)
		if "root" in wachter_result:
			var wroot: Variant = wachter_result["root"]
			if wroot is Node3D:
				(wroot as Node3D).scale = Vector3(0.9, 0.9, 0.9)
		return wachter_result
	# Inquisitor Tank dispatch — Heliarch hover tank. unit_class is
	# "medium" but it needs the tank-vehicle silhouette (low wide hull,
	# hover skirts, centred plasma turret, forward floodlight). Without
	# this dispatch the unit rendered as a humanoid mech holding a
	# 'flashlight-looking gun' (playtest 2026-05-16: "inquisitor tank
	# currently is not a tank and got an odd flashlight looking gun").
	if stats and stats.unit_name.findn("Inquisitor Tank") >= 0:
		var inq_result: Dictionary = _build_inquisitor_hover_tank_member(index, offset, team_color)
		if "root" in inq_result:
			var iqroot: Variant = inq_result["root"]
			if iqroot is Node3D:
				# 0.78 instead of 0.95 — the previous scale was too
				# bulky for the squad-of-3 footprint AND made the
				# chassis read as a tracked tank rather than a hover
				# craft. Combined with the redesigned single-disc base
				# inside the builder, this makes the unit visually
				# distinct from the Combine ground tanks.
				(iqroot as Node3D).scale = Vector3(0.78, 0.78, 0.78)
		return inq_result
	# Conquistador dispatch — centaur silhouette: wide quadruped lower
	# body + humanoid upper torso with the Heat Hammer. Per playtest
	# 2026-05-16: "conquistador should be melee unit ... maybe scaled
	# down slightly and get humanoid upper body above basically a
	# centaur design". The default humanoid biped read as too generic
	# for a heavy melee bruiser.
	if stats and stats.unit_name.findn("Conquistador") >= 0:
		var conq_result: Dictionary = _build_conquistador_centaur_member(index, offset, team_color)
		if "root" in conq_result:
			var cqroot: Variant = conq_result["root"]
			if cqroot is Node3D:
				(cqroot as Node3D).scale = Vector3(0.88, 0.88, 0.88)
		return conq_result
	# Sol Invictus dispatch — Heliarch apex "walking sun". Custom huge
	# silhouette (~3× the default apex chassis) with a head-mounted
	# Solar Lance + arm-mounted plasma turrets + crown of solar spires.
	# Per user 2026-05-19: "sol invictus should be triple its current
	# size and have details added to still look good that large. beam
	# weapon from head, arm cannons = plasma turrets."
	if stats and stats.unit_name.findn("Sol Invictus") >= 0:
		return _build_sol_invictus_member(index, offset, team_color)
	# Herald dispatch — pyre-priest caster. Tall slim mech with a
	# chest-mounted acoustic horn array + hanging brass chains.
	if stats and stats.unit_name.findn("Herald") >= 0:
		return _build_herald_priest_member(index, offset, team_color)
	# Censer dispatch — walking thurible / elite chemical caster.
	# Domed reactor-temple chassis on legs with a swinging cloud
	# launcher pendant.
	if stats and stats.unit_name.findn("Censer") >= 0:
		return _build_censer_thurible_member(index, offset, team_color)
	# Boyar / Breacher Tank dispatch by name. The Boyar branches
	# (Dozer/Plow) live in unit_class="medium" for stat-formula
	# purposes but visually MUST be tracked tanks, not the medium
	# biped fallback. Without this name-based dispatch the player
	# sees Boyars rendering as Borzoi-style bipeds (playtest
	# 2026-05-15: "boyars currently have the squad pacing of tanks
	# but seem to use the model of the borzoi on accident").
	if stats and stats.unit_name.findn("Breacher") >= 0:
		var btank_result: Dictionary
		if stats.unit_name.findn("Mortar") >= 0:
			btank_result = _build_breacher_mortar_member(index, offset, team_color)
		elif stats.unit_name.findn("Salvo") >= 0:
			btank_result = _build_breacher_salvo_member(index, offset, team_color)
		else:
			btank_result = _build_breacher_tank_member(index, offset, team_color)
		if "root" in btank_result:
			var btroot: Variant = btank_result["root"]
			if btroot is Node3D:
				(btroot as Node3D).scale = Vector3(0.9, 0.9, 0.9)
		return btank_result
	# Transport class doesn't have legs / torso / cockpit — bail out
	# of the standard mech build and call the dedicated tracked-vehicle
	# builder instead. Returns the same dictionary shape so the caller's
	# squad-visuals bookkeeping keeps working.
	if stats and stats.unit_class == &"transport":
		# Per-name dispatch within transport class so different
		# tracked vehicles get distinct silhouettes. Breacher Tank
		# uses a casemate (no-turret) tank-destroyer build that
		# diverges from the Meridian Courier's turreted
		# transport silhouette; defaults route to Courier.
		var tank_result: Dictionary
		if stats.unit_name.findn("Breacher") >= 0:
			# Branch variants get distinct silhouettes -- Mortar
			# is an open-topped artillery vehicle, Salvo carries
			# vertical missile pods. Both lose the casemate +
			# main cannon of the base Breacher.
			if stats.unit_name.findn("Mortar") >= 0:
				tank_result = _build_breacher_mortar_member(index, offset, team_color)
			elif stats.unit_name.findn("Salvo") >= 0:
				tank_result = _build_breacher_salvo_member(index, offset, team_color)
			else:
				tank_result = _build_breacher_tank_member(index, offset, team_color)
		else:
			tank_result = _build_courier_tank_member(index, offset, team_color)
		# Tank-visual shrink: user feedback that Breacher and Courier
		# read too large for the squad-of-3 footprint. 0.9 trims them
		# down without losing the tank silhouette.
		if "root" in tank_result:
			var tank_root: Variant = tank_result["root"]
			if tank_root is Node3D:
				(tank_root as Node3D).scale = Vector3(0.9, 0.9, 0.9)
		return tank_result
	var hip_y: float = shape["hip_y"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var head_size: Vector3 = shape["head"] as Vector3
	var head_shape: String = shape["head_shape"] as String
	var cannon_size: Vector3 = shape["cannon"] as Vector3
	var cannon_x: float = shape["cannon_x"] as float
	var cannon_kind: String = shape["cannon_kind"] as String
	var antenna_h: float = shape["antenna"] as float
	var base_color_raw: Color = shape["color"] as Color
	# Re-tint the per-class base color for Sable so units render with the
	# faction's matte-black + cool-blue-white identity instead of Anvil's
	# warm grey-amber palette (V3 §"Pillar 1"). Anvil units pass through
	# unchanged.
	var base_color: Color = _faction_tint_chassis(base_color_raw)
	var leg_kind: String = shape.get("leg_kind", "biped") as String
	var torso_lean: float = shape.get("torso_lean", 0.0) as float
	var cannon_mount: String = shape.get("cannon_mount", "shoulder") as String
	var trim_color: Color = Color(base_color.r + 0.06, base_color.g + 0.06, base_color.b + 0.06, 1.0)

	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []

	# --- Legs (per-class skeleton) ---
	# Pass the faction-tinted base color into leg construction so the
	# legs share the chassis palette (Sable matte-black instead of the
	# Anvil grey-tan baked into shape["color"]).
	var leg_shape: Dictionary = shape.duplicate()
	leg_shape["color"] = base_color
	var leg_info: Dictionary = _build_legs(member, leg_shape, mats, leg_kind)
	var legs: Array = leg_info["legs"] as Array
	var leg_phases: Array = leg_info["phases"] as Array

	# --- Torso ---
	# Torso pivot lets the Hound lean forward without skewing the legs.
	var torso_pivot := Node3D.new()
	torso_pivot.name = "TorsoPivot"
	torso_pivot.position.y = hip_y
	torso_pivot.rotation.x = -torso_lean  # negative X rotation tips the upper body forward
	member.add_child(torso_pivot)

	var torso := MeshInstance3D.new()
	var torso_box := BoxMesh.new()
	torso_box.size = torso_size
	torso.mesh = torso_box
	torso.position.y = torso_size.y / 2.0
	var torso_mat := _make_metal_mat(base_color)
	torso.set_surface_override_material(0, torso_mat)
	torso_pivot.add_child(torso)
	mats.append(torso_mat)

	# Team-color band. Anvil mechs have a flat front/back/sides hull
	# that the original wrap-around band reads cleanly across. Sable's
	# faceted prow + canted shoulder block hides most of the band's
	# flat faces, so a full-size band balloons out at the seams and
	# reads as a slab of player-color on the chassis. For Sable we
	# replace the wrap with two thin edge slivers on the LEFT and
	# RIGHT sides only — they peek past the prow without dominating
	# the silhouette.
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team_color
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team_color
	stripe_mat.emission_energy_multiplier = 1.4
	stripe_mat.roughness = 0.6
	if _faction_id() == 1:
		# Two slim edge slivers, one per side, just barely poking past
		# the chassis silhouette so the team color reads at the edges.
		for sliver_side: int in 2:
			var sx: float = -torso_size.x * 0.5 - 0.03 if sliver_side == 0 else torso_size.x * 0.5 + 0.03
			var sliver := MeshInstance3D.new()
			var sl_box := BoxMesh.new()
			sl_box.size = Vector3(0.06, torso_size.y * 0.32, torso_size.z * 0.55)
			sliver.mesh = sl_box
			sliver.position = Vector3(sx, torso_size.y * 0.58, 0.0)
			sliver.set_surface_override_material(0, stripe_mat)
			torso_pivot.add_child(sliver)
		mats.append(stripe_mat)
	else:
		var stripe := MeshInstance3D.new()
		var stripe_box := BoxMesh.new()
		stripe_box.size = Vector3(torso_size.x + 0.02, torso_size.y * 0.18, torso_size.z + 0.02)
		stripe.mesh = stripe_box
		stripe.position.y = torso_size.y * 0.65
		stripe.set_surface_override_material(0, stripe_mat)
		torso_pivot.add_child(stripe)
		mats.append(stripe_mat)

	# Faction identity strip on the chest. Each faction gets a distinctive
	# accent so the silhouette reads at a glance:
	#   Anvil    — horizontal brass band (institutional / liturgical)
	#   Sable    — small violet core-glow (technocratic / signal-dense)
	#   Inheritor — pale gold leaf sigil on dark backing + violet niche
	#               (reverent / archaeological; Architect indicator)
	#   Heliarch — exposed reactor-amber core glow + vertical vent stack
	#               (mystical / ecstatic; "exposed reactor cores" per spec)
	var faction_id_for_accent: int = _faction_id()
	if faction_id_for_accent == 1:
		var glow_mat := StandardMaterial3D.new()
		glow_mat.albedo_color = SABLE_NEON
		glow_mat.emission_enabled = true
		glow_mat.emission = SABLE_NEON
		glow_mat.emission_energy_multiplier = 2.4
		glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var glow := MeshInstance3D.new()
		var glow_sphere := SphereMesh.new()
		glow_sphere.radius = torso_size.x * 0.08
		glow_sphere.height = torso_size.x * 0.16
		glow.mesh = glow_sphere
		glow.position = Vector3(0.0, torso_size.y * 0.50, -torso_size.z * 0.5 - 0.02)
		glow.set_surface_override_material(0, glow_mat)
		torso_pivot.add_child(glow)
		mats.append(glow_mat)
		var glow_light := OmniLight3D.new()
		glow_light.light_color = SABLE_NEON
		glow_light.light_energy = 0.55
		glow_light.omni_range = torso_size.x * 1.4
		glow_light.position = glow.position
		torso_pivot.add_child(glow_light)
	elif faction_id_for_accent == 2:
		# Inheritor: dark backing plate with a pale-gold sigil at the
		# top and a small Architect-violet niche-glow at the bottom.
		# Reads as "reassembled relic with something still active inside".
		var backing := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(torso_size.x * 0.42, torso_size.y * 0.54, 0.03)
		backing.mesh = bb
		backing.position = Vector3(0.0, torso_size.y * 0.50, -torso_size.z * 0.5 - 0.02)
		var backing_mat := _make_metal_mat(Color(0.10, 0.09, 0.08))
		backing.set_surface_override_material(0, backing_mat)
		torso_pivot.add_child(backing)
		mats.append(backing_mat)
		# Gold-leaf sigil — a stubby horizontal bar on the upper backing.
		var sigil := MeshInstance3D.new()
		var sigil_box := BoxMesh.new()
		sigil_box.size = Vector3(torso_size.x * 0.28, torso_size.y * 0.06, 0.04)
		sigil.mesh = sigil_box
		sigil.position = Vector3(0.0, torso_size.y * 0.68, -torso_size.z * 0.5 - 0.035)
		var sigil_mat := StandardMaterial3D.new()
		sigil_mat.albedo_color = Color(0.95, 0.78, 0.35)
		sigil_mat.emission_enabled = true
		sigil_mat.emission = Color(0.95, 0.78, 0.35)
		sigil_mat.emission_energy_multiplier = 0.45
		sigil_mat.metallic = 0.8
		sigil_mat.roughness = 0.3
		sigil.set_surface_override_material(0, sigil_mat)
		torso_pivot.add_child(sigil)
		# Violet Architect-niche — small round glow on the lower backing.
		var niche := MeshInstance3D.new()
		var niche_sphere := SphereMesh.new()
		niche_sphere.radius = torso_size.x * 0.07
		niche_sphere.height = torso_size.x * 0.14
		niche.mesh = niche_sphere
		var niche_mat := StandardMaterial3D.new()
		niche_mat.albedo_color = Color(0.70, 0.55, 1.0)
		niche_mat.emission_enabled = true
		niche_mat.emission = Color(0.70, 0.55, 1.0)
		niche_mat.emission_energy_multiplier = 2.2
		niche_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		niche.position = Vector3(0.0, torso_size.y * 0.34, -torso_size.z * 0.5 - 0.03)
		niche.set_surface_override_material(0, niche_mat)
		torso_pivot.add_child(niche)
		mats.append(niche_mat)
		var niche_light := OmniLight3D.new()
		niche_light.light_color = Color(0.70, 0.55, 1.0)
		niche_light.light_energy = 0.45
		niche_light.omni_range = torso_size.x * 1.2
		niche_light.position = niche.position
		torso_pivot.add_child(niche_light)
	elif faction_id_for_accent == 3:
		# Heliarch: reactor-amber chest grille (the defining visual feature
		# per 03_factions §3.4 — "every Heliarch mech has at least one
		# visible point where the reactor is glowing through the armor")
		# plus a single vertical vent-stack rising behind the torso.
		var reactor := MeshInstance3D.new()
		var reactor_box := BoxMesh.new()
		reactor_box.size = Vector3(torso_size.x * 0.42, torso_size.y * 0.38, 0.06)
		reactor.mesh = reactor_box
		reactor.position = Vector3(0.0, torso_size.y * 0.48, -torso_size.z * 0.5 - 0.025)
		var reactor_mat := StandardMaterial3D.new()
		reactor_mat.albedo_color = Color(1.0, 0.55, 0.20)
		reactor_mat.emission_enabled = true
		reactor_mat.emission = Color(1.0, 0.55, 0.20)
		reactor_mat.emission_energy_multiplier = 2.6
		reactor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		reactor.set_surface_override_material(0, reactor_mat)
		torso_pivot.add_child(reactor)
		mats.append(reactor_mat)
		# Brass ribbed grille bars over the reactor glow — three thin
		# vertical bars so the glow reads as "through armor", not painted.
		for grille_i: int in 3:
			var bar := MeshInstance3D.new()
			var bar_box := BoxMesh.new()
			bar_box.size = Vector3(0.04, torso_size.y * 0.40, 0.04)
			bar.mesh = bar_box
			var spacing: float = torso_size.x * 0.12
			bar.position = Vector3(
				(grille_i - 1) * spacing,
				torso_size.y * 0.48,
				-torso_size.z * 0.5 - 0.06,
			)
			var bar_mat := _make_metal_mat(Color(0.55, 0.40, 0.20))
			bar.set_surface_override_material(0, bar_mat)
			torso_pivot.add_child(bar)
		# Reactor light so the glow casts onto the surrounding chassis.
		var reactor_light := OmniLight3D.new()
		reactor_light.light_color = Color(1.0, 0.55, 0.20)
		reactor_light.light_energy = 0.75
		reactor_light.omni_range = torso_size.x * 1.8
		reactor_light.position = reactor.position
		torso_pivot.add_child(reactor_light)
		# Vertical vent-stack rising from the back of the torso.
		var vent := MeshInstance3D.new()
		var vent_cyl := CylinderMesh.new()
		vent_cyl.top_radius = torso_size.x * 0.10
		vent_cyl.bottom_radius = torso_size.x * 0.14
		vent_cyl.height = torso_size.y * 0.70
		vent.mesh = vent_cyl
		vent.position = Vector3(0.0, torso_size.y * 1.05, torso_size.z * 0.30)
		var vent_mat := _make_metal_mat(Color(0.18, 0.16, 0.14))
		vent.set_surface_override_material(0, vent_mat)
		torso_pivot.add_child(vent)
		# Vent-stack mouth — small amber emissive cap at the top.
		var vent_cap := MeshInstance3D.new()
		var vent_cap_cyl := CylinderMesh.new()
		vent_cap_cyl.top_radius = torso_size.x * 0.10
		vent_cap_cyl.bottom_radius = torso_size.x * 0.10
		vent_cap_cyl.height = 0.04
		vent_cap.mesh = vent_cap_cyl
		vent_cap.position = vent.position + Vector3(0.0, torso_size.y * 0.36, 0.0)
		var vent_cap_mat := StandardMaterial3D.new()
		vent_cap_mat.albedo_color = Color(1.0, 0.45, 0.15)
		vent_cap_mat.emission_enabled = true
		vent_cap_mat.emission = Color(1.0, 0.45, 0.15)
		vent_cap_mat.emission_energy_multiplier = 1.6
		vent_cap_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		vent_cap.set_surface_override_material(0, vent_cap_mat)
		torso_pivot.add_child(vent_cap)
	else:
		# Anvil — horizontal brass band.
		var brass := MeshInstance3D.new()
		var brass_box := BoxMesh.new()
		brass_box.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.08, 0.04)
		brass.mesh = brass_box
		brass.position = Vector3(0.0, torso_size.y * 0.18, -torso_size.z * 0.5 - 0.02)
		var brass_mat := StandardMaterial3D.new()
		brass_mat.albedo_color = ANVIL_BRASS
		brass_mat.emission_enabled = true
		brass_mat.emission = ANVIL_BRASS
		brass_mat.emission_energy_multiplier = 0.5
		brass_mat.metallic = 0.7
		brass_mat.roughness = 0.4
		brass.set_surface_override_material(0, brass_mat)
		torso_pivot.add_child(brass)

	# --- Surface details (chest grille + back vent) on every mech that doesn't
	# already have its own elaborate hull (the Bulwark platform builds its own).
	if cannon_kind != "platform":
		_add_chassis_panels(torso_pivot, torso_size, mats)

	# --- Head / Cockpit ---
	# Sentinel-style mechs (Hound) keep the cockpit centered above the legs.
	var head_fwd_offset: float = 0.0
	var head: MeshInstance3D = MeshInstance3D.new()
	if head_shape == "sphere":
		var sph := SphereMesh.new()
		sph.radius = head_size.x * 0.5
		sph.height = head_size.y
		head.mesh = sph
	else:
		var hbox := BoxMesh.new()
		hbox.size = head_size
		head.mesh = hbox
	head.position = Vector3(0, torso_size.y + head_size.y / 2.0, head_fwd_offset)
	var head_mat := _make_metal_mat(trim_color)
	head.set_surface_override_material(0, head_mat)
	torso_pivot.add_child(head)
	mats.append(head_mat)

	# Cockpit visor — small emissive band on the FRONT of the head (-Z is forward).
	var visor := MeshInstance3D.new()
	var visor_box := BoxMesh.new()
	visor_box.size = Vector3(head_size.x * 0.85, head_size.y * 0.25, head_size.z * 0.05)
	visor.mesh = visor_box
	visor.position = Vector3(0, torso_size.y + head_size.y * 0.55, head_fwd_offset - head_size.z * 0.5 - 0.005)
	var visor_mat := StandardMaterial3D.new()
	# Hound's visor glows red (mean look); everyone else gets the standard cyan.
	if leg_kind == "chicken":
		visor_mat.albedo_color = Color(0.9, 0.15, 0.1)
		visor_mat.emission = Color(1.0, 0.2, 0.1)
	else:
		visor_mat.albedo_color = Color(0.05, 0.6, 0.9)
		visor_mat.emission = Color(0.2, 0.8, 1.0)
	visor_mat.emission_enabled = true
	visor_mat.emission_energy_multiplier = 1.6
	visor.set_surface_override_material(0, visor_mat)
	torso_pivot.add_child(visor)
	mats.append(visor_mat)

	# Branch-variant cap on top of the head — small visual cue so the
	# player can tell a Tracker apart from a Ripper at a glance even
	# though both share the medium-class silhouette.
	var unit_name_str: String = stats.unit_name if stats else ""
	if unit_name_str.findn("Tracker") >= 0 or unit_name_str.findn("Ripper") >= 0:
		var variant_mark := MeshInstance3D.new()
		var mark_sphere := SphereMesh.new()
		mark_sphere.radius = head_size.x * 0.18
		mark_sphere.height = head_size.x * 0.36
		variant_mark.mesh = mark_sphere
		variant_mark.position = Vector3(0.0, torso_size.y + head_size.y + head_size.x * 0.18, head_fwd_offset)
		var mark_mat := StandardMaterial3D.new()
		if unit_name_str.findn("Tracker") >= 0:
			# Cyan signal — long-range / sensor variant.
			mark_mat.albedo_color = Color(0.2, 0.85, 1.0, 1.0)
			mark_mat.emission = Color(0.3, 0.9, 1.0, 1.0)
		else:
			# Hot red — close-range brawler variant.
			mark_mat.albedo_color = Color(1.0, 0.3, 0.2, 1.0)
			mark_mat.emission = Color(1.0, 0.4, 0.2, 1.0)
		mark_mat.emission_enabled = true
		mark_mat.emission_energy_multiplier = 2.2
		variant_mark.set_surface_override_material(0, mark_mat)
		torso_pivot.add_child(variant_mark)
		mats.append(mark_mat)

	# --- Shoulders / Cannons ---
	var shoulders: Array[Node3D] = []
	var cannons: Array[Node3D] = []
	# Parallel to `cannons` — captures each pivot's rest z so recoil can be
	# applied as an additive offset (the Bulwark hull-mounted gun sits at the
	# chassis front, not at z=0).
	var cannon_rest_z: Array = []
	# Parallel to `cannons` — distance from each pivot's origin to its barrel
	# tip (always positive; we treat -Z as forward when looking up the muzzle
	# point in get_muzzle_positions).
	var cannon_muzzle_z: Array = []

	# Forgemaster reuses the heavy chassis silhouette but its actual
	# weapon is a light Riveter Autocannon — NOT the Bulwark-class
	# main gun. The platform branch checks this flag and routes to
	# a much smaller compact-cannon build for Forgemaster instead
	# of the full mantlet + barrel + sleeve + muzzle assembly.
	var is_forgemaster: bool = stats != null and stats.unit_name.findn("Forgemaster") >= 0
	if cannon_kind == "platform":
		# Bulwark — tank-destroyer hull. Cannon is mounted in the center of
		# the chassis (no turret), emerging from a casemate mantlet at the
		# front. Sloped glacis on top, side skirts, and an engine deck on the
		# rear top break up the silhouette into a proper war machine.
		var darker: Color = Color(base_color.r * 0.78, base_color.g * 0.78, base_color.b * 0.82)
		var trim_dark: Color = Color(base_color.r * 0.6, base_color.g * 0.6, base_color.b * 0.65)

		# Sloped glacis (front armor plate) — a wedge-like rotated box.
		var glacis_size := Vector3(torso_size.x * 0.95, torso_size.y * 0.55, torso_size.z * 0.45)
		var glacis := MeshInstance3D.new()
		var glacis_box := BoxMesh.new()
		glacis_box.size = glacis_size
		glacis.mesh = glacis_box
		glacis.rotation.x = -0.45
		glacis.position = Vector3(0, torso_size.y * 0.85, -torso_size.z * 0.32)
		var glacis_mat := _make_metal_mat(Color(base_color.r * 0.95, base_color.g * 0.95, base_color.b * 0.95))
		glacis.set_surface_override_material(0, glacis_mat)
		torso_pivot.add_child(glacis)
		mats.append(glacis_mat)

		# Engine deck on the rear top — a low raised box with grille slats.
		var deck_size := Vector3(torso_size.x * 0.7, torso_size.y * 0.25, torso_size.z * 0.55)
		var deck := MeshInstance3D.new()
		var deck_box := BoxMesh.new()
		deck_box.size = deck_size
		deck.mesh = deck_box
		deck.position = Vector3(0, torso_size.y + deck_size.y * 0.5, torso_size.z * 0.28)
		var deck_mat := _make_metal_mat(darker)
		deck.set_surface_override_material(0, deck_mat)
		torso_pivot.add_child(deck)
		mats.append(deck_mat)

		# Three thin grille slats on the engine deck — purely decorative detail.
		for slat_i: int in 3:
			var slat := MeshInstance3D.new()
			var slat_box := BoxMesh.new()
			slat_box.size = Vector3(deck_size.x * 0.85, 0.04, 0.06)
			slat.mesh = slat_box
			var sz: float = torso_size.z * 0.28 + (float(slat_i) - 1.0) * 0.18
			slat.position = Vector3(0, torso_size.y + deck_size.y + 0.025, sz)
			var slat_mat := _make_metal_mat(Color(0.1, 0.1, 0.1))
			slat.set_surface_override_material(0, slat_mat)
			torso_pivot.add_child(slat)
			mats.append(slat_mat)

		# Side skirts — armor panels along each side, hide the leg-hip area.
		for side: int in 2:
			var sx: float = -torso_size.x * 0.5 - 0.02 if side == 0 else torso_size.x * 0.5 + 0.02
			var skirt := MeshInstance3D.new()
			var skirt_box := BoxMesh.new()
			skirt_box.size = Vector3(0.06, torso_size.y * 0.85, torso_size.z * 0.85)
			skirt.mesh = skirt_box
			skirt.position = Vector3(sx, torso_size.y * 0.4, 0)
			var skirt_mat := _make_metal_mat(trim_dark)
			skirt.set_surface_override_material(0, skirt_mat)
			torso_pivot.add_child(skirt)
			mats.append(skirt_mat)

		# Cupola / commander's hatch — small box on top, slightly behind the gun.
		var cupola := MeshInstance3D.new()
		var cup_box := BoxMesh.new()
		cup_box.size = Vector3(0.3, 0.18, 0.32)
		cupola.mesh = cup_box
		cupola.position = Vector3(torso_size.x * 0.18, torso_size.y + 0.09, torso_size.z * 0.12)
		var cup_mat := _make_metal_mat(darker)
		cupola.set_surface_override_material(0, cup_mat)
		torso_pivot.add_child(cupola)
		mats.append(cup_mat)

		# Tiny visor slit on the cupola.
		var cup_slit := MeshInstance3D.new()
		var cup_slit_box := BoxMesh.new()
		cup_slit_box.size = Vector3(0.22, 0.04, 0.02)
		cup_slit.mesh = cup_slit_box
		cup_slit.position = Vector3(torso_size.x * 0.18, torso_size.y + 0.13, torso_size.z * 0.12 - 0.16)
		var cup_slit_mat := StandardMaterial3D.new()
		cup_slit_mat.albedo_color = Color(0.05, 0.6, 0.9)
		cup_slit_mat.emission_enabled = true
		cup_slit_mat.emission = Color(0.2, 0.8, 1.0)
		cup_slit_mat.emission_energy_multiplier = 1.3
		cup_slit.set_surface_override_material(0, cup_slit_mat)
		torso_pivot.add_child(cup_slit)
		mats.append(cup_slit_mat)

		# --- Casemate gun mounted center-front ---
		var gun_y: float = torso_size.y * 0.55
		var front_z: float = -torso_size.z * 0.5

		# Forgemaster intercept — uses the heavy chassis silhouette
		# but its weapon is a small Riveter Autocannon, not the
		# big Bulwark / Harbinger main gun. Build a compact mount
		# (small mantlet + slim twin barrels) sized for the unit's
		# actual damage role and bail out before the giant-cannon
		# build runs.
		if is_forgemaster:
			var fm_mantlet_radius: float = cannon_size.x * 1.2
			var fm_mantlet := MeshInstance3D.new()
			var fm_mant_box := BoxMesh.new()
			fm_mant_box.size = Vector3(fm_mantlet_radius * 1.6, fm_mantlet_radius * 1.4, fm_mantlet_radius * 1.0)
			fm_mantlet.mesh = fm_mant_box
			fm_mantlet.position = Vector3(0, gun_y, front_z + 0.05)
			var fm_mant_mat := _make_metal_mat(base_color)
			fm_mantlet.set_surface_override_material(0, fm_mant_mat)
			torso_pivot.add_child(fm_mantlet)
			mats.append(fm_mant_mat)
			# Cannon pivot for recoil + muzzle lookup.
			var fm_cannon_pivot := Node3D.new()
			fm_cannon_pivot.name = "CannonPivot_top"
			fm_cannon_pivot.position = Vector3(0, gun_y, front_z - 0.10)
			torso_pivot.add_child(fm_cannon_pivot)
			# Twin slim Riveter barrels — short cylinders side-by-
			# side, scaled down well below the Bulwark's barrel.
			var fm_barrel_len: float = cannon_size.z * 0.45
			for fm_side: int in 2:
				var fm_sx: float = -0.10 if fm_side == 0 else 0.10
				var fm_barrel := MeshInstance3D.new()
				var fm_barrel_cyl := CylinderMesh.new()
				fm_barrel_cyl.top_radius = cannon_size.x * 0.35
				fm_barrel_cyl.bottom_radius = cannon_size.x * 0.40
				fm_barrel_cyl.height = fm_barrel_len
				fm_barrel_cyl.radial_segments = 16
				fm_barrel.mesh = fm_barrel_cyl
				fm_barrel.rotate_object_local(Vector3.RIGHT, -PI / 2)
				fm_barrel.position = Vector3(fm_sx, 0.0, -fm_barrel_len * 0.5)
				var fm_barrel_mat := _make_metal_mat(trim_dark)
				fm_barrel.set_surface_override_material(0, fm_barrel_mat)
				fm_cannon_pivot.add_child(fm_barrel)
				mats.append(fm_barrel_mat)
			shoulders.append(fm_mantlet)
			cannons.append(fm_cannon_pivot)
			cannon_rest_z.append(fm_cannon_pivot.position.z)
			cannon_muzzle_z.append(fm_barrel_len + 0.05)
			# Don't drop into the giant-cannon build below — the
			# rest of the platform branch (mantlet sphere, big
			# barrel, sleeve, muzzle brake) all assume Bulwark or
			# Harbinger geometry. Skip past it via the
			# is_forgemaster guard wrapping the giant-gun block.
			pass

		# Giant-cannon build (Bulwark / Harbinger). Wrapped in a
		# not-is_forgemaster guard so Forgemaster keeps just its
		# compact twin-Riveter mount above and doesn't get a
		# duplicate full-size cannon stacked on top.
		if not is_forgemaster:
			# Faction-driven cross-section. Anvil's Bulwark uses round
			# barrels + a domed mantlet (period-correct industrial
			# cannon). Sable's Harbinger takes the same chassis but
			# with a square (4-sided) barrel and a chamfered tapered
			# mantlet — sharp, edged, faceted geometry so the gun
			# reads as a Sable precision weapon rather than just a
			# recolour of the Anvil cannon.
			var is_sable_heavy: bool = _faction_id() == 1

			# Mantlet — armored housing where barrel meets the chassis front.
			var mantlet_radius: float = cannon_size.x * 2.4
			var mantlet := MeshInstance3D.new()
			if is_sable_heavy:
				# Tapered square block — narrower at the muzzle end, wider
				# at the chassis end. 4 radial segments → a wedge-prism
				# silhouette with crisp corners. The 45° spin needs to
				# rotate around the cylinder's OWN length axis after the
				# forward tilt, otherwise (with rotation.z and Godot's
				# YXZ Euler order) the prism ends up tilted in world space
				# and the barrel attaches at an odd angle. Use
				# rotate_object_local so each rotation is applied in the
				# node's local frame, in the order written.
				var mant_facet := CylinderMesh.new()
				mant_facet.top_radius = mantlet_radius * 0.7
				mant_facet.bottom_radius = mantlet_radius * 1.15
				mant_facet.height = mantlet_radius * 1.7
				mant_facet.radial_segments = 4
				mantlet.mesh = mant_facet
				mantlet.rotate_object_local(Vector3.RIGHT, -PI / 2)
				mantlet.rotate_object_local(Vector3.UP, deg_to_rad(45.0))
			else:
				var mantlet_mesh := SphereMesh.new()
				mantlet_mesh.radius = mantlet_radius
				mantlet_mesh.height = mantlet_radius * 1.9
				mantlet.mesh = mantlet_mesh
			mantlet.position = Vector3(0, gun_y, front_z + 0.05)
			var mantlet_mat := _make_metal_mat(base_color)
			mantlet.set_surface_override_material(0, mantlet_mat)
			torso_pivot.add_child(mantlet)
			mats.append(mantlet_mat)
	
			# Cannon pivot — recoil animates this back along +Z.
			var cannon_pivot := Node3D.new()
			cannon_pivot.name = "CannonPivot_top"
			cannon_pivot.position = Vector3(0, gun_y, front_z - 0.05)
			torso_pivot.add_child(cannon_pivot)
	
			var barrel_len: float = cannon_size.z
			if is_sable_heavy:
				# Sable Harbinger fires a Spinal Railgun + drone-bay
				# releases — neither reads as a kinetic cannon. Replace
				# the barrel + sleeve + muzzle with a missile-launcher
				# block: an angled rectangular housing with four
				# vertically-stacked tubes facing forward, missile noses
				# protruding from the openings, and a chamfered top
				# breech. cannon_pivot still receives the launcher so
				# recoil + muzzle-position lookups continue to work.
				var housing_len: float = barrel_len * 0.75
				var housing_w: float = cannon_size.x * 3.6
				var housing_h: float = cannon_size.x * 4.2
				var housing := MeshInstance3D.new()
				var housing_box := BoxMesh.new()
				housing_box.size = Vector3(housing_w, housing_h, housing_len)
				housing.mesh = housing_box
				# Tip the launcher up slightly so the tubes read as
				# pointed forward-and-up, not straight ahead.
				housing.rotate_object_local(Vector3.RIGHT, deg_to_rad(-12.0))
				housing.position.z = -housing_len * 0.5
				housing.position.y = housing_h * 0.05
				var housing_mat := _make_metal_mat(darker)
				housing.set_surface_override_material(0, housing_mat)
				cannon_pivot.add_child(housing)
				mats.append(housing_mat)
	
				# Top breech cap — slimmer angled plate covering the rear
				# upper edge of the housing. Reads as the launcher's
				# closed-bolt mechanism.
				var cap := MeshInstance3D.new()
				var cap_box := BoxMesh.new()
				cap_box.size = Vector3(housing_w * 0.95, housing_h * 0.18, housing_len * 0.45)
				cap.mesh = cap_box
				cap.rotate_object_local(Vector3.RIGHT, deg_to_rad(-12.0))
				cap.position.z = housing.position.z + housing_len * 0.35
				cap.position.y = housing.position.y + housing_h * 0.55
				var cap_mat := _make_metal_mat(Color(0.10, 0.10, 0.14))
				cap.set_surface_override_material(0, cap_mat)
				cannon_pivot.add_child(cap)
				mats.append(cap_mat)
	
				# Four launch tubes — 2x2 grid on the front face. Each
				# tube is a short cylinder protruding forward, with a
				# small cone-tip missile poking out of the mouth.
				var tube_radius: float = cannon_size.x * 0.55
				var tube_len: float = housing_len * 0.30
				var tube_x_off: float = housing_w * 0.22
				var tube_y_off: float = housing_h * 0.20
				for tx_i: int in 2:
					for ty_i: int in 2:
						var tx: float = (-tube_x_off) if tx_i == 0 else tube_x_off
						var ty: float = (-tube_y_off) if ty_i == 0 else tube_y_off
						var tube := MeshInstance3D.new()
						var tube_cyl := CylinderMesh.new()
						tube_cyl.top_radius = tube_radius
						tube_cyl.bottom_radius = tube_radius
						tube_cyl.height = tube_len
						tube_cyl.radial_segments = 8
						tube.mesh = tube_cyl
						tube.rotate_object_local(Vector3.RIGHT, deg_to_rad(-12.0) - PI / 2)
						tube.position = Vector3(
							tx,
							housing.position.y + ty,
							housing.position.z - housing_len * 0.45,
						)
						var tube_mat := _make_metal_mat(Color(0.06, 0.06, 0.08))
						tube.set_surface_override_material(0, tube_mat)
						cannon_pivot.add_child(tube)
						mats.append(tube_mat)
	
						# Missile tip — small cone poking out of the
						# tube. Tinted Sable violet emissive so the
						# loaded-and-armed read carries at any zoom.
						var tip := MeshInstance3D.new()
						var tip_cyl := CylinderMesh.new()
						tip_cyl.top_radius = 0.0
						tip_cyl.bottom_radius = tube_radius * 0.75
						tip_cyl.height = tube_len * 0.55
						tip_cyl.radial_segments = 8
						tip.mesh = tip_cyl
						tip.rotate_object_local(Vector3.RIGHT, deg_to_rad(-12.0) - PI / 2)
						tip.position = Vector3(
							tx,
							housing.position.y + ty + 0.02,
							housing.position.z - housing_len * 0.62,
						)
						var tip_mat := StandardMaterial3D.new()
						tip_mat.albedo_color = Color(0.78, 0.42, 1.0, 1.0)
						tip_mat.emission_enabled = true
						tip_mat.emission = Color(0.78, 0.42, 1.0, 1.0)
						tip_mat.emission_energy_multiplier = 1.6
						tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
						tip.set_surface_override_material(0, tip_mat)
						cannon_pivot.add_child(tip)
						mats.append(tip_mat)
	
				shoulders.append(mantlet)
				cannons.append(cannon_pivot)
				cannon_rest_z.append(cannon_pivot.position.z)
				# Muzzle position = front face of the housing where the
				# missile tubes are. Used by combat code for projectile
				# spawn.
				cannon_muzzle_z.append(housing_len + 0.18)
			else:
				# Anvil Bulwark — keep the original round-barrel cannon
				# (period industrial AP gun). Round barrel, recoil sleeve,
				# muzzle brake.
				var barrel := MeshInstance3D.new()
				var barrel_cyl := CylinderMesh.new()
				barrel_cyl.top_radius = cannon_size.x
				barrel_cyl.bottom_radius = cannon_size.x * 1.05
				barrel_cyl.height = barrel_len
				barrel_cyl.radial_segments = 64
				barrel.mesh = barrel_cyl
				barrel.rotate_object_local(Vector3.RIGHT, -PI / 2)
				barrel.position.z = -barrel_len * 0.5
				var barrel_mat := _make_metal_mat(trim_dark)
				barrel.set_surface_override_material(0, barrel_mat)
				cannon_pivot.add_child(barrel)
				mats.append(barrel_mat)
	
				# Recoil sleeve — wider section near the breech.
				var sleeve_len: float = barrel_len * 0.22
				var sleeve := MeshInstance3D.new()
				var sleeve_cyl := CylinderMesh.new()
				sleeve_cyl.top_radius = cannon_size.x * 1.3
				sleeve_cyl.bottom_radius = cannon_size.x * 1.3
				sleeve_cyl.height = sleeve_len
				sleeve_cyl.radial_segments = 64
				sleeve.mesh = sleeve_cyl
				sleeve.rotate_object_local(Vector3.RIGHT, -PI / 2)
				sleeve.position.z = -barrel_len * 0.55
				var sleeve_mat := _make_metal_mat(darker)
				sleeve.set_surface_override_material(0, sleeve_mat)
				cannon_pivot.add_child(sleeve)
				mats.append(sleeve_mat)
	
				# Muzzle brake — wider cap at the tip.
				var muzzle := MeshInstance3D.new()
				var muzzle_cyl := CylinderMesh.new()
				muzzle_cyl.top_radius = cannon_size.x * 1.4
				muzzle_cyl.bottom_radius = cannon_size.x * 1.2
				muzzle_cyl.height = 0.15
				muzzle_cyl.radial_segments = 64
				muzzle.mesh = muzzle_cyl
				muzzle.rotate_object_local(Vector3.RIGHT, -PI / 2)
				muzzle.position.z = -barrel_len - 0.07
				var muzzle_mat := _make_metal_mat(Color(0.1, 0.1, 0.1))
				muzzle.set_surface_override_material(0, muzzle_mat)
				cannon_pivot.add_child(muzzle)
				mats.append(muzzle_mat)

				# Bore -- an unshaded near-black cylinder protruding from
				# the brake centre. The dark face occupies the inside
				# diameter of the brake so the player reads the cannon
				# as a real hollow tube instead of a capped log. We
				# extend slightly past the brake's front face so the
				# silhouette wins over the brake's metal at any camera
				# angle the top-down RTS allows.
				var bore := MeshInstance3D.new()
				var bore_cyl := CylinderMesh.new()
				bore_cyl.top_radius = cannon_size.x * 0.62
				bore_cyl.bottom_radius = cannon_size.x * 0.62
				bore_cyl.height = 0.22
				bore_cyl.radial_segments = 32
				bore.mesh = bore_cyl
				bore.rotate_object_local(Vector3.RIGHT, -PI / 2)
				# Place the cylinder so its rear sits well inside the
				# brake and its front pokes ~0.04u past the brake face.
				bore.position.z = -barrel_len - 0.18
				var bore_mat := StandardMaterial3D.new()
				bore_mat.albedo_color = Color(0.03, 0.03, 0.04, 1.0)
				bore_mat.metallic = 0.0
				bore_mat.roughness = 1.0
				bore_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				bore.set_surface_override_material(0, bore_mat)
				cannon_pivot.add_child(bore)
				mats.append(bore_mat)
	
			shoulders.append(mantlet)
			cannons.append(cannon_pivot)
			cannon_rest_z.append(cannon_pivot.position.z)
			cannon_muzzle_z.append(barrel_len + 0.07)
			# Anvil Bulwark TRIPLE-cannon expansion. The if/else
			# above already built the centre barrel on
			# `cannon_pivot`; here we add two flanking barrels at
			# +/- BULWARK_FLANK_X. Each gets its own pivot so
			# combat's salvo_stagger code recoils them independently
			# and fires them in quick succession. Skipped for Sable
			# (which uses the missile-launcher housing instead) and
			# for the Bulwark Siegebreaker overlay (which keeps the
			# single Siege Mortar barrel; the overlay layer hides
			# the centre cannon and replaces it).
			if not is_sable_heavy and not (stats and stats.unit_name.findn("Siegebreaker") >= 0):
				const BULWARK_FLANK_X: float = 0.36
				var per_radius: float = cannon_size.x * 0.62
				for s_i: int in 2:
					var sx: float = -BULWARK_FLANK_X if s_i == 0 else BULWARK_FLANK_X
					var side_pivot := Node3D.new()
					side_pivot.name = "CannonPivot_top_%d" % (s_i + 1)
					side_pivot.position = Vector3(sx, gun_y, front_z - 0.05)
					torso_pivot.add_child(side_pivot)
					# Barrel
					var s_barrel := MeshInstance3D.new()
					var s_barrel_cyl := CylinderMesh.new()
					s_barrel_cyl.top_radius = per_radius
					s_barrel_cyl.bottom_radius = per_radius * 1.05
					s_barrel_cyl.height = barrel_len
					s_barrel_cyl.radial_segments = 32
					s_barrel.mesh = s_barrel_cyl
					s_barrel.rotate_object_local(Vector3.RIGHT, -PI / 2)
					s_barrel.position.z = -barrel_len * 0.5
					var s_barrel_mat := _make_metal_mat(trim_dark)
					s_barrel.set_surface_override_material(0, s_barrel_mat)
					side_pivot.add_child(s_barrel)
					mats.append(s_barrel_mat)
					# Sleeve
					var s_sleeve := MeshInstance3D.new()
					var s_sleeve_cyl := CylinderMesh.new()
					s_sleeve_cyl.top_radius = per_radius * 1.30
					s_sleeve_cyl.bottom_radius = per_radius * 1.30
					s_sleeve_cyl.height = barrel_len * 0.22
					s_sleeve_cyl.radial_segments = 32
					s_sleeve.mesh = s_sleeve_cyl
					s_sleeve.rotate_object_local(Vector3.RIGHT, -PI / 2)
					s_sleeve.position.z = -barrel_len * 0.55
					var s_sleeve_mat := _make_metal_mat(darker)
					s_sleeve.set_surface_override_material(0, s_sleeve_mat)
					side_pivot.add_child(s_sleeve)
					mats.append(s_sleeve_mat)
					# Muzzle brake
					var s_muzzle := MeshInstance3D.new()
					var s_muzzle_cyl := CylinderMesh.new()
					s_muzzle_cyl.top_radius = per_radius * 1.40
					s_muzzle_cyl.bottom_radius = per_radius * 1.20
					s_muzzle_cyl.height = 0.13
					s_muzzle_cyl.radial_segments = 32
					s_muzzle.mesh = s_muzzle_cyl
					s_muzzle.rotate_object_local(Vector3.RIGHT, -PI / 2)
					s_muzzle.position.z = -barrel_len - 0.07
					var s_muzzle_mat := _make_metal_mat(Color(0.1, 0.1, 0.1))
					s_muzzle.set_surface_override_material(0, s_muzzle_mat)
					side_pivot.add_child(s_muzzle)
					mats.append(s_muzzle_mat)
					# Bore
					var s_bore := MeshInstance3D.new()
					var s_bore_cyl := CylinderMesh.new()
					s_bore_cyl.top_radius = per_radius * 0.62
					s_bore_cyl.bottom_radius = per_radius * 0.62
					s_bore_cyl.height = 0.22
					s_bore_cyl.radial_segments = 16
					s_bore.mesh = s_bore_cyl
					s_bore.rotate_object_local(Vector3.RIGHT, -PI / 2)
					s_bore.position.z = -barrel_len - 0.18
					var s_bore_mat := StandardMaterial3D.new()
					s_bore_mat.albedo_color = Color(0.03, 0.03, 0.04, 1.0)
					s_bore_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					s_bore.set_surface_override_material(0, s_bore_mat)
					side_pivot.add_child(s_bore)
					mats.append(s_bore_mat)
					# Per-barrel muzzle marker.
					var s_marker := Marker3D.new()
					s_marker.name = "Muzzle"
					s_marker.position = Vector3(0.0, 0.0, -barrel_len - 0.20)
					side_pivot.add_child(s_marker)
					cannons.append(side_pivot)
					cannon_rest_z.append(side_pivot.position.z)
					cannon_muzzle_z.append(barrel_len + 0.07)
	elif cannon_kind != "none":
		# Sentinel-style mounts cannons at the cockpit (top of head); standard
		# bipeds mount them on the torso shoulders.
		var arm_y: float = torso_size.y * 0.7
		if cannon_mount == "head_top":
			arm_y = torso_size.y + head_size.y * 0.5
		var sides: Array[int] = [0, 1]
		if cannon_kind == "single_left" or cannon_kind == "claw":
			sides = [0]
		elif cannon_kind == "single_right":
			sides = [1]
		for side: int in sides:
			var sx: float = -(cannon_x) if side == 0 else cannon_x
			# Shoulder pad
			var shoulder := MeshInstance3D.new()
			var shoulder_box := BoxMesh.new()
			shoulder_box.size = Vector3(torso_size.x * 0.3, torso_size.y * 0.35, torso_size.z * 0.45)
			shoulder.mesh = shoulder_box
			shoulder.position = Vector3(sx, arm_y, 0)
			var shoulder_mat := _make_metal_mat(base_color)
			shoulder.set_surface_override_material(0, shoulder_mat)
			torso_pivot.add_child(shoulder)
			mats.append(shoulder_mat)

			# Cannon pivot animates Z for recoil.
			var cannon_pivot := Node3D.new()
			cannon_pivot.name = "CannonPivot_%d" % side
			cannon_pivot.position = Vector3(sx, arm_y, 0)
			torso_pivot.add_child(cannon_pivot)

			if cannon_kind == "claw":
				# Engineer tool arm: forearm + claw fingers.
				var forearm := MeshInstance3D.new()
				var fb := BoxMesh.new()
				fb.size = Vector3(0.15, 0.15, cannon_size.z)
				forearm.mesh = fb
				forearm.position.z = -cannon_size.z * 0.5
				var forearm_mat := _make_metal_mat(trim_color)
				forearm.set_surface_override_material(0, forearm_mat)
				cannon_pivot.add_child(forearm)
				mats.append(forearm_mat)

				for finger_side: int in 2:
					var fy: float = -0.06 if finger_side == 0 else 0.06
					var finger := MeshInstance3D.new()
					var fingbox := BoxMesh.new()
					fingbox.size = Vector3(0.06, 0.06, 0.18)
					finger.mesh = fingbox
					finger.position = Vector3(0, fy, -cannon_size.z - 0.08)
					var finger_mat := _make_metal_mat(Color(0.7, 0.55, 0.15))
					finger.set_surface_override_material(0, finger_mat)
					cannon_pivot.add_child(finger)
					mats.append(finger_mat)
			else:
				# Cannon barrel — muzzle at -cannon_size.z.
				var barrel := MeshInstance3D.new()
				var bbox := BoxMesh.new()
				bbox.size = cannon_size
				barrel.mesh = bbox
				barrel.position.z = -cannon_size.z * 0.5
				var barrel_mat := _make_metal_mat(Color(base_color.r * 0.6, base_color.g * 0.6, base_color.b * 0.65))
				barrel.set_surface_override_material(0, barrel_mat)
				cannon_pivot.add_child(barrel)
				mats.append(barrel_mat)

				var muzzle := MeshInstance3D.new()
				var mbox := BoxMesh.new()
				mbox.size = Vector3(cannon_size.x * 1.25, cannon_size.y * 1.25, 0.1)
				muzzle.mesh = mbox
				muzzle.position.z = -cannon_size.z - 0.02
				var muzzle_mat := _make_metal_mat(Color(0.15, 0.15, 0.15))
				muzzle.set_surface_override_material(0, muzzle_mat)
				cannon_pivot.add_child(muzzle)
				mats.append(muzzle_mat)

			shoulders.append(shoulder)
			cannons.append(cannon_pivot)
			cannon_rest_z.append(cannon_pivot.position.z)
			# Shoulder cannons: barrel tip + muzzle ring at cannon_size.z + 0.02.
			# Claw arms (engineers) put fingers at -size.z - 0.08, but they
			# don't fire — using the same value is harmless.
			cannon_muzzle_z.append(cannon_size.z + 0.05)

			# Shoulder pauldron cap — small angled plate atop each shoulder.
			var pauldron := MeshInstance3D.new()
			var pauldron_box := BoxMesh.new()
			pauldron_box.size = Vector3(torso_size.x * 0.34, torso_size.y * 0.12, torso_size.z * 0.5)
			pauldron.mesh = pauldron_box
			pauldron.position = Vector3(sx, arm_y + torso_size.y * 0.2, 0)
			pauldron.rotation.z = -0.18 if side == 0 else 0.18
			var pauldron_mat := _make_metal_mat(Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85))
			pauldron.set_surface_override_material(0, pauldron_mat)
			torso_pivot.add_child(pauldron)
			mats.append(pauldron_mat)

	# --- Class-specific extras (back armor, engine mount, etc.) ---
	if stats:
		_add_class_extras(torso_pivot, torso_size, head_size, mats, base_color, stats.unit_class)

	# --- Antenna ---
	if antenna_h > 0.01:
		# Sable mounts the antenna a bit higher and ends it in a violet
		# tip that matches the rest of the faction's emissive accent.
		# Anvil/Combine gets a fully redesigned industrial whip antenna
		# (cross-bar element + brass insulator + tiny warm-amber LED)
		# instead of the prior bright-red sphere — that "toy-soldier
		# flag" read was called out in playtest 2026-05-15.
		var is_sable: bool = _faction_id() == 1
		var sable_lift: float = 0.20 if is_sable else 0.0
		var ant_h_actual: float = antenna_h + sable_lift
		var ant_x: float = head_size.x * 0.3
		var ant_top_y: float = torso_size.y + head_size.y + ant_h_actual
		var antenna := MeshInstance3D.new()
		var ant_box := BoxMesh.new()
		ant_box.size = Vector3(0.04, ant_h_actual, 0.04)
		antenna.mesh = ant_box
		antenna.position = Vector3(ant_x, torso_size.y + head_size.y + ant_h_actual / 2.0, head_fwd_offset)
		var ant_mat := _make_metal_mat(Color(0.15, 0.15, 0.18))
		antenna.set_surface_override_material(0, ant_mat)
		torso_pivot.add_child(antenna)
		mats.append(ant_mat)

		var tip_faction: int = _faction_id()
		if tip_faction == 0:
			# Anvil/Combine: industrial whip — yagi cross-element
			# midway up, brass insulator near the top, and a small
			# dim amber LED that reads as a navigation/status lamp
			# rather than a flag.
			const ANVIL_BRASS: Color = Color(0.78, 0.62, 0.18, 1.0)
			# Cross-bar element near the upper third — small horizontal
			# bar suggesting a directional radio element.
			var crossbar := MeshInstance3D.new()
			var cb_box := BoxMesh.new()
			cb_box.size = Vector3(0.18, 0.018, 0.018)
			crossbar.mesh = cb_box
			crossbar.position = Vector3(ant_x, torso_size.y + head_size.y + ant_h_actual * 0.72, head_fwd_offset)
			crossbar.set_surface_override_material(0, ant_mat)
			torso_pivot.add_child(crossbar)
			# Brass insulator — short cylinder ringing the post just
			# below the tip. Industrial detail, faction colour cue.
			var insulator := MeshInstance3D.new()
			var ins_cyl := CylinderMesh.new()
			ins_cyl.top_radius = 0.035
			ins_cyl.bottom_radius = 0.045
			ins_cyl.height = 0.05
			ins_cyl.radial_segments = 8
			insulator.mesh = ins_cyl
			insulator.position = Vector3(ant_x, ant_top_y - 0.04, head_fwd_offset)
			var ins_mat: StandardMaterial3D = _make_metal_mat(ANVIL_BRASS)
			insulator.set_surface_override_material(0, ins_mat)
			torso_pivot.add_child(insulator)
			mats.append(ins_mat)
			# Tiny status LED at the very top — small dim amber so it
			# reads as a navigation light, not a team flag.
			var led := MeshInstance3D.new()
			var led_sph := SphereMesh.new()
			led_sph.radius = 0.025
			led_sph.height = 0.05
			led.mesh = led_sph
			led.position = Vector3(ant_x, ant_top_y + 0.015, head_fwd_offset)
			var led_mat := StandardMaterial3D.new()
			led_mat.albedo_color = Color(1.0, 0.65, 0.20)
			led_mat.emission_enabled = true
			led_mat.emission = Color(1.0, 0.65, 0.20)
			led_mat.emission_energy_multiplier = 1.4
			led_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			led.set_surface_override_material(0, led_mat)
			torso_pivot.add_child(led)
			mats.append(led_mat)
		else:
			# Sable / Inheritor / Heliarch: keep the spherical signal-
			# light tip with their faction-tinted emissive — those reads
			# already as a glowing antenna node, not a flag.
			var tip := MeshInstance3D.new()
			var tip_sph := SphereMesh.new()
			tip_sph.radius = 0.05
			tip_sph.height = 0.1
			tip.mesh = tip_sph
			tip.position = Vector3(ant_x, ant_top_y, head_fwd_offset)
			var tip_color: Color
			if is_sable:
				tip_color = SABLE_NEON
			elif tip_faction == 3:
				tip_color = Color(1.0, 0.55, 0.20)
			elif tip_faction == 2:
				tip_color = Color(0.70, 0.55, 1.0)
			else:
				tip_color = Color(1.0, 0.3, 0.2)
			var tip_mat := StandardMaterial3D.new()
			tip_mat.albedo_color = tip_color
			tip_mat.emission_enabled = true
			tip_mat.emission = tip_color
			tip_mat.emission_energy_multiplier = 2.0
			tip.set_surface_override_material(0, tip_mat)
			torso_pivot.add_child(tip)
			mats.append(tip_mat)

	# Sable silhouette pass — replaces the boxy torso + head with a
	# faceted angular hull and adds back-spire antennas so a Sable
	# squad is recognisable purely from outline at full zoom. Anvil
	# units skip this and keep the v1 industrial silhouette.
	if _faction_id() == 1:
		_apply_sable_silhouette(torso_pivot, torso, head, torso_size, head_size, base_color, mats)

	# Pulsefont caster overlay — a unique silhouette so the unit
	# reads as a support / Mesh-aura caster rather than another
	# Hound chassis. Keeps the underlying medium chassis (cannons,
	# legs, torso) intact so combat code still works, but stacks
	# faction-distinct emitter geometry on top. Sized up 1.18x
	# below so it visibly reads as a special-class unit.
	if stats and stats.unit_name == "Pulsefont":
		_apply_pulsefont_overlay(torso_pivot, torso_size, head_size, mats)
		_apply_special_chassis_scale(member, 1.18)

	# Anvil Forgemaster overlay — unique support-mech read so it
	# doesn't read as a recoloured Bulwark. Adds a tall furnace
	# stack on the back (visible orange glow), a roof-mounted AA
	# launcher rack (the Skyspike battery), and a chest-front
	# repair-coil ring tinted Anvil amber.
	if stats and stats.unit_name.findn("Forgemaster") >= 0:
		_apply_forgemaster_overlay(torso_pivot, torso_size, head_size, mats)
		_apply_special_chassis_scale(member, 1.18)

	# Branch-variant overlays. Each branch gets a distinct
	# silhouette element so the player can read 'this is a Sapper /
	# Spotter / Ironwall / etc.' without selecting the unit. Visuals
	# stack on top of the base chassis -- combat geometry stays put.
	if stats:
		match stats.unit_name:
			"Rook (Spotter)":
				_apply_rook_spotter_overlay(torso_pivot, torso_size, head_size)
			"Rook (Sapper)":
				_apply_rook_sapper_overlay(torso_pivot, torso_size)
			"Hound — Tracker":
				_apply_hound_tracker_overlay(torso_pivot, torso_size)
			"Hound — Ripper":
				_apply_hound_ripper_overlay(torso_pivot, torso_size)
			"Bulwark":
				_apply_bulwark_imposing_stance(member)
			"Bulwark (Ironwall)":
				_apply_bulwark_ironwall_overlay(torso_pivot, torso_size)
				_apply_bulwark_imposing_stance(member)
			"Bulwark (Siegebreaker)":
				_apply_bulwark_siegebreaker_overlay(torso_pivot, torso_size)
				_apply_bulwark_imposing_stance(member)
			"Restorer", "Restorator":
				_apply_restorer_base_overlay(torso_pivot, torso_size, head_size, base_color, mats)
			"Ashigaru":
				_apply_ashigaru_base_overlay(torso_pivot, torso_size, base_color, mats)
			"Rook":
				_apply_rook_base_overlay(member, torso_pivot, torso_size, head_size, mats)
			"Hound":
				_apply_hound_base_overlay(member, torso_pivot, torso_size, head_size, base_color, mats)
			"Stoker":
				_apply_stoker_base_overlay(torso_pivot, torso_size, head_size, base_color, mats)
			"Matador":
				_apply_matador_base_overlay(torso_pivot, torso_size, base_color, mats)
			"Cremator":
				_apply_cremator_base_overlay(torso_pivot, torso_size, base_color, mats)
			"Inquisitor Tank":
				_apply_inquisitor_tank_base_overlay(torso_pivot, torso_size, base_color, mats)
			"Conquistador":
				_apply_conquistador_base_overlay(torso_pivot, torso_size, base_color, mats)
			"Specter":
				_apply_specter_base_overlay(torso_pivot, torso_size, head_size, base_color, mats)
			"Specter (Ghost)":
				_apply_specter_base_overlay(torso_pivot, torso_size, head_size, base_color, mats)
				_apply_specter_ghost_overlay(torso_pivot, torso_size, mats)
			"Specter (Glitch)":
				_apply_specter_base_overlay(torso_pivot, torso_size, head_size, base_color, mats)
				_apply_specter_glitch_overlay(torso_pivot, torso_size, mats)
			"Jackal":
				_apply_jackal_base_overlay(torso_pivot, torso_size, base_color, mats)
			"Jackal (Striker)":
				_apply_jackal_base_overlay(torso_pivot, torso_size, base_color, mats)
				_apply_jackal_striker_overlay(torso_pivot, torso_size, mats)
			"Jackal (Widow)":
				_apply_jackal_base_overlay(torso_pivot, torso_size, base_color, mats)
				_apply_jackal_widow_overlay(torso_pivot, torso_size, mats)
			"Forgemaster (Foreman)":
				_apply_forgemaster_foreman_extras(torso_pivot, torso_size, mats)
			"Forgemaster (Reactor)":
				_apply_forgemaster_reactor_extras(torso_pivot, torso_size, mats)
			"Harbinger":
				_apply_harbinger_base_overlay(torso_pivot, torso_size, base_color, mats)
			"Harbinger (Overseer)":
				_apply_harbinger_base_overlay(torso_pivot, torso_size, base_color, mats)
				_apply_harbinger_overseer_overlay(torso_pivot, torso_size, mats)
			"Harbinger (Swarm Marshal)":
				_apply_harbinger_base_overlay(torso_pivot, torso_size, base_color, mats)
				_apply_harbinger_swarm_marshal_overlay(torso_pivot, torso_size, mats)

	# Per-member gait variation so a squad doesn't goose-step in lockstep.
	# Each mech has its own phase, slightly different stride speed, swing
	# amplitude, and torso bob amount — same skeleton, individual feel.
	# Recoil array sized to the actual cannon count -- Bulwark's
	# triple-cannon expansion adds extra entries to the cannons
	# array AFTER the initial build, so a fixed-size [0.0, 0.0]
	# would underflow when _tick_recoil iterates cannons.size().
	var recoil_array: Array = []
	for _rc: int in cannons.size():
		recoil_array.append(0.0)
	# Fall back to the legacy 2-entry default for units that have
	# zero cannons (tank-builder paths return their own dict).
	if recoil_array.is_empty():
		recoil_array = [0.0, 0.0]
	return {
		"root": member,
		"legs": legs,
		"leg_phases": leg_phases,
		"shoulders": shoulders,
		"cannons": cannons,
		"cannon_rest_z": cannon_rest_z,
		"cannon_muzzle_z": cannon_muzzle_z,
		"torso": torso,
		"head": head,
		"mats": mats,
		"recoil": recoil_array,
		"stride_phase": randf_range(0.0, TAU),
		"stride_speed": randf_range(0.85, 1.18),
		"stride_swing": randf_range(0.36, 0.55),
		"bob_amount": randf_range(0.05, 0.09),
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": randf_range(0.6, 1.0),
	}


func _apply_sable_silhouette(
	torso_pivot: Node3D,
	torso: MeshInstance3D,
	head: MeshInstance3D,
	torso_size: Vector3,
	head_size: Vector3,
	base_color: Color,
	mats: Array[StandardMaterial3D],
) -> void:
	## Replaces the standard boxy torso and head with Sable's angular,
	## chevron-fronted silhouette. Anvil reads as "industrial heavy
	## machine"; Sable should read as "low-slung stealth chassis with
	## sensor spires" — same scale + collision footprint, different
	## profile.
	# Hide the standard boxy meshes — keep them in-tree so animation /
	# damage / wreck code that holds a reference still works, but make
	# them invisible so only the Sable replacement reads.
	if torso:
		torso.visible = false
	if head:
		head.visible = false

	# Faceted hull: a forward chevron wedge + a rear shoulder block,
	# slightly slanted top and bottom. Built as small box meshes
	# rotated around Y/Z so the silhouette has chamfered corners and
	# a clear leading edge instead of a brick face.
	var dark_mat := _make_metal_mat(base_color)
	mats.append(dark_mat)
	var accent_mat := StandardMaterial3D.new()
	accent_mat.albedo_color = SABLE_NEON
	accent_mat.emission_enabled = true
	accent_mat.emission = SABLE_NEON
	accent_mat.emission_energy_multiplier = 2.0
	accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mats.append(accent_mat)

	# Front chevron — two long thin slabs meeting at the centerline,
	# pointing -Z (forward). Reads as a cutwater / prow.
	var prow_mat := _make_metal_mat(base_color.darkened(0.15))
	mats.append(prow_mat)
	var prow_left := MeshInstance3D.new()
	var prow_box := BoxMesh.new()
	prow_box.size = Vector3(torso_size.x * 0.46, torso_size.y * 0.55, torso_size.z * 0.85)
	prow_left.mesh = prow_box
	prow_left.position = Vector3(-torso_size.x * 0.18, torso_size.y * 0.55, -torso_size.z * 0.06)
	prow_left.rotation.y = deg_to_rad(18.0)
	prow_left.set_surface_override_material(0, prow_mat)
	torso_pivot.add_child(prow_left)
	var prow_right := MeshInstance3D.new()
	prow_right.mesh = prow_box
	prow_right.position = Vector3(torso_size.x * 0.18, torso_size.y * 0.55, -torso_size.z * 0.06)
	prow_right.rotation.y = deg_to_rad(-18.0)
	prow_right.set_surface_override_material(0, prow_mat)
	torso_pivot.add_child(prow_right)

	# Rear shoulder block — a low wide platform behind the prow,
	# slightly canted so the back reads as armored cargo, not a
	# featureless cube. Engineer for shoulder mounts to ride on.
	var shoulder_block := MeshInstance3D.new()
	var shoulder_box := BoxMesh.new()
	shoulder_box.size = Vector3(torso_size.x * 1.05, torso_size.y * 0.45, torso_size.z * 0.55)
	shoulder_block.mesh = shoulder_box
	shoulder_block.position = Vector3(0.0, torso_size.y * 0.30, torso_size.z * 0.20)
	shoulder_block.rotation.x = deg_to_rad(-6.0)
	shoulder_block.set_surface_override_material(0, dark_mat)
	torso_pivot.add_child(shoulder_block)

	# Cyan seam down the centre of the chevron — emissive line
	# tracing the prow ridge. Visible at distance.
	var seam := MeshInstance3D.new()
	var seam_box := BoxMesh.new()
	seam_box.size = Vector3(0.05, torso_size.y * 0.50, torso_size.z * 0.95)
	seam.mesh = seam_box
	seam.position = Vector3(0.0, torso_size.y * 0.55, -torso_size.z * 0.05)
	seam.set_surface_override_material(0, accent_mat)
	torso_pivot.add_child(seam)

	# Wedge head — sharply forward-pointing pyramid replacing the
	# boxy/spherical Anvil cockpit. Two slim slabs meeting at a
	# centerline so the head silhouette reads as a "blade" pointing
	# at the enemy.
	var head_y: float = torso_size.y + head_size.y * 0.5
	var wedge_mat := _make_metal_mat(base_color.darkened(0.10))
	mats.append(wedge_mat)
	var wedge_l := MeshInstance3D.new()
	var wedge_box := BoxMesh.new()
	wedge_box.size = Vector3(head_size.x * 0.55, head_size.y * 0.85, head_size.z * 1.1)
	wedge_l.mesh = wedge_box
	wedge_l.position = Vector3(-head_size.x * 0.18, head_y, -head_size.z * 0.10)
	wedge_l.rotation.y = deg_to_rad(22.0)
	wedge_l.set_surface_override_material(0, wedge_mat)
	torso_pivot.add_child(wedge_l)
	var wedge_r := MeshInstance3D.new()
	wedge_r.mesh = wedge_box
	wedge_r.position = Vector3(head_size.x * 0.18, head_y, -head_size.z * 0.10)
	wedge_r.rotation.y = deg_to_rad(-22.0)
	wedge_r.set_surface_override_material(0, wedge_mat)
	torso_pivot.add_child(wedge_r)

	# Cyan visor strip running across the wedge prow — narrow horizontal
	# slit, the only "eye" the chassis has.
	var visor := MeshInstance3D.new()
	var visor_box := BoxMesh.new()
	visor_box.size = Vector3(head_size.x * 0.65, head_size.y * 0.13, 0.04)
	visor.mesh = visor_box
	visor.position = Vector3(0.0, head_y + head_size.y * 0.05, -head_size.z * 0.55)
	visor.set_surface_override_material(0, accent_mat)
	torso_pivot.add_child(visor)

	# Sensor spire — short rear antenna rising off the shoulder
	# block. Smaller than the early version so it doesn't tower over
	# light mechs; reads as "comm whip", not "flagpole".
	var spire := MeshInstance3D.new()
	var spire_box := BoxMesh.new()
	var spire_h: float = (torso_size.y + head_size.y) * 0.55
	spire_box.size = Vector3(0.06, spire_h, 0.06)
	spire.mesh = spire_box
	spire.position = Vector3(
		torso_size.x * 0.32,
		torso_size.y * 0.55 + spire_h * 0.5,
		torso_size.z * 0.30,
	)
	spire.rotation.z = deg_to_rad(-4.0)
	spire.set_surface_override_material(0, _make_metal_mat(base_color.darkened(0.25)))
	torso_pivot.add_child(spire)

	# Tip cap — small dot, not a baseball.
	var tip := MeshInstance3D.new()
	var tip_box := BoxMesh.new()
	tip_box.size = Vector3(0.10, 0.06, 0.10)
	tip.mesh = tip_box
	tip.position = Vector3(0.0, spire_h * 0.5 + 0.04, 0.0)
	tip.set_surface_override_material(0, accent_mat)
	spire.add_child(tip)


func _apply_bulwark_imposing_stance(member: Node3D) -> void:
	## Makes the Bulwark read as 'engine of destruction' instead
	## of 'standard heavy mech'. Four changes layer:
	##   - +10% chassis scale so the silhouette towers over Hounds.
	##   - Slight forward lean (~4deg pitch) so the chassis reads
	##     as advancing under its own weight.
	##   - Per-member walk-feel override: slower stride, deeper
	##     bob, narrower swing arc -- the parade gait gets replaced
	##     with a heavy stomp. Idle weight-shift slows too.
	##   - Hammer-and-anvil sigil on the chest (the Combine doctrine
	##     icon per 03_factions §2). Brass embossed plate on a dark
	##     backing so the iconography reads at any zoom level.
	_apply_special_chassis_scale(member, 1.10)
	_apply_combine_hammer_anvil_sigil(member)
	# Forward lean is applied to the chassis root so legs + torso
	# tilt as one unit. Small enough to read as posture, not
	# falling.
	member.rotation.x = deg_to_rad(-4.0)
	# Walk + idle parameter override. Previous override pinched
	# stride_swing down to 0.22-0.32 and pumped bob_amount up to
	# 0.13-0.18, which read as 'waddle': torso heaving up and
	# down while legs barely moved. The Bulwark IS slow but it
	# should still actually USE its legs; player feedback was
	# 'looks like it's wagging, not walking'. New values:
	#   - bigger stride swing (0.45-0.60) so the leg visibly
	#     lifts forward each step,
	#   - smaller torso bob (0.05-0.07) so the heaviness comes
	#     from leg weight, not body roll.
	for entry: Dictionary in _member_data:
		if entry.get("root", null) == member:
			entry["stride_speed"] = randf_range(0.55, 0.68)
			entry["stride_swing"] = randf_range(0.45, 0.60)
			entry["bob_amount"] = randf_range(0.05, 0.07)
			entry["idle_speed"] = randf_range(0.30, 0.45)
			break


func _apply_combine_hammer_anvil_sigil(member: Node3D) -> void:
	## Combine doctrine icon — a brass hammer-and-anvil plate embossed
	## on the chest backing. Per 03_factions §2: "hammer-and-anvil
	## iconography ... oaths". Built as: dark backing plate, horizontal
	## anvil bar at the bottom, vertical hammer head above it, brass
	## emissive on a dark backing so it reads at any RTS zoom.
	## Attached to the leader's TorsoPivot — the four-legged Bulwark's
	## torso_pivot is at member/TorsoPivot per the standard build.
	var torso_pivot: Node3D = member.get_node_or_null("TorsoPivot") as Node3D
	if not torso_pivot:
		return
	# Pull torso_size from the first BoxMesh child of torso_pivot (the
	# torso itself). Fall back to a sensible default if not found.
	var torso_size: Vector3 = Vector3(1.6, 0.8, 2.4)
	for child: Node in torso_pivot.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh is BoxMesh:
			torso_size = ((child as MeshInstance3D).mesh as BoxMesh).size
			break
	var anvil_brass: Color = Color(0.78, 0.62, 0.18, 1.0)
	var dark: Color = Color(0.10, 0.09, 0.08, 1.0)
	# Backing plate.
	var backing := MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(torso_size.x * 0.32, torso_size.y * 0.34, 0.04)
	backing.mesh = bb
	backing.position = Vector3(0.0, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.03)
	var backing_mat := _make_metal_mat(dark)
	backing.set_surface_override_material(0, backing_mat)
	torso_pivot.add_child(backing)
	# Brass material (shared by anvil + hammer for unity).
	var brass_mat := StandardMaterial3D.new()
	brass_mat.albedo_color = anvil_brass
	brass_mat.emission_enabled = true
	brass_mat.emission = anvil_brass
	brass_mat.emission_energy_multiplier = 0.55
	brass_mat.metallic = 0.85
	brass_mat.roughness = 0.25
	# Anvil base — horizontal bar near the bottom of the backing.
	var anvil_bar := MeshInstance3D.new()
	var ab_box := BoxMesh.new()
	ab_box.size = Vector3(torso_size.x * 0.24, torso_size.y * 0.06, 0.04)
	anvil_bar.mesh = ab_box
	anvil_bar.position = Vector3(0.0, torso_size.y * 0.43, -torso_size.z * 0.5 - 0.05)
	anvil_bar.set_surface_override_material(0, brass_mat)
	torso_pivot.add_child(anvil_bar)
	# Hammer head — wider rectangle above the anvil.
	var hammer_head := MeshInstance3D.new()
	var hh_box := BoxMesh.new()
	hh_box.size = Vector3(torso_size.x * 0.18, torso_size.y * 0.10, 0.04)
	hammer_head.mesh = hh_box
	hammer_head.position = Vector3(0.0, torso_size.y * 0.62, -torso_size.z * 0.5 - 0.05)
	hammer_head.set_surface_override_material(0, brass_mat)
	torso_pivot.add_child(hammer_head)
	# Hammer haft — slim vertical bar between the hammer head and the
	# anvil bar.
	var haft := MeshInstance3D.new()
	var ht_box := BoxMesh.new()
	ht_box.size = Vector3(torso_size.x * 0.04, torso_size.y * 0.10, 0.04)
	haft.mesh = ht_box
	haft.position = Vector3(0.0, torso_size.y * 0.52, -torso_size.z * 0.5 - 0.05)
	haft.set_surface_override_material(0, brass_mat)
	torso_pivot.add_child(haft)


func _apply_special_chassis_scale(member: Node3D, scale: float) -> void:
	## Cosmetic-only chassis scale-up for special / hero units. The
	## CharacterBody3D's collision + combat math don't move with this
	## (they read from global_position, not the visual subtree), so
	## the unit reads visibly larger without affecting hitboxes,
	## squad spacing, or movement.
	if not is_instance_valid(member) or scale <= 0.0:
		return
	member.scale = Vector3(scale, scale, scale)


func _apply_pulsefont_caster_turret(
	torso_pivot: Node3D,
	torso_size: Vector3,
	head_size: Vector3,
	mats: Array[StandardMaterial3D],
) -> void:
	## Distinct caster turret that visually overrides the standard
	## medium-chassis side cannon: two side prongs flanking a hovering
	## emitter orb mounted on top of the head. Stacks on top of the
	## existing head + cannons so combat-code geometry isn't disturbed,
	## but the silhouette reads as 'broadcast caster' instead of 'one
	## of those Jackal-class shooters'.
	var beam_color: Color = Color(0.55, 0.85, 1.0)
	var top_y: float = torso_size.y + head_size.y * 0.55
	# Two angled prongs on the head sides -- thin tapered cylinders
	# meeting above the head like an antenna fork.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var prong: MeshInstance3D = MeshInstance3D.new()
		var p_cyl: CylinderMesh = CylinderMesh.new()
		p_cyl.top_radius = 0.04
		p_cyl.bottom_radius = 0.10
		p_cyl.height = head_size.y * 1.4
		p_cyl.radial_segments = 8
		prong.mesh = p_cyl
		prong.rotation = Vector3(0.0, 0.0, deg_to_rad(-22.0 * sx))
		prong.position = Vector3(
			sx * head_size.x * 0.46,
			top_y + p_cyl.height * 0.45,
			0.0,
		)
		var p_mat: StandardMaterial3D = StandardMaterial3D.new()
		p_mat.albedo_color = Color(0.16, 0.18, 0.22)
		p_mat.metallic = 0.55
		p_mat.roughness = 0.30
		prong.set_surface_override_material(0, p_mat)
		torso_pivot.add_child(prong)
		mats.append(p_mat)
	# Hovering emitter orb cradled between the prongs -- bright
	# emissive sphere that visually outranks the head-mounted
	# cannons below it.
	var orb: MeshInstance3D = MeshInstance3D.new()
	var sph: SphereMesh = SphereMesh.new()
	sph.radius = head_size.x * 0.42
	sph.height = head_size.x * 0.84
	orb.mesh = sph
	orb.position = Vector3(0.0, top_y + head_size.y * 0.95, 0.0)
	var orb_mat: StandardMaterial3D = StandardMaterial3D.new()
	orb_mat.albedo_color = beam_color
	orb_mat.emission_enabled = true
	orb_mat.emission = beam_color
	orb_mat.emission_energy_multiplier = 3.5
	orb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	orb.set_surface_override_material(0, orb_mat)
	torso_pivot.add_child(orb)
	mats.append(orb_mat)
	# Inner core ring -- a flat torus laid horizontally inside the
	# orb gives a distinctive 'energy field' read at any zoom.
	var ring: MeshInstance3D = MeshInstance3D.new()
	var t_mesh: TorusMesh = TorusMesh.new()
	t_mesh.inner_radius = sph.radius * 0.7
	t_mesh.outer_radius = sph.radius * 1.05
	t_mesh.rings = 24
	t_mesh.ring_segments = 8
	ring.mesh = t_mesh
	ring.rotation.x = PI * 0.5
	ring.position = orb.position
	var ring_mat: StandardMaterial3D = StandardMaterial3D.new()
	ring_mat.albedo_color = Color(beam_color.r, beam_color.g, beam_color.b, 0.85)
	ring_mat.emission_enabled = true
	ring_mat.emission = beam_color
	ring_mat.emission_energy_multiplier = 4.5
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, ring_mat)
	torso_pivot.add_child(ring)
	mats.append(ring_mat)


func _apply_pulsefont_overlay(
	torso_pivot: Node3D,
	torso_size: Vector3,
	head_size: Vector3,
	mats: Array[StandardMaterial3D],
) -> void:
	## Overlay geometry that turns a generic Sable medium chassis into
	## a Pulsefont caster. Adds: a tall crystalline emitter spire on
	## the back of the torso, an emissive halo ring around the chest
	## (the visible Mesh aura band), and three small floating pulse
	## nodes orbiting at shoulder height. The original head + cannons
	## stay where they are so combat code (muzzle pivots, recoil) is
	## unaffected.
	var halo_color: Color = Color(0.4, 0.8, 1.0)
	var crystal_color: Color = Color(0.55, 0.7, 1.0)

	# --- Halo ring around the chest (the Mesh aura visual). ---
	var halo := MeshInstance3D.new()
	var halo_torus := TorusMesh.new()
	halo_torus.inner_radius = torso_size.x * 0.62
	halo_torus.outer_radius = torso_size.x * 0.72
	halo_torus.ring_segments = 6
	halo_torus.rings = 24
	halo.mesh = halo_torus
	halo.position = Vector3(0.0, torso_size.y * 0.55, 0.0)
	# Lay it flat so it reads as a circular band when seen from above.
	var halo_mat := StandardMaterial3D.new()
	halo_mat.albedo_color = halo_color
	halo_mat.emission_enabled = true
	halo_mat.emission = halo_color
	halo_mat.emission_energy_multiplier = 2.4
	halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo.set_surface_override_material(0, halo_mat)
	torso_pivot.add_child(halo)
	mats.append(halo_mat)

	# --- Tall crystalline emitter spire on the upper back. ---
	# Three stacked tapering prisms (4-sided cylinders rotated 45°)
	# read as a sharp crystal antenna catching the rim light.
	var spire_root := Node3D.new()
	spire_root.position = Vector3(0.0, torso_size.y, torso_size.z * 0.35)
	torso_pivot.add_child(spire_root)
	var heights: Array = [0.42, 0.30, 0.22]
	var radii: Array = [0.14, 0.10, 0.07]
	var stack_y: float = 0.0
	for i: int in heights.size():
		var seg_h: float = heights[i] as float
		var seg_top: float = (radii[i + 1] as float) if i + 1 < radii.size() else (radii[i] as float) * 0.4
		var seg_bot: float = radii[i] as float
		var seg := MeshInstance3D.new()
		var seg_cyl := CylinderMesh.new()
		seg_cyl.top_radius = seg_top
		seg_cyl.bottom_radius = seg_bot
		seg_cyl.height = seg_h
		seg_cyl.radial_segments = 4
		seg.mesh = seg_cyl
		seg.position.y = stack_y + seg_h * 0.5
		seg.rotation.y = deg_to_rad(45.0 * float(i))
		var seg_mat := StandardMaterial3D.new()
		seg_mat.albedo_color = crystal_color
		seg_mat.emission_enabled = true
		seg_mat.emission = crystal_color
		seg_mat.emission_energy_multiplier = 1.3 + 0.6 * float(i)
		seg_mat.metallic = 0.4
		seg_mat.roughness = 0.25
		seg.set_surface_override_material(0, seg_mat)
		spire_root.add_child(seg)
		mats.append(seg_mat)
		stack_y += seg_h - 0.02

	# Capstone — a small bright pyramid tip on top of the spire.
	var cap := MeshInstance3D.new()
	var cap_cyl := CylinderMesh.new()
	cap_cyl.top_radius = 0.0
	cap_cyl.bottom_radius = 0.06
	cap_cyl.height = 0.18
	cap_cyl.radial_segments = 4
	cap.mesh = cap_cyl
	cap.position.y = stack_y + 0.09
	cap.rotation.y = deg_to_rad(22.5)
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = halo_color
	cap_mat.emission_enabled = true
	cap_mat.emission = halo_color
	cap_mat.emission_energy_multiplier = 3.5
	cap_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cap.set_surface_override_material(0, cap_mat)
	spire_root.add_child(cap)
	mats.append(cap_mat)

	# Distinct caster turret on top of the head. Visually outranks
	# the standard medium-chassis side cannon so the silhouette
	# reads as 'broadcast emitter' rather than 'Jackal-class
	# shooter' at typical zoom levels.
	_apply_pulsefont_caster_turret(torso_pivot, torso_size, head_size, mats)

	# Forward-facing parabolic chest dish — aimed where System Crash
	# fires its 90° cone. Two pieces: a flat backing disc on the chest
	# and a curved rim (TorusMesh) on top so the silhouette reads as a
	# concave dish rather than a flat plate. Sits high on the torso
	# under the spire so both features are visible from the side.
	var dish_back := MeshInstance3D.new()
	var dish_back_cyl := CylinderMesh.new()
	dish_back_cyl.top_radius = torso_size.x * 0.45
	dish_back_cyl.bottom_radius = torso_size.x * 0.45
	dish_back_cyl.height = 0.06
	dish_back_cyl.radial_segments = 24
	dish_back.mesh = dish_back_cyl
	# Lay flat against the chest with the dish face pointing forward (-Z).
	dish_back.rotation.x = PI * 0.5
	dish_back.position = Vector3(0.0, torso_size.y * 0.45, -torso_size.z * 0.5 - 0.05)
	var dish_back_mat := StandardMaterial3D.new()
	dish_back_mat.albedo_color = halo_color
	dish_back_mat.emission_enabled = true
	dish_back_mat.emission = halo_color
	dish_back_mat.emission_energy_multiplier = 1.8
	dish_back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dish_back.set_surface_override_material(0, dish_back_mat)
	torso_pivot.add_child(dish_back)
	mats.append(dish_back_mat)
	# Concave rim torus framing the dish.
	var dish_rim := MeshInstance3D.new()
	var dish_rim_t := TorusMesh.new()
	dish_rim_t.inner_radius = torso_size.x * 0.40
	dish_rim_t.outer_radius = torso_size.x * 0.50
	dish_rim_t.rings = 32
	dish_rim_t.ring_segments = 8
	dish_rim.mesh = dish_rim_t
	# Torus is flat by default in the XZ plane; rotate so the dish
	# faces forward like a satellite reflector.
	dish_rim.rotation.x = PI * 0.5
	dish_rim.position = Vector3(0.0, torso_size.y * 0.45, -torso_size.z * 0.5 - 0.10)
	var dish_rim_mat := _make_metal_mat(Color(0.16, 0.18, 0.22))
	dish_rim.set_surface_override_material(0, dish_rim_mat)
	torso_pivot.add_child(dish_rim)
	mats.append(dish_rim_mat)

	# Violet conduits running down each leg-side of the torso — sells
	# "this is a high-power caster, power lines run through it". Two
	# thin emissive strips on each hip-line, descending past the torso
	# bottom (legs animate below, so the visible run-out is correct
	# from the top-down RTS camera).
	for c_side: int in 2:
		var cx: float = -torso_size.x * 0.34 if c_side == 0 else torso_size.x * 0.34
		var conduit := MeshInstance3D.new()
		var c_box := BoxMesh.new()
		c_box.size = Vector3(0.05, torso_size.y * 0.95, 0.05)
		conduit.mesh = c_box
		conduit.position = Vector3(cx, torso_size.y * 0.10, 0.04)
		var c_mat := StandardMaterial3D.new()
		c_mat.albedo_color = halo_color
		c_mat.emission_enabled = true
		c_mat.emission = halo_color
		c_mat.emission_energy_multiplier = 1.4
		c_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		conduit.set_surface_override_material(0, c_mat)
		torso_pivot.add_child(conduit)
		mats.append(c_mat)

	# --- Three small floating pulse nodes around the chest. ---
	# Equilateral arrangement at chest height; emissive blue cubes
	# tilted 45° to read as glowing diamonds from above.
	var node_radius: float = torso_size.x * 0.95
	for i: int in 3:
		var angle: float = TAU * float(i) / 3.0 - PI / 2.0
		var pulse_node := MeshInstance3D.new()
		var pulse_box := BoxMesh.new()
		pulse_box.size = Vector3(0.13, 0.13, 0.13)
		pulse_node.mesh = pulse_box
		pulse_node.position = Vector3(
			cos(angle) * node_radius,
			torso_size.y * 0.6 + sin(float(i) * 1.7) * 0.05,
			sin(angle) * node_radius,
		)
		pulse_node.rotation = Vector3(deg_to_rad(45.0), deg_to_rad(45.0), 0.0)
		var pulse_mat := StandardMaterial3D.new()
		pulse_mat.albedo_color = halo_color
		pulse_mat.emission_enabled = true
		pulse_mat.emission = halo_color
		pulse_mat.emission_energy_multiplier = 2.8
		pulse_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pulse_node.set_surface_override_material(0, pulse_mat)
		torso_pivot.add_child(pulse_node)
		mats.append(pulse_mat)


func _apply_forgemaster_overlay(
	torso_pivot: Node3D,
	torso_size: Vector3,
	head_size: Vector3,
	mats: Array[StandardMaterial3D],
) -> void:
	## Overlay geometry that turns a generic Anvil heavy chassis into
	## a Forgemaster — distinct support-mech silhouette so it doesn't
	## just read as a recoloured Bulwark. Stacks: a tall furnace
	## stack on the rear deck with a glowing forge mouth (the heal
	## visual cue), a roof-mounted Skyspike AA launcher rack
	## (communicates the strong AA secondary), and a chest-front
	## repair-coil ring tinted Anvil amber (telegraphs Factory
	## Pulse's heal aura). The original Bulwark cannons + chassis
	## stay where they are so combat code (muzzle pivots, recoil)
	## is unaffected.
	var anvil_amber: Color = Color(1.0, 0.55, 0.18)
	var forge_red: Color = Color(1.0, 0.35, 0.10)

	# --- Tapered front prow plating. Two stacked sloped wedges on
	# the leading edge of the torso (the -Z face) so the chassis has
	# a clear 'this is the front' read at top-down camera. Without
	# this the wide carapace torso reads as symmetrical and the
	# player can't tell facing at a glance. The prow narrows from
	# the torso width down to a slim leading edge.
	var prow_root := Node3D.new()
	prow_root.position = Vector3(0.0, torso_size.y * 0.45, -torso_size.z * 0.45)
	torso_pivot.add_child(prow_root)
	# Lower wedge -- broad base.
	var prow_lower := MeshInstance3D.new()
	var prow_lower_box := BoxMesh.new()
	prow_lower_box.size = Vector3(torso_size.x * 0.95, torso_size.y * 0.42, torso_size.z * 0.22)
	prow_lower.mesh = prow_lower_box
	prow_lower.position = Vector3(0.0, -torso_size.y * 0.18, -torso_size.z * 0.04)
	prow_lower.rotation.x = deg_to_rad(-22.0)  # lean forward + down
	var prow_mat := _make_metal_mat(Color(0.32, 0.30, 0.28))
	prow_lower.set_surface_override_material(0, prow_mat)
	prow_root.add_child(prow_lower)
	mats.append(prow_mat)
	# Upper wedge -- narrower nose plate further forward.
	var prow_upper := MeshInstance3D.new()
	var prow_upper_box := BoxMesh.new()
	prow_upper_box.size = Vector3(torso_size.x * 0.62, torso_size.y * 0.34, torso_size.z * 0.18)
	prow_upper.mesh = prow_upper_box
	prow_upper.position = Vector3(0.0, torso_size.y * 0.06, -torso_size.z * 0.10)
	prow_upper.rotation.x = deg_to_rad(-30.0)  # steeper slope
	var prow_upper_mat := _make_metal_mat(Color(0.36, 0.34, 0.32))
	prow_upper.set_surface_override_material(0, prow_upper_mat)
	prow_root.add_child(prow_upper)
	mats.append(prow_upper_mat)
	# Amber accent strip along the prow's leading edge -- reads as
	# warning paint on a heavy industrial vehicle.
	var prow_stripe := MeshInstance3D.new()
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(torso_size.x * 0.55, 0.04, torso_size.z * 0.06)
	prow_stripe.mesh = stripe_box
	prow_stripe.position = Vector3(0.0, torso_size.y * 0.16, -torso_size.z * 0.18)
	prow_stripe.rotation.x = deg_to_rad(-30.0)
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = anvil_amber
	stripe_mat.emission_enabled = true
	stripe_mat.emission = anvil_amber
	stripe_mat.emission_energy_multiplier = 1.4
	stripe_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	prow_stripe.set_surface_override_material(0, stripe_mat)
	prow_root.add_child(prow_stripe)
	mats.append(stripe_mat)

	# --- Furnace stack on the rear deck. Communicates "industrial
	# repair shop" — a tall vertical chimney with a glowing mouth
	# at its base.
	var stack_root := Node3D.new()
	stack_root.position = Vector3(0.0, torso_size.y, torso_size.z * 0.35)
	torso_pivot.add_child(stack_root)
	# Wide base block — the actual furnace housing.
	var furnace := MeshInstance3D.new()
	var furnace_box := BoxMesh.new()
	furnace_box.size = Vector3(0.65, 0.45, 0.50)
	furnace.mesh = furnace_box
	furnace.position.y = 0.20
	var furnace_mat := _make_metal_mat(Color(0.18, 0.16, 0.14))
	furnace.set_surface_override_material(0, furnace_mat)
	stack_root.add_child(furnace)
	mats.append(furnace_mat)
	# Glowing forge mouth — emissive recess on the front face.
	var mouth := MeshInstance3D.new()
	var mouth_box := BoxMesh.new()
	mouth_box.size = Vector3(0.45, 0.22, 0.05)
	mouth.mesh = mouth_box
	mouth.position = Vector3(0.0, 0.18, -0.26)
	var mouth_mat := StandardMaterial3D.new()
	mouth_mat.albedo_color = forge_red
	mouth_mat.emission_enabled = true
	mouth_mat.emission = forge_red
	mouth_mat.emission_energy_multiplier = 3.4
	mouth_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mouth.set_surface_override_material(0, mouth_mat)
	stack_root.add_child(mouth)
	mats.append(mouth_mat)
	# Tall chimney rising from the furnace top — three stacked
	# segments tapering inward so the silhouette reads vertical.
	var chimney_y: float = 0.45
	for seg_i: int in 3:
		var seg := MeshInstance3D.new()
		var seg_box := BoxMesh.new()
		var w: float = 0.34 - float(seg_i) * 0.05
		var h: float = 0.32
		seg_box.size = Vector3(w, h, w)
		seg.mesh = seg_box
		seg.position.y = chimney_y + h * 0.5
		seg.set_surface_override_material(0, _make_metal_mat(Color(0.12, 0.11, 0.10)))
		stack_root.add_child(seg)
		chimney_y += h - 0.02
	# Cap with a faint amber glow at the top — heat haze read.
	var stack_cap := MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	cap_box.size = Vector3(0.20, 0.06, 0.20)
	stack_cap.mesh = cap_box
	stack_cap.position.y = chimney_y + 0.03
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = anvil_amber
	cap_mat.emission_enabled = true
	cap_mat.emission = anvil_amber
	cap_mat.emission_energy_multiplier = 2.2
	cap_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	stack_cap.set_surface_override_material(0, cap_mat)
	stack_root.add_child(stack_cap)
	mats.append(cap_mat)

	# --- Roof-mounted Skyspike AA rack. Quad missile tubes angled
	# upward so the player reads "anti-air" without needing the
	# tooltip. Sits between the chimney and the front of the chassis.
	var rack_root := Node3D.new()
	rack_root.position = Vector3(0.0, torso_size.y + 0.05, -torso_size.z * 0.05)
	torso_pivot.add_child(rack_root)
	# Mount block.
	var mount := MeshInstance3D.new()
	var mount_box := BoxMesh.new()
	mount_box.size = Vector3(0.55, 0.10, 0.45)
	mount.mesh = mount_box
	mount.set_surface_override_material(0, _make_metal_mat(Color(0.20, 0.18, 0.16)))
	rack_root.add_child(mount)
	# Four upward-angled launch tubes.
	for tube_i: int in 4:
		var tube := MeshInstance3D.new()
		var tube_cyl := CylinderMesh.new()
		tube_cyl.top_radius = 0.06
		tube_cyl.bottom_radius = 0.06
		tube_cyl.height = 0.32
		tube_cyl.radial_segments = 6
		tube.mesh = tube_cyl
		var tx: float = (float(tube_i % 2) - 0.5) * 0.34
		var tz: float = (float(tube_i / 2) - 0.5) * 0.30
		tube.position = Vector3(tx, 0.20, tz)
		tube.rotation.x = deg_to_rad(-15.0)
		tube.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.10)))
		rack_root.add_child(tube)
		# Glowing missile tip showing in the tube mouth.
		var tip := MeshInstance3D.new()
		var tip_cyl := CylinderMesh.new()
		tip_cyl.top_radius = 0.05
		tip_cyl.bottom_radius = 0.05
		tip_cyl.height = 0.06
		tip.mesh = tip_cyl
		tip.position = Vector3(tx, 0.36, tz)
		tip.rotation.x = deg_to_rad(-15.0)
		var tip_mat := StandardMaterial3D.new()
		tip_mat.albedo_color = anvil_amber
		tip_mat.emission_enabled = true
		tip_mat.emission = anvil_amber
		tip_mat.emission_energy_multiplier = 2.0
		tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		tip.set_surface_override_material(0, tip_mat)
		rack_root.add_child(tip)
		mats.append(tip_mat)

	# --- Repair-coil torus ringing the chest. Tinted Anvil amber so
	# it reads as a heal aura emitter (parallel to the Pulsefont's
	# blue Mesh halo).
	var coil := MeshInstance3D.new()
	var coil_torus := TorusMesh.new()
	coil_torus.inner_radius = torso_size.x * 0.55
	coil_torus.outer_radius = torso_size.x * 0.66
	coil_torus.ring_segments = 6
	coil_torus.rings = 24
	coil.mesh = coil_torus
	coil.position = Vector3(0.0, torso_size.y * 0.55, 0.0)
	var coil_mat := StandardMaterial3D.new()
	coil_mat.albedo_color = anvil_amber
	coil_mat.emission_enabled = true
	coil_mat.emission = anvil_amber
	coil_mat.emission_energy_multiplier = 2.4
	coil_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	coil.set_surface_override_material(0, coil_mat)
	torso_pivot.add_child(coil)
	mats.append(coil_mat)


func _build_courier_tank_member(index: int, offset: Vector3, team_color: Color) -> Dictionary:
	## Meridian Courier — tracked transport with a twin-MG turret.
	## Replaces the standard mech build for the "transport" unit_class.
	## Returns the same per-member dict shape so the squad-visuals
	## bookkeeping in _build_squad_visuals stays compatible (legs +
	## leg_phases come back empty so the walk-bob code skips this
	## member without crashing).
	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []
	var sable_dark: Color = _faction_tint_chassis(Color(0.18, 0.18, 0.22))
	var sable_mid: Color = _faction_tint_chassis(Color(0.28, 0.28, 0.32))
	# Accent colour swings to Anvil amber for the Breacher Tank
	# variants so a player using both factions doesn't see two
	# tracked tanks share the same Meridian-violet seam read. Meridian
	# Courier keeps its violet identity.
	var is_breacher: bool = stats != null and stats.unit_name.findn("Breacher") >= 0
	var sable_violet: Color = Color(1.00, 0.55, 0.18) if is_breacher else Color(0.78, 0.42, 1.0)
	# Per-member rib list returned via member_info["track_ribs"] — the
	# bake collector skips these so position-scroll on velocity actually
	# moves the visible plates instead of editing a baked combined mesh.
	var member_track_ribs: Array[MeshInstance3D] = []

	# --- Dual-bogie tracks per user pick 2026-05-14 ("dual track setup
	# like their crawler has"). Each side gets TWO shorter tread
	# segments — front + rear — staggered with opposite X-tilts so the
	# bogies splay outward at the ends. Mirrors the Sable Crawler look
	# in salvage_crawler.gd._build_tread_segment.
	# Tread + spacing pass 2026-05-15: bigger treads (taller / wider /
	# longer) and a wider midline gap so the hull reads as suspended
	# between two distinct track packs instead of sitting on a single
	# block.
	var track_h: float = 0.58
	var bogie_len: float = 1.50
	var bogie_w: float = 0.55
	var bogie_offsets: Array[float] = [-0.95, 0.95]
	var bogie_tilts: Array[float] = [-8.0, 8.0]
	for side: int in 2:
		var sx: float = -1.40 if side == 0 else 1.40
		for bg_i: int in bogie_offsets.size():
			var z_center: float = bogie_offsets[bg_i]
			var tilt_deg: float = bogie_tilts[bg_i]
			# Tilted bogie root lets the segment angle outward at the
			# end without baking the rotation into every child.
			var seg_root := Node3D.new()
			seg_root.position = Vector3(sx, track_h * 0.55, z_center)
			seg_root.rotation.x = deg_to_rad(tilt_deg)
			member.add_child(seg_root)
			# Tread slab.
			var tread := MeshInstance3D.new()
			var tb := BoxMesh.new()
			tb.size = Vector3(bogie_w, track_h * 0.78, bogie_len)
			tread.mesh = tb
			tread.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.12)))
			seg_root.add_child(tread)
			# Plate ribs along the bogie top — register for scroll.
			var plate_count: int = 4
			var plate_mat := _make_metal_mat(Color(0.06, 0.06, 0.06))
			for p_i: int in plate_count:
				var t: float = (float(p_i) + 0.5) / float(plate_count)
				var rib := MeshInstance3D.new()
				var rb := BoxMesh.new()
				rb.size = Vector3(bogie_w + 0.04, 0.06, 0.20)
				rib.mesh = rb
				rib.position = Vector3(0.0, track_h * 0.4, -bogie_len * 0.5 + t * bogie_len)
				rib.set_surface_override_material(0, plate_mat)
				seg_root.add_child(rib)
				_courier_track_ribs.append({"node": rib, "length": bogie_len})
				member_track_ribs.append(rib)
			# Outer-edge top rail strip.
			var rail := MeshInstance3D.new()
			var rail_box := BoxMesh.new()
			rail_box.size = Vector3(0.08, 0.05, bogie_len * 0.94)
			rail.mesh = rail_box
			rail.position = Vector3(0.16 if sx > 0.0 else -0.16, track_h * 0.4, 0.0)
			rail.set_surface_override_material(0, _make_metal_mat(Color(0.18, 0.16, 0.20)))
			seg_root.add_child(rail)
			# Drive sprocket (front) + idler (rear) end-wheels — the
			# sprocket gets a low radial segment count so the polygon
			# edges read as gear teeth.
			for end_i: int in 2:
				var ez: float = -bogie_len * 0.5 + 0.08 if end_i == 0 else bogie_len * 0.5 - 0.08
				var wheel := MeshInstance3D.new()
				var w_cyl := CylinderMesh.new()
				w_cyl.top_radius = track_h * 0.5
				w_cyl.bottom_radius = track_h * 0.5
				w_cyl.height = bogie_w * 0.7
				w_cyl.radial_segments = 10 if end_i == 0 else 14
				wheel.mesh = w_cyl
				wheel.rotate_object_local(Vector3.FORWARD, PI * 0.5)
				wheel.position = Vector3(0.0, 0.0, ez)
				wheel.set_surface_override_material(0, _make_metal_mat(Color(0.12, 0.12, 0.14)))
				seg_root.add_child(wheel)

	# --- Hull. Two-section transport chassis (playtest 2026-05-15):
	#   Front 55%: tall enclosed turret bay.
	#   Rear 45%: lower open-topped cargo bed with low side rails so
	#     the silhouette reads as a transport, not a gun-tank.
	# Rides LOW so the chassis bottom dips into the upper third of the
	# tread height — the vehicle and treads read as one design.
	var hull_w: float = 1.55
	var hull_h: float = 0.55
	var hull_len: float = 2.55
	var hull_y: float = track_h * 0.65 + hull_h * 0.5
	var hull_mat := _make_metal_mat(sable_mid)
	mats.append(hull_mat)
	# Forward enclosed section — covers the front portion + the turret.
	var fwd_len: float = hull_len * 0.55
	var fwd_z: float = -hull_len * 0.5 + fwd_len * 0.5  # flush with the nose
	var hull := MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(hull_w, hull_h, fwd_len)
	hull.mesh = hull_box
	hull.position = Vector3(0.0, hull_y, fwd_z)
	hull.set_surface_override_material(0, hull_mat)
	member.add_child(hull)
	# Lower rear chassis — the cargo bed FLOOR. Half-height + slightly
	# narrower so the side profile tapers down toward the rear.
	var rear_len: float = hull_len * 0.45
	var rear_z: float = hull_len * 0.5 - rear_len * 0.5
	var rear_chassis := MeshInstance3D.new()
	var rear_box := BoxMesh.new()
	rear_box.size = Vector3(hull_w * 0.88, hull_h * 0.45, rear_len)
	rear_chassis.mesh = rear_box
	rear_chassis.position = Vector3(0.0, hull_y - hull_h * 0.275, rear_z)
	rear_chassis.set_surface_override_material(0, hull_mat)
	member.add_child(rear_chassis)
	# Tapered side skirts on the FORWARD hull — angled panels that
	# slope from the hull side at the top down to the tread top at the
	# bottom, giving the chassis a trapezoidal cross-section so it
	# reads as one tapered shape with the treads instead of a flat
	# brick floating between two track packs.
	var skirt_h: float = hull_h * 0.95
	var skirt_tilt: float = deg_to_rad(18.0)
	for skirt_side: int in 2:
		var ssx: float = -1.0 if skirt_side == 0 else 1.0
		var skirt := MeshInstance3D.new()
		var sk_box := BoxMesh.new()
		sk_box.size = Vector3(0.06, skirt_h, fwd_len * 0.95)
		skirt.mesh = sk_box
		# Position the skirt's TOP edge at the hull side; tilting on Z
		# pivots the bottom OUTWARD so it meets the tread top.
		skirt.position = Vector3(ssx * (hull_w * 0.5 + sin(skirt_tilt) * skirt_h * 0.5), hull_y, fwd_z)
		skirt.rotation.z = -ssx * skirt_tilt
		skirt.set_surface_override_material(0, hull_mat)
		member.add_child(skirt)
	# Cargo bed side rails — low walls along the open rear so the bay
	# reads as "open-topped", not "missing piece". Tops are open so the
	# player sees the floor through the gap.
	var rail_h: float = hull_h * 0.32
	var rail_y: float = hull_y - hull_h * 0.05
	for rail_side: int in 2:
		var rsx: float = -hull_w * 0.42 if rail_side == 0 else hull_w * 0.42
		var rail := MeshInstance3D.new()
		var rail_box := BoxMesh.new()
		rail_box.size = Vector3(0.08, rail_h, rear_len * 0.92)
		rail.mesh = rail_box
		rail.position = Vector3(rsx, rail_y, rear_z)
		rail.set_surface_override_material(0, hull_mat)
		member.add_child(rail)
	# Rear tailgate — short low wall closing the back of the bay so
	# passengers don't fall out the open end.
	var tailgate := MeshInstance3D.new()
	var tg_box := BoxMesh.new()
	tg_box.size = Vector3(hull_w * 0.78, rail_h, 0.06)
	tailgate.mesh = tg_box
	tailgate.position = Vector3(0.0, rail_y, hull_len * 0.5 - 0.04)
	tailgate.set_surface_override_material(0, hull_mat)
	member.add_child(tailgate)
	# Hull-to-rear-chassis junction — short bevel panel between the
	# tall front bay and the lower rear chassis so the step isn't a
	# blunt cliff.
	var junction := MeshInstance3D.new()
	var jb := BoxMesh.new()
	jb.size = Vector3(hull_w * 0.92, hull_h * 0.55, 0.20)
	junction.mesh = jb
	junction.rotate_object_local(Vector3.RIGHT, deg_to_rad(38.0))
	junction.position = Vector3(0.0, hull_y - hull_h * 0.10, fwd_z + fwd_len * 0.5 + 0.04)
	junction.set_surface_override_material(0, hull_mat)
	member.add_child(junction)

	# Side fenders — bridge the gap between hull edge and tread top so
	# the chassis reads as one connected vehicle instead of a hull
	# floating between two detached track packs. Sits flush on top of
	# the inner edge of each tread pack and tucks under the hull side.
	var fender_w: float = 1.40 - 0.775  # tread sx − hull half-width
	var fender_h: float = 0.10
	var fender_y: float = track_h * 0.55 + track_h * 0.40 - 0.02
	for side_f: int in 2:
		var fx: float = -(0.775 + fender_w * 0.5) if side_f == 0 else (0.775 + fender_w * 0.5)
		var fender := MeshInstance3D.new()
		var fb := BoxMesh.new()
		fb.size = Vector3(fender_w, fender_h, hull_len * 0.92)
		fender.mesh = fb
		fender.position = Vector3(fx, fender_y, 0.0)
		var fender_mat := _make_metal_mat(sable_dark)
		fender.set_surface_override_material(0, fender_mat)
		member.add_child(fender)
		mats.append(fender_mat)

	# Sloped front glacis — short angled plate on the nose.
	var glacis := MeshInstance3D.new()
	var glacis_box := BoxMesh.new()
	glacis_box.size = Vector3(hull_w * 0.95, hull_h * 0.55, 0.5)
	glacis.mesh = glacis_box
	glacis.rotate_object_local(Vector3.RIGHT, deg_to_rad(-28.0))
	glacis.position = Vector3(0.0, hull_y + hull_h * 0.1, -hull_len * 0.5 + 0.05)
	var glacis_mat := _make_metal_mat(sable_dark)
	glacis.set_surface_override_material(0, glacis_mat)
	member.add_child(glacis)
	mats.append(glacis_mat)

	# Team-color stripe along the FORWARD enclosed hull only — was
	# `hull_len * 0.7` long centered on z=0.18, which after the front-bay /
	# open-bed split left half the stripe floating mid-air over the open
	# cargo bed. Sized to the front bay so it sits on solid armor.
	var stripe := MeshInstance3D.new()
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(0.45, 0.06, fwd_len * 0.65)
	stripe.mesh = stripe_box
	stripe.position = Vector3(0.0, hull_y + hull_h * 0.5 + 0.02, fwd_z)
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team_color
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team_color
	stripe_mat.emission_energy_multiplier = 1.4
	stripe.set_surface_override_material(0, stripe_mat)
	member.add_child(stripe)
	mats.append(stripe_mat)

	# Sable violet edge accent along the lower hull-track seam — the
	# same identity strip that appears on Sable mechs.
	for accent_side: int in 2:
		var asx: float = -hull_w * 0.5 + 0.04 if accent_side == 0 else hull_w * 0.5 - 0.04
		var accent := MeshInstance3D.new()
		var accent_box := BoxMesh.new()
		accent_box.size = Vector3(0.04, 0.05, hull_len * 0.85)
		accent.mesh = accent_box
		accent.position = Vector3(asx, hull_y - hull_h * 0.5 + 0.02, 0.0)
		var accent_mat := StandardMaterial3D.new()
		accent_mat.albedo_color = sable_violet
		accent_mat.emission_enabled = true
		accent_mat.emission = sable_violet
		accent_mat.emission_energy_multiplier = 1.2
		accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		accent.set_surface_override_material(0, accent_mat)
		member.add_child(accent)
		mats.append(accent_mat)

	# --- Turret on top of the forward enclosed bay — moved forward
	# (z = -0.40) per playtest 2026-05-15 so the gun reads as a
	# "transport with a forward turret" silhouette rather than a tank
	# with a cargo bay tacked on.
	var turret_y: float = hull_y + hull_h * 0.5
	var turret_z: float = -0.40
	var turret_ring := MeshInstance3D.new()
	var ring_cyl := CylinderMesh.new()
	ring_cyl.top_radius = 0.50
	ring_cyl.bottom_radius = 0.55
	ring_cyl.height = 0.10
	ring_cyl.radial_segments = 16
	turret_ring.mesh = ring_cyl
	turret_ring.position = Vector3(0.0, turret_y + 0.05, turret_z)
	var ring_mat := _make_metal_mat(sable_dark)
	turret_ring.set_surface_override_material(0, ring_mat)
	member.add_child(turret_ring)
	mats.append(ring_mat)

	# Turret body — wedge-shaped block on the ring.
	var turret_pivot := Node3D.new()
	turret_pivot.name = "TurretPivot"
	turret_pivot.position = Vector3(0.0, turret_y + 0.10, turret_z)
	member.add_child(turret_pivot)
	var turret := MeshInstance3D.new()
	var turret_box := BoxMesh.new()
	turret_box.size = Vector3(0.85, 0.40, 0.95)
	turret.mesh = turret_box
	turret.position = Vector3(0.0, 0.20, 0.05)
	var turret_mat := _make_metal_mat(sable_mid)
	turret.set_surface_override_material(0, turret_mat)
	turret_pivot.add_child(turret)
	mats.append(turret_mat)

	# Cupola hatch — small box on top of the turret.
	var cupola := MeshInstance3D.new()
	var cup_box := BoxMesh.new()
	cup_box.size = Vector3(0.30, 0.14, 0.34)
	cupola.mesh = cup_box
	cupola.position = Vector3(-0.18, 0.47, 0.18)
	var cup_mat := _make_metal_mat(sable_dark)
	cupola.set_surface_override_material(0, cup_mat)
	turret_pivot.add_child(cupola)
	mats.append(cup_mat)

	# --- Twin MG barrels — two slim cylinders flanking a short
	# mantlet on the front face of the turret. The MGs share the
	# same cannon_pivot for recoil so a fire tick recoils both at
	# once.
	var mantlet := MeshInstance3D.new()
	var mantlet_box := BoxMesh.new()
	mantlet_box.size = Vector3(0.55, 0.28, 0.18)
	mantlet.mesh = mantlet_box
	mantlet.position = Vector3(0.0, 0.20, -0.42)
	var mantlet_mat := _make_metal_mat(sable_dark)
	mantlet.set_surface_override_material(0, mantlet_mat)
	turret_pivot.add_child(mantlet)
	mats.append(mantlet_mat)

	var cannon_pivot := Node3D.new()
	cannon_pivot.name = "CannonPivot_top"
	cannon_pivot.position = Vector3(0.0, 0.20, -0.50)
	turret_pivot.add_child(cannon_pivot)

	var mg_len: float = 0.85
	for mg_i: int in 2:
		var mx: float = -0.14 if mg_i == 0 else 0.14
		var mg := MeshInstance3D.new()
		var mg_cyl := CylinderMesh.new()
		mg_cyl.top_radius = 0.05
		mg_cyl.bottom_radius = 0.05
		mg_cyl.height = mg_len
		mg_cyl.radial_segments = 10
		mg.mesh = mg_cyl
		mg.rotate_object_local(Vector3.RIGHT, -PI * 0.5)
		mg.position = Vector3(mx, 0.0, -mg_len * 0.5)
		var mg_mat := _make_metal_mat(Color(0.08, 0.08, 0.08))
		mg.set_surface_override_material(0, mg_mat)
		cannon_pivot.add_child(mg)
		mats.append(mg_mat)

	# Tailgate marker light — small violet emissive strip on the
	# tailgate face. Replaces the old enclosed-rear bay hatch (the
	# rear is now an open-topped cargo bed; the rail + tailgate read
	# as the transport bay without needing a hatch).
	var bay_inset := MeshInstance3D.new()
	var bi_box := BoxMesh.new()
	bi_box.size = Vector3(hull_w * 0.45, rail_h * 0.50, 0.02)
	bay_inset.mesh = bi_box
	bay_inset.position = Vector3(0.0, rail_y + rail_h * 0.05, hull_len * 0.5 + 0.02)
	var bay_inset_mat := StandardMaterial3D.new()
	bay_inset_mat.albedo_color = sable_violet
	bay_inset_mat.emission_enabled = true
	bay_inset_mat.emission = sable_violet
	bay_inset_mat.emission_energy_multiplier = 1.6
	bay_inset_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bay_inset.set_surface_override_material(0, bay_inset_mat)
	member.add_child(bay_inset)
	mats.append(bay_inset_mat)
	# Asymmetric sensor mast on the back-left of the hull. Slim
	# tapering antenna with a violet emissive tip — Sable's mandated
	# off-axis silhouette feature.
	var mast := MeshInstance3D.new()
	var m_cyl := CylinderMesh.new()
	m_cyl.top_radius = 0.04
	m_cyl.bottom_radius = 0.06
	m_cyl.height = 0.85
	m_cyl.radial_segments = 8
	mast.mesh = m_cyl
	mast.position = Vector3(-hull_w * 0.35, hull_y + hull_h * 0.5 + 0.42, hull_len * 0.32)
	mast.rotation.z = deg_to_rad(8.0)
	var mast_mat := _make_metal_mat(Color(0.10, 0.10, 0.12))
	mast.set_surface_override_material(0, mast_mat)
	member.add_child(mast)
	mats.append(mast_mat)
	# Mast tip.
	var mast_tip := MeshInstance3D.new()
	var mt_sph := SphereMesh.new()
	mt_sph.radius = 0.06
	mt_sph.height = 0.12
	mast_tip.mesh = mt_sph
	mast_tip.position = Vector3(-hull_w * 0.35 + sin(deg_to_rad(8.0)) * 0.45, hull_y + hull_h * 0.5 + 0.88, hull_len * 0.32)
	var mast_tip_mat := StandardMaterial3D.new()
	mast_tip_mat.albedo_color = sable_violet
	mast_tip_mat.emission_enabled = true
	mast_tip_mat.emission = sable_violet
	mast_tip_mat.emission_energy_multiplier = 2.4
	mast_tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mast_tip.set_surface_override_material(0, mast_tip_mat)
	member.add_child(mast_tip)
	mats.append(mast_tip_mat)

	# Branch variant overlays for the Courier. Infiltrator gets
	# a stealth tarp draped over the hull (matte mottled colour);
	# Sensor Carrier gets a dish array on the rear deck. Combat
	# geometry stays put; overlays attach to `member`.
	if stats:
		match stats.unit_name:
			"Courier (Infiltrator)":
				_apply_courier_infiltrator_overlay(member, mats)
			"Courier (Sensor Carrier)":
				_apply_courier_sensor_overlay(member, mats)

	# --- Bookkeeping dict. Returns the same shape Unit's per-member
	# logic expects. Empty `legs` + `leg_phases` mean the walk-bob
	# pass skips this member entirely (tracks don't need it). The
	# tank still gets idle / stride floats so any code reading them
	# without a length check stays happy.
	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [mantlet] as Array,
		"cannons": [cannon_pivot] as Array,
		"track_ribs": member_track_ribs,
		"cannon_rest_z": [cannon_pivot.position.z] as Array,
		"cannon_muzzle_z": [mg_len + 0.05] as Array,
		"torso": hull,
		"head": turret,
		"mats": mats,
		"recoil": [0.0, 0.0],
		"stride_phase": randf_range(0.0, TAU),
		"stride_speed": randf_range(0.95, 1.05),
		"stride_swing": 0.0,
		"bob_amount": 0.02,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": randf_range(0.4, 0.7),
	}


## --- Branch variant overlays ---
##
## Each function adds geometry under `torso_pivot` so the unit
## silhouettes as its specific branch. Combat geometry (cannons,
## head, legs) stays put; overlays are pure visual differentiation.

const _ANVIL_RED: Color = Color(1.0, 0.30, 0.20)


func _apply_rook_spotter_overlay(torso_pivot: Node3D, torso_size: Vector3, head_size: Vector3) -> void:
	# Sensor mast on the right shoulder + a pale-blue eye on top.
	# Reads as the long-sight reconnaissance variant.
	var mast := MeshInstance3D.new()
	var mb := BoxMesh.new()
	mb.size = Vector3(0.06, 0.65, 0.06)
	mast.mesh = mb
	mast.position = Vector3(torso_size.x * 0.45, torso_size.y + 0.32, 0.0)
	mast.set_surface_override_material(0, _make_metal_mat(Color(0.18, 0.16, 0.14)))
	torso_pivot.add_child(mast)
	# Sensor eye -- emissive cyan disk on the mast tip.
	var eye := MeshInstance3D.new()
	var eye_sph := SphereMesh.new()
	eye_sph.radius = 0.10
	eye_sph.height = 0.20
	eye.mesh = eye_sph
	eye.position = Vector3(torso_size.x * 0.45, torso_size.y + 0.66, 0.0)
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.30, 0.78, 1.0)
	eye_mat.emission_enabled = true
	eye_mat.emission = Color(0.30, 0.78, 1.0)
	eye_mat.emission_energy_multiplier = 2.0
	eye.set_surface_override_material(0, eye_mat)
	torso_pivot.add_child(eye)


func _apply_rook_sapper_overlay(torso_pivot: Node3D, torso_size: Vector3) -> void:
	# Demolition charges strapped to the hip -- two cylindrical
	# satchels with a cord between them. Reads as 'this one is
	# carrying the building-cracker payload'.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var charge := MeshInstance3D.new()
		var c_cyl := CylinderMesh.new()
		c_cyl.top_radius = 0.10
		c_cyl.bottom_radius = 0.10
		c_cyl.height = 0.22
		c_cyl.radial_segments = 10
		charge.mesh = c_cyl
		charge.rotation.x = PI * 0.5
		charge.position = Vector3(sx * torso_size.x * 0.42, torso_size.y * 0.20, torso_size.z * 0.30)
		var c_mat := StandardMaterial3D.new()
		c_mat.albedo_color = Color(0.78, 0.16, 0.10)
		c_mat.roughness = 0.7
		charge.set_surface_override_material(0, c_mat)
		torso_pivot.add_child(charge)
		# Tan fuse cap.
		var fuse := MeshInstance3D.new()
		var f_cyl := CylinderMesh.new()
		f_cyl.top_radius = 0.025
		f_cyl.bottom_radius = 0.025
		f_cyl.height = 0.10
		fuse.mesh = f_cyl
		fuse.position = Vector3(sx * torso_size.x * 0.42, torso_size.y * 0.20 + 0.08, torso_size.z * 0.30)
		var f_mat := StandardMaterial3D.new()
		f_mat.albedo_color = Color(0.78, 0.62, 0.32)
		fuse.set_surface_override_material(0, f_mat)
		torso_pivot.add_child(fuse)


func _apply_hound_tracker_overlay(torso_pivot: Node3D, torso_size: Vector3) -> void:
	# Sensor dish mounted on the rear of the torso -- the Tracker is
	# the ranged spotter Hound, so a back-mounted dish + emissive
	# pickup reads at zoom.
	var mast := MeshInstance3D.new()
	var m_box := BoxMesh.new()
	m_box.size = Vector3(0.08, 0.55, 0.08)
	mast.mesh = m_box
	mast.position = Vector3(0.0, torso_size.y + 0.28, -torso_size.z * 0.40)
	mast.set_surface_override_material(0, _make_metal_mat(Color(0.18, 0.16, 0.14)))
	torso_pivot.add_child(mast)
	var dish := MeshInstance3D.new()
	var d_cyl := CylinderMesh.new()
	d_cyl.top_radius = 0.22
	d_cyl.bottom_radius = 0.22
	d_cyl.height = 0.05
	d_cyl.radial_segments = 18
	dish.mesh = d_cyl
	dish.rotation.x = deg_to_rad(-30.0)
	dish.position = Vector3(0.0, torso_size.y + 0.55, -torso_size.z * 0.40)
	var d_mat := StandardMaterial3D.new()
	d_mat.albedo_color = Color(0.20, 0.20, 0.22)
	d_mat.emission_enabled = true
	d_mat.emission = Color(0.30, 0.85, 1.0)
	d_mat.emission_energy_multiplier = 0.4
	dish.set_surface_override_material(0, d_mat)
	torso_pivot.add_child(dish)


func _apply_hound_base_overlay(member: Node3D, torso_pivot: Node3D, torso_size: Vector3, head_size: Vector3, base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Borzoi base — was using only the bare default mech build, which
	## read as a flat-textured "missing detail" silhouette compared to
	## Strelet/Bulwark which both got brass + sigil passes. This overlay
	## adds: brass shoulder pauldron caps, a multi-barrel autogun (so the
	## chest gun reads as autogun not single cannon), a back-mounted
	## missile pod for the salvo missile attack, and a small sensor mast.
	## Playtest 2026-05-15.
	const WEATHERED_BRASS: Color = Color(0.55, 0.42, 0.18, 1.0)
	# Multi-barrel autogun — replace the single chest cannon look by
	# adding TWO additional thinner barrels flanking the existing main
	# barrel. From front it reads as a tri-barrel autogun cluster.
	var cannon_pivot: Node3D = torso_pivot.get_node_or_null("CannonPivot_0") as Node3D
	if cannon_pivot:
		for side: int in 2:
			var sx: float = (-1.0 if side == 0 else 1.0) * 0.10
			var aux := MeshInstance3D.new()
			var ab_cyl := CylinderMesh.new()
			ab_cyl.top_radius = 0.035
			ab_cyl.bottom_radius = 0.035
			ab_cyl.height = 0.55
			ab_cyl.radial_segments = 8
			aux.mesh = ab_cyl
			aux.rotate_object_local(Vector3.RIGHT, PI * 0.5)
			aux.position = Vector3(sx, 0.04, -0.30)
			aux.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.10)))
			cannon_pivot.add_child(aux)
		# Brass cooling jacket midway down the main barrel.
		var jacket := MeshInstance3D.new()
		var jc := CylinderMesh.new()
		jc.top_radius = 0.085
		jc.bottom_radius = 0.085
		jc.height = 0.10
		jc.radial_segments = 12
		jacket.mesh = jc
		jacket.rotate_object_local(Vector3.RIGHT, PI * 0.5)
		jacket.position = Vector3(0.0, 0.0, -0.20)
		jacket.set_surface_override_material(0, _make_metal_mat(WEATHERED_BRASS))
		cannon_pivot.add_child(jacket)
	# Back-mounted missile pod — small angled box on the upper back with
	# four visible launch tubes facing up + slightly forward. Reads as
	# the salvo-missile launcher Borzoi uses for its anti-armor punch.
	var pod := MeshInstance3D.new()
	var pb := BoxMesh.new()
	pb.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.18, torso_size.z * 0.50)
	pod.mesh = pb
	pod.rotate_object_local(Vector3.RIGHT, deg_to_rad(-22.0))
	pod.position = Vector3(0.0, torso_size.y * 0.92, torso_size.z * 0.28)
	var pod_mat := _make_metal_mat(Color(0.16, 0.16, 0.18))
	pod.set_surface_override_material(0, pod_mat)
	torso_pivot.add_child(pod)
	mats.append(pod_mat)
	# Four launch tubes in a 2x2 array, angled up-forward to match the
	# pod tilt so missiles read as fired UP and OVER in a salvo.
	for tx_i: int in 2:
		for ty_i: int in 2:
			var tube := MeshInstance3D.new()
			var tc := CylinderMesh.new()
			tc.top_radius = 0.05
			tc.bottom_radius = 0.05
			tc.height = 0.20
			tc.radial_segments = 8
			tube.mesh = tc
			# Tubes face -Z then we tilt the whole pod via parent rotation.
			# Easier: just make them vertical, then rotate same as pod.
			tube.rotation = Vector3(deg_to_rad(-22.0), 0.0, 0.0)
			var off_x: float = (-1.0 if tx_i == 0 else 1.0) * torso_size.x * 0.16
			var off_z: float = (-1.0 if ty_i == 0 else 1.0) * 0.10
			tube.position = Vector3(off_x, torso_size.y * 1.04, torso_size.z * 0.30 + off_z)
			tube.set_surface_override_material(0, _make_metal_mat(Color(0.08, 0.08, 0.08)))
			torso_pivot.add_child(tube)
	# Brass shoulder pauldron caps — two small angled brass plates
	# capping the existing shoulder boxes so the silhouette has a
	# visible "Combine brass kit" identity.
	for shoulder_side: int in 2:
		var ssx: float = -1.0 if shoulder_side == 0 else 1.0
		var cap := MeshInstance3D.new()
		var cb := BoxMesh.new()
		cb.size = Vector3(torso_size.x * 0.30, 0.06, torso_size.z * 0.42)
		cap.mesh = cb
		cap.rotation.z = -ssx * deg_to_rad(8.0)
		cap.position = Vector3(ssx * torso_size.x * 0.40, torso_size.y * 0.78 + 0.06, 0.0)
		cap.set_surface_override_material(0, _make_metal_mat(WEATHERED_BRASS))
		torso_pivot.add_child(cap)
	# Small sensor mast on the head — short brass-tipped rod so the
	# Borzoi reads as a "scout" with optics rather than just a plain head.
	var mast := MeshInstance3D.new()
	var mc := CylinderMesh.new()
	mc.top_radius = 0.02
	mc.bottom_radius = 0.03
	mc.height = 0.18
	mc.radial_segments = 6
	mast.mesh = mc
	mast.position = Vector3(head_size.x * 0.28, torso_size.y + head_size.y + mc.height * 0.5, head_size.z * 0.25)
	mast.set_surface_override_material(0, _make_metal_mat(Color(0.14, 0.14, 0.14)))
	torso_pivot.add_child(mast)
	var mast_tip := MeshInstance3D.new()
	var mt_box := BoxMesh.new()
	mt_box.size = Vector3(0.05, 0.05, 0.05)
	mast_tip.mesh = mt_box
	mast_tip.position = Vector3(head_size.x * 0.28, torso_size.y + head_size.y + mc.height + 0.025, head_size.z * 0.25)
	mast_tip.set_surface_override_material(0, _make_metal_mat(WEATHERED_BRASS))
	torso_pivot.add_child(mast_tip)
	# Hammer-and-anvil chest sigil reuse — keeps the Borzoi within the
	# Combine brass-kit visual family.
	_apply_combine_hammer_anvil_sigil(member)


func _apply_hound_ripper_overlay(torso_pivot: Node3D, torso_size: Vector3) -> void:
	# Shoulder shotgun pod -- a chunky drum on the right shoulder
	# with three barrel mouths poking forward. Pairs with the
	# Ripper's shoulder shotgun array secondary weapon.
	var pod := MeshInstance3D.new()
	var pod_box := BoxMesh.new()
	pod_box.size = Vector3(0.32, 0.32, 0.42)
	pod.mesh = pod_box
	pod.position = Vector3(torso_size.x * 0.48, torso_size.y * 0.85, torso_size.z * 0.20)
	pod.set_surface_override_material(0, _make_metal_mat(Color(0.22, 0.18, 0.14)))
	torso_pivot.add_child(pod)
	# Three barrel mouths in a triangle on the front face.
	var barrel_offsets: Array[Vector2] = [
		Vector2(-0.08, 0.06), Vector2(0.08, 0.06), Vector2(0.0, -0.08),
	]
	for off: Vector2 in barrel_offsets:
		var barrel := MeshInstance3D.new()
		var b_cyl := CylinderMesh.new()
		b_cyl.top_radius = 0.05
		b_cyl.bottom_radius = 0.05
		b_cyl.height = 0.10
		b_cyl.radial_segments = 8
		barrel.mesh = b_cyl
		barrel.rotation.x = PI * 0.5
		barrel.position = Vector3(
			torso_size.x * 0.48 + off.x,
			torso_size.y * 0.85 + off.y,
			torso_size.z * 0.20 + 0.26,
		)
		barrel.set_surface_override_material(0, _make_metal_mat(Color(0.08, 0.08, 0.08)))
		torso_pivot.add_child(barrel)


func _apply_bulwark_ironwall_overlay(torso_pivot: Node3D, torso_size: Vector3) -> void:
	# Heavy-tank tier of Bulwark. Silhouette grows: angled shoulder
	# plates, a frontal bull-bar, hull skirt around the lower torso,
	# riveted spine ridge, and a small commander cupola so the unit
	# reads as 'siege-line tank' at zoom.
	var dark_steel: StandardMaterial3D = _make_metal_mat(Color(0.32, 0.28, 0.22))
	var bronze: StandardMaterial3D = _make_metal_mat(Color(0.55, 0.45, 0.18))
	var charcoal: StandardMaterial3D = _make_metal_mat(Color(0.16, 0.14, 0.12))
	# Reinforced shoulder plating + rivet strips.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var plate := MeshInstance3D.new()
		var p_box := BoxMesh.new()
		p_box.size = Vector3(0.55, 0.45, 0.55)
		plate.mesh = p_box
		plate.position = Vector3(sx * torso_size.x * 0.55, torso_size.y * 0.85, 0.0)
		plate.rotation.z = sx * deg_to_rad(-12.0)
		plate.set_surface_override_material(0, dark_steel)
		torso_pivot.add_child(plate)
		var rivet_strip := MeshInstance3D.new()
		var rs_box := BoxMesh.new()
		rs_box.size = Vector3(0.55, 0.06, 0.06)
		rivet_strip.mesh = rs_box
		rivet_strip.position = Vector3(sx * torso_size.x * 0.55, torso_size.y * 0.65, torso_size.z * 0.30)
		rivet_strip.rotation.z = sx * deg_to_rad(-12.0)
		rivet_strip.set_surface_override_material(0, bronze)
		torso_pivot.add_child(rivet_strip)
		# Side hull skirt -- a thick rectangular plate hanging down
		# alongside the lower torso so the silhouette widens at hip
		# height (tank stance).
		var skirt := MeshInstance3D.new()
		var sk_box := BoxMesh.new()
		sk_box.size = Vector3(0.14, torso_size.y * 0.55, torso_size.z * 0.92)
		skirt.mesh = sk_box
		skirt.position = Vector3(sx * (torso_size.x * 0.55 + 0.05), torso_size.y * 0.28, 0.0)
		skirt.set_surface_override_material(0, dark_steel)
		torso_pivot.add_child(skirt)
		# Three small side rivets on the skirt.
		for r: int in 3:
			var rivet := MeshInstance3D.new()
			var rv := SphereMesh.new()
			rv.radius = 0.045
			rv.height = 0.090
			rivet.mesh = rv
			rivet.position = Vector3(
				sx * (torso_size.x * 0.55 + 0.13),
				torso_size.y * (0.10 + 0.18 * float(r)),
				0.0
			)
			rivet.set_surface_override_material(0, bronze)
			torso_pivot.add_child(rivet)
	# Frontal bull-bar -- a thick angled bar that shields the lower
	# front of the chassis. Reads as 'made for ramming through
	# rubble'.
	var bar := MeshInstance3D.new()
	var bar_box := BoxMesh.new()
	bar_box.size = Vector3(torso_size.x * 1.30, 0.18, 0.22)
	bar.mesh = bar_box
	bar.position = Vector3(0.0, torso_size.y * 0.20, torso_size.z * 0.55)
	bar.rotation.x = deg_to_rad(-12.0)
	bar.set_surface_override_material(0, dark_steel)
	torso_pivot.add_child(bar)
	# Two vertical posts connecting the bar to the chassis.
	for side2: int in 2:
		var sx2: float = -1.0 if side2 == 0 else 1.0
		var post := MeshInstance3D.new()
		var po_box := BoxMesh.new()
		po_box.size = Vector3(0.10, 0.45, 0.10)
		post.mesh = po_box
		post.position = Vector3(sx2 * torso_size.x * 0.50, torso_size.y * 0.32, torso_size.z * 0.50)
		post.set_surface_override_material(0, charcoal)
		torso_pivot.add_child(post)
	# Spine ridge -- riveted bar running front-to-back along the
	# top of the chassis.
	var spine := MeshInstance3D.new()
	var sp_box := BoxMesh.new()
	sp_box.size = Vector3(0.16, 0.10, torso_size.z * 0.95)
	spine.mesh = sp_box
	spine.position = Vector3(0.0, torso_size.y * 1.04, 0.0)
	spine.set_surface_override_material(0, dark_steel)
	torso_pivot.add_child(spine)
	# Spine rivets.
	for r2: int in 5:
		var rivet2 := MeshInstance3D.new()
		var rv2 := SphereMesh.new()
		rv2.radius = 0.06
		rv2.height = 0.12
		rivet2.mesh = rv2
		rivet2.position = Vector3(
			0.0,
			torso_size.y * 1.10,
			torso_size.z * (-0.42 + 0.21 * float(r2))
		)
		rivet2.set_surface_override_material(0, bronze)
		torso_pivot.add_child(rivet2)
	# Commander cupola -- small dome on top toward the rear so the
	# unit reads as 'crewed heavy tank' rather than autonomous walker.
	var cupola := MeshInstance3D.new()
	var cu_cyl := CylinderMesh.new()
	cu_cyl.top_radius = 0.18
	cu_cyl.bottom_radius = 0.22
	cu_cyl.height = 0.18
	cu_cyl.radial_segments = 12
	cupola.mesh = cu_cyl
	cupola.position = Vector3(0.0, torso_size.y * 1.18, -torso_size.z * 0.30)
	cupola.set_surface_override_material(0, charcoal)
	torso_pivot.add_child(cupola)
	var hatch := MeshInstance3D.new()
	var ha_cyl := CylinderMesh.new()
	ha_cyl.top_radius = 0.14
	ha_cyl.bottom_radius = 0.14
	ha_cyl.height = 0.04
	ha_cyl.radial_segments = 10
	hatch.mesh = ha_cyl
	hatch.position = Vector3(0.0, torso_size.y * 1.30, -torso_size.z * 0.30)
	hatch.set_surface_override_material(0, dark_steel)
	torso_pivot.add_child(hatch)


func _apply_bulwark_siegebreaker_overlay(torso_pivot: Node3D, torso_size: Vector3) -> void:
	# Big anti-structure siege piece. Silhouette grows: long forward
	# barrel with chunky muzzle brake, breech block + recoil sled
	# mounted on the spine, side rangefinder pod, and a counterweight
	# crate on the rear so the chassis reads as 'load-bearing siege
	# rig' rather than just 'mech with an extra gun stuck on'.
	var dark_steel: StandardMaterial3D = _make_metal_mat(Color(0.18, 0.16, 0.14))
	var brake_mat: StandardMaterial3D = _make_metal_mat(Color(0.10, 0.09, 0.08))
	var bronze: StandardMaterial3D = _make_metal_mat(Color(0.55, 0.45, 0.18))
	# Long siege barrel mounted along the spine.
	var barrel := MeshInstance3D.new()
	var b_cyl := CylinderMesh.new()
	b_cyl.top_radius = 0.14
	b_cyl.bottom_radius = 0.18
	b_cyl.height = 1.40
	b_cyl.radial_segments = 14
	barrel.mesh = b_cyl
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0.0, torso_size.y * 0.65, torso_size.z * 0.55)
	barrel.set_surface_override_material(0, dark_steel)
	torso_pivot.add_child(barrel)
	# Muzzle brake -- chunky ring at the barrel tip.
	var brake := MeshInstance3D.new()
	var br_cyl := CylinderMesh.new()
	br_cyl.top_radius = 0.22
	br_cyl.bottom_radius = 0.22
	br_cyl.height = 0.16
	br_cyl.radial_segments = 12
	brake.mesh = br_cyl
	brake.rotation.x = PI * 0.5
	brake.position = Vector3(0.0, torso_size.y * 0.65, torso_size.z * 0.55 + 0.78)
	brake.set_surface_override_material(0, brake_mat)
	torso_pivot.add_child(brake)
	# Muzzle brake side vents (3 per side).
	for vside: int in 2:
		var vsx: float = -1.0 if vside == 0 else 1.0
		for v: int in 3:
			var vent := MeshInstance3D.new()
			var ve_box := BoxMesh.new()
			ve_box.size = Vector3(0.04, 0.10, 0.025)
			vent.mesh = ve_box
			vent.position = Vector3(
				vsx * 0.18,
				torso_size.y * 0.65,
				torso_size.z * 0.55 + 0.72 + 0.04 * float(v)
			)
			vent.set_surface_override_material(0, brake_mat)
			torso_pivot.add_child(vent)
	# Breech block -- a chunky box where the barrel meets the chassis.
	var breech := MeshInstance3D.new()
	var be_box := BoxMesh.new()
	be_box.size = Vector3(0.45, 0.42, 0.55)
	breech.mesh = be_box
	breech.position = Vector3(0.0, torso_size.y * 0.65, torso_size.z * 0.20)
	breech.set_surface_override_material(0, dark_steel)
	torso_pivot.add_child(breech)
	# Recoil sled -- two parallel rails running back from the breech
	# along the spine.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var rail := MeshInstance3D.new()
		var ra_box := BoxMesh.new()
		ra_box.size = Vector3(0.06, 0.08, 0.65)
		rail.mesh = ra_box
		rail.position = Vector3(sx * 0.18, torso_size.y * 0.50, -torso_size.z * 0.10)
		rail.set_surface_override_material(0, brake_mat)
		torso_pivot.add_child(rail)
	# Side rangefinder pod -- a small cylindrical pod on the right
	# shoulder with a small emissive aperture aimed forward.
	var pod := MeshInstance3D.new()
	var po_cyl := CylinderMesh.new()
	po_cyl.top_radius = 0.10
	po_cyl.bottom_radius = 0.10
	po_cyl.height = 0.30
	po_cyl.radial_segments = 10
	pod.mesh = po_cyl
	pod.rotation.x = PI * 0.5
	pod.position = Vector3(torso_size.x * 0.55, torso_size.y * 0.92, torso_size.z * 0.30)
	pod.set_surface_override_material(0, dark_steel)
	torso_pivot.add_child(pod)
	var aperture := MeshInstance3D.new()
	var ap := SphereMesh.new()
	ap.radius = 0.05
	ap.height = 0.10
	aperture.mesh = ap
	aperture.position = Vector3(torso_size.x * 0.55, torso_size.y * 0.92, torso_size.z * 0.30 + 0.16)
	var ap_mat := StandardMaterial3D.new()
	ap_mat.albedo_color = Color(1.0, 0.80, 0.30)
	ap_mat.emission_enabled = true
	ap_mat.emission = Color(1.0, 0.80, 0.30)
	ap_mat.emission_energy_multiplier = 1.6
	aperture.set_surface_override_material(0, ap_mat)
	torso_pivot.add_child(aperture)
	# Counterweight crate on the rear -- shifts visual weight back so
	# the long forward barrel doesn't feel front-heavy.
	var crate := MeshInstance3D.new()
	var cr_box := BoxMesh.new()
	cr_box.size = Vector3(0.55, 0.35, 0.30)
	crate.mesh = cr_box
	crate.position = Vector3(0.0, torso_size.y * 0.45, -torso_size.z * 0.55)
	crate.set_surface_override_material(0, dark_steel)
	torso_pivot.add_child(crate)
	# Crate handle/strap.
	var strap := MeshInstance3D.new()
	var st_box := BoxMesh.new()
	st_box.size = Vector3(0.05, 0.10, 0.32)
	strap.mesh = st_box
	strap.position = Vector3(0.0, torso_size.y * 0.62, -torso_size.z * 0.55)
	strap.set_surface_override_material(0, bronze)
	torso_pivot.add_child(strap)


func _apply_cremator_base_overlay(torso_pivot: Node3D, torso_size: Vector3, _base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Heliarch medium mainline — Heavy Flamethrower + Phosphorus
	## Mortar. Squat chest furnace, short stubby flamethrower nozzle on
	## the LEFT chest (wide flared tip — reads as a flame projector,
	## not a lance), shoulder-mounted mortar tube angled upward on the
	## RIGHT, and a hanging brass ceremonial chain.
	## Replaces the previous tall forward-projected lance which read as
	## off-balance / goofy and didn't match the spec'd loadout (Lancer
	## is a BRANCH, not the base unit).
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const HEAT_WHITE_HOT: Color = Color(1.0, 0.85, 0.55, 1.0)
	const HELIARCH_BRASS: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.14, 1.0)
	# --- Chest furnace plate (back of torso). Sooted-iron housing.
	var furnace_back := MeshInstance3D.new()
	var fb := BoxMesh.new()
	fb.size = Vector3(torso_size.x * 0.72, torso_size.y * 0.55, 0.08)
	furnace_back.mesh = fb
	furnace_back.position = Vector3(0.0, torso_size.y * 0.46, -torso_size.z * 0.5 - 0.06)
	furnace_back.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	torso_pivot.add_child(furnace_back)
	# Hot reactor amber plate.
	var furnace_glow := MeshInstance3D.new()
	var fg := BoxMesh.new()
	fg.size = Vector3(torso_size.x * 0.62, torso_size.y * 0.45, 0.04)
	furnace_glow.mesh = fg
	furnace_glow.position = Vector3(0.0, torso_size.y * 0.46, -torso_size.z * 0.5 - 0.10)
	var fg_mat := StandardMaterial3D.new()
	fg_mat.albedo_color = REACTOR_AMBER
	fg_mat.emission_enabled = true
	fg_mat.emission = REACTOR_AMBER
	fg_mat.emission_energy_multiplier = 3.2
	fg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	furnace_glow.set_surface_override_material(0, fg_mat)
	torso_pivot.add_child(furnace_glow)
	mats.append(fg_mat)
	# Five brass grille bars across the furnace.
	for grille_i: int in 5:
		var bar := MeshInstance3D.new()
		var bar_box := BoxMesh.new()
		bar_box.size = Vector3(torso_size.x * 0.66, 0.05, 0.06)
		bar.mesh = bar_box
		var ry: float = torso_size.y * 0.20 + float(grille_i) * torso_size.y * 0.13
		bar.position = Vector3(0.0, ry, -torso_size.z * 0.5 - 0.13)
		bar.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		torso_pivot.add_child(bar)
	# Furnace omni light.
	var furnace_light := OmniLight3D.new()
	furnace_light.light_color = REACTOR_AMBER
	furnace_light.light_energy = 1.0
	furnace_light.omni_range = torso_size.x * 2.4
	furnace_light.position = Vector3(0.0, torso_size.y * 0.46, -torso_size.z * 0.5 - 0.10)
	torso_pivot.add_child(furnace_light)

	# --- Forward floodlight on the RIGHT chest — the Heliarch lamp
	# motif, mirroring Stoker / Inquisitor / Conquistador. Small enough
	# that it sits alongside the flamethrower nozzle without competing
	# for silhouette dominance. Warm amber-white emissive disc inside
	# a brass housing.
	const FLOOD_WARM_CREM: Color = Color(1.0, 0.78, 0.42, 1.0)
	var flood_root := Node3D.new()
	flood_root.position = Vector3(torso_size.x * 0.32, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.05)
	torso_pivot.add_child(flood_root)
	var flood_housing := MeshInstance3D.new()
	var fhouse := CylinderMesh.new()
	fhouse.top_radius = 0.13
	fhouse.bottom_radius = 0.11
	fhouse.height = 0.14
	fhouse.radial_segments = 12
	flood_housing.mesh = fhouse
	flood_housing.rotation.x = PI * 0.5
	flood_housing.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	flood_root.add_child(flood_housing)
	var flood_bulb := MeshInstance3D.new()
	var fbulb := CylinderMesh.new()
	fbulb.top_radius = 0.09
	fbulb.bottom_radius = 0.09
	fbulb.height = 0.03
	fbulb.radial_segments = 12
	flood_bulb.mesh = fbulb
	flood_bulb.rotation.x = PI * 0.5
	flood_bulb.position = Vector3(0.0, 0.0, -0.08)
	var fb_mat := StandardMaterial3D.new()
	fb_mat.albedo_color = FLOOD_WARM_CREM
	fb_mat.emission_enabled = true
	fb_mat.emission = FLOOD_WARM_CREM
	fb_mat.emission_energy_multiplier = 3.2
	fb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flood_bulb.set_surface_override_material(0, fb_mat)
	flood_root.add_child(flood_bulb)
	mats.append(fb_mat)
	# Small omni so the lamp visibly casts on nearby geometry.
	var flood_light := OmniLight3D.new()
	flood_light.light_color = FLOOD_WARM_CREM
	flood_light.light_energy = 0.45
	flood_light.omni_range = 3.5
	flood_light.position = Vector3(0.0, 0.0, -0.14)
	flood_root.add_child(flood_light)

	# --- Heavy Flamethrower nozzle on the LEFT chest. Short stubby
	# barrel with a flared cone tip (the wide aperture reads as a
	# flame projector, not a precision weapon).
	# Mounted further off-centre (LEFT-side hip-shoulder) so it reads as
	# a side-arm and the silhouette stays asymmetrical (per playtest
	# 2026-05-18: "should be attached a bit more to the side instead of
	# center"). Rotated slightly inward toward the centerline so the
	# nozzle still points forward despite the side mounting.
	var flamer_root := Node3D.new()
	flamer_root.name = "CremnatorFlamer"
	flamer_root.position = Vector3(-torso_size.x * 0.62, torso_size.y * 0.45, -torso_size.z * 0.35)
	flamer_root.rotation.y = deg_to_rad(12.0)  # nozzle angles inward to forward
	torso_pivot.add_child(flamer_root)
	# Sooted housing — squarer and a touch larger to give the side-mount
	# more visual weight.
	var flamer_housing := MeshInstance3D.new()
	var fh := BoxMesh.new()
	fh.size = Vector3(0.30, 0.30, 0.34)
	flamer_housing.mesh = fh
	flamer_housing.position = Vector3(0.0, 0.0, -0.05)
	flamer_housing.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	flamer_root.add_child(flamer_housing)
	# Longer thicker brass barrel — was 0.45 / very stubby (read as a
	# mushroom). Now 0.65 with a more pronounced taper so the silhouette
	# reads as a directed flame projector, not a vent cap.
	var flamer_barrel_len: float = 0.65
	var flamer_barrel := MeshInstance3D.new()
	var fbl := CylinderMesh.new()
	fbl.top_radius = 0.08
	fbl.bottom_radius = 0.11
	fbl.height = flamer_barrel_len
	fbl.radial_segments = 12
	flamer_barrel.mesh = fbl
	flamer_barrel.rotation.x = PI * 0.5
	flamer_barrel.position = Vector3(0.0, 0.0, -flamer_barrel_len * 0.5 - 0.20)
	flamer_barrel.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	flamer_root.add_child(flamer_barrel)
	# Two brass cooling rings along the barrel — visible bulkhead beats
	# the mushroom-cone read.
	for ring_i: int in 2:
		var cring := MeshInstance3D.new()
		var crt := TorusMesh.new()
		crt.inner_radius = 0.10
		crt.outer_radius = 0.14
		crt.rings = 10
		crt.ring_segments = 4
		cring.mesh = crt
		cring.rotation.x = PI * 0.5
		cring.position = Vector3(0.0, 0.0, -0.35 - float(ring_i) * 0.20)
		cring.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		flamer_root.add_child(cring)
	# Compact muzzle nozzle — narrow opening, not the previous wide flared
	# cone (the flare made it look like a mushroom cap).
	var flamer_muzzle_ring := MeshInstance3D.new()
	var fmr := TorusMesh.new()
	fmr.inner_radius = 0.08
	fmr.outer_radius = 0.12
	fmr.rings = 10
	fmr.ring_segments = 4
	flamer_muzzle_ring.mesh = fmr
	flamer_muzzle_ring.rotation.x = PI * 0.5
	flamer_muzzle_ring.position = Vector3(0.0, 0.0, -flamer_barrel_len - 0.22)
	flamer_muzzle_ring.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	flamer_root.add_child(flamer_muzzle_ring)
	# Pilot-light glow at the nozzle — small, kept the visible "lit"
	# read but no longer the visual mushroom-cap.
	var pilot_glow := MeshInstance3D.new()
	var pg := SphereMesh.new()
	pg.radius = 0.06
	pg.height = 0.12
	pilot_glow.mesh = pg
	pilot_glow.position = Vector3(0.0, 0.0, -flamer_barrel_len - 0.22)
	var pg_mat := StandardMaterial3D.new()
	pg_mat.albedo_color = HEAT_WHITE_HOT
	pg_mat.emission_enabled = true
	pg_mat.emission = HEAT_WHITE_HOT
	pg_mat.emission_energy_multiplier = 2.4
	pg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pilot_glow.set_surface_override_material(0, pg_mat)
	flamer_root.add_child(pilot_glow)
	mats.append(pg_mat)
	# Muzzle marker — at the nozzle aperture. Tagged FlamerMuzzle so the
	# combat side's per-weapon muzzle resolver (see
	# get_muzzle_positions_for_weapon) can fire the flame stream from the
	# actual flamethrower nozzle instead of the unit's chest centre.
	var muzzle_mk := Marker3D.new()
	muzzle_mk.name = "FlamerMuzzle"
	muzzle_mk.position = Vector3(0.0, 0.0, -flamer_barrel_len - 0.30)
	flamer_root.add_child(muzzle_mk)
	# Backpack fuel cylinder feeding the flamer (small cylinder on the
	# back-left of the torso). Sells "this thing burns chemical fuel".
	var fuel_tank := MeshInstance3D.new()
	var ft := CylinderMesh.new()
	ft.top_radius = 0.13
	ft.bottom_radius = 0.13
	ft.height = 0.55
	ft.radial_segments = 10
	fuel_tank.mesh = ft
	fuel_tank.position = Vector3(-torso_size.x * 0.30, torso_size.y * 0.55, torso_size.z * 0.42)
	fuel_tank.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	torso_pivot.add_child(fuel_tank)

	# --- Heavy armor plating. Bolted-on chest + side slab plates
	# sell the "armored religious soldier" silhouette and visually
	# justify the Medium armor class. Plates are deliberately thick
	# and proud of the chassis so they read at RTS zoom.
	# Front chest plate — wide slab covering most of the torso front.
	var chest_plate := MeshInstance3D.new()
	var cp_box := BoxMesh.new()
	cp_box.size = Vector3(torso_size.x * 0.85, torso_size.y * 0.62, 0.10)
	chest_plate.mesh = cp_box
	chest_plate.position = Vector3(0.0, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.02)
	chest_plate.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	torso_pivot.add_child(chest_plate)
	# Brass rivet rows along the chest plate edge — 4 rivets per side.
	for rivet_side: int in 2:
		var rsx: float = -1.0 if rivet_side == 0 else 1.0
		for rivet_i: int in 4:
			var rivet := MeshInstance3D.new()
			var rs := SphereMesh.new()
			rs.radius = 0.04
			rs.height = 0.08
			rivet.mesh = rs
			var ry: float = torso_size.y * 0.30 + float(rivet_i) * torso_size.y * 0.16
			var rx: float = rsx * (torso_size.x * 0.36)
			rivet.position = Vector3(rx, ry, -torso_size.z * 0.5 - 0.10)
			rivet.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
			torso_pivot.add_child(rivet)
	# Side armor pauldrons — flared shoulder slabs angled outward.
	for pauldron_side: int in 2:
		var psx: float = -1.0 if pauldron_side == 0 else 1.0
		var pauldron := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.22, torso_size.y * 0.40, torso_size.z * 0.65)
		pauldron.mesh = pb
		pauldron.position = Vector3(psx * (torso_size.x * 0.55 + 0.05), torso_size.y * 0.85, 0.0)
		pauldron.rotation.z = psx * deg_to_rad(8.0)
		pauldron.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		torso_pivot.add_child(pauldron)
		# Brass trim along the pauldron's outer edge.
		var trim := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(0.06, torso_size.y * 0.40, 0.05)
		trim.mesh = tb
		trim.position = Vector3(psx * (torso_size.x * 0.55 + 0.16), torso_size.y * 0.85, torso_size.z * 0.30)
		trim.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		torso_pivot.add_child(trim)
	# Hip skirt plates — angled slabs covering the upper legs/hip.
	for hip_side: int in 2:
		var hsx: float = -1.0 if hip_side == 0 else 1.0
		var hip := MeshInstance3D.new()
		var hb := BoxMesh.new()
		hb.size = Vector3(torso_size.x * 0.42, 0.32, 0.10)
		hip.mesh = hb
		hip.position = Vector3(hsx * torso_size.x * 0.22, torso_size.y * 0.10, -torso_size.z * 0.5 - 0.02)
		hip.rotation.z = hsx * deg_to_rad(14.0)
		hip.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		torso_pivot.add_child(hip)

	# --- Phosphorus Mortar tube mounted on the BACK, angled steeply
	# upward. Sits high on the rear chassis so the silhouette reads
	# 'shoulder-launcher of mortar shells over the head'. Replaces
	# the previous right-shoulder mount per playtest 2026-05-16
	# ("mortar attached to his back").
	var mortar_root := Node3D.new()
	mortar_root.name = "CremnatorMortar"
	mortar_root.position = Vector3(0.0, torso_size.y * 1.05, torso_size.z * 0.5 + 0.08)
	mortar_root.rotation.x = -deg_to_rad(58.0)  # steep upward arc launch
	torso_pivot.add_child(mortar_root)
	# Mortar tube.
	var mortar_len: float = 0.95
	var mortar_tube := MeshInstance3D.new()
	var mt_cyl := CylinderMesh.new()
	mt_cyl.top_radius = 0.14
	mt_cyl.bottom_radius = 0.16
	mt_cyl.height = mortar_len
	mt_cyl.radial_segments = 12
	mortar_tube.mesh = mt_cyl
	mortar_tube.rotation.x = PI * 0.5
	mortar_tube.position = Vector3(0.0, 0.0, -mortar_len * 0.5)
	mortar_tube.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	mortar_root.add_child(mortar_tube)
	# Backplate / mounting block — sells "bolted to the back".
	var mortar_mount := MeshInstance3D.new()
	var mm := BoxMesh.new()
	mm.size = Vector3(0.40, 0.25, 0.20)
	mortar_mount.mesh = mm
	mortar_mount.position = Vector3(0.0, 0.05, 0.10)
	mortar_mount.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	mortar_root.add_child(mortar_mount)
	# Brass cooling rings around the tube.
	for ring_i: int in 2:
		var ring := MeshInstance3D.new()
		var rt := TorusMesh.new()
		rt.inner_radius = 0.16
		rt.outer_radius = 0.21
		rt.rings = 12
		rt.ring_segments = 6
		ring.mesh = rt
		ring.rotation.x = PI * 0.5
		ring.position = Vector3(0.0, 0.0, -0.30 - float(ring_i) * 0.30)
		ring.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		mortar_root.add_child(ring)
	# Brass muzzle ring at the mortar tube tip.
	var mortar_ring := MeshInstance3D.new()
	var mr := TorusMesh.new()
	mr.inner_radius = 0.16
	mr.outer_radius = 0.21
	mr.rings = 12
	mr.ring_segments = 6
	mortar_ring.mesh = mr
	mortar_ring.rotation.x = PI * 0.5
	mortar_ring.position = Vector3(0.0, 0.0, -mortar_len - 0.05)
	mortar_ring.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	mortar_root.add_child(mortar_ring)

	# --- Brass ceremonial chain drape on the RIGHT hip — short.
	# Less of a feature now that the back is busy with the mortar.
	var chain_root := Node3D.new()
	chain_root.position = Vector3(torso_size.x * 0.50, torso_size.y * 0.40, 0.0)
	torso_pivot.add_child(chain_root)
	for link_i: int in 4:
		var link := MeshInstance3D.new()
		var ls := SphereMesh.new()
		ls.radius = 0.05
		ls.height = 0.10
		link.mesh = ls
		var t: float = float(link_i) / 3.0
		var arc_x: float = t * 0.06
		var arc_y: float = -t * t * 0.40
		link.position = Vector3(arc_x, arc_y, 0.0)
		link.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		chain_root.add_child(link)
	# Heliarch miner helmet with central forward floodlight — shared
	# faction-flavour piece (also on Matador). Sells the industrial
	# work-crew silhouette.
	_apply_heliarch_miner_helmet(torso_pivot, torso_size, mats)


func _apply_inquisitor_tank_base_overlay(torso_pivot: Node3D, torso_size: Vector3, _base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Heliarch medium hover tank. Squat angular hull (extra-low chassis
	## silhouette via flatter side plates), a centred plasma-cannon turret
	## with a long forward barrel + emissive plasma bulb at the muzzle,
	## an auxiliary flamer nozzle on the front-left chest, and twin
	## brass thruster vents on the rear to sell the "hover" identity.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const PLASMA_BLUE: Color = Color(0.55, 0.75, 1.00, 1.0)
	const HELIARCH_BRASS: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.14, 1.0)
	# --- Low side skirts (sells the hover-tank low silhouette).
	for skirt_side: int in 2:
		var ssx: float = -1.0 if skirt_side == 0 else 1.0
		var skirt := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.18, torso_size.y * 0.28, torso_size.z * 0.95)
		skirt.mesh = sb
		skirt.position = Vector3(ssx * (torso_size.x * 0.55 + 0.05), torso_size.y * 0.20, 0.0)
		skirt.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		torso_pivot.add_child(skirt)
	# --- Plasma turret housing on top centre.
	var turret_pivot := Node3D.new()
	turret_pivot.name = "TurretPivot"
	turret_pivot.position = Vector3(0.0, torso_size.y * 1.05, 0.0)
	torso_pivot.add_child(turret_pivot)
	var turret_base := MeshInstance3D.new()
	var tb := CylinderMesh.new()
	tb.top_radius = torso_size.x * 0.28
	tb.bottom_radius = torso_size.x * 0.34
	tb.height = 0.18
	tb.radial_segments = 12
	turret_base.mesh = tb
	turret_base.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	turret_pivot.add_child(turret_base)
	# Cannon mantlet.
	var mantlet := MeshInstance3D.new()
	var mb := BoxMesh.new()
	mb.size = Vector3(0.32, 0.22, 0.32)
	mantlet.mesh = mb
	mantlet.position = Vector3(0.0, 0.10, -0.10)
	mantlet.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	turret_pivot.add_child(mantlet)
	# Long plasma barrel.
	var barrel_len: float = 1.20
	var barrel := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.10
	bc.bottom_radius = 0.13
	bc.height = barrel_len
	bc.radial_segments = 14
	barrel.mesh = bc
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0.0, 0.10, -barrel_len * 0.5 - 0.25)
	barrel.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	turret_pivot.add_child(barrel)
	# Plasma bulb at muzzle — bright blue emissive.
	var bulb := MeshInstance3D.new()
	var bs := SphereMesh.new()
	bs.radius = 0.13
	bs.height = 0.26
	bulb.mesh = bs
	bulb.position = Vector3(0.0, 0.10, -barrel_len - 0.25)
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = PLASMA_BLUE
	bulb_mat.emission_enabled = true
	bulb_mat.emission = PLASMA_BLUE
	bulb_mat.emission_energy_multiplier = 3.0
	bulb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bulb.set_surface_override_material(0, bulb_mat)
	turret_pivot.add_child(bulb)
	mats.append(bulb_mat)
	# Muzzle marker.
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, 0.10, -barrel_len - 0.36)
	turret_pivot.add_child(muzzle)
	# --- Twin rear thrusters — short cylinders with amber glow.
	for thr_side: int in 2:
		var tsx: float = -1.0 if thr_side == 0 else 1.0
		var thruster := MeshInstance3D.new()
		var tc := CylinderMesh.new()
		tc.top_radius = 0.10
		tc.bottom_radius = 0.13
		tc.height = 0.22
		tc.radial_segments = 10
		thruster.mesh = tc
		thruster.rotation.x = PI * 0.5
		thruster.position = Vector3(tsx * torso_size.x * 0.32, torso_size.y * 0.40, torso_size.z * 0.5 + 0.12)
		thruster.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		torso_pivot.add_child(thruster)
		# Inner glow disc.
		var glow := MeshInstance3D.new()
		var gd := CylinderMesh.new()
		gd.top_radius = 0.09
		gd.bottom_radius = 0.09
		gd.height = 0.03
		gd.radial_segments = 10
		glow.mesh = gd
		glow.rotation.x = PI * 0.5
		glow.position = Vector3(tsx * torso_size.x * 0.32, torso_size.y * 0.40, torso_size.z * 0.5 + 0.24)
		var glow_mat := StandardMaterial3D.new()
		glow_mat.albedo_color = REACTOR_AMBER
		glow_mat.emission_enabled = true
		glow_mat.emission = REACTOR_AMBER
		glow_mat.emission_energy_multiplier = 2.4
		glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.set_surface_override_material(0, glow_mat)
		torso_pivot.add_child(glow)
		mats.append(glow_mat)


func _apply_conquistador_base_overlay(torso_pivot: Node3D, torso_size: Vector3, _base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Heliarch heavy brawler. Bulky chassis with massive shoulder pauldrons,
	## a huge two-handed Heat Hammer held diagonally across the body, twin
	## shoulder-mounted plasma cannons firing forward over the head, and a
	## chest-furnace exhaust crown. Reads as "armored religious soldier
	## carrying a giant hammer."
	const HEAT_WHITE_HOT: Color = Color(1.0, 0.85, 0.55, 1.0)
	const PLASMA_BLUE: Color = Color(0.55, 0.75, 1.00, 1.0)
	const HELIARCH_BRASS: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.14, 1.0)
	# --- Massive shoulder pauldrons (much bigger than Cremator's).
	for pauldron_side: int in 2:
		var psx: float = -1.0 if pauldron_side == 0 else 1.0
		var pauldron := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.42, torso_size.y * 0.55, torso_size.z * 0.95)
		pauldron.mesh = pb
		pauldron.position = Vector3(psx * (torso_size.x * 0.55 + 0.10), torso_size.y * 0.90, 0.0)
		pauldron.rotation.z = psx * deg_to_rad(12.0)
		pauldron.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		torso_pivot.add_child(pauldron)
		# Brass rim along the front edge.
		var rim := MeshInstance3D.new()
		var rb := BoxMesh.new()
		rb.size = Vector3(0.46, 0.08, 0.30)
		rim.mesh = rb
		rim.position = Vector3(psx * (torso_size.x * 0.55 + 0.10), torso_size.y * 0.90 + torso_size.y * 0.28, -torso_size.z * 0.40)
		rim.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		torso_pivot.add_child(rim)
	# --- Two-handed Heat Hammer — the unit's primary identity. Built
	# OVERSIZED so it dominates the silhouette and the unit reads as
	# a melee bruiser. Haft is longer + thicker, head is a massive
	# anvil-like block with a wide hot face. Carried diagonally across
	# the chest from lower-left up to over the right shoulder
	# (warrior's "ready-to-swing" pose, not parade-rest).
	var hammer_root := Node3D.new()
	hammer_root.name = "ConquistadorHammer"
	hammer_root.position = Vector3(-torso_size.x * 0.18, torso_size.y * 0.50, -torso_size.z * 0.5 - 0.20)
	hammer_root.rotation.z = deg_to_rad(48.0)
	# Tag as melee pivot. The Conquistador swings the hammer overhead
	# (rotation.z arc) rather than thrusting forward, so the swing
	# tween uses the Z axis for this unit's pivot.
	hammer_root.add_to_group("melee_pivots")
	hammer_root.set_meta("melee_rest_rot", hammer_root.rotation)
	hammer_root.set_meta("melee_swing_axis", "z")
	torso_pivot.add_child(hammer_root)
	# Haft — longer + thicker so the hammer feels weighty.
	var haft_len: float = 2.00
	var haft := MeshInstance3D.new()
	var hc := CylinderMesh.new()
	hc.top_radius = 0.11
	hc.bottom_radius = 0.11
	hc.height = haft_len
	hc.radial_segments = 12
	haft.mesh = hc
	haft.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	hammer_root.add_child(haft)
	# Brass grip wrap near the lower hand.
	var grip_wrap := MeshInstance3D.new()
	var gw := CylinderMesh.new()
	gw.top_radius = 0.14
	gw.bottom_radius = 0.14
	gw.height = 0.32
	gw.radial_segments = 10
	grip_wrap.mesh = gw
	grip_wrap.position = Vector3(0.0, -haft_len * 0.40, 0.0)
	grip_wrap.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	hammer_root.add_child(grip_wrap)
	# Hammer head — massive anvil block, much bigger than before.
	var head := MeshInstance3D.new()
	var head_box := BoxMesh.new()
	head_box.size = Vector3(0.90, 0.65, 0.52)
	head.mesh = head_box
	head.position = Vector3(0.0, haft_len * 0.5 + 0.25, 0.0)
	head.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	hammer_root.add_child(head)
	# Brass collar where head meets haft.
	var collar := MeshInstance3D.new()
	var col_box := BoxMesh.new()
	col_box.size = Vector3(0.40, 0.18, 0.40)
	collar.mesh = col_box
	collar.position = Vector3(0.0, haft_len * 0.5 + 0.05, 0.0)
	collar.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	hammer_root.add_child(collar)
	# Hot face on the hammer head — large emissive plate (the striking
	# face). Bright orange-white so it reads as superheated.
	var hot_face := MeshInstance3D.new()
	var hf := BoxMesh.new()
	hf.size = Vector3(0.84, 0.58, 0.06)
	hot_face.mesh = hf
	hot_face.position = Vector3(0.0, haft_len * 0.5 + 0.25, -0.28)
	var hot_mat := StandardMaterial3D.new()
	hot_mat.albedo_color = HEAT_WHITE_HOT
	hot_mat.emission_enabled = true
	hot_mat.emission = Color(1.0, 0.55, 0.18, 1.0)
	hot_mat.emission_energy_multiplier = 3.0
	hot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot_face.set_surface_override_material(0, hot_mat)
	hammer_root.add_child(hot_face)
	mats.append(hot_mat)
	# Muzzle marker at the hammer head — melee swing VFX spawns here.
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, haft_len * 0.5 + 0.55, 0.0)
	hammer_root.add_child(muzzle)
	# --- Twin shoulder plasma cannons — small and tucked, since
	# they're purely the secondary (passive auto-fire support while
	# closing). Reduced from a prominent feature to discreet greebles
	# so they don't compete with the hammer for silhouette dominance.
	for cannon_side: int in 2:
		var csx: float = -1.0 if cannon_side == 0 else 1.0
		var cannon := MeshInstance3D.new()
		var cc := CylinderMesh.new()
		cc.top_radius = 0.045
		cc.bottom_radius = 0.055
		cc.height = 0.40
		cc.radial_segments = 8
		cannon.mesh = cc
		cannon.rotation.x = PI * 0.5
		cannon.position = Vector3(csx * torso_size.x * 0.55, torso_size.y * 1.05, -torso_size.z * 0.20)
		cannon.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		torso_pivot.add_child(cannon)
		# Smaller blue bulb tip.
		var c_bulb := MeshInstance3D.new()
		var cb := SphereMesh.new()
		cb.radius = 0.05
		cb.height = 0.10
		c_bulb.mesh = cb
		c_bulb.position = Vector3(csx * torso_size.x * 0.55, torso_size.y * 1.05, -torso_size.z * 0.20 - 0.28)
		var cb_mat := StandardMaterial3D.new()
		cb_mat.albedo_color = PLASMA_BLUE
		cb_mat.emission_enabled = true
		cb_mat.emission = PLASMA_BLUE
		cb_mat.emission_energy_multiplier = 2.0
		cb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		c_bulb.set_surface_override_material(0, cb_mat)
		torso_pivot.add_child(c_bulb)
		mats.append(cb_mat)


func _apply_matador_base_overlay(torso_pivot: Node3D, torso_size: Vector3, _base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Heliarch light harasser. Signature: tall exposed reactor core on
	## the back ("vertical glowing slot through ribbed grilles") +
	## front-mounted multi-tube incendiary cluster launcher replacing
	## the missing shoulder cannons. Brass front sigil for ritual flair.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const HELIARCH_BRASS: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.14, 1.0)
	# --- Exposed reactor core on the SPINE (back). Tall vertical
	# slab with a glowing inner slot framed by 3 ribbed grille bars.
	var core_housing := MeshInstance3D.new()
	var ch_box := BoxMesh.new()
	ch_box.size = Vector3(torso_size.x * 0.42, torso_size.y * 0.85, 0.10)
	core_housing.mesh = ch_box
	core_housing.position = Vector3(0.0, torso_size.y * 0.50, torso_size.z * 0.5 + 0.06)
	core_housing.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	torso_pivot.add_child(core_housing)
	# Reactor glow slot — emissive amber plate inset into the housing.
	var core_glow := MeshInstance3D.new()
	var cg_box := BoxMesh.new()
	cg_box.size = Vector3(torso_size.x * 0.30, torso_size.y * 0.70, 0.04)
	core_glow.mesh = cg_box
	core_glow.position = Vector3(0.0, torso_size.y * 0.50, torso_size.z * 0.5 + 0.11)
	var core_glow_mat := StandardMaterial3D.new()
	core_glow_mat.albedo_color = REACTOR_AMBER
	core_glow_mat.emission_enabled = true
	core_glow_mat.emission = REACTOR_AMBER
	core_glow_mat.emission_energy_multiplier = 2.8
	core_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_glow.set_surface_override_material(0, core_glow_mat)
	torso_pivot.add_child(core_glow)
	mats.append(core_glow_mat)
	# Three ribbed grille bars across the slot.
	for grille_i: int in 3:
		var bar := MeshInstance3D.new()
		var bar_box := BoxMesh.new()
		bar_box.size = Vector3(torso_size.x * 0.36, 0.05, 0.06)
		bar.mesh = bar_box
		var ry: float = torso_size.y * 0.25 + float(grille_i) * torso_size.y * 0.25
		bar.position = Vector3(0.0, ry, torso_size.z * 0.5 + 0.14)
		bar.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		torso_pivot.add_child(bar)
	# Reactor omni light so the core casts amber light on the surrounding chassis.
	var core_light := OmniLight3D.new()
	core_light.light_color = REACTOR_AMBER
	core_light.light_energy = 0.55
	core_light.omni_range = torso_size.x * 1.8
	core_light.position = Vector3(0.0, torso_size.y * 0.50, torso_size.z * 0.5 + 0.10)
	torso_pivot.add_child(core_light)
	# --- Dual Flame Daggers (one each side) — twin blades held in a
	# low fighting stance, fanned slightly OUTWARD from the chassis
	# and tilted down so they read as "held in two hands at the hip"
	# rather than straight-ahead T-pose extensions. Each dagger: brass
	# hilt at the body, sooted-iron blade angled forward/down, hot
	# white-orange glowing tip.
	# Orientation fix (2026-05-16): previous `rotation.y = sx * 12°`
	# fanned the daggers INWARD (right blade pointed left, left blade
	# pointed right — Y+ rotation is counterclockwise from above).
	# Negated to fan outward + bumped to 22° for a clearer matador-
	# stance silhouette + 15° downward tilt for the held-at-hip pose.
	const HEAT_WHITE_HOT: Color = Color(1.0, 0.85, 0.55, 1.0)
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var dagger_root := Node3D.new()
		dagger_root.name = "MatadorDagger_%d" % side
		# Held at hip height (lower than before so the silhouette
		# reads as "blades close to the body, not stuck out at chest").
		dagger_root.position = Vector3(sx * torso_size.x * 0.45, torso_size.y * 0.38, -torso_size.z * 0.5 - 0.05)
		# Outward fan (negated previous sign) + downward blade tilt.
		dagger_root.rotation.y = -sx * deg_to_rad(22.0)
		dagger_root.rotation.x = deg_to_rad(18.0)
		# Tag as melee pivot so play_melee_anim's swing tween finds it.
		# stores the rest rotation in meta so the tween can return to
		# it after the swing.
		dagger_root.add_to_group("melee_pivots")
		dagger_root.set_meta("melee_rest_rot", dagger_root.rotation)
		dagger_root.set_meta("melee_swing_axis", "x")
		torso_pivot.add_child(dagger_root)
		# Brass hilt cube nearest the body.
		var hilt := MeshInstance3D.new()
		var hilt_box := BoxMesh.new()
		hilt_box.size = Vector3(0.10, 0.12, 0.18)
		hilt.mesh = hilt_box
		hilt.position = Vector3(0.0, 0.0, -0.04)
		hilt.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		dagger_root.add_child(hilt)
		# Crossguard.
		var guard := MeshInstance3D.new()
		var guard_box := BoxMesh.new()
		guard_box.size = Vector3(0.18, 0.04, 0.06)
		guard.mesh = guard_box
		guard.position = Vector3(0.0, 0.0, -0.18)
		guard.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		dagger_root.add_child(guard)
		# Blade — flat tapered slab. Sooted near the hilt, hot at the tip.
		var blade_len: float = 0.55
		var blade := MeshInstance3D.new()
		var blade_box := BoxMesh.new()
		blade_box.size = Vector3(0.05, 0.10, blade_len)
		blade.mesh = blade_box
		blade.position = Vector3(0.0, 0.0, -0.18 - blade_len * 0.5)
		blade.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		dagger_root.add_child(blade)
		# Hot edge highlight on the blade — narrow emissive strip
		# along the cutting edge so the dagger looks heated.
		var edge := MeshInstance3D.new()
		var edge_box := BoxMesh.new()
		edge_box.size = Vector3(0.012, 0.10, blade_len * 0.85)
		edge.mesh = edge_box
		var edge_x: float = sx * 0.022
		edge.position = Vector3(edge_x, 0.0, -0.18 - blade_len * 0.5)
		var edge_mat := StandardMaterial3D.new()
		edge_mat.albedo_color = Color(1.0, 0.55, 0.18, 1.0)
		edge_mat.emission_enabled = true
		edge_mat.emission = Color(1.0, 0.55, 0.18, 1.0)
		edge_mat.emission_energy_multiplier = 1.6
		edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		edge.set_surface_override_material(0, edge_mat)
		dagger_root.add_child(edge)
		mats.append(edge_mat)
		# Tip-orb removed per playtest 2026-05-18 — the bright sphere at
		# the dagger point read as a flashlight bulb stuck on the blade.
		# The hot-edge emissive strip alone tells the "heated blade"
		# story; the orb was over-reading. Kept the variable comment as
		# a marker so future passes know what was here.
		# Muzzle marker on the dominant (right) dagger so melee swings
		# spawn their flame VFX from the blade tip rather than the
		# unit centre. Only one Muzzle marker — Unit.gd's lookup uses
		# the first match.
		if side == 1:
			var dagger_muzzle := Marker3D.new()
			dagger_muzzle.name = "Muzzle"
			dagger_muzzle.position = Vector3(0.0, 0.0, -0.18 - blade_len - 0.10)
			dagger_root.add_child(dagger_muzzle)
	# --- Small forward floodlight on the chest centre — Heliarch lamp
	# motif applied to the light unit. Sized down so it doesn't compete
	# with the dagger silhouette below or the back reactor core above.
	const HELIARCH_BRASS_MAT: Color = Color(0.55, 0.40, 0.20, 1.0)
	const FLOOD_WARM_MAT: Color = Color(1.0, 0.78, 0.42, 1.0)
	var flood_root_mat := Node3D.new()
	flood_root_mat.position = Vector3(0.0, torso_size.y * 0.62, -torso_size.z * 0.5 - 0.04)
	torso_pivot.add_child(flood_root_mat)
	var flood_housing_mat := MeshInstance3D.new()
	var fhouse_mat := CylinderMesh.new()
	fhouse_mat.top_radius = 0.10
	fhouse_mat.bottom_radius = 0.085
	fhouse_mat.height = 0.10
	fhouse_mat.radial_segments = 10
	flood_housing_mat.mesh = fhouse_mat
	flood_housing_mat.rotation.x = PI * 0.5
	flood_housing_mat.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS_MAT))
	flood_root_mat.add_child(flood_housing_mat)
	var flood_bulb_mat := MeshInstance3D.new()
	var fbulb_mat := CylinderMesh.new()
	fbulb_mat.top_radius = 0.07
	fbulb_mat.bottom_radius = 0.07
	fbulb_mat.height = 0.03
	fbulb_mat.radial_segments = 10
	flood_bulb_mat.mesh = fbulb_mat
	flood_bulb_mat.rotation.x = PI * 0.5
	flood_bulb_mat.position = Vector3(0.0, 0.0, -0.06)
	var fb_mat_mat := StandardMaterial3D.new()
	fb_mat_mat.albedo_color = FLOOD_WARM_MAT
	fb_mat_mat.emission_enabled = true
	fb_mat_mat.emission = FLOOD_WARM_MAT
	fb_mat_mat.emission_energy_multiplier = 3.0
	fb_mat_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flood_bulb_mat.set_surface_override_material(0, fb_mat_mat)
	flood_root_mat.add_child(flood_bulb_mat)
	mats.append(fb_mat_mat)
	# Brass embossed sigil on the chest front (above the launcher),
	# rectangular tablet with a hot-amber emissive emblem.
	var sigil_back := MeshInstance3D.new()
	var sb_box := BoxMesh.new()
	sb_box.size = Vector3(torso_size.x * 0.32, torso_size.y * 0.10, 0.04)
	sigil_back.mesh = sb_box
	sigil_back.position = Vector3(0.0, torso_size.y * 0.88, -torso_size.z * 0.5 - 0.04)
	sigil_back.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	torso_pivot.add_child(sigil_back)
	var sigil := MeshInstance3D.new()
	var sg_box := BoxMesh.new()
	sg_box.size = Vector3(torso_size.x * 0.22, torso_size.y * 0.05, 0.04)
	sigil.mesh = sg_box
	sigil.position = Vector3(0.0, torso_size.y * 0.88, -torso_size.z * 0.5 - 0.06)
	var sigil_mat := StandardMaterial3D.new()
	sigil_mat.albedo_color = HELIARCH_BRASS
	sigil_mat.emission_enabled = true
	sigil_mat.emission = HELIARCH_BRASS
	sigil_mat.emission_energy_multiplier = 0.55
	sigil_mat.metallic = 0.85
	sigil_mat.roughness = 0.25
	sigil.set_surface_override_material(0, sigil_mat)
	torso_pivot.add_child(sigil)
	mats.append(sigil_mat)
	# Heliarch miner helmet — wide brim + central floodlight, replaces
	# the generic head silhouette. Sells "industrial reactor priest in
	# work safety gear" rather than the previous bare-cockpit look.
	_apply_heliarch_miner_helmet(torso_pivot, torso_size, mats)


func _apply_heliarch_miner_helmet(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	## Adds a wide-brimmed mining helmet with a large central forward
	## floodlight on top of the unit's torso. Shared between Matador and
	## Cremator (and any future Heliarch infantry / mech) so the faction
	## reads as "industrial work crew". Per playtest 2026-05-18: head
	## should "look more like miner equipment and have a large central
	## lamp designwise". Anchored to torso_pivot at head height.
	const HELIARCH_BRASS_MH: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_MH: Color = Color(0.22, 0.18, 0.14, 1.0)
	const FLOOD_WARM_MH: Color = Color(1.0, 0.78, 0.42, 1.0)
	# Head approximate Y — sits just above the torso top.
	var head_y: float = torso_size.y + 0.18
	# Helmet dome — short flat-topped cylinder (the hard hat). Per
	# playtest 2026-05-19 the previous build was too large for the
	# Matador chassis; sizes scaled to ~70% across the helmet.
	var dome := MeshInstance3D.new()
	var dc := CylinderMesh.new()
	dc.top_radius = 0.15
	dc.bottom_radius = 0.20
	dc.height = 0.14
	dc.radial_segments = 12
	dome.mesh = dc
	dome.position = Vector3(0.0, head_y + dc.height * 0.5, 0.0)
	dome.set_surface_override_material(0, _make_metal_mat(SOOTED_MH))
	torso_pivot.add_child(dome)
	# Wide brim — flat disc around the base of the dome.
	var brim := MeshInstance3D.new()
	var brimc := CylinderMesh.new()
	brimc.top_radius = 0.26
	brimc.bottom_radius = 0.26
	brimc.height = 0.03
	brimc.radial_segments = 14
	brim.mesh = brimc
	brim.position = Vector3(0.0, head_y + 0.02, 0.0)
	brim.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS_MH))
	torso_pivot.add_child(brim)
	# Forward brim extension — flat slab sticking out the front.
	var visor := MeshInstance3D.new()
	var visorb := BoxMesh.new()
	visorb.size = Vector3(0.36, 0.04, 0.14)
	visor.mesh = visorb
	visor.position = Vector3(0.0, head_y + 0.04, -0.22)
	visor.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS_MH))
	torso_pivot.add_child(visor)
	# --- Central forward floodlight on the helmet dome — the signature.
	# Brass housing + warm bulb + OmniLight so the lamp casts on the
	# ground in front of the unit. Also scaled down with the rest.
	var lamp_housing := MeshInstance3D.new()
	var lhc := CylinderMesh.new()
	lhc.top_radius = 0.09
	lhc.bottom_radius = 0.08
	lhc.height = 0.12
	lhc.radial_segments = 12
	lamp_housing.mesh = lhc
	lamp_housing.rotation.x = PI * 0.5
	lamp_housing.position = Vector3(0.0, head_y + dc.height * 0.55, -0.13)
	lamp_housing.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS_MH))
	torso_pivot.add_child(lamp_housing)
	# Bright lamp bulb.
	var lamp_bulb := MeshInstance3D.new()
	var lbc := CylinderMesh.new()
	lbc.top_radius = 0.07
	lbc.bottom_radius = 0.07
	lbc.height = 0.03
	lbc.radial_segments = 12
	lamp_bulb.mesh = lbc
	lamp_bulb.rotation.x = PI * 0.5
	lamp_bulb.position = Vector3(0.0, head_y + dc.height * 0.55, -0.20)
	var lb_mat := StandardMaterial3D.new()
	lb_mat.albedo_color = FLOOD_WARM_MH
	lb_mat.emission_enabled = true
	lb_mat.emission = FLOOD_WARM_MH
	lb_mat.emission_energy_multiplier = 3.6
	lb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lamp_bulb.set_surface_override_material(0, lb_mat)
	torso_pivot.add_child(lamp_bulb)
	mats.append(lb_mat)
	# Small amber-cast OmniLight at the lamp position.
	var lamp_light := OmniLight3D.new()
	lamp_light.light_color = FLOOD_WARM_MH
	lamp_light.light_energy = 0.55
	lamp_light.omni_range = 3.5
	lamp_light.position = Vector3(0.0, head_y + dc.height * 0.55, -0.35)
	torso_pivot.add_child(lamp_light)
	# Brass chinstrap — small short bar under the helmet.
	var strap := MeshInstance3D.new()
	var stb := BoxMesh.new()
	stb.size = Vector3(0.36, 0.04, 0.06)
	strap.mesh = stb
	strap.position = Vector3(0.0, head_y - 0.04, 0.0)
	strap.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS_MH))
	torso_pivot.add_child(strap)


func _apply_stoker_base_overlay(torso_pivot: Node3D, torso_size: Vector3, head_size: Vector3, _base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Heliarch engineer per user pick 2026-05-14: reactor-priest hood
	## silhouette. Adds a tall forward-tilted cowl over the head with
	## reactor-amber glow inside, a brass ceremonial chain drape from
	## one shoulder, a hot-orange welding torch replacing one claw arm,
	## and an embossed prayer-plate on the chest backing.
	## Stacks on top of the Heliarch chest reactor grille + back vent
	## stack already applied by _build_mech_member's faction pass.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const TORCH_HOT: Color = Color(1.0, 0.45, 0.15, 1.0)
	const HELIARCH_BRASS: Color = Color(0.55, 0.40, 0.20, 1.0)
	const PRIEST_DARK: Color = Color(0.12, 0.10, 0.08, 1.0)
	# --- Hooded cowl: tall rectangular slab tilted forward over the
	# head, plus side wings that frame the cockpit. Reactor glow inside.
	var cowl_root := Node3D.new()
	cowl_root.position = Vector3(0.0, torso_size.y + head_size.y * 0.10, 0.0)
	torso_pivot.add_child(cowl_root)
	# Main cowl slab — tilted forward so it overhangs the head.
	var cowl := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(head_size.x * 1.30, head_size.y * 1.40, 0.10)
	cowl.mesh = cb
	cowl.position = Vector3(0.0, head_size.y * 0.70, -head_size.z * 0.45)
	cowl.rotation.x = deg_to_rad(18.0)  # tilt forward
	cowl.set_surface_override_material(0, _make_metal_mat(PRIEST_DARK))
	cowl_root.add_child(cowl)
	mats.append(cowl.get_surface_override_material(0))
	# Two side wings flanking the cockpit.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var wing := MeshInstance3D.new()
		var wb := BoxMesh.new()
		wb.size = Vector3(0.08, head_size.y * 1.20, head_size.z * 0.80)
		wing.mesh = wb
		wing.position = Vector3(sx * head_size.x * 0.65, head_size.y * 0.55, -head_size.z * 0.10)
		wing.rotation.z = sx * deg_to_rad(-6.0)
		wing.set_surface_override_material(0, _make_metal_mat(PRIEST_DARK))
		cowl_root.add_child(wing)
		mats.append(wing.get_surface_override_material(0))
	# Reactor-amber glow inside the cowl — recessed plate behind the head.
	var glow := MeshInstance3D.new()
	var glow_box := BoxMesh.new()
	glow_box.size = Vector3(head_size.x * 0.85, head_size.y * 0.55, 0.04)
	glow.mesh = glow_box
	glow.position = Vector3(0.0, head_size.y * 0.60, -head_size.z * 0.30)
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_color = REACTOR_AMBER
	glow_mat.emission_enabled = true
	glow_mat.emission = REACTOR_AMBER
	glow_mat.emission_energy_multiplier = 2.4
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.set_surface_override_material(0, glow_mat)
	cowl_root.add_child(glow)
	mats.append(glow_mat)
	# Small omni light inside the cowl so the glow casts on the face.
	var cowl_light := OmniLight3D.new()
	cowl_light.light_color = REACTOR_AMBER
	cowl_light.light_energy = 0.55
	cowl_light.omni_range = head_size.x * 1.5
	cowl_light.position = Vector3(0.0, head_size.y * 0.55, -head_size.z * 0.25)
	cowl_root.add_child(cowl_light)
	# --- Brass ceremonial chain drape on the LEFT shoulder. Five
	# small linked sphere/ring pieces hanging in an arc.
	var chain_root := Node3D.new()
	chain_root.position = Vector3(-torso_size.x * 0.48, torso_size.y * 0.78, 0.0)
	torso_pivot.add_child(chain_root)
	for link_i: int in 5:
		var link := MeshInstance3D.new()
		var ls := SphereMesh.new()
		ls.radius = 0.05
		ls.height = 0.10
		link.mesh = ls
		# Hanging arc: x drifts outward + down. Quadratic curve so the
		# bottom links splay out more than the top.
		var t: float = float(link_i) / 4.0
		var arc_x: float = -t * 0.12
		var arc_y: float = -t * t * 0.55
		link.position = Vector3(arc_x, arc_y, 0.0)
		link.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		chain_root.add_child(link)
	# --- Embossed prayer-plate on the chest backing — gold-on-dark
	# rectangular tablet.
	var plate := MeshInstance3D.new()
	var pl_box := BoxMesh.new()
	pl_box.size = Vector3(torso_size.x * 0.36, torso_size.y * 0.30, 0.04)
	plate.mesh = pl_box
	plate.position = Vector3(torso_size.x * 0.18, torso_size.y * 0.78, -torso_size.z * 0.5 - 0.03)
	plate.set_surface_override_material(0, _make_metal_mat(PRIEST_DARK))
	torso_pivot.add_child(plate)
	# Gold sigil bar embossed on the plate.
	var sigil := MeshInstance3D.new()
	var sg_box := BoxMesh.new()
	sg_box.size = Vector3(torso_size.x * 0.26, torso_size.y * 0.06, 0.04)
	sigil.mesh = sg_box
	sigil.position = Vector3(torso_size.x * 0.18, torso_size.y * 0.78, -torso_size.z * 0.5 - 0.05)
	var sigil_mat := StandardMaterial3D.new()
	sigil_mat.albedo_color = HELIARCH_BRASS
	sigil_mat.emission_enabled = true
	sigil_mat.emission = HELIARCH_BRASS
	sigil_mat.emission_energy_multiplier = 0.55
	sigil_mat.metallic = 0.85
	sigil_mat.roughness = 0.25
	sigil.set_surface_override_material(0, sigil_mat)
	torso_pivot.add_child(sigil)
	mats.append(sigil_mat)
	# --- Welding torch on the LEFT claw arm. Per playtest 2026-05-15:
	# the engineer should NOT have a glowing circle at the front of the
	# barrel; instead the barrel should be HOLLOW with the heat glowing
	# from INSIDE. Built as: brass outer barrel (cap_top removed so the
	# bore is visibly open) + dark inner throat + amber emissive plate
	# recessed deep inside the throat.
	var cannon_pivot: Node3D = torso_pivot.get_node_or_null("CannonPivot_0") as Node3D
	if cannon_pivot:
		# Outer brass barrel with the front cap removed so the player
		# can see down into the bore.
		var barrel := MeshInstance3D.new()
		var barrel_cyl := CylinderMesh.new()
		barrel_cyl.top_radius = 0.07
		barrel_cyl.bottom_radius = 0.08
		barrel_cyl.height = 0.32
		barrel_cyl.radial_segments = 12
		barrel_cyl.cap_top = false  # open mouth so the inner throat is visible
		barrel.mesh = barrel_cyl
		barrel.rotation.x = PI * 0.5  # face -Z
		barrel.position.z = -0.56
		barrel.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		cannon_pivot.add_child(barrel)
		# Inner dark throat — sunk into the bore so the recessed read
		# survives any camera angle.
		var throat := MeshInstance3D.new()
		var throat_cyl := CylinderMesh.new()
		throat_cyl.top_radius = 0.058
		throat_cyl.bottom_radius = 0.058
		throat_cyl.height = 0.20
		throat_cyl.radial_segments = 10
		throat.mesh = throat_cyl
		throat.rotation.x = PI * 0.5
		throat.position.z = -0.50
		throat.set_surface_override_material(0, _make_metal_mat(Color(0.04, 0.03, 0.02)))
		cannon_pivot.add_child(throat)
		# Amber molten core deep inside the throat (small disc near the
		# back) — reads as "hot from within" not "glowing tip".
		var core := MeshInstance3D.new()
		var core_cyl := CylinderMesh.new()
		core_cyl.top_radius = 0.05
		core_cyl.bottom_radius = 0.05
		core_cyl.height = 0.04
		core_cyl.radial_segments = 10
		core.mesh = core_cyl
		core.rotation.x = PI * 0.5
		core.position.z = -0.44
		var core_mat := StandardMaterial3D.new()
		core_mat.albedo_color = TORCH_HOT
		core_mat.emission_enabled = true
		core_mat.emission = TORCH_HOT
		core_mat.emission_energy_multiplier = 3.4
		core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		core.set_surface_override_material(0, core_mat)
		cannon_pivot.add_child(core)
		mats.append(core_mat)
		# Small amber omni light near the bore mouth so the bore casts
		# warm light on the surrounding chassis (sells the heat read).
		var bore_light := OmniLight3D.new()
		bore_light.light_color = TORCH_HOT
		bore_light.light_energy = 0.45
		bore_light.omni_range = 1.4
		bore_light.position.z = -0.55
		cannon_pivot.add_child(bore_light)


func _apply_rook_base_overlay(member: Node3D, torso_pivot: Node3D, torso_size: Vector3, head_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	## Combine basic light per user pick 2026-05-14 + revisions
	## 2026-05-15: square-shouldered scout biped with weathered brass
	## (NOT bright gold), half-circle drum magazine UNDER the gun
	## (not a full collar around it), amber visor slit overriding the
	## cyan default, hammer-and-anvil chest sigil.
	# Weathered brass — duller than the bright gilded ANVIL_BRASS
	# used on building cornices, so the unit reads as field-worn
	# infantry kit not parade-polished.
	const WEATHERED_BRASS: Color = Color(0.55, 0.42, 0.18, 1.0)
	# --- Half-circle drum magazine UNDER the cannon barrel (per
	# playtest: "more fun if they looked like a round magazine /
	# semicircle under the gun not all around it"). Built as a
	# small flat disc + a thin semicircular ring around its forward
	# half so the silhouette reads as a "drum mag" peeking out below
	# the barrel.
	var cannon_pivot: Node3D = torso_pivot.get_node_or_null("CannonPivot_0") as Node3D
	if cannon_pivot:
		# Smaller drum body (was 0.20 radius — playtest 2026-05-15: too
		# beefy compared to the gun itself). Now a tighter ~0.14 disc that
		# reads as a clip-on magazine rather than a bucket.
		var drum := MeshInstance3D.new()
		var drum_cyl := CylinderMesh.new()
		drum_cyl.top_radius = 0.14
		drum_cyl.bottom_radius = 0.14
		drum_cyl.height = 0.06
		drum_cyl.radial_segments = 14
		drum.mesh = drum_cyl
		# Drum is horizontal disc oriented like a pancake under the gun.
		drum.position = Vector3(0.0, -0.16, -0.10)
		var drum_mat := _make_metal_mat(WEATHERED_BRASS)
		drum.set_surface_override_material(0, drum_mat)
		cannon_pivot.add_child(drum)
		mats.append(drum_mat)
		# Semicircular rim — half-torus on the forward half of the drum.
		var rim := MeshInstance3D.new()
		var rim_torus := TorusMesh.new()
		rim_torus.inner_radius = 0.13
		rim_torus.outer_radius = 0.17
		rim_torus.rings = 10
		rim_torus.ring_segments = 4
		rim.mesh = rim_torus
		rim.position = Vector3(0.0, -0.12, -0.10)
		rim.set_surface_override_material(0, _make_metal_mat(WEATHERED_BRASS.darkened(0.10)))
		cannon_pivot.add_child(rim)
		# Brass accent collar on the gun barrel itself — small ring near
		# the muzzle so the gun reads as having a brass cooling sleeve.
		var collar := MeshInstance3D.new()
		var collar_cyl := CylinderMesh.new()
		collar_cyl.top_radius = 0.07
		collar_cyl.bottom_radius = 0.07
		collar_cyl.height = 0.05
		collar_cyl.radial_segments = 12
		collar.mesh = collar_cyl
		collar.rotate_object_local(Vector3.RIGHT, PI * 0.5)
		collar.position = Vector3(0.0, 0.0, -0.30)
		collar.set_surface_override_material(0, _make_metal_mat(WEATHERED_BRASS))
		cannon_pivot.add_child(collar)
		# Two short brass strap mounts holding the drum to the gun
		# undercarriage — sells "this is a clip-on magazine".
		for strap_side: int in 2:
			var sx: float = (-1.0 if strap_side == 0 else 1.0) * 0.10
			var strap := MeshInstance3D.new()
			var strap_box := BoxMesh.new()
			strap_box.size = Vector3(0.04, 0.18, 0.04)
			strap.mesh = strap_box
			strap.position = Vector3(sx, -0.10, -0.10)
			strap.set_surface_override_material(0, _make_metal_mat(WEATHERED_BRASS.darkened(0.20)))
			cannon_pivot.add_child(strap)
	# --- Override the cyan visor with amber. Find the existing visor
	# node by walking torso_pivot's children for the small box at the
	# expected visor position. Cleanest: just paint a NEW amber visor
	# slat over the top of the existing one (the previous cyan visor
	# stays but is occluded by the wider amber strip).
	var amber_visor := MeshInstance3D.new()
	var av_box := BoxMesh.new()
	av_box.size = Vector3(head_size.x * 0.92, head_size.y * 0.30, head_size.z * 0.06)
	amber_visor.mesh = av_box
	amber_visor.position = Vector3(0.0, torso_size.y + head_size.y * 0.55, -head_size.z * 0.5 - 0.01)
	var amber_mat := StandardMaterial3D.new()
	amber_mat.albedo_color = ANVIL_BRASS
	amber_mat.emission_enabled = true
	amber_mat.emission = Color(1.0, 0.55, 0.18)
	amber_mat.emission_energy_multiplier = 1.8
	amber_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	amber_visor.set_surface_override_material(0, amber_mat)
	torso_pivot.add_child(amber_visor)
	mats.append(amber_mat)
	# --- Combine hammer-and-anvil chest sigil — shared helper, same
	# brass icon used on Bulwark variants. Reads as Combine doctrine
	# from the chest backing.
	_apply_combine_hammer_anvil_sigil(member)


func _apply_ashigaru_base_overlay(torso_pivot: Node3D, torso_size: Vector3, base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Inheritor Ashigaru melee scout per user pick 2026-05-14: replace
	## the single-left claw arm with a two-handed katana. The blade
	## extends forward from the cannon pivot (so weapon recoil swings
	## the blade), and a foregrip arm reaches from the opposite
	## shoulder to grip the blade mid-shaft. Inheritor identity:
	## bronze tsuba, pale-gold blade emissive (Architect signature),
	## verdigris-bronze fittings.
	const ARCHITECT_VIOLET: Color = Color(0.70, 0.55, 1.0, 1.0)
	const BLADE_GLOW: Color = Color(0.95, 0.85, 0.55, 1.0)
	const BRONZE_PATINA: Color = Color(0.55, 0.40, 0.20, 1.0)
	const HILT_DARK: Color = Color(0.10, 0.09, 0.08, 1.0)
	# Find the cannon pivot — single_left puts it at CannonPivot_0.
	var cannon_pivot: Node3D = torso_pivot.get_node_or_null("CannonPivot_0") as Node3D
	if cannon_pivot:
		# Clear stock claw geometry (forearm + 2 fingers) — would clip
		# with the new katana hilt.
		for child: Node in cannon_pivot.get_children():
			child.queue_free()
		# Lower the pivot toward the hip + angle the blade slightly down
		# and across the body — sells "katana held in two hands at the
		# waist in a ready stance" instead of the previous T-pose
		# straight-forward extension (playtest 2026-05-16). Recoil still
		# animates on top of this transform via play_melee_anim, so the
		# lunge thrust reads from the new low ready position.
		# Drop the pivot to roughly the chassis waistline (0.40 of torso
		# height, was at shoulder ~1.0). Move it slightly forward of the
		# torso front so the blade clears the chest plate.
		cannon_pivot.position.y = torso_size.y * 0.40
		cannon_pivot.position.z = -torso_size.z * 0.5 - 0.06
		# Tilt the pivot: rotate down 22° (blade tip angles toward the
		# ground in front), and yaw 10° toward the body centre line for
		# the cross-body "held in two hands" silhouette.
		cannon_pivot.rotation.x = deg_to_rad(22.0)
		var yaw_sign: float = -1.0 if cannon_pivot.position.x < 0.0 else 1.0
		cannon_pivot.rotation.y = -yaw_sign * deg_to_rad(10.0)
		# Build the katana along the pivot's -Z axis (forward).
		# Order from pivot outward: grip → tsuba (handguard) → blade → tip.
		# --- Grip (handle): short cylinder bound in dark wrap.
		var grip := MeshInstance3D.new()
		var gc := CylinderMesh.new()
		gc.top_radius = 0.05
		gc.bottom_radius = 0.05
		gc.height = 0.32
		gc.radial_segments = 10
		grip.mesh = gc
		grip.rotation.x = PI * 0.5
		grip.position.z = -0.16
		var grip_mat := _make_metal_mat(HILT_DARK)
		grip.set_surface_override_material(0, grip_mat)
		cannon_pivot.add_child(grip)
		mats.append(grip_mat)
		# --- Tsuba (handguard): small flat disc between grip and blade.
		var tsuba := MeshInstance3D.new()
		var ts_cyl := CylinderMesh.new()
		ts_cyl.top_radius = 0.12
		ts_cyl.bottom_radius = 0.12
		ts_cyl.height = 0.04
		ts_cyl.radial_segments = 12
		tsuba.mesh = ts_cyl
		tsuba.rotation.x = PI * 0.5
		tsuba.position.z = -0.34
		var tsuba_mat := _make_metal_mat(BRONZE_PATINA)
		tsuba.set_surface_override_material(0, tsuba_mat)
		cannon_pivot.add_child(tsuba)
		mats.append(tsuba_mat)
		# --- Blade: WIDER and TALLER profile so it reads as a sword
		# rather than a lance/spear. Per playtest 2026-05-15: "katana
		# looks like a lance and should instead be shaped more
		# swordlike, have a slight glowing edge". Wider in X (the
		# blade's flat face — ~5x the previous thinness), shorter in
		# total length, and a clearly thinner spine on top.
		var blade_len: float = 1.10
		var blade := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(0.18, 0.06, blade_len)  # WIDE flat blade (X), thin spine (Y), full length (Z)
		blade.mesh = bb
		blade.position.z = -0.36 - blade_len * 0.5
		var blade_mat := StandardMaterial3D.new()
		blade_mat.albedo_color = Color(0.85, 0.83, 0.72)
		blade_mat.emission_enabled = true
		blade_mat.emission = BLADE_GLOW
		blade_mat.emission_energy_multiplier = 0.55
		blade_mat.metallic = 0.95
		blade_mat.roughness = 0.15
		blade.set_surface_override_material(0, blade_mat)
		cannon_pivot.add_child(blade)
		mats.append(blade_mat)
		# Brighter violet emissive edge along the BOTTOM of the blade
		# (the cutting edge). Wider + brighter than the previous
		# version so it actually reads at gameplay zoom.
		var edge := MeshInstance3D.new()
		var eb := BoxMesh.new()
		eb.size = Vector3(0.20, 0.025, blade_len * 0.95)
		edge.mesh = eb
		edge.position = Vector3(0.0, -0.04, -0.36 - blade_len * 0.5)
		var edge_mat := StandardMaterial3D.new()
		edge_mat.albedo_color = ARCHITECT_VIOLET
		edge_mat.emission_enabled = true
		edge_mat.emission = ARCHITECT_VIOLET
		edge_mat.emission_energy_multiplier = 2.6
		edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		edge.set_surface_override_material(0, edge_mat)
		cannon_pivot.add_child(edge)
		mats.append(edge_mat)
		# --- Tip: angled wedge tapering forward to a sharp point.
		# Built as a thin box rotated so it reads as a chiseled
		# sword tip, not a cone (cones look spear-like).
		var tip := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(0.18, 0.04, 0.18)
		tip.mesh = tb
		tip.position.z = -0.36 - blade_len - 0.06
		tip.rotation.y = deg_to_rad(45.0)  # diamond-shape from above (sword point)
		tip.set_surface_override_material(0, blade_mat)
		cannon_pivot.add_child(tip)
		# Optional: a small kashira (pommel cap) at the back of the
		# grip so the hilt reads as finished.
		var pommel := MeshInstance3D.new()
		var pmel_sph := SphereMesh.new()
		pmel_sph.radius = 0.06
		pmel_sph.height = 0.10
		pommel.mesh = pmel_sph
		pommel.position.z = 0.04
		pommel.set_surface_override_material(0, _make_metal_mat(BRONZE_PATINA))
		cannon_pivot.add_child(pommel)
		# Muzzle marker — for combat fire-position consistency, sits at
		# the blade's mid-point so beam/hitscan visuals (if any) emit
		# from the strike zone. The melee weapon won't actually fire
		# tracers but this keeps the pivot data clean.
		var mark := Marker3D.new()
		mark.name = "Muzzle"
		mark.position = Vector3(0.0, 0.0, -0.36 - blade_len * 0.5)
		cannon_pivot.add_child(mark)
		# --- Foregrip arm: reach from the OPPOSITE shoulder to grip
		# the blade just past the tsuba (mid-shaft of the held weapon).
		# Built as child of torso_pivot so the support arm doesn't
		# swing with cannon recoil — it stays planted while the blade
		# arm thrusts.
		var grip_world_local: Vector3 = cannon_pivot.position + Vector3(0.0, 0.0, -0.50)
		var support_shoulder: Vector3 = Vector3(-cannon_pivot.position.x, cannon_pivot.position.y, 0.0)
		var arm_vec: Vector3 = grip_world_local - support_shoulder
		var arm_len: float = arm_vec.length()
		if arm_len > 0.05:
			var arm := MeshInstance3D.new()
			var ab := BoxMesh.new()
			ab.size = Vector3(0.08, 0.08, arm_len)
			arm.mesh = ab
			arm.position = (support_shoulder + grip_world_local) * 0.5
			var arm_mat := _make_metal_mat(base_color)
			arm.set_surface_override_material(0, arm_mat)
			torso_pivot.add_child(arm)
			# look_at after add_child so the node is inside the tree.
			arm.look_at(torso_pivot.to_global(grip_world_local), Vector3.UP)
			mats.append(arm_mat)
			# Knuckle pad where the support hand grips the blade — small
			# bronze cube so the "second hand" reads.
			var knuckle := MeshInstance3D.new()
			var kb := BoxMesh.new()
			kb.size = Vector3(0.12, 0.12, 0.10)
			knuckle.mesh = kb
			knuckle.position = grip_world_local
			var k_mat := _make_metal_mat(BRONZE_PATINA)
			knuckle.set_surface_override_material(0, k_mat)
			torso_pivot.add_child(knuckle)
			mats.append(k_mat)


func _apply_restorer_base_overlay(torso_pivot: Node3D, torso_size: Vector3, _head_size: Vector3, _base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Inheritor Restorer — quadrupedal restoration crab per user pick
	## 2026-05-14. The shape override widens + flattens the torso and
	## drops the hip; this overlay adds the dorsal welder rig + Architect-
	## violet beam emitter, verdigris-bronze side pipework, and a gold-
	## leaf sigil on the back so the silhouette reads as an Inheritor
	## reverent artisan rather than another claw-armed engineer.
	const ARCHITECT_VIOLET: Color = Color(0.70, 0.55, 1.0, 1.0)
	const BRONZE_PATINA: Color = Color(0.55, 0.40, 0.20, 1.0)
	const VERDIGRIS: Color = Color(0.32, 0.50, 0.42, 1.0)
	const GOLD_LEAF: Color = Color(0.95, 0.78, 0.35, 1.0)
	# --- Dorsal welder rig: a low-profile bronze housing centred on
	# the torso top with an upward-facing emitter dish + violet beam
	# spout angled forward.
	var housing := MeshInstance3D.new()
	var hb := BoxMesh.new()
	hb.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.40, torso_size.z * 0.50)
	housing.mesh = hb
	housing.position = Vector3(0.0, torso_size.y + torso_size.y * 0.10, 0.0)
	var housing_mat := _make_metal_mat(BRONZE_PATINA)
	housing.set_surface_override_material(0, housing_mat)
	torso_pivot.add_child(housing)
	mats.append(housing_mat)
	# Bronze coil rings around the housing — patinated artisanal feel.
	for ring_i: int in 2:
		var ring := MeshInstance3D.new()
		var rt := TorusMesh.new()
		rt.inner_radius = torso_size.x * 0.34
		rt.outer_radius = torso_size.x * 0.40
		rt.rings = 18
		rt.ring_segments = 6
		ring.mesh = rt
		var ring_z: float = (-1.0 if ring_i == 0 else 1.0) * torso_size.z * 0.16
		ring.position = Vector3(0.0, torso_size.y + torso_size.y * 0.10, ring_z)
		ring.rotation.x = PI * 0.5
		var ring_mat := _make_metal_mat(BRONZE_PATINA)
		ring.set_surface_override_material(0, ring_mat)
		torso_pivot.add_child(ring)
		mats.append(ring_mat)
	# Forward-angled welder spout — short cylinder with a violet
	# emissive tip. Tilted nose-down so it reads as aimed at the
	# ground the engineer is restoring.
	var spout := MeshInstance3D.new()
	var sp_cyl := CylinderMesh.new()
	sp_cyl.top_radius = 0.07
	sp_cyl.bottom_radius = 0.10
	sp_cyl.height = torso_size.z * 0.55
	sp_cyl.radial_segments = 10
	spout.mesh = sp_cyl
	spout.rotation.x = deg_to_rad(70.0)  # nose-down forward
	spout.position = Vector3(0.0, torso_size.y + torso_size.y * 0.22, -torso_size.z * 0.20)
	var spout_mat := _make_metal_mat(Color(0.18, 0.16, 0.14))
	spout.set_surface_override_material(0, spout_mat)
	torso_pivot.add_child(spout)
	mats.append(spout_mat)
	# Violet emitter tip at the spout's front.
	var emitter := MeshInstance3D.new()
	var em_sph := SphereMesh.new()
	em_sph.radius = 0.10
	em_sph.height = 0.20
	emitter.mesh = em_sph
	emitter.position = Vector3(0.0, torso_size.y + torso_size.y * 0.22 - sin(deg_to_rad(70.0)) * torso_size.z * 0.30, -torso_size.z * 0.20 + cos(deg_to_rad(70.0)) * torso_size.z * 0.30 - torso_size.z * 0.20)
	# (Approximate placement at the spout's far end. Decoupled from
	# exact trig so a small visual drift between spout-tip and emitter
	# is acceptable.)
	emitter.position = Vector3(0.0, torso_size.y * 0.92, -torso_size.z * 0.42)
	var em_mat := StandardMaterial3D.new()
	em_mat.albedo_color = ARCHITECT_VIOLET
	em_mat.emission_enabled = true
	em_mat.emission = ARCHITECT_VIOLET
	em_mat.emission_energy_multiplier = 2.8
	em_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	emitter.set_surface_override_material(0, em_mat)
	torso_pivot.add_child(emitter)
	mats.append(em_mat)
	# --- Side pipework: verdigris-bronze pipes running along each
	# side of the wider flat torso, sells "this is plumbed for
	# restoration work".
	for pipe_side: int in 2:
		var psx: float = -torso_size.x * 0.50 - 0.06 if pipe_side == 0 else torso_size.x * 0.50 + 0.06
		var pipe := MeshInstance3D.new()
		var p_cyl := CylinderMesh.new()
		p_cyl.top_radius = 0.06
		p_cyl.bottom_radius = 0.06
		p_cyl.height = torso_size.z * 0.85
		p_cyl.radial_segments = 8
		pipe.mesh = p_cyl
		pipe.rotation.x = PI * 0.5
		pipe.position = Vector3(psx, torso_size.y * 0.42, 0.0)
		var pipe_mat := _make_metal_mat(VERDIGRIS)
		pipe.set_surface_override_material(0, pipe_mat)
		torso_pivot.add_child(pipe)
		mats.append(pipe_mat)
		# Two pipe couplings (knuckle joints) along each pipe.
		for j_i: int in 2:
			var coupling := MeshInstance3D.new()
			var cb := BoxMesh.new()
			cb.size = Vector3(0.10, 0.10, 0.10)
			coupling.mesh = cb
			var jz: float = (-1.0 if j_i == 0 else 1.0) * torso_size.z * 0.25
			coupling.position = Vector3(psx, torso_size.y * 0.42, jz)
			var c_mat := _make_metal_mat(BRONZE_PATINA)
			coupling.set_surface_override_material(0, c_mat)
			torso_pivot.add_child(coupling)
			mats.append(c_mat)
	# --- Gold-leaf sigil on the BACK of the welder housing. Single
	# horizontal bar so the iconography reads as "ancient mark" on
	# dark backing.
	var sigil_backing := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(torso_size.x * 0.40, torso_size.y * 0.22, 0.04)
	sigil_backing.mesh = sb
	sigil_backing.position = Vector3(0.0, torso_size.y + torso_size.y * 0.10, torso_size.z * 0.26)
	var sigil_back_mat := _make_metal_mat(Color(0.10, 0.09, 0.08))
	sigil_backing.set_surface_override_material(0, sigil_back_mat)
	torso_pivot.add_child(sigil_backing)
	mats.append(sigil_back_mat)
	# Gold sigil bar.
	var sigil := MeshInstance3D.new()
	var sg_box := BoxMesh.new()
	sg_box.size = Vector3(torso_size.x * 0.30, torso_size.y * 0.08, 0.05)
	sigil.mesh = sg_box
	sigil.position = Vector3(0.0, torso_size.y + torso_size.y * 0.10, torso_size.z * 0.29)
	var sigil_mat := StandardMaterial3D.new()
	sigil_mat.albedo_color = GOLD_LEAF
	sigil_mat.emission_enabled = true
	sigil_mat.emission = GOLD_LEAF
	sigil_mat.emission_energy_multiplier = 0.55
	sigil_mat.metallic = 0.85
	sigil_mat.roughness = 0.25
	sigil.set_surface_override_material(0, sigil_mat)
	torso_pivot.add_child(sigil)
	mats.append(sigil_mat)


func _apply_specter_base_overlay(torso_pivot: Node3D, torso_size: Vector3, head_size: Vector3, base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Per 03_factions §"Meridian Visual Language → Specter":
	## "nearly skeletal, with weapon and sensor mounts visibly bolted to
	## a minimal frame". Replaces the stock side-mount single cannon
	## with a long two-handed sniper rifle held across the body, adds
	## sensor pods on the head + opposite shoulder, and paints visible
	## frame ribs on the exposed torso. User feedback 2026-05-14: the
	## rifle must be visibly two-handed so it doesn't read as an
	## oversized pistol.
	# Locate the cannon pivot — Specter overrides cannon_kind to
	# "single_left" so only CannonPivot_0 exists.
	var cannon_pivot: Node3D = torso_pivot.get_node_or_null("CannonPivot_0") as Node3D
	if cannon_pivot:
		# Clear the stock short barrel + muzzle + bore that the medium
		# class shape baked.
		for child: Node in cannon_pivot.get_children():
			child.queue_free()
		# Long thin sniper barrel, mounted forward of the cannon pivot.
		var rifle_len: float = 1.20
		var barrel := MeshInstance3D.new()
		var bbox := BoxMesh.new()
		bbox.size = Vector3(0.06, 0.06, rifle_len)
		barrel.mesh = bbox
		barrel.position.z = -rifle_len * 0.5
		var barrel_mat := _make_metal_mat(Color(0.10, 0.10, 0.12))
		barrel.set_surface_override_material(0, barrel_mat)
		cannon_pivot.add_child(barrel)
		mats.append(barrel_mat)
		# Muzzle block at the rifle's front.
		var muzzle := MeshInstance3D.new()
		var mbox := BoxMesh.new()
		mbox.size = Vector3(0.10, 0.10, 0.10)
		muzzle.mesh = mbox
		muzzle.position.z = -rifle_len - 0.05
		var muzzle_mat := _make_metal_mat(Color(0.06, 0.06, 0.06))
		muzzle.set_surface_override_material(0, muzzle_mat)
		cannon_pivot.add_child(muzzle)
		mats.append(muzzle_mat)
		# Muzzle marker keeps the combat fire-position correct on the
		# rifle's tip — without this the tracer originates from the
		# pivot, ~1.2u behind the visible muzzle.
		var marker := Marker3D.new()
		marker.name = "Muzzle"
		marker.position.z = -rifle_len - 0.10
		cannon_pivot.add_child(marker)
		# Top-mounted scope so the silhouette reads as a sniper rifle,
		# not a generic stick.
		var scope := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.08, 0.08, 0.26)
		scope.mesh = sb
		scope.position = Vector3(0.0, 0.07, -rifle_len * 0.32)
		var scope_mat := _make_metal_mat(Color(0.08, 0.08, 0.10))
		scope.set_surface_override_material(0, scope_mat)
		cannon_pivot.add_child(scope)
		mats.append(scope_mat)
		# Two-handed grip: a front foregrip arm reaches forward from the
		# OPPOSITE shoulder (mirrored across X) to the barrel's midpoint.
		# Built as a child of torso_pivot so the support arm stays
		# planted on the chassis while the cannon pivot recoils on fire.
		var rifle_mid_local: Vector3 = cannon_pivot.position + Vector3(0.0, 0.0, -rifle_len * 0.45)
		var support_shoulder: Vector3 = Vector3(-cannon_pivot.position.x, cannon_pivot.position.y, 0.0)
		var arm_vec: Vector3 = rifle_mid_local - support_shoulder
		var arm_len: float = arm_vec.length()
		if arm_len > 0.05:
			var arm := MeshInstance3D.new()
			var ab := BoxMesh.new()
			ab.size = Vector3(0.08, 0.08, arm_len)
			arm.mesh = ab
			var arm_mid: Vector3 = (support_shoulder + rifle_mid_local) * 0.5
			arm.position = arm_mid
			var arm_mat := _make_metal_mat(base_color)
			arm.set_surface_override_material(0, arm_mat)
			torso_pivot.add_child(arm)
			# look_at after add_child so the node is inside the tree.
			arm.look_at(torso_pivot.to_global(rifle_mid_local), Vector3.UP)
			mats.append(arm_mat)
			# Tiny knuckle pad at the rifle end of the support arm.
			var knuckle := MeshInstance3D.new()
			var kb := BoxMesh.new()
			kb.size = Vector3(0.12, 0.10, 0.12)
			knuckle.mesh = kb
			knuckle.position = rifle_mid_local
			var k_mat := _make_metal_mat(Color(0.10, 0.10, 0.12))
			knuckle.set_surface_override_material(0, k_mat)
			torso_pivot.add_child(knuckle)
			mats.append(k_mat)
	# Head-top sensor pod — short stub cylinder + emissive violet tip
	# so the silhouette reads as "antenna scout" even at full zoom out.
	var sensor_pod := MeshInstance3D.new()
	var sp_cyl := CylinderMesh.new()
	sp_cyl.top_radius = 0.07
	sp_cyl.bottom_radius = 0.09
	sp_cyl.height = 0.20
	sensor_pod.mesh = sp_cyl
	sensor_pod.position = Vector3(0.0, torso_size.y + head_size.y + 0.10, 0.0)
	var sp_mat := _make_metal_mat(Color(0.10, 0.10, 0.12))
	sensor_pod.set_surface_override_material(0, sp_mat)
	torso_pivot.add_child(sensor_pod)
	mats.append(sp_mat)
	var ant_tip := MeshInstance3D.new()
	var at_sph := SphereMesh.new()
	at_sph.radius = 0.06
	at_sph.height = 0.12
	ant_tip.mesh = at_sph
	ant_tip.position = Vector3(0.0, torso_size.y + head_size.y + 0.26, 0.0)
	var at_mat := StandardMaterial3D.new()
	at_mat.albedo_color = SABLE_NEON
	at_mat.emission_enabled = true
	at_mat.emission = SABLE_NEON
	at_mat.emission_energy_multiplier = 2.0
	at_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ant_tip.set_surface_override_material(0, at_mat)
	torso_pivot.add_child(ant_tip)
	mats.append(at_mat)
	# Shoulder-mounted sensor block on the OFF-rifle side (the rifle
	# pivot is on -X, so the sensor lives on +X).
	var s_sensor := MeshInstance3D.new()
	var ss_box := BoxMesh.new()
	ss_box.size = Vector3(0.12, 0.22, 0.14)
	s_sensor.mesh = ss_box
	s_sensor.position = Vector3(torso_size.x * 0.5 + 0.08, torso_size.y * 0.85, 0.0)
	var ss_mat := _make_metal_mat(Color(0.10, 0.10, 0.12))
	s_sensor.set_surface_override_material(0, ss_mat)
	torso_pivot.add_child(s_sensor)
	mats.append(ss_mat)
	# Skeletal-frame ribs visible through "missing" torso panels — three
	# thin emissive uprights on the back so the chassis reads as
	# unfinished armour, matching the doc's "minimal frame" call-out.
	for i: int in 3:
		var rib := MeshInstance3D.new()
		var rb := BoxMesh.new()
		rb.size = Vector3(0.04, torso_size.y * 0.80, 0.04)
		rib.mesh = rb
		var rt: float = float(i - 1)
		rib.position = Vector3(rt * torso_size.x * 0.22, torso_size.y * 0.45, torso_size.z * 0.5 + 0.03)
		var rib_mat := StandardMaterial3D.new()
		rib_mat.albedo_color = SABLE_NEON
		rib_mat.emission_enabled = true
		rib_mat.emission = SABLE_NEON
		rib_mat.emission_energy_multiplier = 0.7
		rib_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rib.set_surface_override_material(0, rib_mat)
		torso_pivot.add_child(rib)
		mats.append(rib_mat)


func _apply_specter_ghost_overlay(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# Stealth-cloak shimmer -- thin emissive cyan strips wrapping the
	# torso edges. Reads as the always-on cloaking variant.
	for edge_y: int in 3:
		var ey: float = (float(edge_y) + 0.5) * (torso_size.y / 3.0)
		var strip := MeshInstance3D.new()
		var s_box := BoxMesh.new()
		s_box.size = Vector3(torso_size.x * 1.04, 0.03, torso_size.z * 1.04)
		strip.mesh = s_box
		strip.position = Vector3(0.0, ey, 0.0)
		var s_mat := StandardMaterial3D.new()
		s_mat.albedo_color = Color(0.55, 0.85, 1.0)
		s_mat.emission_enabled = true
		s_mat.emission = Color(0.55, 0.85, 1.0)
		s_mat.emission_energy_multiplier = 0.9
		s_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		s_mat.albedo_color.a = 0.7
		strip.set_surface_override_material(0, s_mat)
		torso_pivot.add_child(strip)
		mats.append(s_mat)


func _apply_specter_glitch_overlay(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# CRT glitch panels -- two violet-emissive flat panels on the
	# chest + back, each carrying a fine scanline pattern feel via
	# differing emission energies. Reads as the EW / Mesh-projecting
	# variant rather than the cloaking Ghost.
	for side: int in 2:
		var sz: float = 1.0 if side == 0 else -1.0
		var panel := MeshInstance3D.new()
		var p_box := BoxMesh.new()
		p_box.size = Vector3(torso_size.x * 0.7, torso_size.y * 0.55, 0.04)
		panel.mesh = p_box
		panel.position = Vector3(0.0, torso_size.y * 0.55, sz * (torso_size.z * 0.51))
		var p_mat := StandardMaterial3D.new()
		p_mat.albedo_color = Color(0.18, 0.04, 0.22)
		p_mat.emission_enabled = true
		p_mat.emission = SABLE_NEON
		p_mat.emission_energy_multiplier = 1.6
		panel.set_surface_override_material(0, p_mat)
		torso_pivot.add_child(panel)
		mats.append(p_mat)
	# Spinning emitter ring above the head -- a small horizontal
	# torus that spins via _process. Cheap to leave un-animated for
	# now since the emission energy carries most of the read.
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.20
	torus.outer_radius = 0.26
	torus.rings = 8
	torus.ring_segments = 18
	ring.mesh = torus
	ring.position = Vector3(0.0, torso_size.y + 0.35, 0.0)
	var r_mat := StandardMaterial3D.new()
	r_mat.albedo_color = SABLE_NEON
	r_mat.emission_enabled = true
	r_mat.emission = SABLE_NEON
	r_mat.emission_energy_multiplier = 2.0
	r_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.set_surface_override_material(0, r_mat)
	torso_pivot.add_child(ring)
	mats.append(r_mat)


func _apply_jackal_base_overlay(torso_pivot: Node3D, torso_size: Vector3, base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Fast-skirmisher pass: drop the single-right cannon down to hip
	## level (so the gun reads as held-at-hip, not shouldered), lengthen
	## the barrel, and add an asymmetric antenna fin on the LEFT
	## shoulder so the chassis silhouette is visibly unbalanced —
	## matches Sable's "deliberately asymmetric" design language.
	## Stacks on top of the Sable silhouette pass and any branch overlay.
	var cannon_pivot: Node3D = torso_pivot.get_node_or_null("CannonPivot_1") as Node3D
	if cannon_pivot:
		# Mid-chest level — high enough that the barrel reads as "held
		# straight ahead" instead of "pointed down at the floor", but
		# still distinct from the shoulder default (torso_size.y * 0.7)
		# so the Jackal silhouette reads as a sprinter shouldering its
		# rifle low. Hip-level (0.22) made the gun visibly tilt below
		# horizontal toward standing-height enemies (playtest 2026-05-15).
		cannon_pivot.position.y = torso_size.y * 0.50
		# Clear any inherited rotation so the rifle points dead ahead
		# along -Z — defensive reset in case a base-shape pass tilted
		# the pivot.
		cannon_pivot.rotation = Vector3.ZERO
		# Lengthen the existing barrel into a forward-projected rifle.
		# Walk the pivot's children: the existing barrel is the BoxMesh
		# child at position.z negative. Replace with a longer one.
		for child: Node in cannon_pivot.get_children():
			if child is MeshInstance3D:
				var mesh_node: MeshInstance3D = child as MeshInstance3D
				if mesh_node.mesh is BoxMesh:
					var bm: BoxMesh = mesh_node.mesh as BoxMesh
					# Only rebuild the long barrel-shaped meshes (z dominant),
					# leave the muzzle cap (cubic) alone.
					var s: Vector3 = bm.size
					if s.z > s.x * 1.5:
						bm.size = Vector3(s.x * 0.85, s.y * 0.85, s.z * 1.45)
						mesh_node.position.z = -bm.size.z * 0.5
			elif child is Marker3D:
				# Push the muzzle marker forward to match the longer barrel.
				(child as Marker3D).position.z *= 1.45
	# Asymmetric antenna fin on the LEFT shoulder (cannon is on right).
	var fin := MeshInstance3D.new()
	var fb := BoxMesh.new()
	fb.size = Vector3(0.05, torso_size.y * 0.45, 0.22)
	fin.mesh = fb
	fin.position = Vector3(-torso_size.x * 0.40, torso_size.y * 0.85, 0.0)
	fin.rotation.z = deg_to_rad(-12.0)
	var fin_mat := _make_metal_mat(base_color)
	fin.set_surface_override_material(0, fin_mat)
	torso_pivot.add_child(fin)
	mats.append(fin_mat)
	# Small violet emissive tip at the fin's top — Sable signal-mast read.
	var tip := MeshInstance3D.new()
	var ts := SphereMesh.new()
	ts.radius = 0.05
	ts.height = 0.10
	tip.mesh = ts
	tip.position = Vector3(
		-torso_size.x * 0.40 + sin(deg_to_rad(-12.0)) * (torso_size.y * 0.22),
		torso_size.y * 0.85 + cos(deg_to_rad(-12.0)) * (torso_size.y * 0.22),
		0.0,
	)
	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = SABLE_NEON
	tip_mat.emission_enabled = true
	tip_mat.emission = SABLE_NEON
	tip_mat.emission_energy_multiplier = 2.2
	tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tip.set_surface_override_material(0, tip_mat)
	torso_pivot.add_child(tip)
	mats.append(tip_mat)


func _apply_jackal_striker_overlay(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# Overcharged primary barrels -- glowing violet rings around the
	# muzzle ends so the Striker reads as 'pumped-up shooter'. Adds
	# a chest energy pack with two cooling fins for silhouette.
	var pack := MeshInstance3D.new()
	var p_box := BoxMesh.new()
	p_box.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.30, 0.18)
	pack.mesh = p_box
	pack.position = Vector3(0.0, torso_size.y * 0.65, torso_size.z * 0.50)
	pack.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.13)))
	torso_pivot.add_child(pack)
	# Two cooling fins jutting out the sides of the pack.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var fin := MeshInstance3D.new()
		var f_box := BoxMesh.new()
		f_box.size = Vector3(0.06, 0.30, 0.20)
		fin.mesh = f_box
		fin.position = Vector3(sx * torso_size.x * 0.36, torso_size.y * 0.65, torso_size.z * 0.50)
		var f_mat := StandardMaterial3D.new()
		f_mat.albedo_color = SABLE_NEON.darkened(0.30)
		f_mat.emission_enabled = true
		f_mat.emission = SABLE_NEON
		f_mat.emission_energy_multiplier = 1.4
		fin.set_surface_override_material(0, f_mat)
		torso_pivot.add_child(fin)
		mats.append(f_mat)


func _apply_jackal_widow_overlay(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# Spider-leg accents -- four slim angled struts off the back of
	# the torso, plus a tall sniper sight on the right shoulder.
	# Sells the Widow's long-range coilgun-needle identity.
	for i: int in 4:
		var ang_deg: float = -45.0 + float(i) * 30.0
		var ang: float = deg_to_rad(ang_deg)
		var leg := MeshInstance3D.new()
		var l_box := BoxMesh.new()
		l_box.size = Vector3(0.05, 0.50, 0.05)
		leg.mesh = l_box
		leg.position = Vector3(0.0, torso_size.y * 0.85, -torso_size.z * 0.40)
		leg.rotation = Vector3(deg_to_rad(40.0), 0.0, ang)
		leg.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.13)))
		torso_pivot.add_child(leg)
	# Sniper sight tube on the right shoulder.
	var sight := MeshInstance3D.new()
	var s_cyl := CylinderMesh.new()
	s_cyl.top_radius = 0.05
	s_cyl.bottom_radius = 0.05
	s_cyl.height = 0.40
	s_cyl.radial_segments = 10
	sight.mesh = s_cyl
	sight.rotation.x = PI * 0.5
	sight.position = Vector3(torso_size.x * 0.42, torso_size.y * 0.95, 0.10)
	sight.set_surface_override_material(0, _make_metal_mat(Color(0.08, 0.08, 0.10)))
	torso_pivot.add_child(sight)
	# Violet eye on the front of the sight.
	var eye := MeshInstance3D.new()
	var e_sph := SphereMesh.new()
	e_sph.radius = 0.05
	e_sph.height = 0.10
	eye.mesh = e_sph
	eye.position = Vector3(torso_size.x * 0.42, torso_size.y * 0.95, 0.32)
	var e_mat := StandardMaterial3D.new()
	e_mat.albedo_color = SABLE_NEON
	e_mat.emission_enabled = true
	e_mat.emission = SABLE_NEON
	e_mat.emission_energy_multiplier = 2.4
	eye.set_surface_override_material(0, e_mat)
	torso_pivot.add_child(eye)
	mats.append(e_mat)


func _apply_forgemaster_foreman_extras(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# Repair-coil halo around the chest -- the Foreman branch leans
	# into the healing identity, so a green-tinted aura ring sits in
	# front of the standard Forgemaster overlay's amber chest ring
	# to differentiate it visually.
	var coil := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = torso_size.x * 0.62
	t.outer_radius = torso_size.x * 0.74
	t.rings = 24
	t.ring_segments = 6
	coil.mesh = t
	coil.position = Vector3(0.0, torso_size.y * 0.40, torso_size.z * 0.05)
	coil.rotation.x = PI * 0.5
	var c_mat := StandardMaterial3D.new()
	c_mat.albedo_color = Color(0.30, 0.95, 0.55)
	c_mat.emission_enabled = true
	c_mat.emission = Color(0.30, 0.95, 0.55)
	c_mat.emission_energy_multiplier = 1.6
	c_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	coil.set_surface_override_material(0, c_mat)
	torso_pivot.add_child(coil)
	mats.append(c_mat)
	# Worker-arm extra -- a stubby tool arm jutting from the right
	# shoulder so the silhouette differs from the base Forgemaster.
	var arm := MeshInstance3D.new()
	var a_box := BoxMesh.new()
	a_box.size = Vector3(0.10, 0.10, 0.55)
	arm.mesh = a_box
	arm.position = Vector3(torso_size.x * 0.55, torso_size.y * 0.65, torso_size.z * 0.15)
	arm.rotation.y = deg_to_rad(20.0)
	arm.set_surface_override_material(0, _make_metal_mat(Color(0.20, 0.18, 0.16)))
	torso_pivot.add_child(arm)
	# Welding torch tip -- bright cyan emissive cone at the arm's end.
	var torch := MeshInstance3D.new()
	var t_sph := SphereMesh.new()
	t_sph.radius = 0.06
	t_sph.height = 0.12
	torch.mesh = t_sph
	torch.position = Vector3(torso_size.x * 0.55 + 0.10, torso_size.y * 0.65, torso_size.z * 0.15 + 0.34)
	var to_mat := StandardMaterial3D.new()
	to_mat.albedo_color = Color(0.55, 0.95, 1.0)
	to_mat.emission_enabled = true
	to_mat.emission = Color(0.55, 0.95, 1.0)
	to_mat.emission_energy_multiplier = 2.4
	torch.set_surface_override_material(0, to_mat)
	torso_pivot.add_child(torch)
	mats.append(to_mat)


func _apply_forgemaster_reactor_extras(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# Reactor coil ring -- a tall vertical coil tower sitting on the
	# back of the torso, with three glowing horizontal rings stacked
	# along it. Reads as 'this one runs the damage-buff aura' rather
	# than the healing Foreman.
	var tower := MeshInstance3D.new()
	var t_box := BoxMesh.new()
	t_box.size = Vector3(0.20, 1.10, 0.20)
	tower.mesh = t_box
	tower.position = Vector3(0.0, torso_size.y + 0.55, -torso_size.z * 0.45)
	tower.set_surface_override_material(0, _make_metal_mat(Color(0.18, 0.16, 0.14)))
	torso_pivot.add_child(tower)
	for ring_i: int in 3:
		var ring := MeshInstance3D.new()
		var rt := TorusMesh.new()
		rt.inner_radius = 0.18
		rt.outer_radius = 0.26
		rt.rings = 16
		rt.ring_segments = 6
		ring.mesh = rt
		ring.rotation.x = PI * 0.5
		ring.position = Vector3(0.0, torso_size.y + 0.20 + float(ring_i) * 0.40, -torso_size.z * 0.45)
		var r_mat := StandardMaterial3D.new()
		r_mat.albedo_color = Color(1.0, 0.55, 0.18)
		r_mat.emission_enabled = true
		r_mat.emission = Color(1.0, 0.55, 0.18)
		r_mat.emission_energy_multiplier = 2.2
		r_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ring.set_surface_override_material(0, r_mat)
		torso_pivot.add_child(ring)
		mats.append(r_mat)
	# Hot-orange beacon on the tower tip.
	var beacon := MeshInstance3D.new()
	var b_sph := SphereMesh.new()
	b_sph.radius = 0.10
	b_sph.height = 0.20
	beacon.mesh = b_sph
	beacon.position = Vector3(0.0, torso_size.y + 1.20, -torso_size.z * 0.45)
	var b_mat := StandardMaterial3D.new()
	b_mat.albedo_color = Color(1.0, 0.45, 0.15)
	b_mat.emission_enabled = true
	b_mat.emission = Color(1.0, 0.45, 0.15)
	b_mat.emission_energy_multiplier = 2.6
	beacon.set_surface_override_material(0, b_mat)
	torso_pivot.add_child(beacon)
	mats.append(b_mat)


func _apply_harbinger_base_overlay(torso_pivot: Node3D, torso_size: Vector3, base_color: Color, mats: Array[StandardMaterial3D]) -> void:
	## Missile-puma silhouette pass (playtest 2026-05-15):
	## the previous version was a flat chest pod + boxy backpack with
	## little directional read. Now the front of the torso reads as a
	## predator face — armoured brow plate over a 3×2 missile battery,
	## twin sensor "horns" on the brow, side flank armour that tapers
	## front-to-back so the player can tell where the front is, plus
	## visible knee bracing on each leg. Drone bay stays on the back.
	const SABLE_VIOLET: Color = Color(0.78, 0.42, 1.0)

	# --- Chest missile battery: 3×2 forward-facing tubes inside an
	# armoured housing that wraps the front of the torso.
	var pod_root := Node3D.new()
	pod_root.name = "ChestMissilePod"
	pod_root.position = Vector3(0.0, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.12)
	torso_pivot.add_child(pod_root)
	# Armour housing — wider + taller than before so the missile face
	# dominates the front silhouette.
	var housing := MeshInstance3D.new()
	var hb := BoxMesh.new()
	hb.size = Vector3(torso_size.x * 0.80, torso_size.y * 0.55, 0.22)
	housing.mesh = hb
	housing.position = Vector3(0.0, 0.0, 0.12)
	var housing_mat := _make_metal_mat(Color(0.12, 0.12, 0.15))
	housing.set_surface_override_material(0, housing_mat)
	pod_root.add_child(housing)
	mats.append(housing_mat)
	# Brow plate — angled armoured shelf overhanging the missile tubes.
	# This is the "predator face" read: a heavy ridge that tilts the
	# silhouette downward, like a beast staring forward.
	var brow := MeshInstance3D.new()
	var br_box := BoxMesh.new()
	br_box.size = Vector3(torso_size.x * 0.92, 0.14, 0.40)
	brow.mesh = br_box
	brow.rotate_object_local(Vector3.RIGHT, deg_to_rad(-22.0))
	brow.position = Vector3(0.0, torso_size.y * 0.32, 0.05)
	var brow_mat := _make_metal_mat(Color(0.10, 0.10, 0.12))
	brow.set_surface_override_material(0, brow_mat)
	pod_root.add_child(brow)
	mats.append(brow_mat)
	# 3×2 tube grid.
	var tube_len: float = 0.50
	var tube_radius: float = 0.075
	for gx: int in 3:
		for gy: int in 2:
			var tx: float = (float(gx) - 1.0) * torso_size.x * 0.22
			var ty: float = (-1.0 if gy == 0 else 1.0) * torso_size.y * 0.14
			var tube := MeshInstance3D.new()
			var tc := CylinderMesh.new()
			tc.top_radius = tube_radius
			tc.bottom_radius = tube_radius
			tc.height = tube_len
			tc.radial_segments = 10
			tube.mesh = tc
			tube.rotation.x = PI * 0.5
			tube.position = Vector3(tx, ty, -tube_len * 0.5)
			var tube_mat := _make_metal_mat(Color(0.08, 0.08, 0.10))
			tube.set_surface_override_material(0, tube_mat)
			pod_root.add_child(tube)
			mats.append(tube_mat)
			# Glowing bore at each tube mouth — emissive violet so the
			# 6 muzzle dots read as "loaded missile launchers" from above.
			var bore := MeshInstance3D.new()
			var bcyl := CylinderMesh.new()
			bcyl.top_radius = tube_radius * 0.55
			bcyl.bottom_radius = tube_radius * 0.55
			bcyl.height = 0.05
			bcyl.radial_segments = 8
			bore.mesh = bcyl
			bore.rotation.x = PI * 0.5
			bore.position = Vector3(tx, ty, -tube_len - 0.03)
			var bore_mat := StandardMaterial3D.new()
			bore_mat.albedo_color = SABLE_VIOLET
			bore_mat.emission_enabled = true
			bore_mat.emission = SABLE_VIOLET
			bore_mat.emission_energy_multiplier = 1.4
			bore_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			bore.set_surface_override_material(0, bore_mat)
			pod_root.add_child(bore)
			mats.append(bore_mat)
	# Twin sensor "horns" jutting forward from the brow corners — tilted
	# slim cylinders that read as predator antennae / targeting eyes.
	for horn_side: int in 2:
		var hsx: float = -1.0 if horn_side == 0 else 1.0
		var horn := MeshInstance3D.new()
		var hc := CylinderMesh.new()
		hc.top_radius = 0.025
		hc.bottom_radius = 0.05
		hc.height = 0.36
		hc.radial_segments = 6
		horn.mesh = hc
		horn.rotation = Vector3(deg_to_rad(72.0), 0.0, hsx * deg_to_rad(-15.0))
		horn.position = Vector3(hsx * torso_size.x * 0.40, torso_size.y * 0.45, -0.12)
		horn.set_surface_override_material(0, brow_mat)
		torso_pivot.add_child(horn)
		# Glowing tip — predator eye dot.
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = 0.04
		es.height = 0.08
		eye.mesh = es
		eye.position = Vector3(hsx * torso_size.x * 0.40, torso_size.y * 0.55, -0.34)
		var eye_mat := StandardMaterial3D.new()
		eye_mat.albedo_color = SABLE_VIOLET
		eye_mat.emission_enabled = true
		eye_mat.emission = SABLE_VIOLET
		eye_mat.emission_energy_multiplier = 2.4
		eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		eye.set_surface_override_material(0, eye_mat)
		torso_pivot.add_child(eye)
		mats.append(eye_mat)
	# Tapered side flank armour — wider at the front, narrower at the
	# back, so the silhouette has clear directional taper. Two slabs
	# per side angled inward toward the rear.
	for flank_side: int in 2:
		var fxs: float = -1.0 if flank_side == 0 else 1.0
		# Front flank — bigger.
		var flank_f := MeshInstance3D.new()
		var ff_box := BoxMesh.new()
		ff_box.size = Vector3(0.18, torso_size.y * 0.55, torso_size.z * 0.50)
		flank_f.mesh = ff_box
		flank_f.position = Vector3(fxs * (torso_size.x * 0.55 + 0.04), torso_size.y * 0.42, -torso_size.z * 0.20)
		flank_f.rotation.y = -fxs * deg_to_rad(8.0)
		flank_f.set_surface_override_material(0, _make_metal_mat(base_color.darkened(0.10)))
		torso_pivot.add_child(flank_f)
		# Rear flank — smaller, tucked inward.
		var flank_r := MeshInstance3D.new()
		var fr_box := BoxMesh.new()
		fr_box.size = Vector3(0.14, torso_size.y * 0.40, torso_size.z * 0.40)
		flank_r.mesh = fr_box
		flank_r.position = Vector3(fxs * (torso_size.x * 0.42), torso_size.y * 0.40, torso_size.z * 0.25)
		flank_r.rotation.y = fxs * deg_to_rad(14.0)
		flank_r.set_surface_override_material(0, _make_metal_mat(base_color.darkened(0.18)))
		torso_pivot.add_child(flank_r)
	# Visible knee bracing — extra armour bracket at hip-leg junction
	# on each side. Adds the "articulated leg" read without needing
	# direct access to the base mech's leg pivots.
	for knee_side: int in 2:
		var kxs: float = -1.0 if knee_side == 0 else 1.0
		var knee := MeshInstance3D.new()
		var kn_box := BoxMesh.new()
		kn_box.size = Vector3(0.20, 0.22, 0.20)
		knee.mesh = kn_box
		knee.position = Vector3(kxs * torso_size.x * 0.32, -torso_size.y * 0.05, 0.0)
		knee.rotation.z = kxs * deg_to_rad(-10.0)
		knee.set_surface_override_material(0, _make_metal_mat(base_color.darkened(0.05)))
		torso_pivot.add_child(knee)

	# Pod muzzle marker so primary tracers visibly leave the battery.
	var pod_muzzle := Marker3D.new()
	pod_muzzle.name = "Muzzle"
	pod_muzzle.position = Vector3(0.0, 0.0, -tube_len - 0.10)
	pod_root.add_child(pod_muzzle)

	# --- Backpack drone bay: tall slab on the back with 4 visible
	# launch hatches lit violet. The DroneBay Marker3D anchor lives on
	# the unit root (created in _build_squad_visuals) so its world
	# position needs to match the hatch zone. We update that marker
	# below to align with this new backpack.
	var bay_root := Node3D.new()
	bay_root.name = "DroneBackpack"
	bay_root.position = Vector3(0.0, torso_size.y * 0.78, torso_size.z * 0.5 + 0.12)
	torso_pivot.add_child(bay_root)
	# Backpack slab — the visible housing.
	var pack := MeshInstance3D.new()
	var pkb := BoxMesh.new()
	pkb.size = Vector3(torso_size.x * 0.85, torso_size.y * 0.70, 0.30)
	pack.mesh = pkb
	pack.position = Vector3(0.0, 0.0, 0.15)
	var pack_mat := _make_metal_mat(Color(0.12, 0.12, 0.15))
	pack.set_surface_override_material(0, pack_mat)
	bay_root.add_child(pack)
	mats.append(pack_mat)
	# Four hatches in a 2×2 grid on the back face of the backpack.
	for hx: int in 2:
		for hy: int in 2:
			var fx: float = (-1.0 if hx == 0 else 1.0) * torso_size.x * 0.22
			var fy: float = (-1.0 if hy == 0 else 1.0) * torso_size.y * 0.18
			# Hatch frame.
			var frame := MeshInstance3D.new()
			var fb := BoxMesh.new()
			fb.size = Vector3(0.18, 0.18, 0.04)
			frame.mesh = fb
			frame.position = Vector3(fx, fy, 0.32)
			var frame_mat := _make_metal_mat(Color(0.06, 0.06, 0.08))
			frame.set_surface_override_material(0, frame_mat)
			bay_root.add_child(frame)
			mats.append(frame_mat)
			# Violet status light inset.
			var light := MeshInstance3D.new()
			var lb := BoxMesh.new()
			lb.size = Vector3(0.12, 0.12, 0.02)
			light.mesh = lb
			light.position = Vector3(fx, fy, 0.345)
			var l_mat := StandardMaterial3D.new()
			l_mat.albedo_color = SABLE_NEON
			l_mat.emission_enabled = true
			l_mat.emission = SABLE_NEON
			l_mat.emission_energy_multiplier = 1.8
			l_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			light.set_surface_override_material(0, l_mat)
			bay_root.add_child(light)
			mats.append(l_mat)


func _apply_harbinger_overseer_overlay(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# Bigger drone bay on the back -- a wider housing with two
	# violet-emissive launch tubes facing aft. Reads as the variant
	# that pumps out more drones.
	var bay := MeshInstance3D.new()
	var b_box := BoxMesh.new()
	b_box.size = Vector3(torso_size.x * 0.85, torso_size.y * 0.45, 0.50)
	bay.mesh = b_box
	bay.position = Vector3(0.0, torso_size.y * 0.65, -torso_size.z * 0.55)
	bay.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.13)))
	torso_pivot.add_child(bay)
	# Two launch tubes facing aft, each with a violet glow inside.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var tube := MeshInstance3D.new()
		var tc := CylinderMesh.new()
		tc.top_radius = 0.10
		tc.bottom_radius = 0.10
		tc.height = 0.30
		tc.radial_segments = 12
		tube.mesh = tc
		tube.rotation.x = PI * 0.5
		tube.position = Vector3(sx * torso_size.x * 0.25, torso_size.y * 0.65, -torso_size.z * 0.78)
		tube.set_surface_override_material(0, _make_metal_mat(Color(0.06, 0.06, 0.08)))
		torso_pivot.add_child(tube)
		# Violet inner glow.
		var glow := MeshInstance3D.new()
		var gc := CylinderMesh.new()
		gc.top_radius = 0.08
		gc.bottom_radius = 0.08
		gc.height = 0.04
		gc.radial_segments = 12
		glow.mesh = gc
		glow.rotation.x = PI * 0.5
		glow.position = Vector3(sx * torso_size.x * 0.25, torso_size.y * 0.65, -torso_size.z * 0.92)
		var g_mat := StandardMaterial3D.new()
		g_mat.albedo_color = SABLE_NEON
		g_mat.emission_enabled = true
		g_mat.emission = SABLE_NEON
		g_mat.emission_energy_multiplier = 2.4
		glow.set_surface_override_material(0, g_mat)
		torso_pivot.add_child(glow)
		mats.append(g_mat)


func _apply_harbinger_swarm_marshal_overlay(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	# Command spire on top of the torso -- a tall slim antenna with a
	# pulsing violet beacon at the tip. Reads as the coordination /
	# command variant rather than the production-focused Overseer.
	var spire := MeshInstance3D.new()
	var s_box := BoxMesh.new()
	s_box.size = Vector3(0.10, 1.20, 0.10)
	spire.mesh = s_box
	spire.position = Vector3(0.0, torso_size.y + 0.60, 0.0)
	spire.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.13)))
	torso_pivot.add_child(spire)
	# Beacon at the tip.
	var beacon := MeshInstance3D.new()
	var b_sph := SphereMesh.new()
	b_sph.radius = 0.12
	b_sph.height = 0.24
	beacon.mesh = b_sph
	beacon.position = Vector3(0.0, torso_size.y + 1.30, 0.0)
	var bm: StandardMaterial3D = StandardMaterial3D.new()
	bm.albedo_color = SABLE_NEON
	bm.emission_enabled = true
	bm.emission = SABLE_NEON
	bm.emission_energy_multiplier = 2.8
	beacon.set_surface_override_material(0, bm)
	torso_pivot.add_child(beacon)
	mats.append(bm)
	# Two coordination antennae -- slim diagonal struts off the
	# shoulders that read as drone-formation broadcast aerials.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var ant := MeshInstance3D.new()
		var a_box := BoxMesh.new()
		a_box.size = Vector3(0.04, 0.65, 0.04)
		ant.mesh = a_box
		ant.position = Vector3(sx * torso_size.x * 0.45, torso_size.y + 0.15, -torso_size.z * 0.10)
		ant.rotation = Vector3(deg_to_rad(-25.0), 0.0, sx * deg_to_rad(15.0))
		ant.set_surface_override_material(0, _make_metal_mat(Color(0.10, 0.10, 0.13)))
		torso_pivot.add_child(ant)


func _apply_courier_infiltrator_overlay(member: Node3D, mats: Array[StandardMaterial3D]) -> void:
	# Stealth tarp draped over the hull -- a slightly larger, matte,
	# mottled-darker box sitting on top of the chassis. Reads as
	# 'this one wears a camo cover' rather than the bare Sensor
	# Carrier hull.
	var tarp := MeshInstance3D.new()
	var t_box := BoxMesh.new()
	t_box.size = Vector3(2.30, 0.18, 2.20)
	tarp.mesh = t_box
	tarp.position = Vector3(0.0, 1.10, 0.10)
	tarp.rotation.x = randf_range(-0.04, 0.04)
	tarp.rotation.z = randf_range(-0.04, 0.04)
	var t_mat := StandardMaterial3D.new()
	t_mat.albedo_color = Color(0.10, 0.10, 0.12, 1.0)
	t_mat.roughness = 1.0
	t_mat.metallic = 0.0
	tarp.set_surface_override_material(0, t_mat)
	member.add_child(tarp)
	mats.append(t_mat)
	# Two faint cyan optical-camo strips wrapping the tarp's edges so
	# the silhouette catches a hint of light at zoom.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var strip := MeshInstance3D.new()
		var s_box := BoxMesh.new()
		s_box.size = Vector3(0.04, 0.04, 2.10)
		strip.mesh = s_box
		strip.position = Vector3(sx * 1.10, 1.18, 0.10)
		var s_mat := StandardMaterial3D.new()
		s_mat.albedo_color = Color(0.30, 0.78, 1.0)
		s_mat.emission_enabled = true
		s_mat.emission = Color(0.30, 0.78, 1.0)
		s_mat.emission_energy_multiplier = 0.7
		strip.set_surface_override_material(0, s_mat)
		member.add_child(strip)
		mats.append(s_mat)


func _apply_courier_sensor_overlay(member: Node3D, mats: Array[StandardMaterial3D]) -> void:
	# Sensor dish array on the rear deck -- a central tilted dish
	# flanked by two slim antennae. Reads as the Mesh-providing
	# sensor variant rather than the stealth Infiltrator.
	var mast := MeshInstance3D.new()
	var m_box := BoxMesh.new()
	m_box.size = Vector3(0.08, 0.55, 0.08)
	mast.mesh = m_box
	mast.position = Vector3(0.0, 1.30, -0.85)
	mast.set_surface_override_material(0, _make_metal_mat(Color(0.12, 0.12, 0.14)))
	member.add_child(mast)
	# Central dish.
	var dish := MeshInstance3D.new()
	var d_cyl := CylinderMesh.new()
	d_cyl.top_radius = 0.30
	d_cyl.bottom_radius = 0.30
	d_cyl.height = 0.06
	d_cyl.radial_segments = 18
	dish.mesh = d_cyl
	dish.rotation.x = deg_to_rad(-25.0)
	dish.position = Vector3(0.0, 1.55, -0.85)
	var d_mat := StandardMaterial3D.new()
	d_mat.albedo_color = Color(0.20, 0.20, 0.22)
	d_mat.emission_enabled = true
	d_mat.emission = SABLE_NEON
	d_mat.emission_energy_multiplier = 0.4
	dish.set_surface_override_material(0, d_mat)
	member.add_child(dish)
	mats.append(d_mat)
	# Two slim flanking antennae.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var ant := MeshInstance3D.new()
		var a_box := BoxMesh.new()
		a_box.size = Vector3(0.05, 0.45, 0.05)
		ant.mesh = a_box
		ant.position = Vector3(sx * 0.55, 1.30, -0.65)
		ant.rotation.z = sx * deg_to_rad(8.0)
		ant.set_surface_override_material(0, _make_metal_mat(Color(0.12, 0.12, 0.14)))
		member.add_child(ant)
		# Violet tip light.
		var tip := MeshInstance3D.new()
		var ts := SphereMesh.new()
		ts.radius = 0.05
		ts.height = 0.10
		tip.mesh = ts
		tip.position = Vector3(sx * 0.62, 1.55, -0.65)
		var tm := StandardMaterial3D.new()
		tm.albedo_color = SABLE_NEON
		tm.emission_enabled = true
		tm.emission = SABLE_NEON
		tm.emission_energy_multiplier = 2.0
		tip.set_surface_override_material(0, tm)
		member.add_child(tip)
		mats.append(tm)


func _maybe_override_shape_for_unit(base: Dictionary) -> Dictionary:
	## Per-unit shape overrides applied on top of the CLASS_SHAPES
	## baseline. Each branch returns a shallow-duplicated dictionary
	## with the changed fields set, so other heavy-class units stay
	## on the unmodified profile.
	if not stats:
		return base
	if stats.unit_name.findn("Breacher") >= 0:
		# Breacher Tank squad of 3. Chassis at the default visual scale
		# was ~2.91u wide; with the 0.9× tank scaling applied in the
		# build dispatcher the chassis is now ~2.62u wide. Spacing
		# tightens to match: 2.85u between centres = ~0.23u gap, still
		# visibly distinct without tracks clipping.
		var ovb: Dictionary = base.duplicate()
		ovb["formation_spacing"] = 2.85
		return ovb
	if stats.unit_name.findn("Harbinger") >= 0:
		var ovh: Dictionary = base.duplicate()
		# Drone-carrier silhouette per 03_factions §3.3: "visible drone
		# bays as backpack modules". Remove the shoulder cannons — the
		# Harbinger's primary is a chest-mounted missile pod (added by
		# _apply_harbinger_base_overlay), not paired shoulder guns.
		ovh["cannon_kind"] = "none"
		# Harbinger ('NODE Command Carrier') reads as the heavy
		# command frame for the Sable army. +5% on every dimension
		# so it visibly out-bulks a Bulwark squad, then an
		# additional +5% on torso.x specifically so the chassis
		# looks broader (carrier deck) rather than just uniformly
		# scaled. hip_y comes up with the leg scale so the
		# silhouette stays proportional and the model isn't sunk
		# into the ground.
		var leg: Vector3 = ovh["leg"] as Vector3
		ovh["leg"] = leg * 1.05
		ovh["hip_y"] = (ovh["hip_y"] as float) * 1.05
		var torso: Vector3 = ovh["torso"] as Vector3
		# Uniform 5% scale + an extra 5% on width.
		ovh["torso"] = Vector3(torso.x * 1.05 * 1.05, torso.y * 1.05, torso.z * 1.05)
		var head: Vector3 = ovh["head"] as Vector3
		ovh["head"] = head * 1.05
		# Cannon scales with chassis; muzzle alignment carries
		# through automatically.
		var cannon: Vector3 = ovh["cannon"] as Vector3
		ovh["cannon"] = cannon * 1.05
		ovh["cannon_x"] = (ovh["cannon_x"] as float) * 1.05
		# Wider footprint demands a touch more spacing in formation.
		ovh["formation_spacing"] = (ovh["formation_spacing"] as float) * 1.06
		return ovh
	if stats.unit_name == "Inquisitor Tank":
		# Heliarch medium hover-tank. Chassis is wider than the medium
		# baseline (twin hover skirts at ±1.05 → ~2.80u total width)
		# so the default medium spacing packs the squad into an
		# overlapping cluster. Bumped to 3.0 in an earlier pass, then
		# tightened to 2.5 per playtest 2026-05-19 ("formation can be
		# a little bit tighter"). The new single-disc hover-base
		# replaced the wider twin-skirts, so the chassis footprint is
		# smaller now and 2.5u between centres keeps the squad
		# visibly separated without leaving them feeling spread out.
		var ovit: Dictionary = base.duplicate()
		ovit["formation_spacing"] = 2.5
		ovit["cannon_kind"] = "none"
		return ovit
	if stats.unit_name == "Wächter" or stats.unit_name == "Wachter":
		# Inheritor medium tank-vehicle. Slow armored chassis; the
		# default medium spacing leaves the 3-member row touching.
		# 2.8u between centres gives a visible gap without making the
		# squad feel split.
		var ovwc: Dictionary = base.duplicate()
		ovwc["formation_spacing"] = 2.8
		return ovwc
	if stats.unit_name == "Stahlyokai" or stats.unit_name.findn("Stahlyokai") >= 0:
		# Inheritor adaptive medium biped. Squad of 2 with a wider
		# adaptive chassis — bump spacing so the pair reads as two
		# separate frames rather than one wide silhouette.
		var ovsy: Dictionary = base.duplicate()
		ovsy["formation_spacing"] = 2.4
		return ovsy
	if stats.unit_name == "Cremator":
		# Heliarch medium assault. No shoulder cannons — overlay mounts
		# a long forward-projected Heat Lance and a bigger chest furnace
		# than Matador. Standard medium chassis proportions kept.
		var ovcr: Dictionary = base.duplicate()
		ovcr["cannon_kind"] = "none"
		var t_cr: Vector3 = ovcr["torso"] as Vector3
		ovcr["torso"] = Vector3(t_cr.x * 0.95, t_cr.y * 1.05, t_cr.z * 0.95)
		return ovcr
	if stats.unit_name == "Matador":
		# Heliarch light harasser. Slim vertical biped (docs: "vertical,
		# asymmetric"), no shoulder cannons — overlay mounts an
		# incendiary cluster launcher forward + a tall exposed reactor
		# core at the spine (per 03_factions §3.4: "light mechs have
		# exposed reactor cores at the spine").
		var ovmt: Dictionary = base.duplicate()
		ovmt["cannon_kind"] = "none"
		var t_mt: Vector3 = ovmt["torso"] as Vector3
		ovmt["torso"] = Vector3(t_mt.x * 0.82, t_mt.y * 1.10, t_mt.z * 0.85)
		var l_mt: Vector3 = ovmt["leg"] as Vector3
		ovmt["leg"] = Vector3(l_mt.x * 0.90, l_mt.y * 1.05, l_mt.z * 0.90)
		return ovmt
	if stats.unit_name == "Stoker":
		# Heliarch engineer — reactor-priest. Keep biped + spider legs;
		# overlay adds the hooded cowl + brass chain. Slim torso for
		# the vertical Heliarch silhouette per docs §3.4.
		var ovst: Dictionary = base.duplicate()
		ovst["leg_kind"] = "spider"
		ovst["cannon_kind"] = "claw"
		var t_st: Vector3 = ovst["torso"] as Vector3
		ovst["torso"] = Vector3(t_st.x * 0.82, t_st.y * 1.05, t_st.z * 0.85)
		return ovst
	if stats.unit_name == "Restorer" or stats.unit_name == "Restorator":
		# Inheritor engineer per user pick 2026-05-14 ("quadrupedal
		# restoration crab"). Wider flatter torso, lower hip, four
		# spider legs (engineer baseline already), dorsal welder rig
		# (added by overlay below), no shoulder cannons — the claw
		# arms double as welding mandibles.
		var ovrs: Dictionary = base.duplicate()
		ovrs["leg_kind"] = "spider"
		ovrs["cannon_kind"] = "claw"
		var t_rs: Vector3 = ovrs["torso"] as Vector3
		# Crab silhouette: wider in X, longer in Z, flatter in Y.
		ovrs["torso"] = Vector3(t_rs.x * 1.50, t_rs.y * 0.65, t_rs.z * 1.40)
		# Sit closer to the ground.
		ovrs["hip_y"] = (ovrs["hip_y"] as float) * 0.65
		# Smaller head — the dorsal welder housing replaces the head as
		# the visual top feature.
		var h_rs: Vector3 = ovrs["head"] as Vector3
		ovrs["head"] = Vector3(h_rs.x * 0.70, h_rs.y * 0.55, h_rs.z * 0.70)
		# Wider squad spacing so the four-leg footprint doesn't clip.
		ovrs["formation_spacing"] = (ovrs["formation_spacing"] as float) * 1.18
		return ovrs
	if stats.unit_name == "Pulsefont":
		# Caster mast frame per user pick: tall narrow biped, no
		# shoulder cannons (the System Crash cone is the weapon, not
		# a gun). Existing _apply_pulsefont_overlay adds the back spire
		# + head emitter orb; this override removes the shoulder
		# cannons so the silhouette doesn't read as a Jackal carrying
		# extra hardware.
		var ovpf: Dictionary = base.duplicate()
		ovpf["cannon_kind"] = "none"
		var t_pf: Vector3 = ovpf["torso"] as Vector3
		ovpf["torso"] = Vector3(t_pf.x * 0.78, t_pf.y * 1.18, t_pf.z * 0.82)
		var l_pf: Vector3 = ovpf["leg"] as Vector3
		ovpf["leg"] = Vector3(l_pf.x * 0.85, l_pf.y * 1.12, l_pf.z * 0.85)
		ovpf["hip_y"] = (ovpf["hip_y"] as float) * 1.10
		# Shrink head — the caster turret orb is the dominant head
		# feature so the underlying head box should sit smaller.
		var h_pf: Vector3 = ovpf["head"] as Vector3
		ovpf["head"] = Vector3(h_pf.x * 0.85, h_pf.y * 0.85, h_pf.z * 0.85)
		return ovpf
	if stats.unit_name == "Jackal" or stats.unit_name.findn("Jackal") >= 0:
		# Fast-skirmisher sprint biped per 03_factions §3.3:
		# "fast skirmisher". Lean torso forward, lengthen legs, slim
		# the chassis, and dispatch a single-gun layout that the
		# overlay below drops to hip level. Asymmetric on purpose to
		# match Sable's "asymmetric mech" silhouette read.
		var ovjk: Dictionary = base.duplicate()
		ovjk["cannon_kind"] = "single_right"
		ovjk["torso_lean"] = 0.22  # nose-down sprint stance
		# Longer thinner legs for fast read.
		var l_jk: Vector3 = ovjk["leg"] as Vector3
		ovjk["leg"] = Vector3(l_jk.x * 0.85, l_jk.y * 1.10, l_jk.z * 0.85)
		ovjk["hip_y"] = (ovjk["hip_y"] as float) * 1.05
		# Slimmer torso so the silhouette reads agile rather than tanky.
		var t_jk: Vector3 = ovjk["torso"] as Vector3
		ovjk["torso"] = Vector3(t_jk.x * 0.82, t_jk.y * 0.95, t_jk.z * 0.85)
		# Thinner longer gun.
		var c_jk: Vector3 = ovjk["cannon"] as Vector3
		ovjk["cannon"] = Vector3(c_jk.x * 0.75, c_jk.y * 0.75, c_jk.z * 1.20)
		# Squad members can sit a touch tighter — fast scouts move as
		# a tighter cluster than a typical medium line.
		ovjk["formation_spacing"] = (ovjk["formation_spacing"] as float) * 0.95
		return ovjk
	if stats.unit_name == "Specter":
		# Skeletal-recon biped per 03_factions §"Meridian Silhouette".
		# Slimmer torso/head, longer legs, single shoulder cannon (will
		# be replaced in-overlay with a two-handed sniper rifle so the
		# barrel doesn't read as an oversized pistol).
		var ovsp: Dictionary = base.duplicate()
		ovsp["cannon_kind"] = "single_left"
		var t_sp: Vector3 = ovsp["torso"] as Vector3
		ovsp["torso"] = Vector3(t_sp.x * 0.78, t_sp.y * 1.05, t_sp.z * 0.85)
		var l_sp: Vector3 = ovsp["leg"] as Vector3
		ovsp["leg"] = Vector3(l_sp.x * 0.85, l_sp.y * 1.10, l_sp.z * 0.85)
		ovsp["hip_y"] = (ovsp["hip_y"] as float) * 1.08
		var h_sp: Vector3 = ovsp["head"] as Vector3
		ovsp["head"] = Vector3(h_sp.x * 0.85, h_sp.y * 0.85, h_sp.z * 0.85)
		# Centre the single cannon (rifle) at the body midline so it
		# reads as a held weapon rather than a side-mount.
		ovsp["cannon_x"] = (ovsp["cannon_x"] as float) * 0.55
		return ovsp
	if stats.unit_name == "Rook":
		# Combine basic light per user pick 2026-05-14: square-shouldered
		# scout biped. Single shoulder cannon (combine cathedral-foundry
		# style) + amber visor + hammer-and-anvil chest sigil added by
		# the overlay below.
		var ovrk: Dictionary = base.duplicate()
		ovrk["cannon_kind"] = "single_left"
		# Slightly wider torso to push the "broad-shouldered" Combine
		# read while staying within the light class footprint.
		var t_rk: Vector3 = ovrk["torso"] as Vector3
		ovrk["torso"] = Vector3(t_rk.x * 1.10, t_rk.y * 1.02, t_rk.z * 1.05)
		# Centre the cannon a touch closer in so the squared-shoulder
		# silhouette doesn't sprout a lopsided cannon.
		ovrk["cannon_x"] = (ovrk["cannon_x"] as float) * 0.85
		return ovrk
	if stats.unit_name.findn("Ashigaru") >= 0:
		# Inheritor Ashigaru — restored-katana melee scout. Single
		# forward cannon pivot so the overlay can build the katana
		# gripped two-handed. Quadruped legs match the "skittering
		# quadruped" doc description. Wider leg spread so members
		# don't clip into each other in the squad. Helmet-style head
		# (sphere with a forward visor brim added in the overlay).
		var ova: Dictionary = base.duplicate()
		ova["cannon_kind"] = "single_left"
		ova["leg_kind"] = "spider"
		ova["turn_speed"] = 11.0
		# Wider hip span — the default 0.128 light leg_x had the
		# spider legs almost touching. Bumped to 0.22 so the four
		# legs splay out visibly.
		ova["leg_x"] = 0.22
		# Helmet-shaped head: spherical (samurai kabuto silhouette)
		# rather than the toy-robot box. Slightly wider than tall.
		ova["head"] = Vector3(0.26, 0.20, 0.26)
		ova["head_shape"] = "sphere"
		# Wider formation spacing so squadmates don't visually collide
		# (per playtest 2026-05-15: "legs of the ashigaru are too
		# little spaced out and too close to each other").
		ova["formation_spacing"] = (ova["formation_spacing"] as float) * 1.45
		return ova
	if stats.unit_name.findn("Forgemaster") >= 0:
		var ov: Dictionary = base.duplicate()
		# Six articulated insect-style legs (three pairs along the
		# chassis sides). Each leg has a thigh + shin + foot
		# segment so it actually plants on the ground from any
		# hip height -- the previous spider straight-stub build
		# left feet floating ~0.7u above the floor and read as
		# 'mech standing on tiptoe'.
		ov["leg_kind"] = "insect"
		# Bulkier leg shafts -- the Forgemaster reads as a heavy
		# support mech, so shafts feel like industrial linkage,
		# not delicate spider limbs.
		ov["leg"] = Vector3(0.22, 1.05, 0.22)
		# Lift the hip so the chassis silhouette sits noticeably
		# higher than Bulwark's. With six side legs the body
		# clears the ground more, and a 1.40 hip vs Bulwark's
		# 0.98 reads as 'distinctly taller support mech'.
		ov["hip_y"] = 1.40
		# Slightly slimmer + LONGER torso than Bulwark's wide
		# tank-destroyer profile -- reads as a hauling carapace,
		# not a gun chassis. Z up, X down.
		ov["torso"] = Vector3(1.32, 0.90, 2.70)
		# Smaller forward sensor head so it doesn't fight the
		# chimney + missile rack on the rear deck.
		ov["head"] = Vector3(0.55, 0.42, 0.62)
		# Wider squad spacing so the side legs of one Forgemaster
		# don't clip into a neighbour.
		ov["formation_spacing"] = 2.4
		return ov
	return base


func _build_breacher_tank_member(index: int, offset: Vector3, team_color: Color) -> Dictionary:
	## Combine VA-9 Boyar — casemate-style tank destroyer with
	## a fixed forward-mounted heavy gun (no turret). Lower + wider
	## silhouette than the Bulwark biped, longer than the Meridian
	## Courier's turreted hull. Distinct visual identity:
	##   - twin track rails like the Courier
	##   - sloped forward casemate hosting a single heavy cannon
	##   - twin exhaust stacks on the rear deck
	##   - Combine amber side stripe instead of Meridian violet
	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []
	# Warmer tones than the previous cool grey-brown so the Anvil
	# tank-hunter reads as iron-rust industrial rather than cold
	# steel. Bumped reds + dropped blues for the warmth shift.
	var anvil_dark: Color = _faction_tint_chassis(Color(0.34, 0.24, 0.16))
	var anvil_mid: Color = _faction_tint_chassis(Color(0.46, 0.32, 0.20))
	var anvil_amber: Color = Color(1.00, 0.55, 0.18)

	# --- Tracks (two side rails). WIDER tracks per the tank-hunter
	# rework so the chassis reads as 'serious tracked vehicle'.
	var track_len: float = 3.40
	var track_h: float = 0.50
	var track_w: float = 0.68
	for side: int in 2:
		var sx: float = -1.10 if side == 0 else 1.10
		var track := MeshInstance3D.new()
		var track_box := BoxMesh.new()
		track_box.size = Vector3(track_w, track_h, track_len)
		track.mesh = track_box
		track.position = Vector3(sx, track_h * 0.5, 0.0)
		var track_mat := _make_metal_mat(Color(0.08, 0.08, 0.08))
		track.set_surface_override_material(0, track_mat)
		member.add_child(track)
		mats.append(track_mat)
		# Six visible rib stripes per side -- consistent with the
		# Courier read so tracked vehicles share a visual
		# language even with different chassis above. Each rib
		# registered with _courier_track_ribs so _process scrolls
		# them along the track Z axis proportional to ground speed.
		for r_i: int in 6:
			var rib := MeshInstance3D.new()
			var rib_box := BoxMesh.new()
			rib_box.size = Vector3(track_w + 0.06, 0.06, 0.20)
			rib.mesh = rib_box
			var rt: float = (float(r_i) + 0.5) / 6.0
			rib.position = Vector3(sx, track_h, -track_len * 0.5 + rt * track_len)
			var rib_mat := _make_metal_mat(Color(0.05, 0.05, 0.05))
			rib.set_surface_override_material(0, rib_mat)
			member.add_child(rib)
			mats.append(rib_mat)
			_courier_track_ribs.append({"node": rib, "length": track_len})

	# --- Lower hull -- thin floor between the tracks. Narrower
	# than the previous build per rework feedback, and sitting
	# slightly lower (closer to the tracks) for the squat
	# tank-hunter stance. Hull bottom now meets the tracks at
	# track_h + small overlap so the hull sits 'on' the tracks
	# rather than floating above them.
	var hull_w: float = 1.55
	var hull_h: float = 0.34
	var hull_len: float = 2.85
	var hull_y: float = track_h * 0.85 + hull_h * 0.5
	var hull := MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(hull_w, hull_h, hull_len)
	hull.mesh = hull_box
	hull.position = Vector3(0.0, hull_y, 0.0)
	var hull_mat := _make_metal_mat(anvil_mid)
	hull.set_surface_override_material(0, hull_mat)
	member.add_child(hull)
	mats.append(hull_mat)

	# --- Casemate -- the SLOPED FORWARD-FACING superstructure that
	# defines the tank-destroyer silhouette. A trapezoidal block
	# leaning forward, fully replacing the turret + ring of the
	# Courier build. Two stacked plates so the slope reads at any
	# camera angle.
	var case_y: float = hull_y + hull_h * 0.5
	var case_lower := MeshInstance3D.new()
	var case_lower_box := BoxMesh.new()
	case_lower_box.size = Vector3(hull_w * 1.05, 0.65, hull_len * 0.78)
	case_lower.mesh = case_lower_box
	case_lower.position = Vector3(0.0, case_y + 0.32, 0.05)
	case_lower.rotation.x = deg_to_rad(-8.0)
	var case_mat := _make_metal_mat(anvil_dark)
	case_lower.set_surface_override_material(0, case_mat)
	member.add_child(case_lower)
	mats.append(case_mat)
	# Upper plate -- narrower, steeper slope, gives the casemate a
	# 'leaning into the shot' read.
	var case_upper := MeshInstance3D.new()
	var case_upper_box := BoxMesh.new()
	case_upper_box.size = Vector3(hull_w * 0.85, 0.40, hull_len * 0.55)
	case_upper.mesh = case_upper_box
	case_upper.position = Vector3(0.0, case_y + 0.78, -0.10)
	case_upper.rotation.x = deg_to_rad(-18.0)
	var case_upper_mat := _make_metal_mat(anvil_dark)
	case_upper.set_surface_override_material(0, case_upper_mat)
	member.add_child(case_upper)
	mats.append(case_upper_mat)

	# --- Twin fixed forward cannons -- two barrels side-by-side
	# in the casemate. Each gets its own CannonPivot so combat
	# can recoil them independently and the salvo_stagger code
	# fires them in quick succession. The whole vehicle still
	# rotates to aim (no turret).
	var cannons: Array[Node3D] = []
	var muzzles: Array[float] = []
	# Barrel length trimmed 2.10 -> 1.78 (~15% shorter) per
	# playtest feedback; the twin barrels read crisper at the
	# casemate scale without dominating the silhouette.
	var barrel_len: float = 1.78
	for bi: int in 2:
		var bx: float = -0.42 if bi == 0 else 0.42
		var pivot := Node3D.new()
		pivot.name = "CannonPivot_top" if bi == 0 else "CannonPivot_top_right"
		pivot.position = Vector3(bx, case_y + 0.55, -hull_len * 0.55)
		member.add_child(pivot)
		# Mantlet -- per-barrel armoured collar.
		var mantlet := MeshInstance3D.new()
		var mantlet_cyl := CylinderMesh.new()
		mantlet_cyl.top_radius = 0.30
		mantlet_cyl.bottom_radius = 0.36
		mantlet_cyl.height = 0.32
		mantlet_cyl.radial_segments = 22
		mantlet.mesh = mantlet_cyl
		mantlet.rotate_object_local(Vector3.RIGHT, -PI / 2)
		mantlet.position.z = 0.05
		var mantlet_mat := _make_metal_mat(anvil_dark)
		mantlet.set_surface_override_material(0, mantlet_mat)
		pivot.add_child(mantlet)
		mats.append(mantlet_mat)
		# Barrel -- thinner than the previous single-barrel build
		# because there are two of them now (silhouette stays
		# beefy via the side-by-side pair).
		var barrel := MeshInstance3D.new()
		var barrel_cyl := CylinderMesh.new()
		barrel_cyl.top_radius = 0.14
		barrel_cyl.bottom_radius = 0.18
		barrel_cyl.height = barrel_len
		barrel_cyl.radial_segments = 28
		barrel.mesh = barrel_cyl
		barrel.rotate_object_local(Vector3.RIGHT, -PI / 2)
		barrel.position.z = -barrel_len * 0.5
		var barrel_mat := _make_metal_mat(Color(0.16, 0.15, 0.14))
		barrel.set_surface_override_material(0, barrel_mat)
		pivot.add_child(barrel)
		mats.append(barrel_mat)
		# Muzzle brake.
		var muzzle := MeshInstance3D.new()
		var muzzle_cyl := CylinderMesh.new()
		muzzle_cyl.top_radius = 0.24
		muzzle_cyl.bottom_radius = 0.20
		muzzle_cyl.height = 0.20
		muzzle_cyl.radial_segments = 22
		muzzle.mesh = muzzle_cyl
		muzzle.rotate_object_local(Vector3.RIGHT, -PI / 2)
		muzzle.position.z = -barrel_len - 0.10
		var muzzle_mat := _make_metal_mat(Color(0.10, 0.09, 0.08))
		muzzle.set_surface_override_material(0, muzzle_mat)
		pivot.add_child(muzzle)
		mats.append(muzzle_mat)
		# Bore so the barrel reads hollow.
		var bore := MeshInstance3D.new()
		var bore_cyl := CylinderMesh.new()
		bore_cyl.top_radius = 0.09
		bore_cyl.bottom_radius = 0.09
		bore_cyl.height = 0.26
		bore_cyl.radial_segments = 14
		bore.mesh = bore_cyl
		bore.rotate_object_local(Vector3.RIGHT, -PI / 2)
		bore.position.z = -barrel_len - 0.24
		var bore_mat := StandardMaterial3D.new()
		bore_mat.albedo_color = Color(0.03, 0.03, 0.04, 1.0)
		bore_mat.emission_enabled = true
		bore_mat.emission = Color(0.03, 0.03, 0.04, 1.0)
		bore_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bore.set_surface_override_material(0, bore_mat)
		pivot.add_child(bore)
		mats.append(bore_mat)
		# Per-barrel muzzle marker.
		var marker := Marker3D.new()
		marker.name = "Muzzle"
		marker.position = Vector3(0.0, 0.0, -barrel_len - 0.20)
		pivot.add_child(marker)
		cannons.append(pivot)
		muzzles.append(barrel_len + 0.20)
	# Casemate "armoured shroud" between the two barrels -- a
	# small block bridging them at the mantlet line so the pair
	# reads as a single twin-cannon assembly, not two
	# independent guns.
	var shroud := MeshInstance3D.new()
	var shroud_box := BoxMesh.new()
	shroud_box.size = Vector3(0.65, 0.36, 0.40)
	shroud.mesh = shroud_box
	shroud.position = Vector3(0.0, case_y + 0.55, -hull_len * 0.55 + 0.05)
	var shroud_mat := _make_metal_mat(anvil_dark)
	shroud.set_surface_override_material(0, shroud_mat)
	member.add_child(shroud)
	mats.append(shroud_mat)

	# --- Mantlet collar -- a wide sloped armour plate that bridges
	# the casemate's front face to the gun mantlets so the cannons
	# don't read as floating in front of the chassis. Sits flush
	# against the casemate upper plate's leading edge and tilts
	# down to meet the mantlet shroud.
	var collar := MeshInstance3D.new()
	var collar_box := BoxMesh.new()
	collar_box.size = Vector3(hull_w * 0.95, 0.30, 0.55)
	collar.mesh = collar_box
	collar.position = Vector3(0.0, case_y + 0.55, -hull_len * 0.45)
	collar.rotation.x = deg_to_rad(-22.0)
	var collar_mat := _make_metal_mat(anvil_dark)
	collar.set_surface_override_material(0, collar_mat)
	member.add_child(collar)
	mats.append(collar_mat)

	# --- Side fender plates above the tracks -- extra mass that
	# fills the gap between hull and tracks visually. Reads as
	# real engineering instead of a hovering box.
	for fs_i: int in 2:
		var fs_x: float = -hull_w * 0.5 - 0.10 if fs_i == 0 else hull_w * 0.5 + 0.10
		var fender := MeshInstance3D.new()
		var fender_box := BoxMesh.new()
		fender_box.size = Vector3(0.20, 0.18, hull_len * 0.85)
		fender.mesh = fender_box
		fender.position = Vector3(fs_x, hull_y + hull_h * 0.20, 0.0)
		var fender_mat := _make_metal_mat(anvil_dark)
		fender.set_surface_override_material(0, fender_mat)
		member.add_child(fender)
		mats.append(fender_mat)

	# --- Rivet strip along the casemate top edge. A row of small
	# dark blocks the player reads as bolt heads, breaking up the
	# otherwise-flat plate.
	for ri: int in 5:
		var rivet := MeshInstance3D.new()
		var rivet_box := BoxMesh.new()
		rivet_box.size = Vector3(0.08, 0.05, 0.08)
		rivet.mesh = rivet_box
		var rt: float = (float(ri) + 0.5) / 5.0
		rivet.position = Vector3(
			-hull_w * 0.40 + rt * hull_w * 0.80,
			case_y + 0.97,
			hull_len * 0.18,
		)
		var rivet_mat := _make_metal_mat(Color(0.05, 0.05, 0.05))
		rivet.set_surface_override_material(0, rivet_mat)
		member.add_child(rivet)
		mats.append(rivet_mat)

	# --- Twin exhaust stacks on the rear deck. Anvil industrial-
	# diesel signature -- visible from any angle.
	for ex_i: int in 2:
		var ex_x: float = -0.55 if ex_i == 0 else 0.55
		var stack := MeshInstance3D.new()
		var stack_cyl := CylinderMesh.new()
		stack_cyl.top_radius = 0.10
		stack_cyl.bottom_radius = 0.13
		stack_cyl.height = 0.55
		stack_cyl.radial_segments = 14
		stack.mesh = stack_cyl
		stack.position = Vector3(ex_x, case_y + 0.90, hull_len * 0.42)
		var stack_mat := _make_metal_mat(Color(0.08, 0.08, 0.08))
		stack.set_surface_override_material(0, stack_mat)
		member.add_child(stack)
		mats.append(stack_mat)
		# Heat-glow cap.
		var heat := MeshInstance3D.new()
		var heat_cyl := CylinderMesh.new()
		heat_cyl.top_radius = 0.09
		heat_cyl.bottom_radius = 0.09
		heat_cyl.height = 0.04
		heat.mesh = heat_cyl
		heat.position = Vector3(ex_x, case_y + 1.18, hull_len * 0.42)
		var heat_mat := StandardMaterial3D.new()
		heat_mat.albedo_color = Color(0.85, 0.32, 0.10, 1.0)
		heat_mat.emission_enabled = true
		heat_mat.emission = Color(0.95, 0.40, 0.15, 1.0)
		heat_mat.emission_energy_multiplier = 2.2
		heat_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		heat.set_surface_override_material(0, heat_mat)
		member.add_child(heat)
		mats.append(heat_mat)

	# --- Amber side stripes (Combine identity, opposite of Meridian
	# Courier's violet seams).
	for as_i: int in 2:
		var asx: float = -hull_w * 0.5 + 0.04 if as_i == 0 else hull_w * 0.5 - 0.04
		var accent := MeshInstance3D.new()
		var accent_box := BoxMesh.new()
		accent_box.size = Vector3(0.05, 0.06, hull_len * 0.85)
		accent.mesh = accent_box
		accent.position = Vector3(asx, hull_y - hull_h * 0.5 + 0.03, 0.0)
		var accent_mat := StandardMaterial3D.new()
		accent_mat.albedo_color = anvil_amber
		accent_mat.emission_enabled = true
		accent_mat.emission = anvil_amber
		accent_mat.emission_energy_multiplier = 1.4
		accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		accent.set_surface_override_material(0, accent_mat)
		member.add_child(accent)
		mats.append(accent_mat)

	# Team-colour chevron pointing forward. Two angled strips that
	# meet at the bow form a simple > silhouette on top of the
	# casemate -- glance-readable from the RTS camera, doubles as
	# a 'this is the front' direction tell. Replaces the previous
	# rectangular spine stripe which read as a random box on the
	# roof rather than identity.
	var ts_mat := StandardMaterial3D.new()
	ts_mat.albedo_color = team_color
	ts_mat.emission_enabled = true
	ts_mat.emission = team_color
	ts_mat.emission_energy_multiplier = 1.5
	ts_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for ch_i: int in 2:
		var ch_x_sign: float = -1.0 if ch_i == 0 else 1.0
		var chev := MeshInstance3D.new()
		var chev_box := BoxMesh.new()
		chev_box.size = Vector3(hull_w * 0.55, 0.05, 0.18)
		chev.mesh = chev_box
		chev.position = Vector3(
			ch_x_sign * hull_w * 0.18,
			case_y + 1.05,
			hull_len * 0.05,
		)
		# Tilt each strip so they form a forward-pointing >.
		chev.rotation.y = deg_to_rad(28.0) * ch_x_sign
		chev.set_surface_override_material(0, ts_mat)
		member.add_child(chev)
	mats.append(ts_mat)

	# Recoil + rest_z arrays sized to the actual cannon count so
	# salvo_stagger barrels each kick + recover independently.
	var rest_z_arr: Array = []
	var recoil_arr: Array = []
	for c: Node3D in cannons:
		rest_z_arr.append(c.position.z)
		recoil_arr.append(0.0)
	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [] as Array,
		"cannons": cannons,
		"cannon_rest_z": rest_z_arr,
		"cannon_muzzle_z": muzzles,
		"torso": null,
		"head": null,
		"mats": mats,
		"recoil": recoil_arr,
		"stride_phase": 0.0,
		"stride_speed": 0.0,
		"stride_swing": 0.0,
		"bob_amount": 0.0,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.0,
	}


func _build_inquisitor_hover_tank_member(index: int, offset: Vector3, _team_color: Color) -> Dictionary:
	## Heliarch Inquisitor Tank — hover chassis. Per playtest 2026-05-19
	## the previous build read as a traditional tracked tank (twin side
	## skirts + rectangular hull + sloped bow) AND sat too low to the
	## ground (the bottom of the skirts scraped terrain mid-bob). This
	## rebuild:
	##   - replaces the twin skirts with a single CENTRED hover-disc
	##     (saucer-shaped antigrav base, glowing amber ring around the
	##     bottom rim);
	##   - swaps the rectangular bow / hull for a chamfered + tapered
	##     hexagonal hull that reads as "armored hover platform" rather
	##     than "boxy tank";
	##   - lifts the whole assembly HOVER_BASE_LIFT_Y above ground so
	##     the disc bottom sits clearly above the terrain even at the
	##     bottom of the hover bob;
	## Turret + barrel + floodlight + thrusters carry over so the unit
	## still has the readable Inquisitor silhouette from above.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const PLASMA_BLUE: Color = Color(0.55, 0.75, 1.00, 1.0)
	const FLOOD_WARM: Color = Color(1.0, 0.78, 0.42, 1.0)
	const HELIARCH_BRASS: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.14, 1.0)
	const DARK_HULL: Color = Color(0.22, 0.18, 0.14, 1.0)
	## Ground clearance for the hover base. Adds to every Y position
	## below so the bottom of the disc sits HOVER_BASE_LIFT_Y above
	## the ground at rest. The hover bob amplitude (±0.10 from
	## _per_frame_bookkeeping) is well under this lift, so the unit
	## never visually scrapes terrain.
	const HOVER_BASE_LIFT_Y: float = 0.55

	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []

	# --- Single central hover disc — replaces the twin side skirts.
	# Reads as a saucer-shaped antigrav base, not as rectangular treads.
	var disc_radius: float = 1.30
	var disc_height: float = 0.32
	var disc_y: float = HOVER_BASE_LIFT_Y + disc_height * 0.5
	var disc := MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = disc_radius * 0.88  # slightly smaller top → chamfered
	disc_mesh.bottom_radius = disc_radius
	disc_mesh.height = disc_height
	disc_mesh.radial_segments = 18
	disc.mesh = disc_mesh
	disc.position = Vector3(0.0, disc_y, 0.0)
	disc.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	member.add_child(disc)
	# Amber underglow ring around the disc's bottom rim — the "antigrav
	# vent" read. Drawn as a torus that sits flush with the disc base.
	var underglow := MeshInstance3D.new()
	var ug_mesh := TorusMesh.new()
	ug_mesh.inner_radius = disc_radius * 0.78
	ug_mesh.outer_radius = disc_radius * 1.00
	ug_mesh.rings = 24
	ug_mesh.ring_segments = 6
	underglow.mesh = ug_mesh
	underglow.position = Vector3(0.0, HOVER_BASE_LIFT_Y + 0.04, 0.0)
	var ug_mat := StandardMaterial3D.new()
	ug_mat.albedo_color = REACTOR_AMBER
	ug_mat.emission_enabled = true
	ug_mat.emission = REACTOR_AMBER
	ug_mat.emission_energy_multiplier = 2.8
	ug_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	underglow.set_surface_override_material(0, ug_mat)
	member.add_child(underglow)
	mats.append(ug_mat)
	# Six radial vent slits around the disc's outer wall — equally spaced
	# brass-rimmed amber slits selling "the antigrav vents are running hot".
	for slit_i: int in 6:
		var ang: float = float(slit_i) / 6.0 * TAU
		var slit := MeshInstance3D.new()
		var slb := BoxMesh.new()
		slb.size = Vector3(0.08, disc_height * 0.55, 0.18)
		slit.mesh = slb
		slit.position = Vector3(cos(ang) * disc_radius * 0.94, disc_y, sin(ang) * disc_radius * 0.94)
		slit.rotation.y = ang
		var slm := StandardMaterial3D.new()
		slm.albedo_color = REACTOR_AMBER
		slm.emission_enabled = true
		slm.emission = REACTOR_AMBER
		slm.emission_energy_multiplier = 1.6
		slm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		slit.set_surface_override_material(0, slm)
		member.add_child(slit)
		mats.append(slm)
	# Soft amber omni-light beneath the disc — the antigrav field bleeds
	# warm light onto the ground when hovering close to terrain.
	var hover_light := OmniLight3D.new()
	hover_light.light_color = REACTOR_AMBER
	hover_light.light_energy = 0.8
	hover_light.omni_range = 3.0
	hover_light.position = Vector3(0.0, HOVER_BASE_LIFT_Y - 0.20, 0.0)
	member.add_child(hover_light)

	# --- Main hull — chamfered hexagonal platform that sits on top
	# of the disc. Reads as a faceted armored platform rather than a
	# boxy tank casemate. The "hexagonal" effect comes from a slimmer
	# top cylinder sitting on a wider bottom cylinder.
	var hull_w: float = 1.60   # was 1.95 — slimmer for the hover read
	var hull_len: float = 2.55  # was 3.00 — shorter
	var hull_h: float = 0.42
	var hull_y: float = HOVER_BASE_LIFT_Y + disc_height + 0.20
	var hull := MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(hull_w, hull_h, hull_len)
	hull.mesh = hull_box
	hull.position = Vector3(0.0, hull_y, 0.0)
	hull.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	member.add_child(hull)
	# Sloped flanks — angled plates on the LEFT + RIGHT (not the bow).
	# The bow stays open / curved; the flanks lean inward for the
	# chamfered hexagon silhouette.
	for flank_side: int in 2:
		var fsx: float = -1.0 if flank_side == 0 else 1.0
		var flank := MeshInstance3D.new()
		var fb := BoxMesh.new()
		fb.size = Vector3(0.22, hull_h * 0.90, hull_len * 0.95)
		flank.mesh = fb
		flank.position = Vector3(fsx * (hull_w * 0.5 + 0.04), hull_y, 0.0)
		flank.rotation.z = fsx * deg_to_rad(-12.0)
		flank.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		member.add_child(flank)
	# Bow chamfer — short angled plate on the FRONT corners only
	# (replaces the old square bow). Sells the hexagonal tapered nose.
	for bow_side: int in 2:
		var bsx: float = -1.0 if bow_side == 0 else 1.0
		var bcham := MeshInstance3D.new()
		var bcb := BoxMesh.new()
		bcb.size = Vector3(0.45, hull_h * 0.85, 0.55)
		bcham.mesh = bcb
		bcham.position = Vector3(bsx * (hull_w * 0.36), hull_y + 0.02, -hull_len * 0.5 + 0.05)
		bcham.rotation.y = bsx * deg_to_rad(-22.0)
		bcham.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
		member.add_child(bcham)
	# Brass rivet rows along the chamfered flank, fewer + smaller than
	# the old build (the rivet density was reading as boxy plating).
	for rivet_side: int in 2:
		var rsx: float = -1.0 if rivet_side == 0 else 1.0
		for rivet_i: int in 3:
			var rivet := MeshInstance3D.new()
			var rs := SphereMesh.new()
			rs.radius = 0.045
			rs.height = 0.09
			rivet.mesh = rs
			var rz: float = -hull_len * 0.30 + float(rivet_i) * hull_len * 0.30
			rivet.position = Vector3(rsx * hull_w * 0.48, hull_y + 0.10, rz)
			rivet.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
			member.add_child(rivet)

	# --- Forward floodlight — the lamp aesthetic. Mounted on the front
	# face of the chamfered hull. Bright warm beam-bulb that catches the
	# eye in fog.
	var flood_root := Node3D.new()
	flood_root.position = Vector3(0.0, hull_y + 0.25, -hull_len * 0.5 - 0.06)
	member.add_child(flood_root)
	var flood_housing := MeshInstance3D.new()
	var fh := CylinderMesh.new()
	fh.top_radius = 0.18
	fh.bottom_radius = 0.16
	fh.height = 0.22
	fh.radial_segments = 12
	flood_housing.mesh = fh
	flood_housing.rotation.x = PI * 0.5
	flood_housing.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	flood_root.add_child(flood_housing)
	# Inner amber beam-bulb.
	var flood_bulb := MeshInstance3D.new()
	var fbulb := CylinderMesh.new()
	fbulb.top_radius = 0.14
	fbulb.bottom_radius = 0.14
	fbulb.height = 0.03
	fbulb.radial_segments = 12
	flood_bulb.mesh = fbulb
	flood_bulb.rotation.x = PI * 0.5
	flood_bulb.position = Vector3(0.0, 0.0, -0.12)
	var fb_mat := StandardMaterial3D.new()
	fb_mat.albedo_color = FLOOD_WARM
	fb_mat.emission_enabled = true
	fb_mat.emission = FLOOD_WARM
	fb_mat.emission_energy_multiplier = 3.4
	fb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flood_bulb.set_surface_override_material(0, fb_mat)
	flood_root.add_child(flood_bulb)
	mats.append(fb_mat)
	# Small warm OmniLight so the beam actually paints nearby geometry.
	var flood_light := OmniLight3D.new()
	flood_light.light_color = FLOOD_WARM
	flood_light.light_energy = 0.65
	flood_light.omni_range = 5.0
	flood_light.position = Vector3(0.0, 0.0, -0.20)
	flood_root.add_child(flood_light)

	# --- Plasma turret — centred on the hull, rotates to aim.
	var turret_pivot := Node3D.new()
	turret_pivot.name = "TurretPivot"
	turret_pivot.position = Vector3(0.0, hull_y + hull_h * 0.5 + 0.02, 0.10)
	member.add_child(turret_pivot)
	# Turret ring (low cylinder).
	var ring := MeshInstance3D.new()
	var rc := CylinderMesh.new()
	rc.top_radius = 0.52
	rc.bottom_radius = 0.58
	rc.height = 0.16
	rc.radial_segments = 14
	ring.mesh = rc
	ring.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	turret_pivot.add_child(ring)
	# Turret bulb (the dome above the ring).
	var dome := MeshInstance3D.new()
	var db := BoxMesh.new()
	db.size = Vector3(0.78, 0.36, 0.85)
	dome.mesh = db
	dome.position = Vector3(0.0, 0.26, -0.08)
	dome.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	turret_pivot.add_child(dome)
	# Brass crest on top of the turret — religious-cult flair.
	var crest := MeshInstance3D.new()
	var crb := BoxMesh.new()
	crb.size = Vector3(0.42, 0.06, 0.22)
	crest.mesh = crb
	crest.position = Vector3(0.0, 0.48, -0.10)
	crest.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	turret_pivot.add_child(crest)
	# Cannon mantlet at the turret front.
	var cannon_pivot := Node3D.new()
	cannon_pivot.name = "CannonPivot_0"
	cannon_pivot.position = Vector3(0.0, 0.22, -0.46)
	turret_pivot.add_child(cannon_pivot)
	var mantlet := MeshInstance3D.new()
	var mb := BoxMesh.new()
	mb.size = Vector3(0.36, 0.30, 0.30)
	mantlet.mesh = mb
	mantlet.position = Vector3(0.0, 0.0, -0.04)
	mantlet.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	cannon_pivot.add_child(mantlet)
	# Plasma barrel — thicker + shorter than the previous "flashlight",
	# with cooling fins along the length.
	var barrel_len: float = 1.05
	var barrel := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.14
	bc.bottom_radius = 0.17
	bc.height = barrel_len
	bc.radial_segments = 14
	barrel.mesh = bc
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0.0, 0.0, -barrel_len * 0.5 - 0.16)
	barrel.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	cannon_pivot.add_child(barrel)
	# Three brass cooling rings spaced along the barrel.
	for ring_i: int in 3:
		var cring := MeshInstance3D.new()
		var crt := TorusMesh.new()
		crt.inner_radius = 0.17
		crt.outer_radius = 0.23
		crt.rings = 14
		crt.ring_segments = 6
		cring.mesh = crt
		cring.rotation.x = PI * 0.5
		cring.position = Vector3(0.0, 0.0, -0.30 - float(ring_i) * 0.28)
		cring.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		cannon_pivot.add_child(cring)
	# Plasma bulb at muzzle.
	var bulb := MeshInstance3D.new()
	var bs := SphereMesh.new()
	bs.radius = 0.17
	bs.height = 0.34
	bulb.mesh = bs
	bulb.position = Vector3(0.0, 0.0, -barrel_len - 0.20)
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = PLASMA_BLUE
	bulb_mat.emission_enabled = true
	bulb_mat.emission = PLASMA_BLUE
	bulb_mat.emission_energy_multiplier = 3.2
	bulb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bulb.set_surface_override_material(0, bulb_mat)
	cannon_pivot.add_child(bulb)
	mats.append(bulb_mat)
	var muzzle_mk := Marker3D.new()
	muzzle_mk.name = "Muzzle"
	muzzle_mk.position = Vector3(0.0, 0.0, -barrel_len - 0.34)
	cannon_pivot.add_child(muzzle_mk)

	# --- Rear thrusters — visible exhaust nozzles on the back deck.
	for thr_side: int in 2:
		var tsx: float = -1.0 if thr_side == 0 else 1.0
		var thruster := MeshInstance3D.new()
		var tc := CylinderMesh.new()
		tc.top_radius = 0.13
		tc.bottom_radius = 0.16
		tc.height = 0.30
		tc.radial_segments = 10
		thruster.mesh = tc
		thruster.rotation.x = PI * 0.5
		thruster.position = Vector3(tsx * hull_w * 0.32, hull_y + hull_h * 0.5 + 0.05, hull_len * 0.5 + 0.10)
		thruster.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		member.add_child(thruster)
		var glow := MeshInstance3D.new()
		var gd := CylinderMesh.new()
		gd.top_radius = 0.11
		gd.bottom_radius = 0.11
		gd.height = 0.03
		gd.radial_segments = 10
		glow.mesh = gd
		glow.rotation.x = PI * 0.5
		glow.position = Vector3(tsx * hull_w * 0.32, hull_y + hull_h * 0.5 + 0.05, hull_len * 0.5 + 0.25)
		var glow_mat := StandardMaterial3D.new()
		glow_mat.albedo_color = REACTOR_AMBER
		glow_mat.emission_enabled = true
		glow_mat.emission = REACTOR_AMBER
		glow_mat.emission_energy_multiplier = 2.8
		glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.set_surface_override_material(0, glow_mat)
		member.add_child(glow)
		mats.append(glow_mat)

	# Bookkeeping mirrors the other tank builders.
	var cannons: Array = [cannon_pivot]
	var rest_z_arr: Array = []
	var recoil_arr: Array = []
	for c: Node3D in cannons:
		rest_z_arr.append(c.position.z)
		recoil_arr.append(0.0)
	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [] as Array,
		"cannons": cannons,
		"cannon_rest_z": rest_z_arr,
		"cannon_muzzle_z": [muzzle_mk.position.z] as Array,
		"torso": null,
		"head": null,
		"mats": mats,
		"recoil": recoil_arr,
		"stride_phase": 0.0,
		"stride_speed": 0.0,
		"stride_swing": 0.0,
		"bob_amount": 0.0,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.0,
	}


func _build_conquistador_centaur_member(index: int, offset: Vector3, _team_color: Color) -> Dictionary:
	## Heliarch Conquistador — centaur silhouette. Wide armored lower
	## chassis on four short stout legs (the "horse" body), surmounted
	## by a humanoid torso wielding a massive two-handed Heat Hammer.
	## Shoulder plasma cannons are deliberately small (passive secondary
	## while closing). Forward floodlight on the chest sells the
	## Heliarch lamp aesthetic on a heavy chassis.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const HEAT_WHITE_HOT: Color = Color(1.0, 0.85, 0.55, 1.0)
	const FLOOD_WARM: Color = Color(1.0, 0.78, 0.42, 1.0)
	const PLASMA_BLUE: Color = Color(0.55, 0.75, 1.00, 1.0)
	const HELIARCH_BRASS: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.14, 1.0)
	const DARK_HULL: Color = Color(0.22, 0.18, 0.14, 1.0)

	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []

	# --- Quadruped legs — four short stout pillars at the corners of
	# the chassis. Static (no per-leg gait animation); the heavy weight
	# + small lateral footprint sells "stomping forward".
	var chassis_w: float = 1.65
	var chassis_h: float = 0.70
	var chassis_len: float = 2.20
	var chassis_y: float = 0.85
	const LEG_HEIGHT: float = 0.85
	const LEG_THICK: float = 0.26
	for leg_xi: int in 2:
		for leg_zi: int in 2:
			var leg_x: float = -chassis_w * 0.40 if leg_xi == 0 else chassis_w * 0.40
			var leg_z: float = -chassis_len * 0.35 if leg_zi == 0 else chassis_len * 0.35
			var leg := MeshInstance3D.new()
			var lb := BoxMesh.new()
			lb.size = Vector3(LEG_THICK, LEG_HEIGHT, LEG_THICK)
			leg.mesh = lb
			leg.position = Vector3(leg_x, LEG_HEIGHT * 0.5, leg_z)
			leg.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
			member.add_child(leg)
			# Brass knee/joint cap at the top of each leg.
			var knee := MeshInstance3D.new()
			var kb := SphereMesh.new()
			kb.radius = LEG_THICK * 0.65
			kb.height = LEG_THICK * 1.3
			knee.mesh = kb
			knee.position = Vector3(leg_x, LEG_HEIGHT, leg_z)
			knee.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
			member.add_child(knee)
			# Foot pad — wide low cylinder.
			var foot := MeshInstance3D.new()
			var fc := CylinderMesh.new()
			fc.top_radius = LEG_THICK * 0.80
			fc.bottom_radius = LEG_THICK * 0.95
			fc.height = 0.10
			fc.radial_segments = 8
			foot.mesh = fc
			foot.position = Vector3(leg_x, 0.05, leg_z)
			foot.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
			member.add_child(foot)

	# --- Lower chassis (the "horse" body) — wide armored slab spanning
	# the four legs.
	var chassis := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(chassis_w, chassis_h, chassis_len)
	chassis.mesh = cb
	chassis.position = Vector3(0.0, chassis_y, 0.0)
	chassis.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	member.add_child(chassis)
	# Side armor plates — angled slabs hanging off the chassis flanks.
	for side: int in 2:
		var ssx: float = -1.0 if side == 0 else 1.0
		var flank := MeshInstance3D.new()
		var fb := BoxMesh.new()
		fb.size = Vector3(0.12, chassis_h * 0.80, chassis_len * 0.95)
		flank.mesh = fb
		flank.position = Vector3(ssx * (chassis_w * 0.5 + 0.04), chassis_y, 0.0)
		flank.rotation.z = ssx * deg_to_rad(8.0)
		flank.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		member.add_child(flank)
		# Brass rivet row along each flank.
		for rivet_i: int in 4:
			var rivet := MeshInstance3D.new()
			var rs := SphereMesh.new()
			rs.radius = 0.05
			rs.height = 0.10
			rivet.mesh = rs
			var rz: float = -chassis_len * 0.30 + float(rivet_i) * chassis_len * 0.20
			rivet.position = Vector3(ssx * (chassis_w * 0.5 + 0.10), chassis_y, rz)
			rivet.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
			member.add_child(rivet)
	# Front chest plate — sloped armor across the front of the chassis.
	var bow := MeshInstance3D.new()
	var bowb := BoxMesh.new()
	bowb.size = Vector3(chassis_w * 0.95, 0.50, 0.70)
	bow.mesh = bowb
	bow.position = Vector3(0.0, chassis_y + 0.05, -chassis_len * 0.5 + 0.25)
	bow.rotation.x = deg_to_rad(-22.0)
	bow.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	member.add_child(bow)

	# --- Forward floodlight on the chest plate (Heliarch lamp aesthetic).
	var flood_root := Node3D.new()
	flood_root.position = Vector3(0.0, chassis_y + 0.35, -chassis_len * 0.5 - 0.10)
	member.add_child(flood_root)
	var flood_housing := MeshInstance3D.new()
	var fhouse := CylinderMesh.new()
	fhouse.top_radius = 0.16
	fhouse.bottom_radius = 0.14
	fhouse.height = 0.18
	fhouse.radial_segments = 12
	flood_housing.mesh = fhouse
	flood_housing.rotation.x = PI * 0.5
	flood_housing.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	flood_root.add_child(flood_housing)
	var flood_bulb := MeshInstance3D.new()
	var fbulb := CylinderMesh.new()
	fbulb.top_radius = 0.12
	fbulb.bottom_radius = 0.12
	fbulb.height = 0.03
	fbulb.radial_segments = 12
	flood_bulb.mesh = fbulb
	flood_bulb.rotation.x = PI * 0.5
	flood_bulb.position = Vector3(0.0, 0.0, -0.10)
	var fb_mat := StandardMaterial3D.new()
	fb_mat.albedo_color = FLOOD_WARM
	fb_mat.emission_enabled = true
	fb_mat.emission = FLOOD_WARM
	fb_mat.emission_energy_multiplier = 3.4
	fb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flood_bulb.set_surface_override_material(0, fb_mat)
	flood_root.add_child(flood_bulb)
	mats.append(fb_mat)
	var flood_light := OmniLight3D.new()
	flood_light.light_color = FLOOD_WARM
	flood_light.light_energy = 0.55
	flood_light.omni_range = 4.5
	flood_light.position = Vector3(0.0, 0.0, -0.18)
	flood_root.add_child(flood_light)

	# --- Humanoid upper torso — mounted CENTRE-TOP of the chassis,
	# rising out of it like a centaur rider. Smaller than the chassis
	# so the proportions read centaur, not "humanoid mech on a wagon".
	var torso_pivot := Node3D.new()
	torso_pivot.name = "TorsoPivot"
	torso_pivot.position = Vector3(0.0, chassis_y + chassis_h * 0.5 + 0.02, 0.20)
	member.add_child(torso_pivot)
	var torso_size: Vector3 = Vector3(1.05, 1.10, 0.85)
	var torso := MeshInstance3D.new()
	var torso_box := BoxMesh.new()
	torso_box.size = torso_size
	torso.mesh = torso_box
	torso.position.y = torso_size.y * 0.5
	torso.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	torso_pivot.add_child(torso)
	# Chest furnace plate — emissive amber slot framed by brass grille bars.
	var furnace := MeshInstance3D.new()
	var fnb := BoxMesh.new()
	fnb.size = Vector3(torso_size.x * 0.60, torso_size.y * 0.45, 0.04)
	furnace.mesh = fnb
	furnace.position = Vector3(0.0, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.04)
	var furn_mat := StandardMaterial3D.new()
	furn_mat.albedo_color = REACTOR_AMBER
	furn_mat.emission_enabled = true
	furn_mat.emission = REACTOR_AMBER
	furn_mat.emission_energy_multiplier = 2.4
	furn_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	furnace.set_surface_override_material(0, furn_mat)
	torso_pivot.add_child(furnace)
	mats.append(furn_mat)
	for grille_i: int in 4:
		var bar := MeshInstance3D.new()
		var grb := BoxMesh.new()
		grb.size = Vector3(torso_size.x * 0.62, 0.04, 0.06)
		bar.mesh = grb
		var ry: float = torso_size.y * 0.36 + float(grille_i) * torso_size.y * 0.13
		bar.position = Vector3(0.0, ry, -torso_size.z * 0.5 - 0.07)
		bar.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		torso_pivot.add_child(bar)
	# Head/cowl — a hooded slab on top.
	var head := MeshInstance3D.new()
	var hb := BoxMesh.new()
	hb.size = Vector3(0.42, 0.36, 0.42)
	head.mesh = hb
	head.position = Vector3(0.0, torso_size.y + 0.18, -0.04)
	head.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	torso_pivot.add_child(head)
	# Brass crest on the head.
	var crest := MeshInstance3D.new()
	var crb := BoxMesh.new()
	crb.size = Vector3(0.16, 0.10, 0.42)
	crest.mesh = crb
	crest.position = Vector3(0.0, torso_size.y + 0.40, -0.04)
	crest.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	torso_pivot.add_child(crest)

	# Pauldrons — massive shoulder slabs flanking the torso.
	for pauldron_side: int in 2:
		var psx: float = -1.0 if pauldron_side == 0 else 1.0
		var pauldron := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.40, torso_size.y * 0.45, torso_size.z * 0.85)
		pauldron.mesh = pb
		pauldron.position = Vector3(psx * (torso_size.x * 0.5 + 0.10), torso_size.y * 0.82, 0.0)
		pauldron.rotation.z = psx * deg_to_rad(10.0)
		pauldron.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		torso_pivot.add_child(pauldron)
		# Brass rim on the pauldron.
		var rim := MeshInstance3D.new()
		var rrb := BoxMesh.new()
		rrb.size = Vector3(0.46, 0.06, 0.30)
		rim.mesh = rrb
		rim.position = Vector3(psx * (torso_size.x * 0.5 + 0.10), torso_size.y * 0.82 + torso_size.y * 0.24, -torso_size.z * 0.30)
		rim.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		torso_pivot.add_child(rim)

	# --- Heat Hammer — held diagonally across the body via cannon_pivot
	# so play_melee_anim's lunge animates the whole weapon. The hammer
	# is the silhouette focal point.
	var cannon_pivot := Node3D.new()
	cannon_pivot.name = "CannonPivot_0"
	cannon_pivot.position = Vector3(-torso_size.x * 0.20, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.20)
	cannon_pivot.rotation.z = deg_to_rad(48.0)
	torso_pivot.add_child(cannon_pivot)
	# Haft.
	var haft_len: float = 1.80
	var haft := MeshInstance3D.new()
	var hc := CylinderMesh.new()
	hc.top_radius = 0.10
	hc.bottom_radius = 0.10
	hc.height = haft_len
	hc.radial_segments = 12
	haft.mesh = hc
	haft.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	cannon_pivot.add_child(haft)
	# Grip wrap near the lower hand.
	var grip_wrap := MeshInstance3D.new()
	var gw := CylinderMesh.new()
	gw.top_radius = 0.13
	gw.bottom_radius = 0.13
	gw.height = 0.28
	gw.radial_segments = 10
	grip_wrap.mesh = gw
	grip_wrap.position = Vector3(0.0, -haft_len * 0.42, 0.0)
	grip_wrap.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	cannon_pivot.add_child(grip_wrap)
	# Hammer head — anvil block.
	var hhead := MeshInstance3D.new()
	var hhb := BoxMesh.new()
	hhb.size = Vector3(0.80, 0.58, 0.46)
	hhead.mesh = hhb
	hhead.position = Vector3(0.0, haft_len * 0.5 + 0.22, 0.0)
	hhead.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	cannon_pivot.add_child(hhead)
	# Brass collar.
	var collar := MeshInstance3D.new()
	var col_box := BoxMesh.new()
	col_box.size = Vector3(0.36, 0.16, 0.36)
	collar.mesh = col_box
	collar.position = Vector3(0.0, haft_len * 0.5 + 0.04, 0.0)
	collar.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	cannon_pivot.add_child(collar)
	# Hot striking face.
	var hot_face := MeshInstance3D.new()
	var hfb := BoxMesh.new()
	hfb.size = Vector3(0.74, 0.52, 0.05)
	hot_face.mesh = hfb
	hot_face.position = Vector3(0.0, haft_len * 0.5 + 0.22, -0.26)
	var hot_mat := StandardMaterial3D.new()
	hot_mat.albedo_color = HEAT_WHITE_HOT
	hot_mat.emission_enabled = true
	hot_mat.emission = Color(1.0, 0.55, 0.18, 1.0)
	hot_mat.emission_energy_multiplier = 3.0
	hot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot_face.set_surface_override_material(0, hot_mat)
	cannon_pivot.add_child(hot_face)
	mats.append(hot_mat)
	var muzzle_mk := Marker3D.new()
	muzzle_mk.name = "Muzzle"
	muzzle_mk.position = Vector3(0.0, haft_len * 0.5 + 0.50, 0.0)
	cannon_pivot.add_child(muzzle_mk)

	# Small shoulder plasma cannons — passive secondary, discreet.
	for cannon_side: int in 2:
		var csx: float = -1.0 if cannon_side == 0 else 1.0
		var cannon := MeshInstance3D.new()
		var ccyl := CylinderMesh.new()
		ccyl.top_radius = 0.045
		ccyl.bottom_radius = 0.055
		ccyl.height = 0.38
		ccyl.radial_segments = 8
		cannon.mesh = ccyl
		cannon.rotation.x = PI * 0.5
		cannon.position = Vector3(csx * (torso_size.x * 0.5 + 0.12), torso_size.y * 0.95, -torso_size.z * 0.20)
		cannon.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		torso_pivot.add_child(cannon)
		var c_bulb := MeshInstance3D.new()
		var cbsph := SphereMesh.new()
		cbsph.radius = 0.05
		cbsph.height = 0.10
		c_bulb.mesh = cbsph
		c_bulb.position = Vector3(csx * (torso_size.x * 0.5 + 0.12), torso_size.y * 0.95, -torso_size.z * 0.20 - 0.26)
		var cb_mat := StandardMaterial3D.new()
		cb_mat.albedo_color = PLASMA_BLUE
		cb_mat.emission_enabled = true
		cb_mat.emission = PLASMA_BLUE
		cb_mat.emission_energy_multiplier = 2.0
		cb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		c_bulb.set_surface_override_material(0, cb_mat)
		torso_pivot.add_child(c_bulb)
		mats.append(cb_mat)

	var cannons: Array = [cannon_pivot]
	var rest_z_arr: Array = []
	var recoil_arr: Array = []
	for c: Node3D in cannons:
		rest_z_arr.append(c.position.z)
		recoil_arr.append(0.0)
	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [] as Array,
		"cannons": cannons,
		"cannon_rest_z": rest_z_arr,
		"cannon_muzzle_z": [muzzle_mk.position.z] as Array,
		"torso": torso,
		"head": head,
		"mats": mats,
		"recoil": recoil_arr,
		"stride_phase": 0.0,
		"stride_speed": 0.0,
		"stride_swing": 0.0,
		"bob_amount": 0.0,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.0,
	}


func _sol_invictus_emissive(c: Color, energy: float) -> StandardMaterial3D:
	## Local helper for the Sol Invictus build — there's no generic
	## emissive-material helper on Unit, and copy-pasting the 6-line
	## StandardMaterial setup at every glow surface was making the
	## builder hard to read.
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _build_sol_invictus_member(index: int, offset: Vector3, _team_color: Color) -> Dictionary:
	## Heliarch apex — Sol Invictus, the walking sun. Triple-scale
	## humanoid silhouette with a head-mounted Solar Lance beam emitter
	## + arm-mounted plasma turret pods + crown of solar spires + an
	## exposed central reactor core glowing through chest grilles.
	## Detail density is deliberately heavy because the chassis is
	## ~12u tall — empty spaces at that size read as a blocky cube
	## instead of a holy war engine.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const HEAT_WHITE_HOT: Color = Color(1.0, 0.88, 0.55, 1.0)
	const PLASMA_BLUE: Color = Color(0.55, 0.75, 1.00, 1.0)
	const HELIARCH_BRASS: Color = Color(0.65, 0.45, 0.18, 1.0)
	const DARK_BRASS: Color = Color(0.35, 0.24, 0.10, 1.0)
	const SOOTED_IRON: Color = Color(0.16, 0.14, 0.12, 1.0)
	const DARK_HULL: Color = Color(0.22, 0.18, 0.14, 1.0)

	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []

	# --- Two huge biped legs wrapped in hip pivots so _apply_walk_bob
	# can swing them on the X axis. The unit is ~12u tall; each leg
	# is ~4.5u from hip to foot. Hip-pivot Node3D sits at the hip
	# joint (Y = LEG_HEIGHT), child meshes are positioned RELATIVE
	# to it (negative local Y descending). Rotation around X hinges
	# the entire limb forward / back.
	const LEG_THICK: float = 1.05
	const LEG_HEIGHT: float = 4.50
	const FOOT_W: float = 1.50
	var leg_roots: Array[Node3D] = []
	for leg_i: int in 2:
		var lsx: float = -1.10 if leg_i == 0 else 1.10
		var hip_pivot := Node3D.new()
		hip_pivot.name = "SolInvictusHip_%d" % leg_i
		hip_pivot.position = Vector3(lsx, LEG_HEIGHT, 0.0)
		member.add_child(hip_pivot)
		leg_roots.append(hip_pivot)
		# Upper thigh — descends from the hip pivot (negative local Y).
		var thigh := MeshInstance3D.new()
		var thmesh := CylinderMesh.new()
		thmesh.top_radius = LEG_THICK * 0.55
		thmesh.bottom_radius = LEG_THICK * 0.70
		thmesh.height = LEG_HEIGHT * 0.55
		thmesh.radial_segments = 10
		thigh.mesh = thmesh
		thigh.position = Vector3(0.0, -LEG_HEIGHT * 0.28, 0.0)
		thigh.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
		hip_pivot.add_child(thigh)
		# Knee disc — brass plate where upper + lower leg meet.
		var knee := MeshInstance3D.new()
		var kn := SphereMesh.new()
		kn.radius = LEG_THICK * 0.85
		kn.height = LEG_THICK * 1.20
		knee.mesh = kn
		knee.position = Vector3(0.0, -LEG_HEIGHT * 0.55, 0.10)
		knee.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		hip_pivot.add_child(knee)
		# Lower shin — narrower at the ankle.
		var shin := MeshInstance3D.new()
		var shmesh := CylinderMesh.new()
		shmesh.top_radius = LEG_THICK * 0.50
		shmesh.bottom_radius = LEG_THICK * 0.38
		shmesh.height = LEG_HEIGHT * 0.42
		shmesh.radial_segments = 10
		shin.mesh = shmesh
		shin.position = Vector3(0.0, -LEG_HEIGHT * 0.78, 0.05)
		shin.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		hip_pivot.add_child(shin)
		# Foot — broad armored slab at the bottom of the leg.
		var foot := MeshInstance3D.new()
		var fb := BoxMesh.new()
		fb.size = Vector3(FOOT_W, 0.35, FOOT_W * 1.10)
		foot.mesh = fb
		foot.position = Vector3(0.0, -LEG_HEIGHT + 0.18, 0.20)
		foot.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
		hip_pivot.add_child(foot)
		# Amber vent line along the inside of each shin.
		var vent := MeshInstance3D.new()
		var vb := BoxMesh.new()
		vb.size = Vector3(0.12, LEG_HEIGHT * 0.32, 0.18)
		vent.mesh = vb
		vent.position = Vector3(-lsx * 0.30, -LEG_HEIGHT * 0.78, 0.55)
		vent.set_surface_override_material(0, _sol_invictus_emissive(REACTOR_AMBER, 2.2))
		hip_pivot.add_child(vent)

	# --- Lower hip block — wide armored band linking the two legs.
	var hip_y: float = LEG_HEIGHT * 0.92
	var hip := MeshInstance3D.new()
	var hipb := BoxMesh.new()
	hipb.size = Vector3(3.30, 1.20, 2.40)
	hip.mesh = hipb
	hip.position = Vector3(0.0, hip_y, 0.0)
	hip.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	member.add_child(hip)
	# Brass cinch around the hip.
	for cinch_i: int in 3:
		var cinch := MeshInstance3D.new()
		var cib := BoxMesh.new()
		cib.size = Vector3(3.42, 0.16, 0.32)
		cinch.mesh = cib
		cinch.position = Vector3(0.0, hip_y - 0.40 + float(cinch_i) * 0.40, -1.05)
		cinch.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		member.add_child(cinch)

	# --- Main torso. Massive humanoid chest 4.8u wide, with a recessed
	# reactor cavity in the middle that glows amber.
	var torso_y: float = hip_y + 2.10
	var torso := MeshInstance3D.new()
	var tb := BoxMesh.new()
	tb.size = Vector3(4.80, 3.50, 3.00)
	torso.mesh = tb
	torso.position = Vector3(0.0, torso_y, 0.0)
	torso.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	member.add_child(torso)
	# --- Layered armor plates on top of the torso block (per user
	# 2026-05-19: "main body has too few parts atm, is basically just
	# a few large blocks"). Adds three angled armor slabs across the
	# front, a brass collar where torso meets neck, two side hip
	# pauldrons hanging below the shoulders, and a row of brass
	# rivets along the chest seam.
	# Front armor slabs — three tilted-forward plates stacked vertically
	# so the chest reads as layered scale armor rather than a flat box.
	for plate_i: int in 3:
		var plate := MeshInstance3D.new()
		var pbm := BoxMesh.new()
		pbm.size = Vector3(3.40 - float(plate_i) * 0.30, 0.55, 0.14)
		plate.mesh = pbm
		var py: float = torso_y + 0.95 - float(plate_i) * 0.85
		plate.position = Vector3(0.0, py, -1.50)
		plate.rotation.x = deg_to_rad(-14.0)
		plate.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		member.add_child(plate)
	# Brass collar at the top of the torso, just below where the neck
	# meets the head.
	var torso_collar := MeshInstance3D.new()
	var tcb := BoxMesh.new()
	tcb.size = Vector3(4.90, 0.22, 3.10)
	torso_collar.mesh = tcb
	torso_collar.position = Vector3(0.0, torso_y + 1.65, 0.0)
	torso_collar.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	member.add_child(torso_collar)
	# Hip pauldron pair — sloped armor slabs hanging off each lower
	# torso flank. Sells "the chassis has skirt armor over the hip".
	for hp_side: int in 2:
		var hpsx: float = -1.0 if hp_side == 0 else 1.0
		var hip_pauld := MeshInstance3D.new()
		var hpb := BoxMesh.new()
		hpb.size = Vector3(0.90, 1.40, 1.85)
		hip_pauld.mesh = hpb
		hip_pauld.position = Vector3(hpsx * 2.20, torso_y - 1.30, 0.0)
		hip_pauld.rotation.z = hpsx * deg_to_rad(8.0)
		hip_pauld.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
		member.add_child(hip_pauld)
	# Brass rivet row across the chest seam — six rivets along the
	# centre band, breaking up the flat plate.
	for rivet_i: int in 6:
		var rivet := MeshInstance3D.new()
		var rs := SphereMesh.new()
		rs.radius = 0.10
		rs.height = 0.20
		rivet.mesh = rs
		var rx: float = -1.65 + float(rivet_i) * 0.66
		rivet.position = Vector3(rx, torso_y + 0.40, -1.55)
		rivet.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		member.add_child(rivet)
	# Vertical brass pipework running from the torso top down to the
	# hip block — one pipe on each side, breaks up the otherwise-flat
	# back of the torso.
	for pipe_side: int in 2:
		var psx: float = -1.0 if pipe_side == 0 else 1.0
		var pipe := MeshInstance3D.new()
		var pmm := CylinderMesh.new()
		pmm.top_radius = 0.16
		pmm.bottom_radius = 0.20
		pmm.height = 3.20
		pmm.radial_segments = 10
		pipe.mesh = pmm
		pipe.position = Vector3(psx * 1.95, torso_y - 0.20, 1.30)
		pipe.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(pipe)
	# Reactor cavity — a recessed amber sphere mounted in the chest
	# centre. The "exposed reactor core" the lore promises.
	var reactor_cavity := MeshInstance3D.new()
	var rc := BoxMesh.new()
	rc.size = Vector3(2.20, 2.20, 0.40)
	reactor_cavity.mesh = rc
	reactor_cavity.position = Vector3(0.0, torso_y, -1.45)
	reactor_cavity.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	member.add_child(reactor_cavity)
	var reactor_core := MeshInstance3D.new()
	var rsph := SphereMesh.new()
	rsph.radius = 0.85
	rsph.height = 1.70
	rsph.radial_segments = 16
	rsph.rings = 12
	reactor_core.mesh = rsph
	reactor_core.position = Vector3(0.0, torso_y, -1.55)
	var reactor_mat := _sol_invictus_emissive(REACTOR_AMBER, 4.5)
	reactor_core.set_surface_override_material(0, reactor_mat)
	member.add_child(reactor_core)
	mats.append(reactor_mat)
	# Three horizontal grille bars across the cavity so the glow is
	# split by structural ribs (sells "the reactor is contained, barely").
	for grille_i: int in 3:
		var grille := MeshInstance3D.new()
		var gb := BoxMesh.new()
		gb.size = Vector3(2.30, 0.12, 0.20)
		grille.mesh = gb
		grille.position = Vector3(0.0, torso_y - 0.70 + float(grille_i) * 0.70, -1.55)
		grille.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(grille)
	# Brass shoulder pauldrons — broad armored caps where the arms attach.
	for pauld_i: int in 2:
		var psx: float = -2.55 if pauld_i == 0 else 2.55
		var pauld := MeshInstance3D.new()
		var pb := SphereMesh.new()
		pb.radius = 1.10
		pb.height = 1.80
		pb.radial_segments = 12
		pb.rings = 8
		pauld.mesh = pb
		pauld.position = Vector3(psx, torso_y + 1.10, 0.0)
		pauld.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		member.add_child(pauld)
	# Vent stacks rising from the rear of the torso (heat exhaust).
	for stack_i: int in 4:
		var stack := MeshInstance3D.new()
		var sm := CylinderMesh.new()
		sm.top_radius = 0.22
		sm.bottom_radius = 0.30
		sm.height = 2.10
		sm.radial_segments = 8
		stack.mesh = sm
		var sx_off: float = -1.50 + float(stack_i) * 1.00
		stack.position = Vector3(sx_off, torso_y + 2.30, 1.20)
		stack.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(stack)
		# Stack tip cap — small dark-brass collar, NO amber glow ball
		# (per user 2026-05-19: "should not have those orange glowing
		# balls on top of the spires/smokestacks on his head and
		# shoulders/back"). Replaces the previous emissive sphere.
		var stack_cap := MeshInstance3D.new()
		var stcm := CylinderMesh.new()
		stcm.top_radius = 0.18
		stcm.bottom_radius = 0.26
		stcm.height = 0.16
		stcm.radial_segments = 8
		stack_cap.mesh = stcm
		stack_cap.position = Vector3(sx_off, torso_y + 3.40, 1.20)
		stack_cap.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(stack_cap)

	# --- Dedicated shoulder-mounted plasma cannons. Per user request
	# (2026-05-19): replace the previous arm-with-wrist-pod build with
	# dangerous-looking dedicated weapon mounts. Each cannon is a
	# fat forward-pointing barrel on a brass shoulder yoke with three
	# cooling fins along its length and a glowing blue plasma reactor
	# bulb at the back. The whole thing pivots so the muzzle stays
	# tipped at the same forward direction as the head's Solar Lance.
	# No more "arm + hand" silhouette — the gun IS the limb.
	var arm_pivots: Array[Node3D] = []
	for arm_i: int in 2:
		var asx: float = -2.85 if arm_i == 0 else 2.85
		# Shoulder yoke — heavy brass mount block on the torso flank.
		var yoke := MeshInstance3D.new()
		var ykb := BoxMesh.new()
		ykb.size = Vector3(0.95, 1.30, 1.20)
		yoke.mesh = ykb
		yoke.position = Vector3(asx, torso_y + 0.40, 0.0)
		yoke.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		member.add_child(yoke)
		# Yoke ridge — vertical brass band across the front of the yoke.
		var ridge := MeshInstance3D.new()
		var rgb := BoxMesh.new()
		rgb.size = Vector3(1.05, 1.40, 0.20)
		ridge.mesh = rgb
		ridge.position = Vector3(asx, torso_y + 0.40, -0.65)
		ridge.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(ridge)
		# Cannon pivot — origin sits at the yoke front. Cannon meshes
		# parent here so combat rotates the whole assembly via the
		# cannon pivot's Z axis if needed in future.
		var cannon_pivot := Node3D.new()
		cannon_pivot.position = Vector3(asx, torso_y + 0.30, -0.85)
		member.add_child(cannon_pivot)
		arm_pivots.append(cannon_pivot)
		# Plasma reactor block — heavy box at the back of the cannon
		# (the "breech"). Glowing blue from internal containment.
		var breech := MeshInstance3D.new()
		var brb := BoxMesh.new()
		brb.size = Vector3(0.95, 0.95, 0.95)
		breech.mesh = brb
		breech.position = Vector3(0.0, 0.0, 0.45)  # behind the cannon
		breech.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		cannon_pivot.add_child(breech)
		# Blue reactor glow window on the breech (front face).
		var breech_glow := MeshInstance3D.new()
		var bgb := BoxMesh.new()
		bgb.size = Vector3(0.55, 0.55, 0.06)
		breech_glow.mesh = bgb
		breech_glow.position = Vector3(0.0, 0.0, -0.05)
		var bg_mat: StandardMaterial3D = _sol_invictus_emissive(PLASMA_BLUE, 4.0)
		breech_glow.set_surface_override_material(0, bg_mat)
		cannon_pivot.add_child(breech_glow)
		mats.append(bg_mat)
		# Main barrel — fat forward-pointing cylinder. Tapers slightly
		# at the muzzle for the "heavy artillery piece" read.
		var barrel := MeshInstance3D.new()
		var bbm := CylinderMesh.new()
		bbm.top_radius = 0.48   # at muzzle (+Y after rotation = forward)
		bbm.bottom_radius = 0.62  # at breech end
		bbm.height = 2.80
		bbm.radial_segments = 14
		barrel.mesh = bbm
		# CylinderMesh axis is +Y; rotate so it points -Z (forward).
		barrel.rotation.x = -PI * 0.5
		barrel.position = Vector3(0.0, 0.0, -1.40)
		barrel.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		cannon_pivot.add_child(barrel)
		# Three brass cooling rings spaced along the barrel — heavy
		# weapon read (the rings need to dissipate plasma heat).
		for ring_i: int in 3:
			var cring := MeshInstance3D.new()
			var crt := TorusMesh.new()
			crt.inner_radius = 0.60
			crt.outer_radius = 0.78
			crt.rings = 16
			crt.ring_segments = 8
			cring.mesh = crt
			cring.rotation.x = PI * 0.5
			cring.position = Vector3(0.0, 0.0, -0.50 - float(ring_i) * 0.75)
			cring.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
			cannon_pivot.add_child(cring)
		# Muzzle plasma bulb — large glowing sphere at the barrel tip
		# that pulses when the cannon is charging.
		var muzzle_bulb := MeshInstance3D.new()
		var mbm := SphereMesh.new()
		mbm.radius = 0.48
		mbm.height = 0.96
		mbm.radial_segments = 14
		mbm.rings = 8
		muzzle_bulb.mesh = mbm
		muzzle_bulb.position = Vector3(0.0, 0.0, -2.90)
		var mb_mat: StandardMaterial3D = _sol_invictus_emissive(PLASMA_BLUE, 3.5)
		muzzle_bulb.set_surface_override_material(0, mb_mat)
		cannon_pivot.add_child(muzzle_bulb)
		mats.append(mb_mat)
		# Forward muzzle marker — combat reads this for plasma orb spawn.
		var muzzle := Marker3D.new()
		muzzle.name = "ArmPlasmaMuzzle_%d" % arm_i
		muzzle.position = Vector3(0.0, 0.0, -3.40)
		cannon_pivot.add_child(muzzle)

	# --- Head — heavy faceted block above the shoulders carrying the
	# Solar Lance emitter on its forward face.
	var head_y: float = torso_y + 2.65
	var head := MeshInstance3D.new()
	var hdb := BoxMesh.new()
	hdb.size = Vector3(2.20, 1.80, 2.10)
	head.mesh = hdb
	head.position = Vector3(0.0, head_y, 0.0)
	head.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	member.add_child(head)
	# Brass collar around the head base.
	var head_collar := MeshInstance3D.new()
	var hcb := BoxMesh.new()
	hcb.size = Vector3(2.40, 0.30, 2.30)
	head_collar.mesh = hcb
	head_collar.position = Vector3(0.0, head_y - 0.95, 0.0)
	head_collar.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	member.add_child(head_collar)
	# Solar Lance emitter — large amber lens on the front face that
	# the beam visibly fires from. Sells "the lance shoots from the
	# head" without the player having to read tooltips.
	var lens_housing := MeshInstance3D.new()
	var lhh := CylinderMesh.new()
	lhh.top_radius = 0.72
	lhh.bottom_radius = 0.62
	lhh.height = 0.40
	lhh.radial_segments = 16
	lens_housing.mesh = lhh
	lens_housing.rotation.x = -PI * 0.5
	lens_housing.position = Vector3(0.0, head_y, -1.20)
	lens_housing.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
	member.add_child(lens_housing)
	var lens := MeshInstance3D.new()
	var ll := SphereMesh.new()
	ll.radius = 0.55
	ll.height = 1.10
	lens.mesh = ll
	lens.position = Vector3(0.0, head_y, -1.42)
	var lens_mat: StandardMaterial3D = _sol_invictus_emissive(HEAT_WHITE_HOT, 5.0)
	lens.set_surface_override_material(0, lens_mat)
	member.add_child(lens)
	mats.append(lens_mat)
	# Head Solar Lance muzzle marker (combat queries this for beam
	# spawn position).
	var head_muzzle := Marker3D.new()
	head_muzzle.name = "SolarLanceMuzzle"
	head_muzzle.position = Vector3(0.0, head_y, -1.85)
	member.add_child(head_muzzle)
	# Two side eye-slits — narrow amber bars so the head reads as
	# vigilant even with the lens off.
	for eye_i: int in 2:
		var eye := MeshInstance3D.new()
		var eb := BoxMesh.new()
		eb.size = Vector3(0.18, 0.10, 0.60)
		eye.mesh = eb
		var exo: float = -0.85 if eye_i == 0 else 0.85
		eye.position = Vector3(exo, head_y + 0.20, -1.10)
		eye.set_surface_override_material(0, _sol_invictus_emissive(REACTOR_AMBER, 2.0))
		member.add_child(eye)

	# --- Solar spire crown. Eight radial spires of varying heights
	# rising from a brass crown ring above the head — the "crowned
	# with reactor-spires that radiate visible heat" silhouette per
	# 03_factions.md §3.4.
	var crown_y: float = head_y + 1.15
	var crown_ring := MeshInstance3D.new()
	var crm := CylinderMesh.new()
	crm.top_radius = 1.10
	crm.bottom_radius = 1.30
	crm.height = 0.35
	crm.radial_segments = 16
	crown_ring.mesh = crm
	crown_ring.position = Vector3(0.0, crown_y, 0.0)
	crown_ring.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	member.add_child(crown_ring)
	for spire_i: int in 8:
		var ang: float = float(spire_i) / 8.0 * TAU
		var spire_h: float = 1.20 if spire_i % 2 == 0 else 1.80  # alternating tall/short
		var spire := MeshInstance3D.new()
		var sb := CylinderMesh.new()
		sb.top_radius = 0.06
		sb.bottom_radius = 0.22
		sb.height = spire_h
		sb.radial_segments = 8
		spire.mesh = sb
		var sx: float = cos(ang) * 1.10
		var sz: float = sin(ang) * 1.10
		spire.position = Vector3(sx, crown_y + spire_h * 0.5, sz)
		spire.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(spire)
		# (Removed amber pip on each spire tip per user 2026-05-19 —
		# the row of glowing balls on the crown read as cartoony.
		# The brass spire alone carries the silhouette without
		# the lollipop look.)

	# Bright amber omni-light at the reactor core — sells "the unit is
	# emitting visible heat onto the surrounding ground" at dusk.
	var reactor_light := OmniLight3D.new()
	reactor_light.light_color = REACTOR_AMBER
	reactor_light.light_energy = 1.8
	reactor_light.omni_range = 9.0
	reactor_light.position = Vector3(0.0, torso_y, -1.45)
	member.add_child(reactor_light)

	# Cannons array carries the arm pivots so the recoil tick can
	# tap them. Even though we don't animate the arms back-and-forth
	# every fire, the array shape lets the bookkeeping reach in.
	var cannons: Array = []
	for ap: Node3D in arm_pivots:
		cannons.append(ap)
	var rest_z_arr: Array = []
	var recoil_arr: Array = []
	for c: Node3D in cannons:
		rest_z_arr.append(c.position.z)
		recoil_arr.append(0.0)

	return {
		"root": member,
		"legs": leg_roots,
		"leg_phases": [0.0, PI] as Array,  # biped alternating stride
		"shoulders": [] as Array,
		"cannons": cannons,
		"cannon_rest_z": rest_z_arr,
		"cannon_muzzle_z": [-3.40, -3.40] as Array,
		"torso": torso,
		"head": head,
		"mats": mats,
		"recoil": recoil_arr,
		"stride_phase": 0.0,
		"stride_speed": 4.5,  # slow heavy stride
		"stride_swing": 0.32,  # narrow swing — apex chassis is ponderous
		"bob_amount": 0.10,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.6,
	}


func _build_herald_priest_member(index: int, offset: Vector3, _team_color: Color) -> Dictionary:
	## Heliarch Herald — compact tripod walker (rebuilt 2026-05-19).
	## Reads as an "industrial walking bunker" — armored chassis on
	## three short stocky legs, with a forward-mounted turret carrying
	## a single oversized acoustic horn. No more biped + chest horn
	## cluster; the rebuild replaces the prior goofy "preacher with
	## three trumpets glued to the chest" silhouette.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const HELIARCH_BRASS: Color = Color(0.65, 0.45, 0.18, 1.0)
	const DARK_BRASS: Color = Color(0.35, 0.24, 0.10, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.13, 1.0)
	const DARK_HULL: Color = Color(0.22, 0.18, 0.14, 1.0)

	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)
	var mats: Array[StandardMaterial3D] = []

	# --- Three short stocky legs in a tripod layout: one rear
	# (centered behind chassis), two forward (left + right of chassis).
	# Each leg = hip pivot + thigh + foot. Hip rotates around X for
	# stride.
	const TRIPOD_HIP_Y: float = 1.30
	var leg_roots: Array[Node3D] = []
	var leg_layout: Array = [
		Vector3(-0.85, TRIPOD_HIP_Y, -0.55),  # front-left
		Vector3(0.85, TRIPOD_HIP_Y, -0.55),   # front-right
		Vector3(0.0, TRIPOD_HIP_Y, 0.80),     # rear-center
	]
	for leg_i: int in leg_layout.size():
		var hip_pos: Vector3 = leg_layout[leg_i]
		var hip := Node3D.new()
		hip.name = "HeraldTripodHip_%d" % leg_i
		hip.position = hip_pos
		member.add_child(hip)
		leg_roots.append(hip)
		# Thick angled thigh — narrows from hip to ankle.
		var thigh := MeshInstance3D.new()
		var thm := CylinderMesh.new()
		thm.top_radius = 0.30
		thm.bottom_radius = 0.22
		thm.height = 1.05
		thm.radial_segments = 10
		thigh.mesh = thm
		thigh.position = Vector3(0.0, -0.55, 0.0)
		thigh.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
		hip.add_child(thigh)
		# Brass knee collar at the joint level.
		var knee := MeshInstance3D.new()
		var kn := SphereMesh.new()
		kn.radius = 0.28
		kn.height = 0.42
		knee.mesh = kn
		knee.position = Vector3(0.0, -1.05, 0.05)
		knee.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		hip.add_child(knee)
		# Lower shin — thicker armor block.
		var shin := MeshInstance3D.new()
		var shm := BoxMesh.new()
		shm.size = Vector3(0.32, 0.45, 0.32)
		shin.mesh = shm
		shin.position = Vector3(0.0, -1.30, 0.05)
		shin.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		hip.add_child(shin)
		# Foot — wide circular pad for the "lumbering tripod" stance.
		var foot := MeshInstance3D.new()
		var fc := CylinderMesh.new()
		fc.top_radius = 0.42
		fc.bottom_radius = 0.50
		fc.height = 0.14
		fc.radial_segments = 10
		foot.mesh = fc
		foot.position = Vector3(0.0, -1.30, 0.10)
		foot.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
		hip.add_child(foot)

	# --- Chassis core — wider boxy hull sitting on top of the tripod.
	# Layered: a base block, a smaller upper deck with sloped front
	# armor + a brass rim around the perimeter.
	var chassis_y: float = TRIPOD_HIP_Y + 0.20
	var chassis := MeshInstance3D.new()
	var cbm := BoxMesh.new()
	cbm.size = Vector3(2.10, 0.80, 2.00)
	chassis.mesh = cbm
	chassis.position = Vector3(0.0, chassis_y, 0.0)
	chassis.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	member.add_child(chassis)
	# Brass rim — thin band around the chassis top edge.
	var rim := MeshInstance3D.new()
	var rmb := BoxMesh.new()
	rmb.size = Vector3(2.20, 0.10, 2.10)
	rim.mesh = rmb
	rim.position = Vector3(0.0, chassis_y + 0.45, 0.0)
	rim.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	member.add_child(rim)
	# Sloped front armor plate — angled forward for that "walking
	# bunker tipping into the enemy" read.
	var front_armor := MeshInstance3D.new()
	var fab := BoxMesh.new()
	fab.size = Vector3(2.10, 0.85, 0.18)
	front_armor.mesh = fab
	front_armor.position = Vector3(0.0, chassis_y + 0.10, -1.00)
	front_armor.rotation.x = deg_to_rad(-25.0)
	front_armor.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	member.add_child(front_armor)
	# Brass rivets along the front armor.
	for rivet_i: int in 5:
		var rivet := MeshInstance3D.new()
		var rs := SphereMesh.new()
		rs.radius = 0.07
		rs.height = 0.14
		rivet.mesh = rs
		var rx: float = -0.90 + float(rivet_i) * 0.45
		rivet.position = Vector3(rx, chassis_y + 0.30, -1.05)
		rivet.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
		member.add_child(rivet)
	# Side armor plates — angled outward on each flank.
	for armor_side: int in 2:
		var asx: float = -1.0 if armor_side == 0 else 1.0
		var sa := MeshInstance3D.new()
		var sab := BoxMesh.new()
		sab.size = Vector3(0.16, 0.75, 1.80)
		sa.mesh = sab
		sa.position = Vector3(asx * 1.18, chassis_y, 0.0)
		sa.rotation.z = asx * deg_to_rad(-10.0)
		sa.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
		member.add_child(sa)
	# Rear exhaust stacks — two brass vents on the back deck.
	for stack_i: int in 2:
		var ssx: float = -0.5 if stack_i == 0 else 0.5
		var stack := MeshInstance3D.new()
		var sm := CylinderMesh.new()
		sm.top_radius = 0.14
		sm.bottom_radius = 0.18
		sm.height = 0.50
		sm.radial_segments = 8
		stack.mesh = sm
		stack.position = Vector3(ssx, chassis_y + 0.70, 0.85)
		stack.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(stack)

	# --- Turret on top of the chassis. Forward-facing acoustic horn
	# mounted on a brass yoke. Single oversized horn replaces the
	# previous three-trumpet cluster (which read as goofy).
	var turret_pivot := Node3D.new()
	turret_pivot.name = "HeraldTurret"
	turret_pivot.position = Vector3(0.0, chassis_y + 0.60, -0.30)
	member.add_child(turret_pivot)
	# Yoke base — short box mounted on the turret pivot.
	var yoke := MeshInstance3D.new()
	var ykb := BoxMesh.new()
	ykb.size = Vector3(0.85, 0.40, 0.85)
	yoke.mesh = ykb
	yoke.position = Vector3(0.0, 0.0, 0.0)
	yoke.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	turret_pivot.add_child(yoke)
	# Yoke side arms — vertical brass plates that hold the horn pivot.
	for yarm_side: int in 2:
		var ysx: float = -1.0 if yarm_side == 0 else 1.0
		var yarm := MeshInstance3D.new()
		var yab := BoxMesh.new()
		yab.size = Vector3(0.12, 0.55, 0.45)
		yarm.mesh = yab
		yarm.position = Vector3(ysx * 0.45, 0.45, -0.10)
		yarm.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		turret_pivot.add_child(yarm)
	# The horn itself — large forward-pointing tapered cone. Wider
	# mouth at the front, narrow throat at the back. Slightly tilted
	# upward for a "broadcasting" pose.
	var horn := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.62
	hm.bottom_radius = 0.18
	hm.height = 1.40
	hm.radial_segments = 16
	horn.mesh = hm
	horn.rotation.x = -PI * 0.5  # mouth points -Z (forward)
	horn.position = Vector3(0.0, 0.50, -0.95)
	horn.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	turret_pivot.add_child(horn)
	# Inner amber chamber — visible deep inside the horn mouth.
	var horn_chamber := MeshInstance3D.new()
	var hcm := SphereMesh.new()
	hcm.radius = 0.18
	hcm.height = 0.36
	horn_chamber.mesh = hcm
	horn_chamber.position = Vector3(0.0, 0.50, -0.30)
	var hc_mat := _sol_invictus_emissive(REACTOR_AMBER, 2.4)
	horn_chamber.set_surface_override_material(0, hc_mat)
	turret_pivot.add_child(horn_chamber)
	mats.append(hc_mat)
	# Brass reinforcement rings along the horn — two short tori.
	for ring_i: int in 2:
		var hring := MeshInstance3D.new()
		var ht := TorusMesh.new()
		ht.inner_radius = 0.30
		ht.outer_radius = 0.40
		ht.rings = 16
		ht.ring_segments = 6
		hring.mesh = ht
		hring.rotation.x = PI * 0.5
		hring.position = Vector3(0.0, 0.50, -0.55 - float(ring_i) * 0.30)
		hring.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		turret_pivot.add_child(hring)
	# Muzzle marker — at the horn mouth, where the sound wave spawns.
	var horn_muzzle := Marker3D.new()
	horn_muzzle.name = "AcousticHornMuzzle"
	horn_muzzle.position = Vector3(0.0, 0.50, -1.65)
	turret_pivot.add_child(horn_muzzle)

	# Soft amber light from the horn chamber.
	var light := OmniLight3D.new()
	light.light_color = REACTOR_AMBER
	light.light_energy = 1.0
	light.omni_range = 4.5
	light.position = Vector3(0.0, chassis_y + 1.10, -1.20)
	member.add_child(light)

	# Cannons array carries the turret pivot so the combat fire path
	# can resolve a muzzle position. The recoil system is a no-op for
	# the turret (single horn, no recoil arm).
	var cannons: Array = [turret_pivot]
	# Tripod gait — left-front + rear together (phase 0), then
	# right-front alone (phase π). Loose approximation of a 3-leg trot.
	var leg_phases_arr: Array = [0.0, PI, 0.0]
	return {
		"root": member,
		"legs": leg_roots,
		"leg_phases": leg_phases_arr,
		"shoulders": [] as Array,
		"cannons": cannons,
		"cannon_rest_z": [turret_pivot.position.z] as Array,
		"cannon_muzzle_z": [1.65] as Array,
		"torso": chassis,
		"head": yoke,
		"mats": mats,
		"recoil": [0.0] as Array,
		"stride_phase": randf_range(0.0, TAU),
		"stride_speed": 5.0,
		"stride_swing": 0.28,
		"bob_amount": 0.05,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.9,
	}


func _build_censer_thurible_member(index: int, offset: Vector3, _team_color: Color) -> Dictionary:
	## Heliarch Censer — elite chemical caster, REBUILT 2026-05-19 per
	## user feedback ("looks too much like a table with a bong without a
	## real direction"). New silhouette: elongated front-to-back armored
	## reliquary hull on four short legs. Forward end carries a brass
	## faceplate with toxic-green vent grilles + side cooling vents;
	## the chemical launcher angles UP+forward from the dorsal hull,
	## NOT vertically. A small ceremonial dome sits between the launcher
	## and the rear of the chassis. Reads as "consecrated armored
	## war-thurible" with clear forward orientation, no longer a coffee
	## table with a vertical tube glued on top.
	const REACTOR_AMBER: Color = Color(1.0, 0.55, 0.20, 1.0)
	const TOXIC_GREEN: Color = Color(0.55, 0.80, 0.35, 1.0)
	const HELIARCH_BRASS: Color = Color(0.65, 0.45, 0.18, 1.0)
	const DARK_BRASS: Color = Color(0.35, 0.24, 0.10, 1.0)
	const SOOTED_IRON: Color = Color(0.18, 0.16, 0.13, 1.0)
	const DARK_HULL: Color = Color(0.22, 0.18, 0.14, 1.0)

	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)
	var mats: Array[StandardMaterial3D] = []

	# --- Four short legs in a rectangular layout. Elongated chassis
	# (longer than wide) gives the unit a clear forward axis at a
	# glance. Each leg = hip pivot + thigh + foot.
	var chassis_w: float = 1.55
	var chassis_len: float = 2.85  # ~1.85× width = elongated
	var leg_roots: Array[Node3D] = []
	var leg_corner_idx: int = 0
	for leg_xi: int in 2:
		for leg_zi: int in 2:
			var lx: float = -chassis_w * 0.42 if leg_xi == 0 else chassis_w * 0.42
			var lz: float = -chassis_len * 0.36 if leg_zi == 0 else chassis_len * 0.36
			var hip := Node3D.new()
			hip.name = "CenserHip_%d" % leg_corner_idx
			leg_corner_idx += 1
			hip.position = Vector3(lx, 1.00, lz)
			member.add_child(hip)
			leg_roots.append(hip)
			var leg := MeshInstance3D.new()
			var lb := BoxMesh.new()
			lb.size = Vector3(0.32, 1.00, 0.32)
			leg.mesh = lb
			leg.position = Vector3(0.0, -0.50, 0.0)
			leg.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
			hip.add_child(leg)
			var foot := MeshInstance3D.new()
			var fc := CylinderMesh.new()
			fc.top_radius = 0.22
			fc.bottom_radius = 0.30
			fc.height = 0.14
			fc.radial_segments = 10
			foot.mesh = fc
			foot.position = Vector3(0.0, -0.93, 0.0)
			foot.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
			hip.add_child(foot)

	# --- Main hull. Elongated armored slab. Slightly taller at the
	# back (where the chemical reservoir sits) than the front (where
	# the launcher mouth pokes out).
	var chassis_y: float = 1.20
	var chassis := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(chassis_w, 0.65, chassis_len)
	chassis.mesh = cb
	chassis.position = Vector3(0.0, chassis_y, 0.0)
	chassis.set_surface_override_material(0, _make_metal_mat(DARK_HULL))
	member.add_child(chassis)
	# Dorsal hump — slightly raised armored spine running front-to-back.
	# Wider at the back to read as the chemical reservoir, narrower at
	# the front. Reads as "this thing has direction".
	var hump := MeshInstance3D.new()
	var humpb := BoxMesh.new()
	humpb.size = Vector3(chassis_w * 0.55, 0.45, chassis_len * 0.75)
	hump.mesh = humpb
	hump.position = Vector3(0.0, chassis_y + 0.50, 0.35)  # offset toward rear
	hump.set_surface_override_material(0, _make_metal_mat(SOOTED_IRON))
	member.add_child(hump)
	# Brass perimeter rim — clear visual band marking the hull.
	var rim := MeshInstance3D.new()
	var rmb := BoxMesh.new()
	rmb.size = Vector3(chassis_w + 0.10, 0.08, chassis_len + 0.10)
	rim.mesh = rmb
	rim.position = Vector3(0.0, chassis_y + 0.36, 0.0)
	rim.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	member.add_child(rim)

	# --- FORWARD-FACING BRASS FACEPLATE. The dominant silhouette cue
	# that this chassis has a front. Angled forward, brass with toxic-
	# green vent grilles + a central reactor eye.
	var face_z: float = -chassis_len * 0.5 - 0.10
	var faceplate := MeshInstance3D.new()
	var fpb := BoxMesh.new()
	fpb.size = Vector3(chassis_w * 0.95, 0.80, 0.20)
	faceplate.mesh = fpb
	faceplate.position = Vector3(0.0, chassis_y + 0.20, face_z)
	faceplate.rotation.x = deg_to_rad(-14.0)  # tipped forward
	faceplate.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	member.add_child(faceplate)
	# Central reactor eye — glowing toxic-green spheroid mounted on
	# the faceplate. Anchors the "this is the front" read.
	var eye := MeshInstance3D.new()
	var eyem := SphereMesh.new()
	eyem.radius = 0.18
	eyem.height = 0.36
	eyem.radial_segments = 14
	eyem.rings = 8
	eye.mesh = eyem
	eye.position = Vector3(0.0, chassis_y + 0.30, face_z - 0.12)
	var eye_mat := _sol_invictus_emissive(TOXIC_GREEN, 2.8)
	eye.set_surface_override_material(0, eye_mat)
	member.add_child(eye)
	mats.append(eye_mat)
	# Vent grille slits flanking the eye — four thin emissive bars
	# (two per side) signaling "chemical exhaust forward".
	for vent_side: int in 2:
		var vsx: float = -1.0 if vent_side == 0 else 1.0
		for vent_i: int in 2:
			var vent := MeshInstance3D.new()
			var vb := BoxMesh.new()
			vb.size = Vector3(0.08, 0.50, 0.10)
			vent.mesh = vb
			vent.position = Vector3(vsx * (0.30 + float(vent_i) * 0.16), chassis_y + 0.30, face_z - 0.05)
			var v_mat := _sol_invictus_emissive(TOXIC_GREEN, 1.4)
			vent.set_surface_override_material(0, v_mat)
			member.add_child(vent)
			mats.append(v_mat)
	# Forward floodlight on top of the faceplate (lamp aesthetic).
	var floodlight := OmniLight3D.new()
	floodlight.light_color = TOXIC_GREEN
	floodlight.light_energy = 1.3
	floodlight.omni_range = 4.0
	floodlight.position = Vector3(0.0, chassis_y + 0.30, face_z - 0.20)
	member.add_child(floodlight)

	# --- SIDE COOLING VENTS along each flank of the chassis. Long
	# horizontal brass-rimmed slits with toxic green peeking through —
	# the chemical brewing is venting out the sides. Adds detail to
	# the elongated hull AND reinforces the front-to-back direction.
	for flank_side: int in 2:
		var fksx: float = -1.0 if flank_side == 0 else 1.0
		# Outer brass frame.
		var vent_frame := MeshInstance3D.new()
		var vfb := BoxMesh.new()
		vfb.size = Vector3(0.10, 0.30, chassis_len * 0.65)
		vent_frame.mesh = vfb
		vent_frame.position = Vector3(fksx * (chassis_w * 0.5 + 0.03), chassis_y + 0.10, -0.05)
		vent_frame.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		member.add_child(vent_frame)
		# Inner toxic glow strip.
		var vent_glow := MeshInstance3D.new()
		var vgb := BoxMesh.new()
		vgb.size = Vector3(0.06, 0.16, chassis_len * 0.58)
		vent_glow.mesh = vgb
		vent_glow.position = Vector3(fksx * (chassis_w * 0.5 + 0.05), chassis_y + 0.10, -0.05)
		var vg_mat := _sol_invictus_emissive(TOXIC_GREEN, 1.6)
		vent_glow.set_surface_override_material(0, vg_mat)
		member.add_child(vent_glow)
		mats.append(vg_mat)

	# --- Small ceremonial dome on the dorsal hump (NOT the dominant
	# feature anymore). Sits between the launcher and the back of the
	# chassis. Brass with a short spike finial.
	var small_dome_y: float = chassis_y + 1.05
	var small_dome := MeshInstance3D.new()
	var sdm := SphereMesh.new()
	sdm.radius = 0.42
	sdm.height = 0.52
	sdm.radial_segments = 14
	sdm.rings = 8
	small_dome.mesh = sdm
	small_dome.position = Vector3(0.0, small_dome_y, 0.85)  # toward rear
	small_dome.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	member.add_child(small_dome)
	var small_finial := MeshInstance3D.new()
	var sfm := CylinderMesh.new()
	sfm.top_radius = 0.03
	sfm.bottom_radius = 0.08
	sfm.height = 0.32
	sfm.radial_segments = 8
	small_finial.mesh = sfm
	small_finial.position = Vector3(0.0, small_dome_y + 0.40, 0.85)
	small_finial.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
	member.add_child(small_finial)

	# --- DORSAL CHEMICAL LAUNCHER. Mounted on the front of the hump,
	# angled UP+FORWARD at ~30° elevation so barrels arc onto target.
	# Distinct from the previous vertical pole + dome setup: this is
	# a tilted mortar pointing where the unit is facing.
	var launcher_base_y: float = chassis_y + 0.55
	var pendant_pivot := Node3D.new()
	pendant_pivot.position = Vector3(0.0, launcher_base_y, -0.10)  # forward of dome
	# Tilt 30° forward (mouth points up + forward, NOT straight up).
	pendant_pivot.rotation.x = deg_to_rad(-30.0)
	member.add_child(pendant_pivot)
	# Outer launcher tube — fat brass mortar pointing along local +Y.
	var tube := MeshInstance3D.new()
	var tbm := CylinderMesh.new()
	tbm.top_radius = 0.32
	tbm.bottom_radius = 0.40
	tbm.height = 1.40
	tbm.radial_segments = 14
	tube.mesh = tbm
	tube.position = Vector3(0.0, 0.60, 0.0)
	tube.set_surface_override_material(0, _make_metal_mat(HELIARCH_BRASS))
	pendant_pivot.add_child(tube)
	# Two brass reinforcement rings along the tube.
	for ring_i: int in 2:
		var hoop := MeshInstance3D.new()
		var ht := TorusMesh.new()
		ht.inner_radius = 0.34
		ht.outer_radius = 0.44
		ht.rings = 14
		ht.ring_segments = 6
		hoop.mesh = ht
		hoop.rotation.x = PI * 0.5
		hoop.position = Vector3(0.0, 0.20 + float(ring_i) * 0.70, 0.0)
		hoop.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
		pendant_pivot.add_child(hoop)
	# Visible chambered round near the tube mouth.
	var charged_round := MeshInstance3D.new()
	var crsm := SphereMesh.new()
	crsm.radius = 0.26
	crsm.height = 0.52
	crsm.radial_segments = 12
	crsm.rings = 8
	charged_round.mesh = crsm
	charged_round.position = Vector3(0.0, 1.20, 0.0)
	var cr_mat := _sol_invictus_emissive(TOXIC_GREEN, 2.4)
	charged_round.set_surface_override_material(0, cr_mat)
	pendant_pivot.add_child(charged_round)
	mats.append(cr_mat)
	# Muzzle marker — at the tube mouth.
	var pendant_muzzle := Marker3D.new()
	pendant_muzzle.name = "CenserMuzzle"
	pendant_muzzle.position = Vector3(0.0, 1.50, 0.0)
	pendant_pivot.add_child(pendant_muzzle)
	# Mortar mount base — short brass cradle where the tube hinges
	# off the hump.
	var mount_cradle := MeshInstance3D.new()
	var mcb := BoxMesh.new()
	mcb.size = Vector3(0.65, 0.30, 0.55)
	mount_cradle.mesh = mcb
	mount_cradle.position = Vector3(0.0, launcher_base_y - 0.08, -0.10)
	mount_cradle.set_surface_override_material(0, _make_metal_mat(DARK_BRASS))
	member.add_child(mount_cradle)

	# Toxic green light from the launcher chamber — bathes the
	# surrounding area in chemical glow.
	var pendant_light := OmniLight3D.new()
	pendant_light.light_color = TOXIC_GREEN
	pendant_light.light_energy = 1.4
	pendant_light.omni_range = 5.5
	pendant_light.position = Vector3(0.0, launcher_base_y + 0.80, -0.10)
	member.add_child(pendant_light)

	var cannons: Array = [pendant_pivot]
	# Quadruped trot — diagonal pair phases. corner_idx order from the
	# leg loop is: 0=FL-back, 1=FL-front, 2=FR-back, 3=FR-front.
	# Diagonal trot: {0,3} together, {1,2} together.
	var leg_phases_arr: Array = [0.0, PI, PI, 0.0]
	return {
		"root": member,
		"legs": leg_roots,
		"leg_phases": leg_phases_arr,
		"shoulders": [] as Array,
		"cannons": cannons,
		"cannon_rest_z": [pendant_pivot.position.z] as Array,
		"cannon_muzzle_z": [0.65] as Array,
		"torso": chassis,
		"head": faceplate,
		"mats": mats,
		"recoil": [0.0] as Array,
		"stride_phase": randf_range(0.0, TAU),
		"stride_speed": 6.5,
		"stride_swing": 0.30,
		"bob_amount": 0.04,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 1.0,
	}


func _build_wachter_tank_member(index: int, offset: Vector3, team_color: Color) -> Dictionary:
	## Inheritor Wächter — low tracked tank with a tesla-coil mast turret.
	## Per drossfront-docs §4.3: "slow armored vehicle ... Branch B deploys
	## to stationary heavy weapons platform". Built off the Breacher pattern
	## but tuned smaller (medium class, not heavy tank-hunter) and topped
	## with a multi-ring tesla coil that arcs visibly while firing.
	## Faction tint composes via _faction_tint_chassis (Inheritor branch
	## returns pale concrete-grey / patinated bronze tones).
	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []
	var hull_dark: Color = _faction_tint_chassis(Color(0.34, 0.32, 0.28))
	var hull_mid: Color = _faction_tint_chassis(Color(0.48, 0.45, 0.38))
	var inheritor_violet: Color = Color(0.70, 0.55, 1.0, 1.0)
	var tesla_glow: Color = Color(0.45, 0.85, 1.0, 1.0)
	# --- Tracks (two side rails). Shorter than Breacher (medium scale)
	# but the same visual language so the unit family reads tracked.
	var track_len: float = 2.95
	var track_h: float = 0.42
	var track_w: float = 0.55
	for side: int in 2:
		var sx: float = -0.92 if side == 0 else 0.92
		var track := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(track_w, track_h, track_len)
		track.mesh = tb
		track.position = Vector3(sx, track_h * 0.5, 0.0)
		var track_mat := _make_metal_mat(Color(0.08, 0.08, 0.08))
		track.set_surface_override_material(0, track_mat)
		member.add_child(track)
		mats.append(track_mat)
		# Five rib stripes per side (scaled to track length).
		for r_i: int in 5:
			var rib := MeshInstance3D.new()
			var rib_box := BoxMesh.new()
			rib_box.size = Vector3(track_w + 0.05, 0.05, 0.18)
			rib.mesh = rib_box
			var rt: float = (float(r_i) + 0.5) / 5.0
			rib.position = Vector3(sx, track_h, -track_len * 0.5 + rt * track_len)
			var rib_mat := _make_metal_mat(Color(0.05, 0.05, 0.05))
			rib.set_surface_override_material(0, rib_mat)
			member.add_child(rib)
			mats.append(rib_mat)
			_courier_track_ribs.append({"node": rib, "length": track_len})
	# --- Lower hull — squat block between the tracks.
	var hull_w: float = 1.40
	var hull_h: float = 0.32
	var hull_len: float = 2.45
	var hull_y: float = track_h * 0.85 + hull_h * 0.5
	var hull := MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(hull_w, hull_h, hull_len)
	hull.mesh = hull_box
	hull.position = Vector3(0.0, hull_y, 0.0)
	var hull_mat := _make_metal_mat(hull_mid)
	hull.set_surface_override_material(0, hull_mat)
	member.add_child(hull)
	mats.append(hull_mat)
	# Sloped glacis at the front so the vehicle reads as "forward = -Z".
	var glacis := MeshInstance3D.new()
	var glacis_box := BoxMesh.new()
	glacis_box.size = Vector3(hull_w * 0.95, 0.55, 0.45)
	glacis.mesh = glacis_box
	glacis.position = Vector3(0.0, hull_y + 0.18, -hull_len * 0.45)
	glacis.rotation.x = deg_to_rad(-26.0)
	var glacis_mat := _make_metal_mat(hull_dark)
	glacis.set_surface_override_material(0, glacis_mat)
	member.add_child(glacis)
	mats.append(glacis_mat)
	# Side fender plates over the tracks.
	for fs_i: int in 2:
		var fs_x: float = -hull_w * 0.5 - 0.10 if fs_i == 0 else hull_w * 0.5 + 0.10
		var fender := MeshInstance3D.new()
		var fender_box := BoxMesh.new()
		fender_box.size = Vector3(0.18, 0.16, hull_len * 0.82)
		fender.mesh = fender_box
		fender.position = Vector3(fs_x, hull_y + hull_h * 0.20, 0.0)
		var fender_mat := _make_metal_mat(hull_dark)
		fender.set_surface_override_material(0, fender_mat)
		member.add_child(fender)
		mats.append(fender_mat)
	# --- Tesla-coil turret base — a low cylindrical pedestal centered
	# on the hull. Carries the rotating coil mast above it.
	var pedestal_y: float = hull_y + hull_h * 0.5
	var pedestal := MeshInstance3D.new()
	var pedestal_cyl := CylinderMesh.new()
	pedestal_cyl.top_radius = 0.55
	pedestal_cyl.bottom_radius = 0.62
	pedestal_cyl.height = 0.20
	pedestal_cyl.radial_segments = 20
	pedestal.mesh = pedestal_cyl
	pedestal.position = Vector3(0.0, pedestal_y + 0.10, 0.10)
	var pedestal_mat := _make_metal_mat(hull_dark)
	pedestal.set_surface_override_material(0, pedestal_mat)
	member.add_child(pedestal)
	mats.append(pedestal_mat)
	# Bronze ring band on the pedestal — Inheritor patinated-bronze identity.
	var ring := MeshInstance3D.new()
	var ring_torus := TorusMesh.new()
	ring_torus.inner_radius = 0.56
	ring_torus.outer_radius = 0.64
	ring.mesh = ring_torus
	ring.position = Vector3(0.0, pedestal_y + 0.12, 0.10)
	ring.rotation.x = PI * 0.5
	var ring_mat := _make_metal_mat(Color(0.55, 0.40, 0.20))
	ring.set_surface_override_material(0, ring_mat)
	member.add_child(ring)
	mats.append(ring_mat)
	# --- Coil mast (turret pivot) — a vertical pivot so combat
	# tracking can rotate the mast to face the target. CombatComponent
	# walks "cannons" for muzzle data; we register the mast as the
	# single "cannon".
	var pivot := Node3D.new()
	pivot.name = "CannonPivot_top"
	pivot.position = Vector3(0.0, pedestal_y + 0.20, 0.10)
	member.add_child(pivot)
	# Three stacked coil disc-pairs of decreasing radius — the iconic
	# tesla-coil silhouette. Each pair is two thin cylinders with a
	# small gap so the coil "windings" read.
	var coil_radii: Array[float] = [0.48, 0.38, 0.28]
	var coil_y: float = 0.0
	for ci: int in coil_radii.size():
		var rad: float = coil_radii[ci]
		for sub: int in 2:
			var coil_disc := MeshInstance3D.new()
			var coil_cyl := CylinderMesh.new()
			coil_cyl.top_radius = rad
			coil_cyl.bottom_radius = rad
			coil_cyl.height = 0.08
			coil_cyl.radial_segments = 18
			coil_disc.mesh = coil_cyl
			coil_disc.position = Vector3(0.0, coil_y + 0.04 + sub * 0.16, 0.0)
			var coil_mat := _make_metal_mat(Color(0.55, 0.40, 0.20))
			coil_disc.set_surface_override_material(0, coil_mat)
			pivot.add_child(coil_disc)
			mats.append(coil_mat)
		# Inner column connecting the disc-pair.
		var col := MeshInstance3D.new()
		var col_cyl := CylinderMesh.new()
		col_cyl.top_radius = rad * 0.62
		col_cyl.bottom_radius = rad * 0.62
		col_cyl.height = 0.28
		col_cyl.radial_segments = 16
		col.mesh = col_cyl
		col.position = Vector3(0.0, coil_y + 0.14, 0.0)
		var col_mat := _make_metal_mat(hull_dark)
		col.set_surface_override_material(0, col_mat)
		pivot.add_child(col)
		mats.append(col_mat)
		coil_y += 0.34
	# Crowning emissive ball — the coil's sparking sphere where bolts
	# launch from. Wide tesla glow + omni light so the unit reads
	# "charged up" even at rest.
	var spark := MeshInstance3D.new()
	var spark_sphere := SphereMesh.new()
	spark_sphere.radius = 0.22
	spark_sphere.height = 0.44
	spark.mesh = spark_sphere
	spark.position = Vector3(0.0, coil_y + 0.18, 0.0)
	var spark_mat := StandardMaterial3D.new()
	spark_mat.albedo_color = tesla_glow
	spark_mat.emission_enabled = true
	spark_mat.emission = tesla_glow
	spark_mat.emission_energy_multiplier = 3.2
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark.set_surface_override_material(0, spark_mat)
	pivot.add_child(spark)
	mats.append(spark_mat)
	var spark_light := OmniLight3D.new()
	spark_light.light_color = tesla_glow
	spark_light.light_energy = 1.2
	spark_light.omni_range = 4.0
	spark_light.position = spark.position
	pivot.add_child(spark_light)
	# Muzzle marker — bolts fire from the spark sphere. Combat hooks
	# read this off CannonPivot via _resolve_muzzle_pos.
	var muzzle_marker := Marker3D.new()
	muzzle_marker.name = "Muzzle"
	muzzle_marker.position = Vector3(0.0, coil_y + 0.18, -0.05)
	pivot.add_child(muzzle_marker)
	# Architect-violet niche on the front of the pedestal — Inheritor
	# faction identity so the chassis reads pre-Severance even at a
	# glance.
	var niche := MeshInstance3D.new()
	var niche_box := BoxMesh.new()
	niche_box.size = Vector3(0.18, 0.18, 0.04)
	niche.mesh = niche_box
	niche.position = Vector3(0.0, pedestal_y + 0.08, -0.50)
	var niche_mat := StandardMaterial3D.new()
	niche_mat.albedo_color = inheritor_violet
	niche_mat.emission_enabled = true
	niche_mat.emission = inheritor_violet
	niche_mat.emission_energy_multiplier = 2.0
	niche_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	niche.set_surface_override_material(0, niche_mat)
	member.add_child(niche)
	mats.append(niche_mat)
	# Team-color stripe along each fender so allies/enemies read.
	var ts_mat := StandardMaterial3D.new()
	ts_mat.albedo_color = team_color
	ts_mat.emission_enabled = true
	ts_mat.emission = team_color
	ts_mat.emission_energy_multiplier = 1.4
	ts_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for ts_side: int in 2:
		var tsx: float = -hull_w * 0.5 - 0.10 if ts_side == 0 else hull_w * 0.5 + 0.10
		var stripe := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.05, 0.06, hull_len * 0.72)
		stripe.mesh = sb
		stripe.position = Vector3(tsx + (0.02 if ts_side == 1 else -0.02), hull_y + hull_h * 0.05, 0.0)
		stripe.set_surface_override_material(0, ts_mat)
		member.add_child(stripe)
	mats.append(ts_mat)
	# Cannon recoil bookkeeping (single mast).
	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [] as Array,
		"cannons": [pivot] as Array,
		"cannon_rest_z": [pivot.position.z],
		"cannon_muzzle_z": [0.15],
		"torso": null,
		"head": null,
		"mats": mats,
		"recoil": [0.0],
		"stride_phase": 0.0,
		"stride_speed": 0.0,
		"stride_swing": 0.0,
		"bob_amount": 0.0,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.0,
	}


## Shared chassis base for the three Breacher variants. Builds
## tracks (with animated ribs), lower hull, twin exhaust stacks,
## side fender plates, side amber stripes, and the team-colour
## chevron. Returns a dict with the meshes-built materials list +
## the helpful dimensions the variant builders need to position
## their distinct top geometry. Variants attach their own
## casemate / mortar / pod array on top.
func _build_breacher_chassis_base(index: int, offset: Vector3, team_color: Color) -> Dictionary:
	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)
	var mats: Array[StandardMaterial3D] = []
	var anvil_dark: Color = _faction_tint_chassis(Color(0.34, 0.24, 0.16))
	var anvil_mid: Color = _faction_tint_chassis(Color(0.46, 0.32, 0.20))
	var anvil_amber: Color = Color(1.00, 0.55, 0.18)
	# Tracks
	var track_len: float = 3.40
	var track_h: float = 0.50
	var track_w: float = 0.68
	for side: int in 2:
		var sx: float = -1.10 if side == 0 else 1.10
		var track := MeshInstance3D.new()
		var track_box := BoxMesh.new()
		track_box.size = Vector3(track_w, track_h, track_len)
		track.mesh = track_box
		track.position = Vector3(sx, track_h * 0.5, 0.0)
		var track_mat := _make_metal_mat(Color(0.08, 0.08, 0.08))
		track.set_surface_override_material(0, track_mat)
		member.add_child(track)
		mats.append(track_mat)
		for r_i: int in 6:
			var rib := MeshInstance3D.new()
			var rib_box := BoxMesh.new()
			rib_box.size = Vector3(track_w + 0.06, 0.06, 0.20)
			rib.mesh = rib_box
			var rt: float = (float(r_i) + 0.5) / 6.0
			rib.position = Vector3(sx, track_h, -track_len * 0.5 + rt * track_len)
			var rib_mat := _make_metal_mat(Color(0.05, 0.05, 0.05))
			rib.set_surface_override_material(0, rib_mat)
			member.add_child(rib)
			mats.append(rib_mat)
			_courier_track_ribs.append({"node": rib, "length": track_len})
	# Hull (the floor between the tracks)
	var hull_w: float = 1.55
	var hull_h: float = 0.34
	var hull_len: float = 2.85
	var hull_y: float = track_h * 0.85 + hull_h * 0.5
	var hull := MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(hull_w, hull_h, hull_len)
	hull.mesh = hull_box
	hull.position = Vector3(0.0, hull_y, 0.0)
	var hull_mat := _make_metal_mat(anvil_mid)
	hull.set_surface_override_material(0, hull_mat)
	member.add_child(hull)
	mats.append(hull_mat)
	# Side fender plates
	for fs_i: int in 2:
		var fs_x: float = -hull_w * 0.5 - 0.10 if fs_i == 0 else hull_w * 0.5 + 0.10
		var fender := MeshInstance3D.new()
		var fender_box := BoxMesh.new()
		fender_box.size = Vector3(0.20, 0.18, hull_len * 0.85)
		fender.mesh = fender_box
		fender.position = Vector3(fs_x, hull_y + hull_h * 0.20, 0.0)
		var fender_mat := _make_metal_mat(anvil_dark)
		fender.set_surface_override_material(0, fender_mat)
		member.add_child(fender)
		mats.append(fender_mat)
	# Twin exhaust stacks on the rear deck.
	for ex_i: int in 2:
		var ex_x: float = -0.55 if ex_i == 0 else 0.55
		var stack := MeshInstance3D.new()
		var stack_cyl := CylinderMesh.new()
		stack_cyl.top_radius = 0.10
		stack_cyl.bottom_radius = 0.13
		stack_cyl.height = 0.55
		stack_cyl.radial_segments = 14
		stack.mesh = stack_cyl
		stack.position = Vector3(ex_x, hull_y + hull_h * 0.5 + 0.30, hull_len * 0.42)
		var stack_mat := _make_metal_mat(Color(0.08, 0.08, 0.08))
		stack.set_surface_override_material(0, stack_mat)
		member.add_child(stack)
		mats.append(stack_mat)
		var heat := MeshInstance3D.new()
		var heat_cyl := CylinderMesh.new()
		heat_cyl.top_radius = 0.09
		heat_cyl.bottom_radius = 0.09
		heat_cyl.height = 0.04
		heat.mesh = heat_cyl
		heat.position = Vector3(ex_x, hull_y + hull_h * 0.5 + 0.58, hull_len * 0.42)
		var heat_mat := StandardMaterial3D.new()
		heat_mat.albedo_color = Color(0.85, 0.32, 0.10, 1.0)
		heat_mat.emission_enabled = true
		heat_mat.emission = Color(0.95, 0.40, 0.15, 1.0)
		heat_mat.emission_energy_multiplier = 2.2
		heat_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		heat.set_surface_override_material(0, heat_mat)
		member.add_child(heat)
		mats.append(heat_mat)
	# Amber side stripes.
	for as_i: int in 2:
		var asx: float = -hull_w * 0.5 + 0.04 if as_i == 0 else hull_w * 0.5 - 0.04
		var accent := MeshInstance3D.new()
		var accent_box := BoxMesh.new()
		accent_box.size = Vector3(0.05, 0.06, hull_len * 0.85)
		accent.mesh = accent_box
		accent.position = Vector3(asx, hull_y - hull_h * 0.5 + 0.03, 0.0)
		var accent_mat := StandardMaterial3D.new()
		accent_mat.albedo_color = anvil_amber
		accent_mat.emission_enabled = true
		accent_mat.emission = anvil_amber
		accent_mat.emission_energy_multiplier = 1.4
		accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		accent.set_surface_override_material(0, accent_mat)
		member.add_child(accent)
		mats.append(accent_mat)
	# Team-colour chevron on top.
	var ts_mat := StandardMaterial3D.new()
	ts_mat.albedo_color = team_color
	ts_mat.emission_enabled = true
	ts_mat.emission = team_color
	ts_mat.emission_energy_multiplier = 1.5
	ts_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for ch_i: int in 2:
		var ch_x_sign: float = -1.0 if ch_i == 0 else 1.0
		var chev := MeshInstance3D.new()
		var chev_box := BoxMesh.new()
		chev_box.size = Vector3(hull_w * 0.55, 0.05, 0.18)
		chev.mesh = chev_box
		chev.position = Vector3(
			ch_x_sign * hull_w * 0.18,
			hull_y + hull_h * 0.5 + 0.55,
			hull_len * 0.05,
		)
		chev.rotation.y = deg_to_rad(28.0) * ch_x_sign
		chev.set_surface_override_material(0, ts_mat)
		member.add_child(chev)
	mats.append(ts_mat)
	return {
		"member": member,
		"mats": mats,
		"hull_w": hull_w,
		"hull_h": hull_h,
		"hull_len": hull_len,
		"hull_y": hull_y,
		"anvil_dark": anvil_dark,
		"anvil_mid": anvil_mid,
	}


func _build_breacher_mortar_member(index: int, offset: Vector3, team_color: Color) -> Dictionary:
	## Mortar variant -- open-topped artillery body with a mortar
	## tube angled steeply upward and forward. No casemate, no
	## main cannon. Open box reads as an artillery hull (think
	## Sturmpanzer + Hummel / SU-122 lineage) with a high-angle
	## mortar instead of a low-angle gun.
	var base: Dictionary = _build_breacher_chassis_base(index, offset, team_color)
	var member: Node3D = base["member"]
	var mats: Array[StandardMaterial3D] = base["mats"]
	var hull_w: float = base["hull_w"]
	var hull_h: float = base["hull_h"]
	var hull_len: float = base["hull_len"]
	var hull_y: float = base["hull_y"]
	var anvil_dark: Color = base["anvil_dark"]
	var deck_y: float = hull_y + hull_h * 0.5
	# Open-top hull walls -- four thin boxes ringing the upper
	# chassis, leaving the top open. Reads like an open-topped
	# artillery casemate.
	var wall_h: float = 0.65
	var wall_t: float = 0.10
	# Front + rear walls.
	for side: int in 2:
		var sz: float = -hull_len * 0.40 if side == 0 else hull_len * 0.40
		var wall := MeshInstance3D.new()
		var wb := BoxMesh.new()
		wb.size = Vector3(hull_w * 0.92, wall_h, wall_t)
		wall.mesh = wb
		wall.position = Vector3(0.0, deck_y + wall_h * 0.5, sz)
		var wmat := _make_metal_mat(anvil_dark)
		wall.set_surface_override_material(0, wmat)
		member.add_child(wall)
		mats.append(wmat)
	# Left + right walls (slightly shorter so the top reads as
	# open-air with side armor only).
	for side2: int in 2:
		var sx: float = -hull_w * 0.46 if side2 == 0 else hull_w * 0.46
		var sw := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(wall_t, wall_h * 0.72, hull_len * 0.78)
		sw.mesh = sb
		sw.position = Vector3(sx, deck_y + wall_h * 0.36, 0.0)
		var smat := _make_metal_mat(anvil_dark)
		sw.set_surface_override_material(0, smat)
		member.add_child(sw)
		mats.append(smat)
	# Mortar pivot -- recoil + muzzle lookup target. Sits on the
	# open deck near the rear, angled up + forward (~55deg).
	var cannon_pivot := Node3D.new()
	cannon_pivot.name = "CannonPivot_top"
	cannon_pivot.position = Vector3(0.0, deck_y + 0.30, hull_len * 0.05)
	# Pre-rotate so the tube's local -Z (forward) points up + fwd.
	# Sign correction: positive X-rotation tips the local -Z up
	# (and slightly forward); previous -55deg sent the tube DOWN
	# below the chassis, which is why the mortar visually pointed
	# straight ahead instead of diagonally up.
	cannon_pivot.rotation.x = deg_to_rad(55.0)
	member.add_child(cannon_pivot)
	# Mortar baseplate -- chunky cylinder cradling the tube.
	var base_plate := MeshInstance3D.new()
	var bp_cyl := CylinderMesh.new()
	bp_cyl.top_radius = 0.36
	bp_cyl.bottom_radius = 0.42
	bp_cyl.height = 0.25
	bp_cyl.radial_segments = 16
	base_plate.mesh = bp_cyl
	base_plate.position.z = 0.10
	var bp_mat := _make_metal_mat(anvil_dark)
	base_plate.set_surface_override_material(0, bp_mat)
	cannon_pivot.add_child(base_plate)
	mats.append(bp_mat)
	# Mortar tube.
	var tube_len: float = 1.55
	var tube := MeshInstance3D.new()
	var tube_cyl := CylinderMesh.new()
	tube_cyl.top_radius = 0.20
	tube_cyl.bottom_radius = 0.22
	tube_cyl.height = tube_len
	tube_cyl.radial_segments = 22
	tube.mesh = tube_cyl
	tube.rotate_object_local(Vector3.RIGHT, -PI / 2)
	tube.position.z = -tube_len * 0.5
	var tube_mat := _make_metal_mat(Color(0.14, 0.13, 0.12))
	tube.set_surface_override_material(0, tube_mat)
	cannon_pivot.add_child(tube)
	mats.append(tube_mat)
	# Hollow bore at the muzzle.
	var bore := MeshInstance3D.new()
	var bore_cyl := CylinderMesh.new()
	bore_cyl.top_radius = 0.15
	bore_cyl.bottom_radius = 0.15
	bore_cyl.height = 0.20
	bore_cyl.radial_segments = 14
	bore.mesh = bore_cyl
	bore.rotate_object_local(Vector3.RIGHT, -PI / 2)
	bore.position.z = -tube_len - 0.05
	var bore_mat := StandardMaterial3D.new()
	bore_mat.albedo_color = Color(0.03, 0.03, 0.04, 1.0)
	bore_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bore.set_surface_override_material(0, bore_mat)
	cannon_pivot.add_child(bore)
	mats.append(bore_mat)
	# Muzzle marker for combat.
	var muzzle_marker := Marker3D.new()
	muzzle_marker.name = "Muzzle"
	muzzle_marker.position = Vector3(0.0, 0.0, -tube_len - 0.10)
	cannon_pivot.add_child(muzzle_marker)
	# Stack of shells visible inside the open compartment -- two
	# small cylinders so the artillery role reads even when the
	# tube isn't firing.
	for sh_i: int in 2:
		var sh_x: float = -hull_w * 0.18 + float(sh_i) * 0.30
		var shell := MeshInstance3D.new()
		var shell_cyl := CylinderMesh.new()
		shell_cyl.top_radius = 0.09
		shell_cyl.bottom_radius = 0.09
		shell_cyl.height = 0.32
		shell.mesh = shell_cyl
		shell.position = Vector3(sh_x, deck_y + 0.16, -hull_len * 0.18)
		var shmat := _make_metal_mat(Color(0.55, 0.42, 0.18))
		shell.set_surface_override_material(0, shmat)
		member.add_child(shell)
		mats.append(shmat)
	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [] as Array,
		"cannons": [cannon_pivot] as Array[Node3D],
		"cannon_rest_z": [cannon_pivot.position.z] as Array,
		"cannon_muzzle_z": [tube_len + 0.10] as Array,
		"torso": null,
		"head": null,
		"mats": mats,
		"recoil": [0.0],
		"stride_phase": 0.0,
		"stride_speed": 0.0,
		"stride_swing": 0.0,
		"bob_amount": 0.0,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.0,
	}


func _build_breacher_salvo_member(index: int, offset: Vector3, team_color: Color) -> Dictionary:
	## Salvo variant -- chassis carries a single purpose-built
	## 6-tube rocket battery housing on a tilted cradle. Reads as
	## one designed launcher (a la M270 MLRS / Katyusha BM-13)
	## rather than six free-standing pods. Tubes face up-forward
	## so ripple-fired rockets arc onto target.
	var base: Dictionary = _build_breacher_chassis_base(index, offset, team_color)
	var member: Node3D = base["member"]
	var mats: Array[StandardMaterial3D] = base["mats"]
	var hull_w: float = base["hull_w"]
	var hull_h: float = base["hull_h"]
	var hull_len: float = base["hull_len"]
	var hull_y: float = base["hull_y"]
	var anvil_dark: Color = base["anvil_dark"]
	var deck_y: float = hull_y + hull_h * 0.5

	# Cradle base -- the launcher rests on this raised plinth so
	# the tilt angle reads as deliberate engineering, not a stuck
	# lid. Spans the rear ~70% of the chassis deck.
	var cradle := MeshInstance3D.new()
	var cradle_box := BoxMesh.new()
	cradle_box.size = Vector3(hull_w * 0.78, 0.20, hull_len * 0.55)
	cradle.mesh = cradle_box
	cradle.position = Vector3(0.0, deck_y + 0.10, hull_len * 0.10)
	var cradle_mat := _make_metal_mat(anvil_dark)
	cradle.set_surface_override_material(0, cradle_mat)
	member.add_child(cradle)
	mats.append(cradle_mat)
	# Twin trunnion blocks where the cradle meets the launcher --
	# small cylinders that read as the elevation hinge pins.
	for tr_i: int in 2:
		var trx: float = (-1.0 if tr_i == 0 else 1.0) * hull_w * 0.32
		var trun := MeshInstance3D.new()
		var trun_cyl := CylinderMesh.new()
		trun_cyl.top_radius = 0.10
		trun_cyl.bottom_radius = 0.10
		trun_cyl.height = 0.10
		trun_cyl.radial_segments = 12
		trun.mesh = trun_cyl
		trun.rotation.z = PI * 0.5
		trun.position = Vector3(trx, deck_y + 0.30, hull_len * 0.10)
		var trun_mat := _make_metal_mat(Color(0.10, 0.09, 0.08))
		trun.set_surface_override_material(0, trun_mat)
		member.add_child(trun)
		mats.append(trun_mat)

	# Launcher pivot -- tilts the whole housing back so the front
	# face (tubes) points up-forward. Pivot positioned at the
	# trunnion line so the rotation reads as an elevation arm.
	# Sign flipped from -22° to +22° per playtest 2026-05-15:
	# negative X rotation made the tubes point DOWN-and-forward
	# (rockets would have plowed into the dirt at the unit's feet).
	# Positive X rotation ties to the right-hand rule so local -Z
	# (forward) sweeps up to point at the sky.
	var launcher_pivot := Node3D.new()
	launcher_pivot.name = "LauncherPivot"
	launcher_pivot.position = Vector3(0.0, deck_y + 0.30, hull_len * 0.10)
	launcher_pivot.rotation.x = deg_to_rad(22.0)
	member.add_child(launcher_pivot)

	# Housing -- single rectangular launcher block. Built in
	# launcher-local space so the tilt carries everything together.
	# Local -Z is "forward" of the housing (the tube face).
	var housing_w: float = hull_w * 0.62
	var housing_h: float = 0.62
	var housing_d: float = hull_len * 0.62
	var housing := MeshInstance3D.new()
	var housing_box := BoxMesh.new()
	housing_box.size = Vector3(housing_w, housing_h, housing_d)
	housing.mesh = housing_box
	# Centre the housing so the trunnion sits at the housing's
	# bottom-rear corner -- gives a believable elevation arm.
	housing.position = Vector3(0.0, housing_h * 0.5, -housing_d * 0.5 + 0.10)
	var housing_mat := _make_metal_mat(_faction_tint_chassis(Color(0.30, 0.22, 0.16)))
	housing.set_surface_override_material(0, housing_mat)
	launcher_pivot.add_child(housing)
	mats.append(housing_mat)
	# Top spine plate -- a slim raised dark strip running the
	# length of the housing. Breaks the silhouette and reads as
	# a structural rib.
	var spine := MeshInstance3D.new()
	var spine_box := BoxMesh.new()
	spine_box.size = Vector3(housing_w * 0.12, 0.06, housing_d * 0.94)
	spine.mesh = spine_box
	spine.position = Vector3(0.0, housing_h + 0.03, housing.position.z)
	var spine_mat := _make_metal_mat(Color(0.10, 0.09, 0.08))
	spine.set_surface_override_material(0, spine_mat)
	launcher_pivot.add_child(spine)
	mats.append(spine_mat)
	# Side rails -- thin emissive amber strips along the launcher's
	# upper side edges. Sells "loaded and armed" without needing a
	# light per tube.
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(1.00, 0.55, 0.18, 1.0)
	rail_mat.emission_enabled = true
	rail_mat.emission = Color(1.00, 0.55, 0.18, 1.0)
	rail_mat.emission_energy_multiplier = 1.4
	rail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for rail_side: int in 2:
		var rsx: float = (-1.0 if rail_side == 0 else 1.0) * (housing_w * 0.5 + 0.025)
		var rail := MeshInstance3D.new()
		var rail_box := BoxMesh.new()
		rail_box.size = Vector3(0.05, 0.06, housing_d * 0.78)
		rail.mesh = rail_box
		rail.position = Vector3(rsx, housing_h * 0.85, housing.position.z)
		rail.set_surface_override_material(0, rail_mat)
		launcher_pivot.add_child(rail)
	mats.append(rail_mat)

	# 6 tube openings drilled into the housing's front face.
	# Front face is at local Z = housing.position.z - housing_d*0.5.
	# Each tube = a short dark cylinder protruding out the front
	# (the bore) + an emissive amber rocket nose tip just inside.
	const ROWS: int = 3
	const COLS: int = 2
	var tube_radius: float = 0.13
	var tube_protrude: float = 0.18
	var front_z: float = housing.position.z - housing_d * 0.5
	# Tubes laid out vertically by row, side-by-side by column.
	# Vertical spacing tuned so all 6 fit inside the housing face
	# with clear divider strips between them.
	var col_dx: float = housing_w * 0.22
	var row_dy: float = housing_h * 0.26
	var bore_mat := _make_metal_mat(Color(0.06, 0.05, 0.04))
	var rim_mat := _make_metal_mat(Color(0.16, 0.13, 0.10))
	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = Color(1.00, 0.55, 0.18, 1.0)
	tip_mat.emission_enabled = true
	tip_mat.emission = Color(1.00, 0.55, 0.18, 1.0)
	tip_mat.emission_energy_multiplier = 1.6
	tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for r_i: int in ROWS:
		for c_i: int in COLS:
			var tx: float = (-1.0 if c_i == 0 else 1.0) * col_dx
			# Centre the 3-row stack vertically across the housing.
			var ty: float = housing_h * 0.5 + (float(r_i) - 1.0) * row_dy
			var tube_centre_z: float = front_z - tube_protrude * 0.5
			# Outer rim ring -- slightly larger than the bore so
			# each tube reads as a flanged opening, not a hole.
			var rim := MeshInstance3D.new()
			var rim_cyl := CylinderMesh.new()
			rim_cyl.top_radius = tube_radius * 1.18
			rim_cyl.bottom_radius = tube_radius * 1.18
			rim_cyl.height = 0.04
			rim_cyl.radial_segments = 14
			rim.mesh = rim_cyl
			rim.rotation.x = PI * 0.5
			rim.position = Vector3(tx, ty, front_z - 0.02)
			rim.set_surface_override_material(0, rim_mat)
			launcher_pivot.add_child(rim)
			# Bore -- the actual visible tube. Dark interior so
			# the player reads "rocket comes out of here".
			var bore := MeshInstance3D.new()
			var bore_cyl := CylinderMesh.new()
			bore_cyl.top_radius = tube_radius
			bore_cyl.bottom_radius = tube_radius
			bore_cyl.height = tube_protrude
			bore_cyl.radial_segments = 14
			bore.mesh = bore_cyl
			bore.rotation.x = PI * 0.5
			bore.position = Vector3(tx, ty, tube_centre_z)
			bore.set_surface_override_material(0, bore_mat)
			launcher_pivot.add_child(bore)
			# Rocket nose tip just inside the bore -- tiny
			# emissive cone peeking out so the launcher reads
			# loaded.
			var tip := MeshInstance3D.new()
			var tip_cyl := CylinderMesh.new()
			tip_cyl.top_radius = 0.0
			tip_cyl.bottom_radius = tube_radius * 0.74
			tip_cyl.height = 0.16
			tip_cyl.radial_segments = 10
			tip.mesh = tip_cyl
			tip.rotation.x = -PI * 0.5  # cone points -Z (forward)
			tip.position = Vector3(tx, ty, front_z - tube_protrude - 0.03)
			tip.set_surface_override_material(0, tip_mat)
			launcher_pivot.add_child(tip)
	mats.append(bore_mat)
	mats.append(rim_mat)
	mats.append(tip_mat)

	# Cannon pivot for combat lookups -- positioned just in front
	# of the launcher's tube face so missile spawns originate from
	# the battery's muzzle, not the chassis centre. Parented to the
	# tilted launcher_pivot so spawn point inherits the elevation
	# angle.
	var cannon_pivot := Node3D.new()
	cannon_pivot.name = "CannonPivot_top"
	cannon_pivot.position = Vector3(0.0, housing_h * 0.5, front_z - tube_protrude - 0.20)
	launcher_pivot.add_child(cannon_pivot)
	var muzzle_marker := Marker3D.new()
	muzzle_marker.name = "Muzzle"
	muzzle_marker.position = Vector3(0.0, 0.0, 0.0)
	cannon_pivot.add_child(muzzle_marker)
	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [] as Array,
		"cannons": [cannon_pivot] as Array[Node3D],
		"cannon_rest_z": [cannon_pivot.position.z] as Array,
		"cannon_muzzle_z": [0.0] as Array,
		"torso": null,
		"head": null,
		"mats": mats,
		"recoil": [0.0],
		"stride_phase": 0.0,
		"stride_speed": 0.0,
		"stride_swing": 0.0,
		"bob_amount": 0.0,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.0,
	}


func _build_grinder_tank_member(index: int, offset: Vector3, team_color: Color) -> Dictionary:
	## Combine VA-5 Boyar (base hull) — medium tracked tank with a normal
	## rotating turret and a dozer prow on the front. Distinct from
	## the Boyar casemate (no turret) and the Meridian
	## Courier (Combine amber stripe + dozer blade out front).
	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []
	var anvil_dark: Color = _faction_tint_chassis(Color(0.22, 0.20, 0.18))
	var anvil_mid: Color = _faction_tint_chassis(Color(0.32, 0.28, 0.24))
	var anvil_amber: Color = Color(1.00, 0.55, 0.18)

	# --- Tracks.
	var track_len: float = 2.70
	var track_h: float = 0.40
	var track_w: float = 0.40
	for side: int in 2:
		var sx: float = -0.95 if side == 0 else 0.95
		var track := MeshInstance3D.new()
		var track_box := BoxMesh.new()
		track_box.size = Vector3(track_w, track_h, track_len)
		track.mesh = track_box
		track.position = Vector3(sx, track_h * 0.5, 0.0)
		var track_mat := _make_metal_mat(Color(0.08, 0.08, 0.10))
		track.set_surface_override_material(0, track_mat)
		member.add_child(track)
		mats.append(track_mat)
		# Animated track ribs -- registered with the unit's
		# _courier_track_ribs list so _process scrolls them along
		# the track's Z axis as the tank moves.
		for r_i: int in 5:
			var rib := MeshInstance3D.new()
			var rib_box := BoxMesh.new()
			rib_box.size = Vector3(track_w + 0.04, 0.05, 0.16)
			rib.mesh = rib_box
			var rt: float = (float(r_i) + 0.5) / 5.0
			rib.position = Vector3(sx, track_h, -track_len * 0.5 + rt * track_len)
			var rib_mat := _make_metal_mat(Color(0.05, 0.05, 0.05))
			rib.set_surface_override_material(0, rib_mat)
			member.add_child(rib)
			mats.append(rib_mat)
			_courier_track_ribs.append({"node": rib, "length": track_len})
	# --- Hull (thicker than Courier; medium rather than the Breacher's
	# wide casemate stance).
	var hull_w: float = 1.65
	var hull_h: float = 0.55
	var hull_len: float = 2.20
	var hull_y: float = track_h + hull_h * 0.5
	var hull := MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(hull_w, hull_h, hull_len)
	hull.mesh = hull_box
	hull.position = Vector3(0.0, hull_y, 0.0)
	var hull_mat := _make_metal_mat(anvil_mid)
	hull.set_surface_override_material(0, hull_mat)
	member.add_child(hull)
	mats.append(hull_mat)

	# --- Dozer prow on the front. Wide angled blade clearly visible
	# from above -- this is the unit's primary visual identity.
	var blade := MeshInstance3D.new()
	var blade_box := BoxMesh.new()
	blade_box.size = Vector3(hull_w * 1.55, 0.45, 0.30)
	blade.mesh = blade_box
	blade.rotation.x = deg_to_rad(-30.0)  # tipped forward like a real plow
	blade.position = Vector3(0.0, hull_y - hull_h * 0.10, -hull_len * 0.5 - 0.18)
	var blade_mat := _make_metal_mat(anvil_dark)
	blade.set_surface_override_material(0, blade_mat)
	member.add_child(blade)
	mats.append(blade_mat)
	# Amber warning stripe along the prow's leading edge.
	var blade_stripe := MeshInstance3D.new()
	var bs_box := BoxMesh.new()
	bs_box.size = Vector3(hull_w * 1.50, 0.04, 0.06)
	blade_stripe.mesh = bs_box
	blade_stripe.rotation.x = deg_to_rad(-30.0)
	blade_stripe.position = Vector3(0.0, hull_y - hull_h * 0.32, -hull_len * 0.5 - 0.28)
	var bs_mat := StandardMaterial3D.new()
	bs_mat.albedo_color = anvil_amber
	bs_mat.emission_enabled = true
	bs_mat.emission = anvil_amber
	bs_mat.emission_energy_multiplier = 1.4
	bs_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	blade_stripe.set_surface_override_material(0, bs_mat)
	member.add_child(blade_stripe)
	mats.append(bs_mat)

	# --- Turret on top.
	var turret_y: float = hull_y + hull_h * 0.5
	var turret_pivot := Node3D.new()
	turret_pivot.name = "TurretPivot"
	turret_pivot.position = Vector3(0.0, turret_y + 0.15, 0.0)
	member.add_child(turret_pivot)
	var turret := MeshInstance3D.new()
	var turret_box := BoxMesh.new()
	turret_box.size = Vector3(hull_w * 0.75, 0.40, hull_len * 0.50)
	turret.mesh = turret_box
	var turret_mat := _make_metal_mat(anvil_dark)
	turret.set_surface_override_material(0, turret_mat)
	turret_pivot.add_child(turret)
	mats.append(turret_mat)
	# Cannon pivot lives on the turret so recoil + muzzle resolve.
	var cannon_pivot := Node3D.new()
	cannon_pivot.name = "CannonPivot_top"
	cannon_pivot.position = Vector3(0.0, 0.0, -hull_len * 0.20)
	turret_pivot.add_child(cannon_pivot)
	var barrel_len: float = 1.10
	var barrel := MeshInstance3D.new()
	var barrel_cyl := CylinderMesh.new()
	barrel_cyl.top_radius = 0.10
	barrel_cyl.bottom_radius = 0.12
	barrel_cyl.height = barrel_len
	barrel_cyl.radial_segments = 20
	barrel.mesh = barrel_cyl
	barrel.rotate_object_local(Vector3.RIGHT, -PI / 2)
	barrel.position.z = -barrel_len * 0.5
	var barrel_mat := _make_metal_mat(Color(0.16, 0.16, 0.16))
	barrel.set_surface_override_material(0, barrel_mat)
	cannon_pivot.add_child(barrel)
	mats.append(barrel_mat)
	var muzzle_marker := Marker3D.new()
	muzzle_marker.name = "Muzzle"
	muzzle_marker.position = Vector3(0.0, 0.0, -barrel_len - 0.05)
	cannon_pivot.add_child(muzzle_marker)

	# Single rear exhaust stack.
	var stack := MeshInstance3D.new()
	var stack_cyl := CylinderMesh.new()
	stack_cyl.top_radius = 0.09
	stack_cyl.bottom_radius = 0.11
	stack_cyl.height = 0.42
	stack_cyl.radial_segments = 14
	stack.mesh = stack_cyl
	stack.position = Vector3(hull_w * 0.32, turret_y + 0.55, hull_len * 0.40)
	var stack_mat := _make_metal_mat(Color(0.08, 0.08, 0.08))
	stack.set_surface_override_material(0, stack_mat)
	member.add_child(stack)
	mats.append(stack_mat)

	return {
		"root": member,
		"legs": [] as Array,
		"leg_phases": [] as Array,
		"shoulders": [] as Array,
		"cannons": [cannon_pivot] as Array[Node3D],
		"cannon_rest_z": [cannon_pivot.position.z] as Array,
		"cannon_muzzle_z": [barrel_len + 0.05] as Array,
		"torso": null,
		"head": null,
		"mats": mats,
		"recoil": [0.0],
		"stride_phase": 0.0,
		"stride_speed": 0.0,
		"stride_swing": 0.0,
		"bob_amount": 0.0,
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": 0.0,
	}


func _build_legs(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D], kind: String) -> Dictionary:
	## Dispatches to one of several skeletons. Each helper builds its meshes
	## under `member`, registers their materials in `mats`, and returns the
	## list of pivot Node3Ds (rotated around X for swing) plus a parallel
	## list of phase offsets so the walk animation knows when each leg should
	## be at the front/back of its stride.
	match kind:
		"chicken": return _build_legs_chicken(member, shape, mats)
		"spider": return _build_legs_spider(member, shape, mats)
		"insect": return _build_legs_insect(member, shape, mats)
		"quadruped": return _build_legs_quadruped(member, shape, mats)
		_: return _build_legs_biped(member, shape, mats)


func _build_legs_insect(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	## Articulated six-leg insect/carapace skeleton. Each leg has a
	## thigh + shin segment that bend at the knee so the foot lands
	## flat on the ground regardless of the chassis hip_y. Built for
	## the Forgemaster -- the previous spider build splayed straight-
	## stub legs that floated 0.5-1u above the floor and read as
	## 'mech standing on tiptoe'. The shin angles inward and down to
	## reach Y=0; the thigh sits roughly horizontal so the leg
	## silhouette is recognisably articulated, not a slanted stick.
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var base_color: Color = shape["color"] as Color
	var trim_color: Color = Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85)

	# Segment dimensions. Bulkier than the spider build -- the
	# Forgemaster reads as a heavy support frame, not a wasp.
	var seg_thick: float = leg_size.x * 1.55
	var thigh_len: float = leg_size.y * 0.55
	# Shin length is tuned per-call so foot lands at Y=0 from any
	# hip height. Uses the geometry: thigh extends laterally at
	# THIGH_DROP_RATIO downward, then shin travels inward+down to
	# the floor. Shin = hip_y - thigh_drop, since it's roughly
	# vertical at rest.
	const THIGH_DROP_RATIO: float = 0.25  # thigh angles slightly down
	var thigh_drop: float = thigh_len * THIGH_DROP_RATIO
	var shin_len: float = maxf(hip_y - thigh_drop, 0.4)

	var anchor_y: float = hip_y
	var anchor_x: float = torso_size.x * 0.5 + 0.06
	var anchor_z_front: float = torso_size.z * 0.36
	var anchor_z_mid: float = 0.0
	var anchor_z_rear: float = -torso_size.z * 0.36
	var corners: Array[Vector2] = [
		Vector2(-anchor_x, anchor_z_front),    # 0 front-left
		Vector2(anchor_x, anchor_z_front),     # 1 front-right
		Vector2(-anchor_x, anchor_z_mid),      # 2 mid-left
		Vector2(anchor_x, anchor_z_mid),       # 3 mid-right
		Vector2(-anchor_x, anchor_z_rear),     # 4 rear-left
		Vector2(anchor_x, anchor_z_rear),      # 5 rear-right
	]

	var legs: Array[Node3D] = []
	for i: int in corners.size():
		var c: Vector2 = corners[i]
		# Hip pivot -- this is the rotating root the walk-bob code
		# swings around X. Sits at the chassis hip height.
		var hip := Node3D.new()
		hip.name = "LegPivot_%d" % i
		hip.position = Vector3(c.x, anchor_y, c.y)
		member.add_child(hip)

		# Hip cap detail (small dark ball where the leg joins).
		var hip_cap := MeshInstance3D.new()
		var hip_box := BoxMesh.new()
		hip_box.size = Vector3(seg_thick * 1.4, seg_thick * 0.9, seg_thick * 1.4)
		hip_cap.mesh = hip_box
		var hip_mat := _make_metal_mat(trim_color)
		hip_cap.set_surface_override_material(0, hip_mat)
		hip.add_child(hip_cap)
		mats.append(hip_mat)

		# Thigh -- horizontal segment angling outward + slightly
		# downward. Right legs splay +x, left legs splay -x. The
		# thigh leaves the hip and ends at the knee.
		var splay_dir: float = 1.0 if c.x > 0.0 else -1.0
		var thigh := MeshInstance3D.new()
		var thigh_box := BoxMesh.new()
		thigh_box.size = Vector3(thigh_len, seg_thick, seg_thick * 0.95)
		thigh.mesh = thigh_box
		# Place the thigh box centered between hip and knee. Knee
		# sits at lateral offset thigh_len * splay_dir, dropped by
		# thigh_drop.
		thigh.position = Vector3(thigh_len * 0.5 * splay_dir, -thigh_drop * 0.5, 0.0)
		# Tilt around Z so the box reads as angling down toward the
		# knee rather than flat horizontal.
		thigh.rotation.z = -0.18 * splay_dir if splay_dir > 0.0 else 0.18
		var thigh_mat := _make_metal_mat(base_color)
		thigh.set_surface_override_material(0, thigh_mat)
		hip.add_child(thigh)
		mats.append(thigh_mat)

		# Knee joint detail.
		var knee := MeshInstance3D.new()
		var knee_box := BoxMesh.new()
		knee_box.size = Vector3(seg_thick * 1.2, seg_thick * 1.2, seg_thick * 1.2)
		knee.mesh = knee_box
		knee.position = Vector3(thigh_len * splay_dir, -thigh_drop, 0.0)
		var knee_mat := _make_metal_mat(trim_color)
		knee.set_surface_override_material(0, knee_mat)
		hip.add_child(knee)
		mats.append(knee_mat)

		# Shin -- drops from the knee to the ground at Y = -hip_y.
		# Slight inward tilt so the foot pads sit a little inside
		# the knee width (a stable triangulated stance).
		var foot_y: float = -hip_y  # absolute floor level relative to hip pivot
		var foot_x: float = thigh_len * splay_dir * 0.85  # inward bias from knee
		var shin_dx: float = foot_x - thigh_len * splay_dir
		var shin_dy: float = foot_y - (-thigh_drop)
		var shin_actual_len: float = sqrt(shin_dx * shin_dx + shin_dy * shin_dy)
		var shin_angle: float = atan2(shin_dx, -shin_dy)  # rotation around Z
		var shin := MeshInstance3D.new()
		var shin_box := BoxMesh.new()
		shin_box.size = Vector3(seg_thick * 0.9, shin_actual_len, seg_thick * 0.9)
		shin.mesh = shin_box
		var shin_pos: Vector3 = Vector3(
			(thigh_len * splay_dir + foot_x) * 0.5,
			(-thigh_drop + foot_y) * 0.5,
			0.0,
		)
		shin.position = shin_pos
		shin.rotation.z = shin_angle
		var shin_mat := _make_metal_mat(base_color)
		shin.set_surface_override_material(0, shin_mat)
		hip.add_child(shin)
		mats.append(shin_mat)

		# Foot pad -- flat plate sitting on the ground.
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(seg_thick * 1.6, 0.06, seg_thick * 1.8)
		foot.mesh = foot_box
		foot.position = Vector3(foot_x, foot_y + 0.03, 0.0)
		var foot_mat := _make_metal_mat(Color(0.10, 0.10, 0.11))
		foot.set_surface_override_material(0, foot_mat)
		hip.add_child(foot)
		mats.append(foot_mat)

		legs.append(hip)
	# Alternating tripod gait, same as spider: phases [FL, FR, ML, MR, RL, RR]
	# = [0, PI, PI, 0, 0, PI]. Tripod A (FL, MR, RL) lifts together,
	# tripod B (FR, ML, RR) follows. Reads as a real insect gait at
	# distance.
	return { "legs": legs, "phases": [0.0, PI, PI, 0.0, 0.0, PI] }


func _build_legs_biped(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var leg_x: float = shape["leg_x"] as float
	var base_color: Color = shape["color"] as Color

	var legs: Array[Node3D] = []
	for side: int in 2:
		var sx: float = -leg_x if side == 0 else leg_x
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % side
		pivot.position = Vector3(sx, hip_y, 0)
		member.add_child(pivot)
		_attach_leg_segment(pivot, leg_size, base_color, mats, true)
		legs.append(pivot)

	return { "legs": legs, "phases": [0.0, PI] }


func _build_legs_chicken(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	## Proper digitigrade legs (raptor / chicken): the thigh pitches BACK
	## from the hip so the knee sits BEHIND the body, the shin then pitches
	## forward to plant the foot under or slightly ahead of the hip, and
	## the talons spread forward. Reads as a fast strider, not a humanoid.
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var leg_x: float = shape["leg_x"] as float
	var base_color: Color = shape["color"] as Color
	# Segment lengths chosen so the bent geometry plants the foot at
	# y=0. Thigh tilts -0.55 (cos 0.85), shin tilts forward by +1.0
	# (cos 0.54). Vertical reach = (thigh + shin) * 0.72 ≈ hip_y, so
	# the foot lands flat instead of dangling 0.2u above the floor
	# (the previous 0.58 scalar produced a visible gap on Hound /
	# medium chicken-walkers).
	var thigh_len: float = hip_y * 0.72
	var shin_len: float = hip_y * 0.72
	var thigh_size := Vector3(leg_size.x, thigh_len, leg_size.z)
	var shin_size := Vector3(leg_size.x * 0.85, shin_len, leg_size.z * 0.85)

	var legs: Array[Node3D] = []
	for side: int in 2:
		var sx: float = -leg_x if side == 0 else leg_x
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % side
		pivot.position = Vector3(sx, hip_y, 0)
		member.add_child(pivot)

		# Thigh tilts BACKWARD from the hip — the knee is now behind the
		# body, mirroring a real digitigrade animal. With unit-forward at
		# +Z, "backward" is -Z, so the thigh's bottom rotates toward -Z
		# via a NEGATIVE X-axis rotation.
		var thigh_rot := Node3D.new()
		thigh_rot.rotation.x = -0.55
		pivot.add_child(thigh_rot)

		var thigh_mesh := MeshInstance3D.new()
		var thigh_box := BoxMesh.new()
		thigh_box.size = thigh_size
		thigh_mesh.mesh = thigh_box
		thigh_mesh.position.y = -thigh_len / 2.0
		var thigh_mat := _make_metal_mat(base_color)
		thigh_mesh.set_surface_override_material(0, thigh_mat)
		thigh_rot.add_child(thigh_mesh)
		mats.append(thigh_mat)

		# Knee node — at the bottom (and slightly back) end of the thigh.
		var knee := Node3D.new()
		knee.position.y = -thigh_len
		thigh_rot.add_child(knee)

		# Shin pitches FORWARD from the knee so the foot lands beneath
		# or slightly ahead of the hip. Positive X-axis rotation with
		# the local forward at +Z.
		var shin_rot := Node3D.new()
		shin_rot.rotation.x = 1.0
		knee.add_child(shin_rot)

		var shin_mesh := MeshInstance3D.new()
		var shin_box := BoxMesh.new()
		shin_box.size = shin_size
		shin_mesh.mesh = shin_box
		shin_mesh.position.y = -shin_len / 2.0
		var shin_mat := _make_metal_mat(base_color)
		shin_mesh.set_surface_override_material(0, shin_mat)
		shin_rot.add_child(shin_mesh)
		mats.append(shin_mat)

		# Talon-style foot — extends forward of the ankle so the toes
		# read as a raptor's spread claws when the leg is planted.
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(leg_size.x * 1.1, 0.08, leg_size.z * 2.4)
		foot.mesh = foot_box
		foot.position = Vector3(0, -shin_len - 0.04, leg_size.z * 0.5)
		var foot_mat := _make_metal_mat(Color(base_color.r * 0.65, base_color.g * 0.65, base_color.b * 0.65))
		foot.set_surface_override_material(0, foot_mat)
		shin_rot.add_child(foot)
		mats.append(foot_mat)

		legs.append(pivot)

	return { "legs": legs, "phases": [0.0, PI] }


func _build_legs_spider(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	## Six legs in left/right pairs along the chassis sides — fore, mid, rear.
	## Each leg sticks out laterally and bends down to a foot pad. Alternating
	## tripod gait: tripod A (front-left, mid-right, rear-left) swings, then
	## tripod B (front-right, mid-left, rear-right).
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var base_color: Color = shape["color"] as Color
	var trim_color: Color = Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85)

	var anchor_y: float = hip_y + torso_size.y * 0.45
	var anchor_x: float = torso_size.x * 0.5 + 0.04
	# Spread three pairs evenly along the hull's length.
	var anchor_z_front: float = torso_size.z * 0.36
	var anchor_z_mid: float = 0.0
	var anchor_z_rear: float = -torso_size.z * 0.36

	var corners: Array[Vector2] = [
		Vector2(-anchor_x, anchor_z_front),    # 0 front-left
		Vector2(anchor_x, anchor_z_front),     # 1 front-right
		Vector2(-anchor_x, anchor_z_mid),      # 2 mid-left
		Vector2(anchor_x, anchor_z_mid),       # 3 mid-right
		Vector2(-anchor_x, anchor_z_rear),     # 4 rear-left
		Vector2(anchor_x, anchor_z_rear),      # 5 rear-right
	]
	var splay_z: float = 0.7

	var legs: Array[Node3D] = []
	for i: int in corners.size():
		var c: Vector2 = corners[i]
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % i
		pivot.position = Vector3(c.x, anchor_y, c.y)
		# Lean each leg outward. Right-side legs use +θ, left-side use -θ.
		pivot.rotation.z = splay_z if c.x > 0.0 else -splay_z
		member.add_child(pivot)

		# Hip-cap detail — small dark stub where the leg joins the chassis.
		var hip_cap := MeshInstance3D.new()
		var hip_box := BoxMesh.new()
		hip_box.size = Vector3(leg_size.x * 1.6, leg_size.y * 0.18, leg_size.z * 1.6)
		hip_cap.mesh = hip_box
		hip_cap.position.y = -leg_size.y * 0.04
		var hip_mat := _make_metal_mat(trim_color)
		hip_cap.set_surface_override_material(0, hip_mat)
		pivot.add_child(hip_cap)
		mats.append(hip_mat)

		# Main leg shaft.
		var leg_mesh := MeshInstance3D.new()
		var leg_box := BoxMesh.new()
		leg_box.size = leg_size
		leg_mesh.mesh = leg_box
		leg_mesh.position.y = -leg_size.y / 2.0
		var leg_mat := _make_metal_mat(base_color)
		leg_mesh.set_surface_override_material(0, leg_mat)
		pivot.add_child(leg_mesh)
		mats.append(leg_mat)

		# Tip claw — wider, darker foot pad at the leg's end.
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(leg_size.x * 1.6, 0.07, leg_size.z * 2.0)
		foot.mesh = foot_box
		foot.position.y = -leg_size.y - 0.035
		var foot_mat := _make_metal_mat(Color(0.12, 0.12, 0.12))
		foot.set_surface_override_material(0, foot_mat)
		pivot.add_child(foot)
		mats.append(foot_mat)

		legs.append(pivot)

	# Alternating-tripod gait: FL, MR, RL move together (phase 0); FR, ML, RR at PI.
	return { "legs": legs, "phases": [0.0, PI, PI, 0.0, 0.0, PI] }


func _build_legs_quadruped(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	## Four articulated legs at the corners of the torso footprint. Each
	## leg has a thigh + shin + foot with a forward-bending knee — gives
	## the Bulwark a proper tank-mech stance instead of stiff sticks.
	## Trot gait — diagonal pairs swing together.
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var leg_x: float = shape["leg_x"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var base_color: Color = shape["color"] as Color
	# Thigh tilts outward slightly, shin angles back IN — knee points
	# OUTWARD-AND-FORWARD on front legs, OUTWARD-AND-BACK on rear legs
	# (animal-style stance). 2 segments × hip_y × 0.55 + small foot
	# clearance roughly equals hip_y so the foot lands on the ground.
	var thigh_len: float = hip_y * 0.55
	var shin_len: float = hip_y * 0.55
	var thigh_size: Vector3 = Vector3(leg_size.x, thigh_len, leg_size.z)
	var shin_size: Vector3 = Vector3(leg_size.x * 0.82, shin_len, leg_size.z * 0.82)

	# Front legs slightly forward, rear legs slightly back.
	var leg_z: float = torso_size.z * 0.4
	var corners: Array[Vector2] = [
		Vector2(-leg_x, leg_z),    # front-left
		Vector2(leg_x, leg_z),     # front-right
		Vector2(-leg_x, -leg_z),   # rear-left
		Vector2(leg_x, -leg_z),    # rear-right
	]

	var legs: Array[Node3D] = []
	for i: int in corners.size():
		var c: Vector2 = corners[i]
		var is_front: bool = c.y > 0.0
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % i
		pivot.position = Vector3(c.x, hip_y, c.y)
		member.add_child(pivot)

		# Hip: thigh leans at ~45° from vertical (forward for front legs,
		# back for rear) so the knee is clearly bent rather than the
		# stick-straight stance the smaller 0.32 lean produced (playtest
		# 2026-05-15 — Voron Walker legs read as right-angle stilts).
		# Shin counter-rotates by the same magnitude below, so the shin
		# ends up vertical and the foot lands under the hip.
		var thigh_rot := Node3D.new()
		thigh_rot.rotation.x = 0.78 if is_front else -0.78  # ~45°
		# Roll outward just a touch so the legs splay.
		thigh_rot.rotation.z = -0.12 if c.x < 0.0 else 0.12
		pivot.add_child(thigh_rot)

		var thigh_mesh := MeshInstance3D.new()
		var thigh_box := BoxMesh.new()
		thigh_box.size = thigh_size
		thigh_mesh.mesh = thigh_box
		thigh_mesh.position.y = -thigh_len * 0.5
		var thigh_mat := _make_metal_mat(base_color)
		thigh_mesh.set_surface_override_material(0, thigh_mat)
		thigh_rot.add_child(thigh_mesh)
		mats.append(thigh_mat)

		# Knee — bottom of the thigh, where the shin pivots.
		var knee := Node3D.new()
		knee.position.y = -thigh_len
		thigh_rot.add_child(knee)

		# Shin counter-rotates by the same magnitude as the thigh so the
		# shin's world angle ends up vertical (knee is the only bend) and
		# the foot lands directly under the hip. Front legs bend back,
		# rear legs bend forward (classic horse stance, sharper now).
		var shin_rot := Node3D.new()
		shin_rot.rotation.x = -0.78 if is_front else 0.78
		knee.add_child(shin_rot)

		var shin_mesh := MeshInstance3D.new()
		var shin_box := BoxMesh.new()
		shin_box.size = shin_size
		shin_mesh.mesh = shin_box
		shin_mesh.position.y = -shin_len * 0.5
		var shin_mat := _make_metal_mat(Color(base_color.r * 0.92, base_color.g * 0.92, base_color.b * 0.95))
		shin_mesh.set_surface_override_material(0, shin_mat)
		shin_rot.add_child(shin_mesh)
		mats.append(shin_mat)

		# Foot — wide pad slightly larger than the leg cross-section.
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(leg_size.x * 1.5, 0.10, leg_size.z * 1.7)
		foot.mesh = foot_box
		foot.position.y = -shin_len - 0.05
		var foot_mat := _make_metal_mat(Color(base_color.r * 0.6, base_color.g * 0.6, base_color.b * 0.6))
		foot.set_surface_override_material(0, foot_mat)
		shin_rot.add_child(foot)
		mats.append(foot_mat)

		# Hip armor / shoulder cap — a small pauldron-like box sitting
		# atop the hip pivot, so the corner reads as "armoured joint"
		# rather than a bare cylinder.
		var hip_cap := MeshInstance3D.new()
		var hip_box := BoxMesh.new()
		hip_box.size = Vector3(leg_size.x * 1.6, leg_size.x * 0.9, leg_size.z * 1.6)
		hip_cap.mesh = hip_box
		hip_cap.position = Vector3(0, leg_size.x * 0.2, 0)
		var hip_mat := _make_metal_mat(Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85))
		hip_cap.set_surface_override_material(0, hip_mat)
		pivot.add_child(hip_cap)
		mats.append(hip_mat)

		legs.append(pivot)

	# Trot: front-left + rear-right swing together (phase 0); other pair at PI.
	return { "legs": legs, "phases": [0.0, PI, PI, 0.0] }


func _attach_leg_segment(parent: Node3D, leg_size: Vector3, base_color: Color, mats: Array[StandardMaterial3D], with_foot: bool) -> void:
	var leg_mesh := MeshInstance3D.new()
	var leg_box := BoxMesh.new()
	leg_box.size = leg_size
	leg_mesh.mesh = leg_box
	leg_mesh.position.y = -leg_size.y / 2.0
	var leg_mat := _make_metal_mat(base_color)
	leg_mesh.set_surface_override_material(0, leg_mat)
	parent.add_child(leg_mesh)
	mats.append(leg_mat)

	if with_foot:
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(leg_size.x * 1.4, 0.08, leg_size.z * 1.6)
		foot.mesh = foot_box
		# Foot pad sits AT ground level (top face touching ground at
		# y=0). The previous offset of -leg_size.y - 0.04 dropped the
		# bottom of the pad to y=-0.08 -- the foot was clipping into
		# the ground plane. With a 0.08-tall pad we want its centre
		# at -leg_size.y + 0.04 so the bottom face rests on y=0.
		foot.position.y = -leg_size.y + 0.04
		var foot_mat := _make_metal_mat(Color(base_color.r * 0.7, base_color.g * 0.7, base_color.b * 0.7))
		foot.set_surface_override_material(0, foot_mat)
		parent.add_child(foot)
		mats.append(foot_mat)


func _make_metal_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.albedo_texture = SharedTextures.get_metal_wear_texture()
	# Random uv offset so adjacent panels don't all sample the same patch
	# of grime — each member's chassis ends up with its own wear pattern.
	m.uv1_offset = Vector3(randf(), randf(), 0.0)
	m.uv1_scale = Vector3(2.0, 2.0, 1.0)
	m.roughness = 0.55
	m.metallic = 0.45
	return m


func _add_class_extras(torso_pivot: Node3D, torso_size: Vector3, head_size: Vector3, mats: Array[StandardMaterial3D], base_color: Color, unit_class: StringName) -> void:
	## Class-specific decorative pieces — gives each mech a recognisable
	## silhouette beyond the shared chassis grille and back vent.
	match unit_class:
		&"light":
			# Rook backpack — small box on the upper rear of the torso.
			var pack := MeshInstance3D.new()
			var pack_box := BoxMesh.new()
			pack_box.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.4, torso_size.z * 0.25)
			pack.mesh = pack_box
			pack.position = Vector3(0, torso_size.y * 0.55, torso_size.z * 0.5 + pack_box.size.z * 0.5)
			var pack_mat := _make_metal_mat(Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85))
			pack.set_surface_override_material(0, pack_mat)
			torso_pivot.add_child(pack)
			mats.append(pack_mat)
		&"medium":
			# Hound — cockpit door frame on the front of the cockpit and a
			# rear engine block.
			var door_frame := MeshInstance3D.new()
			var df_box := BoxMesh.new()
			df_box.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.55, 0.04)
			door_frame.mesh = df_box
			door_frame.position = Vector3(0, torso_size.y * 0.45, -torso_size.z * 0.5 - 0.025)
			var df_mat := _make_metal_mat(Color(base_color.r * 0.7, base_color.g * 0.7, base_color.b * 0.7))
			door_frame.set_surface_override_material(0, df_mat)
			torso_pivot.add_child(door_frame)
			mats.append(df_mat)

			var engine := MeshInstance3D.new()
			var eng_box := BoxMesh.new()
			eng_box.size = Vector3(torso_size.x * 0.65, torso_size.y * 0.55, torso_size.z * 0.25)
			engine.mesh = eng_box
			engine.position = Vector3(0, torso_size.y * 0.5, torso_size.z * 0.5 + eng_box.size.z * 0.5)
			var eng_mat := _make_metal_mat(Color(0.18, 0.15, 0.15))
			engine.set_surface_override_material(0, eng_mat)
			torso_pivot.add_child(engine)
			mats.append(eng_mat)
		&"apex":
			# Apex — chest plate, command spire on the head, and a heavy back
			# armor plate.
			var chest_plate := MeshInstance3D.new()
			var cp_box := BoxMesh.new()
			cp_box.size = Vector3(torso_size.x * 0.85, torso_size.y * 0.55, 0.08)
			chest_plate.mesh = cp_box
			chest_plate.position = Vector3(0, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.04)
			var cp_mat := _make_metal_mat(Color(base_color.r * 1.05, base_color.g * 1.05, base_color.b * 1.05))
			chest_plate.set_surface_override_material(0, cp_mat)
			torso_pivot.add_child(chest_plate)
			mats.append(cp_mat)

			# Command spire on top of the head.
			var spire := MeshInstance3D.new()
			var spire_box := BoxMesh.new()
			spire_box.size = Vector3(0.18, head_size.y * 0.7, 0.18)
			spire.mesh = spire_box
			spire.position = Vector3(0, torso_size.y + head_size.y + spire_box.size.y * 0.5, 0)
			var spire_mat := _make_metal_mat(Color(0.2, 0.2, 0.22))
			spire.set_surface_override_material(0, spire_mat)
			torso_pivot.add_child(spire)
			mats.append(spire_mat)

			# Heavy back armor plate.
			var back_plate := MeshInstance3D.new()
			var bp_box := BoxMesh.new()
			bp_box.size = Vector3(torso_size.x * 0.95, torso_size.y * 0.85, 0.12)
			back_plate.mesh = bp_box
			back_plate.position = Vector3(0, torso_size.y * 0.45, torso_size.z * 0.5 + 0.06)
			var bp_mat := _make_metal_mat(Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85))
			back_plate.set_surface_override_material(0, bp_mat)
			torso_pivot.add_child(back_plate)
			mats.append(bp_mat)
		&"engineer":
			# Ratchet — small tool brace below the claw arm and a hull rivet band.
			var brace := MeshInstance3D.new()
			var brace_box := BoxMesh.new()
			brace_box.size = Vector3(torso_size.x * 0.75, 0.05, torso_size.z * 0.6)
			brace.mesh = brace_box
			brace.position = Vector3(0, torso_size.y * 0.3, 0)
			var brace_mat := _make_metal_mat(Color(0.28, 0.25, 0.16))
			brace.set_surface_override_material(0, brace_mat)
			torso_pivot.add_child(brace)
			mats.append(brace_mat)
		_:
			pass


func _add_chassis_panels(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	## Tiny surface detail shared by all bipedal/chicken/spider mechs so they
	## read as engineered hulls rather than smooth boxes.
	# Chest grille — three thin parallel bars on the front of the torso.
	for i: int in 3:
		var bar := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(torso_size.x * 0.45, 0.04, 0.02)
		bar.mesh = bb
		bar.position = Vector3(
			0,
			torso_size.y * 0.4 + (float(i) - 1.0) * (torso_size.y * 0.12),
			-torso_size.z * 0.5 - 0.012
		)
		var bar_mat := _make_metal_mat(Color(0.08, 0.08, 0.1))
		bar.set_surface_override_material(0, bar_mat)
		torso_pivot.add_child(bar)
		mats.append(bar_mat)

	# Back vent — small panel on the back of the torso.
	var vent := MeshInstance3D.new()
	var vb := BoxMesh.new()
	vb.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.25, 0.04)
	vent.mesh = vb
	vent.position = Vector3(0, torso_size.y * 0.4, torso_size.z * 0.5 + 0.02)
	var vent_mat := _make_metal_mat(Color(0.08, 0.08, 0.1))
	vent.set_surface_override_material(0, vent_mat)
	torso_pivot.add_child(vent)
	mats.append(vent_mat)


func _build_hp_bar() -> void:
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()

	var bar_y: float = _mech_total_height() + 0.4

	_hp_bar = Node3D.new()
	_hp_bar.name = "HPBar"
	_hp_bar.position.y = bar_y

	# Background
	_hp_bar_bg = MeshInstance3D.new()
	var bg_box := BoxMesh.new()
	bg_box.size = Vector3(2.0, 0.12, 0.08)
	_hp_bar_bg.mesh = bg_box
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.7)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hp_bar_bg.set_surface_override_material(0, bg_mat)
	_hp_bar.add_child(_hp_bar_bg)

	# Fill
	_hp_bar_fill = MeshInstance3D.new()
	var fill_box := BoxMesh.new()
	fill_box.size = Vector3(1.0, 0.15, 0.1)
	_hp_bar_fill.mesh = fill_box
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.1, 0.9, 0.1, 0.9)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill_mat.emission_enabled = true
	fill_mat.emission = Color(0.1, 0.9, 0.1, 1.0)
	fill_mat.emission_energy_multiplier = 0.5
	_hp_bar_fill.set_surface_override_material(0, fill_mat)
	_hp_bar.add_child(_hp_bar_fill)

	# Squad-member dividers — vertical ticks at each per-member HP
	# boundary so the player can read at a glance how many members
	# are still alive and how close the next death is. squad_size 5
	# gives 4 dividers at 1/5, 2/5, 3/5, 4/5.
	if stats and stats.squad_size > 1:
		var bar_w: float = 2.0
		for i: int in stats.squad_size - 1:
			var frac: float = float(i + 1) / float(stats.squad_size)
			var divider := MeshInstance3D.new()
			var d_mesh := BoxMesh.new()
			# Widened from 0.04 → 0.08 so member boundaries are clearly
			# readable at combat zoom (bug C: more prominent separators).
			d_mesh.size = Vector3(0.08, 0.18, 0.14)
			divider.mesh = d_mesh
			var d_mat := StandardMaterial3D.new()
			d_mat.albedo_color = Color(0.02, 0.02, 0.02, 1.0)
			divider.set_surface_override_material(0, d_mat)
			divider.position = Vector3(-bar_w * 0.5 + frac * bar_w, 0.0, 0.01)
			_hp_bar.add_child(divider)

	# Reload progress bar — thinner whitegrey strip below the HP bar.
	# Updated from CombatComponent._fire_cooldown via _update_reload_bar.
	_reload_bar_bg = MeshInstance3D.new()
	var rl_bg_mesh := BoxMesh.new()
	rl_bg_mesh.size = Vector3(2.0, 0.06, 0.06)
	_reload_bar_bg.mesh = rl_bg_mesh
	var rl_bg_mat := StandardMaterial3D.new()
	rl_bg_mat.albedo_color = Color(0.08, 0.08, 0.08, 0.7)
	rl_bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_reload_bar_bg.set_surface_override_material(0, rl_bg_mat)
	_reload_bar_bg.position = Vector3(0, -0.16, 0)
	_hp_bar.add_child(_reload_bar_bg)
	_reload_bar_fill = MeshInstance3D.new()
	var rl_fill_mesh := BoxMesh.new()
	rl_fill_mesh.size = Vector3(1.0, 0.08, 0.07)
	_reload_bar_fill.mesh = rl_fill_mesh
	var rl_fill_mat := StandardMaterial3D.new()
	rl_fill_mat.albedo_color = Color(0.85, 0.85, 0.88, 0.9)
	rl_fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rl_fill_mat.emission_enabled = true
	rl_fill_mat.emission = Color(0.7, 0.7, 0.75, 1.0)
	rl_fill_mat.emission_energy_multiplier = 0.3
	_reload_bar_fill.set_surface_override_material(0, rl_fill_mat)
	_reload_bar_fill.position = Vector3(-1.0, -0.16, 0.01)
	_reload_bar_fill.scale.x = 0.01
	_hp_bar.add_child(_reload_bar_fill)

	# Top-level so it doesn't inherit unit rotation (prevents jitter)
	add_child(_hp_bar)
	_hp_bar.top_level = true
	_update_hp_bar()


func _update_hp_bar() -> void:
	if not _hp_bar_fill:
		return
	var pct: float = float(get_total_hp()) / float(maxi(stats.hp_total, 1))
	var bar_width: float = 2.0

	# Scale fill from left
	_hp_bar_fill.scale.x = maxf(pct * bar_width, 0.01)
	_hp_bar_fill.position.x = -bar_width / 2.0 * (1.0 - pct)

	# Color shift green → yellow → red
	var fill_mat: StandardMaterial3D = _hp_bar_fill.get_surface_override_material(0) as StandardMaterial3D
	if fill_mat:
		var r: float = 1.0 - pct
		var g: float = pct
		fill_mat.albedo_color = Color(r, g, 0.1, 0.9)
		fill_mat.emission = Color(r, g, 0.1, 1.0)

	_update_reload_bar()


func _update_reload_bar() -> void:
	## Whitegrey reload bar under the HP bar. Computes fill from real
	## wall-clock time since the most recent fire (combat tick is
	## staggered to 20Hz, so reading _fire_cooldown directly produced
	## visible 50ms steps). Fills from empty (just fired) toward
	## full (ready to fire). Hidden once ready.
	## Combat is read as a typed CombatComponent so the cooldown
	## fields land via direct property access, not Node.get(string).
	## Profile flagged the previous string-keyed lookups as a hot
	## spot (every actively-firing unit ran 2 dict lookups per tick).
	if not _reload_bar_fill:
		return
	var combat: CombatComponent = get_combat() as CombatComponent
	if not combat or not stats or not stats.primary_weapon:
		_reload_bar_fill.visible = false
		if _reload_bar_bg:
			_reload_bar_bg.visible = false
		return
	var cd_max: float = combat._fire_cooldown_max
	if cd_max <= 0.0:
		cd_max = 1.0
	var set_at: int = combat._fire_cooldown_set_at_msec
	if set_at == 0:
		# Never fired — bar full = ready, but hidden because no
		# pending reload to show.
		_reload_bar_fill.visible = false
		if _reload_bar_bg:
			_reload_bar_bg.visible = false
		return
	var elapsed_sec: float = float(Time.get_ticks_msec() - set_at) / 1000.0
	var pct: float = clampf(elapsed_sec / cd_max, 0.0, 1.0)
	var bar_width: float = 2.0
	_reload_bar_fill.scale.x = maxf(pct * bar_width, 0.01)
	_reload_bar_fill.position.x = -bar_width / 2.0 * (1.0 - pct)
	var ready: bool = pct >= 0.999
	_reload_bar_fill.visible = not ready
	if _reload_bar_bg:
		_reload_bar_bg.visible = not ready


func _mech_total_height() -> float:
	if not stats:
		return 2.0
	# Transport class units carry their visual height in their
	# bespoke build functions, NOT in CLASS_SHAPES (which only
	# stores formation_spacing / turn_speed for tracked vehicles).
	# Without a per-unit-name override the HP bar lands inside
	# the chassis -- the Breacher casemate sits ~1.7u tall while
	# the default transport reading was 0.5u, hiding the bar.
	if stats.unit_class == &"transport":
		if stats.unit_name.findn("Breacher") >= 0:
			return 1.95
		# Meridian Courier default.
		return 1.40
	var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	var hip_y: float = shape["hip_y"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var head_size: Vector3 = shape["head"] as Vector3
	return hip_y + torso_size.y + head_size.y


func _remove_member_visual(index: int) -> void:
	if index < _member_meshes.size():
		var member: Node3D = _member_meshes[index]
		if is_instance_valid(member):
			member.visible = false
			# Spawn flying debris at member's world position
			_spawn_member_debris(member.global_position)
			# A small salvage pile per dead squad member — partial cost
			# refund for whoever clears it. Squad death spawns its own
			# bigger wreck via _die(); this is just the per-member chunk.
			_spawn_member_wreck(member.global_position)
	# Reform the surviving members into the formation slots for the
	# new alive_count so the squad keeps a balanced shape around its
	# centre. Only rebalance immediately if the squad is currently
	# moving — a stationary squad shouldn't visibly shuffle around
	# every time a member dies. Defer the reform to the next move
	# command so the player sees a clean reformation in motion
	# instead of teleport-corrections at rest.
	if has_move_order:
		_rebalance_formation()
	else:
		_rebalance_pending = true


func _rebalance_formation() -> void:
	## Reassigns local member positions to the formation slots for the
	## current alive_count. Ratchet of 5 -> 3 will swap the surviving
	## members into the 3-slot triangle layout; squad keeps its centre
	## instead of trailing a corner gap. Tween (~0.4s) so the
	## reposition reads as a deliberate close-up rather than a
	## teleport. No-op when alive_count == squad_size or stats is
	## missing (rare during scene teardown).
	if not stats or alive_count <= 0:
		return
	if alive_count >= stats.squad_size:
		return
	var unit_offsets_v: Variant = FORMATION_OFFSETS.get(alive_count, null)
	if unit_offsets_v == null:
		return
	var unit_offsets: Array = unit_offsets_v as Array
	var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	shape_data = _maybe_override_shape_for_unit(shape_data)
	var spacing: float = shape_data.get("formation_spacing", 1.5) as float
	# Walk surviving members in their original index order so the new
	# slot list maps them deterministically (slot 0 -> first survivor,
	# slot 1 -> second survivor, etc). Without the deterministic order
	# the leader / trailing reads can flip frame-to-frame.
	var slot_idx: int = 0
	for i: int in _member_data.size():
		if i >= member_hp.size() or member_hp[i] <= 0:
			continue
		if slot_idx >= unit_offsets.size():
			break
		var u: Vector2 = unit_offsets[slot_idx] as Vector2
		var new_offset := Vector3(u.x * spacing, 0.0, u.y * spacing)
		slot_idx += 1
		var member: Node3D = _member_meshes[i] if i < _member_meshes.size() else null
		if not is_instance_valid(member):
			continue
		# Tween, but cancel any prior rebalance tween on this member
		# so back-to-back deaths don't queue stale lerps. Guard with
		# has_meta to avoid Godot 4's "object does not have any meta
		# values with the key" runtime warning that fires the first
		# time the rebalance runs on a freshly-built squad.
		if member.has_meta("rebalance_tween"):
			var prev_tween: Tween = member.get_meta("rebalance_tween") as Tween
			if prev_tween and prev_tween.is_valid():
				prev_tween.kill()
		var t := member.create_tween()
		t.tween_property(member, "position", new_offset, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		member.set_meta("rebalance_tween", t)


func _spawn_member_wreck(world_pos: Vector3) -> void:
	if not stats:
		return
	# Each member is roughly 1/squad_size of the squad's value, and we yield
	# the same ~30% of cost that the full-squad Wreck does.
	var squad_size: int = maxi(stats.squad_size, 1)
	var per_member_value: int = int(round(float(stats.cost_salvage) * 0.3 / float(squad_size)))
	if per_member_value <= 0:
		return
	var wreck: Wreck = Wreck.new()
	wreck.salvage_value = per_member_value
	wreck.salvage_remaining = per_member_value
	# Smaller wreck visual than the full-squad version. Always Light-class
	# size so a Crawler can crush it.
	wreck.wreck_size = Vector3(0.7, 0.3, 0.7)
	wreck.position = world_pos
	get_tree().current_scene.add_child(wreck)


## --- Movement ---

func command_move(target: Vector3, clear_combat: bool = true) -> void:
	## Move toward `target`. By default this also clears any combat target
	## (player-issued moves preempt combat). Pass `clear_combat=false` for
	## combat-internal chase commands so the chaser doesn't immediately wipe
	## its own forced target. Plain move clears any pending waypoint queue,
	## the patrol pair, and the stand-ground flag — those are all
	## superseded by an explicit move.
	# Wächter deploy gate: a deployed or mid-transition unit cannot move.
	# Combat-internal chase commands (clear_combat=false) are also blocked
	# while deployed so the unit stays in place and fights.
	if is_deployed or _deploy_locked:
		return
	# Combat-internal idempotency. Combat AI re-issues command_move(chase_pos)
	# every chase tick (~0.5 Hz under the 2-second lockout, multiplied by
	# 50+ engaged units in mid-battle = ~150 calls/sec). The downstream
	# goto_world already short-circuits the kernel field rebuild for
	# near-identical targets, but command_move's own setup work
	# (move_queue.clear, patrol reset, formation rebalance check, mc
	# resolution) was running unconditionally. Skip the whole function
	# for combat-internal calls whose target is within ~3 m XZ of the
	# already-active move_target — the result is the same. Player
	# commands (clear_combat=true) always fall through so a player
	# right-click is never silently ignored.
	# Exception: a stationary unit that hasn't reached firing range must
	# still re-issue goto_world so the kernel wakes it from the ARRIVED
	# state. Without this, a unit that settled at arrival_radius boundary
	# just outside weapon range is permanently stuck — the idempotency
	# guard blocks the chase re-issue because the target hasn't changed.
	if not clear_combat and has_move_order and move_target != Vector3.INF:
		var dx_m: float = target.x - move_target.x
		var dz_m: float = target.z - move_target.z
		if dx_m * dx_m + dz_m * dz_m < 9.0:  # (3 m)^2
			# Allow re-issue when the unit is stationary (settled at
			# arrival boundary). Speed check: XZ velocity² < 0.25 (0.5 m/s).
			var vxz: Vector3 = velocity
			var vxz_sq: float = vxz.x * vxz.x + vxz.z * vxz.z
			if vxz_sq >= 0.25:
				return
	move_queue.clear()
	is_holding_position = false
	patrol_a = Vector3.INF
	patrol_b = Vector3.INF
	move_target = target
	move_target.y = global_position.y
	has_move_order = true
	_stuck_timer = 0.0
	# If members died while the squad was stationary, the formation
	# reform was deferred. Now that we're moving, run it once so the
	# survivors close ranks as part of the journey.
	if _rebalance_pending:
		_rebalance_pending = false
		_rebalance_formation()
	var _mc: Node = get_node_or_null("MovementComponent")
	if _mc != null and _mc is GroundMovement:
		# Player-issued plain move breaks the unit out of any prior GroupAura
		# flock: clear _kernel_group_id so the subsequent goto_world passes
		# group_id=0, giving solo cohesion semantics. Combat-internal chases
		# (clear_combat=false) skip this so the unit stays in its flock group
		# while approaching an enemy during attack-move.
		if clear_combat:
			(_mc as GroundMovement)._kernel_group_id = 0
			# Short-distance arrival fix (playtest 2026-05-15: "if I task
			# a unit to only walk a short distance it instead stutters
			# shortly and then stops immediately"). Combat units default
			# to arrival_radius=6u for stable group arrival, but a short
			# player click within 6u resolves as "already arrived" and
			# the unit barely moves. Tighten arrival_radius to fit the
			# move distance for player commands so short moves actually
			# travel the requested distance. Engineers/melee units
			# already keep their tight 1.5u radius (set at init); this
			# only affects standard combat units' player-issued moves.
			var _gm: GroundMovement = _mc as GroundMovement
			var _dist: float = global_position.distance_to(move_target)
			# Use 30% of distance, clamped to [0.8, 6.0]. Short clicks
			# get a tight arrival; long clicks keep the wide formation
			# arrival.
			_gm.arrival_radius = clampf(_dist * 0.30, 0.8, 6.0)
		(_mc as GroundMovement).goto_world(move_target)
	elif _nav_agent != null:
		_nav_agent.target_position = move_target
	if clear_combat:
		var combat: Node = get_combat()
		if combat and combat.has_method("clear_target"):
			combat.clear_target()
		# Suppress combat re-engagement for ~4 seconds so retaliation
		# can't immediately pull the unit back into the fight.
		_move_priority_until_ms = Time.get_ticks_msec() + 4000


func command_hold_position() -> void:
	## Stand Ground. Stops moving, clears combat target, and sets
	## `is_holding_position` so CombatComponent skips the auto-acquire
	## scan. Anything that walks into actual weapon range still gets
	## shot — hold means "don't reposition", not "go pacifist".
	stop()
	is_holding_position = true
	patrol_a = Vector3.INF
	patrol_b = Vector3.INF
	var combat: Node = get_combat()
	if combat and combat.has_method("clear_target"):
		combat.clear_target()


func command_patrol(target: Vector3) -> void:
	## Patrol between current position and `target`, looping. Each leg
	## walks like an attack-move (auto-engage en route). If the target
	## is essentially the unit's current position, no patrol is set.
	patrol_a = Vector3(global_position.x, global_position.y, global_position.z)
	patrol_b = Vector3(target.x, global_position.y, target.z)
	if patrol_a.distance_to(patrol_b) < 1.0:
		patrol_a = Vector3.INF
		patrol_b = Vector3.INF
		return
	is_holding_position = false
	# Kick off leg 1 toward B via attack-move so the unit fights on
	# the way. The patrol-loop logic in _physics_process flips legs
	# when the unit arrives at each end.
	var combat: Node = get_combat()
	if combat and combat.has_method("command_attack_move"):
		combat.command_attack_move(patrol_b)
	else:
		command_move(patrol_b, false)


func queue_move(target: Vector3) -> void:
	## Append a waypoint to the move queue. If the unit is currently idle,
	## the appended target becomes its active goal; otherwise the unit
	## finishes its current target first and then walks to each queued
	## waypoint in turn.
	var fixed: Vector3 = Vector3(target.x, global_position.y, target.z)
	if move_target == Vector3.INF:
		# Idle — just start the move directly.
		command_move(fixed)
		return
	move_queue.append(fixed)


func stop() -> void:
	move_target = Vector3.INF
	move_queue.clear()
	velocity = Vector3.ZERO
	has_move_order = false
	# New-system units: clear the MovementComponent's target AND zero its
	# internal _velocity. Without zeroing _velocity, the body's velocity
	# is overwritten next physics tick from MC's last frame value, so the
	# unit decelerates from full chase speed via inertia and overshoots
	# past weapon range into melee before settling.
	var mc: Node = get_node_or_null("MovementComponent")
	if mc != null and mc is MovementComponent:
		var mc_typed: MovementComponent = mc as MovementComponent
		mc_typed.clear_target()
		mc_typed._velocity = Vector3.ZERO


func _in_active_combat() -> bool:
	## True when the CombatComponent has a live target it's engaging.
	## Used to suppress the stuck-rescue ladder so a unit standing
	## still while firing on an enemy isn't misread as wedged on
	## terrain. Both forced_target (player or AI command_attack
	## directive) and _current_target (auto-acquired) count.
	var combat: Node = get_combat()
	if not combat:
		return false
	var t_var: Variant = combat.get("_current_target")
	if typeof(t_var) == TYPE_OBJECT and is_instance_valid(t_var):
		var t_alive: bool = true
		if "alive_count" in t_var:
			t_alive = (t_var.get("alive_count") as int) > 0
		if t_alive:
			return true
	var f_var: Variant = combat.get("forced_target")
	if typeof(f_var) == TYPE_OBJECT and is_instance_valid(f_var):
		return true
	return false


func _try_unit_detour_around_building() -> bool:
	## Stuck-rescue stage 2 for Unit (~1.4s of zero progress with a
	## live move order). Mirrors the crawler's
	## _find_detour_waypoint logic: find the nearest building roughly
	## ahead of the unit, compute a perpendicular side-step that
	## walks AWAY from that building's centre line, and queue it
	## ahead of the original target so the unit physically routes
	## around the obstacle before resuming.
	##
	## Returns true when a detour was actually queued (caller uses
	## the bool to throttle re-attempts) and false when no blocking
	## building was found in front of the unit (in which case the
	## existing deflection ladder handles the situation).
	if move_target == Vector3.INF or not has_move_order:
		return false
	var fwd: Vector3 = move_target - global_position
	fwd.y = 0.0
	if fwd.length_squared() < 0.01:
		return false
	fwd = fwd.normalized()
	const DETOUR_SCAN_RADIUS: float = 10.0
	const DETOUR_FORWARD_CONE_DOT: float = 0.2  # ~78° cone forward
	const DETOUR_OFFSET_MIN: float = 5.0
	var origin: Vector3 = global_position
	var best_blocker: Node3D = null
	var best_blocker_d: float = DETOUR_SCAN_RADIUS
	# Spatial-index narrows the candidate list to entities within a
	# few buckets; the previous full-group walk visited every
	# building in the scene per stuck-detour attempt.
	var idx: SpatialIndex = SpatialIndex.get_instance(get_tree().current_scene) if get_tree() else null
	var candidates: Array = idx.nearby(origin, DETOUR_SCAN_RADIUS) if idx else get_tree().get_nodes_in_group("buildings")
	for raw in candidates:
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if not node or not node.is_in_group("buildings"):
			continue
		var b: Node3D = node as Node3D
		if not b:
			continue
		var to_b: Vector3 = b.global_position - origin
		to_b.y = 0.0
		var d: float = to_b.length()
		if d > DETOUR_SCAN_RADIUS:
			continue
		if d > 0.001 and to_b.normalized().dot(fwd) < DETOUR_FORWARD_CONE_DOT:
			continue
		if d < best_blocker_d:
			best_blocker_d = d
			best_blocker = b
	if not best_blocker:
		return false
	# Perpendicular axis (90° rotation of fwd around Y).
	var perp: Vector3 = Vector3(-fwd.z, 0.0, fwd.x)
	# Lateral offset scales with the blocker's footprint half-
	# extent so the side-step clears the bounding box plus margin.
	var b_half: float = 3.0
	var b_stats_v: Variant = best_blocker.get("stats")
	if typeof(b_stats_v) == TYPE_OBJECT and is_instance_valid(b_stats_v):
		var fp_v: Variant = b_stats_v.get("footprint_size")
		if typeof(fp_v) == TYPE_VECTOR3:
			var fp: Vector3 = fp_v as Vector3
			b_half = maxf(fp.x, fp.z) * 0.5
	var lateral_off: float = maxf(b_half + 3.0, DETOUR_OFFSET_MIN)
	# Try BOTH sides and pick whichever side-step destination is
	# itself clear of every building footprint. Previously we only
	# tried the side AWAY from the blocker's centre, which still
	# wedged the unit when the "away" side happened to host
	# another building (common in dense AI bases). Picking the
	# clearer side prevents the detour from queueing a fresh
	# stuck.
	var to_blocker: Vector3 = best_blocker.global_position - origin
	to_blocker.y = 0.0
	var blocker_lateral: float = to_blocker.dot(perp)
	var preferred_side: Vector3 = -perp if blocker_lateral > 0.0 else perp
	var fallback_side: Vector3 = -preferred_side
	var detour_a: Vector3 = origin + preferred_side * lateral_off + fwd * 3.0
	var detour_b: Vector3 = origin + fallback_side * lateral_off + fwd * 3.0
	detour_a.y = origin.y
	detour_b.y = origin.y
	var detour: Vector3 = detour_a
	if not _detour_destination_clear(detour_a):
		if _detour_destination_clear(detour_b):
			detour = detour_b
		else:
			# Neither side has clearance; let the deflection ladder
			# stages take over.
			return false
	# Queue the detour: push the original target back into the
	# move_queue so the unit resumes the original goal once the
	# detour is reached, then retarget the agent to the side-step.
	move_queue.push_front(move_target)
	move_target = detour
	if _nav_agent:
		_nav_agent.target_position = detour
	return true


func _detour_destination_clear(pos: Vector3) -> bool:
	## True when no building's XZ AABB (footprint + small margin)
	## contains `pos`. Used by the unit detour to verify the
	## side-step destination isn't itself wedged inside another
	## building -- the detour only helps if the unit can actually
	## stand at the new waypoint.
	const DETOUR_DEST_MARGIN: float = 1.5
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Node3D = node as Node3D
		if not b:
			continue
		var stats_v: Variant = b.get("stats")
		if typeof(stats_v) != TYPE_OBJECT or not is_instance_valid(stats_v):
			continue
		var fp_v: Variant = stats_v.get("footprint_size")
		if typeof(fp_v) != TYPE_VECTOR3:
			continue
		var fp: Vector3 = fp_v as Vector3
		var half_x: float = fp.x * 0.5 + DETOUR_DEST_MARGIN
		var half_z: float = fp.z * 0.5 + DETOUR_DEST_MARGIN
		if absf(pos.x - b.global_position.x) < half_x and absf(pos.z - b.global_position.z) < half_z:
			return false
	return true


func _try_ramp_stuck_rescue() -> bool:
	## When wedged on a ramp, command_move toward the far short-end
	## midpoint of the ramp's clearance rect (i.e. the side opposite
	## the unit's current position along the rect's long axis). The
	## ramp is whichever direction the rect is longer, so the long
	## axis = traversal direction. Returns true when a rescue move
	## actually fired so the caller can throttle.
	var arena: Node = get_tree().current_scene if get_tree() else null
	if not arena or not arena.has_method("get_ramp_clearance_at"):
		return false
	var rect: Rect2 = arena.call("get_ramp_clearance_at", global_position) as Rect2
	if rect.size.length_squared() < 0.01:
		return false  # not on a ramp
	# Long axis = traversal direction. Short-end midpoints sit at
	# the rect's two narrow edges along that axis.
	var long_axis_x: bool = rect.size.x >= rect.size.y
	var end_a_xz: Vector2
	var end_b_xz: Vector2
	if long_axis_x:
		end_a_xz = Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5)
		end_b_xz = Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y * 0.5)
	else:
		end_a_xz = Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y)
		end_b_xz = Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y)
	# Pick the end farther from the unit's current XZ -- that's the
	# 'exit' the unit hasn't reached yet.
	var here: Vector2 = Vector2(global_position.x, global_position.z)
	var pick_a: bool = here.distance_squared_to(end_a_xz) > here.distance_squared_to(end_b_xz)
	var target_xz: Vector2 = end_a_xz if pick_a else end_b_xz
	var target: Vector3 = Vector3(target_xz.x, global_position.y, target_xz.y)
	command_move(target, false)
	return true


func _update_movement_collision() -> void:
	## Switch the leader collision box between full-size (at rest)
	## and shrunk (moving). Allows squads to pass through each
	## other in transit while still reading as solid bodies once
	## stopped. Only writes when the moving state actually changes
	## so the BoxShape3D stays cheap.
	if not _movement_collision_shape:
		return
	var moving: bool = (velocity.x * velocity.x + velocity.z * velocity.z) > MOVING_VELOCITY_THRESHOLD_SQ
	if moving == _movement_collision_currently_moving:
		return
	_movement_collision_currently_moving = moving
	if moving:
		var rest: Vector3 = _movement_collision_rest_size
		_movement_collision_shape.size = Vector3(
			rest.x * MOVING_COLLISION_SCALE,
			rest.y,
			rest.z * MOVING_COLLISION_SCALE,
		)
	else:
		_movement_collision_shape.size = _movement_collision_rest_size


func apply_emp_paralysis(duration: float) -> void:
	## Public hook used by Meridian's EChO override. Stacks by max so
	## a fresh short cast can't clip the tail of a longer one. Halts
	## current movement, silences the combat component (gates firing
	## via the existing _silence_remaining check), and arms the
	## per-frame velocity-zero gate in _physics_process.
	if duration <= 0.0:
		return
	_emp_paralysis_remaining = maxf(_emp_paralysis_remaining, duration)
	stop()
	var combat: Node = get_combat()
	if combat and combat.has_method("apply_silence"):
		combat.call("apply_silence", duration)


## --- Heliarch: Heat HP drain + Emergency Cooldown ---
## Spec §11_faction_mechanics.md lines 451-465.

func _tick_heliarch_heat_drain(delta: float) -> void:
	## Per-physics-tick heat HP drain for Heliarch units (faction_id == 3).
	## Called from _per_frame_bookkeeping so it runs under BOTH the new
	## GroundMovement path and the legacy path.
	##
	## Emergency Cooldown phase — this takes priority over Tier 2/3 drain:
	## while _emergency_cooldown_remaining > 0, the unit is paralysed (via
	## the emp mechanism) and drains EMERGENCY_COOLDOWN_DRAIN_PER_SEC HP/sec.
	## When the timer expires the unit's heat resets to 0.
	##
	## Normal Tier 2/3 drain runs only when NOT in Emergency Cooldown and
	## the unit is fully alive.
	if _emergency_cooldown_remaining > 0.0:
		_emergency_cooldown_remaining -= delta
		# Watchdog: keep the EMP paralysis alive and the combat component
		# silenced for the full cooldown window. apply_emp_paralysis uses
		# maxf so if EC is 5.8 s remaining but emp is down to 0.4 s, this
		# re-arms it to 5.8 s each tick, effectively keeping it pegged.
		# Small epsilon (0.1 s) avoids one stutter frame at the very end.
		if _emergency_cooldown_remaining > 0.0:
			var remaining_clamp: float = _emergency_cooldown_remaining + 0.1
			_emp_paralysis_remaining = maxf(_emp_paralysis_remaining, remaining_clamp)
			var ec_combat: Node = get_combat()
			if ec_combat and ec_combat.has_method("apply_silence"):
				ec_combat.call("apply_silence", remaining_clamp)
		# HP drain at 8 HP/sec. Accumulate fractional HP to avoid losing
		# damage to truncation on high-frequency ticks.
		_heat_drain_accum += EMERGENCY_COOLDOWN_DRAIN_PER_SEC * delta
		var drain_int: int = int(_heat_drain_accum)
		if drain_int >= 1:
			_heat_drain_accum -= float(drain_int)
			take_damage(drain_int, null)
		if _emergency_cooldown_remaining <= 0.0:
			_emergency_cooldown_remaining = 0.0
			_on_emergency_cooldown_end()
		return

	# Passive Heat decay — every Heliarch unit cools off slowly while
	# not firing. CombatComponent.notify_heat_ramp_fire pushes it back
	# up faster than this decay, so a unit in sustained combat climbs
	# toward Tier 2/3; a unit that has disengaged drops below the
	# drain threshold within ~10 seconds. Keeps the Heat tax dynamic
	# instead of letting a unit linger at max heat indefinitely.
	var heat_now: float = _read_heat_pct()
	if heat_now > 0.0:
		var decayed: float = heat_now - HEAT_PASSIVE_DECAY_PER_SEC * delta
		_set_heat_pct(maxf(decayed, 0.0))

	# Normal Tier 2/3 passive HP drain. Not active during Emergency Cooldown.
	var heat_pct: float = _read_heat_pct()
	var tier: int = _heat_tier(heat_pct)
	if tier == 2:
		_heat_drain_accum += 2.0 * delta
	elif tier == 3:
		_heat_drain_accum += 5.0 * delta
	var drain_t23: int = int(_heat_drain_accum)
	if drain_t23 >= 1:
		_heat_drain_accum -= float(drain_t23)
		take_damage(drain_t23, null)

	# Emergency Cooldown trigger: if we just crossed 100% Heat and no
	# meltdown was triggered this cycle, enter cooldown.
	if tier == 3 and _emergency_cooldown_remaining <= 0.0 and not _meltdown_triggered_this_cycle:
		_enter_emergency_cooldown()
	# Reset the per-cycle meltdown flag so it doesn't latch across frames.
	_meltdown_triggered_this_cycle = false


func _read_heat_pct() -> float:
	## Read this unit's current Heat percentage (0.0-1.0).
	## Heat is a Heliarch-faction stat. Until Heliarch unit resources
	## exist (Phase 3) the stat resource won't have a `heat_pct` field,
	## so this safely returns 0.0. Phase 3 will add a `heat_pct: float`
	## member variable to Heliarch units and wire it here.
	if has_meta("heat_pct"):
		return get_meta("heat_pct") as float
	return 0.0


func _set_heat_pct(value: float) -> void:
	## Write this unit's Heat percentage. Clamped to [0, 1].
	## Uses the same meta-property path as _read_heat_pct so Phase 3
	## can swap to a typed field without touching the call sites.
	set_meta("heat_pct", clampf(value, 0.0, 1.0))


func notify_heat_ramp_fire() -> void:
	## Called by CombatComponent every time the unit's primary weapon
	## fires. Bumps the unit's heat_pct by HEAT_RAMP_PER_FIRE. No-op for
	## non-Heliarch units (the caller already faction-gates) — also
	## clamped so heat can never exceed 1.0 except when the Emergency
	## Cooldown handler explicitly zeroes it.
	if _faction_id() != 3:
		return
	if _emergency_cooldown_remaining > 0.0:
		return
	var cur: float = _read_heat_pct()
	_set_heat_pct(cur + HEAT_RAMP_PER_FIRE)


func _heat_tier(heat_pct: float) -> int:
	## Returns the Heat tier (0-3) from a 0-1 fraction.
	## Spec §11_faction_mechanics.md lines 446-449:
	##   Tier 0: 0-32 %   Tier 1: 33-65 %   Tier 2: 66-99 %   Tier 3: 100 %
	if heat_pct >= 1.0:
		return 3
	if heat_pct >= 0.66:
		return 2
	if heat_pct >= 0.33:
		return 1
	return 0


func _enter_emergency_cooldown() -> void:
	## Transition into Emergency Cooldown state.
	## Immobilises + silences the unit for EMERGENCY_COOLDOWN_DURATION
	## seconds; _tick_heliarch_heat_drain handles the HP drain and
	## termination logic while the timer runs.
	_emergency_cooldown_remaining = EMERGENCY_COOLDOWN_DURATION
	_heat_drain_accum = 0.0  # Fresh accumulator for the EC drain phase.
	# stop() zeroes velocity and clears move_target/has_move_order.
	stop()
	# apply_emp_paralysis handles both movement and fire suppression via
	# the same mechanism Meridian's EChO uses — no duplicate code.
	apply_emp_paralysis(EMERGENCY_COOLDOWN_DURATION + 0.2)
	# Visual feedback: tint all chassis materials deep orange-red to signal
	# the unit is overheating and locked. Cleared by _on_emergency_cooldown_end.
	_apply_emergency_cooldown_tint(true)


func _on_emergency_cooldown_end() -> void:
	## Called when Emergency Cooldown timer expires.
	## Resets Heat to 0 % and restores the unit's visual state.
	_set_heat_pct(0.0)
	_heat_drain_accum = 0.0
	_apply_emergency_cooldown_tint(false)
	# Movement and firing resume naturally: _emp_paralysis_remaining has
	# already counted down to 0 (the watchdog pegged it to the EC timer,
	# which just expired), and the silence timer on the combat component
	# also expires at the same cadence.


func _apply_emergency_cooldown_tint(active: bool) -> void:
	## Visual feedback for Emergency Cooldown. Sets (or clears) an
	## intense orange-red emission on the unit's chassis members.
	## This is MVP — spec line 591-592 calls for steam VFX in Phase 3.
	##
	## Safety: we only operate on surface OVERRIDE materials (set per-unit
	## in the mesh build helpers). If no override is set for a surface we
	## skip it — we never mutate the shared mesh material, which would
	## tint every unit using the same resource.
	for member: Node3D in _member_meshes:
		if not is_instance_valid(member):
			continue
		# Walk the member's children to find surface MeshInstance3Ds.
		for child: Node in member.get_children():
			var mi: MeshInstance3D = child as MeshInstance3D
			if not mi:
				continue
			var n_surfs: int = mi.get_surface_override_material_count()
			for surf: int in range(n_surfs):
				var mat: Material = mi.get_surface_override_material(surf)
				var std: StandardMaterial3D = mat as StandardMaterial3D
				if not std:
					continue  # No per-unit override — skip to avoid touching shared resource.
				if active:
					std.emission_enabled = true
					std.emission = Color(1.0, 0.2, 0.05)
					std.emission_energy_multiplier = 3.5
				else:
					# Restore: clear the forced emission. The material's normal
					# emission state (if any) was already set by the build helper;
					# we only clear emission_enabled when it was the EC override.
					std.emission_enabled = false


## --- Active abilities ---

func has_ability() -> bool:
	## True when this unit's stats define an ability the HUD should
	## surface as a button.
	return stats != null and stats.ability_name != ""

func ability_ready() -> bool:
	return has_ability() and _ability_cd_remaining <= 0.0

func ability_cooldown_remaining() -> float:
	return _ability_cd_remaining

## Track the most recent target world position passed to a
## targeted ability. Targeted ability implementations read this
## instead of taking an explicit arg so the existing dispatch
## table keeps its zero-arg signature.
var _ability_target_pos: Vector3 = Vector3.INF


func trigger_ability(target_pos: Vector3 = Vector3.INF) -> bool:
	## Called by the HUD ability button (or hotkey). Dispatches by
	## stats.ability_name to the concrete effect implementation.
	## Returns true on a successful cast so the HUD can play
	## confirmation feedback. `target_pos` is set for area-target
	## abilities (ability_targeted = true on the stat); instant
	## abilities ignore it and use the caster's position.
	if not has_ability() or alive_count == 0:
		return false
	if _ability_cd_remaining > 0.0:
		return false
	_ability_target_pos = target_pos
	var fired: bool = false
	match stats.ability_name:
		"System Crash":
			fired = _ability_system_crash()
		"Factory Pulse":
			fired = _ability_factory_pulse()
		"Reactor Surge":
			fired = _ability_reactor_surge()
		"Garrison":
			fired = _ability_garrison()
		"Heavy Volley":
			fired = _ability_heavy_volley()
		"Glowing Shot":
			fired = _ability_glowing_shot()
		"Barrier Bloom":
			fired = _ability_barrier_bloom()
		"Plant Charge":
			fired = _ability_plant_charge()
		"Meltdown":
			fired = _ability_meltdown()
		"Wächter Deploy":
			fired = _ability_wachter_deploy()
		_:
			# Unknown ability name on stats — don't crash, just
			# refuse to fire so the player notices.
			push_warning("Unit '%s' has unknown ability '%s'" % [stats.unit_name, stats.ability_name])
			return false
	if fired:
		_ability_cd_remaining = stats.ability_cooldown
	return fired

func _ability_system_crash() -> bool:
	## Pulsefont's System Crash. Sweeps every enemy mech inside
	## stats.ability_radius around the caster's current position
	## and silences their CombatComponent for stats.ability_duration
	## seconds (no firing during the silence). Skips structures and
	## aircraft on purpose — the spec calls this an anti-mech EMP.
	var origin: Vector3 = global_position
	var radius_sq: float = stats.ability_radius * stats.ability_radius
	var hits: int = 0
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var enemy: Unit = node as Unit
		if not enemy or enemy == self:
			continue
		if enemy.owner_id == owner_id:
			continue
		if enemy.alive_count <= 0:
			continue
		if enemy.global_position.distance_squared_to(origin) > radius_sq:
			continue
		var combat: Node = enemy.get_node_or_null("CombatComponent")
		if combat and combat.has_method("apply_silence"):
			combat.apply_silence(stats.ability_duration)
			hits += 1
	# Spawn a quick blue pulse so the player sees the AOE land.
	_spawn_system_crash_visual(stats.ability_radius)
	return hits > 0 or true  # Always succeed even if zero hits — the
							# cooldown still applies (cast committed).


func _ability_factory_pulse() -> bool:
	## Forgemaster's Factory Pulse — instead of a single instant
	## heal pop, the ability now ticks over stats.ability_duration
	## seconds, healing per_tick HP every second to every friendly
	## mech in radius. Total heal is meaningfully larger (5 ticks ×
	## 80 = 400 HP base; Foreman branch 5 × 100 = 500 HP) but the
	## payoff is metered out so the ally has to STAY in the aura
	## to get the full benefit. Ticker registered as a Timer-driven
	## callback chain anchored on the Forgemaster itself; if the
	## caster dies mid-pulse the timer dies with it.
	# Per-tick heal lifted to 125 (Foreman branch scales by the same
	# 1.25x ratio it had before -> 156). Previous 64/80 baseline read
	# as a chip heal that didn't justify the cooldown commitment;
	# 125 makes a single Pulse meaningfully stitch a squad back up.
	var per_tick: int = 125
	if stats.unit_name.findn("Foreman") >= 0:
		per_tick = 156
	var ticks_left: int = 5
	var radius: float = stats.ability_radius
	# Every second: heal allies in radius for per_tick + spawn a
	# small pulse visual. Recursing via call_deferred + a Timer
	# child keeps the chain GC-safe — the timer is parented to the
	# caster, so freeing the Forgemaster cancels the chain.
	_factory_pulse_tick(per_tick, ticks_left, radius)
	return true


func _factory_pulse_tick(per_tick: int, ticks_left: int, radius: float) -> void:
	## One pulse tick — heals allies in radius, spawns a visual,
	## and schedules the next tick. Called recursively via a
	## one-shot Timer until ticks_left runs out.
	if alive_count <= 0:
		return
	var origin: Vector3 = global_position
	var radius_sq: float = radius * radius
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var ally: Unit = node as Unit
		if not ally:
			continue
		if ally.owner_id != owner_id:
			continue
		if ally.alive_count <= 0:
			continue
		if ally.global_position.distance_squared_to(origin) > radius_sq:
			continue
		ally.apply_heal(per_tick)
	_spawn_pulse_visual(radius, Color(1.0, 0.65, 0.25))
	if ticks_left > 1:
		var timer: SceneTreeTimer = get_tree().create_timer(1.0)
		timer.timeout.connect(_factory_pulse_tick.bind(per_tick, ticks_left - 1, radius))


func _ability_reactor_surge() -> bool:
	## Forgemaster Reactor branch — friendly mechs in radius gain a
	## temporary outgoing-damage multiplier (handled inside
	## CombatComponent.apply_damage_buff so subsequent _fire_weapon
	## calls scale automatically).
	var origin: Vector3 = global_position
	var radius_sq: float = stats.ability_radius * stats.ability_radius
	var hits: int = 0
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var ally: Unit = node as Unit
		if not ally:
			continue
		if ally.owner_id != owner_id:
			continue
		if ally.alive_count <= 0:
			continue
		if ally.global_position.distance_squared_to(origin) > radius_sq:
			continue
		var combat: Node = ally.get_node_or_null("CombatComponent")
		if combat and combat.has_method("apply_damage_buff"):
			combat.apply_damage_buff(1.30, stats.ability_duration)
			hits += 1
	_spawn_pulse_visual(stats.ability_radius, Color(1.0, 0.5, 0.2))
	return hits > 0 or true


func _ability_heavy_volley() -> bool:
	## Harbinger Swarm Marshal's Heavy Volley. Flags the combat
	## component so the NEXT primary-weapon shot fires as a glowing
	## 5-pellet salvo at 2x damage. Cooldown gates re-trigger; the
	## flag clears on the buffed shot (or harmlessly on next cast).
	var combat: Node = get_combat()
	if not combat:
		return false
	if not combat.has_method("queue_glowing_volley"):
		return false
	combat.call("queue_glowing_volley", 2.0, true)
	return true


func _ability_barrier_bloom() -> bool:
	## Phalanx Shield's area-target ability. Drops a directional
	## barrier centered on the targeted ground point: every friendly
	## unit (ground or air) inside stats.ability_radius gets a
	## damage-reduction shield for stats.ability_duration. Spawned
	## in front of higher-value gunships -- the player picks the
	## arc, the drones project the field. Visual is a translucent
	## blue dome at the target site.
	if _ability_target_pos == Vector3.INF:
		return false
	var radius_sq: float = stats.ability_radius * stats.ability_radius
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var ally: Unit = node as Unit
		if not ally:
			continue
		if ally.owner_id != owner_id:
			continue
		if ally.alive_count <= 0:
			continue
		if ally.global_position.distance_squared_to(_ability_target_pos) > radius_sq:
			continue
		var combat: Node = ally.get_node_or_null("CombatComponent")
		if combat and combat.has_method("apply_damage_reduction"):
			combat.call("apply_damage_reduction", 0.45, stats.ability_duration)
	_spawn_pulse_visual_at(_ability_target_pos, stats.ability_radius, Color(0.45, 0.75, 1.0))
	return true


func _ability_plant_charge() -> bool:
	## Rook Sapper's area-target ability. Plants a delayed demolition
	## charge at the target point; after a 2.0s arming window the
	## charge detonates dealing AS-tag damage in stats.ability_radius.
	## Manual-cast on purpose -- the Sapper picks where + when the
	## bomb goes, and the arming window is the miscast risk.
	if _ability_target_pos == Vector3.INF:
		return false
	var arm_pos: Vector3 = _ability_target_pos
	var radius: float = stats.ability_radius
	# 2.0s fuse, then resolve in the same hostility-filtered loop the
	# other AOE abilities use. Anchored on a SceneTreeTimer so the
	# charge survives the caster dying mid-fuse (the bomb was already
	# planted; the Sapper's death doesn't disarm it).
	var timer: SceneTreeTimer = get_tree().create_timer(2.0)
	timer.timeout.connect(_resolve_plant_charge.bind(arm_pos, radius, owner_id))
	# Visual: a small ground marker so the player can SEE the bomb.
	_spawn_pulse_visual_at(arm_pos, radius * 0.35, Color(1.0, 0.6, 0.2))
	return true


func _resolve_plant_charge(at_pos: Vector3, radius: float, src_owner: int) -> void:
	## Detonate the planted demolition charge. Hostile to the placer's
	## owner — uses the registry-driven hostility check instead of a
	## raw owner_id compare so 2v2 alliance changes propagate.
	var radius_sq: float = radius * radius
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	# Damage units.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var u: Unit = node as Unit
		if not u or u.alive_count <= 0:
			continue
		var allied: bool
		if registry:
			allied = registry.are_allied(src_owner, u.owner_id)
		else:
			allied = u.owner_id == src_owner
		if allied:
			continue
		if u.global_position.distance_squared_to(at_pos) > radius_sq:
			continue
		# AS-tag heavy hit -- 320 base damage, then standard armor.
		u.take_damage(320, null)
	# Damage buildings (the AS tag's whole point).
	for b_node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(b_node):
			continue
		var b: Node3D = b_node as Node3D
		if not b:
			continue
		if "owner_id" in b:
			var b_owner: int = b.get("owner_id")
			var b_allied: bool
			if registry:
				b_allied = registry.are_allied(src_owner, b_owner)
			else:
				b_allied = b_owner == src_owner
			if b_allied:
				continue
		if b.global_position.distance_squared_to(at_pos) > radius_sq:
			continue
		if b.has_method("take_damage"):
			b.call("take_damage", 480, null)
	_spawn_pulse_visual_at(at_pos, radius, Color(1.0, 0.5, 0.15))


func _ability_meltdown() -> bool:
	## Heliarch Meltdown — player-triggered self-destruct at 100% Heat.
	## Phase 3 will implement the full area-damage effect (the unit sacrifices
	## itself for a large AOE hit). For now this is a stub: it sets the
	## _meltdown_triggered_this_cycle flag (preventing Emergency Cooldown from
	## also triggering on the same tick) and kills the unit.
	## Spec §11_faction_mechanics.md lines 457-465.
	_meltdown_triggered_this_cycle = true
	# TODO(Phase 3): deal area damage proportional to remaining HP before dying.
	_die()
	return true


func _ability_wachter_deploy() -> bool:
	## Wächter Deploy/Undeploy toggle. Transitions between:
	##   Undeployed: mobile, normal weapon damage.
	##   Deployed:   immobile, +50% weapon damage (CombatComponent
	##               reads is_deployed via get_damage_buff_mult).
	## A 3-second transition locks movement each direction. Cannot
	## be triggered while a transition is already in progress.
	if _deploy_locked:
		return false  # mid-transition; ignore the button press
	if is_deployed:
		# Start undeploy transition.
		_deploy_locked = true
		_deploy_progress = 1.0
	else:
		# Start deploy transition — stop movement first.
		stop()
		if has_method("stop"):
			stop()
		_deploy_locked = true
		_deploy_progress = 0.0
	return true


func _tick_deploy_state(delta: float) -> void:
	## Called every physics frame by _physics_process to advance the
	## deploy/undeploy transition. When progress completes, locks/unlocks
	## movement and flips is_deployed.
	if not _deploy_locked:
		return
	if is_deployed:
		# Undeploy: progress 1 → 0
		_deploy_progress -= delta / DEPLOY_TRANSITION_SEC
		if _deploy_progress <= 0.0:
			_deploy_progress = 0.0
			is_deployed = false
			_deploy_locked = false
			_wachter_hide_deploy_range()
	else:
		# Deploy: progress 0 → 1
		_deploy_progress += delta / DEPLOY_TRANSITION_SEC
		if _deploy_progress >= 1.0:
			_deploy_progress = 1.0
			is_deployed = true
			_deploy_locked = false
			_wachter_show_deploy_range()

	# Drive the body sink + emissive tesla tint every frame of the
	# transition so the unit physically reads as anchoring/un-anchoring
	# from the ground.
	_wachter_apply_deploy_visual(_deploy_progress)

	# During transition: prevent movement.
	if _deploy_locked and has_move_order:
		stop()


## Wächter deploy sink offset (world-units, additive on top of the walk/idle
## bob). _apply_walk_bob and _reset_walk_bob compose this into member
## position.y so the sink doesn't get overwritten frame-to-frame.
## The body only settles a hair (~0.10u) now that Wächter is a tracked
## tank; the visible deploy state lives on four corner anchor stakes
## that extend into the ground.
var _wachter_deploy_sink_offset: float = 0.0
const _WACHTER_DEPLOY_SINK: float = 0.10  # subtle hull settle while anchoring
const _WACHTER_DEPLOY_STAKE_DEPTH: float = 1.10  # how far stakes drive below the hull
const _WACHTER_DEPLOY_TESLA_TINT: Color = Color(0.45, 0.85, 1.0, 1.0)
const _WACHTER_STAKE_HALF_X: float = 0.95  # corner positions match tank fender extents
const _WACHTER_STAKE_HALF_Z: float = 1.05


func _wachter_apply_deploy_visual(progress: float) -> void:
	## Updates the shared _wachter_deploy_sink_offset (subtle hull
	## settle) and drives the four corner anchor stakes the Wächter
	## extends into the ground during deploy. Stakes are visible from
	## any camera angle and clearly communicate the unit's anchored
	## state on top of the new range-ring outline. No-op for non-
	## Wächter units.
	if not stats or stats.unit_name != "Wächter":
		return
	if _member_meshes.is_empty():
		return
	var clamped: float = clampf(progress, 0.0, 1.0)
	_wachter_deploy_sink_offset = clamped * _WACHTER_DEPLOY_SINK
	var leader: Node3D = _member_meshes[0]
	if not is_instance_valid(leader):
		return
	# Anchor-stake container — created once on first deploy, then
	# re-used across cycles.
	var stake_root: Node3D = leader.get_node_or_null("DeployStakes") as Node3D
	if clamped <= 0.01:
		if stake_root:
			stake_root.queue_free()
		return
	if stake_root == null:
		stake_root = Node3D.new()
		stake_root.name = "DeployStakes"
		leader.add_child(stake_root)
		for xi: int in 2:
			for zi: int in 2:
				var stake := MeshInstance3D.new()
				stake.name = "Stake_%d_%d" % [xi, zi]
				var stake_cyl := CylinderMesh.new()
				stake_cyl.top_radius = 0.10
				stake_cyl.bottom_radius = 0.07
				stake_cyl.height = _WACHTER_DEPLOY_STAKE_DEPTH
				stake_cyl.radial_segments = 10
				stake.mesh = stake_cyl
				var sx: float = -_WACHTER_STAKE_HALF_X if xi == 0 else _WACHTER_STAKE_HALF_X
				var sz: float = -_WACHTER_STAKE_HALF_Z if zi == 0 else _WACHTER_STAKE_HALF_Z
				stake.position = Vector3(sx, 0.0, sz)  # y updated by progress
				var stake_mat := StandardMaterial3D.new()
				stake_mat.albedo_color = Color(0.30, 0.27, 0.22)
				stake_mat.metallic = 0.7
				stake_mat.roughness = 0.45
				# Emissive tesla band near the base so the stake reads
				# as energized, not just plain metal.
				stake_mat.emission_enabled = true
				stake_mat.emission = _WACHTER_DEPLOY_TESLA_TINT
				stake_mat.emission_energy_multiplier = 0.4
				stake.set_surface_override_material(0, stake_mat)
				stake_root.add_child(stake)
	# Drive each stake downward proportional to progress: at 0 the
	# stake's top is flush with the hull (invisible inside the chassis);
	# at 1 the bottom is buried at _WACHTER_DEPLOY_STAKE_DEPTH below.
	for stake_node: Node in stake_root.get_children():
		var stake_mesh: MeshInstance3D = stake_node as MeshInstance3D
		if not stake_mesh:
			continue
		stake_mesh.position.y = -clamped * _WACHTER_DEPLOY_STAKE_DEPTH * 0.6


func _wachter_show_deploy_range() -> void:
	## Adds a single-line attack-range ring at the unit's footprint matching
	## the Wächter's weapon range when fully deployed. Stored as
	## "DeployAttackRange" on the unit root so undeploy can remove it cleanly.
	## Uses a thin TorusMesh so it reads as an outline circle rather than a
	## filled disc (user feedback: "should be a single line circle, not a
	## fully filled in area").
	if get_node_or_null("DeployAttackRange"):
		return
	if not stats or not stats.primary_weapon:
		return
	var radius: float = stats.primary_weapon.resolved_range()
	if radius <= 0.0:
		return
	var ring := MeshInstance3D.new()
	ring.name = "DeployAttackRange"
	var torus := TorusMesh.new()
	# Thin band on the ground: inner ~ outer minus a small width so the
	# ring reads as a single line at top-down RTS camera angles.
	torus.inner_radius = maxf(radius - 0.15, 0.05)
	torus.outer_radius = radius
	torus.ring_segments = 96
	torus.rings = 8
	ring.mesh = torus
	ring.position.y = 0.06
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(_WACHTER_DEPLOY_TESLA_TINT.r, _WACHTER_DEPLOY_TESLA_TINT.g, _WACHTER_DEPLOY_TESLA_TINT.b, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = _WACHTER_DEPLOY_TESLA_TINT
	mat.emission_energy_multiplier = 1.2
	ring.set_surface_override_material(0, mat)
	add_child(ring)


func _wachter_hide_deploy_range() -> void:
	var ring: Node = get_node_or_null("DeployAttackRange")
	if ring:
		ring.queue_free()


func _spawn_pulse_visual_at(at_pos: Vector3, radius: float, tint: Color) -> void:
	## Same visual as _spawn_pulse_visual but anchored to a world
	## position instead of the caster -- needed for area-target
	## abilities where the pulse is at the click site, not on the
	## caster itself.
	var pulse: MeshInstance3D = MeshInstance3D.new()
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	pulse.mesh = sphere
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.18)
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 1.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pulse.material_override = mat
	pulse.global_position = at_pos
	get_tree().current_scene.add_child(pulse)
	# Fade + grow over 0.6s, then free.
	var tween: Tween = pulse.create_tween()
	tween.set_parallel(true)
	tween.tween_property(pulse, "scale", Vector3.ONE * 1.35, 0.6)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.6)
	tween.chain().tween_callback(pulse.queue_free)


func _ability_glowing_shot() -> bool:
	## Hound Ripper's Glowing Shot. Flags the combat component so
	## the NEXT primary-weapon shot deals +50% damage and renders
	## as a glowing yellow tracer. Single shot rather than a
	## pellet salvo (the autocannon stays the autocannon, just
	## brighter + harder hitting). Autocast on cooldown handled by
	## CombatComponent's per-tick autocast trigger.
	var combat: Node = get_combat()
	if not combat:
		return false
	if not combat.has_method("queue_glowing_volley"):
		return false
	combat.call("queue_glowing_volley", 1.5, false)
	return true


func _ability_garrison() -> bool:
	## Courier embark / disembark toggle.
	##   No passengers loaded -> board the nearest 3 friendly Combine
	##     light mechs / engineers within stats.ability_radius. Each
	##     boarded unit hides, suppresses combat + movement, and
	##     points _garrisoned_in at this tank. Tank's CombatComponent
	##     enables the garrison damage + fire-rate buff.
	##   Passengers loaded -> disembark all of them around the tank,
	##     restore visibility / combat, clear the buff.
	if _garrison_passengers.is_empty():
		var origin: Vector3 = global_position
		var radius_sq: float = stats.ability_radius * stats.ability_radius
		var candidates: Array[Unit] = []
		for node: Node in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(node):
				continue
			var ally: Unit = node as Unit
			if not ally or ally == self:
				continue
			if ally.owner_id != owner_id:
				continue
			if ally.alive_count <= 0:
				continue
			if ally._garrisoned_in != null:
				continue
			if not ally.stats:
				continue
			# Only light mechs and engineers fit in the transport.
			# Mediums + heavies + transports + aircraft don't.
			if ally.stats.unit_class != &"light" and ally.stats.unit_class != &"engineer":
				continue
			if ally.global_position.distance_squared_to(origin) > radius_sq:
				continue
			candidates.append(ally)
		# Sort closest first and take up to 3 — the spec's transport
		# capacity. Sort by squared distance to avoid the sqrt cost.
		candidates.sort_custom(func(a: Unit, b: Unit) -> bool:
			return a.global_position.distance_squared_to(origin) < b.global_position.distance_squared_to(origin)
		)
		var taken: int = 0
		for ally: Unit in candidates:
			if taken >= 3:
				break
			_garrison_passengers.append(ally)
			ally._garrisoned_in = self
			ally.visible = false
			# Stop them in place so any active move order doesn't
			# resume on disembark — the player can re-task after
			# they're back on the field.
			if ally.has_method("stop"):
				ally.stop()
			# Disable the passenger's collision while garrisoned.
			# Without this, the passenger's CharacterBody3D collider
			# stays at the carrier's position and fights the carrier's
			# move_and_slide depenetration each frame -- the visible
			# symptom was the transport jittering whenever it tried
			# to move. Originals are stashed so disembark can put
			# them back.
			ally.set_meta("garrison_prev_collision_layer", ally.collision_layer)
			ally.set_meta("garrison_prev_collision_mask", ally.collision_mask)
			ally.collision_layer = 0
			ally.collision_mask = 0
			taken += 1
		_set_garrison_buff(true)
		return true

	# Disembark — drop every passenger in a small ring around the
	# tank, restore them, clear the buff.
	var passengers: Array[Unit] = _garrison_passengers.duplicate()
	_garrison_passengers.clear()
	var n: int = passengers.size()
	for i: int in n:
		var ally: Unit = passengers[i]
		if not is_instance_valid(ally):
			continue
		var angle: float = TAU * float(i) / float(maxi(n, 1))
		var drop_pos: Vector3 = global_position + Vector3(cos(angle) * 3.0, 0.0, sin(angle) * 3.0)
		ally.global_position = drop_pos
		ally._garrisoned_in = null
		ally.visible = true
		# Restore the passenger's collision layer / mask. Falls back
		# to the standard Unit values if the metadata is missing
		# (e.g. mid-save reload), so a disembarked unit always ends
		# up collidable.
		var prev_layer: int = ally.get_meta("garrison_prev_collision_layer", 2) as int
		var prev_mask: int = ally.get_meta("garrison_prev_collision_mask", 5) as int
		ally.collision_layer = prev_layer
		ally.collision_mask = prev_mask
		ally.remove_meta("garrison_prev_collision_layer")
		ally.remove_meta("garrison_prev_collision_mask")
	_set_garrison_buff(false)
	return true


func _set_garrison_buff(active: bool) -> void:
	## Toggles the carrier's CombatComponent garrison flag (fire
	## rate + damage buff) and updates the visual cue.
	var combat: Node = get_node_or_null("CombatComponent")
	if combat and combat.has_method("set_garrison_active"):
		combat.call("set_garrison_active", active)


func apply_heal(amount: int) -> void:
	## Distributes a heal across alive members. Caps at hp_per_unit
	## per member so a single huge heal doesn't overheal one member
	## past full while another sits at 1 HP. Walks the array and
	## dumps excess into the next still-wounded member; whatever's
	## still left over after all alive members are full feeds
	## _heal_overflow_accum, which restores ONE dead squad member
	## per hp_per_unit accumulated. Lets sustained Factory Pulse
	## casts gradually rebuild a wounded squad instead of just
	## healing the survivors.
	if alive_count <= 0 or not stats:
		return
	var remaining: int = amount
	for i: int in member_hp.size():
		if remaining <= 0:
			break
		if member_hp[i] <= 0:
			continue
		var deficit: int = stats.hp_per_unit - member_hp[i]
		if deficit <= 0:
			continue
		var apply_amt: int = mini(deficit, remaining)
		member_hp[i] += apply_amt
		remaining -= apply_amt
	# Overflow converts to dead-member restorations. Only when the
	# squad has at least one missing member; otherwise the heal
	# vanishes (a full squad shouldn't bank a free revive for
	# later future casualties — would be too generous).
	if remaining > 0 and alive_count < stats.squad_size:
		_heal_overflow_accum += remaining
		while _heal_overflow_accum >= stats.hp_per_unit and alive_count < stats.squad_size:
			_heal_overflow_accum -= stats.hp_per_unit
			_restore_dead_member()
	elif alive_count >= stats.squad_size:
		# No use for accumulated overflow once the squad is full —
		# clear the bucket so a long lull at full strength doesn't
		# bank revival juice for the next casualty.
		_heal_overflow_accum = 0
	_update_hp_bar()


func _restore_dead_member() -> void:
	## Brings one dead squad member back with full HP. Picks the
	## first slot whose member_hp is 0; restores the visual mesh
	## (set visible) and bumps alive_count. No-op when there are
	## no dead slots.
	if not stats:
		return
	for i: int in member_hp.size():
		if member_hp[i] > 0:
			continue
		member_hp[i] = stats.hp_per_unit
		alive_count = mini(alive_count + 1, stats.squad_size)
		if i < _member_meshes.size():
			var mesh: Node3D = _member_meshes[i]
			if is_instance_valid(mesh):
				mesh.visible = true
		break


func _spawn_pulse_visual(radius: float, tint: Color) -> void:
	## Friendly-target ring used by Factory Pulse + Reactor Surge.
	## Tuned more transparent than the System Crash debuff so a
	## sustained heal (Factory Pulse fires once per second over 5s)
	## doesn't smother the units it's healing under a solid block
	## of warm colour. Alpha 0.20, emission 1.4, lighter tint.
	var ring := MeshInstance3D.new()
	var disc := SphereMesh.new()
	disc.radius = 1.0
	disc.height = 0.2
	disc.radial_segments = 24
	disc.rings = 4
	ring.mesh = disc
	ring.scale = Vector3.ZERO
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.20)
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 1.4
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.set_surface_override_material(0, mat)
	get_tree().current_scene.add_child(ring)
	ring.global_position = global_position + Vector3(0, 0.4, 0)
	var tween: Tween = ring.create_tween().set_parallel(true)
	tween.tween_property(ring, "scale", Vector3(radius, radius, radius), 0.55)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.55)
	tween.tween_property(mat, "emission_energy_multiplier", 0.0, 0.55)
	tween.chain().tween_callback(ring.queue_free)


func _spawn_system_crash_visual(radius: float) -> void:
	## A flat emissive disc that scales out from 0 -> radius over
	## ~0.45s while fading. Cheap, reads at any zoom.
	var ring := MeshInstance3D.new()
	var disc := SphereMesh.new()
	disc.radius = 1.0
	disc.height = 0.2
	disc.radial_segments = 24
	disc.rings = 4
	ring.mesh = disc
	ring.scale = Vector3.ZERO
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.55)
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.85, 1.0)
	mat.emission_energy_multiplier = 2.6
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.set_surface_override_material(0, mat)
	get_tree().current_scene.add_child(ring)
	ring.global_position = global_position + Vector3(0, 0.4, 0)
	var tween: Tween = ring.create_tween().set_parallel(true)
	tween.tween_property(ring, "scale", Vector3(radius, radius, radius), 0.45)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tween.tween_property(mat, "emission_energy_multiplier", 0.0, 0.45)
	tween.chain().tween_callback(ring.queue_free)


func _physics_process(delta: float) -> void:
	# Garrisoned passenger short-circuit. While riding inside a
	# Courier, the passenger snaps to the carrier's position
	# every tick and skips its own movement, combat, stuck-rescue,
	# stealth, and damage-flash logic. The carrier dying clears
	# _garrisoned_in (see take_damage / _die path) and the
	# passenger resumes normal processing on the next tick.
	if _garrisoned_in:
		if not is_instance_valid(_garrisoned_in) or _garrisoned_in.alive_count <= 0:
			# Carrier vanished mid-ride — drop out where we are
			# so the passenger isn't permanently invisible.
			_garrisoned_in = null
			visible = true
		else:
			global_position = _garrisoned_in.global_position
			velocity = Vector3.ZERO
			return

	_per_frame_bookkeeping(delta)
	# Cached MovementComponent — was a get_node_or_null lookup per
	# tick. Profile 531 found Unit._physics_process at 5.81 ms / call
	# under heavy combat (vs 0.075 ms baseline); the per-tick string
	# lookup combined with the bookkeeping branch's second lookup was
	# the suspect. Cached field collapses both into a typed access.
	if _movement_cached is GroundMovement:
		return  # New movement system owns velocity + move_and_slide
	_legacy_movement_step(delta)


## Per-frame bookkeeping that runs regardless of which movement system
## owns this unit's velocity. Pulled out of _physics_process when the
## new MovementComponent path landed (Plan B Phase 0) so flag-on units
## still get animations, HP bars, ability cooldowns, etc.
func _per_frame_bookkeeping(delta: float) -> void:
	# Hover-tank bob + bank (Inquisitor Tank). Slow sine-wave Y offset
	# + bank-into-turns based on horizontal velocity. Pure cosmetic
	# overlay on each member's root — movement / collision unchanged.
	# Skipped early for non-hover units to keep the per-tick cost
	# trivial (one bool read).
	if stats and "is_hover_tank" in stats and (stats.get("is_hover_tank") as bool) and alive_count > 0:
		_hover_phase = fmod(_hover_phase + delta * HOVER_BOB_RATE, TAU)
		var bob_y: float = sin(_hover_phase) * HOVER_BOB_AMPL
		# Bank — tilt around forward axis based on lateral velocity.
		# velocity is body-space when local-axis movement is used, but
		# under GroundMovement it's world-space; project onto the
		# unit's right axis to get a stable "lean into the turn" value.
		var lateral: float = 0.0
		var v: Vector3 = velocity
		v.y = 0.0
		if v.length_squared() > 0.04:
			var right: Vector3 = transform.basis.x
			right.y = 0.0
			if right.length_squared() > 0.001:
				lateral = right.normalized().dot(v)
		var bank_rad: float = clampf(lateral * HOVER_BANK_PER_UNIT_SPEED, -HOVER_BANK_MAX_RAD, HOVER_BANK_MAX_RAD)
		for i: int in _member_data.size():
			if i >= member_hp.size() or member_hp[i] <= 0:
				continue
			var member: Node3D = _member_data[i]["root"] as Node3D
			if not is_instance_valid(member):
				continue
			# Preserve the per-member rest-y so the bob is purely additive.
			var rest_y: float = (_member_data[i].get("hover_rest_y", member.position.y)) as float
			if not _member_data[i].has("hover_rest_y"):
				_member_data[i]["hover_rest_y"] = rest_y
			member.position.y = rest_y + bob_y
			# Smooth-lerp the bank angle so direction changes aren't snappy.
			member.rotation.z = lerp(member.rotation.z, -bank_rad, clampf(delta * HOVER_BANK_LERP_RATE, 0.0, 1.0))
	# Nanite passive regen (Stahlyokai Predator branch).
	# Heals total nanite_regen_per_sec HP / sec across the squad while
	# out of combat (no damage taken in NANITE_OUT_OF_COMBAT_SEC).
	# Fractional accumulator means a 4 HP/sec regen ticks 1 HP every
	# 0.25 s instead of waiting a full second for an int boundary.
	if stats and "nanite_regen_per_sec" in stats:
		var regen_rate: float = stats.nanite_regen_per_sec
		# Ceiling is alive-member HP only — dead members don't regen;
		# apply_heal converts overflow into respawns only via the
		# heal-overflow path, which we don't want a passive regen to
		# tap. Cheap early-out also saves the get_ticks_msec call when
		# the squad is already topped up.
		var alive_cap: int = alive_count * stats.hp_per_unit
		if regen_rate > 0.0 and alive_count > 0 and get_total_hp() < alive_cap:
			var since_dmg: float = float(Time.get_ticks_msec() - _last_damage_taken_msec) / 1000.0
			if _last_damage_taken_msec == 0 or since_dmg >= NANITE_OUT_OF_COMBAT_SEC:
				_nanite_regen_accum += regen_rate * delta
				if _nanite_regen_accum >= 1.0:
					var heal_amt: int = int(_nanite_regen_accum)
					_nanite_regen_accum -= float(heal_amt)
					apply_heal(heal_amt)
	# New-system arrival: legacy clears has_move_order inside
	# _legacy_movement_step when the unit reaches its destination, but that
	# path is skipped under MovementComponent. Without an equivalent here,
	# has_move_order stays true forever after the first command_move, which
	# permanently disables CombatComponent.can_auto_target and stops idle
	# units from engaging nearby enemies.
	#
	# We require sustained settled state (low velocity AND within arrival_radius
	# AND no path progress for ~30 frames) before clearing. A unit briefly
	# blocked while a formation reshuffles hits velocity≈0 and may be inside
	# arrival_radius of its slot for one frame — without the sustain window
	# that single frame would clear has_move_order, the squad would never
	# re-set it, and auto-acquire would pull the unit out of formation.
	# Settle window scaled to the active physics rate. 30 frames
	# was tuned at 60 Hz (~0.5 s); after the rate dropped to 20 Hz
	# the hardcoded 30 became 1.5 s, which kept settled units
	# running heavy steering work for a full second longer than
	# necessary. ~0.5 s of settled state at any tick rate.
	var SETTLE_FRAMES: int = maxi(int(0.5 * float(Engine.physics_ticks_per_second)), 4)
	if has_move_order:
		# _movement_cached is set during construction (or remains null
		# for legacy units). Avoids the per-tick get_node_or_null
		# lookup that was firing every frame on every unit with an
		# active move order — i.e. every unit currently being
		# chased / chasing during combat.
		var mc_typed: MovementComponent = _movement_cached
		if mc_typed != null and is_instance_valid(mc_typed):
			if not mc_typed.has_target():
				has_move_order = false
				move_target = Vector3.INF
				_settled_frames = 0
			else:
				# Distance to the FINAL destination, not the live waypoint.
				# GroundMovement updates `target` to each path waypoint as
				# the unit advances, and seek's arrival_radius slowdown
				# kicks in at every waypoint. Without using the final goal,
				# a unit slowed near an intermediate waypoint by separation
				# could accumulate the settle counter and stop in open
				# terrain mid-route.
				var goal: Vector3 = mc_typed.arrival_target()
				var d: float = global_position.distance_to(goal)
				var v_xz_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
				if d <= mc_typed.arrival_radius and v_xz_sq < 0.25:  # < 0.5 m/s
					_settled_frames += 1
					if _settled_frames >= SETTLE_FRAMES:
						has_move_order = false
						move_target = Vector3.INF
						_settled_frames = 0
				else:
					_settled_frames = 0
	else:
		_settled_frames = 0

	# Damage flash countdown (cheap — runs every frame).
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_restore_member_colors()

	# Active-ability cooldown tick.
	if _ability_cd_remaining > 0.0:
		_ability_cd_remaining = maxf(0.0, _ability_cd_remaining - delta)

	# Wächter deploy state transition tick. No-ops for all other units
	# (_deploy_locked == false by default).
	if _deploy_locked:
		_tick_deploy_state(delta)

	# Heliarch Heat HP drain + Emergency Cooldown. Faction-gated to
	# MatchSettingsClass.FactionId.HELIARCH (== 3). The inner function
	# checks heat tiers and runs the Emergency Cooldown state machine;
	# it no-ops harmlessly for non-Heliarch units because _read_heat_pct()
	# returns 0.0 (Tier 0 — no drain) until Heliarch unit resources exist.
	# alive_count guard: a dying unit (alive_count == 0) is in _die() and
	# take_damage calls inside _tick_heliarch_heat_drain would be no-ops
	# anyway, but skip the entire block to be safe.
	if alive_count > 0 and _faction_id() == 3:  # 3 == MatchSettingsClass.FactionId.HELIARCH
		_tick_heliarch_heat_drain(delta)

	# Courier track-rib scrolling — slide the per-tread plate
	# strip along its segment when the tank's actually moving, so
	# the tracks read as turning over rather than painted-on
	# stripes. Multiplier ~1.4 on top of ground speed sells the
	# "tread runs faster than chassis" feel.
	if not _courier_track_ribs.is_empty():
		var speed_xz: float = Vector2(velocity.x, velocity.z).length()
		if speed_xz > 0.05:
			var scroll: float = speed_xz * delta * 1.4
			for rib_data: Dictionary in _courier_track_ribs:
				# Untyped read first -- the typed `as Node3D` cast
				# itself errors when rib_data["node"] points at a
				# queue_freed Node, before the is_instance_valid
				# guard ever runs.
				var node_v: Variant = rib_data.get("node", null)
				if node_v == null or not is_instance_valid(node_v):
					continue
				var node: Node3D = node_v as Node3D
				if not node:
					continue
				var seg_len: float = rib_data["length"] as float
				node.position.z -= scroll
				if node.position.z < -seg_len * 0.5:
					node.position.z += seg_len
		# Chassis dive / squat. Tracked vehicles without modern
		# stabilisation rock forward when braking and rear when
		# accelerating; we mimic that by applying a pitch to each
		# member root proportional to longitudinal acceleration.
		# Track ribs exist iff this is a transport-class unit, so
		# the loop is gated on the same array. Cost is one
		# Vector2 length + a short member loop per physics frame.
		_apply_tank_chassis_tilt(delta)

	_physics_frame_counter += 1

	# Stealth tick — only stealth-capable units do real work here.
	# Throttled to ~2.5 Hz; reveal proximity changes much slower
	# than the 60 Hz physics loop, and walking the units group is
	# the main cost per check.
	if stats and stats.is_stealth_capable and alive_count > 0:
		_stealth_check_throttle -= delta
		if _stealth_damage_timer > 0.0:
			_stealth_damage_timer -= delta
		if _stealth_check_throttle <= 0.0:
			_stealth_check_throttle = STEALTH_CHECK_INTERVAL
			_tick_stealth()
		# Active-camo pulse: oscillate alpha on the cached material list
		# while concealed. Skips the walk when revealed (cache empty).
		if not stealth_revealed and not _stealth_pulse_mats.is_empty():
			_stealth_pulse_phase += delta
			var phase_rad: float = _stealth_pulse_phase * TAU / STEALTH_PULSE_PERIOD
			var alpha_now: float = STEALTH_PULSE_BASE + STEALTH_PULSE_AMP * sin(phase_rad)
			for mat: StandardMaterial3D in _stealth_pulse_mats:
				if not is_instance_valid(mat):
					continue
				var c: Color = mat.albedo_color
				c.a = alpha_now
				mat.albedo_color = c

	# 1-in-3 frame stagger for ALL visual work — including the HP
	# bar / reload bar / billboard. The previous build kept the bar
	# at full physics rate to dodge "bar lags unit" jitter, but the
	# cumulative profile showed _per_frame_bookkeeping at 99 SECONDS
	# of session time (>30% of total script cost) — by far the
	# dominant function once the 200-unit stress test runs combat.
	# At 20 Hz physics the 1-in-3 stagger gives ~7 Hz visual updates;
	# units moving 6 u/s drift ~0.9 u between bar refreshes which is
	# invisible at typical RTS zoom. Selection / damage indicators
	# still feel responsive — a click waits at most ~150 ms for the
	# bar to pop in, well under perceptual threshold.
	# HP bar position MUST update every physics frame: the bar is
	# top_level, so it does not inherit the parent transform, and at
	# 20 Hz the unit moves ~0.3 u per frame. Letting the bar position
	# update only every 3rd frame (~7 Hz) lags the unit by up to 0.9 u,
	# which reads as visible jitter at typical zoom. The assignment is
	# a few µs — cheap vs the avoid/build/combat work below.
	if _hp_bar and is_instance_valid(_hp_bar) and _hp_bar.visible:
		var pos_h: float = (_cached_total_height if _cached_total_height > 0.0 else _mech_total_height()) + 0.4
		_hp_bar.global_position = global_position + Vector3(0, pos_h, 0)

	# --- Camera-distance cull flag (used by every-frame + staggered work).
	if not _camera_cached or not is_instance_valid(_camera_cached):
		_camera_cached = get_viewport().get_camera_3d() if get_viewport() else null
	var anim_culled: bool = false
	if _camera_cached:
		anim_culled = global_position.distance_squared_to(_camera_cached.global_position) > ANIM_CULL_DIST_SQ

	# --- EVERY-FRAME walk animation. Leg sin() rotation runs at 60 Hz
	# (NOT gated by the 1-in-3 stagger below) so the gait reads smooth
	# instead of flickering. Cheap: one sin + one Vector3 write per
	# leg per frame, ~6 legs per squad-member tops. Per playtest
	# 2026-05-19 the previous staggered path made walk cycles flicker
	# at ~20 Hz, especially on the big-stride apex / caster mechs.
	_idle_time += delta
	if velocity.length_squared() > 1.0:
		_anim_time += delta * 8.0
		if not anim_culled:
			_apply_walk_bob()
	else:
		_anim_time = 0.0
		_idle_anim_throttle += 1
		if _idle_anim_throttle >= IDLE_ANIM_THROTTLE_FRAMES:
			_idle_anim_throttle = 0
			if not anim_culled:
				_reset_walk_bob()
	# Recoil decay must also run every frame so the muzzle-recoil
	# return-to-rest reads smooth (otherwise it ticks at 20 Hz too).
	if not anim_culled and Time.get_ticks_msec() < _recoil_active_until_msec:
		_tick_recoil(delta)

	if (_physics_frame_counter % 3) != _walk_bob_phase:
		return

	# HP bar visibility / fill + reload bar — staggered (cheap work
	# that doesn't need every-frame accuracy).
	if _hp_bar and is_instance_valid(_hp_bar):
		var smooth_damaged: bool = false
		if stats:
			smooth_damaged = get_total_hp() < stats.hp_total
		var smooth_should_show: bool = is_selected or smooth_damaged or hp_bar_hovered
		if _hp_bar.visible != smooth_should_show:
			_hp_bar.visible = smooth_should_show
			# Snap position on the visibility-on edge so a freshly
			# revealed bar doesn't sit at the last cached position.
			if smooth_should_show:
				var pos_h2: float = (_cached_total_height if _cached_total_height > 0.0 else _mech_total_height()) + 0.4
				_hp_bar.global_position = global_position + Vector3(0, pos_h2, 0)
		if smooth_should_show:
			_update_reload_bar()

	# Heavier walking-dust spawn — kept on the 1-in-3 stagger
	# (particle alloc is cheap but adds up at 60 Hz × many units).
	if not anim_culled and velocity.length_squared() > 1.0:
		_tick_walking_dust(delta * 3.0)

	if is_building:
		_animate_build_claw()
		_build_spark_timer -= delta
		if _build_spark_timer <= 0.0:
			_build_spark_timer = 0.16
			_spawn_build_sparks()

	# HP bar BILLBOARD rotation — keeps the bar facing the camera. Position
	# update was moved out to per-frame above; the camera rotation barely
	# changes between physics frames so 20 Hz is plenty here. anim_culled
	# skip is preserved so off-camera units don't pay the rotation write.
	if _hp_bar and is_instance_valid(_hp_bar) and _hp_bar.visible and not anim_culled:
		if _camera_cached:
			_hp_bar.global_rotation = _camera_cached.global_rotation


## Legacy movement integration: NavigationAgent3D pathfinding + direct-
## seek fallback + velocity writes + move_and_slide. Only meaningful
## when _nav_agent is non-null (i.e., the unit was constructed under
## the legacy code path). The internal _nav_agent != null guards
## already cause this to no-op cleanly when the new system is on.
## Plan D will delete this whole helper.
func _legacy_movement_step(delta: float) -> void:
	# EChO override / EMP paralysis. While the timer is hot, force
	# velocity to zero, drop any pending move target, and skip the
	# rest of the physics frame so the unit is fully frozen even
	# if the AI keeps re-issuing commands. Gravity still settles
	# via move_and_slide so airborne units don't hover.
	if _emp_paralysis_remaining > 0.0:
		_emp_paralysis_remaining = maxf(0.0, _emp_paralysis_remaining - delta)
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		else:
			velocity.y = 0.0
		move_target = Vector3.INF
		has_move_order = false
		move_and_slide()
		return

	# 1-in-3 frame stagger — each unit runs heavy work every 3rd physics
	# frame (~20Hz) instead of every frame (60Hz). At 360+ units the
	# half-frame stagger still ate the whole frame budget; tightening
	# further drops the per-frame batch from 180 to ~120 units. Off
	# frames just integrate velocity + gravity so motion stays smooth.
	if (_physics_frame_counter % 3) != _walk_bob_phase:
		# Gravity must run every frame to keep airborne units pinned.
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		else:
			velocity.y = 0.0
		move_and_slide()
		return

	# Gravity — keeps a unit pinned to the ground even when it ends up
	# briefly above floor level (e.g. spawned with a slight Y offset, or
	# walked onto a building edge). Without this the squad would float at
	# whatever Y it last reached and bounce against vertical collision.
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	if move_target == Vector3.INF:
		# Idle. Three cases:
		#  - In combat: the combat loop drives positioning, just zero
		#    horizontal velocity here.
		#  - Patrolling: flip to the other patrol endpoint.
		#  - Otherwise: gently push apart from same-team neighbours so
		#    a clumped squad spreads out at rest.
		var idle_combat_target: Variant = null
		var idle_combat: Node = get_combat()
		if idle_combat:
			idle_combat_target = idle_combat.get("_current_target")
		# `is Object` against a freed Variant crashes ("Left operand of
		# 'is' is a previously freed instance"). `is_instance_valid`
		# safely returns false on a stale reference, so it's the
		# right primitive here.
		var has_combat: bool = idle_combat_target != null and is_instance_valid(idle_combat_target)
		if has_combat:
			velocity.x = 0.0
			velocity.z = 0.0
		elif patrol_a != Vector3.INF and patrol_b != Vector3.INF:
			# Pick whichever endpoint is further from us — that's the
			# next leg. attack_move so the unit fights en route.
			var d_a: float = global_position.distance_to(patrol_a)
			var d_b: float = global_position.distance_to(patrol_b)
			var next: Vector3 = patrol_a if d_a > d_b else patrol_b
			var combat: Node = get_combat()
			if combat and combat.has_method("command_attack_move"):
				combat.command_attack_move(next)
			else:
				command_move(next, false)
			velocity.x = 0.0
			velocity.z = 0.0
		else:
			# Idle-spread is O(N) per call (iterates all units), and called
			# per idle unit per physics frame that's O(N²) total. Throttle
			# to share the work across frames using the same staggered
			# counter as the walk-bob reset. Velocity persists between
			# frames, so the unit keeps drifting in the previously-computed
			# direction during the off frames.
			if _idle_anim_throttle == 0:
				_apply_idle_spread()
		# Always run move_and_slide while idle — gravity needs to settle
		# airborne units, and the spread velocity (when set) needs to
		# actually move the body.
		move_and_slide()
		return

	# Use NavigationAgent for pathfinding if available
	if _nav_agent and _nav_agent.is_navigation_finished():
		# Reached this waypoint. If there are queued ones, advance —
		# otherwise the move order is fully complete.
		if not move_queue.is_empty():
			var next_wp: Vector3 = move_queue.pop_front() as Vector3
			move_target = Vector3(next_wp.x, global_position.y, next_wp.z)
			_stuck_timer = 0.0
			_nav_agent.target_position = move_target
			return
		has_move_order = false
		stop()
		arrived.emit()
		return

	var next_pos: Vector3
	if _nav_agent:
		next_pos = _nav_agent.get_next_path_position()
	else:
		next_pos = move_target

	var to_next := next_pos - global_position
	to_next.y = 0.0
	var distance := to_next.length()

	if distance < ARRIVE_THRESHOLD:
		if not _nav_agent or _nav_agent.is_navigation_finished():
			# Same waypoint-advance logic as the nav-finished branch
			# above — kept here for the no-NavAgent fallback path.
			if not move_queue.is_empty():
				var next_wp: Vector3 = move_queue.pop_front() as Vector3
				move_target = Vector3(next_wp.x, global_position.y, next_wp.z)
				_stuck_timer = 0.0
				if _nav_agent:
					_nav_agent.target_position = move_target
				return
			has_move_order = false
			stop()
			arrived.emit()
			return

	var direction := to_next / maxf(distance, 0.01)
	# Wall deflection — when the unit is wedged head-on against geometry,
	# `move_and_slide` zeroes the perpendicular component and the squad
	# stops dead instead of sliding around the building. Briefly rotating
	# the desired heading sideways gives slide a real lateral component
	# to work with so it wraps the corner. The angle ramps up the longer
	# the unit has been stuck so a thick wall eventually triggers near-
	# perpendicular sidesteps.
	var now_msec: int = Time.get_ticks_msec()
	if now_msec < _deflect_until_msec and _deflect_sign != 0.0:
		direction = direction.rotated(Vector3.UP, _deflect_sign * deg_to_rad(_deflect_angle_deg))
	# Preserve the y component (gravity accumulator) so the unit keeps
	# falling toward the floor while moving horizontally.
	velocity.x = direction.x * _move_speed
	velocity.z = direction.z * _move_speed

	# Shrink the leader collision box while moving so squads can
	# pass through each other in transit. At rest the box snaps
	# back to its full size so stacked mechs physically separate.
	_update_movement_collision()

	var prev_pos: Vector3 = global_position
	move_and_slide()

	# Stuck-rescue ladder. Successive tiers escalate the deflection
	# angle so a thick wall (where 50° still leaves the unit wedged)
	# eventually triggers near-perpendicular sidesteps that walk the
	# unit around the obstacle. We never rewrite `_nav_agent.target_position`
	# to anything other than `move_target` itself — past attempts to
	# nudge it 2u sideways made the agent report "navigation finished"
	# and the unit dropped its move order entirely. The original move
	# target stays authoritative; only the desired *direction* per
	# frame is rotated.
	var actual_move: float = (global_position - prev_pos).length()
	var expected_move: float = _move_speed * delta * 0.3
	# Zero-movement repath: when the unit has a move order but the
	# physics step produced essentially no displacement, force the
	# NavigationAgent to recompute its path immediately. The
	# deflection ladder below still handles the "moved a little but
	# not enough" cases; this branch catches the harder failure
	# mode where the agent is stuck against fresh geometry (a
	# building that just rose, a wreck that just spawned) and is
	# returning a stale next_path_position. Throttled to avoid
	# spamming the navigation server every frame while wedged.
	# A unit standing still while shooting a live target isn't
	# stuck -- it's intentionally holding ground to fire. Skip the
	# zero-move repath + the deflection / detour ladder while a
	# combat target is engaged so the rescue logic doesn't yank
	# the unit out of position to rotate around an enemy it's
	# already killing. The `_in_active_combat` helper checks the
	# CombatComponent's _current_target for a live, valid target.
	var in_combat: bool = _in_active_combat()
	if actual_move < 0.001 and has_move_order and _nav_agent and not in_combat:
		if now_msec >= _zero_move_repath_at_msec:
			_nav_agent.target_position = move_target
			_zero_move_repath_at_msec = now_msec + 500
	if actual_move < expected_move and not in_combat:
		_stuck_timer += delta
		# 0.6s — ramp self-rescue. Side-to-side wiggle from the
		# deflection ladder doesn't actually clear a ramp; the unit
		# just paces the slope. Detect 'stuck on a ramp' and re-aim
		# at the far end of the ramp's clearance rect so the unit
		# physically traverses the slope instead.
		if _stuck_timer >= 0.6 and now_msec >= _ramp_rescue_at_msec:
			if _try_ramp_stuck_rescue():
				_ramp_rescue_at_msec = now_msec + 1200
		# 0.25s — first sidestep, ~50°. Light corner / shoulder bump.
		if _stuck_timer >= 0.25 and now_msec >= _deflect_until_msec:
			_deflect_sign = 1.0 if (get_instance_id() % 2) == 0 else -1.0
			_deflect_angle_deg = 50.0
			_deflect_until_msec = now_msec + 700
		# 0.9s — flip side, same angle. Maybe we picked the wrong way.
		if _stuck_timer >= 0.9 and _stuck_timer < 0.9 + delta * 1.5:
			_deflect_sign = -_deflect_sign
			_deflect_angle_deg = 50.0
			_deflect_until_msec = now_msec + 900
			if _nav_agent:
				_nav_agent.target_position = move_target
		# 1.4s — building detour. The deflection sidesteps wiggle but
		# don't change the path the navmesh hands back; if the unit's
		# stuck on a building corner, the agent keeps producing the
		# same blocked route. Insert a side-step waypoint AROUND the
		# nearest blocking building so the unit physically routes
		# past it before retrying the original target. Once-every-3s
		# throttle so a stuck-against-a-wall unit doesn't stack
		# detour waypoints on top of each other.
		if _stuck_timer >= 1.4 and now_msec >= _detour_attempted_at_msec:
			if _try_unit_detour_around_building():
				_detour_attempted_at_msec = now_msec + 3000
		# 1.8s — escalate to 75°. Pure-perpendicular slide along the
		# obstacle edge.
		if _stuck_timer >= 1.8 and _stuck_timer < 1.8 + delta * 1.5:
			_deflect_sign = -_deflect_sign
			_deflect_angle_deg = 75.0
			_deflect_until_msec = now_msec + 1500
		# 3.5s — escalate to 95°. Slightly past perpendicular — the
		# unit briefly walks AWAY from the target to find an alternate
		# approach lane around a thick wall.
		if _stuck_timer >= 3.5 and _stuck_timer < 3.5 + delta * 1.5:
			_deflect_sign = -_deflect_sign
			_deflect_angle_deg = 95.0
			_deflect_until_msec = now_msec + 2000
			if _nav_agent:
				_nav_agent.target_position = move_target
		# 7s — same again, opposite side. Last big push before give-up.
		if _stuck_timer >= 7.0 and _stuck_timer < 7.0 + delta * 1.5:
			_deflect_sign = -_deflect_sign
			_deflect_angle_deg = 95.0
			_deflect_until_msec = now_msec + 2500
			if _nav_agent:
				_nav_agent.target_position = move_target
		# 14s — finally accept that we can't reach (target may be in a
		# sealed area). Stop so we don't grind here forever; the
		# player can manually re-task.
		elif _stuck_timer > 14.0:
			has_move_order = false
			stop()
			arrived.emit()
			return
	else:
		_stuck_timer = 0.0
		_deflect_angle_deg = 50.0
	# Combat overrides the rescue ladder entirely. Reset the stuck
	# timer when engaged so a long firefight doesn't wake up a
	# 14s give-up the moment the target dies.
	if in_combat:
		_stuck_timer = 0.0
		_deflect_angle_deg = 50.0

	_last_position = global_position

	var face_dir := velocity.normalized()
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.001:
		_turn_toward(face_dir, delta)


func _apply_idle_spread() -> void:
	## Gently pushes the unit away from any same-team neighbour that's
	## inside `IDLE_SPREAD_MIN_DIST`. Sums per-neighbour push vectors
	## (closer = stronger) and writes them to `velocity.x/.z`.
	## Spatial-index lookup so a 200-pop match doesn't pay
	## O(N) per idle unit -- the previous full-group walk produced
	## the dominant cost in the per-tick stagger profile because
	## every idle unit visited every other unit. Index buckets only
	## return entities within a few cells, so the per-call cost
	## stays bounded regardless of fleet size.
	var push: Vector3 = Vector3.ZERO
	var idx: SpatialIndex = SpatialIndex.get_instance(get_tree().current_scene) if get_tree() else null
	var candidates: Array = idx.nearby(global_position, IDLE_SPREAD_MIN_DIST) if idx else get_tree().get_nodes_in_group("units")
	for raw in candidates:
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if not node or node == self:
			continue
		if not ("owner_id" in node) or node.get("owner_id") != owner_id:
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var other: Node3D = node as Node3D
		if not other:
			continue
		var to_self: Vector3 = global_position - other.global_position
		to_self.y = 0.0
		var d: float = to_self.length()
		if d > IDLE_SPREAD_MIN_DIST or d < 0.001:
			continue
		# Closer overlap → stronger push.
		var strength: float = (1.0 - d / IDLE_SPREAD_MIN_DIST) * IDLE_SPREAD_FORCE
		push += to_self.normalized() * strength
	# Cap so a unit caught in a really dense pile doesn't shoot off at
	# combat speed.
	if push.length() > IDLE_SPREAD_FORCE:
		push = push.normalized() * IDLE_SPREAD_FORCE
	velocity.x = push.x
	velocity.z = push.z


func _turn_toward(face_dir: Vector3, delta: float) -> void:
	## Constant angular-velocity turn around Y. Replaces the previous
	## smoothstep lerp_angle which felt floaty -- the lerp factor
	## (turn_speed * delta) was tiny per frame, so big direction
	## changes (180deg kite-back) interpolated slowly while small
	## ones felt instant. Now the unit rotates at exactly
	## `_turn_speed` rad/sec regardless of how far it has to turn,
	## matching how Dota 2 / SC2 handle facing: a hard cap on
	## degrees per second so heavies pivot visibly slower than
	## lights but neither feels rubber-banded.
	if face_dir.length_squared() < 0.0001:
		return
	# atan2(x, z) gives the Y rotation that orients -Z toward face_dir; -PI matches look_at.
	var target_y: float = atan2(face_dir.x, face_dir.z) + PI
	# Signed shortest-path delta in [-PI, PI]. wrapf gives us the
	# wrap; we then clamp the per-frame step to turn_speed * delta
	# and apply it directly so the rotation closes at constant
	# angular velocity until it's within one frame's step of the
	# target.
	var diff: float = wrapf(target_y - rotation.y, -PI, PI)
	var max_step: float = _turn_speed * delta
	var step: float = clampf(diff, -max_step, max_step)
	rotation.y += step


## Per-tank chassis pitch state (radians). Updated each physics
## frame from longitudinal acceleration; lerped back to neutral
## when no acceleration delta is present.
var _tank_chassis_pitch: float = 0.0
var _tank_prev_speed_signed: float = 0.0
## Last value written to member_root.rotation.x. When the new pitch
## hasn't drifted from this since the previous tick, the per-member
## rotation write loop is a no-op — skip it. A stationary tank under
## fire has zero longitudinal acceleration; target_pitch decays to 0;
## _tank_chassis_pitch decays to 0; without this guard the loop fires
## every tick to write the same 0 to every member root.
var _tank_chassis_pitch_applied: float = 0.0


func _apply_tank_chassis_tilt(delta: float) -> void:
	## Tracked vehicle dive / squat. Compares this frame's
	## longitudinal speed (positive = forward, negative = reverse)
	## to last frame's to derive an acceleration sign, then pitches
	## the visible chassis around X to mimic an unsuspended hull
	## rocking when the engine spools / brakes bite.
	#
	# Magnitudes:
	#   - Pitch peak ~5 deg either direction. Bigger reads as
	#     comedy bobblehead; smaller as no animation.
	#   - Lerp back toward zero at REST_RECOVERY_RAD_PER_SEC when
	#     acceleration is small so the chassis settles cleanly.
	const TILT_PER_ACCEL: float = 0.020  # rad gained per (u/s^2)
	const TILT_MAX: float = 0.087        # ~5 deg cap
	const REST_RECOVERY_RAD_PER_SEC: float = 0.45  # rad/s back to neutral
	# Forward velocity component projected onto the unit's local
	# -Z axis (the unit's facing). Positive = moving forward.
	var fwd: Vector3 = -global_basis.z
	var v_xz: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var speed_signed: float = v_xz.dot(fwd)
	var accel: float = (speed_signed - _tank_prev_speed_signed) / maxf(delta, 0.0001)
	_tank_prev_speed_signed = speed_signed
	# Acceleration drives the target pitch. Positive accel (engine
	# spinning up) -> nose lifts, chassis pitches BACK (positive X
	# rotation in unit-local frame). Braking flips the sign.
	var target_pitch: float = clampf(-accel * TILT_PER_ACCEL, -TILT_MAX, TILT_MAX)
	# Recover toward target. Rate scales with how far we are from
	# target so big swings settle in roughly half a second; small
	# nudges damp quickly.
	var step: float = REST_RECOVERY_RAD_PER_SEC * delta
	var diff: float = target_pitch - _tank_chassis_pitch
	if absf(diff) <= step:
		_tank_chassis_pitch = target_pitch
	else:
		_tank_chassis_pitch += step * signf(diff)
	# Skip the per-member rotation write when the chassis pitch hasn't
	# meaningfully changed since the last frame we wrote it. Stationary
	# tanks under fire have zero longitudinal acceleration, so target
	# pitch is 0 and _tank_chassis_pitch settles at 0 — every tick was
	# writing the same rotation back. With multiple tanks in a base
	# under aircraft fire that's N_tanks × N_members per tick of pure
	# overhead. 0.0005 rad ≈ 0.029° — well below visual perception.
	if absf(_tank_chassis_pitch - _tank_chassis_pitch_applied) < 0.0005:
		return
	_tank_chassis_pitch_applied = _tank_chassis_pitch
	# Apply to every member's local rotation.x. Members are the
	# chassis roots (one per squad seat); tilting them rocks the
	# whole tank without disturbing the squad's world position.
	for entry: Dictionary in _member_data:
		var root_v: Variant = entry.get("root", null)
		if root_v == null or not is_instance_valid(root_v):
			continue
		var root: Node3D = root_v as Node3D
		if not root:
			continue
		root.rotation.x = _tank_chassis_pitch


func _apply_walk_bob() -> void:
	# Hover-tank guard: the hover bob in _per_frame_bookkeeping owns
	# position.y for is_hover_tank units. _apply_walk_bob's torso bob
	# (legs absent on hover, bob_amount = 0 → bob = 0) would overwrite
	# the hover offset with 0 every 3rd frame, producing the small
	# vertical jitter on top of the bob the player reported. Bail
	# early so hover units stay smooth.
	if stats and "is_hover_tank" in stats and (stats.get("is_hover_tank") as bool):
		return
	# Mech walk: swing each leg around its hip and bob the torso slightly.
	# Per-member stride speed/phase/swing makes the squad feel like four
	# individuals walking together rather than a parade.
	#
	# When the squad is on a slope (ramp or general elevation > 0.2u),
	# each member's Y is snapped to the actual surface beneath via a
	# physics raycast — without that snap the back/front members of the
	# squad appear to float in air while the squad center rides the
	# slope. Raycasts are throttled by `_bob_raycast_throttle` (an
	# independent counter that ticks every physics frame, regardless of
	# move/idle state), so a moving squad on a ramp pays the cost every
	# BOB_RAYCAST_THROTTLE_FRAMES tick instead of 60Hz.
	_bob_raycast_throttle += 1
	if _bob_raycast_throttle >= BOB_RAYCAST_THROTTLE_FRAMES:
		_bob_raycast_throttle = 0
	var on_slope: bool = absf(velocity.y) > 0.05 or global_position.y > 0.2
	var space: PhysicsDirectSpaceState3D = null
	if on_slope and _bob_raycast_throttle == 0:
		space = get_world_3d().direct_space_state
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var member: Node3D = data["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		var phase: float = _anim_time * (data["stride_speed"] as float) + (data["stride_phase"] as float)
		var swing: float = data["stride_swing"] as float
		var legs: Array = data["legs"] as Array
		var leg_phases: Array = data["leg_phases"] as Array
		for li: int in legs.size():
			var leg: Node3D = legs[li]
			if not is_instance_valid(leg):
				continue
			# Each leg has its own phase offset (biped: alternating; spider/quadruped: trot).
			var phase_offset: float = 0.0
			if li < leg_phases.size():
				phase_offset = leg_phases[li] as float
			leg.rotation.x = sin(phase + phase_offset) * swing
		# Torso bob doubles per stride cycle (peaks when feet plant).
		var bob: float = absf(sin(phase)) * (data["bob_amount"] as float)
		# Wächter deploy: subtract the sink offset so the body stays
		# anchored when deployed/transitioning. The bob would otherwise
		# overwrite the sink every frame, producing the rapid in/out
		# bouncing the user reported.
		var deploy_sink: float = _wachter_deploy_sink_offset
		if space:
			# Cast a short ray straight down from the member's current
			# world position and snap it onto whatever surface is below.
			# Layer 5 = ground (1) + terrain/elevation (4); covers
			# ramps, plateau tops, and the regular ground plane.
			var origin: Vector3 = member.global_position + Vector3(0, 2.0, 0)
			var to: Vector3 = member.global_position + Vector3(0, -3.0, 0)
			var query := PhysicsRayQueryParameters3D.create(origin, to, 5)
			var hit := space.intersect_ray(query)
			if hit.has("position"):
				# Convert the world-space surface y into member-local y
				# (relative to the parent unit) so it composes correctly
				# with the bob offset.
				var surface_world_y: float = (hit["position"] as Vector3).y
				member.position.y = surface_world_y - global_position.y + bob - deploy_sink
				continue
		member.position.y = bob - deploy_sink


func _reset_walk_bob() -> void:
	# Hover-tank guard: see _apply_walk_bob comment. _reset_walk_bob's
	# tiny idle sway (sin(idle_phase) * 0.012) would overwrite the
	# hover bob every ~15Hz tick, beating against the smooth bob.
	if stats and "is_hover_tank" in stats and (stats.get("is_hover_tank") as bool):
		return
	# Idle: lerp legs back to neutral, then add a slow weight-shift sway so
	# the mechs don't look frozen while standing.
	var t_idle: float = _idle_time
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var member: Node3D = data["root"]
		var legs: Array = data["legs"] as Array
		for leg: Node3D in legs:
			if is_instance_valid(leg):
				leg.rotation.x = lerp(leg.rotation.x, 0.0, 0.2)
		if is_instance_valid(member):
			# Subtle idle sway — small vertical breath + tiny lateral weight shift,
			# different per member so they don't sway in unison.
			var idle_phase: float = t_idle * (data["idle_speed"] as float) + (data["idle_phase"] as float)
			# Wächter deploy: same composition rule as _apply_walk_bob — subtract
			# the deploy sink so the body stays anchored when deployed.
			member.position.y = sin(idle_phase) * 0.012 - _wachter_deploy_sink_offset
			# Tiny lean — unit-local X — gives a relaxed feel without breaking formation.
			member.rotation.z = sin(idle_phase * 0.7) * 0.012
			# Expressive idle -- the head (chicken-leg walker top
			# turret) slowly swivels left/right and the cannons
			# tilt up/down a touch. Sells the unit as 'alert,
			# scanning' rather than statically frozen. Very small
			# arc + slow phase per-member so a squad doesn't sway
			# in lockstep.
			var head: Node3D = data.get("head", null) as Node3D
			if head and is_instance_valid(head):
				head.rotation.y = sin(idle_phase * 0.35) * 0.18
			var cannons: Array = data.get("cannons", []) as Array
			if not cannons.is_empty():
				var cannon_pitch: float = sin(idle_phase * 0.5 + 1.7) * 0.08
				for c_node in cannons:
					if c_node and is_instance_valid(c_node):
						(c_node as Node3D).rotation.x = cannon_pitch


## --- Shooting Animation ---

func play_shoot_anim() -> void:
	## Kick all alive members' cannons backward; combat_component calls this on fire.
	# Arm the recoil window so `_physics_process` actually invokes
	# `_tick_recoil` for the next ~250ms (covers the 8/s decay back to
	# rest). Idle squads with no shooting pay zero recoil cost.
	_recoil_active_until_msec = Time.get_ticks_msec() + 260
	for i: int in _member_data.size():
		if i >= member_hp.size() or member_hp[i] <= 0:
			continue
		var member: Node3D = _member_data[i]["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		# Kick every cannon index this member actually has, instead
		# of hardcoding [0]+[1]. Single-cannon units (Breacher Tank
		# casemate, gun emplacements) carry recoil = [0.0] and
		# crashed on recoil[1] = 1.0. Iterating to recoil.size() is
		# also forward-compatible with three-cannon variants we
		# might add later.
		var recoil: Array = _member_data[i]["recoil"] as Array
		for ri: int in recoil.size():
			recoil[ri] = 1.0


func play_melee_anim() -> void:
	## Melee swing animation. Two layers:
	##   (1) Forward chassis lunge — drives any registered cannon
	##       pivots forward by RECOIL_DISTANCE via the recoil tick.
	##       Mostly a no-op for melee-only units (no cannons), but
	##       harmless when cannons happen to be present.
	##   (2) Weapon swing tween — every Node3D in the "melee_pivots"
	##       group under each alive member gets a short tween that
	##       rotates the pivot ~55° forward (around its `melee_swing_axis`
	##       meta — "x" for daggers, "z" for hammer) then snaps back to
	##       the rest rotation cached in `melee_rest_rot`. Sells the
	##       blade thrust / hammer overhead-swing visibly at RTS zoom.
	## Called by CombatComponent on every melee strike; idle squads pay
	## zero cost.
	_recoil_active_until_msec = Time.get_ticks_msec() + 260
	for i: int in _member_data.size():
		if i >= member_hp.size() or member_hp[i] <= 0:
			continue
		var member: Node3D = _member_data[i]["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		var recoil: Array = _member_data[i]["recoil"] as Array
		for ri: int in recoil.size():
			recoil[ri] = -1.0  # negative = forward lunge instead of aft recoil
		# Weapon swing tween — walk the member's subtree for any
		# Node3D registered in "melee_pivots" and animate it.
		_swing_melee_pivots_for_member(member)


func _swing_melee_pivots_for_member(member: Node3D) -> void:
	## Finds every "melee_pivot"-tagged Node3D in the member's subtree
	## and launches a quick swing tween. Each pivot's rest rotation
	## (stored in meta on build) is the return target.
	## Swing arc: ~55° forward in 0.10s, then back to rest in 0.18s.
	## Tween auto-frees itself.
	const SWING_RAD: float = 0.96   # ~55°
	const SWING_OUT_SEC: float = 0.10
	const SWING_BACK_SEC: float = 0.18
	for child: Node in _flatten_subtree(member):
		if not (child is Node3D):
			continue
		if not (child as Node).is_in_group("melee_pivots"):
			continue
		var pivot: Node3D = child as Node3D
		if not is_instance_valid(pivot):
			continue
		var rest_rot: Vector3 = pivot.get_meta("melee_rest_rot", pivot.rotation) as Vector3
		var axis: String = pivot.get_meta("melee_swing_axis", "x") as String
		var swing_rot: Vector3 = rest_rot
		match axis:
			"x": swing_rot.x = rest_rot.x - SWING_RAD  # forward = -X (toward target)
			"z": swing_rot.z = rest_rot.z - SWING_RAD  # overhead chop
			_: swing_rot.x = rest_rot.x - SWING_RAD
		# Cancel any in-flight melee tween on this pivot — back-to-back
		# strikes shouldn't queue up overlapping arcs.
		var prev_tween_v: Variant = pivot.get_meta("melee_tween", null)
		if prev_tween_v != null and prev_tween_v is Tween:
			var prev_tween: Tween = prev_tween_v as Tween
			if prev_tween.is_valid():
				prev_tween.kill()
		var tw: Tween = pivot.create_tween()
		tw.tween_property(pivot, "rotation", swing_rot, SWING_OUT_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(pivot, "rotation", rest_rot, SWING_BACK_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN_OUT)
		pivot.set_meta("melee_tween", tw)


func _flatten_subtree(root: Node) -> Array[Node]:
	## DFS-flatten a node's subtree. Used by the melee-swing dispatch
	## to find every "melee_pivots"-tagged descendant in a member's
	## tree. Cheap for typical squad-member subtrees (~30 nodes).
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if not is_instance_valid(n):
			continue
		out.append(n)
		for c: Node in n.get_children():
			stack.append(c)
	return out


func _tick_recoil(delta: float) -> void:
	const RECOIL_DECAY: float = 8.0
	const RECOIL_DISTANCE: float = 0.18
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var cannons: Array = data["cannons"] as Array
		var recoil: Array = data["recoil"] as Array
		var rest_z: Array = data.get("cannon_rest_z", []) as Array
		var changed: bool = false
		for c: int in cannons.size():
			var r: float = recoil[c] as float
			# Skip rest-state cannons. r > 0 = aft kick (gun recoil);
			# r < 0 = forward lunge (melee swing). Both decay back to 0.
			if r == 0.0:
				continue
			# Decay magnitude toward zero, preserving sign so a melee
			# lunge (r=-1.0) decays through (-0.8, -0.6, ...) → 0.
			if r > 0.0:
				r = maxf(0.0, r - delta * RECOIL_DECAY)
			else:
				r = minf(0.0, r + delta * RECOIL_DECAY)
			recoil[c] = r
			var pivot: Node3D = cannons[c]
			if is_instance_valid(pivot):
				# Recoil is an OFFSET on top of the cannon's rest position; the
				# rest may be non-zero (e.g., Bulwark's hull-mounted gun sits at
				# the chassis front), so we must add to it instead of replacing.
				# Positive r → aft (+RECOIL_DISTANCE); negative r → forward.
				var base_z: float = 0.0
				if c < rest_z.size():
					base_z = rest_z[c] as float
				pivot.position.z = base_z + r * RECOIL_DISTANCE
			changed = true
		if changed:
			data["recoil"] = recoil


## --- Floating damage numbers / camera shake ---

func _spawn_damage_number(amount: int) -> void:
	## Floating yellow number above the unit that drifts up and fades out.
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	# FOW gate -- damage numbers spawning over a unit the local player
	# can't currently see leaks the unit's position through fog. Only
	# pop them when the cell is in live vision.
	var fow: Node = scene.get_node_or_null("FogOfWar")
	if fow and fow.has_method("is_visible_world"):
		if not fow.call("is_visible_world", global_position):
			return
	var label := Label3D.new()
	label.text = "%d" % amount
	label.font_size = 36
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(1.0, 0.9, 0.3, 1.0)
	label.outline_size = 8
	label.outline_modulate = Color(0.0, 0.0, 0.0, 1.0)
	# Spawn above the squad's HP bar with a small random horizontal jitter.
	var spawn_pos: Vector3 = global_position + Vector3(
		randf_range(-0.3, 0.3),
		_mech_total_height() + 0.7,
		randf_range(-0.3, 0.3)
	)
	# Add to tree FIRST, then assign global_position — Setting it pre-tree
	# fires a !is_inside_tree() warning per damage tick and was a major
	# contributor to the debugger error flood.
	scene.add_child(label)
	label.global_position = spawn_pos

	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", spawn_pos + Vector3(0, 1.4, 0), 0.7).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.7).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)


func _request_camera_shake(amount: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d() if get_viewport() else null
	if cam and cam.has_method("add_shake"):
		cam.add_shake(amount)


## --- Walking dust ---

func _tick_walking_dust(delta: float) -> void:
	## Spawn dust puffs at random member feet while moving. Heavier mechs
	## (bigger torso width) raise more frequent and bigger puffs; lights and
	## engineers barely scuff the ground.
	# Cheapest test first — `_dust_timer` is the dominant gate. The timer
	# check happens every moving frame; only every ~0.18-0.7s does it
	# expire and reach the heavier work below.
	_dust_timer -= delta
	if _dust_timer > 0.0:
		return
	if not stats:
		return
	var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	var torso_width: float = (shape["torso"] as Vector3).x
	# Below this width we don't bother — Ratchets / Rooks would over-emit.
	if torso_width < 0.5:
		return
	# Bigger mechs trigger faster: ~0.45 s for medium, down to ~0.18 s for apex.
	var interval: float = clampf(0.65 / torso_width, 0.18, 0.7)
	_dust_timer = interval

	# Pick a random alive member and spawn a puff at its foot world position.
	var alive_indices: Array = []
	for i: int in member_hp.size():
		if member_hp[i] > 0:
			alive_indices.append(i)
	if alive_indices.is_empty():
		return
	var idx: int = alive_indices[randi() % alive_indices.size()]
	var member: Node3D = _member_meshes[idx] if idx < _member_meshes.size() else null
	if not is_instance_valid(member):
		return

	var foot_pos: Vector3 = member.global_position
	foot_pos.y = 0.05

	# Scale puff size with torso width.
	var puff_radius: float = clampf(torso_width * 0.35, 0.18, 0.55)
	_spawn_dust_puff(foot_pos, puff_radius)


func _spawn_dust_puff(world_pos: Vector3, radius: float) -> void:
	# Walking dust → GPU particle. The `radius` arg used to size the
	# legacy MeshInstance3D — now it scales the emitted particle's
	# initial color saturation (used as a visual cue for big stomps vs
	# small footsteps). One emit_particle call.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if pem:
		pem.emit_dust(world_pos, 1, clampf(radius * 4.0, 0.5, 1.5))


## --- Build Animation ---

func _animate_build_claw() -> void:
	## Engineer's tool arm hammers up-down rapidly while constructing.
	for data: Dictionary in _member_data:
		var cannons: Array = data["cannons"] as Array
		if cannons.is_empty():
			continue
		var pivot: Node3D = cannons[0]
		if not is_instance_valid(pivot):
			continue
		var t: float = _idle_time * 11.0 + (data["stride_phase"] as float)
		# Forward + downward hammer arc, biased so the claw spends more time
		# at the bottom of its swing.
		pivot.rotation.x = sin(t) * 0.55 - 0.25


func _spawn_build_sparks() -> void:
	## Welding sparks → GPU particle emitter. One emit per active claw tip
	## per build tick instead of allocating MeshInstance3D + Tween per
	## spark.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if not pem:
		return
	for data: Dictionary in _member_data:
		var cannons: Array = data["cannons"] as Array
		if cannons.is_empty():
			continue
		var pivot: Node3D = cannons[0]
		if not is_instance_valid(pivot) or not pivot.visible:
			continue
		var tip_world: Vector3 = pivot.global_transform * Vector3(0, 0, -0.55)
		# 2-3 sparks per tick gives the same visual density as the
		# previous single-spark per member.
		pem.emit_spark(tip_world, randi_range(2, 3))


## --- Destruction Animation ---

func _spawn_member_debris(world_pos: Vector3) -> void:
	## Per-member death: small burst of metal chunks flying outward.
	var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"]) if stats else CLASS_SHAPES[&"medium"]
	var base_color: Color = shape["color"] as Color
	_spawn_debris_burst(world_pos, base_color, 6, 4.5, 0.12)
	_spawn_flash_at(world_pos, Color(1.0, 0.6, 0.2), 0.35, 0.18)


func _spawn_squad_death_explosion() -> void:
	## Final death: bigger flash + larger debris burst at the unit's center.
	var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"]) if stats else CLASS_SHAPES[&"medium"]
	var base_color: Color = shape["color"] as Color
	var center: Vector3 = global_position + Vector3(0, _mech_total_height() * 0.5, 0)
	_spawn_debris_burst(center, base_color, 14, 7.0, 0.18)
	_spawn_flash_at(center, Color(1.0, 0.5, 0.15), 0.7, 0.45)


func _spawn_debris_burst(world_pos: Vector3, color: Color, count: int, speed: float, size: float) -> void:
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	for i: int in count:
		var chunk := MeshInstance3D.new()
		var box := BoxMesh.new()
		var s: float = size * randf_range(0.6, 1.3)
		box.size = Vector3(s, s, s)
		chunk.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(color.r * 0.7, color.g * 0.7, color.b * 0.7)
		mat.roughness = 0.9
		mat.metallic = 0.4
		chunk.set_surface_override_material(0, mat)
		chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		scene.add_child(chunk)
		chunk.global_position = world_pos

		var dir := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(0.6, 1.4),
			randf_range(-1.0, 1.0)
		).normalized()
		var vel: Vector3 = dir * speed * randf_range(0.7, 1.2)
		var spin: Vector3 = Vector3(
			randf_range(-12.0, 12.0),
			randf_range(-12.0, 12.0),
			randf_range(-12.0, 12.0)
		)
		_animate_debris(chunk, vel, spin, randf_range(0.7, 1.1))


func _animate_debris(chunk: MeshInstance3D, velocity: Vector3, spin: Vector3, lifetime: float) -> void:
	# Pure-property tween bound to the chunk so it survives the unit being freed.
	# We approximate ballistic motion as a straight outward fly + ease-in-quad fall,
	# keeping it lightweight (no per-frame method callbacks).
	var start_pos: Vector3 = chunk.global_position
	var end_pos: Vector3 = start_pos + velocity * lifetime
	end_pos.y = maxf(end_pos.y - 4.0 * lifetime * lifetime, 0.05)

	var tween := chunk.create_tween()
	tween.set_parallel(true)
	tween.tween_property(chunk, "global_position", end_pos, lifetime).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(chunk, "rotation", chunk.rotation + spin * lifetime, lifetime)
	tween.tween_property(chunk, "scale", Vector3(0.15, 0.15, 0.15), lifetime).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(chunk.queue_free)


func _spawn_flash_at(world_pos: Vector3, color: Color, radius: float, lifetime: float) -> void:
	# Death-flash visual → GPU particle. `radius`/`lifetime` are ignored
	# now (the emitter's process material owns the curves) — bigger
	# explosions emit MORE particles instead of one bigger sphere,
	# which actually reads better. The scene-light pop is kept on the
	# CPU because it affects nearby unit shading.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if pem:
		# Member-death (small radius) emits 1 flash; squad-death
		# (radius >= 0.5 typically) emits a cluster.
		var n: int = 6 if radius >= 0.5 else 1
		pem.emit_flash(world_pos, Color(color.r, color.g, color.b, 0.95), n)

	var scene: Node = get_tree().current_scene
	if not scene:
		return
	# Real OmniLight3D so the explosion bathes nearby geometry. Range scales
	# with the flash radius (small radius = small flash on member death,
	# bigger radius = full squad death explosion).
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 5.0
	light.omni_range = radius * 6.0 + 2.0
	scene.add_child(light)
	light.global_position = world_pos
	var ltween := light.create_tween()
	ltween.tween_property(light, "light_energy", 0.0, lifetime).set_ease(Tween.EASE_OUT)
	ltween.tween_callback(light.queue_free)


## --- HP and Damage ---

func _damage_priority_order() -> Array[int]:
	## Returns member indices ordered by squared distance from the
	## squad centre, DESCENDING — outer members get hit first. Empty
	## squads or single-member units return [0].
	if not stats:
		return [0]
	var squad: int = stats.squad_size
	var unit_offsets: Array = FORMATION_OFFSETS.get(squad, FORMATION_OFFSETS[1])
	var indexed: Array = []
	for i: int in member_hp.size():
		var off: Vector2 = (unit_offsets[i] as Vector2) if i < unit_offsets.size() else Vector2.ZERO
		indexed.append({"i": i, "d2": off.length_squared()})
	indexed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["d2"] as float) > (b["d2"] as float))
	var out: Array[int] = []
	for entry: Variant in indexed:
		out.append((entry as Dictionary)["i"] as int)
	return out


func take_damage(amount: int, attacker: Node3D = null) -> void:
	if alive_count <= 0:
		return
	# Nanite regen out-of-combat gate (stats.nanite_regen_per_sec > 0).
	# Stamping on every incoming damage call keeps the regen suppressed
	# for NANITE_OUT_OF_COMBAT_SEC after the most recent hit, regardless
	# of whether members died from it.
	_last_damage_taken_msec = Time.get_ticks_msec()
	# Reset the fractional accumulator so a hit interrupts a heal that
	# was mid-accumulation instead of preserving it across the combat
	# window — feels weird otherwise (HP ticks up the instant you stop
	# being shot, even mid-fight, because the accum from 6 s ago was
	# already at 0.9 HP).
	_nanite_regen_accum = 0.0

	# Barrier Bloom (Phalanx Shield) and any future incoming-damage
	# aura applies BEFORE armor and member splitting -- the shield
	# is conceptually a flat-front damage absorber, so it scales the
	# incoming amount and lets the rest of the resolution stay
	# unchanged. Local var name avoids colliding with `combat` later
	# in the function (retaliation block).
	var _shield_combat: Node = get_node_or_null("CombatComponent")
	if _shield_combat and _shield_combat.has_method("get_damage_taken_mult"):
		var taken_mult: float = _shield_combat.call("get_damage_taken_mult")
		if taken_mult < 1.0:
			amount = int(round(float(amount) * taken_mult))
			if amount <= 0:
				return

	# Stealth break — taking damage forces the unit into the
	# "revealed" state for stealth_restore_time seconds. Per V3
	# stealth rules, FIRING does NOT break stealth (Specter can
	# fire from concealment); only being shot does.
	if stats and stats.is_stealth_capable:
		_stealth_damage_timer = stats.stealth_restore_time
		_set_stealth_revealed(true)

	# Player-only "we're under attack" alert. Channel-keyed by squad
	# instance id so the AlertManager's per-channel cooldown gates
	# the voiceline — a single squad taking sustained fire only
	# fires the alert once every ~8 seconds, not on every bullet.
	if owner_id == 0:
		var alert: Node = get_tree().current_scene.get_node_or_null("AlertManager") if get_tree() else null
		if alert and alert.has_method("emit_alert"):
			alert.emit_alert("Squad under fire", 1, global_position, "unit_attack:%d" % get_instance_id(), 8.0)

	var hp_before: int = get_total_hp()

	# Damage carries across members so alive_count tracks the HP fraction:
	# a 4-unit squad at 50% total HP shows 2 members alive. We apply
	# damage to OUTER members first (sorted by formation distance from
	# centre, descending), so a squad keeps coherency: the centre mech
	# survives while the wings get picked off. Without this the squad
	# disintegrates from a fixed iteration order regardless of layout.
	var member_order: Array[int] = _damage_priority_order()
	var remaining: int = amount
	for i: int in member_order:
		if remaining <= 0:
			break
		if member_hp[i] <= 0:
			continue
		var dealt: int = mini(member_hp[i], remaining)
		member_hp[i] -= dealt
		remaining -= dealt
		if member_hp[i] <= 0:
			alive_count -= 1
			_remove_member_visual(i)
			member_died.emit(i)
			if alive_count <= 0:
				# Show the final hit's damage before _die() frees the unit.
				_spawn_damage_number(hp_before)
				_die()
				return

	# Floating damage number — uses actual HP delta in case some damage was clamped.
	var dealt_total: int = hp_before - get_total_hp()
	if dealt_total > 0:
		_spawn_damage_number(dealt_total)

	_flash_timer = FLASH_DURATION
	_apply_damage_flash()
	_update_hp_bar()

	# FOW reveal-on-attack (Behavior B) — player units only.
	# When a player-owned unit takes damage from an enemy outside LOS:
	#   Non-stealth: briefly reveal the attacker + surrounding area.
	#   Stealth: reveal only the ground tile under them (terrain flash).
	if owner_id == 0 and attacker and is_instance_valid(attacker):
		var fow_node: Node = get_tree().current_scene.get_node_or_null("FogOfWar") if get_tree() else null
		if fow_node and fow_node.has_method("is_visible_world"):
			var atk_pos: Vector3 = (attacker as Node3D).global_position
			if not (fow_node.call("is_visible_world", atk_pos) as bool):
				# Determine stealth status of attacker.
				var atk_is_stealth: bool = false
				if "stealth_revealed" in attacker:
					var atk_revealed: bool = (attacker.get("stealth_revealed") as bool)
					var atk_stats_b: UnitStatResource = attacker.get("stats") as UnitStatResource if "stats" in attacker else null
					if atk_stats_b and atk_stats_b.is_stealth_capable and not atk_revealed:
						atk_is_stealth = true
				if atk_is_stealth:
					# Terrain flash only: 1.5u radius for 1 second.
					fow_node.call("reveal_area", atk_pos, 1.5, 1.0)
				else:
					# Full reveal: 4u radius for 3 seconds.
					fow_node.call("reveal_area", atk_pos, 4.0, 3.0)

	# Retaliate: if we have a combat component and aren't already engaged,
	# pick the attacker as our target so we shoot back.
	if attacker and is_instance_valid(attacker):
		var combat: Node = get_combat()
		if combat and combat.has_method("notify_attacked"):
			combat.notify_attacked(attacker)


func get_total_hp() -> int:
	var total: int = 0
	for hp: int in member_hp:
		total += hp
	return total


## Diminishing-returns bookkeeping for stacked repairs. Each healer
## that contributes within the same ~250ms window gets a smaller
## factor (1, 0.9, 0.8, ... floor 0.1) so 10 engineers wrenching on
## one wounded squad don't add up to 10x throughput.
var _healers_this_tick: Dictionary = {}
var _last_heal_tick_msec: int = 0
const _HEAL_TICK_MS: int = 250


func heal(amount: float, healer: Node = null) -> void:
	## Restore HP across surviving squad members up to per-member cap.
	## Used by Ratchet auto-repair. Heals members evenly; dead members
	## stay dead — repair doesn't resurrect. Multiple engineers
	## healing the same target in the same tick get diminishing
	## returns -- 100% / 90% / 80% / ... floored at 10%.
	if alive_count <= 0 or not stats:
		return
	# Diminishing-returns scaling on the input amount.
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_heal_tick_msec >= _HEAL_TICK_MS:
		_healers_this_tick.clear()
		_last_heal_tick_msec = now_ms
	if healer:
		var hid: int = healer.get_instance_id()
		if not _healers_this_tick.has(hid):
			var idx: int = _healers_this_tick.size()
			var factor: float = maxf(1.0 - float(idx) * 0.1, 0.1)
			amount *= factor
			_healers_this_tick[hid] = factor
		else:
			amount *= (_healers_this_tick[hid] as float)
	var per_member_cap: int = stats.hp_per_unit
	var remaining: int = int(ceil(amount))
	if remaining <= 0:
		return
	# Heal the most-damaged living member first so repair feels like it's
	# saving the wounded rather than topping up healthy ones.
	while remaining > 0:
		var lowest_idx: int = -1
		var lowest_hp: int = per_member_cap
		for i: int in member_hp.size():
			if member_hp[i] <= 0:
				continue
			if member_hp[i] < lowest_hp:
				lowest_hp = member_hp[i]
				lowest_idx = i
		if lowest_idx < 0:
			return  # All living members at full HP.
		var room: int = per_member_cap - member_hp[lowest_idx]
		var apply: int = mini(remaining, room)
		member_hp[lowest_idx] += apply
		remaining -= apply
		if apply <= 0:
			return


func is_damaged() -> bool:
	## True only when at least one LIVING squad member is below their
	## per-member max HP. A 4-Rook squad with 1 dead + 3 full-HP
	## survivors counts as not-damaged for repair purposes -- engineers
	## can heal HP but can't resurrect dead members, so flagging the
	## squad as damaged just put engineers on a job they couldn't do.
	if alive_count <= 0 or not stats:
		return false
	var per_max: int = stats.hp_per_unit
	for hp: int in member_hp:
		if hp > 0 and hp < per_max:
			return true
	return false


func _die() -> void:
	squad_destroyed.emit()
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()

	# Carrier death — eject any garrisoned passengers in a small
	# ring around the wreck position. Better the player keeps the
	# infantry / engineers than them silently disappearing with
	# the tank.
	if not _garrison_passengers.is_empty():
		var n: int = _garrison_passengers.size()
		for i: int in n:
			var ally: Unit = _garrison_passengers[i]
			if not is_instance_valid(ally):
				continue
			var angle: float = TAU * float(i) / float(maxi(n, 1))
			ally.global_position = global_position + Vector3(cos(angle) * 3.0, 0.0, sin(angle) * 3.0)
			ally._garrisoned_in = null
			ally.visible = true
			# Carrier-died disembark also restores collision so the
			# survivors don't end up phasing through everything.
			var prev_layer: int = ally.get_meta("garrison_prev_collision_layer", 2) as int
			var prev_mask: int = ally.get_meta("garrison_prev_collision_mask", 5) as int
			ally.collision_layer = prev_layer
			ally.collision_mask = prev_mask
			ally.remove_meta("garrison_prev_collision_layer")
			ally.remove_meta("garrison_prev_collision_mask")
		_garrison_passengers.clear()

	_spawn_squad_death_explosion()
	_request_camera_shake(0.35)

	# Death detonation passive (Matador Martyr branch). When the squad
	# is fully wiped, deal AS-flavoured AoE damage to all hostile
	# entities in stats.death_detonation_radius. Uses the unit's
	# armor_class to map a sensible role mult: anti-structure damage
	# bites unarmored / light hardest, with structures taking a chip.
	# Reuses ParticleEmitterManager flash + smoke for VFX so the AoE
	# reads visually distinct from the regular squad-death cluster
	# fx.
	if stats and "death_detonation_radius" in stats and "death_detonation_damage" in stats:
		var det_radius: float = stats.death_detonation_radius
		var det_damage: int = stats.death_detonation_damage
		if det_radius > 0.0 and det_damage > 0:
			_apply_death_detonation(det_radius, det_damage)

	var wreck: Node = Wreck.create_from_unit(stats, global_position)
	get_tree().current_scene.add_child(wreck)

	if owner_id == 0:
		var resource_mgr: Node = get_tree().current_scene.get_node_or_null("ResourceManager")
		if resource_mgr and resource_mgr.has_method("remove_population"):
			resource_mgr.remove_population(stats.population)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_unit_destroyed"):
		# Heavy mechs (Bulwark, Harbinger, etc.) trigger the larger
		# explosion bank so a Bulwark squad's death reads weightier
		# than a Hound's. unit_class string is checked rather than
		# armor since some lights have heavy armor (e.g., Hound
		# variants) but their squad death should still feel light.
		var heavy: bool = stats != null and (stats.unit_class == &"heavy" or stats.unit_class == &"apex")
		audio.play_unit_destroyed(global_position, heavy)

	queue_free()


func _apply_death_detonation(radius: float, base_dmg: int) -> void:
	## Matador Martyr death-AoE. Applies AS-flavour role mult vs each
	## target's armor class via CombatTables so the same 50 dmg cluster
	## bites unarmored for full damage but only chips heavies — keeps
	## the Martyr's role as "anti-light skirmisher with kamikaze
	## finisher" instead of a heavy-tank counter.
	var det_pos: Vector3 = global_position
	var shooter_owner: int = owner_id
	var scene: Node = get_tree().current_scene if get_tree() else null
	var idx: SpatialIndex = SpatialIndex.get_instance(scene) if scene else null
	var candidates: Array = idx.nearby(det_pos, radius) if idx else []
	for raw: Variant in candidates:
		if raw == null or not is_instance_valid(raw):
			continue
		var ent: Node = raw as Node
		if ent == null or ent == self:
			continue
		if not ent.has_method("take_damage"):
			continue
		var ent_owner: int = (ent.get("owner_id") as int) if "owner_id" in ent else 0
		if ent_owner == shooter_owner:
			continue
		if "alive_count" in ent and (ent.get("alive_count") as int) <= 0:
			continue
		var t_armor: StringName = &"unarmored"
		if "stats" in ent:
			var ts: Resource = ent.get("stats")
			if ts and "armor_class" in ts:
				t_armor = ts.get("armor_class") as StringName
		var role_mult: float = CombatTables.get_role_modifier(&"AS", t_armor)
		var armored_dmg: int = maxi(int(float(base_dmg) * role_mult), 1)
		(ent as Node).call("take_damage", armored_dmg, self)
	# Explosion VFX — mirrors _kamikaze_detonate (CombatComponent).
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager") if scene else null
	if pem and pem.has_method("emit_flash"):
		pem.emit_flash(det_pos, Color(1.0, 0.6, 0.1, 1.0))
	if pem and pem.has_method("emit_smoke"):
		pem.emit_smoke(det_pos, Vector3(0.0, 1.5, 0.0), Color(0.3, 0.2, 0.15, 0.8))


func _apply_damage_flash() -> void:
	# Boost emission on each member's existing materials. Ongoing animations
	# (leg swing, recoil) are preserved because we don't rebuild any nodes.
	for i: int in _member_data.size():
		if i < member_hp.size() and member_hp[i] <= 0:
			continue
		var data: Dictionary = _member_data[i]
		var member: Node3D = data["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		var mats: Array = data["mats"] as Array
		for m: StandardMaterial3D in mats:
			if not m:
				continue
			m.emission_enabled = true
			m.emission = Color(1.0, 0.1, 0.0, 1.0)
			m.emission_energy_multiplier = 2.5


func _restore_member_colors() -> void:
	# Restore the per-material emission settings without rebuilding the meshes,
	# so leg-swing and recoil state stay intact and dead members stay hidden.
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var mats: Array = data["mats"] as Array
		for m: StandardMaterial3D in mats:
			if not m:
				continue
			# Most metal mats are non-emissive; team stripe / visor / antenna tip
			# carry their own emission set at build time. The flash only changed
			# emission, so resetting it here clears the red without losing color.
			m.emission_enabled = _is_emissive_color(m.albedo_color)
			if m.emission_enabled:
				m.emission = m.albedo_color
				m.emission_energy_multiplier = 1.4
			else:
				m.emission = Color(0, 0, 0, 1)
				m.emission_energy_multiplier = 0.0


func _is_emissive_color(c: Color) -> bool:
	# Heuristic: the only emissive surfaces we build are bright team color, the
	# blue visor, and the red antenna tip. Plain metal greys/browns aren't.
	var lum: float = (c.r + c.g + c.b) / 3.0
	# High saturation OR very bright primary → emissive.
	var max_c: float = maxf(c.r, maxf(c.g, c.b))
	var min_c: float = minf(c.r, minf(c.g, c.b))
	return (max_c - min_c) > 0.3 and lum > 0.25


## --- Selection ---

func select() -> void:
	if is_selected:
		return
	is_selected = true
	selected.emit()
	_update_selection_visual(true)


func deselect() -> void:
	if not is_selected:
		return
	is_selected = false
	deselected.emit()
	_update_selection_visual(false)


func _update_selection_visual(show: bool) -> void:
	var ring: Node3D = get_node_or_null("SelectionRing") as Node3D
	if ring:
		ring.visible = show


## --- Component Accessors ---

func get_builder() -> Node:
	return get_node_or_null("BuilderComponent")


func get_combat() -> Node:
	# Cached in _ready. Re-resolve only if the cache went stale (combat
	# component freed mid-match for some reason); otherwise the per-tick
	# `get_node_or_null` lookup that was here used to be one of the
	# bigger contributors to idle-unit `_physics_process` cost.
	if _combat_cached and is_instance_valid(_combat_cached):
		return _combat_cached
	_combat_cached = get_node_or_null("CombatComponent")
	return _combat_cached


func get_member_positions() -> Array[Vector3]:
	# Return chest-height positions so projectiles and muzzle flashes spawn at
	# the cannons rather than at the feet.
	var positions: Array[Vector3] = []
	var chest_offset: float = 0.0
	if stats:
		var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
		var hip_y: float = shape["hip_y"] as float
		var torso_size: Vector3 = shape["torso"] as Vector3
		chest_offset = hip_y + torso_size.y * 0.7
	for i: int in _member_meshes.size():
		var member: Node3D = _member_meshes[i]
		if is_instance_valid(member) and member.visible:
			positions.append(member.global_position + Vector3(0, chest_offset, 0))
	return positions


func get_muzzle_positions_for_weapon(weapon: WeaponResource) -> Array[Vector3]:
	## Per-weapon muzzle override. Most units fire every weapon from
	## the same cannons array (returned by get_muzzle_positions), but
	## a few apex units mount different weapons on different parts of
	## the chassis. Sol Invictus is the canonical case: the Solar
	## Lance beam fires from the head-mounted lens, while the Body
	## Plasma Turrets fire from the wrist pods. Returns an empty array
	## when the default behaviour is acceptable so combat falls back
	## to get_muzzle_positions.
	if weapon == null:
		return [] as Array[Vector3]
	if stats == null:
		return [] as Array[Vector3]
	# Sol Invictus per-weapon muzzles.
	if stats.unit_name.findn("Sol Invictus") >= 0:
		var positions: Array[Vector3] = []
		# Solar Lance → head muzzle marker. Body Plasma Turrets →
		# generic cannons list (which IS the arm pivots for this build).
		if weapon.weapon_name == "Solar Lance":
			for i: int in _member_data.size():
				if i >= member_hp.size() or member_hp[i] <= 0:
					continue
				var data: Dictionary = _member_data[i]
				var member: Node3D = data["root"]
				if not is_instance_valid(member):
					continue
				var marker: Node3D = member.get_node_or_null("SolarLanceMuzzle") as Node3D
				if is_instance_valid(marker):
					positions.append(marker.global_position)
			return positions
		# Plasma turrets — fall through to the default arm-cannon path.
	# Flame weapons — spawn the projectile from the actual flamethrower
	# nozzle on each member instead of the chassis centre. Walks the
	# member subtree for a Marker3D named "FlamerMuzzle"; falls back to
	# the default cannons list when a member doesn't carry one (e.g.
	# units that mount a flame weapon in data but lack a dedicated mesh
	# nozzle, like Inquisitor Tank's auxiliary flamer).
	var ws: String = String(weapon.projectile_style) if "projectile_style" in weapon else ""
	if ws == "flame":
		var fpositions: Array[Vector3] = []
		for i: int in _member_data.size():
			if i >= member_hp.size() or member_hp[i] <= 0:
				continue
			var data: Dictionary = _member_data[i]
			var member: Node3D = data["root"]
			if not is_instance_valid(member):
				continue
			var marker: Node3D = _find_marker_named(member, "FlamerMuzzle")
			if is_instance_valid(marker):
				fpositions.append(marker.global_position)
		if not fpositions.is_empty():
			return fpositions
		# Fall through to default for units without a FlamerMuzzle node.
	return [] as Array[Vector3]


func _find_marker_named(root: Node, marker_name: StringName) -> Node3D:
	## Depth-first search for a child Marker3D / Node3D with the given
	## name under `root`. Returns null when nothing matches. Used by
	## get_muzzle_positions_for_weapon to locate weapon-specific muzzle
	## markers that aren't direct children of the member root (e.g.
	## the Cremator's FlamerMuzzle is nested inside CremnatorFlamer →
	## torso_pivot → member).
	if not is_instance_valid(root):
		return null
	for child in root.get_children():
		if child.name == marker_name and child is Node3D:
			return child as Node3D
		var nested: Node3D = _find_marker_named(child, marker_name)
		if nested != null:
			return nested
	return null


func get_muzzle_positions() -> Array[Vector3]:
	## World-space barrel-tip positions, one per alive squad member's primary
	## cannon. Used by combat to spawn projectiles and muzzle flashes at the
	## actual gun mouth instead of the unit's chest. Falls back to
	## get_member_positions for members that lack a cannon.
	var positions: Array[Vector3] = []
	for i: int in _member_data.size():
		if i >= member_hp.size() or member_hp[i] <= 0:
			continue
		var data: Dictionary = _member_data[i]
		var member: Node3D = data["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		var cannons: Array = data["cannons"] as Array
		var muzzle_zs: Array = data.get("cannon_muzzle_z", []) as Array
		if cannons.is_empty():
			# No cannons (e.g., engineer's claw isn't tracked here) — fall back
			# to a chest-forward point so projectiles still leave the body.
			var chest: Vector3 = member.global_position + Vector3(0, _mech_total_height() * 0.55, 0)
			var forward: Vector3 = -global_basis.z.normalized()
			positions.append(chest + forward * 0.4)
			continue
		# Return EVERY cannon's barrel tip. Combat cycles shots
		# through these via `i % muzzle_positions.size()` so a
		# multi-barrel weapon (Bulwark triple cannon, Breacher twin
		# cannon) sprays each barrel in turn instead of stacking
		# every projectile on one muzzle.
		for ci: int in cannons.size():
			var pivot: Node3D = cannons[ci]
			if not is_instance_valid(pivot):
				continue
			var muzzle_z: float = 0.5
			if ci < muzzle_zs.size():
				muzzle_z = muzzle_zs[ci] as float
			elif muzzle_zs.size() > 0:
				muzzle_z = muzzle_zs[0] as float
			positions.append(pivot.global_transform * Vector3(0, 0, -muzzle_z))
	return positions


## --- Faction-aware visual identity (V3 §"Pillar 1") ----------------------

## --- V3 Mesh aura visual --------------------------------------------------

func _add_mesh_aura_ring(radius: float) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "MeshAuraRing"
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.18
	torus.outer_radius = radius
	torus.rings = 36
	torus.ring_segments = 4
	ring.mesh = torus
	ring.position.y = 0.05
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.45, 1.0, 0.50)
	mat.emission_enabled = true
	mat.emission = Color(0.78, 0.45, 1.0, 1.0)
	mat.emission_energy_multiplier = 0.85
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, mat)
	add_child(ring)


## --- V3 Stealth -----------------------------------------------------------

func _tick_stealth() -> void:
	## Reveal logic: walk the units group, find the closest enemy, and
	## flip stealth_revealed based on whether anyone is inside our
	## detection bubble. The damage-break timer keeps us revealed for
	## stealth_restore_time seconds after the last hit regardless of
	## proximity.
	if _stealth_damage_timer > 0.0:
		if not stealth_revealed:
			_set_stealth_revealed(true)
		return
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	var detect_r2: float = stats.detection_radius * stats.detection_radius
	var spotted: bool = false
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node) or node == self:
			continue
		if not ("alive_count" in node) or (node.get("alive_count") as int) <= 0:
			continue
		var other_owner: int = node.get("owner_id") as int
		# Allies don't reveal us. Use the registry's are_allied check
		# so 2v2 teammates count as allies.
		if registry:
			if registry.are_allied(owner_id, other_owner):
				continue
		else:
			if other_owner == owner_id:
				continue
		# Each unit's OWN detection_radius defines how far IT can see
		# stealth. Most combat units = 6 (close-range), engineers = 100,
		# Spotter Rook = 200, Glitch / Sensor Carrier = 150.
		var their_r: float = 6.0
		if "stats" in node:
			var their_stats: UnitStatResource = node.get("stats") as UnitStatResource
			if their_stats:
				their_r = their_stats.detection_radius
		var their_r2: float = their_r * their_r
		var dx: float = (node as Node3D).global_position.x - global_position.x
		var dz: float = (node as Node3D).global_position.z - global_position.z
		var d2: float = dx * dx + dz * dz
		# Reveal only by enemy detection. (Previously also OR'd against
		# `detect_r2` — the stealth unit's OWN detection_radius — which
		# made a Specter's 80u radius reveal itself. The stealth unit's
		# own sensors shouldn't betray it.)
		if d2 <= their_r2:
			spotted = true
			break
	if spotted != stealth_revealed:
		_set_stealth_revealed(spotted)


func _set_stealth_revealed(revealed: bool) -> void:
	stealth_revealed = revealed
	_apply_stealth_visual(not revealed)


func _apply_stealth_visual(concealed: bool) -> void:
	## Fades the squad members so concealed stealth units read as a clear
	## ghosty silhouette. GeometryInstance3D.transparency (the previous
	## approach) was dithered and not always obvious; modifying the
	## StandardMaterial3D alpha + transparency_mode gives a proper
	## alpha-blended fade that's visible at any distance. Materials are
	## per-unit (created fresh in the build functions) so toggling them
	## here doesn't bleed across squads.
	##
	## When concealed we also cache the affected StandardMaterial3D refs
	## into `_stealth_pulse_mats` so the per-physics-frame pulse loop can
	## oscillate alpha without re-walking the mesh tree.
	var alpha: float = STEALTH_PULSE_BASE if concealed else 1.0
	var mode: int = (
		StandardMaterial3D.TRANSPARENCY_ALPHA
		if concealed
		else StandardMaterial3D.TRANSPARENCY_DISABLED
	)
	_stealth_pulse_mats.clear()
	for member: Node3D in _member_meshes:
		if not is_instance_valid(member):
			continue
		_apply_transparency_recursive(member, alpha, mode)
	if not concealed:
		_stealth_pulse_phase = 0.0


func _apply_transparency_recursive(node: Node, alpha: float, mode: int) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var override: Material = mi.material_override
		if override is StandardMaterial3D:
			var om: StandardMaterial3D = override as StandardMaterial3D
			_set_mat_alpha(om, alpha, mode)
			if mode == StandardMaterial3D.TRANSPARENCY_ALPHA:
				_stealth_pulse_mats.append(om)
		var surf_count: int = mi.get_surface_override_material_count()
		for s_idx: int in surf_count:
			var sm: Material = mi.get_surface_override_material(s_idx)
			if sm is StandardMaterial3D:
				var ssm: StandardMaterial3D = sm as StandardMaterial3D
				_set_mat_alpha(ssm, alpha, mode)
				if mode == StandardMaterial3D.TRANSPARENCY_ALPHA:
					_stealth_pulse_mats.append(ssm)
	for child: Node in node.get_children():
		_apply_transparency_recursive(child, alpha, mode)


func _set_mat_alpha(mat: StandardMaterial3D, alpha: float, mode: int) -> void:
	var c: Color = mat.albedo_color
	c.a = alpha
	mat.albedo_color = c
	mat.transparency = mode


func _faction_id() -> int:
	# Resolve the unit's faction by routing the owner_id through the
	# match's MatchSettings. owner 0 = local player → player_faction;
	# any non-self owner → enemy_faction. Neutral patrols (owner 2) get
	# a deterministic fallback so cosmetic tinting stays stable.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if not settings:
		return 0  # default Anvil
	if owner_id == 0:
		return settings.get("player_faction") as int
	# Neutral patrols read whichever faction the local player picked AS
	# enemy — this keeps neutrals visually distinct from the player.
	if owner_id == 2:
		return settings.get("enemy_faction") as int
	return settings.get("enemy_faction") as int


func _faction_tint_chassis(c: Color) -> Color:
	# Anvil keeps the v1 grey-tan palette unchanged. Sable shifts the
	# chassis darker + cooler — matte black with anthracite undertones,
	# matching `03_factions.md` §"Sable Network → Aesthetic". Hue shift
	# is a multiplicative remap so the per-class brightness contrast
	# (heavies darker than lights) survives the re-tint.
	#
	# Neutral mechs (rogue salvagers / deserter patrols, owner_id 2)
	# bypass the faction palette entirely and get a desaturated rust /
	# grime treatment so they read as scrap-cobbled rather than mistaken
	# for a player or enemy unit.
	if owner_id == 2:
		return _scrappy_neutral_tint(c)
	var fid: int = _faction_id()
	if fid == 0:  # Anvil/Combine → unchanged
		return c
	var class_id: StringName = stats.unit_class if stats else &"medium"
	var palette: Vector3
	if fid == 2:
		# Inheritor: pale concrete-grey base with patinated-bronze warmer
		# undertone for heavies and a faint violet-cool wash on apex.
		# Per 03_factions §4.4: "pale concrete-grey ... patinated bronze
		# and verdigris-green on salvaged components ... subtle
		# violet-white as the indicator".
		match class_id:
			&"engineer": palette = Vector3(0.62, 0.58, 0.50)  # bronze-warm grey (Restorer)
			&"light":    palette = Vector3(0.66, 0.66, 0.62)  # pale concrete
			&"heavy":    palette = Vector3(0.54, 0.50, 0.42)  # weathered bronze undertone
			&"apex":     palette = Vector3(0.50, 0.46, 0.54)  # cool concrete + violet hint
			_:           palette = Vector3(0.60, 0.58, 0.52)  # medium baseline
		var avg_i: float = (c.r + c.g + c.b) / 3.0
		var bias_i: float = clampf(avg_i * 0.18, 0.0, 0.06)
		return Color(
			clampf(palette.x + bias_i, 0.0, 1.0),
			clampf(palette.y + bias_i, 0.0, 1.0),
			clampf(palette.z + bias_i, 0.0, 1.0),
			c.a,
		)
	if fid == 3:
		# Heliarch: sooted iron-grey, scorched darker. Per 03_factions §3.4:
		# "sooted iron grey as the base chassis color, scorched darker
		# around exhaust ports". Reactor amber glow is added as separate
		# emissive accent (not via chassis tint).
		match class_id:
			&"engineer": palette = Vector3(0.26, 0.22, 0.20)  # warm sooted iron
			&"light":    palette = Vector3(0.24, 0.22, 0.21)  # dark iron-grey
			&"heavy":    palette = Vector3(0.20, 0.18, 0.17)  # scorched iron
			&"apex":     palette = Vector3(0.18, 0.15, 0.14)  # near-black scorched
			_:           palette = Vector3(0.22, 0.20, 0.18)
		var avg_h: float = (c.r + c.g + c.b) / 3.0
		var bias_h: float = clampf(avg_h * 0.22, 0.0, 0.06)
		return Color(
			clampf(palette.x + bias_h, 0.0, 1.0),
			clampf(palette.y + bias_h, 0.0, 1.0),
			clampf(palette.z + bias_h, 0.0, 1.0),
			c.a,
		)
	# Meridian (fid == 1) per-class palette. The Combine unit base colors
	# all collapsed to a single near-black after the desaturate pass,
	# making a Meridian squad of Field Technicians look identical to a
	# squad of Specters. Shift the tone per class so squads can be told
	# apart at a glance:
	#   engineer = warm graphite (slight bronze undercoat)
	#   light    = blued steel (cool, slightly brighter)
	#   medium   = anthracite (the canonical "Sable" matte black)
	#   heavy    = gunmetal (heavy and slightly green-tinted)
	#   apex     = obsidian violet (darkest + violet wash)
	match class_id:
		&"engineer": palette = Vector3(0.18, 0.16, 0.14)
		&"light":    palette = Vector3(0.16, 0.20, 0.26)
		&"heavy":    palette = Vector3(0.13, 0.16, 0.16)
		&"apex":     palette = Vector3(0.13, 0.10, 0.16)
		_:           palette = Vector3(0.14, 0.15, 0.18)
	# Preserve a hint of the original brightness so per-class shape
	# materials still differ slightly within a unit. Most of the colour
	# contrast comes from the palette; only ~10% comes from the input.
	var avg: float = (c.r + c.g + c.b) / 3.0
	var bias: float = clampf(avg * 0.20, 0.0, 0.06)
	return Color(
		clampf(palette.x + bias, 0.0, 1.0),
		clampf(palette.y + bias, 0.0, 1.0),
		clampf(palette.z + bias, 0.0, 1.0),
		c.a,
	)


func _scrappy_neutral_tint(c: Color) -> Color:
	## Rogue / deserter salvager look — desaturate hard, push toward a
	## warm rust palette, dim overall brightness so the unit reads as
	## "patched together from scrap" rather than a polished faction
	## chassis. Per-instance jitter (seeded by a hash of the position so
	## it stays stable per unit between frames) varies the rust amount
	## across a squad so they don't all look identical.
	var avg: float = (c.r + c.g + c.b) / 3.0
	var grey: Color = Color(avg, avg, avg, c.a)
	# Mix toward a rust hue (~ Color(0.42, 0.24, 0.16)). Then darken so
	# neutrals never read brighter than a player chassis.
	var rust: Color = Color(0.42, 0.24, 0.16, c.a)
	var jitter: int = int(global_position.x * 13.0 + global_position.z * 7.0) & 0xff
	var rust_mix: float = 0.55 + float(jitter) / 255.0 * 0.20  # 0.55..0.75
	var mixed: Color = grey.lerp(rust, rust_mix)
	mixed.r *= 0.78
	mixed.g *= 0.74
	mixed.b *= 0.72
	mixed.a = c.a
	return mixed


## Maximum range across this unit's weapons that hit ground.
## Returns 0.0 if the unit has no AG weapons (combine with
## is_aa_only() to test).
func get_ag_range() -> float:
	var best: float = 0.0
	if stats == null:
		return 0.0
	for w: WeaponResource in [stats.primary_weapon, stats.secondary_weapon]:
		if w == null:
			continue
		if w.hits_ground:
			best = maxf(best, w.resolved_range())
	return best


## True if the unit has at least one AA weapon AND no AG weapons.
## Squads identified as AA-only are slotted in the formation's
## middle (where they are protected and where their cover matters
## most).
func is_aa_only() -> bool:
	if stats == null:
		return false
	var has_ag: bool = false
	var has_aa: bool = false
	for w: WeaponResource in [stats.primary_weapon, stats.secondary_weapon]:
		if w == null:
			continue
		if w.hits_ground:
			has_ag = true
		if w.engages_air():
			has_aa = true
	return has_aa and not has_ag


## Heavier armor → larger value. Used as a tiebreaker in
## range-rank sort (heavier in front for equal AG range).
func get_armor_weight() -> float:
	if stats == null:
		return 0.0
	match stats.armor_class:
		&"unarmored": return 1.0
		&"light":     return 2.0
		&"medium":    return 3.0
		&"heavy":     return 4.0
		&"apex":      return 5.0
		&"structure": return 6.0
		_:            return 0.0
