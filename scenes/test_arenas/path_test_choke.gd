extends Node3D
## PA-22 test: choke point formation deformation.
##
## Prerequisites:
##   drossfront/movement/use_new_system = true in project.godot
##
## Scenario:
##   Two static neutral buildings placed at Z=+7 and Z=-7 create a ~6u gap
##   along the X axis (buildings use gun_emplacement_basic footprint 2.4x2.4).
##   Five anvil_hound squads are pushed through the gap from X=-20 to X=+20.
##
## Expected outcome:
##   - The SquadGroup's group_center throttle slows leading squads when the
##     choke prevents the formation from spreading (group_center_throttle).
##   - No false squad drops (no unit fires DropReason.NO_PROGRESS while
##     queuing through the bottleneck).
##   - Formation re-widens on the far side after clearing the choke.
##
## Console markers:
##   [PA-22] STARTED — choke walls placed, 5 hounds spawned.
##   [PA-22] ARRIVED — all hounds at goal at t=X.XX   (success)
##   [PA-22] TIMEOUT — not all hounds reached goal.
##
## What to visually verify:
##   - Units queue through the gap rather than stacking on each other.
##   - Speed visibly slows when the lead unit is in the gap.
##   - No unit permanently stalls (would indicate a false drop or deadlock).

const GOAL: Vector3 = Vector3(20.0, 0.0, 0.0)
const ARRIVAL_THRESHOLD: float = 4.0
const TIMEOUT_SECONDS: float = 60.0

# Two blocking buildings straddling Z=0. Each gun_emplacement_basic has a
# footprint of 2.4x2.4u, placed at Z=±7 → gap = 14 - 2*1.2 = 11.6u. To
# tighten the gap to ~6u, move them to Z=±4: 8 - 2.4 = 5.6u ≈ 6u.
const BLOCK_A_POS: Vector3 = Vector3(0.0, 0.0, 4.0)
const BLOCK_B_POS: Vector3 = Vector3(0.0, 0.0, -4.0)

var _hounds: Array[Node3D] = []
var _t: float = 0.0
var _move_issued: bool = false
var _done: bool = false


func _ready() -> void:
	print("[PA-22] STARTED — choke point test. New system must be ON.")

	# Place the two wall buildings first so navmesh bake (if triggered)
	# accounts for them before units are spawned.
	var b1: Node = _spawn_static_building(BLOCK_A_POS)
	var b2: Node = _spawn_static_building(BLOCK_B_POS)
	if not b1 or not b2:
		push_warning("[PA-22] One or both wall buildings failed to spawn. Choke may not be real.")

	# Spawn 5 hounds in a loose column on the western approach.
	for i: int in 5:
		var z_offset: float = -4.0 + float(i) * 2.0
		var spawn_pos: Vector3 = Vector3(-20.0, 0.0, z_offset)
		var u: Node3D = _spawn_unit(
			"res://resources/units/anvil_hound.tres", spawn_pos, 0
		)
		if u:
			_hounds.append(u)

	if _hounds.is_empty():
		push_error("[PA-22] No hounds spawned — check spawn helper.")
		return

	# Short delay so all units finish _ready before the move command.
	get_tree().create_timer(0.5).timeout.connect(_issue_move)


func _issue_move() -> void:
	var sel: SelectionManager = _get_selection_manager()
	if not sel:
		push_error("[PA-22] SelectionManager not found — cannot issue move.")
		return

	for u: Node3D in _hounds:
		if not is_instance_valid(u):
			continue
		sel._selected_units.append(u)
		if u.has_method("select"):
			u.select()

	print("[PA-22] %d hound(s) selected, issuing move through choke to %s" % [sel._selected_units.size(), str(GOAL)])
	sel.command_move_to_world(GOAL)
	_move_issued = true


func _process(delta: float) -> void:
	if _done or not _move_issued:
		return
	_t += delta

	var arrived: int = 0
	var alive: int = 0
	for u: Node3D in _hounds:
		if not is_instance_valid(u):
			continue
		var ac: int = u.get("alive_count") if "alive_count" in u else 1
		if ac <= 0:
			continue
		alive += 1
		if u.global_position.distance_to(GOAL) <= ARRIVAL_THRESHOLD:
			arrived += 1

	if alive > 0 and arrived >= alive:
		print("[PA-22] ARRIVED — %d/%d hound(s) at goal at t=%.2f" % [arrived, alive, _t])
		_done = true
		set_process(false)
		return

	if _t >= TIMEOUT_SECONDS:
		print("[PA-22] TIMEOUT — %d/%d alive hound(s) reached goal within %.0fs" % [arrived, alive, TIMEOUT_SECONDS])
		_done = true
		set_process(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _spawn_unit(stats_path: String, pos: Vector3, owner_id: int) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		push_error("[PA-22] _spawn_unit: could not load stats '%s'" % stats_path)
		return null
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if not unit_scene:
		push_error("[PA-22] _spawn_unit: could not load unit.tscn")
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


func _spawn_static_building(pos: Vector3) -> Node:
	## Drops a fully-constructed neutral building to act as a wall.
	## Neutral owner_id=2 means it is hostile to all and will not
	## be accidentally built-on or reclaimed during the test.
	var stats: BuildingStatResource = load(
		"res://resources/buildings/gun_emplacement_basic.tres"
	) as BuildingStatResource
	if not stats:
		push_error("[PA-22] _spawn_static_building: could not load gun_emplacement_basic.tres")
		return null
	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	if not building_scene:
		push_error("[PA-22] _spawn_static_building: could not load building.tscn")
		return null
	var b: Node3D = building_scene.instantiate() as Node3D
	if not b:
		return null
	b.set("stats", stats)
	b.set("owner_id", 2)
	b.set("is_constructed", true)
	add_child(b)
	b.global_position = pos
	return b


func _get_selection_manager() -> SelectionManager:
	var sm: Node = get_node_or_null("TestArena/SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	sm = get_tree().current_scene.get_node_or_null("SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	push_error("[PA-22] _get_selection_manager: SelectionManager not found.")
	return null
