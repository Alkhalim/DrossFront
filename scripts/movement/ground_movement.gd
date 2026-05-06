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
		emit_signal("path_unreachable", REASON_NO_NAVMESH_PATH)

func set_slot_target(slot_world: Vector3) -> void:
	## Called per-frame by SquadGroup in cohesive mode. No path
	## query — local SEEK toward the moving slot. Path queries
	## happen at the group level for cohesive groups.
	target = slot_world
	path_waypoints = PackedVector3Array()
	path_waypoint_idx = 0

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

func _separate_neighbors() -> Array:
	var idx: SpatialIndex = _get_spatial_idx()
	if idx == null:
		return []
	var pos: Vector3 = _body.global_position
	var raw: Array = idx.nearby(pos, separate_min_distance + 1.0)
	var filtered: Array = []
	for n: Variant in raw:
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		if n == _body or n == get_parent():
			continue
		# Skip same-group friendlies — they're slot-following, not separation contacts.
		if squad_group_ref != null and squad_group_ref.has_member_for_body(n as Node3D):
			continue
		# Skip buildings — those go to AVOID, not SEPARATE.
		if (n as Node).is_in_group("buildings"):
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
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		if (n as Node).is_in_group("buildings") or (n as Node).is_in_group("wrecks"):
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

func _is_combat_engaged() -> bool:
	var owner_unit: Node = get_parent()
	if owner_unit == null:
		return false
	if "in_combat" in owner_unit:
		return owner_unit.in_combat as bool
	return false

func _get_spatial_idx() -> SpatialIndex:
	if _cached_spatial_idx == null or not is_instance_valid(_cached_spatial_idx):
		_cached_spatial_idx = SpatialIndex.get_instance(get_tree().current_scene)
	return _cached_spatial_idx

func _get_nav_router() -> NavRouter:
	if _cached_nav_router == null or not is_instance_valid(_cached_nav_router):
		_cached_nav_router = NavRouter.get_instance(get_tree().current_scene)
	return _cached_nav_router
