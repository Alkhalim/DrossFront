class_name SalvageCrawler
extends CharacterBody3D
## Mobile salvage harvester (v2 §1.3). Slow large unit that workers anchor to.
## Selectable + commandable like a player unit; visually presents as a low
## tracked platform with a workshop on top. The actual worker management
## is handled by an attached SalvageYardComponent so we share the proven
## spawn/harvest/return logic.

signal squad_destroyed   # for combat target validation parity with Unit

@export var stats: UnitStatResource
@export var owner_id: int = 0

const PLAYER_COLOR := Color(0.08, 0.25, 0.85, 1.0)
const ENEMY_COLOR := Color(0.80, 0.10, 0.10, 1.0)
const NEUTRAL_COLOR := Color(0.85, 0.7, 0.3, 1.0)


static func _color_for(owner_idx: int) -> Color:
	# Static fallback when no registry is reachable. Runtime callers go
	# through `_resolve_team_color` which honours team alliances.
	if owner_idx == 0:
		return PLAYER_COLOR
	if owner_idx == 2:
		return NEUTRAL_COLOR
	return ENEMY_COLOR


func _resolve_team_color() -> Color:
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	if registry and registry.has_method("get_perspective_color"):
		return registry.get_perspective_color(owner_id)
	return SalvageCrawler._color_for(owner_id)
const ARRIVE_THRESHOLD: float = 1.4
## Crawler's worker harvest radius. Pulled in 12% from the original
## 45u to 39.6u per balance request -- crawlers were reaching too far
## into the contested mid; the smaller leash forces the player to
## actually advance the crawler to push the front line.
const HARVEST_RADIUS: float = 39.6
## Wrecks above this size are too tough to crush — Crawler bumps into them.
const CRUSH_MAX_WRECK_SIZE: float = 1.3
## Salvage absorbed when crushing a wreck (per doc: 25%).
const CRUSH_SALVAGE_FRAC: float = 0.25

var resource_manager: Node = null

## Combat compatibility (selection / targeting code reads these).
var alive_count: int = 1
var current_hp: int = 800
## True while the crawler has been told to move; mirrors Unit.has_move_order
## so combat / hover code that tests this still works.
var has_move_order: bool = false
## Where the unit is currently moving to. Vector3.INF means stopped.
var move_target: Vector3 = Vector3.INF
## Optional waypoint chain for Ctrl-clicked queued moves.
var move_queue: Array[Vector3] = []
var is_selected: bool = false
var hp_bar_hovered: bool = false

var _move_speed: float = 3.0          # set from stats.speed_tier in _ready
var _nav_agent: NavigationAgent3D = null
var _yard_component: Node = null
## Stuck-rescue: same logic as Unit. Tracks how long the Crawler has been
## ordered somewhere but unable to make progress; re-paths once at 1.5s and
## gives up at 5s so a wedged Crawler doesn't grind forever.
var _stuck_timer: float = 0.0

## Wreck-crushing — runs at a low cadence so we don't hammer the wrecks group.
const CRUSH_CHECK_INTERVAL: float = 0.25
var _crush_timer: float = 0.0
## Crawler's effective "treads" footprint — wrecks within this XZ distance
## get crushed if they're small enough. Treads cover the chassis hull.
const CRUSH_RADIUS: float = 2.4

## Mid-trip salvage drop — when the Crawler relocates significantly, its
## carrying workers drop their loads at their current positions per v3.3 §1.3.
const RELOCATION_DROP_DISTANCE: float = 10.0
var _last_relocation_anchor: Vector3 = Vector3.INF

## Anchor Mode state machine (v3.3 §3.1).
enum AnchorState { OFF, DEPLOYING, ANCHORED, UNDEPLOYING }
const ANCHOR_DEPLOY_TIME: float = 5.0
const ANCHOR_ARMOR_BONUS: float = 0.5      # +50% damage reduction multiplier
const ANCHOR_WORKER_BONUS: float = 0.25    # +25% effective workers (we add a worker slot)
const ANCHOR_RANGE_BONUS: float = 0.30     # +30% harvest radius while deployed
const _BASE_MAX_WORKERS: int = 4
const _BASE_HARVEST_RADIUS: float = HARVEST_RADIUS

var anchor_state: int = AnchorState.OFF
var _anchor_progress: float = 0.0
## Visual plating Node3D added when anchored (lazily built).
var _anchor_plating: Node3D = null

# Visual elements that we can toggle for selection highlight.
var _hull: MeshInstance3D = null
var _team_stripe: MeshInstance3D = null

## Track-plate scrolling — list of {node, segment_z_min, segment_length}
## entries. Each frame we advance the plate's local Z by delta *
## _move_speed when the crawler is moving, wrapping back to the front
## of the segment when it falls off the rear.
var _track_plates: Array[Dictionary] = []
var _track_scroll_t: float = 0.0
var _hp_bar: Node3D = null
var _hp_bar_fill: MeshInstance3D = null
var _hp_bar_bg: MeshInstance3D = null


func _ready() -> void:
	add_to_group("units")
	add_to_group("crawlers")
	add_to_group("owner_%d" % owner_id)

	if stats:
		current_hp = maxi(stats.hp_total, 1)
		_move_speed = stats.resolved_speed()

	# Collision: layer 2 (units, so click-select raycasts find it) AND
	# layer 4 (obstacles, so other units' mask=5 actually collides with
	# the chassis). Without the layer 4 bit, mechs walked straight
	# through the Crawler. Mask = 7 (ground + units + obstacles) so the
	# Crawler now also bumps into other units / workers / crawlers
	# instead of being able to drive straight through them.
	collision_layer = 6
	collision_mask = 7

	_build_visuals()
	_build_collision()
	_build_hp_bar()

	# Navigation agent for movement around obstacles.
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.name = "NavAgent"
	_nav_agent.path_desired_distance = 1.0
	_nav_agent.target_desired_distance = 1.5
	_nav_agent.avoidance_enabled = true
	_nav_agent.radius = 2.5
	_nav_agent.max_speed = _move_speed
	add_child(_nav_agent)

	# Worker management — reuse the existing SalvageYardComponent with
	# Crawler-spec overrides (per v3.3 §1.3): wider 45m harvest radius,
	# 4 workers, 18s spawn cadence, 1 salvage/sec self-trickle.
	var script: GDScript = load("res://scripts/salvage_yard_component.gd") as GDScript
	if script:
		_yard_component = script.new()
		_yard_component.name = "SalvageYardComponent"
		_yard_component.set("max_workers", 4)
		_yard_component.set("harvest_radius", HARVEST_RADIUS)
		_yard_component.set("worker_spawn_interval", 18.0)
		_yard_component.set("self_trickle_per_sec", 1.0)
		add_child(_yard_component)


## --- Compatibility shims for code that treats us as a Building ---
## SalvageYardComponent reads these via _building.get("is_constructed") /
## .has_method("get_power_efficiency") etc.

var is_constructed: bool = true       # Crawlers are always "ready" once spawned.

func get_power_efficiency() -> float:
	if resource_manager and resource_manager.has_method("get_power_efficiency"):
		return resource_manager.get_power_efficiency()
	return 1.0


## --- Visuals ---

## Vertical offset applied to every chassis-mounted element (hull,
## workshop, stripes, lights, crane, etc.). Treads / road wheels /
## sprockets stay at ground level so the chassis sits visibly above
## the tread block instead of sharing the ground plane with it.
const CHASSIS_LIFT: float = 0.20


func _build_visuals() -> void:
	var team_color: Color = _resolve_team_color()

	# Low rectangular hull (treads-and-platform silhouette).
	_hull = MeshInstance3D.new()
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(3.6, 1.0, 5.0)
	_hull.mesh = hull_box
	_hull.position.y = 0.55 + CHASSIS_LIFT
	var hull_mat := _make_metal(Color(0.32, 0.3, 0.27))
	_hull.set_surface_override_material(0, hull_mat)
	add_child(_hull)

	# Tread layout — Anvil ships a single long tread per side with
	# detailed plates, a visible drive sprocket up front, and an
	# idler wheel at the rear. Sable uses TWO shorter tread sets per
	# side ("bogie" pairs) for a quicker, more agile silhouette read.
	# Both layouts emit detailed plate strips on top of the tread so
	# the side panel doesn't look like a mono-coloured block.
	#
	# Both factions sit slightly raised off the ground so the tread
	# clearly protrudes below the hull instead of merging with it
	# (handled below by lifting _hull). Sable additionally angles
	# its two bogies — front bogie nose-up, rear bogie nose-down —
	# which raises the chassis belly visibly higher.
	var sable: bool = _faction_id() == 1
	for side: int in 2:
		var sx: float = -1.95 if side == 0 else 1.95
		if sable:
			# Two bogie sets per side, staggered front + rear with
			# opposite X-tilts so the bogies splay outward at the
			# ends. Lifts the chassis belly noticeably.
			_build_tread_segment(sx, -1.6, 1.85, -8.0)
			_build_tread_segment(sx, 1.6, 1.85, 8.0)
		else:
			_build_tread_segment(sx, 0.0, 5.2)
		# Drive sprocket up front (toothed wheel) — clearly the
		# "front" of the vehicle. Shape uses a low-radial cylinder
		# so the polygon edges read as gear teeth at distance.
		var sprocket := MeshInstance3D.new()
		var spr := CylinderMesh.new()
		spr.top_radius = 0.42
		spr.bottom_radius = 0.42
		spr.height = 0.22
		spr.radial_segments = 10
		sprocket.mesh = spr
		sprocket.rotation.z = PI * 0.5
		sprocket.position = Vector3(sx, 0.42, -2.55)
		sprocket.set_surface_override_material(0, _make_metal(Color(0.10, 0.10, 0.10)))
		add_child(sprocket)
		# Idler wheel at the rear — smooth round wheel, no teeth.
		var idler := MeshInstance3D.new()
		var idr := CylinderMesh.new()
		idr.top_radius = 0.36
		idr.bottom_radius = 0.36
		idr.height = 0.22
		idr.radial_segments = 16
		idler.mesh = idr
		idler.rotation.z = PI * 0.5
		idler.position = Vector3(sx, 0.42, 2.55)
		idler.set_surface_override_material(0, _make_metal(Color(0.18, 0.16, 0.14)))
		add_child(idler)

	# Workshop / cargo block on top of the hull. Per V3 silhouette
	# pass: faction-distinct profile so a Crawler reads its allegiance
	# from the dorsal turret alone.
	#   Anvil  -> two stacked rectangles, the smaller / shorter one
	#             at the front (industrial step-roof read).
	#   Sable  -> trapezoidal block, full-height vertical back wall
	#             tapering down to a low front face via a sloped roof
	#             plate (clean corp wedge read).
	# Both end up with the same front+back Z extent (-2.1 .. 1.3) and
	# X width (2.8) as the original single-box workshop, so every
	# downstream attachment (deck, ribs, mast, lamp housing, drums)
	# still lines up.
	var ws_x_w: float = 2.8
	var ws_z_total: float = 3.4
	var ws_centre_z: float = -0.4
	var ws_back_z_start: float = ws_centre_z + ws_z_total * 0.5 - ws_z_total * 0.5  # = -2.1
	# Back block: tall, sits on the rear half of the footprint. Used
	# by both factions.
	var back_h: float = 1.0
	var back_z_len: float = ws_z_total * 0.5  # 1.7
	var back_z_centre: float = ws_centre_z + back_z_len * 0.5
	var back_y_centre: float = 1.55 + CHASSIS_LIFT
	var back_block := MeshInstance3D.new()
	var back_box := BoxMesh.new()
	back_box.size = Vector3(ws_x_w, back_h, back_z_len)
	back_block.mesh = back_box
	back_block.position = Vector3(0, back_y_centre, back_z_centre)
	back_block.set_surface_override_material(0, _make_metal(Color(0.28, 0.26, 0.22)))
	add_child(back_block)

	# Front block — short height, shorter/lower than the back. Anvil
	# stops here (the step is the silhouette); Sable adds a sloped
	# roof piece below to fill the wedge in.
	var front_h: float = 0.55
	var front_z_len: float = ws_z_total * 0.5  # 1.7
	var front_z_centre: float = ws_centre_z - front_z_len * 0.5
	# Front-top sits BELOW back-top -> the step / wedge reads.
	var front_y_centre: float = back_y_centre + back_h * 0.5 - front_h * 0.5
	var sable_workshop: bool = _faction_id() == 1
	# Anvil's front block is also slightly narrower in X so the step
	# reads from above as well as from the side. Sable keeps the
	# full width because its sloped roof ties everything together.
	var front_x_w: float = ws_x_w if sable_workshop else ws_x_w * 0.86
	var front_block := MeshInstance3D.new()
	var front_box := BoxMesh.new()
	front_box.size = Vector3(front_x_w, front_h, front_z_len)
	front_block.mesh = front_box
	front_block.position = Vector3(0, front_y_centre, front_z_centre)
	front_block.set_surface_override_material(0, _make_metal(Color(0.28, 0.26, 0.22)))
	add_child(front_block)

	if sable_workshop:
		# Sloped roof slab — fills the gap between the front block's
		# top and the back block's top edge so the side silhouette is
		# a clean trapezoid (vertical back, sloped roof, vertical
		# front) rather than two stacked boxes.
		var slope_front_y: float = front_y_centre + front_h * 0.5
		var slope_back_y: float = back_y_centre + back_h * 0.5
		var slope_front_z: float = front_z_centre - front_z_len * 0.5  # -2.1, the front nose
		var slope_back_z: float = back_z_centre - back_z_len * 0.5     # -0.4, the step
		var slope_dy: float = slope_back_y - slope_front_y
		var slope_dz: float = slope_back_z - slope_front_z
		var slope_len: float = sqrt(slope_dy * slope_dy + slope_dz * slope_dz)
		var slope_angle: float = atan2(slope_dy, slope_dz)
		var slope := MeshInstance3D.new()
		var slope_box := BoxMesh.new()
		slope_box.size = Vector3(ws_x_w, 0.06, slope_len)
		slope.mesh = slope_box
		slope.position = Vector3(
			0,
			(slope_front_y + slope_back_y) * 0.5,
			(slope_front_z + slope_back_z) * 0.5,
		)
		# Tilt around X so +Z (the slab's length axis) follows the
		# front->back climb. atan2(dy, dz) gives the angle directly.
		slope.rotation.x = -slope_angle
		slope.set_surface_override_material(0, _make_metal(Color(0.22, 0.20, 0.26)))
		add_child(slope)

	# Corrugated Wellblech ribs across the BACK block roof only —
	# the new front/slope geometry would clip and hover oddly if we
	# kept ribs across the full original workshop length. Strong
	# horizontal striping read on the back-block top still gives
	# the dorsal hull the v1 industrial / corp panel feel. Anvil
	# uses thicker ribs (industrial sheet metal); Sable uses thin
	# raised seams (corp clean panel).
	var ws_top_y: float = back_y_centre + back_h * 0.5 + 0.04
	var rib_count: int = 4
	var rib_color: Color = Color(0.18, 0.16, 0.14, 1.0)
	if _faction_id() == 1:
		rib_color = Color(0.10, 0.10, 0.16, 1.0)
		rib_count = 6
	for r_i: int in rib_count:
		var rib := MeshInstance3D.new()
		var rb := BoxMesh.new()
		var rib_h: float = 0.07 if _faction_id() == 1 else 0.10
		rb.size = Vector3(ws_x_w * 0.92, rib_h, 0.16)
		rib.mesh = rb
		var t: float = (float(r_i) + 0.5) / float(rib_count)
		var rz: float = back_z_centre - back_z_len * 0.5 * 0.92 + t * back_z_len * 0.92
		rib.position = Vector3(0, ws_top_y + rib_h * 0.5, rz)
		rib.set_surface_override_material(0, _make_metal(rib_color))
		add_child(rib)

	# Rear cargo deck — short flat platform extending PAST the
	# workshop's rear face so the oil drums on top of it actually
	# rest on something. Without this, the drums hover in midair at
	# z=1.95 past the workshop's z=1.30 rear edge.
	var deck := MeshInstance3D.new()
	var deck_box := BoxMesh.new()
	deck_box.size = Vector3(2.4, 0.18, 1.5)
	deck.mesh = deck_box
	deck.position = Vector3(0, ws_top_y + 0.09, 1.95)
	deck.set_surface_override_material(0, _make_metal(Color(0.18, 0.16, 0.14)))
	add_child(deck)

	# Player-color identity strip on the bottom of the workshop (above the
	# chassis). Keeps ownership readable from a top-down camera angle even
	# though the chassis-level color band is replaced with an underglow.
	_team_stripe = MeshInstance3D.new()
	var ws_stripe_box := BoxMesh.new()
	ws_stripe_box.size = Vector3(2.85, 0.12, 3.45)
	_team_stripe.mesh = ws_stripe_box
	_team_stripe.position = Vector3(0.0, 1.0 + CHASSIS_LIFT, -0.4)
	var ws_stripe_mat := StandardMaterial3D.new()
	ws_stripe_mat.albedo_color = team_color
	ws_stripe_mat.emission_enabled = true
	ws_stripe_mat.emission = team_color
	ws_stripe_mat.emission_energy_multiplier = 1.4
	_team_stripe.set_surface_override_material(0, ws_stripe_mat)
	add_child(_team_stripe)

	# Sloped front armor plate — gives the Crawler a clear "front" so the
	# player can read its facing instantly. Triangular silhouette under
	# the workshop pointing in the local -Z direction (which is "forward"
	# per command_move's heading code).
	var nose := MeshInstance3D.new()
	var nose_box := BoxMesh.new()
	nose_box.size = Vector3(2.6, 0.7, 1.0)
	nose.mesh = nose_box
	nose.rotation.x = deg_to_rad(-22.0)
	nose.position = Vector3(0.0, 0.65 + CHASSIS_LIFT, -2.1)
	nose.set_surface_override_material(0, _make_metal(Color(0.22, 0.2, 0.18)))
	add_child(nose)
	# Headlight pair on the nose — emissive amber, brighter than v1
	# so the front reads at any zoom.
	for side: int in 2:
		var hx: float = -0.85 if side == 0 else 0.85
		var headlight := MeshInstance3D.new()
		var hl_sphere := SphereMesh.new()
		hl_sphere.radius = 0.16
		hl_sphere.height = 0.32
		headlight.mesh = hl_sphere
		headlight.position = Vector3(hx, 0.82 + CHASSIS_LIFT, -2.60)
		var hl_mat := StandardMaterial3D.new()
		hl_mat.albedo_color = Color(1.0, 0.78, 0.42)
		hl_mat.emission_enabled = true
		hl_mat.emission = Color(1.0, 0.78, 0.42)
		hl_mat.emission_energy_multiplier = 3.4
		hl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		headlight.set_surface_override_material(0, hl_mat)
		add_child(headlight)
	# Yellow-and-black hazard chevrons painted on the nose top —
	# unmistakable forward indicator from the standard top-down RTS
	# camera. Three V-shaped stripes pointing -Z (forward).
	var chevron_mat := StandardMaterial3D.new()
	chevron_mat.albedo_color = Color(0.95, 0.78, 0.18, 1.0)
	chevron_mat.emission_enabled = true
	chevron_mat.emission = Color(0.95, 0.78, 0.18, 1.0)
	chevron_mat.emission_energy_multiplier = 0.55
	chevron_mat.roughness = 0.6
	for c_i: int in 3:
		# Two short slabs forming a V; each pair is one chevron.
		var z_offset: float = -1.65 - float(c_i) * 0.30
		for slab_side: int in 2:
			var slab := MeshInstance3D.new()
			var sb := BoxMesh.new()
			sb.size = Vector3(0.85, 0.04, 0.16)
			slab.mesh = sb
			var sx2: float = -0.45 if slab_side == 0 else 0.45
			slab.position = Vector3(sx2, 0.92 + CHASSIS_LIFT, z_offset)
			slab.rotation.x = deg_to_rad(-22.0)
			slab.rotation.y = deg_to_rad(28.0 if slab_side == 0 else -28.0)
			slab.set_surface_override_material(0, chevron_mat)
			add_child(slab)
	# Rear exhaust block — short stacks on the back of the chassis,
	# now joined by a pair of red taillights so the rear is just as
	# legible as the front.
	for side: int in 2:
		var ex_x: float = -0.7 if side == 0 else 0.7
		var exhaust := MeshInstance3D.new()
		var ex_box := BoxMesh.new()
		ex_box.size = Vector3(0.32, 0.55, 0.32)
		exhaust.mesh = ex_box
		exhaust.position = Vector3(ex_x, 1.4 + CHASSIS_LIFT, 2.4)
		exhaust.set_surface_override_material(0, _make_metal(Color(0.16, 0.14, 0.12)))
		add_child(exhaust)
	# Red taillights on the rear face, mirror of the headlight pair.
	var tail_mat := StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.95, 0.20, 0.15, 1.0)
	tail_mat.emission_enabled = true
	tail_mat.emission = Color(1.0, 0.25, 0.18, 1.0)
	tail_mat.emission_energy_multiplier = 2.6
	tail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for tail_side: int in 2:
		var tx: float = -1.30 if tail_side == 0 else 1.30
		var tail := MeshInstance3D.new()
		var tail_box := BoxMesh.new()
		tail_box.size = Vector3(0.22, 0.10, 0.06)
		tail.mesh = tail_box
		tail.position = Vector3(tx, 0.95 + CHASSIS_LIFT, 2.55)
		tail.set_surface_override_material(0, tail_mat)
		add_child(tail)

	# Cargo crane / armature on the back top.
	var crane := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(0.16, 1.4, 0.16)
	crane.mesh = cb
	crane.position = Vector3(0, 2.2 + CHASSIS_LIFT, 1.5)
	crane.set_surface_override_material(0, _make_metal(Color(0.22, 0.2, 0.16)))
	add_child(crane)

	var crane_arm := MeshInstance3D.new()
	var ca := BoxMesh.new()
	ca.size = Vector3(0.12, 0.12, 1.6)
	crane_arm.mesh = ca
	crane_arm.position = Vector3(0, 2.85 + CHASSIS_LIFT, 1.0)
	crane_arm.set_surface_override_material(0, _make_metal(Color(0.22, 0.2, 0.16)))
	add_child(crane_arm)

	# Sensor mast — tall thin antenna on the front of the workshop. Adds a
	# vertical silhouette element so the Crawler reads as a "moving
	# fortress" against the flatter Salvage Yard footprint.
	var mast := MeshInstance3D.new()
	var mast_box := BoxMesh.new()
	mast_box.size = Vector3(0.05, 1.2, 0.05)
	mast.mesh = mast_box
	mast.position = Vector3(0.9, 2.7 + CHASSIS_LIFT, -1.1)
	mast.set_surface_override_material(0, _make_metal(Color(0.2, 0.18, 0.15)))
	add_child(mast)
	# Tiny emissive cap on top so the mast catches the eye.
	var mast_tip := MeshInstance3D.new()
	var tip_sphere := SphereMesh.new()
	tip_sphere.radius = 0.05
	tip_sphere.height = 0.1
	mast_tip.mesh = tip_sphere
	mast_tip.position = Vector3(0.9, 3.32 + CHASSIS_LIFT, -1.1)
	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = Color(1.0, 0.55, 0.2)
	tip_mat.emission_enabled = true
	tip_mat.emission = Color(1.0, 0.55, 0.2)
	tip_mat.emission_energy_multiplier = 2.0
	mast_tip.set_surface_override_material(0, tip_mat)
	add_child(mast_tip)

	# Reactor lamp atop the workshop — sits inside a faction-shaped
	# housing so it reads as a real piece of equipment rather than a
	# floating glow orb.
	var sable_now: bool = _faction_id() == 1
	var housing_y: float = 2.3 + CHASSIS_LIFT
	# Faction housing — Anvil gets a riveted square base + hooded
	# cap (industrial floodlight); Sable gets a hex-prism cradle
	# (corp lantern). The lamp itself sits inside.
	if sable_now:
		var hex := MeshInstance3D.new()
		var hex_cyl := CylinderMesh.new()
		hex_cyl.top_radius = 0.32
		hex_cyl.bottom_radius = 0.30
		hex_cyl.height = 0.34
		hex_cyl.radial_segments = 6
		hex.mesh = hex_cyl
		hex.position = Vector3(0, housing_y, -0.4)
		hex.set_surface_override_material(0, _make_metal(Color(0.10, 0.10, 0.14)))
		add_child(hex)
		# Slim cap on top of the hex — pinches the silhouette and
		# breaks the cylinder profile at the top.
		var hex_cap := MeshInstance3D.new()
		var hcap_cyl := CylinderMesh.new()
		hcap_cyl.top_radius = 0.18
		hcap_cyl.bottom_radius = 0.30
		hcap_cyl.height = 0.10
		hcap_cyl.radial_segments = 6
		hex_cap.mesh = hcap_cyl
		hex_cap.position = Vector3(0, housing_y + 0.22, -0.4)
		hex_cap.set_surface_override_material(0, _make_metal(Color(0.06, 0.06, 0.10)))
		add_child(hex_cap)
	else:
		# Anvil — square steel base + hooded cap. Reads as a flood
		# lamp bolted to the deck.
		var base := MeshInstance3D.new()
		var base_box := BoxMesh.new()
		base_box.size = Vector3(0.46, 0.20, 0.46)
		base.mesh = base_box
		base.position = Vector3(0, housing_y - 0.12, -0.4)
		base.set_surface_override_material(0, _make_metal(Color(0.20, 0.18, 0.16)))
		add_child(base)
		# Four small rivets at the base corners.
		var rivet_mat: StandardMaterial3D = _make_metal(Color(0.42, 0.36, 0.22))
		for rx_i: int in 2:
			for rz_i: int in 2:
				var rivet := MeshInstance3D.new()
				var rsp := SphereMesh.new()
				rsp.radius = 0.04
				rsp.height = 0.08
				rsp.radial_segments = 6
				rsp.rings = 3
				rivet.mesh = rsp
				var rxp: float = -0.18 if rx_i == 0 else 0.18
				var rzp: float = -0.4 - 0.18 if rz_i == 0 else -0.4 + 0.18
				rivet.position = Vector3(rxp, housing_y - 0.06, rzp)
				rivet.set_surface_override_material(0, rivet_mat)
				add_child(rivet)
		# Hooded cap above the lamp — angled tin shade.
		var hood := MeshInstance3D.new()
		var hood_box := BoxMesh.new()
		hood_box.size = Vector3(0.50, 0.06, 0.50)
		hood.mesh = hood_box
		hood.position = Vector3(0, housing_y + 0.22, -0.4)
		hood.rotation.x = deg_to_rad(-12.0)
		hood.set_surface_override_material(0, _make_metal(Color(0.16, 0.14, 0.12)))
		add_child(hood)

	var lamp := MeshInstance3D.new()
	var lamp_sphere := SphereMesh.new()
	lamp_sphere.radius = 0.16
	lamp_sphere.height = 0.32
	lamp.mesh = lamp_sphere
	lamp.position = Vector3(0, housing_y, -0.4)
	var lamp_color: Color = Color(0.78, 0.35, 1.0) if sable_now else Color(0.3, 0.85, 1.0)
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = lamp_color
	lamp_mat.emission_enabled = true
	lamp_mat.emission = lamp_color
	lamp_mat.emission_energy_multiplier = 2.4
	lamp.set_surface_override_material(0, lamp_mat)
	add_child(lamp)
	# Real cyan light so the reactor reads at a glance even at low res.
	var lamp_light := OmniLight3D.new()
	lamp_light.light_color = Color(0.4, 0.85, 1.0)
	lamp_light.light_energy = 1.4
	# Forge-amber working pool — wider and warmer than the Salvage Yard's
	# work lamp so the Crawler reads as the larger economic centerpiece
	# per READABILITY_PASS.md §Task 5.
	var work_pool := OmniLight3D.new()
	work_pool.light_color = Color(1.0, 0.55, 0.2)
	work_pool.light_energy = 1.2
	work_pool.omni_range = 9.0
	work_pool.omni_attenuation = 1.4
	work_pool.position = Vector3(0.0, 1.4 + CHASSIS_LIFT, -0.4)
	add_child(work_pool)
	lamp_light.omni_range = 6.0
	lamp_light.position = lamp.position
	add_child(lamp_light)

	# Underchassis glow — an OmniLight3D mounted *under* the hull casts
	# the player's color onto the ground beneath the Crawler. Replaces
	# the previous solid strip on the chassis bottom; the stripe at the
	# workshop base (above) handles the painted-band identity, while
	# this casts the moving glow that follows the Crawler around.
	var underglow := OmniLight3D.new()
	underglow.light_color = team_color
	underglow.light_energy = 1.6
	underglow.omni_range = 4.5
	underglow.omni_attenuation = 1.4
	underglow.position = Vector3(0.0, 0.05, 0.0)
	add_child(underglow)

	# Extra detail: side rivets + visible road wheels through the
	# tread cutouts + oil-drum cargo strapped to the rear deck. Reads
	# as a properly built mobile factory instead of a stack of boxes.
	var rivet_mat := _make_metal(Color(0.42, 0.36, 0.20))
	for side: int in 2:
		var sx: float = -1.81 if side == 0 else 1.81
		# Five road wheels per side, peeking out from under the tread.
		for w_i: int in 5:
			var wheel := MeshInstance3D.new()
			var wcyl := CylinderMesh.new()
			wcyl.top_radius = 0.30
			wcyl.bottom_radius = 0.30
			wcyl.height = 0.20
			wcyl.radial_segments = 12
			wheel.mesh = wcyl
			wheel.rotation.z = PI * 0.5
			wheel.position = Vector3(sx, 0.30, -2.05 + float(w_i) * 1.05)
			wheel.set_surface_override_material(0, _make_metal(Color(0.10, 0.10, 0.10)))
			add_child(wheel)
		# Hull rivets — six small bumps along the side of the chassis.
		for r_i: int in 6:
			var rivet := MeshInstance3D.new()
			var rsp := SphereMesh.new()
			rsp.radius = 0.05
			rsp.height = 0.10
			rsp.radial_segments = 6
			rsp.rings = 3
			rivet.mesh = rsp
			rivet.position = Vector3(sx * 0.92, 0.85 + CHASSIS_LIFT, -2.10 + float(r_i) * 0.82)
			rivet.set_surface_override_material(0, rivet_mat)
			add_child(rivet)

	# Two tall fuel tanks strapped to the rear of the chassis — the
	# bottoms come down to sit flush against the chassis hull (Y=1.25,
	# the top of the main hull box at hull_y + half_hull_h) instead
	# of perching on the small rear deck. Reads as proper bolted-on
	# fuel cargo with weight, not as floating drums.
	var drum_mat := _make_metal(Color(0.55, 0.30, 0.18))
	var drum_top_y: float = 2.70 + CHASSIS_LIFT + 0.85 * 0.5  # original top
	var drum_bottom_y: float = 0.55 + CHASSIS_LIFT + 0.5      # hull top
	var drum_height: float = drum_top_y - drum_bottom_y
	var drum_centre_y: float = (drum_top_y + drum_bottom_y) * 0.5
	for drum_i: int in 2:
		var drum := MeshInstance3D.new()
		var dc := CylinderMesh.new()
		dc.top_radius = 0.30
		dc.bottom_radius = 0.30
		dc.height = drum_height
		dc.radial_segments = 16
		drum.mesh = dc
		var dx: float = -0.55 if drum_i == 0 else 0.55
		drum.position = Vector3(dx, drum_centre_y, 1.95)
		drum.set_surface_override_material(0, drum_mat)
		add_child(drum)

	# Faction-aware silhouette overlay — Anvil keeps the warm
	# headlight + cyan reactor lamp baked above. Sable layers a
	# slate-violet upper plate, swaps to a violet visor strip, and
	# replaces the cyan beacon with a violet pulse-cap.
	if _faction_id() == 1:
		_apply_sable_crawler_overlay()


func _build_tread_segment(sx: float, z_center: float, length: float, tilt_x_deg: float = 0.0) -> void:
	## A single visible tread segment: the dark slab + a row of small
	## "track plate" ribs across its top + a thin upper-rail strip.
	## Used twice per side for Sable (front/rear bogie pairs) and
	## once per side for Anvil (single long tread). `tilt_x_deg`
	## angles the bogie around X (Sable's bogies tilt at the ends
	## so the chassis sits visibly higher off the ground).
	## Plates are recorded in `_track_plates` so `_process` can
	## scroll them along the segment when the crawler is moving.
	# Segment Y is bumped up slightly so the tread block protrudes
	# clearly below the chassis silhouette instead of sharing the
	# ground plane with it. Tilted bogies get an additional lift to
	# keep their lowest point above ground.
	var seg_y: float = 0.45
	if tilt_x_deg != 0.0:
		seg_y = 0.55
	var seg_root := Node3D.new()
	seg_root.position = Vector3(sx, seg_y, z_center)
	if tilt_x_deg != 0.0:
		seg_root.rotation.x = deg_to_rad(tilt_x_deg)
	add_child(seg_root)

	var tread := MeshInstance3D.new()
	var tb := BoxMesh.new()
	tb.size = Vector3(0.50, 0.70, length)
	tread.mesh = tb
	tread.set_surface_override_material(0, _make_metal(Color(0.18, 0.16, 0.14)))
	seg_root.add_child(tread)
	# Track plates — one slim raised rib every ~0.4u along the top.
	# Reads as actual moving track segments rather than a slab.
	# Plates live in segment-local space so the scroll wrap is a
	# simple `+= delta` on the local Z.
	var plate_count: int = maxi(int(length / 0.40), 4)
	var plate_mat := _make_metal(Color(0.10, 0.10, 0.10))
	for p_i: int in plate_count:
		var t: float = (float(p_i) + 0.5) / float(plate_count)
		var local_z: float = -length * 0.5 + t * length
		var plate := MeshInstance3D.new()
		var plate_box := BoxMesh.new()
		plate_box.size = Vector3(0.56, 0.10, 0.18)
		plate.mesh = plate_box
		plate.position = Vector3(0.0, 0.38, local_z)
		plate.set_surface_override_material(0, plate_mat)
		seg_root.add_child(plate)
		_track_plates.append({
			"node": plate,
			"length": length,
		})
	# Upper rail strip — thin strip running the length of the tread
	# along its outer top edge. Adds an extra silhouette line.
	var rail := MeshInstance3D.new()
	var rail_box := BoxMesh.new()
	rail_box.size = Vector3(0.10, 0.06, length * 0.96)
	rail.mesh = rail_box
	rail.position = Vector3(0.20 if sx > 0.0 else -0.20, 0.38, 0.0)
	rail.set_surface_override_material(0, _make_metal(Color(0.32, 0.28, 0.22)))
	seg_root.add_child(rail)


## --- Faction lookup (unit-style) ---------------------------------------

func _faction_id() -> int:
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if not settings:
		return 0
	if owner_id == 0:
		return settings.get("player_faction") as int
	return settings.get("enemy_faction") as int


func _apply_sable_crawler_overlay() -> void:
	const SABLE_VIOLET := Color(0.78, 0.35, 1.0, 1.0)
	# Slate-violet upper hull plate sitting on top of the workshop —
	# the new dominant top surface.
	var plate := MeshInstance3D.new()
	var plate_box := BoxMesh.new()
	plate_box.size = Vector3(2.95, 0.10, 3.55)
	plate.mesh = plate_box
	plate.position = Vector3(0, 2.10 + CHASSIS_LIFT, -0.4)
	plate.set_surface_override_material(0, _make_metal(Color(0.12, 0.10, 0.16)))
	add_child(plate)
	# Violet visor across the front of the workshop — replaces the
	# warm-amber headlight read with a horizontal sensor slit.
	var visor_mat := StandardMaterial3D.new()
	visor_mat.albedo_color = SABLE_VIOLET
	visor_mat.emission_enabled = true
	visor_mat.emission = SABLE_VIOLET
	visor_mat.emission_energy_multiplier = 2.4
	visor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var visor := MeshInstance3D.new()
	var visor_box := BoxMesh.new()
	visor_box.size = Vector3(2.6, 0.12, 0.08)
	visor.mesh = visor_box
	visor.position = Vector3(0, 1.75 + CHASSIS_LIFT, -2.05)
	visor.set_surface_override_material(0, visor_mat)
	add_child(visor)
	# Just a violet beacon LIGHT — the visible reactor sphere lives
	# in _build_visuals' faction-aware housing block (added before
	# the overlay), so the orb itself isn't doubled here.
	var beacon_light := OmniLight3D.new()
	beacon_light.light_color = SABLE_VIOLET
	beacon_light.light_energy = 1.4
	beacon_light.omni_range = 5.5
	beacon_light.position = Vector3(0, 2.30 + CHASSIS_LIFT, -0.4)
	add_child(beacon_light)
	# Side seam strips along the chassis sides, echoing Sable's
	# emissive seam treatment on mechs and buildings.
	for side: int in 2:
		var sx: float = -1.85 if side == 0 else 1.85
		var seam := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.06, 0.08, 4.2)
		seam.mesh = sb
		seam.position = Vector3(sx, 1.05 + CHASSIS_LIFT, 0.0)
		seam.set_surface_override_material(0, visor_mat)
		add_child(seam)


func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.8, 1.6, 5.2)
	col.shape = shape
	col.position.y = 0.8
	add_child(col)


func _build_hp_bar() -> void:
	_hp_bar = Node3D.new()
	_hp_bar.name = "HPBar"
	_hp_bar.position.y = 3.4
	# Background -- bumped from 2.8u to 4.4u so the bar matches the
	# Crawler's wider chassis. Standard mech HP bars are 2u over a
	# ~2u-wide torso; the Crawler's harvester body is closer to 4u
	# wide so the previous 2.8u bar read as 'shorter than other unit
	# bars' relative to the body it sat above.
	_hp_bar_bg = MeshInstance3D.new()
	var bg_box := BoxMesh.new()
	bg_box.size = Vector3(4.4, 0.18, 0.10)
	_hp_bar_bg.mesh = bg_box
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.7)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hp_bar_bg.set_surface_override_material(0, bg_mat)
	_hp_bar.add_child(_hp_bar_bg)

	# Fill -- native width matches the background so scale.x just
	# expresses the HP percentage (0..1). Earlier the fill was 1.0u
	# native and we scaled by pct * 4.4, but at full HP the displayed
	# size could come out half of the background due to the pivot
	# offset; keeping the native widths in sync sidesteps that.
	_hp_bar_fill = MeshInstance3D.new()
	var fill_box := BoxMesh.new()
	fill_box.size = Vector3(4.4, 0.22, 0.12)
	_hp_bar_fill.mesh = fill_box
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.3, 0.95, 0.4, 0.9)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill_mat.emission_enabled = true
	fill_mat.emission = Color(0.2, 0.9, 0.3)
	fill_mat.emission_energy_multiplier = 0.5
	_hp_bar_fill.set_surface_override_material(0, fill_mat)
	_hp_bar.add_child(_hp_bar_fill)

	add_child(_hp_bar)
	_hp_bar.top_level = true


func _make_metal(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	# Subtle grime / wear overlay so the chassis reads as weathered
	# industrial metal instead of flat colour. uv1_offset randomised so
	# adjacent panels each pick a different patch of grime.
	m.albedo_texture = SharedTextures.get_metal_wear_texture()
	m.uv1_offset = Vector3(randf(), randf(), 0.0)
	m.uv1_scale = Vector3(1.8, 1.8, 1.0)
	m.roughness = 0.65
	m.metallic = 0.4
	return m


## --- Movement ---

func command_move(target: Vector3, _clear_combat: bool = true) -> void:
	# Anchored / deploying Crawlers can't move — the player has to undeploy
	# first. We just no-op the command so the existing UI flow is harmless.
	if anchor_state == AnchorState.ANCHORED or anchor_state == AnchorState.DEPLOYING:
		return
	move_queue.clear()
	move_target = Vector3(target.x, global_position.y, target.z)
	has_move_order = true
	_stuck_timer = 0.0
	if _nav_agent:
		_nav_agent.target_position = move_target


func queue_move(target: Vector3) -> void:
	if anchor_state == AnchorState.ANCHORED or anchor_state == AnchorState.DEPLOYING:
		return
	var fixed: Vector3 = Vector3(target.x, global_position.y, target.z)
	if move_target == Vector3.INF:
		command_move(fixed)
		return
	move_queue.append(fixed)


func stop() -> void:
	move_target = Vector3.INF
	move_queue.clear()
	velocity = Vector3.ZERO
	has_move_order = false


func _process(delta: float) -> void:
	# Scroll the track plates along their segment when the crawler
	# is moving. Each plate slides a constant distance per frame
	# proportional to ground speed; once a plate falls off the rear
	# end of its segment it wraps back to the front. Cheap (single
	# float per plate) and reads as a continuously moving track.
	var speed_xz: float = Vector2(velocity.x, velocity.z).length()
	if speed_xz > 0.05 and not _track_plates.is_empty():
		# Treads run faster than the chassis to look like the track
		# is shedding material at the rear and feeding new at the
		# front. Multiplier ~1.5 sells the read.
		var scroll: float = speed_xz * delta * 1.5
		for plate_data: Dictionary in _track_plates:
			var node: Node3D = plate_data["node"] as Node3D
			if not is_instance_valid(node):
				continue
			var seg_len: float = plate_data["length"] as float
			node.position.z += scroll
			if node.position.z > seg_len * 0.5:
				node.position.z -= seg_len


func _physics_process(delta: float) -> void:
	# Update HP bar position / visibility.
	if _hp_bar and is_instance_valid(_hp_bar):
		var damaged: bool = false
		if stats:
			damaged = current_hp < stats.hp_total
		_hp_bar.visible = is_selected or damaged or hp_bar_hovered
		if _hp_bar.visible:
			_hp_bar.global_position = global_position + Vector3(0, 3.4, 0)
			var cam: Camera3D = get_viewport().get_camera_3d()
			if cam:
				_hp_bar.global_rotation = cam.global_rotation
			_update_hp_bar_fill()

	# Anchor Mode state machine — tick deploy/undeploy timers.
	_tick_anchor_state(delta)

	# Wreck crushing — periodic XZ-distance scan against the wrecks group.
	# Disabled while fully anchored (Crawler isn't moving anyway, so any
	# overlap with a wreck was resolved at deploy time).
	_crush_timer -= delta
	if _crush_timer <= 0.0:
		_crush_timer = CRUSH_CHECK_INTERVAL
		if anchor_state != AnchorState.ANCHORED:
			_check_wreck_crush()

	# Relocation drop — when we've moved far enough since our last drop
	# anchor, force any carrying workers to deposit where they stand.
	if _last_relocation_anchor == Vector3.INF:
		_last_relocation_anchor = global_position
	elif global_position.distance_to(_last_relocation_anchor) >= RELOCATION_DROP_DISTANCE:
		_drop_carried_salvage_on_relocation()
		_last_relocation_anchor = global_position

	if move_target == Vector3.INF:
		return

	if _nav_agent and _nav_agent.is_navigation_finished():
		if not move_queue.is_empty():
			var next_wp: Vector3 = move_queue.pop_front() as Vector3
			move_target = Vector3(next_wp.x, global_position.y, next_wp.z)
			_stuck_timer = 0.0
			_nav_agent.target_position = move_target
			return
		stop()
		return

	var next_pos: Vector3 = move_target
	if _nav_agent:
		next_pos = _nav_agent.get_next_path_position()

	var to_next := next_pos - global_position
	to_next.y = 0.0
	var dist: float = to_next.length()
	if dist < ARRIVE_THRESHOLD:
		if not _nav_agent or _nav_agent.is_navigation_finished():
			if not move_queue.is_empty():
				var next_wp: Vector3 = move_queue.pop_front() as Vector3
				move_target = Vector3(next_wp.x, global_position.y, next_wp.z)
				_stuck_timer = 0.0
				if _nav_agent:
					_nav_agent.target_position = move_target
				return
			stop()
			return

	var direction: Vector3 = to_next / maxf(dist, 0.001)
	velocity = direction * _move_speed
	var prev_pos: Vector3 = global_position
	move_and_slide()

	# Stuck rescue — same thresholds as Unit so the Crawler doesn't sit
	# wedged against a wreck or a chokepoint forever.
	var actual_move: float = (global_position - prev_pos).length()
	var expected_move: float = _move_speed * delta * 0.3
	if actual_move < expected_move:
		_stuck_timer += delta
		if _stuck_timer >= 1.5 and _stuck_timer < 1.5 + delta * 1.5:
			if _nav_agent:
				_nav_agent.target_position = move_target
		elif _stuck_timer > 5.0:
			stop()
			return
	else:
		_stuck_timer = 0.0

	# Face direction of travel.
	var face_dir: Vector3 = velocity.normalized()
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.001:
		var target_y: float = atan2(face_dir.x, face_dir.z) + PI
		rotation.y = lerp_angle(rotation.y, target_y, clampf(2.0 * delta, 0.0, 1.0))


func _update_hp_bar_fill() -> void:
	if not _hp_bar_fill or not stats:
		return
	var pct: float = float(current_hp) / float(maxi(stats.hp_total, 1))
	var bar_width: float = 4.4
	# Fill mesh is now native 4.4u wide -- scale.x is the HP fraction
	# directly, and the position offset shifts the pivot so the fill
	# anchors on the LEFT edge of the background rather than centering
	# (so the missing chunk reads as "right-side empty", not
	# "centered shrink").
	_hp_bar_fill.scale.x = maxf(pct, 0.01)
	_hp_bar_fill.position.x = -bar_width * 0.5 * (1.0 - pct)
	var fmat: StandardMaterial3D = _hp_bar_fill.get_surface_override_material(0) as StandardMaterial3D
	if fmat:
		var r: float = 1.0 - pct
		var g: float = pct
		fmat.albedo_color = Color(r, g, 0.1, 0.9)
		fmat.emission = Color(r, g, 0.1, 1.0)


## --- Combat compatibility ---

func take_damage(amount: int, _attacker: Node3D = null) -> void:
	# Anchored Crawler benefits from +50% armor: incoming damage halved.
	# Deploying / undeploying don't get the bonus — vulnerable in transition.
	if anchor_state == AnchorState.ANCHORED:
		amount = maxi(int(round(float(amount) * (1.0 - ANCHOR_ARMOR_BONUS))), 1)
	current_hp -= amount
	if current_hp <= 0:
		current_hp = 0
		alive_count = 0
		_die()


func get_total_hp() -> int:
	return maxi(current_hp, 0)


func is_damaged() -> bool:
	## Used by Ratchet auto-repair (BuilderComponent._find_repair_target).
	## Crawlers want repair the same as buildings or mech squads.
	return alive_count > 0 and stats != null and current_hp < stats.hp_total


## Diminishing-returns bookkeeping for stacked repairs.
var _healers_this_tick: Dictionary = {}
var _last_heal_tick_msec: int = 0
const _HEAL_TICK_MS: int = 250


func heal(amount: float, healer: Node = null) -> void:
	if alive_count <= 0 or not stats:
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_heal_tick_msec >= _HEAL_TICK_MS:
		_healers_this_tick.clear()
		_last_heal_tick_msec = now_ms
	if healer:
		var hid: int = healer.get_instance_id()
		if not _healers_this_tick.has(hid):
			var idx: int = _healers_this_tick.size()
			var factor: float = maxf(1.0 - float(idx) * 0.1, 0.1)
			amount *= factor
			_healers_this_tick[hid] = factor
		else:
			amount *= (_healers_this_tick[hid] as float)
	if current_hp >= stats.hp_total:
		return
	current_hp = mini(stats.hp_total, current_hp + int(ceil(amount)))


func _die() -> void:
	squad_destroyed.emit()
	if _hp_bar and is_instance_valid(_hp_bar):
		_hp_bar.queue_free()
	# Spawn a small wreck representing the chassis.
	var wreck_script: GDScript = load("res://scripts/wreck.gd") as GDScript
	if wreck_script and stats:
		var wreck: Node3D = wreck_script.create_from_unit(stats, global_position) as Node3D
		if wreck:
			get_tree().current_scene.add_child(wreck)
	queue_free()


## --- Selection (called by SelectionManager) ---

func select() -> void:
	is_selected = true


func deselect() -> void:
	is_selected = false


## --- Helpers used by SelectionManager and combat compatibility ---

func get_combat() -> Node:
	return null  # Crawlers don't fight.


func get_builder() -> Node:
	return null  # Crawlers aren't engineers.


## --- Anchor Mode (v3.3 §3.1) ---

func can_toggle_anchor() -> bool:
	## Anchor is researched at the Basic Armory. The HUD checks this flag
	## before drawing the Anchor / Undeploy button.
	var rm: Node = get_tree().current_scene.get_node_or_null("ResearchManager")
	if rm and rm.has_method("is_researched"):
		return rm.is_researched(&"anchor_mode")
	return false


func toggle_anchor() -> void:
	## OFF → DEPLOYING → ANCHORED, or ANCHORED → UNDEPLOYING → OFF.
	## Deploy/undeploy phases are vulnerable per v3.3 §3.1.
	if not can_toggle_anchor():
		return
	match anchor_state:
		AnchorState.OFF:
			# Cannot deploy while moving — stop first.
			stop()
			anchor_state = AnchorState.DEPLOYING
			_anchor_progress = 0.0
			_set_anchor_visual(0.0)
		AnchorState.ANCHORED:
			anchor_state = AnchorState.UNDEPLOYING
			_anchor_progress = 0.0
		AnchorState.DEPLOYING, AnchorState.UNDEPLOYING:
			# Mid-animation toggle just reverses direction.
			anchor_state = AnchorState.OFF if anchor_state == AnchorState.DEPLOYING else AnchorState.ANCHORED


func _tick_anchor_state(delta: float) -> void:
	match anchor_state:
		AnchorState.DEPLOYING:
			_anchor_progress += delta
			_set_anchor_visual(clampf(_anchor_progress / ANCHOR_DEPLOY_TIME, 0.0, 1.0))
			if _anchor_progress >= ANCHOR_DEPLOY_TIME:
				anchor_state = AnchorState.ANCHORED
				_apply_anchor_bonuses()
		AnchorState.UNDEPLOYING:
			_anchor_progress += delta
			_set_anchor_visual(1.0 - clampf(_anchor_progress / ANCHOR_DEPLOY_TIME, 0.0, 1.0))
			if _anchor_progress >= ANCHOR_DEPLOY_TIME:
				anchor_state = AnchorState.OFF
				_remove_anchor_bonuses()


func is_anchored() -> bool:
	return anchor_state == AnchorState.ANCHORED


func _apply_anchor_bonuses() -> void:
	if _yard_component:
		# +25% workers and +25% range. Workers come in integer slots so we
		# round up; range is just a float scale.
		var bonus_workers: int = int(ceil(float(_BASE_MAX_WORKERS) * (1.0 + ANCHOR_WORKER_BONUS)))
		_yard_component.set("max_workers", bonus_workers)
		_yard_component.set("harvest_radius", _BASE_HARVEST_RADIUS * (1.0 + ANCHOR_RANGE_BONUS))


func _remove_anchor_bonuses() -> void:
	if _yard_component:
		_yard_component.set("max_workers", _BASE_MAX_WORKERS)
		_yard_component.set("harvest_radius", _BASE_HARVEST_RADIUS)


func _ensure_anchor_plating() -> void:
	if _anchor_plating and is_instance_valid(_anchor_plating):
		return
	_anchor_plating = Node3D.new()
	_anchor_plating.name = "AnchorPlating"
	add_child(_anchor_plating)

	# Side armor skirts that drop down + outboard support struts. Hidden
	# at scale 0; we lerp scale to 1 during DEPLOYING.
	var skirt_color: Color = Color(0.22, 0.2, 0.18)
	for side: int in 2:
		var sx: float = -2.05 if side == 0 else 2.05
		var skirt := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.12, 0.55, 5.4)
		skirt.mesh = sb
		skirt.position = Vector3(sx, 0.3, 0)
		skirt.set_surface_override_material(0, _make_metal(skirt_color))
		_anchor_plating.add_child(skirt)
		# Forward and aft support struts angled out from the chassis.
		for fore: int in 2:
			var sz: float = -2.4 if fore == 0 else 2.4
			var strut := MeshInstance3D.new()
			var stb := BoxMesh.new()
			stb.size = Vector3(0.18, 0.12, 0.9)
			strut.mesh = stb
			strut.position = Vector3(sx + (0.5 if side == 1 else -0.5), 0.05, sz)
			strut.rotation.z = -0.6 if side == 1 else 0.6
			strut.set_surface_override_material(0, _make_metal(Color(0.18, 0.16, 0.14)))
			_anchor_plating.add_child(strut)
	# Roof reinforcement plate.
	var roof := MeshInstance3D.new()
	var rb := BoxMesh.new()
	rb.size = Vector3(2.4, 0.18, 3.2)
	roof.mesh = rb
	roof.position = Vector3(0, 2.15, -0.4)
	roof.set_surface_override_material(0, _make_metal(Color(0.34, 0.32, 0.28)))
	_anchor_plating.add_child(roof)
	_anchor_plating.scale = Vector3(0.001, 0.001, 0.001)


func _set_anchor_visual(t: float) -> void:
	## t in [0..1]: 0 = retracted, 1 = fully deployed.
	_ensure_anchor_plating()
	var s: float = lerp(0.001, 1.0, clampf(t, 0.0, 1.0))
	_anchor_plating.scale = Vector3(s, s, s)


## --- Movement override: anchored Crawlers cannot move ---

func command_move_anchored_check(target: Vector3, clear_combat: bool = true) -> void:
	if anchor_state == AnchorState.ANCHORED or anchor_state == AnchorState.DEPLOYING:
		return  # Locked down.
	command_move(target, clear_combat)


## --- Wreck crushing (v3.3 §1.3) ---

func _check_wreck_crush() -> void:
	if not resource_manager:
		return
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		var wreck: Wreck = node as Wreck
		if not wreck:
			continue
		var dx: float = absf(wreck.global_position.x - global_position.x)
		var dz: float = absf(wreck.global_position.z - global_position.z)
		# Cheap XZ rectangle check matching the Crawler's hull.
		if dx > CRUSH_RADIUS or dz > CRUSH_RADIUS:
			continue
		var max_extent: float = maxf(wreck.wreck_size.x, wreck.wreck_size.z)
		if max_extent > CRUSH_MAX_WRECK_SIZE:
			# Heavy / Apex wreck — too big to crush. The Wreck's StaticBody3D
			# already physically blocks the Crawler from rolling through.
			continue
		_crush_wreck(wreck)


func _crush_wreck(wreck: Wreck) -> void:
	## Absorb a fraction of the wreck's remaining salvage and free it. Spawns
	## a small dust burst as feedback.
	var absorbed: int = int(round(float(wreck.salvage_remaining) * CRUSH_SALVAGE_FRAC))
	if absorbed > 0 and resource_manager and resource_manager.has_method("add_salvage"):
		resource_manager.add_salvage(absorbed)
	_spawn_crush_burst(wreck.global_position, absorbed)
	wreck.queue_free()


func _spawn_crush_burst(world_pos: Vector3, salvage_gained: int) -> void:
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	# Dust puff cluster → GPU particle burst. 6 emit_particle calls
	# instead of 6 fresh MeshInstance3D + StandardMaterial3D + Tween.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if pem:
		pem.emit_dust(world_pos + Vector3(0, 0.2, 0), 6, 1.2)
	# Floating "+N" salvage popup so the player sees the bonus.
	if salvage_gained <= 0:
		return
	var label := Label3D.new()
	label.text = "+%d" % salvage_gained
	label.font_size = 42
	label.pixel_size = 0.018
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(1.00, 0.55, 0.18, 1.0)  # salvage orange
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0, 1)
	var label_pos: Vector3 = world_pos + Vector3(0, 1.2, 0)
	scene.add_child(label)
	label.global_position = label_pos
	var ltween := label.create_tween()
	ltween.set_parallel(true)
	ltween.tween_property(label, "global_position", label_pos + Vector3(0, 1.2, 0), 0.8)
	ltween.tween_property(label, "modulate:a", 0.0, 0.8).set_ease(Tween.EASE_IN)
	ltween.chain().tween_callback(label.queue_free)


## --- Mid-trip salvage drop on relocation (v3.3 §1.3) ---

func _drop_carried_salvage_on_relocation() -> void:
	if not _yard_component:
		return
	var workers: Array = _yard_component.get("_workers") as Array
	if not workers:
		return
	var scene: Node = get_tree().current_scene
	for w: Node in workers:
		if not is_instance_valid(w):
			continue
		if not w.has_method("drop_carried_salvage"):
			continue
		var amt: int = w.drop_carried_salvage() as int
		if amt <= 0 or not scene:
			continue
		# Spawn a small recoverable wreck cache where the worker stood. Any
		# worker can later harvest it normally.
		var cache := Wreck.new()
		cache.salvage_value = amt
		cache.salvage_remaining = amt
		cache.wreck_size = Vector3(0.6, 0.3, 0.6)
		cache.position = (w as Node3D).global_position
		scene.add_child(cache)


func _speed_from_tier(tier: StringName) -> float:
	match tier:
		&"static": return 0.0
		&"very_slow": return 3.0
		&"slow": return 5.0
		&"moderate": return 8.0
		&"fast": return 12.0
		&"very_fast": return 16.0
	return 5.0
