class_name MeridianContractsManager
extends Node
## Owns per-player Meridian contract pools. Contracts gate every
## Meridian unit order: ordering a unit deducts `unit_stats.contract_cost`
## from the owner's pool; orders are rejected when the pool would go
## negative. Contracts regenerate over time, faster the more mesh-provider
## coverage area the owner has deployed (Task 15).
##
## Lifecycle:
##   - Created once per scene by get_instance(scene_root).
##   - Players are registered lazily when first queried; pool starts at 1.
##   - _process drives the regen tick.

signal contracts_changed(owner_id: int, current: int, maximum: int)

const MAX_CONTRACTS: int = 8
const BASELINE_REGEN_INTERVAL: float = 18.0  # seconds per +1 contract (no mesh)
const MIN_REGEN_INTERVAL: float = 2.0        # floor — heavy mesh investment cap

## Per-owner current count. Capped at MAX_CONTRACTS.
var _contracts: Dictionary = {}  # owner_id -> int
## Per-owner regen accumulator (seconds since last +1).
var _regen_accum: Dictionary = {}  # owner_id -> float

## Per-owner Intelligence Network tier. 0 = no Intel Network built;
## 1 = Intel Network constructed (default); 2/3 = upgrade tiers
## researched (Task 14). Used by Task 13 to scale HQ parallel
## production slots (2 / 3 / 4 slots at tier 0/1/2 — task spec used
## to be 1/2/3 per the doc, but user decision 2026-05-13 bumped the
## floor so even Meridian's pre-Intel-Network HQ has 2 slots).
##
## Persisted explicitly via `set_intel_network_tier` (Task 14 upgrade
## UI). Reads call `get_intel_network_tier(owner_id)` which
## auto-derives "tier 1 if Intel Network exists, else 0" when no
## explicit upgrade has been recorded.
var _intel_tier: Dictionary = {}  # owner_id -> int

static var _pending_instance: MeridianContractsManager = null


static func get_instance(scene_root: Node) -> MeridianContractsManager:
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null("MeridianContractsManager")
	if existing and existing is MeridianContractsManager:
		if _pending_instance == existing:
			_pending_instance = null
		return existing as MeridianContractsManager
	if _pending_instance != null and is_instance_valid(_pending_instance):
		return _pending_instance
	var mgr := MeridianContractsManager.new()
	mgr.name = "MeridianContractsManager"
	_pending_instance = mgr
	scene_root.add_child.call_deferred(mgr)
	return mgr


func _ensure_owner(owner_id: int) -> void:
	if not (owner_id in _contracts):
		_contracts[owner_id] = 1  # starts at 1; grows via regen up to MAX_CONTRACTS
		_regen_accum[owner_id] = 0.0


func get_contracts(owner_id: int) -> int:
	_ensure_owner(owner_id)
	return _contracts[owner_id]


func get_max_contracts(_owner_id: int) -> int:
	return MAX_CONTRACTS


## Cached scan result to avoid re-walking groups for every owner every tick.
## Map: owner_id -> {interval: float, expires_at_ms: int}
var _interval_cache: Dictionary = {}
const _INTERVAL_CACHE_MS: int = 250  # rescan ~4Hz; mesh topology shifts slowly


## Returns the current regen interval in seconds for this owner —
## baseline minus area-based mesh reductions, clamped at MIN_REGEN_INTERVAL.
## Bigger contiguous coverage area = faster regen. Enemy presence inside
## the mesh also gives a small bonus (intelligence value of contested space).
func get_regen_interval(owner_id: int) -> float:
	var now: int = Time.get_ticks_msec()
	var cached: Dictionary = _interval_cache.get(owner_id, {})
	if not cached.is_empty() and cached.get("expires_at_ms", 0) > now:
		return cached.interval
	var interval: float = _scan_regen_interval(owner_id)
	_interval_cache[owner_id] = {"interval": interval, "expires_at_ms": now + _INTERVAL_CACHE_MS}
	return interval


func _scan_regen_interval(owner_id: int) -> float:
	var tree: SceneTree = get_tree()
	if tree == null:
		return BASELINE_REGEN_INTERVAL

	# Compute total mesh coverage area for this owner.
	# Approximation: sum of (pi * r^2) for each mesh-providing building/unit.
	# Overlaps are NOT subtracted — this is already a heuristic and exact
	# area-of-union is expensive. Player intuition: "bigger network = better".
	var total_area: float = 0.0
	for b in tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(b) or int(b.get("owner_id")) != owner_id:
			continue
		if not bool(b.get("is_constructed")):
			continue
		var s: Resource = b.get("stats")
		if s == null:
			continue
		var radius: float = float(s.get("mesh_provider_radius"))
		if radius <= 0.0:
			continue
		total_area += PI * radius * radius
	for u in tree.get_nodes_in_group("units"):
		if not is_instance_valid(u) or int(u.get("owner_id")) != owner_id:
			continue
		var us: Resource = u.get("stats")
		if us == null:
			continue
		var radius_unit: float = float(us.get("mesh_provider_radius"))
		if radius_unit <= 0.0:
			continue
		total_area += PI * radius_unit * radius_unit

	# Enemy-presence bonus: small per-provider reduction when enemies are
	# detected inside that provider's radius (intelligence value of contested mesh).
	var enemies: Array = []
	for u in tree.get_nodes_in_group("units"):
		if is_instance_valid(u) and int(u.get("owner_id")) != owner_id:
			enemies.append(u)
	for b2 in tree.get_nodes_in_group("buildings"):
		if is_instance_valid(b2) and int(b2.get("owner_id")) != owner_id:
			enemies.append(b2)
	var enemies_in_mesh: int = 0
	for b in tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(b) or int(b.get("owner_id")) != owner_id:
			continue
		if not bool(b.get("is_constructed")):
			continue
		var s: Resource = b.get("stats")
		if s == null:
			continue
		var radius: float = float(s.get("mesh_provider_radius"))
		if radius <= 0.0:
			continue
		var radius_sq: float = radius * radius
		var p_pos: Vector3 = (b as Node3D).global_position
		for e in enemies:
			if not is_instance_valid(e):
				continue
			var d_sq: float = p_pos.distance_squared_to((e as Node3D).global_position)
			if d_sq <= radius_sq:
				enemies_in_mesh += 1
				break  # count each provider at most once

	# Calibrated so:
	#   No mesh:                  interval = 18.0 (baseline)
	#   Modest mesh (~766 m^2):   -2.7s → ~15.3s
	#   Strong mesh (~2500 m^2):  -8.8s → ~9.2s
	#   Full saturation (~5000):  -17.5s → clamped at 2.0 (MIN_REGEN_INTERVAL)
	# Enemy presence: +0.5s reduction per provider with enemies (cap at 3 providers).
	const AREA_TO_REDUCTION: float = 0.0035  # seconds reduction per square world unit
	const ENEMY_REDUCTION_PER_PROVIDER: float = 0.5
	const MAX_ENEMY_BONUS: float = 1.5
	var area_reduction: float = total_area * AREA_TO_REDUCTION
	var enemy_reduction: float = mini(enemies_in_mesh, 3) * ENEMY_REDUCTION_PER_PROVIDER
	enemy_reduction = minf(enemy_reduction, MAX_ENEMY_BONUS)
	var interval: float = BASELINE_REGEN_INTERVAL - area_reduction - enemy_reduction
	return maxf(interval, MIN_REGEN_INTERVAL)


## Fraction of the way to the next contract. 0.0 = just ticked, 1.0 =
## about to grant. Used by the HUD to render a progress bar so the
## player can see the regen ticking in real time.
func get_regen_progress(owner_id: int) -> float:
	_ensure_owner(owner_id)
	if _contracts[owner_id] >= MAX_CONTRACTS:
		return 0.0
	var interval: float = get_regen_interval(owner_id)
	if interval <= 0.0:
		return 0.0
	return clampf(_regen_accum[owner_id] / interval, 0.0, 1.0)


## Seconds until the next contract regenerates. Returns 0.0 when the
## pool is already at MAX_CONTRACTS.
func get_seconds_to_next_contract(owner_id: int) -> float:
	_ensure_owner(owner_id)
	if _contracts[owner_id] >= MAX_CONTRACTS:
		return 0.0
	var interval: float = get_regen_interval(owner_id)
	return maxf(interval - _regen_accum[owner_id], 0.0)


## True if `owner_id` has at least `cost` contracts. Used for build-menu
## affordability + order rejection. Does NOT deduct.
func can_afford(owner_id: int, cost: int) -> bool:
	_ensure_owner(owner_id)
	return _contracts[owner_id] >= cost


## Deducts `cost` from owner's pool. Returns true on success, false if
## insufficient. Caller should can_afford() first; this is the single
## deduction point so the order/spend flow stays consistent.
func spend(owner_id: int, cost: int) -> bool:
	_ensure_owner(owner_id)
	if _contracts[owner_id] < cost:
		return false
	_contracts[owner_id] -= cost
	contracts_changed.emit(owner_id, _contracts[owner_id], MAX_CONTRACTS)
	return true


## Returns the current Intel Network tier for `owner_id`. If no
## explicit upgrade has been recorded, auto-derives tier from whether
## the owner has built an intelligence_network at all.
func get_intel_network_tier(owner_id: int) -> int:
	if owner_id in _intel_tier:
		return _intel_tier[owner_id]
	# No explicit set — auto-derive by scanning for intelligence_network
	# in the buildings group. Walking the group is cheap (≤50 buildings)
	# and only happens until set_intel_network_tier is called once.
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	for b in tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(b):
			continue
		if int(b.get("owner_id")) != owner_id:
			continue
		var s: Resource = b.get("stats")
		if s != null and s.get("building_id") == &"intelligence_network":
			# Tier 1 once the building exists.
			return 1
	return 0


## Records an explicit Intel Network tier — used by the upgrade UI
## (Task 14) to bump tier from 1 → 2 → 3 when the player pays the
## upgrade cost. Does not validate cost or building presence; the
## caller is responsible.
func set_intel_network_tier(owner_id: int, tier: int) -> void:
	_intel_tier[owner_id] = clampi(tier, 0, 3)


func _process(delta: float) -> void:
	# Regen every registered owner. Cheap — typically 1-2 owners per scene.
	for owner_id: int in _contracts.keys():
		if _contracts[owner_id] >= MAX_CONTRACTS:
			_regen_accum[owner_id] = 0.0
			continue
		_regen_accum[owner_id] = _regen_accum[owner_id] + delta
		var interval: float = get_regen_interval(owner_id)
		while _regen_accum[owner_id] >= interval - 1e-6 and _contracts[owner_id] < MAX_CONTRACTS:
			_contracts[owner_id] += 1
			_regen_accum[owner_id] -= interval
			contracts_changed.emit(owner_id, _contracts[owner_id], MAX_CONTRACTS)
		if _contracts[owner_id] >= MAX_CONTRACTS:
			_regen_accum[owner_id] = 0.0
