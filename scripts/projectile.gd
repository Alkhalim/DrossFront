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
	var style: String = String(style_override) if style_override != &"" else "beam"
	if style == &"" or style_override == &"":
		# Fall back to rof_tier mapping for backwards compat.
		# Only "continuous" maps to beam; everything else should
		# have been routed through ProjectileManager already.
		const ROF_STYLES: Dictionary = {
			&"single": "missile",
			&"slow": "missile",
			&"moderate": "bullet",
			&"fast": "bullet",
			&"volley": "missile",
			&"continuous": "beam",
		}
		style = ROF_STYLES.get(rof_tier, "bullet") as String
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
