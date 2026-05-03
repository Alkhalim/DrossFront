class_name CombatTables
extends RefCounted
## Static lookup tables for combat resolution.
## All tier StringNames map to numeric values used in damage calculations.

## Damage per shot by tier.
const DAMAGE_MAP: Dictionary = {
	&"very_low": 5,
	&"low": 12,
	&"moderate": 25,
	&"high": 50,
	&"very_high": 85,
	&"extreme": 150,
}

## Weapon range in world units by tier.
const RANGE_MAP: Dictionary = {
	&"melee": 2.0,
	&"short": 8.0,
	&"medium": 15.0,
	&"long": 25.0,
	&"very_long": 40.0,
	&"extreme": 60.0,
}

## Seconds between shots by tier.
const ROF_MAP: Dictionary = {
	&"single": 4.0,
	&"slow": 2.0,
	&"moderate": 1.0,
	&"fast": 0.5,
	&"rapid": 0.25,
	&"volley": 0.3,
	&"continuous": 0.15,
}

## Flat damage reduction by armor class (0.0 to 1.0).
const ARMOR_MAP: Dictionary = {
	&"unarmored": 0.0,
	&"light": 0.15,
	&"medium": 0.30,
	&"heavy": 0.45,
	# Structures bumped 0.30 -> 0.45 so a packed early-rush of light
	# AP fire (Rooks / Specters / Hounds) takes appreciably longer to
	# eat through a Foundry or HQ. Structure-class buildings already
	# have role-tag protection vs AP (0.4 ROLE_VS_ARMOR multiplier);
	# the armor-reduction bump compounds it so the early-game
	# bumrush has to actually invest something heavier than chaingun
	# infantry. AS (anti-structure) tagged weapons -- bombs, siege
	# guns, the dedicated structure crackers -- aren't slowed
	# meaningfully because their ROLE_VS_ARMOR multiplier is high
	# enough that the extra 15% reduction hardly registers on the
	# total.
	&"structure": 0.45,
	# V3 §"Pillar 3" — aircraft armor classes. Light Air = drones,
	# interceptors. Heavy Air = bombers, gunships, Wraith.
	&"light_air": 0.10,
	&"heavy_air": 0.35,
}

## Role tag effectiveness vs armor class. Nested: ROLE_VS_ARMOR[role][armor] -> float.
## V3 adds the AAir tag — anti-air weapons that primarily target aircraft.
## Most ground-targeting weapons have weak/zero effectiveness against aircraft;
## AAir weapons are essentially the only way to reliably hit Light/Heavy Air.
const ROLE_VS_ARMOR: Dictionary = {
	&"AP": {
		# AP = light-armor specialist: full damage vs unarmored /
		# light / light air (1.0x), weak vs medium / heavy ground,
		# moderate vs heavy air. The original AP role had a 2:1
		# light_air-to-heavy_air ratio (0.2 / 0.1); preserved here at
		# 1.0 / 0.5. Existing AP weapons that opted into can_hit_air
		# carry an `air_damage_mult` of 0.2 so their TRUE air output
		# stays at the pre-rebalance value (0.2 * 5 boost = 1.0x net).
		# New AP weapons (e.g. Hammerhead Escort pintle) leave
		# air_damage_mult at 1.0 to take the full air buff.
		&"unarmored": 1.0, &"light": 1.0, &"medium": 0.4,
		&"heavy": 0.3, &"structure": 0.4,
		&"light_air": 1.0, &"heavy_air": 0.5,
	},
	&"AA": {
		&"unarmored": 0.8, &"light": 0.5, &"medium": 0.8,
		&"heavy": 1.2, &"structure": 0.6,
		&"light_air": 0.3, &"heavy_air": 0.4,
	},
	&"AAir": {
		# Anti-air specialists — strong vs aircraft, basically useless
		# vs ground (so SAM sites etc. can't double as ground turrets).
		&"unarmored": 0.0, &"light": 0.0, &"medium": 0.0,
		&"heavy": 0.0, &"structure": 0.0,
		&"light_air": 1.2, &"heavy_air": 1.0,
	},
	&"Universal": {
		# Bumped medium to 1.0 so every Universal-tagged weapon has at
		# least one role-vs-armor multiplier of 1x, satisfying the
		# "each unit's raw damage should match at least one target
		# class" rule that keeps the panel's DPS readout from
		# overstating a weapon that does <1x against everything.
		# Universal stays the generalist (decent vs anything, strong
		# vs nothing); medium = canonical mech armor reads as the
		# weapon's "tuned for" class.
		&"unarmored": 0.8, &"light": 0.8, &"medium": 1.0,
		&"heavy": 0.8, &"structure": 0.8,
		&"light_air": 0.4, &"heavy_air": 0.3,
	},
	&"AAir_Light": {
		# Light anti-air with token ground capability. Used by units
		# whose role is "shoot down aircraft, can chip ground" --
		# Phalanx Drone is the canonical case: 1.0x vs LtAir cleanly,
		# 0.2x vs HvAir (heavy gunships shrug it off), low ground
		# multipliers so the unit's ground DPS reads as token
		# self-defense rather than a real ground threat.
		&"unarmored": 0.40, &"light": 0.35, &"medium": 0.28,
		&"heavy": 0.10, &"structure": 0.15,
		&"light_air": 1.0, &"heavy_air": 0.2,
	},
	&"AB": {
		# Anti-Building / heavy bomber pintle. Punishes structures and
		# ignores aircraft entirely; ground multipliers slope 0.1 / 0.2
		# / 0.3 so the gun is *intentionally* poor against ground mechs
		# (the player should see this number tank against light infantry
		# and pop against a foundry). Used by the Hammerhead Gunship's
		# pintle so the unit reads as a structure cracker rather than a
		# generalist gunship.
		&"unarmored": 0.10, &"light": 0.10, &"medium": 0.20,
		&"heavy": 0.30, &"structure": 2.00,
		&"light_air": 0.00, &"heavy_air": 0.00,
	},
	&"AS": {
		# Anti-structure -- the dedicated building cracker (Wraith
		# bombs, Hammerhead Bomber payload, Rook Sapper charges,
		# Bulwark Siegebreaker). Bumped structure multiplier
		# 1.5 -> 2.5 per balance request: AS units were eating their
		# anti-building punch against the recently-buffed structure
		# armor (now 0.45 reduction), so a Hammerhead Bomber's bomb
		# read as low even on its supposed-best target.
		&"unarmored": 0.6, &"light": 0.6, &"medium": 0.6,
		&"heavy": 0.7, &"structure": 2.5,
		&"light_air": 0.2, &"heavy_air": 0.2,
	},
}

## Directional armor multipliers (applied to incoming damage).
const DIR_FRONT: float = 0.7
const DIR_SIDE: float = 1.0
const DIR_REAR: float = 1.3


static func get_damage(tier: StringName) -> int:
	if DAMAGE_MAP.has(tier):
		return DAMAGE_MAP[tier] as int
	return 25


static func get_range(tier: StringName) -> float:
	if RANGE_MAP.has(tier):
		return RANGE_MAP[tier] as float
	return 15.0


static func get_rof(tier: StringName) -> float:
	if ROF_MAP.has(tier):
		return ROF_MAP[tier] as float
	return 1.0


static func get_armor_reduction(armor_class: StringName) -> float:
	if ARMOR_MAP.has(armor_class):
		return ARMOR_MAP[armor_class] as float
	return 0.0


static func get_role_modifier(role_tag: StringName, armor_class: StringName) -> float:
	var role_key: StringName = role_tag
	if not ROLE_VS_ARMOR.has(role_key):
		role_key = &"Universal"
	var role_dict: Dictionary = ROLE_VS_ARMOR[role_key] as Dictionary
	if role_dict.has(armor_class):
		return role_dict[armor_class] as float
	return 0.8


static func get_directional_multiplier(attacker_pos: Vector3, target: Node3D) -> float:
	var to_attacker: Vector3 = (attacker_pos - target.global_position).normalized()
	to_attacker.y = 0.0
	var target_forward: Vector3 = -target.global_basis.z.normalized()
	target_forward.y = 0.0

	if to_attacker.length_squared() < 0.001 or target_forward.length_squared() < 0.001:
		return DIR_SIDE

	var dot: float = to_attacker.normalized().dot(target_forward.normalized())
	if dot > 0.5:
		return DIR_FRONT
	elif dot < -0.5:
		return DIR_REAR
	return DIR_SIDE
