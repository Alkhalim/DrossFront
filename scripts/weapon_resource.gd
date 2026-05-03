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

## Per-shot salvo count. Default 1 = standard one-projectile-per-cooldown
## fire. Set higher (e.g. 6 for the Hammerhead's underwing missile pods)
## to fire a multi-projectile burst on every fire tick. Each projectile
## in the salvo deals the weapon's damage independently — set the per-
## projectile damage_tier lower when raising salvo_count so the total
## per-cooldown damage stays in budget. CombatTables-aware code
## (DPS readout in HUD, fire loop in CombatComponent) multiplies by
## salvo_count automatically.
@export_range(1, 12, 1) var salvo_count: int = 1

@export_group("Numeric overrides (balance work)")
## When non-negative, these fields override the tier defaults from
## CombatTables. -1 (the default) means "use the tier lookup". Lets
## you fine-tune individual weapons without inventing new tier names
## or shifting the entire tier table for one unit.
##
## Tier-resolved defaults for reference (from CombatTables):
##   damage_tier:   very_low=5, low=12, moderate=25, high=50,
##                  very_high=85, extreme=150
##   range_tier:    melee=2, short=8, medium=15, long=25,
##                  very_long=40, extreme=60
##   rof_seconds:   single=4.0, slow=2.0, moderate=1.0, fast=0.5,
##                  volley=0.3, rapid=0.25, continuous=0.15
@export var damage_value: int = -1
@export var range_value: float = -1.0
## Seconds between shots. Lower = faster; matches CombatTables.ROF_MAP.
@export var rof_seconds_value: float = -1.0

## Per-weapon air-targeting opt-in. Default false. AAir / AAir_Light
## roles auto-engage air through engages_air() regardless of this flag,
## so set to true only when a non-AAir weapon should also fire at
## aircraft (e.g. Hound's Universal autocannons + Jackal's AP SMGs --
## fast generalist guns that can chip airframes; their slower AT
## missile / rocket secondaries stay air-skipping).
@export var can_hit_air: bool = false

## Per-weapon air damage scalar (multiplied into the damage rolled
## against an aircraft target -- skipped for ground hits). Default
## 1.0 = no per-weapon adjustment. Used to clamp the effective air
## DPS on weapons that pre-date a role-mult buff: e.g. the AP role
## got a 5x light-air buff; existing AP+can_hit_air weapons set this
## to 0.2 to preserve their original true air output, while new AP
## weapons (Hammerhead Escort) leave it at 1.0 to take the full
## buff. Display layer (HUD attack-bonus chips + DPS readout)
## folds this into the displayed multiplier so the player sees the
## real number, not just the role mult.
@export_range(0.0, 1.0, 0.01) var air_damage_mult: float = 1.0

## Per-weapon overrides for the role-vs-armor multiplier table.
## When > 0, replaces the corresponding CombatTables entry for
## this specific weapon (combat_component reads them in the
## damage assembly). Used to give a single weapon a custom
## armor-class profile without shifting the global role table --
## e.g. Bulwark Heavy AP Cannon overrides AP's vs-medium 0.4 with
## 0.5, vs-heavy 0.3 with 1.0, etc. Default -1 = fall through to
## CombatTables.ROLE_VS_ARMOR.
@export var mult_vs_light: float = -1.0
@export var mult_vs_medium: float = -1.0
@export var mult_vs_heavy: float = -1.0
@export var mult_vs_light_air: float = -1.0
@export var mult_vs_heavy_air: float = -1.0
## Structure variant -- kept separate from the per-armor-class
## block above so the existing wraith-bomb + sapper-charge tres
## files don't need a rename. New weapons can use either path.
@export var structure_damage_mult: float = -1.0

## Tree damage gate. Default false: small-arms / SMGs / minigun
## turrets / continuous-beam lasers can't chew through forest --
## Schwarzwald / dense brush actually means something. Set true
## on slow / heavy weapons that should clear vegetation: rockets
## (Hammerhead missiles), large-caliber slow guns (Bulwark cannon,
## Anvil heavy turret), bombs (Wraith bomb bay), heavy slow
## lasers (Ratchet cutter), flamethrowers, artillery shells.
@export var can_damage_trees: bool = false


## Drone-bay weapon flag. When true, each "shot" of this weapon
## spawns a Drone instead of a regular projectile -- the drone
## flies out from the carrier, fires once at the target, and
## returns. Drone count per fire = salvo_count (default 1; set
## higher for true swarms). Drones die with the carrier.
@export var is_drone_release: bool = false

## Drone variant style. Picks the visual the spawned drone wears
## when is_drone_release is true. Supported: "default" (compact
## generic drone), "missile" (heavier hull with an underslung
## missile pod), "fast" (smaller sleeker drone with a brighter
## thruster). Other values fall through to "default".
@export var drone_variant: StringName = &"default"

## Maximum simultaneously-active drones from this carrier+weapon.
## Combat skips the drone spawn for any salvo shot that would push
## the live count above this cap. Drones queue_free on dock or
## carrier death so the cap recovers naturally. 0 / negative =
## unbounded (don't gate the spawn).
@export var max_active_drones: int = 6


## Bomber-style projectile origin -- when true the projectile spawns
## just below the firing aircraft and arcs onto the target instead
## of leaving from the chassis center. Reads as 'opens bomb bay,
## drops payload' rather than 'fires from above the wing'. Applies
## to the base aircraft fire path (e.g. Hammerhead Bomber's Cluster
## Bomb Bay) and is independent of any active ability that may also
## drop a bomb.
@export var bomb_drop: bool = false


## Buckshot / scatter-fire flag. When true, CombatComponent fires the
## weapon as a cone of pellets per shot instead of a single
## projectile. Damage is still applied once per shot (the visual is
## the buckshot read; the role/mod math is unchanged). Was previously
## inferred from "shotgun" appearing in weapon_name; the explicit
## flag is more robust against branch renames + lets a "scattergun"
## variant qualify without forcing the word into its name.
@export var is_shotgun: bool = false


func engages_air() -> bool:
	## True when the weapon should fire at aircraft. Auto-true for
	## AAir and AAir_Light roles (their multipliers vs air are the
	## whole point); explicit can_hit_air opt-in covers the
	## "generalist primary that can also chip airframes" case.
	if role_tag == &"AAir" or role_tag == &"AAir_Light":
		return true
	return can_hit_air


func resolved_damage() -> int:
	if damage_value >= 0:
		return damage_value
	return CombatTables.get_damage(damage_tier)


func resolved_range() -> float:
	if range_value >= 0.0:
		return range_value
	return CombatTables.get_range(range_tier)


func resolved_rof_seconds() -> float:
	if rof_seconds_value >= 0.0:
		return rof_seconds_value
	return CombatTables.get_rof(rof_tier)


func get_role_mult_for(armor_class: StringName) -> float:
	## Returns the effective role multiplier vs the given armor
	## class. Honours per-weapon overrides first, then falls back to
	## the CombatTables role-vs-armor table. HUD displays + combat
	## damage paths funnel through this so the displayed multiplier
	## always matches what the gun actually does.
	match armor_class:
		&"light":
			if mult_vs_light > 0.0:
				return mult_vs_light
		&"medium":
			if mult_vs_medium > 0.0:
				return mult_vs_medium
		&"heavy":
			if mult_vs_heavy > 0.0:
				return mult_vs_heavy
		&"light_air":
			if mult_vs_light_air > 0.0:
				return mult_vs_light_air
		&"heavy_air":
			if mult_vs_heavy_air > 0.0:
				return mult_vs_heavy_air
		&"structure":
			if structure_damage_mult > 0.0:
				return structure_damage_mult
	return CombatTables.get_role_modifier(role_tag, armor_class)
