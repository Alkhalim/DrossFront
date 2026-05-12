class_name MovementNativeBootstrap
extends Node
## Lazily creates and links the FlowFieldServer + SteeringKernel singletons
## once the scene is ready. Mirrors the pattern used by SpatialIndex /
## NavRouter / MovementOrchestrator.

static var _server: Object = null
static var _kernel: Object = null
static var _terrain_sweep_pending: bool = false
static var _building_sweep_pending: bool = false

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
		# DEFERRED one frame because get_server is typically called from a
		# unit's MovementComponent._ready, and Godot's depth-first post-order
		# _ready propagation means sibling buildings (e.g. PlayerHQ declared
		# AFTER Units in the .tscn) haven't joined the "buildings" group yet
		# at this point. Running the sweep immediately found 0 buildings on a
		# scene that pre-places HQ. Deferring to process_frame guarantees all
		# building._ready calls have completed and `add_to_group("buildings")`
		# has run. Newly-constructed buildings are picked up additively by
		# building.gd's mark_obstacle call in _on_constructed (T20).
		_schedule_building_sweep(scene_root)
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
			# Cliff guard: closest navmesh point that's near in XZ but high in
			# Y means the cell is at the base of a cliff/plateau, with the
			# only navmesh "nearby" being the ledge above. Without this check
			# the XZ-only distance sees the ledge as close (<= 2.5m XZ) and
			# leaves the base cell walkable — units flow into the vertical
			# wall and physically halt. 1.5m Y-delta covers normal plateau
			# / ramp-wall heights without affecting gentle slope cells.
			# Was: also marked off-mesh when dy > 1.5 to catch cliff bases.
			# That heuristic was wrong: a ramp surface at high Y also has
			# dy > 1.5 from the ground-level query, so ramp cells got marked
			# as obstacles and units routed to the closest cliff face instead
			# of taking the ramp. Cliff bases are now covered by the
			# elevation-walls AABB pass in _mark_existing_terrain_props
			# (commit 6fa4611), so the simple XZ-only off-mesh check is
			# sufficient here.
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


## Defer the building sweep one process frame so all sibling buildings have
## had their _ready run (and thus joined "buildings" group) before we walk it.
static func _schedule_building_sweep(scene_root: Node) -> void:
	if _building_sweep_pending:
		return
	_building_sweep_pending = true
	var tree: SceneTree = scene_root.get_tree() if scene_root else null
	if tree == null:
		_building_sweep_pending = false
		return
	tree.process_frame.connect(_run_deferred_building_sweep.bind(scene_root), CONNECT_ONE_SHOT)


static func _run_deferred_building_sweep(scene_root: Node) -> void:
	_building_sweep_pending = false
	if _server == null:
		return
	if scene_root == null or not is_instance_valid(scene_root):
		return
	_mark_existing_buildings(scene_root)
	_mark_existing_nav_obstacles(scene_root)
	_mark_existing_terrain_props(scene_root)
	# Bug C fix: the plateau body BoxShape3D gets marked as an obstacle by
	# _mark_existing_terrain_props (it's in "elevation" but has a BoxShape3D,
	# not ConvexPolygonShape3D, so the elevation-top skip doesn't apply).
	# That AABB covers the entire plateau footprint including the ramp-top
	# connection zone, blocking cells where units need to step from the ramp
	# onto the plateau. Clear obstacle marks for all ramp bodies (identified
	# by ConvexPolygonShape3D in the "elevation" group) so those cells
	# remain walkable.
	_clear_ramp_obstacles(scene_root)


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


## Sweeps the "nav_obstacle" group for static, non-building props that need
## to be in the cost grid (rocks, ruins, houseblock debris, etc.). These
## don't go through building.gd's _on_constructed mark_obstacle hook, so
## without an explicit sweep they're invisible to the flow field and units
## walk into their colliders. Authors tag a prop by adding it to the
## "nav_obstacle" group; footprint comes from optional `nav_footprint_size`
## metadata (Vector3) or the AABB of the prop's first CollisionShape3D
## descendant, with a 4x2x4 fallback.
static func _mark_existing_nav_obstacles(scene_root: Node) -> void:
	if scene_root == null:
		return
	var tree: SceneTree = scene_root.get_tree()
	if tree == null:
		return
	var marked: int = 0
	for n: Node in tree.get_nodes_in_group("nav_obstacle"):
		if not is_instance_valid(n):
			continue
		if not (n is Node3D):
			continue
		var n3d: Node3D = n as Node3D
		var aabb: AABB = _resolve_nav_obstacle_aabb(n3d)
		_server.call("mark_obstacle", aabb, true)
		marked += 1
	print_debug("[MovementNativeBootstrap] marked %d pre-placed nav_obstacles" % marked)


static func _resolve_nav_obstacle_aabb(n: Node3D) -> AABB:
	# Author-supplied footprint via metadata; default 4x2x4 if absent. Set
	# `nav_footprint_size: Vector3` on the prop's root node in the editor
	# (Inspector → Node → Metadata → Add) to override.
	var fp: Vector3 = Vector3(4, 2, 4)
	if n.has_meta("nav_footprint_size"):
		var meta: Variant = n.get_meta("nav_footprint_size")
		if meta is Vector3:
			fp = meta as Vector3
	return AABB(
		n.global_position - Vector3(fp.x * 0.5, 0.0, fp.z * 0.5),
		fp)


## Sweeps the "terrain" group for static physical obstacles (rocks, ruins,
## scrap piles, boulders, fissures, forest trees, skyline features) that
## collide with units but aren't buildings. These are created procedurally
## by test_arena_controller.gd and ForestTree; they don't go through
## building.gd's mark_obstacle hook so they were invisible to the flow field,
## causing units to flow into them and get physically stuck.
##
## Exclusions to avoid false positives:
##   - Nodes in the "elevation" group (plateaus and ramps): already handled
##     by _mark_terrain_off_navmesh which marks their cliff-side cells as
##     off-navmesh.
##   - Nodes whose collision_layer does NOT have bit 2 set (layer 3, value 4):
##     catches GroundCollision (layer 1) which is in "terrain" for navmesh
##     baking but must stay walkable.
##
## Footprint: derived from the first CollisionShape3D child's shape extents
## so the marked AABB matches the actual physics collision, not a guess.
## Falls back to 3x2x3 if no CollisionShape3D is found.
static func _mark_existing_terrain_props(scene_root: Node) -> void:
	if scene_root == null:
		return
	var tree: SceneTree = scene_root.get_tree()
	if tree == null:
		return
	var marked: int = 0
	var marked_elevation_walls: int = 0
	var skipped_elevation: int = 0
	var skipped_layer: int = 0
	var skipped_buildings: int = 0
	for n: Node in tree.get_nodes_in_group("terrain"):
		if not is_instance_valid(n):
			continue
		if not (n is StaticBody3D):
			continue
		# Elevation nodes need special handling: plateau top bodies and ramp
		# bodies (ConvexPolygonShape3D) are walkable surfaces — skip them.
		# But side walls (BoxShape3D children of the plateau root) are vertical
		# cliffside colliders that units cannot pass through — mark them so the
		# flow field routes around them (i.e. through the ramp).
		if n.is_in_group("elevation"):
			var sb_elev: StaticBody3D = n as StaticBody3D
			var cs_elev: CollisionShape3D = null
			for child: Node in sb_elev.get_children():
				if child is CollisionShape3D:
					cs_elev = child as CollisionShape3D
					break
			if cs_elev == null or cs_elev.shape is ConvexPolygonShape3D:
				# Plateau top or ramp body — walkable surface, skip.
				skipped_elevation += 1
				continue
			# BoxShape3D (or any other) = side wall, fall through to mark.
		# Skip buildings — they're double-tagged (in BOTH "buildings" and
		# "terrain") and already handled by _mark_existing_buildings with
		# their stats.footprint_size. Marking them again here is redundant
		# AND wrong for buildings that are also destinations: a Salvage
		# Yard marked as an obstacle blocks its own home cell, so workers
		# call goto_world repeatedly and trigger a Dijkstra rebuild storm.
		if n.is_in_group("buildings"):
			skipped_buildings += 1
			continue
		var sb: StaticBody3D = n as StaticBody3D
		# collision_layer bit 2 (value 4) = obstacle layer used by all terrain
		# props spawned by test_arena_controller.gd and ForestTree. Bit 0
		# (value 1) is the ground plane; skip it.
		if (sb.collision_layer & 4) == 0:
			skipped_layer += 1
			continue
		var aabb: AABB = _terrain_prop_aabb(sb)
		_server.call("mark_obstacle", aabb, true)
		if n.is_in_group("elevation"):
			marked_elevation_walls += 1
		else:
			marked += 1
	print_debug("[MovementNativeBootstrap] marked %d pre-placed terrain props + %d elevation side walls as flow-field obstacles (skipped %d elevation tops/ramps, %d buildings, %d non-obstacle-layer)" % [marked, marked_elevation_walls, skipped_elevation, skipped_buildings, skipped_layer])


## Derives an AABB for a terrain StaticBody3D from its first CollisionShape3D
## child. Uses the shape's extents (BoxShape3D.size, CylinderShape3D.radius /
## height, etc.) so the marked region matches the physics collider. Falls back
## to 3x2x3 if no recognisable shape is found.
static func _terrain_prop_aabb(sb: StaticBody3D) -> AABB:
	# Walk direct children only — terrain pieces have one CollisionShape3D
	# directly under the StaticBody3D root.
	for child: Node in sb.get_children():
		if not (child is CollisionShape3D):
			continue
		var cs: CollisionShape3D = child as CollisionShape3D
		if cs.shape == null:
			continue
		var ext: Vector3
		if cs.shape is BoxShape3D:
			var bs: BoxShape3D = cs.shape as BoxShape3D
			ext = bs.size * 0.5
		elif cs.shape is CylinderShape3D:
			var cy: CylinderShape3D = cs.shape as CylinderShape3D
			ext = Vector3(cy.radius, cy.height * 0.5, cy.radius)
		elif cs.shape is SphereShape3D:
			var sp: SphereShape3D = cs.shape as SphereShape3D
			ext = Vector3(sp.radius, sp.radius, sp.radius)
		elif cs.shape is CapsuleShape3D:
			var cap: CapsuleShape3D = cs.shape as CapsuleShape3D
			ext = Vector3(cap.radius, cap.height * 0.5 + cap.radius, cap.radius)
		else:
			# ConvexPolygon / ConcavePolygon: use global AABB from the shape's
			# bounding box. get_debug_mesh is expensive; skip and use fallback.
			break
		# The shape's position is relative to the StaticBody3D; account for it.
		var world_center: Vector3 = sb.global_position + cs.position
		return AABB(world_center - ext, ext * 2.0)
	# Fallback: 3x2x3 footprint centred on the body's global position.
	var fallback: Vector3 = Vector3(3.0, 2.0, 3.0)
	return AABB(sb.global_position - fallback * 0.5, fallback)


## Un-marks obstacle cells that ramp bodies (ConvexPolygonShape3D in the
## "elevation" group) occupy. Run AFTER _mark_existing_terrain_props so the
## clear overwrites the plateau-body BoxShape3D mark that covers the ramp-top
## connection zone.
##
## For each ramp StaticBody3D, the ConvexPolygonShape3D points are in local
## space. We transform them to world space, compute an XZ-tight AABB, and call
## mark_obstacle(aabb, false) to restore walkability on those cells.
static func _clear_ramp_obstacles(scene_root: Node) -> void:
	if _server == null or scene_root == null:
		return
	var tree: SceneTree = scene_root.get_tree()
	if tree == null:
		return
	var cleared: int = 0
	for n: Node in tree.get_nodes_in_group("elevation"):
		if not is_instance_valid(n):
			continue
		if not (n is StaticBody3D):
			continue
		var sb: StaticBody3D = n as StaticBody3D
		# Ramp bodies are identified by having a ConvexPolygonShape3D.
		# Plateau bodies (BoxShape3D) and ramp side walls (BoxShape3D)
		# are already handled correctly — only ramp wedges need clearing.
		var cs: CollisionShape3D = null
		for child: Node in sb.get_children():
			if child is CollisionShape3D:
				cs = child as CollisionShape3D
				break
		if cs == null or not (cs.shape is ConvexPolygonShape3D):
			continue
		# Build a tight XZ AABB from the convex hull points in world space.
		# The ramp body's global_transform accounts for the parent's position
		# (plateau_center). Points are in local space relative to the StaticBody3D.
		var hull: ConvexPolygonShape3D = cs.shape as ConvexPolygonShape3D
		var pts: PackedVector3Array = hull.points
		if pts.is_empty():
			continue
		var gt: Transform3D = sb.global_transform
		var x_min: float = INF
		var x_max: float = -INF
		var z_min: float = INF
		var z_max: float = -INF
		var y_min: float = INF
		var y_max: float = -INF
		for pt: Vector3 in pts:
			var wp: Vector3 = gt * pt
			x_min = minf(x_min, wp.x)
			x_max = maxf(x_max, wp.x)
			z_min = minf(z_min, wp.z)
			z_max = maxf(z_max, wp.z)
			y_min = minf(y_min, wp.y)
			y_max = maxf(y_max, wp.y)
		# Slight inward inset (0.1m) so we don't accidentally clear cells
		# that belong to neighboring plateau-body or side-wall regions.
		const INSET: float = 0.1
		var aabb: AABB = AABB(
			Vector3(x_min + INSET, y_min, z_min + INSET),
			Vector3((x_max - x_min) - INSET * 2.0, y_max - y_min + 1.0, (z_max - z_min) - INSET * 2.0))
		_server.call("mark_obstacle", aabb, false)
		cleared += 1
	print_debug("[MovementNativeBootstrap] cleared obstacle marks on %d ramp bodies" % cleared)


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
