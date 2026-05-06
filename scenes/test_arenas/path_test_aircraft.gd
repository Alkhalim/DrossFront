extends Node3D
## PB-9: aircraft + drones flight under the new pathfinding system.
##
## Prerequisites:
##   drossfront/movement/use_new_system = true in project.godot
##
## Scenario:
##   Spawn 2 aircraft (one Anvil, one Sable) near (-30, 12, -30).
##   Select both and command a move to (30, 0, 30). Expected:
##     - Aircraft fly at altitude (base_altitude from stats.flight_altitude)
##     - Visual banking on turns
##     - Both arrive at the destination
##
## Console markers:
##   [PB-9] STARTED — N units spawned, move issued.
##   [PB-9] ARRIVED — all units within ARRIVAL_THRESHOLD of goal at t=X.XX
##   [PB-9] TIMEOUT — not all units reached goal within Xs.

const GOAL: Vector3 = Vector3(30.0, 0.0, 30.0)
const ARRIVAL_THRESHOLD: float = 8.0
const TIMEOUT_SECONDS: float = 60.0

# Y=12 puts aircraft at cruise altitude so they don't clip into the ground.
const SPAWN_POS_BASE: Vector3 = Vector3(-30.0, 12.0, -30.0)
const SPAWN_SPACING: float = 6.0

const UNIT_STATS: Array[String] = [
	"res://resources/units/anvil_hammerhead.tres",
	"res://resources/units/sable_switchblade.tres",
]

var _units: Array[Node3D] = []
var _t: float = 0.0
var _move_issued: bool = false
var _done: bool = false


func _ready() -> void:
	print("[PB-9] STARTED — aircraft movement test. New system must be ON.")

	for i: int in UNIT_STATS.size():
		var spawn_pos: Vector3 = SPAWN_POS_BASE + Vector3(float(i) * SPAWN_SPACING, 0.0, 0.0)
		var u: Node3D = _spawn_unit(UNIT_STATS[i], spawn_pos, 0)
		if u:
			_units.append(u)

	if _units.is_empty():
		push_error("[PB-9] No units spawned — check spawn helper.")
		return

	# Wait a short tick so all units finish _ready before the command fires.
	get_tree().create_timer(0.5).timeout.connect(_issue_move)


func _issue_move() -> void:
	var sel: SelectionManager = _get_selection_manager()
	if not sel:
		push_error("[PB-9] SelectionManager not found — cannot issue move.")
		return

	for u: Node3D in _units:
		if not is_instance_valid(u):
			continue
		sel._selected_units.append(u)
		if u.has_method("select"):
			u.select()

	print("[PB-9] %d unit(s) selected, issuing move to %s" % [sel._selected_units.size(), str(GOAL)])
	sel.command_move_to_world(GOAL)
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
		# Compare on the XZ plane only; aircraft Y varies by flight altitude.
		var flat_pos: Vector3 = Vector3(u.global_position.x, 0.0, u.global_position.z)
		var flat_goal: Vector3 = Vector3(GOAL.x, 0.0, GOAL.z)
		if flat_pos.distance_to(flat_goal) <= ARRIVAL_THRESHOLD:
			arrived += 1

	if alive > 0 and arrived >= alive:
		print("[PB-9] ARRIVED — %d/%d units at goal at t=%.2f" % [arrived, alive, _t])
		_done = true
		set_process(false)
		return

	if _t >= TIMEOUT_SECONDS:
		print("[PB-9] TIMEOUT — %d/%d alive units reached goal within %.0fs" % [arrived, alive, TIMEOUT_SECONDS])
		_done = true
		set_process(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _spawn_unit(stats_path: String, pos: Vector3, owner_id: int) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		push_error("[PB-9] _spawn_unit: could not load stats from '%s'" % stats_path)
		return null
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if not unit_scene:
		push_error("[PB-9] _spawn_unit: could not load res://scenes/unit.tscn")
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
	push_error("[PB-9] _get_selection_manager: could not find SelectionManager in scene tree.")
	return null
