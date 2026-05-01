class_name AmmoDump
extends StaticBody3D
## Destructible explosive crate cluster. Sits on the map as a hard
## obstacle — units bump into it like terrain — but it has HP and any
## weapon hit reduces it. When destroyed it detonates for splash damage
## across a 6u radius, knocking any nearby units / buildings down with
## it. Designed for Foundry Belt's contested mid: turns a stray missile
## into a tactical play (bait the enemy past it, then shoot the dump).

const MAX_HP: int = 220
## Explosion is meant to be a CATASTROPHIC event when a player
## successfully shoots one — radius covers a meaningful chunk of map
## and damage one-shots most light/medium squads caught in the blast.
## Was 6u / 90 dmg which read as a small pop; bumped to make ammo
## dumps a real strategic objective.
const EXPLOSION_RADIUS: float = 14.0
const EXPLOSION_DAMAGE: int = 280
## Owner sentinel — dumps are never on a player's team. Treated as
## neutral so combat hostility checks already see them as targetable.
const NEUTRAL_OWNER: int = 2

var current_hp: int = MAX_HP
var owner_id: int = NEUTRAL_OWNER
var alive_count: int = 1   # combat compat — looks like a 1-member squad
## Combat auto-targeting opt-out. Ammo dumps stay in the "buildings"
## group so a right-click can still target them explicitly, but the
## CombatComponent auto-acquire loop checks this flag and skips
## targets where it's false — otherwise every player squad walking
## past would chip the dump down without the player ever asking for
## the explosion.
var auto_targetable: bool = false
var _exploded: bool = false
var _materials: Array[StandardMaterial3D] = []
var _flash_timer: float = 0.0


func _ready() -> void:
	add_to_group("ammo_dumps")
	add_to_group("buildings")  # so combat targeting + auto-acquire pick it up
	collision_layer = 4        # terrain layer — units mask=5 collides with it
	collision_mask = 0
	_build_visuals()
	_build_collision()


func _build_visuals() -> void:
	# Cluster of 3-4 stacked crates with brass + olive tones. Each crate
	# is a separate mesh so the silhouette reads as discrete boxes.
	var crate_count: int = randi_range(3, 4)
	for i: int in crate_count:
		var crate := MeshInstance3D.new()
		var box := BoxMesh.new()
		var sx: float = randf_range(0.85, 1.15)
		var sz: float = randf_range(0.85, 1.15)
		var sy: float = randf_range(0.55, 0.78)
		box.size = Vector3(sx, sy, sz)
		crate.mesh = box
		# Stack with slight horizontal jitter so the pile leans naturally.
		var stack_y: float = sy * 0.5 + float(i) * randf_range(0.55, 0.75)
		crate.position = Vector3(
			randf_range(-0.2, 0.2),
			stack_y,
			randf_range(-0.2, 0.2),
		)
		crate.rotation.y = randf_range(-0.2, 0.2)

		var mat := StandardMaterial3D.new()
		# Olive-drab base with a faint amber emission seam — reads as
		# munitions / ordnance from the RTS camera distance.
		mat.albedo_color = Color(0.36, 0.32, 0.18, 1.0)
		mat.albedo_texture = SharedTextures.get_metal_wear_texture()
		mat.uv1_offset = Vector3(randf(), randf(), 0.0)
		mat.uv1_scale = Vector3(1.4, 1.4, 1.0)
		mat.roughness = 0.85
		mat.metallic = 0.3
		mat.emission_enabled = true
		mat.emission = Color(0.7, 0.32, 0.10, 1.0)
		mat.emission_energy_multiplier = 0.18
		crate.set_surface_override_material(0, mat)
		add_child(crate)
		_materials.append(mat)

	# Brass warning band across the largest crate so it reads as
	# explicitly explosive, not just generic crates.
	var band := MeshInstance3D.new()
	var band_box := BoxMesh.new()
	band_box.size = Vector3(1.05, 0.06, 1.05)
	band.mesh = band_box
	band.position.y = 0.4
	var band_mat := StandardMaterial3D.new()
	band_mat.albedo_color = Color(0.9, 0.7, 0.18, 1.0)
	band_mat.emission_enabled = true
	band_mat.emission = Color(1.0, 0.65, 0.18, 1.0)
	band_mat.emission_energy_multiplier = 0.7
	band_mat.metallic = 0.6
	band_mat.roughness = 0.4
	band.set_surface_override_material(0, band_mat)
	add_child(band)


func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.4, 1.8, 2.4)
	col.shape = shape
	col.position.y = 0.9
	add_child(col)


func _process(delta: float) -> void:
	# Damage flash countdown — pulse the emission brighter for a beat
	# after each hit so the player gets feedback without tracking HP.
	if _flash_timer > 0.0:
		_flash_timer -= delta
		var pulse: float = clampf(_flash_timer / 0.18, 0.0, 1.0)
		for mat: StandardMaterial3D in _materials:
			if mat:
				mat.emission_energy_multiplier = lerp(0.18, 0.9, pulse)


func take_damage(amount: int, _attacker: Node3D = null) -> void:
	if _exploded:
		return
	current_hp -= amount
	_flash_timer = 0.18
	if current_hp <= 0:
		_explode()


func _explode() -> void:
	if _exploded:
		return
	_exploded = true
	alive_count = 0
	var pos: Vector3 = global_position

	# Splash damage to any unit / building / Crawler within
	# EXPLOSION_RADIUS. Linear falloff with distance so units right next
	# to the dump take full damage and units at the edge take ~30%.
	var groups: Array[String] = ["units", "buildings", "crawlers"]
	for g: String in groups:
		for node: Node in get_tree().get_nodes_in_group(g):
			if not is_instance_valid(node) or node == self:
				continue
			if not node.has_method("take_damage"):
				continue
			var n3: Node3D = node as Node3D
			if not n3:
				continue
			var d: float = pos.distance_to(n3.global_position)
			if d > EXPLOSION_RADIUS:
				continue
			var falloff: float = clampf(1.0 - (d / EXPLOSION_RADIUS) * 0.7, 0.3, 1.0)
			node.take_damage(int(EXPLOSION_DAMAGE * falloff), self)

	# Visual + audio explosion. Reuses unit.gd's _spawn_flash_at by
	# spawning a generic flash node directly — keeps this script
	# self-contained without reaching into Unit internals.
	_spawn_explosion_vfx(pos)
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_impact"):
		audio.play_weapon_impact(pos)
	queue_free()


func _spawn_explosion_vfx(pos: Vector3) -> void:
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	# Big explosion → multi-flash GPU particle burst + smoke cloud +
	# sparks. Volume scales with EXPLOSION_RADIUS so a bigger blast
	# reads as a bigger boom — flash count, smoke volume, and spark
	# count all bumped to match the new 14u radius (was 6u).
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if pem:
		# Center fireball — dense flash cluster at the dump's core.
		pem.emit_flash(pos + Vector3(0, 1.5, 0), Color(1.0, 0.55, 0.15, 1.0), 28)
		# Secondary flashes scattered out toward the explosion radius
		# so the player's eye can SEE the radius — without these the
		# damage area was invisible.
		for i: int in 16:
			var ang: float = float(i) / 16.0 * TAU
			var r: float = EXPLOSION_RADIUS * randf_range(0.35, 0.85)
			var off2 := Vector3(cos(ang) * r, randf_range(0.8, 2.4), sin(ang) * r)
			pem.emit_flash(pos + off2, Color(1.0, 0.45, 0.12, 1.0), 1)
		# Big rolling smoke cloud — 30 puffs spread across the radius
		# rising and drifting outward. Persists long enough for the
		# player to register where the boom went off.
		for i: int in 30:
			var ang2: float = randf() * TAU
			var r2: float = randf_range(0.5, EXPLOSION_RADIUS * 0.9)
			var smoke_pos: Vector3 = pos + Vector3(cos(ang2) * r2, randf_range(0.4, 2.5), sin(ang2) * r2)
			var rise := Vector3(cos(ang2) * 0.6, randf_range(2.0, 3.5), sin(ang2) * 0.6)
			pem.emit_smoke(smoke_pos, rise, Color(0.35, 0.22, 0.16, 0.85))
		# Sparks — heavy spray to sell the detonation.
		pem.emit_spark(pos + Vector3(0, 1.0, 0), 30)

	# Brief omni light so the flash actually illuminates nearby units.
	# Bigger range + brighter to match the larger explosion radius.
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.18, 1.0)
	light.light_energy = 9.0
	light.omni_range = EXPLOSION_RADIUS * 1.8
	scene.add_child(light)
	light.global_position = pos + Vector3(0, 1.5, 0)
	var ltween := light.create_tween()
	ltween.tween_property(light, "light_energy", 0.0, 0.7).set_ease(Tween.EASE_OUT)
	ltween.tween_callback(light.queue_free)


## Combat compatibility — the auto-target / forced-target logic checks
## these like it does on units.
func get_total_hp() -> int:
	return maxi(current_hp, 0)
