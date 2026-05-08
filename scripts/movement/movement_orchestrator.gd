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

## Holds the just-created orchestrator while its add_child is in
## the deferred queue. Without this, every MovementComponent that
## calls get_instance during the same scene-setup frame would
## create its own orchestrator (none of them yet visible via
## get_node_or_null) and queue a duplicate add_child. We'd end
## up with several orphan orchestrators colliding in the scene
## tree on the next idle frame. Cleared once the deferred add
## resolves and the orch is reachable via get_node_or_null.
static var _pending_instance: MovementOrchestrator = null


static func get_instance(scene_root: Node) -> MovementOrchestrator:
	## Returns the singleton MovementOrchestrator under the scene
	## root, creating it lazily if missing. Uses
	## add_child.call_deferred so we don't trip the
	## "Parent node is busy setting up children" guard when
	## components get created during scene init.
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null("MovementOrchestrator")
	if existing and existing is MovementOrchestrator:
		if _pending_instance == existing:
			_pending_instance = null
		return existing as MovementOrchestrator
	# Reuse the in-flight pending instance if it's still alive
	# (cleared on scene reload via is_instance_valid).
	if _pending_instance != null and is_instance_valid(_pending_instance):
		return _pending_instance
	var orch := MovementOrchestrator.new()
	orch.name = "MovementOrchestrator"
	_pending_instance = orch
	# Deferred add — safe even if scene_root is mid-setup. The
	# orchestrator's _physics_process won't fire until it actually
	# lands in the tree on the next idle frame, but components
	# can still register against it immediately because
	# register() only mutates the _components array.
	scene_root.add_child.call_deferred(orch)
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
	# Phase index lets components self-select whether THIS frame
	# is their "heavy" tick. Each component derives a stable
	# phase index in [0..STAGGER_PERIOD-1] from its instance_id
	# so the load spreads evenly across that many frames. Match
	# MovementComponent.STAGGER_PERIOD; using 3 here splits the
	# population into thirds and runs heavy work every 3rd tick
	# per unit.
	var frame_phase: int = _frame_counter % 3
	# Walk in reverse so a unregister mid-iteration (e.g., a
	# component freed during another component's tick) doesn't
	# corrupt the index. is_instance_valid filters freed handles.
	var i: int = _components.size() - 1
	while i >= 0:
		# Variant typing (untyped local) so reading a freed-instance
		# slot doesn't itself throw "Trying to assign invalid
		# previously freed instance" before our is_instance_valid
		# check can intercept. The typed `var mc: Object = ...` form
		# was triggering that error when a unit was queue_freed but
		# its component was still in our array.
		var mc_v: Variant = _components[i]
		if not is_instance_valid(mc_v):
			_components.remove_at(i)
			i -= 1
			continue
		# Typed cast — `register` only accepts MovementComponent
		# subclasses, so the cast always succeeds. Drops the per-call
		# `has_method("tick_movement")` string-keyed lookup that the
		# previous defensive build paid 200×/tick. tick_movement is
		# a real method on MovementComponent so the dispatch is a
		# direct vtable call rather than a Variant-typed indirection.
		var mc: MovementComponent = mc_v as MovementComponent
		if mc != null:
			# needs_tick gate — skip the tick_movement call for fully
			# parked components (no target, near-zero velocity, no
			# active stuck-pushout). With ~50% of units typically idle
			# in an RTS, halves the orchestrator's per-tick load.
			# needs_tick is a tiny field-only check; the savings come
			# from not paying the idle-path inertia / move_and_slide /
			# stuck_step overhead on parked units.
			if mc.needs_tick():
				mc.tick_movement(delta, frame_phase)
		i -= 1
