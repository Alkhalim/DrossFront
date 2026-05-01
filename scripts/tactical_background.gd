extends Control
## Animated tactical-overview backdrop used by the main menu. Repaints
## every frame with a moving radar sweep. Pip and contour positions are
## rolled once on _ready so the backdrop reads as a real terrain layout
## rather than a churning particle field.

var _t: float = 0.0
var _pips: Array = []
var _contours: Array = []

const COLOR_GRID := Color(0.15, 0.30, 0.32, 0.30)
const COLOR_GRID_MAJOR := Color(0.20, 0.45, 0.45, 0.45)
const COLOR_CONTOUR := Color(0.18, 0.28, 0.22, 0.55)
const COLOR_PIP_FRIEND := Color(0.45, 0.85, 0.55, 0.80)
const COLOR_PIP_FOE := Color(0.92, 0.40, 0.32, 0.80)
const COLOR_PIP_NEUTRAL := Color(0.85, 0.75, 0.45, 0.75)
const COLOR_SWEEP := Color(0.45, 0.95, 0.55, 0.18)
const COLOR_SWEEP_EDGE := Color(0.60, 1.00, 0.65, 0.55)
const COLOR_VIGNETTE := Color(0.0, 0.0, 0.0, 0.55)


func _ready() -> void:
	set_process(true)
	_seed_layout()


func _seed_layout() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xD0551E
	for i: int in 14:
		var c: int = rng.randi_range(0, 2)  # 0 friend, 1 foe, 2 neutral
		_pips.append({
			"x": rng.randf(),
			"y": rng.randf(),
			"kind": c,
			"size": rng.randf_range(2.5, 4.5),
			"phase": rng.randf() * TAU,
		})
	for i: int in 7:
		_contours.append({
			"x": rng.randf(),
			"y": rng.randf(),
			"r": rng.randf_range(0.10, 0.22),
			"squash": rng.randf_range(0.5, 1.2),
		})


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var sz: Vector2 = size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return

	for c: Dictionary in _contours:
		var center := Vector2((c["x"] as float) * sz.x, (c["y"] as float) * sz.y)
		var rx: float = (c["r"] as float) * sz.x
		var ry: float = rx * (c["squash"] as float)
		_draw_oval_ring(center, rx, ry, COLOR_CONTOUR, 1.4)
		_draw_oval_ring(center, rx * 0.78, ry * 0.78, COLOR_CONTOUR * Color(1, 1, 1, 0.7), 1.0)
		_draw_oval_ring(center, rx * 0.55, ry * 0.55, COLOR_CONTOUR * Color(1, 1, 1, 0.5), 0.8)

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

	# Radar sweep — slow rotating wedge centered on the screen.
	var pivot: Vector2 = sz * 0.5
	var sweep_radius: float = sz.length() * 0.55
	var sweep_angle: float = fmod(_t * 0.35, TAU)
	var arc_width: float = deg_to_rad(38.0)
	var pts := PackedVector2Array()
	pts.append(pivot)
	var steps: int = 18
	for i: int in steps + 1:
		var a: float = sweep_angle - arc_width + (arc_width * float(i) / float(steps)) * 2.0
		pts.append(pivot + Vector2(cos(a), sin(a)) * sweep_radius)
	var fill_colors := PackedColorArray()
	for _i: int in pts.size():
		fill_colors.append(COLOR_SWEEP)
	draw_polygon(pts, fill_colors)
	var edge_a: Vector2 = pivot
	var edge_b: Vector2 = pivot + Vector2(cos(sweep_angle + arc_width), sin(sweep_angle + arc_width)) * sweep_radius
	draw_line(edge_a, edge_b, COLOR_SWEEP_EDGE, 2.0)

	for p: Dictionary in _pips:
		var pos := Vector2((p["x"] as float) * sz.x, (p["y"] as float) * sz.y)
		var s: float = p["size"] as float
		var col: Color
		match int(p["kind"]):
			0: col = COLOR_PIP_FRIEND
			1: col = COLOR_PIP_FOE
			_: col = COLOR_PIP_NEUTRAL
		var pulse: float = 0.7 + 0.3 * sin(_t * 1.6 + (p["phase"] as float))
		var c2: Color = col
		c2.a = clampf(col.a * pulse, 0.0, 1.0)
		draw_circle(pos, s + 1.5, Color(c2.r, c2.g, c2.b, c2.a * 0.35))
		draw_circle(pos, s, c2)

	# Soft vignette on top + bottom strips so menu copy stays readable.
	draw_rect(Rect2(Vector2.ZERO, Vector2(sz.x, 36)), COLOR_VIGNETTE)
	draw_rect(Rect2(Vector2(0, sz.y - 36), Vector2(sz.x, 36)), COLOR_VIGNETTE)


func _draw_oval_ring(center: Vector2, rx: float, ry: float, col: Color, width: float) -> void:
	var pts := PackedVector2Array()
	var steps: int = 36
	for i: int in steps + 1:
		var a: float = TAU * float(i) / float(steps)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_polyline(pts, col, width)
