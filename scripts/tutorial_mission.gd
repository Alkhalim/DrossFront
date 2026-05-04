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
	call_deferred("_spawn_bonus_wrecks")


func _spawn_bonus_wrecks() -> void:
	## Extra small wrecks scattered along the northward push route
	## from the player base (z=+100) toward the Sable enclave
	## (z=-130), so the player's Crawler doesn't run dry as they
	## advance. Each wreck is small (~25-45 salvage) and spread
	## off-axis to stay clear of the discovery walk.
	## Layout: 4 clusters between the base and the enclave, one
	## per major lateral lane.
	var cluster_centres: Array[Vector3] = [
		Vector3(18.0, 0.0, 70.0),
		Vector3(-18.0, 0.0, 70.0),
		Vector3(20.0, 0.0, 30.0),
		Vector3(-20.0, 0.0, 30.0),
		Vector3(15.0, 0.0, -10.0),
		Vector3(-15.0, 0.0, -10.0),
		Vector3(22.0, 0.0, -50.0),
		Vector3(-22.0, 0.0, -50.0),
	]
	for centre: Vector3 in cluster_centres:
		var per_cluster: int = 3
		for i: int in per_cluster:
			var jitter: Vector3 = Vector3(
				randf_range(-3.0, 3.0),
				0.0,
				randf_range(-3.0, 3.0),
			)
			var wreck := Wreck.new()
			wreck.salvage_value = randi_range(25, 45)
			wreck.salvage_remaining = wreck.salvage_value
			wreck.wreck_size = Vector3(
				randf_range(0.7, 1.1),
				randf_range(0.3, 0.5),
				randf_range(0.7, 1.1),
			)
			wreck.position = centre + jitter
			get_tree().current_scene.add_child.call_deferred(wreck)


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
		"dialogue": "Steelmaster Kress: \"That Crawler still runs — bring it with you. Push further south to the abandoned command outpost — we should be able to reclaim it.\"",
		"objective": "Continue south to the abandoned HQ.",
		"on_enter": Callable(self, "_stage_crawler_enter"),
		"trigger": Callable(self, "_stage_crawler_done"),
	})
	# Stage 3 — base reclaimed. Player gets HQ + economy unlock.
	# Build order matters: the Salvage Yard now requires a Generator
	# prereq, so the dialogue calls out Generator first.
	_stages.append({
		"id": &"base",
		"dialogue": "Steelmaster Kress: \"Welcome to your forward base, commander. Drop a Generator first to keep the lights on, then a Basic Foundry, then a Salvage Yard to feed your war machine.\"",
		"objective": "Build a Generator, a Basic Foundry, and a Salvage Yard.",
		"on_enter": Callable(self, "_stage_base_enter"),
		"trigger": Callable(self, "_stage_base_done"),
	})
	# Stage 4 — push power higher to support the army. Renamed
	# from 'Reactors' (legacy term) to 'Generators' to match the
	# current building name.
	_stages.append({
		"id": &"reactors",
		"dialogue": "Steelmaster Kress: \"You'll want headroom for what's coming, commander. Drop two more Generators next to the foundry so the queue doesn't stall under load.\"",
		"objective": "Have at least 3 Generators powering your base.",
		"on_enter": Callable(self, "_stage_reactors_enter"),
		"trigger": Callable(self, "_stage_reactors_done"),
	})
	# Stage 5 — optional oil-field capture.
	_stages.append({
		"id": &"oil",
		"dialogue": "Steelmaster Kress: \"There's a fuel deposit just east of your base — claim it and you'll have the fuel to roll Hounds out of that foundry. Or save the time and stick to Rooks; your call.\"",
		"objective": "Capture a fuel deposit east of your base to unlock Hounds (optional).",
		"on_enter": Callable(self, "_stage_oil_enter"),
		"trigger": Callable(self, "_stage_oil_done"),
	})
	# Stage 6 — assemble strike force.
	_stages.append({
		"id": &"force",
		"dialogue": "Steelmaster Kress: \"Build your line up to six combat squads, commander — Rooks for speed, Hounds for the punch. The Sable enclave to the north isn't going to dislodge itself.\"",
		"objective": "Build your forces up to 6 combat units (Rooks or Hounds).",
		"on_enter": Callable(self, "_stage_force_enter"),
		"trigger": Callable(self, "_stage_force_done"),
	})
	# Stage 7 — Sable ally arrives.
	_stages.append({
		"id": &"ally",
		"dialogue": "Riven Yul: \"Easy, commander — drop the targeting solution. Yes, Sable colours, no, not the outfit you used to chase. Reformed, retrained, and I brought enough firepower to crack that camp with you. Let's move.\"",
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
	# A Salvage Crawler joins the player just off the discovery
	# point. Spawn pulled ~10u east of the centerline so any
	# leftover map decoration (rock outcrops, scrap piles, ruin
	# blocks) on the z=75 axis can't swallow the Crawler at
	# spawn time. Trigger zone is still centred so the player
	# reaches the discovery beat at the same point.
	var crawler_scene: PackedScene = load("res://scenes/salvage_crawler.tscn") as PackedScene
	if not crawler_scene:
		return
	var crawler: Node3D = crawler_scene.instantiate() as Node3D
	if not crawler:
		return
	crawler.set("owner_id", 0)
	get_tree().current_scene.add_child(crawler)
	crawler.global_position = Vector3(10.0, 0.0, 78.0)


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
	# Player needs Generator + Basic Foundry + Salvage Yard to
	# advance. Yard requires Generator (prereq), so the order is
	# enforced by the build menu; the trigger just checks all
	# three are standing.
	var has_generator: bool = false
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
			&"basic_generator": has_generator = true
			&"basic_foundry":   has_foundry = true
			&"salvage_yard":    has_yard = true
	return has_generator and has_foundry and has_yard


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
## Latches true once the strike force has committed to the
## attack-move-toward-enclave path. The override only ISSUES the
## command on the rising edge (false -> true) — re-issuing on
## every tick would clear each ally's _current_target /
## forced_target every second and the allies would walk past
## enemies without engaging. Resets to false when the engagement
## ends so a future fight re-commits.
var _ally_attack_committed: bool = false

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
const ALLY_RALLY_ARRIVE_SQ: float = 24.0 * 24.0  # any ally within 24u of rally counts as arrived
const ALLY_FOLLOW_INTERVAL_SEC: float = 1.0
## Trail offset — small positive keeps the ally just behind the
## lead so the player's units take the front line on a calm
## advance. The combat-engaged override below ignores the
## trail entirely and attack-moves straight at the enclave.
const ALLY_TRAIL_OFFSET: float = 2.0
const ENEMY_ENCLAVE_CENTRE: Vector3 = Vector3(0.0, 0.0, -130.0)
const ALLY_SPAWN_X: float = -50.0
## Pulled in from 150 -> 135 so every spawn row (rows step +10
## further south for tanks + jackals) stays inside the map's
## playable area (-/+160 extent). Edge units were getting stuck
## off the navmesh at z=170 in the old layout.
const ALLY_SPAWN_Z: float = 135.0


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


## Timestamp at which the OIL stage entered, so the trigger
## can auto-skip after a fixed window if the player chooses
## not to bother capturing.
var _oil_stage_entry_sec: float = 0.0
const OIL_STAGE_AUTO_SKIP_SEC: float = 90.0


func _stage_oil_enter() -> void:
	_oil_stage_entry_sec = float(Time.get_ticks_msec()) / 1000.0


func _stage_oil_done() -> bool:
	# Advance as soon as the player owns ANY captured fuel
	# deposit (owner_id 0). Otherwise auto-skip after the
	# OIL_STAGE_AUTO_SKIP_SEC timer expires so the player can
	# choose to skip the side objective and field Rooks-only.
	for n: Node in get_tree().get_nodes_in_group("fuel_deposits"):
		if not is_instance_valid(n):
			continue
		if not ("owner_id" in n):
			continue
		if (n.get("owner_id") as int) == 0:
			return true
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	return (now_sec - _oil_stage_entry_sec) >= OIL_STAGE_AUTO_SKIP_SEC


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
	# through the foundry / yard / generators. Composition swap
	# from the previous Wraith+Harbinger mix to a faster strike
	# package per playtest — Harbingers are slow heavy artillery
	# walkers and lagged the air group too much.
	#
	# Layout (rows of staggered units, from south to north):
	#   Row 1 (z = spawn_z)        : 4 Wraith bombers, X spread
	#   Row 2 (z = spawn_z + 10)   : 2 Courier Tank squads
	#   Row 3 (z = spawn_z + 20)   : 3 Jackal squads
	for i: int in 4:
		var px: float = ALLY_SPAWN_X + (float(i) - 1.5) * 8.0
		var u: Node3D = _spawn_ally_unit(
			"res://resources/units/sable_wraith.tres",
			Vector3(px, 0.0, spawn_z),
		)
		if u:
			_ally_units.append(u)
	for i: int in 2:
		var px2: float = ALLY_SPAWN_X + (float(i) - 0.5) * 12.0
		var u2: Node3D = _spawn_ally_unit(
			"res://resources/units/sable_courier_tank.tres",
			Vector3(px2, 0.0, spawn_z + 10.0),
		)
		if u2:
			_ally_units.append(u2)
	for i: int in 3:
		var px3: float = ALLY_SPAWN_X + (float(i) - 1.0) * 9.0
		var u3: Node3D = _spawn_ally_unit(
			"res://resources/units/sable_jackal.tres",
			Vector3(px3, 0.0, spawn_z + 20.0),
		)
		if u3:
			_ally_units.append(u3)

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

	# Combat override applies in BOTH marching and following states.
	# As soon as ANY player or ally unit (or any neutral enclave
	# unit) is in an active engagement, the strike force commits
	# and attack-moves straight at the enclave. Issued ONCE on
	# the rising edge (false -> true) so the per-tick reset
	# inside command_attack_move (which clears _current_target)
	# doesn't keep wiping engagements every second — that bug
	# was making allies walk past enemies without firing until
	# they touched the enclave HQ.
	var combat_now: bool = _any_friendly_in_combat() or _any_enclave_taking_fire()
	if combat_now:
		if not _ally_attack_committed:
			_ally_attack_committed = true
			for u_atk: Node3D in _ally_units:
				var combat_atk: Node = u_atk.get_node_or_null("CombatComponent")
				if combat_atk and combat_atk.has_method("command_attack_move"):
					combat_atk.call("command_attack_move", ENEMY_ENCLAVE_CENTRE)
				elif u_atk.has_method("command_move"):
					u_atk.call("command_move", ENEMY_ENCLAVE_CENTRE)
		# Stay in whatever state we were in — the override gets
		# checked again next tick. The combat path returns early
		# so the centroid-trail logic doesn't compete with the
		# attack-move while engagement is active.
		return
	# Disengaged — reset the latch so the next fight re-commits.
	if _ally_attack_committed:
		_ally_attack_committed = false

	if _ally_state == &"marching":
		# Switched from "centroid within radius" to "ANY ally
		# unit within radius" — a single ally stuck on the map
		# edge would otherwise drag the centroid out of range
		# forever and the strike force never flipped to follow.
		for u_check: Node3D in _ally_units:
			if u_check.global_position.distance_squared_to(ALLY_RALLY_POINT) <= ALLY_RALLY_ARRIVE_SQ:
				_ally_state = &"following"
				_ally_follow_accum = ALLY_FOLLOW_INTERVAL_SEC  # fire immediately
				break
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


func _combat_target_is_live(combat: Node, key: String) -> bool:
	## Defensive read for combat target slots. Even `v is Object`
	## throws "Left operand of 'is' is a previously freed
	## instance" in Godot 4 when the Variant holds a stale
	## reference, so we type-check via typeof() FIRST (operates
	## on the Variant container, doesn't dereference) and only
	## then run is_instance_valid (which is documented safe on
	## freed references).
	var v: Variant = combat.get(key)
	if typeof(v) != TYPE_OBJECT:
		return false
	if not is_instance_valid(v):
		return false
	return true


func _any_friendly_in_combat() -> bool:
	## True when ANY friendly unit (player- or ally-owned) has a
	## live target in its CombatComponent — i.e. shots are flying
	## somewhere in the strike force right now. Cheap walk; bails
	## on the first engaged unit found.
	for n: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(n):
			continue
		var owner_id: int = (n.get("owner_id") as int) if "owner_id" in n else -1
		if owner_id != 0 and owner_id != 1:
			continue
		if "alive_count" in n and (n.get("alive_count") as int) <= 0:
			continue
		var combat: Node = n.get_node_or_null("CombatComponent")
		if not combat:
			continue
		if _combat_target_is_live(combat, "_current_target"):
			return true
		if _combat_target_is_live(combat, "forced_target"):
			return true
	return false


func _any_enclave_taking_fire() -> bool:
	## True when an enclave unit OR enclave building is being
	## shot at by friendly fire — caught via the targeting hook
	## on enclave units (their CombatComponent gains a
	## _current_target = friendly unit when retaliating) AND via
	## current-HP-vs-max on enclave buildings (any structure
	## below full HP must have been shot). Lets the strike force
	## react to player-initiated combat even before either side's
	## fire callback has fully resolved on the friendly half.
	for n: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(n):
			continue
		var owner_id: int = (n.get("owner_id") as int) if "owner_id" in n else -1
		if owner_id != 2:  # 2 = NEUTRAL pseudo-player == enclave
			continue
		if "alive_count" in n and (n.get("alive_count") as int) <= 0:
			continue
		var combat: Node = n.get_node_or_null("CombatComponent")
		if combat and _combat_target_is_live(combat, "_current_target"):
			return true
		var stats: UnitStatResource = n.get("stats") as UnitStatResource if "stats" in n else null
		if stats and n.has_method("get_total_hp"):
			var hp: int = n.call("get_total_hp") as int
			if hp > 0 and hp < (stats.hp_total as int):
				return true
	for n: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(n):
			continue
		var b_owner: int = (n.get("owner_id") as int) if "owner_id" in n else -1
		if b_owner != 2:
			continue
		var b: Building = n as Building
		if not b or not b.stats:
			continue
		if b.current_hp > 0 and b.current_hp < (b.stats.hp as int):
			return true
	return false


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
	# Two Sable Specter (light infantry) squads spawn at the
	# northern enclave edge (-Z) and march south toward the
	# player base. Owner 2 (NEUTRAL pseudo-player) so they read
	# as enemy — same slot the enclave defenders use. Light
	# infantry instead of Courier Tanks because the player is
	# still building up early-economy and a tank squad was
	# punching above the player's defensive weight.
	var raid_z: float = -110.0
	# A single Specter squad — small enough to read as a probe /
	# scout contact rather than a real attack, just enough to
	# telegraph "the enemy is in the north" before the climax.
	var u: Node3D = _spawn_tutorial_raid_unit(
		"res://resources/units/sable_specter.tres",
		Vector3(0.0, 0.0, raid_z),
	)
	if u and u.has_method("command_move"):
		u.call("command_move", Vector3(0.0, 0.0, 80.0))
	var alerts: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if alerts and alerts.has_method("emit_alert"):
		alerts.call(
			"emit_alert",
			"Sable scout contact inbound from the north",
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
	# Win the moment the enemy HQ falls -- the player having to also
	# clean up every remaining turret made the climactic beat fizzle
	# into a chip-damage cleanup phase. Enemy team is id 2 in tutorial.
	for n: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(n):
			continue
		if not ("owner_id" in n):
			continue
		var oid: int = n.get("owner_id") as int
		if oid == 0 or oid == 1:
			continue
		var bstats: BuildingStatResource = (n.get("stats") as BuildingStatResource) if "stats" in n else null
		if bstats and bstats.building_id == &"headquarters":
			# Enemy HQ still standing -- mission isn't over yet.
			return false
	return true


## Beat between the closing dialogue line typing in and the
## end-of-match overlay popping up. The HUD typewriter runs
## ~32 chars/sec on stage entry — the closing line is ~110
## chars (~3.4s) so this gives roughly one second of silence
## after the line lands before the victory screen takes the
## scene. MatchManager then layers its own ~4.5s grace delay
## on top before fading the panel in.
const WIN_DIALOGUE_BEAT_SEC: float = 5.0


func _stage_win_enter() -> void:
	# Closing dialogue is published the moment this stage is
	# entered (the HUD picks it up via current_stage_dialogue()).
	# Hold the actual match-end call long enough for the line to
	# type out and breathe before the victory overlay appears.
	get_tree().create_timer(WIN_DIALOGUE_BEAT_SEC).timeout.connect(_fire_victory)


func _fire_victory() -> void:
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
