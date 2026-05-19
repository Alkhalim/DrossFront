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
		# Large (crawler). Was 2.4u to match the chassis half-extent
		# (3.8×5.2 box -> ~2.6u center→corner), but that left gaps the
		# crawler could physically thread through marked as impassable.
		# 1.8u dilation lets the crawler navigate corridors ~5u wide
		# (1.8 dilation per side + chassis half = 2.5u, plus 0.5u
		# margin) — compensates for the crawler's slow turn rate by
		# giving the flow field more room to slip the chassis through.
		# Trade-off: kernel will route the crawler closer to walls than
		# before, so move_and_slide may push back on the chassis at
		# corners. The crawler arrival_radius=3.0 (commit 0d1a7b9) and
		# anchor-mode pause should absorb that.
		_server.call("set_agent_radius", 2, 1.8)  # large (crawler)
		print_debug("[MovementNativeBootstrap] server configured: %dx%d cells @ %.1fm, agent radii small=1.0 / medium=1.4 / large=1.8" % [GRID_W, GRID_H, CELL_SIZE])
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
	_apply_elevation_overrides(scene_root)
	_diagnose_ramp_y_sampling(map_rid, scene_root)
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


## Authoritative post-terrain-sweep pass over every elevation surface
## (plateau tops + ramp slopes). For each it (a) overwrites the stored
## cell_y with the TRUE geometric surface elevation and (b) clears any
## obstacle marks so the cells stay walkable in the flow field.
##
## Why this is needed — the navmesh-based _mark_terrain_off_navmesh is
## unreliable on elevated terrain:
##   * plateau-top cells: its Y=0 map_get_closest_point query is shadowed
##     by spurious ground navmesh UNDER the plateau, so cell_y collapses
##     to ~0 instead of the plateau height;
##   * ramp-top seam cells: the navmesh bake leaves small gaps there, so
##     cells get marked off-navmesh (blocked) and/or Y-sampled wrong.
## Either way the C++ Dijkstra sees a false cliff (cell_y delta beyond
## MAX_Y_DELTA) or a blocked cell at the ramp->plateau seam, and units
## can't path up. Deriving cell_y straight from the collision geometry
## removes the navmesh dependency entirely for these surfaces.
##
## Runs AFTER _mark_terrain_off_navmesh so it has the final word. It also
## subsumes the old _clear_ramp_obstacles pass, which ran in the earlier
## building sweep and was silently undone by the later terrain sweep.
## Plateau bodies are tagged `_plateau_walkable_top`; ramp wedges are the
## ConvexPolygonShape3D members of the "elevation" group. Ramp side walls
## (un-tagged BoxShape3D) are left marked — they are real obstacles.
static func _apply_elevation_overrides(scene_root: Node) -> void:
	if _server == null or scene_root == null or not is_instance_valid(scene_root):
		return
	var tree: SceneTree = scene_root.get_tree()
	if tree == null:
		return
	var plateaus: int = 0
	var ramps: int = 0
	var cells_set: int = 0
	for n: Node in tree.get_nodes_in_group("elevation"):
		if not is_instance_valid(n) or not (n is StaticBody3D):
			continue
		var sb: StaticBody3D = n as StaticBody3D
		var cs: CollisionShape3D = null
		for child: Node in sb.get_children():
			if child is CollisionShape3D:
				cs = child as CollisionShape3D
				break
		if cs == null or cs.shape == null:
			continue
		if sb.has_meta("_plateau_walkable_top") and cs.shape is BoxShape3D:
			# Plateau: flat top, one elevation across the whole footprint.
			var box: BoxShape3D = cs.shape as BoxShape3D
			var box_centre: Vector3 = cs.global_position
			var top_y: float = box_centre.y + box.size.y * 0.5
			cells_set += _override_footprint_flat(
				box_centre.x - box.size.x * 0.5, box_centre.x + box.size.x * 0.5,
				box_centre.z - box.size.z * 0.5, box_centre.z + box.size.z * 0.5,
				top_y)
			plateaus += 1
		elif cs.shape is ConvexPolygonShape3D:
			# Ramp wedge: cell_y ramps linearly foot(Y=lo) -> top(Y=hi).
			var hull: ConvexPolygonShape3D = cs.shape as ConvexPolygonShape3D
			var pts: PackedVector3Array = hull.points
			if pts.is_empty():
				continue
			var gt: Transform3D = sb.global_transform
			# World-space hull points + Y range + footprint XZ AABB.
			var wpts: Array[Vector3] = []
			var y_lo: float = INF
			var y_hi: float = -INF
			var x_min: float = INF
			var x_max: float = -INF
			var z_min: float = INF
			var z_max: float = -INF
			for p: Vector3 in pts:
				var wp: Vector3 = gt * p
				wpts.append(wp)
				y_lo = minf(y_lo, wp.y)
				y_hi = maxf(y_hi, wp.y)
				x_min = minf(x_min, wp.x)
				x_max = maxf(x_max, wp.x)
				z_min = minf(z_min, wp.z)
				z_max = maxf(z_max, wp.z)
			# Top edge = the max-Y hull points.
			var top_sum: Vector3 = Vector3.ZERO
			var top_pts: Array[Vector3] = []
			for wp: Vector3 in wpts:
				if absf(wp.y - y_hi) < 0.5:
					top_sum += wp
					top_pts.append(wp)
			if top_pts.is_empty():
				continue
			var top_mid: Vector3 = top_sum / float(top_pts.size())
			# Foot edge = the min-Y hull points that do NOT sit directly
			# below a top point. The ramp wedge also carries two min-Y
			# points stacked under the top edge (its vertical back face);
			# averaging those in would drag the foot midpoint halfway up
			# the ramp and skew the cell_y gradient.
			var foot_sum: Vector3 = Vector3.ZERO
			var foot_n: int = 0
			for wp2: Vector3 in wpts:
				if absf(wp2.y - y_lo) > 0.5:
					continue
				var under_top: bool = false
				for tp: Vector3 in top_pts:
					if Vector2(wp2.x - tp.x, wp2.z - tp.z).length() < 0.5:
						under_top = true
						break
				if not under_top:
					foot_sum += wp2
					foot_n += 1
			if foot_n == 0:
				continue
			var foot_mid: Vector3 = foot_sum / float(foot_n)
			var axis: Vector2 = Vector2(top_mid.x - foot_mid.x, top_mid.z - foot_mid.z)
			var run: float = axis.length()
			if run < 0.01:
				continue
			cells_set += _override_footprint_ramp(
				x_min, x_max, z_min, z_max,
				Vector2(foot_mid.x, foot_mid.z), axis / run, run, y_lo, y_hi - y_lo)
			ramps += 1
	print_debug("[MovementNativeBootstrap] elevation overrides: %d plateaus + %d ramps, %d cells re-elevated + un-blocked" % [plateaus, ramps, cells_set])


## Sets cell_y to a single flat `surface_y` for every cost-grid cell whose
## centre lies in the XZ rect, then clears any obstacle mark on the rect.
## Returns the number of cells whose elevation was set.
static func _override_footprint_flat(min_x: float, max_x: float, min_z: float, max_z: float, surface_y: float) -> int:
	var n: int = 0
	var cx0: int = floori((min_x - ORIGIN_X) / CELL_SIZE)
	var cx1: int = floori((max_x - ORIGIN_X) / CELL_SIZE)
	var cz0: int = floori((min_z - ORIGIN_Z) / CELL_SIZE)
	var cz1: int = floori((max_z - ORIGIN_Z) / CELL_SIZE)
	for cz: int in range(cz0, cz1 + 1):
		var wz: float = ORIGIN_Z + (float(cz) + 0.5) * CELL_SIZE
		if wz < min_z or wz > max_z:
			continue
		for cx: int in range(cx0, cx1 + 1):
			var wx: float = ORIGIN_X + (float(cx) + 0.5) * CELL_SIZE
			if wx < min_x or wx > max_x:
				continue
			# set_cell_y_at safely ignores off-grid cells (cell_of -> -1).
			_server.call("set_cell_y_at", Vector3(wx, surface_y, wz), surface_y)
			n += 1
	_server.call("mark_obstacle", AABB(
		Vector3(min_x, 0.0, min_z),
		Vector3(max_x - min_x, surface_y + 1.0, max_z - min_z)), false)
	return n


## Like _override_footprint_flat, but cell_y ramps linearly along `axis`
## from `base_y` at the foot to `base_y + height` at the top. `foot_xz` is
## the foot-edge midpoint and `run` the foot->top XZ distance; `axis` is
## the unit foot->top direction in XZ.
static func _override_footprint_ramp(min_x: float, max_x: float, min_z: float, max_z: float, foot_xz: Vector2, axis: Vector2, run: float, base_y: float, height: float) -> int:
	var n: int = 0
	var cx0: int = floori((min_x - ORIGIN_X) / CELL_SIZE)
	var cx1: int = floori((max_x - ORIGIN_X) / CELL_SIZE)
	var cz0: int = floori((min_z - ORIGIN_Z) / CELL_SIZE)
	var cz1: int = floori((max_z - ORIGIN_Z) / CELL_SIZE)
	for cz: int in range(cz0, cz1 + 1):
		var wz: float = ORIGIN_Z + (float(cz) + 0.5) * CELL_SIZE
		if wz < min_z or wz > max_z:
			continue
		for cx: int in range(cx0, cx1 + 1):
			var wx: float = ORIGIN_X + (float(cx) + 0.5) * CELL_SIZE
			if wx < min_x or wx > max_x:
				continue
			# Project the cell centre onto the run axis -> slope fraction.
			var d: float = (Vector2(wx, wz) - foot_xz).dot(axis)
			var s: float = clampf(d / run, 0.0, 1.0)
			var cell_y: float = base_y + s * height
			_server.call("set_cell_y_at", Vector3(wx, cell_y, wz), cell_y)
			n += 1
	_server.call("mark_obstacle", AABB(
		Vector3(min_x, 0.0, min_z),
		Vector3(max_x - min_x, base_y + height + 1.0, max_z - min_z)), false)
	return n


## DIAGNOSTIC (ramp-pathing investigation, 2026-05-19) — temporary.
## For every ramp body in the "elevation" group, reads back the LIVE flow-
## field cost grid (via FlowFieldServer.get_cell_cost_at / get_cell_y_at)
## along the ramp's foot->top->plateau centerline and across two 11x11 cell
## blocks around the ramp top. Reports, per cell: the cost byte (0 open /
## 255 blocked) and the stored elevation cell_y — the exact inputs the C++
## Dijkstra uses. Flags COST-BLOCKED cells and any adjacent-cell cell_y
## delta above MAX_Y_DELTA (cost_grid.h: 1.5m), which is what makes a cell
## pair non-traversable in the flow field.
##
## A healthy ramp+plateau shows cost=0 everywhere on the ramp and top, and
## a cell_y gradient whose every adjacent step is <= MAX_Y_DELTA. If the
## plateau top shows cost=255 or its cell_y collapses to ~0 at the ramp
## seam, units cannot path onto it. Remove this function once verified.
static func _diagnose_ramp_y_sampling(map_rid: RID, scene_root: Node) -> void:
	if scene_root == null or not is_instance_valid(scene_root):
		return
	var tree: SceneTree = scene_root.get_tree()
	if tree == null:
		return
	# Mirror of cost_grid.h MAX_Y_DELTA — keep in sync if that constant moves.
	const MAX_Y_DELTA: float = 1.5
	var ramp_idx: int = 0
	for n: Node in tree.get_nodes_in_group("elevation"):
		if not is_instance_valid(n) or not (n is StaticBody3D):
			continue
		var sb: StaticBody3D = n as StaticBody3D
		# Ramp bodies are the ConvexPolygonShape3D members of "elevation";
		# plateau bodies + side walls use BoxShape3D — skip those.
		var cs: CollisionShape3D = null
		for child: Node in sb.get_children():
			if child is CollisionShape3D:
				cs = child as CollisionShape3D
				break
		if cs == null or not (cs.shape is ConvexPolygonShape3D):
			continue
		var hull: ConvexPolygonShape3D = cs.shape as ConvexPolygonShape3D
		var pts: PackedVector3Array = hull.points
		if pts.is_empty():
			continue
		var gt: Transform3D = sb.global_transform
		# Split hull points into top edge (max world Y) and foot edge (min Y),
		# then take the midpoint of each so we can walk the ramp centerline.
		var y_lo: float = INF
		var y_hi: float = -INF
		for pt: Vector3 in pts:
			var wy: float = (gt * pt).y
			y_lo = minf(y_lo, wy)
			y_hi = maxf(y_hi, wy)
		var top_sum: Vector3 = Vector3.ZERO
		var bot_sum: Vector3 = Vector3.ZERO
		var top_n: int = 0
		var bot_n: int = 0
		for pt2: Vector3 in pts:
			var wp: Vector3 = gt * pt2
			if absf(wp.y - y_hi) < 0.5:
				top_sum += wp
				top_n += 1
			elif absf(wp.y - y_lo) < 0.5:
				bot_sum += wp
				bot_n += 1
		if top_n == 0 or bot_n == 0:
			continue
		var top_mid: Vector3 = top_sum / float(top_n)
		var bot_mid: Vector3 = bot_sum / float(bot_n)
		var axis: Vector3 = Vector3(top_mid.x - bot_mid.x, 0.0, top_mid.z - bot_mid.z)
		if axis.length() < 0.01:
			continue
		axis = axis.normalized()
		ramp_idx += 1
		print("[RampDiag] === ramp %d '%s' === foot~(%.1f,%.1f) top~(%.1f,%.1f) height=%.2f axis=(%.2f,%.2f)" % [
			ramp_idx, sb.name, bot_mid.x, bot_mid.z, top_mid.x, top_mid.z, y_hi - y_lo, axis.x, axis.z])
		# Centerline profile: from 6u before the foot to 10u past the top,
		# one sample per cell, snapped to cell centres. Reads the LIVE cost
		# grid: cost (0 open / 255 blocked, agent class 1) and cell_y. navY
		# is the navmesh surface from a Y=20 query, kept for reference.
		var prev_cell_y: float = INF
		var t: float = -6.0
		while t <= 10.0:
			var sample: Vector3 = bot_mid + axis * t
			var cx: int = floori((sample.x - ORIGIN_X) / CELL_SIZE)
			var cz: int = floori((sample.z - ORIGIN_Z) / CELL_SIZE)
			var wx: float = ORIGIN_X + (float(cx) + 0.5) * CELL_SIZE
			var wz: float = ORIGIN_Z + (float(cz) + 0.5) * CELL_SIZE
			var probe_pos: Vector3 = Vector3(wx, 0.0, wz)
			var nav_top: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, Vector3(wx, 20.0, wz))
			var cost: int = int(_server.call("get_cell_cost_at", probe_pos, 1))
			var cell_y: float = float(_server.call("get_cell_y_at", probe_pos))
			var flags: String = ""
			if cost >= 255:
				flags += "  [COST-BLOCKED]"
			if prev_cell_y != INF and absf(cell_y - prev_cell_y) > MAX_Y_DELTA:
				flags += "  <<< cellY-DELTA %.2f > %.2f — Dijkstra BLOCKS this transition" % [absf(cell_y - prev_cell_y), MAX_Y_DELTA]
			print("[RampDiag]   t=%+5.1f cell(%d,%d) cost=%d cellY=%.2f navY=%.2f%s" % [
				t, cx, cz, cost, cell_y, nav_top.y, flags])
			prev_cell_y = cell_y
			t += CELL_SIZE
		# Two 11x11 cell blocks around the ramp top, read from the live cost
		# grid. Block 1 = stored cell_y; block 2 = cost ('.' open / 'B'
		# blocked, agent class 1). A correctly-walkable plateau shows cell_y
		# at the plateau-top height and no 'B' on the top.
		var ctr_cx: int = floori((top_mid.x - ORIGIN_X) / CELL_SIZE)
		var ctr_cz: int = floori((top_mid.z - ORIGIN_Z) / CELL_SIZE)
		for mode: int in 2:
			if mode == 0:
				print("[RampDiag]   11x11 stored cell_y around ramp top (center cell %d,%d):" % [ctr_cx, ctr_cz])
			else:
				print("[RampDiag]   11x11 cost grid around ramp top ('.'=open 'B'=blocked):")
			for dz: int in range(-5, 6):
				var row: String = "[RampDiag]   "
				for dx: int in range(-5, 6):
					var bx: float = ORIGIN_X + (float(ctr_cx + dx) + 0.5) * CELL_SIZE
					var bz: float = ORIGIN_Z + (float(ctr_cz + dz) + 0.5) * CELL_SIZE
					var pp: Vector3 = Vector3(bx, 0.0, bz)
					if mode == 0:
						row += "%6.1f" % float(_server.call("get_cell_y_at", pp))
					else:
						var cc: int = int(_server.call("get_cell_cost_at", pp, 1))
						row += ("    B " if cc >= 255 else ("    . " if cc == 0 else "%5d " % cc))
				print(row)
	if ramp_idx == 0:
		print("[RampDiag] no ramp bodies found in 'elevation' group")


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
	# Plateau tops + ramp slopes are kept walkable by _apply_elevation_overrides,
	# which runs after the terrain sweep (see _try_terrain_sweep). It must run
	# there, not here: the terrain sweep would otherwise re-mark ramp-seam cells
	# off-navmesh after this building sweep finished.


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
			# Plateau bodies carry the `_plateau_walkable_top` meta: their
			# Box collider's TOP face is a walkable surface, so the cost
			# grid must NOT blanket the footprint as an obstacle. The cliff
			# edge is enforced by the C++ Dijkstra's cell_y / MAX_Y_DELTA
			# guard instead (and _apply_elevation_overrides sets the
			# correct top Y on those cells). Without this skip the plateau
			# top is COST_BLOCKED and units can never path onto it.
			if sb_elev.has_meta("_plateau_walkable_top"):
				skipped_elevation += 1
				continue
			var cs_elev: CollisionShape3D = null
			for child: Node in sb_elev.get_children():
				if child is CollisionShape3D:
					cs_elev = child as CollisionShape3D
					break
			if cs_elev == null or cs_elev.shape is ConvexPolygonShape3D:
				# Ramp wedge — walkable slope surface, skip.
				skipped_elevation += 1
				continue
			# BoxShape3D with no plateau meta = ramp side wall (a true
			# vertical obstacle) — fall through to mark.
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
