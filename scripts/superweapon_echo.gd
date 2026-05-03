class_name SuperweaponEcho
extends SuperweaponComponent
## Meridian Protocol's EChO (Electronic Combat Override). After the
## ARMING channel, paralyzes every enemy mech inside the
## superweapon_radius for the FIRING duration -- weapons offline,
## movement halted. Units take no damage. Effect applies once on
## firing-start; the firing window is the paralysis duration so the
## state machine plays out naturally.
##
## Firing visuals: a violet broadcast pulse fires from the array
## beacon up into the sky, an expanding violet shockwave + decal
## ring lands at the target, and each paralyzed unit gets a small
## violet flash above its head so the player can see which mechs
## are offline.

const PARALYSIS_SECONDS: float = 12.0
const ECHO_NEON: Color = Color(0.78, 0.42, 1.0, 1.0)
const SHOCKWAVE_RING_LIFETIME: float = 1.6
const BROADCAST_BEAM_LIFETIME: float = 1.4


func _start_firing() -> void:
	super()
	_play_broadcast_visual()
	_apply_override(PARALYSIS_SECONDS)
	_play_shockwave_at_target()


func _apply_override(duration: float) -> void:
	var radius_sq: float = _radius * _radius
	var owner_id_v: Variant = _building.get("owner_id") if _building and "owner_id" in _building else 0
	var caster_owner: int = (owner_id_v as int) if owner_id_v is int else 0
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		# Friendlies + allies are immune. Each unit's owner_id passes
		# through PlayerRegistry.are_allied so 2v2 partners don't
		# get paralyzed by their teammate's broadcast.
		var n_owner: int = (n3.get("owner_id") as int) if "owner_id" in n3 else -1
		if n_owner == caster_owner or _are_allied(caster_owner, n_owner):
			continue
		var dx: float = n3.global_position.x - _target_pos.x
		var dz: float = n3.global_position.z - _target_pos.z
		if dx * dx + dz * dz > radius_sq:
			continue
		# Hand off to Unit's apply_emp_paralysis -- silences combat
		# AND arms the per-frame velocity-zero gate so the AI can't
		# keep dragging the mech across the override zone with
		# spammed move commands.
		if n3.has_method("apply_emp_paralysis"):
			n3.call("apply_emp_paralysis", duration)
		else:
			# Fallback for non-Unit entities in the units group.
			var combat: Node = null
			if n3.has_method("get_combat"):
				combat = n3.call("get_combat")
			if combat and combat.has_method("apply_silence"):
				combat.call("apply_silence", duration)
			if n3.has_method("stop"):
				n3.call("stop")
		# Per-unit pulse flash -- a small violet sparkle above the
		# unit so the player sees exactly who went offline.
		_spawn_unit_pulse(n3.global_position + Vector3(0.0, 1.4, 0.0))


func _play_broadcast_visual() -> void:
	## Fires a tall violet beam straight up from the EChO beacon and
	## a series of expanding rings around the array so the building
	## reads as 'broadcasting' rather than just sitting there. Audio
	## carries a low broadcast hum + pop layered on top.
	if not _building or not is_instance_valid(_building):
		return
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return
	var beacon_pos: Vector3 = _building.global_position + Vector3(0.0, 6.0, 0.0)
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem:
		pem.call("emit_flash", beacon_pos, ECHO_NEON, 24)
		pem.call("emit_spark", beacon_pos, 18)
	# Tall violet beam shooting up from the beacon -- a stretched
	# cylinder tinted with the Meridian neon. Auto-frees after a
	# short lifetime so the visual is a flash rather than a beam
	# that lingers through the whole firing window.
	_spawn_broadcast_beam(scene, beacon_pos)
	# Three nested expanding rings around the array base for the
	# 'broadcast going out in every direction' read.
	for i: int in 3:
		_spawn_expanding_ring(
			scene,
			_building.global_position + Vector3(0.0, 0.4, 0.0),
			3.5,
			14.0,
			SHOCKWAVE_RING_LIFETIME + float(i) * 0.20,
			float(i) * 0.18,
		)
	var audio: Node = scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_huge_explosion"):
		audio.call("play_huge_explosion", beacon_pos)


func _play_shockwave_at_target() -> void:
	## Lands a violet shockwave at the strike point: a big flash, a
	## shower of sparks, and an expanding ring decal sized to the
	## paralysis radius so both players can see the override zone.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem:
		pem.call("emit_flash", _target_pos + Vector3(0, 1.5, 0), ECHO_NEON, 32)
		pem.call("emit_spark", _target_pos + Vector3(0, 0.6, 0), 28)
	_spawn_expanding_ring(
		scene,
		_target_pos + Vector3(0, 0.25, 0),
		_radius * 0.18,
		_radius,
		SHOCKWAVE_RING_LIFETIME,
		0.0,
	)
	var audio: Node = scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_huge_explosion"):
		audio.call("play_huge_explosion", _target_pos)


func _spawn_unit_pulse(pos: Vector3) -> void:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem:
		pem.call("emit_flash", pos, ECHO_NEON, 6)
		pem.call("emit_spark", pos, 4)


func _spawn_broadcast_beam(scene: Node, base: Vector3) -> void:
	## A short-lived stretched cylinder firing straight up from the
	## EChO beacon so the array visibly broadcasts on activation.
	var beam: MeshInstance3D = MeshInstance3D.new()
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.85
	cyl.height = 28.0
	cyl.radial_segments = 12
	beam.mesh = cyl
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(ECHO_NEON.r, ECHO_NEON.g, ECHO_NEON.b, 0.55)
	mat.emission_enabled = true
	mat.emission = ECHO_NEON
	mat.emission_energy_multiplier = 3.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	beam.set_surface_override_material(0, mat)
	beam.position = base + Vector3(0, cyl.height * 0.5, 0)
	scene.add_child(beam)
	var timer: SceneTreeTimer = scene.get_tree().create_timer(BROADCAST_BEAM_LIFETIME)
	timer.timeout.connect(beam.queue_free)


func _spawn_expanding_ring(
	scene: Node,
	at: Vector3,
	start_radius: float,
	end_radius: float,
	lifetime: float,
	delay: float,
) -> void:
	## Tweenable flat ring that grows from start_radius to end_radius
	## across `lifetime` seconds while fading out. Used for both the
	## broadcast halo around the array and the shockwave at target.
	var root: Node3D = Node3D.new()
	root.position = at
	scene.add_child(root)
	var ring: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.outer_radius = maxf(start_radius, 0.1)
	torus.inner_radius = maxf(start_radius - 0.4, 0.05)
	ring.mesh = torus
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = ECHO_NEON
	mat.emission_enabled = true
	mat.emission = ECHO_NEON
	mat.emission_energy_multiplier = 2.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, mat)
	root.add_child(ring)
	if delay > 0.0:
		ring.visible = false
		var d_timer: SceneTreeTimer = scene.get_tree().create_timer(delay)
		d_timer.timeout.connect(func() -> void:
			if is_instance_valid(ring):
				ring.visible = true
		)
	var tween: Tween = root.create_tween()
	tween.set_parallel(true)
	tween.tween_property(torus, "outer_radius", end_radius, lifetime)
	tween.tween_property(torus, "inner_radius", maxf(end_radius - 0.6, 0.05), lifetime)
	tween.tween_property(mat, "albedo_color:a", 0.0, lifetime)
	tween.chain().tween_callback(root.queue_free)


func _are_allied(a: int, b: int) -> bool:
	if a == b:
		return true
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("are_allied"):
		return registry.call("are_allied", a, b) as bool
	return false
