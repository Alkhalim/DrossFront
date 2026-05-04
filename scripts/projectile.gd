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
var _is_mortar: bool = false

## Deferred damage payload. CombatComponent attaches this after
## projectile.create() for any non-instant projectile style
## (bullet / shell / missile / mortar / bomb). On _spawn_impact
## the projectile applies pending_damage to pending_target (if
## still alive) plus splash to anything in pending_splash_radius.
## Beams and drone-release weapons stay instant -- their damage
## is the visible event, not the projectile arrival.
var pending_damage: int = 0
var pending_target: Node3D = null
var pending_shooter: Node3D = null
var pending_splash_radius: float = 0.0
var pending_splash_damage: int = 0


func set_damage_payload(damage: int, target: Node3D, shooter: Node3D, splash_radius: float, splash_damage: int) -> void:
	pending_damage = damage
	pending_target = target
	pending_shooter = shooter
	pending_splash_radius = splash_radius
	pending_splash_damage = splash_damage
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


static func create(from: Vector3, to: Vector3, role_tag: StringName, rof_tier: StringName = &"moderate", style_override: StringName = &"", shooter_faction: int = 0, damage_tier: StringName = &"moderate") -> Projectile:
	var proj := Projectile.new()
	# Only lift the spawn point off the ground when the caller passed
	# a low-y position (e.g. unit center / member position). Muzzle
	# positions returned by Unit.get_muzzle_positions are already at
	# barrel height, so lifting them by +1u was making lasers (and
	# any other beam-style projectile) render visibly above the gun.
	var fire_y: float = from.y if from.y >= 0.5 else from.y + 1.0
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
			# Beam thickness scales with damage tier so an engineer's
			# low-power cutting laser doesn't render at the same width
			# as a Pulsefont sidearm. Very-low / low damage -> 0.4x
			# width; moderate -> 1.0x; higher tiers -> 1.2x.
			var beam_width: float = 1.0
			match damage_tier:
				&"very_low":
					beam_width = 0.35
				&"low":
					beam_width = 0.55
				&"high", &"very_high", &"extreme":
					beam_width = 1.2
			proj._create_beam_mesh(color, proj.start_pos, proj.target_pos, beam_width)
			proj.speed = 999.0
		"mortar":
			# High-arc mortar shell -- chunky finned cylinder that
			# arcs much higher than a regular missile + spawns an
			# impact shockwave for splash. Reuses _is_missile flag
			# for the arc trajectory; arc height bumped to read as
			# 'fired straight up' on launch.
			proj._create_mortar_mesh(color)
			proj._is_missile = true
			proj._is_mortar = true
			var mdist: float = from.distance_to(to)
			proj._total_flight_time = maxf(mdist / 11.0, 0.6)
			proj._arc_height = clampf(mdist * 0.55, 6.0, 14.0)
		"shell":
			# Heavy AP shell -- chunkier, brighter tracer than the
			# default bullet, and slightly slower so the silhouette
			# reads on the way to the target. Does NOT arc (kinetic
			# round, not a missile). Used by big-bore guns like the
			# Bulwark cannon where the default rof_tier-derived
			# missile style was visually wrong (the gun's a giant AP
			# cannon, not a launcher).
			proj._create_shell_mesh(color)
			proj.speed = 70.0
			var aim_shell: Vector3 = proj.target_pos - proj.start_pos
			if aim_shell.length_squared() > 0.0001:
				var ts := Transform3D()
				ts.origin = proj.start_pos
				proj.transform = ts.looking_at(proj.target_pos, Vector3.UP)
			proj._bullet_oriented = true
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


func _create_shell_mesh(color: Color) -> void:
	# Heavy AP shell -- bigger than a tracer slug + a tapered nose.
	# Stays a kinetic round (no arc, no missile smoke trail).
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Tapered cylinder gives the AP nose silhouette.
	var shell_cyl := CylinderMesh.new()
	shell_cyl.top_radius = 0.06
	shell_cyl.bottom_radius = 0.16
	shell_cyl.height = 0.62
	shell_cyl.radial_segments = 12
	_mesh.mesh = shell_cyl
	_mesh.rotation.x = -PI / 2
	var shell_mat := StandardMaterial3D.new()
	shell_mat.albedo_color = color
	shell_mat.emission_enabled = true
	shell_mat.emission = color
	shell_mat.emission_energy_multiplier = 2.4
	_mesh.set_surface_override_material(0, shell_mat)
	add_child(_mesh)
	# Bright glowing aft cap reads as the burning tracer charge so a
	# shot fired toward camera still has a strong tail-light read.
	var aft := MeshInstance3D.new()
	aft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var aft_cyl := CylinderMesh.new()
	aft_cyl.top_radius = 0.18
	aft_cyl.bottom_radius = 0.18
	aft_cyl.height = 0.10
	aft_cyl.radial_segments = 12
	aft.mesh = aft_cyl
	aft.rotation.x = -PI / 2
	aft.position.z = 0.26
	var aft_mat := StandardMaterial3D.new()
	var hot: Color = color.lerp(Color(1.0, 1.0, 0.85, 1.0), 0.55)
	aft_mat.albedo_color = hot
	aft_mat.emission_enabled = true
	aft_mat.emission = hot
	aft_mat.emission_energy_multiplier = 6.0
	aft_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	aft.set_surface_override_material(0, aft_mat)
	add_child(aft)


func set_glow_boost(mult: float, tint: Color = Color(1.0, 0.78, 0.20, 1.0)) -> void:
	## Brightens this projectile's mesh emission and shifts its
	## albedo toward the supplied tint. Used by ability paths
	## (Heavy Volley) to make a buffed shot read as glowing
	## pellets at zoom. Safe to call on any style -- if there's no
	## _mesh yet (called pre-_ready) the next physics frame's
	## render still picks up the override material.
	if not _mesh or not is_instance_valid(_mesh):
		return
	var mat: StandardMaterial3D = _mesh.get_surface_override_material(0) as StandardMaterial3D
	if not mat:
		return
	mat.albedo_color = mat.albedo_color.lerp(tint, 0.7)
	mat.emission = tint
	mat.emission_energy_multiplier = mat.emission_energy_multiplier * maxf(mult, 1.0)


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


func _create_mortar_mesh(color: Color) -> void:
	## Stubby finned mortar shell -- shorter + fatter than a regular
	## missile, with cross-fins at the tail. Reads as 'shell falling
	## from the sky' rather than 'guided missile'. No smoke trail
	## (handled by _is_mortar branch in _process).
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Body -- tapered cylinder.
	var body_cyl := CylinderMesh.new()
	body_cyl.top_radius = 0.07
	body_cyl.bottom_radius = 0.18
	body_cyl.height = 0.50
	body_cyl.radial_segments = 12
	_mesh.mesh = body_cyl
	_mesh.rotation.x = -PI / 2  # body points along -Z (forward)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.18, 0.16, 0.14, 1.0)
	body_mat.emission_enabled = true
	body_mat.emission = color
	body_mat.emission_energy_multiplier = 0.6
	_mesh.set_surface_override_material(0, body_mat)
	add_child(_mesh)
	# Tail fins -- 4 thin rectangles forming a + cross at the rear.
	for fin_i: int in 4:
		var fin := MeshInstance3D.new()
		var fin_box := BoxMesh.new()
		fin_box.size = Vector3(0.04, 0.20, 0.16)
		fin.mesh = fin_box
		fin.rotation.x = -PI / 2
		fin.rotation.z = float(fin_i) * PI * 0.5
		fin.position.z = 0.22
		var fin_mat := StandardMaterial3D.new()
		fin_mat.albedo_color = Color(0.10, 0.10, 0.10, 1.0)
		fin.set_surface_override_material(0, fin_mat)
		add_child(fin)


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


func _create_beam_mesh(color: Color, from: Vector3, to: Vector3, width_scale: float = 1.0) -> void:
	var dir: Vector3 = to - from
	var length: float = dir.length()

	# THREE concentric beam layers for a visible 'core brighter than
	# edges' gradient: hot pure-white inner needle, tinted bright
	# core, translucent tinted halo. The previous two-layer build
	# (core + halo) was technically a gradient but the halo's alpha
	# 0.45 fill blended into the core too aggressively at typical
	# RTS zoom and the overall beam read as flat-coloured. Splitting
	# into three layers produces an unmistakable hot centre.

	# Layer 1 -- inner hot needle. Pure white, max emission, very
	# thin so it always sits on top of the tinted core regardless of
	# camera angle.
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hot := BoxMesh.new()
	hot.size = Vector3(0.035 * width_scale, 0.035 * width_scale, maxf(length, 0.1))
	_mesh.mesh = hot
	var hot_mat := StandardMaterial3D.new()
	hot_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	hot_mat.emission_enabled = true
	hot_mat.emission = Color(1.0, 1.0, 1.0, 1.0)
	hot_mat.emission_energy_multiplier = 12.0
	hot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_mesh.set_surface_override_material(0, hot_mat)
	add_child(_mesh)

	# Layer 2 -- tinted core. Carries the role colour but stays
	# bright (60% white-blend kept from the previous build).
	var core := MeshInstance3D.new()
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core_box := BoxMesh.new()
	core_box.size = Vector3(0.09 * width_scale, 0.09 * width_scale, maxf(length, 0.1))
	core.mesh = core_box
	var core_mat := StandardMaterial3D.new()
	var core_color: Color = color.lerp(Color(1.0, 1.0, 1.0, 1.0), 0.6)
	core_color.a = 1.0
	core_mat.albedo_color = core_color
	core_mat.emission_enabled = true
	core_mat.emission = core_color
	core_mat.emission_energy_multiplier = 6.0
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	core.set_surface_override_material(0, core_mat)
	add_child(core)

	# Layer 3 -- wider translucent halo wrapping the core. Drops to
	# alpha 0.30 (was 0.45) so the inner layers' brightness wins
	# instead of being averaged into the halo's tint at distance.
	var halo := MeshInstance3D.new()
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var halo_box := BoxMesh.new()
	halo_box.size = Vector3(0.22 * width_scale, 0.22 * width_scale, maxf(length, 0.1))
	halo.mesh = halo_box
	var halo_mat := StandardMaterial3D.new()
	halo_mat.albedo_color = Color(color.r, color.g, color.b, 0.30)
	halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_mat.emission_enabled = true
	halo_mat.emission = color
	halo_mat.emission_energy_multiplier = 2.5
	halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	halo.set_surface_override_material(0, halo_mat)
	add_child(halo)

	# Position + orient via Transform3D so the basis is correct on the very
	# first frame, before the projectile is parented to the scene tree.
	var mid: Vector3 = (from + to) * 0.5
	var xform := Transform3D()
	xform.origin = mid
	if length > 0.1:
		xform = xform.looking_at(to, Vector3.UP)
	transform = xform


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
	# Apply deferred damage payload. CombatComponent skipped the
	# instant take_damage call for projectile-based fire and
	# attached the payload here so damage lands when the
	# projectile actually arrives. Target may have died mid-flight
	# -- in that case the impact VFX still plays but no damage
	# applies.
	if pending_damage > 0 and pending_target and is_instance_valid(pending_target):
		var alive: bool = true
		if "alive_count" in pending_target:
			alive = (pending_target.get("alive_count") as int) > 0
		if alive and pending_target.has_method("take_damage"):
			pending_target.take_damage(pending_damage, pending_shooter)
	# Splash on impact -- scans hostile units + buildings within
	# pending_splash_radius and chips them. Same shape as the
	# previous CombatComponent splash code, just relocated to the
	# arrival site so the area-of-effect VISIBLY centres on the
	# impact rather than firing instantly from the unit's barrel.
	if pending_splash_radius > 0.0 and pending_splash_damage > 0 and pending_shooter and is_instance_valid(pending_shooter):
		var shooter_owner: int = (pending_shooter.get("owner_id") as int) if "owner_id" in pending_shooter else 0
		var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
		for ent: Node in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(ent) or ent == pending_target:
				continue
			if not ent.has_method("take_damage"):
				continue
			var ent_owner: int = (ent.get("owner_id") as int) if "owner_id" in ent else 0
			var hostile: bool = true
			if registry and registry.has_method("are_enemies"):
				hostile = registry.call("are_enemies", shooter_owner, ent_owner)
			if not hostile:
				continue
			if global_position.distance_to((ent as Node3D).global_position) <= pending_splash_radius:
				ent.take_damage(pending_splash_damage, pending_shooter)
		for ent2: Node in get_tree().get_nodes_in_group("buildings"):
			if not is_instance_valid(ent2) or ent2 == pending_target:
				continue
			if not ent2.has_method("take_damage"):
				continue
			var ent2_owner: int = (ent2.get("owner_id") as int) if "owner_id" in ent2 else 0
			var hostile2: bool = true
			if registry and registry.has_method("are_enemies"):
				hostile2 = registry.call("are_enemies", shooter_owner, ent2_owner)
			if not hostile2:
				continue
			if global_position.distance_to((ent2 as Node3D).global_position) <= pending_splash_radius:
				ent2.take_damage(pending_splash_damage, pending_shooter)
	# Impact flash routed through the GPU-particle emitter — same
	# bright-orange burst, no per-impact MeshInstance3D allocation.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if pem:
		pem.emit_flash(global_position, Color(1.0, 0.6, 0.18, 0.9))
	# Mortar shockwave -- a short-lived expanding ring at ground
	# level so the splash damage is visible as 'this hit
	# everything in this circle'. Cheap one-shot mesh that
	# self-removes after ~0.55s.
	if _is_mortar and is_inside_tree():
		_spawn_mortar_shockwave(global_position)
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_impact"):
		audio.play_weapon_impact(global_position)


func _spawn_mortar_shockwave(at: Vector3) -> void:
	var ring := MeshInstance3D.new()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var torus := TorusMesh.new()
	torus.inner_radius = 0.4
	torus.outer_radius = 0.6
	torus.ring_segments = 6
	torus.rings = 32
	ring.mesh = torus
	ring.position = Vector3(at.x, 0.18, at.z)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.18, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.18, 1.0)
	mat.emission_energy_multiplier = 1.6
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, mat)
	get_tree().current_scene.add_child(ring)
	# Tween the ring outward + fade. Final radius ~ splash radius
	# (3.5u is the Mortar weapon's splash); duration short.
	var tw: Tween = ring.create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(7.0, 1.0, 7.0), 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.55).set_trans(Tween.TRANS_LINEAR)
	tw.chain().tween_callback(ring.queue_free)
