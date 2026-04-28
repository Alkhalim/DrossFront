class_name TestArenaController
extends Node3D
## Bootstraps the test arena: player base, AI opponent, resource wiring.

@export var buildable_buildings: Array[BuildingStatResource] = []

@onready var resource_manager: ResourceManager = $ResourceManager as ResourceManager


func _ready() -> void:
	_setup_player()
	_setup_ai()
	_setup_fuel_deposits()
	_setup_buildable_buildings()


func _setup_player() -> void:
	# Mark the HQ as already constructed
	var hq: Building = $PlayerHQ as Building
	if hq:
		hq.owner_id = 0
		hq.is_constructed = true
		hq.resource_manager = resource_manager
		hq._apply_placeholder_shape()

	# Wire resource manager to all player buildings
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		var building: Building = node as Building
		if building and building.owner_id == 0:
			building.resource_manager = resource_manager

	resource_manager.update_power()


func _setup_ai() -> void:
	# Create AI resource manager
	var ai_res := ResourceManager.new()
	ai_res.name = "AIResourceManager"
	ai_res.salvage = 500
	add_child(ai_res)

	# Spawn AI HQ on the opposite side of the map
	var hq_stats: BuildingStatResource = load("res://resources/buildings/headquarters.tres") as BuildingStatResource
	if not hq_stats:
		return

	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var ai_hq: Building = building_scene.instantiate() as Building
	ai_hq.stats = hq_stats
	ai_hq.owner_id = 1
	ai_hq.resource_manager = ai_res
	ai_hq.global_position = Vector3(0, 0, -60)
	add_child(ai_hq)
	ai_hq.is_constructed = true
	ai_hq._apply_placeholder_shape()

	# Spawn a couple starting AI units near their HQ
	var ratchet_stats: UnitStatResource = load("res://resources/units/anvil_ratchet.tres") as UnitStatResource
	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource

	_spawn_ai_unit(ratchet_stats, Vector3(-3, 0, -55))
	_spawn_ai_unit(ratchet_stats, Vector3(3, 0, -55))
	_spawn_ai_unit(rook_stats, Vector3(-2, 0, -52))
	_spawn_ai_unit(rook_stats, Vector3(2, 0, -52))

	# Create AI controller
	var ai_script: GDScript = load("res://scripts/ai_controller.gd") as GDScript
	var ai_ctrl: Node = ai_script.new()
	ai_ctrl.name = "AIController"
	ai_ctrl.set("owner_id", 1)
	add_child(ai_ctrl)


func _spawn_ai_unit(unit_stats: UnitStatResource, pos: Vector3) -> void:
	if not unit_stats:
		return
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	var unit: Unit = unit_scene.instantiate() as Unit
	unit.stats = unit_stats
	unit.owner_id = 1
	var units_node: Node = get_node_or_null("Units")
	if units_node:
		units_node.add_child(unit)
	else:
		add_child(unit)
	unit.global_position = pos


func _setup_fuel_deposits() -> void:
	var deposit_script: GDScript = load("res://scripts/fuel_deposit.gd") as GDScript
	if not deposit_script:
		return

	# Two deposits roughly equidistant from both HQs
	var positions: Array[Vector3] = [
		Vector3(25, 0, -30),
		Vector3(-25, 0, -30),
	]

	for pos: Vector3 in positions:
		var deposit: Node3D = deposit_script.new()
		deposit.global_position = pos
		add_child(deposit)


func _setup_buildable_buildings() -> void:
	var selection_mgr: SelectionManager = $SelectionManager as SelectionManager
	if not selection_mgr:
		return

	if buildable_buildings.is_empty():
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
