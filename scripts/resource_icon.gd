class_name ResourceIcon
extends Control
## Procedural resource glyph -- draws a distinct shape per resource
## kind so the player can scan a button or bar and tell salvage from
## fuel from chips at a glance, instead of all four icons being a
## colored square that varies only in tint.
##
## Used by the cost-chip widget on production / build buttons, the
## top resource bar, and the unit-stat panel chips. Keep it cheap:
## one Control with a _draw and a fixed canvas size.

enum Kind {
	SALVAGE,    # jagged scrap-pile (3 stacked triangles)
	FUEL,       # cylinder / barrel silhouette
	MICROCHIPS, # small notched chip
	POWER,      # lightning bolt
	POPULATION, # head + shoulders silhouette
}

var kind: Kind = Kind.SALVAGE
var tint: Color = Color.WHITE
## Hover tooltip word that pops up when the player hovers the
## icon ("Salvage", "Fuel", etc). Set by the caller.
var tooltip: String = ""


func _ready() -> void:
	# Default chip size -- 14x14 so the glyph reads at the small
	# button-strip footprint. Caller can override via
	# custom_minimum_size before _ready if a larger icon is needed
	# (top resource bar uses 20x20).
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(14.0, 14.0)
	mouse_filter = Control.MOUSE_FILTER_PASS
	if tooltip != "":
		tooltip_text = tooltip


func _draw() -> void:
	var sz: Vector2 = size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	match kind:
		Kind.SALVAGE:
			_draw_salvage(sz)
		Kind.FUEL:
			_draw_fuel(sz)
		Kind.MICROCHIPS:
			_draw_microchips(sz)
		Kind.POWER:
			_draw_power(sz)
		Kind.POPULATION:
			_draw_population(sz)


# --- Per-kind glyphs -------------------------------------------------

func _draw_salvage(sz: Vector2) -> void:
	# Three stacked angular shards -- reads as a scrap pile.
	var w: float = sz.x
	var h: float = sz.y
	var dark: Color = Color(tint.r * 0.65, tint.g * 0.65, tint.b * 0.65, tint.a)
	# Bottom plate (wide, dark).
	var bottom: PackedVector2Array = PackedVector2Array([
		Vector2(w * 0.05, h * 0.95),
		Vector2(w * 0.95, h * 0.95),
		Vector2(w * 0.78, h * 0.65),
		Vector2(w * 0.20, h * 0.65),
	])
	draw_colored_polygon(bottom, dark)
	# Middle shard (lighter).
	var mid: PackedVector2Array = PackedVector2Array([
		Vector2(w * 0.18, h * 0.65),
		Vector2(w * 0.80, h * 0.65),
		Vector2(w * 0.62, h * 0.40),
		Vector2(w * 0.30, h * 0.40),
	])
	draw_colored_polygon(mid, tint)
	# Top spike (brightest).
	var bright: Color = Color(min(tint.r * 1.25, 1.0), min(tint.g * 1.25, 1.0), min(tint.b * 1.25, 1.0), tint.a)
	var top: PackedVector2Array = PackedVector2Array([
		Vector2(w * 0.30, h * 0.40),
		Vector2(w * 0.65, h * 0.40),
		Vector2(w * 0.50, h * 0.10),
	])
	draw_colored_polygon(top, bright)


func _draw_fuel(sz: Vector2) -> void:
	# Vertical cylinder with cap + ring band -- reads as a fuel
	# barrel / can.
	var w: float = sz.x
	var h: float = sz.y
	var dark: Color = Color(tint.r * 0.65, tint.g * 0.65, tint.b * 0.65, tint.a)
	# Body rectangle.
	draw_rect(Rect2(Vector2(w * 0.20, h * 0.18), Vector2(w * 0.60, h * 0.74)), tint, true)
	# Top cap.
	draw_rect(Rect2(Vector2(w * 0.16, h * 0.10), Vector2(w * 0.68, h * 0.14)), dark, true)
	# Bottom rim.
	draw_rect(Rect2(Vector2(w * 0.16, h * 0.86), Vector2(w * 0.68, h * 0.10)), dark, true)
	# Centre ring band.
	draw_rect(Rect2(Vector2(w * 0.20, h * 0.50), Vector2(w * 0.60, h * 0.10)), dark, true)
	# Spout glyph on the cap.
	draw_rect(Rect2(Vector2(w * 0.62, h * 0.04), Vector2(w * 0.10, h * 0.12)), dark, true)


func _draw_microchips(sz: Vector2) -> void:
	# Square chip body with leg notches on each side -- the IC
	# silhouette. Inner cross detail reads as the die.
	var w: float = sz.x
	var h: float = sz.y
	var dark: Color = Color(tint.r * 0.55, tint.g * 0.55, tint.b * 0.55, tint.a)
	# Body.
	draw_rect(Rect2(Vector2(w * 0.18, h * 0.18), Vector2(w * 0.64, h * 0.64)), tint, true)
	# Inner die.
	draw_rect(Rect2(Vector2(w * 0.32, h * 0.32), Vector2(w * 0.36, h * 0.36)), dark, true)
	# Legs -- two tiny notches each side.
	for i: int in 2:
		var ly: float = h * (0.30 + 0.30 * float(i))
		draw_rect(Rect2(Vector2(w * 0.06, ly), Vector2(w * 0.12, h * 0.10)), dark, true)
		draw_rect(Rect2(Vector2(w * 0.82, ly), Vector2(w * 0.12, h * 0.10)), dark, true)
	for i2: int in 2:
		var lx: float = w * (0.30 + 0.30 * float(i2))
		draw_rect(Rect2(Vector2(lx, h * 0.06), Vector2(w * 0.10, h * 0.12)), dark, true)
		draw_rect(Rect2(Vector2(lx, h * 0.82), Vector2(w * 0.10, h * 0.12)), dark, true)


func _draw_power(sz: Vector2) -> void:
	# Classic lightning bolt -- two stacked Z-mirror triangles.
	var w: float = sz.x
	var h: float = sz.y
	var pts: PackedVector2Array = PackedVector2Array([
		Vector2(w * 0.55, h * 0.04),
		Vector2(w * 0.20, h * 0.55),
		Vector2(w * 0.45, h * 0.55),
		Vector2(w * 0.30, h * 0.96),
		Vector2(w * 0.85, h * 0.40),
		Vector2(w * 0.55, h * 0.40),
		Vector2(w * 0.78, h * 0.04),
	])
	draw_colored_polygon(pts, tint)


func _draw_population(sz: Vector2) -> void:
	# Head + shoulders silhouette.
	var w: float = sz.x
	var h: float = sz.y
	var head_r: float = w * 0.20
	# Head circle.
	draw_circle(Vector2(w * 0.50, h * 0.30), head_r, tint)
	# Shoulders (rounded rect via two stacked rects + side
	# circles).
	var sh_top: float = h * 0.55
	var sh_h: float = h * 0.40
	draw_rect(Rect2(Vector2(w * 0.18, sh_top), Vector2(w * 0.64, sh_h)), tint, true)
	draw_circle(Vector2(w * 0.18, sh_top + sh_h * 0.5), w * 0.12, tint)
	draw_circle(Vector2(w * 0.82, sh_top + sh_h * 0.5), w * 0.12, tint)


static func make(p_kind: Kind, p_tint: Color, p_tooltip: String = "", icon_size: Vector2 = Vector2(14.0, 14.0)) -> ResourceIcon:
	## Convenience factory -- one call returns a sized + tinted +
	## tooltipped icon ready to add as a chip child. Params are
	## prefixed `p_` because plain `kind` / `tint` / `tooltip` shadow
	## the class-level vars they assign to (the parser warns even
	## though static funcs can't actually access instance state).
	var icon: ResourceIcon = ResourceIcon.new()
	icon.kind = p_kind
	icon.tint = p_tint
	icon.tooltip = p_tooltip
	icon.custom_minimum_size = icon_size
	return icon
