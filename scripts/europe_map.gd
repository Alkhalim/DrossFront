extends Control
## Stylized tactical map of Europe used by the Campaigns selection
## screen. Draws a coarse coastline silhouette + a faint compass /
## grid overlay so the menu reads as a command-room briefing. Stump
## buttons are positioned absolutely by the caller using
## get_marker_position(key); this control just paints the backdrop.

const MAP_SIZE := Vector2(760, 540)

const WATER := Color(0.06, 0.10, 0.16, 1.0)
const LAND := Color(0.18, 0.20, 0.18, 1.0)
const LAND_OUTLINE := Color(0.45, 0.55, 0.40, 0.85)
const GRID := Color(0.40, 0.55, 0.50, 0.18)
const ACCENT := Color(0.95, 0.65, 0.28, 0.55)

## Marker site keys -> normalized (0..1) positions on the map.
## Approximate latitude/longitude landings:
##   uk      = London
##   germany = Berlin
##   russia  = Moscow
##   italy   = Rome
##   cern    = Geneva (Switzerland) -- the Special Operations site
const MARKERS: Dictionary = {
	"uk":      Vector2(0.22, 0.40),
	"germany": Vector2(0.50, 0.45),
	"russia":  Vector2(0.84, 0.30),
	"italy":   Vector2(0.51, 0.74),
	"cern":    Vector2(0.43, 0.58),
}

## Coarse coastline polygon. Approximation only -- enough recognizable
## landmarks (Iberian peninsula, Italian boot, Scandinavian sweep,
## British isles, Black Sea bite) to read as Europe at a glance
## without needing an actual asset. Coordinates are in normalized
## 0..1 space; _draw scales them to MAP_SIZE.
const MAIN_LAND: PackedVector2Array = PackedVector2Array([
	# Iberia bottom
	Vector2(0.15, 0.85),
	Vector2(0.20, 0.78),
	Vector2(0.28, 0.78),
	Vector2(0.30, 0.72),
	# Southern France / Mediterranean coast
	Vector2(0.38, 0.72),
	Vector2(0.43, 0.67),
	# Italian boot
	Vector2(0.46, 0.70),
	Vector2(0.49, 0.78),
	Vector2(0.53, 0.85),
	Vector2(0.55, 0.78),
	Vector2(0.55, 0.72),
	# Balkans / Greece
	Vector2(0.60, 0.72),
	Vector2(0.62, 0.80),
	Vector2(0.64, 0.78),
	Vector2(0.66, 0.72),
	# Black Sea south coast
	Vector2(0.72, 0.70),
	Vector2(0.78, 0.66),
	# Caucasus
	Vector2(0.92, 0.60),
	# Russian east edge
	Vector2(0.98, 0.40),
	Vector2(0.96, 0.20),
	# North coast (Arctic / White Sea)
	Vector2(0.78, 0.10),
	Vector2(0.66, 0.13),
	# Scandinavia top
	Vector2(0.60, 0.08),
	Vector2(0.54, 0.05),
	Vector2(0.52, 0.18),
	Vector2(0.46, 0.30),
	# Baltic + Denmark
	Vector2(0.48, 0.36),
	Vector2(0.44, 0.40),
	Vector2(0.42, 0.36),
	Vector2(0.39, 0.32),
	# North Sea coast
	Vector2(0.32, 0.42),
	Vector2(0.28, 0.50),
	# Brittany
	Vector2(0.24, 0.55),
	Vector2(0.20, 0.62),
	# Iberia west
	Vector2(0.16, 0.72),
])

## British Isles (separate landmass).
const BRITISH_ISLES: PackedVector2Array = PackedVector2Array([
	Vector2(0.20, 0.30),
	Vector2(0.27, 0.32),
	Vector2(0.27, 0.42),
	Vector2(0.24, 0.47),
	Vector2(0.20, 0.45),
	Vector2(0.18, 0.40),
])

## Ireland.
const IRELAND: PackedVector2Array = PackedVector2Array([
	Vector2(0.13, 0.36),
	Vector2(0.17, 0.36),
	Vector2(0.17, 0.43),
	Vector2(0.13, 0.43),
])

## Sicily / Sardinia hint -- two small dots to keep the
## Mediterranean from reading completely empty.
const ISLAND_DOTS: PackedVector2Array = PackedVector2Array([
	Vector2(0.49, 0.86),  # Sicily
	Vector2(0.45, 0.78),  # Sardinia
])


func _ready() -> void:
	custom_minimum_size = MAP_SIZE


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, MAP_SIZE)
	# Water / sea backdrop.
	draw_rect(rect, WATER, true)
	# Faint grid -- 12 cols x 9 rows, spaced for a tactical-map feel.
	var cols: int = 12
	var rows: int = 9
	for c: int in cols + 1:
		var x: float = float(c) / float(cols) * MAP_SIZE.x
		draw_line(Vector2(x, 0.0), Vector2(x, MAP_SIZE.y), GRID, 1.0)
	for r: int in rows + 1:
		var y: float = float(r) / float(rows) * MAP_SIZE.y
		draw_line(Vector2(0.0, y), Vector2(MAP_SIZE.x, y), GRID, 1.0)
	# Land masses.
	_draw_land(MAIN_LAND)
	_draw_land(BRITISH_ISLES)
	_draw_land(IRELAND)
	# Mediterranean island dots.
	for p: Vector2 in ISLAND_DOTS:
		draw_circle(p * MAP_SIZE, 4.0, LAND)
		draw_arc(p * MAP_SIZE, 4.0, 0.0, TAU, 18, LAND_OUTLINE, 1.5)
	# Compass rose on the bottom-right corner -- pure decoration.
	_draw_compass(Vector2(MAP_SIZE.x - 60.0, MAP_SIZE.y - 60.0), 28.0)
	# Outer frame.
	draw_rect(rect, ACCENT, false, 2.0)


func _draw_land(poly_norm: PackedVector2Array) -> void:
	var pts: PackedVector2Array = PackedVector2Array()
	for p: Vector2 in poly_norm:
		pts.append(p * MAP_SIZE)
	draw_colored_polygon(pts, LAND)
	# Coastline outline -- redraw the perimeter so the polygon edges
	# read crisply against the dark water.
	for i: int in pts.size():
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		draw_line(a, b, LAND_OUTLINE, 1.6)


func _draw_compass(centre: Vector2, radius: float) -> void:
	# Outer ring + N/S/E/W ticks. Cosmetic.
	draw_arc(centre, radius, 0.0, TAU, 32, ACCENT, 1.2)
	draw_arc(centre, radius * 0.55, 0.0, TAU, 28, ACCENT, 0.8)
	for i: int in 4:
		var ang: float = float(i) * (PI * 0.5) - PI * 0.5
		var dir := Vector2(cos(ang), sin(ang))
		draw_line(centre + dir * (radius * 0.6), centre + dir * radius, ACCENT, 1.4)
	# 'N' tick a bit longer.
	draw_line(centre + Vector2(0.0, -radius), centre + Vector2(0.0, -radius - 8.0), ACCENT, 2.0)


func get_marker_position(key: String) -> Vector2:
	## Returns the pixel position of a marker key inside this control's
	## local coordinate space. Caller is responsible for centering the
	## marker widget on this point.
	var norm: Vector2 = MARKERS.get(key, Vector2(0.5, 0.5)) as Vector2
	return norm * MAP_SIZE
