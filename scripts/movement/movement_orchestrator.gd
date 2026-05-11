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
	var frame_phase: int = _frame_counter % 3

	# PF-A: dual-path orchestration. Flag-on agents are driven by the
	# C++ SteeringKernel; flag-off agents run the legacy GDScript
	# tick_movement path. Both populations share this orchestrator's
	# _components array — `kernel_handle != 0` distinguishes them.
	var flowfield_on: bool = MovementFlags.use_flowfield()
	var kernel: Object = null
	if flowfield_on:
		kernel = MovementNativeBootstrap.get_kernel(get_tree().current_scene)

	# Phase 1: mirror positions into kernel SoA, then run kernel.tick once.
	if kernel != null:
		var i_a: int = _components.size() - 1
		while i_a >= 0:
			var mc_v: Variant = _components[i_a]
			if not is_instance_valid(mc_v):
				_components.remove_at(i_a)
				i_a -= 1
				continue
			var mc: MovementComponent = mc_v as MovementComponent
			if mc != null and mc.kernel_handle != 0:
				kernel.call("set_agent_pos", mc.kernel_handle, mc._body.global_position)
			i_a -= 1
		kernel.call("tick", delta)

		# PF-B-A7: Drain path_unreachable events the kernel pushed during
		# tick(). The kernel can't emit Godot signals (no Object identity
		# per agent), so it buffers events and we route them to the
		# matching component here. Build a quick handle→component map
		# so the per-event lookup is O(1).
		var handle_to_mc: Dictionary = {}
		var i_b: int = _components.size() - 1
		while i_b >= 0:
			var mc_v_b: Variant = _components[i_b]
			if is_instance_valid(mc_v_b):
				var mc_b: MovementComponent = mc_v_b as MovementComponent
				if mc_b != null and mc_b.kernel_handle != 0:
					handle_to_mc[mc_b.kernel_handle] = mc_b
			i_b -= 1
		while true:
			var ev: Vector2i = kernel.call("pop_path_unreachable_event") as Vector2i
			var ev_handle: int = ev.x
			if ev_handle == 0:
				break
			var ev_reason: int = ev.y
			var target_mc_v: Variant = handle_to_mc.get(ev_handle, null)
			if target_mc_v != null and is_instance_valid(target_mc_v):
				(target_mc_v as MovementComponent).emit_path_unreachable_from_kernel(ev_reason)

	# Phase 2: walk components. Flag-on units get velocity from the kernel
	# and apply via move_and_slide. Flag-off units run tick_movement.
	var i: int = _components.size() - 1
	while i >= 0:
		var mc_v: Variant = _components[i]
		if not is_instance_valid(mc_v):
			_components.remove_at(i)
			i -= 1
			continue
		var mc: MovementComponent = mc_v as MovementComponent
		if mc != null:
			if mc.kernel_handle != 0 and flowfield_on and kernel != null:
				# Flag-on path: kernel computed velocity; subclass applies it
				# (GroundMovement adds gravity + body yaw rotation; default
				# base just sets velocity + move_and_slide).
				var v: Vector3 = kernel.call("get_velocity", mc.kernel_handle) as Vector3
				mc._apply_kernel_velocity(v, delta)
			else:
				# Flag-off path: existing GDScript steering.
				if mc.needs_tick():
					mc.tick_movement(delta, frame_phase)
		i -= 1
