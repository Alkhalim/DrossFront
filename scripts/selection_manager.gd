class_name SelectionManager
extends Node
## Handles unit selection (click, shift-click, box drag) and move commands.
## Attach to the test arena root. Requires an RTSCamera in the scene.

## Layer mask for raycast against units (layer 2).
const UNIT_LAYER: int = 2
## Layer mask for raycast against ground (layer 1).
const GROUND_LAYER: int = 1

var _selected_units: Array[Unit] = []
var _is_dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _camera: Camera3D


func _ready() -> void:
	_camera = get_viewport().get_camera_3d()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _is_dragging:
		# Redraw box selection rectangle
		queue_redraw()


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_start = event.position
			_is_dragging = false
		else:
			# Mouse released
			if _is_dragging:
				_finish_box_select(event)
			else:
				_click_select(event)
			_is_dragging = false
			queue_redraw()

	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_command_move(event.position)
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	# Detect drag threshold
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if not _is_dragging:
			var dist := (event.position - _drag_start).length()
			if dist > 5.0:
				_is_dragging = true


func _click_select(event: InputEventMouseButton) -> void:
	var unit := _raycast_unit(event.position)
	var shift := event.shift_pressed

	if unit:
		if shift:
			if unit.is_selected:
				_remove_from_selection(unit)
			else:
				_add_to_selection(unit)
		else:
			_clear_selection()
			_add_to_selection(unit)
	elif not shift:
		_clear_selection()

	get_viewport().set_input_as_handled()


func _finish_box_select(event: InputEventMouseButton) -> void:
	var rect := Rect2(_drag_start, event.position - _drag_start).abs()

	if not event.shift_pressed:
		_clear_selection()

	# Check all units against the screen-space rectangle
	var units := get_tree().get_nodes_in_group("units")
	for node: Node in units:
		var unit := node as Unit
		if not unit:
			continue
		var screen_pos := _camera.unproject_position(unit.global_position)
		if rect.has_point(screen_pos):
			_add_to_selection(unit)

	get_viewport().set_input_as_handled()


func _command_move(screen_pos: Vector2) -> void:
	if _selected_units.is_empty():
		return

	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return

	# Simple formation: offset units in a grid around the target
	var count := _selected_units.size()
	var cols := ceili(sqrtf(float(count)))
	var spacing := 2.5

	for i: int in count:
		var row := i / cols
		var col := i % cols
		var offset := Vector3(
			(col - (cols - 1) / 2.0) * spacing,
			0,
			(row - (cols - 1) / 2.0) * spacing
		)
		_selected_units[i].command_move(ground_pos + offset)


func _add_to_selection(unit: Unit) -> void:
	if unit in _selected_units:
		return
	_selected_units.append(unit)
	unit.select()


func _remove_from_selection(unit: Unit) -> void:
	_selected_units.erase(unit)
	unit.deselect()


func _clear_selection() -> void:
	for unit: Unit in _selected_units:
		unit.deselect()
	_selected_units.clear()


func _raycast_unit(screen_pos: Vector2) -> Unit:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)

	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0, UNIT_LAYER)
	var result := space.intersect_ray(query)

	if result.is_empty():
		return null

	var collider := result.collider
	if collider is Unit:
		return collider
	# Walk up in case collider is a child
	var parent := collider.get_parent()
	if parent is Unit:
		return parent
	return null


func _raycast_ground(screen_pos: Vector2) -> Vector3:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)

	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0, GROUND_LAYER)
	var result := space.intersect_ray(query)

	if result.is_empty():
		return Vector3.INF

	return result.position
