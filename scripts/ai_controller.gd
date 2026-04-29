class_name AIController
extends Node
## AI opponent with varied behavior: builds economy, mixed army, defends and attacks.

enum AIState { SETUP, ECONOMY, ARMY, ATTACK, REBUILD }

@export var owner_id: int = 1

var _state: AIState = AIState.SETUP
var _state_timer: float = 0.0
var _wave_count: int = 0

var _hq: Node = null
var _foundry: Node = null
var _adv_foundry: Node = null
var _generator: Node = null
var _generator2: Node = null
var _salvage_yard: Node = null
var _turret: Node = null
var _units: Array[Node] = []

var _player_hq_pos: Vector3 = Vector3.ZERO
var _ai_resource_manager: Node = null
var _hq_destroyed: bool = false

## Building placement tracking — each placed once.
var _buildings_placed: Dictionary = {}

const AI_SALVAGE_TRICKLE: float = 15.0
const ECONOMY_DURATION: float = 40.0
const ARMY_DURATION: float = 35.0
const REBUILD_DURATION: float = 20.0
const INITIAL_WAVE_SIZE: int = 4
const DEFENDERS: int = 2

var _salvage_accumulator: float = 0.0

## Cached difficulty multipliers from the MatchSettings autoload (defaults to
## Normal if the autoload isn't present, e.g. when running the test arena
## scene directly from the editor).
var _econ_mul: float = 1.0
var _agg_mul: float = 1.0


func _enter_tree() -> void:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings:
		_econ_mul = settings.get_ai_economy_multiplier()
		_agg_mul = settings.get_ai_aggression_multiplier()


func _ready() -> void:
	call_deferred("_setup")


func _setup() -> void:
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if node.get("owner_id") == owner_id:
			if node.get("stats") and node.get("stats").get("building_id") == &"headquarters":
				_hq = node
				break

	for node: Node in buildings:
		if node.get("owner_id") == 0:
			if node.get("stats") and node.get("stats").get("building_id") == &"headquarters":
				_player_hq_pos = node.global_position
				break

	_ai_resource_manager = get_parent().get_node_or_null("AIResourceManager")

	if _hq:
		_state = AIState.ECONOMY
		_state_timer = 0.0


func _process(delta: float) -> void:
	if _hq_destroyed:
		return
	if not _hq or not is_instance_valid(_hq):
		_hq_destroyed = true
		return

	# Passive income — scaled by difficulty's economy multiplier so Easy
	# starves the AI a bit and Hard makes it tech up faster.
	if _ai_resource_manager and _ai_resource_manager.has_method("add_salvage"):
		_salvage_accumulator += AI_SALVAGE_TRICKLE * _econ_mul * delta
		if _salvage_accumulator >= 1.0:
			var trickle: int = int(_salvage_accumulator)
			_salvage_accumulator -= float(trickle)
			_ai_resource_manager.add_salvage(trickle)
			# Also give some fuel
			if _ai_resource_manager.has_method("add_fuel"):
				_ai_resource_manager.add_fuel(max(trickle / 3, 1))

	# Update unit list
	_units.clear()
	var all_nodes: Array[Node] = get_tree().get_nodes_in_group("owner_%d" % owner_id)
	for node: Node in all_nodes:
		if node.is_in_group("units") and is_instance_valid(node):
			if "alive_count" in node and node.get("alive_count") > 0:
				_units.append(node)

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


func _process_economy() -> void:
	# Phase 1: Basic buildings
	_try_place("generator", "res://resources/buildings/basic_generator.tres", Vector3(5, 0, 3))
	_try_place("foundry", "res://resources/buildings/basic_foundry.tres", Vector3(-5, 0, 3))
	_try_place("salvage_yard", "res://resources/buildings/salvage_yard.tres", Vector3(0, 0, 6))

	# Phase 2: After first wave, build advanced structures
	if _wave_count >= 1:
		_try_place("generator2", "res://resources/buildings/basic_generator.tres", Vector3(7, 0, 5))
		_try_place("turret", "res://resources/buildings/gun_emplacement.tres", Vector3(0, 0, -3))

	if _wave_count >= 2:
		_try_place("adv_foundry", "res://resources/buildings/advanced_foundry.tres", Vector3(-7, 0, 5))

	if _state_timer >= ECONOMY_DURATION:
		_state = AIState.ARMY
		_state_timer = 0.0


func _process_army() -> void:
	# Queue at basic foundry (validate not destroyed)
	if is_instance_valid(_foundry):
		_try_queue_at(_foundry)

	# Queue at advanced foundry if available
	if _wave_count >= 2 and is_instance_valid(_adv_foundry):
		_try_queue_at(_adv_foundry)

	# Wave size scales with the aggression multiplier — Hard sends bigger
	# pushes, Easy sends fewer units before attacking.
	var base_wave: float = float(INITIAL_WAVE_SIZE + _wave_count * 2) * _agg_mul
	var wave_size: int = maxi(int(round(base_wave)), 2)
	if _units.size() >= wave_size or _state_timer >= ARMY_DURATION / _agg_mul:
		_state = AIState.ATTACK
		_state_timer = 0.0


func _process_attack() -> void:
	# Keep some units near base as defenders
	var attack_units: Array[Node] = []
	var defender_count: int = 0

	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if defender_count < DEFENDERS:
			# Keep defenders near HQ
			var dist_to_hq: float = node.global_position.distance_to(_hq.global_position)
			if dist_to_hq < 25.0:
				defender_count += 1
				continue
		attack_units.append(node)

	# Send attackers toward player
	for node: Node in attack_units:
		if not is_instance_valid(node):
			continue
		var combat: Node = node.get_node_or_null("CombatComponent")
		if combat and combat.has_method("command_attack_move"):
			if combat.get("attack_move_target") == Vector3.INF:
				combat.command_attack_move(_player_hq_pos)

	# If most attackers are dead, rebuild
	if attack_units.size() <= 1:
		_wave_count += 1
		_state = AIState.REBUILD
		_state_timer = 0.0


func _process_rebuild() -> void:
	if _state_timer >= REBUILD_DURATION:
		_state = AIState.ECONOMY
		_state_timer = 0.0


func _try_place(key: String, stats_path: String, offset: Vector3) -> void:
	if _buildings_placed.has(key):
		return
	var bstats: BuildingStatResource = load(stats_path) as BuildingStatResource
	if not bstats:
		return

	# Find a placement that doesn't overlap an existing building. Hard-coded
	# offsets occasionally collide (e.g., generator + generator2), so we
	# spiral outward from the desired position until something fits.
	var desired: Vector3 = _hq.global_position + offset
	var pos: Vector3 = _find_clear_placement(desired, bstats.footprint_size)
	if pos == Vector3.INF:
		return  # retry next tick once the area clears

	var scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var building: Node = scene.instantiate()
	building.set("stats", bstats)
	building.set("owner_id", owner_id)
	building.set("resource_manager", _ai_resource_manager)
	building.global_position = pos

	get_tree().current_scene.add_child(building)
	building.set("is_constructed", true)
	if building.has_method("_apply_placeholder_shape"):
		building._apply_placeholder_shape()

	_buildings_placed[key] = true

	# Keep references for production
	match key:
		"foundry": _foundry = building
		"adv_foundry": _adv_foundry = building
		"generator": _generator = building
		"generator2": _generator2 = building
		"salvage_yard": _salvage_yard = building
		"turret": _turret = building


func _find_clear_placement(desired: Vector3, footprint: Vector3) -> Vector3:
	if _is_placement_clear(desired, footprint):
		return desired
	# Spiral search — expanding rings around the desired anchor.
	for ring: int in range(1, 8):
		for step: int in 12:
			var ang: float = float(step) / 12.0 * TAU
			var test_offset := Vector3(cos(ang), 0.0, sin(ang)) * float(ring) * 2.5
			var pos: Vector3 = desired + test_offset
			if _is_placement_clear(pos, footprint):
				return pos
	return Vector3.INF


## Required clear gap between adjacent buildings — keeps AI bases from looking
## visually packed even when AABBs technically don't overlap.
const PLACEMENT_GAP: float = 0.8


func _is_placement_clear(pos: Vector3, footprint: Vector3) -> bool:
	## AABB-vs-AABB against every existing building, with a small spacing
	## buffer so adjacent buildings don't touch edge-to-edge.
	var half_x: float = footprint.x * 0.5
	var half_z: float = footprint.z * 0.5
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.stats:
			continue
		var their_hx: float = b.stats.footprint_size.x * 0.5
		var their_hz: float = b.stats.footprint_size.z * 0.5
		var dx: float = absf(b.global_position.x - pos.x)
		var dz: float = absf(b.global_position.z - pos.z)
		if dx < (half_x + their_hx + PLACEMENT_GAP) and dz < (half_z + their_hz + PLACEMENT_GAP):
			return false
	return true


func _try_queue_at(foundry_node: Node) -> void:
	if not foundry_node or not is_instance_valid(foundry_node):
		return
	if not foundry_node.get("is_constructed"):
		return
	if not foundry_node.has_method("get_queue_size"):
		return
	if foundry_node.get_queue_size() >= 2:
		return

	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource
	var hound_stats: UnitStatResource = load("res://resources/units/anvil_hound.tres") as UnitStatResource
	var bulwark_stats: UnitStatResource = load("res://resources/units/anvil_bulwark.tres") as UnitStatResource

	# Choose unit type based on wave count and randomness
	var unit_stats: UnitStatResource = rook_stats
	var roll: int = randi() % 10

	if _wave_count >= 2 and bulwark_stats and roll < 2:
		unit_stats = bulwark_stats
	elif hound_stats and roll < 5:
		unit_stats = hound_stats

	if not unit_stats:
		return

	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage >= unit_stats.cost_salvage:
		_ai_resource_manager.spend(unit_stats.cost_salvage, unit_stats.cost_fuel)
		foundry_node.queue_unit(unit_stats)
