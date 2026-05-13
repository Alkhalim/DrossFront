extends Node3D
## PF-B-A10 — kernel stuck detector smoke (in-game).
##
## Spawns one Combine Borzoi at (-30, 0, 0) and orders it to (30, 0, 0).
## Programmatically inserts two box-collider walls forming a V-wedge with
## a closed throat at (5, 0, 0) — narrow enough that the Borzoi cannot
## squeeze through. Expected timeline:
##
##   t = 0 : Borzoi spawned, move issued
##   t ≈ 4 s : Borzoi reaches the wedge throat, can't progress
##   t ≈ 6 s : displacement window full + ratio < 0.10 → L1 push-out
##             (visible perpendicular kick for ~1 s)
##   t ≈ 9 s : L1 cooldown elapses + still no progress → L2 abandon
##             (hound halts, console prints
##              "[PT-STUCK-WEDGE] path_unreachable, reason=2")
##
## Pre-PF-B (legacy escalator only): hound jitters, may or may not
## escape, no path_unreachable signal because the legacy ladder's
## REASON_REPEATEDLY_STUCK only fires after Level 4 (Abandon goal),
## which the legacy code rarely reaches.

const SPAWN: Vector3 = Vector3(-30, 0, 0)
const DEST: Vector3 = Vector3(30, 0, 0)
const WEDGE_CENTER_X: float = 5.0
const WEDGE_GAP: float = 0.6  # gap at the throat (much smaller than hound radius ~1)
const WALL_LEN: float = 12.0
const WALL_HEIGHT: float = 4.0
const WALL_THICK: float = 1.0

func _ready() -> void:
	print_debug("[PT-STUCK-WEDGE] starting")
	if not MovementFlags.use_flowfield():
		push_warning("[PT-STUCK-WEDGE] use_flowfield is OFF — kernel detector won't fire; set drossfront/movement/use_flowfield=true")
	var arena: Node = $TestArena if has_node("TestArena") else null
	if arena == null:
		push_warning("[PT-STUCK-WEDGE] TestArena child not found")
		return

	# Build the wedge geometry as physics-static walls under the arena's
	# buildings group so SpatialIndex / FlowFieldServer pick them up.
	_add_wedge_walls(arena)

	var units_node: Node = arena.get_node_or_null("Units")
	if units_node == null:
		push_warning("[PT-STUCK-WEDGE] Units node not found")
		return

	var hound: Node = _spawn_unit("anvil_hound", SPAWN, units_node)
	if hound == null:
		push_warning("[PT-STUCK-WEDGE] hound spawn failed")
		return

	# Connect to the kernel stuck signal so we print when L2 fires.
	var mc: Node = hound.get_node_or_null("MovementComponent")
	if mc != null:
		mc.connect("path_unreachable", _on_path_unreachable)

	# Wait a beat so SpatialIndex / NavigationServer pick up the new walls.
	await get_tree().create_timer(0.8).timeout

	var sel: Node = arena.get_node_or_null("SelectionManager")
	if sel == null:
		push_warning("[PT-STUCK-WEDGE] SelectionManager not found")
		return
	sel._selected_units.clear()
	sel._selected_units.append(hound)
	if hound.has_method("select"):
		hound.select()
	sel.command_move_to_world(DEST)
	print_debug("[PT-STUCK-WEDGE] move issued to ", DEST)

func _on_path_unreachable(reason: int) -> void:
	print("[PT-STUCK-WEDGE] path_unreachable, reason=", reason)
	if reason == 2:
		print("[PT-STUCK-WEDGE] PASS — kernel L2 abandon fired (REPEATEDLY_STUCK)")

func _add_wedge_walls(arena: Node) -> void:
	# Two walls forming a V centered on (WEDGE_CENTER_X, 0, 0). Each wall is
	# ~12m long, rotated ~30° toward the centerline so their inner ends
	# leave only WEDGE_GAP between them — closed enough to wedge the hound.
	#
	# Wall A: above the centerline, rotated clockwise (negative around Y).
	# Wall B: below the centerline, rotated counterclockwise.
	#
	# Position offset = (WEDGE_GAP/2 + WALL_THICK/2) along Z, then push the
	# outer end back along the rotation axis.
	var a: StaticBody3D = _make_wall_box()
	a.global_position = Vector3(WEDGE_CENTER_X, WALL_HEIGHT * 0.5, WEDGE_GAP * 0.5 + WALL_LEN * 0.25)
	a.rotate_y(deg_to_rad(-30.0))
	arena.add_child(a)
	a.add_to_group("buildings")

	var b: StaticBody3D = _make_wall_box()
	b.global_position = Vector3(WEDGE_CENTER_X, WALL_HEIGHT * 0.5, -(WEDGE_GAP * 0.5 + WALL_LEN * 0.25))
	b.rotate_y(deg_to_rad(30.0))
	arena.add_child(b)
	b.add_to_group("buildings")
	print_debug("[PT-STUCK-WEDGE] wedge walls placed at x=", WEDGE_CENTER_X)

func _make_wall_box() -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	var mesh_instance: MeshInstance3D = MeshInstance3D.new()
	var box_mesh: BoxMesh = BoxMesh.new()
	box_mesh.size = Vector3(WALL_LEN, WALL_HEIGHT, WALL_THICK)
	mesh_instance.mesh = box_mesh
	body.add_child(mesh_instance)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box_shape: BoxShape3D = BoxShape3D.new()
	box_shape.size = Vector3(WALL_LEN, WALL_HEIGHT, WALL_THICK)
	shape.shape = box_shape
	body.add_child(shape)
	return body

func _spawn_unit(stats_path: String, pos: Vector3, parent: Node) -> Node:
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if unit_scene == null:
		return null
	var stats: Resource = load("res://resources/units/" + stats_path + ".tres")
	if stats == null:
		return null
	var u: Node = unit_scene.instantiate()
	u.set("stats", stats)
	u.set("owner_id", 0)
	parent.add_child(u)
	u.global_position = pos
	return u
