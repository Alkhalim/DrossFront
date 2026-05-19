class_name ChemicalCloud
extends Node3D
## Persistent toxic-green chemical cloud spawned by the Censer's oil
## barrel on impact. Lingers for CLOUD_DURATION_SEC and pulses damage
## to anything hostile inside CLOUD_RADIUS every CLOUD_TICK_SEC.
## Distinct from ThermobaricExplosion in three ways:
##   - No initial fireball; just the cloud fades in + lingers + fades out.
##   - Green / toxic palette, not orange / fire.
##   - DPS pulses are smaller per-tick but run for much longer, so the
##     cloud's identity is "area denial" rather than "burst kill".
## Mechanical damage runs even when the cloud is off-screen — _process
## ticks regardless of culling so the area DPS reads honestly.

## How long the cloud is active (damage pulses + visible cloud volume).
const CLOUD_DURATION_SEC: float = 8.0
## Damage aura radius. Matches the Censer's splash_radius so the
## visible cloud disc tells the truth about the actual AoE footprint.
const CLOUD_RADIUS: float = 5.0
## Damage pulse cadence + per-tick damage. 16 ticks total over the
## cloud's 8-second life — a target standing in it for the full
## duration takes 16 × CLOUD_DAMAGE_PER_PULSE = ~240 damage, which is
## moderately above a single mortar hit. The intent is to discourage
## sitting in the cloud, not to lawnmower full squads.
const CLOUD_TICK_SEC: float = 0.5
const CLOUD_DAMAGE_PER_PULSE: int = 15

## Visible cloud puffs — more puffs than the previous build, denser
## clump so the cloud reads as a real volume rather than a few
## floating spheres. Per playtest 2026-05-19.
const PUFF_COUNT: int = 11
const PUFF_BASE_RADIUS: float = 1.05
const PUFF_HEIGHT_BASE: float = 0.55

## Fade-in / fade-out windows. The cloud doesn't pop or vanish
## instantly — fades in over the first 0.45s and out over the last 1.0s.
const FADE_IN_SEC: float = 0.45
const FADE_OUT_SEC: float = 1.0

var _life: float = 0.0
var _tick_accum: float = 0.0
var _shooter_owner_id: int = -1
var _shooter: Node3D = null
var _ground_disc: MeshInstance3D = null
var _ground_disc_mat: StandardMaterial3D = null
var _puffs: Array[MeshInstance3D] = []
var _puff_mats: Array[StandardMaterial3D] = []
var _puff_phases: PackedFloat32Array = PackedFloat32Array()
var _puff_origins: Array[Vector3] = []
var _cloud_light: OmniLight3D = null


static func spawn_at(scene_root: Node, pos: Vector3, shooter: Node3D, shooter_owner_id: int) -> ChemicalCloud:
	if scene_root == null:
		return null
	var c := ChemicalCloud.new()
	c._shooter = shooter
	c._shooter_owner_id = shooter_owner_id
	scene_root.add_child(c)
	c.global_position = Vector3(pos.x, 0.0, pos.z)
	return c


func _ready() -> void:
	add_to_group("projectiles")
	_build_visual()
	# First damage tick fires on the next _process frame (not at spawn)
	# — gives units a beat to react before they start eating ticks.


func _build_visual() -> void:
	# Per playtest 2026-05-19: green effects too opaque. Cloud puffs +
	# disc alpha dropped to ~0.30 so the cloud reads as a faint
	# chemical mist rather than a flat painted disc on the ground.
	const TOXIC_GREEN: Color = Color(0.55, 0.85, 0.35, 0.30)
	const TOXIC_GREEN_BRIGHT: Color = Color(0.70, 0.95, 0.40, 1.0)
	const TOXIC_GREEN_DARK: Color = Color(0.30, 0.55, 0.20, 0.45)

	# Ground disc — flat green ring on the floor that marks the AoE
	# footprint. Cylinder mesh with very small height + radius =
	# CLOUD_RADIUS so the visible disc matches the actual damage area.
	_ground_disc = MeshInstance3D.new()
	_ground_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var disc := CylinderMesh.new()
	disc.top_radius = CLOUD_RADIUS
	disc.bottom_radius = CLOUD_RADIUS
	disc.height = 0.10
	disc.radial_segments = 48
	_ground_disc.mesh = disc
	_ground_disc.position = Vector3(0.0, 0.06, 0.0)
	_ground_disc_mat = StandardMaterial3D.new()
	_ground_disc_mat.albedo_color = TOXIC_GREEN
	_ground_disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ground_disc_mat.emission_enabled = true
	_ground_disc_mat.emission = TOXIC_GREEN_BRIGHT
	_ground_disc_mat.emission_energy_multiplier = 1.4
	_ground_disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ground_disc_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ground_disc.set_surface_override_material(0, _ground_disc_mat)
	add_child(_ground_disc)

	# Cloud puffs — five overlapping green spheres at varying heights
	# clustered above the centre. Each puff wobbles slowly on a sin
	# wave (per-puff phase offset stored in _puff_phases) so the
	# cloud looks alive rather than a static decal.
	_puff_phases.resize(PUFF_COUNT)
	for i: int in PUFF_COUNT:
		var puff := MeshInstance3D.new()
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sph := SphereMesh.new()
		sph.radius = PUFF_BASE_RADIUS * randf_range(0.85, 1.25)
		sph.height = sph.radius * 2.0
		sph.radial_segments = 12
		sph.rings = 8
		puff.mesh = sph
		var x_off: float = randf_range(-CLOUD_RADIUS * 0.55, CLOUD_RADIUS * 0.55)
		var z_off: float = randf_range(-CLOUD_RADIUS * 0.55, CLOUD_RADIUS * 0.55)
		var y_base: float = PUFF_HEIGHT_BASE + randf_range(-0.15, 0.40)
		var origin := Vector3(x_off, y_base, z_off)
		puff.position = origin
		_puff_origins.append(origin)
		_puff_phases[i] = randf() * TAU
		var mat := StandardMaterial3D.new()
		mat.albedo_color = TOXIC_GREEN_DARK if i % 2 == 0 else TOXIC_GREEN
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = TOXIC_GREEN_BRIGHT
		mat.emission_energy_multiplier = 0.9
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		puff.set_surface_override_material(0, mat)
		add_child(puff)
		_puffs.append(puff)
		_puff_mats.append(mat)

	# Soft green omni-light at chest height — bathes the cloud area
	# in toxic glow so it reads as a hazard even from off-angle.
	_cloud_light = OmniLight3D.new()
	_cloud_light.light_color = TOXIC_GREEN_BRIGHT
	_cloud_light.light_energy = 1.4
	_cloud_light.omni_range = CLOUD_RADIUS + 2.0
	_cloud_light.position = Vector3(0.0, 1.2, 0.0)
	add_child(_cloud_light)


func _process(delta: float) -> void:
	_life += delta

	# Fade alpha based on cloud lifecycle window.
	var alpha_mult: float = 1.0
	if _life < FADE_IN_SEC:
		alpha_mult = clampf(_life / FADE_IN_SEC, 0.0, 1.0)
	elif _life > CLOUD_DURATION_SEC - FADE_OUT_SEC:
		var t_remain: float = CLOUD_DURATION_SEC - _life
		alpha_mult = clampf(t_remain / FADE_OUT_SEC, 0.0, 1.0)

	# Ground disc breathes a touch (slow pulse) while the cloud is up.
	# Max alpha lowered to 0.30 (was 0.55) for the more-transparent look.
	if _ground_disc_mat:
		var breathe: float = 0.85 + sin(_life * TAU * 0.5) * 0.15
		_ground_disc_mat.albedo_color.a = 0.30 * alpha_mult * breathe

	# Puff wobble — each puff drifts on a slow sin wave around its
	# spawn position so the cloud looks alive.
	for i: int in _puffs.size():
		var puff: MeshInstance3D = _puffs[i]
		if not is_instance_valid(puff):
			continue
		var phase: float = _puff_phases[i] + _life * 0.9
		var ox: float = sin(phase) * 0.35
		var oy: float = sin(phase * 1.27 + 0.7) * 0.20
		var oz: float = cos(phase * 0.83) * 0.35
		puff.position = _puff_origins[i] + Vector3(ox, oy, oz)
		# Per-puff alpha fade matches the overall cloud fade.
		# Reduced max alpha from 0.85 → 0.50 so the puffs read as
		# translucent vapor not solid green spheres.
		if i < _puff_mats.size():
			var pm: StandardMaterial3D = _puff_mats[i]
			if pm:
				pm.albedo_color.a = clampf(0.50 * alpha_mult, 0.0, 1.0)

	# Cloud light decays over the lifetime.
	if _cloud_light:
		_cloud_light.light_energy = 1.4 * alpha_mult

	# Damage pulse — every CLOUD_TICK_SEC apply damage to hostiles
	# inside the radius. Pulses keep running through fade-out so the
	# cloud's damaging tail bites past the last visible second.
	if _life < CLOUD_DURATION_SEC:
		_tick_accum += delta
		if _tick_accum >= CLOUD_TICK_SEC:
			_tick_accum -= CLOUD_TICK_SEC
			_apply_damage_pulse()
	else:
		# Cleanup once we've finished the fade-out window.
		if _life > CLOUD_DURATION_SEC + 0.2:
			queue_free()


func _apply_damage_pulse() -> void:
	## Single damage tick. Anything within CLOUD_RADIUS that's hostile
	## to the shooter takes CLOUD_DAMAGE_PER_PULSE. Buildings + units
	## both checked.
	var scene_tree: SceneTree = get_tree()
	if scene_tree == null:
		return
	# Re-validate the stored shooter before each pulse. The cloud lives
	# for several seconds, easily long enough for the firing squad to be
	# wiped out mid-cloud. Building.take_damage takes a typed Node3D
	# attacker, and the call() dispatch fails the type check when the
	# stored reference is a freed Object (error report 644: "Invalid
	# type in function 'take_damage (via call)' in base StaticBody3D
	# (Building). The Object-derived class of argument 3 (previously
	# freed) is not a subclass of the expected argument class").
	# Passing null is allowed — take_damage defaults attacker to null.
	var shooter_arg: Node3D = _shooter if (_shooter != null and is_instance_valid(_shooter)) else null
	var origin: Vector3 = global_position
	var r2: float = CLOUD_RADIUS * CLOUD_RADIUS
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
			node.call("take_damage", CLOUD_DAMAGE_PER_PULSE, shooter_arg)
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
			node.call("take_damage", CLOUD_DAMAGE_PER_PULSE, shooter_arg)


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
