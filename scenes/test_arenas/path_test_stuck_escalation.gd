extends Node3D
## PC Phase 2 test: stuck escalation through Levels 1→2→3→4.
##
## Spawns one anvil_hound at (-30, 0, 0). Commands move to
## (-200, 0, -200) — well outside the navmesh on this map.
## Expected sequence:
##   t≈0.5s: Level 1 repath fires (silent retry)
##   t≈2.0s: Level 2 push-out (visible nudge)
##   t≈4.5s: Level 3 drop from group + wider goal snap
##   t≈7.5s: Level 4 emit path_unreachable → halt
## Watch the console for [PC-PA2] log lines and the unit's behavior.

const SPAWN := Vector3(-30, 0, 0)
const UNREACHABLE_GOAL := Vector3(-200, 0, -200)

func _ready() -> void:
	print_debug("[PC-PA2] path_test_stuck_escalation starting")
	var arena: Node = $TestArena if has_node("TestArena") else null
	if arena == null:
		push_warning("[PC-PA2] TestArena not found")
		return
	var units_node: Node = arena.get_node_or_null("Units")
	if units_node == null:
		return
	var u: Node = _spawn_unit("anvil_hound", SPAWN, units_node)
	if u == null:
		return
	var mc: Node = u.get_node_or_null("MovementComponent")
	if mc != null and mc is MovementComponent:
		mc.path_unreachable.connect(_on_path_unreachable.bind(u))
	await get_tree().create_timer(0.5).timeout
	if u.has_method("command_move"):
		u.command_move(UNREACHABLE_GOAL, true)

func _on_path_unreachable(reason: int, unit: Node) -> void:
	var unit_name: String = unit.name if is_instance_valid(unit) else "<freed>"
	print_debug("[PC-PA2] path_unreachable fired on ", unit_name, " reason=", reason)

func _spawn_unit(stats_path: String, pos: Vector3, parent: Node) -> Node:
	var unit_scene: PackedScene = load("res://scenes/unit.tscn")
	if unit_scene == null:
		return null
	var stats: Resource = load("res://resources/units/" + stats_path + ".tres")
	if stats == null:
		return null
	var u: Node = unit_scene.instantiate()
	u.set("stats", stats)
	u.set("owner_id", 0)
	parent.add_child(u)
	u.global_position = pos
	return u
