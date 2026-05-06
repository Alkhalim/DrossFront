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
	## min_distance. neighbors is Array[Node3D]. Repulsion grows
	## linearly as the gap shrinks (1.0 at 0 distance, 0.0 at
	## min_distance). Output is unbounded — caller clamps.
	var force: Vector3 = ZERO
	for n: Variant in neighbors:
		if not (n is Node3D):
			continue
		if not is_instance_valid(n):
			continue
		var npos: Vector3 = (n as Node3D).global_position
		var diff: Vector3 = current_pos - npos
		diff.y = 0.0
		var d: float = diff.length()
		if d < 0.001:
			# Coincident — push out in an arbitrary stable direction
			force += Vector3.RIGHT * repel_strength
			continue
		if d >= min_distance:
			continue
		var falloff: float = 1.0 - (d / min_distance)
		force += (diff / d) * (repel_strength * falloff)
	return force
