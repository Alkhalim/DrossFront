class_name CombatComponent
extends Node
## Handles targeting, weapon firing, and damage calculation for a unit.
## Attached as a child of Unit by Unit._ready().

var _unit: Node = null  # Parent Unit — accessed via duck typing to avoid class resolution issues
var _current_target: Node3D = null
var _fire_cooldown: float = 0.0
var _secondary_cooldown: float = 0.0
var _search_timer: float = 0.0
## Silence timer set by Pulsefont's System Crash (and any other future
## EMP-style ability). When > 0 the unit's weapons refuse to fire even
## with a valid target in range. Targeting and movement still tick so
## the silence is visible (unit visibly stops shooting) without
## leaving the unit completely unresponsive.
var _silence_remaining: float = 0.0

## Damage multiplier buff timer + value, set by Reactor Surge (and
## any other future damage-aura ability). While > 0 the multiplier
## scales every outgoing weapon hit. _damage_mult_value is reset on
## expiry so a stale value can't leak into the next cast.
var _damage_mult_remaining: float = 0.0
var _damage_mult_value: float = 1.0

## Incoming-damage reduction buff (Phalanx Shield's Barrier Bloom).
## While > 0, every incoming damage application is multiplied by
## (1 - _damage_taken_reduction). 0.0 = no shield, 0.5 = take half
## damage. Cleared on expiry so a stale shield can't leak into the
## next cast.
var _damage_taken_reduction_remaining: float = 0.0
var _damage_taken_reduction: float = 0.0

## Garrison passive — set by Courier Tank's Garrison ability and
## any future "passenger-buff" hook. When true, outgoing damage
## scales by GARRISON_DAMAGE_MULT and fire cooldowns shrink by
## GARRISON_FIRE_RATE_MULT (faster fire). Cleared on disembark.
var _garrison_active: bool = false
const GARRISON_DAMAGE_MULT: float = 1.5
const GARRISON_FIRE_RATE_MULT: float = 1.2

## Glowing-volley flag (Harbinger Swarm Marshal's Heavy Volley
## ability). When > 0 the next primary-weapon fire spawns N glowing
## pellets in a tight cone instead of the standard projectile, with
## damage scaled by the queued multiplier. Cleared after the buffed
## shot fires.
## First-strike per-target tracking. Stores the instance_id of the
## target this combat last opened fire on; the next time the unit
## fires at a DIFFERENT target, the shot picks up the
## stats.first_strike_bonus multiplier. Used by Hound (Ripper) to
## sell the close-range alpha-strike identity. 0 = haven't fired
## at anything yet, so the first ever shot also takes the bonus.
var _first_strike_target_id: int = 0

## Damage-ramp passive bookkeeping (UnitStatResource.damage_ramp_*).
## Tracks the most recent target's instance id and how many shots
## have landed on it consecutively. Resets when the target changes.
## Used by units like the Grinder Tank Plow branch to model a
## 'each successive hit on the same target hits harder' effect
## without a real lock-on system.
var _ramp_target_id: int = 0
var _ramp_hit_count: int = 0

var _glowing_volley_mult: float = 0.0
## When true, the queued glowing volley fires as a 5-pellet shotgun
## salvo (Harbinger Heavy Volley). When false, it fires as a SINGLE
## buffed primary shot with the glow VFX (Hound Ripper Glowing Shot
## -- the autocannon doesn't make sense as buckshot). Default true
## for back-compat with the Heavy Volley callers.
var _glowing_pellet_mode: bool = true
const GLOWING_VOLLEY_PELLETS: int = 5
const GLOWING_VOLLEY_SPREAD_RAD: float = 0.10  # tight cone, ~5.7 deg

## Live drones launched by this carrier. Pruned each spawn tick so
## queue_freed entries (drones that docked or died with the
## carrier) don't keep counting against the bay cap.
var _active_drones: Array[Node3D] = []


func queue_glowing_volley(damage_mult: float, pellet_mode: bool = true) -> void:
	## Caller (an active ability) tags the next primary fire to come
	## out as a glowing salvo at `damage_mult` damage. pellet_mode
	## true splits the buffed shot across 5 shotgun pellets (Heavy
	## Volley); pellet_mode false keeps the existing shot count and
	## just buffs the damage + adds the glow VFX (Hound Ripper
	## Glowing Shot autocannon).
	_glowing_volley_mult = damage_mult
	_glowing_pellet_mode = pellet_mode
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

## Retaliation bookkeeping -- when notify_attacked sets a forced
## target on a unit that was moving (en-route engagement), we
## remember the original move target so the unit can resume its
## journey after the attacker is dead OR has stayed out of sight
## for RETALIATION_LOST_SIGHT_SEC seconds. INF = not retaliating
## from a move. Cleared when the retaliation resolves.
const RETALIATION_LOST_SIGHT_SEC: float = 7.0
var _retaliation_resume_target: Vector3 = Vector3.INF
var _retaliation_lost_sight_timer: float = 0.0


func _ready() -> void:
	_unit = get_parent()
	_registry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	# Round-robin third-frame stagger across the combat fleet. The
	# 250-pop stress test showed CombatComponent eating ~20s of script
	# time over 4 minutes; bumping from 1-in-2 to 1-in-3 cuts ~33% of
	# that. Fire cadence (3-10 shots/sec at peak) sits well below the
	# resulting 20 Hz combat tick so the rate-of-fire stays identical
	# -- the doubled delta below becomes a tripled delta to match.
	_phase = int(get_instance_id() % 3)


func apply_silence(duration: float) -> void:
	## Called by abilities that disable enemy weapons (Pulsefont's
	## System Crash). Stacks by max — overlapping casts extend the
	## silence to whichever runs longer rather than letting a fresh
	## short cast clip a longer one.
	_silence_remaining = maxf(_silence_remaining, duration)


func is_silenced() -> bool:
	return _silence_remaining > 0.0


func apply_damage_buff(multiplier: float, duration: float) -> void:
	## Called by friendly damage-aura abilities (Forgemaster Reactor
	## Surge). Stacks by MAX on both axes so re-casting an aura
	## mid-fight doesn't shrink an already-running stronger one.
	_damage_mult_value = maxf(_damage_mult_value, multiplier)
	_damage_mult_remaining = maxf(_damage_mult_remaining, duration)


func get_damage_buff_mult() -> float:
	var aura: float = _damage_mult_value if _damage_mult_remaining > 0.0 else 1.0
	if _garrison_active:
		aura *= GARRISON_DAMAGE_MULT
	return aura


func apply_damage_reduction(reduction: float, duration: float) -> void:
	## Called by friendly shield-aura abilities (Phalanx Shield's
	## Barrier Bloom). `reduction` is the fraction of incoming damage
	## absorbed (0.5 = take half damage). Stacks by MAX so re-casting
	## a weaker shield over an already-running stronger one doesn't
	## clobber it.
	_damage_taken_reduction = maxf(_damage_taken_reduction, reduction)
	_damage_taken_reduction_remaining = maxf(_damage_taken_reduction_remaining, duration)


func get_damage_taken_mult() -> float:
	## Fraction of incoming damage that lands. 1.0 = unmitigated;
	## 0.5 = half damage. Read by Unit.apply_damage so structures
	## and aircraft route through the same shield-buff hook.
	if _damage_taken_reduction_remaining > 0.0:
		return clampf(1.0 - _damage_taken_reduction, 0.0, 1.0)
	return 1.0


func set_garrison_active(active: bool) -> void:
	_garrison_active = active


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

	# Third-frame stagger -- only run heavy targeting / fire logic
	# on the assigned phase. Cooldowns advance via the tripled delta
	# so fire rate is identical to an un-staggered tick.
	_phys_frame += 1
	if (_phys_frame % 3) != _phase:
		return
	delta *= 3.0

	_fire_cooldown -= delta
	_secondary_cooldown -= delta
	_search_timer -= delta
	if _silence_remaining > 0.0:
		_silence_remaining = maxf(0.0, _silence_remaining - delta)
	if _damage_mult_remaining > 0.0:
		_damage_mult_remaining = maxf(0.0, _damage_mult_remaining - delta)
		if _damage_mult_remaining <= 0.0:
			_damage_mult_value = 1.0
	if _damage_taken_reduction_remaining > 0.0:
		_damage_taken_reduction_remaining = maxf(0.0, _damage_taken_reduction_remaining - delta)
		if _damage_taken_reduction_remaining <= 0.0:
			_damage_taken_reduction = 0.0

	var unit_has_move_order: bool = _unit.get("has_move_order") as bool

	# Forced target wins. If it's gone or dead, drop it.
	if forced_target and not _is_valid_target(forced_target):
		forced_target = null
		_retaliation_lost_sight_timer = 0.0
	# Retaliation lost-sight watchdog -- when an AI-owned unit was
	# pulled into combat by notify_attacked but its attacker has
	# stayed out of sight for RETALIATION_LOST_SIGHT_SEC seconds,
	# clear forced_target so the unit resumes its original move
	# order. 'Out of sight' = farther than the unit's sight radius.
	# Player-owned units (owner 0) never enter retaliation during
	# plain moves, so the watchdog is a no-op for them.
	if forced_target and unit_has_move_order and attack_move_target == Vector3.INF:
		var owner_v: int = (_unit.get("owner_id") as int) if "owner_id" in _unit else 0
		if owner_v != 0:
			var stats_v: UnitStatResource = _unit.get("stats") as UnitStatResource
			var sight: float = stats_v.resolved_sight_radius() if stats_v else 20.0
			var d_target: float = _unit.global_position.distance_to(forced_target.global_position)
			if d_target > sight:
				_retaliation_lost_sight_timer += delta
				if _retaliation_lost_sight_timer >= RETALIATION_LOST_SIGHT_SEC:
					forced_target = null
					_retaliation_lost_sight_timer = 0.0
			else:
				_retaliation_lost_sight_timer = 0.0
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
			weapon_range = stats.primary_weapon.resolved_range()
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
	var primary_range: float = primary.resolved_range() if primary else 10.0

	# Shared-FOW LOS gate -- a unit can engage anything within its
	# weapon range as long as ANY friendly observer (own units,
	# allied units, friendly buildings) currently reveals the target
	# in fog of war. The previous gate was per-unit sight_radius
	# only, so a Bulwark with 25u long-range cannon couldn't fire at
	# a structure 22u away that an allied scout was painting -- the
	# shot was forced to walk into the unit's own sight bubble first.
	# The shared-vision rule mirrors how the player sees the world
	# (FOW is per-team), so a unit firing on what the player can see
	# matches expectations.
	var sight_r: float = stats.resolved_sight_radius() if stats else primary_range
	# Only player-side units (owner 0) and player allies benefit
	# from the shared-FOW reveal; the FOW grid is the local
	# player's vision, so applying it to enemy AI would let the
	# enemy 'cheat' by piggybacking on the player's vision. AI
	# stays on per-unit sight_radius until a per-team FOW is wired
	# up. PlayerRegistry.are_allied returns true for any owner on
	# the same team as the local player.
	var owner_id: int = _unit.get("owner_id") as int
	var uses_shared_los: bool = owner_id == 0
	if not uses_shared_los:
		var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
		if registry and registry.has_method("are_allied"):
			uses_shared_los = registry.call("are_allied", owner_id, 0)
	var team_can_see: bool = false
	if uses_shared_los:
		var fow: Node = get_tree().current_scene.get_node_or_null("FogOfWar") if get_tree() else null
		if fow and fow.has_method("is_visible_world"):
			team_can_see = fow.call("is_visible_world", _current_target.global_position)
	if dist > sight_r and not team_can_see:
		_unit.command_move(_current_target.global_position, false)
		return

	if dist <= primary_range:
		# In range: stop and engage. We always stop here because the only way
		# we reach this branch is when we have a target (forced or auto-acquired
		# during attack-move) — the unit's current move order, if any, was
		# either issued by us to chase, or part of an attack-move that should
		# halt to fire. Plain player move orders never auto-acquire targets.
		_unit.stop()

		_face_target()

		# Per-weapon air gating: when the current target is in the
		# aircraft group, only fire weapons whose engages_air()
		# returns true. Lets a Hound's Universal autocannons engage
		# air while its AT missile rack stays ground-only, and a
		# Forgemaster's Skyspike fire at air while its Riveter
		# autocannon ignores aircraft.
		var target_is_air: bool = _current_target.is_in_group("aircraft")

		if primary and _fire_cooldown <= 0.0 and _silence_remaining <= 0.0:
			if not target_is_air or primary.engages_air():
				_fire_weapon(primary, true)

		# Autocast hook — units whose stats define an ability with
		# ability_autocast = true (Hammerhead's Missile Barrage)
		# fire it on the same tick they're firing the primary, as
		# long as the cooldown has rolled over. trigger_ability
		# itself enforces the cooldown + has-ability guards, so a
		# manually-fired ability + cooldown still gates auto.
		if stats.ability_autocast and stats.ability_name != "" and _silence_remaining <= 0.0:
			if _unit.has_method("ability_ready") and _unit.call("ability_ready"):
				if _unit.has_method("trigger_ability"):
					_unit.call("trigger_ability")

		if stats.secondary_weapon and _secondary_cooldown <= 0.0 and _silence_remaining <= 0.0:
			var sec_range: float = stats.secondary_weapon.resolved_range()
			if dist <= sec_range:
				if not target_is_air or stats.secondary_weapon.engages_air():
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

	# Ground-only units (no AAir-tagged weapon) skip aircraft in
	# auto-acquire. AP / Universal trickle damage at 0.1-0.4x is
	# misleading -- the unit shouldn't be reading as anti-air-capable
	# from the targeting behaviour. Player can still manually
	# right-click an aircraft to forced-target it.
	var ground_only: bool = not stats.can_target_air()

	# Spatial-index lookup: return only the entities in the buckets
	# covering max_range around `my_pos` instead of walking the
	# whole units + buildings groups. Caller-side hostility / armor
	# / range filters still apply because the index includes
	# friendlies + freed handles + entities outside the precise
	# radius (rebuild lag).
	var idx: SpatialIndex = SpatialIndex.get_instance(get_tree().current_scene)
	var candidates: Array = idx.nearby(my_pos, max_range) if idx else []
	# Untyped iteration -- the spatial-index bucket may carry stale
	# Object references for entities freed since the last rebuild
	# tick. A typed `for node: Node in candidates:` assigns each
	# slot to a typed local, which errors on a freed handle BEFORE
	# the is_instance_valid check below ever runs.
	for raw in candidates:
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if not node:
			continue
		# `node` may be a unit OR a building -- both expose
		# take_damage + owner_id. Skip non-targetable entries.
		if not node.has_method("take_damage"):
			continue
		# Auto-target opt-out for destructible neutral structures.
		if "auto_targetable" in node and not node.get("auto_targetable"):
			continue
		# Pre-start foundations -- engineer hasn't reached them yet.
		if "construction_started" in node and not (node.get("construction_started") as bool):
			if "is_constructed" in node and not (node.get("is_constructed") as bool):
				continue
		var node_owner: int = node.get("owner_id")
		if not _is_hostile(my_owner, node_owner):
			continue
		# Alive check only applies to units (alive_count field).
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		if ground_only and node.is_in_group("aircraft"):
			continue
		# V3 stealth -- auto-target ignores stealth-capable units
		# that aren't currently revealed.
		if "stealth_revealed" in node and not (node.get("stealth_revealed") as bool):
			var their_stats: UnitStatResource = node.get("stats") as UnitStatResource
			if their_stats and their_stats.is_stealth_capable:
				continue
		var d: float = my_pos.distance_to((node as Node3D).global_position)
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
			weapon_range = stats.primary_weapon.resolved_range()
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
	var owner_id_v: int = (_unit.get("owner_id") as int) if "owner_id" in _unit else 0
	if has_move_order and attack_move_target == Vector3.INF:
		# Player-issued plain move (owner 0): finish that command
		# before fighting back -- the player explicitly chose to
		# disengage. AI-owned units (owner != 0) DO retaliate
		# during a plain move, then resume the move once the
		# attacker is dead OR has stayed out of sight for
		# RETALIATION_LOST_SIGHT_SEC seconds.
		if owner_id_v == 0:
			return
		_retaliation_lost_sight_timer = 0.0
	forced_target = attacker
	_current_target = attacker


func _is_valid_target(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	if not target.has_method("take_damage"):
		return false
	# Guard against targets that don't carry owner_id (rare -- some
	# neutral terrain features get picked up via stray-shot rules).
	# Casting `null` to int would crash; default to enemy faction
	# (-1) so the hostility check returns false and the targeting
	# layer drops them silently.
	if not "owner_id" in target or not "owner_id" in _unit:
		return false
	var target_owner: int = target.get("owner_id") as int
	var my_owner: int = _unit.get("owner_id") as int
	if not _is_hostile(my_owner, target_owner):
		return false
	# Check if unit is still alive
	if "alive_count" in target:
		var alive: int = target.get("alive_count")
		if alive <= 0:
			return false
	# Garrisoned units (riding inside a Courier Tank) aren't on the
	# board for combat purposes — they don't have a position the
	# enemy can shoot at, and snapping fire to the carrier's pos
	# would let one tank "tank" all the incoming AI shots away from
	# its own crew. Filter them out at the targeting layer.
	if "_garrisoned_in" in target and target.get("_garrisoned_in") != null:
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

	var rof: float = weapon.resolved_rof_seconds() * reload_factor
	# Garrison fire-rate buff — divide cooldown by GARRISON_FIRE_RATE_MULT
	# so fire happens faster (1.2x = 20% quicker rolls). Applied AFTER the
	# Mesh reload factor so both effects compound multiplicatively.
	if _garrison_active:
		rof = rof / GARRISON_FIRE_RATE_MULT
	# RoF-ramp passive (UnitStatResource.rof_ramp_*): each
	# consecutive shot at the same target shortens the next cycle.
	# Reuses _ramp_hit_count from the damage-ramp tracker so a unit
	# carrying both ramps shares one counter (e.g. Breacher Salvo
	# could ramp both damage and rof on the same target). Cap is
	# applied to the multiplier, not the cycle, so 0.6 max ramp
	# means cycles never drop below 40% of the base rof.
	# `in` guards prevent a crash when an older cached
	# UnitStatResource doesn't carry the new fields yet (Godot's
	# resource cache survives a script reload, so the live
	# instance can lag the script schema for one match).
	var rof_ramp_stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	if rof_ramp_stats and "rof_ramp_per_hit" in rof_ramp_stats and "rof_ramp_max" in rof_ramp_stats and _current_target:
		var ramp_per: float = rof_ramp_stats.rof_ramp_per_hit
		var ramp_cap: float = rof_ramp_stats.rof_ramp_max
		if ramp_per > 0.0 and ramp_cap > 0.0:
			var rt_id: int = _current_target.get_instance_id()
			# Note: _ramp_hit_count is bumped AFTER damage in the
			# damage-ramp branch below, so it represents the count
			# BEFORE this shot (0 for first shot, 1 for second, ...).
			# That gives the first shot the full base cycle and only
			# starts shortening from shot 2 onwards.
			var hits_so_far: int = _ramp_hit_count if rt_id == _ramp_target_id else 0
			var rof_cut: float = float(hits_so_far) * ramp_per
			rof_cut = minf(rof_cut, ramp_cap)
			rof *= 1.0 - rof_cut
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

	var base_damage: int = weapon.resolved_damage()
	# Salvo support — a salvo_count of N fires N projectiles per
	# squad member per fire tick. Each projectile deals base_damage
	# independently; weapons with high salvo (Hammerhead missiles)
	# pre-pay this by carrying a smaller per-projectile damage tier.
	var salvo_count: int = maxi(int(weapon.salvo_count), 1)
	var shots: int = (_unit.get("alive_count") as int) * salvo_count

	# Accuracy starts at 1.0 -- the natural "fewer survivors fire
	# fewer shots" effect already scales squad output by alive_count
	# above, so no extra full-strength bonus is layered on top.
	var stats: UnitStatResource = _unit.get("stats") as UnitStatResource
	var accuracy: float = 1.0
	# Mesh accuracy bonus.
	if mesh_sys and mesh_sys.has_method("accuracy_bonus"):
		accuracy += mesh_sys.call("accuracy_bonus", mesh_strength) as float

	# Role vs armor modifier. Routes through WeaponResource.get_role_mult_for
	# so per-weapon per-class overrides (Bulwark cannon's 0.3/0.5/1.0/0.6,
	# WRAITH bomb bay's 3.0 vs structure, etc.) take precedence over the
	# default CombatTables.ROLE_VS_ARMOR row.
	var target_armor: StringName = _get_target_armor()
	var role_mod: float = weapon.get_role_mult_for(target_armor)

	# Armor flat reduction — prefer the target's resolved_armor_reduction()
	# (honors per-unit numeric override), fall back to the armor_class
	# table for buildings / non-unit targets that don't carry a unit stat.
	var armor_reduction: float = CombatTables.get_armor_reduction(target_armor)
	if "stats" in _current_target:
		var ts_v: Variant = _current_target.get("stats")
		if typeof(ts_v) == TYPE_OBJECT and is_instance_valid(ts_v):
			var ts_unit: UnitStatResource = ts_v as UnitStatResource
			if ts_unit:
				armor_reduction = ts_unit.resolved_armor_reduction()

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

	# Per-member damage. damage_buff is the active Reactor-Surge style
	# multiplier (1.0 when no friendly aura is up); applied late so
	# armor and accuracy still gate the result the same way.
	var damage_buff: float = get_damage_buff_mult()
	# Per-weapon air scalar (default 1.0). Lets specific weapons clamp
	# their effective air output without changing the role-vs-armor
	# table -- e.g. existing AP+can_hit_air weapons set this to 0.2
	# so the AP role's light-air buff doesn't 5x their air damage.
	var air_mult: float = 1.0
	var is_air_target: bool = (target_armor == &"light_air" or target_armor == &"heavy_air")
	if is_air_target:
		air_mult = weapon.air_damage_mult
	var damage_per_member: float = float(base_damage) * role_mod * dir_mod * elevation_mod * accuracy * (1.0 - armor_reduction) * damage_buff * air_mult
	# Heavy Volley boost — applied here so it stacks with all other
	# damage modifiers (Mesh, garrison buff, role mult, armor red).
	# Cleared once the buffed shot has been resolved further down.
	if is_primary and _glowing_volley_mult > 0.0:
		damage_per_member *= _glowing_volley_mult
	# First-strike bonus -- when this unit has a first_strike_bonus
	# stat AND the current target is different from the one we last
	# fired at, the opening shot picks up the multiplier. Records the
	# new target id so subsequent shots on the same target are
	# normal-damage. Skipped for secondary weapons so the bonus only
	# fires once per acquisition rather than once per weapon.
	if stats and stats.first_strike_bonus > 1.0 and is_primary:
		var target_id: int = _current_target.get_instance_id()
		if target_id != _first_strike_target_id:
			damage_per_member *= stats.first_strike_bonus
			_first_strike_target_id = target_id
	# Damage-ramp passive — every consecutive shot on the same
	# target adds damage_ramp_per_hit to the multiplier, capped at
	# damage_ramp_max. Resets when the target changes. Applied to
	# primary AND secondary so a Plow-branch Grinder ramps on both
	# its missile launchers. Skipped silently for any unit whose
	# stats don't opt in (default ramp_per_hit / ramp_max = 0).
	if stats and "damage_ramp_per_hit" in stats and "damage_ramp_max" in stats and stats.damage_ramp_per_hit > 0.0 and stats.damage_ramp_max > 0.0:
		var ramp_target_id: int = _current_target.get_instance_id()
		if ramp_target_id != _ramp_target_id:
			# New target -- start the ramp from scratch.
			_ramp_target_id = ramp_target_id
			_ramp_hit_count = 0
		var ramp_bonus: float = float(_ramp_hit_count) * stats.damage_ramp_per_hit
		ramp_bonus = minf(ramp_bonus, stats.damage_ramp_max)
		damage_per_member *= 1.0 + ramp_bonus
		_ramp_hit_count += 1
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
	# Detection prefers the explicit `is_shotgun` flag on the resource;
	# falls back to a name match for any pre-flag tres files. Heavy Volley
	# (active ability) also routes through the pellet branch -- it's a
	# one-shot 5-pellet salvo with bonus damage and a glowing emissive.
	var is_glowing_volley: bool = is_primary and _glowing_volley_mult > 0.0
	# Glowing-volley pellet mode (Heavy Volley) forces shotgun
	# spread; pellet_mode false (Glowing Shot) keeps the weapon's
	# normal shot count and just adds the damage buff + glow.
	var is_shotgun: bool = is_glowing_volley and _glowing_pellet_mode
	if not is_shotgun:
		if "is_shotgun" in weapon and weapon.get("is_shotgun"):
			is_shotgun = true
		elif weapon.weapon_name:
			is_shotgun = weapon.weapon_name.to_lower().find("shotgun") != -1
	var SHOTGUN_PELLETS: int = 9
	var SHOTGUN_SPREAD_RAD: float = 0.26  # ~15 degrees
	const SHOTGUN_PELLET_RANGE: float = 14.0
	if is_glowing_volley and _glowing_pellet_mode:
		SHOTGUN_PELLETS = GLOWING_VOLLEY_PELLETS
		SHOTGUN_SPREAD_RAD = GLOWING_VOLLEY_SPREAD_RAD

	# V3 §Pillar 5 — per-shot hit roll. Squad-strength + Mesh + base
	# weapon accuracy combine into a final hit chance, modified by
	# range-band (long shots are less accurate) and movement (firing
	# while moving is less accurate). Clamped to [0.30, 0.99] so no
	# shot is impossible AND no shot is guaranteed for non-elite
	# weapons. Misses spawn dust + ricochet sound, no damage.
	var weapon_range: float = weapon.resolved_range()
	var dist_to_target: float = _unit.global_position.distance_to(_current_target.global_position)
	var range_t: float = clampf(dist_to_target / maxf(weapon_range, 0.01), 0.0, 1.0)
	# Range band: point-blank shots get a small accuracy bonus, mid
	# range is baseline, the far third of the weapon's reach drops
	# 10%. Closer = more reliable hits, so a player kiting in close
	# is genuinely rewarded for the positioning work.
	var range_penalty: float = 0.0
	if range_t <= 0.30:
		range_penalty = 0.08
	elif range_t >= 0.80:
		range_penalty = -0.10
	var movement_penalty: float = 0.0
	if Vector2(_unit.velocity.x, _unit.velocity.z).length() > 0.5:
		movement_penalty = -0.15
	var base_hit: float = weapon.base_accuracy
	# `accuracy` already has squad-strength + Mesh additions baked in,
	# but it's a damage MULTIPLIER (1.0 = baseline). Subtract 1.0 to
	# get just the bonus and add it onto the per-weapon base hit.
	var hit_chance: float = clampf(
		base_hit + (accuracy - 1.0) + range_penalty + movement_penalty,
		0.30, 0.99
	)

	# FOW gate -- if neither the shooter nor the target are in the
	# local player's current vision, skip every visible / audible
	# side-effect (projectile spawn, miss-zip, muzzle flash, fire
	# sound). Damage already applied above, so the engagement still
	# resolves; the player just doesn't see / hear it through the
	# fog. Friendly units always pass because they're their own
	# visibility source.
	var firing_visible: bool = _firing_observable()

	# Damage timing model: beams (instant flash) and drone-release
	# (damage delivered by the spawned drone on arrival) keep their
	# previous damage path. Every other projectile style (bullet /
	# shell / missile / mortar / bomb) defers damage to the
	# projectile's _spawn_impact -- payload attached after
	# spawning the projectile below. This makes the damage land
	# WHEN the visible projectile reaches the target instead of
	# at fire-time, which the player kept noticing as
	# 'why did that guy take damage before the missile got there?'.
	var weapon_style: StringName = weapon.projectile_style if "projectile_style" in weapon else &""
	# rof_tier -> default projectile style mapping mirrors
	# Projectile.ROF_STYLES so beams (rof=continuous) get instant
	# damage; explicit projectile_style override on the weapon
	# wins.
	var inferred_style: String = "bullet"
	if weapon.rof_tier == &"continuous":
		inferred_style = "beam"
	elif weapon.rof_tier == &"single" or weapon.rof_tier == &"slow" or weapon.rof_tier == &"volley":
		inferred_style = "missile"
	var effective_style: String = String(weapon_style) if weapon_style != &"" else inferred_style
	var damage_is_instant: bool = (
		effective_style == "beam"
		or weapon.is_drone_release
		or is_shotgun  # shotgun pellets stay instant for now -- the cone is the whole damage event
	)
	var splash_r: float = weapon.splash_radius if "splash_radius" in weapon else 0.0
	for i: int in shots:
		var hit: bool = randf() < hit_chance
		if hit and damage_is_instant and not weapon.is_drone_release:
			_current_target.take_damage(per_member_dmg, _unit)
			# Splash for instant-damage weapons -- mirrors the
			# pre-deferral behaviour. Mortar / missile splash now
			# applies on projectile impact instead (handled inside
			# Projectile._spawn_impact via the payload).
			if splash_r > 0.0:
				_apply_instant_splash(per_member_dmg, _current_target, splash_r, weapon.splash_damage_mult)

		# Pick a per-shot aim point: distribute shots across the live members
		# of the target squad so projectiles arrive at different bodies.
		var aim_pos: Vector3 = _current_target.global_position
		if not target_positions.is_empty():
			aim_pos = target_positions[i % target_positions.size()]
		# Missed shot -- offset the impact far enough that the projectile
		# visibly flies PAST the target and lands on the ground beyond
		# (or sails wide). Distance scales with how close the hit chance
		# was to missing -- a 90%-accuracy shot grazes; a 30%-accuracy
		# shot sails wide. If the offset shot happens to land near a
		# different hostile unit / building, that one eats half damage
		# (stray-shot rule).
		if not hit:
			var miss_offset: float = lerp(2.5, 7.0, 1.0 - hit_chance)
			aim_pos += Vector3(
				randf_range(-miss_offset, miss_offset),
				0.0,
				randf_range(-miss_offset, miss_offset),
			)
			# Drop the aim Y to ground so the projectile arc terminates
			# at floor level instead of vanishing in mid-air at unit
			# height -- reads as "shot kicked up dirt over there" rather
			# than "shot evaporated".
			aim_pos.y = 0.0
			# Stray-hit check. Owner pulled fresh here -- this loop
			# doesn't capture an outer my_owner the way some other
			# combat passes do.
			var shooter_owner: int = (_unit.get("owner_id") as int) if _unit and "owner_id" in _unit else 0
			var stray: Node3D = _find_stray_target(aim_pos, _current_target, shooter_owner)
			if stray and stray.has_method("take_damage"):
				var stray_dmg: int = maxi(int(round(float(per_member_dmg) * 0.5)), 1)
				stray.take_damage(stray_dmg, _unit)
			if firing_visible:
				var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager") if get_tree() else null
				if audio and audio.has_method("play_miss"):
					audio.call("play_miss", aim_pos)

		# Drone-release weapons skip the regular projectile path
		# entirely -- each shot in the salvo spawns one Drone that
		# flies out of the carrier, fires once at the target, and
		# returns. Damage is delivered by the drone on arrival.
		if weapon.is_drone_release:
			if hit:
				_spawn_drone(per_member_dmg, weapon.role_tag, weapon.drone_variant, weapon.max_active_drones)
			continue

		if firing_visible and proj_script:
			var fire_pos: Vector3 = _unit.global_position
			# Modulo so salvo shots (i past the muzzle count) cycle
			# back through the available muzzles instead of all
			# spawning from the unit's centre.
			if not muzzle_positions.is_empty():
				fire_pos = muzzle_positions[i % muzzle_positions.size()]
			# Bomb-drop weapons spawn the projectile a few metres below
			# the firing aircraft so the bomb visibly leaves the bomb
			# bay before arcing onto the target -- reads as 'opens
			# payload doors' instead of 'shoots from over the wing'.
			if weapon.bomb_drop:
				fire_pos.y = maxf(fire_pos.y - 4.0, 0.5)

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
					var pellet: Projectile = proj_script.create(fire_pos, pellet_target, weapon.role_tag, &"fast", &"", _shooter_faction_id())
					if is_glowing_volley:
						# Bright warning-yellow tint + 3x emission so the
						# Heavy Volley salvo unmistakably reads as the
						# buffed shot, not regular fire.
						pellet.set_glow_boost(3.0, Color(1.0, 0.85, 0.20, 1.0))
					get_tree().current_scene.add_child(pellet)
			else:
				# Salvo stagger -- when the weapon ships salvo_stagger_sec
				# > 0 (Bulwark triple cannon, Breacher twin cannon) the
				# i-th projectile in the salvo is deferred so the
				# barrels visibly fire one-after-another instead of all
				# spawning on the same physics frame. Damage was
				# already applied above so DPS stays unchanged whether
				# the visual stagger is 0 or 0.20s. Shot i==0 always
				# fires immediately; only the trailing shots wait.
				# `in` guard: stale cached WeaponResources from before
				# salvo_stagger_sec was added would crash on the
				# property access otherwise.
				var weapon_stagger: float = weapon.salvo_stagger_sec if "salvo_stagger_sec" in weapon else 0.0
				var stagger_sec: float = weapon_stagger * float(i) if weapon_stagger > 0.0 else 0.0
				if stagger_sec <= 0.0:
					var proj: Node3D = proj_script.create(fire_pos, aim_pos, weapon.role_tag, weapon.rof_tier, weapon.projectile_style, _shooter_faction_id(), weapon.damage_tier)
					if is_glowing_volley and not _glowing_pellet_mode and proj.has_method("set_glow_boost"):
						proj.call("set_glow_boost", 3.0, Color(1.0, 0.85, 0.20, 1.0))
					# Damage-on-impact: attach payload to the
					# projectile so it lands when the visible
					# round arrives, not at fire-time. Skipped
					# for instant-style (beams / shotgun /
					# drone-release) which already applied
					# damage in the hit branch above.
					if hit and not damage_is_instant and proj.has_method("set_damage_payload"):
						var splash_dmg_int: int = 0
						if splash_r > 0.0:
							splash_dmg_int = maxi(int(round(float(per_member_dmg) * weapon.splash_damage_mult)), 1)
						proj.call("set_damage_payload", per_member_dmg, _current_target, _unit, splash_r, splash_dmg_int)
					get_tree().current_scene.add_child(proj)
				else:
					_spawn_staggered_projectile(stagger_sec, weapon, fire_pos, aim_pos, is_glowing_volley, per_member_dmg if (hit and not damage_is_instant) else 0, splash_r, weapon.splash_damage_mult)

	# Muzzle flash on each member — colored by the weapon's role.
	# Recoil animation runs even off-screen so units that re-enter
	# vision mid-burst don't snap-pose; the muzzle flash + sound are
	# the bits that should respect FOW.
	if firing_visible:
		_spawn_squad_muzzle_flash(_muzzle_color_for(weapon))
	if _unit.has_method("play_shoot_anim"):
		_unit.play_shoot_anim()

	# Sound — pass the weapon so the audio manager can color the layered
	# generators based on damage tier, fire rate, and role. Skip when
	# the firing unit + target are both in fog.
	if firing_visible:
		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
		if audio and audio.has_method("play_weapon_fire"):
			audio.play_weapon_fire(weapon, _unit.global_position)

	# Glowing Volley / Glowing Shot is a one-shot buff -- clear the
	# multiplier now that the buffed primary shot has fired so the
	# next ordinary shot returns to normal damage / spread. Reset
	# pellet_mode to its default so a future ability cast doesn't
	# inherit the previous caller's flag.
	if is_glowing_volley:
		_glowing_volley_mult = 0.0
		_glowing_pellet_mode = true


## Stray-shot landing radius. A miss that drifts within this many
## world-units of a different hostile target nicks them for half
## damage. Tight enough that wide misses still feel like misses.
const STRAY_HIT_RADIUS: float = 2.5


func _find_stray_target(aim_pos: Vector3, primary: Node3D, my_owner: int) -> Node3D:
	## Returns the nearest hostile unit/building within
	## STRAY_HIT_RADIUS of `aim_pos`, excluding `primary` (the unit
	## we already missed). Used to award half-damage stray hits when
	## a missed shot lands near a different enemy.
	var nearest: Node3D = null
	var nearest_dist: float = STRAY_HIT_RADIUS
	# Spatial-index narrow-phase. Replaces the old groups walk for
	# the same O(N)->O(K) win the main targeting path got.
	var idx: SpatialIndex = SpatialIndex.get_instance(get_tree().current_scene)
	var candidates: Array = idx.nearby(aim_pos, STRAY_HIT_RADIUS) if idx else []
	# Untyped iteration -- see _find_nearest_enemy for the typed-cast
	# of freed-instance trap.
	for raw in candidates:
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw as Node
		if not node or node == primary:
			continue
		if not node.has_method("take_damage"):
			continue
		if "auto_targetable" in node and not node.get("auto_targetable"):
			continue
		var node_owner: int = node.get("owner_id") as int
		if not _is_hostile(my_owner, node_owner):
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var n3: Node3D = node as Node3D
		if not n3:
			continue
		var d: float = aim_pos.distance_to(n3.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = n3
	return nearest


func _spawn_drone(damage: int, role_tag: StringName, variant: StringName = &"default", max_active: int = 6) -> void:
	## Spawns a Drone tethered to this carrier (the firing unit) that
	## flies out, fires at the current target, and returns to dock.
	## Drones live as scene-tree children at scene root so they
	## don't get queue_freed when the carrier moves -- they look up
	## the carrier each frame instead.
	var drone_script: GDScript = load("res://scripts/drone.gd") as GDScript
	if not drone_script:
		return
	if not _current_target or not is_instance_valid(_current_target):
		return
	# Prune the active-drone list (drones queue_free on dock + on
	# carrier death) and gate the spawn on the bay cap. max_active
	# <= 0 disables the cap entirely.
	if max_active > 0:
		var live: Array[Node3D] = []
		for d: Node3D in _active_drones:
			if is_instance_valid(d):
				live.append(d)
		_active_drones = live
		if _active_drones.size() >= max_active:
			return
	var drone: Node3D = drone_script.new()
	drone.set("carrier", _unit)
	drone.set("target", _current_target)
	drone.set("damage", damage)
	drone.set("role_tag", role_tag)
	drone.set("owner_id", (_unit.get("owner_id") as int) if _unit and "owner_id" in _unit else 0)
	drone.set("variant", variant)
	# Prefer a 'DroneBay' Marker3D child of the carrier so drones
	# launch from a specific bay door on the chassis rather than a
	# random offset. Falls back to a random offset around the
	# carrier when the marker is missing.
	var bay_marker: Node3D = _unit.get_node_or_null("DroneBay") as Node3D
	get_tree().current_scene.add_child(drone)
	if bay_marker and is_instance_valid(bay_marker):
		drone.global_position = bay_marker.global_position
	else:
		var spawn_offset: Vector3 = Vector3(randf_range(-1.5, 1.5), 1.5, randf_range(-1.5, 1.5))
		drone.global_position = _unit.global_position + spawn_offset
	_active_drones.append(drone)


func _apply_instant_splash(per_shot_dmg: int, primary_target: Node3D, splash_r: float, splash_mult: float) -> void:
	## Splash for instant-damage weapons (beam / shotgun pellets).
	## Mirrors the projectile-impact splash code, just dispatched
	## here at fire-time. Mortar / missile splash applies on
	## projectile arrival via Projectile._spawn_impact instead.
	var splash_dmg: int = maxi(int(round(float(per_shot_dmg) * splash_mult)), 1)
	var t_pos: Vector3 = primary_target.global_position
	var shooter_owner: int = (_unit.get("owner_id") as int) if _unit and "owner_id" in _unit else 0
	var registry: Node = get_tree().current_scene.get_node_or_null("PlayerRegistry") if get_tree() else null
	for ent: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(ent) or ent == primary_target:
			continue
		if not ent.has_method("take_damage"):
			continue
		var ent_owner: int = (ent.get("owner_id") as int) if "owner_id" in ent else 0
		var hostile: bool = true
		if registry and registry.has_method("are_enemies"):
			hostile = registry.call("are_enemies", shooter_owner, ent_owner)
		if not hostile:
			continue
		if t_pos.distance_to((ent as Node3D).global_position) <= splash_r:
			ent.take_damage(splash_dmg, _unit)
	for ent2: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(ent2) or ent2 == primary_target:
			continue
		if not ent2.has_method("take_damage"):
			continue
		var ent2_owner: int = (ent2.get("owner_id") as int) if "owner_id" in ent2 else 0
		var hostile2: bool = true
		if registry and registry.has_method("are_enemies"):
			hostile2 = registry.call("are_enemies", shooter_owner, ent2_owner)
		if not hostile2:
			continue
		if t_pos.distance_to((ent2 as Node3D).global_position) <= splash_r:
			ent2.take_damage(splash_dmg, _unit)


func _spawn_staggered_projectile(delay_sec: float, weapon: WeaponResource, fire_pos: Vector3, aim_pos: Vector3, is_glowing_volley: bool, payload_damage: int = 0, payload_splash_r: float = 0.0, payload_splash_mult: float = 0.0) -> void:
	## Schedules a single projectile spawn after `delay_sec`. Used by
	## salvo_stagger weapons so multi-barrel cannons (Bulwark triple,
	## Breacher twin) can fire their barrels in quick succession
	## while the next reload still measures from the FIRST barrel's
	## fire time. The closure captures the spawn parameters by value
	## via `bind`, so a later weapon swap on the unit doesn't
	## retroactively change what fires.
	var faction: int = _shooter_faction_id()
	var rof_tier: StringName = weapon.rof_tier
	var style: StringName = weapon.projectile_style
	var role: StringName = weapon.role_tag
	var dmg_tier: StringName = weapon.damage_tier
	# Capture the target + shooter as weak references so the lambda
	# doesn't keep them alive past their own death. The deferred
	# spawn checks is_instance_valid before applying damage.
	var captured_target: Node3D = _current_target
	var captured_shooter: Node3D = _unit
	var timer: SceneTreeTimer = get_tree().create_timer(delay_sec)
	timer.timeout.connect(func() -> void:
		if not is_inside_tree():
			return
		var proj_script: GDScript = load("res://scripts/projectile.gd") as GDScript
		if not proj_script:
			return
		var proj: Node3D = proj_script.create(fire_pos, aim_pos, role, rof_tier, style, faction, dmg_tier)
		if is_glowing_volley and proj.has_method("set_glow_boost"):
			proj.call("set_glow_boost", 3.0, Color(1.0, 0.85, 0.20, 1.0))
		# Damage-on-impact payload for staggered shots. payload_damage
		# 0 = caller didn't want this shot to deal damage (miss or
		# instant-style), so the projectile flies as cosmetic.
		if payload_damage > 0 and proj.has_method("set_damage_payload") and is_instance_valid(captured_target):
			var splash_dmg_int: int = 0
			if payload_splash_r > 0.0:
				splash_dmg_int = maxi(int(round(float(payload_damage) * payload_splash_mult)), 1)
			proj.call("set_damage_payload", payload_damage, captured_target, captured_shooter, payload_splash_r, splash_dmg_int)
		get_tree().current_scene.add_child(proj)
	)


func _shooter_faction_id() -> int:
	## Returns 0 for Anvil, 1 for Sable. Used to tint projectile
	## tracers (Sable reads whiter than Anvil's warm orange). Falls
	## back to 0 when the unit doesn't expose a _faction_id helper.
	if _unit and _unit.has_method("_faction_id"):
		return _unit.call("_faction_id") as int
	# Aircraft don't currently carry _faction_id; derive from
	# MatchSettings via owner_id 0 = local player faction.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and "player_faction" in settings:
		var owner_id: int = (_unit.get("owner_id") as int) if _unit and "owner_id" in _unit else 0
		if owner_id == 0:
			return settings.get("player_faction") as int
	return 0


func _firing_observable() -> bool:
	## True when the local player can see the shooter or the target.
	## Both being in fog means the engagement is happening off-screen
	## and shouldn't leak audio / muzzle flashes / projectile trails
	## through scouted-but-not-currently-visible cells.
	var fow: Node = get_tree().current_scene.get_node_or_null("FogOfWar") if get_tree() else null
	if not fow or not fow.has_method("is_visible_world"):
		return true  # No FOW system = no gate.
	if _unit and is_instance_valid(_unit):
		if fow.call("is_visible_world", _unit.global_position):
			return true
	if _current_target and is_instance_valid(_current_target):
		if fow.call("is_visible_world", _current_target.global_position):
			return true
	return false


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
