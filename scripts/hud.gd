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

## HQ panel tab state: "train" shows engineer + crawler production;
## "defense" shows the Anvil-only HQ Plating + HQ Battery upgrades.
## Lives in its own tab row so the upgrades don't pile into the
## "Train Units" grid.
var _hq_tab: String = "train"
var _hq_tab_row: HBoxContainer = null
var _hq_tab_train: Button = null
var _hq_tab_defense: Button = null

## Track what we're showing to avoid rebuilding buttons every frame.
var _last_building_id: int = -1
var _last_unit_ids: Array[int] = []
var _showing_build_buttons: bool = false

## Pool of buttons + cached metadata so we can update affordability tint each frame.
## Each entry: { button: Button, kind: "produce"|"build", index: int }
var _action_buttons: Array[Dictionary] = []
## Build buttons currently visible in the action grid (basic OR
## advanced tab, after prereq filtering). Indexed in display order
## so SelectionManager's engineer-build hotkey can pick the stat
## the player actually sees under each Q/W/E/R/T key.
var _visible_build_stats: Array[BuildingStatResource] = []


func get_visible_build_stat_at(index: int) -> BuildingStatResource:
	## Returns the i-th currently-visible build stat (0-indexed) or
	## null if the index is out of range / no build menu showing.
	if index < 0 or index >= _visible_build_stats.size():
		return null
	return _visible_build_stats[index]

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
## Trailing percent label sitting next to the main Power readout.
## Always visible, colored independently of `_power_label` so the
## name + value stay neutral while just the % number swings between
## comfortable green and deficit red. Built lazily by
## `_build_power_widget` and animated red-pulse via the per-frame
## `_update_top_bar` tick.
var _power_pct_label: Label = null
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
const COLOR_SALVAGE := Color(1.00, 0.55, 0.18, 1.0)   # warm orange — distinct from power yellow
const COLOR_FUEL := Color(0.4, 0.85, 1.0, 1.0)        # cyan
const COLOR_MICROCHIPS := Color(0.85, 0.55, 1.0, 1.0) # violet — distinct from gold/cyan
const COLOR_POWER := Color(1.00, 0.95, 0.20, 1.0)      # bright yellow — distinct from salvage orange
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
	# Stat sheet now compresses to ~4 rows since the bottom-row armor
	# chip merged into the top defense row -- give the rows a few
	# extra pixels of breathing room so the panel doesn't feel cramped.
	if _stats_label:
		_stats_label.add_theme_constant_override("line_separation", 5)
	_build_progress_bar()
	_build_pause_overlay()
	_build_power_widget()
	_build_alert_banner()
	_build_chat_input()
	_build_minimap_quick_select()
	# Gift-allies panel — hide in tutorial since the lone Sable
	# strike force the mission spawns isn't a real player slot
	# the human can transfer resources to. Rest of the modes
	# keep the panel.
	var settings_for_gift: Node = get_node_or_null("/root/MatchSettings")
	if not (settings_for_gift and settings_for_gift.get("tutorial_mode")):
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
	# objective + dialogue from the TutorialMission node every frame.
	# The legacy 7-task checklist overlay was retired in favour of the
	# mission banner — checklist was both visually noisy at start and
	# referenced overlays that could leak across scene reloads, which
	# crashed _check_tutorial_progress when it tried to update freed
	# label instances.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.get("tutorial_mode"):
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
var _tutorial_banner_objective_panel: PanelContainer = null
var _tutorial_banner_progress: Label = null
var _tutorial_banner_last_index: int = -2  # never matches a real stage
var _tutorial_banner_dialogue_tween: Tween = null
var _tutorial_banner_objective_tween: Tween = null
## Pause between dialogue finishing and the objective panel
## fading in. Tuned so the player gets a beat to read the line
## before the call-to-action lands.
const TUTORIAL_OBJECTIVE_DELAY_SEC: float = 2.0
const TUTORIAL_OBJECTIVE_FADE_SEC: float = 0.45


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
	## Two stacked panels at the top of the screen:
	##   - Dialogue panel  — story line, left-aligned so the
	##     letter-by-letter typewriter doesn't cause the text to
	##     re-centre on every character (causing the perceived
	##     wobble / nausea the player called out).
	##   - Objective panel — the actionable task. Hidden while
	##     dialogue is still typing + 2s afterwards, then fades
	##     in. Visually distinct (green border, slightly smaller
	##     panel) so it reads as a HUD banner rather than another
	##     story line.
	# Narrower + left-anchored so the dialogue + objective panels
	# sit in a compact column on the left of the HUD instead of
	# stretching across the screen. Player feedback: the wide
	# centred boxes felt overwhelming + competed with the
	# minimap for visual weight.
	_tutorial_banner_panel = PanelContainer.new()
	_tutorial_banner_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_tutorial_banner_panel.offset_left = 18
	_tutorial_banner_panel.offset_right = 460
	_tutorial_banner_panel.offset_top = 42
	_tutorial_banner_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_tutorial_banner_panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 2)
	_tutorial_banner_panel.add_child(inner)
	_tutorial_banner_progress = Label.new()
	_tutorial_banner_progress.text = ""
	_tutorial_banner_progress.add_theme_font_size_override("font_size", 12)
	_tutorial_banner_progress.add_theme_color_override("font_color", Color(0.78, 0.85, 0.95, 0.85))
	_tutorial_banner_progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	inner.add_child(_tutorial_banner_progress)
	_tutorial_banner_dialogue = Label.new()
	_tutorial_banner_dialogue.text = ""
	_tutorial_banner_dialogue.add_theme_font_size_override("font_size", 16)
	_tutorial_banner_dialogue.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78, 1.0))
	_tutorial_banner_dialogue.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# LEFT-anchored so each typed letter pushes the line outward
	# from the left edge instead of resampling the centre point
	# every frame (which made the text appear to slide).
	_tutorial_banner_dialogue.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	inner.add_child(_tutorial_banner_dialogue)

	# Objective — its own PanelContainer so the visual frame is
	# distinct, anchored just below the dialogue panel on the
	# same left column. Tighter width than the dialogue (340 vs
	# the dialogue's ~440) so the call-to-action reads as a
	# focused HUD chip rather than a second narrative banner.
	# Pushed offset_top down to 240 so the longest dialogue
	# (Riven Yul's ~5-line "drop the targeting solution" speech)
	# can fully expand without overlapping the objective panel.
	_tutorial_banner_objective_panel = PanelContainer.new()
	_tutorial_banner_objective_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_tutorial_banner_objective_panel.offset_left = 18
	_tutorial_banner_objective_panel.offset_right = 358
	_tutorial_banner_objective_panel.offset_top = 240
	_tutorial_banner_objective_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_tutorial_banner_objective_panel.modulate.a = 0.0
	# Green-tinted stylebox so the panel reads as objective /
	# call-to-action rather than another dialogue line.
	var obj_style := StyleBoxFlat.new()
	obj_style.bg_color = Color(0.05, 0.16, 0.10, 0.92)
	obj_style.border_color = Color(0.45, 0.95, 0.55, 0.8)
	obj_style.set_border_width_all(2)
	obj_style.set_corner_radius_all(4)
	obj_style.content_margin_left = 10
	obj_style.content_margin_right = 10
	obj_style.content_margin_top = 6
	obj_style.content_margin_bottom = 6
	_tutorial_banner_objective_panel.add_theme_stylebox_override("panel", obj_style)
	add_child(_tutorial_banner_objective_panel)
	_tutorial_banner_objective = Label.new()
	_tutorial_banner_objective.text = ""
	_tutorial_banner_objective.add_theme_font_size_override("font_size", 15)
	_tutorial_banner_objective.add_theme_color_override("font_color", Color(0.78, 1.0, 0.82, 1.0))
	_tutorial_banner_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_banner_objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_tutorial_banner_objective_panel.add_child(_tutorial_banner_objective)


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
	_tutorial_banner_objective.text = objective
	_tutorial_banner_progress.text = "Stage %d / %d" % [idx + 1, total]
	# Typewriter dialogue — drop the full text in but clamp
	# visible_characters to 0 and tween it up to the full length
	# over a duration proportional to the line length (~32 chars
	# per second). Reads as someone speaking the line rather than
	# a wall of text appearing all at once. Kill the previous
	# tween if a stage flips before the last one finishes so we
	# don't get two animations stacked on the same Label.
	_tutorial_banner_dialogue.text = dialogue
	_tutorial_banner_dialogue.visible_characters = 0
	if _tutorial_banner_dialogue_tween and _tutorial_banner_dialogue_tween.is_valid():
		_tutorial_banner_dialogue_tween.kill()
	var char_count: int = dialogue.length()
	var dialogue_dur: float = 0.0
	if char_count > 0:
		dialogue_dur = clampf(float(char_count) / 32.0, 0.6, 4.0)
		_tutorial_banner_dialogue_tween = create_tween()
		_tutorial_banner_dialogue_tween.tween_property(
			_tutorial_banner_dialogue,
			"visible_characters",
			char_count,
			dialogue_dur,
		)
	# Objective panel — start hidden, fade in after the dialogue
	# finishes typing + a 2s breathing pause. Kill any previous
	# objective tween so back-to-back stage flips don't stack
	# fade chains on the same panel.
	if _tutorial_banner_objective_tween and _tutorial_banner_objective_tween.is_valid():
		_tutorial_banner_objective_tween.kill()
	if _tutorial_banner_objective_panel:
		_tutorial_banner_objective_panel.modulate.a = 0.0
		_tutorial_banner_objective_tween = create_tween()
		_tutorial_banner_objective_tween.tween_interval(dialogue_dur + TUTORIAL_OBJECTIVE_DELAY_SEC)
		_tutorial_banner_objective_tween.tween_property(
			_tutorial_banner_objective_panel,
			"modulate:a",
			1.0,
			TUTORIAL_OBJECTIVE_FADE_SEC,
		)


func _check_tutorial_progress() -> void:
	## Called from _process while the overlay is visible. Polls game state
	## and ticks off completed tasks.
	if not has_meta("tutorial_overlay"):
		return
	# Pull through Variant first — assigning a freed Object straight
	# into a typed `var x: Node` slot triggers Godot 4's
	# "Trying to assign invalid previously freed instance" error.
	# Variant tolerates the freed reference long enough for the
	# is_instance_valid check.
	var overlay_v: Variant = get_meta("tutorial_overlay")
	if not (overlay_v is Object) or not is_instance_valid(overlay_v):
		remove_meta("tutorial_overlay")
		return
	var overlay: Node = overlay_v as Node
	if not overlay:
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

	# Move the existing label into the column. Wrap it in an HBox
	# so a sibling percent label can sit immediately to its right
	# without disturbing the existing layout / column placement.
	top_bar.remove_child(_power_label)
	var label_row := HBoxContainer.new()
	label_row.add_theme_constant_override("separation", 6)
	label_row.add_child(_power_label)
	_power_pct_label = Label.new()
	_power_pct_label.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55, 1.0))
	label_row.add_child(_power_pct_label)
	col.add_child(label_row)

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
		# Suppress global hotkeys (M overlay, Tab palette, etc.) while
		# the chat / cheat input is focused -- typing 'mesh' shouldn't
		# also flick the Mesh overlay on. Escape stays live so it can
		# still cancel the chat (handled by _input above).
		if _is_chat_focused() and key.keycode != KEY_ESCAPE:
			return
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

	# Extended-stats default toggle. When checked, unit/building info
	# panels show the full stat breakdown by default and SHIFT
	# collapses back to the basic view. When unchecked (the default)
	# basic is the default and SHIFT expands. Lives in the pause
	# panel because the player only sees its effect once they're
	# in-match looking at unit info.
	var ext_row := HBoxContainer.new()
	ext_row.add_theme_constant_override("separation", 8)
	ext_row.process_mode = Node.PROCESS_MODE_ALWAYS
	vbox.add_child(ext_row)
	var ext_check := CheckBox.new()
	ext_check.text = "Show extended stats by default"
	ext_check.button_pressed = _extended_stats_default
	ext_check.process_mode = Node.PROCESS_MODE_ALWAYS
	ext_check.toggled.connect(_on_extended_stats_toggled)
	ext_row.add_child(ext_check)

	# Spacer + Restart + Return-to-menu buttons. Restart is the more
	# common 'I want to redo this' affordance (mistake first 30 sec,
	# wrong faction pick, lost the opening); Main Menu is the harder
	# bail-out. Restart drops above so it's the visually default
	# action.
	var menu_spacer := Control.new()
	menu_spacer.custom_minimum_size = Vector2(0, 14)
	vbox.add_child(menu_spacer)

	var restart_btn := Button.new()
	restart_btn.text = "Restart Match"
	restart_btn.custom_minimum_size = Vector2(220, 36)
	restart_btn.process_mode = Node.PROCESS_MODE_ALWAYS
	restart_btn.pressed.connect(_on_pause_restart)
	vbox.add_child(restart_btn)

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


func _on_extended_stats_toggled(pressed: bool) -> void:
	## Persists the player's preference for the basic vs extended
	## stat sheet default. _extended_stats_active() reads from the
	## flag plus the live SHIFT key state so the toggle takes effect
	## on the next panel refresh.
	_extended_stats_default = pressed


func _on_pause_restart() -> void:
	## Reload the current scene so the player gets a fresh match with the
	## same MatchSettings (faction picks, difficulty, map). Mirrors the
	## post-match victory-panel Restart button.
	get_tree().paused = false
	get_tree().reload_current_scene()


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
	# Inserted into the info section under the queue label. The bar
	# stays in the layout permanently (always visible = true) so
	# toggling between idle and 'training' doesn't shift the unit
	# action buttons up + down. When idle, modulate.a drops to 0 so
	# the bar reads as 'no slot in flight' without yanking the
	# layout. Bar height bumped 4 -> 8 for readability.
	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(120, 8)
	_progress_bar.size_flags_horizontal = Control.SIZE_FILL
	_progress_bar.show_percentage = false
	_progress_bar.modulate.a = 0.0
	if _info_section:
		_info_section.add_child(_progress_bar)


## --- Resource bar ---

## Resource display throttle (msec). Resource counters tick at
## game-second timescales -- 60Hz updates were re-allocating the
## label format strings + walking add_theme_color_override every
## frame for values that hadn't changed. ~10Hz is faster than the
## eye can read.
const _RESOURCE_REFRESH_MS: int = 100
var _resource_refresh_at_msec: int = 0


func _update_resource_display() -> void:
	if not _resource_manager:
		return
	var now_msec: int = Time.get_ticks_msec()
	if now_msec < _resource_refresh_at_msec:
		return
	_resource_refresh_at_msec = now_msec + _RESOURCE_REFRESH_MS
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

	# Power — bar shows consumption-vs-production load. The label
	# itself stays the neutral COLOR_POWER tint always; only the
	# trailing percent number swings between green (comfortable)
	# and red (insufficient). The percent number pulses while in
	# deficit so the UI nags the player without changing the main
	# label colour.
	var produced: int = _resource_manager.power_production
	var consumed: int = _resource_manager.power_consumption
	var has_deficit: bool = consumed > produced
	var efficiency: float = _resource_manager.get_power_efficiency()
	_power_label.text = "Power  %d / %d" % [produced, consumed]
	_power_label.add_theme_color_override("font_color", COLOR_POWER)
	if _power_pct_label:
		var pct: int = int(round(efficiency * 100.0))
		_power_pct_label.text = "(%d%%)" % pct
		# Greenish when comfortable, red when in deficit. Distinct
		# green from the population pop-cap green so the player can
		# tell the two stats apart at a glance.
		var ok_color: Color = Color(0.55, 0.95, 0.55, 1.0)
		var bad_color: Color = Color(1.00, 0.30, 0.25, 1.0)
		if has_deficit:
			_power_pct_label.add_theme_color_override("font_color", bad_color)
			# Sin-driven pulse on alpha so the deficit number
			# breathes ~1.4 Hz; alpha clamp keeps it readable
			# even at the trough.
			var t: float = float(Time.get_ticks_msec()) / 1000.0
			var a: float = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 8.8))
			_power_pct_label.modulate.a = a
		else:
			_power_pct_label.add_theme_color_override("font_color", ok_color)
			_power_pct_label.modulate.a = 1.0

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

	# Wreck branch -- wrecks have no `stats` resource and no
	# `owner_id`; they expose `salvage_remaining` (+ optional
	# `microchip_remaining` for satellite piles). Show a small
	# read-only panel with the resource counts so the player can
	# decide whether the pile is worth a Crawler trip.
	if target is Wreck:
		var w: Wreck = target as Wreck
		var w_label: String = "Satellite Pile" if w.is_satellite else "Wreck"
		_name_label.text = w_label
		var rows: Array = []
		rows.append([_stat_chip("Salvage", "%d / %d" % [w.salvage_remaining, w.salvage_value], STAT_LABEL_COLOR_COST_S)])
		if w.microchip_value > 0:
			rows.append([_stat_chip("Chips", "%d / %d" % [w.microchip_remaining, w.microchip_value], STAT_LABEL_COLOR_COST_M)])
		_stats_label.text = _build_stat_sheet(rows)
		var w_pct: float = float(w.salvage_remaining) / float(maxi(w.salvage_value, 1))
		_show_progress(w_pct, Color(1.00, 0.55, 0.18, 0.95))
		return

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
		# Prefer the building's effective_max_hp() when available so the
		# bar tracks per-instance HP buffs (Anvil HQ Plating, etc).
		var bhp_max: int = bstats.hp
		if target.has_method("effective_max_hp"):
			bhp_max = target.call("effective_max_hp") as int
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
		_name_label.text = "%s (%s)" % [stats.get_display_name(), owner_label]
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
	var is_armory: bool = (
		building.stats.building_id == &"basic_armory"
		or building.stats.building_id == &"advanced_armory"
	)
	var armory_in_progress: bool = is_armory and rm and rm.is_in_progress()
	# Buildings that produce units take priority over the turret-
	# profile panel even when they carry a TurretComponent (the HQ
	# now mounts a built-in defensive turret but its primary action
	# is still training Engineers + Crawlers). Pure defenses (gun
	# emplacement, SAM Site) have no producible_units list and fall
	# through to the turret panel.
	var has_production: bool = (
		building.stats != null
		and not (building.get_producible_units() if building.has_method("get_producible_units") else []).is_empty()
	)
	if bid != _last_building_id or armory_in_progress:
		_last_building_id = bid
		_last_unit_ids.clear()
		_showing_build_buttons = false
		if is_armory:
			_rebuild_armory_buttons(building)
		elif has_production:
			_rebuild_production_buttons(building)
		elif building.has_node("TurretComponent"):
			_rebuild_turret_profile_buttons(building)
		else:
			_rebuild_production_buttons(building)
	elif building.has_node("TurretComponent") and not has_production:
		# Re-tint each frame so the active profile stays highlighted even
		# without a selection-change rebuild. Skip when the panel is
		# rendering production -- highlight ticking would walk an empty
		# turret-profile button list.
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
	elif building.stats.building_id == &"basic_armory" or building.stats.building_id == &"advanced_armory":
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
	# Bar stays in the layout always; modulate is what swings between
	# 'visible' and 'hidden' so the surrounding buttons don't shift.
	# We also have to flip `visible` back on -- the deselect path
	# (no selection) hides the bar via .visible = false, and a later
	# alpha bump alone wouldn't bring it back.
	_progress_bar.visible = true
	_progress_bar.modulate.a = 1.0
	_progress_bar.value = clampf(pct, 0.0, 1.0) * 100.0
	# Override fill color per call so the bar matches the task (build vs commit vs spawn).
	var fill_sb: StyleBoxFlat = _progress_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill_sb:
		var local_fill: StyleBoxFlat = fill_sb.duplicate() as StyleBoxFlat
		local_fill.bg_color = fill_color
		_progress_bar.add_theme_stylebox_override("fill", local_fill)


func _hide_progress() -> void:
	if _progress_bar:
		# Drop alpha to 0 instead of toggling visibility so the
		# layout slot stays reserved -- otherwise the unit action
		# buttons jump up the moment training finishes.
		_progress_bar.modulate.a = 0.0
		_progress_bar.value = 0.0
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
		var display: String = unit_stat.get_display_name()
		if display.length() > 0:
			label = display.substr(0, 1)
		# In-progress slot gets a "·" prefix so the player can see which
		# one is mid-build vs queued.
		if i == 0:
			label = "•%s" % label
		btn.text = label
		var cost_text: String = "%dS" % unit_stat.cost_salvage
		if unit_stat.cost_fuel > 0:
			cost_text += " %dF" % unit_stat.cost_fuel
		btn.tooltip_text = "%s (%s)\nClick to cancel and refund." % [
			unit_stat.get_display_name(), cost_text,
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

	# Active-ability buttons — one slot per distinct ability type
	# in the current selection (capped to ABILITY_BUTTON_LIMIT so a
	# mixed mass-select doesn't paper over the move-command row).
	# Used to require every selected unit to share the same ability;
	# a mixed Pulsefont + Forgemaster selection then showed nothing.
	# The new behaviour mirrors classic RTS HUDs: each ability the
	# selection contains gets its own slot, pressing it fires the
	# ability on the subset of units that own it. Tinted violet to
	# distinguish from the grey command buttons.
	var ability_groups: Array[Dictionary] = _selection_ability_groups()
	for group: Dictionary in ability_groups:
		var ability_units: Array[Node3D] = group["units"] as Array[Node3D]
		var ability_stat: UnitStatResource = group["stat"] as UnitStatResource
		var ability_btn := Button.new()
		ability_btn.custom_minimum_size = Vector2(150, 42)
		var unit_count_label: String = ""
		if ability_units.size() > 1:
			unit_count_label = "  ×%d" % ability_units.size()
		ability_btn.tooltip_text = "%s%s\n%s\nCooldown %ds" % [
			ability_stat.ability_name,
			unit_count_label,
			ability_stat.ability_description,
			int(ability_stat.ability_cooldown),
		]
		_paint_ability_button_style(ability_btn)
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

	# Passive-identity placeholder buttons. Units that lack an
	# active ability but carry a meaningful passive (Spotter
	# detection, Tracker sight aura, Specter stealth, etc.) get a
	# disabled "Passive" slot here so the bottom row visually
	# reads "this unit's special is on, just not clickable" instead
	# of an empty action panel for half the roster.
	var passive_groups: Array[Dictionary] = _selection_passive_groups()
	for group: Dictionary in passive_groups:
		var passive_units: Array[Node3D] = group["units"] as Array[Node3D]
		var passive_stat: UnitStatResource = group["stat"] as UnitStatResource
		var passive_btn := Button.new()
		passive_btn.custom_minimum_size = Vector2(150, 42)
		var pcount_label: String = ""
		if passive_units.size() > 1:
			pcount_label = "  ×%d" % passive_units.size()
		passive_btn.text = "Passive%s" % pcount_label
		passive_btn.tooltip_text = passive_stat.passive_description
		passive_btn.disabled = true
		_paint_passive_button_style(passive_btn)
		_button_grid.add_child(passive_btn)
		_action_buttons.append({
			"button": passive_btn,
			"kind": "passive",
			"units": passive_units,
			"stat": passive_stat,
		})


## Bottom-row capacity for ability slots. The command row already
## fills three slots (Hold / Patrol / Attack-Move); leaving three
## free below for ability buttons matches the "standard commands
## top, special actions bottom" layout the user asked for. Selections
## that mix more than three distinct abilities clip to the most
## populous three.
const ABILITY_BUTTON_LIMIT: int = 3


func _selection_ability_groups() -> Array[Dictionary]:
	## Buckets the current selection by ability_name and returns
	## one entry per distinct ability:
	##   { units: Array[Node3D], stat: UnitStatResource }
	## Stats taken from the first unit in each bucket -- ability
	## metadata (name, description, cooldown, autocast) is per-unit-
	## class-shared so the first unit's stat block is representative.
	## Buckets sorted descending by unit count, then clipped to
	## ABILITY_BUTTON_LIMIT so the bottom row stays uncluttered.
	var out: Array[Dictionary] = []
	if not _selection_manager:
		return out
	var selected: Array[Node3D] = _selection_manager.get_selected_units() as Array[Node3D]
	if selected.is_empty():
		return out
	# Bucket by ability_name -> { units: [...], stat: ... }.
	var buckets: Dictionary = {}
	var bucket_order: Array[String] = []
	for unit: Node3D in selected:
		if not is_instance_valid(unit) or not "stats" in unit:
			continue
		var s: UnitStatResource = unit.get("stats") as UnitStatResource
		if not s or s.ability_name == "":
			continue
		var key: String = s.ability_name
		if not buckets.has(key):
			buckets[key] = { "units": [] as Array[Node3D], "stat": s }
			bucket_order.append(key)
		var bucket: Dictionary = buckets[key]
		(bucket["units"] as Array[Node3D]).append(unit)
	# Stable rank: descending unit count, ties broken by first-seen.
	bucket_order.sort_custom(func(a: String, b: String) -> bool:
		var ca: int = (buckets[a]["units"] as Array).size()
		var cb: int = (buckets[b]["units"] as Array).size()
		return ca > cb
	)
	var emitted: int = 0
	for key: String in bucket_order:
		if emitted >= ABILITY_BUTTON_LIMIT:
			break
		out.append(buckets[key])
		emitted += 1
	return out


func _selection_passive_groups() -> Array[Dictionary]:
	## Mirrors _selection_ability_groups but for units that have no
	## active ability and instead carry a passive_description string.
	## Buckets by passive_description so identical passives across
	## different unit_names still collapse into one row.
	var out: Array[Dictionary] = []
	if not _selection_manager:
		return out
	var selected: Array[Node3D] = _selection_manager.get_selected_units() as Array[Node3D]
	if selected.is_empty():
		return out
	var buckets: Dictionary = {}
	var bucket_order: Array[String] = []
	for unit: Node3D in selected:
		if not is_instance_valid(unit) or not "stats" in unit:
			continue
		var s: UnitStatResource = unit.get("stats") as UnitStatResource
		if not s or s.passive_description == "":
			continue
		# Skip units that ALSO have an active ability -- the active
		# slot already represents them; doubling up clutters the row.
		if s.ability_name != "":
			continue
		var key: String = s.passive_description
		if not buckets.has(key):
			buckets[key] = { "units": [] as Array[Node3D], "stat": s }
			bucket_order.append(key)
		(buckets[key]["units"] as Array[Node3D]).append(unit)
	bucket_order.sort_custom(func(a: String, b: String) -> bool:
		return (buckets[a]["units"] as Array).size() > (buckets[b]["units"] as Array).size()
	)
	var emitted: int = 0
	for key: String in bucket_order:
		if emitted >= ABILITY_BUTTON_LIMIT:
			break
		out.append(buckets[key])
		emitted += 1
	return out


func _paint_passive_button_style(btn: Button) -> void:
	## Subdued grey-blue stylebox so a Passive slot reads as
	## 'always-on, not interactive' next to the violet active
	## ability buttons. Disabled-state styling matches normal so
	## the button looks the same whether or not Godot considers it
	## hovered (it's disabled = true so hover never visually fires
	## anyway).
	var passive_accent: Color = Color(0.45, 0.62, 0.78, 1.0)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.16, 0.20, 1.0)
	bg.border_color = passive_accent
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(3)
	bg.content_margin_left = 6
	bg.content_margin_right = 6
	bg.content_margin_top = 4
	bg.content_margin_bottom = 4
	btn.add_theme_stylebox_override("normal", bg)
	btn.add_theme_stylebox_override("hover", bg)
	btn.add_theme_stylebox_override("pressed", bg)
	btn.add_theme_stylebox_override("disabled", bg)
	btn.add_theme_color_override("font_color", passive_accent)
	btn.add_theme_color_override("font_disabled_color", passive_accent)


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
	## are ready cast, the ones still cooling down skip. For
	## area-target abilities (stats.ability_targeted) the press
	## instead enters target mode; the next LEFT-click on the ground
	## resolves the cast position via SelectionManager.
	if units.is_empty():
		return
	var first_unit: Node3D = units[0]
	if is_instance_valid(first_unit) and "stats" in first_unit:
		var stats: UnitStatResource = first_unit.get("stats")
		if stats and stats.ability_targeted and _selection_manager and _selection_manager.has_method("enter_ability_target_mode"):
			_selection_manager.call("enter_ability_target_mode", units, stats)
			return
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

	# Faction-aware producible list. Pull the FULL roster (including
	# tech-gated entries) so locked units still render as greyed-out
	# buttons; the unlocked subset is computed alongside for the
	# disabled-state check.
	var producible_all: Array[UnitStatResource] = building.get_all_producible_units() if building.has_method("get_all_producible_units") else building.get_producible_units()
	var producible: Array[UnitStatResource] = building.get_producible_units()
	# HQ + Anvil player + own HQ + constructed -> show the Train /
	# Defense tab row. Defense tab holds the HQ-only upgrade buttons
	# (HQ Plating, HQ Battery), so they don't clutter the Train tab.
	var show_hq_tabs: bool = _hq_defense_tab_eligible(building)
	if show_hq_tabs:
		_ensure_hq_tab_row()
		if _hq_tab_row:
			_hq_tab_row.visible = true
			if _hq_tab_train:
				_hq_tab_train.button_pressed = _hq_tab == "train"
			if _hq_tab_defense:
				_hq_tab_defense.button_pressed = _hq_tab == "defense"
	else:
		# Non-HQ buildings hide the tab row so the production grid
		# starts at the top of the action section like before.
		if _hq_tab_row:
			_hq_tab_row.visible = false

	# Defense tab: render the upgrade buttons and skip the unit grid.
	if show_hq_tabs and _hq_tab == "defense":
		_action_label.text = "HQ Defense Upgrades"
		_append_hq_upgrade_buttons(building)
		return

	# Superweapon panel -- a building with a SuperweaponComponent
	# replaces the standard production grid with one big activation
	# button that doubles as a state readout (Ready / Arming / Firing
	# / Cooldown). Targeting handover happens via SelectionManager.
	var sw: Node = building.get_node_or_null("SuperweaponComponent")
	if sw:
		_action_label.text = "Superweapon"
		_append_superweapon_button(building, sw)
		return

	if producible_all.is_empty():
		_action_label.text = "No production"
		return

	_action_label.text = "Train Units"
	var hotkeys: Array[String] = ["Q", "W", "E", "R", "T"]

	# Render the FULL roster. Unlocked entries get the standard
	# clickable button + a hotkey index that tracks their position
	# in the unlocked sublist (so hotkey N still triggers the Nth
	# unlocked unit). Locked entries render as a disabled greyed
	# button with a 'Locked: needs <building>' annotation in the
	# label and tooltip.
	# Buildings still under construction can't queue units. Render the
	# whole roster as greyed-out informational so the player can read
	# what they're going to be able to train, but the buttons reject
	# clicks until the building completes.
	var construction_locked: bool = not building.is_constructed
	var unlocked_idx: int = 0
	for unit_stat: UnitStatResource in producible_all:
		var unlocked: bool = building.is_unit_unlocked(unit_stat) if building.has_method("is_unit_unlocked") else true

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(124, 80)
		btn.size_flags_horizontal = Control.SIZE_FILL
		btn.size_flags_vertical = Control.SIZE_FILL

		var u_display: String = unit_stat.get_display_name()
		if unlocked:
			var hotkey: String = hotkeys[unlocked_idx] if unlocked_idx < hotkeys.size() else str(unlocked_idx + 1)
			_set_label_button(btn, "[%s]" % hotkey, u_display)
			btn.tooltip_text = _unit_tooltip(unit_stat)
			var capture_idx: int = unlocked_idx
			btn.pressed.connect(_on_production_button.bind(capture_idx))
			var chip_refs: Dictionary = _attach_cost_widget(btn, unit_stat.cost_salvage, unit_stat.cost_fuel, unit_stat.population)
			_action_buttons.append({ "button": btn, "kind": "produce", "stat": unit_stat, "chips": chip_refs })
			if construction_locked:
				btn.disabled = true
				btn.tooltip_text = "%s — building is still under construction." % u_display
			unlocked_idx += 1
		else:
			var prereq: StringName = unit_stat.unlock_prerequisite
			var prereq_label: String = _building_display_name(String(prereq))
			_set_label_button(btn, "Locked", "%s\nneeds %s" % [u_display, prereq_label])
			btn.disabled = true
			btn.tooltip_text = "%s — locked.\nBuild a %s to unlock." % [u_display, prereq_label]
		# Tint the button by the unit's category so the training
		# panel can be read at a glance the same way the build menu
		# is colour-coded.
		_apply_role_tint_to_build_button(btn, _train_button_role_color(unit_stat), unlocked)
		_button_grid.add_child(btn)


func _append_superweapon_button(building: Building, sw: Node) -> void:
	## Single big activation button for the selected superweapon
	## building. Label flips between Ready (clickable) and a state
	## readout (Arming X% / Firing X% / Cooldown XXs) when a fire
	## sequence is in flight or the weapon is recharging.
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(220, 56)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var state: int = sw.call("get_state") as int if sw.has_method("get_state") else 0
	var ready: bool = sw.call("is_ready") as bool if sw.has_method("is_ready") else false
	if ready:
		btn.text = "[D] Activate Superweapon"
		btn.tooltip_text = "Click to enter targeting mode, then right-click a target on the map."
		btn.pressed.connect(_on_superweapon_activate.bind(building, sw))
	else:
		var label_state: String = sw.call("get_state_label") as String if sw.has_method("get_state_label") else "Busy"
		var pct: int = int((sw.call("get_state_progress") as float if sw.has_method("get_state_progress") else 0.0) * 100.0)
		var remaining: int = int(ceilf(sw.call("get_remaining_seconds") as float if sw.has_method("get_remaining_seconds") else 0.0))
		btn.text = "%s  %d%%  (%ds)" % [label_state, pct, remaining]
		btn.disabled = true
	_button_grid.add_child(btn)


func _on_superweapon_activate(_building: Building, sw: Node) -> void:
	# `_building` arg unused -- kept on the signature so HUD callers
	# can extend the activation flow with per-building UX later
	# without re-binding every superweapon button.
	if not _selection_manager:
		return
	if _selection_manager.has_method("enter_superweapon_target_mode"):
		_selection_manager.call("enter_superweapon_target_mode", sw)


func _building_display_name(building_id: String) -> String:
	## Pretty-print a building_id (snake-case StringName) for inline
	## prereq messaging on locked unit buttons.
	if building_id == "":
		return "?"
	return building_id.replace("_", " ").capitalize()


func _hq_defense_tab_eligible(building: Building) -> bool:
	if not building or not building.stats:
		return false
	if building.stats.building_id != &"headquarters":
		return false
	if building.owner_id != 0:
		return false
	if not building.is_constructed:
		return false
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if not settings or not ("player_faction" in settings):
		return false
	return (settings.get("player_faction") as int) == 0


func _ensure_hq_tab_row() -> void:
	if _hq_tab_row and is_instance_valid(_hq_tab_row):
		return
	var section: Node = _button_grid.get_parent() if _button_grid else null
	if not section:
		return
	var row := HBoxContainer.new()
	row.name = "HQTabRow"
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	section.add_child(row)
	# Sit above the button grid; equivalent to the build_tab_row
	# pattern so HQ panel and build menu read consistently.
	section.move_child(row, _button_grid.get_index())
	_hq_tab_row = row
	_hq_tab_train = Button.new()
	_hq_tab_train.text = "Train"
	_hq_tab_train.custom_minimum_size = Vector2(72, 26)
	_hq_tab_train.toggle_mode = true
	_hq_tab_train.button_pressed = _hq_tab == "train"
	_hq_tab_train.pressed.connect(_on_hq_tab_pressed.bind("train"))
	row.add_child(_hq_tab_train)
	_hq_tab_defense = Button.new()
	_hq_tab_defense.text = "Defense"
	_hq_tab_defense.custom_minimum_size = Vector2(86, 26)
	_hq_tab_defense.toggle_mode = true
	_hq_tab_defense.button_pressed = _hq_tab == "defense"
	_hq_tab_defense.pressed.connect(_on_hq_tab_pressed.bind("defense"))
	row.add_child(_hq_tab_defense)


func _on_hq_tab_pressed(tab: String) -> void:
	if _hq_tab == tab:
		# Reflect the toggle state even if the tab didn't change.
		if _hq_tab_train:
			_hq_tab_train.button_pressed = _hq_tab == "train"
		if _hq_tab_defense:
			_hq_tab_defense.button_pressed = _hq_tab == "defense"
		return
	_hq_tab = tab
	_last_building_id = -1  # force a panel rebuild on the next tick


## Anvil HQ defensive upgrade definitions. Each one-time upgrade
## directly applies its effect on the selected HQ when bought
## (no research timer): hq_plating raises max HP +25%, hq_battery
## bumps the built-in defensive turret damage / range. Costs sit
## in the same salvage + fuel idiom the tech buildings use.
const HQ_PLATING_COST_SALVAGE: int = 150
const HQ_PLATING_COST_FUEL: int = 50
const HQ_BATTERY_COST_SALVAGE: int = 200
const HQ_BATTERY_COST_FUEL: int = 80
const HQ_PLATING_HP_MULT: float = 1.25


func _append_hq_upgrade_buttons(building: Building) -> void:
	## Renders the HQ Plating + HQ Battery buttons. Eligibility check
	## (Anvil-only, own HQ, constructed) lives in
	## _hq_defense_tab_eligible -- this function assumes the caller
	## already gated on it.
	if not bool(building.get("hq_plating_active")):
		_button_grid.add_child(_make_hq_upgrade_button(
			building,
			"HQ Plating",
			"+%d%% HP — heavier ablative plating on the command building." % int((HQ_PLATING_HP_MULT - 1.0) * 100.0),
			HQ_PLATING_COST_SALVAGE,
			HQ_PLATING_COST_FUEL,
			Callable(self, "_apply_hq_plating"),
		))
	if not bool(building.get("hq_battery_active")):
		_button_grid.add_child(_make_hq_upgrade_button(
			building,
			"HQ Battery",
			"+50%% damage / +4u range on the HQ defensive turret.",
			HQ_BATTERY_COST_SALVAGE,
			HQ_BATTERY_COST_FUEL,
			Callable(self, "_apply_hq_battery"),
		))


func _make_hq_upgrade_button(building: Building, title: String, blurb: String, cost_s: int, cost_f: int, apply_cb: Callable) -> Button:
	var btn := _StyledTooltipButton.new()
	btn.custom_minimum_size = Vector2(124, 80)
	btn.size_flags_horizontal = Control.SIZE_FILL
	btn.size_flags_vertical = Control.SIZE_FILL
	_set_label_button(btn, "", title)
	# Plain tooltip_text triggers Godot's tooltip; the styled
	# popup is built by _make_custom_tooltip on the subclass.
	btn.tooltip_text = title
	# Defense red accent matches the role colour the building
	# tooltip uses for emplacements.
	btn.tooltip_builder = func() -> Control:
		return make_styled_upgrade_tooltip(title, blurb, cost_s, cost_f, _ROLE_COLOR_DEFENSE)
	btn.pressed.connect(_on_hq_upgrade_pressed.bind(building, cost_s, cost_f, apply_cb))
	var chip_refs: Dictionary = _attach_cost_widget(btn, cost_s, cost_f, 0)
	_action_buttons.append({ "button": btn, "kind": "hq_upgrade", "cost_s": cost_s, "cost_f": cost_f, "chips": chip_refs })
	return btn


func _on_hq_upgrade_pressed(building: Building, cost_s: int, cost_f: int, apply_cb: Callable) -> void:
	if not is_instance_valid(building) or not _resource_manager:
		return
	if not _resource_manager.can_afford(cost_s, cost_f):
		return
	if not _resource_manager.spend(cost_s, cost_f):
		return
	apply_cb.call(building)
	_last_building_id = -1  # force panel rebuild so the bought button hides


func _apply_hq_plating(building: Building) -> void:
	if not is_instance_valid(building) or not building.stats:
		return
	building.hq_plating_active = true
	var new_max: int = int(round(float(building.stats.hp) * HQ_PLATING_HP_MULT))
	building.hp_max_override = new_max
	# Pour the fresh HP delta into current_hp too so the upgrade
	# reads as a real bulwark immediately (vs leaving the HQ at its
	# old current_hp under a higher ceiling).
	building.current_hp = mini(new_max, int(round(float(building.current_hp) * HQ_PLATING_HP_MULT)))


func _apply_hq_battery(building: Building) -> void:
	if not is_instance_valid(building):
		return
	building.hq_battery_active = true


func _on_production_button(index: int) -> void:
	if _selection_manager:
		_selection_manager.queue_unit_at_building(index)


## Color codes used by `_attach_cost_widget` for the salvage / fuel /
## population swatches on production + build buttons. Each swatch +
## number reads at a glance even when the eye is busy elsewhere.
const RES_COLOR_SALVAGE: Color = Color(1.00, 0.55, 0.18, 1.0)  # warm orange
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
const STAT_LABEL_COLOR_COST_S: String = "ff8c2e"    # salvage orange
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


func _build_unit_stat_sheet(unit: Node3D, _include_cost: bool = false) -> String:
	## Six-row stat sheet for a unit. Used by both the friendly
	## single-select panel and the enemy / neutral inspect panel.
	## Rows in order: defense, combat, mobility/sight/squad,
	## weapon stars, attack bonuses, own armor.
	##
	## _include_cost is kept as a parameter for callsite compat
	## but no longer affects the output -- pop / cost / weapon-
	## summary rows moved out of the stat sheet (they're already
	## visible on the production button + role hint, repeating
	## them here was clutter).
	var stats: UnitStatResource = unit.stats as UnitStatResource
	if not stats:
		return ""
	var hp_now: int = unit.get_total_hp() if unit.has_method("get_total_hp") else 0
	if hp_now == 0 and "current_hp" in unit:
		hp_now = unit.get("current_hp") as int
	var alive: int = (unit.get("alive_count") as int) if "alive_count" in unit else 1

	# Row 1 — defense. Armor reduction percentage merged into the
	# Armor chip as "(-X%)" right after the type label so the
	# defensive headline reads at a glance instead of being split
	# across rows.
	var armor_pct: int = int(round(stats.resolved_armor_reduction() * 100.0))
	var armor_label: String = str(stats.armor_class).capitalize()
	if armor_pct > 0:
		armor_label += "  (-%d%%)" % armor_pct
	var row_defense: Array = [
		_stat_chip("HP", "%d / %d" % [hp_now, stats.hp_total], STAT_LABEL_COLOR_HP),
		_stat_chip("Class", str(stats.unit_class).capitalize(), STAT_LABEL_COLOR_DEFENSE),
		_stat_chip("Armor", armor_label, STAT_LABEL_COLOR_DEFENSE),
	]

	# Row 2 — combat. Always show both DPS-vs-ground and DPS-vs-air
	# with explicit labels so the player can read "this unit can / can't
	# hit aircraft" without guessing from the role tag alone. Range
	# and accuracy fall on the same row to keep all combat numbers
	# in one scannable line.
	var dps_ground: float = _compute_dps_vs(stats, &"medium")
	var range_u: float = _max_weapon_range(stats)
	var acc_pct: int = int(_effective_accuracy(unit) * 100.0)
	# Air DPS only shows for units that can actually engage aircraft
	# (have an AAir-tagged weapon). AP / Universal trickle damage at
	# 0.1-0.4x mults isn't meaningful enough to call the unit anti-
	# air, and showing the value for ground-only units misled the
	# reader into thinking those units could threaten airframes.
	var row_combat: Array = [
		_stat_chip("DPS Gnd", "%.0f" % dps_ground, STAT_LABEL_COLOR_DAMAGE),
	]
	if stats.can_target_air():
		var dps_air: float = _compute_dps_vs(stats, &"light_air")
		row_combat.append(_stat_chip("DPS Air", "%.0f" % dps_air, STAT_LABEL_COLOR_DAMAGE))
	row_combat.append(_stat_chip("Range", "%.0fu" % range_u, STAT_LABEL_COLOR_RANGE))
	row_combat.append(_stat_chip("Acc", "%d%%" % acc_pct, STAT_LABEL_COLOR_RANGE))

	# Row 3 — mobility. Plain numeric readouts (the star bars
	# stayed too busy alongside the rest of the panel content).
	var row_mobility: Array = [
		_stat_chip("Speed", "%.0f" % stats.resolved_speed(), STAT_LABEL_COLOR_MOBILITY),
		_stat_chip("Sight", "%.0fu" % stats.resolved_sight_radius(), STAT_LABEL_COLOR_RANGE),
		_stat_chip("Squad", "%d / %d" % [alive, stats.squad_size], STAT_LABEL_COLOR_SQUAD),
	]

	# (Weapon Dmg / Rng / RoF star row dropped per UX pass -- the
	# attack-bonus matrix below already conveys "is this weapon
	# good against X armor", and the DPS Gnd / DPS Air chips on
	# row_combat carry the punchy summary number. Repeating the
	# raw weapon stats here just made the panel longer.)

	# Row 4 — attack bonus matrix. The role-vs-armor multipliers
	# explain why a Switchblade's raw DPS reads low or high against a
	# specific class -- the multipliers are doing most of the work.
	var row_attack_bonus: Array = _attack_bonus_chips(stats)

	# (Bottom-row armor reduction chip removed -- the percentage now
	# lives inline on the Armor chip in row_defense.)

	# Basic vs Extended split. Default view shows the headline rows
	# only (defense + combat); SHIFT (or the persistent settings
	# toggle) adds mobility + attack-bonus matrix. Keeps the panel
	# scannable for new players while power users can still pull the
	# full breakdown on demand.
	var rows: Array = [row_defense, row_combat]
	if _extended_stats_active():
		rows.append(row_mobility)
		rows.append(row_attack_bonus)
	else:
		rows.append([_extended_hint_chip()])
	return _build_stat_sheet(rows)


func _extended_hint_chip() -> String:
	## Tiny hint chip that lives at the bottom of the basic stat
	## sheet so players know there's more behind SHIFT. When the
	## settings toggle inverts the default, the hint flips to "[hold
	## SHIFT for basic view]" so the cue still reads correctly.
	if _extended_stats_default:
		return "[color=#888888][hold SHIFT for basic view][/color]"
	return "[color=#888888][hold SHIFT for full stats][/color]"


func _role_matchup_chips(role_tag: StringName) -> Array:
	## Same shape as `_attack_bonus_chips` but takes a raw role tag --
	## used by combat buildings (gun emplacement / SAM site / HQ defense)
	## to surface their role multipliers without requiring a
	## UnitStatResource. Anti-air roles drop the ground-class chips so
	## SAMs read as 'air specialist', and ground roles drop air chips
	## so the row stays compact. Multipliers carry the same red->yellow
	## ->green gradient as the unit attack-bonus row so the player can
	## spot a turret's best/worst matchup at a glance.
	var out: Array = []
	if role_tag == &"":
		return out
	var classes: Array[StringName]
	var labels: Array[String]
	if role_tag == &"AAir" or role_tag == &"AAir_Light":
		classes = [&"light_air", &"heavy_air"]
		labels = ["LtAir", "HvAir"]
	else:
		classes = [&"light", &"medium", &"heavy", &"structure"]
		labels = ["Lt", "Md", "Hv", "Struct"]
	var mults: Array[float] = []
	for i: int in classes.size():
		mults.append(CombatTables.get_role_modifier(role_tag, classes[i]))
	var lo: float = mults[0]
	var hi: float = mults[0]
	for m: float in mults:
		if m < lo:
			lo = m
		if m > hi:
			hi = m
	for i: int in classes.size():
		var color_hex: String = _gradient_value_color(mults[i], lo, hi)
		out.append(_stat_chip_value_colored(
			"vs " + labels[i], "%.1fx" % mults[i],
			STAT_LABEL_COLOR_DAMAGE, color_hex,
		))
	return out


func _attack_bonus_chips(stats: UnitStatResource) -> Array:
	## Builds a chip row showing the primary weapon's role-vs-armor
	## multipliers. Reads as "vs Light 1.0x | vs Heavy 0.3x | ..."
	## so the player can see why a unit's raw DPS reads low or high
	## against a specific class. Empty array when the unit has no
	## primary weapon (engineers etc).
	##
	## Air classes (LtAir / HvAir) are dropped for ground-only units
	## so the row stops advertising trickle-damage multipliers vs
	## targets the unit can't actually engage.
	var out: Array = []
	if not stats or not stats.primary_weapon:
		return out
	var role_tag: StringName = stats.primary_weapon.role_tag
	var classes: Array[StringName] = [&"light", &"medium", &"heavy", &"structure"]
	var labels: Array[String] = ["Lt", "Md", "Hv", "Struct"]
	if stats.can_target_air():
		classes = [&"light", &"medium", &"heavy", &"light_air", &"heavy_air", &"structure"]
		labels = ["Lt", "Md", "Hv", "LtAir", "HvAir", "Struct"]
	# Per-unit gradient colour: green for the highest matchup, red for
	# the lowest, smooth interpolation in between. Lets the player
	# spot at a glance which armor class this unit punches up against
	# and which it should avoid. Computed per-call so every unit reads
	# its own scale -- a Switchblade's 'best' chip is a different
	# absolute value than a Bulwark's 'best'.
	var weapon_air_mult: float = stats.primary_weapon.air_damage_mult
	var mults: Array[float] = []
	for i: int in classes.size():
		# Use the weapon's per-class override path so overridden
		# multipliers (Bulwark cannon, WRAITH bay, etc.) display the
		# same number combat actually uses.
		var m: float = stats.primary_weapon.get_role_mult_for(classes[i])
		# Air rows fold in the per-weapon air scalar so the displayed
		# multiplier matches what the gun actually does to airframes.
		if classes[i] == &"light_air" or classes[i] == &"heavy_air":
			m *= weapon_air_mult
		mults.append(m)
	var lo: float = mults[0]
	var hi: float = mults[0]
	for m: float in mults:
		if m < lo:
			lo = m
		if m > hi:
			hi = m
	for i: int in classes.size():
		var mult: float = mults[i]
		var color_hex: String = _gradient_value_color(mult, lo, hi)
		out.append(_stat_chip_value_colored("vs " + labels[i], "%.1fx" % mult, STAT_LABEL_COLOR_DAMAGE, color_hex))
	return out


func _gradient_value_color(value: float, lo: float, hi: float) -> String:
	## Returns a hex colour string ranging red -> yellow -> green
	## across the (lo..hi) range. Collapses to plain yellow when the
	## row has no spread (every chip equal) so a flat row doesn't
	## arbitrarily pick one chip to highlight green over the others.
	if hi - lo < 0.001:
		return "ddc94c"  # neutral mid-yellow
	var t: float = clampf((value - lo) / (hi - lo), 0.0, 1.0)
	# Lerp red -> yellow -> green via two segments so the midpoint
	# lands on yellow instead of muddy orange.
	var r: float
	var g: float
	var b: float = 0.30
	if t < 0.5:
		var k: float = t * 2.0
		r = 0.92
		g = lerp(0.32, 0.86, k)
	else:
		var k: float = (t - 0.5) * 2.0
		r = lerp(0.92, 0.40, k)
		g = lerp(0.86, 0.92, k)
	return "%02x%02x%02x" % [int(r * 255.0), int(g * 255.0), int(b * 255.0)]


func _stat_chip_value_colored(label: String, value: String, label_color_hex: String, value_color_hex: String) -> String:
	## Variant of `_stat_chip` that also colours the value (not just
	## the label). Used by the attack-bonus matrix so the per-unit
	## red->green gradient lands on the multiplier figure itself.
	return "[color=#%s]%s[/color] [color=#%s]%s[/color]" % [
		label_color_hex, label, value_color_hex, value,
	]


func _build_building_stat_sheet(building: Node3D, bstats: BuildingStatResource, hp_now: int) -> String:
	## Compact building / structure stat sheet. Shows HP, power impact,
	## and (when applicable) turret DPS so the player can compare a
	## gun-emplacement profile to a mech weapon at a glance.
	var rows: Array = []
	var hp_max: int = bstats.hp
	if building and building.has_method("effective_max_hp"):
		hp_max = building.call("effective_max_hp") as int
	# HP chip mirrors the unit panel's HP readout -- the world-space
	# bar above the building shows damage state, but the player also
	# wants the numeric value next to the rest of the building stats
	# so they can compare 'is this HQ at half HP' without eyeballing
	# the bar. Tint shifts to orange under 66% HP / red under 33%
	# so the row colour matches how hurt the building is.
	var hp_color_hex: String = STAT_LABEL_COLOR_HP
	if hp_max > 0:
		var pct: float = clampf(float(hp_now) / float(hp_max), 0.0, 1.0)
		if pct < 0.33:
			hp_color_hex = STAT_LABEL_COLOR_DAMAGE
		elif pct < 0.66:
			hp_color_hex = STAT_LABEL_COLOR_RANGE
	var defense_row: Array = [
		_stat_chip("HP", "%d / %d" % [hp_now, hp_max], hp_color_hex),
		_stat_chip("Class", "Structure", STAT_LABEL_COLOR_DEFENSE),
	]
	if bstats.power_production > 0:
		defense_row.append(_stat_chip("Power", "+%d" % bstats.power_production, STAT_LABEL_COLOR_MOBILITY))
	elif bstats.power_consumption > 0:
		defense_row.append(_stat_chip("Power", "-%d" % bstats.power_consumption, STAT_LABEL_COLOR_DAMAGE))
	rows.append(defense_row)

	# Turret stats (gun emplacements / SAM sites that have a
	# TurretComponent attached). Basic view shows DPS + Range; the
	# role-vs-armor matchup row is held back for the SHIFT-extended
	# view since it's the "why is this number what it is" detail.
	var turret: Node = building.get_node_or_null("TurretComponent") if building else null
	var extended: bool = _extended_stats_active()
	if turret:
		# Read the turret's actual current profile (Anvil emplacement
		# damage already includes the +15% multiplier; basic / SAM
		# variants don't).
		var t_dmg: int = int(turret.call("get_damage")) if turret.has_method("get_damage") else TurretComponent.TURRET_DAMAGE
		var t_fi: float = float(turret.call("get_fire_interval")) if turret.has_method("get_fire_interval") else TurretComponent.FIRE_INTERVAL
		var t_rng: float = float(turret.call("get_range")) if turret.has_method("get_range") else TurretComponent.TURRET_RANGE
		# Burst-fire profiles (HQ MG nests fire 3-shot salvos per
		# cooldown) need to multiply per-shot damage by burst_count
		# to get the displayed DPS to match what the turret actually
		# outputs over time.
		var t_burst: int = 1
		var profile_key: StringName = (turret.get("profile") as StringName) if "profile" in turret else &""
		if profile_key != &"" and TurretComponent.PROFILES.has(profile_key):
			var p_dict: Dictionary = TurretComponent.PROFILES[profile_key] as Dictionary
			t_burst = int(p_dict.get("burst_count", 1))
		var dps: float = (float(t_dmg) * float(t_burst)) / maxf(t_fi, 0.01)
		var combat_row: Array = [
			_stat_chip("DPS", "%.0f" % dps, STAT_LABEL_COLOR_DAMAGE),
			_stat_chip("Range", "%.0fu" % t_rng, STAT_LABEL_COLOR_RANGE),
		]
		rows.append(combat_row)
		if extended:
			# Role-vs-armor matchups for the turret's current profile
			# -- so the player can see why a SAM site shreds aircraft
			# but barely scratches mechs, or why an AP emplacement
			# under-performs vs heavy armor.
			var role_tag: StringName = (turret.call("get_role") as StringName) if turret.has_method("get_role") else &"Universal"
			var bonus_row: Array = _role_matchup_chips(role_tag)
			if not bonus_row.is_empty():
				rows.append(bonus_row)

	if extended and not bstats.producible_units.is_empty():
		# 'Produces N unit type(s)' is informational; in the basic
		# view the production grid below the panel already conveys
		# this, so it lives in the extended sheet only.
		var produces_row: Array = [
			_stat_chip("Produces", "%d unit type(s)" % bstats.producible_units.size(), STAT_LABEL_COLOR_RANGE),
		]
		rows.append(produces_row)
	if not extended:
		rows.append([_extended_hint_chip()])
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
	# Pin the strip ENTIRELY inside the button bounds. Previous
	# offset_top = -14 meant the strip's top edge sat 14px above
	# the button bottom -- but with separators + icon padding the
	# bottom row of pixels could clip below the button edge.
	# Now: 18px tall strip starting 20px above the bottom, with a
	# 4px floor margin so the icons can never touch / cross the
	# button outline.
	hbox.offset_top = -22
	hbox.offset_bottom = -4
	hbox.offset_left = 4
	hbox.offset_right = -4
	btn.add_child(hbox)
	var refs: Dictionary = {}
	if salvage > 0:
		refs["salvage"] = _add_cost_chip(hbox, salvage, RES_COLOR_SALVAGE, ResourceIcon.Kind.SALVAGE, "Salvage")
	if fuel > 0:
		refs["fuel"] = _add_cost_chip(hbox, fuel, RES_COLOR_FUEL, ResourceIcon.Kind.FUEL, "Fuel")
	if pop > 0:
		refs["pop"] = _add_cost_chip(hbox, pop, RES_COLOR_POP, ResourceIcon.Kind.POPULATION, "Population")
	return refs


func _add_cost_chip(parent: Container, amount: int, color: Color, icon_kind: int = -1, tooltip: String = "") -> Dictionary:
	var chip := HBoxContainer.new()
	chip.add_theme_constant_override("separation", 3)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(chip)
	# Icon swatch -- distinct shape per resource kind. Kept as
	# `swatch` in the returned dict so legacy callers still work,
	# but it's now a ResourceIcon Control instead of a plain
	# ColorRect (or a ColorRect fallback for un-migrated callers).
	var swatch_node: Node = null
	if icon_kind >= 0:
		var icon: ResourceIcon = ResourceIcon.make(icon_kind as ResourceIcon.Kind, color, tooltip, Vector2(12.0, 12.0))
		chip.add_child(icon)
		swatch_node = icon
	else:
		var fallback := ColorRect.new()
		fallback.custom_minimum_size = Vector2(8, 8)
		fallback.color = color
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(fallback)
		swatch_node = fallback
	var lbl := Label.new()
	lbl.text = str(amount)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(lbl)
	return { "swatch": swatch_node, "label": lbl, "color": color }


func _rebuild_turret_profile_buttons(building: Building) -> void:
	## Profile-swap buttons for a selected gun emplacement — each calls
	## into TurretComponent.set_profile to swap weapon stats and visuals.
	## Only Anvil's specialised emplacement exposes profile selection;
	## Sable's basic emplacement and the SAM Site keep a fixed profile,
	## so we render no buttons for them. anti_air isn't in the swap list
	## either way -- the SAM Site is the AA structure now.
	_clear_buttons()
	var turret: Node = building.get_node_or_null("TurretComponent")
	if not turret:
		_action_label.text = ""
		return
	if turret.has_method("is_profile_swap_allowed") and not turret.call("is_profile_swap_allowed"):
		_action_label.text = "Static Defense"
		return

	_action_label.text = "Turret Profile"
	var profiles: Array[Dictionary] = [
		{ "key": &"balanced",   "hotkey": "Q" },
		{ "key": &"anti_light", "hotkey": "W" },
		{ "key": &"anti_heavy", "hotkey": "E" },
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
		var btn_v: Variant = entry.get("button", null)
		if btn_v == null or not is_instance_valid(btn_v):
			continue
		var btn: Button = btn_v as Button
		if not btn:
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


## Faction roster of base units that have a branch commit, split by
## the armory that hosts them. The Basic Armory hosts upgrades for
## units the player gets from the production buildings on their own
## (Foundry baseline / Adv Foundry baseline / Aerodrome baseline).
## The Advanced Armory hosts upgrades for the units it itself unlocks
## via the Advanced Armory tech gate. Order matters — rendered top
## to bottom in the same order the production lineup uses.
const ANVIL_BASIC_BRANCHED_UNITS: Array[String] = [
	"res://resources/units/anvil_rook.tres",
	"res://resources/units/anvil_hound.tres",
	"res://resources/units/anvil_bulwark.tres",
	"res://resources/units/anvil_phalanx.tres",
]
const ANVIL_ADVANCED_BRANCHED_UNITS: Array[String] = [
	"res://resources/units/anvil_forgemaster.tres",
	"res://resources/units/anvil_hammerhead.tres",
]
const SABLE_BASIC_BRANCHED_UNITS: Array[String] = [
	"res://resources/units/sable_specter.tres",
	"res://resources/units/sable_jackal.tres",
	"res://resources/units/sable_harbinger.tres",
	"res://resources/units/sable_switchblade.tres",
]
const SABLE_ADVANCED_BRANCHED_UNITS: Array[String] = [
	"res://resources/units/sable_courier_tank.tres",
	"res://resources/units/sable_fang.tres",
]


func _rebuild_armory_buttons(building: Building) -> void:
	_clear_buttons()

	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if not bcm:
		_action_label.text = "No commit manager"
		return

	# Pick the player's faction's branch roster, then narrow to the
	# slice this building hosts. Selecting Basic Armory shows the
	# baseline-unlocked units' branches; Advanced Armory shows the
	# branches for units the Adv Armory itself gates.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	var player_faction: int = 0
	if settings and "player_faction" in settings:
		player_faction = settings.get("player_faction") as int
	var is_advanced_armory: bool = building and building.stats and building.stats.building_id == &"advanced_armory"
	var paths: Array[String]
	if player_faction == 1:
		paths = SABLE_ADVANCED_BRANCHED_UNITS if is_advanced_armory else SABLE_BASIC_BRANCHED_UNITS
	else:
		paths = ANVIL_ADVANCED_BRANCHED_UNITS if is_advanced_armory else ANVIL_BASIC_BRANCHED_UNITS

	var armory_label: String = "Advanced Armory — branch upgrades" if is_advanced_armory else "Armory — branch upgrades"
	if bcm.is_committing():
		_action_label.text = "Commit in progress: %s" % bcm.get_commit_branch_name()
	else:
		_action_label.text = armory_label

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

	# Anchor Mode research button — bottom of the Basic Armory only.
	# It's a Crawler / economy upgrade, baseline-tier; the Advanced
	# Armory's slot is reserved for the bigger-ticket branch commits
	# of the units it gates, so don't double up.
	if not is_advanced_armory:
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
	name_lbl.text = base_stats.get_display_name()
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

	# When THIS row's commit is in progress, swap the two branch
	# buttons for a single cancel button showing live progress + the
	# branch being committed. Other rows still render their normal
	# (disabled) branch buttons so the player can see what's locked.
	var owning_base: UnitStatResource = bcm.get_commit_base_stats() if bcm.has_method("get_commit_base_stats") else null
	if bcm.is_committing() and owning_base and owning_base == base_stats:
		row.add_child(_make_commit_cancel_button(bcm))
		return row

	var committing_now: bool = bcm.is_committing()
	row.add_child(_make_branch_button(base_stats, base_stats.branch_a_stats, base_stats.branch_a_name, cost_suffix, committing_now))
	row.add_child(_make_branch_button(base_stats, base_stats.branch_b_stats, base_stats.branch_b_name, cost_suffix, committing_now))
	return row


func _make_commit_cancel_button(bcm: Node) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(248, 50)
	var pct: int = int(bcm.get_commit_progress() * 100.0) if bcm.has_method("get_commit_progress") else 0
	var bname: String = bcm.get_commit_branch_name() if bcm.has_method("get_commit_branch_name") else "Commit"
	btn.text = "Cancel %s  (%d%%) — refund" % [bname, pct]
	btn.add_theme_color_override("font_color", Color(1.0, 0.78, 0.32, 1.0))
	btn.tooltip_text = "Cancel the in-progress branch commit. Microchips, fuel, and salvage spent are refunded."
	btn.pressed.connect(_on_cancel_branch_commit)
	return btn


func _on_cancel_branch_commit() -> void:
	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if not bcm or not bcm.has_method("cancel_commit"):
		return
	if not bcm.cancel_commit():
		return
	# Refund — same trio of resources start_commit charged.
	if _resource_manager:
		if _resource_manager.has_method("add_salvage"):
			_resource_manager.add_salvage(BranchCommitManager.COMMIT_COST_SALVAGE)
		if _resource_manager.has_method("add_fuel"):
			_resource_manager.add_fuel(BranchCommitManager.COMMIT_COST_FUEL)
		if _resource_manager.has_method("add_microchips"):
			_resource_manager.add_microchips(BranchCommitManager.COMMIT_COST_MICROCHIPS)
	if _selection_manager and _selection_manager._audio:
		_selection_manager._audio.play_command()
	# Force panel rebuild so the row immediately reflects "open".
	_last_building_id = -1


func _make_branch_button(
	base_stats: UnitStatResource,
	branch_stats: UnitStatResource,
	branch_name: String,
	cost_suffix: String,
	disabled: bool,
) -> Button:
	var btn := _StyledTooltipButton.new()
	btn.custom_minimum_size = Vector2(120, 50)
	_set_label_button(btn, "", branch_name)
	btn.tooltip_text = branch_name
	# Captured by-reference so tooltip rebuilds reflect any
	# stat-source mutation (none today, but keeps it stable).
	var captured_branch: UnitStatResource = branch_stats
	var captured_base: UnitStatResource = base_stats
	var captured_suffix: String = cost_suffix
	btn.tooltip_builder = func() -> Control:
		return _make_branch_styled_tooltip(captured_base, captured_branch, branch_name, captured_suffix)
	btn.pressed.connect(_on_branch_commit.bind(base_stats, branch_stats, branch_name))
	btn.disabled = disabled
	_attach_research_cost_widget(btn)
	return btn


func _make_branch_styled_tooltip(base_stats: UnitStatResource, branch_stats: UnitStatResource, branch_name: String, cost_suffix: String) -> Control:
	## Branch-commit tooltip. Default body = short prose summary of
	## what the branch trades (read from `branch_summary` on the
	## variant). Holding SHIFT swaps to the per-stat delta breakdown
	## for players who want the full numbers. Empty branch_summary
	## falls back to the delta breakdown so legacy variants still
	## surface useful info.
	var title: String = "%s — %s" % [
		base_stats.unit_name if base_stats else "Unit",
		branch_name,
	]
	var summary: String = ""
	if branch_stats and branch_stats.branch_summary != "":
		summary = branch_stats.branch_summary
	var show_extended: bool = _extended_stats_active()
	var body: String
	if summary != "" and not show_extended:
		body = summary + "\n\n[hold SHIFT for full stat breakdown]"
	else:
		body = _branch_delta_summary(base_stats, branch_stats)
	var lines_extra: PackedStringArray = PackedStringArray()
	if cost_suffix and cost_suffix != "":
		lines_extra.append("")
		lines_extra.append("Upgrade cost:%s" % cost_suffix)
	return make_styled_upgrade_tooltip(title, body, 0, 0, _ROLE_COLOR_TECH, lines_extra)


func _extended_stats_active() -> bool:
	## True when the player is currently asking for the full per-stat
	## breakdown -- either by holding SHIFT or by enabling the
	## 'extended stats by default' setting from the settings panel.
	if _extended_stats_default:
		return not Input.is_key_pressed(KEY_SHIFT)
	return Input.is_key_pressed(KEY_SHIFT)


## Persistent toggle exposed by the settings panel. When true the
## roles invert: basic stats / branch summary live behind SHIFT,
## extended view is the default.
var _extended_stats_default: bool = false


func _branch_delta_summary(base_stats: UnitStatResource, branch_stats: UnitStatResource) -> String:
	## Compact pros/cons readout for a branch upgrade. Player-facing
	## numbers only -- no per-shot damage / RoF (those don't survive
	## the role/armor math), no squad-size deltas (mechanic was
	## scrapped), no narrative blurb (lived in the resource for the
	## old verbose pass; the deltas alone tell the upgrade story).
	if not base_stats or not branch_stats:
		return ""
	var pros: PackedStringArray = PackedStringArray()
	var cons: PackedStringArray = PackedStringArray()

	# HP / armor / speed / sight -- the survivability + mobility levers.
	_emit_branch_delta(pros, cons, "HP", float(branch_stats.hp_total - base_stats.hp_total), float(base_stats.hp_total), 0)
	_emit_branch_delta(pros, cons, "Speed", branch_stats.resolved_speed() - base_stats.resolved_speed(), base_stats.resolved_speed(), 1)
	_emit_branch_delta(pros, cons, "Sight", branch_stats.resolved_sight_radius() - base_stats.resolved_sight_radius(), base_stats.resolved_sight_radius(), 1)
	var arm_d: float = branch_stats.resolved_armor_reduction() - base_stats.resolved_armor_reduction()
	if absf(arm_d) > 0.005:
		var arm_line: String = "Armor %+d%%" % int(round(arm_d * 100.0))
		if arm_d > 0.0:
			pros.append(arm_line)
		else:
			cons.append(arm_line)

	# Effective DPS deltas. Ground readout against medium armor (the
	# canonical mech bucket); air readout against light_air, and only
	# when at least one variant can engage air. Captures damage + RoF
	# + role-mult shifts in a single number the player actually cares
	# about, instead of three separate per-shot deltas that don't
	# add up to anything intuitive.
	var dps_g_b: float = _compute_dps_vs(base_stats, &"medium")
	var dps_g_n: float = _compute_dps_vs(branch_stats, &"medium")
	_emit_branch_delta(pros, cons, "Ground DPS", dps_g_n - dps_g_b, dps_g_b, 0)
	if base_stats.can_target_air() or branch_stats.can_target_air():
		var dps_a_b: float = _compute_dps_vs(base_stats, &"light_air")
		var dps_a_n: float = _compute_dps_vs(branch_stats, &"light_air")
		_emit_branch_delta(pros, cons, "Air DPS", dps_a_n - dps_a_b, dps_a_b, 0)
	# Primary weapon range delta -- a branch that bumps range_tier
	# (Switchblade Dogfighter medium -> long, Specter Ghost medium ->
	# long, etc.) is a meaningful upgrade that doesn't show up in
	# the DPS calc. Surface it so the player reads the change.
	if base_stats.primary_weapon and branch_stats.primary_weapon:
		var b_range: float = base_stats.primary_weapon.resolved_range()
		var n_range: float = branch_stats.primary_weapon.resolved_range()
		_emit_branch_delta(pros, cons, "Range", n_range - b_range, b_range, 0)

	# Role-vs-armor mult shifts. Surfaces the "vs Heavy 0.3 -> 0.5"
	# kind of change the previous tooltip never showed -- meaningful
	# when a branch retags from AP to Universal etc.
	if base_stats.primary_weapon and branch_stats.primary_weapon:
		var b_role: StringName = base_stats.primary_weapon.role_tag
		var n_role: StringName = branch_stats.primary_weapon.role_tag
		var classes: Array[StringName] = [&"light", &"medium", &"heavy", &"structure", &"light_air", &"heavy_air"]
		var labels: Array[String] = ["vs Lt", "vs Md", "vs Hv", "vs Struct", "vs LtAir", "vs HvAir"]
		for i: int in classes.size():
			var bm: float = CombatTables.get_role_modifier(b_role, classes[i])
			var nm: float = CombatTables.get_role_modifier(n_role, classes[i])
			if absf(nm - bm) < 0.05:
				continue
			var mult_line: String = "%s %.1fx -> %.1fx" % [labels[i], bm, nm]
			if nm > bm:
				pros.append(mult_line)
			else:
				cons.append(mult_line)

	# Ability gain / change. Branches that introduce a new active
	# (System Crash, Missile Barrage, etc.) advertise it in the
	# plus column so the player isn't blindsided by a hotkey that
	# wasn't on the base unit. Autocast / manual is called out so
	# the player knows whether they need to babysit the cast.
	if branch_stats.ability_name != "" and base_stats.ability_name == "":
		var cast_tag_a: String = " (autocast)" if branch_stats.ability_autocast else " (active)"
		pros.append("Gains ability: %s%s" % [branch_stats.ability_name, cast_tag_a])
		if branch_stats.ability_description != "":
			pros.append("  • %s" % branch_stats.ability_description)
	elif branch_stats.ability_name != base_stats.ability_name and branch_stats.ability_name != "":
		var cast_tag_b: String = " (autocast)" if branch_stats.ability_autocast else " (active)"
		pros.append("Ability: %s -> %s%s" % [base_stats.ability_name, branch_stats.ability_name, cast_tag_b])
		if branch_stats.ability_description != "":
			pros.append("  • %s" % branch_stats.ability_description)
	elif branch_stats.ability_name == "" and base_stats.ability_name != "":
		cons.append("Loses ability: %s" % base_stats.ability_name)

	# Passive identity gain / change. Lists the branch's
	# passive_description in the pros column so the player sees
	# every always-on trait the branch grants alongside active
	# abilities, with the same '(passive)' tag so it's
	# distinguishable from an active hotkey.
	if branch_stats.passive_description != "" and base_stats.passive_description == "":
		pros.append("Gains passive")
		pros.append("  • %s" % branch_stats.passive_description)
	elif branch_stats.passive_description != base_stats.passive_description and branch_stats.passive_description != "":
		pros.append("Passive change")
		pros.append("  • %s" % branch_stats.passive_description)
	elif branch_stats.passive_description == "" and base_stats.passive_description != "":
		cons.append("Loses passive: %s" % base_stats.passive_description)

	# Passive / role-defining stats that aren't an active ability
	# but functionally ARE the upgrade. The previous tooltip only
	# surfaced active-ability gains, so a Spotter branch (gains
	# 200u stealth detection) read as 'no ability change' even
	# though that detection radius is the entire point of taking
	# the branch. Surface a representative slice here.
	_emit_passive_ability_deltas(pros, cons, base_stats, branch_stats)

	var lines: PackedStringArray = PackedStringArray()
	for p: String in pros:
		lines.append("[color=#7be37b]+ %s[/color]" % p)
	for c: String in cons:
		lines.append("[color=#ff6e6e]- %s[/color]" % c)
	if lines.is_empty():
		lines.append("[color=#aaaaaa]No stat differences.[/color]")
	return "\n".join(lines)


func _emit_passive_ability_deltas(
	pros: PackedStringArray,
	cons: PackedStringArray,
	base_stats: UnitStatResource,
	branch_stats: UnitStatResource,
) -> void:
	## Surface passive / role-defining stat changes that aren't an
	## active ability but functionally ARE the branch upgrade --
	## stealth-detection radius (Spotter), Mesh aura range,
	## repair_rate (Forgemaster), is_stealth_capable (Specter
	## Ghost), first_strike_bonus (Hound Ripper), etc. Only
	## emits a line when the delta is meaningful so identical
	## branches stay quiet.
	# Stealth-detection radius gain / change.
	var det_b: float = (base_stats.get("detection_radius") as float) if "detection_radius" in base_stats else 0.0
	var det_n: float = (branch_stats.get("detection_radius") as float) if "detection_radius" in branch_stats else 0.0
	if absf(det_n - det_b) > 0.5:
		var line: String = "Stealth detection %.0fu -> %.0fu" % [det_b, det_n]
		if det_n > det_b:
			pros.append(line)
		else:
			cons.append(line)
	# Mesh aura range gain.
	var mesh_b: float = (base_stats.get("mesh_provider_radius") as float) if "mesh_provider_radius" in base_stats else 0.0
	var mesh_n: float = (branch_stats.get("mesh_provider_radius") as float) if "mesh_provider_radius" in branch_stats else 0.0
	if absf(mesh_n - mesh_b) > 0.5:
		var line2: String = "Mesh aura %.0fu -> %.0fu" % [mesh_b, mesh_n]
		if mesh_n > mesh_b:
			pros.append(line2)
		else:
			cons.append(line2)
	# Repair rate change (engineers / Forgemaster).
	var rep_b: float = (base_stats.get("repair_rate") as float) if "repair_rate" in base_stats else 0.0
	var rep_n: float = (branch_stats.get("repair_rate") as float) if "repair_rate" in branch_stats else 0.0
	if absf(rep_n - rep_b) > 0.5:
		var line3: String = "Repair rate %+.0f" % (rep_n - rep_b)
		if rep_n > rep_b:
			pros.append(line3)
		else:
			cons.append(line3)
	# First-strike opener bonus (Hound Ripper +50% on first shot).
	var fs_b: float = (base_stats.get("first_strike_bonus") as float) if "first_strike_bonus" in base_stats else 1.0
	var fs_n: float = (branch_stats.get("first_strike_bonus") as float) if "first_strike_bonus" in branch_stats else 1.0
	if absf(fs_n - fs_b) > 0.01:
		var pct_n: int = int(round((fs_n - 1.0) * 100.0))
		if pct_n > 0:
			pros.append("First-strike: +%d%% damage on opening shot" % pct_n)
		elif pct_n < 0:
			cons.append("First-strike: %d%% damage on opening shot" % pct_n)
	# Stealth gain. is_stealth_capable is a bool so emit a
	# 'Gains stealth' line when the branch flips it on.
	var stl_b: bool = (base_stats.get("is_stealth_capable") as bool) if "is_stealth_capable" in base_stats else false
	var stl_n: bool = (branch_stats.get("is_stealth_capable") as bool) if "is_stealth_capable" in branch_stats else false
	if stl_n and not stl_b:
		pros.append("Gains stealth (concealed when not under fire)")
	elif stl_b and not stl_n:
		cons.append("Loses stealth")


func _emit_branch_delta(pros: PackedStringArray, cons: PackedStringArray, label: String, delta: float, base_val: float, decimals: int) -> void:
	## Append a +/- line to the pros / cons arrays based on `delta`.
	## Skipped when |delta| is below noise threshold so identical
	## stats don't clutter the readout. Includes a percentage when
	## the base is non-zero.
	if absf(delta) < 0.05:
		return
	var pct: String = ""
	if base_val > 0.001:
		pct = " (%+d%%)" % int(round((delta / base_val) * 100.0))
	var fmt: String = "%s %+." + str(decimals) + "f%s"
	var line: String = fmt % [label, delta, pct]
	if delta > 0.0:
		pros.append(line)
	else:
		cons.append(line)


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

	var anchor_btn := _StyledTooltipButton.new()
	anchor_btn.custom_minimum_size = Vector2(160, 50)
	if rm.is_researched(&"anchor_mode"):
		anchor_btn.text = "Anchor Mode\nResearched"
		anchor_btn.disabled = true
	elif rm.is_in_progress() and rm.current_id == &"anchor_mode":
		anchor_btn.text = "Cancel Anchor Mode (%d%%) — refund" % int(rm.get_progress() * 100.0)
		anchor_btn.add_theme_color_override("font_color", Color(1.0, 0.78, 0.32, 1.0))
		anchor_btn.tooltip_text = "Cancel the in-progress research. Microchips, fuel, and salvage spent are refunded."
		anchor_btn.pressed.connect(_on_cancel_anchor_research)
	else:
		anchor_btn.text = "[E] Anchor Mode"
		anchor_btn.tooltip_text = "Anchor Mode"
		var captured_suffix: String = cost_suffix
		anchor_btn.tooltip_builder = func() -> Control:
			var blurb: String = (
				"Crawlers gain a stationary Anchor command.\n"
				+ "Anchored: +50% armor, +25% workers, +25% range.\n"
				+ "5s deploy / 5s undeploy (vulnerable during)."
			)
			var extra: PackedStringArray = PackedStringArray()
			if captured_suffix != "":
				extra.append("")
				extra.append("Upgrade cost:%s" % captured_suffix)
			return make_styled_upgrade_tooltip("Anchor Mode", blurb, 0, 0, _ROLE_COLOR_TECH, extra)
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


func _on_cancel_anchor_research() -> void:
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	if not rm or not rm.has_method("cancel_current"):
		return
	if not rm.cancel_current():
		return
	if _resource_manager:
		if _resource_manager.has_method("add_salvage"):
			_resource_manager.add_salvage(BranchCommitManager.COMMIT_COST_SALVAGE)
		if _resource_manager.has_method("add_fuel"):
			_resource_manager.add_fuel(BranchCommitManager.COMMIT_COST_FUEL)
		if _resource_manager.has_method("add_microchips"):
			_resource_manager.add_microchips(BranchCommitManager.COMMIT_COST_MICROCHIPS)
	if _selection_manager and _selection_manager._audio:
		_selection_manager._audio.play_command()
	_last_building_id = -1


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


func _ensure_diploma_button() -> void:
	## Lazily creates the diplomacy ('diploma') toggle button that
	## opens / closes the ally gift panel. Sits to the immediate
	## left of the gift panel anchor so the player learns the
	## association at a glance. Idempotent -- safe to call every
	## panel refresh tick.
	if _diploma_btn and is_instance_valid(_diploma_btn):
		return
	_diploma_btn = Button.new()
	_diploma_btn.name = "DiplomaButton"
	_diploma_btn.text = "Allies"
	_diploma_btn.tooltip_text = "Open / close the ally gift panel."
	_diploma_btn.custom_minimum_size = Vector2(100.0, 32.0)
	_diploma_btn.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	# Sit just below where the gift panel will float open so the
	# spatial relationship is obvious.
	_diploma_btn.position = Vector2(-120.0, 60.0)
	_diploma_btn.mouse_filter = Control.MOUSE_FILTER_PASS
	_diploma_btn.pressed.connect(_on_diploma_pressed)
	add_child(_diploma_btn)


func _on_diploma_pressed() -> void:
	## Toggle the gift panel; the next _refresh_gift_panel tick
	## propagates the visibility flip and (when opening) populates
	## the per-ally rows.
	_gift_panel_open = not _gift_panel_open
	_refresh_gift_panel()


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


## Gating flag toggled by the new diplomacy ('diploma') button.
## The gift panel was opening on its own whenever an ally existed,
## which cluttered the HUD on every 2v2 match. Now it stays hidden
## until the player explicitly opens it via the diploma toggle and
## hides again on second click. The diploma button itself is built
## by _ensure_diploma_button below; it auto-spawns once when the
## player has at least one ally.
var _gift_panel_open: bool = false
var _diploma_btn: Button = null


func _refresh_gift_panel() -> void:
	if not _gift_panel:
		return
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry")
	if not registry:
		_gift_panel.visible = false
		if _diploma_btn:
			_diploma_btn.visible = false
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

	# No ally -> tear down both UIs.
	if ally_ids.is_empty():
		_gift_panel.visible = false
		_gift_panel_open = false
		if _diploma_btn:
			_diploma_btn.visible = false
		return
	# Ally present -> ensure the diploma toggle button exists +
	# is visible. Panel itself only opens on explicit click.
	_ensure_diploma_button()
	if _diploma_btn:
		_diploma_btn.visible = true
	_gift_panel.visible = _gift_panel_open
	if not _gift_panel_open:
		# Skip the row rebuild work when the panel is closed --
		# nothing to refresh visually. Still tear down stale rows
		# below so a freshly-opened panel doesn't display dead
		# allies.
		var stale_only: Array[int] = []
		for existing_id_var: Variant in _gift_rows.keys():
			if (existing_id_var as int) not in ally_ids:
				stale_only.append(existing_id_var as int)
		for sid: int in stale_only:
			var srow_dict: Dictionary = _gift_rows[sid]
			var srow: Node = srow_dict.get("root", null) as Node
			if srow and is_instance_valid(srow):
				srow.queue_free()
			_gift_rows.erase(sid)
		return

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
## Sticky warning bar for long-running countdowns (satellite impact,
## upkeep timers, etc). Lives below the transient `_alert_label` so
## flash alerts and persistent warnings can coexist without one hiding
## the other.
var _warning_label: Label = null
## Active persistent warnings keyed by caller-chosen string. Each entry
## stores {message, severity}; the HUD repaints the bar each call so
## per-second updating just re-invokes set_persistent_warning.
var _persistent_warnings: Dictionary = {}


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

	_warning_label = Label.new()
	_warning_label.name = "PersistentWarningBanner"
	_warning_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_warning_label.offset_top = 100.0
	_warning_label.offset_bottom = 132.0
	_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_warning_label.add_theme_font_size_override("font_size", 20)
	_warning_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	_warning_label.add_theme_constant_override("outline_size", 6)
	_warning_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.32, 1.0))
	_warning_label.modulate.a = 0.0
	_warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_warning_label)

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


func set_persistent_warning(key: String, message: String, severity: int = 1) -> void:
	## Show or update a sticky warning that persists until cleared.
	## The caller updates the message each tick (e.g. once per second
	## for a countdown) and the bar repaints in place. Severity picks
	## the colour: 0 = info teal, 1 = warning amber, 2 = critical red.
	if not _warning_label:
		return
	_persistent_warnings[key] = {"message": message, "severity": severity}
	_refresh_warning_label()


func clear_persistent_warning(key: String) -> void:
	## Remove a sticky warning. The bar hides automatically when the
	## last warning is cleared.
	if not _warning_label:
		return
	if _persistent_warnings.erase(key):
		_refresh_warning_label()


## Chat / cheat input. Hidden by default; Enter shows a small
## input bar at the bottom of the screen, the player types, Enter
## again submits to CheatManager and echoes the result through the
## standard alert banner.
var _chat_input: LineEdit = null
var _chat_panel: PanelContainer = null


## Two small quick-select buttons floating just above the minimap.
## Mech glyph -> select all military (combat units, no engineers /
## crawlers); engineer glyph -> jump to + select an idle engineer
## (no current build / move / attack target).
var _qs_military_btn: Button = null
var _qs_engineer_btn: Button = null


func _build_minimap_quick_select() -> void:
	var row := HBoxContainer.new()
	row.name = "MinimapQuickSelect"
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	# Minimap occupies the bottom 244x244 corner; sit the buttons in
	# the 36px strip just above it, right-aligned.
	row.offset_top = -284.0
	row.offset_bottom = -250.0
	row.offset_left = -244.0
	row.offset_right = -8.0
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_qs_military_btn = Button.new()
	_qs_military_btn.text = ""
	_qs_military_btn.custom_minimum_size = Vector2(40, 34)
	_qs_military_btn.tooltip_text = "Select all your military units (skip engineers / crawlers)."
	_qs_military_btn.pressed.connect(_on_quick_select_military)
	_attach_quick_select_glyph(_qs_military_btn, "mech")
	row.add_child(_qs_military_btn)

	_qs_engineer_btn = Button.new()
	_qs_engineer_btn.text = ""
	_qs_engineer_btn.custom_minimum_size = Vector2(40, 34)
	_qs_engineer_btn.tooltip_text = "Jump to and select an idle engineer (no current build target)."
	_qs_engineer_btn.pressed.connect(_on_quick_select_idle_engineer)
	_attach_quick_select_glyph(_qs_engineer_btn, "wrench")
	row.add_child(_qs_engineer_btn)


func _attach_quick_select_glyph(btn: Button, kind: String) -> void:
	## Adds a procedural Control child to the button that paints a
	## small role glyph (mech for military, wrench for engineer)
	## centered inside the button. Replaces the previous text label.
	var glyph := _QuickSelectGlyph.new()
	glyph.kind = kind
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(glyph)


class _QuickSelectGlyph:
	extends Control
	var kind: String = "mech"
	func _draw() -> void:
		var sz: Vector2 = size
		if sz.x <= 0.0 or sz.y <= 0.0:
			return
		var tint: Color = Color(0.95, 0.92, 0.85, 1.0)
		match kind:
			"mech":
				_draw_mech(sz, tint)
			"wrench":
				_draw_wrench(sz, tint)
	func _draw_mech(sz: Vector2, tint: Color) -> void:
		# Squat bipedal silhouette: cockpit, shoulder pad, two legs.
		var w: float = sz.x
		var h: float = sz.y
		# Cockpit -- trapezoid head.
		var head: PackedVector2Array = PackedVector2Array([
			Vector2(w * 0.30, h * 0.18),
			Vector2(w * 0.70, h * 0.18),
			Vector2(w * 0.78, h * 0.36),
			Vector2(w * 0.22, h * 0.36),
		])
		draw_colored_polygon(head, tint)
		# Shoulder slab.
		draw_rect(Rect2(Vector2(w * 0.18, h * 0.36), Vector2(w * 0.64, h * 0.18)), tint, true)
		# Twin shoulder cannons -- short bars on top of shoulders.
		draw_rect(Rect2(Vector2(w * 0.10, h * 0.28), Vector2(w * 0.10, h * 0.10)), tint, true)
		draw_rect(Rect2(Vector2(w * 0.80, h * 0.28), Vector2(w * 0.10, h * 0.10)), tint, true)
		# Legs -- two diverging stomp blocks.
		var dark: Color = Color(tint.r * 0.7, tint.g * 0.7, tint.b * 0.7, tint.a)
		draw_rect(Rect2(Vector2(w * 0.22, h * 0.55), Vector2(w * 0.20, h * 0.36)), dark, true)
		draw_rect(Rect2(Vector2(w * 0.58, h * 0.55), Vector2(w * 0.20, h * 0.36)), dark, true)
	func _draw_wrench(sz: Vector2, tint: Color) -> void:
		# Open-end wrench with the open jaw at top-left and the
		# handle running diagonally to bottom-right.
		var w: float = sz.x
		var h: float = sz.y
		# Handle as a rotated rect via a polygon.
		var cx: float = w * 0.50
		var cy: float = h * 0.50
		var ang: float = -PI / 4.0
		var hl: float = w * 0.62
		var hw: float = h * 0.16
		var dx: float = cos(ang) * hl * 0.5
		var dy: float = sin(ang) * hl * 0.5
		var nx: float = -sin(ang) * hw * 0.5
		var ny: float = cos(ang) * hw * 0.5
		var handle: PackedVector2Array = PackedVector2Array([
			Vector2(cx - dx + nx, cy - dy + ny),
			Vector2(cx + dx + nx, cy + dy + ny),
			Vector2(cx + dx - nx, cy + dy - ny),
			Vector2(cx - dx - nx, cy - dy - ny),
		])
		draw_colored_polygon(handle, tint)
		# Open-jaw head -- C shape via a circle minus a wedge cut.
		var head_c: Vector2 = Vector2(cx - dx * 1.05, cy - dy * 1.05)
		draw_circle(head_c, w * 0.20, tint)
		# Dark cutout for the jaw opening.
		var bg: Color = Color(0.10, 0.10, 0.12, 1.0)
		var bite: PackedVector2Array = PackedVector2Array([
			head_c,
			head_c + Vector2(-w * 0.22, -w * 0.04),
			head_c + Vector2(-w * 0.04, -w * 0.22),
		])
		draw_colored_polygon(bite, bg)
		draw_circle(head_c, w * 0.10, bg)


func _on_quick_select_military() -> void:
	if not _selection_manager:
		return
	if _selection_manager.has_method("select_all_player_military"):
		_selection_manager.call("select_all_player_military")


func _on_quick_select_idle_engineer() -> void:
	if not _selection_manager:
		return
	if _selection_manager.has_method("select_idle_engineer"):
		_selection_manager.call("select_idle_engineer")


func _build_chat_input() -> void:
	_chat_panel = PanelContainer.new()
	_chat_panel.name = "ChatPanel"
	_chat_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_chat_panel.offset_top = -120.0
	_chat_panel.offset_bottom = -90.0
	_chat_panel.offset_left = 320.0
	_chat_panel.offset_right = -320.0
	_chat_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.10, 0.94)
	style.border_color = Color(1.0, 0.78, 0.32, 0.85)
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_chat_panel.add_theme_stylebox_override("panel", style)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Type and press Enter..."
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_panel.add_child(_chat_input)
	add_child(_chat_panel)


func _open_chat_input() -> void:
	if not _chat_panel or not _chat_input:
		return
	_chat_panel.visible = true
	_chat_input.text = ""
	_chat_input.grab_focus()


func _close_chat_input() -> void:
	if not _chat_panel or not _chat_input:
		return
	_chat_panel.visible = false
	_chat_input.release_focus()


func _on_chat_submitted(text: String) -> void:
	_close_chat_input()
	if text.strip_edges() == "":
		return
	var cheats: Node = get_tree().current_scene.get_node_or_null("CheatManager") if get_tree() else null
	# 'cheats' (or 'help') prints the cheat catalogue. Done here in
	# the HUD layer rather than CheatManager so the listing can be
	# surfaced through the multi-line cheat-help overlay rather than
	# the single-line alert banner.
	var lower: String = text.strip_edges().to_lower()
	if lower == "cheats" or lower == "help":
		_show_cheat_help_overlay(cheats)
		return
	var msg: String = "Chat: %s" % text
	if cheats and cheats.has_method("apply_code"):
		var resp: String = cheats.call("apply_code", text)
		if resp != "":
			msg = resp
	# Surface through the alert banner so the player gets visible
	# feedback without a dedicated chat log scroll.
	_on_alert(msg, 0, Vector3.ZERO)


func _is_chat_focused() -> bool:
	## True when the chat LineEdit currently owns keyboard focus.
	## Used by the global key handlers to suppress hotkeys while the
	## player is typing.
	var vp: Viewport = get_viewport()
	if not vp:
		return false
	var owner: Control = vp.gui_get_focus_owner()
	if not owner:
		return false
	return owner == _chat_input or owner is LineEdit or owner is TextEdit


func _show_cheat_help_overlay(cheats: Node) -> void:
	## Mid-screen panel listing every cheat code + a one-line
	## description. Click anywhere to dismiss. Pulled from
	## CheatManager.cheat_catalogue() if it exists; falls back to the
	## hardcoded list below so the help still works even if the
	## catalogue accessor wasn't wired up yet.
	var entries: Array = []
	if cheats and cheats.has_method("cheat_catalogue"):
		entries = cheats.call("cheat_catalogue") as Array
	if entries.is_empty():
		entries = [
			{"code": "techcraze", "desc": "Unlock every unit + building tech gate."},
			{"code": "cashmoneten", "desc": "Fill salvage / fuel / microchips to cap."},
			{"code": "nofog", "desc": "Disable fog of war for the local player."},
		]
	var panel := PanelContainer.new()
	panel.name = "CheatHelpOverlay"
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(420, 220)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.10, 0.96)
	style.border_color = Color(1.0, 0.78, 0.32, 0.95)
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "Cheat codes — type into chat (Enter)"
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45, 1.0))
	title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title)
	for entry: Dictionary in entries:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var code_lbl := Label.new()
		code_lbl.text = entry.get("code", "") as String
		code_lbl.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0, 1.0))
		code_lbl.custom_minimum_size = Vector2(120, 0)
		row.add_child(code_lbl)
		var desc_lbl := Label.new()
		desc_lbl.text = entry.get("desc", "") as String
		desc_lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92, 1.0))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.custom_minimum_size = Vector2(260, 0)
		row.add_child(desc_lbl)
		vbox.add_child(row)
	var dismiss := Label.new()
	dismiss.text = "Press Esc or click to dismiss."
	dismiss.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65, 1.0))
	dismiss.add_theme_font_size_override("font_size", 11)
	vbox.add_child(dismiss)
	panel.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			panel.queue_free()
		elif ev is InputEventKey and (ev as InputEventKey).pressed:
			panel.queue_free()
	)
	add_child(panel)


func _input(event: InputEvent) -> void:
	# Enter (no modifiers) opens the chat input; Esc cancels it. Skip
	# if any modifier is pressed so existing Ctrl/Shift+Enter combos
	# stay free for future use.
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_ENTER and not key.ctrl_pressed and not key.shift_pressed and not key.alt_pressed:
		# If chat is already open with focus the LineEdit handles its
		# own submit; only catch the OPEN press here.
		if _chat_panel and not _chat_panel.visible:
			_open_chat_input()
			get_viewport().set_input_as_handled()
	elif key.keycode == KEY_ESCAPE and _chat_panel and _chat_panel.visible:
		_close_chat_input()
		get_viewport().set_input_as_handled()


func _refresh_warning_label() -> void:
	if not _warning_label:
		return
	if _persistent_warnings.is_empty():
		_warning_label.modulate.a = 0.0
		_warning_label.text = ""
		return
	# Pick the highest-severity entry's tint and concatenate messages
	# so multiple sticky warnings stack in one banner instead of
	# fighting for the same row.
	var top_severity: int = -1
	var lines: Array[String] = []
	for entry: Dictionary in _persistent_warnings.values():
		var sev: int = (entry.get("severity", 1) as int)
		if sev > top_severity:
			top_severity = sev
		lines.append(entry.get("message", "") as String)
	var tint: Color = Color(1.0, 0.78, 0.32, 1.0)  # warning amber default
	match top_severity:
		2:
			tint = Color(1.0, 0.4, 0.35, 1.0)
		0:
			tint = Color(0.85, 0.95, 0.85, 1.0)
	_warning_label.text = "\n".join(lines)
	_warning_label.add_theme_color_override("font_color", tint)
	_warning_label.modulate.a = 1.0


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
			# Defensive: SalvageWorker + any future "units" group entry
			# without a builder API would crash this loop. has_method
			# guard keeps the panel safe regardless of who's selected.
			if unit.has_method("get_builder") and unit.get_builder():
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
			_name_label.text = "%s — %s" % [unit.stats.get_display_name(), _role_hint_for(unit.stats)]
			var hp_pct: float = float(unit.get_total_hp()) / float(maxi(unit.stats.hp_total, 1))
			_stats_label.text = _build_unit_stat_sheet(unit, true)
			# Use HP bar to mirror the on-world HP — quick eyeball read in the panel.
			var hp_color: Color = Color(0.4, 0.95, 0.4, 0.95)
			if hp_pct < 0.5: hp_color = Color(0.95, 0.78, 0.32, 0.95)
			if hp_pct < 0.25: hp_color = Color(1.0, 0.4, 0.35, 0.95)
			_show_progress(hp_pct, hp_color)
			if unit.has_method("get_builder") and unit.get_builder():
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
	# Build-hotkey letters per visible button. Two-row layout
	# matching the on-screen 4x2 grid -- Q W E R across the top
	# row, A S D F across the bottom. Player's left hand maps
	# directly to the visual position of the building they want.
	const BUILD_HOTKEYS: Array[String] = ["Q", "W", "E", "R", "A", "S", "D", "F"]
	_visible_build_stats.clear()
	var visible_index: int = 0
	# On the Advanced tab we want the superweapon (faction-locked
	# unique structure -- Anvil's MOLOT, Sable's Echo Array) to land
	# at slot S (button 6) regardless of how many other advanced
	# buildings the player's faction has. Anvil players see only one
	# pre-superweapon advanced item beyond Q/W/E/R, which would put
	# the superweapon at A (slot 5); Sable players have Black Pylon
	# at A and the Echo Array at S already. To unify, we precompute a
	# "ghost slot" gap: when the advanced list contains a
	# superweapon and there isn't already a button between R and the
	# superweapon, we insert one disabled placeholder at slot 5 so
	# the superweapon falls on slot 6 in both factions.
	var advanced_in_buildable: Array[BuildingStatResource] = []
	for stat_iter: BuildingStatResource in buildable:
		if stat_iter and stat_iter.is_advanced:
			advanced_in_buildable.append(stat_iter)
	var superweapon_idx: int = -1
	for ai: int in advanced_in_buildable.size():
		var sw: BuildingStatResource = advanced_in_buildable[ai]
		if sw and sw.faction_lock != 0:
			superweapon_idx = ai
			break
	var advanced_ghost_slot: int = -1
	if _build_tab == "advanced" and superweapon_idx == 4:
		advanced_ghost_slot = 4  # superweapon would land at slot 5; bump it.
	for i: int in buildable.size():
		var bstat: BuildingStatResource = buildable[i]
		var is_advanced: bool = bstat.is_advanced
		var tab_match: bool = (is_advanced and _build_tab == "advanced") or (not is_advanced and _build_tab == "basic")
		if not tab_match:
			continue
		# Insert the reserved-empty placeholder right before the
		# superweapon so it lands at slot S.
		if visible_index == advanced_ghost_slot and bstat.faction_lock != 0:
			_add_build_grid_placeholder(BUILD_HOTKEYS[visible_index] if visible_index < BUILD_HOTKEYS.size() else "")
			_visible_build_stats.append(null)
			visible_index += 1
		var prereqs_ok: bool = _prerequisites_met(bstat, built_ids)
		var btn := _BuildingTooltipButton.new()
		btn.bstat = bstat
		btn.prereqs_ok = prereqs_ok
		btn.hud = self
		btn.custom_minimum_size = Vector2(124, 80)
		btn.size_flags_horizontal = Control.SIZE_FILL
		btn.size_flags_vertical = Control.SIZE_FILL
		var hotkey_letter: String = BUILD_HOTKEYS[visible_index] if visible_index < BUILD_HOTKEYS.size() else str(visible_index + 1)
		var prefix: String = "[%s]" % hotkey_letter if prereqs_ok else "[Locked]"
		_set_label_button(btn, prefix, bstat.building_name)
		# Track the visible stat under the hotkey index so the
		# SelectionManager engineer-build hotkey path picks the
		# stat actually shown on this tab (not the wrong one from
		# the unfiltered _buildable_stats list).
		_visible_build_stats.append(bstat)
		# tooltip_text stays plain so Godot still triggers the tooltip;
		# _make_custom_tooltip on the subclass below renders the actual
		# styled popup using BBCode + an opaque PanelContainer so the
		# build-menu hover info is readable + role-coloured.
		btn.tooltip_text = bstat.building_name
		btn.disabled = not prereqs_ok
		# Tint the button itself by the building's role color so the
		# whole panel can be scanned by category at a glance, mirroring
		# the role border tint used in the hover tooltip.
		_apply_role_tint_to_build_button(btn, _building_role_color(bstat), prereqs_ok)
		# Bind by stat reference, not visible index — visible_index only
		# matches `buildable[i]` while filters are stable, and we don't
		# want a hotkey collision to pick the wrong building.
		btn.pressed.connect(_on_build_button_for_stat.bind(bstat))
		_button_grid.add_child(btn)
		var chip_refs: Dictionary = _attach_cost_widget(btn, bstat.cost_salvage, bstat.cost_fuel, 0)
		_action_buttons.append({ "button": btn, "kind": "build", "stat": bstat, "locked": not prereqs_ok, "chips": chip_refs })
		visible_index += 1


func _add_build_grid_placeholder(letter: String) -> void:
	## Inserts a disabled placeholder cell into the build grid so the
	## next real button lands on the desired hotkey slot. Used to keep
	## the superweapon at slot S in factions whose pre-superweapon
	## advanced roster doesn't naturally fill slot A.
	if not _button_grid:
		return
	var ph := Button.new()
	ph.disabled = true
	ph.focus_mode = Control.FOCUS_NONE
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ph.custom_minimum_size = Vector2(124, 80)
	ph.size_flags_horizontal = Control.SIZE_FILL
	ph.size_flags_vertical = Control.SIZE_FILL
	ph.text = "[%s]\n--" % letter if letter != "" else "--"
	ph.modulate = Color(1, 1, 1, 0.35)
	_button_grid.add_child(ph)


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
	# Cheat bypass — 'techcraze' opens every gate for the player.
	var cheats: Node = get_tree().current_scene.get_node_or_null("CheatManager") if get_tree() else null
	if cheats and "tech_craze" in cheats and (cheats.get("tech_craze") as bool):
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
	# Reset column count to 4 so build/training panels have room for
	# longer unit/building names (4 columns x 2 rows = 8 slots).
	# Armory still flips to columns=1 for its branch-row layout.
	if _button_grid:
		_button_grid.columns = 4
	# Hide the build tab row when leaving build mode (production /
	# armory / turret button rebuilds reach this same path).
	if _build_tab_row and is_instance_valid(_build_tab_row):
		_build_tab_row.visible = false
	# Same for the HQ Train / Defense tab row -- only the HQ panel
	# wants it; engineer command panels and other building panels
	# leave it hidden.
	if _hq_tab_row and is_instance_valid(_hq_tab_row):
		_hq_tab_row.visible = false


## --- Affordability tint ---

func _update_button_affordability() -> void:
	if not _resource_manager or _action_buttons.is_empty():
		return
	for entry: Dictionary in _action_buttons:
		# Untyped read so a freed Object reference doesn't trip
		# "Trying to assign invalid previously freed instance" before
		# we get a chance to validity-check it. See _refresh_ability_button
		# for the detailed reasoning.
		var btn_v: Variant = entry.get("button", null)
		if btn_v == null or not is_instance_valid(btn_v):
			continue
		var btn: Button = btn_v as Button
		if not btn:
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
			lack_fuel = _resource_manager.fuel < bstat.cost_fuel
			affordable = not (lack_salvage or lack_fuel)
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
	# Read button + stat as untyped Variants first. Typed assignment
	# (`var btn: Button = entry["button"]`) errors with "Trying to
	# assign invalid previously freed instance" when the stored
	# reference points at a queue_freed Object -- happens when the
	# selected cohort gets vaporised mid-frame (superweapon strike,
	# AoE kill). Untyped read + is_instance_valid lets us bail
	# safely before the cast trips.
	var btn_v: Variant = entry["button"]
	var stat_v: Variant = entry["stat"]
	if btn_v == null or not is_instance_valid(btn_v):
		return
	if stat_v == null:
		return
	var btn: Button = btn_v as Button
	var stat: UnitStatResource = stat_v as UnitStatResource
	if not btn or not btn.is_inside_tree() or not stat:
		return
	# Same defensive read for the units list -- typed for-loop
	# iteration assigns each entry to a typed local, which errors on
	# a freed reference. Walk the array as Variants and skip any
	# freed members before doing typed work on them.
	var units_v: Variant = entry.get("units", [])
	var units: Array = units_v as Array if units_v is Array else []
	var any_ready: bool = false
	var min_cd: float = INF
	for raw in units:
		if raw == null or not is_instance_valid(raw):
			continue
		var u: Node = raw as Node
		if not u:
			continue
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
	## dict (does nothing). Handles BOTH the legacy ColorRect swatch
	## and the new ResourceIcon (which exposes its tint via the
	## `tint` property + queues a redraw).
	if chip.is_empty():
		return
	var swatch_node: Node = chip.get("swatch", null) as Node
	var lbl: Label = chip.get("label", null) as Label
	var base_color: Color = chip.get("color", Color.WHITE) as Color
	if not is_instance_valid(lbl):
		return
	var paint: Color = COLOR_AFFORD_BAD if lacking else base_color
	if is_instance_valid(swatch_node):
		if swatch_node is ResourceIcon:
			(swatch_node as ResourceIcon).tint = paint
			(swatch_node as ResourceIcon).queue_redraw()
		elif swatch_node is ColorRect:
			(swatch_node as ColorRect).color = paint
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
	##
	## When asking about an air armor class, only weapons whose
	## engages_air() is true contribute -- a Hound's AT-missile
	## secondary doesn't pad the DPS Air number even though its AA
	## tag has a token air multiplier. Mirrors the per-weapon
	## firing gate in CombatComponent so what you see is what fires.
	if not stat:
		return 0.0
	var is_air_query: bool = (armor_class == &"light_air" or armor_class == &"heavy_air")
	var dps: float = 0.0
	var weapons: Array[WeaponResource] = []
	if stat.primary_weapon:
		weapons.append(stat.primary_weapon)
	if stat.secondary_weapon:
		weapons.append(stat.secondary_weapon)
	for weapon: WeaponResource in weapons:
		if is_air_query and not weapon.engages_air():
			continue
		var raw: float = _weapon_dps(weapon) * float(stat.squad_size)
		# Mirrors combat: honour per-weapon per-armor-class overrides.
		var role_mod: float = weapon.get_role_mult_for(armor_class)
		var armor_red: float = CombatTables.get_armor_reduction(armor_class)
		# Per-weapon air scalar -- mirrors the combat path so the
		# displayed Air DPS matches actual output.
		var air_mult: float = weapon.air_damage_mult if is_air_query else 1.0
		dps += raw * role_mod * (1.0 - armor_red) * air_mult
	# Autocast ability contribution -- total damage / cooldown,
	# gated by ability_autocast_target so a Hammerhead Bomber's
	# Carpet Bomb (ground-only) doesn't pad DPS Air, and an
	# Escort's AA Barrage doesn't pad DPS Gnd. Manual abilities
	# (ability_autocast = false) don't contribute -- the player
	# chooses when to fire those.
	if stat.ability_autocast and stat.ability_autocast_damage > 0 and stat.ability_cooldown > 0.0:
		var ab_target: int = stat.ability_autocast_target
		var hits_this_class: bool = (
			ab_target == 2
			or (ab_target == 0 and not is_air_query)
			or (ab_target == 1 and is_air_query)
		)
		if hits_this_class:
			dps += float(stat.ability_autocast_damage) / stat.ability_cooldown
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
		r = maxf(r, stat.primary_weapon.resolved_range())
	if stat.secondary_weapon:
		r = maxf(r, stat.secondary_weapon.resolved_range())
	return r


## Star-rating renderer. Maps a numeric stat value across a 30-half-step
## scale stretched over three colour-coded tiers: bronze (steps 1..10) /
## silver (11..20) / gold (21..30). Worse-than-the-low-anchor reads as
## empty stars; better-than-the-high-anchor caps at 5 gold. Inverted
## stats (rate-of-fire seconds where lower = faster) flip the mapping.
##
## Returned BBCode is meant to drop into the existing _stat_chip
## row layout; the chip-side label (e.g. "Speed") still comes from
## _stat_chip's first arg.
const STAR_TIER_BRONZE_HEX: String = "c0703a"
const STAR_TIER_SILVER_HEX: String = "d8dadf"
const STAR_TIER_GOLD_HEX: String = "ffc850"


func _render_stars(value: float, low: float, high: float, inverted: bool = false) -> String:
	if high == low:
		return ""
	var ratio: float
	if inverted:
		ratio = clampf((high - value) / (high - low), 0.0, 1.0)
	else:
		ratio = clampf((value - low) / (high - low), 0.0, 1.0)
	var total_half: int = roundi(ratio * 30.0)
	if total_half <= 0:
		# Below the low anchor -- nothing to brag about, render 5
		# empty bronze slots so the row width stays consistent.
		return "[color=#%s]%s[/color]" % [STAR_TIER_BRONZE_HEX, "☆☆☆☆☆"]
	var color_hex: String
	var tier_half: int
	if total_half <= 10:
		color_hex = STAR_TIER_BRONZE_HEX
		tier_half = total_half
	elif total_half <= 20:
		color_hex = STAR_TIER_SILVER_HEX
		tier_half = total_half - 10
	else:
		color_hex = STAR_TIER_GOLD_HEX
		tier_half = total_half - 20
	var full: int = tier_half / 2
	var has_half: bool = (tier_half % 2) == 1
	var stars: String = "★".repeat(full)
	if has_half:
		stars += "½"
	var empties: int = 5 - full - (1 if has_half else 0)
	if empties > 0:
		stars += "☆".repeat(empties)
	return "[color=#%s]%s[/color]" % [color_hex, stars]


## Per-stat anchor table for _render_stars. The low / high pair
## defines what "0 stars (bronze empty)" and "5 gold" map to. The
## anchors are deliberately wider than the tier table's min/max so
## a "moderate" weapon doesn't bottom out at 1 star -- it should
## land roughly mid-silver, with very_low as the bronze region and
## extreme as the gold region.
const STAR_ANCHOR_DAMAGE: Vector2 = Vector2(5.0, 150.0)
const STAR_ANCHOR_RANGE: Vector2 = Vector2(2.0, 60.0)
## ROF is seconds-between-shots; lower = better. Anchored to the
## slowest (single = 4.0s) and fastest (continuous = 0.15s) tiers.
const STAR_ANCHOR_ROF: Vector2 = Vector2(4.0, 0.15)
const STAR_ANCHOR_SPEED: Vector2 = Vector2(0.0, 16.0)
const STAR_ANCHOR_SIGHT: Vector2 = Vector2(8.0, 50.0)
const STAR_ANCHOR_ARMOR: Vector2 = Vector2(0.0, 0.5)


func _stars_for_speed(value: float) -> String:
	return _render_stars(value, STAR_ANCHOR_SPEED.x, STAR_ANCHOR_SPEED.y)


func _stars_for_sight(value: float) -> String:
	return _render_stars(value, STAR_ANCHOR_SIGHT.x, STAR_ANCHOR_SIGHT.y)


func _stars_for_damage(value: float) -> String:
	return _render_stars(value, STAR_ANCHOR_DAMAGE.x, STAR_ANCHOR_DAMAGE.y)


func _stars_for_range(value: float) -> String:
	return _render_stars(value, STAR_ANCHOR_RANGE.x, STAR_ANCHOR_RANGE.y)


func _stars_for_rof(seconds_between_shots: float) -> String:
	return _render_stars(seconds_between_shots, STAR_ANCHOR_ROF.x, STAR_ANCHOR_ROF.y, true)


func _stars_for_armor(reduction_0_to_1: float) -> String:
	return _render_stars(reduction_0_to_1, STAR_ANCHOR_ARMOR.x, STAR_ANCHOR_ARMOR.y)


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
	var dmg: float = float(weapon.resolved_damage())
	var rof: float = weapon.resolved_rof_seconds()
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
	lines.append("Class: %s    Armor: %s    Speed %.0f u/s    Sight %.0fu" % [
		str(stat.unit_class).capitalize(),
		str(stat.armor_class).capitalize(),
		stat.resolved_speed(),
		stat.resolved_sight_radius(),
	])
	lines.append("HP %d   Squad %d   Pop %d   Range %.0fu" % [
		stat.hp_total, stat.squad_size, stat.population,
		_max_weapon_range(stat),
	])
	lines.append("Cost  %dS / %dF   Build %.1fs" % [
		stat.cost_salvage, stat.cost_fuel, stat.build_time
	])
	if stat.can_target_air():
		lines.append("DPS  %.0f vs Ground / %.0f vs Air" % [
			_compute_dps_vs(stat, &"medium"),
			_compute_dps_vs(stat, &"light_air"),
		])
	else:
		lines.append("DPS  %.0f vs Ground" % _compute_dps_vs(stat, &"medium"))
	if stat.primary_weapon:
		var pw: WeaponResource = stat.primary_weapon
		lines.append("Primary: %s — %s, %d dmg, %.0fu, %.2fs cd, Acc %d%%" % [
			pw.weapon_name if pw.weapon_name else "Cannon",
			str(pw.role_tag),
			pw.resolved_damage(),
			pw.resolved_range(),
			pw.resolved_rof_seconds(),
			int(pw.base_accuracy * 100.0),
		])
	if stat.secondary_weapon:
		lines.append("Secondary: %s — %s, Acc %d%%" % [
			stat.secondary_weapon.weapon_name if stat.secondary_weapon.weapon_name else "Backup",
			str(stat.secondary_weapon.role_tag),
			int(stat.secondary_weapon.base_accuracy * 100.0),
		])
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
	if stat.cost_fuel > 0:
		lines.append("HP %d   Cost %dS / %dF   Build %.1fs" % [stat.hp, stat.cost_salvage, stat.cost_fuel, stat.build_time])
	else:
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
		&"headquarters": return "Command"
		&"basic_foundry": return "Production"
		&"advanced_foundry": return "Production"
		&"basic_generator": return "Power"
		&"advanced_generator": return "Power"
		&"basic_armory": return "Tech"
		&"advanced_armory": return "Tech"
		&"salvage_yard": return "Economy"
		&"gun_emplacement": return "Defense"
		&"gun_emplacement_basic": return "Defense"
		&"aerodrome": return "Production"
		&"sam_site": return "Defense"
		&"black_pylon": return "Tech"
	return "Structure"


## Per-role colours used by both the small role-hint header and
## the build-button tooltip border. Keep distinct enough that the
## category reads at a glance without mousing over.
const _ROLE_COLOR_PRODUCTION: Color = Color(1.00, 0.55, 0.18, 1.0) # salvage orange
const _ROLE_COLOR_TECH: Color       = Color(0.78, 0.45, 1.00, 1.0) # violet
const _ROLE_COLOR_DEFENSE: Color    = Color(0.95, 0.30, 0.25, 1.0) # warm red
const _ROLE_COLOR_POWER: Color      = Color(1.00, 0.95, 0.20, 1.0) # bright yellow
const _ROLE_COLOR_ECONOMY: Color    = Color(0.50, 0.92, 0.55, 1.0) # bright green
const _ROLE_COLOR_COMMAND: Color    = Color(0.85, 0.85, 0.95, 1.0) # cool white


func _apply_role_tint_to_build_button(btn: Button, role_color: Color, enabled: bool) -> void:
	## Tints a build-menu button so the whole panel reads at a glance
	## by category. Background is a desaturated dark of the role color
	## (visible but not loud), border is the saturated role color, and
	## the hover state brightens both for feedback. Locked buttons use
	## a flat dark grey + dim border so the player can still see which
	## category the locked tile belongs to without it shouting.
	var dim: float = 0.92 if enabled else 0.65
	var bg: Color = Color(
		role_color.r * 0.20,
		role_color.g * 0.20,
		role_color.b * 0.20,
		1.0,
	)
	var hover_bg: Color = Color(
		role_color.r * 0.32,
		role_color.g * 0.32,
		role_color.b * 0.32,
		1.0,
	)
	var border: Color = Color(role_color.r, role_color.g, role_color.b, dim)
	var normal := StyleBoxFlat.new()
	normal.bg_color = bg
	normal.border_color = border
	normal.border_width_top = 2
	normal.border_width_bottom = 2
	normal.border_width_left = 2
	normal.border_width_right = 2
	normal.corner_radius_top_left = 4
	normal.corner_radius_top_right = 4
	normal.corner_radius_bottom_left = 4
	normal.corner_radius_bottom_right = 4
	normal.content_margin_left = 6
	normal.content_margin_right = 6
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = hover_bg
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = bg.darkened(0.15)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.10, 0.10, 0.12, 1.0)
	disabled.border_color = Color(role_color.r, role_color.g, role_color.b, 0.45)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("disabled", disabled)


## Per-class training-button tints. Ground vs Air share base hues so
## the panel reads air-vs-ground at a glance; each class gets a
## distinct shade so lights / mediums / heavies / supports are
## still individually distinguishable.
const _TRAIN_COLOR_ECONOMY: Color       = Color(0.45, 0.92, 0.55, 1.0)  # bright green
const _TRAIN_COLOR_LIGHT_GROUND: Color  = Color(0.40, 0.78, 1.00, 1.0)  # cool blue
const _TRAIN_COLOR_MEDIUM_GROUND: Color = Color(0.95, 0.78, 0.30, 1.0)  # amber
const _TRAIN_COLOR_HEAVY_GROUND: Color  = Color(1.00, 0.45, 0.25, 1.0)  # warm orange
const _TRAIN_COLOR_SUPPORT_GROUND: Color = Color(0.78, 0.45, 1.00, 1.0) # violet
const _TRAIN_COLOR_LIGHT_AIR: Color     = Color(0.55, 0.92, 1.00, 1.0)  # paler cyan
const _TRAIN_COLOR_MEDIUM_AIR: Color    = Color(1.00, 0.92, 0.50, 1.0)  # paler amber
const _TRAIN_COLOR_HEAVY_AIR: Color     = Color(1.00, 0.65, 0.42, 1.0)  # paler orange
const _TRAIN_COLOR_SUPPORT_AIR: Color   = Color(0.85, 0.62, 1.00, 1.0)  # paler violet


func _train_button_role_color(stat: UnitStatResource) -> Color:
	## Picks the train-button tint by unit category. Engineers /
	## crawlers are 'economy' regardless of class. Support is detected
	## via repair_rate / mesh_provider_radius / ability_name on units
	## that aren't already classified by class. Falls back to the
	## medium-ground tint for anything that doesn't match.
	if not stat:
		return _TRAIN_COLOR_MEDIUM_GROUND
	# Economy first -- engineers + crawlers always read as econ.
	if stat.unit_class == &"engineer" or stat.unit_class == &"crawler" or stat.is_crawler:
		return _TRAIN_COLOR_ECONOMY
	# Support: dedicated caster / repair / aura units. Detected by
	# carrying a Mesh aura, a heal rate, or an active ability without
	# being one of the standard combat classes.
	var support: bool = (
		stat.mesh_provider_radius > 0.0
		or stat.repair_rate > 0.0
	)
	var is_air: bool = stat.is_aircraft or stat.unit_class == &"aircraft"
	if is_air:
		if support:
			return _TRAIN_COLOR_SUPPORT_AIR
		# Air tier by HP -- there's no light / medium / heavy enum
		# on aircraft so we bucket by total HP instead.
		if stat.hp_total >= 1500:
			return _TRAIN_COLOR_HEAVY_AIR
		if stat.hp_total >= 800:
			return _TRAIN_COLOR_MEDIUM_AIR
		return _TRAIN_COLOR_LIGHT_AIR
	# Ground.
	if support:
		return _TRAIN_COLOR_SUPPORT_GROUND
	match stat.unit_class:
		&"light":
			return _TRAIN_COLOR_LIGHT_GROUND
		&"medium":
			return _TRAIN_COLOR_MEDIUM_GROUND
		&"heavy":
			return _TRAIN_COLOR_HEAVY_GROUND
	return _TRAIN_COLOR_MEDIUM_GROUND


func _building_role_color(stat: BuildingStatResource) -> Color:
	if not stat:
		return _ROLE_COLOR_COMMAND
	match _building_role_hint(stat):
		"Production": return _ROLE_COLOR_PRODUCTION
		"Tech":       return _ROLE_COLOR_TECH
		"Defense":    return _ROLE_COLOR_DEFENSE
		"Power":      return _ROLE_COLOR_POWER
		"Economy":    return _ROLE_COLOR_ECONOMY
		"Command":    return _ROLE_COLOR_COMMAND
	return _ROLE_COLOR_COMMAND


func _local_player_faction() -> int:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "player_faction" in settings:
		return settings.get("player_faction") as int
	return 0


func _building_description(id: StringName) -> String:
	## Short, building-focused blurb. Strips strategy advice and
	## cross-faction unit name-drops so the tooltip reads as "what
	## is this thing" rather than "how should I play this game".
	## Faction-specific lines pull from _local_player_faction so the
	## blurb only mentions units the local player can actually train
	## here.
	match id:
		&"headquarters":
			return "Command building. Trains Engineers and Salvage Crawlers. Grants +25 population cap. Anvil HQs can buy defensive upgrades."
		&"basic_foundry":
			if _local_player_faction() == 1:
				return "Light-mech assembly line. Trains Specters and Jackals. Grants +25 population cap."
			return "Light-mech assembly line. Trains Rooks and Hounds. Grants +25 population cap."
		&"advanced_foundry":
			if _local_player_faction() == 1:
				return "Heavy-mech foundry. Trains Harbingers; Adv Armory unlocks Pulsefont and Courier Tank. Grants +25 population cap."
			return "Heavy-mech foundry. Trains Bulwarks; Adv Armory unlocks Forgemaster. Grants +25 population cap."
		&"basic_generator":
			return "Power source. Adds capacity so additional production buildings stay at full output."
		&"advanced_generator":
			return "Reactor -- 75 power for less salvage-per-watt than two generators. Requires Basic Foundry and costs fuel."
		&"basic_armory":
			return "Branch-upgrade workshop for baseline units. Commits are irreversible."
		&"advanced_armory":
			return "Unlocks the gated unit slots at Advanced Foundry and Aerodrome, and hosts their branch upgrades."
		&"salvage_yard":
			return "Stationary harvester. Pulls salvage from wrecks inside its work radius."
		&"gun_emplacement":
			return "Anvil mode-switchable emplacement: Balanced / Anti-Light / Anti-Heavy. Ground only. +15% HP / damage vs the baseline turret."
		&"gun_emplacement_basic":
			return "Fixed-mode ground turret. No profile swap, no air targeting."
		&"aerodrome":
			if _local_player_faction() == 1:
				return "Aircraft hangar. Trains Switchblade; Adv Armory unlocks Fang, Black Pylon unlocks Wraith. Grants +25 population cap."
			return "Aircraft hangar. Trains Phalanx; Adv Armory unlocks Hammerhead. Grants +25 population cap."
		&"sam_site":
			return "Anti-air missile rack. Strong against aircraft, near-zero against ground."
		&"black_pylon":
			return "Sable Mesh anchor. Boosts nearby Sable units' accuracy/reload and unlocks the Wraith bomber."
	return ""


func make_styled_building_tooltip(bstat: BuildingStatResource, prereqs_ok: bool) -> Control:
	## Custom build-button tooltip popup. Returns a PanelContainer with
	## opaque dark bg + role-coloured border, holding a RichTextLabel
	## that renders BBCode-tagged content (role hint coloured by
	## category, cost figures coloured by resource). Replaces the
	## engine default tooltip which is semi-transparent + plain text.
	if not bstat:
		return null
	var role_color: Color = _building_role_color(bstat)
	var role: String = _building_role_hint(bstat)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 0.97)
	style.border_color = role_color
	style.border_color.a = 0.95
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.custom_minimum_size = Vector2(260, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("default_color", Color(0.92, 0.92, 0.95, 1.0))

	var role_hex: String = "%02x%02x%02x" % [
		int(role_color.r * 255.0), int(role_color.g * 255.0), int(role_color.b * 255.0),
	]
	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b]%s[/b]    [color=#%s]%s[/color]" % [bstat.building_name, role_hex, role])

	# Stat line — costs colour-tagged so salvage / fuel chips read
	# without a legend.
	var cost_str: String = "[color=#ff8c2e]%dS[/color]" % bstat.cost_salvage
	if bstat.cost_fuel > 0:
		cost_str += " / [color=#4cd0ff]%dF[/color]" % bstat.cost_fuel
	var stat_line: String = "HP %d   %s   Build %.1fs" % [bstat.hp, cost_str, bstat.build_time]
	if bstat.power_production > 0:
		stat_line += "   [color=#fff033]+%d Power[/color]" % bstat.power_production
	elif bstat.power_consumption > 0:
		stat_line += "   [color=#fff033]-%d Power[/color]" % bstat.power_consumption
	lines.append(stat_line)

	var blurb: String = _building_description(bstat.building_id)
	if not blurb.is_empty():
		lines.append("")
		lines.append(blurb)

	if not prereqs_ok and not bstat.prerequisites.is_empty():
		var pretty: PackedStringArray = PackedStringArray()
		for req_v: Variant in bstat.prerequisites:
			pretty.append(_pretty_id(StringName(req_v)))
		lines.append("")
		lines.append("[color=#ff6e6e]Requires: %s[/color]" % ", ".join(pretty))

	label.text = "\n".join(lines)
	panel.add_child(label)
	return panel


class _BuildingTooltipButton extends Button:
	## Build-menu button subclass with a custom tooltip popup. Plain
	## tooltip_text would render as a semi-transparent grey label;
	## we want an opaque, role-coloured, BBCode-rich popup instead.
	## Holds back-references the parent HUD reads in its tooltip
	## builder.
	var bstat: BuildingStatResource = null
	var prereqs_ok: bool = true
	var hud: Node = null

	func _make_custom_tooltip(_for_text: String) -> Control:
		if hud and hud.has_method("make_styled_building_tooltip"):
			return hud.call("make_styled_building_tooltip", bstat, prereqs_ok) as Control
		return null


class _StyledTooltipButton extends Button:
	## Generic Button subclass that delegates _make_custom_tooltip to a
	## Callable. Used by every non-build-menu button that wants the same
	## opaque, BBCode-rich tooltip treatment (HQ upgrades, branch
	## upgrades, etc.) without each one needing its own subclass.
	## Builder receives no args -- bake context into the Callable.
	var tooltip_builder: Callable = Callable()

	func _make_custom_tooltip(_for_text: String) -> Control:
		if tooltip_builder.is_valid():
			return tooltip_builder.call() as Control
		return null


func make_styled_upgrade_tooltip(title: String, blurb: String, cost_s: int, cost_f: int, accent: Color, lines_extra: PackedStringArray = PackedStringArray()) -> Control:
	## Mirror of make_styled_building_tooltip but for upgrade-style
	## buttons (HQ Plating / Battery, branch commits, anchor-mode
	## research, etc.). Same opaque PanelContainer + BBCode body, but
	## no role hint -- callers pass an accent colour to tint the
	## border + title underline.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 0.97)
	style.border_color = accent
	style.border_color.a = 0.95
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.custom_minimum_size = Vector2(260, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("default_color", Color(0.92, 0.92, 0.95, 1.0))

	var accent_hex: String = "%02x%02x%02x" % [
		int(accent.r * 255.0), int(accent.g * 255.0), int(accent.b * 255.0),
	]
	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b][color=#%s]%s[/color][/b]" % [accent_hex, title])
	# Cost line if any.
	var cost_str: String = ""
	if cost_s > 0:
		cost_str = "[color=#ff8c2e]%dS[/color]" % cost_s
	if cost_f > 0:
		if cost_str != "":
			cost_str += " / [color=#4cd0ff]%dF[/color]" % cost_f
		else:
			cost_str = "[color=#4cd0ff]%dF[/color]" % cost_f
	if cost_str != "":
		lines.append("Cost: " + cost_str)
	if not blurb.is_empty():
		lines.append("")
		lines.append(blurb)
	for extra: String in lines_extra:
		lines.append(extra)

	label.text = "\n".join(lines)
	panel.add_child(label)
	return panel
