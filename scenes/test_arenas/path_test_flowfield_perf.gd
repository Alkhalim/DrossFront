extends Node3D
## PF perf scratchpad — 20 Anvil Hound squads per side, no win conditions.
##
## Spawns 20 hounds for owner 0 in a 5x4 grid centered at (-60, 0, 0) and
## 20 hounds for owner 1 in a mirrored grid at (60, 0, 0). Removes the
## test arena's pre-placed Ratchet/Rook/Hound units and PlayerHQ so the
## scene contains nothing except hounds (per the test brief). No commands
## are issued — user manually orders units to gauge perf under
## simultaneous mass-movement.

const SQUADS_PER_SIDE: int = 20
const GRID_COLS: int = 5
const GRID_ROWS: int = 4
const SPACING: float = 4.0
const PLAYER_CENTER: Vector3 = Vector3(-60, 0, 0)
const ENEMY_CENTER: Vector3 = Vector3(60, 0, 0)

func _ready() -> void:
	print_debug("[PF-PERF] path_test_flowfield_perf starting")
	if not MovementFlags.use_flowfield():
		push_warning("[PF-PERF] use_flowfield is OFF — set drossfront/movement/use_flowfield=true to exercise the new system")
	var arena: Node = $TestArena if has_node("TestArena") else null
	if arena == null:
		push_warning("[PF-PERF] TestArena child not found")
		return
	var units_node: Node = arena.get_node_or_null("Units")
	if units_node == null:
		push_warning("[PF-PERF] Units node not found")
		return

	# Strip pre-placed Ratchet/Rook/Hound units — perf test is hounds-only.
	for child: Node in units_node.get_children():
		child.queue_free()
	# Strip PlayerHQ for player-symmetry — neither side has an HQ.
	# disable_match_end (set by is_path_test()) prevents auto-defeat.
	var hq: Node = arena.get_node_or_null("PlayerHQ")
	if hq != null:
		hq.queue_free()

	# Wait one frame so the queue_freed nodes actually leave the tree
	# before we spawn replacements (otherwise SelectionManager / kernel
	# would briefly see both sets).
	await get_tree().process_frame

	var player_count: int = _spawn_grid(PLAYER_CENTER, 0, units_node)
	var enemy_count: int = _spawn_grid(ENEMY_CENTER, 1, units_node)
	print_debug("[PF-PERF] spawned %d player hounds, %d enemy hounds" % [player_count, enemy_count])


func _spawn_grid(center: Vector3, owner: int, parent: Node) -> int:
	var spawned: int = 0
	# Center the grid on `center`. Cols span x, rows span z.
	var x_offset: float = -float(GRID_COLS - 1) * 0.5 * SPACING
	var z_offset: float = -float(GRID_ROWS - 1) * 0.5 * SPACING
	for row: int in GRID_ROWS:
		for col: int in GRID_COLS:
			if spawned >= SQUADS_PER_SIDE:
				break
			var pos: Vector3 = center + Vector3(
				x_offset + col * SPACING,
				0.0,
				z_offset + row * SPACING)
			if _spawn_unit("anvil_hound", pos, owner, parent) != null:
				spawned += 1
	return spawned


func _spawn_unit(stats_path: String, pos: Vector3, owner: int, parent: Node) -> Node:
	var unit_scene: PackedScene = load("res://scenes/unit.tscn")
	if unit_scene == null:
		return null
	var stats: Resource = load("res://resources/units/" + stats_path + ".tres")
	if stats == null:
		return null
	var u: Node = unit_scene.instantiate()
	u.set("stats", stats)
	u.set("owner_id", owner)
	parent.add_child(u)
	u.global_position = pos
	return u
