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
	var participants: Array = _participants.get(owner_id, [])
	# Build adjacency: O(n²) edge-to-edge distance check.
	var adj: Dictionary = {}
	for b in participants:
		adj[b] = []
	for i in range(participants.size()):
		var a: Node = participants[i]
		if not is_instance_valid(a):
			continue
		var a_extent: float = _extent_of(a)
		var a_range: float = (a.stats as BuildingStatResource).connection_range
		for j in range(i + 1, participants.size()):
			var c: Node = participants[j]
			if not is_instance_valid(c):
				continue
			var c_extent: float = _extent_of(c)
			var c_range: float = (c.stats as BuildingStatResource).connection_range
			var center_dist: float = a.global_position.distance_to(c.global_position)
			var edge_dist: float = maxf(center_dist - a_extent - c_extent, 0.0)
			# Each side must reach within its own connection_range. Use
			# the min of the two ranges so an asymmetric pair (if ever
			# introduced) only connects when BOTH sides allow it.
			var allowed: float = minf(a_range, c_range)
			if edge_dist <= allowed:
				adj[a].append(c)
				adj[c].append(a)
	_adjacency[owner_id] = adj

	# Connected components via flood fill. Tag each participant with a
	# network_id; compute per-network composition meta.
	var membership: Dictionary = {}
	var meta: Dictionary = {}
	var next_id: int = 1
	for b in participants:
		if b in membership:
			continue
		var stack: Array = [b]
		var component: Array = []
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n in membership:
				continue
			membership[n] = next_id
			component.append(n)
			for neighbor in adj.get(n, []):
				if not (neighbor in membership):
					stack.append(neighbor)
		# Build meta for this component.
		var m: Dictionary = {
			"basic_foundry": 0, "advanced_foundry": 0, "aerodrome": 0,
			"hq": 0, "conveyor_node": 0, "production_total": 0,
			"is_valid": true,
		}
		for n in component:
			var bid: StringName = (n.stats as BuildingStatResource).building_id
			match bid:
				&"basic_foundry": m.basic_foundry += 1; m.production_total += 1
				&"advanced_foundry": m.advanced_foundry += 1; m.production_total += 1
				&"aerodrome": m.aerodrome += 1; m.production_total += 1
				&"headquarters": m.hq += 1; m.production_total += 1
				&"conveyor_node": m.conveyor_node += 1
		m.is_valid = m.production_total <= 3
		meta[next_id] = m
		next_id += 1
	_membership[owner_id] = membership
	_network_meta[owner_id] = meta
	network_changed.emit(owner_id)


func _extent_of(b: Node) -> float:
	var fs: Vector3 = (b.stats as BuildingStatResource).footprint_size
	return maxf(fs.x, fs.z) * 0.5


## Stub — real implementation in Task 8.
func get_bonuses_for_building(_building: Node) -> Dictionary:
	return {"salvage_mult": 1.0, "fuel_mult": 1.0, "speed_mult": 1.0, "power_mult": 1.0}


## Stub — real implementation in Task 9.
func would_overfull_network(_owner_id: int, _pos: Vector3, _building_id: StringName) -> bool:
	return false
