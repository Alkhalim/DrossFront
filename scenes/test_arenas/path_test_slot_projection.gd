extends Node3D
## PC-4 test: slot projection.
##
## Prerequisites:
##   drossfront/movement/use_new_system = true in project.godot
##
## Scenario:
##   Spawn 5 ground squads at the start corner and orders them to
##   the destination corner. The user is expected to manually drop
##   a building between the formation and the destination such that
##   some slots fall inside the wall when group_center is near it.
##
## Pre-PC-3: slot positions inside the wall, units circle endlessly.
## Post-PC-3: slot projection pulls those slots to the nearest valid
## navmesh cell, units queue through the gap (or sidestep around).
##
## Console markers:
##   [PC-4] STARTED — N units spawned, move issued.
##   [PC-4] ARRIVED — all units within ARRIVAL_THRESHOLD of goal at t=X.XX
##   [PC-4] TIMEOUT — not all units reached goal within Xs.

const SPAWN: Vector3 = Vector3(-30.0, 0.0, -10.0)
const DEST: Vector3 = Vector3(30.0, 0.0, 10.0)
const ARRIVAL_THRESHOLD: float = 5.0
const TIMEOUT_SECONDS: float = 60.0

var _units: Array[Node3D] = []
var _t: float = 0.0
var _move_issued: bool = false
var _done: bool = false


func _ready() -> void:
	print("[PC-4] STARTED — slot projection test. New system must be ON.")

	# Spawn 5 hounds offset along Z so they form into a real squad-of-squads
	for i: int in 5:
		var spawn_pos: Vector3 = SPAWN + Vector3(0.0, 0.0, float(i) * 4.0)
		var u: Node3D = _spawn_unit("res://resources/units/anvil_hound.tres", spawn_pos, 0)
		if u:
			_units.append(u)

	if _units.is_empty():
		push_error("[PC-4] No units spawned — check spawn helper.")
		return

	# Wait a short tick so all units finish _ready before the command fires.
	get_tree().create_timer(0.5).timeout.connect(_issue_move)


func _issue_move() -> void:
	var sel: SelectionManager = _get_selection_manager()
	if not sel:
		push_error("[PC-4] SelectionManager not found — cannot issue move.")
		return

	for u: Node3D in _units:
		if not is_instance_valid(u):
			continue
		sel._selected_units.append(u)
		if u.has_method("select"):
			u.select()

	print("[PC-4] %d unit(s) selected, issuing move to %s" % [sel._selected_units.size(), str(DEST)])
	sel.command_move_to_world(DEST)
	_move_issued = true


func _process(delta: float) -> void:
	if _done or not _move_issued:
		return
	_t += delta

	var arrived: int = 0
	var alive: int = 0
	for u: Node3D in _units:
		if not is_instance_valid(u):
			continue
		var ac: int = u.get("alive_count") if "alive_count" in u else 1
		if ac <= 0:
			continue
		alive += 1
		if u.global_position.distance_to(DEST) <= ARRIVAL_THRESHOLD:
			arrived += 1

	if alive > 0 and arrived >= alive:
		print("[PC-4] ARRIVED — %d/%d units at goal at t=%.2f" % [arrived, alive, _t])
		_done = true
		set_process(false)
		return

	if _t >= TIMEOUT_SECONDS:
		print("[PC-4] TIMEOUT — %d/%d alive units reached goal within %.0fs" % [arrived, alive, TIMEOUT_SECONDS])
		_done = true
		set_process(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _spawn_unit(stats_path: String, pos: Vector3, owner_id: int) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		push_error("[PC-4] _spawn_unit: could not load stats from '%s'" % stats_path)
		return null
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if not unit_scene:
		push_error("[PC-4] _spawn_unit: could not load res://scenes/unit.tscn")
		return null
	var unit: Node3D = unit_scene.instantiate() as Node3D
	if not unit:
		return null
	unit.set("stats", stats)
	unit.set("owner_id", owner_id)
	var units_node: Node = get_node_or_null("TestArena/Units")
	if units_node:
		units_node.add_child(unit)
	else:
		add_child(unit)
	unit.global_position = pos
	return unit


func _get_selection_manager() -> SelectionManager:
	var sm: Node = get_node_or_null("TestArena/SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	# Fallback: walk the current scene root.
	sm = get_tree().current_scene.get_node_or_null("SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	push_error("[PC-4] _get_selection_manager: could not find SelectionManager in scene tree.")
	return null
