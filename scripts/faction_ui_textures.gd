class_name FactionUITextures
extends RefCounted
## Process-wide cache of procedurally-generated HUD textures keyed
## per faction. Mirrors SharedTextures' generate-once / share-handle
## pattern; each texture is built on first request and reused for
## every StyleBoxTexture and TextureRect that consumes it.
##
## Anvil = riveted industrial steel plate. Warm dark brown-grey base,
## low-frequency hammered variation, rivet dots clustered near the
## corners + along the edges, faint horizontal panel-line at mid-
## height for the "two plates bolted together" read.
##
## Sable = corpo specops sleek metal. Dark slate-violet base with a
## subtle hex grid + horizontal scanline overlay, thin emissive
## violet edge trim already baked in so callers only need to drop
## the texture into a StyleBoxTexture.
##
## Each faction ships several variants so callers can pick the right
## treatment per surface:
##   - button_face: small (128²) tile for individual buttons.
##   - panel_face: larger (256²) with quieter detail for big panels.
##   - top_bar: wide (512×96) banded strip for the resource bar.
##   - frame_corner: small (64²) corner ornament drawn over panel
##     edges to sell the chrome (rivet cluster / Sable bracket).

const _BUTTON_SIZE: int = 128
const _PANEL_SIZE: int = 256
const _TOP_BAR_W: int = 512
const _TOP_BAR_H: int = 96
const _FRAME_CORNER: int = 64

# --- Anvil palette ---
const _ANVIL_BASE: Color           = Color(0.30, 0.24, 0.18, 1.0)  # warm dark steel
const _ANVIL_BASE_DARK: Color      = Color(0.18, 0.15, 0.12, 1.0)  # panel back
const _ANVIL_RIVET: Color          = Color(0.55, 0.46, 0.30, 1.0)  # brassy bolt cap
const _ANVIL_RIVET_SHADOW: Color   = Color(0.10, 0.08, 0.06, 1.0)
const _ANVIL_HIGHLIGHT: Color      = Color(0.50, 0.42, 0.30, 1.0)  # plate edge bevel
const _ANVIL_CAUTION_YELLOW: Color = Color(0.95, 0.78, 0.18, 1.0)  # top-bar stripe
const _ANVIL_CAUTION_BLACK: Color  = Color(0.10, 0.09, 0.07, 1.0)

# --- Sable palette ---
const _SABLE_BASE: Color           = Color(0.10, 0.10, 0.16, 1.0)  # dark slate-violet
const _SABLE_BASE_DARK: Color      = Color(0.06, 0.06, 0.10, 1.0)
const _SABLE_VIOLET: Color         = Color(0.78, 0.42, 1.00, 1.0)  # emissive trim
const _SABLE_VIOLET_DIM: Color     = Color(0.45, 0.25, 0.62, 1.0)
const _SABLE_HEX_TINT: Color       = Color(0.16, 0.14, 0.22, 1.0)  # hex outline
const _SABLE_SCAN_DARK: Color      = Color(0.04, 0.04, 0.07, 1.0)

# --- Anvil cache ---
static var _anvil_button_face: Texture2D = null
static var _anvil_panel_face: Texture2D = null
static var _anvil_top_bar: Texture2D = null
static var _anvil_frame_corner: Texture2D = null
# --- Sable cache ---
static var _sable_button_face: Texture2D = null
static var _sable_panel_face: Texture2D = null
static var _sable_top_bar: Texture2D = null
static var _sable_frame_corner: Texture2D = null


# ---------------------------------------------------------------- API

static func get_button_face(faction: int) -> Texture2D:
	## faction: 0 = Anvil, 1 = Sable. Returns the small tileable
	## button-face texture for that faction.
	if faction == 1:
		if not _sable_button_face:
			_sable_button_face = _build_sable_button_face()
		return _sable_button_face
	if not _anvil_button_face:
		_anvil_button_face = _build_anvil_button_face()
	return _anvil_button_face


static func get_panel_face(faction: int) -> Texture2D:
	if faction == 1:
		if not _sable_panel_face:
			_sable_panel_face = _build_sable_panel_face()
		return _sable_panel_face
	if not _anvil_panel_face:
		_anvil_panel_face = _build_anvil_panel_face()
	return _anvil_panel_face


static func get_top_bar(faction: int) -> Texture2D:
	if faction == 1:
		if not _sable_top_bar:
			_sable_top_bar = _build_sable_top_bar()
		return _sable_top_bar
	if not _anvil_top_bar:
		_anvil_top_bar = _build_anvil_top_bar()
	return _anvil_top_bar


static func get_frame_corner(faction: int) -> Texture2D:
	## Top-left oriented corner ornament. Callers rotate copies to
	## populate the other three corners.
	if faction == 1:
		if not _sable_frame_corner:
			_sable_frame_corner = _build_sable_frame_corner()
		return _sable_frame_corner
	if not _anvil_frame_corner:
		_anvil_frame_corner = _build_anvil_frame_corner()
	return _anvil_frame_corner


# ---------------------------------------------------------------- Anvil

static func _build_anvil_button_face() -> Texture2D:
	## Riveted plate -- warm dark steel base with low-frequency
	## hammered variation, four corner rivets + two mid-edge rivets,
	## a faint horizontal panel-line at mid-height.
	var img := Image.create(_BUTTON_SIZE, _BUTTON_SIZE, false, Image.FORMAT_RGBA8)
	var hammer := FastNoiseLite.new()
	hammer.seed = 311
	hammer.frequency = 0.04
	hammer.fractal_octaves = 2
	var grit := FastNoiseLite.new()
	grit.seed = 73
	grit.frequency = 0.32
	for y: int in _BUTTON_SIZE:
		for x: int in _BUTTON_SIZE:
			var hv: float = hammer.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var gv: float = grit.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			# Hammered variation around the base, plus speckle for
			# weathered grain. Stays dark-side so the role-color
			# corner brackets can read against the plate.
			var base_mul: float = lerp(0.78, 1.10, hv)
			base_mul += (gv - 0.5) * 0.10
			var c: Color = _ANVIL_BASE * base_mul
			c.a = 1.0
			img.set_pixel(x, y, c)
	# Beveled edge: brighten the topmost / leftmost two-pixel border,
	# darken the bottom / right so the plate reads as inset metal.
	for i: int in _BUTTON_SIZE:
		_blend_pixel(img, i, 0, _ANVIL_HIGHLIGHT, 0.55)
		_blend_pixel(img, i, 1, _ANVIL_HIGHLIGHT, 0.30)
		_blend_pixel(img, 0, i, _ANVIL_HIGHLIGHT, 0.55)
		_blend_pixel(img, 1, i, _ANVIL_HIGHLIGHT, 0.30)
		_blend_pixel(img, i, _BUTTON_SIZE - 1, _ANVIL_RIVET_SHADOW, 0.55)
		_blend_pixel(img, i, _BUTTON_SIZE - 2, _ANVIL_RIVET_SHADOW, 0.30)
		_blend_pixel(img, _BUTTON_SIZE - 1, i, _ANVIL_RIVET_SHADOW, 0.55)
		_blend_pixel(img, _BUTTON_SIZE - 2, i, _ANVIL_RIVET_SHADOW, 0.30)
	# Horizontal panel-line at mid-height. The plate reads as two
	# riveted halves bolted together.
	var mid: int = _BUTTON_SIZE / 2
	for x: int in _BUTTON_SIZE:
		_blend_pixel(img, x, mid, _ANVIL_RIVET_SHADOW, 0.65)
		_blend_pixel(img, x, mid - 1, _ANVIL_HIGHLIGHT, 0.18)
		_blend_pixel(img, x, mid + 1, _ANVIL_RIVET_SHADOW, 0.20)
	# Rivets: four corners (8u inset) + two mid-edge (top-mid, bottom-mid)
	# at the panel line. Radius 4 + a one-pixel highlight so each cap
	# reads as a domed bolt.
	var rivet_inset: int = 9
	_draw_rivet(img, rivet_inset, rivet_inset)
	_draw_rivet(img, _BUTTON_SIZE - rivet_inset, rivet_inset)
	_draw_rivet(img, rivet_inset, _BUTTON_SIZE - rivet_inset)
	_draw_rivet(img, _BUTTON_SIZE - rivet_inset, _BUTTON_SIZE - rivet_inset)
	_draw_rivet(img, _BUTTON_SIZE / 2, mid)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_anvil_panel_face() -> Texture2D:
	## Larger panel — same character as button face but with quieter
	## detail (rivets only at the corners) and a slightly darker base
	## so a foreground button reads on top of it.
	var img := Image.create(_PANEL_SIZE, _PANEL_SIZE, false, Image.FORMAT_RGBA8)
	var hammer := FastNoiseLite.new()
	hammer.seed = 419
	hammer.frequency = 0.022
	hammer.fractal_octaves = 3
	var grit := FastNoiseLite.new()
	grit.seed = 157
	grit.frequency = 0.30
	for y: int in _PANEL_SIZE:
		for x: int in _PANEL_SIZE:
			var hv: float = hammer.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var gv: float = grit.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var base_mul: float = lerp(0.72, 1.05, hv)
			base_mul += (gv - 0.5) * 0.07
			var c: Color = _ANVIL_BASE_DARK * base_mul
			c.a = 1.0
			img.set_pixel(x, y, c)
	# Edge bevel.
	for i: int in _PANEL_SIZE:
		_blend_pixel(img, i, 0, _ANVIL_HIGHLIGHT, 0.50)
		_blend_pixel(img, 0, i, _ANVIL_HIGHLIGHT, 0.50)
		_blend_pixel(img, i, _PANEL_SIZE - 1, _ANVIL_RIVET_SHADOW, 0.55)
		_blend_pixel(img, _PANEL_SIZE - 1, i, _ANVIL_RIVET_SHADOW, 0.55)
	# Corner rivets only.
	var inset: int = 14
	_draw_rivet(img, inset, inset)
	_draw_rivet(img, _PANEL_SIZE - inset, inset)
	_draw_rivet(img, inset, _PANEL_SIZE - inset)
	_draw_rivet(img, _PANEL_SIZE - inset, _PANEL_SIZE - inset)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_anvil_top_bar() -> Texture2D:
	## Industrial top bar -- darker steel base + a hazard caution
	## stripe along the bottom edge (yellow / black diagonal blocks)
	## so the resource readout sits on a clearly Anvil banner.
	var img := Image.create(_TOP_BAR_W, _TOP_BAR_H, false, Image.FORMAT_RGBA8)
	var hammer := FastNoiseLite.new()
	hammer.seed = 521
	hammer.frequency = 0.018
	hammer.fractal_octaves = 2
	var grit := FastNoiseLite.new()
	grit.seed = 89
	grit.frequency = 0.28
	for y: int in _TOP_BAR_H:
		for x: int in _TOP_BAR_W:
			var hv: float = hammer.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var gv: float = grit.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var base_mul: float = lerp(0.74, 1.05, hv)
			base_mul += (gv - 0.5) * 0.06
			var c: Color = _ANVIL_BASE_DARK * base_mul
			c.a = 1.0
			img.set_pixel(x, y, c)
	# Caution stripe — bottom 8px = yellow/black diagonal blocks.
	# Stripe slope: 1 black + 1 yellow each "stripe_period" pixels.
	var stripe_period: int = 24
	var stripe_top: int = _TOP_BAR_H - 8
	for y: int in range(stripe_top, _TOP_BAR_H):
		for x: int in _TOP_BAR_W:
			# Diagonal index — y offsets x so the stripe slants.
			var s: int = ((x + y) % stripe_period)
			var on_yellow: bool = s < stripe_period / 2
			var c: Color = _ANVIL_CAUTION_YELLOW if on_yellow else _ANVIL_CAUTION_BLACK
			img.set_pixel(x, y, c)
	# Top-edge bevel highlight.
	for x: int in _TOP_BAR_W:
		_blend_pixel(img, x, 0, _ANVIL_HIGHLIGHT, 0.55)
		_blend_pixel(img, x, 1, _ANVIL_HIGHLIGHT, 0.25)
	# Rivets along the top bar's bottom-stripe boundary.
	for i: int in range(0, _TOP_BAR_W, 64):
		_draw_rivet(img, i + 32, stripe_top - 4)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_anvil_frame_corner() -> Texture2D:
	## Small ornament rendered at panel corners. Anvil = a cluster
	## of three rivets on a darker plate patch, framed with a
	## bracket of brass highlights. Designed to be drawn at the
	## TOP-LEFT corner; rotate / flip for the other three.
	var img := Image.create(_FRAME_CORNER, _FRAME_CORNER, false, Image.FORMAT_RGBA8)
	# Transparent background -- the corner ornament is a sticker on
	# top of whatever panel face is underneath.
	for y: int in _FRAME_CORNER:
		for x: int in _FRAME_CORNER:
			img.set_pixel(x, y, Color(0, 0, 0, 0))
	# Brass bracket lines — short L pointing into the corner.
	# Two-pixel-thick top + left bars, ending at half-size.
	var bracket_len: int = _FRAME_CORNER / 2
	for i: int in bracket_len:
		_blend_pixel(img, i, 0, _ANVIL_HIGHLIGHT, 0.95)
		_blend_pixel(img, i, 1, _ANVIL_HIGHLIGHT, 0.55)
		_blend_pixel(img, 0, i, _ANVIL_HIGHLIGHT, 0.95)
		_blend_pixel(img, 1, i, _ANVIL_HIGHLIGHT, 0.55)
	# Three rivets in a triangle inside the bracket.
	_draw_rivet(img, 8, 8)
	_draw_rivet(img, 22, 10)
	_draw_rivet(img, 10, 22)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- Sable

static func _build_sable_button_face() -> Texture2D:
	## Sleek dark base + faint hex grid + horizontal scanlines.
	## Stays low-noise so violet emissive trim painted via styleboxes
	## reads as the main accent.
	var img := Image.create(_BUTTON_SIZE, _BUTTON_SIZE, false, Image.FORMAT_RGBA8)
	# Base fill with a faint vertical gradient so the button has a
	# subtle "lit from above" feel.
	for y: int in _BUTTON_SIZE:
		var t: float = float(y) / float(_BUTTON_SIZE - 1)
		var row_color: Color = _SABLE_BASE.lerp(_SABLE_BASE_DARK, t * 0.7)
		for x: int in _BUTTON_SIZE:
			img.set_pixel(x, y, row_color)
	# Hex grid — paint hex outlines via point-in-hexagon test.
	# Hex side length 12px; grid uses pointy-top orientation.
	_paint_hex_grid(img, 12.0, _SABLE_HEX_TINT, 0.42)
	# Horizontal scanlines — every other row darkened slightly.
	for y: int in range(0, _BUTTON_SIZE, 2):
		for x: int in _BUTTON_SIZE:
			_blend_pixel(img, x, y, _SABLE_SCAN_DARK, 0.18)
	# Edge trim — top + left = thin emissive violet line; bottom +
	# right = darker recess. Reads as a chamfered metal panel.
	for i: int in _BUTTON_SIZE:
		_blend_pixel(img, i, 0, _SABLE_VIOLET, 0.70)
		_blend_pixel(img, 0, i, _SABLE_VIOLET, 0.70)
		_blend_pixel(img, i, _BUTTON_SIZE - 1, _SABLE_BASE_DARK, 0.85)
		_blend_pixel(img, _BUTTON_SIZE - 1, i, _SABLE_BASE_DARK, 0.85)
	# Diagonal corner cuts — paint a 6×6 dark triangle into each
	# corner so the button reads as chamfered.
	_cut_corner(img, 0, 0, 6, _SABLE_BASE_DARK, true, true)
	_cut_corner(img, _BUTTON_SIZE - 1, 0, 6, _SABLE_BASE_DARK, false, true)
	_cut_corner(img, 0, _BUTTON_SIZE - 1, 6, _SABLE_BASE_DARK, true, false)
	_cut_corner(img, _BUTTON_SIZE - 1, _BUTTON_SIZE - 1, 6, _SABLE_BASE_DARK, false, false)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_sable_panel_face() -> Texture2D:
	## Larger sable panel — quieter scanlines, slightly larger hex
	## grid, no chamfered corners (panel chrome handles those).
	var img := Image.create(_PANEL_SIZE, _PANEL_SIZE, false, Image.FORMAT_RGBA8)
	for y: int in _PANEL_SIZE:
		var t: float = float(y) / float(_PANEL_SIZE - 1)
		var row_color: Color = _SABLE_BASE.lerp(_SABLE_BASE_DARK, t * 0.5)
		for x: int in _PANEL_SIZE:
			img.set_pixel(x, y, row_color)
	_paint_hex_grid(img, 18.0, _SABLE_HEX_TINT, 0.35)
	for y: int in range(0, _PANEL_SIZE, 3):
		for x: int in _PANEL_SIZE:
			_blend_pixel(img, x, y, _SABLE_SCAN_DARK, 0.10)
	# Outer trim.
	for i: int in _PANEL_SIZE:
		_blend_pixel(img, i, 0, _SABLE_VIOLET_DIM, 0.75)
		_blend_pixel(img, 0, i, _SABLE_VIOLET_DIM, 0.75)
		_blend_pixel(img, i, _PANEL_SIZE - 1, _SABLE_BASE_DARK, 0.85)
		_blend_pixel(img, _PANEL_SIZE - 1, i, _SABLE_BASE_DARK, 0.85)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_sable_top_bar() -> Texture2D:
	## Sable resource banner — dark base + violet trim along
	## the bottom edge + faint horizontal scanlines + a thin
	## emissive line at the very bottom for the "active HUD"
	## glow.
	var img := Image.create(_TOP_BAR_W, _TOP_BAR_H, false, Image.FORMAT_RGBA8)
	for y: int in _TOP_BAR_H:
		var t: float = float(y) / float(_TOP_BAR_H - 1)
		var row_color: Color = _SABLE_BASE.lerp(_SABLE_BASE_DARK, t * 0.6)
		for x: int in _TOP_BAR_W:
			img.set_pixel(x, y, row_color)
	_paint_hex_grid(img, 16.0, _SABLE_HEX_TINT, 0.30)
	for y: int in range(0, _TOP_BAR_H, 3):
		for x: int in _TOP_BAR_W:
			_blend_pixel(img, x, y, _SABLE_SCAN_DARK, 0.12)
	# Violet trim line along the bottom 2px (emissive HUD glow).
	for x: int in _TOP_BAR_W:
		_blend_pixel(img, x, _TOP_BAR_H - 1, _SABLE_VIOLET, 0.95)
		_blend_pixel(img, x, _TOP_BAR_H - 2, _SABLE_VIOLET, 0.55)
	# Top edge highlight.
	for x: int in _TOP_BAR_W:
		_blend_pixel(img, x, 0, _SABLE_VIOLET_DIM, 0.55)
		_blend_pixel(img, x, 1, _SABLE_VIOLET_DIM, 0.20)
	# Diagonal slash markers every 96px — subtle violet ticks
	# for the corp readout aesthetic.
	for cx: int in range(0, _TOP_BAR_W, 96):
		for d: int in 8:
			_blend_pixel(img, cx + d, _TOP_BAR_H - 12 + d, _SABLE_VIOLET, 0.45)
			_blend_pixel(img, cx + d + 1, _TOP_BAR_H - 12 + d, _SABLE_VIOLET, 0.20)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_sable_frame_corner() -> Texture2D:
	## Sable corner ornament -- a sharp L-shaped HUD bracket plus
	## one diagonal slash, in violet emissive. Drawn for the TOP-
	## LEFT corner; rotate copies for the others.
	var img := Image.create(_FRAME_CORNER, _FRAME_CORNER, false, Image.FORMAT_RGBA8)
	for y: int in _FRAME_CORNER:
		for x: int in _FRAME_CORNER:
			img.set_pixel(x, y, Color(0, 0, 0, 0))
	# L bracket — 2px thick, inset 2px from the edge so it reads as
	# a UI marker rather than the panel border itself.
	var bracket_len: int = _FRAME_CORNER * 3 / 5
	var inset: int = 3
	for i: int in bracket_len:
		_blend_pixel(img, inset + i, inset, _SABLE_VIOLET, 0.95)
		_blend_pixel(img, inset + i, inset + 1, _SABLE_VIOLET, 0.55)
		_blend_pixel(img, inset, inset + i, _SABLE_VIOLET, 0.95)
		_blend_pixel(img, inset + 1, inset + i, _SABLE_VIOLET, 0.55)
	# Diagonal accent — short slash at the inner end.
	for d: int in 8:
		_blend_pixel(img, bracket_len + d, bracket_len + d, _SABLE_VIOLET, 0.65)
		_blend_pixel(img, bracket_len + d + 1, bracket_len + d, _SABLE_VIOLET, 0.25)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- helpers

static func _draw_rivet(img: Image, cx: int, cy: int) -> void:
	## Paints a small domed rivet head at (cx, cy). Radius 3 with a
	## one-pixel highlight on the top-left and shadow on the bottom-
	## right so the bolt reads as raised rather than flat.
	var w: int = img.get_width()
	var h: int = img.get_height()
	for dy: int in range(-3, 4):
		for dx: int in range(-3, 4):
			var dist_sq: int = dx * dx + dy * dy
			if dist_sq > 9:
				continue
			var px: int = cx + dx
			var py: int = cy + dy
			if px < 0 or py < 0 or px >= w or py >= h:
				continue
			var c: Color = _ANVIL_RIVET
			# Edge of the rivet darkened.
			if dist_sq > 5:
				c = _ANVIL_RIVET_SHADOW.lerp(_ANVIL_RIVET, 0.35)
			# Top-left highlight pixel.
			elif dx <= -1 and dy <= -1:
				c = _ANVIL_RIVET.lerp(Color.WHITE, 0.30)
			img.set_pixel(px, py, c)


static func _blend_pixel(img: Image, x: int, y: int, c: Color, t: float) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	var existing: Color = img.get_pixel(x, y)
	img.set_pixel(x, y, existing.lerp(c, clampf(t, 0.0, 1.0)))


static func _paint_hex_grid(img: Image, side: float, tint: Color, alpha: float) -> void:
	## Draws thin hex outlines (1-pixel) over the image. Pointy-top
	## orientation. Uses a coarse "is this pixel on the boundary
	## between two hexes?" test by sampling axial coordinates.
	var w: int = img.get_width()
	var h: int = img.get_height()
	var sqrt3: float = sqrt(3.0)
	# Conversion from pixel (x,y) to axial (q,r) for pointy-top hex
	# of side `side`. We only need the fractional cell distance to
	# detect outline pixels.
	for y: int in h:
		for x: int in w:
			var fx: float = float(x)
			var fy: float = float(y)
			var q: float = (sqrt3 / 3.0 * fx - 1.0 / 3.0 * fy) / side
			var r: float = (2.0 / 3.0 * fy) / side
			var s: float = -q - r
			# Distance from the nearest cell boundary -- min of
			# fractional-component distances on each axis.
			var qf: float = q - round(q)
			var rf: float = r - round(r)
			var sf: float = s - round(s)
			var d: float = min(min(absf(qf), absf(rf)), absf(sf))
			if d < 0.06:
				_blend_pixel(img, x, y, tint, alpha)


static func _cut_corner(img: Image, cx: int, cy: int, size: int, fill: Color, _x_neg: bool, _y_neg: bool) -> void:
	## Paints a small triangular dark cut into the corner so the
	## button silhouette reads as chamfered.
	for dy: int in size:
		for dx: int in size - dy:
			var px: int = cx + (dx if cx == 0 else -dx)
			var py: int = cy + (dy if cy == 0 else -dy)
			_blend_pixel(img, px, py, fill, 0.95)
