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

# Auto-rejoin state (PA-15)
var last_group_ref: SquadGroup = null
var last_drop_reason: int = -1                    # SquadGroup.DropReason or -1
var last_order_destination: Vector3 = Vector3.INF

func _ready() -> void:
	super._ready()
	if agent_profile == null:
		agent_profile = AgentProfile.new(0.6, 0.5, 35.0, &"squad_default")

# PA-10 will add: goto_world, set_slot_target, _physics_process override,
# _separate_neighbors, _avoid_obstacles, _on_stuck_level_1_repath,
# _is_combat_engaged.
