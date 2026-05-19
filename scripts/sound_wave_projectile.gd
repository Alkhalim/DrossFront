class_name SoundWaveProjectile
extends Node3D
## Expanding squiggly sound-wave visual for the Herald's Acoustic
## Furnace. Damage is applied separately by CombatComponent's cone
## scan at fire-time (mirroring the flame-cone pattern); this class
## handles ONLY the VFX — three concentric ring meshes that emit
## from the muzzle in quick succession, travel forward along the
## cone axis, and grow in radius as they travel so the visual
## resolves into a cone shape pointed at the target.
##
## "Squiggly" is approximated by adding a fast sin-wave pulse to
## each ring's radius + a slow Y-axis tilt wobble so the ring
## flexes mid-flight rather than reading as a clean static torus.

const RING_COUNT: int = 3
const RING_SPAWN_INTERVAL: float = 0.12
const RING_LIFETIME_SEC: float = 0.55
## Speed each ring travels forward along the cone axis (u/s).
const RING_TRAVEL_SPEED: float = 18.0
## Radius the ring REACHES at the end of its lifetime. Combined with
## RING_TRAVEL_SPEED this defines the cone's half-angle.
const RING_END_RADIUS: float = 3.4
const RING_START_RADIUS: float = 0.35
## Squiggle frequency + amplitude (sin-wave radial pulse).
const SQUIGGLE_HZ: float = 12.0
const SQUIGGLE_AMP: float = 0.18

var _life: float = 0.0
var _from_pos: Vector3 = Vector3.ZERO
var _to_pos: Vector3 = Vector3.ZERO
var _forward: Vector3 = Vector3.FORWARD
## Per-ring state: { mesh: MeshInstance3D, mat: StandardMaterial3D,
## spawned_at: float, dead: bool }.
var _rings: Array[Dictionary] = []
var _next_ring_idx: int = 0


static func create(from: Vector3, to: Vector3) -> SoundWaveProjectile:
	## Spawn a single sound-wave VFX from `from` aimed at `to`. The
	## projectile parents under the scene root; CombatComponent handles
	## the damage cone separately.
	var s := SoundWaveProjectile.new()
	var fire_y: float = from.y if from.y >= 0.5 else from.y + 1.0
	s._from_pos = Vector3(from.x, fire_y, from.z)
	s._to_pos = Vector3(to.x, to.y + 0.4, to.z)
	var dir: Vector3 = s._to_pos - s._from_pos
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD
	s._forward = dir.normalized()
	s.position = s._from_pos
	return s


func _ready() -> void:
	add_to_group("projectiles")


func _process(delta: float) -> void:
	_life += delta

	# Spawn rings at staggered intervals up to RING_COUNT total.
	if _next_ring_idx < RING_COUNT and _life >= float(_next_ring_idx) * RING_SPAWN_INTERVAL:
		_spawn_ring()
		_next_ring_idx += 1

	# Update + age each living ring.
	for ring: Dictionary in _rings:
		if ring.get("dead", false) as bool:
			continue
		var spawned_at: float = ring["spawned_at"] as float
		var age: float = _life - spawned_at
		var t_norm: float = clampf(age / RING_LIFETIME_SEC, 0.0, 1.0)
		var mesh: MeshInstance3D = ring["mesh"] as MeshInstance3D
		var mat: StandardMaterial3D = ring["mat"] as StandardMaterial3D
		if not is_instance_valid(mesh):
			ring["dead"] = true
			continue
		# Radius grows toward RING_END_RADIUS. Apply squiggle pulse on
		# top via scale modulation (mesh radius is fixed at 1.0, scale
		# carries the growth).
		var radius: float = lerp(RING_START_RADIUS, RING_END_RADIUS, t_norm)
		radius += sin(age * TAU * SQUIGGLE_HZ) * SQUIGGLE_AMP * (0.5 + t_norm * 0.5)
		# Wobble — slight roll around the cone axis itself so the ring
		# flexes WITHOUT flattening. We bake the wobble into the basis
		# directly so we don't blow away the upright orientation set at
		# spawn (previously we wrote mesh.rotation.x = sin(...), which
		# overwrote the basis and made the rings lie flat — playtest
		# 2026-05-19).
		var stored_basis: Basis = ring["base_basis"] as Basis
		var roll: float = sin(age * TAU * 6.0) * 0.12
		var wobble_basis: Basis = stored_basis * Basis(Vector3.UP, roll)
		# Build the transform: position = forward * travel, basis =
		# stored upright orientation × small roll wobble, scale = radius.
		var travel: float = RING_TRAVEL_SPEED * age
		var xform := Transform3D(wobble_basis, _forward * travel)
		xform.basis = xform.basis.scaled(Vector3(radius, radius, radius))
		mesh.transform = xform
		# Fade alpha + emission as the ring ages.
		if mat:
			mat.albedo_color.a = (1.0 - t_norm) * 0.85
			mat.emission_energy_multiplier = lerp(2.4, 0.0, t_norm)
		# Free expired rings.
		if t_norm >= 1.0:
			mesh.queue_free()
			ring["dead"] = true

	# Despawn the projectile once every ring has been spawned + died.
	if _next_ring_idx >= RING_COUNT:
		var any_alive: bool = false
		for ring2: Dictionary in _rings:
			if not (ring2.get("dead", false) as bool):
				any_alive = true
				break
		if not any_alive:
			queue_free()


func _spawn_ring() -> void:
	## Spawn a single ring mesh at the projectile's origin, oriented
	## so its disc faces the cone's forward axis. The ring grows +
	## squiggles via _process so this just sets up the static state.
	const WAVE_COLOR: Color = Color(0.85, 0.55, 1.00, 0.85)
	const WAVE_BRIGHT: Color = Color(1.00, 0.80, 1.00, 1.0)
	var ring := MeshInstance3D.new()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tm := TorusMesh.new()
	# Mesh is built at unit radius (1.0); _process scales it.
	tm.inner_radius = 0.92
	tm.outer_radius = 1.00
	tm.rings = 32
	tm.ring_segments = 6
	ring.mesh = tm
	# TorusMesh axis is +Y (the hole's axis). For the rings to read as
	# UPRIGHT vertical discs perpendicular to the cone direction
	# (so they look like sound wavefronts travelling forward), we
	# align the torus's local +Y to _forward — meaning the ring's
	# flat plane is perpendicular to the travel direction. Per
	# playtest 2026-05-19, the previous Basis fed BOTH x_axis +
	# z_axis as horizontal, but then a sibling rotation.x assignment
	# downstream was flattening the discs back to ground-plane;
	# we now also stash this orientation in ring meta so the
	# per-frame wobble can compose against it without losing the
	# upright facing.
	var any_up: Vector3 = Vector3.UP if absf(_forward.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x_axis: Vector3 = any_up.cross(_forward).normalized()
	var z_axis: Vector3 = _forward.cross(x_axis).normalized()
	var base_basis := Basis(x_axis, _forward, z_axis)
	ring.basis = base_basis
	var mat := StandardMaterial3D.new()
	mat.albedo_color = WAVE_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = WAVE_BRIGHT
	mat.emission_energy_multiplier = 2.4
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, mat)
	add_child(ring)
	_rings.append({
		"mesh": ring,
		"mat": mat,
		"spawned_at": _life,
		"dead": false,
		"base_basis": base_basis,
	})
