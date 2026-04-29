class_name SalvageWorker
extends CharacterBody3D
## Autonomous salvage worker drone. Spawned by Salvage Yards.
## Cannot be player-controlled. Finds nearest wreck, harvests it, returns salvage.
## Treated as a unit by combat (owner_id, alive_count, take_damage) so enemies
## can target it.

enum State { IDLE, MOVING_TO_WRECK, HARVESTING, RETURNING }

const MOVE_SPEED: float = 6.0
const HARVEST_RATE: float = 15.0
const CARRY_CAPACITY: int = 30
const ARRIVE_THRESHOLD: float = 1.5
const MAX_HP: int = 100

const PLAYER_COLOR := Color(0.15, 0.45, 0.9, 1.0)
const ENEMY_COLOR := Color(0.85, 0.2, 0.15, 1.0)

## Combat compatibility — workers register as 1-member units so the same
## targeting / projectile / damage code that handles squads also works here.
var owner_id: int = 0
var alive_count: int = 1
var current_hp: int = MAX_HP

var state: State = State.IDLE
var home_yard: Node3D = null
var resource_manager: ResourceManager = null
var search_radius: float = 30.0

var _target_wreck: Wreck = null
var _carried_salvage: int = 0
var _harvest_timer: float = 0.0
var _move_target: Vector3 = Vector3.INF

var _cargo_mat: StandardMaterial3D = null


func _ready() -> void:
	add_to_group("units")
	add_to_group("owner_%d" % owner_id)

	# Make the worker collidable as a unit so enemies can shoot it.
	collision_layer = 2  # unit layer
	collision_mask = 1   # ground

	_build_visuals()


func _build_visuals() -> void:
	var team: Color = PLAYER_COLOR if owner_id == 0 else ENEMY_COLOR

	# --- Chassis (low main body) ---
	var chassis := MeshInstance3D.new()
	var chassis_box := BoxMesh.new()
	chassis_box.size = Vector3(0.55, 0.32, 0.7)
	chassis.mesh = chassis_box
	chassis.position.y = 0.22
	var chassis_mat := _make_metal(Color(0.42, 0.36, 0.22))
	chassis.set_surface_override_material(0, chassis_mat)
	add_child(chassis)

	# --- Track skirts on each side ---
	for side: int in 2:
		var sx: float = -0.3 if side == 0 else 0.3
		var skirt := MeshInstance3D.new()
		var skirt_box := BoxMesh.new()
		skirt_box.size = Vector3(0.08, 0.18, 0.78)
		skirt.mesh = skirt_box
		skirt.position = Vector3(sx, 0.1, 0)
		var skirt_mat := _make_metal(Color(0.18, 0.16, 0.14))
		skirt.set_surface_override_material(0, skirt_mat)
		add_child(skirt)

	# --- Cargo bin on the back top ---
	var cargo := MeshInstance3D.new()
	var cargo_box := BoxMesh.new()
	cargo_box.size = Vector3(0.4, 0.28, 0.32)
	cargo.mesh = cargo_box
	cargo.position = Vector3(0, 0.52, 0.18)
	_cargo_mat = _make_metal(Color(0.32, 0.28, 0.2))
	cargo.set_surface_override_material(0, _cargo_mat)
	add_child(cargo)

	# --- Sensor dome / cab on the front top ---
	var sensor := MeshInstance3D.new()
	var sensor_sphere := SphereMesh.new()
	sensor_sphere.radius = 0.12
	sensor_sphere.height = 0.18
	sensor.mesh = sensor_sphere
	sensor.position = Vector3(0, 0.52, -0.22)
	var sensor_mat := _make_metal(Color(0.22, 0.22, 0.24))
	sensor.set_surface_override_material(0, sensor_mat)
	add_child(sensor)

	# Sensor visor (front-facing emissive band, picks team color so player vs
	# enemy workers are easy to tell apart at a glance).
	var visor := MeshInstance3D.new()
	var visor_box := BoxMesh.new()
	visor_box.size = Vector3(0.22, 0.06, 0.02)
	visor.mesh = visor_box
	visor.position = Vector3(0, 0.55, -0.34)
	var visor_mat := StandardMaterial3D.new()
	visor_mat.albedo_color = team
	visor_mat.emission_enabled = true
	visor_mat.emission = team
	visor_mat.emission_energy_multiplier = 1.6
	visor.set_surface_override_material(0, visor_mat)
	add_child(visor)

	# --- Team color stripe wrapping the chassis ---
	var stripe := MeshInstance3D.new()
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(0.57, 0.05, 0.72)
	stripe.mesh = stripe_box
	stripe.position.y = 0.38
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team
	stripe_mat.emission_energy_multiplier = 1.2
	stripe.set_surface_override_material(0, stripe_mat)
	add_child(stripe)

	# --- Collision shape ---
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 0.7, 0.8)
	col.shape = shape
	col.position.y = 0.35
	add_child(col)


func _make_metal(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.7
	m.metallic = 0.4
	return m


## --- Combat compatibility ---

func take_damage(amount: int, _attacker: Node3D = null) -> void:
	current_hp -= amount
	if current_hp <= 0:
		current_hp = 0
		alive_count = 0
		_die()


func get_total_hp() -> int:
	return maxi(current_hp, 0)


func _die() -> void:
	# Drop carried salvage on the ground? For now just disappear.
	queue_free()


## --- AI state machine ---

func _physics_process(delta: float) -> void:
	if alive_count <= 0:
		return
	match state:
		State.IDLE:
			_find_wreck()
		State.MOVING_TO_WRECK:
			_move_toward_wreck(delta)
		State.HARVESTING:
			_harvest(delta)
		State.RETURNING:
			_return_to_yard(delta)

	# Subtle cargo-bin glow that brightens as salvage is carried.
	if _cargo_mat:
		var fill: float = float(_carried_salvage) / float(CARRY_CAPACITY)
		_cargo_mat.emission_enabled = fill > 0.0
		_cargo_mat.emission = Color(1.0, 0.7, 0.2)
		_cargo_mat.emission_energy_multiplier = fill * 1.4


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
		_carried_salvage = 0
		state = State.IDLE
		return

	if _move_toward(home_yard.global_position, delta):
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
