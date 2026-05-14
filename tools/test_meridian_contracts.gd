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
	# Simulate 36 seconds of physics @ 0.05s/tick = 720 ticks. With
	# BASELINE_REGEN_INTERVAL=18.0 the manager should grant 2 contracts
	# (one at 18s, one at 36s).
	for tick in 720:
		mcm._process(0.05)
	var got: int = mcm.get_contracts(0)
	assert(got == 2, "Expected 2 contracts after 36s baseline regen, got %d" % got)
	print("OK: baseline regen +2 in 36s, contracts=", got)
	quit(0)
