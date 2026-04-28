class_name RTSCamera
extends Camera3D
## Top-down orthogonal RTS camera with WASD panning, scroll zoom, and edge panning.

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

var _target_position: Vector3
var _target_size: float


func _ready() -> void:
	_target_position = global_position
	_target_size = size


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
	var direction := Vector3.ZERO

	# Keyboard panning
	if Input.is_action_pressed("camera_pan_up"):
		direction.z -= 1.0
	if Input.is_action_pressed("camera_pan_down"):
		direction.z += 1.0
	if Input.is_action_pressed("camera_pan_left"):
		direction.x -= 1.0
	if Input.is_action_pressed("camera_pan_right"):
		direction.x += 1.0

	# Edge panning
	if edge_pan_enabled:
		var mouse_pos := get_viewport().get_mouse_position()
		var viewport_size := get_viewport().get_visible_rect().size
		if mouse_pos.x < edge_pan_margin:
			direction.x -= 1.0
		elif mouse_pos.x > viewport_size.x - edge_pan_margin:
			direction.x += 1.0
		if mouse_pos.y < edge_pan_margin:
			direction.z -= 1.0
		elif mouse_pos.y > viewport_size.y - edge_pan_margin:
			direction.z += 1.0

	# Scale pan speed with zoom so it feels consistent
	var zoom_factor := size / 40.0

	if direction != Vector3.ZERO:
		direction = direction.normalized()
		_target_position.x += direction.x * pan_speed * zoom_factor * delta
		_target_position.z += direction.z * pan_speed * zoom_factor * delta

	# Smooth interpolation
	global_position = global_position.lerp(_target_position, 10.0 * delta)
	size = lerpf(size, _target_size, 10.0 * delta)
