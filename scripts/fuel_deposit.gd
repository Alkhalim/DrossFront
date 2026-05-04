class_name FuelDeposit
extends Node3D
## A capturable fuel deposit on the map. Generates passive fuel income for the owner.

signal captured(new_owner: int)
signal contested

## Fuel generated per second when captured. Halved from the previous
## 5.0 so a captured deposit takes twice as long to bankroll a heavy
## mech — the player has to actually defend the fuel income now,
## not just plant the flag and walk off. Income is paid in batched
## chunks every FUEL_PAYOUT_INTERVAL_SEC so the floating "+N F"
## readout doesn't strobe.
@export var fuel_per_second: float = 2.5

## Seconds between fuel payout chunks. ~10s feels like a tide
## rather than a stream — visible income event without spam.
const FUEL_PAYOUT_INTERVAL_SEC: float = 10.0

## Radius in which units can capture or contest.
@export var capture_radius: float = 12.0

## Time in seconds to capture from neutral. 25% faster than the
## v1 baseline (30s -> 22.5s) so the early game doesn't drag while
## both sides slow-walk to neutral fields.
@export var capture_time: float = 22.5

## Current owner: -1 = neutral, 0 = player, 1+ = AI
var owner_id: int = -1

## Capture state
var _capture_progress: float = 0.0
var _capturing_owner: int = -1
var _is_contested: bool = false

## Fuel income accumulator
var _fuel_accumulator: float = 0.0

## Visuals
var _mesh: Node3D = null  # Container for the pumpjack rig + barrels + pad.
var _pump_walker: Node3D = null  # Pivot for the pumpjack walking beam — animated.
var _pump_anim_t: float = 0.0
var _range_indicator: MeshInstance3D = null
var _range_mat_cached: StandardMaterial3D = null
var _range_ring: MeshInstance3D = null
var _range_ring_mat: StandardMaterial3D = null
var _range_color_cached: Color = Color(0, 0, 0, 0)
var _capture_bar_bg: MeshInstance3D = null
var _capture_bar_fill: MeshInstance3D = null
var _capture_label: Label3D = null
var _owner_indicator: MeshInstance3D = null

const NEUTRAL_COLOR := Color(0.6, 0.5, 0.3, 1.0)
const PLAYER_COLOR := Color(0.08, 0.25, 0.85, 1.0)
const ENEMY_COLOR := Color(0.80, 0.10, 0.10, 1.0)
const CONTESTED_COLOR := Color(0.9, 0.7, 0.1, 1.0)


func _ready() -> void:
	add_to_group("fuel_deposits")
	_create_visuals()


var _capture_throttle: float = 0.0
const CAPTURE_INTERVAL: float = 0.1  # ~10 Hz; capture progress is multi-second

func _detail_metal_dark() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.16, 0.14, 0.12, 1.0)
	m.metallic = 0.5
	m.roughness = 0.55
	return m


func _process(delta: float) -> void:
	# Pump-jack walking beam animation — slow rocking. Cheap (single
	# rotation update per deposit per frame).
	if _pump_walker:
		_pump_anim_t += delta
		_pump_walker.rotation.x = sin(_pump_anim_t * 1.6) * 0.18
	# `_update_capture` iterates the whole units group every call —
	# at 360 units × N deposits per frame that's the dominant deposit
	# cost. Throttle to 10 Hz; capture progress is on the order of
	# tens of seconds so the player can't tell the difference.
	_capture_throttle += delta
	if _capture_throttle >= CAPTURE_INTERVAL:
		_update_capture(_capture_throttle)
		_capture_throttle = 0.0
	_generate_fuel(delta)
	_update_visuals()


func _update_capture(delta: float) -> void:
	# Count units of each owner inside the radius. Neutrals (owner_id 2)
	# CAN block the capture — if a wandering neutral patrol is in
	# radius it counts toward "contested" so progress halts — but
	# they cannot claim the deposit themselves; neutral never goes
	# below into the capture-progress branch.
	var owner_counts: Dictionary = {}
	var has_neutral: bool = false
	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not is_instance_valid(node):
			continue
		if not ("alive_count" in node) or node.get("alive_count") <= 0:
			continue
		# Gatherers (salvage crawlers + engineers) can't claim oil
		# fields -- the player has to bring military to the deposit.
		# Stops the early game where a lone Crawler dropping by a
		# contested deposit would silently flip ownership.
		if node.is_in_group("crawlers"):
			continue
		var node_stats: UnitStatResource = (node.get("stats") as UnitStatResource) if "stats" in node else null
		if node_stats and node_stats.can_build:
			continue
		# Aircraft can't claim oil either -- the deposit is a
		# physical pump rig that needs ground forces to secure.
		# Without this rule a swarm of Switchblades could flip the
		# enemy's deposit by orbiting over it, which trivialises
		# territorial play.
		if node.is_in_group("aircraft"):
			continue
		var uid: int = node.get("owner_id")
		var dist: float = global_position.distance_to(node.global_position)
		if dist > capture_radius:
			continue
		if uid == 2:
			has_neutral = true
			continue
		if owner_counts.has(uid):
			owner_counts[uid] = (owner_counts[uid] as int) + 1
		else:
			owner_counts[uid] = 1
	# Any neutral inside the radius blocks progress — treat the
	# deposit as contested while a neutral patrol is contesting it.
	if has_neutral and not owner_counts.is_empty():
		_is_contested = true
		return

	# Determine capture state
	var capturers: Array = owner_counts.keys()

	if capturers.size() == 0:
		_is_contested = false
		return

	if capturers.size() > 1:
		# Multiple factions present — contested, no capture progress
		_is_contested = true
		return

	# Single faction present
	_is_contested = false
	var capturer_id: int = capturers[0] as int

	if capturer_id == owner_id:
		# Already owned — nothing to do
		return

	# Capturing
	if _capturing_owner != capturer_id:
		# New capturer — reset progress
		_capturing_owner = capturer_id
		_capture_progress = 0.0
		# If the player owned this deposit and someone else just started
		# capturing it, surface that immediately — losing a deposit is the
		# kind of event the player wants to know about even if they're
		# elsewhere on the map.
		if owner_id == 0 and capturer_id != 0:
			_emit_alert("Fuel deposit being captured", 1, "deposit_capture:%d" % get_instance_id(), 12.0)

	_capture_progress += delta
	if _capture_progress >= capture_time:
		_capture_progress = capture_time
		_complete_capture(capturer_id)


func _complete_capture(new_owner: int) -> void:
	var prev_owner: int = owner_id
	owner_id = new_owner
	_capturing_owner = -1
	_capture_progress = 0.0
	captured.emit(new_owner)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_construction_complete"):
		audio.play_construction_complete(global_position)

	# Alerts on ownership change touching the player.
	if new_owner == 0:
		_emit_alert("Fuel deposit captured", 0, "", 0.0)
	elif prev_owner == 0:
		_emit_alert("Fuel deposit lost", 2, "", 0.0)


func _emit_alert(message: String, severity: int, channel: String, cooldown: float) -> void:
	var alert: Node = get_tree().current_scene.get_node_or_null("AlertManager") if get_tree() else null
	if not alert or not alert.has_method("emit_alert"):
		return
	alert.emit_alert(message, severity, global_position, channel, cooldown)


func _generate_fuel(delta: float) -> void:
	if owner_id < 0:
		return
	if _is_contested:
		return

	# Look up the manager via the registry so adding more players in v2 doesn't
	# require teaching every deposit a new naming scheme.
	var registry: PlayerRegistry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	var rm: Node = null
	if registry:
		rm = registry.get_resource_manager(owner_id)
	else:
		# Fallback for scenes without a registry (some test setups still use
		# the legacy named-node convention).
		var rm_name: String = "ResourceManager" if owner_id == 0 else "AIResourceManager"
		rm = get_tree().current_scene.get_node_or_null(rm_name)
	if not rm or not rm.has_method("add_fuel"):
		return

	# Accumulate fuel internally, but only PAY OUT in chunks every
	# FUEL_PAYOUT_INTERVAL_SEC seconds. The chunk gets a floating
	# "+N F" cyan number above the deposit so the player notices
	# the tick coming in. Per-second drip would either spam the
	# screen with ones or stay invisible at sub-pixel intervals.
	_fuel_accumulator += fuel_per_second * delta
	if _fuel_accumulator >= fuel_per_second * FUEL_PAYOUT_INTERVAL_SEC:
		var amount: int = int(_fuel_accumulator)
		_fuel_accumulator -= float(amount)
		rm.add_fuel(amount)
		# Floating chunk readout — player-side deposits only so an
		# enemy capturing the same node doesn't broadcast their
		# income through a still-visible cell.
		if owner_id == 0:
			FloatingNumber.spawn(
				get_tree().current_scene,
				global_position + Vector3(0.0, 2.4, 0.0),
				"+%d F" % amount,
				FloatingNumber.COLOR_FUEL,
				1.6,
				1.4,
				1.5,
			)


## --- Visuals ---

func _create_visuals() -> void:
	# Pump-jack rig + concrete pad + oil barrels around the base —
	# clearly reads as "fuel is being extracted here" instead of a
	# generic hex slab.
	_mesh = Node3D.new()
	_mesh.name = "DepositRig"
	add_child(_mesh)

	# Concrete pad — low wide cylinder with the shared wall-panel
	# texture (slab joints + seams) tinted warm-grey so the pad reads
	# as poured concrete with worn panel divisions instead of a flat
	# painted disc.
	var pad := MeshInstance3D.new()
	var pad_cyl := CylinderMesh.new()
	pad_cyl.top_radius = 3.0
	pad_cyl.bottom_radius = 3.2
	pad_cyl.height = 0.25
	pad_cyl.radial_segments = 16
	pad.mesh = pad_cyl
	pad.position.y = 0.125
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.42, 0.39, 0.35, 1.0)
	pad_mat.albedo_texture = SharedTextures.get_wall_panel_texture()
	pad_mat.uv1_scale = Vector3(2.5, 2.5, 1.0)
	pad_mat.roughness = 0.95
	pad.set_surface_override_material(0, pad_mat)
	_mesh.add_child(pad)
	# Stenciled hazard wedges around the rim -- four short yellow/black
	# striped wedges on the cardinal compass points so the pad reads
	# as an industrial work-site, not a grey disc with a derrick on it.
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = Color(0.78, 0.62, 0.10, 1.0)
	stripe_mat.roughness = 0.7
	for w: int in 4:
		var wedge := MeshInstance3D.new()
		var w_box := BoxMesh.new()
		w_box.size = Vector3(0.55, 0.02, 0.18)
		wedge.mesh = w_box
		var ang: float = float(w) * (PI * 0.5) + PI * 0.25
		wedge.position = Vector3(cos(ang) * 2.65, 0.252, sin(ang) * 2.65)
		wedge.rotation.y = -ang
		wedge.set_surface_override_material(0, stripe_mat)
		_mesh.add_child(wedge)

	# Wellhead — short pipe stub in the center of the pad. The
	# walking-beam pump nods over this.
	var wellhead := MeshInstance3D.new()
	var well_cyl := CylinderMesh.new()
	well_cyl.top_radius = 0.18
	well_cyl.bottom_radius = 0.22
	well_cyl.height = 0.85
	wellhead.mesh = well_cyl
	wellhead.position = Vector3(0.0, 0.65, 0.0)
	var well_mat := StandardMaterial3D.new()
	well_mat.albedo_color = Color(0.18, 0.16, 0.14, 1.0)
	well_mat.metallic = 0.5
	well_mat.roughness = 0.55
	wellhead.set_surface_override_material(0, well_mat)
	_mesh.add_child(wellhead)

	# Pump-jack derrick: an A-frame post that holds the walking beam.
	var derrick_mat := StandardMaterial3D.new()
	derrick_mat.albedo_color = Color(0.22, 0.19, 0.16, 1.0)
	derrick_mat.metallic = 0.4
	derrick_mat.roughness = 0.7
	for leg_i: int in 2:
		var leg := MeshInstance3D.new()
		var lbox := BoxMesh.new()
		lbox.size = Vector3(0.16, 2.6, 0.16)
		leg.mesh = lbox
		var sx: float = -0.55 if leg_i == 0 else 0.55
		leg.position = Vector3(sx, 1.30, -0.85)
		# Splay the legs outward at the bottom — A-frame.
		leg.rotation.z = (-0.18 if leg_i == 0 else 0.18)
		leg.set_surface_override_material(0, derrick_mat)
		_mesh.add_child(leg)
	# Cross-strut between the legs, mid-height.
	var strut := MeshInstance3D.new()
	var strut_box := BoxMesh.new()
	strut_box.size = Vector3(1.4, 0.10, 0.10)
	strut.mesh = strut_box
	strut.position = Vector3(0.0, 1.6, -0.85)
	strut.set_surface_override_material(0, derrick_mat)
	_mesh.add_child(strut)

	# Walking-beam pivot — child node animated by _process. Sits on
	# top of the A-frame and rocks the beam + counterweight up/down.
	_pump_walker = Node3D.new()
	_pump_walker.position = Vector3(0.0, 2.55, -0.85)
	_mesh.add_child(_pump_walker)
	# Walking beam — long horizontal box pointing forward toward the
	# wellhead. Rocks around the pivot to simulate the pump motion.
	var beam := MeshInstance3D.new()
	var beam_box := BoxMesh.new()
	beam_box.size = Vector3(0.20, 0.20, 3.0)
	beam.mesh = beam_box
	beam.position = Vector3(0.0, 0.0, 0.6)
	beam.set_surface_override_material(0, derrick_mat)
	_pump_walker.add_child(beam)
	# Horse-head — angled forward end of the walking beam, the iconic
	# "nodding" tip of a pumpjack.
	var head := MeshInstance3D.new()
	var head_box := BoxMesh.new()
	head_box.size = Vector3(0.30, 0.45, 0.55)
	head.mesh = head_box
	head.position = Vector3(0.0, -0.12, 1.95)
	head.rotation.x = 0.35
	head.set_surface_override_material(0, derrick_mat)
	_pump_walker.add_child(head)
	# Counterweight on the opposite side of the beam — square block
	# behind the pivot.
	var counter := MeshInstance3D.new()
	var counter_box := BoxMesh.new()
	counter_box.size = Vector3(0.55, 0.55, 0.55)
	counter.mesh = counter_box
	counter.position = Vector3(0.0, -0.04, -1.10)
	counter.set_surface_override_material(0, derrick_mat)
	_pump_walker.add_child(counter)

	# Oil barrels — three around the pad edge, slight rotation jitter
	# so they don't read as a perfect ring.
	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.62, 0.32, 0.18, 1.0)  # rust-orange
	barrel_mat.albedo_texture = SharedTextures.get_metal_wear_texture()
	barrel_mat.uv1_scale = Vector3(2.0, 2.0, 1.0)
	barrel_mat.metallic = 0.3
	barrel_mat.roughness = 0.65
	var barrel_positions: Array[Vector2] = [
		Vector2(2.1, 1.4),
		Vector2(-2.0, 1.6),
		Vector2(2.4, -0.4),
		Vector2(-2.2, -0.6),
	]
	for bp: Vector2 in barrel_positions:
		var barrel := MeshInstance3D.new()
		var bcyl := CylinderMesh.new()
		bcyl.top_radius = 0.32
		bcyl.bottom_radius = 0.32
		bcyl.height = 0.85
		bcyl.radial_segments = 16
		barrel.mesh = bcyl
		barrel.position = Vector3(bp.x, 0.42, bp.y)
		barrel.rotation.y = randf_range(0.0, TAU)
		barrel.set_surface_override_material(0, barrel_mat)
		_mesh.add_child(barrel)
		# Top rim — slim ring around the cap so the barrel reads
		# proper, not a flat-shaded cylinder.
		var rim := MeshInstance3D.new()
		var rim_cyl := CylinderMesh.new()
		rim_cyl.top_radius = 0.34
		rim_cyl.bottom_radius = 0.34
		rim_cyl.height = 0.05
		rim_cyl.radial_segments = 16
		rim.mesh = rim_cyl
		rim.position = Vector3(bp.x, 0.86, bp.y)
		rim.set_surface_override_material(0, _detail_metal_dark())
		_mesh.add_child(rim)

	# Spilled oil patch on the pad — small dark disc near the wellhead.
	var spill := MeshInstance3D.new()
	var spill_quad := QuadMesh.new()
	spill_quad.size = Vector2(2.0, 1.4)
	spill.mesh = spill_quad
	spill.rotation.x = -PI * 0.5
	spill.position = Vector3(0.6, 0.27, 0.4)
	var spill_mat := StandardMaterial3D.new()
	spill_mat.albedo_color = Color(0.05, 0.04, 0.06, 0.85)
	spill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spill_mat.metallic = 0.85
	spill_mat.roughness = 0.20
	spill.set_surface_override_material(0, spill_mat)
	_mesh.add_child(spill)

	# Range circle (always visible, subtle)
	_range_indicator = MeshInstance3D.new()
	var range_cyl := CylinderMesh.new()
	range_cyl.top_radius = capture_radius
	range_cyl.bottom_radius = capture_radius
	range_cyl.height = 0.03
	range_cyl.radial_segments = 48
	_range_indicator.mesh = range_cyl

	# Range aura material is cached on the deposit so _update_visuals
	# can recolor it (owner / contested / neutral) without allocating
	# fresh materials per frame.
	_range_mat_cached = StandardMaterial3D.new()
	_range_mat_cached.albedo_color = Color(NEUTRAL_COLOR.r, NEUTRAL_COLOR.g, NEUTRAL_COLOR.b, 0.025)
	_range_mat_cached.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_range_mat_cached.cull_mode = BaseMaterial3D.CULL_DISABLED
	_range_mat_cached.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_range_indicator.set_surface_override_material(0, _range_mat_cached)
	_range_indicator.position.y = 0.05
	# UI-style ring -- exclude it from the FOW dim overlay so the
	# already-translucent material doesn't flicker as visibility
	# toggles near the edge of LOS.
	_range_indicator.set_meta("_fow_skip_dim", true)
	add_child(_range_indicator)
	# Outer ring of the aura -- a thin emissive band at the radius
	# edge so the capture circle has a clearly defined boundary
	# instead of a pure soft fill that fades into the ground.
	_range_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = capture_radius - 0.18
	ring_mesh.outer_radius = capture_radius + 0.05
	ring_mesh.ring_segments = 56
	ring_mesh.rings = 6
	_range_ring.mesh = ring_mesh
	_range_ring_mat = StandardMaterial3D.new()
	_range_ring_mat.albedo_color = Color(NEUTRAL_COLOR.r, NEUTRAL_COLOR.g, NEUTRAL_COLOR.b, 0.22)
	_range_ring_mat.emission_enabled = true
	_range_ring_mat.emission = NEUTRAL_COLOR
	_range_ring_mat.emission_energy_multiplier = 0.9
	_range_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_range_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_range_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_range_ring.set_surface_override_material(0, _range_ring_mat)
	_range_ring.position.y = 0.06
	_range_ring.set_meta("_fow_skip_dim", true)
	add_child(_range_ring)

	# Owner flag indicator (small pillar on top)
	_owner_indicator = MeshInstance3D.new()
	var flag_cyl := CylinderMesh.new()
	flag_cyl.top_radius = 0.3
	flag_cyl.bottom_radius = 0.3
	flag_cyl.height = 2.0
	_owner_indicator.mesh = flag_cyl
	_owner_indicator.position.y = 2.5

	var flag_mat := StandardMaterial3D.new()
	flag_mat.albedo_color = NEUTRAL_COLOR
	flag_mat.emission_enabled = true
	flag_mat.emission = NEUTRAL_COLOR
	flag_mat.emission_energy_multiplier = 1.0
	_owner_indicator.set_surface_override_material(0, flag_mat)
	add_child(_owner_indicator)

	# Capture progress label
	_capture_label = Label3D.new()
	_capture_label.text = ""
	_capture_label.font_size = 48
	_capture_label.pixel_size = 0.02
	_capture_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_capture_label.position = Vector3(0, 4.0, 0)
	add_child(_capture_label)


## Cached flag material so _update_visuals doesn't allocate a
## fresh StandardMaterial3D every frame. The previous version
## created + assigned a new material on every tick -- with a
## handful of deposits this was 240-480 material allocations
## per second JUST for the flag tint. Now reused: only the
## albedo / emission colors are written when the colour actually
## changes since the last visual update.
var _flag_mat_cached: StandardMaterial3D = null
var _flag_color_cached: Color = Color(0, 0, 0, 0)
var _capture_label_text_cached: String = "<uninit>"


func _update_visuals() -> void:
	# Update colors based on state. Owner colour pulls from the
	# PlayerRegistry so the user's match-setup colour pick + AI
	# auto-shuffle drive the flag tint -- the local PLAYER_COLOR
	# constant is only the fallback when the registry isn't up yet
	# (rare, mostly headless test scenes).
	var color: Color = NEUTRAL_COLOR
	if _is_contested:
		color = CONTESTED_COLOR
	elif owner_id != 2:
		var registry: PlayerRegistry = null
		if get_tree() and get_tree().current_scene:
			registry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
		if registry and registry.has_method("get_perspective_color"):
			color = registry.get_perspective_color(owner_id)
		elif owner_id == 0:
			color = PLAYER_COLOR
		else:
			color = ENEMY_COLOR

	# Reuse the cached material; only rewrite when the colour has
	# actually changed (state transitions are rare relative to the
	# 60Hz tick rate, so most frames hit the no-op path).
	if not _flag_mat_cached:
		_flag_mat_cached = StandardMaterial3D.new()
		_flag_mat_cached.emission_enabled = true
		_flag_mat_cached.emission_energy_multiplier = 1.0
		_owner_indicator.set_surface_override_material(0, _flag_mat_cached)
	if color != _flag_color_cached:
		_flag_color_cached = color
		_flag_mat_cached.albedo_color = color
		_flag_mat_cached.emission = color

	# Capture aura tint -- mirrors the flag colour so the player can
	# tell at a glance whose deposit they're standing on without
	# clicking it. Cached compare so we only repaint on owner /
	# contested transitions.
	if _range_mat_cached and _range_ring_mat and color != _range_color_cached:
		_range_color_cached = color
		_range_mat_cached.albedo_color = Color(color.r, color.g, color.b, 0.025)
		_range_ring_mat.albedo_color = Color(color.r, color.g, color.b, 0.22)
		_range_ring_mat.emission = color

	# Capture label -- compare-and-skip on the formatted string so
	# the Label3D's text setter (which trips a re-render of the
	# label glyphs) only fires when the displayed text changes.
	var new_text: String = ""
	var new_modulate: Color = Color(1.0, 1.0, 1.0, 1.0)
	if _capturing_owner >= 0 and _capture_progress > 0.0 and owner_id != _capturing_owner:
		var pct: int = int((_capture_progress / capture_time) * 100.0)
		new_text = "Capturing: %d%%" % pct
	elif _is_contested:
		new_text = "CONTESTED"
		new_modulate = CONTESTED_COLOR
	if new_text != _capture_label_text_cached:
		_capture_label_text_cached = new_text
		_capture_label.text = new_text
		_capture_label.modulate = new_modulate
