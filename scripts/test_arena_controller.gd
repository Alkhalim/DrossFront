class_name TestArenaController
extends Node3D
## Bootstraps the test arena: wires up resource manager, marks HQ as built, etc.

@export var buildable_buildings: Array[BuildingStatResource] = []

@onready var resource_manager: ResourceManager = $ResourceManager as ResourceManager


func _ready() -> void:
	# Mark the HQ as already constructed
	var hq: Building = $PlayerHQ as Building
	if hq:
		hq.is_constructed = true
		hq.resource_manager = resource_manager
		hq._apply_placeholder_shape()

	# Wire resource manager to all existing buildings
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		var building: Building = node as Building
		if building:
			building.resource_manager = resource_manager

	resource_manager.update_power()

	# Load buildable building stats and pass to SelectionManager
	var selection_mgr: SelectionManager = $SelectionManager as SelectionManager
	if selection_mgr:
		if buildable_buildings.is_empty():
			# Auto-load from resources/buildings if not set in inspector
			var stat_paths: Array[String] = [
				"res://resources/buildings/basic_foundry.tres",
				"res://resources/buildings/advanced_foundry.tres",
				"res://resources/buildings/salvage_yard.tres",
				"res://resources/buildings/basic_generator.tres",
				"res://resources/buildings/basic_armory.tres",
				"res://resources/buildings/gun_emplacement.tres",
			]
			for path: String in stat_paths:
				var stat: BuildingStatResource = load(path) as BuildingStatResource
				if stat:
					buildable_buildings.append(stat)
		selection_mgr.set_buildable_buildings(buildable_buildings)
