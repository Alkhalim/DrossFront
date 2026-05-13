class_name InheritorBuildingManager
extends Node
## Per-player state for Inheritor faction systems:
##   - Reliquary count cap (max 4 per spec)
##   - Per-Reliquary salvage pile spawn timers
##   - Architect's Network tier (Phase 3 task)
##
## Lifecycle:
##   - Created once per scene by get_instance(scene_root).
##   - Buildings register themselves via register_reliquary() on construction
##     completion and unregister via unregister_reliquary() on _exit_tree.
##   - _process drives the per-Reliquary spawn timer tick.

const MAX_RELIQUARIES: int = 4
const PILE_SPAWN_INTERVAL: float = 30.0  # seconds between pile spawns
const MAX_PILES_PER_RELIQUARY: int = 3
const PILE_SALVAGE_VALUE: int = 25

## Spawn offset radius around the Reliquary centre (units).
const PILE_SPAWN_RADIUS: float = 3.0

## Per-Reliquary spawn timer + active piles. Keyed by Building instance.
var _reliquary_state: Dictionary = {}  # Building -> {timer: float, piles: Array[Node3D]}

static var _pending_instance: InheritorBuildingManager = null


static func get_instance(scene_root: Node) -> InheritorBuildingManager:
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null("InheritorBuildingManager")
	if existing and existing is InheritorBuildingManager:
		if _pending_instance == existing:
			_pending_instance = null
		return existing as InheritorBuildingManager
	if _pending_instance != null and is_instance_valid(_pending_instance):
		return _pending_instance
	var mgr := InheritorBuildingManager.new()
	mgr.name = "InheritorBuildingManager"
	_pending_instance = mgr
	scene_root.add_child.call_deferred(mgr)
	return mgr


## Returns the count of constructed Reliquaries owned by `owner_id`.
## Used by SelectionManager to enforce the per-player cap.
func get_reliquary_count(owner_id: int) -> int:
	var count: int = 0
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	for b: Node in tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(b):
			continue
		if int(b.get("owner_id")) != owner_id:
			continue
		var s: Resource = b.get("stats")
		if s != null and s.get("building_id") == &"reliquary" and bool(b.get("is_constructed")):
			count += 1
	return count


func can_build_reliquary(owner_id: int) -> bool:
	return get_reliquary_count(owner_id) < MAX_RELIQUARIES


## Called by Building.gd when a Reliquary finishes construction.
func register_reliquary(reliquary: Node) -> void:
	if not is_instance_valid(reliquary):
		return
	if reliquary in _reliquary_state:
		return
	_reliquary_state[reliquary] = {"timer": 0.0, "piles": []}


## Called when a Reliquary is destroyed / freed.
func unregister_reliquary(reliquary: Node) -> void:
	if reliquary in _reliquary_state:
		# Free any uncollected piles so they don't pollute the world.
		for pile: Node3D in _reliquary_state[reliquary]["piles"]:
			if is_instance_valid(pile):
				pile.queue_free()
		_reliquary_state.erase(reliquary)


func _process(delta: float) -> void:
	# Spawn pile when timer elapses, up to MAX_PILES_PER_RELIQUARY.
	var to_unregister: Array = []
	for r: Node in _reliquary_state.keys():
		if not is_instance_valid(r):
			to_unregister.append(r)
			continue
		var state: Dictionary = _reliquary_state[r]
		# Prune freed piles.
		var live_piles: Array = []
		for pile: Node3D in state["piles"]:
			if is_instance_valid(pile):
				live_piles.append(pile)
		state["piles"] = live_piles
		if live_piles.size() >= MAX_PILES_PER_RELIQUARY:
			state["timer"] = 0.0
			continue
		state["timer"] = state["timer"] + delta
		if state["timer"] >= PILE_SPAWN_INTERVAL:
			state["timer"] -= PILE_SPAWN_INTERVAL
			var pile: Node3D = _spawn_pile_near(r as Node3D)
			if pile != null:
				state["piles"].append(pile)
	for r: Node in to_unregister:
		_reliquary_state.erase(r)


func _spawn_pile_near(reliquary: Node3D) -> Node3D:
	## Spawn a Wreck-compatible salvage pile at a random offset from the
	## Reliquary. Workers auto-target "wrecks" group nodes and harvest them
	## via the standard SalvageWorker flow — no new entity type needed.
	##
	## The pile is a Wreck instance with:
	##   - salvage_value = PILE_SALVAGE_VALUE (25 salvage)
	##   - wreck_size = small debris footprint (1.0, 0.4, 1.0)
	## Workers collect it exactly as they would battlefield debris.
	if not is_instance_valid(reliquary):
		return null
	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return null

	# Random position within PILE_SPAWN_RADIUS of the Reliquary centre.
	var angle: float = randf_range(0.0, TAU)
	var dist: float = randf_range(1.5, PILE_SPAWN_RADIUS)
	var offset: Vector3 = Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
	var pile_pos: Vector3 = reliquary.global_position + offset

	var pile := Wreck.new()
	pile.salvage_value = PILE_SALVAGE_VALUE
	pile.wreck_size = Vector3(1.0, 0.4, 1.0)
	pile.global_position = pile_pos
	scene_root.add_child(pile)
	return pile
