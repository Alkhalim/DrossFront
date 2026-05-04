extends Control
## Stylized tactical map of Europe used by the Campaigns selection
## screen. All coastline points + city positions land at their real
## lat/lon, normalized to a bounding box that covers Iceland in the
## NW, North Cape in the N, the Caspian shoulder in the E, and the
## Mediterranean in the S. The polygon coordinates were derived from
## real geographic vertices and converted via _ll() so the silhouette
## matches what the player expects when they look at Europe.

## Map render size. The campaigns screen anchors this Control
## full-rect; the map paints inside its own intrinsic size, so this
## directly drives how much screen space the map takes.
const MAP_SIZE := Vector2(1280, 800)

# Bounding box (lon_west, lon_east, lat_south, lat_north).
const LON_W: float = -25.0
const LON_E: float = 45.0
const LAT_S: float = 35.0
const LAT_N: float = 72.0


static func _ll(lon: float, lat: float) -> Vector2:
	## Real (longitude, latitude) -> normalized 0..1 coordinates on
	## the map. Y is inverted because screen Y grows downward.
	return Vector2(
		(lon - LON_W) / (LON_E - LON_W),
		1.0 - (lat - LAT_S) / (LAT_N - LAT_S),
	)


# --- Palette --------------------------------------------------------

const WATER := Color(0.06, 0.10, 0.16, 1.0)
const WATER_DEEP := Color(0.04, 0.07, 0.12, 1.0)
const LAND := Color(0.20, 0.22, 0.20, 1.0)
const LAND_OUTLINE := Color(0.55, 0.65, 0.50, 0.90)
const BORDER := Color(0.42, 0.52, 0.44, 0.50)
const RIVER := Color(0.30, 0.55, 0.78, 0.65)
const GRID := Color(0.42, 0.55, 0.50, 0.14)
const ACCENT := Color(0.95, 0.65, 0.28, 0.55)
const CITY_DOT := Color(0.85, 0.90, 0.55, 0.95)
const CITY_LABEL := Color(0.88, 0.94, 0.70, 0.90)
const SEA_LABEL := Color(0.55, 0.78, 0.95, 0.65)


# --- Marker positions (driven by real city coordinates) ------------

var MARKERS: Dictionary = {
	"uk":      _ll(-0.13,  51.51),  # London
	"germany": _ll(13.40,  52.52),  # Berlin
	"russia":  _ll(37.62,  55.75),  # Moscow
	"italy":   _ll(12.50,  41.90),  # Rome
	"cern":    _ll( 6.14,  46.20),  # Geneva (CERN)
}


# --- Coastlines ----------------------------------------------------

## Each landmass is a separate SIMPLE polygon (no self-intersections,
## consistent clockwise winding) so draw_colored_polygon fills them
## reliably. Peninsulas (Italian boot, Greek finger) and complex
## inlets (Bothnian Gulf, Skagerrak) are split into their own
## polygons rather than tracebacks on a single outline -- that was
## why the previous version filled only the British Isles cleanly.

## Iberian peninsula -- closed shape from Gibraltar around the
## coast and back via the Pyrenees ridge.
var IBERIA: PackedVector2Array = PackedVector2Array([
	_ll(-5.6, 36.0),    # Gibraltar
	_ll(-2.9, 36.7),    # Almeria
	_ll(-0.5, 38.3),    # Alicante
	_ll( 1.0, 41.0),    # Tarragona
	_ll( 3.2, 42.4),    # Pyrenees east end
	_ll(-1.5, 43.5),    # Pyrenees west end (Biarritz)
	_ll(-2.93, 43.26),  # Bilbao
	_ll(-7.0, 43.7),    # Galicia
	_ll(-9.27, 42.88),  # Cape Finisterre
	_ll(-9.14, 38.72),  # Lisbon
	_ll(-8.99, 37.02),  # Cape Saint Vincent
])

## France -- bordered by Pyrenees, Med, Alps, Rhine, Channel,
## Atlantic.
var FRANCE: PackedVector2Array = PackedVector2Array([
	_ll(-1.5, 43.5),    # Biarritz
	_ll( 3.2, 42.4),    # Pyrenees east
	_ll( 5.4, 43.3),    # Marseille
	_ll( 7.3, 43.7),    # Nice
	_ll( 8.0, 46.5),    # Mont Blanc shoulder
	_ll( 8.2, 49.0),    # Rhine valley north
	_ll( 6.6, 51.2),    # Belgian border
	_ll( 3.7, 51.4),    # Belgian coast
	_ll( 1.6, 50.95),   # Calais
	_ll(-1.6, 49.65),   # Cherbourg
	_ll(-4.49, 48.39),  # Brest
	_ll(-2.16, 47.28),  # Saint-Nazaire
	_ll(-1.55, 46.16),  # La Rochelle
])

## Benelux + northern Germany + Denmark base.
var GERMANY_BENELUX: PackedVector2Array = PackedVector2Array([
	_ll( 3.7, 51.4),    # Belgian coast
	_ll( 6.6, 51.2),    # France-Germany border
	_ll( 8.2, 49.0),    # Rhine valley
	_ll( 8.2, 47.7),    # Lake Constance
	_ll(13.5, 49.0),    # Czech border NE
	_ll(14.5, 53.5),    # Oder mouth
	_ll(11.0, 54.5),    # Baltic coast (north Germany)
	_ll( 9.5, 54.8),    # Schleswig
	_ll( 8.5, 55.0),    # Esbjerg
	_ll( 8.8, 53.55),   # Hamburg approach
	_ll( 7.0, 53.5),    # Bremerhaven
	_ll( 4.9, 52.37),   # Amsterdam
])

## Central / Eastern Europe -- Poland, Czech, Austria, Slovakia,
## Hungary, Romania, Balkans north.
var CENTRAL_EUROPE: PackedVector2Array = PackedVector2Array([
	_ll( 8.0, 46.5),    # Alps W
	_ll(13.5, 46.7),    # Brenner
	_ll(13.5, 49.0),    # Czech border NW
	_ll(14.5, 53.5),    # Oder mouth
	_ll(19.0, 54.5),    # Polish-Russian border
	_ll(23.0, 54.0),    # Suwalki gap
	_ll(23.6, 49.0),    # Lviv
	_ll(28.6, 44.2),    # Constanta (Black Sea)
	_ll(22.5, 45.0),    # Iron Gate of the Danube
	_ll(19.0, 44.0),    # Belgrade
	_ll(15.5, 46.0),    # Slovenian border
	_ll(13.5, 46.7),    # back to Brenner area
])

## Russian western heartland -- big block from the Polish border
## east to the bounding edge.
var RUSSIA: PackedVector2Array = PackedVector2Array([
	_ll(23.0, 54.0),    # Suwalki
	_ll(28.0, 60.0),    # St Petersburg approach
	_ll(28.5, 69.5),    # Norwegian-Russian border
	_ll(33.1, 68.97),   # Murmansk
	_ll(38.0, 68.5),    # Murmansk approach
	_ll(43.0, 67.0),    # Severodvinsk hint
	_ll(45.0, 60.0),    # bounding edge
	_ll(45.0, 50.0),    # bounding edge south
	_ll(45.0, 47.5),    # Caspian shoulder
	_ll(38.5, 47.5),    # Don river
	_ll(34.5, 46.5),    # Crimea
	_ll(30.5, 46.0),    # Odessa
	_ll(28.6, 44.2),    # Constanta
	_ll(23.6, 49.0),    # Lviv
])

## Caucasus + Anatolia south coast.
var ANATOLIA: PackedVector2Array = PackedVector2Array([
	_ll(45.0, 41.7),    # Caspian shoulder
	_ll(45.0, 47.5),    # bounding south
	_ll(38.5, 47.5),    # Don
	_ll(38.0, 45.0),    # Sea of Azov east
	_ll(41.5, 41.5),    # Batumi
	_ll(36.2, 36.6),    # Iskenderun
	_ll(34.7, 36.6),    # Adana
	_ll(31.0, 36.8),    # Antalya
	_ll(28.0, 36.7),    # Marmaris
	_ll(26.5, 38.4),    # Izmir
	_ll(26.0, 40.4),    # Dardanelles
	_ll(28.98, 41.01),  # Istanbul
	_ll(35.0, 42.0),    # Sinop
	_ll(41.7, 41.5),    # Trabzon
])

## Italian boot -- separate peninsula polygon.
var ITALY: PackedVector2Array = PackedVector2Array([
	_ll( 7.3, 43.7),    # Riviera
	_ll( 8.9, 44.4),    # Genoa
	_ll(10.5, 45.0),    # Po valley north
	_ll(13.9, 45.7),    # Trieste
	_ll(13.9, 44.9),    # Pula
	_ll(15.0, 41.5),    # Adriatic mid
	_ll(17.9, 40.6),    # Brindisi (heel)
	_ll(18.5, 40.0),    # Lecce
	_ll(17.0, 39.0),    # Gulf of Taranto
	_ll(15.6, 38.1),    # Reggio (toe)
	_ll(13.5, 39.5),    # Salerno
	_ll(14.3, 40.8),    # Naples
	_ll(12.4, 41.9),    # Rome
	_ll(11.2, 43.5),    # Pisa
])

## Balkans + Greek peninsula.
var BALKANS: PackedVector2Array = PackedVector2Array([
	_ll(15.5, 46.0),    # Slovenian border
	_ll(19.0, 44.0),    # Belgrade
	_ll(22.5, 45.0),    # Iron Gate
	_ll(28.6, 44.2),    # Constanta
	_ll(28.0, 41.5),    # Bulgarian Black Sea
	_ll(26.0, 40.4),    # Dardanelles
	_ll(24.0, 40.5),    # Macedonia coast
	_ll(23.7, 37.98),   # Athens
	_ll(22.5, 37.0),    # Peloponnese
	_ll(21.0, 38.5),    # Patras
	_ll(19.3, 41.3),    # Durres
	_ll(18.1, 42.6),    # Dubrovnik
	_ll(16.4, 43.5),    # Split
	_ll(15.2, 44.1),    # Zadar
	_ll(13.9, 45.7),    # Trieste
])

## Scandinavia (Norway + Sweden + Finland as a single landmass).
var SCANDINAVIA: PackedVector2Array = PackedVector2Array([
	# Norway south coast east through Skagerrak
	_ll( 5.73, 58.97),  # Stavanger
	_ll( 8.0,  58.4),   # Norway south coast
	_ll(11.3, 58.4),    # Gothenburg
	_ll(12.6, 56.0),    # Malmo
	_ll(14.5, 56.2),    # Karlskrona
	_ll(17.0, 57.0),    # Kalmar
	_ll(18.07, 59.33),  # Stockholm
	# Bothnian Gulf -- Finland east coast
	_ll(22.0, 60.0),    # Turku
	_ll(24.95, 60.17),  # Helsinki
	_ll(28.0, 60.6),    # Vyborg
	_ll(30.0, 62.5),    # Karelia
	_ll(28.0, 64.0),    # Karelian north
	_ll(25.5, 65.0),    # Oulu
	_ll(24.0, 65.9),    # Tornio
	# Up Finland to Lapland
	_ll(27.5, 68.5),    # Inari
	_ll(28.5, 69.5),    # Norwegian border
	# Norway arctic + fjord coast back south
	_ll(25.8, 71.17),   # North Cape
	_ll(20.0, 70.0),    # Hammerfest
	_ll(18.96, 69.65),  # Tromso
	_ll(14.0, 67.5),    # Bodo
	_ll(10.5, 63.43),   # Trondheim
	_ll( 5.32, 60.39),  # Bergen
])

## Denmark + Jutland peninsula -- separate from Germany so the
## Skagerrak / Kattegat reads as water.
var DENMARK: PackedVector2Array = PackedVector2Array([
	_ll( 8.5, 55.0),    # Esbjerg
	_ll( 8.0, 56.5),    # Jutland west
	_ll(10.7, 57.7),    # Skagen
	_ll(12.5, 56.0),    # Zealand east
	_ll(11.5, 55.0),    # Lolland
	_ll( 9.5, 54.8),    # Schleswig
])

## Great Britain (Scotland + England + Wales).
var BRITISH_ISLES: PackedVector2Array = PackedVector2Array([
	_ll(-5.71, 50.07),  # Land's End
	_ll(-4.20, 50.40),  # Plymouth
	_ll(-1.40, 50.74),  # Portsmouth
	_ll( 1.31, 51.13),  # Dover
	_ll( 1.85, 52.50),  # East Anglia
	_ll(-1.45, 53.83),  # Hull / Yorkshire
	_ll(-1.20, 55.00),  # Newcastle
	_ll(-2.10, 56.50),  # St Andrews
	_ll(-3.19, 55.95),  # Edinburgh
	_ll(-2.50, 57.50),  # Aberdeen
	_ll(-3.07, 58.64),  # John o'Groats
	_ll(-5.00, 58.62),  # Cape Wrath
	_ll(-5.50, 56.70),  # West Highlands
	_ll(-5.10, 54.65),  # Kintyre
	_ll(-3.60, 54.20),  # Cumbrian coast
	_ll(-4.50, 53.30),  # North Wales
	_ll(-5.20, 51.70),  # West Wales / Pembroke
	_ll(-3.50, 51.50),  # Bristol Channel
])

## Ireland.
var IRELAND: PackedVector2Array = PackedVector2Array([
	_ll(-10.27, 51.99),  # Kerry SW
	_ll(-8.50,  51.85),  # Cork
	_ll(-6.27,  52.20),  # Wexford
	_ll(-6.27,  53.35),  # Dublin
	_ll(-6.20,  54.60),  # Belfast
	_ll(-7.30,  55.35),  # Malin Head
	_ll(-9.04,  53.27),  # Galway
	_ll(-10.10, 52.50),  # Brandon Bay
])

## Iceland.
var ICELAND: PackedVector2Array = PackedVector2Array([
	_ll(-22.90, 64.10),  # Reykjavik area
	_ll(-21.50, 65.60),  # Akureyri approach
	_ll(-17.34, 66.05),  # Husavik
	_ll(-14.50, 65.50),  # East fjords
	_ll(-13.50, 64.30),  # Hofn
	_ll(-19.00, 63.40),  # Vik
	_ll(-22.50, 63.80),  # Keflavik
])

## Mediterranean / Aegean / Black-Sea islands -- single-vertex dots.
var ISLAND_DOTS: PackedVector2Array = PackedVector2Array([
	_ll(14.27, 37.50),  # Sicily
	_ll( 9.10, 40.10),  # Sardinia
	_ll( 9.20, 42.20),  # Corsica
	_ll(25.00, 35.30),  # Crete
	_ll(33.50, 35.00),  # Cyprus
	_ll(28.20, 36.40),  # Rhodes
	_ll(-3.50, 39.50),  # placeholder for Balearics? (Mallorca is at 2.65E, 39.57N)
	_ll( 2.65, 39.57),  # Mallorca
])

## Country-border hint segments (start, end pairs). Stylised, not
## surveyed. Drawn as faint dashed lines so the silhouette doesn't
## read as one undifferentiated landmass.
var BORDERS: PackedVector2Array = PackedVector2Array([
	# France-Spain (Pyrenees)
	_ll(-1.5, 43.3), _ll(3.2, 42.4),
	# France-Italy (Alps W)
	_ll(7.0, 43.9), _ll(8.0, 46.5),
	# France-Germany (Rhine)
	_ll(8.2, 47.7), _ll(8.2, 51.0),
	# Germany-Czechia / Austria
	_ll(8.2, 48.0), _ll(13.5, 49.0),
	_ll(13.5, 49.0), _ll(17.0, 48.5),
	# Italy-Austria (Brenner)
	_ll(8.0, 46.5), _ll(13.5, 46.7),
	# Germany-Poland (Oder)
	_ll(13.5, 49.0), _ll(14.5, 53.5),
	# Poland-Belarus / Ukraine
	_ll(23.0, 54.0), _ll(23.6, 51.5),
	_ll(23.6, 51.5), _ll(22.5, 49.0),
	# Russia western border
	_ll(28.0, 60.0), _ll(35.0, 51.0),
	_ll(35.0, 51.0), _ll(45.0, 49.0),
	# Balkans (rough)
	_ll(19.3, 42.5), _ll(22.0, 42.0),
	_ll(22.0, 42.0), _ll(26.0, 41.5),
])

## Major rivers (polylines).
var RIVERS: Array = [
	# Rhine: Lake Constance -> Rotterdam
	PackedVector2Array([_ll(9.0, 47.5), _ll(7.6, 47.6), _ll(7.6, 49.5), _ll(6.6, 51.2), _ll(4.5, 51.9)]),
	# Danube: Black Forest -> Black Sea delta
	PackedVector2Array([_ll(8.2, 48.0), _ll(11.6, 48.4), _ll(16.4, 48.2), _ll(19.0, 47.5), _ll(21.0, 45.3), _ll(28.7, 45.2)]),
	# Volga: source NW of Moscow -> Caspian
	PackedVector2Array([_ll(33.0, 57.0), _ll(37.0, 56.5), _ll(43.0, 56.3), _ll(47.0, 53.5)]),
	# Dnieper / Dnipro
	PackedVector2Array([_ll(31.0, 55.0), _ll(31.5, 50.4), _ll(34.6, 47.0), _ll(32.6, 46.4)]),
	# Thames
	PackedVector2Array([_ll(-1.7, 51.7), _ll(-0.5, 51.5), _ll(0.7, 51.5)]),
	# Po: Italian plain
	PackedVector2Array([_ll(7.5, 45.0), _ll(10.5, 45.1), _ll(12.5, 44.9)]),
]

## City dots + labels. All at real lat/lon.
var CITIES: Array = [
	{"pos": _ll(-0.13, 51.51), "label": "London"},
	{"pos": _ll(-3.70, 40.42), "label": "Madrid"},
	{"pos": _ll(-9.14, 38.72), "label": "Lisbon"},
	{"pos": _ll(2.35,  48.86), "label": "Paris"},
	{"pos": _ll(6.14,  46.20), "label": "Geneva"},
	{"pos": _ll(8.55,  47.37), "label": "Zurich"},
	{"pos": _ll(13.40, 52.52), "label": "Berlin"},
	{"pos": _ll(4.90,  52.37), "label": "Amsterdam"},
	{"pos": _ll(12.50, 41.90), "label": "Rome"},
	{"pos": _ll(16.37, 48.21), "label": "Vienna"},
	{"pos": _ll(14.42, 50.08), "label": "Prague"},
	{"pos": _ll(21.01, 52.23), "label": "Warsaw"},
	{"pos": _ll(30.52, 50.45), "label": "Kyiv"},
	{"pos": _ll(37.62, 55.75), "label": "Moscow"},
	{"pos": _ll(30.34, 59.94), "label": "St Petersburg"},
	{"pos": _ll(23.73, 37.98), "label": "Athens"},
	{"pos": _ll(28.98, 41.01), "label": "Istanbul"},
	{"pos": _ll(18.07, 59.33), "label": "Stockholm"},
	{"pos": _ll(10.75, 59.91), "label": "Oslo"},
	{"pos": _ll(12.57, 55.68), "label": "Copenhagen"},
	{"pos": _ll(24.95, 60.17), "label": "Helsinki"},
	{"pos": _ll(-21.94, 64.13), "label": "Reykjavik"},
	{"pos": _ll(-6.27, 53.35), "label": "Dublin"},
]

## Sea / ocean labels.
var SEA_LABELS: Array = [
	{"pos": _ll(-15.0, 50.0), "label": "ATLANTIC"},
	{"pos": _ll( 4.0, 56.0), "label": "NORTH SEA"},
	{"pos": _ll( 5.0, 64.0), "label": "NORWEGIAN SEA"},
	{"pos": _ll(40.0, 70.0), "label": "BARENTS SEA"},
	{"pos": _ll( 5.0, 39.0), "label": "MEDITERRANEAN"},
	{"pos": _ll(34.0, 43.5), "label": "BLACK SEA"},
	{"pos": _ll(20.0, 58.0), "label": "BALTIC"},
	{"pos": _ll(43.0, 44.5), "label": "CASPIAN"},
]


func _ready() -> void:
	custom_minimum_size = MAP_SIZE


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, MAP_SIZE)
	# Sea backdrop -- slightly deeper colour in the north for chart
	# depth.
	draw_rect(rect, WATER, true)
	draw_rect(Rect2(Vector2.ZERO, Vector2(MAP_SIZE.x, MAP_SIZE.y * 0.35)), WATER_DEEP)
	# Faint coordinate grid -- 14 cols x 12 rows.
	var cols: int = 14
	var rows: int = 12
	for c: int in cols + 1:
		var x: float = float(c) / float(cols) * MAP_SIZE.x
		draw_line(Vector2(x, 0.0), Vector2(x, MAP_SIZE.y), GRID, 1.0)
	for r: int in rows + 1:
		var y: float = float(r) / float(rows) * MAP_SIZE.y
		draw_line(Vector2(0.0, y), Vector2(MAP_SIZE.x, y), GRID, 1.0)
	# Land masses -- all clean simple polygons so each fills with
	# the LAND tone via draw_colored_polygon.
	_draw_land(IBERIA)
	_draw_land(FRANCE)
	_draw_land(GERMANY_BENELUX)
	_draw_land(CENTRAL_EUROPE)
	_draw_land(RUSSIA)
	_draw_land(ANATOLIA)
	_draw_land(ITALY)
	_draw_land(BALKANS)
	_draw_land(SCANDINAVIA)
	_draw_land(DENMARK)
	_draw_land(BRITISH_ISLES)
	_draw_land(IRELAND)
	_draw_land(ICELAND)
	# Mediterranean / nearby island dots.
	for p: Vector2 in ISLAND_DOTS:
		draw_circle(p * MAP_SIZE, 4.5, LAND)
		draw_arc(p * MAP_SIZE, 4.5, 0.0, TAU, 18, LAND_OUTLINE, 1.5)
	# Country-border hint lines, drawn dashed.
	var i: int = 0
	while i + 1 < BORDERS.size():
		var a: Vector2 = BORDERS[i] * MAP_SIZE
		var b: Vector2 = BORDERS[i + 1] * MAP_SIZE
		_draw_dashed_line(a, b, BORDER, 1.2, 7.0, 5.0)
		i += 2
	# Rivers.
	for r2: PackedVector2Array in RIVERS:
		var pts := PackedVector2Array()
		for p2: Vector2 in r2:
			pts.append(p2 * MAP_SIZE)
		draw_polyline(pts, RIVER, 1.7)
	# Sea labels.
	var font: Font = ThemeDB.fallback_font
	for s: Dictionary in SEA_LABELS:
		var pos: Vector2 = (s["pos"] as Vector2) * MAP_SIZE
		var lbl: String = s["label"] as String
		var size_v: Vector2 = font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_CENTER, -1.0, 13)
		draw_string(font, pos - size_v * 0.5, lbl,
			HORIZONTAL_ALIGNMENT_CENTER, -1.0, 13, SEA_LABEL)
	# City dots + labels. Right-side cities label to the left so
	# they don't bleed off the edge.
	for c2: Dictionary in CITIES:
		var p3: Vector2 = (c2["pos"] as Vector2) * MAP_SIZE
		draw_circle(p3, 3.6, CITY_DOT)
		draw_arc(p3, 5.6, 0.0, TAU, 16, CITY_DOT, 1.0)
		var lbl2: String = c2["label"] as String
		var anchor_left: bool = p3.x < MAP_SIZE.x * 0.85
		if anchor_left:
			draw_string(font, p3 + Vector2(8.0, 4.0), lbl2,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, CITY_LABEL)
		else:
			var ts: Vector2 = font.get_string_size(lbl2, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12)
			draw_string(font, p3 + Vector2(-8.0 - ts.x, 4.0), lbl2,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, CITY_LABEL)
	# Compass rose on the bottom-right corner.
	_draw_compass(Vector2(MAP_SIZE.x - 70.0, MAP_SIZE.y - 70.0), 32.0)
	# Outer frame.
	draw_rect(rect, ACCENT, false, 2.0)


func _draw_land(poly_norm: PackedVector2Array) -> void:
	var pts: PackedVector2Array = PackedVector2Array()
	for p: Vector2 in poly_norm:
		pts.append(p * MAP_SIZE)
	draw_colored_polygon(pts, LAND)
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
	draw_arc(centre, radius, 0.0, TAU, 36, ACCENT, 1.4)
	draw_arc(centre, radius * 0.55, 0.0, TAU, 28, ACCENT, 0.9)
	for i: int in 4:
		var ang: float = float(i) * (PI * 0.5) - PI * 0.5
		var dir := Vector2(cos(ang), sin(ang))
		draw_line(centre + dir * (radius * 0.6), centre + dir * radius, ACCENT, 1.4)
	draw_line(centre + Vector2(0.0, -radius), centre + Vector2(0.0, -radius - 8.0), ACCENT, 2.0)
	var font: Font = ThemeDB.fallback_font
	draw_string(font, centre + Vector2(-4.0, -radius - 12.0), "N",
		HORIZONTAL_ALIGNMENT_CENTER, -1.0, 12, ACCENT)


func get_marker_position(key: String) -> Vector2:
	## Returns the pixel position of a marker key inside this control's
	## local coordinate space. Caller centers the marker widget on this
	## point.
	var norm: Vector2 = MARKERS.get(key, Vector2(0.5, 0.5)) as Vector2
	return norm * MAP_SIZE
