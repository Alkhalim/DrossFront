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
	## The cell-state byte is stored verbatim in the texture's R
	## channel; the shader scales the 0..1 sample back to the
	## integer cell-state value before bucketing.
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform sampler2D fog_texture : filter_nearest, repeat_disable;

void fragment() {
	// PlaneMesh ships unit UVs; the plane is centred on origin so
	// UV.x = (x + half) / (2 * half) maps directly to texel index.
	// R8 sample returns byte / 255; multiply back to get the raw
	// cell-state byte value (0, 1, or 2).
	int state = int(texture(fog_texture, UV).r * 255.0 + 0.5);
	if (state == 0) {
		// UNEXPLORED -- opaque black.
		ALBEDO = vec3(0.0);
		ALPHA = 1.0;
	} else if (state == 1) {
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
	# Hand the cell PackedByteArray straight to the image -- the
	# bytes already match R8 layout (1 byte per cell carrying the
	# CellState enum value 0/1/2). The shader rescales 0..1
	# sample back to the integer state, so no per-byte CPU loop
	# rewriting is needed. The previous version walked the
	# 60k-cell array in GDScript per FOW recompute -- the loop
	# alone was a measurable chunk of the per-tick cost.
	_fog_image.set_data(_grid_size, _grid_size, false, Image.FORMAT_R8, cells)
	_fog_texture.update(_fog_image)
	_last_revision = _fow.revision
