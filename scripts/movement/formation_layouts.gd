class_name FormationLayouts
extends RefCounted
## Static layouts (slot offsets) for squad-of-squads sizes, plus
## the range-rank sorter that maps a member list (each is a unit
## with weapons + armor) to slot indices.
##
## Reference: spec §3 "Squad-of-squads meta-formation".

## Each entry: Array[Vector3] of XZ offsets. Unit-vector-ish; SquadGroup
## scales by formation_spacing. Y ignored. Order: front (rank 0) → back.
const LAYOUTS_GROUND: Dictionary = {
	1: [Vector3(0, 0, 0)],
	2: [Vector3(-1, 0,  1), Vector3(1, 0,  1)],                         # 2 wide, 1 row, FRONT
	3: [Vector3(0, 0,  1), Vector3(-1, 0, -1), Vector3(1, 0, -1)],      # wedge
	4: [Vector3(-1, 0,  1), Vector3(1, 0,  1),
		Vector3(-1, 0, -1), Vector3(1, 0, -1)],                         # 2x2 box
	5: [Vector3(0, 0,  2),
		Vector3(-1, 0,  0), Vector3(1, 0,  0),
		Vector3(-1, 0, -2), Vector3(1, 0, -2)],                         # diamond
	6: [Vector3(-1, 0,  2), Vector3(1, 0,  2),
		Vector3(-1, 0,  0), Vector3(1, 0,  0),
		Vector3(-1, 0, -2), Vector3(1, 0, -2)],                         # 2x3 box
	7: [Vector3(0, 0,  2),
		Vector3(-2, 0,  0), Vector3(0, 0,  0), Vector3(2, 0,  0),
		Vector3(-1, 0, -2), Vector3(1, 0, -2),
		Vector3(0, 0, -3)],                                             # T+stub
}

static func slots_for(size: int) -> Array[Vector3]:
	if LAYOUTS_GROUND.has(size):
		return LAYOUTS_GROUND[size] as Array[Vector3]
	# Larger groups: tile a 3-wide grid centered on Z=0 with rank 0
	# at the largest positive Z (consistent with the named layouts).
	var slots: Array[Vector3] = []
	var ranks: int = (size + 2) / 3
	var idx: int = 0
	while idx < size:
		var col: int = idx % 3 - 1
		var rank_idx: int = idx / 3
		var row: int = (ranks - 1) - 2 * rank_idx
		slots.append(Vector3(col, 0, row))
		idx += 1
	return slots

## Sort `members` (Array of Node — each must have `get_ag_range()`
## returning float, `get_armor_weight()` returning float, and
## `is_aa_only()` returning bool) into front-to-back rank order
## per spec §3:
##   AG pool (sorted by ag_range ASC) head → MIDDLE pool (AA-only)
##   → AG pool tail (sorted by ag_range DESC). Tiebreaker: heavier
##   armor forward.
static func range_rank_sort(members: Array) -> Array:
	var ag_pool: Array = []
	var aa_pool: Array = []
	for m: Variant in members:
		if not is_instance_valid(m):
			continue
		if not (m is Node):
			continue
		if (m as Node).is_aa_only():
			aa_pool.append(m)
		else:
			ag_pool.append(m)
	ag_pool.sort_custom(func(a: Node, b: Node) -> bool:
		var ra: float = a.get_ag_range()
		var rb: float = b.get_ag_range()
		if absf(ra - rb) < 0.01:
			return a.get_armor_weight() > b.get_armor_weight()
		return ra < rb)
	# Split ag_pool into head / tail at midpoint, with aa_pool in middle.
	var n: int = ag_pool.size()
	var head_n: int = n / 2 + (n % 2)            # extra one to head; tail size = n - head_n
	var sorted: Array = []
	for i: int in head_n:
		sorted.append(ag_pool[i])
	for m: Variant in aa_pool:
		sorted.append(m)
	# Tail in DESCENDING ag_range so highest-range ends up rearmost
	var tail: Array = ag_pool.slice(head_n, n)
	tail.reverse()
	for m: Variant in tail:
		sorted.append(m)
	return sorted
