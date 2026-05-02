class_name Wreck
extends StaticBody3D
## A destroyed unit's wreckage. Yields salvage when harvested by workers.

## Total salvage this wreck contains.
@export var salvage_value: int = 50

## Salvage remaining to be extracted.
var salvage_remaining: int = 0

## Microchip payload — non-zero only on satellite-crash piles.
## Workers grant the chips on the first extraction tick that
## actually pulls salvage; chips are an all-or-nothing pop, not
## a per-extract trickle.
@export var microchip_value: int = 0
var microchip_remaining: int = 0

## Set true on satellite piles so the spawner can give them a
## distinct visual (taller wreckage + warm violet emissive core).
@export var is_satellite: bool = false

## Visual size based on unit class.
var wreck_size: Vector3 = Vector3(1.0, 0.5, 1.0)


func _ready() -> void:
	add_to_group("wrecks")
	salvage_remaining = salvage_value
	microchip_remaining = microchip_value
	collision_layer = 8

	_build_wreck_visuals()
	if is_satellite:
		_build_satellite_landmark()

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = wreck_size
	col.shape = shape
	col.position.y = wreck_size.y / 2.0
	add_child(col)


## Class buckets keyed off the wreck's horizontal extent. Each class gets a
## distinct base color, accent color, and number of debris chunks so a
## glance reads "small scrap pile" vs "Bulwark hull plate" vs "Apex
## carcass" without needing the size cue alone.
##
## These are `var` rather than `const` because GDScript's compile-time
## const evaluator chokes on `Color()` constructor calls inside Dictionary
## literals — and that parse failure used to cascade through `Building`
## (and every class that referenced it) all the way to `BuilderComponent`.
var _WRECK_CLASS_LIGHT: Dictionary = {
	"max_extent": 1.0,
	"base":   Color(0.22, 0.15, 0.09, 1.0),
	"accent": Color(0.55, 0.30, 0.13, 1.0),
	"chunks": 2,
}
var _WRECK_CLASS_MEDIUM: Dictionary = {
	"max_extent": 1.6,
	"base":   Color(0.20, 0.13, 0.08, 1.0),
	"accent": Color(0.62, 0.34, 0.16, 1.0),
	"chunks": 3,
}
var _WRECK_CLASS_HEAVY: Dictionary = {
	"max_extent": 2.2,
	"base":   Color(0.18, 0.12, 0.07, 1.0),
	"accent": Color(0.70, 0.40, 0.18, 1.0),
	"chunks": 4,
}
var _WRECK_CLASS_APEX: Dictionary = {
	"max_extent": 1000000.0,
	"base":   Color(0.22, 0.14, 0.08, 1.0),
	"accent": Color(0.85, 0.55, 0.20, 1.0),
	"chunks": 14,
	"apex": true,
}


func _classify() -> Dictionary:
	var ext: float = maxf(wreck_size.x, wreck_size.z)
	if ext < _WRECK_CLASS_LIGHT["max_extent"]:
		return _WRECK_CLASS_LIGHT
	if ext < _WRECK_CLASS_MEDIUM["max_extent"]:
		return _WRECK_CLASS_MEDIUM
	if ext < _WRECK_CLASS_HEAVY["max_extent"]:
		return _WRECK_CLASS_HEAVY
	return _WRECK_CLASS_APEX


func _build_wreck_visuals() -> void:
	var spec: Dictionary = _classify()
	var base_color: Color = spec["base"] as Color
	var accent_color: Color = spec["accent"] as Color
	var chunk_count: int = spec["chunks"] as int

	# Tilt the whole wreck a few degrees off-axis so it doesn't read as a
	# tidy cube on the ground. Random per instance.
	rotation.y = randf_range(0.0, TAU)

	# Main twisted-hull mass — a flattened box with a slight roll/pitch so
	# corners poke up unevenly.
	var hull := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = wreck_size
	hull.mesh = box
	hull.position.y = wreck_size.y * 0.5
	hull.rotation.x = randf_range(-0.18, 0.18)
	hull.rotation.z = randf_range(-0.18, 0.18)
	hull.set_surface_override_material(0, _make_wreck_material(base_color))
	add_child(hull)

	# Debris chunks — small boxes scattered around the main hull at random
	# rotations. Some get the rust-accent material to break up the dark
	# silhouette and read as scorched/torn metal.
	var max_extent: float = maxf(wreck_size.x, wreck_size.z)
	for i: int in chunk_count:
		var chunk := MeshInstance3D.new()
		var chunk_box := BoxMesh.new()
		var sx: float = randf_range(0.18, 0.32) * max_extent
		var sy: float = randf_range(0.20, 0.45) * wreck_size.y * 1.6
		var sz: float = randf_range(0.18, 0.32) * max_extent
		chunk_box.size = Vector3(sx, sy, sz)
		chunk.mesh = chunk_box
		var off_radius: float = max_extent * randf_range(0.35, 0.55)
		var ang: float = randf_range(0.0, TAU)
		chunk.position = Vector3(
			cos(ang) * off_radius,
			sy * 0.5 + randf_range(0.0, wreck_size.y * 0.4),
			sin(ang) * off_radius,
		)
		chunk.rotation = Vector3(
			randf_range(-0.5, 0.5),
			randf_range(0.0, TAU),
			randf_range(-0.5, 0.5),
		)
		var color: Color = accent_color if randf() < 0.4 else base_color
		# Occasional darker scorch chunk so the palette has 3 readable tones.
		if randf() < 0.25:
			color = color.darkened(0.4)
		chunk.set_surface_override_material(0, _make_wreck_material(color))
		add_child(chunk)

	# Apex carcass — extra landmark elements so the wreck reads as a
	# real downed capital mech, not just a slightly-bigger debris pile.
	# A jutting spire (broken antenna mast / spine), a smoldering core
	# with warm emissive light, and a scorch ring on the ground.
	if spec.get("apex", false):
		_build_apex_landmark(base_color, accent_color, max_extent)


func _build_apex_landmark(base_color: Color, accent_color: Color, max_extent: float) -> void:
	# Bent spire — tall vertical shard angled off-vertical so it reads
	# as a snapped antenna or broken spinal column rather than a flag.
	var spire := MeshInstance3D.new()
	var spire_box := BoxMesh.new()
	var spire_h: float = wreck_size.y * 3.2 + max_extent * 0.4
	spire_box.size = Vector3(0.65, spire_h, 0.55)
	spire.mesh = spire_box
	spire.position = Vector3(
		randf_range(-max_extent * 0.10, max_extent * 0.10),
		wreck_size.y * 0.5 + spire_h * 0.5,
		randf_range(-max_extent * 0.10, max_extent * 0.10),
	)
	spire.rotation = Vector3(
		randf_range(-0.18, 0.18),
		randf_range(0.0, TAU),
		randf_range(0.20, 0.42) * (1.0 if randf() < 0.5 else -1.0),
	)
	spire.set_surface_override_material(0, _make_wreck_material(base_color.darkened(0.15)))
	add_child(spire)

	# Cap on top — a torn corner chunk hanging off the spire so it
	# silhouettes as a broken structure, not a clean rod.
	var cap := MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	cap_box.size = Vector3(1.4, 0.6, 1.0)
	cap.mesh = cap_box
	cap.position = Vector3(0, spire_h * 0.5 - 0.1, 0)
	cap.rotation = Vector3(randf_range(-0.4, 0.4), randf_range(0.0, TAU), randf_range(-0.4, 0.4))
	cap.set_surface_override_material(0, _make_wreck_material(accent_color))
	spire.add_child(cap)

	# Smoldering core — emissive cube partially buried in the hull.
	# A faint warm light point gives the wreck a "still hot" read at
	# distance, separating it from background rocks.
	var ember := MeshInstance3D.new()
	var ember_box := BoxMesh.new()
	ember_box.size = Vector3(1.2, 0.6, 1.2)
	ember.mesh = ember_box
	ember.position = Vector3(
		randf_range(-max_extent * 0.18, max_extent * 0.18),
		wreck_size.y * 0.55,
		randf_range(-max_extent * 0.18, max_extent * 0.18),
	)
	var ember_mat := StandardMaterial3D.new()
	ember_mat.albedo_color = Color(0.05, 0.03, 0.02, 1.0)
	ember_mat.emission_enabled = true
	ember_mat.emission = Color(1.0, 0.45, 0.12, 1.0)
	ember_mat.emission_energy_multiplier = 1.4
	ember_mat.roughness = 0.85
	ember.set_surface_override_material(0, ember_mat)
	add_child(ember)

	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.55, 0.20, 1.0)
	glow.light_energy = 1.8
	glow.omni_range = max_extent * 1.6
	glow.position = Vector3(ember.position.x, wreck_size.y * 0.9, ember.position.z)
	add_child(glow)

	# Scorch ring — flat disc-like dark mark on the ground out past
	# the wreck footprint, drawing the eye toward this spot from the
	# minimap and from any forward camera angle.
	var ring := MeshInstance3D.new()
	var ring_mesh := QuadMesh.new()
	var ring_extent: float = max_extent * 1.6
	ring_mesh.size = Vector2(ring_extent * 2.0, ring_extent * 2.0)
	ring.mesh = ring_mesh
	ring.rotation.x = -PI * 0.5
	ring.position.y = 0.02
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.06, 0.04, 0.03, 0.88)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring_mat.no_depth_test = false
	ring_mat.roughness = 1.0
	ring.set_surface_override_material(0, ring_mat)
	add_child(ring)


func _make_wreck_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	# Same grime overlay as the unit/building chassis. A wreck IS the
	# chassis of a destroyed mech, so it should look like a battered,
	# weathered version of what it was — not a flat-shaded primitive.
	# Higher uv1_scale than units because wrecks are smaller; this keeps
	# the wear pattern at roughly the same physical size.
	m.albedo_texture = SharedTextures.get_metal_wear_texture()
	m.uv1_offset = Vector3(randf(), randf(), 0.0)
	m.uv1_scale = Vector3(2.4, 2.4, 1.0)
	m.roughness = 0.95
	m.metallic = 0.15
	return m


## Extract salvage. Returns the amount actually extracted.
func extract(amount: int) -> int:
	var extracted: int = mini(amount, salvage_remaining)
	salvage_remaining -= extracted
	if salvage_remaining <= 0:
		queue_free()
	return extracted


## Pulls and clears the microchip payload (if any). Workers call
## this once on a successful harvest pickup so chips drop in a
## single lump rather than tricking out per-extract. Returns the
## number of chips claimed (0 when the wreck has none / they were
## already collected).
func claim_microchips() -> int:
	if microchip_remaining <= 0:
		return 0
	var out: int = microchip_remaining
	microchip_remaining = 0
	return out


func _build_satellite_landmark() -> void:
	## Visible "satellite crashed here" marker — a leaning antenna
	## spar + a violet emissive core + an OmniLight so the pile
	## reads as a high-value drop from any zoom. Sits on top of the
	## existing wreck geometry rather than replacing it.
	var max_extent: float = maxf(wreck_size.x, wreck_size.z)

	# Bent satellite mast — leaning thin pillar.
	var mast := MeshInstance3D.new()
	var mast_box := BoxMesh.new()
	var mast_h: float = wreck_size.y * 4.0 + 0.6
	mast_box.size = Vector3(0.18, mast_h, 0.18)
	mast.mesh = mast_box
	mast.position = Vector3(
		max_extent * 0.18,
		wreck_size.y * 0.4 + mast_h * 0.5,
		max_extent * -0.10,
	)
	mast.rotation = Vector3(
		randf_range(0.18, 0.30),
		randf_range(0.0, TAU),
		randf_range(-0.20, 0.20),
	)
	mast.set_surface_override_material(0, _make_wreck_material(Color(0.10, 0.10, 0.14, 1.0)))
	add_child(mast)

	# Dish near the top of the mast — slightly tilted disc reading
	# as an antenna dish that took a hit on landing.
	var dish := MeshInstance3D.new()
	var dish_cyl := CylinderMesh.new()
	dish_cyl.top_radius = 0.55
	dish_cyl.bottom_radius = 0.42
	dish_cyl.height = 0.10
	dish_cyl.radial_segments = 16
	dish.mesh = dish_cyl
	dish.position = Vector3(0, mast_h * 0.45, 0)
	dish.rotation.x = deg_to_rad(40.0)
	var dish_mat := _make_wreck_material(Color(0.16, 0.13, 0.18, 1.0))
	dish.set_surface_override_material(0, dish_mat)
	mast.add_child(dish)

	# Glowing violet core poking out of the wreck — the chip
	# payload visual cue.
	var core := MeshInstance3D.new()
	var core_box := BoxMesh.new()
	core_box.size = Vector3(0.55, 0.40, 0.55)
	core.mesh = core_box
	core.position = Vector3(0, wreck_size.y * 0.65, 0)
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = Color(0.10, 0.05, 0.16, 1.0)
	core_mat.emission_enabled = true
	core_mat.emission = Color(0.78, 0.42, 1.0, 1.0)
	core_mat.emission_energy_multiplier = 2.6
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core.set_surface_override_material(0, core_mat)
	add_child(core)

	# Real violet light point so the pile reads at minimap distance
	# and at low zoom — different colour from the apex amber so the
	# player learns the cue.
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.78, 0.42, 1.0, 1.0)
	glow.light_energy = 1.6
	glow.omni_range = max_extent * 3.0 + 4.0
	glow.position = Vector3(0, wreck_size.y * 1.0, 0)
	add_child(glow)

	# Microchip shards scattered around the wreck — small angular
	# violet-emissive crystals on the ground so the player reads
	# "this pile contains chips" at a glance, matching the chip
	# resource's violet identity colour. Count scales with the
	# pile's chip payload so a richer drop visibly carries more.
	var shard_count: int = 5 + microchip_value * 2
	var shard_mat := StandardMaterial3D.new()
	shard_mat.albedo_color = Color(0.45, 0.20, 0.65, 1.0)
	shard_mat.emission_enabled = true
	shard_mat.emission = Color(0.78, 0.42, 1.0, 1.0)
	shard_mat.emission_energy_multiplier = 1.8
	shard_mat.metallic = 0.4
	shard_mat.roughness = 0.25
	for s_i: int in shard_count:
		var shard := MeshInstance3D.new()
		var shard_box := BoxMesh.new()
		var sw: float = randf_range(0.16, 0.28)
		var sh: float = randf_range(0.10, 0.22)
		var sd: float = randf_range(0.16, 0.28)
		shard_box.size = Vector3(sw, sh, sd)
		shard.mesh = shard_box
		var off_radius: float = max_extent * randf_range(0.55, 1.05)
		var ang: float = randf_range(0.0, TAU)
		shard.position = Vector3(
			cos(ang) * off_radius,
			sh * 0.5 + randf_range(0.0, 0.05),
			sin(ang) * off_radius,
		)
		shard.rotation = Vector3(
			randf_range(-0.4, 0.4),
			randf_range(0.0, TAU),
			randf_range(-0.4, 0.4),
		)
		shard.set_surface_override_material(0, shard_mat)
		add_child(shard)
	add_child(glow)


## Create a wreck from a destroyed unit's stats.
static func create_from_unit(unit_stats: UnitStatResource, pos: Vector3) -> Wreck:
	var wreck := Wreck.new()
	# Units yield 30-40% of salvage cost
	wreck.salvage_value = int(unit_stats.cost_salvage * 0.35)
	wreck.salvage_remaining = wreck.salvage_value

	# Size based on unit class
	match unit_stats.unit_class:
		&"engineer":
			wreck.wreck_size = Vector3(0.8, 0.3, 0.8)
		&"light":
			wreck.wreck_size = Vector3(1.0, 0.4, 1.0)
		&"medium":
			wreck.wreck_size = Vector3(1.5, 0.5, 1.5)
		&"heavy":
			wreck.wreck_size = Vector3(2.0, 0.6, 2.0)
		_:
			wreck.wreck_size = Vector3(1.0, 0.4, 1.0)

	# Use local `position` here — the wreck isn't in the tree yet, and the
	# caller parents it to the scene root (identity transform), so local
	# == global. Avoids the !is_inside_tree() warning that was firing on
	# every unit death (a high-frequency event during combat).
	wreck.position = pos
	return wreck
