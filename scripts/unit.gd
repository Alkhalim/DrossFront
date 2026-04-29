class_name Unit
extends CharacterBody3D
## Base unit controller. Represents a full squad with individual member visuals.

signal arrived
signal selected
signal deselected
signal squad_destroyed
signal member_died(index: int)

@export var stats: UnitStatResource
@export var owner_id: int = 0

const SPEED_MAP: Dictionary = {
	&"static": 0.0, &"very_slow": 3.0, &"slow": 5.0,
	&"moderate": 8.0, &"fast": 12.0, &"very_fast": 16.0,
}
const ARRIVE_THRESHOLD: float = 0.5

var move_target: Vector3 = Vector3.INF
var is_selected: bool = false
var has_move_order: bool = false
var _move_speed: float = 8.0

## How fast the unit's body slews around Y, in lerp factor per second.
## Lower = sluggish (heavies), higher = snappy (lights). Set per-class in _ready.
var _turn_speed: float = 6.0

## Per-member HP.
var member_hp: Array[int] = []
var alive_count: int = 0

## Visual state.
var _member_meshes: Array[Node3D] = []
var _color_shell: MeshInstance3D = null
var _hp_bar: Node3D = null
var _hp_bar_fill: MeshInstance3D = null
var _hp_bar_bg: MeshInstance3D = null
var _anim_time: float = 0.0
## Continuously advancing clock for idle sway (never resets, unlike _anim_time).
var _idle_time: float = 0.0

## Engineer is currently working on a construction site. BuilderComponent toggles
## this; the visual claw animates and emits sparks while it's true.
var is_building: bool = false
var _build_spark_timer: float = 0.0

## SelectionManager flags this true while the mouse is hovering over the unit
## so we can pop up the HP bar even if the unit is at full health.
var hp_bar_hovered: bool = false

## Damage flash.
var _flash_timer: float = 0.0
const FLASH_DURATION: float = 0.12

## Navigation.
var _nav_agent: NavigationAgent3D = null
var _stuck_timer: float = 0.0
var _last_position: Vector3 = Vector3.ZERO

## Player colors.
const PLAYER_COLOR := Color(0.15, 0.45, 0.9, 1.0)
const ENEMY_COLOR := Color(0.85, 0.2, 0.15, 1.0)

## Unit-vector formation offsets per squad size (XZ plane, magnitude ~1).
## Multiplied by each class's formation_spacing in _build_squad_visuals so
## bigger mechs get proportionally wider squads and don't overlap.
const FORMATION_OFFSETS: Dictionary = {
	1: [Vector2.ZERO],
	2: [Vector2(-1.0, 0.0), Vector2(1.0, 0.0)],
	3: [Vector2(-1.0, 0.55), Vector2(1.0, 0.55), Vector2(0.0, -0.85)],
	4: [Vector2(-1.0, 0.85), Vector2(1.0, 0.85), Vector2(-1.0, -0.85), Vector2(1.0, -0.85)],
}

## Mech anatomy per class. All values are sizes/positions in member-local space.
## leg: dimensions of each leg, hip_y: where legs hang from, leg_x: half-spacing of legs.
## torso: dimensions, head: dimensions, head_shape: "box" or "sphere".
## cannon: dimensions of each shoulder weapon, cannon_x: half-spacing of shoulders,
##   cannon_kind: "twin", "single_left", "claw" (engineer tool arm), "none".
## antenna: height (0 = none).
## formation_spacing: distance from squad center to each member (multiplied with FORMATION_OFFSETS).
## turn_speed: rad/s body slew speed (lower = sluggish, higher = snappy).
const CLASS_SHAPES: Dictionary = {
	&"engineer": {
		# Ratchet — small hexapod utility mech. Hull is elongated so three
		# pairs of legs (front, mid, rear) can splay from the chassis sides.
		"leg": Vector3(0.08, 0.55, 0.08), "hip_y": 0.34, "leg_x": 0.14,
		"torso": Vector3(0.42, 0.3, 0.78), "head": Vector3(0.26, 0.22, 0.3), "head_shape": "sphere",
		"cannon": Vector3(0.12, 0.12, 0.38), "cannon_x": 0.23, "cannon_kind": "claw",
		"antenna": 0.0,
		"color": Color(0.5, 0.46, 0.28),
		"formation_spacing": 0.95,
		"turn_speed": 6.0,
		"leg_kind": "spider",
		"torso_lean": 0.0,
	},
	&"light": {
		# Rook — agile biped scout.
		"leg": Vector3(0.11, 0.55, 0.11), "hip_y": 0.55, "leg_x": 0.15,
		"torso": Vector3(0.38, 0.6, 0.38), "head": Vector3(0.24, 0.24, 0.36), "head_shape": "box",
		"cannon": Vector3(0.12, 0.12, 0.45), "cannon_x": 0.28, "cannon_kind": "twin",
		"antenna": 0.5,
		"color": Color(0.32, 0.34, 0.4),
		"formation_spacing": 0.95,
		"turn_speed": 6.5,
		"leg_kind": "biped",
		"torso_lean": 0.0,
	},
	&"medium": {
		# Hound — Sentinel-style: tall chicken legs dominate, larger cockpit on
		# top, single cannon mounted on the right at cockpit height. Red visor.
		"leg": Vector3(0.18, 0.6, 0.18), "hip_y": 1.15, "leg_x": 0.3,
		"torso": Vector3(0.65, 0.6, 0.7), "head": Vector3(0.55, 0.42, 0.6), "head_shape": "box",
		"cannon": Vector3(0.16, 0.16, 0.75), "cannon_x": 0.34, "cannon_kind": "single_right",
		"cannon_mount": "head_top",
		"antenna": 0.5,
		"color": Color(0.38, 0.32, 0.32),
		"formation_spacing": 1.4,
		"turn_speed": 4.0,
		"leg_kind": "chicken",
		"torso_lean": 0.0,
	},
	&"heavy": {
		# Bulwark — walking tank destroyer: low elongated chassis, sloped front
		# armor, single large cannon mounted in the front-center of the hull
		# (no turret). Cylindrical barrel with a muzzle brake. Detail bulges,
		# side skirts, and engine deck make it read as a proper war machine.
		"leg": Vector3(0.28, 0.7, 0.28), "hip_y": 0.7, "leg_x": 0.55,
		"torso": Vector3(1.1, 0.55, 1.7), "head": Vector3(0.5, 0.4, 0.55), "head_shape": "box",
		"cannon": Vector3(0.16, 0.16, 1.05), "cannon_x": 0.0, "cannon_kind": "platform",
		"antenna": 0.3,
		"color": Color(0.42, 0.4, 0.35),
		"formation_spacing": 1.95,
		"turn_speed": 2.0,
		"leg_kind": "quadruped",
		"torso_lean": 0.0,
	},
	&"apex": {
		# Apex titan — huge biped, kept default silhouette.
		"leg": Vector3(0.5, 0.95, 0.5), "hip_y": 0.95, "leg_x": 0.6,
		"torso": Vector3(1.6, 1.6, 1.6), "head": Vector3(0.9, 0.85, 1.0), "head_shape": "box",
		"cannon": Vector3(0.55, 0.6, 1.55), "cannon_x": 1.15, "cannon_kind": "twin",
		"antenna": 0.85,
		"color": Color(0.48, 0.42, 0.35),
		"formation_spacing": 2.4,
		"turn_speed": 1.7,
		"leg_kind": "biped",
		"torso_lean": 0.0,
	},
}

## Per-member animation state. Parallel to _member_meshes.
## Each entry: { legs:[left,right], shoulders:[left,right], cannons:[left,right],
##              torso:Node3D, head:Node3D, mats:Array[StandardMaterial3D],
##              recoil:[float,float], stride_phase: float }
var _member_data: Array[Dictionary] = []

## Walking animation accumulator (synced from velocity).
var _stride_speed: float = 0.0


func _ready() -> void:
	add_to_group("units")
	add_to_group("owner_%d" % owner_id)
	# Navigation agent for pathfinding
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.name = "NavAgent"
	_nav_agent.path_desired_distance = 0.8
	_nav_agent.target_desired_distance = 1.2
	_nav_agent.avoidance_enabled = true
	_nav_agent.radius = 1.5
	_nav_agent.neighbor_distance = 10.0
	_nav_agent.max_neighbors = 8
	_nav_agent.max_speed = 16.0
	add_child(_nav_agent)

	if stats:
		_move_speed = SPEED_MAP.get(stats.speed_tier, 8.0)
		var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
		_turn_speed = shape.get("turn_speed", 6.0) as float
		# Scale avoidance radius with the squad footprint so big mechs don't
		# clip through neighbours.
		var torso_w: float = (shape["torso"] as Vector3).x
		var formation_spacing: float = shape.get("formation_spacing", 1.5) as float
		_nav_agent.radius = formation_spacing + torso_w * 0.5 + 0.2
		_init_hp()
		_build_squad_visuals()
		_build_hp_bar()
		if stats.can_build:
			var builder := BuilderComponent.new()
			builder.name = "BuilderComponent"
			add_child(builder)
		if stats.primary_weapon:
			var combat_script: GDScript = load("res://scripts/combat_component.gd") as GDScript
			var combat: Node = combat_script.new()
			combat.name = "CombatComponent"
			add_child(combat)


func _init_hp() -> void:
	alive_count = stats.squad_size
	member_hp.clear()
	for i: int in stats.squad_size:
		member_hp.append(stats.hp_per_unit)


## --- Squad Visuals ---

func _build_squad_visuals() -> void:
	# Remove old visuals
	for mesh: Node3D in _member_meshes:
		if is_instance_valid(mesh):
			mesh.queue_free()
	_member_meshes.clear()
	_member_data.clear()
	if _color_shell and is_instance_valid(_color_shell):
		_color_shell.queue_free()
		_color_shell = null

	# Remove the scene's default mesh/collision (we replace them)
	var old_mesh: Node = get_node_or_null("MeshInstance3D")
	if old_mesh:
		old_mesh.queue_free()

	var shape_data: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	var team_color: Color = PLAYER_COLOR if owner_id == 0 else ENEMY_COLOR

	var squad: int = stats.squad_size
	var unit_offsets: Array = FORMATION_OFFSETS.get(squad, FORMATION_OFFSETS[1])
	var spacing: float = shape_data.get("formation_spacing", 1.5) as float

	for i: int in squad:
		var u: Vector2 = unit_offsets[i] as Vector2
		var offset := Vector3(u.x * spacing, 0.0, u.y * spacing)
		var member_info: Dictionary = _build_mech_member(i, offset, shape_data, team_color)
		_member_meshes.append(member_info["root"])
		_member_data.append(member_info)

	# Collision shape covers the squad footprint, sized to the actual mech bulk.
	var torso_size: Vector3 = shape_data["torso"] as Vector3
	var hip_y: float = shape_data["hip_y"] as float
	var head_size: Vector3 = shape_data["head"] as Vector3
	var total_h: float = hip_y + torso_size.y + head_size.y
	var col_node: CollisionShape3D = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_node:
		var col_shape := BoxShape3D.new()
		# Footprint = formation extent + one mech's body width, with a small margin.
		var formation_radius: float = spacing if squad > 1 else 0.0
		var squad_width: float = formation_radius * 2.0 + torso_size.x + 0.4
		col_shape.size = Vector3(squad_width, total_h, squad_width)
		col_node.shape = col_shape
		col_node.position.y = total_h / 2.0


func _build_mech_member(index: int, offset: Vector3, shape: Dictionary, team_color: Color) -> Dictionary:
	## Builds one mech member and returns references to its animatable parts.
	var hip_y: float = shape["hip_y"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var head_size: Vector3 = shape["head"] as Vector3
	var head_shape: String = shape["head_shape"] as String
	var cannon_size: Vector3 = shape["cannon"] as Vector3
	var cannon_x: float = shape["cannon_x"] as float
	var cannon_kind: String = shape["cannon_kind"] as String
	var antenna_h: float = shape["antenna"] as float
	var base_color: Color = shape["color"] as Color
	var leg_kind: String = shape.get("leg_kind", "biped") as String
	var torso_lean: float = shape.get("torso_lean", 0.0) as float
	var cannon_mount: String = shape.get("cannon_mount", "shoulder") as String
	var trim_color: Color = Color(base_color.r + 0.06, base_color.g + 0.06, base_color.b + 0.06, 1.0)

	var member := Node3D.new()
	member.name = "Member_%d" % index
	member.position = offset
	add_child(member)

	var mats: Array[StandardMaterial3D] = []

	# --- Legs (per-class skeleton) ---
	var leg_info: Dictionary = _build_legs(member, shape, mats, leg_kind)
	var legs: Array = leg_info["legs"] as Array
	var leg_phases: Array = leg_info["phases"] as Array

	# --- Torso ---
	# Torso pivot lets the Hound lean forward without skewing the legs.
	var torso_pivot := Node3D.new()
	torso_pivot.name = "TorsoPivot"
	torso_pivot.position.y = hip_y
	torso_pivot.rotation.x = -torso_lean  # negative X rotation tips the upper body forward
	member.add_child(torso_pivot)

	var torso := MeshInstance3D.new()
	var torso_box := BoxMesh.new()
	torso_box.size = torso_size
	torso.mesh = torso_box
	torso.position.y = torso_size.y / 2.0
	var torso_mat := _make_metal_mat(base_color)
	torso.set_surface_override_material(0, torso_mat)
	torso_pivot.add_child(torso)
	mats.append(torso_mat)

	# Team-color stripe across torso (emissive so it pops)
	var stripe := MeshInstance3D.new()
	var stripe_box := BoxMesh.new()
	stripe_box.size = Vector3(torso_size.x + 0.02, torso_size.y * 0.18, torso_size.z + 0.02)
	stripe.mesh = stripe_box
	# Position is in torso_pivot's local space (which already sits at hip_y).
	stripe.position.y = torso_size.y * 0.65
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = team_color
	stripe_mat.emission_enabled = true
	stripe_mat.emission = team_color
	stripe_mat.emission_energy_multiplier = 1.4
	stripe_mat.roughness = 0.6
	stripe.set_surface_override_material(0, stripe_mat)
	torso_pivot.add_child(stripe)
	mats.append(stripe_mat)

	# --- Surface details (chest grille + back vent) on every mech that doesn't
	# already have its own elaborate hull (the Bulwark platform builds its own).
	if cannon_kind != "platform":
		_add_chassis_panels(torso_pivot, torso_size, mats)

	# --- Head / Cockpit ---
	# Sentinel-style mechs (Hound) keep the cockpit centered above the legs.
	var head_fwd_offset: float = 0.0
	var head: MeshInstance3D = MeshInstance3D.new()
	if head_shape == "sphere":
		var sph := SphereMesh.new()
		sph.radius = head_size.x * 0.5
		sph.height = head_size.y
		head.mesh = sph
	else:
		var hbox := BoxMesh.new()
		hbox.size = head_size
		head.mesh = hbox
	head.position = Vector3(0, torso_size.y + head_size.y / 2.0, head_fwd_offset)
	var head_mat := _make_metal_mat(trim_color)
	head.set_surface_override_material(0, head_mat)
	torso_pivot.add_child(head)
	mats.append(head_mat)

	# Cockpit visor — small emissive band on the FRONT of the head (-Z is forward).
	var visor := MeshInstance3D.new()
	var visor_box := BoxMesh.new()
	visor_box.size = Vector3(head_size.x * 0.85, head_size.y * 0.25, head_size.z * 0.05)
	visor.mesh = visor_box
	visor.position = Vector3(0, torso_size.y + head_size.y * 0.55, head_fwd_offset - head_size.z * 0.5 - 0.005)
	var visor_mat := StandardMaterial3D.new()
	# Hound's visor glows red (mean look); everyone else gets the standard cyan.
	if leg_kind == "chicken":
		visor_mat.albedo_color = Color(0.9, 0.15, 0.1)
		visor_mat.emission = Color(1.0, 0.2, 0.1)
	else:
		visor_mat.albedo_color = Color(0.05, 0.6, 0.9)
		visor_mat.emission = Color(0.2, 0.8, 1.0)
	visor_mat.emission_enabled = true
	visor_mat.emission_energy_multiplier = 1.6
	visor.set_surface_override_material(0, visor_mat)
	torso_pivot.add_child(visor)
	mats.append(visor_mat)

	# --- Shoulders / Cannons ---
	var shoulders: Array[Node3D] = []
	var cannons: Array[Node3D] = []
	# Parallel to `cannons` — captures each pivot's rest z so recoil can be
	# applied as an additive offset (the Bulwark hull-mounted gun sits at the
	# chassis front, not at z=0).
	var cannon_rest_z: Array = []

	if cannon_kind == "platform":
		# Bulwark — tank-destroyer hull. Cannon is mounted in the center of
		# the chassis (no turret), emerging from a casemate mantlet at the
		# front. Sloped glacis on top, side skirts, and an engine deck on the
		# rear top break up the silhouette into a proper war machine.
		var darker: Color = Color(base_color.r * 0.78, base_color.g * 0.78, base_color.b * 0.82)
		var trim_dark: Color = Color(base_color.r * 0.6, base_color.g * 0.6, base_color.b * 0.65)

		# Sloped glacis (front armor plate) — a wedge-like rotated box.
		var glacis_size := Vector3(torso_size.x * 0.95, torso_size.y * 0.55, torso_size.z * 0.45)
		var glacis := MeshInstance3D.new()
		var glacis_box := BoxMesh.new()
		glacis_box.size = glacis_size
		glacis.mesh = glacis_box
		glacis.rotation.x = -0.45
		glacis.position = Vector3(0, torso_size.y * 0.85, -torso_size.z * 0.32)
		var glacis_mat := _make_metal_mat(Color(base_color.r * 0.95, base_color.g * 0.95, base_color.b * 0.95))
		glacis.set_surface_override_material(0, glacis_mat)
		torso_pivot.add_child(glacis)
		mats.append(glacis_mat)

		# Engine deck on the rear top — a low raised box with grille slats.
		var deck_size := Vector3(torso_size.x * 0.7, torso_size.y * 0.25, torso_size.z * 0.55)
		var deck := MeshInstance3D.new()
		var deck_box := BoxMesh.new()
		deck_box.size = deck_size
		deck.mesh = deck_box
		deck.position = Vector3(0, torso_size.y + deck_size.y * 0.5, torso_size.z * 0.28)
		var deck_mat := _make_metal_mat(darker)
		deck.set_surface_override_material(0, deck_mat)
		torso_pivot.add_child(deck)
		mats.append(deck_mat)

		# Three thin grille slats on the engine deck — purely decorative detail.
		for slat_i: int in 3:
			var slat := MeshInstance3D.new()
			var slat_box := BoxMesh.new()
			slat_box.size = Vector3(deck_size.x * 0.85, 0.04, 0.06)
			slat.mesh = slat_box
			var sz: float = torso_size.z * 0.28 + (float(slat_i) - 1.0) * 0.18
			slat.position = Vector3(0, torso_size.y + deck_size.y + 0.025, sz)
			var slat_mat := _make_metal_mat(Color(0.1, 0.1, 0.1))
			slat.set_surface_override_material(0, slat_mat)
			torso_pivot.add_child(slat)
			mats.append(slat_mat)

		# Side skirts — armor panels along each side, hide the leg-hip area.
		for side: int in 2:
			var sx: float = -torso_size.x * 0.5 - 0.02 if side == 0 else torso_size.x * 0.5 + 0.02
			var skirt := MeshInstance3D.new()
			var skirt_box := BoxMesh.new()
			skirt_box.size = Vector3(0.06, torso_size.y * 0.85, torso_size.z * 0.85)
			skirt.mesh = skirt_box
			skirt.position = Vector3(sx, torso_size.y * 0.4, 0)
			var skirt_mat := _make_metal_mat(trim_dark)
			skirt.set_surface_override_material(0, skirt_mat)
			torso_pivot.add_child(skirt)
			mats.append(skirt_mat)

		# Cupola / commander's hatch — small box on top, slightly behind the gun.
		var cupola := MeshInstance3D.new()
		var cup_box := BoxMesh.new()
		cup_box.size = Vector3(0.3, 0.18, 0.32)
		cupola.mesh = cup_box
		cupola.position = Vector3(torso_size.x * 0.18, torso_size.y + 0.09, torso_size.z * 0.12)
		var cup_mat := _make_metal_mat(darker)
		cupola.set_surface_override_material(0, cup_mat)
		torso_pivot.add_child(cupola)
		mats.append(cup_mat)

		# Tiny visor slit on the cupola.
		var cup_slit := MeshInstance3D.new()
		var cup_slit_box := BoxMesh.new()
		cup_slit_box.size = Vector3(0.22, 0.04, 0.02)
		cup_slit.mesh = cup_slit_box
		cup_slit.position = Vector3(torso_size.x * 0.18, torso_size.y + 0.13, torso_size.z * 0.12 - 0.16)
		var cup_slit_mat := StandardMaterial3D.new()
		cup_slit_mat.albedo_color = Color(0.05, 0.6, 0.9)
		cup_slit_mat.emission_enabled = true
		cup_slit_mat.emission = Color(0.2, 0.8, 1.0)
		cup_slit_mat.emission_energy_multiplier = 1.3
		cup_slit.set_surface_override_material(0, cup_slit_mat)
		torso_pivot.add_child(cup_slit)
		mats.append(cup_slit_mat)

		# --- Casemate gun mounted center-front ---
		var gun_y: float = torso_size.y * 0.55
		var front_z: float = -torso_size.z * 0.5

		# Mantlet — armored ball housing where barrel meets the chassis front.
		var mantlet_radius: float = cannon_size.x * 2.4
		var mantlet := MeshInstance3D.new()
		var mantlet_mesh := SphereMesh.new()
		mantlet_mesh.radius = mantlet_radius
		mantlet_mesh.height = mantlet_radius * 1.9
		mantlet.mesh = mantlet_mesh
		mantlet.position = Vector3(0, gun_y, front_z + 0.05)
		var mantlet_mat := _make_metal_mat(base_color)
		mantlet.set_surface_override_material(0, mantlet_mat)
		torso_pivot.add_child(mantlet)
		mats.append(mantlet_mat)

		# Cannon pivot — recoil animates this back along +Z.
		var cannon_pivot := Node3D.new()
		cannon_pivot.name = "CannonPivot_top"
		cannon_pivot.position = Vector3(0, gun_y, front_z - 0.05)
		torso_pivot.add_child(cannon_pivot)

		# Cylindrical main barrel — round, not boxy. CylinderMesh defaults to
		# Y axis; rotate -PI/2 around X so its length aligns with -Z (forward).
		var barrel_len: float = cannon_size.z
		var barrel := MeshInstance3D.new()
		var barrel_cyl := CylinderMesh.new()
		barrel_cyl.top_radius = cannon_size.x
		barrel_cyl.bottom_radius = cannon_size.x * 1.05
		barrel_cyl.height = barrel_len
		barrel.mesh = barrel_cyl
		barrel.rotation.x = -PI / 2
		barrel.position.z = -barrel_len * 0.5
		var barrel_mat := _make_metal_mat(trim_dark)
		barrel.set_surface_override_material(0, barrel_mat)
		cannon_pivot.add_child(barrel)
		mats.append(barrel_mat)

		# Recoil sleeve — slightly wider cylinder near the breech end. Adds
		# a "rifled" or "fume-extractor" look so the barrel isn't a single tube.
		var sleeve_len: float = barrel_len * 0.22
		var sleeve := MeshInstance3D.new()
		var sleeve_cyl := CylinderMesh.new()
		sleeve_cyl.top_radius = cannon_size.x * 1.25
		sleeve_cyl.bottom_radius = cannon_size.x * 1.25
		sleeve_cyl.height = sleeve_len
		sleeve.mesh = sleeve_cyl
		sleeve.rotation.x = -PI / 2
		sleeve.position.z = -barrel_len * 0.55
		var sleeve_mat := _make_metal_mat(darker)
		sleeve.set_surface_override_material(0, sleeve_mat)
		cannon_pivot.add_child(sleeve)
		mats.append(sleeve_mat)

		# Muzzle brake — short, slightly fatter cylinder at the tip.
		var muzzle := MeshInstance3D.new()
		var muzzle_cyl := CylinderMesh.new()
		muzzle_cyl.top_radius = cannon_size.x * 1.4
		muzzle_cyl.bottom_radius = cannon_size.x * 1.25
		muzzle_cyl.height = 0.15
		muzzle.mesh = muzzle_cyl
		muzzle.rotation.x = -PI / 2
		muzzle.position.z = -barrel_len - 0.07
		var muzzle_mat := _make_metal_mat(Color(0.1, 0.1, 0.1))
		muzzle.set_surface_override_material(0, muzzle_mat)
		cannon_pivot.add_child(muzzle)
		mats.append(muzzle_mat)

		shoulders.append(mantlet)
		cannons.append(cannon_pivot)
		cannon_rest_z.append(cannon_pivot.position.z)
	elif cannon_kind != "none":
		# Sentinel-style mounts cannons at the cockpit (top of head); standard
		# bipeds mount them on the torso shoulders.
		var arm_y: float = torso_size.y * 0.7
		if cannon_mount == "head_top":
			arm_y = torso_size.y + head_size.y * 0.5
		var sides: Array[int] = [0, 1]
		if cannon_kind == "single_left" or cannon_kind == "claw":
			sides = [0]
		elif cannon_kind == "single_right":
			sides = [1]
		for side: int in sides:
			var sx: float = -(cannon_x) if side == 0 else cannon_x
			# Shoulder pad
			var shoulder := MeshInstance3D.new()
			var shoulder_box := BoxMesh.new()
			shoulder_box.size = Vector3(torso_size.x * 0.3, torso_size.y * 0.35, torso_size.z * 0.45)
			shoulder.mesh = shoulder_box
			shoulder.position = Vector3(sx, arm_y, 0)
			var shoulder_mat := _make_metal_mat(base_color)
			shoulder.set_surface_override_material(0, shoulder_mat)
			torso_pivot.add_child(shoulder)
			mats.append(shoulder_mat)

			# Cannon pivot animates Z for recoil.
			var cannon_pivot := Node3D.new()
			cannon_pivot.name = "CannonPivot_%d" % side
			cannon_pivot.position = Vector3(sx, arm_y, 0)
			torso_pivot.add_child(cannon_pivot)

			if cannon_kind == "claw":
				# Engineer tool arm: forearm + claw fingers.
				var forearm := MeshInstance3D.new()
				var fb := BoxMesh.new()
				fb.size = Vector3(0.15, 0.15, cannon_size.z)
				forearm.mesh = fb
				forearm.position.z = -cannon_size.z * 0.5
				var forearm_mat := _make_metal_mat(trim_color)
				forearm.set_surface_override_material(0, forearm_mat)
				cannon_pivot.add_child(forearm)
				mats.append(forearm_mat)

				for finger_side: int in 2:
					var fy: float = -0.06 if finger_side == 0 else 0.06
					var finger := MeshInstance3D.new()
					var fingbox := BoxMesh.new()
					fingbox.size = Vector3(0.06, 0.06, 0.18)
					finger.mesh = fingbox
					finger.position = Vector3(0, fy, -cannon_size.z - 0.08)
					var finger_mat := _make_metal_mat(Color(0.7, 0.55, 0.15))
					finger.set_surface_override_material(0, finger_mat)
					cannon_pivot.add_child(finger)
					mats.append(finger_mat)
			else:
				# Cannon barrel — muzzle at -cannon_size.z.
				var barrel := MeshInstance3D.new()
				var bbox := BoxMesh.new()
				bbox.size = cannon_size
				barrel.mesh = bbox
				barrel.position.z = -cannon_size.z * 0.5
				var barrel_mat := _make_metal_mat(Color(base_color.r * 0.6, base_color.g * 0.6, base_color.b * 0.65))
				barrel.set_surface_override_material(0, barrel_mat)
				cannon_pivot.add_child(barrel)
				mats.append(barrel_mat)

				var muzzle := MeshInstance3D.new()
				var mbox := BoxMesh.new()
				mbox.size = Vector3(cannon_size.x * 1.25, cannon_size.y * 1.25, 0.1)
				muzzle.mesh = mbox
				muzzle.position.z = -cannon_size.z - 0.02
				var muzzle_mat := _make_metal_mat(Color(0.15, 0.15, 0.15))
				muzzle.set_surface_override_material(0, muzzle_mat)
				cannon_pivot.add_child(muzzle)
				mats.append(muzzle_mat)

			shoulders.append(shoulder)
			cannons.append(cannon_pivot)
			cannon_rest_z.append(cannon_pivot.position.z)

			# Shoulder pauldron cap — small angled plate atop each shoulder.
			var pauldron := MeshInstance3D.new()
			var pauldron_box := BoxMesh.new()
			pauldron_box.size = Vector3(torso_size.x * 0.34, torso_size.y * 0.12, torso_size.z * 0.5)
			pauldron.mesh = pauldron_box
			pauldron.position = Vector3(sx, arm_y + torso_size.y * 0.2, 0)
			pauldron.rotation.z = -0.18 if side == 0 else 0.18
			var pauldron_mat := _make_metal_mat(Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85))
			pauldron.set_surface_override_material(0, pauldron_mat)
			torso_pivot.add_child(pauldron)
			mats.append(pauldron_mat)

	# --- Class-specific extras (back armor, engine mount, etc.) ---
	if stats:
		_add_class_extras(torso_pivot, torso_size, head_size, mats, base_color, stats.unit_class)

	# --- Antenna ---
	if antenna_h > 0.01:
		var antenna := MeshInstance3D.new()
		var ant_box := BoxMesh.new()
		ant_box.size = Vector3(0.04, antenna_h, 0.04)
		antenna.mesh = ant_box
		antenna.position = Vector3(head_size.x * 0.3, torso_size.y + head_size.y + antenna_h / 2.0, head_fwd_offset)
		var ant_mat := _make_metal_mat(Color(0.15, 0.15, 0.18))
		antenna.set_surface_override_material(0, ant_mat)
		torso_pivot.add_child(antenna)
		mats.append(ant_mat)

		var tip := MeshInstance3D.new()
		var tip_sph := SphereMesh.new()
		tip_sph.radius = 0.05
		tip_sph.height = 0.1
		tip.mesh = tip_sph
		tip.position = Vector3(head_size.x * 0.3, torso_size.y + head_size.y + antenna_h, head_fwd_offset)
		var tip_mat := StandardMaterial3D.new()
		tip_mat.albedo_color = Color(1.0, 0.3, 0.2)
		tip_mat.emission_enabled = true
		tip_mat.emission = Color(1.0, 0.3, 0.2)
		tip_mat.emission_energy_multiplier = 2.0
		tip.set_surface_override_material(0, tip_mat)
		torso_pivot.add_child(tip)
		mats.append(tip_mat)

	# Per-member gait variation so a squad doesn't goose-step in lockstep.
	# Each mech has its own phase, slightly different stride speed, swing
	# amplitude, and torso bob amount — same skeleton, individual feel.
	return {
		"root": member,
		"legs": legs,
		"leg_phases": leg_phases,
		"shoulders": shoulders,
		"cannons": cannons,
		"cannon_rest_z": cannon_rest_z,
		"torso": torso,
		"head": head,
		"mats": mats,
		"recoil": [0.0, 0.0],
		"stride_phase": randf_range(0.0, TAU),
		"stride_speed": randf_range(0.85, 1.18),
		"stride_swing": randf_range(0.36, 0.55),
		"bob_amount": randf_range(0.05, 0.09),
		"idle_phase": randf_range(0.0, TAU),
		"idle_speed": randf_range(0.6, 1.0),
	}


func _build_legs(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D], kind: String) -> Dictionary:
	## Dispatches to one of several skeletons. Each helper builds its meshes
	## under `member`, registers their materials in `mats`, and returns the
	## list of pivot Node3Ds (rotated around X for swing) plus a parallel
	## list of phase offsets so the walk animation knows when each leg should
	## be at the front/back of its stride.
	match kind:
		"chicken": return _build_legs_chicken(member, shape, mats)
		"spider": return _build_legs_spider(member, shape, mats)
		"quadruped": return _build_legs_quadruped(member, shape, mats)
		_: return _build_legs_biped(member, shape, mats)


func _build_legs_biped(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var leg_x: float = shape["leg_x"] as float
	var base_color: Color = shape["color"] as Color

	var legs: Array[Node3D] = []
	for side: int in 2:
		var sx: float = -leg_x if side == 0 else leg_x
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % side
		pivot.position = Vector3(sx, hip_y, 0)
		member.add_child(pivot)
		_attach_leg_segment(pivot, leg_size, base_color, mats, true)
		legs.append(pivot)

	return { "legs": legs, "phases": [0.0, PI] }


func _build_legs_chicken(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	## Reverse-jointed legs: thigh pitches forward, shin angles back so the
	## knee points forward and the foot lands roughly under the body.
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var leg_x: float = shape["leg_x"] as float
	var base_color: Color = shape["color"] as Color
	# Sized so the bent leg's vertical projection reaches the ground:
	# thigh tilts +0.55 (cos 0.85), shin tilts back so its world angle is -0.45 (cos 0.90).
	# 2 segments × hip_y × 0.58 × 1.75 ≈ hip_y, with a tiny embed for visual contact.
	var thigh_len: float = hip_y * 0.58
	var shin_len: float = hip_y * 0.58
	var thigh_size := Vector3(leg_size.x, thigh_len, leg_size.z)
	var shin_size := Vector3(leg_size.x * 0.85, shin_len, leg_size.z * 0.85)

	var legs: Array[Node3D] = []
	for side: int in 2:
		var sx: float = -leg_x if side == 0 else leg_x
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % side
		pivot.position = Vector3(sx, hip_y, 0)
		member.add_child(pivot)

		# Thigh tilts forward (knee in front of hip).
		var thigh_rot := Node3D.new()
		thigh_rot.rotation.x = 0.55
		pivot.add_child(thigh_rot)

		var thigh_mesh := MeshInstance3D.new()
		var thigh_box := BoxMesh.new()
		thigh_box.size = thigh_size
		thigh_mesh.mesh = thigh_box
		thigh_mesh.position.y = -thigh_len / 2.0
		var thigh_mat := _make_metal_mat(base_color)
		thigh_mesh.set_surface_override_material(0, thigh_mat)
		thigh_rot.add_child(thigh_mesh)
		mats.append(thigh_mat)

		# Knee node sits at the bottom of the thigh.
		var knee := Node3D.new()
		knee.position.y = -thigh_len
		thigh_rot.add_child(knee)

		# Shin tilts back so the foot ends up roughly under the hip.
		var shin_rot := Node3D.new()
		shin_rot.rotation.x = -1.0
		knee.add_child(shin_rot)

		var shin_mesh := MeshInstance3D.new()
		var shin_box := BoxMesh.new()
		shin_box.size = shin_size
		shin_mesh.mesh = shin_box
		shin_mesh.position.y = -shin_len / 2.0
		var shin_mat := _make_metal_mat(base_color)
		shin_mesh.set_surface_override_material(0, shin_mat)
		shin_rot.add_child(shin_mesh)
		mats.append(shin_mat)

		# Forward-extending foot — chicken style talons.
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(leg_size.x * 1.1, 0.08, leg_size.z * 2.4)
		foot.mesh = foot_box
		foot.position = Vector3(0, -shin_len - 0.04, leg_size.z * 0.5)
		var foot_mat := _make_metal_mat(Color(base_color.r * 0.65, base_color.g * 0.65, base_color.b * 0.65))
		foot.set_surface_override_material(0, foot_mat)
		shin_rot.add_child(foot)
		mats.append(foot_mat)

		legs.append(pivot)

	return { "legs": legs, "phases": [0.0, PI] }


func _build_legs_spider(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	## Six legs in left/right pairs along the chassis sides — fore, mid, rear.
	## Each leg sticks out laterally and bends down to a foot pad. Alternating
	## tripod gait: tripod A (front-left, mid-right, rear-left) swings, then
	## tripod B (front-right, mid-left, rear-right).
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var base_color: Color = shape["color"] as Color
	var trim_color: Color = Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85)

	var anchor_y: float = hip_y + torso_size.y * 0.45
	var anchor_x: float = torso_size.x * 0.5 + 0.04
	# Spread three pairs evenly along the hull's length.
	var anchor_z_front: float = torso_size.z * 0.36
	var anchor_z_mid: float = 0.0
	var anchor_z_rear: float = -torso_size.z * 0.36

	var corners: Array[Vector2] = [
		Vector2(-anchor_x, anchor_z_front),    # 0 front-left
		Vector2(anchor_x, anchor_z_front),     # 1 front-right
		Vector2(-anchor_x, anchor_z_mid),      # 2 mid-left
		Vector2(anchor_x, anchor_z_mid),       # 3 mid-right
		Vector2(-anchor_x, anchor_z_rear),     # 4 rear-left
		Vector2(anchor_x, anchor_z_rear),      # 5 rear-right
	]
	var splay_z: float = 0.7

	var legs: Array[Node3D] = []
	for i: int in corners.size():
		var c: Vector2 = corners[i]
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % i
		pivot.position = Vector3(c.x, anchor_y, c.y)
		# Lean each leg outward. Right-side legs use +θ, left-side use -θ.
		pivot.rotation.z = splay_z if c.x > 0.0 else -splay_z
		member.add_child(pivot)

		# Hip-cap detail — small dark stub where the leg joins the chassis.
		var hip_cap := MeshInstance3D.new()
		var hip_box := BoxMesh.new()
		hip_box.size = Vector3(leg_size.x * 1.6, leg_size.y * 0.18, leg_size.z * 1.6)
		hip_cap.mesh = hip_box
		hip_cap.position.y = -leg_size.y * 0.04
		var hip_mat := _make_metal_mat(trim_color)
		hip_cap.set_surface_override_material(0, hip_mat)
		pivot.add_child(hip_cap)
		mats.append(hip_mat)

		# Main leg shaft.
		var leg_mesh := MeshInstance3D.new()
		var leg_box := BoxMesh.new()
		leg_box.size = leg_size
		leg_mesh.mesh = leg_box
		leg_mesh.position.y = -leg_size.y / 2.0
		var leg_mat := _make_metal_mat(base_color)
		leg_mesh.set_surface_override_material(0, leg_mat)
		pivot.add_child(leg_mesh)
		mats.append(leg_mat)

		# Tip claw — wider, darker foot pad at the leg's end.
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(leg_size.x * 1.6, 0.07, leg_size.z * 2.0)
		foot.mesh = foot_box
		foot.position.y = -leg_size.y - 0.035
		var foot_mat := _make_metal_mat(Color(0.12, 0.12, 0.12))
		foot.set_surface_override_material(0, foot_mat)
		pivot.add_child(foot)
		mats.append(foot_mat)

		legs.append(pivot)

	# Alternating-tripod gait: FL, MR, RL move together (phase 0); FR, ML, RR at PI.
	return { "legs": legs, "phases": [0.0, PI, PI, 0.0, 0.0, PI] }


func _build_legs_quadruped(member: Node3D, shape: Dictionary, mats: Array[StandardMaterial3D]) -> Dictionary:
	## Four sturdy legs at the corners of the torso footprint. Trot gait —
	## diagonal pairs swing together.
	var leg_size: Vector3 = shape["leg"] as Vector3
	var hip_y: float = shape["hip_y"] as float
	var leg_x: float = shape["leg_x"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var base_color: Color = shape["color"] as Color
	# Front legs slightly forward, rear legs slightly back.
	var leg_z: float = torso_size.z * 0.4
	var corners: Array[Vector2] = [
		Vector2(-leg_x, leg_z),    # front-left
		Vector2(leg_x, leg_z),     # front-right
		Vector2(-leg_x, -leg_z),   # rear-left
		Vector2(leg_x, -leg_z),    # rear-right
	]

	var legs: Array[Node3D] = []
	for i: int in corners.size():
		var c: Vector2 = corners[i]
		var pivot := Node3D.new()
		pivot.name = "LegPivot_%d" % i
		pivot.position = Vector3(c.x, hip_y, c.y)
		member.add_child(pivot)
		_attach_leg_segment(pivot, leg_size, base_color, mats, true)
		legs.append(pivot)

	# Trot: front-left + rear-right swing together (phase 0); other pair at PI.
	return { "legs": legs, "phases": [0.0, PI, PI, 0.0] }


func _attach_leg_segment(parent: Node3D, leg_size: Vector3, base_color: Color, mats: Array[StandardMaterial3D], with_foot: bool) -> void:
	var leg_mesh := MeshInstance3D.new()
	var leg_box := BoxMesh.new()
	leg_box.size = leg_size
	leg_mesh.mesh = leg_box
	leg_mesh.position.y = -leg_size.y / 2.0
	var leg_mat := _make_metal_mat(base_color)
	leg_mesh.set_surface_override_material(0, leg_mat)
	parent.add_child(leg_mesh)
	mats.append(leg_mat)

	if with_foot:
		var foot := MeshInstance3D.new()
		var foot_box := BoxMesh.new()
		foot_box.size = Vector3(leg_size.x * 1.4, 0.08, leg_size.z * 1.6)
		foot.mesh = foot_box
		foot.position.y = -leg_size.y - 0.04
		var foot_mat := _make_metal_mat(Color(base_color.r * 0.7, base_color.g * 0.7, base_color.b * 0.7))
		foot.set_surface_override_material(0, foot_mat)
		parent.add_child(foot)
		mats.append(foot_mat)


func _make_metal_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.55
	m.metallic = 0.45
	return m


func _add_class_extras(torso_pivot: Node3D, torso_size: Vector3, head_size: Vector3, mats: Array[StandardMaterial3D], base_color: Color, unit_class: StringName) -> void:
	## Class-specific decorative pieces — gives each mech a recognisable
	## silhouette beyond the shared chassis grille and back vent.
	match unit_class:
		&"light":
			# Rook backpack — small box on the upper rear of the torso.
			var pack := MeshInstance3D.new()
			var pack_box := BoxMesh.new()
			pack_box.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.4, torso_size.z * 0.25)
			pack.mesh = pack_box
			pack.position = Vector3(0, torso_size.y * 0.55, torso_size.z * 0.5 + pack_box.size.z * 0.5)
			var pack_mat := _make_metal_mat(Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85))
			pack.set_surface_override_material(0, pack_mat)
			torso_pivot.add_child(pack)
			mats.append(pack_mat)
		&"medium":
			# Hound — cockpit door frame on the front of the cockpit and a
			# rear engine block.
			var door_frame := MeshInstance3D.new()
			var df_box := BoxMesh.new()
			df_box.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.55, 0.04)
			door_frame.mesh = df_box
			door_frame.position = Vector3(0, torso_size.y * 0.45, -torso_size.z * 0.5 - 0.025)
			var df_mat := _make_metal_mat(Color(base_color.r * 0.7, base_color.g * 0.7, base_color.b * 0.7))
			door_frame.set_surface_override_material(0, df_mat)
			torso_pivot.add_child(door_frame)
			mats.append(df_mat)

			var engine := MeshInstance3D.new()
			var eng_box := BoxMesh.new()
			eng_box.size = Vector3(torso_size.x * 0.65, torso_size.y * 0.55, torso_size.z * 0.25)
			engine.mesh = eng_box
			engine.position = Vector3(0, torso_size.y * 0.5, torso_size.z * 0.5 + eng_box.size.z * 0.5)
			var eng_mat := _make_metal_mat(Color(0.18, 0.15, 0.15))
			engine.set_surface_override_material(0, eng_mat)
			torso_pivot.add_child(engine)
			mats.append(eng_mat)
		&"apex":
			# Apex — chest plate, command spire on the head, and a heavy back
			# armor plate.
			var chest_plate := MeshInstance3D.new()
			var cp_box := BoxMesh.new()
			cp_box.size = Vector3(torso_size.x * 0.85, torso_size.y * 0.55, 0.08)
			chest_plate.mesh = cp_box
			chest_plate.position = Vector3(0, torso_size.y * 0.55, -torso_size.z * 0.5 - 0.04)
			var cp_mat := _make_metal_mat(Color(base_color.r * 1.05, base_color.g * 1.05, base_color.b * 1.05))
			chest_plate.set_surface_override_material(0, cp_mat)
			torso_pivot.add_child(chest_plate)
			mats.append(cp_mat)

			# Command spire on top of the head.
			var spire := MeshInstance3D.new()
			var spire_box := BoxMesh.new()
			spire_box.size = Vector3(0.18, head_size.y * 0.7, 0.18)
			spire.mesh = spire_box
			spire.position = Vector3(0, torso_size.y + head_size.y + spire_box.size.y * 0.5, 0)
			var spire_mat := _make_metal_mat(Color(0.2, 0.2, 0.22))
			spire.set_surface_override_material(0, spire_mat)
			torso_pivot.add_child(spire)
			mats.append(spire_mat)

			# Heavy back armor plate.
			var back_plate := MeshInstance3D.new()
			var bp_box := BoxMesh.new()
			bp_box.size = Vector3(torso_size.x * 0.95, torso_size.y * 0.85, 0.12)
			back_plate.mesh = bp_box
			back_plate.position = Vector3(0, torso_size.y * 0.45, torso_size.z * 0.5 + 0.06)
			var bp_mat := _make_metal_mat(Color(base_color.r * 0.85, base_color.g * 0.85, base_color.b * 0.85))
			back_plate.set_surface_override_material(0, bp_mat)
			torso_pivot.add_child(back_plate)
			mats.append(bp_mat)
		&"engineer":
			# Ratchet — small tool brace below the claw arm and a hull rivet band.
			var brace := MeshInstance3D.new()
			var brace_box := BoxMesh.new()
			brace_box.size = Vector3(torso_size.x * 0.75, 0.05, torso_size.z * 0.6)
			brace.mesh = brace_box
			brace.position = Vector3(0, torso_size.y * 0.3, 0)
			var brace_mat := _make_metal_mat(Color(0.28, 0.25, 0.16))
			brace.set_surface_override_material(0, brace_mat)
			torso_pivot.add_child(brace)
			mats.append(brace_mat)
		_:
			pass


func _add_chassis_panels(torso_pivot: Node3D, torso_size: Vector3, mats: Array[StandardMaterial3D]) -> void:
	## Tiny surface detail shared by all bipedal/chicken/spider mechs so they
	## read as engineered hulls rather than smooth boxes.
	# Chest grille — three thin parallel bars on the front of the torso.
	for i: int in 3:
		var bar := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(torso_size.x * 0.45, 0.04, 0.02)
		bar.mesh = bb
		bar.position = Vector3(
			0,
			torso_size.y * 0.4 + (float(i) - 1.0) * (torso_size.y * 0.12),
			-torso_size.z * 0.5 - 0.012
		)
		var bar_mat := _make_metal_mat(Color(0.08, 0.08, 0.1))
		bar.set_surface_override_material(0, bar_mat)
		torso_pivot.add_child(bar)
		mats.append(bar_mat)

	# Back vent — small panel on the back of the torso.
	var vent := MeshInstance3D.new()
	var vb := BoxMesh.new()
	vb.size = Vector3(torso_size.x * 0.55, torso_size.y * 0.25, 0.04)
	vent.mesh = vb
	vent.position = Vector3(0, torso_size.y * 0.4, torso_size.z * 0.5 + 0.02)
	var vent_mat := _make_metal_mat(Color(0.08, 0.08, 0.1))
	vent.set_surface_override_material(0, vent_mat)
	torso_pivot.add_child(vent)
	mats.append(vent_mat)


func _build_hp_bar() -> void:
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()

	var bar_y: float = _mech_total_height() + 0.4

	_hp_bar = Node3D.new()
	_hp_bar.name = "HPBar"
	_hp_bar.position.y = bar_y

	# Background
	_hp_bar_bg = MeshInstance3D.new()
	var bg_box := BoxMesh.new()
	bg_box.size = Vector3(2.0, 0.12, 0.08)
	_hp_bar_bg.mesh = bg_box
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.7)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hp_bar_bg.set_surface_override_material(0, bg_mat)
	_hp_bar.add_child(_hp_bar_bg)

	# Fill
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

	# Top-level so it doesn't inherit unit rotation (prevents jitter)
	add_child(_hp_bar)
	_hp_bar.top_level = true
	_update_hp_bar()


func _update_hp_bar() -> void:
	if not _hp_bar_fill:
		return
	var pct: float = float(get_total_hp()) / float(maxi(stats.hp_total, 1))
	var bar_width: float = 2.0

	# Scale fill from left
	_hp_bar_fill.scale.x = maxf(pct * bar_width, 0.01)
	_hp_bar_fill.position.x = -bar_width / 2.0 * (1.0 - pct)

	# Color shift green → yellow → red
	var fill_mat: StandardMaterial3D = _hp_bar_fill.get_surface_override_material(0) as StandardMaterial3D
	if fill_mat:
		var r: float = 1.0 - pct
		var g: float = pct
		fill_mat.albedo_color = Color(r, g, 0.1, 0.9)
		fill_mat.emission = Color(r, g, 0.1, 1.0)


func _mech_total_height() -> float:
	if not stats:
		return 2.0
	var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
	var hip_y: float = shape["hip_y"] as float
	var torso_size: Vector3 = shape["torso"] as Vector3
	var head_size: Vector3 = shape["head"] as Vector3
	return hip_y + torso_size.y + head_size.y


func _remove_member_visual(index: int) -> void:
	if index < _member_meshes.size():
		var member: Node3D = _member_meshes[index]
		if is_instance_valid(member):
			member.visible = false
			# Spawn flying debris at member's world position
			_spawn_member_debris(member.global_position)


## --- Movement ---

func command_move(target: Vector3, clear_combat: bool = true) -> void:
	## Move toward `target`. By default this also clears any combat target
	## (player-issued moves preempt combat). Pass `clear_combat=false` for
	## combat-internal chase commands so the chaser doesn't immediately wipe
	## its own forced target.
	move_target = target
	move_target.y = global_position.y
	has_move_order = true
	if _nav_agent:
		_nav_agent.target_position = move_target
	if clear_combat:
		var combat: Node = get_combat()
		if combat and combat.has_method("clear_target"):
			combat.clear_target()


func stop() -> void:
	move_target = Vector3.INF
	velocity = Vector3.ZERO
	has_move_order = false


func _physics_process(delta: float) -> void:
	# Damage flash countdown
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_restore_member_colors()

	# Walking animation. _anim_time only advances while moving so legs always
	# resume from a clean stride; _idle_time runs continuously to drive the
	# small standing sway.
	_idle_time += delta
	if velocity.length_squared() > 1.0:
		_anim_time += delta * 8.0
		_apply_walk_bob()
	else:
		_anim_time = 0.0
		_reset_walk_bob()

	_tick_recoil(delta)

	if is_building:
		_animate_build_claw()
		_build_spark_timer -= delta
		if _build_spark_timer <= 0.0:
			_build_spark_timer = 0.16
			_spawn_build_sparks()

	# Position HP bar above unit (top_level so we set global_position).
	# Visibility rule: shown when selected, when damaged, or when hovered. A
	# healthy idle unit is invisible-bar so the battlefield isn't cluttered.
	if _hp_bar and is_instance_valid(_hp_bar):
		var damaged: bool = false
		if stats:
			damaged = get_total_hp() < stats.hp_total
		_hp_bar.visible = is_selected or damaged or hp_bar_hovered
		if _hp_bar.visible:
			var bar_height: float = _mech_total_height() + 0.4
			_hp_bar.global_position = global_position + Vector3(0, bar_height, 0)
			var cam: Camera3D = get_viewport().get_camera_3d()
			if cam:
				_hp_bar.global_rotation = cam.global_rotation

	if move_target == Vector3.INF:
		return

	# Use NavigationAgent for pathfinding if available
	if _nav_agent and _nav_agent.is_navigation_finished():
		has_move_order = false
		stop()
		arrived.emit()
		return

	var next_pos: Vector3
	if _nav_agent:
		next_pos = _nav_agent.get_next_path_position()
	else:
		next_pos = move_target

	var to_next := next_pos - global_position
	to_next.y = 0.0
	var distance := to_next.length()

	if distance < ARRIVE_THRESHOLD:
		if not _nav_agent or _nav_agent.is_navigation_finished():
			has_move_order = false
			stop()
			arrived.emit()
			return

	var direction := to_next / maxf(distance, 0.01)
	velocity = direction * _move_speed

	move_and_slide()

	_last_position = global_position

	var face_dir := velocity.normalized()
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.001:
		_turn_toward(face_dir, delta)


func _turn_toward(face_dir: Vector3, delta: float) -> void:
	## Smoothly rotate the unit around Y to face `face_dir`. Heavies turn
	## noticeably slower than lights, giving each class a different feel.
	if face_dir.length_squared() < 0.0001:
		return
	# atan2(x, z) gives the Y rotation that orients -Z toward face_dir; -PI matches look_at.
	var target_y: float = atan2(face_dir.x, face_dir.z) + PI
	rotation.y = lerp_angle(rotation.y, target_y, clampf(_turn_speed * delta, 0.0, 1.0))


func _apply_walk_bob() -> void:
	# Mech walk: swing each leg around its hip and bob the torso slightly.
	# Per-member stride speed/phase/swing makes the squad feel like four
	# individuals walking together rather than a parade.
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var member: Node3D = data["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		var phase: float = _anim_time * (data["stride_speed"] as float) + (data["stride_phase"] as float)
		var swing: float = data["stride_swing"] as float
		var legs: Array = data["legs"] as Array
		var leg_phases: Array = data["leg_phases"] as Array
		for li: int in legs.size():
			var leg: Node3D = legs[li]
			if not is_instance_valid(leg):
				continue
			# Each leg has its own phase offset (biped: alternating; spider/quadruped: trot).
			var phase_offset: float = 0.0
			if li < leg_phases.size():
				phase_offset = leg_phases[li] as float
			leg.rotation.x = sin(phase + phase_offset) * swing
		# Torso bob doubles per stride cycle (peaks when feet plant).
		member.position.y = absf(sin(phase)) * (data["bob_amount"] as float)


func _reset_walk_bob() -> void:
	# Idle: lerp legs back to neutral, then add a slow weight-shift sway so
	# the mechs don't look frozen while standing.
	var t_idle: float = _idle_time
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var member: Node3D = data["root"]
		var legs: Array = data["legs"] as Array
		for leg: Node3D in legs:
			if is_instance_valid(leg):
				leg.rotation.x = lerp(leg.rotation.x, 0.0, 0.2)
		if is_instance_valid(member):
			# Subtle idle sway — small vertical breath + tiny lateral weight shift,
			# different per member so they don't sway in unison.
			var idle_phase: float = t_idle * (data["idle_speed"] as float) + (data["idle_phase"] as float)
			member.position.y = sin(idle_phase) * 0.012
			# Tiny lean — unit-local X — gives a relaxed feel without breaking formation.
			member.rotation.z = sin(idle_phase * 0.7) * 0.012


## --- Shooting Animation ---

func play_shoot_anim() -> void:
	## Kick all alive members' cannons backward; combat_component calls this on fire.
	for i: int in _member_data.size():
		if i >= member_hp.size() or member_hp[i] <= 0:
			continue
		var member: Node3D = _member_data[i]["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		var recoil: Array = _member_data[i]["recoil"] as Array
		recoil[0] = 1.0
		recoil[1] = 1.0


func _tick_recoil(delta: float) -> void:
	const RECOIL_DECAY: float = 8.0
	const RECOIL_DISTANCE: float = 0.18
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var cannons: Array = data["cannons"] as Array
		var recoil: Array = data["recoil"] as Array
		var rest_z: Array = data.get("cannon_rest_z", []) as Array
		var changed: bool = false
		for c: int in cannons.size():
			var r: float = recoil[c] as float
			if r <= 0.0:
				continue
			r = maxf(0.0, r - delta * RECOIL_DECAY)
			recoil[c] = r
			var pivot: Node3D = cannons[c]
			if is_instance_valid(pivot):
				# Recoil is an OFFSET on top of the cannon's rest position; the
				# rest may be non-zero (e.g., Bulwark's hull-mounted gun sits at
				# the chassis front), so we must add to it instead of replacing.
				var base_z: float = 0.0
				if c < rest_z.size():
					base_z = rest_z[c] as float
				pivot.position.z = base_z + r * RECOIL_DISTANCE
			changed = true
		if changed:
			data["recoil"] = recoil


## --- Floating damage numbers / camera shake ---

func _spawn_damage_number(amount: int) -> void:
	## Floating yellow number above the unit that drifts up and fades out.
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	var label := Label3D.new()
	label.text = "%d" % amount
	label.font_size = 36
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(1.0, 0.9, 0.3, 1.0)
	label.outline_size = 8
	label.outline_modulate = Color(0.0, 0.0, 0.0, 1.0)
	# Spawn above the squad's HP bar with a small random horizontal jitter.
	var spawn_pos: Vector3 = global_position + Vector3(
		randf_range(-0.3, 0.3),
		_mech_total_height() + 0.7,
		randf_range(-0.3, 0.3)
	)
	label.global_position = spawn_pos
	scene.add_child(label)

	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", spawn_pos + Vector3(0, 1.4, 0), 0.7).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.7).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)


func _request_camera_shake(amount: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d() if get_viewport() else null
	if cam and cam.has_method("add_shake"):
		cam.add_shake(amount)


## --- Build Animation ---

func _animate_build_claw() -> void:
	## Engineer's tool arm hammers up-down rapidly while constructing.
	for data: Dictionary in _member_data:
		var cannons: Array = data["cannons"] as Array
		if cannons.is_empty():
			continue
		var pivot: Node3D = cannons[0]
		if not is_instance_valid(pivot):
			continue
		var t: float = _idle_time * 11.0 + (data["stride_phase"] as float)
		# Forward + downward hammer arc, biased so the claw spends more time
		# at the bottom of its swing.
		pivot.rotation.x = sin(t) * 0.55 - 0.25


func _spawn_build_sparks() -> void:
	## Small bright spark flashes at the claw tip to sell the welding effort.
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	for data: Dictionary in _member_data:
		var cannons: Array = data["cannons"] as Array
		if cannons.is_empty():
			continue
		var pivot: Node3D = cannons[0]
		if not is_instance_valid(pivot) or not pivot.visible:
			continue
		# Tip is roughly cannon_size.z forward of the pivot in pivot-local space.
		var tip_world: Vector3 = pivot.global_transform * Vector3(0, 0, -0.55)
		var spark := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = 0.05
		sph.height = 0.1
		spark.mesh = sph
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.85, 0.3, 0.9)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.7, 0.15)
		mat.emission_energy_multiplier = 5.0
		spark.set_surface_override_material(0, mat)
		spark.global_position = tip_world + Vector3(randf_range(-0.05, 0.05), randf_range(-0.05, 0.05), randf_range(-0.05, 0.05))
		scene.add_child(spark)

		var tween := spark.create_tween()
		tween.set_parallel(true)
		tween.tween_property(spark, "scale", Vector3(0.2, 0.2, 0.2), 0.18).set_ease(Tween.EASE_IN)
		tween.tween_property(mat, "albedo_color:a", 0.0, 0.18)
		tween.chain().tween_callback(spark.queue_free)


## --- Destruction Animation ---

func _spawn_member_debris(world_pos: Vector3) -> void:
	## Per-member death: small burst of metal chunks flying outward.
	var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"]) if stats else CLASS_SHAPES[&"medium"]
	var base_color: Color = shape["color"] as Color
	_spawn_debris_burst(world_pos, base_color, 6, 4.5, 0.12)
	_spawn_flash_at(world_pos, Color(1.0, 0.6, 0.2), 0.35, 0.18)


func _spawn_squad_death_explosion() -> void:
	## Final death: bigger flash + larger debris burst at the unit's center.
	var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"]) if stats else CLASS_SHAPES[&"medium"]
	var base_color: Color = shape["color"] as Color
	var center: Vector3 = global_position + Vector3(0, _mech_total_height() * 0.5, 0)
	_spawn_debris_burst(center, base_color, 14, 7.0, 0.18)
	_spawn_flash_at(center, Color(1.0, 0.5, 0.15), 0.7, 0.45)


func _spawn_debris_burst(world_pos: Vector3, color: Color, count: int, speed: float, size: float) -> void:
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	for i: int in count:
		var chunk := MeshInstance3D.new()
		var box := BoxMesh.new()
		var s: float = size * randf_range(0.6, 1.3)
		box.size = Vector3(s, s, s)
		chunk.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(color.r * 0.7, color.g * 0.7, color.b * 0.7)
		mat.roughness = 0.9
		mat.metallic = 0.4
		chunk.set_surface_override_material(0, mat)
		chunk.global_position = world_pos
		scene.add_child(chunk)

		var dir := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(0.6, 1.4),
			randf_range(-1.0, 1.0)
		).normalized()
		var vel: Vector3 = dir * speed * randf_range(0.7, 1.2)
		var spin: Vector3 = Vector3(
			randf_range(-12.0, 12.0),
			randf_range(-12.0, 12.0),
			randf_range(-12.0, 12.0)
		)
		_animate_debris(chunk, vel, spin, randf_range(0.7, 1.1))


func _animate_debris(chunk: MeshInstance3D, velocity: Vector3, spin: Vector3, lifetime: float) -> void:
	# Pure-property tween bound to the chunk so it survives the unit being freed.
	# We approximate ballistic motion as a straight outward fly + ease-in-quad fall,
	# keeping it lightweight (no per-frame method callbacks).
	var start_pos: Vector3 = chunk.global_position
	var end_pos: Vector3 = start_pos + velocity * lifetime
	end_pos.y = maxf(end_pos.y - 4.0 * lifetime * lifetime, 0.05)

	var tween := chunk.create_tween()
	tween.set_parallel(true)
	tween.tween_property(chunk, "global_position", end_pos, lifetime).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(chunk, "rotation", chunk.rotation + spin * lifetime, lifetime)
	tween.tween_property(chunk, "scale", Vector3(0.15, 0.15, 0.15), lifetime).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(chunk.queue_free)


func _spawn_flash_at(world_pos: Vector3, color: Color, radius: float, lifetime: float) -> void:
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	var flash := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = radius
	sph.height = radius * 2.0
	flash.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 5.0
	flash.set_surface_override_material(0, mat)
	flash.global_position = world_pos
	scene.add_child(flash)

	# Tween bound to the flash itself so it's not killed when the unit frees.
	var tween := flash.create_tween()
	tween.set_parallel(true)
	tween.tween_property(flash, "scale", Vector3(2.5, 2.5, 2.5), lifetime)
	tween.tween_property(mat, "albedo_color:a", 0.0, lifetime)
	tween.chain().tween_callback(flash.queue_free)


## --- HP and Damage ---

func take_damage(amount: int, attacker: Node3D = null) -> void:
	if alive_count <= 0:
		return

	var hp_before: int = get_total_hp()

	# Damage carries across members so alive_count tracks the HP fraction:
	# a 4-unit squad at 50% total HP shows 2 members alive.
	var remaining: int = amount
	for i: int in member_hp.size():
		if remaining <= 0:
			break
		if member_hp[i] <= 0:
			continue
		var dealt: int = mini(member_hp[i], remaining)
		member_hp[i] -= dealt
		remaining -= dealt
		if member_hp[i] <= 0:
			alive_count -= 1
			_remove_member_visual(i)
			member_died.emit(i)
			if alive_count <= 0:
				# Show the final hit's damage before _die() frees the unit.
				_spawn_damage_number(hp_before)
				_die()
				return

	# Floating damage number — uses actual HP delta in case some damage was clamped.
	var dealt_total: int = hp_before - get_total_hp()
	if dealt_total > 0:
		_spawn_damage_number(dealt_total)

	_flash_timer = FLASH_DURATION
	_apply_damage_flash()
	_update_hp_bar()

	# Retaliate: if we have a combat component and aren't already engaged,
	# pick the attacker as our target so we shoot back.
	if attacker and is_instance_valid(attacker):
		var combat: Node = get_combat()
		if combat and combat.has_method("notify_attacked"):
			combat.notify_attacked(attacker)


func get_total_hp() -> int:
	var total: int = 0
	for hp: int in member_hp:
		total += hp
	return total


func get_squad_strength_ratio() -> float:
	if not stats or stats.squad_size <= 0:
		return 0.0
	return float(alive_count) / float(stats.squad_size)


func _die() -> void:
	squad_destroyed.emit()
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()

	_spawn_squad_death_explosion()
	_request_camera_shake(0.35)

	var wreck: Node = Wreck.create_from_unit(stats, global_position)
	get_tree().current_scene.add_child(wreck)

	if owner_id == 0:
		var resource_mgr: Node = get_tree().current_scene.get_node_or_null("ResourceManager")
		if resource_mgr and resource_mgr.has_method("remove_population"):
			resource_mgr.remove_population(stats.population)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_unit_destroyed"):
		audio.play_unit_destroyed()

	queue_free()


func _apply_damage_flash() -> void:
	# Boost emission on each member's existing materials. Ongoing animations
	# (leg swing, recoil) are preserved because we don't rebuild any nodes.
	for i: int in _member_data.size():
		if i < member_hp.size() and member_hp[i] <= 0:
			continue
		var data: Dictionary = _member_data[i]
		var member: Node3D = data["root"]
		if not is_instance_valid(member) or not member.visible:
			continue
		var mats: Array = data["mats"] as Array
		for m: StandardMaterial3D in mats:
			if not m:
				continue
			m.emission_enabled = true
			m.emission = Color(1.0, 0.1, 0.0, 1.0)
			m.emission_energy_multiplier = 2.5


func _restore_member_colors() -> void:
	# Restore the per-material emission settings without rebuilding the meshes,
	# so leg-swing and recoil state stay intact and dead members stay hidden.
	for i: int in _member_data.size():
		var data: Dictionary = _member_data[i]
		var mats: Array = data["mats"] as Array
		for m: StandardMaterial3D in mats:
			if not m:
				continue
			# Most metal mats are non-emissive; team stripe / visor / antenna tip
			# carry their own emission set at build time. The flash only changed
			# emission, so resetting it here clears the red without losing color.
			m.emission_enabled = _is_emissive_color(m.albedo_color)
			if m.emission_enabled:
				m.emission = m.albedo_color
				m.emission_energy_multiplier = 1.4
			else:
				m.emission = Color(0, 0, 0, 1)
				m.emission_energy_multiplier = 0.0


func _is_emissive_color(c: Color) -> bool:
	# Heuristic: the only emissive surfaces we build are bright team color, the
	# blue visor, and the red antenna tip. Plain metal greys/browns aren't.
	var lum: float = (c.r + c.g + c.b) / 3.0
	# High saturation OR very bright primary → emissive.
	var max_c: float = maxf(c.r, maxf(c.g, c.b))
	var min_c: float = minf(c.r, minf(c.g, c.b))
	return (max_c - min_c) > 0.3 and lum > 0.25


## --- Selection ---

func select() -> void:
	if is_selected:
		return
	is_selected = true
	selected.emit()
	_update_selection_visual(true)


func deselect() -> void:
	if not is_selected:
		return
	is_selected = false
	deselected.emit()
	_update_selection_visual(false)


func _update_selection_visual(show: bool) -> void:
	var ring: Node3D = get_node_or_null("SelectionRing") as Node3D
	if ring:
		ring.visible = show


## --- Component Accessors ---

func get_builder() -> Node:
	return get_node_or_null("BuilderComponent")


func get_combat() -> Node:
	return get_node_or_null("CombatComponent")


func get_member_positions() -> Array[Vector3]:
	# Return chest-height positions so projectiles and muzzle flashes spawn at
	# the cannons rather than at the feet.
	var positions: Array[Vector3] = []
	var chest_offset: float = 0.0
	if stats:
		var shape: Dictionary = CLASS_SHAPES.get(stats.unit_class, CLASS_SHAPES[&"medium"])
		var hip_y: float = shape["hip_y"] as float
		var torso_size: Vector3 = shape["torso"] as Vector3
		chest_offset = hip_y + torso_size.y * 0.7
	for i: int in _member_meshes.size():
		var member: Node3D = _member_meshes[i]
		if is_instance_valid(member) and member.visible:
			positions.append(member.global_position + Vector3(0, chest_offset, 0))
	return positions
