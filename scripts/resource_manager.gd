class_name ResourceManager
extends Node
## Tracks the player's three resources (Salvage, Fuel, Power) and population.

signal salvage_changed(amount: int)
signal fuel_changed(amount: int)
signal power_changed(production: int, consumption: int)
signal population_changed(current: int, cap: int)

## Starting values per the design doc.
const SALVAGE_CAP: int = 9999
const FUEL_CAP_BASE: int = 500
const HQ_SALVAGE_TRICKLE: float = 5.0
## Population scales with infrastructure: a baseline cap from the HQ
## itself + a per-production-building bonus, hard-capped at the upper
## ceiling. New player starts modest (50) and grows their barracks
## space by completing foundries / armories.
const POPULATION_BASE: int = 50
const POPULATION_PER_BUILDING: int = 25
const POPULATION_MAX: int = 250

## Which player this manager bookkeeps for. Used by `update_population_cap`
## to count this player's production buildings rather than the whole map.
## 0 = local human; AI managers set their own player_id via PlayerRegistry.
var owner_id: int = 0

var salvage: int = 200
var fuel: int = 0
var fuel_cap: int = FUEL_CAP_BASE
var power_production: int = 0
var power_consumption: int = 0
var population: int = 0
var population_cap: int = POPULATION_BASE

var _salvage_accumulator: float = 0.0


func _process(delta: float) -> void:
	# HQ passive salvage trickle
	_salvage_accumulator += HQ_SALVAGE_TRICKLE * delta
	if _salvage_accumulator >= 1.0:
		var trickle: int = int(_salvage_accumulator)
		_salvage_accumulator -= float(trickle)
		add_salvage(trickle)


## Power efficiency floors at 25% — buildings throttle but never fully stall.
const POWER_EFFICIENCY_FLOOR: float = 0.25


func get_power_efficiency() -> float:
	if power_consumption <= 0 or power_production >= power_consumption:
		return 1.0
	var ratio: float = float(power_production) / float(power_consumption)
	return maxf(ratio, POWER_EFFICIENCY_FLOOR)


func can_afford_salvage(amount: int) -> bool:
	return salvage >= amount


func can_afford_fuel(amount: int) -> bool:
	return fuel >= amount


func can_afford(salvage_cost: int, fuel_cost: int) -> bool:
	return salvage >= salvage_cost and fuel >= fuel_cost


func has_population(pop_cost: int) -> bool:
	return population + pop_cost <= population_cap


func spend(salvage_cost: int, fuel_cost: int) -> bool:
	if not can_afford(salvage_cost, fuel_cost):
		return false
	salvage -= salvage_cost
	fuel -= fuel_cost
	salvage_changed.emit(salvage)
	fuel_changed.emit(fuel)
	return true


func add_salvage(amount: int) -> void:
	salvage = mini(salvage + amount, SALVAGE_CAP)
	salvage_changed.emit(salvage)


func add_fuel(amount: int) -> void:
	fuel = mini(fuel + amount, fuel_cap)
	fuel_changed.emit(fuel)


func add_population(amount: int) -> void:
	population += amount
	population_changed.emit(population, population_cap)


func remove_population(amount: int) -> void:
	population = maxi(population - amount, 0)
	population_changed.emit(population, population_cap)


func update_population_cap() -> void:
	## Recomputes population_cap = BASE + 25 per friendly production
	## building (anything that has at least one producible unit), capped
	## at POPULATION_MAX. Called by Building._finish_construction so the
	## cap rises as soon as a foundry / armory completes.
	var production_count: int = 0
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		var building: Building = node as Building
		if not building or not building.is_constructed or not building.stats:
			continue
		if building.owner_id != owner_id:
			continue
		if building.stats.producible_units.is_empty():
			continue
		production_count += 1
	var new_cap: int = mini(POPULATION_BASE + production_count * POPULATION_PER_BUILDING, POPULATION_MAX)
	if new_cap != population_cap:
		population_cap = new_cap
		population_changed.emit(population, population_cap)


func update_power() -> void:
	var total_production: int = 0
	var total_consumption: int = 0

	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		var building: Building = node as Building
		if not building or not building.is_constructed or not building.stats:
			continue
		total_production += building.stats.power_production
		total_consumption += building.stats.power_consumption

	power_production = total_production
	power_consumption = total_consumption
	power_changed.emit(power_production, power_consumption)
