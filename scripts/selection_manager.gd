class_name SelectionManager
extends Node
## Handles unit selection (click, shift-click, box drag) and move commands.
## Attach to the test arena root. Requires an RTSCamera in the scene.

## Layer mask for raycast against units (layer 2).
const UNIT_LAYER: int = 2
## Layer mask for raycast against ground (layer 1).
const GROUND_LAYER: int = 1
## Surface raycast — ground (1) + terrain / elevation (4). Used by every
## click-to-world conversion (move commands, build placement, etc.) so the
## hit y reflects plateau tops, not the buried floor underneath. Without
## this, placing a building on a plateau dropped its origin to y=0 and
## the building rendered halfway sunken into the plateau.
const SURFACE_RAYCAST_MASK: int = 1 | 4
## Layer mask for raycast against buildings (layer 4).
const BUILDING_LAYER: int = 4
## Layer mask for raycast against wrecks (layer 8).
const WRECK_LAYER: int = 8

## Holds selected ground units (Unit) AND aircraft (Aircraft). Both
## expose the same selection surface (`is_selected`, `set_selected`,
## `command_move`, `command_attack_move`, `command_hold_position`,
## `command_patrol`, `alive_count`), so the array is typed as the
## common Node3D base and methods are dispatched via duck-typing.
var _selected_units: Array[Node3D] = []
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
	if not _camera:
		_set_hover(null)
		_update_cursor_kind(null)
		return
	if _build_mode:
		_set_hover(null)
		_update_cursor_kind_for_build_mode()
		return
	# Hover affects ground Units only (HP-bar reveal). Aircraft skip
	# hover treatment for now — `as Unit` returns null for Aircraft so
	# `_set_hover(null)` clears the previous hover cleanly.
	var screen_pos: Vector2 = get_viewport().get_mouse_position()
	var raw_hover: Node3D = _raycast_unit(screen_pos)
	var hovered: Unit = raw_hover as Unit
	_set_hover(hovered)
	_update_cursor_kind(raw_hover)


func _update_cursor_kind(hovered: Node3D) -> void:
	## Switch the system cursor based on what's under the pointer.
	## Attack reticle when an enemy unit / aircraft / building is
	## hovered (and the player has units selected to actually attack
	## with); repair wrench when an engineer is selected and a damaged
	## ally is hovered; default arrow otherwise.
	var cursor_mgr: Node = _get_cursor_manager()
	if not cursor_mgr:
		return
	# CursorManager.Kind enum values inlined since the class_name may
	# not be globally registered when this script first parses. Order
	# matches `enum Kind`: 0 DEFAULT 1 ATTACK 2 REPAIR 3 BUILD 4 MOVE.
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	if hovered and is_instance_valid(hovered):
		var owner_id: int = hovered.get("owner_id") as int if "owner_id" in hovered else -1
		if owner_id >= 0 and owner_id != 0:
			# Hostile or neutral non-player unit — attack reticle.
			if registry and registry.are_enemies(0, owner_id):
				cursor_mgr.set_kind(1)  # ATTACK
				return
		# Allied or own unit. Repair cursor when an engineer is selected
		# and the target is damaged.
		if _has_engineer_selected() and _is_damaged(hovered):
			cursor_mgr.set_kind(2)  # REPAIR
			return

	# No enemy unit under the cursor — check enemy / neutral buildings
	# too so the player gets the same attack-reticle feedback when
	# hovering over a structure they could right-click to attack.
	# Skipped when nothing is selected (no unit to attack with) so the
	# attack reticle doesn't flash on every passing structure during
	# camera pans.
	if not _selected_units.is_empty() or not _selected_crawlers.is_empty():
		var screen_pos: Vector2 = get_viewport().get_mouse_position()
		var building: Building = _find_building_at(screen_pos, false)
		if building and building.owner_id != 0:
			if registry and registry.are_enemies(0, building.owner_id):
				cursor_mgr.set_kind(1)  # ATTACK
				return
			# Neutral structures (owner_id == 2) — also hostile-attack
			# the player can manually engage them, so keep the reticle.
			if building.owner_id == 2:
				cursor_mgr.set_kind(1)
				return

	cursor_mgr.set_kind(0)  # DEFAULT


func _update_cursor_kind_for_build_mode() -> void:
	var cursor_mgr: Node = _get_cursor_manager()
	if cursor_mgr:
		cursor_mgr.set_kind(3)  # BUILD


func _get_cursor_manager() -> Node:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return null
	return scene.get_node_or_null("CursorManager")


func _has_engineer_selected() -> bool:
	for u: Node3D in _selected_units:
		if not is_instance_valid(u):
			continue
		if u is Unit:
			var unit: Unit = u as Unit
			if unit.stats and unit.stats.can_build:
				return true
	return false


func _is_damaged(node: Node3D) -> bool:
	if not is_instance_valid(node) or not "stats" in node:
		return false
	var stats_v: Variant = node.get("stats")
	if not stats_v or not "hp_total" in stats_v:
		return false
	# Both Unit and Aircraft expose `get_total_hp()`; if missing assume
	# fully healed.
	if not node.has_method("get_total_hp"):
		return false
	var hp_total: int = stats_v.get("hp_total") as int
	var hp_now: int = node.call("get_total_hp") as int
	return hp_now < hp_total


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
		if _selected_building and _selected_building.stats and not _selected_building.get_producible_units().is_empty() and _selection_movables_count() == 0:
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
	for u: Node3D in _selected_units:
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
			# D key = trigger active ability on every selected unit
			# whose stats define one. Cooldown gating happens
			# per-unit inside trigger_ability so a half-cooled
			# squad partial-fires.
			if key.keycode == KEY_D and not _selected_units.is_empty():
				var fired_any: bool = false
				for unit_node: Node3D in _selected_units:
					if is_instance_valid(unit_node) and unit_node.has_method("trigger_ability"):
						if unit_node.call("trigger_ability"):
							fired_any = true
				if fired_any:
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
	for unit: Node3D in _selected_units:
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
				# No friendly building hit — but we may still be over an
				# enemy structure. Same treatment as enemy units / Crawlers:
				# clear local selection, route to the inspect slot so the
				# HUD shows the building's name + stats, and bail before
				# the wreck branch swallows the click.
				var enemy_building: Building = _find_building_at(event.position, false)
				if enemy_building and enemy_building.owner_id != 0:
					_inspected_enemy = enemy_building
					_clear_selection()
					_clear_crawler_selection()
					_deselect_building()
					get_viewport().set_input_as_handled()
					return
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
	var label_pos: Vector3 = wreck.global_position + Vector3(0.0, 1.4, 0.0)
	get_tree().current_scene.add_child(label)
	label.global_position = label_pos
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", label_pos + Vector3(0.0, 0.6, 0.0), 1.6)
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

	# Check units against the screen-space rectangle. The "units" group
	# contains Units, Aircraft, SalvageCrawlers, and SalvageWorkers;
	# only the first two are command-selectable via this path. Crawlers
	# go through `_selected_crawlers` (handled below); workers aren't
	# directly commandable. Filter accordingly.
	var units := get_tree().get_nodes_in_group("units")
	for node: Node in units:
		var movable: Node3D = node as Node3D
		if not movable:
			continue
		# Only Unit or Aircraft (group "aircraft") are box-select targets.
		var is_aircraft: bool = movable.is_in_group("aircraft")
		if not (movable is Unit) and not is_aircraft:
			continue
		# Filter to the player's living units. owner_id and alive_count
		# exist on both Unit and Aircraft.
		if "owner_id" in movable and (movable.get("owner_id") as int) != 0:
			continue
		if "alive_count" in movable and (movable.get("alive_count") as int) <= 0:
			continue
		var screen_pos := _camera.unproject_position(movable.global_position)
		if rect.has_point(screen_pos):
			_add_to_selection(movable, false)

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
		# Unit selections speak instead of chiming — voiceline only.
		if _audio.has_method("play_voice_select"):
			_audio.play_voice_select()

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
	for u: Node3D in _selected_units:
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
	if _audio and _audio.has_method("play_voice_move"):
		_audio.play_voice_move()

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
	for unit: Node3D in _selected_units:
		var builder: Node = unit.get_builder()
		if builder and builder.has_method("start_building"):
			builder.start_building(building)
	# Engineer commanded to assist construction — unit action, so the
	# voiceline replaces the chime.
	if _audio and _audio.has_method("play_voice_build"):
		_audio.play_voice_build()


func _command_attack(target: Node3D) -> void:
	_prune_selection()
	if _selected_units.is_empty():
		return
	_cancel_builder_tasks()
	if _audio and _audio.has_method("play_voice_attack"):
		_audio.play_voice_attack()
	for unit: Node3D in _selected_units:
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
	if _audio and _audio.has_method("play_voice_attack"):
		_audio.play_voice_attack()
	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return
	for unit: Node3D in _selected_units:
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
	if _audio and _audio.has_method("play_voice_move"):
		_audio.play_voice_move()
	for unit: Node3D in _selected_units:
		if unit.has_method("command_hold_position"):
			unit.command_hold_position()


func _command_patrol(screen_pos: Vector2) -> void:
	_prune_selection()
	if _selected_units.is_empty():
		return
	_cancel_builder_tasks()
	if _audio and _audio.has_method("play_voice_move"):
		_audio.play_voice_move()
	var ground_pos := _raycast_ground(screen_pos)
	if ground_pos == Vector3.INF:
		return
	for unit: Node3D in _selected_units:
		if unit.has_method("command_patrol"):
			unit.command_patrol(ground_pos)


func _find_enemy_at(screen_pos: Vector2) -> Node3D:
	## Check if an *enemy* unit / Crawler / building is under the click.
	## Hostility is resolved through PlayerRegistry so 2v2 allies are
	## correctly skipped — `owner_id != 0` is not the right check, because
	## the AI ally (player_id 1, team 0) also has owner_id != 0.
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry

	var unit := _raycast_unit(screen_pos)
	if unit and _is_attack_target(unit.owner_id, registry):
		return unit

	# Check Crawlers — they aren't Unit instances and slip past
	# `_raycast_unit`'s typed cast, so without this branch right-clicking
	# an enemy Crawler did nothing and the player relied on auto-target.
	var crawler := _raycast_crawler(screen_pos)
	if crawler and _is_attack_target(crawler.owner_id, registry):
		return crawler

	# Check enemy buildings via screen projection. Footprint comes from
	# the BuildingStatResource if present, otherwise falls back to a
	# fixed 1.5u radius so destructible structures without `stats` (like
	# AmmoDump) are still right-clickable for manual attack.
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if not ("owner_id" in node):
			continue
		var bowner: int = node.get("owner_id")
		if not _is_attack_target(bowner, registry):
			continue
		var half_size: float = 1.5
		if "stats" in node and node.get("stats") != null:
			var bstats: BuildingStatResource = node.get("stats") as BuildingStatResource
			if bstats:
				half_size = maxf(bstats.footprint_size.x, bstats.footprint_size.z) * 0.5
		var screen_center: Vector2 = _camera.unproject_position(node.global_position)
		var screen_edge: Vector2 = _camera.unproject_position(
			node.global_position + Vector3(half_size, 0, 0)
		)
		var pixel_radius: float = absf(screen_edge.x - screen_center.x) * 1.2
		if screen_pos.distance_to(screen_center) <= pixel_radius:
			return node as Node3D

	return null


func _is_attack_target(target_owner: int, registry: PlayerRegistry) -> bool:
	## Returns true when the local player can legitimately attack-command a
	## unit/building owned by `target_owner` — i.e. it's not the local
	## player and not an ally. Falls back to the v1 "anything not owner 0"
	## rule when the registry isn't available (e.g. legacy scenes).
	if target_owner == 0:
		return false
	if registry and registry.has_method("are_enemies"):
		return registry.are_enemies(0, target_owner)
	return true


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
		# Unit selections speak instead of chiming — voiceline only.
		if _audio.has_method("play_voice_select"):
			_audio.play_voice_select()


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
	for unit: Node3D in _selected_units:
		_control_groups[index].append(unit.get_instance_id())
	if _audio:
		# Unit selections speak instead of chiming — voiceline only.
		if _audio.has_method("play_voice_select"):
			_audio.play_voice_select()


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
		# Unit selections speak instead of chiming — voiceline only.
		if _audio.has_method("play_voice_select"):
			_audio.play_voice_select()

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
	for unit: Node3D in _selected_units:
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


func get_selected_units() -> Array[Node3D]:
	# Returns ground Units AND Aircraft both — same array. Callers that
	# need Unit-specific behaviour should iterate with `if u is Unit:`.
	return _selected_units


func get_buildable_stats() -> Array[BuildingStatResource]:
	return _buildable_stats


func _add_to_selection(unit: Node3D, play_audio: bool = true) -> void:
	if not is_instance_valid(unit) or unit.owner_id != 0:
		return
	if unit in _selected_units:
		return
	_selected_units.append(unit)
	unit.select()
	if play_audio and _audio:
		# Unit selections speak instead of chiming — voiceline only.
		if _audio.has_method("play_voice_select"):
			_audio.play_voice_select()


func _remove_from_selection(unit: Node3D) -> void:
	_selected_units.erase(unit)
	if is_instance_valid(unit):
		unit.deselect()


func _clear_selection() -> void:
	for unit: Node3D in _selected_units:
		if is_instance_valid(unit):
			unit.deselect()
	_selected_units.clear()


func _cancel_builder_tasks() -> void:
	## Tell every selected engineer to drop its current build target so the
	## subsequent move/attack command isn't immediately overridden by the
	## builder dragging the unit back to the construction site.
	for unit: Node3D in _selected_units:
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
		var unit: Node3D = _selected_units[i]
		# Validity FIRST — `in unit` on a freed object errors with
		# "Invalid base object for 'in'", so we must guard before any
		# property access. Both Unit and Aircraft expose alive_count.
		var alive: int = 0
		if is_instance_valid(unit):
			alive = unit.get("alive_count") as int
		if not is_instance_valid(unit) or alive <= 0:
			_selected_units.remove_at(i)
		i -= 1
	var ci: int = _selected_crawlers.size() - 1
	while ci >= 0:
		var crawler: SalvageCrawler = _selected_crawlers[ci]
		if not is_instance_valid(crawler) or crawler.alive_count <= 0:
			_selected_crawlers.remove_at(ci)
		ci -= 1


func _raycast_unit(screen_pos: Vector2) -> Node3D:
	# Returns either a `Unit` or an `Aircraft` — both share the
	# selection / command surface and live in the same `units` group.
	# Aircraft register their click hitbox via an `Area3D` child on
	# UNIT_LAYER, so the ray hits the area and we walk up to recover
	# the Aircraft node. Ground units' ray hits the unit's own
	# collision shape directly.
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)

	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0, UNIT_LAYER)
	# Aircraft register their click hitbox as an Area3D (no physics body);
	# physics raycasts ignore Area3Ds by default, which is why aircraft
	# couldn't be clicked even though they could be drag-selected.
	# Enabling area collisions lets the ray hit the click area too.
	query.collide_with_areas = true
	var result := space.intersect_ray(query)

	if result.is_empty():
		return null

	var collider: Object = result["collider"]
	if collider is Unit:
		return collider as Unit
	# Aircraft are detected via the "aircraft" group rather than
	# `is Aircraft`. The class_name lookup was failing intermittently —
	# group membership is set in `Aircraft._ready` and doesn't depend
	# on Godot's global class registry being warm.
	if collider is Node3D and (collider as Node3D).is_in_group("aircraft"):
		return collider as Node3D
	# Walk up — the collider may be a CollisionShape3D child of the
	# aircraft's ClickArea (Area3D), which is itself a child of the
	# Aircraft node. Both layers need traversal to find the Aircraft.
	var node: Node = collider as Node
	for _i: int in 3:
		if not node:
			break
		var parent: Node = node.get_parent()
		if parent is Unit:
			return parent as Unit
		if parent is Node3D and (parent as Node3D).is_in_group("aircraft"):
			return parent as Node3D
		node = parent
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
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0, SURFACE_RAYCAST_MASK)
	var result := space.intersect_ray(query)

	if result.is_empty():
		return Vector3.INF

	return result["position"] as Vector3


## --- Building Selection ---

func _find_building_at(screen_pos: Vector2, local_only: bool = true) -> Building:
	## Find a building under the click. By default filters to
	## *local-player-owned* buildings — selecting an ally's foundry
	## shouldn't let the player queue units on their own budget. Pass
	## `local_only=false` to find any building under the cursor (used
	## by the enemy-inspect path so the player can left-click an enemy
	## structure to read its name and stats, the same as left-clicking
	## an enemy unit).
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
		if not ("owner_id" in node):
			continue
		if local_only and node.get("owner_id") != 0:
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
	# Buildings get the UI chime instead of a voiceline (per spec —
	# voicelines are unit-only). The replace_all that swapped chimes
	# for voicelines on every play_select call was too broad and
	# accidentally caught this site too.
	if _audio:
		_audio.play_select()

	# Show rally point only for production buildings
	if building.stats and not building.get_producible_units().is_empty():
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
	# Also light up wrecks the yard could reach right now.
	if yard and yard.has_method("get_collection_radius"):
		_refresh_yard_wreck_highlights(building.global_position, yard.get_collection_radius())


func _hide_yard_range(building: Building) -> void:
	var yard: Node = building.get_node_or_null("SalvageYardComponent")
	if yard and yard.has_method("hide_range"):
		yard.hide_range()
	_clear_yard_wreck_highlights()


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
		# Unit selections speak instead of chiming — voiceline only.
		if _audio.has_method("play_voice_select"):
			_audio.play_voice_select()


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
	# Faction-aware producible list — same source as the HUD buttons,
	# so the index passed in (mapped from a button click or hotkey)
	# resolves to the right Sable / Anvil unit.
	var selected_producible: Array[UnitStatResource] = _selected_building.get_producible_units()
	if index < 0 or index >= selected_producible.size():
		return

	# Pick the cohort member with the smallest current queue. With a
	# single-foundry selection that's just `_selected_building` itself.
	# After a double-click cohort, queueing fans out so a player who
	# spammed the production button gets one unit per foundry instead
	# of all units stacking on the primary.
	var target: Building = _pick_lowest_queue_target()
	if not target:
		return

	# Reject queue actions on a building that hasn't finished construction
	# yet. Without this check we'd spend resources + reserve population,
	# then `building.queue_unit` would silently return false (it gates on
	# is_constructed too) and the player would lose the cost with nothing
	# in the queue to show for it.
	if not target.is_constructed:
		if _audio:
			_audio.play_error()
		return

	var bid: int = target.get_instance_id()
	var now: int = Time.get_ticks_msec()
	var prev: int = (_last_queue_msec.get(bid, 0) as int)
	if (now - prev) < 100:
		return
	_last_queue_msec[bid] = now

	var target_producible: Array[UnitStatResource] = target.get_producible_units()
	if index >= target_producible.size():
		return
	var unit_stats: UnitStatResource = target_producible[index]
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

	# Building placement is a UI / building action — per spec, buildings
	# get sounds but no voicelines. Chime falls through via the existing
	# `play_command` callers; no voiceline here.

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

	# Salvage Yard / Crawler — show the worker harvest radius and highlight
	# every wreck inside it so the player can see what they'd be feeding.
	if bstat.building_id == &"salvage_yard":
		_attach_range_ring(ghost, SalvageYardComponent.COLLECTION_RADIUS, Color(0.9, 0.7, 0.2, 0.30))
		_refresh_yard_wreck_highlights(ghost.global_position, SalvageYardComponent.COLLECTION_RADIUS)


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
	_clear_yard_wreck_highlights()


## --- Salvage Yard wreck highlighting -----------------------------------------
## Tracks every wreck currently tinted by a yard's harvest preview, plus the
## original albedo of each so the highlight can be cleared cleanly. Used both
## for the placement ghost and for selecting an existing yard.

const _YARD_WRECK_HIGHLIGHT_COLOR := Color(1.0, 0.85, 0.35, 1.0)
var _highlighted_wrecks: Dictionary = {}


func _refresh_yard_wreck_highlights(center: Vector3, radius: float) -> void:
	# Recompute the highlight set for the current yard center / radius.
	# Wrecks that are no longer in range get their original tint back; new
	# wrecks in range get the highlight color.
	var in_range: Dictionary = {}
	var radius_sq: float = radius * radius
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		var wreck: Node3D = node as Node3D
		if not wreck:
			continue
		var dx: float = wreck.global_position.x - center.x
		var dz: float = wreck.global_position.z - center.z
		if dx * dx + dz * dz <= radius_sq:
			in_range[wreck.get_instance_id()] = wreck

	# Remove highlights from wrecks that are no longer in range.
	var to_drop: Array[int] = []
	for id: int in _highlighted_wrecks.keys():
		if not in_range.has(id):
			to_drop.append(id)
	for id: int in to_drop:
		_unhighlight_wreck(id)

	# Apply highlights to newly-in-range wrecks.
	for id: int in in_range.keys():
		if not _highlighted_wrecks.has(id):
			_highlight_wreck(in_range[id] as Node3D)


func _highlight_wreck(wreck: Node3D) -> void:
	# Walk every MeshInstance3D under the wreck, save the current albedo on
	# its material override, swap to the highlight tint. The wreck stores
	# the saved colors keyed by mesh instance id so _unhighlight can revert.
	var saved: Dictionary = {}
	for mesh: MeshInstance3D in _collect_mesh_instances(wreck):
		var mat: StandardMaterial3D = mesh.get_surface_override_material(0) as StandardMaterial3D
		if not mat:
			continue
		saved[mesh.get_instance_id()] = mat.albedo_color
		mat.albedo_color = mat.albedo_color.lerp(_YARD_WRECK_HIGHLIGHT_COLOR, 0.55)
		mat.emission_enabled = true
		mat.emission = _YARD_WRECK_HIGHLIGHT_COLOR
		mat.emission_energy_multiplier = 0.6
	_highlighted_wrecks[wreck.get_instance_id()] = {
		"wreck": wreck,
		"saved": saved,
	}


func _unhighlight_wreck(id: int) -> void:
	var entry: Variant = _highlighted_wrecks.get(id)
	if entry == null:
		_highlighted_wrecks.erase(id)
		return
	var data: Dictionary = entry as Dictionary
	# `is Node3D` errors with "Left operand of 'is' is a previously
	# freed instance" when the wreck has despawned since being
	# highlighted. is_instance_valid MUST come first — it safely
	# handles freed Variants. Only after validity passes do we use
	# `is` for the type narrowing.
	var wreck_var: Variant = data.get("wreck")
	if not is_instance_valid(wreck_var):
		_highlighted_wrecks.erase(id)
		return
	if not (wreck_var is Node3D):
		_highlighted_wrecks.erase(id)
		return
	var wreck: Node3D = wreck_var
	var saved: Dictionary = data.get("saved") as Dictionary
	for mesh: MeshInstance3D in _collect_mesh_instances(wreck):
		# A child mesh may have been freed independently between the
		# highlight call and this unhighlight (e.g. wreck collapsed
		# mid-frame). Skip freed meshes before touching their material.
		if not is_instance_valid(mesh):
			continue
		var mat: StandardMaterial3D = mesh.get_surface_override_material(0) as StandardMaterial3D
		if not mat:
			continue
		var orig: Variant = saved.get(mesh.get_instance_id())
		if orig != null:
			mat.albedo_color = orig as Color
		mat.emission_enabled = false
		mat.emission_energy_multiplier = 0.0
	_highlighted_wrecks.erase(id)


func _clear_yard_wreck_highlights() -> void:
	for id: int in _highlighted_wrecks.keys().duplicate():
		_unhighlight_wreck(id)


func _collect_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child: Node in root.get_children():
		if child is MeshInstance3D:
			out.append(child as MeshInstance3D)
		# Wreck visuals are typically one level deep, but recurse one more
		# level just in case a wreck script wraps mesh instances under a
		# transform node.
		for grandchild: Node in child.get_children():
			if grandchild is MeshInstance3D:
				out.append(grandchild as MeshInstance3D)
	return out


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
	## building, unit, or terrain feature (fuel deposit, wreck), AND the
	## footprint sits in cells the player has at least scouted at some
	## point. Placing in unexplored fog reveals enemy intel and lets you
	## drop foundations on terrain you've never seen, so block it.
	if not _build_stats:
		return false
	if not _is_build_position_explored(pos):
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
	# Plateaus / elevation are walkable surfaces — building ON TOP of
	# them is valid (the raycast already returned the plateau-top y).
	# Only block elevation overlap when the building's base would sit
	# at ground level (i.e., placement is below the plateau top).
	for group_name: String in ["fuel_deposits", "wrecks", "terrain"]:
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


func _is_build_position_explored(pos: Vector3) -> bool:
	## Returns true when the cell at `pos` AND the four corner cells of
	## the building's footprint have been scouted by the local player
	## (FogOfWar.is_explored_world). Black / never-seen cells reject
	## the placement; greyed-out / explored-but-not-currently-visible
	## cells pass. Tutorial / non-FOW scenes pass through.
	var fow: Node = get_tree().current_scene.get_node_or_null("FogOfWar") if get_tree() else null
	if not fow or not fow.has_method("is_explored_world"):
		return true
	if not _build_stats:
		return false
	var half_x: float = _build_stats.footprint_size.x * 0.5
	var half_z: float = _build_stats.footprint_size.z * 0.5
	var checks: Array[Vector3] = [
		pos,
		pos + Vector3(half_x, 0.0, half_z),
		pos + Vector3(-half_x, 0.0, half_z),
		pos + Vector3(half_x, 0.0, -half_z),
		pos + Vector3(-half_x, 0.0, -half_z),
	]
	for c: Vector3 in checks:
		if not (fow.call("is_explored_world", c) as bool):
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
			# Ghost origin matches the actual hit y so building on a
			# plateau places the building flush with the plateau top
			# (not sunken into the floor underneath).
			_build_ghost.global_position = ground_pos
			_update_ghost_validity_tint(ground_pos)
			# Salvage Yard ghost — refresh wreck highlights as the cursor
			# moves so the player can see which clusters fall in range.
			if _build_stats and _build_stats.building_id == &"salvage_yard":
				_refresh_yard_wreck_highlights(_build_ghost.global_position, SalvageYardComponent.COLLECTION_RADIUS)

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
	for unit: Node3D in _selected_units:
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
		for unit: Node3D in _selected_units:
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
