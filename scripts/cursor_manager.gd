class_name CursorManager
extends Node
## Industrial-themed mouse cursors built procedurally at scene start.
## All variants share a single base silhouette — a slightly-rounded
## chunky arrow rendered in gunmetal grey with a soft highlight along
## the inner edge — and differ via colour tint plus a small accent
## glyph attached to the arrow's lower-right shoulder.
##
## Kinds:
##   DEFAULT — gunmetal grey, no glyph
##   ATTACK  — red tint, crosshair-bracket glyph
##   REPAIR  — green tint, wrench glyph
##   BUILD   — cyan tint, brick glyph
##   MOVE    — amber tint, chevron glyph
##
## SelectionManager calls `set_kind()` whenever its hover state changes.
## Static helper `apply_default_cursor(tree)` lets the main menu / boot
## scenes set the gunmetal cursor without spinning up a full manager.

enum Kind { DEFAULT, ATTACK, REPAIR, BUILD, MOVE }

const _SIZE: int = 28

# Base palette — gunmetal grey body + cooler highlight + dark outline.
const _BODY_BASE: Color = Color(0.34, 0.36, 0.40, 1.0)
const _HIGHLIGHT_BASE: Color = Color(0.62, 0.65, 0.68, 1.0)
const _OUTLINE: Color = Color(0.06, 0.07, 0.08, 1.0)
const _RIVET: Color = Color(0.18, 0.20, 0.22, 1.0)

var _textures: Dictionary = {}
var _textures_pressed: Dictionary = {}
var _current: int = -1
var _is_pressed: bool = false


func _ready() -> void:
	_textures[Kind.DEFAULT] = _make_arrow(_BODY_BASE, _HIGHLIGHT_BASE, Kind.DEFAULT, false)
	_textures[Kind.ATTACK] = _make_arrow(
		Color(0.55, 0.18, 0.18, 1.0), Color(0.95, 0.45, 0.40, 1.0), Kind.ATTACK, false
	)
	_textures[Kind.REPAIR] = _make_arrow(
		Color(0.20, 0.45, 0.25, 1.0), Color(0.50, 0.92, 0.55, 1.0), Kind.REPAIR, false
	)
	_textures[Kind.BUILD] = _make_arrow(
		Color(0.18, 0.40, 0.50, 1.0), Color(0.55, 0.90, 1.00, 1.0), Kind.BUILD, false
	)
	_textures[Kind.MOVE] = _make_arrow(
		Color(0.55, 0.42, 0.12, 1.0), Color(1.00, 0.85, 0.32, 1.0), Kind.MOVE, false
	)
	# Pressed variants — same shape and tint but darkened and pixel-
	# shifted 2px down-right, simulating the cursor being physically
	# pushed when the player clicks. Generated once at startup so the
	# swap on mouse-down is just a texture pointer change.
	_textures_pressed[Kind.DEFAULT] = _make_arrow(_BODY_BASE.darkened(0.25), _HIGHLIGHT_BASE.darkened(0.2), Kind.DEFAULT, true)
	_textures_pressed[Kind.ATTACK] = _make_arrow(
		Color(0.40, 0.10, 0.10, 1.0), Color(0.75, 0.30, 0.25, 1.0), Kind.ATTACK, true
	)
	_textures_pressed[Kind.REPAIR] = _make_arrow(
		Color(0.12, 0.32, 0.18, 1.0), Color(0.35, 0.70, 0.40, 1.0), Kind.REPAIR, true
	)
	_textures_pressed[Kind.BUILD] = _make_arrow(
		Color(0.10, 0.28, 0.36, 1.0), Color(0.40, 0.70, 0.80, 1.0), Kind.BUILD, true
	)
	_textures_pressed[Kind.MOVE] = _make_arrow(
		Color(0.40, 0.30, 0.08, 1.0), Color(0.78, 0.65, 0.22, 1.0), Kind.MOVE, true
	)
	set_kind(Kind.DEFAULT)


func _input(event: InputEvent) -> void:
	## Cursor "physical click" feel — swap to the darker / shifted
	## pressed variant on mouse-down, restore on release. Both buttons
	## (left and right) trigger the swap so right-clicking commands
	## also get the press feedback.
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed != _is_pressed:
				_is_pressed = mb.pressed
				_apply_current()


## Used by main menu / boot scenes to install the default gunmetal
## cursor without creating a full CursorManager instance. Generates the
## arrow once and applies it via Input.set_custom_mouse_cursor.
static func apply_default_cursor() -> void:
	var tex: ImageTexture = _build_arrow_static(_BODY_BASE, _HIGHLIGHT_BASE, Kind.DEFAULT)
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, Vector2(2, 2))


## Static lookup so any system can switch cursors via the scene-level
## CursorManager node without explicit refs.
static func get_instance(tree: SceneTree) -> Node:
	if not tree:
		return null
	var scene: Node = tree.current_scene
	if not scene:
		return null
	return scene.get_node_or_null("CursorManager")


func set_kind(kind: int) -> void:
	if _current == kind:
		return
	_current = kind
	_apply_current()


func _apply_current() -> void:
	var bank: Dictionary = _textures_pressed if _is_pressed else _textures
	var tex: ImageTexture = bank.get(_current) as ImageTexture
	if not tex:
		return
	# Anchor stays at the arrow tip — pressed variant pixel-shifts the
	# silhouette but the click point should remain at the same screen
	# location, so the hotspot doesn't move.
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, Vector2(2, 2))


## --- Procedural cursor generators ----------------------------------------

func _make_arrow(body: Color, highlight: Color, kind: int, pressed: bool = false) -> ImageTexture:
	return _build_arrow_static(body, highlight, kind, pressed)


static func _build_arrow_static(body: Color, highlight: Color, kind: int, pressed: bool = false) -> ImageTexture:
	## Draws the shared arrow silhouette tinted with `body` and inner
	## highlight `highlight`, then overlays the per-kind glyph at the
	## arrow's lower-right shoulder.
	var img := Image.create(_SIZE, _SIZE, false, Image.FORMAT_RGBA8)
	# Pressed variants pixel-shift the arrow 2 down + 1 right so the
	# cursor visually "sinks" into the click point, simulating the
	# physical motion of a button press without animating.
	var shift_x: int = 1 if pressed else 0
	var shift_y: int = 2 if pressed else 0
	# Slightly-rounded chunky arrow — built row-by-row. The shape is
	# the same as a standard pointer but the corners taper smoothly
	# instead of going to single-pixel points.
	for y: int in _SIZE:
		var width: int = _arrow_width(y)
		if width <= 0:
			continue
		for x: int in width + 2:
			var px: int = 2 + x + shift_x
			var py: int = y + shift_y
			if px >= _SIZE or py >= _SIZE:
				continue
			# Outline at the silhouette boundary.
			var on_outline: bool = (x == 0 or x == width + 1 or y == 0 or y == _SIZE - 1)
			# Edge softening — top-left and bottom-left corners get a
			# rounded slope so the cursor reads as cast metal rather
			# than CRT pixel art.
			if y < 2 and x > width - 1:
				continue
			if y > 19 and x > maxi(width - (y - 19) * 2, 1):
				continue
			if on_outline:
				img.set_pixel(px, py, _OUTLINE)
			elif x <= 1:
				# Inner highlight — runs along the leading (left) edge.
				img.set_pixel(px, py, highlight)
			else:
				# Body fill, slightly darker toward the trailing edge.
				var t: float = float(x) / float(maxi(width, 1))
				img.set_pixel(px, py, body.lerp(_OUTLINE, t * 0.35))
	# Dark rivet near the arrow's base for industrial flavor — also
	# pixel-shifted with the rest of the body when pressed.
	for dx: int in 2:
		for dy: int in 2:
			var rx: int = 5 + dx + shift_x
			var ry: int = 16 + dy + shift_y
			if rx < _SIZE and ry < _SIZE:
				img.set_pixel(rx, ry, _RIVET)
	# Per-kind accent glyph attached to the lower-right shoulder. The
	# arrow ends around y=22, so glyph sits in y=14..22 range.
	match kind:
		Kind.ATTACK:
			_draw_glyph_crosshair(img, Color(1.0, 0.30, 0.25, 1.0))
		Kind.REPAIR:
			_draw_glyph_wrench(img, Color(0.55, 1.0, 0.55, 1.0))
		Kind.BUILD:
			_draw_glyph_brick(img, Color(0.65, 0.95, 1.0, 1.0))
		Kind.MOVE:
			_draw_glyph_chevron(img, Color(1.0, 0.85, 0.30, 1.0))
		_:
			pass  # DEFAULT — no glyph
	return ImageTexture.create_from_image(img)


static func _arrow_width(y: int) -> int:
	## Returns the row width of the arrow body at row `y`. Wider in
	## the upper half (the arrow head), narrowing into a flag tail
	## toward the bottom.
	if y < 2:
		return y + 1            # rounded tip
	if y < 14:
		return y / 2 + 2        # head expands
	if y < 22:
		return maxi(20 - y, 2)  # tail narrows
	return 0


## --- Glyphs ---
##
## Each glyph is small (5-7px) and sits in the bottom-right area of the
## cursor texture so it doesn't disrupt the silhouette but is readable
## alongside the colored arrow.

static func _draw_glyph_crosshair(img: Image, color: Color) -> void:
	# Tiny corner brackets + centre dot.
	var cx: int = 20
	var cy: int = 18
	for i: int in 4:
		img.set_pixel(cx - 3, cy - 3 + i, color)
		img.set_pixel(cx - 3 + i, cy - 3, color)
		img.set_pixel(cx + 3, cy - 3 + i, color)
		img.set_pixel(cx + 3 - i, cy - 3, color)
		img.set_pixel(cx - 3, cy + 3 - i, color)
		img.set_pixel(cx - 3 + i, cy + 3, color)
		img.set_pixel(cx + 3, cy + 3 - i, color)
		img.set_pixel(cx + 3 - i, cy + 3, color)
	img.set_pixel(cx, cy, color)


static func _draw_glyph_wrench(img: Image, color: Color) -> void:
	# Diagonal shaft + 3x3 head with a 1px notch (jaw).
	var ox: int = 16
	var oy: int = 14
	for i: int in 7:
		img.set_pixel(ox + i, oy + i, color)
		img.set_pixel(ox + i + 1, oy + i, color)
	# Wrench head at the upper-left end.
	for dx: int in 4:
		for dy: int in 4:
			img.set_pixel(ox - 1 + dx, oy - 1 + dy, color)
	# Notch (jaw opening) — 1×1 transparent gap.
	img.set_pixel(ox, oy, Color(0, 0, 0, 0))


static func _draw_glyph_brick(img: Image, color: Color) -> void:
	# 6x6 outlined brick — placement marker.
	var ox: int = 16
	var oy: int = 16
	for i: int in 6:
		img.set_pixel(ox + i, oy, color)
		img.set_pixel(ox + i, oy + 5, color)
		img.set_pixel(ox, oy + i, color)
		img.set_pixel(ox + 5, oy + i, color)
	# Small cross inside the brick.
	for i: int in 3:
		img.set_pixel(ox + 1 + i, oy + 2, color)
		img.set_pixel(ox + 2, oy + 1 + i, color)


static func _draw_glyph_chevron(img: Image, color: Color) -> void:
	# Two stacked chevrons pointing down.
	for ch: int in 2:
		var y: int = 16 + ch * 4
		for i: int in 4:
			img.set_pixel(18 - i, y + i, color)
			img.set_pixel(18 + i, y + i, color)
