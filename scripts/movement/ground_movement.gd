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

# Cached singleton refs to avoid per-frame linear scans of scene root children
var _cached_spatial_idx: SpatialIndex = null
var _cached_nav_router: NavRouter = null

# Auto-rejoin state (PA-15)
var last_group_ref: SquadGroup = null
var last_drop_reason: int = -1                    # SquadGroup.DropReason or -1
var last_order_destination: Vector3 = Vector3.INF

func _ready() -> void:
	super._ready()
	if agent_profile == null:
		agent_profile = AgentProfile.new(0.6, 0.5, 35.0, &"squad_default")

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

## Override of MovementComponent.arrival_target. When a path is active,
## return the path's final waypoint — the unit-level arrival poll uses
## this to avoid registering arrival at intermediate waypoints (where
## seek's arrival_radius slowdown would otherwise count as "settled" if
## separation forces happen to balance seek into low velocity).
func arrival_target() -> Vector3:
	if path_waypoints.size() > 0:
		return path_waypoints[path_waypoints.size() - 1]
	return target

func _physics_process(delta: float) -> void:
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
	super._physics_process(delta)

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

func _separate_neighbors() -> Array:
	var idx: SpatialIndex = _get_spatial_idx()
	if idx == null:
		return []
	var pos: Vector3 = _body.global_position
	var raw: Array = idx.nearby(pos, separate_min_distance + 1.0)
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
		filtered.append(n)
	return filtered

func _avoid_obstacles() -> Array:
	var idx: SpatialIndex = _get_spatial_idx()
	if idx == null:
		return []
	var pos: Vector3 = _body.global_position
	var raw: Array = idx.nearby(pos, avoid_min_distance + 2.0)
	var filtered: Array = []
	for n: Variant in raw:
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		if n is Building or (n as Node).is_in_group("wrecks"):
			filtered.append(n)
	return filtered

func _on_stuck_level_1_repath() -> void:
	## Re-query the path with the current target.
	if not has_target():
		return
	var router: NavRouter = _get_nav_router()
	if router == null:
		return
	var result: PathResult = router.query_path(
		_body.global_position, target, agent_profile)
	if result.valid:
		path_waypoints = result.waypoints
		path_waypoint_idx = 1

func _on_stuck_level_3_drop() -> void:
	## Squad has been at Level 2 (push-out) for stuck_drop_cooldown
	## seconds without recovering. Drop from any current SquadGroup
	## with NO_PROGRESS reason; retry with a wider goal-snap so that
	## targets near (but not on) the navmesh become reachable.
	if squad_group_ref != null and is_instance_valid(squad_group_ref):
		squad_group_ref.drop_member(get_parent(), SquadGroup.DropReason.NO_PROGRESS)
		# drop_member nulls our squad_group_ref via SquadGroup logic
	if not has_target():
		return
	var router: NavRouter = _get_nav_router()
	if router == null:
		return
	# Wider goal snap: ask the router to project our target up to
	# stuck_goal_snap_radius units to find a valid cell.
	var snapped_target: Vector3 = router.project_to_navmesh(
		target, agent_profile, stuck_goal_snap_radius)
	target = snapped_target
	var result: PathResult = router.query_path(
		_body.global_position, target, agent_profile)
	if result.valid:
		path_waypoints = result.waypoints
		path_waypoint_idx = 1

func _is_combat_engaged() -> bool:
	var owner_unit: Node = get_parent()
	if owner_unit == null:
		return false
	if owner_unit.has_method("_in_active_combat"):
		return owner_unit._in_active_combat() as bool
	return false

func _get_spatial_idx() -> SpatialIndex:
	if _cached_spatial_idx == null or not is_instance_valid(_cached_spatial_idx):
		_cached_spatial_idx = SpatialIndex.get_instance(get_tree().current_scene)
	return _cached_spatial_idx

func _get_nav_router() -> NavRouter:
	if _cached_nav_router == null or not is_instance_valid(_cached_nav_router):
		_cached_nav_router = NavRouter.get_instance(get_tree().current_scene)
	return _cached_nav_router
