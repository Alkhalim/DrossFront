class_name Projectile
extends Node3D
## Visual projectile. Missiles arc, bullets fly straight, beams are instant lines.

var target_pos: Vector3 = Vector3.ZERO
var start_pos: Vector3 = Vector3.ZERO
var speed: float = 40.0
var _mesh: MeshInstance3D = null
var _trail: MeshInstance3D = null

## Missile arc state.
var _is_missile: bool = false
var _flight_time: float = 0.0
var _total_flight_time: float = 1.0
var _arc_height: float = 4.0

const ROLE_COLORS: Dictionary = {
	&"AP": Color(1.0, 0.8, 0.2, 1.0),
	&"AA": Color(0.3, 0.7, 1.0, 1.0),
	&"Universal": Color(0.9, 0.6, 0.2, 1.0),
}

const ROF_STYLES: Dictionary = {
	&"single": "missile",
	&"slow": "missile",
	&"moderate": "bullet",
	&"fast": "bullet",
	&"volley": "missile",
	&"continuous": "beam",
}


static func create(from: Vector3, to: Vector3, role_tag: StringName, rof_tier: StringName = &"moderate") -> Projectile:
	var proj := Projectile.new()
	var fire_y: float = from.y + 1.0
	proj.start_pos = Vector3(from.x, fire_y, from.z)
	proj.target_pos = Vector3(to.x, to.y + 0.8, to.z)
	proj.global_position = proj.start_pos

	var color: Color = ROLE_COLORS.get(role_tag, Color(0.9, 0.6, 0.2, 1.0)) as Color
	var style: String = ROF_STYLES.get(rof_tier, "bullet") as String

	# Add slight random offset so squad projectiles don't perfectly overlap
	proj.target_pos += Vector3(randf_range(-0.3, 0.3), 0, randf_range(-0.3, 0.3))

	match style:
		"missile":
			proj._create_missile_mesh(color)
			proj._is_missile = true
			var dist: float = from.distance_to(to)
			proj._total_flight_time = maxf(dist / 12.0, 0.5)
			proj._arc_height = clampf(dist * 0.25, 2.0, 8.0)
		"beam":
			proj._create_beam_mesh(color, proj.start_pos, proj.target_pos)
			proj.speed = 999.0
		_:
			proj._create_bullet_mesh(color)
			# Faster bullets so the volley reads as actually shooting rather than
			# floating across the field — important now that Rook fires bursts.
			proj.speed = 95.0

	return proj


func _create_bullet_mesh(color: Color) -> void:
	# Slim slug shape rather than a round ball — a thin cylinder oriented
	# along the travel direction reads as a tracer round, not a cannonball.
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.05
	cyl.height = 0.34
	_mesh.mesh = cyl
	# Cylinder default axis is Y; rotate so the long axis aligns with the
	# projectile's local -Z (which look_at orients toward the target).
	_mesh.rotation.x = -PI / 2

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	_mesh.set_surface_override_material(0, mat)
	add_child(_mesh)


func _create_missile_mesh(color: Color) -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04   # nose
	cyl.bottom_radius = 0.1 # exhaust
	cyl.height = 0.4
	_mesh.mesh = cyl
	# Default cylinder height is along +Y. Rotate so it aligns with the
	# projectile's -Z (forward) — the nose then leads the trajectory and
	# look_at properly orients the body along the arc.
	_mesh.rotation.x = -PI / 2

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	_mesh.set_surface_override_material(0, mat)
	add_child(_mesh)

	# Exhaust trail — long thin cylinder behind the missile rather than a
	# small sphere. Extends ~1.5u trailing the body, with alpha
	# fading toward the tail for the classic rocket-trail read.
	_trail = MeshInstance3D.new()
	var trail_cyl := CylinderMesh.new()
	trail_cyl.top_radius = 0.02
	trail_cyl.bottom_radius = 0.12
	trail_cyl.height = 1.6
	_trail.mesh = trail_cyl
	# Cylinder default axis = +Y; rotate so the long axis runs along
	# local +Z (placed behind the missile in `_process`).
	_trail.rotation.x = PI / 2

	var trail_mat := StandardMaterial3D.new()
	trail_mat.albedo_color = Color(1.0, 0.6, 0.1, 0.7)
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_mat.emission_enabled = true
	trail_mat.emission = Color(1.0, 0.4, 0.0, 1.0)
	trail_mat.emission_energy_multiplier = 2.4
	_trail.set_surface_override_material(0, trail_mat)
	add_child(_trail)


func _create_beam_mesh(color: Color, from: Vector3, to: Vector3) -> void:
	var dir: Vector3 = to - from
	var length: float = dir.length()

	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.05, 0.05, maxf(length, 0.1))
	_mesh.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 5.0
	_mesh.set_surface_override_material(0, mat)

	var mid: Vector3 = (from + to) * 0.5
	global_position = mid
	if dir.length() > 0.1:
		look_at(to, Vector3.UP)

	add_child(_mesh)


func _process(delta: float) -> void:
	# Beam — instant, fade out
	if speed > 500.0:
		if _mesh:
			var mat: StandardMaterial3D = _mesh.get_surface_override_material(0) as StandardMaterial3D
			if mat:
				mat.albedo_color.a -= delta * 8.0
				if mat.albedo_color.a <= 0.0:
					queue_free()
					return
		else:
			queue_free()
		return

	# Missile — parabolic arc
	if _is_missile:
		_flight_time += delta
		var t: float = clampf(_flight_time / _total_flight_time, 0.0, 1.0)

		# Lerp XZ, parabolic Y
		var xz_pos: Vector3 = start_pos.lerp(target_pos, t)
		var arc_y: float = _arc_height * 4.0 * t * (1.0 - t)
		global_position = Vector3(xz_pos.x, xz_pos.y + arc_y, xz_pos.z)

		# Orient missile along velocity direction
		if t < 0.98:
			var next_t: float = clampf(t + 0.05, 0.0, 1.0)
			var next_xz: Vector3 = start_pos.lerp(target_pos, next_t)
			var next_arc: float = _arc_height * 4.0 * next_t * (1.0 - next_t)
			var next_pos := Vector3(next_xz.x, next_xz.y + next_arc, next_xz.z)
			if global_position.distance_to(next_pos) > 0.01:
				look_at(next_pos, Vector3.UP)

		# Trail behind missile. After look_at, basis.z is the world direction of
		# the projectile's local +Z (i.e. backward). The long-cylinder trail
		# pivots from its midpoint, so place its center 0.9u behind the
		# missile body and orient it along the body's basis.
		if _trail:
			_trail.global_position = global_position + global_basis.z.normalized() * 0.9
			_trail.global_basis = global_basis

		if t >= 1.0:
			_spawn_impact()
			queue_free()
		return

	# Bullet — straight line
	var to_target := target_pos - global_position
	var dist := to_target.length()

	if dist < 0.5:
		_spawn_impact()
		queue_free()
		return

	var direction := to_target / dist
	global_position += direction * speed * delta


func _spawn_impact() -> void:
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	flash.mesh = sphere
	flash.global_position = global_position

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.7, 0.2, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.1, 1.0)
	mat.emission_energy_multiplier = 5.0
	flash.set_surface_override_material(0, mat)

	get_tree().current_scene.add_child(flash)

	var timer := Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(flash.queue_free)
	flash.add_child(timer)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_impact"):
		audio.play_weapon_impact(global_position)
