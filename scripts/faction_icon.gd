class_name FactionIcon
extends Control
## Procedural faction logo, drawn directly in `_draw` so we don't need
## external image assets. Each faction gets a distinct silhouette:
##   - Anvil: chunky angular arrow on an iron-grey rivet plate (matches
##     the cursor). Reads as "industrial / soviet".
##   - Sable: faceted black diamond with a pale-cyan accent line.
##     Reads as "sleek corpo specops".
## Used by the match-setup screen to label faction-pick buttons; size
## defaults to 64×64 but can be scaled via custom_minimum_size.

enum Faction { ANVIL, SABLE }

@export var faction: Faction = Faction.ANVIL:
	set(value):
		faction = value
		queue_redraw()
@export var selected: bool = false:
	set(value):
		selected = value
		queue_redraw()


func _init() -> void:
	custom_minimum_size = Vector2(64, 64)


func _draw() -> void:
	var s: Vector2 = size
	var cx: float = s.x * 0.5
	var cy: float = s.y * 0.5
	var r: float = mini(int(s.x), int(s.y)) * 0.45
	# Background plate — different per faction.
	if faction == Faction.ANVIL:
		_draw_anvil_icon(cx, cy, r)
	else:
		_draw_sable_icon(cx, cy, r)
	# Selection ring — drawn on top, gold on Anvil / cyan on Sable.
	if selected:
		var ring_color: Color = Color(0.95, 0.78, 0.32, 1.0) if faction == Faction.ANVIL else Color(0.78, 0.35, 1.0, 1.0)
		draw_arc(Vector2(cx, cy), r + 4, 0.0, TAU, 48, ring_color, 2.5, true)


func _draw_anvil_icon(cx: float, cy: float, r: float) -> void:
	# --- Iron plate (octagonal) ---
	var plate: PackedVector2Array = []
	for i: int in 8:
		var a: float = float(i) / 8.0 * TAU + PI / 8.0
		plate.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	draw_colored_polygon(plate, Color(0.30, 0.27, 0.22, 1.0))
	# Bevel ring (slightly smaller darker octagon).
	var bevel: PackedVector2Array = []
	for i: int in 8:
		var a: float = float(i) / 8.0 * TAU + PI / 8.0
		bevel.append(Vector2(cx + cos(a) * (r * 0.84), cy + sin(a) * (r * 0.84)))
	draw_colored_polygon(bevel, Color(0.20, 0.18, 0.15, 1.0))
	# Outer plate outline.
	for i: int in 8:
		var p_a: Vector2 = plate[i]
		var p_b: Vector2 = plate[(i + 1) % 8]
		draw_line(p_a, p_b, Color(0.55, 0.46, 0.30, 1.0), 1.5)
	# Inner bevel highlight line for added depth.
	for i: int in 8:
		var b_a: Vector2 = bevel[i]
		var b_b: Vector2 = bevel[(i + 1) % 8]
		draw_line(b_a, b_b, Color(0.40, 0.32, 0.20, 0.7), 0.8)

	# --- 8 rivets (one per octagon vertex) for a more detailed plate ---
	var rivet_r: float = r * 0.83
	for i: int in 8:
		var ang: float = float(i) / 8.0 * TAU
		var rp: Vector2 = Vector2(cx + cos(ang) * rivet_r, cy + sin(ang) * rivet_r)
		# Brass rivet body, with a darker recess ring below.
		draw_circle(rp, 2.6, Color(0.30, 0.22, 0.13, 1.0))
		draw_circle(rp, 2.0, Color(0.72, 0.55, 0.30, 1.0))
		# Specular highlight for the stamped-bolt feel.
		draw_circle(rp + Vector2(-0.8, -0.8), 0.7, Color(1.0, 0.88, 0.50, 0.85))

	# --- Crossed hammer behind the anvil ---
	var hammer_handle_col: Color = Color(0.46, 0.32, 0.18, 1.0)
	var hammer_head_col: Color = Color(0.78, 0.62, 0.18, 1.0)
	# Handle from upper-right to lower-left.
	_draw_thick_line(
		Vector2(cx + r * 0.62, cy - r * 0.55),
		Vector2(cx - r * 0.30, cy + r * 0.40),
		r * 0.045,
		hammer_handle_col,
	)
	# Hammer head with two-tone (top brass, bottom shadow) for depth.
	var hh_pos: Vector2 = Vector2(cx + r * 0.38, cy - r * 0.68)
	var hh_size: Vector2 = Vector2(r * 0.42, r * 0.24)
	draw_rect(Rect2(hh_pos, hh_size), hammer_head_col, true)
	draw_rect(Rect2(hh_pos + Vector2(0, hh_size.y * 0.55),
		Vector2(hh_size.x, hh_size.y * 0.45)),
		Color(0.45, 0.32, 0.12, 1.0), true)
	# Hammer head outline.
	draw_rect(Rect2(hh_pos, hh_size), Color(0.20, 0.14, 0.06, 1.0), false, 1.0)

	# --- Anvil body ---
	var body_w: float = r * 1.10
	var body_h: float = r * 0.55
	var body: PackedVector2Array = [
		Vector2(cx - body_w * 0.55, cy - body_h * 0.10),  # top-left horn
		Vector2(cx - body_w * 0.18, cy - body_h * 0.05),
		Vector2(cx - body_w * 0.18, cy + body_h * 0.18),
		Vector2(cx - body_w * 0.42, cy + body_h * 0.55),  # base outer
		Vector2(cx + body_w * 0.42, cy + body_h * 0.55),
		Vector2(cx + body_w * 0.18, cy + body_h * 0.18),
		Vector2(cx + body_w * 0.18, cy - body_h * 0.05),
		Vector2(cx + body_w * 0.55, cy - body_h * 0.10),
	]
	draw_colored_polygon(body, Color(0.14, 0.14, 0.15, 1.0))
	# Anvil shadow/edge — thin darker line on bottom of body.
	for i: int in body.size():
		var ba: Vector2 = body[i]
		var bb: Vector2 = body[(i + 1) % body.size()]
		draw_line(ba, bb, Color(0.05, 0.05, 0.06, 1.0), 1.0)

	# --- Hot working face (brass + glow) ---
	var face_rect: Rect2 = Rect2(
		Vector2(cx - body_w * 0.55, cy - body_h * 0.18),
		Vector2(body_w * 1.10, body_h * 0.12))
	draw_rect(face_rect, Color(0.86, 0.55, 0.18, 1.0), true)
	# Brighter strip along the very top of the face for the heat-glow.
	draw_rect(Rect2(face_rect.position, Vector2(face_rect.size.x, face_rect.size.y * 0.35)),
		Color(1.0, 0.78, 0.30, 1.0), true)

	# --- Forge sparks rising from the strike point ---
	var spark_origin: Vector2 = Vector2(cx + r * 0.04, cy - body_h * 0.12)
	for s_off: Vector2 in [
		Vector2(-r * 0.28, -r * 0.22),
		Vector2(-r * 0.10, -r * 0.42),
		Vector2(r * 0.18, -r * 0.30),
		Vector2(r * 0.08, -r * 0.18),
	]:
		var sp: Vector2 = spark_origin + s_off
		draw_circle(sp, 1.4, Color(1.0, 0.82, 0.30, 0.95))
		draw_circle(sp, 2.4, Color(1.0, 0.55, 0.20, 0.30))


func _draw_thick_line(a: Vector2, b: Vector2, half_thickness: float, color: Color) -> void:
	## draw_line's `width` only renders ALIASED lines on most
	## drivers; for a clean thick stroke we build a quad.
	var dir: Vector2 = (b - a).normalized()
	var perp: Vector2 = Vector2(-dir.y, dir.x) * half_thickness
	draw_colored_polygon(PackedVector2Array([
		a + perp,
		a - perp,
		b - perp,
		b + perp,
	]), color)


func _draw_sable_icon(cx: float, cy: float, r: float) -> void:
	# --- Hexagonal corp plate (outer + inner) ---
	var hex: PackedVector2Array = []
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU + PI / 6.0
		hex.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	draw_colored_polygon(hex, Color(0.05, 0.05, 0.08, 1.0))
	# Mid hex layer for additional depth.
	var mid_hex: PackedVector2Array = []
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU + PI / 6.0
		mid_hex.append(Vector2(cx + cos(a) * (r * 0.88), cy + sin(a) * (r * 0.88)))
	draw_colored_polygon(mid_hex, Color(0.08, 0.08, 0.11, 1.0))
	# Inner darker hex for the recessed-die look.
	var inner_hex: PackedVector2Array = []
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU + PI / 6.0
		inner_hex.append(Vector2(cx + cos(a) * (r * 0.74), cy + sin(a) * (r * 0.74)))
	draw_colored_polygon(inner_hex, Color(0.11, 0.11, 0.16, 1.0))
	# Outer hex outline — bright violet for the corpo-tech silhouette.
	for i: int in 6:
		var p_a: Vector2 = hex[i]
		var p_b: Vector2 = hex[(i + 1) % 6]
		draw_line(p_a, p_b, Color(0.78, 0.35, 1.00, 1.0), 1.6)
	# Faint inner hex outline for additional structure.
	for i: int in 6:
		var ia: Vector2 = inner_hex[i]
		var ib: Vector2 = inner_hex[(i + 1) % 6]
		draw_line(ia, ib, Color(0.45, 0.20, 0.65, 0.7), 0.8)

	# --- Centred sigil: scope crosshair + stacked downward chevrons.
	# Reads as "infiltration target lock" instead of the prior 'Z'.
	var violet: Color = Color(0.92, 0.65, 1.00, 1.0)
	var violet_dim: Color = Color(0.78, 0.35, 1.00, 1.0)

	# Crosshair scope ring at center.
	draw_arc(Vector2(cx, cy), r * 0.36, 0.0, TAU, 28, violet, 1.5)
	draw_arc(Vector2(cx, cy), r * 0.20, 0.0, TAU, 22, violet_dim, 1.0)
	# Crosshair tick lines (4 cardinal directions, broken at center).
	for ang: float in [-PI * 0.5, 0.0, PI * 0.5, PI]:
		var dir: Vector2 = Vector2(cos(ang), sin(ang))
		var inner_end: Vector2 = Vector2(cx, cy) + dir * (r * 0.12)
		var outer_end: Vector2 = Vector2(cx, cy) + dir * (r * 0.38)
		draw_line(inner_end, outer_end, violet, 1.4)
	# Center dot (the lock-pip).
	draw_circle(Vector2(cx, cy), r * 0.05, Color(1.0, 0.85, 1.0, 1.0))

	# --- Stacked downward chevrons above the scope (3 layered V shapes,
	# tightening toward the bottom — military rank / "elite operator" feel).
	var chev_thick: float = r * 0.05
	for i: int in 3:
		var y_off: float = -r * 0.50 + float(i) * (r * 0.08)
		var w_scale: float = 1.0 - float(i) * 0.18
		var alpha: float = 1.0 - float(i) * 0.20
		var ch_col: Color = Color(0.92, 0.65, 1.00, alpha)
		# Left arm.
		_draw_thick_line(
			Vector2(cx - r * 0.32 * w_scale, cy + y_off - r * 0.05),
			Vector2(cx, cy + y_off + r * 0.07),
			chev_thick,
			ch_col,
		)
		# Right arm.
		_draw_thick_line(
			Vector2(cx + r * 0.32 * w_scale, cy + y_off - r * 0.05),
			Vector2(cx, cy + y_off + r * 0.07),
			chev_thick,
			ch_col,
		)

	# --- 6 corner pip dots at hex vertices for the circuit-etching read.
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU + PI / 6.0
		var pip_pos: Vector2 = Vector2(cx + cos(a) * (r * 0.62), cy + sin(a) * (r * 0.62))
		draw_circle(pip_pos, 1.8, violet_dim)
		draw_circle(pip_pos, 0.9, Color(1.0, 0.85, 1.0, 0.9))
