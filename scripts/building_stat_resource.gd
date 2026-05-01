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
## must be present). The ID matches `building_id` on the prerequisite.
@export var prerequisites: Array[StringName] = []
