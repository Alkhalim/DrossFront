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
                 max_speed: float,
                 arrival_radius: float = 0.0) -> Vector3:
	## Returns a desired velocity pointing at target. When `arrival_radius`
	## is > 0 and the unit is within it, scales speed linearly by distance
	## so the unit naturally damps to a stop at the target instead of
	## overshooting.
	var diff: Vector3 = target_pos - current_pos
	diff.y = 0.0
	var d: float = diff.length()
	if d < 0.001:
		return ZERO
	var speed: float = max_speed
	if arrival_radius > 0.0 and d < arrival_radius:
		speed = max_speed * (d / arrival_radius)
	return (diff / d) * speed

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
		var ref_pos: Vector3 = (n as Node3D).global_position
		# Building closest-point: large buildings would have near-zero falloff
		# if we measured from their center; use nearest AABB face instead.
		if n is Building:
			var b: Building = n as Building
			if b.stats != null and "footprint_size" in b.stats:
				var fp: Vector3 = b.stats.footprint_size
				var aabb_min: Vector3 = ref_pos - Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				var aabb_max: Vector3 = ref_pos + Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				ref_pos = Vector3(
					clampf(current_pos.x, aabb_min.x, aabb_max.x),
					current_pos.y,
					clampf(current_pos.z, aabb_min.z, aabb_max.z))
		# Crawler closest-point: crawlers are ~8u wide; measuring from center
		# means units touch the collider before any repulsion fires. Use a
		# fixed 8×8 AABB. Plan B: replace with large_footprint on UnitStatResource.
		elif (n as Node).get("stats") != null:
			var stats_var: Variant = (n as Node).get("stats")
			if "is_crawler" in stats_var and stats_var.is_crawler:
				var fp: Vector3 = Vector3(8.0, 0.0, 8.0)
				var aabb_min: Vector3 = ref_pos - Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				var aabb_max: Vector3 = ref_pos + Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				ref_pos = Vector3(
					clampf(current_pos.x, aabb_min.x, aabb_max.x),
					current_pos.y,
					clampf(current_pos.z, aabb_min.z, aabb_max.z))
		var diff: Vector3 = current_pos - ref_pos
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
	## Same falloff math as separate(), but for static obstacles.
	## For Building obstacles with a known footprint, use the closest
	## point on the building's footprint AABB instead of the building's
	## center — otherwise large buildings (HQ, factory) effectively have
	## avoidance radius 0 because the center is far inside.
	## NOTE: Steering → Building coupling is intentional for Plan A.
	## Plan B should refactor with a proper IObstacle interface.
	var force: Vector3 = ZERO
	for n: Variant in obstacles:
		if not is_instance_valid(n):
			continue
		if not (n is Node3D):
			continue
		var ref_pos: Vector3 = (n as Node3D).global_position
		# Building closest-point: use AABB face instead of center so
		# large buildings get meaningful falloff at the unit's actual
		# touch distance.
		if n is Building:
			var b: Building = n as Building
			if b.stats != null and "footprint_size" in b.stats:
				var fp: Vector3 = b.stats.footprint_size
				var aabb_min: Vector3 = ref_pos - Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				var aabb_max: Vector3 = ref_pos + Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				ref_pos = Vector3(
					clampf(current_pos.x, aabb_min.x, aabb_max.x),
					current_pos.y,
					clampf(current_pos.z, aabb_min.z, aabb_max.z))
		# Crawler closest-point: crawlers are ~8u wide; measuring from center
		# means units touch the collider before any repulsion fires. Use a
		# fixed 8×8 AABB. Plan B: replace with large_footprint on UnitStatResource.
		elif (n as Node).get("stats") != null:
			var stats_var: Variant = (n as Node).get("stats")
			if "is_crawler" in stats_var and stats_var.is_crawler:
				var fp: Vector3 = Vector3(8.0, 0.0, 8.0)
				var aabb_min: Vector3 = ref_pos - Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				var aabb_max: Vector3 = ref_pos + Vector3(fp.x * 0.5, 0.0, fp.z * 0.5)
				ref_pos = Vector3(
					clampf(current_pos.x, aabb_min.x, aabb_max.x),
					current_pos.y,
					clampf(current_pos.z, aabb_min.z, aabb_max.z))
		var diff: Vector3 = current_pos - ref_pos
		diff.y = 0.0
		var d: float = diff.length()
		if d < 0.001:
			force += Vector3.RIGHT * repel_strength
			continue
		if d >= min_distance:
			continue
		var falloff: float = 1.0 - (d / min_distance)
		force += (diff / d) * (repel_strength * falloff)
	return force

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
	# Default 1.0; only updated in the "both > 0" branch where ang_to is known.
	var alignment_factor: float = 1.0
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
		# Turn-priority: slow down while turning so units don't draw wide
		# arcs through the world. At full alignment (0°): factor=1.0.
		# At 180° (target behind): factor=0.15. Scales linearly.
		var abs_ang: float = absf(ang_to)
		alignment_factor = lerpf(1.0, 0.15, clampf(abs_ang / PI, 0.0, 1.0))

	# Magnitude change (rate-limited)
	var max_speed_step: float = max_accel * dt
	var target_speed: float = des_speed * alignment_factor
	var new_speed: float = clampf(target_speed,
		cur_speed - max_speed_step,
		cur_speed + max_speed_step)
	new_speed = maxf(new_speed, 0.0)
	return new_dir * new_speed
