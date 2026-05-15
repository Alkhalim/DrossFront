class_name Projectile
extends Node3D
## Visual projectile — beam-only after the MultiMesh refactor.
## Non-beam styles (bullet, missile, shell, mortar, bomb) route
## through ProjectileManager.fire() (Task 7 of the MultiMesh
## Projectile Rendering plan). Beams stay here because they are
## single-frame line-fades that don't benefit from MultiMesh
## batching — keeping them on a one-off Node3D is simpler than
## building a separate beam-aware path in the manager.

func _ready() -> void:
	# Group membership lets FogOfWar.apply_visibility hide
	# projectiles whose current cell isn't currently in line of
	# sight. Without this filter, a unit in unscouted territory
	# would still leak its position to the player by rendering
	# beam traces through the fog.
	add_to_group("projectiles")


var target_pos: Vector3 = Vector3.ZERO
var start_pos: Vector3 = Vector3.ZERO
## Beam-only after refactor. Value 999.0 flags beam path in _process
## (threshold > 500.0). Non-beam projectiles never reach _process now.
var speed: float = 999.0
var _mesh: MeshInstance3D = null

const ROLE_COLORS: Dictionary = {
	&"AP": Color(1.0, 0.8, 0.2, 1.0),
	&"AA": Color(0.3, 0.7, 1.0, 1.0),
	&"Universal": Color(0.9, 0.6, 0.2, 1.0),
}

## Cached FogOfWar reference — looked up lazily on the first
## process tick so the projectile doesn't pay the lookup cost when
## fog isn't part of the active scene.
var _fow: Node = null
var _fow_lookup_done: bool = false
## Counter for the FoW visibility check. The FogOfWar polygon updates
## at ~5 Hz so checking every frame on every projectile is wasted work
## at high beam traffic. Phase the check across frames so each beam
## re-checks every Nth frame (using a randomized initial offset so
## the load is spread instead of all beams re-checking on the same
## frame).
var _fow_check_counter: int = 0
const FOW_CHECK_INTERVAL: int = 4   # ~15 Hz at 60 fps; FoW polys update at 5 Hz


static func create(from: Vector3, to: Vector3, role_tag: StringName,
		rof_tier: StringName = &"moderate", style_override: StringName = &"",
		shooter_faction: int = 0, damage_tier: StringName = &"moderate") -> Projectile:
	## Beam-only factory. Non-beam styles route through
	## ProjectileManager.fire() in CombatComponent. This factory
	## survives only because beams are instant single-frame
	## line-fades that don't benefit from MultiMesh batching —
	## keeping them on a one-off Node3D is simpler than building
	## a separate beam-aware path in the manager.
	# Mirror original ROF_STYLES dispatch: rof_tier is the base style;
	# explicit style_override wins if provided. Only "continuous" maps
	# to beam — all other tiers should have been routed through
	# ProjectileManager already.
	const ROF_STYLES: Dictionary = {
		&"single": "missile",
		&"slow": "missile",
		&"moderate": "bullet",
		&"fast": "bullet",
		&"volley": "missile",
		&"continuous": "beam",
	}
	var style: String = ROF_STYLES.get(rof_tier, "bullet") as String
	if style_override != &"":
		style = String(style_override)
	if style != "beam":
		push_error("Projectile.create called with non-beam style '%s' (rof_tier=%s) — should route through ProjectileManager" % [style, rof_tier])
	var proj := Projectile.new()
	# Only lift the spawn point off the ground when the caller passed
	# a low-y position (e.g. unit center / member position). Muzzle
	# positions returned by Unit.get_muzzle_positions are already at
	# barrel height, so lifting them by +1u was making lasers render
	# visibly above the gun.
	var fire_y: float = from.y if from.y >= 0.5 else from.y + 1.0
	proj.start_pos = Vector3(from.x, fire_y, from.z)
	proj.target_pos = Vector3(to.x, to.y + 0.8, to.z)
	# Use `position` (local) here — the projectile isn't in the tree
	# yet, and assigning `global_position` on an unparented Node3D
	# triggers a `!is_inside_tree()` debug warning per call. The
	# caller parents to the scene root (identity transform), so
	# local == global.
	proj.position = proj.start_pos

	var color: Color = ROLE_COLORS.get(role_tag, Color(0.9, 0.6, 0.2, 1.0)) as Color
	# Sable tracers read whiter / colder than Anvil's warm orange so a
	# friendly Sable squad's beams are visually distinguishable from
	# an Anvil ally's at a glance. Lerp 40% toward white.
	if shooter_faction == 1:
		color = color.lerp(Color(1.0, 1.0, 1.0, color.a), 0.4)

	# Beam thickness scales with damage tier so small units' beams
	# read as thin tracers and only heavy-caliber weapons paint the
	# screen. Tuned per playtest 2026-05-14: "beam weapons currently
	# have too large of a beam, the very wide ones should be reserved
	# for bigger units and heavier calibers".
	var beam_width: float = 0.55  # moderate baseline (was 1.0)
	match damage_tier:
		&"very_low":
			beam_width = 0.25
		&"low":
			beam_width = 0.38
		&"moderate":
			beam_width = 0.55
		&"high":
			beam_width = 0.78
		&"very_high":
			beam_width = 1.00
		&"extreme":
			beam_width = 1.30

	# Tesla / chain-lightning style: jagged segmented bolt instead of a
	# clean tube. Detected by projectile_style override on the weapon
	# (style_override is the variable shadowing here). Drawn in a
	# separate function so the legacy straight-beam path stays simple.
	if style_override == &"tesla" or style_override == &"lightning":
		proj._create_tesla_beam_mesh(color, proj.start_pos, proj.target_pos, beam_width)
	else:
		proj._create_beam_mesh(color, proj.start_pos, proj.target_pos, beam_width)
	proj.speed = 999.0
	return proj


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

	# Position + orient via Transform3D so the basis is correct on
	# the very first frame, before the projectile is parented to
	# the scene tree.
	var mid: Vector3 = (from + to) * 0.5
	var xform := Transform3D()
	xform.origin = mid
	if length > 0.1:
		xform = xform.looking_at(to, Vector3.UP)
	transform = xform


func _create_tesla_beam_mesh(color: Color, from: Vector3, to: Vector3, width_scale: float = 1.0) -> void:
	## Chain-lightning bolt — short straight segments with random
	## perpendicular offsets at every joint, giving the jagged
	## "electric arc" silhouette. Also spawns a handful of short
	## fork branches that splay outward at random midpoints so the
	## bolt reads as electrical rather than as a stripey beam.
	## Reset the projectile's own transform to identity first — caller
	## had set position = start_pos for the straight-beam path's
	## look_at fix, but our segments below set their transforms in
	## WORLD coordinates and would otherwise double-displace by
	## start_pos. Keeping projectile at origin lets each segment's
	## local transform equal its world transform.
	transform = Transform3D()
	var dir: Vector3 = to - from
	var length: float = dir.length()
	if length < 0.05:
		return
	# Per-bolt RNG seed: keeps a single bolt's jitter consistent
	# during the fade but distinct between back-to-back bolts.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# Pick a perpendicular up-vector so offsets always stay
	# in-plane rather than randomly stretching toward camera.
	var fwd: Vector3 = dir.normalized()
	var any_up: Vector3 = Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var perp_a: Vector3 = fwd.cross(any_up).normalized()
	var perp_b: Vector3 = fwd.cross(perp_a).normalized()
	# Segment count scales with length so long arcs get more joints.
	var seg_count: int = clampi(int(length / 1.5), 4, 14)
	var seg_thickness_core: float = 0.06 * width_scale
	var seg_thickness_hot: float = 0.025 * width_scale
	var max_offset: float = clampf(length * 0.08, 0.20, 0.65)
	# Build the joint path in world space.
	var joints: Array[Vector3] = []
	joints.append(from)
	for s_i: int in seg_count - 1:
		var t: float = float(s_i + 1) / float(seg_count)
		var center: Vector3 = from.lerp(to, t)
		# Bias offsets so they fade to zero at the endpoints (sin curve).
		var off_amt: float = sin(t * PI) * max_offset
		var off: Vector3 = perp_a * rng.randf_range(-off_amt, off_amt) + perp_b * rng.randf_range(-off_amt, off_amt)
		joints.append(center + off)
	joints.append(to)
	# Tinted core color (matches straight-beam treatment).
	var core_color: Color = color.lerp(Color(1.0, 1.0, 1.0, 1.0), 0.55)
	core_color.a = 1.0
	for j_i: int in joints.size() - 1:
		var a: Vector3 = joints[j_i]
		var b: Vector3 = joints[j_i + 1]
		_add_tesla_segment(a, b, core_color, color, seg_thickness_core, seg_thickness_hot, j_i == 0)
	# Fork branches — short side-arcs splaying off random joints.
	var fork_count: int = mini(2, seg_count / 3)
	for f_i: int in fork_count:
		var pick: int = rng.randi_range(1, joints.size() - 2)
		var anchor: Vector3 = joints[pick]
		var splay_dir: Vector3 = (perp_a * rng.randf_range(-1.0, 1.0) + perp_b * rng.randf_range(-1.0, 1.0)).normalized()
		var splay_len: float = rng.randf_range(0.4, 0.9)
		var fork_end: Vector3 = anchor + splay_dir * splay_len + fwd * rng.randf_range(-0.2, 0.2)
		_add_tesla_segment(anchor, fork_end, core_color, color, seg_thickness_core * 0.65, seg_thickness_hot * 0.65, false)


func _add_tesla_segment(a: Vector3, b: Vector3, core_color: Color, halo_color: Color, core_size: float, hot_size: float, root_segment: bool) -> void:
	## Single jagged lightning segment between two world points. Three
	## stacked meshes (hot needle, tinted core, translucent halo) match
	## the straight-beam visual budget so tesla bolts look like the
	## same family of weapon, just bent.
	var seg_v: Vector3 = b - a
	var seg_len: float = seg_v.length()
	if seg_len < 0.01:
		return
	var mid: Vector3 = (a + b) * 0.5
	var seg_xform := Transform3D()
	seg_xform.origin = mid
	seg_xform = seg_xform.looking_at(b, Vector3.UP)
	# Hot needle (only on the trunk; forks skip it so they don't pile
	# up at near-coincident endpoints).
	if root_segment:
		var hot := MeshInstance3D.new()
		hot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var hb := BoxMesh.new()
		hb.size = Vector3(hot_size, hot_size, seg_len)
		hot.mesh = hb
		var hot_mat := StandardMaterial3D.new()
		hot_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
		hot_mat.emission_enabled = true
		hot_mat.emission = Color(1.0, 1.0, 1.0, 1.0)
		hot_mat.emission_energy_multiplier = 12.0
		hot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hot.set_surface_override_material(0, hot_mat)
		hot.transform = seg_xform
		add_child(hot)
		# Use the first segment's hot-needle mesh as the fade reference.
		if _mesh == null:
			_mesh = hot
	# Tinted core.
	var core := MeshInstance3D.new()
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cb := BoxMesh.new()
	cb.size = Vector3(core_size, core_size, seg_len)
	core.mesh = cb
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = core_color
	core_mat.emission_enabled = true
	core_mat.emission = core_color
	core_mat.emission_energy_multiplier = 6.0
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core.set_surface_override_material(0, core_mat)
	core.transform = seg_xform
	add_child(core)
	# Translucent halo.
	var halo := MeshInstance3D.new()
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hb2 := BoxMesh.new()
	hb2.size = Vector3(core_size * 2.4, core_size * 2.4, seg_len)
	halo.mesh = hb2
	var halo_mat := StandardMaterial3D.new()
	halo_mat.albedo_color = Color(halo_color.r, halo_color.g, halo_color.b, 0.30)
	halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_mat.emission_enabled = true
	halo_mat.emission = halo_color
	halo_mat.emission_energy_multiplier = 2.5
	halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	halo.set_surface_override_material(0, halo_mat)
	halo.transform = seg_xform
	add_child(halo)


func _process(delta: float) -> void:
	# FoW visibility — phased re-check (see _fow_check_counter doc).
	if not _fow_lookup_done:
		_fow_lookup_done = true
		_fow = get_tree().current_scene.get_node_or_null("FogOfWar")
		# Randomize initial offset so many beams spawned on the
		# same combat tick don't all re-check on the same future frames.
		_fow_check_counter = randi() % FOW_CHECK_INTERVAL
	_fow_check_counter += 1
	if _fow_check_counter >= FOW_CHECK_INTERVAL:
		_fow_check_counter = 0
		if _fow and _fow.has_method("is_visible_world"):
			visible = _fow.is_visible_world(global_position)

	# Beam — instant, fade out.
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

	# Non-beam projectiles should never reach this path now —
	# CombatComponent routes them through ProjectileManager.fire().
	queue_free()
