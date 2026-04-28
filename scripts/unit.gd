class_name Unit
extends CharacterBody3D
## Base unit controller. Handles movement toward a target position.
## Composed with Selectable, etc. via child nodes.

signal arrived
signal selected
signal deselected

## The stat resource defining this unit's properties.
@export var stats: UnitStatResource

## Movement speed mapped from tier. Tunable later.
const SPEED_MAP: Dictionary = {
	&"static": 0.0,
	&"very_slow": 3.0,
	&"slow": 5.0,
	&"moderate": 8.0,
	&"fast": 12.0,
	&"very_fast": 16.0,
}

## Minimum distance to target before considering arrived.
const ARRIVE_THRESHOLD: float = 0.5

var move_target: Vector3 = Vector3.INF
var is_selected: bool = false
var _move_speed: float = 8.0


## Placeholder shape/size per unit class for visual differentiation.
const CLASS_SHAPES: Dictionary = {
	&"engineer": { "type": "cylinder", "radius": 0.4, "height": 1.2, "color": Color(0.45, 0.42, 0.3) },
	&"light": { "type": "box", "size": Vector3(0.7, 1.8, 0.7), "color": Color(0.3, 0.32, 0.38) },
	&"medium": { "type": "box", "size": Vector3(1.2, 2.0, 1.2), "color": Color(0.35, 0.35, 0.38) },
	&"heavy": { "type": "box", "size": Vector3(1.6, 2.4, 1.6), "color": Color(0.4, 0.38, 0.35) },
	&"apex": { "type": "box", "size": Vector3(2.0, 3.0, 2.0), "color": Color(0.45, 0.4, 0.35) },
}


func _ready() -> void:
	add_to_group("units")
	if stats:
		_move_speed = SPEED_MAP.get(stats.speed_tier, 8.0)
		_apply_placeholder_shape()
		if stats.can_build:
			var builder := BuilderComponent.new()
			builder.name = "BuilderComponent"
			add_child(builder)


func command_move(target: Vector3) -> void:
	move_target = target
	move_target.y = global_position.y


func stop() -> void:
	move_target = Vector3.INF
	velocity = Vector3.ZERO


var _stuck_timer: float = 0.0
var _last_position: Vector3 = Vector3.ZERO


func _physics_process(delta: float) -> void:
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

	# Detect if stuck against a wall — if barely moved, steer around
	var moved := global_position.distance_to(_last_position)
	if moved < _move_speed * delta * 0.1 and distance > ARRIVE_THRESHOLD * 2.0:
		_stuck_timer += delta
		if _stuck_timer > 0.15:
			# Steer perpendicular to try to go around the obstacle
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


func _apply_placeholder_shape() -> void:
	var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])

	var mesh_node: MeshInstance3D = $MeshInstance3D as MeshInstance3D
	var col_node: CollisionShape3D = $CollisionShape3D as CollisionShape3D
	var ring_node: MeshInstance3D = $SelectionRing as MeshInstance3D

	var mat := StandardMaterial3D.new()
	mat.albedo_color = shape_data["color"] as Color
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

		var col_shape := CylinderShape3D.new()
		col_shape.radius = radius
		col_shape.height = height
		col_node.shape = col_shape
		col_node.position.y = height / 2.0

		# Scale selection ring to match
		var ring_scale: float = radius * 2.5
		ring_node.scale = Vector3(ring_scale, 1.0, ring_scale)
	else:
		var box_size: Vector3 = shape_data["size"] as Vector3

		var box := BoxMesh.new()
		box.size = box_size
		mesh_node.mesh = box
		mesh_node.set_surface_override_material(0, mat)
		mesh_node.position.y = box_size.y / 2.0

		var col_shape := BoxShape3D.new()
		col_shape.size = box_size
		col_node.shape = col_shape
		col_node.position.y = box_size.y / 2.0

		# Scale selection ring to match unit width
		var ring_scale: float = box_size.x * 1.2
		ring_node.scale = Vector3(ring_scale, 1.0, ring_scale)


func get_builder() -> BuilderComponent:
	return get_node_or_null("BuilderComponent") as BuilderComponent


func _update_selection_visual(show: bool) -> void:
	var ring: Node3D = get_node_or_null("SelectionRing") as Node3D
	if ring:
		ring.visible = show
