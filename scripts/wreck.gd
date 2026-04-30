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

	_build_wreck_visuals()

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = wreck_size
	col.shape = shape
	col.position.y = wreck_size.y / 2.0
	add_child(col)


## Class buckets keyed off the wreck's horizontal extent. Each class gets a
## distinct base color, accent color, and number of debris chunks so a
## glance reads "small scrap pile" vs "Bulwark hull plate" vs "Apex
## carcass" without needing the size cue alone.
##
## These are `var` rather than `const` because GDScript's compile-time
## const evaluator chokes on `Color()` constructor calls inside Dictionary
## literals — and that parse failure used to cascade through `Building`
## (and every class that referenced it) all the way to `BuilderComponent`.
var _WRECK_CLASS_LIGHT: Dictionary = {
	"max_extent": 1.0,
	"base":   Color(0.22, 0.15, 0.09, 1.0),
	"accent": Color(0.55, 0.30, 0.13, 1.0),
	"chunks": 2,
}
var _WRECK_CLASS_MEDIUM: Dictionary = {
	"max_extent": 1.6,
	"base":   Color(0.20, 0.13, 0.08, 1.0),
	"accent": Color(0.62, 0.34, 0.16, 1.0),
	"chunks": 3,
}
var _WRECK_CLASS_HEAVY: Dictionary = {
	"max_extent": 2.2,
	"base":   Color(0.18, 0.12, 0.07, 1.0),
	"accent": Color(0.70, 0.40, 0.18, 1.0),
	"chunks": 4,
}
var _WRECK_CLASS_APEX: Dictionary = {
	"max_extent": 1000000.0,
	"base":   Color(0.22, 0.14, 0.08, 1.0),
	"accent": Color(0.85, 0.55, 0.20, 1.0),
	"chunks": 6,
}


func _classify() -> Dictionary:
	var ext: float = maxf(wreck_size.x, wreck_size.z)
	if ext < _WRECK_CLASS_LIGHT["max_extent"]:
		return _WRECK_CLASS_LIGHT
	if ext < _WRECK_CLASS_MEDIUM["max_extent"]:
		return _WRECK_CLASS_MEDIUM
	if ext < _WRECK_CLASS_HEAVY["max_extent"]:
		return _WRECK_CLASS_HEAVY
	return _WRECK_CLASS_APEX


func _build_wreck_visuals() -> void:
	var spec: Dictionary = _classify()
	var base_color: Color = spec["base"] as Color
	var accent_color: Color = spec["accent"] as Color
	var chunk_count: int = spec["chunks"] as int

	# Tilt the whole wreck a few degrees off-axis so it doesn't read as a
	# tidy cube on the ground. Random per instance.
	rotation.y = randf_range(0.0, TAU)

	# Main twisted-hull mass — a flattened box with a slight roll/pitch so
	# corners poke up unevenly.
	var hull := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = wreck_size
	hull.mesh = box
	hull.position.y = wreck_size.y * 0.5
	hull.rotation.x = randf_range(-0.18, 0.18)
	hull.rotation.z = randf_range(-0.18, 0.18)
	hull.set_surface_override_material(0, _make_wreck_material(base_color))
	add_child(hull)

	# Debris chunks — small boxes scattered around the main hull at random
	# rotations. Some get the rust-accent material to break up the dark
	# silhouette and read as scorched/torn metal.
	var max_extent: float = maxf(wreck_size.x, wreck_size.z)
	for i: int in chunk_count:
		var chunk := MeshInstance3D.new()
		var chunk_box := BoxMesh.new()
		var sx: float = randf_range(0.18, 0.32) * max_extent
		var sy: float = randf_range(0.20, 0.45) * wreck_size.y * 1.6
		var sz: float = randf_range(0.18, 0.32) * max_extent
		chunk_box.size = Vector3(sx, sy, sz)
		chunk.mesh = chunk_box
		var off_radius: float = max_extent * randf_range(0.35, 0.55)
		var ang: float = randf_range(0.0, TAU)
		chunk.position = Vector3(
			cos(ang) * off_radius,
			sy * 0.5 + randf_range(0.0, wreck_size.y * 0.4),
			sin(ang) * off_radius,
		)
		chunk.rotation = Vector3(
			randf_range(-0.5, 0.5),
			randf_range(0.0, TAU),
			randf_range(-0.5, 0.5),
		)
		var color: Color = accent_color if randf() < 0.4 else base_color
		# Occasional darker scorch chunk so the palette has 3 readable tones.
		if randf() < 0.25:
			color = color.darkened(0.4)
		chunk.set_surface_override_material(0, _make_wreck_material(color))
		add_child(chunk)


func _make_wreck_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	m.metallic = 0.15
	return m


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
