class_name Unit
extends CharacterBody3D
## Base unit controller. Represents a full squad with individual member visuals.

signal arrived
signal selected
signal deselected
signal squad_destroyed
signal member_died(index: int)

@export var stats: UnitStatResource
@export var owner_id: int = 0

const SPEED_MAP: Dictionary = {
	&"static": 0.0, &"very_slow": 3.0, &"slow": 5.0,
	&"moderate": 8.0, &"fast": 12.0, &"very_fast": 16.0,
}
const ARRIVE_THRESHOLD: float = 0.5

var move_target: Vector3 = Vector3.INF
var is_selected: bool = false
var has_move_order: bool = false
var _move_speed: float = 8.0

## Per-member HP.
var member_hp: Array[int] = []
var alive_count: int = 0

## Visual state.
var _member_meshes: Array[Node3D] = []
var _color_shell: MeshInstance3D = null
var _hp_bar: Node3D = null
var _hp_bar_fill: MeshInstance3D = null
var _hp_bar_bg: MeshInstance3D = null
var _anim_time: float = 0.0

## Damage flash.
var _flash_timer: float = 0.0
const FLASH_DURATION: float = 0.12

## Navigation.
var _nav_agent: NavigationAgent3D = null
var _stuck_timer: float = 0.0
var _last_position: Vector3 = Vector3.ZERO

## Player colors.
const PLAYER_COLOR := Color(0.15, 0.45, 0.9, 1.0)
const ENEMY_COLOR := Color(0.85, 0.2, 0.15, 1.0)

## Formation offsets per squad size (positions relative to center).
const FORMATIONS: Dictionary = {
	1: [Vector3.ZERO],
	2: [Vector3(-0.6, 0, 0), Vector3(0.6, 0, 0)],
	3: [Vector3(-0.8, 0, 0.4), Vector3(0.8, 0, 0.4), Vector3(0, 0, -0.6)],
	4: [Vector3(-0.7, 0, 0.5), Vector3(0.7, 0, 0.5), Vector3(-0.7, 0, -0.5), Vector3(0.7, 0, -0.5)],
}

## Unit shape definitions — more distinct silhouettes.
const CLASS_SHAPES: Dictionary = {
	&"engineer": { "body": Vector3(0.35, 0.8, 0.35), "head": Vector3(0.25, 0.3, 0.25), "color": Color(0.45, 0.42, 0.3) },
	&"light": { "body": Vector3(0.3, 1.2, 0.3), "head": Vector3(0.2, 0.4, 0.2), "color": Color(0.3, 0.32, 0.38) },
	&"medium": { "body": Vector3(0.5, 1.2, 0.5), "head": Vector3(0.35, 0.5, 0.35), "color": Color(0.35, 0.35, 0.38) },
	&"heavy": { "body": Vector3(0.7, 1.4, 0.7), "head": Vector3(0.5, 0.6, 0.5), "color": Color(0.4, 0.38, 0.35) },
	&"apex": { "body": Vector3(0.9, 1.8, 0.9), "head": Vector3(0.6, 0.7, 0.6), "color": Color(0.45, 0.4, 0.35) },
}


func _ready() -> void:
	add_to_group("units")
	add_to_group("owner_%d" % owner_id)
	# Navigation agent for pathfinding
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.name = "NavAgent"
	_nav_agent.path_desired_distance = 0.8
	_nav_agent.target_desired_distance = 1.2
	_nav_agent.avoidance_enabled = true
	_nav_agent.radius = 1.5
	_nav_agent.neighbor_distance = 10.0
	_nav_agent.max_neighbors = 8
	_nav_agent.max_speed = 16.0
	add_child(_nav_agent)

	if stats:
		_move_speed = SPEED_MAP.get(stats.speed_tier, 8.0)
		_init_hp()
		_build_squad_visuals()
		_build_hp_bar()
		if stats.can_build:
			var builder := BuilderComponent.new()
			builder.name = "BuilderComponent"
			add_child(builder)
		if stats.primary_weapon:
			var combat_script: GDScript = load("res://scripts/combat_component.gd") as GDScript
			var combat: Node = combat_script.new()
			combat.name = "CombatComponent"
			add_child(combat)


func _init_hp() -> void:
	alive_count = stats.squad_size
	member_hp.clear()
	for i: int in stats.squad_size:
		member_hp.append(stats.hp_per_unit)


## --- Squad Visuals ---

func _build_squad_visuals() -> void:
	# Remove old visuals
	for mesh: Node3D in _member_meshes:
		if is_instance_valid(mesh):
			mesh.queue_free()
	_member_meshes.clear()
	if _color_shell and is_instance_valid(_color_shell):
		_color_shell.queue_free()
		_color_shell = null

	# Remove the scene's default mesh/collision (we replace them)
	var old_mesh: Node = get_node_or_null("MeshInstance3D")
	if old_mesh:
		old_mesh.queue_free()

	var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	var body_size: Vector3 = shape_data["body"] as Vector3
	var head_size: Vector3 = shape_data["head"] as Vector3
	var base_color: Color = shape_data["color"] as Color
	var team_color: Color = PLAYER_COLOR if owner_id == 0 else ENEMY_COLOR

	# Get formation positions
	var squad: int = stats.squad_size
	var positions: Array = FORMATIONS.get(squad, FORMATIONS[1])

	for i: int in squad:
		var member := Node3D.new()
		member.name = "Member_%d" % i
		var offset: Vector3 = positions[i] as Vector3
		member.position = offset

		# Body mesh
		var body_mesh_inst := MeshInstance3D.new()
		var body_box := BoxMesh.new()
		body_box.size = body_size
		body_mesh_inst.mesh = body_box
		body_mesh_inst.position.y = body_size.y / 2.0
		var body_mat := StandardMaterial3D.new()
		body_mat.albedo_color = base_color
		body_mat.roughness = 0.8
		body_mesh_inst.set_surface_override_material(0, body_mat)
		member.add_child(body_mesh_inst)

		# Head/turret mesh
		var head_mesh_inst := MeshInstance3D.new()
		var head_box := BoxMesh.new()
		head_box.size = head_size
		head_mesh_inst.mesh = head_box
		head_mesh_inst.position.y = body_size.y + head_size.y / 2.0
		var head_mat := StandardMaterial3D.new()
		head_mat.albedo_color = Color(base_color.r + 0.05, base_color.g + 0.05, base_color.b + 0.05, 1.0)
		head_mat.roughness = 0.7
		head_mesh_inst.set_surface_override_material(0, head_mat)
		member.add_child(head_mesh_inst)

		# Team color stripe on body
		var stripe := MeshInstance3D.new()
		var stripe_box := BoxMesh.new()
		stripe_box.size = Vector3(body_size.x + 0.02, body_size.y * 0.2, body_size.z + 0.02)
		stripe.mesh = stripe_box
		stripe.position.y = body_size.y * 0.7
		var stripe_mat := StandardMaterial3D.new()
		stripe_mat.albedo_color = team_color
		stripe_mat.emission_enabled = true
		stripe_mat.emission = team_color
		stripe_mat.emission_energy_multiplier = 1.2
		stripe.set_surface_override_material(0, stripe_mat)
		member.add_child(stripe)

		add_child(member)
		_member_meshes.append(member)

	# Update collision shape to cover the squad footprint
	var col_node: CollisionShape3D = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_node:
		var col_shape := BoxShape3D.new()
		var squad_width: float = maxf(body_size.x * 2.0, 1.5)
		if squad > 2:
			squad_width = 2.5
		col_shape.size = Vector3(squad_width, body_size.y + head_size.y, squad_width)
		col_node.shape = col_shape
		col_node.position.y = (body_size.y + head_size.y) / 2.0


func _build_hp_bar() -> void:
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()

	var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	var body_size: Vector3 = shape_data["body"] as Vector3
	var head_size: Vector3 = shape_data["head"] as Vector3
	var bar_y: float = body_size.y + head_size.y + 0.5

	_hp_bar = Node3D.new()
	_hp_bar.name = "HPBar"
	_hp_bar.position.y = bar_y

	# Background
	_hp_bar_bg = MeshInstance3D.new()
	var bg_box := BoxMesh.new()
	bg_box.size = Vector3(2.0, 0.12, 0.08)
	_hp_bar_bg.mesh = bg_box
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.7)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hp_bar_bg.set_surface_override_material(0, bg_mat)
	_hp_bar.add_child(_hp_bar_bg)

	# Fill
	_hp_bar_fill = MeshInstance3D.new()
	var fill_box := BoxMesh.new()
	fill_box.size = Vector3(1.0, 0.15, 0.1)
	_hp_bar_fill.mesh = fill_box
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.1, 0.9, 0.1, 0.9)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill_mat.emission_enabled = true
	fill_mat.emission = Color(0.1, 0.9, 0.1, 1.0)
	fill_mat.emission_energy_multiplier = 0.5
	_hp_bar_fill.set_surface_override_material(0, fill_mat)
	_hp_bar.add_child(_hp_bar_fill)

	# Top-level so it doesn't inherit unit rotation (prevents jitter)
	add_child(_hp_bar)
	_hp_bar.top_level = true
	_update_hp_bar()


func _update_hp_bar() -> void:
	if not _hp_bar_fill:
		return
	var pct: float = float(get_total_hp()) / float(maxi(stats.hp_total, 1))
	var bar_width: float = 2.0

	# Scale fill from left
	_hp_bar_fill.scale.x = maxf(pct * bar_width, 0.01)
	_hp_bar_fill.position.x = -bar_width / 2.0 * (1.0 - pct)

	# Color shift green → yellow → red
	var fill_mat: StandardMaterial3D = _hp_bar_fill.get_surface_override_material(0) as StandardMaterial3D
	if fill_mat:
		var r: float = 1.0 - pct
		var g: float = pct
		fill_mat.albedo_color = Color(r, g, 0.1, 0.9)
		fill_mat.emission = Color(r, g, 0.1, 1.0)


func _remove_member_visual(index: int) -> void:
	if index < _member_meshes.size():
		var member: Node3D = _member_meshes[index]
		if is_instance_valid(member):
			member.visible = false


## --- Movement ---

func command_move(target: Vector3) -> void:
	move_target = target
	move_target.y = global_position.y
	has_move_order = true
	if _nav_agent:
		_nav_agent.target_position = move_target
	var combat: Node = get_combat()
	if combat and combat.has_method("clear_target"):
		combat.clear_target()


func stop() -> void:
	move_target = Vector3.INF
	velocity = Vector3.ZERO
	has_move_order = false


func _physics_process(delta: float) -> void:
	# Damage flash countdown
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_restore_member_colors()

	# Walking animation
	if velocity.length_squared() > 1.0:
		_anim_time += delta * 8.0
		_apply_walk_bob()
	else:
		_anim_time = 0.0
		_reset_walk_bob()

	# Position HP bar above unit (top_level so we set global_position)
	if _hp_bar and is_instance_valid(_hp_bar):
		var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"]) if stats else CLASS_SHAPES[&"medium"]
		var bar_height: float = 2.5
		if shape_data.has("body"):
			var body: Vector3 = shape_data["body"] as Vector3
			var head: Vector3 = shape_data["head"] as Vector3
			bar_height = body.y + head.y + 0.5
		_hp_bar.global_position = global_position + Vector3(0, bar_height, 0)
		var cam: Camera3D = get_viewport().get_camera_3d()
		if cam:
			_hp_bar.global_rotation = cam.global_rotation

	if move_target == Vector3.INF:
		return

	# Use NavigationAgent for pathfinding if available
	if _nav_agent and _nav_agent.is_navigation_finished():
		has_move_order = false
		stop()
		arrived.emit()
		return

	var next_pos: Vector3
	if _nav_agent:
		next_pos = _nav_agent.get_next_path_position()
	else:
		next_pos = move_target

	var to_next := next_pos - global_position
	to_next.y = 0.0
	var distance := to_next.length()

	if distance < ARRIVE_THRESHOLD:
		if not _nav_agent or _nav_agent.is_navigation_finished():
			has_move_order = false
			stop()
			arrived.emit()
			return

	var direction := to_next / maxf(distance, 0.01)
	velocity = direction * _move_speed

	move_and_slide()

	_last_position = global_position

	var face_dir := velocity.normalized()
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.001:
		look_at(global_position + face_dir, Vector3.UP)


func _apply_walk_bob() -> void:
	for i: int in _member_meshes.size():
		var member: Node3D = _member_meshes[i]
		if not is_instance_valid(member) or not member.visible:
			continue
		# Each member bobs slightly offset
		var phase: float = _anim_time + float(i) * 1.5
		member.position.y = sin(phase) * 0.08


func _reset_walk_bob() -> void:
	for i: int in _member_meshes.size():
		var member: Node3D = _member_meshes[i]
		if is_instance_valid(member):
			member.position.y = 0.0


## --- HP and Damage ---

func take_damage(amount: int) -> void:
	if alive_count <= 0:
		return

	for i: int in member_hp.size():
		if member_hp[i] > 0:
			member_hp[i] -= amount
			if member_hp[i] <= 0:
				member_hp[i] = 0
				alive_count -= 1
				_remove_member_visual(i)
				member_died.emit(i)
				if alive_count <= 0:
					_die()
					return
			break

	_flash_timer = FLASH_DURATION
	_apply_damage_flash()
	_update_hp_bar()


func get_total_hp() -> int:
	var total: int = 0
	for hp: int in member_hp:
		total += hp
	return total


func get_squad_strength_ratio() -> float:
	if not stats or stats.squad_size <= 0:
		return 0.0
	return float(alive_count) / float(stats.squad_size)


func _die() -> void:
	squad_destroyed.emit()
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()
	var wreck: Node = Wreck.create_from_unit(stats, global_position)
	get_tree().current_scene.add_child(wreck)

	if owner_id == 0:
		var resource_mgr: Node = get_tree().current_scene.get_node_or_null("ResourceManager")
		if resource_mgr and resource_mgr.has_method("remove_population"):
			resource_mgr.remove_population(stats.population)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_unit_destroyed"):
		audio.play_unit_destroyed()

	queue_free()


func _apply_damage_flash() -> void:
	for member: Node3D in _member_meshes:
		if not is_instance_valid(member) or not member.visible:
			continue
		for child: Node in member.get_children():
			var mesh_inst: MeshInstance3D = child as MeshInstance3D
			if not mesh_inst:
				continue
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.9, 0.2, 0.1, 1.0)
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.1, 0.0, 1.0)
			mat.emission_energy_multiplier = 2.0
			mesh_inst.set_surface_override_material(0, mat)


func _restore_member_colors() -> void:
	# Rebuild visuals to restore colors
	_build_squad_visuals()


## --- Selection ---

func select() -> void:
	if is_selected:
		return
	is_selected = true
	selected.emit()
	_update_selection_visual(true)


func deselect() -> void:
	if not is_selected:
		return
	is_selected = false
	deselected.emit()
	_update_selection_visual(false)


func _update_selection_visual(show: bool) -> void:
	var ring: Node3D = get_node_or_null("SelectionRing") as Node3D
	if ring:
		ring.visible = show


## --- Component Accessors ---

func get_builder() -> Node:
	return get_node_or_null("BuilderComponent")


func get_combat() -> Node:
	return get_node_or_null("CombatComponent")


func get_member_positions() -> Array[Vector3]:
	var positions: Array[Vector3] = []
	for i: int in _member_meshes.size():
		var member: Node3D = _member_meshes[i]
		if is_instance_valid(member) and member.visible:
			positions.append(member.global_position)
	return positions
