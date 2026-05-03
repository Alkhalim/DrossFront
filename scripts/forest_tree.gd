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


func _ready() -> void:
	add_to_group("trees")
	# Collision: layer 4 (terrain/obstacles) so units' mask 7
	# physically bumps into the trunk just like a rock pile.
	collision_layer = 4
	collision_mask = 0
	_build_visual()
	_register_occluder(true)


func _build_visual() -> void:
	# Trunk -- tall narrow cylinder in dark warm brown.
	_trunk = MeshInstance3D.new()
	var trunk_cyl: CylinderMesh = CylinderMesh.new()
	trunk_cyl.top_radius = TRUNK_RADIUS * 0.65
	trunk_cyl.bottom_radius = TRUNK_RADIUS
	trunk_cyl.height = TRUNK_HEIGHT
	trunk_cyl.radial_segments = 10
	_trunk.mesh = trunk_cyl
	_trunk.position = Vector3(0, TRUNK_HEIGHT * 0.5, 0)
	var trunk_mat: StandardMaterial3D = StandardMaterial3D.new()
	# Slight per-instance jitter so a forest doesn't look stamped.
	trunk_mat.albedo_color = Color(
		0.18 + randf_range(-0.04, 0.04),
		0.12 + randf_range(-0.03, 0.03),
		0.07 + randf_range(-0.02, 0.02),
		1.0,
	)
	trunk_mat.roughness = 1.0
	trunk_mat.metallic = 0.0
	_trunk.set_surface_override_material(0, trunk_mat)
	add_child(_trunk)
	# Canopy -- wide flat cone at the top, three stacked discs of
	# varying width so the silhouette reads as a layered conifer.
	_canopy = MeshInstance3D.new()
	add_child(_canopy)
	for layer: int in 3:
		var disc: MeshInstance3D = MeshInstance3D.new()
		var dc: CylinderMesh = CylinderMesh.new()
		dc.top_radius = CANOPY_RADIUS * (0.45 - 0.10 * float(layer))
		dc.bottom_radius = CANOPY_RADIUS * (0.95 - 0.18 * float(layer))
		dc.height = CANOPY_HEIGHT * 0.45
		dc.radial_segments = 12
		disc.mesh = dc
		disc.position = Vector3(0, TRUNK_HEIGHT + dc.height * 0.5 + float(layer) * (dc.height * 0.55), 0)
		var c_mat: StandardMaterial3D = StandardMaterial3D.new()
		c_mat.albedo_color = Color(
			0.12 + randf_range(-0.03, 0.03),
			0.30 + randf_range(-0.05, 0.05),
			0.14 + randf_range(-0.03, 0.03),
			1.0,
		)
		c_mat.roughness = 1.0
		c_mat.metallic = 0.0
		disc.set_surface_override_material(0, c_mat)
		_canopy.add_child(disc)
	# Random Y rotation per instance so the whole forest doesn't
	# face the same direction.
	rotation.y = randf_range(0.0, TAU)
	# Hard collision cylinder around the trunk (a unit can't walk
	# through a tree; canopy is cosmetic only).
	var col: CollisionShape3D = CollisionShape3D.new()
	var col_cyl: CylinderShape3D = CylinderShape3D.new()
	col_cyl.radius = TRUNK_RADIUS * 1.1
	col_cyl.height = TRUNK_HEIGHT
	col.shape = col_cyl
	col.position = Vector3(0, TRUNK_HEIGHT * 0.5, 0)
	add_child(col)
	# Navigation obstacle so agents route around trees via RVO
	# without baking a hole into the static navmesh per tree (a
	# Schwarzwald-density forest would otherwise blow up the
	# triangulation pass at startup).
	var obstacle: NavigationObstacle3D = NavigationObstacle3D.new()
	obstacle.radius = TRUNK_RADIUS * 1.4
	obstacle.affect_navigation_mesh = false
	obstacle.avoidance_enabled = true
	add_child(obstacle)


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
