class_name NavRouter
extends Node
## Wraps NavigationServer3D for the new movement system. The ONLY
## code in the project that talks to NavigationServer3D for path
## queries — every MovementComponent / SquadGroup goes through here.
##
## Lives as a singleton-like node under the test arena scene root,
## same convention as SpatialIndex (scripts/spatial_index.gd:33).

static func get_instance(scene_root: Node) -> NavRouter:
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null("NavRouter")
	if existing and existing is NavRouter:
		return existing as NavRouter
	var router := NavRouter.new()
	router.name = "NavRouter"
	scene_root.add_child(router)
	return router

func query_path(start: Vector3,
		goal: Vector3,
		profile: AgentProfile) -> PathResult:
	## Returns a polyline path from start to goal for an agent of
	## the given profile. start is snapped to the nearest navmesh
	## position if off-mesh. Returns invalid PathResult if no path.
	var map_rid: RID = _map_rid_for(profile)
	if not map_rid.is_valid():
		return PathResult.new()
	var start_snapped: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, start)
	var path: PackedVector3Array = NavigationServer3D.map_get_path(
		map_rid, start_snapped, goal, true)
	return PathResult.new(path, path.size() >= 2)

func _map_rid_for(_profile: AgentProfile) -> RID:
	## Plan A: there is one navmesh per scene (the existing
	## NavigationRegion3D under test_arena). Plan B will introduce
	## per-profile maps for the crawler. For now, return the
	## default world map.
	var world_3d: World3D = get_world_3d()
	if world_3d == null:
		return RID()
	return world_3d.get_navigation_map()
