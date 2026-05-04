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
	# Octagonal iron plate -- stronger industrial silhouette than
	# the previous circle. Eight-vertex polygon with a darker
	# bevel ring on its inside edge.
	var plate: PackedVector2Array = []
	for i: int in 8:
		var a: float = float(i) / 8.0 * TAU + PI / 8.0  # rotated so a flat edge sits on top
		plate.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	draw_colored_polygon(plate, Color(0.30, 0.27, 0.22, 1.0))
	# Inner bevel polygon -- slightly smaller octagon in a darker
	# tone so the plate reads as a thick rim around the central
	# emblem.
	var bevel: PackedVector2Array = []
	for i: int in 8:
		var a: float = float(i) / 8.0 * TAU + PI / 8.0
		bevel.append(Vector2(cx + cos(a) * (r * 0.84), cy + sin(a) * (r * 0.84)))
	draw_colored_polygon(bevel, Color(0.20, 0.18, 0.15, 1.0))
	# Bright outline on the outer plate edge.
	for i: int in 8:
		var p_a: Vector2 = plate[i]
		var p_b: Vector2 = plate[(i + 1) % 8]
		draw_line(p_a, p_b, Color(0.55, 0.46, 0.30, 1.0), 1.5)
	# 4 brass rivets along the cardinal axes -- larger and brighter
	# than before so they read at small thumbnail sizes.
	var rivet_r: float = r * 0.78
	for ang: float in [-PI * 0.5, 0.0, PI * 0.5, PI]:
		var rp: Vector2 = Vector2(cx + cos(ang) * rivet_r, cy + sin(ang) * rivet_r)
		draw_circle(rp, 3.0, Color(0.65, 0.52, 0.30, 1.0))
		# Highlight pixel on the top-left of each rivet for the
		# stamped-bolt look.
		draw_rect(Rect2(rp + Vector2(-1.5, -1.5), Vector2(1.0, 1.0)), Color(1.0, 0.85, 0.45, 0.65), true)
	# Anvil silhouette -- chunkier, cleaner trapezoid with sharper
	# horns and a defined waist. Drawn over a brass-tinted
	# crossed-hammer accent so the emblem reads as "hammer + anvil"
	# rather than "blob + line".
	# Crossed hammer (drawn first so anvil overlaps it).
	var hammer_a: Color = Color(0.78, 0.62, 0.18, 1.0)
	var hammer_w: float = r * 0.10
	# Diagonal handle from upper-right toward lower-left.
	_draw_thick_line(
		Vector2(cx + r * 0.55, cy - r * 0.50),
		Vector2(cx - r * 0.20, cy + r * 0.30),
		hammer_w * 0.7,
		Color(0.42, 0.30, 0.18, 1.0),
	)
	# Hammer head box at the upper end.
	draw_rect(
		Rect2(Vector2(cx + r * 0.40, cy - r * 0.65), Vector2(r * 0.36, r * 0.22)),
		hammer_a,
		true,
	)
	# Anvil body.
	var body_w: float = r * 1.10
	var body_h: float = r * 0.55
	var body: PackedVector2Array = [
		Vector2(cx - body_w * 0.55, cy - body_h * 0.10),  # top-left horn tip
		Vector2(cx - body_w * 0.18, cy - body_h * 0.05),  # neck
		Vector2(cx - body_w * 0.18, cy + body_h * 0.18),  # waist top
		Vector2(cx - body_w * 0.42, cy + body_h * 0.55),  # base outer
		Vector2(cx + body_w * 0.42, cy + body_h * 0.55),
		Vector2(cx + body_w * 0.18, cy + body_h * 0.18),
		Vector2(cx + body_w * 0.18, cy - body_h * 0.05),
		Vector2(cx + body_w * 0.55, cy - body_h * 0.10),  # top-right horn tip
	]
	draw_colored_polygon(body, Color(0.16, 0.16, 0.17, 1.0))
	# Top working face -- a thin brass strip along the upper edge of
	# the anvil for the "hot iron" highlight that sells the forge
	# read.
	draw_rect(
		Rect2(Vector2(cx - body_w * 0.55, cy - body_h * 0.16), Vector2(body_w * 1.10, body_h * 0.10)),
		Color(0.78, 0.55, 0.18, 1.0),
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
	# Hexagonal corp-glyph -- replaces the previous diamond. Hex
	# shape reads as "circuit / chip die" which leans into the
	# corpo-cyber aesthetic better than the simpler diamond.
	var hex: PackedVector2Array = []
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU + PI / 6.0  # flat edge top
		hex.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	draw_colored_polygon(hex, Color(0.05, 0.05, 0.08, 1.0))
	# Inner darker hex for the recessed-die look.
	var inner_hex: PackedVector2Array = []
	for i: int in 6:
		var a: float = float(i) / 6.0 * TAU + PI / 6.0
		inner_hex.append(Vector2(cx + cos(a) * (r * 0.78), cy + sin(a) * (r * 0.78)))
	draw_colored_polygon(inner_hex, Color(0.10, 0.10, 0.14, 1.0))
	# Outer hex outline -- bright violet emissive for the corp-tech
	# silhouette.
	for i: int in 6:
		var p_a: Vector2 = hex[i]
		var p_b: Vector2 = hex[(i + 1) % 6]
		draw_line(p_a, p_b, Color(0.78, 0.35, 1.00, 1.0), 1.6)
	# Centred sigil -- an angular S-curve made of three thick line
	# segments. Reads as a stylised corp logo / monogram. Drawn as
	# rotated rectangles so the "S" silhouette stays sharp.
	var s_thick: float = r * 0.13
	# Top stroke (upper-left to upper-right).
	_draw_thick_line(
		Vector2(cx - r * 0.30, cy - r * 0.32),
		Vector2(cx + r * 0.32, cy - r * 0.32),
		s_thick * 0.5,
		Color(0.92, 0.65, 1.00, 1.0),
	)
	# Middle diagonal (upper-right to lower-left).
	_draw_thick_line(
		Vector2(cx + r * 0.32, cy - r * 0.32),
		Vector2(cx - r * 0.32, cy + r * 0.32),
		s_thick * 0.5,
		Color(0.92, 0.65, 1.00, 1.0),
	)
	# Bottom stroke (lower-left to lower-right).
	_draw_thick_line(
		Vector2(cx - r * 0.32, cy + r * 0.32),
		Vector2(cx + r * 0.30, cy + r * 0.32),
		s_thick * 0.5,
		Color(0.92, 0.65, 1.00, 1.0),
	)
	# Two corner pip dots at the top-left + bottom-right of the hex
	# for that "circuit etching" pattern read.
	for ang: float in [PI * 0.83, PI * 1.83]:
		draw_circle(Vector2(cx + cos(ang) * (r * 0.55), cy + sin(ang) * (r * 0.55)), 2.0, Color(0.78, 0.35, 1.0, 1.0))
