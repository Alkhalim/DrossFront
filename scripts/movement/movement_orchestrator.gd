class_name MovementOrchestrator
extends Node
## One physics tick callback that drives every registered
## MovementComponent. Removes the per-unit `_physics_process`
## dispatch overhead that scaled linearly with unit count
## (~0.05 ms × 200 units = 10 ms / tick of pure Godot overhead
## before any script work). Also lets us stagger heavy steering
## across frames cheaply: each component can choose to skip its
## expensive separate/avoid composition on alternate ticks while
## the orchestrator still integrates position every tick so motion
## stays smooth.
##
## Lifecycle:
##   - MovementComponent._ready calls register(self) and disables
##     its own _physics_process.
##   - MovementComponent._exit_tree calls unregister(self).
##   - On each physics tick we walk the registered list and call
##     each component's tick_movement(delta, heavy_tick).
##
## The orchestrator is created lazily via get_instance(scene_root),
## mirroring the SpatialIndex / NavRouter pattern, so existing
## scenes don't need wiring updates.

static func get_instance(scene_root: Node) -> MovementOrchestrator:
	## Returns the singleton MovementOrchestrator under the scene
	## root, creating it lazily if missing.
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null("MovementOrchestrator")
	if existing and existing is MovementOrchestrator:
		return existing as MovementOrchestrator
	var orch := MovementOrchestrator.new()
	orch.name = "MovementOrchestrator"
	scene_root.add_child(orch)
	return orch


## Registered components driven each physics tick. Indexed array
## (not Dictionary) because we walk it linearly every tick — array
## access is much faster than Dictionary iteration.
var _components: Array = []
## Frame counter used by per-component "heavy tick" stagger. We
## compute a 0/1 phase per frame from this so we don't have to
## query Engine.get_physics_frames() inside the hot loop.
var _frame_counter: int = 0


func register(mc: Object) -> void:
	if mc == null:
		return
	# Disable the component's own _physics_process so we get a
	# single callback per tick instead of one per component. The
	# component's tick_movement method is what we call below.
	if mc.has_method("set_physics_process"):
		mc.set_physics_process(false)
	_components.append(mc)


func unregister(mc: Object) -> void:
	if mc == null:
		return
	var idx: int = _components.find(mc)
	if idx >= 0:
		_components.remove_at(idx)


func _physics_process(delta: float) -> void:
	_frame_counter += 1
	# Phase bit lets components self-select whether THIS frame is
	# their "heavy" tick. Each component derives a stable phase
	# from its instance_id so the load spreads evenly across the
	# alternating frames.
	var frame_phase: int = _frame_counter & 1
	# Walk in reverse so a unregister mid-iteration (e.g., a
	# component freed during another component's tick) doesn't
	# corrupt the index. is_instance_valid filters freed handles.
	var i: int = _components.size() - 1
	while i >= 0:
		var mc: Object = _components[i]
		if not is_instance_valid(mc):
			_components.remove_at(i)
			i -= 1
			continue
		if mc.has_method("tick_movement"):
			mc.tick_movement(delta, frame_phase)
		i -= 1
