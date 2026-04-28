class_name AIController
extends Node
## Simple AI opponent. Builds economy, produces units, sends attack waves.

enum AIState { SETUP, ECONOMY, ARMY, ATTACK, REBUILD }

@export var owner_id: int = 1

var _state: AIState = AIState.SETUP
var _state_timer: float = 0.0

var _hq: Node = null
var _foundry: Node = null
var _generator: Node = null
var _salvage_yard: Node = null
var _units: Array[Node] = []

var _player_hq_pos: Vector3 = Vector3.ZERO
var _ai_resource_manager: Node = null

## Passive income for AI (cheats slightly to keep pressure).
const AI_SALVAGE_TRICKLE: float = 12.0
const ECONOMY_DURATION: float = 45.0
const ARMY_DURATION: float = 40.0
const REBUILD_DURATION: float = 25.0
const WAVE_SIZE: int = 5

var _salvage_accumulator: float = 0.0


func _ready() -> void:
	# Defer setup to let scene finish loading
	call_deferred("_setup")


func _setup() -> void:
	# Find AI HQ
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if node.get("owner_id") == owner_id:
			if node.get("stats") and node.get("stats").get("building_id") == &"headquarters":
				_hq = node
				break

	# Find player HQ
	for node: Node in buildings:
		if node.get("owner_id") == 0:
			if node.get("stats") and node.get("stats").get("building_id") == &"headquarters":
				_player_hq_pos = node.global_position
				break

	# Find or create AI ResourceManager
	_ai_resource_manager = get_parent().get_node_or_null("AIResourceManager")

	if _hq:
		_state = AIState.ECONOMY
		_state_timer = 0.0


var _hq_destroyed: bool = false


func _process(delta: float) -> void:
	if _hq_destroyed:
		return
	if not _hq or not is_instance_valid(_hq):
		_hq_destroyed = true
		return

	# AI passive income
	if _ai_resource_manager and _ai_resource_manager.has_method("add_salvage"):
		_salvage_accumulator += AI_SALVAGE_TRICKLE * delta
		if _salvage_accumulator >= 1.0:
			var trickle: int = int(_salvage_accumulator)
			_salvage_accumulator -= float(trickle)
			_ai_resource_manager.add_salvage(trickle)

	# Clean dead units
	var i: int = _units.size() - 1
	while i >= 0:
		if not is_instance_valid(_units[i]):
			_units.remove_at(i)
		i -= 1

	_state_timer += delta

	match _state:
		AIState.ECONOMY:
			_process_economy()
		AIState.ARMY:
			_process_army()
		AIState.ATTACK:
			_process_attack()
		AIState.REBUILD:
			_process_rebuild()


var _generator_built: bool = false
var _foundry_built: bool = false
var _yard_built: bool = false


func _process_economy() -> void:
	# Place buildings once — don't respawn destroyed buildings
	if not _generator_built:
		_generator = _place_ai_building("res://resources/buildings/basic_generator.tres", Vector3(5, 0, 3))
		if _generator:
			_generator_built = true

	if not _foundry_built:
		_foundry = _place_ai_building("res://resources/buildings/basic_foundry.tres", Vector3(-5, 0, 3))
		if _foundry:
			_foundry_built = true

	if not _yard_built:
		_salvage_yard = _place_ai_building("res://resources/buildings/salvage_yard.tres", Vector3(0, 0, 6))
		if _salvage_yard:
			_yard_built = true

	if _state_timer >= ECONOMY_DURATION:
		_state = AIState.ARMY
		_state_timer = 0.0


func _process_army() -> void:
	# Queue units at foundry
	if _foundry and is_instance_valid(_foundry) and _foundry.get("is_constructed"):
		if _foundry.has_method("get_queue_size") and _foundry.get_queue_size() < 2:
			_queue_unit_at_foundry()

	# Track spawned AI units
	var all_units: Array[Node] = get_tree().get_nodes_in_group("owner_%d" % owner_id)
	_units.clear()
	for node: Node in all_units:
		if node.is_in_group("units") and is_instance_valid(node):
			var alive: int = node.get("alive_count")
			if alive > 0:
				_units.append(node)

	if _units.size() >= WAVE_SIZE or _state_timer >= ARMY_DURATION:
		_state = AIState.ATTACK
		_state_timer = 0.0


func _process_attack() -> void:
	# Command all AI units to attack-move toward player HQ
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		var combat: Node = node.get_node_or_null("CombatComponent")
		if combat and combat.has_method("command_attack_move"):
			if combat.get("attack_move_target") == Vector3.INF:
				combat.command_attack_move(_player_hq_pos)

	# If all units dead, rebuild
	if _units.is_empty():
		_state = AIState.REBUILD
		_state_timer = 0.0


func _process_rebuild() -> void:
	if _state_timer >= REBUILD_DURATION:
		_state = AIState.ECONOMY
		_state_timer = 0.0


func _place_ai_building(stats_path: String, offset: Vector3) -> Node:
	var bstats: BuildingStatResource = load(stats_path) as BuildingStatResource
	if not bstats:
		return null

	var scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var building: Node = scene.instantiate()
	building.set("stats", bstats)
	building.set("owner_id", owner_id)
	building.set("resource_manager", _ai_resource_manager)
	building.global_position = _hq.global_position + offset

	get_tree().current_scene.add_child(building)

	# Mark as instantly constructed
	building.set("is_constructed", true)
	if building.has_method("_apply_placeholder_shape"):
		building._apply_placeholder_shape()

	return building


func _queue_unit_at_foundry() -> void:
	if not _ai_resource_manager:
		return

	# Alternate between Rooks and Hounds
	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource
	var hound_stats: UnitStatResource = load("res://resources/units/anvil_hound.tres") as UnitStatResource

	# Prefer Rooks early, mix in Hounds
	var unit_stats: UnitStatResource = rook_stats
	if _units.size() >= 2 and hound_stats:
		if randi() % 3 == 0:
			unit_stats = hound_stats

	if not unit_stats:
		return

	# Check if AI can afford it
	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage >= unit_stats.cost_salvage:
		_ai_resource_manager.spend(unit_stats.cost_salvage, unit_stats.cost_fuel)
		_foundry.queue_unit(unit_stats)
