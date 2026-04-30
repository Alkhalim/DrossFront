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
## Layer mask for raycast against wrecks (layer 8).
const WRECK_LAYER: int = 8

var _selected_units: Array[Unit] = []
## Selected Crawlers. Crawlers aren't Unit instances (different base class), so
## they live in a parallel list, but selection / move / drag-select code now
## treats both lists as one combined "movables" set so the player can mix and
## match the same way they would with units alone.
var _selected_crawlers: Array[SalvageCrawler] = []
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
## Cohort of same-type buildings selected together — populated by
## `_select_all_buildings_of_type` (the double-click path). The
## primary `_selected_building` is the one whose info panel shows in
## the HUD; queue commands fan out across the cohort, picking the
## member with the smallest current queue.
var _selected_buildings: Array[Building] = []
## After confirming a building placement on mouse-press, we want to swallow
## the corresponding mouse-release so it doesn't leak to `_click_select`
## and re-select the freshly-placed foundation. Cleared on the first
## release that consumes it.
var _suppress_next_release: bool = false
## Read-only inspection target — set when the player clicks an enemy or
## neutral unit/Crawler so the HUD can show its name + HP + stats. Doesn't
## interact with movement / attack commands; it's pure info display.
var _inspected_enemy: Node3D = null

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
			if _suppress_next_release:
				# A placement click consumed the press; swallow the matching
				# release so it doesn't drop into `_click_select` and
				# auto-select the new foundation.
				_suppress_next_release = false
				_is_dragging = false
				return
			if _is_dragging:
				_finish_box_select(event)
			else:
				_click_select(event)
			_is_dragging = false

	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# Ctrl-held → queue this command after whatever the unit is already
		# doing instead of replacing it. Only the plain move path supports
		# queueing for now (attack / assist / rally still replace).
		var queue: bool = event.ctrl_pressed
		if _selected_building and _selected_building.stats and not _selected_building.stats.producible_units.is_empty() and _selection_movables_count() == 0:
			_set_rally_point(event.position)
		elif _attack_move_mode:
			_command_attack_move(event.position)
			_attack_move_mode = false
		elif _patrol_target_mode:
			_command_patrol(event.position)
			_patrol_target_mode = false
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
					_command_move(event.position, queue)
		get_viewport().set_input_as_handled()


func _selection_movables_count() -> int:
	# Combined live count across units + crawlers — used to decide whether a
	# right-click should issue a move or fall through to building rally-point
	# / no-op behaviors.
	var n: int = 0
	for u: Unit in _selected_units:
		if is_instance_valid(u) and u.alive_count > 0:
			n += 1
	for c: SalvageCrawler in _selected_crawlers:
		if is_instance_valid(c) and c.alive_count > 0:
			n += 1
	return n


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
				_patrol_target_mode = false
				get_viewport().set_input_as_handled()
				return
			# S key = Stand Ground / Hold Position
			if key.keycode == KEY_S and not _selected_units.is_empty():
				command_hold_position_on_selection()
				get_viewport().set_input_as_handled()
				return
			# P key = Patrol target mode (next right-click sets endpoint)
			if key.keycode == KEY_P and not _selected_units.is_empty():
				_patrol_target_mode = true
				_attack_move_mode = false
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

	# Only select player-owned units. Enemy / neutral clicks become a
	# read-only "inspect this thing" — the HUD shows its name + stats
	# but the player can't command it.
	if unit and unit.owner_id != 0:
		_inspected_enemy = unit
		_clear_selection()
		_clear_crawler_selection()
		_deselect_building()
		get_viewport().set_input_as_handled()
		return
	# Clear stale inspection on any new click attempt — the new selection
	# (if any) will write to it; otherwise it just stays cleared.
	_inspected_enemy = null

	if unit:
		_deselect_building()
		if is_double and unit.stats:
			# Double-click: select all on-screen units of same type
			if not shift:
				_clear_crawler_selection()
			_select_all_of_type(unit.stats.unit_name)
		elif shift:
			if unit.is_selected:
				_remove_from_selection(unit)
			else:
				_add_to_selection(unit)
		else:
			_clear_selection()
			_clear_crawler_selection()
			_add_to_selection(unit)
	else:
		# Try selecting a Crawler — same combined-selection rules as units so
		# shift extends, plain click replaces, and a Crawler can be in the
		# same selection as combat mechs.
		var crawler := _raycast_crawler(event.position)
		if crawler and crawler.owner_id == 0:
			_deselect_building()
			if shift:
				if crawler in _selected_crawlers:
					_remove_crawler_from_selection(crawler)
				else:
					_add_crawler_to_selection(crawler)
			else:
				_clear_selection()
				_clear_crawler_selection()
				_add_crawler_to_selection(crawler)
		elif crawler and crawler.owner_id != 0:
			# Enemy / neutral Crawler — same inspect treatment as units.
			_inspected_enemy = crawler
			_clear_selection()
			_clear_crawler_selection()
			_deselect_building()
			get_viewport().set_input_as_handled()
			return
		else:
			# Try selecting a building
			var building := _find_building_at(event.position)
			if building:
				_clear_crawler_selection()
				if is_double and building.stats:
					_select_all_buildings_of_type(building.stats.building_id)
				else:
					if not shift:
						_clear_selection()
					_select_building(building)
			else:
				# Wreck click → just surface its remaining salvage value.
				# Doesn't clear other selections; treats the wreck as a
				# queryable info-only object.
				var wreck: Wreck = _raycast_wreck(event.position)
				if wreck:
					_show_wreck_readout(wreck)
				elif not shift:
					_clear_selection()
					_clear_crawler_selection()
					_deselect_building()

	get_viewport().set_input_as_handled()


func _raycast_wreck(screen_pos: Vector2) -> Wreck:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0, WRECK_LAYER)
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var collider: Object = result["collider"]
	if collider is Wreck:
		return collider as Wreck
	return null


func _show_wreck_readout(wreck: Wreck) -> void:
	## Spawn a tiny floating Label3D above the wreck displaying its
	## remaining salvage. Auto-fades after a couple of seconds so the
	## battlefield doesn't accumulate stale readouts.
	if not is_instance_valid(wreck):
		return
	var label := Label3D.new()
	label.text = "%d salvage" % wreck.salvage_remaining
	label.font_size = 28
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(0.95, 0.78, 0.32, 1.0)
	label.outline_size = 8
	label.outline_modulate = Color(0.0, 0.0, 0.0, 1.0)
	label.global_position = wreck.global_position + Vector3(0.0, 1.4, 0.0)
	get_tree().current_scene.add_child(label)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", label.global_position + Vector3(0.0, 0.6, 0.0), 1.6)
	tween.tween_property(label, "modulate:a", 0.0, 1.6).set_ease(Tween.EASE_IN).set_delay(0.6)
	tween.chain().tween_callback(label.queue_free)


func _finish_box_select(event: InputEventMouseButton) -> void:
	var rect := Rect2(_drag_start, event.position - _drag_start).abs()

	if not event.shift_pressed:
		_clear_selection()
		_clear_crawler_selection()
		_deselect_building()

	# Track the pre-drag size so we know whether the drag actually picked up
	# anything new; we play a single select sound at the end instead of one
	# per added unit (otherwise a 6-unit drag fires six clicks at once).
	var prev_unit_count: int = _selected_units.size()
	var prev_crawler_count: int = _selected_crawlers.size()

	# Check units against the screen-space rectangle
	var units := get_tree().get_nodes_in_group("units")
	for node: Node in units:
		var unit := node as Unit
		if not unit:
			continue
		var screen_pos := _camera.unproject_position(unit.global_position)
		if rect.has_point(screen_pos):
			_add_to_selection(unit, false)

	# Crawlers are scooped into the same drag rectangle so a sweep across the
	# base picks up the harvester alongside its escorts.
	var crawlers := get_tree().get_nodes_in_group("crawlers")
	for node: Node in crawlers:
		var crawler := node as SalvageCrawler
		if not crawler or crawler.owner_id != 0:
			continue
		var screen_pos := _camera.unproject_position(crawler.global_position)
		if rect.has_point(screen_pos):
			_add_crawler_to_selection(crawler, false)

	# Single select chime if anything new actually entered the selection.
	var added_anything: bool = (
		_selected_units.size() > prev_unit_count
		or _selected_crawlers.size() > prev_crawler_count
	)
	if added_anything and _audio:
		_audio.play_select()

	# If nothing movable was selected, check for a building in the box
	if _selected_units.is_empty() and _selected_crawlers.is_empty():
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


func _command_move(screen_pos: Vector2, queue: bool = false) -> void:
	_prune_selection()
	# Combined movables list — units and crawlers both honor command_move(target).
	var movables: Array = []
	for u: Unit in _selected_units:
		if is_instance_valid(u) and u.alive_count > 0:
			movables.append(u)
	for c: SalvageCrawler in _selected_crawlers:
		if is_instance_valid(c) and c.alive_count > 0:
			movables.append(c)
	if movables.is_empty():
		return
	# Don't cancel in-progress build tasks when *queueing* — the player wants
	# the engineer to finish what it's doing and then walk to the waypoint.
	if not queue:
		_cancel_builder_tasks()
	if _audio:
		_audio.play_command()

	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return

	# Simple formation: offset entries in a grid around the target. Crawlers
	# slot into the formation alongside units — the wider crawler footprint
	# is handled by the Crawler's collision response, not by special-casing
	# its formation slot.
	var count: int = movables.size()
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
		var slot: Vector3 = ground_pos + offset
		var movable: Object = movables[i]
		if queue and movable.has_method("queue_move"):
			movable.queue_move(slot)
		else:
			movable.command_move(slot)


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


## Stand Ground / Patrol mode flags driven by the unit-action panel.
var _patrol_target_mode: bool = false


func enter_attack_move_mode() -> void:
	## Public version of the 'A' hotkey toggle so the HUD button can
	## hand off the same flow.
	if not _selected_units.is_empty():
		_attack_move_mode = true
		_patrol_target_mode = false


func enter_patrol_target_mode() -> void:
	if _selected_units.is_empty():
		return
	_patrol_target_mode = true
	_attack_move_mode = false


func command_hold_position_on_selection() -> void:
	_prune_selection()
	if _selected_units.is_empty():
		return
	_cancel_builder_tasks()
	if _audio:
		_audio.play_command()
	for unit: Unit in _selected_units:
		if unit.has_method("command_hold_position"):
			unit.command_hold_position()


func _command_patrol(screen_pos: Vector2) -> void:
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
		if unit.has_method("command_patrol"):
			unit.command_patrol(ground_pos)


func _find_enemy_at(screen_pos: Vector2) -> Node3D:
	## Check if an enemy unit or building is under the click.
	var unit := _raycast_unit(screen_pos)
	if unit and unit.owner_id != 0:
		return unit

	# Check Crawlers — they aren't Unit instances and slip past
	# `_raycast_unit`'s typed cast, so without this branch right-clicking
	# an enemy Crawler did nothing and the player relied on auto-target.
	var crawler := _raycast_crawler(screen_pos)
	if crawler and crawler.owner_id != 0:
		return crawler

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
	var added: bool = false
	for node: Node in all_units:
		var unit: Unit = node as Unit
		if not unit or unit.owner_id != 0 or unit.alive_count <= 0:
			continue
		if not unit.stats or unit.stats.unit_name != unit_name:
			continue
		var screen_pos: Vector2 = _camera.unproject_position(unit.global_position)
		if viewport_rect.has_point(screen_pos):
			_add_to_selection(unit, false)
			added = true
	if added and _audio:
		_audio.play_select()


func _select_all_buildings_of_type(building_id: StringName) -> void:
	_clear_selection()
	_deselect_building()
	# Gather every on-screen, friendly building of this type into the
	# cohort. The first one becomes the panel-displayed primary; the rest
	# are eligible queue targets via load-balanced fan-out.
	var viewport_rect := get_viewport().get_visible_rect()
	var matches: Array[Building] = []
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not ("owner_id" in node) or node.get("owner_id") != 0:
			continue
		if not ("stats" in node) or node.get("stats") == null:
			continue
		var bstats: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not bstats or bstats.building_id != building_id:
			continue
		var screen_pos: Vector2 = _camera.unproject_position(node.global_position)
		if not viewport_rect.has_point(screen_pos):
			continue
		var b: Building = node as Building
		if b:
			matches.append(b)

	if matches.is_empty():
		return
	# Primary = the first match (closest to top-left); _select_building
	# also resets the cohort to just that one, so we re-populate after.
	_select_building(matches[0])
	_selected_buildings = matches


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


## Last-recalled control group + timestamp so a second press of the same key
## within DOUBLE_PRESS_WINDOW jumps the camera to that group's centroid —
## standard RTS muscle memory ("press 1 to select, press 1 again to find it").
const DOUBLE_PRESS_WINDOW: float = 0.4
var _last_recalled_group: int = -1
var _last_recalled_at: float = -1.0


func _recall_control_group(index: int) -> void:
	_clear_selection()
	_clear_crawler_selection()
	_deselect_building()
	var ids: Array = _control_groups[index]
	var added: bool = false
	for uid: int in ids:
		var obj: Object = instance_from_id(uid)
		if obj and obj is Unit:
			var unit: Unit = obj as Unit
			if is_instance_valid(unit) and unit.alive_count > 0:
				_add_to_selection(unit, false)
				added = true
	if added and _audio:
		_audio.play_select()

	# Double-press detection: same group within the window pans the camera
	# to where those units are right now.
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if _last_recalled_group == index and (now - _last_recalled_at) < DOUBLE_PRESS_WINDOW:
		_jump_camera_to_selection()
	_last_recalled_group = index
	_last_recalled_at = now


func _jump_camera_to_selection() -> void:
	# Centroid of the currently-selected units; nothing to jump to if dead /
	# empty (e.g. control group's units were all destroyed before recall).
	var sum := Vector3.ZERO
	var count: int = 0
	for unit: Unit in _selected_units:
		if not is_instance_valid(unit) or unit.alive_count <= 0:
			continue
		sum += unit.global_position
		count += 1
	if count == 0:
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if not cam:
		return
	var centroid: Vector3 = sum / float(count)
	cam.set("_pivot", Vector3(centroid.x, 0.0, centroid.z))
	cam.set("_target_pivot", Vector3(centroid.x, 0.0, centroid.z))


func get_selected_units() -> Array[Unit]:
	return _selected_units


func get_buildable_stats() -> Array[BuildingStatResource]:
	return _buildable_stats


func _add_to_selection(unit: Unit, play_audio: bool = true) -> void:
	if not is_instance_valid(unit) or unit.owner_id != 0:
		return
	if unit in _selected_units:
		return
	_selected_units.append(unit)
	unit.select()
	if play_audio and _audio:
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
	## Remove freed or dead units / crawlers from the selection so command
	## iterators don't trip over stale references.
	var i: int = _selected_units.size() - 1
	while i >= 0:
		var unit: Unit = _selected_units[i]
		if not is_instance_valid(unit) or unit.alive_count <= 0:
			_selected_units.remove_at(i)
		i -= 1
	var ci: int = _selected_crawlers.size() - 1
	while ci >= 0:
		var crawler: SalvageCrawler = _selected_crawlers[ci]
		if not is_instance_valid(crawler) or crawler.alive_count <= 0:
			_selected_crawlers.remove_at(ci)
		ci -= 1


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
	## Find a building under the click. Filters to *local-player-owned*
	## buildings only — clicking on an ally's foundry shouldn't count as a
	## selection (the player would otherwise be able to queue units from
	## the ally's HQ on the player's own resource budget). Enemy / ally
	## buildings are discoverable through other paths (right-click attack,
	## minimap dot, perspective coloring) so they're never invisible, just
	## not commandable.
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
		# Local-player owned only.
		if not ("owner_id" in node) or node.get("owner_id") != 0:
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
		_hide_attack_range(_selected_building)
	_selected_building = building
	_selected_building.select_building()
	_show_yard_range(building)
	_show_attack_range(building)
	# Single-select path also resets the cohort to just this building so
	# subsequent queue calls don't fan out to a stale double-click set.
	_selected_buildings.clear()
	_selected_buildings.append(building)
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
		_hide_attack_range(_selected_building)
	_selected_building = null
	_selected_buildings.clear()
	_hide_rally_marker()


func _show_attack_range(building: Building) -> void:
	## Adds a translucent disc at the building's footprint matching its
	## turret range. Stores it as a child so `_hide_attack_range` can
	## kill it on deselect.
	if not building or not building.stats:
		return
	if building.stats.building_id != &"gun_emplacement":
		return
	if building.has_node("SelectionAttackRange"):
		return  # Already showing.
	var ring := MeshInstance3D.new()
	ring.name = "SelectionAttackRange"
	var disc := CylinderMesh.new()
	var radius: float = TurretComponent.TURRET_RANGE
	# If the turret component is live, take its actual range (covers
	# upgraded profiles in case we add range modifiers later).
	var turret: Node = building.get_node_or_null("TurretComponent")
	if turret and turret.has_method("get_range"):
		radius = turret.get_range()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.04
	disc.radial_segments = 64
	ring.mesh = disc
	ring.position.y = 0.06
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.4, 0.35, 0.30)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.4, 0.35, 1.0)
	mat.emission_energy_multiplier = 0.4
	ring.set_surface_override_material(0, mat)
	building.add_child(ring)


func _hide_attack_range(building: Building) -> void:
	if not building:
		return
	var ring: Node = building.get_node_or_null("SelectionAttackRange")
	if ring:
		ring.queue_free()


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
	# Back-compat: HUD reads this for the crawler info panel. Returns the
	# first live crawler in the selection (or null) — the panel doesn't yet
	# render multi-crawler info, but the rest of the selection flow works.
	for c: SalvageCrawler in _selected_crawlers:
		if is_instance_valid(c):
			return c
	return null


func get_selected_crawlers() -> Array[SalvageCrawler]:
	return _selected_crawlers


func get_inspected_enemy() -> Node3D:
	if _inspected_enemy and not is_instance_valid(_inspected_enemy):
		_inspected_enemy = null
	return _inspected_enemy


func _add_crawler_to_selection(crawler: SalvageCrawler, play_audio: bool = true) -> void:
	if not is_instance_valid(crawler) or crawler.owner_id != 0:
		return
	if crawler in _selected_crawlers:
		return
	_selected_crawlers.append(crawler)
	crawler.select()
	if play_audio and _audio:
		_audio.play_select()


func _remove_crawler_from_selection(crawler: SalvageCrawler) -> void:
	_selected_crawlers.erase(crawler)
	if is_instance_valid(crawler):
		crawler.deselect()


func _clear_crawler_selection() -> void:
	for c: SalvageCrawler in _selected_crawlers:
		if is_instance_valid(c):
			c.deselect()
	_selected_crawlers.clear()


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


## Debounce rapid double-fires of the production button. Some inputs (a
## bouncy mouse click, or keyboard repeat after a held key) can deliver two
## "pressed" events within the same frame, which previously queued two
## units off a single intended click. 100ms is well below human
## double-click intent, so this never blocks legitimate fast queueing.
var _last_queue_msec: Dictionary = {}


func queue_unit_at_building(index: int) -> void:
	if not _selected_building or not _selected_building.stats:
		return
	if index < 0 or index >= _selected_building.stats.producible_units.size():
		return

	# Pick the cohort member with the smallest current queue. With a
	# single-foundry selection that's just `_selected_building` itself.
	# After a double-click cohort, queueing fans out so a player who
	# spammed the production button gets one unit per foundry instead
	# of all units stacking on the primary.
	var target: Building = _pick_lowest_queue_target()
	if not target:
		return

	var bid: int = target.get_instance_id()
	var now: int = Time.get_ticks_msec()
	var prev: int = (_last_queue_msec.get(bid, 0) as int)
	if (now - prev) < 100:
		return
	_last_queue_msec[bid] = now

	var unit_stats: UnitStatResource = target.stats.producible_units[index]
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
	target.queue_unit(unit_stats)
	if _audio:
		_audio.play_production_started()


func _pick_lowest_queue_target() -> Building:
	## Returns the cohort member with the smallest current queue size, or
	## the singular `_selected_building` when no cohort is active. Buildings
	## that have somehow drifted out of the same producible_units shape
	## (different building_id) are skipped — the cohort should already be
	## same-type via `_select_all_buildings_of_type`, but the guard makes
	## this resilient if other code paths populate `_selected_buildings`.
	if _selected_buildings.is_empty():
		return _selected_building
	var primary: Building = _selected_building
	var primary_id: StringName = primary.stats.building_id if primary and primary.stats else &""
	var best: Building = null
	var best_q: int = 0x7FFFFFFF
	for b: Building in _selected_buildings:
		if not is_instance_valid(b) or not b.is_constructed:
			continue
		if not b.stats or b.stats.building_id != primary_id:
			continue
		var q: int = b.get_queue_size() if b.has_method("get_queue_size") else 0
		if q < best_q:
			best_q = q
			best = b
	return best if best else primary


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

	# Attack-range ring on ghosts for buildings that fire at things.
	# Currently only the gun emplacement; other defensive types (SAM
	# site, etc.) drop in here later.
	if bstat.building_id == &"gun_emplacement":
		_attach_range_ring(ghost, TurretComponent.TURRET_RANGE, Color(0.95, 0.4, 0.35, 0.35))


func _attach_range_ring(parent: Node3D, radius: float, color: Color) -> void:
	## Flat translucent disc parented to the placement ghost so the player
	## sees what the turret will cover before committing.
	var ring := MeshInstance3D.new()
	ring.name = "RangeRing"
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.04
	disc.radial_segments = 64
	ring.mesh = disc
	ring.position.y = 0.05  # just above ground to avoid z-fighting
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.4
	ring.set_surface_override_material(0, mat)
	parent.add_child(ring)


func cancel_build_placement() -> void:
	_build_mode = false
	_build_stats = null
	if _build_ghost and is_instance_valid(_build_ghost):
		_build_ghost.queue_free()
	_build_ghost = null


## Margin added around units / terrain features when checking placement overlap.
const BUILD_OBSTACLE_MARGIN: float = 0.4
## Clear gap required between adjacent buildings.
## Bumped 0.8 → 2.6 so two adjacent player buildings leave enough room
## for a unit (≈1u collision capsule + a little clearance) to actually
## walk between them rather than wedge in the gap. The narrow-gap stuck
## bug was rooted in this — paths went through 0.8u corridors that the
## unit physically didn't fit through.
const BUILD_PLACEMENT_GAP: float = 2.6


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

	# Fuel deposits, wrecks, and terrain pieces all block placement.
	for group_name: String in ["fuel_deposits", "wrecks", "terrain", "elevation"]:
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
				# Ctrl OR Shift held → "stay in build mode" so the player can
				# drop the same foundation type repeatedly without re-pressing
				# the hotkey for each one. Two modifiers because some players
				# reach for one and some the other.
				_confirm_build_placement(mb.position, mb.ctrl_pressed or mb.shift_pressed)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_RIGHT:
				cancel_build_placement()
				get_viewport().set_input_as_handled()

	elif event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and key.keycode == KEY_ESCAPE:
			cancel_build_placement()
			get_viewport().set_input_as_handled()


func _confirm_build_placement(screen_pos: Vector2, keep_placing: bool = false) -> void:
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
			_audio.play_building_placed(building.global_position)
		# Swallow the click's matching mouse-release so it doesn't drop
		# through to `_click_select` and reselect the new foundation —
		# the player should keep their engineers selected after placing.
		_suppress_next_release = true
		# Ctrl held → reuse the same build_stats for the next click so
		# the player can chain a row of generators without re-pressing the
		# hotkey. Plain click ends placement after one drop.
		if keep_placing:
			start_build_placement(_build_stats)
		else:
			cancel_build_placement()
	else:
		# Not enough resources — keep placement mode active
		pass
