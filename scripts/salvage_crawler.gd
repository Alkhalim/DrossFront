class_name SalvageCrawler
extends CharacterBody3D
## Mobile salvage harvester (v2 §1.3). Slow large unit that workers anchor to.
## Selectable + commandable like a player unit; visually presents as a low
## tracked platform with a workshop on top. The actual worker management
## is handled by an attached SalvageYardComponent so we share the proven
## spawn/harvest/return logic.

signal squad_destroyed   # for combat target validation parity with Unit

@export var stats: UnitStatResource
@export var owner_id: int = 0

const PLAYER_COLOR := Color(0.15, 0.45, 0.9, 1.0)
const ENEMY_COLOR := Color(0.85, 0.2, 0.15, 1.0)
const ARRIVE_THRESHOLD: float = 1.4
## Crawler's worker harvest radius (matches the doc's 45 world units; doc
## phrasing is "450m" but our prototype scales to ~10x smaller).
const HARVEST_RADIUS: float = 45.0
## Wrecks above this size are too tough to crush — Crawler bumps into them.
const CRUSH_MAX_WRECK_SIZE: float = 1.3
## Salvage absorbed when crushing a wreck (per doc: 25%).
const CRUSH_SALVAGE_FRAC: float = 0.25

var resource_manager: Node = null

## Combat compatibility (selection / targeting code reads these).
var alive_count: int = 1
var current_hp: int = 800
## True while the crawler has been told to move; mirrors Unit.has_move_order
## so combat / hover code that tests this still works.
var has_move_order: bool = false
## Where the unit is currently moving to. Vector3.INF means stopped.
var move_target: Vector3 = Vector3.INF
var is_selected: bool = false
var hp_bar_hovered: bool = false

var _move_speed: float = 3.0          # set from stats.speed_tier in _ready
var _nav_agent: NavigationAgent3D = null
var _yard_component: Node = null

# Visual elements that we can toggle for selection highlight.
var _hull: MeshInstance3D = null
var _team_stripe: MeshInstance3D = null
var _hp_bar: Node3D = null
var _hp_bar_fill: MeshInstance3D = null
var _hp_bar_bg: MeshInstance3D = null


func _ready() -> void:
	add_to_group("units")
	add_to_group("crawlers")
	add_to_group("owner_%d" % owner_id)

	if stats:
		current_hp = maxi(stats.hp_total, 1)
		_move_speed = _speed_from_tier(stats.speed_tier)

	# Collision: small layer 2 (units) so projectiles can hit; mask 1 ground.
	collision_layer = 2
	collision_mask = 1

	_build_visuals()
	_build_collision()
	_build_hp_bar()

	# Navigation agent for movement around obstacles.
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.name = "NavAgent"
	_nav_agent.path_desired_distance = 1.0
	_nav_agent.target_desired_distance = 1.5
	_nav_agent.avoidance_enabled = true
	_nav_agent.radius = 2.5
	_nav_agent.max_speed = _move_speed
	add_child(_nav_agent)

	# Worker management — reuse the existing SalvageYardComponent. It already
	# spawns / tracks / cleans up workers and trickles passive salvage.
	var script: GDScript = load("res://scripts/salvage_yard_component.gd") as GDScript
	if script:
		_yard_component = script.new()
		_yard_component.name = "SalvageYardComponent"
		add_child(_yard_component)


## --- Compatibility shims for code that treats us as a Building ---
## SalvageYardComponent reads these via _building.get("is_constructed") /
## .has_method("get_power_efficiency") etc.

var is_constructed: bool = true       # Crawlers are always "ready" once spawned.

func get_power_efficiency() -> float:
	if resource_manager and resource_manager.has_method("get_power_efficiency"):
		return resource_manager.get_power_efficiency()
	return 1.0


## --- Visuals ---

func _build_visuals() -> void:
	var team_color: Color = PLAYER_COLOR if owner_id == 0 else ENEMY_COLOR

	# Low rectangular hull (treads-and-platform silhouette).
	_hull = MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(3.6, 1.0, 5.0)
	_hull.mesh = hull_box
	_hull.position.y = 0.55
	var hull_mat := _make_metal(Color(0.32, 0.3, 0.27))
	_hull.set_surface_override_material(0, hull_mat)
	add_child(_hull)

	# Tread blocks on each side.
	for side: int in 2:
		var sx: float = -1.95 if side == 0 else 1.95
		var tread := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(0.5, 0.7, 5.2)
		tread.mesh = tb
		tread.position = Vector3(sx, 0.4, 0)
		var tread_mat := _make_metal(Color(0.18, 0.16, 0.14))
		tread.set_surface_override_material(0, tread_mat)
		add_child(tread)

	# Workshop / cargo box on top of the hull.
	var workshop := MeshInstance3D.new()
	var ws_box := BoxMesh.new()
	ws_box.size = Vector3(2.8, 1.0, 3.4)
	workshop.mesh = ws_box
	workshop.position = Vector3(0, 1.55, -0.4)
	workshop.set_surface_override_material(0, _make_metal(Color(0.28, 0.26, 0.22)))
	add_child(workshop)

	# Cargo crane / armature on the back top.
	var crane := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(0.16, 1.4, 0.16)
	crane.mesh = cb
	crane.position = Vector3(0, 2.2, 1.5)
	crane.set_surface_override_material(0, _make_metal(Color(0.22, 0.2, 0.16)))
	add_child(crane)

	var crane_arm := MeshInstance3D.new()
	var ca := BoxMesh.new()
	ca.size = Vector3(0.12, 0.12, 1.6)
	crane_arm.mesh = ca
	crane_arm.position = Vector3(0, 2.85, 1.0)
	crane_arm.set_surface_override_material(0, _make_metal(Color(0.22, 0.2, 0.16)))
	add_child(crane_arm)

	# Reactor lamp atop the workshop — emissive cyan, marks the Crawler at
	# a distance.
	var lamp := MeshInstance3D.new()
	var lamp_sphere := SphereMesh.new()
	lamp_sphere.radius = 0.18
	lamp_sphere.height = 0.36
	lamp.mesh = lamp_sphere
	lamp.position = Vector3(0, 2.3, -0.4)
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = Color(0.3, 0.85, 1.0)
	lamp_mat.emission_enabled = true
	lamp_mat.emission = Color(0.3, 0.85, 1.0)
	lamp_mat.emission_energy_multiplier = 2.4
	lamp.set_surface_override_material(0, lamp_mat)
	add_child(lamp)
	# Real cyan light so the reactor reads at a glance even at low res.
	var lamp_light := OmniLight3D.new()
	lamp_light.light_color = Color(0.4, 0.85, 1.0)
	lamp_light.light_energy = 1.4
	lamp_light.omni_range = 6.0
	lamp_light.position = lamp.position
	add_child(lamp_light)

	# Team-color band wrapping the hull near the bottom (matches the
	# building convention so faction identity reads consistently).
	_team_stripe = MeshInstance3D.new()
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(3.7, 0.18, 5.1)
	_team_stripe.mesh = stripe_box
	_team_stripe.position.y = 0.18
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team_color
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team_color
	stripe_mat.emission_energy_multiplier = 1.4
	_team_stripe.set_surface_override_material(0, stripe_mat)
	add_child(_team_stripe)


func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.8, 1.6, 5.2)
	col.shape = shape
	col.position.y = 0.8
	add_child(col)


func _build_hp_bar() -> void:
	_hp_bar = Node3D.new()
	_hp_bar.name = "HPBar"
	_hp_bar.position.y = 3.4
	# Background
	_hp_bar_bg = MeshInstance3D.new()
	var bg_box := BoxMesh.new()
	bg_box.size = Vector3(2.8, 0.16, 0.1)
	_hp_bar_bg.mesh = bg_box
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.7)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hp_bar_bg.set_surface_override_material(0, bg_mat)
	_hp_bar.add_child(_hp_bar_bg)

	# Fill
	_hp_bar_fill = MeshInstance3D.new()
	var fill_box := BoxMesh.new()
	fill_box.size = Vector3(1.0, 0.2, 0.12)
	_hp_bar_fill.mesh = fill_box
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.3, 0.95, 0.4, 0.9)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill_mat.emission_enabled = true
	fill_mat.emission = Color(0.2, 0.9, 0.3)
	fill_mat.emission_energy_multiplier = 0.5
	_hp_bar_fill.set_surface_override_material(0, fill_mat)
	_hp_bar.add_child(_hp_bar_fill)

	add_child(_hp_bar)
	_hp_bar.top_level = true


func _make_metal(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.65
	m.metallic = 0.4
	return m


## --- Movement ---

func command_move(target: Vector3, _clear_combat: bool = true) -> void:
	move_target = Vector3(target.x, global_position.y, target.z)
	has_move_order = true
	if _nav_agent:
		_nav_agent.target_position = move_target


func stop() -> void:
	move_target = Vector3.INF
	velocity = Vector3.ZERO
	has_move_order = false


func _physics_process(delta: float) -> void:
	# Update HP bar position / visibility.
	if _hp_bar and is_instance_valid(_hp_bar):
		var damaged: bool = false
		if stats:
			damaged = current_hp < stats.hp_total
		_hp_bar.visible = is_selected or damaged or hp_bar_hovered
		if _hp_bar.visible:
			_hp_bar.global_position = global_position + Vector3(0, 3.4, 0)
			var cam: Camera3D = get_viewport().get_camera_3d()
			if cam:
				_hp_bar.global_rotation = cam.global_rotation
			_update_hp_bar_fill()

	if move_target == Vector3.INF:
		return

	if _nav_agent and _nav_agent.is_navigation_finished():
		stop()
		return

	var next_pos: Vector3 = move_target
	if _nav_agent:
		next_pos = _nav_agent.get_next_path_position()

	var to_next := next_pos - global_position
	to_next.y = 0.0
	var dist: float = to_next.length()
	if dist < ARRIVE_THRESHOLD:
		if not _nav_agent or _nav_agent.is_navigation_finished():
			stop()
			return

	var direction: Vector3 = to_next / maxf(dist, 0.001)
	velocity = direction * _move_speed
	move_and_slide()

	# Face direction of travel.
	var face_dir: Vector3 = velocity.normalized()
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.001:
		var target_y: float = atan2(face_dir.x, face_dir.z) + PI
		rotation.y = lerp_angle(rotation.y, target_y, clampf(2.0 * delta, 0.0, 1.0))


func _update_hp_bar_fill() -> void:
	if not _hp_bar_fill or not stats:
		return
	var pct: float = float(current_hp) / float(maxi(stats.hp_total, 1))
	var bar_width: float = 2.8
	_hp_bar_fill.scale.x = maxf(pct * bar_width, 0.01)
	_hp_bar_fill.position.x = -bar_width / 2.0 * (1.0 - pct)
	var fmat: StandardMaterial3D = _hp_bar_fill.get_surface_override_material(0) as StandardMaterial3D
	if fmat:
		var r: float = 1.0 - pct
		var g: float = pct
		fmat.albedo_color = Color(r, g, 0.1, 0.9)
		fmat.emission = Color(r, g, 0.1, 1.0)


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
	squad_destroyed.emit()
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()
	# Spawn a small wreck representing the chassis.
	var wreck_script: GDScript = load("res://scripts/wreck.gd") as GDScript
	if wreck_script and stats:
		var wreck: Node3D = wreck_script.create_from_unit(stats, global_position) as Node3D
		if wreck:
			get_tree().current_scene.add_child(wreck)
	queue_free()


## --- Selection (called by SelectionManager) ---

func select() -> void:
	is_selected = true


func deselect() -> void:
	is_selected = false


## --- Helpers used by SelectionManager and combat compatibility ---

func get_combat() -> Node:
	return null  # Crawlers don't fight.


func get_builder() -> Node:
	return null  # Crawlers aren't engineers.


func _speed_from_tier(tier: StringName) -> float:
	match tier:
		&"static": return 0.0
		&"very_slow": return 3.0
		&"slow": return 5.0
		&"moderate": return 8.0
		&"fast": return 12.0
		&"very_fast": return 16.0
	return 5.0
