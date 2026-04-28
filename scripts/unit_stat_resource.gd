class_name UnitStatResource
extends Resource
## Defines a unit type's base stats. One per unit class (not per instance).
## Branch variants are separate UnitStatResource files.

## Display name shown in UI.
@export var unit_name: String = ""

## Unit role for production/categorization: "engineer", "light", "medium", "heavy", "apex"
@export var unit_class: StringName = &"light"

## Total HP across the full squad.
@export var hp_total: int = 0

## HP per individual member of the squad.
@export var hp_per_unit: int = 0

## Armor class: "unarmored", "light", "medium", "heavy", "apex", "structure"
@export var armor_class: StringName = &"light"

## Speed tier: "static", "very_slow", "slow", "moderate", "fast", "very_fast"
@export var speed_tier: StringName = &"moderate"

## Sight tier: "short", "medium", "long", "very_long", "extreme"
@export var sight_tier: StringName = &"medium"

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

@export_group("Weapons")
## Primary weapon.
@export var primary_weapon: WeaponResource
## Secondary weapon (if any).
@export var secondary_weapon: WeaponResource

@export_group("Squad Bonus")
## Accuracy bonus at full squad strength (0.0 = none, 0.12 = +12%).
@export var squad_strength_bonus: float = 0.0

@export_group("Special")
## Brief description of special abilities for tooltips.
@export_multiline var special_description: String = ""

## Whether this unit can build structures.
@export var can_build: bool = false

## Repair rate in HP/sec (0 if cannot repair).
@export var repair_rate: float = 0.0

@export_group("Branch Upgrades")
## If this is a base unit, the two branch variant stats.
@export var branch_a_stats: UnitStatResource
@export var branch_b_stats: UnitStatResource
## Branch display names for the Armory UI.
@export var branch_a_name: String = ""
@export var branch_b_name: String = ""
