class_name ResourceManager
extends Node
## Tracks the player's three resources (Salvage, Fuel, Power) and population.

signal salvage_changed(amount: int)
signal fuel_changed(amount: int)
signal microchips_changed(amount: int)
signal power_changed(production: int, consumption: int)
signal population_changed(current: int, cap: int)

## Starting values per the design doc.
const SALVAGE_CAP: int = 9999
const FUEL_CAP_BASE: int = 500
## Microchips are deliberately a small-number resource — branch
## upgrades cost 1-3, the field starts with 2-4, satellite crashes
## drop a couple at a time. Capped low so the player can't squirrel
## away a stockpile that trivialises the late game.
const MICROCHIPS_CAP: int = 30
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

var salvage: int = 300
var fuel: int = 0
var microchips: int = 0
var fuel_cap: int = FUEL_CAP_BASE
var power_production: int = 0
var power_consumption: int = 0
var population: int = 0
var population_cap: int = POPULATION_BASE

var _salvage_accumulator: float = 0.0

## Cumulative income tally — used by the match-end summary. Bumped on
## every successful add_salvage / add_fuel. Independent of the running
## income window; this one only ever grows.
var total_salvage_earned: int = 0
var total_fuel_earned: int = 0

## Rolling income window — list of (timestamp_seconds, salvage_gain, fuel_gain)
## entries. Stale entries get pruned each `add_*` call so memory stays small
## (a few dozen entries per minute at typical play). The HUD reads the
## sum / window for an average-per-second readout.
const INCOME_WINDOW_SEC: float = 30.0
var _income_log: Array[Dictionary] = []
## Pause-aware "game seconds" counter. _process doesn't run while
## the SceneTree is paused (default PROCESS_MODE_INHERIT), so this
## stops accumulating during pause. Income-log timestamps reference
## this instead of Time.get_ticks_msec() — without it, old entries
## aged out of the rolling window during pause (wall clock keeps
## moving) and the HUD's salvage/s readout fell to 0 the longer
## the player stayed paused.
var _game_seconds: float = 0.0


func _process(delta: float) -> void:
	_game_seconds += delta
	# HQ passive salvage trickle
	_salvage_accumulator += HQ_SALVAGE_TRICKLE * delta
	if _salvage_accumulator >= 1.0:
		var trickle: int = int(_salvage_accumulator)
		_salvage_accumulator -= float(trickle)
		add_salvage(trickle)


## Power efficiency floors at 25% — buildings throttle but never fully stall.
const POWER_EFFICIENCY_FLOOR: float = 0.25


func get_power_efficiency() -> float:
	# Cheat hook — cashmoneten / einfachturbo set CheatManager.infinite_power
	# so the local player isn't throttled mid-test even when consumption
	# spikes above production. Only applies for local-player owner_id 0.
	if owner_id == 0:
		var cheats: Node = get_tree().current_scene.get_node_or_null("CheatManager") if get_tree() else null
		if cheats and "infinite_power" in cheats and cheats.get("infinite_power"):
			return 1.0
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


func can_afford_microchips(amount: int) -> bool:
	return microchips >= amount


func can_afford_full(salvage_cost: int, fuel_cost: int, microchip_cost: int) -> bool:
	## Combined affordability check for upgrade costs that span all
	## three currencies. Branch researches use this — they need
	## microchips + a small salvage + a heavier fuel down-payment.
	return salvage >= salvage_cost and fuel >= fuel_cost and microchips >= microchip_cost


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


func spend_full(salvage_cost: int, fuel_cost: int, microchip_cost: int) -> bool:
	## Atomic deduction across all three resources. Used by the branch
	## research path so a click that's affordable on salvage+fuel but
	## not on microchips doesn't half-pay.
	if not can_afford_full(salvage_cost, fuel_cost, microchip_cost):
		return false
	salvage -= salvage_cost
	fuel -= fuel_cost
	microchips -= microchip_cost
	salvage_changed.emit(salvage)
	fuel_changed.emit(fuel)
	microchips_changed.emit(microchips)
	return true


func add_salvage(amount: int) -> void:
	salvage = mini(salvage + amount, SALVAGE_CAP)
	salvage_changed.emit(salvage)
	_record_income(amount, 0)
	if amount > 0:
		total_salvage_earned += amount


func add_fuel(amount: int) -> void:
	fuel = mini(fuel + amount, fuel_cap)
	fuel_changed.emit(fuel)
	_record_income(0, amount)
	if amount > 0:
		total_fuel_earned += amount


func add_microchips(amount: int) -> void:
	## Microchips arrive in small lumps (satellite-crash piles, the
	## occasional special objective drop). The cap is intentionally
	## low — overflow gets clamped silently.
	microchips = mini(microchips + amount, MICROCHIPS_CAP)
	microchips_changed.emit(microchips)


func _record_income(salvage_amt: int, fuel_amt: int) -> void:
	if salvage_amt <= 0 and fuel_amt <= 0:
		return
	var now: float = _game_seconds
	# Drop entries older than the window.
	while not _income_log.is_empty() and (_income_log[0]["t"] as float) < now - INCOME_WINDOW_SEC:
		_income_log.pop_front()
	_income_log.append({"t": now, "s": salvage_amt, "f": fuel_amt})


func get_average_income() -> Vector2:
	## Returns (salvage_per_sec, fuel_per_sec) averaged over the last
	## INCOME_WINDOW_SEC. Empty log → (0, 0).
	if _income_log.is_empty():
		return Vector2.ZERO
	var now: float = _game_seconds
	var total_s: int = 0
	var total_f: int = 0
	for entry: Dictionary in _income_log:
		if (entry["t"] as float) < now - INCOME_WINDOW_SEC:
			continue
		total_s += entry["s"] as int
		total_f += entry["f"] as int
	# Use the configured window even before it's been alive that long
	# — running average smooths out the spiky early-game numbers.
	return Vector2(float(total_s) / INCOME_WINDOW_SEC, float(total_f) / INCOME_WINDOW_SEC)


func add_population(amount: int) -> void:
	population += amount
	population_changed.emit(population, population_cap)


func remove_population(amount: int) -> void:
	population = maxi(population - amount, 0)
	population_changed.emit(population, population_cap)


func update_population_cap() -> void:
	## Recomputes population_cap = BASE + 25 per friendly production
	## building (anything that has at least one producible unit), capped
	## at POPULATION_MAX. Also adds stats.provides_population for any
	## building that explicitly contributes pop cap (e.g. Sensor Spine,
	## Drone Bay — authorization buildings that expand the roster budget
	## without being direct producers). Called by Building._finish_construction
	## so the cap rises as soon as a foundry / armory / spine completes.
	var production_count: int = 0
	var pop_from_provision: int = 0
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		var building: Building = node as Building
		if not building or not building.is_constructed or not building.stats:
			continue
		if building.owner_id != owner_id:
			continue
		if not building.stats.producible_units.is_empty():
			production_count += 1
		pop_from_provision += building.stats.provides_population
	var new_cap: int = mini(POPULATION_BASE + production_count * POPULATION_PER_BUILDING + pop_from_provision, POPULATION_MAX)
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
		# Filter by owner so the AI / ally HQ + generators don't leak
		# their power production into THIS manager's totals. Pre-fix
		# the player saw 60 baseline from 'their' HQ + the AI's HQ
		# (or both ally HQs in 2v2).
		var b_owner: int = (building.get("owner_id") as int) if "owner_id" in building else -1
		if b_owner != owner_id:
			continue
		total_production += building.stats.power_production
		total_consumption += building.get_effective_power_consumption()

	power_production = total_production
	power_consumption = total_consumption
	power_changed.emit(power_production, power_consumption)
