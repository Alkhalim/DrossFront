extends Node3D
## PA-19 test: range-rank-sorted squad-of-squads.
##
## Prerequisites:
##   drossfront/movement/use_new_system = true in project.godot
##
## Scenario:
##   Spawn 5 mixed-AG-range ground squads (and ideally one AA-only ground unit).
##   Select all and issue a move command. The SelectionManager routes them
##   through a SquadGroup with range_rank_sort applied. Observe:
##     - Low-AG-range squads (Hound/Specter, ~17u) are in the front slots.
##     - Long-AG-range squads (Bulwark, ~25u) are in the rear slots.
##     - AA-only (if present) goes to the middle slot.
##     - Convoy speed cap = slowest unit's speed.
##
## AA-only note:
##   No ground unit in the current roster satisfies is_aa_only() (all
##   ground units have at least one AG-capable weapon). The test spawns
##   5 AG squads across a wide range spread (17u → 25u). Add an AA-only
##   stat resource when one exists and uncomment the AA spawn below.
##
## Console markers:
##   [PA-19] STARTED — N units spawned, move issued.
##   [PA-19] WARNING: no AA-only unit in roster; AA-middle slot not tested.
##   [PA-19] ARRIVED — all units within ARRIVAL_THRESHOLD of goal at t=X.XX
##   [PA-19] TIMEOUT — not all units reached goal within Xs.

const GOAL: Vector3 = Vector3(30.0, 0.0, 30.0)
const ARRIVAL_THRESHOLD: float = 5.0
const TIMEOUT_SECONDS: float = 60.0

# Five AG squads spanning the full range spread used by range_rank_sort.
# Listed short → long so a reader can verify front-to-back ordering by eye.
#   anvil_hound    primary_weapon.range = 17u  (short AG,  fast)
#   sable_specter  primary_weapon.range = 17u  (short AG,  fast)
#   sable_jackal   primary_weapon.range = 20u  (mid   AG,  medium)
#   anvil_rook     primary_weapon.range = 17u  (mid   AG,  fast — scout)
#   anvil_bulwark  primary_weapon.range = 25u  (long  AG,  slow  — anchor)
const UNIT_STATS: Array[String] = [
	"res://resources/units/anvil_hound.tres",
	"res://resources/units/sable_specter.tres",
	"res://resources/units/sable_jackal.tres",
	"res://resources/units/anvil_rook.tres",
	"res://resources/units/anvil_bulwark.tres",
]
# If a true AA-only ground unit stat resource is added to the roster,
# uncomment this and the _spawn_aa_only call below.
# const AA_ONLY_STATS: String = "res://resources/units/REPLACE_WITH_AA_ONLY.tres"

var _units: Array[Node3D] = []
var _t: float = 0.0
var _move_issued: bool = false
var _done: bool = false


func _ready() -> void:
	print("[PA-19] STARTED — squad-of-squads range-rank test. New system must be ON.")
	push_warning("[PA-19] No AA-only ground unit exists in the current roster. " \
			+ "AA-middle slot ordering cannot be verified. " \
			+ "Add an AA-only stat resource and uncomment the AA spawn block.")

	# Spawn the AG squads spread along Z so they don't overlap.
	for i: int in UNIT_STATS.size():
		var z_offset: float = -float(UNIT_STATS.size() - 1) * 2.0 + float(i) * 4.0
		var spawn_pos: Vector3 = Vector3(-30.0, 0.0, z_offset)
		var u: Node3D = _spawn_unit(UNIT_STATS[i], spawn_pos, 0)
		if u:
			_units.append(u)

	# Uncomment to add an AA-only squad when one exists:
	# var aa_unit: Node3D = _spawn_unit(AA_ONLY_STATS, Vector3(-30.0, 0.0, 10.0), 0)
	# if aa_unit:
	#     _units.append(aa_unit)

	if _units.is_empty():
		push_error("[PA-19] No units spawned — check spawn helper.")
		return

	# Wait one frame + a short tick so all units finish _ready before the
	# command fires. The SelectionManager prunes dead units on command, so
	# units must be fully alive before we populate _selected_units.
	get_tree().create_timer(0.5).timeout.connect(_issue_move)


func _issue_move() -> void:
	# Force-populate the SelectionManager's _selected_units list. There is
	# no public select_units() API; we replicate what a click-drag does
	# by directly appending to the private array and calling unit.select().
	# This is safe for a test scene where the existing selection is empty.
	var sel: SelectionManager = _get_selection_manager()
	if not sel:
		push_error("[PA-19] SelectionManager not found — cannot issue move.")
		return

	for u: Node3D in _units:
		if not is_instance_valid(u):
			continue
		# Bypass _add_to_selection's owner_id==0 guard — units are owner 0.
		sel._selected_units.append(u)
		if u.has_method("select"):
			u.select()

	print("[PA-19] %d unit(s) selected, issuing move to %s" % [sel._selected_units.size(), str(GOAL)])
	sel.command_move_to_world(GOAL)
	_move_issued = true


func _process(delta: float) -> void:
	if _done or not _move_issued:
		return
	_t += delta

	# Check all alive units have arrived.
	var arrived: int = 0
	var alive: int = 0
	for u: Node3D in _units:
		if not is_instance_valid(u):
			continue
		var ac: int = u.get("alive_count") if "alive_count" in u else 1
		if ac <= 0:
			continue
		alive += 1
		if u.global_position.distance_to(GOAL) <= ARRIVAL_THRESHOLD:
			arrived += 1

	if alive > 0 and arrived >= alive:
		print("[PA-19] ARRIVED — %d/%d units at goal at t=%.2f" % [arrived, alive, _t])
		_done = true
		set_process(false)
		return

	if _t >= TIMEOUT_SECONDS:
		print("[PA-19] TIMEOUT — %d/%d alive units reached goal within %.0fs" % [arrived, alive, TIMEOUT_SECONDS])
		_done = true
		set_process(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _spawn_unit(stats_path: String, pos: Vector3, owner_id: int) -> Node3D:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		push_error("[PA-19] _spawn_unit: could not load stats from '%s'" % stats_path)
		return null
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	if not unit_scene:
		push_error("[PA-19] _spawn_unit: could not load res://scenes/unit.tscn")
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


func _get_selection_manager() -> SelectionManager:
	# The SelectionManager lives as a direct child of the test arena root.
	# When instanced under our Node3D parent, it's one level deeper.
	var sm: Node = get_node_or_null("TestArena/SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	# Fallback: walk the current scene root.
	sm = get_tree().current_scene.get_node_or_null("SelectionManager")
	if sm is SelectionManager:
		return sm as SelectionManager
	push_error("[PA-19] _get_selection_manager: could not find SelectionManager in scene tree.")
	return null
