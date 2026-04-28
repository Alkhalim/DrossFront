class_name SelectionManager
extends Node
## Handles unit selection (click, shift-click, box drag) and move commands.
## Attach to the test arena root. Requires an RTSCamera in the scene.

## Layer mask for raycast against units (layer 2).
const UNIT_LAYER: int = 2
## Layer mask for raycast against ground (layer 1).
const GROUND_LAYER: int = 1
## Layer mask for raycast against buildings (layer 4).
const BUILDING_LAYER: int = 4

var _selected_units: Array[Unit] = []
var _is_dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _camera: Camera3D

## Build placement state.
var _build_mode: bool = false
var _build_stats: BuildingStatResource = null
var _build_ghost: MeshInstance3D = null

## Currently selected building (if any).
var _selected_building: Building = null

## Attack-move mode: next right-click issues attack-move instead of move.
var _attack_move_mode: bool = false

## Control groups: index 0-9 maps to arrays of unit instance IDs.
var _control_groups: Array[Array] = []


var _audio: AudioManager = null


func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	_audio = get_tree().current_scene.get_node_or_null("AudioManager") as AudioManager
	for i: int in 10:
		_control_groups.append([])


func _unhandled_input(event: InputEvent) -> void:
	if _build_mode:
		_handle_build_mode_input(event)
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)


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

	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if _selected_building and _selected_building.stats and not _selected_building.stats.producible_units.is_empty():
			_set_rally_point(event.position)
		elif _attack_move_mode:
			_command_attack_move(event.position)
			_attack_move_mode = false
		else:
			# Check if right-clicking an enemy → attack command
			var enemy := _find_enemy_at(event.position)
			if enemy:
				_command_attack(enemy)
			else:
				_command_move(event.position)
		get_viewport().set_input_as_handled()


## Available buildings that engineers can construct.
var _buildable_stats: Array[BuildingStatResource] = []


func set_buildable_buildings(stats: Array[BuildingStatResource]) -> void:
	_buildable_stats = stats


func _input(event: InputEvent) -> void:
	# Detect drag threshold
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var motion := event as InputEventMouseMotion
		if not _is_dragging:
			var dist := (motion.position - _drag_start).length()
			if dist > 5.0:
				_is_dragging = true

	# Key handlers
	if event is InputEventKey and not _build_mode:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo:
			# A key = attack-move mode
			if key.keycode == KEY_A and not _selected_units.is_empty():
				_attack_move_mode = true
				get_viewport().set_input_as_handled()
				return

			# Control groups: Ctrl+0-9 = assign, 0-9 = recall
			var group_index: int = _key_to_group_index(key.keycode)
			if group_index >= 0:
				if key.ctrl_pressed:
					_assign_control_group(group_index)
					get_viewport().set_input_as_handled()
					return
				elif not _selected_building:
					_recall_control_group(group_index)
					get_viewport().set_input_as_handled()
					return

			_handle_build_hotkey(key)


func _handle_build_hotkey(key: InputEventKey) -> void:
	# Production hotkeys when a building is selected (Q, W, E for units 1-3)
	if _selected_building and _selected_building.stats:
		var prod_index: int = -1
		match key.keycode:
			KEY_Q: prod_index = 0
			KEY_W: prod_index = 1
			KEY_E: prod_index = 2
		if prod_index >= 0:
			queue_unit_at_building(prod_index)
			get_viewport().set_input_as_handled()
			return

	# Build placement hotkeys when an engineer is selected (1-7)
	var has_engineer: bool = false
	for unit: Unit in _selected_units:
		if unit.get_builder():
			has_engineer = true
			break
	if not has_engineer:
		return

	var index: int = -1
	match key.keycode:
		KEY_1: index = 0
		KEY_2: index = 1
		KEY_3: index = 2
		KEY_4: index = 3
		KEY_5: index = 4
		KEY_6: index = 5
		KEY_7: index = 6

	if index >= 0 and index < _buildable_stats.size():
		start_build_placement(_buildable_stats[index])
		get_viewport().set_input_as_handled()


func _click_select(event: InputEventMouseButton) -> void:
	var unit := _raycast_unit(event.position)
	var shift := event.shift_pressed
	var is_double: bool = event.double_click

	# Only select player-owned units
	if unit and unit.owner_id != 0:
		unit = null

	if unit:
		_deselect_building()
		if is_double and unit.stats:
			# Double-click: select all on-screen units of same type
			_select_all_of_type(unit.stats.unit_name)
		elif shift:
			if unit.is_selected:
				_remove_from_selection(unit)
			else:
				_add_to_selection(unit)
		else:
			_clear_selection()
			_add_to_selection(unit)
	else:
		# Try selecting a building
		var building := _find_building_at(event.position)
		if building:
			if is_double and building.stats:
				# Double-click building: select all of same type on screen
				_select_all_buildings_of_type(building.stats.building_id)
			else:
				if not shift:
					_clear_selection()
				_select_building(building)
		elif not shift:
			_clear_selection()
			_deselect_building()

	get_viewport().set_input_as_handled()


func _finish_box_select(event: InputEventMouseButton) -> void:
	var rect := Rect2(_drag_start, event.position - _drag_start).abs()

	if not event.shift_pressed:
		_clear_selection()
		_deselect_building()

	# Check units against the screen-space rectangle
	var units := get_tree().get_nodes_in_group("units")
	for node: Node in units:
		var unit := node as Unit
		if not unit:
			continue
		var screen_pos := _camera.unproject_position(unit.global_position)
		if rect.has_point(screen_pos):
			_add_to_selection(unit)

	# If no units were selected, check for a building in the box
	if _selected_units.is_empty():
		var buildings := get_tree().get_nodes_in_group("buildings")
		for node: Node in buildings:
			var building: Building = node as Building
			if not building or not building.is_constructed:
				continue
			var screen_pos := _camera.unproject_position(building.global_position)
			if rect.has_point(screen_pos):
				_select_building(building)
				break

	get_viewport().set_input_as_handled()


func _command_move(screen_pos: Vector2) -> void:
	if _selected_units.is_empty():
		return
	if _audio:
		_audio.play_command()

	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return

	# Simple formation: offset units in a grid around the target
	var count := _selected_units.size()
	var cols := ceili(sqrt(float(count)))
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


func _command_attack(target: Node3D) -> void:
	if _selected_units.is_empty():
		return
	if _audio:
		_audio.play_command()
	for unit: Unit in _selected_units:
		var combat: Node = unit.get_combat()
		if combat and combat.has_method("set_target"):
			combat.set_target(target)
		else:
			# Non-combat units just move toward the target
			unit.command_move(target.global_position)


func _command_attack_move(screen_pos: Vector2) -> void:
	if _selected_units.is_empty():
		return
	if _audio:
		_audio.play_command()
	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return
	for unit: Unit in _selected_units:
		var combat: Node = unit.get_combat()
		if combat and combat.has_method("command_attack_move"):
			combat.command_attack_move(ground_pos)
		else:
			unit.command_move(ground_pos)


func _find_enemy_at(screen_pos: Vector2) -> Node3D:
	## Check if an enemy unit or building is under the click.
	var unit := _raycast_unit(screen_pos)
	if unit and unit.owner_id != 0:
		return unit

	# Check enemy buildings via screen projection
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if not ("owner_id" in node):
			continue
		var bowner: int = node.get("owner_id")
		if bowner == 0:
			continue
		if not ("stats" in node) or node.get("stats") == null:
			continue
		var bstats: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not bstats:
			continue
		var screen_center: Vector2 = _camera.unproject_position(node.global_position)
		var half_size: float = maxf(bstats.footprint_size.x, bstats.footprint_size.z) * 0.5
		var screen_edge: Vector2 = _camera.unproject_position(
			node.global_position + Vector3(half_size, 0, 0)
		)
		var pixel_radius: float = absf(screen_edge.x - screen_center.x) * 1.2
		if screen_pos.distance_to(screen_center) <= pixel_radius:
			return node as Node3D

	return null


func _select_all_of_type(unit_name: String) -> void:
	_clear_selection()
	_deselect_building()
	var viewport_rect := get_viewport().get_visible_rect()
	var all_units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in all_units:
		var unit: Unit = node as Unit
		if not unit or unit.owner_id != 0 or unit.alive_count <= 0:
			continue
		if not unit.stats or unit.stats.unit_name != unit_name:
			continue
		var screen_pos: Vector2 = _camera.unproject_position(unit.global_position)
		if viewport_rect.has_point(screen_pos):
			_add_to_selection(unit)


func _select_all_buildings_of_type(building_id: StringName) -> void:
	_clear_selection()
	_deselect_building()
	# For buildings we just select the first matching one
	# (building selection is single-select in this prototype)
	var viewport_rect := get_viewport().get_visible_rect()
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if not ("owner_id" in node) or node.get("owner_id") != 0:
			continue
		if not ("stats" in node) or node.get("stats") == null:
			continue
		var bstats: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not bstats or bstats.building_id != building_id:
			continue
		var screen_pos: Vector2 = _camera.unproject_position(node.global_position)
		if viewport_rect.has_point(screen_pos):
			var building: Building = node as Building
			if building:
				_select_building(building)
			break


## --- Control Groups ---

func _key_to_group_index(keycode: int) -> int:
	match keycode:
		KEY_0: return 0
		KEY_1: return 1
		KEY_2: return 2
		KEY_3: return 3
		KEY_4: return 4
		KEY_5: return 5
		KEY_6: return 6
		KEY_7: return 7
		KEY_8: return 8
		KEY_9: return 9
	return -1


func _assign_control_group(index: int) -> void:
	_control_groups[index] = []
	for unit: Unit in _selected_units:
		_control_groups[index].append(unit.get_instance_id())
	if _audio:
		_audio.play_select()


func _recall_control_group(index: int) -> void:
	_clear_selection()
	_deselect_building()
	var ids: Array = _control_groups[index]
	for uid: int in ids:
		var obj: Object = instance_from_id(uid)
		if obj and obj is Unit:
			var unit: Unit = obj as Unit
			if is_instance_valid(unit) and unit.alive_count > 0:
				_add_to_selection(unit)


func get_selected_units() -> Array[Unit]:
	return _selected_units


func get_buildable_stats() -> Array[BuildingStatResource]:
	return _buildable_stats


func _add_to_selection(unit: Unit) -> void:
	if unit in _selected_units:
		return
	_selected_units.append(unit)
	unit.select()
	if _audio:
		_audio.play_select()


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

	var collider: Object = result["collider"]
	if collider is Unit:
		return collider as Unit
	# Walk up in case collider is a child
	if collider is Node:
		var parent: Node = (collider as Node).get_parent()
		if parent is Unit:
			return parent as Unit
	return null


func _raycast_ground(screen_pos: Vector2) -> Vector3:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)

	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0, GROUND_LAYER)
	var result := space.intersect_ray(query)

	if result.is_empty():
		return Vector3.INF

	return result["position"] as Vector3


## --- Building Selection ---

func _find_building_at(screen_pos: Vector2) -> Building:
	## Find a building under the click by checking screen-space distance.
	## Uses the same unproject_position method proven to work for unit selection.
	var nearest: Building = null
	var nearest_dist: float = INF

	# Try typed group first, fall back to checking all StaticBody3D children
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")

	# Fallback: if no nodes in group, scan scene children directly
	if buildings.is_empty():
		var scene: Node = get_tree().current_scene
		for child: Node in scene.get_children():
			if child.has_method("get_queue_size"):
				buildings.append(child)

	for node: Node in buildings:
		# Accept any node that has the building interface
		if not node.has_method("get_queue_size"):
			continue
		if not ("stats" in node) or node.get("stats") == null:
			continue

		var bstats: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not bstats:
			continue

		# Project building center to screen space
		var screen_center: Vector2 = _camera.unproject_position(node.global_position)

		# Compute pixel-space radius from the building's footprint
		var half_size: float = maxf(bstats.footprint_size.x, bstats.footprint_size.z) * 0.5
		var screen_edge: Vector2 = _camera.unproject_position(
			node.global_position + Vector3(half_size, 0, 0)
		)
		var pixel_radius: float = absf(screen_edge.x - screen_center.x) * 1.2

		var dist: float = screen_pos.distance_to(screen_center)
		if dist <= pixel_radius and dist < nearest_dist:
			nearest_dist = dist
			nearest = node as Building
			# If typed cast fails, try duck-typing approach
			if not nearest:
				# Node has building interface but isn't typed as Building
				# This means building.gd failed to load — flag it
				print_debug("Building script not loaded on node: ", node.name)

	return nearest


func _select_building(building: Building) -> void:
	if _selected_building and _selected_building != building:
		_selected_building.deselect_building()
		_hide_yard_range(_selected_building)
	_selected_building = building
	_selected_building.select_building()
	_show_yard_range(building)
	if _audio:
		_audio.play_select()

	# Show rally point only for production buildings
	if building.stats and not building.stats.producible_units.is_empty():
		if building.rally_point != Vector3.ZERO:
			_set_rally_point_visual(building.rally_point)
	else:
		_hide_rally_marker()


func _deselect_building() -> void:
	if _selected_building:
		_selected_building.deselect_building()
		_hide_yard_range(_selected_building)
	_selected_building = null
	_hide_rally_marker()


func _show_yard_range(building: Building) -> void:
	var yard: Node = building.get_node_or_null("SalvageYardComponent")
	if yard and yard.has_method("show_range"):
		yard.show_range()


func _hide_yard_range(building: Building) -> void:
	var yard: Node = building.get_node_or_null("SalvageYardComponent")
	if yard and yard.has_method("hide_range"):
		yard.hide_range()


func _set_rally_point_visual(pos: Vector3) -> void:
	if not _rally_marker:
		_rally_marker = MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.3
		cyl.bottom_radius = 0.6
		cyl.height = 1.5
		_rally_marker.mesh = cyl

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.8, 0.2, 0.8)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.8, 0.2, 1.0)
		mat.emission_energy_multiplier = 1.5
		_rally_marker.set_surface_override_material(0, mat)

		get_tree().current_scene.add_child(_rally_marker)

	_rally_marker.visible = true
	_rally_marker.global_position = pos + Vector3(0, 0.75, 0)


func get_selected_building() -> Building:
	return _selected_building


## --- Rally Point ---

var _rally_marker: MeshInstance3D = null


func _set_rally_point(screen_pos: Vector2) -> void:
	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return
	_selected_building.rally_point = ground_pos
	_set_rally_point_visual(ground_pos)


func _hide_rally_marker() -> void:
	if _rally_marker:
		_rally_marker.visible = false


## Queue a unit at the selected building. Index maps to producible_units array.
func queue_unit_at_building(index: int) -> void:
	if not _selected_building or not _selected_building.stats:
		return
	if index < 0 or index >= _selected_building.stats.producible_units.size():
		return

	var unit_stats: UnitStatResource = _selected_building.stats.producible_units[index]
	var resource_mgr: ResourceManager = get_tree().current_scene.get_node("ResourceManager") as ResourceManager
	if not resource_mgr:
		return

	if not resource_mgr.can_afford(unit_stats.cost_salvage, unit_stats.cost_fuel):
		return
	if not resource_mgr.has_population(unit_stats.population):
		return

	resource_mgr.spend(unit_stats.cost_salvage, unit_stats.cost_fuel)
	resource_mgr.add_population(unit_stats.population)
	_selected_building.queue_unit(unit_stats)
	if _audio:
		_audio.play_production_started()


## --- Build Placement Mode ---

func start_build_placement(bstat: BuildingStatResource) -> void:
	# Cancel any existing placement first
	if _build_mode:
		cancel_build_placement()

	_build_mode = true
	_build_stats = bstat

	# Create ghost preview
	_build_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = bstat.footprint_size
	_build_ghost.mesh = box
	_build_ghost.position.y = bstat.footprint_size.y / 2.0

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.2, 0.8, 0.2, 0.3)
	_build_ghost.set_surface_override_material(0, mat)

	get_tree().current_scene.add_child(_build_ghost)


func cancel_build_placement() -> void:
	_build_mode = false
	_build_stats = null
	if _build_ghost and is_instance_valid(_build_ghost):
		_build_ghost.queue_free()
	_build_ghost = null


func _handle_build_mode_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		var ground_pos := _raycast_ground(motion.position)
		if ground_pos != Vector3.INF and _build_ghost:
			_build_ghost.global_position = Vector3(ground_pos.x, _build_stats.footprint_size.y / 2.0, ground_pos.z)

	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_LEFT:
				# Don't place if click was over a GUI element
				var gui_control: Control = get_viewport().gui_get_hovered_control()
				if gui_control:
					return
				_confirm_build_placement(mb.position)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_RIGHT:
				cancel_build_placement()
				get_viewport().set_input_as_handled()

	elif event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and key.keycode == KEY_ESCAPE:
			cancel_build_placement()
			get_viewport().set_input_as_handled()


func _confirm_build_placement(screen_pos: Vector2) -> void:
	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return

	var resource_mgr: ResourceManager = get_tree().current_scene.get_node("ResourceManager") as ResourceManager
	if not resource_mgr:
		cancel_build_placement()
		return

	# Find the first selected engineer
	var builder_unit: Unit = null
	for unit: Unit in _selected_units:
		if unit.get_builder():
			builder_unit = unit
			break

	if not builder_unit:
		cancel_build_placement()
		return

	var builder: BuilderComponent = builder_unit.get_builder()
	var building: Building = builder.place_building(_build_stats, ground_pos, resource_mgr)

	if building:
		if _audio:
			_audio.play_building_placed()
		cancel_build_placement()
	else:
		# Not enough resources — keep placement mode active
		pass
