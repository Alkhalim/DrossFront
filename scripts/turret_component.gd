class_name TurretComponent
extends Node
## Attaches to a Building. Auto-attacks enemies in range.
##
## Each turret has a profile (`balanced`, `anti_light`, `anti_heavy`, `anti_air`)
## chosen at runtime. Profile values drive damage, fire rate, range, and the
## projectile's role tag; the building rebuilds its visual barrel to match.

const SEARCH_INTERVAL: float = 0.5
## How fast the turret swings to face its target, in lerp factor per second.
const TURRET_TURN_SPEED: float = 5.0

## Backwards-compatible defaults so external code can still read these.
## Damage values were 3x'd (was 15) — turrets read as a real defensive
## investment now instead of chip-damage emitters.
const TURRET_RANGE: float = 20.0
const TURRET_DAMAGE: int = 45
const FIRE_INTERVAL: float = 0.8

## Profile presets. Keep keys stable — HUD code references them by name.
## Damage values are 3x the original tuning so static defenses can actually
## threaten an attacking squad rather than tickle it.
##
## anti_air stays in PROFILES because the SAM Site uses the same component
## with profile preset to anti_air (no UI swap; it's a dedicated AA building).
## The HUD's profile selector lists only the ground profiles below.
const PROFILES: Dictionary = {
	&"balanced":   { "damage": 45,  "fire": 0.9,  "range": 20.0, "role": &"Universal", "name": "Balanced" },
	&"anti_light": { "damage": 24,  "fire": 0.3,  "range": 18.0, "role": &"AP",        "name": "Anti-Light" },
	&"anti_heavy": { "damage": 135, "fire": 2.2,  "range": 22.0, "role": &"AP",        "name": "Anti-Heavy" },
	&"anti_air":   { "damage": 36,  "fire": 0.25, "range": 24.0, "role": &"AAir",      "name": "Anti-Air" },
	# Built-in HQ self-defense -- light Universal MG cluster meant
	# to discourage early bumrushes. Range bumped 16 -> 22 so the
	# HQ outranges short + medium-tier mech weapons (8u / 15u),
	# giving the defender breathing room against light pushes.
	# Burst fires `burst_count` projectiles per cooldown (with
	# brief intra-burst gaps for the visual stagger) so the salvo
	# reads as a real MG nest, not single-tap shots. Targets both
	# ground AND air -- HQ MGs work as light flak.
	&"hq_defense": { "damage": 19, "fire": 1.1, "range": 28.0, "role": &"Universal", "name": "HQ Defense", "burst_count": 5, "burst_gap": 0.08, "targets_air": true },
}

## Anvil's industrial-doctrine turret hits harder than the baseline
## emplacement. +15% damage on every profile; HP bonus lives on the
## building's stats (Anvil .tres has hp 932, baseline has 810).
const ANVIL_DAMAGE_MULT: float = 1.15

var profile: StringName = &"balanced"

## When set, overrides the parent building's shared `turret_pivot`
## field. Lets a single building host multiple independent
## TurretComponents (each with its own pivot) -- used by HQ corner
## MG nests so all four corners track + fire individually instead
## of all reading the same pivot. Falls back to building.turret_pivot
## when null.
var pivot_override: Node3D = null
## Idle rotation for the pivot. Captured from the pivot's
## rotation.y the first time _process runs so we don't depend on
## construction order. When _target is null the component lerps
## back to this rotation -- HQ corner MG nests then point
## outwards at rest instead of frozen on the last engagement angle.
var _idle_pivot_rotation_y: float = 0.0
var _idle_rotation_captured: bool = false

var _building: Node = null
var _target: Node3D = null
var _fire_timer: float = 0.0
var _search_timer: float = 0.0
## Cached scene-level singletons. The targeting + validation paths
## fetched PlayerRegistry from the scene tree on every call -- a
## measurable cost across many active turrets at high fire rates.
var _registry_cached: PlayerRegistry = null
var _scene_cached: Node = null


func _get_registry_cached() -> PlayerRegistry:
	if _registry_cached and is_instance_valid(_registry_cached):
		return _registry_cached
	if not _scene_cached or not is_instance_valid(_scene_cached):
		_scene_cached = get_tree().current_scene if get_tree() else null
	if _scene_cached:
		_registry_cached = _scene_cached.get_node_or_null("PlayerRegistry") as PlayerRegistry
	return _registry_cached


func _ready() -> void:
	_building = get_parent()
	# Apply the visual barrel matching the default profile.
	_apply_visual_profile()


func _building_id() -> StringName:
	if not _building:
		return &""
	var s: Resource = _building.get("stats") as Resource
	if not s:
		return &""
	return s.get("building_id") as StringName


func _damage_multiplier() -> float:
	## Anvil's specialised emplacement deals +15% damage on every
	## profile. Sable's basic emplacement and the SAM Site use the
	## raw profile damage.
	return ANVIL_DAMAGE_MULT if _building_id() == &"gun_emplacement" else 1.0


func is_profile_swap_allowed() -> bool:
	## Only Anvil's specialised emplacement exposes profile selection
	## in the HUD. Sable's basic turret is fixed at the baseline
	## ground role; the SAM Site is fixed at anti_air.
	return _building_id() == &"gun_emplacement"


## Anvil HQ Battery upgrade -- when the parent HQ has hq_battery_active
## true, the built-in defensive turret hits ~50% harder and reaches
## ~25% further. Only the hq_defense profile honors it; standard
## emplacements ignore the flag because the upgrade is HQ-bound.
const HQ_BATTERY_DAMAGE_MULT: float = 1.5
const HQ_BATTERY_RANGE_BONUS: float = 4.0


func _hq_battery_active() -> bool:
	return profile == &"hq_defense" and _building != null and bool(_building.get("hq_battery_active"))


func get_damage() -> int:
	var base: int = (PROFILES[profile] as Dictionary).get("damage", TURRET_DAMAGE) as int
	var dmg: float = float(base) * _damage_multiplier()
	if _hq_battery_active():
		dmg *= HQ_BATTERY_DAMAGE_MULT
	return int(round(dmg))


func get_fire_interval() -> float:
	return (PROFILES[profile] as Dictionary).get("fire", FIRE_INTERVAL) as float


func get_range() -> float:
	var base: float = (PROFILES[profile] as Dictionary).get("range", TURRET_RANGE) as float
	if _hq_battery_active():
		base += HQ_BATTERY_RANGE_BONUS
	return base


func get_role() -> StringName:
	return (PROFILES[profile] as Dictionary).get("role", &"Universal") as StringName


func get_dps() -> float:
	var fi: float = get_fire_interval()
	if fi <= 0.0:
		return 0.0
	return float(get_damage()) / fi


func set_profile(new_profile: StringName) -> void:
	if not PROFILES.has(new_profile):
		return
	profile = new_profile
	_target = null
	_fire_timer = 0.0
	_apply_visual_profile()


func _apply_visual_profile() -> void:
	if _building and _building.has_method("rebuild_turret_visual"):
		_building.rebuild_turret_visual(profile)


## Half-frame stagger so 16+ HQ corner MGs + standalone turrets
## don't all tick at 60Hz. The fire / search timers tick at the
## doubled delta on heavy frames so cadence stays identical.
var _turret_phys_frame: int = 0


func _process(delta: float) -> void:
	if not _building or not _building.get("is_constructed"):
		return
	# Stagger heavy work to ~30Hz; phase tied to instance id so a
	# base of corner MGs spreads across alternating frames instead
	# of all firing on the same physics tick.
	_turret_phys_frame += 1
	if (_turret_phys_frame & 1) != (get_instance_id() & 1):
		return
	delta *= 2.0

	_fire_timer -= delta
	_search_timer -= delta

	# Capture the pivot's authored rotation the first time we run --
	# that's the "idle" / outward-facing pose set by the building's
	# detail script (e.g. HQ corner nests aim outwards at construct
	# time). When idle we lerp the pivot back to this rotation.
	if not _idle_rotation_captured:
		var pivot_init: Node3D = _resolve_pivot()
		if pivot_init and is_instance_valid(pivot_init):
			_idle_pivot_rotation_y = pivot_init.rotation.y
			_idle_rotation_captured = true

	# Validate target
	if _target and not _is_valid_target(_target):
		_target = null

	# Search for targets
	if not _target and _search_timer <= 0.0:
		_search_timer = SEARCH_INTERVAL
		_target = _find_nearest_enemy()

	if not _target:
		# Idle -- ease the pivot back to its outward-facing pose.
		_relax_to_idle(delta)
		return

	# Slew the turret pivot toward the target before firing.
	_aim_at_target(delta)

	# Fire
	if _fire_timer <= 0.0:
		_fire_timer = get_fire_interval()

		# Apply power efficiency
		var efficiency: float = 1.0
		if _building.has_method("get_power_efficiency"):
			efficiency = _building.get_power_efficiency()
		_fire_timer /= maxf(efficiency, 0.1)

		var damage: int = maxi(int(float(get_damage()) * efficiency), 1)

		# Burst-fire support. profile_dict.burst_count > 1 schedules
		# extra shots after the initial one with burst_gap seconds
		# between them, so HQ MG nests fire a 3-round salvo per
		# cooldown instead of a single tap.
		var profile_dict: Dictionary = PROFILES[profile] as Dictionary
		var burst_count: int = int(profile_dict.get("burst_count", 1))
		var burst_gap: float = float(profile_dict.get("burst_gap", 0.0))

		# Initial shot lands now.
		_fire_one_shot(damage)
		# Trailing shots scheduled via SceneTreeTimer so the salvo
		# stagger is independent of the per-process tick rate.
		for i in range(1, burst_count):
			var delay: float = burst_gap * float(i)
			get_tree().create_timer(delay).timeout.connect(_fire_one_shot.bind(damage))


func _fire_one_shot(damage: int) -> void:
	## Single shot in a burst -- damage + projectile + audio. Validates
	## the target each call so a target dying mid-salvo just drops
	## the trailing shots silently instead of crashing.
	if not _target or not is_instance_valid(_target):
		return
	if not _is_valid_target(_target):
		return
	# HQ-defense per-class profile per balance brief:
	#   vs light       1.0
	#   vs medium      0.7
	#   vs heavy       0.4
	#   vs light_air   1.0
	#   vs heavy_air   0.4
	# AA branch caps at ~45% of AG DPS (an HQ is a deterrent
	# against air, not a flak battery). With damage=18 + burst 3 /
	# fire 1.0 = 54 ground DPS, the AA branch's 0.45 base scales to
	# ~24 AA DPS before per-class mults. Both factions share this
	# profile via the same _detail_hq_defense_turret build path.
	var final_damage: int = damage
	if profile == &"hq_defense":
		var target_armor: StringName = _resolve_target_armor(_target)
		var base_dmg: float = float(damage)
		var mult: float = 1.0
		match target_armor:
			&"light":
				mult = 1.0
			&"medium":
				mult = 0.7
			&"heavy":
				mult = 0.4
			&"structure":
				mult = 0.3
			&"light_air":
				base_dmg = float(damage) * 0.45
				mult = 1.0
			&"heavy_air":
				base_dmg = float(damage) * 0.45
				mult = 0.4
			_:
				mult = 0.7
		final_damage = int(round(base_dmg * mult))
	_target.take_damage(final_damage, _building as Node3D)

	var observable: bool = _firing_observable()
	if not observable:
		return
	var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
	if proj_script:
		var fire_origin: Vector3 = _building.global_position + Vector3(0.0, 2.0, 0.0)
		var pivot_n3d: Node3D = _resolve_pivot()
		if pivot_n3d and is_instance_valid(pivot_n3d):
			fire_origin = pivot_n3d.global_position
		# Prefer a 'Muzzle' Marker3D child of the pivot if the building
		# detail layer placed one (HQ MG nests, gun emplacement barrels)
		# so tracers leave from the barrel tip instead of the pivot
		# centre. Falls through to the pivot's own world position.
		if pivot_n3d:
			var muzzle: Node3D = pivot_n3d.get_node_or_null("Muzzle") as Node3D
			if muzzle:
				fire_origin = muzzle.global_position
		var building_faction: int = 0
		if _building and _building.has_method("_resolve_faction_id"):
			building_faction = _building.call("_resolve_faction_id") as int
		var proj: Node3D = proj_script.create(
			fire_origin,
			_target.global_position,
			get_role(),
			&"moderate",
			&"",
			building_faction,
		)
		get_tree().current_scene.add_child(proj)
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_fire"):
		var sfx_pos: Vector3 = _building.global_position
		var pivot_n3d2: Node3D = _resolve_pivot()
		if pivot_n3d2 and is_instance_valid(pivot_n3d2):
			sfx_pos = pivot_n3d2.global_position
		audio.play_weapon_fire(null, sfx_pos)


func _firing_observable() -> bool:
	## True when the local player can currently see either the firing
	## turret or its target. Skips projectile spawn + fire sound when
	## an off-screen turret duels with an off-screen target.
	var fow: Node = get_tree().current_scene.get_node_or_null("FogOfWar") if get_tree() else null
	if not fow or not fow.has_method("is_visible_world"):
		return true
	if _building and is_instance_valid(_building):
		if fow.call("is_visible_world", _building.global_position):
			return true
	if _target and is_instance_valid(_target):
		if fow.call("is_visible_world", _target.global_position):
			return true
	return false


func _find_nearest_enemy() -> Node3D:
	var my_owner: int = _building.get("owner_id")
	var my_pos: Vector3 = _building.global_position
	var range_v: float = get_range()
	var nearest: Node3D = null
	var nearest_dist: float = INF
	var registry: PlayerRegistry = _get_registry_cached()
	# Targeting filter:
	#  - AAir profile (SAM Site, etc): air-only.
	#  - Profiles with targets_air = true (HQ MG nests): both air
	#    AND ground.
	#  - Everything else: ground-only.
	var is_aa: bool = get_role() == &"AA" or get_role() == &"AAir" or profile == &"anti_air"
	var profile_dict: Dictionary = PROFILES[profile] as Dictionary
	var dual_purpose: bool = bool(profile_dict.get("targets_air", false))

	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not node.has_method("take_damage"):
			continue
		var target_owner: int = node.get("owner_id")
		var hostile: bool = (registry.are_enemies(my_owner, target_owner)
			if registry
			else target_owner != my_owner)
		if not hostile:
			continue
		if "alive_count" in node and node.get("alive_count") <= 0:
			continue
		var target_is_air: bool = node.is_in_group("aircraft")
		# Air-only turrets ignore ground; ground-only turrets ignore air;
		# dual-purpose turrets engage either.
		if is_aa and not target_is_air:
			continue
		if not is_aa and not dual_purpose and target_is_air:
			continue
		var d: float = my_pos.distance_to(node.global_position)
		if d <= range_v and d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D

	return nearest


## Idle-scan state. Every few seconds the turret picks a fresh random
## yaw offset around its captured idle rotation and slowly slews to
## it, so a defended position visibly scans the horizon instead of
## standing perfectly still until something walks into range.
var _idle_scan_target_y: float = 0.0
var _idle_scan_timer: float = 0.0
var _idle_scan_initialized: bool = false
const IDLE_SCAN_RANGE_RAD: float = 0.8     # ~46 degrees off-axis sweep
const IDLE_SCAN_INTERVAL_MIN: float = 3.5
const IDLE_SCAN_INTERVAL_MAX: float = 6.5


func _resolve_target_armor(target: Node3D) -> StringName:
	## Reads the target's armor_class via its UnitStatResource. Falls
	## through to "structure" for buildings (structures share that
	## armor class in CombatTables) so the HQ-defense bonus check
	## doesn't accidentally flag a building as light-armored.
	if not target or not is_instance_valid(target):
		return &"medium"
	if "stats" in target:
		var ts: Variant = target.get("stats")
		if typeof(ts) == TYPE_OBJECT and is_instance_valid(ts):
			var unit_stats: UnitStatResource = ts as UnitStatResource
			if unit_stats:
				return unit_stats.armor_class
	if target is Building:
		return &"structure"
	return &"medium"


func _relax_to_idle(delta: float) -> void:
	## Slow random horizon-scan around the captured idle rotation.
	## Picks a new target yaw every IDLE_SCAN_INTERVAL_*; in between,
	## eases the pivot toward that target with the relaxed turn rate.
	## Reads as "the turret is paying attention" rather than staring
	## at a fixed compass point.
	if not _idle_rotation_captured:
		return
	var pivot: Node3D = _resolve_pivot()
	if not pivot or not is_instance_valid(pivot):
		return
	# First call -- jitter the initial timer + seed a target so all
	# turrets don't sweep in lockstep.
	if not _idle_scan_initialized:
		_idle_scan_initialized = true
		_idle_scan_target_y = _idle_pivot_rotation_y
		_idle_scan_timer = randf_range(0.5, IDLE_SCAN_INTERVAL_MAX)
	_idle_scan_timer -= delta
	if _idle_scan_timer <= 0.0:
		_idle_scan_timer = randf_range(IDLE_SCAN_INTERVAL_MIN, IDLE_SCAN_INTERVAL_MAX)
		_idle_scan_target_y = _idle_pivot_rotation_y + randf_range(-IDLE_SCAN_RANGE_RAD, IDLE_SCAN_RANGE_RAD)
	pivot.rotation.y = lerp_angle(pivot.rotation.y, _idle_scan_target_y, clampf(TURRET_TURN_SPEED * 0.4 * delta, 0.0, 1.0))


func _aim_at_target(delta: float) -> void:
	## Rotate this turret's pivot around Y to face the current target.
	## Reads pivot_override when set (HQ corner nests each have their
	## own); falls back to building.turret_pivot. The pivot is parented
	## under the building's VisualRoot, which itself has a slight
	## randomized Y rotation per building, so we have to subtract that
	## parent rotation when computing the local target angle.
	var pivot: Node3D = _resolve_pivot()
	if not pivot or not is_instance_valid(pivot):
		return
	# Aim from the actual pivot world-position rather than the building
	# centre so corner turrets (HQ nests) track relative to where they
	# physically sit on the structure.
	var to_target: Vector3 = _target.global_position - pivot.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return
	# atan2(x, z) + PI gives the world Y rotation aligning local -Z with the
	# target.
	var target_y_world: float = atan2(to_target.x, to_target.z) + PI
	var compensation: float = 0.0
	var parent_root: Node = pivot.get_parent()
	if parent_root and parent_root is Node3D:
		compensation = (parent_root as Node3D).rotation.y
	var target_y_local: float = target_y_world - compensation
	pivot.rotation.y = lerp_angle(pivot.rotation.y, target_y_local, clampf(TURRET_TURN_SPEED * delta, 0.0, 1.0))


func _resolve_pivot() -> Node3D:
	if pivot_override and is_instance_valid(pivot_override):
		return pivot_override
	if not _building:
		return null
	return _building.get("turret_pivot") as Node3D


func _is_valid_target(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	if not target.has_method("take_damage"):
		return false
	var my_owner: int = _building.get("owner_id")
	var target_owner: int = target.get("owner_id")
	var registry: PlayerRegistry = _get_registry_cached()
	var hostile: bool = (registry.are_enemies(my_owner, target_owner)
		if registry
		else target_owner != my_owner)
	if not hostile:
		return false
	if "alive_count" in target and target.get("alive_count") <= 0:
		return false
	var d: float = _building.global_position.distance_to(target.global_position)
	return d <= get_range()
