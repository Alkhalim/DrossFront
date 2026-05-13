extends Node3D
## PF-A pilot smoke test — flag-on Combine Borzoi through a minimal flow field.
##
## Spawns three Borzoi squads at (-30, 0, 0) / (-30, 0, -5) / (-30, 0, +5)
## and orders them to (30, 0, 0). Watch console: GroupAura prints field
## build counts; movement orchestrator drives kernel.tick. Expected: Borzoi
## navigate to the destination smoothly with mild flock cohesion.
##
## Pre-PF-A: Borzoi use SquadGroup slot logic (formation slots).
## Post-PF-A (with flag on): Borzoi use flow field + flock forces.

const SPAWN: Vector3 = Vector3(-30, 0, 0)
const DEST: Vector3 = Vector3(30, 0, 0)

func _ready() -> void:
	print_debug("[PF-A-21] path_test_flowfield_smoke starting")
	if not MovementFlags.use_flowfield():
		push_warning("[PF-A-21] use_flowfield is OFF — set drossfront/movement/use_flowfield=true to exercise the new system")
	var arena: Node = $TestArena if has_node("TestArena") else null
	if arena == null:
		push_warning("[PF-A-21] TestArena child not found")
		return
	var units_node: Node = arena.get_node_or_null("Units")
	if units_node == null:
		push_warning("[PF-A-21] Units node not found")
		return

	var spawned: Array[Node] = []
	var spawn_offsets: Array[Vector3] = [
		Vector3(0, 0, 0), Vector3(0, 0, -5), Vector3(0, 0, 5),
	]
	for off: Vector3 in spawn_offsets:
		var u: Node = _spawn_unit("anvil_hound", SPAWN + off, units_node)
		if u != null:
			spawned.append(u)

	await get_tree().create_timer(0.8).timeout
	if spawned.is_empty():
		return
	var sel: Node = arena.get_node_or_null("SelectionManager")
	if sel == null:
		return
	sel._selected_units.clear()
	for u: Node in spawned:
		sel._selected_units.append(u)
		if u.has_method("select"):
			u.select()
	sel.command_move_to_world(DEST)
	print_debug("[PF-A-21] move issued to ", DEST)

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
