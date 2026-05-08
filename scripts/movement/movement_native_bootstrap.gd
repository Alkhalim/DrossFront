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
		# Sweep buildings already in the scene tree into the cost grid so the
		# first flow field built after server creation routes around them.
		# Newly-constructed buildings are picked up by the mark_obstacle call
		# in building.gd's _on_constructed hook (T20). This sweep covers the
		# arena's pre-placed structures (HQ, starting yards, etc.) which never
		# transition through _on_constructed.
		_mark_existing_buildings(scene_root)
	return _server


static func _mark_existing_buildings(scene_root: Node) -> void:
	if scene_root == null:
		return
	var tree: SceneTree = scene_root.get_tree()
	if tree == null:
		return
	for b: Node in tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(b):
			continue
		if not (b is Node3D):
			continue
		var b3d: Node3D = b as Node3D
		# Default footprint if the building lacks stats; covers the small
		# fraction of buildings (e.g. wreck-style props) that don't have
		# a UnitStatResource-equivalent.
		var fp_size: Vector3 = Vector3(4, 2, 4)
		if "stats" in b:
			var bstats: Resource = b.get("stats") as Resource
			if bstats != null and "footprint_size" in bstats:
				fp_size = bstats.footprint_size as Vector3
		var aabb: AABB = AABB(
			b3d.global_position - Vector3(fp_size.x * 0.5, 0.0, fp_size.z * 0.5),
			fp_size)
		_server.call("mark_obstacle", aabb, true)

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
