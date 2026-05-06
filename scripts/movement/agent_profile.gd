class_name AgentProfile
extends RefCounted
## Per-agent navmesh requirements. Passed to NavRouter.query_path
## so the router can pick the right navmesh / map filter for the
## requesting agent. Crawlers want a wide profile; squad-default
## is fine for almost everything else in Plan A.

var radius: float = 0.6           # agent radius for navmesh queries
var max_climb: float = 0.5        # max step height the agent can climb
var max_slope_deg: float = 35.0   # max walkable slope
var profile_id: StringName = &""  # identity label; used as NavRouter cache key and (Plan B) navmesh selector

func _init(p_radius: float = 0.6,
	p_climb: float = 0.5,
	p_slope_deg: float = 35.0,
	p_id: StringName = &"") -> void:
	radius = p_radius
	max_climb = p_climb
	max_slope_deg = p_slope_deg
	profile_id = p_id
