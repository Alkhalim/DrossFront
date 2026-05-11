extends SceneTree

## Headless smoke for PF-B-A4 / A5 / A6 / A7. Loads the kernel and server
## directly via ClassDB (no bootstrap, no deferred sweeps), registers one
## agent, holds it at origin until L2 fires, drains the event queue, prints
## OK / FAIL.
##
## Run:
##   & "G:\Programme\Godot\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe" `
##     --headless --quit --path "D:\Dokumente\Gamedesign\DrossFront\DrossFront" `
##     -s tools/test_stuck_detector_snapshot.gd

func _init() -> void:
	var server: Object = ClassDB.instantiate("FlowFieldServer")
	if server == null:
		push_error("FlowFieldServer not registered — extension not loaded?")
		quit(1)
		return

	var kernel: Object = ClassDB.instantiate("SteeringKernel")
	if kernel == null:
		push_error("SteeringKernel not registered — extension not loaded?")
		server.free()
		quit(1)
		return

	if kernel.has_method("set_flow_field_server"):
		kernel.call("set_flow_field_server", server)

	# 32x32 cells at 2m, origin at (-32, -32). Open grid (no obstacles).
	server.call("configure_map", 32, 32, 2.0, -32.0, -32.0)
	server.call("set_agent_radius", 0, 0.5)

	var fid: int = server.call("build_field", Vector3(20.0, 0.0, 20.0), 0) as int
	if fid == 0:
		push_error("build_field returned 0")
		kernel.free()
		server.free()
		quit(1)
		return

	# register_agent(unit_id, agent_class, radius, max_speed, max_accel, max_turn_rate)
	var handle: int = kernel.call("register_agent", 1, 0, 0.5, 5.0, 20.0, 8.0) as int
	if handle == 0:
		push_error("register_agent returned 0")
		kernel.free()
		server.free()
		quit(1)
		return

	# group_id=1 matches the fid's group, stance=0
	kernel.call("set_agent_target", handle, 1, fid, 0)

	# 60 ticks at 0.1 s, agent held at origin. L2 fires by tick ~42.
	for t: int in range(60):
		kernel.call("set_agent_pos", handle, Vector3(0.0, 0.0, 0.0))
		kernel.call("tick", 0.1)

	var ev: Vector2i = kernel.call("pop_path_unreachable_event") as Vector2i
	if ev.x == handle and ev.y == 2:
		print("OK: kernel emitted REPEATEDLY_STUCK for handle ", handle)
		kernel.free()
		server.free()
		quit(0)
	else:
		push_error("FAIL: expected (handle=%d, reason=2), got %s" % [handle, str(ev)])
		kernel.free()
		server.free()
		quit(1)
