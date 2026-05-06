class_name PathResult
extends RefCounted
## Returned by NavRouter.query_path. Carries the polyline plus a
## valid flag — invalid means "no path found"; the caller should
## treat the agent as unable to reach goal and escalate stuck
## recovery / fall back to last_order_destination.

var waypoints: PackedVector3Array = PackedVector3Array()
var valid: bool = false              # if false, callers MUST NOT consume waypoints

func _init(p_waypoints: PackedVector3Array = PackedVector3Array(),
	p_valid: bool = false) -> void:
	waypoints = p_waypoints
	valid = p_valid
