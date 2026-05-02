class_name SatelliteSpawner
extends Node
## Spawns satellite-crash salvage piles. At match start drops 2-4
## piles around the map; every 120-180 seconds drops one more
## somewhere a player can race for it. Each pile is a Wreck with
## a microchip payload — workers gather them like any other wreck
## and deposit chips alongside salvage on the return trip.

const STARTING_PILES_MIN: int = 2
const STARTING_PILES_MAX: int = 4

const RESPAWN_INTERVAL_MIN: float = 120.0
const RESPAWN_INTERVAL_MAX: float = 180.0

## Salvage in each satellite pile — meaningfully fatter than a
## standard wreck so it's worth racing for, but not so fat that
## controlling one swings the whole match.
const SATELLITE_SALVAGE: int = 220

## Microchip payload range — 1 / 2 / 3 chips per pile, biased
## low so the average match drops "enough chips for one to two
## branch upgrades" per spawn cycle. With 2 chips per branch
## commit, three chips lets a savvy player snag a research +
## save the leftover.
const SATELLITE_CHIPS_MIN: int = 1
const SATELLITE_CHIPS_MAX: int = 3

## Pile placement: a square around the origin. Avoids the very
## edges (units would have a hard time reaching them) and keeps
## chunks in the playable zone.
const SPAWN_X_RANGE: float = 110.0
const SPAWN_Z_RANGE: float = 110.0
## Keep-out radius from any HQ so satellites don't drop on top
## of bases.
const HQ_KEEPOUT: float = 40.0

var _next_spawn_in: float = 0.0


func _ready() -> void:
	# Stagger first spawn pass so initial scene chaos is settled.
	call_deferred("_initial_drop")
	_schedule_next_spawn()


func _process(delta: float) -> void:
	if _next_spawn_in <= 0.0:
		return
	_next_spawn_in -= delta
	if _next_spawn_in <= 0.0:
		_spawn_one()
		_schedule_next_spawn()


func _schedule_next_spawn() -> void:
	_next_spawn_in = randf_range(RESPAWN_INTERVAL_MIN, RESPAWN_INTERVAL_MAX)


func _initial_drop() -> void:
	var count: int = randi_range(STARTING_PILES_MIN, STARTING_PILES_MAX)
	for i: int in count:
		_spawn_one()


func _spawn_one() -> void:
	var pos: Vector3 = _pick_spawn_pos()
	if pos == Vector3.INF:
		return
	var pile := Wreck.new()
	pile.salvage_value = SATELLITE_SALVAGE
	pile.salvage_remaining = SATELLITE_SALVAGE
	pile.microchip_value = randi_range(SATELLITE_CHIPS_MIN, SATELLITE_CHIPS_MAX)
	pile.is_satellite = true
	pile.wreck_size = Vector3(2.6, 0.7, 2.6)
	pile.position = pos
	get_tree().current_scene.add_child.call_deferred(pile)
	# Surface a one-line alert so the player learns the cue —
	# AlertManager handles routing to the HUD ticker if present.
	var alerts: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if alerts and alerts.has_method("emit_alert"):
		alerts.call("emit_alert", "Satellite crash detected — salvage and chips inbound", 0, pos)


func _pick_spawn_pos() -> Vector3:
	# Up to ~12 retries to find a spot that isn't on top of an HQ
	# or another satellite pile. Falls through with INF if every
	# try collided — caller skips silently.
	for attempt: int in 12:
		var x: float = randf_range(-SPAWN_X_RANGE, SPAWN_X_RANGE)
		var z: float = randf_range(-SPAWN_Z_RANGE, SPAWN_Z_RANGE)
		var p: Vector3 = Vector3(x, 0.0, z)
		if _is_clear(p):
			return p
	return Vector3.INF


func _is_clear(p: Vector3) -> bool:
	# HQ keep-out.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.stats:
			continue
		if b.stats.building_id != &"headquarters":
			continue
		if p.distance_to(b.global_position) < HQ_KEEPOUT:
			return false
	# Other-satellite spacing — don't drop two piles on top of one
	# another so the player has to actually move workers between them.
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		var w: Wreck = node as Wreck
		if not w or not w.is_satellite:
			continue
		if p.distance_to(w.global_position) < 25.0:
			return false
	return true
