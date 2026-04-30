class_name TestArenaController
extends Node3D
## Bootstraps the test arena: player base, AI opponent, resource wiring.

@export var buildable_buildings: Array[BuildingStatResource] = []

@onready var resource_manager: ResourceManager = $ResourceManager as ResourceManager

## Cached so the deferred-bake / re-bake-after-construction can find the region
## without searching the scene tree.
var _nav_region: NavigationRegion3D = null


func _ready() -> void:
	_setup_navigation()
	_setup_alerts()
	_setup_player_registry()
	_setup_player()
	_setup_ai()
	_setup_fuel_deposits()
	_setup_terrain()
	_setup_elevation()
	_setup_skyline_features()
	_setup_neutral_patrols()
	_setup_buildable_buildings()
	# Bake last — once every static collider (HQs, terrain) is in place, so
	# the navmesh actually routes around buildings rather than reporting
	# "navigation finished" the moment a unit collides with one. Synchronous
	# so the first pathfind requests after _ready already hit a real mesh.
	_bake_navmesh_now()


## Per-mode roster definitions. Each entry seeds one PlayerState; AI
## resource managers are wired up later (when `_setup_ai` actually creates
## them). Player IDs 0/1 are team A, 3/4 are team B; 2 is reserved for the
## neutral pseudo-player so existing patrol code keeps working unchanged.
const ROSTER_1V1: Array[Dictionary] = [
	{"id": 0, "team": 0, "color": Color(0.15, 0.45, 0.9, 1.0), "human": true, "name": "Player"},
	{"id": 1, "team": 1, "color": Color(0.85, 0.2, 0.15, 1.0), "human": false, "name": "AI Bravo"},
]
const ROSTER_2V2: Array[Dictionary] = [
	{"id": 0, "team": 0, "color": Color(0.15, 0.45, 0.9, 1.0), "human": true, "name": "Player"},
	{"id": 1, "team": 0, "color": Color(0.2, 0.85, 0.5, 1.0), "human": false, "name": "AI Charlie"},
	{"id": 3, "team": 1, "color": Color(0.85, 0.2, 0.15, 1.0), "human": false, "name": "AI Bravo"},
	{"id": 4, "team": 1, "color": Color(0.95, 0.55, 0.2, 1.0), "human": false, "name": "AI Delta"},
]


func _is_2v2() -> bool:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "mode" in settings:
		var mode: int = settings.get("mode") as int
		# MatchSettingsClass.Mode.TWO_V_TWO == 1
		return mode == 1
	return false


func _current_roster() -> Array[Dictionary]:
	return ROSTER_2V2 if _is_2v2() else ROSTER_1V1


func _setup_player_registry() -> void:
	# Establish the player roster up front so other setups can register
	# their resource managers + faction info as they spawn nodes. The
	# roster is mode-driven, so 2v2 (Pillar 3) and the existing 1v1 share
	# this path.
	var registry := PlayerRegistry.new()
	registry.name = "PlayerRegistry"
	add_child(registry)

	for entry: Dictionary in _current_roster():
		var state: PlayerState = PlayerState.make(
			entry["id"] as int,
			entry["team"] as int,
			entry["color"] as Color,
			entry["human"] as bool,
			entry["name"] as String
		)
		# Local human reuses the existing ResourceManager node; the rest
		# get their managers wired up in `_setup_ai`.
		var rm: Node = resource_manager if entry["human"] else null
		registry.register(state, rm)

	# Neutral pseudo-player — patrols, deposit guards.
	registry.register(
		PlayerState.make(
			PlayerRegistry.NEUTRAL_PLAYER_ID,
			PlayerRegistry.NEUTRAL_TEAM_ID,
			Color(0.85, 0.7, 0.3, 1.0),
			false,
			"Neutral"
		),
		null
	)


func _setup_alerts() -> void:
	# AlertManager is an event hub — created early so any system spawned later
	# can find it via get_node_or_null("AlertManager"). Owned by the arena
	# so it lives the same lifetime as the match.
	var mgr := AlertManager.new()
	mgr.name = "AlertManager"
	add_child(mgr)


func _setup_navigation() -> void:
	# Flat manual navmesh — the bake-from-colliders version proved fragile
	# (infinite WorldBoundaryShape3D + multi-layer walkable surfaces +
	# async bake timing all combined to occasionally produce a degenerate
	# navmesh that left every unit reporting "navigation finished" the
	# moment a path query was issued). Until that's debugged properly,
	# keep the simple ±150 quad and rely on stuck-rescue + RVO obstacles
	# for the cases the bake was supposed to solve.
	var nav_region := NavigationRegion3D.new()
	nav_region.name = "NavigationRegion"

	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = PackedVector3Array([
		Vector3(-150, 0, -150),
		Vector3(150, 0, -150),
		Vector3(150, 0, 150),
		Vector3(-150, 0, 150),
	])
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2]))
	nav_mesh.add_polygon(PackedInt32Array([0, 2, 3]))

	nav_region.navigation_mesh = nav_mesh
	add_child(nav_region)
	_nav_region = nav_region


func _bake_navmesh_now() -> void:
	# No-op while the manual navmesh is in use. Kept so callers from the
	# bake-era still wire up cleanly.
	pass


func request_navmesh_rebake() -> void:
	# Same — a manual navmesh doesn't need re-baking when buildings appear.
	pass


## HQ placement — both modes use opposite corners around the map center
## (z = 0). 1v1: player on north edge, AI on south edge, equidistant. 2v2:
## team A on the north edge (player west, ally east), team B mirrored on
## the south edge.
const HQ_POSITIONS_1V1: Dictionary = {
	0: Vector3(0.0, 0.0, 110.0),
	1: Vector3(0.0, 0.0, -110.0),
}
const HQ_POSITIONS_2V2: Dictionary = {
	0: Vector3(-60.0, 0.0, 100.0),
	1: Vector3(60.0, 0.0, 100.0),
	3: Vector3(-60.0, 0.0, -100.0),
	4: Vector3(60.0, 0.0, -100.0),
}


func _hq_position_for(player_id: int) -> Vector3:
	if _is_2v2():
		return HQ_POSITIONS_2V2.get(player_id, Vector3.ZERO) as Vector3
	return HQ_POSITIONS_1V1.get(player_id, Vector3(0.0, 0.0, -110.0)) as Vector3


func _setup_player() -> void:
	# Mark the HQ as already constructed
	var hq: Building = $PlayerHQ as Building
	var hq_offset: Vector3 = Vector3.ZERO
	if hq:
		hq.owner_id = 0
		hq.is_constructed = true
		hq.resource_manager = resource_manager
		# Move the player HQ to its mode-specific corner — the .tscn places
		# it at world origin for editor convenience, but real matches want
		# both bases pushed to opposite ends of the map.
		var new_pos: Vector3 = _hq_position_for(0)
		hq_offset = new_pos - hq.global_position
		hq.global_position = new_pos
		hq._apply_placeholder_shape()

	# Shift the static starter Units by the same delta so they cluster
	# around the relocated HQ instead of getting stranded at world origin.
	if hq_offset.length_squared() > 0.0001:
		var units_node: Node = get_node_or_null("Units")
		if units_node:
			for child: Node in units_node.get_children():
				if child is Node3D:
					(child as Node3D).global_position += hq_offset

	# Snap the camera so the match opens looking at the player's base
	# instead of wherever the .tscn happened to leave the camera node.
	# Reuses RTSCamera's pivot fields (same way the H hotkey does).
	var cam: Camera3D = get_viewport().get_camera_3d() if get_viewport() else null
	if cam and hq:
		var focus: Vector3 = Vector3(hq.global_position.x, 0.0, hq.global_position.z)
		cam.set("_pivot", focus)
		cam.set("_target_pivot", focus)

	# Wire resource manager to all player buildings
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		var building: Building = node as Building
		if building and building.owner_id == 0:
			building.resource_manager = resource_manager

	resource_manager.update_power()


func _setup_ai() -> void:
	# Spawn one AI HQ + starter army + AIController per non-human entry in
	# the roster. The 1v1 path lights up player_id=1 only; the 2v2 path
	# lights up the ally (1) plus two enemies (3, 4).
	for entry: Dictionary in _current_roster():
		if entry["human"] as bool:
			continue
		_spawn_ai_player(entry["id"] as int, entry["name"] as String)


func _spawn_ai_player(player_id: int, display_name: String) -> void:
	# Resource manager — uses a name unique per player so multi-AI 2v2
	# scenes don't clash. Legacy code that asks for "AIResourceManager"
	# still finds the player_id=1 manager since it gets that exact name.
	var ai_res := ResourceManager.new()
	ai_res.name = ("AIResourceManager" if player_id == 1 else "AIResourceManager_%d" % player_id)
	ai_res.salvage = 500
	add_child(ai_res)

	var registry: PlayerRegistry = $PlayerRegistry as PlayerRegistry
	if registry:
		registry.register(registry.get_state(player_id), ai_res)

	# HQ
	var hq_stats: BuildingStatResource = load("res://resources/buildings/headquarters.tres") as BuildingStatResource
	if not hq_stats:
		return
	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	var ai_hq: Building = building_scene.instantiate() as Building
	ai_hq.stats = hq_stats
	ai_hq.owner_id = player_id
	ai_hq.resource_manager = ai_res
	ai_hq.global_position = _hq_position_for(player_id)
	add_child(ai_hq)
	ai_hq.is_constructed = true
	ai_hq._apply_placeholder_shape()

	# Starter army anchored relative to the HQ. The unit offsets are
	# laid out in `fwd` (toward map center) and `right` (perpendicular)
	# axes — earlier code used world-space x/z offsets, which for the
	# 2v2 ally at the (60, 100) corner reliably parked one starter unit
	# inside the HQ collision (corner spawn → world +x went BACK into
	# the building). Forward/right space puts every starter clearly out
	# in open ground regardless of HQ corner.
	var ratchet_stats: UnitStatResource = load("res://resources/units/anvil_ratchet.tres") as UnitStatResource
	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource
	var hq_pos: Vector3 = ai_hq.global_position
	var fwd: Vector3 = Vector3.ZERO - hq_pos
	fwd.y = 0.0
	if fwd.length_squared() > 0.0001:
		fwd = fwd.normalized()
	else:
		fwd = Vector3(0.0, 0.0, 1.0)
	# 90° right of fwd (still XZ-plane).
	var right: Vector3 = Vector3(-fwd.z, 0.0, fwd.x)
	# Anchor a generous 8u in front of the HQ — outside the 6u
	# footprint plus ~2u clearance for the unit's own collision capsule.
	var anchor: Vector3 = hq_pos + fwd * 8.0
	_spawn_ai_unit(ratchet_stats, anchor - right * 3.0, player_id)
	_spawn_ai_unit(ratchet_stats, anchor + right * 3.0, player_id)
	_spawn_ai_unit(rook_stats, anchor + fwd * 3.0 - right * 2.0, player_id)
	_spawn_ai_unit(rook_stats, anchor + fwd * 3.0 + right * 2.0, player_id)

	# Controller
	var ai_script: GDScript = load("res://scripts/ai_controller.gd") as GDScript
	var ai_ctrl: Node = ai_script.new()
	ai_ctrl.name = "AIController_%d" % player_id
	ai_ctrl.set("owner_id", player_id)
	add_child(ai_ctrl)


func _spawn_ai_unit(unit_stats: UnitStatResource, pos: Vector3, player_id: int = 1) -> void:
	if not unit_stats:
		return
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	var unit: Unit = unit_scene.instantiate() as Unit
	unit.stats = unit_stats
	unit.owner_id = player_id
	var units_node: Node = get_node_or_null("Units")
	if units_node:
		units_node.add_child(unit)
	else:
		add_child(unit)
	unit.global_position = pos


func _setup_fuel_deposits() -> void:
	var deposit_script: GDScript = load("res://scripts/fuel_deposit.gd") as GDScript
	if not deposit_script:
		return

	var positions: Array[Vector3] = (
		_deposit_positions_2v2() if _is_2v2() else _deposit_positions_1v1()
	)

	for pos: Vector3 in positions:
		var deposit: Node3D = deposit_script.new()
		deposit.global_position = pos
		add_child(deposit)


func _deposit_positions_1v1() -> Array[Vector3]:
	# Foundry Belt 1v1 layout. Symmetric around z = 0 AND x = 0 — the
	# previous version put the back-door deposit only on the east flank,
	# which gave the player at z = +110 a faster claim than the AI at
	# z = -110 to anything west of center. Now both flanks have a
	# back-door so map dominance is genuinely a both-flanks decision.
	return [
		Vector3(28, 0, 80),     # Player safe-side (north)
		Vector3(-28, 0, -80),   # AI safe-side (south)
		Vector3(35, 0, 0),      # Mid-east (contested)
		Vector3(-35, 0, 0),     # Mid-west (contested)
		Vector3(95, 0, 0),      # East back-door
		Vector3(-95, 0, 0),     # West back-door (mirror)
	]


func _deposit_positions_2v2() -> Array[Vector3]:
	# 2v2 layout — each of the four corner spawns gets a near-home deposit
	# of its own so neither team feels starved on opening, plus a single
	# central contested deposit that's the dominant mid-game objective.
	# Total 5 (matches the V2 spec's "4-5 in 2v2" range).
	return [
		Vector3(-30, 0, 70),    # Player NW safe
		Vector3(30, 0, 70),     # Ally NE safe
		Vector3(-30, 0, -70),   # Enemy SW safe
		Vector3(30, 0, -70),    # Enemy SE safe
		Vector3(0, 0, 0),       # Central contested — the hot zone
	]


func _setup_terrain() -> void:
	# Foundry Belt terrain: rusted ruins and rock outcrops scattered through
	# the contested mid-map. Each piece blocks pathing (collision_layer 4 like
	# buildings, so units' mask=5 covers them) and carries a NavigationObstacle3D
	# so units route around it via RVO instead of grinding into the side.
	#
	# Positions deliberately leave the home-base lanes and deposit approaches
	# open so the early game stays clean; cover lives in the mid lane where
	# fights actually happen.
	# Mirrored across z = 0 so neither side gets a cover advantage. Also
	# corner-fill ruins in NW / NE / SW / SE so the map reads as an
	# inhabited industrial belt rather than a flat empty plate.
	var pieces: Array[Dictionary] = [
		# Mid-line cover — two rocks flanking the central z-axis lane.
		{"pos": Vector3(-15, 0, 10), "size": Vector3(4.0, 2.5, 3.0), "kind": "rock"},
		{"pos": Vector3(15, 0, -10), "size": Vector3(3.5, 2.0, 4.0), "kind": "rock"},
		# Mid-flank ruins.
		{"pos": Vector3(48, 0, 15), "size": Vector3(3.0, 3.5, 3.0), "kind": "ruin"},
		{"pos": Vector3(-48, 0, -15), "size": Vector3(3.5, 3.0, 3.5), "kind": "ruin"},
		# Player-side flank features.
		{"pos": Vector3(60, 0, 35), "size": Vector3(2.5, 2.0, 2.5), "kind": "rock"},
		{"pos": Vector3(-60, 0, 30), "size": Vector3(3.0, 2.5, 3.0), "kind": "ruin"},
		# AI-side flank features (mirrored z values).
		{"pos": Vector3(50, 0, -40), "size": Vector3(3.0, 2.0, 3.5), "kind": "rock"},
		{"pos": Vector3(-55, 0, -30), "size": Vector3(4.0, 3.0, 3.0), "kind": "ruin"},
		# East back-door chokepoint at x ≈ 85.
		{"pos": Vector3(85, 0, 6), "size": Vector3(8.0, 4.0, 8.0), "kind": "ruin"},
		{"pos": Vector3(85, 0, -6), "size": Vector3(8.0, 4.0, 8.0), "kind": "ruin"},
		# West back-door chokepoint mirror at x ≈ -85 — same narrow gap
		# leading to the west back-door deposit at (-95, 0).
		{"pos": Vector3(-85, 0, 6), "size": Vector3(8.0, 4.0, 8.0), "kind": "ruin"},
		{"pos": Vector3(-85, 0, -6), "size": Vector3(8.0, 4.0, 8.0), "kind": "ruin"},
		# Corner fillers — break up the visual emptiness of the four map
		# corners without affecting the strategic lanes. Smaller and
		# pushed near the camera-bound limits.
		{"pos": Vector3(120, 0, 120), "size": Vector3(4.5, 3.0, 4.5), "kind": "ruin"},
		{"pos": Vector3(-120, 0, 120), "size": Vector3(5.0, 3.0, 4.0), "kind": "ruin"},
		{"pos": Vector3(120, 0, -120), "size": Vector3(4.0, 3.0, 5.0), "kind": "ruin"},
		{"pos": Vector3(-120, 0, -120), "size": Vector3(4.5, 2.5, 4.5), "kind": "ruin"},
		# Mid-edge filler — the long horizontal flanks need something
		# between the safe deposits and the corners.
		{"pos": Vector3(110, 0, 50), "size": Vector3(3.0, 2.5, 3.5), "kind": "rock"},
		{"pos": Vector3(-110, 0, 55), "size": Vector3(3.5, 2.0, 3.0), "kind": "rock"},
		{"pos": Vector3(110, 0, -50), "size": Vector3(3.5, 2.5, 3.0), "kind": "rock"},
		{"pos": Vector3(-110, 0, -45), "size": Vector3(3.0, 2.0, 3.5), "kind": "rock"},
		# Scrap-pile terrain: low + wide debris fields. Different
		# silhouette from rocks/ruins (flatter, more chunks per piece)
		# so the same area can mix variety.
		{"pos": Vector3(40, 0, 50), "size": Vector3(5.0, 1.0, 5.0), "kind": "scrap_pile"},
		{"pos": Vector3(-40, 0, 50), "size": Vector3(4.5, 1.2, 5.5), "kind": "scrap_pile"},
		{"pos": Vector3(40, 0, -50), "size": Vector3(4.5, 1.0, 5.0), "kind": "scrap_pile"},
		{"pos": Vector3(-40, 0, -50), "size": Vector3(5.0, 1.2, 4.5), "kind": "scrap_pile"},
		{"pos": Vector3(0, 0, 50), "size": Vector3(6.0, 0.9, 4.5), "kind": "scrap_pile"},
		{"pos": Vector3(0, 0, -65), "size": Vector3(5.5, 1.0, 5.0), "kind": "scrap_pile"},
	]
	for piece: Dictionary in pieces:
		_spawn_terrain_piece(piece["pos"] as Vector3, piece["size"] as Vector3, piece["kind"] as String)
	# Boulder clusters — three close-spaced small rocks that read as a
	# weathered formation rather than a single big shape.
	var cluster_centers: Array[Vector3] = [
		Vector3(85, 0, 25),
		Vector3(-85, 0, 25),
		Vector3(85, 0, -25),
		Vector3(-85, 0, -25),
	]
	for c: Vector3 in cluster_centers:
		_spawn_boulder_cluster(c)


func _spawn_boulder_cluster(center: Vector3) -> void:
	# Three small boulders within 4u of each other. Each is its own
	# StaticBody3D so unit pathing can thread between them, and each
	# uses the regular `_spawn_terrain_piece` rock path so it picks up
	# all the rotation / color / debris-chunk variation.
	for i: int in 3:
		var ang: float = float(i) / 3.0 * TAU + randf_range(0.0, 0.7)
		var radius: float = randf_range(1.6, 2.4)
		var off := Vector3(cos(ang) * radius, 0.0, sin(ang) * radius)
		var size := Vector3(
			randf_range(1.6, 2.4),
			randf_range(1.2, 1.8),
			randf_range(1.6, 2.4),
		)
		_spawn_terrain_piece(center + off, size, "rock")


func _spawn_terrain_piece(pos: Vector3, piece_size: Vector3, kind: String) -> void:
	var root := StaticBody3D.new()
	root.collision_layer = 4
	root.collision_mask = 0
	root.position = Vector3(pos.x, piece_size.y * 0.5, pos.z)
	# Random Y rotation so a row of identical-spec pieces doesn't read as
	# copy-pasted cubes. The collision shape rotates with the root, so
	# the AABB still covers the same footprint.
	root.rotation.y = randf_range(0.0, TAU)
	root.add_to_group("terrain")
	add_child(root)

	# Hard collision matching the visual extent.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = piece_size
	shape.shape = box
	root.add_child(shape)

	# Per-kind palette with per-instance jitter so adjacent pieces read as
	# distinct objects rather than a mass of one tone.
	var base_color: Color
	if kind == "ruin":
		base_color = Color(0.32, 0.26, 0.22, 1.0)
	elif kind == "scrap_pile":
		# Rust-orange palette — clearly "metal debris", not "stone".
		base_color = Color(0.36, 0.22, 0.14, 1.0)
	else:
		base_color = Color(0.28, 0.27, 0.24, 1.0)
	var jitter: float = 0.05
	base_color.r = clampf(base_color.r + randf_range(-jitter, jitter), 0.0, 1.0)
	base_color.g = clampf(base_color.g + randf_range(-jitter, jitter), 0.0, 1.0)
	base_color.b = clampf(base_color.b + randf_range(-jitter, jitter), 0.0, 1.0)

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = piece_size
	mesh_inst.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color
	mat.roughness = randf_range(0.85, 0.98)
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

	# Scrap piles read as "field of broken metal" — many small chunks
	# scattered across the footprint, no single dominant block. Rocks /
	# ruins keep the existing one-debris-chunk shape so the silhouette
	# stays grouped.
	if kind == "scrap_pile":
		var chunk_count: int = randi_range(5, 8)
		for i: int in chunk_count:
			var chunk := MeshInstance3D.new()
			var chunk_box := BoxMesh.new()
			var cs: float = randf_range(0.25, 0.55) * piece_size.x * 0.5
			chunk_box.size = Vector3(
				cs,
				randf_range(0.35, 0.95) * piece_size.y,
				cs * randf_range(0.7, 1.3),
			)
			chunk.mesh = chunk_box
			chunk.position = Vector3(
				randf_range(-piece_size.x * 0.4, piece_size.x * 0.4),
				piece_size.y * 0.5 + chunk_box.size.y * 0.4,
				randf_range(-piece_size.z * 0.4, piece_size.z * 0.4),
			)
			chunk.rotation = Vector3(
				randf_range(-0.4, 0.4),
				randf_range(0.0, TAU),
				randf_range(-0.4, 0.4),
			)
			var chunk_mat := StandardMaterial3D.new()
			# Mix darkened and rust-bright tones so the pile reads as
			# weathered metal rather than uniform colored.
			if randf() < 0.4:
				chunk_mat.albedo_color = base_color.lerp(Color(0.6, 0.32, 0.14, 1.0), 0.4)
			else:
				chunk_mat.albedo_color = base_color.darkened(randf_range(0.0, 0.3))
			chunk_mat.roughness = mat.roughness
			chunk.material_override = chunk_mat
			root.add_child(chunk)
	else:
		# Single debris chunk on top — random size + rotation, slightly
		# darker shade. Adds vertical silhouette variation and breaks the
		# perfect-cube read without changing the collision footprint.
		var chunk := MeshInstance3D.new()
		var chunk_box := BoxMesh.new()
		var cs: float = piece_size.x * randf_range(0.35, 0.55)
		chunk_box.size = Vector3(cs, randf_range(0.4, 0.8) * piece_size.y, cs * randf_range(0.7, 1.1))
		chunk.mesh = chunk_box
		chunk.position = Vector3(
			randf_range(-piece_size.x * 0.18, piece_size.x * 0.18),
			piece_size.y * 0.5 + chunk_box.size.y * 0.4,
			randf_range(-piece_size.z * 0.18, piece_size.z * 0.18),
		)
		chunk.rotation = Vector3(
			randf_range(-0.18, 0.18),
			randf_range(0.0, TAU),
			randf_range(-0.18, 0.18),
		)
		var chunk_mat := StandardMaterial3D.new()
		chunk_mat.albedo_color = base_color.darkened(randf_range(0.05, 0.18))
		chunk_mat.roughness = mat.roughness
		chunk.material_override = chunk_mat
		root.add_child(chunk)

	# RVO obstacle so units steer around instead of grinding into the side.
	# Radius is the larger horizontal half-extent + a small margin.
	var obstacle := NavigationObstacle3D.new()
	obstacle.radius = maxf(piece_size.x, piece_size.z) * 0.5 + 0.6
	obstacle.height = piece_size.y
	obstacle.avoidance_enabled = true
	root.add_child(obstacle)


func _setup_elevation() -> void:
	# Foundry Belt elevation pass — the spec calls for a high-ground zone
	# (V2 §"Map 1") and the map currently reads as a flat sheet. Three
	# walkable rises at strategic positions: a central plateau between the
	# mid deposits (the "high-ground zone"), one platform overlooking the
	# back-door chokepoint, and one north of mid that gives the player a
	# defensible push position on their side of the map.
	#
	# Heights are picked so units can step on/off via `agent_max_climb`
	# (set to 0.7) — no rotated ramp geometry needed. Each piece is on
	# layer 1 (walkable surface) so the navmesh bake parses it as nav-
	# walkable rather than carving it as an obstacle.
	#
	# Avoid x∈[-3, 3], z∈[-3, 8] so player HQ + starting unit cluster
	# stay clear; same on the AI side at z=-120.
	var pieces: Array[Dictionary] = [
		# Northern plateau (player-side mid).
		{"pos": Vector3(0.0, 0.3, 25.0), "size": Vector3(18.0, 0.6, 12.0)},
		# Southern plateau (AI-side mirror) — reduces the previous
		# north-only asymmetry.
		{"pos": Vector3(0.0, 0.3, -75.0), "size": Vector3(16.0, 0.6, 10.0)},
		# East ridge near the back-door chokepoint.
		{"pos": Vector3(70.0, 0.3, 0.0), "size": Vector3(8.0, 0.6, 14.0)},
		# West ridge mirror near the new west back-door.
		{"pos": Vector3(-70.0, 0.3, 0.0), "size": Vector3(8.0, 0.6, 14.0)},
	]
	for piece: Dictionary in pieces:
		_spawn_elevation_piece(piece["pos"] as Vector3, piece["size"] as Vector3)


func _spawn_elevation_piece(pos: Vector3, piece_size: Vector3) -> void:
	# Visual rise that physically blocks pathing — same collision treatment
	# as terrain pieces (layer 4). Until the navmesh bake gets sorted out
	# we can't make the top walkable, so for now these read as low-rise
	# obstacles units route around. The high-ground combat bonus still
	# applies to anyone who *does* end up at a higher Y (e.g. firing from
	# a building roof later).
	var root := StaticBody3D.new()
	root.collision_layer = 4
	root.collision_mask = 0
	root.position = pos
	root.add_to_group("elevation")
	add_child(root)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = piece_size
	shape.shape = box
	root.add_child(shape)

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = piece_size
	mesh_inst.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	# Slightly lighter than the ground albedo so the rise reads visually.
	mat.albedo_color = Color(0.22, 0.21, 0.19, 1.0)
	mat.roughness = 0.92
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)


func _setup_skyline_features() -> void:
	# Tall decorative refinery stacks / broken towers / chimney columns
	# scattered around the map. Non-walkable obstacles (collision_layer 4
	# like terrain) — purely about giving the silhouette a vertical read
	# from the RTS camera angle so the map doesn't look flat.
	#
	# Positions are off the central battle lanes (deposits / chokepoints
	# are still clear) and skewed toward the edges so they fill empty
	# corners rather than block routing.
	var pieces: Array[Dictionary] = [
		# Pair of refinery stacks flanking the apex wreck.
		{"pos": Vector3(20.0, 0.0, -45.0), "kind": "stack", "height": 8.5},
		{"pos": Vector3(-22.0, 0.0, -45.0), "kind": "stack", "height": 7.5},
		# Broken tower north-east of the player base.
		{"pos": Vector3(80.0, 0.0, 90.0), "kind": "tower", "height": 6.5},
		# Mirror near the AI base.
		{"pos": Vector3(-80.0, 0.0, -90.0), "kind": "tower", "height": 6.0},
		# Chimney cluster at the deep east edge.
		{"pos": Vector3(125.0, 0.0, 30.0), "kind": "chimneys", "height": 7.0},
		{"pos": Vector3(125.0, 0.0, -30.0), "kind": "chimneys", "height": 7.5},
		# Smaller pylons along the long flanks (visual bookends).
		{"pos": Vector3(105.0, 0.0, 75.0), "kind": "pylon", "height": 5.5},
		{"pos": Vector3(-105.0, 0.0, 75.0), "kind": "pylon", "height": 5.0},
		{"pos": Vector3(105.0, 0.0, -75.0), "kind": "pylon", "height": 5.5},
		{"pos": Vector3(-105.0, 0.0, -75.0), "kind": "pylon", "height": 5.0},
	]
	for piece: Dictionary in pieces:
		_spawn_skyline_feature(
			piece["pos"] as Vector3,
			piece["kind"] as String,
			piece["height"] as float,
		)


func _spawn_skyline_feature(pos: Vector3, kind: String, height: float) -> void:
	# Each feature is a single StaticBody3D parent on layer 4 with a
	# narrow base collider — units bump into the trunk and route around.
	# Tall visual mass is built from MeshInstance3D children that sit
	# above the collider, so units can't stand on top but the silhouette
	# reads as a real structure.
	var root := StaticBody3D.new()
	root.collision_layer = 4
	root.collision_mask = 0
	root.position = pos
	root.rotation.y = randf_range(0.0, TAU)
	root.add_to_group("terrain")
	add_child(root)

	# Trunk collision (kept short relative to total height — the visual
	# mass on top is decoration only).
	var trunk_radius: float = 1.4 if kind != "pylon" else 0.9
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(trunk_radius * 1.6, height * 0.4, trunk_radius * 1.6)
	shape.shape = box
	shape.position.y = height * 0.2
	root.add_child(shape)

	# Base color palette per kind — cooler / darker than terrain rocks.
	var base_color: Color
	match kind:
		"stack":
			base_color = Color(0.20, 0.18, 0.16, 1.0)
		"tower":
			base_color = Color(0.24, 0.21, 0.19, 1.0)
		"chimneys":
			base_color = Color(0.18, 0.16, 0.14, 1.0)
		_:  # pylon
			base_color = Color(0.22, 0.20, 0.18, 1.0)
	# Subtle per-instance jitter.
	base_color.r = clampf(base_color.r + randf_range(-0.04, 0.04), 0.0, 1.0)
	base_color.g = clampf(base_color.g + randf_range(-0.04, 0.04), 0.0, 1.0)
	base_color.b = clampf(base_color.b + randf_range(-0.04, 0.04), 0.0, 1.0)

	if kind == "stack":
		_build_skyline_stack(root, base_color, height)
	elif kind == "tower":
		_build_skyline_tower(root, base_color, height)
	elif kind == "chimneys":
		_build_skyline_chimneys(root, base_color, height)
	else:
		_build_skyline_pylon(root, base_color, height)


func _build_skyline_stack(root: Node3D, color: Color, height: float) -> void:
	# A wide brick base + tall thinner column + cap ring — reads as an
	# old foundry chimney / refinery stack.
	var base := MeshInstance3D.new()
	var base_box := BoxMesh.new()
	base_box.size = Vector3(2.4, height * 0.18, 2.4)
	base.mesh = base_box
	base.position.y = height * 0.09
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = color.darkened(0.15)
	base_mat.roughness = 0.95
	base.material_override = base_mat
	root.add_child(base)
	var column := MeshInstance3D.new()
	var column_cyl := CylinderMesh.new()
	column_cyl.top_radius = 0.7
	column_cyl.bottom_radius = 0.95
	column_cyl.height = height * 0.78
	column.mesh = column_cyl
	column.position.y = height * 0.18 + column_cyl.height * 0.5
	var col_mat := StandardMaterial3D.new()
	col_mat.albedo_color = color
	col_mat.roughness = 0.92
	column.material_override = col_mat
	root.add_child(column)
	# Cap ring at the top — slight emissive so distant skyline catches the eye.
	var cap := MeshInstance3D.new()
	var cap_cyl := CylinderMesh.new()
	cap_cyl.top_radius = 1.0
	cap_cyl.bottom_radius = 1.0
	cap_cyl.height = 0.25
	cap.mesh = cap_cyl
	cap.position.y = height * 0.96
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = color.darkened(0.3)
	cap_mat.emission_enabled = true
	cap_mat.emission = Color(1.0, 0.45, 0.18)
	cap_mat.emission_energy_multiplier = 0.6
	cap.material_override = cap_mat
	root.add_child(cap)


func _build_skyline_tower(root: Node3D, color: Color, height: float) -> void:
	# Square broken tower — tapered with a partial-height upper section
	# leaning slightly off-axis (reads as collapsed roof).
	var trunk := MeshInstance3D.new()
	var trunk_box := BoxMesh.new()
	trunk_box.size = Vector3(2.2, height * 0.6, 2.2)
	trunk.mesh = trunk_box
	trunk.position.y = height * 0.3
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = color
	trunk_mat.roughness = 0.95
	trunk.material_override = trunk_mat
	root.add_child(trunk)
	var upper := MeshInstance3D.new()
	var upper_box := BoxMesh.new()
	upper_box.size = Vector3(1.6, height * 0.32, 1.6)
	upper.mesh = upper_box
	upper.position = Vector3(0.18, height * 0.6 + upper_box.size.y * 0.5, 0.0)
	upper.rotation.z = deg_to_rad(8.0)
	var upper_mat := StandardMaterial3D.new()
	upper_mat.albedo_color = color.darkened(0.1)
	upper_mat.roughness = 0.95
	upper.material_override = upper_mat
	root.add_child(upper)
	# Detail crenellations / broken edge.
	for i: int in 4:
		var ang: float = float(i) / 4.0 * TAU
		var c := MeshInstance3D.new()
		var cb := BoxMesh.new()
		cb.size = Vector3(0.4, 0.5, 0.4)
		c.mesh = cb
		c.position = Vector3(cos(ang) * 1.0, height * 0.62, sin(ang) * 1.0)
		c.material_override = trunk_mat
		root.add_child(c)


func _build_skyline_chimneys(root: Node3D, color: Color, height: float) -> void:
	# Cluster of three chimneys at slightly different heights / offsets
	# — reads as an old industrial complex.
	var positions: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.6, 0.0, 0.4),
		Vector3(-1.4, 0.0, -0.6),
	]
	var heights: Array[float] = [height, height * 0.78, height * 0.88]
	for i: int in positions.size():
		var ch := MeshInstance3D.new()
		var ch_cyl := CylinderMesh.new()
		ch_cyl.top_radius = 0.45
		ch_cyl.bottom_radius = 0.6
		ch_cyl.height = heights[i]
		ch.mesh = ch_cyl
		ch.position = positions[i] + Vector3(0.0, heights[i] * 0.5, 0.0)
		var ch_mat := StandardMaterial3D.new()
		ch_mat.albedo_color = color.darkened(randf_range(0.0, 0.2))
		ch_mat.roughness = 0.95
		ch.material_override = ch_mat
		root.add_child(ch)


func _build_skyline_pylon(root: Node3D, color: Color, height: float) -> void:
	# Narrow lattice-ish power pylon — central post + four leg struts +
	# cross-arms near the top. Implemented with simple boxes since lines
	# don't render reliably from the RTS camera distance.
	var post := MeshInstance3D.new()
	var post_box := BoxMesh.new()
	post_box.size = Vector3(0.35, height, 0.35)
	post.mesh = post_box
	post.position.y = height * 0.5
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = color
	post_mat.roughness = 0.95
	post.material_override = post_mat
	root.add_child(post)
	# Four leg struts angled outward at the base.
	for i: int in 4:
		var ang: float = float(i) / 4.0 * TAU + 0.78
		var leg := MeshInstance3D.new()
		var leg_box := BoxMesh.new()
		leg_box.size = Vector3(0.12, height * 0.45, 0.12)
		leg.mesh = leg_box
		leg.position = Vector3(cos(ang) * 0.9, height * 0.22, sin(ang) * 0.9)
		leg.rotation.x = -0.25 * sin(ang)
		leg.rotation.z = 0.25 * cos(ang)
		leg.material_override = post_mat
		root.add_child(leg)
	# Cross-arms near the top.
	for offset_y: float in [height * 0.7, height * 0.85]:
		var arm := MeshInstance3D.new()
		var arm_box := BoxMesh.new()
		arm_box.size = Vector3(2.0, 0.12, 0.18)
		arm.mesh = arm_box
		arm.position.y = offset_y
		arm.material_override = post_mat
		root.add_child(arm)


func _setup_neutral_patrols() -> void:
	# Foundry Belt 1v1 patrol layout (per SCOPE_VERTICAL_SLICE_V2.md §"Map 1"):
	# - 1 Light patrol on each safe-side deposit (a Rook stand-in until we
	#   have a proper neutral roster).
	# - 1 Medium patrol on each contested mid-deposit (a Hound).
	#
	# Patrols don't move on their own — they're stationary and rely on the
	# combat component's auto-engage to defend their deposit. Neutrals share
	# owner_id = 2, which makes both player and AI see them as enemies (and
	# they don't shoot each other).
	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource
	var hound_stats: UnitStatResource = load("res://resources/units/anvil_hound.tres") as UnitStatResource
	var bulwark_stats: UnitStatResource = load("res://resources/units/anvil_bulwark.tres") as UnitStatResource

	# Patrol unit, position offset from the deposit center so harvesters
	# don't spawn directly inside the patrol's collision.
	# Patrols sit one unit-radius off each deposit so harvesters don't
	# immediately overlap the guard's collision capsule. Layout differs
	# per mode because the deposit positions do.
	var patrols: Array[Dictionary]
	if _is_2v2():
		patrols = [
			# Each corner safe deposit gets a Light patrol — fast to clear
			# but enough that a wandering Crawler can't waltz straight in.
			{"stats": rook_stats, "pos": Vector3(-30 + 4, 0, 70)},
			{"stats": rook_stats, "pos": Vector3(30 - 4, 0, 70)},
			{"stats": rook_stats, "pos": Vector3(-30 + 4, 0, -70)},
			{"stats": rook_stats, "pos": Vector3(30 - 4, 0, -70)},
			# Central deposit — Heavy patrol (Bulwark). It's the dominant
			# 2v2 objective; clearing it is a real combat-power investment.
			{"stats": bulwark_stats, "pos": Vector3(4, 0, 4)},
			# Apex wreck guard, same as 1v1.
			{"stats": bulwark_stats, "pos": Vector3(4, 0, -45)},
		]
	else:
		patrols = [
			{"stats": rook_stats, "pos": Vector3(28 + 4, 0, 80)},     # Player safe
			{"stats": rook_stats, "pos": Vector3(-28 - 4, 0, -80)},   # AI safe
			{"stats": hound_stats, "pos": Vector3(35 + 4, 0, 4)},     # Mid-east contested
			{"stats": hound_stats, "pos": Vector3(-35 - 4, 0, 4)},    # Mid-west contested
			{"stats": bulwark_stats, "pos": Vector3(95 + 4, 0, 4)},   # East back-door
			{"stats": bulwark_stats, "pos": Vector3(-95 - 4, 0, 4)},  # West back-door
			# Apex wreck guard — Heavy patrol (Bulwark) sitting on the central
			# scar; mid-late game objective per V2 §"Map 1".
			{"stats": bulwark_stats, "pos": Vector3(4, 0, -45)},
		]
	for entry: Dictionary in patrols:
		_spawn_neutral_unit(entry["stats"] as UnitStatResource, entry["pos"] as Vector3)


func _spawn_neutral_unit(unit_stats: UnitStatResource, pos: Vector3) -> void:
	if not unit_stats:
		return
	var unit_scene: PackedScene = load("res://scenes/unit.tscn") as PackedScene
	var unit: Unit = unit_scene.instantiate() as Unit
	unit.stats = unit_stats
	unit.owner_id = 2
	# Mark this neutral as a patrol — `home_position` triggers the -20%
	# aggro modifier and the return-to-spawn behaviour in CombatComponent.
	unit.home_position = pos
	var units_node: Node = get_node_or_null("Units")
	if units_node:
		units_node.add_child(unit)
	else:
		add_child(unit)
	unit.global_position = pos


func _setup_buildable_buildings() -> void:
	var selection_mgr: SelectionManager = $SelectionManager as SelectionManager
	if not selection_mgr:
		return

	if buildable_buildings.is_empty():
		var stat_paths: Array[String] = [
			"res://resources/buildings/basic_foundry.tres",
			"res://resources/buildings/advanced_foundry.tres",
			"res://resources/buildings/salvage_yard.tres",
			"res://resources/buildings/basic_generator.tres",
			"res://resources/buildings/basic_armory.tres",
			"res://resources/buildings/gun_emplacement.tres",
		]
		for path: String in stat_paths:
			var stat: BuildingStatResource = load(path) as BuildingStatResource
			if stat:
				buildable_buildings.append(stat)
	selection_mgr.set_buildable_buildings(buildable_buildings)
