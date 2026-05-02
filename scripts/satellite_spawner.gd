class_name SatelliteSpawner
extends Node
## Spawns satellite-crash salvage piles. At match start drops 2-4
## piles around the map; every 120-180 seconds drops one more
## somewhere a player can race for it. Each pile is a Wreck with
## a microchip payload — workers gather them like any other wreck
## and deposit chips alongside salvage on the return trip.

const STARTING_PILES_MIN: int = 2
const STARTING_PILES_MAX: int = 4

const RESPAWN_INTERVAL_MIN: float = 120.0
const RESPAWN_INTERVAL_MAX: float = 180.0

## Salvage in each satellite pile — meaningfully fatter than a
## standard wreck so it's worth racing for, but not so fat that
## controlling one swings the whole match.
const SATELLITE_SALVAGE: int = 220

## Microchip payload range — 1 / 2 / 3 chips per pile, biased
## low so the average match drops "enough chips for one to two
## branch upgrades" per spawn cycle. With 2 chips per branch
## commit, three chips lets a savvy player snag a research +
## save the leftover.
const SATELLITE_CHIPS_MIN: int = 1
const SATELLITE_CHIPS_MAX: int = 3

## Pile placement: a square around the origin. Avoids the very
## edges (units would have a hard time reaching them) and keeps
## chunks in the playable zone.
const SPAWN_X_RANGE: float = 110.0
const SPAWN_Z_RANGE: float = 110.0
## Keep-out radius from any HQ so satellites don't drop on top
## of bases.
const HQ_KEEPOUT: float = 40.0

var _next_spawn_in: float = 0.0


func _ready() -> void:
	# Tutorial mode strips out the satellite-crash mechanic — the
	# mission has its own scripted pacing and a satellite-flare
	# pop-up + microchip economy on top would just be noise that
	# the tutorial banner never explains. Disable the spawner
	# entirely on tutorial scenes.
	var settings: Node = get_tree().current_scene.get_node_or_null("../MatchSettings") if get_tree() else null
	if not settings:
		settings = get_node_or_null("/root/MatchSettings")
	if settings and settings.get("tutorial_mode"):
		set_process(false)
		return
	# Stagger first spawn pass so initial scene chaos is settled.
	call_deferred("_initial_drop")
	_schedule_next_spawn()


func _process(delta: float) -> void:
	if _next_spawn_in <= 0.0:
		return
	_next_spawn_in -= delta
	if _next_spawn_in <= 0.0:
		_spawn_one()
		_schedule_next_spawn()


func _schedule_next_spawn() -> void:
	_next_spawn_in = randf_range(RESPAWN_INTERVAL_MIN, RESPAWN_INTERVAL_MAX)


func _initial_drop() -> void:
	var count: int = randi_range(STARTING_PILES_MIN, STARTING_PILES_MAX)
	for i: int in count:
		_spawn_one()


func _spawn_one() -> void:
	var pos: Vector3 = _pick_spawn_pos()
	if pos == Vector3.INF:
		return
	var pile := Wreck.new()
	pile.salvage_value = SATELLITE_SALVAGE
	pile.salvage_remaining = SATELLITE_SALVAGE
	pile.microchip_value = randi_range(SATELLITE_CHIPS_MIN, SATELLITE_CHIPS_MAX)
	pile.is_satellite = true
	pile.wreck_size = Vector3(2.6, 0.7, 2.6)
	pile.position = pos
	get_tree().current_scene.add_child.call_deferred(pile)
	# Surface a one-line alert so the player learns the cue —
	# AlertManager handles routing to the HUD ticker if present.
	var alerts: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if alerts and alerts.has_method("emit_alert"):
		alerts.call("emit_alert", "Satellite crash detected — salvage and chips inbound", 0, pos)
	# Briefly reveal the crash site through the fog so the player
	# actually sees the new pile pop in (8s gives them time to
	# notice + plan a recovery before LOS lapses).
	var fow: Node = get_tree().current_scene.get_node_or_null("FogOfWar")
	if fow and fow.has_method("reveal_area"):
		fow.call("reveal_area", pos, 28.0, 8.0)
	# Minimap ping in violet so the player's eye snaps to the
	# crash site even off-screen — same colour as the chips
	# resource readout so the cue is consistent.
	var hud: Node = get_tree().current_scene.get_node_or_null("HUD")
	if not hud:
		# HUD is a CanvasLayer scene attached to the test arena;
		# the actual minimap node sits inside it.
		var canvas: Node = get_tree().current_scene.get_node_or_null("HUDCanvas")
		if canvas:
			hud = canvas.get_node_or_null("HUD")
	var minimap: Node = null
	if hud:
		minimap = hud.get_node_or_null("Minimap")
	if minimap and minimap.has_method("ping"):
		minimap.call("ping", pos, Color(0.78, 0.42, 1.0, 1.0))
	# Vertical signal flare at the crash position — emissive violet
	# beam tapering up so the player's camera sweep catches it.
	# Free-standing scene child; tweens its own scale/alpha out and
	# queue_frees after ~3.5s.
	_spawn_flare(pos)


func _spawn_flare(pos: Vector3) -> void:
	## Tall thin emissive cylinder at the crash site. Reads as a
	## signal flare punching up through the air column. Tweened
	## out over ~3.5s, then queue_freed.
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	var beam := MeshInstance3D.new()
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var beam_cyl := CylinderMesh.new()
	beam_cyl.top_radius = 0.06
	beam_cyl.bottom_radius = 0.20
	beam_cyl.height = 28.0
	beam_cyl.radial_segments = 12
	beam.mesh = beam_cyl
	var beam_mat := StandardMaterial3D.new()
	beam_mat.albedo_color = Color(0.78, 0.42, 1.0, 0.55)
	beam_mat.emission_enabled = true
	beam_mat.emission = Color(0.78, 0.42, 1.0, 1.0)
	beam_mat.emission_energy_multiplier = 3.2
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam.set_surface_override_material(0, beam_mat)
	scene.add_child(beam)
	beam.global_position = pos + Vector3(0.0, 14.0, 0.0)

	# Bright violet OmniLight at the base — drops a real ground
	# splash that catches the eye even at low zoom on the minimap.
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.78, 0.42, 1.0, 1.0)
	glow.light_energy = 4.0
	glow.omni_range = 18.0
	glow.position = Vector3(0.0, 1.0, 0.0)
	beam.add_child(glow)

	var tween: Tween = beam.create_tween().set_parallel(true)
	tween.tween_property(beam_mat, "albedo_color:a", 0.0, 3.5).set_ease(Tween.EASE_IN)
	tween.tween_property(beam_mat, "emission_energy_multiplier", 0.0, 3.5).set_ease(Tween.EASE_IN)
	tween.tween_property(glow, "light_energy", 0.0, 3.5).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(beam.queue_free)


func _pick_spawn_pos() -> Vector3:
	# Up to ~12 retries to find a spot that isn't on top of an HQ
	# or another satellite pile. Falls through with INF if every
	# try collided — caller skips silently.
	for attempt: int in 12:
		var x: float = randf_range(-SPAWN_X_RANGE, SPAWN_X_RANGE)
		var z: float = randf_range(-SPAWN_Z_RANGE, SPAWN_Z_RANGE)
		var p: Vector3 = Vector3(x, 0.0, z)
		if _is_clear(p):
			return p
	return Vector3.INF


func _is_clear(p: Vector3) -> bool:
	# HQ keep-out.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b: Building = node as Building
		if not b or not b.stats:
			continue
		if b.stats.building_id != &"headquarters":
			continue
		if p.distance_to(b.global_position) < HQ_KEEPOUT:
			return false
	# Other-satellite spacing — don't drop two piles on top of one
	# another so the player has to actually move workers between them.
	# Group iteration is defensive: any pre-existing wreck created
	# before is_satellite was added doesn't have the property, so we
	# duck-type the check via `in` rather than relying on the typed
	# Wreck cast carrying the new field.
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		if not ("is_satellite" in node):
			continue
		if not (node.get("is_satellite") as bool):
			continue
		var w_pos: Vector3 = (node as Node3D).global_position
		if p.distance_to(w_pos) < 25.0:
			return false
	return true
