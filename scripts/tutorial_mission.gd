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


func _spawn_player_unit(stats_path: String, pos: Vector3) -> void:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		return
	var scene_path: String = "res://scenes/aircraft.tscn" if stats.is_aircraft else "res://scenes/unit.tscn"
	var ps: PackedScene = load(scene_path) as PackedScene
	if not ps:
		return
	var node: Node3D = ps.instantiate() as Node3D
	if not node:
		return
	node.set("stats", stats)
	node.set("owner_id", 0)
	var units_node: Node = get_tree().current_scene.get_node_or_null("Units")
	if units_node:
		units_node.add_child(node)
	else:
		get_tree().current_scene.add_child(node)
	node.global_position = pos


## --- Stage definitions ---------------------------------------------------

func _install_stages() -> void:
	# All discovery beats sit progressively further south (positive
	# Z in world space). Every dialogue line points the player in
	# the same direction so the navigation cue stays consistent
	# from start to finish.
	# Stage 0 — opening. The player has just their Rook scouts.
	_stages.append({
		"id": &"open",
		"dialogue": "Field Command: \"Scouts, advance south. There's a wreckage cache about a hundred meters out — survivors might be holed up there.\"",
		"objective": "Move your Rooks south to the wreckage.",
		"on_enter": Callable(self, "_stage_open_enter"),
		"trigger": Callable(self, "_stage_open_done"),
	})
	# Stage 1 — reinforcements found.
	_stages.append({
		"id": &"reinforce",
		"dialogue": "Field Command: \"Two more Rook squads are intact. Keep pushing south — we have a Salvage Crawler hulk on the long-range scope.\"",
		"objective": "Keep moving south to find the Crawler.",
		"on_enter": Callable(self, "_stage_reinforce_enter"),
		"trigger": Callable(self, "_stage_reinforce_done"),
	})
	# Stage 2 — Crawler.
	_stages.append({
		"id": &"crawler",
		"dialogue": "Field Command: \"That Crawler still runs — bring it with you. Push further south to the abandoned foundry.\"",
		"objective": "Continue south to the foundry ruin.",
		"on_enter": Callable(self, "_stage_crawler_enter"),
		"trigger": Callable(self, "_stage_crawler_done"),
	})
	# Stage 3 — base reclaimed. Player gets HQ + economy unlock.
	_stages.append({
		"id": &"base",
		"dialogue": "Field Command: \"Welcome to your forward base, commander. Build a Basic Foundry and a Salvage Yard — get production rolling.\"",
		"objective": "Build a Basic Foundry and a Salvage Yard.",
		"on_enter": Callable(self, "_stage_base_enter"),
		"trigger": Callable(self, "_stage_base_done"),
	})
	# Stage 4 — assemble strike force.
	_stages.append({
		"id": &"force",
		"dialogue": "Field Command: \"Train six combat units. The Sable enclave is dug in further south — we're going to dislodge them.\"",
		"objective": "Train at least 6 combat units (Rooks, Hounds, Phalanx).",
		"on_enter": Callable(self, "_stage_force_enter"),
		"trigger": Callable(self, "_stage_force_done"),
	})
	# Stage 5 — Sable ally arrives.
	_stages.append({
		"id": &"ally",
		"dialogue": "Field Command: \"A Sable strike force has dropped at our position. Coordinate with them and finish the enclave to the south.\"",
		"objective": "Push south and destroy the Sable enclave alongside your ally.",
		"on_enter": Callable(self, "_stage_ally_enter"),
		"trigger": Callable(self, "_stage_ally_done"),
	})
	# Stage 6 — victory.
	_stages.append({
		"id": &"win",
		"dialogue": "Field Command: \"Enclave neutralised. Tutorial complete — head back to the main menu when you're ready.\"",
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
	# Player walks any Rook into the wreckage cache zone.
	return _any_player_unit_in_radius(Vector3(0.0, 0.0, 28.0), VISIT_RADIUS_SQ)


func _stage_reinforce_enter() -> void:
	# Two more Rook squads spawn at the cache, slightly off-axis
	# so they don't all overlap the lead squad.
	_spawn_player_unit("res://resources/units/anvil_rook.tres", Vector3(-3.0, 0.0, 28.0))
	_spawn_player_unit("res://resources/units/anvil_rook.tres", Vector3(3.0, 0.0, 28.0))


func _stage_reinforce_done() -> bool:
	# Player walks units to the Crawler discovery point — further south.
	return _any_player_unit_in_radius(Vector3(0.0, 0.0, 58.0), VISIT_RADIUS_SQ)


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
	crawler.global_position = Vector3(0.0, 0.0, 58.0)


func _stage_crawler_done() -> bool:
	# Player advances south to the foundry ruin position.
	return _any_player_unit_in_radius(Vector3(0.0, 0.0, 88.0), VISIT_RADIUS_SQ)


func _stage_base_enter() -> void:
	# Hand the abandoned HQ over to the player. TestArenaController
	# parks it at (0, 0, 88) with owner_id 2 (neutral ruin) at
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
		if b.global_position.distance_squared_to(Vector3(0.0, 0.0, 88.0)) > 30.0 * 30.0:
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
	# fresh tutorial-mode HQ doesn't auto-spawn anything.
	_spawn_player_unit("res://resources/units/anvil_ratchet.tres", Vector3(-4.0, 0.0, 92.0))
	_spawn_player_unit("res://resources/units/anvil_ratchet.tres", Vector3(4.0, 0.0, 92.0))


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


func _stage_force_enter() -> void:
	pass


func _stage_force_done() -> bool:
	# Six combat-capable units (anything but engineers / crawlers).
	var combat: int = 0
	for u: Node3D in _player_units():
		var s: UnitStatResource = u.get("stats") as UnitStatResource
		if not s:
			continue
		if s.unit_class == &"engineer" or s.unit_class == &"crawler":
			continue
		combat += 1
	return combat >= 6


func _stage_ally_enter() -> void:
	# Sable ally drops in: a Harbinger heavy + two Switchblades for
	# anti-air. Owner_id = 1 with team 0 (allied to player) —
	# PlayerRegistry handles the alliance lookup.
	var ally_pos: Vector3 = Vector3(0.0, 0.0, 80.0)
	_spawn_ally_unit("res://resources/units/sable_harbinger.tres", ally_pos)
	_spawn_ally_unit("res://resources/units/sable_switchblade.tres", ally_pos + Vector3(8.0, 0.0, 0.0))
	_spawn_ally_unit("res://resources/units/sable_switchblade.tres", ally_pos + Vector3(-8.0, 0.0, 0.0))
	# Switch the playlist to the Sable folder so the moment the
	# ally arrives the score shifts character. MusicManager's
	# start() rebuilds the playlist + advances to a new track.
	var music_mgr: Node = get_tree().current_scene.get_node_or_null("MusicManager")
	if music_mgr and music_mgr.has_method("start"):
		music_mgr.call("start", 1)  # 1 = Sable


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


func _spawn_ally_unit(stats_path: String, pos: Vector3) -> void:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		return
	var scene_path: String = "res://scenes/aircraft.tscn" if stats.is_aircraft else "res://scenes/unit.tscn"
	var ps: PackedScene = load(scene_path) as PackedScene
	if not ps:
		return
	var node: Node3D = ps.instantiate() as Node3D
	if not node:
		return
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
