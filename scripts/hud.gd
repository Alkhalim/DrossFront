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

	_pause_overlay = overlay


func _on_volume_changed(db: float) -> void:
	# 0 is the master bus — feed the dB value through directly. -40 dB ≈ silent,
	# 0 dB is the project default, +6 dB pushes a little hotter.
	AudioServer.set_bus_volume_db(0, db)


func _process(delta: float) -> void:
	_match_time += delta
	_update_resource_display()
	_update_selection_display()
	_update_button_affordability()


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

	if building and building.stats:
		_bottom_panel.visible = true
		_update_building_panel(building)
	elif not units.is_empty():
		_bottom_panel.visible = true
		_update_unit_panel(units)
	else:
		_bottom_panel.visible = false
		_last_building_id = -1
		_last_unit_ids.clear()
		_showing_build_buttons = false
		if _progress_bar:
			_progress_bar.visible = false


func _update_building_panel(building: Building) -> void:
	var bid: int = building.get_instance_id()

	# Only rebuild buttons when selection changes
	if bid != _last_building_id:
		_last_building_id = bid
		_last_unit_ids.clear()
		_showing_build_buttons = false
		if building.stats.building_id == &"basic_armory":
			_rebuild_armory_buttons(building)
		else:
			_rebuild_production_buttons(building)

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
		_queue_label.text = "Queue  %d" % building.get_queue_size()
		_show_progress(building.get_build_progress_percent(), Color(0.4, 0.85, 1.0, 0.95))
	else:
		_queue_label.text = ""
		_hide_progress()


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


func _on_branch_commit(base_stats: UnitStatResource, branch_stats: UnitStatResource, branch_name: String) -> void:
	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if bcm and bcm.has_method("start_commit"):
		bcm.start_commit(base_stats, branch_stats, branch_name)
		_last_building_id = -1


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
