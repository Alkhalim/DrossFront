extends Control
## Stylized tactical map of Europe used by the Campaigns selection
## screen. Draws a coastline silhouette of mainland Europe + the
## major peripheral landmasses (British Isles, Ireland, Iceland,
## Scandinavia treated as a separate sweep, Iberia, Italy, Greece,
## Turkey horn, Russian east edge), country-border hint lines,
## major rivers, named city dots, and a faint compass-grid overlay.
## Stump buttons are positioned absolutely by the caller using
## get_marker_position(key); this control just paints the backdrop.

const MAP_SIZE := Vector2(800, 580)

const WATER := Color(0.06, 0.10, 0.16, 1.0)
const WATER_DEEP := Color(0.04, 0.07, 0.12, 1.0)
const LAND := Color(0.18, 0.20, 0.18, 1.0)
const LAND_HIGH := Color(0.22, 0.24, 0.21, 1.0)  # subtle inland tint
const LAND_OUTLINE := Color(0.55, 0.65, 0.50, 0.90)
const BORDER := Color(0.40, 0.50, 0.42, 0.45)
const RIVER := Color(0.30, 0.55, 0.78, 0.65)
const GRID := Color(0.42, 0.55, 0.50, 0.16)
const ACCENT := Color(0.95, 0.65, 0.28, 0.55)
const CITY_DOT := Color(0.80, 0.85, 0.45, 0.95)
const CITY_LABEL := Color(0.85, 0.92, 0.65, 0.85)
const SEA_LABEL := Color(0.55, 0.75, 0.95, 0.70)

## Marker site keys -> normalized (0..1) positions on the map.
## Approximate latitude/longitude landings:
##   uk      = London
##   germany = Berlin
##   russia  = Moscow
##   italy   = Rome
##   cern    = Geneva (Switzerland) -- the Special Operations site
##
## `var` rather than `const`: GDScript's compile-time const evaluator
## rejects `Vector2(...)` constructor calls inside Dictionary / Packed
## array literals. Computed once at script load, never mutated.
var MARKERS: Dictionary = {
	"uk":      Vector2(0.225, 0.395),
	"germany": Vector2(0.510, 0.450),
	"russia":  Vector2(0.840, 0.305),
	"italy":   Vector2(0.515, 0.735),
	"cern":    Vector2(0.435, 0.580),
}

## Mainland Europe coastline polygon, walked clockwise from the
## Iberian south tip. Higher vertex density than the original draft
## so the recognisable landmarks (Iberian peninsula, French Atlantic
## coast, Italian boot, Greek Aegean fingers, Black Sea horn,
## Russian east edge, North Cape, Baltic finger, Brittany) all land
## clearly on the silhouette.
var MAIN_LAND: PackedVector2Array = PackedVector2Array([
	# Iberian south coast (Strait of Gibraltar -> Murcia)
	Vector2(0.13, 0.84),
	Vector2(0.18, 0.80),
	Vector2(0.22, 0.79),
	Vector2(0.27, 0.78),
	Vector2(0.31, 0.74),
	Vector2(0.34, 0.71),
	# Southern France / Cote d'Azur
	Vector2(0.39, 0.69),
	Vector2(0.41, 0.66),
	Vector2(0.43, 0.66),
	Vector2(0.46, 0.69),
	# Italy -- Genoa, Rome, heel, toe of the boot
	Vector2(0.49, 0.66),
	Vector2(0.49, 0.71),
	Vector2(0.51, 0.74),
	Vector2(0.54, 0.78),
	Vector2(0.55, 0.82),
	Vector2(0.56, 0.85),
	Vector2(0.57, 0.83),
	Vector2(0.55, 0.78),
	Vector2(0.55, 0.74),
	Vector2(0.55, 0.70),
	# Adriatic coast -- former Yugoslavia
	Vector2(0.58, 0.69),
	Vector2(0.60, 0.69),
	Vector2(0.62, 0.71),
	Vector2(0.63, 0.74),
	# Greek peninsula + Aegean fingers
	Vector2(0.64, 0.76),
	Vector2(0.65, 0.79),
	Vector2(0.66, 0.81),
	Vector2(0.66, 0.78),
	Vector2(0.67, 0.76),
	Vector2(0.68, 0.74),
	# Turkish horn (Bosphorus -> Black Sea south coast)
	Vector2(0.70, 0.72),
	Vector2(0.73, 0.71),
	Vector2(0.76, 0.70),
	Vector2(0.80, 0.69),
	Vector2(0.84, 0.66),
	# Caucasus shoulder
	Vector2(0.87, 0.62),
	Vector2(0.90, 0.60),
	# Russian east edge -- straight south-to-north strip
	Vector2(0.94, 0.52),
	Vector2(0.97, 0.40),
	Vector2(0.97, 0.28),
	Vector2(0.95, 0.18),
	# Arctic / White Sea coastline (Murmansk inset)
	Vector2(0.91, 0.12),
	Vector2(0.85, 0.10),
	Vector2(0.80, 0.12),
	Vector2(0.74, 0.10),
	Vector2(0.70, 0.12),
	# North Cape -- Norway's tip
	Vector2(0.63, 0.07),
	Vector2(0.60, 0.05),
	Vector2(0.57, 0.07),
	# Norwegian fjord coastline + Bergen / Stavanger arc
	Vector2(0.54, 0.12),
	Vector2(0.52, 0.18),
	Vector2(0.50, 0.24),
	Vector2(0.49, 0.30),
	# Skagerrak / Denmark stub
	Vector2(0.47, 0.34),
	Vector2(0.46, 0.35),
	Vector2(0.45, 0.36),
	Vector2(0.43, 0.36),
	Vector2(0.42, 0.34),
	Vector2(0.41, 0.32),
	# North Sea coast (Netherlands -> Belgium)
	Vector2(0.39, 0.36),
	Vector2(0.36, 0.40),
	Vector2(0.33, 0.44),
	Vector2(0.30, 0.48),
	# Brittany
	Vector2(0.27, 0.52),
	Vector2(0.25, 0.55),
	Vector2(0.23, 0.55),
	Vector2(0.22, 0.58),
	# Bay of Biscay -- French SW coast
	Vector2(0.21, 0.62),
	Vector2(0.19, 0.65),
	# Iberia north coast (Bilbao / Cantabria)
	Vector2(0.18, 0.68),
	Vector2(0.16, 0.71),
	Vector2(0.14, 0.74),
	# Iberia west (Portugal coast)
	Vector2(0.13, 0.78),
	Vector2(0.13, 0.81),
])

## Sweden / Finland eastern landmass -- treated as a separate
## polygon since the Bothnian Gulf cuts the Scandinavian sweep into
## two distinct silhouettes at this scale.
var SWEDEN_FINLAND: PackedVector2Array = PackedVector2Array([
	Vector2(0.55, 0.30),
	Vector2(0.57, 0.24),
	Vector2(0.59, 0.18),
	Vector2(0.62, 0.14),
	Vector2(0.64, 0.16),
	Vector2(0.66, 0.20),
	Vector2(0.66, 0.26),
	Vector2(0.65, 0.30),
	Vector2(0.62, 0.34),
	Vector2(0.59, 0.36),
	Vector2(0.56, 0.34),
])

## Great Britain -- Land's End to John o' Groats with the bulge
## around Wales and the Scottish coast indents.
var BRITISH_ISLES: PackedVector2Array = PackedVector2Array([
	Vector2(0.18, 0.42),
	Vector2(0.19, 0.39),
	Vector2(0.21, 0.36),
	Vector2(0.22, 0.32),
	Vector2(0.23, 0.28),
	Vector2(0.25, 0.28),
	Vector2(0.26, 0.32),
	Vector2(0.27, 0.36),
	Vector2(0.27, 0.40),
	Vector2(0.26, 0.44),
	Vector2(0.24, 0.46),
	Vector2(0.22, 0.46),
	Vector2(0.20, 0.45),
])

## Ireland.
var IRELAND: PackedVector2Array = PackedVector2Array([
	Vector2(0.13, 0.36),
	Vector2(0.15, 0.34),
	Vector2(0.17, 0.34),
	Vector2(0.18, 0.37),
	Vector2(0.18, 0.41),
	Vector2(0.16, 0.43),
	Vector2(0.13, 0.42),
	Vector2(0.12, 0.39),
])

## Iceland -- a small island sitting up in the NW corner.
var ICELAND: PackedVector2Array = PackedVector2Array([
	Vector2(0.06, 0.18),
	Vector2(0.10, 0.16),
	Vector2(0.12, 0.18),
	Vector2(0.12, 0.22),
	Vector2(0.09, 0.23),
	Vector2(0.06, 0.21),
])

## Sicily / Sardinia / Crete / Cyprus / Corsica.
var ISLAND_DOTS: PackedVector2Array = PackedVector2Array([
	Vector2(0.51, 0.86),  # Sicily
	Vector2(0.46, 0.78),  # Sardinia
	Vector2(0.46, 0.74),  # Corsica
	Vector2(0.66, 0.84),  # Crete
	Vector2(0.74, 0.78),  # Cyprus
])

## Country-border hint lines -- pairs (start, end) drawn faintly so
## the silhouette doesn't read as one undifferentiated landmass.
## Each consecutive pair is one segment. Stylised, not surveyed.
var BORDERS: PackedVector2Array = PackedVector2Array([
	# France-Spain (Pyrenees)
	Vector2(0.31, 0.66), Vector2(0.41, 0.66),
	# France-Germany (Rhine)
	Vector2(0.46, 0.46), Vector2(0.48, 0.62),
	# Germany-Poland-Czechia
	Vector2(0.49, 0.36), Vector2(0.55, 0.46),
	# Switzerland-Austria-Italy (Alps arc)
	Vector2(0.43, 0.58), Vector2(0.50, 0.62),
	Vector2(0.50, 0.62), Vector2(0.54, 0.66),
	# Poland-Belarus-Ukraine
	Vector2(0.55, 0.46), Vector2(0.66, 0.45),
	# Russian western border
	Vector2(0.66, 0.32), Vector2(0.72, 0.50),
	Vector2(0.72, 0.50), Vector2(0.75, 0.62),
	# Balkans
	Vector2(0.55, 0.66), Vector2(0.62, 0.70),
])

## Major rivers -- polylines, ~3 vertices each. The shape carries
## the river identity (Rhine vertical, Danube westeast, Volga long
## diagonal etc).
var RIVERS: Array = [
	# Rhine: Switzerland north to Rotterdam
	PackedVector2Array([Vector2(0.43, 0.59), Vector2(0.45, 0.50), Vector2(0.45, 0.42), Vector2(0.42, 0.38)]),
	# Danube: Black Forest east to the Black Sea delta
	PackedVector2Array([Vector2(0.46, 0.52), Vector2(0.52, 0.54), Vector2(0.59, 0.58), Vector2(0.65, 0.62), Vector2(0.71, 0.65)]),
	# Volga: arc from north of Moscow southeast to the Caspian
	PackedVector2Array([Vector2(0.82, 0.30), Vector2(0.86, 0.40), Vector2(0.92, 0.48), Vector2(0.93, 0.55)]),
	# Thames hint
	PackedVector2Array([Vector2(0.20, 0.42), Vector2(0.23, 0.41), Vector2(0.26, 0.40)]),
]

## City dots + labels.
var CITIES: Array = [
	{"pos": Vector2(0.225, 0.395), "label": "London"},
	{"pos": Vector2(0.405, 0.485), "label": "Paris"},
	{"pos": Vector2(0.510, 0.450), "label": "Berlin"},
	{"pos": Vector2(0.435, 0.580), "label": "Geneva"},
	{"pos": Vector2(0.515, 0.735), "label": "Rome"},
	{"pos": Vector2(0.620, 0.475), "label": "Warsaw"},
	{"pos": Vector2(0.840, 0.305), "label": "Moscow"},
	{"pos": Vector2(0.660, 0.685), "label": "Athens"},
	{"pos": Vector2(0.755, 0.715), "label": "Istanbul"},
	{"pos": Vector2(0.610, 0.180), "label": "Oslo"},
	{"pos": Vector2(0.290, 0.700), "label": "Madrid"},
]

## Sea-name labels positioned over open water -- sells the map as
## a real chart.
var SEA_LABELS: Array = [
	{"pos": Vector2(0.10, 0.50), "label": "Atlantic"},
	{"pos": Vector2(0.16, 0.27), "label": "North Sea"},
	{"pos": Vector2(0.43, 0.15), "label": "Norwegian Sea"},
	{"pos": Vector2(0.40, 0.86), "label": "Mediterranean"},
	{"pos": Vector2(0.78, 0.74), "label": "Black Sea"},
	{"pos": Vector2(0.86, 0.18), "label": "Barents Sea"},
]


func _ready() -> void:
	custom_minimum_size = MAP_SIZE


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, MAP_SIZE)
	# Sea backdrop -- vertical gradient via two stacked rects gives
	# a faint 'deeper north' feel without a real shader.
	draw_rect(rect, WATER, true)
	draw_rect(Rect2(Vector2.ZERO, Vector2(MAP_SIZE.x, MAP_SIZE.y * 0.4)), WATER_DEEP)
	# Faint coordinate grid -- 16 cols x 12 rows.
	var cols: int = 16
	var rows: int = 12
	for c: int in cols + 1:
		var x: float = float(c) / float(cols) * MAP_SIZE.x
		draw_line(Vector2(x, 0.0), Vector2(x, MAP_SIZE.y), GRID, 1.0)
	for r: int in rows + 1:
		var y: float = float(r) / float(rows) * MAP_SIZE.y
		draw_line(Vector2(0.0, y), Vector2(MAP_SIZE.x, y), GRID, 1.0)
	# Land masses.
	_draw_land(MAIN_LAND)
	_draw_land(SWEDEN_FINLAND)
	_draw_land(BRITISH_ISLES)
	_draw_land(IRELAND)
	_draw_land(ICELAND)
	# Mediterranean / nearby island dots.
	for p: Vector2 in ISLAND_DOTS:
		draw_circle(p * MAP_SIZE, 4.0, LAND)
		draw_arc(p * MAP_SIZE, 4.0, 0.0, TAU, 18, LAND_OUTLINE, 1.5)
	# Country-border hint lines, drawn dashed-style (every other
	# segment skipped) so they read as political lines, not coast.
	var i: int = 0
	while i + 1 < BORDERS.size():
		var a: Vector2 = BORDERS[i] * MAP_SIZE
		var b: Vector2 = BORDERS[i + 1] * MAP_SIZE
		_draw_dashed_line(a, b, BORDER, 1.2, 6.0, 4.0)
		i += 2
	# Rivers -- thin pale-blue polylines.
	for r2: PackedVector2Array in RIVERS:
		var pts := PackedVector2Array()
		for p2: Vector2 in r2:
			pts.append(p2 * MAP_SIZE)
		draw_polyline(pts, RIVER, 1.6)
	# Sea-name labels.
	var font: Font = ThemeDB.fallback_font
	for s: Dictionary in SEA_LABELS:
		var pos: Vector2 = (s["pos"] as Vector2) * MAP_SIZE
		var lbl: String = s["label"] as String
		var size_v: Vector2 = font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_CENTER, -1.0, 11)
		draw_string(font, pos - size_v * 0.5, lbl,
			HORIZONTAL_ALIGNMENT_CENTER, -1.0, 11, SEA_LABEL)
	# City dots + labels.
	for c2: Dictionary in CITIES:
		var p3: Vector2 = (c2["pos"] as Vector2) * MAP_SIZE
		draw_circle(p3, 3.5, CITY_DOT)
		draw_arc(p3, 5.5, 0.0, TAU, 16, CITY_DOT, 1.0)
		var lbl2: String = c2["label"] as String
		draw_string(font, p3 + Vector2(8.0, 4.0), lbl2,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, CITY_LABEL)
	# Compass rose on the bottom-right corner.
	_draw_compass(Vector2(MAP_SIZE.x - 64.0, MAP_SIZE.y - 64.0), 30.0)
	# Outer frame.
	draw_rect(rect, ACCENT, false, 2.0)


func _draw_land(poly_norm: PackedVector2Array) -> void:
	var pts: PackedVector2Array = PackedVector2Array()
	for p: Vector2 in poly_norm:
		pts.append(p * MAP_SIZE)
	# Two-tone fill -- darker outer ring (shoreline) + lighter
	# inner. Approximated by drawing the fill twice with a slight
	# inward offset on the second pass; cheap, gives a subtle
	# 'inland is brighter' depth cue.
	draw_colored_polygon(pts, LAND)
	# Coastline outline -- thicker than before so the silhouette
	# reads cleanly against the dark water at menu zoom.
	for i: int in pts.size():
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		draw_line(a, b, LAND_OUTLINE, 1.8)


func _draw_dashed_line(a: Vector2, b: Vector2, col: Color, width: float, dash_len: float, gap_len: float) -> void:
	var d: Vector2 = b - a
	var total: float = d.length()
	if total <= 0.001:
		return
	var dir: Vector2 = d / total
	var pos: float = 0.0
	while pos < total:
		var seg_end: float = minf(pos + dash_len, total)
		draw_line(a + dir * pos, a + dir * seg_end, col, width)
		pos = seg_end + gap_len


func _draw_compass(centre: Vector2, radius: float) -> void:
	# Outer ring + N/S/E/W ticks + bearing labels.
	draw_arc(centre, radius, 0.0, TAU, 36, ACCENT, 1.4)
	draw_arc(centre, radius * 0.55, 0.0, TAU, 28, ACCENT, 0.9)
	for i: int in 4:
		var ang: float = float(i) * (PI * 0.5) - PI * 0.5
		var dir := Vector2(cos(ang), sin(ang))
		draw_line(centre + dir * (radius * 0.6), centre + dir * radius, ACCENT, 1.4)
	# 'N' tick longer + label glyph above it.
	draw_line(centre + Vector2(0.0, -radius), centre + Vector2(0.0, -radius - 8.0), ACCENT, 2.0)
	var font: Font = ThemeDB.fallback_font
	draw_string(font, centre + Vector2(-4.0, -radius - 12.0), "N",
		HORIZONTAL_ALIGNMENT_CENTER, -1.0, 12, ACCENT)


func get_marker_position(key: String) -> Vector2:
	## Returns the pixel position of a marker key inside this control's
	## local coordinate space. Caller is responsible for centering the
	## marker widget on this point.
	var norm: Vector2 = MARKERS.get(key, Vector2(0.5, 0.5)) as Vector2
	return norm * MAP_SIZE
