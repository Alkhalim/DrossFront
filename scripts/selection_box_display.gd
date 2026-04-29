class_name SelectionBoxDisplay
extends Control
## Draws the drag-selection rectangle on screen. Sits above the HUD via a high
## z_index so the box is visible over panels and the minimap.

const DRAG_THRESHOLD: float = 5.0

var _is_dragging: bool = false
var _start: Vector2 = Vector2.ZERO
var _end: Vector2 = Vector2.ZERO

const FILL_COLOR: Color = Color(0.35, 1.0, 0.45, 0.18)
const BORDER_COLOR: Color = Color(0.45, 1.0, 0.55, 0.95)
const BORDER_GLOW: Color = Color(0.2, 0.8, 0.3, 0.55)


func _ready() -> void:
	# Render above the HUD layer so the rectangle is visible over panels.
	z_index = 10
	# Cover the full viewport so _draw can paint anywhere.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_start = mb.position
				_end = mb.position
				_is_dragging = false
			else:
				if _is_dragging:
					_is_dragging = false
					queue_redraw()

	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_end = motion.position
		if not _is_dragging and (_end - _start).length() > DRAG_THRESHOLD:
			_is_dragging = true
		if _is_dragging:
			queue_redraw()


func _draw() -> void:
	if not _is_dragging:
		return
	var rect := Rect2(_start, _end - _start).abs()
	# Thin outer glow for visibility against busy battlefields.
	var glow_rect := Rect2(rect.position - Vector2(1, 1), rect.size + Vector2(2, 2))
	draw_rect(glow_rect, BORDER_GLOW, false, 3.0)
	# Translucent fill + crisp inner border.
	draw_rect(rect, FILL_COLOR, true)
	draw_rect(rect, BORDER_COLOR, false, 1.5)
