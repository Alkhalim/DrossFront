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
		var ring_color: Color = Color(0.95, 0.78, 0.32, 1.0) if faction == Faction.ANVIL else Color(0.45, 0.95, 1.0, 1.0)
		draw_arc(Vector2(cx, cy), r + 4, 0.0, TAU, 48, ring_color, 2.5, true)


func _draw_anvil_icon(cx: float, cy: float, r: float) -> void:
	# Iron-grey rivet plate background — circle with darker outline.
	draw_circle(Vector2(cx, cy), r, Color(0.32, 0.34, 0.36, 1.0))
	draw_arc(Vector2(cx, cy), r, 0.0, TAU, 32, Color(0.05, 0.05, 0.06, 1.0), 2.0, true)
	# 4 corner rivets at NE/NW/SE/SW of the plate.
	var rivet_r: float = r * 0.70
	for ang: float in [PI * 0.25, PI * 0.75, PI * 1.25, PI * 1.75]:
		draw_circle(Vector2(cx + cos(ang) * rivet_r, cy + sin(ang) * rivet_r), 2.5, Color(0.18, 0.20, 0.22, 1.0))
	# Anvil silhouette — a chunky upside-down trapezoid with horns.
	# Drawn as a polygon so the body is solid and reads at small size.
	var body_w: float = r * 1.05
	var body_h: float = r * 0.55
	var body: PackedVector2Array = [
		Vector2(cx - body_w * 0.55, cy - body_h * 0.20),  # top-left horn
		Vector2(cx - body_w * 0.32, cy - body_h * 0.15),
		Vector2(cx - body_w * 0.18, cy + body_h * 0.05),
		Vector2(cx - body_w * 0.32, cy + body_h * 0.45),  # base widens
		Vector2(cx + body_w * 0.32, cy + body_h * 0.45),
		Vector2(cx + body_w * 0.18, cy + body_h * 0.05),
		Vector2(cx + body_w * 0.32, cy - body_h * 0.15),
		Vector2(cx + body_w * 0.55, cy - body_h * 0.20),  # top-right horn
	]
	draw_colored_polygon(body, Color(0.18, 0.20, 0.22, 1.0))
	# Brass identity stripe across the anvil body — Anvil's faction color.
	var stripe_y: float = cy + body_h * 0.20
	draw_line(Vector2(cx - body_w * 0.32, stripe_y), Vector2(cx + body_w * 0.32, stripe_y), Color(0.78, 0.62, 0.18, 1.0), 2.0)


func _draw_sable_icon(cx: float, cy: float, r: float) -> void:
	# Matte black faceted diamond background — angular instead of round.
	var diamond: PackedVector2Array = [
		Vector2(cx, cy - r * 1.05),
		Vector2(cx + r * 0.92, cy),
		Vector2(cx, cy + r * 1.05),
		Vector2(cx - r * 0.92, cy),
	]
	draw_colored_polygon(diamond, Color(0.05, 0.06, 0.08, 1.0))
	# Subtle inner facet — slightly lighter polygon offset toward upper-left
	# so the diamond reads as 3D rather than flat.
	var facet: PackedVector2Array = [
		Vector2(cx, cy - r * 0.95),
		Vector2(cx + r * 0.18, cy - r * 0.25),
		Vector2(cx, cy + r * 0.20),
		Vector2(cx - r * 0.55, cy - r * 0.10),
	]
	draw_colored_polygon(facet, Color(0.10, 0.12, 0.16, 1.0))
	# Diamond outline.
	for i: int in 4:
		var a: Vector2 = diamond[i]
		var b: Vector2 = diamond[(i + 1) % 4]
		draw_line(a, b, Color(0.20, 0.22, 0.26, 1.0), 1.5)
	# Pale-cyan accent line — Sable's signature glow strip running
	# diagonally across the diamond face.
	var c1: Vector2 = Vector2(cx - r * 0.45, cy + r * 0.10)
	var c2: Vector2 = Vector2(cx + r * 0.55, cy - r * 0.40)
	draw_line(c1, c2, Color(0.45, 0.95, 1.0, 1.0), 2.0)
	# Small vertical kicker stroke on the right side, same neon.
	var k1: Vector2 = Vector2(cx + r * 0.22, cy + r * 0.05)
	var k2: Vector2 = Vector2(cx + r * 0.22, cy + r * 0.45)
	draw_line(k1, k2, Color(0.45, 0.95, 1.0, 1.0), 2.0)
