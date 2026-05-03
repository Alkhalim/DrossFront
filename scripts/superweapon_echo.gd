class_name SuperweaponEcho
extends SuperweaponComponent
## Meridian Protocol's EChO (Electronic Combat Override). After the
## ARMING channel, paralyzes every enemy mech inside the
## superweapon_radius for the FIRING duration -- weapons offline,
## movement halted. Units take no damage. Effect applies once on
## firing-start; the firing window is the paralysis duration so the
## state machine plays out naturally.

const PARALYSIS_SECONDS: float = 12.0


func _start_firing() -> void:
	super()
	_apply_override(PARALYSIS_SECONDS)


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
		# Route through the unit's combat component so the existing
		# silence machinery (silence_remaining gates firing already)
		# carries the weapon-offline half of the effect. Movement
		# halt: stop() + clear move target so the paralyzed unit
		# stands still even if it had a queued waypoint.
		var combat: Node = null
		if n3.has_method("get_combat"):
			combat = n3.call("get_combat")
		if combat and "_silence_remaining" in combat:
			combat.set("_silence_remaining", duration)
		if n3.has_method("stop"):
			n3.call("stop")
	# Visual telegraph at the centre -- a brief violet pulse so the
	# 600u override zone reads on impact. Reuses the same particle
	# emitter the ammo dump explosion uses for cheap reuse.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
		if pem:
			pem.call("emit_flash", _target_pos + Vector3(0, 1.5, 0), Color(0.78, 0.42, 1.0, 1.0), 24)
		var audio: Node = scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_huge_explosion"):
			audio.call("play_huge_explosion", _target_pos)


func _are_allied(a: int, b: int) -> bool:
	if a == b:
		return true
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("are_allied"):
		return registry.call("are_allied", a, b) as bool
	return false
