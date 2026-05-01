class_name CursorManager
extends Node
## Industrial-themed mouse cursors that switch based on what's under
## the pointer. Generated procedurally at scene start so we don't need
## external image assets — each cursor is a small bitmap drawn in code.
##
## Kinds:
##   DEFAULT — chunky angular arrow with a rivet, neutral pointer
##   ATTACK  — red crosshair reticle for enemy units / buildings
##   REPAIR  — green wrench when an engineer is hovered over an ally
##   BUILD   — blue brick + cross when in build-placement mode
##   MOVE    — yellow direction chevron when right-clicking ground
##
## SelectionManager calls `set_kind()` whenever its hover state changes.

enum Kind { DEFAULT, ATTACK, REPAIR, BUILD, MOVE }

const _SIZE: int = 28

var _textures: Dictionary = {}
var _current: int = -1


func _ready() -> void:
	_textures[Kind.DEFAULT] = _make_default()
	_textures[Kind.ATTACK] = _make_attack()
	_textures[Kind.REPAIR] = _make_repair()
	_textures[Kind.BUILD] = _make_build()
	_textures[Kind.MOVE] = _make_move()
	set_kind(Kind.DEFAULT)


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
	var tex: ImageTexture = _textures.get(kind) as ImageTexture
	if not tex:
		return
	# Hotspot — most cursor shapes anchor at the top-left so the click
	# point lines up with the visual tip / center of the reticle.
	var hotspot: Vector2 = Vector2(2, 2)
	if kind == Kind.ATTACK or kind == Kind.MOVE:
		# Crosshair / direction chevron read better when anchored to the
		# centre so the click lands on what the player sees.
		hotspot = Vector2(_SIZE * 0.5, _SIZE * 0.5)
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, hotspot)


## --- Procedural cursor generators ----------------------------------------

func _new_image() -> Image:
	# Transparent canvas. set_pixel writes opaque colors to the shapes;
	# untouched pixels stay alpha=0.
	return Image.create(_SIZE, _SIZE, false, Image.FORMAT_RGBA8)


func _make_default() -> ImageTexture:
	# Chunky angular arrow pointing up-left — the dieselpunk pointer.
	# White interior, dark outline, single rivet near the base.
	var img: Image = _new_image()
	var fg := Color(0.92, 0.92, 0.88, 1.0)   # off-white plate
	var ol := Color(0.05, 0.05, 0.05, 1.0)   # near-black outline
	var rivet := Color(0.55, 0.50, 0.45, 1.0)
	# Arrow body — a triangle with a flag tail. Built row-by-row so
	# the silhouette stays sharp at 28px.
	for y: int in _SIZE:
		# Triangle width grows down to row ~14, then narrows back to a
		# thin tail.
		var width: int
		if y < 14:
			width = y / 2 + 2
		else:
			width = maxi(20 - y, 2)
		# Outline pass — one pixel wider than the body.
		for x: int in _SIZE:
			if x >= 2 and x < width + 2:
				if x == 2 or x == width + 1 or y == 0 or y == 27:
					img.set_pixel(x, y, ol)
				else:
					img.set_pixel(x, y, fg)
	# Rivet at the arrow's base — small dark dot for industrial flavor.
	for dx: int in 2:
		for dy: int in 2:
			img.set_pixel(5 + dx, 18 + dy, rivet)
	return ImageTexture.create_from_image(img)


func _make_attack() -> ImageTexture:
	# Red crosshair reticle — angular brackets at four corners of a
	# central diamond, with a small dot at the centre.
	var img: Image = _new_image()
	var red := Color(1.0, 0.25, 0.20, 1.0)
	var dark_red := Color(0.35, 0.05, 0.05, 1.0)
	var center: int = _SIZE / 2
	# Outer corner brackets (4 L-shaped ticks).
	var bracket_len: int = 6
	var bracket_offset: int = 11
	for i: int in bracket_len:
		# Top-left bracket — vertical + horizontal ticks meeting near
		# top-left corner.
		img.set_pixel(center - bracket_offset, center - bracket_offset + i, red)
		img.set_pixel(center - bracket_offset + i, center - bracket_offset, red)
		# Top-right.
		img.set_pixel(center + bracket_offset, center - bracket_offset + i, red)
		img.set_pixel(center + bracket_offset - i, center - bracket_offset, red)
		# Bottom-left.
		img.set_pixel(center - bracket_offset, center + bracket_offset - i, red)
		img.set_pixel(center - bracket_offset + i, center + bracket_offset, red)
		# Bottom-right.
		img.set_pixel(center + bracket_offset, center + bracket_offset - i, red)
		img.set_pixel(center + bracket_offset - i, center + bracket_offset, red)
	# Centre dot.
	for dx: int in 2:
		for dy: int in 2:
			img.set_pixel(center + dx - 1, center + dy - 1, dark_red)
	# Crosshair lines through the centre — short stubs.
	for i: int in range(4, 9):
		img.set_pixel(center + i, center, red)
		img.set_pixel(center - i, center, red)
		img.set_pixel(center, center + i, red)
		img.set_pixel(center, center - i, red)
	return ImageTexture.create_from_image(img)


func _make_repair() -> ImageTexture:
	# Green wrench silhouette — shaft + open jaw at the head.
	var img: Image = _new_image()
	var green := Color(0.30, 0.92, 0.45, 1.0)
	var dark_g := Color(0.10, 0.30, 0.15, 1.0)
	# Shaft — diagonal rectangle from upper-left to lower-right.
	for i: int in 18:
		var x: int = 4 + i
		var y: int = 4 + i
		img.set_pixel(x, y, green)
		img.set_pixel(x + 1, y, green)
		img.set_pixel(x, y + 1, green)
		img.set_pixel(x + 1, y + 1, dark_g)
	# Wrench head — chunkier rectangle + open jaw at the upper-left end.
	for dx: int in 6:
		for dy: int in 6:
			if dx < 5 and dy < 5:
				img.set_pixel(2 + dx, 2 + dy, green)
	# Jaw opening — a 2x2 transparent cut into the head.
	for dx: int in 2:
		for dy: int in 2:
			img.set_pixel(3 + dx, 3 + dy, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)


func _make_build() -> ImageTexture:
	# Cyan brick + cross — placement marker. Small square brick outline
	# with a cross overlay indicating "place here".
	var img: Image = _new_image()
	var cyan := Color(0.50, 0.90, 1.0, 1.0)
	var dark_c := Color(0.08, 0.20, 0.30, 1.0)
	# Brick — 14x14 outlined square.
	var origin: int = 7
	var sq: int = 14
	for i: int in sq:
		img.set_pixel(origin + i, origin, cyan)         # top
		img.set_pixel(origin + i, origin + sq - 1, cyan)  # bottom
		img.set_pixel(origin, origin + i, cyan)         # left
		img.set_pixel(origin + sq - 1, origin + i, cyan)  # right
	# Cross overlay through the center.
	var center: int = _SIZE / 2
	for i: int in 9:
		img.set_pixel(center + i - 4, center, dark_c)
		img.set_pixel(center, center + i - 4, dark_c)
	return ImageTexture.create_from_image(img)


func _make_move() -> ImageTexture:
	# Yellow direction chevron — three stacked V-shapes pointing down,
	# evoking "head this way."
	var img: Image = _new_image()
	var amber := Color(1.0, 0.85, 0.30, 1.0)
	var dark_a := Color(0.40, 0.30, 0.05, 1.0)
	var center: int = _SIZE / 2
	# Three chevrons at increasing Y, each a V of pixels.
	for ch: int in 3:
		var y: int = 6 + ch * 6
		for i: int in 6:
			img.set_pixel(center - i, y + i, amber)
			img.set_pixel(center + i, y + i, amber)
			# Soft inner shadow.
			if i > 0:
				img.set_pixel(center - i + 1, y + i, dark_a)
				img.set_pixel(center + i - 1, y + i, dark_a)
	return ImageTexture.create_from_image(img)
