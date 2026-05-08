@tool
extends EditorScript
## PF-A-11: snapshot test for FlowFieldServer.
## Run from Editor -> File -> Run with any scene open.

func _run() -> void:
	var server: Object = ClassDB.instantiate("FlowFieldServer")
	if server == null:
		push_error("FlowFieldServer not registered — extension load failed")
		return
	print_debug("[PF-A-11] configuring 20x20 grid, 2m cells, origin (-20,-20)")
	server.call("configure_map", 20, 20, 2.0, -20.0, -20.0)
	server.call("set_agent_radius", 0, 0.6)  # small
	server.call("set_agent_radius", 1, 1.0)  # medium
	server.call("set_agent_radius", 2, 2.0)  # large

	print_debug("[PF-A-11] building field for class=0, goal=(10,0,10)")
	var fid: int = server.call("build_field", Vector3(10, 0, 10), 0)
	print_debug("[PF-A-11] field id = ", fid, "  (expect non-zero)")

	var s_origin: Vector2 = server.call("sample", fid, Vector3(0, 0, 0))
	print_debug("[PF-A-11] sample at origin = ", s_origin, "  (expect roughly (+x,+z) toward goal)")

	var s_goal: Vector2 = server.call("sample", fid, Vector3(10, 0, 10))
	print_debug("[PF-A-11] sample at goal = ", s_goal, "  (expect ~(0,0))")

	print_debug("[PF-A-11] marking obstacle at (0,0,0) size (4,1,4)")
	var aabb := AABB(Vector3(-2, 0, -2), Vector3(4, 1, 4))
	server.call("mark_obstacle", aabb, true)

	var s_after: Vector2 = server.call("sample", fid, Vector3(-5, 0, -5))
	print_debug("[PF-A-11] sample at (-5,0,-5) after obstacle = ", s_after, "  (expect skewed away from obstacle)")

	print_debug("[PF-A-11] releasing field")
	server.call("release_field", fid)
	server.free()
	print_debug("[PF-A-11] done")
