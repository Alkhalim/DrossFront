class_name SustainedSolarBeam
extends Node3D
## Continuous beam visual for the Sol Invictus Solar Lance during a
## sustained channel. Lives for the full channel duration and updates
## per frame to:
##   - Track the shooter's current muzzle position + the target's
##     current position (both can move during the channel).
##   - Scale beam thickness from BEAM_WIDTH_START → BEAM_WIDTH_END as
##     the channel progresses (intensifies over time).
##   - Ramp emission energy from EMISSION_START → EMISSION_END so the
##     beam looks visibly hotter near the end of the channel.
##   - Add a "core" needle inside the beam plus an outer translucent
##     halo for the classic three-layer hot beam read.
##
## Damage application is owned by CombatComponent's channel tick; this
## class handles ONLY the visual. CombatComponent calls
## `set_intensity(0..1)` each tick and `dismiss()` to kill the beam
## cleanly (fades out over 0.18s) when the channel ends or cancels.

const BEAM_WIDTH_START: float = 0.22
const BEAM_WIDTH_END: float = 1.05
const EMISSION_START: float = 4.0
const EMISSION_END: float = 14.0
const FADE_OUT_SEC: float = 0.18

const CORE_COLOR: Color = Color(1.0, 0.95, 0.78, 1.0)   # hot white-amber
const HALO_COLOR: Color = Color(1.0, 0.55, 0.18, 1.0)   # amber

var _intensity: float = 0.0
var _dismissing: bool = false
var _dismiss_timer: float = 0.0

var _shooter: WeakRef = null
var _target: WeakRef = null
var _muzzle_marker: Node3D = null  # Optional — the SolarLanceMuzzle on head

var _core_mesh: MeshInstance3D = null
var _core_mat: StandardMaterial3D = null
var _halo_mesh: MeshInstance3D = null
var _halo_mat: StandardMaterial3D = null


static func create(shooter: Node3D, target: Node3D, muzzle_marker: Node3D) -> SustainedSolarBeam:
	var b := SustainedSolarBeam.new()
	b.setup(shooter, target, muzzle_marker)
	return b


func setup(shooter: Node3D, target: Node3D, muzzle_marker: Node3D) -> void:
	## Instance-method configuration — paired with the static create()
	## above. Callers that can't reference the SustainedSolarBeam
	## class_name yet (e.g. combat_component.gd while the class
	## registry hasn't refreshed) use:
	##   beam = preload(...).new()
	##   beam.setup(shooter, target, muzzle_marker)
	##   scene_root.add_child(beam)
	## Functionally identical to going through create() — both end up
	## setting the same fields before _ready runs.
	_shooter = weakref(shooter)
	_target = weakref(target)
	_muzzle_marker = muzzle_marker


func _ready() -> void:
	add_to_group("projectiles")
	_build_meshes()


func _build_meshes() -> void:
	# Hot white core — narrow inner needle, unshaded so it always
	# blooms regardless of the lighting in the scene.
	_core_mesh = MeshInstance3D.new()
	_core_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core_box := BoxMesh.new()
	core_box.size = Vector3(1.0, 1.0, 1.0)  # base unit; rescaled per frame
	_core_mesh.mesh = core_box
	_core_mat = StandardMaterial3D.new()
	_core_mat.albedo_color = CORE_COLOR
	_core_mat.emission_enabled = true
	_core_mat.emission = CORE_COLOR
	_core_mat.emission_energy_multiplier = EMISSION_START
	_core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core_mesh.set_surface_override_material(0, _core_mat)
	add_child(_core_mesh)
	# Outer halo — translucent amber wrap.
	_halo_mesh = MeshInstance3D.new()
	_halo_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var halo_box := BoxMesh.new()
	halo_box.size = Vector3(1.0, 1.0, 1.0)
	_halo_mesh.mesh = halo_box
	_halo_mat = StandardMaterial3D.new()
	_halo_mat.albedo_color = Color(HALO_COLOR.r, HALO_COLOR.g, HALO_COLOR.b, 0.40)
	_halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_halo_mat.emission_enabled = true
	_halo_mat.emission = HALO_COLOR
	_halo_mat.emission_energy_multiplier = EMISSION_START * 0.5
	_halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_halo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_halo_mesh.set_surface_override_material(0, _halo_mat)
	add_child(_halo_mesh)


func set_intensity(t: float) -> void:
	## Called by CombatComponent's channel tick. `t` is the channel
	## progress in 0..1. Scales beam width + emission for the visual
	## ramp.
	_intensity = clampf(t, 0.0, 1.0)


func dismiss() -> void:
	## Begin the fade-out. Channel is ending (either naturally or
	## cancelled); the beam fades over FADE_OUT_SEC and then frees.
	if _dismissing:
		return
	_dismissing = true
	_dismiss_timer = FADE_OUT_SEC


func _process(delta: float) -> void:
	var shooter_node: Node3D = _shooter.get_ref() as Node3D if _shooter else null
	var target_node: Node3D = _target.get_ref() as Node3D if _target else null
	if shooter_node == null or not is_instance_valid(shooter_node):
		queue_free()
		return
	if target_node == null or not is_instance_valid(target_node):
		# Target gone mid-channel — fade out and free.
		if not _dismissing:
			dismiss()

	# Resolve from / to positions.
	var from_pos: Vector3 = shooter_node.global_position
	if _muzzle_marker and is_instance_valid(_muzzle_marker):
		from_pos = _muzzle_marker.global_position
	var to_pos: Vector3
	if target_node != null and is_instance_valid(target_node):
		to_pos = target_node.global_position + Vector3(0, 0.8, 0)
	else:
		# Lost target — beam keeps pointing where it last was.
		to_pos = global_position + (global_basis.z * 5.0)

	# Position + orient the beam meshes between from_pos and to_pos.
	var dir: Vector3 = to_pos - from_pos
	var length: float = dir.length()
	if length < 0.1:
		return
	# Beam intensity — visual scale + emission ramp. Dismissed beams
	# fade down regardless of the channel intensity.
	var visual_t: float = _intensity
	if _dismissing:
		_dismiss_timer -= delta
		var fade_t: float = clampf(_dismiss_timer / FADE_OUT_SEC, 0.0, 1.0)
		visual_t *= fade_t
		if _dismiss_timer <= 0.0:
			queue_free()
			return
	var width: float = lerp(BEAM_WIDTH_START, BEAM_WIDTH_END, visual_t)
	var emission: float = lerp(EMISSION_START, EMISSION_END, visual_t)
	if _core_mat:
		_core_mat.emission_energy_multiplier = emission
	if _halo_mat:
		_halo_mat.emission_energy_multiplier = emission * 0.55
		# Fade halo alpha during dismiss.
		_halo_mat.albedo_color.a = lerp(0.05, 0.55, visual_t)
	# Place + orient via Transform3D so the beam is correct on the
	# first frame too. CORE / HALO share the same transform.
	var mid: Vector3 = (from_pos + to_pos) * 0.5
	var xform := Transform3D()
	xform.origin = mid
	xform = xform.looking_at(to_pos, Vector3.UP)
	# Apply width via per-mesh scale: x = y = width, z = length. The
	# BoxMesh is unit-sized so scale carries the actual dimensions.
	if _core_mesh:
		_core_mesh.transform = xform
		_core_mesh.scale = Vector3(width * 0.40, width * 0.40, length)
	if _halo_mesh:
		_halo_mesh.transform = xform
		_halo_mesh.scale = Vector3(width * 1.20, width * 1.20, length)
