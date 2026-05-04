class_name GeothermicVent
extends StaticBody3D
## A capped fissure of geothermal steam. Generator buildings must
## be placed on top of one of these to function. Open vents emit a
## continuous smoke plume; once a Generator covers the vent the
## plume stops. Roughly the footprint of a Generator (4u square),
## so the visual hides cleanly under the building.
##
## Scene placement happens via TestArenaController's vent setup
## pass. Each player gets 2 close-base vents + 1 forward visible
## vent at start, plus 3 more distributed across the map.

const VENT_SIZE: float = 4.0
const SMOKE_INTERVAL_SEC: float = 0.85

var is_covered: bool = false
var _smoke_timer: float = 0.0
## Cached PEM ref so the per-tick smoke emit doesn't re-walk the
## scene tree.
var _pem: Node = null


func _ready() -> void:
	add_to_group("geothermic_vents")
	# Collision layer 0 (no physics interaction); the vent is a
	# static decoration that the build system queries by group.
	collision_layer = 0
	collision_mask = 0
	_build_visuals()
	# Stagger the smoke timer so a row of vents doesn't all puff
	# in sync.
	_smoke_timer = randf_range(0.0, SMOKE_INTERVAL_SEC)
	if get_tree() and get_tree().current_scene:
		_pem = get_tree().current_scene.get_node_or_null("ParticleEmitterManager")


func _build_visuals() -> void:
	# Concrete-collared rim around the fissure.
	var rim_mat: StandardMaterial3D = StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.30, 0.28, 0.24, 1.0)
	rim_mat.roughness = 0.95
	var rim: MeshInstance3D = MeshInstance3D.new()
	var rim_mesh: CylinderMesh = CylinderMesh.new()
	rim_mesh.top_radius = VENT_SIZE * 0.45
	rim_mesh.bottom_radius = VENT_SIZE * 0.50
	rim_mesh.height = 0.18
	rim_mesh.radial_segments = 12
	rim.mesh = rim_mesh
	rim.position = Vector3(0.0, 0.09, 0.0)
	rim.set_surface_override_material(0, rim_mat)
	add_child(rim)
	# Glowing inner cap -- warm orange pit, gives the vent its
	# 'hot' read at a glance.
	var pit_mat: StandardMaterial3D = StandardMaterial3D.new()
	pit_mat.albedo_color = Color(0.45, 0.20, 0.10, 1.0)
	pit_mat.emission_enabled = true
	pit_mat.emission = Color(1.0, 0.45, 0.15, 1.0)
	pit_mat.emission_energy_multiplier = 1.4
	pit_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	var pit: MeshInstance3D = MeshInstance3D.new()
	var pit_mesh: CylinderMesh = CylinderMesh.new()
	pit_mesh.top_radius = VENT_SIZE * 0.30
	pit_mesh.bottom_radius = VENT_SIZE * 0.32
	pit_mesh.height = 0.06
	pit_mesh.radial_segments = 14
	pit.mesh = pit_mesh
	pit.position = Vector3(0.0, 0.20, 0.0)
	pit.set_surface_override_material(0, pit_mat)
	add_child(pit)
	# Hazard stripe markers around the rim -- four short yellow
	# wedges, same visual language as the fuel-deposit pad.
	var stripe_mat: StandardMaterial3D = StandardMaterial3D.new()
	stripe_mat.albedo_color = Color(0.78, 0.62, 0.10, 1.0)
	stripe_mat.roughness = 0.7
	for w: int in 4:
		var wedge: MeshInstance3D = MeshInstance3D.new()
		var w_box: BoxMesh = BoxMesh.new()
		w_box.size = Vector3(0.4, 0.025, 0.16)
		wedge.mesh = w_box
		var ang: float = float(w) * (PI * 0.5) + PI * 0.25
		wedge.position = Vector3(cos(ang) * VENT_SIZE * 0.55, 0.205, sin(ang) * VENT_SIZE * 0.55)
		wedge.rotation.y = -ang
		wedge.set_surface_override_material(0, stripe_mat)
		add_child(wedge)


## Throttle for the cover-state recheck. Repolling the buildings
## group every frame for every vent at high counts is wasteful;
## ~1 Hz is plenty since a generator either is or isn't on top.
const COVER_RECHECK_INTERVAL: float = 1.1
var _cover_check_timer: float = 0.0


func _process(delta: float) -> void:
	# Periodically rescan for a Generator footprint covering the
	# vent. When found, mark covered (kills the smoke); when the
	# generator is destroyed the recheck flips it back to open.
	_cover_check_timer -= delta
	if _cover_check_timer <= 0.0:
		_cover_check_timer = COVER_RECHECK_INTERVAL + randf_range(-0.1, 0.2)
		_recheck_cover_state()
	if is_covered:
		return
	_smoke_timer -= delta
	if _smoke_timer > 0.0:
		return
	_smoke_timer += SMOKE_INTERVAL_SEC
	# Steady steam plume rising straight up. Pale grey-white tint
	# so it reads as hot vapour, not a smoke smear.
	if _pem and _pem.has_method("emit_smoke"):
		var origin: Vector3 = global_position + Vector3(0.0, 0.4, 0.0)
		_pem.call("emit_smoke", origin, Vector3(0.0, 4.0, 0.0), Color(0.78, 0.80, 0.82, 0.55))


func _recheck_cover_state() -> void:
	## Scans the buildings group for a Generator (basic_generator or
	## advanced_generator) whose footprint overlaps this vent. Sets
	## is_covered accordingly so the smoke plume tracks reality.
	var found: bool = false
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Node3D = node as Node3D
		if not b:
			continue
		var stats: Variant = b.get("stats")
		if stats == null:
			continue
		var bid: StringName = stats.get("building_id") as StringName
		if bid != &"basic_generator" and bid != &"advanced_generator":
			continue
		if b.global_position.distance_to(global_position) < VENT_SIZE * 0.6:
			found = true
			break
	is_covered = found


func mark_covered(covered: bool) -> void:
	## Called by Building when a Generator finishes / is destroyed
	## on this vent. Stops or resumes the steam plume.
	is_covered = covered


static func find_vent_at(scene: Node, world_pos: Vector3, radius: float = 2.5) -> GeothermicVent:
	## Returns the closest GeothermicVent within `radius` of world_pos,
	## or null. Used by the build-placement validity check + the
	## generator's on-construct hook.
	if not scene or not scene.get_tree():
		return null
	var best: GeothermicVent = null
	var best_dist: float = radius
	for node: Node in scene.get_tree().get_nodes_in_group("geothermic_vents"):
		if not is_instance_valid(node):
			continue
		var v: GeothermicVent = node as GeothermicVent
		if not v:
			continue
		var d: float = world_pos.distance_to(v.global_position)
		if d <= best_dist:
			best_dist = d
			best = v
	return best
