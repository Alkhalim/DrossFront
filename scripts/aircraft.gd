class_name Aircraft
extends Node3D
## Aircraft base — V3 §"Pillar 3". Flies at a fixed altitude above the
## ground, ignores ground obstacles, can only be targeted by weapons
## with the AAir role tag (or weapons with non-zero effectiveness vs
## light_air / heavy_air armor classes).
##
## Movement is direct lerp-toward-target (no NavigationAgent3D). Aircraft
## share the unit-group "units" + "owner_%d" for combat targeting + the
## existing PlayerRegistry hostility logic. The CombatComponent is
## attached as a child so AAir-tagged shooters can find them through
## the same auto-target loop ground units use.

const ARRIVE_THRESHOLD: float = 1.5

@export var stats: UnitStatResource

## Combat compatibility — exposes the same surface as `Unit` so the
## targeting / damage / squad-strength code already in CombatComponent
## works without special-casing aircraft.
var owner_id: int = 1
var alive_count: int = 1
var current_hp: int = 0
var member_hp: PackedInt32Array = PackedInt32Array()

## V3 stealth — same model as Unit. Wraith starts concealed; the
## targeting code checks stealth_revealed before auto-acquiring.
var stealth_revealed: bool = true
var _stealth_damage_timer: float = 0.0
var _stealth_check_throttle: float = 0.0
const STEALTH_CHECK_INTERVAL: float = 0.4
var has_move_order: bool = false
var move_target: Vector3 = Vector3.INF
var is_holding_position: bool = false
var move_queue: Array[Vector3] = []
var velocity: Vector3 = Vector3.ZERO

## Return-to-base state. When stats.rtb_after_attack is set, the
## aircraft locks into this mode the moment it discharges its primary
## weapon and stays locked until it touches down at a friendly HQ.
## During RTB:
##   - command_move + selection input are ignored (handled by the
##     selection manager checking is_returning_to_base())
##   - combat target is cleared so it doesn't re-engage en route
##   - the aircraft flies a single straight path to the nearest HQ
##     and "rearms" there (resets the flag) on arrival.
## Cleared automatically when the aircraft is within RTB_ARRIVAL_RADIUS
## of its target HQ.
var _returning_to_base: bool = false
var _rtb_target_pos: Vector3 = Vector3.INF
const RTB_ARRIVAL_RADIUS: float = 6.0

var _combat: Node = null
var _hp_bar: Node3D = null
## Per-drone roots for swarm aircraft (Sputnik, Fang). Each entry is a
## Node3D that holds one drone's mesh; we bob them slightly via
## `_process` so the swarm reads as alive instead of a frozen formation.
var _drone_meshes: Array[Node3D] = []
var _drone_anim_time: float = 0.0

## Whole-aircraft altitude hover. Even single-body aircraft (gunships,
## interceptors) bob slightly so they read as airborne rather than glued
## to a fixed altitude. Each aircraft gets its own phase so the squadron
## doesn't bob in unison.
const ALTITUDE_BOB_AMP: float = 0.45
const ALTITUDE_BOB_FREQ: float = 1.1
var _bob_phase: float = 0.0
var _altitude_anim_time: float = 0.0
var _smoke_trail_timer: float = 0.0
var _anvil_rotor: Node3D = null
var _anvil_tail_rotor: Node3D = null

## Ground shadow blob — flat dark ellipse on the ground beneath the
## aircraft. Sells the "airborne" read at any camera angle (the directional
## light's real shadow can be lost when the aircraft is over rough terrain
## or off-screen edges). Updated per-frame to track the aircraft's XZ.
var _shadow_blob: MeshInstance3D = null

## Selection state. Mirrors the `is_selected` flag on `Unit` so the same
## SelectionManager codepath can flip it. `_select_ring` is a small green
## ground ring marker below the aircraft, mirroring the unit selection
## indicator visual style.
var is_selected: bool = false
var _select_ring: MeshInstance3D = null

## Active-ability cooldown. Mirrors the field on Unit so the same
## HUD ability button + autocast hooks work for aircraft.
var _ability_cd_remaining: float = 0.0


func _ready() -> void:
	add_to_group("units")
	add_to_group("aircraft")
	add_to_group("owner_%d" % owner_id)
	# Independent hover phase so a flight of aircraft bobs out of
	# sync — synchronised motion reads as glitching, not living.
	_bob_phase = randf() * TAU
	if stats:
		current_hp = stats.hp_total
		# `alive_count` tracks how many drones / craft are still up.
		# Defaulted to 1 at the field decl, but a swarm needs the full
		# squad size so per-member damage and per-drone fire both work.
		alive_count = stats.squad_size
		member_hp = PackedInt32Array()
		for i: int in stats.squad_size:
			member_hp.append(stats.hp_per_unit)
		# Spawn at the configured altitude — the spawn position from
		# Building._spawn_unit lands on the ground; we lift to the
		# unit's flight_altitude immediately on enter-tree so the
		# aircraft is in its proper airspace.
		global_position.y = stats.flight_altitude

	# Attach a CombatComponent — same component the ground units use.
	# It auto-acquires hostile targets via the units / buildings groups
	# and routes damage through the standard tag/armor system.
	var combat_script: GDScript = load("res://scripts/combat_component.gd") as GDScript
	if combat_script:
		_combat = combat_script.new()
		_combat.name = "CombatComponent"
		add_child(_combat)

	_build_visuals()
	_build_shadow_blob()
	_build_click_collider()
	_build_hp_bar()

	# Stealth-capable aircraft (Wraith) start concealed; the
	# proximity check below will reveal them when an enemy detector
	# closes the distance, OR when they take damage.
	if stats and stats.is_stealth_capable:
		stealth_revealed = false
		_apply_stealth_visual(true)

	# Feature-flagged AircraftMovement (PB-6). When enabled the new
	# steering system owns XZ position; the legacy _process lerp is
	# gated out via an early return below.
	if MovementFlags.use_new_system():
		var am := AircraftMovement.new()
		am.name = "MovementComponent"
		am.max_speed = stats.flight_speed if stats != null else 12.0
		am.max_accel = am.max_speed * 6.0
		am.max_turn_rate_rad_s = TAU * 0.7    # aircraft turn slower than ground
		am.base_altitude = stats.flight_altitude if stats != null else 12.0
		add_child(am)


## --- Shadow / selection visuals ---

func _build_shadow_blob() -> void:
	## Flat dark elliptical disc spawned at world origin and reparented to
	## the scene root, then tracked to the aircraft's XZ each frame in
	## `_process`. Reparenting (instead of being a child of the aircraft)
	## keeps the disc on the ground regardless of the aircraft's altitude
	## bob. Material is shared-style (one allocation per aircraft) — for
	## now this is fine; if the aircraft count climbs we can switch to a
	## MultiMeshInstance3D.
	# PlaneMesh (not QuadMesh) — only PlaneMesh exposes the `orientation`
	# enum that lets the disc lie flat on XZ. A QuadMesh is always
	# XY-facing and would render edge-on from a top-down RTS camera.
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.6, 2.6)
	plane.orientation = PlaneMesh.FACE_Y
	_shadow_blob = MeshInstance3D.new()
	_shadow_blob.mesh = plane
	_shadow_blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.42)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false
	mat.disable_receive_shadows = true
	_shadow_blob.material_override = mat
	# Parent to the scene root so the blob doesn't follow Y; we update it
	# from `_process` to match the aircraft's XZ.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		scene.add_child(_shadow_blob)
	else:
		add_child(_shadow_blob)


func _build_click_collider() -> void:
	## Selection raycasts use UNIT_LAYER (= 2). Aircraft are pure Node3Ds
	## with no built-in collider, so without this they're transparent to
	## raycasts. An Area3D + small CollisionShape3D on layer 2 makes them
	## clickable; the SelectionManager walks `parent` to recover the
	## Aircraft from the area's collider.
	var area := Area3D.new()
	area.name = "ClickArea"
	area.collision_layer = 2
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	# Generous selection sphere so clicks register reliably even on the
	# small Sputnik drones — gameplay readability over visual exactness.
	sphere.radius = 1.6
	col.shape = sphere
	area.add_child(col)
	add_child(area)


## Aliases matching Unit's selection API so SelectionManager's
## `unit.select()` / `unit.deselect()` calls work for aircraft too via
## duck-typing.
func select() -> void:
	set_selected(true)


func deselect() -> void:
	set_selected(false)


func _turn_toward(face_dir: Vector3, delta: float) -> void:
	## Smooth yaw toward `face_dir`. The aircraft visual is built with
	## the nose along +Z (V-formation places wingmen at -Z behind the
	## leader), so to make +Z point at the target we use
	## `atan2(face_dir.x, face_dir.z)` directly. The previous version
	## negated face_dir, which produced rotation that pointed the
	## model's BACK (-Z) at the target — units fired tail-first.
	## In Godot rotation.y semantics, atan2(x, z) sets +Z to align
	## with the (x, z) direction, which is what we want.
	##
	## Bank: roll into the turn proportional to the signed yaw error
	## so direction changes read as a real aircraft banking instead
	## of the previous flat-yaw spin. Decays back to 0 when flying
	## straight (lerp toward `bank_target` does the easing).
	if face_dir.length_squared() < 0.0001:
		# Decay bank back to level even while idle so a parked unit
		# doesn't keep its last roll forever.
		rotation.z = lerp_angle(rotation.z, 0.0, clampf(4.0 * delta, 0.0, 1.0))
		return
	var target_y: float = atan2(face_dir.x, face_dir.z)
	var turn_speed: float = 5.0  # rad/s — aircraft turn slightly slower than light mechs
	var yaw_error: float = wrapf(target_y - rotation.y, -PI, PI)
	rotation.y = lerp_angle(rotation.y, target_y, clampf(turn_speed * delta, 0.0, 1.0))
	# Bank target — sign chosen so a right-hand turn (yaw_error < 0
	# in Godot's left-handed Y convention) drops the right wing.
	# Cap at 35° so a hard 180° doesn't flip the model upside down.
	const BANK_GAIN: float = 1.4
	const BANK_MAX_RAD: float = deg_to_rad(35.0)
	var bank_target: float = clampf(yaw_error * BANK_GAIN, -BANK_MAX_RAD, BANK_MAX_RAD)
	rotation.z = lerp_angle(rotation.z, bank_target, clampf(6.0 * delta, 0.0, 1.0))


## Surface-compat wrapper — HUD's selection panel calls `get_builder` on
## whatever Node3D ends up in `_selected_units`. Aircraft don't build,
## so this accessor returns null. `get_total_hp` is already defined
## later in the file; no shim needed.
func get_builder() -> Node:
	return null


func set_selected(value: bool) -> void:
	## Toggle the selection ring marker. Called by SelectionManager — same
	## API contract as Unit's selection state.
	is_selected = value
	if value:
		if not _select_ring or not is_instance_valid(_select_ring):
			_spawn_select_ring()
	else:
		if _select_ring and is_instance_valid(_select_ring):
			_select_ring.queue_free()
			_select_ring = null


func _spawn_select_ring() -> void:
	# Thin green torus on the ground beneath the aircraft. Same color
	# as Unit's selection indicator so the two read consistently.
	var torus := TorusMesh.new()
	torus.inner_radius = 1.4
	torus.outer_radius = 1.7
	torus.ring_segments = 4
	torus.rings = 24
	_select_ring = MeshInstance3D.new()
	_select_ring.mesh = torus
	_select_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 1.0, 0.45, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 1.0, 0.45, 1.0)
	mat.emission_energy_multiplier = 1.4
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_select_ring.material_override = mat
	# Parent to scene so the ring stays on the ground while the aircraft
	# bobs. Position is updated in `_process` alongside the shadow blob.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		scene.add_child(_select_ring)
	else:
		add_child(_select_ring)


## Half-frame stagger so multiple aircraft don't all churn the
## per-frame altitude-bob / shadow / drone-bob loop on the same
## tick. The doubled delta on heavy frames keeps motion + bob
## cadence identical to the un-staggered version.
var _ac_phys_frame: int = 0


func _process(delta: float) -> void:
	if alive_count <= 0:
		return
	# Return-to-base flight check — runs every frame (cheap, just a
	# distance compare) so the moment the bomber crosses the HQ
	# arrival radius it stops + becomes selectable again.
	if _returning_to_base:
		_tick_return_to_base(delta)
	# HP-bar reposition runs every frame (cheap) so the bar tracks
	# the aircraft while moving. Bar is hidden at full HP, so the
	# only cost when undamaged is one visibility check.
	_update_hp_bar()
	# Shadow blob + selection ring follow the aircraft's XZ every
	# frame so they don't stutter when the body moves at 30 Hz
	# (via AircraftMovement.tick_movement) while the visual updates
	# below were gated to ~10 Hz by the 1-in-3 stagger. Three
	# Vector3 assignments per frame; cheap.
	# is_inside_tree() guard alongside is_instance_valid: the shadow blob
	# and selection ring are parented to the scene root (so they don't
	# inherit aircraft Y), which means they live a separate lifecycle from
	# the aircraft. During scene reloads / unit despawns there's a window
	# where the node is valid but not yet/no-longer in the tree, and
	# writing global_position then triggers Godot's "is_inside_tree() is
	# true. Returning: Transform3D()" error. 2000+ such errors per second
	# was floods the console and starves the GPU command queue.
	if _shadow_blob and is_instance_valid(_shadow_blob) and _shadow_blob.is_inside_tree():
		_shadow_blob.global_position = Vector3(global_position.x, 0.06, global_position.z)
	if _select_ring and is_instance_valid(_select_ring) and _select_ring.is_inside_tree():
		_select_ring.global_position = Vector3(global_position.x, 0.08, global_position.z)
	_ac_phys_frame += 1
	# Third-frame stagger (was half-frame) -- matches the
	# CombatComponent + SalvageWorker pattern. Off-frames still
	# get the visual updates above so motion looks smooth.
	if (_ac_phys_frame % 3) != int(get_instance_id() % 3):
		# New system owns position — skip legacy integration on off-frames too.
		if get_node_or_null("MovementComponent") is AircraftMovement:
			return
		if move_target != Vector3.INF and stats:
			global_position += velocity * delta
		return
	delta *= 3.0
	# Active-ability cooldown tick (mirrors Unit). The autocast
	# trigger lives in CombatComponent so it fires at the right
	# moment in the combat tick instead of here.
	if _ability_cd_remaining > 0.0:
		_ability_cd_remaining = maxf(0.0, _ability_cd_remaining - delta)
	# Maintain altitude — drift toward the configured flight altitude
	# even if something nudges us off it. The aircraft's whole body
	# bobs around the target altitude on a sin curve so single-body
	# craft (gunships, interceptors) read as airborne the same way the
	# swarm drones do via their per-drone bob.
	#
	# CRITICAL: this block ONLY runs on the legacy movement path. When
	# AircraftMovement is active, IT owns Y position (pulls toward
	# base_altitude every physics tick). Running this _process bob in
	# parallel made BOTH systems fight over Y at different rates: the
	# render-frame bob lerps Y toward `flight_altitude + sin(...)`,
	# the physics tick pulls Y back to base_altitude, and the result
	# is the rapid up/down oscillation the user reported (visible
	# even out of combat). With the new system the aircraft hovers
	# stably; visual bob can be re-added inside AircraftMovement
	# later if needed.
	_altitude_anim_time += delta
	var _alt_mc: Node = get_node_or_null("MovementComponent")
	var _aircraft_mc_active: bool = _alt_mc != null and _alt_mc is AircraftMovement
	if stats and not _aircraft_mc_active:
		var hover: float = sin(_altitude_anim_time * ALTITUDE_BOB_FREQ + _bob_phase) * ALTITUDE_BOB_AMP
		var target_y: float = stats.flight_altitude + hover
		global_position.y = lerp(global_position.y, target_y, clampf(delta * 4.0, 0.0, 1.0))

	# Shadow + select ring update was moved out of the heavy-tick
	# block to the top of _process so they track every frame
	# (otherwise they stuttered at 1-in-3 frames behind the body's
	# 30 Hz physics-tick movement).

	# Spin Anvil's main + tail rotors. Speed is constant — the
	# rotor reads as "engine running" all the time.
	if _anvil_rotor and is_instance_valid(_anvil_rotor):
		_anvil_rotor.rotate_y(delta * 28.0)
	if _anvil_tail_rotor and is_instance_valid(_anvil_tail_rotor):
		_anvil_tail_rotor.rotate_z(delta * 42.0)

	# V3 stealth tick (Wraith only — early-out for everything else).
	_process_stealth(delta)

	# Per-drone bob — gives swarm aircraft visual life. Each drone has
	# its own phase (set when spawned) so they don't bob in unison.
	_drone_anim_time += delta
	if not _drone_meshes.is_empty():
		for drone: Node3D in _drone_meshes:
			if not is_instance_valid(drone):
				continue
			var phase: float = drone.get_meta("bob_phase", 0.0) as float
			drone.position.y = sin(_drone_anim_time * 2.5 + phase) * 0.18
			# Subtle Z roll mimicking drone yaw correction.
			drone.rotation.z = sin(_drone_anim_time * 1.7 + phase) * 0.05

	# Patrol-orbit tick for Drone Bay defenders.
	if _patrol_around != null:
		_tick_patrol()

	# PB-6 / PF-B-B5: new movement system owns XZ position when active.
	# Visual-only work above (altitude bob, shadow, rotor spin, drone bob)
	# still runs. When AircraftMovement is present, either:
	#   - kernel_handle == 0: orchestrator drives via AircraftMovement.tick_movement
	#   - kernel_handle != 0: orchestrator drives via _apply_kernel_velocity (PF-B-B5)
	# Either way the legacy lerp below must not run. Keep it alive only for
	# flag-off mode where no MovementComponent is attached.
	var _mc_loco: Node = get_node_or_null("MovementComponent")
	if _mc_loco is AircraftMovement:
		return

	if move_target == Vector3.INF:
		velocity = Vector3.ZERO
		return

	var to_target: Vector3 = move_target - global_position
	to_target.y = 0.0
	var dist: float = to_target.length()
	if dist < ARRIVE_THRESHOLD:
		velocity = Vector3.ZERO
		# Advance the queue or signal arrival.
		if not move_queue.is_empty():
			var next_wp: Vector3 = move_queue.pop_front() as Vector3
			move_target = Vector3(next_wp.x, stats.flight_altitude if stats else global_position.y, next_wp.z)
		else:
			move_target = Vector3.INF
			has_move_order = false
		return

	var dir: Vector3 = to_target / dist
	var speed: float = stats.flight_speed if stats else 14.0
	velocity = dir * speed
	global_position += velocity * delta

	# Engine smoke trail — small periodic puff dropped behind the
	# aircraft. Routed through the central GPU particle emitter so
	# the per-puff cost is one ring-buffer write, not a fresh
	# MeshInstance3D + Tween. Throttled to once every 0.18s and only
	# when actually moving so a parked aircraft doesn't smoke.
	_smoke_trail_timer -= delta
	if _smoke_trail_timer <= 0.0 and speed > 0.5:
		_smoke_trail_timer = randf_range(0.16, 0.22)
		var trail_pos: Vector3 = global_position - dir * 1.3
		trail_pos.y -= 0.20
		var pem: Node = get_tree().current_scene.get_node_or_null("ParticleEmitterManager") if get_tree() else null
		if pem and pem.has_method("emit_smoke"):
			pem.emit_smoke(trail_pos, Vector3(0.0, 0.6, 0.0) - dir * 0.6, Color(0.25, 0.22, 0.20, 0.55))

	# Face direction of travel. Godot's `look_at` aligns -Z to the
	# target, but the aircraft V-formation places wingmen at local -Z
	# behind the leader — so the model's actual nose is along +Z.
	# Looking at a point BEHIND us flips that, putting +Z toward the
	# velocity direction. Without this fix planes flew (and fought)
	# tail-first.
	if dir.length_squared() > 0.001:
		look_at(global_position - Vector3(dir.x, 0, dir.z), Vector3.UP)


func _build_visuals() -> void:
	if not stats:
		_build_default_aircraft()
		return
	# Dispatch on the unit's display name so each aircraft type gets a
	# distinct silhouette. Drone swarms render as multiple small drones
	# in formation; gunships and interceptors render as single bodies.
	match stats.unit_name:
		"Phalanx Drone":
			_build_drone_swarm(8, _team_color(), Color(0.45, 0.42, 0.36), 0.7, true)
		"Phalanx (Shield)":
			_build_drone_swarm(8, _team_color(), Color(0.45, 0.42, 0.36), 0.7, true)
			_apply_phalanx_shield_extras()
		"Phalanx (Interceptor)":
			_build_drone_swarm(8, _team_color(), Color(0.45, 0.42, 0.36), 0.7, true)
			_apply_phalanx_interceptor_extras()
		"Fang Drone":
			_build_drone_swarm(10, _team_color(), Color(0.10, 0.11, 0.13), 0.55, false)
		"Fang (Hunter)":
			_build_drone_swarm(10, _team_color(), Color(0.10, 0.11, 0.13), 0.55, false)
			_apply_fang_hunter_extras()
		"Fang (Harasser)":
			_build_drone_swarm(10, _team_color(), Color(0.10, 0.11, 0.13), 0.55, false)
			_apply_fang_harasser_extras()
		"Hammerhead Gunship", "Hammerhead (Bomber)", "Hammerhead (Escort)":
			# All Hammerhead variants share the gunship hull build so
			# the branches read as the same airframe with different
			# loadouts -- not three different aircraft. Variant-
			# specific accents (bomb bay tint / escort fairings) get
			# layered on inside _build_hammerhead.
			_build_hammerhead()
		"Switchblade Interceptor", "Switchblade (Dogfighter)", "Switchblade (Strafe Runner)":
			_build_switchblade()
		"Wraith Bomber":
			_build_wraith()
		"Patrol Drone":
			_build_patrol_drone()
		"Schwarm":
			# Inheritor suicide-drone swarm. 6 small kamikaze munitions
			# with Architect-violet emitters + verdigris-bronze accents.
			_build_inheritor_swarm(6, _team_color(), Color(0.62, 0.60, 0.56), 0.50)
		"Firefly":
			# Heliarch incendiary drone pack — 6 small drones in a loose
			# swarm. Warm body colour (sooted iron) + the standard drone
			# build; the AS bomblet weapon does the visual work at
			# fire-time, not on the drone hull itself.
			_build_heliarch_firefly_swarm()
		"Águila":
			# Heliarch light gunship — single airframe with napalm
			# tanks + AA chaingun. (File name + builder name are the
			# legacy "Condor" because we swapped in-game names but
			# kept internal identifiers stable.)
			_build_heliarch_condor()
		"Condor":
			# Heliarch heavy bomber — much larger silhouette, thicker
			# fuselage with a huge belly bomb bay, four engines, brass
			# canopy + flood, big tail fin. (Builder is named for the
			# pre-swap identity; in-game this displays as "Condor".)
			_build_heliarch_aguila()
		_:
			_build_default_aircraft()


func _team_color() -> Color:
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry if get_tree() else null
	if registry:
		return registry.get_perspective_color(owner_id)
	return Color(0.7, 0.7, 0.7, 1.0)


func _aircraft_metal_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.albedo_texture = SharedTextures.get_metal_wear_texture()
	m.uv1_offset = Vector3(randf(), randf(), 0.0)
	m.uv1_scale = Vector3(1.8, 1.8, 1.0)
	m.roughness = 0.5
	m.metallic = 0.5
	return m


func _build_drone_swarm(count: int, team: Color, body_color: Color, drone_size: float, is_anvil_blocky: bool) -> void:
	## Renders a swarm as `count` small drone meshes in a tight V-formation
	## around the aircraft origin. Drones bob slightly via per-frame
	## update in `_process` (registered via _drone_meshes for animation).
	## `is_anvil_blocky` selects the drone silhouette style: Combine drones
	## are squat boxes with stubby wings (Sputnik); Meridian drones are
	## sharper, slimmer angular shapes with forward-pointing nose
	## (Fang).
	var ring_offsets: Array[Vector3] = _v_formation_offsets(count, drone_size * 1.6)
	for i: int in count:
		var drone := Node3D.new()
		drone.position = ring_offsets[i]
		# Per-drone phase so they bob out of sync.
		drone.set_meta("bob_phase", randf() * TAU)
		add_child(drone)
		_drone_meshes.append(drone)

		if is_anvil_blocky:
			_build_anvil_drone(drone, team, body_color, drone_size)
		else:
			_build_sable_drone(drone, team, body_color, drone_size)


func _v_formation_offsets(n: int, spacing: float) -> Array[Vector3]:
	# Tight V — symmetric in either parity:
	#   odd n  → 1 leader at origin + (n-1)/2 mirrored pairs back-and-out
	#   even n → no central leader, instead a front PAIR at ±spacing/2,
	#            then (n/2 - 1) more mirrored pairs receding behind them
	# Without this, even counts (8, 10) had one unpaired drone trailing
	# off one side — visually lopsided.
	var arr: Array[Vector3] = []
	if n <= 0:
		return arr
	if n % 2 == 1:
		arr.append(Vector3.ZERO)
		@warning_ignore("integer_division")
		var pairs: int = (n - 1) / 2
		for r: int in pairs:
			var rank: int = r + 1
			var x: float = spacing * float(rank)
			var z: float = -spacing * 0.85 * float(rank)
			arr.append(Vector3(-x, 0.0, z))
			arr.append(Vector3(+x, 0.0, z))
	else:
		@warning_ignore("integer_division")
		var pairs: int = n / 2
		for r: int in pairs:
			# Front pair sits at ±spacing/2 (no central leader); each
			# subsequent pair recedes backward and outward by one spacing
			# unit, mirroring the odd-count V geometry but offset half a
			# step so the silhouette stays symmetric.
			var x: float = spacing * (float(r) + 0.5)
			var z: float = -spacing * 0.85 * float(r)
			arr.append(Vector3(-x, 0.0, z))
			arr.append(Vector3(+x, 0.0, z))
	return arr


func _apply_phalanx_shield_extras() -> void:
	# Each Shield drone gains a forward shield-emitter disc PLUS two
	# smaller side emitters bracketing it (3-emitter cluster), and
	# darkened armor strips along the body sides so the silhouette
	# reads tank-bulky vs the Interceptor's needle-thin profile.
	var shield_tint: Color = Color(0.30, 0.78, 1.0, 1.0)
	for drone: Node3D in _drone_meshes:
		if not is_instance_valid(drone):
			continue
		# Main forward shield-emitter disc.
		var disc := MeshInstance3D.new()
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var d_cyl := CylinderMesh.new()
		d_cyl.top_radius = 0.32
		d_cyl.bottom_radius = 0.32
		d_cyl.height = 0.04
		d_cyl.radial_segments = 18
		disc.mesh = d_cyl
		disc.rotation.x = PI * 0.5
		disc.position = Vector3(0.0, 0.0, 0.55)
		var d_mat := StandardMaterial3D.new()
		d_mat.albedo_color = Color(shield_tint.r, shield_tint.g, shield_tint.b, 0.55)
		d_mat.emission_enabled = true
		d_mat.emission = shield_tint
		d_mat.emission_energy_multiplier = 1.4
		d_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		d_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		d_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		disc.set_surface_override_material(0, d_mat)
		drone.add_child(disc)
		# Two flanking smaller emitters -- shorter forward reach,
		# smaller disc, same shield material so the cluster reads
		# unified.
		for side: int in 2:
			var sx: float = -1.0 if side == 0 else 1.0
			var em := MeshInstance3D.new()
			em.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var em_cyl := CylinderMesh.new()
			em_cyl.top_radius = 0.16
			em_cyl.bottom_radius = 0.16
			em_cyl.height = 0.03
			em_cyl.radial_segments = 14
			em.mesh = em_cyl
			em.rotation.x = PI * 0.5
			em.position = Vector3(sx * 0.36, -0.04, 0.40)
			em.set_surface_override_material(0, d_mat)
			drone.add_child(em)
		# Side armor strips -- thin dark plates along the drone body
		# so the chassis reads heavier than the bare-body Interceptor.
		var armor_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.18, 0.20, 0.22))
		for side2: int in 2:
			var sx2: float = -1.0 if side2 == 0 else 1.0
			var strip := MeshInstance3D.new()
			strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var st_box := BoxMesh.new()
			st_box.size = Vector3(0.08, 0.30, 1.10)
			strip.mesh = st_box
			strip.position = Vector3(sx2 * 0.46, 0.0, 0.0)
			strip.set_surface_override_material(0, armor_mat)
			drone.add_child(strip)
		# Top emitter ridge -- a small cyan emissive bar on the spine
		# so the Shield reads even from above (matters for the
		# top-down RTS camera).
		var ridge := MeshInstance3D.new()
		ridge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ri_box := BoxMesh.new()
		ri_box.size = Vector3(0.08, 0.04, 0.65)
		ridge.mesh = ri_box
		ridge.position = Vector3(0.0, 0.20, 0.0)
		var ri_mat := StandardMaterial3D.new()
		ri_mat.albedo_color = shield_tint
		ri_mat.emission_enabled = true
		ri_mat.emission = shield_tint
		ri_mat.emission_energy_multiplier = 1.6
		ri_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ridge.set_surface_override_material(0, ri_mat)
		drone.add_child(ridge)


func _apply_phalanx_interceptor_extras() -> void:
	# Pure dogfighter silhouette: sharp nose, under-slung barrel,
	# swept wing fins on each side, and an orange afterburner glow at
	# the tail so the formation reads as 'fast strike wing' vs the
	# Shield's bulky defensive cluster.
	for drone: Node3D in _drone_meshes:
		if not is_instance_valid(drone):
			continue
		# Sharp nose wedge.
		var nose := MeshInstance3D.new()
		nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var n_box := BoxMesh.new()
		n_box.size = Vector3(0.18, 0.10, 0.55)
		nose.mesh = n_box
		nose.position = Vector3(0.0, -0.02, 0.55)
		nose.rotation.x = deg_to_rad(-6.0)
		nose.set_surface_override_material(0, _aircraft_metal_mat(Color(0.42, 0.38, 0.30)))
		drone.add_child(nose)
		# Under-slung gun barrel.
		var barrel := MeshInstance3D.new()
		barrel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var b_cyl := CylinderMesh.new()
		b_cyl.top_radius = 0.04
		b_cyl.bottom_radius = 0.05
		b_cyl.height = 0.40
		b_cyl.radial_segments = 8
		barrel.mesh = b_cyl
		barrel.rotation.x = PI * 0.5
		barrel.position = Vector3(0.0, -0.18, 0.45)
		barrel.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.10)))
		drone.add_child(barrel)
		# Swept wing fins -- one each side, angled back so the
		# silhouette reads streamlined.
		var fin_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.32, 0.28, 0.20))
		for side: int in 2:
			var sx: float = -1.0 if side == 0 else 1.0
			var fin := MeshInstance3D.new()
			fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var f_box := BoxMesh.new()
			f_box.size = Vector3(0.45, 0.04, 0.22)
			fin.mesh = f_box
			fin.position = Vector3(sx * 0.40, 0.02, -0.12)
			fin.rotation.y = sx * deg_to_rad(-22.0)
			fin.set_surface_override_material(0, fin_mat)
			drone.add_child(fin)
		# Tail afterburner -- a small orange glow at the back of the
		# drone so the formation reads as 'engines hot, accelerating
		# to intercept'.
		var tail := MeshInstance3D.new()
		tail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var t_cyl := CylinderMesh.new()
		t_cyl.top_radius = 0.10
		t_cyl.bottom_radius = 0.12
		t_cyl.height = 0.18
		t_cyl.radial_segments = 12
		tail.mesh = t_cyl
		tail.rotation.x = PI * 0.5
		tail.position = Vector3(0.0, 0.0, -0.65)
		var t_mat := StandardMaterial3D.new()
		t_mat.albedo_color = Color(1.0, 0.55, 0.18)
		t_mat.emission_enabled = true
		t_mat.emission = Color(1.0, 0.55, 0.18)
		t_mat.emission_energy_multiplier = 2.4
		t_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		tail.set_surface_override_material(0, t_mat)
		drone.add_child(tail)


func _apply_fang_hunter_extras() -> void:
	# Tracker silhouette: tall sensor needle, two side-mounted
	# secondary sensor pods, a wing-mounted antenna array, and a
	# soft glow ring around the body so the formation reads as
	# 'always painting targets' vs Harasser's bristling guns.
	var needle_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.10, 0.10, 0.13))
	var pod_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.16, 0.14, 0.20))
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_color = SABLE_NEON_PALE
	glow_mat.emission_enabled = true
	glow_mat.emission = SABLE_NEON_PALE
	glow_mat.emission_energy_multiplier = 2.0
	for drone: Node3D in _drone_meshes:
		if not is_instance_valid(drone):
			continue
		# Main sensor needle.
		var needle := MeshInstance3D.new()
		needle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var n_box := BoxMesh.new()
		n_box.size = Vector3(0.03, 0.42, 0.03)
		needle.mesh = n_box
		needle.position = Vector3(0.0, 0.25, 0.0)
		needle.set_surface_override_material(0, needle_mat)
		drone.add_child(needle)
		# Cross-bar antenna array near the base of the needle.
		var crossbar := MeshInstance3D.new()
		crossbar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cb_box := BoxMesh.new()
		cb_box.size = Vector3(0.32, 0.02, 0.02)
		crossbar.mesh = cb_box
		crossbar.position = Vector3(0.0, 0.32, 0.0)
		crossbar.set_surface_override_material(0, needle_mat)
		drone.add_child(crossbar)
		# Smaller cross-bar higher up.
		var crossbar2 := MeshInstance3D.new()
		crossbar2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cb2_box := BoxMesh.new()
		cb2_box.size = Vector3(0.20, 0.02, 0.02)
		crossbar2.mesh = cb2_box
		crossbar2.position = Vector3(0.0, 0.42, 0.0)
		crossbar2.set_surface_override_material(0, needle_mat)
		drone.add_child(crossbar2)
		# Tip light at the very top.
		var tip := MeshInstance3D.new()
		tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var t_sph := SphereMesh.new()
		t_sph.radius = 0.06
		t_sph.height = 0.12
		tip.mesh = t_sph
		tip.position = Vector3(0.0, 0.50, 0.0)
		tip.set_surface_override_material(0, glow_mat)
		drone.add_child(tip)
		# Two side sensor pods -- small ovoids on each side of the
		# body with their own glow apertures aimed forward.
		for side: int in 2:
			var sx: float = -1.0 if side == 0 else 1.0
			var pod := MeshInstance3D.new()
			pod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var po_sph := SphereMesh.new()
			po_sph.radius = 0.10
			po_sph.height = 0.20
			pod.mesh = po_sph
			pod.position = Vector3(sx * 0.40, 0.04, 0.10)
			pod.scale = Vector3(0.9, 0.7, 1.4)
			pod.set_surface_override_material(0, pod_mat)
			drone.add_child(pod)
			# Pod aperture glow.
			var aperture := MeshInstance3D.new()
			aperture.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var ap_cyl := CylinderMesh.new()
			ap_cyl.top_radius = 0.04
			ap_cyl.bottom_radius = 0.04
			ap_cyl.height = 0.02
			ap_cyl.radial_segments = 10
			aperture.mesh = ap_cyl
			aperture.rotation.x = PI * 0.5
			aperture.position = Vector3(sx * 0.40, 0.04, 0.24)
			aperture.set_surface_override_material(0, glow_mat)
			drone.add_child(aperture)


func _apply_fang_harasser_extras() -> void:
	# Salvage-disrupt repeater silhouette: twin forward barrels, an
	# ammo box on each side feeding the barrels via short belts, and
	# a small disruptor coil ring around each barrel that pulses
	# violet so the formation reads as 'bristling, lit-up gunship'.
	var barrel_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.06, 0.06, 0.08))
	var ammo_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.18, 0.16, 0.20))
	var coil_mat := StandardMaterial3D.new()
	coil_mat.albedo_color = SABLE_NEON_PALE
	coil_mat.emission_enabled = true
	coil_mat.emission = SABLE_NEON_PALE
	coil_mat.emission_energy_multiplier = 1.8
	for drone: Node3D in _drone_meshes:
		if not is_instance_valid(drone):
			continue
		for side: int in 2:
			var sx: float = -1.0 if side == 0 else 1.0
			# Forward gun barrel.
			var barrel := MeshInstance3D.new()
			barrel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var b_cyl := CylinderMesh.new()
			b_cyl.top_radius = 0.025
			b_cyl.bottom_radius = 0.030
			b_cyl.height = 0.40
			b_cyl.radial_segments = 8
			barrel.mesh = b_cyl
			barrel.rotation.x = PI * 0.5
			barrel.position = Vector3(sx * 0.18, -0.05, 0.42)
			barrel.set_surface_override_material(0, barrel_mat)
			drone.add_child(barrel)
			# Disruptor coil ring midway down the barrel -- a thin
			# torus-equivalent (low-segment cylinder) glowing violet.
			var coil := MeshInstance3D.new()
			coil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var co_cyl := CylinderMesh.new()
			co_cyl.top_radius = 0.06
			co_cyl.bottom_radius = 0.06
			co_cyl.height = 0.025
			co_cyl.radial_segments = 12
			coil.mesh = co_cyl
			coil.rotation.x = PI * 0.5
			coil.position = Vector3(sx * 0.18, -0.05, 0.42)
			coil.set_surface_override_material(0, coil_mat)
			drone.add_child(coil)
			# Side ammo box -- a small box wedged against the body.
			var ammo := MeshInstance3D.new()
			ammo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var am_box := BoxMesh.new()
			am_box.size = Vector3(0.12, 0.10, 0.20)
			ammo.mesh = am_box
			ammo.position = Vector3(sx * 0.30, -0.05, 0.16)
			ammo.set_surface_override_material(0, ammo_mat)
			drone.add_child(ammo)
			# Belt feed -- small dark strip from the box to the
			# barrel base.
			var belt := MeshInstance3D.new()
			belt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var be_box := BoxMesh.new()
			be_box.size = Vector3(0.04, 0.03, 0.18)
			belt.mesh = be_box
			belt.position = Vector3(sx * 0.24, -0.04, 0.30)
			belt.rotation.y = sx * deg_to_rad(-12.0)
			belt.set_surface_override_material(0, barrel_mat)
			drone.add_child(belt)


func _build_anvil_drone(parent: Node3D, team: Color, body_color: Color, s: float) -> void:
	# Squat blocky drone — Anvil utilitarian. Forward direction = +Z
	# (matches the aircraft.look_at flip).
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var body_box := BoxMesh.new()
	body_box.size = Vector3(s * 1.0, s * 0.45, s * 1.3)
	body.mesh = body_box
	body.set_surface_override_material(0, _aircraft_metal_mat(body_color))
	parent.add_child(body)

	# Nose taper — smaller box at the front of the body for a slightly
	# pointed silhouette instead of a pure brick.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_box := BoxMesh.new()
	nose_box.size = Vector3(s * 0.65, s * 0.35, s * 0.35)
	nose.mesh = nose_box
	nose.position = Vector3(0, s * 0.0, s * 0.75)
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.08)))
	parent.add_child(nose)

	# Cockpit canopy — small dark bubble on top of the nose.
	var canopy := MeshInstance3D.new()
	canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var canopy_sph := SphereMesh.new()
	canopy_sph.radius = s * 0.12
	canopy_sph.height = s * 0.2
	canopy.mesh = canopy_sph
	canopy.position = Vector3(0, s * 0.22, s * 0.5)
	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.albedo_color = Color(0.06, 0.08, 0.12, 1.0)
	canopy_mat.metallic = 0.85
	canopy_mat.roughness = 0.15
	canopy.set_surface_override_material(0, canopy_mat)
	parent.add_child(canopy)

	# Stubby wings.
	var wing := MeshInstance3D.new()
	wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wing_box := BoxMesh.new()
	wing_box.size = Vector3(s * 1.8, s * 0.10, s * 0.55)
	wing.mesh = wing_box
	wing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
	parent.add_child(wing)

	# Wingtip running lights — small emissive dots at each wing end.
	for side: int in 2:
		var light_dot := MeshInstance3D.new()
		light_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var light_sph := SphereMesh.new()
		light_sph.radius = s * 0.07
		light_sph.height = s * 0.14
		light_dot.mesh = light_sph
		var sign_x: float = 1.0 if side == 0 else -1.0
		light_dot.position = Vector3(sign_x * s * 0.9, 0, 0)
		var ld_mat := StandardMaterial3D.new()
		# Red on right wing, green on left — aviation convention.
		ld_mat.albedo_color = Color(0.9, 0.1, 0.1, 1.0) if side == 0 else Color(0.1, 0.9, 0.4, 1.0)
		ld_mat.emission_enabled = true
		ld_mat.emission = ld_mat.albedo_color
		ld_mat.emission_energy_multiplier = 1.4
		ld_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		light_dot.set_surface_override_material(0, ld_mat)
		parent.add_child(light_dot)

	# Hardpoint pylons under the wings — tiny cylindrical struts.
	for side2: int in 2:
		var pylon := MeshInstance3D.new()
		pylon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pylon_cyl := CylinderMesh.new()
		pylon_cyl.top_radius = s * 0.06
		pylon_cyl.bottom_radius = s * 0.07
		pylon_cyl.height = s * 0.18
		pylon.mesh = pylon_cyl
		var sign2: float = 1.0 if side2 == 0 else -1.0
		pylon.position = Vector3(sign2 * s * 0.55, -s * 0.15, 0)
		pylon.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.25)))
		parent.add_child(pylon)

	# Tail fin.
	var fin := MeshInstance3D.new()
	fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fin_box := BoxMesh.new()
	fin_box.size = Vector3(s * 0.08, s * 0.45, s * 0.4)
	fin.mesh = fin_box
	fin.position = Vector3(0, s * 0.25, -s * 0.5)
	fin.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.2)))
	parent.add_child(fin)

	# Engine exhaust nozzle at the rear — emissive orange glow.
	var exhaust := MeshInstance3D.new()
	exhaust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var exhaust_cyl := CylinderMesh.new()
	exhaust_cyl.top_radius = s * 0.16
	exhaust_cyl.bottom_radius = s * 0.16
	exhaust_cyl.height = s * 0.18
	exhaust.mesh = exhaust_cyl
	exhaust.rotation.x = PI / 2  # cylinder along +Z (rear)
	exhaust.position = Vector3(0, 0, -s * 0.75)
	var ex_mat := StandardMaterial3D.new()
	ex_mat.albedo_color = Color(1.0, 0.45, 0.12, 1.0)
	ex_mat.emission_enabled = true
	ex_mat.emission = Color(1.0, 0.5, 0.15, 1.0)
	ex_mat.emission_energy_multiplier = 1.8
	ex_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	exhaust.set_surface_override_material(0, ex_mat)
	parent.add_child(exhaust)

	# Team-color underbelly stripe.
	var stripe := MeshInstance3D.new()
	stripe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(s * 0.6, s * 0.08, s * 1.0)
	stripe.mesh = stripe_box
	stripe.position.y = -s * 0.27
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team
	stripe_mat.emission_energy_multiplier = 1.0
	stripe.set_surface_override_material(0, stripe_mat)
	parent.add_child(stripe)


func _build_inheritor_swarm(count: int, team: Color, body_color: Color, drone_size: float) -> void:
	## Inheritor Schwarm — squad of small kamikaze munitions in V
	## formation. Each drone is a wedge with verdigris-bronze chassis,
	## an Architect-violet detonator glow at the tip, and small bronze
	## fins. Per 03_factions §4.4: pale concrete-grey, patinated bronze,
	## violet-white indicator.
	const ARCHITECT_VIOLET: Color = Color(0.70, 0.55, 1.0, 1.0)
	const BRONZE_PATINA: Color = Color(0.55, 0.40, 0.20, 1.0)
	const VERDIGRIS: Color = Color(0.32, 0.50, 0.42, 1.0)
	var ring_offsets: Array[Vector3] = _v_formation_offsets(count, drone_size * 1.6)
	for i: int in count:
		var drone := Node3D.new()
		drone.position = ring_offsets[i]
		drone.set_meta("bob_phase", randf() * TAU)
		add_child(drone)
		_drone_meshes.append(drone)
		_build_inheritor_kamikaze_drone(drone, team, body_color, drone_size, ARCHITECT_VIOLET, BRONZE_PATINA, VERDIGRIS)


func _build_inheritor_kamikaze_drone(parent: Node3D, team: Color, body_color: Color, s: float, violet: Color, bronze: Color, verdigris: Color) -> void:
	## A single Inheritor kamikaze drone. Wedge body, violet detonator
	## bulb at the nose, verdigris pipe along the spine, two bronze
	## fins at the back. Reads as "consecrated suicide munition" rather
	## than "fighter aircraft".
	# Wedge body — tapering from wider rear to a pointed nose. Built
	# as two stacked boxes so the silhouette has a clear forward taper.
	var rear := MeshInstance3D.new()
	rear.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rb := BoxMesh.new()
	rb.size = Vector3(s * 0.50, s * 0.30, s * 0.85)
	rear.mesh = rb
	rear.position = Vector3(0, 0, -s * 0.35)
	rear.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.08)))
	parent.add_child(rear)
	# Mid section — slightly narrower.
	var mid := MeshInstance3D.new()
	mid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mb := BoxMesh.new()
	mb.size = Vector3(s * 0.35, s * 0.26, s * 0.60)
	mid.mesh = mb
	mid.position = Vector3(0, 0.02, s * 0.20)
	mid.set_surface_override_material(0, _aircraft_metal_mat(body_color))
	parent.add_child(mid)
	# Nose taper — short cone to a violet detonator.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_cyl := CylinderMesh.new()
	nose_cyl.top_radius = 0.0
	nose_cyl.bottom_radius = s * 0.14
	nose_cyl.height = s * 0.50
	nose_cyl.radial_segments = 8
	nose.mesh = nose_cyl
	nose.rotation.x = deg_to_rad(-90.0)  # cone tip points forward (-Z)
	nose.position = Vector3(0, 0.02, s * 0.72)
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.16)))
	parent.add_child(nose)
	# Violet detonator bulb just behind the cone tip.
	var detonator := MeshInstance3D.new()
	detonator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var det_sph := SphereMesh.new()
	det_sph.radius = s * 0.10
	det_sph.height = s * 0.20
	detonator.mesh = det_sph
	detonator.position = Vector3(0, 0.02, s * 0.92)
	var det_mat := StandardMaterial3D.new()
	det_mat.albedo_color = violet
	det_mat.emission_enabled = true
	det_mat.emission = violet
	det_mat.emission_energy_multiplier = 2.8
	det_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	detonator.set_surface_override_material(0, det_mat)
	parent.add_child(detonator)
	# Verdigris-bronze pipework along the spine — sells "plumbed with
	# corrosive payload".
	var spine_pipe := MeshInstance3D.new()
	spine_pipe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sp_cyl := CylinderMesh.new()
	sp_cyl.top_radius = s * 0.04
	sp_cyl.bottom_radius = s * 0.04
	sp_cyl.height = s * 1.10
	sp_cyl.radial_segments = 8
	spine_pipe.mesh = sp_cyl
	spine_pipe.rotation.x = PI * 0.5
	spine_pipe.position = Vector3(0, s * 0.20, -s * 0.05)
	spine_pipe.set_surface_override_material(0, _aircraft_metal_mat(verdigris))
	parent.add_child(spine_pipe)
	# Two bronze fins at the rear — small swept verticals so the drone
	# reads as guided rather than thrown.
	for fin_side: int in 2:
		var fsx: float = 1.0 if fin_side == 0 else -1.0
		var fin := MeshInstance3D.new()
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var fb := BoxMesh.new()
		fb.size = Vector3(s * 0.04, s * 0.30, s * 0.34)
		fin.mesh = fb
		fin.position = Vector3(fsx * s * 0.10, s * 0.20, -s * 0.65)
		fin.rotation.z = fsx * deg_to_rad(12.0)
		fin.set_surface_override_material(0, _aircraft_metal_mat(bronze))
		parent.add_child(fin)
	# Small violet thruster glow at the back so propulsion reads.
	var thruster := MeshInstance3D.new()
	thruster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var th_cyl := CylinderMesh.new()
	th_cyl.top_radius = s * 0.08
	th_cyl.bottom_radius = s * 0.08
	th_cyl.height = s * 0.10
	th_cyl.radial_segments = 10
	thruster.mesh = th_cyl
	thruster.rotation.x = PI * 0.5
	thruster.position = Vector3(0, 0, -s * 0.78)
	var th_mat := StandardMaterial3D.new()
	th_mat.albedo_color = violet
	th_mat.emission_enabled = true
	th_mat.emission = violet
	th_mat.emission_energy_multiplier = 2.0
	th_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	thruster.set_surface_override_material(0, th_mat)
	parent.add_child(thruster)
	# Team-color sliver near the rear so allegiance reads.
	var team_sliver := MeshInstance3D.new()
	team_sliver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ts_box := BoxMesh.new()
	ts_box.size = Vector3(s * 0.20, s * 0.04, s * 0.20)
	team_sliver.mesh = ts_box
	team_sliver.position = Vector3(0, s * 0.18, -s * 0.55)
	var team_mat := StandardMaterial3D.new()
	team_mat.albedo_color = team
	team_mat.emission_enabled = true
	team_mat.emission = team
	team_mat.emission_energy_multiplier = 1.2
	team_sliver.set_surface_override_material(0, team_mat)
	parent.add_child(team_sliver)


func _build_sable_drone(parent: Node3D, team: Color, body_color: Color, s: float) -> void:
	# Slim angular drone — Sable predatory.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var body_box := BoxMesh.new()
	body_box.size = Vector3(s * 0.55, s * 0.32, s * 1.6)
	body.mesh = body_box
	body.set_surface_override_material(0, _aircraft_metal_mat(body_color))
	parent.add_child(body)

	# Forward-swept wings — diagonal box rotated.
	for side: int in 2:
		var wing := MeshInstance3D.new()
		wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wing_box := BoxMesh.new()
		wing_box.size = Vector3(s * 1.0, s * 0.05, s * 0.6)
		wing.mesh = wing_box
		var sx: float = 1.0 if side == 0 else -1.0
		wing.position = Vector3(sx * s * 0.65, 0, -s * 0.1)
		wing.rotation.y = sx * deg_to_rad(28.0)
		wing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.1)))
		parent.add_child(wing)

	# Forward-pointing nose spike.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_box := BoxMesh.new()
	nose_box.size = Vector3(s * 0.18, s * 0.18, s * 0.45)
	nose.mesh = nose_box
	nose.position.z = s * 0.95
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.2)))
	parent.add_child(nose)

	# Cool blue-white sensor strip running along the spine.
	var sensor := MeshInstance3D.new()
	sensor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sensor_box := BoxMesh.new()
	sensor_box.size = Vector3(s * 0.06, s * 0.04, s * 1.2)
	sensor.mesh = sensor_box
	sensor.position.y = s * 0.2
	var sensor_mat := StandardMaterial3D.new()
	sensor_mat.albedo_color = team
	sensor_mat.emission_enabled = true
	sensor_mat.emission = team
	sensor_mat.emission_energy_multiplier = 2.0
	sensor.set_surface_override_material(0, sensor_mat)
	parent.add_child(sensor)

	# Twin twin-mounted engine nozzles flanking the rear — tight pair
	# of cyan-glowing exhausts gives the Sable drone a more menacing
	# silhouette than a single underbelly stripe.
	for side2: int in 2:
		var sx2: float = 1.0 if side2 == 0 else -1.0
		var nozzle := MeshInstance3D.new()
		nozzle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var noz_cyl := CylinderMesh.new()
		noz_cyl.top_radius = s * 0.10
		noz_cyl.bottom_radius = s * 0.10
		noz_cyl.height = s * 0.20
		nozzle.mesh = noz_cyl
		nozzle.rotation.x = PI / 2
		nozzle.position = Vector3(sx2 * s * 0.20, 0, -s * 0.85)
		var noz_mat := StandardMaterial3D.new()
		noz_mat.albedo_color = Color(0.50, 0.95, 1.0, 1.0)
		noz_mat.emission_enabled = true
		noz_mat.emission = Color(0.5, 0.95, 1.0, 1.0)
		noz_mat.emission_energy_multiplier = 2.2
		noz_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		nozzle.set_surface_override_material(0, noz_mat)
		parent.add_child(nozzle)

	# Canard fins on each side of the nose for an angular predator
	# silhouette — small triangular kicker boxes rotated.
	for side3: int in 2:
		var sx3: float = 1.0 if side3 == 0 else -1.0
		var canard := MeshInstance3D.new()
		canard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var c_box := BoxMesh.new()
		c_box.size = Vector3(s * 0.45, s * 0.04, s * 0.20)
		canard.mesh = c_box
		canard.position = Vector3(sx3 * s * 0.30, s * 0.02, s * 0.60)
		canard.rotation.y = sx3 * deg_to_rad(-18.0)
		canard.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.18)))
		parent.add_child(canard)

	# Vertical tail fin — thin angular blade at the rear top.
	var tail := MeshInstance3D.new()
	tail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tail_box := BoxMesh.new()
	tail_box.size = Vector3(s * 0.05, s * 0.42, s * 0.32)
	tail.mesh = tail_box
	tail.position = Vector3(0, s * 0.30, -s * 0.50)
	tail.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.2)))
	parent.add_child(tail)

	# Asymmetric data-uplink antenna on the right side of the body —
	# breaks the mirror-symmetry per 03_factions §"Sable Visual Language:
	# deliberately asymmetric". Mounted just behind the canards, angles
	# up-and-out. Violet emissive tip dot.
	var uplink := MeshInstance3D.new()
	uplink.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var u_cyl := CylinderMesh.new()
	u_cyl.top_radius = s * 0.018
	u_cyl.bottom_radius = s * 0.028
	u_cyl.height = s * 0.38
	u_cyl.radial_segments = 6
	uplink.mesh = u_cyl
	uplink.rotation.z = deg_to_rad(-22.0)
	uplink.position = Vector3(s * 0.32, s * 0.18, s * 0.18)
	uplink.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.12)))
	parent.add_child(uplink)
	var uplink_tip := MeshInstance3D.new()
	uplink_tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ut_sph := SphereMesh.new()
	ut_sph.radius = s * 0.04
	ut_sph.height = s * 0.08
	uplink_tip.mesh = ut_sph
	uplink_tip.position = Vector3(
		s * 0.32 + sin(deg_to_rad(-22.0)) * s * 0.19,
		s * 0.18 + cos(deg_to_rad(-22.0)) * s * 0.19,
		s * 0.18,
	)
	var ut_mat := StandardMaterial3D.new()
	ut_mat.albedo_color = SABLE_NEON_PALE
	ut_mat.emission_enabled = true
	ut_mat.emission = SABLE_NEON_PALE
	ut_mat.emission_energy_multiplier = 2.2
	ut_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	uplink_tip.set_surface_override_material(0, ut_mat)
	parent.add_child(uplink_tip)


func _build_hammerhead() -> void:
	# Heavy gunship — wide low-profile body, weapon pods underneath,
	# tail rotor + twin engine nacelles. Anvil's flagship aircraft.
	# v3 polish: scaled ~25% smaller and densified with cockpit canopy,
	# intake grilles, panel-line strips, antenna mast, and ventral fin
	# so the silhouette doesn't read as a single chunky box.
	var team: Color = _team_color()
	var body_color := Color(0.32, 0.30, 0.27, 1.0)

	# Hull broken into three stacked / nested segments instead of a
	# single 2.0×0.55×3.4 brick — the original silhouette read as
	# one big block from any zoom. Front segment is narrowest +
	# tallest (cockpit pod), mid segment carries the spine and is
	# the widest, rear segment tapers down to the boom. Two
	# chamfer plates on the top edges tie the segments together
	# and break the boxy silhouette.
	var hull_front := MeshInstance3D.new()
	hull_front.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hull_front_box := BoxMesh.new()
	hull_front_box.size = Vector3(1.55, 0.55, 1.10)
	hull_front.mesh = hull_front_box
	hull_front.position = Vector3(0, 0.02, 1.05)
	hull_front.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.04)))
	add_child(hull_front)

	var hull_mid := MeshInstance3D.new()
	hull_mid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hull_mid_box := BoxMesh.new()
	hull_mid_box.size = Vector3(2.0, 0.55, 1.30)
	hull_mid.mesh = hull_mid_box
	hull_mid.position = Vector3(0, 0.0, 0.0)
	hull_mid.set_surface_override_material(0, _aircraft_metal_mat(body_color))
	add_child(hull_mid)

	var hull_rear := MeshInstance3D.new()
	hull_rear.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hull_rear_box := BoxMesh.new()
	hull_rear_box.size = Vector3(1.65, 0.45, 1.10)
	hull_rear.mesh = hull_rear_box
	hull_rear.position = Vector3(0, -0.02, -1.10)
	hull_rear.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.06)))
	add_child(hull_rear)

	# Two chamfer plates joining the segments — slim slabs tilted
	# inward on the top edges so the silhouette steps down from
	# mid to front and from mid to rear instead of a hard ledge.
	for chamfer_z: int in 2:
		var chamfer := MeshInstance3D.new()
		chamfer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ch_box := BoxMesh.new()
		ch_box.size = Vector3(1.7, 0.05, 0.55)
		chamfer.mesh = ch_box
		var cz: float = 0.55 if chamfer_z == 0 else -0.55
		var crot: float = -0.30 if chamfer_z == 0 else 0.30
		chamfer.position = Vector3(0, 0.27, cz)
		chamfer.rotation.x = crot
		chamfer.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.10)))
		add_child(chamfer)

	# Tapered nose — angled slab in front. Width pulled in from 1.5
	# -> 1.10 so the silhouette pinches toward the front instead of
	# reading as a brick all the way to the tip; depth bumped a hair
	# so the taper still has length.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_box := BoxMesh.new()
	nose_box.size = Vector3(1.10, 0.42, 1.05)
	nose.mesh = nose_box
	nose.position = Vector3(0, -0.04, 2.0)
	nose.rotation.x = -0.20
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.05)))
	add_child(nose)
	# Forward nose-tip cap -- a smaller wedge in FRONT of the nose
	# block, shrinking again so the silhouette tapers in two stages
	# instead of one big slab. Reads as a real aircraft beak.
	var nose_tip := MeshInstance3D.new()
	nose_tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nt_box := BoxMesh.new()
	nt_box.size = Vector3(0.70, 0.32, 0.65)
	nose_tip.mesh = nt_box
	nose_tip.position = Vector3(0, -0.18, 2.65)
	nose_tip.rotation.x = -0.30
	nose_tip.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.10)))
	add_child(nose_tip)

	# Cockpit canopy — small angled bubble on top of the nose. Adds
	# silhouette focal point near the front + reads as a real cockpit.
	var canopy := MeshInstance3D.new()
	canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var canopy_box := BoxMesh.new()
	canopy_box.size = Vector3(0.85, 0.30, 0.85)
	canopy.mesh = canopy_box
	canopy.position = Vector3(0, 0.32, 1.55)
	canopy.rotation.x = -0.16
	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.albedo_color = Color(0.05, 0.10, 0.18, 1.0)
	canopy_mat.emission_enabled = true
	canopy_mat.emission = Color(0.30, 0.55, 0.85, 1.0)
	canopy_mat.emission_energy_multiplier = 0.8
	canopy_mat.metallic = 0.7
	canopy_mat.roughness = 0.20
	canopy.set_surface_override_material(0, canopy_mat)
	add_child(canopy)
	# Armored cage over the cockpit -- five thin metal bars running
	# fore-aft + two thicker hoops crosswise so the canopy reads as
	# protected by a roll cage instead of an exposed bubble.
	var cage_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.10, 0.10, 0.12, 1.0))
	for bar_i: int in 5:
		var bar := MeshInstance3D.new()
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var bb := BoxMesh.new()
		bb.size = Vector3(0.04, 0.05, 0.95)
		bar.mesh = bb
		var bx: float = (float(bar_i) - 2.0) * 0.18
		bar.position = Vector3(bx, 0.50, 1.55)
		bar.rotation.x = -0.16
		bar.set_surface_override_material(0, cage_mat)
		add_child(bar)
	for hoop_i: int in 2:
		var hoop := MeshInstance3D.new()
		hoop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var hb := BoxMesh.new()
		hb.size = Vector3(0.95, 0.06, 0.06)
		hoop.mesh = hb
		var hz: float = 1.55 + (float(hoop_i) - 0.5) * 0.55
		hoop.position = Vector3(0, 0.52, hz)
		hoop.rotation.x = -0.16
		hoop.set_surface_override_material(0, cage_mat)
		add_child(hoop)
	# Side cockpit shoulder -- two slim plates flanking the canopy at
	# the same angle so the cage reads as part of a fortified pilot
	# capsule rather than bolted-on bars over a bubble.
	for sx_i: int in 2:
		var ssx: float = -1.0 if sx_i == 0 else 1.0
		var shoulder := MeshInstance3D.new()
		shoulder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sb := BoxMesh.new()
		sb.size = Vector3(0.10, 0.30, 0.95)
		shoulder.mesh = sb
		shoulder.position = Vector3(ssx * 0.50, 0.30, 1.55)
		shoulder.rotation.x = -0.16
		shoulder.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.20)))
		add_child(shoulder)

	# Tapered tail -- pinched cap behind the rear hull so the
	# fuselage doesn't end in a hard rectangle. Slim wedge that
	# narrows the silhouette toward the boom.
	var tail_taper := MeshInstance3D.new()
	tail_taper.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tt_box := BoxMesh.new()
	tt_box.size = Vector3(1.10, 0.40, 0.75)
	tail_taper.mesh = tt_box
	tail_taper.position = Vector3(0, -0.06, -1.95)
	tail_taper.rotation.x = 0.18
	tail_taper.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.10)))
	add_child(tail_taper)

	# Twin engine nacelles flanking the body. Each nacelle is now
	# split into a forward intake block + an aft thrust block, with
	# a slim cooling-fin band wrapping the join — same overall
	# silhouette, much less monolithic at zoom.
	for side: int in 2:
		var sx: float = 1.0 if side == 0 else -1.0
		var nacelle_fwd := MeshInstance3D.new()
		nacelle_fwd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var n_fwd_box := BoxMesh.new()
		n_fwd_box.size = Vector3(0.50, 0.55, 0.95)
		nacelle_fwd.mesh = n_fwd_box
		nacelle_fwd.position = Vector3(sx * 1.30, 0.04, 0.20)
		nacelle_fwd.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.08)))
		add_child(nacelle_fwd)

		var nacelle_aft := MeshInstance3D.new()
		nacelle_aft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var n_aft_box := BoxMesh.new()
		n_aft_box.size = Vector3(0.46, 0.50, 0.90)
		nacelle_aft.mesh = n_aft_box
		nacelle_aft.position = Vector3(sx * 1.30, -0.02, -0.78)
		nacelle_aft.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.16)))
		add_child(nacelle_aft)

		# Cooling-fin band — three thin slabs ringing the nacelle
		# join so the gap between fwd / aft sections reads as a
		# real machined seam instead of a stuck-on box.
		for fin_y: int in 3:
			var fin := MeshInstance3D.new()
			fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var fb := BoxMesh.new()
			fb.size = Vector3(0.58, 0.05, 0.10)
			fin.mesh = fb
			var fy: float = (float(fin_y) - 1.0) * 0.18
			fin.position = Vector3(sx * 1.30, fy, -0.30)
			fin.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.12, 1.0)))
			add_child(fin)

		# Intake grille on the nacelle face — shallow recess + cross-bars
		# so the front of the engine reads as an air intake, not a brick.
		var intake := MeshInstance3D.new()
		intake.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var intake_box := BoxMesh.new()
		intake_box.size = Vector3(0.36, 0.42, 0.20)
		intake.mesh = intake_box
		intake.position = Vector3(sx * 1.30, 0.0, 0.78)
		intake.set_surface_override_material(0, _aircraft_metal_mat(Color(0.05, 0.05, 0.06, 1.0)))
		add_child(intake)
		for bar_i: int in 3:
			var bar := MeshInstance3D.new()
			bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var bar_box := BoxMesh.new()
			bar_box.size = Vector3(0.42, 0.04, 0.04)
			bar.mesh = bar_box
			var by: float = (float(bar_i) - 1.0) * 0.14
			bar.position = Vector3(sx * 1.30, by, 0.86)
			bar.set_surface_override_material(0, _aircraft_metal_mat(Color(0.18, 0.18, 0.18, 1.0)))
			add_child(bar)

		# Engine exhaust — emissive at the back of each nacelle.
		var exhaust := MeshInstance3D.new()
		exhaust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var exh_box := BoxMesh.new()
		exh_box.size = Vector3(0.34, 0.32, 0.16)
		exhaust.mesh = exh_box
		exhaust.position = Vector3(sx * 1.30, 0.0, -1.30)
		var exh_mat := StandardMaterial3D.new()
		exh_mat.albedo_color = Color(1.0, 0.45, 0.15, 1.0)
		exh_mat.emission_enabled = true
		exh_mat.emission = Color(1.0, 0.45, 0.10, 1.0)
		exh_mat.emission_energy_multiplier = 2.5
		exhaust.set_surface_override_material(0, exh_mat)
		add_child(exhaust)

	# Underwing weapon pods (missile racks). Beefier than before — a
	# wider 5-tube cluster with a tapered nose cap, a top-mounted
	# avionics bulge, and visible per-tube end caps so the
	# silhouette telegraphs "this is the thing that fires the
	# 10-missile barrage." Each tube also gets a small emissive
	# ready-light tip so the salvo character reads at zoom.
	for side: int in 2:
		var sx: float = 1.0 if side == 0 else -1.0
		var pod_root := Node3D.new()
		pod_root.position = Vector3(sx * 0.78, -0.36, 0.40)
		add_child(pod_root)
		# Main pod body — wider + longer than before.
		var pod := MeshInstance3D.new()
		pod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pod_box := BoxMesh.new()
		pod_box.size = Vector3(0.46, 0.34, 1.40)
		pod.mesh = pod_box
		pod.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
		pod_root.add_child(pod)
		# Tapered nose cap on the front of the pod — chamfered box
		# tilted down so the tubes "point" forward instead of
		# meeting a flat brick face.
		var pod_nose := MeshInstance3D.new()
		pod_nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pn_box := BoxMesh.new()
		pn_box.size = Vector3(0.46, 0.20, 0.34)
		pod_nose.mesh = pn_box
		pod_nose.position = Vector3(0.0, -0.06, 0.85)
		pod_nose.rotation.x = deg_to_rad(-18.0)
		pod_nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.22)))
		pod_root.add_child(pod_nose)
		# Top avionics bulge — small box on top of the pod that
		# reads as the targeting sensor.
		var avionics := MeshInstance3D.new()
		avionics.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var av_box := BoxMesh.new()
		av_box.size = Vector3(0.30, 0.10, 0.55)
		avionics.mesh = av_box
		avionics.position = Vector3(0.0, 0.22, 0.10)
		avionics.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.25)))
		pod_root.add_child(avionics)
		# Five missile tube end-caps in a cross pattern on the
		# nose face — three on top row, two on bottom.
		var tube_layout: Array[Vector2] = [
			Vector2(-0.16, 0.04),
			Vector2(0.0, 0.04),
			Vector2(0.16, 0.04),
			Vector2(-0.08, -0.10),
			Vector2(0.08, -0.10),
		]
		for tube_pos: Vector2 in tube_layout:
			var tube := MeshInstance3D.new()
			tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var tube_cyl := CylinderMesh.new()
			tube_cyl.top_radius = 0.06
			tube_cyl.bottom_radius = 0.06
			tube_cyl.height = 0.10
			tube_cyl.radial_segments = 8
			tube.mesh = tube_cyl
			tube.rotation.x = PI * 0.5
			tube.position = Vector3(tube_pos.x, tube_pos.y, 1.06)
			tube.set_surface_override_material(0, _aircraft_metal_mat(Color(0.08, 0.08, 0.08, 1.0)))
			pod_root.add_child(tube)
			# Ready-light tip on each tube — small emissive cone
			# poking out so the salvo character reads at any zoom.
			var ready_tip := MeshInstance3D.new()
			ready_tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var rt_cyl := CylinderMesh.new()
			rt_cyl.top_radius = 0.0
			rt_cyl.bottom_radius = 0.045
			rt_cyl.height = 0.06
			rt_cyl.radial_segments = 8
			ready_tip.mesh = rt_cyl
			ready_tip.rotation.x = PI * 0.5
			ready_tip.position = Vector3(tube_pos.x, tube_pos.y, 1.13)
			var rt_mat := StandardMaterial3D.new()
			rt_mat.albedo_color = Color(1.0, 0.45, 0.15, 1.0)
			rt_mat.emission_enabled = true
			rt_mat.emission = Color(1.0, 0.55, 0.18, 1.0)
			rt_mat.emission_energy_multiplier = 1.4
			rt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			ready_tip.set_surface_override_material(0, rt_mat)
			pod_root.add_child(ready_tip)
		# Two side-mounted attachment lugs holding the pod to the
		# fuselage — small struts that break the "pod floating
		# under the wing" read.
		for lug_z: int in 2:
			var lug := MeshInstance3D.new()
			lug.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var lg_box := BoxMesh.new()
			lg_box.size = Vector3(0.10, 0.16, 0.12)
			lug.mesh = lg_box
			var lz: float = -0.30 if lug_z == 0 else 0.30
			lug.position = Vector3(-sx * 0.20, 0.18, lz)
			lug.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.30)))
			pod_root.add_child(lug)

	# Chin cannon — single stub barrel under the nose.
	var cannon := MeshInstance3D.new()
	cannon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cannon_box := BoxMesh.new()
	cannon_box.size = Vector3(0.32, 0.32, 0.85)
	cannon.mesh = cannon_box
	cannon.position = Vector3(0, -0.40, 1.55)
	cannon.set_surface_override_material(0, _aircraft_metal_mat(Color(0.18, 0.18, 0.20)))
	add_child(cannon)

	# Tail fin + horizontal stabilizers — cruciform tail for silhouette.
	var fin := MeshInstance3D.new()
	fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fin_box := BoxMesh.new()
	fin_box.size = Vector3(0.14, 0.75, 0.65)
	fin.mesh = fin_box
	fin.position = Vector3(0, 0.40, -1.55)
	fin.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.1)))
	add_child(fin)
	# Horizontal stabilizers — two short wings off the rear hull.
	for stab_side: int in 2:
		var ssx: float = 1.0 if stab_side == 0 else -1.0
		var stab := MeshInstance3D.new()
		stab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var stab_box := BoxMesh.new()
		stab_box.size = Vector3(0.85, 0.06, 0.45)
		stab.mesh = stab_box
		stab.position = Vector3(ssx * 0.55, 0.18, -1.50)
		stab.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.1)))
		add_child(stab)

	# Hull panel lines — two thin recessed strips running fore/aft along
	# each side of the hull. Reads as armor-plate seams at distance.
	for line_side: int in 2:
		var lsx: float = 1.0 if line_side == 0 else -1.0
		for line_y: int in 2:
			var line := MeshInstance3D.new()
			line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var line_box := BoxMesh.new()
			line_box.size = Vector3(0.04, 0.04, 2.5)
			line.mesh = line_box
			var ly: float = 0.15 if line_y == 0 else -0.10
			line.position = Vector3(lsx * 0.95, ly, 0.0)
			line.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.30)))
			add_child(line)

	# Cockpit + team-color stripe along the spine.
	var spine := MeshInstance3D.new()
	spine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var spine_box := BoxMesh.new()
	spine_box.size = Vector3(0.45, 0.14, 2.8)
	spine.mesh = spine_box
	spine.position.y = 0.34
	var spine_mat := StandardMaterial3D.new()
	spine_mat.albedo_color = team
	spine_mat.emission_enabled = true
	spine_mat.emission = team
	spine_mat.emission_energy_multiplier = 1.4
	spine.set_surface_override_material(0, spine_mat)
	add_child(spine)

	# Rotor mast — short pylon rising from the spine where the
	# rotor hub mounts. Reads as an attack-chopper instead of a
	# generic blocky gunship.
	var rotor_pylon := MeshInstance3D.new()
	rotor_pylon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rp_box := BoxMesh.new()
	rp_box.size = Vector3(0.34, 0.55, 0.34)
	rotor_pylon.mesh = rp_box
	rotor_pylon.position = Vector3(0, 0.72, 0.20)
	rotor_pylon.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.20)))
	add_child(rotor_pylon)
	# Rotor hub disc on top of the pylon.
	var hub := MeshInstance3D.new()
	hub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hub_cyl := CylinderMesh.new()
	hub_cyl.top_radius = 0.18
	hub_cyl.bottom_radius = 0.18
	hub_cyl.height = 0.10
	hub_cyl.radial_segments = 12
	hub.mesh = hub_cyl
	hub.position = Vector3(0, 1.05, 0.20)
	hub.set_surface_override_material(0, _aircraft_metal_mat(Color(0.08, 0.08, 0.08, 1.0)))
	add_child(hub)
	# Four-blade main rotor — bigger than the previous 3-blade /
	# 2.6u version (now 3.6u long, 4 blades) so the rotor disc reads
	# as a real heavy-lift gunship's sweep at any zoom. Each blade
	# has a slight droop at rest (rotation.z) to suggest weight; a
	# small rectangular blade-tip cap breaks up the slim slab.
	var rotor_pivot := Node3D.new()
	rotor_pivot.name = "RotorPivot"
	rotor_pivot.position = Vector3(0, 1.10, 0.20)
	add_child(rotor_pivot)
	for blade_i: int in 4:
		var blade := MeshInstance3D.new()
		blade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var bb := BoxMesh.new()
		bb.size = Vector3(3.6, 0.05, 0.20)
		blade.mesh = bb
		blade.rotation.y = float(blade_i) * (TAU / 4.0)
		blade.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.12, 0.9)))
		rotor_pivot.add_child(blade)
		# Blade-tip endcap so the silhouette doesn't end in a hard
		# rectangle — small box at the outer edge.
		var tip_cap := MeshInstance3D.new()
		tip_cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var tc_box := BoxMesh.new()
		tc_box.size = Vector3(0.18, 0.05, 0.12)
		tip_cap.mesh = tc_box
		tip_cap.rotation.y = float(blade_i) * (TAU / 4.0)
		tip_cap.position = Vector3(
			cos(float(blade_i) * (TAU / 4.0)) * 1.74,
			0.0,
			-sin(float(blade_i) * (TAU / 4.0)) * 1.74,
		)
		tip_cap.set_surface_override_material(0, _aircraft_metal_mat(Color(0.55, 0.45, 0.18, 1.0)))
		rotor_pivot.add_child(tip_cap)
	_anvil_rotor = rotor_pivot

	# Tail boom — restructured: thicker conical taper (was a flat
	# 0.30 box) running back from the hull, with three vertical
	# stiffener fins on top reading as load-bearing structural
	# bracing. Reads as a load-rated boom instead of a glued-on
	# stick.
	for boom_i: int in 3:
		var boom_seg := MeshInstance3D.new()
		boom_seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var bs_box := BoxMesh.new()
		# Each segment tapers thinner as it goes back.
		var seg_w: float = 0.42 - float(boom_i) * 0.06
		var seg_h: float = 0.40 - float(boom_i) * 0.05
		var seg_z_len: float = 0.46
		bs_box.size = Vector3(seg_w, seg_h, seg_z_len)
		boom_seg.mesh = bs_box
		boom_seg.position = Vector3(0, 0.20, -1.86 - float(boom_i) * (seg_z_len - 0.04))
		boom_seg.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.10 + float(boom_i) * 0.04)))
		add_child(boom_seg)
		# Stiffener fin — a slim vertical slab on top of each
		# boom segment (panel-line read at distance).
		var stiffener := MeshInstance3D.new()
		stiffener.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sf_box := BoxMesh.new()
		sf_box.size = Vector3(0.05, 0.10, seg_z_len * 0.85)
		stiffener.mesh = sf_box
		stiffener.position = Vector3(0, 0.20 + seg_h * 0.5 + 0.04, -1.86 - float(boom_i) * (seg_z_len - 0.04))
		stiffener.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.30)))
		add_child(stiffener)

	# Tail-rotor housing — a proper pyloned pod at the end of the
	# boom: a vertical stub-pylon, a circular hub disc, and a 4-blade
	# rotor on a pivot so it actually reads as a real anti-torque
	# rotor and not "two sticks taped to a strut."
	var tail_pylon := MeshInstance3D.new()
	tail_pylon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tp_box := BoxMesh.new()
	tp_box.size = Vector3(0.22, 0.50, 0.30)
	tail_pylon.mesh = tp_box
	tail_pylon.position = Vector3(0, 0.34, -3.00)
	tail_pylon.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
	add_child(tail_pylon)
	# Hub at the side of the pylon — small cylinder facing
	# sideways, reads as the rotor mounting.
	var tail_hub := MeshInstance3D.new()
	tail_hub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var th_cyl := CylinderMesh.new()
	th_cyl.top_radius = 0.10
	th_cyl.bottom_radius = 0.10
	th_cyl.height = 0.12
	th_cyl.radial_segments = 12
	tail_hub.mesh = th_cyl
	tail_hub.rotation.z = PI * 0.5
	tail_hub.position = Vector3(0.18, 0.34, -3.00)
	tail_hub.set_surface_override_material(0, _aircraft_metal_mat(Color(0.08, 0.08, 0.10, 1.0)))
	add_child(tail_hub)
	# Tail rotor — 4 blades on a pivot at the end of the hub,
	# spinning in the YZ plane (rotation.x driven in _process).
	var tail_pivot := Node3D.new()
	tail_pivot.name = "TailRotorPivot"
	tail_pivot.position = Vector3(0.28, 0.34, -3.00)
	add_child(tail_pivot)
	for tail_blade_i: int in 4:
		var tblade := MeshInstance3D.new()
		tblade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var tbb := BoxMesh.new()
		tbb.size = Vector3(0.04, 0.65, 0.08)
		tblade.mesh = tbb
		tblade.rotation.x = float(tail_blade_i) * (PI * 0.5)
		tblade.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.12, 0.9)))
		tail_pivot.add_child(tblade)
	_anvil_tail_rotor = tail_pivot

	# Riveted armor patches on the hull sides — small cube bumps in
	# a row just below the spine, reinforcing the brutalist read.
	var rivet_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.45, 0.40, 0.22, 1.0))
	for rivet_side: int in 2:
		var rsx: float = 0.95 if rivet_side == 0 else -0.95
		for rivet_i: int in 5:
			var rivet := MeshInstance3D.new()
			rivet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var rb := BoxMesh.new()
			rb.size = Vector3(0.10, 0.10, 0.10)
			rivet.mesh = rb
			var rt: float = (float(rivet_i) + 0.5) / 5.0
			var rz: float = -1.30 + rt * 2.6
			rivet.position = Vector3(rsx, 0.12, rz)
			rivet.set_surface_override_material(0, rivet_mat)
			add_child(rivet)

	# Variant overlays. The base build is the gunship hull; the bomber
	# stacks a stubby wing pair with downward-folded tips and a second
	# engine on each side so the silhouette reads as a sturdy
	# traditional bomber. Escort and base gunship take no overlay so
	# the family resemblance is intact.
	if stats and stats.unit_name == "Hammerhead (Bomber)":
		_apply_hammerhead_bomber_extras(body_color)
	elif stats and stats.unit_name == "Hammerhead (Escort)":
		_apply_hammerhead_escort_extras(body_color)


func _apply_hammerhead_bomber_extras(body_color: Color) -> void:
	# Stubby main wings forward of the engines, with downward-folded
	# wing tips. Reads as a heavy carrier-style bomber wing.
	for wing_side: int in 2:
		var wsx: float = 1.0 if wing_side == 0 else -1.0
		var wing := MeshInstance3D.new()
		wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wing_box := BoxMesh.new()
		wing_box.size = Vector3(1.50, 0.10, 0.85)
		wing.mesh = wing_box
		wing.position = Vector3(wsx * 1.85, 0.08, 0.30)
		wing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.10)))
		add_child(wing)
		# Downward folded tip — angled wing-tip stub off the outer
		# edge, rotated ~45° down so the silhouette terminates in a
		# fighter-bomber's anhedral.
		var tip := MeshInstance3D.new()
		tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var tip_box := BoxMesh.new()
		tip_box.size = Vector3(0.42, 0.10, 0.75)
		tip.mesh = tip_box
		tip.position = Vector3(wsx * 2.70, -0.06, 0.25)
		tip.rotation.z = wsx * deg_to_rad(45.0)
		tip.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.20)))
		add_child(tip)
		# Second engine pod, slung under the wing outboard of the
		# fuselage-mounted nacelle. Forward intake + aft thrust block
		# match the gunship's twin-segment language.
		var outer_fwd := MeshInstance3D.new()
		outer_fwd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ofb := BoxMesh.new()
		ofb.size = Vector3(0.42, 0.46, 0.85)
		outer_fwd.mesh = ofb
		outer_fwd.position = Vector3(wsx * 2.10, -0.20, 0.30)
		outer_fwd.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.12)))
		add_child(outer_fwd)
		var outer_aft := MeshInstance3D.new()
		outer_aft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var oab := BoxMesh.new()
		oab.size = Vector3(0.40, 0.44, 0.80)
		outer_aft.mesh = oab
		outer_aft.position = Vector3(wsx * 2.10, -0.22, -0.55)
		outer_aft.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.20)))
		add_child(outer_aft)
		# Outer engine exhaust glow.
		var outer_exh := MeshInstance3D.new()
		outer_exh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var oeb := BoxMesh.new()
		oeb.size = Vector3(0.30, 0.28, 0.14)
		outer_exh.mesh = oeb
		outer_exh.position = Vector3(wsx * 2.10, -0.22, -1.00)
		var oem := StandardMaterial3D.new()
		oem.albedo_color = Color(1.0, 0.45, 0.15, 1.0)
		oem.emission_enabled = true
		oem.emission = Color(1.0, 0.45, 0.10, 1.0)
		oem.emission_energy_multiplier = 2.5
		outer_exh.set_surface_override_material(0, oem)
		add_child(outer_exh)
	# Stretched bomb-bay belly under the central hull -- visible
	# payload undercarriage so the bomber doesn't read as the gunship
	# with extra wings.
	var bay := MeshInstance3D.new()
	bay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bay_box := BoxMesh.new()
	bay_box.size = Vector3(1.20, 0.30, 1.80)
	bay.mesh = bay_box
	bay.position = Vector3(0.0, -0.40, 0.10)
	bay.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.18)))
	add_child(bay)
	# Bay door seam — slim emissive strip running fore/aft so the
	# undercarriage reads as a real bomb-bay door.
	var seam := MeshInstance3D.new()
	seam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var seam_box := BoxMesh.new()
	seam_box.size = Vector3(0.05, 0.04, 1.70)
	seam.mesh = seam_box
	seam.position = Vector3(0.0, -0.55, 0.10)
	var seam_mat := StandardMaterial3D.new()
	seam_mat.albedo_color = Color(1.0, 0.50, 0.18, 1.0)
	seam_mat.emission_enabled = true
	seam_mat.emission = Color(1.0, 0.50, 0.18, 1.0)
	seam_mat.emission_energy_multiplier = 1.4
	seam.set_surface_override_material(0, seam_mat)
	add_child(seam)


func _apply_hammerhead_escort_extras(body_color: Color) -> void:
	# Dorsal AA missile rails -- two pairs of upward-tilted slim
	# missiles mounted above the spine, so the escort silhouettes as
	# 'this one carries the air-to-air payload'.
	for rail_side: int in 2:
		var rsx: float = -0.45 if rail_side == 0 else 0.45
		var rail := MeshInstance3D.new()
		rail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var rb := BoxMesh.new()
		rb.size = Vector3(0.12, 0.08, 1.30)
		rail.mesh = rb
		rail.position = Vector3(rsx, 0.55, 0.10)
		rail.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
		add_child(rail)
		for missile_i: int in 2:
			var missile := MeshInstance3D.new()
			missile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var m_box := BoxMesh.new()
			m_box.size = Vector3(0.14, 0.14, 0.95)
			missile.mesh = m_box
			missile.position = Vector3(rsx, 0.66, -0.30 + float(missile_i) * 0.65)
			missile.rotation.x = deg_to_rad(-12.0)
			missile.set_surface_override_material(0, _aircraft_metal_mat(Color(0.78, 0.78, 0.80, 1.0)))
			add_child(missile)
			var tip := MeshInstance3D.new()
			tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var t_box := BoxMesh.new()
			t_box.size = Vector3(0.12, 0.12, 0.18)
			tip.mesh = t_box
			tip.position = Vector3(rsx, 0.68, -0.30 + float(missile_i) * 0.65 + 0.46)
			tip.rotation.x = deg_to_rad(-12.0)
			var tip_mat := StandardMaterial3D.new()
			tip_mat.albedo_color = Color(0.85, 0.18, 0.15, 1.0)
			tip_mat.emission_enabled = true
			tip_mat.emission = Color(1.0, 0.25, 0.18, 1.0)
			tip_mat.emission_energy_multiplier = 0.9
			tip.set_surface_override_material(0, tip_mat)
			add_child(tip)
	# Countermeasure flare pods on the wing roots -- slim dispensers
	# with three faint-amber tube end caps facing aft so the escort
	# reads as carrying defensive countermeasures alongside the AA
	# missiles.
	for pod_side: int in 2:
		var psx: float = -1.0 if pod_side == 0 else 1.0
		var pod := MeshInstance3D.new()
		pod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pod_box := BoxMesh.new()
		pod_box.size = Vector3(0.20, 0.18, 0.55)
		pod.mesh = pod_box
		pod.position = Vector3(psx * 0.85, -0.22, -0.45)
		pod.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.20)))
		add_child(pod)
		for tube_i: int in 3:
			var cap := MeshInstance3D.new()
			cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var cap_cyl := CylinderMesh.new()
			cap_cyl.top_radius = 0.025
			cap_cyl.bottom_radius = 0.025
			cap_cyl.height = 0.05
			cap_cyl.radial_segments = 8
			cap.mesh = cap_cyl
			cap.rotation.x = PI * 0.5
			cap.position = Vector3(
				psx * 0.85 + (float(tube_i) - 1.0) * 0.06,
				-0.22,
				-0.74,
			)
			var cap_mat := StandardMaterial3D.new()
			cap_mat.albedo_color = Color(1.0, 0.78, 0.20, 1.0)
			cap_mat.emission_enabled = true
			cap_mat.emission = Color(1.0, 0.78, 0.20, 1.0)
			cap_mat.emission_energy_multiplier = 0.6
			cap.set_surface_override_material(0, cap_mat)
			add_child(cap)


func _build_switchblade() -> void:
	# Sable interceptor — slim, angular, swept-back wings, cockpit
	# canopy with cool-blue glow.
	var team: Color = _team_color()
	var body_color := Color(0.10, 0.11, 0.13, 1.0)

	# Slim fuselage.
	var fuselage := MeshInstance3D.new()
	fuselage.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fuse_box := BoxMesh.new()
	fuse_box.size = Vector3(0.7, 0.5, 3.4)
	fuselage.mesh = fuse_box
	fuselage.set_surface_override_material(0, _aircraft_metal_mat(body_color))
	add_child(fuselage)

	# Fuselage-to-nose fairing — intermediate-sized box that absorbs the
	# step from fuselage cross-section (0.7 x 0.5) down to nose
	# (0.45 x 0.35) so the player doesn't see a hard shoulder mid-craft.
	var fairing_blend := MeshInstance3D.new()
	fairing_blend.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fairing_box := BoxMesh.new()
	fairing_box.size = Vector3(0.58, 0.42, 0.32)
	fairing_blend.mesh = fairing_box
	fairing_blend.position.z = 1.50
	fairing_blend.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
	add_child(fairing_blend)
	# Tapering nose — short box section + a true cone tip so the front
	# isn't a hard right-angle slab. The cone uses very few radial
	# segments so the silhouette stays faceted (Sable angular language)
	# instead of going full smooth.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_box := BoxMesh.new()
	nose_box.size = Vector3(0.45, 0.35, 0.7)
	nose.mesh = nose_box
	nose.position.z = 2.00
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.2)))
	add_child(nose)
	var nose_tip := MeshInstance3D.new()
	nose_tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tip_cone := CylinderMesh.new()
	tip_cone.top_radius = 0.0
	tip_cone.bottom_radius = 0.22
	tip_cone.height = 0.55
	tip_cone.radial_segments = 6  # faceted, not smooth
	nose_tip.mesh = tip_cone
	nose_tip.rotation.x = PI * 0.5  # cone points along +Z (point forward)
	nose_tip.position.z = 2.55
	nose_tip.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.25)))
	add_child(nose_tip)

	# Swept-back wings (triangular slabs rotated).
	for side: int in 2:
		var sx: float = 1.0 if side == 0 else -1.0
		var wing := MeshInstance3D.new()
		wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wing_box := BoxMesh.new()
		wing_box.size = Vector3(1.5, 0.06, 1.1)
		wing.mesh = wing_box
		wing.position = Vector3(sx * 0.95, 0, -0.4)
		wing.rotation.y = sx * deg_to_rad(-32.0)
		wing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.1)))
		add_child(wing)
		# Wing-root fairing — short tapered box bridging the wing's
		# trailing-edge root into the fuselage rear so the wing isn't
		# visually disconnected from the body. Tapered from wing
		# thickness up to a short fuselage-side fairing.
		var fairing := MeshInstance3D.new()
		fairing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var fb := BoxMesh.new()
		fb.size = Vector3(0.18, 0.18, 0.55)
		fairing.mesh = fb
		fairing.position = Vector3(sx * 0.30, 0.04, -0.55)
		fairing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.1)))
		add_child(fairing)
		# Forward-edge wing taper — narrow tip wedge that the leading
		# edge fades into so the outer wing reads as tapered, not
		# rectangular. Sits at the wing's outer-front corner.
		var tip_taper := MeshInstance3D.new()
		tip_taper.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ttp := PrismMesh.new()
		ttp.size = Vector3(0.45, 0.06, 0.30)
		ttp.left_to_right = 0.0  # peaks at the outer edge
		tip_taper.mesh = ttp
		tip_taper.position = Vector3(sx * 1.40, 0.0, -0.05)
		tip_taper.rotation.y = sx * deg_to_rad(-32.0) + (PI if sx > 0.0 else 0.0)
		tip_taper.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.12)))
		add_child(tip_taper)

		# Wingtip pulse-cannon barrel.
		var cannon := MeshInstance3D.new()
		cannon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cannon_box := BoxMesh.new()
		cannon_box.size = Vector3(0.10, 0.10, 0.7)
		cannon.mesh = cannon_box
		cannon.position = Vector3(sx * 1.55, 0, -0.05)
		cannon.set_surface_override_material(0, _aircraft_metal_mat(Color(0.06, 0.06, 0.08)))
		add_child(cannon)

	# Twin tail fins (V-tail).
	for side: int in 2:
		var sx: float = 1.0 if side == 0 else -1.0
		var fin := MeshInstance3D.new()
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var fin_box := BoxMesh.new()
		fin_box.size = Vector3(0.08, 0.7, 0.6)
		fin.mesh = fin_box
		fin.position = Vector3(sx * 0.25, 0.4, -1.5)
		fin.rotation.z = sx * deg_to_rad(20.0)
		fin.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
		add_child(fin)

	# Cockpit canopy — slimmer + tilted forward so the silhouette
	# slopes into the nose instead of standing up as a square box.
	var canopy := MeshInstance3D.new()
	canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var canopy_box := BoxMesh.new()
	canopy_box.size = Vector3(0.36, 0.14, 1.20)
	canopy.mesh = canopy_box
	canopy.position = Vector3(0, 0.30, 0.55)
	# Forward rake — a small downward tilt so the front of the canopy
	# meets the fuselage at an angle instead of a hard 90° corner.
	canopy.rotation.x = deg_to_rad(-9.0)
	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.albedo_color = team
	canopy_mat.emission_enabled = true
	canopy_mat.emission = team
	canopy_mat.emission_energy_multiplier = 2.2
	canopy.set_surface_override_material(0, canopy_mat)
	add_child(canopy)

	# Engine glow at the back.
	var exhaust := MeshInstance3D.new()
	exhaust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var exh_box := BoxMesh.new()
	exh_box.size = Vector3(0.45, 0.35, 0.18)
	exhaust.mesh = exh_box
	exhaust.position.z = -1.7
	var exh_mat := StandardMaterial3D.new()
	exh_mat.albedo_color = team
	exh_mat.emission_enabled = true
	exh_mat.emission = team
	exh_mat.emission_energy_multiplier = 3.0
	exhaust.set_surface_override_material(0, exh_mat)
	add_child(exhaust)

	# Detail polish: wingtip nav lights + nose air intake + spine panel
	# strip. Fills out the silhouette beyond a few flat slabs.
	var nav_mat := StandardMaterial3D.new()
	nav_mat.albedo_color = SABLE_NEON_PALE
	nav_mat.emission_enabled = true
	nav_mat.emission = SABLE_NEON_PALE
	nav_mat.emission_energy_multiplier = 2.6
	nav_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for nav_side: int in 2:
		var nsx: float = 1.0 if nav_side == 0 else -1.0
		var nav := MeshInstance3D.new()
		nav.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var nav_box := BoxMesh.new()
		nav_box.size = Vector3(0.10, 0.06, 0.10)
		nav.mesh = nav_box
		nav.position = Vector3(nsx * 1.62, 0.02, -0.20)
		nav.set_surface_override_material(0, nav_mat)
		add_child(nav)
	# Nose intake — recessed dark slit at the front of the nose cone.
	var intake := MeshInstance3D.new()
	intake.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var intake_box := BoxMesh.new()
	intake_box.size = Vector3(0.34, 0.10, 0.20)
	intake.mesh = intake_box
	intake.position = Vector3(0, -0.12, 2.32)
	intake.set_surface_override_material(0, _aircraft_metal_mat(Color(0.04, 0.04, 0.06, 1.0)))
	add_child(intake)
	# Spine — short emissive cyan strip running the upper fuselage.
	var spine := MeshInstance3D.new()
	spine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var spine_box := BoxMesh.new()
	spine_box.size = Vector3(0.06, 0.04, 1.5)
	spine.mesh = spine_box
	spine.position = Vector3(0, 0.27, -0.4)
	var spine_mat := StandardMaterial3D.new()
	spine_mat.albedo_color = SABLE_NEON_PALE
	spine_mat.emission_enabled = true
	spine_mat.emission = SABLE_NEON_PALE
	spine_mat.emission_energy_multiplier = 1.8
	spine.set_surface_override_material(0, spine_mat)
	add_child(spine)

	# Sable stealth-fighter polish — extra silhouette elements that
	# read as B-2 / F-117 cousins, fitting the corp-stealth faction
	# profile. Forward canard wings, a slim nose probe, twin
	# outward-canted thrust vectoring nozzles at the back, and a
	# sharper violet under-glow strip along the belly.
	var canard_mat: StandardMaterial3D = _aircraft_metal_mat(body_color.darkened(0.15))
	for canard_side: int in 2:
		var csx: float = 1.0 if canard_side == 0 else -1.0
		var canard := MeshInstance3D.new()
		canard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var canard_box := BoxMesh.new()
		canard_box.size = Vector3(0.75, 0.04, 0.45)
		canard.mesh = canard_box
		canard.position = Vector3(csx * 0.50, 0.18, 1.20)
		canard.rotation.y = csx * deg_to_rad(-22.0)
		canard.set_surface_override_material(0, canard_mat)
		add_child(canard)
		# Canard root fairing — small bump that ties the canard's root
		# to the nose so it doesn't read as bolted-on plates.
		var c_fairing := MeshInstance3D.new()
		c_fairing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cfb := BoxMesh.new()
		cfb.size = Vector3(0.14, 0.14, 0.32)
		c_fairing.mesh = cfb
		c_fairing.position = Vector3(csx * 0.22, 0.18, 1.20)
		c_fairing.set_surface_override_material(0, canard_mat)
		add_child(c_fairing)
	# Nose probe — slim cylinder extending past the nose cone tip.
	var probe := MeshInstance3D.new()
	probe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var probe_cyl := CylinderMesh.new()
	probe_cyl.top_radius = 0.04
	probe_cyl.bottom_radius = 0.05
	probe_cyl.height = 0.55
	probe_cyl.radial_segments = 6
	probe.mesh = probe_cyl
	probe.rotation.x = PI * 0.5
	probe.position = Vector3(0, -0.08, 2.70)
	probe.set_surface_override_material(0, _aircraft_metal_mat(Color(0.18, 0.18, 0.20, 1.0)))
	add_child(probe)
	# Twin thrust-vectoring nozzles at the rear, canted outward.
	# Build them as a dark housing with the pink afterburner glow
	# RECESSED inside — the prior solid-pink cylinders read as plastic
	# tubes glued to the back; this reads as proper engine bells with
	# a hot core (playtest 2026-05-15).
	var nozzle_shell_mat: StandardMaterial3D = _aircraft_metal_mat(Color(0.05, 0.05, 0.06, 1.0))
	var nozzle_core_mat := StandardMaterial3D.new()
	nozzle_core_mat.albedo_color = SABLE_NEON_PALE
	nozzle_core_mat.emission_enabled = true
	nozzle_core_mat.emission = SABLE_NEON_PALE
	nozzle_core_mat.emission_energy_multiplier = 4.0
	nozzle_core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for nozzle_side: int in 2:
		var nzsx: float = 1.0 if nozzle_side == 0 else -1.0
		# Outer bell — rear flare with the back face uncapped so looking
		# down the throat reveals the recessed glow core instead of a
		# closed plate.
		var nozzle := MeshInstance3D.new()
		nozzle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var nz_cyl := CylinderMesh.new()
		nz_cyl.top_radius = 0.16
		nz_cyl.bottom_radius = 0.22
		nz_cyl.height = 0.40
		nz_cyl.radial_segments = 12
		nz_cyl.cap_bottom = false  # open rear face — view inside the bell
		nozzle.mesh = nz_cyl
		nozzle.rotation.x = PI * 0.5
		nozzle.rotation.y = nzsx * deg_to_rad(-12.0)
		nozzle.position = Vector3(nzsx * 0.30, 0.04, -1.85)
		nozzle.set_surface_override_material(0, nozzle_shell_mat)
		add_child(nozzle)
		# Hot core disc — sits flush with (or just behind) the rear
		# face so the pink glow is visible from above + from behind
		# instead of being hidden inside a dark cup. Slightly smaller
		# than the bell aperture so the dark rim still frames the glow.
		var glow := MeshInstance3D.new()
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var glow_cyl := CylinderMesh.new()
		glow_cyl.top_radius = 0.18
		glow_cyl.bottom_radius = 0.18
		glow_cyl.height = 0.06
		glow_cyl.radial_segments = 14
		glow.mesh = glow_cyl
		glow.rotation.x = PI * 0.5
		glow.rotation.y = nzsx * deg_to_rad(-12.0)
		# Place the glow disc just at the rear aperture (slight outward
		# offset so it pokes through visibly even at oblique RTS angles).
		var glow_offset: Vector3 = Vector3(0.0, 0.0, -0.02).rotated(Vector3.UP, nzsx * deg_to_rad(-12.0))
		glow.position = Vector3(nzsx * 0.30, 0.04, -2.05) + glow_offset
		glow.set_surface_override_material(0, nozzle_core_mat)
		add_child(glow)
		# Side throat slit — narrow emissive band wrapping the bell's
		# upper side so the glow reads from straight above (the standard
		# RTS camera angle) without putting solid pink everywhere.
		var slit := MeshInstance3D.new()
		slit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var slit_box := BoxMesh.new()
		slit_box.size = Vector3(0.04, 0.06, 0.22)
		slit.mesh = slit_box
		slit.rotation.y = nzsx * deg_to_rad(-12.0)
		slit.position = Vector3(nzsx * 0.30, 0.20, -1.85)
		slit.set_surface_override_material(0, nozzle_core_mat)
		add_child(slit)
	# Sharper violet under-glow strip along the belly so the
	# silhouette has a "highlighted edge" read from below.
	var belly := MeshInstance3D.new()
	belly.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var belly_box := BoxMesh.new()
	belly_box.size = Vector3(0.10, 0.04, 2.5)
	belly.mesh = belly_box
	belly.position = Vector3(0, -0.27, 0.1)
	belly.set_surface_override_material(0, spine_mat)
	add_child(belly)

	# Asymmetric sensor pod on the right wing root — per 03_factions
	# §"Sable Visual Language: deliberately asymmetric". One stubby
	# housing + an angled antenna stub with a violet emissive tip,
	# mounted on the +X side only so the silhouette breaks mirror
	# symmetry from above. Doesn't compromise flight-shape readability.
	var sensor_housing := MeshInstance3D.new()
	sensor_housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sh_box := BoxMesh.new()
	sh_box.size = Vector3(0.22, 0.20, 0.36)
	sensor_housing.mesh = sh_box
	sensor_housing.position = Vector3(0.95, 0.18, 0.05)
	sensor_housing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.12)))
	add_child(sensor_housing)
	# Angled antenna stub on top of the housing.
	var antenna := MeshInstance3D.new()
	antenna.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ant_cyl := CylinderMesh.new()
	ant_cyl.top_radius = 0.025
	ant_cyl.bottom_radius = 0.04
	ant_cyl.height = 0.42
	ant_cyl.radial_segments = 6
	antenna.mesh = ant_cyl
	antenna.rotation.z = deg_to_rad(-18.0)
	antenna.position = Vector3(0.95 + sin(deg_to_rad(-18.0)) * 0.21, 0.18 + cos(deg_to_rad(-18.0)) * 0.21, 0.05)
	antenna.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.12, 1.0)))
	add_child(antenna)
	# Violet emissive tip — the Sable signature dot.
	var ant_tip := MeshInstance3D.new()
	ant_tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tip_sph := SphereMesh.new()
	tip_sph.radius = 0.05
	tip_sph.height = 0.10
	ant_tip.mesh = tip_sph
	ant_tip.position = Vector3(0.95 + sin(deg_to_rad(-18.0)) * 0.42, 0.18 + cos(deg_to_rad(-18.0)) * 0.42, 0.05)
	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = SABLE_NEON_PALE
	tip_mat.emission_enabled = true
	tip_mat.emission = SABLE_NEON_PALE
	tip_mat.emission_energy_multiplier = 2.4
	tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ant_tip.set_surface_override_material(0, tip_mat)
	add_child(ant_tip)

	# Variant overlays. Dogfighter mounts twin gunpods under each
	# wing root; Strafe Runner mounts a single longer belly cannon
	# along the underside of the fuselage.
	if stats and stats.unit_name == "Switchblade (Dogfighter)":
		_apply_switchblade_dogfighter_extras(body_color)
	elif stats and stats.unit_name == "Switchblade (Strafe Runner)":
		_apply_switchblade_strafe_extras(body_color)


func _apply_switchblade_dogfighter_extras(body_color: Color) -> void:
	# Twin underwing gunpods -- short stubby barrels mounted at the
	# wing roots so the silhouette pinches forward into 'fighter
	# bristling with guns'. Each pod has a faint cyan emissive cap
	# matching the Switchblade's canopy palette.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		# Pod housing.
		var pod := MeshInstance3D.new()
		pod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pod_box := BoxMesh.new()
		pod_box.size = Vector3(0.18, 0.18, 0.85)
		pod.mesh = pod_box
		pod.position = Vector3(sx * 0.55, -0.18, 0.30)
		pod.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.12)))
		add_child(pod)
		# Twin barrels protruding forward from the pod.
		for barrel_i: int in 2:
			var bx: float = -0.05 if barrel_i == 0 else 0.05
			var barrel := MeshInstance3D.new()
			barrel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var bcyl := CylinderMesh.new()
			bcyl.top_radius = 0.025
			bcyl.bottom_radius = 0.030
			bcyl.height = 0.42
			bcyl.radial_segments = 10
			barrel.mesh = bcyl
			barrel.rotation.x = PI * 0.5
			barrel.position = Vector3(sx * 0.55 + bx, -0.18, 0.92)
			barrel.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.11, 1.0)))
			add_child(barrel)
		# Faint cyan emissive cap on the back of each pod -- targeting
		# pickup on a Sable interceptor.
		var cap := MeshInstance3D.new()
		cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cap_box := BoxMesh.new()
		cap_box.size = Vector3(0.10, 0.10, 0.04)
		cap.mesh = cap_box
		cap.position = Vector3(sx * 0.55, -0.18, -0.10)
		var cap_mat := StandardMaterial3D.new()
		cap_mat.albedo_color = SABLE_NEON_PALE
		cap_mat.emission_enabled = true
		cap_mat.emission = SABLE_NEON_PALE
		cap_mat.emission_energy_multiplier = 1.6
		cap.set_surface_override_material(0, cap_mat)
		add_child(cap)


func _apply_switchblade_strafe_extras(body_color: Color) -> void:
	# Belly cannon -- single long ventral barrel running fore-aft
	# under the fuselage, with a fairing that wraps around it. Reads
	# as 'this one runs strafing passes' rather than 'this one
	# dogfights'.
	var fairing := MeshInstance3D.new()
	fairing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fb := BoxMesh.new()
	fb.size = Vector3(0.32, 0.18, 1.50)
	fairing.mesh = fb
	fairing.position = Vector3(0.0, -0.34, 0.20)
	fairing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.18)))
	add_child(fairing)
	# Long single barrel poking out the front of the fairing.
	var barrel := MeshInstance3D.new()
	barrel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var b_cyl := CylinderMesh.new()
	b_cyl.top_radius = 0.05
	b_cyl.bottom_radius = 0.06
	b_cyl.height = 0.85
	b_cyl.radial_segments = 12
	barrel.mesh = b_cyl
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0.0, -0.34, 1.30)
	barrel.set_surface_override_material(0, _aircraft_metal_mat(Color(0.08, 0.08, 0.10, 1.0)))
	add_child(barrel)
	# Muzzle brake ring at the front of the barrel for silhouette.
	var brake := MeshInstance3D.new()
	brake.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var brake_cyl := CylinderMesh.new()
	brake_cyl.top_radius = 0.085
	brake_cyl.bottom_radius = 0.085
	brake_cyl.height = 0.10
	brake_cyl.radial_segments = 10
	brake.mesh = brake_cyl
	brake.rotation.x = PI * 0.5
	brake.position = Vector3(0.0, -0.34, 1.65)
	brake.set_surface_override_material(0, _aircraft_metal_mat(Color(0.06, 0.06, 0.07, 1.0)))
	add_child(brake)
	# Twin ammo feed boxes flanking the fairing aft so the strafer
	# reads as carrying ammo for its big gun.
	for side: int in 2:
		var sx: float = -1.0 if side == 0 else 1.0
		var feed := MeshInstance3D.new()
		feed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var feed_box := BoxMesh.new()
		feed_box.size = Vector3(0.18, 0.18, 0.42)
		feed.mesh = feed_box
		feed.position = Vector3(sx * 0.22, -0.30, -0.30)
		feed.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.30)))
		add_child(feed)


const SABLE_NEON_PALE := Color(0.78, 0.35, 1.0, 1.0)  # violet, paired with unit/building Sable accent


func _build_wraith() -> void:
	## Sable stealth bomber — flat blade silhouette with a deep
	## central bomb bay glow + swept rear empennage. Reads as
	## "stealth flying-wing", much wider and lower than the
	## Switchblade. The Stealth system handles concealment fade
	## via GeometryInstance3D.transparency.
	var team: Color = _team_color()
	var body_color := Color(0.06, 0.06, 0.10, 1.0)

	# Fuselage broken into a tapered four-section spine instead of a
	# single 2.2×0.30×3.0 brick. Going (back to front): rear vent
	# block (narrow), mid-rear bay (wide, deep), mid-front lift
	# section (full width), and a slim front beak (narrowest, tall
	# enough to take the cockpit blister). Each section nudges the
	# colour one shade so the joins read.
	var seg_back := MeshInstance3D.new()
	seg_back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var seg_back_box := BoxMesh.new()
	seg_back_box.size = Vector3(1.55, 0.22, 0.85)
	seg_back.mesh = seg_back_box
	seg_back.position = Vector3(0, -0.02, -1.05)
	seg_back.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.08)))
	add_child(seg_back)

	var seg_mid_rear := MeshInstance3D.new()
	seg_mid_rear.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var seg_mr_box := BoxMesh.new()
	seg_mr_box.size = Vector3(2.2, 0.32, 0.95)
	seg_mid_rear.mesh = seg_mr_box
	seg_mid_rear.position = Vector3(0, 0.0, -0.30)
	seg_mid_rear.set_surface_override_material(0, _aircraft_metal_mat(body_color))
	add_child(seg_mid_rear)

	var seg_mid_fwd := MeshInstance3D.new()
	seg_mid_fwd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var seg_mf_box := BoxMesh.new()
	seg_mf_box.size = Vector3(2.0, 0.30, 0.85)
	seg_mid_fwd.mesh = seg_mf_box
	seg_mid_fwd.position = Vector3(0, 0.01, 0.50)
	seg_mid_fwd.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.04)))
	add_child(seg_mid_fwd)

	var seg_beak := MeshInstance3D.new()
	seg_beak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var seg_beak_box := BoxMesh.new()
	seg_beak_box.size = Vector3(1.10, 0.36, 0.90)
	seg_beak.mesh = seg_beak_box
	seg_beak.position = Vector3(0, 0.04, 1.20)
	seg_beak.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.10)))
	add_child(seg_beak)

	# Two slim triangular gap-fillers tucked between segments so the
	# steps in width don't read as ledges from above.
	for filler_z: int in 2:
		var filler := MeshInstance3D.new()
		filler.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ff := BoxMesh.new()
		ff.size = Vector3(2.0, 0.05, 0.30)
		filler.mesh = ff
		var fz: float = 0.10 if filler_z == 0 else -0.85
		var frot: float = 0.18 if filler_z == 0 else -0.18
		filler.position = Vector3(0, 0.13, fz)
		filler.rotation.x = frot
		filler.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.16)))
		add_child(filler)

	# Forward delta wings — large swept slabs angled out from the
	# nose, giving the unmistakable stealth-bomber silhouette.
	for wing_side: int in 2:
		var wsx: float = 1.0 if wing_side == 0 else -1.0
		var wing := MeshInstance3D.new()
		wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wing_box := BoxMesh.new()
		wing_box.size = Vector3(2.2, 0.10, 1.5)
		wing.mesh = wing_box
		wing.position = Vector3(wsx * 1.3, 0.0, 0.5)
		wing.rotation.y = wsx * deg_to_rad(-32.0)
		wing.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.10)))
		add_child(wing)

	# Bomb-bay glow on the underside — a violet emissive recess
	# down the spine. Carries the Sable identity + signals "armed".
	var bay_mat := StandardMaterial3D.new()
	bay_mat.albedo_color = SABLE_NEON_PALE
	bay_mat.emission_enabled = true
	bay_mat.emission = SABLE_NEON_PALE
	bay_mat.emission_energy_multiplier = 1.4
	bay_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var bay := MeshInstance3D.new()
	bay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bay_box := BoxMesh.new()
	bay_box.size = Vector3(0.55, 0.06, 1.6)
	bay.mesh = bay_box
	bay.position = Vector3(0, -0.18, 0.0)
	bay.set_surface_override_material(0, bay_mat)
	add_child(bay)

	# Twin rear stabilizer fins — small swept verticals at the back.
	for fin_side: int in 2:
		var fsx: float = 1.0 if fin_side == 0 else -1.0
		var fin := MeshInstance3D.new()
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var fin_box := BoxMesh.new()
		fin_box.size = Vector3(0.06, 0.40, 0.55)
		fin.mesh = fin_box
		fin.position = Vector3(fsx * 0.55, 0.20, -1.30)
		fin.rotation.z = fsx * deg_to_rad(18.0)
		fin.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
		add_child(fin)

	# Centred dorsal cockpit blister — slim violet-tinted dome.
	var cockpit := MeshInstance3D.new()
	cockpit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cockpit_sphere := SphereMesh.new()
	cockpit_sphere.radius = 0.22
	cockpit_sphere.height = 0.30
	cockpit.mesh = cockpit_sphere
	cockpit.position = Vector3(0, 0.18, 0.85)
	var cockpit_mat := StandardMaterial3D.new()
	cockpit_mat.albedo_color = Color(0.05, 0.06, 0.10, 1.0)
	cockpit_mat.emission_enabled = true
	cockpit_mat.emission = SABLE_NEON_PALE
	cockpit_mat.emission_energy_multiplier = 0.65
	cockpit_mat.metallic = 0.7
	cockpit_mat.roughness = 0.18
	cockpit.set_surface_override_material(0, cockpit_mat)
	add_child(cockpit)

	# Slim team-colour edge sliver along the front leading edge of
	# each wing — minimal player-color paint for a stealth airframe.
	var team_mat := StandardMaterial3D.new()
	team_mat.albedo_color = team
	team_mat.emission_enabled = true
	team_mat.emission = team
	team_mat.emission_energy_multiplier = 1.4
	for ts: int in 2:
		var tsx: float = 1.0 if ts == 0 else -1.0
		var sliver := MeshInstance3D.new()
		sliver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sb := BoxMesh.new()
		sb.size = Vector3(0.06, 0.04, 1.10)
		sliver.mesh = sb
		sliver.position = Vector3(tsx * 1.30, 0.06, 0.95)
		sliver.rotation.y = tsx * deg_to_rad(-32.0)
		sliver.set_surface_override_material(0, team_mat)
		add_child(sliver)

	# --- Polish layer ---
	# Sleeker nose cone -- a tapered cone capping the boxy beak so
	# the front silhouette reads as 'stealth blade' rather than
	# 'cardboard wedge'.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_cyl := CylinderMesh.new()
	nose_cyl.top_radius = 0.0
	nose_cyl.bottom_radius = 0.32
	nose_cyl.height = 0.95
	nose_cyl.radial_segments = 12
	nose.mesh = nose_cyl
	nose.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
	nose.position = Vector3(0, 0.04, 1.95)
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.12)))
	add_child(nose)
	# Twin engine nacelles tucked under the rear fuselage with
	# violet thruster glow at the back -- gives the bomber an
	# obvious propulsion read instead of flying via faith.
	for nac_side: int in 2:
		var nsx: float = -1.0 if nac_side == 0 else 1.0
		var nacelle := MeshInstance3D.new()
		nacelle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var n_cyl := CylinderMesh.new()
		n_cyl.top_radius = 0.18
		n_cyl.bottom_radius = 0.20
		n_cyl.height = 1.05
		n_cyl.radial_segments = 12
		nacelle.mesh = n_cyl
		nacelle.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
		nacelle.position = Vector3(nsx * 0.45, -0.08, -0.85)
		nacelle.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.18)))
		add_child(nacelle)
		# Hot exhaust ring at the rear of the nacelle.
		var exhaust := MeshInstance3D.new()
		exhaust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ex_cyl := CylinderMesh.new()
		ex_cyl.top_radius = 0.13
		ex_cyl.bottom_radius = 0.13
		ex_cyl.height = 0.12
		ex_cyl.radial_segments = 12
		exhaust.mesh = ex_cyl
		exhaust.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
		exhaust.position = Vector3(nsx * 0.45, -0.08, -1.42)
		var ex_mat := StandardMaterial3D.new()
		ex_mat.albedo_color = SABLE_NEON_PALE
		ex_mat.emission_enabled = true
		ex_mat.emission = SABLE_NEON_PALE
		ex_mat.emission_energy_multiplier = 2.6
		ex_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		exhaust.set_surface_override_material(0, ex_mat)
		add_child(exhaust)
	# Underwing hardpoints + a slim bomb pylon under each wing so
	# the bomber visibly carries ordnance.
	for hp_side: int in 2:
		var hsx: float = 1.0 if hp_side == 0 else -1.0
		var pylon := MeshInstance3D.new()
		pylon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var py_box := BoxMesh.new()
		py_box.size = Vector3(0.10, 0.12, 0.40)
		pylon.mesh = py_box
		pylon.position = Vector3(hsx * 1.10, -0.10, 0.55)
		pylon.rotation.y = hsx * deg_to_rad(-32.0)
		pylon.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.14)))
		add_child(pylon)
		var bomb := MeshInstance3D.new()
		bomb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var bm_cyl := CylinderMesh.new()
		bm_cyl.top_radius = 0.10
		bm_cyl.bottom_radius = 0.10
		bm_cyl.height = 0.85
		bm_cyl.radial_segments = 10
		bomb.mesh = bm_cyl
		bomb.rotation = Vector3(deg_to_rad(90.0), hsx * deg_to_rad(-32.0), 0.0)
		bomb.position = Vector3(hsx * 1.10, -0.20, 0.55)
		bomb.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.20)))
		add_child(bomb)
	# Wing-tip canted winglets so the wings don't end in a flat
	# slab. Small triangular shards angled up from each wing tip.
	for wt_side: int in 2:
		var wtsx: float = 1.0 if wt_side == 0 else -1.0
		var winglet := MeshInstance3D.new()
		winglet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wt_box := BoxMesh.new()
		wt_box.size = Vector3(0.08, 0.32, 0.55)
		winglet.mesh = wt_box
		winglet.position = Vector3(wtsx * 2.05, 0.12, 0.10)
		winglet.rotation = Vector3(0.0, wtsx * deg_to_rad(-32.0), wtsx * deg_to_rad(28.0))
		winglet.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.16)))
		add_child(winglet)
	# Dorsal spine ridge -- thin raised strip running the length
	# of the body so the centreline reads as a deliberate seam.
	var spine := MeshInstance3D.new()
	spine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sp_box := BoxMesh.new()
	sp_box.size = Vector3(0.14, 0.06, 2.40)
	spine.mesh = sp_box
	spine.position = Vector3(0, 0.15, 0.10)
	spine.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.20)))
	add_child(spine)

	# Asymmetric command-uplink pod on the right side of the cockpit
	# blister — per 03_factions §"Sable Visual Language: deliberately
	# asymmetric". A short angled mast with a violet emissive sensor
	# at the tip; only on the +X side so the silhouette breaks
	# symmetry from above without compromising the stealth-blade read.
	var cmd_pod := MeshInstance3D.new()
	cmd_pod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cp_box := BoxMesh.new()
	cp_box.size = Vector3(0.18, 0.14, 0.34)
	cmd_pod.mesh = cp_box
	cmd_pod.position = Vector3(0.42, 0.20, 0.80)
	cmd_pod.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.14)))
	add_child(cmd_pod)
	var cmd_mast := MeshInstance3D.new()
	cmd_mast.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cm_cyl := CylinderMesh.new()
	cm_cyl.top_radius = 0.025
	cm_cyl.bottom_radius = 0.04
	cm_cyl.height = 0.42
	cm_cyl.radial_segments = 6
	cmd_mast.mesh = cm_cyl
	cmd_mast.rotation.z = deg_to_rad(-15.0)
	cmd_mast.position = Vector3(0.42 + sin(deg_to_rad(-15.0)) * 0.21, 0.20 + cos(deg_to_rad(-15.0)) * 0.21, 0.80)
	cmd_mast.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.12)))
	add_child(cmd_mast)
	var cmd_tip := MeshInstance3D.new()
	cmd_tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ct_sph := SphereMesh.new()
	ct_sph.radius = 0.06
	ct_sph.height = 0.12
	cmd_tip.mesh = ct_sph
	cmd_tip.position = Vector3(0.42 + sin(deg_to_rad(-15.0)) * 0.42, 0.20 + cos(deg_to_rad(-15.0)) * 0.42, 0.80)
	var cmd_tip_mat := StandardMaterial3D.new()
	cmd_tip_mat.albedo_color = SABLE_NEON_PALE
	cmd_tip_mat.emission_enabled = true
	cmd_tip_mat.emission = SABLE_NEON_PALE
	cmd_tip_mat.emission_energy_multiplier = 2.4
	cmd_tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmd_tip.set_surface_override_material(0, cmd_tip_mat)
	add_child(cmd_tip)


func _build_heliarch_firefly_swarm() -> void:
	## Heliarch incendiary drone pack. Six small chunky drones in a
	## loose V formation; warm sooted body + brass detonator bulb + a
	## tiny amber ember glow on the underside (sells "lit / smoldering"
	## without needing a particle system). The bomblets are spawned via
	## the regular projectile path on fire.
	const HELIARCH_BRASS_FF: Color = Color(0.55, 0.40, 0.20, 1.0)
	const SOOTED_FF: Color = Color(0.22, 0.18, 0.14, 1.0)
	const EMBER_FF: Color = Color(1.0, 0.55, 0.18, 1.0)
	var team: Color = _team_color()
	var drone_size: float = 0.55
	var ring_offsets: Array[Vector3] = _v_formation_offsets(6, drone_size * 1.6)
	for i: int in 6:
		var drone := Node3D.new()
		drone.position = ring_offsets[i]
		drone.set_meta("bob_phase", randf() * TAU)
		add_child(drone)
		_drone_meshes.append(drone)
		# Squat hex-prism body — short cylinder, six sides, sells
		# "purpose-built munition" without being a fighter.
		var body := MeshInstance3D.new()
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var body_cyl := CylinderMesh.new()
		body_cyl.top_radius = drone_size * 0.35
		body_cyl.bottom_radius = drone_size * 0.45
		body_cyl.height = drone_size * 0.30
		body_cyl.radial_segments = 6
		body.mesh = body_cyl
		body.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_FF))
		drone.add_child(body)
		# Brass ring around the equator — Heliarch trim.
		var ring := MeshInstance3D.new()
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ring_torus := TorusMesh.new()
		ring_torus.inner_radius = drone_size * 0.38
		ring_torus.outer_radius = drone_size * 0.46
		ring_torus.rings = 10
		ring_torus.ring_segments = 4
		ring.mesh = ring_torus
		ring.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_FF))
		drone.add_child(ring)
		# Amber ember underglow — small emissive disc on the bottom.
		var ember := MeshInstance3D.new()
		ember.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ember_cyl := CylinderMesh.new()
		ember_cyl.top_radius = drone_size * 0.18
		ember_cyl.bottom_radius = drone_size * 0.18
		ember_cyl.height = 0.02
		ember_cyl.radial_segments = 8
		ember.mesh = ember_cyl
		ember.position.y = -drone_size * 0.16
		var ember_mat := StandardMaterial3D.new()
		ember_mat.albedo_color = EMBER_FF
		ember_mat.emission_enabled = true
		ember_mat.emission = EMBER_FF
		ember_mat.emission_energy_multiplier = 2.4
		ember_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ember.set_surface_override_material(0, ember_mat)
		drone.add_child(ember)
		# Team-colour spine stripe so owner-ID is readable.
		var stripe := MeshInstance3D.new()
		stripe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var stripe_box := BoxMesh.new()
		stripe_box.size = Vector3(drone_size * 0.10, drone_size * 0.06, drone_size * 0.65)
		stripe.mesh = stripe_box
		stripe.position.y = drone_size * 0.18
		var stripe_mat := StandardMaterial3D.new()
		stripe_mat.albedo_color = team
		stripe_mat.emission_enabled = true
		stripe_mat.emission = team
		stripe_mat.emission_energy_multiplier = 1.0
		stripe.set_surface_override_material(0, stripe_mat)
		drone.add_child(stripe)


func _build_heliarch_condor() -> void:
	## Heliarch Águila gunship (file/function name dates to before the
	## 2026-05-19 in-game name swap; this IS the gunship that displays
	## as "Águila"). Full rebuild 2026-05-19 per user feedback:
	##   - Previous build placed the floodlight at -Z and engines at +Z.
	##     The aircraft.gd look_at hack flips so +Z is the travel
	##     direction, which made the old gunship visibly fly TAIL-FIRST
	##     (floodlight pointing AWAY from the move vector).
	##   - New build follows the +Z = forward convention everywhere.
	##   - Replaced the twin-tail-engine layout with a VTOL silhouette:
	##     two large wing-mounted rotors on tilt nacelles, no main
	##     rotor on top, no tail rotor. Heavy scifi gunship aesthetic.
	##   - Significantly more player-color (broad team-tinted spine
	##     panels on the fuselage flanks + wing leading edges + tail
	##     fin chevron) so the airframe is unmistakably owned at a
	##     glance from the minimap zoom.
	const HELIARCH_BRASS_CD: Color = Color(0.65, 0.45, 0.18, 1.0)
	const DARK_BRASS_CD: Color = Color(0.40, 0.26, 0.10, 1.0)
	const SOOTED_CD: Color = Color(0.18, 0.15, 0.12, 1.0)
	const SOOTED_DARK_CD: Color = Color(0.10, 0.08, 0.06, 1.0)
	const FLOOD_WARM_CD: Color = Color(1.0, 0.78, 0.42, 1.0)
	const REACTOR_AMBER_CD: Color = Color(1.0, 0.55, 0.20, 1.0)
	var team: Color = _team_color()

	# --- Fuselage — chunky tapered hull. Slightly wider at the back
	# (engine block) tapering toward the nose. +Z is the travel
	# direction in aircraft coordinates.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var body_box := BoxMesh.new()
	body_box.size = Vector3(1.40, 0.70, 2.80)
	body.mesh = body_box
	body.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_CD))
	add_child(body)
	# Dorsal spine — slimmer raised top so the hull reads as multi-tier.
	var spine := MeshInstance3D.new()
	spine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sb := BoxMesh.new()
	sb.size = Vector3(0.95, 0.28, 2.20)
	spine.mesh = sb
	spine.position = Vector3(0.0, 0.48, -0.10)
	spine.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_DARK_CD))
	add_child(spine)
	# --- Team-color flank stripe — narrower than the previous build's
	# broad panels (per user 2026-05-19: gunship had too much player
	# color). Slim accent strip on each flank — still readable but
	# no longer dominating the silhouette.
	for spine_side: int in 2:
		var ssx: float = -1.0 if spine_side == 0 else 1.0
		var team_panel := MeshInstance3D.new()
		team_panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var tpb := BoxMesh.new()
		tpb.size = Vector3(0.04, 0.10, 1.20)
		team_panel.mesh = tpb
		team_panel.position = Vector3(ssx * 0.76, 0.20, 0.0)
		var tp_mat := StandardMaterial3D.new()
		tp_mat.albedo_color = team
		tp_mat.emission_enabled = true
		tp_mat.emission = team
		tp_mat.emission_energy_multiplier = 1.4
		team_panel.set_surface_override_material(0, tp_mat)
		add_child(team_panel)

	# --- Forward canopy + floodlight (placed at +Z = front).
	var canopy := MeshInstance3D.new()
	canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var canopy_box := BoxMesh.new()
	canopy_box.size = Vector3(0.85, 0.35, 0.95)
	canopy.mesh = canopy_box
	canopy.position = Vector3(0.0, 0.42, 0.85)
	canopy.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_CD))
	add_child(canopy)
	# Amber cockpit slit on the canopy.
	var canopy_slit := MeshInstance3D.new()
	canopy_slit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var css := BoxMesh.new()
	css.size = Vector3(0.65, 0.08, 0.35)
	canopy_slit.mesh = css
	canopy_slit.position = Vector3(0.0, 0.52, 1.15)
	var cs_mat := StandardMaterial3D.new()
	cs_mat.albedo_color = REACTOR_AMBER_CD
	cs_mat.emission_enabled = true
	cs_mat.emission = REACTOR_AMBER_CD
	cs_mat.emission_energy_multiplier = 2.2
	cs_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	canopy_slit.set_surface_override_material(0, cs_mat)
	add_child(canopy_slit)
	# Nose floodlight — brass housing + warm bulb. Positive Z (front).
	var flood := MeshInstance3D.new()
	flood.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var flood_cyl := CylinderMesh.new()
	flood_cyl.top_radius = 0.22
	flood_cyl.bottom_radius = 0.20
	flood_cyl.height = 0.22
	flood_cyl.radial_segments = 12
	flood.mesh = flood_cyl
	flood.rotation.x = PI * 0.5
	flood.position = Vector3(0.0, 0.05, 1.55)
	flood.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_CD))
	add_child(flood)
	var flood_bulb := MeshInstance3D.new()
	flood_bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fbulb_cyl := CylinderMesh.new()
	fbulb_cyl.top_radius = 0.17
	fbulb_cyl.bottom_radius = 0.17
	fbulb_cyl.height = 0.04
	fbulb_cyl.radial_segments = 12
	flood_bulb.mesh = fbulb_cyl
	flood_bulb.rotation.x = PI * 0.5
	flood_bulb.position = Vector3(0.0, 0.05, 1.68)
	var fb_mat := StandardMaterial3D.new()
	fb_mat.albedo_color = FLOOD_WARM_CD
	fb_mat.emission_enabled = true
	fb_mat.emission = FLOOD_WARM_CD
	fb_mat.emission_energy_multiplier = 3.6
	fb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flood_bulb.set_surface_override_material(0, fb_mat)
	add_child(flood_bulb)

	# --- Wings — wider stub wings with rotor nacelles at the tips.
	var wing := MeshInstance3D.new()
	wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wing_box := BoxMesh.new()
	wing_box.size = Vector3(3.80, 0.14, 0.95)
	wing.mesh = wing_box
	wing.position = Vector3(0.0, 0.0, -0.10)
	wing.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_DARK_CD))
	add_child(wing)
	# Team-color wing leading edge — second player-color cue, visible
	# from above (the natural RTS viewing angle).
	var wing_le := MeshInstance3D.new()
	wing_le.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wle := BoxMesh.new()
	wle.size = Vector3(3.85, 0.10, 0.18)
	wing_le.mesh = wle
	wing_le.position = Vector3(0.0, 0.04, 0.32)
	var wle_mat := StandardMaterial3D.new()
	wle_mat.albedo_color = team
	wle_mat.emission_enabled = true
	wle_mat.emission = team
	wle_mat.emission_energy_multiplier = 1.4
	wing_le.set_surface_override_material(0, wle_mat)
	add_child(wing_le)

	# --- VTOL rotor nacelles at the wing tips. Each nacelle = brass
	# housing + spinning rotor disc (built as a static cross of two
	# blades since we don't animate it here; the disc visual reads as
	# "rotor at speed" via a translucent blur ring). No top or tail
	# rotor — these wing-tip rotors ARE the lift system.
	for rotor_side: int in 2:
		var rsx: float = -1.0 if rotor_side == 0 else 1.0
		# Nacelle pylon — vertical pillar rising from the wing tip.
		var pylon := MeshInstance3D.new()
		pylon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pb := BoxMesh.new()
		pb.size = Vector3(0.40, 0.50, 0.55)
		pylon.mesh = pb
		pylon.position = Vector3(rsx * 1.85, 0.20, -0.10)
		pylon.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_CD))
		add_child(pylon)
		# Rotor hub — brass cylinder pointing UP (rotor axis is
		# vertical = VTOL lifter).
		var hub := MeshInstance3D.new()
		hub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var hb := CylinderMesh.new()
		hb.top_radius = 0.16
		hb.bottom_radius = 0.20
		hb.height = 0.22
		hb.radial_segments = 12
		hub.mesh = hb
		hub.position = Vector3(rsx * 1.85, 0.55, -0.10)
		hub.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_CD))
		add_child(hub)
		# Spinning rotor disc — translucent darker grey ring + two
		# crossed blades. Doesn't actually spin (animation deferred);
		# the translucent disc reads as "this is rotating fast".
		var rotor_disc := MeshInstance3D.new()
		rotor_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var rdc := CylinderMesh.new()
		rdc.top_radius = 1.05
		rdc.bottom_radius = 1.05
		rdc.height = 0.04
		rdc.radial_segments = 24
		rotor_disc.mesh = rdc
		rotor_disc.position = Vector3(rsx * 1.85, 0.78, -0.10)
		var rd_mat := StandardMaterial3D.new()
		rd_mat.albedo_color = Color(0.10, 0.08, 0.06, 0.42)
		rd_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rd_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		rotor_disc.set_surface_override_material(0, rd_mat)
		add_child(rotor_disc)
		# Two crossed rotor blades — thin boxes inside the disc.
		for blade_i: int in 2:
			var blade := MeshInstance3D.new()
			blade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var blb := BoxMesh.new()
			blb.size = Vector3(2.00, 0.05, 0.18)
			blade.mesh = blb
			blade.position = Vector3(rsx * 1.85, 0.79, -0.10)
			blade.rotation.y = float(blade_i) * PI * 0.5
			blade.set_surface_override_material(0, _aircraft_metal_mat(DARK_BRASS_CD))
			add_child(blade)
		# Brass support strut from nacelle base down to the wing.
		var strut := MeshInstance3D.new()
		strut.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var stb := BoxMesh.new()
		stb.size = Vector3(0.10, 0.30, 0.10)
		strut.mesh = stb
		strut.position = Vector3(rsx * 1.85, -0.10, -0.10)
		strut.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_CD))
		add_child(strut)

	# --- Twin underwing napalm tanks — chunky cylinders slung under
	# the inner wing, NOT the rotor tips. Keeps the gunship's "napalm
	# tank" identity readable from above.
	for tank_side: int in 2:
		var tsx: float = -1.0 if tank_side == 0 else 1.0
		var tank := MeshInstance3D.new()
		tank.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var tank_cyl := CylinderMesh.new()
		tank_cyl.top_radius = 0.16
		tank_cyl.bottom_radius = 0.16
		tank_cyl.height = 1.05
		tank_cyl.radial_segments = 10
		tank.mesh = tank_cyl
		tank.rotation.x = PI * 0.5
		tank.position = Vector3(tsx * 1.05, -0.22, -0.10)
		tank.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_CD))
		add_child(tank)
		# Tank nose cap — now at +Z (front) per the new convention.
		var cap := MeshInstance3D.new()
		cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cap_sph := SphereMesh.new()
		cap_sph.radius = 0.18
		cap_sph.height = 0.32
		cap.mesh = cap_sph
		cap.position = Vector3(tsx * 1.05, -0.22, 0.45)
		cap.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_CD))
		add_child(cap)

	# --- Rear thruster pair (jet exhaust, NOT rotors). Provides forward
	# thrust once the rotors lift the aircraft. -Z = aft.
	for thr_side: int in 2:
		var thsx: float = -1.0 if thr_side == 0 else 1.0
		var thruster := MeshInstance3D.new()
		thruster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var thc := CylinderMesh.new()
		thc.top_radius = 0.18
		thc.bottom_radius = 0.22
		thc.height = 0.55
		thc.radial_segments = 10
		thruster.mesh = thc
		thruster.rotation.x = PI * 0.5
		thruster.position = Vector3(thsx * 0.45, 0.08, -1.40)
		thruster.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_CD))
		add_child(thruster)
		# Amber exhaust glow at the rear.
		var glow := MeshInstance3D.new()
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var glow_cyl := CylinderMesh.new()
		glow_cyl.top_radius = 0.15
		glow_cyl.bottom_radius = 0.15
		glow_cyl.height = 0.04
		glow_cyl.radial_segments = 10
		glow.mesh = glow_cyl
		glow.rotation.x = PI * 0.5
		glow.position = Vector3(thsx * 0.45, 0.08, -1.70)
		var glow_mat := StandardMaterial3D.new()
		glow_mat.albedo_color = REACTOR_AMBER_CD
		glow_mat.emission_enabled = true
		glow_mat.emission = REACTOR_AMBER_CD
		glow_mat.emission_energy_multiplier = 3.0
		glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.set_surface_override_material(0, glow_mat)
		add_child(glow)

	# --- Vertical tail fin — at -Z (rear). Team-color chevron makes
	# it a third large player-color cue.
	var fin := MeshInstance3D.new()
	fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fin_box := BoxMesh.new()
	fin_box.size = Vector3(0.10, 0.75, 0.65)
	fin.mesh = fin_box
	fin.position = Vector3(0.0, 0.65, -1.10)
	fin.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_CD))
	add_child(fin)
	var fin_chevron := MeshInstance3D.new()
	fin_chevron.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fcb := BoxMesh.new()
	fcb.size = Vector3(0.14, 0.55, 0.16)
	fin_chevron.mesh = fcb
	fin_chevron.position = Vector3(0.0, 0.65, -0.85)
	var fc_mat := StandardMaterial3D.new()
	fc_mat.albedo_color = team
	fc_mat.emission_enabled = true
	fc_mat.emission = team
	fc_mat.emission_energy_multiplier = 1.5
	fin_chevron.set_surface_override_material(0, fc_mat)
	add_child(fin_chevron)
	var fin_team := MeshInstance3D.new()
	fin_team.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ft_box := BoxMesh.new()
	ft_box.size = Vector3(0.06, 0.55, 0.10)
	fin_team.mesh = ft_box
	fin_team.position = Vector3(0.0, 0.50, 0.85)
	var ft_mat := StandardMaterial3D.new()
	ft_mat.albedo_color = team
	ft_mat.emission_enabled = true
	ft_mat.emission = team
	ft_mat.emission_energy_multiplier = 1.4
	fin_team.set_surface_override_material(0, ft_mat)
	add_child(fin_team)


func _build_heliarch_aguila() -> void:
	## Heliarch heavy bomber (in-game name "Condor" after the
	## 2026-05-19 swap; builder still named for legacy reasons).
	## Full rebuild 2026-05-19:
	##   - Orientation: +Z = forward (aircraft.gd look_at flip means
	##     +Z is the travel direction). Previous build placed
	##     canopy at -Z, so the bomber visibly flew tail-first.
	##   - Enlarged ~1.4× from the prior build for the "heavy
	##     bomber dwarfs the gunship" silhouette read.
	##   - VTOL wing-inlay rotors: circular cutouts in the wing with
	##     spinning rotor discs visible THROUGH the wing surface
	##     (not external nacelles). Read as a built-in lift system.
	##   - More player color: dorsal spine stripe + wing leading
	##     edges + tail chevron. Three big cues, not just one.
	##   - Silhouette polish: tapered nose dome, curved engine
	##     pods, vertical tail with brass cap. Less boxy than the
	##     previous build's flat slabs.
	const HELIARCH_BRASS_AG: Color = Color(0.65, 0.45, 0.18, 1.0)
	const DARK_BRASS_AG: Color = Color(0.40, 0.26, 0.10, 1.0)
	const SOOTED_AG: Color = Color(0.18, 0.15, 0.12, 1.0)
	const SOOTED_DARK_AG: Color = Color(0.10, 0.08, 0.06, 1.0)
	const FLOOD_WARM_AG: Color = Color(1.0, 0.78, 0.42, 1.0)
	const REACTOR_AMBER_AG: Color = Color(1.0, 0.55, 0.20, 1.0)
	const HOT_WHITE_AG: Color = Color(1.0, 0.88, 0.62, 1.0)
	var team: Color = _team_color()
	# Scale factor — 1.4× the previous size so the heavy bomber
	# silhouette dominates over the lighter gunship.
	const S: float = 1.4
	# Main fuselage — slightly larger than the old build for a heavier
	# silhouette + a layered top spine that breaks the otherwise-flat
	# upper surface.
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var body_box := BoxMesh.new()
	body_box.size = Vector3(2.00, 0.95, 4.60)
	body.mesh = body_box
	body.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_AG))
	add_child(body)
	# Upper spine — a narrower box riding the top of the fuselage so
	# the bomber reads as multi-tiered instead of a single slab.
	var spine := MeshInstance3D.new()
	spine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sb := BoxMesh.new()
	sb.size = Vector3(1.40, 0.32, 3.80)
	spine.mesh = sb
	spine.position = Vector3(0.0, 0.62, 0.10)
	spine.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_DARK_AG))
	add_child(spine)
	# Brass rivet rows down each flank of the fuselage — four rivets
	# per side, spaced along the length.
	for side: int in 2:
		var rsx: float = -1.05 if side == 0 else 1.05
		for rivet_i: int in 6:
			var rivet := MeshInstance3D.new()
			rivet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var rs := SphereMesh.new()
			rs.radius = 0.07
			rs.height = 0.14
			rivet.mesh = rs
			var rz: float = -2.00 + float(rivet_i) * 0.80
			rivet.position = Vector3(rsx, 0.10, rz)
			rivet.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
			add_child(rivet)
	# Brass cult plate riveted to the dorsal spine — embossed Heliarch
	# crest, just a flat box but reads as "ritual ornamentation".
	var dorsal_plate := MeshInstance3D.new()
	dorsal_plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dp := BoxMesh.new()
	dp.size = Vector3(0.80, 0.06, 1.40)
	dorsal_plate.mesh = dp
	dorsal_plate.position = Vector3(0.0, 0.82, 0.10)
	dorsal_plate.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
	add_child(dorsal_plate)
	# Belly bomb bay — deeper recessed gondola with brass framing and
	# two visible amber payload bulbs nestled inside.
	var bay := MeshInstance3D.new()
	bay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bay_box := BoxMesh.new()
	bay_box.size = Vector3(1.70, 0.55, 2.60)
	bay.mesh = bay_box
	bay.position = Vector3(0.0, -0.60, 0.05)
	bay.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_DARK_AG))
	add_child(bay)
	# Brass framing around the bay opening — four thin bars.
	for frame_side: int in 4:
		var fr := MeshInstance3D.new()
		fr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var fb := BoxMesh.new()
		match frame_side:
			0:
				fb.size = Vector3(1.80, 0.10, 0.10)
				fr.position = Vector3(0.0, -0.40, 1.30)
			1:
				fb.size = Vector3(1.80, 0.10, 0.10)
				fr.position = Vector3(0.0, -0.40, -1.20)
			2:
				fb.size = Vector3(0.10, 0.10, 2.50)
				fr.position = Vector3(-0.85, -0.40, 0.05)
			_:
				fb.size = Vector3(0.10, 0.10, 2.50)
				fr.position = Vector3(0.85, -0.40, 0.05)
		fr.mesh = fb
		fr.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
		add_child(fr)
	# Two visible payload bulbs in the bay — amber spheres that read
	# as the unstable fuel-air charges waiting to drop.
	for bomb_i: int in 2:
		var bomb := MeshInstance3D.new()
		bomb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var bm := SphereMesh.new()
		bm.radius = 0.32
		bm.height = 0.64
		bm.radial_segments = 10
		bm.rings = 6
		bomb.mesh = bm
		var bz: float = -0.60 + float(bomb_i) * 1.20
		bomb.position = Vector3(0.0, -0.72, bz)
		var bmm := StandardMaterial3D.new()
		bmm.albedo_color = HELIARCH_BRASS_AG
		bmm.emission_enabled = true
		bmm.emission = REACTOR_AMBER_AG
		bmm.emission_energy_multiplier = 1.8
		bomb.set_surface_override_material(0, bmm)
		add_child(bomb)
	# Ember-hot ventral slit between the two bombs — sells "the
	# payload itself is hot".
	var hot_slit := MeshInstance3D.new()
	hot_slit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hsb := BoxMesh.new()
	hsb.size = Vector3(0.50, 0.05, 2.30)
	hot_slit.mesh = hsb
	hot_slit.position = Vector3(0.0, -0.95, 0.05)
	var hs_mat := StandardMaterial3D.new()
	hs_mat.albedo_color = REACTOR_AMBER_AG
	hs_mat.emission_enabled = true
	hs_mat.emission = REACTOR_AMBER_AG
	hs_mat.emission_energy_multiplier = 3.4
	hs_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot_slit.set_surface_override_material(0, hs_mat)
	add_child(hot_slit)
	# Brass overslung canopy — taller, with a riveted brass framework
	# and a recessed amber cockpit slit so the canopy reads as armored
	# rather than a clear bubble.
	var canopy := MeshInstance3D.new()
	canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var canopy_box := BoxMesh.new()
	canopy_box.size = Vector3(1.10, 0.45, 1.30)
	canopy.mesh = canopy_box
	canopy.position = Vector3(0.0, 0.60, -1.25)
	canopy.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
	add_child(canopy)
	var canopy_slit := MeshInstance3D.new()
	canopy_slit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var css := BoxMesh.new()
	css.size = Vector3(0.85, 0.10, 0.45)
	canopy_slit.mesh = css
	canopy_slit.position = Vector3(0.0, 0.70, -1.55)
	var cs_mat := StandardMaterial3D.new()
	cs_mat.albedo_color = REACTOR_AMBER_AG
	cs_mat.emission_enabled = true
	cs_mat.emission = REACTOR_AMBER_AG
	cs_mat.emission_energy_multiplier = 2.2
	cs_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	canopy_slit.set_surface_override_material(0, cs_mat)
	add_child(canopy_slit)
	# Chin radome — small bulbous nose under the canopy.
	var radome := MeshInstance3D.new()
	radome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rm := SphereMesh.new()
	rm.radius = 0.35
	rm.height = 0.65
	rm.radial_segments = 12
	rm.rings = 8
	radome.mesh = rm
	radome.position = Vector3(0.0, -0.10, -2.05)
	radome.set_surface_override_material(0, _aircraft_metal_mat(DARK_BRASS_AG))
	add_child(radome)
	# Large forward floodlight on the nose.
	var flood := MeshInstance3D.new()
	flood.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var flood_cyl := CylinderMesh.new()
	flood_cyl.top_radius = 0.28
	flood_cyl.bottom_radius = 0.25
	flood_cyl.height = 0.30
	flood_cyl.radial_segments = 14
	flood.mesh = flood_cyl
	flood.rotation.x = PI * 0.5
	flood.position = Vector3(0.0, 0.0, -2.20)
	flood.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
	add_child(flood)
	var flood_bulb := MeshInstance3D.new()
	flood_bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fbulb := CylinderMesh.new()
	fbulb.top_radius = 0.22
	fbulb.bottom_radius = 0.22
	fbulb.height = 0.04
	fbulb.radial_segments = 14
	flood_bulb.mesh = fbulb
	flood_bulb.rotation.x = PI * 0.5
	flood_bulb.position = Vector3(0.0, 0.0, -2.36)
	var fb_mat := StandardMaterial3D.new()
	fb_mat.albedo_color = FLOOD_WARM_AG
	fb_mat.emission_enabled = true
	fb_mat.emission = FLOOD_WARM_AG
	fb_mat.emission_energy_multiplier = 3.6
	fb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flood_bulb.set_surface_override_material(0, fb_mat)
	add_child(flood_bulb)
	# Wide wings.
	var wing := MeshInstance3D.new()
	wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wing_box := BoxMesh.new()
	wing_box.size = Vector3(5.20, 0.16, 1.30)
	wing.mesh = wing_box
	wing.position = Vector3(0.0, 0.0, 0.20)
	wing.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_AG.darkened(0.10)))
	add_child(wing)
	# Wing-inlay rotors — replaces the previous external tail-mounted
	# engines. Per user 2026-05-19: the Condor should have rotors
	# INLAYED into its wings (scifi heavy lifter aesthetic, not main
	# rotor + tail rotor). Four rotors per wing, two per side, sitting
	# FLUSH with the wing surface. Each = brass-rimmed circular cutout
	# + translucent grey rotor disc + two crossed dark-brass blades
	# (static; the disc translucency reads as "spinning fast"). Also
	# keep the rear amber exhaust glow as the forward-thrust source.
	for rotor_xi: int in 4:
		var rx_offsets: Array[float] = [-2.0, -0.95, 0.95, 2.0]
		var rx: float = rx_offsets[rotor_xi]
		# Brass rim around the rotor — flat torus inlayed on the wing
		# surface (slightly raised above the wing top).
		var rim_inlay := MeshInstance3D.new()
		rim_inlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var rim_t := TorusMesh.new()
		rim_t.inner_radius = 0.36
		rim_t.outer_radius = 0.46
		rim_t.rings = 20
		rim_t.ring_segments = 4
		rim_inlay.mesh = rim_t
		rim_inlay.position = Vector3(rx, 0.08, 0.45)
		rim_inlay.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
		add_child(rim_inlay)
		# Dark recessed cavity — the wing "hole" the rotor sits in.
		var cavity := MeshInstance3D.new()
		cavity.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cv := CylinderMesh.new()
		cv.top_radius = 0.36
		cv.bottom_radius = 0.36
		cv.height = 0.06
		cv.radial_segments = 18
		cavity.mesh = cv
		cavity.position = Vector3(rx, 0.04, 0.45)
		cavity.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_DARK_AG))
		add_child(cavity)
		# Translucent rotor disc — sits inside the cavity at the wing
		# top, low alpha reads as "spinning fast" without animation.
		var rotor_disc := MeshInstance3D.new()
		rotor_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var rdc := CylinderMesh.new()
		rdc.top_radius = 0.34
		rdc.bottom_radius = 0.34
		rdc.height = 0.03
		rdc.radial_segments = 20
		rotor_disc.mesh = rdc
		rotor_disc.position = Vector3(rx, 0.10, 0.45)
		var rd_mat := StandardMaterial3D.new()
		rd_mat.albedo_color = Color(0.18, 0.16, 0.14, 0.45)
		rd_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rd_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		rotor_disc.set_surface_override_material(0, rd_mat)
		add_child(rotor_disc)
		# Two crossed rotor blades inside the disc — thin dark-brass bars.
		for blade_i: int in 2:
			var blade := MeshInstance3D.new()
			blade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var blb := BoxMesh.new()
			blb.size = Vector3(0.62, 0.04, 0.10)
			blade.mesh = blb
			blade.position = Vector3(rx, 0.105, 0.45)
			blade.rotation.y = float(blade_i) * PI * 0.5
			blade.set_surface_override_material(0, _aircraft_metal_mat(DARK_BRASS_AG))
			add_child(blade)
		# Central brass hub cap.
		var hub := MeshInstance3D.new()
		hub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var hubm := CylinderMesh.new()
		hubm.top_radius = 0.10
		hubm.bottom_radius = 0.12
		hubm.height = 0.10
		hubm.radial_segments = 10
		hub.mesh = hubm
		hub.position = Vector3(rx, 0.16, 0.45)
		hub.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
		add_child(hub)
		# Amber underglow visible through the cavity from below (the
		# rotor draft is reactor-heated air).
		var glow := MeshInstance3D.new()
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var glow_cyl := CylinderMesh.new()
		glow_cyl.top_radius = 0.28
		glow_cyl.bottom_radius = 0.28
		glow_cyl.height = 0.02
		glow_cyl.radial_segments = 16
		glow.mesh = glow_cyl
		glow.position = Vector3(rx, -0.05, 0.45)
		var glow_mat := StandardMaterial3D.new()
		glow_mat.albedo_color = REACTOR_AMBER_AG
		glow_mat.emission_enabled = true
		glow_mat.emission = REACTOR_AMBER_AG
		glow_mat.emission_energy_multiplier = 2.4
		glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.set_surface_override_material(0, glow_mat)
		add_child(glow)
	# Tall vertical tail fin with brass crest.
	var fin := MeshInstance3D.new()
	fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fin_box := BoxMesh.new()
	fin_box.size = Vector3(0.14, 1.10, 0.80)
	fin.mesh = fin_box
	fin.position = Vector3(0.0, 0.80, 1.80)
	fin.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_AG))
	add_child(fin)
	var fin_crest := MeshInstance3D.new()
	fin_crest.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fc := BoxMesh.new()
	fc.size = Vector3(0.20, 0.10, 0.65)
	fin_crest.mesh = fc
	fin_crest.position = Vector3(0.0, 1.40, 1.80)
	fin_crest.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
	add_child(fin_crest)
	# Team-colour leading edge on the fin.
	var fin_team := MeshInstance3D.new()
	fin_team.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ft_box := BoxMesh.new()
	ft_box.size = Vector3(0.08, 0.90, 0.10)
	fin_team.mesh = ft_box
	fin_team.position = Vector3(0.0, 0.80, 1.45)
	var ft_mat := StandardMaterial3D.new()
	ft_mat.albedo_color = team
	ft_mat.emission_enabled = true
	ft_mat.emission = team
	ft_mat.emission_energy_multiplier = 1.4
	fin_team.set_surface_override_material(0, ft_mat)
	add_child(fin_team)
	# Twin tail booms — slender beams flanking the main fin, capped by
	# small amber tail-lights. Adds depth + symmetry to the rear.
	for boom_side: int in 2:
		var bsx: float = -1.20 if boom_side == 0 else 1.20
		var boom := MeshInstance3D.new()
		boom.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var bbm := BoxMesh.new()
		bbm.size = Vector3(0.18, 0.18, 1.80)
		boom.mesh = bbm
		boom.position = Vector3(bsx, 0.30, 1.40)
		boom.set_surface_override_material(0, _aircraft_metal_mat(SOOTED_DARK_AG))
		add_child(boom)
		var tail_light := MeshInstance3D.new()
		tail_light.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var tls := SphereMesh.new()
		tls.radius = 0.12
		tls.height = 0.24
		tail_light.mesh = tls
		tail_light.position = Vector3(bsx, 0.30, 2.40)
		var tl_mat := StandardMaterial3D.new()
		tl_mat.albedo_color = REACTOR_AMBER_AG
		tl_mat.emission_enabled = true
		tl_mat.emission = REACTOR_AMBER_AG
		tl_mat.emission_energy_multiplier = 2.8
		tl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		tail_light.set_surface_override_material(0, tl_mat)
		add_child(tail_light)
	# Two ritual brass chains hanging off the wing roots — short
	# dangling boxes simulating consecrated chain ornaments per the
	# Heliarch "ritual ornamentation" lore in §3.4. Tiny but they
	# add the "this is a holy war engine" read.
	for chain_side: int in 2:
		var cnx: float = -0.90 if chain_side == 0 else 0.90
		for link_i: int in 4:
			var link := MeshInstance3D.new()
			link.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var lb := BoxMesh.new()
			lb.size = Vector3(0.07, 0.10, 0.07)
			link.mesh = lb
			link.position = Vector3(cnx, -0.10 - float(link_i) * 0.13, 0.55)
			link.set_surface_override_material(0, _aircraft_metal_mat(HELIARCH_BRASS_AG))
			add_child(link)
	# Hot-white reactor-glow lamp along the underbelly near the nose
	# — sells "the payload is unstable + ready to drop".
	var underglow := OmniLight3D.new()
	underglow.light_color = HOT_WHITE_AG
	underglow.light_energy = 1.4
	underglow.omni_range = 4.0
	underglow.position = Vector3(0.0, -1.0, 0.05)
	add_child(underglow)

	# --- Player-color reinforcement (more, per user 2026-05-19).
	# Three additional team-tinted features beyond the small fin
	# crest the earlier build had: dorsal team-stripe along the
	# spine, wing leading-edge strips on both wings, and a tail
	# chevron on the rear fuselage.
	var dorsal_stripe := MeshInstance3D.new()
	dorsal_stripe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dsb := BoxMesh.new()
	dsb.size = Vector3(0.50, 0.06, 3.40)
	dorsal_stripe.mesh = dsb
	dorsal_stripe.position = Vector3(0.0, 0.86, 0.10)
	var ds_mat := StandardMaterial3D.new()
	ds_mat.albedo_color = team
	ds_mat.emission_enabled = true
	ds_mat.emission = team
	ds_mat.emission_energy_multiplier = 1.5
	dorsal_stripe.set_surface_override_material(0, ds_mat)
	add_child(dorsal_stripe)
	for wing_le_side: int in 2:
		var wsx: float = -1.0 if wing_le_side == 0 else 1.0
		var wing_le := MeshInstance3D.new()
		wing_le.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wleb := BoxMesh.new()
		wleb.size = Vector3(2.40, 0.10, 0.16)
		wing_le.mesh = wleb
		wing_le.position = Vector3(wsx * 1.30, 0.06, -0.42)  # leading edge sits forward of the wing (-Z in current build)
		var wle_mat := StandardMaterial3D.new()
		wle_mat.albedo_color = team
		wle_mat.emission_enabled = true
		wle_mat.emission = team
		wle_mat.emission_energy_multiplier = 1.4
		wing_le.set_surface_override_material(0, wle_mat)
		add_child(wing_le)

	# --- Orientation correction. The build above places nose / canopy
	# / floodlight at -Z, but aircraft.gd's look_at (line 459) flips
	# so +Z is the travel direction — the bomber was visibly flying
	# tail-first. Rather than rewrite every literal Z position, flip
	# every direct child's Z + add a 180° yaw so cylinders/boxes
	# originally facing -Z now face +Z. Self transform is not touched
	# — the per-frame look_at owns it.
	for child: Node in get_children():
		if not (child is Node3D):
			continue
		var c: Node3D = child as Node3D
		if c == self:
			continue
		c.position.z = -c.position.z
		c.rotation.y = wrapf(c.rotation.y + PI, -PI, PI)
	# Then scale the WHOLE thing up — heavy bomber should be visibly
	# bulkier than the gunship. 1.4× per the rebuild plan.
	scale = Vector3(1.4, 1.4, 1.4)
	add_child(underglow)


func _build_default_aircraft() -> void:
	# Fallback for any aircraft type without a dedicated builder.
	var team: Color = _team_color()
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var body_box := BoxMesh.new()
	body_box.size = Vector3(1.4, 0.45, 2.2)
	body.mesh = body_box
	body.set_surface_override_material(0, _aircraft_metal_mat(Color(0.32, 0.30, 0.28)))
	add_child(body)
	var wing := MeshInstance3D.new()
	wing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wing_box := BoxMesh.new()
	wing_box.size = Vector3(3.4, 0.08, 0.9)
	wing.mesh = wing_box
	wing.set_surface_override_material(0, _aircraft_metal_mat(Color(0.32, 0.30, 0.28).darkened(0.15)))
	add_child(wing)
	var stripe := MeshInstance3D.new()
	stripe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(0.5, 0.22, 1.9)
	stripe.mesh = stripe_box
	stripe.position.y = 0.2
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team
	stripe_mat.emission_energy_multiplier = 1.2
	stripe.set_surface_override_material(0, stripe_mat)
	add_child(stripe)


## --- Patrol Drone (Drone Bay defender) -----------------------------------

func _build_patrol_drone() -> void:
	## Small flat disc + raised sensor dome. Single-body craft; no swarm.
	## Meridian teal-blue accent to read as allied tech on the battlefield.
	var team: Color = _team_color()
	var body := MeshInstance3D.new()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var disc := CylinderMesh.new()
	disc.top_radius = 0.40
	disc.bottom_radius = 0.40
	disc.height = 0.10
	disc.radial_segments = 16
	body.mesh = disc
	body.set_surface_override_material(0, _aircraft_metal_mat(Color(0.12, 0.13, 0.16, 1.0)))
	add_child(body)
	# Sensor dome on top.
	var dome := MeshInstance3D.new()
	dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dome_mesh := SphereMesh.new()
	dome_mesh.radius = 0.20
	dome_mesh.height = 0.22
	dome_mesh.radial_segments = 10
	dome_mesh.rings = 5
	dome.mesh = dome_mesh
	dome.position.y = 0.14
	var dome_mat := StandardMaterial3D.new()
	dome_mat.albedo_color = Color(0.20, 0.72, 0.90, 0.75)
	dome_mat.emission_enabled = true
	dome_mat.emission = Color(0.20, 0.72, 0.90, 1.0)
	dome_mat.emission_energy_multiplier = 1.6
	dome_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dome_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dome.set_surface_override_material(0, dome_mat)
	add_child(dome)
	# Team colour ring around disc edge.
	var ring := MeshInstance3D.new()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var torus_mesh := TorusMesh.new()
	torus_mesh.inner_radius = 0.35
	torus_mesh.outer_radius = 0.44
	torus_mesh.ring_segments = 4
	torus_mesh.rings = 20
	ring.mesh = torus_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = team
	ring_mat.emission_enabled = true
	ring_mat.emission = team
	ring_mat.emission_energy_multiplier = 1.4
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.set_surface_override_material(0, ring_mat)
	add_child(ring)


## --- Patrol-around-parent state (Drone Bay defenders) -------------------

## Set by Drone Bay after spawn. When non-null the drone orbits this node.
var _patrol_around: Node3D = null
var _patrol_radius: float = 12.0
var _patrol_target: Vector3 = Vector3.INF
## Throttle counter so we don't re-pick patrol target every frame.
var _patrol_tick: int = 0


func set_patrol_around(parent: Node3D, radius: float) -> void:
	## Called by Building._spawn_patrol_drones immediately after spawn.
	_patrol_around = parent
	_patrol_radius = radius
	_pick_new_patrol_target()


func _pick_new_patrol_target() -> void:
	if not is_instance_valid(_patrol_around):
		return
	var ang: float = randf() * TAU
	var dist: float = _patrol_radius * (0.5 + 0.5 * randf())
	_patrol_target = _patrol_around.global_position + Vector3(cos(ang), 0.0, sin(ang)) * dist
	command_move(_patrol_target, false)
	# Enable auto-targeting while flying to the patrol waypoint.
	# command_move sets has_move_order=true which blocks CombatComponent's
	# can_auto_target check (requires either idle OR attack_move_target set).
	# Setting attack_move_target satisfies the second branch so the drone
	# scans for enemies throughout its patrol circuit without interrupting
	# the waypoint movement.
	if _combat != null:
		_combat.set("attack_move_target", _patrol_target)


## Called from _process on the heavy tick (every 3rd frame). Checks whether
## the drone has reached its patrol waypoint and should pick a new one.
func _tick_patrol() -> void:
	if _patrol_around == null:
		return
	if not is_instance_valid(_patrol_around):
		_patrol_around = null
		return
	# If the parent bay dies, kill this drone.
	var bay_hp: int = _patrol_around.get("current_hp") as int
	if bay_hp <= 0:
		queue_free()
		return
	# Don't interrupt an active engagement.
	if _combat != null:
		var ct_v: Variant = _combat.get("_current_target")
		if ct_v != null and is_instance_valid(ct_v):
			return
	# Pick a new waypoint when idle and arrived (move_target cleared).
	if move_target == Vector3.INF and _patrol_target != Vector3.INF:
		_pick_new_patrol_target()


## --- V3 stealth (Wraith) -------------------------------------------------

func _process_stealth(delta: float) -> void:
	## Mirrors Unit._tick_stealth: throttled proximity check + a damage
	## timer, with the same reveal rules. Wraith uses this; other
	## aircraft pass through (is_stealth_capable defaults to false).
	if not stats or not stats.is_stealth_capable or alive_count <= 0:
		return
	if _stealth_damage_timer > 0.0:
		_stealth_damage_timer -= delta
	_stealth_check_throttle -= delta
	if _stealth_check_throttle > 0.0:
		return
	_stealth_check_throttle = STEALTH_CHECK_INTERVAL
	if _stealth_damage_timer > 0.0:
		if not stealth_revealed:
			_set_stealth_revealed(true)
		return
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry if get_tree() else null
	var detect_r2: float = stats.detection_radius * stats.detection_radius
	var spotted: bool = false
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node) or node == self:
			continue
		if not ("alive_count" in node) or (node.get("alive_count") as int) <= 0:
			continue
		var other_owner: int = node.get("owner_id") as int
		if registry:
			if registry.are_allied(owner_id, other_owner):
				continue
		else:
			if other_owner == owner_id:
				continue
		var their_r: float = 6.0
		if "stats" in node:
			var their_stats: UnitStatResource = node.get("stats") as UnitStatResource
			if their_stats:
				their_r = their_stats.detection_radius
		var their_r2: float = their_r * their_r
		var dx: float = (node as Node3D).global_position.x - global_position.x
		var dz: float = (node as Node3D).global_position.z - global_position.z
		var d2: float = dx * dx + dz * dz
		# Reveal only by enemy detection. The stealth unit's OWN radius
		# shouldn't reveal it (see unit.gd::_tick_stealth comment).
		if d2 <= their_r2:
			spotted = true
			break
	if spotted != stealth_revealed:
		_set_stealth_revealed(spotted)


func _set_stealth_revealed(revealed: bool) -> void:
	stealth_revealed = revealed
	_apply_stealth_visual(not revealed)


func _apply_stealth_visual(concealed: bool) -> void:
	## Same alpha-based fade as Unit._apply_stealth_visual — see the comment
	## there. GI3D.transparency was dithered and easy to miss; modifying
	## StandardMaterial3D albedo alpha + transparency_mode gives a clean
	## ghosty fade that reads at any distance.
	var alpha: float = 0.35 if concealed else 1.0
	var mode: int = (
		StandardMaterial3D.TRANSPARENCY_ALPHA
		if concealed
		else StandardMaterial3D.TRANSPARENCY_DISABLED
	)
	_apply_transparency_recursive(self, alpha, mode)


func _apply_transparency_recursive(node: Node, alpha: float, mode: int) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var override: Material = mi.material_override
		if override is StandardMaterial3D:
			_set_mat_alpha(override as StandardMaterial3D, alpha, mode)
		var surf_count: int = mi.get_surface_override_material_count()
		for s_idx: int in surf_count:
			var sm: Material = mi.get_surface_override_material(s_idx)
			if sm is StandardMaterial3D:
				_set_mat_alpha(sm as StandardMaterial3D, alpha, mode)
	for child: Node in node.get_children():
		_apply_transparency_recursive(child, alpha, mode)


func _set_mat_alpha(mat: StandardMaterial3D, alpha: float, mode: int) -> void:
	var c: Color = mat.albedo_color
	c.a = alpha
	mat.albedo_color = c
	mat.transparency = mode


## --- Combat compatibility ---

func take_damage(amount: int, _attacker: Node3D = null) -> void:
	## Per-drone damage distribution — same shape as Unit.take_damage so
	## a swarm dies bit-by-bit instead of all at once. Damage spills from
	## one drone to the next, decrementing alive_count as each drone
	## reaches 0 HP and hiding its visual mesh. Single-body aircraft
	## (Hammerhead / Switchblade) have squad_size 1 and behave the same
	## way they did before.
	if alive_count <= 0:
		return
	# Stealth break — Wraith reveals when hit; same rule as Unit.
	if stats and stats.is_stealth_capable:
		_stealth_damage_timer = stats.stealth_restore_time
		_set_stealth_revealed(true)
	var remaining: int = amount
	for i: int in member_hp.size():
		if remaining <= 0:
			break
		if member_hp[i] <= 0:
			continue
		var dealt: int = mini(member_hp[i], remaining)
		member_hp[i] -= dealt
		remaining -= dealt
		current_hp -= dealt
		_update_hp_bar()
		if member_hp[i] <= 0:
			alive_count -= 1
			# Hide the dead drone's visual. Swarms have one mesh per
			# drone in `_drone_meshes`; single-body craft don't, in
			# which case _die() handles the whole-body cleanup below.
			if i < _drone_meshes.size() and is_instance_valid(_drone_meshes[i]):
				_drone_meshes[i].visible = false
			if alive_count <= 0:
				current_hp = 0
				_die()
				return
	if current_hp < 0:
		current_hp = 0


func get_total_hp() -> int:
	return maxi(current_hp, 0)


func get_combat() -> Node:
	return _combat


## --- Active abilities (mirrors Unit) ----------------------------------
## Same shape as Unit's API so HUD ability buttons + the autocast hook
## in CombatComponent treat aircraft and ground units identically.

func has_ability() -> bool:
	return stats != null and stats.ability_name != ""


func ability_ready() -> bool:
	return has_ability() and _ability_cd_remaining <= 0.0


func ability_cooldown_remaining() -> float:
	return _ability_cd_remaining


func trigger_ability(target_pos: Vector3 = Vector3.INF) -> bool:
	## Signature mirrors Unit.trigger_ability so SelectionManager's
	## unified ability-fire path can call .call("trigger_ability",
	## target) on either a Unit or an Aircraft without an arity
	## mismatch. target_pos is consumed by area-target abilities
	## (Barrier Bloom); auto-target abilities (Missile Barrage,
	## Carpet Bombard) ignore it.
	if not has_ability() or alive_count == 0:
		return false
	if _ability_cd_remaining > 0.0:
		return false
	var fired: bool = false
	match stats.ability_name:
		"Missile Barrage", "AA Missile Barrage":
			fired = _ability_missile_barrage()
		"Carpet Bombard":
			fired = _ability_carpet_bombard()
		"Barrier Bloom":
			fired = _ability_barrier_bloom(target_pos)
		_:
			push_warning("Aircraft '%s' has unknown ability '%s'" % [stats.unit_name, stats.ability_name])
			return false
	if fired:
		_ability_cd_remaining = stats.ability_cooldown
	return fired


func _ability_barrier_bloom(target_pos: Vector3) -> bool:
	## Sputnik Shield's area-target ability. Mirrors Unit's
	## _ability_barrier_bloom: every friendly unit (ground or air)
	## inside stats.ability_radius of the targeted ground point gets
	## a 45% damage reduction for stats.ability_duration. The Shield
	## is currently flagged is_aircraft so it instantiates from
	## aircraft.tscn -- this port lets the same selection-manager
	## ability dispatch fire it without an "unknown ability"
	## warning when the player triggers it.
	if target_pos == Vector3.INF:
		return false
	var radius: float = stats.ability_radius if stats.ability_radius > 0.0 else 6.0
	var duration: float = stats.ability_duration if stats.ability_duration > 0.0 else 5.0
	var radius_sq: float = radius * radius
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var ally_owner: int = (node.get("owner_id") as int) if "owner_id" in node else -1
		if ally_owner != owner_id:
			continue
		var alive_v: int = (node.get("alive_count") as int) if "alive_count" in node else 1
		if alive_v <= 0:
			continue
		var ally_pos: Vector3 = (node as Node3D).global_position
		if ally_pos.distance_squared_to(target_pos) > radius_sq:
			continue
		var combat: Node = node.get_node_or_null("CombatComponent")
		if combat and combat.has_method("apply_damage_reduction"):
			combat.call("apply_damage_reduction", 0.45, duration)
	# Visual marker -- shared dome / pulse renderer if aircraft has
	# one; otherwise a no-op so the gameplay effect still lands.
	if has_method("_spawn_pulse_visual_at"):
		call("_spawn_pulse_visual_at", target_pos, radius, Color(0.45, 0.75, 1.0))
	return true


func _ability_missile_barrage() -> bool:
	## Fires 10 underwing missiles in rapid succession at the
	## CombatComponent's current target — a real salvo. Per-missile
	## damage tuned so the total stays in the same ballpark as the
	## previous 6-missile pop:
	##   Base Hammerhead   -> 10 x 45 = 450 dmg
	##   Hammerhead Escort -> 10 x 54 = 540 dmg
	## Missiles alternate between the LEFT and RIGHT underwing pods
	## (offset 0.78u from the body) and the target point gets a
	## small per-missile XZ spread so the impacts splash around the
	## target rather than all converging on the same pixel.
	if not _combat:
		return false
	var target: Node3D = _combat.get("_current_target") as Node3D
	if not target or not is_instance_valid(target):
		return false
	# Don't bother if the target has already been freed but the
	# combat component hasn't ticked again yet.
	if "alive_count" in target and (target.get("alive_count") as int) <= 0:
		return false
	# AA variant -- skip when the current target isn't an aircraft.
	# The Escort's barrage tubes carry air-to-air missiles; firing
	# them at ground squads (especially under autocast) wasted the
	# salvo on a target the warhead role multiplier can't punish
	# anyway. Anvil's standard Hammerhead barrage stays generalist.
	if stats.ability_name == "AA Missile Barrage" and not target.is_in_group("aircraft"):
		return false
	var per_missile: int = 45
	if stats.unit_name.findn("Escort") >= 0:
		per_missile = 54
	const SALVO_COUNT: int = 10
	const SALVO_STAGGER_SEC: float = 0.09  # ~0.9s total - reads as a real burst
	const POD_X_OFFSET: float = 0.78        # matches the underwing pod placement
	const TARGET_SPREAD: float = 1.6        # XZ jitter on each missile's aim point
	for i: int in SALVO_COUNT:
		var delay: float = float(i) * SALVO_STAGGER_SEC
		# Alternate left / right pod so the salvo visibly comes
		# from BOTH sides instead of stacking on one wing.
		var side_x: float = -POD_X_OFFSET if (i % 2) == 0 else POD_X_OFFSET
		var spread_offset: Vector3 = Vector3(
			randf_range(-TARGET_SPREAD, TARGET_SPREAD),
			0.0,
			randf_range(-TARGET_SPREAD, TARGET_SPREAD),
		)
		var timer: SceneTreeTimer = get_tree().create_timer(delay)
		timer.timeout.connect(_fire_barrage_missile.bind(target, per_missile, side_x, spread_offset))
	return true


func _fire_barrage_missile(target: Node3D, damage: int, side_x: float, spread_offset: Vector3) -> void:
	## One missile in the barrage. side_x is the local X offset of
	## the launching pod (negative = port, positive = starboard);
	## spread_offset is the per-missile XZ jitter applied to the
	## target aim point so the salvo splashes around the target.
	## Skipped silently if the target died mid-volley.
	if not is_instance_valid(target):
		return
	if "alive_count" in target and (target.get("alive_count") as int) <= 0:
		return
	if target.has_method("take_damage"):
		target.call("take_damage", damage, self)
	var role_tag: StringName = &"AAir" if stats.unit_name.findn("Escort") >= 0 else &"AA"
	# Convert the local-X pod offset into a world-space spawn
	# position by sampling the aircraft's transform basis. Falls
	# back to a plain X-axis offset if the basis isn't available
	# (it always is on a parented Node3D, but defensive).
	var pod_world_offset: Vector3 = transform.basis.x * side_x
	var spawn_pos: Vector3 = global_position + pod_world_offset + Vector3(0, -0.25, 0)
	var aim_pos: Vector3 = target.global_position + spread_offset
	# Cosmetic missile through ProjectileManager. Damage was already
	# applied above (target.take_damage), so pending_damage=0.
	var p_color: Color = Color(0.3, 0.7, 1.0, 1.0) if role_tag == &"AA" or role_tag == &"AAir" else Color(0.9, 0.6, 0.2, 1.0)
	var pm: ProjectileManager = ProjectileManager.get_instance(get_tree().current_scene if get_tree() else null)
	if pm != null:
		pm.fire(spawn_pos, aim_pos, "missile", p_color, 0.0,
				0,  # damage already applied
				target as Node3D, self, 0.0, 0,
				(get("owner_id") as int) if "owner_id" in self else -1)


func _ability_carpet_bombard() -> bool:
	## Hammerhead Bomber's heavy bomb drop. THREE bombs spawn just
	## below the bomber, each one staggered slightly along the
	## bomber's heading so they read as a 'stick' of carpet bombs
	## hitting in a line. Total payload (~650 dmg, AS-tagged) is split
	## across the three impacts; structures still eat the full
	## anti-structure multiplier on every hit, while units shrug off
	## most of each one via the AS role-vs-armor table. Skipped
	## silently if no target.
	if not _combat:
		return false
	var target: Node3D = _combat.get("_current_target") as Node3D
	if not target or not is_instance_valid(target):
		return false
	if "alive_count" in target and (target.get("alive_count") as int) <= 0:
		return false
	const BOMB_COUNT: int = 3
	# Total payload preserved at 650 across the stick; split evenly so
	# each bomb deals ~217 base. The damage application below
	# repeats the splash math per bomb so a target that catches all
	# three takes the full 650.
	const BOMBARD_TOTAL: int = 650
	var per_bomb: int = int(round(float(BOMBARD_TOTAL) / float(BOMB_COUNT)))
	# Stick length -- bombs walk along the bomber's heading so the
	# carpet read is 'a row of impacts', not three bombs stacking on
	# the same crater.
	const STICK_LENGTH: float = 3.6
	var heading: Vector3 = -global_transform.basis.z
	heading.y = 0.0
	if heading.length_squared() < 0.001:
		heading = Vector3.FORWARD
	heading = heading.normalized()
	var faction: int = 0
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "player_faction" in settings and (owner_id == 0):
		faction = settings.get("player_faction") as int
	var splash_radius: float = stats.ability_radius if stats.ability_radius > 0.0 else 5.0
	# Per-bomb splash a touch smaller than the umbrella ability radius
	# so the three impacts feel like distinct craters that overlap on
	# a clustered target rather than one giant blast.
	var per_bomb_radius: float = splash_radius * 0.75
	for b: int in BOMB_COUNT:
		# t goes -1, 0, 1 across the stick (BOMB_COUNT == 3); the
		# corresponding bomb spawns at the bomber-X offset and lands
		# offset along the heading.
		var t: float = (float(b) - float(BOMB_COUNT - 1) * 0.5) / float(maxi(BOMB_COUNT - 1, 1))
		var lateral: Vector3 = heading * t * STICK_LENGTH * 0.5
		var spawn_pos: Vector3 = global_position + lateral + Vector3(0.0, -3.5, 0.0)
		if spawn_pos.y < 0.5:
			spawn_pos.y = 0.5
		# Each bomb aims at a point along the same stick centred on
		# the target, so the visual line of impacts crosses the
		# target.
		var aim_pos: Vector3 = target.global_position + heading * t * STICK_LENGTH * 0.5
		# Cosmetic bomb through ProjectileManager. Damage is applied
		# below via _apply_carpet_bomb_splash, so pending_damage=0.
		var bomb_color: Color = Color(0.9, 0.6, 0.2, 1.0)  # AS = generic warm
		if faction == 1:
			bomb_color = bomb_color.lerp(Color(1.0, 1.0, 1.0, bomb_color.a), 0.4)
		var pm_bomb: ProjectileManager = ProjectileManager.get_instance(get_tree().current_scene if get_tree() else null)
		if pm_bomb != null:
			pm_bomb.fire(spawn_pos, aim_pos, "bomb", bomb_color, 0.0,
					0,  # damage applied via _apply_carpet_bomb_splash
					target as Node3D, self, 0.0, 0,
					(get("owner_id") as int) if "owner_id" in self else -1)
		# Splash damage per bomb. Mirrors the regular AS bomb math --
		# structures take the full hit, units take the AS-vs-armor
		# fraction. Targets caught in multiple impact circles take
		# the sum, which is exactly the desired carpet-bomb behavior.
		_apply_carpet_bomb_splash(aim_pos, per_bomb, per_bomb_radius)
	return true


func _apply_carpet_bomb_splash(aim_pos: Vector3, base_damage: int, splash_radius: float) -> void:
	var splash_radius_sq: float = splash_radius * splash_radius
	var groups: Array[String] = ["units", "buildings", "crawlers"]
	for g: String in groups:
		for node: Node in get_tree().get_nodes_in_group(g):
			if not is_instance_valid(node) or node == self:
				continue
			if not node.has_method("take_damage"):
				continue
			var n3: Node3D = node as Node3D
			if not n3:
				continue
			var dx: float = n3.global_position.x - aim_pos.x
			var dz: float = n3.global_position.z - aim_pos.z
			var dist_sq: float = dx * dx + dz * dz
			if dist_sq > splash_radius_sq:
				continue
			var falloff: float = clampf(1.0 - sqrt(dist_sq) / splash_radius * 0.6, 0.4, 1.0)
			var target_armor: StringName = &"medium"
			if "stats" in n3:
				var ts: Variant = n3.get("stats")
				if typeof(ts) == TYPE_OBJECT and is_instance_valid(ts):
					var unit_stats: UnitStatResource = ts as UnitStatResource
					if unit_stats:
						target_armor = unit_stats.armor_class
			if n3.is_in_group("buildings"):
				target_armor = &"structure"
			var role_mod: float = CombatTables.get_role_modifier(&"AS", target_armor)
			var armor_red: float = CombatTables.get_armor_reduction(target_armor)
			var dmg: float = float(base_damage) * role_mod * (1.0 - armor_red) * falloff
			n3.take_damage(int(dmg), self)


func get_member_positions() -> Array[Vector3]:
	# Single-position aircraft — for combat targeting + muzzle flash
	# spawn this maps to the body center.
	return [global_position]


func get_muzzle_positions() -> Array[Vector3]:
	# Each alive drone in a swarm fires its own shot, so the muzzles
	# come from each drone's world position (drone meshes are children
	# of `self`, so `global_position` returns the world location).
	# Fall back to the aircraft origin if there are no drone meshes
	# (single-body craft like the Hammerhead).
	if _drone_meshes.is_empty():
		return [global_position]
	var positions: Array[Vector3] = []
	for i: int in _drone_meshes.size():
		var drone: Node3D = _drone_meshes[i]
		if not is_instance_valid(drone) or not drone.visible:
			continue
		# Skip drones whose member HP slot is already dead (the visual
		# is hidden by take_damage but a stale alive cache could still
		# reach this).
		if i < member_hp.size() and member_hp[i] <= 0:
			continue
		positions.append(drone.global_position)
	if positions.is_empty():
		return [global_position]
	return positions


func _die() -> void:
	# Release population. Aircraft were leaking pop on death — this
	# call mirrors Unit._die. Player-side units only (owner 0); the AI
	# manages its own pop ledger separately.
	if owner_id == 0:
		var resource_mgr: Node = get_tree().current_scene.get_node_or_null("ResourceManager") if get_tree() else null
		if resource_mgr and resource_mgr.has_method("remove_population") and stats:
			resource_mgr.remove_population(stats.population)
	# Free the selection ring eagerly. The ring is parented to the
	# scene (not the aircraft) so it stays on the ground while the
	# aircraft bobs — but that means queue_free on self DOESN'T cascade
	# to the ring. Without this, the green selection ring kept hovering
	# over a dead aircraft's last position forever.
	if _select_ring and is_instance_valid(_select_ring):
		_select_ring.queue_free()
		_select_ring = null
	# Simple destruction — drop straight down with a fade. A proper
	# crash animation comes when the aircraft visual gets a real
	# scene treatment per faction.
	var tween := create_tween()
	tween.tween_property(self, "global_position:y", 0.0, 0.6).set_ease(Tween.EASE_IN)
	tween.tween_callback(queue_free)


## --- Movement commands (mirror Unit's API so SelectionManager works) ---

func is_returning_to_base() -> bool:
	## Read-only flag — selection_manager + HUD use this to skip the
	## aircraft when the player is trying to issue commands during RTB.
	return _returning_to_base


func begin_return_to_base() -> void:
	## Trigger the RTB sequence — find the nearest friendly HQ, lock
	## the unit into RTB mode, drop any active combat target, and
	## issue an internal move command toward the HQ. Called by the
	## combat path right after a primary-weapon discharge on units
	## whose stats.rtb_after_attack is set.
	var hq_pos: Vector3 = _find_nearest_friendly_hq_pos()
	if hq_pos == Vector3.INF:
		# No HQ found (rare — e.g. all friendly HQs destroyed). Bail
		# silently rather than locking the unit into a perpetual
		# unsacked state; it'll re-trigger on next fire.
		return
	_returning_to_base = true
	_rtb_target_pos = hq_pos
	# Drop any combat target so we don't re-engage en route.
	if _combat:
		if "_current_target" in _combat:
			_combat.set("_current_target", null)
		if _combat.has_method("clear_target"):
			_combat.call("clear_target")
	# Issue the move through the internal command path. Pass
	# clear_combat=false because we already cleared above.
	_force_command_move_to_rtb(hq_pos)


func _force_command_move_to_rtb(target: Vector3) -> void:
	## Bypass the public command_move guard (which refuses commands
	## during RTB) so the RTB itself can fly the unit home.
	var mc: Node = get_node_or_null("MovementComponent")
	if mc != null and mc is AircraftMovement:
		(mc as AircraftMovement).goto_world(target)
	move_target = Vector3(target.x, stats.flight_altitude if stats else global_position.y, target.z)
	move_queue.clear()
	has_move_order = true
	is_holding_position = false


func _find_nearest_friendly_hq_pos() -> Vector3:
	## Scans the buildings group for the closest headquarters owned by
	## the same team as this aircraft. Falls back to Vector3.INF when
	## none exists.
	var scene: SceneTree = get_tree()
	if scene == null:
		return Vector3.INF
	var best_pos: Vector3 = Vector3.INF
	var best_d: float = INF
	var registry: Node = scene.current_scene.get_node_or_null("PlayerRegistry")
	for node: Node in scene.get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var bstats_v: Variant = node.get("stats")
		if bstats_v == null:
			continue
		var bstats: Resource = bstats_v as Resource
		if bstats == null or not ("building_id" in bstats):
			continue
		if bstats.get("building_id") != &"headquarters":
			continue
		var b_owner: int = node.get("owner_id") as int
		var friendly: bool = (b_owner == owner_id)
		if not friendly and registry and registry.has_method("are_allied"):
			friendly = registry.call("are_allied", owner_id, b_owner) as bool
		if not friendly:
			continue
		var n3: Node3D = node as Node3D
		if n3 == null:
			continue
		var d: float = n3.global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best_pos = n3.global_position
	return best_pos


func _tick_return_to_base(_delta: float) -> void:
	## Called once per physics tick while _returning_to_base is set.
	## Checks for arrival at the HQ + refreshes the move command if
	## the original HQ disappeared mid-trip.
	if not _returning_to_base:
		return
	# HQ may have been destroyed mid-trip — pick a fresh one.
	if _rtb_target_pos == Vector3.INF:
		_rtb_target_pos = _find_nearest_friendly_hq_pos()
		if _rtb_target_pos == Vector3.INF:
			# Nowhere to land. Clear RTB so the player can use the
			# unit again (it'll just be unarmed until next reload).
			_returning_to_base = false
			return
		_force_command_move_to_rtb(_rtb_target_pos)
	# Arrival check — horizontal distance only (we're flying above).
	var here: Vector3 = global_position
	var dx: float = here.x - _rtb_target_pos.x
	var dz: float = here.z - _rtb_target_pos.z
	if dx * dx + dz * dz <= RTB_ARRIVAL_RADIUS * RTB_ARRIVAL_RADIUS:
		# Touch-down — clear RTB, stop the aircraft, allow player
		# control again. The unit is now ready to receive new orders.
		_returning_to_base = false
		_rtb_target_pos = Vector3.INF
		stop()


func command_move(target: Vector3, clear_combat: bool = true) -> void:
	# RTB lockout — refuse player commands while the bomber is flying
	# home to rearm. The bomber still finishes its return trip via
	# _force_command_move_to_rtb; only EXTERNAL commands are blocked.
	if _returning_to_base:
		return
	# Route through AircraftMovement when the new system is active (PB-6).
	var mc: Node = get_node_or_null("MovementComponent")
	if mc != null and mc is AircraftMovement:
		(mc as AircraftMovement).goto_world(target)
		has_move_order = true
		is_holding_position = false
		if clear_combat and _combat:
			if "_current_target" in _combat:
				_combat.set("_current_target", null)
			if _combat.has_method("clear_target"):
				_combat.call("clear_target")
		return
	# Legacy direct-lerp path.
	move_target = Vector3(target.x, stats.flight_altitude if stats else global_position.y, target.z)
	move_queue.clear()
	has_move_order = true
	is_holding_position = false
	# Drop any currently-engaged target so the aircraft actually obeys
	# the move order instead of continuing to chase its prior target.
	# Without this, "fall back" right-clicks were ignored — the combat
	# component kept overriding velocity each tick to stay on the foe.
	if clear_combat and _combat:
		if "_current_target" in _combat:
			_combat.set("_current_target", null)
		if _combat.has_method("clear_target"):
			_combat.call("clear_target")


func command_hold_position() -> void:
	move_target = Vector3.INF
	move_queue.clear()
	has_move_order = false
	is_holding_position = true


func command_patrol(_target: Vector3) -> void:
	# Patrol behavior for aircraft is left to a follow-up pass —
	# straight move for now.
	command_move(_target)


func queue_move(target: Vector3) -> void:
	move_queue.append(Vector3(target.x, stats.flight_altitude if stats else global_position.y, target.z))


func stop() -> void:
	move_target = Vector3.INF
	move_queue.clear()
	velocity = Vector3.ZERO
	has_move_order = false
	# Also clear the AircraftMovement target so the new-system path
	# actually halts. Without this, _unit.stop() (called by combat
	# when entering firing range) only zeroed the legacy velocity
	# field while AircraftMovement.target stayed set; SEEK kept
	# pulling the aircraft toward the old chase position, producing
	# the "drifts past target / freezes near old chase pos" symptom.
	var mc: Node = get_node_or_null("MovementComponent")
	if mc != null and mc.has_method("clear_target"):
		mc.call("clear_target")


## --- HP bar (mirrors Unit._build_hp_bar / _update_hp_bar) -----------------

var _hp_bar_bg: MeshInstance3D = null
var _hp_bar_fill: MeshInstance3D = null


func _build_hp_bar() -> void:
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()
	# Aircraft sit at flight_altitude (~8u). Drop the bar to a
	# fixed Y just under the chassis height so it reads at top-
	# down camera distance without being lost in the sky.
	var bar_y: float = (stats.flight_altitude if stats else 8.0) + 0.6
	_hp_bar = Node3D.new()
	_hp_bar.name = "HPBar"
	_hp_bar.position.y = bar_y
	_hp_bar_bg = MeshInstance3D.new()
	var bg_box := BoxMesh.new()
	bg_box.size = Vector3(2.0, 0.12, 0.08)
	_hp_bar_bg.mesh = bg_box
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.7)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hp_bar_bg.set_surface_override_material(0, bg_mat)
	_hp_bar.add_child(_hp_bar_bg)
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
	# top_level so the bar doesn't inherit aircraft tilt / yaw.
	add_child(_hp_bar)
	_hp_bar.top_level = true
	_update_hp_bar()


## Cached pct of last full bar refresh. Compared against current_hp
## on each _process tick to short-circuit the scale/material writes
## when nothing changed. Float so the 0.999 visibility threshold uses
## the same value the writes did. Initialised to -1 so the first call
## always triggers a full write.
var _hp_bar_last_pct: float = -1.0


func _update_hp_bar() -> void:
	if not _hp_bar or not is_instance_valid(_hp_bar):
		return
	if not _hp_bar_fill or not stats:
		return
	# At-full-HP fast path. Aircraft spend the vast majority of their
	# lifetime undamaged; running the position write + pct compute +
	# scale + material recolour every render frame on every aircraft
	# was the dominant per-frame cost in the per-aircraft _process
	# (called unconditionally before the 1-in-3 stagger gate). When
	# the bar is already hidden AND HP is full, all the per-frame
	# work below is wasted -- the bar isn't drawn and pct hasn't
	# changed since the last call. take_damage explicitly invokes
	# _update_hp_bar on every hit so the cached pct gets refreshed
	# the moment damage lands (forces the visible branch on the next
	# tick).
	var pct_now: float = float(maxi(current_hp, 0)) / float(maxi(stats.hp_total, 1))
	if pct_now >= 0.999 and _hp_bar_last_pct >= 0.999 and not _hp_bar.visible:
		return
	# Reposition the bar above the aircraft each tick so it
	# tracks the aircraft as it moves (top_level needs explicit
	# global position updates).
	var bar_y: float = (stats.flight_altitude if stats else 8.0) + 0.6
	_hp_bar.global_position = global_position + Vector3(0.0, bar_y - global_position.y, 0.0)
	# Hide the bar at full HP so it only appears when damaged --
	# matches the land-unit bar policy.
	_hp_bar.visible = pct_now < 0.999
	# Skip the scale + material writes when pct hasn't moved. These
	# only need to refresh when current_hp actually changes; the
	# position update above still runs every frame so the bar tracks
	# the moving aircraft. take_damage call sites trigger the write
	# branch directly.
	if absf(pct_now - _hp_bar_last_pct) < 0.0005:
		return
	_hp_bar_last_pct = pct_now
	var bar_width: float = 2.0
	_hp_bar_fill.scale.x = maxf(pct_now * bar_width, 0.01)
	_hp_bar_fill.position.x = -bar_width * 0.5 * (1.0 - pct_now)
	var fill_mat: StandardMaterial3D = _hp_bar_fill.get_surface_override_material(0) as StandardMaterial3D
	if fill_mat:
		var r: float = 1.0 - pct_now
		var g: float = pct_now
		fill_mat.albedo_color = Color(r, g, 0.1, 0.9)
		fill_mat.emission = Color(r, g, 0.1, 1.0)
