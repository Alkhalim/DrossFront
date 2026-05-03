class_name FogOverlay
extends Node3D
## Visible darkening layer that sits just above the ground and tints
## per-cell from the FogOfWar grid:
##   UNEXPLORED -> opaque black (player has no idea what's there)
##   EXPLORED   -> ~55% dim grey (terrain visible, no live info)
##   VISIBLE    -> fully transparent
##
## Implementation: a single PlaneMesh covering the whole map, with a
## ShaderMaterial sampling a fog ImageTexture (one texel per cell).
## Each FOW tick we refresh the texture in one buffer upload instead
## of pushing 60k+ per-instance custom-data writes through the
## RenderingServer the way the previous MultiMesh approach did.

const CELL_LIFT_Y: float = 0.1

var _plane_mesh: MeshInstance3D = null
var _shader_material: ShaderMaterial = null
var _fog_image: Image = null
var _fog_texture: ImageTexture = null
var _grid_size: int = 0
var _cell_size: float = 0.0
var _half_extent: float = 0.0
var _fow: FogOfWar = null
var _last_revision: int = -1


func _ready() -> void:
	_fow = get_tree().current_scene.get_node_or_null("FogOfWar") as FogOfWar
	if not _fow:
		queue_free()
		return
	_grid_size = _fow.get_grid_size()
	_cell_size = FogOfWar.CELL_SIZE
	_half_extent = FogOfWar.MAP_HALF_EXTENT

	_build_overlay()
	_refresh_texture()


func _process(_delta: float) -> void:
	if not _fow:
		return
	# Only re-upload the texture when FOW has actually recomputed.
	# revision is bumped at the end of the 5 Hz tick so we mirror
	# the same cadence here.
	if _fow.revision != _last_revision:
		_refresh_texture()


func _build_overlay() -> void:
	# One flat plane covering the map. The shader samples the fog
	# texture per-fragment so cell tinting / smoothing is GPU-side
	# instead of pushing per-cell uploads through the
	# RenderingServer per tick.
	var quad := PlaneMesh.new()
	quad.size = Vector2(_half_extent * 2.0, _half_extent * 2.0)
	quad.subdivide_width = 1
	quad.subdivide_depth = 1

	# Fog texture -- one byte per cell (R8 channel) carrying the
	# CellState enum value. The shader maps that value to the dim
	# tint per-fragment.
	_fog_image = Image.create(_grid_size, _grid_size, false, Image.FORMAT_R8)
	_fog_image.fill(Color(0, 0, 0, 0))
	_fog_texture = ImageTexture.create_from_image(_fog_image)

	_shader_material = _make_overlay_material()
	_shader_material.set_shader_parameter("fog_texture", _fog_texture)
	_shader_material.set_shader_parameter("map_half_extent", _half_extent)
	_shader_material.set_shader_parameter("cell_state_max", 2.0)

	_plane_mesh = MeshInstance3D.new()
	_plane_mesh.name = "FogOverlayPlane"
	_plane_mesh.mesh = quad
	_plane_mesh.position = Vector3(0.0, CELL_LIFT_Y, 0.0)
	_plane_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_plane_mesh.material_override = _shader_material
	# Generous AABB so the plane isn't culled at oblique camera
	# angles where the bounds barely overlap the screen.
	_plane_mesh.custom_aabb = AABB(
		Vector3(-_half_extent, -1.0, -_half_extent),
		Vector3(_half_extent * 2.0, 4.0, _half_extent * 2.0),
	)
	add_child(_plane_mesh)


func _make_overlay_material() -> ShaderMaterial:
	## Spatial shader. Samples the fog texture in world-space:
	##  - 0 (UNEXPLORED) -> opaque black
	##  - 1 (EXPLORED)   -> ~55% dim
	##  - 2 (VISIBLE)    -> fully transparent
	## The cell state is stored as the texture's R channel; we
	## quantize the sampled value into the three buckets so a
	## linear-filtered sample on the boundary still picks one bucket
	## cleanly instead of fading through.
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform sampler2D fog_texture : filter_nearest, repeat_disable;
uniform float map_half_extent;
uniform float cell_state_max;

void fragment() {
	// Map world XZ into [0, 1] UV using the plane's local UV
	// (PlaneMesh ships unit UVs). The plane is centred on the
	// origin spanning -half..+half on X/Z so UV.x = (x + half) /
	// (2 * half), and the plane mesh has UV already aligned that
	// way.
	float r = texture(fog_texture, UV).r;
	// Texture stores cell state byte; rescale to 0..2 range.
	float state = round(r * cell_state_max);
	if (state < 0.5) {
		// UNEXPLORED -- opaque black.
		ALBEDO = vec3(0.0);
		ALPHA = 1.0;
	} else if (state < 1.5) {
		// EXPLORED -- dim memory.
		ALBEDO = vec3(0.0);
		ALPHA = 0.55;
	} else {
		// VISIBLE -- pass through.
		ALBEDO = vec3(0.0);
		ALPHA = 0.0;
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


func _refresh_texture() -> void:
	if not _fog_image or not _fog_texture or not _fow:
		return
	var cells: PackedByteArray = _fow.get_cells()
	if cells.size() != _grid_size * _grid_size:
		return
	# Pack the cell-state byte array directly into the image. R8
	# format expects raw bytes per pixel matching exactly. The
	# cell state values 0/1/2 map onto the texture's R channel
	# 0/1/2 byte values; the shader rescales by cell_state_max.
	# The texture range 0..255 means our 0/1/2 sample as
	# ~0.0/0.004/0.008 floats; rescaling cell_state_max = 2 still
	# works because we sample raw bytes via the 8-bit format and
	# rescale relative to 2.0 / 255.0 below.
	# To keep the shader simple, write pre-rescaled bytes (state
	# * 127 + 1) -- maps {0, 1, 2} to {0, 128, 255} which
	# survives 8-bit precision cleanly.
	var data: PackedByteArray = PackedByteArray()
	data.resize(cells.size())
	for i: int in cells.size():
		var s: int = cells[i] & 0x3
		# Map CellState to a byte the shader can pick three buckets
		# from after the implicit /255 read: 0 -> 0, 1 -> 128, 2 -> 255.
		var b: int = 0
		if s == 1:
			b = 128
		elif s == 2:
			b = 255
		data[i] = b
	_fog_image.set_data(_grid_size, _grid_size, false, Image.FORMAT_R8, data)
	_fog_texture.update(_fog_image)
	# Shader samples raw byte / 255, so rescale to pick three
	# buckets from {0.0, 0.5, 1.0}: cell_state_max * sample_value
	# should land on the three integer buckets {0, 1, 2}.
	_shader_material.set_shader_parameter("cell_state_max", 2.0)
	_last_revision = _fow.revision
