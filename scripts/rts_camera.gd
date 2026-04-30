class_name RTSCamera
extends Camera3D
## Isometric-style RTS camera with WASD panning, scroll zoom, and edge panning.
## Fixed rotation angle — only position changes, never tilts.

@export var pan_speed: float = 30.0
@export var zoom_speed: float = 3.0
@export var zoom_min: float = 15.0
@export var zoom_max: float = 80.0
@export var edge_pan_margin: int = 20
@export var edge_pan_enabled: bool = true

## The point on the ground the camera orbits around.
var _pivot: Vector3 = Vector3.ZERO
var _target_pivot: Vector3 = Vector3.ZERO
var _target_size: float = 40.0

## Fixed camera offset from pivot (set once at startup).
var _cam_offset: Vector3 = Vector3.ZERO

## Trauma-style screen shake. Callers (Unit._die, Building destruction) push
## an "amount" into _shake_trauma; we square it for nicer falloff.
var _shake_trauma: float = 0.0
const SHAKE_DECAY: float = 4.0
const SHAKE_MAX_OFFSET: float = 0.6


func add_shake(amount: float) -> void:
	_shake_trauma = clampf(_shake_trauma + amount, 0.0, 1.0)

## Camera pitch angle in degrees (50 = good isometric view).
const PITCH_DEG: float = 50.0


func _ready() -> void:
	_target_size = size

	# Compute fixed offset from angle
	var pitch_rad: float = deg_to_rad(PITCH_DEG)
	var arm_length: float = 30.0
	_cam_offset = Vector3(0, arm_length * sin(pitch_rad), arm_length * cos(pitch_rad))

	# Set fixed rotation once — never changes
	rotation_degrees = Vector3(-PITCH_DEG, 0, 0)

	# Initialize pivot
	_pivot = Vector3(global_position.x, 0, global_position.z)
	_target_pivot = _pivot
	global_position = _pivot + _cam_offset


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_target_size = maxf(_target_size - zoom_speed, zoom_min)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_target_size = minf(_target_size + zoom_speed, zoom_max)
				get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			if key.keycode == KEY_H:
				_jump_to_player_hq()
				get_viewport().set_input_as_handled()
			elif key.keycode == KEY_F1:
				_jump_to_player_army()
				get_viewport().set_input_as_handled()
			elif key.keycode == KEY_EQUAL or key.keycode == KEY_KP_ADD:
				_step_match_speed(1)
				get_viewport().set_input_as_handled()
			elif key.keycode == KEY_MINUS or key.keycode == KEY_KP_SUBTRACT:
				_step_match_speed(-1)
				get_viewport().set_input_as_handled()
			elif key.keycode == KEY_BACKSPACE:
				_reset_match_speed()
				get_viewport().set_input_as_handled()


## Match-speed control — discrete steps so the player can step through them
## by tapping +/-. Resetting via BACKSPACE returns to real time.
const MATCH_SPEEDS: Array[float] = [0.5, 1.0, 2.0, 4.0]


func _step_match_speed(direction: int) -> void:
	# `current_scale` (not `current`) — Camera3D has a `current` property
	# and shadowing it errors out under strict typing.
	var current_scale: float = Engine.time_scale
	var idx: int = 1  # default to 1.0
	for i: int in MATCH_SPEEDS.size():
		if absf(MATCH_SPEEDS[i] - current_scale) < 0.01:
			idx = i
			break
	idx = clampi(idx + direction, 0, MATCH_SPEEDS.size() - 1)
	_apply_match_speed(MATCH_SPEEDS[idx])


func _reset_match_speed() -> void:
	_apply_match_speed(1.0)


func _apply_match_speed(speed: float) -> void:
	Engine.time_scale = speed
	var alert_mgr: Node = get_tree().current_scene.get_node_or_null("AlertManager") if get_tree() else null
	if alert_mgr and alert_mgr.has_method("emit_alert"):
		alert_mgr.emit_alert("Match speed: %sx" % str(speed), 0, global_position, "match_speed", 0.5)


func _jump_to(world_pos: Vector3) -> void:
	# Both pivots updated so the smooth-lerp catches up cleanly without a
	# delayed slide. Y is forced to 0 — the pivot tracks the ground plane.
	var target := Vector3(world_pos.x, 0.0, world_pos.z)
	_pivot = target
	_target_pivot = target


func _jump_to_player_hq() -> void:
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != 0:
			continue
		var stats: Resource = node.get("stats") as Resource
		if stats and stats.get("building_id") == &"headquarters":
			_jump_to((node as Node3D).global_position)
			return
	# Fallback — any player building.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if is_instance_valid(node) and node.get("owner_id") == 0:
			_jump_to((node as Node3D).global_position)
			return


func _jump_to_player_army() -> void:
	# Prefer the currently selected units' centroid so the player can flick
	# back to whatever they're commanding. Fall back to the full army when
	# nothing is selected.
	var sel_mgr: Node = get_tree().current_scene.get_node_or_null("SelectionManager") if get_tree() else null
	var selected: Array = []
	if sel_mgr:
		var raw: Variant = sel_mgr.get("_selected_units")
		if raw is Array:
			selected = raw

	var sum := Vector3.ZERO
	var count: int = 0
	if not selected.is_empty():
		for unit: Object in selected:
			if not is_instance_valid(unit):
				continue
			var n3: Node3D = unit as Node3D
			if not n3:
				continue
			if "alive_count" in unit and (unit.get("alive_count") as int) <= 0:
				continue
			sum += n3.global_position
			count += 1

	if count == 0:
		# No (live) selection — jump to the centroid of all player units.
		for node: Node in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(node):
				continue
			if node.get("owner_id") != 0:
				continue
			if "alive_count" in node and (node.get("alive_count") as int) <= 0:
				continue
			sum += (node as Node3D).global_position
			count += 1

	if count > 0:
		_jump_to(sum / float(count))


func _process(delta: float) -> void:
	# Only read input while the game window is focused. Without this the camera
	# keeps scrolling whenever a stuck modifier or a mouse-near-edge state
	# remains "pressed" after alt-tabbing away.
	var window: Window = get_window()
	var window_focused: bool = window != null and window.has_focus()

	var input_dir := Vector2.ZERO

	if window_focused:
		if Input.is_action_pressed("camera_pan_up"):
			input_dir.y -= 1.0
		if Input.is_action_pressed("camera_pan_down"):
			input_dir.y += 1.0
		if Input.is_action_pressed("camera_pan_left"):
			input_dir.x -= 1.0
		if Input.is_action_pressed("camera_pan_right"):
			input_dir.x += 1.0

		if edge_pan_enabled:
			var mouse_pos := get_viewport().get_mouse_position()
			var viewport_size := get_viewport().get_visible_rect().size
			if mouse_pos.x < edge_pan_margin:
				input_dir.x -= 1.0
			elif mouse_pos.x > viewport_size.x - edge_pan_margin:
				input_dir.x += 1.0
			if mouse_pos.y < edge_pan_margin:
				input_dir.y -= 1.0
			elif mouse_pos.y > viewport_size.y - edge_pan_margin:
				input_dir.y += 1.0

	var zoom_factor := size / 40.0

	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()
		_target_pivot.x += input_dir.x * pan_speed * zoom_factor * delta
		_target_pivot.z += input_dir.y * pan_speed * zoom_factor * delta

	# Clamp to map bounds — Foundry Belt scale (±140 keeps the camera just
	# inside the navmesh's ±150 walkable area).
	_target_pivot.x = clampf(_target_pivot.x, -140.0, 140.0)
	_target_pivot.z = clampf(_target_pivot.z, -140.0, 140.0)

	# Smooth interpolation — only position changes, rotation is fixed
	_pivot = _pivot.lerp(_target_pivot, 10.0 * delta)
	global_position = _pivot + _cam_offset
	size = lerpf(size, _target_size, 10.0 * delta)

	# Trauma-based screen shake. Squared trauma → snappier falloff.
	if _shake_trauma > 0.0:
		_shake_trauma = maxf(0.0, _shake_trauma - SHAKE_DECAY * delta)
		var t: float = _shake_trauma * _shake_trauma
		var ox: float = randf_range(-1.0, 1.0) * SHAKE_MAX_OFFSET * t
		var oy: float = randf_range(-1.0, 1.0) * SHAKE_MAX_OFFSET * t
		global_position += Vector3(ox, 0.0, oy)
