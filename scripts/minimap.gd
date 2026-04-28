class_name Minimap
extends Control
## Simple minimap showing unit/building positions as colored dots.

const MAP_WORLD_SIZE: float = 120.0
const DOT_SIZE: float = 3.0
const BUILDING_SIZE: float = 5.0
const DEPOSIT_SIZE: float = 4.0

var _player_color := Color(0.2, 0.5, 1.0, 1.0)
var _enemy_color := Color(1.0, 0.2, 0.15, 1.0)
var _neutral_color := Color(0.7, 0.6, 0.3, 1.0)
var _wreck_color := Color(0.4, 0.35, 0.25, 0.5)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var map_size: Vector2 = size
	var half_world: float = MAP_WORLD_SIZE / 2.0

	# Background
	draw_rect(Rect2(Vector2.ZERO, map_size), Color(0.08, 0.08, 0.07, 0.8))
	draw_rect(Rect2(Vector2.ZERO, map_size), Color(0.3, 0.3, 0.3, 0.5), false, 1.0)

	# Draw buildings
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if not is_instance_valid(node):
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		var color: Color = _player_color if node.get("owner_id") == 0 else _enemy_color
		draw_rect(Rect2(pos - Vector2(BUILDING_SIZE / 2.0, BUILDING_SIZE / 2.0), Vector2(BUILDING_SIZE, BUILDING_SIZE)), color)

	# Draw fuel deposits
	var deposits: Array[Node] = get_tree().get_nodes_in_group("fuel_deposits")
	for node: Node in deposits:
		if not is_instance_valid(node):
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		var dep_owner: int = node.get("owner_id") if "owner_id" in node else -1
		var color: Color = _neutral_color
		if dep_owner == 0:
			color = _player_color
		elif dep_owner > 0:
			color = _enemy_color
		# Diamond shape for deposits
		var pts := PackedVector2Array([
			pos + Vector2(0, -DEPOSIT_SIZE),
			pos + Vector2(DEPOSIT_SIZE, 0),
			pos + Vector2(0, DEPOSIT_SIZE),
			pos + Vector2(-DEPOSIT_SIZE, 0),
		])
		draw_colored_polygon(pts, color)

	# Draw wrecks
	var wrecks: Array[Node] = get_tree().get_nodes_in_group("wrecks")
	for node: Node in wrecks:
		if not is_instance_valid(node):
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		draw_circle(pos, 2.0, _wreck_color)

	# Draw units
	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not is_instance_valid(node):
			continue
		if "alive_count" in node and node.get("alive_count") <= 0:
			continue
		var pos: Vector2 = _world_to_map(node.global_position, map_size, half_world)
		var color: Color = _player_color if node.get("owner_id") == 0 else _enemy_color
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


func _world_to_map(world_pos: Vector3, map_size: Vector2, half_world: float) -> Vector2:
	var nx: float = (world_pos.x + half_world) / (half_world * 2.0)
	var nz: float = (world_pos.z + half_world) / (half_world * 2.0)
	return Vector2(nx * map_size.x, nz * map_size.y)


func _gui_input(event: InputEvent) -> void:
	# Click on minimap to move camera
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_click_minimap(mb.position)
			get_viewport().set_input_as_handled()


func _click_minimap(local_pos: Vector2) -> void:
	var half_world: float = MAP_WORLD_SIZE / 2.0
	var map_size: Vector2 = size
	var world_x: float = (local_pos.x / map_size.x) * half_world * 2.0 - half_world
	var world_z: float = (local_pos.y / map_size.y) * half_world * 2.0 - half_world

	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam and cam.has_method("_ready"):
		# Move camera pivot
		cam.set("_target_pivot", Vector3(world_x, 0, world_z))
		cam.set("_pivot", Vector3(world_x, 0, world_z))
