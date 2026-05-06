class_name MovementComponent
extends Node
## Abstract base for all movement. Attached to a CharacterBody3D
## (the unit chassis). Reads `target` from the order layer or its
## own routing logic; produces a desired velocity each physics
## frame; writes velocity to its parent body.
##
## Subclasses (GroundMovement / AircraftMovement / CrawlerMovement)
## implement neighbor and obstacle queries plus path planning. The
## base owns force composition and inertia. See spec §6.

signal path_unreachable(reason: int)
const REASON_NO_NAVMESH_PATH: int = 0
const REASON_GOAL_IN_OBSTACLE: int = 1
const REASON_REPEATEDLY_STUCK: int = 2
const REASON_AGENT_OFF_NAVMESH: int = 3

# --- Configurable per-instance (set by owning unit on _ready) ---
var max_speed: float = 8.0
var max_accel: float = 30.0
var max_turn_rate_rad_s: float = TAU            # default: 1 turn/sec
var separate_min_distance: float = 2.5
var separate_repel: float = 6.0
var avoid_min_distance: float = 4.0
var avoid_repel: float = 12.0

# --- Set every frame by the order layer or solo logic ---
var target: Vector3 = Vector3.INF                # INF = no order
var effective_max_speed_cap: float = INF         # convoy cap from SquadGroup
var effective_max_turn_rate_cap: float = INF

# --- Internal state ---
var _velocity: Vector3 = Vector3.ZERO
var _body: CharacterBody3D = null

func _ready() -> void:
	# Parent should be the unit's CharacterBody3D chassis.
	_body = get_parent() as CharacterBody3D
	if _body == null:
		push_error("MovementComponent must be a child of CharacterBody3D")
		set_physics_process(false)

func _physics_process(delta: float) -> void:
	if _body == null:
		return
	if not has_target():
		# Decelerate to rest and idle
		_velocity = Steering.inertia_step(
			_velocity, Vector3.ZERO, max_accel, max_turn_rate_rad_s, delta)
		_body.velocity = _velocity
		_body.move_and_slide()
		return

	var pos: Vector3 = _body.global_position
	var desired: Vector3 = Steering.seek(pos, target, _capped_speed())
	desired += Steering.separate(pos,
								  _separate_neighbors(),
								  separate_min_distance,
								  separate_repel)
	desired += Steering.avoid_static(pos,
									  _avoid_obstacles(),
									  avoid_min_distance,
									  avoid_repel)
	# Clamp composed magnitude to capped speed
	var dlen: float = desired.length()
	if dlen > _capped_speed():
		desired = desired * (_capped_speed() / dlen)

	_velocity = Steering.inertia_step(
		_velocity, desired, max_accel, _capped_turn_rate(), delta)
	_body.velocity = _velocity
	_body.move_and_slide()

func has_target() -> bool:
	return not _is_inf(target)

func clear_target() -> void:
	target = Vector3.INF

# --- Subclass hooks ---

func _separate_neighbors() -> Array:
	## Return non-group-member dynamic agents within sensing range.
	## Subclass overrides to query SpatialIndex and filter by
	## SquadGroup membership and entity type.
	return []

func _avoid_obstacles() -> Array:
	## Return static obstacles (buildings, wrecks, terrain hazards).
	## Subclass overrides to query SpatialIndex filtered to "buildings"
	## group / wreck class etc.
	return []

# --- Helpers ---

func _capped_speed() -> float:
	return minf(max_speed, effective_max_speed_cap)

func _capped_turn_rate() -> float:
	return minf(max_turn_rate_rad_s, effective_max_turn_rate_cap)

static func _is_inf(v: Vector3) -> bool:
	return is_inf(v.x) or is_inf(v.y) or is_inf(v.z)
