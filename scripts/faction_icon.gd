class_name FactionIcon
extends Control
## Procedural faction logo, drawn directly in `_draw` so we don't need
## external image assets. Each faction gets a distinct silhouette:
##   - Anvil: octagonal iron plate, stylized falcon in a forward-diving
##     posture (sodium-amber wings spread, brass body) with a hot forge
##     band beneath. Reads as "industrial / soviet" — the falcon is the
##     Combine's heraldic war-bird.
##   - Sable: faceted hex plate with cool blue-white scope crosshair +
##     chevrons. Reads as "sleek corpo specops". Color matches lore
##     (docs/03_factions.md §2.3) — Meridian's signature glow is cool
##     blue-white, NOT violet (violet is reserved for the Inheritors).
##   - Inheritor: pale-gold square temple plate, central architect-violet
##     all-seeing eye sigil + bronze accents. Reads as "patient AI
##     collective / consecrated".
##   - Heliarch: hexagonal sooted-iron plate, brass rivets, amber sun
##     crown sigil + radiating heat rays. Reads as "thermal cult /
##     reactor mystics".
## Used by the match-setup screen to label faction-pick buttons; size
## defaults to 64×64 but can be scaled via custom_minimum_size.

enum Faction { ANVIL, SABLE, INHERITOR, HELIARCH }

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
	match faction:
		Faction.ANVIL:
			_draw_anvil_icon(cx, cy, r)
		Faction.SABLE:
			_draw_sable_icon(cx, cy, r)
		Faction.INHERITOR:
			_draw_inheritor_icon(cx, cy, r)
		Faction.HELIARCH:
			_draw_heliarch_icon(cx, cy, r)
		_:
			_draw_anvil_icon(cx, cy, r)
	# Selection ring — drawn on top, faction-tinted.
	if selected:
		var ring_color: Color
		match faction:
			Faction.ANVIL:     ring_color = Color(0.95, 0.78, 0.32, 1.0)
			Faction.SABLE:     ring_color = Color(0.55, 0.85, 1.00, 1.0)
			Faction.INHERITOR: ring_color = Color(0.95, 0.85, 0.55, 1.0)
			Faction.HELIARCH:  ring_color = Color(1.00, 0.55, 0.20, 1.0)
			_:                 ring_color = Color(0.95, 0.78, 0.32, 1.0)
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

	# --- Stylized falcon (Combine heraldic war-bird) ---
	# Three-part construction: spread wings (two angled polygons),
	# body (vertical lozenge), and a faceted head with eye-pip. The
	# falcon faces the viewer in a forward-diving posture — wings
	# swept slightly back from horizontal so the silhouette reads as
	# "stooping raptor" rather than "soaring vulture".
	const FALCON_BODY: Color  = Color(0.85, 0.68, 0.32, 1.0)  # brass body
	const FALCON_WING: Color  = Color(0.70, 0.50, 0.22, 1.0)  # darker brass wings
	const FALCON_SHADE: Color = Color(0.42, 0.28, 0.12, 1.0)  # wing shadow band
	const FALCON_HOT: Color   = Color(1.00, 0.82, 0.34, 1.0)  # sodium-amber accent
	const FALCON_OUT: Color   = Color(0.18, 0.12, 0.06, 1.0)  # outline

	# Wings — two trapezoidal polygons, mirrored across the vertical
	# axis, swept slightly back (rear edge lower than leading edge).
	var wing_inner_y: float = cy - r * 0.05
	var wing_outer_y: float = cy + r * 0.12
	var wing_inner_x: float = r * 0.10
	var wing_outer_x: float = r * 0.78
	var wing_tip_y: float = cy + r * 0.30
	var left_wing: PackedVector2Array = [
		Vector2(cx - wing_inner_x, wing_inner_y),                  # inner top
		Vector2(cx - wing_outer_x, wing_outer_y),                  # outer top
		Vector2(cx - wing_outer_x * 0.92, wing_tip_y),             # outer bottom
		Vector2(cx - wing_inner_x, wing_outer_y + r * 0.04),       # inner bottom
	]
	var right_wing: PackedVector2Array = [
		Vector2(cx + wing_inner_x, wing_inner_y),
		Vector2(cx + wing_outer_x, wing_outer_y),
		Vector2(cx + wing_outer_x * 0.92, wing_tip_y),
		Vector2(cx + wing_inner_x, wing_outer_y + r * 0.04),
	]
	draw_colored_polygon(left_wing, FALCON_WING)
	draw_colored_polygon(right_wing, FALCON_WING)
	# Wing-tip shadow bands for the layered-feather read.
	var l_shade: PackedVector2Array = [
		Vector2(cx - wing_outer_x, wing_outer_y),
		Vector2(cx - wing_outer_x * 0.92, wing_tip_y),
		Vector2(cx - wing_outer_x * 0.55, wing_tip_y - r * 0.02),
		Vector2(cx - wing_outer_x * 0.62, wing_outer_y),
	]
	var r_shade: PackedVector2Array = [
		Vector2(cx + wing_outer_x, wing_outer_y),
		Vector2(cx + wing_outer_x * 0.92, wing_tip_y),
		Vector2(cx + wing_outer_x * 0.55, wing_tip_y - r * 0.02),
		Vector2(cx + wing_outer_x * 0.62, wing_outer_y),
	]
	draw_colored_polygon(l_shade, FALCON_SHADE)
	draw_colored_polygon(r_shade, FALCON_SHADE)
	# Wing outlines so each polygon has a crisp edge.
	for poly_v: PackedVector2Array in [left_wing, right_wing]:
		for i: int in poly_v.size():
			draw_line(poly_v[i], poly_v[(i + 1) % poly_v.size()], FALCON_OUT, 1.0)

	# Body — vertical lozenge ending in a tail fork.
	var body: PackedVector2Array = [
		Vector2(cx, cy - r * 0.30),                # neck base
		Vector2(cx + r * 0.10, cy - r * 0.08),     # shoulder right
		Vector2(cx + r * 0.08, cy + r * 0.20),     # waist right
		Vector2(cx + r * 0.14, cy + r * 0.50),     # tail right
		Vector2(cx, cy + r * 0.40),                # tail notch
		Vector2(cx - r * 0.14, cy + r * 0.50),     # tail left
		Vector2(cx - r * 0.08, cy + r * 0.20),     # waist left
		Vector2(cx - r * 0.10, cy - r * 0.08),     # shoulder left
	]
	draw_colored_polygon(body, FALCON_BODY)
	for i: int in body.size():
		draw_line(body[i], body[(i + 1) % body.size()], FALCON_OUT, 1.0)
	# Body center-line crease — thin shadow down the keel for the
	# stamped-metal feel.
	draw_line(Vector2(cx, cy - r * 0.28), Vector2(cx, cy + r * 0.38), FALCON_SHADE, 1.0)

	# Head — small faceted polygon above the body with a beak hook.
	var head: PackedVector2Array = [
		Vector2(cx, cy - r * 0.62),                # crown
		Vector2(cx + r * 0.10, cy - r * 0.50),     # right cheek
		Vector2(cx + r * 0.05, cy - r * 0.34),     # right neck
		Vector2(cx - r * 0.05, cy - r * 0.34),     # left neck
		Vector2(cx - r * 0.10, cy - r * 0.50),     # left cheek
	]
	draw_colored_polygon(head, FALCON_BODY)
	for i: int in head.size():
		draw_line(head[i], head[(i + 1) % head.size()], FALCON_OUT, 1.0)
	# Beak — small triangle below the head pointing down.
	var beak: PackedVector2Array = [
		Vector2(cx, cy - r * 0.30),
		Vector2(cx + r * 0.04, cy - r * 0.40),
		Vector2(cx - r * 0.04, cy - r * 0.40),
	]
	draw_colored_polygon(beak, FALCON_SHADE)
	# Eye — sodium-amber pip.
	draw_circle(Vector2(cx, cy - r * 0.52), r * 0.05, FALCON_HOT)
	draw_circle(Vector2(cx - r * 0.012, cy - r * 0.532), r * 0.02, Color(1.0, 0.95, 0.7, 1.0))

	# --- Hot forge band beneath the falcon ---
	# A narrow sodium-amber strip across the lower plate so the
	# Combine palette (brass body + forge amber + soot black) reads
	# at a glance.
	var band_rect: Rect2 = Rect2(
		Vector2(cx - r * 0.78, cy + r * 0.60),
		Vector2(r * 1.56, r * 0.10),
	)
	draw_rect(band_rect, Color(0.55, 0.30, 0.10, 1.0), true)
	draw_rect(
		Rect2(band_rect.position, Vector2(band_rect.size.x, band_rect.size.y * 0.45)),
		Color(1.0, 0.62, 0.20, 1.0),
		true,
	)


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
	# Outer hex outline — cool blue-white for the corpo-tech silhouette
	# (per docs/03_factions.md §2.3 — Meridian's signature is cyan, not
	# violet; violet is the Inheritors' exclusive Architect color).
	for i: int in 6:
		var p_a: Vector2 = hex[i]
		var p_b: Vector2 = hex[(i + 1) % 6]
		draw_line(p_a, p_b, Color(0.55, 0.85, 1.00, 1.0), 1.6)
	# Faint inner hex outline for additional structure.
	for i: int in 6:
		var ia: Vector2 = inner_hex[i]
		var ib: Vector2 = inner_hex[(i + 1) % 6]
		draw_line(ia, ib, Color(0.28, 0.50, 0.62, 0.7), 0.8)

	# --- Centred sigil: scope crosshair + stacked downward chevrons.
	# Reads as "infiltration target lock" instead of the prior 'Z'.
	var cyan: Color = Color(0.80, 0.95, 1.00, 1.0)
	var cyan_dim: Color = Color(0.55, 0.85, 1.00, 1.0)

	# Crosshair scope ring at center.
	draw_arc(Vector2(cx, cy), r * 0.36, 0.0, TAU, 28, cyan, 1.5)
	draw_arc(Vector2(cx, cy), r * 0.20, 0.0, TAU, 22, cyan_dim, 1.0)
	# Crosshair tick lines (4 cardinal directions, broken at center).
	for ang: float in [-PI * 0.5, 0.0, PI * 0.5, PI]:
		var dir: Vector2 = Vector2(cos(ang), sin(ang))
		var inner_end: Vector2 = Vector2(cx, cy) + dir * (r * 0.12)
		var outer_end: Vector2 = Vector2(cx, cy) + dir * (r * 0.38)
		draw_line(inner_end, outer_end, cyan, 1.4)
	# Center dot (the lock-pip).
	draw_circle(Vector2(cx, cy), r * 0.05, Color(0.95, 1.0, 1.0, 1.0))

	# --- Stacked downward chevrons above the scope (3 layered V shapes,
	# tightening toward the bottom — military rank / "elite operator" feel).
	var chev_thick: float = r * 0.05
	for i: int in 3:
		var y_off: float = -r * 0.50 + float(i) * (r * 0.08)
		var w_scale: float = 1.0 - float(i) * 0.18
		var alpha: float = 1.0 - float(i) * 0.20
		var ch_col: Color = Color(0.80, 0.95, 1.00, alpha)
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
		draw_circle(pip_pos, 1.8, cyan_dim)
		draw_circle(pip_pos, 0.9, Color(0.95, 1.0, 1.0, 0.9))


func _draw_inheritor_icon(cx: float, cy: float, r: float) -> void:
	## Inheritor sigil — square temple plate (rotated 45° = diamond)
	## with a centered architect-violet all-seeing eye flanked by bronze
	## arches. Pale-gold base reads as "consecrated / patient", violet
	## emissive reads as "Architect AI". Bronze accents tie in the
	## faction's verdigris-bronze fittings.
	const PALE_GOLD: Color = Color(0.78, 0.70, 0.50, 1.0)
	const PALE_GOLD_DK: Color = Color(0.55, 0.48, 0.32, 1.0)
	const ARCHITECT_VIOLET: Color = Color(0.78, 0.50, 1.00, 1.0)
	const VIOLET_BRIGHT: Color = Color(0.95, 0.75, 1.00, 1.0)
	const BRONZE: Color = Color(0.55, 0.40, 0.20, 1.0)
	const VERDIGRIS: Color = Color(0.32, 0.50, 0.42, 1.0)
	const PLATE_BG: Color = Color(0.18, 0.18, 0.20, 1.0)

	# --- Diamond plate (square rotated 45°) ---
	var dia: PackedVector2Array = PackedVector2Array([
		Vector2(cx, cy - r),
		Vector2(cx + r, cy),
		Vector2(cx, cy + r),
		Vector2(cx - r, cy),
	])
	draw_colored_polygon(dia, PLATE_BG)
	# Inner bevel diamond (smaller, slightly brighter — pale gold).
	var dia_inner: PackedVector2Array = PackedVector2Array([
		Vector2(cx, cy - r * 0.86),
		Vector2(cx + r * 0.86, cy),
		Vector2(cx, cy + r * 0.86),
		Vector2(cx - r * 0.86, cy),
	])
	draw_colored_polygon(dia_inner, Color(0.22, 0.20, 0.22, 1.0))
	# Diamond outline — pale-gold, sells the temple-plate feel.
	for i: int in 4:
		var pa: Vector2 = dia[i]
		var pb: Vector2 = dia[(i + 1) % 4]
		draw_line(pa, pb, PALE_GOLD, 1.8)
	# Inner outline — bronze.
	for i: int in 4:
		var pa: Vector2 = dia_inner[i]
		var pb: Vector2 = dia_inner[(i + 1) % 4]
		draw_line(pa, pb, BRONZE, 1.0)

	# --- Two bronze archways flanking the centre (left + right) ---
	# Each is a half-circle arc on top of a short upright bar.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var arch_cx: float = cx + sx * r * 0.42
		# Upright bar.
		_draw_thick_line(
			Vector2(arch_cx, cy + r * 0.18),
			Vector2(arch_cx, cy - r * 0.08),
			r * 0.030,
			BRONZE,
		)
		# Arc cap over the bar.
		draw_arc(Vector2(arch_cx, cy - r * 0.08), r * 0.10, PI, TAU, 14, BRONZE, 2.0)

	# --- Central all-seeing eye sigil (the Architect motif) ---
	# Almond-shaped eye outline: two arcs meeting at left + right.
	var eye_r: float = r * 0.40
	var eye_y: float = cy
	# Top arc.
	draw_arc(Vector2(cx, eye_y + eye_r * 0.40), eye_r, PI + 0.30, TAU - 0.30, 22, ARCHITECT_VIOLET, 1.8)
	# Bottom arc.
	draw_arc(Vector2(cx, eye_y - eye_r * 0.40), eye_r, 0.30, PI - 0.30, 22, ARCHITECT_VIOLET, 1.8)
	# Iris ring.
	draw_arc(Vector2(cx, eye_y), eye_r * 0.42, 0.0, TAU, 26, VIOLET_BRIGHT, 1.6)
	# Pupil — solid violet dot.
	draw_circle(Vector2(cx, eye_y), eye_r * 0.18, VIOLET_BRIGHT)
	# Bright pupil core.
	draw_circle(Vector2(cx, eye_y), eye_r * 0.08, Color(1.0, 0.95, 1.0, 1.0))

	# --- Verdigris circuitry traces along the top and bottom of the eye ---
	# Short horizontal lines flanking the eye, reading as "consecrated
	# data flow" — Inheritor's AI-collective identity.
	for trace_side: int in 2:
		var tsx: float = -1.0 if trace_side == 0 else 1.0
		# Upper trace.
		draw_line(
			Vector2(cx + tsx * eye_r * 0.95, eye_y - eye_r * 0.10),
			Vector2(cx + tsx * (eye_r * 1.30), eye_y - eye_r * 0.10),
			VERDIGRIS, 1.4,
		)
		draw_circle(Vector2(cx + tsx * (eye_r * 1.30), eye_y - eye_r * 0.10), 1.6, VERDIGRIS)
		# Lower trace.
		draw_line(
			Vector2(cx + tsx * eye_r * 0.95, eye_y + eye_r * 0.10),
			Vector2(cx + tsx * (eye_r * 1.30), eye_y + eye_r * 0.10),
			VERDIGRIS, 1.4,
		)
		draw_circle(Vector2(cx + tsx * (eye_r * 1.30), eye_y + eye_r * 0.10), 1.6, VERDIGRIS)

	# --- Corner studs at the four diamond points (pale-gold rivets) ---
	for i: int in 4:
		var stud_pos: Vector2 = dia[i]
		# Pull the stud slightly inward so it sits on the bevel, not the tip.
		var inward: Vector2 = (Vector2(cx, cy) - stud_pos).normalized() * (r * 0.06)
		var spos: Vector2 = stud_pos + inward
		draw_circle(spos, 3.2, PALE_GOLD_DK)
		draw_circle(spos, 2.2, PALE_GOLD)
		draw_circle(spos + Vector2(-0.7, -0.7), 0.8, Color(1.0, 0.95, 0.65, 0.85))


func _draw_heliarch_icon(cx: float, cy: float, r: float) -> void:
	## Heliarch sigil — hexagonal sooted-iron plate with brass rivets and
	## a central amber sun crown (radiating heat rays + brass chalice
	## frame). Reads as "thermal cult / reactor mystics". Warm orange
	## palette throughout matches the in-game faction tint.
	const SOOTED: Color = Color(0.18, 0.14, 0.10, 1.0)
	const SOOTED_DK: Color = Color(0.10, 0.08, 0.06, 1.0)
	const HELIARCH_BRASS: Color = Color(0.72, 0.52, 0.20, 1.0)
	const HELIARCH_BRASS_DK: Color = Color(0.42, 0.30, 0.12, 1.0)
	const REACTOR_AMBER: Color = Color(1.00, 0.55, 0.20, 1.0)
	const HOT_WHITE: Color = Color(1.00, 0.88, 0.55, 1.0)

	# --- Hexagonal plate (point-up) ---
	var hex: PackedVector2Array = PackedVector2Array()
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU - PI * 0.5  # rotate so a point is at the top
		hex.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	draw_colored_polygon(hex, SOOTED)
	# Inner hex (slightly smaller, even darker) for the recessed look.
	var hex_inner: PackedVector2Array = PackedVector2Array()
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU - PI * 0.5
		hex_inner.append(Vector2(cx + cos(a) * (r * 0.86), cy + sin(a) * (r * 0.86)))
	draw_colored_polygon(hex_inner, SOOTED_DK)
	# Outline — brass.
	for i: int in 6:
		var pa: Vector2 = hex[i]
		var pb: Vector2 = hex[(i + 1) % 6]
		draw_line(pa, pb, HELIARCH_BRASS, 1.8)
	# Inner bevel highlight.
	for i: int in 6:
		var pa: Vector2 = hex_inner[i]
		var pb: Vector2 = hex_inner[(i + 1) % 6]
		draw_line(pa, pb, HELIARCH_BRASS_DK, 0.9)

	# --- 6 brass rivets at hex vertices ---
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU - PI * 0.5
		var rivet_pos: Vector2 = Vector2(cx + cos(a) * (r * 0.78), cy + sin(a) * (r * 0.78))
		draw_circle(rivet_pos, 2.8, HELIARCH_BRASS_DK)
		draw_circle(rivet_pos, 2.0, HELIARCH_BRASS)
		draw_circle(rivet_pos + Vector2(-0.7, -0.7), 0.8, Color(1.0, 0.92, 0.55, 0.85))

	# --- Central sun crown ---
	# Eight radiating heat rays around the sun disc, tapering outward.
	var ray_inner: float = r * 0.32
	var ray_outer: float = r * 0.62
	for ray_i: int in 8:
		var ang: float = float(ray_i) / 8.0 * TAU
		var inner_p: Vector2 = Vector2(cx + cos(ang) * ray_inner, cy + sin(ang) * ray_inner)
		var outer_p: Vector2 = Vector2(cx + cos(ang) * ray_outer, cy + sin(ang) * ray_outer)
		# Thick triangular ray (tapered tip outward).
		var perp: Vector2 = Vector2(-sin(ang), cos(ang)) * (r * 0.03)
		var tri: PackedVector2Array = PackedVector2Array([
			inner_p + perp,
			inner_p - perp,
			outer_p,
		])
		draw_colored_polygon(tri, REACTOR_AMBER)
	# Sun disc — solid amber.
	draw_circle(Vector2(cx, cy), r * 0.30, REACTOR_AMBER)
	# Hot-white inner core.
	draw_circle(Vector2(cx, cy), r * 0.18, HOT_WHITE)
	# Brass chalice frame — two crescent arcs above and below the disc
	# making it read as "fire held in a brass vessel".
	# Top arc (open downward).
	draw_arc(Vector2(cx, cy - r * 0.05), r * 0.36, PI * 0.10, PI - 0.10, 18, HELIARCH_BRASS, 2.4)
	# Bottom chalice rim — short flat band.
	_draw_thick_line(
		Vector2(cx - r * 0.32, cy + r * 0.32),
		Vector2(cx + r * 0.32, cy + r * 0.32),
		r * 0.040,
		HELIARCH_BRASS,
	)
	# Two brass uprights joining the rim to the disc base.
	for upright_side: int in 2:
		var usx: float = -1.0 if upright_side == 0 else 1.0
		_draw_thick_line(
			Vector2(cx + usx * r * 0.28, cy + r * 0.10),
			Vector2(cx + usx * r * 0.32, cy + r * 0.32),
			r * 0.025,
			HELIARCH_BRASS,
		)
	# Stem under the rim — a short brass spine.
	_draw_thick_line(
		Vector2(cx, cy + r * 0.32),
		Vector2(cx, cy + r * 0.52),
		r * 0.045,
		HELIARCH_BRASS,
	)
	# Wide brass foot at the bottom.
	_draw_thick_line(
		Vector2(cx - r * 0.22, cy + r * 0.54),
		Vector2(cx + r * 0.22, cy + r * 0.54),
		r * 0.050,
		HELIARCH_BRASS,
	)
