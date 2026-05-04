class_name BuildingStatResource
extends Resource
## Defines a building type's properties.

## Display name shown in UI.
@export var building_name: String = ""

## Identifier for logic dispatch: "headquarters", "basic_foundry", "advanced_foundry",
## "salvage_yard", "basic_generator", "basic_armory", "gun_emplacement"
@export var building_id: StringName = &""

## Total hit points.
@export var hp: int = 1000

## Salvage cost to construct.
@export var cost_salvage: int = 0

## Fuel cost to construct. Most buildings use 0 (pure salvage); tech /
## research / advanced-air structures (Armory, Advanced Armory, Black
## Pylon, Aerodrome, SAM Site) split their cost between salvage and
## fuel so fuel matters at the building tier, not just the unit tier.
@export var cost_fuel: int = 0

## Construction time in seconds.
@export var build_time: float = 30.0

## Power consumed by this building.
@export var power_consumption: int = 0

## Power produced by this building (generators only).
@export var power_production: int = 0

## Which unit types this building can produce (references to UnitStatResource).
@export var producible_units: Array[UnitStatResource] = []

## Placeholder visual size for the building footprint.
@export var footprint_size: Vector3 = Vector3(4.0, 3.0, 4.0)

## Placeholder visual color.
@export var placeholder_color: Color = Color(0.3, 0.3, 0.3)

## Tech tier — basic structures (foundry, generator, salvage yard,
## armory, turret) are available from the start. Advanced structures
## (advanced foundry, aerodrome, SAM site) are locked until a
## prerequisite is built. The build menu uses this for tab routing.
@export var is_advanced: bool = false

## Building IDs that must be CONSTRUCTED before this one can be built.
## Empty array = always available. Multiple entries are AND-ed (all
## must be present). Stored as plain `Array` of StringName values
## because some Godot 4.x versions have parser issues with
## `Array[StringName]` exports. Loaded values are read as StringName
## by callers.
@export var prerequisites: Array = []

## V3 §"Pillar 2 — Neural Mesh" — when > 0 this building emits a
## Mesh aura. Black Pylon ~35u radius is the largest Mesh provider
## and the strategic anchor.
@export var mesh_provider_radius: float = 0.0

## Faction lock. 0 = available to all, 1 = Anvil only, 2 = Sable
## only. Used by HUD's build menu to filter the buildable list.
@export var faction_lock: int = 0

## Geothermic-vent placement gate. When true, the building can ONLY
## be placed on top of a GeothermicVent (a steam fissure). Used by
## Generators -- power production is now tied to vent locations
## instead of free placement, forcing the player to expand toward
## map-distributed vents instead of camping every building next to
## the HQ.
@export var requires_geothermic_vent: bool = false

@export_group("Superweapon")
## Empty when this building isn't a superweapon. Set to a kind id
## (e.g. &"molot", &"echo") to attach a SuperweaponComponent that
## handles the activation flow + per-kind effect dispatch.
@export var superweapon_kind: StringName = &""
## Seconds the player must wait between firing the superweapon and
## being able to fire it again. Doc spec is 4-5 minutes per weapon.
@export var superweapon_cooldown_sec: float = 240.0
## Seconds spent in the ARMING phase after activation -- the
## telegraph window where the opponent sees the warning before the
## effect lands.
@export var superweapon_arming_sec: float = 15.0
## Seconds the FIRING phase lasts. Some weapons fire instantly
## (EChO paralysis pulse) -- set to 0.0 in that case so the
## component skips straight to cooldown.
@export var superweapon_firing_sec: float = 30.0
## World-unit radius for the superweapon's effect zone. Used by
## both the targeting reticle and the per-kind effect dispatch.
@export var superweapon_radius: float = 30.0
