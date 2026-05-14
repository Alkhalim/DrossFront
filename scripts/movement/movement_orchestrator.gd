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
	# Fallback scan: get_node_or_null only matches by exact name, but
	# Godot auto-renames duplicate children (MovementOrchestrator2,
	# MovementOrchestrator3, …) when a deferred add races a prior one
	# that landed before this call. Scan direct children so we find
	# any existing MovementOrchestrator regardless of its assigned name.
	for child: Node in scene_root.get_children():
		if child is MovementOrchestrator and is_instance_valid(child):
			_pending_instance = null
			return child as MovementOrchestrator
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

## Cached kernel reference + Callables. Per-tick binding crossings
## via `Object.call("method_name", ...)` go through a StringName
## hash lookup on every call (~5-10 µs per crossing on a 200-unit
## tick that's 200 × 2 = 400 crossings = 2-4 ms of pure binding
## overhead). Cached Callables resolve the method name ONCE at
## construction, so subsequent `.call(args)` skip the lookup.
##
## Re-resolved lazily on the first physics tick that finds a non-null
## kernel; cleared back to null in unregister() if the kernel ever
## becomes invalid (scene reload).
var _kernel_cached: Object = null
var _set_agent_pos_c: Callable = Callable()
var _get_velocity_c: Callable = Callable()
var _tick_c: Callable = Callable()
var _pop_event_c: Callable = Callable()


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
	# Duplicate-instance guard. If multiple orchestrators somehow entered
	# the tree (deferred-add race that slipped past _pending_instance),
	# Godot renames the extras "MovementOrchestrator2", "…3", … so
	# get_node_or_null("MovementOrchestrator") keeps finding the first
	# one and the extras run forever un-noticed. Detect by scanning our
	# parent: the FIRST MovementOrchestrator child found is the primary;
	# any other that runs _physics_process self-destructs.
	var parent: Node = get_parent()
	if parent != null:
		for sibling: Node in parent.get_children():
			if sibling is MovementOrchestrator:
				if sibling != self:
					# An earlier sibling is the primary — we are a duplicate.
					push_warning("MovementOrchestrator: duplicate (%s) yielding to primary (%s)" % [name, sibling.name])
					set_physics_process(false)
					queue_free()
					return
				# sibling == self means we are first → we are the primary
				break

	_frame_counter += 1
	var frame_phase: int = _frame_counter % 3

	# PF-A: dual-path orchestration. Flag-on agents are driven by the
	# C++ SteeringKernel; flag-off agents run the legacy GDScript
	# tick_movement path. Both populations share this orchestrator's
	# _components array — `kernel_handle != 0` distinguishes them.
	var flowfield_on: bool = MovementFlags.use_flowfield()
	var kernel: Object = null
	if flowfield_on:
		kernel = _resolve_kernel()

	# Phase 1: mirror positions into kernel SoA, then run kernel.tick once.
	# We use cached Callables instead of `kernel.call("method_name", ...)`
	# because each .call(StringName, ...) does a per-call hash lookup in
	# the bound-methods table (~5-10 µs each). At 200 units that's
	# 200 × 2 (set_agent_pos + get_velocity) = 400 crossings per tick =
	# 2-4 ms of pure StringName overhead. Cached Callables resolve once.
	if kernel != null:
		# Single sweep: drop dead handles, mirror live agent positions
		# into the kernel SoA. Previously this took two separate walks
		# (one in Phase 1, one in Phase 2) plus a third walk to build
		# the handle→component map. Now we do it once and only build
		# the map lazily when the kernel actually has events to drain.
		var i_a: int = _components.size() - 1
		while i_a >= 0:
			var mc_v: Variant = _components[i_a]
			if not is_instance_valid(mc_v):
				_components.remove_at(i_a)
				i_a -= 1
				continue
			var mc: MovementComponent = mc_v as MovementComponent
			if mc != null and mc.kernel_handle != 0:
				# Skip the mirror call when the body hasn't moved since
				# last tick — the kernel SoA already holds the same
				# value. Parked / arrived units (typically 30-50% of
				# the population mid-battle) save the cached-callable
				# crossing every tick. Component-side _last_mirrored_pos
				# is initialized to INF so the first tick always mirrors.
				var pos: Vector3 = mc._body.global_position
				if pos != mc._last_mirrored_pos:
					_set_agent_pos_c.call(mc.kernel_handle, pos)
					mc._last_mirrored_pos = pos
			i_a -= 1
		_tick_c.call(delta)

		# PF-B-A7: Drain path_unreachable events the kernel pushed during
		# tick(). The kernel can't emit Godot signals (no Object identity
		# per agent), so it buffers events and we route them to the
		# matching component here.
		#
		# Optimization: peek at the queue first. The vast majority of
		# physics ticks have ZERO pending events (escalation L2 is rare —
		# a unit that's been stuck for 2+ seconds), so on those ticks we
		# can skip the entire handle→component map build. Building the
		# map on every tick was ~200 dictionary insertions × 5 µs =
		# 1 ms of pointless work for the common case.
		var first_ev: Vector2i = _pop_event_c.call() as Vector2i
		if first_ev.x != 0:
			# We have at least one event — build the map and process.
			var handle_to_mc: Dictionary = {}
			var i_b: int = _components.size() - 1
			while i_b >= 0:
				var mc_v_b: Variant = _components[i_b]
				if is_instance_valid(mc_v_b):
					var mc_b: MovementComponent = mc_v_b as MovementComponent
					if mc_b != null and mc_b.kernel_handle != 0:
						handle_to_mc[mc_b.kernel_handle] = mc_b
				i_b -= 1
			# Process the event we already popped, then drain the rest.
			# Hard cap protects against a hypothetical kernel bug returning
			# non-zero forever. 512 is well above any realistic per-tick
			# event count (200 agents × max 1 event each = 200).
			const MAX_DRAIN_PER_TICK: int = 512
			_dispatch_event(first_ev, handle_to_mc)
			var drained: int = 1
			while drained < MAX_DRAIN_PER_TICK:
				var ev: Vector2i = _pop_event_c.call() as Vector2i
				if ev.x == 0:
					break
				_dispatch_event(ev, handle_to_mc)
				drained += 1
			if drained >= MAX_DRAIN_PER_TICK:
				push_warning("MovementOrchestrator drained MAX_DRAIN_PER_TICK kernel events — possible kernel bug")

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
				var v: Vector3 = _get_velocity_c.call(mc.kernel_handle) as Vector3
				mc._apply_kernel_velocity(v, delta)
			else:
				# Flag-off path: existing GDScript steering.
				if mc.needs_tick():
					mc.tick_movement(delta, frame_phase)
		i -= 1


## Resolves the kernel (lazy-cached) and rebuilds the cached Callables
## if needed. Re-resolves transparently if the cached kernel was freed
## (scene reload) — a freed Object compares as != null but
## is_instance_valid returns false.
func _resolve_kernel() -> Object:
	if _kernel_cached != null and is_instance_valid(_kernel_cached):
		return _kernel_cached
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return null
	var k: Object = MovementNativeBootstrap.get_kernel(scene)
	if k == null:
		return null
	_kernel_cached = k
	# Cache Callables — these resolve the StringName ONCE here instead
	# of on every per-tick call. The performance gain matters at scale:
	# at 200 agents, set_agent_pos + get_velocity fire 400 times per tick.
	_set_agent_pos_c = Callable(k, "set_agent_pos")
	_get_velocity_c = Callable(k, "get_velocity")
	_tick_c = Callable(k, "tick")
	_pop_event_c = Callable(k, "pop_path_unreachable_event")
	return _kernel_cached


## Inline helper for path-unreachable event dispatch. Kept tiny so
## the hot drain loop stays cache-friendly — a single function call
## per event with no per-event allocations.
func _dispatch_event(ev: Vector2i, handle_to_mc: Dictionary) -> void:
	var target_mc_v: Variant = handle_to_mc.get(ev.x, null)
	if target_mc_v != null and is_instance_valid(target_mc_v):
		(target_mc_v as MovementComponent).emit_path_unreachable_from_kernel(ev.y)
