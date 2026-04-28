class_name RTSCamera
extends Camera3D
## Isometric-style RTS camera with WASD panning, scroll zoom, and edge panning.
## Uses orthographic projection at ~50 degree angle for good unit visibility.

## Pan speed in units per second.
@export var pan_speed: float = 30.0

## Zoom speed (orthographic size change per scroll tick).
@export var zoom_speed: float = 3.0

## Minimum orthographic size (closest zoom).
@export var zoom_min: float = 15.0

## Maximum orthographic size (farthest zoom).
@export var zoom_max: float = 80.0

## Pixels from screen edge that trigger edge panning.
@export var edge_pan_margin: int = 20

## Whether edge-of-screen panning is enabled.
@export var edge_pan_enabled: bool = true

## The point on the ground the camera looks at (pivot).
var _target_pivot: Vector3 = Vector3.ZERO
var _target_size: float = 40.0

## Camera angle from horizontal (radians). ~50 degrees.
const CAMERA_ANGLE: float = 0.87  # ~50 degrees in radians
const CAMERA_HEIGHT_FACTOR: float = 0.77  # sin(50°) ≈ 0.766
const CAMERA_DIST_FACTOR: float = 0.64  # cos(50°) ≈ 0.643


func _ready() -> void:
	_target_size = size
	# Initialize pivot from current position
	_target_pivot = Vector3(global_position.x, 0, global_position.z + global_position.y * CAMERA_DIST_FACTOR / CAMERA_HEIGHT_FACTOR)
	_update_camera_transform()


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


func _process(delta: float) -> void:
	var input_dir := Vector2.ZERO

	# Keyboard panning
	if Input.is_action_pressed("camera_pan_up"):
		input_dir.y -= 1.0
	if Input.is_action_pressed("camera_pan_down"):
		input_dir.y += 1.0
	if Input.is_action_pressed("camera_pan_left"):
		input_dir.x -= 1.0
	if Input.is_action_pressed("camera_pan_right"):
		input_dir.x += 1.0

	# Edge panning
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

	# Scale pan speed with zoom
	var zoom_factor := size / 40.0

	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()
		# Map screen directions to world XZ for isometric view
		# Screen right = world +X, screen up = world -Z
		_target_pivot.x += input_dir.x * pan_speed * zoom_factor * delta
		_target_pivot.z += input_dir.y * pan_speed * zoom_factor * delta

	# Smooth interpolation
	size = lerpf(size, _target_size, 10.0 * delta)
	_update_camera_transform_smooth(delta)


func _update_camera_transform() -> void:
	var cam_offset := Vector3(0, 30.0 * CAMERA_HEIGHT_FACTOR, 30.0 * CAMERA_DIST_FACTOR)
	global_position = _target_pivot + cam_offset
	look_at(_target_pivot, Vector3.UP)


func _update_camera_transform_smooth(delta: float) -> void:
	var cam_offset := Vector3(0, 30.0 * CAMERA_HEIGHT_FACTOR, 30.0 * CAMERA_DIST_FACTOR)
	var target_pos := _target_pivot + cam_offset
	global_position = global_position.lerp(target_pos, 10.0 * delta)
	look_at(_target_pivot, Vector3.UP)
