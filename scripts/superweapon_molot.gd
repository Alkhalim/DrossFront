class_name SuperweaponMolot
extends SuperweaponComponent
## The Combine's MOLOT artillery superweapon. Fires 20-40 shells in
## a spread pattern across superweapon_firing_sec inside
## superweapon_radius. Structures take heavy AS damage; mechs take
## significant HP damage; light units in the zone are wiped.

const SHELLS_PER_SECOND: float = 1.1   # ~33 shells over a 30s firing window
const SHELL_BASE_DAMAGE: int = 220
const SHELL_RADIUS: float = 6.0


func _firing_tick(delta: float) -> void:
	# Fire one shell every (1 / SHELLS_PER_SECOND) seconds, picking
	# a random offset inside the superweapon radius. _effect_scratch
	# accumulates so partial-tick deltas don't drop shells.
	_effect_scratch += delta * SHELLS_PER_SECOND
	while _effect_scratch >= 1.0:
		_effect_scratch -= 1.0
		_drop_shell()


func _drop_shell() -> void:
	# Random offset inside the radius -- biased toward the edge a
	# bit so the carpet pattern feels broad rather than crater-piling
	# the centre.
	var ang: float = randf_range(0.0, TAU)
	var r: float = sqrt(randf_range(0.0, 1.0)) * _radius
	var impact: Vector3 = _target_pos + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	# Damage application -- AS-tagged (anti-structure heavy, light vs
	# units), splash falloff inside SHELL_RADIUS.
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
	# Visual + audio puff at the impact site.
	_spawn_shell_vfx(impact)


func _spawn_shell_vfx(pos: Vector3) -> void:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem:
		pem.call("emit_flash", pos + Vector3(0, 1.0, 0), Color(1.0, 0.55, 0.18, 1.0), 6)
		var smoke_pos: Vector3 = pos + Vector3(0, 0.6, 0)
		pem.call("emit_smoke", smoke_pos, Vector3(0, 2.4, 0), Color(0.32, 0.24, 0.18, 0.85))
		pem.call("emit_spark", pos + Vector3(0, 0.5, 0), 8)
	var audio: Node = scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_impact"):
		audio.call("play_weapon_impact", pos)
