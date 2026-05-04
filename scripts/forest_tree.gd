class_name ForestTree
extends StaticBody3D
## Destructible map decoration. Acts as a nav obstacle (and optionally
## a FogOfWar LOS occluder) until felled by sufficiently heavy weapons
## fire. Drops a small salvage payout when destroyed so chewing through
## a forest is rewarded rather than purely an obstacle clear.
##
## Three variants picked at random per spawn:
##  - HEALTHY: muted-green conifer (3 stacked canopy discs).
##  - DEAD: skeletal trunk + a few angular bare branches, no canopy.
##  - STUMP: short snapped trunk, slightly wider, no canopy.
## All variants share a small static mesh + material palette so the
## renderer can batch the forest into a handful of draw calls instead
## of hundreds of unique materials per scene.

enum Variant { HEALTHY, DEAD, STUMP }

const TREE_HP: int = 80
const TREE_SALVAGE_DROP_MIN: int = 4
const TREE_SALVAGE_DROP_MAX: int = 9
## Visual trunk radius -- intentionally slim so trees read as tall
## conifers, not stubby mushroom bases. Collision is wider (see
## TRUNK_COLLISION_RADIUS below) so the forest physically blocks
## movement even though the trunks LOOK narrow.
const TRUNK_RADIUS_VISUAL: float = 0.42
const TRUNK_HEIGHT: float = 5.4
const STUMP_HEIGHT: float = 1.6
## Collision radius is much wider than the visual trunk so adjacent
## trees on the spawn grid (3.4u step + 1.1u jitter) overlap their
## collision boxes. Result: no gap between adjacent trunks larger
## than ~0.4u, which is smaller than even a moving-shrunk mech's
## collision footprint -- the forest actually walls movement off
## instead of letting squads weave between trunks.
const TRUNK_COLLISION_RADIUS: float = 1.55
const CANOPY_RADIUS: float = 1.95
const CANOPY_HEIGHT: float = 3.0
## Cell radius the tree occupies for FogOfWar's LOS occluder grid.
## A single trunk shouldn't block a whole 4u cell on its own; we
## still register so dense clusters (a forest) stack into a real
## opaque region while a single isolated tree barely matters.
const LOS_OCCLUDER_RADIUS: float = 1.6

var current_hp: int = TREE_HP
var _felled: bool = false
var _variant: int = Variant.HEALTHY

## Shared mesh + material palette for forest trees. Per-instance
## allocations break renderer batching (one draw call per tree
## instead of one draw call per material). Static palette keeps
## visual variety while collapsing every tree to a handful of
## mesh+material combos.
static var _shared_assets_built: bool = false
# Shared meshes.
static var _mesh_trunk_full: CylinderMesh = null
static var _mesh_trunk_dead: CylinderMesh = null
static var _mesh_trunk_stump: CylinderMesh = null
static var _mesh_canopy_layers: Array[CylinderMesh] = []  # 3 layers
static var _mesh_dead_branch: CylinderMesh = null
static var _mesh_root_flare: CylinderMesh = null
static var _mesh_bark_plate: BoxMesh = null
# Shared material palettes.
static var _mats_trunk: Array[StandardMaterial3D] = []
static var _mats_trunk_dead: Array[StandardMaterial3D] = []
static var _mats_canopy: Array[StandardMaterial3D] = []
# Shared collision shapes -- one per trunk size class.
static var _shape_trunk_full: CylinderShape3D = null
static var _shape_trunk_stump: CylinderShape3D = null


static func _ensure_shared_assets() -> void:
	if _shared_assets_built:
		return
	_shared_assets_built = true
	# Healthy trunk -- tall slim cylinder with a subtle taper. Real
	# conifer profile (was a stubby mushroom-base flare before).
	# 12 radial segments so the silhouette reads as round, not
	# polygonal, at building-detail fidelity.
	var trunk: CylinderMesh = CylinderMesh.new()
	trunk.top_radius = TRUNK_RADIUS_VISUAL * 0.78
	trunk.bottom_radius = TRUNK_RADIUS_VISUAL
	trunk.height = TRUNK_HEIGHT
	trunk.radial_segments = 12
	_mesh_trunk_full = trunk
	# Dead trunk -- slim, slightly thinner at the top, near
	# straight cylinder. Same height as healthy so the silhouettes
	# align in a mixed forest.
	var dead: CylinderMesh = CylinderMesh.new()
	dead.top_radius = TRUNK_RADIUS_VISUAL * 0.62
	dead.bottom_radius = TRUNK_RADIUS_VISUAL * 0.88
	dead.height = TRUNK_HEIGHT
	dead.radial_segments = 10
	_mesh_trunk_dead = dead
	# Stump -- short snapped trunk, slightly wider so the broken
	# cap reads at zoom.
	var stump: CylinderMesh = CylinderMesh.new()
	stump.top_radius = TRUNK_RADIUS_VISUAL * 1.10
	stump.bottom_radius = TRUNK_RADIUS_VISUAL * 1.30
	stump.height = STUMP_HEIGHT
	stump.radial_segments = 12
	_mesh_trunk_stump = stump
	# 4 stacked cones tapering inward; top layer top_radius=0
	# so the conifer ends in a real point instead of a disc cap.
	var canopy_bot: Array[float] = [1.00, 0.78, 0.55, 0.32]
	var canopy_top: Array[float] = [0.78, 0.55, 0.32, 0.00]
	for layer: int in 4:
		var dc: CylinderMesh = CylinderMesh.new()
		dc.top_radius = CANOPY_RADIUS * canopy_top[layer]
		dc.bottom_radius = CANOPY_RADIUS * canopy_bot[layer]
		dc.height = CANOPY_HEIGHT * 0.32
		dc.radial_segments = 14
		_mesh_canopy_layers.append(dc)
	# Dead-tree branches -- thin angular cylinders rotated outward.
	var br: CylinderMesh = CylinderMesh.new()
	br.top_radius = 0.04
	br.bottom_radius = 0.08
	br.height = 1.4
	br.radial_segments = 6
	_mesh_dead_branch = br
	# Root flare -- a stubby disc that sits at the base of healthy
	# + dead trunks so the foot reads as roots flaring into the
	# ground rather than a pole stuck in a hole.
	if _mesh_root_flare == null:
		var rf: CylinderMesh = CylinderMesh.new()
		rf.top_radius = TRUNK_RADIUS_VISUAL * 1.05
		rf.bottom_radius = TRUNK_RADIUS_VISUAL * 1.65
		rf.height = 0.30
		rf.radial_segments = 12
		_mesh_root_flare = rf
	# Bark plate -- a thin tall vertical strip applied to the
	# trunk side at random rotations so bark detail breaks up the
	# perfectly-round trunk silhouette. 2-3 plates per healthy
	# tree.
	if _mesh_bark_plate == null:
		var bp: BoxMesh = BoxMesh.new()
		bp.size = Vector3(0.07, TRUNK_HEIGHT * 0.78, 0.04)
		_mesh_bark_plate = bp
	# Trunk material palette -- muted dark browns. Dieselpunk
	# wasteland forest, not a National Park brochure.
	var trunk_palette: Array[Color] = [
		Color(0.16, 0.11, 0.07, 1.0),
		Color(0.13, 0.09, 0.05, 1.0),
		Color(0.20, 0.14, 0.09, 1.0),
		Color(0.11, 0.08, 0.05, 1.0),
	]
	for c: Color in trunk_palette:
		var m: StandardMaterial3D = StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 1.0
		m.metallic = 0.0
		_mats_trunk.append(m)
	# Dead-tree palette -- bleached greys + ash, no warm brown.
	var dead_palette: Array[Color] = [
		Color(0.30, 0.27, 0.22, 1.0),
		Color(0.22, 0.20, 0.16, 1.0),
		Color(0.36, 0.32, 0.27, 1.0),
		Color(0.18, 0.16, 0.13, 1.0),
	]
	for cd: Color in dead_palette:
		var md: StandardMaterial3D = StandardMaterial3D.new()
		md.albedo_color = cd
		md.roughness = 1.0
		md.metallic = 0.0
		_mats_trunk_dead.append(md)
	# Canopy palette -- desaturated dusty greens, biased toward
	# olive / khaki instead of forest-floor lush. A few darker
	# slots so a cluster reads as 'unwell, neglected' rather than
	# 'pristine'.
	var canopy_palette: Array[Color] = [
		Color(0.18, 0.24, 0.15, 1.0),  # dusty olive
		Color(0.14, 0.20, 0.12, 1.0),  # darker olive
		Color(0.22, 0.26, 0.16, 1.0),  # khaki tinge
		Color(0.16, 0.21, 0.13, 1.0),  # mid olive
		Color(0.12, 0.16, 0.10, 1.0),  # near-black green for
		                                # the diseased-looking ones
	]
	for cc: Color in canopy_palette:
		var mc: StandardMaterial3D = StandardMaterial3D.new()
		mc.albedo_color = cc
		mc.roughness = 1.0
		mc.metallic = 0.0
		_mats_canopy.append(mc)
	# Collision shapes -- decoupled from the visual trunk radius.
	# The collision is intentionally MUCH wider than the visible
	# trunk so adjacent trees on the spawn grid overlap their
	# collision boxes and units physically can't slip between
	# them. Visually the trunks still read as slim conifers.
	var col_full: CylinderShape3D = CylinderShape3D.new()
	col_full.radius = TRUNK_COLLISION_RADIUS
	col_full.height = TRUNK_HEIGHT
	_shape_trunk_full = col_full
	var col_stump: CylinderShape3D = CylinderShape3D.new()
	col_stump.radius = TRUNK_COLLISION_RADIUS
	col_stump.height = STUMP_HEIGHT
	_shape_trunk_stump = col_stump


func _ready() -> void:
	add_to_group("trees")
	# Collision: layer 4 (terrain/obstacles) so units' mask 7
	# physically bumps into the trunk just like a rock pile.
	collision_layer = 4
	collision_mask = 0
	# Variant roll: 38% healthy, 50% dead, 12% stump. Pushes the
	# dieselpunk-wasteland decay tone harder than the previous
	# 60/30/10 mix that read as too lush. Half the trees are now
	# bleached + bare; healthy + stump fill the rest.
	var roll: float = randf()
	if roll < 0.38:
		_variant = Variant.HEALTHY
	elif roll < 0.88:
		_variant = Variant.DEAD
	else:
		_variant = Variant.STUMP
	_build_visual()


func _build_visual() -> void:
	_ensure_shared_assets()
	# Random Y rotation per instance so the whole forest doesn't
	# face the same direction.
	rotation.y = randf_range(0.0, TAU)
	match _variant:
		Variant.HEALTHY:
			_build_healthy()
		Variant.DEAD:
			_build_dead()
		Variant.STUMP:
			_build_stump()


func _build_healthy() -> void:
	var trunk_mat: StandardMaterial3D = _mats_trunk[randi() % _mats_trunk.size()]
	var canopy_mat: StandardMaterial3D = _mats_canopy[randi() % _mats_canopy.size()]
	# Trunk -- tall slim cylinder.
	var trunk: MeshInstance3D = MeshInstance3D.new()
	trunk.mesh = _mesh_trunk_full
	trunk.position = Vector3(0, TRUNK_HEIGHT * 0.5, 0)
	trunk.set_surface_override_material(0, trunk_mat)
	add_child(trunk)
	# Root flare -- wider stub at the base so the trunk reads as
	# anchored in soil rather than a pole stuck in a hole.
	var flare: MeshInstance3D = MeshInstance3D.new()
	flare.mesh = _mesh_root_flare
	flare.position = Vector3(0, 0.15, 0)
	flare.set_surface_override_material(0, trunk_mat)
	add_child(flare)
	# Bark plates -- 2-3 thin vertical strips at random rotations
	# so the trunk silhouette breaks up the perfect cylinder. Use
	# a slightly darker variant of the trunk palette so the plates
	# read as bark ridges, not paint stripes.
	var bark_dark: StandardMaterial3D = _mats_trunk[(randi() + 2) % _mats_trunk.size()]
	var plate_count: int = randi_range(2, 3)
	for i: int in plate_count:
		var plate: MeshInstance3D = MeshInstance3D.new()
		plate.mesh = _mesh_bark_plate
		var ang: float = randf_range(0.0, TAU)
		plate.position = Vector3(
			cos(ang) * TRUNK_RADIUS_VISUAL * 0.95,
			TRUNK_HEIGHT * 0.42,
			sin(ang) * TRUNK_RADIUS_VISUAL * 0.95,
		)
		plate.rotation.y = ang
		plate.set_surface_override_material(0, bark_dark)
		add_child(plate)
	# Canopy -- 4 stacked cones tapering to a point at the top.
	var canopy_y: float = TRUNK_HEIGHT - 0.20  # start lower so canopy hugs trunk
	for layer: int in 4:
		var disc: MeshInstance3D = MeshInstance3D.new()
		var dc: CylinderMesh = _mesh_canopy_layers[layer]
		disc.mesh = dc
		disc.position = Vector3(0, canopy_y + dc.height * 0.5, 0)
		disc.set_surface_override_material(0, canopy_mat)
		add_child(disc)
		# Each layer overlaps the one below by ~25% so the silhouette
		# reads as a continuous cone, not a stack of separated discs.
		canopy_y += dc.height * 0.75
	# Lower secondary branches -- 2-3 short downward-tilted twigs
	# poking out from the trunk just below the canopy. Adds the
	# fidelity the user wanted (matches building / unit detail
	# pass) without breaking the silhouette.
	var twig_count: int = randi_range(2, 3)
	for j: int in twig_count:
		var twig: MeshInstance3D = MeshInstance3D.new()
		twig.mesh = _mesh_dead_branch
		var tang: float = randf_range(0.0, TAU)
		var ttilt: float = randf_range(deg_to_rad(60.0), deg_to_rad(85.0))
		twig.rotation = Vector3(ttilt, tang, 0.0)
		twig.position = Vector3(0.0, TRUNK_HEIGHT * 0.78 + randf_range(-0.2, 0.2), 0.0)
		twig.set_surface_override_material(0, trunk_mat)
		add_child(twig)
	_add_full_collision()


func _build_dead() -> void:
	var dead_mat: StandardMaterial3D = _mats_trunk_dead[randi() % _mats_trunk_dead.size()]
	var trunk: MeshInstance3D = MeshInstance3D.new()
	trunk.mesh = _mesh_trunk_dead
	trunk.position = Vector3(0, TRUNK_HEIGHT * 0.5, 0)
	trunk.set_surface_override_material(0, dead_mat)
	add_child(trunk)
	# Dead trees still have a small root flare -- the trunk
	# rotted but the base remained.
	var flare: MeshInstance3D = MeshInstance3D.new()
	flare.mesh = _mesh_root_flare
	flare.position = Vector3(0, 0.15, 0)
	flare.set_surface_override_material(0, dead_mat)
	add_child(flare)
	# A handful of angular bare branches sticking out the upper
	# half of the trunk. 4-6 branches at random rotations + tilts.
	var branch_count: int = randi_range(3, 6)
	for i: int in branch_count:
		var br: MeshInstance3D = MeshInstance3D.new()
		br.mesh = _mesh_dead_branch
		# Branches default to vertical; rotate them outward at a
		# random angle. The branch's own pivot is at the lower
		# end (cylinder default).
		var ang: float = randf_range(0.0, TAU)
		var tilt: float = randf_range(deg_to_rad(40.0), deg_to_rad(75.0))
		br.rotation = Vector3(tilt, ang, 0.0)
		# Place the lower end at a random height on the upper
		# half of the trunk; the rotation swings the branch out
		# from the trunk centre.
		var y: float = randf_range(TRUNK_HEIGHT * 0.55, TRUNK_HEIGHT * 0.95)
		br.position = Vector3(0.0, y, 0.0)
		br.set_surface_override_material(0, dead_mat)
		add_child(br)
	_add_full_collision()


func _build_stump() -> void:
	var trunk_mat: StandardMaterial3D = _mats_trunk_dead[randi() % _mats_trunk_dead.size()]
	var trunk: MeshInstance3D = MeshInstance3D.new()
	trunk.mesh = _mesh_trunk_stump
	trunk.position = Vector3(0, STUMP_HEIGHT * 0.5, 0)
	trunk.set_surface_override_material(0, trunk_mat)
	add_child(trunk)
	# Stumps use a shorter collision shape so units can fire
	# OVER them; they still physically block movement.
	var col: CollisionShape3D = CollisionShape3D.new()
	col.shape = _shape_trunk_stump
	col.position = Vector3(0, STUMP_HEIGHT * 0.5, 0)
	add_child(col)


func _add_full_collision() -> void:
	var col: CollisionShape3D = CollisionShape3D.new()
	col.shape = _shape_trunk_full
	col.position = Vector3(0, TRUNK_HEIGHT * 0.5, 0)
	add_child(col)


func take_damage(amount: int, attacker: Node3D = null) -> void:
	if _felled or amount <= 0:
		return
	# Weapon-tier gate: accept damage only if the attacker's loadout
	# includes a weapon flagged can_damage_trees (rockets, large
	# slow guns, bombs, heavy lasers, flamethrowers). Anything
	# without a stats / weapon (e.g. splash from a turret, scripted
	# wreck wave) defaults to allowed so map-event damage doesn't
	# leak past the gate.
	if attacker and "stats" in attacker:
		var stats: UnitStatResource = attacker.get("stats") as UnitStatResource
		if stats:
			var allowed: bool = false
			if stats.primary_weapon and stats.primary_weapon.can_damage_trees:
				allowed = true
			if not allowed and stats.secondary_weapon and stats.secondary_weapon.can_damage_trees:
				allowed = true
			if not allowed:
				return
	current_hp -= amount
	if current_hp <= 0:
		_fell(attacker)


func _fell(attacker: Node3D) -> void:
	_felled = true
	# Dust + chip burst at the trunk base so the felling reads as
	# real impact rather than a silent disappearance.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
		if pem:
			var fall_pos: Vector3 = global_position + Vector3(0, 0.3, 0)
			pem.call("emit_smoke", fall_pos, Vector3(0, 1.2, 0), Color(0.30, 0.22, 0.14, 0.75))
			if pem.has_method("emit_dust"):
				pem.call("emit_dust", fall_pos, 14, 1.4)
		# Floating salvage payout to the attacker's owner so a
		# chopped forest visibly rewards the player who cleared it.
		var dropped: int = randi_range(TREE_SALVAGE_DROP_MIN, TREE_SALVAGE_DROP_MAX)
		var owner_id: int = -1
		if attacker and "owner_id" in attacker:
			owner_id = attacker.get("owner_id") as int
		if owner_id >= 0:
			var rm_path: String = "ResourceManager"
			if owner_id != 0:
				# AI players have their own ResourceManager nodes
				# named ResourceManager_<id>; fall back gracefully.
				rm_path = "ResourceManager_%d" % owner_id
			var rm: Node = scene.get_node_or_null(rm_path)
			if not rm:
				rm = scene.get_node_or_null("ResourceManager")
			if rm and rm.has_method("add_salvage"):
				rm.call("add_salvage", dropped)
			if owner_id == 0:
				FloatingNumber.spawn(
					scene,
					global_position + Vector3(0, 2.4, 0),
					"+%d" % dropped,
					FloatingNumber.COLOR_SALVAGE,
				)
	queue_free()
