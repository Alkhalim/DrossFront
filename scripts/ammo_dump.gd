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
## Damage tripled per balance pass so ammo dumps actually delete a
## squad caught at full radius rather than chip-damaging them.
const EXPLOSION_RADIUS: float = 14.0
const EXPLOSION_DAMAGE: int = 840
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

	# Explosive warning sign on top of the stack -- a stylized
	# detonation symbol (yellow triangle around a red "burst" star)
	# so the player reads at a glance that this pile is volatile.
	# The sign sits above the brass band so it's the first thing
	# the eye lands on when the camera passes over.
	_build_warning_sign()
	# Scatter a handful of dynamite sticks around the base -- helps
	# the dump read as 'pile of unsecured ordnance' from a distance,
	# not just a generic crate stack.
	_build_dynamite_scatter()


func _build_warning_sign() -> void:
	# Lift the placard well clear of the tallest possible crate stack.
	# 4 crates at the upper-end heights stack to ~2.4u; 2.9u keeps the
	# triangle floating above instead of clipping into the top crate.
	var sign_root := Node3D.new()
	sign_root.position = Vector3(0.0, 2.9, 0.0)
	add_child(sign_root)
	# Slim mounting pole so the placard reads as held aloft on a
	# stake instead of drifting in mid-air.
	var pole := MeshInstance3D.new()
	var pole_box := BoxMesh.new()
	pole_box.size = Vector3(0.06, 1.6, 0.06)
	pole.mesh = pole_box
	pole.position = Vector3(0.0, -0.8, 0.0)
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.16, 0.14, 0.12, 1.0)
	pole_mat.roughness = 0.7
	pole.set_surface_override_material(0, pole_mat)
	sign_root.add_child(pole)
	# Hazard-yellow triangular plate. Layer order is critical here:
	# every layer is billboarded (camera-facing), and Godot composites
	# +Z as 'closer to camera' after the billboard rotation. The
	# previous build put the black border in FRONT of the plate (z =
	# +0.02) so the placard read as a solid grey-black triangle from
	# in-game; spokes were BEHIND the plate (z = -0.04) so the red
	# burst never showed either. Layered now: border behind, plate
	# in the middle, spokes in front.
	var tri_size: float = 0.55
	# Black hazard outline -- behind the plate.
	var border := MeshInstance3D.new()
	var border_mesh := PrismMesh.new()
	border_mesh.size = Vector3(tri_size * 2.18, tri_size * 1.85, 0.05)
	border.mesh = border_mesh
	border.position.z = -0.04
	var border_mat := StandardMaterial3D.new()
	border_mat.albedo_color = Color(0.05, 0.05, 0.05, 1.0)
	border_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	border.set_surface_override_material(0, border_mat)
	sign_root.add_child(border)
	# Yellow plate -- middle layer.
	var plate := MeshInstance3D.new()
	var plate_mesh := PrismMesh.new()
	plate_mesh.size = Vector3(tri_size * 2.0, tri_size * 1.7, 0.06)
	plate.mesh = plate_mesh
	plate.position.z = 0.0
	var plate_mat := StandardMaterial3D.new()
	plate_mat.albedo_color = Color(1.0, 0.85, 0.10, 1.0)
	plate_mat.emission_enabled = true
	plate_mat.emission = Color(1.0, 0.80, 0.10, 1.0)
	plate_mat.emission_energy_multiplier = 1.4
	plate_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	plate.set_surface_override_material(0, plate_mat)
	sign_root.add_child(plate)
	# Red detonation burst -- in front of the plate.
	for i: int in 6:
		var spoke := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.08, tri_size * 1.0, 0.02)
		spoke.mesh = sb
		spoke.rotation.z = float(i) / 6.0 * PI  # 6 spokes = 30deg apart
		spoke.position.z = 0.05  # in front of the plate
		var spoke_mat := StandardMaterial3D.new()
		spoke_mat.albedo_color = Color(0.95, 0.12, 0.10, 1.0)
		spoke_mat.emission_enabled = true
		spoke_mat.emission = Color(1.0, 0.20, 0.15, 1.0)
		spoke_mat.emission_energy_multiplier = 2.0
		spoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		spoke.set_surface_override_material(0, spoke_mat)
		sign_root.add_child(spoke)


func _build_dynamite_scatter() -> void:
	## A handful of red dynamite sticks (with little tan fuses) lying
	## around the base of the crate cluster. Tilts + positions are
	## randomized so each dump's scatter looks unique.
	var stick_count: int = randi_range(5, 8)
	for i: int in stick_count:
		var stick := MeshInstance3D.new()
		var stick_cyl := CylinderMesh.new()
		stick_cyl.top_radius = 0.07
		stick_cyl.bottom_radius = 0.07
		stick_cyl.height = randf_range(0.32, 0.46)
		stick_cyl.radial_segments = 8
		stick.mesh = stick_cyl
		var stick_mat := StandardMaterial3D.new()
		stick_mat.albedo_color = Color(0.78, 0.16, 0.10, 1.0)
		stick_mat.roughness = 0.7
		stick.set_surface_override_material(0, stick_mat)
		# Lay the stick on its side (cylinder default points +Y, rotate
		# 90 about Z so it lays flat).
		stick.rotation = Vector3(
			randf_range(-0.10, 0.10),
			randf_range(0.0, TAU),
			deg_to_rad(90.0) + randf_range(-0.20, 0.20),
		)
		var radius: float = randf_range(1.30, 1.65)
		var ang: float = randf_range(0.0, TAU)
		stick.position = Vector3(cos(ang) * radius, stick_cyl.top_radius + 0.01, sin(ang) * radius)
		add_child(stick)
		# Tan fuse poking out of one end -- short slim cylinder.
		var fuse := MeshInstance3D.new()
		var fuse_cyl := CylinderMesh.new()
		fuse_cyl.top_radius = 0.018
		fuse_cyl.bottom_radius = 0.018
		fuse_cyl.height = 0.16
		fuse_cyl.radial_segments = 6
		fuse.mesh = fuse_cyl
		var fuse_mat := StandardMaterial3D.new()
		fuse_mat.albedo_color = Color(0.78, 0.62, 0.32, 1.0)
		fuse.set_surface_override_material(0, fuse_mat)
		# Sit the fuse at one end of the stick, angled up a little.
		fuse.position.y = stick_cyl.height * 0.5 + 0.05
		fuse.rotation.x = randf_range(-0.40, 0.40)
		stick.add_child(fuse)


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
	# Buildings take an additional 3x multiplier -- the dump's shrapnel
	# tears through structural plating, so a contested-mid dump going up
	# next to a Foundry should genuinely threaten the building.
	const BUILDING_DAMAGE_MULT: float = 3.0
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
			var dmg: float = float(EXPLOSION_DAMAGE) * falloff
			if g == "buildings" and not (node is AmmoDump):
				dmg *= BUILDING_DAMAGE_MULT
			node.take_damage(int(dmg), self)

	# Visual + audio explosion. Reuses unit.gd's _spawn_flash_at by
	# spawning a generic flash node directly — keeps this script
	# self-contained without reaching into Unit internals.
	_spawn_explosion_vfx(pos)
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_huge_explosion"):
		# Ammo dump going up is a CATASTROPHIC event — play the huge
		# explosion bank rather than the small impact clang the dump
		# was using before.
		audio.play_huge_explosion(pos)
	elif audio and audio.has_method("play_weapon_impact"):
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

	# Fireball -- a large emissive sphere that scales out from a tight
	# core to ~70% of the damage radius over 0.45s, then fades. Sells
	# the "this is a CATASTROPHIC blast" beat better than the flash
	# particles alone (which read as point sparks at distance).
	var fireball := MeshInstance3D.new()
	fireball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fb_mesh := SphereMesh.new()
	fb_mesh.radius = 1.0
	fb_mesh.height = 2.0
	fb_mesh.radial_segments = 24
	fb_mesh.rings = 12
	fireball.mesh = fb_mesh
	var fb_mat := StandardMaterial3D.new()
	fb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fb_mat.albedo_color = Color(1.0, 0.55, 0.15, 0.85)
	fb_mat.emission_enabled = true
	fb_mat.emission = Color(1.0, 0.55, 0.15, 1.0)
	fb_mat.emission_energy_multiplier = 2.0
	fb_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fireball.set_surface_override_material(0, fb_mat)
	fireball.scale = Vector3.ONE * 0.6
	scene.add_child(fireball)
	fireball.global_position = pos + Vector3(0.0, 1.5, 0.0)
	var fb_target_scale: float = EXPLOSION_RADIUS * 0.7
	var fb_tween := fireball.create_tween()
	fb_tween.set_parallel(true)
	fb_tween.tween_property(fireball, "scale", Vector3.ONE * fb_target_scale, 0.45).set_ease(Tween.EASE_OUT)
	fb_tween.tween_property(fb_mat, "albedo_color:a", 0.0, 0.55).set_ease(Tween.EASE_IN).set_delay(0.10)
	fb_tween.chain().tween_callback(fireball.queue_free)

	# Shockwave -- a flat ring expanding along the ground out to
	# EXPLOSION_RADIUS over 0.55s. Gives the player a precise visual
	# of the damage area: anything inside the ring at the moment of
	# detonation took damage. Uses a TorusMesh that scales radially.
	var ring := MeshInstance3D.new()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.85
	ring_mesh.outer_radius = 1.0
	ring_mesh.rings = 36
	ring_mesh.ring_segments = 6
	ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(1.0, 0.75, 0.25, 0.90)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(1.0, 0.75, 0.25, 1.0)
	ring_mat.emission_energy_multiplier = 1.8
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, ring_mat)
	# TorusMesh's natural orientation is YZ-axis; rotate to lay flat
	# on XZ ground plane.
	ring.rotation.x = -PI * 0.5
	scene.add_child(ring)
	ring.global_position = pos + Vector3(0.0, 0.15, 0.0)
	# Scale the torus so its OUTER radius matches EXPLOSION_RADIUS at
	# end; starts at 1u outer radius (so visually a tiny ring at the
	# centre) and ramps out.
	var ring_target_scale: float = EXPLOSION_RADIUS
	var ring_tween := ring.create_tween()
	ring_tween.set_parallel(true)
	ring_tween.tween_property(ring, "scale", Vector3(ring_target_scale, ring_target_scale, ring_target_scale), 0.55).set_ease(Tween.EASE_OUT)
	ring_tween.tween_property(ring_mat, "albedo_color:a", 0.0, 0.55).set_ease(Tween.EASE_IN).set_delay(0.20)
	ring_tween.chain().tween_callback(ring.queue_free)


## Combat compatibility — the auto-target / forced-target logic checks
## these like it does on units.
func get_total_hp() -> int:
	return maxi(current_hp, 0)
