class_name BuilderComponent
extends Node
## Attached to engineer units. Handles building placement and construction.

signal construction_started(building: Building)
signal construction_finished(building: Building)

## How fast this engineer constructs (seconds of progress per real second).
@export var build_rate: float = 1.0

## Distance at which the engineer can construct.
const BUILD_RANGE: float = 4.0

var _target_building: Building = null
var _unit: Unit = null


func _ready() -> void:
	_unit = get_parent() as Unit
	if not _unit:
		push_error("BuilderComponent must be a child of a Unit node.")


func _physics_process(delta: float) -> void:
	if not _target_building or not is_instance_valid(_target_building):
		_target_building = null
		return

	if _target_building.is_constructed:
		_target_building = null
		_unit.stop()
		return

	var dist: float = _unit.global_position.distance_to(_target_building.global_position)
	if dist > BUILD_RANGE:
		# Move toward building
		_unit.command_move(_target_building.global_position)
		return

	# In range — stop moving and build
	_unit.stop()
	_target_building.advance_construction(build_rate * delta)

	if _target_building.is_constructed:
		construction_finished.emit(_target_building)
		_target_building = null


func start_building(building: Building) -> void:
	_target_building = building
	construction_started.emit(building)
	_unit.command_move(building.global_position)


func place_building(building_stats: BuildingStatResource, position: Vector3, resource_mgr: ResourceManager) -> Building:
	if not resource_mgr.can_afford_salvage(building_stats.cost_salvage):
		return null

	resource_mgr.spend(building_stats.cost_salvage, 0)

	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var building: Building = building_scene.instantiate() as Building
	building.stats = building_stats
	building.resource_manager = resource_mgr
	building.global_position = position
	building.begin_construction()

	get_tree().current_scene.add_child(building)

	# Recalculate power when building finishes
	building.construction_complete.connect(func() -> void: resource_mgr.update_power())

	start_building(building)
	return building
