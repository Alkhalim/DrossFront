extends SceneTree
## Headless parity test: verify MeridianContractsManager baseline regen.
## Run: godot --headless --script tools/test_meridian_contracts.gd --path .
## Exits 0 on success, 1 on assertion failure.

func _initialize() -> void:
	var mcm: MeridianContractsManager = MeridianContractsManager.new()
	root.add_child(mcm)
	# Initial pool starts at MAX_CONTRACTS (8). Spend everything down to 0.
	for i in 8:
		assert(mcm.spend(0, 1), "Initial spend %d failed" % i)
	assert(mcm.get_contracts(0) == 0, "Expected 0 after full spend, got %d" % mcm.get_contracts(0))
	# Simulate 16 seconds of physics @ 0.05s/tick = 320 ticks. With
	# BASELINE_REGEN_INTERVAL=8.0 the manager should grant 2 contracts.
	for tick in 320:
		mcm._process(0.05)
	var got: int = mcm.get_contracts(0)
	assert(got == 2, "Expected 2 contracts after 16s baseline regen, got %d" % got)
	print("OK: baseline regen +2 in 16s, contracts=", got)
	quit(0)
