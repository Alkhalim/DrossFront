extends Node3D
## PA-20 test: auto-rejoin after combat distraction.
##
## Prerequisites:
##   drossfront/movement/use_new_system = true in project.godot
##
## Scenario:
##   Spawn 5 anvil_hound squads in a column. Spawn one weak enemy building
##   (gun_emplacement_basic, ~1010 HP) positioned just off the main march path.
##   Issue an attack-move to a distant destination.
##
## Expected outcome:
##   The hound(s) nearest the enemy building engage, kill it, then resume march
##   and rejoin the group (SquadGroup auto-rejoin, spec §10). The building
##   should die within a reasonable time given Hound AP damage. No permanent
##   drop (unit rejoins rather than being abandoned).
##
## Console markers:
##   [PA-20] STARTED — 5 hounds spawned, attack-move issued.
##   [PA-20] Enemy building destroyed at t=X.XX
##   [PA-20] ARRIVED — all hounds within threshold at t=X.XX  (success)
##   [PA-20] TIMEOUT — not all hounds reached destination.

const DEST: Vector3 = Vector3(50.0, 0.0, 0.0)
# Building is placed off the march line (Z=-12) so attack-move naturally
# triggers engagement for the nearest hound(s) without blocking all of them.
const ENEMY_BUILDING_POS: Vector3 = Vector3(5.0, 0.0, -12.0)
const ARRIVAL_THRESHOLD: float = 6.0
const TIMEOUT_SECONDS: float = 90.0

var _hounds: Array[Node3D] = []
var _enemy_building: Node = null
var _building_dead_logged: bool = false
var _t: float = 0.0
var _move_issued: bool = false
var _done: bool = false


func _ready() -> void:
	print("[PA-20] STARTED — auto-rejoin test. New system must be ON.")

	# Spawn 5 hounds in a column along Z so they have natural spacing.
	for i: int in 5:
		var spawn_pos: Vector3 = Vector3(-30.0, 0.0, -8.0 + float(i) * 4.0)
		var u: Node3D = _spawn_unit(
			"res://resources/units/anvil_hound.tres", spawn_pos, 0
		)
		if u:
			_hounds.append(u)

	if _hounds.is_empty():
		push_error("[PA-20] No hounds spawned — check spawn helper.")
		return

	# Enemy building. Neutral owner_id=2 means it's hostile to all players
	# and will be shot at by attack-move.
	_enemy_building = _spawn_neutral_building(ENEMY_BUILDING_POS)
	if not _enemy_building:
		push_warning("[PA-20] Enemy building failed to spawn — rejoin may not trigger.")

	# Wait a half-second for all units to finish _ready.
	get_tree().create_timer(0.5).timeout.connect(_issue_attack_move)


func _issue_attack_move() -> void:
	var sel: SelectionManager = _get_selection_manager()
	if not sel:
		push_error("[PA-20] SelectionManager not found — cannot issue attack-move.")
		return

	for u: Node3D in _hounds:
		if not is_instance_valid(u):
			continue
		sel._selected_units.append(u)
		if u.has_method("select"):
			u.select()

	print("[PA-20] %d hound(s) selected, issuing attack-move to %s" % [sel._selected_units.size(), str(DEST)])
	sel.command_attack_move_to_world(DEST)
	_move_issued = true


func _process(delta: float) -> void:
	if _done or not _move_issued:
		return
	_t += delta

	# Log building death once.
	if not _building_dead_logged and _enemy_building:
		var valid: bool = is_instance_valid(_enemy_building)
		if not valid:
			print("[PA-20] Enemy building destroyed at t=%.2f" % _t)
			_building_dead_logged = true

	# Check arrival: all alive hounds near dest.
	var arrived: int = 0
	var alive: int = 0
	for u: Node3D in _hounds:
		if not is_instance_valid(u):
			continue
		var ac: int = u.get("alive_count") if "alive_count" in u else 1
		if ac <= 0:
			continue
		alive += 1
		if u.global_position.distance_to(DEST) <= ARRIVAL_THRESHOLD:
			arrived += 1

	if alive > 0 and arrived >= alive:
		print("[PA-20] ARRIVED — %d/%d hound(s) at dest at t=%.2f" % [arrived, alive, _t])
		_done = true
		set_process(false)
		return

	if _t >= TIMEOUT_SECONDS:
		print("[PA-20] TIMEOUT — %d/%d alive hound(s) reached dest within %.0fs" % [arrived, alive, TIMEOUT_SECONDS])
		_done = true
		set_process(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _spawn_unit(stats_path: String, pos: Vector3, owner_id: int) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		push_error("[PA-20] _spawn_unit: could not load stats '%s'" % stats_path)
		return null
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if not unit_scene:
		push_error("[PA-20] _spawn_unit: could not load unit.tscn")
		return null
	var unit: Node3D = unit_scene.instantiate() as Node3D
	if not unit:
		return null
	unit.set("stats", stats)
	unit.set("owner_id", owner_id)
	var units_node: Node = get_node_or_null("TestArena/Units")
	if units_node:
		units_node.add_child(unit)
	else:
		add_child(unit)
	unit.global_position = pos
	return unit


func _spawn_neutral_building(pos: Vector3) -> Node:
	## Spawns a fully-constructed neutral building at pos.
	## gun_emplacement_basic has ~1010 HP — weak enough that a Hound squad
	## (twin MGs, rapid fire) kills it within ~10-15s at full strength.
	var stats: BuildingStatResource = load(
		"res://resources/buildings/gun_emplacement_basic.tres"
	) as BuildingStatResource
	if not stats:
		push_error("[PA-20] _spawn_neutral_building: could not load gun_emplacement_basic.tres")
		return null
	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	if not building_scene:
		push_error("[PA-20] _spawn_neutral_building: could not load building.tscn")
		return null
	var b: Node3D = building_scene.instantiate() as Node3D
	if not b:
		return null
	b.set("stats", stats)
	b.set("owner_id", 2)           # Neutral — hostile to all.
	b.set("is_constructed", true)  # Active immediately.
	add_child(b)
	b.global_position = pos
	return b


func _get_selection_manager() -> SelectionManager:
	var sm: Node = get_node_or_null("TestArena/SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	sm = get_tree().current_scene.get_node_or_null("SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	push_error("[PA-20] _get_selection_manager: SelectionManager not found.")
	return null
