extends Control
## Animated tactical-radar backdrop used by the main menu. Real-radar
## conventions: concentric range rings centered on the sweep pivot,
## bearing tick marks every 15° (cardinal labels at N/E/S/W), a
## directional sweep wedge that fades from a bright leading edge to
## a phosphor-trailing dim wash, and pips that flash bright the
## moment the sweep passes over them and then decay back.
##
## Pip + contour layouts roll once on _ready so the backdrop reads
## as a real terrain plot rather than a churning particle field. A
## handful of pips drift along bearings to sell the "live tactical
## picture" feel without adding much paint cost.

var _t: float = 0.0
var _pips: Array = []
var _contours: Array = []
## Cached oval-ring polylines per (center, rx, ry) tuple. The
## radar's nested elevation contours never move, so building the
## 36-vertex polylines once at _ready and reusing the
## PackedVector2Array each draw avoids the 19k+ allocations the
## profiler saw across a 65s session.
var _cached_contour_polys: Array = []
## Cached range-ring polylines indexed by ring index (0..N-1) so
## _draw doesn't rebuild them each frame.
var _cached_range_rings: Array = []
## Cached size we built _cached_contour_polys + _cached_range_rings
## against. When the control resizes (rare in the menu but possible
## on viewport change) we rebuild.
var _cache_size: Vector2 = Vector2.ZERO
## When the sweep most recently passed over each pip's bearing.
## Drives the per-pip brightness flash + phosphor decay so the pip
## reads as an active radar return.
var _pip_last_hit: Array = []

const COLOR_BG_DEEP := Color(0.02, 0.06, 0.05, 1.0)  # CRT phosphor depth
const COLOR_GRID := Color(0.15, 0.30, 0.32, 0.30)
const COLOR_GRID_MAJOR := Color(0.20, 0.45, 0.45, 0.45)
const COLOR_RING := Color(0.25, 0.55, 0.45, 0.55)
const COLOR_RING_FAINT := Color(0.18, 0.40, 0.35, 0.30)
const COLOR_BEARING := Color(0.30, 0.60, 0.45, 0.50)
const COLOR_BEARING_LABEL := Color(0.65, 0.95, 0.75, 0.75)
const COLOR_CONTOUR := Color(0.18, 0.28, 0.22, 0.55)
const COLOR_PIP_FRIEND := Color(0.45, 0.95, 0.55, 1.0)
const COLOR_PIP_FOE := Color(0.95, 0.40, 0.32, 1.0)
const COLOR_PIP_NEUTRAL := Color(0.92, 0.80, 0.40, 1.0)
const COLOR_SWEEP_LEAD := Color(0.55, 1.00, 0.65, 0.55)
const COLOR_SWEEP_TRAIL := Color(0.30, 0.85, 0.45, 0.06)
const COLOR_SWEEP_EDGE := Color(0.65, 1.00, 0.70, 0.85)
const COLOR_VIGNETTE := Color(0.0, 0.0, 0.0, 0.55)
const COLOR_SCANLINE := Color(0.05, 0.20, 0.10, 0.07)

const SWEEP_PERIOD_SEC: float = 6.0  # one full revolution
const PIP_FLASH_DURATION_SEC: float = 1.6  # afterglow per radar return
const NUM_RANGE_RINGS: int = 5


func _ready() -> void:
	set_process(true)
	_seed_layout()


func _seed_layout() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xD0551E
	# 18 radar contacts spread across the plot. Drift vector is
	# small so they meander rather than streaking. Most are static
	# (drift = 0); a handful drift along set bearings to sell the
	# 'live tactical picture'.
	var pip_count: int = 18
	for i: int in pip_count:
		var c: int = rng.randi_range(0, 2)  # 0 friend, 1 foe, 2 neutral
		var drifts: bool = rng.randf() < 0.35
		var heading: float = rng.randf() * TAU
		var speed: float = rng.randf_range(0.005, 0.018) if drifts else 0.0
		_pips.append({
			"x": rng.randf(),
			"y": rng.randf(),
			"kind": c,
			"size": rng.randf_range(2.5, 4.5),
			"phase": rng.randf() * TAU,
			"drift": Vector2(cos(heading), sin(heading)) * speed,
			"id": i,
		})
		_pip_last_hit.append(-PIP_FLASH_DURATION_SEC)
	# Terrain-elevation contour rings -- a few faint nested ovals so
	# the plot has shape under the radar layer.
	for i: int in 7:
		_contours.append({
			"x": rng.randf(),
			"y": rng.randf(),
			"r": rng.randf_range(0.10, 0.22),
			"squash": rng.randf_range(0.5, 1.2),
		})


func _process(delta: float) -> void:
	_t += delta
	# Per-pip drift + bearing-pass detection. When the sweep angle
	# crosses a pip's bearing relative to the radar pivot, stamp the
	# current time so _draw can render the flash + decay.
	var pivot_norm := Vector2(0.5, 0.5)
	var prev_sweep: float = _sweep_angle_at(_t - delta)
	var cur_sweep: float = _sweep_angle_at(_t)
	for i: int in _pips.size():
		var p: Dictionary = _pips[i]
		var drift: Vector2 = p.get("drift", Vector2.ZERO) as Vector2
		if drift.length_squared() > 0.0:
			var nx: float = (p["x"] as float) + drift.x * delta
			var ny: float = (p["y"] as float) + drift.y * delta
			# Wrap-around so drifting pips don't fall off the screen.
			p["x"] = fposmod(nx, 1.0)
			p["y"] = fposmod(ny, 1.0)
		var rel := Vector2((p["x"] as float) - pivot_norm.x, (p["y"] as float) - pivot_norm.y)
		var bearing: float = atan2(rel.y, rel.x)
		if _angle_passed(prev_sweep, cur_sweep, bearing):
			_pip_last_hit[i] = _t
	queue_redraw()


func _sweep_angle_at(t: float) -> float:
	## Linearly increasing sweep angle, wrapped to [-PI, PI]. Period
	## = SWEEP_PERIOD_SEC.
	return wrapf(t * (TAU / SWEEP_PERIOD_SEC), -PI, PI)


func _angle_passed(prev: float, cur: float, target: float) -> bool:
	## Returns true when the sweep crossed `target` between prev and
	## cur. Handles the -PI / +PI seam by treating the sweep as
	## monotonically advancing.
	# Normalize all three to [0, TAU) so comparison is straightforward.
	var p: float = fposmod(prev, TAU)
	var c: float = fposmod(cur, TAU)
	var tgt: float = fposmod(target, TAU)
	if p <= c:
		return tgt > p and tgt <= c
	# Wrapped past 0 -- crossed the seam.
	return tgt > p or tgt <= c


func _draw() -> void:
	var sz: Vector2 = size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return

	# CRT phosphor backdrop -- darker than the menu black so the
	# radar arc has something to glow against without crushing the
	# UI text on top.
	draw_rect(Rect2(Vector2.ZERO, sz), COLOR_BG_DEEP)

	# Rebuild the cached polylines whenever the control's size
	# changes (rare but possible on viewport change).
	if sz != _cache_size:
		_rebuild_geometry_cache(sz)

	# Faint nested elevation contours under everything else.
	# Polylines pre-built; we just emit them with their cached colour
	# triplets via draw_polyline.
	for entry: Dictionary in _cached_contour_polys:
		draw_polyline(entry["pts"] as PackedVector2Array, entry["col"] as Color, entry["w"] as float)

	# Light grid -- two pitches so the major lines read as a
	# coordinate grid + the minor lines as the in-between detail.
	var grid_pitch: float = 38.0
	var x: float = fmod(sz.x, grid_pitch) * 0.5
	while x < sz.x:
		var col: Color = COLOR_GRID_MAJOR if int(x / grid_pitch) % 4 == 0 else COLOR_GRID
		draw_line(Vector2(x, 0), Vector2(x, sz.y), col, 1.0)
		x += grid_pitch
	var y: float = fmod(sz.y, grid_pitch) * 0.5
	while y < sz.y:
		var col2: Color = COLOR_GRID_MAJOR if int(y / grid_pitch) % 4 == 0 else COLOR_GRID
		draw_line(Vector2(0, y), Vector2(sz.x, y), col2, 1.0)
		y += grid_pitch

	# --- Radar plot ---
	var pivot: Vector2 = sz * 0.5
	var max_radius: float = minf(sz.x, sz.y) * 0.46
	# Concentric range rings -- pre-built in _rebuild_geometry_cache.
	for entry: Dictionary in _cached_range_rings:
		draw_polyline(entry["pts"] as PackedVector2Array, entry["col"] as Color, entry["w"] as float)

	# Bearing tick marks every 15°; cardinal directions (N/E/S/W)
	# get a label glyph in the menu's brass-green palette.
	var bearing_step: float = deg_to_rad(15.0)
	var ang: float = -PI
	while ang < PI:
		var dir := Vector2(cos(ang), sin(ang))
		var inner: float = max_radius * 0.96
		var outer: float = max_radius
		var len: float = 0.5  # short tick by default
		# Cardinal + 45° = longer tick.
		var deg: int = int(round(rad_to_deg(ang)))
		if deg == 0 or deg == 90 or deg == -90 or deg == 180 or deg == -180 or absi(deg) == 45 or absi(deg) == 135:
			len = 1.0
		var t_inner: Vector2 = pivot + dir * inner * (1.0 - 0.05 * len)
		var t_outer: Vector2 = pivot + dir * outer
		draw_line(t_inner, t_outer, COLOR_BEARING, 1.5 if len > 0.5 else 1.0)
		ang += bearing_step
	# Cardinal labels. Drawn slightly outside the outer ring so they
	# don't overlap the sweep wedge.
	for entry: Dictionary in [
		{"label": "N", "ang": -PI * 0.5},
		{"label": "E", "ang":  0.0},
		{"label": "S", "ang":  PI * 0.5},
		{"label": "W", "ang":  PI},
	]:
		var dir := Vector2(cos(entry["ang"] as float), sin(entry["ang"] as float))
		var p: Vector2 = pivot + dir * (max_radius + 14.0)
		var font: Font = ThemeDB.fallback_font
		var fsize: int = 16
		var text: String = entry["label"] as String
		var ts: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, fsize)
		draw_string(font, p - ts * 0.5 + Vector2(0.0, ts.y * 0.35), text,
			HORIZONTAL_ALIGNMENT_CENTER, -1.0, fsize, COLOR_BEARING_LABEL)

	# Cross-hair through the pivot -- helps the eye lock on the
	# sweep origin.
	draw_line(pivot - Vector2(max_radius + 8.0, 0.0), pivot + Vector2(max_radius + 8.0, 0.0), COLOR_BEARING, 1.0)
	draw_line(pivot - Vector2(0.0, max_radius + 8.0), pivot + Vector2(0.0, max_radius + 8.0), COLOR_BEARING, 1.0)

	# Sweep wedge -- bright leading edge (the radar antenna tip)
	# fading to phosphor-trailing wash. Built as a fan of triangles
	# with per-vertex color so the trailing wash falls off smoothly.
	var sweep_angle: float = _sweep_angle_at(_t)
	var arc_width: float = deg_to_rad(60.0)
	# Trailing wash: from the trailing edge to the leading edge,
	# colour interpolates dim -> bright.
	var fan_pts := PackedVector2Array()
	var fan_cols := PackedColorArray()
	fan_pts.append(pivot)
	fan_cols.append(Color(COLOR_SWEEP_LEAD.r, COLOR_SWEEP_LEAD.g, COLOR_SWEEP_LEAD.b, 0.10))
	var steps: int = 32
	for i: int in steps + 1:
		var t01: float = float(i) / float(steps)
		var a: float = sweep_angle - arc_width + arc_width * t01
		fan_pts.append(pivot + Vector2(cos(a), sin(a)) * max_radius)
		# Brightness ramps from dim at the trailing edge (t01=0) to
		# bright at the leading edge (t01=1).
		var alpha: float = lerp(COLOR_SWEEP_TRAIL.a, COLOR_SWEEP_LEAD.a, t01)
		fan_cols.append(Color(COLOR_SWEEP_LEAD.r, COLOR_SWEEP_LEAD.g, COLOR_SWEEP_LEAD.b, alpha))
	draw_polygon(fan_pts, fan_cols)
	# Bright leading line -- the antenna's current bearing.
	var lead_dir := Vector2(cos(sweep_angle), sin(sweep_angle))
	draw_line(pivot, pivot + lead_dir * max_radius, COLOR_SWEEP_EDGE, 2.2)

	# --- Pips ---
	# Pip flash decays linearly over PIP_FLASH_DURATION_SEC. A
	# freshly-hit pip is at full brightness; a stale one falls back
	# to a baseline glow.
	for i: int in _pips.size():
		var p2: Dictionary = _pips[i]
		var pos := Vector2((p2["x"] as float) * sz.x, (p2["y"] as float) * sz.y)
		var sval: float = p2["size"] as float
		var col: Color
		match int(p2["kind"]):
			0: col = COLOR_PIP_FRIEND
			1: col = COLOR_PIP_FOE
			_: col = COLOR_PIP_NEUTRAL
		var age: float = _t - (_pip_last_hit[i] as float)
		var flash: float = clampf(1.0 - age / PIP_FLASH_DURATION_SEC, 0.0, 1.0)
		# Baseline pulse so even un-hit pips throb subtly.
		var pulse: float = 0.30 + 0.10 * sin(_t * 1.6 + (p2["phase"] as float))
		var brightness: float = clampf(pulse + flash * 0.85, 0.0, 1.0)
		var c2: Color = col
		c2.a = brightness
		# Outer halo -- bigger and dimmer; pulses with the flash so a
		# fresh hit visibly glows out.
		var halo_radius: float = sval + 2.5 + flash * 4.0
		draw_circle(pos, halo_radius, Color(c2.r, c2.g, c2.b, brightness * 0.30))
		draw_circle(pos, sval, c2)
		# Tiny crosshair on flashed pips -- locks the eye onto a fresh
		# return.
		if flash > 0.5:
			var ch: float = sval + 5.0
			draw_line(pos + Vector2(-ch, 0.0), pos + Vector2(ch, 0.0), Color(c2.r, c2.g, c2.b, flash * 0.5), 1.0)
			draw_line(pos + Vector2(0.0, -ch), pos + Vector2(0.0, ch), Color(c2.r, c2.g, c2.b, flash * 0.5), 1.0)

	# Subtle horizontal CRT scanlines on top of everything -- every
	# 3 px, very low alpha. Sells the phosphor-screen feel without
	# making the menu hard to read.
	var scan_y: float = 0.0
	while scan_y < sz.y:
		draw_line(Vector2(0.0, scan_y), Vector2(sz.x, scan_y), COLOR_SCANLINE, 1.0)
		scan_y += 3.0

	# Vignettes top + bottom so menu copy stays readable.
	draw_rect(Rect2(Vector2.ZERO, Vector2(sz.x, 36)), COLOR_VIGNETTE)
	draw_rect(Rect2(Vector2(0, sz.y - 36), Vector2(sz.x, 36)), COLOR_VIGNETTE)


func _draw_oval_ring(center: Vector2, rx: float, ry: float, col: Color, width: float) -> void:
	## Kept for any future caller that wants on-the-fly rings. The
	## hot _draw path uses _cached_contour_polys / _cached_range_rings
	## instead so it doesn't allocate per frame.
	var pts := _build_oval_pts(center, rx, ry, 36)
	draw_polyline(pts, col, width)


func _build_oval_pts(center: Vector2, rx: float, ry: float, steps: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(steps + 1)
	for i: int in steps + 1:
		var a: float = TAU * float(i) / float(steps)
		pts[i] = center + Vector2(cos(a) * rx, sin(a) * ry)
	return pts


func _rebuild_geometry_cache(sz: Vector2) -> void:
	## Pre-build every static polyline (contour ovals + radar range
	## rings) once at this size. Each entry stores the PackedVector2
	## points + colour + width so the _draw hot path is a flat
	## walk-and-emit with zero per-frame allocation.
	_cache_size = sz
	_cached_contour_polys.clear()
	for c: Dictionary in _contours:
		var center := Vector2((c["x"] as float) * sz.x, (c["y"] as float) * sz.y)
		var rx: float = (c["r"] as float) * sz.x
		var ry: float = rx * (c["squash"] as float)
		# Three nested rings per contour at decreasing radius +
		# alpha. Pre-baking the (radius * factor) calculation here
		# means draw doesn't have to do the math every frame.
		_cached_contour_polys.append({
			"pts": _build_oval_pts(center, rx, ry, 36),
			"col": COLOR_CONTOUR,
			"w": 1.4,
		})
		_cached_contour_polys.append({
			"pts": _build_oval_pts(center, rx * 0.78, ry * 0.78, 36),
			"col": COLOR_CONTOUR * Color(1, 1, 1, 0.7),
			"w": 1.0,
		})
		_cached_contour_polys.append({
			"pts": _build_oval_pts(center, rx * 0.55, ry * 0.55, 36),
			"col": COLOR_CONTOUR * Color(1, 1, 1, 0.5),
			"w": 0.8,
		})
	# Radar range rings -- centered, even alpha, alternating tone.
	_cached_range_rings.clear()
	var pivot: Vector2 = sz * 0.5
	var max_radius: float = minf(sz.x, sz.y) * 0.46
	for i: int in NUM_RANGE_RINGS:
		var r: float = max_radius * float(i + 1) / float(NUM_RANGE_RINGS)
		var ring_col: Color = COLOR_RING if (i % 2) == 0 else COLOR_RING_FAINT
		_cached_range_rings.append({
			"pts": _build_oval_pts(pivot, r, r, 48),
			"col": ring_col,
			"w": 1.4,
		})
