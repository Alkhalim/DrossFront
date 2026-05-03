class_name Projectile
extends Node3D
## Visual projectile. Missiles arc, bullets fly straight, beams are instant lines.

func _ready() -> void:
	# Group membership lets FogOfWar.apply_visibility hide
	# projectiles whose current cell isn't currently in line of
	# sight. Without this filter, a Hammerhead in unscouted
	# territory would still leak its position to the player by
	# rendering missile arcs through the fog.
	add_to_group("projectiles")


var target_pos: Vector3 = Vector3.ZERO
var start_pos: Vector3 = Vector3.ZERO
var speed: float = 40.0
var _mesh: MeshInstance3D = null
## Whether to spawn smoke-puff trail mesh instances behind the projectile.
## True for missiles, false for bullets / beams.
var _emit_trail: bool = false
var _trail_timer: float = 0.0

## Missile arc state.
var _is_missile: bool = false
var _flight_time: float = 0.0
var _total_flight_time: float = 1.0
var _arc_height: float = 4.0
## Bullets only orient once (on first physics frame, after add_child puts them
## in the tree); after that they fly straight and don't need re-aiming.
var _bullet_oriented: bool = false
## Hard lifetime safety cap — if for any reason the impact-distance check
## fails to fire (target moved underground, target_pos slightly past the
## reachable straight line, etc.) this guarantees the bullet self-destructs
## instead of jittering around the impact point forever.
var _life: float = 0.0
## How often to drop a smoke puff. ~30 puffs/sec at the default cadence
## would paint a continuous trail; we throttle to ~14/sec via the wider
## interval below to keep the per-puff allocation+tween overhead in check.
const MISSILE_TRAIL_INTERVAL: float = 0.07

## Smoke puffs now route through the central GPU-particle emitter
## (`ParticleEmitterManager.emit_smoke`). The emitter has its own ring
## buffer (SMOKE_AMOUNT particles) so old particles overwrite new ones
## automatically when the buffer fills — no per-process cap needed.

const ROLE_COLORS: Dictionary = {
	&"AP": Color(1.0, 0.8, 0.2, 1.0),
	&"AA": Color(0.3, 0.7, 1.0, 1.0),
	&"Universal": Color(0.9, 0.6, 0.2, 1.0),
}

const ROF_STYLES: Dictionary = {
	&"single": "missile",
	&"slow": "missile",
	&"moderate": "bullet",
	&"fast": "bullet",
	&"volley": "missile",
	&"continuous": "beam",
}


static func create(from: Vector3, to: Vector3, role_tag: StringName, rof_tier: StringName = &"moderate", style_override: StringName = &"", shooter_faction: int = 0) -> Projectile:
	var proj := Projectile.new()
	var fire_y: float = from.y + 1.0
	proj.start_pos = Vector3(from.x, fire_y, from.z)
	proj.target_pos = Vector3(to.x, to.y + 0.8, to.z)
	# Use `position` (local) here — the projectile isn't in the tree yet,
	# and assigning `global_position` on an unparented Node3D triggers a
	# `!is_inside_tree()` debug warning per call. The caller parents to
	# the scene root (identity transform), so local == global.
	proj.position = proj.start_pos

	var color: Color = ROLE_COLORS.get(role_tag, Color(0.9, 0.6, 0.2, 1.0)) as Color
	# Sable tracers read whiter / colder than Anvil's warm orange so a
	# friendly Sable squad's trails are visually distinguishable from
	# an Anvil ally's at a glance. Lerp 40% toward white.
	if shooter_faction == 1:
		color = color.lerp(Color(1.0, 1.0, 1.0, color.a), 0.4)
	var style: String = ROF_STYLES.get(rof_tier, "bullet") as String
	# Explicit override wins. Lets the Ratchet's "Light Pistol Gun" render as
	# a cutting beam without forcing a faster RoF tier on it.
	if style_override != &"":
		style = String(style_override)

	# Add slight random offset so squad projectiles don't perfectly overlap
	proj.target_pos += Vector3(randf_range(-0.3, 0.3), 0, randf_range(-0.3, 0.3))

	match style:
		"missile":
			proj._create_missile_mesh(color)
			proj._is_missile = true
			var dist: float = from.distance_to(to)
			proj._total_flight_time = maxf(dist / 12.0, 0.5)
			proj._arc_height = clampf(dist * 0.25, 2.0, 8.0)
		"bomb":
			# Heavy aerial bomb -- finned cylindrical body. Reuses the
			# missile arc trajectory so the bomb visibly drops + tumbles
			# onto the target. Slightly slower flight than a missile so
			# the silhouette reads at zoom.
			proj._create_bomb_mesh(color)
			proj._is_missile = true
			var bdist: float = from.distance_to(to)
			proj._total_flight_time = maxf(bdist / 9.0, 0.7)
			# Lower arc than a missile -- bombs fall, they don't soar.
			proj._arc_height = clampf(bdist * 0.10, 0.5, 3.0)
		"beam":
			proj._create_beam_mesh(color, proj.start_pos, proj.target_pos)
			proj.speed = 999.0
		_:
			proj._create_bullet_mesh(color)
			# Faster bullets so the volley reads as actually shooting rather than
			# floating across the field — important now that Rook fires bursts.
			proj.speed = 95.0
			# Orient the slug along the firing direction at spawn time. Using
			# Transform3D.looking_at directly (rather than Node3D.look_at) so
			# the rotation is correct on the very first frame, before the
			# projectile is parented to the scene tree.
			var aim_dir: Vector3 = proj.target_pos - proj.start_pos
			if aim_dir.length_squared() > 0.0001:
				var t := Transform3D()
				t.origin = proj.start_pos
				proj.transform = t.looking_at(proj.target_pos, Vector3.UP)
			proj._bullet_oriented = true

	return proj


func _create_bullet_mesh(color: Color) -> void:
	# Slim slug shape rather than a round ball — a thin cylinder oriented
	# along the travel direction reads as a tracer round, not a cannonball.
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.05
	cyl.height = 0.34
	_mesh.mesh = cyl
	# Cylinder default axis is Y; rotate so the long axis aligns with the
	# projectile's local -Z (which look_at orients toward the target).
	_mesh.rotation.x = -PI / 2

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	_mesh.set_surface_override_material(0, mat)
	add_child(_mesh)


func _create_bomb_mesh(color: Color) -> void:
	## Heavy aerial bomb -- chunky cylindrical body with a tail-fin
	## cluster on the back. Distinct from missiles (which are slimmer
	## and emissive) so a player can tell at a glance which projectile
	## came from a Carpet Bombard vs a missile barrage.
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var body_cyl := CylinderMesh.new()
	body_cyl.top_radius = 0.05
	body_cyl.bottom_radius = 0.18
	body_cyl.height = 0.65
	body_cyl.radial_segments = 12
	_mesh.mesh = body_cyl
	# Default cylinder is along +Y. Rotate so the bomb's nose leads
	# the trajectory along local -Z.
	_mesh.rotation.x = -PI / 2
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.18, 0.16, 0.14, 1.0)
	body_mat.metallic = 0.4
	body_mat.roughness = 0.65
	_mesh.set_surface_override_material(0, body_mat)
	add_child(_mesh)
	# Tail-fin cluster -- four slim plates radiating around the back
	# end. Re-uses the body material so they read as part of the
	# bomb chassis.
	for fin_i: int in 4:
		var fin := MeshInstance3D.new()
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var fin_box := BoxMesh.new()
		fin_box.size = Vector3(0.20, 0.02, 0.18)
		fin.mesh = fin_box
		fin.rotation.z = float(fin_i) * (TAU / 4.0)
		# Sit the fin cluster at the bomb's back (local +Y on the
		# unrotated mesh -> +Z on the rotated parent, but the fin is
		# parented under the rotated _mesh so its local +Y is the
		# back). Cleaner: parent to _mesh so it inherits the rotation.
		fin.position = Vector3(0.0, 0.30, 0.0)
		fin.set_surface_override_material(0, body_mat)
		_mesh.add_child(fin)
	# Stencil stripe near the nose -- thin emissive band so the bomb
	# isn't lost against dark terrain. Faint warning yellow.
	var stripe := MeshInstance3D.new()
	stripe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var stripe_cyl := CylinderMesh.new()
	stripe_cyl.top_radius = 0.19
	stripe_cyl.bottom_radius = 0.19
	stripe_cyl.height = 0.05
	stripe_cyl.radial_segments = 12
	stripe.mesh = stripe_cyl
	stripe.position = Vector3(0.0, -0.20, 0.0)
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = Color(1.0, 0.78, 0.20, 1.0)
	stripe_mat.emission_enabled = true
	stripe_mat.emission = Color(1.0, 0.78, 0.20, 1.0)
	stripe_mat.emission_energy_multiplier = 0.8
	stripe.set_surface_override_material(0, stripe_mat)
	_mesh.add_child(stripe)


func _create_missile_mesh(color: Color) -> void:
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04   # nose
	cyl.bottom_radius = 0.1 # exhaust
	cyl.height = 0.4
	_mesh.mesh = cyl
	# Default cylinder height is along +Y. Rotate so it aligns with the
	# projectile's -Z (forward) — the nose then leads the trajectory and
	# look_at properly orients the body along the arc.
	_mesh.rotation.x = -PI / 2

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	_mesh.set_surface_override_material(0, mat)
	add_child(_mesh)

	# Exhaust trail = a stream of small smoke puffs spawned behind the
	# missile in `_process`. Soft, expanding, fading — reads as actual
	# rocket exhaust instead of the previous (misaligned) tapered cone.
	_emit_trail = true


func _create_beam_mesh(color: Color, from: Vector3, to: Vector3) -> void:
	var dir: Vector3 = to - from
	var length: float = dir.length()

	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var box := BoxMesh.new()
	box.size = Vector3(0.05, 0.05, maxf(length, 0.1))
	_mesh.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 5.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mesh.set_surface_override_material(0, mat)

	# Position + orient via Transform3D so the basis is correct on the very
	# first frame, before the projectile is parented to the scene tree.
	# (Node3D.look_at silently produces an identity orientation when called
	# pre-tree, which made the beam render as a Z-aligned segment regardless
	# of where it was supposed to fire.)
	var mid: Vector3 = (from + to) * 0.5
	var xform := Transform3D()
	xform.origin = mid
	if length > 0.1:
		xform = xform.looking_at(to, Vector3.UP)
	transform = xform

	add_child(_mesh)


## Cached FogOfWar reference — looked up lazily on the first
## physics tick so the projectile doesn't pay the lookup cost when
## fog isn't part of the active scene.
var _fow: Node = null
var _fow_lookup_done: bool = false


func _process(delta: float) -> void:
	# Per-frame FOW visibility — projectiles tick fast enough that
	# the 5 Hz FogOfWar group sweep can leave them visible for
	# up to 200ms after they enter fog. Self-checking here gives
	# tight visual gating without measurably increasing combat
	# cost (typically <15 projectiles in flight at peak).
	if not _fow_lookup_done:
		_fow_lookup_done = true
		_fow = get_tree().current_scene.get_node_or_null("FogOfWar")
	if _fow and _fow.has_method("is_visible_world"):
		visible = _fow.is_visible_world(global_position)

	# Beam — instant, fade out
	if speed > 500.0:
		if _mesh:
			var mat: StandardMaterial3D = _mesh.get_surface_override_material(0) as StandardMaterial3D
			if mat:
				mat.albedo_color.a -= delta * 8.0
				if mat.albedo_color.a <= 0.0:
					queue_free()
					return
		else:
			queue_free()
		return

	# Missile — parabolic arc
	if _is_missile:
		_flight_time += delta
		var t: float = clampf(_flight_time / _total_flight_time, 0.0, 1.0)

		# Lerp XZ, parabolic Y
		var xz_pos: Vector3 = start_pos.lerp(target_pos, t)
		var arc_y: float = _arc_height * 4.0 * t * (1.0 - t)
		global_position = Vector3(xz_pos.x, xz_pos.y + arc_y, xz_pos.z)

		# Orient missile along velocity direction
		if t < 0.98:
			var next_t: float = clampf(t + 0.05, 0.0, 1.0)
			var next_xz: Vector3 = start_pos.lerp(target_pos, next_t)
			var next_arc: float = _arc_height * 4.0 * next_t * (1.0 - next_t)
			var next_pos := Vector3(next_xz.x, next_xz.y + next_arc, next_xz.z)
			if global_position.distance_to(next_pos) > 0.01:
				look_at(next_pos, Vector3.UP)

		# Smoke trail — drop a fading puff behind the missile every
		# MISSILE_TRAIL_INTERVAL. Each puff is a free-standing scene
		# child (not parented to the missile), so it stays put after
		# the missile passes and produces a real "trail" through space.
		if _emit_trail:
			_trail_timer -= delta
			if _trail_timer <= 0.0:
				_trail_timer = MISSILE_TRAIL_INTERVAL
				_spawn_trail_puff()

		if t >= 1.0:
			_spawn_impact()
			queue_free()
		return

	# Bullet — straight line. Orient on the first frame so the slug
	# cylinder points at the target. After that the basis stays put;
	# bullets fly in a perfectly straight line and don't need per-frame
	# look_at the way missiles do.
	if not _bullet_oriented:
		_bullet_oriented = true
		if global_position.distance_to(target_pos) > 0.05:
			look_at(target_pos, Vector3.UP)

	# Lifetime safety: even at the lowest weapon range a bullet should reach
	# its target in well under 1.5 seconds at 95u/s. If we ever exceed that,
	# something has gone wrong with the impact-distance check — kill it
	# silently instead of leaving a ghost projectile to flicker.
	_life += delta
	if _life > 1.5:
		queue_free()
		return

	var to_target := target_pos - global_position
	var dist := to_target.length()
	var step: float = speed * delta

	# Impact when this frame's travel would reach or overshoot the target.
	# Without this, fast bullets overshoot the 0.5u threshold, the next
	# frame they're flying back toward target, and the slug visibly
	# oscillates around the impact point until it eventually lands inside
	# the threshold band.
	if step >= dist or dist < 0.1:
		_spawn_impact()
		queue_free()
		return

	var direction := to_target / dist
	global_position += direction * step


func _spawn_trail_puff() -> void:
	## Drops one smoke puff behind the missile. Direct MeshInstance3D +
	## Tween — the GPU-particle path through ParticleEmitterManager
	## was silently emitting nothing on the project's Godot build, so
	## missile trails went invisible mid-match. Per-puff allocation is
	## paid back by the missile-side trail interval (one puff every
	## 70ms ≈ 14/sec across a salvo of 6 missiles = ~85/sec peak), and
	## tween auto-frees the puff so memory stays bounded.
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	# Drop just behind the missile body. global_basis.z is the local +Z
	# direction in world space (missile's "backward" after look_at).
	var rear_offset: Vector3 = global_basis.z.normalized() * randf_range(0.18, 0.32)
	rear_offset += Vector3(
		randf_range(-0.05, 0.05),
		randf_range(-0.05, 0.05),
		randf_range(-0.05, 0.05),
	)
	var puff := MeshInstance3D.new()
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sphere := SphereMesh.new()
	sphere.radius = 0.18
	sphere.height = 0.36
	sphere.radial_segments = 8
	sphere.rings = 4
	puff.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.62, 0.45, 0.65)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	puff.set_surface_override_material(0, mat)
	scene.add_child(puff)
	puff.global_position = global_position + rear_offset
	# Drift up + outward as the puff expands, fading to fully
	# transparent over its life. ~0.7s gives a visible trail across
	# the full missile arc without accumulating too many puffs at
	# once.
	var target_pos_drift: Vector3 = puff.global_position + Vector3(
		randf_range(-0.15, 0.15),
		randf_range(0.4, 0.8),
		randf_range(-0.15, 0.15),
	)
	var tween: Tween = puff.create_tween().set_parallel(true)
	tween.tween_property(puff, "global_position", target_pos_drift, 0.7)
	tween.tween_property(puff, "scale", Vector3(2.4, 2.4, 2.4), 0.7)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.7)
	tween.chain().tween_callback(puff.queue_free)


func _spawn_impact() -> void:
	# Impact flash routed through the GPU-particle emitter — same
	# bright-orange burst, no per-impact MeshInstance3D allocation.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if pem:
		pem.emit_flash(global_position, Color(1.0, 0.6, 0.18, 0.9))

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_impact"):
		audio.play_weapon_impact(global_position)
