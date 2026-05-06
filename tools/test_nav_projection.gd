@tool
extends EditorScript
## Snapshot test for NavRouter.project_to_navmesh. Run from Godot
## Editor → File → Run with scenes/test_arena.tscn open. Prints
## projection results for crafted positions; eyeball against
## "expected" comments in the source.

func _run() -> void:
	var arena: Node = EditorInterface.get_edited_scene_root()
	if arena == null:
		push_error("Open scenes/test_arena.tscn first")
		return
	var router: NavRouter = NavRouter.get_instance(arena)
	var profile: AgentProfile = AgentProfile.new(0.6, 0.5, 35.0, &"smoke")

	print_debug("--- project_to_navmesh ---")
	# Inside navmesh — should return unchanged (or very close)
	var p1: Vector3 = router.project_to_navmesh(Vector3(0, 0, 0), profile)
	print_debug("origin → ", p1, "  expected ~(0,0,0)")
	# Above navmesh (Y high) — XZ should snap to mesh
	var p2: Vector3 = router.project_to_navmesh(Vector3(10, 50, 10), profile)
	print_debug("above (10,50,10) → ", p2, "  expected XZ ~(10,?,10), Y near mesh height")
	# Far off-map — should return unchanged because > max_distance
	var p3: Vector3 = router.project_to_navmesh(Vector3(500, 0, 500), profile)
	print_debug("off-map (500,0,500) → ", p3, "  expected (500,0,500) [max_distance fallback]")
	# Off-map but within max_distance — should snap toward mesh
	var p4: Vector3 = router.project_to_navmesh(Vector3(202, 0, 0), profile, 8.0)
	print_debug("near boundary (202,0,0) → ", p4, "  expected ~(200,?,0) snapped inward")
