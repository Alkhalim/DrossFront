extends SceneTree
## Headless parity test: verify MeridianContractsManager baseline regen.
## Run: godot --headless --script tools/test_meridian_contracts.gd --path .
## Exits 0 on success, 1 on assertion failure.

func _initialize() -> void:
	var mcm: MeridianContractsManager = MeridianContractsManager.new()
	root.add_child(mcm)
	# Initial pool starts at 1. Spend it down to 0.
	assert(mcm.spend(0, 1), "Initial spend failed")
	assert(mcm.get_contracts(0) == 0, "Expected 0 after full spend, got %d" % mcm.get_contracts(0))
	# Simulate 80 seconds of physics @ 0.05s/tick = 1600 ticks. With
	# BASELINE_REGEN_INTERVAL=75.0 the manager should grant 1 contract
	# (one at 75s; 80s elapsed is not enough for a second at 150s).
	for tick in 1600:
		mcm._process(0.05)
	var got: int = mcm.get_contracts(0)
	assert(got == 1, "Expected 1 contract after 80s baseline regen, got %d" % got)
	print("OK: baseline regen +1 in 80s, contracts=", got)
	quit(0)
