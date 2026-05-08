class_name SpatialIndex
extends Node
## Coarse spatial-bucket cache for "find nearby hostile units +
## buildings" queries. The 250-pop stress test profiler showed
## CombatComponent._find_nearest_enemy + _find_stray_target walking
## the full units + buildings groups (~250 entities each) per call;
## with 200+ shooter ticks per second that's hundreds of thousands
## of distance comparisons. A 16u grid (20x20 cells over a 320x320
## map) drops the per-query candidate count from ~250 to typically
## 10-30, with the cache rebuilt every 250 ms (slow enough that
## the rebuild cost is negligible, fast enough that fresh-spawned
## squads land in the index before they need to fire).
##
## Usage from CombatComponent:
##   var idx := SpatialIndex.get_instance(get_tree().current_scene)
##   for node in idx.nearby(my_pos, max_range):
##       <hostility / armor / range filtering>
##
## The returned Array may include the caller itself, freed nodes
## that haven't dropped from the bucket yet, and entities outside
## the query radius (rebuild lag); callers must keep their existing
## validity / hostility / distance checks.

const CELL_SIZE: float = 16.0
const MAP_HALF: float = 200.0
const GRID_DIM: int = int((MAP_HALF * 2.0) / CELL_SIZE)
## Cumulative profile (1831-frame session) showed SpatialIndex.nearby
## at 6.65 ms per call inclusive — the cost is the periodic rebuild
## walking every unit + building. At 250ms intervals that's 4
## rebuilds/sec × ~250 entities = 1000 walks/sec. Bumping to 500ms
## halves that. Trade-off: combat queries see up to 500ms of stale
## position data — a unit moving into firing range takes up to 0.5s
## to be "seen" by an attacker who isn't already locked on. RTS
## pacing easily absorbs that latency.
const REBUILD_INTERVAL_MS: int = 500

## Flat array of GRID_DIM² cells, each cell an Array[Node3D] of
## entities currently bucketed there. Replaces the previous
## Dictionary[int -> Array]: array indexing is faster than dict
## lookup, no need for has-check branches in the hot rebuild loop
## or the nearby scan. Pre-sized at _ready so we don't allocate
## per-rebuild.
var _cells: Array = []
var _last_rebuild_ms: int = -REBUILD_INTERVAL_MS  # force first build


func _ready() -> void:
	# One-time: pre-allocate the flat cell grid. Each entry stays
	# as an Array reference for the lifetime of the SpatialIndex —
	# rebuilds clear the entries in place rather than re-allocating.
	_cells.resize(GRID_DIM * GRID_DIM)
	for i: int in _cells.size():
		_cells[i] = []


static func get_instance(scene_root: Node) -> SpatialIndex:
	## Returns the SpatialIndex node living under the scene root,
	## creating it lazily if missing. Lets callers stay agnostic of
	## whether the arena scene wired it up explicitly.
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null("SpatialIndex")
	if existing and existing is SpatialIndex:
		return existing as SpatialIndex
	var idx := SpatialIndex.new()
	idx.name = "SpatialIndex"
	scene_root.add_child(idx)
	return idx


func _cell_of(pos: Vector3) -> int:
	var cx: int = int((pos.x + MAP_HALF) / CELL_SIZE)
	var cz: int = int((pos.z + MAP_HALF) / CELL_SIZE)
	cx = clampi(cx, 0, GRID_DIM - 1)
	cz = clampi(cz, 0, GRID_DIM - 1)
	return cz * GRID_DIM + cx


func _ensure_fresh() -> void:
	var now: int = Time.get_ticks_msec()
	if (now - _last_rebuild_ms) < REBUILD_INTERVAL_MS:
		return
	_last_rebuild_ms = now
	# Clear in place — each cell's Array is reused across rebuilds.
	# Avoids re-allocating GRID_DIM² Arrays per rebuild (was
	# implicitly happening via the Dictionary clear+rebuild).
	for i: int in _cells.size():
		(_cells[i] as Array).clear()
	# Bucket every alive unit + every constructed building. Untyped
	# iteration -- get_nodes_in_group can return freed handles that
	# haven't dropped from the group yet, and a typed for-loop
	# variable assignment errors before the is_instance_valid check
	# below ever runs.
	for raw in get_tree().get_nodes_in_group("units"):
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if not node:
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		(_cells[_cell_of(n3.global_position)] as Array).append(n3)
	for raw2 in get_tree().get_nodes_in_group("buildings"):
		if raw2 == null or not is_instance_valid(raw2):
			continue
		var node2: Node = raw2 as Node
		if not node2:
			continue
		var n3b: Node3D = node2 as Node3D
		if not n3b:
			continue
		(_cells[_cell_of(n3b.global_position)] as Array).append(n3b)


func nearby(world_pos: Vector3, radius: float) -> Array:
	## Returns every entity from the bucket cells covering the radius
	## around world_pos. Includes a safety margin so a unit just
	## about to enter the radius is still in the result.
	_ensure_fresh()
	var out: Array = []
	var cell_radius: int = int(ceil(radius / CELL_SIZE)) + 1
	var origin_cx: int = int((world_pos.x + MAP_HALF) / CELL_SIZE)
	var origin_cz: int = int((world_pos.z + MAP_HALF) / CELL_SIZE)
	var x0: int = maxi(origin_cx - cell_radius, 0)
	var x1: int = mini(origin_cx + cell_radius, GRID_DIM - 1)
	var z0: int = maxi(origin_cz - cell_radius, 0)
	var z1: int = mini(origin_cz + cell_radius, GRID_DIM - 1)
	for cz: int in range(z0, z1 + 1):
		var row_base: int = cz * GRID_DIM
		for cx: int in range(x0, x1 + 1):
			# Direct array index (no dict has-check needed since
			# every cell is pre-allocated as an empty Array at
			# _ready). Empty cells are cheap.
			var bucket: Array = _cells[row_base + cx] as Array
			if not bucket.is_empty():
				out.append_array(bucket)
	return out
