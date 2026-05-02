class_name HUD
extends Control
## Prototype HUD: resource counters, selection info, production buttons.

var _resource_manager: ResourceManager = null
var _selection_manager: SelectionManager = null

## Currently-selected tab on the build menu. Buildings are routed by
## `BuildingStatResource.is_advanced`; the Advanced tab additionally
## disables entries whose prerequisites the local player hasn't built.
var _build_tab: String = "basic"

## Hash of the last-rebuilt advanced-prereq state. When the player
## completes a new building, this changes and the build menu rebuilds
## itself so just-unlocked Advanced entries become enabled live.
var _build_prereq_hash: int = -1

## Persistent tab row for the build menu. Lives in ActionSection
## above ButtonGrid so the buttons in the grid don't shift around
## when basic/advanced is swapped (the tab row used to be a child
## of the grid, which tossed the buttons by one cell on every
## tab change).
var _build_tab_row: HBoxContainer = null
var _build_tab_basic: Button = null
var _build_tab_advanced: Button = null

## Track what we're showing to avoid rebuilding buttons every frame.
var _last_building_id: int = -1
var _last_unit_ids: Array[int] = []
var _showing_build_buttons: bool = false

## Pool of buttons + cached metadata so we can update affordability tint each frame.
## Each entry: { button: Button, kind: "produce"|"build", index: int }
var _action_buttons: Array[Dictionary] = []

## Optional progress bar shown inside the bottom panel for construction / queue / worker spawn.
var _progress_bar: ProgressBar = null

## Selection roster strip — vertical column of unit-class chips
## anchored to the LEFT edge of the bottom panel. Shown when more
## than one squad is selected; each chip is a coloured class swatch
## with count + average HP sliver. Click a chip to deselect that
## class from the current selection.
var _roster_strip: VBoxContainer = null
var _roster_last_signature: String = ""

## Hotkey palette overlay — translucent panel listing every active
## hotkey for the current selection. Shown while Tab is held down.
var _hotkey_palette: PanelContainer = null
var _hotkey_palette_label: RichTextLabel = null

## Full-screen overlay shown while the tree is paused.
var _pause_overlay: Control = null

@onready var _salvage_label: Label = $TopBar/SalvageLabel as Label
@onready var _fuel_label: Label = $TopBar/FuelLabel as Label
@onready var _microchips_label: Label = $TopBar/MicrochipsLabel as Label
@onready var _power_label: Label = $TopBar/PowerLabel as Label
@onready var _pop_label: Label = $TopBar/PopLabel as Label

## Power widget — built in _ready by `_build_power_widget`. Replaces the bare
## PowerLabel with a label + thin ProgressBar showing usage vs capacity.
var _power_bar: ProgressBar = null
var _power_bar_fill_style: StyleBoxFlat = null
@onready var _name_label: Label = $BottomPanel/HBox/InfoSection/NameLabel as Label
@onready var _stats_label: RichTextLabel = $BottomPanel/HBox/InfoSection/StatsLabel as RichTextLabel
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
const COLOR_MICROCHIPS := Color(0.85, 0.55, 1.0, 1.0) # violet — distinct from gold/cyan
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
	_build_fps_counter()
	_build_faction_watermark()
	_apply_top_bar_faction_theme()
	_build_selection_roster()
	_build_hotkey_palette()
	# Faster tooltip popups — Godot's default ~500ms is too slow for
	# in-battle decisions where the player needs to verify costs /
	# weapon roles in a couple of seconds. 0.18s feels responsive
	# without firing on every transient hover.
	_apply_tooltip_delay(0.18)

	# Tutorial overlay — shown only when the player launched via the Tutorial
	# button on the main menu. The mission-style banner reads its current
	# objective + dialogue from the TutorialMission node every frame; the
	# legacy task-checklist overlay stays available as a controls reference.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.get("tutorial_mode"):
		_build_tutorial_overlay()
		_build_tutorial_mission_banner()


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

## Mission-style banner (separate from the legacy task-checklist
## overlay). Shows the current TutorialMission stage's dialogue +
## objective at the top of the screen and updates whenever the
## mission advances.
var _tutorial_banner_panel: PanelContainer = null
var _tutorial_banner_dialogue: Label = null
var _tutorial_banner_objective: Label = null
var _tutorial_banner_progress: Label = null
var _tutorial_banner_last_index: int = -2  # never matches a real stage


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


func _build_tutorial_mission_banner() -> void:
	## Centred-top banner panel that shows the current
	## TutorialMission stage's dialogue + objective. Lives above
	## the existing topbar but stays out of the way of the
	## minimap. Updates every HUD tick via
	## _refresh_tutorial_mission_banner.
	_tutorial_banner_panel = PanelContainer.new()
	_tutorial_banner_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_tutorial_banner_panel.offset_left = 220
	_tutorial_banner_panel.offset_right = -260
	_tutorial_banner_panel.offset_top = 38
	_tutorial_banner_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_tutorial_banner_panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 2)
	_tutorial_banner_panel.add_child(inner)
	_tutorial_banner_progress = Label.new()
	_tutorial_banner_progress.text = ""
	_tutorial_banner_progress.add_theme_font_size_override("font_size", 12)
	_tutorial_banner_progress.add_theme_color_override("font_color", Color(0.78, 0.85, 0.95, 0.85))
	_tutorial_banner_progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(_tutorial_banner_progress)
	_tutorial_banner_dialogue = Label.new()
	_tutorial_banner_dialogue.text = ""
	_tutorial_banner_dialogue.add_theme_font_size_override("font_size", 16)
	_tutorial_banner_dialogue.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78, 1.0))
	_tutorial_banner_dialogue.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_banner_dialogue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(_tutorial_banner_dialogue)
	_tutorial_banner_objective = Label.new()
	_tutorial_banner_objective.text = ""
	_tutorial_banner_objective.add_theme_font_size_override("font_size", 14)
	_tutorial_banner_objective.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55, 1.0))
	_tutorial_banner_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_banner_objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(_tutorial_banner_objective)


func _refresh_tutorial_mission_banner() -> void:
	## Polls TutorialMission for its current stage and pushes the
	## text into the banner. Skips the work when the stage hasn't
	## changed so the labels don't churn each tick.
	if not _tutorial_banner_panel:
		return
	var mission_nodes: Array[Node] = get_tree().get_nodes_in_group("tutorial_mission")
	if mission_nodes.is_empty():
		_tutorial_banner_panel.visible = false
		return
	var mission: Node = mission_nodes[0]
	if not is_instance_valid(mission):
		return
	var idx: int = mission.call("current_stage_index") as int
	if idx == _tutorial_banner_last_index:
		return
	_tutorial_banner_last_index = idx
	_tutorial_banner_panel.visible = true
	var dialogue: String = mission.call("current_stage_dialogue") as String
	var objective: String = mission.call("current_stage_objective") as String
	var total: int = mission.call("total_stages") as int
	_tutorial_banner_dialogue.text = dialogue
	_tutorial_banner_objective.text = "Objective: %s" % objective
	_tutorial_banner_progress.text = "Stage %d / %d" % [idx + 1, total]


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

	var units: Array[Node3D] = _selection_manager.get_selected_units()

	# Each task is independent — once done, stays done.
	if not _tutorial_progress.get("select_unit", false) and units.size() >= 1:
		_mark_task_done("select_unit")

	if not _tutorial_progress.get("issue_move", false):
		for u: Node3D in units:
			if is_instance_valid(u) and u.has_move_order:
				_mark_task_done("issue_move")
				break

	if not _tutorial_progress.get("box_select", false) and units.size() >= 2:
		_mark_task_done("box_select")

	if not _tutorial_progress.get("attack_move", false):
		for u: Node3D in units:
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
		elif key.pressed and not key.echo and key.keycode == KEY_M:
			# V3 QoL — M toggles the bright Mesh-coverage overlay.
			# Each provider's ground ring is bumped to a brighter
			# emission level so the player can read the entire Sable
			# Mesh footprint at a glance.
			_toggle_mesh_overlay()
			get_viewport().set_input_as_handled()
		elif key.keycode == KEY_TAB:
			# TAB on first press: dismiss the tutorial overlay if it's
			# up. Otherwise, hold-Tab shows the hotkey palette overlay
			# listing every active shortcut for the current selection;
			# release hides it again.
			if key.pressed and not key.echo and has_meta("tutorial_overlay"):
				var overlay: Node = get_meta("tutorial_overlay")
				if is_instance_valid(overlay):
					overlay.queue_free()
				remove_meta("tutorial_overlay")
				get_viewport().set_input_as_handled()
			elif key.pressed and _hotkey_palette and not _hotkey_palette.visible:
				_refresh_hotkey_palette()
				_hotkey_palette.visible = true
				get_viewport().set_input_as_handled()
			elif not key.pressed and _hotkey_palette and _hotkey_palette.visible:
				_hotkey_palette.visible = false
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

	# Three bus sliders — SFX / Voices / Music — same controls the
	# main menu Settings page exposes, accessible mid-match without
	# leaving the game. Each slider binds directly to its bus's
	# volume_db so the change is live.
	for entry: Dictionary in [
		{"label": "SFX", "bus": "SFX"},
		{"label": "Voices", "bus": "Voiceline"},
		{"label": "Music", "bus": "Music"},
	]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.process_mode = Node.PROCESS_MODE_ALWAYS
		vbox.add_child(row)
		var label := Label.new()
		label.text = entry["label"] as String
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
		label.custom_minimum_size = Vector2(70, 22)
		row.add_child(label)
		var slider := HSlider.new()
		slider.custom_minimum_size = Vector2(280, 22)
		slider.min_value = -40.0
		slider.max_value = 6.0
		slider.step = 1.0
		var bus_idx: int = AudioServer.get_bus_index(entry["bus"] as String)
		if bus_idx >= 0:
			slider.value = AudioServer.get_bus_volume_db(bus_idx)
		else:
			slider.value = 0.0
		slider.value_changed.connect(_on_bus_volume_changed.bind(entry["bus"] as String))
		slider.process_mode = Node.PROCESS_MODE_ALWAYS
		row.add_child(slider)

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


func _on_bus_volume_changed(db: float, bus_name: String) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, db)


func _on_volume_changed(db: float) -> void:
	# 0 is the master bus — feed the dB value through directly. -40 dB ≈ silent,
	# 0 dB is the project default, +6 dB pushes a little hotter.
	AudioServer.set_bus_volume_db(0, db)


var _hud_throttle: float = 0.0
const HUD_REFRESH_INTERVAL: float = 0.066  # ~15 Hz; HUD readouts don't need 60Hz

func _process(delta: float) -> void:
	_match_time += delta
	# FPS counter and resource display run every frame so the readout
	# is responsive. The heavier panels (selection, buttons, tutorial,
	# gift, queue) refresh ~15Hz — they only need to redraw when the
	# underlying state changes, which is rare per frame anyway.
	_refresh_fps_counter(delta)
	_update_resource_display()
	_hud_throttle += delta
	if _hud_throttle < HUD_REFRESH_INTERVAL:
		return
	_hud_throttle = 0.0
	_update_selection_display()
	_update_button_affordability()
	_update_selection_roster()
	_check_tutorial_progress()
	_refresh_tutorial_mission_banner()
	_refresh_gift_panel()
	_refresh_global_queue()


## --- Theme ---

func _apply_theme() -> void:
	## Dark-steel theme applied at the HUD root so every child Label/Button/Panel
	## inherits a consistent industrial look without per-node overrides in the .tscn.
	var theme_res := Theme.new()

	# Default font sizing — slightly larger so labels pop on a busy battlefield.
	theme_res.set_default_font_size(14)

	# Faction-driven accent color used for panel borders and button
	# hover/press highlights. Anvil ships warm brass, Sable swaps to
	# violet so the HUD itself signals which faction the player picked
	# the moment the match opens.
	var faction_id: int = 0
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "player_faction" in settings:
		faction_id = settings.get("player_faction") as int
	var accent: Color = Color(1.0, 0.82, 0.35, 1.0) if faction_id == 0 else Color(0.78, 0.45, 1.0, 1.0)
	var accent_dim: Color = accent.darkened(0.4)

	# --- Panel ---
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = Color(0.08, 0.09, 0.10, 0.88)
	panel_sb.border_color = accent_dim
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
	# Faction button shape language: Anvil keeps right-angle corners
	# all around (industrial, square-cut). Sable chamfers the top-
	# right corner with a much larger radius — subtle but instantly
	# tells you which faction's interface you're staring at.
	var btn_normal := StyleBoxFlat.new()
	btn_normal.bg_color = Color(0.16, 0.18, 0.20, 1.0)
	btn_normal.border_color = Color(0.4, 0.42, 0.46, 1.0)
	btn_normal.set_border_width_all(1)
	if faction_id == 1:
		btn_normal.corner_radius_top_left = 2
		btn_normal.corner_radius_top_right = 12
		btn_normal.corner_radius_bottom_right = 2
		btn_normal.corner_radius_bottom_left = 2
	else:
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
	btn_hover.border_color = accent.lightened(0.15)

	var btn_pressed := btn_normal.duplicate() as StyleBoxFlat
	# Pressed state — visibly inset: darker fill, brighter accent
	# border, top edge nudged DOWN by adjusting content margins so the
	# button label "drops" 1px when clicked. The expand_margin_top shift
	# gives the panel an inset shadow so the button reads as physically
	# pushed into the panel rather than just a colour swap.
	btn_pressed.bg_color = Color(0.08, 0.10, 0.12, 1.0)
	btn_pressed.border_color = accent
	btn_pressed.set_border_width_all(2)
	btn_pressed.content_margin_top = 5
	btn_pressed.content_margin_bottom = 3
	btn_pressed.shadow_color = Color(0, 0, 0, 0.5)
	btn_pressed.shadow_size = 2
	btn_pressed.shadow_offset = Vector2(0, 1)

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
	if _microchips_label: _microchips_label.add_theme_color_override("font_color", COLOR_MICROCHIPS)
	if _power_label: _power_label.add_theme_color_override("font_color", COLOR_POWER)
	if _pop_label: _pop_label.add_theme_color_override("font_color", COLOR_POP)
	if _timer_label: _timer_label.add_theme_color_override("font_color", COLOR_TIMER)
	if _name_label: _name_label.add_theme_color_override("font_color", COLOR_NAME)
	if _stats_label: _stats_label.add_theme_color_override("default_color", COLOR_STATS)
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
	# Resource counters get a 30s rolling-average income suffix so the
	# player can read economy health at a glance without watching the
	# numbers tick.
	var avg_income: Vector2 = Vector2.ZERO
	if _resource_manager.has_method("get_average_income"):
		avg_income = _resource_manager.get_average_income()
	_salvage_label.text = "Salvage  %d  (+%.1f/s)" % [_resource_manager.salvage, avg_income.x]

	# Fuel — turn red when below 20% capacity (early-warning).
	var fuel_pct: float = float(_resource_manager.fuel) / float(maxi(_resource_manager.fuel_cap, 1))
	_fuel_label.text = "Fuel  %d / %d  (+%.1f/s)" % [_resource_manager.fuel, _resource_manager.fuel_cap, avg_income.y]
	_fuel_label.add_theme_color_override(
		"font_color",
		COLOR_WARN if fuel_pct < 0.2 else COLOR_FUEL
	)

	# Microchips — small-number resource. Format intentionally tight
	# ("Chips 2 / 30") so the readout fits in the topbar without
	# crowding the salvage / fuel counters.
	if _microchips_label:
		var chips_now: int = (_resource_manager.get("microchips") as int) if "microchips" in _resource_manager else 0
		var chips_cap: int = ResourceManager.MICROCHIPS_CAP
		_microchips_label.text = "Chips  %d / %d" % [chips_now, chips_cap]

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

	# Population — yellow when >= 90%, red when capped. Pop cap is now
	# dynamic (base + production buildings) so we read the live field
	# instead of the previous static constant.
	var pop_cap: int = maxi(_resource_manager.population_cap, 1)
	var pop_pct: float = float(_resource_manager.population) / float(pop_cap)
	_pop_label.text = "Pop  %d / %d" % [_resource_manager.population, pop_cap]
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
	var units: Array[Node3D] = _selection_manager.get_selected_units()
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
		# Nothing of ours selected — fall back to the read-only enemy
		# inspection panel if the player clicked an enemy / neutral.
		var inspected: Node3D = null
		if _selection_manager.has_method("get_inspected_enemy"):
			inspected = _selection_manager.get_inspected_enemy()
		if inspected:
			_bottom_panel.visible = true
			_update_enemy_inspect_panel(inspected)
		else:
			_bottom_panel.visible = false
			_last_building_id = -1
			_last_unit_ids.clear()
			_showing_build_buttons = false
			if _progress_bar:
				_progress_bar.visible = false


func _update_enemy_inspect_panel(target: Node3D) -> void:
	## Read-only panel for an enemy / neutral unit, Crawler, or
	## building. No buttons, no progress bar interaction — just
	## identification + HP + a one-line stats summary.
	_clear_buttons()
	_action_label.text = ""
	_queue_label.text = ""
	_hide_progress()
	_last_unit_ids.clear()
	_last_building_id = -1
	_showing_build_buttons = false

	# Owner tag — Enemy / Neutral.
	var owner_id: int = (target.get("owner_id") as int) if "owner_id" in target else -1
	var owner_label: String = "Enemy"
	if owner_id == 2:
		owner_label = "Neutral"

	var raw_stats: Resource = target.get("stats") as Resource if "stats" in target else null

	# Building branch — BuildingStatResource has its own field names
	# (building_name, hp) that don't line up with UnitStatResource, so
	# they need a separate readout. Right-clicking an enemy structure
	# already routes here via the inspect path.
	var bstats: BuildingStatResource = raw_stats as BuildingStatResource
	if bstats:
		var bhp_now: int = (target.get("current_hp") as int) if "current_hp" in target else 0
		var bhp_max: int = bstats.hp
		_name_label.text = "%s (%s)" % [bstats.building_name, owner_label]
		_stats_label.text = _build_building_stat_sheet(target, bstats, bhp_now)
		var bhp_pct: float = float(bhp_now) / float(maxi(bhp_max, 1))
		var bhp_color: Color = Color(0.95, 0.4, 0.35, 0.95)
		if bhp_pct >= 0.5:
			bhp_color = Color(0.95, 0.78, 0.32, 0.95)
		_show_progress(bhp_pct, bhp_color)
		return

	var stats: UnitStatResource = raw_stats as UnitStatResource
	# Unit tracks HP via per-member arrays; the only public total is
	# `get_total_hp()`. Aircraft also expose it as a method (returning
	# `current_hp`). Falling through to the field for nodes without
	# the method just to avoid crashes.
	var hp_now: int = 0
	if target.has_method("get_total_hp"):
		hp_now = target.call("get_total_hp") as int
	elif "current_hp" in target:
		hp_now = target.get("current_hp") as int
	var hp_max: int = stats.hp_total if stats else hp_now

	if stats:
		_name_label.text = "%s (%s)" % [stats.unit_name, owner_label]
		# Same stat sheet as a friendly unit, but with cost / pop chips
		# omitted — the player can't act on enemy stats. Damage (DPS
		# vs Gnd / DPS vs Air) explicitly included so the player can
		# see what an enemy unit threatens before engaging.
		_stats_label.text = _build_unit_stat_sheet(target, false)
		var hp_pct: float = float(hp_now) / float(maxi(hp_max, 1))
		var hp_color: Color = Color(0.95, 0.4, 0.35, 0.95)
		if hp_pct >= 0.5:
			hp_color = Color(0.95, 0.78, 0.32, 0.95)
		_show_progress(hp_pct, hp_color)
	else:
		_name_label.text = "%s Unit" % owner_label
		_stats_label.text = _build_stat_sheet([[_stat_chip("HP", str(hp_now), STAT_LABEL_COLOR_HP)]])


func _update_crawler_panel(crawler: SalvageCrawler) -> void:
	## Crawler bottom-panel readout — name, HP, worker count, harvest range,
	## state (anchored / deploying / mobile), HP bar, and an Anchor toggle
	## button when the upgrade is researched.

	# Rebuild buttons only when the action changes — keep state stable when
	# selection is unchanged. ALSO force a rebuild when transitioning IN
	# from another panel type that left _showing_build_buttons set
	# (e.g. the player had an engineer + crawler selected, then
	# deselected the engineer); without this the previous panel's
	# build buttons would persist on a crawler-only selection.
	var current_action: String = _crawler_action_key(crawler)
	var prev_action: String = str(get_meta("_crawler_action", ""))
	if _showing_build_buttons or current_action != prev_action:
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
	_stats_label.text = _build_stat_sheet([
		[
			_stat_chip("HP", "%d / %d" % [crawler.current_hp, max_hp], STAT_LABEL_COLOR_HP),
			_stat_chip("Class", "Crawler", STAT_LABEL_COLOR_DEFENSE),
			_stat_chip("State", state_label, STAT_LABEL_COLOR_RANGE),
		],
		[
			_stat_chip("Workers", "%d / %d" % [worker_count, max_workers], STAT_LABEL_COLOR_SQUAD),
			_stat_chip("Harvest", "%dm" % int(harvest_radius), STAT_LABEL_COLOR_RANGE),
		],
	])

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
		_stats_label.text = _build_stat_sheet([
			[_stat_chip("Status", "Under Construction", STAT_LABEL_COLOR_RANGE)],
		])
		_queue_label.text = ""
		_show_progress(building.get_construction_percent(), Color(0.95, 0.78, 0.32, 0.95))
		return

	_name_label.text = building.stats.building_name
	_stats_label.text = _build_building_stat_sheet(building, building.stats, building.current_hp)

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
		# Build-queue ETA tooltip — hover the bar to see "Currently:
		# Hound — 14s" plus the queue tail. Implemented via the
		# bar's tooltip_text rather than a custom popup so it picks
		# up the same fast tooltip delay as everything else.
		_progress_bar.tooltip_text = _build_queue_tooltip(building)
	else:
		_queue_label.text = ""
		_hide_progress()

	# Queue icons — one button per pending unit, click to cancel and
	# refund. Yards / armories don't have a build queue in the usual
	# sense, so they fall through with an empty row (no icons rendered).
	_refresh_queue_icons(building)


func _build_queue_tooltip(building: Building) -> String:
	## Composes a multi-line tooltip for the production progress bar:
	## current unit + remaining seconds, then the queue tail. Returns
	## empty when there's nothing in the queue.
	if not building or building.get_queue_size() <= 0:
		return ""
	var queue: Array = building.get("_build_queue") as Array
	if queue.is_empty():
		return ""
	var current: UnitStatResource = queue[0] as UnitStatResource
	if not current:
		return ""
	var build_progress: float = building.get("_build_progress") as float
	var remaining: float = maxf(current.build_time - build_progress, 0.0)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Currently: %s — %ds" % [current.unit_name, int(ceil(remaining))])
	if queue.size() > 1:
		var tail: PackedStringArray = PackedStringArray()
		for i: int in range(1, queue.size()):
			var u: UnitStatResource = queue[i] as UnitStatResource
			if u:
				tail.append(u.unit_name)
		if not tail.is_empty():
			lines.append("Queued: %s" % ", ".join(tail))
	return "\n".join(lines)


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
		_progress_bar.tooltip_text = ""


## --- FPS counter ---
##
## Top-right corner — small monospace-ish label showing the current
## frame rate, refreshed at most every 0.25s so the digit churn doesn't
## distract.

var _fps_label: Label = null
var _fps_refresh_timer: float = 0.0


func _build_fps_counter() -> void:
	_fps_label = Label.new()
	_fps_label.name = "FPSCounter"
	_fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_fps_label.position = Vector2(-90.0, 12.0)
	_fps_label.custom_minimum_size = Vector2(76.0, 0.0)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
	_fps_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	_fps_label.add_theme_constant_override("outline_size", 4)
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fps_label)


func _update_selection_roster() -> void:
	## Rebuild the roster strip when the selection changes. Shows
	## a chip per unique unit_class in the current selection with a
	## live count + average HP fill. Hidden when no units are
	## selected or only one class is in play (the regular bottom-
	## panel readout already covers that case).
	if not _roster_strip or not _selection_manager:
		return
	var units: Array[Node3D] = _selection_manager.get_selected_units()
	if units.size() <= 1:
		_roster_strip.visible = false
		return
	# Bucket per unit_name + accumulate HP fill.
	var buckets: Dictionary = {}
	for unit: Node3D in units:
		if not is_instance_valid(unit) or not ("stats" in unit) or not unit.stats:
			continue
		var key: String = unit.stats.unit_name
		if not buckets.has(key):
			buckets[key] = {
				"count": 0,
				"hp_now": 0,
				"hp_max": 0,
				"class": str(unit.stats.unit_class),
			}
		var b: Dictionary = buckets[key]
		b["count"] = (b["count"] as int) + 1
		var hp_now: int = 0
		if unit.has_method("get_total_hp"):
			hp_now = unit.call("get_total_hp") as int
		b["hp_now"] = (b["hp_now"] as int) + hp_now
		b["hp_max"] = (b["hp_max"] as int) + (unit.stats.hp_total as int)
	if buckets.size() < 2:
		_roster_strip.visible = false
		return
	# Cheap signature so we only rebuild when classes/counts change.
	var sig: String = ""
	for k: String in buckets.keys():
		sig += "%s:%d|" % [k, (buckets[k] as Dictionary)["count"] as int]
	if sig != _roster_last_signature:
		_roster_last_signature = sig
		for child: Node in _roster_strip.get_children():
			child.queue_free()
		for class_name_str: String in buckets.keys():
			var data: Dictionary = buckets[class_name_str] as Dictionary
			_roster_strip.add_child(_make_roster_chip(class_name_str, data))
	_roster_strip.visible = true


func _make_roster_chip(class_name_str: String, data: Dictionary) -> Control:
	var hp_now: int = data["hp_now"] as int
	var hp_max: int = maxi(data["hp_max"] as int, 1)
	var fill: float = clampf(float(hp_now) / float(hp_max), 0.0, 1.0)
	var fill_color: Color = Color(0.40, 0.95, 0.40, 0.95)
	if fill < 0.5: fill_color = Color(0.95, 0.78, 0.32, 0.95)
	if fill < 0.25: fill_color = Color(1.0, 0.40, 0.35, 0.95)
	# Class swatch (left) + label + HP sliver as a vertical chip.
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(0, 28)
	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	chip.add_child(inner)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(6, 22)
	swatch.color = _class_swatch_color(data["class"] as String)
	inner.add_child(swatch)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(col)
	var name_lbl := Label.new()
	name_lbl.text = "%dx %s" % [data["count"] as int, class_name_str]
	name_lbl.add_theme_font_size_override("font_size", 12)
	col.add_child(name_lbl)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 4)
	bar.value = fill * 100.0
	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = fill_color
	bar.add_theme_stylebox_override("fill", fill_sb)
	col.add_child(bar)
	return chip


func _class_swatch_color(unit_class: String) -> Color:
	match unit_class.to_lower():
		"engineer": return Color(0.60, 0.85, 0.40, 1.0)
		"light":    return Color(0.40, 0.85, 1.00, 1.0)
		"medium":   return Color(0.95, 0.80, 0.35, 1.0)
		"heavy":    return Color(1.00, 0.50, 0.35, 1.0)
		"aircraft": return Color(0.78, 0.55, 1.00, 1.0)
		"apex":     return Color(0.95, 0.40, 0.95, 1.0)
	return Color(0.85, 0.85, 0.85, 1.0)


func _build_selection_roster() -> void:
	## Vertical chip column floating ABOVE the bottom panel on the
	## left edge of the screen, NOT inside the bottom panel itself.
	## Earlier the strip was a child of _bottom_panel — its layout
	## could pour HP-sliver chips over the production / build /
	## command buttons in the action grid. Making it a HUD-root child
	## anchored bottom-left guarantees it floats to the left of the
	## panel and never collides with the action buttons.
	_roster_strip = VBoxContainer.new()
	_roster_strip.name = "SelectionRoster"
	_roster_strip.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_roster_strip.add_theme_constant_override("separation", 4)
	_roster_strip.offset_left = 12
	_roster_strip.offset_right = 12 + 168
	# Bottom panel grew from 120 -> 150px tall to fit the new
	# multi-row stat sheet, so the roster strip's bottom anchor
	# moved up to clear it (roster sits ABOVE the panel).
	_roster_strip.offset_top = -290
	_roster_strip.offset_bottom = -160
	_roster_strip.size_flags_horizontal = 0
	_roster_strip.size_flags_vertical = 0
	_roster_strip.mouse_filter = Control.MOUSE_FILTER_PASS
	_roster_strip.visible = false
	add_child(_roster_strip)


var _mesh_overlay_on: bool = false


func _toggle_mesh_overlay() -> void:
	## V3 §Pillar 2 — flip every MeshAuraRing's emission energy so
	## the rings either pulse subtly (default, off) or punch out
	## brightly (overlay, on). No new geometry is created; we just
	## bump the emission multiplier on the existing per-provider
	## rings + the central column glow.
	_mesh_overlay_on = not _mesh_overlay_on
	var bright: float = 2.4 if _mesh_overlay_on else 0.85
	# Walk every MeshAuraRing in the scene.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		_apply_mesh_overlay_to(node, bright)
	for node: Node in get_tree().get_nodes_in_group("units"):
		_apply_mesh_overlay_to(node, bright)


func _apply_mesh_overlay_to(node: Node, energy: float) -> void:
	if not is_instance_valid(node):
		return
	var ring: Node = node.get_node_or_null("MeshAuraRing")
	if not ring or not (ring is MeshInstance3D):
		return
	var mat: StandardMaterial3D = (ring as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
	if mat:
		mat.emission_energy_multiplier = energy
		var c: Color = mat.albedo_color
		c.a = 0.85 if _mesh_overlay_on else 0.50
		mat.albedo_color = c


func _refresh_hotkey_palette() -> void:
	## Repopulates the palette with hotkeys relevant to the current
	## selection: camera + global shortcuts, plus production /
	## build / unit-command hotkeys when applicable.
	if not _hotkey_palette_label:
		return
	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b]Hotkeys[/b]   (hold Tab to view)")
	lines.append("")
	lines.append("[color=#9fd0ff]Global[/color]")
	lines.append("  Esc — pause / settings")
	lines.append("  Tab — show this overlay")
	lines.append("  M — toggle Mesh coverage overlay (Sable)")
	lines.append("  WASD / arrow keys — pan camera")
	lines.append("  QE / mouse wheel — zoom")
	lines.append("  Ctrl + 1-9 — assign control group")
	lines.append("  1-9 — recall control group")
	lines.append("  Double-press group — center camera on group")
	# Show selection-context hotkeys when something is selected.
	var units: Array[Node3D] = []
	if _selection_manager:
		units = _selection_manager.get_selected_units()
	if not units.is_empty():
		lines.append("")
		lines.append("[color=#9fd0ff]Unit Commands[/color]")
		lines.append("  Right-click — move / attack-move")
		lines.append("  S — stop")
		lines.append("  H — hold ground")
		lines.append("  P — patrol")
		lines.append("  A — attack-move (then click)")
	# Production / build buttons always have hotkeys assigned per
	# the action panel; mirror them here.
	if not _action_buttons.is_empty():
		var first_kind: String = (_action_buttons[0] as Dictionary).get("kind", "") as String
		if first_kind == "produce":
			lines.append("")
			lines.append("[color=#9fd0ff]Production[/color]")
			lines.append("  Q W E R T — train queued slot")
		elif first_kind == "build":
			lines.append("")
			lines.append("[color=#9fd0ff]Build Menu[/color]")
			lines.append("  1-6 — start building placement")
			lines.append("  Esc — cancel placement")
	_hotkey_palette_label.text = "\n".join(lines)


func _build_hotkey_palette() -> void:
	## Translucent overlay anchored bottom-centre, populated on demand
	## when Tab is held. Lists every hotkey that maps to a real action
	## right now (selection commands, production hotkeys, build menu).
	_hotkey_palette = PanelContainer.new()
	_hotkey_palette.name = "HotkeyPalette"
	_hotkey_palette.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hotkey_palette.offset_left = -260
	_hotkey_palette.offset_right = 260
	_hotkey_palette.offset_top = -300
	_hotkey_palette.offset_bottom = -60
	_hotkey_palette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hotkey_palette.modulate = Color(1.0, 1.0, 1.0, 0.92)
	_hotkey_palette.visible = false
	add_child(_hotkey_palette)
	_hotkey_palette_label = RichTextLabel.new()
	_hotkey_palette_label.bbcode_enabled = true
	_hotkey_palette_label.fit_content = true
	_hotkey_palette_label.scroll_active = false
	_hotkey_palette_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hotkey_palette_label.add_theme_font_size_override("normal_font_size", 14)
	_hotkey_palette.add_child(_hotkey_palette_label)


func _apply_top_bar_faction_theme() -> void:
	## Adds a faction-coloured underline to the top resource bar so
	## the bar itself signals which faction the player picked. Anvil
	## gets warm brass, Sable gets violet. Drawn as a thin ColorRect
	## anchored to the bottom edge of the TopBarBackdrop.
	var backdrop: ColorRect = get_node_or_null("TopBarBackdrop") as ColorRect
	if not backdrop:
		return
	var faction_id: int = 0
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "player_faction" in settings:
		faction_id = settings.get("player_faction") as int
	var accent: Color = Color(1.0, 0.82, 0.35, 1.0) if faction_id == 0 else Color(0.78, 0.45, 1.0, 1.0)
	# Thin underline strip — 2px tall, full width, anchored to the
	# bottom of the backdrop.
	var underline := ColorRect.new()
	underline.name = "TopBarFactionUnderline"
	underline.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	underline.offset_top = -2
	underline.offset_bottom = 0
	underline.color = accent
	underline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.add_child(underline)
	# Pair of small faction-coloured corner caps so the bar reads
	# as a properly framed strip rather than just a dark rectangle.
	for side: int in 2:
		var cap := ColorRect.new()
		cap.set_anchors_preset(Control.PRESET_TOP_LEFT if side == 0 else Control.PRESET_TOP_RIGHT)
		cap.offset_left = 0 if side == 0 else -64
		cap.offset_right = 64 if side == 0 else 0
		cap.offset_top = 0
		cap.offset_bottom = 4
		cap.color = accent.darkened(0.15)
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		backdrop.add_child(cap)


func _build_faction_watermark() -> void:
	## Soft 30%-alpha faction emblem in the lower-right corner of the
	## bottom panel. Uses the same procedural FactionIcon as the main
	## menu so the in-match HUD still reinforces the player's faction
	## identity at a glance — Anvil iron-rivet plate or Sable matte-
	## black diamond.
	if not _bottom_panel:
		return
	var faction_id: int = 0
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "player_faction" in settings:
		faction_id = settings.get("player_faction") as int
	var icon_script: GDScript = load("res://scripts/faction_icon.gd") as GDScript
	if not icon_script:
		return
	var watermark: Control = Control.new()
	watermark.set_script(icon_script)
	watermark.set("faction", faction_id)
	watermark.modulate = Color(1.0, 1.0, 1.0, 0.30)
	watermark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	watermark.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	watermark.custom_minimum_size = Vector2(56, 56)
	watermark.size = Vector2(56, 56)
	watermark.position = Vector2(-72, -64)
	_bottom_panel.add_child(watermark)


func _apply_tooltip_delay(seconds: float) -> void:
	## Drops the global tooltip hover delay from Godot's default
	## 0.5s to a tighter value so production / build / inspect
	## tooltips fire faster during active play.
	ProjectSettings.set_setting("gui/timers/tooltip_delay_sec", seconds)


func _refresh_fps_counter(delta: float) -> void:
	if not _fps_label:
		return
	_fps_refresh_timer -= delta
	if _fps_refresh_timer > 0.0:
		return
	_fps_refresh_timer = 0.25
	var fps: int = Engine.get_frames_per_second()
	_fps_label.text = "%d FPS" % fps
	# Tint by health: green ≥55, amber 30–54, red <30.
	var color: Color = Color(0.6, 0.95, 0.6, 1.0)
	if fps < 55:
		color = Color(0.95, 0.85, 0.4, 1.0)
	if fps < 30:
		color = Color(0.95, 0.4, 0.35, 1.0)
	_fps_label.add_theme_color_override("font_color", color)


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
## Cache the last building + queue contents we rendered so the icons
## row only rebuilds when something actually changed. Without this the
## row queue_free'd its children every frame, which raced with click
## input — clicking a queue icon often happened on a button that was
## already pending free, and the cancel signal was lost.
var _last_queue_signature: String = ""


func _ensure_queue_icons_row() -> void:
	if _queue_icons_row and is_instance_valid(_queue_icons_row):
		return
	_queue_icons_row = HBoxContainer.new()
	_queue_icons_row.name = "QueueIconsRow"
	_queue_icons_row.add_theme_constant_override("separation", 4)
	_info_section.add_child(_queue_icons_row)


func _refresh_queue_icons(building: Building) -> void:
	_ensure_queue_icons_row()

	if not building or not building.is_constructed:
		_queue_icons_row.visible = false
		_last_queue_signature = ""
		return
	var queue: Array = []
	if building.has_method("get_queue_snapshot"):
		queue = building.get_queue_snapshot()

	# Build a cheap signature so we only rebuild when the queue actually
	# changes — building id + each unit's instance_id in order.
	var sig := "%d" % building.get_instance_id()
	for entry: UnitStatResource in queue:
		sig += ":%d" % (entry.get_instance_id() if entry else 0)
	if sig == _last_queue_signature:
		return
	_last_queue_signature = sig

	# Clear existing icons — only happens on actual change now.
	for child: Node in _queue_icons_row.get_children():
		child.queue_free()

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


## --- Unit command buttons ---
##
## Stand Ground / Patrol / Attack-Move row shown when a non-engineer
## unit is selected. Clicking Patrol or Attack-Move puts the
## SelectionManager into a target-pick mode; the next right-click
## sets the destination.

func _rebuild_unit_command_buttons() -> void:
	_action_label.text = "Commands"
	# Hold (Stand Ground)
	var hold_btn := Button.new()
	hold_btn.text = "[S] Hold"
	hold_btn.tooltip_text = "Stand Ground — units stop moving and don't chase enemies, but still fire on threats in range."
	hold_btn.custom_minimum_size = Vector2(94, 42)
	hold_btn.pressed.connect(_on_hold_button)
	_button_grid.add_child(hold_btn)
	_action_buttons.append({"button": hold_btn, "kind": "command", "key": "hold"})
	# Patrol
	var patrol_btn := Button.new()
	patrol_btn.text = "[P] Patrol"
	patrol_btn.tooltip_text = "Patrol — units walk between current position and a chosen point, attacking en route."
	patrol_btn.custom_minimum_size = Vector2(94, 42)
	patrol_btn.pressed.connect(_on_patrol_button)
	_button_grid.add_child(patrol_btn)
	_action_buttons.append({"button": patrol_btn, "kind": "command", "key": "patrol"})
	# Attack-Move
	var amove_btn := Button.new()
	amove_btn.text = "[A] Attack-Move"
	amove_btn.tooltip_text = "Attack-Move — units advance to a point and engage anything they pass on the way."
	amove_btn.custom_minimum_size = Vector2(120, 42)
	amove_btn.pressed.connect(_on_attack_move_button)
	_button_grid.add_child(amove_btn)
	_action_buttons.append({"button": amove_btn, "kind": "command", "key": "attack_move"})

	# Active-ability button — added when EVERY unit in the current
	# selection shares the same ability (so a mixed selection of
	# Pulsefonts + Hounds doesn't show a button that only fires on
	# half of them). The button label flips between the cast / cooldown
	# states each frame via _refresh_ability_button. Tinted distinct
	# from the standard command buttons (violet vs grey) so the
	# player sees at a glance that this slot is a special action,
	# not another move command.
	var ability_units: Array[Node3D] = _selection_ability_units()
	if not ability_units.is_empty():
		var first: Node3D = ability_units[0]
		var ability_stat: UnitStatResource = first.stats
		var ability_btn := Button.new()
		ability_btn.custom_minimum_size = Vector2(150, 42)
		ability_btn.tooltip_text = "%s\n%s\nCooldown %ds" % [
			ability_stat.ability_name,
			ability_stat.ability_description,
			int(ability_stat.ability_cooldown),
		]
		_paint_ability_button_style(ability_btn)
		# Autocast indicator — small "AUTO" badge anchored to the
		# top-right of the button so the player reads at a glance
		# that this ability fires on its own when the unit's in
		# combat. Manual press still works (and fast-forwards
		# cooldown rolls if available).
		if ability_stat.ability_autocast:
			_attach_autocast_badge(ability_btn)
		ability_btn.pressed.connect(_on_ability_button.bind(ability_units))
		_button_grid.add_child(ability_btn)
		_action_buttons.append({
			"button": ability_btn,
			"kind": "ability",
			"units": ability_units,
			"stat": ability_stat,
		})


func _selection_ability_units() -> Array[Node3D]:
	## Returns the subset of the current selection that shares one
	## active ability. Empty when no selected unit has an ability or
	## when the selection mixes ability types.
	var out: Array[Node3D] = []
	if not _selection_manager:
		return out
	var selected: Array[Node3D] = _selection_manager.get_selected_units() as Array[Node3D]
	if selected.is_empty():
		return out
	var ability_id: String = ""
	for unit: Node3D in selected:
		if not is_instance_valid(unit) or not "stats" in unit:
			continue
		var s: UnitStatResource = unit.get("stats") as UnitStatResource
		if not s or s.ability_name == "":
			continue
		if ability_id == "":
			ability_id = s.ability_name
		elif ability_id != s.ability_name:
			# Mixed ability types — no shared button.
			return [] as Array[Node3D]
		out.append(unit)
	return out


func _paint_ability_button_style(btn: Button) -> void:
	## Distinct stylebox + label colour for active-ability buttons so
	## they stand out from the grey Hold / Patrol / Attack-Move slots.
	## Violet matches the COLOR_MICROCHIPS / overall "special action"
	## tinting in the rest of the HUD.
	var ability_color: Color = Color(0.62, 0.32, 0.92, 1.0)
	var bg_normal := StyleBoxFlat.new()
	bg_normal.bg_color = Color(0.20, 0.10, 0.30, 1.0)
	bg_normal.border_color = ability_color
	bg_normal.set_border_width_all(2)
	bg_normal.set_corner_radius_all(3)
	bg_normal.content_margin_left = 6
	bg_normal.content_margin_right = 6
	bg_normal.content_margin_top = 4
	bg_normal.content_margin_bottom = 4
	var bg_hover := bg_normal.duplicate()
	bg_hover.bg_color = Color(0.28, 0.14, 0.40, 1.0)
	var bg_pressed := bg_normal.duplicate()
	bg_pressed.bg_color = Color(0.36, 0.20, 0.48, 1.0)
	var bg_disabled := bg_normal.duplicate()
	bg_disabled.bg_color = Color(0.14, 0.10, 0.18, 1.0)
	bg_disabled.border_color = Color(0.40, 0.30, 0.55, 1.0)
	btn.add_theme_stylebox_override("normal", bg_normal)
	btn.add_theme_stylebox_override("hover", bg_hover)
	btn.add_theme_stylebox_override("pressed", bg_pressed)
	btn.add_theme_stylebox_override("disabled", bg_disabled)
	btn.add_theme_color_override("font_color", Color(0.92, 0.85, 1.0))


func _attach_autocast_badge(btn: Button) -> void:
	## Top-right "AUTO" pill on an ability button so the player
	## reads the autocast cue without hovering for the tooltip.
	## Pulses gently via a Tween so it doesn't blend with the
	## static stylebox.
	var pill := PanelContainer.new()
	pill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pill.offset_left = -42
	pill.offset_top = 2
	pill.offset_right = -2
	pill.offset_bottom = 18
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pill_style := StyleBoxFlat.new()
	pill_style.bg_color = Color(0.30, 0.92, 0.55, 0.85)
	pill_style.set_corner_radius_all(6)
	pill_style.content_margin_left = 4
	pill_style.content_margin_right = 4
	pill_style.content_margin_top = 0
	pill_style.content_margin_bottom = 0
	pill.add_theme_stylebox_override("panel", pill_style)
	var lbl := Label.new()
	lbl.text = "AUTO"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.05, 0.10, 0.05))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(lbl)
	btn.add_child(pill)
	# Pulse the pill alpha so the autocast read stays visible
	# even if the player isn't focused on the button. Loops
	# indefinitely; cleared automatically when the button is
	# freed (Tween is parented to the badge).
	var tween: Tween = pill.create_tween().set_loops()
	tween.tween_property(pill, "modulate:a", 0.55, 0.8)
	tween.tween_property(pill, "modulate:a", 1.0, 0.8)


func _on_ability_button(units: Array[Node3D]) -> void:
	## Fire the ability on every unit in the cohort that has one
	## ready. Cooldown gating happens per-unit inside trigger_ability,
	## so a half-on-cooldown squad will partial-fire — the units that
	## are ready cast, the ones still cooling down skip.
	for unit: Node3D in units:
		if is_instance_valid(unit) and unit.has_method("trigger_ability"):
			unit.call("trigger_ability")


func _on_hold_button() -> void:
	if _selection_manager and _selection_manager.has_method("command_hold_position_on_selection"):
		_selection_manager.command_hold_position_on_selection()


func _on_patrol_button() -> void:
	if _selection_manager and _selection_manager.has_method("enter_patrol_target_mode"):
		_selection_manager.enter_patrol_target_mode()


func _on_attack_move_button() -> void:
	if _selection_manager and _selection_manager.has_method("enter_attack_move_mode"):
		_selection_manager.enter_attack_move_mode()


## --- Production / Build buttons ---

func _rebuild_production_buttons(building: Building) -> void:
	_clear_buttons()

	# Faction-aware producible list — Sable HQ shows Sable units, etc.
	var producible: Array[UnitStatResource] = building.get_producible_units()
	if producible.is_empty():
		_action_label.text = "No production"
		return

	_action_label.text = "Train Units"
	var hotkeys: Array[String] = ["Q", "W", "E", "R", "T"]

	for i: int in producible.size():
		var unit_stat: UnitStatResource = producible[i]
		var hotkey: String = hotkeys[i] if i < hotkeys.size() else str(i + 1)

		var btn := Button.new()
		# Bumped to 70px height so a wrapped two-line name + the
		# bottom cost-chip strip both fit cleanly without overlap.
		btn.custom_minimum_size = Vector2(108, 70)
		btn.size_flags_horizontal = Control.SIZE_FILL
		btn.size_flags_vertical = Control.SIZE_FILL
		_set_label_button(btn, "[%s]" % hotkey, unit_stat.unit_name)
		btn.tooltip_text = _unit_tooltip(unit_stat)
		btn.pressed.connect(_on_production_button.bind(i))
		_button_grid.add_child(btn)
		var chip_refs: Dictionary = _attach_cost_widget(btn, unit_stat.cost_salvage, unit_stat.cost_fuel, unit_stat.population)
		_action_buttons.append({ "button": btn, "kind": "produce", "stat": unit_stat, "chips": chip_refs })


func _on_production_button(index: int) -> void:
	if _selection_manager:
		_selection_manager.queue_unit_at_building(index)


## Color codes used by `_attach_cost_widget` for the salvage / fuel /
## population swatches on production + build buttons. Each swatch +
## number reads at a glance even when the eye is busy elsewhere.
const RES_COLOR_SALVAGE: Color = Color(1.00, 0.78, 0.30, 1.0)  # warm gold
const RES_COLOR_FUEL: Color = Color(0.30, 0.85, 1.00, 1.0)     # cyan
const RES_COLOR_POP: Color = Color(0.78, 0.95, 0.55, 1.0)      # green-tan
const RES_COLOR_MICROCHIPS: Color = Color(0.85, 0.55, 1.0, 1.0) # violet


## --- Stat sheet builder ---------------------------------------------------
##
## Every selection panel — friendly unit, enemy unit, building, Crawler —
## funnels its stat readout through `_build_stat_sheet` so the format stays
## consistent regardless of what's selected. Each row is an array of "chips"
## (label, value, color); chips on the same row are joined with a divider,
## rows are joined with newlines. Reads as a real stat sheet at a glance
## instead of a single comma-separated wall.

const STAT_CHIP_DIVIDER: String = "    "
const STAT_LABEL_COLOR_HP: String = "ff8a4a"        # warm orange (HP)
const STAT_LABEL_COLOR_DEFENSE: String = "c5a05c"   # tan (armor / class)
const STAT_LABEL_COLOR_DAMAGE: String = "ff5d5d"    # red (damage / DPS)
const STAT_LABEL_COLOR_RANGE: String = "9bd1ff"     # pale blue (range / accuracy)
const STAT_LABEL_COLOR_MOBILITY: String = "8feda0"  # green (speed)
const STAT_LABEL_COLOR_SQUAD: String = "c8c8c8"     # neutral grey (squad / pop)
const STAT_LABEL_COLOR_COST_S: String = "ffc850"    # salvage gold
const STAT_LABEL_COLOR_COST_F: String = "66d8ff"    # fuel cyan
const STAT_LABEL_COLOR_COST_M: String = "d88aff"    # microchips violet


func _stat_chip(label: String, value: String, color_hex: String) -> String:
	## A single labelled stat chip. Label is colour-tagged; value uses
	## the RichTextLabel default colour so it stays at full brightness.
	return "[color=#%s]%s[/color] %s" % [color_hex, label, value]


func _build_stat_sheet(rows: Array) -> String:
	## Joins an array-of-arrays of pre-formatted chips into a BBCode
	## string. Expects each row entry to already be a chip string from
	## `_stat_chip`. Empty rows are skipped so a missing-cost branch
	## doesn't leave a blank line in the readout.
	var lines: PackedStringArray = PackedStringArray()
	for row: Variant in rows:
		var chips: Array = row as Array
		if chips.is_empty():
			continue
		lines.append(STAT_CHIP_DIVIDER.join(chips))
	return "\n".join(lines)


func _build_unit_stat_sheet(unit: Node3D, include_cost: bool) -> String:
	## Three-row stat sheet for a unit. Used by both the friendly
	## single-select panel and the enemy / neutral inspect panel
	## (passing include_cost=false hides the salvage/fuel chips on
	## enemy units since the player can't act on them). Rows in
	## order: defense, combat, mobility/economy.
	var stats: UnitStatResource = unit.stats as UnitStatResource
	if not stats:
		return ""
	var hp_now: int = unit.get_total_hp() if unit.has_method("get_total_hp") else 0
	if hp_now == 0 and "current_hp" in unit:
		hp_now = unit.get("current_hp") as int
	var alive: int = (unit.get("alive_count") as int) if "alive_count" in unit else 1

	# Row 1 — defense.
	var row_defense: Array = [
		_stat_chip("HP", "%d / %d" % [hp_now, stats.hp_total], STAT_LABEL_COLOR_HP),
		_stat_chip("Class", str(stats.unit_class).capitalize(), STAT_LABEL_COLOR_DEFENSE),
		_stat_chip("Armor", str(stats.armor_class).capitalize(), STAT_LABEL_COLOR_DEFENSE),
	]

	# Row 2 — combat. Always show both DPS-vs-ground and DPS-vs-air
	# with explicit labels so the player can read "this unit can / can't
	# hit aircraft" without guessing from the role tag alone. Range
	# and accuracy fall on the same row to keep all combat numbers
	# in one scannable line.
	var dps_ground: float = _compute_dps_vs(stats, &"medium")
	var dps_air: float = _compute_dps_vs(stats, &"light_air")
	var range_u: float = _max_weapon_range(stats)
	var acc_pct: int = int(_effective_accuracy(unit) * 100.0)
	var row_combat: Array = [
		_stat_chip("DPS Gnd", "%.0f" % dps_ground, STAT_LABEL_COLOR_DAMAGE),
		_stat_chip("DPS Air", "%.0f" % dps_air, STAT_LABEL_COLOR_DAMAGE),
		_stat_chip("Range", "%.0fu" % range_u, STAT_LABEL_COLOR_RANGE),
		_stat_chip("Acc", "%d%%" % acc_pct, STAT_LABEL_COLOR_RANGE),
	]

	# Row 3 — mobility + (player units only) cost / pop.
	var row_mobility: Array = [
		_stat_chip("Speed", _speed_label(stats.speed_tier), STAT_LABEL_COLOR_MOBILITY),
		_stat_chip("Squad", "%d / %d" % [alive, stats.squad_size], STAT_LABEL_COLOR_SQUAD),
	]
	if include_cost:
		row_mobility.append(_stat_chip("Pop", str(stats.population), STAT_LABEL_COLOR_SQUAD))
		row_mobility.append(_stat_chip("Cost", "%dS / %dF" % [stats.cost_salvage, stats.cost_fuel], STAT_LABEL_COLOR_COST_S))

	# Optional row 4 — weapon character. One short summary so the player
	# knows whether the DPS comes from a slow cannon, a continuous beam,
	# a missile salvo, etc. Pulled into its own row so the combat
	# numbers row stays clean.
	var weapon_summary: String = _weapon_summary(stats)
	var row_weapons: Array = []
	if weapon_summary != "":
		row_weapons.append(_stat_chip("Weapons", weapon_summary, STAT_LABEL_COLOR_RANGE))

	return _build_stat_sheet([row_defense, row_combat, row_mobility, row_weapons])


func _build_building_stat_sheet(building: Node3D, bstats: BuildingStatResource, hp_now: int) -> String:
	## Compact building / structure stat sheet. Shows HP, power impact,
	## and (when applicable) turret DPS so the player can compare a
	## gun-emplacement profile to a mech weapon at a glance.
	var rows: Array = []
	var defense_row: Array = [
		_stat_chip("HP", "%d / %d" % [hp_now, bstats.hp], STAT_LABEL_COLOR_HP),
		_stat_chip("Class", "Structure", STAT_LABEL_COLOR_DEFENSE),
	]
	if bstats.power_production > 0:
		defense_row.append(_stat_chip("Power", "+%d" % bstats.power_production, STAT_LABEL_COLOR_MOBILITY))
	elif bstats.power_consumption > 0:
		defense_row.append(_stat_chip("Power", "-%d" % bstats.power_consumption, STAT_LABEL_COLOR_DAMAGE))
	rows.append(defense_row)

	# Turret stats (gun emplacements / SAM sites that have a
	# TurretComponent attached). Mirrors the per-shot damage table used
	# by the actual fire path.
	var turret: Node = building.get_node_or_null("TurretComponent") if building else null
	if turret:
		var dps: float = float(TurretComponent.TURRET_DAMAGE) / TurretComponent.FIRE_INTERVAL
		var combat_row: Array = [
			_stat_chip("DPS", "%.0f" % dps, STAT_LABEL_COLOR_DAMAGE),
			_stat_chip("Range", "%.0fu" % TurretComponent.TURRET_RANGE, STAT_LABEL_COLOR_RANGE),
		]
		rows.append(combat_row)

	if not bstats.producible_units.is_empty():
		var produces_row: Array = [
			_stat_chip("Produces", "%d unit type(s)" % bstats.producible_units.size(), STAT_LABEL_COLOR_RANGE),
		]
		rows.append(produces_row)
	return _build_stat_sheet(rows)


func _set_label_button(btn: Button, prefix: String, name: String) -> void:
	## Production / build / branch buttons label themselves with a
	## hotkey prefix + a unit / building name. Long names like
	## "Switchblade (Strafe Runner)" or "Hammerhead Bomber" used to
	## clip on the 108px-wide button. This helper:
	##   - turns clip_text off
	##   - splits the name onto a second line at a sensible space
	##     when the full label would not fit on one
	##   - drops the font one notch if the longest line is still wide
	## so every name reads in full without the player having to hover
	## the tooltip.
	var single_line: String = "%s %s" % [prefix, name] if prefix != "" else name
	var max_one_line: int = 14  # roughly fits in 108px at default font
	if single_line.length() <= max_one_line:
		btn.clip_text = false
		btn.text = single_line
		return

	# Try to break the name itself in half. rfind with a starting
	# index searches backwards from that index, so we get the last
	# space at or before the cutoff — keeps the first line short
	# enough to fit, and pushes the long suffix onto line two.
	var name_cut: int = max_one_line - prefix.length() - 1
	if name_cut < 1:
		name_cut = 1
	var split_idx: int = name.rfind(" ", name_cut)
	if split_idx <= 0:
		split_idx = name.find(" ")  # fall back to first space if any

	var line_a: String = single_line
	var line_b: String = ""
	if split_idx > 0:
		line_a = "%s %s" % [prefix, name.substr(0, split_idx)] if prefix != "" else name.substr(0, split_idx)
		line_b = name.substr(split_idx + 1)

	btn.clip_text = false
	if line_b == "":
		# No splittable space — keep on one line and just shrink
		# the font so it fits inside the button.
		btn.text = single_line
		btn.add_theme_font_size_override("font_size", 11)
		return

	btn.text = "%s\n%s" % [line_a, line_b]
	# Shrink slightly when either half is still long, so the wider
	# of the two lines doesn't bleed into the cost strip below.
	var widest: int = maxi(line_a.length(), line_b.length())
	if widest > 14:
		btn.add_theme_font_size_override("font_size", 11)
	elif widest > 12:
		btn.add_theme_font_size_override("font_size", 12)


func _attach_cost_widget(btn: Button, salvage: int, fuel: int, pop: int) -> Dictionary:
	## Anchors a small colored cost-readout strip at the bottom of a
	## production / build button. Each resource gets its own swatch
	## (small ColorRect) and Label so the player can decode salvage
	## vs fuel vs pop at a glance instead of squinting at S/F/P.
	## Returns a dict mapping resource keys ("salvage" / "fuel" / "pop")
	## to {swatch, label} so the affordability pass can tint the
	## SPECIFIC chip red when that resource is the one running out,
	## leaving the others coloured normally.
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hbox.add_theme_constant_override("separation", 6)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.offset_top = -16
	hbox.offset_bottom = -3
	btn.add_child(hbox)
	var refs: Dictionary = {}
	if salvage > 0:
		refs["salvage"] = _add_cost_chip(hbox, salvage, RES_COLOR_SALVAGE)
	if fuel > 0:
		refs["fuel"] = _add_cost_chip(hbox, fuel, RES_COLOR_FUEL)
	if pop > 0:
		refs["pop"] = _add_cost_chip(hbox, pop, RES_COLOR_POP)
	return refs


func _add_cost_chip(parent: Container, amount: int, color: Color) -> Dictionary:
	var chip := HBoxContainer.new()
	chip.add_theme_constant_override("separation", 3)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(chip)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(8, 8)
	swatch.color = color
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(swatch)
	var lbl := Label.new()
	lbl.text = str(amount)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(lbl)
	return { "swatch": swatch, "label": lbl, "color": color }


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


## Faction roster of base units that have a branch commit. Only base
## units listed here surface in the Armory. Order matters — the panel
## renders these top-to-bottom in the same order the player sees in
## the Foundry production lineup.
const ANVIL_BRANCHED_UNITS: Array[String] = [
	"res://resources/units/anvil_rook.tres",
	"res://resources/units/anvil_hound.tres",
	"res://resources/units/anvil_phalanx.tres",
	"res://resources/units/anvil_hammerhead.tres",
	"res://resources/units/anvil_bulwark.tres",
	"res://resources/units/anvil_forgemaster.tres",
]
const SABLE_BRANCHED_UNITS: Array[String] = [
	"res://resources/units/sable_specter.tres",
	"res://resources/units/sable_jackal.tres",
	"res://resources/units/sable_courier_tank.tres",
	"res://resources/units/sable_fang.tres",
	"res://resources/units/sable_switchblade.tres",
	"res://resources/units/sable_harbinger.tres",
]


func _rebuild_armory_buttons(_building: Building) -> void:
	_clear_buttons()

	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if not bcm:
		_action_label.text = "No commit manager"
		return

	# Pick the player's faction's branch roster. Sable factions use
	# the Sable list; everyone else gets Anvil.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	var player_faction: int = 0
	if settings and "player_faction" in settings:
		player_faction = settings.get("player_faction") as int
	var paths: Array[String] = ANVIL_BRANCHED_UNITS
	if player_faction == 1:
		paths = SABLE_BRANCHED_UNITS

	if bcm.is_committing():
		_action_label.text = "Commit in progress: %s" % bcm.get_commit_branch_name()
	else:
		_action_label.text = "Armory — branch upgrades"

	# Branch upgrades cost the same across every base unit in v1 —
	# pulled from BranchCommitManager constants. Bake the cost line
	# into each tooltip so the player sees the price up-front.
	var cost_suffix: String = "  •  %dM / %dF / %dS" % [
		BranchCommitManager.COMMIT_COST_MICROCHIPS,
		BranchCommitManager.COMMIT_COST_FUEL,
		BranchCommitManager.COMMIT_COST_SALVAGE,
	]

	# Re-key the button grid to one column so each "row" we add lays
	# out vertically. Each row is itself an HBoxContainer holding the
	# unit name + branch A button + branch B button. This keeps the
	# armory layout aligned regardless of how many base units the
	# faction has.
	_button_grid.columns = 1

	# Render each branched base unit as one row.
	for path: String in paths:
		var base_stats: UnitStatResource = load(path) as UnitStatResource
		if not base_stats or not base_stats.branch_a_stats or not base_stats.branch_b_stats:
			continue
		_button_grid.add_child(_make_armory_row(base_stats, bcm, cost_suffix))

	# Anchor Mode research button — bottom of the list. Same currency
	# mix as a branch commit so the resource pressure is consistent.
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	if rm:
		_button_grid.add_child(_make_anchor_research_row(rm, cost_suffix))


func _make_armory_row(base_stats: UnitStatResource, bcm: Node, cost_suffix: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Name label — short header so the player can read the row's
	# subject before scanning the branch buttons.
	var name_lbl := Label.new()
	name_lbl.text = base_stats.unit_name
	name_lbl.custom_minimum_size = Vector2(110, 0)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.add_theme_color_override("font_color", Color(0.85, 0.82, 0.70, 1.0))
	row.add_child(name_lbl)

	if bcm.has_committed(base_stats.unit_name):
		# Already committed — show the committed branch name in
		# place of the two buttons so the row still reads clearly.
		var committed: UnitStatResource = bcm.get_committed_stats(base_stats.unit_name)
		var done_lbl := Label.new()
		done_lbl.text = "Committed: %s" % committed.unit_name
		done_lbl.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55, 1.0))
		done_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(done_lbl)
		return row

	var committing_now: bool = bcm.is_committing()
	row.add_child(_make_branch_button(base_stats, base_stats.branch_a_stats, base_stats.branch_a_name, cost_suffix, committing_now))
	row.add_child(_make_branch_button(base_stats, base_stats.branch_b_stats, base_stats.branch_b_name, cost_suffix, committing_now))
	return row


func _make_branch_button(
	base_stats: UnitStatResource,
	branch_stats: UnitStatResource,
	branch_name: String,
	cost_suffix: String,
	disabled: bool,
) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(120, 50)
	_set_label_button(btn, "", branch_name)
	btn.tooltip_text = _unit_tooltip(branch_stats) + "\n\nUpgrade cost:" + cost_suffix
	btn.pressed.connect(_on_branch_commit.bind(base_stats, branch_stats, branch_name))
	btn.disabled = disabled
	_attach_research_cost_widget(btn)
	return btn


func _make_anchor_research_row(rm: Node, cost_suffix: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = "Crawler"
	lbl.custom_minimum_size = Vector2(110, 0)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(0.85, 0.82, 0.70, 1.0))
	row.add_child(lbl)

	var anchor_btn := Button.new()
	anchor_btn.custom_minimum_size = Vector2(160, 50)
	if rm.is_researched(&"anchor_mode"):
		anchor_btn.text = "Anchor Mode\nResearched"
		anchor_btn.disabled = true
	elif rm.is_in_progress() and rm.current_id == &"anchor_mode":
		anchor_btn.text = "Anchor Mode\n%d%%" % int(rm.get_progress() * 100.0)
		anchor_btn.disabled = true
	else:
		anchor_btn.text = "[E] Anchor Mode"
		anchor_btn.tooltip_text = (
			"Crawlers gain a stationary Anchor command.\n"
			+ "Anchored: +50% armor, +25% workers, +25% range.\n"
			+ "5s deploy / 5s undeploy (vulnerable during).\n\n"
			+ "Upgrade cost:" + cost_suffix
		)
		anchor_btn.pressed.connect(_on_research_anchor)
		_attach_research_cost_widget(anchor_btn)
	row.add_child(anchor_btn)
	return row


func _attach_research_cost_widget(btn: Button) -> void:
	## Mirrors _attach_cost_widget but for research / branch commits —
	## shows a microchips chip + a fuel chip + a salvage chip at the
	## bottom of the button so the player sees the cost without
	## hovering for the tooltip.
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hbox.add_theme_constant_override("separation", 6)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.offset_top = -16
	hbox.offset_bottom = -3
	btn.add_child(hbox)
	_add_cost_chip(hbox, BranchCommitManager.COMMIT_COST_MICROCHIPS, RES_COLOR_MICROCHIPS)
	_add_cost_chip(hbox, BranchCommitManager.COMMIT_COST_FUEL, RES_COLOR_FUEL)
	_add_cost_chip(hbox, BranchCommitManager.COMMIT_COST_SALVAGE, RES_COLOR_SALVAGE)


func _on_research_anchor() -> void:
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	if not rm or rm.is_researched(&"anchor_mode") or rm.is_in_progress():
		return
	if not _resource_manager:
		return
	if not _resource_manager.spend_full(
		BranchCommitManager.COMMIT_COST_SALVAGE,
		BranchCommitManager.COMMIT_COST_FUEL,
		BranchCommitManager.COMMIT_COST_MICROCHIPS,
	):
		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_error"):
			audio.play_error()
		return
	rm.start_research(&"anchor_mode", "Anchor Mode", 50.0)
	# Force a panel rebuild so the button immediately reflects "in progress".
	_last_building_id = -1


func _on_branch_commit(base_stats: UnitStatResource, branch_stats: UnitStatResource, branch_name: String) -> void:
	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if not bcm or not bcm.has_method("start_commit"):
		return
	if not _resource_manager:
		return
	# Pay first, commit second — start_commit refuses if a commit is
	# already in progress, so spending up-front would leak resources.
	# Validate, then spend, then start.
	if bcm.is_committing() or bcm.has_committed(base_stats.unit_name):
		return
	if not _resource_manager.spend_full(
		BranchCommitManager.COMMIT_COST_SALVAGE,
		BranchCommitManager.COMMIT_COST_FUEL,
		BranchCommitManager.COMMIT_COST_MICROCHIPS,
	):
		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_error"):
			audio.play_error()
		return
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

func _update_unit_panel(units: Array[Node3D]) -> void:
	# Filter out freed units. Mixed Unit + Aircraft selection — both
	# share the duck-typed `alive_count` property.
	var valid_units: Array[Node3D] = []
	for unit: Node3D in units:
		if not is_instance_valid(unit):
			continue
		var alive: int = (unit.get("alive_count") as int) if "alive_count" in unit else 0
		if alive > 0:
			valid_units.append(unit)
	units = valid_units

	if units.is_empty():
		_bottom_panel.visible = false
		_hide_progress()
		return

	# Check if selection actually changed
	var current_ids: Array[int] = []
	for unit: Node3D in units:
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
		for unit: Node3D in units:
			if unit.get_builder():
				has_builder = true
				break

		if has_builder and not _showing_build_buttons:
			_showing_build_buttons = true
			# Default a freshly-opened build menu back to the Basic
			# tab. Otherwise a player who placed an Advanced building
			# (Advanced Foundry, Aerodrome, Black Pylon ...) and then
			# clicked their engineer again would land on the Advanced
			# tab — visually unhelpful and pushes the common build
			# choices off-screen behind the prereq-locked entries.
			_build_tab = "basic"
			_rebuild_build_buttons()
		elif not has_builder:
			_showing_build_buttons = false
			_clear_buttons()
			_rebuild_unit_command_buttons()

	# When the build menu is showing, rebuild it whenever the local
	# player's set of constructed buildings changes — so a freshly-
	# completed Basic Foundry unlocks the Advanced Foundry button on
	# the same frame the construction finishes, without needing a
	# selection change to trigger the redraw.
	if _showing_build_buttons:
		var prereq_hash: int = _compute_built_ids_hash()
		if prereq_hash != _build_prereq_hash:
			_build_prereq_hash = prereq_hash
			_rebuild_build_buttons()

	# Update text every frame
	_queue_label.text = ""
	_hide_progress()

	if units.size() == 1:
		var unit: Node3D = units[0]
		if unit.stats:
			_name_label.text = "%s — %s" % [unit.stats.unit_name, _role_hint_for(unit.stats)]
			var hp_pct: float = float(unit.get_total_hp()) / float(maxi(unit.stats.hp_total, 1))
			_stats_label.text = _build_unit_stat_sheet(unit, true)
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
		for unit: Node3D in units:
			var uname: String = unit.stats.unit_name if unit.stats else "Unknown"
			if counts.has(uname):
				counts[uname] += 1
			else:
				counts[uname] = 1

		var parts: PackedStringArray = PackedStringArray()
		for uname: String in counts:
			parts.append("%d %s" % [counts[uname], uname])
		_name_label.text = "%d units selected" % units.size()
		_stats_label.text = _build_stat_sheet([
			[_stat_chip("Roster", "  •  ".join(parts), STAT_LABEL_COLOR_SQUAD)],
		])


func _rebuild_build_buttons() -> void:
	_clear_buttons()
	if not _selection_manager:
		return

	# Tab row lives ABOVE the grid, not inside it. Lazily created
	# once + reused so the grid only contains the actual build
	# buttons (uniform-sized cells, no shift when tab swaps).
	_ensure_build_tab_row()
	if _build_tab_row:
		_build_tab_row.visible = true
		if _build_tab_basic:
			_build_tab_basic.button_pressed = _build_tab == "basic"
		if _build_tab_advanced:
			_build_tab_advanced.button_pressed = _build_tab == "advanced"

	_action_label.text = "Build — %s" % _build_tab.capitalize()
	var built_ids: Dictionary = _local_player_built_ids()
	var buildable: Array[BuildingStatResource] = _selection_manager.get_buildable_stats()
	var visible_index: int = 0
	for i: int in buildable.size():
		var bstat: BuildingStatResource = buildable[i]
		var is_advanced: bool = bstat.is_advanced
		var tab_match: bool = (is_advanced and _build_tab == "advanced") or (not is_advanced and _build_tab == "basic")
		if not tab_match:
			continue
		var prereqs_ok: bool = _prerequisites_met(bstat, built_ids)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(108, 70)
		btn.size_flags_horizontal = Control.SIZE_FILL
		btn.size_flags_vertical = Control.SIZE_FILL
		var prefix: String = "[%d]" % (visible_index + 1) if prereqs_ok else "[Locked]"
		_set_label_button(btn, prefix, bstat.building_name)
		btn.tooltip_text = _building_tooltip_with_prereq(bstat, prereqs_ok)
		btn.disabled = not prereqs_ok
		# Bind by stat reference, not visible index — visible_index only
		# matches `buildable[i]` while filters are stable, and we don't
		# want a hotkey collision to pick the wrong building.
		btn.pressed.connect(_on_build_button_for_stat.bind(bstat))
		_button_grid.add_child(btn)
		var chip_refs: Dictionary = _attach_cost_widget(btn, bstat.cost_salvage, 0, 0)
		_action_buttons.append({ "button": btn, "kind": "build", "stat": bstat, "locked": not prereqs_ok, "chips": chip_refs })
		visible_index += 1


func _ensure_build_tab_row() -> void:
	## Lazily creates the persistent tab row (Basic / Advanced) and
	## inserts it into ActionSection right above the button grid.
	## Created once; subsequent rebuilds just re-use it. Keeping the
	## tab row OUT of the grid means the grid's auto-flow layout
	## isn't perturbed when we swap tabs.
	if _build_tab_row and is_instance_valid(_build_tab_row):
		return
	var section: Node = _button_grid.get_parent() if _button_grid else null
	if not section:
		return
	var row := HBoxContainer.new()
	row.name = "BuildTabRow"
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	# Insert the row right BEFORE the grid in ActionSection so it
	# appears above the buttons. ActionSection is a VBoxContainer so
	# child order = visual top-to-bottom.
	section.add_child(row)
	section.move_child(row, _button_grid.get_index())
	_build_tab_row = row
	_build_tab_basic = Button.new()
	_build_tab_basic.text = "Basic"
	_build_tab_basic.custom_minimum_size = Vector2(72, 26)
	_build_tab_basic.toggle_mode = true
	_build_tab_basic.button_pressed = _build_tab == "basic"
	_build_tab_basic.pressed.connect(_on_build_tab_pressed.bind("basic"))
	row.add_child(_build_tab_basic)
	_build_tab_advanced = Button.new()
	_build_tab_advanced.text = "Advanced"
	_build_tab_advanced.custom_minimum_size = Vector2(86, 26)
	_build_tab_advanced.toggle_mode = true
	_build_tab_advanced.button_pressed = _build_tab == "advanced"
	_build_tab_advanced.pressed.connect(_on_build_tab_pressed.bind("advanced"))
	row.add_child(_build_tab_advanced)


func _on_build_tab_pressed(tab: String) -> void:
	if _build_tab == tab:
		return
	_build_tab = tab
	_rebuild_build_buttons()


func _on_build_button_for_stat(bstat: BuildingStatResource) -> void:
	if not _selection_manager or not bstat:
		return
	_selection_manager.start_build_placement(bstat)


func _on_build_button(index: int) -> void:
	if not _selection_manager:
		return
	var buildable: Array[BuildingStatResource] = _selection_manager.get_buildable_stats()
	if index < buildable.size():
		_selection_manager.start_build_placement(buildable[index])


func _compute_built_ids_hash() -> int:
	## Cheap hash that changes whenever the local player's set of
	## constructed-building IDs changes. Sums building_id hashes so a
	## new building flips the value but the game-loop doesn't need to
	## allocate a Dictionary every frame.
	var h: int = 0
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if "owner_id" in node and (node.get("owner_id") as int) != 0:
			continue
		if not node.get("is_constructed"):
			continue
		var bstat: BuildingStatResource = node.get("stats") as BuildingStatResource
		if bstat:
			h ^= hash(bstat.building_id)
	return h


func _local_player_built_ids() -> Dictionary:
	## Returns a Dictionary mapping `building_id` -> true for every
	## constructed building owned by the local player. Used by the
	## advanced-tab tab to gate buildings behind prerequisites.
	var ids: Dictionary = {}
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var owner_id: int = 0
		if "owner_id" in node:
			owner_id = node.get("owner_id") as int
		if owner_id != 0:
			continue
		if not node.get("is_constructed"):
			continue
		var bstat: BuildingStatResource = node.get("stats") as BuildingStatResource
		if bstat:
			ids[bstat.building_id] = true
	return ids


func _prerequisites_met(bstat: BuildingStatResource, built_ids: Dictionary) -> bool:
	if bstat.prerequisites.is_empty():
		return true
	for req_v: Variant in bstat.prerequisites:
		var req: StringName = StringName(req_v)
		if not built_ids.has(req):
			return false
	return true


func _building_tooltip_with_prereq(bstat: BuildingStatResource, prereqs_ok: bool) -> String:
	var base: String = _building_tooltip(bstat)
	if prereqs_ok or bstat.prerequisites.is_empty():
		return base
	var names: PackedStringArray = PackedStringArray()
	for req_v: Variant in bstat.prerequisites:
		names.append(_pretty_id(StringName(req_v)))
	return "%s\n\nRequires: %s" % [base, ", ".join(names)]


func _pretty_id(id: StringName) -> String:
	return str(id).replace("_", " ").capitalize()


func _clear_buttons() -> void:
	for child: Node in _button_grid.get_children():
		child.queue_free()
	_action_buttons.clear()
	# Reset column count to the standard 3 so panels other than the
	# Armory (which switches to columns=1 for its row layout) get
	# the original grid back. Without this, the next panel rebuild
	# would inherit the armory's single-column layout.
	if _button_grid:
		_button_grid.columns = 3
	# Hide the build tab row when leaving build mode (production /
	# armory / turret button rebuilds reach this same path).
	if _build_tab_row and is_instance_valid(_build_tab_row):
		_build_tab_row.visible = false


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
		# Per-resource shortfall flags so the cost chips can mark
		# which specific resource the player is missing.
		var lack_salvage: bool = false
		var lack_fuel: bool = false
		var lack_pop: bool = false
		if kind == "produce":
			var stat: UnitStatResource = entry["stat"] as UnitStatResource
			lack_salvage = _resource_manager.salvage < stat.cost_salvage
			lack_fuel = _resource_manager.fuel < stat.cost_fuel
			lack_pop = not _resource_manager.has_population(stat.population)
			affordable = not (lack_salvage or lack_fuel or lack_pop)
		elif kind == "build":
			var bstat: BuildingStatResource = entry["stat"] as BuildingStatResource
			lack_salvage = _resource_manager.salvage < bstat.cost_salvage
			affordable = not lack_salvage
			# Prereq-locked entries should stay disabled regardless of
			# whether the player has the salvage to pay for them.
			if entry.get("locked", false):
				affordable = false
		elif kind == "build_tab_row":
			# Tab row container — never tinted as un-affordable.
			continue
		elif kind == "ability":
			# Ability buttons aren't gated by resources; the cooldown
			# and label refresh happen here so the player sees the
			# countdown live.
			_refresh_ability_button(entry)
			continue
		btn.disabled = not affordable
		# Button itself uses the standard "disabled" style — same
		# regardless of WHICH resource is missing, so the unclickable
		# read is consistent. Per-resource tinting happens on the
		# cost chips below.
		btn.modulate = Color.WHITE if affordable else COLOR_AFFORD_BAD
		var chips: Dictionary = entry.get("chips", {}) as Dictionary
		# Defaults must stay as Dictionary, not null — `null as Dictionary`
		# raises an invalid-cast error rather than silently producing {}.
		_paint_cost_chip(chips.get("salvage", {}) as Dictionary, lack_salvage)
		_paint_cost_chip(chips.get("fuel", {}) as Dictionary, lack_fuel)
		_paint_cost_chip(chips.get("pop", {}) as Dictionary, lack_pop)


func _refresh_ability_button(entry: Dictionary) -> void:
	## Updates the ability button label and disabled state based on
	## the per-unit cooldowns of every cohort member. The label
	## reads "[D] Ready" when at least one unit can fire, and
	## "[D] %ds" when every cohort member is still cooling down
	## (showing the SHORTEST remaining cooldown so the player
	## knows when SOMEONE will be ready next).
	if not entry.has("button") or not entry.has("stat"):
		return
	var btn: Button = entry["button"] as Button
	var stat: UnitStatResource = entry["stat"] as UnitStatResource
	var units: Array = entry.get("units", []) as Array
	# Triple guard: button must exist, must be a live instance, AND
	# must still be in the scene tree. The third check catches the
	# brief window after queue_free where is_instance_valid still
	# returns true but property access on the freed Object errors.
	if not btn or not is_instance_valid(btn) or not btn.is_inside_tree() or not stat:
		return
	var any_ready: bool = false
	var min_cd: float = INF
	for unit_node: Node in units:
		if not is_instance_valid(unit_node):
			continue
		var u: Node = unit_node
		if u.has_method("ability_ready") and u.call("ability_ready"):
			any_ready = true
			break
		if u.has_method("ability_cooldown_remaining"):
			var cd: float = u.call("ability_cooldown_remaining") as float
			if cd < min_cd:
				min_cd = cd
	var hotkey: String = stat.ability_hotkey if stat.ability_hotkey != "" else "D"
	if any_ready:
		btn.disabled = false
		btn.text = "[%s] %s" % [hotkey, stat.ability_name]
		btn.modulate = Color.WHITE
	else:
		btn.disabled = true
		var cd_label: String = "%ds" % int(ceilf(min_cd)) if min_cd < INF else "—"
		btn.text = "[%s] %s\n%s" % [hotkey, stat.ability_name, cd_label]
		btn.modulate = Color(0.78, 0.78, 0.78)


func _paint_cost_chip(chip: Dictionary, lacking: bool) -> void:
	## Tints a single cost chip's swatch + label red when the player
	## is short on that resource. When the resource is fine, restores
	## the chip's stored neutral color. Safe to call with an empty
	## dict (does nothing).
	if chip.is_empty():
		return
	var swatch: ColorRect = chip.get("swatch", null) as ColorRect
	var lbl: Label = chip.get("label", null) as Label
	var base_color: Color = chip.get("color", Color.WHITE) as Color
	if not is_instance_valid(swatch) or not is_instance_valid(lbl):
		return
	var paint: Color = COLOR_AFFORD_BAD if lacking else base_color
	swatch.color = paint
	lbl.add_theme_color_override("font_color", paint)


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


func _compute_dps_vs(stat: UnitStatResource, armor_class: StringName) -> float:
	## Effective DPS at full squad strength against the given armor class.
	## Bakes in the role-vs-armor lookup so the displayed number actually
	## reflects what the unit will do — AAir vs ground reads 0, AP vs heavy
	## armor reads the reduced value, etc.
	if not stat:
		return 0.0
	var dps: float = 0.0
	var weapons: Array[WeaponResource] = []
	if stat.primary_weapon:
		weapons.append(stat.primary_weapon)
	if stat.secondary_weapon:
		weapons.append(stat.secondary_weapon)
	for weapon: WeaponResource in weapons:
		var raw: float = _weapon_dps(weapon) * float(stat.squad_size)
		var role_mod: float = CombatTables.get_role_modifier(weapon.role_tag, armor_class)
		var armor_red: float = CombatTables.get_armor_reduction(armor_class)
		dps += raw * role_mod * (1.0 - armor_red)
	return dps


func _effective_accuracy(unit: Node3D) -> float:
	## Mirrors CombatComponent._fire_weapon's hit-chance assembly so
	## the inspect panel shows the player what the weapon will
	## ACTUALLY do right now: base + squad-strength + Mesh + a
	## movement penalty if the squad is moving. Range penalty
	## requires an aim target so we don't include it; the inspect
	## reading assumes a medium-range, in-bound shot.
	if not unit or not ("stats" in unit) or not unit.stats:
		return 0.0
	var stats: UnitStatResource = unit.stats as UnitStatResource
	if not stats.primary_weapon:
		return 0.0
	var base: float = stats.primary_weapon.base_accuracy
	var bonus: float = 0.0
	# Squad-strength full-strength bonus.
	if stats.squad_strength_bonus > 0.0 and unit.has_method("get_squad_strength_ratio"):
		var ratio: float = unit.call("get_squad_strength_ratio") as float
		bonus += stats.squad_strength_bonus * ratio
	# Mesh bonus from the scene-level singleton.
	var mesh_sys: Node = get_tree().current_scene.get_node_or_null("MeshSystem") if get_tree() else null
	if mesh_sys and mesh_sys.has_method("strength_for") and mesh_sys.has_method("accuracy_bonus"):
		var owner_id: int = unit.get("owner_id") as int
		var strength: int = mesh_sys.call("strength_for", unit.global_position, owner_id) as int
		bonus += mesh_sys.call("accuracy_bonus", strength) as float
	# Movement penalty if currently moving.
	var is_moving: bool = false
	if "velocity" in unit:
		var v: Vector3 = unit.get("velocity") as Vector3
		is_moving = Vector2(v.x, v.z).length() > 0.5
	var penalty: float = -0.15 if is_moving else 0.0
	return clampf(base + bonus + penalty, 0.30, 0.99)


func _max_weapon_range(stat: UnitStatResource) -> float:
	## Returns the longer of the unit's primary / secondary weapon
	## ranges. Lets the player tell at a glance whether this is a
	## brawler (short) or a sniper (long) without opening the tooltip.
	if not stat:
		return 0.0
	var r: float = 0.0
	if stat.primary_weapon:
		r = maxf(r, CombatTables.get_range(stat.primary_weapon.range_tier))
	if stat.secondary_weapon:
		r = maxf(r, CombatTables.get_range(stat.secondary_weapon.range_tier))
	return r


func _speed_label(tier: StringName) -> String:
	## Maps the speed-tier StringName to a human-readable label so the
	## inspect panel reads "Fast" / "Slow" instead of "&\"slow\"".
	var s: String = String(tier).replace("_", " ")
	if s.is_empty():
		return "Speed —"
	return "Speed " + s.capitalize()


func _weapon_summary(stat: UnitStatResource) -> String:
	## Compact one-liner about the unit's weapon: primary role tag + a
	## marker for any secondary. Captures whether this is e.g. an
	## anti-air specialist or a universal brawler without spelling out
	## the full WeaponResource.
	if not stat:
		return ""
	if not stat.primary_weapon:
		return "Unarmed"
	var role: String = String(stat.primary_weapon.role_tag)
	if stat.secondary_weapon:
		role += " + " + String(stat.secondary_weapon.role_tag)
	return "Wpn " + role


func _role_hint_for(stat: UnitStatResource) -> String:
	## One-word tactical role classifier so the unit name tells the
	## player WHAT the unit is for. Derived from the primary weapon's
	## role tag and the unit class — leans toward what the player
	## should send this unit to fight, not what it technically is.
	if not stat:
		return "Unit"
	var cls: String = String(stat.unit_class)
	if cls == "engineer":
		return "Engineer / Builder"
	var role: StringName = &"Universal"
	if stat.primary_weapon:
		role = stat.primary_weapon.role_tag
	match role:
		&"AAir":
			return "Anti-Air Specialist"
		&"AA":
			return "Anti-Armor"
		&"AP":
			if cls == "heavy":
				return "Heavy Brawler"
			return "Anti-Light"
		&"AS":
			return "Siege / Anti-Structure"
		_:
			if cls == "light":
				return "Scout / Skirmisher"
			if cls == "heavy":
				return "Heavy Line"
			return "Frontline"


func _weapon_dps(weapon: WeaponResource) -> float:
	if not weapon:
		return 0.0
	var dmg: float = float(CombatTables.get_damage(weapon.damage_tier))
	var rof: float = CombatTables.get_rof(weapon.rof_tier)
	if rof <= 0.0:
		return 0.0
	# Salvo weapons fire salvo_count projectiles per cooldown,
	# each dealing the weapon's damage independently. The displayed
	# DPS has to mirror that multiplier or the Hammerhead's
	# six-tube missile pod under-reads at 1/6 of its real output.
	var salvo: int = maxi(int(weapon.salvo_count), 1)
	return (dmg * float(salvo)) / rof


func _unit_tooltip(stat: UnitStatResource) -> String:
	if not stat:
		return ""
	var lines: PackedStringArray = PackedStringArray()
	# Header: name + tactical role hint so the player can read what
	# this unit is FOR before parsing the numbers.
	lines.append("%s — %s" % [stat.unit_name, _role_hint_for(stat)])
	lines.append("Class: %s    Armor: %s    %s" % [
		str(stat.unit_class).capitalize(),
		str(stat.armor_class).capitalize(),
		_speed_label(stat.speed_tier),
	])
	lines.append("HP %d   Squad %d   Pop %d   Range %.0fu" % [
		stat.hp_total, stat.squad_size, stat.population,
		_max_weapon_range(stat),
	])
	lines.append("Cost  %dS / %dF   Build %.1fs" % [
		stat.cost_salvage, stat.cost_fuel, stat.build_time
	])
	lines.append("DPS  %.0f vs Ground / %.0f vs Air" % [
		_compute_dps_vs(stat, &"medium"),
		_compute_dps_vs(stat, &"light_air"),
	])
	if stat.primary_weapon:
		lines.append("Primary: %s — %s, %s, %s, Acc %d%%" % [
			stat.primary_weapon.weapon_name if stat.primary_weapon.weapon_name else "Cannon",
			str(stat.primary_weapon.role_tag),
			str(stat.primary_weapon.range_tier),
			str(stat.primary_weapon.damage_tier),
			int(stat.primary_weapon.base_accuracy * 100.0),
		])
	if stat.secondary_weapon:
		lines.append("Secondary: %s — %s, Acc %d%%" % [
			stat.secondary_weapon.weapon_name if stat.secondary_weapon.weapon_name else "Backup",
			str(stat.secondary_weapon.role_tag),
			int(stat.secondary_weapon.base_accuracy * 100.0),
		])
	if stat.squad_strength_bonus > 0.0:
		lines.append("Full-strength accuracy bonus: +%d%%" % int(stat.squad_strength_bonus * 100.0))
	if stat.special_description != "":
		lines.append("")
		lines.append(stat.special_description)
	return "\n".join(lines)


func _building_tooltip(stat: BuildingStatResource) -> String:
	if not stat:
		return ""
	var lines: PackedStringArray = PackedStringArray()
	# Header: name + a one-line role hint so the player knows WHAT the
	# building is FOR before parsing the cost numbers.
	lines.append("%s — %s" % [stat.building_name, _building_role_hint(stat)])
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
	# Long-form description — strategic context the player needs to
	# decide WHEN to build this. Sourced from a per-building lookup
	# rather than the .tres so we can iterate copy without touching
	# resource files.
	var blurb: String = _building_description(stat.building_id)
	if not blurb.is_empty():
		lines.append("")
		lines.append(blurb)
	return "\n".join(lines)


func _building_role_hint(stat: BuildingStatResource) -> String:
	## One-line role summary so the player can identify what the
	## building does at a glance. Maps building_id to a short label.
	match stat.building_id:
		&"headquarters": return "Command Center"
		&"basic_foundry": return "Mech Production"
		&"advanced_foundry": return "Heavy Mech Production"
		&"basic_generator": return "Power Source"
		&"basic_armory": return "Tech Upgrades"
		&"salvage_yard": return "Static Salvage Harvester"
		&"gun_emplacement": return "Defensive Turret"
		&"aerodrome": return "Aircraft Production"
		&"sam_site": return "Anti-Air Defense"
	return "Structure"


func _building_description(id: StringName) -> String:
	## Strategic blurb for each building. Tells the player when to
	## build it, what it competes against, and any caveats.
	match id:
		&"headquarters":
			return "Your command center. Trains engineers, holds rally point. Losing it is a loss condition."
		&"basic_foundry":
			return "Trains light + medium ground mechs. You'll want at least one early; multiple foundries let you produce in parallel."
		&"advanced_foundry":
			return "Unlocks heavy ground units (Bulwark / Harbinger). Requires a basic foundry."
		&"basic_generator":
			return "Provides power. Power-starved buildings produce more slowly, so build a generator before stacking foundries."
		&"basic_armory":
			return "Hosts branch upgrades for your existing unit lines. Branch commits are irreversible."
		&"salvage_yard":
			return "Stationary harvester with a fixed work radius. Crawlers go further but are slower; yards are best on dense scrap fields."
		&"gun_emplacement":
			return "Manned turret. Choose a profile (anti-light / anti-heavy / anti-air / balanced) after construction."
		&"aerodrome":
			return "Trains aircraft (Phalanx Drone, Hammerhead Gunship). Aircraft only fall to AAir-tagged weapons or SAM Sites."
		&"sam_site":
			return "Anti-air missile rack. Heavy damage vs aircraft, near-zero vs ground. Pair with turrets to cover both axes."
	return ""
