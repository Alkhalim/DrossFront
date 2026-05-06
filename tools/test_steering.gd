@tool
extends EditorScript
## Snapshot test for Steering.seek and Steering.separate. Prints
## expected outputs; engineer eyeballs them against the comments.
## Plan A — does NOT need a test framework; use print_debug.

func _run() -> void:
	print_debug("--- Steering.seek ---")
	# Seek straight east at 10u/s
	var v1: Vector3 = Steering.seek(Vector3.ZERO, Vector3(10, 0, 0), 10.0)
	print_debug("east 10u: ", v1, "  expected ~(10,0,0)")
	# Seek with speed cap 5
	var v2: Vector3 = Steering.seek(Vector3.ZERO, Vector3(10, 0, 0), 5.0)
	print_debug("east cap5: ", v2, "  expected ~(5,0,0)")
	# Coincident
	var v3: Vector3 = Steering.seek(Vector3.ZERO, Vector3.ZERO, 10.0)
	print_debug("coincident: ", v3, "  expected (0,0,0)")
	# Diagonal NE
	var v4: Vector3 = Steering.seek(Vector3.ZERO, Vector3(1, 0, 1), 10.0)
	print_debug("NE 1u: ", v4, "  expected ~(7.07,0,7.07)")

	print_debug("--- Steering.separate ---")
	var n_node := Node3D.new()
	n_node.global_position = Vector3(2, 0, 0)
	# Neighbor 2u east, min_distance 4u, strength 10
	# Falloff = 1 - 2/4 = 0.5; force = (-1,0,0)*10*0.5 = (-5,0,0)
	var s1: Vector3 = Steering.separate(Vector3.ZERO, [n_node], 4.0, 10.0)
	print_debug("near east: ", s1, "  expected ~(-5,0,0)")
	n_node.global_position = Vector3(10, 0, 0)
	var s2: Vector3 = Steering.separate(Vector3.ZERO, [n_node], 4.0, 10.0)
	print_debug("far east: ", s2, "  expected (0,0,0)")
	n_node.queue_free()

	print_debug("--- Steering.inertia_step ---")
	# Already at desired, no change
	var i1: Vector3 = Steering.inertia_step(
		Vector3(5, 0, 0), Vector3(5, 0, 0), 10.0, PI, 1.0/60.0)
	print_debug("at-target: ", i1, "  expected ~(5,0,0)")
	# Accelerate from rest toward east
	var i2: Vector3 = Steering.inertia_step(
		Vector3.ZERO, Vector3(10, 0, 0), 60.0, PI, 1.0/60.0)
	print_debug("accel 1f at 60u/s²: ", i2, "  expected ~(1,0,0)")
	# Decelerate from speed
	var i3: Vector3 = Steering.inertia_step(
		Vector3(10, 0, 0), Vector3.ZERO, 60.0, PI, 1.0/60.0)
	print_debug("decel 1f: ", i3, "  expected ~(9,0,0)")
	# Turn-limit: 90° turn at PI rad/s, 1/60s = 3°/frame
	var i4: Vector3 = Steering.inertia_step(
		Vector3(10, 0, 0), Vector3(0, 0, 10), 60.0, PI, 1.0/60.0)
	print_debug("turn-limited: ", i4, "  expected new_dir ~3° toward north")
