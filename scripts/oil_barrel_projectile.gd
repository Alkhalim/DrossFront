class_name OilBarrelProjectile
extends Node3D
## Tumbling oil-barrel projectile fired by the Censer. Travels on a
## mortar-like arc from the firing point to the target, visibly
## tumbling end-over-end during flight, then spawns a ChemicalCloud
## at the impact point to mark + apply the area DPS.
##
## Distinct from the standard mortar (ProjectileManager style 3) for
## three reasons that don't fit cleanly into the MultiMesh layout:
##   - Per-frame rotation accumulation (tumble) — MultiMesh transforms
##     don't store per-instance angular velocity; we'd have to bolt on
##     a parallel rotation array.
##   - Distinct mesh — the barrel body + brass hoops would need its
##     own bucket key, and that one mesh is only ever used by this
##     weapon, so a dedicated Node3D is simpler than expanding the
##     manager's style enum + mesh builder for a one-off shape.
##   - Spawns a ChemicalCloud at impact instead of applying the
##     manager's standard splash. The damage model is fundamentally
##     different ("lingering area DPS" vs "instant splash"), and
##     that branch fits better on a self-contained class.

## Approximate flight time scales with distance — set on spawn so the
## arc lands on target regardless of how far it travels.
var _total_flight_sec: float = 1.0
var _arc_height: float = 8.0

## Tumble rate — spin around the barrel's horizontal axis.
const TUMBLE_RAD_PER_SEC: float = 11.0  # ~1.75 rotations / sec

## Greenish vapor trail puff cadence — every TRAIL_INTERVAL_SEC the
## barrel emits a faint translucent green puff at its current pos.
## Sells "leaking chemical fumes" without spamming particles.
const TRAIL_INTERVAL_SEC: float = 0.07

var _life: float = 0.0
var _from_pos: Vector3 = Vector3.ZERO
var _to_pos: Vector3 = Vector3.ZERO
var _shooter: Node3D = null
var _shooter_owner_id: int = -1
var _payload_damage: int = 0
var _tumble_phase: float = 0.0
var _next_trail_at: float = 0.0
## Stable horizontal axis perpendicular to the flight direction —
## the barrel tumbles around this so the spin always looks "end over
## end forward" regardless of which way it's flying.
var _tumble_axis: Vector3 = Vector3.RIGHT
## Visual root the tumble rotation is applied to. Kept as a child so
## the projectile's own transform stays clean for position updates.
var _body_pivot: Node3D = null


static func create(from: Vector3, to: Vector3, damage: int,
		shooter: Node3D, shooter_owner_id: int) -> OilBarrelProjectile:
	var b := OilBarrelProjectile.new()
	var fire_y: float = from.y if from.y >= 0.5 else from.y + 1.0
	b._from_pos = Vector3(from.x, fire_y, from.z)
	b._to_pos = Vector3(to.x, to.y, to.z)
	b._payload_damage = damage
	b._shooter = shooter
	b._shooter_owner_id = shooter_owner_id
	# Flight time scales with horizontal distance — same factor the
	# manager's mortar arc uses (11 u/s baseline), clamped to 0.6s
	# minimum so short lobs still arc visibly.
	var dist: float = b._from_pos.distance_to(b._to_pos)
	b._total_flight_sec = maxf(dist / 11.0, 0.6)
	# Arc height also scales with distance — long lobs go higher.
	b._arc_height = clampf(dist * 0.50, 5.5, 12.0)
	# Tumble axis = horizontal perpendicular to travel direction so
	# the barrel ALWAYS appears to tumble forward, not laterally.
	var travel: Vector3 = b._to_pos - b._from_pos
	travel.y = 0.0
	if travel.length_squared() > 0.01:
		var fwd: Vector3 = travel.normalized()
		# rotate fwd 90° around Y to get a horizontal perpendicular
		b._tumble_axis = Vector3(-fwd.z, 0.0, fwd.x)
	b._tumble_phase = randf() * TAU
	b.position = b._from_pos
	return b


func _ready() -> void:
	add_to_group("projectiles")
	_build_visual()


func _build_visual() -> void:
	## Vertical barrel — rust-brown cylinder with three brass hoop
	## bands and an amber-glow strip at the lid (the chemical inside
	## is hot enough to glow). Whole thing is parented to a pivot so
	## tumble rotation doesn't fight with the projectile's own position
	## updates.
	const BARREL_BODY: Color = Color(0.45, 0.28, 0.16, 1.0)  # rust brown
	const BARREL_BAND: Color = Color(0.62, 0.45, 0.18, 1.0)  # brass hoop
	const BARREL_LID_GLOW: Color = Color(0.55, 0.85, 0.35, 1.0)  # toxic green peek

	_body_pivot = Node3D.new()
	_body_pivot.name = "BarrelBody"
	add_child(_body_pivot)

	# Main barrel body — wider cylinder.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := CylinderMesh.new()
	bm.top_radius = 0.30
	bm.bottom_radius = 0.30
	bm.height = 0.85
	bm.radial_segments = 14
	body.mesh = bm
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = BARREL_BODY
	body.set_surface_override_material(0, body_mat)
	_body_pivot.add_child(body)

	# Three brass hoop bands around the barrel — short tori at
	# top, middle, bottom.
	for i: int in 3:
		var hoop := MeshInstance3D.new()
		hoop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var hm := TorusMesh.new()
		hm.inner_radius = 0.30
		hm.outer_radius = 0.34
		hm.rings = 16
		hm.ring_segments = 6
		hoop.mesh = hm
		hoop.rotation.x = PI * 0.5  # torus lies horizontally
		var y_off: float = -0.35 + float(i) * 0.35
		hoop.position = Vector3(0.0, y_off, 0.0)
		var hm_mat := StandardMaterial3D.new()
		hm_mat.albedo_color = BARREL_BAND
		hoop.set_surface_override_material(0, hm_mat)
		_body_pivot.add_child(hoop)

	# Top lid glow — thin emissive disc on the top so the barrel reads
	# as containing something hot + green.
	var lid := MeshInstance3D.new()
	lid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lm := CylinderMesh.new()
	lm.top_radius = 0.24
	lm.bottom_radius = 0.24
	lm.height = 0.06
	lm.radial_segments = 14
	lid.mesh = lm
	lid.position = Vector3(0.0, 0.45, 0.0)
	var lid_mat := StandardMaterial3D.new()
	lid_mat.albedo_color = BARREL_LID_GLOW
	lid_mat.emission_enabled = true
	lid_mat.emission = BARREL_LID_GLOW
	lid_mat.emission_energy_multiplier = 1.8
	lid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lid.set_surface_override_material(0, lid_mat)
	_body_pivot.add_child(lid)


func _process(delta: float) -> void:
	_life += delta
	var t_norm: float = clampf(_life / _total_flight_sec, 0.0, 1.0)
	# Parabolic arc — horizontal lerp + height parabola, same math
	# the manager's _update_arc uses for mortars.
	var xz: Vector3 = _from_pos.lerp(_to_pos, t_norm)
	var arc_y: float = _arc_height * 4.0 * t_norm * (1.0 - t_norm)
	global_position = Vector3(xz.x, xz.y + arc_y, xz.z)

	# Tumble — accumulate rotation around the stable horizontal axis.
	# Apply on the body pivot so the projectile's own transform stays
	# unrotated (simpler position math).
	_tumble_phase += delta * TUMBLE_RAD_PER_SEC
	if _body_pivot:
		_body_pivot.basis = Basis(_tumble_axis, _tumble_phase)

	# Greenish vapor trail — fine translucent green puffs at a fixed
	# cadence so the barrel visibly leaks chemical fumes during flight.
	if _life >= _next_trail_at:
		_next_trail_at += TRAIL_INTERVAL_SEC
		_spawn_trail_puff(global_position)

	if t_norm >= 1.0:
		_impact()


func _spawn_trail_puff(pos: Vector3) -> void:
	## Faint green vapor puff — small translucent sphere that fades
	## out over ~0.6 s. Drifts down (heavier-than-air chemical fume).
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return
	var puff := MeshInstance3D.new()
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sph := SphereMesh.new()
	sph.radius = 0.12
	sph.height = 0.24
	sph.radial_segments = 8
	sph.rings = 4
	puff.mesh = sph
	var mat := StandardMaterial3D.new()
	# Very transparent green so the trail stays faint, not painted.
	mat.albedo_color = Color(0.55, 0.85, 0.35, 0.30)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.85, 0.35, 1.0)
	mat.emission_energy_multiplier = 0.7
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	puff.set_surface_override_material(0, mat)
	scene.add_child(puff)
	puff.global_position = pos + Vector3(
		randf_range(-0.10, 0.10),
		randf_range(-0.04, 0.04),
		randf_range(-0.10, 0.10),
	)
	var drift: Vector3 = puff.global_position + Vector3(
		randf_range(-0.15, 0.15),
		randf_range(-0.25, -0.05),  # drift DOWN (chemical fume is heavy)
		randf_range(-0.15, 0.15),
	)
	var tw: Tween = puff.create_tween().set_parallel(true)
	tw.tween_property(puff, "global_position", drift, 0.65)
	tw.tween_property(puff, "scale", Vector3(2.2, 2.2, 2.2), 0.65)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.65)
	tw.chain().tween_callback(puff.queue_free)


func _impact() -> void:
	## On arrival — apply the direct-hit damage payload to whoever is
	## under the impact point, then spawn the persistent ChemicalCloud
	## that handles the lingering area DPS.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		queue_free()
		return
	# Direct-hit damage: anything within a small radius (1.5u) of the
	# impact point eats the full damage payload immediately.
	const DIRECT_HIT_RADIUS: float = 1.5
	var origin: Vector3 = global_position
	if _payload_damage > 0:
		var r2: float = DIRECT_HIT_RADIUS * DIRECT_HIT_RADIUS
		for node: Node in get_tree().get_nodes_in_group("units"):
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
				node.call("take_damage", _payload_damage, _shooter)
	# Spawn the lingering cloud at ground level.
	ChemicalCloud.spawn_at(scene, origin, _shooter, _shooter_owner_id)
	# Small impact flash for feedback.
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem != null and pem.has_method("emit_flash"):
		pem.call("emit_flash", origin, Color(0.55, 0.85, 0.35, 0.85))
	queue_free()


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
