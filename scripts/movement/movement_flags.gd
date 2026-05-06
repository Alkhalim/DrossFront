class_name MovementFlags
extends RefCounted
## Global flags for pathfinding migration (Plan A).
## Provides a single access point for feature gates controlling the transition
## from legacy NavigationAgent3D to the new MovementComponent-based system.
## Gated by `drossfront/movement/use_new_system` in project.godot.


## Returns true if the new MovementComponent-based pathfinding
## should be used instead of the legacy NavigationAgent3D path.
## Plan A default: false. Plan C will delete the legacy path
## and this accessor.
static func use_new_system() -> bool:
	return ProjectSettings.get_setting("drossfront/movement/use_new_system", false) as bool
