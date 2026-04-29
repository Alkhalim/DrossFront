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
	# Replenish engineers if we're running low — they're built at the HQ.
	_maintain_engineers()

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
		# Engineers stay home — they need to keep building, not march on the
		# enemy. Same rule the player follows by intuition.
		if node.has_method("get_builder") and node.get_builder():
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
	# AI must afford the building, just like the player. _ai_resource_manager
	# handles the spending inside builder.place_building.
	if _ai_resource_manager and _ai_resource_manager.has_method("can_afford_salvage"):
		if not _ai_resource_manager.can_afford_salvage(bstats.cost_salvage):
			return

	# AI now needs an engineer to build. If none are free, skip — the AI
	# will retry next tick (or after producing more engineers).
	var engineer: Node = _find_free_engineer()
	if not engineer:
		return

	# Find a placement that doesn't overlap a building, unit, fuel deposit,
	# or wreck. Hard-coded offsets occasionally collide; spiral outward from
	# the desired position until something fits.
	var desired: Vector3 = _hq.global_position + offset
	var pos: Vector3 = _find_clear_placement(desired, bstats.footprint_size)
	if pos == Vector3.INF:
		return  # retry next tick once the area clears

	# Use the same path as the player: BuilderComponent.place_building spends
	# resources, instantiates the building, calls begin_construction, and
	# assigns this engineer as its builder.
	var builder: Node = engineer.get_builder()
	if not builder or not builder.has_method("place_building"):
		return
	builder.place_building(bstats, pos, _ai_resource_manager)

	# Find the building we just placed so we can hold a reference for
	# production / state tracking.
	var building: Node = _find_building_at(pos, bstats.footprint_size)
	if not building:
		return
	_buildings_placed[key] = true

	# Keep references for production
	match key:
		"foundry": _foundry = building
		"adv_foundry": _adv_foundry = building
		"generator": _generator = building
		"generator2": _generator2 = building
		"salvage_yard": _salvage_yard = building
		"turret": _turret = building


func _maintain_engineers() -> void:
	## Keep at least one Ratchet engineer alive. Built at the HQ, just like
	## the player builds them. Without this the AI permanently loses build
	## capability if the player wipes out the starting engineers.
	if not is_instance_valid(_hq) or not _hq.get("is_constructed"):
		return
	var engineer_count: int = 0
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if node.has_method("get_builder") and node.get_builder():
			engineer_count += 1
	if engineer_count >= 1:
		return
	# Don't pile up Ratchets in the queue; only request one at a time.
	if _hq.has_method("get_queue_size") and _hq.get_queue_size() > 0:
		return
	var ratchet: UnitStatResource = load("res://resources/units/anvil_ratchet.tres") as UnitStatResource
	if not ratchet:
		return
	if not _ai_resource_manager:
		return
	var salvage: int = _ai_resource_manager.get("salvage")
	if salvage < ratchet.cost_salvage:
		return
	_ai_resource_manager.spend(ratchet.cost_salvage, ratchet.cost_fuel)
	_hq.queue_unit(ratchet)


func _find_free_engineer() -> Node:
	## Returns an idle AI engineer (Ratchet) — one with a builder component
	## that isn't currently constructing or moving to a build site.
	for node: Node in _units:
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue
		if "alive_count" in node and node.get("alive_count") <= 0:
			continue
		var builder: Node = node.get_builder() if node.has_method("get_builder") else null
		if not builder:
			continue
		# Read the target through Variant + is_instance_valid so a freed
		# Building reference (queue_free'd but still cached on the builder)
		# can't crash the cast. If it's freed, the engineer is treated as
		# free-to-build.
		var target_var: Variant = builder.get("_target_building")
		if target_var is Object and is_instance_valid(target_var):
			var target_node: Node = target_var as Node
			if target_node and not target_node.get("is_constructed"):
				continue  # Builder is genuinely busy on a live, unfinished site.
		return node
	return null


func _find_building_at(pos: Vector3, footprint: Vector3) -> Node:
	## Find the freshly-placed building (matching position within the
	## footprint half-extent) so _try_place can cache references.
	var half_x: float = footprint.x * 0.5 + 0.5
	var half_z: float = footprint.z * 0.5 + 0.5
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue
		var b: Node3D = node as Node3D
		if not b:
			continue
		if absf(b.global_position.x - pos.x) < half_x and absf(b.global_position.z - pos.z) < half_z:
			return node
	return null


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


## How far units / fuel deposits / wrecks must be from the placement footprint.
const UNIT_PLACEMENT_MARGIN: float = 0.5


func _is_placement_clear(pos: Vector3, footprint: Vector3) -> bool:
	## Same rules the player follows in SelectionManager — check against
	## buildings (with PLACEMENT_GAP buffer), units, fuel deposits, and
	## wrecks. Previously the AI only checked buildings, so it could happily
	## drop a foundry on top of the player's units.
	var half_x: float = footprint.x * 0.5
	var half_z: float = footprint.z * 0.5

	# Buildings (AABB-vs-AABB with spacing gap).
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

	# Units — friendly OR enemy. The AI shouldn't be allowed to drop a
	# foundry on top of player units mid-raid either.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var u: Node3D = node as Node3D
		if not u:
			continue
		var dx: float = absf(u.global_position.x - pos.x)
		var dz: float = absf(u.global_position.z - pos.z)
		if dx < (half_x + UNIT_PLACEMENT_MARGIN) and dz < (half_z + UNIT_PLACEMENT_MARGIN):
			return false

	# Fuel deposits and wrecks.
	for group_name: String in ["fuel_deposits", "wrecks"]:
		for node: Node in get_tree().get_nodes_in_group(group_name):
			if not is_instance_valid(node):
				continue
			var f: Node3D = node as Node3D
			if not f:
				continue
			var dx: float = absf(f.global_position.x - pos.x)
			var dz: float = absf(f.global_position.z - pos.z)
			if dx < (half_x + UNIT_PLACEMENT_MARGIN) and dz < (half_z + UNIT_PLACEMENT_MARGIN):
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
