@tool
extends EditorScript
## Smoke-test for NavRouter.query_path. Run from Editor → File → Run
## with scenes/test_arena.tscn open. Prints a path between two
## fixed points; visually confirm it has more than two waypoints
## and traverses sensible geometry.

func _run() -> void:
	var arena: Node = EditorInterface.get_edited_scene_root()
	if arena == null:
		push_error("Open scenes/test_arena.tscn first")
		return
	var router := NavRouter.get_instance(arena)
	var profile := AgentProfile.new(0.6, 0.5, 35.0, &"smoke")
	var result := router.query_path(
		Vector3(-30, 0, -30),
		Vector3(30, 0, 30),
		profile)
	print("valid: %s, waypoints: %d" % [result.valid, result.waypoints.size()])
	for w in result.waypoints:
		print("  ", w)
