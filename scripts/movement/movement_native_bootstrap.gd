class_name MovementNativeBootstrap
extends Node
## Lazily creates and links the FlowFieldServer + SteeringKernel singletons
## once the scene is ready. Mirrors the pattern used by SpatialIndex /
## NavRouter / MovementOrchestrator.

static var _server: Object = null
static var _kernel: Object = null
static var _terrain_sweep_pending: bool = false

# Match the configure_map call below — keep these in sync if either changes.
const GRID_W: int = 160
const GRID_H: int = 160
const CELL_SIZE: float = 2.0
const ORIGIN_X: float = -160.0
const ORIGIN_Z: float = -160.0
# A cell whose center is more than this far from the nearest navmesh point
# is treated as off-mesh (cliff, void, untraversable terrain). Loosened
# from 1.5 to 2.5 (= ~1.25 cells) so plateau-edge cells whose centers are
# just past the navmesh polygon edge stay open. Too tight a threshold
# blocked legitimate plateau cells; too loose lets cliff overhangs leak
# in as traversable. 2.5 is the conservative-loose end of the tuning
# range; tighten if cliff edges become walkable in practice.
const OFF_MESH_DIST_THRESHOLD: float = 2.5

static func get_server(scene_root: Node) -> Object:
	if _server == null:
		_server = ClassDB.instantiate("FlowFieldServer")
		if _server == null:
			push_error("FlowFieldServer not registered — extension not loaded?")
			return null
		# Default 320x320m map @ 2m cells, centered at world origin. Per-map
		# override: call configure_map again from arena setup.
		_server.call("configure_map", GRID_W, GRID_H, CELL_SIZE, ORIGIN_X, ORIGIN_Z)
		# Bumped from 0.6/1.0/2.0 — the per-class agent_radius drives how
		# far building obstacles dilate in the cost grid, which in turn
		# determines how early flow redirects a unit away from a wall.
		# At 0.6m a hound's CharacterBody3D collision shape would reach
		# the wall before the field redirected sideways, leading to
		# inertia-vs-flow oscillation on frontal approach. Wider dilation
		# gives the flow a sharper sideways gradient earlier and lets
		# inertia turn before move_and_slide hits the wall. Trade-off:
		# tighter corridors get rejected as impassable.
		_server.call("set_agent_radius", 0, 1.0)  # small
		_server.call("set_agent_radius", 1, 1.4)  # medium
		_server.call("set_agent_radius", 2, 2.4)  # large
		print_debug("[MovementNativeBootstrap] server configured: %dx%d cells @ %.1fm, agent radii small=1.0 / medium=1.4 / large=2.4" % [GRID_W, GRID_H, CELL_SIZE])
		# Sweep buildings already in the scene tree into the cost grid so the
		# first flow field built after server creation routes around them.
		# Newly-constructed buildings are picked up by the mark_obstacle call
		# in building.gd's _on_constructed hook (T20). This sweep covers the
		# arena's pre-placed structures (HQ, starting yards, etc.) which never
		# transition through _on_constructed.
		_mark_existing_buildings(scene_root)
		# Schedule the terrain sweep — needs the navmesh to be synced first,
		# which doesn't happen until at least one process frame after scene
		# load, so we defer.
		_schedule_terrain_sweep(scene_root)
	return _server


## Schedule the terrain (off-navmesh) sweep. Defers one process frame so
## the NavigationServer3D map has time to sync after scene load — querying
## an unsynced map returns garbage and would blanket-mark every cell as
## blocked. Retries each frame until the map reports a non-zero iteration
## id (synced at least once) or scene_root is freed.
static func _schedule_terrain_sweep(scene_root: Node) -> void:
	if _terrain_sweep_pending:
		return
	_terrain_sweep_pending = true
	var tree: SceneTree = scene_root.get_tree() if scene_root else null
	if tree == null:
		_terrain_sweep_pending = false
		return
	tree.process_frame.connect(_try_terrain_sweep.bind(scene_root), CONNECT_ONE_SHOT)


static func _try_terrain_sweep(scene_root: Node) -> void:
	if _server == null:
		_terrain_sweep_pending = false
		return
	if scene_root == null or not is_instance_valid(scene_root):
		_terrain_sweep_pending = false
		return
	var world: World3D = scene_root.get_world_3d()
	if world == null:
		_terrain_sweep_pending = false
		return
	var map_rid: RID = world.get_navigation_map()
	if not map_rid.is_valid():
		_terrain_sweep_pending = false
		return
	var iter_id: int = NavigationServer3D.map_get_iteration_id(map_rid)
	if iter_id <= 0:
		# Map not synced yet — try again next frame.
		var tree: SceneTree = scene_root.get_tree()
		if tree:
			tree.process_frame.connect(_try_terrain_sweep.bind(scene_root), CONNECT_ONE_SHOT)
		return
	_mark_terrain_off_navmesh(map_rid)
	_terrain_sweep_pending = false


## Walks the cost grid; marks cells whose XZ center is too far from the
## nearest navmesh point as blocked, AND records each on-mesh cell's
## navmesh Y elevation so the C++ Dijkstra can reject neighbor expansion
## across cliffs. Catches cliffs, voids, untraversable terrain, and
## obstacles (like rocks) that aren't in the "buildings" group.
## Cost: GRID_W * GRID_H navmesh queries (~25k at default size). Runs once
## per scene load; ~50–200 ms hitch acceptable at scene start.
static func _mark_terrain_off_navmesh(map_rid: RID) -> void:
	var threshold_sq: float = OFF_MESH_DIST_THRESHOLD * OFF_MESH_DIST_THRESHOLD
	var marked_count: int = 0
	for cz: int in GRID_H:
		var wz: float = ORIGIN_Z + (cz + 0.5) * CELL_SIZE
		for cx: int in GRID_W:
			var wx: float = ORIGIN_X + (cx + 0.5) * CELL_SIZE
			var query_pos: Vector3 = Vector3(wx, 0.0, wz)
			var closest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, query_pos)
			var dx: float = closest.x - wx
			var dz: float = closest.z - wz
			if dx * dx + dz * dz > threshold_sq:
				# Off-mesh cell — mark blocked. Use a sub-cell AABB so floor/
				# ceil-1 lands exactly on this cell.
				var aabb: AABB = AABB(
					Vector3(wx - CELL_SIZE * 0.4, 0.0, wz - CELL_SIZE * 0.4),
					Vector3(CELL_SIZE * 0.8, 1.0, CELL_SIZE * 0.8))
				_server.call("mark_obstacle", aabb, true)
				marked_count += 1
			else:
				# Cell is on-mesh — record the navmesh's Y elevation here so
				# Dijkstra can use it to reject cliff transitions later.
				_server.call("set_cell_y_at", Vector3(wx, closest.y, wz), closest.y)
	var total_cells: int = GRID_W * GRID_H
	var pct: float = 100.0 * float(marked_count) / float(total_cells)
	# Diagnostic Y-range survey — quick sanity that the navmesh actually
	# has elevation. If min/max are both ~0, terrain ingestion isn't
	# providing meaningful Y deltas to the Dijkstra and cliff detection
	# can't fire. If min/max span the map's actual height range, Y data
	# is healthy.
	var y_min: float = INF
	var y_max: float = -INF
	for cz: int in GRID_H:
		var wz: float = ORIGIN_Z + (cz + 0.5) * CELL_SIZE
		for cx: int in GRID_W:
			var wx: float = ORIGIN_X + (cx + 0.5) * CELL_SIZE
			var closest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, Vector3(wx, 0.0, wz))
			y_min = minf(y_min, closest.y)
			y_max = maxf(y_max, closest.y)
	print_debug("[MovementNativeBootstrap] terrain sweep: marked %d / %d cells off-navmesh (%.1f%%) — threshold=%.2fm, Y range navmesh: %.2f .. %.2f" %
		[marked_count, total_cells, pct, OFF_MESH_DIST_THRESHOLD, y_min, y_max])


static func _mark_existing_buildings(scene_root: Node) -> void:
	if scene_root == null:
		return
	var tree: SceneTree = scene_root.get_tree()
	if tree == null:
		return
	var building_count: int = 0
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
		building_count += 1
	print_debug("[MovementNativeBootstrap] marked %d pre-placed buildings" % building_count)

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
