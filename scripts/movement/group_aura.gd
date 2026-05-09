class_name GroupAura
extends Node
## Lightweight order-layer container for flag-on (use_flowfield) movement
## orders. Replaces SquadGroup's slot/range-rank machinery with a simple
## destination + members + flow-field-id-per-class triple.
##
## Lifecycle:
##   - Created by selection_manager when a multi-squad move is issued and
##     the flowfield flag is on.
##   - Owns one FieldId per agent class represented in members.
##   - Releases its FieldIds on _exit_tree.

const MovementNativeBootstrap = preload("res://scripts/movement/movement_native_bootstrap.gd")

var members: Array[Node] = []
var destination: Vector3 = Vector3.ZERO
var stance: int = 0                     # 0 = move, 1 = attack-move
var field_ids: Dictionary = {}          # int agent_class → FieldId

# Class lookup: maps Unit (or its MovementComponent) to one of 0/1/2.
const AGENT_CLASS_SMALL: int = 0
const AGENT_CLASS_MEDIUM: int = 1
const AGENT_CLASS_LARGE: int = 2

func setup(initial_members: Array, dest: Vector3, initial_stance: int) -> void:
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
	var classes_seen: Dictionary = {}
	for m: Node in members:
		var c: int = _agent_class_for(m)
		classes_seen[c] = true
	for c_v: Variant in classes_seen:
		var c: int = c_v as int
		var fid: int = server.call("build_field", destination, c)
		if fid != 0:
			field_ids[c] = fid
		else:
			push_warning("[GroupAura] build_field failed for class %d at %s" % [c, destination])
	# Wire each member to its class's field on the kernel.
	var kernel: Object = MovementNativeBootstrap.get_kernel(get_tree().current_scene)
	if kernel == null:
		return
	for m: Node in members:
		var mc: Node = m.get_node_or_null("MovementComponent")
		if mc == null:
			continue
		if not "kernel_handle" in mc:
			continue
		var c: int = _agent_class_for(m)
		var fid: int = field_ids.get(c, 0) as int
		if fid != 0:
			kernel.call("set_agent_target", mc.kernel_handle, get_instance_id(), fid, stance)

func _exit_tree() -> void:
	var server: Object = MovementNativeBootstrap.get_server(get_tree().current_scene)
	if server == null:
		return
	for fid_v: Variant in field_ids.values():
		var fid: int = fid_v as int
		if fid != 0:
			server.call("release_field", fid)
	field_ids.clear()

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
