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

const PLAYER_COLOR := Color(0.08, 0.25, 0.85, 1.0)
const ENEMY_COLOR := Color(0.80, 0.10, 0.10, 1.0)

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

## Half-frame stagger phase. Salvage workers don't need 60Hz updates —
## their state-machine ticks (find/harvest/return) are coarse-grained
## enough that 30Hz is invisible. Spreading workers across alternating
## physics frames halves their per-frame cost at high worker counts.
var _phys_frame: int = 0
var _phase: int = 0

var _cargo_mat: StandardMaterial3D = null
## Microchips picked up from a satellite-pile harvest tick. Carried
## back home alongside salvage and deposited in the same drop.
var _carried_microchips: int = 0

## Stuck detection — workers don't path with NavigationAgent3D, just
## push toward the target with move_and_slide. When something blocks
## the line they grind in place forever, especially against tightly-
## packed AI building walls. _stuck_pos remembers where progress last
## stalled; when that lasts past STUCK_GIVE_UP_SEC the worker drops
## the current target and goes IDLE so it can reacquire a different
## wreck on the next tick.
const STUCK_GIVE_UP_SEC: float = 4.0
const STUCK_PROGRESS_EPS: float = 0.6
var _stuck_check_pos: Vector3 = Vector3.INF
var _stuck_time: float = 0.0


func _ready() -> void:
	add_to_group("units")
	add_to_group("owner_%d" % owner_id)

	# Make the worker collidable as a unit so enemies can shoot it.
	collision_layer = 2  # unit layer
	collision_mask = 1   # ground

	# Round-robin half-frame stagger across worker fleet.
	_phase = int(get_instance_id() & 1)

	_build_visuals()


func _build_visuals() -> void:
	# Use the registry's perspective coloring so 2v2 ally workers read
	# as ALLY (green) instead of falling through to ENEMY (red). Owner
	# 0 = self (blue), other team-0 owners = ally (green), team-1
	# owners = enemy (red), team-2 = neutral (amber). When the registry
	# isn't loaded yet (very early init) we fall back to the v1
	# self-vs-enemy binary.
	var team: Color
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry if get_tree() and get_tree().current_scene else null
	if registry:
		team = registry.get_perspective_color(owner_id)
	else:
		team = PLAYER_COLOR if owner_id == 0 else ENEMY_COLOR

	if _faction_id() == 1:
		_build_visuals_sable(team)
	else:
		_build_visuals_anvil(team)

	# --- Collision shape (shared) ---
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 0.7, 0.8)
	col.shape = shape
	col.position.y = 0.35
	add_child(col)


func _faction_id() -> int:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if not settings:
		return 0
	if owner_id == 0:
		return settings.get("player_faction") as int
	return settings.get("enemy_faction") as int


func _build_visuals_anvil(team: Color) -> void:
	# Anvil drone — boxy industrial scrap-hauler. Keeps its previous
	# silhouette but the wrap-around team stripe is replaced with two
	# slim edge slivers so the team colour reads at the side without
	# painting the chassis.
	var chassis := MeshInstance3D.new()
	var chassis_box := BoxMesh.new()
	chassis_box.size = Vector3(0.55, 0.32, 0.7)
	chassis.mesh = chassis_box
	chassis.position.y = 0.22
	var chassis_mat := _make_metal(Color(0.42, 0.36, 0.22))
	chassis.set_surface_override_material(0, chassis_mat)
	add_child(chassis)

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

	var cargo := MeshInstance3D.new()
	var cargo_box := BoxMesh.new()
	cargo_box.size = Vector3(0.4, 0.28, 0.32)
	cargo.mesh = cargo_box
	cargo.position = Vector3(0, 0.52, 0.18)
	_cargo_mat = _make_metal(Color(0.32, 0.28, 0.2))
	cargo.set_surface_override_material(0, _cargo_mat)
	add_child(cargo)

	var sensor := MeshInstance3D.new()
	var sensor_sphere := SphereMesh.new()
	sensor_sphere.radius = 0.12
	sensor_sphere.height = 0.18
	sensor.mesh = sensor_sphere
	sensor.position = Vector3(0, 0.52, -0.22)
	var sensor_mat := _make_metal(Color(0.22, 0.22, 0.24))
	sensor.set_surface_override_material(0, sensor_mat)
	add_child(sensor)

	# Slim warm-amber visor for Anvil — not the team colour.
	var visor := MeshInstance3D.new()
	var visor_box := BoxMesh.new()
	visor_box.size = Vector3(0.22, 0.06, 0.02)
	visor.mesh = visor_box
	visor.position = Vector3(0, 0.55, -0.34)
	var visor_mat := StandardMaterial3D.new()
	visor_mat.albedo_color = Color(1.0, 0.55, 0.20, 1.0)
	visor_mat.emission_enabled = true
	visor_mat.emission = Color(1.0, 0.55, 0.20, 1.0)
	visor_mat.emission_energy_multiplier = 1.6
	visor.set_surface_override_material(0, visor_mat)
	add_child(visor)

	# Team-colour edge slivers — slim emissive strips on each side
	# replacing the wrap-around band. Keeps team identity without
	# dominating the chassis.
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team
	stripe_mat.emission_energy_multiplier = 1.4
	for side: int in 2:
		var sliver := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.04, 0.14, 0.50)
		sliver.mesh = sb
		var sx: float = -0.30 if side == 0 else 0.30
		sliver.position = Vector3(sx, 0.32, 0.0)
		sliver.set_surface_override_material(0, stripe_mat)
		add_child(sliver)


func _build_visuals_sable(team: Color) -> void:
	# Sable drone — sleek hover-skiff variant. Lower flat chassis,
	# faceted prow up front, twin antigrav vents underneath instead
	# of treads, slim violet sensor strip across the front, and two
	# small team-colour edge slivers for ownership.
	const SABLE_VIOLET := Color(0.78, 0.35, 1.0, 1.0)
	# Main chassis — wider + flatter than Anvil, matte black.
	var chassis := MeshInstance3D.new()
	var chassis_box := BoxMesh.new()
	chassis_box.size = Vector3(0.62, 0.22, 0.78)
	chassis.mesh = chassis_box
	chassis.position.y = 0.30
	var chassis_mat := _make_metal(Color(0.10, 0.10, 0.14))
	chassis.set_surface_override_material(0, chassis_mat)
	add_child(chassis)

	# Forward chevron prow — two angled slabs at the front.
	for side: int in 2:
		var sx: float = -0.16 if side == 0 else 0.16
		var prow := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.30, 0.20, 0.30)
		prow.mesh = pb
		prow.position = Vector3(sx, 0.30, -0.40)
		prow.rotation.y = deg_to_rad(20.0 if side == 0 else -20.0)
		prow.set_surface_override_material(0, _make_metal(Color(0.08, 0.08, 0.12)))
		add_child(prow)

	# Cargo bin — same role as Anvil's, slightly leaner.
	var cargo := MeshInstance3D.new()
	var cargo_box := BoxMesh.new()
	cargo_box.size = Vector3(0.40, 0.22, 0.30)
	cargo.mesh = cargo_box
	cargo.position = Vector3(0, 0.52, 0.18)
	_cargo_mat = _make_metal(Color(0.14, 0.12, 0.18))
	cargo.set_surface_override_material(0, _cargo_mat)
	add_child(cargo)

	# Twin antigrav vent pads underneath — short cylinders sunk into
	# the chassis bottom. Replaces the Anvil tread skirts.
	for side: int in 2:
		var sx: float = -0.20 if side == 0 else 0.20
		var vent := MeshInstance3D.new()
		var vc := CylinderMesh.new()
		vc.top_radius = 0.14
		vc.bottom_radius = 0.16
		vc.height = 0.10
		vc.radial_segments = 12
		vent.mesh = vc
		vent.position = Vector3(sx, 0.10, 0.0)
		var vent_mat := StandardMaterial3D.new()
		vent_mat.albedo_color = Color(0.04, 0.04, 0.06, 1.0)
		vent_mat.emission_enabled = true
		vent_mat.emission = SABLE_VIOLET
		vent_mat.emission_energy_multiplier = 1.0
		vent.set_surface_override_material(0, vent_mat)
		add_child(vent)

	# Violet visor — thin emissive sensor slit across the prow.
	var visor_mat := StandardMaterial3D.new()
	visor_mat.albedo_color = SABLE_VIOLET
	visor_mat.emission_enabled = true
	visor_mat.emission = SABLE_VIOLET
	visor_mat.emission_energy_multiplier = 2.2
	visor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var visor := MeshInstance3D.new()
	var visor_box := BoxMesh.new()
	visor_box.size = Vector3(0.40, 0.05, 0.04)
	visor.mesh = visor_box
	visor.position = Vector3(0, 0.36, -0.42)
	visor.set_surface_override_material(0, visor_mat)
	add_child(visor)

	# Two slim team-colour edge slivers, one per side, placed past
	# the chassis silhouette so team identity peeks at the edges.
	var team_mat := StandardMaterial3D.new()
	team_mat.albedo_color = team
	team_mat.emission_enabled = true
	team_mat.emission = team
	team_mat.emission_energy_multiplier = 1.4
	for side: int in 2:
		var sliver := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.04, 0.10, 0.55)
		sliver.mesh = sb
		var sx: float = -0.34 if side == 0 else 0.34
		sliver.position = Vector3(sx, 0.34, 0.0)
		sliver.set_surface_override_material(0, team_mat)
		add_child(sliver)


func _make_metal(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	# Match the unit / building / Crawler chassis grime overlay so the
	# salvage worker reads coherently with the rest of the war-mech fleet
	# instead of as a smoothly-shaded oddball.
	m.albedo_texture = SharedTextures.get_metal_wear_texture()
	m.uv1_offset = Vector3(randf(), randf(), 0.0)
	m.uv1_scale = Vector3(1.6, 1.6, 1.0)
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


func drop_carried_salvage() -> int:
	## Returns the carried amount and clears it. Used by the Crawler when it
	## relocates mid-trip — the worker drops the load where it stands and
	## becomes idle, ready to dispatch from the Crawler's new position.
	var amt: int = _carried_salvage
	if amt <= 0:
		return 0
	_carried_salvage = 0
	state = State.IDLE
	_target_wreck = null
	return amt


## --- AI state machine ---

func _physics_process(delta: float) -> void:
	if alive_count <= 0:
		return
	# Stagger heavy state-machine work to ~30Hz; off frames just skip.
	# Worker movement is coarse-grained (drive toward target, harvest,
	# drop off) — sampling at 30Hz vs 60Hz is invisible during play.
	_phys_frame += 1
	if (_phys_frame & 1) != _phase:
		return
	# Off-frames skip work entirely; the halved delta means timers tick
	# half as often, but we double the effective delta on heavy frames
	# so cargo accumulation / movement progress remain at the same rate.
	delta *= 2.0
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
		return
	# No wreck in range — if we've drifted away from the home yard /
	# Crawler (e.g. last wreck was far out and we're still standing
	# there), walk back to home so we're idle in a useful position. The
	# RETURNING state arrives at home_yard, then drops back to IDLE and
	# re-scans on the next tick.
	if is_instance_valid(home_yard):
		var d_home: float = global_position.distance_to(home_yard.global_position)
		if d_home > 2.5:
			state = State.RETURNING


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
		# Satellite piles drop their chip payload on the first tick
		# that actually pulled salvage. claim_microchips clears the
		# wreck-side counter so subsequent ticks don't double-count
		# even if the wreck survives.
		if amount > 0 and is_instance_valid(_target_wreck) and _target_wreck.has_method("claim_microchips"):
			_carried_microchips += _target_wreck.claim_microchips()

		if _carried_salvage >= CARRY_CAPACITY or not is_instance_valid(_target_wreck):
			state = State.RETURNING


func _return_to_yard(delta: float) -> void:
	if not is_instance_valid(home_yard):
		_carried_salvage = 0
		_carried_microchips = 0
		state = State.IDLE
		return

	if _move_toward(home_yard.global_position, delta):
		if resource_manager:
			resource_manager.add_salvage(_carried_salvage)
			if _carried_microchips > 0 and resource_manager.has_method("add_microchips"):
				resource_manager.add_microchips(_carried_microchips)
		# Floating "+N S" / "+N M" readouts above the home yard
		# every time a worker drops cargo. Player-side only so
		# enemy economy doesn't broadcast through visible yards.
		if owner_id == 0 and is_instance_valid(home_yard):
			var drop_pos: Vector3 = home_yard.global_position + Vector3(
				randf_range(-0.6, 0.6), 1.6, randf_range(-0.6, 0.6)
			)
			if _carried_salvage > 0:
				FloatingNumber.spawn(
					get_tree().current_scene,
					drop_pos,
					"+%d S" % _carried_salvage,
					FloatingNumber.COLOR_SALVAGE,
					1.6,
					1.4,
					1.5,
				)
			if _carried_microchips > 0:
				FloatingNumber.spawn(
					get_tree().current_scene,
					drop_pos + Vector3(0.0, 0.5, 0.0),
					"+%d M" % _carried_microchips,
					FloatingNumber.COLOR_MICROCHIPS,
					1.6,
					1.4,
					1.5,
				)
		_carried_salvage = 0
		_carried_microchips = 0
		state = State.IDLE


func _move_toward(target: Vector3, delta: float) -> bool:
	var to_target := target - global_position
	to_target.y = 0.0
	var distance: float = to_target.length()

	if distance < ARRIVE_THRESHOLD:
		velocity = Vector3.ZERO
		_stuck_time = 0.0
		_stuck_check_pos = Vector3.INF
		return true

	var direction := to_target / distance
	velocity = direction * MOVE_SPEED

	if direction.length_squared() > 0.001:
		look_at(global_position + direction, Vector3.UP)

	move_and_slide()

	# Stuck-progress check — sample our position; if it has not moved
	# more than STUCK_PROGRESS_EPS over STUCK_GIVE_UP_SEC seconds,
	# bail on the current move target so the state machine can pick
	# a different wreck rather than grinding forever against a
	# building wall the AI base packed in too tight.
	if _stuck_check_pos == Vector3.INF:
		_stuck_check_pos = global_position
		_stuck_time = 0.0
	else:
		_stuck_time += delta
		if _stuck_time >= STUCK_GIVE_UP_SEC:
			var progress: float = global_position.distance_to(_stuck_check_pos)
			if progress < STUCK_PROGRESS_EPS:
				# Drop the current move; reset state to IDLE so the
				# next tick re-scans for a reachable wreck. Returning
				# true here makes the caller treat the move as
				# "arrived enough"; the state-machine branches that
				# call _move_toward all check post-arrival action
				# (HARVEST / RETURN), so just transitioning to IDLE
				# from outside is cleanest.
				state = State.IDLE
				_target_wreck = null
				_move_target = Vector3.INF
				velocity = Vector3.ZERO
				_stuck_time = 0.0
				_stuck_check_pos = Vector3.INF
				return false
			# Made progress over the window — restart the sample.
			_stuck_check_pos = global_position
			_stuck_time = 0.0
	return false
