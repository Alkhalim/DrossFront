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

## Accumulator for healing overflow — used by Factory Pulse to
## convert "wasted" heal (everyone already at full HP) into
## restored squad members. Once this passes hp_per_unit, one
## dead member comes back with full HP. Persists across casts so
## a partial top-up adds to the next.
var _heal_overflow_accum: int = 0

## Courier Tank passenger list — populated when this unit casts
## Garrison and emptied on the second press (disembark). Each entry
## is the passenger Unit. Empty when the tank isn't carrying anyone
## or when this unit isn't a transport at all.
var _garrison_passengers: Array[Unit] = []

## Courier Tank track ribs — flat list of MeshInstance3D nodes
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
		# Courier Tank — tracked transport, custom mesh built via
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
		"formation_spacing": 3.5,
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
	# Random offset so idle-animation work is staggered across units.
	_idle_anim_throttle = randi() % IDLE_ANIM_THROTTLE_FRAMES
	_bob_raycast_throttle = randi() % BOB_RAYCAST_THROTTLE_FRAMES
	# Round-robin physics work across THREE-frame slots (~20Hz per unit
	# instead of 60Hz). At 360+ active units, even a 30Hz half-frame
	# stagger blew the frame budget on `Unit._physics_process` — bumping
	# to a 1-in-3 cadence drops the per-frame batch from 180 units to
	# 120 with no visible quality loss for movement / animation.
	_walk_bob_phase = int(get_instance_id() % 3)
	# Navigation agent for pathfinding
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

		# The Courier Tank is the FACTION transport for Sable, so the
		# speed gap "on foot vs in the tank" needs to live on Sable's
		# side of the roster. Sable infantry / engineers eat a small
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

		# Transports (Courier Tank) get a small speed bump on top of
		# their tier so the embark loop reads as a real upgrade over
		# walking. Applies regardless of faction since "transport" is
		# a unit-class concept, but in practice only Sable ships one
		# right now.
		if stats.unit_class == &"transport":
			_move_speed *= 1.10
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
		# X-ray silhouette disabled -- the depth-texture sample in
		# the previous shader was returning the near-plane value
		# in Forward+, causing the silhouette to draw EVERYWHERE
		# instead of only when occluded. Plain white capsules
		# overlaid every unit. Reverted while a more reliable
		# behind-buildings outline approach is designed (next_pass
		# duplicate via the Building's transparent layer is the
		# probable replacement).

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
	var member_radius: float = maxf(torso_size.x, torso_size.z) * 0.6 + 0.25
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
		bay.position = Vector3(0.0, total_h + 0.3, -torso_size.z * 0.5)
		add_child(bay)


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
	# Transport class doesn't have legs / torso / cockpit — bail out
	# of the standard mech build and call the dedicated tracked-vehicle
	# builder instead. Returns the same dictionary shape so the caller's
	# squad-visuals bookkeeping keeps working.
	if stats and stats.unit_class == &"transport":
		# Per-name dispatch within transport class so different
		# tracked vehicles get distinct silhouettes. Breacher Tank
		# uses a casemate (no-turret) tank-destroyer build that
		# diverges from the Sable Courier Tank's turreted
		# transport silhouette; defaults route to Courier Tank.
		if stats.unit_name.findn("Breacher") >= 0:
			# Branch variants get distinct silhouettes -- Mortar
			# is an open-topped artillery vehicle, Salvo carries
			# vertical missile pods. Both lose the casemate +
			# main cannon of the base Breacher.
			if stats.unit_name.findn("Mortar") >= 0:
				return _build_breacher_mortar_member(index, offset, team_color)
			if stats.unit_name.findn("Salvo") >= 0:
				return _build_breacher_salvo_member(index, offset, team_color)
			return _build_breacher_tank_member(index, offset, team_color)
		if stats.unit_name.findn("Grinder") >= 0:
			return _build_grinder_tank_member(index, offset, team_color)
		return _build_courier_tank_member(index, offset, team_color)
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

	# Faction identity strip on the chest. Anvil ships a horizontal warm
	# brass band; Sable replaces it with a single small glow point —
	# the previous horizontal-line-plus-vertical-kicker formed an
	# L-shape that read as a chunk of dominant violet across the
	# already-narrow Sable prow. A simple core-glow with a low-energy
	# light reads as Sable identity without taking over the silhouette.
	if _faction_id() == 1:
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
		# Tiny coloured light so the glow has bloom/spread on the
		# surrounding chassis without painting a visible band.
		var glow_light := OmniLight3D.new()
		glow_light.light_color = SABLE_NEON
		glow_light.light_energy = 0.55
		glow_light.omni_range = torso_size.x * 1.4
		glow_light.position = glow.position
		torso_pivot.add_child(glow_light)
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
		# tip that matches the rest of the faction's emissive accent —
		# the previous warm-red tip clashed with the violet hull seams
		# (red + purple living next to each other read as a colour bug,
		# not a faction palette). Anvil keeps the warm red.
		var is_sable: bool = _faction_id() == 1
		var sable_lift: float = 0.20 if is_sable else 0.0
		var ant_h_actual: float = antenna_h + sable_lift
		var antenna := MeshInstance3D.new()
		var ant_box := BoxMesh.new()
		ant_box.size = Vector3(0.04, ant_h_actual, 0.04)
		antenna.mesh = ant_box
		antenna.position = Vector3(
			head_size.x * 0.3,
			torso_size.y + head_size.y + ant_h_actual / 2.0,
			head_fwd_offset,
		)
		var ant_mat := _make_metal_mat(Color(0.15, 0.15, 0.18))
		antenna.set_surface_override_material(0, ant_mat)
		torso_pivot.add_child(antenna)
		mats.append(ant_mat)

		var tip := MeshInstance3D.new()
		var tip_sph := SphereMesh.new()
		tip_sph.radius = 0.05
		tip_sph.height = 0.1
		tip.mesh = tip_sph
		tip.position = Vector3(
			head_size.x * 0.3,
			torso_size.y + head_size.y + ant_h_actual,
			head_fwd_offset,
		)
		var tip_mat := StandardMaterial3D.new()
		var tip_color: Color = SABLE_NEON if is_sable else Color(1.0, 0.3, 0.2)
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
			"Specter (Ghost)":
				_apply_specter_ghost_overlay(torso_pivot, torso_size, mats)
			"Specter (Glitch)":
				_apply_specter_glitch_overlay(torso_pivot, torso_size, mats)
			"Jackal (Striker)":
				_apply_jackal_striker_overlay(torso_pivot, torso_size, mats)
			"Jackal (Widow)":
				_apply_jackal_widow_overlay(torso_pivot, torso_size, mats)
			"Forgemaster (Foreman)":
				_apply_forgemaster_foreman_extras(torso_pivot, torso_size, mats)
			"Forgemaster (Reactor)":
				_apply_forgemaster_reactor_extras(torso_pivot, torso_size, mats)
			"Harbinger (Overseer)":
				_apply_harbinger_overseer_overlay(torso_pivot, torso_size, mats)
			"Harbinger (Swarm Marshal)":
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
	## of 'standard heavy mech'. Three changes layer:
	##   - +10% chassis scale so the silhouette towers over Hounds.
	##   - Slight forward lean (~4deg pitch) so the chassis reads
	##     as advancing under its own weight.
	##   - Per-member walk-feel override: slower stride, deeper
	##     bob, narrower swing arc -- the parade gait gets replaced
	##     with a heavy stomp. Idle weight-shift slows too.
	_apply_special_chassis_scale(member, 1.10)
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
	## Sable Courier Tank — tracked transport with a twin-MG turret.
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
	# tracked tanks share the same Sable-violet seam read. Sable
	# Courier Tank keeps its violet identity.
	var is_breacher: bool = stats != null and stats.unit_name.findn("Breacher") >= 0
	var sable_violet: Color = Color(1.00, 0.55, 0.18) if is_breacher else Color(0.78, 0.42, 1.0)

	# --- Tracks (two side rails). Long flat boxes flanking the hull.
	var track_len: float = 2.85
	var track_h: float = 0.42
	var track_w: float = 0.42
	for side: int in 2:
		var sx: float = -1.05 if side == 0 else 1.05
		var track := MeshInstance3D.new()
		var track_box := BoxMesh.new()
		track_box.size = Vector3(track_w, track_h, track_len)
		track.mesh = track_box
		track.position = Vector3(sx, track_h * 0.5, 0.0)
		var track_mat := _make_metal_mat(Color(0.10, 0.10, 0.12))
		track.set_surface_override_material(0, track_mat)
		member.add_child(track)
		mats.append(track_mat)
		# Six visible track ribs across the top of each tread —
		# horizontal striping that reads as actual moving track at
		# distance. Each rib is registered with the unit's
		# _courier_track_ribs list so _process can scroll it
		# proportionally to ground speed (wraps around at the
		# track ends).
		for r_i: int in 6:
			var rib := MeshInstance3D.new()
			var rib_box := BoxMesh.new()
			rib_box.size = Vector3(track_w + 0.06, 0.06, 0.18)
			rib.mesh = rib_box
			var rt: float = (float(r_i) + 0.5) / 6.0
			rib.position = Vector3(sx, track_h, -track_len * 0.5 + rt * track_len)
			var rib_mat := _make_metal_mat(Color(0.06, 0.06, 0.06))
			rib.set_surface_override_material(0, rib_mat)
			member.add_child(rib)
			mats.append(rib_mat)
			_courier_track_ribs.append({"node": rib, "length": track_len})
		# Drive sprocket up front, idler at rear — small low-radial
		# cylinders so the polygon edges read as gear teeth.
		for end_i: int in 2:
			var ez: float = -track_len * 0.5 + 0.1 if end_i == 0 else track_len * 0.5 - 0.1
			var wheel := MeshInstance3D.new()
			var wheel_cyl := CylinderMesh.new()
			wheel_cyl.top_radius = track_h * 0.55
			wheel_cyl.bottom_radius = track_h * 0.55
			wheel_cyl.height = track_w * 0.7
			wheel_cyl.radial_segments = 10 if end_i == 0 else 14
			wheel.mesh = wheel_cyl
			wheel.rotate_object_local(Vector3.FORWARD, PI * 0.5)
			wheel.position = Vector3(sx, track_h * 0.5, ez)
			var wheel_mat := _make_metal_mat(Color(0.15, 0.15, 0.16))
			wheel.set_surface_override_material(0, wheel_mat)
			member.add_child(wheel)
			mats.append(wheel_mat)

	# --- Hull. Low rectangular chassis sitting between the tracks.
	var hull_w: float = 1.8
	var hull_h: float = 0.55
	var hull_len: float = 2.4
	var hull_y: float = track_h + hull_h * 0.5
	var hull := MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(hull_w, hull_h, hull_len)
	hull.mesh = hull_box
	hull.position = Vector3(0.0, hull_y, 0.0)
	var hull_mat := _make_metal_mat(sable_mid)
	hull.set_surface_override_material(0, hull_mat)
	member.add_child(hull)
	mats.append(hull_mat)

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

	# Team-color stripe along the spine — small emissive band so
	# allegiance reads from above.
	var stripe := MeshInstance3D.new()
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(0.45, 0.06, hull_len * 0.7)
	stripe.mesh = stripe_box
	stripe.position = Vector3(0.0, hull_y + hull_h * 0.5 + 0.02, 0.18)
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

	# --- Turret on top — short angled drum with a small ring base.
	var turret_y: float = hull_y + hull_h * 0.5
	var turret_ring := MeshInstance3D.new()
	var ring_cyl := CylinderMesh.new()
	ring_cyl.top_radius = 0.50
	ring_cyl.bottom_radius = 0.55
	ring_cyl.height = 0.10
	ring_cyl.radial_segments = 16
	turret_ring.mesh = ring_cyl
	turret_ring.position = Vector3(0.0, turret_y + 0.05, -0.10)
	var ring_mat := _make_metal_mat(sable_dark)
	turret_ring.set_surface_override_material(0, ring_mat)
	member.add_child(turret_ring)
	mats.append(ring_mat)

	# Turret body — wedge-shaped block on the ring.
	var turret_pivot := Node3D.new()
	turret_pivot.name = "TurretPivot"
	turret_pivot.position = Vector3(0.0, turret_y + 0.10, -0.10)
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

	# Branch variant overlays for the Courier Tank. Infiltrator gets
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
		# Breacher Tank squad of 3 sits looser than it needs to.
		# Chassis is ~2.91u wide (hull 1.55 + 2 * track 0.68); the
		# transport-class default spacing of 3.5u left a ~0.6u gap
		# between adjacent tanks. Tighten to 3.15u for a ~0.24u
		# gap -- visibly closer formation without the tracks
		# clipping into each other.
		var ovb: Dictionary = base.duplicate()
		ovb["formation_spacing"] = 3.15
		return ovb
	if stats.unit_name.findn("Harbinger") >= 0:
		var ovh: Dictionary = base.duplicate()
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
	## Anvil VA-9 Breacher Tank — casemate-style tank destroyer with
	## a fixed forward-mounted heavy gun (no turret). Lower + wider
	## silhouette than the Bulwark biped, longer than the Sable
	## Courier Tank's turreted hull. Distinct visual identity:
	##   - twin track rails like the Courier
	##   - sloped forward casemate hosting a single heavy cannon
	##   - twin exhaust stacks on the rear deck
	##   - Anvil amber side stripe instead of Sable violet
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
		# Courier Tank read so tracked vehicles share a visual
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

	# --- Amber side stripes (Anvil identity, opposite of Sable
	# Courier Tank's violet seams).
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
	var launcher_pivot := Node3D.new()
	launcher_pivot.name = "LauncherPivot"
	launcher_pivot.position = Vector3(0.0, deck_y + 0.30, hull_len * 0.10)
	launcher_pivot.rotation.x = deg_to_rad(-22.0)
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
	## Anvil VA-5 Grinder Tank — medium tracked tank with a normal
	## rotating turret and a dozer prow on the front. Distinct from
	## the Breacher Tank (no casemate, has a turret) and the Sable
	## Courier Tank (Anvil amber stripe + dozer blade out front).
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

		# Hip: thigh rotates OUTWARD slightly (knee away from body) and
		# leans forward/back so each leg has a distinct stance silhouette.
		var thigh_rot := Node3D.new()
		# Pitch: front legs lean forward, rear legs lean backward.
		thigh_rot.rotation.x = 0.32 if is_front else -0.32
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

		# Shin counter-rotates so the leg's overall "world" angle ends
		# near vertical — the foot lands roughly under the hip. Front
		# legs bend back, rear legs bend forward (classic horse stance).
		var shin_rot := Node3D.new()
		shin_rot.rotation.x = -0.55 if is_front else 0.55
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
		if stats.unit_name.findn("Grinder") >= 0:
			return 1.55
		# Sable Courier Tank default.
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
	# centre instead of leaving holes where the dead used to stand.
	_rebalance_formation()


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
	move_queue.clear()
	is_holding_position = false
	patrol_a = Vector3.INF
	patrol_b = Vector3.INF
	move_target = target
	move_target.y = global_position.y
	has_move_order = true
	_stuck_timer = 0.0
	if _nav_agent:
		_nav_agent.target_position = move_target
	if clear_combat:
		var combat: Node = get_combat()
		if combat and combat.has_method("clear_target"):
			combat.clear_target()


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
	## Courier Tank embark / disembark toggle.
	##   No passengers loaded -> board the nearest 3 friendly Anvil
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
	# Courier Tank, the passenger snaps to the carrier's position
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

	# Damage flash countdown (cheap — runs every frame).
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_restore_member_colors()

	# Active-ability cooldown tick.
	if _ability_cd_remaining > 0.0:
		_ability_cd_remaining = maxf(0.0, _ability_cd_remaining - delta)

	# Courier Tank track-rib scrolling — slide the per-tread plate
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

	# Camera-distance cull flag. AI / pathing / combat still run; only
	# the per-frame cosmetic work (walk-bob, HP bar reposition, dust,
	# recoil) skips when the unit is off-camera.
	if not _camera_cached or not is_instance_valid(_camera_cached):
		_camera_cached = get_viewport().get_camera_3d() if get_viewport() else null
	var anim_culled: bool = false
	if _camera_cached:
		anim_culled = global_position.distance_squared_to(_camera_cached.global_position) > ANIM_CULL_DIST_SQ

	# Walking animation. _anim_time only advances while moving so legs always
	# resume from a clean stride; _idle_time runs continuously to drive the
	# small standing sway.
	_idle_time += delta
	if velocity.length_squared() > 1.0:
		# `delta` here represents one physics frame (~16ms) but with the
		# outer 1-in-3 stagger this branch only runs every 3rd frame —
		# advance _anim_time by 3× delta so the leg phase keeps the
		# same wall-clock cadence as before.
		_anim_time += delta * 8.0 * 3.0
		# Skip cosmetic work when the unit is off-camera. The animation
		# state still advances so legs resume mid-stride when the
		# camera pans back, but no per-leg sin / position writes fire.
		if not anim_culled:
			_apply_walk_bob()
			_tick_walking_dust(delta * 3.0)
	else:
		_anim_time = 0.0
		# Idle sway is invisibly subtle at 60Hz; throttle to ~15Hz with
		# round-robin staggering so 88 units don't all run reset_walk_bob
		# in the same physics frame.
		_idle_anim_throttle += 1
		if _idle_anim_throttle >= IDLE_ANIM_THROTTLE_FRAMES:
			_idle_anim_throttle = 0
			if not anim_culled:
				_reset_walk_bob()

	# Skip the recoil loop entirely when no member is recoiling, OR when
	# the unit is off-camera (recoil is purely visual — the gun fires
	# either way via combat_component).
	if not anim_culled and Time.get_ticks_msec() < _recoil_active_until_msec:
		_tick_recoil(delta)

	if is_building:
		_animate_build_claw()
		_build_spark_timer -= delta
		if _build_spark_timer <= 0.0:
			_build_spark_timer = 0.16
			_spawn_build_sparks()

	# Position HP bar above unit (top_level so we set global_position).
	# Visibility rule: shown when selected, when damaged, or when hovered. A
	# healthy idle unit is invisible-bar so the battlefield isn't cluttered.
	# When the bar is invisible we skip the position/rotation update entirely
	# — that work is per-unit per-physics-frame, and at 80+ units it's the
	# difference between 4ms and 0.4ms of HP-bar overhead.
	if _hp_bar and is_instance_valid(_hp_bar):
		var damaged: bool = false
		if stats:
			damaged = get_total_hp() < stats.hp_total
		var should_show: bool = is_selected or damaged or hp_bar_hovered
		if _hp_bar.visible != should_show:
			_hp_bar.visible = should_show
		# Skip the position / rotation update when off-camera (the bar
		# is also invisible at that range so the math is wasted).
		if should_show and not anim_culled:
			# Use the cached total height (set in _ready). Falls back to
			# the live computation if the cache wasn't populated for any
			# reason — same answer, just one extra dict lookup.
			var bar_height: float = (_cached_total_height if _cached_total_height > 0.0 else _mech_total_height()) + 0.4
			_hp_bar.global_position = global_position + Vector3(0, bar_height, 0)
			# Reuse the cached camera reference set above for the cull
			# check — saves a get_viewport().get_camera_3d() per frame.
			if _camera_cached:
				_hp_bar.global_rotation = _camera_cached.global_rotation

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
				member.position.y = surface_world_y - global_position.y + bob
				continue
		member.position.y = bob


func _reset_walk_bob() -> void:
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
			member.position.y = sin(idle_phase) * 0.012
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
			if r <= 0.0:
				continue
			r = maxf(0.0, r - delta * RECOIL_DECAY)
			recoil[c] = r
			var pivot: Node3D = cannons[c]
			if is_instance_valid(pivot):
				# Recoil is an OFFSET on top of the cannon's rest position; the
				# rest may be non-zero (e.g., Bulwark's hull-mounted gun sits at
				# the chassis front), so we must add to it instead of replacing.
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
		# stealth — Engineer 100, Glitch 150, Spotter 200, others 80.
		var their_r: float = 80.0
		if "stats" in node:
			var their_stats: UnitStatResource = node.get("stats") as UnitStatResource
			if their_stats:
				their_r = their_stats.detection_radius
		var their_r2: float = their_r * their_r
		var dx: float = (node as Node3D).global_position.x - global_position.x
		var dz: float = (node as Node3D).global_position.z - global_position.z
		var d2: float = dx * dx + dz * dz
		if d2 <= their_r2 or d2 <= detect_r2:
			spotted = true
			break
	if spotted != stealth_revealed:
		_set_stealth_revealed(spotted)


func _set_stealth_revealed(revealed: bool) -> void:
	stealth_revealed = revealed
	_apply_stealth_visual(not revealed)


func _apply_stealth_visual(concealed: bool) -> void:
	## Fades the squad members' rendering so concealed units read as
	## a faint shimmer. GeometryInstance3D.transparency in 0..1 is a
	## per-instance fade — 0 = opaque, 1 = invisible. We use 0.7 so
	## the silhouette is barely there but still distinguishable to
	## the controlling player.
	var t: float = 0.7 if concealed else 0.0
	for member: Node3D in _member_meshes:
		if not is_instance_valid(member):
			continue
		_apply_transparency_recursive(member, t)


func _apply_transparency_recursive(node: Node, t: float) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).transparency = t
	for child: Node in node.get_children():
		_apply_transparency_recursive(child, t)


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
	if _faction_id() != 1:  # not Sable → no change
		return c
	# Sable per-class palette. The Anvil unit base colors all collapsed
	# to a single near-black after the desaturate pass, making a Sable
	# squad of Riggers look identical to a squad of Specters. Shift the
	# tone per class so the squads can be told apart at a glance:
	#   engineer = warm graphite (slight bronze undercoat)
	#   light    = blued steel (cool, slightly brighter)
	#   medium   = anthracite (the canonical "Sable" matte black)
	#   heavy    = gunmetal (heavy and slightly green-tinted)
	#   apex     = obsidian violet (darkest + violet wash)
	var class_id: StringName = stats.unit_class if stats else &"medium"
	var palette: Vector3
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
