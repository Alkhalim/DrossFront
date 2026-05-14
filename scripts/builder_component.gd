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

## Hysteresis on the "in build range" check. Once the engineer has
## docked, allow it to drift this much past build_max before re-issuing
## an approach — separation forces from peer engineers or units walking
## past can nudge a docked builder ~1 u outward, and without hysteresis
## we'd kick it back to approach for that tiny drift, then back to build
## the next tick. The user-visible symptom was engineers bouncing back
## and forth a metre or two from the foundation.
const BUILD_RANGE_HYSTERESIS: float = 1.5
var _was_in_build_range: bool = false

## Cached approach point so we don't re-issue the same command_move every
## physics frame. command_move's idempotency check only fires when the
## caller passes clear_combat=true; BuilderComponent passes false (so the
## priority window isn't tripped), so the kernel ends up replanning every
## tick. Track the last destination here and skip re-issues that move
## the target less than the threshold.
var _last_command_move_dest: Vector3 = Vector3.INF
const COMMAND_MOVE_REISSUE_DIST: float = 0.5


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
## Mekh engineers repairing the same building still bring it back fast.
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
## Wall-clock minimum gap between idle scans. Bounded below by the frame-
## counter interval above (so we don't scan more often than every Nth
## staggered frame), bounded above by this — at lowered physics rates the
## frame counter alone would let scans drift to once-per-1.2s; the user
## reported the rate still feels too aggressive for engineer behaviour
## where build_time is multi-second and repair patients don't appear
## faster than ~2s. Wall-clock gating makes the cadence physics-rate
## independent so future physics retunes don't reintroduce the issue.
const IDLE_SCAN_MIN_INTERVAL_MSEC: int = 500
var _next_idle_scan_msec: int = 0


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
	# Respect player priority. unit.command_move(clear_combat=true) sets
	# _move_priority_until_ms = now + 4s; CombatComponent already honors this
	# to suppress combat re-engagement. Mirror it here so a player's "go
	# there" right-click isn't immediately overridden by the build-approach
	# re-issue loop. Without this guard, the player can't reposition an
	# engineer that's locked onto a build target — every BuilderComponent
	# tick (~30 Hz) re-issues command_move(_approach_point()) on top of
	# the player's command.
	if "_move_priority_until_ms" in _unit:
		var prio_until: int = _unit.get("_move_priority_until_ms") as int
		if prio_until > 0 and Time.get_ticks_msec() < prio_until:
			return
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
		# Wall-clock gate on top of the frame-counter gate — see
		# IDLE_SCAN_MIN_INTERVAL_MSEC. Scan only fires when both have
		# elapsed; whichever is slower wins.
		var now_msec_b: int = Time.get_ticks_msec()
		if now_msec_b < _next_idle_scan_msec:
			return
		_next_idle_scan_msec = now_msec_b + IDLE_SCAN_MIN_INTERVAL_MSEC
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
	# Hysteresis: once we've docked, require a larger drift before going
	# back to approach. Stops the "bounce in and out of build range" loop
	# when separation force nudges a docked engineer ~1 u outward.
	var range_threshold: float = build_max + (BUILD_RANGE_HYSTERESIS if _was_in_build_range else 0.0)

	if dist > range_threshold:
		_was_in_build_range = false
		# Move toward an approach point just outside the building edge facing us,
		# rather than the building center (which sits inside its nav obstacle and
		# would trap the agent oscillating around the edge).
		# clear_combat=false: this is an internal builder-driven move, NOT a
		# player command. Passing true would set _move_priority_until_ms = now+4s
		# on the unit, which my own priority-window guard above would then
		# read as 'player just clicked' and skip BuilderComponent for 4s —
		# the engineer would arrive at approach_pt and sit idle for 4 seconds
		# before construction started.
		# Idempotency: only re-issue command_move when the approach point
		# has actually moved (cached angle + a small movement threshold).
		# Without this the kernel replans every tick and the engineer can
		# stutter on approach.
		var approach_pt: Vector3 = _approach_point()
		if approach_pt.distance_squared_to(_last_command_move_dest) > COMMAND_MOVE_REISSUE_DIST * COMMAND_MOVE_REISSUE_DIST:
			_unit.command_move(approach_pt, false)
			_last_command_move_dest = approach_pt
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
				_last_command_move_dest = Vector3.INF
				_unit.stop()
		return

	# Reset the stuck tracker once we're inside the build perimeter.
	_was_in_build_range = true
	_approach_stuck_timer = 0.0
	_approach_last_dist = INF
	_last_command_move_dest = Vector3.INF

	# Foundation-block self-rescue was the workaround for "engineer
	# inside the foundation footprint blocks its own construction".
	# That's no longer a problem — Building._is_foundation_clear
	# exempts the assigned engineer (commit 04b80b4), so the engineer
	# can stand inside the footprint+0.4 box and construction still
	# progresses. Branch removed (commit 7fbf7fc).

	# In range — stop moving and build
	_unit.stop()
	# Inheritor construction-site collaboration multiplier (spec §633).
	# Applies only to the field-unit foundation; other buildings are unaffected.
	# 1 Restorer → 1.0x, 2 total → 1.4x, 3+ total → 1.8x. Cap at 3.
	var collab_mult: float = 1.0
	if _target_building != null and _target_building.stats != null \
			and _target_building.stats.building_id == &"inheritor_construction_site":
		var n_peers: int = _count_peer_engineers_at_target()
		# n_peers = number of OTHER Restorers also on this target.
		# Total = n_peers + self → index into [1.0, 1.0, 1.4, 1.8], capped at 3.
		collab_mult = ([1.0, 1.0, 1.4, 1.8] as Array)[mini(n_peers + 1, 3)]
	_target_building.advance_construction(build_rate * delta * collab_mult, _unit)
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
	## Finds the nearest damaged friendly entity inside AUTO_REPAIR_RADIUS.
	## Used to be two full-scene walks (every building + every unit in
	## their groups, regardless of distance) — the profiler clocked it
	## at ~229 ms per call, by far the dominant per-frame cost in the
	## game (BuilderComponent ate 80% of script time on a busy save).
	## Switched to SpatialIndex.nearby so we only iterate entities in
	## the bucket cells covering the search radius — typically 10-30
	## entities instead of all 100-200 in the scene.
	if not _unit:
		return null
	var my_owner: int = _unit.owner_id
	var my_pos: Vector3 = _unit.global_position
	var best: Node3D = null
	var best_dist: float = AUTO_REPAIR_RADIUS
	var idx: SpatialIndex = SpatialIndex.get_instance(_unit.get_tree().current_scene)
	if idx == null:
		return null
	for raw: Variant in idx.nearby(my_pos, AUTO_REPAIR_RADIUS):
		if not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if node == null or node == _unit:
			continue
		if not ("owner_id" in node) or node.get("owner_id") != my_owner:
			continue
		# is_damaged is duck-typed across Building / Unit / SalvageCrawler
		# (Crawlers extend CharacterBody3D directly, not Unit).
		if not node.has_method("is_damaged") or not node.is_damaged():
			continue
		var n3: Node3D = node as Node3D
		if n3 == null:
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
	_was_in_build_range = false
	_last_command_move_dest = Vector3.INF
	# Player just explicitly assigned this engineer to a build site.
	# Clear any prior priority window — if the player had right-clicked
	# the engineer somewhere else seconds ago and it set _move_priority_
	# until_ms = now+4s, the BuilderComponent tick guard would skip the
	# entire _physics_process for that 4 s window and the new
	# assignment would just sit there doing nothing. Player-driven
	# start_building should take effect immediately.
	if "_move_priority_until_ms" in _unit:
		_unit.set("_move_priority_until_ms", 0)
	construction_started.emit(building)
	# clear_combat=false — internal builder-driven move (see active-build
	# branch in _physics_process). Passing true sets _move_priority_until_ms
	# on the unit, which would trip BuilderComponent's own priority guard
	# and freeze the engineer at approach_pt for 4 s after every start_building.
	_unit.command_move(_approach_point(), false)
	_last_command_move_dest = _approach_point()


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


## Cached approach angle so the engineer commits to a single docking slot
## per target instead of recomputing it every tick (which produced
## oscillation when other engineers shifted nearby). Invalidated by
## target change or free.
var _cached_approach_angle: float = 0.0
var _cached_approach_for: Building = null


func _approach_point() -> Vector3:
	## Approach target on the side facing the engineer, but if another
	## engineer is already parked there, rotate around the foundation in
	## 45° increments to find a clear slot. With 8 slots evenly spaced
	## around the building, multiple cooperating engineers fan out and
	## each gets a clean approach line — none of them blocks another's
	## final docking step. The chosen angle is cached per-target so the
	## engineer doesn't re-pick every tick and oscillate.
	if not _target_building:
		return _unit.global_position
	if not is_instance_valid(_cached_approach_for) or _cached_approach_for != _target_building:
		_cached_approach_angle = _pick_approach_angle()
		_cached_approach_for = _target_building
	var center: Vector3 = _target_building.global_position
	var extent: float = 0.0
	if _target_building.stats:
		var fs: Vector3 = _target_building.stats.footprint_size
		extent = maxf(fs.x, fs.z) * 0.5
	var radius: float = extent + 0.5
	return center + Vector3(cos(_cached_approach_angle), 0.0, sin(_cached_approach_angle)) * radius


func _pick_approach_angle() -> float:
	## Try 8 compass slots starting at the engineer's natural approach
	## direction, alternating +1, -1, +2, -2... so the chosen slot is
	## the nearest free one to the engineer's actual position. If every
	## slot is occupied (heavy cooperation, ≥8 engineers), fall back to
	## the natural direction and let _process_construction's stuck timer
	## eventually drop the assignment.
	var center: Vector3 = _target_building.global_position
	var extent: float = 0.0
	if _target_building.stats:
		var fs: Vector3 = _target_building.stats.footprint_size
		extent = maxf(fs.x, fs.z) * 0.5
	var radius: float = extent + 0.5
	var to_unit: Vector3 = _unit.global_position - center
	to_unit.y = 0.0
	if to_unit.length_squared() < 0.01:
		to_unit = Vector3(1, 0, 0)
	var base_angle: float = atan2(to_unit.z, to_unit.x)
	for i in 8:
		var sign_val: int = (1 if i % 2 == 0 else -1)
		var step: int = (i + 1) / 2
		var slot_offset: float = float(sign_val * step) * TAU / 8.0
		var angle: float = base_angle + slot_offset
		var pt: Vector3 = center + Vector3(cos(angle), 0.0, sin(angle)) * radius
		if not _spot_has_other_engineer(pt, 1.5):
			return angle
	return base_angle


func _spot_has_other_engineer(spot: Vector3, radius: float) -> bool:
	## True if another player-allied unit with a BuilderComponent is
	## within `radius` of `spot` (excluding self).
	## Profile 532 flagged this at 36.4 ms / call (and _approach_point
	## that calls it at the same magnitude) — the previous build walked
	## the FULL units group (~200 entities) per call and ran a
	## has_method + get_builder dynamic call on every one. With many
	## engineers competing for build spots during heavy combat that
	## was the dominant cost on the entire script board (60 s of session
	## time on this function chain). Switched to the same SpatialIndex
	## narrow-phase pattern we use elsewhere — typical bucket return
	## is 5-15 candidates instead of 200.
	var r2: float = radius * radius
	var idx: SpatialIndex = SpatialIndex.get_instance(get_tree().current_scene)
	if idx == null:
		return false
	# Untyped iteration: spatial-index buckets can carry stale Object
	# references for entities freed since the last rebuild tick.
	for raw in idx.nearby(spot, radius):
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if not node or node == _unit:
			continue
		# Cheap check: only candidates that have a builder.
		if not node.has_method("get_builder"):
			continue
		var builder: Node = node.get_builder()
		if not builder:
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		var dx: float = n3.global_position.x - spot.x
		var dz: float = n3.global_position.z - spot.z
		if dx * dx + dz * dz < r2:
			return true
	return false


func _count_peer_engineers_at_target() -> int:
	## Counts OTHER Restorers (engineers with a BuilderComponent) that are
	## also targeting the same _target_building as this engineer, within
	## build range. Used to compute the Inheritor construction-site
	## collaboration multiplier (spec §633). Capped at 2 peers (3 total).
	if not _target_building or not is_instance_valid(_target_building):
		return 0
	var count: int = 0
	var idx: SpatialIndex = SpatialIndex.get_instance(get_tree().current_scene)
	if idx == null:
		# Fallback: walk the units group.
		for node: Node in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(node) or node == _unit:
				continue
			if not node.has_method("get_builder"):
				continue
			var other_builder: Node = node.get_builder()
			if other_builder != null and other_builder.get("_target_building") == _target_building:
				count += 1
				if count >= 2:
					break
		return count
	var search_radius: float = _build_max_distance() + 2.0
	for raw: Variant in idx.nearby(_target_building.global_position, search_radius):
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if node == null or node == _unit:
			continue
		if not node.has_method("get_builder"):
			continue
		var other_builder: Node = node.get_builder()
		if other_builder != null and other_builder.get("_target_building") == _target_building:
			count += 1
			if count >= 2:
				break
	return count


func start_field_unit_build(unit_stats: UnitStatResource, world_pos: Vector3) -> void:
	## Inheritor Restorer field-build entry point. Spawns a construction-site
	## Building at world_pos as a real foundation (is_constructed = false) so
	## the Restorer constructs it exactly like any other building via the existing
	## advance_construction loop. When the foundation completes, _finish_construction
	## detects the inheritor_construction_site building_id, spawns the queued unit
	## pair, and queue_free()s the site. Cost has already been paid by the caller
	## (HUD / SelectionManager) before this is invoked. If the Restorer is killed
	## mid-construction the unit is lost with no refund per spec line 631.
	var site_stats: BuildingStatResource = load(
		"res://resources/buildings/inheritor_construction_site.tres"
	) as BuildingStatResource
	if site_stats == null:
		push_error("BuilderComponent: could not load inheritor_construction_site.tres")
		return
	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	if building_scene == null:
		push_error("BuilderComponent: could not load scenes/building.tscn")
		return
	var site: Building = building_scene.instantiate() as Building
	site.stats = site_stats
	if _unit:
		site.owner_id = _unit.owner_id
	# Foundation state — engineer constructs it like any other building.
	# is_constructed stays false (the default); begin_construction() is
	# called implicitly by start_building → advance_construction on the
	# first in-range tick. We call begin_construction() here so the
	# progress bar and buried-visual state are ready before the Restorer
	# walks over (mirrors how place_building works for other factions).
	# Per-instance build_time override: foundation takes the queued unit's
	# build_time (e.g. Ashigaru 50s, Wächter 75s) — not the 0.0 placeholder
	# baked into inheritor_construction_site.tres.
	site._build_time_override = unit_stats.build_time

	var scene_root: Node = get_tree().current_scene
	var buildings_node: Node = scene_root.get_node_or_null("Buildings")
	var units_node: Node = scene_root.get_node_or_null("Units")
	# Prefer a dedicated Buildings node; fall back to Units (where the
	# old code put sites) then to the scene root. The SpatialIndex and
	# BuilderComponent.start_building's scan find the site regardless of
	# parent because Building._ready registers it in the "buildings" group.
	var parent_node: Node
	if buildings_node != null:
		parent_node = buildings_node
	elif units_node != null:
		parent_node = units_node
	else:
		parent_node = scene_root
	parent_node.add_child(site)
	site.global_position = world_pos

	# Call begin_construction() AFTER add_child so _ready has run and the
	# progress bar + visual state are correctly initialised before the
	# Restorer walks to the site.
	site.begin_construction()

	# Stash the queued unit AFTER begin_construction so the queue is
	# populated when _finish_construction runs. We bypass queue_unit()'s
	# is_constructed + producible_units gate (the site's producible list is
	# intentionally empty — the unit to build is injected per-instance here).
	site._build_queue.append(unit_stats)

	# Route the Restorer to the site using the existing approach loop.
	start_building(site)


func cancel_build() -> void:
	## Called by the player issuing a non-build command (move/attack) so the
	## builder doesn't immediately drag the unit back to the construction
	## site or repair patient.
	_target_building = null
	_repair_target = null


func _try_auto_assist() -> void:
	## Look for the nearest under-construction friendly building within
	## AUTO_ASSIST_RADIUS and start helping it. Same SpatialIndex.nearby
	## migration as _find_repair_target — used to walk every building in
	## the scene per call, now restricted to the bucket cells covering
	## the search radius.
	if not _unit or not is_instance_valid(_unit):
		return
	# has_move_order check removed: the _move_priority_until_ms gate in
	# _physics_process already blocks auto-assist during player commands.
	# Keeping it here prevented the engineer from switching to a closer
	# foundation that appeared while it was walking toward a self-issued
	# target.
	var my_owner: int = _unit.owner_id
	var my_pos: Vector3 = _unit.global_position
	var best: Building = null
	var best_dist: float = AUTO_ASSIST_RADIUS
	var idx: SpatialIndex = SpatialIndex.get_instance(_unit.get_tree().current_scene)
	if idx == null:
		return
	for raw: Variant in idx.nearby(my_pos, AUTO_ASSIST_RADIUS):
		if not is_instance_valid(raw):
			continue
		var b: Building = raw as Building
		if b == null or b.is_constructed:
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
