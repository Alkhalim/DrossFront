extends Node3D
## PB-12 test: salvage workers gather wrecks under the new system.
##
## Prerequisites:
##   drossfront/movement/use_new_system = true in project.godot
##
## Scenario:
##   The test_arena.tscn provides a SalvageCrawler that auto-spawns
##   SalvageWorkers. Workers are autonomous — they self-organize to
##   find wrecks, path to them (using the new GroundMovement system
##   with squad_size=1), harvest salvage, and return to the crawler.
##
##   This test scene just instanes test_arena.tscn, confirms it loaded,
##   and lets workers run their AI loop. No manual selection/commands needed.
##
## Verification:
##   - Workers spawn from the crawler at regular intervals.
##   - Each worker moves toward the nearest wreck without getting stuck.
##   - Workers harvest and return to the crawler.
##   - Salvage counts increase as workers deposit cargo.
##
## Console markers:
##   [PB-12] STARTED — arena loaded, worker auto-spawn cycle active.
##   [PB-12] Arena did not load correctly — check TestArena node.


func _ready() -> void:
	print_debug("PB-12 path_test_worker starting")

	var arena: Node = $TestArena if has_node("TestArena") else null
	if arena == null:
		push_warning("PB-12: TestArena child not found")
		return

	print("[PB-12] STARTED — arena loaded, worker auto-spawn cycle active.")
	print_debug("PB-12: scene loaded; observe workers gathering wrecks")
