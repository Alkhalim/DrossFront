class_name TestArenaController
extends Node3D
## Bootstraps the test arena: player base, AI opponent, resource wiring.

@export var buildable_buildings: Array[BuildingStatResource] = []

@onready var resource_manager: ResourceManager = $ResourceManager as ResourceManager

## Cached so the deferred-bake / re-bake-after-construction can find the region
## without searching the scene tree.
var _nav_region: NavigationRegion3D = null

## Polygons queued by `_setup_elevation` (plateau tops + ramps) that
## `_setup_navigation` then merges into the manual navmesh so units can
## actually path onto raised ground.
var _pending_nav_polys: Array[PackedVector3Array] = []

## 2D footprints (XZ plane) of plateau bodies + ramp slopes — the ground
## navmesh subtracts these so the perimeter of each blocked area becomes
## walkable polygon edges. This is what shares ground vertices with the
## ramp-bottom edges so a unit on a ramp can plan a path onto the ground
## (and vice-versa) without `navigation finished` stuck-states at the
## seam.
var _pending_blocked_footprints: Array[PackedVector2Array] = []
## Extra ground vertices that need to be welded into the ground
## triangulation — typically the ramp bottom-edge endpoints, so the
## triangulation puts the ground edge at the ramp's foot.
var _pending_ground_vertex_marks: Array[Vector2] = []
## Approach-lane footprints for every ramp — the ramp's own footprint
## PLUS a 4u clearance zone extending in the ramp's outward direction.
## Terrain spawn checks each piece against these and skips placement
## that would obstruct a ramp's approach. Each entry is a Rect2 in
## XZ-world coords.
var _pending_ramp_clearance: Array[Rect2] = []


func _ready() -> void:
	# Navmesh debug overlay — TEMPORARILY ON while diagnosing the
	# "invisible wall" reports. Renders walkable cells as colored
	# polygons; gaps in the overlay correspond directly to spots where
	# the navmesh is broken. Will turn off again once the bug is fully
	# squashed.
	const NAV_DEBUG_OVERLAY: bool = true
	NavigationServer3D.set_debug_enabled(NAV_DEBUG_OVERLAY)
	if NAV_DEBUG_OVERLAY:
		# Force-set high-contrast colors via project settings so the
		# overlay actually shows up — defaults can be very subtle and
		# blend with the ash-tinted ground. Random face color highlights
		# polygon boundaries (each cell gets a different tint, so a
		# disconnected island stands out visually). Edge color in bright
		# magenta makes polygon-perimeter seams pop.
		var nav_settings: Array = [
			["debug/shapes/navigation/enable_geometry_face_random_color", true],
			["debug/shapes/navigation/enable_edge_lines", true],
			["debug/shapes/navigation/edge_color", Color(1.0, 0.2, 0.9, 1.0)],
			["debug/shapes/navigation/geometry_face_color", Color(0.2, 0.9, 0.4, 0.55)],
		]
		for kv: Array in nav_settings:
			if ProjectSettings.has_setting(kv[0] as String):
				ProjectSettings.set_setting(kv[0] as String, kv[1])

	# Manual strip-decomposition navmesh has dense polygon adjacency
	# (every blocker contributes both X and Z cuts, so 4-way corners
	# are common). Godot's default merge rasterizer cell scale of 1.0
	# fires the "More than 2 edges occupy the same map rasterization
	# space" warning hundreds of times per match for what are actually
	# legitimate corner configurations. Lowering the scale shrinks the
	# rasterizer cell so coincident edges don't collapse into a single
	# spot, eliminating the noise without changing real connectivity.
	# Disabling the warning is also safe — the underlying connectivity
	# we care about is verified by manual vertex dedup.
	if ProjectSettings.has_setting("navigation/3d/merge_rasterizer_cell_scale"):
		ProjectSettings.set_setting("navigation/3d/merge_rasterizer_cell_scale", 0.1)
	if ProjectSettings.has_setting("navigation/3d/warnings/navmesh_edge_merge_errors"):
		ProjectSettings.set_setting("navigation/3d/warnings/navmesh_edge_merge_errors", false)

	# Single GPU-particle hub used for smoke / muzzle flashes / dust /
	# sparks. Replaces the per-particle MeshInstance3D + Tween churn
	# that dominated the profiler under heavy combat. Loaded via preload
	# rather than the class_name so the parser doesn't need the global
	# class registry to be ready before this script compiles.
	var pem_script: GDScript = preload("res://scripts/particle_emitter_manager.gd")
	var pem: Node = pem_script.new()
	pem.name = "ParticleEmitterManager"
	add_child(pem)

	# V3 Pillar 2 — Neural Mesh provider tracker. Maintains a snapshot
	# of every Sable Mesh provider (Black Pylon + Overseer Harbinger
	# etc.) so combat can read the per-position Mesh strength cheaply.
	var mesh_script: GDScript = preload("res://scripts/mesh_system.gd")
	var mesh: Node = mesh_script.new()
	mesh.name = "MeshSystem"
	add_child(mesh)

	# Fog of War — Age-of-Empires-style three-state grid (unexplored
	# / explored / visible). Allied vision shares automatically.
	# Per-unit + per-building visibility hooks read from this node
	# every frame; the terrain darkening overlay reads the same
	# grid via revision bumps.
	var fow_script: GDScript = preload("res://scripts/fog_of_war.gd")
	var fow: Node = fow_script.new()
	fow.name = "FogOfWar"
	add_child(fow)
	# Visible darkening layer that sits just above the ground and
	# tints itself per-cell from the FOW grid. Reads the grid via
	# revision bumps so the multi-mesh colour buffer is only re-
	# uploaded when fog actually moves.
	var fow_overlay_script: GDScript = preload("res://scripts/fog_overlay.gd")
	var fow_overlay: Node = fow_overlay_script.new()
	fow_overlay.name = "FogOverlay"
	add_child(fow_overlay)

	# Industrial-themed cursor manager. Procedurally generates the
	# default / attack / repair / build / move cursor textures and
	# exposes `set_kind()` for SelectionManager to switch on hover.
	var cursor_script: GDScript = preload("res://scripts/cursor_manager.gd")
	var cursor_mgr: Node = cursor_script.new()
	cursor_mgr.name = "CursorManager"
	add_child(cursor_mgr)

	# Cheat state -- bypassed unless the player types a code into the
	# HUD chat input. Lives at the scene root so prereq checks +
	# resource grants can find it via a simple get_node lookup.
	var cheat_script: GDScript = preload("res://scripts/cheat_manager.gd")
	var cheats: Node = cheat_script.new()
	cheats.name = "CheatManager"
	add_child(cheats)

	_apply_map_visuals()
	_setup_alerts()
	_setup_player_registry()
	_setup_player()
	_setup_ai()
	_setup_fuel_deposits()
	# Build elevation BEFORE terrain so terrain spawn knows where the
	# plateau / ramp footprints are and can avoid placing rocks /
	# ruins that obstruct ramp approach lanes.
	_setup_elevation()
	_setup_terrain()
	_setup_map_signature_features()
	_setup_skyline_features()
	_setup_ground_patches()
	_setup_neutral_patrols()
	_setup_buildable_buildings()
	# Navigation last — uses the queued plateau polys.
	_setup_navigation()
	_bake_navmesh_now()

	# Fire up the in-match playlist. The MusicManager child node loads
	# the universal pool plus the player's faction folder and cycles
	# through them, gap-spaced. Fire after the player_faction has been
	# resolved by _setup_player so the right folder is picked.
	var music_mgr: Node = get_node_or_null("MusicManager")
	if music_mgr and music_mgr.has_method("start"):
		var player_faction: int = _faction_id_for_player(0)
		music_mgr.call("start", player_faction)

	# Tutorial mission scaffold — only when MatchSettings.tutorial_mode
	# is true. Adds a TutorialMission node that owns the stage state,
	# spawns reinforcements at trigger zones, and ends the match on
	# completion. Banner UI is in HUD; mission is otherwise self-
	# contained.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.get("tutorial_mode"):
		var tut_script: GDScript = preload("res://scripts/tutorial_mission.gd")
		var tutorial: Node = tut_script.new()
		tutorial.name = "TutorialMission"
		add_child(tutorial)


func _setup_map_signature_features() -> void:
	# Per-map distinctive features that go beyond the shared
	# terrain / plateau / skyline systems. Foundry Belt gets explosive
	# ammo dumps that turn into tactical bait targets; Ashplains gets
	# glowing volcanic fissures that block pathing across the open plain.
	if _is_ashplains():
		_setup_volcanic_fissures()
	else:
		_setup_ammo_dumps()


## --- Foundry Belt ammo dumps ------------------------------------------------

func _setup_ammo_dumps() -> void:
	# Tutorial mode skips the ammo-dump scatter entirely — the
	# bait-the-enemy-past-it tactical play those dumps enable
	# isn't part of the tutorial's beats and they only clutter
	# the southward / northward push lanes the mission scripts.
	var settings_for_dumps: Node = get_node_or_null("/root/MatchSettings")
	if settings_for_dumps and settings_for_dumps.get("tutorial_mode"):
		return
	# 4 destructible ammo dumps placed around the contested mid lanes.
	# Positioned so squads have to path NEAR them on the way to deposits
	# / the Apex scar — creates the bait-the-enemy-past-it tactical play.
	var dump_script: GDScript = load("res://scripts/ammo_dump.gd") as GDScript
	if not dump_script:
		return
	var positions: Array[Vector3] = [
		# Two flanking the central plateau, on the lanes between mid
		# deposits and the plateau ramps.
		Vector3(22.0, 0.0, 18.0),
		Vector3(-22.0, 0.0, 18.0),
		# Two near the back-door choke entrances — defenders walking up
		# to retake will path past these.
		Vector3(60.0, 0.0, -18.0),
		Vector3(-60.0, 0.0, -18.0),
	]
	for pos: Vector3 in positions:
		var dump: AmmoDump = dump_script.new() as AmmoDump
		add_child(dump)
		dump.global_position = pos
		dump.rotation.y = randf_range(0.0, TAU)


## --- Ashplains volcanic fissures --------------------------------------------

func _setup_volcanic_fissures() -> void:
	# Glowing fissures across the open plain. Each fissure is a thin,
	# elongated obstacle: visible as a dark crack with orange emission
	# glow, blocks movement (collision_layer 4), and pushes pathing via
	# NavigationObstacle3D. They break up the otherwise frictionless
	# plain into pathing corridors without blocking sightlines.
	var fissures: Array[Dictionary] = [
		# Long fissure paralleling the main ridge on its north side
		# (forces units to approach the ridge in narrower lanes).
		{"pos": Vector3(40.0, 0.0, 12.0), "size": Vector3(28.0, 0.4, 2.5), "rot": 0.05},
		{"pos": Vector3(-40.0, 0.0, 12.0), "size": Vector3(28.0, 0.4, 2.5), "rot": -0.05},
		# Smaller fissures near the safe deposits — funnels the
		# initial expansion toward the edges.
		{"pos": Vector3(15.0, 0.0, 55.0), "size": Vector3(14.0, 0.4, 2.0), "rot": 0.4},
		{"pos": Vector3(-15.0, 0.0, 55.0), "size": Vector3(14.0, 0.4, 2.0), "rot": -0.4},
		{"pos": Vector3(15.0, 0.0, -55.0), "size": Vector3(14.0, 0.4, 2.0), "rot": -0.4},
		{"pos": Vector3(-15.0, 0.0, -55.0), "size": Vector3(14.0, 0.4, 2.0), "rot": 0.4},
		# Far flank fissures — make the long sightlines slightly less
		# uniform.
		{"pos": Vector3(95.0, 0.0, -30.0), "size": Vector3(20.0, 0.4, 2.2), "rot": 1.2},
		{"pos": Vector3(-95.0, 0.0, 30.0), "size": Vector3(20.0, 0.4, 2.2), "rot": 1.2},
	]
	for f: Dictionary in fissures:
		_spawn_volcanic_fissure(
			f["pos"] as Vector3,
			f["size"] as Vector3,
			f["rot"] as float,
		)


func _spawn_volcanic_fissure(pos: Vector3, fissure_size: Vector3, rot_y: float) -> void:
	## A volcanic fissure is a CRACK in the ground — recessed below the
	## surface, with a glow at the bottom. The previous version stuck a
	## thin box ABOVE the ground which read as a wall, not a crack.
	## This version:
	##   - keeps an invisible thin collision slab so units still can't
	##     cross (gameplay unchanged)
	##   - emits 3-5 jittered dark wedge segments along the length, each
	##     with slight per-segment width and rotation offsets so the
	##     silhouette reads as a jagged organic split, not a ruler line
	##   - sinks the orange emissive glow into the trench (negative y)
	##     so we see the magma "down inside" the crack
	var root := StaticBody3D.new()
	root.collision_layer = 4
	root.collision_mask = 0
	root.position = pos
	root.rotation.y = rot_y
	root.add_to_group("terrain")
	add_child(root)

	# Invisible collision wall — only the slab a unit's body touches.
	# Slightly taller than the visible crack so an off-axis unit can't
	# slip through, but the box itself isn't rendered.
	var col := CollisionShape3D.new()
	var col_box := BoxShape3D.new()
	col_box.size = Vector3(fissure_size.x, 0.6, fissure_size.z)
	col.shape = col_box
	col.position.y = 0.3
	root.add_child(col)

	# Replaced the previous "stack of box segments" approach with a
	# single irregular polygon mesh that reads as a real crack: a
	# jagged dark perimeter on the ground (the hole's "mouth") with
	# a thinner emissive polygon recessed inside (the magma below).
	# The polygon's edge wobbles per-vertex so adjacent vertices
	# never align on a clean rectangle, which was the giveaway that
	# made the box-stack version look stamped.
	var crust_mat := StandardMaterial3D.new()
	crust_mat.albedo_color = Color(0.04, 0.03, 0.03, 1.0)
	crust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	crust_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_color = Color(1.0, 0.4, 0.1, 1.0)
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(1.0, 0.5, 0.15, 1.0)
	glow_mat.emission_energy_multiplier = 2.8
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Outer mouth polygon — perimeter walks along the fissure length
	# with width that bulges in the middle and tapers at the ends,
	# plus a per-vertex jitter so the silhouette is jagged.
	var mouth: MeshInstance3D = _build_fissure_polygon(
		fissure_size.x, fissure_size.z, -0.04, 0.45, 12, crust_mat
	)
	root.add_child(mouth)
	# Inner glow polygon — narrower (~50%) and recessed deeper so it
	# reads as magma seen down through the crack mouth, not a stripe
	# painted on the surface.
	var inner: MeshInstance3D = _build_fissure_polygon(
		fissure_size.x * 0.65, fissure_size.z * 0.5, -0.18, 0.55, 10, glow_mat
	)
	root.add_child(inner)

	# Heat glow — soft warm omni light hovering just above the trench
	# so the surrounding ash plain picks up the heat halo. Position is
	# at ground level (y ~ 0) instead of the previous +0.4 stripe.
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.50, 0.15, 1.0)
	light.light_energy = 1.6
	light.omni_range = maxf(fissure_size.x, fissure_size.z) * 0.7 + 1.5
	light.position.y = 0.05
	root.add_child(light)

	# RVO obstacle — pushes pathing away even before the wall is hit.
	var nav_obstacle := NavigationObstacle3D.new()
	nav_obstacle.radius = maxf(fissure_size.x, fissure_size.z) * 0.55 + 0.6
	nav_obstacle.height = 1.0
	nav_obstacle.avoidance_enabled = true
	root.add_child(nav_obstacle)


func _build_fissure_polygon(length: float, width: float, y: float, jitter: float, segments: int, mat: StandardMaterial3D) -> MeshInstance3D:
	## Builds a flat horizontal mesh with an irregular jagged perimeter
	## representing a single elongated crack in the ground. The polygon
	## is shaped like a cigar (tapered ends, bulged middle), with each
	## perimeter vertex jittered by `jitter` units so adjacent vertices
	## never align on a clean rectangle. Triangulated as a fan from the
	## centre. Returned as a MeshInstance3D positioned at y=`y`,
	## y-rotation 0 (the caller's root node owns the heading rotation).
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	# Build perimeter — `segments` per long side, top + bottom + 2 caps.
	# We walk along the length axis collecting top-edge points (positive
	# z offset) then bottom-edge points (negative z) so the polygon
	# winds CCW from above.
	var top_pts := PackedVector3Array()
	var bot_pts := PackedVector3Array()
	for i: int in segments + 1:
		var u: float = float(i) / float(segments)
		var x: float = lerp(-length * 0.5, length * 0.5, u)
		# Width tapers at the ends, bulges in the middle — sin gives the
		# right falloff curve.
		var taper: float = sin(u * PI)
		var z_extent: float = width * 0.5 * lerp(0.25, 1.0, taper)
		# Per-vertex jitter so the edge is jagged, not smooth.
		var jx: float = randf_range(-jitter, jitter) * 0.5
		var jz_top: float = randf_range(-jitter, jitter)
		var jz_bot: float = randf_range(-jitter, jitter)
		top_pts.append(Vector3(x + jx, 0, +z_extent + jz_top))
		bot_pts.append(Vector3(x + jx, 0, -z_extent + jz_bot))
	# Triangulate as a fan from the polygon centre.
	var centre: Vector3 = Vector3(0, 0, 0)
	var perimeter: PackedVector3Array = PackedVector3Array()
	for p: Vector3 in top_pts:
		perimeter.append(p)
	# bottom walks back the other direction so the perimeter is a
	# closed loop CCW from above.
	for i: int in bot_pts.size():
		perimeter.append(bot_pts[bot_pts.size() - 1 - i])
	for i: int in perimeter.size():
		var a: Vector3 = perimeter[i]
		var b: Vector3 = perimeter[(i + 1) % perimeter.size()]
		# Triangle (centre, b, a) — note reversed b/a so the normal
		# points UP (CCW from +Y).
		verts.append(centre); norms.append(Vector3.UP); uvs.append(Vector2(0.5, 0.5))
		verts.append(b); norms.append(Vector3.UP); uvs.append(Vector2(0.5 + b.x / length, 0.5 + b.z / width))
		verts.append(a); norms.append(Vector3.UP); uvs.append(Vector2(0.5 + a.x / length, 0.5 + a.z / width))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var inst := MeshInstance3D.new()
	inst.mesh = arr_mesh
	inst.position.y = y
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.set_surface_override_material(0, mat)
	return inst


func _apply_map_visuals() -> void:
	# Re-tint the ground / lighting / environment per map so Foundry Belt
	# (cool grey industrial) and Ashplains (warm volcanic ash) actually
	# feel different at a glance, not just "same map with less stuff".
	#
	# Both maps share the same noise texture; the per-map albedo tint
	# multiplies it so the surface detail still reads but the overall
	# colour shifts dramatically.
	var ground: MeshInstance3D = get_node_or_null("Ground") as MeshInstance3D
	var dir_light: DirectionalLight3D = get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	var fill_light: DirectionalLight3D = get_node_or_null("FillLight") as DirectionalLight3D
	var world_env: WorldEnvironment = get_node_or_null("WorldEnvironment") as WorldEnvironment

	if _is_ashplains():
		# Ashplains — warm volcanic ash, pushed harder into wasteland
		# territory: deeper orange-red base tint, sunset sun, cool
		# blue fill, hazy beige sky.
		if ground:
			var gmat: StandardMaterial3D = ground.get_surface_override_material(0) as StandardMaterial3D
			if gmat:
				gmat.albedo_color = Color(1.85, 1.20, 0.72, 1.0)  # deeper warm wash so the desert reads as parched, not just cooler-tinted
		if dir_light:
			dir_light.light_color = Color(1.0, 0.78, 0.52, 1.0)
			dir_light.light_energy = 1.35
		if fill_light:
			fill_light.light_color = Color(0.42, 0.55, 0.78, 1.0)
			fill_light.light_energy = 0.45
		if world_env and world_env.environment:
			var env: Environment = world_env.environment
			env.background_color = Color(0.32, 0.22, 0.16, 1.0)
			env.ambient_light_color = Color(0.55, 0.40, 0.28, 1.0)
			env.ambient_light_energy = 0.7
	elif _is_iron_gate():
		# Iron Gate Crossing — semi-controlled district, overcast
		# storm light. Cool desaturated palette so the colour pops
		# from Sable violet + Anvil brass over a flat grey-green
		# atmospheric base. Pulled the ground tint cooler + darker
		# so the "snow" reads as packed dirty winter ground rather
		# than fresh-fallen sheet white; the spotty patches added
		# in _setup_ground_patches do the rest of the texture work.
		if ground:
			var gmat2: StandardMaterial3D = ground.get_surface_override_material(0) as StandardMaterial3D
			if gmat2:
				gmat2.albedo_color = Color(0.58, 0.62, 0.62, 1.0)
		if dir_light:
			dir_light.light_color = Color(0.78, 0.82, 0.85, 1.0)
			dir_light.light_energy = 0.95
		if fill_light:
			fill_light.light_color = Color(0.60, 0.68, 0.78, 1.0)
			fill_light.light_energy = 0.55
		if world_env and world_env.environment:
			var env3: Environment = world_env.environment
			env3.background_color = Color(0.16, 0.18, 0.20, 1.0)
			env3.ambient_light_color = Color(0.45, 0.50, 0.55, 1.0)
			env3.ambient_light_energy = 0.65
	else:
		# Foundry Belt — cool grey industrial. Restore the .tscn
		# defaults explicitly so switching back from Ashplains during
		# the same session resets everything.
		if ground:
			var gmat: StandardMaterial3D = ground.get_surface_override_material(0) as StandardMaterial3D
			if gmat:
				gmat.albedo_color = Color(1, 1, 1, 1)
		if dir_light:
			dir_light.light_color = Color(0.95, 0.9, 0.8, 1.0)
			dir_light.light_energy = 1.2
		if fill_light:
			fill_light.light_color = Color(0.6, 0.65, 0.75, 1.0)
			fill_light.light_energy = 0.4
		if world_env and world_env.environment:
			var env: Environment = world_env.environment
			env.background_color = Color(0.12, 0.12, 0.11, 1.0)
			env.ambient_light_color = Color(0.3, 0.28, 0.25, 1.0)
			env.ambient_light_energy = 0.5


## Per-mode roster definitions. Each entry seeds one PlayerState; AI
## resource managers are wired up later (when `_setup_ai` actually creates
## them). Player IDs 0/1 are team A, 3/4 are team B; 2 is reserved for the
## neutral pseudo-player so existing patrol code keeps working unchanged.
const ROSTER_1V1: Array[Dictionary] = [
	{"id": 0, "team": 0, "color": Color(0.08, 0.25, 0.85, 1.0), "human": true, "name": "Player"},
	{"id": 1, "team": 1, "color": Color(0.85, 0.2, 0.15, 1.0), "human": false, "name": "AI Bravo"},
]
const ROSTER_2V2: Array[Dictionary] = [
	{"id": 0, "team": 0, "color": Color(0.08, 0.25, 0.85, 1.0), "human": true, "name": "Player"},
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


## Returns the active V2 map id from MatchSettings. Defaults to
## FOUNDRY_BELT (== 0) when the autoload is missing, e.g. running the
## arena scene directly from the editor.
func _map_id() -> int:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "map_id" in settings:
		return settings.get("map_id") as int
	return 0


func _is_ashplains() -> bool:
	# MapId.ASHPLAINS_CROSSING == 1 in the autoload's enum.
	return _map_id() == 1


func _is_iron_gate() -> bool:
	# MapId.IRON_GATE_CROSSING == 2. V3 §Pillar 6 — asymmetric-test
	# map emphasising concealment and flanking.
	return _map_id() == 2


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

	# Apply the player's colour pick (MatchSettings.player_color)
	# and reshuffle any AI colour that collides with it -- so no two
	# participants share the same swatch even if the player picks a
	# colour that the default roster had assigned to an AI.
	var resolved_colors: Array[Color] = _resolve_player_colors(_current_roster())
	for i: int in _current_roster().size():
		var entry: Dictionary = _current_roster()[i]
		var state: PlayerState = PlayerState.make(
			entry["id"] as int,
			entry["team"] as int,
			resolved_colors[i],
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


func _resolve_player_colors(roster: Array[Dictionary]) -> Array[Color]:
	## Builds the per-roster-entry colour list. Local human takes
	## MatchSettings.player_color; every AI keeps its default unless
	## that default collides with an already-claimed colour, in which
	## case the AI gets reassigned to the next free swatch in
	## PLAYER_COLOR_PALETTE. Falls back to MatchSettings.player_color
	## or the original entry colour if MatchSettings isn't loaded
	## (headless test scenes without the autoload).
	var settings: Node = get_node_or_null("/root/MatchSettings")
	var human_pick: Color = Color(0.08, 0.25, 0.85, 1.0)
	var palette: Array[Color] = []
	if settings:
		human_pick = settings.get("player_color") as Color
		palette = settings.PLAYER_COLOR_PALETTE
	var out: Array[Color] = []
	out.resize(roster.size())
	# Pass 1: place the human's pick (slot id 0).
	var taken: Array[Color] = []
	for i: int in roster.size():
		var entry: Dictionary = roster[i]
		if entry.get("human", false) as bool:
			out[i] = human_pick
			taken.append(human_pick)
		else:
			out[i] = Color()  # placeholder, filled in pass 2
	# Pass 2: AI slots. Keep the default if it doesn't collide; else
	# pick the next palette colour not already in `taken`.
	for i: int in roster.size():
		var entry: Dictionary = roster[i]
		if entry.get("human", false) as bool:
			continue
		var default_col: Color = entry["color"] as Color
		if not _color_taken(default_col, taken):
			out[i] = default_col
			taken.append(default_col)
			continue
		# Reassign from the unused-palette pool.
		var picked: Color = default_col
		for cand: Color in palette:
			if not _color_taken(cand, taken):
				picked = cand
				break
		out[i] = picked
		taken.append(picked)
	return out


func _color_taken(c: Color, taken: Array[Color]) -> bool:
	for t: Color in taken:
		if t.is_equal_approx(c):
			return true
	return false


func _setup_alerts() -> void:
	# AlertManager is an event hub — created early so any system spawned later
	# can find it via get_node_or_null("AlertManager"). Owned by the arena
	# so it lives the same lifetime as the match.
	var mgr := AlertManager.new()
	mgr.name = "AlertManager"
	add_child(mgr)


func _setup_navigation() -> void:
	## Godot-native navmesh BAKING. Walks the existing collision shapes
	## via the "terrain" group (plateaus, ramps, terrain pieces, the
	## ground plane via GroundCollision) and produces a properly
	## connected navmesh. Replaces the previous manual strip-
	## decomposition approach which had recurring connectivity bugs at
	## adjacent strip boundaries — different float-jitter at the same
	## logical Z value left invisible seams the path planner couldn't
	## bridge.
	##
	## Bake parameters:
	##   cell_size 0.5 — reasonable resolution for a 300×300 map
	##   agent_radius 2.5 — covers the largest unit (Bulwark squad
	##     formation) so corridors narrower than 5u get carved out;
	##     fixes the "lights pass, heavies don't" symptom from the
	##     manual decomposition where corridors were carved per-AABB
	##     without considering agent size
	##   agent_max_climb 2.0 — plateaus are 1.5-2.0u tall so the bake
	##     correctly walks the ramp slopes
	##   agent_max_slope 30° — ramps are ~13°, well within range
	var nav_region := NavigationRegion3D.new()
	nav_region.name = "NavigationRegion"
	add_child(nav_region)
	_nav_region = nav_region

	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = 0.5
	# cell_height drives Recast's vertical voxel resolution. 0.25 was
	# leaving the slope foot at y≈0.25 (one voxel above ground level)
	# instead of y=0, putting a 0.25u step between the ramp navmesh
	# and the surrounding ground navmesh. agent_max_climb 0.5 should
	# bridge that, but the resulting connection is fragile and the
	# path planner sometimes refuses to commit to it. Tighter cell
	# height keeps the slope foot exactly at y=0.
	nav_mesh.cell_height = 0.1
	# Don't filter "ledge spans" — Recast's default behaviour drops
	# walkable polygons that sit next to a drop, which removes ramp
	# slope navmesh near the foot (the foot is at the same Y as the
	# surrounding ground, but Recast classifies it as a ledge anyway).
	nav_mesh.filter_ledge_spans = false
	nav_mesh.filter_low_hanging_obstacles = false
	nav_mesh.filter_walkable_low_height_spans = false
	# agent_radius shrinks the walkable area by this distance from
	# every obstacle edge. With 2.5u and a 7u-wide ramp, the walkable
	# strip on the slope was only 2u — too narrow for the path planner
	# to keep a connection to plateau top, leaving units stuck at the
	# wall. Dropping to 1.5u gives a 4u walkable strip on a 7u ramp,
	# which is enough for both light and heavy units to traverse.
	nav_mesh.agent_radius = 1.5
	nav_mesh.agent_height = 2.0
	# agent_max_climb caps the vertical distance Recast will treat as
	# a "step" between two adjacent walkable cells. Plateaus are 1.5-2u
	# tall — if max_climb >= plateau height, the bake creates a direct
	# adjacency from the ground navmesh to the plateau-top navmesh
	# along the ENTIRE plateau perimeter, not just at the ramp. The
	# path planner then picks "walk off the cliff" as the shortest
	# route, which is exactly the "unit dives off the plateau and gets
	# stuck mid-air" symptom the user reported. Cap at 0.5u so the
	# bake only connects plateau-top to the ground via the ramp's
	# walkable slope (which has a smooth gradient, not a 1.5u step).
	nav_mesh.agent_max_climb = 0.5
	nav_mesh.agent_max_slope = 30.0
	# Pull source geometry from the "terrain" group + the ground
	# collision (already in scene). The bake walks each shape, treats
	# walkable surfaces as candidates, and rejects areas a unit of the
	# specified agent_radius can't enter.
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav_mesh.geometry_source_group_name = &"terrain"
	# Terrain blockers live on collision_layer 4; the ground plane on 1.
	# Bake mask covers both so the ground is walkable and obstacles
	# carve out their footprints.
	nav_mesh.geometry_collision_mask = 1 | 4
	# Bake region — a generous box covering the full ±150 map plus a
	# small buffer. Without this, the bake AABB defaults to a tiny
	# region around the source geometry origin and skips most of the map.
	nav_mesh.filter_baking_aabb = AABB(Vector3(-160, -5, -160), Vector3(320, 25, 320))
	nav_region.navigation_mesh = nav_mesh

	# Make sure the GroundCollision and all terrain blockers are in
	# the "terrain" group so the bake picks them up. The terrain
	# spawners already add their pieces; the .tscn-placed
	# GroundCollision needs the group set here.
	var ground_col: Node = get_node_or_null("GroundCollision")
	if ground_col and not ground_col.is_in_group("terrain"):
		ground_col.add_to_group("terrain")

	# Synchronous bake — for a 300×300 map at 0.5 cell_size this
	# produces ~360k cells which Godot bakes in <1s. Async would mean
	# the first frame of the match has no navmesh and units spawn
	# without paths.
	nav_region.bake_navigation_mesh(false)

	# Generous edge-connection margin for any T-junctions the bake
	# leaves at boundary cell edges.
	#
	# Also align the map's cell_height with the navmesh's cell_height
	# (we set the mesh to 0.1 above; the NavigationServer's default
	# is 0.25). A mismatch spams "navmesh cell_size mismatch" warnings
	# every rebake -- harmless for pathing but floods the debugger.
	var nav_map: RID = nav_region.get_navigation_map()
	if nav_map.is_valid():
		NavigationServer3D.map_set_edge_connection_margin(nav_map, 1.0)
		NavigationServer3D.map_set_cell_height(nav_map, 0.1)
		NavigationServer3D.map_set_cell_size(nav_map, 0.5)


func _overlaps_plateau_footprint(pos: Vector3, piece_size: Vector3, margin: float) -> bool:
	# Returns true if a piece centered at `pos` with the given size would
	# overlap any queued plateau / ramp footprint plus `margin` clearance.
	# Used to keep terrain / skyline / detail spawns out of ramp approach
	# lanes so ramps stay reachable.
	var half_x: float = piece_size.x * 0.5 + margin
	var half_z: float = piece_size.z * 0.5 + margin
	var p_min: Vector2 = Vector2(pos.x - half_x, pos.z - half_z)
	var p_max: Vector2 = Vector2(pos.x + half_x, pos.z + half_z)
	for blocked: PackedVector2Array in _pending_blocked_footprints:
		if blocked.is_empty():
			continue
		var b_aabb: Rect2 = Rect2(blocked[0], Vector2.ZERO)
		for v: Vector2 in blocked:
			b_aabb = b_aabb.expand(v)
		if p_max.x < b_aabb.position.x:
			continue
		if p_min.x > b_aabb.position.x + b_aabb.size.x:
			continue
		if p_max.y < b_aabb.position.y:
			continue
		if p_min.y > b_aabb.position.y + b_aabb.size.y:
			continue
		return true
	return false


func _build_ground_triangulation() -> Array[PackedVector2Array]:
	# Strip decomposition: split the ±150 ground into horizontal Z-bands
	# at every plateau/ramp footprint edge, then in each band produce
	# axis-aligned ground rectangles in the X-gaps between blockers.
	# Every blocker corner becomes a strip rectangle corner, so plateau
	# / ramp footprint perimeters fully share vertices with the
	# surrounding ground polygons. That's what gives the ramp slope
	# polys (whose bottom edge sits on a strip rectangle's edge) a
	# proper navmesh edge to connect through.
	const MAP_HALF: float = 150.0
	var rects: Array[Rect2] = []
	for blocked: PackedVector2Array in _pending_blocked_footprints:
		if blocked.is_empty():
			continue
		var aabb: Rect2 = Rect2(blocked[0], Vector2.ZERO)
		for v: Vector2 in blocked:
			aabb = aabb.expand(v)
		rects.append(aabb)

	if rects.is_empty():
		return [PackedVector2Array([
			Vector2(-MAP_HALF, -MAP_HALF),
			Vector2(MAP_HALF, -MAP_HALF),
			Vector2(MAP_HALF, MAP_HALF),
			Vector2(-MAP_HALF, MAP_HALF),
		])]

	# Collect unique Z + X values across ALL blockers — every strip
	# rectangle is then split at the same universal X cuts so adjacent
	# strips (above/below) always share full edges.
	#
	# CUT QUANTIZATION: blocker AABB edges are computed from many
	# different sources (plateau body, ramp footprints, terrain pieces
	# with NAV_INFLATION). Float arithmetic between those sources can
	# leave the SAME logical edge as two slightly-different values in
	# the cut set (e.g. 5.0000 from one path, 4.9999 from another).
	# That caused two adjacent strips to be created with a sub-millimeter
	# gap between them — invisible on the map but enough to keep the
	# vertex-dedup hash from matching, splitting the navmesh into two
	# disjoint islands and producing the "horizontal wall across the
	# whole map" symptom. Quantizing every cut to 1mm collapses those
	# duplicates so a single canonical Z (or X) value is used.
	var QUANT: float = 1000.0
	var quantize := func(v: float) -> float:
		return roundf(v * QUANT) / QUANT
	var z_set: Dictionary = {}
	z_set[quantize.call(-MAP_HALF)] = true
	z_set[quantize.call(MAP_HALF)] = true
	for r: Rect2 in rects:
		z_set[quantize.call(r.position.y)] = true
		z_set[quantize.call(r.position.y + r.size.y)] = true
	var z_vals: Array = z_set.keys()
	z_vals.sort()

	var x_set: Dictionary = {}
	x_set[quantize.call(-MAP_HALF)] = true
	x_set[quantize.call(MAP_HALF)] = true
	for r: Rect2 in rects:
		x_set[quantize.call(r.position.x)] = true
		x_set[quantize.call(r.position.x + r.size.x)] = true
	var x_vals: Array = x_set.keys()
	x_vals.sort()

	# Per-cell emission — every cell bounded by adjacent universal X/Z
	# cuts becomes its own quad. The previous merge attempt introduced
	# T-junctions between adjacent strips with different blocker
	# patterns (one strip = one long polygon, the next strip split into
	# 2-3 polygons), which produced exactly the kind of "wall in open
	# ground" symptom the merge was trying to eliminate. Per-cell
	# emission keeps every shared edge between two cells as a single
	# index pair, which Godot's edge merger handles cleanly via the
	# vertex-dedup pass in `_setup_navigation`. The 4-way-corner warnings
	# this produces are silenced at scene start.
	var polys: Array[PackedVector2Array] = []
	for zi: int in range(z_vals.size() - 1):
		var z_low: float = z_vals[zi] as float
		var z_high: float = z_vals[zi + 1] as float
		if z_high - z_low <= 0.01:
			continue

		for xi: int in range(x_vals.size() - 1):
			var x_low: float = x_vals[xi] as float
			var x_high: float = x_vals[xi + 1] as float
			if x_high - x_low <= 0.01:
				continue

			# Skip cells fully covered by a blocker.
			var cell_blocked: bool = false
			for r: Rect2 in rects:
				if r.position.x <= x_low + 0.005 and r.position.x + r.size.x >= x_high - 0.005 \
				and r.position.y <= z_low + 0.005 and r.position.y + r.size.y >= z_high - 0.005:
					cell_blocked = true
					break
			if cell_blocked:
				continue

			polys.append(PackedVector2Array([
				Vector2(x_low, z_low),
				Vector2(x_high, z_low),
				Vector2(x_high, z_high),
				Vector2(x_low, z_high),
			]))
	return polys


func _bake_navmesh_now() -> void:
	# No-op while the manual navmesh is in use. Kept so callers from the
	# bake-era still wire up cleanly.
	pass


## Debounced navmesh rebake. Buildings call this on construction
## start / finish + on destruction so dynamic structures actually
## carve the path-planner mesh (NavigationObstacle3D's runtime
## carving doesn't reliably update a pre-baked NavigationRegion).
## Without it, a unit en-route to a build site keeps the path
## computed before the new building existed and grinds against it.
const _NAVMESH_REBAKE_DEBOUNCE_SEC: float = 1.5
var _navmesh_rebake_pending: bool = false
var _navmesh_rebake_last_time: float = -1000.0


func request_navmesh_rebake() -> void:
	if not _nav_region:
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - _navmesh_rebake_last_time >= _NAVMESH_REBAKE_DEBOUNCE_SEC:
		_perform_navmesh_rebake()
		return
	# Otherwise queue exactly one trailing rebake at the end of the
	# debounce window. Multiple buildings completing on the same
	# frame collapse to a single rebake.
	if _navmesh_rebake_pending:
		return
	_navmesh_rebake_pending = true
	var remaining: float = _NAVMESH_REBAKE_DEBOUNCE_SEC - (now - _navmesh_rebake_last_time)
	get_tree().create_timer(maxf(remaining, 0.05)).timeout.connect(_perform_navmesh_rebake)


func _perform_navmesh_rebake() -> void:
	_navmesh_rebake_pending = false
	if not _nav_region:
		return
	_navmesh_rebake_last_time = float(Time.get_ticks_msec()) / 1000.0
	_nav_region.bake_navigation_mesh(false)
	# Refresh the edge-connection margin + cell sizes since some
	# bakes reset them. Without the cell-size sync the navmesh
	# (0.5 cell, 0.1 height) mismatches the NavigationServer's
	# default (0.25/0.25), spamming a warning per rebake.
	var nav_map: RID = _nav_region.get_navigation_map()
	if nav_map.is_valid():
		NavigationServer3D.map_set_edge_connection_margin(nav_map, 1.0)
		NavigationServer3D.map_set_cell_height(nav_map, 0.1)
		NavigationServer3D.map_set_cell_size(nav_map, 0.5)


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
	# Tutorial mode plays out as a mini-mission: the player starts
	# with just a Rook squad and no HQ. The TutorialMission script
	# hands them a Crawler + an HQ as they progress through stages.
	# So if tutorial_mode is on, position the .tscn-placed HQ at
	# the eventual reclaim point but leave it visually un-owned
	# until the mission flips it.
	var settings_for_tut: Node = get_node_or_null("/root/MatchSettings")
	var in_tutorial: bool = settings_for_tut and settings_for_tut.get("tutorial_mode")

	# Tutorial seed bonus — 100 extra salvage on top of the
	# default 300 so the player can comfortably afford the
	# Foundry + Yard + first round of Reactors that the BASE +
	# REACTORS objectives ask for. Non-tutorial play keeps the
	# vanilla starting purse.
	if in_tutorial and resource_manager and resource_manager.has_method("add_salvage"):
		resource_manager.add_salvage(100)

	# Mark the HQ as already constructed
	var hq: Building = $PlayerHQ as Building
	var hq_offset: Vector3 = Vector3.ZERO
	if hq:
		# Tutorial: HQ starts as a NEUTRAL ruin (owner_id 2) at
		# the foundry-ruin reclaim point. The player has no
		# vision around it (FOW filters by friendly), no
		# production from it, and won't lose if it falls. The
		# TutorialMission's stage-3 (BASE) hand-off flips the
		# ownership to 0 so the player can build / produce from
		# it the moment they walk into the cell.
		hq.owner_id = 2 if in_tutorial else 0
		hq.is_constructed = true
		hq.resource_manager = resource_manager
		# Move the player HQ to its mode-specific corner — the .tscn places
		# it at world origin for editor convenience, but real matches want
		# both bases pushed to opposite ends of the map.
		var new_pos: Vector3 = _hq_position_for(0)
		if in_tutorial:
			# Foundry-ruin reclaim point sits at +Z = south on
			# screen. Discovery beats land at z=+50 (cache),
			# +75 (Crawler), +100 (HQ) — all SOUTH of the
			# Foundry Belt central plateau (which spans z=16-34
			# at X=-14..+14). Putting the HQ on the plateau
			# wedged the freshly-spawned Ratchets inside the
			# elevation collider; +100 sits cleanly past it.
			new_pos = Vector3(0.0, 0.0, 100.0)
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

	# Faction-correct starter units. The .tscn-spawned Units node has
	# Anvil mechs hardcoded; if the player picked a different faction
	# we replace each starter with the matching role from their own
	# roster so the opener doesn't include units that aren't in the
	# faction's tech tree. Reuses each unit's existing world position
	# and removes the old node before spawning the replacement.
	_swap_starter_units_to_player_faction()
	# Anvil players keep the original .tscn units (no swap happens),
	# so their starter pop never went through the spawn path that
	# adds_population. Walk the Units children and account for each
	# living squad against the player's resource manager so the pop
	# counter starts at the correct value rather than 0.
	_account_starter_unit_population()

	# Snap the camera so the match opens looking at the player's
	# base — or, in tutorial mode, the player's lone Rook squad at
	# world origin (the HQ at (0, 95) is still neutral and the
	# squad is what the player actually starts the mission with).
	var cam: Camera3D = get_viewport().get_camera_3d() if get_viewport() else null
	if cam:
		var focus: Vector3 = Vector3.ZERO
		if in_tutorial:
			focus = Vector3(0.0, 0.0, 0.0)
		elif hq:
			focus = Vector3(hq.global_position.x, 0.0, hq.global_position.z)
		cam.set("_pivot", focus)
		cam.set("_target_pivot", focus)

	# Wire resource manager to all player buildings
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		var building: Building = node as Building
		if building and building.owner_id == 0:
			building.resource_manager = resource_manager

	resource_manager.update_power()

	# Starter Salvage Crawler. Smooths the early game — the player has
	# a harvester out the gate instead of waiting for the first build
	# cycle to produce one. Anchored just outside the HQ in the
	# direction of map center so the crawler can immediately push out
	# to the nearest wreck field.
	# Tutorial mode: skip the starter Crawler. The TutorialMission
	# hands one to the player at stage 2 ("crawler") so the
	# discovery beat actually plays. Also prune the .tscn-placed
	# starter army down to just one Rook squad and re-position it
	# at world origin — the mission opens with a single scout
	# squad walking northward into the unknown.
	if in_tutorial:
		_prepare_tutorial_starter_units()
		return
	if hq:
		var crawler_scene: PackedScene = load("res://scenes/salvage_crawler.tscn") as PackedScene
		if crawler_scene:
			var crawler: Node3D = crawler_scene.instantiate() as Node3D
			crawler.set("owner_id", 0)
			add_child(crawler)
			var fwd: Vector3 = Vector3.ZERO - hq.global_position
			fwd.y = 0.0
			if fwd.length_squared() > 0.0001:
				fwd = fwd.normalized()
			else:
				fwd = Vector3(0.0, 0.0, -1.0)
			crawler.global_position = hq.global_position + fwd * 11.0


func _setup_ai() -> void:
	# Tutorial mode: skip the normal AI roster entirely and drop a
	# stationary fortified Sable enclave at the south end of the map
	# instead. The enemy doesn't push toward the player; they just
	# defend their camp until the player + the late-arriving Sable
	# ally crack it open.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.get("tutorial_mode"):
		_setup_tutorial_enemy_camp()
		return

	# Spawn one AI HQ + starter army + AIController per non-human entry in
	# the roster. The 1v1 path lights up player_id=1 only; the 2v2 path
	# lights up the ally (1) plus two enemies (3, 4).
	for entry: Dictionary in _current_roster():
		if entry["human"] as bool:
			continue
		_spawn_ai_player(entry["id"] as int, entry["name"] as String)


func _prepare_tutorial_starter_units() -> void:
	## Trim the .tscn-placed starter army down to a single Rook
	## squad and drop it at world origin. The mission opens with
	## a small scout group with no HQ; everything else is unlocked
	## as the player progresses through tutorial stages.
	var units_node: Node = get_node_or_null("Units")
	if not units_node:
		return
	var kept: bool = false
	for child: Node in units_node.get_children():
		var keep: bool = false
		if not kept and ("stats" in child):
			var s: UnitStatResource = child.get("stats") as UnitStatResource
			if s and s.unit_class == &"light":
				keep = true
				kept = true
		if keep:
			(child as Node3D).global_position = Vector3(0.0, 0.0, 0.0)
		else:
			child.queue_free()


func _setup_neutral_patrols_or_skip() -> bool:
	## Tutorial mode skips the standard neutral patrols entirely so
	## the only enemies on the map are the southern fortified camp.
	## Returns true when the standard patrol setup should be skipped
	## (i.e. tutorial is active). Hooked into _setup_neutral_patrols
	## via an early-exit guard.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	return settings != null and settings.get("tutorial_mode")


func _setup_tutorial_enemy_camp() -> void:
	## Stationary Sable enclave at the south end of the map.
	## Builds:
	##   - 1 Headquarters (provides building targets)
	##   - 2 Gun Emplacements (anti-ground turrets)
	##   - 1 SAM Site (anti-air, mainly to make the AlertManager-
	##     side learning curve feel real)
	##   - 1 Sable Fang drone squad (air swarm, AAir-vulnerable)
	##   - 1 Sable Specter ground squad (stationary defenders)
	## Owner_id = 2 (neutral team — the player + ally treat them
	## as enemies, the camp engages anything that walks in range
	## but doesn't move toward the player on its own).
	var ai_res := ResourceManager.new()
	ai_res.name = "TutorialEnemyResources"
	add_child(ai_res)
	# Camp structures.
	var hq_path: String = "res://resources/buildings/headquarters.tres"
	var gun_path: String = "res://resources/buildings/gun_emplacement.tres"
	var sam_path: String = "res://resources/buildings/sam_site.tres"
	# Enclave parked at the NORTH end of the map (-Z = north on
	# screen). The player walks SOUTH through discovery beats
	# (cache 28 -> crawler 58 -> HQ 88), then turns around and
	# pushes back NORTH for the climactic assault. Outer turret
	# ring at z=-115 denies the approach corridor; inner core
	# sits at z=-130 to -140.
	_spawn_tutorial_enemy_building(hq_path, Vector3(0.0, 0.0, -134.0), ai_res, 2)
	# Inner ring of gun emplacements + SAM coverage behind. Tight
	# overlap on every approach axis.
	_spawn_tutorial_enemy_building(gun_path, Vector3(-14.0, 0.0, -124.0), ai_res, 2)
	_spawn_tutorial_enemy_building(gun_path, Vector3(14.0, 0.0, -124.0), ai_res, 2)
	_spawn_tutorial_enemy_building(gun_path, Vector3(-10.0, 0.0, -140.0), ai_res, 2)
	_spawn_tutorial_enemy_building(gun_path, Vector3(10.0, 0.0, -140.0), ai_res, 2)
	_spawn_tutorial_enemy_building(sam_path, Vector3(0.0, 0.0, -118.0), ai_res, 2)
	_spawn_tutorial_enemy_building(sam_path, Vector3(0.0, 0.0, -146.0), ai_res, 2)
	# Outer ring — two more emplacements pushed forward (closer
	# to the player) to deny the obvious approach lane.
	_spawn_tutorial_enemy_building(gun_path, Vector3(-22.0, 0.0, -115.0), ai_res, 2)
	_spawn_tutorial_enemy_building(gun_path, Vector3(22.0, 0.0, -115.0), ai_res, 2)
	# Defenders — two Fang drone swarms (the air drones the player
	# will need AA for) + a couple of Specter ground squads patrolling
	# the camp interior.
	_spawn_tutorial_enemy_unit("res://resources/units/sable_fang.tres", Vector3(-6.0, 0.0, -125.0), 2)
	_spawn_tutorial_enemy_unit("res://resources/units/sable_fang.tres", Vector3(6.0, 0.0, -125.0), 2)
	_spawn_tutorial_enemy_unit("res://resources/units/sable_specter.tres", Vector3(-8.0, 0.0, -130.0), 2)
	_spawn_tutorial_enemy_unit("res://resources/units/sable_specter.tres", Vector3(8.0, 0.0, -130.0), 2)
	_spawn_tutorial_enemy_unit("res://resources/units/sable_specter.tres", Vector3(0.0, 0.0, -140.0), 2)
	# owner_id 2 is the registry's pre-registered NEUTRAL player —
	# treated as enemy by every other player and never allies with
	# anyone, which is exactly the relationship we want for the
	# tutorial enclave (player attacks them; the late-game Sable
	# ally also attacks them).
	# Demote player_id 1 (the would-be 1v1 enemy AI) onto the
	# player's team so the late-arriving Sable strike force the
	# TutorialMission spawns at owner_id 1 reads as friendly.
	# PlayerRegistry's are_allied lookup goes through team_id.
	var registry_for_ally: PlayerRegistry = get_node_or_null("PlayerRegistry") as PlayerRegistry
	if registry_for_ally:
		var ally_state: PlayerState = registry_for_ally.get_state(1)
		if ally_state:
			ally_state.team_id = 0
			# Wipe the cached are_allied lookup so the change
			# takes effect for any subsequent query.
			registry_for_ally.set("_allied_cache", {})


func _spawn_tutorial_enemy_building(stats_path: String, pos: Vector3, rm: ResourceManager, owner_id: int) -> void:
	var stats: BuildingStatResource = load(stats_path) as BuildingStatResource
	if not stats:
		return
	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	if not building_scene:
		return
	var b: Building = building_scene.instantiate() as Building
	if not b:
		return
	b.stats = stats
	b.owner_id = owner_id
	b.is_constructed = true
	b.resource_manager = rm
	add_child(b)
	b.global_position = pos


func _spawn_tutorial_enemy_unit(stats_path: String, pos: Vector3, owner_id: int) -> void:
	var stats: UnitStatResource = load(stats_path) as UnitStatResource
	if not stats:
		return
	var scene_path: String = "res://scenes/aircraft.tscn" if stats.is_aircraft else "res://scenes/unit.tscn"
	var ps: PackedScene = load(scene_path) as PackedScene
	if not ps:
		return
	var node: Node3D = ps.instantiate() as Node3D
	if not node:
		return
	node.set("stats", stats)
	node.set("owner_id", owner_id)
	var units_node: Node = get_node_or_null("Units")
	if units_node:
		units_node.add_child(node)
	else:
		add_child(node)
	node.global_position = pos


func _spawn_ai_player(player_id: int, display_name: String) -> void:
	# Resource manager — uses a name unique per player so multi-AI 2v2
	# scenes don't clash. Legacy code that asks for "AIResourceManager"
	# still finds the player_id=1 manager since it gets that exact name.
	var ai_res := ResourceManager.new()
	ai_res.name = ("AIResourceManager" if player_id == 1 else "AIResourceManager_%d" % player_id)
	ai_res.salvage = 600
	# So `update_population_cap` knows whose buildings to count. The
	# manager would otherwise default to owner 0 and tally the player's
	# foundries against the AI's population pool.
	ai_res.owner_id = player_id
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
	add_child(ai_hq)
	ai_hq.global_position = _hq_position_for(player_id)
	ai_hq.is_constructed = true
	ai_hq._apply_placeholder_shape()

	# Starter army anchored relative to the HQ. The unit offsets are
	# laid out in `fwd` (toward map center) and `right` (perpendicular)
	# axes — earlier code used world-space x/z offsets, which for the
	# 2v2 ally at the (60, 100) corner reliably parked one starter unit
	# inside the HQ collision (corner spawn → world +x went BACK into
	# the building). Forward/right space puts every starter clearly out
	# in open ground regardless of HQ corner.
	# Faction-aware starter army — pick the engineer + medium mechs from
	# whichever faction this AI plays. Sable AIs ship Riggers and Jackals
	# instead of Ratchets and Rooks; Anvil AIs unchanged.
	var ai_faction: int = _faction_id_for_player(player_id)
	var ratchet_stats: UnitStatResource = _unit_for_role(ai_faction, "engineer")
	var rook_stats: UnitStatResource = _unit_for_role(ai_faction, "medium")
	if not ratchet_stats:
		ratchet_stats = load("res://resources/units/anvil_ratchet.tres") as UnitStatResource
	if not rook_stats:
		rook_stats = load("res://resources/units/anvil_rook.tres") as UnitStatResource
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
	# Population accounting — direct spawn path bypasses the building
	# queue, so we have to manually add the unit's pop cost to the
	# owner's resource manager. Without this, starter units (and AI
	# starter army) never increment population, which made e.g. a
	# Specter squad of population 8 register as 0 against the cap.
	# remove_population fires at unit death so the bookkeeping closes.
	var rm: Node = _resource_manager_for_owner(player_id)
	if rm and rm.has_method("add_population"):
		rm.add_population(unit_stats.population)


func _resource_manager_for_owner(player_id: int) -> Node:
	## Routes through PlayerRegistry to find the ResourceManager that
	## tracks this owner's pop / salvage / fuel. Falls back to legacy
	## node names if the registry is unreachable.
	var registry: Node = get_node_or_null("PlayerRegistry")
	if registry and registry.has_method("get_resource_manager"):
		var rm: Node = registry.get_resource_manager(player_id)
		if rm:
			return rm
	# Legacy fallback — covers the test arena being run directly without
	# PlayerRegistry having registered all entries yet.
	if player_id == 0:
		return get_node_or_null("ResourceManager")
	return get_node_or_null("AIResourceManager")


## --- Faction roster lookup -----------------------------------------------

## Maps a unit's `unit_class` (engineer / light / medium / heavy) to the
## stat resource for that role in the given faction. Used to swap the
## .tscn-spawned starter army into faction-correct equivalents and to
## let the AI pick units that match its own faction.
const _FACTION_ROSTER: Dictionary = {
	# FactionId.ANVIL = 0
	0: {
		"engineer": "res://resources/units/anvil_ratchet.tres",
		"light": "res://resources/units/anvil_hound.tres",
		"medium": "res://resources/units/anvil_rook.tres",
		"heavy": "res://resources/units/anvil_bulwark.tres",
	},
	# FactionId.SABLE = 1
	1: {
		"engineer": "res://resources/units/sable_rigger.tres",
		"light": "res://resources/units/sable_specter.tres",
		"medium": "res://resources/units/sable_jackal.tres",
		"heavy": "res://resources/units/sable_harbinger.tres",
	},
}


func _faction_id_for_player(player_id: int) -> int:
	## Resolves which faction this player_id is meant to play. Per-AI
	## override (set by the menu's per-AI faction dropdowns) wins; if
	## none, allies play `player_faction` and enemies play
	## `enemy_faction`. Falls back to ANVIL when MatchSettings isn't
	## reachable.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if not settings:
		return 0
	# Per-AI override has the highest priority — the menu sets these
	# from the per-AI faction dropdown.
	if settings.has_method("has_ai_faction") and settings.has_ai_faction(player_id):
		return settings.get_ai_faction(player_id) as int
	var roster: Array[Dictionary] = _current_roster()
	var local_team: int = 0
	var target_team: int = 0
	for entry: Dictionary in roster:
		if entry["human"] as bool:
			local_team = entry["team"] as int
		if (entry["id"] as int) == player_id:
			target_team = entry["team"] as int
	var pf: int = (settings.get("player_faction") as int) if "player_faction" in settings else 0
	var ef: int = (settings.get("enemy_faction") as int) if "enemy_faction" in settings else 0
	return pf if target_team == local_team else ef


func _unit_for_role(faction_id: int, role: String) -> UnitStatResource:
	## Loads the stat resource for the given role in the given faction.
	## Returns null if either faction or role is unknown.
	if not _FACTION_ROSTER.has(faction_id):
		return null
	var roster: Dictionary = _FACTION_ROSTER[faction_id] as Dictionary
	var path: String = roster.get(role, "") as String
	if path.is_empty():
		return null
	return load(path) as UnitStatResource


func _role_for_unit_class(unit_class: StringName) -> String:
	# StringName comparison — convert via String to keep the match cheap.
	var c: String = String(unit_class).to_lower()
	if c == "engineer" or c == "light" or c == "medium" or c == "heavy":
		return c
	return ""


func _account_starter_unit_population() -> void:
	## Walks the player-owned units already in the scene and adds each
	## unit's population to the ResourceManager. The faction-swap
	## function uses _spawn_ai_unit which already accounts; this covers
	## the surviving .tscn-spawned units when no swap happens.
	var rm: Node = _resource_manager_for_owner(0)
	if not rm or not rm.has_method("add_population"):
		return
	# Reset to zero before re-adding so we don't double-count when the
	# function is called after the swap (which already added pop for
	# the new units).
	rm.set("population", 0)
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var oid: int = (node.get("owner_id") as int) if "owner_id" in node else -1
		if oid != 0:
			continue
		var stats_v: Variant = node.get("stats") if "stats" in node else null
		if not stats_v:
			continue
		var pop: int = stats_v.get("population") as int
		if pop > 0:
			rm.add_population(pop)


func _swap_starter_units_to_player_faction() -> void:
	## Replaces the .tscn-hardcoded Anvil starter mechs with the matching
	## role from the player's chosen faction. Reuses each unit's existing
	## world position so the starter formation stays visually identical
	## regardless of which faction the player picked.
	var player_faction: int = _faction_id_for_player(0)
	var units_node: Node = get_node_or_null("Units")
	if not units_node:
		return
	if player_faction != 0:
		var specs: Array[Dictionary] = []
		for child: Node in units_node.get_children():
			if not (child is Unit):
				continue
			var u: Unit = child as Unit
			if not u.stats:
				continue
			var role: String = _role_for_unit_class(u.stats.unit_class)
			if role.is_empty():
				continue
			specs.append({"pos": u.global_position, "role": role})
			child.queue_free()
		for spec: Dictionary in specs:
			var role: String = spec["role"] as String
			var new_stats: UnitStatResource = _unit_for_role(player_faction, role)
			if not new_stats:
				continue
			_spawn_ai_unit(new_stats, spec["pos"] as Vector3, 0)

	# Removed the free starter heavy (Bulwark / Harbinger) — was a
	# faction-comparison playtest aid, not real economy. Players
	# now have to grind through the foundry build path to see
	# their heavy on the field, which matches every other unit.


func _setup_fuel_deposits() -> void:
	var deposit_script: GDScript = load("res://scripts/fuel_deposit.gd") as GDScript
	if not deposit_script:
		return

	var positions: Array[Vector3]
	if _is_ashplains():
		# Ashplains has fewer deposits than Foundry Belt — sparser map,
		# the central deposit is THE objective.
		positions = _deposit_positions_ashplains_2v2() if _is_2v2() else _deposit_positions_ashplains_1v1()
	elif _is_iron_gate():
		# Iron Gate Crossing — 4 deposits scattered along the central
		# corridor + the east/west flanks so the Sable flanker can
		# reach two of them with covered approaches.
		positions = [
			Vector3(0.0, 0.0, 80.0),    # Player safe deposit
			# Was (0, 0, -80) -- sat inside the south plateau's body
			# (z range -82..-68). Moved to z=-95 so it's clear of the
			# plateau and its south ramp foot.
			Vector3(0.0, 0.0, -95.0),   # Enemy safe deposit
			Vector3(55.0, 0.0, 0.0),    # East flank contested
			Vector3(-55.0, 0.0, 0.0),   # West flank contested
		]
	else:
		positions = _deposit_positions_2v2() if _is_2v2() else _deposit_positions_1v1()

	for pos: Vector3 in positions:
		var deposit: Node3D = deposit_script.new()
		add_child(deposit)
		deposit.global_position = pos

	# 2v2 — extra small back-/side-of-base satellite deposits.
	# Previously gated to Foundry Belt only because Ashplains was meant
	# to be lean; the new design wants more resources on the desert
	# map too, so the small satellites apply to both maps now.
	if _is_2v2():
		for pos: Vector3 in _small_deposit_positions_2v2():
			var small: Node3D = deposit_script.new()
			# Lower yield + smaller capture radius than the main deposits —
			# rewards expansion without making them a primary fight.
			small.fuel_per_second = 2.0
			small.capture_radius = 8.0
			small.capture_time = 18.0
			small.scale = Vector3(0.65, 0.65, 0.65)
			add_child(small)
			small.global_position = pos


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
	# Plus four *small* satellite deposits to the side and back of each
	# team (lower yield) so 2v2 has more economic surface than 1v1.
	return [
		Vector3(-30, 0, 70),    # Player NW safe
		Vector3(30, 0, 70),     # Ally NE safe
		Vector3(-30, 0, -70),   # Enemy SW safe
		Vector3(30, 0, -70),    # Enemy SE safe
		Vector3(0, 0, 0),       # Central contested — the hot zone
	]


## Ashplains Crossing 1v1 layout. Per the V2 spec: 1 safe-area deposit per
## player + 1 large mid-map deposit (the primary objective, heavy patrol).
## Map orientation matches Foundry Belt — player at +z, AI at -z.
func _deposit_positions_ashplains_1v1() -> Array[Vector3]:
	return [
		Vector3(0, 0, 80),     # Player safe (north)
		Vector3(0, 0, -80),    # AI safe (south)
		# Was (0, 0, 0) -- sat under the central plateau's N ramp
		# (which extends to ~z=12.5). Moved to z=20 so the deposit
		# lives in the open corridor between the central and northern
		# plateaus, still in the contested mid-zone.
		Vector3(0, 0, 20),     # Central — the primary objective, Heavy patrol
		# Additional flank deposits — give the player meaningful
		# expansion targets beyond the safe + central. Mid-z so they
		# sit between safe and central, encouraging scouting pushes.
		Vector3(80, 0, 40),    # East flank, player side
		Vector3(-80, 0, 40),   # West flank, player side
		Vector3(80, 0, -40),   # East flank, AI side
		Vector3(-80, 0, -40),  # West flank, AI side
	]


## Ashplains Crossing 2v2 layout. Per the spec: per-team safe deposits +
## central + 1 deposit on each flank (Medium patrols).
func _deposit_positions_ashplains_2v2() -> Array[Vector3]:
	return [
		Vector3(-30, 0, 70),    # Team A west safe
		Vector3(30, 0, 70),     # Team A east safe
		Vector3(-30, 0, -70),   # Team B west safe
		Vector3(30, 0, -70),    # Team B east safe
		# Same (0, 0, 0) -> (0, 0, 20) move as 1v1 — central plateau's
		# N ramp foot sits over the previous spot.
		Vector3(0, 0, 20),      # Central — primary objective
		Vector3(70, 0, 0),      # East flank
		Vector3(-70, 0, 0),     # West flank
	]


## Smaller back-/side-of-base deposits for 2v2. Returned separately so they
## can be flagged as `small = true` on the deposit script (lower yield).
func _small_deposit_positions_2v2() -> Array[Vector3]:
	return [
		# Behind / outboard of each team's base corner. Far enough out that
		# they're a meaningful map-control commitment, not a free pickup.
		Vector3(-95, 0, 110),    # Far west of team A back line
		Vector3(95, 0, 110),     # Far east of team A back line
		Vector3(-95, 0, -110),   # Far west of team B back line
		Vector3(95, 0, -110),    # Far east of team B back line
		# Side flanks — between safe and central, slightly off-axis so they
		# read as side approaches rather than another mid-line objective.
		Vector3(-80, 0, 35),     # West side of team A
		Vector3(80, 0, 35),      # East side of team A
		Vector3(-80, 0, -35),    # West side of team B
		Vector3(80, 0, -35),     # East side of team B
	]


func _setup_terrain() -> void:
	if _is_ashplains():
		_setup_terrain_ashplains()
		return
	if _is_iron_gate():
		_setup_terrain_iron_gate()
		return
	_setup_terrain_foundry_belt()


func _setup_terrain_foundry_belt() -> void:
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
		# Back-door chokepoint pieces — moved out + away from the ridge
		# ramps (E ramp footprint x∈[78, 84], z∈[-4, +4]) so the ramp
		# approach lanes stay open.
		{"pos": Vector3(92, 0, 12), "size": Vector3(7.0, 4.0, 7.0), "kind": "ruin"},
		{"pos": Vector3(92, 0, -12), "size": Vector3(7.0, 4.0, 7.0), "kind": "ruin"},
		{"pos": Vector3(-92, 0, 12), "size": Vector3(7.0, 4.0, 7.0), "kind": "ruin"},
		{"pos": Vector3(-92, 0, -12), "size": Vector3(7.0, 4.0, 7.0), "kind": "ruin"},
		# Corner fillers.
		{"pos": Vector3(120, 0, 120), "size": Vector3(4.5, 3.0, 4.5), "kind": "ruin"},
		{"pos": Vector3(-120, 0, 120), "size": Vector3(5.0, 3.0, 4.0), "kind": "ruin"},
		{"pos": Vector3(120, 0, -120), "size": Vector3(4.0, 3.0, 5.0), "kind": "ruin"},
		{"pos": Vector3(-120, 0, -120), "size": Vector3(4.5, 2.5, 4.5), "kind": "ruin"},
		# Mid-edge filler.
		{"pos": Vector3(110, 0, 50), "size": Vector3(3.0, 2.5, 3.5), "kind": "rock"},
		{"pos": Vector3(-110, 0, 55), "size": Vector3(3.5, 2.0, 3.0), "kind": "rock"},
		{"pos": Vector3(110, 0, -50), "size": Vector3(3.5, 2.5, 3.0), "kind": "rock"},
		{"pos": Vector3(-110, 0, -45), "size": Vector3(3.0, 2.0, 3.5), "kind": "rock"},
		# Scrap-pile terrain.
		{"pos": Vector3(40, 0, 50), "size": Vector3(5.0, 1.0, 5.0), "kind": "scrap_pile"},
		{"pos": Vector3(-40, 0, 50), "size": Vector3(4.5, 1.2, 5.5), "kind": "scrap_pile"},
		{"pos": Vector3(40, 0, -50), "size": Vector3(4.5, 1.0, 5.0), "kind": "scrap_pile"},
		{"pos": Vector3(-40, 0, -50), "size": Vector3(5.0, 1.2, 4.5), "kind": "scrap_pile"},
		{"pos": Vector3(0, 0, 50), "size": Vector3(6.0, 0.9, 4.5), "kind": "scrap_pile"},
		{"pos": Vector3(0, 0, -65), "size": Vector3(5.5, 1.0, 5.0), "kind": "scrap_pile"},
	]
	# Tutorial mode skips every piece sitting on the centre-line
	# (X = 0) — the southward discovery walk runs along that
	# axis and the player's reinforce / Crawler / Ratchet
	# spawns kept landing inside scrap piles + rock chunks.
	# Off-centerline pieces (which the player passes BUT doesn't
	# stand on) stay so the map still reads as inhabited.
	var settings_for_terrain: Node = get_node_or_null("/root/MatchSettings")
	var skip_centerline: bool = settings_for_terrain != null and settings_for_terrain.get("tutorial_mode")
	for piece: Dictionary in pieces:
		var p_pos: Vector3 = piece["pos"] as Vector3
		if skip_centerline and absf(p_pos.x) < 0.5:
			continue
		_spawn_terrain_piece(p_pos, piece["size"] as Vector3, piece["kind"] as String)

	# Rock outcrops — bigger, multi-faceted natural rock formations
	# (5-7 box chunks fused at angles) for organic stone silhouettes
	# rather than monolithic boxes. The two centre-line outcrops
	# (z=+75 / -90) are skipped in tutorial mode because they sit
	# right where the mission scripts the Crawler hand-off + the
	# enemy enclave approach, and were either swallowing the
	# spawned Crawler or wedging units against unexpected cover.
	var settings_for_outcrops: Node = get_node_or_null("/root/MatchSettings")
	var skip_centre_outcrops: bool = settings_for_outcrops != null and settings_for_outcrops.get("tutorial_mode")
	var outcrop_positions: Array[Vector3] = [
		Vector3(-25, 0, 60), Vector3(25, 0, -60),
		Vector3(55, 0, 12), Vector3(-55, 0, -12),
	]
	if not skip_centre_outcrops:
		outcrop_positions.append(Vector3(0, 0, 75))
		outcrop_positions.append(Vector3(0, 0, -90))
	for outcrop_pos: Vector3 in outcrop_positions:
		_spawn_rock_outcrop(outcrop_pos, randf_range(4.0, 6.5))

	# Ruined building complexes — multi-block collapsed industrial
	# structures. Reads as "block of houses / factory wing", provides
	# meaningful pathing blockage in the otherwise open mid-map.
	for complex: Dictionary in [
		# Mid-east complex — between contested mid and the east flank.
		{"pos": Vector3(35, 0, 40), "rot": 0.3, "size": Vector2(11.0, 6.5)},
		# Mid-west mirror.
		{"pos": Vector3(-35, 0, -40), "rot": 0.3, "size": Vector2(11.0, 6.5)},
		# Larger collapsed factory wing on the player approach.
		{"pos": Vector3(45, 0, 65), "rot": -0.5, "size": Vector2(13.0, 7.0)},
		# AI mirror.
		{"pos": Vector3(-45, 0, -65), "rot": -0.5, "size": Vector2(13.0, 7.0)},
		# Mid-map block near the apex scar — extra cover around the
		# central battlefield.
		{"pos": Vector3(-20, 0, -55), "rot": 1.1, "size": Vector2(9.0, 6.0)},
		{"pos": Vector3(20, 0, 55), "rot": 1.1, "size": Vector2(9.0, 6.0)},
	]:
		_spawn_ruin_complex(complex["pos"] as Vector3, complex["size"] as Vector2, complex["rot"] as float)

	# Boulder clusters — close-spaced small rocks that read as a
	# weathered formation rather than a single big shape.
	var cluster_centers: Array[Vector3] = [
		Vector3(85, 0, 25),
		Vector3(-85, 0, 25),
		Vector3(85, 0, -25),
		Vector3(-85, 0, -25),
	]
	for c: Vector3 in cluster_centers:
		_spawn_boulder_cluster(c)

	# Neutral derelict structures — foundries that read as a defunct
	# industrial site, plus a handful of automated turrets that still
	# track threats in their kill zone. Owned by the neutral player so
	# they're hostile to everyone; destroying them drops a wreck (35%
	# salvage refund of build cost) which doubles as a reason to push
	# into the mid-map. Both groups are skipped in tutorial mode —
	# the foundries clutter the lane the tutorial drives the player
	# down + the dead-centre turret was killing the starting Rook
	# squad before they could move.
	var settings_for_neutrals: Node = get_node_or_null("/root/MatchSettings")
	var skip_neutrals: bool = settings_for_neutrals != null and settings_for_neutrals.get("tutorial_mode")
	var foundry_stats: BuildingStatResource = load("res://resources/buildings/basic_foundry.tres") as BuildingStatResource
	if foundry_stats and not skip_neutrals:
		_spawn_neutral_building(foundry_stats, Vector3(38, 0, 22), 0.4)
		_spawn_neutral_building(foundry_stats, Vector3(-38, 0, -22), -0.4)
	var turret_stats: BuildingStatResource = load("res://resources/buildings/gun_emplacement.tres") as BuildingStatResource
	if turret_stats and not skip_neutrals:
		_spawn_neutral_building(turret_stats, Vector3(0, 0, 0), 0.0)
		_spawn_neutral_building(turret_stats, Vector3(70, 0, 8), 0.0)
		_spawn_neutral_building(turret_stats, Vector3(-70, 0, -8), 0.0)


func _setup_terrain_iron_gate() -> void:
	## V3 §"Pillar 6" — Iron Gate Crossing. A semi-controlled
	## district between corporate cores and the wild zones, with
	## chokepoints designed to favour stealth flanking over heavy
	## pushes. Terrain composition:
	##   - Open central corridor along the z-axis (Anvil push lane)
	##   - Dense ruin clusters on each east/west flank (Sable cover)
	##   - Two large elevated overlooks at NW and SE corners
	##   - Rocky chokepoints near the spawns to slow rushes
	##   - 4 forward-deploy "Mesh anchor" pads near the centre that
	##     read as flat structural footprints, suggesting Black Pylon
	##     placement spots
	# West-flank ruin cluster — dense covered approach for Sable
	# flankers.
	var pieces: Array[Dictionary] = [
		# West dense ruin cluster
		{"pos": Vector3(-72, 0, 36), "size": Vector3(5.0, 4.0, 4.5), "kind": "ruin"},
		{"pos": Vector3(-78, 0, 22), "size": Vector3(4.0, 3.5, 5.0), "kind": "ruin"},
		{"pos": Vector3(-66, 0, 8), "size": Vector3(4.5, 3.0, 4.0), "kind": "ruin"},
		{"pos": Vector3(-78, 0, -8), "size": Vector3(4.0, 3.5, 5.0), "kind": "ruin"},
		{"pos": Vector3(-72, 0, -22), "size": Vector3(5.0, 3.0, 4.0), "kind": "ruin"},
		{"pos": Vector3(-66, 0, -38), "size": Vector3(4.0, 4.5, 4.0), "kind": "ruin"},
		# East mirror cluster
		{"pos": Vector3(72, 0, 36), "size": Vector3(5.0, 4.0, 4.5), "kind": "ruin"},
		{"pos": Vector3(78, 0, 22), "size": Vector3(4.0, 3.5, 5.0), "kind": "ruin"},
		{"pos": Vector3(66, 0, 8), "size": Vector3(4.5, 3.0, 4.0), "kind": "ruin"},
		{"pos": Vector3(78, 0, -8), "size": Vector3(4.0, 3.5, 5.0), "kind": "ruin"},
		{"pos": Vector3(72, 0, -22), "size": Vector3(5.0, 3.0, 4.0), "kind": "ruin"},
		{"pos": Vector3(66, 0, -38), "size": Vector3(4.0, 4.5, 4.0), "kind": "ruin"},
		# Spawn-area chokepoint cover (north/south).
		{"pos": Vector3(20, 0, 90), "size": Vector3(4.5, 3.5, 4.0), "kind": "rock"},
		{"pos": Vector3(-20, 0, 90), "size": Vector3(4.0, 3.5, 4.5), "kind": "rock"},
		{"pos": Vector3(20, 0, -90), "size": Vector3(4.0, 3.5, 4.5), "kind": "rock"},
		{"pos": Vector3(-20, 0, -90), "size": Vector3(4.5, 3.5, 4.0), "kind": "rock"},
		# Mid-line cover — keep the central corridor mostly open but
		# add a few rocks to break up sightlines.
		{"pos": Vector3(0, 0, 18), "size": Vector3(3.0, 2.5, 3.0), "kind": "rock"},
		{"pos": Vector3(0, 0, -18), "size": Vector3(3.0, 2.5, 3.0), "kind": "rock"},
		# Scrap-pile salvage scattered across the contested zones.
		{"pos": Vector3(40, 0, 30), "size": Vector3(4.0, 1.0, 4.0), "kind": "scrap_pile"},
		{"pos": Vector3(-40, 0, 30), "size": Vector3(4.0, 1.0, 4.0), "kind": "scrap_pile"},
		{"pos": Vector3(40, 0, -30), "size": Vector3(4.0, 1.0, 4.0), "kind": "scrap_pile"},
		{"pos": Vector3(-40, 0, -30), "size": Vector3(4.0, 1.0, 4.0), "kind": "scrap_pile"},
		{"pos": Vector3(0, 0, 50), "size": Vector3(5.0, 1.0, 4.5), "kind": "scrap_pile"},
		{"pos": Vector3(0, 0, -50), "size": Vector3(5.0, 1.0, 4.5), "kind": "scrap_pile"},
	]
	for piece: Dictionary in pieces:
		_spawn_terrain_piece(piece["pos"] as Vector3, piece["size"] as Vector3, piece["kind"] as String)

	# Forward Mesh anchor pads — flat low platforms at four spots
	# along the centre line. Visually they read as cleared concrete
	# foundations; tactically they're natural Black Pylon homes.
	# Built as terrain pieces (collision-blocking but very short)
	# so a scout can read "this is a built spot" at a glance.
	var pad_positions: Array[Vector3] = [
		Vector3(0, 0, 28),
		Vector3(0, 0, -28),
		Vector3(36, 0, 0),
		Vector3(-36, 0, 0),
	]
	for pad_pos: Vector3 in pad_positions:
		_spawn_terrain_piece(pad_pos, Vector3(3.0, 0.3, 3.0), "scrap_pile")

	# Multi-block ruin complexes (mid-flank) — bigger collapsed
	# structures that read as the Iron Gate's namesake militarised
	# infrastructure.
	for complex_data: Dictionary in [
		{"pos": Vector3(48, 0, 56), "rot": 0.6, "size": Vector2(11.0, 7.0)},
		{"pos": Vector3(-48, 0, 56), "rot": -0.6, "size": Vector2(11.0, 7.0)},
		{"pos": Vector3(48, 0, -56), "rot": 0.6, "size": Vector2(11.0, 7.0)},
		{"pos": Vector3(-48, 0, -56), "rot": -0.6, "size": Vector2(11.0, 7.0)},
	]:
		_spawn_ruin_complex(complex_data["pos"] as Vector3, complex_data["size"] as Vector2, complex_data["rot"] as float)


func _setup_terrain_ashplains() -> void:
	# Ashplains Crossing — volcanic ash flats. The "industrial plant
	# ruins" that previously sat at flank-mid have been replaced with
	# rock outcrops because ruined buildings on a desert / volcanic
	# map didn't make sense. Plus a much denser scattering of small
	# scrap piles (resource opportunities) so the map isn't visually
	# empty at standard zoom — the player should always have a few
	# salvage targets within scouting range.
	var pieces: Array[Dictionary] = [
		# Standalone rock formations across the plain — replacing the
		# previous ruin clusters at the same approximate locations so
		# the strategic cover layout stays similar (something to push
		# around on each flank).
		{"pos": Vector3(55, 0, 40), "size": Vector3(2.4, 2.0, 2.4), "kind": "rock"},
		{"pos": Vector3(-55, 0, -40), "size": Vector3(2.4, 2.0, 2.4), "kind": "rock"},
		{"pos": Vector3(70, 0, -55), "size": Vector3(2.6, 2.2, 2.6), "kind": "rock"},
		{"pos": Vector3(-70, 0, 55), "size": Vector3(2.6, 2.2, 2.6), "kind": "rock"},
		# Corner / boundary rocks — the very edges of the playable area
		# don't read as a perfectly flat boundary.
		{"pos": Vector3(115, 0, 100), "size": Vector3(3.0, 2.0, 3.0), "kind": "rock"},
		{"pos": Vector3(-115, 0, 100), "size": Vector3(3.0, 2.0, 3.0), "kind": "rock"},
		{"pos": Vector3(115, 0, -100), "size": Vector3(3.0, 2.0, 3.0), "kind": "rock"},
		{"pos": Vector3(-115, 0, -100), "size": Vector3(3.0, 2.0, 3.0), "kind": "rock"},
		# Mid-flank rock cluster anchors (was ruins). Three rocks each
		# in a loose triangle so the silhouette reads as a small rocky
		# outcropping rather than a single boulder.
		{"pos": Vector3(-28, 0, 16), "size": Vector3(3.0, 2.5, 3.0), "kind": "rock"},
		{"pos": Vector3(-34, 0, 10), "size": Vector3(2.6, 2.2, 2.6), "kind": "rock"},
		{"pos": Vector3(-22, 0, 8), "size": Vector3(2.4, 2.0, 2.8), "kind": "rock"},
		{"pos": Vector3(28, 0, -16), "size": Vector3(3.0, 2.5, 3.0), "kind": "rock"},
		{"pos": Vector3(34, 0, -10), "size": Vector3(2.6, 2.2, 2.6), "kind": "rock"},
		{"pos": Vector3(22, 0, -8), "size": Vector3(2.4, 2.0, 2.8), "kind": "rock"},
	]
	# Many scattered small scrap piles for resource scouting + visual
	# density. Mirrored across both teams' territory plus mid-flank
	# spread so the map has consistent salvage targets at any zoom.
	# Each pile is small (~2u) so they don't act as cover, just
	# economic incentive to push out.
	var scrap_pile_positions: Array[Vector3] = [
		# Player half (z > 0)
		Vector3(40, 0, 50), Vector3(-40, 0, 50),
		Vector3(15, 0, 60), Vector3(-15, 0, 60),
		Vector3(60, 0, 35), Vector3(-60, 0, 35),
		Vector3(45, 0, 75), Vector3(-45, 0, 75),
		Vector3(80, 0, 60), Vector3(-80, 0, 60),
		Vector3(20, 0, 90), Vector3(-20, 0, 90),
		Vector3(95, 0, 90), Vector3(-95, 0, 90),
		Vector3(110, 0, 50), Vector3(-110, 0, 50),
		# AI half (z < 0) — mirrored
		Vector3(40, 0, -50), Vector3(-40, 0, -50),
		Vector3(15, 0, -60), Vector3(-15, 0, -60),
		Vector3(60, 0, -35), Vector3(-60, 0, -35),
		Vector3(45, 0, -75), Vector3(-45, 0, -75),
		Vector3(80, 0, -60), Vector3(-80, 0, -60),
		Vector3(20, 0, -90), Vector3(-20, 0, -90),
		Vector3(95, 0, -90), Vector3(-95, 0, -90),
		Vector3(110, 0, -50), Vector3(-110, 0, -50),
		# Mid-flanks (z ≈ 0) — sparser so the central ridge area still
		# reads as the contested high-stakes zone.
		Vector3(90, 0, 18), Vector3(-90, 0, 18),
		Vector3(90, 0, -18), Vector3(-90, 0, -18),
	]
	for sp: Vector3 in scrap_pile_positions:
		# Per-pile size jitter so the scattering doesn't look stamped.
		var sx: float = randf_range(1.6, 2.6)
		var sz: float = randf_range(1.6, 2.6)
		var sy: float = randf_range(0.5, 1.0)
		pieces.append({"pos": sp, "size": Vector3(sx, sy, sz), "kind": "scrap_pile"})
	for piece: Dictionary in pieces:
		_spawn_terrain_piece(piece["pos"] as Vector3, piece["size"] as Vector3, piece["kind"] as String)

	# Scattered abandoned reactors — neutral buildings dotting the ash
	# flats. Visually they're basic_generator power buildings; tactically
	# they're destructible salvage drops that give the desert map a
	# narrative reason for the warm orange glow. Locations are mirrored
	# across z=0 so neither side has an extra reactor to claim.
	var reactor_stats: BuildingStatResource = load("res://resources/buildings/basic_generator.tres") as BuildingStatResource
	if reactor_stats:
		var reactor_positions: Array[Vector3] = [
			Vector3(48, 0, 28),
			Vector3(-48, 0, 28),
			Vector3(48, 0, -28),
			Vector3(-48, 0, -28),
			Vector3(0, 0, 65),
			Vector3(0, 0, -65),
		]
		for rp: Vector3 in reactor_positions:
			_spawn_neutral_building(reactor_stats, rp, randf_range(-PI, PI))


func _decorate_ruin_block(root: Node3D, piece_size: Vector3, center_offset: Vector3 = Vector3.ZERO, add_roof_details: bool = true) -> void:
	## Adds building-character details (windows, antennae, half-collapsed
	## corner) to a ruin block of `piece_size` centered at `center_offset`
	## within `root`. Pass center_offset = Vector3.ZERO for the base block,
	## or the upper-story's local position so windows sit on the smaller
	## block on top.
	var hx: float = piece_size.x * 0.5
	var hy: float = piece_size.y * 0.5
	var hz: float = piece_size.z * 0.5

	var window_mat := StandardMaterial3D.new()
	# Dark window panels, very faint emission so they pick up at night.
	window_mat.albedo_color = Color(0.04, 0.05, 0.07, 1.0)
	window_mat.emission_enabled = true
	window_mat.emission = Color(0.10, 0.16, 0.22, 1.0)
	window_mat.emission_energy_multiplier = 0.18
	window_mat.roughness = 0.4

	# Skip windows on really small ruin chunks — they read as rubble.
	if piece_size.x >= 2.0 and piece_size.z >= 2.0 and piece_size.y >= 1.6:
		# Row count scales with block height — taller blocks get more
		# stacked window bands. Even small blocks get 2 rows now so the
		# upper-story block doesn't read as featureless concrete.
		var rows: int = 1
		if piece_size.y >= 3.6:
			rows = 3
		elif piece_size.y >= 2.0:
			rows = 2
		# Window pitch leaves an inset above and below so windows never
		# land on the top edge (which used to push them above the roof).
		var window_w: float = 0.36
		var window_h: float = 0.42
		var v_inset: float = 0.35
		var available_h: float = maxf(piece_size.y - v_inset * 2.0, window_h)
		var row_pitch: float = available_h / float(rows + 1)
		for face_dir: Vector3 in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
			var face_w: float = piece_size.x if face_dir.z != 0 else piece_size.z
			var cols: int = 1
			if face_w >= 3.5:
				cols = 3
			elif face_w >= 2.4:
				cols = 2
			for row: int in rows:
				# Local-y of this row, relative to the block center.
				# Range stays in [-hy + v_inset, +hy - v_inset], so
				# windows never poke above the roof or below the base.
				var row_y: float = -hy + v_inset + row_pitch * float(row + 1)
				for col: int in cols:
					if randf() < 0.25:
						continue  # ~25% missing for "collapsed" feel
					var window_mesh := MeshInstance3D.new()
					var window_box := BoxMesh.new()
					window_box.size = Vector3(window_w, window_h, 0.05)
					window_mesh.mesh = window_box
					var col_offset: float = 0.0
					if cols > 1:
						col_offset = (float(col) - float(cols - 1) * 0.5) * (face_w / float(cols + 1))
					var pos := Vector3(0, row_y, 0)
					if absf(face_dir.z) > 0.5:
						pos.x = col_offset
						pos.z = face_dir.z * (hz + 0.03)
					else:
						pos.x = face_dir.x * (hx + 0.03)
						pos.z = col_offset
						window_mesh.rotation.y = PI * 0.5
					window_mesh.position = pos + center_offset
					window_mesh.set_surface_override_material(0, window_mat)
					root.add_child(window_mesh)

	# Antennae and corner-collapse are roof-level details — only
	# added when this is the topmost block in the building. For a base
	# block with an upper-story we skip them so antennae poke from the
	# real roof, not from underneath the upper-story.
	if not add_roof_details:
		return

	# 1-2 broken antennae on the roof — thin tall boxes leaning at random
	# angles. Reads as comm gear that survived the collapse.
	var antenna_count: int = randi_range(0, 2)
	for i: int in antenna_count:
		var ant := MeshInstance3D.new()
		var ant_box := BoxMesh.new()
		var ant_h: float = randf_range(0.6, 1.4)
		ant_box.size = Vector3(0.06, ant_h, 0.06)
		ant.mesh = ant_box
		ant.position = center_offset + Vector3(
			randf_range(-hx * 0.6, hx * 0.6),
			hy + ant_h * 0.5,
			randf_range(-hz * 0.6, hz * 0.6),
		)
		ant.rotation = Vector3(
			randf_range(-0.4, 0.4),
			0.0,
			randf_range(-0.4, 0.4),
		)
		var ant_mat := StandardMaterial3D.new()
		ant_mat.albedo_color = Color(0.12, 0.10, 0.09, 1.0)
		ant_mat.roughness = 0.65
		ant.set_surface_override_material(0, ant_mat)
		root.add_child(ant)

	# Half-collapsed corner — a smaller box knocked off one corner,
	# rotated so it reads as a fallen wall section. Position is just
	# outside the block's footprint so collision isn't expanded.
	if randf() < 0.6:
		var corner := MeshInstance3D.new()
		var c_box := BoxMesh.new()
		var c_size: Vector3 = Vector3(
			piece_size.x * randf_range(0.25, 0.45),
			piece_size.y * randf_range(0.4, 0.6),
			piece_size.z * randf_range(0.25, 0.45),
		)
		c_box.size = c_size
		corner.mesh = c_box
		var sign_x: float = 1.0 if randf() < 0.5 else -1.0
		var sign_z: float = 1.0 if randf() < 0.5 else -1.0
		corner.position = Vector3(
			sign_x * (hx + c_size.x * 0.3),
			c_size.y * 0.5,
			sign_z * (hz + c_size.z * 0.3),
		)
		corner.rotation = Vector3(
			randf_range(-0.6, 0.6),
			randf_range(0.0, TAU),
			randf_range(-0.6, 0.6),
		)
		var corner_mat := StandardMaterial3D.new()
		corner_mat.albedo_color = Color(0.30, 0.24, 0.20, 1.0).darkened(randf_range(0.0, 0.2))
		corner_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
		corner_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
		corner_mat.uv1_scale = Vector3(1.6, 1.6, 1.0)
		corner_mat.roughness = 0.95
		corner.set_surface_override_material(0, corner_mat)
		root.add_child(corner)


func _spawn_rock_outcrop(center: Vector3, base_size: float) -> void:
	# Multi-faceted rock formation. One large central chunk plus 4-6
	# smaller chunks fused at random angles — produces a more organic,
	# multi-corner silhouette than a single box.
	_spawn_terrain_piece(center, Vector3(base_size, base_size * 0.7, base_size * 0.9), "rock")
	# Surround with smaller satellite rocks at random angles + heights.
	var sat_count: int = randi_range(4, 6)
	for i: int in sat_count:
		var ang: float = float(i) / float(sat_count) * TAU + randf_range(-0.4, 0.4)
		var radius: float = base_size * randf_range(0.55, 0.95)
		var sx: float = base_size * randf_range(0.32, 0.6)
		var sy: float = base_size * randf_range(0.4, 0.85)
		var sz: float = base_size * randf_range(0.32, 0.6)
		_spawn_terrain_piece(
			center + Vector3(cos(ang) * radius, 0.0, sin(ang) * radius),
			Vector3(sx, sy, sz),
			"rock",
		)


func _spawn_ruin_complex(center: Vector3, complex_size: Vector2, rot_y: float) -> void:
	# Asymmetric ruined-building complex. Multiple square ruin blocks
	# arranged in a row + offset perpendicular blocks, all rotated as
	# a unit so the whole complex aligns to the requested angle. Reads
	# as a collapsed industrial wing / block of buildings.
	#
	# Each block is its own _spawn_terrain_piece — separate StaticBody3D
	# colliders so units can thread between blocks where there's a gap,
	# but the overall silhouette is one big asymmetric structure.
	var hx: float = complex_size.x * 0.5
	var hz: float = complex_size.y * 0.5
	var fwd: Vector3 = Vector3(cos(rot_y), 0.0, sin(rot_y))
	var right: Vector3 = Vector3(-fwd.z, 0.0, fwd.x)

	# Main row — 3 large blocks along the long axis.
	var block_w: float = complex_size.x / 3.0
	for i: int in 3:
		var t: float = float(i) - 1.0  # -1, 0, +1
		var pos: Vector3 = center + fwd * (t * block_w * 0.95)
		# Slight per-block size jitter so the row isn't perfectly uniform.
		var sx: float = block_w * randf_range(0.85, 1.0)
		var sz: float = complex_size.y * randf_range(0.65, 0.9)
		var sy: float = randf_range(2.6, 4.5)  # variable heights — collapsed look
		# Rotate the size by the complex's rotation so the block aligns.
		var rotated_size: Vector3 = _rotated_box_size(sx, sy, sz, rot_y)
		_spawn_terrain_piece(pos, rotated_size, "ruin")

	# Two perpendicular wings sticking out from the main row, offset
	# asymmetrically so the complex doesn't read as a perfectly
	# symmetric shape.
	var wing_offset_main: float = block_w * randf_range(0.3, 0.8)
	var wing_pos_a: Vector3 = center + fwd * wing_offset_main + right * (hz + 1.5)
	var wing_size_a: Vector3 = _rotated_box_size(
		block_w * 0.85, randf_range(2.4, 3.6), complex_size.y * 0.5, rot_y
	)
	_spawn_terrain_piece(wing_pos_a, wing_size_a, "ruin")

	var wing_offset_other: float = -block_w * randf_range(0.4, 0.9)
	var wing_pos_b: Vector3 = center + fwd * wing_offset_other - right * (hz + 1.2)
	var wing_size_b: Vector3 = _rotated_box_size(
		block_w * 0.7, randf_range(2.0, 3.2), complex_size.y * 0.4, rot_y
	)
	_spawn_terrain_piece(wing_pos_b, wing_size_b, "ruin")


func _rotated_box_size(sx: float, sy: float, sz: float, rot_y: float) -> Vector3:
	# Rotated AABB approximation — a box of (sx, sy, sz) rotated by
	# `rot_y` projects to an AABB of (sx*|cos| + sz*|sin|, sy,
	# sx*|sin| + sz*|cos|). For collision/visual we use the projection
	# so the spawn-piece BoxMesh covers the rotated footprint cleanly.
	var c: float = absf(cos(rot_y))
	var s: float = absf(sin(rot_y))
	return Vector3(sx * c + sz * s, sy, sx * s + sz * c)


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
	# Use the diagonal half-extent for the piece's 2D AABB so any
	# rotation of the piece stays inside the carved footprint.
	var diag_half: float = sqrt(piece_size.x * piece_size.x + piece_size.z * piece_size.z) * 0.5
	var p_min: Vector2 = Vector2(pos.x - diag_half, pos.z - diag_half)
	var p_max: Vector2 = Vector2(pos.x + diag_half, pos.z + diag_half)

	# Skip placement that overlaps any ramp's approach clearance — the
	# ramp footprint plus a 4u outward margin. This guarantees ramps
	# stay reachable regardless of which terrain layout the map uses
	# and how dense the surrounding obstacles are.
	for clearance: Rect2 in _pending_ramp_clearance:
		if p_max.x < clearance.position.x:
			continue
		if p_min.x > clearance.position.x + clearance.size.x:
			continue
		if p_max.y < clearance.position.y:
			continue
		if p_min.y > clearance.position.y + clearance.size.y:
			continue
		return  # overlap → silently drop the piece

	# Also skip placement overlapping any queued plateau footprint --
	# placing a ground-level deco piece inside a plateau footprint
	# leaves it visually half-submerged in the raised platform geometry.
	if _overlaps_plateau_footprint(pos, piece_size, 0.0):
		return

	# Queue the piece's 2D footprint as a blocked region so the ground
	# strip-decomposition navmesh carves a hole at this position. Without
	# this, units' nav agents path THROUGH terrain (the navmesh covers
	# the area as walkable) and only RVO avoidance steers them — which
	# fails inside dense terrain like ruin complexes, leaving units
	# wedged against walls.
	#
	# The footprint is inflated by NAV_INFLATION beyond the visual extent.
	# This is the navmesh-only buffer — collision and the RVO obstacle
	# still match the visual size. Without inflation, a ruin complex's
	# tightly-packed blocks leave 0.5-1.5u walkable slivers between them
	# in the navmesh; the path planner happily routes heavy units through
	# those slivers, but the units' avoidance radius (~2.5u for heavies)
	# can't fit and they wedge against the geometry — the "invisible wall
	# only small units can pass" symptom. Inflation closes those slivers
	# so the planner only emits paths through gaps that are actually
	# wide enough for the largest unit to traverse.
	const NAV_INFLATION: float = 1.5
	var inf_min: Vector2 = p_min - Vector2(NAV_INFLATION, NAV_INFLATION)
	var inf_max: Vector2 = p_max + Vector2(NAV_INFLATION, NAV_INFLATION)
	_pending_blocked_footprints.append(PackedVector2Array([
		inf_min,
		Vector2(inf_max.x, inf_min.y),
		inf_max,
		Vector2(inf_min.x, inf_max.y),
	]))

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
	# For scrap piles, the dominant visual is the scattered chunk
	# layer added below — the underlying base box was reading as a
	# big flat rust slab on the ground. Shrink it to a thin "rust
	# stain" footprint just barely above the floor; the chunks above
	# carry the silhouette. Collision keeps the original size so
	# units still treat the pile as a physical obstacle.
	if kind == "scrap_pile":
		box_mesh.size = Vector3(piece_size.x * 0.95, 0.20, piece_size.z * 0.95)
		mesh_inst.position.y = -piece_size.y * 0.5 + 0.10
	else:
		box_mesh.size = piece_size
	mesh_inst.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color
	# Ruins use the panel-wall texture (horizontal/vertical joint lines)
	# so they read as masonry, clearly distinct from the organic noise of
	# rock surfaces. uv scale is tied to world size so the panel pitch
	# stays roughly constant across blocks of different sizes.
	if kind == "ruin":
		mat.albedo_texture = SharedTextures.get_wall_panel_texture()
		mat.uv1_offset = Vector3(randf(), randf(), 0.0)
		# ~1 panel per ~1.2u of wall height. Texture has 4 horizontal
		# panels per cycle, so scale.y = piece_size.y / 4.8 gives ~1u
		# per panel.
		mat.uv1_scale = Vector3(maxf(piece_size.x / 4.8, 0.6), maxf(piece_size.y / 4.8, 0.6), 1.0)
	else:
		# Rocks / scrap: organic-noise wear texture, wider scale so the
		# pattern reads as weathered stone rather than fabricated panels.
		mat.albedo_texture = SharedTextures.get_metal_wear_texture()
		mat.uv1_offset = Vector3(randf(), randf(), 0.0)
		mat.uv1_scale = Vector3(2.2, 2.2, 1.0)
	mat.roughness = randf_range(0.85, 0.98)
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

	# Scrap piles read as "field of broken metal" — many small chunks
	# scattered across the footprint, no single dominant block. Rocks /
	# ruins keep the existing one-debris-chunk shape so the silhouette
	# stays grouped.
	if kind == "scrap_pile":
		# Scattered chunks sit on the buried-flat base (root is at
		# y = piece_size.y * 0.5, base mesh is buried so the chunks
		# are now the dominant silhouette). Anchor each chunk so its
		# bottom rests near ground level — calculated relative to
		# root rather than the original tall base.
		var chunk_count: int = randi_range(7, 11)
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
			# Place each chunk so its bottom face sits at ground level
			# (root y - piece_size.y * 0.5 = 0).
			var chunk_y: float = -piece_size.y * 0.5 + chunk_box.size.y * 0.5
			chunk.position = Vector3(
				randf_range(-piece_size.x * 0.4, piece_size.x * 0.4),
				chunk_y,
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
			chunk_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
			chunk_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
			chunk_mat.uv1_scale = Vector3(2.0, 2.0, 1.0)
			chunk_mat.roughness = mat.roughness
			chunk.material_override = chunk_mat
			root.add_child(chunk)
	elif kind == "ruin":
		# Upper-story building block — clean axis-aligned smaller block
		# resting on top of the base. Reads as a second floor of the same
		# structure, not as collapsed debris. Same wall texture as the
		# base so the building reads coherently. Gets its own grid of
		# windows. Only added when the base is tall enough to support a
		# distinct upper level — short ruins stay single-block.
		var upper_offset: Vector3 = Vector3.ZERO
		var upper_size: Vector3 = Vector3.ZERO
		var has_upper: bool = piece_size.y >= 2.6
		if has_upper:
			var upper := MeshInstance3D.new()
			var upper_box := BoxMesh.new()
			var u_w: float = piece_size.x * randf_range(0.55, 0.75)
			var u_d: float = piece_size.z * randf_range(0.55, 0.75)
			var u_h: float = randf_range(1.4, 2.4)
			upper_size = Vector3(u_w, u_h, u_d)
			upper_box.size = upper_size
			upper.mesh = upper_box
			upper_offset = Vector3(
				randf_range(-piece_size.x * 0.12, piece_size.x * 0.12),
				piece_size.y * 0.5 + u_h * 0.5,
				randf_range(-piece_size.z * 0.12, piece_size.z * 0.12),
			)
			upper.position = upper_offset
			# Subtle Y-only rotation — keeps the upper story upright so it
			# reads as an inhabited level rather than tumbled debris.
			upper.rotation.y = randf_range(-0.15, 0.15)
			var upper_mat := StandardMaterial3D.new()
			upper_mat.albedo_color = base_color.darkened(randf_range(0.05, 0.15))
			upper_mat.albedo_texture = SharedTextures.get_wall_panel_texture()
			upper_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
			upper_mat.uv1_scale = Vector3(maxf(u_w / 4.8, 0.6), maxf(u_h / 4.8, 0.6), 1.0)
			upper_mat.roughness = mat.roughness
			upper.material_override = upper_mat
			root.add_child(upper)
		# Decorate the base block with windows only — no antennae /
		# corner-collapse, those go on the topmost block. If there's no
		# upper-story (short ruin), the base IS the topmost and gets the
		# full treatment.
		_decorate_ruin_block(root, piece_size, Vector3.ZERO, not has_upper)
		if has_upper:
			_decorate_ruin_block(root, upper_size, upper_offset, true)
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
		chunk_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
		chunk_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
		chunk_mat.uv1_scale = Vector3(2.0, 2.0, 1.0)
		chunk_mat.roughness = mat.roughness
		chunk.material_override = chunk_mat
		root.add_child(chunk)

	# RVO obstacle so units steer around instead of grinding into the side.
	# Radius covers the FULL diagonal half-extent (sqrt(x²+z²)/2) plus a
	# 1.2u margin — the previous max(x,z)/2 left the corners uncovered, so
	# units routing diagonally past a long rectangle would catch on the
	# corner and the stuck-rescue ladder would have to dig them out.
	# Reuse `diag_half` computed at the top of the function for the
	# blocked-footprint queue.
	var obstacle := NavigationObstacle3D.new()
	obstacle.radius = diag_half + 1.2
	obstacle.height = piece_size.y
	obstacle.avoidance_enabled = true
	root.add_child(obstacle)


func _setup_elevation() -> void:
	if _is_ashplains():
		_setup_elevation_ashplains()
		return
	_setup_elevation_foundry_belt()


func _setup_elevation_foundry_belt() -> void:
	# Bigger plateaus, wider ramps. Ramps cover the full width of the
	# side they sit on — the top edge of the ramp is the same edge as
	# the plateau's top, so they read as one continuous walkable surface
	# rather than a separate piece sticking out. The plateau is also
	# octagonal (corners cut) so the silhouette feels less rectilinear.
	# Heights bumped 1.5 -> 2.6 so the plateaus visibly tower over
	# ground units (mech height ~2u). Without the visible step the
	# "ground units can't see uphill" FOW rule would read as a bug
	# rather than terrain consequence.
	var plateaus: Array[Dictionary] = [
		# Central plateau — the contested high ground. Larger footprint
		# so a Bulwark squad can comfortably perch on it. Ramps N + S.
		{"center": Vector3(0.0, 0.0, 25.0), "top": Vector2(28.0, 18.0),
		 "height": 2.6, "ramps": ["N", "S"]},
		# Southern (AI-side) plateau.
		{"center": Vector3(0.0, 0.0, -75.0), "top": Vector2(24.0, 14.0),
		 "height": 2.6, "ramps": ["S"]},
		# East ridge — wider+longer, ramp on east side toward back-door.
		{"center": Vector3(72.0, 0.0, 0.0), "top": Vector2(12.0, 22.0),
		 "height": 2.6, "ramps": ["E"]},
		# West ridge mirror.
		{"center": Vector3(-72.0, 0.0, 0.0), "top": Vector2(12.0, 22.0),
		 "height": 2.6, "ramps": ["W"]},
	]
	for p: Dictionary in plateaus:
		_spawn_walkable_plateau(
			p["center"] as Vector3,
			p["top"] as Vector2,
			p["height"] as float,
			p["ramps"] as Array,
		)


func _setup_elevation_ashplains() -> void:
	# Main ridge dominates the central plain — much wider than before so
	# multiple squads can comfortably hold it. Three ramps (N + S + E)
	# spread access points across both teams' approach lanes.
	# Heights bumped (1.4/2.0 -> 2.4/3.0) so plateaus visibly tower
	# over ground units, making the FOW LOS gate believable.
	var plateaus: Array[Dictionary] = [
		{"center": Vector3(0.0, 0.0, -8.0), "top": Vector2(90.0, 14.0),
		 "height": 3.0, "ramps": ["N", "S", "E"]},
		{"center": Vector3(0.0, 0.0, 38.0), "top": Vector2(28.0, 10.0),
		 "height": 2.4, "ramps": ["N"]},
	]
	for p: Dictionary in plateaus:
		_spawn_walkable_plateau(
			p["center"] as Vector3,
			p["top"] as Vector2,
			p["height"] as float,
			p["ramps"] as Array,
		)


func _spawn_walkable_plateau(center: Vector3, top_size: Vector2, height: float, ramp_sides: Array) -> void:
	# Plateau body + ramp wedges. Ramps are EMBEDDED — their top edge
	# spans the full width of the plateau side they're on, sharing the
	# plateau's top corner positions. Visually the ramp reads as a
	# natural extension of the plateau's surface, not a separate piece
	# stuck on. Plateau silhouette is octagonal (corners cut) so it
	# doesn't read as a perfect rectangle.
	var hx: float = top_size.x * 0.5
	var hz: float = top_size.y * 0.5

	# Queue the plateau-body footprint as a blocked region so the
	# ground triangulation cuts a hole here. Ramp footprints are queued
	# inside `_spawn_plateau_ramp` after the per-side coords are known.
	_pending_blocked_footprints.append(PackedVector2Array([
		Vector2(center.x - hx, center.z - hz),
		Vector2(center.x + hx, center.z - hz),
		Vector2(center.x + hx, center.z + hz),
		Vector2(center.x - hx, center.z + hz),
	]))
	# Tell the FOW which cells sit on the plateau top so ground
	# observers' vision can't reveal them. Ground LOS gates on
	# plateau elevation; aircraft + plateau-top observers bypass.
	var fow: Node = get_node_or_null("FogOfWar")
	if fow and fow.has_method("register_plateau_footprint"):
		fow.call("register_plateau_footprint", center, top_size)

	var root := StaticBody3D.new()
	root.collision_layer = 4
	root.collision_mask = 0
	root.position = center
	# "elevation" — used by other systems to identify plateaus.
	# "terrain" — required so the navmesh bake walks this collision
	# shape and recognises the plateau top + ramps as walkable surfaces.
	# Without this the plateaus were entirely missing from the bake
	# and units couldn't path on/off them.
	root.add_to_group("elevation")
	root.add_to_group("terrain")
	# Plateaus + ramps are permanent landmarks. Once explored they
	# stay at full brightness even when not in current vision -- the
	# FOW dim overlay composited with the side-wall material was
	# producing near-solid-black plateau cliffs.
	root.set_meta("_fow_skip_dim", true)
	add_child(root)

	# Two materials — same wear texture, two albedo shades. The top
	# face uses the lighter tone (so it stands out against the ground);
	# the sides and ramps use a noticeably darker variant so the
	# vertical surfaces read as "rock face in shadow" against the lit
	# top. Same texture on both keeps the surface character coherent.
	#
	# CULL_DISABLED — render both sides of every face so winding
	# orientation never causes invisibility. Plateau geometry is small
	# (≈64 triangles per plateau) so the 2× draw cost is trivial.
	var mat_top := StandardMaterial3D.new()
	mat_top.albedo_color = Color(0.32, 0.28, 0.22, 1.0)
	mat_top.albedo_texture = SharedTextures.get_metal_wear_texture()
	mat_top.uv1_scale = Vector3(3.5, 3.5, 1.0)
	mat_top.roughness = 0.95
	mat_top.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Side / ramp tint pulled out of near-black -- the previous
	# 0.09/0.08/0.07 read as flat black under most lighting and the
	# user couldn't tell ramp from cliff face. Around 0.20 keeps the
	# walls clearly darker than the top while staying lit.
	var mat_side := StandardMaterial3D.new()
	mat_side.albedo_color = Color(0.22, 0.19, 0.16, 1.0)
	mat_side.albedo_texture = SharedTextures.get_metal_wear_texture()
	mat_side.uv1_scale = Vector3(2.4, 2.4, 1.0)
	mat_side.roughness = 0.95
	mat_side.cull_mode = BaseMaterial3D.CULL_DISABLED

	# --- Plateau body collision (single Box for the whole prism) ---
	var box_col := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(top_size.x, height, top_size.y)
	box_col.shape = box_shape
	box_col.position.y = height * 0.5
	root.add_child(box_col)

	# --- Plateau body visual: octagonal prism (cut corners) ---
	# The 8 top corners trace an octagon by chamfering the rectangle's
	# 4 corners by `corner_cut`. This breaks the perfectly-rectilinear
	# silhouette without changing the collision footprint (collision
	# stays the simpler Box, which is fine — the chamfer is small).
	# Bumped from 0.18 to 0.30 so the chamfer is bigger and the
	# silhouette reads less like a rectangular box.
	var corner_cut: float = minf(top_size.x, top_size.y) * 0.30
	var oct_top: PackedVector3Array = _octagon_corners(top_size, corner_cut, height)
	var oct_bot: PackedVector3Array = _octagon_corners(top_size, corner_cut, 0.0)

	var body_mesh := _build_octagonal_prism_mesh(oct_top, oct_bot, mat_top, mat_side)
	root.add_child(body_mesh)

	# Rocky scree against the side walls -- 8-12 small irregular blocks
	# leaning against / projecting out of the cliff face. Breaks up the
	# straight wall silhouette so the plateau reads as a weathered
	# outcrop instead of a poured-concrete platform. Same darker side
	# material so the scree blends rather than spotlights itself.
	_decorate_plateau_scree(root, top_size, height, corner_cut, mat_side)

	# --- Ramps ---
	# Ramp width — generous enough that the bake's 1.5u agent_radius
	# carve doesn't pinch the walkable strip down to almost nothing.
	# At 10u, the slope's walkable navmesh is 10 - 2*1.5 = 7u wide,
	# which gives diagonal approaches enough room to enter the ramp
	# without grinding the side wall.
	const RAMP_WIDTH: float = 10.0
	# Ramp run scales with plateau height — gentler slope on taller
	# plateaus so collision climbing stays well under floor_max_angle
	# (45°). At height 1.5 / run 6.5 the slope is ~13°; at height
	# 2.0 / run 9.0 it's ~12.5°.
	var run: float = maxf(height * 4.5, 6.5)

	# --- Top nav polygons (CCW perimeter w/ ramp inserts → fan from center) ---
	# The plateau-top perimeter walks the octagon corners CCW. For each
	# side that has a ramp, we insert the ramp's two top-edge vertices
	# inline so the fan triangle covering that segment shares an edge
	# with the ramp's top — meaning the path planner sees them as one
	# connected region instead of two disjoint islands.
	var top_perimeter: PackedVector3Array = _plateau_top_perimeter_with_ramps(
		top_size, corner_cut, height, ramp_sides, RAMP_WIDTH
	)
	var top_y: float = center.y + height
	var top_center: Vector3 = Vector3(center.x, top_y, center.z)
	# Plateau-top fan triangles. Winding is (top_center, b, a) — i.e.
	# the perimeter walk is REVERSED — so the fan tri's edge between
	# consecutive perimeter points goes (b → a). The ramp slope tri
	# emits its top edge as (tA → tB) with the opposite direction, so
	# the two share an edge with reversed indices and Godot's nav-mesh
	# edge merger correctly identifies them as adjacent. The previous
	# winding (top_center, a, b) put the fan tris and slope tris in
	# the SAME direction, which produced the "more than 2 edges
	# occupy same space" warnings and broke ramp connectivity.
	for i: int in top_perimeter.size():
		var a: Vector3 = top_perimeter[i] + Vector3(center.x, 0.0, center.z)
		var b: Vector3 = top_perimeter[(i + 1) % top_perimeter.size()] + Vector3(center.x, 0.0, center.z)
		_pending_nav_polys.append(PackedVector3Array([top_center, b, a]))

	for side_var: Variant in ramp_sides:
		var side: String = side_var as String
		_spawn_plateau_ramp(center, top_size, height, side, run, RAMP_WIDTH, mat_side)

	# No NavigationObstacle3D on plateaus — earlier we attached one
	# sized to the diagonal half-extent (~17u for the central plateau)
	# and the resulting RVO push field intercepted units approaching
	# the ramp from far away, knocking them off the climb lane. The
	# Box collision already physically blocks units at ground level,
	# and the unit stuck-rescue ladder handles the rare case where a
	# pathfinding query routes through the plateau wall.


func _plateau_top_perimeter_with_ramps(top_size: Vector2, cut: float, height: float, ramp_sides: Array, ramp_width: float) -> PackedVector3Array:
	## Walks the octagonal perimeter CCW. For each side that has a ramp,
	## inserts the ramp's two top-edge endpoints inline so the fan
	## triangle covering that segment shares an exact edge with the
	## ramp's top — the path planner then sees them as one connected
	## navigation surface. Without these insertions the plateau top fan
	## and the ramp slope polys are separate islands and units stop at
	## the seam.
	var hx: float = top_size.x * 0.5
	var hz: float = top_size.y * 0.5
	var hw: float = ramp_width * 0.5
	var has_n: bool = ramp_sides.has("N")
	var has_s: bool = ramp_sides.has("S")
	var has_e: bool = ramp_sides.has("E")
	var has_w: bool = ramp_sides.has("W")
	var verts := PackedVector3Array()
	# Octagon walk CCW starting at SE chamfer top. Each octagon edge is
	# chased; ramps embed in the four cardinal-side edges.
	# 0: SE chamfer top
	verts.append(Vector3(+hx, height, -hz + cut))
	# 1: SE chamfer side (start of S edge)
	verts.append(Vector3(+hx - cut, height, -hz))
	if has_s:
		verts.append(Vector3(+hw, height, -hz))
		verts.append(Vector3(-hw, height, -hz))
	# 2: SW chamfer side (end of S edge)
	verts.append(Vector3(-hx + cut, height, -hz))
	# 3: SW chamfer top (start of W edge)
	verts.append(Vector3(-hx, height, -hz + cut))
	if has_w:
		verts.append(Vector3(-hx, height, -hw))
		verts.append(Vector3(-hx, height, +hw))
	# 4: NW chamfer bottom (end of W edge)
	verts.append(Vector3(-hx, height, +hz - cut))
	# 5: NW chamfer side (start of N edge)
	verts.append(Vector3(-hx + cut, height, +hz))
	if has_n:
		verts.append(Vector3(-hw, height, +hz))
		verts.append(Vector3(+hw, height, +hz))
	# 6: NE chamfer side (end of N edge)
	verts.append(Vector3(+hx - cut, height, +hz))
	# 7: NE chamfer bottom (start of E edge)
	verts.append(Vector3(+hx, height, +hz - cut))
	if has_e:
		verts.append(Vector3(+hx, height, +hw))
		verts.append(Vector3(+hx, height, -hw))
	# Wraps back to vertex 0 implicitly.
	return verts


func _decorate_plateau_scree(root: Node3D, top_size: Vector2, height: float, cut: float, share_mat: StandardMaterial3D) -> void:
	## Drops 8-14 small irregular blocks against the plateau side
	## walls -- weathered scree / fallen hull plates leaning against
	## the cliff. Helps the silhouette read as a natural outcrop
	## instead of a poured-concrete prism. Blocks leak slightly past
	## the wall plane so the silhouette shows them, and they don't
	## affect collision (the underlying Box collider is unchanged).
	var hx: float = top_size.x * 0.5
	var hz: float = top_size.y * 0.5
	const SCREE_COUNT: int = 11
	for i: int in SCREE_COUNT:
		# Pick a random side (0=+X, 1=-X, 2=+Z, 3=-Z) so coverage is
		# spread roughly evenly around the plateau.
		var side: int = i % 4
		var t: float = randf_range(0.10, 0.90)
		var pos: Vector3
		var rot_y: float
		match side:
			0:  # +X face
				var z_extent: float = hz - cut
				pos = Vector3(hx + randf_range(0.10, 0.55), 0.0, lerp(-z_extent, z_extent, t))
				rot_y = 0.0
			1:  # -X face
				var z_extent2: float = hz - cut
				pos = Vector3(-hx - randf_range(0.10, 0.55), 0.0, lerp(-z_extent2, z_extent2, t))
				rot_y = PI
			2:  # +Z face
				var x_extent: float = hx - cut
				pos = Vector3(lerp(-x_extent, x_extent, t), 0.0, hz + randf_range(0.10, 0.55))
				rot_y = PI * 0.5
			_:  # -Z face
				var x_extent2: float = hx - cut
				pos = Vector3(lerp(-x_extent2, x_extent2, t), 0.0, -hz - randf_range(0.10, 0.55))
				rot_y = -PI * 0.5
		var block := MeshInstance3D.new()
		var box := BoxMesh.new()
		var sx: float = randf_range(0.45, 1.20)
		var sy: float = randf_range(height * 0.30, height * 0.85)
		var sz: float = randf_range(0.45, 1.10)
		box.size = Vector3(sx, sy, sz)
		block.mesh = box
		pos.y = sy * 0.5 + randf_range(-0.05, 0.10)
		block.position = pos
		block.rotation = Vector3(
			randf_range(-0.20, 0.20),
			rot_y + randf_range(-0.45, 0.45),
			randf_range(-0.30, 0.30),
		)
		block.set_surface_override_material(0, share_mat)
		root.add_child(block)


func _octagon_corners(size: Vector2, cut: float, y: float) -> PackedVector3Array:
	## Returns 8 vertices forming an octagon (rectangle with chamfered
	## corners), going CCW starting from the +x / -z chamfer. Local
	## coordinates centered on the origin.
	var hx: float = size.x * 0.5
	var hz: float = size.y * 0.5
	return PackedVector3Array([
		Vector3(+hx, y, -hz + cut),
		Vector3(+hx - cut, y, -hz),
		Vector3(-hx + cut, y, -hz),
		Vector3(-hx, y, -hz + cut),
		Vector3(-hx, y, +hz - cut),
		Vector3(-hx + cut, y, +hz),
		Vector3(+hx - cut, y, +hz),
		Vector3(+hx, y, +hz - cut),
	])


func _build_octagonal_prism_mesh(oct_top: PackedVector3Array, oct_bot: PackedVector3Array, mat_top: StandardMaterial3D, mat_side: StandardMaterial3D) -> MeshInstance3D:
	## Builds an 8-sided prism mesh from an octagon top + bottom. Two
	## surfaces — top face uses `mat_top`, the 8 wall quads use
	## `mat_side`. Splitting them lets the top read as the "lit upper
	## face" and the walls as a darker, shadowed-rock variant.
	var top_verts := PackedVector3Array()
	var top_norms := PackedVector3Array()
	var top_uvs := PackedVector2Array()
	var side_verts := PackedVector3Array()
	var side_norms := PackedVector3Array()
	var side_uvs := PackedVector2Array()

	# Top face — fan from local origin outward. The octagon vertex list
	# walks the perimeter CW (looking from above), so we emit triangles
	# as (center, c, b) instead of (center, b, c) to flip the winding
	# back to CCW with normal pointing UP.
	var top_y: float = oct_top[0].y
	var top_center := Vector3(0, top_y, 0)
	for i: int in oct_top.size():
		var a: Vector3 = top_center
		var b: Vector3 = oct_top[i]
		var c: Vector3 = oct_top[(i + 1) % oct_top.size()]
		var n: Vector3 = Vector3(0, 1, 0)
		for v: Vector3 in [a, c, b]:
			top_verts.append(v)
			top_norms.append(n)
		var w: int = oct_top.size()
		var ang_b: float = TAU * float(i) / float(w)
		var ang_c: float = TAU * float(i + 1) / float(w)
		top_uvs.append(Vector2(0.5, 0.5))
		top_uvs.append(Vector2(0.5 + cos(ang_c) * 0.5, 0.5 + sin(ang_c) * 0.5))
		top_uvs.append(Vector2(0.5 + cos(ang_b) * 0.5, 0.5 + sin(ang_b) * 0.5))

	# Wall quads — winding reversed so normals point outward.
	for i: int in oct_top.size():
		var t_a: Vector3 = oct_top[i]
		var t_b: Vector3 = oct_top[(i + 1) % oct_top.size()]
		var b_a: Vector3 = oct_bot[i]
		var b_b: Vector3 = oct_bot[(i + 1) % oct_bot.size()]
		var seg_len: float = (t_a - t_b).length()
		var height: float = t_a.y - b_a.y
		var uv_aspect: Vector2 = Vector2(seg_len * 0.4, height * 0.4)
		# Two triangles per wall: (b_a, b_b, t_b) and (b_a, t_b, t_a).
		var n: Vector3 = (b_b - b_a).cross(t_b - b_a).normalized()
		for v: Vector3 in [b_a, b_b, t_b, b_a, t_b, t_a]:
			side_verts.append(v)
			side_norms.append(n)
		side_uvs.append(Vector2(0, 0))
		side_uvs.append(Vector2(uv_aspect.x, 0))
		side_uvs.append(Vector2(uv_aspect.x, uv_aspect.y))
		side_uvs.append(Vector2(0, 0))
		side_uvs.append(Vector2(uv_aspect.x, uv_aspect.y))
		side_uvs.append(Vector2(0, uv_aspect.y))

	var arr_mesh := ArrayMesh.new()
	# Surface 0 = top
	var top_arrays := []
	top_arrays.resize(Mesh.ARRAY_MAX)
	top_arrays[Mesh.ARRAY_VERTEX] = top_verts
	top_arrays[Mesh.ARRAY_NORMAL] = top_norms
	top_arrays[Mesh.ARRAY_TEX_UV] = top_uvs
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, top_arrays)
	# Surface 1 = sides
	var side_arrays := []
	side_arrays.resize(Mesh.ARRAY_MAX)
	side_arrays[Mesh.ARRAY_VERTEX] = side_verts
	side_arrays[Mesh.ARRAY_NORMAL] = side_norms
	side_arrays[Mesh.ARRAY_TEX_UV] = side_uvs
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, side_arrays)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	mesh_inst.set_surface_override_material(0, mat_top)
	mesh_inst.set_surface_override_material(1, mat_side)
	return mesh_inst


func _spawn_plateau_ramp(plateau_center: Vector3, top_size: Vector2, height: float, side: String, run: float, width: float, share_mat: StandardMaterial3D) -> void:
	# Wedge ramp embedded into the plateau side. Ramp's top edge spans
	# the full width of the plateau side (sharing top-corner positions
	# with the plateau body), so the ramp surface reads as one continuous
	# walkable surface with the plateau top.
	var hx: float = top_size.x * 0.5
	var hz: float = top_size.y * 0.5

	# Ramp top edge sits flush against the plateau wall and is centered
	# along the side at a fixed `width`. The plateau wall continues to
	# either side of the ramp — units can only climb up via the central
	# slot, not anywhere along the edge.
	var hw: float = width * 0.5
	var tA: Vector3
	var tB: Vector3
	var bA: Vector3
	var bB: Vector3
	match side:
		"N":  # ramp on +z side, centered on x
			tA = Vector3(-hw, height, hz)
			tB = Vector3(+hw, height, hz)
			bA = Vector3(-hw, 0.0, hz + run)
			bB = Vector3(+hw, 0.0, hz + run)
		"S":  # ramp on -z side, centered on x
			tA = Vector3(+hw, height, -hz)
			tB = Vector3(-hw, height, -hz)
			bA = Vector3(+hw, 0.0, -hz - run)
			bB = Vector3(-hw, 0.0, -hz - run)
		"E":  # ramp on +x side, centered on z
			tA = Vector3(hx, height, +hw)
			tB = Vector3(hx, height, -hw)
			bA = Vector3(hx + run, 0.0, +hw)
			bB = Vector3(hx + run, 0.0, -hw)
		_:    # "W" — ramp on -x side, centered on z
			tA = Vector3(-hx, height, -hw)
			tB = Vector3(-hx, height, +hw)
			bA = Vector3(-hx - run, 0.0, -hw)
			bB = Vector3(-hx - run, 0.0, +hw)
	var uA: Vector3 = Vector3(tA.x, 0.0, tA.z)
	var uB: Vector3 = Vector3(tB.x, 0.0, tB.z)

	# Queue the ramp footprint as a blocked region so the ground
	# triangulation cuts a hole at exactly the ramp's foot. The ramp's
	# bottom-edge endpoints (bA, bB) become ground polygon vertices, so
	# the resulting ground triangles share an edge with the ramp's
	# bottom — ramp ↔ ground are connected for path planning.
	# Footprint vertices are CCW in world space and slightly inset on
	# the plateau-side edge so the polygon doesn't intersect the
	# plateau body footprint (which would break clip_polygons).
	var w_uA: Vector2 = Vector2(plateau_center.x + uA.x, plateau_center.z + uA.z)
	var w_uB: Vector2 = Vector2(plateau_center.x + uB.x, plateau_center.z + uB.z)
	var w_bA: Vector2 = Vector2(plateau_center.x + bA.x, plateau_center.z + bA.z)
	var w_bB: Vector2 = Vector2(plateau_center.x + bB.x, plateau_center.z + bB.z)
	# Order so the polygon winds CCW. tA→tB matches one direction along
	# the plateau side; bA→bB extends outward. The CCW ordering depends
	# on which side the ramp is on — easiest is to use a known-good fan.
	_pending_blocked_footprints.append(PackedVector2Array([w_uA, w_bA, w_bB, w_uB]))

	# Mark ramp-bottom endpoints as ground vertices so the
	# triangulation puts a polygon edge there even if the clip
	# operation is clipped slightly differently.
	_pending_ground_vertex_marks.append(w_bA)
	_pending_ground_vertex_marks.append(w_bB)

	# Approach-clearance rect — the ramp footprint plus an extra
	# OUTWARD margin so terrain spawn keeps the ramp's bottom
	# approach lane free. Without this, a rock or ruin block can
	# sit right where the ramp meets the ground and the ramp
	# becomes effectively unreachable.
	const RAMP_APPROACH_MARGIN: float = 4.0
	var ramp_min_x: float = minf(w_uA.x, minf(w_bA.x, minf(w_bB.x, w_uB.x))) - RAMP_APPROACH_MARGIN
	var ramp_max_x: float = maxf(w_uA.x, maxf(w_bA.x, maxf(w_bB.x, w_uB.x))) + RAMP_APPROACH_MARGIN
	var ramp_min_z: float = minf(w_uA.y, minf(w_bA.y, minf(w_bB.y, w_uB.y))) - RAMP_APPROACH_MARGIN
	var ramp_max_z: float = maxf(w_uA.y, maxf(w_bA.y, maxf(w_bB.y, w_uB.y))) + RAMP_APPROACH_MARGIN
	_pending_ramp_clearance.append(Rect2(
		Vector2(ramp_min_x, ramp_min_z),
		Vector2(ramp_max_x - ramp_min_x, ramp_max_z - ramp_min_z),
	))

	var root := StaticBody3D.new()
	root.collision_layer = 4
	root.collision_mask = 0
	root.position = plateau_center
	# Both groups — see plateau body comment. The bake needs the
	# convex-hull ramp to be in "terrain" so the slope poly becomes
	# walkable navmesh.
	root.add_to_group("elevation")
	root.add_to_group("terrain")
	# Plateaus + ramps are permanent landmarks. Once explored they
	# stay at full brightness even when not in current vision -- the
	# FOW dim overlay composited with the side-wall material was
	# producing near-solid-black plateau cliffs.
	root.set_meta("_fow_skip_dim", true)
	add_child(root)

	# Mesh — sloped top + two side triangles + underside. UVs on every
	# face so the wear texture renders correctly (without UVs the
	# sampler returned (0,0) which produced flat black slabs).
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()

	var push_tri := func(a: Vector3, b: Vector3, c: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> void:
		var n: Vector3 = (b - a).cross(c - a).normalized()
		verts.append(a); norms.append(n); uvs.append(uv_a)
		verts.append(b); norms.append(n); uvs.append(uv_b)
		verts.append(c); norms.append(n); uvs.append(uv_c)

	# Sloped top — UV: spans the slope length × the ramp width, scaled
	# so the wear pattern matches the body's cell size. Argument order
	# below is winding-corrected so the slope's normal points UP/OUT,
	# not into the wedge body. Same correction on the side caps and
	# underside.
	var slope_len: float = sqrt(run * run + height * height)
	var uv_w: float = width * 0.4
	var uv_l: float = slope_len * 0.4
	push_tri.call(tA, bB, tB, Vector2(0, 0), Vector2(uv_w, uv_l), Vector2(uv_w, 0))
	push_tri.call(tA, bA, bB, Vector2(0, 0), Vector2(0, uv_l), Vector2(uv_w, uv_l))
	# Two vertical side triangles capping the wedge ends.
	var uv_s_l: float = run * 0.4
	var uv_s_h: float = height * 0.4
	push_tri.call(tA, uA, bA, Vector2(0, uv_s_h), Vector2(0, 0), Vector2(uv_s_l, 0))
	push_tri.call(tB, bB, uB, Vector2(0, uv_s_h), Vector2(uv_s_l, 0), Vector2(0, 0))
	# Underside (downward face).
	push_tri.call(uA, bB, bA, Vector2(0, 0), Vector2(uv_s_l, uv_w), Vector2(uv_s_l, 0))
	push_tri.call(uA, uB, bB, Vector2(0, 0), Vector2(0, uv_w), Vector2(uv_s_l, uv_w))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	mesh_inst.material_override = share_mat
	root.add_child(mesh_inst)

	# Collision — convex hull from all 6 unique vertices. Provides the
	# solid wedge for unit physics AND the walkable slope surface for
	# the navmesh bake. The hull's vertices bA/bB sit at exactly y=0
	# (ramp foot) and tA/tB at y=height (plateau side), so the slope
	# face meets the ground at y=0 with no seam — important so the
	# bake produces continuous navmesh from ground to plateau-top.
	# (An earlier attempt added a thin BoxShape3D rotated to match the
	# slope, but the rotation math left the box's TOP face floating
	# ~0.2u above the ground at the ramp foot, creating an intermittent
	# seam the path planner only bridged on some re-plans — the user
	# saw this as units refusing to enter the ramp without spam-
	# clicking move commands. The convex hull alone gives a clean
	# slope-to-ground contact.)
	var col := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([tA, tB, bA, bB, uA, uB])
	col.shape = hull
	root.add_child(col)

	# Navmesh — sloped walking surface as 2 tris in world space. Vertices
	# tA/tB sit exactly on the plateau top edge so the path planner sees
	# this slope as connected to the plateau top fan.
	var to_world := func(v: Vector3) -> Vector3: return v + plateau_center
	_pending_nav_polys.append(PackedVector3Array([to_world.call(tA), to_world.call(tB), to_world.call(bB)]))
	_pending_nav_polys.append(PackedVector3Array([to_world.call(tA), to_world.call(bB), to_world.call(bA)]))

	# (NavigationLink3D removed.) With the bake-based navmesh handling
	# plateaus and ramps directly via the explicit walkable-slope
	# collision above, the link becomes a path-planner trap: when a
	# unit on the plateau top is told to leave, the planner picks the
	# link's slope-TOP endpoint as its first waypoint, which the unit
	# walks toward — straight off the plateau cliff. It then "uses" the
	# link to teleport its path target to the slope BOTTOM, but the
	# unit is still falling. Net effect: ordering a plateau-top unit
	# anywhere off-plateau caused it to dive off the edge mid-air.


## Cached procedural alpha mask for ground patches. Generated once at first
## use and shared across every patch material so the same blob silhouette
## tints differently per patch instead of repeating identical squares.
static var _patch_alpha_tex: Texture2D = null


func _setup_ground_patches() -> void:
	# Two layers stacked:
	#   1. Large biome zones (40-70u) that tint the ground a different
	#      base hue with soft, irregular edges — slag-soot fields, sand
	#      drifts, dried-mud zones. These give the map distinct regions
	#      with gradual transitions instead of one uniform tone.
	#   2. Small detail patches (3-12u) scattered throughout — soot blots,
	#      sand smears, occasional reflective oil spills.
	#
	# Every patch reuses a single procedural alpha-mask texture: an
	# irregular blob with a soft radial fade to alpha 0 at the edges. This
	# replaces the previous mono-color rectangular planes (which read as
	# obvious squares against the noise ground) with rounded organic
	# shapes that blend into whatever's underneath them.

	# Biome zones — placed off the corners + a couple in mid-flank gaps so
	# they don't crowd the deposits or the contested center. Mirrored
	# across z=0 so neither team gets a different look. Foundry Belt
	# uses an industrial palette (soot / sand / dried mud); Ashplains
	# leans into pale-ash drift fields with a darker volcanic scar to
	# break up the otherwise uniform plains.
	var biomes: Array[Dictionary]
	if _is_iron_gate():
		# Iron Gate winter zone — packed slush + exposed asphalt
		# under uneven snowpack. Big mottled patches break the
		# otherwise-uniform pale ground into a textured wintry
		# read. Mirrored across z=0 so the symmetry holds.
		biomes = [
			# Cleared road / vehicle-track zone running through the
			# centre — darker exposed asphalt where the snow's been
			# trampled or plowed.
			{"pos": Vector3(0.0, 0.025, 0.0), "size": 60.0, "tint": Color(0.18, 0.20, 0.22, 0.55), "rough": 1.0},
			# Slush drift zones flanking the spawns — slightly warmer
			# tone so they read as melted-and-refrozen, not fresh.
			{"pos": Vector3(0.0, 0.025, 80.0), "size": 80.0, "tint": Color(0.45, 0.48, 0.50, 0.45), "rough": 1.0},
			{"pos": Vector3(0.0, 0.025, -80.0), "size": 80.0, "tint": Color(0.45, 0.48, 0.50, 0.45), "rough": 1.0},
			# Iron-stained patches around the central ruins — the
			# rust + cold mix that gives the map its name.
			{"pos": Vector3(48.0, 0.025, 30.0), "size": 35.0, "tint": Color(0.30, 0.20, 0.16, 0.55), "rough": 1.0},
			{"pos": Vector3(-48.0, 0.025, -30.0), "size": 35.0, "tint": Color(0.30, 0.20, 0.16, 0.55), "rough": 1.0},
			# Far-flank dirt-windswept zones where the snow's been
			# scoured off entirely.
			{"pos": Vector3(95.0, 0.025, 0.0), "size": 50.0, "tint": Color(0.22, 0.20, 0.16, 0.55), "rough": 1.0},
			{"pos": Vector3(-95.0, 0.025, 0.0), "size": 50.0, "tint": Color(0.22, 0.20, 0.16, 0.55), "rough": 1.0},
		]
	elif _is_ashplains():
		biomes = [
			# Pale-ash drift zones either side of the central ridge —
			# wash out a wide swath of the open ground so it reads as
			# "ash plains", not "grey field". Pushed warmer + more
			# saturated so the sand has actual desert character.
			{"pos": Vector3(0.0, 0.025, 60.0), "size": 90.0, "tint": Color(0.55, 0.42, 0.24, 0.62), "rough": 1.0},
			{"pos": Vector3(0.0, 0.025, -60.0), "size": 90.0, "tint": Color(0.55, 0.42, 0.24, 0.62), "rough": 1.0},
			# Volcanic scar that crosses the central deposit area —
			# darker than the rest, marks where the heaviest fighting
			# tends to happen.
			{"pos": Vector3(0.0, 0.025, 0.0), "size": 55.0, "tint": Color(0.08, 0.06, 0.05, 0.70), "rough": 1.0},
			# Bleached bone-white salt-flat patches — distinctive
			# wasteland read.
			{"pos": Vector3(50.0, 0.025, 95.0), "size": 38.0, "tint": Color(0.78, 0.72, 0.55, 0.50), "rough": 1.0},
			{"pos": Vector3(-50.0, 0.025, -95.0), "size": 38.0, "tint": Color(0.78, 0.72, 0.55, 0.50), "rough": 1.0},
			# Cracked-earth dark zones — deep ferrous-rust tone that
			# breaks up the warm sand belt.
			{"pos": Vector3(70.0, 0.025, 30.0), "size": 42.0, "tint": Color(0.22, 0.13, 0.08, 0.65), "rough": 1.0},
			{"pos": Vector3(-70.0, 0.025, -30.0), "size": 42.0, "tint": Color(0.22, 0.13, 0.08, 0.65), "rough": 1.0},
			# Far-flank dust patches.
			{"pos": Vector3(115.0, 0.025, 0.0), "size": 50.0, "tint": Color(0.52, 0.40, 0.22, 0.55), "rough": 1.0},
			{"pos": Vector3(-115.0, 0.025, 0.0), "size": 50.0, "tint": Color(0.52, 0.40, 0.22, 0.55), "rough": 1.0},
		]
	else:
		biomes = [
			# Soot scar across the contested mid (ash-grey).
			{"pos": Vector3(0.0, 0.025, 0.0), "size": 70.0, "tint": Color(0.09, 0.09, 0.10, 0.55), "rough": 1.0},
			# Sand drift on the east flank (warm ochre).
			{"pos": Vector3(95.0, 0.025, 35.0), "size": 55.0, "tint": Color(0.32, 0.26, 0.18, 0.50), "rough": 0.95},
			# Sand drift on the west flank (mirror).
			{"pos": Vector3(-95.0, 0.025, -35.0), "size": 55.0, "tint": Color(0.30, 0.24, 0.17, 0.50), "rough": 0.95},
			# Dried-mud zones near the back-doors (slate-tan).
			{"pos": Vector3(70.0, 0.025, -75.0), "size": 50.0, "tint": Color(0.21, 0.17, 0.13, 0.55), "rough": 0.95},
			{"pos": Vector3(-70.0, 0.025, 75.0), "size": 50.0, "tint": Color(0.21, 0.17, 0.13, 0.55), "rough": 0.95},
		]
	for b: Dictionary in biomes:
		_spawn_soft_patch(
			b["pos"] as Vector3,
			b["size"] as float,
			b["tint"] as Color,
			b["rough"] as float,
			false,
		)

	# Small detail patches — denser than before so the eye reads the
	# ground as patchy rather than uniform-noise. Map-aware roll so
	# the desert gets cracked-earth and bleached-bone patches, while
	# the foundry belt gets soot blots and oil spills.
	var detail_count: int = 80
	const MAP_HALF: float = 135.0
	var on_ash: bool = _is_ashplains()
	var on_iron: bool = _is_iron_gate()
	# Iron Gate gets denser detail patches — the ground is more
	# uniform without them and reads as too-clean snowfield.
	if on_iron:
		detail_count = 130
	for i: int in detail_count:
		var pos := Vector3(
			randf_range(-MAP_HALF, MAP_HALF),
			0.03,
			randf_range(-MAP_HALF, MAP_HALF),
		)
		# Skip the HQ pads.
		if absf(pos.x) < 12.0 and absf(pos.z) > 95.0:
			continue
		var roll: float = randf()
		if on_iron:
			# Wintry-grey palette: snow drifts (lighter), exposed
			# rock (darker), iron-rust patches (warm), dirty packed
			# slush (mid-grey). Higher overall density + a bit of
			# variance in size makes the snowpack read as broken
			# and lived-in rather than a flat sheet.
			if roll < 0.28:
				# Slush / packed dirty snow — grey wash with light
				# alpha, soft-edged.
				_spawn_soft_patch(pos, randf_range(3.5, 7.0), Color(0.40, 0.42, 0.44, randf_range(0.40, 0.60)), 1.0, false)
			elif roll < 0.50:
				# Exposed asphalt / dark rock — high-contrast dark
				# patch breaking up the pale ground.
				_spawn_soft_patch(pos, randf_range(2.5, 5.5), Color(0.10, 0.10, 0.12, randf_range(0.55, 0.78)), 1.0, false)
			elif roll < 0.68:
				# Iron-stained rust spot — warm orange-brown,
				# sparse so it reads as stains, not background.
				_spawn_soft_patch(pos, randf_range(2.5, 5.0), Color(0.42, 0.22, 0.13, randf_range(0.45, 0.65)), 1.0, false)
			elif roll < 0.82:
				# Drift snow — slightly brighter than the base
				# tint, low alpha so it reads as light surface
				# texture.
				_spawn_soft_patch(pos, randf_range(3.0, 6.0), Color(0.78, 0.80, 0.78, randf_range(0.30, 0.45)), 1.0, false)
			elif roll < 0.92:
				# Frozen mud puddle — dark warm patch with a
				# slightly cool blue undertone.
				_spawn_soft_patch(pos, randf_range(2.5, 4.5), Color(0.18, 0.16, 0.14, randf_range(0.50, 0.72)), 1.0, false)
			else:
				# Sparse ice glaze — low-roughness reflective spot.
				_spawn_soft_patch(pos, randf_range(2.0, 3.5), Color(0.80, 0.85, 0.92, randf_range(0.32, 0.48)), 0.40, false)
		elif on_ash:
			if roll < 0.24:
				# Cracked-earth — dark warm patch with a slightly red
				# undertone, reads as parched riverbed.
				_spawn_soft_patch(pos, randf_range(4.0, 8.5), Color(0.22, 0.14, 0.09, randf_range(0.55, 0.78)), 1.0, false)
			elif roll < 0.45:
				# Bleached / salt-flat — pale tan-white wash.
				_spawn_soft_patch(pos, randf_range(4.0, 9.0), Color(0.78, 0.72, 0.55, randf_range(0.40, 0.62)), 1.0, false)
			elif roll < 0.66:
				# Sand smear — warmer than the foundry version.
				_spawn_soft_patch(pos, randf_range(4.5, 9.5), Color(0.50, 0.38, 0.22, randf_range(0.45, 0.7)), 0.95, false)
			elif roll < 0.78:
				# Dry-earth patch with reddish-clay tint.
				_spawn_soft_patch(pos, randf_range(3.5, 7.5), Color(0.36, 0.20, 0.13, randf_range(0.50, 0.72)), 1.0, false)
			elif roll < 0.86:
				# Hardy moss — rare green patch where shade pools (small).
				_spawn_soft_patch(pos, randf_range(2.5, 4.5), Color(0.20, 0.32, 0.16, randf_range(0.40, 0.62)), 1.0, false)
			elif roll < 0.93:
				# Volcanic-glass shard — small dark high-contrast spot.
				_spawn_soft_patch(pos, randf_range(2.5, 5.0), Color(0.06, 0.04, 0.05, randf_range(0.65, 0.85)), 0.55, false)
			else:
				# Reflective oil spill — uncommon on the desert but
				# they happen near old crash sites.
				_spawn_oil_spill(pos)
		else:
			if roll < 0.32:
				# Soot blot.
				_spawn_soft_patch(pos, randf_range(5.0, 10.0), Color(0.05, 0.05, 0.05, randf_range(0.55, 0.8)), 1.0, false)
			elif roll < 0.55:
				# Sand smear (cooler than the desert).
				_spawn_soft_patch(pos, randf_range(4.5, 8.5), Color(0.34, 0.27, 0.18, randf_range(0.45, 0.7)), 0.95, false)
			elif roll < 0.70:
				# Dry-earth patch with cracking — reddish-brown.
				_spawn_soft_patch(pos, randf_range(4.0, 8.0), Color(0.32, 0.22, 0.15, randf_range(0.50, 0.72)), 1.0, false)
			elif roll < 0.82:
				# Hardy moss / weed-grass tuft — cool green patch where
				# the industrial belt has been left to itself for a while.
				# Bigger range than the desert variant so it reads as
				# actual green rather than a moss spot.
				_spawn_soft_patch(pos, randf_range(3.5, 6.5), Color(0.22, 0.34, 0.18, randf_range(0.45, 0.65)), 1.0, false)
			elif roll < 0.92:
				# Reflective oil spill — multi-blob spawn for the puddle
				# silhouette, low roughness for the wet-glint read.
				_spawn_oil_spill(pos)
			else:
				# Slag-grey patch — cool industrial residue.
				_spawn_soft_patch(pos, randf_range(3.5, 6.5), Color(0.22, 0.22, 0.24, randf_range(0.45, 0.65)), 0.95, false)


func _spawn_soft_patch(pos: Vector3, base_size: float, tint: Color, roughness: float, oil: bool) -> void:
	# Soft-edged organic patch built from a triangle-fan ArrayMesh with
	# vertex-color alpha (1 at center → 0 at perimeter). The fade is
	# entirely driven by per-vertex interpolation, so we don't depend on
	# transparency-texture sampling working correctly across drivers
	# (which was the bug producing solid black rectangles in earlier
	# attempts that used a procedural alpha texture).
	var patch := MeshInstance3D.new()
	patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var x_scale: float = randf_range(0.85, 1.25)
	var z_scale: float = randf_range(0.85, 1.25)
	patch.mesh = _build_soft_blob_mesh(base_size * 0.5, x_scale, z_scale)
	patch.position = pos
	patch.rotation.y = randf_range(0.0, TAU)

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = tint
	# Vertex color carries the alpha falloff; multiplied with albedo_color
	# this gives `tint` at the center fading smoothly to fully transparent
	# at the blob edge.
	mat.vertex_color_use_as_albedo = true
	mat.roughness = roughness
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if oil else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	if oil:
		# Kept for backwards-compat (the recommended path is now
		# `_spawn_oil_spill`). Subtle emission to fake the wet glint.
		mat.emission_enabled = true
		mat.emission = Color(0.18, 0.12, 0.22, 1.0)
		mat.emission_energy_multiplier = 0.35

	patch.material_override = mat
	add_child(patch)


func _build_soft_blob_mesh(base_radius: float, x_scale: float, z_scale: float) -> ArrayMesh:
	# Triangle-fan disc with `BLOB_VERTS` perimeter vertices. Each perimeter
	# vertex gets a small radial noise offset so the silhouette is
	# irregular (slightly off-circle). Center vertex has alpha = 1.0,
	# perimeter vertices have alpha = 0.0 — the rasteriser interpolates
	# between them, producing the soft fade.
	const BLOB_VERTS: int = 24
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	# Center vertex, full alpha, UV at (0.5, 0.5).
	verts.append(Vector3.ZERO)
	colors.append(Color(1, 1, 1, 1))
	uvs.append(Vector2(0.5, 0.5))
	for i: int in BLOB_VERTS:
		var ang: float = float(i) / float(BLOB_VERTS) * TAU
		var radius_jitter: float = randf_range(0.85, 1.18)
		var rx: float = cos(ang) * base_radius * x_scale * radius_jitter
		var rz: float = sin(ang) * base_radius * z_scale * radius_jitter
		verts.append(Vector3(rx, 0.0, rz))
		colors.append(Color(1, 1, 1, 0))
		# UV maps perimeter to a unit circle in [0,1] space — gives any
		# texture sampled on the blob a natural radial layout (centered
		# detail, perimeter is the texture's edge).
		uvs.append(Vector2(0.5 + cos(ang) * 0.5, 0.5 + sin(ang) * 0.5))
	# Indices — fan connecting center (0) to each perimeter pair.
	var indices := PackedInt32Array()
	for i: int in BLOB_VERTS:
		var a: int = 1 + i
		var b: int = 1 + ((i + 1) % BLOB_VERTS)
		indices.append(0)
		indices.append(b)
		indices.append(a)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _spawn_oil_spill(center: Vector3) -> void:
	# An oil spill is rendered as 2-4 overlapping elongated blobs at
	# slightly offset positions and rotations. Each blob is irregular
	# (random aspect ratio 0.55-1.8) so the combined silhouette reads as
	# a real puddle that's seeped into uneven ground rather than a single
	# round disc.
	#
	# We deliberately don't use `metallic` because StandardMaterial3D's
	# transparent-metallic path can't sample reflections during the
	# alpha-blend pass and the test_arena environment is too dark for
	# real reflections anyway. Instead the wet/glossy read comes from
	# very low roughness (catches direct-light specular) plus a subtle
	# violet-tinged emission that gives the puddle the "iridescent oil
	# sheen" look in any lighting.
	var blob_count: int = randi_range(2, 4)
	var oil_tex: Texture2D = _get_oil_sheen_tex()
	for i: int in blob_count:
		var blob := MeshInstance3D.new()
		blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var base_size: float = randf_range(2.6, 4.5)
		# Aggressive aspect ratio jitter so each blob is an oblong, not a
		# circle — adjacent oblongs at different rotations form an
		# irregular outline.
		var aspect: float = randf_range(0.55, 1.8)
		# Same vertex-alpha blob mesh the soft patches use, so the oil
		# silhouette fades to transparent at the edges and the texture
		# shows through cleanly without depending on transparency-mode
		# texture alpha sampling.
		blob.mesh = _build_soft_blob_mesh(base_size * 0.5, aspect, 1.0 / aspect)
		# Small per-blob offset so they overlap rather than stack at
		# identical positions. y stays at 0.04 so all blobs sit at the
		# same ground level and don't z-fight against each other.
		var offset := Vector3(randf_range(-1.2, 1.2), 0.04, randf_range(-1.2, 1.2))
		blob.position = center + offset
		blob.rotation.y = randf_range(0.0, TAU)

		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		# Slightly varied dark base — pure-black blobs read as holes;
		# adding a touch of violet keeps them looking like fluid. Vertex
		# color provides the alpha falloff; tint multiplies the iridescent
		# texture to bias it toward the dark-fluid end of the gradient.
		var base: Color = Color(
			randf_range(0.04, 0.07),
			randf_range(0.03, 0.05),
			randf_range(0.05, 0.09),
			1.0,
		)
		mat.albedo_color = base
		mat.albedo_texture = oil_tex
		mat.roughness = 0.18
		mat.metallic = 0.0
		# Iridescent sheen — emission energy is low but the cool tint
		# breaks the monotonous dark and reads as the "rainbow" you get
		# off a real oil puddle.
		mat.emission_enabled = true
		mat.emission = Color(0.22, 0.14, 0.30, 1.0)
		mat.emission_energy_multiplier = 0.4

		blob.material_override = mat
		add_child(blob)


## Procedural texture used for oil-spill blobs. RGB carries faint iridescent
## streaks (cool blues / violets) over a dark base; alpha is the same kind
## of soft radial blob mask the other patches use, but with stronger noise
## perturbation so the silhouette is more obviously irregular.
static var _oil_sheen_tex: Texture2D = null


func _get_oil_sheen_tex() -> Texture2D:
	if _oil_sheen_tex:
		return _oil_sheen_tex
	const TEX_SIZE: int = 256
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var shape_noise := FastNoiseLite.new()
	shape_noise.seed = 41
	shape_noise.frequency = 0.025
	shape_noise.fractal_octaves = 4
	var sheen_noise := FastNoiseLite.new()
	sheen_noise.seed = 73
	sheen_noise.frequency = 0.04
	sheen_noise.fractal_octaves = 3
	var center: Vector2 = Vector2(TEX_SIZE * 0.5, TEX_SIZE * 0.5)
	var max_r: float = TEX_SIZE * 0.5
	for y: int in TEX_SIZE:
		for x: int in TEX_SIZE:
			var dx: float = float(x) - center.x
			var dy: float = float(y) - center.y
			# Strong noise perturbation on the radius so the blob outline
			# is noticeably non-circular.
			var d: float = sqrt(dx * dx + dy * dy) / max_r
			d += shape_noise.get_noise_2d(float(x), float(y)) * 0.32
			var t: float = clampf((d - 0.3) / 0.65, 0.0, 1.0)
			var alpha: float = 1.0 - (t * t * (3.0 - 2.0 * t))

			# Iridescent streaks. Sheen noise drives a hue offset
			# between cold blue (low) and warm amber (high) over the
			# base dark color. Streaks are thin so most of the puddle
			# still reads as dark fluid.
			var s: float = sheen_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var base := Color(0.06, 0.045, 0.07)
			var streak: Color
			if s < 0.45:
				streak = Color(0.10, 0.10, 0.22)  # cool blue
			elif s > 0.7:
				streak = Color(0.20, 0.14, 0.05)  # warm amber
			else:
				streak = base
			var rgb: Color = base.lerp(streak, clampf(absf(s - 0.5) * 2.0, 0.0, 1.0))
			img.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, alpha))
	img.generate_mipmaps()
	_oil_sheen_tex = ImageTexture.create_from_image(img)
	return _oil_sheen_tex


func _get_patch_alpha_tex() -> Texture2D:
	## Lazily build a white-RGB / radial-noise-alpha image and cache it.
	## The alpha channel is a soft radial falloff perturbed by low-
	## frequency noise so the patch silhouette is irregular and the
	## edges fade gracefully into the ground beneath. Generated once per
	## process; shared across every patch material.
	##
	## Uses FORMAT_RGBA8 (not LA8) — StandardMaterial3D's albedo path
	## expects RGBA, and LA8 was producing opaque dark rectangles on
	## some hardware because the alpha channel wasn't sampled correctly.
	if _patch_alpha_tex:
		return _patch_alpha_tex
	const TEX_SIZE: int = 256
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 17
	noise.frequency = 0.02
	noise.fractal_octaves = 3
	var center: Vector2 = Vector2(TEX_SIZE * 0.5, TEX_SIZE * 0.5)
	var max_r: float = TEX_SIZE * 0.5
	for y: int in TEX_SIZE:
		for x: int in TEX_SIZE:
			var dx: float = float(x) - center.x
			var dy: float = float(y) - center.y
			var d: float = sqrt(dx * dx + dy * dy) / max_r
			# Perturb the radius with noise so the silhouette isn't a
			# perfect circle.
			d += noise.get_noise_2d(float(x), float(y)) * 0.22
			# Smooth fade: opaque inside ~0.35 of the radius, fully
			# transparent past 0.95.
			var t: float = clampf((d - 0.35) / 0.6, 0.0, 1.0)
			var alpha: float = 1.0 - (t * t * (3.0 - 2.0 * t))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	# Mipmaps so the texture samples cleanly when patches are seen at
	# steep angles or far distances.
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_patch_alpha_tex = tex
	return _patch_alpha_tex


func _setup_skyline_features() -> void:
	# Tall decorative refinery stacks / broken towers / chimney columns
	# scattered around the map. Non-walkable obstacles (collision_layer 4
	# like terrain) — purely about giving the silhouette a vertical read
	# from the RTS camera angle so the map doesn't look flat.
	#
	# Positions are off the central battle lanes (deposits / chokepoints
	# are still clear) and skewed toward the edges so they fill empty
	# corners rather than block routing.
	var pieces: Array[Dictionary]
	if _is_ashplains():
		# Ashplains is meant to FEEL open and exposed. Skyline features
		# are pushed to the very edges — distant silhouettes that frame
		# the map without breaking up the open central plain.
		pieces = [
			# Far-corner pylons (just visual bookends, way out at the
			# camera bound).
			{"pos": Vector3(125.0, 0.0, 110.0), "kind": "pylon", "height": 6.5},
			{"pos": Vector3(-125.0, 0.0, 110.0), "kind": "pylon", "height": 6.5},
			{"pos": Vector3(125.0, 0.0, -110.0), "kind": "pylon", "height": 6.5},
			{"pos": Vector3(-125.0, 0.0, -110.0), "kind": "pylon", "height": 6.5},
			# A pair of broken towers on the deep east + west edges so
			# the long sightline isn't completely empty.
			{"pos": Vector3(135.0, 0.0, 0.0), "kind": "tower", "height": 7.0},
			{"pos": Vector3(-135.0, 0.0, 0.0), "kind": "tower", "height": 7.0},
			# A single chimney cluster in the back-far-corner (only one;
			# Ashplains intentionally has very little "stuff" to look at).
			{"pos": Vector3(0.0, 0.0, 130.0), "kind": "chimneys", "height": 8.5},
			{"pos": Vector3(0.0, 0.0, -130.0), "kind": "chimneys", "height": 8.5},
		]
	else:
		pieces = [
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
	# Skip if the trunk would land inside a plateau footprint -- the
	# trunk is at y=0 and the plateau top is ~1.5-2u up, so the result
	# reads as a tower half-submerged in the platform.
	var trunk_radius_check: float = 1.4 if kind != "pylon" else 0.9
	var trunk_check_size: Vector3 = Vector3(trunk_radius_check * 1.6, 1.0, trunk_radius_check * 1.6)
	if _overlaps_plateau_footprint(pos, trunk_check_size, 0.0):
		return
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
	base_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	base_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
	base_mat.uv1_scale = Vector3(1.8, 1.8, 1.0)
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
	col_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	col_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
	col_mat.uv1_scale = Vector3(1.5, 3.0, 1.0)
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
	trunk_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	trunk_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
	trunk_mat.uv1_scale = Vector3(1.8, 2.2, 1.0)
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
	upper_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	upper_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
	upper_mat.uv1_scale = Vector3(1.6, 1.8, 1.0)
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
		ch_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
		ch_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
		ch_mat.uv1_scale = Vector3(1.2, 2.5, 1.0)
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
	post_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	post_mat.uv1_offset = Vector3(randf(), randf(), 0.0)
	post_mat.uv1_scale = Vector3(1.0, 3.0, 1.0)
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
	# Skip the standard patrols entirely in tutorial mode so the
	# only enemies on the map are the southern fortified camp.
	if _setup_neutral_patrols_or_skip():
		return
	# Patrols don't move on their own — they're stationary and rely on the
	# combat component's auto-engage to defend their deposit. Neutrals share
	# owner_id = 2, which makes both player and AI see them as enemies (and
	# they don't shoot each other).
	var rook_stats: UnitStatResource = load("res://resources/units/anvil_rook.tres") as UnitStatResource
	var hound_stats: UnitStatResource = load("res://resources/units/anvil_hound.tres") as UnitStatResource
	var bulwark_stats: UnitStatResource = load("res://resources/units/anvil_bulwark.tres") as UnitStatResource

	var patrols: Array[Dictionary]
	if _is_ashplains():
		# Ashplains layout (V2 §"Map 2"). 1 Light per safe deposit + 1
		# Heavy on the central deposit (THE objective). Flank deposits
		# in 2v2 get a Medium each.
		if _is_2v2():
			patrols = [
				{"stats": rook_stats, "pos": Vector3(-30 + 4, 0, 70)},
				{"stats": rook_stats, "pos": Vector3(30 - 4, 0, 70)},
				{"stats": rook_stats, "pos": Vector3(-30 + 4, 0, -70)},
				{"stats": rook_stats, "pos": Vector3(30 - 4, 0, -70)},
				{"stats": bulwark_stats, "pos": Vector3(4, 0, 4)},   # Central — THE objective
				{"stats": hound_stats, "pos": Vector3(70 + 4, 0, 0)},   # East flank
				{"stats": hound_stats, "pos": Vector3(-70 - 4, 0, 0)},  # West flank
			]
		else:
			patrols = [
				{"stats": rook_stats, "pos": Vector3(4, 0, 80)},     # Player safe
				{"stats": rook_stats, "pos": Vector3(-4, 0, -80)},   # AI safe
				{"stats": bulwark_stats, "pos": Vector3(4, 0, 4)},   # Central — THE objective
			]
	elif _is_2v2():
		# Foundry Belt 2v2 layout.
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
		# Foundry Belt 1v1 layout (V2 §"Map 1"):
		# - 1 Light patrol on each safe-side deposit
		# - 1 Medium patrol on each contested mid-deposit
		# - 1 Heavy patrol on each back-door + the Apex scar
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


func _spawn_neutral_building(b_stats: BuildingStatResource, pos: Vector3, y_rot: float) -> void:
	## Drops a derelict / abandoned building into the map under the
	## neutral player. Set is_constructed before _ready so the building
	## skips the construction ramp and its components (turret, etc.)
	## activate immediately. Neutral owner_id = 2 → hostile to both
	## teams via the existing PlayerRegistry are_allied path; destroying
	## one drops the standard 35%-of-cost wreck.
	if not b_stats:
		return
	var building_scene: PackedScene = load("res://scenes/building.tscn") as PackedScene
	if not building_scene:
		return
	var b: Building = building_scene.instantiate() as Building
	if not b:
		return
	b.stats = b_stats
	b.owner_id = 2  # PlayerRegistry.NEUTRAL_PLAYER_ID
	b.is_constructed = true
	add_child(b)
	b.global_position = pos
	b.rotation.y = y_rot


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
			"res://resources/buildings/advanced_generator.tres",
			"res://resources/buildings/basic_armory.tres",
			"res://resources/buildings/advanced_armory.tres",
			"res://resources/buildings/gun_emplacement.tres",
			"res://resources/buildings/gun_emplacement_basic.tres",
			# V3 §"Pillar 3" — Aerodrome (produces aircraft) + SAM Site
			# (anti-air defense). Both available to either faction.
			"res://resources/buildings/aerodrome.tres",
			"res://resources/buildings/sam_site.tres",
			# V3 §"Pillar 2" — Sable's Mesh anchor structure. Filtered
			# below by faction_lock so Anvil players don't see it.
			"res://resources/buildings/black_pylon.tres",
		]
		var player_faction: int = _faction_id_for_player(0)
		for path: String in stat_paths:
			var stat: BuildingStatResource = load(path) as BuildingStatResource
			if not stat:
				continue
			# faction_lock 0 = universal, 1 = Anvil only, 2 = Sable only.
			# Player faction id 0 = Anvil, 1 = Sable. Map: lock = (faction_id + 1).
			if stat.faction_lock != 0 and stat.faction_lock != (player_faction + 1):
				continue
			buildable_buildings.append(stat)
	selection_mgr.set_buildable_buildings(buildable_buildings)
