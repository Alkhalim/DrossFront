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
##
## Lazy-attach: if the scene root has no ProjectileManager, create
## one and add it. Mirrors SpatialIndex / NavRouter pattern so every
## arena scene picks up combat rendering automatically — the test
## arenas under scenes/test_arenas/ each have their own controller
## script that doesn't wire infrastructure singletons explicitly,
## so without this fallback Borzoi (and all other units) silently
## skip projectile rendering when CombatComponent gets back a null
## manager.
static func get_instance(scene_root: Node) -> ProjectileManager:
	if scene_root == null:
		return null
	var found: Node = scene_root.get_node_or_null("ProjectileManager")
	if found != null:
		return found as ProjectileManager
	# Lazy-create. Use call_deferred so we don't trip the
	# 'Parent node is busy setting up children' guard if get_instance
	# is called during scene init from a child's _ready.
	var pm := ProjectileManager.new()
	pm.name = "ProjectileManager"
	scene_root.add_child.call_deferred(pm)
	return pm


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
	# CRITICAL: mesh MUST be set BEFORE instance_count. Setting
	# instance_count first allocates the transform array against an
	# empty mesh (Godot quirk) and the MultiMesh ends up rendering
	# nothing — this was why no projectiles were visible in-game even
	# though the manager's _process / fire path ran correctly.
	mm.mesh = _build_mesh_for_style(style, color)
	mm.instance_count = MAX_PROJECTILES_PER_BUCKET
	mm.visible_instance_count = 0  # nothing in flight yet
	mmi.multimesh = mm
	add_child(mmi)
	_buckets[key] = mmi
	return mmi


func _build_mesh_for_style(style: String, color: Color) -> Mesh:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	match style:
		"bullet":
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.04
			cyl.bottom_radius = 0.05
			cyl.height = 0.34
			mat.emission_energy_multiplier = 3.0
			cyl.material = mat
			return cyl
		"missile":
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.04
			cyl.bottom_radius = 0.10
			cyl.height = 0.40
			mat.emission_energy_multiplier = 2.5
			cyl.material = mat
			return cyl
		"shell":
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.06
			cyl.bottom_radius = 0.16
			cyl.height = 0.62
			cyl.radial_segments = 12
			mat.emission_energy_multiplier = 2.4
			cyl.material = mat
			return cyl
		"mortar":
			# Fidelity reduced — fins folded into the body silhouette
			# at ~3× radial extent to read as fin-stabilized.
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.07
			cyl.bottom_radius = 0.18
			cyl.height = 0.50
			cyl.radial_segments = 12
			mat.emission_energy_multiplier = 0.6
			cyl.material = mat
			return cyl
		"bomb":
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.05
			cyl.bottom_radius = 0.18
			cyl.height = 0.65
			cyl.radial_segments = 12
			mat.emission_energy_multiplier = 0.4
			cyl.material = mat
			return cyl
		_:
			# Unknown style — fall back to bullet visual.
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.04
			cyl.bottom_radius = 0.05
			cyl.height = 0.34
			mat.emission_energy_multiplier = 3.0
			cyl.material = mat
			return cyl


## Public entry point — replaces Projectile.create() for non-beam styles.
## Returns true if the projectile was successfully spawned, false if
## the bucket was full (silently dropped — combat doesn't need to know).
func fire(
		from: Vector3,
		to: Vector3,
		style: String,
		color: Color,
		speed: float,
		damage: int,
		target: Node3D,
		shooter: Node3D,
		splash_radius: float,
		splash_damage: int,
		shooter_owner_id: int) -> bool:
	var bucket_key: String = _bucket_key(style, color)
	_ensure_bucket(style, color)
	var bucket_slot: int = _alloc_bucket_slot(bucket_key)
	if bucket_slot < 0:
		return false  # bucket full
	var idx: int = _alloc_slot()
	# Lift fire_y just like the legacy Projectile.create did — barrel-tip
	# y when caller passed a >=0.5 muzzle position; +1u above ground when
	# caller passed a low-y unit-center position.
	var fire_y: float = from.y if from.y >= 0.5 else from.y + 1.0
	var start_pos := Vector3(from.x, fire_y, from.z)
	var target_pos := Vector3(to.x, to.y + 0.8, to.z)
	# Slight random target offset so squad volleys don't perfectly stack.
	target_pos += Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3))
	_state_pos[idx] = start_pos
	_state_start[idx] = start_pos
	_state_target[idx] = target_pos
	_state_speed[idx] = speed
	_state_life[idx] = 0.0
	_state_style[idx] = _style_to_int(style)
	_state_bucket_key[idx] = bucket_key
	_state_bucket_slot[idx] = bucket_slot
	_state_pending_damage[idx] = damage
	_state_pending_target[idx] = target
	_state_pending_shooter[idx] = shooter
	_state_pending_splash_radius[idx] = splash_radius
	_state_pending_splash_damage[idx] = splash_damage
	_state_pending_shooter_owner_id[idx] = shooter_owner_id
	# Per-style flight-time + arc-height setup. Bullet/shell are
	# straight-line, total_flight=0 unused. Missile/mortar/bomb arc
	# parabolically — total_flight scales with distance so the arc
	# always lands on target regardless of fire-to-target distance.
	var dist_to_target: float = start_pos.distance_to(target_pos)
	match style:
		"missile":
			_state_total_flight[idx] = maxf(dist_to_target / 12.0, 0.5)
			_state_arc_height[idx] = clampf(dist_to_target * 0.25, 2.0, 8.0)
		"bomb":
			_state_total_flight[idx] = maxf(dist_to_target / 9.0, 0.7)
			_state_arc_height[idx] = clampf(dist_to_target * 0.10, 0.5, 3.0)
		"mortar":
			_state_total_flight[idx] = maxf(dist_to_target / 11.0, 0.6)
			_state_arc_height[idx] = clampf(dist_to_target * 0.55, 6.0, 14.0)
		"shell":
			# Slower than bullet but straight-line.
			if speed <= 0.0:
				_state_speed[idx] = 70.0
			_state_total_flight[idx] = 0.0
			_state_arc_height[idx] = 0.0
		_:
			_state_total_flight[idx] = 0.0
			_state_arc_height[idx] = 0.0
	# Initial transform write so the projectile is visible on frame 0.
	_write_transform(idx)
	return true


func _style_to_int(style: String) -> int:
	# Compact int encoding for the style. Used by _process to branch to
	# the right per-style update code.
	match style:
		"bullet": return 0
		"missile": return 1
		"shell": return 2
		"mortar": return 3
		"bomb": return 4
		_: return 0


func _write_transform(idx: int) -> void:
	var bucket: MultiMeshInstance3D = _buckets.get(_state_bucket_key[idx]) as MultiMeshInstance3D
	if bucket == null or bucket.multimesh == null:
		return
	var pos: Vector3 = _state_pos[idx]
	var target: Vector3 = _state_target[idx]
	var t := Transform3D()
	t.origin = pos
	if pos.distance_squared_to(target) > 0.0001:
		# looking_at orients the transform's local -Z toward the target.
		# CylinderMesh's long axis is local Y, so the slug renders
		# perpendicular to its travel direction unless we rotate the
		# basis so Y aligns with -Z. Mirrors the legacy
		# `_mesh.rotation.x = -PI / 2` trick the per-Projectile path used
		# (see scripts/projectile.gd before commit c0da14f, the
		# `_create_bullet_mesh` body).
		t = t.looking_at(target, Vector3.UP)
		t.basis = t.basis * Basis(Vector3.RIGHT, -PI * 0.5)
	bucket.multimesh.set_instance_transform(_state_bucket_slot[idx], t)


func _process(delta: float) -> void:
	# Per-projectile update. Bullet path only in this task; missile arc,
	# shell ballistic, mortar, bomb land in later tasks.
	var n: int = _state_pos.size()
	var i: int = 0
	while i < n:
		if _state_style[i] == SLOT_FREE:
			i += 1
			continue
		var style_int: int = _state_style[i]
		match style_int:
			0: _update_bullet(i, delta)
			1, 3, 4: _update_arc(i, delta)  # missile, mortar, bomb
			2: _update_shell(i, delta)
		i += 1


func _update_bullet(idx: int, delta: float) -> void:
	# Lifetime cap (matches legacy Projectile bullet 0.7s cap).
	_state_life[idx] += delta
	if _state_life[idx] > 0.7:
		_free_slot(idx)
		return
	var pos: Vector3 = _state_pos[idx]
	var target: Vector3 = _state_target[idx]
	var to_target: Vector3 = target - pos
	var dist: float = to_target.length()
	var step: float = _state_speed[idx] * delta
	if step >= dist or dist < 0.1:
		_spawn_impact_vfx(idx)
		_free_slot(idx)
		return
	pos += (to_target / dist) * step
	_state_pos[idx] = pos
	_write_transform(idx)


func _spawn_impact_vfx(idx: int) -> void:
	# Hitscan damage already applied at fire-tick by CombatComponent.
	# This function only plays the impact VFX (PEM emit_flash) + audio.
	# For deferred-damage styles (missile/shell/mortar/bomb — landing in
	# later tasks), this also applies the pending_damage payload.
	var pos: Vector3 = _state_pos[idx]
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem != null:
		pem.call("emit_flash", pos, Color(1.0, 0.6, 0.18, 0.9))
	var audio: Node = scene.get_node_or_null("AudioManager")
	if audio != null and audio.has_method("play_weapon_impact"):
		audio.call("play_weapon_impact", pos)


func _update_arc(idx: int, delta: float) -> void:
	# Parabolic arc — XZ lerp + height parabola, same math the legacy
	# Projectile missile path used.
	var prev_life: float = _state_life[idx]
	_state_life[idx] = prev_life + delta
	var t_norm: float = clampf(_state_life[idx] / _state_total_flight[idx], 0.0, 1.0)
	var start: Vector3 = _state_start[idx]
	var target: Vector3 = _state_target[idx]
	var xz: Vector3 = start.lerp(target, t_norm)
	var arc_y: float = _state_arc_height[idx] * 4.0 * t_norm * (1.0 - t_norm)
	var pos := Vector3(xz.x, xz.y + arc_y, xz.z)
	_state_pos[idx] = pos
	_write_transform(idx)
	# Smoke trail — missiles only (not bombs / mortars). Spawn one puff
	# every MISSILE_TRAIL_INTERVAL seconds via integer-bucket compare
	# so we don't need per-projectile timer state. Mirrors the legacy
	# Projectile._spawn_trail_puff cadence (~14 puffs/sec).
	if _state_style[idx] == 1:  # missile
		var prev_bucket: int = int(prev_life / MISSILE_TRAIL_INTERVAL)
		var curr_bucket: int = int(_state_life[idx] / MISSILE_TRAIL_INTERVAL)
		if curr_bucket > prev_bucket:
			_spawn_trail_puff_at(pos)
	if t_norm >= 1.0:
		_apply_pending_damage(idx)
		_spawn_impact_vfx(idx)
		_free_slot(idx)


## Trail-puff lifecycle. Mirrors the legacy Projectile per-puff path
## (cap 60 concurrent so dense salvos don't snowball allocation, see
## commit 9347126). Each puff is MeshInstance3D + SphereMesh +
## StandardMaterial3D + 3-property Tween, free-standing under the
## current scene root (NOT a MultiMesh — puffs need per-instance
## tween-driven alpha/scale animation, which MultiMesh doesn't support
## without a per-instance shader).
const MISSILE_TRAIL_INTERVAL: float = 0.07
const MAX_TRAIL_PUFFS: int = 60
static var _alive_trail_puffs: int = 0


static func _release_trail_puff(puff: Node) -> void:
	if is_instance_valid(puff):
		puff.queue_free()
	_alive_trail_puffs = maxi(_alive_trail_puffs - 1, 0)


func _spawn_trail_puff_at(pos: Vector3) -> void:
	if _alive_trail_puffs >= MAX_TRAIL_PUFFS:
		return
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return
	_alive_trail_puffs += 1
	var puff := MeshInstance3D.new()
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sphere := SphereMesh.new()
	sphere.radius = 0.18
	sphere.height = 0.36
	sphere.radial_segments = 8
	sphere.rings = 4
	puff.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.62, 0.45, 0.65)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	puff.set_surface_override_material(0, mat)
	scene.add_child(puff)
	puff.global_position = pos + Vector3(
		randf_range(-0.15, 0.15),
		randf_range(-0.05, 0.05),
		randf_range(-0.15, 0.15),
	)
	# Drift up + outward as the puff expands, fading to fully transparent.
	var drift: Vector3 = puff.global_position + Vector3(
		randf_range(-0.15, 0.15),
		randf_range(0.4, 0.8),
		randf_range(-0.15, 0.15),
	)
	var tween: Tween = puff.create_tween().set_parallel(true)
	tween.tween_property(puff, "global_position", drift, 0.7)
	tween.tween_property(puff, "scale", Vector3(2.4, 2.4, 2.4), 0.7)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.7)
	tween.chain().tween_callback(Callable(ProjectileManager, "_release_trail_puff").bind(puff))


func _apply_pending_damage(idx: int) -> void:
	# Deferred damage — missile/shell/mortar/bomb apply on impact (not
	# at fire-tick like bullets). Mirrors Projectile._spawn_impact's
	# pending_damage path.
	var dmg: int = _state_pending_damage[idx]
	if dmg <= 0:
		return
	var target: Node3D = _state_pending_target[idx]
	if target != null and is_instance_valid(target):
		var alive: bool = true
		if "alive_count" in target:
			alive = (target.get("alive_count") as int) > 0
		if alive and target.has_method("take_damage"):
			var shooter: Node3D = _state_pending_shooter[idx]
			var attacker: Node3D = shooter if (shooter != null and is_instance_valid(shooter)) else null
			target.call("take_damage", dmg, attacker)
	# Splash. Mirrors the splash branch in Projectile._spawn_impact —
	# SpatialIndex narrow-phase, friend/foe filter, edge-case handling
	# for freed-mid-flight shooter.
	var splash_r: float = _state_pending_splash_radius[idx]
	var splash_d: int = _state_pending_splash_damage[idx]
	if splash_r > 0.0 and splash_d > 0:
		_apply_splash(_state_pos[idx], splash_r, splash_d, _state_pending_target[idx],
				_state_pending_shooter[idx], _state_pending_shooter_owner_id[idx])


func _apply_splash(pos: Vector3, radius: float, dmg: int, primary: Node3D,
		shooter: Node3D, shooter_owner_id: int) -> void:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return
	var idx: SpatialIndex = SpatialIndex.get_instance(scene)
	if idx == null:
		return
	var registry: Node = scene.get_node_or_null("PlayerRegistry")
	var owner_unknown: bool = shooter_owner_id < 0
	var splash_attacker: Node3D = shooter if (shooter != null and is_instance_valid(shooter)) else null
	for raw: Variant in idx.nearby(pos, radius):
		if raw == null or not is_instance_valid(raw):
			continue
		var ent: Node = raw as Node
		if ent == null or ent == primary:
			continue
		if not ent.has_method("take_damage"):
			continue
		var ent_owner: int = (ent.get("owner_id") as int) if "owner_id" in ent else 0
		var hostile: bool = true
		if not owner_unknown and registry != null and registry.has_method("are_enemies"):
			hostile = registry.call("are_enemies", shooter_owner_id, ent_owner)
		elif not owner_unknown:
			hostile = ent_owner != shooter_owner_id
		if not hostile:
			continue
		if "alive_count" in ent and (ent.get("alive_count") as int) <= 0:
			continue
		if pos.distance_to((ent as Node3D).global_position) <= radius:
			ent.call("take_damage", dmg, splash_attacker)


func _update_shell(idx: int, delta: float) -> void:
	# Heavy AP shell — same straight-line movement as bullet but
	# slower. Damage applies at impact (deferred path, like missile).
	_state_life[idx] += delta
	if _state_life[idx] > 1.5:
		_free_slot(idx)
		return
	var pos: Vector3 = _state_pos[idx]
	var target: Vector3 = _state_target[idx]
	var to_target: Vector3 = target - pos
	var dist: float = to_target.length()
	var step: float = _state_speed[idx] * delta
	if step >= dist or dist < 0.1:
		_apply_pending_damage(idx)
		_spawn_impact_vfx(idx)
		_free_slot(idx)
		return
	pos += (to_target / dist) * step
	_state_pos[idx] = pos
	_write_transform(idx)
