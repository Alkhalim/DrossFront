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
	# PF-A pilot: Anvil Hound is the only migrated unit and is small class.
	# PF-B widens this lookup to read from the unit's stat resource.
	if "stats" in unit:
		var stats: Variant = unit.get("stats")
		if stats != null and "id" in stats:
			var id: String = stats.id as String
			if id == "anvil_hound":
				return AGENT_CLASS_SMALL
	return AGENT_CLASS_SMALL
