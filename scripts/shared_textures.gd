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
static var _scorched_ground_tex: Texture2D = null
static var _sand_dunes_tex: Texture2D = null
static var _cracked_mud_tex: Texture2D = null
static var _packed_snow_tex: Texture2D = null


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


static func get_scorched_ground_texture() -> Texture2D:
	## Charred-ground texture for wreck / crash-site debris pads.
	## Mostly-dark base with low-frequency soot variation, sharp
	## thin crack lines from a high-frequency ridge noise, and
	## occasional brighter ember speckle so the patch reads as
	## 'burnt + cracked' instead of a flat painted disc.
	if _scorched_ground_tex:
		return _scorched_ground_tex
	var img := Image.create(_TEX_SIZE, _TEX_SIZE, false, Image.FORMAT_RGBA8)
	# Soot — broad value variation, biased dark.
	var soot := FastNoiseLite.new()
	soot.seed = 419
	soot.frequency = 0.018
	soot.fractal_octaves = 4
	# Cracks — ridge / cellular noise gives sharp dark veins
	# rather than smooth blobs.
	var cracks := FastNoiseLite.new()
	cracks.seed = 853
	cracks.noise_type = FastNoiseLite.TYPE_CELLULAR
	cracks.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	cracks.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_DIV
	cracks.frequency = 0.060
	# Embers — high-frequency speckle, biased very bright + sparse
	# so only a handful of pixels per patch glow.
	var ember := FastNoiseLite.new()
	ember.seed = 71
	ember.frequency = 0.34
	for y: int in _TEX_SIZE:
		for x: int in _TEX_SIZE:
			var s_val: float = soot.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var c_val: float = cracks.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			# Base value: dark (0.18..0.55) modulated by soot.
			var v: float = lerp(0.20, 0.55, s_val)
			# Crack veins darken the base sharply where c_val is low.
			if c_val < 0.18:
				v *= lerp(0.25, 0.55, c_val / 0.18)
			# Mild colour bias toward warm brown so the texture
			# reads as scorched soil rather than dead grey.
			var r: float = clampf(v * 1.05, 0.0, 1.0)
			var g: float = clampf(v * 0.92, 0.0, 1.0)
			var b: float = clampf(v * 0.78, 0.0, 1.0)
			# Occasional bright ember pixel (sparse threshold).
			var e_val: float = ember.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			if e_val > 0.92 and v < 0.40:
				r = lerp(r, 1.0, 0.7)
				g = lerp(g, 0.55, 0.5)
				b = lerp(b, 0.18, 0.5)
			img.set_pixel(x, y, Color(r, g, b, 1.0))
	img.generate_mipmaps()
	_scorched_ground_tex = ImageTexture.create_from_image(img)
	return _scorched_ground_tex



static func get_sand_dunes_texture() -> Texture2D:
	## Granular sand-drift surface. Two octaves of low-frequency
	## bands form the dune-line ridges; high-frequency speckle adds
	## the grain. Sampled by warm-tan biome patches so they read as
	## actual sand instead of a flat ochre tint.
	if _sand_dunes_tex:
		return _sand_dunes_tex
	var img := Image.create(_TEX_SIZE, _TEX_SIZE, false, Image.FORMAT_RGBA8)
	var bands := FastNoiseLite.new()
	bands.seed = 211
	bands.frequency = 0.012
	bands.fractal_octaves = 2
	var grain := FastNoiseLite.new()
	grain.seed = 47
	grain.frequency = 0.18
	for y: int in _TEX_SIZE:
		for x: int in _TEX_SIZE:
			var bv: float = bands.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var gv: float = grain.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var v: float = lerp(0.62, 1.05, bv)
			v += (gv - 0.5) * 0.18  # speckled grain
			v = clampf(v, 0.40, 1.10)
			img.set_pixel(x, y, Color(v, v * 0.95, v * 0.86, 1.0))
	img.generate_mipmaps()
	_sand_dunes_tex = ImageTexture.create_from_image(img)
	return _sand_dunes_tex


static func get_cracked_mud_texture() -> Texture2D:
	## Dried-mud pattern: cellular noise gives the polygonal crack
	## network; a low-frequency value layer adds plate-by-plate
	## brightness variation so the cracked surface doesn't read as a
	## uniform texture.
	if _cracked_mud_tex:
		return _cracked_mud_tex
	var img := Image.create(_TEX_SIZE, _TEX_SIZE, false, Image.FORMAT_RGBA8)
	var cells := FastNoiseLite.new()
	cells.seed = 613
	cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	cells.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_DIV
	cells.frequency = 0.040
	var plates := FastNoiseLite.new()
	plates.seed = 89
	plates.frequency = 0.025
	for y: int in _TEX_SIZE:
		for x: int in _TEX_SIZE:
			var c: float = cells.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var p: float = plates.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var v: float = lerp(0.62, 0.95, p)
			if c < 0.16:
				v *= lerp(0.30, 0.70, c / 0.16)  # dark crack veins
			img.set_pixel(x, y, Color(v, v * 0.92, v * 0.80, 1.0))
	img.generate_mipmaps()
	_cracked_mud_tex = ImageTexture.create_from_image(img)
	return _cracked_mud_tex


static func get_packed_snow_texture() -> Texture2D:
	## Trampled snowpack: high-frequency speckle for the granular
	## ice crystal feel + a sparse darker spotting from boot prints
	## / rut tracks. Stays close to white so callers can tint it
	## subtly without losing the snow read.
	if _packed_snow_tex:
		return _packed_snow_tex
	var img := Image.create(_TEX_SIZE, _TEX_SIZE, false, Image.FORMAT_RGBA8)
	var grain := FastNoiseLite.new()
	grain.seed = 743
	grain.frequency = 0.40
	var prints := FastNoiseLite.new()
	prints.seed = 113
	prints.frequency = 0.07
	for y: int in _TEX_SIZE:
		for x: int in _TEX_SIZE:
			var g: float = grain.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var pr: float = prints.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var v: float = lerp(0.85, 1.0, g)
			if pr < 0.35:
				v *= lerp(0.65, 0.92, pr / 0.35)  # boot / rut prints
			img.set_pixel(x, y, Color(v, v, v * 1.02, 1.0))
	img.generate_mipmaps()
	_packed_snow_tex = ImageTexture.create_from_image(img)
	return _packed_snow_tex
