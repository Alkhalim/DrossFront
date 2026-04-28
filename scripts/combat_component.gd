class_name CombatComponent
extends Node
## Handles targeting, weapon firing, and damage calculation for a unit.
## Attached as a child of Unit by Unit._ready().

var _unit: Node = null  # Parent Unit — accessed via duck typing to avoid class resolution issues
var _current_target: Node3D = null
var _fire_cooldown: float = 0.0
var _secondary_cooldown: float = 0.0
var _search_timer: float = 0.0

const SEARCH_INTERVAL: float = 0.5

## Explicit attack target set by player command.
var forced_target: Node3D = null

## Attack-move destination. Vector3.INF = not attack-moving.
var attack_move_target: Vector3 = Vector3.INF


func _ready() -> void:
	_unit = get_parent()


func _physics_process(delta: float) -> void:
	if not _unit or not _unit.get("stats"):
		return
	var alive: int = _unit.get("alive_count")
	if alive <= 0:
		return

	_fire_cooldown -= delta
	_secondary_cooldown -= delta
	_search_timer -= delta

	var unit_has_move_order: bool = _unit.get("has_move_order") as bool

	# Use forced target if set, otherwise auto-acquire
	if forced_target and _is_valid_target(forced_target):
		_current_target = forced_target
	elif _current_target and not _is_valid_target(_current_target):
		_current_target = null

	# Don't auto-acquire targets while executing a move order
	if not _current_target and not unit_has_move_order and _search_timer <= 0.0:
		_search_timer = SEARCH_INTERVAL
		_current_target = _find_nearest_enemy()

	if not _current_target:
		if attack_move_target != Vector3.INF and _unit.get("move_target") == Vector3.INF:
			_unit.command_move(attack_move_target)
		return

	var dist: float = _unit.global_position.distance_to(_current_target.global_position)
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	var primary: WeaponResource = stats.primary_weapon
	var primary_range: float = CombatTables.get_range(primary.range_tier) if primary else 10.0

	if dist <= primary_range:
		# In range: only stop if we don't have an active move order
		if not unit_has_move_order:
			_unit.stop()

		_face_target()

		if primary and _fire_cooldown <= 0.0:
			_fire_weapon(primary, true)

		if stats.secondary_weapon and _secondary_cooldown <= 0.0:
			var sec_range: float = CombatTables.get_range(stats.secondary_weapon.range_tier)
			if dist <= sec_range:
				_fire_weapon(stats.secondary_weapon, false)
	else:
		# Out of range — move toward target only if explicitly attacking (not during move order)
		if forced_target and not unit_has_move_order:
			_unit.command_move(_current_target.global_position)


func set_target(target: Node3D) -> void:
	forced_target = target
	_current_target = target
	attack_move_target = Vector3.INF


func clear_target() -> void:
	forced_target = null
	_current_target = null


func command_attack_move(pos: Vector3) -> void:
	attack_move_target = pos
	forced_target = null
	_current_target = null
	_unit.command_move(pos)


## --- Target Acquisition ---

func _find_nearest_enemy() -> Node3D:
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	if not stats or not stats.primary_weapon:
		return null

	var my_owner: int = _unit.get("owner_id")
	var weapon_range: float = CombatTables.get_range(stats.primary_weapon.range_tier)
	var my_pos: Vector3 = _unit.global_position

	var nearest: Node3D = null
	var nearest_dist: float = INF

	# Check enemy units
	var all_units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in all_units:
		if not node.has_method("take_damage"):
			continue
		var node_owner: int = node.get("owner_id")
		if node_owner == my_owner:
			continue
		var node_alive: int = node.get("alive_count")
		if node_alive <= 0:
			continue
		var d: float = my_pos.distance_to(node.global_position)
		if d <= weapon_range and d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D

	# Check enemy buildings
	var all_buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in all_buildings:
		if not node.has_method("take_damage"):
			continue
		var node_owner: int = node.get("owner_id")
		if node_owner == my_owner:
			continue
		var d: float = my_pos.distance_to(node.global_position)
		if d <= weapon_range and d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D

	return nearest


func _is_valid_target(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	if not target.has_method("take_damage"):
		return false
	var target_owner: int = target.get("owner_id")
	var my_owner: int = _unit.get("owner_id")
	if target_owner == my_owner:
		return false
	# Check if unit is still alive
	if "alive_count" in target:
		var alive: int = target.get("alive_count")
		if alive <= 0:
			return false
	return true


func _face_target() -> void:
	if not _current_target:
		return
	var look_pos: Vector3 = _current_target.global_position
	look_pos.y = _unit.global_position.y
	if _unit.global_position.distance_to(look_pos) > 0.1:
		_unit.look_at(look_pos, Vector3.UP)


## --- Damage Calculation ---

func _fire_weapon(weapon: WeaponResource, is_primary: bool) -> void:
	if not weapon or not _current_target:
		return

	var rof: float = CombatTables.get_rof(weapon.rof_tier)
	if is_primary:
		_fire_cooldown = rof
	else:
		_secondary_cooldown = rof

	var base_damage: int = CombatTables.get_damage(weapon.damage_tier)
	var shots: int = _unit.get("alive_count")

	# Squad strength accuracy bonus
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	var accuracy: float = 1.0
	if stats.squad_strength_bonus > 0.0:
		var strength_ratio: float = _unit.get_squad_strength_ratio()
		accuracy += stats.squad_strength_bonus * strength_ratio

	# Role vs armor modifier
	var target_armor: StringName = _get_target_armor()
	var role_mod: float = CombatTables.get_role_modifier(weapon.role_tag, target_armor)

	# Armor flat reduction
	var armor_reduction: float = CombatTables.get_armor_reduction(target_armor)

	# Directional modifier
	var dir_mod: float = CombatTables.get_directional_multiplier(
		_unit.global_position, _current_target
	)

	# Final damage: base × role × direction × accuracy × (1 - armor)
	var damage_per_shot: float = float(base_damage) * role_mod * dir_mod * accuracy * (1.0 - armor_reduction)
	var total_damage: int = maxi(int(damage_per_shot * float(shots)), 1)

	_current_target.take_damage(total_damage)

	# Spawn projectile visual
	var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
	if proj_script:
		var proj: Node3D = proj_script.create(_unit.global_position, _current_target.global_position, weapon.role_tag, weapon.rof_tier)
		get_tree().current_scene.add_child(proj)

	# Muzzle flash
	_spawn_muzzle_flash()

	# Sound
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_fire"):
		audio.play_weapon_fire()


func _spawn_muzzle_flash() -> void:
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.25
	sphere.height = 0.5
	flash.mesh = sphere

	var forward: Vector3 = -_unit.global_basis.z.normalized()
	flash.global_position = _unit.global_position + forward * 0.8 + Vector3(0, 1.2, 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.2, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.1, 1.0)
	mat.emission_energy_multiplier = 6.0
	flash.set_surface_override_material(0, mat)

	get_tree().current_scene.add_child(flash)

	var timer := Timer.new()
	timer.wait_time = 0.08
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(flash.queue_free)
	flash.add_child(timer)


func _get_target_armor() -> StringName:
	if "stats" in _current_target:
		var target_stats: Resource = _current_target.get("stats")
		if target_stats and "armor_class" in target_stats:
			return target_stats.get("armor_class") as StringName
		elif target_stats and "building_id" in target_stats:
			return &"structure"
	return &"unarmored"
