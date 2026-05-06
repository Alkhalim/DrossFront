class_name MovementComponent
extends Node                  # attached as child of CharacterBody3D, not the body itself
## Abstract base for all movement. Attached to a Node3D (or
## CharacterBody3D) unit chassis. Reads `target` from the order
## layer or its own routing logic; produces a desired velocity each
## physics frame; writes velocity to its parent body.
##
## When the parent is a CharacterBody3D (ground units), velocity is
## written via move_and_slide(). When the parent is a plain Node3D
## (aircraft, drones), position is integrated directly.
##
## Subclasses (GroundMovement / AircraftMovement / CrawlerMovement)
## implement neighbor and obstacle queries plus path planning. The
## base owns force composition and inertia. See spec §6.

signal path_unreachable(reason: int)
const REASON_NO_NAVMESH_PATH: int = 0
const REASON_GOAL_IN_OBSTACLE: int = 1
const REASON_REPEATEDLY_STUCK: int = 2
const REASON_AGENT_OFF_NAVMESH: int = 3

## World boundary for the off-map safety check. SpatialIndex's
## MAP_HALF is 200u; we use a slightly larger threshold so a unit
## briefly overshooting the mesh edge isn't immediately panicked.
## When a unit's global_position exceeds this on X or Z, the
## component emits path_unreachable and halts.
const OFF_MAP_THRESHOLD: float = 250.0

# --- Configurable per-instance (set by owning unit on _ready) ---
var max_speed: float = 8.0
var max_accel: float = 30.0
var max_turn_rate_rad_s: float = TAU            # default: one full rotation per second (2π rad/s)
var separate_min_distance: float = 2.5
var separate_repel: float = 6.0
var avoid_min_distance: float = 6.0
var avoid_repel: float = 24.0
@export var arrival_radius: float = 2.0

# --- Set every frame by the order layer or solo logic ---
var target: Vector3 = Vector3.INF                # INF = no active order; checked via has_target()
var effective_max_speed_cap: float = INF         # convoy cap from SquadGroup
var effective_max_turn_rate_cap: float = INF

# --- Internal state ---
var _velocity: Vector3 = Vector3.ZERO
var _body: Node3D = null                       # primary reference: position reads
var _body_physics: CharacterBody3D = null      # set if parent is CharacterBody3D
var _off_map_emitted: bool = false

func _ready() -> void:
	var p: Node = get_parent()
	if not (p is Node3D):
		push_error("MovementComponent must be a child of Node3D or CharacterBody3D")
		set_physics_process(false)
		return
	_body = p as Node3D
	if p is CharacterBody3D:
		_body_physics = p as CharacterBody3D
	_stuck_last_pos = _body.global_position

func _physics_process(delta: float) -> void:
	if _body == null:
		return

	# Off-map safety net (Plan B hotfix; Plan C addresses root cause
	# via slot projection per spec §9). If the unit has drifted
	# outside sensible world bounds, stop and emit path_unreachable
	# so AI / SquadGroup can drop it.
	var pos_check: Vector3 = _body.global_position
	if absf(pos_check.x) > OFF_MAP_THRESHOLD or absf(pos_check.z) > OFF_MAP_THRESHOLD:
		_velocity = Vector3.ZERO
		if _body_physics != null:
			_body_physics.velocity = Vector3.ZERO
		clear_target()
		if not _off_map_emitted:
			_off_map_emitted = true
			path_unreachable.emit(REASON_AGENT_OFF_NAVMESH)
		return

	# EMP paralysis: zero velocity, skip steering. Mirrors the legacy
	# path in unit.gd's _physics_process.
	var owner_unit: Node = get_parent()
	if owner_unit != null and "_emp_paralysis_remaining" in owner_unit:
		var emp_state: Variant = owner_unit.get("_emp_paralysis_remaining")
		var emp_active: bool = false
		if emp_state is float:
			emp_active = (emp_state as float) > 0.0
		if emp_active:
			_velocity = Vector3.ZERO
			if _body_physics != null:
				_body_physics.velocity = Vector3.ZERO
				_body_physics.move_and_slide()
			return

	if not has_target():
		# Decelerate to rest and idle
		_velocity = Steering.inertia_step(
			_velocity, Vector3.ZERO, max_accel, max_turn_rate_rad_s, delta)
		if _body_physics != null:
			_body_physics.velocity = _velocity
			_body_physics.move_and_slide()
		else:
			_body.global_position += _velocity * delta
		_stuck_step(delta, _is_combat_engaged())
		return

	var pos: Vector3 = _body.global_position
	var cap: float = _capped_speed()
	# NOTE: a previous Plan B fix tried to zero SEEK during combat
	# (_is_combat_engaged()) to stop "moves while firing" cosmetic
	# circling. That regressed attack-move (units froze before
	# reaching range) and ignored new move commands during the frame
	# combat was clearing. Reverted. Plan C will add a proper stance
	# system that distinguishes "acquired target out of range" (keep
	# moving) from "actively firing in range" (hold position).
	var desired: Vector3 = Steering.seek(pos, target, cap, arrival_radius)
	desired += Steering.separate(pos,
								  _separate_neighbors(),
								  separate_min_distance,
								  separate_repel)
	desired += Steering.avoid_static(pos,
									  _avoid_obstacles(),
									  avoid_min_distance,
									  avoid_repel)
	if _stuck_pushout_frames_left > 0:
		desired += _stuck_pushout_dir * max_speed
		_stuck_pushout_frames_left -= 1
	# Clamp composed magnitude to capped speed
	var dlen: float = desired.length()
	if dlen > cap:
		desired = desired * (cap / dlen)

	_velocity = Steering.inertia_step(
		_velocity, desired, max_accel, _capped_turn_rate(), delta)
	if _body_physics != null:
		_body_physics.velocity = _velocity
		_body_physics.move_and_slide()
	else:
		_body.global_position += _velocity * delta
	_stuck_step(delta, _is_combat_engaged())

func has_target() -> bool:
	return not _is_inf(target)

func clear_target() -> void:
	target = Vector3.INF

# --- Subclass hooks ---

## Return non-group-member dynamic agents within sensing range.
## Subclass overrides to query SpatialIndex and filter by
## SquadGroup membership and entity type.
func _separate_neighbors() -> Array:
	return []

## Return static obstacles (buildings, wrecks, terrain hazards).
## Subclass overrides to query SpatialIndex filtered to "buildings"
## group / wreck class etc.
func _avoid_obstacles() -> Array:
	return []

# --- Helpers ---

func _capped_speed() -> float:
	return minf(max_speed, effective_max_speed_cap)

func _capped_turn_rate() -> float:
	return minf(max_turn_rate_rad_s, effective_max_turn_rate_cap)

static func _is_inf(v: Vector3) -> bool:
	return is_inf(v.x) or is_inf(v.y) or is_inf(v.z)

# --- Stuck detector ---
@export var stuck_progress_ratio_threshold: float = 0.10
@export var stuck_window_frames: int = 30
@export var stuck_repath_cooldown: float = 1.5
@export var stuck_pushout_cooldown: float = 2.0
@export var stuck_pushout_duration_frames: int = 10

var _stuck_buffer: PackedFloat32Array = PackedFloat32Array()
var _stuck_buffer_idx: int = 0
var _stuck_last_pos: Vector3 = Vector3.ZERO
var _stuck_level: int = 0                       # 0 = healthy, 1 = repathed, 2 = pushed-out
var _stuck_cooldown_remaining: float = 0.0
var _stuck_pushout_frames_left: int = 0
var _stuck_pushout_dir: Vector3 = Vector3.ZERO

func _ensure_stuck_buffer() -> void:
	if _stuck_buffer.size() != stuck_window_frames:
		_stuck_buffer.resize(stuck_window_frames)
		for i: int in stuck_window_frames:
			_stuck_buffer[i] = max_speed * (1.0 / 60.0)  # seed as healthy
		_stuck_buffer_idx = 0

func _stuck_step(delta: float, combat_engaged: bool) -> void:
	_ensure_stuck_buffer()
	if _stuck_cooldown_remaining > 0.0:
		_stuck_cooldown_remaining -= delta
	var pos: Vector3 = _body.global_position
	var disp: float = (pos - _stuck_last_pos).length()
	_stuck_last_pos = pos
	_stuck_buffer[_stuck_buffer_idx] = disp
	_stuck_buffer_idx = (_stuck_buffer_idx + 1) % _stuck_buffer.size()

	if not has_target():
		return
	if combat_engaged:
		return
	if _stuck_cooldown_remaining > 0.0:
		return
	# Arrived at destination — not stuck, just standing still on slot.
	# Reset escalation level so a future actual-stuck case starts fresh.
	if arrival_radius > 0.0:
		var d_to_target: float = Vector2(pos.x - target.x, pos.z - target.z).length()
		if d_to_target < arrival_radius:
			_stuck_level = 0
			return

	var sum: float = 0.0
	for v: float in _stuck_buffer:
		sum += v
	var mean_disp: float = sum / float(_stuck_buffer.size())
	var expected: float = max_speed * (1.0 / 60.0)
	if expected <= 0.0:
		return
	var ratio: float = mean_disp / expected
	if ratio > 0.5:
		# Healthy progress — reset escalation level
		_stuck_level = 0
		return
	if ratio < stuck_progress_ratio_threshold:
		_escalate()

func _escalate() -> void:
	_stuck_level += 1
	match _stuck_level:
		1:
			_stuck_cooldown_remaining = stuck_repath_cooldown
			_on_stuck_level_1_repath()
		2:
			_stuck_cooldown_remaining = stuck_pushout_cooldown
			_stuck_pushout_frames_left = stuck_pushout_duration_frames
			_stuck_pushout_dir = _compute_pushout_dir()
			_on_stuck_level_2_pushout()
		_:
			# Plan A clamps at level 2. Plan B adds Level 3-4.
			_stuck_level = 2
			path_unreachable.emit(REASON_REPEATEDLY_STUCK)

## Subclass override — request a fresh path.
func _on_stuck_level_1_repath() -> void:
	pass

## Subclass override; default no-op. The pushout direction is
## applied by the base (in _physics_process) for
## stuck_pushout_duration_frames after this fires.
func _on_stuck_level_2_pushout() -> void:
	pass

func _compute_pushout_dir() -> Vector3:
	## Default: opposite of mean obstacle direction. If no obstacles,
	## return a stable arbitrary perpendicular to current velocity.
	var pos: Vector3 = _body.global_position
	var obstacles: Array = _avoid_obstacles()
	if obstacles.is_empty():
		if _velocity.length() < 0.001:
			return Vector3.RIGHT
		return Vector3(-_velocity.z, 0, _velocity.x).normalized()
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for o: Variant in obstacles:
		if not is_instance_valid(o) or not (o is Node3D):
			continue
		sum += pos - (o as Node3D).global_position
		n += 1
	if n == 0:
		return Vector3.RIGHT
	sum.y = 0
	return sum.normalized()

## Subclass override — returns true if the unit is currently in
## combat (suppresses stuck detection per spec §11).
func _is_combat_engaged() -> bool:
	return false
