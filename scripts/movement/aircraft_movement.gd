class_name AircraftMovement
extends MovementComponent
## Free-flight movement for aircraft and drones. No NavRouter queries —
## aircraft fly directly toward target with separation/avoidance from
## other aircraft. Y axis is owned by altitude logic; the SEEK math
## (in the base class) operates on XZ.
##
## Plan B scope: solo aircraft moves only. Mixed-domain SquadGroup
## (air sub-formation, soft-throttle gate vs ground center) is Plan C.

@export var base_altitude: float = 12.0           # cruise altitude above terrain
@export var altitude_climb_rate: float = 8.0      # u/s vertical adjustment
@export var bank_angle_max_rad: float = PI * 0.25 # max visual roll on turn
@export var bank_response_rate: float = 4.0       # how fast roll catches up

var _bank_angle_current: float = 0.0
var _last_heading_xz: Vector2 = Vector2.ZERO
## Arrival hysteresis state (mirrors GroundMovement._is_arrived). True when
## the aircraft is within arrival_radius of its goal and the kernel's
## AGENT_FLAG_ARRIVED is set (SEEK suppressed). Cleared on every new order
## in goto_world so a new destination starts fresh.
var _is_arrived: bool = false


func _ready() -> void:
	super._ready()
	# Aircraft fly fast (12-18 u/s) and pull tight separation
	# circles when in formation. With the base-class stagger, the
	# cached separate force was a tick stale — for slow ground
	# units that's invisible, but for aircraft it produced a
	# visible tremble (cached force pointed at a neighbor's old
	# position, then suddenly snapped to the fresh one on the next
	# heavy tick). Disable stagger; aircraft recompute neighbors
	# every tick. Aircraft populations are sparse enough that the
	# extra SpatialIndex query is cheap.
	_stagger_enabled = false
	# Wider arrival_radius than the base 3.0 default. With flight
	# speed 12-18 u/s and max_accel 30, deceleration distance is
	# ~5.4 u; a 3 u arrival zone meant SEEK kept oscillating between
	# decel and overshoot near the destination, producing trembling
	# in place when the aircraft "arrived". 6 u gives the inertia
	# step room to converge cleanly.
	arrival_radius = 6.0
	# Altitude snap on spawn — deferred. Godot's spawn order is
	# `instantiate → add_child (triggers _ready) → global_position = pos`,
	# so at _ready time the body is still at (0,0,0). A direct snap here
	# would write Y=base_altitude at the origin, and an immediate
	# set_agent_target_pos would point the kernel's AIRCRAFT SEEK at
	# (0, base_altitude, 0) — the middle of the map. Deferring to the
	# next idle frame guarantees the spawner has placed the body first.
	#
	# We DON'T call set_agent_target_pos here — that would set HAS_TARGET
	# and force the kernel to SEEK toward our current position. Without
	# HAS_TARGET set, the kernel tick() short-circuits and the aircraft
	# simply hovers wherever the orchestrator's set_agent_pos mirrors
	# from _body.global_position. First real goto_world sets both the
	# target and HAS_TARGET correctly.
	call_deferred("_snap_altitude_on_spawn")


func _snap_altitude_on_spawn() -> void:
	if _body != null:
		_body.global_position.y = base_altitude


func goto_world(world_pos: Vector3) -> void:
	## Aircraft don't navmesh-route; just set the target. Y is overridden
	## to base_altitude so the unit doesn't try to dive into the ground.
	target = Vector3(world_pos.x, base_altitude, world_pos.z)
	# New order — reset arrival state so the unit actively seeks the new goal.
	_is_arrived = false
	# PF-B-B6: forward single-aircraft targets to the kernel via
	# set_agent_target_pos. The kernel's AIRCRAFT branch (B2) consumes
	# target_pos for direct 3D seek. Multi-unit aircraft orders are
	# already routed via GroupAura (B4). Solo orders — drone repositions,
	# ai_controller per-tick moves, ability targeting that translates
	# to a move — land here.
	if kernel_handle == 0:
		return
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return
	var kernel: Object = MovementNativeBootstrap.get_kernel(scene)
	if kernel == null:
		return
	kernel.call("set_agent_target_pos", kernel_handle, target)

func _apply_kernel_velocity(v: Vector3, delta: float) -> void:
	# Arrival hysteresis — same pattern as GroundMovement._apply_kernel_velocity.
	# Aircraft target is set by goto_world (which GroupAura also calls for aircraft
	# members), so has_target() is valid here. arrival_radius is 6.0 for aircraft.
	# When within arrival_radius the kernel's SEEK is suppressed via
	# AGENT_FLAG_ARRIVED so crowded aircraft stop jostling for the same point.
	const AGENT_FLAG_ARRIVED_BIT: int = 64  # 1 << 6, mirrors types.h
	if kernel_handle != 0 and has_target() and _body != null:
		var dist_to_target: float = _body.global_position.distance_to(target)
		var ar: float = arrival_radius
		if not _is_arrived and dist_to_target < ar:
			_is_arrived = true
			var scene1: Node = get_tree().current_scene if get_tree() else null
			if scene1 != null:
				var kernel1: Object = MovementNativeBootstrap.get_kernel(scene1)
				if kernel1 != null:
					kernel1.call("set_agent_flag", kernel_handle, AGENT_FLAG_ARRIVED_BIT, true)
		elif _is_arrived and dist_to_target > ar * 1.5:
			_is_arrived = false
			var scene2: Node = get_tree().current_scene if get_tree() else null
			if scene2 != null:
				var kernel2: Object = MovementNativeBootstrap.get_kernel(scene2)
				if kernel2 != null:
					kernel2.call("set_agent_flag", kernel_handle, AGENT_FLAG_ARRIVED_BIT, false)
	# PF-B-final-fix: kernel computes 3D velocity for aircraft but does
	# nothing about visual rotation. Populate _velocity so _update_bank
	# can read heading, apply movement via super (Node3D positional
	# integration: global_position += v * delta), then update bank/yaw
	# the same way the legacy tick_movement did.
	_velocity = v
	super._apply_kernel_velocity(v, delta)
	_update_bank(delta)

func tick_movement(delta: float, frame_phase: int) -> void:
	super.tick_movement(delta, frame_phase)
	# Altitude maintenance: pull Y toward base_altitude. Aircraft don't
	# have gravity (GroundMovement applies gravity; AircraftMovement
	# explicitly does not).
	if _body != null:
		var y_diff: float = base_altitude - _body.global_position.y
		var y_step: float = clampf(y_diff,
			-altitude_climb_rate * delta,
			altitude_climb_rate * delta)
		_body.global_position.y += y_step
	_update_bank(delta)

func _update_bank(delta: float) -> void:
	## Yaw the aircraft to face its current velocity AND apply visual
	## bank/roll proportional to the turn rate. The previous version
	## reset the basis to (UP, current_basis.get_euler().y) every
	## frame — i.e. it preserved whatever yaw the body already had
	## without ever turning toward the velocity heading. Aircraft
	## tasked to a new direction kept facing the OLD heading because
	## nothing actually wrote the new yaw. Visible bug: Wraiths
	## (and any other AircraftMovement-driven aircraft) sliding
	## sideways without rotating.
	if _body == null:
		return
	var heading: Vector2 = Vector2(_velocity.x, _velocity.z)
	var heading_len: float = heading.length()
	var current_y: float = _body.transform.basis.get_euler().y
	var desired_y: float = current_y
	var target_bank: float = 0.0
	if heading_len > 0.5:
		var heading_dir: Vector2 = heading / heading_len
		# Aircraft scenes are oriented with the nose along -Z.
		# atan2(x, -z) gives the Y rotation that points -Z toward
		# (heading_dir.x, heading_dir.y).
		desired_y = atan2(heading_dir.x, -heading_dir.y)
		if _last_heading_xz.length() > 0.5:
			var ang: float = _last_heading_xz.normalized().angle_to(heading_dir)
			target_bank = clampf(ang / maxf(delta, 0.001) * 0.1,
			                     -bank_angle_max_rad, bank_angle_max_rad)
	_last_heading_xz = heading
	# Slew the actual yaw toward the desired heading at a fixed
	# turn rate. Wrapping the delta into [-PI, PI] avoids the long
	# way around when crossing the +PI/-PI seam.
	const TURN_RATE_RAD_PER_SEC: float = 4.5
	var dy: float = desired_y - current_y
	while dy > PI:
		dy -= TAU
	while dy < -PI:
		dy += TAU
	var step: float = clampf(dy, -TURN_RATE_RAD_PER_SEC * delta, TURN_RATE_RAD_PER_SEC * delta)
	var new_y: float = current_y + step
	_bank_angle_current = lerpf(_bank_angle_current, target_bank,
	                             bank_response_rate * delta)
	# Compose: yaw around Y (heading) then roll around forward (-Z) for visual bank.
	var t: Transform3D = _body.transform
	t.basis = Basis(Vector3.UP, new_y).rotated(Vector3.FORWARD, _bank_angle_current)
	_body.transform = t

func _separate_neighbors(prefetched: Array = []) -> Array:
	## Aircraft separate from other aircraft and drones in the air —
	## not from ground units (they're far below). When the base
	## tick_movement passes a prefetched raw list, skip the
	## SpatialIndex query and just filter.
	var raw: Array = prefetched
	if raw.is_empty():
		var idx: SpatialIndex = _get_spatial_idx()
		if idx == null:
			return []
		raw = idx.nearby(_body.global_position, separate_min_distance + 1.0)
	var filtered: Array = []
	for n: Variant in raw:
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		if n == _body or n == get_parent():
			continue
		# Only separate from other airborne entities
		if n is Aircraft or n is Drone:
			filtered.append(n)
	return filtered

func _avoid_obstacles(_prefetched: Array = []) -> Array:
	## Aircraft don't AVOID buildings by default — they fly over them.
	## Plan C may add AA-building avoidance for tactical reasons.
	return []

func _is_combat_engaged() -> bool:
	var owner_unit: Node = get_parent()
	if owner_unit == null:
		return false
	if owner_unit.has_method("_in_active_combat"):
		return owner_unit._in_active_combat() as bool
	return false
