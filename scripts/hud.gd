class_name HUD
extends Control
## Minimal prototype HUD: resource counters, selected unit/building info, hotkey hints.

var _resource_manager: ResourceManager = null
var _selection_manager: SelectionManager = null

@onready var _salvage_label: Label = $TopBar/SalvageLabel as Label
@onready var _fuel_label: Label = $TopBar/FuelLabel as Label
@onready var _power_label: Label = $TopBar/PowerLabel as Label
@onready var _pop_label: Label = $TopBar/PopLabel as Label
@onready var _info_label: Label = $InfoPanel/InfoLabel as Label
@onready var _build_panel: VBoxContainer = $BuildPanel as VBoxContainer


func _ready() -> void:
	var scene: Node = get_tree().current_scene
	_resource_manager = scene.get_node_or_null("ResourceManager") as ResourceManager
	_selection_manager = scene.get_node_or_null("SelectionManager") as SelectionManager


func _process(_delta: float) -> void:
	_update_resource_display()
	_update_info_display()


func _update_resource_display() -> void:
	if not _resource_manager:
		return
	_salvage_label.text = "Salvage: %d" % _resource_manager.salvage
	_fuel_label.text = "Fuel: %d / %d" % [_resource_manager.fuel, _resource_manager.fuel_cap]

	var efficiency: float = _resource_manager.get_power_efficiency()
	var eff_str: String = ""
	if efficiency < 1.0:
		eff_str = " (%d%%)" % int(efficiency * 100.0)
	_power_label.text = "Power: %d / %d%s" % [_resource_manager.power_production, _resource_manager.power_consumption, eff_str]
	_pop_label.text = "Pop: %d / %d" % [_resource_manager.population, ResourceManager.POPULATION_CAP]


func _update_info_display() -> void:
	if not _selection_manager:
		_info_label.text = ""
		return

	# Building selected — show production info
	var building: Building = _selection_manager.get_selected_building()
	if building and building.stats:
		var text: String = building.stats.building_name
		if building.get_queue_size() > 0:
			text += "  |  Queue: %d  |  Progress: %d%%" % [
				building.get_queue_size(),
				int(building.get_build_progress_percent() * 100.0)
			]
		text += "\n"

		# Show producible units with hotkeys
		for i: int in building.stats.producible_units.size():
			var unit_stat: UnitStatResource = building.stats.producible_units[i]
			var hotkey: String = ["Q", "W", "E"][i] if i < 3 else str(i + 1)
			text += "[%s] %s (%dS" % [hotkey, unit_stat.unit_name, unit_stat.cost_salvage]
			if unit_stat.cost_fuel > 0:
				text += " %dF" % unit_stat.cost_fuel
			text += ")  "

		_info_label.text = text
		return

	# Units selected — show info
	var units: Array[Unit] = _selection_manager._selected_units
	if units.is_empty():
		_info_label.text = ""
		return

	if units.size() == 1:
		var unit: Unit = units[0]
		if unit.stats:
			var text: String = "%s  |  %s" % [unit.stats.unit_name, unit.stats.unit_class]
			if unit.get_builder():
				text += "\n[1-6] Place building"
			_info_label.text = text
		else:
			_info_label.text = "Unit (no stats)"
	else:
		# Multiple selected
		var counts: Dictionary = {}
		for unit: Unit in units:
			var name_key: String = unit.stats.unit_name if unit.stats else "Unknown"
			if counts.has(name_key):
				counts[name_key] += 1
			else:
				counts[name_key] = 1

		var parts: PackedStringArray = PackedStringArray()
		for name_key: String in counts:
			parts.append("%dx %s" % [counts[name_key], name_key])
		_info_label.text = "%d selected: %s" % [units.size(), ", ".join(parts)]
