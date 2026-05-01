class_name MapPreview
extends Control
## Procedural top-down sketch of a map's strategic layout. Drawn by
## hand in `_draw` from the same constants the test arena uses, so
## what the player sees here matches what they'll spawn into. No
## external image assets needed.
##
## Layout for each map:
##   - Plateau footprints as octagons (cool grey), labelled "high"
##   - Plateau ramps as small wedges
##   - Fuel deposits as gold dots with capture-radius rings
##   - Volcanic fissures (Ashplains only) as jagged orange streaks
##   - Player HQ corners marked with team colour squares
##
## Used by the match-setup screen below the map dropdown so the player
## sees what they're picking before committing.

enum MapId { FOUNDRY_BELT, ASHPLAINS_CROSSING }

@export var map_id: MapId = MapId.FOUNDRY_BELT:
	set(value):
		map_id = value
		queue_redraw()
@export var selected: bool = false:
	set(value):
		selected = value
		queue_redraw()


const MAP_HALF: float = 150.0  # world half-extent — matches test_arena_controller


func _init() -> void:
	custom_minimum_size = Vector2(220, 156)


func _draw() -> void:
	var s: Vector2 = size
	# Background — dark frame + subtle ground tint per map.
	var bg_color: Color = (
		Color(0.12, 0.13, 0.13, 1.0) if map_id == MapId.FOUNDRY_BELT
		else Color(0.18, 0.13, 0.10, 1.0)  # warm ash tint
	)
	draw_rect(Rect2(Vector2.ZERO, s), bg_color, true)
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.30, 0.32, 0.36, 1.0), false, 1.5)
	# Headline label across the top.
	var label: String = "FOUNDRY BELT" if map_id == MapId.FOUNDRY_BELT else "ASHPLAINS CROSSING"
	var f := ThemeDB.fallback_font
	draw_string(f, Vector2(8, 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.85, 0.80, 1.0))
	# Per-map content. Centre of preview maps to world (0, 0).
	if map_id == MapId.FOUNDRY_BELT:
		_draw_foundry_belt()
	else:
		_draw_ashplains()
	# Selection ring.
	if selected:
		draw_rect(Rect2(Vector2.ZERO, s).grow(-2), Color(0.95, 0.78, 0.32, 1.0), false, 2.5)


func _draw_foundry_belt() -> void:
	# Plateaus.
	_draw_plateau(Vector3(0, 0, 25), Vector2(28, 18))
	_draw_plateau(Vector3(0, 0, -75), Vector2(24, 14))
	_draw_plateau(Vector3(72, 0, 0), Vector2(12, 22))
	_draw_plateau(Vector3(-72, 0, 0), Vector2(12, 22))
	# Deposits — 1v1 layout (the menu doesn't yet know if 2v2 is picked).
	var deposits: Array[Vector3] = [
		Vector3(28, 0, 80), Vector3(-28, 0, -80),
		Vector3(35, 0, 0), Vector3(-35, 0, 0),
		Vector3(95, 0, 0), Vector3(-95, 0, 0),
	]
	for d: Vector3 in deposits:
		_draw_deposit(d)
	# HQ corners.
	_draw_hq(Vector3(0, 0, 110), Color(0.30, 0.55, 1.0, 1.0))
	_draw_hq(Vector3(0, 0, -110), Color(1.0, 0.30, 0.30, 1.0))


func _draw_ashplains() -> void:
	# Central ridge plateau.
	_draw_plateau(Vector3(0, 0, -8), Vector2(90, 14))
	_draw_plateau(Vector3(0, 0, 38), Vector2(28, 10))
	# Volcanic fissures.
	_draw_fissure(Vector3(40, 0, 12), Vector3(28, 0, 2.5), 0.05)
	_draw_fissure(Vector3(-40, 0, 12), Vector3(28, 0, 2.5), -0.05)
	_draw_fissure(Vector3(95, 0, -30), Vector3(20, 0, 2.2), 1.2)
	_draw_fissure(Vector3(-95, 0, 30), Vector3(20, 0, 2.2), 1.2)
	# Deposits.
	for d: Vector3 in [
		Vector3(0, 0, 80), Vector3(0, 0, -80), Vector3(0, 0, 0),
		Vector3(80, 0, 40), Vector3(-80, 0, 40),
		Vector3(80, 0, -40), Vector3(-80, 0, -40),
	]:
		_draw_deposit(d)
	# HQ corners.
	_draw_hq(Vector3(0, 0, 110), Color(0.30, 0.55, 1.0, 1.0))
	_draw_hq(Vector3(0, 0, -110), Color(1.0, 0.30, 0.30, 1.0))


## --- World → preview coord helpers ---

func _w2p(world: Vector3) -> Vector2:
	# World (-150..150) → pixel within the preview rect, with a margin
	# so HQ markers near the corners aren't clipped.
	var s: Vector2 = size
	var margin: float = 8.0
	var w: float = s.x - margin * 2.0
	var h: float = s.y - margin * 2.0
	var x: float = margin + (world.x + MAP_HALF) / (MAP_HALF * 2.0) * w
	# +Z = up on the preview (north). Flip Z so screen-y matches world-z.
	var y: float = margin + (1.0 - (world.z + MAP_HALF) / (MAP_HALF * 2.0)) * h
	return Vector2(x, y)


func _w2p_size(world_size: Vector2) -> Vector2:
	var s: Vector2 = size
	var margin: float = 8.0
	var w: float = s.x - margin * 2.0
	var h: float = s.y - margin * 2.0
	return Vector2(world_size.x / (MAP_HALF * 2.0) * w, world_size.y / (MAP_HALF * 2.0) * h)


## --- Feature drawing ---

func _draw_plateau(center: Vector3, top_size: Vector2) -> void:
	var p: Vector2 = _w2p(center)
	var sz: Vector2 = _w2p_size(top_size)
	# Octagon with chamfered corners — same silhouette as in-game.
	var hx: float = sz.x * 0.5
	var hz: float = sz.y * 0.5
	var cut: float = mini(int(hx), int(hz)) * 0.25
	var pts: PackedVector2Array = [
		Vector2(p.x + hx, p.y - hz + cut),
		Vector2(p.x + hx - cut, p.y - hz),
		Vector2(p.x - hx + cut, p.y - hz),
		Vector2(p.x - hx, p.y - hz + cut),
		Vector2(p.x - hx, p.y + hz - cut),
		Vector2(p.x - hx + cut, p.y + hz),
		Vector2(p.x + hx - cut, p.y + hz),
		Vector2(p.x + hx, p.y + hz - cut),
	]
	draw_colored_polygon(pts, Color(0.42, 0.42, 0.46, 1.0))
	for i: int in 8:
		draw_line(pts[i], pts[(i + 1) % 8], Color(0.62, 0.62, 0.66, 1.0), 1.0)


func _draw_deposit(center: Vector3) -> void:
	var p: Vector2 = _w2p(center)
	# Capture radius (faint), then the deposit dot.
	draw_arc(p, 5.0, 0.0, TAU, 16, Color(0.95, 0.78, 0.32, 0.45), 1.0, true)
	draw_circle(p, 3.0, Color(0.95, 0.78, 0.32, 1.0))


func _draw_fissure(center: Vector3, fissure_size: Vector3, rot_y: float) -> void:
	var p: Vector2 = _w2p(center)
	# Approximate the fissure as a short rotated streak with an
	# orange glow line. Length scales with world width.
	var len_px: float = fissure_size.x / (MAP_HALF * 2.0) * (size.x - 16.0)
	var ax: float = cos(rot_y) * len_px * 0.5
	var ay: float = -sin(rot_y) * len_px * 0.5  # screen-y inverted vs world-z
	var a: Vector2 = p - Vector2(ax, ay)
	var b: Vector2 = p + Vector2(ax, ay)
	# Dark trench outline.
	draw_line(a, b, Color(0.10, 0.05, 0.04, 1.0), 3.0)
	# Inner glow.
	draw_line(a, b, Color(1.0, 0.5, 0.15, 0.95), 1.5)


func _draw_hq(center: Vector3, color: Color) -> void:
	var p: Vector2 = _w2p(center)
	draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), color, true)
	draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), Color(0.05, 0.05, 0.05, 1.0), false, 1.0)
