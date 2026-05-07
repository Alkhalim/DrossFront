class_name SatelliteSpawner
extends Node
## Spawns satellite-crash salvage piles. At match start drops 2-4
## piles around the map; every 120-180 seconds drops one more
## somewhere a player can race for it. Each pile is a Wreck with
## a microchip payload — workers gather them like any other wreck
## and deposit chips alongside salvage on the return trip.

const STARTING_PILES_MIN: int = 2
const STARTING_PILES_MAX: int = 4

## Cadence for crash-event satellite drops. Tightened from
## 120-180s to 180-240s -- "every 3-4 minutes" puts a fresh
## chip pile on the map regularly enough that microchips stay
## a present resource consideration without the satellite
## ticker turning into background noise.
const RESPAWN_INTERVAL_MIN: float = 180.0
const RESPAWN_INTERVAL_MAX: float = 240.0

## Salvage in each satellite pile — meaningfully fatter than a
## standard wreck so it's worth racing for, but not so fat that
## controlling one swings the whole match.
const SATELLITE_SALVAGE: int = 220

## Microchip payload range — 2 or 3 chips per pile. With 2 chips
## per branch commit, that's "exactly one commit's worth, sometimes
## a chip leftover for the next" -- meaningful payoff for racing
## the satellite without the bottom of the range (1) feeling like a
## wasted trip.
const SATELLITE_CHIPS_MIN: int = 2
const SATELLITE_CHIPS_MAX: int = 3

## Pile placement: a square around the origin. Avoids the very
## edges (units would have a hard time reaching them) and keeps
## chunks in the playable zone.
const SPAWN_X_RANGE: float = 110.0
const SPAWN_Z_RANGE: float = 110.0
## Keep-out radius from any HQ so satellites don't drop on top
## of bases. 40 was close enough that the very-early initial
## drops sometimes landed inside the player's expanding economic
## footprint and felt like free starter resources for whichever
## side the dice favored. 70 puts them outside the typical opening
## build perimeter — the player has to scout/walk to claim them.
const HQ_KEEPOUT: float = 70.0

## Lead time between the player getting an early-warning ping and
## the satellite actually impacting. 90s gives the player room to
## re-route a Crawler / squad toward the marked spot before the
## chip pile lands.
const WARNING_LEAD_TIME_SEC: float = 90.0
## Spacing between minimap re-pings during the warning window so
## the marker keeps the player's eye anchored without spamming
## audio. Aligned roughly with the alert-channel cooldown so the
## "incoming" voiceline doesn't repeat every tick.
const WARNING_PING_INTERVAL_SEC: float = 15.0

## Impact damage radius + magnitude. Values mirror the ammo dump's
## "this matters" pop so the player learns the cue: catching a
## Bulwark squad under the impact is meaningful but not
## squad-deleting.
const IMPACT_DAMAGE: int = 200
const IMPACT_RADIUS: float = 10.0

## Crash-event LOS reveal at the impact point. Long enough for the
## player to register the explosion + chip pile before the fog
## takes the cell back.
const IMPACT_REVEAL_RADIUS: float = 26.0
const IMPACT_REVEAL_DURATION_SEC: float = 8.0

var _next_spawn_in: float = 0.0

## Pending crashes -- each entry { pos, fires_at_sec, last_ping_sec,
## warning_key, last_banner_sec }. _process steps through this list
## every frame; warnings re-ping every WARNING_PING_INTERVAL_SEC and
## the impact triggers when fires_at_sec elapses. The HUD countdown
## banner re-renders every second so the ticker visibly updates.
var _pending_crashes: Array[Dictionary] = []
var _next_warning_key: int = 0


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
	# Step pending crash warnings (re-ping minimap + trigger
	# impact when their countdown lands).
	if not _pending_crashes.is_empty():
		var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
		var hud: Node = _find_hud()
		var i: int = _pending_crashes.size() - 1
		while i >= 0:
			var entry: Dictionary = _pending_crashes[i]
			if (entry["fires_at"] as float) <= now_sec:
				if hud and hud.has_method("clear_persistent_warning"):
					hud.call("clear_persistent_warning", entry["warning_key"] as String)
				var minimap_done: Node = _find_minimap()
				if minimap_done and minimap_done.has_method("stop_pulse_pin"):
					minimap_done.call("stop_pulse_pin", entry["warning_key"] as String)
				_trigger_crash(entry["pos"] as Vector3)
				_pending_crashes.remove_at(i)
			else:
				var remaining: int = int(ceilf((entry["fires_at"] as float) - now_sec))
				# Per-second banner refresh so the countdown visibly
				# ticks down rather than fading away after one paint.
				var last_banner: float = entry.get("last_banner", -1.0) as float
				if hud and hud.has_method("set_persistent_warning") and (last_banner < 0.0 or floorf(last_banner) != floorf(now_sec)):
					var msg: String = "Satellite incoming — %ds to impact" % remaining
					hud.call("set_persistent_warning", entry["warning_key"] as String, msg, 1)
					entry["last_banner"] = now_sec
				# Periodic flash ping kept alongside the persistent
				# pulse pin so the audio / minimap-flash cue still
				# triggers every WARNING_PING_INTERVAL_SEC.
				if now_sec - (entry["last_ping"] as float) >= WARNING_PING_INTERVAL_SEC:
					_ping_warning(entry["pos"] as Vector3)
					entry["last_ping"] = now_sec
				_pending_crashes[i] = entry
			i -= 1

	# Schedule new crash warnings on the existing cadence.
	if _next_spawn_in <= 0.0:
		return
	_next_spawn_in -= delta
	if _next_spawn_in <= 0.0:
		_schedule_crash()
		_schedule_next_spawn()


func _schedule_next_spawn() -> void:
	_next_spawn_in = randf_range(RESPAWN_INTERVAL_MIN, RESPAWN_INTERVAL_MAX)


func _initial_drop() -> void:
	## Match-start piles. Distribute across map sectors so they don't
	## cluster on one half (random sampling occasionally landed 2-3
	## piles near a single base while the other side saw none — felt
	## arbitrary). Divide the map into 4 quadrants and place one pile
	## per quadrant up to count, then any extras go to a random
	## quadrant. Each per-quadrant pick still passes through _is_clear
	## (HQ keep-out, elevation skip, other-satellite spacing).
	var count: int = randi_range(STARTING_PILES_MIN, STARTING_PILES_MAX)
	# Quadrant order: NE, NW, SW, SE — shuffled so the same map seed
	# doesn't always favor the same corner.
	var quadrants: Array = [
		Vector2(1, 1), Vector2(-1, 1),
		Vector2(-1, -1), Vector2(1, -1),
	]
	quadrants.shuffle()
	for i: int in count:
		var quad: Vector2 = quadrants[i % quadrants.size()]
		var pos: Vector3 = _pick_spawn_pos_in_quadrant(quad)
		if pos != Vector3.INF:
			_drop_static_pile(pos)


func _pick_spawn_pos_in_quadrant(quad: Vector2) -> Vector3:
	## Same retry logic as _pick_spawn_pos but constrains x/z signs to
	## the requested quadrant so the result lands in the intended
	## sector of the map. quad is a unit Vector2 with x,z each ±1.
	for attempt: int in 12:
		var x_mag: float = randf_range(SPAWN_X_RANGE * 0.30, SPAWN_X_RANGE)
		var z_mag: float = randf_range(SPAWN_Z_RANGE * 0.30, SPAWN_Z_RANGE)
		var p: Vector3 = Vector3(x_mag * quad.x, 0.0, z_mag * quad.y)
		if _is_clear(p):
			return p
	return Vector3.INF


func _drop_static_pile(pos: Vector3) -> void:
	## Map-setup pile -- already on the ground when the match
	## starts, no warning, no impact damage, no flare. Player
	## scouts it normally.
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


func _schedule_crash() -> void:
	## Picks an impact site, fires the early-warning alert + minimap
	## ping, and queues the actual impact for WARNING_LEAD_TIME_SEC
	## seconds out. The player has the lead time to redirect a
	## Crawler / squad toward the marked spot.
	var pos: Vector3 = _pick_spawn_pos()
	if pos == Vector3.INF:
		return
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	var key: String = "satellite_%d" % _next_warning_key
	_next_warning_key += 1
	_pending_crashes.append({
		"pos": pos,
		"fires_at": now_sec + WARNING_LEAD_TIME_SEC,
		"last_ping": now_sec,
		"warning_key": key,
		"last_banner": -1.0,
	})
	# Initial alert + ping so the player knows immediately.
	var alerts: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if alerts and alerts.has_method("emit_alert"):
		alerts.call(
			"emit_alert",
			"Satellite tracked — impact in %ds" % int(WARNING_LEAD_TIME_SEC),
			0,
			pos,
		)
	_ping_warning(pos)
	# Persistent pulse pin so the eye stays anchored to the impact
	# site for the whole 90s lead time, not just the 1.5s flash.
	var minimap: Node = _find_minimap()
	if minimap and minimap.has_method("start_pulse_pin"):
		minimap.call("start_pulse_pin", key, pos, Color(0.78, 0.42, 1.0, 1.0))


func _ping_warning(pos: Vector3) -> void:
	## Ping the minimap (violet, matches chip colour) at the future
	## impact point. Called once on schedule + every
	## WARNING_PING_INTERVAL_SEC during the lead window so the eye
	## stays anchored to where the crash will land.
	var minimap: Node = _find_minimap()
	if minimap and minimap.has_method("ping"):
		minimap.call("ping", pos, Color(0.78, 0.42, 1.0, 1.0))


func _find_hud() -> Node:
	## The HUD scene is currently parented under UILayer in
	## test_arena.tscn (UILayer/HUD). Two legacy paths kept as
	## fallback (top-level HUD, HUDCanvas/HUD) so older scenes /
	## tests still resolve.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return null
	var hud: Node = scene.get_node_or_null("UILayer/HUD")
	if not hud:
		hud = scene.get_node_or_null("HUD")
	if not hud:
		var canvas: Node = scene.get_node_or_null("HUDCanvas")
		if canvas:
			hud = canvas.get_node_or_null("HUD")
	return hud


func _find_minimap() -> Node:
	var hud: Node = _find_hud()
	if hud:
		return hud.get_node_or_null("Minimap")
	return null


func _trigger_crash(pos: Vector3) -> void:
	## Impact event: spawns the chip pile, deals splash damage to
	## anything inside IMPACT_RADIUS, plays a heavy explosion + VFX,
	## and grants a brief LOS reveal so the player sees the crater.
	# Spawn the pile.
	_drop_static_pile(pos)

	# Splash damage -- units / buildings / crawlers within the impact
	# radius take a flat IMPACT_DAMAGE. Linear cap so the centre
	# takes full and the edge takes ~30%.
	var groups: Array[String] = ["units", "buildings", "crawlers"]
	for g: String in groups:
		for node: Node in get_tree().get_nodes_in_group(g):
			if not is_instance_valid(node):
				continue
			if not node.has_method("take_damage"):
				continue
			var n3: Node3D = node as Node3D
			if not n3:
				continue
			var d: float = pos.distance_to(n3.global_position)
			if d > IMPACT_RADIUS:
				continue
			var falloff: float = clampf(1.0 - (d / IMPACT_RADIUS) * 0.7, 0.3, 1.0)
			node.take_damage(int(IMPACT_DAMAGE * falloff), null)

	# Tree clearing -- a satellite slamming into the canopy on
	# Schwarzwald (or any forested map) should leave a small ring
	# of fallen trees + the visible crater. Trees are not in the
	# splash group above; queue_free them directly here so the
	# crash actually reads as 'something hit the ground hard'.
	const TREE_CLEAR_RADIUS: float = 6.0
	for tree_node: Node in get_tree().get_nodes_in_group("trees"):
		if not is_instance_valid(tree_node):
			continue
		var t3: Node3D = tree_node as Node3D
		if not t3:
			continue
		if pos.distance_to(t3.global_position) <= TREE_CLEAR_RADIUS:
			t3.queue_free()

	# Audio -- huge explosion stinger so the crash reads as a real
	# event, not a quiet pop.
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio:
		if audio.has_method("play_huge_explosion"):
			audio.call("play_huge_explosion", pos)
		elif audio.has_method("play_weapon_impact"):
			audio.call("play_weapon_impact", pos)

	# Brief FOW reveal at the impact site so the player can
	# actually see the explosion + new pile.
	var fow: Node = get_tree().current_scene.get_node_or_null("FogOfWar")
	if fow and fow.has_method("reveal_area"):
		fow.call("reveal_area", pos, IMPACT_REVEAL_RADIUS, IMPACT_REVEAL_DURATION_SEC)

	# Visual punch -- fireball + ground shockwave (mirrors ammo dump's
	# detonation language so the player learns the visual cue across
	# both kinds of explosions).
	_spawn_impact_vfx(pos)
	_spawn_flare(pos)

	# Confirmation alert at the actual impact.
	var alerts: Node = get_tree().current_scene.get_node_or_null("AlertManager")
	if alerts and alerts.has_method("emit_alert"):
		alerts.call("emit_alert", "Satellite impact — chips down", 0, pos)


func _spawn_impact_vfx(pos: Vector3) -> void:
	## Fireball sphere expanding to ~70% IMPACT_RADIUS + ground-laid
	## shockwave torus expanding out to IMPACT_RADIUS. Same recipe
	## as ammo_dump._spawn_explosion_vfx, smaller because the impact
	## radius is 10u vs 14u.
	var scene: Node = get_tree().current_scene
	if not scene:
		return
	# Brief omni light that throws onto nearby geometry.
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.18, 1.0)
	light.light_energy = 7.0
	light.omni_range = IMPACT_RADIUS * 1.8
	scene.add_child(light)
	light.global_position = pos + Vector3(0.0, 1.5, 0.0)
	var ltween := light.create_tween()
	ltween.tween_property(light, "light_energy", 0.0, 0.7).set_ease(Tween.EASE_OUT)
	ltween.tween_callback(light.queue_free)
	# Fireball sphere.
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
	var fb_target_scale: float = IMPACT_RADIUS * 0.7
	var fb_tween := fireball.create_tween()
	fb_tween.set_parallel(true)
	fb_tween.tween_property(fireball, "scale", Vector3.ONE * fb_target_scale, 0.45).set_ease(Tween.EASE_OUT)
	fb_tween.tween_property(fb_mat, "albedo_color:a", 0.0, 0.55).set_ease(Tween.EASE_IN).set_delay(0.10)
	fb_tween.chain().tween_callback(fireball.queue_free)
	# Shockwave ring.
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
	ring.rotation.x = -PI * 0.5
	scene.add_child(ring)
	ring.global_position = pos + Vector3(0.0, 0.15, 0.0)
	var ring_tween := ring.create_tween()
	ring_tween.set_parallel(true)
	ring_tween.tween_property(ring, "scale", Vector3(IMPACT_RADIUS, IMPACT_RADIUS, IMPACT_RADIUS), 0.55).set_ease(Tween.EASE_OUT)
	ring_tween.tween_property(ring_mat, "albedo_color:a", 0.0, 0.55).set_ease(Tween.EASE_IN).set_delay(0.20)
	ring_tween.chain().tween_callback(ring.queue_free)


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
	# Plateau / ramp keep-out -- piles dropped on a slope or under a
	# plateau body get buried in the geometry and become unreachable.
	# Cheap AABB test against every "elevation"-group collision shape
	# instead of a raycast (raycast missed the ramp's convex-hull
	# faces from straight above on a couple of attempts).
	for elev_node: Node in get_tree().get_nodes_in_group("elevation"):
		if not is_instance_valid(elev_node):
			continue
		var elev_body: StaticBody3D = elev_node as StaticBody3D
		if not elev_body:
			continue
		if _point_inside_elevation(p, elev_body):
			return false
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


func _point_inside_elevation(p: Vector3, body: StaticBody3D) -> bool:
	## Returns true if `p` (XZ only) sits inside the AABB of any
	## CollisionShape3D child of `body`. Plateau bodies use a Box,
	## ramps use a ConvexPolygonShape3D -- both expose `get_aabb()` /
	## bounding extents we can read after transforming to world space.
	const PAD: float = 1.0
	for child: Node in body.get_children():
		var col: CollisionShape3D = child as CollisionShape3D
		if not col or not col.shape:
			continue
		var aabb: AABB = col.shape.get_debug_mesh().get_aabb() if col.shape.has_method("get_debug_mesh") else AABB()
		# Transform the local-space AABB to world space via the body
		# + collision-shape combined transform so plateau placement
		# offsets carry through.
		var xform: Transform3D = body.global_transform * col.transform
		var w_aabb: AABB = xform * aabb
		w_aabb = w_aabb.grow(PAD)
		if p.x < w_aabb.position.x or p.x > w_aabb.position.x + w_aabb.size.x:
			continue
		if p.z < w_aabb.position.z or p.z > w_aabb.position.z + w_aabb.size.z:
			continue
		return true
	return false
