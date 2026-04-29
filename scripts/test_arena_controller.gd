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
	# Bake-from-source-geometry navmesh. The arena's static colliders on
	# layer 5 (1 = ground, 4 = buildings/terrain) are walked at bake time:
	# the ground slab below provides a finite walkable surface, buildings
	# and terrain pieces carve out their footprints. This is what lets the
	# pathfinder route units AROUND structures instead of straight into a
	# wall and giving up.
	var nav_region := NavigationRegion3D.new()
	nav_region.name = "NavigationRegion"

	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = 0.5
	nav_mesh.cell_height = 0.25
	# agent_radius bigger than the largest unit's collision radius (Bulwark
	# squad ≈ 1.4) so the bake leaves enough clearance around buildings
	# that even the heaviest squad fits through the carved corridor.
	nav_mesh.agent_radius = 1.5
	nav_mesh.agent_height = 2.0
	# Bumped from 0.5 to 0.7 so units can step onto the 0.6-unit elevated
	# platforms placed by `_setup_elevation`. Anything taller than this is
	# either a ramp (gentle slope, parsed as walkable by max_walkable_slope)
	# or non-walkable cliff (blocked by the bake).
	nav_mesh.agent_max_climb = 0.7
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = 5  # layer 1 (ground) + layer 4 (structures)
	nav_mesh.filter_baking_aabb = AABB(Vector3(-150.0, -1.0, -150.0), Vector3(300.0, 4.0, 300.0))

	nav_region.navigation_mesh = nav_mesh
	add_child(nav_region)
	_nav_region = nav_region

	# WorldBoundaryShape3D in test_arena.tscn is infinite (good for keeping
	# units on the floor) but bake needs a *finite* walkable surface to parse
	# as the floor. Add a thin slab on layer 1 strictly for the bake input.
	var slab := StaticBody3D.new()
	slab.name = "NavBakeFloor"
	slab.collision_layer = 1
	slab.collision_mask = 0
	var slab_shape := CollisionShape3D.new()
	var slab_box := BoxShape3D.new()
	slab_box.size = Vector3(310.0, 0.1, 310.0)
	slab_shape.shape = slab_box
	slab.add_child(slab_shape)
	slab.position = Vector3(0.0, -0.05, 0.0)
	add_child(slab)


func _bake_navmesh_now() -> void:
	if _nav_region:
		# Synchronous bake so the first frame's pathfinding queries hit a
		# real navmesh. ±150 with cell_size 0.5 is small enough that the
		# main-thread cost is negligible at startup.
		_nav_region.bake_navigation_mesh(false)


func request_navmesh_rebake() -> void:
	## Public hook: call after a building finishes construction (or is
	## destroyed) so the navmesh reflects the new static layout. We defer
	## to next frame so multiple buildings finishing on the same tick coalesce
	## into a single bake.
	if _rebake_pending:
		return
	_rebake_pending = true
	call_deferred("_do_pending_rebake")


var _rebake_pending: bool = false


func _do_pending_rebake() -> void:
	_rebake_pending = false
	if _nav_region:
		# Async bake here — runtime re-bakes shouldn't stutter; pathfinders
		# fall through to the previous mesh until the new one is ready.
		_nav_region.bake_navigation_mesh(true)


## Spawn positions per player_id. Picked so 2v2 has the team-A pair on the
## east (player at the corner, ally further north) and team-B on the west
## opposite — diagonal layout per the "no symmetric mirror maps" guideline
## but balanced so each team has comparable terrain access.
const PLAYER_HQ_POSITIONS: Dictionary = {
	0: Vector3(0.0, 0.0, 0.0),       # 1v1 default — keeps existing scene wiring untouched
	1: Vector3(60.0, 0.0, -20.0),    # 2v2 ally
	3: Vector3(-60.0, 0.0, -100.0),  # 2v2 enemy 1
	4: Vector3(60.0, 0.0, -100.0),   # 2v2 enemy 2
}

const HQ_POSITIONS_2V2: Dictionary = {
	0: Vector3(-60.0, 0.0, -20.0),   # Player corner in 2v2
	1: Vector3(60.0, 0.0, -20.0),    # Ally corner
	3: Vector3(-60.0, 0.0, -100.0),
	4: Vector3(60.0, 0.0, -100.0),
}


func _hq_position_for(player_id: int) -> Vector3:
	if _is_2v2():
		return HQ_POSITIONS_2V2.get(player_id, Vector3.ZERO) as Vector3
	if player_id == 0:
		return Vector3.ZERO
	return Vector3(0.0, 0.0, -120.0)


func _setup_player() -> void:
	# Mark the HQ as already constructed
	var hq: Building = $PlayerHQ as Building
	var hq_offset: Vector3 = Vector3.ZERO
	if hq:
		hq.owner_id = 0
		hq.is_constructed = true
		hq.resource_manager = resource_manager
		# Reposition player HQ for 2v2 since the static scene placement
		# only fits the 1v1 layout. Track the delta so the starter army
		# (statically placed in the scene) shifts by the same amount and
		# stays clustered around the HQ.
		if _is_2v2():
			var new_pos: Vector3 = _hq_position_for(0)
			hq_offset = new_pos - hq.global_position
			hq.global_position = new_pos
		hq._apply_placeholder_shape()

	# Shift the static starter Units alongside the HQ so they don't end up
	# stranded at world origin.
	if hq_offset.length_squared() > 0.0001:
		var units_node: Node = get_node_or_null("Units")
		if units_node:
			for child: Node in units_node.get_children():
				if child is Node3D:
					(child as Node3D).global_position += hq_offset

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

	# Starter army anchored relative to the HQ — same shape regardless of
	# corner / edge so each AI starts with comparable forces.
	var ratchet_stats: UnitStatResource = load("res://resources/units/anvil_ratchet.tres") as UnitStatResource
	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource
	var hq_pos: Vector3 = ai_hq.global_position
	# Push starter units further into open ground (away from map corner)
	# by stepping toward map center on z.
	var step_dir: Vector3 = (Vector3.ZERO - hq_pos)
	step_dir.y = 0.0
	if step_dir.length_squared() > 0.0001:
		step_dir = step_dir.normalized()
	else:
		step_dir = Vector3(0.0, 0.0, 1.0)
	var anchor: Vector3 = hq_pos + step_dir * 5.0
	_spawn_ai_unit(ratchet_stats, anchor + Vector3(-3.0, 0.0, 0.0), player_id)
	_spawn_ai_unit(ratchet_stats, anchor + Vector3(3.0, 0.0, 0.0), player_id)
	_spawn_ai_unit(rook_stats, anchor + Vector3(-2.0, 0.0, 3.0), player_id)
	_spawn_ai_unit(rook_stats, anchor + Vector3(2.0, 0.0, 3.0), player_id)

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

	# Foundry Belt 1v1 layout (per SCOPE_VERTICAL_SLICE_V2.md §"Map 1"):
	# - 1 in each player's safe area (close to home)
	# - 2 mid-map deposits (contested, central)
	# - 1 back-door deposit on the far east flank behind a terrain
	#   chokepoint (the high-value target — guarded by a Heavy patrol).
	# Total 5 deposits at varied strategic distances.
	var positions: Array[Vector3] = [
		Vector3(28, 0, -8),    # Player safe-side
		Vector3(-28, 0, -112), # AI safe-side
		Vector3(35, 0, -60),   # Mid-east (contested)
		Vector3(-35, 0, -60),  # Mid-west (contested)
		Vector3(95, 0, -60),   # Back-door (far east, behind chokepoint)
	]

	for pos: Vector3 in positions:
		var deposit: Node3D = deposit_script.new()
		deposit.global_position = pos
		add_child(deposit)


func _setup_terrain() -> void:
	# Foundry Belt terrain: rusted ruins and rock outcrops scattered through
	# the contested mid-map. Each piece blocks pathing (collision_layer 4 like
	# buildings, so units' mask=5 covers them) and carries a NavigationObstacle3D
	# so units route around it via RVO instead of grinding into the side.
	#
	# Positions deliberately leave the home-base lanes and deposit approaches
	# open so the early game stays clean; cover lives in the mid lane where
	# fights actually happen.
	var pieces: Array[Dictionary] = [
		{"pos": Vector3(-15, 0, -50), "size": Vector3(4.0, 2.5, 3.0), "kind": "rock"},
		{"pos": Vector3(15, 0, -55), "size": Vector3(3.5, 2.0, 4.0), "kind": "rock"},
		{"pos": Vector3(48, 0, -45), "size": Vector3(3.0, 3.5, 3.0), "kind": "ruin"},
		{"pos": Vector3(-48, 0, -75), "size": Vector3(3.5, 3.0, 3.5), "kind": "ruin"},
		{"pos": Vector3(60, 0, -25), "size": Vector3(2.5, 2.0, 2.5), "kind": "rock"},
		{"pos": Vector3(-60, 0, -30), "size": Vector3(3.0, 2.5, 3.0), "kind": "ruin"},
		{"pos": Vector3(50, 0, -100), "size": Vector3(3.0, 2.0, 3.5), "kind": "rock"},
		{"pos": Vector3(-55, 0, -90), "size": Vector3(4.0, 3.0, 3.0), "kind": "ruin"},
		# Back-door chokepoint — two large ruins at x ≈ 85 sandwich a narrow
		# gap (~4 units wide in z) that any attacker must thread through to
		# reach the back-door deposit at (95, -60). The high-value Heavy-
		# guarded deposit is the reward; the chokepoint is the price of
		# admission.
		{"pos": Vector3(85, 0, -54), "size": Vector3(8.0, 4.0, 8.0), "kind": "ruin"},
		{"pos": Vector3(85, 0, -66), "size": Vector3(8.0, 4.0, 8.0), "kind": "ruin"},
	]
	for piece: Dictionary in pieces:
		_spawn_terrain_piece(piece["pos"] as Vector3, piece["size"] as Vector3, piece["kind"] as String)


func _spawn_terrain_piece(pos: Vector3, piece_size: Vector3, kind: String) -> void:
	var root := StaticBody3D.new()
	root.collision_layer = 4
	root.collision_mask = 0
	root.position = Vector3(pos.x, piece_size.y * 0.5, pos.z)
	root.add_to_group("terrain")
	add_child(root)

	# Hard collision matching the visual extent.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = piece_size
	shape.shape = box
	root.add_child(shape)

	# Visual mesh with kind-specific color so ruins and rocks read differently.
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = piece_size
	mesh_inst.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	if kind == "ruin":
		mat.albedo_color = Color(0.32, 0.26, 0.22, 1.0)
		mat.roughness = 0.9
	else:
		mat.albedo_color = Color(0.28, 0.27, 0.24, 1.0)
		mat.roughness = 1.0
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

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
		# Central plateau — the contested high ground between the two mid
		# deposits and just above the apex wreck cluster.
		{"pos": Vector3(0.0, 0.3, -45.0), "size": Vector3(18.0, 0.6, 12.0)},
		# East ridge near the back-door chokepoint — defenders of the
		# back-door deposit can stand on it.
		{"pos": Vector3(70.0, 0.3, -60.0), "size": Vector3(8.0, 0.6, 14.0)},
		# West rise, mirrored across the map for the cross-flank push.
		{"pos": Vector3(-65.0, 0.3, -75.0), "size": Vector3(10.0, 0.6, 10.0)},
	]
	for piece: Dictionary in pieces:
		_spawn_elevation_piece(piece["pos"] as Vector3, piece["size"] as Vector3)


func _spawn_elevation_piece(pos: Vector3, piece_size: Vector3) -> void:
	# Walkable platform: collision on layer 1 (same as ground) so the
	# navmesh bake treats the top surface as walkable; click-to-move
	# raycasts through layer 1 will land on the platform when the player
	# clicks on top of it.
	var root := StaticBody3D.new()
	root.collision_layer = 1
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
	var patrols: Array[Dictionary] = [
		{"stats": rook_stats, "pos": Vector3(28 + 4, 0, -8)},     # Player safe
		{"stats": rook_stats, "pos": Vector3(-28 - 4, 0, -112)},  # AI safe
		{"stats": hound_stats, "pos": Vector3(35 + 4, 0, -56)},   # Mid-east contested
		{"stats": hound_stats, "pos": Vector3(-35 - 4, 0, -56)},  # Mid-west contested
		# Back-door deposit guard — Heavy patrol (Bulwark). High-value
		# target: clearing this opens up the strongest deposit on the map.
		{"stats": bulwark_stats, "pos": Vector3(95 + 4, 0, -56)},
		# Apex wreck guard — Heavy patrol (Bulwark) sitting on the scar at
		# (0, -30). Per V2 spec §"Map 1", the apex wreck is a mid-late game
		# objective and should be heavily guarded; pushing for it costs
		# real combat power, not a free salvage burst.
		{"stats": bulwark_stats, "pos": Vector3(4, 0, -28)},
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
