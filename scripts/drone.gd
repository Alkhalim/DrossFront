class_name Drone
extends Node3D
## Detached carrier-launched drone. Flies out from its parent
## carrier, fires one shot at a target, then flies back to the
## carrier and despawns. Dies with the carrier -- the moment the
## carrier becomes invalid, all of its drones queue_free.

const SPEED: float = 14.0
const DOCK_RADIUS: float = 2.0     # how close to the carrier counts as "docked"
const ATTACK_RADIUS: float = 1.6   # how close to the target counts as "in firing position"
const HOVER_TIME: float = 0.5      # seconds spent firing before peeling off

enum State { LAUNCHING, ATTACKING, RETURNING }

## Wired by the spawning combat path before the drone enters the
## scene tree. All four are required for the drone to behave; the
## drone bails (queue_free) if any is missing at _ready.
var carrier: Node3D = null
var target: Node3D = null
var damage: int = 25
var role_tag: StringName = &"Universal"
var owner_id: int = 0

var _state: int = State.LAUNCHING
var _hover_timer: float = 0.0
var _fired: bool = false


func _ready() -> void:
	if not carrier or not is_instance_valid(carrier):
		queue_free()
		return
	_build_visual()


func _build_visual() -> void:
	# Small drone body -- compact silhouette so a salvo of 2-3 reads
	# as separate craft converging on the target.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := BoxMesh.new()
	bm.size = Vector3(0.30, 0.16, 0.50)
	body.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.18, 0.18, 0.22)
	bmat.metallic = 0.5
	bmat.roughness = 0.4
	body.set_surface_override_material(0, bmat)
	add_child(body)
	# Twin stub wings.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var wing := MeshInstance3D.new()
		wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wm := BoxMesh.new()
		wm.size = Vector3(0.30, 0.04, 0.20)
		wing.mesh = wm
		wing.position = Vector3(sx * 0.28, 0.0, 0.04)
		wing.set_surface_override_material(0, bmat)
		add_child(wing)
	# Glowing thruster at the back -- emissive sphere, faction-tinted
	# hot orange so it reads against most backgrounds.
	var thruster := MeshInstance3D.new()
	thruster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ts := SphereMesh.new()
	ts.radius = 0.07
	ts.height = 0.14
	thruster.mesh = ts
	thruster.position = Vector3(0.0, 0.0, -0.30)
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(1.0, 0.55, 0.18)
	tm.emission_enabled = true
	tm.emission = Color(1.0, 0.55, 0.18)
	tm.emission_energy_multiplier = 2.0
	thruster.set_surface_override_material(0, tm)
	add_child(thruster)


func _process(delta: float) -> void:
	# Carrier dies -- drone dies. No half-life of orphaned drones
	# floating around the map.
	if not carrier or not is_instance_valid(carrier):
		queue_free()
		return

	match _state:
		State.LAUNCHING:
			# If the target died mid-flight, peel off and head home.
			if not target or not is_instance_valid(target):
				_state = State.RETURNING
				return
			if "alive_count" in target and (target.get("alive_count") as int) <= 0:
				_state = State.RETURNING
				return
			var aim: Vector3 = target.global_position
			_fly_toward(aim, delta)
			if global_position.distance_to(aim) < ATTACK_RADIUS:
				_state = State.ATTACKING
				_hover_timer = HOVER_TIME
				_fire_at_target()
		State.ATTACKING:
			# Brief hover at firing position so the engagement reads
			# as 'drone arrived, fired, peeling off'.
			_hover_timer -= delta
			if _hover_timer <= 0.0:
				_state = State.RETURNING
		State.RETURNING:
			var dock: Vector3 = carrier.global_position
			_fly_toward(dock, delta)
			if global_position.distance_to(dock) < DOCK_RADIUS:
				queue_free()


func _fly_toward(target_pos: Vector3, delta: float) -> void:
	var to_target: Vector3 = target_pos - global_position
	var dist: float = to_target.length()
	if dist < 0.001:
		return
	var step: float = SPEED * delta
	if step >= dist:
		global_position = target_pos
	else:
		global_position += to_target.normalized() * step
	# Face flight direction so the silhouette + thruster glow line
	# up with motion.
	look_at(target_pos, Vector3.UP)


func _fire_at_target() -> void:
	# Damage delivered now so the drone's payload lands consistently
	# even if the target dies next frame. Visual is a small fast
	# projectile from the drone toward the target so the player sees
	# the shot leave the drone.
	if not target or not is_instance_valid(target):
		return
	if _fired:
		return
	_fired = true
	if target.has_method("take_damage"):
		target.take_damage(damage, carrier)
	var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
	if not proj_script:
		return
	var proj: Node3D = proj_script.create(global_position, target.global_position, role_tag, &"fast")
	get_tree().current_scene.add_child(proj)
