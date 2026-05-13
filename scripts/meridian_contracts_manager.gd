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


## Returns the current regen interval in seconds for this owner —
## baseline minus surveillance reductions, clamped at MIN_REGEN_INTERVAL.
## Implemented in Task 15; stubbed here at baseline.
func get_regen_interval(_owner_id: int) -> float:
	return BASELINE_REGEN_INTERVAL


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
