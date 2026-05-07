class_name SalvageWorker
extends CharacterBody3D
## Autonomous salvage worker drone. Spawned by Salvage Yards.
## Cannot be player-controlled. Finds nearest wreck, harvests it, returns salvage.
## Treated as a unit by combat (owner_id, alive_count, take_damage) so enemies
## can target it.

enum State { IDLE, MOVING_TO_WRECK, HARVESTING, RETURNING, UNSTUCKING }

const MOVE_SPEED: float = 6.0
# Halved (was 15) per balance pass — workers harvest slower so a
# wreck patch lasts longer and raids on workers feel more meaningful
# (it takes real time to recover lost gathering throughput).
const HARVEST_RATE: float = 7.5
const CARRY_CAPACITY: int = 30
const ARRIVE_THRESHOLD: float = 1.5
## Dropoff radius at the home crawler. Wider than ARRIVE_THRESHOLD
## because the crawler is a chunky chassis -- the worker can be
## physically touching the side of the crawler and still be 2.5u
## from its CENTRE, which the strict 1.5u arrive check rejected.
## Bumping to 3.0u so a worker that's bumped up against the chassis
## counts as 'docked' for the deposit. Bumped 3 → 5 because the
## salvage_yard footprint (4.5×4.5) plus the bake's agent_radius shrink
## kept the navmesh edge ~3.9u from the yard's center — gm.goto_world
## couldn't bring the worker any closer than that, so DROPOFF_RADIUS=3
## was unreachable and full workers stalled next to a yard with cargo
## undelivered. 5u clears the carved buffer for every yard size we ship.
const DROPOFF_RADIUS: float = 5.0
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
## wreck on the next tick. Pulled 4s -> 1.5s so the worker reacts
## within a single attack-window instead of grinding for half a
## production cycle; eps tightened so a worker that's drifting in
## place but not actually traversing also counts.
const STUCK_GIVE_UP_SEC: float = 1.5
const STUCK_PROGRESS_EPS: float = 0.3
var _stuck_check_pos: Vector3 = Vector3.INF
var _stuck_time: float = 0.0

## Unstuck phase -- when the stuck-detect trips, push laterally for
## a short window so the worker physically clears the obstacle
## before re-scanning. Direction is chosen perpendicular to the
## desired path (not random) so the side-step actually side-steps
## the blocker rather than sometimes pushing straight INTO it. The
## stuck wreck is remembered for a short cooldown so the very next
## scan also prefers a different target.
const UNSTUCK_PUSH_SEC: float = 1.2
const UNSTUCK_TARGET_BLACKLIST_SEC: float = 6.0
const WORKER_GRAVITY: float = 18.0
var _unstuck_dir: Vector3 = Vector3.ZERO
var _unstuck_timer: float = 0.0
var _last_intent_dir: Vector3 = Vector3.ZERO
## Alternates the side-step direction across consecutive unstuck
## attempts so a worker stuck against a corner that the first
## perpendicular pick failed to clear tries the OTHER side next.
var _unstuck_flip: int = 1
## { wreck_instance_id : float seconds_until_clear }
var _blacklisted_wrecks: Dictionary = {}

## Throttle for the IDLE -> wreck-search scan. The scan walks every
## wreck node in the scene; doing it every staggered frame
## (~20Hz) was wasteful since fresh wrecks don't appear faster
## than ~once per second. Skip ticks until the cooldown expires.
const IDLE_RESCAN_INTERVAL: float = 0.5
var _idle_rescan_cooldown: float = 0.0

## Cached emission state for the cargo bin. Writing the
## StandardMaterial3D properties every staggered frame causes
## RenderingServer to reupload the material even when nothing
## changed; only push updates when the carry ratio actually
## crossed an integer fill bucket.
var _cargo_fill_last: int = -1


func _ready() -> void:
	add_to_group("units")
	add_to_group("owner_%d" % owner_id)

	# Make the worker collidable as a unit so enemies can shoot it.
	# Mask is GROUND ONLY -- workers don't push back against other
	# units / crawlers / structures. The previous unit-mask version
	# wedged returning workers against their home Crawler and
	# friendly mechs walking past, which the dock-distance hack
	# only papered over. Letting workers phase through other units
	# costs a tiny bit of physical realism for a big reduction in
	# stuck-pathfinding cases.
	# Workers are noncombat economy agents — other units (and the player's
	# build placement check, foundation-clear, etc.) should treat them as
	# pass-through. Layer 0 = on no physics layer, so any other body's
	# mask intersects nothing here and move_and_slide on units, mechs,
	# crawlers, and engineers walks straight through workers. Targeting
	# (combat acquisition) goes through SpatialIndex/group iteration, not
	# physics queries, so enemies can still shoot at workers via that
	# path. Mask 1 keeps the worker's own ground detection intact for
	# gravity / floor snap.
	collision_layer = 0
	collision_mask = 1   # ground only
	# Floor snap so the worker stays glued to the ground across the
	# tiny lip where flat ground meets a plateau ramp foot. Without
	# the snap the body briefly loses floor contact on the
	# transition, the next physics step's gravity push pulls
	# velocity.y negative, and move_and_slide reports zero progress
	# even though there's no horizontal blocker -- which trips the
	# stuck-detect for no real reason.
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(45.0)
	up_direction = Vector3.UP

	# Round-robin half-frame stagger across worker fleet.
	# Third-frame stagger across the worker fleet. Worker state-
	# machine ticks (find/harvest/return) are coarse enough that
	# 20 Hz is invisible compared to the previous 30 Hz tick.
	_phase = int(get_instance_id() % 3)

	# PB-11: Attach GroundMovement when the new system is active.
	# Workers are solo agents (no SquadGroup). MOVE_SPEED drives
	# max_speed; accel is 6× speed (same ratio as squads). The
	# path_unreachable signal replaces the legacy custom stuck
	# detection: when GroundMovement exhausts its recovery ladder
	# the worker re-scans for a different wreck instead of grinding.
	if MovementFlags.use_new_system():
		var gm := GroundMovement.new()
		gm.name = "MovementComponent"
		gm.max_speed = MOVE_SPEED
		gm.max_accel = MOVE_SPEED * 6.0
		gm.max_turn_rate_rad_s = TAU * 0.5
		gm.agent_profile = AgentProfile.new(0.5, 0.5, 35.0, &"worker")
		add_child(gm)
		gm.path_unreachable.connect(_on_movement_path_unreachable)

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
	# Shrunk from the original 0.6x0.7x0.8 footprint so workers don't
	# log-jam at the crawler dropoff under unit-vs-unit collision.
	# The previous box was wider than the dropoff target's clearance
	# so two workers approaching from different angles got wedged.
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.42, 0.7, 0.55)
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
	# PB-11: When GroundMovement is active it owns velocity +
	# move_and_slide. This guard runs the AI tick (target selection,
	# harvest, cargo glow) but skips legacy movement code below.
	if get_node_or_null("MovementComponent") is GroundMovement:
		_per_frame_worker_tick(delta)
		return
	# Stagger heavy state-machine work to ~20 Hz; off frames just
	# skip. Worker movement is coarse-grained (drive toward target,
	# harvest, drop off) -- sampling at 20 Hz vs 60 Hz is invisible
	# during play.
	_phys_frame += 1
	if (_phys_frame % 3) != _phase:
		return
	# Off-frames skip entirely; tripling the delta on heavy frames
	# keeps cargo accumulation / movement progress at the same
	# real-time rate.
	delta *= 3.0
	# Tick down the temporary blacklist so a wreck we couldn't reach
	# 5 seconds ago becomes a candidate again once the blockade
	# (transient unit traffic, mid-pile crawler swap) clears.
	if not _blacklisted_wrecks.is_empty():
		var stale: Array = []
		for k in _blacklisted_wrecks.keys():
			_blacklisted_wrecks[k] = (_blacklisted_wrecks[k] as float) - delta
			if (_blacklisted_wrecks[k] as float) <= 0.0:
				stale.append(k)
		for k in stale:
			_blacklisted_wrecks.erase(k)

	match state:
		State.IDLE:
			# Throttle the wreck scan -- walks the entire wrecks
			# group, so doing it every staggered frame burned CPU
			# during long IDLE stretches (no reachable wreck nearby).
			_idle_rescan_cooldown -= delta
			if _idle_rescan_cooldown <= 0.0:
				_idle_rescan_cooldown = IDLE_RESCAN_INTERVAL
				_find_wreck()
		State.MOVING_TO_WRECK:
			_move_toward_wreck(delta)
		State.HARVESTING:
			_harvest(delta)
		State.RETURNING:
			_return_to_yard(delta)
		State.UNSTUCKING:
			_unstuck_step(delta)

	# Subtle cargo-bin glow that brightens as salvage is carried.
	# Only push to the material when the integer fill bucket
	# actually changed; the previous unconditional write reuploaded
	# the material every staggered frame for every worker.
	if _cargo_mat:
		var fill_bucket: int = (_carried_salvage * 16) / maxi(CARRY_CAPACITY, 1)
		if fill_bucket != _cargo_fill_last:
			_cargo_fill_last = fill_bucket
			var fill: float = float(_carried_salvage) / float(CARRY_CAPACITY)
			_cargo_mat.emission_enabled = fill > 0.0
			_cargo_mat.emission = Color(1.0, 0.7, 0.2)
			_cargo_mat.emission_energy_multiplier = fill * 1.4


## PB-11: AI tick for GroundMovement path. Handles target selection,
## harvest, deposit and cargo glow — everything except velocity /
## move_and_slide, which GroundMovement owns.
## Runs at full physics rate (no frame-stagger) because the
## arrive-check in _move_toward_wreck_new must see the position
## updated each frame to fire cleanly.
func _per_frame_worker_tick(delta: float) -> void:
	# Blacklist cooldown — same as legacy path.
	if not _blacklisted_wrecks.is_empty():
		var stale: Array = []
		for k in _blacklisted_wrecks.keys():
			_blacklisted_wrecks[k] = (_blacklisted_wrecks[k] as float) - delta
			if (_blacklisted_wrecks[k] as float) <= 0.0:
				stale.append(k)
		for k in stale:
			_blacklisted_wrecks.erase(k)

	match state:
		State.IDLE:
			_idle_rescan_cooldown -= delta
			if _idle_rescan_cooldown <= 0.0:
				_idle_rescan_cooldown = IDLE_RESCAN_INTERVAL
				_find_wreck_new()
		State.MOVING_TO_WRECK:
			_move_toward_wreck_new(delta)
		State.HARVESTING:
			_harvest(delta)
		State.RETURNING:
			_return_to_yard_new(delta)
		# UNSTUCKING state is not used in the new path;
		# GroundMovement handles stuck recovery internally.

	# Cargo-bin glow (unchanged).
	if _cargo_mat:
		var fill_bucket: int = (_carried_salvage * 16) / maxi(CARRY_CAPACITY, 1)
		if fill_bucket != _cargo_fill_last:
			_cargo_fill_last = fill_bucket
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
		# Skip wrecks we recently failed to reach. Cooldown lapses on
		# its own (see _physics_process) so a transient blockade
		# clears.
		if _blacklisted_wrecks.has(wreck.get_instance_id()):
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

	# Move toward the crawler. The worker docks (deposits) the moment
	# its centre falls within DROPOFF_RADIUS of the crawler's centre,
	# even if _move_toward's strict ARRIVE_THRESHOLD hasn't fired yet
	# -- the crawler chassis is wide enough that the worker can be
	# physically touching the side without the arrive check passing.
	var arrived: bool = _move_toward(home_yard.global_position, delta)
	var docked: bool = arrived
	if not docked:
		var d: float = global_position.distance_to(home_yard.global_position)
		docked = d < DROPOFF_RADIUS
	if docked:
		if resource_manager:
			resource_manager.add_salvage(_carried_salvage)
			if _carried_microchips > 0 and resource_manager.has_method("add_microchips"):
				resource_manager.add_microchips(_carried_microchips)
		# Stamp the home yard with this delivery so the AI's
		# idle-yard reaper can detect dead-investment yards
		# (no salvage / chips delivered for >2.5min) and demolish
		# them before they keep draining power.
		if is_instance_valid(home_yard) and (_carried_salvage > 0 or _carried_microchips > 0):
			home_yard.set_meta("last_delivery_msec", Time.get_ticks_msec())
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
	velocity.x = direction.x * MOVE_SPEED
	velocity.z = direction.z * MOVE_SPEED
	# Gravity push so workers settle on slopes instead of floating
	# against ramp lips. Without this the body's collider could
	# catch on the tiny lip where a flat ground tile meets a
	# plateau ramp and report zero progress -- the stuck-detect
	# would fire repeatedly.
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= WORKER_GRAVITY * delta
	# Remember where we WANTED to go so the unstuck side-step picks
	# a perpendicular axis to the actual desired path instead of
	# rolling random.
	_last_intent_dir = direction

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
				# Stuck. Blacklist the current wreck for a few seconds
				# so the next IDLE scan picks something else, then
				# enter UNSTUCKING which physically pushes the worker
				# laterally for UNSTUCK_PUSH_SEC seconds before it
				# tries again. Without the lateral push the worker
				# would just re-target the second-nearest wreck and
				# re-grind into the same wall.
				if is_instance_valid(_target_wreck):
					_blacklisted_wrecks[_target_wreck.get_instance_id()] = UNSTUCK_TARGET_BLACKLIST_SEC
				_target_wreck = null
				_move_target = Vector3.INF
				_enter_unstuck()
				return false
			# Made progress over the window — restart the sample.
			_stuck_check_pos = global_position
			_stuck_time = 0.0
	return false


func _enter_unstuck() -> void:
	## Side-step perpendicular to the desired path instead of rolling
	## random. The flip alternates each invocation so a worker stuck
	## against a corner that the first perpendicular pick failed to
	## clear tries the OTHER side on the next stuck-trip. Falls
	## back to a random direction when the intent is unknown
	## (fresh worker, no prior _move_toward call).
	var fwd: Vector3 = _last_intent_dir
	if fwd.length_squared() < 0.01:
		var ang: float = randf() * TAU
		_unstuck_dir = Vector3(cos(ang), 0.0, sin(ang))
	else:
		var perp: Vector3 = Vector3(-fwd.z, 0.0, fwd.x) * float(_unstuck_flip)
		_unstuck_dir = perp.normalized()
		_unstuck_flip = -_unstuck_flip
	_unstuck_timer = UNSTUCK_PUSH_SEC
	state = State.UNSTUCKING
	_stuck_time = 0.0
	_stuck_check_pos = Vector3.INF


func _unstuck_step(delta: float) -> void:
	## Push laterally in _unstuck_dir for UNSTUCK_PUSH_SEC seconds;
	## then return to IDLE so the next tick re-scans for a reachable
	## wreck (now that we've cleared the obstacle and the previous
	## target is briefly blacklisted).
	_unstuck_timer -= delta
	velocity.x = _unstuck_dir.x * MOVE_SPEED * 0.7
	velocity.z = _unstuck_dir.z * MOVE_SPEED * 0.7
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= WORKER_GRAVITY * delta
	if _unstuck_dir.length_squared() > 0.001:
		look_at(global_position + _unstuck_dir, Vector3.UP)
	move_and_slide()
	if _unstuck_timer <= 0.0:
		state = State.IDLE
		velocity = Vector3.ZERO


## --- PB-11: New-system variants of the AI helper methods ---
## These mirror the legacy helpers but route destination updates
## through GroundMovement.goto_world instead of direct velocity
## writes. The legacy helpers (_find_wreck, _move_toward, etc.)
## remain unchanged so the legacy path is always available.

func _find_wreck_new() -> void:
	## Same candidate-search logic as _find_wreck; routes the
	## destination through GroundMovement when a wreck is found.
	var wrecks: Array[Node] = get_tree().get_nodes_in_group("wrecks")
	if wrecks.is_empty():
		return

	var nearest: Wreck = null
	var nearest_dist: float = INF
	var search_origin: Vector3 = home_yard.global_position if is_instance_valid(home_yard) else global_position
	for node: Node in wrecks:
		var wreck: Wreck = node as Wreck
		if not wreck:
			continue
		if _blacklisted_wrecks.has(wreck.get_instance_id()):
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
		var mc: Node = get_node_or_null("MovementComponent")
		if mc != null and mc is GroundMovement:
			(mc as GroundMovement).goto_world(_move_target)
		return
	# No wreck in range — walk home if we've drifted.
	if is_instance_valid(home_yard):
		var d_home: float = global_position.distance_to(home_yard.global_position)
		if d_home > 2.5:
			state = State.RETURNING
			var mc: Node = get_node_or_null("MovementComponent")
			if mc != null and mc is GroundMovement:
				(mc as GroundMovement).goto_world(home_yard.global_position)


func _move_toward_wreck_new(delta: float) -> void:
	## Arrive-check for MOVING_TO_WRECK under GroundMovement.
	## GroundMovement drives velocity; we only watch distance to
	## detect arrival or wreck-disappearance.
	if not is_instance_valid(_target_wreck):
		state = State.IDLE
		_target_wreck = null
		var mc: Node = get_node_or_null("MovementComponent")
		if mc != null and mc is GroundMovement:
			(mc as GroundMovement).clear_target()
		return

	# Keep destination fresh in case the wreck drifts (shouldn't
	# normally happen, but guards against floating wrecks).
	var dest: Vector3 = _target_wreck.global_position
	if dest.distance_squared_to(_move_target) > 0.25:
		_move_target = dest
		var mc: Node = get_node_or_null("MovementComponent")
		if mc != null and mc is GroundMovement:
			(mc as GroundMovement).goto_world(_move_target)

	var dist: float = global_position.distance_to(dest)
	# Use the same ARRIVE_THRESHOLD as the legacy path.
	if dist < ARRIVE_THRESHOLD:
		state = State.HARVESTING
		_harvest_timer = 0.0
		var mc: Node = get_node_or_null("MovementComponent")
		if mc != null and mc is GroundMovement:
			(mc as GroundMovement).clear_target()


func _return_to_yard_new(delta: float) -> void:
	## Return-and-deposit leg under GroundMovement.
	if not is_instance_valid(home_yard):
		_carried_salvage = 0
		_carried_microchips = 0
		state = State.IDLE
		return

	# Drive toward home. Update destination every tick in case the
	# Crawler (home_yard) has moved.
	var dest: Vector3 = home_yard.global_position
	if dest.distance_squared_to(_move_target) > 0.25:
		_move_target = dest
		var mc: Node = get_node_or_null("MovementComponent")
		if mc != null and mc is GroundMovement:
			(mc as GroundMovement).goto_world(dest)

	# Deposit when within DROPOFF_RADIUS (same logic as legacy).
	var d: float = global_position.distance_to(dest)
	if d < DROPOFF_RADIUS:
		if resource_manager:
			resource_manager.add_salvage(_carried_salvage)
			if _carried_microchips > 0 and resource_manager.has_method("add_microchips"):
				resource_manager.add_microchips(_carried_microchips)
		if is_instance_valid(home_yard) and (_carried_salvage > 0 or _carried_microchips > 0):
			home_yard.set_meta("last_delivery_msec", Time.get_ticks_msec())
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
					1.6, 1.4, 1.5,
				)
			if _carried_microchips > 0:
				FloatingNumber.spawn(
					get_tree().current_scene,
					drop_pos + Vector3(0.0, 0.5, 0.0),
					"+%d M" % _carried_microchips,
					FloatingNumber.COLOR_MICROCHIPS,
					1.6, 1.4, 1.5,
				)
		_carried_salvage = 0
		_carried_microchips = 0
		state = State.IDLE
		var mc: Node = get_node_or_null("MovementComponent")
		if mc != null and mc is GroundMovement:
			(mc as GroundMovement).clear_target()


## Called when GroundMovement gives up on the current target
## (Plan B: stuck-recovery Level 2 exhausted). Worker re-picks
## a different salvage target rather than grinding indefinitely.
## Replaces the legacy custom stuck detection for the new path.
func _on_movement_path_unreachable(_reason: int) -> void:
	# Blacklist the wreck we were trying to reach so the next
	# _find_wreck_new scan skips it for a few seconds.
	if is_instance_valid(_target_wreck):
		_blacklisted_wrecks[_target_wreck.get_instance_id()] = UNSTUCK_TARGET_BLACKLIST_SEC
	_target_wreck = null
	_move_target = Vector3.INF
	state = State.IDLE
