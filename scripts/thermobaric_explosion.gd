class_name ThermobaricExplosion
extends Node3D
## Massive fuel-air detonation with a persistent damage aura that
## pulses for several seconds after impact. Spawned by ProjectileManager
## when a `thermobaric` projectile lands. Distinct from a normal bomb
## impact in that:
##   - The visible fireball is much larger (expanding orange sphere +
##     bright white-hot core + secondary shockwave ring).
##   - A damage-aura disc lingers in the crater for AURA_DURATION_SEC,
##     pulsing damage every AURA_TICK_SEC to anything inside it. Sells
##     "the fuel kept burning for ages" without spawning a full
##     particle system.

## Visual fireball — sphere expands from 0 → MAX_FIREBALL_RADIUS over
## FIREBALL_EXPAND_SEC, then fades over FIREBALL_FADE_SEC.
const MAX_FIREBALL_RADIUS: float = 10.0
const FIREBALL_EXPAND_SEC: float = 0.45
const FIREBALL_FADE_SEC: float = 0.85

## Persistent damage aura — pulses on a fixed interval. Each pulse
## applies AURA_DAMAGE_PER_PULSE to everything (friend OR foe) within
## AURA_RADIUS. The whole effect lasts AURA_DURATION_SEC.
const AURA_RADIUS: float = 9.0
const AURA_DURATION_SEC: float = 5.0
const AURA_TICK_SEC: float = 0.75
const AURA_DAMAGE_PER_PULSE: int = 25

## One-shot impact blast — fires once on spawn, synchronised with the
## fireball animation. Linear falloff from IMPACT_DAMAGE_CENTER at
## ground zero to IMPACT_DAMAGE_EDGE at AURA_RADIUS. Applied IN ADDITION
## to the burn aura so a direct hit is genuinely lethal to anything
## near the impact point, while units caught in the outer ring still
## take meaningful damage. Anything past AURA_RADIUS is untouched.
const IMPACT_DAMAGE_CENTER: int = 300
const IMPACT_DAMAGE_EDGE: int = 100

## Visual pulse — the lingering ring on the ground flashes brighter
## on each damage tick so the player can read "this is still hurting
## things".
const RING_PULSE_BRIGHT: float = 2.5
const RING_PULSE_REST: float = 1.0

## Shockwave — flat expanding ring on the ground beneath the impact.
## Visible separately from the fireball, sells the airblast.
const SHOCKWAVE_MAX_RADIUS: float = 14.0
const SHOCKWAVE_EXPAND_SEC: float = 0.50

var _life: float = 0.0
var _aura_tick_accum: float = 0.0
var _aura_pulse_visual_until: float = 0.0
var _shooter_owner_id: int = -1
var _shooter: Node3D = null
## All meshes spawned by the explosion so we can mutate / free them
## across the life of the effect.
var _fireball: MeshInstance3D = null
var _fireball_core: MeshInstance3D = null
var _shockwave: MeshInstance3D = null
var _aura_ring: MeshInstance3D = null
var _fireball_mat: StandardMaterial3D = null
var _fireball_core_mat: StandardMaterial3D = null
var _shockwave_mat: StandardMaterial3D = null
var _aura_ring_mat: StandardMaterial3D = null
var _aura_light: OmniLight3D = null


static func spawn_at(scene_root: Node, pos: Vector3, shooter: Node3D, shooter_owner_id: int) -> ThermobaricExplosion:
	if scene_root == null:
		return null
	var ex := ThermobaricExplosion.new()
	ex._shooter = shooter
	ex._shooter_owner_id = shooter_owner_id
	scene_root.add_child(ex)
	ex.global_position = Vector3(pos.x, 0.1, pos.z)
	return ex


func _ready() -> void:
	# Group so FoW + cleanup paths can find the explosion VFX the
	# same way they find other transient effects.
	add_to_group("projectiles")
	_build_visual()
	# One-shot impact blast — 300 → 100 linear falloff out to AURA_RADIUS.
	# Fired before the first aura tick so the impact frame stacks the
	# detonation hit with the first burn pulse (matches the visible
	# fireball flash on spawn).
	_apply_impact_blast()
	# Fire the first damage pulse immediately on spawn — the initial
	# detonation IS the first pulse, not a free first tick.
	_apply_aura_pulse()
	_aura_pulse_visual_until = 0.18


func _build_visual() -> void:
	const FIREBALL_ORANGE: Color = Color(1.00, 0.55, 0.15, 0.85)
	const FIREBALL_HOT_WHITE: Color = Color(1.00, 0.88, 0.55, 1.0)
	const SHOCKWAVE_AMBER: Color = Color(1.00, 0.68, 0.22, 0.65)
	const AURA_BURN: Color = Color(0.95, 0.42, 0.12, 0.55)

	# Outer expanding fireball — sphere starts tiny and scales up.
	_fireball = MeshInstance3D.new()
	_fireball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fbm := SphereMesh.new()
	fbm.radius = 1.0  # we scale via Node3D.scale so the mesh stays unit-radius
	fbm.height = 2.0
	fbm.radial_segments = 14
	fbm.rings = 10
	_fireball.mesh = fbm
	_fireball.scale = Vector3.ONE * 0.10
	_fireball_mat = StandardMaterial3D.new()
	_fireball_mat.albedo_color = FIREBALL_ORANGE
	_fireball_mat.emission_enabled = true
	_fireball_mat.emission = FIREBALL_ORANGE
	_fireball_mat.emission_energy_multiplier = 3.0
	_fireball_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fireball_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fireball_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fireball.set_surface_override_material(0, _fireball_mat)
	add_child(_fireball)

	# Inner white-hot core — same expansion curve, smaller.
	_fireball_core = MeshInstance3D.new()
	_fireball_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fcm := SphereMesh.new()
	fcm.radius = 1.0
	fcm.height = 2.0
	fcm.radial_segments = 12
	fcm.rings = 8
	_fireball_core.mesh = fcm
	_fireball_core.scale = Vector3.ONE * 0.05
	_fireball_core_mat = StandardMaterial3D.new()
	_fireball_core_mat.albedo_color = FIREBALL_HOT_WHITE
	_fireball_core_mat.emission_enabled = true
	_fireball_core_mat.emission = FIREBALL_HOT_WHITE
	_fireball_core_mat.emission_energy_multiplier = 5.0
	_fireball_core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fireball_core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fireball_core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fireball_core.set_surface_override_material(0, _fireball_core_mat)
	add_child(_fireball_core)

	# Ground shockwave — flat ring expanding outward.
	_shockwave = MeshInstance3D.new()
	_shockwave.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var swm := TorusMesh.new()
	swm.inner_radius = 0.9
	swm.outer_radius = 1.0
	swm.rings = 32
	swm.ring_segments = 4
	_shockwave.mesh = swm
	_shockwave.scale = Vector3.ONE * 0.20
	_shockwave.position = Vector3(0.0, 0.05, 0.0)
	_shockwave_mat = StandardMaterial3D.new()
	_shockwave_mat.albedo_color = SHOCKWAVE_AMBER
	_shockwave_mat.emission_enabled = true
	_shockwave_mat.emission = SHOCKWAVE_AMBER
	_shockwave_mat.emission_energy_multiplier = 2.0
	_shockwave_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shockwave_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shockwave_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_shockwave.set_surface_override_material(0, _shockwave_mat)
	add_child(_shockwave)

	# Persistent burning aura — a thicker ground ring that pulses
	# brighter on each damage tick. Lives for AURA_DURATION_SEC.
	_aura_ring = MeshInstance3D.new()
	_aura_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var arm := CylinderMesh.new()
	arm.top_radius = AURA_RADIUS
	arm.bottom_radius = AURA_RADIUS
	arm.height = 0.10
	arm.radial_segments = 48
	_aura_ring.mesh = arm
	_aura_ring.position = Vector3(0.0, 0.06, 0.0)
	_aura_ring_mat = StandardMaterial3D.new()
	_aura_ring_mat.albedo_color = AURA_BURN
	_aura_ring_mat.emission_enabled = true
	_aura_ring_mat.emission = AURA_BURN
	_aura_ring_mat.emission_energy_multiplier = RING_PULSE_REST
	_aura_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_aura_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_aura_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_aura_ring.set_surface_override_material(0, _aura_ring_mat)
	add_child(_aura_ring)

	# Bright amber omni-light — visible flash that bathes the
	# surrounding terrain. Decays with the fireball.
	_aura_light = OmniLight3D.new()
	_aura_light.light_color = FIREBALL_ORANGE
	_aura_light.light_energy = 3.5
	_aura_light.omni_range = 16.0
	_aura_light.position = Vector3(0.0, 1.5, 0.0)
	add_child(_aura_light)


func _process(delta: float) -> void:
	_life += delta

	# Fireball expand-then-fade.
	if _fireball and _fireball_mat:
		var fb_t: float = clampf(_life / FIREBALL_EXPAND_SEC, 0.0, 1.0)
		var fb_scale: float = lerp(0.10, MAX_FIREBALL_RADIUS, fb_t)
		_fireball.scale = Vector3.ONE * fb_scale
		# Fade alpha after expansion completes.
		if _life > FIREBALL_EXPAND_SEC:
			var fade_t: float = clampf((_life - FIREBALL_EXPAND_SEC) / FIREBALL_FADE_SEC, 0.0, 1.0)
			_fireball_mat.albedo_color.a = lerp(0.85, 0.0, fade_t)
			_fireball_mat.emission_energy_multiplier = lerp(3.0, 0.0, fade_t)
	if _fireball_core and _fireball_core_mat:
		var fc_t: float = clampf(_life / (FIREBALL_EXPAND_SEC * 0.65), 0.0, 1.0)
		_fireball_core.scale = Vector3.ONE * lerp(0.05, MAX_FIREBALL_RADIUS * 0.55, fc_t)
		if _life > FIREBALL_EXPAND_SEC * 0.65:
			var cfade: float = clampf((_life - FIREBALL_EXPAND_SEC * 0.65) / (FIREBALL_FADE_SEC * 0.5), 0.0, 1.0)
			_fireball_core_mat.albedo_color.a = lerp(1.0, 0.0, cfade)
			_fireball_core_mat.emission_energy_multiplier = lerp(5.0, 0.0, cfade)

	# Shockwave — quick expansion + fade.
	if _shockwave and _shockwave_mat:
		var sw_t: float = clampf(_life / SHOCKWAVE_EXPAND_SEC, 0.0, 1.0)
		_shockwave.scale = Vector3.ONE * lerp(0.20, SHOCKWAVE_MAX_RADIUS, sw_t)
		_shockwave_mat.albedo_color.a = lerp(0.65, 0.0, sw_t)
		_shockwave_mat.emission_energy_multiplier = lerp(2.0, 0.0, sw_t)

	# Aura ring — persists for AURA_DURATION_SEC, pulses on each
	# damage tick, then fades cleanly.
	if _aura_ring and _aura_ring_mat:
		if _life < AURA_DURATION_SEC:
			# Pulse-visual interpolation: bright for the first 0.18s
			# after a damage tick, otherwise sit at rest brightness.
			if _life < _aura_pulse_visual_until:
				_aura_ring_mat.emission_energy_multiplier = RING_PULSE_BRIGHT
			else:
				_aura_ring_mat.emission_energy_multiplier = RING_PULSE_REST
		else:
			# Final fade-out over 0.5s after the aura expires.
			var fade_t: float = clampf((_life - AURA_DURATION_SEC) / 0.5, 0.0, 1.0)
			_aura_ring_mat.albedo_color.a = lerp(0.55, 0.0, fade_t)
			_aura_ring_mat.emission_energy_multiplier = lerp(RING_PULSE_REST, 0.0, fade_t)

	# Omni-light decays with the fireball.
	if _aura_light:
		var lt_t: float = clampf(_life / (FIREBALL_EXPAND_SEC + FIREBALL_FADE_SEC), 0.0, 1.0)
		_aura_light.light_energy = lerp(3.5, 0.3, lt_t)

	# Damage aura pulse — every AURA_TICK_SEC inside the AURA window.
	if _life < AURA_DURATION_SEC:
		_aura_tick_accum += delta
		if _aura_tick_accum >= AURA_TICK_SEC:
			_aura_tick_accum -= AURA_TICK_SEC
			_apply_aura_pulse()
			_aura_pulse_visual_until = _life + 0.18

	# Cleanup once the aura + fireball + shockwave have all expired.
	if _life > AURA_DURATION_SEC + 0.6:
		queue_free()


func _apply_impact_blast() -> void:
	## One-shot detonation damage at spawn. Linear falloff from
	## IMPACT_DAMAGE_CENTER at distance 0 to IMPACT_DAMAGE_EDGE at
	## AURA_RADIUS. Anything past AURA_RADIUS is untouched. Hits hostile
	## units AND hostile buildings; the burn aura that follows handles
	## the sustained DOT separately.
	var scene_tree: SceneTree = get_tree()
	if scene_tree == null:
		return
	# Re-validate the stored shooter — Condor squads can be wiped before
	# the bomb finishes its arc. Passing a freed reference into
	# take_damage(... attacker) crashes the typed-arg check on Building.
	var shooter_arg: Node3D = _shooter if (_shooter != null and is_instance_valid(_shooter)) else null
	var origin: Vector3 = global_position
	var r2: float = AURA_RADIUS * AURA_RADIUS
	for node: Node in scene_tree.get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		if not _is_hostile(node):
			continue
		var n3: Node3D = node as Node3D
		if n3 == null:
			continue
		var d2: float = n3.global_position.distance_squared_to(origin)
		if d2 > r2:
			continue
		var d: float = sqrt(d2)
		var t: float = clampf(d / AURA_RADIUS, 0.0, 1.0)
		var dmg: int = maxi(int(round(lerp(float(IMPACT_DAMAGE_CENTER), float(IMPACT_DAMAGE_EDGE), t))), 1)
		if node.has_method("take_damage"):
			node.call("take_damage", dmg, shooter_arg)
	for node: Node in scene_tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if not _is_hostile(node):
			continue
		var n3b: Node3D = node as Node3D
		if n3b == null:
			continue
		var d2b: float = n3b.global_position.distance_squared_to(origin)
		if d2b > r2:
			continue
		var db: float = sqrt(d2b)
		var tb: float = clampf(db / AURA_RADIUS, 0.0, 1.0)
		var dmgb: int = maxi(int(round(lerp(float(IMPACT_DAMAGE_CENTER), float(IMPACT_DAMAGE_EDGE), tb))), 1)
		if node.has_method("take_damage"):
			node.call("take_damage", dmgb, shooter_arg)


func _apply_aura_pulse() -> void:
	## Single damage pulse — anything within AURA_RADIUS that's hostile
	## to the shooter takes AURA_DAMAGE_PER_PULSE. Buildings counted
	## from their centre; units from their squad position.
	var scene_tree: SceneTree = get_tree()
	if scene_tree == null:
		return
	var shooter_arg: Node3D = _shooter if (_shooter != null and is_instance_valid(_shooter)) else null
	var origin: Vector3 = global_position
	var r2: float = AURA_RADIUS * AURA_RADIUS
	for node: Node in scene_tree.get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		if not _is_hostile(node):
			continue
		var n3: Node3D = node as Node3D
		if n3 == null:
			continue
		if n3.global_position.distance_squared_to(origin) > r2:
			continue
		if node.has_method("take_damage"):
			node.call("take_damage", AURA_DAMAGE_PER_PULSE, shooter_arg)
	for node: Node in scene_tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if not _is_hostile(node):
			continue
		var n3b: Node3D = node as Node3D
		if n3b == null:
			continue
		if n3b.global_position.distance_squared_to(origin) > r2:
			continue
		if node.has_method("take_damage"):
			node.call("take_damage", AURA_DAMAGE_PER_PULSE, shooter_arg)


func _is_hostile(node: Node) -> bool:
	if not ("owner_id" in node):
		return false
	var their_oid: int = node.get("owner_id") as int
	if their_oid == _shooter_owner_id:
		return false
	var scene_root: Node = get_tree().current_scene if get_tree() else null
	var registry: Node = scene_root.get_node_or_null("PlayerRegistry") if scene_root else null
	if registry and registry.has_method("are_enemies"):
		return registry.call("are_enemies", _shooter_owner_id, their_oid) as bool
	return true
