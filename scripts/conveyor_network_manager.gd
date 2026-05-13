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


## Returns a multiplier dict for the network the building participates in.
## All multipliers default to 1.0 (no effect). Spec tables (per 11_faction_mechanics.md):
##   Basic Foundry      x1 → -5%, x2 → -10%, x3 → -15% salvage on units
##   Advanced Foundry   x1 → -7%, x2 → -14%, x3 → -20% fuel on units
##   Aerodrome          x1 → +7%, x2 → +14%, x3 → +20% production speed
##   HQ in network      -15% Power consumption on OTHER buildings in net
## Invalid (overfull) networks return all-1.0.
func get_bonuses_for_building(building: Node) -> Dictionary:
	var defaults: Dictionary = {"salvage_mult": 1.0, "fuel_mult": 1.0, "speed_mult": 1.0, "power_mult": 1.0}
	if building == null or not is_instance_valid(building):
		return defaults
	var owner_id: int = building.get("owner_id")
	var mem: Dictionary = _membership.get(owner_id, {})
	if not (building in mem):
		return defaults
	var net_id: int = mem[building]
	var meta_dict: Dictionary = _network_meta.get(owner_id, {})
	var m: Dictionary = meta_dict.get(net_id, {})
	if m.is_empty() or not m.is_valid:
		return defaults
	var bid: StringName = (building.stats as BuildingStatResource).building_id
	var out: Dictionary = defaults.duplicate()
	match bid:
		&"basic_foundry":
			out.salvage_mult = 1.0 - 0.05 * float(m.basic_foundry)  # x1=.95, x2=.90, x3=.85
		&"advanced_foundry":
			out.fuel_mult = 1.0 - 0.07 * float(m.advanced_foundry)
			# Spec says x3 → -20% (not -21%); clamp to match table.
			if m.advanced_foundry >= 3:
				out.fuel_mult = 0.80
		&"aerodrome":
			out.speed_mult = 1.0 + 0.07 * float(m.aerodrome)
			if m.aerodrome >= 3:
				out.speed_mult = 1.20
		&"headquarters":
			pass  # HQ itself gets no own-type bonus; its bonus radiates outward.
	# HQ Power discount on OTHER network members.
	if m.hq > 0 and bid != &"headquarters":
		out.power_mult = 0.85  # -15%
	return out


## Compute the salvage/fuel cost the player should be charged when
## producing `unit_stats` at `target` building. Applies the network
## salvage/fuel multipliers. Speed bonus is applied separately inside
## Building._process via the speed_mult lookup.
func compute_unit_cost(target: Node, unit_stats: UnitStatResource) -> Dictionary:
	var b: Dictionary = get_bonuses_for_building(target)
	return {
		"salvage": int(round(float(unit_stats.cost_salvage) * b.salvage_mult)),
		"fuel": int(round(float(unit_stats.cost_fuel) * b.fuel_mult)),
	}


## Returns a human-readable summary of the network containing `building`.
## Keys:
##   - in_network: bool
##   - is_valid: bool                       (false when overfull)
##   - composition: String                  ("2× Basic Foundry, 1× Conveyor Node")
##   - bonuses: Array[String]               (one line per bonus, e.g., "Basic Foundries: -10% salvage")
##   - production_total: int
## Returns {in_network: false} if the building isn't part of any network yet.
func describe_network_for_building(building: Node) -> Dictionary:
	if building == null or not is_instance_valid(building):
		return {"in_network": false}
	var owner_id: int = building.get("owner_id")
	var mem: Dictionary = _membership.get(owner_id, {})
	if not (building in mem):
		return {"in_network": false}
	var net_id: int = mem[building]
	var meta_dict: Dictionary = _network_meta.get(owner_id, {})
	var m: Dictionary = meta_dict.get(net_id, {})
	if m.is_empty():
		return {"in_network": false}

	# Build composition string from non-zero type counts.
	var parts: PackedStringArray = PackedStringArray()
	if m.basic_foundry > 0:
		parts.append("%d× Basic Foundry" % m.basic_foundry)
	if m.advanced_foundry > 0:
		parts.append("%d× Advanced Foundry" % m.advanced_foundry)
	if m.aerodrome > 0:
		parts.append("%d× Aerodrome" % m.aerodrome)
	if m.hq > 0:
		parts.append("%d× HQ" % m.hq)
	if m.conveyor_node > 0:
		parts.append("%d× Conveyor Node" % m.conveyor_node)
	var composition: String = "  ".join(parts)

	# Build bonuses list using same math as get_bonuses_for_building.
	var bonuses: Array[String] = []
	if not m.is_valid:
		return {
			"in_network": true,
			"is_valid": false,
			"composition": composition,
			"bonuses": bonuses,
			"production_total": int(m.production_total),
		}
	if m.basic_foundry > 0:
		var pct: int = m.basic_foundry * 5
		bonuses.append("Basic Foundries: -%d%% salvage on produced units" % pct)
	if m.advanced_foundry > 0:
		var pct: int = m.advanced_foundry * 7
		if m.advanced_foundry >= 3:
			pct = 20
		bonuses.append("Advanced Foundries: -%d%% fuel on produced units" % pct)
	if m.aerodrome > 0:
		var pct: int = m.aerodrome * 7
		if m.aerodrome >= 3:
			pct = 20
		bonuses.append("Aerodromes: +%d%% production speed" % pct)
	if m.hq > 0:
		bonuses.append("HQ present: -15%% Power on non-HQ members")
	return {
		"in_network": true,
		"is_valid": true,
		"composition": composition,
		"bonuses": bonuses,
		"production_total": int(m.production_total),
	}


## Simulate placing a building with the given building_id at pos for
## owner_id. Returns true if doing so would create a connected component
## containing more than 3 production buildings (HQ + Foundries +
## Aerodrome count toward the cap; Conveyor Nodes do not).
##
## Used by SelectionManager to reject placements up-front. Cheap to call
## because participants per owner is small (≤50 typically).
func would_overfull_network(owner_id: int, pos: Vector3, building_id: StringName) -> bool:
	var counts_as_production: bool = building_id in [&"basic_foundry", &"advanced_foundry", &"aerodrome", &"headquarters"]
	# All network-eligible buildings share connection_range = 10 (set on
	# the four production buildings + the Conveyor Node). 10 world units is
	# roughly 1.5× a Basic Foundry's longest footprint axis, which keeps
	# Combine bases compact per the user's intent. If the per-building stat
	# diverges in the future, look it up here from the resource instead.
	var hypo_range: float = 10.0
	var hypo_extent: float = 3.0  # rough — exact footprint TBD per building; small enough not to falsely permit
	var participants: Array = _participants.get(owner_id, [])
	# Build adjacency for {participants ∪ hypo}.
	var nearby: Array = []  # participants connected to hypo
	for b in participants:
		if not is_instance_valid(b):
			continue
		var b_extent: float = _extent_of(b)
		var b_range: float = (b.stats as BuildingStatResource).connection_range
		var center_dist: float = b.global_position.distance_to(pos)
		var edge_dist: float = maxf(center_dist - b_extent - hypo_extent, 0.0)
		var allowed: float = minf(b_range, hypo_range)
		if edge_dist <= allowed:
			nearby.append(b)
	# Union the components of all nearby participants + the hypothetical.
	var seen_components: Dictionary = {}
	var production_count: int = 0
	if counts_as_production:
		production_count += 1
	var mem: Dictionary = _membership.get(owner_id, {})
	var meta: Dictionary = _network_meta.get(owner_id, {})
	for n in nearby:
		var net_id: int = mem.get(n, 0)
		if net_id == 0 or net_id in seen_components:
			continue
		seen_components[net_id] = true
		var m: Dictionary = meta.get(net_id, {})
		production_count += int(m.get("production_total", 0))
	return production_count > 3
