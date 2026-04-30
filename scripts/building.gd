class_name Building
extends StaticBody3D
## Base building. Handles HP, power draw, production queue, and rally point.

signal unit_produced(unit_scene: PackedScene, spawn_point: Vector3)
signal destroyed
signal construction_complete

@export var stats: BuildingStatResource
@export var owner_faction: FactionResource
@export var owner_id: int = 0

## When true the building behaves as a placement-preview ghost: no group
## membership, no collision, no nav obstacle, no logic components. Visuals are
## still built so the player can see exactly what they're placing.
var is_ghost_preview: bool = false

## Set during placement by the builder.
var is_constructed: bool = false
var current_hp: int = 0
var _construction_progress: float = 0.0

## Production queue — array of UnitStatResource.
var _build_queue: Array[UnitStatResource] = []
var _build_progress: float = 0.0

## Rally point for produced units.
var rally_point: Vector3 = Vector3.ZERO

## Reference to the game's resource manager (set externally).
var resource_manager: Node = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D as MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D as CollisionShape3D
@onready var _spawn_marker: Marker3D = $SpawnPoint as Marker3D

const PLAYER_COLOR := Color(0.15, 0.45, 0.9, 1.0)
const ENEMY_COLOR := Color(0.85, 0.2, 0.15, 1.0)
const NEUTRAL_COLOR := Color(0.85, 0.7, 0.3, 1.0)


static func team_color_for(owner_idx: int) -> Color:
	# Static fallback used by tools / tests that lack a PlayerRegistry.
	# Live colors at runtime go through `_resolve_team_color`.
	if owner_idx == 0:
		return PLAYER_COLOR
	if owner_idx == 2:
		return NEUTRAL_COLOR
	return ENEMY_COLOR


func _resolve_team_color() -> Color:
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("get_perspective_color"):
		return registry.get_perspective_color(owner_id)
	return Building.team_color_for(owner_id)
var _team_ring: MeshInstance3D = null

var _progress_bg: MeshInstance3D = null
var _progress_bar: MeshInstance3D = null
var _progress_mat: StandardMaterial3D = null
var _progress_label: Label3D = null
var _bar_width: float = 0.0

## Holds all visual children (mesh, team ring, type-specific details). The
## construction-rise animation lifts this single node from below ground to its
## final position; collision/nav obstacle stay fixed at scene root.
var _visual_root: Node3D = null

## Gun-emplacement turret pivot — rotates around Y to track the current target.
## Set by _detail_gun_emplacement; read by TurretComponent.
var turret_pivot: Node3D = null

## Damage-state visuals. The "smoke" node is just a container of spawn-point
## markers — actual smoke is rising puffs spawned from _process. Fire is a
## small cluster of independently-flickering embers + an orange OmniLight3D
## that casts real light on the building.
var _damage_smoke: Node3D = null
var _damage_smoke_anchors: Array[Node3D] = []
var _damage_smoke_timer: float = 0.0
var _damage_fire: Node3D = null
var _damage_embers: Array = []  # Array of { mesh: MeshInstance3D, mat: StandardMaterial3D, base: float, phase: float }
var _damage_fire_light: OmniLight3D = null
## Continuously-advancing time used to animate damage VFX.
var _damage_anim_time: float = 0.0

## Atmospheric idle animations — captured by detail builders if the type has
## something worth animating. All are optional; nulls are skipped.
var _atmos_dish: Node3D = null                          # HQ radar — slow Y spin
var _atmos_stack_tops: Array[Node3D] = []               # Foundry stack tips for smoke puffs
var _atmos_generator_cap_mat: StandardMaterial3D = null # Pulsing reactor cap
var _atmos_beacon_mat: StandardMaterial3D = null        # HQ beacon throbber
var _atmos_beacon_light: OmniLight3D = null             # Real light source synced to the beacon
var _atmos_generator_light: OmniLight3D = null          # Cyan reactor glow
var _atmos_stack_lights: Array[OmniLight3D] = []        # Hot-orange stack-tip lights
var _atmos_indicator_mats: Array = []                   # Foundry/armory front lights
var _atmos_anim_time: float = 0.0
var _atmos_smoke_timer: float = 0.0


func _ready() -> void:
	if is_ghost_preview:
		# Ghost preview: visuals only. No groups, no collision, no logic.
		if stats:
			is_constructed = true
			_ensure_visual_root()
			_apply_placeholder_shape()
			_add_building_details()
			if _collision:
				_collision.disabled = true
		return

	add_to_group("buildings")
	add_to_group("owner_%d" % owner_id)
	if stats:
		current_hp = stats.hp
		rally_point = global_position + Vector3(0, 0, stats.footprint_size.z + 2.0)
		_ensure_visual_root()
		_apply_placeholder_shape()
		_add_nav_obstacle()
		_add_building_details()
		_apply_function_roof_cap()
		# Per-mesh AABBs are tiny (smokestacks, vents, ribs etc.) so
		# Godot frustum-culls each detail piece individually as the
		# camera nears the screen edge — smokestacks pop in/out, the
		# building "peels". Generous cull margin keeps every visual
		# child drawn until the building's center is well off-screen.
		_apply_visual_cull_margin(_visual_root, 12.0)

		# Specialized logic components.
		if stats.building_id == &"salvage_yard":
			var script: GDScript = load("res://scripts/salvage_yard_component.gd") as GDScript
			var yard: Node = script.new()
			yard.name = "SalvageYardComponent"
			add_child(yard)
		elif stats.building_id == &"gun_emplacement":
			var turret_script: GDScript = load("res://scripts/turret_component.gd") as GDScript
			var turret: Node = turret_script.new()
			turret.name = "TurretComponent"
			add_child(turret)


func _ensure_visual_root() -> void:
	if _visual_root and is_instance_valid(_visual_root):
		return
	_visual_root = Node3D.new()
	_visual_root.name = "VisualRoot"
	# Slight Y rotation per real building so the bases don't read as a flat
	# row of identical boxes from the RTS camera. Ghost previews stay aligned
	# (rotation = 0) so the player sees exactly what they're placing.
	# Turret pivots compensate via TurretComponent._aim_at_target.
	if not is_ghost_preview:
		_visual_root.rotation.y = randf_range(-0.22, 0.22)
	add_child(_visual_root)


func _attach_visual(node: Node3D) -> void:
	_ensure_visual_root()
	_visual_root.add_child(node)


func _apply_visual_cull_margin(root: Node, margin: float) -> void:
	## Walks the visual tree and bumps `extra_cull_margin` on every
	## VisualInstance3D so the small per-mesh AABBs (smokestacks, ribs,
	## vents, etc.) stay drawn until the *whole building* is off-screen,
	## not just each individual detail.
	if root is VisualInstance3D:
		(root as VisualInstance3D).extra_cull_margin = margin
	for child: Node in root.get_children():
		_apply_visual_cull_margin(child, margin)


## --- Per-building visual details ---

func _add_building_details() -> void:
	## Add type-specific decorations on top of the placeholder box so each
	## building is recognizable at a glance: foundries get smokestacks,
	## generators get cooling fins, salvage yards get crane arms, etc.
	if not stats:
		return
	# Universal extras applied to every building. These read as "lived-in
	# industrial detail" without overlapping the type-specific silhouette.
	_detail_universal_extras()
	match stats.building_id:
		&"headquarters": _detail_headquarters()
		&"basic_foundry": _detail_foundry(false)
		&"advanced_foundry": _detail_foundry(true)
		&"basic_generator": _detail_generator()
		&"basic_armory": _detail_armory()
		&"salvage_yard": _detail_salvage_yard()
		&"gun_emplacement": _detail_gun_emplacement()


func _detail_universal_extras() -> void:
	## Pipes / vents / front doorway glow that every building gets so even
	## the simplest hull reads as "machinery", not "concrete cube".
	if not stats:
		return
	var fs: Vector3 = stats.footprint_size

	# Side wall ribs — three parallel vertical strips on each long side
	# break up the otherwise flat hull faces.
	for side: int in 2:
		var sx: float = -fs.x * 0.5 - 0.04 if side == 0 else fs.x * 0.5 + 0.04
		for i: int in 3:
			var rib := MeshInstance3D.new()
			var rb := BoxMesh.new()
			rb.size = Vector3(0.06, fs.y * 0.55, 0.18)
			rib.mesh = rb
			rib.position = Vector3(
				sx,
				fs.y * 0.45,
				-fs.z * 0.32 + float(i) * fs.z * 0.32,
			)
			rib.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.15, 0.14)))
			_attach_visual(rib)

	# Roof vents — two small box stacks near the rear of the roof.
	for i: int in 2:
		var vent := MeshInstance3D.new()
		var vb := BoxMesh.new()
		vb.size = Vector3(0.22, 0.32, 0.22)
		vent.mesh = vb
		vent.position = Vector3(
			-fs.x * 0.18 + float(i) * fs.x * 0.36,
			fs.y + 0.16,
			fs.z * 0.32,
		)
		vent.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.2, 0.18)))
		_attach_visual(vent)

	# Front doorway glow — small emissive square low on the front face.
	# Skip on buildings whose main detail layer already puts a feature
	# right where we'd draw it (foundry's loading door, gun emplacement's
	# turret base) so we don't double-stack geometry.
	var bid: StringName = stats.building_id
	if bid != &"basic_foundry" and bid != &"advanced_foundry" and bid != &"gun_emplacement":
		var doorway := MeshInstance3D.new()
		var dbox := BoxMesh.new()
		dbox.size = Vector3(fs.x * 0.22, fs.y * 0.18, 0.05)
		doorway.mesh = dbox
		doorway.position = Vector3(0.0, fs.y * 0.16, -fs.z * 0.5 - 0.03)
		doorway.set_surface_override_material(0, _detail_emissive_mat(Color(0.95, 0.55, 0.2), 0.9))
		_attach_visual(doorway)

	# Subtle external pipework — a single conduit running along one side
	# of the hull. Adds the dieselpunk read.
	var pipe := MeshInstance3D.new()
	var pipe_box := BoxMesh.new()
	pipe_box.size = Vector3(0.1, 0.1, fs.z * 0.85)
	pipe.mesh = pipe_box
	pipe.position = Vector3(fs.x * 0.5 + 0.1, fs.y * 0.85, 0.0)
	pipe.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.26, 0.18)))
	_attach_visual(pipe)
	# Pipe couplings every ~third of its length.
	for i: int in 3:
		var coupling := MeshInstance3D.new()
		var cb := BoxMesh.new()
		cb.size = Vector3(0.16, 0.16, 0.16)
		coupling.mesh = cb
		coupling.position = Vector3(
			fs.x * 0.5 + 0.1,
			fs.y * 0.85,
			-fs.z * 0.3 + float(i) * fs.z * 0.3,
		)
		coupling.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
		_attach_visual(coupling)

	# Maintenance ladder up the rear-left side — vertical rails + rungs.
	var ladder_x: float = -fs.x * 0.4
	var ladder_z: float = fs.z * 0.5 + 0.05
	for rail_side: int in 2:
		var rail_off: float = -0.08 if rail_side == 0 else 0.08
		var rail := MeshInstance3D.new()
		var rb := BoxMesh.new()
		rb.size = Vector3(0.04, fs.y * 0.85, 0.04)
		rail.mesh = rb
		rail.position = Vector3(ladder_x + rail_off, fs.y * 0.45, ladder_z)
		rail.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.2, 0.16)))
		_attach_visual(rail)
	var rung_count: int = maxi(int(fs.y * 1.4), 3)
	for r: int in rung_count:
		var rung := MeshInstance3D.new()
		var rung_box := BoxMesh.new()
		rung_box.size = Vector3(0.20, 0.03, 0.03)
		rung.mesh = rung_box
		var t: float = (float(r) + 0.5) / float(rung_count)
		rung.position = Vector3(ladder_x, fs.y * t * 0.85 + 0.05, ladder_z + 0.02)
		rung.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.14, 0.12)))
		_attach_visual(rung)

	# Floor-line emissive markers — three small amber points around the
	# base perimeter. Reads as "guide lights / marshalling lamps".
	var marker_offsets: Array[Vector3] = [
		Vector3(-fs.x * 0.45, 0.05, -fs.z * 0.5 - 0.04),
		Vector3(fs.x * 0.45, 0.05, -fs.z * 0.5 - 0.04),
		Vector3(0.0, 0.05, -fs.z * 0.5 - 0.04),
	]
	for off: Vector3 in marker_offsets:
		var marker := MeshInstance3D.new()
		var m_box := BoxMesh.new()
		m_box.size = Vector3(0.08, 0.08, 0.08)
		marker.mesh = m_box
		marker.position = off
		marker.set_surface_override_material(0, _detail_emissive_mat(Color(0.95, 0.7, 0.25), 1.4))
		_attach_visual(marker)

	# Cargo crate cluster on the right-rear — three stacked boxes of
	# varying tones. Sells the "active base" feel without taking up
	# the silhouette real-estate the type-specific builder uses.
	var crate_anchor: Vector3 = Vector3(fs.x * 0.35, 0.0, fs.z * 0.5 + 0.6)
	for ci: int in 3:
		var crate := MeshInstance3D.new()
		var crate_box := BoxMesh.new()
		var cw: float = randf_range(0.32, 0.5)
		var ch: float = randf_range(0.3, 0.45)
		crate_box.size = Vector3(cw, ch, cw)
		crate.mesh = crate_box
		crate.rotation.y = randf_range(-0.25, 0.25)
		crate.position = crate_anchor + Vector3(
			float(ci) * 0.15 + randf_range(-0.05, 0.05),
			ch * 0.5,
			float(ci) * 0.18,
		)
		var crate_color: Color = Color(0.32, 0.28, 0.20).darkened(randf_range(0.0, 0.2))
		crate.set_surface_override_material(0, _detail_dark_metal_mat(crate_color))
		_attach_visual(crate)

	# Stair / loading ramp on the front-left, angled down to ground.
	var ramp := MeshInstance3D.new()
	var ramp_box := BoxMesh.new()
	ramp_box.size = Vector3(fs.x * 0.18, 0.06, fs.z * 0.22)
	ramp.mesh = ramp_box
	ramp.rotation.x = deg_to_rad(-12.0)
	ramp.position = Vector3(-fs.x * 0.32, 0.06, -fs.z * 0.5 - fs.z * 0.10)
	ramp.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.20, 0.17)))
	_attach_visual(ramp)


func _detail_dark_metal_mat(c: Color = Color(0.18, 0.18, 0.2)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	m.metallic = 0.4
	return m


func _detail_emissive_mat(c: Color, energy: float = 1.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	m.roughness = 0.5
	return m


func _add_production_door(width: float, height: float) -> void:
	## Recessed dark door on the camera-facing (+Z) side of the building, sized
	## per the unit class trained inside. Larger units → bigger door.
	if not stats:
		return
	var fs: Vector3 = stats.footprint_size
	var door := MeshInstance3D.new()
	var db := BoxMesh.new()
	db.size = Vector3(width, height, 0.08)
	door.mesh = db
	door.position = Vector3(0, height * 0.5 + 0.05, fs.z * 0.5 + 0.04)
	door.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.08, 0.08, 0.1)))
	_attach_visual(door)

	# Top door rail (lighter trim).
	var rail := MeshInstance3D.new()
	var rb := BoxMesh.new()
	rb.size = Vector3(width + 0.1, 0.06, 0.04)
	rail.mesh = rb
	rail.position = Vector3(0, height + 0.05, fs.z * 0.5 + 0.07)
	rail.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.3, 0.25)))
	_attach_visual(rail)


func _team_collar(width: float, height: float, depth: float, pos: Vector3) -> void:
	## Small team-colored band at the base of a detail tower (smokestack,
	## spire, turret base, crane pole, etc.) so the hull-band's identity
	## carries up through the upper geometry too.
	var team_color: Color = _resolve_team_color()
	var collar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, height, depth)
	collar.mesh = box
	collar.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = team_color
	mat.emission_enabled = true
	mat.emission = team_color
	mat.emission_energy_multiplier = 1.2
	mat.roughness = 0.6
	collar.set_surface_override_material(0, mat)
	_attach_visual(collar)


func _detail_headquarters() -> void:
	var fs: Vector3 = stats.footprint_size
	# Team collar at the base of the spire so the upper geometry stays readable.
	_team_collar(fs.x * 0.32, 0.12, fs.z * 0.32, Vector3(0, fs.y + 0.06, 0))
	# Central command spire — a tall thin tower rising from the roof.
	var spire := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(fs.x * 0.25, fs.y * 0.65, fs.z * 0.25)
	spire.mesh = sb
	spire.position = Vector3(0, fs.y + sb.size.y * 0.5, 0)
	spire.set_surface_override_material(0, _detail_dark_metal_mat())
	_attach_visual(spire)

	# Radar dish on top of the spire. Static parts (mast + base collar)
	# stay outside the rotating pivot so a sweeping dish doesn't drag a
	# glowing dot or a tilted base around with it. The pivot rotates a
	# parabolic dome + a feed horn that's structurally attached to the
	# dome's back.
	var dish_top_y: float = fs.y + sb.size.y + 0.55
	# Static base collar — small disc on top of the spire so the spire's
	# square corners are hidden when the dish rotates.
	var dish_collar := MeshInstance3D.new()
	var collar_cyl := CylinderMesh.new()
	collar_cyl.top_radius = fs.x * 0.18
	collar_cyl.bottom_radius = fs.x * 0.22
	collar_cyl.height = 0.1
	dish_collar.mesh = collar_cyl
	dish_collar.position = Vector3(0.0, fs.y + sb.size.y + 0.05, 0.0)
	dish_collar.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.28, 0.26, 0.24)))
	_attach_visual(dish_collar)
	# Static vertical mast under the rotating dome — the dome sits on top
	# of it. Doesn't rotate with the pivot.
	var dish_mast := MeshInstance3D.new()
	var mast_box := BoxMesh.new()
	mast_box.size = Vector3(0.08, 0.45, 0.08)
	dish_mast.mesh = mast_box
	dish_mast.position = Vector3(0.0, dish_top_y - 0.22, 0.0)
	dish_mast.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
	_attach_visual(dish_mast)
	# Rotating pivot — only the dish bowl + feed horn live under here.
	var dish_pivot := Node3D.new()
	dish_pivot.position = Vector3(0.0, dish_top_y, 0.0)
	_attach_visual(dish_pivot)
	# Parabolic dome — squashed sphere tilted forward 30° so the camera
	# sees the bowl shape clearly. Sphere never produces visible "corners"
	# during rotation.
	var dish_bowl := MeshInstance3D.new()
	var bowl_sphere := SphereMesh.new()
	bowl_sphere.radius = fs.x * 0.34
	bowl_sphere.height = fs.x * 0.14
	dish_bowl.mesh = bowl_sphere
	dish_bowl.rotation = Vector3(deg_to_rad(30.0), 0.0, 0.0)
	dish_bowl.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.34, 0.34, 0.36)))
	dish_pivot.add_child(dish_bowl)
	# Concentric ring on the dome surface for added detail — reads as a
	# rim panel.
	var bowl_rim := MeshInstance3D.new()
	var rim_torus := TorusMesh.new()
	rim_torus.inner_radius = fs.x * 0.28
	rim_torus.outer_radius = fs.x * 0.34
	rim_torus.rings = 24
	rim_torus.ring_segments = 8
	bowl_rim.mesh = rim_torus
	bowl_rim.rotation = Vector3(deg_to_rad(30.0), 0.0, 0.0)
	bowl_rim.position = Vector3(0.0, sin(deg_to_rad(30.0)) * 0.04, 0.0)
	bowl_rim.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.22, 0.24)))
	dish_pivot.add_child(bowl_rim)
	# Feed horn — small box held in front of the dish on a thin tripod
	# strut. Stays attached to the dish so it doesn't appear to "float".
	var horn_strut := MeshInstance3D.new()
	var strut_box := BoxMesh.new()
	strut_box.size = Vector3(0.04, 0.05, fs.x * 0.32)
	horn_strut.mesh = strut_box
	horn_strut.rotation = Vector3(deg_to_rad(30.0), 0.0, 0.0)
	horn_strut.position = Vector3(0.0, 0.05, -fs.x * 0.14)
	horn_strut.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
	dish_pivot.add_child(horn_strut)
	var horn := MeshInstance3D.new()
	var horn_box := BoxMesh.new()
	horn_box.size = Vector3(0.14, 0.14, 0.18)
	horn.mesh = horn_box
	# Front of the dish (negative-Z under rotation) where the focal point
	# of a real parabolic feed sits.
	horn.rotation = Vector3(deg_to_rad(30.0), 0.0, 0.0)
	horn.position = Vector3(0.0, 0.18, -fs.x * 0.30)
	horn.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.45, 0.38, 0.18)))
	dish_pivot.add_child(horn)
	# Tiny emissive indicator on the horn so the rotation direction is
	# legible. Attached to the horn (not floating) — orbits with the dish
	# but always sits flush against the horn's front face.
	var horn_lamp := MeshInstance3D.new()
	var lamp_sphere := SphereMesh.new()
	lamp_sphere.radius = 0.04
	lamp_sphere.height = 0.08
	horn_lamp.mesh = lamp_sphere
	horn_lamp.rotation = Vector3(deg_to_rad(30.0), 0.0, 0.0)
	horn_lamp.position = Vector3(0.0, 0.20, -fs.x * 0.34)
	horn_lamp.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.55, 0.2), 1.6))
	dish_pivot.add_child(horn_lamp)
	_atmos_dish = dish_pivot

	# Beacon light on the spire — pulses via _process.
	var beacon := MeshInstance3D.new()
	var beacon_sphere := SphereMesh.new()
	beacon_sphere.radius = 0.12
	beacon_sphere.height = 0.24
	beacon.mesh = beacon_sphere
	beacon.position = Vector3(0, fs.y + sb.size.y + 0.45, 0)
	var beacon_mat: StandardMaterial3D = _detail_emissive_mat(Color(1.0, 0.4, 0.2), 2.5)
	beacon.set_surface_override_material(0, beacon_mat)
	_attach_visual(beacon)
	_atmos_beacon_mat = beacon_mat
	# Real light so the beacon throw casts on the spire and surrounding hull.
	_atmos_beacon_light = OmniLight3D.new()
	_atmos_beacon_light.light_color = Color(1.0, 0.45, 0.18)
	_atmos_beacon_light.light_energy = 1.6
	_atmos_beacon_light.omni_range = 4.5
	_atmos_beacon_light.position = beacon.position
	_attach_visual(_atmos_beacon_light)

	# Forge-core glow — a wider, dimmer amber pool centered on the HQ that
	# bleeds onto nearby ground. Gives the player's command center a
	# "city aglow at night" presence per READABILITY_PASS.md §Task 5.
	var forge_pool := OmniLight3D.new()
	forge_pool.light_color = Color(1.0, 0.55, 0.2)
	forge_pool.light_energy = 0.9
	forge_pool.omni_range = 22.0
	forge_pool.omni_attenuation = 1.6
	forge_pool.position = Vector3(0.0, fs.y * 0.45, 0.0)
	_attach_visual(forge_pool)

	# Lower flanking wings on each side, like fortified bunkers.
	for side: int in 2:
		var sx: float = -fs.x * 0.5 - 0.6 if side == 0 else fs.x * 0.5 + 0.6
		var wing := MeshInstance3D.new()
		var wb := BoxMesh.new()
		wb.size = Vector3(1.2, fs.y * 0.55, fs.z * 0.7)
		wing.mesh = wb
		wing.position = Vector3(sx, wb.size.y * 0.5, 0)
		wing.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.25, 0.22, 0.2)))
		_attach_visual(wing)

	# Four corner spotlights with green emissive lenses — security floodlights.
	var corner_offsets: Array[Vector2] = [
		Vector2(-fs.x * 0.45, -fs.z * 0.45),
		Vector2(fs.x * 0.45, -fs.z * 0.45),
		Vector2(-fs.x * 0.45, fs.z * 0.45),
		Vector2(fs.x * 0.45, fs.z * 0.45),
	]
	for c: Vector2 in corner_offsets:
		var post := MeshInstance3D.new()
		var post_box := BoxMesh.new()
		post_box.size = Vector3(0.12, 0.4, 0.12)
		post.mesh = post_box
		post.position = Vector3(c.x, fs.y + post_box.size.y * 0.5, c.y)
		post.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.18, 0.18)))
		_attach_visual(post)
		# `corner_lamp_sphere` rather than `lamp_sphere` — the radar dish
		# code earlier in this function already declares a `lamp_sphere`,
		# and GDScript 4 treats two `var` declarations with the same name
		# in one function (even across blocks) as a duplicate error.
		var lamp := MeshInstance3D.new()
		var corner_lamp_sphere := SphereMesh.new()
		corner_lamp_sphere.radius = 0.08
		corner_lamp_sphere.height = 0.16
		lamp.mesh = corner_lamp_sphere
		lamp.position = Vector3(c.x, fs.y + post_box.size.y, c.y)
		lamp.set_surface_override_material(0, _detail_emissive_mat(Color(0.5, 1.0, 0.4), 1.6))
		_attach_visual(lamp)

	# Wide trim band around the top of the main hull.
	var trim := MeshInstance3D.new()
	var trim_box := BoxMesh.new()
	trim_box.size = Vector3(fs.x * 1.02, 0.18, fs.z * 1.02)
	trim.mesh = trim_box
	trim.position = Vector3(0, fs.y - 0.05, 0)
	trim.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.2, 0.18, 0.16)))
	_attach_visual(trim)

	# Spawn door for engineers (small unit door on the camera-facing side).
	_add_production_door(1.1, 1.5)


func _detail_foundry(advanced: bool) -> void:
	var fs: Vector3 = stats.footprint_size
	# Team collar at the base of the main smokestack.
	_team_collar(fs.x * 0.32, 0.1, fs.z * 0.32, Vector3(fs.x * 0.28, fs.y + 0.05, fs.z * 0.18))
	# Off-center smokestack.
	var stack := MeshInstance3D.new()
	var stack_cyl := CylinderMesh.new()
	stack_cyl.top_radius = fs.x * 0.12
	stack_cyl.bottom_radius = fs.x * 0.16
	stack_cyl.height = fs.y * (1.1 if advanced else 0.9)
	stack.mesh = stack_cyl
	stack.position = Vector3(fs.x * 0.28, fs.y + stack_cyl.height * 0.5, fs.z * 0.18)
	stack.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.15, 0.13, 0.12)))
	_attach_visual(stack)

	# Glowing rim at the top of the stack — molten interior.
	var glow := MeshInstance3D.new()
	var glow_cyl := CylinderMesh.new()
	glow_cyl.top_radius = stack_cyl.top_radius * 0.85
	glow_cyl.bottom_radius = stack_cyl.top_radius * 0.85
	glow_cyl.height = 0.08
	glow.mesh = glow_cyl
	glow.position = Vector3(stack.position.x, fs.y + stack_cyl.height + 0.04, stack.position.z)
	glow.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.45, 0.1), 3.0))
	_attach_visual(glow)
	# Hot-orange light at the stack tip — sells the molten interior.
	var stack_light := OmniLight3D.new()
	stack_light.light_color = Color(1.0, 0.5, 0.15)
	stack_light.light_energy = 1.4
	stack_light.omni_range = 3.0
	stack_light.position = Vector3(stack.position.x, fs.y + stack_cyl.height + 0.1, stack.position.z)
	_attach_visual(stack_light)
	_atmos_stack_lights.append(stack_light)
	# Marker at the stack tip — drives periodic smoke puffs.
	var stack_top := Marker3D.new()
	stack_top.position = Vector3(stack.position.x, fs.y + stack_cyl.height + 0.1, stack.position.z)
	_attach_visual(stack_top)
	_atmos_stack_tops.append(stack_top)

	# Intake vent on the front face.
	var vent := MeshInstance3D.new()
	var vent_box := BoxMesh.new()
	vent_box.size = Vector3(fs.x * 0.45, fs.y * 0.18, 0.08)
	vent.mesh = vent_box
	vent.position = Vector3(0, fs.y * 0.5, -fs.z * 0.5 - 0.03)
	vent.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.12, 0.12, 0.12)))
	_attach_visual(vent)

	# For advanced foundry, add a second smaller stack and a roof detail.
	if advanced:
		var stack2 := MeshInstance3D.new()
		var stack2_cyl := CylinderMesh.new()
		stack2_cyl.top_radius = fs.x * 0.09
		stack2_cyl.bottom_radius = fs.x * 0.12
		stack2_cyl.height = fs.y * 0.7
		stack2.mesh = stack2_cyl
		stack2.position = Vector3(-fs.x * 0.3, fs.y + stack2_cyl.height * 0.5, fs.z * 0.1)
		stack2.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.15, 0.13, 0.12)))
		_attach_visual(stack2)
		var stack2_top := Marker3D.new()
		stack2_top.position = Vector3(-fs.x * 0.3, fs.y + stack2_cyl.height + 0.08, fs.z * 0.1)
		_attach_visual(stack2_top)
		_atmos_stack_tops.append(stack2_top)

	# Ore intake hopper — angled wedge on the left side.
	var hopper := MeshInstance3D.new()
	var hopper_box := BoxMesh.new()
	hopper_box.size = Vector3(0.7, fs.y * 0.35, fs.z * 0.5)
	hopper.mesh = hopper_box
	hopper.rotation.z = 0.35
	hopper.position = Vector3(-fs.x * 0.5 - 0.2, fs.y * 0.7, 0)
	hopper.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.2, 0.18)))
	_attach_visual(hopper)

	# Three indicator lights on the front face — pulse via _process for life.
	for i: int in 3:
		var light := MeshInstance3D.new()
		var ls := SphereMesh.new()
		ls.radius = 0.06
		ls.height = 0.12
		light.mesh = ls
		light.position = Vector3((float(i) - 1.0) * 0.35, fs.y * 0.85, -fs.z * 0.5 - 0.06)
		var lcolor: Color = Color(1.0, 0.6, 0.2) if i == 1 else Color(0.5, 0.95, 0.4)
		var lmat: StandardMaterial3D = _detail_emissive_mat(lcolor, 1.8)
		light.set_surface_override_material(0, lmat)
		_attach_visual(light)
		# Cache with a phase offset so they don't all blink in sync.
		_atmos_indicator_mats.append({ "mat": lmat, "phase": float(i) * 1.6, "base": 1.8 })

	# Side panel ribs along both walls — heavy industrial look.
	for side: int in 2:
		var sx: float = -fs.x * 0.5 - 0.04 if side == 0 else fs.x * 0.5 + 0.04
		for r: int in 4:
			var rib := MeshInstance3D.new()
			var rb := BoxMesh.new()
			rb.size = Vector3(0.06, fs.y * 0.85, 0.18)
			rib.mesh = rb
			var rz: float = (float(r) - 1.5) * fs.z * 0.25
			rib.position = Vector3(sx, fs.y * 0.5, rz)
			rib.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.15)))
			_attach_visual(rib)

	# Production door — bigger for the advanced foundry which builds Bulwark.
	if advanced:
		_add_production_door(4.0, 2.6)
	else:
		_add_production_door(2.7, 1.9)


func _detail_generator() -> void:
	var fs: Vector3 = stats.footprint_size
	# Team collar at the base of the central core tower.
	_team_collar(fs.x * 0.7, 0.1, fs.z * 0.7, Vector3(0, fs.y + 0.05, 0))
	# Central cylindrical core protruding above the housing.
	var core := MeshInstance3D.new()
	var core_cyl := CylinderMesh.new()
	core_cyl.top_radius = fs.x * 0.3
	core_cyl.bottom_radius = fs.x * 0.32
	core_cyl.height = fs.y * 0.55
	core.mesh = core_cyl
	core.position = Vector3(0, fs.y + core_cyl.height * 0.5, 0)
	core.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.25, 0.25, 0.28)))
	_attach_visual(core)

	# Vertical cooling fins around the core (4 cardinal sides).
	for i: int in 4:
		var ang: float = float(i) * PI * 0.5
		var fin := MeshInstance3D.new()
		var fin_box := BoxMesh.new()
		fin_box.size = Vector3(0.08, fs.y * 0.55, fs.x * 0.18)
		fin.mesh = fin_box
		var dx: float = sin(ang) * (fs.x * 0.32 + 0.05)
		var dz: float = cos(ang) * (fs.x * 0.32 + 0.05)
		fin.position = Vector3(dx, fs.y + fin_box.size.y * 0.5, dz)
		fin.rotation.y = -ang
		fin.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.22, 0.22)))
		_attach_visual(fin)

	# Glowing top cap — pulses via _process.
	var cap := MeshInstance3D.new()
	var cap_cyl := CylinderMesh.new()
	cap_cyl.top_radius = fs.x * 0.22
	cap_cyl.bottom_radius = fs.x * 0.22
	cap_cyl.height = 0.12
	cap.mesh = cap_cyl
	cap.position = Vector3(0, fs.y + core_cyl.height + cap_cyl.height * 0.5, 0)
	var cap_mat: StandardMaterial3D = _detail_emissive_mat(Color(0.3, 0.85, 1.0), 2.0)
	cap.set_surface_override_material(0, cap_mat)
	_attach_visual(cap)
	_atmos_generator_cap_mat = cap_mat
	# Cyan reactor light bathes the housing.
	_atmos_generator_light = OmniLight3D.new()
	_atmos_generator_light.light_color = Color(0.3, 0.85, 1.0)
	_atmos_generator_light.light_energy = 2.0
	_atmos_generator_light.omni_range = 5.5
	_atmos_generator_light.position = cap.position
	_attach_visual(_atmos_generator_light)

	# Wider base flange around the bottom of the housing.
	var flange := MeshInstance3D.new()
	var flange_cyl := CylinderMesh.new()
	flange_cyl.top_radius = fs.x * 0.55
	flange_cyl.bottom_radius = fs.x * 0.55
	flange_cyl.height = 0.18
	flange.mesh = flange_cyl
	flange.position = Vector3(0, 0.09, 0)
	flange.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.16, 0.18)))
	_attach_visual(flange)

	# Cable trunks routed up the housing on opposite sides.
	for side: int in 2:
		var sx: float = -fs.x * 0.5 - 0.06 if side == 0 else fs.x * 0.5 + 0.06
		var cable := MeshInstance3D.new()
		var cb := BoxMesh.new()
		cb.size = Vector3(0.08, fs.y * 0.85, 0.18)
		cable.mesh = cb
		cable.position = Vector3(sx, fs.y * 0.5, 0)
		cable.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.15, 0.13, 0.12)))
		_attach_visual(cable)

	# Warning stripes around the housing — angled hazard pattern.
	var stripe := MeshInstance3D.new()
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(fs.x * 1.02, 0.12, fs.z * 1.02)
	stripe.mesh = stripe_box
	stripe.position = Vector3(0, fs.y * 0.25, 0)
	stripe.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.7, 0.1), 1.0))
	_attach_visual(stripe)


func _detail_armory() -> void:
	var fs: Vector3 = stats.footprint_size
	# Vertical rib panels along each side wall — like ammunition lockers.
	for side: int in 2:
		var sx: float = -fs.x * 0.5 if side == 0 else fs.x * 0.5
		for i: int in 3:
			var rib := MeshInstance3D.new()
			var rib_box := BoxMesh.new()
			rib_box.size = Vector3(0.06, fs.y * 0.7, 0.18)
			rib.mesh = rib_box
			var rib_z: float = (float(i) - 1.0) * fs.z * 0.3
			rib.position = Vector3(sx + (-0.04 if side == 0 else 0.04), fs.y * 0.5, rib_z)
			rib.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.2, 0.18)))
			_attach_visual(rib)

	# Indicator strip across the front.
	var strip := MeshInstance3D.new()
	var strip_box := BoxMesh.new()
	strip_box.size = Vector3(fs.x * 0.7, 0.06, 0.04)
	strip.mesh = strip_box
	strip.position = Vector3(0, fs.y * 0.78, -fs.z * 0.5 - 0.02)
	strip.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.85, 0.3), 1.6))
	_attach_visual(strip)

	# Loading dock door on the front — recessed panel with a horizontal bar.
	var dock := MeshInstance3D.new()
	var dock_box := BoxMesh.new()
	dock_box.size = Vector3(fs.x * 0.4, fs.y * 0.55, 0.08)
	dock.mesh = dock_box
	dock.position = Vector3(0, fs.y * 0.3, -fs.z * 0.5 - 0.04)
	dock.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.14, 0.13, 0.12)))
	_attach_visual(dock)

	var dock_bar := MeshInstance3D.new()
	var dock_bar_box := BoxMesh.new()
	dock_bar_box.size = Vector3(fs.x * 0.42, 0.05, 0.02)
	dock_bar.mesh = dock_bar_box
	dock_bar.position = Vector3(0, fs.y * 0.4, -fs.z * 0.5 - 0.085)
	dock_bar.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.3, 0.28, 0.25)))
	_attach_visual(dock_bar)

	# Stacked ammo crates against the right side wall.
	for c: int in 2:
		var crate := MeshInstance3D.new()
		var cb := BoxMesh.new()
		cb.size = Vector3(0.4, 0.4, 0.4)
		crate.mesh = cb
		crate.position = Vector3(fs.x * 0.5 + 0.25, 0.2 + float(c) * 0.42, -fs.z * 0.2)
		crate.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.42, 0.32, 0.18)))
		_attach_visual(crate)

	# Roof overhang lip.
	var lip := MeshInstance3D.new()
	var lip_box := BoxMesh.new()
	lip_box.size = Vector3(fs.x * 1.1, 0.1, 0.4)
	lip.mesh = lip_box
	lip.position = Vector3(0, fs.y, -fs.z * 0.5 - 0.15)
	lip.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.2, 0.18)))
	_attach_visual(lip)


func _detail_salvage_yard() -> void:
	var fs: Vector3 = stats.footprint_size
	# Team collar at the base of the crane pole.
	_team_collar(0.32, 0.08, 0.32, Vector3(fs.x * 0.3, fs.y + 0.04, -fs.z * 0.3))
	# Crane arm — tall pole with a horizontal jib.
	var pole := MeshInstance3D.new()
	var pole_box := BoxMesh.new()
	pole_box.size = Vector3(0.12, fs.y * 1.4, 0.12)
	pole.mesh = pole_box
	pole.position = Vector3(fs.x * 0.3, fs.y + pole_box.size.y * 0.5, -fs.z * 0.3)
	pole.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.35, 0.3, 0.18)))
	_attach_visual(pole)

	var jib := MeshInstance3D.new()
	var jib_box := BoxMesh.new()
	jib_box.size = Vector3(fs.x * 0.6, 0.08, 0.08)
	jib.mesh = jib_box
	jib.position = Vector3(fs.x * 0.0, fs.y + pole_box.size.y - 0.12, -fs.z * 0.3)
	jib.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.35, 0.3, 0.18)))
	_attach_visual(jib)

	# Hook hanging from the jib.
	var hook := MeshInstance3D.new()
	var hook_box := BoxMesh.new()
	hook_box.size = Vector3(0.08, 0.2, 0.08)
	hook.mesh = hook_box
	hook.position = Vector3(-fs.x * 0.25, fs.y + pole_box.size.y - 0.35, -fs.z * 0.3)
	hook.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.15, 0.13, 0.12)))
	_attach_visual(hook)

	# Small storage bins on the deck.
	for i: int in 2:
		var bin := MeshInstance3D.new()
		var bin_box := BoxMesh.new()
		bin_box.size = Vector3(fs.x * 0.25, fs.y * 0.45, fs.z * 0.25)
		bin.mesh = bin_box
		bin.position = Vector3(-fs.x * 0.22 + float(i) * fs.x * 0.45, fs.y + bin_box.size.y * 0.5, fs.z * 0.22)
		bin.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.28, 0.18)))
		_attach_visual(bin)

	# Scrap pile on the front — pile of dark salvage chunks.
	for s: int in 4:
		var chunk := MeshInstance3D.new()
		var chunk_box := BoxMesh.new()
		var sz: float = randf_range(0.18, 0.32)
		chunk_box.size = Vector3(sz, sz * 0.6, sz)
		chunk.mesh = chunk_box
		chunk.rotation.y = randf_range(0.0, TAU)
		chunk.position = Vector3(
			-fs.x * 0.2 + float(s) * 0.18,
			sz * 0.3,
			-fs.z * 0.5 - 0.4
		)
		chunk.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
		_attach_visual(chunk)

	# Working-glow lamp under the crane arm — soft amber pool that says
	# "this building is busy". Per READABILITY_PASS.md §Task 5, it's a
	# distinct visual cue from the Crawler's brighter reactor lamp.
	var work_lamp := OmniLight3D.new()
	work_lamp.light_color = Color(1.0, 0.6, 0.2)
	work_lamp.light_energy = 0.7
	work_lamp.omni_range = 4.5
	work_lamp.position = Vector3(0.0, fs.y + 0.4, 0.0)
	_attach_visual(work_lamp)

	# Crane support strut from the pole base back to the chassis.
	var strut := MeshInstance3D.new()
	var strut_box := BoxMesh.new()
	strut_box.size = Vector3(0.1, 0.1, fs.z * 0.4)
	strut.mesh = strut_box
	strut.rotation.x = -0.6
	strut.position = Vector3(fs.x * 0.3, fs.y * 0.5 + 0.4, -fs.z * 0.1)
	strut.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.3, 0.26, 0.16)))
	_attach_visual(strut)


func _detail_gun_emplacement() -> void:
	var fs: Vector3 = stats.footprint_size
	# Team collar around the base of the turret.
	_team_collar(fs.x * 0.95, 0.1, fs.z * 0.95, Vector3(0, fs.y + 0.05, 0))
	# Pivot at the top center of the chassis; the turret + barrel rotate
	# around its Y axis to track targets. The barrel meshes themselves are
	# rebuilt by `rebuild_turret_visual` whenever the profile changes.
	var pivot := Node3D.new()
	pivot.name = "TurretPivot"
	pivot.position = Vector3(0, fs.y, 0)
	_attach_visual(pivot)
	turret_pivot = pivot

	rebuild_turret_visual(&"balanced")


func rebuild_turret_visual(profile: StringName) -> void:
	## Replaces all children of `turret_pivot` with a profile-specific turret.
	## anti_light = quad-barrel rotary; anti_heavy = single thick howitzer;
	## anti_air = tall slim missile rack with skyward tilt; balanced = the
	## original cylindrical autocannon.
	if not turret_pivot:
		return
	var fs: Vector3 = stats.footprint_size

	# Wipe existing barrels/dome.
	for child: Node in turret_pivot.get_children():
		child.queue_free()

	# Dome — color varies subtly per profile.
	var dome_color: Color = Color(0.3, 0.28, 0.25)
	match profile:
		&"anti_light": dome_color = Color(0.32, 0.32, 0.28)
		&"anti_heavy": dome_color = Color(0.36, 0.3, 0.22)
		&"anti_air":   dome_color = Color(0.25, 0.3, 0.36)

	var dome_sphere := SphereMesh.new()
	dome_sphere.radius = fs.x * 0.42
	dome_sphere.height = fs.x * 0.5
	var dome := MeshInstance3D.new()
	dome.mesh = dome_sphere
	dome.position.y = dome_sphere.height * 0.25
	dome.set_surface_override_material(0, _detail_dark_metal_mat(dome_color))
	turret_pivot.add_child(dome)

	var arm_y: float = dome_sphere.height * 0.35
	var dark: StandardMaterial3D = _detail_dark_metal_mat(Color(0.18, 0.16, 0.16))

	match profile:
		&"anti_light":
			# Quad short barrels (rotary autocannon look).
			for i: int in 4:
				var ang: float = float(i) / 4.0 * TAU
				var bx: float = cos(ang) * 0.07
				var by: float = sin(ang) * 0.07
				var b := MeshInstance3D.new()
				var bc := CylinderMesh.new()
				bc.top_radius = 0.045
				bc.bottom_radius = 0.045
				bc.height = fs.x * 0.7
				b.mesh = bc
				b.rotation.x = -PI / 2
				b.position = Vector3(bx, arm_y + by, -bc.height * 0.5 - 0.05)
				b.set_surface_override_material(0, dark)
				turret_pivot.add_child(b)
		&"anti_heavy":
			# Single thick howitzer barrel + chunky muzzle brake.
			var b := MeshInstance3D.new()
			var bc := CylinderMesh.new()
			bc.top_radius = 0.16
			bc.bottom_radius = 0.18
			bc.height = fs.x * 1.05
			b.mesh = bc
			b.rotation.x = -PI / 2
			b.position = Vector3(0, arm_y, -bc.height * 0.5 - 0.05)
			b.set_surface_override_material(0, dark)
			turret_pivot.add_child(b)
			# Muzzle brake — fat ring at the tip.
			var muzzle := MeshInstance3D.new()
			var mc := CylinderMesh.new()
			mc.top_radius = 0.24
			mc.bottom_radius = 0.22
			mc.height = 0.16
			muzzle.mesh = mc
			muzzle.rotation.x = -PI / 2
			muzzle.position = Vector3(0, arm_y, -bc.height - 0.13)
			muzzle.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.1, 0.1, 0.1)))
			turret_pivot.add_child(muzzle)
		&"anti_air":
			# Missile rack — three tubes pointing up-and-forward, plus a small
			# radar dish.
			var rack_pivot := Node3D.new()
			rack_pivot.position.y = arm_y + 0.05
			rack_pivot.rotation.x = -0.4  # tilt skyward
			turret_pivot.add_child(rack_pivot)
			for i: int in 3:
				var tube := MeshInstance3D.new()
				var tc := CylinderMesh.new()
				tc.top_radius = 0.07
				tc.bottom_radius = 0.07
				tc.height = fs.x * 0.5
				tube.mesh = tc
				tube.rotation.x = -PI / 2
				tube.position = Vector3((float(i) - 1.0) * 0.18, 0.05, -tc.height * 0.5 - 0.04)
				tube.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.2, 0.22, 0.28)))
				rack_pivot.add_child(tube)
			# Side radar dish.
			var dish := MeshInstance3D.new()
			var dish_sphere := SphereMesh.new()
			dish_sphere.radius = 0.14
			dish_sphere.height = 0.18
			dish.mesh = dish_sphere
			dish.position = Vector3(fs.x * 0.3, arm_y + 0.18, 0)
			dish.set_surface_override_material(0, _detail_emissive_mat(Color(0.4, 1.0, 0.5), 1.4))
			turret_pivot.add_child(dish)
		_:
			# Balanced — original single autocannon.
			var b := MeshInstance3D.new()
			var bc := CylinderMesh.new()
			bc.top_radius = 0.1
			bc.bottom_radius = 0.12
			bc.height = fs.x * 0.9
			b.mesh = bc
			b.rotation.x = -PI / 2
			b.position = Vector3(0, arm_y, -bc.height * 0.5 - 0.05)
			b.set_surface_override_material(0, dark)
			turret_pivot.add_child(b)
			# Muzzle ring.
			var muzzle := MeshInstance3D.new()
			var mc := CylinderMesh.new()
			mc.top_radius = 0.14
			mc.bottom_radius = 0.14
			mc.height = 0.1
			muzzle.mesh = mc
			muzzle.rotation.x = -PI / 2
			muzzle.position = Vector3(0, arm_y, -bc.height - 0.1)
			muzzle.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.1, 0.1, 0.1)))
			turret_pivot.add_child(muzzle)

	# Ammo crate at the base of the emplacement (decorative, doesn't rotate).
	var crate := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(0.5, 0.4, 0.35)
	crate.mesh = cb
	crate.position = Vector3(-fs.x * 0.4, 0.2, fs.z * 0.4)
	crate.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.26, 0.16)))
	_attach_visual(crate)

	# Sandbag wall around two sides of the base.
	for i: int in 4:
		var sandbag := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.35, 0.18, 0.22)
		sandbag.mesh = sb
		sandbag.position = Vector3(-fs.x * 0.45 + float(i) * 0.32, 0.09, -fs.z * 0.5 - 0.18)
		sandbag.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.35, 0.32, 0.22)))
		_attach_visual(sandbag)

	# Reinforced base plate around the emplacement.
	var base_plate := MeshInstance3D.new()
	var bp_box := BoxMesh.new()
	bp_box.size = Vector3(fs.x * 1.05, 0.18, fs.z * 1.05)
	base_plate.mesh = bp_box
	base_plate.position = Vector3(0, 0.09, 0)
	base_plate.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.18, 0.2)))
	_attach_visual(base_plate)


func _add_nav_obstacle() -> void:
	var obstacle := NavigationObstacle3D.new()
	obstacle.name = "NavObstacle"
	# Create a rectangular obstacle matching the building footprint
	var half_x: float = stats.footprint_size.x * 0.6
	var half_z: float = stats.footprint_size.z * 0.6
	obstacle.vertices = PackedVector3Array([
		Vector3(-half_x, 0, -half_z),
		Vector3(half_x, 0, -half_z),
		Vector3(half_x, 0, half_z),
		Vector3(-half_x, 0, half_z),
	])
	obstacle.avoidance_enabled = true
	obstacle.radius = maxf(half_x, half_z)
	add_child(obstacle)


func _apply_placeholder_shape() -> void:
	if not stats:
		return

	# Most buildings use a rectangular hull; the basic generator uses a
	# squat cylinder so its silhouette doesn't read as "another box".
	var fs: Vector3 = stats.footprint_size
	if stats.building_id == &"basic_generator":
		var cyl := CylinderMesh.new()
		cyl.top_radius = fs.x * 0.5
		cyl.bottom_radius = fs.x * 0.55
		cyl.height = fs.y
		_mesh.mesh = cyl
	else:
		var box := BoxMesh.new()
		box.size = fs
		_mesh.mesh = box
	_mesh.position.y = fs.y / 2.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = stats.placeholder_color
	mat.roughness = 0.9
	if not is_constructed:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.5
	_mesh.set_surface_override_material(0, mat)

	# Move the visual mesh under VisualRoot so the construction-rise tween
	# carries it; collision stays at scene root.
	_ensure_visual_root()
	if _mesh.get_parent() != _visual_root:
		_mesh.reparent(_visual_root, false)

	# Buried while under construction, fully risen once complete. AI buildings
	# spawn with is_constructed=true immediately and skip the rise.
	if _visual_root:
		if is_constructed:
			_visual_root.position.y = 0.0
		else:
			_visual_root.position.y = -stats.footprint_size.y * 0.95

	var col_shape := BoxShape3D.new()
	col_shape.size = stats.footprint_size
	_collision.shape = col_shape
	_collision.position.y = stats.footprint_size.y / 2.0
	_apply_team_ring()


func _apply_team_ring() -> void:
	if _team_ring and is_instance_valid(_team_ring):
		_team_ring.queue_free()
		_team_ring = null

	if not stats:
		return

	var team_color: Color = _resolve_team_color()

	# Horizontal team-color band wrapping the building. Slightly larger than the
	# footprint in X/Z so it sits proud of the walls and is visible from every
	# angle. Replaces the old inverted-shell trick which only rendered on one
	# face from the RTS camera angle.
	_team_ring = MeshInstance3D.new()
	# Match the hull shape — cylinder body gets a cylindrical band so it
	# wraps without weird edge clipping.
	if stats.building_id == &"basic_generator":
		var ring_cyl := CylinderMesh.new()
		ring_cyl.top_radius = stats.footprint_size.x * 0.5 + 0.06
		ring_cyl.bottom_radius = stats.footprint_size.x * 0.55 + 0.06
		ring_cyl.height = stats.footprint_size.y * 0.14
		_team_ring.mesh = ring_cyl
	else:
		var stripe := BoxMesh.new()
		stripe.size = Vector3(
			stats.footprint_size.x + 0.12,
			stats.footprint_size.y * 0.14,
			stats.footprint_size.z + 0.12
		)
		_team_ring.mesh = stripe
	# Near the bottom of the hull — keeps the silhouette readable while leaving
	# the upper detail layers (turrets, stacks, spires) free for their own band.
	_team_ring.position.y = stats.footprint_size.y * 0.18

	var mat := StandardMaterial3D.new()
	mat.albedo_color = team_color
	mat.emission_enabled = true
	mat.emission = team_color
	mat.emission_energy_multiplier = 1.4
	mat.roughness = 0.6
	_team_ring.set_surface_override_material(0, mat)

	_attach_visual(_team_ring)
	_apply_anvil_brass_band()


## Anvil identity strip — a thin brass band that sits just above the
## team-color ring on the front face of the building. Per
## READABILITY_PASS.md §Task 7, it's an additive accent: the team color
## still does the ownership signal, brass marks the *faction*. The
## infrastructure is the same shape that future factions (Sable / Synod /
## Inheritors) will swap their own accent material into.
const ANVIL_BRASS := Color(0.78, 0.62, 0.18, 1.0)
var _brass_band: MeshInstance3D = null


## Function-coded roof-cap colors per READABILITY_PASS.md §Task 2. Picks
## the cap tint from the building's category so a glance at the roof
## reveals what the building does (production vs economy vs power vs
## defense) without having to select it.
const _ROOF_PRODUCTION: Color = Color(0.22, 0.22, 0.24, 1.0)   # gunmetal grey
const _ROOF_ECONOMY: Color    = Color(0.65, 0.36, 0.18, 1.0)   # copper-orange
const _ROOF_TECH: Color       = Color(0.78, 0.66, 0.32, 1.0)   # pale brass
const _ROOF_POWER: Color      = Color(0.20, 0.24, 0.32, 1.0)   # deep blue-grey
const _ROOF_DEFENSE: Color    = Color(0.10, 0.10, 0.10, 1.0)   # near-black
const _ROOF_HQ: Color         = Color(0.16, 0.14, 0.12, 1.0)   # dark with brass inlay (added separately)


func _roof_color_for_category() -> Color:
	if not stats:
		return _ROOF_PRODUCTION
	match stats.building_id:
		&"headquarters":
			return _ROOF_HQ
		&"basic_foundry", &"advanced_foundry":
			return _ROOF_PRODUCTION
		&"salvage_yard":
			return _ROOF_ECONOMY
		&"basic_armory":
			return _ROOF_TECH
		&"basic_generator":
			return _ROOF_POWER
		&"gun_emplacement":
			return _ROOF_DEFENSE
		_:
			return _ROOF_PRODUCTION


var _roof_cap: MeshInstance3D = null
var _roof_accent: MeshInstance3D = null


func _apply_function_roof_cap() -> void:
	if _roof_cap and is_instance_valid(_roof_cap):
		_roof_cap.queue_free()
		_roof_cap = null
	if _roof_accent and is_instance_valid(_roof_accent):
		_roof_accent.queue_free()
		_roof_accent = null
	if not stats:
		return

	# Generator already has an emissive cap; the silhouette would clash if
	# we also stuck a flat box on top. Skip the cap on cylindrical builds.
	if stats.building_id == &"basic_generator":
		return

	# Roof slab — sits on top of the placeholder hull, slightly inset so
	# the team-color band still wraps the lower portion cleanly.
	var fp: Vector3 = stats.footprint_size
	_roof_cap = MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	cap_box.size = Vector3(fp.x * 0.9, fp.y * 0.08, fp.z * 0.9)
	_roof_cap.mesh = cap_box
	_roof_cap.position.y = fp.y * 0.92
	var cap_color: Color = _roof_color_for_category()
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = cap_color
	cap_mat.roughness = 0.7
	cap_mat.metallic = 0.3
	_roof_cap.set_surface_override_material(0, cap_mat)
	_attach_visual(_roof_cap)

	# HQ identity flourish — the doc calls for "distinctive dark with brass
	# accent" so the player's command center never reads as an ordinary
	# building. A small brass disc on top is enough for placeholder.
	if stats.building_id == &"headquarters":
		_roof_accent = MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = fp.x * 0.18
		disc.bottom_radius = fp.x * 0.22
		disc.height = fp.y * 0.05
		_roof_accent.mesh = disc
		_roof_accent.position.y = fp.y * 0.99
		var disc_mat := StandardMaterial3D.new()
		disc_mat.albedo_color = ANVIL_BRASS
		disc_mat.emission_enabled = true
		disc_mat.emission = ANVIL_BRASS
		disc_mat.emission_energy_multiplier = 0.6
		disc_mat.metallic = 0.8
		disc_mat.roughness = 0.35
		_roof_accent.set_surface_override_material(0, disc_mat)
		_attach_visual(_roof_accent)
	# Defense category — small red warning inlay so it reads as "shooting"
	# rather than "industrial".
	elif stats.building_id == &"gun_emplacement":
		_roof_accent = MeshInstance3D.new()
		var inlay := BoxMesh.new()
		inlay.size = Vector3(fp.x * 0.4, fp.y * 0.04, fp.z * 0.18)
		_roof_accent.mesh = inlay
		_roof_accent.position.y = fp.y * 0.96
		var inlay_mat := StandardMaterial3D.new()
		inlay_mat.albedo_color = Color(0.85, 0.12, 0.10, 1.0)
		inlay_mat.emission_enabled = true
		inlay_mat.emission = Color(0.95, 0.2, 0.15, 1.0)
		inlay_mat.emission_energy_multiplier = 0.8
		_roof_accent.set_surface_override_material(0, inlay_mat)
		_attach_visual(_roof_accent)


func _apply_anvil_brass_band() -> void:
	if _brass_band and is_instance_valid(_brass_band):
		_brass_band.queue_free()
		_brass_band = null
	if not stats:
		return
	# Skip the construction foundation — only show the brass once the
	# building visual is real.
	_brass_band = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(
		stats.footprint_size.x * 0.55,
		stats.footprint_size.y * 0.06,
		0.05,
	)
	_brass_band.mesh = box
	_brass_band.position = Vector3(
		0.0,
		stats.footprint_size.y * 0.32,
		-stats.footprint_size.z * 0.5 - 0.03,
	)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ANVIL_BRASS
	mat.emission_enabled = true
	mat.emission = ANVIL_BRASS
	mat.emission_energy_multiplier = 0.5
	mat.metallic = 0.7
	mat.roughness = 0.4
	_brass_band.set_surface_override_material(0, mat)
	_attach_visual(_brass_band)


func begin_construction() -> void:
	_construction_progress = 0.0
	is_constructed = false
	_apply_placeholder_shape()
	_create_progress_bar()
	# Foundation is a "ghost" — units can walk into and out of it freely until
	# the structure is complete. Solid collision is enabled in _finish_construction.
	if _collision:
		_collision.disabled = true
	# Sink the visuals so the building rises out of the ground as it's built.
	if _visual_root and stats:
		_visual_root.position.y = -stats.footprint_size.y * 0.95


func advance_construction(amount: float) -> void:
	if is_constructed:
		return
	# Construction halts while any unit is standing inside the footprint, so
	# foundations placed on top of units (or with units passing through) wait
	# for the area to clear before progressing.
	if not _is_foundation_clear():
		return
	_construction_progress += amount
	_update_progress_bar()
	_update_construction_rise()
	if _construction_progress >= stats.build_time:
		_finish_construction()


func _update_construction_rise() -> void:
	## Lerp the visual root from -fs.y * 0.95 (mostly buried) to 0 (fully risen)
	## as the construction progresses.
	if not _visual_root or not stats:
		return
	var pct: float = get_construction_percent()
	_visual_root.position.y = -stats.footprint_size.y * 0.95 * (1.0 - pct)


func _is_foundation_clear() -> bool:
	## True when no unit's center is inside (or just at the edge of) the
	## building's XZ footprint. Margin = 0.4 prevents construction completing
	## while a unit is straddling the boundary, which used to trap engineers
	## the moment collision activated.
	if not stats:
		return true
	var half_x: float = stats.footprint_size.x * 0.5 + 0.4
	var half_z: float = stats.footprint_size.z * 0.5 + 0.4
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var node3d: Node3D = node as Node3D
		if not node3d:
			continue
		var dx: float = absf(node3d.global_position.x - global_position.x)
		var dz: float = absf(node3d.global_position.z - global_position.z)
		if dx < half_x and dz < half_z:
			return false
	return true


func get_construction_percent() -> float:
	if not stats or stats.build_time <= 0.0:
		return 1.0
	return clampf(_construction_progress / stats.build_time, 0.0, 1.0)


func _finish_construction() -> void:
	is_constructed = true
	_construction_progress = stats.build_time
	construction_complete.emit()
	_apply_placeholder_shape()
	_remove_progress_bar()
	# Tell the arena to re-bake the navmesh now that this footprint is
	# active — without this, pathfinders keep routing units straight into
	# the new wall and stuck-rescue eventually gives up on the move order.
	var arena: Node = get_tree().current_scene
	if arena and arena.has_method("request_navmesh_rebake"):
		arena.request_navmesh_rebake()
	# Belt-and-suspenders: even though _is_foundation_clear gates progress,
	# fast-moving units can slip into the footprint between frames. Push any
	# stragglers out before the collision shape activates.
	_kick_units_out_of_footprint()
	# Solidify now that the structure stands.
	if _collision:
		_collision.disabled = false
	if _visual_root:
		_visual_root.position.y = 0.0


func _kick_units_out_of_footprint() -> void:
	if not stats:
		return
	var half_x: float = stats.footprint_size.x * 0.5
	var half_z: float = stats.footprint_size.z * 0.5
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var u: Node3D = node as Node3D
		if not u:
			continue
		var dx: float = u.global_position.x - global_position.x
		var dz: float = u.global_position.z - global_position.z
		var inside_x: bool = absf(dx) < half_x
		var inside_z: bool = absf(dz) < half_z
		if not (inside_x and inside_z):
			continue
		# Pop the unit out along whichever axis it's closest to escaping.
		var dx_in: float = half_x - absf(dx)
		var dz_in: float = half_z - absf(dz)
		if dx_in < dz_in:
			var dir_x: float = 1.0
			if dx < 0.0:
				dir_x = -1.0
			u.global_position.x = global_position.x + (half_x + 0.6) * dir_x
		else:
			var dir_z: float = 1.0
			if dz < 0.0:
				dir_z = -1.0
			u.global_position.z = global_position.z + (half_z + 0.6) * dir_z


func _create_progress_bar() -> void:
	if _progress_bar:
		return

	_bar_width = stats.footprint_size.x
	# Lift the bar well above the tallest detail (spires, smokestacks, crane
	# arms) so decorative geometry never obscures the construction percentage.
	var bar_y: float = stats.footprint_size.y * 1.5 + 2.0
	var half_w: float = _bar_width * 0.5

	# Dark background bar (full width)
	_progress_bg = MeshInstance3D.new()
	var bg_mesh := BoxMesh.new()
	bg_mesh.size = Vector3(_bar_width, 0.2, 0.4)
	_progress_bg.mesh = bg_mesh
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.15, 0.15, 0.15, 0.8)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_progress_bg.set_surface_override_material(0, bg_mat)
	_progress_bg.position = Vector3(0, bar_y, 0)
	add_child(_progress_bg)

	# Fill bar (grows left to right)
	_progress_bar = MeshInstance3D.new()
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(1.0, 0.25, 0.45)
	_progress_bar.mesh = bar_mesh

	_progress_mat = StandardMaterial3D.new()
	_progress_mat.albedo_color = Color(1.0, 0.2, 0.1, 0.9)
	_progress_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_progress_mat.emission_enabled = true
	_progress_mat.emission = Color(1.0, 0.2, 0.1, 1.0)
	_progress_mat.emission_energy_multiplier = 1.0
	_progress_bar.set_surface_override_material(0, _progress_mat)

	# Start at left edge
	_progress_bar.position = Vector3(-half_w, bar_y, 0)
	_progress_bar.scale.x = 0.01
	add_child(_progress_bar)

	# Percentage label
	_progress_label = Label3D.new()
	_progress_label.text = "0%"
	_progress_label.font_size = 48
	_progress_label.pixel_size = 0.02
	_progress_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_progress_label.position = Vector3(0, bar_y + 0.6, 0)
	_progress_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	add_child(_progress_label)


func _update_progress_bar() -> void:
	if not _progress_bar:
		return
	var pct: float = get_construction_percent()
	var fill_width: float = _bar_width * pct
	var half_w: float = _bar_width * 0.5

	# Scale the bar mesh and position it so it grows from the left edge
	_progress_bar.scale.x = maxf(fill_width, 0.01)
	_progress_bar.position.x = -half_w + fill_width * 0.5

	# Shift color from red to green
	var r: float = 1.0 - pct
	var g: float = pct
	_progress_mat.albedo_color = Color(r, g, 0.1, 0.9)
	_progress_mat.emission = Color(r, g, 0.1, 1.0)

	# Update label
	if _progress_label:
		_progress_label.text = "%d%%" % int(pct * 100.0)


func _remove_progress_bar() -> void:
	if _progress_bg:
		_progress_bg.queue_free()
		_progress_bg = null
	if _progress_bar:
		_progress_bar.queue_free()
		_progress_bar = null
		_progress_mat = null
	if _progress_label:
		_progress_label.queue_free()
		_progress_label = null
	var audio: AudioManager = get_tree().current_scene.get_node_or_null("AudioManager") as AudioManager
	if audio:
		audio.play_construction_complete(global_position)


func get_power_efficiency() -> float:
	if resource_manager and resource_manager.has_method("get_power_efficiency"):
		return resource_manager.get_power_efficiency()
	return 1.0


func cancel_queue_at(index: int) -> bool:
	## Pop a queued unit and refund its full salvage / fuel cost back to
	## this building's resource manager. Cancelling index 0 (the in-flight
	## one) also resets the production timer so the next queued unit
	## starts fresh; partial progress is abandoned, not refunded.
	## Returns true if a slot was actually cancelled.
	if index < 0 or index >= _build_queue.size():
		return false
	# Use a different local name than `stats` so we don't shadow the
	# class's own @export `stats` field — GDScript's parser is unhappy
	# about the shadow even when there's no real ambiguity.
	var unit_stats: UnitStatResource = _build_queue[index]
	if not unit_stats:
		return false
	# Salvage / fuel refund.
	if resource_manager and resource_manager.has_method("add_salvage"):
		if unit_stats.cost_salvage > 0:
			resource_manager.add_salvage(unit_stats.cost_salvage)
	if resource_manager and resource_manager.has_method("add_fuel") and unit_stats.cost_fuel > 0:
		resource_manager.add_fuel(unit_stats.cost_fuel)
	# Population also rebates — `queue_unit` (via SelectionManager /
	# AIController) bumped it on enqueue.
	if resource_manager and resource_manager.has_method("remove_population"):
		resource_manager.remove_population(unit_stats.population)
	_build_queue.remove_at(index)
	if index == 0:
		_build_progress = 0.0
	return true


## Queue a unit for production. Returns true if successfully queued.
func queue_unit(unit_stats: UnitStatResource) -> bool:
	if not is_constructed:
		return false
	if not (unit_stats in stats.producible_units):
		return false
	_build_queue.append(unit_stats)
	return true


func _process(delta: float) -> void:
	# Always-on damage VFX animation, even when nothing is in production.
	_atmos_anim_time += delta
	# Damage smoke — spawn rising sphere puffs at random anchors. Soft,
	# round, and they actually climb instead of bobbing in place.
	if _damage_smoke and _damage_smoke.visible and not _damage_smoke_anchors.is_empty():
		_damage_anim_time += delta
		_damage_smoke_timer -= delta
		if _damage_smoke_timer <= 0.0:
			_damage_smoke_timer = randf_range(0.18, 0.32)
			var anchor: Node3D = _damage_smoke_anchors[randi() % _damage_smoke_anchors.size()]
			if is_instance_valid(anchor):
				_spawn_smoke_puff(anchor.global_position)

	# Damage fire — each ember has its own phase + speed so the cluster
	# crackles unevenly. Orange light source flickers with them.
	if _damage_fire and _damage_fire.visible:
		var avg_brightness: float = 0.0
		for entry: Dictionary in _damage_embers:
			var mat: StandardMaterial3D = entry["mat"] as StandardMaterial3D
			if not mat:
				continue
			var base: float = entry["base"] as float
			var phase: float = entry["phase"] as float
			var speed: float = entry["speed"] as float
			var flicker: float = base * (0.55 + 0.35 * sin(_atmos_anim_time * speed + phase) + randf_range(-0.08, 0.08))
			mat.emission_energy_multiplier = maxf(flicker, 0.4)
			avg_brightness += flicker
		if _damage_fire_light:
			var n: int = maxi(_damage_embers.size(), 1)
			_damage_fire_light.light_energy = clampf(avg_brightness / float(n), 1.5, 4.5)

	# Atmospheric idle animations — only after construction completes; sunken
	# / under-construction buildings stay still.
	if is_constructed:
		_tick_atmospheric_animations(delta)

	if not is_constructed:
		return
	if _build_queue.is_empty():
		return

	var current_unit: UnitStatResource = _build_queue[0]
	var efficiency: float = get_power_efficiency()
	_build_progress += delta * efficiency

	if _build_progress >= current_unit.build_time:
		_build_progress = 0.0
		_build_queue.remove_at(0)
		_spawn_unit(current_unit)


func _spawn_unit(unit_stats: UnitStatResource) -> void:
	# Check if a branch commit exists for this unit type → use upgraded stats
	var actual_stats: UnitStatResource = unit_stats
	var bcm: Node = get_tree().current_scene.get_node_or_null("BranchCommitManager")
	if bcm and bcm.has_method("get_committed_stats"):
		var committed: UnitStatResource = bcm.get_committed_stats(unit_stats.unit_name)
		if committed:
			actual_stats = committed

	# Crawlers route through a dedicated scene; everything else uses the
	# standard mech scene.
	var scene_path: String = "res://scenes/unit.tscn"
	var is_crawler: bool = false
	if "is_crawler" in actual_stats and actual_stats.is_crawler:
		scene_path = "res://scenes/salvage_crawler.tscn"
		is_crawler = true

	var unit_scene: PackedScene = load(scene_path) as PackedScene
	var spawned: Node3D = unit_scene.instantiate() as Node3D
	spawned.set("stats", actual_stats)
	spawned.set("owner_id", owner_id)
	if is_crawler:
		spawned.set("resource_manager", resource_manager)

	var spawn_pos: Vector3
	if _spawn_marker:
		spawn_pos = _spawn_marker.global_position
	else:
		spawn_pos = global_position
	spawn_pos += Vector3(randf_range(-1.0, 1.0), 0, randf_range(-1.0, 1.0))

	var units_node: Node = get_tree().current_scene.get_node_or_null("Units")
	if units_node:
		units_node.add_child(spawned)
	else:
		get_tree().current_scene.add_child(spawned)
	spawned.global_position = spawn_pos
	if spawned.has_method("command_move"):
		spawned.command_move(rally_point)
	unit_produced.emit(unit_scene, spawn_pos)
	var audio: AudioManager = get_tree().current_scene.get_node_or_null("AudioManager") as AudioManager
	if audio:
		audio.play_production_complete(global_position)


func get_queue_size() -> int:
	return _build_queue.size()


func get_queue_snapshot() -> Array[UnitStatResource]:
	# Defensive copy so HUD code can iterate without seeing live mutation
	# from a finishing tick.
	return _build_queue.duplicate()


func get_queue_unit_count(filter_class: StringName) -> int:
	## Count queued units whose stats match a given unit_class. Used by the
	## Crawler cap so the player can't sneak past it by stacking the queue.
	var n: int = 0
	for s: UnitStatResource in _build_queue:
		if s and s.unit_class == filter_class:
			n += 1
	return n


func get_build_progress_percent() -> float:
	if _build_queue.is_empty():
		return 0.0
	var current_unit: UnitStatResource = _build_queue[0]
	return _build_progress / current_unit.build_time


var _is_selected: bool = false

## Emission state captured before applying the selection highlight, so
## deselect can restore exactly what each material had. Keyed by the
## StandardMaterial3D itself.
var _saved_emission: Dictionary = {}


func select_building() -> void:
	if _is_selected:
		return
	_is_selected = true
	_update_selection_visual()


func deselect_building() -> void:
	if not _is_selected:
		return
	_is_selected = false
	_update_selection_visual()


func _update_selection_visual() -> void:
	if not _visual_root:
		return
	if _is_selected:
		_apply_select_glow(_visual_root)
	else:
		_restore_select_glow(_visual_root)


## Soft green emission boost applied per-material. Existing emissive
## materials (team band, indicator lights, beacons) get a small bump
## that blends with their own color so they don't all flash green.
const _SELECT_TINT: Color = Color(0.25, 0.85, 0.35)
const _SELECT_ENERGY_FLOOR: float = 0.45


func _apply_select_glow(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var mat: StandardMaterial3D = mi.get_surface_override_material(0) as StandardMaterial3D
		if mat and not _saved_emission.has(mat):
			_saved_emission[mat] = {
				"enabled": mat.emission_enabled,
				"color": mat.emission,
				"energy": mat.emission_energy_multiplier,
			}
			mat.emission_enabled = true
			if mat.emission == Color(0.0, 0.0, 0.0, 1.0) or not (_saved_emission[mat] as Dictionary)["enabled"]:
				# Plain metal — give it a soft green wash.
				mat.emission = _SELECT_TINT
				mat.emission_energy_multiplier = _SELECT_ENERGY_FLOOR
			else:
				# Already emissive (team band, indicator lights). Blend toward
				# the select tint so the highlight is visible without losing
				# the original color identity.
				mat.emission = mat.emission.lerp(_SELECT_TINT, 0.35)
				mat.emission_energy_multiplier = maxf(mat.emission_energy_multiplier + 0.4, _SELECT_ENERGY_FLOOR + 0.4)
	for child: Node in node.get_children():
		_apply_select_glow(child)


func _restore_select_glow(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var mat: StandardMaterial3D = mi.get_surface_override_material(0) as StandardMaterial3D
		if mat and _saved_emission.has(mat):
			var saved: Dictionary = _saved_emission[mat] as Dictionary
			mat.emission_enabled = saved["enabled"] as bool
			mat.emission = saved["color"] as Color
			mat.emission_energy_multiplier = saved["energy"] as float
			_saved_emission.erase(mat)
	for child: Node in node.get_children():
		_restore_select_glow(child)


func heal(amount: float) -> void:
	## Restore HP up to the building's max — used by Ratchet auto-repair.
	## Floats so a 0.5/sec accumulation works across frames; we cast back
	## to int when applying.
	if not is_constructed or not stats:
		return
	if current_hp >= stats.hp:
		return
	current_hp = mini(stats.hp, current_hp + int(ceil(amount)))
	_update_damage_state()


func is_damaged() -> bool:
	return is_constructed and stats != null and current_hp < stats.hp


func take_damage(amount: int, _attacker: Node3D = null) -> void:
	current_hp -= amount
	_update_damage_state()
	if owner_id == 0:
		_emit_player_damage_alert()
	if current_hp <= 0:
		current_hp = 0
		_spawn_building_wreck()
		if owner_id == 0:
			_emit_player_destroyed_alert()
		destroyed.emit()
		# Re-bake so units can walk through the now-empty footprint.
		var arena_dead: Node = get_tree().current_scene
		if arena_dead and arena_dead.has_method("request_navmesh_rebake"):
			arena_dead.request_navmesh_rebake()
		# Big screen shake — buildings going down should feel weighty.
		var cam: Camera3D = get_viewport().get_camera_3d() if get_viewport() else null
		if cam and cam.has_method("add_shake"):
			cam.add_shake(0.55)
		queue_free()


func _emit_player_damage_alert() -> void:
	# One alert per building per cooldown — a building under sustained fire
	# shouldn't spam every tick. Channel keys the building's instance id so
	# different buildings can each fire their own alert independently.
	var alert: Node = get_tree().current_scene.get_node_or_null("AlertManager") if get_tree() else null
	if not alert or not alert.has_method("emit_alert"):
		return
	var label: String = _alert_label()
	alert.emit_alert("%s under attack" % label, 1, global_position, "building_attack:%d" % get_instance_id(), 8.0)


func _emit_player_destroyed_alert() -> void:
	var alert: Node = get_tree().current_scene.get_node_or_null("AlertManager") if get_tree() else null
	if not alert or not alert.has_method("emit_alert"):
		return
	alert.emit_alert("%s destroyed" % _alert_label(), 2, global_position, "", 0.0)


func _alert_label() -> String:
	if stats and stats.building_name != "":
		return stats.building_name
	return "Building"


func _update_damage_state() -> void:
	## Show/hide smoke and fire based on the building's current HP ratio:
	## damaged at 50%, critical at 25%.
	if not stats:
		return
	var ratio: float = float(current_hp) / float(maxi(stats.hp, 1))
	var damaged: bool = ratio < 0.5 and current_hp > 0
	var critical: bool = ratio < 0.25 and current_hp > 0

	if damaged and not _damage_smoke:
		_build_damage_smoke()
	if _damage_smoke:
		_damage_smoke.visible = damaged

	if critical and not _damage_fire:
		_build_damage_fire()
	if _damage_fire:
		_damage_fire.visible = critical


func _tick_atmospheric_animations(delta: float) -> void:
	## Drive the per-frame idle animations captured by the detail builders:
	## radar dish spin, beacon throb, generator cap pulse, indicator flicker,
	## and periodic smokestack puffs.
	if _atmos_dish and is_instance_valid(_atmos_dish):
		_atmos_dish.rotation.y += delta * 0.55  # slow sweep
	if _atmos_beacon_mat:
		var beacon_pulse: float = 1.6 + 1.2 * (0.5 + 0.5 * sin(_atmos_anim_time * 2.4))
		_atmos_beacon_mat.emission_energy_multiplier = beacon_pulse
		if _atmos_beacon_light:
			# Map the same pulse to the light's energy so the cast light
			# brightens with the beacon.
			_atmos_beacon_light.light_energy = lerp(0.8, 2.6, (beacon_pulse - 1.6) / 1.2)
	if _atmos_generator_cap_mat:
		# Reactor pulse — mostly steady with a slight flicker.
		var gen_pulse: float = 1.7 + 0.5 * sin(_atmos_anim_time * 3.1) + randf_range(-0.06, 0.06)
		_atmos_generator_cap_mat.emission_energy_multiplier = gen_pulse
		if _atmos_generator_light:
			_atmos_generator_light.light_energy = lerp(1.4, 2.4, clampf((gen_pulse - 1.2) / 1.0, 0.0, 1.0))
	for entry: Dictionary in _atmos_indicator_mats:
		var lmat: StandardMaterial3D = entry["mat"] as StandardMaterial3D
		if not lmat:
			continue
		var ph: float = entry["phase"] as float
		var base: float = entry["base"] as float
		lmat.emission_energy_multiplier = base * (0.7 + 0.3 * sin(_atmos_anim_time * 1.8 + ph))

	# Stack-tip lights brighten while the foundry is actively producing —
	# a clear "this building is doing something right now" signal per
	# READABILITY_PASS.md §Task 5.
	if not _atmos_stack_lights.is_empty():
		var producing: bool = is_constructed and not _build_queue.is_empty()
		var target_energy: float = 1.4 if producing else 0.55
		var pulse: float = (1.0 + 0.18 * sin(_atmos_anim_time * 4.1)) if producing else 1.0
		for stack_light: OmniLight3D in _atmos_stack_lights:
			if is_instance_valid(stack_light):
				stack_light.light_energy = target_energy * pulse

	# Periodic smoke puff per stack so foundries feel alive.
	if not _atmos_stack_tops.is_empty():
		_atmos_smoke_timer -= delta
		if _atmos_smoke_timer <= 0.0:
			_atmos_smoke_timer = randf_range(0.7, 1.4)
			for marker: Node3D in _atmos_stack_tops:
				if is_instance_valid(marker):
					_spawn_smoke_puff(marker.global_position)


func _spawn_smoke_puff(world_pos: Vector3) -> void:
	## Tiny dark sphere that drifts upward, expands, and fades — the rolling
	## smoke at a foundry stack tip.
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	var puff := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = randf_range(0.18, 0.28)
	sph.height = sph.radius * 2.0
	puff.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.22, 0.2, 0.65)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.05, 0.04, 0.04)
	mat.emission_energy_multiplier = 0.05
	puff.set_surface_override_material(0, mat)
	puff.global_position = world_pos + Vector3(randf_range(-0.1, 0.1), 0.0, randf_range(-0.1, 0.1))
	scene.add_child(puff)

	var lifetime: float = randf_range(1.6, 2.4)
	var rise: float = randf_range(2.5, 3.5)
	var grow: float = randf_range(1.6, 2.2)

	var tween := puff.create_tween()
	tween.set_parallel(true)
	tween.tween_property(puff, "global_position", puff.global_position + Vector3(randf_range(-0.4, 0.4), rise, randf_range(-0.4, 0.4)), lifetime)
	tween.tween_property(puff, "scale", Vector3(grow, grow, grow), lifetime)
	tween.tween_property(mat, "albedo_color:a", 0.0, lifetime).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(puff.queue_free)


func _build_damage_smoke() -> void:
	## Container of Marker3D spawn points scattered across the roof. Actual
	## smoke is rising sphere puffs spawned from _process via the same
	## _spawn_smoke_puff helper used by the foundry smokestacks — rounder,
	## softer, and rises naturally instead of bobbing in place.
	if not stats:
		return
	_ensure_visual_root()
	_damage_smoke = Node3D.new()
	_damage_smoke.name = "DamageSmoke"
	_visual_root.add_child(_damage_smoke)
	_damage_smoke_anchors.clear()

	var fs: Vector3 = stats.footprint_size
	# Three anchors offset across the roof so puffs come from different
	# spots rather than a single column.
	for i: int in 3:
		var anchor := Marker3D.new()
		anchor.position = Vector3(
			randf_range(-fs.x * 0.3, fs.x * 0.3),
			fs.y + 0.15,
			randf_range(-fs.z * 0.3, fs.z * 0.3)
		)
		_damage_smoke.add_child(anchor)
		_damage_smoke_anchors.append(anchor)


func _build_damage_fire() -> void:
	## Cluster of small irregularly-flickering embers + an orange OmniLight3D
	## so the building actually receives warm light when it's burning.
	if not stats:
		return
	_ensure_visual_root()
	_damage_fire = Node3D.new()
	_damage_fire.name = "DamageFire"
	_visual_root.add_child(_damage_fire)
	_damage_embers.clear()

	var fs: Vector3 = stats.footprint_size
	# Embers scattered across the upper deck, varied in size and height for
	# an irregular silhouette.
	for i: int in 7:
		var ember := MeshInstance3D.new()
		var sph := SphereMesh.new()
		var radius: float = randf_range(0.08, 0.18)
		sph.radius = radius
		sph.height = radius * 2.0
		ember.mesh = sph
		ember.position = Vector3(
			randf_range(-fs.x * 0.35, fs.x * 0.35),
			fs.y + randf_range(0.05, 0.25),
			randf_range(-fs.z * 0.35, fs.z * 0.35)
		)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.45, 0.1, 1.0)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.4, 0.05)
		mat.emission_energy_multiplier = 3.0
		ember.set_surface_override_material(0, mat)
		_damage_fire.add_child(ember)
		# Each ember carries its own base energy and phase so they flicker
		# independently rather than scaling as a uniform cluster.
		_damage_embers.append({
			"mesh": ember,
			"mat": mat,
			"base": randf_range(2.4, 3.6),
			"phase": randf_range(0.0, TAU),
			"speed": randf_range(7.0, 13.0),
		})

	# Real light source so the burning building actually casts orange glow.
	_damage_fire_light = OmniLight3D.new()
	_damage_fire_light.light_color = Color(1.0, 0.5, 0.18)
	_damage_fire_light.light_energy = 2.5
	_damage_fire_light.omni_range = maxf(fs.x, fs.z) * 1.6 + 2.0
	_damage_fire_light.position = Vector3(0, fs.y + 0.4, 0)
	_damage_fire.add_child(_damage_fire_light)


func _spawn_building_wreck() -> void:
	if not stats or stats.cost_salvage <= 0:
		return
	var wreck := Wreck.new()
	wreck.salvage_value = int(stats.cost_salvage * 0.35)
	wreck.salvage_remaining = wreck.salvage_value
	wreck.wreck_size = Vector3(
		stats.footprint_size.x * 0.8,
		stats.footprint_size.y * 0.3,
		stats.footprint_size.z * 0.8
	)
	wreck.global_position = global_position
	get_tree().current_scene.add_child(wreck)
