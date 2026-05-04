extends Control
## Pre-match loading screen. Shows the Europe map (the same Control
## the Campaigns page uses) and tweens a zoom-in toward the
## geographic location associated with the chosen map. Kicks off a
## ResourceLoader.load_threaded_request for the arena scene at the
## same time so the heavy disk + parse work happens in parallel
## with the visible animation; once both the zoom finishes AND the
## arena PackedScene is ready, we change_scene_to_packed (an
## instant swap from a pre-loaded scene resource) instead of the
## blocking change_scene_to_file.

const ARENA_SCENE: String = "res://scenes/test_arena.tscn"

## Pan phase -- mimics the operator turning to look at the map
## monitor before honing in. Starts off-screen-right at small
## scale and slides + grows to centred-and-fitting before the
## zoom-in begins.
const PAN_IN_SEC: float = 1.1
## Zoom phase duration. Bumped from 1.8s to 3.2s after profiling
## showed change_scene_to_file alone spends ~2-3s on the arena's
## _ready (terrain spawn, navmesh bake, AI setup, scenario
## seeding); the threaded preload now happens during this window
## so we wait for whichever finishes last instead of stacking the
## load time on top of the zoom.
const ZOOM_IN_SEC: float = 3.2
const FADE_OUT_SEC: float = 0.6
## Default zoom factor (scale relative to the fitted resting size).
## Bumped 2.4 -> 4.8 so the final framed view actually shows the
## map's region recognisably (city-sized footprint) rather than
## the whole north-half of Europe. Per-map overrides live in
## MAP_TARGETS["zoom"] -- denser regions can ask for more, sparse
## ones for less.
const ZOOM_FACTOR: float = 4.8
## Hard ceiling -- if for some reason the threaded load hangs we
## bail to a synchronous swap after this many seconds so the
## player isn't stuck on the loading screen.
const HARD_TIMEOUT_SEC: float = 18.0

## Real lat/lon of where each map "is set" in Europe. Drives the
## focal point of the zoom-in tween. MapId enum values from
## MatchSettingsClass: FOUNDRY_BELT=0, ASHPLAINS=1, IRON_GATE=2,
## SCHWARZWALD=3.
## Per-map zoom + focal lat/lon. `zoom` is a multiplier on top of
## the default ZOOM_FACTOR -- 1.0 keeps the default; >1 frames the
## region tighter (use for compact areas like the Iron Gate);
## <1 pulls back (use for sprawling regions like the Steppe).
const MAP_TARGETS: Array[Dictionary] = [
	{"lon":  7.4, "lat": 51.4, "name": "FOUNDRY BELT", "zoom": 1.20},   # Ruhr industrial cluster (Essen / Dortmund)
	{"lon": 35.5, "lat": 48.0, "name": "ASHPLAINS",    "zoom": 0.85},   # Ukrainian steppe -- pulled back, region is big
	{"lon": 22.6, "lat": 44.6, "name": "IRON GATE CROSSING", "zoom": 1.40},  # narrow Danube gorge -- tighter framing
	{"lon":  8.0, "lat": 48.2, "name": "SCHWARZWALD",  "zoom": 1.25},   # Black Forest -- mid-tight
]

## Special Operations scenarios all converge on Geneva (CERN).
const CERN_TARGET: Dictionary = {"lon": 6.14, "lat": 46.20, "name": "CERN BLACK SITE", "zoom": 1.30}

var _map: Control = null
var _label: Label = null
var _vignette: ColorRect = null
var _zoom_done: bool = false
var _scene_change_requested: bool = false
var _hard_timeout: float = HARD_TIMEOUT_SEC


func _process(delta: float) -> void:
	## Poll the threaded load every frame; once both the zoom phase
	## reports done AND the load reports STATUS_LOADED, swap to the
	## pre-loaded PackedScene. Hard-timeout fallback so a stuck load
	## doesn't strand the player on the loading screen.
	_hard_timeout -= delta
	if _scene_change_requested:
		return
	if _hard_timeout <= 0.0:
		_scene_change_requested = true
		get_tree().change_scene_to_file(ARENA_SCENE)
		return
	if not _zoom_done:
		return
	var status: int = ResourceLoader.load_threaded_get_status(ARENA_SCENE)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		_scene_change_requested = true
		var packed: PackedScene = ResourceLoader.load_threaded_get(ARENA_SCENE) as PackedScene
		if packed:
			get_tree().change_scene_to_packed(packed)
		else:
			get_tree().change_scene_to_file(ARENA_SCENE)
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		# Fallback to the synchronous path if the threaded load
		# couldn't resolve the scene.
		_scene_change_requested = true
		get_tree().change_scene_to_file(ARENA_SCENE)


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

	# Kick off the threaded preload of the arena RIGHT NOW so the
	# heavy parse work happens in parallel with the zoom animation.
	# The _process polling loop above swaps to the pre-loaded
	# PackedScene once both the zoom finishes AND the load reports
	# THREAD_LOAD_LOADED.
	ResourceLoader.load_threaded_request(ARENA_SCENE)


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


func _resolve_target_zoom() -> float:
	## Per-map zoom multiplier on top of ZOOM_FACTOR. Lets dense
	## regions frame tighter than sprawling steppe maps.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "scenario" in settings and (settings.get("scenario") as int) != 0:
		return CERN_TARGET.get("zoom", 1.0) as float
	if settings and "map_id" in settings:
		var idx: int = settings.get("map_id") as int
		if idx >= 0 and idx < MAP_TARGETS.size():
			return MAP_TARGETS[idx].get("zoom", 1.0) as float
	return 1.0


func _start_zoom() -> void:
	if not is_instance_valid(_map):
		# Map control didn't survive ready -- skip the visual phase
		# entirely and let the _process polling loop handle the
		# scene swap once the threaded preload reports done.
		_mark_zoom_done()
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

	# Centred / fitted resting state -- map sized to fit the screen
	# height. The zoom-in target is computed off this scale.
	var fit_scale: float = minf(
		screen_size.x / map_size.x,
		(screen_size.y - 140.0) / map_size.y,
	)
	fit_scale = clampf(fit_scale, 0.4, 1.4)
	var fit_offset: Vector2 = screen_centre - (map_size * 0.5) * fit_scale

	# PAN-IN starting state -- the map sits off-screen-right at a
	# smaller scale, as if it were a separate monitor on a wall the
	# operator is just now turning toward. Pan-in tweens both scale
	# and position to the fitted resting state.
	var pan_start_scale: float = fit_scale * 0.55
	var pan_start_offset: Vector2 = Vector2(
		screen_size.x + map_size.x * pan_start_scale * 0.30,  # off-screen right
		screen_centre.y - (map_size.y * 0.5) * pan_start_scale,
	)
	_map.scale = Vector2(pan_start_scale, pan_start_scale)
	_map.position = pan_start_offset
	# Slight tilt during the pan so the monitor reads as 'turning
	# into view' rather than sliding flatly.
	_map.rotation = deg_to_rad(-4.0)

	var pan: Tween = create_tween()
	pan.set_trans(Tween.TRANS_CUBIC)
	pan.set_ease(Tween.EASE_OUT)
	pan.set_parallel(true)
	pan.tween_property(_map, "scale", Vector2(fit_scale, fit_scale), PAN_IN_SEC)
	pan.tween_property(_map, "position", fit_offset, PAN_IN_SEC)
	pan.tween_property(_map, "rotation", 0.0, PAN_IN_SEC)

	# Final zoom -- pin the target lat/lon pixel to screen centre
	# at ZOOM_FACTOR * per-map override magnification, kicked off
	# after the pan lands. Per-map override (`zoom` in MAP_TARGETS)
	# tightens compact theatres (Iron Gate gorge) and pulls back on
	# sprawling ones (Steppe).
	var final_scale: float = fit_scale * ZOOM_FACTOR * _resolve_target_zoom()
	var final_offset: Vector2 = screen_centre - target_pixel * final_scale

	get_tree().create_timer(PAN_IN_SEC).timeout.connect(
		_run_zoom_phase.bind(final_scale, final_offset),
		CONNECT_ONE_SHOT
	)


func _run_zoom_phase(final_scale: float, final_offset: Vector2) -> void:
	if not is_instance_valid(_map):
		_mark_zoom_done()
		return
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_parallel(true)
	tween.tween_property(_map, "scale", Vector2(final_scale, final_scale), ZOOM_IN_SEC)
	tween.tween_property(_map, "position", final_offset, ZOOM_IN_SEC)
	get_tree().create_timer(ZOOM_IN_SEC).timeout.connect(_begin_fade_out, CONNECT_ONE_SHOT)


func _begin_fade_out() -> void:
	if _vignette:
		var tw: Tween = create_tween()
		tw.tween_property(_vignette, "color:a", 0.95, FADE_OUT_SEC)
	# Mark the visual phase complete; the _process polling loop
	# now waits for THREAD_LOAD_LOADED before swapping scenes. If
	# the threaded load already finished during the zoom the swap
	# fires on the next frame; otherwise we hold on the faded-out
	# vignette until the load lands or the hard timeout trips.
	get_tree().create_timer(FADE_OUT_SEC + 0.05).timeout.connect(_mark_zoom_done, CONNECT_ONE_SHOT)


func _mark_zoom_done() -> void:
	_zoom_done = true
