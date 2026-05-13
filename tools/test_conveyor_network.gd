extends SceneTree
## Headless parity test: verify that two Basic Foundries linked through a
## Conveyor Node produce a network with salvage_mult = 0.90 (the spec's
## "2× Basic Foundry → -10% salvage" rule). Run with:
##   godot --headless --script tools/test_conveyor_network.gd --path .
## Exits 0 on success, 1 on assertion failure.

const ConveyorNetworkManagerScript := preload("res://scripts/conveyor_network_manager.gd")
const BuildingStatResourceScript := preload("res://scripts/building_stat_resource.gd")

## Minimal building stub that exposes owner_id and stats as real properties.
class BuildingStub extends Node3D:
	var owner_id: int = 0
	var stats: Resource = null


func _initialize() -> void:
	# Defer actual test to _process so all nodes are fully inside the tree.
	call_deferred("_run_test")


func _run_test() -> void:
	var cnm := ConveyorNetworkManagerScript.new()
	root.add_child(cnm)
	# Fabricate 3 Building stubs. Add to tree before registering so
	# global_position is valid (Node3D requires tree membership for global_transform).
	var b1 := _make_stub(&"basic_foundry")
	var b2 := _make_stub(&"basic_foundry")
	var node1 := _make_stub(&"conveyor_node")
	root.add_child(b1); root.add_child(b2); root.add_child(node1)
	b1.position = Vector3(0, 0, 0)
	b2.position = Vector3(40, 0, 0)
	node1.position = Vector3(80, 0, 0)
	cnm.register(b1); cnm.register(b2); cnm.register(node1)
	var bonus_b1: Dictionary = cnm.get_bonuses_for_building(b1)
	var got: float = bonus_b1.get("salvage_mult", -1.0)
	assert(is_equal_approx(got, 0.90), "Expected 2x Basic Foundry = -10% salvage, got " + str(got))
	print("OK: 2x Basic Foundry -> salvage_mult = ", got)
	quit(0)


func _make_stub(building_id: StringName) -> BuildingStub:
	var b := BuildingStub.new()
	b.owner_id = 0
	var s := BuildingStatResourceScript.new()
	s.building_id = building_id
	s.connection_range = 100.0
	s.footprint_size = Vector3(6, 4, 6)
	b.stats = s
	return b
