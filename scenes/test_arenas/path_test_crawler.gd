extends Node3D
## PB Phase 3: salvage crawler routes through narrow geometry under
## the new system. Set drossfront/movement/use_new_system = true.
##
## test_arena.tscn auto-spawns the crawler. The scene mainly exists
## to confirm the crawler starts moving without warnings about
## "navmesh ends short of chassis" (Plan A's known issue).

func _ready() -> void:
	print_debug("[PB-15] path_test_crawler starting")
	var arena: Node = $TestArena if has_node("TestArena") else null
	if arena == null:
		push_warning("[PB-15] TestArena child not found")
		return
	print_debug("[PB-15] scene loaded; observe crawler movement")
