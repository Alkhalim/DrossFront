extends SceneTree
## Headless verification that ProjectileManager preserves the
## existing damage-timing semantics:
##   - bullets (hitscan) NEVER call take_damage from the manager
##     side (CombatComponent already applied it at fire-tick).
##   - missiles call take_damage when their arc completes.
##
## Mirrors the structure of test_hitscan_bullets.gd.
##
## Run:
##   & "G:\Programme\Godot\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe" `
##     --headless --quit --path "D:\Dokumente\Gamedesign\DrossFront\DrossFront" `
##     -s tools/test_multimesh_projectiles.gd

class FakeTarget extends Node3D:
	var alive_count: int = 1
	var owner_id: int = 0
	var damage_log: Array = []

	func take_damage(amount: int, _attacker) -> void:
		damage_log.append(amount)


func _initialize() -> void:
	# _initialize fires when the main loop starts. Nodes added here are
	# parented but is_inside_tree() returns false until the first frame
	# tick — process callbacks won't run yet. await process_frame once
	# so the tree settles before running the assertions.
	var scene_root := Node3D.new()
	scene_root.name = "TestScene"
	get_root().add_child(scene_root)
	current_scene = scene_root
	# SpatialIndex is required for the splash narrow-phase. Stub it
	# with an empty Node — _apply_splash will see no candidates and
	# skip cleanly.
	var idx_stub := Node.new()
	idx_stub.name = "SpatialIndex"
	scene_root.add_child(idx_stub)
	var pm := ProjectileManager.new()
	pm.name = "ProjectileManager"
	scene_root.add_child(pm)

	await process_frame

	var ok: bool = true
	ok = await _test_bullet_no_damage_from_manager(pm) and ok
	ok = await _test_missile_damage_on_arrival(pm) and ok
	if ok:
		print("OK: multimesh projectile damage-timing PASSED")
		quit(0)
	else:
		push_error("FAIL: multimesh projectile damage-timing")
		quit(1)


func _test_bullet_no_damage_from_manager(pm: ProjectileManager) -> bool:
	# Hitscan bullets carry pending_damage=0 because CombatComponent
	# already applied damage at fire-tick. The manager must NOT call
	# take_damage on the target.
	var target := FakeTarget.new()
	target.name = "BulletTarget"
	target.position = Vector3(8.0, 0.0, 0.0)
	current_scene.add_child(target)
	var ok_fired: bool = pm.fire(Vector3.ZERO, Vector3(8.0, 0.0, 0.0),
			"bullet", Color(1, 0.8, 0.2, 1), 150.0,
			0,  # pending_damage = 0 (hitscan)
			target, null, 0.0, 0, 0)
	if not ok_fired:
		push_error("FAIL: pm.fire returned false for bullet")
		return false
	# Drive time synthetically. Headless frames have near-zero delta, so
	# we pump _process directly at a fixed 1/60 s step.
	# 60 ticks × (1/60 s) = 1.0 s — well past the 0.7 s bullet cap.
	var dt: float = 1.0 / 60.0
	for _i: int in 60:
		pm._process(dt)
		await process_frame
	if not target.damage_log.is_empty():
		push_error("FAIL: bullet manager applied damage (pending=0): %s" % str(target.damage_log))
		return false
	return true


func _test_missile_damage_on_arrival(pm: ProjectileManager) -> bool:
	# Missile carries a real damage payload that the manager must
	# apply when the arc reaches t_norm >= 1.0.
	var target := FakeTarget.new()
	target.name = "MissileTarget"
	target.position = Vector3(15.0, 0.0, 0.0)
	current_scene.add_child(target)
	var ok_fired: bool = pm.fire(Vector3.ZERO, Vector3(15.0, 0.0, 0.0),
			"missile", Color(0.9, 0.6, 0.2, 1), 0.0,
			17,  # pending_damage = 17
			target, null, 0.0, 0, 0)
	if not ok_fired:
		push_error("FAIL: pm.fire returned false for missile")
		return false
	# Drive time synthetically at 1/60 s per tick. total_flight for this
	# missile = max(15 / 12, 0.5) = 1.25 s. 120 ticks = 2 s — ample slack.
	var dt: float = 1.0 / 60.0
	for _i: int in 120:
		pm._process(dt)
		await process_frame
		if target.damage_log.size() > 0:
			break
	if target.damage_log.is_empty():
		push_error("FAIL: missile never applied damage")
		return false
	if target.damage_log[0] != 17:
		push_error("FAIL: missile damage mismatch: %d" % target.damage_log[0])
		return false
	return true
