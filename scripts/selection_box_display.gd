class_name SelectionBoxDisplay
extends Control
## Draws the drag-selection rectangle on screen.

var _is_dragging: bool = false
var _start: Vector2 = Vector2.ZERO
var _end: Vector2 = Vector2.ZERO

var _box_color := Color(0.2, 0.9, 0.2, 0.15)
var _border_color := Color(0.2, 0.9, 0.2, 0.6)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_start = event.position
			_end = event.position
			_is_dragging = false
		else:
			_is_dragging = false
			queue_redraw()

	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end = event.position
		if not _is_dragging and (_end - _start).length() > 5.0:
			_is_dragging = true
		if _is_dragging:
			queue_redraw()


func _draw() -> void:
	if not _is_dragging:
		return
	var rect := Rect2(_start, _end - _start).abs()
	draw_rect(rect, _box_color, true)
	draw_rect(rect, _border_color, false, 1.5)
