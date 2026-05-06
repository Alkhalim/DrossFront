class_name NavRouter
extends Node
## Wraps NavigationServer3D for the new movement system. The ONLY
## code in the project that talks to NavigationServer3D for path
## queries — every MovementComponent / SquadGroup goes through here.
##
## Lives as a singleton-like node under the test arena scene root,
## same convention as SpatialIndex (scripts/spatial_index.gd:33).

var _frame_cache: Dictionary = {}     # cache_key -> PathResult
var _last_clear_frame: int = -1

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
	## Identical queries within the same frame are coalesced.
	var cur_frame: int = Engine.get_process_frames()
	if cur_frame != _last_clear_frame:
		_frame_cache.clear()
		_last_clear_frame = cur_frame
	# Quantise start/goal to ~1u so nearby agents starting from
	# the same cell share the cache hit.
	var key: String = "%d:%d:%d:%d:%s" % [
		floori(start.x), floori(start.z),
		floori(goal.x),  floori(goal.z),
		profile.profile_id]
	if _frame_cache.has(key):
		return _frame_cache[key] as PathResult
	var map_rid: RID = _map_rid_for(profile)
	if not map_rid.is_valid():
		var miss := PathResult.new()
		_frame_cache[key] = miss
		return miss
	var start_snapped: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, start)
	var path: PackedVector3Array = NavigationServer3D.map_get_path(
		map_rid, start_snapped, goal, true)
	var result := PathResult.new(path, path.size() >= 2)
	_frame_cache[key] = result
	return result

func _map_rid_for(_profile: AgentProfile) -> RID:
	## Plan A: there is one navmesh per scene (the existing
	## NavigationRegion3D under test_arena). Plan B will introduce
	## per-profile maps for the crawler. For now, return the
	## default world map.
	##
	## NavRouter extends Node, not Node3D, so get_world_3d() is
	## not directly available. We fetch via the viewport.
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return RID()
	var world_3d: World3D = viewport.world_3d
	if world_3d == null:
		return RID()
	return world_3d.get_navigation_map()

func project_to_navmesh(world_pos: Vector3,
		profile: AgentProfile,
		max_distance: float = 8.0) -> Vector3:
	## Projects a world position onto the nearest valid navmesh cell.
	## Returns world_pos unchanged if it's already on the navmesh OR if
	## the nearest navmesh point is more than max_distance away (avoids
	## yanking the position implausibly far for off-map queries).
	##
	## Used by SquadGroup._slot_world to keep formation slots reachable
	## even when the slot's geometry-naive position would land in a
	## wall, building, or off-map void.
	var map_rid: RID = _map_rid_for(profile)
	if not map_rid.is_valid():
		return world_pos
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, world_pos)
	var d_sq: float = world_pos.distance_squared_to(snapped)
	var max_sq: float = max_distance * max_distance
	if d_sq > max_sq:
		# Snapped point is too far — likely the world_pos is in a deep
		# off-map region. Return the original; the caller's stuck
		# detector will catch the unreachable case via Phase 2 escalation.
		return world_pos
	return snapped

@warning_ignore("unused_parameter")
func update_obstacle_tile(aabb: AABB) -> void:
	## Plan A: forwards to the scene's existing navmesh rebake
	## debouncer (test_arena_controller.gd). Plan C replaces this
	## with a true tile-local rebake. The aabb argument is recorded
	## but not yet used.
	var arena: Node = get_parent()
	if arena and arena.has_method("request_navmesh_rebake"):
		arena.request_navmesh_rebake()
	# else: no arena hook available; navmesh will refresh on next
	# full bake. This is acceptable for Plan A because flag-off
	# code path still uses request_navmesh_rebake() directly.
