class_name TurretComponent
extends Node
## Attaches to a Building. Auto-attacks enemies in range.

const TURRET_RANGE: float = 20.0
const TURRET_DAMAGE: int = 15
const FIRE_INTERVAL: float = 0.8
const SEARCH_INTERVAL: float = 0.5

var _building: Node = null
var _target: Node3D = null
var _fire_timer: float = 0.0
var _search_timer: float = 0.0


func _ready() -> void:
	_building = get_parent()


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

	# Fire
	if _fire_timer <= 0.0:
		_fire_timer = FIRE_INTERVAL

		# Apply power efficiency
		var efficiency: float = 1.0
		if _building.has_method("get_power_efficiency"):
			efficiency = _building.get_power_efficiency()
		_fire_timer /= maxf(efficiency, 0.1)

		var damage: int = maxi(int(float(TURRET_DAMAGE) * efficiency), 1)
		_target.take_damage(damage)

		# Projectile visual
		var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
		if proj_script:
			var proj: Node3D = proj_script.create(
				_building.global_position + Vector3(0, 2.0, 0),
				_target.global_position,
				&"AP"
			)
			get_tree().current_scene.add_child(proj)

		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_weapon_fire"):
			audio.play_weapon_fire()


func _find_nearest_enemy() -> Node3D:
	var my_owner: int = _building.get("owner_id")
	var my_pos: Vector3 = _building.global_position
	var nearest: Node3D = null
	var nearest_dist: float = INF

	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not node.has_method("take_damage"):
			continue
		if node.get("owner_id") == my_owner:
			continue
		if "alive_count" in node and node.get("alive_count") <= 0:
			continue
		var d: float = my_pos.distance_to(node.global_position)
		if d <= TURRET_RANGE and d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D

	return nearest


func _is_valid_target(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	if not target.has_method("take_damage"):
		return false
	if target.get("owner_id") == _building.get("owner_id"):
		return false
	if "alive_count" in target and target.get("alive_count") <= 0:
		return false
	var d: float = _building.global_position.distance_to(target.global_position)
	return d <= TURRET_RANGE
