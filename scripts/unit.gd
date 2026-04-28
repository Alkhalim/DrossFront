class_name Unit
extends CharacterBody3D
## Base unit controller. Handles movement, HP, death, and component hosting.

signal arrived
signal selected
signal deselected
signal squad_destroyed
signal member_died(index: int)

## The stat resource defining this unit's properties.
@export var stats: UnitStatResource

## Owner: 0 = player, 1+ = AI players.
@export var owner_id: int = 0

## Movement speed mapped from tier.
const SPEED_MAP: Dictionary = {
	&"static": 0.0,
	&"very_slow": 3.0,
	&"slow": 5.0,
	&"moderate": 8.0,
	&"fast": 12.0,
	&"very_fast": 16.0,
}

const ARRIVE_THRESHOLD: float = 0.5

var move_target: Vector3 = Vector3.INF
var is_selected: bool = false
var _move_speed: float = 8.0

## Per-member HP. Length = squad_size, each entry = that member's current HP.
var member_hp: Array[int] = []
var alive_count: int = 0

## Damage flash state.
var _flash_timer: float = 0.0
const FLASH_DURATION: float = 0.12

## Stuck detection for obstacle avoidance.
var _stuck_timer: float = 0.0
var _last_position: Vector3 = Vector3.ZERO

## Placeholder shape/size per unit class.
const CLASS_SHAPES: Dictionary = {
	&"engineer": { "type": "cylinder", "radius": 0.4, "height": 1.2, "color": Color(0.45, 0.42, 0.3) },
	&"light": { "type": "box", "size": Vector3(0.7, 1.8, 0.7), "color": Color(0.3, 0.32, 0.38) },
	&"medium": { "type": "box", "size": Vector3(1.2, 2.0, 1.2), "color": Color(0.35, 0.35, 0.38) },
	&"heavy": { "type": "box", "size": Vector3(1.6, 2.4, 1.6), "color": Color(0.4, 0.38, 0.35) },
	&"apex": { "type": "box", "size": Vector3(2.0, 3.0, 2.0), "color": Color(0.45, 0.4, 0.35) },
}


func _ready() -> void:
	add_to_group("units")
	add_to_group("owner_%d" % owner_id)
	if stats:
		_move_speed = SPEED_MAP.get(stats.speed_tier, 8.0)
		_init_hp()
		_apply_placeholder_shape()
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


## --- Movement ---

func command_move(target: Vector3) -> void:
	move_target = target
	move_target.y = global_position.y


func stop() -> void:
	move_target = Vector3.INF
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	# Damage flash countdown
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_restore_material()

	if move_target == Vector3.INF:
		return

	var to_target := move_target - global_position
	to_target.y = 0.0
	var distance := to_target.length()

	if distance < ARRIVE_THRESHOLD:
		stop()
		_stuck_timer = 0.0
		arrived.emit()
		return

	var direction := to_target / distance
	velocity = direction * _move_speed

	move_and_slide()

	# Stuck detection — steer perpendicular to go around obstacles
	var moved := global_position.distance_to(_last_position)
	if moved < _move_speed * delta * 0.1 and distance > ARRIVE_THRESHOLD * 2.0:
		_stuck_timer += delta
		if _stuck_timer > 0.15:
			var perp := Vector3(-direction.z, 0, direction.x)
			velocity = perp * _move_speed
			move_and_slide()
	else:
		_stuck_timer = 0.0

	_last_position = global_position

	# Face movement direction
	var face_dir := velocity.normalized()
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.001:
		look_at(global_position + face_dir, Vector3.UP)


## --- HP and Damage ---

func take_damage(amount: int) -> void:
	if alive_count <= 0:
		return

	# Distribute damage to first alive member
	for i: int in member_hp.size():
		if member_hp[i] > 0:
			member_hp[i] -= amount
			if member_hp[i] <= 0:
				member_hp[i] = 0
				alive_count -= 1
				member_died.emit(i)
				if alive_count <= 0:
					_die()
					return
			break

	_flash_timer = FLASH_DURATION
	_apply_damage_flash()


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

	# Spawn wreck
	var wreck: Node = Wreck.create_from_unit(stats, global_position)
	get_tree().current_scene.add_child(wreck)

	# Free population for player units
	if owner_id == 0:
		var resource_mgr: Node = get_tree().current_scene.get_node_or_null("ResourceManager")
		if resource_mgr and resource_mgr.has_method("remove_population"):
			resource_mgr.remove_population(stats.population)

	# Death sound
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_unit_destroyed"):
		audio.play_unit_destroyed()

	queue_free()


func _apply_damage_flash() -> void:
	var mesh_node: MeshInstance3D = get_node_or_null("MeshInstance3D") as MeshInstance3D
	if not mesh_node:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.2, 0.1, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.1, 0.0, 1.0)
	mat.emission_energy_multiplier = 2.0
	mesh_node.set_surface_override_material(0, mat)


func _restore_material() -> void:
	_apply_placeholder_shape()


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


## --- Visuals ---

func _apply_placeholder_shape() -> void:
	if not stats:
		return
	var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])

	var mesh_node: MeshInstance3D = get_node_or_null("MeshInstance3D") as MeshInstance3D
	var col_node: CollisionShape3D = get_node_or_null("CollisionShape3D") as CollisionShape3D
	var ring_node: MeshInstance3D = get_node_or_null("SelectionRing") as MeshInstance3D

	if not mesh_node:
		return

	var mat := StandardMaterial3D.new()
	var base_color: Color = shape_data["color"] as Color
	# Tint enemy units red
	if owner_id != 0:
		base_color = Color(
			minf(base_color.r + 0.25, 1.0),
			maxf(base_color.g - 0.15, 0.0),
			maxf(base_color.b - 0.15, 0.0),
			1.0
		)
	mat.albedo_color = base_color
	mat.roughness = 0.8

	var shape_type: String = shape_data["type"]
	if shape_type == "cylinder":
		var radius: float = shape_data["radius"]
		var height: float = shape_data["height"]

		var cyl := CylinderMesh.new()
		cyl.top_radius = radius
		cyl.bottom_radius = radius
		cyl.height = height
		mesh_node.mesh = cyl
		mesh_node.set_surface_override_material(0, mat)
		mesh_node.position.y = height / 2.0

		if col_node:
			var col_shape := CylinderShape3D.new()
			col_shape.radius = radius
			col_shape.height = height
			col_node.shape = col_shape
			col_node.position.y = height / 2.0

		if ring_node:
			var ring_scale: float = radius * 2.5
			ring_node.scale = Vector3(ring_scale, 1.0, ring_scale)
	else:
		var box_size: Vector3 = shape_data["size"] as Vector3

		var box := BoxMesh.new()
		box.size = box_size
		mesh_node.mesh = box
		mesh_node.set_surface_override_material(0, mat)
		mesh_node.position.y = box_size.y / 2.0

		if col_node:
			var col_shape := BoxShape3D.new()
			col_shape.size = box_size
			col_node.shape = col_shape
			col_node.position.y = box_size.y / 2.0

		if ring_node:
			var ring_scale: float = box_size.x * 1.2
			ring_node.scale = Vector3(ring_scale, 1.0, ring_scale)


## --- Component Accessors ---

func get_builder() -> Node:
	return get_node_or_null("BuilderComponent")


func get_combat() -> Node:
	return get_node_or_null("CombatComponent")


func _update_selection_visual(show: bool) -> void:
	var ring: Node3D = get_node_or_null("SelectionRing") as Node3D
	if ring:
		ring.visible = show
