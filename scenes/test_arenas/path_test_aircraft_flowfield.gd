extends Node3D
## PF-B-B7 — aircraft kernel-branch smoke (in-game).
##
## Spawns 2 aircraft at (-30, 12, -3) and (-30, 12, +3), orders them to
## (30, 12, 0) over an AA building obstacle at (5, 4, 0). Expected:
## - Both aircraft fly at altitude toward the goal
## - Inter-aircraft SEPARATE keeps them ~radii+buffer apart laterally
## - Kernel writes full 3D velocity (no Y zeroing); both arrive within
##   ARRIVAL_THRESHOLD of goal
##
## Pre-PF-B-B2 (no aircraft branch in tick()): aircraft skipped kernel
## registration entirely; this scene wouldn't even register them as agents.
## Post-PF-B-B2/B3/B4/B6: aircraft register, get IS_AIRCRAFT flag, kernel
## tick() takes the 3D direct-seek branch, GroupAura/goto_world both wire
## set_agent_target_pos.

const SPAWN_BASE: Vector3 = Vector3(-30.0, 12.0, 0.0)
const SPAWN_OFFSETS: Array[Vector3] = [Vector3(0, 0, -3), Vector3(0, 0, 3)]
const GOAL: Vector3 = Vector3(30.0, 12.0, 0.0)
const ARRIVAL_THRESHOLD: float = 8.0
const TIMEOUT_SECONDS: float = 60.0

const UNIT_STATS: Array[String] = [
	"res://resources/units/anvil_hammerhead.tres",
	"res://resources/units/sable_switchblade.tres",
]

# AA building obstacle midway through the flight path.
const AA_POS: Vector3 = Vector3(5.0, 0.0, 0.0)
const AA_HEIGHT: float = 8.0  # tall enough that aircraft must steer around laterally
const AA_FOOTPRINT: float = 4.0

var _units: Array[Node3D] = []
var _t: float = 0.0
var _move_issued: bool = false
var _done: bool = false


func _ready() -> void:
	print("[PT-AC-FF] STARTED — aircraft kernel-branch test. use_flowfield must be ON.")
	if not MovementFlags.use_flowfield():
		push_warning("[PT-AC-FF] use_flowfield is OFF — set drossfront/movement/use_flowfield=true")

	var arena: Node = $TestArena if has_node("TestArena") else null
	if arena == null:
		push_warning("[PT-AC-FF] TestArena child not found")
		return

	_add_aa_building(arena)

	var units_node: Node = arena.get_node_or_null("Units")
	if units_node == null:
		push_warning("[PT-AC-FF] Units node not found")
		return

	for i: int in SPAWN_OFFSETS.size():
		var stats_path: String = UNIT_STATS[i] if i < UNIT_STATS.size() else UNIT_STATS[0]
		var pos: Vector3 = SPAWN_BASE + SPAWN_OFFSETS[i]
		var u: Node3D = _spawn_unit(stats_path, pos, units_node)
		if u != null:
			_units.append(u)

	if _units.is_empty():
		push_error("[PT-AC-FF] No aircraft spawned")
		return

	await get_tree().create_timer(0.8).timeout

	var sel: SelectionManager = _get_selection_manager()
	if sel == null:
		push_warning("[PT-AC-FF] SelectionManager not found")
		return
	sel._selected_units.clear()
	for u: Node3D in _units:
		if not is_instance_valid(u):
			continue
		sel._selected_units.append(u)
		if u.has_method("select"):
			u.select()
	sel.command_move_to_world(GOAL)
	_move_issued = true
	print("[PT-AC-FF] move issued to ", GOAL, " — ", _units.size(), " aircraft")


func _process(delta: float) -> void:
	if _done or not _move_issued:
		return
	_t += delta

	if _t > TIMEOUT_SECONDS:
		push_warning("[PT-AC-FF] TIMEOUT after %.1fs — aircraft did not arrive" % _t)
		_done = true
		set_process(false)
		return

	var arrived: int = 0
	var alive: int = 0
	for u: Node3D in _units:
		if not is_instance_valid(u):
			continue
		alive += 1
		if u.global_position.distance_to(GOAL) <= ARRIVAL_THRESHOLD:
			arrived += 1

	if alive > 0 and arrived >= alive:
		print("[PT-AC-FF] PASS — all aircraft arrived within %.1fm of goal at t=%.2fs" % [ARRIVAL_THRESHOLD, _t])
		_done = true
		set_process(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _add_aa_building(arena: Node) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var mesh_inst: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(AA_FOOTPRINT, AA_HEIGHT, AA_FOOTPRINT)
	mesh_inst.mesh = box
	body.add_child(mesh_inst)
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var shape_box: BoxShape3D = BoxShape3D.new()
	shape_box.size = Vector3(AA_FOOTPRINT, AA_HEIGHT, AA_FOOTPRINT)
	shape_node.shape = shape_box
	body.add_child(shape_node)
	arena.add_child(body)
	body.global_position = AA_POS + Vector3(0.0, AA_HEIGHT * 0.5, 0.0)
	body.add_to_group("buildings")
	print("[PT-AC-FF] AA building placed at ", AA_POS)


func _spawn_unit(stats_path: String, pos: Vector3, parent: Node) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if stats == null:
		push_error("[PT-AC-FF] _spawn_unit: could not load stats from '%s'" % stats_path)
		return null
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if unit_scene == null:
		push_error("[PT-AC-FF] _spawn_unit: could not load res://scenes/unit.tscn")
		return null
	var u: Node3D = unit_scene.instantiate() as Node3D
	if u == null:
		return null
	u.set("stats", stats)
	u.set("owner_id", 0)
	parent.add_child(u)
	u.global_position = pos
	return u


func _get_selection_manager() -> SelectionManager:
	var sm: Node = get_node_or_null("TestArena/SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	sm = get_tree().current_scene.get_node_or_null("SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	push_error("[PT-AC-FF] _get_selection_manager: could not find SelectionManager in scene tree.")
	return null
