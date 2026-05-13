class_name ConveyorNetworkManager
extends Node
## Owns per-player Conveyor Network graphs. Networks are connected
## components of Conveyor Nodes + production buildings, computed using
## edge-to-edge distance ≤ each pair's min(connection_range). A network
## containing more than 3 production buildings is invalid and grants
## zero bonuses; engineer placement that would form such a component
## is rejected up-front by SelectionManager via would_overfull_network().
##
## Lifecycle:
##   - Each Building._ready that has connection_range > 0 calls
##     register(building) once construction completes.
##   - Each Building._exit_tree calls unregister(building).
##   - Both call sites trigger _recompute_for(owner_id), which rebuilds
##     adjacency and emits network_changed(owner_id) so consumers
##     (renderer, HUD) can update.

signal network_changed(owner_id: int)

## Per-owner registered participants. Holds all eligible buildings
## (Conveyor Nodes + production buildings + HQ) that exist for that
## owner. Plain Array, not Dictionary, because membership is small
## (≤ ~50 entries per player in any realistic match) and we iterate
## linearly during recompute.
var _participants: Dictionary = {}  # owner_id -> Array[Building]

## Per-owner adjacency: building -> Array[Building] within range.
## Rebuilt fully on each register/unregister; no incremental update.
## At realistic sizes (~50 buildings × ~10 neighbors max) this is
## O(n²) ≈ 2500 distance checks, well under 1 ms.
var _adjacency: Dictionary = {}  # owner_id -> {Building: Array[Building]}

## Per-owner network membership: building -> network_id (int, stable
## within an owner_id, monotonic). 0 means "no network" / orphan.
## Production buildings in invalid (overfull) components are also
## tagged with their component id but get zero bonus.
var _membership: Dictionary = {}  # owner_id -> {Building: int}

## Cached per-network composition: network_id -> {basic_foundry: int,
## advanced_foundry: int, aerodrome: int, hq: int, conveyor_node: int,
## production_total: int, is_valid: bool}. Rebuilt on recompute.
var _network_meta: Dictionary = {}  # owner_id -> {network_id: meta_dict}


static var _pending_instance: ConveyorNetworkManager = null


static func get_instance(scene_root: Node) -> ConveyorNetworkManager:
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null("ConveyorNetworkManager")
	if existing and existing is ConveyorNetworkManager:
		if _pending_instance == existing:
			_pending_instance = null
		return existing as ConveyorNetworkManager
	if _pending_instance != null and is_instance_valid(_pending_instance):
		return _pending_instance
	var mgr := ConveyorNetworkManager.new()
	mgr.name = "ConveyorNetworkManager"
	_pending_instance = mgr
	scene_root.add_child.call_deferred(mgr)
	return mgr


func register(building: Node) -> void:
	if building == null or not is_instance_valid(building):
		return
	var owner_id: int = building.get("owner_id")
	var arr: Array = _participants.get(owner_id, [])
	if building in arr:
		return
	arr.append(building)
	_participants[owner_id] = arr
	_recompute_for(owner_id)


func unregister(building: Node) -> void:
	if building == null:
		return
	var owner_id: int = building.get("owner_id")
	var arr: Array = _participants.get(owner_id, [])
	var idx: int = arr.find(building)
	if idx < 0:
		return
	arr.remove_at(idx)
	_participants[owner_id] = arr
	_recompute_for(owner_id)


func _recompute_for(owner_id: int) -> void:
	# Implemented in Task 7. Stub here so register/unregister don't error.
	network_changed.emit(owner_id)


## Stub — real implementation in Task 8.
func get_bonuses_for_building(_building: Node) -> Dictionary:
	return {"salvage_mult": 1.0, "fuel_mult": 1.0, "speed_mult": 1.0, "power_mult": 1.0}


## Stub — real implementation in Task 9.
func would_overfull_network(_owner_id: int, _pos: Vector3, _building_id: StringName) -> bool:
	return false
