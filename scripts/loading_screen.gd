extends Control
## Pre-match loading screen. Shows the Europe map (the same Control
## the Campaigns page uses) and tweens a zoom-in toward the
## geographic location associated with the chosen map. Sells the
## "deploying to theatre" feel and gives Godot a window to load the
## arena scene without the player staring at a black frame.
##
## Flow:
##   _ready -> build map + label, schedule the zoom-in tween,
##             after `TOTAL_SEC` change_scene_to_file(ARENA_SCENE).

const ARENA_SCENE: String = "res://scenes/test_arena.tscn"

## Total time the loading screen is visible. ~2.4 s lands long
## enough for the zoom to read but short enough that players who've
## seen it once aren't bothered.
const TOTAL_SEC: float = 2.4
const ZOOM_IN_SEC: float = 1.8
const FADE_OUT_SEC: float = 0.5
const ZOOM_FACTOR: float = 2.4

## Real lat/lon of where each map "is set" in Europe. Drives the
## focal point of the zoom-in tween. MapId enum values from
## MatchSettingsClass: FOUNDRY_BELT=0, ASHPLAINS=1, IRON_GATE=2,
## SCHWARZWALD=3.
const MAP_TARGETS: Array[Dictionary] = [
	{"lon":  8.5, "lat": 50.5, "name": "FOUNDRY BELT"},          # Ruhr industrial heartland
	{"lon": 30.0, "lat": 47.0, "name": "ASHPLAINS"},             # Ukrainian steppe
	{"lon": 22.5, "lat": 44.7, "name": "IRON GATE CROSSING"},    # actual Iron Gate of the Danube
	{"lon":  8.2, "lat": 48.0, "name": "SCHWARZWALD"},           # Black Forest
]

## Special Operations scenarios all converge on Geneva (CERN).
const CERN_TARGET: Dictionary = {"lon": 6.14, "lat": 46.20, "name": "CERN BLACK SITE"}

var _map: Control = null
var _label: Label = null
var _vignette: ColorRect = null


func _ready() -> void:
	# Black backdrop -- the map paints inside it, but the unused
	# corners stay dark so the eye lands on the zoom focus.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.04, 0.05, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# The Europe map sits in a center-pivoted holder so a uniform
	# `scale` from the centre with a translation offset lands the
	# zoom on the target lat/lon.
	var map_script: GDScript = preload("res://scripts/europe_map.gd")
	var map: Control = Control.new()
	map.set_script(map_script)
	# Anchor full-rect; we'll position+scale via direct property
	# sets in the tween.
	add_child(map)
	_map = map
	# Defer initial layout so the map's _ready fires (which sets
	# its custom_minimum_size).
	map.call_deferred("_ready")

	# Heading label -- "DEPLOYING: <site>". Sits at the top.
	_label = Label.new()
	_label.text = "DEPLOYING: %s" % _resolve_target_name()
	_label.add_theme_font_size_override("font_size", 28)
	_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78, 1.0))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_label.offset_top = 30
	_label.offset_bottom = 80
	add_child(_label)

	# Soft vignette overlay -- fades to white during the FADE_OUT
	# phase so the scene change feels seamless.
	_vignette = ColorRect.new()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color(0.85, 0.95, 0.85, 0.0)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)

	# Defer the tween until after the map's _ready landed so the
	# focal lat/lon resolves to a real pixel position.
	call_deferred("_start_zoom")


func _resolve_target_name() -> String:
	## Returns the display name of the destination: the matching
	## entry in MAP_TARGETS for skirmishes, or the CERN label for
	## any active Special Operations scenario.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "scenario" in settings and (settings.get("scenario") as int) != 0:
		return CERN_TARGET["name"] as String
	if settings and "map_id" in settings:
		var idx: int = settings.get("map_id") as int
		if idx >= 0 and idx < MAP_TARGETS.size():
			return MAP_TARGETS[idx]["name"] as String
	return "FRONT LINE"


func _resolve_target_lonlat() -> Vector2:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "scenario" in settings and (settings.get("scenario") as int) != 0:
		return Vector2(CERN_TARGET["lon"] as float, CERN_TARGET["lat"] as float)
	if settings and "map_id" in settings:
		var idx: int = settings.get("map_id") as int
		if idx >= 0 and idx < MAP_TARGETS.size():
			return Vector2(MAP_TARGETS[idx]["lon"] as float, MAP_TARGETS[idx]["lat"] as float)
	return Vector2(8.5, 50.5)  # default to central Europe


func _start_zoom() -> void:
	if not is_instance_valid(_map):
		_finish_load()
		return
	var lonlat: Vector2 = _resolve_target_lonlat()
	# Map.get_marker_position returns world-space pixels for a
	# normalized point; we'll feed it the lat/lon-derived normalised
	# coords ourselves rather than via the marker dictionary.
	var map_size: Vector2 = (_map.get("custom_minimum_size") as Vector2)
	if map_size == Vector2.ZERO:
		map_size = Vector2(1280.0, 800.0)
	# Match europe_map's _ll() conversion.
	var norm: Vector2 = Vector2(
		(lonlat.x - (-25.0)) / (45.0 - (-25.0)),
		1.0 - (lonlat.y - 35.0) / (72.0 - 35.0),
	)
	var target_pixel: Vector2 = norm * map_size

	# Centre of the screen we want the focal point to land on.
	var screen_size: Vector2 = get_viewport_rect().size
	var screen_centre: Vector2 = screen_size * 0.5

	# Initial: map sized to fit screen height, centered.
	var initial_scale: float = minf(
		screen_size.x / map_size.x,
		(screen_size.y - 140.0) / map_size.y,
	)
	initial_scale = clampf(initial_scale, 0.4, 1.4)
	var initial_offset: Vector2 = screen_centre - (map_size * 0.5) * initial_scale
	_map.scale = Vector2(initial_scale, initial_scale)
	_map.position = initial_offset

	# Final: zoom by ZOOM_FACTOR with the target pixel pinned to
	# screen centre.
	var final_scale: float = initial_scale * ZOOM_FACTOR
	var final_offset: Vector2 = screen_centre - target_pixel * final_scale

	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_parallel(true)
	tween.tween_property(_map, "scale", Vector2(final_scale, final_scale), ZOOM_IN_SEC)
	tween.tween_property(_map, "position", final_offset, ZOOM_IN_SEC)

	# Trigger scene change after the zoom + a brief fade-out flash.
	get_tree().create_timer(ZOOM_IN_SEC).timeout.connect(_begin_fade_out, CONNECT_ONE_SHOT)


func _begin_fade_out() -> void:
	if _vignette:
		var tw: Tween = create_tween()
		tw.tween_property(_vignette, "color:a", 0.95, FADE_OUT_SEC)
	get_tree().create_timer(FADE_OUT_SEC + 0.05).timeout.connect(_finish_load, CONNECT_ONE_SHOT)


func _finish_load() -> void:
	get_tree().change_scene_to_file(ARENA_SCENE)
