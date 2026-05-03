class_name SuperweaponMolot
extends SuperweaponComponent
## The Combine's MOLOT artillery superweapon. Across superweapon_firing_sec
## the platform fires ~SHELLS_PER_SECOND shells per second, each with a
## random offset inside superweapon_radius. Damage is friendly-fire — every
## unit, building, and crawler inside SHELL_RADIUS of an impact takes the
## hit, regardless of allegiance.
##
## Each fired shell plays a heavy muzzle blast at the barrel tip, then
## resolves a delayed impact (SHELL_TRAVEL_SEC later) so the player sees
## the 'shot fired -> shell rains down' beats land separately.

const SHELLS_PER_SECOND: float = 1.1   # ~33 shells over a 30s firing window
const SHELL_BASE_DAMAGE: int = 220
const SHELL_RADIUS: float = 6.0
const SHELL_TRAVEL_SEC_MIN: float = 1.1
const SHELL_TRAVEL_SEC_MAX: float = 1.7


func _start_firing() -> void:
	## Snap the turret to face the strike target before the first
	## shell fires so the barrel visibly points the right way the
	## moment FIRING begins.
	super()
	_aim_turret_at_target()


func _firing_tick(delta: float) -> void:
	# Fire one shell every (1 / SHELLS_PER_SECOND) seconds, picking
	# a random offset inside the superweapon radius. _effect_scratch
	# accumulates so partial-tick deltas don't drop shells.
	_effect_scratch += delta * SHELLS_PER_SECOND
	while _effect_scratch >= 1.0:
		_effect_scratch -= 1.0
		_fire_shell()


func _aim_turret_at_target() -> void:
	if not _building or not is_instance_valid(_building):
		return
	var pivot: Node3D = _building.get("molot_turret_pivot") as Node3D
	if not pivot:
		return
	var to_target: Vector3 = _target_pos - pivot.global_position
	var horiz_sq: float = to_target.x * to_target.x + to_target.z * to_target.z
	if horiz_sq < 0.01:
		return
	# Pivot is parented under _visual_root which carries a small
	# random Y-rotation per building. Snapping global_transform
	# instead of rotation.y bypasses that offset cleanly so the
	# barrel always points at the target's world position. The
	# barrel sub-tree was built along +Z so a Basis from +Z toward
	# the target is what we want.
	var yaw: float = atan2(to_target.x, to_target.z)
	pivot.global_transform = Transform3D(
		Basis(Vector3.UP, yaw),
		pivot.global_position,
	)


func _fire_shell() -> void:
	# Random impact inside the superweapon radius -- biased toward
	# the edge a bit so the carpet pattern feels broad rather than
	# crater-piling the centre.
	var ang: float = randf_range(0.0, TAU)
	var r: float = sqrt(randf_range(0.0, 1.0)) * _radius
	var impact: Vector3 = _target_pos + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	# Muzzle blast at the barrel mouth -- big orange flash + smoke
	# + the heavy-explosion audio bank so the player hears the gun
	# go off before the shell lands.
	_spawn_muzzle_blast()
	# Schedule the impact for SHELL_TRAVEL_SEC_MIN..MAX from now.
	var travel: float = randf_range(SHELL_TRAVEL_SEC_MIN, SHELL_TRAVEL_SEC_MAX)
	var timer: SceneTreeTimer = get_tree().create_timer(travel)
	timer.timeout.connect(_resolve_shell.bind(impact))


func _spawn_muzzle_blast() -> void:
	if not _building or not is_instance_valid(_building):
		return
	var muzzle: Node3D = _building.get("molot_muzzle") as Node3D
	var pos: Vector3 = muzzle.global_position if muzzle else _building.global_position + Vector3(0, 4.0, 0)
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
		if pem:
			pem.call("emit_flash", pos, Color(1.0, 0.65, 0.20, 1.0), 14)
			pem.call("emit_smoke", pos + Vector3(0, 0.4, 0), Vector3(0, 2.6, 0), Color(0.30, 0.24, 0.20, 0.85))
			pem.call("emit_spark", pos, 18)
		var audio: Node = scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_unit_destroyed"):
			audio.call("play_unit_destroyed", pos, true)


func _resolve_shell(impact: Vector3) -> void:
	# Friendly-fire splash inside SHELL_RADIUS. Hits units, crawlers,
	# and buildings of any allegiance; the firer's building is the
	# only excluded target so the platform doesn't blow itself up by
	# arming a strike on its own footprint.
	var splash_sq: float = SHELL_RADIUS * SHELL_RADIUS
	var groups: Array[String] = ["units", "buildings", "crawlers"]
	for g: String in groups:
		for node: Node in get_tree().get_nodes_in_group(g):
			if not is_instance_valid(node) or node == _building:
				continue
			if not node.has_method("take_damage"):
				continue
			var n3: Node3D = node as Node3D
			if not n3:
				continue
			var dx: float = n3.global_position.x - impact.x
			var dz: float = n3.global_position.z - impact.z
			var dist_sq: float = dx * dx + dz * dz
			if dist_sq > splash_sq:
				continue
			var falloff: float = clampf(1.0 - sqrt(dist_sq) / SHELL_RADIUS * 0.6, 0.4, 1.0)
			# AS role multiplier so structures eat the full hit and
			# units take a fraction (matches the doc's "light units
			# in the zone are wiped, heavies take significant HP").
			var target_armor: StringName = &"medium"
			if "stats" in n3:
				var ts: Variant = n3.get("stats")
				if typeof(ts) == TYPE_OBJECT and is_instance_valid(ts):
					var unit_stats: UnitStatResource = ts as UnitStatResource
					if unit_stats:
						target_armor = unit_stats.armor_class
			if n3.is_in_group("buildings"):
				target_armor = &"structure"
			var role_mod: float = CombatTables.get_role_modifier(&"AS", target_armor)
			var armor_red: float = CombatTables.get_armor_reduction(target_armor)
			var dmg: float = float(SHELL_BASE_DAMAGE) * role_mod * (1.0 - armor_red) * falloff
			node.take_damage(int(dmg), _building)
	_spawn_impact_vfx(impact)


func _spawn_impact_vfx(pos: Vector3) -> void:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem:
		pem.call("emit_flash", pos + Vector3(0, 1.2, 0), Color(1.0, 0.55, 0.18, 1.0), 32)
		pem.call("emit_smoke", pos + Vector3(0, 0.6, 0), Vector3(0, 3.5, 0), Color(0.32, 0.24, 0.18, 0.92))
		pem.call("emit_spark", pos + Vector3(0, 0.5, 0), 36)
		if pem.has_method("emit_dust"):
			pem.call("emit_dust", pos, 22, 1.8)
	# Big explicit fireball -- a sphere mesh that flashes bright,
	# scales up, and fades to nothing across ~0.9s. Sits on top of
	# the particle burst as the unmissable 'a shell hit here' read
	# in case the GPU particle bank is starved.
	_spawn_impact_fireball(scene, pos)
	# Brief vertical orange pillar so the impact reads even when
	# the camera is zoomed far out -- a stretched cylinder visible
	# above any unit-level visual clutter.
	_spawn_impact_pillar(scene, pos)
	var audio: Node = scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_unit_destroyed"):
		audio.call("play_unit_destroyed", pos, true)


func _spawn_impact_fireball(scene: Node, pos: Vector3) -> void:
	var ball: MeshInstance3D = MeshInstance3D.new()
	var sph: SphereMesh = SphereMesh.new()
	sph.radius = 1.8
	sph.height = 3.6
	ball.mesh = sph
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.18, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.42, 0.10, 1.0)
	mat.emission_energy_multiplier = 4.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ball.set_surface_override_material(0, mat)
	ball.position = pos + Vector3(0, 1.6, 0)
	scene.add_child(ball)
	var tween: Tween = ball.create_tween()
	tween.set_parallel(true)
	tween.tween_property(ball, "scale", Vector3(2.4, 2.4, 2.4), 0.85)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.85)
	tween.tween_property(mat, "emission_energy_multiplier", 0.0, 0.85)
	tween.chain().tween_callback(ball.queue_free)


func _spawn_impact_pillar(scene: Node, pos: Vector3) -> void:
	var pillar: MeshInstance3D = MeshInstance3D.new()
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = 0.6
	cyl.bottom_radius = 1.4
	cyl.height = 9.0
	cyl.radial_segments = 12
	pillar.mesh = cyl
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.50, 0.16, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.40, 0.08, 1.0)
	mat.emission_energy_multiplier = 3.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pillar.set_surface_override_material(0, mat)
	pillar.position = pos + Vector3(0, cyl.height * 0.5, 0)
	scene.add_child(pillar)
	var tween: Tween = pillar.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.65)
	tween.tween_property(mat, "emission_energy_multiplier", 0.0, 0.65)
	tween.chain().tween_callback(pillar.queue_free)
