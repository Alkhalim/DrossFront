class_name TutorialMission
extends Node
## Mission-style tutorial scenario. Replaces the old checklist-only
## overlay with a sequence of objective stages, each with its own
## dialogue line and trigger condition. The mission opens with the
## player commanding only a small Rook squad — there's no HQ yet.
## As they explore the map they pick up reinforcements, a Crawler,
## an abandoned base, and finally a Sable ally arrives to help them
## crack a fortified enemy camp.
##
## Wired by TestArenaController only when MatchSettings.tutorial_mode
## is true. Owns its own state machine; the HUD's TutorialBanner reads
## current_stage_text() / current_stage_dialogue() each frame.

signal stage_advanced(index: int)

## Each stage is a Dictionary:
##   id: StringName       — short identifier for save state
##   dialogue: String     — top-banner story line ("Commander, ...")
##   objective: String    — actionable task readout
##   on_enter: Callable   — fires once when the stage becomes active
##                          (spawn units, drop the crawler, etc.)
##   trigger: Callable    — returns true when the stage is complete
var _stages: Array[Dictionary] = []
var _current_stage_index: int = -1
var _completed: bool = false

## Tracks zones the player has visited so trigger callables can ask
## "did the squad enter the cache point yet?" without each one
## re-implementing the proximity poll.
const VISIT_RADIUS_SQ: float = 20.0 * 20.0  # 20u radius
var _visited_zones: Dictionary = {}  # StringName -> bool

## How often _process polls the trigger callable — 4 Hz is plenty
## for proximity / unit-count checks without hammering the scene.
const TRIGGER_POLL_INTERVAL: float = 0.25
var _poll_accum: float = 0.0


func _ready() -> void:
	add_to_group("tutorial_mission")
	# Fire after the test arena finishes its setup pass so unit
	# spawns can hit live nodes (Units container, ResourceManager
	# etc).
	call_deferred("_install_stages")
	call_deferred("_advance_to_stage", 0)


func current_stage_dialogue() -> String:
	if _current_stage_index < 0 or _current_stage_index >= _stages.size():
		return ""
	return (_stages[_current_stage_index] as Dictionary).get("dialogue", "") as String


func current_stage_objective() -> String:
	if _current_stage_index < 0 or _current_stage_index >= _stages.size():
		return ""
	return (_stages[_current_stage_index] as Dictionary).get("objective", "") as String


func current_stage_index() -> int:
	return _current_stage_index


func total_stages() -> int:
	return _stages.size()


func is_completed() -> bool:
	return _completed


func _process(delta: float) -> void:
	if _completed or _stages.is_empty():
		return
	# Ally march/follow logic ticks every frame (cheap — 5 units
	# max). Idle when the ally hasn't been spawned yet.
	_tick_ally_behaviour(delta)
	# First-building-completion raid trigger (fires once when the
	# player finishes their first non-HQ structure).
	_tick_first_building_raid()
	_poll_accum += delta
	if _poll_accum < TRIGGER_POLL_INTERVAL:
		return
	_poll_accum = 0.0
	if _current_stage_index < 0 or _current_stage_index >= _stages.size():
		return
	var stage: Dictionary = _stages[_current_stage_index]
	var trig: Callable = stage.get("trigger", Callable()) as Callable
	if trig.is_valid() and trig.call() as bool:
		_advance_to_stage(_current_stage_index + 1)


func _advance_to_stage(idx: int) -> void:
	if idx >= _stages.size():
		_completed = true
		return
	_current_stage_index = idx
	var stage: Dictionary = _stages[idx]
	var on_enter: Callable = stage.get("on_enter", Callable()) as Callable
	if on_enter.is_valid():
		on_enter.call()
	stage_advanced.emit(idx)


## --- Helpers used by stage on_enter callables ----------------------------

func _player_units() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for n: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(n):
			continue
		if not ("owner_id" in n) or n.get("owner_id") != 0:
			continue
		var u: Node3D = n as Node3D
		if u and ("alive_count" in u) and (u.get("alive_count") as int) > 0:
			out.append(u)
	return out


func _player_unit_count() -> int:
	return _player_units().size()


func _any_player_unit_in_radius(centre: Vector3, radius_sq: float) -> bool:
	for u: Node3D in _player_units():
		if u.global_position.distance_squared_to(centre) <= radius_sq:
			return true
	return false


func _spawn_player_unit(stats_path: String, pos: Vector3) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		return null
	var scene_path: String = "res://scenes/aircraft.tscn" if stats.is_aircraft else "res://scenes/unit.tscn"
	var ps: PackedScene = load(scene_path) as PackedScene
	if not ps:
		return null
	var node: Node3D = ps.instantiate() as Node3D
	if not node:
		return null
	node.set("stats", stats)
	node.set("owner_id", 0)
	var units_node: Node = get_tree().current_scene.get_node_or_null("Units")
	if units_node:
		units_node.add_child(node)
	else:
		get_tree().current_scene.add_child(node)
	node.global_position = pos
	return node


## --- Stage definitions ---------------------------------------------------

func _install_stages() -> void:
	# Cast:
	#   Steelmaster Kress  — Anvil dispatch officer. Player's contact.
	#   Riven Yul          — Sable strike-force lead, ex-shadow ops,
	#                        recently turned. Arrives at stage 6.
	#
	# Discovery beats sit progressively further SOUTH (negative Z
	# in world space — south reads as "down the screen" with the
	# camera's 50 deg pitch). The Sable enclave the player has to
	# crack at the end sits at the OPPOSITE end of the map (+Z =
	# north), so the climax involves turning around and pushing
	# the strike force the other direction.

	# Stage 0 — opening. The player has just their Rook scouts.
	_stages.append({
		"id": &"open",
		"dialogue": "Steelmaster Kress: \"Scouts, advance south. There's a wreckage cache a hundred meters out — survivors might be holed up there.\"",
		"objective": "Move your Rooks south to the wreckage.",
		"on_enter": Callable(self, "_stage_open_enter"),
		"trigger": Callable(self, "_stage_open_done"),
	})
	# Stage 1 — reinforcements found.
	_stages.append({
		"id": &"reinforce",
		"dialogue": "Steelmaster Kress: \"Two more Rook squads are intact. Keep pushing south — we have a Salvage Crawler hulk on the long-range scope.\"",
		"objective": "Keep moving south to find the Crawler.",
		"on_enter": Callable(self, "_stage_reinforce_enter"),
		"trigger": Callable(self, "_stage_reinforce_done"),
	})
	# Stage 2 — Crawler.
	_stages.append({
		"id": &"crawler",
		"dialogue": "Steelmaster Kress: \"That Crawler still runs — bring it with you. Push further south to the abandoned foundry.\"",
		"objective": "Continue south to the foundry ruin.",
		"on_enter": Callable(self, "_stage_crawler_enter"),
		"trigger": Callable(self, "_stage_crawler_done"),
	})
	# Stage 3 — base reclaimed. Player gets HQ + economy unlock.
	_stages.append({
		"id": &"base",
		"dialogue": "Steelmaster Kress: \"Welcome to your forward base, commander. Build a Basic Foundry and a Salvage Yard — get production rolling.\"",
		"objective": "Build a Basic Foundry and a Salvage Yard.",
		"on_enter": Callable(self, "_stage_base_enter"),
		"trigger": Callable(self, "_stage_base_done"),
	})
	# Stage 4 — power the base.
	_stages.append({
		"id": &"reactors",
		"dialogue": "Steelmaster Kress: \"Brownouts on every line. Drop three Reactors next to your foundry — full power or your queue stalls.\"",
		"objective": "Build 3 Generators (Reactors) to fully power your base.",
		"on_enter": Callable(self, "_stage_reactors_enter"),
		"trigger": Callable(self, "_stage_reactors_done"),
	})
	# Stage 5 — assemble strike force.
	_stages.append({
		"id": &"force",
		"dialogue": "Steelmaster Kress: \"Build your forces up to six combat units, commander — Rooks for speed, Hounds for the punch. The Sable enclave is dug in to the north and we are going to dislodge them.\"",
		"objective": "Build your forces up to 6 combat units (Rooks or Hounds).",
		"on_enter": Callable(self, "_stage_force_enter"),
		"trigger": Callable(self, "_stage_force_done"),
	})
	# Stage 6 — Sable ally arrives.
	_stages.append({
		"id": &"ally",
		"dialogue": "Riven Yul: \"Easy, commander — drop the targeting solution. Yes, Sable colours, no, not the same outfit you used to chase. Reformed, retrained, and bringing three heavy bombers and two Harbinger squadrons. Let's go crack that camp to the north together.\"",
		"objective": "Destroy the Sable enclave to the north alongside your ally.",
		"on_enter": Callable(self, "_stage_ally_enter"),
		"trigger": Callable(self, "_stage_ally_done"),
	})
	# Stage 7 — victory.
	_stages.append({
		"id": &"win",
		"dialogue": "Steelmaster Kress: \"Enclave neutralised. Tutorial complete — head back to the main menu when you're ready.\"",
		"objective": "(Tutorial complete.)",
		"on_enter": Callable(self, "_stage_win_enter"),
		"trigger": Callable(self, "_stage_win_done"),
	})


# Stage entry callables — most are no-ops in this scaffold; the
# initial unit / cache / base setup happens in TestArenaController's
# tutorial-mode branch (separate commit). Triggers below run as
# proximity / count checks against live world state.

func _stage_open_enter() -> void:
	pass


func _stage_open_done() -> bool:
	# Player walks any Rook into the wreckage cache zone. Sits
	# safely SOUTH of the Foundry Belt central plateau (which
	# covers z=+16 to +34) so the cache + reinforcement spawn
	# both land on flat ground rather than wedged inside the
	# plateau geometry.
	return _any_player_unit_in_radius(Vector3(0.0, 0.0, 50.0), VISIT_RADIUS_SQ)


func _stage_reinforce_enter() -> void:
	# Two more Rook squads spawn at the cache (south of the
	# central plateau), slightly off-axis so they don't all
	# overlap the lead squad.
	_spawn_player_unit("res://resources/units/anvil_rook.tres", Vector3(-3.0, 0.0, 50.0))
	_spawn_player_unit("res://resources/units/anvil_rook.tres", Vector3(3.0, 0.0, 50.0))


func _stage_reinforce_done() -> bool:
	# Player walks units further south to the Crawler discovery point.
	return _any_player_unit_in_radius(Vector3(0.0, 0.0, 75.0), VISIT_RADIUS_SQ)


func _stage_crawler_enter() -> void:
	# A Salvage Crawler joins the player at the discovery point.
	var crawler_scene: PackedScene = load("res://scenes/salvage_crawler.tscn") as PackedScene
	if not crawler_scene:
		return
	var crawler: Node3D = crawler_scene.instantiate() as Node3D
	if not crawler:
		return
	crawler.set("owner_id", 0)
	get_tree().current_scene.add_child(crawler)
	crawler.global_position = Vector3(0.0, 0.0, 75.0)


func _stage_crawler_done() -> bool:
	# Player advances further south to the foundry ruin.
	return _any_player_unit_in_radius(Vector3(0.0, 0.0, 100.0), VISIT_RADIUS_SQ)


func _stage_base_enter() -> void:
	# Hand the abandoned HQ over to the player. TestArenaController
	# parks it at (0, 0, -88) with owner_id 2 (neutral ruin) at
	# match start; flipping owner_id to 0 here unlocks production,
	# vision, and resource flow as the discovery beat resolves.
	for n: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(n):
			continue
		var b: Building = n as Building
		if not b or not b.stats:
			continue
		if b.stats.building_id != &"headquarters":
			continue
		# Only claim the abandoned (neutral) HQ — leave the actual
		# enemy enclave's HQ alone.
		if b.owner_id != 2:
			continue
		# Distance check so we don't accidentally claim the wrong
		# neutral HQ if the map ever has more than one.
		if b.global_position.distance_squared_to(Vector3(0.0, 0.0, 100.0)) > 30.0 * 30.0:
			continue
		b.owner_id = 0
		var rm: Node = get_tree().current_scene.get_node_or_null("ResourceManager")
		if rm:
			b.resource_manager = rm
		# Re-skin the HQ with the new owner's team colour by
		# rebuilding the placeholder shape.
		if b.has_method("_apply_placeholder_shape"):
			b._apply_placeholder_shape()
	# Hand the player a couple of Ratchet engineers so they can
	# actually act on the next objective ("build a Foundry + Yard")
	# without first having to produce engineers from scratch — a
	# fresh tutorial-mode HQ doesn't auto-spawn anything. Spawn
	# them ~14u south of the HQ (further out, NOT directly next
	# to the building) so they're easy to spot against the
	# silhouette of the freshly-claimed structure.
	_spawn_player_unit("res://resources/units/anvil_ratchet.tres", Vector3(-6.0, 0.0, 114.0))
	_spawn_player_unit("res://resources/units/anvil_ratchet.tres", Vector3(6.0, 0.0, 114.0))


func _stage_base_done() -> bool:
	# Player needs at least one Basic Foundry AND one Salvage Yard
	# to advance.
	var has_foundry: bool = false
	var has_yard: bool = false
	for n: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(n):
			continue
		if not ("owner_id" in n) or n.get("owner_id") != 0:
			continue
		var b: Building = n as Building
		if not b or not b.stats or not b.is_constructed:
			continue
		match b.stats.building_id:
			&"basic_foundry": has_foundry = true
			&"salvage_yard":  has_yard = true
	return has_foundry and has_yard


## Reworded from "3 additional" to "6 total" per playtest — the
## delta target was confusing relative to the visible roster
## count, and a flat 6-unit target reads cleaner. _force_target
## kept as a const for tuning parity.
const FORCE_TARGET_COUNT: int = 6

## Sable ally tracking. _ally_units holds every unit spawned for
## the player's strike-force ally; _ally_state walks them through
## a two-phase behaviour:
##   "marching"  — moving from southern edge to the player base
##   "following" — trailing the player's army centroid toward
##                 the enclave, refreshed at FOLLOW_INTERVAL_SEC
##                 so the move target stays current as the
##                 player advances.
var _ally_units: Array[Node3D] = []
var _ally_state: StringName = &""
var _ally_follow_accum: float = 0.0

## First-building-completion raid trigger. Once the player
## finishes their first non-HQ structure, two Sable Courier Tank
## squads spawn at the northern enclave edge and march south
## toward the player base — a small early scare that introduces
## the "enemy is in the north" concept before the climax push.
var _raid_fired: bool = false
## Player walks SOUTH (+Z) through the discovery beats and ends
## up with their base at +100. Ally rally point sits to the
## LEFT (-X) of the base, NOT directly south of it — heavy
## Harbinger walkers were getting stuck pathing between the
## player's foundry / generators / yard if they marched
## straight up the centre line. The west-side approach gives
## them a clean lane around the base.
## Spawn point is also pulled west so the whole strike force
## arrives offset rather than crossing through the base mid-
## march. Enemy enclave at -Z = north on screen.
const ALLY_RALLY_POINT: Vector3 = Vector3(-50.0, 0.0, 108.0)
const ALLY_RALLY_ARRIVE_SQ: float = 18.0 * 18.0
const ALLY_FOLLOW_INTERVAL_SEC: float = 3.0
const ALLY_TRAIL_OFFSET: float = 6.0  # ally rallies this far behind player centroid
const ENEMY_ENCLAVE_CENTRE: Vector3 = Vector3(0.0, 0.0, -130.0)
const ALLY_SPAWN_X: float = -50.0
const ALLY_SPAWN_Z: float = 150.0


func _stage_force_enter() -> void:
	pass


func _stage_force_done() -> bool:
	# Total of FORCE_TARGET_COUNT combat units (Rooks / Hounds /
	# Phalanx). Counts the entire current roster — the player
	# starts the stage with whatever Rooks survived the south
	# walk + their reinforce squads, and only has to top up to
	# the target.
	return _count_player_combat_units() >= FORCE_TARGET_COUNT


func _count_player_combat_units() -> int:
	var combat: int = 0
	for u: Node3D in _player_units():
		var s: UnitStatResource = u.get("stats") as UnitStatResource
		if not s:
			continue
		if s.unit_class == &"engineer" or s.unit_class == &"crawler":
			continue
		combat += 1
	return combat


func _stage_reactors_enter() -> void:
	pass


func _stage_reactors_done() -> bool:
	# Three constructed Generators on the player's account.
	var generators: int = 0
	for n: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(n):
			continue
		if not ("owner_id" in n) or n.get("owner_id") != 0:
			continue
		var b: Building = n as Building
		if not b or not b.stats or not b.is_constructed:
			continue
		if b.stats.building_id == &"basic_generator":
			generators += 1
	return generators >= 3


func _stage_ally_enter() -> void:
	# Sable strike force drops in at the SOUTHERN edge of the
	# map (the player walks NORTH through the mission, so the
	# ally arrives behind them and pushes up to join). Owner 1
	# with team 0 — PlayerRegistry's are_allied lookup treats
	# them as friendly to the player.
	#
	# Composition per spec:
	#   3 Wraith heavy bombers
	#   2 Harbinger artillery walkers
	# Wraith would normally require a Black Pylon to build, but
	# the ally arrives pre-formed so the prereq is moot.
	_ally_units.clear()
	var spawn_z: float = ALLY_SPAWN_Z
	# Strike force arrives at the western edge of the south end
	# (X = ALLY_SPAWN_X) so the march to the rally point is a
	# clean north-westward lane around the base, not straight
	# through the foundry / yard / generators.
	var heavy_offsets: Array = [-8.0, 0.0, 8.0]   # X spread around the spawn lane
	for i: int in 3:
		var p: Vector3 = Vector3(ALLY_SPAWN_X + heavy_offsets[i], 0.0, spawn_z)
		var u: Node3D = _spawn_ally_unit("res://resources/units/sable_wraith.tres", p)
		if u:
			_ally_units.append(u)
	for i: int in 2:
		var p2: Vector3 = Vector3(ALLY_SPAWN_X - 4.0 + float(i) * 8.0, 0.0, spawn_z + 8.0)
		var u2: Node3D = _spawn_ally_unit("res://resources/units/sable_harbinger.tres", p2)
		if u2:
			_ally_units.append(u2)

	# Issue the initial "march to player base" command. Allies
	# move north toward ALLY_RALLY_POINT; the _process tick below
	# flips them to FOLLOW state once they're close enough.
	_ally_state = &"marching"
	for u3: Node3D in _ally_units:
		if u3.has_method("command_move"):
			u3.call("command_move", ALLY_RALLY_POINT)

	# Switch the playlist to the Sable folder so the moment the
	# ally arrives the score shifts character. MusicManager's
	# start() rebuilds the playlist + advances to a new track.
	var music_mgr: Node = get_tree().current_scene.get_node_or_null("MusicManager")
	if music_mgr and music_mgr.has_method("start"):
		music_mgr.call("start", 1)  # 1 = Sable


func _tick_ally_behaviour(delta: float) -> void:
	## Drives the Sable strike force through their two phases.
	## Called from _process every tick (cheap — N <= 5 ally
	## units max). Bails out when there are no allies or the
	## stage has progressed past ALLY.
	if _ally_units.is_empty():
		return
	# Drop freed entries.
	var i: int = _ally_units.size() - 1
	while i >= 0:
		if not is_instance_valid(_ally_units[i]):
			_ally_units.remove_at(i)
		i -= 1
	if _ally_units.is_empty():
		return

	if _ally_state == &"marching":
		# Look at the centroid of the (still-alive) allies — when
		# they're close enough to the player rally point, flip to
		# follow mode.
		var centroid: Vector3 = _ally_centroid()
		if centroid.distance_squared_to(ALLY_RALLY_POINT) <= ALLY_RALLY_ARRIVE_SQ:
			_ally_state = &"following"
			_ally_follow_accum = ALLY_FOLLOW_INTERVAL_SEC  # fire immediately
		return

	if _ally_state == &"following":
		_ally_follow_accum += delta
		if _ally_follow_accum < ALLY_FOLLOW_INTERVAL_SEC:
			return
		_ally_follow_accum = 0.0
		# Re-target: trail behind the player's army on its push
		# toward the enclave. Aim at a point just behind the
		# player centroid (offset toward the player's spawn) so
		# the ally pushes alongside rather than passing the
		# player and getting picked off by the camp's outer ring
		# of turrets first.
		var player_centre: Vector3 = _player_combat_centroid()
		var to_enclave: Vector3 = ENEMY_ENCLAVE_CENTRE - player_centre
		to_enclave.y = 0.0
		var trail: Vector3 = player_centre
		if to_enclave.length_squared() > 0.0001:
			trail = player_centre - to_enclave.normalized() * ALLY_TRAIL_OFFSET
		# If the player has no combat units (early ally arrival
		# before the player rebuilds), just push the allies
		# straight at the enclave.
		var target: Vector3 = trail
		if _player_combat_count_only() == 0:
			target = ENEMY_ENCLAVE_CENTRE
		for u: Node3D in _ally_units:
			if u.has_method("command_move"):
				u.call("command_move", target)


func _ally_centroid() -> Vector3:
	if _ally_units.is_empty():
		return Vector3.ZERO
	var sum: Vector3 = Vector3.ZERO
	var count: int = 0
	for u: Node3D in _ally_units:
		if not is_instance_valid(u):
			continue
		sum += u.global_position
		count += 1
	return sum / float(maxi(count, 1))


func _player_combat_centroid() -> Vector3:
	## Returns the average position of the player's combat
	## units (no engineers, no crawlers). Falls back to the
	## ally rally point when the player has none alive.
	var sum: Vector3 = Vector3.ZERO
	var count: int = 0
	for u: Node3D in _player_units():
		var s: UnitStatResource = u.get("stats") as UnitStatResource
		if not s:
			continue
		if s.unit_class == &"engineer" or s.unit_class == &"crawler":
			continue
		sum += u.global_position
		count += 1
	if count == 0:
		return ALLY_RALLY_POINT
	return sum / float(count)


func _player_combat_count_only() -> int:
	return _count_player_combat_units()


func _tick_first_building_raid() -> void:
	## Fires once when the player finishes their first non-HQ
	## structure (Foundry, Salvage Yard, Generator, etc). Spawns
	## two Courier Tank squads at the northern enclave edge with
	## a move command toward the player base — a small early
	## raid to telegraph "enemy is in the north" before the
	## climax push.
	if _raid_fired:
		return
	for n: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(n):
			continue
		if not ("owner_id" in n) or n.get("owner_id") != 0:
			continue
		var b: Building = n as Building
		if not b or not b.stats or not b.is_constructed:
			continue
		# Skip the HQ — it counts as already-built (the player
		# claimed it, didn't construct it from scratch).
		if b.stats.building_id == &"headquarters":
			continue
		_raid_fired = true
		_spawn_first_building_raid()
		return


func _spawn_first_building_raid() -> void:
	# One Courier Tank squad spawns at the northern enclave edge
	# (-Z) and starts moving south toward the player base. Owner
	# 2 (NEUTRAL pseudo-player) so it reads as enemy — same
	# slot the enclave defenders use. Single squad keeps the
	# raid as a soft warning rather than a real fight.
	var raid_z: float = -110.0
	var u: Node3D = _spawn_tutorial_raid_unit(
		"res://resources/units/sable_courier_tank.tres",
		Vector3(0.0, 0.0, raid_z),
	)
	if u and u.has_method("command_move"):
		u.call("command_move", Vector3(0.0, 0.0, 80.0))
	# Surface a one-line alert so the player sees the raid coming
	# without having to scrub the minimap.
	var alerts: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if alerts and alerts.has_method("emit_alert"):
		alerts.call(
			"emit_alert",
			"Sable raid inbound from the north — one Courier Tank squad",
			1,
			Vector3(0.0, 0.0, raid_z),
		)


func _spawn_tutorial_raid_unit(stats_path: String, pos: Vector3) -> Node3D:
	## Same shape as _spawn_ally_unit but owner_id 2 (enemy
	## neutral) and parented to the standard Units container.
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		return null
	var ps: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if not ps:
		return null
	var node: Node3D = ps.instantiate() as Node3D
	if not node:
		return null
	node.set("stats", stats)
	node.set("owner_id", 2)
	var units_node: Node = get_tree().current_scene.get_node_or_null("Units")
	if units_node:
		units_node.add_child(node)
	else:
		get_tree().current_scene.add_child(node)
	node.global_position = pos
	return node


func _stage_ally_done() -> bool:
	# Win when no enemy combat units / buildings remain in the
	# enclave. Enemy team is id 2 (the AI in tutorial setup).
	for n: Node in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(n) and ("owner_id" in n):
			var oid: int = n.get("owner_id") as int
			if oid != 0 and oid != 1 and (n.get("alive_count") as int) > 0:
				return false
	for n: Node in get_tree().get_nodes_in_group("buildings"):
		if is_instance_valid(n) and ("owner_id" in n):
			var oid: int = n.get("owner_id") as int
			if oid != 0 and oid != 1:
				return false
	return true


func _stage_win_enter() -> void:
	# Trigger the match-end victory path so the player gets the
	# normal end overlay.
	var mm: Node = get_tree().current_scene.get_node_or_null("MatchManager")
	if mm and mm.has_method("_end_match"):
		mm.call("_end_match", true)


func _stage_win_done() -> bool:
	# Win is terminal — never advance past it.
	return false


func _spawn_ally_unit(stats_path: String, pos: Vector3) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		return null
	var scene_path: String = "res://scenes/aircraft.tscn" if stats.is_aircraft else "res://scenes/unit.tscn"
	var ps: PackedScene = load(scene_path) as PackedScene
	if not ps:
		return null
	var node: Node3D = ps.instantiate() as Node3D
	if not node:
		return null
	node.set("stats", stats)
	# Owner 1 = ally slot (team 0 alongside the player) — matches
	# PlayerRegistry's 2v2 roster wiring.
	node.set("owner_id", 1)
	var units_node: Node = get_tree().current_scene.get_node_or_null("Units")
	if units_node:
		units_node.add_child(node)
	else:
		get_tree().current_scene.add_child(node)
	node.global_position = pos
	return node
