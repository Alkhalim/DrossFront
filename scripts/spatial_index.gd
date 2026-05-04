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
const REBUILD_INTERVAL_MS: int = 250

var _cells: Dictionary = {}      # int cell-index -> Array[Node3D]
var _last_rebuild_ms: int = -REBUILD_INTERVAL_MS  # force first build


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
	_cells.clear()
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
		var idx: int = _cell_of(n3.global_position)
		if not _cells.has(idx):
			_cells[idx] = []
		(_cells[idx] as Array).append(n3)
	for raw2 in get_tree().get_nodes_in_group("buildings"):
		if raw2 == null or not is_instance_valid(raw2):
			continue
		var node2: Node = raw2 as Node
		if not node2:
			continue
		var n3b: Node3D = node2 as Node3D
		if not n3b:
			continue
		var idx2: int = _cell_of(n3b.global_position)
		if not _cells.has(idx2):
			_cells[idx2] = []
		(_cells[idx2] as Array).append(n3b)


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
		for cx: int in range(x0, x1 + 1):
			var key: int = cz * GRID_DIM + cx
			var bucket: Array = _cells.get(key, []) as Array
			if not bucket.is_empty():
				out.append_array(bucket)
	return out
