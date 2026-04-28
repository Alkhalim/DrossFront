class_name Projectile
extends Node3D
## Simple visual projectile that travels from origin to target position.
## No physics — purely cosmetic. Frees itself on arrival.

var target_pos: Vector3 = Vector3.ZERO
var speed: float = 40.0
var _mesh: MeshInstance3D = null

## Color based on weapon role.
const ROLE_COLORS: Dictionary = {
	&"AP": Color(1.0, 0.8, 0.2, 1.0),
	&"AA": Color(0.3, 0.7, 1.0, 1.0),
	&"Universal": Color(0.9, 0.6, 0.2, 1.0),
}


static func create(from: Vector3, to: Vector3, role_tag: StringName) -> Projectile:
	var proj := Projectile.new()
	proj.global_position = from + Vector3(0, 1.0, 0)
	proj.target_pos = to + Vector3(0, 1.0, 0)

	# Create mesh
	proj._mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	proj._mesh.mesh = sphere

	var mat := StandardMaterial3D.new()
	var color: Color = ROLE_COLORS.get(role_tag, Color(0.9, 0.6, 0.2, 1.0)) as Color
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	proj._mesh.set_surface_override_material(0, mat)
	proj.add_child(proj._mesh)

	return proj


func _process(delta: float) -> void:
	var to_target := target_pos - global_position
	var dist := to_target.length()

	if dist < 0.5:
		_spawn_impact()
		queue_free()
		return

	var direction := to_target / dist
	global_position += direction * speed * delta


func _spawn_impact() -> void:
	# Brief flash at impact point
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.4
	sphere.height = 0.8
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

	# Auto-remove after short delay
	var timer := Timer.new()
	timer.wait_time = 0.12
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(flash.queue_free)
	flash.add_child(timer)
