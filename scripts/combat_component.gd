class_name CombatComponent
extends Node
## Handles targeting, weapon firing, and damage calculation for a unit.
## Attached as a child of Unit by Unit._ready().

var _unit: Node = null  # Parent Unit — accessed via duck typing to avoid class resolution issues
var _current_target: Node3D = null
var _fire_cooldown: float = 0.0
var _secondary_cooldown: float = 0.0
var _search_timer: float = 0.0

## Burst-fire state for high-RoF weapons. Counts shots within the current
## burst; once the burst is full the cooldown is bumped up so the average
## shots-per-second matches the underlying ROF tier.
var _burst_count: int = 0

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


func _physics_process(delta: float) -> void:
	if not _unit or not _unit.get("stats"):
		return
	var alive: int = _unit.get("alive_count")
	if alive <= 0:
		return

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
	var can_auto_target: bool = not unit_has_move_order or attack_move_target != Vector3.INF
	if not _current_target and can_auto_target and _search_timer <= 0.0:
		_search_timer = SEARCH_INTERVAL
		var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
		var weapon_range: float = 10.0
		if stats and stats.primary_weapon:
			weapon_range = CombatTables.get_range(stats.primary_weapon.range_tier)
		var found: Node3D = _find_nearest_enemy(weapon_range * ENGAGE_RANGE_MULT)
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
		if node_owner == my_owner:
			continue
		var node_alive: int = node.get("alive_count")
		if node_alive <= 0:
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
		var node_owner: int = node.get("owner_id")
		if node_owner == my_owner:
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
	if forced_target and is_instance_valid(forced_target):
		# Already engaging something — don't drop a player-issued or in-progress
		# target just because we got hit by someone else.
		return
	var has_move_order: bool = _unit.get("has_move_order") as bool
	if has_move_order and attack_move_target == Vector3.INF:
		# Player-issued (or builder-issued) plain move is in progress.
		# Finish that command before fighting back.
		return
	if not _is_valid_target(attacker):
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
	if target_owner == my_owner:
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

	var rof: float = CombatTables.get_rof(weapon.rof_tier)
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

	# Role vs armor modifier
	var target_armor: StringName = _get_target_armor()
	var role_mod: float = CombatTables.get_role_modifier(weapon.role_tag, target_armor)

	# Armor flat reduction
	var armor_reduction: float = CombatTables.get_armor_reduction(target_armor)

	# Directional modifier
	var dir_mod: float = CombatTables.get_directional_multiplier(
		_unit.global_position, _current_target
	)

	# Per-member damage
	var damage_per_member: float = float(base_damage) * role_mod * dir_mod * accuracy * (1.0 - armor_reduction)
	var per_member_dmg: int = maxi(int(damage_per_member), 1)

	# Fire one projectile per alive squad member, originating at the actual
	# barrel tip (falls back to chest-height if the unit has no cannons).
	var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
	var muzzle_positions: Array[Vector3] = []
	if _unit.has_method("get_muzzle_positions"):
		muzzle_positions = _unit.get_muzzle_positions()
	if muzzle_positions.is_empty() and _unit.has_method("get_member_positions"):
		muzzle_positions = _unit.get_member_positions()

	for i: int in shots:
		_current_target.take_damage(per_member_dmg, _unit)

		if proj_script:
			var fire_pos: Vector3 = _unit.global_position
			if i < muzzle_positions.size():
				fire_pos = muzzle_positions[i]
			var proj: Node3D = proj_script.create(fire_pos, _current_target.global_position, weapon.role_tag, weapon.rof_tier)
			get_tree().current_scene.add_child(proj)

	# Muzzle flash on each member
	_spawn_squad_muzzle_flash()

	# Trigger cannon recoil animation on the unit.
	if _unit.has_method("play_shoot_anim"):
		_unit.play_shoot_anim()

	# Sound
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_weapon_fire"):
		audio.play_weapon_fire()


func _spawn_squad_muzzle_flash() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.2, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.1, 1.0)
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
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	flash.mesh = sphere
	flash.global_position = pos
	flash.set_surface_override_material(0, mat)
	get_tree().current_scene.add_child(flash)

	var timer := Timer.new()
	timer.wait_time = 0.07
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(flash.queue_free)
	flash.add_child(timer)


func _get_target_armor() -> StringName:
	if "stats" in _current_target:
		var target_stats: Resource = _current_target.get("stats")
		if target_stats and "armor_class" in target_stats:
			return target_stats.get("armor_class") as StringName
		elif target_stats and "building_id" in target_stats:
			return &"structure"
	return &"unarmored"
