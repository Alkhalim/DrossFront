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

func goto_world(world_pos: Vector3) -> void:
	## Aircraft don't navmesh-route; just set the target. Y is overridden
	## to base_altitude so the unit doesn't try to dive into the ground.
	target = Vector3(world_pos.x, base_altitude, world_pos.z)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
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
	## Visual banking: roll the aircraft chassis when turning. This is
	## visual-only — doesn't affect physics or steering. The bank angle
	## is proportional to the heading change rate.
	if _body == null:
		return
	var heading: Vector2 = Vector2(_velocity.x, _velocity.z)
	var heading_len: float = heading.length()
	var target_bank: float = 0.0
	if heading_len > 0.5 and _last_heading_xz.length() > 0.5:
		var heading_dir: Vector2 = heading / heading_len
		var ang: float = _last_heading_xz.normalized().angle_to(heading_dir)
		# Bank toward the inside of the turn — sign matches angle delta.
		target_bank = clampf(ang / maxf(delta, 0.001) * 0.1,
		                     -bank_angle_max_rad, bank_angle_max_rad)
	_last_heading_xz = heading
	_bank_angle_current = lerpf(_bank_angle_current, target_bank,
	                             bank_response_rate * delta)
	# Apply visual roll to the body's transform. Implementer may need
	# to adjust the rotation axis depending on how aircraft scenes
	# are oriented (Godot default: forward = -Z; roll = around -Z).
	var t: Transform3D = _body.transform
	t.basis = t.basis.orthonormalized()
	# Reset roll, then apply current bank
	t.basis = Basis(Vector3.UP, t.basis.get_euler().y).rotated(Vector3.FORWARD, _bank_angle_current)
	_body.transform = t

func _separate_neighbors() -> Array:
	## Aircraft separate from other aircraft and drones in the air —
	## not from ground units (they're far below).
	var idx: SpatialIndex = SpatialIndex.get_instance(get_tree().current_scene)
	if idx == null:
		return []
	var pos: Vector3 = _body.global_position
	var raw: Array = idx.nearby(pos, separate_min_distance + 1.0)
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

func _avoid_obstacles() -> Array:
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
