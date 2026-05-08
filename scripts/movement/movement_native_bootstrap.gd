class_name MovementNativeBootstrap
extends Node
## Lazily creates and links the FlowFieldServer + SteeringKernel singletons
## once the scene is ready. Mirrors the pattern used by SpatialIndex /
## NavRouter / MovementOrchestrator.

static var _server: Object = null
static var _kernel: Object = null

static func get_server(scene_root: Node) -> Object:
	if _server == null:
		_server = ClassDB.instantiate("FlowFieldServer")
		if _server == null:
			push_error("FlowFieldServer not registered — extension not loaded?")
			return null
		# Default 320x320m map @ 2m cells, centered at world origin. Per-map
		# override: call configure_map again from arena setup.
		_server.call("configure_map", 160, 160, 2.0, -160.0, -160.0)
		_server.call("set_agent_radius", 0, 0.6)  # small
		_server.call("set_agent_radius", 1, 1.0)  # medium
		_server.call("set_agent_radius", 2, 2.0)  # large
	return _server

static func get_kernel(scene_root: Node) -> Object:
	if _kernel == null:
		_kernel = ClassDB.instantiate("SteeringKernel")
		if _kernel == null:
			push_error("SteeringKernel not registered — extension not loaded?")
			return null
		var server: Object = get_server(scene_root)
		if server != null and _kernel.has_method("set_flow_field_server"):
			_kernel.call("set_flow_field_server", server)
	return _kernel
