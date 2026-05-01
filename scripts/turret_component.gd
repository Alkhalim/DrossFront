class_name TurretComponent
extends Node
## Attaches to a Building. Auto-attacks enemies in range.
##
## Each turret has a profile (`balanced`, `anti_light`, `anti_heavy`, `anti_air`)
## chosen at runtime. Profile values drive damage, fire rate, range, and the
## projectile's role tag; the building rebuilds its visual barrel to match.

const SEARCH_INTERVAL: float = 0.5
## How fast the turret swings to face its target, in lerp factor per second.
const TURRET_TURN_SPEED: float = 5.0

## Backwards-compatible defaults so external code can still read these.
## Damage values were 3x'd (was 15) — turrets read as a real defensive
## investment now instead of chip-damage emitters.
const TURRET_RANGE: float = 20.0
const TURRET_DAMAGE: int = 45
const FIRE_INTERVAL: float = 0.8

## Profile presets. Keep keys stable — HUD code references them by name.
## Damage values are 3x the original tuning so static defenses can actually
## threaten an attacking squad rather than tickle it.
const PROFILES: Dictionary = {
	&"balanced":   { "damage": 45,  "fire": 0.8,  "range": 20.0, "role": &"Universal", "name": "Balanced" },
	&"anti_light": { "damage": 24,  "fire": 0.4,  "range": 18.0, "role": &"AP",        "name": "Anti-Light" },
	&"anti_heavy": { "damage": 135, "fire": 2.0,  "range": 22.0, "role": &"AP",        "name": "Anti-Heavy" },
	&"anti_air":   { "damage": 18,  "fire": 0.25, "range": 24.0, "role": &"AA",        "name": "Anti-Air" },
}

var profile: StringName = &"balanced"

var _building: Node = null
var _target: Node3D = null
var _fire_timer: float = 0.0
var _search_timer: float = 0.0


func _ready() -> void:
	_building = get_parent()
	# Apply the visual barrel matching the default profile.
	_apply_visual_profile()


func get_damage() -> int:
	return (PROFILES[profile] as Dictionary).get("damage", TURRET_DAMAGE) as int


func get_fire_interval() -> float:
	return (PROFILES[profile] as Dictionary).get("fire", FIRE_INTERVAL) as float


func get_range() -> float:
	return (PROFILES[profile] as Dictionary).get("range", TURRET_RANGE) as float


func get_role() -> StringName:
	return (PROFILES[profile] as Dictionary).get("role", &"Universal") as StringName


func get_dps() -> float:
	var fi: float = get_fire_interval()
	if fi <= 0.0:
		return 0.0
	return float(get_damage()) / fi


func set_profile(new_profile: StringName) -> void:
	if not PROFILES.has(new_profile):
		return
	profile = new_profile
	_target = null
	_fire_timer = 0.0
	_apply_visual_profile()


func _apply_visual_profile() -> void:
	if _building and _building.has_method("rebuild_turret_visual"):
		_building.rebuild_turret_visual(profile)


func _process(delta: float) -> void:
	if not _building or not _building.get("is_constructed"):
		return

	_fire_timer -= delta
	_search_timer -= delta

	# Validate target
	if _target and not _is_valid_target(_target):
		_target = null

	# Search for targets
	if not _target and _search_timer <= 0.0:
		_search_timer = SEARCH_INTERVAL
		_target = _find_nearest_enemy()

	if not _target:
		return

	# Slew the turret pivot toward the target before firing.
	_aim_at_target(delta)

	# Fire
	if _fire_timer <= 0.0:
		_fire_timer = get_fire_interval()

		# Apply power efficiency
		var efficiency: float = 1.0
		if _building.has_method("get_power_efficiency"):
			efficiency = _building.get_power_efficiency()
		_fire_timer /= maxf(efficiency, 0.1)

		var damage: int = maxi(int(float(get_damage()) * efficiency), 1)
		_target.take_damage(damage, _building as Node3D)

		# Projectile visual — uses the profile's role tag so anti-air shoots AA
		# missiles, anti-heavy spits AP shells, etc.
		var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
		if proj_script:
			var proj: Node3D = proj_script.create(
				_building.global_position + Vector3(0, 2.0, 0),
				_target.global_position,
				get_role()
			)
			get_tree().current_scene.add_child(proj)

		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_weapon_fire"):
			audio.play_weapon_fire(null, _building.global_position)


func _find_nearest_enemy() -> Node3D:
	var my_owner: int = _building.get("owner_id")
	var my_pos: Vector3 = _building.global_position
	var range_v: float = get_range()
	var nearest: Node3D = null
	var nearest_dist: float = INF
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	# AAir profile turrets (SAM Sites etc.) only target aircraft and
	# never engage ground units. Ground turrets ignore aircraft for now
	# — the AAir tag exclusivity in CombatTables already gives them 0
	# damage vs air armor, so engaging would just waste shots.
	var is_aa: bool = get_role() == &"AA" or get_role() == &"AAir" or profile == &"anti_air"

	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not node.has_method("take_damage"):
			continue
		var target_owner: int = node.get("owner_id")
		var hostile: bool = (registry.are_enemies(my_owner, target_owner)
			if registry
			else target_owner != my_owner)
		if not hostile:
			continue
		if "alive_count" in node and node.get("alive_count") <= 0:
			continue
		var target_is_air: bool = node.is_in_group("aircraft")
		if is_aa and not target_is_air:
			continue
		if not is_aa and target_is_air:
			continue
		var d: float = my_pos.distance_to(node.global_position)
		if d <= range_v and d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D

	return nearest


func _aim_at_target(delta: float) -> void:
	## Rotate the building's `turret_pivot` (created in _detail_gun_emplacement)
	## around Y to face the current target. The pivot is parented under the
	## building's VisualRoot, which itself has a slight randomized Y rotation
	## per building, so we have to subtract that parent rotation when
	## computing the local target angle — otherwise the turret aims off by the
	## same amount the building was rotated.
	var pivot: Node3D = _building.get("turret_pivot") as Node3D
	if not pivot or not is_instance_valid(pivot):
		return
	var to_target: Vector3 = _target.global_position - _building.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return
	# atan2(x, z) + PI gives the world Y rotation aligning local -Z with the
	# target.
	var target_y_world: float = atan2(to_target.x, to_target.z) + PI
	var compensation: float = 0.0
	var parent_root: Node = pivot.get_parent()
	if parent_root and parent_root is Node3D:
		compensation = (parent_root as Node3D).rotation.y
	var target_y_local: float = target_y_world - compensation
	pivot.rotation.y = lerp_angle(pivot.rotation.y, target_y_local, clampf(TURRET_TURN_SPEED * delta, 0.0, 1.0))


func _is_valid_target(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	if not target.has_method("take_damage"):
		return false
	var my_owner: int = _building.get("owner_id")
	var target_owner: int = target.get("owner_id")
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	var hostile: bool = (registry.are_enemies(my_owner, target_owner)
		if registry
		else target_owner != my_owner)
	if not hostile:
		return false
	if "alive_count" in target and target.get("alive_count") <= 0:
		return false
	var d: float = _building.global_position.distance_to(target.global_position)
	return d <= get_range()
