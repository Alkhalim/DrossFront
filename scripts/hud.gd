class_name HUD
extends Control
## Prototype HUD: resource counters, selection info, production buttons.

var _resource_manager: ResourceManager = null
var _selection_manager: SelectionManager = null

## Track what we're showing to avoid rebuilding buttons every frame.
var _last_building_id: int = -1
var _last_unit_ids: Array[int] = []
var _showing_build_buttons: bool = false

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


func _update_building_panel(building: Building) -> void:
	var bid: int = building.get_instance_id()

	# Only rebuild buttons when selection changes
	if bid != _last_building_id:
		_last_building_id = bid
		_last_unit_ids.clear()
		_showing_build_buttons = false
		_rebuild_production_buttons(building)

	# Update dynamic text every frame
	if not building.is_constructed:
		_name_label.text = "%s (Under Construction)" % building.stats.building_name
		_stats_label.text = "Construction: %d%%" % int(building.get_construction_percent() * 100.0)
		_queue_label.text = ""
		return

	_name_label.text = building.stats.building_name

	var stats_text: String = "HP: %d / %d" % [building.current_hp, building.stats.hp]
	if building.stats.power_production > 0:
		stats_text += "  |  Power: +%d" % building.stats.power_production
	elif building.stats.power_consumption > 0:
		stats_text += "  |  Power: -%d" % building.stats.power_consumption
	_stats_label.text = stats_text

	# Salvage yard: show worker info
	var yard: Node = building.get_node_or_null("SalvageYardComponent")
	if yard and yard.has_method("get_worker_count"):
		var count: int = yard.get_worker_count()
		var max_w: int = yard.get_max_workers()
		var spawn_pct: float = yard.get_spawn_progress()
		var queue_text: String = "Workers: %d / %d" % [count, max_w]
		if count < max_w:
			queue_text += "  |  Next worker: %d%%" % int(spawn_pct * 100.0)
		_queue_label.text = queue_text
	elif building.get_queue_size() > 0:
		_queue_label.text = "Queue: %d  |  Progress: %d%%" % [
			building.get_queue_size(),
			int(building.get_build_progress_percent() * 100.0)
		]
	else:
		_queue_label.text = ""


func _rebuild_production_buttons(building: Building) -> void:
	_clear_buttons()

	if building.stats.producible_units.is_empty():
		_action_label.text = "No production"
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


func _update_unit_panel(units: Array[Unit]) -> void:
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

		# Check if any selected unit is an engineer
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

	if units.size() == 1:
		var unit: Unit = units[0]
		if unit.stats:
			_name_label.text = unit.stats.unit_name
			_stats_label.text = "%s  |  Speed: %s  |  Armor: %s" % [
				str(unit.stats.unit_class),
				str(unit.stats.speed_tier),
				str(unit.stats.armor_class)
			]
			if unit.get_builder():
				_action_label.text = "Build: [1-6] Place structure"
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

	_action_label.text = "Build:"
	var buildable: Array[BuildingStatResource] = _selection_manager.get_buildable_stats()
	for i: int in buildable.size():
		var bstat: BuildingStatResource = buildable[i]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(75, 36)
		btn.text = "[%d] %s\n%dS" % [i + 1, bstat.building_name, bstat.cost_salvage]
		btn.pressed.connect(_on_build_button.bind(i))
		_button_grid.add_child(btn)


func _on_build_button(index: int) -> void:
	if not _selection_manager:
		return
	var buildable: Array[BuildingStatResource] = _selection_manager.get_buildable_stats()
	if index < buildable.size():
		_selection_manager.start_build_placement(buildable[index])


func _clear_buttons() -> void:
	for child: Node in _button_grid.get_children():
		child.queue_free()
