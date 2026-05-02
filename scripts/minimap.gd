class_name Minimap
extends Control
## Simple minimap showing unit/building positions as colored dots.

const MAP_WORLD_SIZE: float = 300.0
const DOT_SIZE: float = 3.0
const BUILDING_SIZE: float = 5.0
const DEPOSIT_SIZE: float = 4.0

var _player_color := Color(0.08, 0.25, 0.85, 1.0)
var _enemy_color := Color(0.80, 0.10, 0.10, 1.0)
var _neutral_color := Color(0.85, 0.7, 0.3, 1.0)
var _wreck_color := Color(0.4, 0.35, 0.25, 0.5)

## Faction-coloured decorative border + ping flash overlay. Border is
## drawn each frame around the actual map area; pings are short-lived
## flash markers triggered by alert events.
const BORDER_THICKNESS: float = 8.0
var _border_accent: Color = Color(1.0, 0.82, 0.35, 1.0)  # Anvil brass; replaced at _ready

## Active pings — list of {pos, t_start, color}. Pings live for
## PING_LIFETIME seconds and pulse expanding rings.
var _pings: Array[Dictionary] = []
const PING_LIFETIME: float = 1.6
const PING_MAX_RADIUS: float = 18.0

## Persistent pulsing pins keyed by caller-chosen string. Each entry
## holds {pos, color}. Drawn every frame as a sin-pulsed ring + filled
## core so the eye is anchored to long-running events (incoming
## satellite, beacon dropped by an ability) until the caller clears
## the pin via stop_pulse_pin().
var _pulse_pins: Dictionary = {}
const PULSE_PIN_INNER: float = 4.5
const PULSE_PIN_OUTER: float = 11.0
const PULSE_PIN_HZ: float = 1.4


func _ready() -> void:
	# Resolve the player's faction once and cache the accent colour
	# used for the border and corner ticks.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "player_faction" in settings:
		var fid: int = settings.get("player_faction") as int
		if fid == 1:
			_border_accent = Color(0.78, 0.45, 1.0, 1.0)  # Sable violet
		else:
			_border_accent = Color(1.0, 0.82, 0.35, 1.0)  # Anvil brass


func ping(world_pos: Vector3, color: Color = Color.WHITE) -> void:
	## Add a short-lived flash at the given world position. Other systems
	## (alert manager, event handlers) call this to draw the player's
	## eye to the minimap location of an event.
	_pings.append({
		"pos": world_pos,
		"t_start": Time.get_ticks_msec() / 1000.0,
		"color": color,
	})


func start_pulse_pin(key: String, world_pos: Vector3, color: Color) -> void:
	## Place a persistent pulsing ring on the minimap until cleared
	## via stop_pulse_pin(). Used for long-running threats (satellite
	## impact countdown) where a one-shot ping isn't sticky enough.
	_pulse_pins[key] = {"pos": world_pos, "color": color}


func stop_pulse_pin(key: String) -> void:
	_pulse_pins.erase(key)


func _draw_fog_tint(fow: FogOfWar, map_origin: Vector2, map_size: Vector2, half_world: float) -> void:
	## One filled rect per FOW cell, drawn directly in the minimap's
	## map area. Per-cell px size is derived from the FOW grid size.
	## Iterates the flat byte array linearly so we hit each cell at
	## most once.
	var grid_size: int = fow.get_grid_size()
	if grid_size <= 0:
		return
	var cells: PackedByteArray = fow.get_cells()
	var cell_px: Vector2 = map_size / float(grid_size)
	# Tint world fits the same MAP_WORLD_SIZE the entity loops use.
	# half_world is unused for the fog tint (cells map directly to
	# the minimap rect 1:1), but kept in the signature for symmetry.
	var _hw: float = half_world  # quiet the unused-arg warning
	for cz: int in grid_size:
		for cx: int in grid_size:
			var i: int = cz * grid_size + cx
			if i >= cells.size():
				continue
			var alpha: float = 0.0
			match cells[i]:
				FogOfWar.CellState.UNEXPLORED:
					alpha = 0.95
				FogOfWar.CellState.EXPLORED:
					alpha = 0.55
				_:
					continue
			var px := Vector2(
				map_origin.x + float(cx) * cell_px.x,
				# World +Z (south) maps to minimap +Y (down) — matches
				# _world_to_map's convention so fog overlay aligns
				# with where entities are actually drawn.
				map_origin.y + float(cz) * cell_px.y,
			)
			# Bump rect size by ~0.5 px so adjacent cell rects don't
			# leave hairline gaps at fractional cell sizes.
			draw_rect(
				Rect2(px, cell_px + Vector2(0.5, 0.5)),
				Color(0.02, 0.02, 0.04, alpha)
			)


func _color_for_owner(owner_idx: int) -> Color:
	# Prefer the PlayerRegistry's perspective rule so 2v2 allies show in
	# their own tint instead of generic enemy red. Falls back to the
	# pre-registry behaviour for headless / test scenes.
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("get_perspective_color"):
		return registry.get_perspective_color(owner_idx)
	if owner_idx == 0:
		return _player_color
	if owner_idx == 2:
		return _neutral_color
	return _enemy_color


var _redraw_timer: float = 0.0
const REDRAW_INTERVAL: float = 0.066  # ~15 Hz; minimap glance-readability
									   # doesn't need 60 Hz

func _process(delta: float) -> void:
	# Throttle minimap repaint to ~15 Hz. At 360+ units the per-frame
	# `_draw` was eating ~2 ms; capping the rate cuts that to ~0.5 ms
	# without any noticeable lag in unit dot positions.
	_redraw_timer += delta
	if _redraw_timer < REDRAW_INTERVAL:
		return
	_redraw_timer = 0.0
	queue_redraw()


func _draw() -> void:
	# Decorative faction-themed margin lives in the outer
	# BORDER_THICKNESS pixels; the actual map area is inset.
	var full: Vector2 = size
	var map_origin: Vector2 = Vector2(BORDER_THICKNESS, BORDER_THICKNESS)
	var map_size: Vector2 = full - Vector2(BORDER_THICKNESS, BORDER_THICKNESS) * 2.0
	var half_world: float = MAP_WORLD_SIZE / 2.0

	# Decorative border — outer dark frame + faction-coloured inner
	# accent bands + corner ticks. Reads as a stamped insignia plate
	# rather than a flat dark rectangle.
	draw_rect(Rect2(Vector2.ZERO, full), Color(0.04, 0.04, 0.05, 0.95))
	# Faction accent strip just inside the outer frame.
	var inner_rect := Rect2(Vector2(2, 2), full - Vector2(4, 4))
	draw_rect(inner_rect, Color.TRANSPARENT, false, 2.0)
	draw_rect(inner_rect, _border_accent.darkened(0.30), false, 2.0)
	# Corner ticks — small L-brackets in faction accent at each
	# corner. Stops the frame from looking like a generic UI panel.
	var tick_len: float = 14.0
	var tick_thick: float = 2.0
	for cx_i: int in 2:
		for cy_i: int in 2:
			var ox: float = 2.0 if cx_i == 0 else full.x - 2.0
			var oy: float = 2.0 if cy_i == 0 else full.y - 2.0
			var dir_x: int = 1 if cx_i == 0 else -1
			var dir_y: int = 1 if cy_i == 0 else -1
			draw_line(Vector2(ox, oy), Vector2(ox + dir_x * tick_len, oy), _border_accent, tick_thick)
			draw_line(Vector2(ox, oy), Vector2(ox, oy + dir_y * tick_len), _border_accent, tick_thick)

	# Map background — inset rectangle.
	draw_rect(Rect2(map_origin, map_size), Color(0.08, 0.08, 0.07, 0.85))
	draw_rect(Rect2(map_origin, map_size), Color(0.3, 0.3, 0.3, 0.55), false, 1.0)

	# Cache FOW once for the rest of the draw — every entity loop
	# below filters through it so the minimap shows what the player
	# actually knows, not ground truth.
	var fow: FogOfWar = get_tree().current_scene.get_node_or_null("FogOfWar") as FogOfWar

	# Fog tint over the minimap background — one rect per cell of
	# the FOW grid. UNEXPLORED cells render fully opaque black so
	# the player sees a hard edge at the explored boundary;
	# EXPLORED cells render a darker tint so the player still
	# reads "this terrain is known but I have no live info." Drawn
	# AFTER the background and BEFORE entities so dots overlay the
	# fog (visible cells are no-draw; explored buildings render
	# under the explored tint, which softens but doesn't hide).
	if fow:
		_draw_fog_tint(fow, map_origin, map_size, half_world)

	# Draw buildings
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if not is_instance_valid(node):
			continue
		var b_owner: int = node.get("owner_id") as int
		# Enemy buildings stick around once explored (AoE-style
		# memory). Friendly + ally buildings always show.
		if fow and b_owner != 0 and not fow.is_explored_world((node as Node3D).global_position):
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		var color: Color = _color_for_owner(b_owner)
		draw_rect(Rect2(pos - Vector2(BUILDING_SIZE / 2.0, BUILDING_SIZE / 2.0), Vector2(BUILDING_SIZE, BUILDING_SIZE)), color)

	# Draw fuel deposits
	var deposits: Array[Node] = get_tree().get_nodes_in_group("fuel_deposits")
	for node: Node in deposits:
		if not is_instance_valid(node):
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		var dep_owner: int = node.get("owner_id") if "owner_id" in node else -1
		# Uncaptured deposits sit at owner_id == -1, which isn't a valid
		# player id — keep the explicit neutral fallback for that case.
		# Captured deposits go through the same perspective helper as
		# units / buildings so 2v2 allies render green instead of the
		# previous "any non-zero owner = red enemy" rule.
		var color: Color
		if dep_owner < 0:
			color = _neutral_color
		else:
			color = _color_for_owner(dep_owner)
		# Diamond shape for deposits
		var pts := PackedVector2Array([
			pos + Vector2(0, -DEPOSIT_SIZE),
			pos + Vector2(DEPOSIT_SIZE, 0),
			pos + Vector2(0, DEPOSIT_SIZE),
			pos + Vector2(-DEPOSIT_SIZE, 0),
		])
		draw_colored_polygon(pts, color)

	# Draw wrecks — only those in EXPLORED or VISIBLE cells.
	# Unexplored map cells should be totally featureless on the
	# minimap, so the player can't scout salvage piles for free.
	var wrecks: Array[Node] = get_tree().get_nodes_in_group("wrecks")
	for node: Node in wrecks:
		if not is_instance_valid(node):
			continue
		if fow and not fow.is_explored_world((node as Node3D).global_position):
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		draw_circle(pos, 2.0, _wreck_color)

	# Draw units. Aircraft get a slightly larger ring + a small
	# diamond-shape pip so the player can tell at a glance whether
	# a dot is on the ground or in the air. Stealthed enemy units
	# that we haven't revealed yet are skipped — the minimap is the
	# strategic overview, not an x-ray.
	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not is_instance_valid(node):
			continue
		if "alive_count" in node and node.get("alive_count") <= 0:
			continue
		# Hide stealthed enemy units when not revealed.
		if "stealth_revealed" in node and not (node.get("stealth_revealed") as bool):
			var stats_chk: Resource = node.get("stats") as Resource
			if stats_chk and stats_chk.get("is_stealth_capable"):
				var u_owner: int = node.get("owner_id") as int
				if u_owner != 0:  # only hide enemies; show our own dim
					continue
		# FOW filter — enemy unit dots only render when CURRENTLY
		# in vision (not just explored). Friendly + ally dots
		# always show.
		var unit_owner: int = node.get("owner_id") as int
		if fow and unit_owner != 0 and not fow.is_visible_world((node as Node3D).global_position):
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		var color: Color = _color_for_owner(node.get("owner_id") as int)
		var is_air: bool = node.is_in_group("aircraft")
		if is_air:
			# Aircraft pip — outer ring + filled diamond inside.
			# The double-shape reads even at small minimap zoom.
			draw_arc(pos, DOT_SIZE + 1.5, 0.0, TAU, 12, color, 1.5, true)
			var d: float = DOT_SIZE
			var diamond: PackedVector2Array = PackedVector2Array([
				pos + Vector2(0, -d),
				pos + Vector2(d, 0),
				pos + Vector2(0, d),
				pos + Vector2(-d, 0),
			])
			draw_colored_polygon(diamond, color)
		else:
			draw_circle(pos, DOT_SIZE, color)

	# Draw camera viewport rectangle
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam:
		var cam_pos: Vector2 = _world_to_map(cam.global_position, map_size, half_world)
		var view_half: float = cam.size * 0.5 / half_world * map_size.x * 0.5
		var view_rect := Rect2(
			cam_pos - Vector2(view_half, view_half * 0.6),
			Vector2(view_half * 2.0, view_half * 1.2)
		)
		draw_rect(view_rect, Color(1.0, 1.0, 1.0, 0.3), false, 1.0)

	# Persistent pulse pins (incoming-satellite warning, etc). Drawn
	# UNDER the active flash pings so a single-tick ping still pops on
	# top, but ABOVE unit dots / camera rect so the pulse stays
	# readable through the scene.
	var pulse_now: float = Time.get_ticks_msec() / 1000.0
	for pin: Dictionary in _pulse_pins.values():
		var pin_pos: Vector2 = _world_to_map(pin["pos"] as Vector3, map_size, half_world)
		var pulse_t: float = (sin(pulse_now * TAU * PULSE_PIN_HZ) + 1.0) * 0.5
		var pulse_radius: float = lerp(PULSE_PIN_INNER, PULSE_PIN_OUTER, pulse_t)
		var pin_color: Color = pin["color"] as Color
		var ring_color: Color = pin_color
		ring_color.a = lerp(0.45, 1.0, 1.0 - pulse_t)
		draw_arc(pin_pos, pulse_radius, 0.0, TAU, 24, ring_color, 2.0, true)
		var core_color: Color = pin_color
		core_color.a = 0.95
		draw_circle(pin_pos, PULSE_PIN_INNER * 0.55, core_color)
		# Crosshair tick — 4 short stubs at compass points so the pin
		# reads as a marked target, not just another dot.
		var stub: float = PULSE_PIN_OUTER + 2.0
		draw_line(pin_pos + Vector2(0, -stub), pin_pos + Vector2(0, -stub + 3.0), pin_color, 1.5)
		draw_line(pin_pos + Vector2(0, stub), pin_pos + Vector2(0, stub - 3.0), pin_color, 1.5)
		draw_line(pin_pos + Vector2(-stub, 0), pin_pos + Vector2(-stub + 3.0, 0), pin_color, 1.5)
		draw_line(pin_pos + Vector2(stub, 0), pin_pos + Vector2(stub - 3.0, 0), pin_color, 1.5)

	# Active pings — expanding rings + filled dot, fading over
	# PING_LIFETIME seconds. Drawn last so they render on top of
	# unit dots / camera rect.
	var now_sec: float = Time.get_ticks_msec() / 1000.0
	var i: int = _pings.size() - 1
	while i >= 0:
		var ping_data: Dictionary = _pings[i]
		var elapsed: float = now_sec - (ping_data["t_start"] as float)
		if elapsed > PING_LIFETIME:
			_pings.remove_at(i)
			i -= 1
			continue
		var t: float = elapsed / PING_LIFETIME
		var ping_color: Color = ping_data["color"] as Color
		ping_color.a = 1.0 - t
		var ping_pos: Vector2 = _world_to_map(ping_data["pos"] as Vector3, map_size, half_world)
		# Expanding outer ring.
		draw_arc(ping_pos, PING_MAX_RADIUS * t, 0.0, TAU, 24, ping_color, 2.0, true)
		# Bright core that decays slower.
		var core_color: Color = ping_data["color"] as Color
		core_color.a = clampf(1.0 - t * 0.6, 0.0, 1.0)
		draw_circle(ping_pos, 3.5, core_color)
		i -= 1


func _world_to_map(world_pos: Vector3, map_size: Vector2, half_world: float) -> Vector2:
	var nx: float = (world_pos.x + half_world) / (half_world * 2.0)
	var nz: float = (world_pos.z + half_world) / (half_world * 2.0)
	# Offset by the decorative-border inset so dots land inside the
	# map's actual draw area, not under the border.
	return Vector2(BORDER_THICKNESS + nx * map_size.x, BORDER_THICKNESS + nz * map_size.y)


var _is_panning: bool = false


func _gui_input(event: InputEvent) -> void:
	# Click on minimap to move camera; drag to keep panning while LMB is held.
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_is_panning = true
				_click_minimap(mb.position)
			else:
				_is_panning = false
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _is_panning:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_click_minimap(motion.position)
		get_viewport().set_input_as_handled()


func _click_minimap(local_pos: Vector2) -> void:
	var half_world: float = MAP_WORLD_SIZE / 2.0
	var map_size: Vector2 = size
	var world_x: float = (local_pos.x / map_size.x) * half_world * 2.0 - half_world
	var world_z: float = (local_pos.y / map_size.y) * half_world * 2.0 - half_world

	var cam: Camera3D = get_viewport().get_camera_3d()
	if not cam:
		return
	# Set both pivots — _target_pivot drives the smooth lerp in RTSCamera
	# and _pivot snaps the current position so clicks/drags feel responsive.
	cam.set("_target_pivot", Vector3(world_x, 0, world_z))
	cam.set("_pivot", Vector3(world_x, 0, world_z))
