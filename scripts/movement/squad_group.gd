class_name SquadGroup
extends Node
## Order-layer container for a squad-of-squads movement order.
## Created by selection_manager when the player issues a multi-
## squad move; lives until destination reached or all members
## drop. Owns convoy speed cap, group_center advance, slot
## assignment, drop/rejoin.
##
## Reference: spec §3, §4, §5, §10.

enum DropReason { COMBAT, NO_PROGRESS, PLAYER_ORDER }

@export var formation_spacing: float = 1.7    # squad-to-squad gap; tune in inspector
@export var cohesion_radius_multiplier: float = 4.0
@export var lag_distance_multiplier: float = 2.0
@export var group_center_throttle_factor: float = 0.5
@export var slot_proximity_threshold: float = 2.0     # × formation_spacing
@export var drop_on_no_progress_seconds: float = 1.5

# --- State ---
var _members: Array[Node] = []
var _slot_offsets: Dictionary = {}                # Node -> Vector3 (formation-local)
var _destination: Vector3 = Vector3.ZERO
var _is_cohesive: bool = true
var _group_center: Vector3 = Vector3.ZERO
var _group_orientation: Basis = Basis.IDENTITY
var _path_waypoints: PackedVector3Array = PackedVector3Array()
var _path_idx: int = 0
var _convoy_speed_cap: float = 8.0
var _convoy_turn_rate_cap: float = TAU
var _no_progress_timers: Dictionary = {}          # Node -> float

# Shared default profile — Plan A uses one ground-squad profile for
# all group path queries. Plan B introduces per-profile maps (crawler).
static var _DEFAULT_GROUND_PROFILE: AgentProfile = null

static func _get_default_ground_profile() -> AgentProfile:
	if _DEFAULT_GROUND_PROFILE == null:
		_DEFAULT_GROUND_PROFILE = AgentProfile.new(0.6, 0.5, 35.0, &"squad_default")
	return _DEFAULT_GROUND_PROFILE

# --- Public API ---

func setup(members: Array, destination: Vector3) -> void:
	_members = []
	for m: Variant in members:
		if m is Node:
			_members.append(m as Node)
	_destination = destination
	# Wire each member's back-pointer so GroundMovement._separate_neighbors
	# can filter same-group friendlies. (Without this, members repel each
	# other inside their own formation.)
	for m: Node in _members:
		var gm: GroundMovement = _gm_for(m)
		if gm != null:
			gm.squad_group_ref = self
	_decide_mode()
	_assign_slots()
	_recompute_caps()
	_group_center = _centroid()
	if _is_cohesive:
		_query_group_path()

func add_member(m: Node) -> void:
	if m in _members:
		return
	_members.append(m)
	_assign_slots()
	_recompute_caps()
	var gm: GroundMovement = _gm_for(m)
	if gm != null:
		gm.squad_group_ref = self

func drop_member(m: Node, reason: int) -> void:
	if not (m in _members):
		return
	_members.erase(m)
	_slot_offsets.erase(m)
	_no_progress_timers.erase(m)
	_recompute_caps()
	var gm: GroundMovement = _gm_for(m)
	if gm != null:
		gm.squad_group_ref = null
		gm.last_group_ref = self
		gm.last_drop_reason = reason
		gm.last_order_destination = _destination
		if reason == DropReason.COMBAT:
			_connect_combat_end_for(m, gm)
	_assign_slots()
	if _members.is_empty():
		queue_free()

func has_member_for_body(body: Node3D) -> bool:
	for m: Node in _members:
		if not is_instance_valid(m):
			continue
		if m == body:
			return true
		if m.get_parent() == body or body.get_parent() == m:
			return true
	return false

# --- Per-frame ---

func _physics_process(delta: float) -> void:
	# Prune freed/invalid Node refs so the empty-check below catches
	# whole-squad wipeouts. Without this, freed members stay in
	# _members forever and the group ticks indefinitely.
	var live: Array[Node] = []
	for m: Node in _members:
		if is_instance_valid(m):
			live.append(m)
		else:
			_slot_offsets.erase(m)
			_no_progress_timers.erase(m)
	_members = live

	if _members.is_empty():
		queue_free()
		return
	if _is_cohesive:
		_advance_cohesive(delta)
	else:
		_check_dispersed_promotion()
	_check_drop_on_no_progress(delta)
	_update_member_targets()

# --- Implementation ---

func _decide_mode() -> void:
	var c: Vector3 = _centroid()
	var max_d: float = 0.0
	for m: Node in _members:
		if not is_instance_valid(m): continue
		var p: Vector3 = (m as Node3D).global_position
		var d: float = Vector2(p.x - c.x, p.z - c.z).length()
		max_d = maxf(max_d, d)
	var threshold: float = cohesion_radius_multiplier * formation_spacing
	_is_cohesive = max_d < threshold

func _centroid() -> Vector3:
	var s: Vector3 = Vector3.ZERO
	var n: int = 0
	for m: Node in _members:
		if not is_instance_valid(m): continue
		s += (m as Node3D).global_position
		n += 1
	if n == 0:
		return Vector3.ZERO
	return s / float(n)

func _assign_slots() -> void:
	var sorted_members: Array = FormationLayouts.range_rank_sort(_members)
	var slots: Array[Vector3] = FormationLayouts.slots_for(sorted_members.size())
	_slot_offsets.clear()
	for i: int in sorted_members.size():
		_slot_offsets[sorted_members[i]] = slots[i] * formation_spacing

func _recompute_caps() -> void:
	var sp: float = INF
	var tr: float = INF
	for m: Node in _members:
		if not is_instance_valid(m): continue
		var gm: GroundMovement = _gm_for(m)
		if gm == null: continue
		sp = minf(sp, gm.max_speed)
		tr = minf(tr, gm.max_turn_rate_rad_s)
	if sp == INF: sp = 8.0
	if tr == INF: tr = TAU
	_convoy_speed_cap = sp
	_convoy_turn_rate_cap = tr

func _gm_for(m: Node) -> GroundMovement:
	if not is_instance_valid(m): return null
	var c: Node = m.get_node_or_null("MovementComponent")
	return c as GroundMovement if c is GroundMovement else null

func _query_group_path() -> void:
	var router: NavRouter = NavRouter.get_instance(get_tree().current_scene)
	if router == null:
		_path_waypoints = PackedVector3Array()
		_path_idx = 0
		return
	var profile: AgentProfile = _get_default_ground_profile()
	var result: PathResult = router.query_path(_group_center, _destination, profile)
	if result.valid:
		_path_waypoints = result.waypoints
		_path_idx = 1

func _advance_cohesive(delta: float) -> void:
	if _path_waypoints.size() < 2 or _path_idx >= _path_waypoints.size():
		return
	var lag_count: int = 0
	var lag_thresh: float = lag_distance_multiplier * formation_spacing
	var lag_thresh_sq: float = lag_thresh * lag_thresh
	for m: Node in _members:
		if not is_instance_valid(m): continue
		var slot_world: Vector3 = _slot_world(m)
		if (m as Node3D).global_position.distance_squared_to(slot_world) > lag_thresh_sq:
			lag_count += 1
	var lag_ratio: float = float(lag_count) / maxf(float(_members.size()), 1.0)
	var advance: float = _convoy_speed_cap * (1.0 - group_center_throttle_factor * lag_ratio) * delta
	var wp: Vector3 = _path_waypoints[_path_idx]
	var to_wp: Vector3 = wp - _group_center
	to_wp.y = 0.0
	var d: float = to_wp.length()
	if d < 0.5:
		_path_idx += 1
		return
	var step: Vector3 = (to_wp / d) * minf(advance, d)
	_group_center += step
	if step.length() > 0.001:
		var fwd: Vector3 = step.normalized()
		var max_ang: float = _convoy_turn_rate_cap * delta
		var cur_fwd: Vector3 = -_group_orientation.z
		var ang: float = cur_fwd.signed_angle_to(fwd, Vector3.UP)
		var ang_step: float = clampf(ang, -max_ang, max_ang)
		_group_orientation = _group_orientation.rotated(Vector3.UP, ang_step)

func _check_dispersed_promotion() -> void:
	# Plan A simplification: promote when all members are within
	# cohesion_radius of the DESTINATION (means dispersed group has
	# gathered near the destination).
	var threshold: float = cohesion_radius_multiplier * formation_spacing
	var max_to_dest: float = 0.0
	for m: Node in _members:
		if not is_instance_valid(m): continue
		max_to_dest = maxf(max_to_dest, (m as Node3D).global_position.distance_to(_destination))
	if max_to_dest < threshold:
		_is_cohesive = true
		_group_center = _centroid()
		_query_group_path()

func _check_drop_on_no_progress(delta: float) -> void:
	for m: Node in _members.duplicate():
		if not is_instance_valid(m): continue
		var gm: GroundMovement = _gm_for(m)
		if gm == null: continue
		if gm._stuck_level >= 2:
			var t: float = _no_progress_timers.get(m, 0.0) as float
			t += delta
			_no_progress_timers[m] = t
			if t >= drop_on_no_progress_seconds:
				drop_member(m, DropReason.NO_PROGRESS)
		else:
			# Recovered (stuck_level reset) — clear the dwell timer
			_no_progress_timers.erase(m)

func _update_member_targets() -> void:
	for m: Node in _members:
		if not is_instance_valid(m): continue
		var gm: GroundMovement = _gm_for(m)
		if gm == null: continue
		if _is_cohesive:
			# Relax formation during combat — let engaged members hold
			# their current position to fight rather than dragging them
			# back to slot. When combat ends, the next tick re-applies
			# set_slot_target and the member sprints back (catch-up
			# phase via _speed_cap_for returns INF).
			var combat_engaged: bool = false
			if gm.has_method("_is_combat_engaged"):
				combat_engaged = gm._is_combat_engaged()
			if combat_engaged:
				gm.clear_target()                       # no SEEK; unit holds + fires
				gm.effective_max_speed_cap = INF        # uncapped for post-combat sprint
				gm.effective_max_turn_rate_cap = INF
			else:
				var slot_world: Vector3 = _slot_world(m)
				if gm.has_method("set_slot_target"):
					gm.set_slot_target(slot_world)
				gm.effective_max_speed_cap = _speed_cap_for(m)
				gm.effective_max_turn_rate_cap = _convoy_turn_rate_cap
		else:
			# Dispersed: each squad has its own goto from selection_manager.
			gm.effective_max_speed_cap = INF
			gm.effective_max_turn_rate_cap = INF

func _slot_world(m: Node) -> Vector3:
	var off_local: Vector3 = _slot_offsets.get(m, Vector3.ZERO)
	return _group_center + _group_orientation * off_local

func _speed_cap_for(m: Node) -> float:
	var gm: GroundMovement = _gm_for(m)
	if gm == null: return _convoy_speed_cap
	var slot_world: Vector3 = _slot_world(m)
	var d: float = (m as Node3D).global_position.distance_to(slot_world)
	if d > slot_proximity_threshold * formation_spacing:
		return INF
	return _convoy_speed_cap

func _connect_combat_end_for(m: Node, _gm: GroundMovement) -> void:
	var combat: Node = m.get_node_or_null("CombatComponent")
	if combat == null:
		return
	if not combat.has_signal("combat_ended"):
		return
	var cb: Callable = _on_member_combat_ended.bind(m)
	# is_connected works for bind()-created Callables because Godot 4
	# compares Callables by target+method+bound-args. If this is ever
	# refactored to a lambda or sub-object method, this guard silently
	# stops deduplicating — re-check before changing.
	if not combat.is_connected("combat_ended", cb):
		combat.connect("combat_ended", cb)

func _on_member_combat_ended(m: Node) -> void:
	if not is_instance_valid(self) or not is_instance_valid(m):
		return
	var gm: GroundMovement = _gm_for(m)
	if gm == null:
		return
	if gm.last_drop_reason != DropReason.COMBAT:
		return
	if m in _members:
		return
	add_member(m)
	if gm.has_method("set_slot_target"):
		gm.set_slot_target(_slot_world(m))
