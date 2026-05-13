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


## Per-projectile state, parallel arrays (SoA). Index N across all
## arrays describes one active projectile. Free slots are tracked
## in _free_slots; allocation pops from the free list, falling back
## to growing all arrays when the list is empty.
const SLOT_FREE: int = -1

var _state_pos: PackedVector3Array = PackedVector3Array()
var _state_target: PackedVector3Array = PackedVector3Array()
var _state_start: PackedVector3Array = PackedVector3Array()
var _state_speed: PackedFloat32Array = PackedFloat32Array()
var _state_life: PackedFloat32Array = PackedFloat32Array()
var _state_total_flight: PackedFloat32Array = PackedFloat32Array()
var _state_arc_height: PackedFloat32Array = PackedFloat32Array()
## Style index per projectile. -1 = SLOT_FREE. Other values are bucket
## keys looked up in _bucket_key_by_index.
var _state_style: PackedInt32Array = PackedInt32Array()
## Bucket key (and slot index in that bucket's MultiMesh) per projectile.
var _state_bucket_key: Array[String] = []
var _state_bucket_slot: PackedInt32Array = PackedInt32Array()
## Damage payload per projectile. Populated on fire(...) from the caller.
var _state_pending_damage: PackedInt32Array = PackedInt32Array()
var _state_pending_target: Array[Node3D] = []
var _state_pending_shooter: Array[Node3D] = []
var _state_pending_splash_radius: PackedFloat32Array = PackedFloat32Array()
var _state_pending_splash_damage: PackedInt32Array = PackedInt32Array()
var _state_pending_shooter_owner_id: PackedInt32Array = PackedInt32Array()

var _free_slots: PackedInt32Array = PackedInt32Array()


## Per-bucket free-slot list. When a projectile in bucket B is freed,
## its bucket slot returns here so future fires reuse it.
var _bucket_free_slots: Dictionary = {}  # String -> PackedInt32Array


func _alloc_slot() -> int:
	if _free_slots.size() > 0:
		var slot: int = _free_slots[_free_slots.size() - 1]
		_free_slots.resize(_free_slots.size() - 1)
		return slot
	# Grow all arrays by one slot.
	var new_idx: int = _state_pos.size()
	_state_pos.append(Vector3.ZERO)
	_state_target.append(Vector3.ZERO)
	_state_start.append(Vector3.ZERO)
	_state_speed.append(0.0)
	_state_life.append(0.0)
	_state_total_flight.append(0.0)
	_state_arc_height.append(0.0)
	_state_style.append(SLOT_FREE)
	_state_bucket_key.append("")
	_state_bucket_slot.append(-1)
	_state_pending_damage.append(0)
	_state_pending_target.append(null)
	_state_pending_shooter.append(null)
	_state_pending_splash_radius.append(0.0)
	_state_pending_splash_damage.append(0)
	_state_pending_shooter_owner_id.append(-1)
	return new_idx


func _free_slot(idx: int) -> void:
	# Return the bucket slot to its bucket's free list, then mark
	# this projectile slot free so _alloc_slot can reuse it.
	var bk: String = _state_bucket_key[idx]
	var bs: int = _state_bucket_slot[idx]
	if bk != "" and bs >= 0:
		var fl: PackedInt32Array = _bucket_free_slots.get(bk, PackedInt32Array()) as PackedInt32Array
		fl.append(bs)
		_bucket_free_slots[bk] = fl
		# Hide the freed instance by zeroing its scale so it isn't visible.
		var bucket: MultiMeshInstance3D = _buckets.get(bk) as MultiMeshInstance3D
		if bucket != null and bucket.multimesh != null:
			bucket.multimesh.set_instance_transform(bs, Transform3D().scaled(Vector3.ZERO))
	_state_style[idx] = SLOT_FREE
	_state_bucket_key[idx] = ""
	_state_bucket_slot[idx] = -1
	_state_pending_target[idx] = null
	_state_pending_shooter[idx] = null
	_free_slots.append(idx)


func _alloc_bucket_slot(key: String) -> int:
	var fl: PackedInt32Array = _bucket_free_slots.get(key, PackedInt32Array()) as PackedInt32Array
	if fl.size() > 0:
		var slot: int = fl[fl.size() - 1]
		fl.resize(fl.size() - 1)
		_bucket_free_slots[key] = fl
		return slot
	# No free slot in this bucket — find the next unused slot in the
	# MultiMesh (visible_instance_count is the high-water mark).
	var bucket: MultiMeshInstance3D = _buckets.get(key) as MultiMeshInstance3D
	if bucket == null or bucket.multimesh == null:
		return -1
	var mm: MultiMesh = bucket.multimesh
	if mm.visible_instance_count >= MAX_PROJECTILES_PER_BUCKET:
		# Bucket full — caller should drop the projectile silently.
		return -1
	var slot: int = mm.visible_instance_count
	mm.visible_instance_count = slot + 1
	return slot


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
