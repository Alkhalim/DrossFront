extends SceneTree

## Headless smoke test for hitscan bullet behavior (commits 281b41f + e811fa2).
##
## Test: a bullet Projectile spawned via Projectile.create() with no
## set_damage_payload call has pending_damage == 0, and calling
## _spawn_impact() directly does NOT invoke take_damage on any target.
##
## This verifies the core perf invariant: bullet tracers are spawned
## damage-free, so the visual tracer arriving at the target does not
## double-apply damage that CombatComponent already applied synchronously
## at fire-tick.
##
## Run:
##   & "G:\Programme\Godot\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe" `
##     --headless --quit --path "D:\Dokumente\Gamedesign\DrossFront\DrossFront" `
##     -s tools/test_hitscan_bullets.gd


## Minimal stand-in for a damageable unit.  Records every take_damage call so
## the test can assert none arrived.
class FakeTarget extends Node3D:
	var alive_count: int = 1
	var owner_id: int = 0
	var damage_log: Array = []

	func take_damage(amount: int, _attacker) -> void:
		damage_log.append(amount)


func _init() -> void:
	# ---- scene setup -------------------------------------------------------
	# _spawn_impact uses get_tree().current_scene (without null guards on some
	# paths: lines 914 and 924 in projectile.gd) for AudioManager /
	# ParticleEmitterManager lookups.  We must set current_scene so those
	# calls don't crash with a null dereference.
	var scene_root := Node3D.new()
	scene_root.name = "TestScene"
	get_root().add_child(scene_root)
	# SceneTree.current_scene is assignable; point it at our stub root so
	# projectile.gd's get_tree().current_scene.get_node_or_null(...) resolves.
	current_scene = scene_root

	# _spawn_impact looks for AudioManager and ParticleEmitterManager under
	# current_scene via get_node_or_null -- they must exist as named nodes or
	# the lookups return null (which is safe).  Add empty stubs so the guard
	# branches resolve without crashing even if the null-check pattern ever
	# changes slightly.
	var audio_stub := Node.new()
	audio_stub.name = "AudioManager"
	scene_root.add_child(audio_stub)

	var pem_stub := Node.new()
	pem_stub.name = "ParticleEmitterManager"
	scene_root.add_child(pem_stub)

	# ---- test: no-payload Projectile does not damage on _spawn_impact ------
	var fake_target := FakeTarget.new()
	fake_target.name = "FakeTarget"
	fake_target.position = Vector3(10.0, 0.0, 0.0)
	scene_root.add_child(fake_target)

	# Projectile is registered via class_name Projectile (scripts/projectile.gd).
	# The --path flag causes Godot to index global class names, so we can
	# reference it directly.  Fallback to load() in case the headless harness
	# hasn't indexed it yet.
	var proj: Projectile = null
	if ClassDB.class_exists("Projectile"):
		# class_name registered -- call the static factory directly.
		# Signature: create(from, to, role_tag, rof_tier, style_override, shooter_faction)
		# &"fast" rof_tier resolves to "bullet" style via ROF_STYLES.
		# No set_damage_payload call -- this simulates the hitscan path where
		# CombatComponent fires damage instantly and spawns a cosmetic-only tracer.
		proj = Projectile.create(
				Vector3.ZERO,
				Vector3(10.0, 0.0, 0.0),
				&"AP",
				&"fast",
				&"",
				0)
	else:
		# Fallback: load via resource path (slower but always works).
		var ProjectileScript: GDScript = load("res://scripts/projectile.gd") as GDScript
		if ProjectileScript == null:
			push_error("FAIL: could not load res://scripts/projectile.gd")
			quit(1)
			return
		proj = ProjectileScript.call("create",
				Vector3.ZERO,
				Vector3(10.0, 0.0, 0.0),
				&"AP",
				&"fast",
				&"",
				0) as Projectile

	if proj == null:
		push_error("FAIL: Projectile.create() returned null")
		quit(1)
		return

	# Verify the pending_damage field is 0 before we even call _spawn_impact.
	if proj.get("pending_damage") != 0:
		push_error("FAIL: fresh Projectile has pending_damage=%d (expected 0)" \
				% [proj.get("pending_damage") as int])
		proj.queue_free()
		quit(1)
		return

	print("OK: fresh Projectile.pending_damage == 0")

	# Parent to the scene so get_tree() works inside _spawn_impact.
	scene_root.add_child(proj)

	# Directly call _spawn_impact.  With pending_damage == 0 the damage branch
	# is skipped entirely (guarded by `if pending_damage > 0`).
	# With pending_splash_radius == 0 the splash branch is also skipped.
	# AudioManager / ParticleEmitterManager stubs absorb any node lookups.
	proj._spawn_impact()

	# Assert: no damage reached the fake target.
	if fake_target.damage_log.size() > 0:
		push_error("FAIL: FakeTarget.damage_log is non-empty after _spawn_impact — " +
				"double-damage regression: %s" % [str(fake_target.damage_log)])
		quit(1)
		return

	print("OK: _spawn_impact() on a no-payload Projectile did not call take_damage")
	print("OK: hitscan no-double-apply test PASSED")

	# ---- second test skipped (deliberate scope decision) -------------------
	# Verifying that CombatComponent._fire_weapon calls take_damage synchronously
	# requires instantiating a Unit parent with many scene-tree signals, autoloads
	# (PlayerRegistry, SpatialIndex, etc.) and a fully-wired WeaponResource.
	# That scaffolding would be disproportionately brittle for a headless test.
	# The first test already covers the invariant the perf optimization depends on.

	quit(0)
