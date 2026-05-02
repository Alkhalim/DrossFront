class_name FogOverlay
extends Node3D
## Visible darkening layer that sits just above the ground and tints
## itself per-cell from the FogOfWar grid:
##   UNEXPLORED -> opaque black (player has no idea what's there)
##   EXPLORED   -> ~55% dim grey (terrain visible, no live info)
##   VISIBLE    -> fully transparent
##
## Implementation: a single MultiMeshInstance3D with one flat quad per
## cell, modulated via per-instance custom data colour. The shader
## reads custom data .a as the alpha multiplier so visible cells
## drop to alpha 0 each frame without needing to rebuild the
## MultiMesh layout — only the per-instance colour buffer is
## re-uploaded.

## Overlay quads sit just above the ground plane. Lifting them higher
## pushes them in front of the tilted RTS camera (50 deg pitch) and
## introduces a parallax offset — a unit at world (X, 0, Z) appears
## centred ~10u south of where its vision circle is actually punched
## out. Keeping it at ground level removes the offset entirely.
## Per-entity FOW visibility hooks (units, buildings, wrecks,
## projectiles) handle hiding TALL stuff in unexplored cells; the
## overlay only needs to cover ground texture.
const CELL_LIFT_Y: float = 0.1

var _multimesh: MultiMeshInstance3D = null
var _mm: MultiMesh = null
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

	_build_multimesh()
	_refresh_colors()


func _process(_delta: float) -> void:
	if not _fow:
		return
	# Only re-upload the per-instance colour buffer when FOW has
	# actually recomputed. revision is bumped at the end of the
	# 5 Hz tick so we mirror the same cadence here.
	if _fow.revision != _last_revision:
		_refresh_colors()


func _build_multimesh() -> void:
	# Single flat quad mesh used for every cell.
	var quad := QuadMesh.new()
	quad.size = Vector2(_cell_size, _cell_size)
	# QuadMesh sits in the XY plane facing +Z by default. Lay it
	# flat by rotating about X so its surface is horizontal.
	# We rotate the per-instance transform instead of building a
	# pre-rotated mesh so the shader-side normal stays sane.

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = false
	_mm.use_custom_data = true
	_mm.mesh = quad
	_mm.instance_count = _grid_size * _grid_size

	# Pre-place every quad transform once. Per-frame work only
	# touches the custom data buffer (alpha multiplier per cell),
	# not the position transforms. Cell N centre at world
	# (N*cell - half_extent) — matches FogOfWar._world_to_cell's
	# round-based mapping so a unit's visibility cells line up
	# pixel-for-pixel with where the unit actually is.
	for cz: int in _grid_size:
		for cx: int in _grid_size:
			var i: int = cz * _grid_size + cx
			var x: float = float(cx) * _cell_size - _half_extent
			var z: float = float(cz) * _cell_size - _half_extent
			var t := Transform3D()
			t = t.rotated(Vector3.RIGHT, -PI * 0.5)
			t.origin = Vector3(x, CELL_LIFT_Y, z)
			_mm.set_instance_transform(i, t)
			_mm.set_instance_custom_data(i, Color(1, 1, 1, 1))

	_multimesh = MultiMeshInstance3D.new()
	_multimesh.name = "FogOverlayMM"
	_multimesh.multimesh = _mm
	_multimesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_multimesh.material_override = _make_overlay_material()
	# Generous AABB so the overlay isn't culled when the camera is
	# only looking at one corner of the map.
	_multimesh.custom_aabb = AABB(
		Vector3(-_half_extent, -1.0, -_half_extent),
		Vector3(_half_extent * 2.0, 4.0, _half_extent * 2.0),
	)
	add_child(_multimesh)


func _make_overlay_material() -> ShaderMaterial:
	# INSTANCE_CUSTOM is only readable in the VERTEX stage in
	# Godot 4 spatial shaders, so we hand-pipe the colour value
	# through a varying so the fragment stage can sample it. The
	# previous version tried to read INSTANCE_CUSTOM directly in
	# fragment, which fails to compile and the whole material
	# falls back to invisible.
	#
	# .rgb is the tint colour (black for unexplored, blue-grey for
	# explored), .a is the per-cell alpha multiplier. Visible cells
	# push alpha to 0 so the camera sees the world clearly;
	# explored cells dim with a slightly desaturated cool grey so
	# they read as MEMORY rather than just "dark"; unexplored cells
	# go fully opaque black so the player has zero info.
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

varying vec4 v_fog_color;

void vertex() {
	v_fog_color = INSTANCE_CUSTOM;
}

void fragment() {
	ALBEDO = v_fog_color.rgb;
	ALPHA = v_fog_color.a;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


## Per-state overlay colours. Unexplored is opaque black so the
## player sees nothing of what's there. Explored cells use a
## very-light cool grey at low alpha so the underlying terrain +
## buildings + wrecks read clearly — the previous 0.65 alpha was
## reading as a "block of grey colour" that swamped detail.
## Currently visible cells stay fully clear.
const FOG_COLOR_UNEXPLORED: Color = Color(0.0, 0.0, 0.0, 1.0)
const FOG_COLOR_EXPLORED: Color = Color(0.05, 0.06, 0.08, 0.32)


func _refresh_colors() -> void:
	if not _mm or not _fow:
		return
	var cells: PackedByteArray = _fow.get_cells()
	var size: int = mini(cells.size(), _mm.instance_count)
	for i: int in size:
		var state: int = cells[i]
		var col: Color = Color(0, 0, 0, 0)
		match state:
			FogOfWar.CellState.UNEXPLORED:
				col = FOG_COLOR_UNEXPLORED
			FogOfWar.CellState.EXPLORED:
				col = FOG_COLOR_EXPLORED
			_:
				col = Color(0, 0, 0, 0)
		_mm.set_instance_custom_data(i, col)
	_last_revision = _fow.revision
