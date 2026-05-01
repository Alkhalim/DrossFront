class_name ParticleEmitterManager
extends Node3D
## Single scene-level node that owns one persistent GPUParticles3D per
## particle category (smoke, flash, dust, spark). Other systems call
## `emit_smoke(...)` / `emit_flash(...)` / etc. instead of allocating
## fresh `MeshInstance3D + Tween + StandardMaterial3D` per particle —
## the per-particle lifetime, drift, fade, and scale animation now run
## on the GPU via `ParticleProcessMaterial`, not in GDScript.
##
## Each emitter is sized for the worst-case concurrent particle count
## across the match. `emit_particle` overrides the configured initial
## position / velocity / color of one particle in the buffer; the
## process material drives everything else.

const SMOKE_AMOUNT: int = 240         # missile trails — high concurrent count
const FLASH_AMOUNT: int = 80          # muzzle + impact flashes (short-lived)
const DUST_AMOUNT: int = 140          # walking dust + crush bursts
const SPARK_AMOUNT: int = 120         # welding sparks (very short-lived)
const SMOKE_LIFETIME: float = 0.55
const FLASH_LIFETIME: float = 0.18
const DUST_LIFETIME: float = 0.85
const SPARK_LIFETIME: float = 0.22

var _smoke: GPUParticles3D = null
var _flash: GPUParticles3D = null
var _dust: GPUParticles3D = null
var _spark: GPUParticles3D = null


func _ready() -> void:
	# Each emitter is created with its draw mesh (the visible particle
	# shape) and a process material defining the per-particle update.
	_smoke = _build_smoke_emitter()
	add_child(_smoke)
	_flash = _build_flash_emitter()
	add_child(_flash)
	_dust = _build_dust_emitter()
	add_child(_dust)
	_spark = _build_spark_emitter()
	add_child(_spark)


## --- Public emit API -------------------------------------------------------

func emit_smoke(world_pos: Vector3, velocity: Vector3 = Vector3(0, 0.4, 0), color: Color = Color(0.6, 0.5, 0.4, 0.65)) -> void:
	if not _smoke:
		return
	var t := Transform3D()
	t.origin = world_pos
	_smoke.emit_particle(
		t,
		velocity,
		color,
		Color(1, 1, 1, 1),
		GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_COLOR
	)


func emit_flash(world_pos: Vector3, color: Color = Color(1.0, 0.7, 0.2, 0.85), count: int = 1) -> void:
	if not _flash:
		return
	for i: int in count:
		var t := Transform3D()
		t.origin = world_pos
		_flash.emit_particle(
			t,
			Vector3.ZERO,
			color,
			Color(1, 1, 1, 1),
			GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_COLOR
		)


func emit_dust(world_pos: Vector3, count: int = 1, scale_mul: float = 1.0) -> void:
	if not _dust:
		return
	for i: int in count:
		var t := Transform3D()
		t.origin = world_pos + Vector3(
			randf_range(-0.25, 0.25),
			0.05,
			randf_range(-0.25, 0.25),
		)
		var rise: float = randf_range(0.4, 0.9)
		var drift: Vector3 = Vector3(
			randf_range(-0.3, 0.3),
			rise,
			randf_range(-0.3, 0.3),
		)
		_dust.emit_particle(
			t,
			drift,
			Color(0.55, 0.5, 0.42, 0.6) * scale_mul,
			Color(scale_mul, scale_mul, 1, 1),
			GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_COLOR | GPUParticles3D.EMIT_FLAG_CUSTOM
		)


func emit_spark(world_pos: Vector3, count: int = 1) -> void:
	if not _spark:
		return
	for i: int in count:
		var t := Transform3D()
		t.origin = world_pos
		var dir := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(0.4, 1.2),
			randf_range(-1.0, 1.0),
		).normalized() * randf_range(1.5, 3.0)
		_spark.emit_particle(
			t,
			dir,
			Color(1.0, 0.85, 0.3, 0.95),
			Color(1, 1, 1, 1),
			GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_COLOR
		)


## --- Emitter builders ------------------------------------------------------

func _build_smoke_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "SmokeEmitter"
	p.amount = SMOKE_AMOUNT
	p.lifetime = SMOKE_LIFETIME
	p.one_shot = false
	p.emitting = true
	p.preprocess = 0.0
	p.explosiveness = 0.0
	p.randomness = 0.0
	# We drive emissions via emit_particle; the built-in continuous
	# emission is suppressed by setting amount_ratio to 0.
	p.amount_ratio = 0.0
	p.fixed_fps = 30
	# emit_particle drops particles into world-space at any position;
	# the GPUParticles3D node itself stays at origin. Without an
	# explicit visibility_aabb the engine culls particles that sit
	# far outside the node's transform — which on a 300x300 map was
	# every smoke puff fired more than ~10u from origin. Generous
	# AABB makes the puffs visible regardless of emit position.
	p.visibility_aabb = AABB(Vector3(-200, -10, -200), Vector3(400, 60, 400))
	p.draw_pass_1 = _smoke_mesh()

	var pm := ParticleProcessMaterial.new()
	pm.particle_flag_align_y = false
	pm.particle_flag_disable_z = false
	pm.gravity = Vector3.ZERO   # drift handled per-particle via emit velocity
	pm.damping_min = 0.6
	pm.damping_max = 1.2
	pm.scale_min = 0.18
	pm.scale_max = 0.32
	# Scale grows over life — soft sphere expands as it fades.
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.6))
	scale_curve.add_point(Vector2(1.0, 2.6))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# Alpha fade-out over life.
	var alpha_grad := Gradient.new()
	alpha_grad.set_color(0, Color(1, 1, 1, 1))
	alpha_grad.set_color(1, Color(1, 1, 1, 0))
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = alpha_grad
	pm.color_ramp = alpha_tex
	p.process_material = pm
	return p


func _smoke_mesh() -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.16
	sphere.height = 0.32
	sphere.radial_segments = 8
	sphere.rings = 4
	# Smoke uses ALPHA-blend (mix), not additive: real smoke obscures
	# the scene behind it. The previous additive blend made the dark
	# grey emitted by missile trails / damaged buildings / smokestacks
	# nearly invisible against the lit ground (additive of 0.3-grey
	# barely tints anything bright).
	sphere.material = _alpha_unshaded_mat(Color(0.85, 0.65, 0.45, 0.7))
	return sphere


func _build_flash_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "FlashEmitter"
	p.amount = FLASH_AMOUNT
	p.lifetime = FLASH_LIFETIME
	p.one_shot = false
	p.emitting = true
	p.amount_ratio = 0.0
	p.fixed_fps = 30
	# emit_particle drops particles into world-space at any position;
	# the GPUParticles3D node itself stays at origin. Without an
	# explicit visibility_aabb the engine culls particles that sit
	# far outside the node's transform — which on a 300x300 map was
	# every smoke puff fired more than ~10u from origin. Generous
	# AABB makes the puffs visible regardless of emit position.
	p.visibility_aabb = AABB(Vector3(-200, -10, -200), Vector3(400, 60, 400))
	p.draw_pass_1 = _flash_mesh()

	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.0
	pm.damping_max = 0.0
	pm.scale_min = 0.4
	pm.scale_max = 0.55
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.4))
	scale_curve.add_point(Vector2(0.4, 1.4))
	scale_curve.add_point(Vector2(1.0, 0.1))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	var alpha_grad := Gradient.new()
	alpha_grad.set_color(0, Color(1, 1, 1, 1))
	alpha_grad.set_color(1, Color(1, 1, 1, 0))
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = alpha_grad
	pm.color_ramp = alpha_tex
	p.process_material = pm
	return p


func _flash_mesh() -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	sphere.radial_segments = 8
	sphere.rings = 4
	sphere.material = _additive_unshaded_mat(Color(1.0, 0.55, 0.18, 1.0))
	return sphere


func _build_dust_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "DustEmitter"
	p.amount = DUST_AMOUNT
	p.lifetime = DUST_LIFETIME
	p.one_shot = false
	p.emitting = true
	p.amount_ratio = 0.0
	p.fixed_fps = 30
	# emit_particle drops particles into world-space at any position;
	# the GPUParticles3D node itself stays at origin. Without an
	# explicit visibility_aabb the engine culls particles that sit
	# far outside the node's transform — which on a 300x300 map was
	# every smoke puff fired more than ~10u from origin. Generous
	# AABB makes the puffs visible regardless of emit position.
	p.visibility_aabb = AABB(Vector3(-200, -10, -200), Vector3(400, 60, 400))
	p.draw_pass_1 = _dust_mesh()

	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0, -1.0, 0)  # dust settles back down
	pm.damping_min = 1.5
	pm.damping_max = 2.5
	pm.scale_min = 0.12
	pm.scale_max = 0.22
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.5))
	scale_curve.add_point(Vector2(0.5, 1.5))
	scale_curve.add_point(Vector2(1.0, 0.6))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	var alpha_grad := Gradient.new()
	alpha_grad.set_color(0, Color(1, 1, 1, 1))
	alpha_grad.set_color(1, Color(1, 1, 1, 0))
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = alpha_grad
	pm.color_ramp = alpha_tex
	p.process_material = pm
	return p


func _dust_mesh() -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.4
	sphere.radial_segments = 8
	sphere.rings = 4
	sphere.material = _additive_unshaded_mat(Color(0.55, 0.5, 0.42, 0.55))
	return sphere


func _build_spark_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "SparkEmitter"
	p.amount = SPARK_AMOUNT
	p.lifetime = SPARK_LIFETIME
	p.one_shot = false
	p.emitting = true
	p.amount_ratio = 0.0
	p.fixed_fps = 30
	# emit_particle drops particles into world-space at any position;
	# the GPUParticles3D node itself stays at origin. Without an
	# explicit visibility_aabb the engine culls particles that sit
	# far outside the node's transform — which on a 300x300 map was
	# every smoke puff fired more than ~10u from origin. Generous
	# AABB makes the puffs visible regardless of emit position.
	p.visibility_aabb = AABB(Vector3(-200, -10, -200), Vector3(400, 60, 400))
	p.draw_pass_1 = _spark_mesh()

	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0, -3.0, 0)  # sparks arc down
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	pm.scale_min = 0.6
	pm.scale_max = 1.0
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 1.0))
	scale_curve.add_point(Vector2(1.0, 0.0))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	var alpha_grad := Gradient.new()
	alpha_grad.set_color(0, Color(1, 1, 1, 1))
	alpha_grad.set_color(1, Color(1, 1, 1, 0))
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = alpha_grad
	pm.color_ramp = alpha_tex
	p.process_material = pm
	return p


func _spark_mesh() -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.06
	sphere.height = 0.12
	sphere.radial_segments = 6
	sphere.rings = 3
	sphere.material = _additive_unshaded_mat(Color(1.0, 0.85, 0.3, 1.0))
	return sphere


func _additive_unshaded_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Disable depth write so overlapping particles don't z-fight.
	m.disable_receive_shadows = true
	return m


func _alpha_unshaded_mat(c: Color) -> StandardMaterial3D:
	## Same as _additive_unshaded_mat but with standard alpha-blend
	## instead of additive — used for smoke, which should obscure
	## what's behind it rather than brighten it.
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	return m


## Helper for finding the global emitter from anywhere in the scene.
## Returns the manager as Node so callers don't need ParticleEmitterManager
## as a resolved class_name — duck-typing via has_method() is fine for the
## small public API.
static func get_instance(tree: SceneTree) -> Node:
	if not tree:
		return null
	var scene: Node = tree.current_scene
	if not scene:
		return null
	return scene.get_node_or_null("ParticleEmitterManager")
