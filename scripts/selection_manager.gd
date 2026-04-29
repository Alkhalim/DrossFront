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
## Currently-selected Crawler (only one — Crawlers are individual units, not
## squads). Independent from _selected_units because Crawlers aren't Units.
var _selected_crawler: SalvageCrawler = null
var _is_dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _camera: Camera3D

## Build placement state.
var _build_mode: bool = false
var _build_stats: BuildingStatResource = null
## Now a full Building scene (in ghost mode) so the preview shows real geometry.
var _build_ghost: Node3D = null

## Currently selected building (if any).
var _selected_building: Building = null

## Attack-move mode: next right-click issues attack-move instead of move.
var _attack_move_mode: bool = false

## Control groups: index 0-9 maps to arrays of unit instance IDs.
var _control_groups: Array[Array] = []


var _audio: AudioManager = null

## Last unit pointed at by the mouse — kept so we can clear its hover bar
## when the cursor moves to a different unit.
var _hovered_unit: Unit = null


func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	_audio = get_tree().current_scene.get_node_or_null("AudioManager") as AudioManager
	for i: int in 10:
		_control_groups.append([])


func _process(_delta: float) -> void:
	_update_hover()


func _update_hover() -> void:
	if not _camera or _build_mode:
		_set_hover(null)
		return
	var hovered: Unit = _raycast_unit(get_viewport().get_mouse_position())
	_set_hover(hovered)


func _set_hover(unit: Unit) -> void:
	if _hovered_unit == unit:
		return
	if _hovered_unit and is_instance_valid(_hovered_unit):
		_hovered_unit.hp_bar_hovered = false
	_hovered_unit = unit
	if _hovered_unit and is_instance_valid(_hovered_unit):
		_hovered_unit.hp_bar_hovered = true


func _unhandled_input(event: InputEvent) -> void:
	if _build_mode:
		_handle_build_mode_input(event)
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)


var _pending_double_click: bool = false


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_start = event.position
			_is_dragging = false
			_pending_double_click = event.double_click
		else:
			# Mouse released
			if _is_dragging:
				_finish_box_select(event)
			else:
				_click_select(event)
			_is_dragging = false

	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if _selected_crawler and is_instance_valid(_selected_crawler):
			# Crawler is selected — right-click moves it.
			_command_crawler_move(event.position)
		elif _selected_building and _selected_building.stats and not _selected_building.stats.producible_units.is_empty():
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
				# Check if right-clicking a friendly under-construction building → assist
				var friendly_building := _find_building_at(event.position)
				if friendly_building and not friendly_building.is_constructed:
					_command_assist_build(friendly_building)
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
	_prune_selection()
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
	var is_double: bool = _pending_double_click
	_pending_double_click = false

	# Only select player-owned units
	if unit and unit.owner_id != 0:
		unit = null

	if unit:
		_deselect_building()
		_deselect_crawler()
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
		# Try selecting a Crawler — they live on the unit collision layer but
		# aren't Unit instances, so they get their own selection slot.
		var crawler := _raycast_crawler(event.position)
		if crawler and crawler.owner_id == 0:
			_clear_selection()
			_deselect_building()
			_select_crawler(crawler)
		else:
			# Try selecting a building
			var building := _find_building_at(event.position)
			if building:
				_deselect_crawler()
				if is_double and building.stats:
					_select_all_buildings_of_type(building.stats.building_id)
				else:
					if not shift:
						_clear_selection()
					_select_building(building)
			elif not shift:
				_clear_selection()
				_deselect_building()
				_deselect_crawler()

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
	_prune_selection()
	if _selected_units.is_empty():
		return
	_cancel_builder_tasks()
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


func _command_assist_build(building: Building) -> void:
	_prune_selection()
	for unit: Unit in _selected_units:
		var builder: Node = unit.get_builder()
		if builder and builder.has_method("start_building"):
			builder.start_building(building)
	if _audio:
		_audio.play_command()


func _command_attack(target: Node3D) -> void:
	_prune_selection()
	if _selected_units.is_empty():
		return
	_cancel_builder_tasks()
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
	_prune_selection()
	if _selected_units.is_empty():
		return
	_cancel_builder_tasks()
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
	_prune_selection()
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
	if not is_instance_valid(unit) or unit.owner_id != 0:
		return
	if unit in _selected_units:
		return
	_selected_units.append(unit)
	unit.select()
	if _audio:
		_audio.play_select()


func _remove_from_selection(unit: Unit) -> void:
	_selected_units.erase(unit)
	if is_instance_valid(unit):
		unit.deselect()


func _clear_selection() -> void:
	for unit: Unit in _selected_units:
		if is_instance_valid(unit):
			unit.deselect()
	_selected_units.clear()


func _command_crawler_move(screen_pos: Vector2) -> void:
	if not _selected_crawler or not is_instance_valid(_selected_crawler):
		return
	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return
	_selected_crawler.command_move(ground_pos)
	if _audio:
		_audio.play_command()


func _cancel_builder_tasks() -> void:
	## Tell every selected engineer to drop its current build target so the
	## subsequent move/attack command isn't immediately overridden by the
	## builder dragging the unit back to the construction site.
	for unit: Unit in _selected_units:
		if not is_instance_valid(unit):
			continue
		var builder: Node = unit.get_builder()
		if builder and builder.has_method("cancel_build"):
			builder.cancel_build()


func _prune_selection() -> void:
	## Remove freed or dead units from the selection so command iterators are safe.
	var i: int = _selected_units.size() - 1
	while i >= 0:
		var unit: Unit = _selected_units[i]
		if not is_instance_valid(unit) or unit.alive_count <= 0:
			_selected_units.remove_at(i)
		i -= 1


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


func _raycast_crawler(screen_pos: Vector2) -> SalvageCrawler:
	## Same UNIT_LAYER ray, but returns a SalvageCrawler. Crawlers occupy the
	## unit collision layer so their hitbox is clickable like a mech.
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0, UNIT_LAYER)
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var collider: Object = result["collider"]
	if collider is SalvageCrawler:
		return collider as SalvageCrawler
	if collider is Node:
		var parent: Node = (collider as Node).get_parent()
		if parent is SalvageCrawler:
			return parent as SalvageCrawler
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


func get_selected_crawler() -> SalvageCrawler:
	return _selected_crawler


func _select_crawler(crawler: SalvageCrawler) -> void:
	if _selected_crawler == crawler:
		return
	if _selected_crawler and is_instance_valid(_selected_crawler):
		_selected_crawler.deselect()
	_selected_crawler = crawler
	_selected_crawler.select()
	if _audio:
		_audio.play_select()


func _deselect_crawler() -> void:
	if _selected_crawler and is_instance_valid(_selected_crawler):
		_selected_crawler.deselect()
	_selected_crawler = null


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
## Maximum Crawlers per player (v3.3 §1.3 spec).
const CRAWLER_CAP: int = 3


func queue_unit_at_building(index: int) -> void:
	if not _selected_building or not _selected_building.stats:
		return
	if index < 0 or index >= _selected_building.stats.producible_units.size():
		return

	var unit_stats: UnitStatResource = _selected_building.stats.producible_units[index]
	var resource_mgr: ResourceManager = get_tree().current_scene.get_node("ResourceManager") as ResourceManager
	if not resource_mgr:
		return

	# Crawler cap — never queue if the player is already at 3 Crawlers
	# (or has 3 in flight, including ones still in production queue).
	if unit_stats.is_crawler and _crawler_count_for_owner(0) >= CRAWLER_CAP:
		if _audio:
			_audio.play_error()
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


func _crawler_count_for_owner(owner_id: int) -> int:
	## Count live + queued Crawlers belonging to the given owner.
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group("crawlers"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") == owner_id:
			count += 1
	# Also count any Crawler stats currently in the player's production queue.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if node.get("owner_id") != owner_id:
			continue
		if not node.has_method("get_queue_size"):
			continue
		var b: Building = node as Building
		if not b:
			continue
		# Peek at the queue via a method we add below if it doesn't exist.
		if b.has_method("get_queue_unit_count"):
			count += b.get_queue_unit_count("crawler")
	return count


## --- Build Placement Mode ---

func start_build_placement(bstat: BuildingStatResource) -> void:
	# Cancel any existing placement first
	if _build_mode:
		cancel_build_placement()

	_build_mode = true
	_build_stats = bstat

	# Spawn a real Building scene as the ghost so the preview shows the actual
	# silhouette (smokestacks, turrets, antenna farms, etc.), not just a box.
	# `is_ghost_preview = true` makes Building skip groups, collision, and
	# logic components — visuals only.
	var scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var ghost: Building = scene.instantiate() as Building
	ghost.is_ghost_preview = true
	ghost.stats = bstat
	ghost.owner_id = 0
	get_tree().current_scene.add_child(ghost)
	# Recolor every material under the ghost to a translucent green tint —
	# the validity update repaints to red when overlap is detected.
	_apply_ghost_tint(ghost, Color(0.25, 0.85, 0.3, 0.45))

	_build_ghost = ghost as Node3D


func cancel_build_placement() -> void:
	_build_mode = false
	_build_stats = null
	if _build_ghost and is_instance_valid(_build_ghost):
		_build_ghost.queue_free()
	_build_ghost = null


## Margin added around units / terrain features when checking placement overlap.
const BUILD_OBSTACLE_MARGIN: float = 0.4
## Clear gap required between adjacent buildings.
const BUILD_PLACEMENT_GAP: float = 0.8


func _is_valid_build_position(pos: Vector3) -> bool:
	## True when the build footprint at `pos` would not overlap any existing
	## building, unit, or terrain feature (fuel deposit, wreck).
	if not _build_stats:
		return false
	var half_x: float = _build_stats.footprint_size.x * 0.5
	var half_z: float = _build_stats.footprint_size.z * 0.5

	# Other buildings — AABB-vs-AABB in XZ.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.stats:
			continue
		var their_hx: float = b.stats.footprint_size.x * 0.5
		var their_hz: float = b.stats.footprint_size.z * 0.5
		var dx: float = absf(b.global_position.x - pos.x)
		var dz: float = absf(b.global_position.z - pos.z)
		if dx < (half_x + their_hx + BUILD_PLACEMENT_GAP) and dz < (half_z + their_hz + BUILD_PLACEMENT_GAP):
			return false

	# Units — treat each as a small disc.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var u: Node3D = node as Node3D
		if not u:
			continue
		var dx: float = absf(u.global_position.x - pos.x)
		var dz: float = absf(u.global_position.z - pos.z)
		if dx < (half_x + BUILD_OBSTACLE_MARGIN) and dz < (half_z + BUILD_OBSTACLE_MARGIN):
			return false

	# Fuel deposits and wrecks — terrain features that block placement.
	for group_name: String in ["fuel_deposits", "wrecks"]:
		for node: Node in get_tree().get_nodes_in_group(group_name):
			if not is_instance_valid(node):
				continue
			var f: Node3D = node as Node3D
			if not f:
				continue
			var dx: float = absf(f.global_position.x - pos.x)
			var dz: float = absf(f.global_position.z - pos.z)
			if dx < (half_x + BUILD_OBSTACLE_MARGIN) and dz < (half_z + BUILD_OBSTACLE_MARGIN):
				return false

	return true


func _update_ghost_validity_tint(pos: Vector3) -> void:
	if not _build_ghost:
		return
	var tint: Color = Color(0.25, 0.85, 0.3, 0.45)
	if not _is_valid_build_position(pos):
		tint = Color(0.95, 0.2, 0.18, 0.55)
	_apply_ghost_tint(_build_ghost, tint)


func _apply_ghost_tint(node: Node, tint: Color) -> void:
	## Walks the ghost tree and replaces every mesh's material with a
	## translucent emissive tint so the preview reads as a hologram.
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(tint.r, tint.g, tint.b)
		mat.emission_energy_multiplier = 0.45
		mi.set_surface_override_material(0, mat)
	for child: Node in node.get_children():
		_apply_ghost_tint(child, tint)


func _handle_build_mode_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		var ground_pos := _raycast_ground(motion.position)
		if ground_pos != Vector3.INF and _build_ghost:
			# The Building ghost's visual origin sits at ground level (its mesh
			# is offset internally), so place the root at the ground.
			_build_ghost.global_position = Vector3(ground_pos.x, 0.0, ground_pos.z)
			_update_ghost_validity_tint(ground_pos)

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

	# Reject placement that would overlap another building, a unit, or a
	# terrain feature (fuel deposit, wreck). Stay in build mode so the player
	# can adjust and try again.
	if not _is_valid_build_position(ground_pos):
		if _audio:
			_audio.play_error()
		return

	var resource_mgr: ResourceManager = get_tree().current_scene.get_node("ResourceManager") as ResourceManager
	if not resource_mgr:
		cancel_build_placement()
		return

	# Find the first selected engineer
	_prune_selection()
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
		# Every other selected engineer also walks over and builds — multiple
		# Ratchets share the work so a squad gets the whole task instead of
		# leaving three idle.
		for unit: Unit in _selected_units:
			if unit == builder_unit:
				continue
			var other_builder: Node = unit.get_builder()
			if other_builder and other_builder.has_method("start_building"):
				other_builder.start_building(building)
		if _audio:
			_audio.play_building_placed()
		cancel_build_placement()
	else:
		# Not enough resources — keep placement mode active
		pass
