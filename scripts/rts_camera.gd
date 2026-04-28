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


func _process(delta: float) -> void:
	var input_dir := Vector2.ZERO

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

	# Smooth interpolation — only position changes, rotation is fixed
	_pivot = _pivot.lerp(_target_pivot, 10.0 * delta)
	global_position = _pivot + _cam_offset
	size = lerpf(size, _target_size, 10.0 * delta)
