class_name GroupAura
extends Node
## Lightweight order-layer container for flag-on (use_flowfield) movement
## orders. Replaces SquadGroup's slot/range-rank machinery with a simple
## destination + members + flow-field-id-per-class triple.
##
## Lifecycle:
##   - Created by selection_manager when a multi-squad move is issued and
##     the flowfield flag is on.
##   - For move orders: owns one FieldId per agent class represented in members.
##   - For attack orders (is_attack=true): owns one FieldId per member, each
##     at a per-squad arc-offset position to spread the firing line laterally.
##   - Releases its FieldIds on _exit_tree.

const MovementNativeBootstrap = preload("res://scripts/movement/movement_native_bootstrap.gd")

var members: Array[Node] = []
var destination: Vector3 = Vector3.ZERO
var stance: int = 0                         # 0 = move, 1 = attack-move
var field_ids: Dictionary = {}              # int agent_class → FieldId  (move orders)
var _per_member_field_ids: Dictionary = {}  # int instance_id → FieldId  (attack orders)

# Class lookup: maps Unit (or its MovementComponent) to one of 0/1/2.
const AGENT_CLASS_SMALL: int = 0
const AGENT_CLASS_MEDIUM: int = 1
const AGENT_CLASS_LARGE: int = 2

func setup(initial_members: Array, dest: Vector3, initial_stance: int, is_attack: bool = false) -> void:
	members.clear()
	for m: Variant in initial_members:
		if m is Node:
			members.append(m as Node)
	destination = dest
	stance = initial_stance
	var server: Object = MovementNativeBootstrap.get_server(get_tree().current_scene)
	if server == null:
		push_warning("[GroupAura] FlowFieldServer unavailable — no fields built")
		return
	var kernel: Object = MovementNativeBootstrap.get_kernel(get_tree().current_scene)
	if kernel == null:
		return

	if is_attack and members.size() > 1:
		_setup_attack_spread(dest, server, kernel)
	else:
		_setup_move(dest, server, kernel)


func _setup_move(dest: Vector3, server: Object, kernel: Object) -> void:
	## Shared-field path: one FieldId per agent class, all units on same goal.
	# Collect ground agent classes only — aircraft don't need flow fields;
	# they use the kernel's IS_AIRCRAFT branch (B2) with set_agent_target_pos.
	var classes_seen: Dictionary = {}
	for m: Node in members:
		var mc_check: Node = m.get_node_or_null("MovementComponent")
		if mc_check == null or not (mc_check is MovementComponent):
			continue
		if (mc_check as MovementComponent)._opts_unit_is_aircraft():
			continue  # aircraft skip field-build; handled via set_agent_target_pos below
		var c: int = _agent_class_for(m)
		classes_seen[c] = true
	for c_v: Variant in classes_seen:
		var c: int = c_v as int
		var fid: int = server.call("build_field", dest, c)
		if fid != 0:
			field_ids[c] = fid
		else:
			push_warning("[GroupAura] build_field failed for class %d at %s" % [c, dest])
	# Wire each member to its class's field on the kernel.
	for m: Node in members:
		var mc: Node = m.get_node_or_null("MovementComponent")
		if mc == null:
			continue
		if not "kernel_handle" in mc:
			continue
		if (mc as MovementComponent)._opts_unit_is_aircraft():
			# PF-B-final-fix: route through AircraftMovement.goto_world so Y
			# gets remapped to base_altitude. Raw destination (Y≈ground) would
			# cause the kernel's AIRCRAFT branch (B2) to 3D-seek toward
			# ground level, diving aircraft into terrain.
			(mc as AircraftMovement).goto_world(dest)
		else:
			var c: int = _agent_class_for(m)
			var fid: int = field_ids.get(c, 0) as int
			if fid != 0:
				kernel.call("set_agent_target", mc.kernel_handle, get_instance_id(), fid, stance)


func _setup_attack_spread(dest: Vector3, server: Object, kernel: Object) -> void:
	## Per-squad arc-offset path: each member gets its own field at a lateral
	## offset perpendicular to the approach direction, so squads fan out into a
	## firing arc rather than all converging on the same cell.

	# Compute squad centroid from valid ground members.
	var centroid: Vector3 = Vector3.ZERO
	var count: int = 0
	for m: Node in members:
		if not is_instance_valid(m):
			continue
		centroid += m.global_position
		count += 1
	if count > 0:
		centroid /= float(count)

	# Approach direction from centroid to target (XZ plane only).
	var approach_dir: Vector3 = dest - centroid
	approach_dir.y = 0.0
	if approach_dir.length() < 0.01:
		approach_dir = Vector3(0.0, 0.0, 1.0)
	else:
		approach_dir = approach_dir.normalized()

	# Right-perpendicular in XZ: rotate approach 90° clockwise.
	var perp: Vector3 = Vector3(approach_dir.z, 0.0, -approach_dir.x)

	# Spread half-width scales with member count.
	# 2 members: 4m  |  5 members: ~10.5m  |  12+ members: 18m (capped)
	var n: int = members.size()
	var spread_half_width: float = clampf(3.0 + float(n) * 1.5, 4.0, 18.0)

	for i: int in members.size():
		var m: Node = members[i]
		if not is_instance_valid(m):
			continue
		var mc: Node = m.get_node_or_null("MovementComponent")
		if mc == null or not "kernel_handle" in mc:
			continue

		# Compute this member's laterally-offset destination.
		var lateral_t: float = (float(i) / float(n - 1)) * 2.0 - 1.0
		var lateral_offset: float = lateral_t * spread_half_width
		var squad_dest: Vector3 = dest + perp * lateral_offset

		if (mc as MovementComponent)._opts_unit_is_aircraft():
			# Apply the same arc-spread to aircraft via goto_world with offset pos.
			var air_dest: Vector3 = squad_dest
			(mc as AircraftMovement).goto_world(air_dest)
		else:
			var ac: int = _agent_class_for(m)
			var fid: int = server.call("build_field", squad_dest, ac) as int
			if fid != 0:
				_per_member_field_ids[m.get_instance_id()] = fid
				kernel.call("set_agent_target", mc.kernel_handle, get_instance_id(), fid, stance)
			else:
				push_warning("[GroupAura] build_field failed for attack-spread member %d at %s" % [i, squad_dest])


func _exit_tree() -> void:
	var server: Object = MovementNativeBootstrap.get_server(get_tree().current_scene)
	if server == null:
		return
	# Release move-order shared fields (keyed by agent_class).
	for fid_v: Variant in field_ids.values():
		var fid: int = fid_v as int
		if fid != 0:
			server.call("release_field", fid)
	field_ids.clear()
	# Release attack-order per-member fields (keyed by instance_id).
	for fid_v: Variant in _per_member_field_ids.values():
		var fid: int = fid_v as int
		if fid != 0:
			server.call("release_field", fid)
	_per_member_field_ids.clear()

static func _agent_class_for(unit: Node) -> int:
	# PF-B: read pf_agent_class from the unit's stat resource. Crawlers
	# explicitly use AGENT_CLASS_LARGE regardless of the stat field
	# (CrawlerMovement._agent_class_for_self enforces it on registration);
	# the stat field on a crawler can stay at its default. Falls back to
	# AGENT_CLASS_SMALL when stats are missing or the field is absent
	# (covers ghost previews and pre-PF-B .tres files).
	if "stats" in unit:
		var stats: Resource = unit.get("stats") as Resource
		if stats != null and "is_crawler" in stats and (stats.get("is_crawler") as bool):
			return AGENT_CLASS_LARGE
		if stats != null and "pf_agent_class" in stats:
			var v: int = stats.get("pf_agent_class") as int
			if v >= 0 and v <= 2:
				return v
	return AGENT_CLASS_SMALL
