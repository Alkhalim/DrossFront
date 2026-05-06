class_name Steering
extends RefCounted
## Static steering primitives. Composed by MovementComponent each
## physics frame to produce a desired velocity. Inputs are pure
## values; outputs are Vector3 force/velocity contributions.
##
## Reference: spec §6 "Per-frame steering".

const ZERO: Vector3 = Vector3.ZERO

static func seek(current_pos: Vector3,
                 target_pos: Vector3,
                 max_speed: float) -> Vector3:
	## Returns a desired velocity pointing at target at full speed.
	## Caller composes / clamps / inertia-steps the result.
	var diff: Vector3 = target_pos - current_pos
	diff.y = 0.0
	var d: float = diff.length()
	if d < 0.001:
		return ZERO
	return (diff / d) * max_speed

static func separate(current_pos: Vector3,
                     neighbors: Array,
                     min_distance: float,
                     repel_strength: float) -> Vector3:
	## Returns a repulsion velocity from any neighbor within
	## min_distance. `neighbors` is an untyped Array; non-Node3D
	## entries are silently skipped. Repulsion grows linearly as
	## the gap shrinks (1.0 at 0 distance, 0.0 at min_distance).
	## Output is unbounded — caller clamps.
	var force: Vector3 = ZERO
	for n: Variant in neighbors:
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		var neighbor_pos: Vector3 = (n as Node3D).global_position
		var diff: Vector3 = current_pos - neighbor_pos
		diff.y = 0.0
		var d: float = diff.length()
		if d < 0.001:
			# Coincident — push out in an arbitrary stable direction.
			# True coincidence is vanishingly rare at normal agent
			# densities; the bias toward Vector3.RIGHT is acceptable.
			force += Vector3.RIGHT * repel_strength
			continue
		if d >= min_distance:
			continue
		var falloff: float = 1.0 - (d / min_distance)
		force += (diff / d) * (repel_strength * falloff)
	return force

static func avoid_static(current_pos: Vector3,
                         obstacles: Array,
                         min_distance: float,
                         repel_strength: float) -> Vector3:
	## Same falloff math as separate(), but for static obstacles
	## (Node3D entities tagged as buildings/wrecks/terrain). Caller
	## supplies the obstacle list — typically filtered from
	## SpatialIndex by group membership ("buildings" group) or
	## a per-script tag. Identical implementation to separate but
	## kept distinct so future tuning (different falloff curve
	## for static vs dynamic) doesn't require touching both.
	return separate(current_pos, obstacles, min_distance, repel_strength)

static func inertia_step(current_velocity: Vector3,
                         desired_velocity: Vector3,
                         max_accel: float,
                         max_turn_rate_rad_s: float,
                         dt: float) -> Vector3:
	## Steps current_velocity toward desired_velocity bounded by
	## max_accel (units/s²) and max_turn_rate (radians/s). Heading
	## change is rate-limited; magnitude change is also rate-limited.
	## Returns the new velocity to assign to the physics body.
	if dt <= 0.0:
		return current_velocity

	# Heading change (rate-limited rotation)
	var cur_speed: float = current_velocity.length()
	var des_speed: float = desired_velocity.length()
	var new_dir: Vector3
	if cur_speed < 0.001:
		new_dir = desired_velocity.normalized() if des_speed > 0.001 else Vector3.FORWARD
	elif des_speed < 0.001:
		new_dir = current_velocity / cur_speed
	else:
		var cur_dir: Vector3 = current_velocity / cur_speed
		var des_dir: Vector3 = desired_velocity / des_speed
		var max_step_rad: float = max_turn_rate_rad_s * dt
		# Angle between them (XZ plane)
		var cur_dir_xz: Vector2 = Vector2(cur_dir.x, cur_dir.z)
		var des_dir_xz: Vector2 = Vector2(des_dir.x, des_dir.z)
		var ang_to: float = cur_dir_xz.angle_to(des_dir_xz)
		var ang_step: float = clampf(ang_to, -max_step_rad, max_step_rad)
		var rot_xz: Vector2 = cur_dir_xz.rotated(ang_step)
		new_dir = Vector3(rot_xz.x, 0.0, rot_xz.y)

	# Magnitude change (rate-limited)
	var max_speed_step: float = max_accel * dt
	var new_speed: float = clampf(des_speed,
		cur_speed - max_speed_step,
		cur_speed + max_speed_step)
	new_speed = maxf(new_speed, 0.0)
	return new_dir * new_speed
