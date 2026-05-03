class_name UnitStatResource
extends Resource
## Defines a unit type's base stats. One per unit class (not per instance).
## Branch variants are separate UnitStatResource files.

## Stable identifier used by code paths that dispatch on unit type
## (overlay builders, ability dispatch, etc.). Player-facing UI
## should use display_name instead, falling back to unit_name when
## display_name is empty.
@export var unit_name: String = ""

## Display name shown in UI -- production buttons, unit panels,
## tooltips. When empty, callers fall back to unit_name. Used to
## decouple the player-facing reflavoring (e.g. 'KV-0 Field
## Engineer') from the internal type identifier ('Ratchet') the
## overlay / ability dispatch logic still matches on.
@export var display_name: String = ""


func get_display_name() -> String:
	if display_name != "":
		return display_name
	return unit_name

## Unit role for production/categorization: "engineer", "light", "medium", "heavy", "apex"
@export var unit_class: StringName = &"light"

## Total HP across the full squad.
@export var hp_total: int = 0

## HP per individual member of the squad.
@export var hp_per_unit: int = 0

## Armor class: "unarmored", "light", "medium", "heavy", "apex", "structure"
@export var armor_class: StringName = &"light"

## Aircraft only: when true the unit's idle + attack movement
## switches to bomber behaviour -- circles its loiter point when
## idle, and circles its combat target dropping bombs instead of
## hovering and firing missiles. Default false; set on the
## Hammerhead Bomber branch.
@export var bomber_behaviour: bool = false

## Speed tier: "static", "very_slow", "slow", "moderate", "fast", "very_fast"
@export var speed_tier: StringName = &"moderate"

## Sight tier: "short", "medium", "long", "very_long", "extreme"
@export var sight_tier: StringName = &"medium"

## Numeric overrides for the tier lookups. -1 (default) = use the
## tier table. Set to a concrete value to override per-unit during
## balance work without shifting the whole tier table.
##
## Tier-resolved defaults for reference:
##   speed_tier (units/s):  static=0, very_slow=3, slow=5,
##                          moderate=8, fast=12, very_fast=16
##   sight_tier (units):    short=12, medium=18, long=26,
##                          very_long=36, extreme=50
##   armor_class (% red):   unarmored=0, light=15, medium=30,
##                          heavy=45, structure=30,
##                          light_air=10, heavy_air=35
@export var speed_value: float = -1.0
@export var sight_radius_value: float = -1.0
## Flat damage reduction (0.0..1.0). -1 = use armor_class default.
@export var armor_reduction_value: float = -1.0


func resolved_speed() -> float:
	if speed_value >= 0.0:
		return speed_value
	# UNIT_SPEED_MAP duplicates Unit.SPEED_MAP — kept on the resource
	# so balance code (HUD readouts, AI heuristics) can look up speed
	# without importing Unit.gd.
	const UNIT_SPEED_MAP: Dictionary = {
		&"static": 0.0, &"very_slow": 3.0, &"slow": 5.0,
		&"moderate": 8.0, &"fast": 12.0, &"very_fast": 16.0,
	}
	return UNIT_SPEED_MAP.get(speed_tier, 8.0) as float


func resolved_sight_radius() -> float:
	if sight_radius_value >= 0.0:
		return sight_radius_value
	const SIGHT_MAP: Dictionary = {
		&"short": 12.0, &"medium": 18.0, &"long": 26.0,
		&"very_long": 36.0, &"extreme": 50.0,
	}
	return SIGHT_MAP.get(sight_tier, 18.0) as float


func resolved_armor_reduction() -> float:
	if armor_reduction_value >= 0.0:
		return armor_reduction_value
	return CombatTables.get_armor_reduction(armor_class)


func can_target_air() -> bool:
	## True when at least one of the unit's weapons can fire at air
	## (per WeaponResource.engages_air()). Lets a unit qualify as
	## anti-air via either an AAir-tag weapon OR a generalist
	## weapon that opted in via can_hit_air, without committing the
	## unit to a single-purpose role.
	if primary_weapon and primary_weapon.engages_air():
		return true
	if secondary_weapon and secondary_weapon.engages_air():
		return true
	return false

## Number of units in a full-strength squad.
@export var squad_size: int = 1

## Population cost toward the 100-pop cap.
@export var population: int = 0

## Salvage cost to produce.
@export var cost_salvage: int = 0

## Fuel cost to produce.
@export var cost_fuel: int = 0

## Build time in seconds.
@export var build_time: float = 0.0

## Building required: "headquarters", "basic_foundry", "advanced_foundry", "aerodrome"
@export var built_at: StringName = &"basic_foundry"

## Optional tech-tree gate. Empty = always available once `built_at`
## exists. Non-empty = the listed building (by building_id) must also
## be constructed before this unit can be queued. Building.get_producible_units()
## filters trained-from lists by this prereq, so a unit hidden behind
## an Advanced Armory still lives in its production building's
## producible_units array — the gate just hides it until the prereq
## is satisfied. One id only; the unit/building tech tree is shallow.
@export var unlock_prerequisite: StringName = &""

@export_group("Weapons")
## Primary weapon.
@export var primary_weapon: WeaponResource
## Secondary weapon (if any).
@export var secondary_weapon: WeaponResource

@export_group("Special")
## Brief description of special abilities for tooltips.
@export_multiline var special_description: String = ""

## Whether this unit can build structures.
@export var can_build: bool = false

## Repair rate in HP/sec (0 if cannot repair).
@export var repair_rate: float = 0.0

## When true, Building._spawn_unit instantiates res://scenes/salvage_crawler.tscn
## instead of res://scenes/unit.tscn. The Crawler is a slow mobile harvester
## (v2 spec §1.3) — produced at the HQ but mechanically distinct from a mech.
@export var is_crawler: bool = false

@export_group("Stealth")
## V3 §"Pillar 1 — Stealth System" — when true the unit camouflages
## itself when no enemy is within `detection_radius` and no recent
## damage. Auto-target skips revealed=false stealth units; firing
## doesn't break stealth (Specter can fire from concealment).
@export var is_stealth_capable: bool = false
## Distance at which an enemy unit reveals stealth-capable targets.
## Standard ground = 80, engineers = 100, Glitch Specter = 150,
## Spotter Rook = 200. The unit also stays revealed for
## `stealth_restore_time` after taking damage.
@export var detection_radius: float = 80.0
## Seconds after the last damage before stealth re-applies.
@export var stealth_restore_time: float = 4.0

## First Strike multiplier -- when > 1.0, the unit's first
## attack against any newly-acquired target deals base * mult
## damage. Resets per target so a unit firing on a fresh enemy
## always gets the buffed opening shot. Used by Hound (Ripper) to
## sell the close-range alpha-strike identity. Default 1.0 = no
## bonus.
@export_range(1.0, 3.0, 0.05) var first_strike_bonus: float = 1.0


@export_group("Aircraft")
## V3 §"Pillar 3" — when true the unit spawns as an aircraft (extends
## Aircraft scene, uses simple flight movement instead of NavigationAgent3D
## ground pathing). Aircraft fly at fixed altitude and ignore ground
## obstacles, but can only be hit by AAir weapons.
@export var is_aircraft: bool = false
## Flight altitude in world units. Aircraft maintain this Y above the
## ground. Heavy gunships sit higher than swarm drones so the same
## airspace doesn't crowd visually.
@export var flight_altitude: float = 6.0
## Max flight speed (units / second). Independent of `speed_tier` since
## aircraft don't share the ground-unit speed tiers.
@export var flight_speed: float = 14.0

@export_group("Mesh")
## V3 §"Pillar 2 — Neural Mesh" — when > 0, this unit emits a Mesh
## aura of this radius. Sable units inside 1+ provider auras gain
## stacked accuracy / reload bonuses (capped at 3 providers = 100%
## strength). Examples per spec: Glitch Specter ~18u, Courier Sensor
## Carrier ~24u, Harbinger Overseer ~30u, Pulsefont ~24u.
@export var mesh_provider_radius: float = 0.0

@export_group("Branch Upgrades")
## If this is a base unit, the two branch variant stats.
@export var branch_a_stats: UnitStatResource
@export var branch_b_stats: UnitStatResource
## Branch display names for the Armory UI.
@export var branch_a_name: String = ""
@export var branch_b_name: String = ""

@export_group("Active Ability")
## Empty when this unit has no active ability. When set, the HUD
## adds an action button that calls into Unit.trigger_ability(),
## which dispatches by ability_name to a specific effect.
@export var ability_name: String = ""
## Hotkey shown in the button label and bound for keyboard
## activation while the unit is selected.
@export var ability_hotkey: String = "D"
## Cooldown in seconds between activations.
@export var ability_cooldown: float = 30.0
## Effect radius (units). Interpretation depends on the ability —
## e.g. System Crash silences enemy mech weapons inside this
## radius around the casting unit.
@export var ability_radius: float = 0.0
## Effect duration in seconds (e.g. how long System Crash holds
## enemy weapons silenced).
@export var ability_duration: float = 0.0
## One-line description shown in the button tooltip so the player
## can read what the ability does without leaving the HUD.
@export var ability_description: String = ""
## Auto-cast flag — when true, CombatComponent fires this ability
## automatically every cooldown the unit has a valid target. The
## HUD ability button stays clickable for manual triggers and
## shows a circling dot so the player can read "this is on
## autocast" at a glance.
@export var ability_autocast: bool = false
