class_name BuilderComponent
extends Node
## Attached to engineer units. Handles building placement and construction.

signal construction_started(building: Building)
signal construction_finished(building: Building)

## How fast this engineer constructs (seconds of progress per real second).
@export var build_rate: float = 1.0

## Clearance the engineer needs from the building edge to start working.
## Distance is measured from the building's edge (footprint half-extent), not its
## center, so big buildings still have a workable construction perimeter.
const BUILD_BUFFER: float = 2.5

var _target_building: Building = null
var _unit: Unit = null


func _ready() -> void:
	_unit = get_parent() as Unit
	if not _unit:
		push_error("BuilderComponent must be a child of a Unit node.")


func _physics_process(delta: float) -> void:
	if not _target_building or not is_instance_valid(_target_building):
		_target_building = null
		_set_build_anim(false)
		return

	if _target_building.is_constructed:
		_target_building = null
		_unit.stop()
		_set_build_anim(false)
		return

	var dist: float = _unit.global_position.distance_to(_target_building.global_position)
	var build_max: float = _build_max_distance()

	if dist > build_max:
		# Move toward an approach point just outside the building edge facing us,
		# rather than the building center (which sits inside its nav obstacle and
		# would trap the agent oscillating around the edge).
		_unit.command_move(_approach_point())
		_set_build_anim(false)
		return

	# In range — stop moving and build
	_unit.stop()
	_target_building.advance_construction(build_rate * delta)
	# Only animate when the foundation is actually progressing (it can be
	# blocked by units standing inside the footprint).
	_set_build_anim(not _target_building.is_constructed and _target_building._is_foundation_clear())

	if _target_building.is_constructed:
		construction_finished.emit(_target_building)
		_target_building = null
		_set_build_anim(false)


func _set_build_anim(active: bool) -> void:
	if _unit and "is_building" in _unit:
		_unit.is_building = active


func start_building(building: Building) -> void:
	_target_building = building
	construction_started.emit(building)
	_unit.command_move(_approach_point())


func _build_max_distance() -> float:
	## Engineer is "in range" when within BUILD_BUFFER of the building's edge.
	if not _target_building or not _target_building.stats:
		return BUILD_BUFFER
	var footprint: Vector3 = _target_building.stats.footprint_size
	var extent: float = maxf(footprint.x, footprint.z) * 0.5
	return extent + BUILD_BUFFER


func _approach_point() -> Vector3:
	## A point just outside the building edge on the side facing the engineer.
	if not _target_building:
		return _unit.global_position
	var center: Vector3 = _target_building.global_position
	var to_unit: Vector3 = _unit.global_position - center
	to_unit.y = 0.0
	if to_unit.length_squared() < 0.01:
		# Engineer is already on top of the building — pick any side.
		to_unit = Vector3(1, 0, 0)
	var extent: float = 0.0
	if _target_building.stats:
		var fs: Vector3 = _target_building.stats.footprint_size
		extent = maxf(fs.x, fs.z) * 0.5
	# Approach target sits one buffer-radius outside the edge.
	return center + to_unit.normalized() * (extent + BUILD_BUFFER * 0.5)


func cancel_build() -> void:
	## Called by the player issuing a non-build command (move/attack) so the
	## builder doesn't immediately drag the unit back to the construction site.
	_target_building = null


func place_building(building_stats: BuildingStatResource, position: Vector3, resource_mgr: ResourceManager) -> Building:
	if not resource_mgr.can_afford_salvage(building_stats.cost_salvage):
		return null

	resource_mgr.spend(building_stats.cost_salvage, 0)

	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var building: Building = building_scene.instantiate() as Building
	building.stats = building_stats
	building.resource_manager = resource_mgr
	building.global_position = position

	get_tree().current_scene.add_child(building)

	building.begin_construction()

	# Recalculate power when building finishes
	building.construction_complete.connect(func() -> void: resource_mgr.update_power())

	start_building(building)
	return building
