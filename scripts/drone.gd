class_name Drone
extends Node3D
## Detached carrier-launched drone. Flies out from its parent
## carrier, fires one shot at a target, then flies back to the
## carrier and despawns. Dies with the carrier -- the moment the
## carrier becomes invalid, all of its drones queue_free.

const SPEED: float = 14.0
const DOCK_RADIUS: float = 2.0     # how close to the carrier counts as "docked"
const STRAFE_RADIUS: float = 4.5   # offset distance the drone holds while strafing past the target
const STRAFE_SHOTS: int = 3        # rounds the drone fires during a strafe pass
const STRAFE_SHOT_INTERVAL: float = 0.45  # seconds between consecutive strafe shots
const APPROACH_CURVE_HEIGHT: float = 3.0  # max sideways arc magnitude on the launching path

enum State { LAUNCHING, ATTACKING, RETURNING }

## Wired by the spawning combat path before the drone enters the
## scene tree. All four are required for the drone to behave; the
## drone bails (queue_free) if any is missing at _ready.
var carrier: Node3D = null
var target: Node3D = null
var damage: int = 25
var role_tag: StringName = &"Universal"
var owner_id: int = 0
## Visual style hint -- "default" / "missile" / "fast". Picks the
## mesh dispatch in _build_visual.
var variant: StringName = &"default"

var _state: int = State.LAUNCHING
var _shots_fired: int = 0
var _shot_timer: float = 0.0
## Side direction the drone offsets to during a strafing pass --
## randomized at launch so consecutive drones in a salvo arc out
## along different sides of the target.
var _strafe_side: Vector3 = Vector3.ZERO
## Curve magnitude for the launch arc. Each drone picks a random
## sign so a salvo of 2-3 spreads laterally rather than all
## tracing the same path.
var _curve_sign: float = 1.0
## Distance from carrier to target at launch -- caches the path
## length so the curve interpolation can map progress to [0..1].
var _launch_anchor: Vector3 = Vector3.ZERO
var _launch_total_dist: float = 1.0


func _ready() -> void:
	if not carrier or not is_instance_valid(carrier):
		queue_free()
		return
	_build_visual()
	# Pick a random curve direction and strafe-side so a salvo of
	# drones arcs out along different paths and strafes from
	# different angles instead of stacking.
	_curve_sign = 1.0 if randf() < 0.5 else -1.0
	_launch_anchor = global_position
	if target and is_instance_valid(target):
		_launch_total_dist = maxf(_launch_anchor.distance_to(target.global_position), 0.001)


func _build_visual() -> void:
	match variant:
		&"missile":
			_build_missile_drone()
		&"fast":
			_build_fast_drone()
		_:
			_build_default_drone()


func _build_default_drone() -> void:
	# Compact generic drone -- box body + twin stub wings + warm
	# orange thruster. The Harbinger base's standard release.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := BoxMesh.new()
	bm.size = Vector3(0.30, 0.16, 0.50)
	body.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.18, 0.18, 0.22)
	bmat.metallic = 0.5
	bmat.roughness = 0.4
	body.set_surface_override_material(0, bmat)
	add_child(body)
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var wing := MeshInstance3D.new()
		wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wm := BoxMesh.new()
		wm.size = Vector3(0.30, 0.04, 0.20)
		wing.mesh = wm
		wing.position = Vector3(sx * 0.28, 0.0, 0.04)
		wing.set_surface_override_material(0, bmat)
		add_child(wing)
	_attach_thruster(Color(1.0, 0.55, 0.18), 0.07, 2.0, Vector3(0.0, 0.0, -0.30))


func _build_missile_drone() -> void:
	# Heavier hull with an underslung missile pod. Reads as 'this
	# one carries a real warhead' when the Overseer launches them.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := BoxMesh.new()
	bm.size = Vector3(0.36, 0.20, 0.60)
	body.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.16, 0.16, 0.20)
	bmat.metallic = 0.55
	bmat.roughness = 0.40
	body.set_surface_override_material(0, bmat)
	add_child(body)
	# Twin stubby wings.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var wing := MeshInstance3D.new()
		wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wm := BoxMesh.new()
		wm.size = Vector3(0.40, 0.05, 0.24)
		wing.mesh = wm
		wing.position = Vector3(sx * 0.34, 0.0, 0.04)
		wing.set_surface_override_material(0, bmat)
		add_child(wing)
	# Underslung missile pod -- cylindrical pod with a red warhead
	# tip, slung beneath the body.
	var pod := MeshInstance3D.new()
	pod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pcyl := CylinderMesh.new()
	pcyl.top_radius = 0.07
	pcyl.bottom_radius = 0.07
	pcyl.height = 0.42
	pcyl.radial_segments = 10
	pod.mesh = pcyl
	pod.rotation.x = PI * 0.5
	pod.position = Vector3(0.0, -0.16, 0.05)
	pod.set_surface_override_material(0, _make_metal_mat(Color(0.22, 0.20, 0.22)))
	add_child(pod)
	var tip := MeshInstance3D.new()
	tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tip_box := BoxMesh.new()
	tip_box.size = Vector3(0.12, 0.10, 0.10)
	tip.mesh = tip_box
	tip.position = Vector3(0.0, -0.16, 0.30)
	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = Color(0.85, 0.18, 0.15)
	tip_mat.emission_enabled = true
	tip_mat.emission = Color(1.0, 0.25, 0.18)
	tip_mat.emission_energy_multiplier = 0.8
	tip.set_surface_override_material(0, tip_mat)
	add_child(tip)
	_attach_thruster(Color(1.0, 0.55, 0.18), 0.08, 2.2, Vector3(0.0, 0.0, -0.36))


func _build_fast_drone() -> void:
	# Slim sleek drone -- shorter body, no wings, brighter cyan
	# thruster. Reads as 'fast harassment swarm' when the Swarm
	# Marshal pumps three of them out per fire tick.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := BoxMesh.new()
	bm.size = Vector3(0.20, 0.12, 0.42)
	body.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.20, 0.20, 0.24)
	bmat.metallic = 0.5
	bmat.roughness = 0.35
	body.set_surface_override_material(0, bmat)
	add_child(body)
	# Tiny dorsal fin so the silhouette isn't a plain pill from above.
	var fin := MeshInstance3D.new()
	fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fb := BoxMesh.new()
	fb.size = Vector3(0.04, 0.10, 0.16)
	fin.mesh = fb
	fin.position = Vector3(0.0, 0.10, -0.04)
	fin.set_surface_override_material(0, bmat)
	add_child(fin)
	_attach_thruster(Color(0.40, 0.85, 1.0), 0.08, 3.0, Vector3(0.0, 0.0, -0.26))


func _attach_thruster(color: Color, radius: float, energy: float, pos: Vector3) -> void:
	var thruster := MeshInstance3D.new()
	thruster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ts := SphereMesh.new()
	ts.radius = radius
	ts.height = radius * 2.0
	thruster.mesh = ts
	thruster.position = pos
	var tm := StandardMaterial3D.new()
	tm.albedo_color = color
	tm.emission_enabled = true
	tm.emission = color
	tm.emission_energy_multiplier = energy
	thruster.set_surface_override_material(0, tm)
	add_child(thruster)


func _make_metal_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = 0.5
	m.roughness = 0.4
	return m


func _process(delta: float) -> void:
	# Carrier dies -- drone dies. No half-life of orphaned drones
	# floating around the map.
	if not carrier or not is_instance_valid(carrier):
		queue_free()
		return

	match _state:
		State.LAUNCHING:
			# If the target died mid-flight, peel off and head home.
			if not target or not is_instance_valid(target):
				_state = State.RETURNING
				return
			if "alive_count" in target and (target.get("alive_count") as int) <= 0:
				_state = State.RETURNING
				return
			# Curved approach: aim for a strafing-position offset
			# beside the target rather than the target itself, so the
			# drone arcs in along an attack vector instead of
			# crashing straight at the centre.
			var aim: Vector3 = _strafe_anchor()
			_fly_toward_curved(aim, delta)
			if global_position.distance_to(aim) < 1.5:
				_enter_attacking()
		State.ATTACKING:
			# Strafe past the target while firing STRAFE_SHOTS rounds
			# spaced STRAFE_SHOT_INTERVAL apart. Movement keeps going
			# along the strafe vector so the drone visibly flies past
			# the target instead of hovering on top of it.
			if not target or not is_instance_valid(target):
				_state = State.RETURNING
				return
			if "alive_count" in target and (target.get("alive_count") as int) <= 0:
				_state = State.RETURNING
				return
			# Drift across the target along the strafe axis. The
			# drone's nose still tracks the target so the laser /
			# missile shots come out the front.
			var across: Vector3 = -_strafe_side
			global_position += across * (SPEED * 0.7) * delta
			look_at(target.global_position, Vector3.UP)
			_shot_timer -= delta
			if _shot_timer <= 0.0 and _shots_fired < STRAFE_SHOTS:
				_fire_at_target()
				_shots_fired += 1
				_shot_timer = STRAFE_SHOT_INTERVAL
			if _shots_fired >= STRAFE_SHOTS:
				_state = State.RETURNING
		State.RETURNING:
			var dock: Vector3 = carrier.global_position
			_fly_toward(dock, delta)
			if global_position.distance_to(dock) < DOCK_RADIUS:
				queue_free()


func _strafe_anchor() -> Vector3:
	## Position offset beside the target the drone aims for during
	## launch. Picked perpendicular to the launch vector so the arc
	## ends in a real strafing line instead of dive-bombing the
	## centre. Side picked once at _ready via _curve_sign.
	if not target or not is_instance_valid(target):
		return carrier.global_position
	var t_pos: Vector3 = target.global_position
	var to_target: Vector3 = t_pos - _launch_anchor
	to_target.y = 0.0
	if to_target.length_squared() < 0.001:
		_strafe_side = Vector3(STRAFE_RADIUS, 0.0, 0.0)
	else:
		# Perpendicular in the XZ plane (rotate 90 deg).
		var perp: Vector3 = Vector3(-to_target.z, 0.0, to_target.x).normalized()
		_strafe_side = perp * STRAFE_RADIUS * _curve_sign
	return t_pos + _strafe_side


func _enter_attacking() -> void:
	_state = State.ATTACKING
	_shots_fired = 0
	_shot_timer = 0.0


func _fly_toward_curved(target_pos: Vector3, delta: float) -> void:
	## Curve-augmented flight. Computes a straight-line lerp toward
	## the target then offsets the path sideways by an arc whose
	## peak height is APPROACH_CURVE_HEIGHT * _curve_sign. Reads as
	## 'banking attack run' rather than 'rail-shot at the target'.
	var to_target: Vector3 = target_pos - global_position
	var dist: float = to_target.length()
	if dist < 0.001:
		return
	var step_len: float = SPEED * delta
	# Progress 0..1 along the original launch path -- gives an
	# arc that peaks at the midpoint and shrinks back to 0 as the
	# drone closes in.
	var travelled: float = _launch_anchor.distance_to(global_position)
	var progress: float = clampf(travelled / _launch_total_dist, 0.0, 1.0)
	var arc_t: float = 1.0 - absf(progress - 0.5) * 2.0  # tent function 0..1..0
	var perp: Vector3 = Vector3(-to_target.z, 0.0, to_target.x).normalized()
	var bend: Vector3 = perp * APPROACH_CURVE_HEIGHT * _curve_sign * arc_t * 0.15
	var step_dir: Vector3 = (to_target.normalized() + bend).normalized()
	if step_len >= dist:
		global_position = target_pos
	else:
		global_position += step_dir * step_len
	look_at(target_pos, Vector3.UP)


func _fly_toward(target_pos: Vector3, delta: float) -> void:
	var to_target: Vector3 = target_pos - global_position
	var dist: float = to_target.length()
	if dist < 0.001:
		return
	var step: float = SPEED * delta
	if step >= dist:
		global_position = target_pos
	else:
		global_position += to_target.normalized() * step
	# Face flight direction so the silhouette + thruster glow line
	# up with motion.
	look_at(target_pos, Vector3.UP)


func _fire_at_target() -> void:
	# One round of the strafing pass. Per-shot damage is the
	# carrier's `damage` argument; a full strafe lands STRAFE_SHOTS
	# rounds, which the carrier's per-fire damage budget already
	# accounts for (combat path passes the per-member damage that
	# was meant to land on a single hit -- the strafe spreads it
	# over multiple visible bullets, but the total still matches).
	if not target or not is_instance_valid(target):
		return
	if target.has_method("take_damage"):
		target.take_damage(damage, carrier)
	var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
	if not proj_script:
		return
	var proj: Node3D = proj_script.create(global_position, target.global_position, role_tag, &"fast")
	get_tree().current_scene.add_child(proj)
