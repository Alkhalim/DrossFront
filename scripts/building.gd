class_name Building
extends StaticBody3D
## Base building. Handles HP, power draw, production queue, and rally point.

signal unit_produced(unit_scene: PackedScene, spawn_point: Vector3)
signal destroyed
signal construction_complete

@export var stats: BuildingStatResource
@export var owner_faction: FactionResource

## Set during placement by the builder.
var is_constructed: bool = false
var current_hp: int = 0
var _construction_progress: float = 0.0

## Production queue — array of UnitStatResource.
var _build_queue: Array[UnitStatResource] = []
var _build_progress: float = 0.0

## Rally point for produced units.
var rally_point: Vector3 = Vector3.ZERO

## Reference to the game's resource manager (set externally).
var resource_manager: Node = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D as MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D as CollisionShape3D
@onready var _spawn_marker: Marker3D = $SpawnPoint as Marker3D

var _progress_bar: MeshInstance3D = null
var _progress_mat: StandardMaterial3D = null


func _ready() -> void:
	add_to_group("buildings")
	if stats:
		current_hp = stats.hp
		rally_point = global_position + Vector3(0, 0, stats.footprint_size.z + 2.0)
		_apply_placeholder_shape()

		# Add specialized components based on building type
		if stats.building_id == &"salvage_yard":
			var script: GDScript = load("res://scripts/salvage_yard_component.gd") as GDScript
			var yard: Node = script.new()
			yard.name = "SalvageYardComponent"
			add_child(yard)


func _apply_placeholder_shape() -> void:
	if not stats:
		return

	var box := BoxMesh.new()
	box.size = stats.footprint_size
	_mesh.mesh = box
	_mesh.position.y = stats.footprint_size.y / 2.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = stats.placeholder_color
	mat.roughness = 0.9
	if not is_constructed:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.5
	_mesh.set_surface_override_material(0, mat)

	var col_shape := BoxShape3D.new()
	col_shape.size = stats.footprint_size
	_collision.shape = col_shape
	_collision.position.y = stats.footprint_size.y / 2.0


func begin_construction() -> void:
	_construction_progress = 0.0
	is_constructed = false
	_apply_placeholder_shape()
	_create_progress_bar()


func advance_construction(amount: float) -> void:
	if is_constructed:
		return
	_construction_progress += amount
	_update_progress_bar()
	if _construction_progress >= stats.build_time:
		_finish_construction()


func get_construction_percent() -> float:
	if not stats or stats.build_time <= 0.0:
		return 1.0
	return clampf(_construction_progress / stats.build_time, 0.0, 1.0)


func _finish_construction() -> void:
	is_constructed = true
	_construction_progress = stats.build_time
	construction_complete.emit()
	_apply_placeholder_shape()
	_remove_progress_bar()


func _create_progress_bar() -> void:
	if _progress_bar:
		return

	_progress_bar = MeshInstance3D.new()
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(stats.footprint_size.x, 0.2, 0.4)
	_progress_bar.mesh = bar_mesh

	_progress_mat = StandardMaterial3D.new()
	_progress_mat.albedo_color = Color(0.1, 0.8, 0.1, 0.9)
	_progress_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_progress_mat.emission_enabled = true
	_progress_mat.emission = Color(0.1, 0.8, 0.1, 1.0)
	_progress_mat.emission_energy_multiplier = 1.0
	_progress_bar.set_surface_override_material(0, _progress_mat)

	_progress_bar.position = Vector3(0, stats.footprint_size.y + 0.5, 0)
	_progress_bar.scale.x = 0.01
	add_child(_progress_bar)


func _update_progress_bar() -> void:
	if not _progress_bar:
		return
	var pct: float = get_construction_percent()
	_progress_bar.scale.x = maxf(pct, 0.01)

	# Shift color from red to green as progress increases
	var r: float = 1.0 - pct
	var g: float = pct
	_progress_mat.albedo_color = Color(r, g, 0.1, 0.9)
	_progress_mat.emission = Color(r, g, 0.1, 1.0)


func _remove_progress_bar() -> void:
	if _progress_bar:
		_progress_bar.queue_free()
		_progress_bar = null
		_progress_mat = null
	var audio: AudioManager = get_tree().current_scene.get_node_or_null("AudioManager") as AudioManager
	if audio:
		audio.play_construction_complete()


func get_power_efficiency() -> float:
	if resource_manager and resource_manager.has_method("get_power_efficiency"):
		return resource_manager.get_power_efficiency()
	return 1.0


## Queue a unit for production. Returns true if successfully queued.
func queue_unit(unit_stats: UnitStatResource) -> bool:
	if not is_constructed:
		return false
	if not (unit_stats in stats.producible_units):
		return false
	_build_queue.append(unit_stats)
	return true


func _process(delta: float) -> void:
	if not is_constructed:
		return
	if _build_queue.is_empty():
		return

	var current_unit: UnitStatResource = _build_queue[0]
	var efficiency: float = get_power_efficiency()
	_build_progress += delta * efficiency

	if _build_progress >= current_unit.build_time:
		_build_progress = 0.0
		_build_queue.remove_at(0)
		_spawn_unit(current_unit)


func _spawn_unit(unit_stats: UnitStatResource) -> void:
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	var unit: Unit = unit_scene.instantiate() as Unit
	unit.stats = unit_stats

	var spawn_pos: Vector3
	if _spawn_marker:
		spawn_pos = _spawn_marker.global_position
	else:
		spawn_pos = global_position
	spawn_pos += Vector3(randf_range(-1.0, 1.0), 0, randf_range(-1.0, 1.0))

	get_tree().current_scene.get_node("Units").add_child(unit)
	unit.global_position = spawn_pos
	unit.command_move(rally_point)
	unit_produced.emit(unit_scene, spawn_pos)
	var audio: AudioManager = get_tree().current_scene.get_node_or_null("AudioManager") as AudioManager
	if audio:
		audio.play_production_complete()


func get_queue_size() -> int:
	return _build_queue.size()


func get_build_progress_percent() -> float:
	if _build_queue.is_empty():
		return 0.0
	var current_unit: UnitStatResource = _build_queue[0]
	return _build_progress / current_unit.build_time


var _is_selected: bool = false


func select_building() -> void:
	if _is_selected:
		return
	_is_selected = true
	_update_selection_visual()


func deselect_building() -> void:
	if not _is_selected:
		return
	_is_selected = false
	_update_selection_visual()


func _update_selection_visual() -> void:
	if not _mesh or not stats:
		return
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.9
	if _is_selected:
		mat.albedo_color = Color(stats.placeholder_color.r + 0.15, stats.placeholder_color.g + 0.2, stats.placeholder_color.b + 0.1)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.9, 0.2)
		mat.emission_energy_multiplier = 0.3
	else:
		mat.albedo_color = stats.placeholder_color
		if not is_constructed:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.5
	_mesh.set_surface_override_material(0, mat)


func take_damage(amount: int) -> void:
	current_hp -= amount
	if current_hp <= 0:
		current_hp = 0
		destroyed.emit()
		queue_free()
