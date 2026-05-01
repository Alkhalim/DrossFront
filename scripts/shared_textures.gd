class_name SharedTextures
extends RefCounted
## Process-wide cache of small procedural textures used to break up the
## flat-shaded look of mech and building placeholder geometry.
##
## Each texture is generated once at first request (Image + ImageTexture),
## then handed back to every caller — sharing a single GPU upload across
## hundreds of materials. Resolution is intentionally modest (256²) so the
## one-shot fill loop stays under a few milliseconds.

const _TEX_SIZE: int = 256

static var _metal_wear_tex: Texture2D = null
static var _wall_panel_tex: Texture2D = null


static func get_metal_wear_texture() -> Texture2D:
	## Mostly-white texture with low-frequency dark streaks and high-
	## frequency speckle. Multiplied against `albedo_color` it adds a
	## subtle grime / wear pattern to flat metal surfaces without
	## dominating the underlying tint.
	if _metal_wear_tex:
		return _metal_wear_tex
	var img := Image.create(_TEX_SIZE, _TEX_SIZE, false, Image.FORMAT_RGBA8)
	# Two noise layers — broad streaks (panel-line / soot smears) layered
	# over a finer speckle (dirt / scratches). Both biased toward 1.0 so
	# the texture darkens rather than brightens the base color.
	var streak := FastNoiseLite.new()
	streak.seed = 211
	streak.frequency = 0.012
	streak.fractal_octaves = 4
	streak.fractal_lacunarity = 2.4
	var speckle := FastNoiseLite.new()
	speckle.seed = 67
	speckle.frequency = 0.18
	speckle.fractal_octaves = 2
	for y: int in _TEX_SIZE:
		for x: int in _TEX_SIZE:
			var s_val: float = streak.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var p_val: float = speckle.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			# Bias both noises toward bright; combine multiplicatively so
			# only locations that are dark in BOTH show real wear. Keeps
			# the average value close to 1.0 (subtle effect).
			var streak_w: float = lerp(0.78, 1.0, s_val)
			var speckle_w: float = lerp(0.88, 1.0, p_val)
			var v: float = clampf(streak_w * speckle_w, 0.0, 1.0)
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	img.generate_mipmaps()
	_metal_wear_tex = ImageTexture.create_from_image(img)
	return _metal_wear_tex


static func get_wall_panel_texture() -> Texture2D:
	## Concrete-slab wall texture — horizontal panel-joint lines every
	## quarter of the texture, vertical seams every half, with mild
	## low-frequency noise so the panels don't read as a perfect grid.
	## Used by ruin / building blocks so they read as structured masonry
	## clearly distinct from the organic rock surface texture.
	if _wall_panel_tex:
		return _wall_panel_tex
	var img := Image.create(_TEX_SIZE, _TEX_SIZE, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 137
	noise.frequency = 0.04
	noise.fractal_octaves = 2
	# 4 horizontal panels, 2 vertical slabs across the texture face. World-
	# space repetition is controlled by the caller's uv1_scale.
	var horiz_period: int = _TEX_SIZE / 4
	var vert_period: int = _TEX_SIZE / 2
	var joint_thickness: int = 2
	# Sub-joint mortar groove — a faint half-brightness inset alongside
	# the dark joint so the line reads as a recessed seam rather than a
	# painted stripe.
	var groove_thickness: int = 1
	for y: int in _TEX_SIZE:
		for x: int in _TEX_SIZE:
			var noise_val: float = noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var v: float = lerp(0.82, 1.0, noise_val)
			var h_off: int = y % horiz_period
			var v_off: int = x % vert_period
			var on_horiz: bool = h_off < joint_thickness
			var on_vert: bool = v_off < joint_thickness
			var near_horiz: bool = h_off >= joint_thickness and h_off < joint_thickness + groove_thickness
			var near_vert: bool = v_off >= joint_thickness and v_off < joint_thickness + groove_thickness
			if on_horiz or on_vert:
				v = 0.45  # darker joint
			elif near_horiz or near_vert:
				v = lerp(v, 0.7, 0.5)  # mortar groove halftone
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	img.generate_mipmaps()
	_wall_panel_tex = ImageTexture.create_from_image(img)
	return _wall_panel_tex
