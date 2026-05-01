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
var has_move_order: bool = false
var move_target: Vector3 = Vector3.INF
var is_holding_position: bool = false
var move_queue: Array[Vector3] = []
var velocity: Vector3 = Vector3.ZERO

var _combat: Node = null
var _hp_bar: Node3D = null
## Per-drone roots for swarm aircraft (Phalanx, Fang). Each entry is a
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
	# small Phalanx drones — gameplay readability over visual exactness.
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
	if face_dir.length_squared() < 0.0001:
		return
	var target_y: float = atan2(face_dir.x, face_dir.z)
	var turn_speed: float = 5.0  # rad/s — aircraft turn slightly slower than light mechs
	rotation.y = lerp_angle(rotation.y, target_y, clampf(turn_speed * delta, 0.0, 1.0))


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


func _process(delta: float) -> void:
	if alive_count <= 0:
		return
	# Maintain altitude — drift toward the configured flight altitude
	# even if something nudges us off it. The aircraft's whole body
	# bobs around the target altitude on a sin curve so single-body
	# craft (gunships, interceptors) read as airborne the same way the
	# swarm drones do via their per-drone bob.
	_altitude_anim_time += delta
	if stats:
		var hover: float = sin(_altitude_anim_time * ALTITUDE_BOB_FREQ + _bob_phase) * ALTITUDE_BOB_AMP
		var target_y: float = stats.flight_altitude + hover
		global_position.y = lerp(global_position.y, target_y, clampf(delta * 4.0, 0.0, 1.0))

	# Track the shadow blob to the aircraft's XZ. Y is pinned to ~ground
	# (a small lift above 0 so it isn't z-fighting with the terrain).
	if _shadow_blob and is_instance_valid(_shadow_blob):
		_shadow_blob.global_position = Vector3(global_position.x, 0.06, global_position.z)
	if _select_ring and is_instance_valid(_select_ring):
		_select_ring.global_position = Vector3(global_position.x, 0.08, global_position.z)

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
		"Fang Drone":
			_build_drone_swarm(10, _team_color(), Color(0.10, 0.11, 0.13), 0.55, false)
		"Hammerhead Gunship":
			_build_hammerhead()
		"Switchblade Interceptor":
			_build_switchblade()
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
	## `is_anvil_blocky` selects the drone silhouette style: Anvil drones
	## are squat boxes with stubby wings (Phalanx); Sable drones are
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
		var pairs: int = (n - 1) / 2
		for r: int in pairs:
			var rank: int = r + 1
			var x: float = spacing * float(rank)
			var z: float = -spacing * 0.85 * float(rank)
			arr.append(Vector3(-x, 0.0, z))
			arr.append(Vector3(+x, 0.0, z))
	else:
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


func _build_hammerhead() -> void:
	# Heavy gunship — wide low-profile body, weapon pods underneath,
	# tail rotor + twin engine nacelles. Anvil's flagship aircraft.
	# v3 polish: scaled ~25% smaller and densified with cockpit canopy,
	# intake grilles, panel-line strips, antenna mast, and ventral fin
	# so the silhouette doesn't read as a single chunky box.
	var team: Color = _team_color()
	var body_color := Color(0.32, 0.30, 0.27, 1.0)

	# Wide hull (smaller than v1 — was 2.6x0.7x4.5).
	var hull := MeshInstance3D.new()
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(2.0, 0.55, 3.4)
	hull.mesh = hull_box
	hull.set_surface_override_material(0, _aircraft_metal_mat(body_color))
	add_child(hull)

	# Tapered nose — angled slab in front.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_box := BoxMesh.new()
	nose_box.size = Vector3(1.5, 0.45, 0.95)
	nose.mesh = nose_box
	nose.position = Vector3(0, -0.04, 2.0)
	nose.rotation.x = -0.20
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.05)))
	add_child(nose)

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

	# Twin engine nacelles flanking the body.
	for side: int in 2:
		var sx: float = 1.0 if side == 0 else -1.0
		var nacelle := MeshInstance3D.new()
		nacelle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var nacelle_box := BoxMesh.new()
		nacelle_box.size = Vector3(0.50, 0.55, 2.0)
		nacelle.mesh = nacelle_box
		nacelle.position = Vector3(sx * 1.30, 0.0, -0.30)
		nacelle.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.1)))
		add_child(nacelle)

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

	# Underwing weapon pods (missile racks). Now with visible missile
	# tubes on the front face for fine detail at zoom.
	for side: int in 2:
		var sx: float = 1.0 if side == 0 else -1.0
		var pod := MeshInstance3D.new()
		pod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pod_box := BoxMesh.new()
		pod_box.size = Vector3(0.36, 0.28, 1.20)
		pod.mesh = pod_box
		pod.position = Vector3(sx * 0.78, -0.36, 0.40)
		pod.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.15)))
		add_child(pod)
		# Three missile tube ends visible on the front face of each pod.
		for tube_i: int in 3:
			var tube := MeshInstance3D.new()
			tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var tube_cyl := CylinderMesh.new()
			tube_cyl.top_radius = 0.06
			tube_cyl.bottom_radius = 0.06
			tube_cyl.height = 0.08
			tube.mesh = tube_cyl
			tube.rotation.x = PI * 0.5
			var tx: float = sx * 0.78 + (float(tube_i) - 1.0) * 0.10
			tube.position = Vector3(tx, -0.36, 1.04)
			tube.set_surface_override_material(0, _aircraft_metal_mat(Color(0.10, 0.10, 0.10, 1.0)))
			add_child(tube)

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

	# Slim antenna mast on the spine — tiny silhouette punctuation.
	var ant := MeshInstance3D.new()
	ant.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ant_box := BoxMesh.new()
	ant_box.size = Vector3(0.05, 0.45, 0.05)
	ant.mesh = ant_box
	ant.position = Vector3(0, 0.65, -0.40)
	ant.set_surface_override_material(0, _aircraft_metal_mat(Color(0.12, 0.12, 0.12, 1.0)))
	add_child(ant)


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

	# Sharp nose cone.
	var nose := MeshInstance3D.new()
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var nose_box := BoxMesh.new()
	nose_box.size = Vector3(0.45, 0.35, 0.9)
	nose.mesh = nose_box
	nose.position.z = 2.0
	nose.set_surface_override_material(0, _aircraft_metal_mat(body_color.darkened(0.2)))
	add_child(nose)

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

	# Cockpit canopy — emissive cool-blue slit.
	var canopy := MeshInstance3D.new()
	canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var canopy_box := BoxMesh.new()
	canopy_box.size = Vector3(0.45, 0.18, 1.2)
	canopy.mesh = canopy_box
	canopy.position = Vector3(0, 0.32, 0.6)
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


const SABLE_NEON_PALE := Color(0.45, 0.95, 1.0, 1.0)


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


func get_squad_strength_ratio() -> float:
	if not stats or stats.squad_size <= 0:
		return 0.0
	return float(current_hp) / float(maxi(stats.hp_total, 1))


func get_combat() -> Node:
	return _combat


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
	# Simple destruction — drop straight down with a fade. A proper
	# crash animation comes when the aircraft visual gets a real
	# scene treatment per faction.
	var tween := create_tween()
	tween.tween_property(self, "global_position:y", 0.0, 0.6).set_ease(Tween.EASE_IN)
	tween.tween_callback(queue_free)


## --- Movement commands (mirror Unit's API so SelectionManager works) ---

func command_move(target: Vector3, clear_combat: bool = true) -> void:
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
