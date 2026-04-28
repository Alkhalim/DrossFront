class_name HUD
extends Control
## Prototype HUD: resource counters, selection info, production buttons.

var _resource_manager: ResourceManager = null
var _selection_manager: SelectionManager = null

## Track what we're showing to avoid rebuilding buttons every frame.
var _last_selected_building: Building = null
var _last_selected_unit_count: int = -1

@onready var _salvage_label: Label = $TopBar/SalvageLabel as Label
@onready var _fuel_label: Label = $TopBar/FuelLabel as Label
@onready var _power_label: Label = $TopBar/PowerLabel as Label
@onready var _pop_label: Label = $TopBar/PopLabel as Label
@onready var _name_label: Label = $BottomPanel/HBox/InfoSection/NameLabel as Label
@onready var _stats_label: Label = $BottomPanel/HBox/InfoSection/StatsLabel as Label
@onready var _queue_label: Label = $BottomPanel/HBox/InfoSection/QueueLabel as Label
@onready var _action_label: Label = $BottomPanel/HBox/ActionSection/ActionLabel as Label
@onready var _button_grid: GridContainer = $BottomPanel/HBox/ActionSection/ButtonGrid as GridContainer
@onready var _bottom_panel: PanelContainer = $BottomPanel as PanelContainer


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	_resource_manager = scene.get_node_or_null("ResourceManager") as ResourceManager
	_selection_manager = scene.get_node_or_null("SelectionManager") as SelectionManager
	_bottom_panel.visible = false


func _process(_delta: float) -> void:
	_update_resource_display()
	_update_selection_display()


func _update_resource_display() -> void:
	if not _resource_manager:
		return
	_salvage_label.text = "Salvage: %d" % _resource_manager.salvage
	_fuel_label.text = "Fuel: %d / %d" % [_resource_manager.fuel, _resource_manager.fuel_cap]

	var efficiency: float = _resource_manager.get_power_efficiency()
	var eff_str: String = ""
	if efficiency < 1.0:
		eff_str = " (%d%%)" % int(efficiency * 100.0)
	_power_label.text = "Power: %d / %d%s" % [
		_resource_manager.power_production,
		_resource_manager.power_consumption,
		eff_str
	]
	_pop_label.text = "Pop: %d / %d" % [_resource_manager.population, ResourceManager.POPULATION_CAP]


func _update_selection_display() -> void:
	if not _selection_manager:
		_bottom_panel.visible = false
		return

	var building: Building = _selection_manager.get_selected_building()
	var unit_count: int = _selection_manager._selected_units.size()

	if building and building.stats:
		_show_building_panel(building)
	elif unit_count > 0:
		_show_unit_panel()
	else:
		_bottom_panel.visible = false
		_last_selected_building = null
		_last_selected_unit_count = -1


func _show_building_panel(building: Building) -> void:
	_bottom_panel.visible = true

	# Rebuild buttons only when selection changes
	if building != _last_selected_building:
		_last_selected_building = building
		_last_selected_unit_count = -1
		_rebuild_building_buttons(building)

	# Update dynamic info every frame
	_name_label.text = building.stats.building_name
	_stats_label.text = "HP: %d / %d" % [building.current_hp, building.stats.hp]

	if building.stats.power_production > 0:
		_stats_label.text += "  |  Power: +%d" % building.stats.power_production
	elif building.stats.power_consumption > 0:
		_stats_label.text += "  |  Power: -%d" % building.stats.power_consumption

	if building.get_queue_size() > 0:
		_queue_label.text = "Queue: %d  |  Progress: %d%%" % [
			building.get_queue_size(),
			int(building.get_build_progress_percent() * 100.0)
		]
	else:
		_queue_label.text = ""


func _rebuild_building_buttons(building: Building) -> void:
	# Clear old buttons
	for child: Node in _button_grid.get_children():
		child.queue_free()

	if building.stats.producible_units.is_empty():
		_action_label.text = ""
		return

	_action_label.text = "Train Units:"
	var hotkeys: Array[String] = ["Q", "W", "E", "R", "T"]

	for i: int in building.stats.producible_units.size():
		var unit_stat: UnitStatResource = building.stats.producible_units[i]
		var hotkey: String = hotkeys[i] if i < hotkeys.size() else str(i + 1)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(75, 36)

		var cost_text: String = "%dS" % unit_stat.cost_salvage
		if unit_stat.cost_fuel > 0:
			cost_text += " %dF" % unit_stat.cost_fuel

		btn.text = "[%s] %s\n%s" % [hotkey, unit_stat.unit_name, cost_text]
		btn.pressed.connect(_on_production_button.bind(i))
		_button_grid.add_child(btn)


func _on_production_button(index: int) -> void:
	if _selection_manager:
		_selection_manager.queue_unit_at_building(index)


func _show_unit_panel() -> void:
	_bottom_panel.visible = true
	_last_selected_building = null

	var units: Array[Unit] = _selection_manager._selected_units

	if units.size() != _last_selected_unit_count:
		_last_selected_unit_count = units.size()
		# Clear production buttons
		for child: Node in _button_grid.get_children():
			child.queue_free()

	_queue_label.text = ""

	if units.size() == 1:
		var unit: Unit = units[0]
		if unit.stats:
			_name_label.text = unit.stats.unit_name
			_stats_label.text = "%s  |  Speed: %s  |  Armor: %s" % [
				unit.stats.unit_class,
				unit.stats.speed_tier,
				unit.stats.armor_class
			]
			if unit.get_builder():
				_action_label.text = "Build: [1-6] Place structure"
				_rebuild_build_buttons()
			else:
				_action_label.text = ""
		else:
			_name_label.text = "Unit"
			_stats_label.text = ""
			_action_label.text = ""
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

		# Check if any selected unit is an engineer
		var has_builder: bool = false
		for unit: Unit in units:
			if unit.get_builder():
				has_builder = true
				break
		if has_builder:
			_action_label.text = "Build: [1-6] Place structure"
			_rebuild_build_buttons()
		else:
			_action_label.text = ""


func _rebuild_build_buttons() -> void:
	for child: Node in _button_grid.get_children():
		child.queue_free()

	if not _selection_manager:
		return

	var buildable: Array[BuildingStatResource] = _selection_manager._buildable_stats
	for i: int in buildable.size():
		var bstat: BuildingStatResource = buildable[i]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(75, 36)
		btn.text = "[%d] %s\n%dS" % [i + 1, bstat.building_name, bstat.cost_salvage]
		btn.pressed.connect(_on_build_button.bind(i))
		_button_grid.add_child(btn)


func _on_build_button(index: int) -> void:
	if _selection_manager and index < _selection_manager._buildable_stats.size():
		_selection_manager.start_build_placement(_selection_manager._buildable_stats[index])
