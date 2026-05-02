class_name CombatComponent
extends Node
## Handles targeting, weapon firing, and damage calculation for a unit.
## Attached as a child of Unit by Unit._ready().

var _unit: Node = null  # Parent Unit — accessed via duck typing to avoid class resolution issues
var _current_target: Node3D = null
var _fire_cooldown: float = 0.0
var _secondary_cooldown: float = 0.0
var _search_timer: float = 0.0
## Cached PlayerRegistry — used to ask "is my owner allied with this owner?"
## instead of comparing raw owner_ids. Falls back to the raw compare when
## the registry isn't present, so headless / test scenes keep working.
var _registry: PlayerRegistry = null

## Burst-fire state for high-RoF weapons. Counts shots within the current
## burst; once the burst is full the cooldown is bumped up so the average
## shots-per-second matches the underlying ROF tier.
var _burst_count: int = 0

## Half-frame stagger phase. Combat targeting and firing run at ~30 Hz
## per unit instead of 60 Hz — fire cooldowns are tenths of a second at
## fastest, target search is throttled to 0.5s, and the player can't tell
## a one-frame delay on muzzle flash. Halves CombatComponent CPU cost.
var _phys_frame: int = 0
var _phase: int = 0

const SEARCH_INTERVAL: float = 0.5

## Weapons whose ROF is at or below this threshold (seconds between shots)
## switch to a burst pattern so they don't read as a metronome.
const BURST_THRESHOLD: float = 0.3
const BURST_SHOTS: int = 3
const BURST_INTRA_DELAY: float = 0.06

## Idle units engage enemies up to this multiple of weapon range — they'll
## advance into firing range instead of standing still while an enemy is in sight.
## Kept tight so units don't aggressively chase distant threats.
const ENGAGE_RANGE_MULT: float = 1.35

## Explicit attack target set by player command, by retaliation, or by idle
## auto-engagement. The unit will pursue this target into weapon range and stop
## once close enough to fire.
var forced_target: Node3D = null

## Attack-move destination. Vector3.INF = not attack-moving.
var attack_move_target: Vector3 = Vector3.INF


func _ready() -> void:
	_unit = get_parent()
	_registry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	# Round-robin half-frame stagger across the combat fleet. Fire
	# cadence is well above 30 Hz (~3-10 shots/s at peak) so a 30 Hz
	# combat tick is invisible.
	_phase = int(get_instance_id() & 1)


func _is_hostile(my_owner: int, target_owner: int) -> bool:
	# Single shape used by the targeting and validation paths so a future
	# alliance change (gifting / treason / 2v2 ally betrayal) only has to
	# touch the registry rule.
	#
	# Lazy-fetch the registry — pre-placed units in the .tscn ready up
	# before TestArenaController calls `_setup_player_registry`, leaving
	# `_registry` null at first physics tick. Without this fallback, the
	# `!= my_owner` rule treats 2v2 allies as enemies and the squad
	# auto-targets its own ally.
	if not _registry:
		var scene: Node = get_tree().current_scene if get_tree() else null
		if scene:
			_registry = scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	if _registry:
		return _registry.are_enemies(my_owner, target_owner)
	return target_owner != my_owner


func _physics_process(delta: float) -> void:
	if not _unit or not _unit.get("stats"):
		return
	var alive: int = _unit.get("alive_count")
	if alive <= 0:
		return

	# Half-frame stagger — only run heavy targeting / fire logic on
	# the assigned phase. Cooldowns advance via the doubled delta so
	# fire rate is identical to an un-staggered tick.
	_phys_frame += 1
	if (_phys_frame & 1) != _phase:
		return
	delta *= 2.0

	_fire_cooldown -= delta
	_secondary_cooldown -= delta
	_search_timer -= delta

	var unit_has_move_order: bool = _unit.get("has_move_order") as bool

	# Forced target wins. If it's gone or dead, drop it.
	if forced_target and not _is_valid_target(forced_target):
		forced_target = null
	if forced_target:
		_current_target = forced_target
	elif _current_target and not _is_valid_target(_current_target):
		_current_target = null

	# Auto-acquire targets: allowed when idle, or during attack-move. We scan a
	# wider engage range than the weapon range so an idle unit will move toward
	# an enemy that's in sight but just out of range, rather than ignoring it.
	# Stand-ground units skip this — they shoot what walks into actual
	# range but don't hunt.
	var holding: bool = bool(_unit.get("is_holding_position"))
	var can_auto_target: bool = (not unit_has_move_order or attack_move_target != Vector3.INF) and not holding
	if not _current_target and can_auto_target and _search_timer <= 0.0:
		_search_timer = SEARCH_INTERVAL
		var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
		var weapon_range: float = 10.0
		if stats and stats.primary_weapon:
			weapon_range = CombatTables.get_range(stats.primary_weapon.range_tier)
		var engage_radius: float = weapon_range * ENGAGE_RANGE_MULT
		# Patrol units (any unit with a `home_position` set) get a -20%
		# aggro multiplier so a careful player can sneak past them
		# without triggering a fight.
		var home: Variant = _unit.get("home_position")
		var is_patrol: bool = (home is Vector3) and (home as Vector3) != Vector3.INF
		if is_patrol:
			engage_radius *= 0.8
		var found: Node3D = _find_nearest_enemy(engage_radius)
		if found:
			# Promote to forced_target so the unit will close the distance even
			# if the enemy starts outside weapon range.
			forced_target = found
			_current_target = found

	if not _current_target:
		# Reset the burst counter so a half-finished burst from the previous
		# target doesn't bleed into the next engagement.
		_burst_count = 0
		# If attack-move and arrived, stay put and keep scanning
		if attack_move_target != Vector3.INF:
			if _unit.get("move_target") == Vector3.INF:
				# Arrived at attack-move destination — keep scanning
				pass
		# Patrol return-to-home: if this unit has a home position and no
		# current target, send it back home so it doesn't drift across
		# the map after a brief chase ends.
		var home_var: Variant = _unit.get("home_position")
		if home_var is Vector3 and (home_var as Vector3) != Vector3.INF:
			var home_pos: Vector3 = home_var as Vector3
			if not unit_has_move_order:
				var d_home: float = _unit.global_position.distance_to(home_pos)
				if d_home > 2.5:
					if _unit.has_method("command_move"):
						_unit.command_move(home_pos, false)
		return

	var dist: float = _unit.global_position.distance_to(_current_target.global_position)
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	var primary: WeaponResource = stats.primary_weapon
	var primary_range: float = CombatTables.get_range(primary.range_tier) if primary else 10.0

	if dist <= primary_range:
		# In range: stop and engage. We always stop here because the only way
		# we reach this branch is when we have a target (forced or auto-acquired
		# during attack-move) — the unit's current move order, if any, was
		# either issued by us to chase, or part of an attack-move that should
		# halt to fire. Plain player move orders never auto-acquire targets.
		_unit.stop()

		_face_target()

		if primary and _fire_cooldown <= 0.0:
			_fire_weapon(primary, true)

		if stats.secondary_weapon and _secondary_cooldown <= 0.0:
			var sec_range: float = CombatTables.get_range(stats.secondary_weapon.range_tier)
			if dist <= sec_range:
				_fire_weapon(stats.secondary_weapon, false)
	else:
		# Out of range — chase if we have a forced target (player-set, retaliated,
		# or auto-engaged on sight). Pass `clear_combat=false` so command_move
		# doesn't wipe the very target we're chasing; that bug used to make
		# units walk all the way into melee before re-acquiring and firing.
		if forced_target:
			_unit.command_move(_current_target.global_position, false)


func set_target(target: Node3D) -> void:
	# Defensive: never accept an allied (or self-owned) target. The
	# selection_manager click-path already filters by PlayerRegistry, but
	# this guard covers attack-move sweeps and any future command that
	# might surface a target via set_target without re-checking hostility.
	if target and "owner_id" in target:
		var my_owner: int = _unit.owner_id if "owner_id" in _unit else 0
		if not _is_hostile(my_owner, target.get("owner_id") as int):
			return
	forced_target = target
	_current_target = target
	attack_move_target = Vector3.INF


func clear_target() -> void:
	## Called by Unit.command_move on a player-issued move. Wipe ALL combat
	## state — including attack_move_target — so a stale attack-move from a
	## previous command can't slip through and let notify_attacked retaliate
	## during the plain move.
	forced_target = null
	_current_target = null
	attack_move_target = Vector3.INF


func command_attack_move(pos: Vector3) -> void:
	attack_move_target = pos
	forced_target = null
	_current_target = null
	# Move without clearing combat state (bypass command_move's clear_target)
	_unit.move_target = pos
	_unit.move_target.y = _unit.global_position.y
	_unit.has_move_order = true
	if _unit.has_method("_nav_agent") or "_nav_agent" in _unit:
		var nav: NavigationAgent3D = _unit.get("_nav_agent") as NavigationAgent3D
		if nav:
			nav.target_position = pos


## --- Target Acquisition ---

func _find_nearest_enemy(max_range: float) -> Node3D:
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	if not stats or not stats.primary_weapon:
		return null

	var my_owner: int = _unit.get("owner_id")
	var my_pos: Vector3 = _unit.global_position

	var nearest: Node3D = null
	var nearest_dist: float = INF

	# Check enemy units
	var all_units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in all_units:
		if not node.has_method("take_damage"):
			continue
		var node_owner: int = node.get("owner_id")
		if not _is_hostile(my_owner, node_owner):
			continue
		var node_alive: int = node.get("alive_count")
		if node_alive <= 0:
			continue
		# V3 stealth — auto-target ignores stealth-capable units that
		# aren't currently revealed. The player can still manually
		# right-click them to engage; this only gates the autonomous
		# "find nearest enemy" pass.
		if "stealth_revealed" in node and not (node.get("stealth_revealed") as bool):
			var their_stats: UnitStatResource = node.get("stats") as UnitStatResource
			if their_stats and their_stats.is_stealth_capable:
				continue
		var d: float = my_pos.distance_to(node.global_position)
		if d <= max_range and d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D

	# Check enemy buildings
	var all_buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in all_buildings:
		if not node.has_method("take_damage"):
			continue
		# Auto-target opt-out — destructible neutral structures (ammo
		# dumps, etc.) sit in the "buildings" group so a right-click
		# can still target them, but the player shouldn't have squads
		# autonomously chip them down on patrol. Right-click → forced
		# target bypasses this list entirely.
		if "auto_targetable" in node and not node.get("auto_targetable"):
			continue
		var node_owner: int = node.get("owner_id")
		if not _is_hostile(my_owner, node_owner):
			continue
		var d: float = my_pos.distance_to(node.global_position)
		if d <= max_range and d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D

	return nearest


func notify_attacked(attacker: Node3D) -> void:
	## Called by Unit.take_damage when something shoots us. We respect the
	## player's current task: while the unit is executing a plain move order
	## (or a builder task, which also routes through has_move_order) we do
	## not retaliate. Use attack-move if you want en-route engagement.
	if not attacker or not is_instance_valid(attacker):
		return
	if not _is_valid_target(attacker):
		return

	# Already engaging something — switch ONLY if the current target
	# has run beyond practical engage range AND the new attacker is
	# well within range. Stops a unit from blindly chasing a fleeing
	# target while a closer threat shoots it in the back.
	if forced_target and is_instance_valid(forced_target):
		var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
		var weapon_range: float = 10.0
		if stats and stats.primary_weapon:
			weapon_range = CombatTables.get_range(stats.primary_weapon.range_tier)
		var my_pos: Vector3 = _unit.global_position
		var d_current: float = my_pos.distance_to(forced_target.global_position)
		var d_attacker: float = my_pos.distance_to(attacker.global_position)
		# Switch if attacker is inside weapon range AND current target
		# has drifted to >1.5× weapon range away. Otherwise keep the
		# original engagement.
		if d_attacker < weapon_range and d_current > weapon_range * 1.5:
			forced_target = attacker
			_current_target = attacker
		return

	var has_move_order: bool = _unit.get("has_move_order") as bool
	if has_move_order and attack_move_target == Vector3.INF:
		# Player-issued (or builder-issued) plain move is in progress.
		# Finish that command before fighting back.
		return
	forced_target = attacker
	_current_target = attacker


func _is_valid_target(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	if not target.has_method("take_damage"):
		return false
	var target_owner: int = target.get("owner_id")
	var my_owner: int = _unit.get("owner_id")
	if not _is_hostile(my_owner, target_owner):
		return false
	# Check if unit is still alive
	if "alive_count" in target:
		var alive: int = target.get("alive_count")
		if alive <= 0:
			return false
	return true


func _face_target() -> void:
	if not _current_target:
		return
	var look_pos: Vector3 = _current_target.global_position
	look_pos.y = _unit.global_position.y
	var to_target: Vector3 = look_pos - _unit.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return
	# Use the unit's turn-speed-aware slew so heavies feel sluggish here too.
	if _unit.has_method("_turn_toward"):
		_unit._turn_toward(to_target.normalized(), get_physics_process_delta_time())
	else:
		_unit.look_at(look_pos, Vector3.UP)


## --- Damage Calculation ---

func _fire_weapon(weapon: WeaponResource, is_primary: bool) -> void:
	if not weapon or not _current_target:
		return

	# Mesh strength bonus — V3 §Pillar 2. Sable units inside friendly
	# Mesh provider auras get faster reload (rof shrinks) AND higher
	# accuracy. Looked up via the scene-level MeshSystem singleton.
	var mesh_strength: int = 0
	var mesh_sys: Node = get_tree().current_scene.get_node_or_null("MeshSystem") if get_tree() else null
	if mesh_sys and mesh_sys.has_method("strength_for"):
		mesh_strength = mesh_sys.call("strength_for", _unit.global_position, _unit.get("owner_id") as int) as int
	var reload_factor: float = 1.0
	if mesh_sys and mesh_sys.has_method("reload_factor"):
		reload_factor = mesh_sys.call("reload_factor", mesh_strength) as float

	var rof: float = CombatTables.get_rof(weapon.rof_tier) * reload_factor
	if is_primary:
		# Burst pattern for very high RoF: BURST_SHOTS quick shots, then a
		# longer pause that keeps the average DPS the same.
		if rof <= BURST_THRESHOLD:
			_burst_count += 1
			if _burst_count >= BURST_SHOTS:
				_burst_count = 0
				# burst_period = rof * BURST_SHOTS, minus the intra-burst gaps
				# we already paid between shots.
				var long_pause: float = rof * float(BURST_SHOTS) - float(BURST_SHOTS - 1) * BURST_INTRA_DELAY
				_fire_cooldown = maxf(long_pause, BURST_INTRA_DELAY)
			else:
				_fire_cooldown = BURST_INTRA_DELAY
		else:
			_burst_count = 0
			_fire_cooldown = rof
	else:
		_secondary_cooldown = rof

	var base_damage: int = CombatTables.get_damage(weapon.damage_tier)
	var shots: int = _unit.get("alive_count")

	# Squad strength accuracy bonus
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	var accuracy: float = 1.0
	if stats.squad_strength_bonus > 0.0:
		var strength_ratio: float = _unit.get_squad_strength_ratio()
		accuracy += stats.squad_strength_bonus * strength_ratio
	# Mesh accuracy bonus — additive on top of squad-strength.
	if mesh_sys and mesh_sys.has_method("accuracy_bonus"):
		accuracy += mesh_sys.call("accuracy_bonus", mesh_strength) as float

	# Role vs armor modifier
	var target_armor: StringName = _get_target_armor()
	var role_mod: float = CombatTables.get_role_modifier(weapon.role_tag, target_armor)

	# Armor flat reduction
	var armor_reduction: float = CombatTables.get_armor_reduction(target_armor)

	# Directional modifier
	var dir_mod: float = CombatTables.get_directional_multiplier(
		_unit.global_position, _current_target
	)

	# High-ground bonus (V2 §"Map 1") — units firing from at least 0.4u
	# above their target deal 15% more damage. Threshold is just under
	# the 0.6u platform height so the bonus reads cleanly when standing
	# on an elevated piece without false-positives from squad bobbing.
	var elevation_mod: float = 1.0
	if _unit.global_position.y - _current_target.global_position.y >= 0.4:
		elevation_mod = 1.15

	# Per-member damage
	var damage_per_member: float = float(base_damage) * role_mod * dir_mod * elevation_mod * accuracy * (1.0 - armor_reduction)
	var per_member_dmg: int = maxi(int(damage_per_member), 1)

	# Fire one projectile per alive squad member, originating at the actual
	# barrel tip (falls back to chest-height if the unit has no cannons).
	var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
	var muzzle_positions: Array[Vector3] = []
	if _unit.has_method("get_muzzle_positions"):
		muzzle_positions = _unit.get_muzzle_positions()
	if muzzle_positions.is_empty() and _unit.has_method("get_member_positions"):
		muzzle_positions = _unit.get_member_positions()

	# Aim each projectile at a distinct enemy squad member rather than the
	# squad's averaged center, so volleys don't visually stack on a single
	# point and miss the outer formation members entirely.
	var target_positions: Array[Vector3] = []
	if _current_target.has_method("get_member_positions"):
		target_positions = _current_target.get_member_positions()

	# Shotgun-style weapons fire a cluster of small pellets per shot. Damage
	# is applied once per shot (same as any other weapon), but the visual is
	# a cone of pellets so a Ripper volley reads as buckshot, not a slug.
	var is_shotgun: bool = false
	if weapon.weapon_name:
		is_shotgun = weapon.weapon_name.to_lower().find("shotgun") != -1
	const SHOTGUN_PELLETS: int = 5
	const SHOTGUN_SPREAD_RAD: float = 0.157  # ~9 degrees
	const SHOTGUN_PELLET_RANGE: float = 14.0

	for i: int in shots:
		_current_target.take_damage(per_member_dmg, _unit)

		# Pick a per-shot aim point: distribute shots across the live members
		# of the target squad so projectiles arrive at different bodies.
		var aim_pos: Vector3 = _current_target.global_position
		if not target_positions.is_empty():
			aim_pos = target_positions[i % target_positions.size()]

		if proj_script:
			var fire_pos: Vector3 = _unit.global_position
			if i < muzzle_positions.size():
				fire_pos = muzzle_positions[i]

			if is_shotgun:
				var to_target: Vector3 = aim_pos - fire_pos
				to_target.y = 0.0
				var base_dir: Vector3 = Vector3.FORWARD
				if to_target.length_squared() > 0.01:
					base_dir = to_target.normalized()
				for p: int in SHOTGUN_PELLETS:
					var yaw: float = randf_range(-SHOTGUN_SPREAD_RAD, SHOTGUN_SPREAD_RAD)
					var spread_dir: Vector3 = base_dir.rotated(Vector3.UP, yaw)
					spread_dir.y += randf_range(-0.06, 0.06)
					spread_dir = spread_dir.normalized()
					var pellet_target: Vector3 = fire_pos + spread_dir * SHOTGUN_PELLET_RANGE
					pellet_target.y = aim_pos.y
					# Force "fast" tier so Projectile renders these as bullet
					# slugs regardless of the parent weapon's classification.
					var pellet: Node3D = proj_script.create(fire_pos, pellet_target, weapon.role_tag, &"fast")
					get_tree().current_scene.add_child(pellet)
			else:
				var proj: Node3D = proj_script.create(fire_pos, aim_pos, weapon.role_tag, weapon.rof_tier, weapon.projectile_style)
				get_tree().current_scene.add_child(proj)

	# Muzzle flash on each member — colored by the weapon's role.
	_spawn_squad_muzzle_flash(_muzzle_color_for(weapon))

	# Trigger cannon recoil animation on the unit.
	if _unit.has_method("play_shoot_anim"):
		_unit.play_shoot_anim()

	# Sound — pass the weapon so the audio manager can color the layered
	# generators based on damage tier, fire rate, and role.
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_fire"):
		audio.play_weapon_fire(weapon, _unit.global_position)


func _muzzle_color_for(weapon: WeaponResource) -> Color:
	if not weapon:
		return Color(1.0, 0.7, 0.1, 1.0)
	match weapon.role_tag:
		&"AA":
			return Color(0.4, 0.85, 1.0, 1.0)   # cool blue tracers
		&"AP":
			return Color(1.0, 0.55, 0.1, 1.0)   # punchy orange
		_:
			return Color(1.0, 0.85, 0.3, 1.0)   # warm yellow generic


func _spawn_squad_muzzle_flash(color: Color = Color(1.0, 0.7, 0.1, 1.0)) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 6.0

	# Prefer real barrel-tip positions; fall back to chest-height if none.
	var positions: Array[Vector3] = []
	if _unit.has_method("get_muzzle_positions"):
		positions = _unit.get_muzzle_positions()

	if positions.is_empty():
		_create_flash_at(_unit.global_position + Vector3(0, 1.2, 0), mat)
		return

	# Muzzle positions are already at the barrel tip — flash directly there.
	for pos: Vector3 in positions:
		_create_flash_at(pos, mat)


func _create_flash_at(pos: Vector3, mat: StandardMaterial3D) -> void:
	# Muzzle flash → GPU particle emit. Color comes from the weapon's
	# muzzle-color material. Extra OmniLight3D kept (light pop is the
	# part that READS as muzzle flash from the ground), but the visible
	# burst itself is now a GPU particle.
	var _pem_scene: Node = get_tree().current_scene
	var pem: Node = _pem_scene.get_node_or_null("ParticleEmitterManager") if _pem_scene else null
	if pem:
		var flash_color: Color = mat.emission if mat.emission_enabled else Color(1.0, 0.8, 0.3, 1.0)
		flash_color.a = 0.95
		pem.emit_flash(pos, flash_color)

	# Brief OmniLight3D — kept on the CPU side because its real-light
	# contribution affects the unit + terrain shading, which can't be
	# reproduced by a GPU particle. Single light per shot, lifetime
	# 0.09s.
	var light := OmniLight3D.new()
	light.light_color = mat.emission if mat.emission_enabled else Color(1.0, 0.8, 0.3)
	light.light_energy = 3.5
	light.omni_range = 4.5
	get_tree().current_scene.add_child(light)
	light.global_position = pos
	var ltween := light.create_tween()
	ltween.tween_property(light, "light_energy", 0.0, 0.09).set_ease(Tween.EASE_OUT)
	ltween.tween_callback(light.queue_free)


func _get_target_armor() -> StringName:
	if "stats" in _current_target:
		var target_stats: Resource = _current_target.get("stats")
		if target_stats and "armor_class" in target_stats:
			return target_stats.get("armor_class") as StringName
		elif target_stats and "building_id" in target_stats:
			return &"structure"
	return &"unarmored"
