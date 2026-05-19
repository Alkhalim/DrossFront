class_name PlasmaProjectile
extends Node3D
## Slow blueish plasma orb. Distinct from the bullet / missile path
## because it carries three special-cased behaviours:
##   - Slow flight (~12 u/s) so the orb is visibly in transit.
##   - Slight oscillation: sin-wave perpendicular drift + scale pulse +
##     emissive flicker. Sells the "unstable plasma" read.
##   - Piercing damage: anything inside HIT_RADIUS of the orb takes
##     full payload damage and is then added to a dedupe set so the
##     same target isn't hit twice by one orb. The orb keeps flying
##     until it reaches its declared target / max range.
##
## Implementation chose Node3D over ProjectileManager because the
## piercing-hit set + per-orb oscillation phase don't fit cleanly into
## the manager's PackedArray layout. Plasma volume is small in practice
## (Sol Invictus body turrets fire 4-per-volley at 0.5 s rof against
## medium-range targets — ~16 in flight peak), so the per-instance
## Node3D cost is acceptable.

## Speed in world units per second. Slow enough that the orb is
## visibly travelling (player can dodge with micro), fast enough that
## a 18u-range engagement resolves in ~1.5 s.
const PLASMA_SPEED: float = 12.0

## Implosion AoE on impact. When the orb completes its flight (reaches
## the target distance) or dissipates, a small area damage burst fires
## at the impact point — sells "the plasma dissipates outward" rather
## than vanishing silently. Tuned to be a soft secondary effect, not
## the main damage path (which is the piercing per-target hit during
## flight).
const IMPLOSION_RADIUS: float = 1.6
const IMPLOSION_DMG_FRAC: float = 0.40  # of full payload

## How long the orb lives before despawning regardless of arrival.
## Just in case the orb misses (oscillation overshoot, target dies
## mid-flight, etc) — without this cap the orb would chase forever.
const MAX_LIFETIME_SEC: float = 4.0

## Radius around the orb at which piercing damage triggers. Matches
## the orb's visual radius so the "you got hit if it touched you" read
## is honest.
const HIT_RADIUS: float = 0.85

## Perpendicular oscillation amplitude in world units. The orb wobbles
## around its straight-line flight path by this much, looking unstable.
const WOBBLE_AMPLITUDE: float = 0.55

## Oscillation frequency in Hz. Slow enough to read as a deliberate
## sway, not jitter.
const WOBBLE_HZ: float = 3.2

## Sin-wave pulse on the visual scale of the orb. 1.0 ± SCALE_PULSE_AMP.
const SCALE_PULSE_AMP: float = 0.18
const SCALE_PULSE_HZ: float = 5.0

var _from_pos: Vector3 = Vector3.ZERO
var _to_pos: Vector3 = Vector3.ZERO
var _travel_dir: Vector3 = Vector3.FORWARD
var _perp_a: Vector3 = Vector3.RIGHT
var _perp_b: Vector3 = Vector3.UP
var _life: float = 0.0
var _wobble_phase: float = 0.0
var _max_dist: float = 30.0
var _payload_damage: int = 0
var _shooter: Node3D = null
var _shooter_owner_id: int = -1
var _primary_target_iid: int = 0
## Dedupe set: instance_id → true for every squad we've already
## damaged on this flight. Stops one orb from chipping a target to
## death by piling 30 ticks of damage onto the same unit it sits on.
var _hit_set: Dictionary = {}
var _orb_mesh: MeshInstance3D = null
var _glow_mesh: MeshInstance3D = null
var _orb_material: StandardMaterial3D = null
var _glow_material: StandardMaterial3D = null


static func create(from: Vector3, to: Vector3, damage: int,
		shooter: Node3D, shooter_owner_id: int,
		primary_target: Node3D = null) -> PlasmaProjectile:
	## Factory. Caller (CombatComponent) parents the returned node to
	## the current scene root before configuring further. damage is the
	## full payload — applied per pierced target, NOT divided across
	## hits, so a beefy plasma orb mowing through a tight squad
	## genuinely shreds it.
	var p := PlasmaProjectile.new()
	# Match Projectile.create's fire_y lift so muzzle positions land at
	# barrel height vs unit-center.
	var fire_y: float = from.y if from.y >= 0.5 else from.y + 1.0
	p._from_pos = Vector3(from.x, fire_y, from.z)
	p._to_pos = Vector3(to.x, to.y + 0.6, to.z)
	p._travel_dir = p._to_pos - p._from_pos
	p._max_dist = p._travel_dir.length()
	if p._max_dist > 0.001:
		p._travel_dir = p._travel_dir / p._max_dist
	# Build a stable basis for perpendicular wobble. perp_a is in the
	# horizontal plane (so the wobble doesn't look like the orb is
	# bobbing vertically only); perp_b uses the cross to span the
	# remaining axis.
	var any_up: Vector3 = Vector3.UP if absf(p._travel_dir.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	p._perp_a = any_up.cross(p._travel_dir).normalized()
	p._perp_b = p._travel_dir.cross(p._perp_a).normalized()
	# Stagger phase per orb so a 4-volley doesn't move in lockstep.
	p._wobble_phase = randf() * TAU
	p._payload_damage = damage
	p._shooter = shooter
	p._shooter_owner_id = shooter_owner_id
	if primary_target != null and is_instance_valid(primary_target):
		p._primary_target_iid = primary_target.get_instance_id()
	p.position = p._from_pos
	return p


func _ready() -> void:
	# Group membership so FoW + cleanup paths can find plasma orbs the
	# same way they find other projectiles.
	add_to_group("projectiles")
	_build_visual()


func _build_visual() -> void:
	## Two stacked meshes: a bright inner core sphere + a translucent
	## outer halo. Both share the cool plasma blue tint; emission is
	## what makes the orb pop against dark terrain.
	const PLASMA_CORE: Color = Color(0.55, 0.75, 1.00, 1.0)   # cool blue-white
	const PLASMA_HALO: Color = Color(0.30, 0.55, 1.00, 0.55)  # deeper translucent blue

	_orb_mesh = MeshInstance3D.new()
	_orb_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core_sphere := SphereMesh.new()
	core_sphere.radius = 0.32
	core_sphere.height = 0.64
	core_sphere.radial_segments = 12
	core_sphere.rings = 8
	_orb_mesh.mesh = core_sphere
	_orb_material = StandardMaterial3D.new()
	_orb_material.albedo_color = PLASMA_CORE
	_orb_material.emission_enabled = true
	_orb_material.emission = PLASMA_CORE
	_orb_material.emission_energy_multiplier = 4.5
	_orb_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_orb_mesh.set_surface_override_material(0, _orb_material)
	add_child(_orb_mesh)

	_glow_mesh = MeshInstance3D.new()
	_glow_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var glow_sphere := SphereMesh.new()
	glow_sphere.radius = 0.62
	glow_sphere.height = 1.24
	glow_sphere.radial_segments = 12
	glow_sphere.rings = 8
	_glow_mesh.mesh = glow_sphere
	_glow_material = StandardMaterial3D.new()
	_glow_material.albedo_color = PLASMA_HALO
	_glow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow_material.emission_enabled = true
	_glow_material.emission = PLASMA_HALO
	_glow_material.emission_energy_multiplier = 2.4
	_glow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_glow_mesh.set_surface_override_material(0, _glow_material)
	add_child(_glow_mesh)


func _process(delta: float) -> void:
	_life += delta
	if _life >= MAX_LIFETIME_SEC:
		queue_free()
		return

	# Travel along the straight-line path, then apply perpendicular
	# wobble + a slight forward-axis jitter so the path looks unstable
	# instead of mathematically clean.
	var traveled: float = _life * PLASMA_SPEED
	if traveled >= _max_dist:
		# Reached the original target distance. Before despawning, make
		# sure the orb's declared primary target eats damage even if it
		# was bypassed in flight (wobble offset, target moved between
		# fire and arrival, or the target was at the very end of the
		# line and the perpendicular wobble carried the orb past it).
		# Without this guarantee, plasma weapons routinely deal zero
		# damage to their main target (error report 644).
		_apply_primary_target_guaranteed_hit()
		# Apply impact VFX + implosion AoE at the final position + despawn.
		_spawn_impact_flash(global_position)
		queue_free()
		return

	var base_pos: Vector3 = _from_pos + _travel_dir * traveled
	# Sin-wave wobble in two perpendicular axes — the offset traces a
	# slow figure-8 around the straight-line path.
	var wob_t: float = _wobble_phase + _life * WOBBLE_HZ * TAU
	var wob_a: float = sin(wob_t) * WOBBLE_AMPLITUDE
	var wob_b: float = sin(wob_t * 1.37 + 0.7) * WOBBLE_AMPLITUDE * 0.6
	# Slight forward-axis jitter so the orb stutter-flies instead of
	# perfectly maintaining its travel rate.
	var fwd_jitter: float = sin(wob_t * 2.1 + 1.3) * 0.18
	global_position = base_pos \
		+ _perp_a * wob_a \
		+ _perp_b * wob_b \
		+ _travel_dir * fwd_jitter

	# Visual pulse — scale + emission energy ride a sin wave so the
	# orb looks like an unstable charge, not a static decal.
	var pulse_t: float = _wobble_phase + _life * SCALE_PULSE_HZ * TAU
	var pulse: float = 1.0 + sin(pulse_t) * SCALE_PULSE_AMP
	scale = Vector3(pulse, pulse, pulse)
	if _orb_material:
		_orb_material.emission_energy_multiplier = 4.0 + sin(pulse_t * 1.3) * 1.2
	if _glow_material:
		_glow_material.emission_energy_multiplier = 2.0 + sin(pulse_t * 0.8) * 0.6

	# Piercing damage check — any enemy unit / building within
	# HIT_RADIUS of the orb takes payload damage (once per flight).
	_apply_piercing_damage()


func _apply_piercing_damage() -> void:
	## Iterates units + buildings groups, applies damage to any whose
	## centre is within HIT_RADIUS of the orb's current position AND
	## belongs to a hostile owner. Dedupe via _hit_set so one orb can
	## chain through a line of enemies but never re-tags the same one.
	var scene_tree: SceneTree = get_tree()
	if scene_tree == null:
		return
	# Re-validate the stored shooter every tick — a plasma orb can
	# outlive its shooter (4 s lifetime cap, orb keeps flying after
	# squad death) and passing a freed Object into Building.take_damage
	# crashes the typed-arg check (error report 644).
	var shooter_arg: Node3D = _shooter if (_shooter != null and is_instance_valid(_shooter)) else null
	# Hit anything in the units group first — squads are the common
	# case and we want to score them even when their bounding sphere
	# overlaps the orb earlier than a building's centre.
	for node: Node in scene_tree.get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var iid: int = node.get_instance_id()
		if _hit_set.has(iid):
			continue
		if not _is_hostile(node):
			continue
		var n3: Node3D = node as Node3D
		if n3 == null:
			continue
		if n3.global_position.distance_to(global_position) > HIT_RADIUS + _unit_pad_radius(node):
			continue
		_hit_set[iid] = true
		if node.has_method("take_damage"):
			node.call("take_damage", _payload_damage, shooter_arg)
	# Buildings — same rule, slightly larger pad radius because
	# building footprints are bigger than unit hitboxes.
	for node: Node in scene_tree.get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var iid: int = node.get_instance_id()
		if _hit_set.has(iid):
			continue
		if not _is_hostile(node):
			continue
		var n3: Node3D = node as Node3D
		if n3 == null:
			continue
		# Use the building's footprint XZ extent for the pad — much
		# larger than a unit hitbox.
		var pad: float = 1.2
		if "stats" in node and node.get("stats") != null:
			var stats: Resource = node.get("stats") as Resource
			if stats and "footprint_size" in stats:
				var fs: Vector3 = stats.get("footprint_size") as Vector3
				pad = maxf(fs.x, fs.z) * 0.5
		if n3.global_position.distance_to(global_position) > HIT_RADIUS + pad:
			continue
		_hit_set[iid] = true
		if node.has_method("take_damage"):
			node.call("take_damage", _payload_damage, shooter_arg)


func _is_hostile(node: Node) -> bool:
	## True when node belongs to a player on a different team from the
	## shooter. Resolved via PlayerRegistry when present; falls back to
	## "anything not owned by us" for headless scenes.
	if not ("owner_id" in node):
		return false
	var their_oid: int = node.get("owner_id") as int
	if their_oid == _shooter_owner_id:
		return false
	var scene_root: Node = get_tree().current_scene if get_tree() else null
	var registry: Node = scene_root.get_node_or_null("PlayerRegistry") if scene_root else null
	if registry and registry.has_method("are_enemies"):
		return registry.call("are_enemies", _shooter_owner_id, their_oid) as bool
	# Fallback — assume non-self is hostile.
	return true


func _unit_pad_radius(node: Node) -> float:
	## Approximate hit-pad radius for a unit. Units carry their squad
	## footprint via the unit's class shape; we don't have direct
	## access here, so just use a flat per-unit-class pad that's
	## comfortably larger than the visible mech model.
	if "stats" in node and node.get("stats") != null:
		var stats: Resource = node.get("stats") as Resource
		if stats and "unit_class" in stats:
			match stats.get("unit_class"):
				&"engineer": return 0.45
				&"light": return 0.55
				&"medium": return 0.75
				&"heavy": return 1.10
				&"apex": return 1.40
				&"aircraft": return 0.85
				_: return 0.65
	return 0.65


## How far the primary target is allowed to have drifted from the orb's
## fire-time aim point and still count as a "didn't dodge" hit. Set
## just over a typical squad's per-frame drift so a stationary target
## (including stand-and-fire combatants in the 2 s engagement lockout)
## always eats the backstop, while a target that ran a meaningful
## distance gets to escape — plasma is supposed to stay dodgeable.
## Numbers: light unit at 9 u/s moves ~13 u over a max-range plasma
## flight (~1.5 s), so anything past PRIMARY_HIT_MAX_DRIFT is clearly
## "moved out of the way". 2.0 u captures the wobble + footprint
## overlap a stationary target should never escape but excludes any
## meaningful evasive motion.
const PRIMARY_HIT_MAX_DRIFT: float = 2.0


func _apply_primary_target_guaranteed_hit() -> void:
	## End-of-flight backstop: if the orb was fired with a declared
	## primary target, that target is still alive, hasn't been scored
	## already by the piercing pass, AND hasn't moved meaningfully
	## from the orb's fire-time aim point, apply full payload damage
	## now. This patches the "orb wobbles past a stationary mesh and
	## fizzles" case (error report 644) without removing dodgeability
	## — a target that actually moves out of the way still survives.
	if _primary_target_iid == 0:
		return
	if _hit_set.has(_primary_target_iid):
		return
	var target: Node = instance_from_id(_primary_target_iid) as Node
	if target == null or not is_instance_valid(target):
		return
	# Confirm the target is still alive — squads track this via
	# alive_count, single-entity targets (buildings) just need
	# is_instance_valid.
	if "alive_count" in target and (target.get("alive_count") as int) <= 0:
		return
	if not target.has_method("take_damage"):
		return
	# Dodge check: how far is the target from the orb's original aim
	# point? _to_pos was lifted by +0.6 on Y at fire time, so compare
	# in the horizontal plane and ignore Y drift (units bob, aircraft
	# fly at altitude — neither counts as dodging).
	var target3: Node3D = target as Node3D
	if target3 == null:
		return
	var aim_xz: Vector2 = Vector2(_to_pos.x, _to_pos.z)
	var tgt_xz: Vector2 = Vector2(target3.global_position.x, target3.global_position.z)
	# Buildings have large footprints — count any part of the footprint
	# overlapping the aim circle as a hit. Without this big structures
	# would "dodge" by virtue of their centre being further from aim
	# than their edge.
	var drift_allowance: float = PRIMARY_HIT_MAX_DRIFT
	if "stats" in target and target.get("stats") != null:
		var ts: Resource = target.get("stats") as Resource
		if ts and "footprint_size" in ts:
			var fs: Vector3 = ts.get("footprint_size") as Vector3
			drift_allowance += maxf(fs.x, fs.z) * 0.5
	if aim_xz.distance_to(tgt_xz) > drift_allowance:
		return  # Target moved out of the way — let the dodge stand.
	var shooter_arg: Node3D = _shooter if (_shooter != null and is_instance_valid(_shooter)) else null
	_hit_set[_primary_target_iid] = true
	target.call("take_damage", _payload_damage, shooter_arg)


func _spawn_impact_flash(pos: Vector3) -> void:
	## End-of-flight VFX — uses the standard ParticleEmitterManager
	## flash with a cool blue palette so the impact reads as plasma
	## rather than a generic explosion. Also applies a small AoE
	## implosion damage burst so the player sees the orb dissipate
	## with a kick instead of just fizzling.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return
	var pem: Node = scene.get_node_or_null("ParticleEmitterManager")
	if pem != null and pem.has_method("emit_flash"):
		pem.call("emit_flash", pos, Color(0.55, 0.80, 1.00, 0.95))
	# Implosion AoE — anything hostile within IMPLOSION_RADIUS of the
	# impact point takes IMPLOSION_DMG_FRAC of the orb's full payload.
	# Dedupe against _hit_set so targets the orb already pierced en
	# route don't double-eat the implosion on the same flight.
	var shooter_arg: Node3D = _shooter if (_shooter != null and is_instance_valid(_shooter)) else null
	var burst: int = maxi(int(float(_payload_damage) * IMPLOSION_DMG_FRAC), 1)
	var r2: float = IMPLOSION_RADIUS * IMPLOSION_RADIUS
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var iid: int = node.get_instance_id()
		if _hit_set.has(iid):
			continue
		if not _is_hostile(node):
			continue
		var n3: Node3D = node as Node3D
		if n3 == null:
			continue
		if n3.global_position.distance_squared_to(pos) > r2:
			continue
		if node.has_method("take_damage"):
			node.call("take_damage", burst, shooter_arg)
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var biid: int = node.get_instance_id()
		if _hit_set.has(biid):
			continue
		if not _is_hostile(node):
			continue
		var n3b: Node3D = node as Node3D
		if n3b == null:
			continue
		if n3b.global_position.distance_squared_to(pos) > r2:
			continue
		if node.has_method("take_damage"):
			node.call("take_damage", burst, shooter_arg)
