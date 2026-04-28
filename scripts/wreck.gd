class_name Wreck
extends StaticBody3D
## A destroyed unit's wreckage. Yields salvage when harvested by workers.

## Total salvage this wreck contains.
@export var salvage_value: int = 50

## Salvage remaining to be extracted.
var salvage_remaining: int = 0

## Visual size based on unit class.
var wreck_size: Vector3 = Vector3(1.0, 0.5, 1.0)


func _ready() -> void:
	add_to_group("wrecks")
	salvage_remaining = salvage_value
	collision_layer = 8

	# Create wreck visual — a flattened, darker version of the unit
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = wreck_size
	mesh.mesh = box
	mesh.position.y = wreck_size.y / 2.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.18, 0.15)
	mat.roughness = 1.0
	mesh.set_surface_override_material(0, mat)

	add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = wreck_size
	col.shape = shape
	col.position.y = wreck_size.y / 2.0
	add_child(col)


## Extract salvage. Returns the amount actually extracted.
func extract(amount: int) -> int:
	var extracted: int = mini(amount, salvage_remaining)
	salvage_remaining -= extracted
	if salvage_remaining <= 0:
		queue_free()
	return extracted


## Create a wreck from a destroyed unit's stats.
static func create_from_unit(unit_stats: UnitStatResource, pos: Vector3) -> Wreck:
	var wreck := Wreck.new()
	# Units yield 30-40% of salvage cost
	wreck.salvage_value = int(unit_stats.cost_salvage * 0.35)
	wreck.salvage_remaining = wreck.salvage_value

	# Size based on unit class
	match unit_stats.unit_class:
		&"engineer":
			wreck.wreck_size = Vector3(0.8, 0.3, 0.8)
		&"light":
			wreck.wreck_size = Vector3(1.0, 0.4, 1.0)
		&"medium":
			wreck.wreck_size = Vector3(1.5, 0.5, 1.5)
		&"heavy":
			wreck.wreck_size = Vector3(2.0, 0.6, 2.0)
		_:
			wreck.wreck_size = Vector3(1.0, 0.4, 1.0)

	wreck.global_position = pos
	return wreck
