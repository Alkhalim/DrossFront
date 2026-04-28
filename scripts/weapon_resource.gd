class_name WeaponResource
extends Resource
## Defines a single weapon's properties for a unit.

## Display name.
@export var weapon_name: String = ""

## Role tag: "AP", "AA", "AAir", "AS", "Universal"
@export var role_tag: StringName = &"Universal"

## Damage tier: "very_low", "low", "moderate", "high", "very_high", "extreme"
@export var damage_tier: StringName = &"moderate"

## Range tier: "melee", "short", "medium", "long", "very_long", "extreme"
@export var range_tier: StringName = &"medium"

## Rate of fire tier: "single", "slow", "moderate", "fast", "volley", "continuous"
@export var rof_tier: StringName = &"moderate"
