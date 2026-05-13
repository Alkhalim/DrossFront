class_name ProjectileManager
extends Node
## Centralized projectile rendering + simulation. Replaces per-projectile
## Node3D with one MultiMeshInstance3D per (style, color) tuple. State for
## active projectiles lives in parallel arrays (SoA) and updates each frame
## in _process. CombatComponent calls fire(...) to create projectiles;
## damage application semantics match the legacy Projectile path exactly
## (hitscan for bullets, deferred for missiles/shells/mortars/bombs).

const MAX_PROJECTILES_PER_BUCKET: int = 256

## Singleton lookup. Mirrors the SpatialIndex / NavRouter / FogOfWar
## pattern — find the manager under the current scene root, fall back
## to null for headless contexts.
static func get_instance(scene_root: Node) -> ProjectileManager:
	if scene_root == null:
		return null
	var found: Node = scene_root.get_node_or_null("ProjectileManager")
	if found == null:
		return null
	return found as ProjectileManager


## Per-(style, color) MultiMeshInstance3D bucket.
## Key format: "style|R|G|B|A" (color quantized to 0-255 ints).
var _buckets: Dictionary = {}


func _bucket_key(style: String, color: Color) -> String:
	return "%s|%d|%d|%d|%d" % [
		style,
		int(color.r * 255.0),
		int(color.g * 255.0),
		int(color.b * 255.0),
		int(color.a * 255.0),
	]


func _ensure_bucket(style: String, color: Color) -> MultiMeshInstance3D:
	var key: String = _bucket_key(style, color)
	if _buckets.has(key):
		return _buckets[key] as MultiMeshInstance3D
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "MMI_" + key
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	mm.instance_count = MAX_PROJECTILES_PER_BUCKET
	mm.visible_instance_count = 0  # nothing in flight yet
	mm.mesh = _build_mesh_for_style(style, color)
	mmi.multimesh = mm
	add_child(mmi)
	_buckets[key] = mmi
	return mmi


func _build_mesh_for_style(style: String, color: Color) -> Mesh:
	# Reuse the cached meshes Projectile already builds. Each style's
	# mesh shape stays the same as the legacy per-Projectile path; only
	# the rendering path changes (one shared MultiMesh instead of one
	# MeshInstance3D per projectile).
	# For now, return a placeholder cylinder. Style-specific meshes
	# land in Task 6 (shell, mortar, bomb each have multi-surface
	# meshes that need to fold into one ArrayMesh for MultiMesh).
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.05
	cyl.height = 0.34
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	cyl.surface_set_material(0, mat)
	return cyl
