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
## True once an engineer has actually started building the foundation
## (first advance_construction() call). Foundations sit in this
## not-yet-started state from begin_construction() until the placing
## engineer reaches them; during that window opponents shouldn't see
## or be able to attack the foundation -- the structure isn't really
## there yet, just a placement intent.
var construction_started: bool = false
## Per-instance max HP override. -1 = use stats.hp. Bumped above
## stats.hp when the Anvil HQ Plating upgrade is bought (the buff
## raises both current_hp and the max ceiling so the auto-repair
## tops back up to the upgraded total).
var hp_max_override: int = -1
## Anvil-only HQ upgrades. One-time per HQ; payment + flag flip
## happen in the HUD. hq_plating raises max HP +25%; hq_battery
## bumps the built-in HQ defensive turret's damage and range.
var hq_plating_active: bool = false
var hq_battery_active: bool = false
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

const PLAYER_COLOR := Color(0.08, 0.25, 0.85, 1.0)
const ENEMY_COLOR := Color(0.80, 0.10, 0.10, 1.0)
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
## Per-frame construction stats so the progress label can show
## current worker count and an estimated remaining time. The dicts
## are flipped in _process so a builder still counts even if it
## advanced earlier in the frame than the rotation tick.
var _builders_this_tick: Dictionary = {}
var _builders_last_tick: Dictionary = {}
var _build_amount_this_tick: float = 0.0
var _build_rate_per_sec: float = 0.0
var _last_build_tick_time_msec: int = 0

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

## Four-stage damage progression keyed off `current_hp / stats.hp`:
##   0 — undamaged    (HP > 75%)  : no effects
##   1 — light damage (50-75%)    : occasional smoke wisps
##   2 — moderate     (25-50%)    : steady smoke + a few flickering embers, slight albedo darkening
##   3 — critical     (< 25%)     : heavy smoke + dense embers + orange fire light + noticeable darkening
## Stage edges drive lazy build of the smoke/fire nodes and reapply the
## per-stage albedo darken on every attached material.
var _damage_stage: int = 0
## Average seconds between smoke puffs at each stage. Stage 0 is unused.
const _DAMAGE_SMOKE_INTERVAL_MIN: Array[float] = [0.0, 0.7, 0.28, 0.10]
const _DAMAGE_SMOKE_INTERVAL_MAX: Array[float] = [0.0, 1.1, 0.55, 0.22]
## How many of the 7 ember slots are visible at each stage.
const _DAMAGE_EMBER_VISIBLE: Array[int] = [0, 0, 3, 7]
## Albedo darken factor (multiplied as `1 - factor`) at each stage.
const _DAMAGE_DARKEN: Array[float] = [0.0, 0.0, 0.10, 0.22]
## Original albedo per material we've darkened, keyed by material instance_id.
## Lets us restore + reapply when the stage changes (including healing back
## up the chain) without compounding darken multipliers.
var _damage_saved_albedo: Dictionary = {}

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

## Half-frame stagger for the cosmetic smoke / fire / atmospheric loop.
## Damage VFX flicker reads fine at 30Hz; halving the rate at high
## building counts cuts Building._process roughly in half.
var _process_phase: int = 0
var _process_frame: int = 0
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
	# Round-robin phase for the half-frame stagger in `_process`.
	_process_phase = int(get_instance_id() & 1)
	if stats:
		current_hp = stats.hp
		# Default rally point sits just OUTSIDE the building's
		# footprint, in the direction AWAY from the world origin.
		# A building at z=+110 (player base, north end of map)
		# rallies further north so freshly-produced units stay
		# safely behind the line. A building at z=-110 (AI base,
		# south) rallies further south. Fixed +Z south used to
		# default the player's units straight toward the enemy
		# front. Faction-agnostic — the heuristic just looks at
		# where the building actually is relative to the map.
		var away_from_origin: Vector3 = global_position
		away_from_origin.y = 0.0
		if away_from_origin.length_squared() > 0.0001:
			away_from_origin = away_from_origin.normalized()
		else:
			# Building parked at exact origin — fall back to a
			# fixed +Z offset.
			away_from_origin = Vector3(0.0, 0.0, 1.0)
		var rally_dist: float = stats.footprint_size.z * 0.5 + 2.5
		rally_point = global_position + away_from_origin * rally_dist
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
		elif stats.building_id == &"gun_emplacement" or stats.building_id == &"gun_emplacement_basic":
			var turret_script: GDScript = load("res://scripts/turret_component.gd") as GDScript
			var turret: Node = turret_script.new()
			turret.name = "TurretComponent"
			add_child(turret)
		elif stats.building_id == &"sam_site":
			# V3 §"Pillar 4" — SAM Site uses the existing TurretComponent
			# with the `anti_air` profile so it autocasts on aircraft
			# only. Profile values (high damage, fast fire, AAir tag)
			# come straight from PROFILES["anti_air"] in turret_component.
			var turret_script: GDScript = load("res://scripts/turret_component.gd") as GDScript
			var turret: Node = turret_script.new()
			turret.name = "TurretComponent"
			turret.set("profile", &"anti_air")
			add_child(turret)
		# Headquarters self-defense -- one TurretComponent per corner
		# MG nest, each with its own pivot. The components are
		# created from inside _detail_hq_defense_turret once the
		# corner pivots exist, so we don't pre-create one here.


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
	## GeometryInstance3D so the small per-mesh AABBs (smokestacks, ribs,
	## vents, etc.) stay drawn until the *whole building* is off-screen,
	## not just each individual detail. Lights live under VisualInstance3D
	## too but don't expose extra_cull_margin — narrow the cast to
	## GeometryInstance3D so we don't try to set the property on them.
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).extra_cull_margin = margin
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
		&"basic_generator", &"advanced_generator": _detail_generator()
		&"basic_armory": _detail_armory()
		&"advanced_armory": _detail_advanced_armory()
		&"salvage_yard": _detail_salvage_yard()
		&"gun_emplacement", &"gun_emplacement_basic": _detail_gun_emplacement()
		&"aerodrome": _detail_aerodrome()
		&"sam_site": _detail_sam_site()
		&"black_pylon": _detail_black_pylon()
	# Mesh-provider aura ring (V3 §Pillar 2). Drawn after the type
	# detail layer so the ring sits on top of the ground markings.
	if stats.mesh_provider_radius > 0.0:
		_add_mesh_aura_ring(stats.mesh_provider_radius)


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

	# Front doorway -- recessed lit interior visible through the
	# opening rather than a flat emissive panel slapped on the wall.
	# Skip on buildings whose main detail layer already puts a feature
	# right where we'd draw it (foundry's loading door, gun emplacement's
	# turret base) so we don't double-stack geometry.
	var bid: StringName = stats.building_id
	if bid != &"basic_foundry" and bid != &"advanced_foundry" and bid != &"gun_emplacement" and bid != &"gun_emplacement_basic":
		_build_lit_doorway(
			Vector3(0.0, fs.y * 0.16, -fs.z * 0.5),
			fs.x * 0.22,
			fs.y * 0.30,
			Color(0.95, 0.55, 0.2),
		)

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
	# Subtle grime/wear overlay — multiplied against the tint so the
	# building reads as weathered industrial metal instead of flat colour.
	m.albedo_texture = SharedTextures.get_metal_wear_texture()
	m.uv1_offset = Vector3(randf(), randf(), 0.0)
	m.uv1_scale = Vector3(1.5, 1.5, 1.0)
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
	## Recessed production gate on the camera-facing (+Z) side. Built as a
	## real opening: a deep dark interior box set INTO the wall, surrounded
	## by a raised frame (header beam + jamb posts) sticking forward from
	## the wall, so the eye reads "open hangar mouth", not "black sticker
	## on a brick".
	if not stats:
		return
	var fs: Vector3 = stats.footprint_size

	# Interior cavity — deep recessed dark box. Most of it sits inside the
	# building wall; only a sliver pokes out to define the opening edge.
	var cavity := MeshInstance3D.new()
	var cbox := BoxMesh.new()
	var cavity_depth: float = maxf(0.45, fs.z * 0.12)
	cbox.size = Vector3(width, height, cavity_depth)
	cavity.mesh = cbox
	# Push the cavity centroid INTO the building so its outer face sits a
	# touch proud of the wall while its back wall is well inside.
	cavity.position = Vector3(0.0, height * 0.5 + 0.05, fs.z * 0.5 - cavity_depth * 0.35)
	cavity.set_surface_override_material(0, _detail_emissive_mat(Color(0.18, 0.10, 0.05), 0.25))
	_attach_visual(cavity)

	# Header beam — heavy box across the top of the opening, sticks out
	# from the wall so it casts a ledge shadow over the cavity.
	var header := MeshInstance3D.new()
	var hb := BoxMesh.new()
	hb.size = Vector3(width + 0.30, 0.20, 0.30)
	header.mesh = hb
	header.position = Vector3(0.0, height + 0.15, fs.z * 0.5 + 0.12)
	header.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.28, 0.22)))
	_attach_visual(header)

	# Jamb posts — left and right vertical pillars framing the opening.
	for side: int in 2:
		var jx: float = -width * 0.5 - 0.07 if side == 0 else width * 0.5 + 0.07
		var jamb := MeshInstance3D.new()
		var jb := BoxMesh.new()
		jb.size = Vector3(0.18, height + 0.10, 0.30)
		jamb.mesh = jb
		jamb.position = Vector3(jx, (height + 0.10) * 0.5 + 0.05, fs.z * 0.5 + 0.12)
		jamb.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.28, 0.24, 0.20)))
		_attach_visual(jamb)

	# Cross-strut overhead lamp — single cylinder with a warm emissive
	# disc, sits flush against the underside of the header so the cavity
	# has a believable interior light.
	var lamp := MeshInstance3D.new()
	var lcyl := CylinderMesh.new()
	lcyl.top_radius = 0.10
	lcyl.bottom_radius = 0.10
	lcyl.height = 0.05
	lamp.mesh = lcyl
	lamp.position = Vector3(0.0, height + 0.02, fs.z * 0.5 + 0.04)
	lamp.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.75, 0.35), 1.4))
	_attach_visual(lamp)

	# Top door rail (lighter trim above the header).
	var rail := MeshInstance3D.new()
	var rb := BoxMesh.new()
	rb.size = Vector3(width + 0.40, 0.06, 0.06)
	rail.mesh = rb
	rail.position = Vector3(0, height + 0.30, fs.z * 0.5 + 0.16)
	rail.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.42, 0.38, 0.30)))
	_attach_visual(rail)


func _build_lit_doorway(centre_world: Vector3, width: float, height: float, accent: Color) -> void:
	## Recessed doorway with a visible interior. Replaces the old
	## "flat emissive box on the wall" pattern -- those read as a
	## glowing rectangle pasted on, not a real opening. This builds
	## five layers parented to a single Node3D centred on the door:
	##   * Frame: thin trim around the opening (slightly proud)
	##   * Recess back wall: dark cavity pushed INTO the building
	##     (negative-Z relative to the front face) so the camera
	##     sees depth instead of a flat rectangle
	##   * Header beam: thin horizontal slab along the top of the
	##     opening for the industrial-doorway read
	##   * Floor sill: thin flat slab at the bottom edge so the
	##     door doesn't read as floating
	##   * Interior lights: 2 small emissive squares deep inside
	##     the recess at varying heights, suggesting machinery /
	##     activity rather than a single flat lamp
	##
	## Accent colour drives the trim + interior lights so factional
	## identity carries through (Anvil amber / Sable violet etc.).
	## centre_world is the position on the building's FRONT face;
	## the recess extends back into the wall.
	var door_root := Node3D.new()
	door_root.position = centre_world
	_attach_visual(door_root)

	# Recess back wall -- a dark box pushed into the building
	# (positive Z = INTO the building since the front face is at -Z).
	# Reads as the inside of the room when the camera looks at the
	# opening at the typical RTS angle.
	var recess_depth: float = 0.45
	var back := MeshInstance3D.new()
	var back_box := BoxMesh.new()
	back_box.size = Vector3(width * 0.94, height * 0.94, 0.04)
	back.mesh = back_box
	back.position = Vector3(0.0, 0.0, recess_depth)
	back.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.05, 0.04, 0.04)))
	door_root.add_child(back)

	# Side walls of the recess -- catch shading so the cavity reads
	# as a real volume rather than a back panel floating in space.
	for side: int in 2:
		var sx: float = -width * 0.5 if side == 0 else width * 0.5
		var wall := MeshInstance3D.new()
		var wall_box := BoxMesh.new()
		wall_box.size = Vector3(0.04, height * 0.94, recess_depth)
		wall.mesh = wall_box
		wall.position = Vector3(sx, 0.0, recess_depth * 0.5)
		wall.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.07, 0.06, 0.05)))
		door_root.add_child(wall)

	# Outer trim -- thin frame slightly proud of the wall, accent-tinted.
	var trim_mat: StandardMaterial3D = _detail_emissive_mat(accent, 0.6)
	var trim_w: float = 0.04
	# Top.
	var trim_top := MeshInstance3D.new()
	var trim_top_box := BoxMesh.new()
	trim_top_box.size = Vector3(width + trim_w * 2.0, trim_w, 0.04)
	trim_top.mesh = trim_top_box
	trim_top.position = Vector3(0.0, height * 0.5, -0.02)
	trim_top.set_surface_override_material(0, trim_mat)
	door_root.add_child(trim_top)
	# Bottom.
	var trim_bot := MeshInstance3D.new()
	var trim_bot_box := BoxMesh.new()
	trim_bot_box.size = Vector3(width + trim_w * 2.0, trim_w, 0.04)
	trim_bot.mesh = trim_bot_box
	trim_bot.position = Vector3(0.0, -height * 0.5, -0.02)
	trim_bot.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
	door_root.add_child(trim_bot)
	# Side trims.
	for side: int in 2:
		var sx2: float = -width * 0.5 - trim_w * 0.5 if side == 0 else width * 0.5 + trim_w * 0.5
		var trim_side := MeshInstance3D.new()
		var trim_side_box := BoxMesh.new()
		trim_side_box.size = Vector3(trim_w, height, 0.04)
		trim_side.mesh = trim_side_box
		trim_side.position = Vector3(sx2, 0.0, -0.02)
		trim_side.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
		door_root.add_child(trim_side)

	# Interior lights -- small emissive boxes deep in the recess
	# at varying heights. Two of them so the interior reads as
	# "active workspace" rather than "a single bulb on a wall".
	var lamp_a := MeshInstance3D.new()
	var lamp_a_box := BoxMesh.new()
	lamp_a_box.size = Vector3(width * 0.32, height * 0.18, 0.04)
	lamp_a.mesh = lamp_a_box
	lamp_a.position = Vector3(-width * 0.18, height * 0.20, recess_depth - 0.03)
	lamp_a.set_surface_override_material(0, _detail_emissive_mat(accent, 1.4))
	door_root.add_child(lamp_a)
	var lamp_b := MeshInstance3D.new()
	var lamp_b_box := BoxMesh.new()
	lamp_b_box.size = Vector3(width * 0.20, height * 0.10, 0.04)
	lamp_b.mesh = lamp_b_box
	lamp_b.position = Vector3(width * 0.22, -height * 0.10, recess_depth - 0.03)
	lamp_b.set_surface_override_material(0, _detail_emissive_mat(accent, 1.0))
	door_root.add_child(lamp_b)

	# Floor sill -- thin flat slab so the door doesn't read as
	# floating against the wall.
	var sill := MeshInstance3D.new()
	var sill_box := BoxMesh.new()
	sill_box.size = Vector3(width, 0.04, recess_depth + 0.04)
	sill.mesh = sill_box
	sill.position = Vector3(0.0, -height * 0.5 + 0.02, recess_depth * 0.5)
	sill.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.10, 0.09, 0.08)))
	door_root.add_child(sill)


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


func _team_collar_ring(radius: float, height: float, pos: Vector3) -> void:
	## Cylindrical variant of `_team_collar` for cylindrical detail
	## towers (smokestacks, spires). A box collar around a round stack
	## reads as a misaligned colour patch; the cylindrical band wraps
	## the stack edge correctly.
	var team_color: Color = _resolve_team_color()
	var collar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 20
	collar.mesh = cyl
	collar.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = team_color
	mat.emission_enabled = true
	mat.emission = team_color
	mat.emission_energy_multiplier = 1.2
	mat.roughness = 0.6
	collar.set_surface_override_material(0, mat)
	_attach_visual(collar)


func _detail_hq_defense_turret() -> void:
	## Four MG nests at the HQ roof corners -- reads as a
	## position-secured-by-soldiers, not a turret fortification.
	## Each nest is a sandbag-ringed open-top emplacement with a
	## pintle-mounted MG, and each gets its own TurretComponent so
	## all four corners track + fire independently. A single
	## defensive turret ratting only one corner reads wrong; this
	## way the player sees a 360-degree security cordon.
	var fs: Vector3 = stats.footprint_size
	var corners: Array[Vector3] = [
		Vector3(fs.x * 0.40, fs.y, fs.z * 0.40),
		Vector3(-fs.x * 0.40, fs.y, fs.z * 0.40),
		Vector3(fs.x * 0.40, fs.y, -fs.z * 0.40),
		Vector3(-fs.x * 0.40, fs.y, -fs.z * 0.40),
	]
	var turret_script: GDScript = load("res://scripts/turret_component.gd") as GDScript
	for i: int in corners.size():
		var corner: Vector3 = corners[i]
		var pivot: Node3D = _build_hq_corner_mg_nest(corner)
		# First corner mirrors its pivot into building.turret_pivot so
		# legacy callers (HUD readouts, projectile-origin fallback)
		# still find a pivot. Other corners get their TurretComponent
		# pivot via pivot_override and don't need to fight for the
		# shared field.
		if i == 0:
			turret_pivot = pivot
		var turret: Node = turret_script.new()
		# Name the first one "TurretComponent" so legacy callers
		# (HUD readouts, selection_manager) that look up by exact
		# name still find a representative component on the HQ;
		# others get a numbered suffix so all four are unique
		# children.
		turret.name = "TurretComponent" if i == 0 else "TurretComponent_%d" % i
		turret.set("profile", &"hq_defense")
		turret.set("pivot_override", pivot)
		add_child(turret)


func _build_hq_corner_mg_nest(corner: Vector3) -> Node3D:
	## Sandbag ring + pintle-mounted MG. Returns the tracking pivot
	## the caller wires into a TurretComponent so every nest fires
	## independently. Sized up over the original pass so the nest
	## reads as a real weapon emplacement at standard RTS distance.
	var ring_radius: float = 0.78
	var bag_h: float = 0.30
	# Sandbag ring -- 7 bags so the ring closes more solidly than 6.
	for s: int in 7:
		var ang: float = float(s) / 7.0 * TAU
		var bx: float = corner.x + cos(ang) * ring_radius
		var bz: float = corner.z + sin(ang) * ring_radius
		var bag := MeshInstance3D.new()
		var bg_box := BoxMesh.new()
		bg_box.size = Vector3(0.42, bag_h, 0.62)
		bag.mesh = bg_box
		bag.position = Vector3(bx, corner.y + bag_h * 0.5, bz)
		bag.rotation.y = ang + PI / 2
		bag.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.28, 0.20)))
		_attach_visual(bag)
		# Stack a smaller bag on top of every other ring bag so the
		# silhouette reads as "piled" rather than a single course.
		if s % 2 == 0:
			var top_bag := MeshInstance3D.new()
			var tb := BoxMesh.new()
			tb.size = Vector3(0.36, bag_h * 0.85, 0.52)
			top_bag.mesh = tb
			top_bag.position = Vector3(bx, corner.y + bag_h + tb.size.y * 0.5, bz)
			top_bag.rotation.y = ang + PI / 2 + 0.15
			top_bag.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.30, 0.26, 0.18)))
			_attach_visual(top_bag)

	# Pintle base plate -- a flat disc bolted to the roof inside the
	# sandbag ring; reads as "this is where the gun is mounted".
	var base_plate := MeshInstance3D.new()
	var plate_cyl := CylinderMesh.new()
	plate_cyl.top_radius = 0.30
	plate_cyl.bottom_radius = 0.34
	plate_cyl.height = 0.08
	base_plate.mesh = plate_cyl
	base_plate.position = Vector3(corner.x, corner.y + 0.04, corner.z)
	base_plate.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.20, 0.18)))
	_attach_visual(base_plate)

	# Vertical pintle post -- tall enough that the cradle + barrel
	# clear the sandbag stack (bottom course at corner.y + bag_h
	# = 0.30, second course top at ~corner.y + 0.555). Post tip at
	# corner.y + 0.78 puts the barrel comfortably above the bags so
	# the gunner is firing OVER cover, not into it.
	var post := MeshInstance3D.new()
	var post_cyl := CylinderMesh.new()
	post_cyl.top_radius = 0.06
	post_cyl.bottom_radius = 0.10
	post_cyl.height = 0.70
	post.mesh = post_cyl
	post.position = Vector3(corner.x, corner.y + 0.08 + post_cyl.height * 0.5, corner.z)
	post.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
	_attach_visual(post)

	# Tracking pivot at the top of the post. Each nest gets its own.
	var pivot := Node3D.new()
	pivot.name = "MGNestPivot"
	pivot.position = Vector3(corner.x, corner.y + 0.80, corner.z)
	_attach_visual(pivot)

	# Horizontal swivel cradle -- a short box cradling the barrel,
	# parented to pivot so it tracks. Gives the gun a real "yoke" feel.
	var cradle := MeshInstance3D.new()
	var cradle_box := BoxMesh.new()
	cradle_box.size = Vector3(0.30, 0.14, 0.18)
	cradle.mesh = cradle_box
	cradle.position = Vector3(0.0, 0.0, 0.05)
	cradle.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.20, 0.18)))
	pivot.add_child(cradle)

	# Cooling jacket -- a slightly fatter cylinder enclosing the
	# inner barrel. The jacket has visible vent rings drawn as
	# thin torus segments so the gun reads as machine-gun rather
	# than smooth tube.
	var jacket := MeshInstance3D.new()
	var jc := CylinderMesh.new()
	jc.top_radius = 0.085
	jc.bottom_radius = 0.10
	jc.height = 0.62
	jacket.mesh = jc
	jacket.rotation.x = -PI / 2
	jacket.position = Vector3(0.0, 0.04, -jc.height * 0.5 - 0.10)
	jacket.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.15, 0.14)))
	pivot.add_child(jacket)
	# Three vent rings along the jacket (cosmetic detail).
	for v: int in 3:
		var ring := MeshInstance3D.new()
		var ring_torus := TorusMesh.new()
		ring_torus.inner_radius = 0.10
		ring_torus.outer_radius = 0.12
		ring_torus.rings = 12
		ring_torus.ring_segments = 6
		ring.mesh = ring_torus
		ring.rotation.x = -PI / 2
		var z: float = -0.25 - float(v) * 0.16
		ring.position = Vector3(0.0, 0.04, z)
		ring.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.10, 0.09, 0.08)))
		pivot.add_child(ring)

	# Inner barrel -- the actual rifling visible at the muzzle.
	var inner_barrel := MeshInstance3D.new()
	var ic := CylinderMesh.new()
	ic.top_radius = 0.045
	ic.bottom_radius = 0.05
	ic.height = 0.78
	inner_barrel.mesh = ic
	inner_barrel.rotation.x = -PI / 2
	inner_barrel.position = Vector3(0.0, 0.04, -ic.height * 0.5 - 0.10)
	inner_barrel.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.10, 0.09, 0.08)))
	pivot.add_child(inner_barrel)

	# Muzzle compensator -- a short, slightly fatter cylinder at the
	# tip with vertical slots (single emissive box reads as the
	# muzzle flash port).
	var muzzle := MeshInstance3D.new()
	var mc := CylinderMesh.new()
	mc.top_radius = 0.075
	mc.bottom_radius = 0.075
	mc.height = 0.10
	muzzle.mesh = mc
	muzzle.rotation.x = -PI / 2
	muzzle.position = Vector3(0.0, 0.04, -ic.height - 0.14)
	muzzle.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.07, 0.06, 0.05)))
	pivot.add_child(muzzle)

	# Ammo box on the side of the cradle -- distinct olive-drab
	# colour so the player picks the gun out as a weapon. Includes
	# a thin belt link projection on top.
	var ammo := MeshInstance3D.new()
	var ammo_box := BoxMesh.new()
	ammo_box.size = Vector3(0.16, 0.22, 0.30)
	ammo.mesh = ammo_box
	ammo.position = Vector3(0.18, -0.06, 0.0)
	ammo.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.30, 0.34, 0.18)))
	pivot.add_child(ammo)
	# Short belt feed link visible above the ammo box -- a thin
	# slanted slab that hints at the feed connection.
	var belt := MeshInstance3D.new()
	var belt_box := BoxMesh.new()
	belt_box.size = Vector3(0.10, 0.04, 0.16)
	belt.mesh = belt_box
	belt.position = Vector3(0.10, 0.06, -0.05)
	belt.rotation.z = -0.35
	belt.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.45, 0.38, 0.18)))
	pivot.add_child(belt)

	# Aim outward from the building centre so the barrel sits in
	# its arc at construction-time before any target locks on.
	pivot.rotation.y = atan2(corner.x, corner.z)
	return pivot


func _detail_headquarters() -> void:
	_detail_hq_defense_turret()
	var fs: Vector3 = stats.footprint_size
	# Roof base Y — Anvil's command tower sits on the placeholder hull
	# (y ≈ fs.y); Sable adds a stepped tower overlay whose top spine
	# reaches y ≈ fs.y * 1.10, so we push every rooftop element up by
	# that delta to avoid the spire / dish being buried inside the
	# Sable hull.
	var roof_base_y: float = fs.y
	if _resolve_faction_id() == 1:
		roof_base_y = fs.y * 1.10
	# Team collar wraps the base of the visible spire — same player
	# color band the rest of the building gets, lifted to sit on the
	# Sable hull's roof instead of hiding inside it.
	_team_collar(fs.x * 0.32, 0.12, fs.z * 0.32, Vector3(0, roof_base_y + 0.06, 0))
	# Central command spire — a tall thin tower rising from the roof.
	# Lifted slightly above the roof_cap and brass disc so the spire's
	# bottom face doesn't z-fight with their top faces (was visibly
	# flickering between roof cap, brass disc, and spire base).
	var spire := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(fs.x * 0.25, fs.y * 0.65, fs.z * 0.25)
	spire.mesh = sb
	spire.position = Vector3(0, roof_base_y + 0.10 + sb.size.y * 0.5, 0)
	spire.set_surface_override_material(0, _detail_dark_metal_mat())
	_attach_visual(spire)

	# Radar dish on top of the spire. Static parts (mast + base collar)
	# stay outside the rotating pivot so a sweeping dish doesn't drag a
	# glowing dot or a tilted base around with it. The pivot rotates a
	# parabolic dome + a feed horn that's structurally attached to the
	# dome's back.
	var dish_top_y: float = roof_base_y + 0.10 + sb.size.y + 0.55
	# Static base collar — small disc on top of the spire so the spire's
	# square corners are hidden when the dish rotates.
	var dish_collar := MeshInstance3D.new()
	var collar_cyl := CylinderMesh.new()
	collar_cyl.top_radius = fs.x * 0.18
	collar_cyl.bottom_radius = fs.x * 0.22
	collar_cyl.height = 0.1
	dish_collar.mesh = collar_cyl
	dish_collar.position = Vector3(0.0, roof_base_y + 0.10 + sb.size.y + 0.05, 0.0)
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
	beacon.position = Vector3(0, roof_base_y + 0.10 + sb.size.y + 0.45, 0)
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
	# Off-center smokestack.
	var stack := MeshInstance3D.new()
	var stack_cyl := CylinderMesh.new()
	stack_cyl.top_radius = fs.x * 0.12
	stack_cyl.bottom_radius = fs.x * 0.16
	stack_cyl.height = fs.y * (1.1 if advanced else 0.9)
	stack.mesh = stack_cyl
	stack.position = Vector3(fs.x * 0.28, fs.y + stack_cyl.height * 0.5, fs.z * 0.18)
	# Cylindrical team collar wrapping the stack base. A box collar
	# poked outside the stack's circular silhouette and read as a
	# misaligned colour patch instead of a band on the smokestack.
	_team_collar_ring(stack_cyl.bottom_radius * 1.10, 0.10, Vector3(stack.position.x, fs.y + 0.05, stack.position.z))
	stack.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.15, 0.13, 0.12)))
	_attach_visual(stack)

	# Real 3D chimney mouth — annular rim (torus) over a recessed dark
	# inner throat with the molten core sunk deep enough that the eye
	# reads "looking down a hot chimney" instead of "glowing disc on
	# top of a brick".
	var rim := MeshInstance3D.new()
	var rim_torus := TorusMesh.new()
	rim_torus.inner_radius = stack_cyl.top_radius * 0.85
	rim_torus.outer_radius = stack_cyl.top_radius * 1.10
	rim_torus.rings = 24
	rim_torus.ring_segments = 8
	rim.mesh = rim_torus
	rim.position = Vector3(stack.position.x, fs.y + stack_cyl.height + 0.04, stack.position.z)
	rim.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.10, 0.08, 0.07)))
	_attach_visual(rim)
	# Inner throat — dark cylinder sunk well below the rim so when
	# the camera looks at the stack from anywhere but directly above,
	# it sees a deep dark tube.
	var throat := MeshInstance3D.new()
	var throat_cyl := CylinderMesh.new()
	throat_cyl.top_radius = stack_cyl.top_radius * 0.84
	throat_cyl.bottom_radius = stack_cyl.top_radius * 0.84
	throat_cyl.height = 0.45
	throat.mesh = throat_cyl
	throat.position = Vector3(stack.position.x, fs.y + stack_cyl.height - 0.20, stack.position.z)
	throat.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.04, 0.03, 0.02)))
	_attach_visual(throat)
	# Molten core — small intense disc at the bottom of the throat so
	# the heat reads as "deep inside" rather than at the lip.
	var core := MeshInstance3D.new()
	var core_cyl := CylinderMesh.new()
	core_cyl.top_radius = stack_cyl.top_radius * 0.70
	core_cyl.bottom_radius = stack_cyl.top_radius * 0.70
	core_cyl.height = 0.06
	core.mesh = core_cyl
	core.position = Vector3(stack.position.x, fs.y + stack_cyl.height - 0.36, stack.position.z)
	core.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.45, 0.10), 3.6))
	_attach_visual(core)
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

	# Recessed intake vent on the front face — built as a sunken dark
	# cavity with louvre bars stretched across it. Real depth + grille
	# bars instead of a flat panel decal.
	var vent_w: float = fs.x * 0.45
	var vent_h: float = fs.y * 0.18
	var vent_cavity := MeshInstance3D.new()
	var vc_box := BoxMesh.new()
	vc_box.size = Vector3(vent_w, vent_h, 0.30)
	vent_cavity.mesh = vc_box
	vent_cavity.position = Vector3(0, fs.y * 0.5, -fs.z * 0.5 + 0.04)
	vent_cavity.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.06, 0.06, 0.07)))
	_attach_visual(vent_cavity)
	# Louvre bars — three slim horizontal slats across the cavity.
	for bar_i: int in 3:
		var bar := MeshInstance3D.new()
		var bbox := BoxMesh.new()
		bbox.size = Vector3(vent_w * 0.95, vent_h * 0.12, 0.08)
		bar.mesh = bbox
		var by: float = fs.y * 0.5 + (float(bar_i) - 1.0) * vent_h * 0.30
		bar.position = Vector3(0, by, -fs.z * 0.5 - 0.07)
		bar.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.20, 0.18, 0.16)))
		_attach_visual(bar)
	# Vent frame — thin rectangle around the opening, sticks proud of
	# the wall so the louvres read as recessed.
	for side_pair: Dictionary in [
		{ "size": Vector3(vent_w + 0.20, 0.08, 0.10), "y": fs.y * 0.5 + vent_h * 0.5 + 0.04 },
		{ "size": Vector3(vent_w + 0.20, 0.08, 0.10), "y": fs.y * 0.5 - vent_h * 0.5 - 0.04 },
	]:
		var fr := MeshInstance3D.new()
		var frb := BoxMesh.new()
		frb.size = side_pair["size"] as Vector3
		fr.mesh = frb
		fr.position = Vector3(0, side_pair["y"] as float, -fs.z * 0.5 - 0.07)
		fr.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.28, 0.22)))
		_attach_visual(fr)

	# Advanced foundry only: rear annex wing + roof-pipe bridge +
	# secondary stack so the silhouette breaks out of the "basic
	# foundry but bigger" read. Three changes layered:
	#   1. Annex wing -- a smaller hull volume bolted to the back
	#      face. Different X/Z proportions so it reads as a
	#      separate shop, not a uniform extension.
	#   2. Roof-pipe bridge -- thick conduit running between the
	#      main stack and the secondary, evoking heavy-industrial
	#      plumbing.
	#   3. Secondary stack -- already present; kept and joined to
	#      the bridge.
	if advanced:
		# Rear annex wing.
		var wing := MeshInstance3D.new()
		var wing_box := BoxMesh.new()
		wing_box.size = Vector3(fs.x * 0.55, fs.y * 0.65, fs.z * 0.45)
		wing.mesh = wing_box
		wing.position = Vector3(0.0, wing_box.size.y * 0.5, fs.z * 0.5 + wing_box.size.z * 0.5 - 0.10)
		wing.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.20, 0.22)))
		_attach_visual(wing)
		# Wing roof cap so the silhouette doesn't look like a flat
		# slab leaning against the building.
		var wing_cap := MeshInstance3D.new()
		var wing_cap_box := BoxMesh.new()
		wing_cap_box.size = Vector3(wing_box.size.x + 0.20, 0.10, wing_box.size.z + 0.20)
		wing_cap.mesh = wing_cap_box
		wing_cap.position = Vector3(0.0, wing_box.size.y + 0.05, fs.z * 0.5 + wing_box.size.z * 0.5 - 0.10)
		wing_cap.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.14, 0.14)))
		_attach_visual(wing_cap)
		# Lit doorway on the wing back so the annex reads as
		# functional, not a decorative box.
		_build_lit_doorway(
			wing.position + Vector3(0.0, 0.0, wing_box.size.z * 0.5 + 0.02),
			wing_box.size.x * 0.5,
			wing_box.size.y * 0.55,
			Color(0.95, 0.65, 0.20),
		)

		# Secondary stack on the wing (still feeds the smoke
		# loop through _atmos_stack_tops).
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

		# Roof pipe bridge between the two stacks. Thick conduit
		# slung between the stack tops and bracketed by smaller
		# support piping. Straight box runs main->secondary at
		# stack-mid height.
		var pipe_a: Vector3 = Vector3(stack.position.x, fs.y + stack_cyl.height * 0.55, stack.position.z)
		var pipe_b: Vector3 = Vector3(stack2.position.x, fs.y + stack2_cyl.height * 0.55, stack2.position.z)
		var pipe_mid: Vector3 = (pipe_a + pipe_b) * 0.5
		var pipe_dist: float = pipe_a.distance_to(pipe_b)
		var bridge := MeshInstance3D.new()
		var bridge_box := BoxMesh.new()
		bridge_box.size = Vector3(pipe_dist, 0.12, 0.12)
		bridge.mesh = bridge_box
		bridge.position = pipe_mid
		bridge.rotation.y = atan2(pipe_b.x - pipe_a.x, pipe_b.z - pipe_a.z) - PI * 0.5
		bridge.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.30, 0.26, 0.18)))
		_attach_visual(bridge)
		# Brass support struts hanging from the bridge midpoint.
		for s_i: int in 2:
			var strut := MeshInstance3D.new()
			var strut_box := BoxMesh.new()
			strut_box.size = Vector3(0.05, 0.30, 0.05)
			strut.mesh = strut_box
			var t: float = 0.3 + float(s_i) * 0.4
			var sp: Vector3 = pipe_a.lerp(pipe_b, t)
			strut.position = Vector3(sp.x, sp.y - 0.15, sp.z)
			strut.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.45, 0.36, 0.18)))
			_attach_visual(strut)

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
	var is_advanced: bool = stats.building_id == &"advanced_generator"
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

	# Cooling tower — eight chunky radial fins ringing the core, deeper
	# and thicker than the previous four-fin version. Real silhouette
	# from any camera angle, not a thin cross-shape that disappears
	# at oblique angles.
	for i: int in 8:
		var ang: float = float(i) * (PI * 0.25)
		var fin := MeshInstance3D.new()
		var fin_box := BoxMesh.new()
		fin_box.size = Vector3(0.18, fs.y * 0.55, fs.x * 0.22)
		fin.mesh = fin_box
		var dx: float = sin(ang) * (fs.x * 0.38)
		var dz: float = cos(ang) * (fs.x * 0.38)
		fin.position = Vector3(dx, fs.y + fin_box.size.y * 0.5, dz)
		fin.rotation.y = -ang
		fin.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.22, 0.22)))
		_attach_visual(fin)
	# Stacked radiator rings — three horizontal bands around the core
	# add the slatted-cooling-tower read at every camera angle. These
	# are thin discs sandwiched between the core and the fins.
	for ring_i: int in 3:
		var ring := MeshInstance3D.new()
		var ring_cyl := CylinderMesh.new()
		ring_cyl.top_radius = fs.x * 0.36
		ring_cyl.bottom_radius = fs.x * 0.36
		ring_cyl.height = 0.08
		ring.mesh = ring_cyl
		var ry: float = fs.y + (float(ring_i) + 0.5) * (core_cyl.height / 3.0)
		ring.position = Vector3(0, ry, 0)
		ring.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.18, 0.18)))
		_attach_visual(ring)

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

	# Advanced Generator (Reactor) support structures -- a ring of
	# external coolant towers + radial pylon supports + a stout
	# secondary stack so the upgraded tier reads as 'industrial
	# reactor', not just a bigger basic generator.
	if is_advanced:
		_apply_reactor_support_structures(fs)


func _apply_reactor_support_structures(fs: Vector3) -> void:
	# Ring of external coolant towers around the main core. Four short
	# cylinders set just outside the chassis at compass points -- each
	# capped with a slight emissive glow so the reactor reads as
	# 'multiple stage cooling system' from any angle.
	for i: int in 4:
		var ang: float = float(i) * (PI * 0.5) + PI * 0.25
		var tower := MeshInstance3D.new()
		var t_cyl := CylinderMesh.new()
		t_cyl.top_radius = fs.x * 0.12
		t_cyl.bottom_radius = fs.x * 0.14
		t_cyl.height = fs.y * 0.85
		t_cyl.radial_segments = 12
		tower.mesh = t_cyl
		var tx: float = sin(ang) * fs.x * 0.62
		var tz: float = cos(ang) * fs.z * 0.62
		tower.position = Vector3(tx, t_cyl.height * 0.5, tz)
		tower.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.18, 0.20)))
		_attach_visual(tower)
		# Radial pylon connecting the tower to the main chassis --
		# slim diagonal box that reads as a coolant pipe / structural
		# brace tying the support tower to the core.
		var pylon := MeshInstance3D.new()
		var py_box := BoxMesh.new()
		py_box.size = Vector3(0.10, 0.08, fs.x * 0.30)
		pylon.mesh = py_box
		pylon.position = Vector3(tx * 0.55, fs.y * 0.55, tz * 0.55)
		pylon.rotation.y = ang
		pylon.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.15, 0.14)))
		_attach_visual(pylon)
		# Glowing top cap -- small emissive disc on each tower so the
		# support cluster sells the 'high-power reactor' read at zoom.
		var glow := MeshInstance3D.new()
		var g_cyl := CylinderMesh.new()
		g_cyl.top_radius = fs.x * 0.10
		g_cyl.bottom_radius = fs.x * 0.10
		g_cyl.height = 0.06
		glow.mesh = g_cyl
		glow.position = Vector3(tx, t_cyl.height + 0.04, tz)
		glow.set_surface_override_material(0, _detail_emissive_mat(Color(0.30, 0.85, 1.0), 1.6))
		_attach_visual(glow)
	# Secondary thicker exhaust stack rising off the rear of the
	# chassis -- offset so it doesn't fight the central core for
	# silhouette and gives the reactor a real industrial-stack
	# profile.
	var stack := MeshInstance3D.new()
	var stack_cyl := CylinderMesh.new()
	stack_cyl.top_radius = fs.x * 0.16
	stack_cyl.bottom_radius = fs.x * 0.20
	stack_cyl.height = fs.y * 1.30
	stack_cyl.radial_segments = 16
	stack.mesh = stack_cyl
	stack.position = Vector3(fs.x * 0.30, fs.y + stack_cyl.height * 0.5, -fs.z * 0.10)
	stack.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.15, 0.14)))
	_attach_visual(stack)
	# Stack rim collar so the exhaust mouth has machined character.
	var rim := MeshInstance3D.new()
	var rim_cyl := CylinderMesh.new()
	rim_cyl.top_radius = fs.x * 0.18
	rim_cyl.bottom_radius = fs.x * 0.18
	rim_cyl.height = 0.06
	rim.mesh = rim_cyl
	rim.position = Vector3(stack.position.x, fs.y + stack_cyl.height + 0.04, stack.position.z)
	rim.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.10, 0.09, 0.08)))
	_attach_visual(rim)
	# Hot core inside the stack -- emissive disc deep enough to read
	# as a real venting opening when the camera drifts off-axis.
	var core_glow := MeshInstance3D.new()
	var cg_cyl := CylinderMesh.new()
	cg_cyl.top_radius = fs.x * 0.13
	cg_cyl.bottom_radius = fs.x * 0.13
	cg_cyl.height = 0.06
	core_glow.mesh = cg_cyl
	core_glow.position = Vector3(stack.position.x, fs.y + stack_cyl.height - 0.04, stack.position.z)
	core_glow.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.45, 0.10), 2.6))
	_attach_visual(core_glow)


func _detail_armory() -> void:
	var fs: Vector3 = stats.footprint_size
	# Hex-aligned vertical rib panels -- one rib on each of the six
	# hex faces of the new armory hull. Previously placed at fixed
	# +/-X positions assuming a box hull, which clipped through the
	# hex's corner vertices and read as misaligned. Hex flat-face
	# centres sit at angles 0, 60, 120, 180, 240, 300 deg around
	# the cylinder; placing each rib on the face midpoint keeps
	# them flush with the wall.
	var radius: float = fs.x * 0.5
	for face_i: int in 6:
		var ang: float = float(face_i) * (PI / 3.0)
		var rib := MeshInstance3D.new()
		var rib_box := BoxMesh.new()
		rib_box.size = Vector3(0.10, fs.y * 0.70, 0.06)
		rib.mesh = rib_box
		# Push slightly outward from the face so the rib reads as
		# proud of the wall instead of clipping through.
		var face_radius: float = radius * 0.94
		rib.position = Vector3(sin(ang) * face_radius, fs.y * 0.5, cos(ang) * face_radius)
		rib.rotation.y = ang
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

	# Loading dock -- recessed lit interior with a header beam.
	_build_lit_doorway(
		Vector3(0.0, fs.y * 0.30, -fs.z * 0.5),
		fs.x * 0.40,
		fs.y * 0.55,
		Color(0.95, 0.65, 0.20),
	)

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

	# Small roof antenna with a coloured tip — Anvil's warm-red warning
	# light, Sable's violet pulse. Reads as "this building has comms"
	# without needing the full Advanced Armory mast/dish kit.
	var ant_accent: Color = Color(1.0, 0.30, 0.20) if _resolve_faction_id() == 0 else Color(0.78, 0.45, 1.0)
	var antenna := MeshInstance3D.new()
	var ant_box := BoxMesh.new()
	ant_box.size = Vector3(0.06, fs.y * 0.55, 0.06)
	antenna.mesh = ant_box
	antenna.position = Vector3(fs.x * 0.18, fs.y + ant_box.size.y * 0.5, fs.z * 0.18)
	antenna.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.14, 0.14)))
	_attach_visual(antenna)
	var ant_tip := MeshInstance3D.new()
	var tip_sph := SphereMesh.new()
	tip_sph.radius = 0.10
	tip_sph.height = 0.20
	ant_tip.mesh = tip_sph
	ant_tip.position = Vector3(antenna.position.x, fs.y + ant_box.size.y + 0.04, antenna.position.z)
	ant_tip.set_surface_override_material(0, _detail_emissive_mat(ant_accent, 2.4))
	_attach_visual(ant_tip)


func _detail_advanced_armory() -> void:
	## Advanced Armory silhouette — reads as "upgraded armory" rather
	## than a different building. Keeps the rib panels + dock door of
	## the basic armory so the family resemblance is obvious, then
	## adds: a raised research bay with skylights on the roof, a
	## dish/scanner on top, and emissive accents (Anvil red / Sable
	## violet) so the player can pick the upgrade tier out at range.
	var fs: Vector3 = stats.footprint_size
	# Faction accent — Anvil reads as warm-red warning lights matching
	# unit antennae and barrel tips; Sable keeps the violet tech-glow.
	# Earlier the violet was hard-coded for both factions and the
	# Anvil armory looked like a Sable defection.
	var accent: Color = Color(0.78, 0.45, 1.0)
	if _resolve_faction_id() == 0:
		accent = Color(1.0, 0.30, 0.20)
	# Hex-aligned ribs -- one per hex face, matching the basic
	# armory pattern but in a slightly cooler tone for the advanced
	# tier read.
	var radius: float = fs.x * 0.5
	for face_i: int in 6:
		var ang: float = float(face_i) * (PI / 3.0)
		var rib := MeshInstance3D.new()
		var rib_box := BoxMesh.new()
		rib_box.size = Vector3(0.10, fs.y * 0.70, 0.06)
		rib.mesh = rib_box
		var face_radius: float = radius * 0.94
		rib.position = Vector3(sin(ang) * face_radius, fs.y * 0.5, cos(ang) * face_radius)
		rib.rotation.y = ang
		rib.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.20, 0.18, 0.22)))
		_attach_visual(rib)

	# Raised research bay on the roof — a smaller setback box that
	# reads as a second story / clean room. The skylight strips on
	# its sides hint at the optics work happening inside.
	var bay := MeshInstance3D.new()
	var bay_box := BoxMesh.new()
	bay_box.size = Vector3(fs.x * 0.6, fs.y * 0.45, fs.z * 0.55)
	bay.mesh = bay_box
	bay.position = Vector3(0, fs.y + bay_box.size.y * 0.5, 0)
	bay.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.26, 0.24, 0.28)))
	_attach_visual(bay)

	# Violet skylight strip wrapping the bay's long sides — distinguishes
	# Advanced Armory from Basic Armory's amber indicator.
	for side: int in 2:
		var sx: float = -bay_box.size.x * 0.5 - 0.02 if side == 0 else bay_box.size.x * 0.5 + 0.02
		var skylight := MeshInstance3D.new()
		var sk_box := BoxMesh.new()
		sk_box.size = Vector3(0.04, bay_box.size.y * 0.4, bay_box.size.z * 0.85)
		skylight.mesh = sk_box
		skylight.position = Vector3(sx, fs.y + bay_box.size.y * 0.55, 0)
		skylight.set_surface_override_material(0, _detail_emissive_mat(accent, 1.6))
		_attach_visual(skylight)

	# Dish / scanner mast on the roof bay — angled slightly so the
	# silhouette reads from the side as well as above.
	var mast := MeshInstance3D.new()
	var mast_box := BoxMesh.new()
	mast_box.size = Vector3(0.08, bay_box.size.y * 0.9, 0.08)
	mast.mesh = mast_box
	mast.position = Vector3(fs.x * 0.18, fs.y + bay_box.size.y + mast_box.size.y * 0.5, fs.z * 0.05)
	mast.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.18)))
	_attach_visual(mast)

	var dish := MeshInstance3D.new()
	var dish_cyl := CylinderMesh.new()
	dish_cyl.top_radius = 0.36
	dish_cyl.bottom_radius = 0.36
	dish_cyl.height = 0.06
	dish.mesh = dish_cyl
	dish.position = Vector3(fs.x * 0.18, fs.y + bay_box.size.y + mast_box.size.y, fs.z * 0.05)
	dish.rotation = Vector3(deg_to_rad(20.0), 0.0, 0.0)
	dish.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.30, 0.28, 0.32)))
	_attach_visual(dish)

	# Tall comm spire on the OPPOSITE corner of the bay -- balances
	# the dish's right-side mast and gives the advanced armory a
	# distinct vertical silhouette beyond just "box with skylights".
	var spire := MeshInstance3D.new()
	var spire_box := BoxMesh.new()
	spire_box.size = Vector3(0.10, fs.y * 1.10, 0.10)
	spire.mesh = spire_box
	spire.position = Vector3(-fs.x * 0.22, fs.y + bay_box.size.y + spire_box.size.y * 0.5, -fs.z * 0.10)
	spire.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.14, 0.16)))
	_attach_visual(spire)
	# Two coil rings stacked on the spire -- evoke the tesla-coil
	# look that says "research building".
	for ring_i: int in 2:
		var ring := MeshInstance3D.new()
		var ring_torus := TorusMesh.new()
		ring_torus.inner_radius = 0.18
		ring_torus.outer_radius = 0.24
		ring_torus.rings = 18
		ring_torus.ring_segments = 6
		ring.mesh = ring_torus
		var ry: float = fs.y + bay_box.size.y + 0.30 + float(ring_i) * 0.50
		ring.position = Vector3(-fs.x * 0.22, ry, -fs.z * 0.10)
		ring.set_surface_override_material(0, _detail_emissive_mat(accent, 1.0))
		_attach_visual(ring)
	# Pulse beacon at the spire tip — same accent as rings/skylights.
	var beacon := MeshInstance3D.new()
	var beacon_sphere := SphereMesh.new()
	beacon_sphere.radius = 0.10
	beacon_sphere.height = 0.20
	beacon.mesh = beacon_sphere
	beacon.position = Vector3(-fs.x * 0.22, fs.y + bay_box.size.y + spire_box.size.y + 0.05, -fs.z * 0.10)
	beacon.set_surface_override_material(0, _detail_emissive_mat(accent, 2.4))
	_attach_visual(beacon)

	# Optics ports along the front bay wall -- small extruded
	# cylinders with violet "eyes", reading as scanning equipment.
	for op_i: int in 3:
		var port := MeshInstance3D.new()
		var port_cyl := CylinderMesh.new()
		port_cyl.top_radius = 0.06
		port_cyl.bottom_radius = 0.06
		port_cyl.height = 0.08
		port.mesh = port_cyl
		port.rotation.x = PI * 0.5
		var px: float = (float(op_i) - 1.0) * bay_box.size.x * 0.30
		port.position = Vector3(px, fs.y + bay_box.size.y * 0.55, -bay_box.size.z * 0.5 - 0.04)
		port.set_surface_override_material(0, _detail_emissive_mat(accent, 1.6))
		_attach_visual(port)

	# Loading dock -- same recessed-with-interior treatment as the
	# basic armory, lit with the faction accent so the upgrade tier's
	# identity reads through the entrance too.
	_build_lit_doorway(
		Vector3(0.0, fs.y * 0.30, -fs.z * 0.5),
		fs.x * 0.40,
		fs.y * 0.55,
		accent,
	)


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


func _detail_aerodrome() -> void:
	## Aerodrome — landing pad with hangar entrance + control tower.
	## V3 §"Pillar 3" production building for aircraft.
	var fs: Vector3 = stats.footprint_size
	var sable: bool = _resolve_faction_id() == 1
	var team_color: Color = _resolve_team_color()

	# Plain dark roof deck — featureless metal, the corrugation lives
	# on the control tower's top cap instead of being plastered
	# across the entire building roof.
	var roof_color: Color = Color(0.30, 0.32, 0.36, 1.0)
	if sable:
		roof_color = Color(0.18, 0.16, 0.22, 1.0)
	var roof := MeshInstance3D.new()
	var roof_box := BoxMesh.new()
	roof_box.size = Vector3(fs.x * 0.96, 0.10, fs.z * 0.96)
	roof.mesh = roof_box
	roof.position = Vector3(0, fs.y + 0.05, 0)
	roof.set_surface_override_material(0, _detail_dark_metal_mat(roof_color))
	_attach_visual(roof)

	# Diagonal landing strip — corner-to-corner. The diagonal axis
	# is now the OPPOSITE of the previous version (front-left to
	# rear-right is the canonical runway here). Slightly wider hull
	# + thinner yellow centre dashes + blinking edge lights spaced
	# along the runway.
	var strip_diag_len: float = sqrt(fs.x * fs.x + fs.z * fs.z) * 0.86
	var strip_width: float = 2.20
	var strip := MeshInstance3D.new()
	var strip_box := BoxMesh.new()
	strip_box.size = Vector3(strip_width, 0.06, strip_diag_len)
	strip.mesh = strip_box
	strip.position = Vector3(0, fs.y + 0.12, 0)
	# Front-left corner -> rear-right corner. Same direction for both
	# factions for consistency; the visible distinction lives in the
	# tower silhouette and the seam pattern.
	var strip_angle_deg: float = 45.0
	strip.rotation.y = deg_to_rad(strip_angle_deg)
	strip.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.12, 0.13, 0.16, 1.0)))
	_attach_visual(strip)
	# Thin yellow centerline dashes — narrower than v1 so they read
	# as "stripes painted on the tarmac" instead of a wide warning
	# stripe. Emissive enough to catch the eye.
	var dash_color: Color = Color(0.95, 0.85, 0.30, 1.0)
	var dash_mat := StandardMaterial3D.new()
	dash_mat.albedo_color = dash_color
	dash_mat.emission_enabled = true
	dash_mat.emission = dash_color
	dash_mat.emission_energy_multiplier = 0.65
	dash_mat.roughness = 0.55
	var dash_count: int = 7
	var ang: float = deg_to_rad(strip_angle_deg)
	for d_i: int in dash_count:
		var dash := MeshInstance3D.new()
		var db := BoxMesh.new()
		db.size = Vector3(0.10, 0.03, strip_diag_len * 0.08)
		dash.mesh = db
		var dt: float = (float(d_i) + 0.5) / float(dash_count)
		var local_z: float = -strip_diag_len * 0.5 + dt * strip_diag_len
		dash.position = Vector3(sin(ang) * local_z, fs.y + 0.16, cos(ang) * local_z)
		dash.rotation.y = ang
		dash.set_surface_override_material(0, dash_mat)
		_attach_visual(dash)
	# Blinking edge lights — small emissive points spaced along
	# both edges of the runway. The atmos-anim system on the
	# building processes phase-pulsed materials each tick; we add
	# our own materials list so each light fires independently.
	var light_count: int = 10
	for l_i: int in light_count:
		var t: float = (float(l_i) + 0.5) / float(light_count)
		var local_z: float = -strip_diag_len * 0.5 + t * strip_diag_len
		for edge: int in 2:
			var lateral: float = strip_width * 0.5 * (1.0 if edge == 0 else -1.0)
			var lx: float = sin(ang) * local_z + cos(ang) * lateral
			var lz: float = cos(ang) * local_z - sin(ang) * lateral
			var lamp := MeshInstance3D.new()
			var lb := BoxMesh.new()
			lb.size = Vector3(0.10, 0.06, 0.10)
			lamp.mesh = lb
			lamp.position = Vector3(lx, fs.y + 0.18, lz)
			var lamp_color: Color = Color(0.95, 0.55, 0.20, 1.0) if not sable else Color(0.78, 0.35, 1.0, 1.0)
			var lamp_mat: StandardMaterial3D = _detail_emissive_mat(lamp_color, 1.6)
			lamp.set_surface_override_material(0, lamp_mat)
			_attach_visual(lamp)
			# Phase-shifted blink so adjacent lamps don't all flash
			# in lockstep — produces the chasing-runway-light read.
			var phase: float = (float(l_i) * 0.6 + float(edge) * 0.3)
			_atmos_indicator_mats.append({
				"mat": lamp_mat, "phase": phase, "base": 1.6,
			})

	# Team-color accent points — TWO small corner caps (front-left +
	# rear-right or matching pair) plus a slim band along the rear
	# edge. Replaces the previous full-footprint team slab that was
	# painting the whole roof in player color.
	var accent_mat := StandardMaterial3D.new()
	accent_mat.albedo_color = team_color
	accent_mat.emission_enabled = true
	accent_mat.emission = team_color
	accent_mat.emission_energy_multiplier = 1.2
	accent_mat.roughness = 0.55
	for cap_i: int in 2:
		var cap_pt := MeshInstance3D.new()
		var cap_box := BoxMesh.new()
		cap_box.size = Vector3(0.55, 0.08, 0.55)
		cap_pt.mesh = cap_box
		var cx: float = fs.x * 0.42 if cap_i == 0 else -fs.x * 0.42
		var cz: float = fs.z * 0.42 if cap_i == 0 else -fs.z * 0.42
		cap_pt.position = Vector3(cx, fs.y + 0.20, cz)
		cap_pt.set_surface_override_material(0, accent_mat)
		_attach_visual(cap_pt)
	# Slim rear team band — short strip at the back of the roof so
	# ownership reads from the rear too.
	var rear_band := MeshInstance3D.new()
	var rear_box := BoxMesh.new()
	rear_box.size = Vector3(fs.x * 0.45, 0.06, 0.18)
	rear_band.mesh = rear_box
	rear_band.position = Vector3(0, fs.y + 0.24, fs.z * 0.45)
	rear_band.set_surface_override_material(0, accent_mat)
	_attach_visual(rear_band)

	# Control tower — diverges per faction. Anvil ships a wide,
	# squat brutalist concrete block with a slatted observation cap.
	# Sable ships a slim glass spike with a single slim band.
	if sable:
		_build_aerodrome_tower_sable(fs)
	else:
		_build_aerodrome_tower_anvil(fs)

	# Hangar opening — proper recessed entrance with header beam,
	# jamb posts, hanging segmented blast doors, and amber interior
	# glow. Reads as a real production gate rather than a flat
	# decal stuck on the front face.
	var hangar_w: float = fs.x * 0.55
	var hangar_h: float = fs.y * 0.70
	var front_z: float = fs.z * 0.5
	# Deep dark interior cavity — most of it sits inside the wall;
	# only a sliver pokes out so the cavity edge reads.
	var cavity_depth: float = 0.85
	var cavity := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(hangar_w, hangar_h, cavity_depth)
	cavity.mesh = cb
	cavity.position = Vector3(0, hangar_h * 0.5 + 0.05, front_z - cavity_depth * 0.4)
	var cavity_mat := StandardMaterial3D.new()
	cavity_mat.albedo_color = Color(0.04, 0.03, 0.02, 1.0)
	cavity_mat.emission_enabled = true
	cavity_mat.emission = Color(0.95, 0.55, 0.18, 1.0)
	cavity_mat.emission_energy_multiplier = 0.45
	cavity.set_surface_override_material(0, cavity_mat)
	_attach_visual(cavity)
	# Heavy header beam across the top of the gate, sticking out
	# from the wall so it casts a ledge shadow over the cavity.
	var header := MeshInstance3D.new()
	var hb := BoxMesh.new()
	hb.size = Vector3(hangar_w + 0.50, 0.32, 0.45)
	header.mesh = hb
	header.position = Vector3(0, hangar_h + 0.21, front_z + 0.18)
	header.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.28, 0.22, 1.0)))
	_attach_visual(header)
	# Hazard chevrons on the header — alternating angled slabs in
	# warning yellow so the gate reads as restricted entry.
	var chev_mat := StandardMaterial3D.new()
	chev_mat.albedo_color = Color(0.95, 0.78, 0.18, 1.0)
	chev_mat.emission_enabled = true
	chev_mat.emission = Color(0.95, 0.78, 0.18, 1.0)
	chev_mat.emission_energy_multiplier = 0.55
	chev_mat.roughness = 0.6
	var chev_count: int = 5
	for c_i: int in chev_count:
		var chev := MeshInstance3D.new()
		var cbox := BoxMesh.new()
		cbox.size = Vector3(0.30, 0.06, 0.06)
		chev.mesh = cbox
		var ct: float = (float(c_i) + 0.5) / float(chev_count)
		var cx: float = -hangar_w * 0.5 + ct * hangar_w
		chev.position = Vector3(cx, hangar_h + 0.34, front_z + 0.42)
		chev.rotation.z = deg_to_rad(35.0 if c_i % 2 == 0 else -35.0)
		chev.set_surface_override_material(0, chev_mat)
		_attach_visual(chev)
	# Jamb posts framing the opening.
	var jamb_mat: StandardMaterial3D = _detail_dark_metal_mat(Color(0.28, 0.24, 0.20, 1.0))
	for side: int in 2:
		var jx: float = -hangar_w * 0.5 - 0.12 if side == 0 else hangar_w * 0.5 + 0.12
		var jamb := MeshInstance3D.new()
		var jb := BoxMesh.new()
		jb.size = Vector3(0.24, hangar_h + 0.10, 0.45)
		jamb.mesh = jb
		jamb.position = Vector3(jx, (hangar_h + 0.10) * 0.5 + 0.05, front_z + 0.18)
		jamb.set_surface_override_material(0, jamb_mat)
		_attach_visual(jamb)
	# Two segmented blast-door panels hanging from the header — the
	# door is "open" but the panels are still visible above the
	# cavity, suggesting it can close.
	for door_i: int in 2:
		var door := MeshInstance3D.new()
		var db := BoxMesh.new()
		db.size = Vector3(hangar_w * 0.48, 0.40, 0.08)
		door.mesh = db
		var dx: float = -hangar_w * 0.25 if door_i == 0 else hangar_w * 0.25
		door.position = Vector3(dx, hangar_h - 0.16, front_z + 0.06)
		door.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14, 1.0)))
		_attach_visual(door)
	# Floor markings on the hangar approach — short bright strips
	# leading INTO the gate, on the ground.
	for f_i: int in 3:
		var floor_mark := MeshInstance3D.new()
		var fmb := BoxMesh.new()
		fmb.size = Vector3(0.40, 0.04, 0.18)
		floor_mark.mesh = fmb
		var ft: float = (float(f_i) + 0.5) / 3.0
		var fmx: float = -hangar_w * 0.18 + ft * hangar_w * 0.36
		floor_mark.position = Vector3(fmx, 0.05, front_z + 0.55)
		floor_mark.set_surface_override_material(0, chev_mat)
		_attach_visual(floor_mark)
	# Pair of amber interior pillar lamps deep in the cavity.
	for lamp_i: int in 2:
		var lamp := MeshInstance3D.new()
		var lcyl := CylinderMesh.new()
		lcyl.top_radius = 0.10
		lcyl.bottom_radius = 0.10
		lcyl.height = 0.06
		lamp.mesh = lcyl
		lamp.rotation.x = PI * 0.5
		var lx: float = -hangar_w * 0.30 if lamp_i == 0 else hangar_w * 0.30
		lamp.position = Vector3(lx, hangar_h * 0.85, front_z - 0.05)
		lamp.set_surface_override_material(0, _detail_emissive_mat(Color(1.0, 0.65, 0.20), 1.6))
		_attach_visual(lamp)


func _build_aerodrome_tower_anvil(fs: Vector3) -> void:
	## Wide, squat concrete brutalist tower at the rear-left corner
	## with a slatted observation cap. Reads "industrial control
	## bunker" — heavier and more grounded than the Sable variant.
	var tower := MeshInstance3D.new()
	var tower_box := BoxMesh.new()
	tower_box.size = Vector3(fs.x * 0.36, fs.y * 1.15, fs.z * 0.36)
	tower.mesh = tower_box
	tower.position = Vector3(-fs.x * 0.30, fs.y + tower_box.size.y * 0.5, -fs.z * 0.30)
	tower.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.30, 0.27, 1.0)))
	_attach_visual(tower)
	# Slatted observation deck — wider cap with horizontal louvre
	# slits for that brutalist control-room read.
	var cap_y: float = fs.y + tower_box.size.y + 0.18
	var cap := MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	cap_box.size = Vector3(fs.x * 0.46, 0.30, fs.z * 0.46)
	cap.mesh = cap_box
	cap.position = Vector3(-fs.x * 0.30, cap_y, -fs.z * 0.30)
	cap.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.42, 0.36, 0.28, 1.0)))
	_attach_visual(cap)
	# Corrugated Wellblech roof on the tower cap — the actual
	# intended home for the corrugation pattern. Series of slim
	# raised ribs across the cap top.
	var rib_color: Color = Color(0.32, 0.28, 0.22, 1.0)
	var cap_w: float = fs.x * 0.46
	var cap_d: float = fs.z * 0.46
	var rib_count: int = 6
	for r_i: int in rib_count:
		var rib := MeshInstance3D.new()
		var rb := BoxMesh.new()
		rb.size = Vector3(cap_w * 0.95, 0.08, 0.10)
		rib.mesh = rb
		var t_rib: float = (float(r_i) + 0.5) / float(rib_count)
		var rz: float = -cap_d * 0.45 + t_rib * (cap_d * 0.90)
		rib.position = Vector3(-fs.x * 0.30, cap_y + 0.18, -fs.z * 0.30 + rz)
		rib.set_surface_override_material(0, _detail_dark_metal_mat(rib_color))
		_attach_visual(rib)
	# Two louvre slits across the cap front — emissive amber so the
	# control room reads as occupied.
	var slit_mat := StandardMaterial3D.new()
	slit_mat.albedo_color = Color(0.95, 0.55, 0.20, 1.0)
	slit_mat.emission_enabled = true
	slit_mat.emission = Color(0.95, 0.55, 0.20, 1.0)
	slit_mat.emission_energy_multiplier = 0.95
	for s_i: int in 2:
		var slit := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(fs.x * 0.40, 0.06, 0.04)
		slit.mesh = sb
		slit.position = Vector3(-fs.x * 0.30, cap_y + (0.06 if s_i == 0 else -0.06), -fs.z * 0.30 - fs.z * 0.23)
		slit.set_surface_override_material(0, slit_mat)
		_attach_visual(slit)
	# Stout antenna mast on the cap.
	var antenna := MeshInstance3D.new()
	var ant_box := BoxMesh.new()
	ant_box.size = Vector3(0.10, 0.85, 0.10)
	antenna.mesh = ant_box
	antenna.position = Vector3(-fs.x * 0.30, cap_y + 0.30 + 0.42, -fs.z * 0.30)
	antenna.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14, 1.0)))
	_attach_visual(antenna)


func _build_aerodrome_tower_sable(fs: Vector3) -> void:
	## Slim glass spike at the rear-left corner with a single violet
	## band near the top. Daintier silhouette than the Anvil control
	## bunker — reads as a sleek corp observation tower.
	var spike := MeshInstance3D.new()
	var spike_box := BoxMesh.new()
	spike_box.size = Vector3(fs.x * 0.20, fs.y * 1.55, fs.z * 0.20)
	spike.mesh = spike_box
	spike.position = Vector3(-fs.x * 0.30, fs.y + spike_box.size.y * 0.5, -fs.z * 0.30)
	spike.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.10, 0.10, 0.14, 1.0)))
	_attach_visual(spike)
	# Single violet band — slim emissive ring near the top, much
	# more restrained than the warm slatted cap on Anvil.
	var band_y: float = fs.y + spike_box.size.y * 0.85
	var band_mat := StandardMaterial3D.new()
	const SABLE_VIOLET := Color(0.78, 0.35, 1.0, 1.0)
	band_mat.albedo_color = SABLE_VIOLET
	band_mat.emission_enabled = true
	band_mat.emission = SABLE_VIOLET
	band_mat.emission_energy_multiplier = 1.6
	band_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for face_i: int in 4:
		var band := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(fs.x * 0.22 if face_i % 2 == 0 else 0.04, 0.06, fs.z * 0.22 if face_i % 2 == 1 else 0.04)
		band.mesh = bb
		var fx: float = -fs.x * 0.30
		var fz: float = -fs.z * 0.30
		match face_i:
			0: fz += fs.z * 0.10
			1: fx += fs.x * 0.10
			2: fz -= fs.z * 0.10
			3: fx -= fs.x * 0.10
		band.position = Vector3(fx, band_y, fz)
		band.set_surface_override_material(0, band_mat)
		_attach_visual(band)
	# Hair-thin antenna with a single violet tip — the spike is
	# narrow enough that a chunky antenna would unbalance it.
	var antenna := MeshInstance3D.new()
	var ant_box := BoxMesh.new()
	ant_box.size = Vector3(0.06, 0.65, 0.06)
	antenna.mesh = ant_box
	antenna.position = Vector3(-fs.x * 0.30, fs.y + spike_box.size.y + 0.32, -fs.z * 0.30)
	antenna.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.16, 0.16, 0.20, 1.0)))
	_attach_visual(antenna)
	var tip := MeshInstance3D.new()
	var tip_box := BoxMesh.new()
	tip_box.size = Vector3(0.10, 0.06, 0.10)
	tip.mesh = tip_box
	tip.position = Vector3(-fs.x * 0.30, fs.y + spike_box.size.y + 0.65, -fs.z * 0.30)
	tip.set_surface_override_material(0, band_mat)
	_attach_visual(tip)


func _detail_sam_site() -> void:
	## SAM Site — bunker base with a tilted missile launcher rack on
	## top. V3 §"Pillar 4" anti-air defense.
	var fs: Vector3 = stats.footprint_size
	# Slim team band -- cylindrical pad got the same "team band ate
	# the silhouette" treatment as the gun emplacement; trim to a
	# thinner waist stripe so the player-colour cue stays visible
	# without dominating the chassis.
	_team_collar(fs.x * 0.55, 0.06, fs.z * 0.55, Vector3(0, fs.y + 0.05, 0))

	# Rotating launcher base — a flat disc on top of the bunker.
	var base_disc := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = fs.x * 0.45
	disc.bottom_radius = fs.x * 0.5
	disc.height = 0.18
	base_disc.mesh = disc
	base_disc.position = Vector3(0, fs.y + 0.09, 0)
	base_disc.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.20, 0.20, 0.22)))
	_attach_visual(base_disc)

	# Pivot for the launcher (used by TurretComponent for tracking).
	var pivot := Node3D.new()
	pivot.name = "TurretPivot"
	pivot.position = Vector3(0, fs.y + 0.18, 0)
	_attach_visual(pivot)
	turret_pivot = pivot

	# Tilted launcher rack — angled up at ~35° for sky targeting.
	var rack_pivot := Node3D.new()
	rack_pivot.rotation.x = -deg_to_rad(35.0)
	pivot.add_child(rack_pivot)

	# Spine of the launcher rack.
	var rack := MeshInstance3D.new()
	var rack_box := BoxMesh.new()
	rack_box.size = Vector3(fs.x * 0.7, 0.18, 0.4)
	rack.mesh = rack_box
	rack.position = Vector3(0, 0.1, 0)
	rack.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.22, 0.23, 0.26)))
	rack_pivot.add_child(rack)

	# Chunky pod housing wrapping the missile cluster -- reads as a
	# real "sealed rocket pod" instead of an open carriage of single
	# missiles. The missiles still slot through the front face so
	# the warhead tips remain visible.
	var pod_housing := MeshInstance3D.new()
	var pod_box := BoxMesh.new()
	pod_box.size = Vector3(fs.x * 0.85, 0.46, fs.z * 0.95)
	pod_housing.mesh = pod_box
	pod_housing.position = Vector3(0, 0.30, fs.z * 0.10)
	pod_housing.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.18, 0.20)))
	rack_pivot.add_child(pod_housing)
	# Pod side ribs -- two slim emissive strips along the housing's
	# long edges so the pod silhouette pops at zoom.
	for rib_side: int in 2:
		var rsx: float = (-1.0 if rib_side == 0 else 1.0) * fs.x * 0.42
		var rib := MeshInstance3D.new()
		var rib_box_mesh := BoxMesh.new()
		rib_box_mesh.size = Vector3(0.06, 0.06, fs.z * 0.85)
		rib.mesh = rib_box_mesh
		rib.position = Vector3(rsx, 0.46, fs.z * 0.10)
		var rib_mat := StandardMaterial3D.new()
		rib_mat.albedo_color = Color(0.85, 0.18, 0.15, 1.0)
		rib_mat.emission_enabled = true
		rib_mat.emission = Color(1.0, 0.25, 0.18, 1.0)
		rib_mat.emission_energy_multiplier = 0.8
		rib.set_surface_override_material(0, rib_mat)
		rack_pivot.add_child(rib)

	# Four missiles in the rack — slim white-tipped tubes.
	for i: int in 4:
		var missile := MeshInstance3D.new()
		var missile_box := BoxMesh.new()
		missile_box.size = Vector3(0.16, 0.16, fs.z * 0.85)
		missile.mesh = missile_box
		missile.position = Vector3((float(i) - 1.5) * fs.x * 0.18, 0.18, fs.z * 0.4)
		var missile_mat := StandardMaterial3D.new()
		missile_mat.albedo_color = Color(0.78, 0.78, 0.80, 1.0)
		missile_mat.roughness = 0.5
		missile_mat.metallic = 0.4
		missile.set_surface_override_material(0, missile_mat)
		rack_pivot.add_child(missile)

		# Red warhead tip.
		var tip := MeshInstance3D.new()
		var tip_box := BoxMesh.new()
		tip_box.size = Vector3(0.14, 0.14, 0.18)
		tip.mesh = tip_box
		tip.position = Vector3(missile.position.x, missile.position.y, missile.position.z + fs.z * 0.42)
		var tip_mat := StandardMaterial3D.new()
		tip_mat.albedo_color = Color(0.85, 0.18, 0.15, 1.0)
		tip_mat.emission_enabled = true
		tip_mat.emission = Color(1.0, 0.25, 0.18, 1.0)
		tip_mat.emission_energy_multiplier = 0.5
		tip.set_surface_override_material(0, tip_mat)
		rack_pivot.add_child(tip)

	# Radar dish — tall mast with a small dish on top, behind the launcher.
	var mast := MeshInstance3D.new()
	var mast_box := BoxMesh.new()
	mast_box.size = Vector3(0.1, fs.y * 0.6, 0.1)
	mast.mesh = mast_box
	mast.position = Vector3(0, fs.y + fs.y * 0.4, -fs.z * 0.4)
	mast.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.18, 0.20)))
	_attach_visual(mast)

	var dish := MeshInstance3D.new()
	var dish_cyl := CylinderMesh.new()
	dish_cyl.top_radius = 0.4
	dish_cyl.bottom_radius = 0.55
	dish_cyl.height = 0.08
	dish.mesh = dish_cyl
	dish.position = Vector3(0, fs.y + fs.y * 0.7, -fs.z * 0.4)
	dish.rotation.x = deg_to_rad(-30.0)
	var dish_mat := StandardMaterial3D.new()
	dish_mat.albedo_color = Color(0.30, 0.30, 0.34, 1.0)
	dish_mat.emission_enabled = true
	dish_mat.emission = Color(0.55, 0.85, 1.0, 1.0)
	dish_mat.emission_energy_multiplier = 0.35
	dish.set_surface_override_material(0, dish_mat)
	_attach_visual(dish)


func _detail_gun_emplacement() -> void:
	var fs: Vector3 = stats.footprint_size
	# Slimmer team collar -- the previous fs.x * 0.95 wrapped the
	# entire turret cap and the player-coloured band ate most of the
	# silhouette. 0.45 gives a thinner waist band that still reads
	# as "this is mine" without dominating the chassis.
	_team_collar(fs.x * 0.45, 0.06, fs.z * 0.45, Vector3(0, fs.y + 0.05, 0))
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
	##
	## HQ defensive profile is hand-built by _build_hq_corner_mg_nest
	## (sandbag ring + tripod + small barrel) and skips this function
	## entirely -- otherwise the gun-emplacement-scaled dome
	## (fs.x * 0.42 = ~3u wide on the HQ) would land on top of the
	## corner nest as a massive turret cap.
	if profile == &"hq_defense":
		return
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
	# Create a rectangular obstacle matching the building footprint, with
	# extra padding so the 4 corners are covered by both the polygonal
	# avoidance vertices AND the conservative circular fallback radius.
	# The previous max(half_x, half_z) circle left building corners
	# uncovered, so units routing diagonally past a foundry would catch
	# on the corner.
	var half_x: float = stats.footprint_size.x * 0.65
	var half_z: float = stats.footprint_size.z * 0.65
	# Vertices MUST be counter-clockwise from above (i.e. with +Y as
	# the up axis Godot expects the polygon outline to wind CCW). The
	# previous CW winding caused Godot to invert the "inside" of the
	# obstacle, producing an effective avoidance region extending well
	# beyond the building footprint — manifesting as an invisible wall
	# running through the building when it was constructed.
	obstacle.vertices = PackedVector3Array([
		Vector3(-half_x, 0, -half_z),
		Vector3(-half_x, 0, half_z),
		Vector3(half_x, 0, half_z),
		Vector3(half_x, 0, -half_z),
	])
	obstacle.avoidance_enabled = true
	obstacle.radius = sqrt(half_x * half_x + half_z * half_z) + 0.4
	# Carve this obstacle out of any active navmesh so units re-plan
	# paths around the building as it appears. Without this, buildings
	# that the AI constructs after match start are invisible to the
	# baked navmesh, and units path straight through them and oscillate
	# against the collision wall — the "stuck on building" symptom.
	if "affect_navigation_mesh" in obstacle:
		obstacle.affect_navigation_mesh = true
	add_child(obstacle)


func _apply_placeholder_shape() -> void:
	if not stats:
		return

	# Per-role base shape so the building silhouette reads at a
	# glance even before the type-specific roof / detail layer
	# kicks in:
	#   power generator -> short cylinder (already)
	#   tech (armory + advanced armory) -> hex prism (8-sided)
	#   defense turrets -> short cylindrical pad
	#   everything else (production / economy / HQ / pylon) -> box
	var fs: Vector3 = stats.footprint_size
	match stats.building_id:
		&"basic_generator", &"advanced_generator":
			var cyl := CylinderMesh.new()
			cyl.top_radius = fs.x * 0.5
			cyl.bottom_radius = fs.x * 0.55
			cyl.height = fs.y
			_mesh.mesh = cyl
		&"basic_armory", &"advanced_armory":
			# Hex prism via a CylinderMesh with 6 radial segments --
			# avoids hand-building a SurfaceTool mesh while still
			# reading as a faceted research bunker.
			var hex := CylinderMesh.new()
			hex.radial_segments = 6
			hex.top_radius = fs.x * 0.5
			hex.bottom_radius = fs.x * 0.5
			hex.height = fs.y
			_mesh.mesh = hex
		&"gun_emplacement", &"gun_emplacement_basic", &"sam_site":
			# Cylindrical pad so the turret cap reads as
			# "fortified mount" rather than another box. Slight
			# bottom flare so the silhouette tapers visibly.
			var pad := CylinderMesh.new()
			pad.radial_segments = 16
			pad.top_radius = fs.x * 0.5
			pad.bottom_radius = fs.x * 0.55
			pad.height = fs.y
			_mesh.mesh = pad
		_:
			var box := BoxMesh.new()
			box.size = fs
			_mesh.mesh = box
	_mesh.position.y = fs.y / 2.0

	var mat := StandardMaterial3D.new()
	# Sable buildings render with the matte-black corpo cyberpunk
	# treatment — same hull shape as Anvil but desaturated and pulled
	# darker + cooler. Player team color still appears via the team
	# ring band, so faction identity reads alongside the team identity.
	# After the faction tint, blend a subtle role wash (Production
	# orange / Tech violet / Defense red / Power yellow / Economy
	# green / Command cool-white) into the chassis so the player can
	# tell category at a glance from the hull tint -- not just the
	# silhouette.
	var base_chassis: Color = _faction_tint_building_chassis(stats.placeholder_color)
	mat.albedo_color = _blend_role_tint(base_chassis, _building_role_color())
	# Same grime overlay as the detail metal so the main hull doesn't
	# read as flat colour while every doorway / vent / ladder around it
	# does. uv1_scale tuned to the larger surface area — bigger hull
	# faces sample more pattern repeats so the wear stays at panel-line
	# scale instead of stretching across the whole wall.
	mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	mat.uv1_offset = Vector3(randf(), randf(), 0.0)
	mat.uv1_scale = Vector3(2.5, 2.5, 1.0)
	mat.roughness = 0.9
	# Sable hulls are metallic-ish to lean into the corpo specops feel.
	if _resolve_faction_id() == 1:
		mat.metallic = 0.4
		mat.roughness = 0.55
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

	# Sable hull silhouette — overlays a stepped angular hull and tall
	# antenna spires on top of the boxy primitive so a Sable foundry,
	# armory, etc. reads as a different build language than Anvil's
	# blocky industrial hulks. Generator stays cylindrical (its
	# silhouette already contrasts), and HQ gets a stronger pyramid
	# treatment downstream.
	if _resolve_faction_id() == 1 and stats.building_id != &"basic_generator" and stats.building_id != &"advanced_generator":
		_apply_sable_building_silhouette()
	# Anvil brutalist treatment — heavy concrete corner pylons, a
	# raised plinth at the base, and a crenellated parapet on top.
	# Reads as Soviet-monolith industrial vs Sable's clean tower
	# proportions.
	if _resolve_faction_id() == 0 and stats.building_id != &"basic_generator" and stats.building_id != &"advanced_generator" and stats.building_id != &"gun_emplacement" and stats.building_id != &"gun_emplacement_basic":
		_apply_anvil_brutalist_extras()


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
	# Match the hull shape — cylinder body gets a cylindrical band, hex
	# armory gets a 6-segment cylindrical band so it wraps the hex faces
	# instead of poking past their corners as a rectangular box would.
	if stats.building_id == &"basic_generator" or stats.building_id == &"advanced_generator":
		var ring_cyl := CylinderMesh.new()
		ring_cyl.top_radius = stats.footprint_size.x * 0.5 + 0.06
		ring_cyl.bottom_radius = stats.footprint_size.x * 0.55 + 0.06
		ring_cyl.height = stats.footprint_size.y * 0.14
		_team_ring.mesh = ring_cyl
	elif stats.building_id == &"basic_armory" or stats.building_id == &"advanced_armory":
		var ring_hex := CylinderMesh.new()
		ring_hex.radial_segments = 6
		ring_hex.top_radius = stats.footprint_size.x * 0.5 + 0.06
		ring_hex.bottom_radius = stats.footprint_size.x * 0.5 + 0.06
		ring_hex.height = stats.footprint_size.y * 0.14
		_team_ring.mesh = ring_hex
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
## Sable's faction-identity accent — pale neon cyan glow line. Replaces
## the brass band on Sable buildings.
const SABLE_NEON := Color(0.78, 0.35, 1.0, 1.0)  # violet, paired with unit.gd
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
		&"basic_armory", &"advanced_armory":
			return _ROOF_TECH
		&"basic_generator", &"advanced_generator":
			return _ROOF_POWER
		&"gun_emplacement", &"gun_emplacement_basic":
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
	if stats.building_id == &"basic_generator" or stats.building_id == &"advanced_generator":
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
	cap_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	cap_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
	cap_mat.uv1_scale = Vector3(2.0, 2.0, 1.0)
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
	elif stats.building_id == &"gun_emplacement" or stats.building_id == &"gun_emplacement_basic":
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
	## Faction-identity accent on the front face. Anvil ships a horizontal
	## brass band; Sable replaces it with a thin neon-cyan emissive line
	## plus a vertical kicker so the silhouette reads as cyberpunk-corpo
	## instead of soviet-industrial. Despite the function name (kept for
	## backward compatibility), this also applies the Sable variant.
	if _brass_band and is_instance_valid(_brass_band):
		_brass_band.queue_free()
		_brass_band = null
	if not stats:
		return
	var faction_id: int = _resolve_faction_id()
	_brass_band = MeshInstance3D.new()
	var box := BoxMesh.new()
	if faction_id == 1:
		# Sable — thinner emissive cyan line.
		box.size = Vector3(
			stats.footprint_size.x * 0.50,
			stats.footprint_size.y * 0.04,
			0.05,
		)
	else:
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
	if faction_id == 1:
		mat.albedo_color = SABLE_NEON
		mat.emission_enabled = true
		mat.emission = SABLE_NEON
		mat.emission_energy_multiplier = 1.6
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	else:
		mat.albedo_color = ANVIL_BRASS
		mat.emission_enabled = true
		mat.emission = ANVIL_BRASS
		mat.emission_energy_multiplier = 0.5
		mat.metallic = 0.7
		mat.roughness = 0.4
	_brass_band.set_surface_override_material(0, mat)
	_attach_visual(_brass_band)
	# Sable adds a second vertical accent slash off-centre.
	if faction_id == 1:
		var vert := MeshInstance3D.new()
		var vbox := BoxMesh.new()
		vbox.size = Vector3(
			0.05,
			stats.footprint_size.y * 0.32,
			0.05,
		)
		vert.mesh = vbox
		vert.position = Vector3(
			stats.footprint_size.x * 0.20,
			stats.footprint_size.y * 0.20,
			-stats.footprint_size.z * 0.5 - 0.03,
		)
		vert.set_surface_override_material(0, mat)
		_attach_visual(vert)


func begin_construction() -> void:
	_construction_progress = 0.0
	is_constructed = false
	construction_started = false
	_apply_placeholder_shape()
	_create_progress_bar()
	# Foundation is a "ghost" — units can walk into and out of it freely until
	# the structure is complete. Solid collision is enabled in _finish_construction.
	if _collision:
		_collision.disabled = true
	# Sink the visuals so the building rises out of the ground as it's built.
	if _visual_root and stats:
		_visual_root.position.y = -stats.footprint_size.y * 0.95


func advance_construction(amount: float, builder: Node = null) -> void:
	if is_constructed:
		return
	# Construction halts while any unit is standing inside the footprint, so
	# foundations placed on top of units (or with units passing through) wait
	# for the area to clear before progressing.
	if not _is_foundation_clear():
		return
	# First tick of real progress flips construction_started so opponents'
	# FOW visibility + auto-target acquisition start treating the foundation
	# as a real structure. Pre-start foundations are placement intent only.
	construction_started = true
	_construction_progress += amount
	_build_amount_this_tick += amount
	if builder:
		_builders_this_tick[builder.get_instance_id()] = true
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


## Cache for the foundation-clear check. Recomputing across all units in
## the scene every construction tick was the dominant `Building.*`
## cost in the profiler (~62 µs per call × 32 building.advance calls/frame).
## Caching for ~0.25 s between recomputes keeps the construction-pause
## response feeling instant while cutting the per-frame cost ~10×.
var _foundation_clear_cached: bool = true
var _foundation_clear_recheck_at_msec: int = 0


func _is_foundation_clear() -> bool:
	## True when no unit's center is inside (or just at the edge of) the
	## building's XZ footprint. Margin = 0.4 prevents construction completing
	## while a unit is straddling the boundary, which used to trap engineers
	## the moment collision activated.
	if not stats:
		return true
	var now_msec: int = Time.get_ticks_msec()
	if now_msec < _foundation_clear_recheck_at_msec:
		return _foundation_clear_cached
	_foundation_clear_recheck_at_msec = now_msec + 250
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
			_foundation_clear_cached = false
			return false
	_foundation_clear_cached = true
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
	# Pop a unit far enough that its own collision capsule clears the
	# building edge — half_unit ≈ 1.0u + a comfortable margin so the
	# next move_and_slide doesn't immediately push it back inside.
	var clearance: float = 1.6
	# Iterate units AND crawlers — Crawler is in the "units" group too
	# but listing both is cheap and protects against future group changes.
	var trapped: Array[Node] = []
	for node: Node in get_tree().get_nodes_in_group("units"):
		trapped.append(node)
	for node: Node in get_tree().get_nodes_in_group("crawlers"):
		if not (node in trapped):
			trapped.append(node)
	for node: Node in trapped:
		if not is_instance_valid(node):
			continue
		var u: Node3D = node as Node3D
		if not u:
			continue
		var dx: float = u.global_position.x - global_position.x
		var dz: float = u.global_position.z - global_position.z
		var inside_x: bool = absf(dx) < half_x + 0.3
		var inside_z: bool = absf(dz) < half_z + 0.3
		if not (inside_x and inside_z):
			continue
		# Pop the unit out along whichever axis it's closest to escaping.
		var dx_in: float = half_x - dx
		var dz_in: float = half_z - dz
		# Use signed distances so we kick toward the *near* face on each
		# axis, not always +x / +z.
		var sign_x: float = 1.0 if dx >= 0.0 else -1.0
		var sign_z: float = 1.0 if dz >= 0.0 else -1.0
		if absf(dx_in) < absf(dz_in):
			u.global_position.x = global_position.x + (half_x + clearance) * sign_x
		else:
			u.global_position.z = global_position.z + (half_z + clearance) * sign_z
		# Reset Y to the building's ground plane. CharacterBody3D's
		# collision solver was sometimes pushing trapped units UP onto
		# the building's roof when their Y component was inside the
		# collider — the unit then bounced between floor + roof while
		# gravity pulled it back through. Resetting y kills that loop.
		u.global_position.y = global_position.y


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

	# Update label -- "PCT% • N workers • ~Xs" so the player can see
	# both the build progress and how many engineers to add for it
	# to finish faster.
	if _progress_label:
		var workers: int = _builders_last_tick.size()
		var line: String = "%d%%" % int(pct * 100.0)
		if workers > 0:
			line += "  •  %d worker%s" % [workers, "" if workers == 1 else "s"]
			if _build_rate_per_sec > 0.0001:
				var remaining: float = (stats.build_time - _construction_progress) / _build_rate_per_sec
				if remaining > 0.5:
					line += "  •  ~%ds" % int(ceilf(remaining))
		_progress_label.text = line


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
	if not (unit_stats in get_producible_units()):
		return false
	_build_queue.append(unit_stats)
	return true


## Resolve the building's producible-unit list for the OWNER's faction.
## Anvil owners see the BuildingStatResource's default `producible_units`
## list (the Anvil baseline). Sable owners get a Sable-specific roster
## per building_id, falling back to the Anvil list for tiers Sable
## hasn't filled in yet (V3 incremental rollout — Sable engineer/light/
## medium/heavy + air units exist; Crawler is shared with Anvil).
##
## After the faction lookup runs we apply unit-side tech gates: any
## UnitStatResource with unlock_prerequisite set is filtered out unless
## the owner has constructed that building. This is how Forgemaster /
## Hammerhead / Wraith / etc. are hidden behind the Advanced Armory
## (or Black Pylon, for Wraith) — the building keeps the unit in its
## producible_units list and the unit's gate decides visibility.
func get_producible_units() -> Array[UnitStatResource]:
	if not stats:
		return []
	var unfiltered: Array[UnitStatResource] = _faction_producible_list()
	if unfiltered.is_empty():
		return unfiltered
	var out: Array[UnitStatResource] = []
	for u: UnitStatResource in unfiltered:
		if u and _unit_unlock_prerequisite_met(u):
			out.append(u)
	return out


func get_all_producible_units() -> Array[UnitStatResource]:
	## Faction-resolved producible roster ignoring tech-gate
	## prerequisites. Used by the HUD to render locked units as
	## greyed-out buttons that show what to build to unlock them,
	## instead of hiding the option entirely.
	if not stats:
		return []
	return _faction_producible_list()


func is_unit_unlocked(u: UnitStatResource) -> bool:
	return _unit_unlock_prerequisite_met(u)


func _faction_producible_list() -> Array[UnitStatResource]:
	var faction_id: int = _resolve_faction_id()
	# 0 = Anvil (default), 1 = Sable per MatchSettingsClass.FactionId.
	if faction_id != 1:
		return stats.producible_units

	# Sable lookup — keyed by building_id. Each entry is a list of
	# resource paths that we lazy-load and resolve to UnitStatResources.
	# Tech gates (Advanced Armory / Black Pylon) are applied by the
	# caller via unit.unlock_prerequisite, so the lists below are the
	# *full* roster — the gate filter hides what the player hasn't
	# unlocked yet.
	var sable_paths: Array[String] = []
	match stats.building_id:
		&"headquarters":
			sable_paths = [
				"res://resources/units/sable_rigger.tres",
				# Crawler is shared across factions for now.
				"res://resources/units/anvil_crawler.tres",
			]
		&"basic_foundry":
			sable_paths = [
				"res://resources/units/sable_specter.tres",
				"res://resources/units/sable_jackal.tres",
			]
		&"advanced_foundry":
			sable_paths = [
				"res://resources/units/sable_harbinger.tres",
				"res://resources/units/sable_courier_tank.tres",
				"res://resources/units/sable_pulsefont.tres",
			]
		&"aerodrome":
			sable_paths = [
				"res://resources/units/sable_switchblade.tres",
				"res://resources/units/sable_fang.tres",
				"res://resources/units/sable_wraith.tres",
			]
		_:
			# Building type without a Sable-specific roster — fall back
			# to the default list (e.g., salvage_yard has no produced
			# units, gun emplacements aren't producers, etc.).
			return stats.producible_units

	var out: Array[UnitStatResource] = []
	for path: String in sable_paths:
		var s: UnitStatResource = load(path) as UnitStatResource
		if s:
			out.append(s)
	# If every Sable path failed to load (file missing, typo) fall back
	# rather than handing the player an empty production menu.
	if out.is_empty():
		return stats.producible_units
	return out


func _unit_unlock_prerequisite_met(u: UnitStatResource) -> bool:
	## True when the owner has met the unit's tech gate. No gate set =
	## always true. The gate is a single building_id — keep it simple,
	## the unit/building tech tree is shallow.
	if not u:
		return true
	var prereq: StringName = u.unlock_prerequisite
	if prereq == &"":
		return true
	# Cheat bypass -- 'techcraze' opens every gate for the local player.
	if owner_id == 0 and _cheats_tech_craze():
		return true
	return _local_player_has_built(prereq)


func _cheats_tech_craze() -> bool:
	var cheats: Node = get_tree().current_scene.get_node_or_null("CheatManager") if get_tree() else null
	if cheats and "tech_craze" in cheats:
		return cheats.get("tech_craze") as bool
	return false


func _apply_sable_building_silhouette() -> void:
	## Layers a faceted angular hull + sensor spires + cyan edge seams
	## over the standard placeholder hull, hiding the original primitive
	## so the Sable building reads as a distinct architectural language
	## (low setbacks, slim antennae, glowing seams) rather than a
	## colour-shifted Anvil structure.
	if not stats or not _visual_root:
		return
	# Hide the standard primitive hull. Keep it parented so the team
	# ring + collision + animations that reference it still resolve.
	if _mesh:
		_mesh.visible = false

	var fs: Vector3 = stats.footprint_size
	var hull_color: Color = _faction_tint_building_chassis(stats.placeholder_color).darkened(0.05)
	var seam_color: Color = Color(0.78, 0.35, 1.0, 1.0)

	# Some buildings have prominent rooftop hardware that needs a clear
	# top (aerodrome's landing pad, SAM's launcher rack). For those we
	# replace the hull with a single full-height base block and skip
	# the mid-setback / top-spine that would otherwise stick up through
	# the rooftop feature.
	var keep_top_clear: bool = (
		stats.building_id == &"aerodrome"
		or stats.building_id == &"sam_site"
	)

	# Stepped main hull — base box (full footprint, ~70% height),
	# narrower middle setback (~80% width, +25% height), then a thin
	# spine block. Reads as a tiered corpo tower instead of a brick.
	var base_block := MeshInstance3D.new()
	var base_box := BoxMesh.new()
	var base_h: float = fs.y if keep_top_clear else fs.y * 0.62
	base_box.size = Vector3(fs.x, base_h, fs.z)
	base_block.mesh = base_box
	base_block.position.y = base_h * 0.5
	base_block.set_surface_override_material(0, _make_sable_hull_mat(hull_color))
	_visual_root.add_child(base_block)

	# Skip the setback + spine entirely for buildings whose roof must
	# stay clear (aerodrome landing pad, SAM launcher rack).
	if not keep_top_clear:
		var mid_block := MeshInstance3D.new()
		var mid_box := BoxMesh.new()
		mid_box.size = Vector3(fs.x * 0.78, fs.y * 0.30, fs.z * 0.78)
		mid_block.mesh = mid_box
		mid_block.position.y = fs.y * 0.62 + fs.y * 0.15
		mid_block.set_surface_override_material(0, _make_sable_hull_mat(hull_color.darkened(0.08)))
		_visual_root.add_child(mid_block)

		var top_spine := MeshInstance3D.new()
		var top_box := BoxMesh.new()
		top_box.size = Vector3(fs.x * 0.32, fs.y * 0.18, fs.z * 0.42)
		top_spine.mesh = top_box
		top_spine.position.y = fs.y * 0.92 + fs.y * 0.09
		top_spine.set_surface_override_material(0, _make_sable_hull_mat(hull_color.darkened(0.15)))
		_visual_root.add_child(top_spine)

	# Forward chevron prow — slim slabs angled at the front face,
	# echoing the Sable mech silhouette so units and structures
	# share design DNA.
	var prow_mat := _make_sable_hull_mat(hull_color.darkened(0.12))
	var prow_l := MeshInstance3D.new()
	var prow_box := BoxMesh.new()
	prow_box.size = Vector3(fs.x * 0.40, fs.y * 0.50, fs.z * 0.30)
	prow_l.mesh = prow_box
	prow_l.position = Vector3(-fs.x * 0.18, fs.y * 0.30, -fs.z * 0.45)
	prow_l.rotation.y = deg_to_rad(20.0)
	prow_l.set_surface_override_material(0, prow_mat)
	_visual_root.add_child(prow_l)
	var prow_r := MeshInstance3D.new()
	prow_r.mesh = prow_box
	prow_r.position = Vector3(fs.x * 0.18, fs.y * 0.30, -fs.z * 0.45)
	prow_r.rotation.y = deg_to_rad(-20.0)
	prow_r.set_surface_override_material(0, prow_mat)
	_visual_root.add_child(prow_r)

	# Vertical glass fins along each side wall — slim emissive blades
	# running floor to ceiling. Sable uses these where Anvil uses
	# concrete pylons; signals "data-corp HQ" vs "industrial bunker".
	var fin_glow_mat := StandardMaterial3D.new()
	fin_glow_mat.albedo_color = Color(0.05, 0.10, 0.15, 1.0)
	fin_glow_mat.emission_enabled = true
	fin_glow_mat.emission = seam_color
	fin_glow_mat.emission_energy_multiplier = 0.65
	fin_glow_mat.metallic = 0.6
	fin_glow_mat.roughness = 0.35
	for fin_side: int in 2:
		var fsx: float = -fs.x * 0.5 - 0.04 if fin_side == 0 else fs.x * 0.5 + 0.04
		for slot: int in 3:
			var slot_z: float = (float(slot) - 1.0) * fs.z * 0.30
			var fin := MeshInstance3D.new()
			var fbox := BoxMesh.new()
			fbox.size = Vector3(0.10, fs.y * 0.85, 0.20)
			fin.mesh = fbox
			fin.position = Vector3(fsx, fs.y * 0.45, slot_z)
			fin.set_surface_override_material(0, fin_glow_mat)
			_visual_root.add_child(fin)

	# Cantilevered upper eave — a thin overhanging slab at the top of
	# the base block. Stronger architectural read than just a setback,
	# and casts a shadow line that distinguishes Sable's silhouette
	# from any Anvil rooftop in any lighting. Skipped for the clear-
	# top buildings so it doesn't slice through their landing pad /
	# launcher rack at mid-height.
	if not keep_top_clear:
		var eave := MeshInstance3D.new()
		var eave_box := BoxMesh.new()
		eave_box.size = Vector3(fs.x * 1.08, 0.08, fs.z * 1.08)
		eave.mesh = eave_box
		eave.position.y = fs.y * 0.62
		eave.set_surface_override_material(0, _make_sable_hull_mat(hull_color.darkened(0.20)))
		_visual_root.add_child(eave)

	# Cyan emissive seams along the edge where each setback meets — a
	# horizontal line at base/mid joint and another at mid/spine joint.
	var seam_mat := StandardMaterial3D.new()
	seam_mat.albedo_color = seam_color
	seam_mat.emission_enabled = true
	seam_mat.emission = seam_color
	seam_mat.emission_energy_multiplier = 2.0
	seam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Seam rings live on the setback joints. With no setbacks (clear-
	# top buildings) we render a single cornice ring at the top of the
	# full-height base block instead of the two-ring pattern.
	var ring_specs: Array[Dictionary]
	if keep_top_clear:
		ring_specs = [
			{ "y": fs.y * 0.97, "w": fs.x, "d": fs.z, "thick": 0.045 },
		]
	else:
		ring_specs = [
			{ "y": fs.y * 0.62, "w": fs.x, "d": fs.z, "thick": 0.045 },
			{ "y": fs.y * 0.92, "w": fs.x * 0.78, "d": fs.z * 0.78, "thick": 0.035 },
		]
	# Buildings whose roof should stay readable (aerodrome's landing
	# strip, SAM's launcher rack) get a DOTTED ring rather than a
	# continuous one — the unbroken cyan strip read as a violet
	# slash framing the entire roof and competed with the type's own
	# detail layer for the eye.
	var dotted: bool = keep_top_clear
	for ring_data: Dictionary in ring_specs:
		var ring_y: float = ring_data["y"] as float
		var ring_w: float = (ring_data["w"] as float) + 0.05
		var ring_d: float = (ring_data["d"] as float) + 0.05
		var thick: float = ring_data["thick"] as float
		if dotted:
			# Replace each edge with 4 short dashes of the same accent
			# colour, evenly spaced. Keeps the Sable read at the edge
			# without painting the whole rim.
			var dash_count: int = 4
			for axis_i: int in 4:
				# axis_i 0,1 = front/back (vary X), 2,3 = sides (vary Z).
				var along_x: bool = axis_i < 2
				var span: float = ring_w if along_x else ring_d
				var fixed: float = ring_d * 0.5 * (1.0 if axis_i == 0 else -1.0) if along_x else ring_w * 0.5 * (1.0 if axis_i == 2 else -1.0)
				for d_i: int in dash_count:
					var t: float = (float(d_i) + 0.5) / float(dash_count)
					var along_pos: float = -span * 0.5 + t * span
					var dash := MeshInstance3D.new()
					var dbox := BoxMesh.new()
					if along_x:
						dbox.size = Vector3(ring_w * 0.10, thick, 0.05)
					else:
						dbox.size = Vector3(0.05, thick, ring_d * 0.10)
					dash.mesh = dbox
					var dpos: Vector3
					if along_x:
						dpos = Vector3(along_pos, ring_y, fixed)
					else:
						dpos = Vector3(fixed, ring_y, along_pos)
					dash.position = dpos
					dash.set_surface_override_material(0, seam_mat)
					_visual_root.add_child(dash)
		else:
			# Continuous ring — four edges of a flat rectangle.
			for edge_data: Dictionary in [
				{ "size": Vector3(ring_w, thick, 0.05), "pos": Vector3(0.0, ring_y, ring_d * 0.5) },
				{ "size": Vector3(ring_w, thick, 0.05), "pos": Vector3(0.0, ring_y, -ring_d * 0.5) },
				{ "size": Vector3(0.05, thick, ring_d), "pos": Vector3(ring_w * 0.5, ring_y, 0.0) },
				{ "size": Vector3(0.05, thick, ring_d), "pos": Vector3(-ring_w * 0.5, ring_y, 0.0) },
			]:
				var edge := MeshInstance3D.new()
				var ebox := BoxMesh.new()
				ebox.size = edge_data["size"] as Vector3
				edge.mesh = ebox
				edge.position = edge_data["pos"] as Vector3
				edge.set_surface_override_material(0, seam_mat)
				_visual_root.add_child(edge)

	# Sensor spires — tall thin antennas off opposing corners of the
	# top spine. Critical Sable silhouette element. Heights scale with
	# building footprint so the HQ towers higher than a generator.
	# Skip for buildings that already have prominent rooftop hardware
	# (HQ command tower + dish, foundry smokestacks, advanced foundry
	# stacks, aerodrome control mast, SAM site missile rack) so the
	# spires don't clip into them.
	if stats.building_id == &"headquarters" \
			or stats.building_id == &"basic_foundry" \
			or stats.building_id == &"advanced_foundry" \
			or stats.building_id == &"aerodrome" \
			or stats.building_id == &"sam_site":
		return
	# Spire size scales with the building footprint so a defensive
	# turret (~3u wide) gets a small whip antenna while a salvage
	# yard (~7u wide) gets a real comm tower. Was a fixed thickness
	# (0.18) that read as a flagpole on the smaller hulls.
	var avg_extent: float = (fs.x + fs.z) * 0.5
	var size_scale: float = clampf(avg_extent / 6.0, 0.45, 1.20)
	var spire_h: float = (fs.y * 1.2 + avg_extent * 0.22) * size_scale
	var spire_thick: float = 0.18 * size_scale
	var tip_w: float = 0.30 * size_scale
	var tip_h: float = 0.16 * size_scale
	for spire_idx: int in 2:
		var spire := MeshInstance3D.new()
		var spire_box := BoxMesh.new()
		spire_box.size = Vector3(spire_thick, spire_h, spire_thick)
		spire.mesh = spire_box
		var sx: float = fs.x * 0.16 if spire_idx == 0 else -fs.x * 0.16
		var sz: float = fs.z * 0.18
		spire.position = Vector3(sx, fs.y * 1.05 + spire_h * 0.5, sz)
		spire.rotation.z = deg_to_rad(-3.0 if spire_idx == 0 else 3.0)
		spire.set_surface_override_material(0, _make_sable_hull_mat(hull_color.darkened(0.35)))
		_visual_root.add_child(spire)
		# Cyan tip light — single pulse point at the spire crown.
		var tip := MeshInstance3D.new()
		var tip_box := BoxMesh.new()
		tip_box.size = Vector3(tip_w, tip_h, tip_w)
		tip.mesh = tip_box
		tip.position = Vector3(0.0, spire_h * 0.5 + tip_h * 0.5, 0.0)
		tip.set_surface_override_material(0, seam_mat)
		spire.add_child(tip)


func _apply_anvil_brutalist_extras() -> void:
	## Layers Soviet/post-industrial architectural elements over the
	## standard Anvil placeholder hull: thick concrete corner pylons, a
	## raised plinth ringing the base, and a crenellated parapet around
	## the rooftop edge. Sable buildings skip this and use the stepped
	## tower silhouette instead, so a Sable structure looks corp-clean
	## while an Anvil structure looks like a poured-concrete fortress.
	if not stats or not _visual_root:
		return
	# Hex-chassis armories get their own hex-aligned brutalist pass --
	# pouring rectangular crenellations / corner pylons around a
	# 6-sided hull reads as a layout bug.
	if stats.building_id == &"basic_armory" or stats.building_id == &"advanced_armory":
		_apply_anvil_brutalist_extras_hex()
		return
	var fs: Vector3 = stats.footprint_size

	# Concrete plinth — a wider, shorter slab at the base of the
	# building. The hull sits on top of it, reading as a poured-concrete
	# foundation pad. Slightly darker than the hull so the seam is
	# visible from any angle.
	var plinth := MeshInstance3D.new()
	var plinth_box := BoxMesh.new()
	plinth_box.size = Vector3(fs.x * 1.10, fs.y * 0.10, fs.z * 1.10)
	plinth.mesh = plinth_box
	plinth.position.y = fs.y * 0.05
	plinth.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
	_attach_visual(plinth)

	# Corner pylons — square iron-clad concrete pillars sitting just
	# OUTSIDE the hull walls (not flush with them — overlapping faces
	# at exactly the wall plane caused z-fighting flicker). The pylons
	# read as the structural skeleton wrapping the building.
	var pylon_color := Color(0.24, 0.22, 0.20)
	var pylon_half_x: float = fs.x * 0.09
	var pylon_half_z: float = fs.z * 0.09
	# Each pylon's outer wall is offset from the hull by the pylon's
	# own half-extent + a hair so its shadow plane never coincides
	# with the hull's.
	for px: int in 2:
		for pz: int in 2:
			var pylon := MeshInstance3D.new()
			var pbox := BoxMesh.new()
			pbox.size = Vector3(fs.x * 0.18, fs.y * 1.02, fs.z * 0.18)
			pylon.mesh = pbox
			var ppx: float = (-fs.x * 0.5 - pylon_half_x - 0.02) if px == 0 else (fs.x * 0.5 + pylon_half_x + 0.02)
			var ppz: float = (-fs.z * 0.5 - pylon_half_z - 0.02) if pz == 0 else (fs.z * 0.5 + pylon_half_z + 0.02)
			pylon.position = Vector3(ppx, fs.y * 0.51, ppz)
			pylon.set_surface_override_material(0, _detail_dark_metal_mat(pylon_color))
			_attach_visual(pylon)
			# Iron strap mid-height — a slim band wrapping the pylon
			# face, reads as a maintenance grip / structural collar.
			var strap := MeshInstance3D.new()
			var sbox := BoxMesh.new()
			sbox.size = Vector3(fs.x * 0.22, 0.10, fs.z * 0.22)
			strap.mesh = sbox
			strap.position = Vector3(ppx, fs.y * 0.42, ppz)
			strap.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.26, 0.20)))
			_attach_visual(strap)

	# Crenellated parapet — small square blocks ringing the roof edge
	# every fixed pitch. Brutalist battlement read.
	var parapet_color := Color(0.22, 0.20, 0.17)
	var perim_pitch: float = 0.85
	# Top + bottom edges along Z
	var x_count: int = maxi(int(fs.x / perim_pitch), 2)
	for i: int in x_count + 1:
		var px2: float = -fs.x * 0.5 + (fs.x / float(x_count)) * float(i)
		for sign: int in 2:
			var pz2: float = fs.z * 0.5 if sign == 0 else -fs.z * 0.5
			var crenel := MeshInstance3D.new()
			var cbox := BoxMesh.new()
			cbox.size = Vector3(0.32, 0.30, 0.22)
			crenel.mesh = cbox
			crenel.position = Vector3(px2, fs.y * 1.02 + 0.15, pz2)
			crenel.set_surface_override_material(0, _detail_dark_metal_mat(parapet_color))
			_attach_visual(crenel)
	var z_count: int = maxi(int(fs.z / perim_pitch), 2)
	for i: int in z_count + 1:
		var pz3: float = -fs.z * 0.5 + (fs.z / float(z_count)) * float(i)
		for sign2: int in 2:
			var px3: float = fs.x * 0.5 if sign2 == 0 else -fs.x * 0.5
			# Skip the corners (already covered by the X-axis pass).
			if i == 0 or i == z_count:
				continue
			var crenel2 := MeshInstance3D.new()
			var cbox2 := BoxMesh.new()
			cbox2.size = Vector3(0.22, 0.30, 0.32)
			crenel2.mesh = cbox2
			crenel2.position = Vector3(px3, fs.y * 1.02 + 0.15, pz3)
			crenel2.set_surface_override_material(0, _detail_dark_metal_mat(parapet_color))
			_attach_visual(crenel2)


func _apply_anvil_brutalist_extras_hex() -> void:
	## Hex-aware brutalist pass for the hex-prism armories. Same
	## visual language as the rectangular variant (plinth + corner
	## pylons + crenellated parapet) but every element is laid out
	## along the hex's 6 faces so the silhouette reads as one
	## consistent fortified shape instead of a hex hull stuck inside
	## a rectangular fortification.
	if not stats or not _visual_root:
		return
	var fs: Vector3 = stats.footprint_size
	var hull_radius: float = fs.x * 0.5

	# Concrete plinth — short hex prism wider than the hull.
	var plinth := MeshInstance3D.new()
	var plinth_hex := CylinderMesh.new()
	plinth_hex.radial_segments = 6
	plinth_hex.top_radius = hull_radius * 1.10
	plinth_hex.bottom_radius = hull_radius * 1.10
	plinth_hex.height = fs.y * 0.10
	plinth.mesh = plinth_hex
	plinth.position.y = fs.y * 0.05
	plinth.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.18, 0.16, 0.14)))
	_attach_visual(plinth)

	# Corner pylons — one tall column at each of the 6 hex corner
	# vertices. Pylons sit slightly outside the hex face line so they
	# read as the structural skeleton wrapping the hull.
	var pylon_color := Color(0.24, 0.22, 0.20)
	var pylon_radius: float = hull_radius * 1.02
	for face_i: int in 6:
		# Corner angles sit between two flat faces. Hex faces in
		# `_apply_placeholder_shape` use a 6-segment cylinder, whose
		# corner vertices sit at angles (PI/6) + face_i*(PI/3).
		var ang: float = (PI / 6.0) + float(face_i) * (PI / 3.0)
		var pylon := MeshInstance3D.new()
		var pbox := BoxMesh.new()
		pbox.size = Vector3(fs.x * 0.16, fs.y * 1.02, fs.x * 0.16)
		pylon.mesh = pbox
		pylon.position = Vector3(sin(ang) * pylon_radius, fs.y * 0.51, cos(ang) * pylon_radius)
		pylon.rotation.y = ang
		pylon.set_surface_override_material(0, _detail_dark_metal_mat(pylon_color))
		_attach_visual(pylon)
		# Iron strap mid-height.
		var strap := MeshInstance3D.new()
		var sbox := BoxMesh.new()
		sbox.size = Vector3(fs.x * 0.20, 0.10, fs.x * 0.20)
		strap.mesh = sbox
		strap.position = Vector3(sin(ang) * pylon_radius, fs.y * 0.42, cos(ang) * pylon_radius)
		strap.rotation.y = ang
		strap.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.32, 0.26, 0.20)))
		_attach_visual(strap)

	# Crenellated parapet — small blocks ringing the hex perimeter at
	# even arc-length intervals. 18 merlons (3 per face) gives enough
	# density to read as a battlement without crowding the silhouette.
	var parapet_color := Color(0.22, 0.20, 0.17)
	const MERLON_COUNT: int = 18
	var parapet_radius: float = hull_radius * 0.96
	for m_i: int in MERLON_COUNT:
		var ang: float = float(m_i) / float(MERLON_COUNT) * TAU
		var crenel := MeshInstance3D.new()
		var cbox := BoxMesh.new()
		cbox.size = Vector3(0.26, 0.30, 0.22)
		crenel.mesh = cbox
		crenel.position = Vector3(sin(ang) * parapet_radius, fs.y * 1.02 + 0.15, cos(ang) * parapet_radius)
		crenel.rotation.y = ang
		crenel.set_surface_override_material(0, _detail_dark_metal_mat(parapet_color))
		_attach_visual(crenel)


func _make_sable_hull_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.albedo_texture = SharedTextures.get_metal_wear_texture()
	m.uv1_offset = Vector3(randf(), randf(), 0.0)
	m.uv1_scale = Vector3(2.5, 2.5, 1.0)
	m.metallic = 0.5
	m.roughness = 0.5
	return m


func _detail_black_pylon() -> void:
	## V3 §Pillar 2 — Sable's Mesh anchor structure. Tall thin
	## obelisk + a stack of antenna rings + a violet pulse-point at
	## the top. Visually unmistakable as "the Mesh node here".
	var fs: Vector3 = stats.footprint_size
	# Central column rising the full height.
	var column := MeshInstance3D.new()
	var col_box := BoxMesh.new()
	col_box.size = Vector3(fs.x * 0.65, fs.y * 0.95, fs.z * 0.65)
	column.mesh = col_box
	column.position.y = fs.y * 0.475
	column.set_surface_override_material(0, _detail_dark_metal_mat(Color(0.10, 0.08, 0.16)))
	_attach_visual(column)
	# Antenna ring stack — three torus-like rings at intervals up
	# the column, each slightly larger than the column's width.
	const SABLE_VIOLET := Color(0.78, 0.35, 1.0, 1.0)
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = SABLE_VIOLET
	ring_mat.emission_enabled = true
	ring_mat.emission = SABLE_VIOLET
	ring_mat.emission_energy_multiplier = 1.2
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for r_i: int in 3:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = fs.x * 0.40
		torus.outer_radius = fs.x * 0.50
		torus.rings = 16
		torus.ring_segments = 6
		ring.mesh = torus
		ring.position.y = fs.y * (0.30 + float(r_i) * 0.22)
		ring.set_surface_override_material(0, ring_mat)
		_attach_visual(ring)
	# Violet pulse-point at the top.
	var pulse := MeshInstance3D.new()
	var pulse_sphere := SphereMesh.new()
	pulse_sphere.radius = 0.22
	pulse_sphere.height = 0.44
	pulse.mesh = pulse_sphere
	pulse.position.y = fs.y + 0.20
	pulse.set_surface_override_material(0, ring_mat)
	_attach_visual(pulse)
	# Glow point so the pylon casts violet onto the surrounding
	# ground — matches the Mesh aura colour.
	var glow := OmniLight3D.new()
	glow.light_color = SABLE_VIOLET
	glow.light_energy = 1.6
	glow.omni_range = 6.0
	glow.position.y = fs.y * 0.6
	_attach_visual(glow)


func _add_mesh_aura_ring(radius: float) -> void:
	## Flat ground ring marking this building's Mesh aura coverage.
	## Always visible to the controlling player; opponents see it
	## only when they have line of sight on the structure.
	var ring := MeshInstance3D.new()
	ring.name = "MeshAuraRing"
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.20
	torus.outer_radius = radius
	torus.rings = 48
	torus.ring_segments = 4
	ring.mesh = torus
	ring.position.y = 0.05
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.45, 1.0, 0.55)
	mat.emission_enabled = true
	mat.emission = Color(0.78, 0.45, 1.0, 1.0)
	mat.emission_energy_multiplier = 0.9
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, mat)
	add_child(ring)


func _local_player_has_built(building_id: StringName) -> bool:
	## True when ANY building owned by this Building's owner has the
	## given building_id and is fully constructed. Used by the
	## faction-aware production list to gate Wraith behind the
	## Black Pylon.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node) or node == self:
			continue
		if "owner_id" in node and (node.get("owner_id") as int) != owner_id:
			continue
		if not node.get("is_constructed"):
			continue
		var b: BuildingStatResource = node.get("stats") as BuildingStatResource
		if b and b.building_id == building_id:
			return true
	return false


func _resolve_faction_id() -> int:
	## Owner 0 (local human) reads MatchSettings.player_faction; any
	## other owner reads MatchSettings.enemy_faction. Returns 0 (Anvil)
	## when MatchSettings isn't loaded — keeps the .tscn-direct test
	## arena working without the autoload.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if not settings:
		return 0
	if owner_id == 0:
		return settings.get("player_faction") as int
	return settings.get("enemy_faction") as int


## Per-role hull tint -- shared with the HUD's role colour palette
## so a Production-orange tooltip header matches the warm wash on
## the building's chassis.
const _BUILDING_ROLE_TINT_PRODUCTION: Color = Color(1.00, 0.55, 0.18, 1.0)
const _BUILDING_ROLE_TINT_TECH: Color       = Color(0.78, 0.45, 1.00, 1.0)
const _BUILDING_ROLE_TINT_DEFENSE: Color    = Color(0.95, 0.30, 0.25, 1.0)
const _BUILDING_ROLE_TINT_POWER: Color      = Color(1.00, 0.95, 0.20, 1.0)
const _BUILDING_ROLE_TINT_ECONOMY: Color    = Color(0.50, 0.92, 0.55, 1.0)
const _BUILDING_ROLE_TINT_COMMAND: Color    = Color(0.85, 0.85, 0.95, 1.0)
## Blend amount for the role tint over the base chassis colour.
## Keep light -- the chassis still needs to read as its faction
## (Anvil tan, Sable black) under the wash; the role tint is a hint,
## not a repaint.
const _ROLE_TINT_BLEND: float = 0.18


func _building_role_color() -> Color:
	if not stats:
		return _BUILDING_ROLE_TINT_COMMAND
	match stats.building_id:
		&"basic_foundry", &"advanced_foundry", &"aerodrome":
			return _BUILDING_ROLE_TINT_PRODUCTION
		&"basic_armory", &"advanced_armory", &"black_pylon":
			return _BUILDING_ROLE_TINT_TECH
		&"gun_emplacement", &"gun_emplacement_basic", &"sam_site":
			return _BUILDING_ROLE_TINT_DEFENSE
		&"basic_generator", &"advanced_generator":
			return _BUILDING_ROLE_TINT_POWER
		&"salvage_yard":
			return _BUILDING_ROLE_TINT_ECONOMY
		&"headquarters":
			return _BUILDING_ROLE_TINT_COMMAND
	return _BUILDING_ROLE_TINT_COMMAND


func _blend_role_tint(base: Color, role: Color) -> Color:
	## Linear blend of role colour over the chassis at _ROLE_TINT_BLEND
	## strength. Preserves alpha from base so transparency-driven
	## construction ghosting still works.
	var b: float = clampf(_ROLE_TINT_BLEND, 0.0, 1.0)
	var out: Color = base.lerp(role, b)
	out.a = base.a
	return out


func _faction_tint_building_chassis(c: Color) -> Color:
	## Anvil keeps its existing palette. Sable shifts the building hull
	## darker + cooler so the corpo cyberpunk specops aesthetic reads
	## even before the cyan accent strip catches the eye. Brightness
	## contrast between buildings (basic_foundry vs salvage_yard etc.)
	## is preserved by re-multiplying the input rather than replacing.
	##
	## Neutral structures (rogue salvager outposts / abandoned ruins,
	## owner_id 2) bypass the faction palette and route to a desaturated
	## rust + grime tint so they read as scrap-cobbled rather than as
	## a "third faction" with its own clean visual language.
	if owner_id == 2:
		return _scrappy_neutral_building_tint(c)
	if _resolve_faction_id() != 1:
		return c
	var avg: float = (c.r + c.g + c.b) / 3.0
	var darkened: float = avg * 0.4  # average building brightness ~0.10-0.18
	return Color(
		darkened * 0.95,
		darkened * 1.0,
		darkened * 1.20,
		c.a,
	)


func _scrappy_neutral_building_tint(c: Color) -> Color:
	## Mirror of unit-side _scrappy_neutral_tint: desaturate, mix toward
	## a warm rust hue, dim brightness. Building-side jitter seeds off
	## the building's spawn position so two ruins on the same map have
	## slightly different rust amounts.
	var avg: float = (c.r + c.g + c.b) / 3.0
	var grey: Color = Color(avg, avg, avg, c.a)
	var rust: Color = Color(0.42, 0.24, 0.16, c.a)
	var jitter: int = int(global_position.x * 11.0 + global_position.z * 5.0) & 0xff
	var rust_mix: float = 0.55 + float(jitter) / 255.0 * 0.20  # 0.55..0.75
	var mixed: Color = grey.lerp(rust, rust_mix)
	mixed.r *= 0.78
	mixed.g *= 0.74
	mixed.b *= 0.72
	mixed.a = c.a
	return mixed


func _process(delta: float) -> void:
	# Construction-progress sampling runs every frame regardless of
	# the cosmetic stagger so the worker count + ETA refresh feels
	# instant when the player adds / removes engineers. Sample window
	# is roughly 0.25s -- cheap, and keeps the displayed rate stable
	# instead of jittering with single-frame contributor lists.
	if not is_constructed:
		var now_msec: int = Time.get_ticks_msec()
		if now_msec - _last_build_tick_time_msec >= 250:
			var window_sec: float = float(now_msec - _last_build_tick_time_msec) * 0.001
			if window_sec > 0.001:
				_build_rate_per_sec = _build_amount_this_tick / window_sec
			_builders_last_tick = _builders_this_tick
			_builders_this_tick = {}
			_build_amount_this_tick = 0.0
			_last_build_tick_time_msec = now_msec
			_update_progress_bar()

	# Half-frame stagger for the cosmetic / damage-VFX work. Buildings
	# don't need 60 Hz redraws — smoke timers, ember flicker, foundry
	# glow loops all read fine at 30 Hz. Phase is set at _enter_tree
	# (instance-id parity) so a base of buildings all running their
	# loops in lockstep doesn't all spike on the same physics frame.
	_process_frame += 1
	if (_process_frame & 1) != _process_phase:
		return
	delta *= 2.0
	# Always-on damage VFX animation, even when nothing is in production.
	_atmos_anim_time += delta
	# Damage smoke — spawn rising sphere puffs at random anchors. Soft,
	# round, and they actually climb instead of bobbing in place.
	if _damage_smoke and _damage_smoke.visible and not _damage_smoke_anchors.is_empty():
		_damage_anim_time += delta
		_damage_smoke_timer -= delta
		if _damage_smoke_timer <= 0.0:
			# Smoke cadence scales with damage stage — light wisps at
			# stage 1, steady plume at stage 2, near-continuous at
			# stage 3. Clamping in case _damage_stage is somehow 0
			# (shouldn't be when the smoke node is visible).
			var s: int = clampi(_damage_stage, 1, 3)
			_damage_smoke_timer = randf_range(_DAMAGE_SMOKE_INTERVAL_MIN[s], _DAMAGE_SMOKE_INTERVAL_MAX[s])
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

	# Aircraft route through scenes/aircraft.tscn (V3 §"Pillar 3"),
	# Crawlers through salvage_crawler.tscn, everything else through
	# the standard unit.tscn. The flag-driven dispatch keeps the spawn
	# path uniform — Aerodromes don't need a special spawn function.
	var scene_path: String = "res://scenes/unit.tscn"
	var is_crawler: bool = false
	var is_aircraft: bool = false
	if "is_aircraft" in actual_stats and actual_stats.is_aircraft:
		scene_path = "res://scenes/aircraft.tscn"
		is_aircraft = true
	elif "is_crawler" in actual_stats and actual_stats.is_crawler:
		scene_path = "res://scenes/salvage_crawler.tscn"
		is_crawler = true

	var unit_scene: PackedScene = load(scene_path) as PackedScene
	var spawned: Node3D = unit_scene.instantiate() as Node3D
	spawned.set("stats", actual_stats)
	spawned.set("owner_id", owner_id)
	if is_crawler:
		spawned.set("resource_manager", resource_manager)

	# Spawn position has to be OUTSIDE the building's NavigationObstacle3D
	# avoidance radius — otherwise the new unit (especially a freshly-
	# queued AI engineer) ends up inside the obstacle and the avoidance
	# system pushes it back continuously, leaving it wedged against the
	# HQ footprint. The fixed `SpawnPoint` marker at local z=6 isn't
	# always far enough for larger footprints (HQ is 6×6 → obstacle
	# radius ~5.9, marker at distance 6, jitter can pull it to 5.1).
	# Computing the spawn distance from the actual footprint guarantees
	# a clean exit lane on every building size.
	var safe_radius: float = maxf(stats.footprint_size.x, stats.footprint_size.z) * 0.65 + 2.2
	# Spawn on the building's RALLY side rather than the .tscn-baked
	# SpawnPoint marker. The marker sits at local +Z (the back face of
	# the building from the map's perspective), which on the player's
	# HQ at world (0,0,+110) was dropping freshly-produced engineers
	# behind the HQ — they then had to path all the way around the
	# obstacle to reach the rally point in front, and frequently got
	# stuck. Spawning toward the rally point keeps the freshly-produced
	# unit inside the same navmesh region as their destination.
	var fwd: Vector3
	var rally_dir: Vector3 = rally_point - global_position
	rally_dir.y = 0.0
	if rally_dir.length_squared() > 0.001:
		fwd = rally_dir.normalized()
	elif _spawn_marker:
		var marker_dir: Vector3 = _spawn_marker.global_position - global_position
		marker_dir.y = 0.0
		if marker_dir.length_squared() > 0.001:
			fwd = marker_dir.normalized()
		else:
			fwd = -global_transform.basis.z
	else:
		fwd = -global_transform.basis.z
	var spawn_pos: Vector3 = global_position + fwd * safe_radius
	# Lateral jitter only (perpendicular to `fwd`) — random radial
	# jitter could pull the spawn back inside the obstacle.
	var lateral: Vector3 = Vector3(-fwd.z, 0.0, fwd.x)
	spawn_pos += lateral * randf_range(-1.0, 1.0)

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
	var max_hp: int = effective_max_hp()
	if current_hp >= max_hp:
		return
	current_hp = mini(max_hp, current_hp + int(ceil(amount)))
	_update_damage_state()


func effective_max_hp() -> int:
	## Per-instance max HP. Returns hp_max_override when set
	## (Anvil HQ Plating upgrade bumps it +25%); otherwise the
	## shared stats.hp. Repair / damaged-state checks read this.
	if hp_max_override > 0:
		return hp_max_override
	if stats:
		return stats.hp
	return 0


func is_damaged() -> bool:
	return is_constructed and stats != null and current_hp < effective_max_hp()


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
		# Building destruction audio — distinct collapse sample (not the
		# unit-death explosion) so the player can hear what kind of loss
		# happened. HQs use the catastrophic huge-explosion bank instead;
		# everything else collapses.
		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio:
			var is_hq: bool = stats and stats.building_id == &"headquarters"
			if is_hq and audio.has_method("play_huge_explosion"):
				audio.play_huge_explosion(global_position)
			elif audio.has_method("play_building_collapse"):
				audio.play_building_collapse(global_position)
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
	## Resolve the 4-stage damage progression and re-apply visuals.
	if not stats:
		return
	var new_stage: int = _compute_damage_stage()
	if new_stage == _damage_stage:
		return
	_damage_stage = new_stage

	# Smoke — lazy-build at stage 1+, visible whenever stage > 0.
	if _damage_stage >= 1 and not _damage_smoke:
		_build_damage_smoke()
	if _damage_smoke:
		_damage_smoke.visible = _damage_stage >= 1

	# Fire / embers — lazy-build at stage 2+. Stage 2 shows a subset of
	# embers; stage 3 shows them all + the OmniLight3D at full strength.
	if _damage_stage >= 2 and not _damage_fire:
		_build_damage_fire()
	if _damage_fire:
		_damage_fire.visible = _damage_stage >= 2
		var visible_count: int = _DAMAGE_EMBER_VISIBLE[_damage_stage]
		for i: int in _damage_embers.size():
			var entry: Dictionary = _damage_embers[i] as Dictionary
			var mesh: MeshInstance3D = entry.get("mesh") as MeshInstance3D
			if is_instance_valid(mesh):
				mesh.visible = i < visible_count
		# Stage 3 cranks the fire light; stage 2 keeps it dim so embers
		# don't flood the building with light when only a handful are
		# burning.
		if _damage_fire_light and is_instance_valid(_damage_fire_light):
			_damage_fire_light.visible = _damage_stage >= 2
			_damage_fire_light.light_energy = 2.5 if _damage_stage >= 3 else 1.0

	# Material darkening — reset to originals, then reapply at the new
	# factor. Cheap because we only touch our own VisualRoot tree.
	_apply_damage_darken(_DAMAGE_DARKEN[_damage_stage])


func _compute_damage_stage() -> int:
	if not stats or current_hp <= 0:
		return 0
	var ratio: float = float(current_hp) / float(maxi(effective_max_hp(), 1))
	if ratio < 0.25:
		return 3
	if ratio < 0.5:
		return 2
	if ratio < 0.75:
		return 1
	return 0


func _apply_damage_darken(factor: float) -> void:
	## Multiply each visual material's albedo by (1 - factor). The first
	## time we touch a material we cache its original albedo so subsequent
	## stage changes (including repair healing) can restore the unmodified
	## value before reapplying — otherwise repeated calls would compound
	## the darkening into pitch black.
	if not _visual_root:
		return
	for mat: StandardMaterial3D in _collect_damageable_materials():
		if not mat:
			continue
		var mid: int = mat.get_instance_id()
		if not _damage_saved_albedo.has(mid):
			_damage_saved_albedo[mid] = mat.albedo_color
		var orig: Color = _damage_saved_albedo[mid] as Color
		var k: float = 1.0 - factor
		mat.albedo_color = Color(orig.r * k, orig.g * k, orig.b * k, orig.a)


func _collect_damageable_materials() -> Array[StandardMaterial3D]:
	var out: Array[StandardMaterial3D] = []
	if not _visual_root:
		return out
	_collect_damageable_materials_recursive(_visual_root, out)
	return out


func _collect_damageable_materials_recursive(node: Node, out: Array[StandardMaterial3D]) -> void:
	# Skip the smoke/fire VFX subtrees so we don't darken our own embers
	# or smoke puffs (which would defeat their visibility).
	if node == _damage_smoke or node == _damage_fire:
		return
	if node is MeshInstance3D:
		var mesh: MeshInstance3D = node as MeshInstance3D
		var mat: StandardMaterial3D = mesh.get_surface_override_material(0) as StandardMaterial3D
		if mat:
			out.append(mat)
	for c: Node in node.get_children():
		_collect_damageable_materials_recursive(c, out)


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
	## Foundry stack smoke + damaged-building smoke → GPU particle.
	## Routes through the central emitter which has SMOKE_AMOUNT
	## particles in its ring buffer; old puffs auto-recycle as new
	## ones come in. No CPU per-particle update.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if not pem:
		return
	# Slightly darker tint than the missile-trail smoke so building
	# stack output reads as oil-fed industrial soot instead of rocket
	# exhaust.
	var drift: Vector3 = Vector3(
		randf_range(-0.2, 0.2),
		randf_range(2.0, 3.2),
		randf_range(-0.2, 0.2),
	)
	pem.emit_smoke(world_pos, drift, Color(0.30, 0.27, 0.24, 0.65))


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
	## A destroyed building drops a SCATTERED debris pile rather than a
	## single huge slab — the previous spawn was a 0.8x footprint x 0.3
	## height box that read as a flat grey rectangle on the ground (and
	## triggered the unit wreck's Apex landmark, which is meant for
	## downed capital mechs, not ruined factories). Now we drop 4-7
	## medium-class wrecks distributed across the building footprint
	## with random rotations + sizes so the silhouette reads as actual
	## collapsed structure with exposed walls and toppled blocks.
	if not stats or stats.cost_salvage <= 0:
		return
	var total_salvage: int = int(stats.cost_salvage * 0.35)
	var fs: Vector3 = stats.footprint_size
	var area: float = fs.x * fs.z
	# More chunks for bigger buildings — keeps each chunk medium-sized
	# regardless of footprint, instead of one monstrous slab.
	var chunk_count: int = clampi(int(area / 12.0) + 3, 4, 7)
	# Distribute salvage. Round so the integer total still adds up
	# correctly even with the per-chunk floor() truncations.
	var per_chunk: int = maxi(int(total_salvage / chunk_count), 1)
	var remainder: int = total_salvage - per_chunk * chunk_count
	var wreck_pos: Vector3 = global_position
	var scene_root: Node = get_tree().current_scene
	for i: int in chunk_count:
		var wreck := Wreck.new()
		var w_value: int = per_chunk + (1 if i < remainder else 0)
		wreck.salvage_value = w_value
		wreck.salvage_remaining = w_value
		# Per-chunk size jitter — most chunks medium (1.4u), a couple
		# bigger pieces (1.9u). Cap below the apex threshold (2.2u)
		# so building debris uses the standard wreck silhouette.
		var base_extent: float = randf_range(1.2, 1.9)
		var chunk_h: float = randf_range(0.35, 0.65)
		wreck.wreck_size = Vector3(
			base_extent,
			chunk_h,
			base_extent * randf_range(0.85, 1.15),
		)
		# Scatter inside the footprint with a small inset so debris
		# stays on the original pad rather than spilling outside.
		var inset: float = 0.7
		var dx: float = randf_range(-fs.x * 0.5 + inset, fs.x * 0.5 - inset)
		var dz: float = randf_range(-fs.z * 0.5 + inset, fs.z * 0.5 - inset)
		scene_root.add_child(wreck)
		wreck.global_position = wreck_pos + Vector3(dx, 0.0, dz)
		# Random Y rotation — handled by Wreck._build_wreck_visuals
		# itself, but explicitly nudging position only matters here.
