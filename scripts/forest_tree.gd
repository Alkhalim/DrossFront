class_name ForestTree
extends StaticBody3D
## Destructible map decoration. Acts as a nav obstacle and FogOfWar
## LOS occluder until felled by sufficiently heavy weapons fire.
## Drops a small floating salvage payout on death so chewing through
## a forest is rewarded rather than purely an obstacle clear.
##
## Damage filter: weapons must carry `can_damage_trees = true` on
## their WeaponResource. Combat's damage application path checks the
## flag before routing the hit; fast SMGs / minigun turrets / beam
## continuous lasers are filtered out so 'forest' actually means
## something rather than melting under any volume of rifle fire.

const TREE_HP: int = 80
const TREE_SALVAGE_DROP_MIN: int = 4
const TREE_SALVAGE_DROP_MAX: int = 9
const TRUNK_RADIUS: float = 0.55
const TRUNK_HEIGHT: float = 3.4
const CANOPY_RADIUS: float = 1.8
const CANOPY_HEIGHT: float = 2.6
## Cell radius the tree occupies for FogOfWar's LOS occluder grid.
## A single trunk shouldn't block a whole 4u cell on its own; we
## still register so dense clusters (a forest) stack into a real
## opaque region while a single isolated tree barely matters.
const LOS_OCCLUDER_RADIUS: float = 1.6

var current_hp: int = TREE_HP
var _felled: bool = false
var _trunk: MeshInstance3D = null
var _canopy: MeshInstance3D = null

## Shared mesh + material palette for forest trees. The previous
## per-instance allocations were ~2000 unique materials on
## Schwarzwald (4 per tree x 500+ trees), which broke renderer
## batching and dropped framerate on the map. Sharing collapses
## every tree to one of a handful of trunk/canopy materials so
## the renderer can batch the lot into a few draw calls.
static var _shared_trunk_mesh: CylinderMesh = null
static var _shared_trunk_mats: Array[StandardMaterial3D] = []
static var _shared_canopy_meshes: Array[CylinderMesh] = []  # one per layer
static var _shared_canopy_mats: Array[StandardMaterial3D] = []
static var _shared_collision_shape: CylinderShape3D = null


static func _ensure_shared_assets() -> void:
	if _shared_trunk_mesh != null:
		return
	# Trunk mesh -- single CylinderMesh shared by every tree.
	var trunk: CylinderMesh = CylinderMesh.new()
	trunk.top_radius = TRUNK_RADIUS * 0.65
	trunk.bottom_radius = TRUNK_RADIUS
	trunk.height = TRUNK_HEIGHT
	trunk.radial_segments = 10
	_shared_trunk_mesh = trunk
	# Canopy meshes -- 3 layers, one shared mesh per layer.
	for layer: int in 3:
		var dc: CylinderMesh = CylinderMesh.new()
		dc.top_radius = CANOPY_RADIUS * (0.45 - 0.10 * float(layer))
		dc.bottom_radius = CANOPY_RADIUS * (0.95 - 0.18 * float(layer))
		dc.height = CANOPY_HEIGHT * 0.45
		dc.radial_segments = 12
		_shared_canopy_meshes.append(dc)
	# Trunk + canopy material palettes -- 4 variants each so a
	# forest reads as varied at zoom without breaking batching.
	var trunk_palette: Array[Color] = [
		Color(0.20, 0.13, 0.07, 1.0),
		Color(0.17, 0.11, 0.06, 1.0),
		Color(0.15, 0.10, 0.05, 1.0),
		Color(0.22, 0.14, 0.08, 1.0),
	]
	for c: Color in trunk_palette:
		var m: StandardMaterial3D = StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 1.0
		m.metallic = 0.0
		_shared_trunk_mats.append(m)
	var canopy_palette: Array[Color] = [
		Color(0.13, 0.30, 0.15, 1.0),
		Color(0.10, 0.27, 0.13, 1.0),
		Color(0.15, 0.33, 0.17, 1.0),
		Color(0.11, 0.25, 0.12, 1.0),
	]
	for c2: Color in canopy_palette:
		var m2: StandardMaterial3D = StandardMaterial3D.new()
		m2.albedo_color = c2
		m2.roughness = 1.0
		m2.metallic = 0.0
		_shared_canopy_mats.append(m2)
	# Shared collision shape too -- the trunk shape is identical
	# per tree.
	var col: CylinderShape3D = CylinderShape3D.new()
	col.radius = TRUNK_RADIUS * 1.1
	col.height = TRUNK_HEIGHT
	_shared_collision_shape = col


func _ready() -> void:
	add_to_group("trees")
	# Collision: layer 4 (terrain/obstacles) so units' mask 7
	# physically bumps into the trunk just like a rock pile.
	collision_layer = 4
	collision_mask = 0
	_build_visual()
	# LOS occluder registration disabled for trees -- on
	# Schwarzwald with 500+ trees the per-cell Bresenham line walks
	# in FOW recompute were the dominant per-tick cost. Trees still
	# physically block movement and reveal as the player explores;
	# vision just isn't blocked through them until the FOW recompute
	# moves to a cheaper representation.
	# _register_occluder(true)


func _build_visual() -> void:
	_ensure_shared_assets()
	# Pick one of the four trunk + canopy materials at random per
	# tree so a forest reads as varied at zoom without breaking
	# renderer batching (Godot batches contiguous instances that
	# share the same mesh + material).
	var trunk_mat: StandardMaterial3D = _shared_trunk_mats[randi() % _shared_trunk_mats.size()]
	var canopy_mat: StandardMaterial3D = _shared_canopy_mats[randi() % _shared_canopy_mats.size()]
	# Trunk -- shared mesh + chosen palette material.
	_trunk = MeshInstance3D.new()
	_trunk.mesh = _shared_trunk_mesh
	_trunk.position = Vector3(0, TRUNK_HEIGHT * 0.5, 0)
	_trunk.set_surface_override_material(0, trunk_mat)
	add_child(_trunk)
	# Canopy -- 3 stacked discs sharing the layer mesh + chosen
	# canopy material across every tree.
	_canopy = MeshInstance3D.new()
	add_child(_canopy)
	for layer: int in 3:
		var disc: MeshInstance3D = MeshInstance3D.new()
		var dc: CylinderMesh = _shared_canopy_meshes[layer]
		disc.mesh = dc
		disc.position = Vector3(0, TRUNK_HEIGHT + dc.height * 0.5 + float(layer) * (dc.height * 0.55), 0)
		disc.set_surface_override_material(0, canopy_mat)
		_canopy.add_child(disc)
	# Random Y rotation per instance so the whole forest doesn't
	# face the same direction.
	rotation.y = randf_range(0.0, TAU)
	# Hard collision cylinder around the trunk (a unit can't walk
	# through a tree; canopy is cosmetic only). Shape is shared
	# across every tree.
	var col: CollisionShape3D = CollisionShape3D.new()
	col.shape = _shared_collision_shape
	col.position = Vector3(0, TRUNK_HEIGHT * 0.5, 0)
	add_child(col)
	# No NavigationObstacle3D per tree -- a Schwarzwald-density
	# forest would saturate the RVO server with hundreds of
	# obstacles per agent neighbourhood and tank the frame rate.
	# Hard collision (trunk cylinder above) physically blocks
	# agents; the FOW LOS occluder + collision are enough to
	# make trees feel solid without paying RVO costs per trunk.


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
	_register_occluder(false)
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


func _register_occluder(register: bool) -> void:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return
	var fow: Node = scene.get_node_or_null("FogOfWar")
	if not fow:
		return
	if register and fow.has_method("register_los_occluder"):
		fow.call("register_los_occluder", global_position, LOS_OCCLUDER_RADIUS)
	elif not register and fow.has_method("unregister_los_occluder"):
		fow.call("unregister_los_occluder", global_position, LOS_OCCLUDER_RADIUS)
