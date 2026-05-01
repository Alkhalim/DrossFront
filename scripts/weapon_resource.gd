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

## Optional override for the projectile visual style. By default the projectile
## type is inferred from rof_tier (slow → missile, fast → bullet, continuous →
## beam). Set this to "bullet", "missile", or "beam" to force a specific look
## independent of fire rate — used e.g. for the Ratchet's cutting laser, which
## should read as a beam even though it fires at a slow cadence.
@export var projectile_style: StringName = &""
