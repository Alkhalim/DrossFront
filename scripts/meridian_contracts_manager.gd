class_name MeridianContractsManager
extends Node
## Owns per-player Meridian contract pools. Contracts gate every
## Meridian unit order: ordering a unit deducts `unit_stats.contract_cost`
## from the owner's pool; orders are rejected when the pool would go
## negative. Contracts regenerate over time, faster while the owner has
## active surveillance on enemy buildings/units (Task 15).
##
## Lifecycle:
##   - Created once per scene by get_instance(scene_root).
##   - Players are registered lazily when first queried; pool starts
##     at MAX_CONTRACTS.
##   - _process drives the regen tick.

signal contracts_changed(owner_id: int, current: int, maximum: int)

const MAX_CONTRACTS: int = 8
const BASELINE_REGEN_INTERVAL: float = 8.0  # seconds per +1 contract
const MIN_REGEN_INTERVAL: float = 2.0       # floor — heavy surveillance cap

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
		_contracts[owner_id] = MAX_CONTRACTS
		_regen_accum[owner_id] = 0.0


func get_contracts(owner_id: int) -> int:
	_ensure_owner(owner_id)
	return _contracts[owner_id]


func get_max_contracts(_owner_id: int) -> int:
	return MAX_CONTRACTS


## Reduction (seconds) per surveilling building type.
const SURVEILLANCE_REDUCTION: Dictionary = {
	&"sensor_spine": 1.0,
	&"mesh_relay": 0.5,
	&"black_pylon": 2.0,
	&"sensor_array": 0.5,
}

## Cached scan result to avoid re-walking groups for every owner every tick.
## Map: owner_id -> {interval: float, expires_at_ms: int}
var _interval_cache: Dictionary = {}
const _INTERVAL_CACHE_MS: int = 250  # rescan ~4Hz; surveillance shifts slowly


## Returns the current regen interval in seconds for this owner —
## baseline minus surveillance reductions, clamped at MIN_REGEN_INTERVAL.
## Surveillance: each mesh provider building/unit owned by owner_id that
## overlaps at least one enemy entity reduces the interval per
## SURVEILLANCE_REDUCTION (buildings) or -0.5s (mobile mesh units).
func get_regen_interval(owner_id: int) -> float:
	var now: int = Time.get_ticks_msec()
	var cached: Dictionary = _interval_cache.get(owner_id, {})
	if not cached.is_empty() and cached.get("expires_at_ms", 0) > now:
		return cached.interval
	var interval: float = _scan_regen_interval(owner_id)
	_interval_cache[owner_id] = {"interval": interval, "expires_at_ms": now + _INTERVAL_CACHE_MS}
	return interval


func _scan_regen_interval(owner_id: int) -> float:
	var reduction: float = 0.0
	var tree: SceneTree = get_tree()
	if tree == null:
		return BASELINE_REGEN_INTERVAL
	# Snapshot enemies once; reused for every provider overlap check.
	var enemies: Array = []
	for u in tree.get_nodes_in_group("units"):
		if is_instance_valid(u) and int(u.get("owner_id")) != owner_id:
			enemies.append(u)
	for b in tree.get_nodes_in_group("buildings"):
		if is_instance_valid(b) and int(b.get("owner_id")) != owner_id:
			enemies.append(b)
	# Walk owner's buildings — buildings use SURVEILLANCE_REDUCTION by building_id.
	for b in tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(b) or int(b.get("owner_id")) != owner_id:
			continue
		var s: Resource = b.get("stats")
		if s == null:
			continue
		var bid: StringName = s.get("building_id")
		var per_provider: float = SURVEILLANCE_REDUCTION.get(bid, 0.0)
		if per_provider <= 0.0:
			continue
		var radius: float = float(s.get("mesh_provider_radius"))
		if radius <= 0.0:
			continue
		if _provider_surveils_any(b as Node3D, radius, enemies):
			reduction += per_provider
	# Walk owner's units — any unit with mesh_provider_radius > 0 contributes -0.5s.
	# This covers all mobile mesh providers (Specter Glitch, Sensor Carrier,
	# Harbinger Overseer, Pulsefont) without relying on unit_class, which
	# stores generic roles (light/transport/heavy/medium) not unique identifiers.
	for u in tree.get_nodes_in_group("units"):
		if not is_instance_valid(u) or int(u.get("owner_id")) != owner_id:
			continue
		var us: Resource = u.get("stats")
		if us == null:
			continue
		var radius_unit: float = float(us.get("mesh_provider_radius"))
		if radius_unit <= 0.0:
			continue
		if _provider_surveils_any(u as Node3D, radius_unit, enemies):
			reduction += 0.5
	var interval: float = BASELINE_REGEN_INTERVAL - reduction
	return maxf(interval, MIN_REGEN_INTERVAL)


func _provider_surveils_any(provider: Node3D, radius: float, enemies: Array) -> bool:
	var p_pos: Vector3 = provider.global_position
	var r2: float = radius * radius
	for e in enemies:
		if not is_instance_valid(e):
			continue
		var e3: Node3D = e as Node3D
		if e3 == null:
			continue
		if p_pos.distance_squared_to(e3.global_position) <= r2:
			return true
	return false


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
