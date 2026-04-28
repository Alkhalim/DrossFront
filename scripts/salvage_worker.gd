class_name SalvageWorker
extends CharacterBody3D
## Autonomous salvage worker drone. Spawned by Salvage Yards.
## Cannot be player-controlled. Finds nearest wreck, harvests it, returns salvage.

enum State { IDLE, MOVING_TO_WRECK, HARVESTING, RETURNING }

const MOVE_SPEED: float = 6.0
const HARVEST_RATE: float = 15.0
const CARRY_CAPACITY: int = 30
const ARRIVE_THRESHOLD: float = 1.5

var state: State = State.IDLE
var home_yard: Node3D = null
var resource_manager: ResourceManager = null
var search_radius: float = 30.0

var _target_wreck: Wreck = null
var _carried_salvage: int = 0
var _harvest_timer: float = 0.0
var _move_target: Vector3 = Vector3.INF


func _ready() -> void:
	# Small cylinder visual
	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.25
	cyl.bottom_radius = 0.25
	cyl.height = 0.6
	mesh.mesh = cyl
	mesh.position.y = 0.3

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.45, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.45, 0.2)
	mat.emission_energy_multiplier = 0.5
	mesh.set_surface_override_material(0, mat)
	add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.25
	shape.height = 0.6
	col.shape = shape
	col.position.y = 0.3
	add_child(col)

	collision_layer = 0
	collision_mask = 1


func _physics_process(delta: float) -> void:
	match state:
		State.IDLE:
			_find_wreck()
		State.MOVING_TO_WRECK:
			_move_toward_wreck(delta)
		State.HARVESTING:
			_harvest(delta)
		State.RETURNING:
			_return_to_yard(delta)


func _find_wreck() -> void:
	var wrecks: Array[Node] = get_tree().get_nodes_in_group("wrecks")
	if wrecks.is_empty():
		return

	# Find nearest wreck within search radius of home yard
	var nearest: Wreck = null
	var nearest_dist: float = INF
	var search_origin: Vector3 = home_yard.global_position if is_instance_valid(home_yard) else global_position
	for node: Node in wrecks:
		var wreck: Wreck = node as Wreck
		if not wreck:
			continue
		var dist_to_yard: float = search_origin.distance_to(wreck.global_position)
		if dist_to_yard > search_radius:
			continue
		var dist: float = global_position.distance_to(wreck.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = wreck

	if nearest:
		_target_wreck = nearest
		_move_target = nearest.global_position
		state = State.MOVING_TO_WRECK


func _move_toward_wreck(delta: float) -> void:
	if not is_instance_valid(_target_wreck):
		state = State.IDLE
		_target_wreck = null
		return

	_move_target = _target_wreck.global_position
	if _move_toward(_move_target, delta):
		state = State.HARVESTING
		_harvest_timer = 0.0


func _harvest(delta: float) -> void:
	if not is_instance_valid(_target_wreck):
		if _carried_salvage > 0:
			state = State.RETURNING
		else:
			state = State.IDLE
		return

	_harvest_timer += delta
	if _harvest_timer >= 1.0:
		_harvest_timer -= 1.0
		var amount: int = _target_wreck.extract(int(HARVEST_RATE))
		_carried_salvage += amount

		if _carried_salvage >= CARRY_CAPACITY or not is_instance_valid(_target_wreck):
			state = State.RETURNING


func _return_to_yard(delta: float) -> void:
	if not is_instance_valid(home_yard):
		# Yard destroyed — drop salvage and go idle
		_carried_salvage = 0
		state = State.IDLE
		return

	if _move_toward(home_yard.global_position, delta):
		# Deposit salvage
		if resource_manager:
			resource_manager.add_salvage(_carried_salvage)
		_carried_salvage = 0
		state = State.IDLE


func _move_toward(target: Vector3, delta: float) -> bool:
	var to_target := target - global_position
	to_target.y = 0.0
	var distance: float = to_target.length()

	if distance < ARRIVE_THRESHOLD:
		velocity = Vector3.ZERO
		return true

	var direction := to_target / distance
	velocity = direction * MOVE_SPEED

	if direction.length_squared() > 0.001:
		look_at(global_position + direction, Vector3.UP)

	move_and_slide()
	return false
