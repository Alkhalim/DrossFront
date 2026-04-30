class_name HUD
extends Control
## Prototype HUD: resource counters, selection info, production buttons.

var _resource_manager: ResourceManager = null
var _selection_manager: SelectionManager = null

## Track what we're showing to avoid rebuilding buttons every frame.
var _last_building_id: int = -1
var _last_unit_ids: Array[int] = []
var _showing_build_buttons: bool = false

## Pool of buttons + cached metadata so we can update affordability tint each frame.
## Each entry: { button: Button, kind: "produce"|"build", index: int }
var _action_buttons: Array[Dictionary] = []

## Optional progress bar shown inside the bottom panel for construction / queue / worker spawn.
var _progress_bar: ProgressBar = null

## Full-screen overlay shown while the tree is paused.
var _pause_overlay: Control = null

@onready var _salvage_label: Label = $TopBar/SalvageLabel as Label
@onready var _fuel_label: Label = $TopBar/FuelLabel as Label
@onready var _power_label: Label = $TopBar/PowerLabel as Label
@onready var _pop_label: Label = $TopBar/PopLabel as Label

## Power widget — built in _ready by `_build_power_widget`. Replaces the bare
## PowerLabel with a label + thin ProgressBar showing usage vs capacity.
var _power_bar: ProgressBar = null
var _power_bar_fill_style: StyleBoxFlat = null
@onready var _name_label: Label = $BottomPanel/HBox/InfoSection/NameLabel as Label
@onready var _stats_label: Label = $BottomPanel/HBox/InfoSection/StatsLabel as Label
@onready var _queue_label: Label = $BottomPanel/HBox/InfoSection/QueueLabel as Label
@onready var _action_label: Label = $BottomPanel/HBox/ActionSection/ActionLabel as Label
@onready var _button_grid: GridContainer = $BottomPanel/HBox/ActionSection/ButtonGrid as GridContainer
@onready var _bottom_panel: PanelContainer = $BottomPanel as PanelContainer
@onready var _timer_label: Label = $TopBar/MatchTimerLabel as Label
@onready var _info_section: VBoxContainer = $BottomPanel/HBox/InfoSection as VBoxContainer

var _match_time: float = 0.0

## Resource label palette — accent colors so each line is instantly readable.
const COLOR_SALVAGE := Color(0.95, 0.78, 0.32, 1.0)   # warm gold
const COLOR_FUEL := Color(0.4, 0.85, 1.0, 1.0)        # cyan
const COLOR_POWER := Color(1.0, 0.85, 0.35, 1.0)      # yellow
const COLOR_POP := Color(0.55, 0.95, 0.55, 1.0)       # green
const COLOR_TIMER := Color(0.85, 0.85, 0.85, 1.0)
const COLOR_WARN := Color(1.0, 0.4, 0.35, 1.0)        # red — low fuel / power deficit
const COLOR_NAME := Color(0.95, 0.92, 0.78, 1.0)
const COLOR_STATS := Color(0.85, 0.85, 0.85, 1.0)
const COLOR_QUEUE := Color(0.7, 0.85, 0.95, 1.0)
const COLOR_AFFORD_BAD := Color(0.5, 0.5, 0.5, 1.0)


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	_resource_manager = scene.get_node_or_null("ResourceManager") as ResourceManager
	_selection_manager = scene.get_node_or_null("SelectionManager") as SelectionManager
	_bottom_panel.visible = false

	# HUD must keep running while the tree is paused so the player can unpause.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_apply_theme()
	_apply_resource_colors()
	_build_progress_bar()
	_build_pause_overlay()
	_build_power_widget()
	_build_alert_banner()
	_build_gifting_panel()
	_build_global_queue_panel()

	# Tutorial overlay — shown only when the player launched via the Tutorial
	# button on the main menu. Dismisses with TAB or its own close button.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.get("tutorial_mode"):
		_build_tutorial_overlay()


## Tutorial state — tracked per step so the checklist can tick off as the
## player does each thing. Polled in _process when the overlay is visible.
const TUTORIAL_TASKS: Array[Dictionary] = [
	{ "id": "select_unit",       "label": "Click on one of your units (blue) to select it" },
	{ "id": "issue_move",        "label": "Right-click on empty ground to move the selected unit" },
	{ "id": "box_select",        "label": "Drag a box around multiple units to select them all" },
	{ "id": "attack_move",       "label": "Press A then right-click to issue an attack-move" },
	{ "id": "build_something",   "label": "With an engineer selected, press 1-7 and click to place a building" },
	{ "id": "train_unit",        "label": "Click your foundry and press Q/W to train a unit" },
	{ "id": "kill_enemy",        "label": "Destroy any enemy unit" },
]

var _tutorial_task_labels: Array = []  # Labels for ticking off
var _tutorial_progress: Dictionary = {}  # task_id → completed bool


func _build_tutorial_overlay() -> void:
	var overlay := PanelContainer.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	overlay.position = Vector2(-280, 56)
	overlay.custom_minimum_size = Vector2(560, 0)
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(overlay)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	overlay.add_child(inner)

	var title := Label.new()
	title.text = "Tutorial — complete the tasks below"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(title)

	# The task checklist — built once, updated each frame by _check_tutorial_progress.
	_tutorial_task_labels.clear()
	_tutorial_progress.clear()
	for task: Dictionary in TUTORIAL_TASKS:
		var lbl := Label.new()
		lbl.text = "  ☐  %s" % task["label"]
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95, 1.0))
		inner.add_child(lbl)
		_tutorial_task_labels.append(lbl)
		_tutorial_progress[task["id"]] = false

	# Quick-reference controls under the checklist.
	var sep := Control.new()
	sep.custom_minimum_size = Vector2(0, 8)
	inner.add_child(sep)
	var ctrl_title := Label.new()
	ctrl_title.text = "Controls"
	ctrl_title.add_theme_font_size_override("font_size", 14)
	ctrl_title.add_theme_color_override("font_color", Color(0.7, 0.85, 0.95, 1.0))
	inner.add_child(ctrl_title)
	for line: String in [
		"  Arrow keys / mouse edge — pan camera        Mouse wheel — zoom",
		"  Ctrl+0..9 assign control group        0..9 recall group",
		"  ESC pause / settings / main menu      TAB hide tutorial",
	]:
		var l := Label.new()
		l.text = line
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.7, 0.78, 0.85, 1.0))
		inner.add_child(l)

	var close_btn := Button.new()
	close_btn.text = "Dismiss"
	close_btn.custom_minimum_size = Vector2(120, 28)
	close_btn.pressed.connect(func() -> void: overlay.queue_free())
	inner.add_child(close_btn)

	# Cache so the TAB handler can free it.
	set_meta("tutorial_overlay", overlay)


func _check_tutorial_progress() -> void:
	## Called from _process while the overlay is visible. Polls game state
	## and ticks off completed tasks.
	if not has_meta("tutorial_overlay"):
		return
	var overlay: Node = get_meta("tutorial_overlay")
	if not is_instance_valid(overlay):
		remove_meta("tutorial_overlay")
		return
	if not _selection_manager:
		return

	var units: Array[Unit] = _selection_manager.get_selected_units()

	# Each task is independent — once done, stays done.
	if not _tutorial_progress.get("select_unit", false) and units.size() >= 1:
		_mark_task_done("select_unit")

	if not _tutorial_progress.get("issue_move", false):
		for u: Unit in units:
			if is_instance_valid(u) and u.has_move_order:
				_mark_task_done("issue_move")
				break

	if not _tutorial_progress.get("box_select", false) and units.size() >= 2:
		_mark_task_done("box_select")

	if not _tutorial_progress.get("attack_move", false):
		for u: Unit in units:
			if not is_instance_valid(u):
				continue
			var combat: Node = u.get_combat()
			if combat and combat.get("attack_move_target") != Vector3.INF:
				_mark_task_done("attack_move")
				break

	if not _tutorial_progress.get("build_something", false):
		for node: Node in get_tree().get_nodes_in_group("buildings"):
			if not is_instance_valid(node):
				continue
			if node.get("owner_id") == 0:
				var bid: StringName = (node.get("stats") as Resource).get("building_id") if node.get("stats") else &""
				# Headquarters spawns at game start so don't count it.
				if bid != &"" and bid != &"headquarters":
					_mark_task_done("build_something")
					break

	if not _tutorial_progress.get("train_unit", false):
		for node: Node in get_tree().get_nodes_in_group("buildings"):
			if not is_instance_valid(node):
				continue
			if node.get("owner_id") != 0:
				continue
			if node.has_method("get_queue_size") and node.get_queue_size() > 0:
				_mark_task_done("train_unit")
				break

	if not _tutorial_progress.get("kill_enemy", false):
		# Cheap proxy: any wreck with a salvage_value matching an AI unit.
		# More directly, watch for a unit count drop on owner_id != 0 — but
		# that requires storing previous counts. Use wreck-spawn instead.
		# We can't easily distinguish wrecks here, so fall back to a simple
		# "no enemy units alive that came from initial AI spawn" check —
		# any wreck created during the match counts as a kill.
		for w: Node in get_tree().get_nodes_in_group("wrecks"):
			if is_instance_valid(w):
				_mark_task_done("kill_enemy")
				break


func _mark_task_done(task_id: String) -> void:
	if _tutorial_progress.get(task_id, false):
		return
	_tutorial_progress[task_id] = true
	# Find the matching label and tick it.
	for i: int in TUTORIAL_TASKS.size():
		if TUTORIAL_TASKS[i].get("id") != task_id:
			continue
		if i < _tutorial_task_labels.size():
			var lbl: Label = _tutorial_task_labels[i] as Label
			if is_instance_valid(lbl):
				lbl.text = "  ☑  %s" % TUTORIAL_TASKS[i].get("label")
				lbl.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55, 1.0))
		break


func _build_power_widget() -> void:
	## Replace the bare PowerLabel with a small column: numeric label on top,
	## thin colored bar below. Tooltip explains what efficiency means.
	if not _power_label:
		return
	var top_bar: Node = _power_label.get_parent()
	if not top_bar:
		return
	var idx: int = _power_label.get_index()

	var col := VBoxContainer.new()
	col.tooltip_text = (
		"Power efficiency scales every powered building's output:\n"
		+ "• Foundries train units slower\n"
		+ "• Salvage yards spawn workers slower\n"
		+ "• Gun emplacements fire slower\n"
		+ "Efficiency floors at 25% even under heavy deficit."
	)
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_theme_constant_override("separation", 1)

	# Move the existing label into the column.
	top_bar.remove_child(_power_label)
	col.add_child(_power_label)

	_power_bar = ProgressBar.new()
	_power_bar.custom_minimum_size = Vector2(140, 5)
	_power_bar.show_percentage = false
	_power_bar.min_value = 0.0
	_power_bar.max_value = 100.0
	_power_bar.value = 0.0
	_power_bar.mouse_filter = Control.MOUSE_FILTER_PASS

	# Per-bar fill style we can recolor each frame without churning the theme.
	var template: StyleBoxFlat = _power_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if template:
		_power_bar_fill_style = template.duplicate() as StyleBoxFlat
	else:
		_power_bar_fill_style = StyleBoxFlat.new()
		_power_bar_fill_style.corner_radius_top_left = 2
		_power_bar_fill_style.corner_radius_top_right = 2
		_power_bar_fill_style.corner_radius_bottom_left = 2
		_power_bar_fill_style.corner_radius_bottom_right = 2
	_power_bar_fill_style.bg_color = COLOR_POWER
	_power_bar.add_theme_stylebox_override("fill", _power_bar_fill_style)

	col.add_child(_power_bar)

	top_bar.add_child(col)
	top_bar.move_child(col, idx)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			_toggle_pause()
			get_viewport().set_input_as_handled()
		elif key.pressed and not key.echo and key.keycode == KEY_TAB:
			# TAB toggles / dismisses the tutorial overlay.
			if has_meta("tutorial_overlay"):
				var overlay: Node = get_meta("tutorial_overlay")
				if is_instance_valid(overlay):
					overlay.queue_free()
				remove_meta("tutorial_overlay")
				get_viewport().set_input_as_handled()


func _toggle_pause() -> void:
	var tree: SceneTree = get_tree()
	tree.paused = not tree.paused
	if _pause_overlay:
		_pause_overlay.visible = tree.paused


func _build_pause_overlay() -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.55)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "Press ESC to resume"
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.7, 0.85, 0.95, 1.0))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	# Spacer.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18)
	vbox.add_child(spacer)

	# Volume slider — controls the master audio bus.
	var vol_label := Label.new()
	vol_label.text = "Master Volume"
	vol_label.add_theme_font_size_override("font_size", 16)
	vol_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
	vol_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(vol_label)

	var vol_slider := HSlider.new()
	vol_slider.custom_minimum_size = Vector2(280, 22)
	vol_slider.min_value = -40.0
	vol_slider.max_value = 6.0
	vol_slider.step = 1.0
	vol_slider.value = AudioServer.get_bus_volume_db(0)
	vol_slider.value_changed.connect(_on_volume_changed)
	vol_slider.process_mode = Node.PROCESS_MODE_ALWAYS
	vbox.add_child(vol_slider)

	# Spacer + return-to-menu button.
	var menu_spacer := Control.new()
	menu_spacer.custom_minimum_size = Vector2(0, 14)
	vbox.add_child(menu_spacer)

	var menu_btn := Button.new()
	menu_btn.text = "Return to Main Menu"
	menu_btn.custom_minimum_size = Vector2(220, 36)
	menu_btn.process_mode = Node.PROCESS_MODE_ALWAYS
	menu_btn.pressed.connect(_on_return_to_menu)
	vbox.add_child(menu_btn)

	_pause_overlay = overlay


func _on_return_to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_volume_changed(db: float) -> void:
	# 0 is the master bus — feed the dB value through directly. -40 dB ≈ silent,
	# 0 dB is the project default, +6 dB pushes a little hotter.
	AudioServer.set_bus_volume_db(0, db)


func _process(delta: float) -> void:
	_match_time += delta
	_update_resource_display()
	_update_selection_display()
	_update_button_affordability()
	_check_tutorial_progress()
	_refresh_gift_panel()
	_refresh_global_queue()


## --- Theme ---

func _apply_theme() -> void:
	## Dark-steel theme applied at the HUD root so every child Label/Button/Panel
	## inherits a consistent industrial look without per-node overrides in the .tscn.
	var theme_res := Theme.new()

	# Default font sizing — slightly larger so labels pop on a busy battlefield.
	theme_res.set_default_font_size(14)

	# --- Panel ---
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = Color(0.08, 0.09, 0.10, 0.88)
	panel_sb.border_color = Color(0.32, 0.34, 0.38, 1.0)
	panel_sb.set_border_width_all(1)
	panel_sb.corner_radius_top_left = 4
	panel_sb.corner_radius_top_right = 4
	panel_sb.corner_radius_bottom_left = 4
	panel_sb.corner_radius_bottom_right = 4
	panel_sb.content_margin_left = 12
	panel_sb.content_margin_right = 12
	panel_sb.content_margin_top = 8
	panel_sb.content_margin_bottom = 8
	theme_res.set_stylebox("panel", "PanelContainer", panel_sb)

	# --- Buttons ---
	var btn_normal := StyleBoxFlat.new()
	btn_normal.bg_color = Color(0.16, 0.18, 0.20, 1.0)
	btn_normal.border_color = Color(0.4, 0.42, 0.46, 1.0)
	btn_normal.set_border_width_all(1)
	btn_normal.corner_radius_top_left = 3
	btn_normal.corner_radius_top_right = 3
	btn_normal.corner_radius_bottom_left = 3
	btn_normal.corner_radius_bottom_right = 3
	btn_normal.content_margin_left = 6
	btn_normal.content_margin_right = 6
	btn_normal.content_margin_top = 4
	btn_normal.content_margin_bottom = 4

	var btn_hover := btn_normal.duplicate() as StyleBoxFlat
	btn_hover.bg_color = Color(0.24, 0.28, 0.32, 1.0)
	btn_hover.border_color = Color(0.7, 0.85, 0.95, 1.0)

	var btn_pressed := btn_normal.duplicate() as StyleBoxFlat
	btn_pressed.bg_color = Color(0.12, 0.14, 0.16, 1.0)
	btn_pressed.border_color = Color(0.95, 0.78, 0.32, 1.0)

	var btn_disabled := btn_normal.duplicate() as StyleBoxFlat
	btn_disabled.bg_color = Color(0.10, 0.10, 0.10, 0.95)
	btn_disabled.border_color = Color(0.55, 0.25, 0.22, 1.0)

	theme_res.set_stylebox("normal", "Button", btn_normal)
	theme_res.set_stylebox("hover", "Button", btn_hover)
	theme_res.set_stylebox("pressed", "Button", btn_pressed)
	theme_res.set_stylebox("disabled", "Button", btn_disabled)
	theme_res.set_stylebox("focus", "Button", btn_hover)
	theme_res.set_color("font_color", "Button", Color(0.95, 0.95, 0.95, 1.0))
	theme_res.set_color("font_hover_color", "Button", Color(1.0, 1.0, 1.0, 1.0))
	theme_res.set_color("font_disabled_color", "Button", Color(0.55, 0.55, 0.55, 1.0))

	# --- ProgressBar ---
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = Color(0.05, 0.06, 0.07, 1.0)
	pb_bg.border_color = Color(0.3, 0.32, 0.36, 1.0)
	pb_bg.set_border_width_all(1)
	pb_bg.corner_radius_top_left = 2
	pb_bg.corner_radius_top_right = 2
	pb_bg.corner_radius_bottom_left = 2
	pb_bg.corner_radius_bottom_right = 2

	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = Color(0.4, 0.85, 1.0, 0.95)
	pb_fill.corner_radius_top_left = 2
	pb_fill.corner_radius_top_right = 2
	pb_fill.corner_radius_bottom_left = 2
	pb_fill.corner_radius_bottom_right = 2

	theme_res.set_stylebox("background", "ProgressBar", pb_bg)
	theme_res.set_stylebox("fill", "ProgressBar", pb_fill)
	theme_res.set_color("font_color", "ProgressBar", Color(0.95, 0.95, 0.95, 1.0))

	theme = theme_res


func _apply_resource_colors() -> void:
	if _salvage_label: _salvage_label.add_theme_color_override("font_color", COLOR_SALVAGE)
	if _fuel_label: _fuel_label.add_theme_color_override("font_color", COLOR_FUEL)
	if _power_label: _power_label.add_theme_color_override("font_color", COLOR_POWER)
	if _pop_label: _pop_label.add_theme_color_override("font_color", COLOR_POP)
	if _timer_label: _timer_label.add_theme_color_override("font_color", COLOR_TIMER)
	if _name_label: _name_label.add_theme_color_override("font_color", COLOR_NAME)
	if _stats_label: _stats_label.add_theme_color_override("font_color", COLOR_STATS)
	if _queue_label: _queue_label.add_theme_color_override("font_color", COLOR_QUEUE)


func _build_progress_bar() -> void:
	# Inserted into the info section under the queue label; visibility toggled per selection.
	_progress_bar = ProgressBar.new()
	# Slim bar — roughly a third of the previous height/width so it doesn't
	# dominate the bottom panel.
	_progress_bar.custom_minimum_size = Vector2(120, 4)
	_progress_bar.show_percentage = false
	_progress_bar.visible = false
	if _info_section:
		_info_section.add_child(_progress_bar)


## --- Resource bar ---

func _update_resource_display() -> void:
	if not _resource_manager:
		return
	_salvage_label.text = "Salvage  %d" % _resource_manager.salvage

	# Fuel — turn red when below 20% capacity (early-warning).
	var fuel_pct: float = float(_resource_manager.fuel) / float(maxi(_resource_manager.fuel_cap, 1))
	_fuel_label.text = "Fuel  %d / %d" % [_resource_manager.fuel, _resource_manager.fuel_cap]
	_fuel_label.add_theme_color_override(
		"font_color",
		COLOR_WARN if fuel_pct < 0.2 else COLOR_FUEL
	)

	# Power — bar shows consumption-vs-production load. Color shifts green→
	# yellow→red as the load grows, with an extra red flag when in deficit.
	var produced: int = _resource_manager.power_production
	var consumed: int = _resource_manager.power_consumption
	var has_deficit: bool = consumed > produced
	var efficiency: float = _resource_manager.get_power_efficiency()
	var eff_str: String = ""
	if efficiency < 1.0:
		eff_str = "  (%d%%)" % int(efficiency * 100.0)
	_power_label.text = "Power  %d / %d%s" % [produced, consumed, eff_str]
	_power_label.add_theme_color_override(
		"font_color",
		COLOR_WARN if has_deficit else COLOR_POWER
	)

	# Bar value = load ratio (consumption / production), capped so deficit
	# pegs the bar at full but recolors red.
	var load_ratio: float = 0.0
	if produced > 0:
		load_ratio = float(consumed) / float(produced)
	elif consumed > 0:
		load_ratio = 1.5  # producing nothing but drawing — full red
	var bar_value: float = clampf(load_ratio, 0.0, 1.0) * 100.0
	if _power_bar:
		_power_bar.value = bar_value
		if _power_bar_fill_style:
			var fill_color: Color
			if load_ratio > 1.0:
				fill_color = COLOR_WARN  # deficit
			elif load_ratio > 0.85:
				fill_color = COLOR_POWER  # near capacity (yellow)
			elif load_ratio > 0.5:
				fill_color = Color(0.85, 0.95, 0.4, 1.0)  # light green
			else:
				fill_color = Color(0.4, 0.95, 0.4, 1.0)  # comfortable green
			_power_bar_fill_style.bg_color = fill_color

	# Population — yellow when >= 90%, red when capped.
	var pop_pct: float = float(_resource_manager.population) / float(ResourceManager.POPULATION_CAP)
	_pop_label.text = "Pop  %d / %d" % [_resource_manager.population, ResourceManager.POPULATION_CAP]
	if pop_pct >= 1.0:
		_pop_label.add_theme_color_override("font_color", COLOR_WARN)
	elif pop_pct >= 0.9:
		_pop_label.add_theme_color_override("font_color", COLOR_POWER)
	else:
		_pop_label.add_theme_color_override("font_color", COLOR_POP)

	# Match timer
	if _timer_label:
		var mins: int = int(_match_time) / 60
		var secs: int = int(_match_time) % 60
		_timer_label.text = "%d:%02d" % [mins, secs]


## --- Selection panel ---

func _update_selection_display() -> void:
	if not _selection_manager:
		_bottom_panel.visible = false
		return

	var building: Building = _selection_manager.get_selected_building()
	if building and not is_instance_valid(building):
		building = null
	var units: Array[Unit] = _selection_manager.get_selected_units()
	var crawler: SalvageCrawler = _selection_manager.get_selected_crawler()
	if crawler and not is_instance_valid(crawler):
		crawler = null

	if building and building.stats:
		_bottom_panel.visible = true
		_update_building_panel(building)
	elif not units.is_empty():
		# Mixed selection (units + crawler): the unit panel is more useful
		# because it surfaces builder / production hotkeys. The crawler is
		# still selected — right-click move still routes to it — but the
		# panel reflects the larger group.
		_bottom_panel.visible = true
		_update_unit_panel(units)
	elif crawler:
		_bottom_panel.visible = true
		_update_crawler_panel(crawler)
	else:
		_bottom_panel.visible = false
		_last_building_id = -1
		_last_unit_ids.clear()
		_showing_build_buttons = false
		if _progress_bar:
			_progress_bar.visible = false


func _update_crawler_panel(crawler: SalvageCrawler) -> void:
	## Crawler bottom-panel readout — name, HP, worker count, harvest range,
	## state (anchored / deploying / mobile), HP bar, and an Anchor toggle
	## button when the upgrade is researched.

	# Rebuild buttons only when the action changes — keep state stable when
	# selection is unchanged.
	var current_action: String = _crawler_action_key(crawler)
	var prev_action: String = str(get_meta("_crawler_action", ""))
	if current_action != prev_action:
		set_meta("_crawler_action", current_action)
		_clear_buttons()
		_action_label.text = ""
		_queue_label.text = ""
		_last_unit_ids.clear()
		_last_building_id = -1
		_showing_build_buttons = false
		if crawler.can_toggle_anchor():
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(150, 44)
			match crawler.anchor_state:
				SalvageCrawler.AnchorState.OFF:
					btn.text = "Anchor"
					btn.tooltip_text = "Deploy stationary mode (5s vulnerable):\n+50% armor, +25% workers, +25% range. Cannot move."
				SalvageCrawler.AnchorState.DEPLOYING:
					btn.text = "Deploying...\n%d%%" % int(crawler.get("_anchor_progress") * 100.0 / SalvageCrawler.ANCHOR_DEPLOY_TIME)
					btn.disabled = true
				SalvageCrawler.AnchorState.ANCHORED:
					btn.text = "Undeploy"
					btn.tooltip_text = "Retract Anchor Mode (5s vulnerable)."
				SalvageCrawler.AnchorState.UNDEPLOYING:
					btn.text = "Undeploying...\n%d%%" % int(crawler.get("_anchor_progress") * 100.0 / SalvageCrawler.ANCHOR_DEPLOY_TIME)
					btn.disabled = true
			btn.pressed.connect(crawler.toggle_anchor)
			_button_grid.add_child(btn)
			_action_label.text = "Anchor"

	var max_hp: int = crawler.stats.hp_total if crawler.stats else 800
	_name_label.text = "Salvage Crawler"
	var yard: Node = crawler.get_node_or_null("SalvageYardComponent")
	var worker_count: int = 0
	var max_workers: int = 0
	var harvest_radius: float = SalvageCrawler.HARVEST_RADIUS
	if yard:
		if yard.has_method("get_worker_count"):
			worker_count = yard.get_worker_count()
		if yard.has_method("get_max_workers"):
			max_workers = yard.get_max_workers()
		if yard.has_method("get_collection_radius"):
			harvest_radius = yard.get_collection_radius()
	var state_label: String = "Mobile"
	match crawler.anchor_state:
		SalvageCrawler.AnchorState.DEPLOYING: state_label = "Deploying"
		SalvageCrawler.AnchorState.ANCHORED: state_label = "Anchored (+50% armor)"
		SalvageCrawler.AnchorState.UNDEPLOYING: state_label = "Undeploying"
	_stats_label.text = "%s   HP %d / %d   Workers %d / %d   Harvest %dm" % [
		state_label,
		crawler.current_hp,
		max_hp,
		worker_count,
		max_workers,
		int(harvest_radius),
	]

	var hp_pct: float = float(crawler.current_hp) / float(maxi(max_hp, 1))
	var hp_color: Color = Color(0.4, 0.95, 0.4, 0.95)
	if hp_pct < 0.5: hp_color = Color(0.95, 0.78, 0.32, 0.95)
	if hp_pct < 0.25: hp_color = Color(1.0, 0.4, 0.35, 0.95)
	_show_progress(hp_pct, hp_color)


func _crawler_action_key(crawler: SalvageCrawler) -> String:
	# A small key that captures whether the visible Anchor button needs to
	# rebuild — based on can-toggle status + current state.
	var can: bool = crawler.can_toggle_anchor()
	return "%d|%d" % [int(can), crawler.anchor_state]


func _update_building_panel(building: Building) -> void:
	var bid: int = building.get_instance_id()

	# Only rebuild buttons when selection changes — except for the armory
	# while a research project is in flight, where we rebuild every frame
	# so the percentage label stays live.
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	var armory_in_progress: bool = (
		building.stats.building_id == &"basic_armory"
		and rm
		and rm.is_in_progress()
	)
	if bid != _last_building_id or armory_in_progress:
		_last_building_id = bid
		_last_unit_ids.clear()
		_showing_build_buttons = false
		if building.stats.building_id == &"basic_armory":
			_rebuild_armory_buttons(building)
		elif building.has_node("TurretComponent"):
			_rebuild_turret_profile_buttons(building)
		else:
			_rebuild_production_buttons(building)
	elif building.has_node("TurretComponent"):
		# Re-tint each frame so the active profile stays highlighted even
		# without a selection-change rebuild.
		_refresh_turret_profile_highlight(building)

	# Under construction → show construction progress bar.
	if not building.is_constructed:
		_name_label.text = building.stats.building_name
		_stats_label.text = "Under Construction"
		_queue_label.text = ""
		_show_progress(building.get_construction_percent(), Color(0.95, 0.78, 0.32, 0.95))
		return

	_name_label.text = building.stats.building_name

	var stats_text: String = "HP %d / %d" % [building.current_hp, building.stats.hp]
	if building.stats.power_production > 0:
		stats_text += "    Power +%d" % building.stats.power_production
	elif building.stats.power_consumption > 0:
		stats_text += "    Power -%d" % building.stats.power_consumption
	# Gun emplacements show their DPS so the player can compare to mech weapons.
	var turret: Node = building.get_node_or_null("TurretComponent")
	if turret:
		var dps: float = float(TurretComponent.TURRET_DAMAGE) / TurretComponent.FIRE_INTERVAL
		stats_text += "    DPS %.0f" % dps
	_stats_label.text = stats_text

	# Salvage yard: show worker info + spawn progress
	var yard: Node = building.get_node_or_null("SalvageYardComponent")
	if yard and yard.has_method("get_worker_count"):
		var count: int = yard.get_worker_count()
		var max_w: int = yard.get_max_workers()
		_queue_label.text = "Workers  %d / %d" % [count, max_w]
		if count < max_w:
			_show_progress(yard.get_spawn_progress(), Color(0.55, 0.95, 0.55, 0.95))
		else:
			_hide_progress()
	elif building.stats.building_id == &"basic_armory":
		var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
		if bcm and bcm.has_method("is_committing") and bcm.is_committing():
			var bname: String = bcm.get_commit_branch_name()
			_queue_label.text = "Committing %s" % bname
			_show_progress(bcm.get_commit_progress(), Color(0.95, 0.78, 0.32, 0.95))
		else:
			_queue_label.text = ""
			_hide_progress()
	elif building.get_queue_size() > 0:
		_queue_label.text = ""
		_show_progress(building.get_build_progress_percent(), Color(0.4, 0.85, 1.0, 0.95))
	else:
		_queue_label.text = ""
		_hide_progress()

	# Queue icons — one button per pending unit, click to cancel and
	# refund. Yards / armories don't have a build queue in the usual
	# sense, so they fall through with an empty row (no icons rendered).
	_refresh_queue_icons(building)


func _show_progress(pct: float, fill_color: Color) -> void:
	if not _progress_bar:
		return
	_progress_bar.visible = true
	_progress_bar.value = clampf(pct, 0.0, 1.0) * 100.0
	# Override fill color per call so the bar matches the task (build vs commit vs spawn).
	var fill_sb: StyleBoxFlat = _progress_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill_sb:
		var local_fill: StyleBoxFlat = fill_sb.duplicate() as StyleBoxFlat
		local_fill.bg_color = fill_color
		_progress_bar.add_theme_stylebox_override("fill", local_fill)


func _hide_progress() -> void:
	if _progress_bar:
		_progress_bar.visible = false


## --- Global queue panel ---
##
## Compact line anchored top-left under the resource counters. Aggregates
## production queues across every friendly production building plus the
## current research / branch-commit project so the player sees total
## throughput at a glance without selecting each building individually.

var _global_queue_label: Label = null


func _build_global_queue_panel() -> void:
	_global_queue_label = Label.new()
	_global_queue_label.name = "GlobalQueueLabel"
	_global_queue_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	# Sits ~140px below the screen top so it tucks under the resource row
	# without colliding with the match timer in the same area.
	_global_queue_label.position = Vector2(16.0, 132.0)
	_global_queue_label.custom_minimum_size = Vector2(360.0, 0.0)
	_global_queue_label.add_theme_font_size_override("font_size", 14)
	_global_queue_label.add_theme_color_override("font_color", COLOR_QUEUE)
	_global_queue_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	_global_queue_label.add_theme_constant_override("outline_size", 4)
	_global_queue_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_global_queue_label)


func _refresh_global_queue() -> void:
	if not _global_queue_label:
		return
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry")
	var local_id: int = (registry.get("local_player_id") as int) if registry else 0

	# Sum production queue across friendly buildings.
	var total_queued: int = 0
	var producing_buildings: int = 0
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.is_constructed:
			continue
		if b.owner_id != local_id:
			continue
		if not b.has_method("get_queue_size"):
			continue
		var qs: int = b.get_queue_size()
		if qs > 0:
			total_queued += qs
			producing_buildings += 1

	# Research line — `ResearchManager` for upgrades, `BranchCommitManager`
	# for branch commits. Either can be active independently.
	var research_text: String = ""
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	if rm and rm.has_method("is_in_progress") and rm.is_in_progress():
		var rname: String = (rm.get("current_label") as String) if "current_label" in rm else "Research"
		if rname == "":
			rname = "Research"
		var pct: float = rm.get_progress() if rm.has_method("get_progress") else 0.0
		research_text = "%s %d%%" % [rname, int(pct * 100.0)]
	if research_text == "":
		var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
		if bcm and bcm.has_method("is_committing") and bcm.is_committing():
			var bname: String = bcm.get_commit_branch_name() if bcm.has_method("get_commit_branch_name") else "Commit"
			var pct: float = bcm.get_commit_progress() if bcm.has_method("get_commit_progress") else 0.0
			research_text = "%s %d%%" % [bname, int(pct * 100.0)]

	var lines: Array[String] = []
	if total_queued > 0:
		lines.append("Producing: %d unit(s) across %d building(s)" % [total_queued, producing_buildings])
	if research_text != "":
		lines.append("Research: %s" % research_text)
	_global_queue_label.text = "\n".join(lines)
	_global_queue_label.visible = not lines.is_empty()


## --- Per-building queue icons ---
##
## Visualizes the building's `_build_queue` as a row of clickable
## buttons. Each entry shows the unit's first letter (cheap stand-in
## for an icon) and its position in the queue. Clicking a button
## cancels that slot and refunds the resources via
## `Building.cancel_queue_at`. The row is built lazily and lives
## inside the InfoSection so it sits next to the building name / HP.

var _queue_icons_row: HBoxContainer = null
const _QUEUE_ICON_SLOT_SIZE: Vector2 = Vector2(32.0, 32.0)


func _ensure_queue_icons_row() -> void:
	if _queue_icons_row and is_instance_valid(_queue_icons_row):
		return
	_queue_icons_row = HBoxContainer.new()
	_queue_icons_row.name = "QueueIconsRow"
	_queue_icons_row.add_theme_constant_override("separation", 4)
	_info_section.add_child(_queue_icons_row)


func _refresh_queue_icons(building: Building) -> void:
	_ensure_queue_icons_row()
	# Clear existing icons each refresh — cheap (max ~8 per building) and
	# avoids stale state when the queue's been reordered elsewhere.
	for child: Node in _queue_icons_row.get_children():
		child.queue_free()

	if not building or not building.is_constructed:
		_queue_icons_row.visible = false
		return
	var queue: Array = []
	if building.has_method("get_queue_snapshot"):
		queue = building.get_queue_snapshot()
	if queue.is_empty():
		_queue_icons_row.visible = false
		return
	_queue_icons_row.visible = true

	for i: int in queue.size():
		var unit_stat: UnitStatResource = queue[i] as UnitStatResource
		if not unit_stat:
			continue
		var btn := Button.new()
		btn.custom_minimum_size = _QUEUE_ICON_SLOT_SIZE
		# First-letter stand-in icon — readable enough for placeholder UI.
		var label: String = "?"
		if unit_stat.unit_name.length() > 0:
			label = unit_stat.unit_name.substr(0, 1)
		# In-progress slot gets a "·" prefix so the player can see which
		# one is mid-build vs queued.
		if i == 0:
			label = "•%s" % label
		btn.text = label
		var cost_text: String = "%dS" % unit_stat.cost_salvage
		if unit_stat.cost_fuel > 0:
			cost_text += " %dF" % unit_stat.cost_fuel
		btn.tooltip_text = "%s (%s)\nClick to cancel and refund." % [
			unit_stat.unit_name, cost_text,
		]
		var captured_index: int = i
		var captured_building: Building = building
		btn.pressed.connect(func() -> void: _on_queue_icon_pressed(captured_building, captured_index))
		_queue_icons_row.add_child(btn)


func _on_queue_icon_pressed(building: Building, index: int) -> void:
	if not is_instance_valid(building):
		return
	if not building.has_method("cancel_queue_at"):
		return
	var ok: bool = building.cancel_queue_at(index) as bool
	if ok and _selection_manager and _selection_manager._audio:
		_selection_manager._audio.play_command()
	# Force a panel rebuild so the row redraws without waiting for the
	# next building-id change.
	_last_building_id = -1


## --- Production / Build buttons ---

func _rebuild_production_buttons(building: Building) -> void:
	_clear_buttons()

	if building.stats.producible_units.is_empty():
		_action_label.text = "No production"
		return

	_action_label.text = "Train Units"
	var hotkeys: Array[String] = ["Q", "W", "E", "R", "T"]

	for i: int in building.stats.producible_units.size():
		var unit_stat: UnitStatResource = building.stats.producible_units[i]
		var hotkey: String = hotkeys[i] if i < hotkeys.size() else str(i + 1)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(86, 42)
		var cost_text: String = "%dS" % unit_stat.cost_salvage
		if unit_stat.cost_fuel > 0:
			cost_text += "  %dF" % unit_stat.cost_fuel
		btn.text = "[%s] %s\n%s" % [hotkey, unit_stat.unit_name, cost_text]
		btn.tooltip_text = _unit_tooltip(unit_stat)
		btn.pressed.connect(_on_production_button.bind(i))
		_button_grid.add_child(btn)
		_action_buttons.append({ "button": btn, "kind": "produce", "stat": unit_stat })


func _on_production_button(index: int) -> void:
	if _selection_manager:
		_selection_manager.queue_unit_at_building(index)


func _rebuild_turret_profile_buttons(building: Building) -> void:
	## Four upgrade buttons for a selected gun emplacement — each calls into
	## TurretComponent.set_profile to swap weapon stats and visuals.
	_clear_buttons()
	var turret: Node = building.get_node_or_null("TurretComponent")
	if not turret:
		_action_label.text = ""
		return

	_action_label.text = "Turret Profile"
	var profiles: Array[Dictionary] = [
		{ "key": &"balanced",   "hotkey": "Q" },
		{ "key": &"anti_light", "hotkey": "W" },
		{ "key": &"anti_heavy", "hotkey": "E" },
		{ "key": &"anti_air",   "hotkey": "R" },
	]
	for entry: Dictionary in profiles:
		var key: StringName = entry["key"] as StringName
		var data: Dictionary = TurretComponent.PROFILES[key] as Dictionary
		var dps: float = float(data["damage"]) / float(data["fire"])
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(120, 50)
		btn.text = "[%s] %s\nDPS %.0f  Rng %d" % [
			entry["hotkey"],
			data["name"],
			dps,
			int(data["range"]),
		]
		btn.tooltip_text = _turret_profile_tooltip(key, data)
		btn.pressed.connect(_on_turret_profile_button.bind(turret, key))
		_button_grid.add_child(btn)
		_action_buttons.append({ "button": btn, "kind": "turret_profile", "key": key })

	_refresh_turret_profile_highlight(building)


func _refresh_turret_profile_highlight(building: Building) -> void:
	var turret: Node = building.get_node_or_null("TurretComponent")
	if not turret:
		return
	var current: StringName = turret.get("profile") as StringName
	for entry: Dictionary in _action_buttons:
		if (entry.get("kind") as String) != "turret_profile":
			continue
		var btn: Button = entry["button"] as Button
		if not is_instance_valid(btn):
			continue
		if (entry["key"] as StringName) == current:
			btn.modulate = Color(0.55, 1.0, 0.55, 1.0)
		else:
			btn.modulate = Color.WHITE


func _on_turret_profile_button(turret: Node, key: StringName) -> void:
	if turret and is_instance_valid(turret) and turret.has_method("set_profile"):
		turret.set_profile(key)


func _turret_profile_tooltip(key: StringName, data: Dictionary) -> String:
	var role: StringName = data["role"] as StringName
	var lines: PackedStringArray = PackedStringArray()
	lines.append("%s turret" % data["name"])
	lines.append("Damage %d   ROF %.2fs   Range %d   Role %s" % [
		data["damage"], data["fire"], int(data["range"]), str(role)
	])
	match key:
		&"anti_light":
			lines.append("Quad-barrel rotary. High RoF eats light/medium chassis but bounces off heavy armor.")
		&"anti_heavy":
			lines.append("Slow howitzer. One shot can crater a Bulwark; ineffective vs swarms.")
		&"anti_air":
			lines.append("Tilted missile rack. Fast fire, AA-tagged ordnance — best vs flyers and lights.")
		_:
			lines.append("Generalist autocannon. Decent vs everything, specialised vs nothing.")
	return "\n".join(lines)


func _rebuild_armory_buttons(_building: Building) -> void:
	_clear_buttons()

	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if not bcm:
		_action_label.text = "No commit manager"
		return

	var hound_stats: UnitStatResource = load("res://resources/units/anvil_hound.tres") as UnitStatResource
	if not hound_stats or not hound_stats.branch_a_stats:
		_action_label.text = "No branches available"
		return

	if bcm.has_committed(hound_stats.unit_name):
		var committed: UnitStatResource = bcm.get_committed_stats(hound_stats.unit_name)
		_action_label.text = "Committed: %s" % committed.unit_name
		return

	if bcm.is_committing():
		_action_label.text = "Commit in progress..."
		return

	_action_label.text = "Hound Branch (irreversible)"

	var btn_a := Button.new()
	btn_a.custom_minimum_size = Vector2(120, 44)
	btn_a.text = "[Q] %s\nRecon / Smoke" % hound_stats.branch_a_name
	btn_a.tooltip_text = _unit_tooltip(hound_stats.branch_a_stats)
	btn_a.pressed.connect(_on_branch_commit.bind(hound_stats, hound_stats.branch_a_stats, hound_stats.branch_a_name))
	_button_grid.add_child(btn_a)

	var btn_b := Button.new()
	btn_b.custom_minimum_size = Vector2(120, 44)
	btn_b.text = "[W] %s\nBrawler / HP++" % hound_stats.branch_b_name
	btn_b.tooltip_text = _unit_tooltip(hound_stats.branch_b_stats)
	btn_b.pressed.connect(_on_branch_commit.bind(hound_stats, hound_stats.branch_b_stats, hound_stats.branch_b_name))
	_button_grid.add_child(btn_b)

	# Anchor Mode research button (v3.3 §3.1) — researched here, applies to
	# every present and future Crawler.
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	if rm:
		var anchor_btn := Button.new()
		anchor_btn.custom_minimum_size = Vector2(160, 44)
		if rm.is_researched(&"anchor_mode"):
			anchor_btn.text = "Anchor Mode\nResearched"
			anchor_btn.disabled = true
		elif rm.is_in_progress() and rm.current_id == &"anchor_mode":
			anchor_btn.text = "Anchor Mode\n%d%%" % int(rm.get_progress() * 100.0)
			anchor_btn.disabled = true
		else:
			anchor_btn.text = "[E] Anchor Mode\n300S / 35F  50s"
			anchor_btn.tooltip_text = (
				"Crawlers gain a stationary Anchor command.\n"
				+ "Anchored: +50% armor, +25% workers, +25% range.\n"
				+ "5s deploy / 5s undeploy (vulnerable during)."
			)
			anchor_btn.pressed.connect(_on_research_anchor)
		_button_grid.add_child(anchor_btn)


func _on_research_anchor() -> void:
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	if not rm or rm.is_researched(&"anchor_mode") or rm.is_in_progress():
		return
	if not _resource_manager:
		return
	if not _resource_manager.can_afford(300, 35):
		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_error"):
			audio.play_error()
		return
	_resource_manager.spend(300, 35)
	rm.start_research(&"anchor_mode", "Anchor Mode", 50.0)
	# Force a panel rebuild so the button immediately reflects "in progress".
	_last_building_id = -1


func _on_branch_commit(base_stats: UnitStatResource, branch_stats: UnitStatResource, branch_name: String) -> void:
	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if bcm and bcm.has_method("start_commit"):
		bcm.start_commit(base_stats, branch_stats, branch_name)
		_last_building_id = -1


## --- Resource gifting (2v2 allies) ---
##
## A compact panel anchored to the right-center of the screen that lists
## each allied player's current resources and offers quick-send buttons.
## Hidden in 1v1 (no allies) so it doesn't take up space; populated and
## shown automatically when at least one ally is registered.

var _gift_panel: PanelContainer = null
var _gift_vbox: VBoxContainer = null
## Per-ally row state: ally_id -> { label: Label, salvage_buttons: Array, fuel_buttons: Array }
var _gift_rows: Dictionary = {}


const GIFT_AMOUNTS_SALVAGE: Array[int] = [50, 100, 250]
const GIFT_AMOUNTS_FUEL: Array[int] = [10, 25, 50]


func _build_gifting_panel() -> void:
	_gift_panel = PanelContainer.new()
	_gift_panel.name = "GiftPanel"
	_gift_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_gift_panel.position = Vector2(-260.0, -120.0)
	_gift_panel.custom_minimum_size = Vector2(240.0, 0.0)
	_gift_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_gift_panel.visible = false
	add_child(_gift_panel)

	_gift_vbox = VBoxContainer.new()
	_gift_vbox.add_theme_constant_override("separation", 6)
	_gift_panel.add_child(_gift_vbox)

	var title := Label.new()
	title.text = "Gift Allies"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", COLOR_NAME)
	_gift_vbox.add_child(title)


func _refresh_gift_panel() -> void:
	if not _gift_panel:
		return
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry")
	if not registry:
		_gift_panel.visible = false
		return

	var local_id: int = registry.get("local_player_id") as int
	var all_ids: Array = registry.get_all_player_ids() if registry.has_method("get_all_player_ids") else []
	var ally_ids: Array[int] = []
	for id_var: Variant in all_ids:
		var pid: int = id_var as int
		if pid == local_id:
			continue
		if registry.are_allied(local_id, pid):
			ally_ids.append(pid)

	if ally_ids.is_empty():
		_gift_panel.visible = false
		return
	_gift_panel.visible = true

	# Drop rows for allies who got eliminated since the last refresh.
	for existing_id: Variant in _gift_rows.keys():
		if (existing_id as int) not in ally_ids:
			var row_dict: Dictionary = _gift_rows[existing_id]
			var row: Node = row_dict.get("root", null) as Node
			if row and is_instance_valid(row):
				row.queue_free()
			_gift_rows.erase(existing_id)

	# Add rows for newly-registered allies.
	for ally_id: int in ally_ids:
		if not _gift_rows.has(ally_id):
			_build_gift_row(ally_id, registry)
		_update_gift_row(ally_id, registry, local_id)


func _build_gift_row(ally_id: int, registry: Node) -> void:
	var state: Resource = registry.get_state(ally_id) as Resource
	var name: String = "Ally"
	if state and "display_name" in state:
		name = state.get("display_name") as String

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	var header := Label.new()
	header.text = name
	header.add_theme_font_size_override("font_size", 14)
	if state and "player_color" in state:
		header.add_theme_color_override("font_color", state.get("player_color") as Color)
	row.add_child(header)

	var resources_label := Label.new()
	resources_label.add_theme_font_size_override("font_size", 12)
	resources_label.add_theme_color_override("font_color", COLOR_STATS)
	row.add_child(resources_label)

	var salvage_row := HBoxContainer.new()
	row.add_child(salvage_row)
	for amt: int in GIFT_AMOUNTS_SALVAGE:
		var btn := Button.new()
		btn.text = "+%dS" % amt
		btn.custom_minimum_size = Vector2(60, 26)
		btn.tooltip_text = "Send %d salvage to %s" % [amt, name]
		var captured_amt: int = amt
		var captured_id: int = ally_id
		btn.pressed.connect(func() -> void: _send_gift(captured_id, captured_amt, 0))
		salvage_row.add_child(btn)

	var fuel_row := HBoxContainer.new()
	row.add_child(fuel_row)
	for amt: int in GIFT_AMOUNTS_FUEL:
		var btn := Button.new()
		btn.text = "+%dF" % amt
		btn.custom_minimum_size = Vector2(60, 26)
		btn.tooltip_text = "Send %d fuel to %s" % [amt, name]
		var captured_amt: int = amt
		var captured_id: int = ally_id
		btn.pressed.connect(func() -> void: _send_gift(captured_id, 0, captured_amt))
		fuel_row.add_child(btn)

	_gift_vbox.add_child(row)
	_gift_rows[ally_id] = {
		"root": row,
		"resources_label": resources_label,
	}


func _update_gift_row(ally_id: int, registry: Node, local_id: int) -> void:
	var row_dict: Dictionary = _gift_rows.get(ally_id, {}) as Dictionary
	var label: Label = row_dict.get("resources_label", null) as Label
	if not label:
		return
	var rm: Node = registry.get_resource_manager(ally_id)
	var ally_salvage: int = (rm.get("salvage") as int) if rm else 0
	var ally_fuel: int = (rm.get("fuel") as int) if rm else 0
	var local_rm: Node = registry.get_resource_manager(local_id)
	var local_salvage: int = (local_rm.get("salvage") as int) if local_rm else 0
	var local_fuel: int = (local_rm.get("fuel") as int) if local_rm else 0
	label.text = "Ally: %dS  %dF\nYou: %dS  %dF" % [ally_salvage, ally_fuel, local_salvage, local_fuel]


func _send_gift(to_id: int, salvage: int, fuel: int) -> void:
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry")
	if not registry or not registry.has_method("transfer_resources"):
		return
	var local_id: int = registry.get("local_player_id") as int
	var ok: bool = registry.transfer_resources(local_id, to_id, salvage, fuel) as bool
	var alert_mgr: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if not alert_mgr:
		return
	if ok:
		var msg: String = "Sent gift to ally"
		if salvage > 0 and fuel > 0:
			msg = "Sent %dS / %dF" % [salvage, fuel]
		elif salvage > 0:
			msg = "Sent %d salvage" % salvage
		elif fuel > 0:
			msg = "Sent %d fuel" % fuel
		alert_mgr.emit_alert(msg, 0, Vector3.ZERO, "gift", 0.5)
	else:
		alert_mgr.emit_alert("Gift failed — not enough resources", 1, Vector3.ZERO, "gift_fail", 0.5)


## --- Alert banner ---
##
## A single line of text that appears centered near the top of the screen,
## with a tint based on severity, fading out after a fixed duration. Each
## new alert replaces the previous one — players read the latest event;
## the older one is gone from the HUD but the audio cue still played.

var _alert_label: Label = null
var _alert_tween: Tween = null


func _build_alert_banner() -> void:
	_alert_label = Label.new()
	_alert_label.name = "AlertBanner"
	_alert_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_alert_label.offset_top = 60.0
	_alert_label.offset_bottom = 96.0
	_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_alert_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_alert_label.add_theme_font_size_override("font_size", 22)
	_alert_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	_alert_label.add_theme_constant_override("outline_size", 6)
	_alert_label.modulate.a = 0.0
	_alert_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_alert_label)

	# Children _ready before parents in Godot, so AlertManager (created in
	# TestArenaController._ready) doesn't exist yet — connect on the next
	# frame once all _ready calls have settled.
	call_deferred("_connect_alert_manager")


func _connect_alert_manager() -> void:
	var alert_mgr: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if alert_mgr and alert_mgr.has_signal("alert_emitted"):
		alert_mgr.connect("alert_emitted", _on_alert)


func _on_alert(message: String, severity: int, _world_pos: Vector3) -> void:
	if not _alert_label:
		return
	var tint: Color = COLOR_NAME
	match severity:
		1:
			tint = Color(1.0, 0.78, 0.32, 1.0)  # warning amber
		2:
			tint = Color(1.0, 0.4, 0.35, 1.0)   # critical red
		_:
			tint = Color(0.85, 0.95, 0.85, 1.0) # info pale green
	_alert_label.text = message
	_alert_label.add_theme_color_override("font_color", tint)
	_alert_label.modulate.a = 1.0
	if _alert_tween and _alert_tween.is_valid():
		_alert_tween.kill()
	_alert_tween = create_tween()
	_alert_tween.tween_interval(3.5)
	_alert_tween.tween_property(_alert_label, "modulate:a", 0.0, 1.5)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_alert"):
		audio.play_alert(severity)


## --- Unit panel ---

func _update_unit_panel(units: Array[Unit]) -> void:
	# Filter out freed units
	var valid_units: Array[Unit] = []
	for unit: Unit in units:
		if is_instance_valid(unit) and unit.alive_count > 0:
			valid_units.append(unit)
	units = valid_units

	if units.is_empty():
		_bottom_panel.visible = false
		_hide_progress()
		return

	# Check if selection actually changed
	var current_ids: Array[int] = []
	for unit: Unit in units:
		current_ids.append(unit.get_instance_id())

	var selection_changed: bool = current_ids.size() != _last_unit_ids.size()
	if not selection_changed:
		for i: int in current_ids.size():
			if current_ids[i] != _last_unit_ids[i]:
				selection_changed = true
				break

	if selection_changed:
		_last_unit_ids = current_ids
		_last_building_id = -1
		_showing_build_buttons = false

		var has_builder: bool = false
		for unit: Unit in units:
			if unit.get_builder():
				has_builder = true
				break

		if has_builder and not _showing_build_buttons:
			_showing_build_buttons = true
			_rebuild_build_buttons()
		elif not has_builder:
			_showing_build_buttons = false
			_clear_buttons()
			_action_label.text = ""

	# Update text every frame
	_queue_label.text = ""
	_hide_progress()

	if units.size() == 1:
		var unit: Unit = units[0]
		if unit.stats:
			_name_label.text = unit.stats.unit_name
			var hp_pct: float = float(unit.get_total_hp()) / float(maxi(unit.stats.hp_total, 1))
			var dps: float = _compute_full_squad_dps(unit.stats)
			_stats_label.text = "%s   HP %d / %d   Squad %d / %d   Armor %s   DPS %.0f" % [
				str(unit.stats.unit_class).capitalize(),
				unit.get_total_hp(),
				unit.stats.hp_total,
				unit.alive_count,
				unit.stats.squad_size,
				str(unit.stats.armor_class).capitalize(),
				dps,
			]
			# Use HP bar to mirror the on-world HP — quick eyeball read in the panel.
			var hp_color: Color = Color(0.4, 0.95, 0.4, 0.95)
			if hp_pct < 0.5: hp_color = Color(0.95, 0.78, 0.32, 0.95)
			if hp_pct < 0.25: hp_color = Color(1.0, 0.4, 0.35, 0.95)
			_show_progress(hp_pct, hp_color)
			if unit.get_builder():
				_action_label.text = "Build  [1-6]"
		else:
			_name_label.text = "Unit"
			_stats_label.text = ""
	else:
		var counts: Dictionary = {}
		for unit: Unit in units:
			var uname: String = unit.stats.unit_name if unit.stats else "Unknown"
			if counts.has(uname):
				counts[uname] += 1
			else:
				counts[uname] = 1

		var parts: PackedStringArray = PackedStringArray()
		for uname: String in counts:
			parts.append("%dx %s" % [counts[uname], uname])
		_name_label.text = "%d units selected" % units.size()
		_stats_label.text = ", ".join(parts)


func _rebuild_build_buttons() -> void:
	_clear_buttons()
	if not _selection_manager:
		return

	_action_label.text = "Build"
	var buildable: Array[BuildingStatResource] = _selection_manager.get_buildable_stats()
	for i: int in buildable.size():
		var bstat: BuildingStatResource = buildable[i]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(86, 42)
		btn.text = "[%d] %s\n%dS" % [i + 1, bstat.building_name, bstat.cost_salvage]
		btn.tooltip_text = _building_tooltip(bstat)
		btn.pressed.connect(_on_build_button.bind(i))
		_button_grid.add_child(btn)
		_action_buttons.append({ "button": btn, "kind": "build", "stat": bstat })


func _on_build_button(index: int) -> void:
	if not _selection_manager:
		return
	var buildable: Array[BuildingStatResource] = _selection_manager.get_buildable_stats()
	if index < buildable.size():
		_selection_manager.start_build_placement(buildable[index])


func _clear_buttons() -> void:
	for child: Node in _button_grid.get_children():
		child.queue_free()
	_action_buttons.clear()


## --- Affordability tint ---

func _update_button_affordability() -> void:
	if not _resource_manager or _action_buttons.is_empty():
		return
	for entry: Dictionary in _action_buttons:
		var btn: Button = entry["button"] as Button
		if not is_instance_valid(btn):
			continue
		var kind: String = entry["kind"] as String
		var affordable: bool = true
		if kind == "produce":
			var stat: UnitStatResource = entry["stat"] as UnitStatResource
			affordable = (
				_resource_manager.can_afford(stat.cost_salvage, stat.cost_fuel)
				and _resource_manager.has_population(stat.population)
			)
		elif kind == "build":
			var bstat: BuildingStatResource = entry["stat"] as BuildingStatResource
			affordable = _resource_manager.can_afford_salvage(bstat.cost_salvage)
		btn.disabled = not affordable
		# Default theme already paints a red border on disabled buttons; we additionally
		# dim the font so the player's eye is drawn to the affordable options.
		btn.modulate = Color.WHITE if affordable else COLOR_AFFORD_BAD


## --- Tooltips ---

func _compute_full_squad_dps(stat: UnitStatResource) -> float:
	## Theoretical DPS at full squad strength against an unarmored target,
	## ignoring directional/role mods. Counts both primary and secondary.
	if not stat:
		return 0.0
	var dps: float = 0.0
	if stat.primary_weapon:
		dps += _weapon_dps(stat.primary_weapon) * float(stat.squad_size)
	if stat.secondary_weapon:
		dps += _weapon_dps(stat.secondary_weapon) * float(stat.squad_size)
	return dps


func _weapon_dps(weapon: WeaponResource) -> float:
	if not weapon:
		return 0.0
	var dmg: float = float(CombatTables.get_damage(weapon.damage_tier))
	var rof: float = CombatTables.get_rof(weapon.rof_tier)
	if rof <= 0.0:
		return 0.0
	return dmg / rof


func _unit_tooltip(stat: UnitStatResource) -> String:
	if not stat:
		return ""
	var lines: PackedStringArray = PackedStringArray()
	lines.append(stat.unit_name)
	lines.append("Class: %s    Armor: %s" % [
		str(stat.unit_class).capitalize(),
		str(stat.armor_class).capitalize()
	])
	lines.append("HP %d   Squad %d   Pop %d" % [stat.hp_total, stat.squad_size, stat.population])
	lines.append("Cost  %dS / %dF   Build %.1fs   DPS %.0f" % [
		stat.cost_salvage, stat.cost_fuel, stat.build_time, _compute_full_squad_dps(stat)
	])
	if stat.primary_weapon:
		lines.append("Primary: %s (%s, %s)" % [
			str(stat.primary_weapon.role_tag),
			str(stat.primary_weapon.range_tier),
			str(stat.primary_weapon.damage_tier)
		])
	if stat.secondary_weapon:
		lines.append("Secondary: %s" % str(stat.secondary_weapon.role_tag))
	if stat.special_description != "":
		lines.append(stat.special_description)
	return "\n".join(lines)


func _building_tooltip(stat: BuildingStatResource) -> String:
	if not stat:
		return ""
	var lines: PackedStringArray = PackedStringArray()
	lines.append(stat.building_name)
	lines.append("HP %d   Cost %dS   Build %.1fs" % [stat.hp, stat.cost_salvage, stat.build_time])
	if stat.power_production > 0:
		lines.append("Power: +%d" % stat.power_production)
	elif stat.power_consumption > 0:
		lines.append("Power: -%d" % stat.power_consumption)
	if not stat.producible_units.is_empty():
		var unit_names: PackedStringArray = PackedStringArray()
		for u: UnitStatResource in stat.producible_units:
			if u:
				unit_names.append(u.unit_name)
		lines.append("Produces: %s" % ", ".join(unit_names))
	return "\n".join(lines)
