class_name FuelDeposit
extends Node3D
## A capturable fuel deposit on the map. Generates passive fuel income for the owner.

signal captured(new_owner: int)
signal contested

## Fuel generated per second when captured.
@export var fuel_per_second: float = 5.0

## Radius in which units can capture or contest.
@export var capture_radius: float = 12.0

## Time in seconds to capture from neutral.
@export var capture_time: float = 30.0

## Current owner: -1 = neutral, 0 = player, 1+ = AI
var owner_id: int = -1

## Capture state
var _capture_progress: float = 0.0
var _capturing_owner: int = -1
var _is_contested: bool = false

## Fuel income accumulator
var _fuel_accumulator: float = 0.0

## Visuals
var _mesh: MeshInstance3D = null
var _range_indicator: MeshInstance3D = null
var _capture_bar_bg: MeshInstance3D = null
var _capture_bar_fill: MeshInstance3D = null
var _capture_label: Label3D = null
var _owner_indicator: MeshInstance3D = null

const NEUTRAL_COLOR := Color(0.6, 0.5, 0.3, 1.0)
const PLAYER_COLOR := Color(0.2, 0.6, 0.9, 1.0)
const ENEMY_COLOR := Color(0.9, 0.3, 0.2, 1.0)
const CONTESTED_COLOR := Color(0.9, 0.7, 0.1, 1.0)


func _ready() -> void:
	add_to_group("fuel_deposits")
	_create_visuals()


func _process(delta: float) -> void:
	_update_capture(delta)
	_generate_fuel(delta)
	_update_visuals()


func _update_capture(delta: float) -> void:
	# Count units of each owner inside the radius
	var owner_counts: Dictionary = {}
	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not is_instance_valid(node):
			continue
		if not ("alive_count" in node) or node.get("alive_count") <= 0:
			continue
		var dist: float = global_position.distance_to(node.global_position)
		if dist <= capture_radius:
			var uid: int = node.get("owner_id")
			if owner_counts.has(uid):
				owner_counts[uid] = (owner_counts[uid] as int) + 1
			else:
				owner_counts[uid] = 1

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

	_fuel_accumulator += fuel_per_second * delta
	if _fuel_accumulator >= 1.0:
		var amount: int = int(_fuel_accumulator)
		_fuel_accumulator -= float(amount)
		rm.add_fuel(amount)


## --- Visuals ---

func _create_visuals() -> void:
	# Main deposit mesh — a hexagonal prism shape (using cylinder as placeholder)
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 2.0
	cyl.bottom_radius = 2.5
	cyl.height = 1.5
	cyl.radial_segments = 6
	_mesh.mesh = cyl
	_mesh.position.y = 0.75

	var mat := StandardMaterial3D.new()
	mat.albedo_color = NEUTRAL_COLOR
	mat.roughness = 0.7
	_mesh.set_surface_override_material(0, mat)
	add_child(_mesh)

	# Range circle (always visible, subtle)
	_range_indicator = MeshInstance3D.new()
	var range_cyl := CylinderMesh.new()
	range_cyl.top_radius = capture_radius
	range_cyl.bottom_radius = capture_radius
	range_cyl.height = 0.03
	range_cyl.radial_segments = 48
	_range_indicator.mesh = range_cyl

	var range_mat := StandardMaterial3D.new()
	range_mat.albedo_color = Color(0.6, 0.5, 0.3, 0.06)
	range_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	range_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_range_indicator.set_surface_override_material(0, range_mat)
	_range_indicator.position.y = 0.05
	add_child(_range_indicator)

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


func _update_visuals() -> void:
	# Update colors based on state
	var color: Color = NEUTRAL_COLOR
	if _is_contested:
		color = CONTESTED_COLOR
	elif owner_id == 0:
		color = PLAYER_COLOR
	elif owner_id > 0:
		color = ENEMY_COLOR

	# Update flag
	var flag_mat := StandardMaterial3D.new()
	flag_mat.albedo_color = color
	flag_mat.emission_enabled = true
	flag_mat.emission = color
	flag_mat.emission_energy_multiplier = 1.0
	_owner_indicator.set_surface_override_material(0, flag_mat)

	# Update capture label
	if _capturing_owner >= 0 and _capture_progress > 0.0 and owner_id != _capturing_owner:
		var pct: int = int((_capture_progress / capture_time) * 100.0)
		_capture_label.text = "Capturing: %d%%" % pct
		_capture_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	elif _is_contested:
		_capture_label.text = "CONTESTED"
		_capture_label.modulate = CONTESTED_COLOR
	else:
		_capture_label.text = ""
