extends Node3D
## PA-11 test: provoke stuck Level 1 (repath).
##
## Prerequisites:
##   drossfront/movement/use_new_system = true in project.godot
##
## Scenario:
##   Spawn one anvil_hound at (-30, 0, 0). Command move to (30, 0, 0).
##   At t=2s, drop a fully-constructed neutral gun_emplacement_basic at
##   (0, 0, 0) directly on the path.
##
## Expected outcome:
##   The hound detects the newly-blocked path, repath fires (stuck Level 1),
##   and the hound detours around the building to reach the goal.
##
## Console markers:
##   [PA-11] STARTED
##   [PA-11] Building dropped at t=X.XX
##   [PA-11] REPATH OK — arrived at t=X.XX     (success)
##   [PA-11] TIMEOUT — hound never reached goal (failure)

const GOAL: Vector3 = Vector3(30.0, 0.0, 0.0)
const START: Vector3 = Vector3(-30.0, 0.0, 0.0)
const BLOCK_POS: Vector3 = Vector3(0.0, 0.0, 0.0)
const ARRIVAL_THRESHOLD: float = 2.5
const TIMEOUT_SECONDS: float = 30.0

var _t: float = 0.0
var _building_dropped: bool = false
var _hound: Node3D = null
var _done: bool = false


func _ready() -> void:
	print("[PA-11] STARTED — repath test. New system must be ON.")
	_hound = _spawn_unit("res://resources/units/anvil_hound.tres", START, 0)
	if not _hound:
		push_error("[PA-11] Failed to spawn unit — check spawn helper.")
		return
	# Defer move command one frame so the unit finishes _ready before
	# receiving any movement order.
	_hound.command_move(GOAL)


func _process(delta: float) -> void:
	if _done:
		return

	_t += delta

	# Drop the blocking building two seconds in.
	if not _building_dropped and _t >= 2.0:
		_building_dropped = true
		var b: Node = _spawn_blocking_building(BLOCK_POS)
		if b:
			print("[PA-11] Building dropped at t=%.2f" % _t)
		else:
			push_warning("[PA-11] Building spawn returned null at t=%.2f — repath may not trigger." % _t)

	# Check arrival.
	if _hound and is_instance_valid(_hound):
		var dist: float = _hound.global_position.distance_to(GOAL)
		if dist <= ARRIVAL_THRESHOLD:
			print("[PA-11] REPATH OK — arrived at t=%.2f (dist=%.2f)" % [_t, dist])
			_done = true
			set_process(false)
			return

	# Timeout guard.
	if _t >= TIMEOUT_SECONDS:
		print("[PA-11] TIMEOUT — hound never reached goal within %.0fs" % TIMEOUT_SECONDS)
		if _hound and is_instance_valid(_hound):
			print("[PA-11]   hound final pos: %s" % str(_hound.global_position))
		_done = true
		set_process(false)


# ---------------------------------------------------------------------------
# Spawn helpers — extracted from test_arena_controller.gd spawn patterns.
# ---------------------------------------------------------------------------

func _spawn_unit(stats_path: String, pos: Vector3, owner_id: int) -> Node3D:
	## Instantiates unit.tscn, assigns UnitStatResource and owner_id, adds to
	## scene tree, positions. Mirrors _spawn_ai_unit in test_arena_controller.gd.
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		push_error("[PA-11] _spawn_unit: could not load stats from '%s'" % stats_path)
		return null
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if not unit_scene:
		push_error("[PA-11] _spawn_unit: could not load res://scenes/unit.tscn")
		return null
	var unit: Node3D = unit_scene.instantiate() as Node3D
	if not unit:
		push_error("[PA-11] _spawn_unit: instantiate returned null")
		return null
	unit.set("stats", stats)
	unit.set("owner_id", owner_id)
	# Parent to the TestArena's Units node if present; else to self.
	var units_node: Node = get_node_or_null("TestArena/Units")
	if units_node:
		units_node.add_child(unit)
	else:
		add_child(unit)
	unit.global_position = pos
	return unit


func _spawn_blocking_building(pos: Vector3) -> Node:
	## Drops a fully-constructed neutral gun_emplacement_basic at pos.
	## Neutral owner_id=2 makes it hostile to both teams, matching how
	## _spawn_neutral_building works in test_arena_controller.gd.
	## The building registers on physics layer 4 (building collision)
	## so GroundMovement's navmesh bake will treat it as an obstacle.
	var stats: BuildingStatResource = load(
		"res://resources/buildings/gun_emplacement_basic.tres"
	) as BuildingStatResource
	if not stats:
		push_error("[PA-11] _spawn_blocking_building: could not load gun_emplacement_basic.tres")
		return null
	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	if not building_scene:
		push_error("[PA-11] _spawn_blocking_building: could not load building.tscn")
		return null
	var b: Node3D = building_scene.instantiate() as Node3D
	if not b:
		return null
	b.set("stats", stats)
	b.set("owner_id", 2)      # Neutral — hostile to both teams.
	b.set("is_constructed", true)  # Skip construction ramp; activate immediately.
	add_child(b)
	b.global_position = pos
	return b
