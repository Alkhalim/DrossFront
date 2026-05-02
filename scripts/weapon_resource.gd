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

## V3 §"Pillar 5 — Accuracy". Base hit chance (0.0 .. 1.0) before
## modifiers (squad strength, Mesh, cover, range, movement).
## Defaults match the spec's standard-autocannon value (0.82); override
## per-weapon for guided missiles (0.92), beams (0.95), dumbfire
## rockets (0.60), artillery (0.75), etc. Final hit chance is clamped
## to [0.30, 0.99] in CombatComponent so no shot is impossible and no
## non-elite shot is guaranteed.
@export_range(0.0, 1.0, 0.01) var base_accuracy: float = 0.82
