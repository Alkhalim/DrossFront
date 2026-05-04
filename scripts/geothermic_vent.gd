class_name GeothermicVent
extends StaticBody3D
## A capped fissure of geothermal steam. Generator buildings must
## be placed on top of one to produce power. Open vents emit a
## continuous steam plume via a dedicated GPUParticles3D so the
## smoke is unmissable; once a Generator covers the vent the
## plume stops. Roughly the footprint of a Generator (4u square),
## so the visual hides cleanly under the building.
##
## Scene placement happens via TestArenaController's vent setup
## pass. Each player gets a starter pair of close vents + 1
## forward visible vent at start, plus distributed vents elsewhere.

const VENT_SIZE: float = 4.0

var is_covered: bool = false
var _steam: GPUParticles3D = null
var _glow_light: OmniLight3D = null

## Throttle for the cover-state recheck. Repolling the buildings
## group every frame for every vent at high counts is wasteful;
## ~1 Hz is plenty since a generator either is or isn't on top.
const COVER_RECHECK_INTERVAL: float = 1.1
var _cover_check_timer: float = 0.0


func _ready() -> void:
	add_to_group("geothermic_vents")
	# Static decoration -- no physics interaction. The build system
	# queries vents by group, not by collider.
	collision_layer = 0
	collision_mask = 0
	_build_visuals()
	_cover_check_timer = randf_range(0.0, COVER_RECHECK_INTERVAL)


func _build_visuals() -> void:
	# --- Concrete pad + collar -------------------------------------
	# Wide low pad gives the rim something to sit on and matches the
	# Generator footprint (so the building looks like it locked into
	# place).
	var pad_mat: StandardMaterial3D = StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.34, 0.32, 0.28, 1.0)
	pad_mat.roughness = 0.95
	var pad: MeshInstance3D = MeshInstance3D.new()
	var pad_mesh: CylinderMesh = CylinderMesh.new()
	pad_mesh.top_radius = VENT_SIZE * 0.55
	pad_mesh.bottom_radius = VENT_SIZE * 0.60
	pad_mesh.height = 0.16
	pad_mesh.radial_segments = 14
	pad.mesh = pad_mesh
	pad.position = Vector3(0.0, 0.08, 0.0)
	pad.set_surface_override_material(0, pad_mat)
	add_child(pad)

	# Riveted iron collar around the rim -- pipes / fixtures bolted
	# in. Read as the cap on the geothermal well.
	var collar_mat: StandardMaterial3D = StandardMaterial3D.new()
	collar_mat.albedo_color = Color(0.18, 0.16, 0.14, 1.0)
	collar_mat.metallic = 0.45
	collar_mat.roughness = 0.55
	var collar: MeshInstance3D = MeshInstance3D.new()
	var collar_mesh: CylinderMesh = CylinderMesh.new()
	collar_mesh.top_radius = VENT_SIZE * 0.40
	collar_mesh.bottom_radius = VENT_SIZE * 0.46
	collar_mesh.height = 0.32
	collar_mesh.radial_segments = 18
	collar.mesh = collar_mesh
	collar.position = Vector3(0.0, 0.32, 0.0)
	collar.set_surface_override_material(0, collar_mat)
	add_child(collar)

	# Eight rivets around the collar.
	var rivet_mat: StandardMaterial3D = StandardMaterial3D.new()
	rivet_mat.albedo_color = Color(0.55, 0.45, 0.18, 1.0)
	rivet_mat.metallic = 0.7
	rivet_mat.roughness = 0.4
	for r: int in 8:
		var rivet: MeshInstance3D = MeshInstance3D.new()
		var rs: SphereMesh = SphereMesh.new()
		rs.radius = 0.08
		rs.height = 0.16
		rivet.mesh = rs
		var ang: float = TAU * float(r) / 8.0
		rivet.position = Vector3(
			cos(ang) * VENT_SIZE * 0.43,
			0.40,
			sin(ang) * VENT_SIZE * 0.43,
		)
		rivet.set_surface_override_material(0, rivet_mat)
		add_child(rivet)

	# Glowing inner pit -- warm orange, gives the vent its 'hot'
	# read and the steam its colour anchor.
	var pit_mat: StandardMaterial3D = StandardMaterial3D.new()
	pit_mat.albedo_color = Color(0.45, 0.20, 0.10, 1.0)
	pit_mat.emission_enabled = true
	pit_mat.emission = Color(1.0, 0.50, 0.18, 1.0)
	pit_mat.emission_energy_multiplier = 2.2
	pit_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	var pit: MeshInstance3D = MeshInstance3D.new()
	var pit_mesh: CylinderMesh = CylinderMesh.new()
	pit_mesh.top_radius = VENT_SIZE * 0.28
	pit_mesh.bottom_radius = VENT_SIZE * 0.30
	pit_mesh.height = 0.06
	pit_mesh.radial_segments = 18
	pit.mesh = pit_mesh
	pit.position = Vector3(0.0, 0.50, 0.0)
	pit.set_surface_override_material(0, pit_mat)
	add_child(pit)

	# Soft warm point light so the vent reads at distance + tints
	# nearby ground orange.
	_glow_light = OmniLight3D.new()
	_glow_light.light_color = Color(1.0, 0.55, 0.20, 1.0)
	_glow_light.light_energy = 0.6
	_glow_light.omni_range = 5.5
	_glow_light.position = Vector3(0.0, 0.7, 0.0)
	add_child(_glow_light)

	# Hazard stripe wedges around the pad -- four short
	# yellow/black segments on the cardinals so the pad reads as
	# an industrial work-site.
	var stripe_mat: StandardMaterial3D = StandardMaterial3D.new()
	stripe_mat.albedo_color = Color(0.78, 0.62, 0.10, 1.0)
	stripe_mat.roughness = 0.7
	for w: int in 4:
		var wedge: MeshInstance3D = MeshInstance3D.new()
		var w_box: BoxMesh = BoxMesh.new()
		w_box.size = Vector3(0.55, 0.025, 0.20)
		wedge.mesh = w_box
		var ang2: float = float(w) * (PI * 0.5) + PI * 0.25
		wedge.position = Vector3(
			cos(ang2) * VENT_SIZE * 0.55,
			0.165,
			sin(ang2) * VENT_SIZE * 0.55,
		)
		wedge.rotation.y = -ang2
		wedge.set_surface_override_material(0, stripe_mat)
		add_child(wedge)

	# Dedicated GPU steam emitter. Cone-shape with upward velocity
	# and a long lifetime so the plume reads as a continuous column
	# without the previous version's busy density. The 'smoke' is a
	# circular alpha-fade billboard sprite -- soft round puffs
	# instead of square quads.
	_steam = GPUParticles3D.new()
	_steam.amount = 16  # was 32 -- less dense, less visual noise
	_steam.lifetime = 2.6
	_steam.preprocess = 1.5
	_steam.position = Vector3(0.0, 0.55, 0.0)
	_steam.draw_pass_1 = _build_steam_mesh()
	_steam.process_material = _build_steam_material()
	add_child(_steam)


## Process-wide cache of the soft-round puff texture so every vent
## reuses the same GPU upload.
static var _puff_texture: Texture2D = null


static func _ensure_puff_texture() -> Texture2D:
	## Builds (once) a circular alpha-fade puff texture used as the
	## steam particle albedo. Radial gradient: opaque white at the
	## centre fading to transparent at the rim. Replaces the square
	## QuadMesh outline with a soft round shape.
	if _puff_texture:
		return _puff_texture
	var sz: int = 64
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var centre: float = float(sz - 1) * 0.5
	var max_r: float = centre * 0.95
	for y: int in sz:
		for x: int in sz:
			var dx: float = float(x) - centre
			var dy: float = float(y) - centre
			var dist: float = sqrt(dx * dx + dy * dy)
			# Smoothstep falloff: fully opaque inside ~30% of the
			# radius, smoothly transitioning to transparent at the
			# rim. Gives the puff a soft round read with a hint of
			# core density.
			var t: float = clampf((dist - max_r * 0.30) / (max_r * 0.70), 0.0, 1.0)
			# Smoother-than-linear falloff for that "soft cloud" feel.
			var alpha: float = 1.0 - (t * t * (3.0 - 2.0 * t))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	img.generate_mipmaps()
	_puff_texture = ImageTexture.create_from_image(img)
	return _puff_texture


func _build_steam_mesh() -> Mesh:
	var qm: QuadMesh = QuadMesh.new()
	qm.size = Vector2(1.0, 1.0)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.88, 0.92, 0.65)
	mat.albedo_texture = _ensure_puff_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	qm.material = mat
	return qm


func _build_steam_material() -> ParticleProcessMaterial:
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.30
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 14.0  # tighter cone for cleaner column
	pm.initial_velocity_min = 1.4
	pm.initial_velocity_max = 2.2
	pm.gravity = Vector3(0.0, 0.6, 0.0)
	pm.scale_min = 0.65
	pm.scale_max = 1.20
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	# Fade out across lifetime via colour ramp. Lower starting
	# alpha (0.55 vs 0.85) so the column is a soft mist rather
	# than dense smoke.
	var ramp: Gradient = Gradient.new()
	ramp.set_color(0, Color(0.92, 0.94, 0.96, 0.55))
	ramp.set_color(1, Color(0.85, 0.86, 0.88, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = ramp
	pm.color_ramp = grad_tex
	# Scale curve -- grow as the puff rises.
	var sc_curve: Curve = Curve.new()
	sc_curve.add_point(Vector2(0.0, 0.7))
	sc_curve.add_point(Vector2(1.0, 1.5))
	var sc_tex: CurveTexture = CurveTexture.new()
	sc_tex.curve = sc_curve
	pm.scale_curve = sc_tex
	return pm


func _process(delta: float) -> void:
	# Periodically rescan for a Generator footprint covering the
	# vent. When found, mark covered (kills the steam); when the
	# generator is destroyed the recheck flips it back to open.
	_cover_check_timer -= delta
	if _cover_check_timer <= 0.0:
		_cover_check_timer = COVER_RECHECK_INTERVAL + randf_range(-0.1, 0.2)
		_recheck_cover_state()


func _recheck_cover_state() -> void:
	## Scans the buildings group for a Generator (basic_generator or
	## advanced_generator) whose footprint overlaps this vent. Sets
	## is_covered accordingly so the steam plume tracks reality.
	var found: bool = false
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Node3D = node as Node3D
		if not b:
			continue
		var stats: Variant = b.get("stats")
		if stats == null:
			continue
		var bid: StringName = stats.get("building_id") as StringName
		if bid != &"basic_generator" and bid != &"advanced_generator":
			continue
		if b.global_position.distance_to(global_position) < VENT_SIZE * 0.6:
			found = true
			break
	if found != is_covered:
		mark_covered(found)


func mark_covered(covered: bool) -> void:
	## Toggle the cover state. Stops or resumes the steam plume +
	## the warm OmniLight (no point shedding light from underneath
	## a finished generator -- the building has its own emission).
	is_covered = covered
	if _steam:
		_steam.emitting = not covered
	if _glow_light:
		_glow_light.visible = not covered


static func find_vent_at(scene: Node, world_pos: Vector3, radius: float = 2.5) -> GeothermicVent:
	## Returns the closest GeothermicVent within `radius` of world_pos,
	## or null. Used by the build-placement validity check + the
	## generator's on-construct hook.
	if not scene or not scene.get_tree():
		return null
	var best: GeothermicVent = null
	var best_dist: float = radius
	for node: Node in scene.get_tree().get_nodes_in_group("geothermic_vents"):
		if not is_instance_valid(node):
			continue
		var v: GeothermicVent = node as GeothermicVent
		if not v:
			continue
		var d: float = world_pos.distance_to(v.global_position)
		if d <= best_dist:
			best_dist = d
			best = v
	return best
