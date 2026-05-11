class_name GroundMovement
extends MovementComponent
## Concrete MovementComponent for ground squads. PA-15 ships only
## the rejoin-related fields below as a forward-reference stub —
## PA-10 fills in path-query integration, neighbor queries, and
## stuck-recovery overrides.

var agent_profile: AgentProfile = null
var squad_group_ref: SquadGroup = null            # set when joined to a group
var path_waypoints: PackedVector3Array = PackedVector3Array()
var path_waypoint_idx: int = 0

# _cached_spatial_idx + _get_spatial_idx() moved to MovementComponent
# base class so the centralized tick_movement can do one combined
# nearby query per heavy tick.
var _cached_nav_router: NavRouter = null

# Auto-rejoin state (PA-15)
var last_group_ref: SquadGroup = null
var last_drop_reason: int = -1                    # SquadGroup.DropReason or -1
var last_order_destination: Vector3 = Vector3.INF

## PF-A — ad-hoc kernel field id for solo (non-GroupAura) moves under
## flag-on. When goto_world is called from outside the player's selection
## dispatch (combat reactions via unit.command_move, AI orders, etc.)
## the kernel needs a current target — without one it keeps the previous
## field, and the unit walks toward a stale goal. We build a per-unit
## field here, release it on the next goto_world or _exit_tree.
## 0 = no owned field.
var _kernel_field_id: int = 0
## Last world position we built a kernel field for. Used to skip
## rebuild when goto_world is called repeatedly with essentially the
## same target — combat AI re-issues `unit.command_move(enemy_pos)`
## every tick on engaged units, which without idempotency rebuilds
## a fresh ~25k-cell Dijkstra each call. The kernel target shifts
## per-tick, the unit's flow direction never stabilizes, and what
## should have been a smooth approach degrades into oscillation
## against walls/obstacles. Tracked as a Vector3; comparisons use
## squared distance against a one-cell threshold.
var _kernel_field_target: Vector3 = Vector3.INF
## The group_id most recently assigned to this agent via set_agent_target.
## GroupAura writes this (= aura.get_instance_id()) after wiring the field
## so that subsequent ad-hoc goto_world calls (combat chase, attack-move
## resume) pass the same group_id instead of 0. Passing 0 would drop the
## unit out of its cohesion group mid-approach, breaking the flock and
## causing lateral oscillation (the attack-move wiggle bug). Cleared to 0
## by unit.command_move(clear_combat=true) so a player-issued plain move
## correctly detaches the unit from any prior GroupAura flock.
var _kernel_group_id: int = 0

## Counts consecutive physics ticks the kernel returned ~zero velocity
## while the unit is on the floor. Once past SKIP_SLIDE_AFTER_TICKS we
## start skipping move_and_slide every tick (with a periodic refresh
## via SKIP_REFRESH_TICKS) — see _apply_kernel_velocity for rationale.
var _stationary_ticks: int = 0
const MOTION_THRESHOLD_SQ: float = 0.04  # (0.2 m/s)^2 — below this is "parked"
const SKIP_SLIDE_AFTER_TICKS: int = 3   # 0.3 sec at 10 Hz physics
const SKIP_REFRESH_TICKS: int = 6        # force a sweep every ~0.6 sec

func _ready() -> void:
	super._ready()
	if agent_profile == null:
		agent_profile = AgentProfile.new(0.6, 0.5, 35.0, &"squad_default")


func _exit_tree() -> void:
	# PF-A: release our ad-hoc kernel field if we own one. Otherwise
	# FieldEntry leaks in FlowFieldServer.fields_ map.
	if _kernel_field_id != 0:
		var scene: Node = get_tree().current_scene if get_tree() else null
		if scene != null:
			var server: Object = MovementNativeBootstrap.get_server(scene)
			if server != null:
				server.call("release_field", _kernel_field_id)
		_kernel_field_id = 0
	super._exit_tree()

const WAYPOINT_REACH_DIST: float = 1.5
const GRAVITY: float = 18.0  # matches scripts/unit.gd legacy value (PB-3)

func goto_world(world_pos: Vector3) -> void:
	## Solo path-query. Used when not in a SquadGroup or in
	## dispersed mode (each squad routes its own way).
	##
	## On null-router or no-path, `target` stays set to the goal so
	## the unit falls back to direct SEEK; eventually the stuck
	## detector escalates to repath/push-out. This is intentional
	## "best effort" behavior — leaving the unit idle would mask
	## navmesh setup problems during early development.
	target = world_pos

	# PF-A: under flag-on, also push the new target into the kernel via
	# an ad-hoc per-unit field. selection_manager's _dispatch_via_group_aura
	# path skips goto_world for player-issued multi-squad orders, but
	# unit.command_move (combat reactions, AI orders, etc.) routes through
	# this function — without this hook, the kernel keeps the previous
	# target and the unit follows a stale field into walls.
	#
	# Idempotency: combat AI calls unit.command_move every tick on engaged
	# units (re-issuing the enemy position). Each call WAS rebuilding a
	# ~25k-cell Dijkstra and swapping the kernel target, causing the unit's
	# flow direction to thrash and never stabilize. Skip when the new
	# target is within one cell of the existing one — close enough that a
	# rebuilt field would point essentially the same way.
	if MovementFlags.use_flowfield() and kernel_handle != 0:
		# 6m == 3 cells. Bumped from 2m (one cell) after the perf scene
		# showed combat AI re-targeting was the dominant rebuild driver
		# even WITH cell-aligned idempotency: each enemy step inside the
		# same cell would still cross-cell occasionally, and rebuilds
		# averaged ~3.6/frame at 100 units. 6m gives 9× fewer rebuilds
		# in steady-state combat at the cost of slightly delayed flow
		# updates when an enemy moves laterally (the unit overshoots,
		# then the next combat retarget snaps the field once the enemy
		# clears the threshold). Combat AI handles aim independently of
		# the flow field, so missed shots are not a side effect.
		const SAME_TARGET_THRESHOLD_SQ: float = 36.0  # (6m)^2
		if _kernel_field_id != 0 and \
		   _kernel_field_target.distance_squared_to(world_pos) < SAME_TARGET_THRESHOLD_SQ:
			# Same target as last build — kernel still has it, no rebuild.
			pass
		else:
			var scene: Node = get_tree().current_scene if get_tree() else null
			if scene != null:
				var server: Object = MovementNativeBootstrap.get_server(scene)
				var kernel: Object = MovementNativeBootstrap.get_kernel(scene)
				if server != null and kernel != null:
					# Release the previously-owned ad-hoc field so we don't leak.
					if _kernel_field_id != 0:
						server.call("release_field", _kernel_field_id)
						_kernel_field_id = 0
					var fid: int = server.call("build_field", world_pos, _agent_class_for_self())
					if fid != 0:
						_kernel_field_id = fid
						_kernel_field_target = world_pos
						# Use _kernel_group_id so combat-chase re-issues
						# preserve the GroupAura flock (group_id != 0).
						# Solo moves (player plain-move) clear _kernel_group_id
						# to 0 via unit.command_move before calling goto_world,
						# so this correctly falls back to solo behaviour there.
						kernel.call("set_agent_target", kernel_handle, _kernel_group_id, fid, 0)

	# Under flag-on, the kernel steers directly from the flow field; the
	# orchestrator's flag-on path NEVER reads `path_waypoints` (it calls
	# _apply_kernel_velocity instead of tick_movement). Skip the legacy
	# A* query — at high agent counts in combat this fires 4-5 times per
	# unit per second, ~0.06 ms each, all wasted. Path waypoints are
	# cleared so no stale data lingers if the flag is toggled off later.
	if MovementFlags.use_flowfield() and kernel_handle != 0:
		path_waypoints = PackedVector3Array()
		path_waypoint_idx = 0
		return
	var router: NavRouter = _get_nav_router()
	if router == null:
		path_waypoints = PackedVector3Array()
		path_waypoint_idx = 0
		return
	var result: PathResult = router.query_path(
		_body.global_position, world_pos, agent_profile)
	if result.valid:
		path_waypoints = result.waypoints
		path_waypoint_idx = 1                   # waypoints[0] is current pos
	else:
		path_waypoints = PackedVector3Array()
		path_waypoint_idx = 0
		path_unreachable.emit(REASON_NO_NAVMESH_PATH)

func set_slot_target(slot_world: Vector3) -> void:
	## Called per-frame by SquadGroup in cohesive mode. No path
	## query — local SEEK toward the moving slot. Path queries
	## happen at the group level for cohesive groups.
	target = slot_world
	path_waypoints = PackedVector3Array()
	path_waypoint_idx = 0


func clear_target() -> void:
	## Override base clear_target to also wipe the path-waypoint cache.
	## Without this, _physics_process reads the next path waypoint and
	## overwrites `target` back to it on the very next physics tick —
	## stop() becomes a no-op for path-routed units, so combat's "stop
	## and fire" leaves the unit still walking. Now stop() actually
	## halts the route as well as clearing the goal.
	super.clear_target()
	path_waypoints = PackedVector3Array()
	path_waypoint_idx = 0
	# PF-A: under flag-on, the kernel keeps reading the unit's flow field
	# and produces non-zero velocity even after the GDScript-side target
	# is cleared. Combat AI's "stop and fire" then never actually stops
	# the body — the kernel walks past attack range, combat re-issues
	# command_move(chase_pos), and the unit visibly wiggles in place
	# every tick. Set HALTED to make the kernel zero velocity.
	# AGENT_FLAG_HALTED bit is 1 << 2 = 4 (mirrors native types.h).
	#
	# Keep the cached field alive — releasing it would force a full
	# Dijkstra rebuild on the very next stop-then-chase cycle (combat
	# AI exits range → command_move(chase_pos) → goto_world). With the
	# field preserved, goto_world's idempotency check can short-circuit
	# when the new chase target is within 6m of the previous goal, and
	# the server-side cache lets sibling units sharing the goal reuse
	# the field. set_agent_target clears HALTED on the next motion order.
	const AGENT_FLAG_HALTED: int = 4
	if MovementFlags.use_flowfield() and kernel_handle != 0:
		var scene: Node = get_tree().current_scene if get_tree() else null
		if scene != null:
			var kernel: Object = MovementNativeBootstrap.get_kernel(scene)
			if kernel != null:
				kernel.call("set_agent_flag", kernel_handle, AGENT_FLAG_HALTED, true)

## Override of MovementComponent.arrival_target. When a path is active,
## return the path's final waypoint — the unit-level arrival poll uses
## this to avoid registering arrival at intermediate waypoints (where
## seek's arrival_radius slowdown would otherwise count as "settled" if
## separation forces happen to balance seek into low velocity).
func arrival_target() -> Vector3:
	if path_waypoints.size() > 0:
		return path_waypoints[path_waypoints.size() - 1]
	return target

func tick_movement(delta: float, frame_phase: int) -> void:
	# Advance waypoint if we have a path and have reached the current one
	if path_waypoints.size() > 1 and path_waypoint_idx < path_waypoints.size():
		var wp: Vector3 = path_waypoints[path_waypoint_idx]
		var pos: Vector3 = _body.global_position if _body != null else Vector3.ZERO
		var d: float = Vector2(pos.x - wp.x, pos.z - wp.z).length()
		if d < WAYPOINT_REACH_DIST:
			path_waypoint_idx += 1
		if path_waypoint_idx < path_waypoints.size():
			target = path_waypoints[path_waypoint_idx]
		# else: target remains the final goal already set by goto_world
	super.tick_movement(delta, frame_phase)

	# Body facing — rotate to face velocity direction at most
	# max_turn_rate_rad_s per second. Aircraft handles its own rotation
	# in AircraftMovement._update_bank; this is for ground units only.
	if _body != null:
		var dir_xz: Vector3 = Vector3(_velocity.x, 0.0, _velocity.z)
		# Higher threshold (4.0 = 2 u/s) suppresses rotation jitter
		# from low-speed velocity oscillation near slot. Below this
		# the body holds its current facing.
		if dir_xz.length_squared() > 4.0:
			# Godot Node3D forward is -Z; convert dir_xz to a target
			# yaw and step the body's yaw toward it, rate-limited.
			var desired_yaw: float = atan2(-dir_xz.x, -dir_xz.z)
			var current_yaw: float = _body.rotation.y
			var yaw_diff: float = wrapf(desired_yaw - current_yaw, -PI, PI)
			var max_step: float = max_turn_rate_rad_s * delta
			var yaw_step: float = clampf(yaw_diff, -max_step, max_step)
			_body.rotation.y = current_yaw + yaw_step

	# Gravity — new system owns Y velocity for ground units. Aircraft
	# don't get this (AircraftMovement holds Y at base_altitude).
	# _body_physics is non-null only when parent is CharacterBody3D,
	# which is always true for ground units.
	if _body_physics != null:
		if _body_physics.is_on_floor() and _body_physics.velocity.y < 0.0:
			_body_physics.velocity.y = 0.0
		else:
			_body_physics.velocity.y -= GRAVITY * delta
			_body_physics.move_and_slide()

## PF-A — kernel-driven velocity application for ground units. Mirrors what
## the legacy tick_movement did after super: yaw the body to face the motion
## direction, then apply gravity + move_and_slide. Without this, flag-on
## hounds would face their spawn direction forever and (if airborne) wouldn't
## fall.
func _apply_kernel_velocity(v: Vector3, delta: float) -> void:
	if _body_physics == null:
		# Fall back to base behavior for non-CharacterBody3D ground units
		# (none in PF-A, but keep the contract honest).
		super._apply_kernel_velocity(v, delta)
		return

	# Apply kernel XZ velocity; preserve / add Y for gravity.
	_body_physics.velocity.x = v.x
	_body_physics.velocity.z = v.z
	if _body_physics.is_on_floor() and _body_physics.velocity.y < 0.0:
		_body_physics.velocity.y = 0.0
	else:
		_body_physics.velocity.y -= GRAVITY * delta

	_body_physics.move_and_slide()

	# Body facing — rotate to face motion direction at most max_turn_rate_rad_s
	# per second. Same formula as the legacy tick_movement path uses.
	if _body != null:
		var dir_xz: Vector3 = Vector3(v.x, 0.0, v.z)
		# Threshold (4.0 = 2 u/s squared) suppresses rotation jitter at low speed.
		if dir_xz.length_squared() > 4.0:
			# Godot Node3D forward is -Z; map dir_xz to target yaw.
			var desired_yaw: float = atan2(-dir_xz.x, -dir_xz.z)
			var current_yaw: float = _body.rotation.y
			var yaw_diff: float = wrapf(desired_yaw - current_yaw, -PI, PI)
			var max_step: float = max_turn_rate_rad_s * delta
			var yaw_step: float = clampf(yaw_diff, -max_step, max_step)
			_body.rotation.y = current_yaw + yaw_step


func _separate_neighbors(prefetched: Array = []) -> Array:
	# Use prefetched raw list when the centralized tick_movement
	# already queried SpatialIndex on this heavy tick (saves the
	# second nearby() call). Falls back to its own query for
	# legacy callers (e.g. _compute_pushout_dir from stuck recovery).
	var raw: Array = prefetched
	if raw.is_empty():
		var idx: SpatialIndex = _get_spatial_idx()
		if idx == null:
			return []
		raw = idx.nearby(_body.global_position, separate_min_distance + 1.0)
	var filtered: Array = []
	for n: Variant in raw:
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		if n == _body or n == get_parent():
			continue
		# Skip same-group friendlies — they're slot-following, not separation contacts.
		if squad_group_ref != null and squad_group_ref.has_member_for_body(n as Node3D):
			continue
		# Skip buildings — those go to AVOID, not SEPARATE.
		if n is Building:
			continue
		# Skip workers — they're noncombat pass-through agents (collision_layer
		# 0, foundation-clear ignores them). Letting them push other units via
		# SEPARATE made the salvage crawler drift around erratically inside its
		# own gatherer cloud — every worker counted as a separation contact.
		if n is SalvageWorker:
			continue
		filtered.append(n)
	return filtered

func _avoid_obstacles(prefetched: Array = []) -> Array:
	# Same prefetched-raw-list contract as _separate_neighbors.
	# DEAD-CODE FIX: the previous build added a wrecks check via
	# `(n as Node).is_in_group("wrecks")` for every candidate — but
	# Wreck nodes are only registered in the "wrecks" group, not
	# "units" or "buildings", which are the only groups the
	# SpatialIndex buckets. So `n` (which came from the index) was
	# never in "wrecks" and the string-keyed group lookup always
	# returned false. Profile 536 flagged this at 55 s session time
	# / 1.45 ms / call — by far the worst per-call cost on the board
	# and pure waste. Wreck avoidance via physics collision still
	# works (Wreck is a StaticBody3D on layer 8). If proper steering
	# avoidance is wanted, the right fix is to add wrecks to
	# SpatialIndex's tracked groups, not to chase them via a string
	# lookup against the wrong bucket contents.
	var raw: Array = prefetched
	if raw.is_empty():
		var idx: SpatialIndex = _get_spatial_idx()
		if idx == null:
			return []
		raw = idx.nearby(_body.global_position, avoid_min_distance + 2.0)
	var filtered: Array = []
	for n: Variant in raw:
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		if n is Building:
			filtered.append(n)
	return filtered

func _on_stuck_level_1_repath() -> void:
	## Re-query the path toward the FINAL destination, not the current
	## waypoint. _physics_process overwrites `target` with the live
	## waypoint each frame, so using `target` here would query a path
	## back to the waypoint we're already chasing — when the new path
	## ends, the unit would stop at the waypoint instead of continuing
	## to the original goal.
	if not has_target():
		return
	var router: NavRouter = _get_nav_router()
	if router == null:
		return
	var goal: Vector3 = arrival_target()
	var result: PathResult = router.query_path(
		_body.global_position, goal, agent_profile)
	if result.valid:
		path_waypoints = result.waypoints
		path_waypoint_idx = 1

func _on_stuck_level_3_drop() -> void:
	## Drop from any current SquadGroup with NO_PROGRESS reason; retry the
	## path with a wider goal-snap so targets near (but not on) the navmesh
	## become reachable. Use the FINAL destination, not the live waypoint
	## — same reasoning as _on_stuck_level_1_repath.
	if squad_group_ref != null and is_instance_valid(squad_group_ref):
		squad_group_ref.drop_member(get_parent(), SquadGroup.DropReason.NO_PROGRESS)
		# drop_member nulls our squad_group_ref via SquadGroup logic
	if not has_target():
		return
	var router: NavRouter = _get_nav_router()
	if router == null:
		return
	var goal: Vector3 = arrival_target()
	var snapped_goal: Vector3 = router.project_to_navmesh(
		goal, agent_profile, stuck_goal_snap_radius)
	var result: PathResult = router.query_path(
		_body.global_position, snapped_goal, agent_profile)
	if result.valid:
		path_waypoints = result.waypoints
		path_waypoint_idx = 1
	else:
		# No path even to the snapped goal. Fall back to direct seek; the
		# next stuck level will escalate further if still stuck.
		target = snapped_goal
		path_waypoints = PackedVector3Array()
		path_waypoint_idx = 0

func _is_combat_engaged() -> bool:
	var owner_unit: Node = get_parent()
	if owner_unit == null:
		return false
	if owner_unit.has_method("_in_active_combat"):
		return owner_unit._in_active_combat() as bool
	return false

func _get_nav_router() -> NavRouter:
	if _cached_nav_router == null or not is_instance_valid(_cached_nav_router):
		_cached_nav_router = NavRouter.get_instance(get_tree().current_scene)
	return _cached_nav_router
