class_name BuilderComponent
extends Node
## Attached to engineer units. Handles building placement and construction.

signal construction_started(building: Building)
signal construction_finished(building: Building)

## How fast this engineer constructs (seconds of progress per real second).
@export var build_rate: float = 1.0

## Clearance the engineer needs from the building edge to start working.
## Distance is measured from the building's edge (footprint half-extent), not its
## center, so big buildings still have a workable construction perimeter.
## 3.5u (was 2.5u) gives a little extra leniency so the engineer doesn't drop
## out of build range from being nudged a unit or two by separation forces or
## another unit walking past — that previously interrupted construction and
## made the engineer re-approach for what looked like no reason.
const BUILD_BUFFER: float = 3.5

var _target_building: Building = null
## Damaged friendly node (Building or Unit) the engineer is currently
## walking to / repairing. Independent from `_target_building` because
## repair targets stay registered until full HP, not until "constructed".
var _repair_target: Node3D = null
var _unit: Unit = null

## Time the engineer has spent trying (and failing) to reach the
## current target_building approach point. If we never make progress
## for this long, we give up on the build so the worker isn't
## permanently stuck pathing into an unreachable spot.
var _approach_stuck_timer: float = 0.0
var _approach_last_dist: float = INF
const APPROACH_GIVEUP_SEC: float = 20.0
const APPROACH_PROGRESS_EPSILON: float = 0.5


func _ready() -> void:
	_unit = get_parent() as Unit
	if not _unit:
		push_error("BuilderComponent must be a child of a Unit node.")


## Radius in which a freshly-idle engineer will automatically pitch in on a
## nearby teammate's construction site. Tight enough that an idle worker
## doesn't run across the map to a totally different front, but loose
## enough that a base under simultaneous build-up always has hands.
const AUTO_ASSIST_RADIUS: float = 30.0
## Auto-repair scan radius. Same idea as AUTO_ASSIST_RADIUS — engineer
## tends only to nearby damage rather than running across the map.
const AUTO_REPAIR_RADIUS: float = 22.0
## Repair feels best at a fraction of the unit's `repair_rate` so a single
## engineer is meaningful but not nearly as fast as the construction itself
## would have been at full strength. Engineers in a squad stack — three
## Ratchets repairing the same building still bring it back fast.
const REPAIR_RATE_FACTOR: float = 0.5


var _builder_phys_frame: int = 0
## Idle-engineer scan throttle. The repair-target / auto-assist
## searches walk every building (and for repair, every unit) in the
## scene -- running at the previous 30Hz cadence was the dominant
## per-engineer cost in profiling. Build / repair gameplay timers
## are on the order of seconds, so dropping the IDLE scan to ~5Hz
## (one in every 6 staggered physics frames) is invisible at the
## gameplay layer and slashes the cost by 6x. The throttle is reset
## the moment the engineer picks up a real target so the active
## build / repair path keeps running every staggered frame.
const IDLE_SCAN_FRAME_INTERVAL: int = 6
var _idle_scan_frame: int = 0


func _physics_process(delta: float) -> void:
	# Stagger builder logic across alternating physics frames. Repair /
	# auto-assist scans iterate the buildings group and run distance
	# checks — running at 60Hz is wasteful since the engineer's
	# behaviour is gated by long timers (build_time ~5s+, repair tick
	# ~0.5s). 30Hz update is invisible and halves the per-frame cost.
	_builder_phys_frame += 1
	if (_builder_phys_frame & 1) == 0:
		return
	delta *= 2.0
	if not _target_building or not is_instance_valid(_target_building):
		_target_building = null
		_set_build_anim(false)
		# No construction in progress — auto-assist construction
		# takes priority over auto-repair, so the engineer always
		# moves to the nearest unfinished friendly site before
		# tending to damaged allies. Either path is skipped if the
		# player is actively moving the engineer somewhere. The
		# scans walk every building / unit in the scene; throttle
		# to ~5Hz since build_time is on a multi-second cadence
		# anyway. An already-assigned repair patient still ticks
		# every staggered frame so the engineer doesn't lose its
		# in-progress heal between scans.
		if _repair_target and is_instance_valid(_repair_target):
			if _process_repair(delta):
				return
		_idle_scan_frame += 1
		if _idle_scan_frame < IDLE_SCAN_FRAME_INTERVAL:
			return
		_idle_scan_frame = 0
		_try_auto_assist()
		if _target_building and is_instance_valid(_target_building):
			# Picked up a construction site -- bail before the
			# repair-scan so the next staggered frame routes through
			# the active-target branch above.
			return
		if _process_repair(delta):
			return
		return
	# Active target re-acquired -- reset the idle throttle so the next
	# IDLE entry kicks off a scan immediately.
	_idle_scan_frame = 0

	if _target_building.is_constructed:
		_target_building = null
		_unit.stop()
		_set_build_anim(false)
		# Same priority order on the just-finished branch -- look
		# for a fresh construction site first, then fall through to
		# repair if nothing else needs building.
		_try_auto_assist()
		if _target_building and is_instance_valid(_target_building):
			return
		if _process_repair(delta):
			return
		return

	var dist: float = _unit.global_position.distance_to(_target_building.global_position)
	var build_max: float = _build_max_distance()

	if dist > build_max:
		# Move toward an approach point just outside the building edge facing us,
		# rather than the building center (which sits inside its nav obstacle and
		# would trap the agent oscillating around the edge).
		_unit.command_move(_approach_point())
		_set_build_anim(false)
		# Track progress — if we don't shrink the distance for too long
		# the build site is probably unreachable (e.g. the player placed
		# it behind their HQ in a corner the navmesh can't connect to).
		# Drop the assignment so the engineer can take other work.
		if dist + APPROACH_PROGRESS_EPSILON < _approach_last_dist:
			_approach_last_dist = dist
			_approach_stuck_timer = 0.0
		else:
			_approach_stuck_timer += delta
			if _approach_stuck_timer >= APPROACH_GIVEUP_SEC:
				_target_building = null
				_approach_stuck_timer = 0.0
				_approach_last_dist = INF
				_unit.stop()
		return

	# Reset the stuck tracker once we're inside the build perimeter.
	_approach_stuck_timer = 0.0
	_approach_last_dist = INF

	# Foundation-block self-rescue. With big-footprint buildings
	# (MOLOT / EChO / Headquarters) the engineer's "in range" gate
	# (extent + BUILD_BUFFER) sits outside the footprint, but nav
	# precision occasionally lands the engineer just inside the
	# foundation XZ box. The engineer then blocks its own
	# foundation-clear check, advance_construction silently no-ops,
	# and the build stalls until the player nudges them out.
	#
	# Single fixed approach point wasn't enough: if that approach
	# direction was blocked (by another building, ramp, or unit)
	# the engineer kept re-issuing the same blocked path tick
	# after tick. Now we try eight cardinal-and-diagonal escape
	# directions and commit to the first one with a clear edge,
	# rotating the start each time we re-enter the rescue branch
	# so the engineer doesn't always pick the same blocked one.
	if _is_inside_foundation_footprint():
		var escape: Vector3 = _pick_clear_escape_point()
		_unit.command_move(escape)
		_set_build_anim(false)
		return

	# In range — stop moving and build
	_unit.stop()
	_target_building.advance_construction(build_rate * delta, _unit)
	# Only animate when the foundation is actually progressing (it can be
	# blocked by units standing inside the footprint).
	_set_build_anim(not _target_building.is_constructed and _target_building._is_foundation_clear())

	if _target_building.is_constructed:
		construction_finished.emit(_target_building)
		_target_building = null
		_set_build_anim(false)


func _process_repair(delta: float) -> bool:
	## Returns true if it took control of the engineer this tick (so the
	## caller doesn't also try to auto-assist construction). Looks for the
	## nearest damaged friendly node, walks to it, and applies the
	## repair_rate.
	if not _unit or not is_instance_valid(_unit):
		return false
	# Honor explicit player commands. Same rule as auto-assist — if the
	# player just clicked a destination, don't drag the unit somewhere else.
	if _unit.has_move_order:
		return false

	# Drop the cached target if it's gone, freed, or fully healed.
	if _repair_target and is_instance_valid(_repair_target):
		var still_damaged: bool = false
		if _repair_target.has_method("is_damaged"):
			still_damaged = _repair_target.is_damaged()
		if not still_damaged:
			_repair_target = null
	else:
		_repair_target = null

	if not _repair_target:
		_repair_target = _find_repair_target()
		if not _repair_target:
			return false

	var center: Vector3 = (_repair_target as Node3D).global_position
	var d: float = _unit.global_position.distance_to(center)
	var range_max: float = _repair_max_distance(_repair_target)
	# `RANGE_TOLERANCE` is wider than the NavigationAgent's
	# `target_desired_distance` so the unit doesn't keep re-walking
	# whenever arrival lands a hair outside `range_max`. Without this
	# slack the engineer ping-pongs between "walk closer" → "nav says I
	# arrived" → "still slightly out of range" and never starts the heal.
	const RANGE_TOLERANCE: float = 1.5
	if d > range_max + RANGE_TOLERANCE:
		# Walk into repair range. Approach point sits well inside the
		# target's range_max so post-arrival we're guaranteed inside.
		var to_self: Vector3 = _unit.global_position - center
		to_self.y = 0.0
		if to_self.length_squared() < 0.01:
			to_self = Vector3(1.0, 0.0, 0.0)
		var approach: Vector3 = center + to_self.normalized() * (range_max - RANGE_TOLERANCE)
		_unit.command_move(approach, false)
		_set_build_anim(false)
		return true

	# In range — tend to the patient.
	_unit.stop()
	_set_build_anim(true)
	var rate: float = REPAIR_RATE_FACTOR
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	if stats and "repair_rate" in stats:
		rate *= float(stats.get("repair_rate"))
	if _repair_target.has_method("heal"):
		_repair_target.heal(rate * delta, _unit)
	return true


func _find_repair_target() -> Node3D:
	if not _unit:
		return null
	var my_owner: int = _unit.owner_id
	var my_pos: Vector3 = _unit.global_position
	var best: Node3D = null
	var best_dist: float = AUTO_REPAIR_RADIUS

	# Damaged friendly buildings.
	for node: Node in _unit.get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or b.owner_id != my_owner:
			continue
		if not b.is_damaged():
			continue
		var d: float = my_pos.distance_to(b.global_position)
		if d < best_dist:
			best_dist = d
			best = b

	# Damaged friendly units / Crawlers (skip self). Duck-typed via
	# `has_method("is_damaged")` instead of `as Unit` because Crawlers
	# live in the "units" group but extend CharacterBody3D directly,
	# not Unit — the cast would skip them.
	for node: Node in _unit.get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		if node == _unit:
			continue
		if not ("owner_id" in node) or node.get("owner_id") != my_owner:
			continue
		if not node.has_method("is_damaged") or not node.is_damaged():
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		var d: float = my_pos.distance_to(n3.global_position)
		if d < best_dist:
			best_dist = d
			best = n3
	return best


func _repair_max_distance(target: Node3D) -> float:
	if target is Building and (target as Building).stats:
		var fs: Vector3 = (target as Building).stats.footprint_size
		return maxf(fs.x, fs.z) * 0.5 + BUILD_BUFFER
	# SalvageCrawler — bigger than a mech squad, give the engineer
	# enough working clearance around the chassis.
	if target is SalvageCrawler:
		return 3.6
	# Unit target — small extent.
	return 2.5


func _set_build_anim(active: bool) -> void:
	if _unit and "is_building" in _unit:
		_unit.is_building = active


func start_building(building: Building) -> void:
	_target_building = building
	_approach_stuck_timer = 0.0
	_approach_last_dist = INF
	construction_started.emit(building)
	_unit.command_move(_approach_point())


func _build_max_distance() -> float:
	## Engineer is "in range" when within BUILD_BUFFER of the building's edge.
	if not _target_building or not _target_building.stats:
		return BUILD_BUFFER
	var footprint: Vector3 = _target_building.stats.footprint_size
	var extent: float = maxf(footprint.x, footprint.z) * 0.5
	return extent + BUILD_BUFFER


func _is_inside_foundation_footprint() -> bool:
	## True when the engineer's XZ position lands inside the target
	## building's foundation-clear box (footprint half-extent + the
	## same 0.4u margin used by Building._is_foundation_clear). Used
	## to push the engineer back to the approach point when nav
	## precision lands them on top of their own work.
	if not _target_building or not _target_building.stats:
		return false
	if not _unit:
		return false
	var fs: Vector3 = _target_building.stats.footprint_size
	var half_x: float = fs.x * 0.5 + 0.4
	var half_z: float = fs.z * 0.5 + 0.4
	var dx: float = absf(_unit.global_position.x - _target_building.global_position.x)
	var dz: float = absf(_unit.global_position.z - _target_building.global_position.z)
	return dx < half_x and dz < half_z


## Per-builder rotating offset so consecutive _pick_clear_escape_point
## calls don't always start at the same compass direction. Bumped
## one slot each tick we re-enter the rescue branch.
var _escape_rotation: int = 0


func _pick_clear_escape_point() -> Vector3:
	## Returns a world-space target outside the building's
	## foundation footprint. Tries 8 compass directions starting at
	## a per-builder rotating offset and picks the first one whose
	## endpoint clears every other building / large terrain piece.
	## If no direction is fully clear, returns the first candidate
	## anyway -- the engineer at least leaves the foundation, and
	## the next rescue tick will re-roll.
	if not _target_building or not _target_building.stats:
		return _unit.global_position
	var center: Vector3 = _target_building.global_position
	var fs: Vector3 = _target_building.stats.footprint_size
	var extent: float = maxf(fs.x, fs.z) * 0.5
	var radius: float = extent + BUILD_BUFFER * 1.4
	var first_candidate: Vector3 = Vector3.INF
	for i: int in 8:
		var dir_idx: int = (i + _escape_rotation) % 8
		var ang: float = float(dir_idx) / 8.0 * TAU
		var cand: Vector3 = center + Vector3(cos(ang), 0.0, sin(ang)) * radius
		if first_candidate == Vector3.INF:
			first_candidate = cand
		# Reject candidates whose endpoint sits inside another
		# building's foundation -- those would just re-trap the
		# engineer in a different self-block.
		var blocked: bool = false
		for node: Node in get_tree().get_nodes_in_group("buildings"):
			if not is_instance_valid(node) or node == _target_building:
				continue
			var b: Building = node as Building
			if not b or not b.stats:
				continue
			var bfs: Vector3 = b.stats.footprint_size
			var bx: float = bfs.x * 0.5 + 0.4
			var bz: float = bfs.z * 0.5 + 0.4
			var dxb: float = absf(b.global_position.x - cand.x)
			var dzb: float = absf(b.global_position.z - cand.z)
			if dxb < bx and dzb < bz:
				blocked = true
				break
		if not blocked:
			_escape_rotation = (dir_idx + 1) % 8
			return cand
	# Every direction had something in it (heavy base packing) --
	# return the first one anyway so at least we shuffle out of
	# the foundation; next rescue cycle will try again from a
	# rotated start.
	_escape_rotation = (_escape_rotation + 1) % 8
	return first_candidate


func _approach_point() -> Vector3:
	## Approach target on the side facing the engineer. Tries a CLOSE
	## point first (right at the edge of the foundation, +0.5u clearance);
	## if another engineer is already there, falls back to the FAR point
	## (one buffer-radius out). Lets multiple engineers cluster at a
	## single foundation without stacking on the same spot — first one
	## tucks in close, others fan out at full range.
	if not _target_building:
		return _unit.global_position
	var center: Vector3 = _target_building.global_position
	var to_unit: Vector3 = _unit.global_position - center
	to_unit.y = 0.0
	if to_unit.length_squared() < 0.01:
		# Engineer is already on top of the building — pick any side.
		to_unit = Vector3(1, 0, 0)
	var dir: Vector3 = to_unit.normalized()
	var extent: float = 0.0
	if _target_building.stats:
		var fs: Vector3 = _target_building.stats.footprint_size
		extent = maxf(fs.x, fs.z) * 0.5
	var close_pt: Vector3 = center + dir * (extent + 0.5)
	var far_pt: Vector3 = center + dir * (extent + BUILD_BUFFER * 0.5)
	# If another engineer is already parked near the close spot, take
	# the far spot instead. Self is excluded from the check.
	if _spot_has_other_engineer(close_pt, 1.5):
		return far_pt
	return close_pt


func _spot_has_other_engineer(spot: Vector3, radius: float) -> bool:
	## True if another player-allied unit with a BuilderComponent is
	## within `radius` of `spot` (excluding self).
	var r2: float = radius * radius
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node) or node == _unit:
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		# Cheap check: only candidates that have a builder.
		if not n3.has_method("get_builder"):
			continue
		var builder: Node = n3.get_builder() if n3.has_method("get_builder") else null
		if not builder:
			continue
		var dx: float = n3.global_position.x - spot.x
		var dz: float = n3.global_position.z - spot.z
		if dx * dx + dz * dz < r2:
			return true
	return false


func cancel_build() -> void:
	## Called by the player issuing a non-build command (move/attack) so the
	## builder doesn't immediately drag the unit back to the construction
	## site or repair patient.
	_target_building = null
	_repair_target = null


func _try_auto_assist() -> void:
	## Look for the nearest under-construction friendly building within
	## AUTO_ASSIST_RADIUS and start helping it. Bails out if the player
	## has the engineer mid-move (we honor the explicit order), or if no
	## eligible site exists.
	if not _unit or not is_instance_valid(_unit):
		return
	if _unit.has_move_order:
		return  # Player gave a move command — don't second-guess them.
	var my_owner: int = _unit.owner_id
	var my_pos: Vector3 = _unit.global_position
	var best: Building = null
	var best_dist: float = AUTO_ASSIST_RADIUS
	for node: Node in _unit.get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or b.is_constructed:
			continue
		if b.owner_id != my_owner:
			continue
		var d: float = my_pos.distance_to(b.global_position)
		if d < best_dist:
			best_dist = d
			best = b
	if best:
		start_building(best)


func place_building(building_stats: BuildingStatResource, position: Vector3, resource_mgr: ResourceManager) -> Building:
	if not resource_mgr.can_afford(building_stats.cost_salvage, building_stats.cost_fuel):
		return null

	resource_mgr.spend(building_stats.cost_salvage, building_stats.cost_fuel)

	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var building: Building = building_scene.instantiate() as Building
	building.stats = building_stats
	# Inherit ownership from the engineer placing the building. Without this
	# step every building came up as owner_id=0 (player) regardless of who
	# built it — AI bases ended up player-coloured and the win-condition
	# tracking treated them as the player's.
	if _unit:
		building.owner_id = _unit.owner_id
	building.resource_manager = resource_mgr

	# Add to tree FIRST, then set global_position. Pre-tree assignment
	# triggers a !is_inside_tree() warning per call (and many bake spots
	# would otherwise re-fire one warning per AI placement attempt).
	get_tree().current_scene.add_child(building)
	building.global_position = position

	building.begin_construction()

	# Recalculate power when building finishes
	building.construction_complete.connect(func() -> void:
		resource_mgr.update_power()
		resource_mgr.update_population_cap()
	)
	# Also re-tally on building death so the cap shrinks when a foundry
	# is destroyed.
	building.destroyed.connect(func() -> void:
		resource_mgr.update_power()
		resource_mgr.update_population_cap()
	)

	start_building(building)
	return building
