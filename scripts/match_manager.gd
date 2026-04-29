class_name MatchManager
extends Node
## Tracks win/lose conditions. Destroy enemy HQ = victory. Lose yours = defeat.

signal match_over(victory: bool)

var _player_hq: Node = null
var _enemy_hqs: Array[Node] = []
var _match_ended: bool = false
var _victory_panel: Control = null
var _match_timer: float = 0.0


func _ready() -> void:
	call_deferred("_find_hqs")


func _find_hqs() -> void:
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		if not ("stats" in node):
			continue
		var stats: Resource = node.get("stats")
		if not stats or not ("building_id" in stats):
			continue
		if stats.get("building_id") != &"headquarters":
			continue
		var oid: int = node.get("owner_id")
		if oid == 0:
			_player_hq = node
			node.connect("destroyed", _on_player_hq_destroyed)
		else:
			_enemy_hqs.append(node)
			node.connect("destroyed", _on_enemy_hq_destroyed.bind(node))


func _process(delta: float) -> void:
	if _match_ended:
		return
	_match_timer += delta


func _on_player_hq_destroyed() -> void:
	if _match_ended:
		return
	_end_match(false)


func _on_enemy_hq_destroyed(hq: Node) -> void:
	_enemy_hqs.erase(hq)
	if _enemy_hqs.is_empty() and not _match_ended:
		_end_match(true)


func _end_match(victory: bool) -> void:
	_match_ended = true
	match_over.emit(victory)
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
	bg.color = Color(0.0, 0.0, 0.0, 0.6)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_victory_panel.add_child(bg)

	# Center container
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_victory_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if victory:
		title.text = "VICTORY"
		title.add_theme_color_override("font_color", Color(0.2, 0.9, 0.2, 1.0))
	else:
		title.text = "DEFEAT"
		title.add_theme_color_override("font_color", Color(0.9, 0.2, 0.2, 1.0))
	title.add_theme_font_size_override("font_size", 64)
	vbox.add_child(title)

	# Match time
	var mins: int = int(_match_timer) / 60
	var secs: int = int(_match_timer) % 60
	var time_label := Label.new()
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_label.text = "Match time: %d:%02d" % [mins, secs]
	time_label.add_theme_font_size_override("font_size", 24)
	vbox.add_child(time_label)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)

	# Restart button
	var restart_btn := Button.new()
	restart_btn.text = "Restart"
	restart_btn.custom_minimum_size = Vector2(220, 44)
	restart_btn.pressed.connect(_on_restart)
	vbox.add_child(restart_btn)

	# Main Menu button — return to the lobby for a fresh map / difficulty pick.
	var menu_btn := Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.custom_minimum_size = Vector2(220, 44)
	menu_btn.pressed.connect(_on_main_menu)
	vbox.add_child(menu_btn)

	# Pause the game
	get_tree().paused = true
	_victory_panel.process_mode = Node.PROCESS_MODE_ALWAYS


func _on_restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
