class_name Projectile
extends Node3D
## Visual projectile traveling from origin to target. Purely cosmetic.

var target_pos: Vector3 = Vector3.ZERO
var speed: float = 40.0
var _mesh: MeshInstance3D = null
var _trail: MeshInstance3D = null

## Weapon role colors.
const ROLE_COLORS: Dictionary = {
	&"AP": Color(1.0, 0.8, 0.2, 1.0),
	&"AA": Color(0.3, 0.7, 1.0, 1.0),
	&"Universal": Color(0.9, 0.6, 0.2, 1.0),
}

## ROF determines visual style: slow = missile, fast = bullet, continuous = beam
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
	proj.global_position = from + Vector3(0, 1.0, 0)
	proj.target_pos = to + Vector3(0, 1.0, 0)

	var color: Color = ROLE_COLORS.get(role_tag, Color(0.9, 0.6, 0.2, 1.0)) as Color
	var style: String = ROF_STYLES.get(rof_tier, "bullet") as String

	match style:
		"missile":
			proj._create_missile_mesh(color)
			proj.speed = 25.0
		"beam":
			proj._create_beam_mesh(color, from, to)
			proj.speed = 999.0
		_:
			proj._create_bullet_mesh(color)
			proj.speed = 50.0

	return proj


func _create_bullet_mesh(color: Color) -> void:
	_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.12
	sphere.height = 0.24
	_mesh.mesh = sphere

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
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.12
	cyl.height = 0.5
	_mesh.mesh = cyl
	# Orient along direction of travel
	_mesh.rotation_degrees.x = 90.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	_mesh.set_surface_override_material(0, mat)
	add_child(_mesh)

	# Smoke trail
	_trail = MeshInstance3D.new()
	var trail_sphere := SphereMesh.new()
	trail_sphere.radius = 0.08
	trail_sphere.height = 0.16
	_trail.mesh = trail_sphere
	_trail.position.z = 0.3

	var trail_mat := StandardMaterial3D.new()
	trail_mat.albedo_color = Color(0.5, 0.5, 0.5, 0.4)
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail.set_surface_override_material(0, trail_mat)
	add_child(_trail)


func _create_beam_mesh(color: Color, from: Vector3, to: Vector3) -> void:
	var dir: Vector3 = to - from
	var length: float = dir.length()

	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.06, 0.06, maxf(length, 0.1))
	_mesh.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 5.0
	_mesh.set_surface_override_material(0, mat)

	# Position beam at midpoint, oriented along direction
	var mid: Vector3 = (from + to) * 0.5 + Vector3(0, 1.0, 0)
	global_position = mid
	if dir.length() > 0.1:
		look_at(to + Vector3(0, 1.0, 0), Vector3.UP)

	add_child(_mesh)


func _process(delta: float) -> void:
	if speed > 500.0:
		# Beam — instant, just fade and remove
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

	var to_target := target_pos - global_position
	var dist := to_target.length()

	if dist < 0.5:
		_spawn_impact()
		queue_free()
		return

	var direction := to_target / dist
	global_position += direction * speed * delta

	# Orient missile along travel direction
	if _mesh and speed < 40.0:
		look_at(target_pos, Vector3.UP)


func _spawn_impact() -> void:
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
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
