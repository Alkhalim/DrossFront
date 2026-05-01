class_name MatchManager
extends Node
## Tracks win/lose conditions per team. A team is eliminated when its last
## HQ-class building is destroyed; the local player's team winning fires
## VICTORY, losing fires DEFEAT. Works the same way for 1v1 (one HQ per
## team) and 2v2 (two HQs per team).

signal match_over(victory: bool)

## Per-HQ entry: { hq: Node, owner_id: int, team_id: int }
var _hqs: Array[Dictionary] = []
var _match_ended: bool = false
var _victory_panel: Control = null
var _match_timer: float = 0.0
var _registry: Node = null

## Lightweight stats tally — surfaced on the end screen so the player has
## something to read after the dust settles. Updated via signals from the
## existing combat / building paths so we don't have to instrument every
## damage call.
var _enemy_units_lost: int = 0    # squads on opposing team that died
var _own_units_lost: int = 0      # squads on local team that died
var _enemy_buildings_lost: int = 0
var _own_buildings_lost: int = 0


func _ready() -> void:
	call_deferred("_find_hqs")


func _find_hqs() -> void:
	_registry = get_tree().current_scene.get_node_or_null("PlayerRegistry")
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		_register_hq_if_eligible(node)

	# Wire up the kill counters for any units that already exist (rare —
	# usually only the starter armies). Future units register themselves
	# via the unit-spawned signal in _on_unit_added.
	for unit: Node in get_tree().get_nodes_in_group("units"):
		_attach_unit_listener(unit)
	# Catch units spawned mid-match (foundry production, AI replenishments).
	get_tree().node_added.connect(_on_node_added)


func _register_hq_if_eligible(node: Node) -> void:
	if not ("stats" in node):
		return
	var stats: Resource = node.get("stats")
	if not stats or not ("building_id" in stats):
		return
	if stats.get("building_id") != &"headquarters":
		return
	var oid: int = node.get("owner_id") as int
	var tid: int = (_registry.get_team(oid) as int) if _registry else (0 if oid == 0 else 1)
	_hqs.append({"hq": node, "owner_id": oid, "team_id": tid})
	node.connect("destroyed", _on_hq_destroyed.bind(node))
	# Buildings count toward the side-totals on the end screen.
	node.connect("destroyed", _on_building_destroyed.bind(oid))


func _on_node_added(node: Node) -> void:
	if node.is_in_group("units"):
		# Wait one frame so groups + properties are populated.
		call_deferred("_attach_unit_listener", node)
	elif node.is_in_group("buildings"):
		call_deferred("_register_hq_if_eligible", node)
		call_deferred("_attach_building_listener", node)


func _attach_unit_listener(unit: Node) -> void:
	if not is_instance_valid(unit):
		return
	if not unit.has_signal("squad_destroyed"):
		return
	if unit.is_connected("squad_destroyed", _on_unit_died):
		return
	var oid: int = unit.get("owner_id") as int
	unit.connect("squad_destroyed", _on_unit_died.bind(oid))


func _attach_building_listener(building: Node) -> void:
	if not is_instance_valid(building):
		return
	if not building.has_signal("destroyed"):
		return
	# Don't double-connect on HQs (already wired by _register_hq_if_eligible).
	for entry: Dictionary in _hqs:
		if entry["hq"] == building:
			return
	if building.is_connected("destroyed", _on_building_destroyed):
		return
	var oid: int = building.get("owner_id") as int
	building.connect("destroyed", _on_building_destroyed.bind(oid))


func _process(delta: float) -> void:
	if _match_ended:
		return
	_match_timer += delta


func _local_team() -> int:
	if not _registry:
		return 0
	var local_id: int = _registry.get("local_player_id") as int
	return _registry.get_team(local_id) as int


func _on_hq_destroyed(destroyed_node: Node) -> void:
	if _match_ended:
		return

	# Was this the local player's own HQ? If so, defeat is immediate —
	# losing your own HQ ends your game even if an ally is still alive.
	var lost_was_local_player: bool = false
	if _registry:
		for entry: Dictionary in _hqs:
			if entry["hq"] == destroyed_node:
				if (entry["owner_id"] as int) == (_registry.get("local_player_id") as int):
					lost_was_local_player = true
				break

	# Drop the entry for the fallen HQ.
	var i: int = _hqs.size() - 1
	while i >= 0:
		if _hqs[i]["hq"] == destroyed_node:
			_hqs.remove_at(i)
		i -= 1

	if lost_was_local_player:
		_end_match(false)
		return

	# Tally surviving HQs per team. Match ends as soon as one team has
	# zero HQs left.
	var local_team_alive: int = 0
	var enemy_teams_alive: int = 0
	var local_team_id: int = _local_team()
	for entry: Dictionary in _hqs:
		if (entry["team_id"] as int) == local_team_id:
			local_team_alive += 1
		else:
			enemy_teams_alive += 1

	if local_team_alive == 0:
		_end_match(false)
	elif enemy_teams_alive == 0:
		_end_match(true)


func _on_unit_died(owner_id: int) -> void:
	# Counts squads (a Hound dying = +1, not +2) so the end-screen totals
	# read at-a-glance rather than ballooning into per-member numbers.
	var local_team_id: int = _local_team()
	var their_team: int = (_registry.get_team(owner_id) as int) if _registry else (0 if owner_id == 0 else 1)
	if their_team == local_team_id:
		_own_units_lost += 1
	else:
		_enemy_units_lost += 1


func _on_building_destroyed(owner_id: int) -> void:
	var local_team_id: int = _local_team()
	var their_team: int = (_registry.get_team(owner_id) as int) if _registry else (0 if owner_id == 0 else 1)
	if their_team == local_team_id:
		_own_buildings_lost += 1
	else:
		_enemy_buildings_lost += 1


func _end_match(victory: bool) -> void:
	_match_ended = true
	match_over.emit(victory)
	# Defeat stinger — only on loss for now (no victory sample yet).
	if not victory:
		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_defeat"):
			audio.play_defeat()
	_show_end_screen(victory)


func _show_end_screen(victory: bool) -> void:
	# Create overlay
	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)

	_victory_panel = Control.new()
	_victory_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(_victory_panel)

	# Semi-transparent background
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.7)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_victory_panel.add_child(bg)

	# Center container
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_victory_panel.add_child(center)

	# Card — boxed group of widgets so the layout reads as a real screen
	# rather than text floating in the void.
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(440, 0)
	center.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(vbox)

	# Title.
	var title := Label.new()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if victory:
		title.text = "VICTORY"
		title.add_theme_color_override("font_color", Color(0.2, 0.9, 0.4, 1.0))
	else:
		title.text = "DEFEAT"
		title.add_theme_color_override("font_color", Color(0.95, 0.3, 0.25, 1.0))
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	title.add_theme_constant_override("outline_size", 6)
	vbox.add_child(title)

	# Match time + tally — formatted as a stat block.
	var mins: int = int(_match_timer) / 60
	var secs: int = int(_match_timer) % 60
	var stats := Label.new()
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.add_theme_font_size_override("font_size", 18)
	stats.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1.0))
	stats.text = "Match length: %d:%02d\n\nEnemy squads destroyed: %d\nOwn squads lost: %d\n\nEnemy buildings destroyed: %d\nOwn buildings lost: %d" % [
		mins, secs,
		_enemy_units_lost, _own_units_lost,
		_enemy_buildings_lost, _own_buildings_lost,
	]
	vbox.add_child(stats)

	# Spacer.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 16)
	vbox.add_child(spacer)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var restart_btn := Button.new()
	restart_btn.text = "Restart"
	restart_btn.custom_minimum_size = Vector2(180, 44)
	restart_btn.pressed.connect(_on_restart)
	btn_row.add_child(restart_btn)

	var menu_btn := Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.custom_minimum_size = Vector2(180, 44)
	menu_btn.pressed.connect(_on_main_menu)
	btn_row.add_child(menu_btn)

	# Pause the game — keep the panel responsive even though everything
	# else is frozen.
	get_tree().paused = true
	_victory_panel.process_mode = Node.PROCESS_MODE_ALWAYS


func _on_restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
