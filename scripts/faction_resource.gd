class_name FactionResource
extends Resource
## Defines a playable faction's identity, visual language, and mechanic.
## Faction-specific behavior dispatches through this resource.

## Display name shown in UI and menus.
@export var faction_name: StringName = &""

## Short lore tagline for loading screens / tooltips.
@export var tagline: String = ""

## --- Visual Identity (fixed per faction, never changes with player color) ---

## Base material color — the dominant surface tone of all faction units/structures.
@export var color_base: Color = Color.GRAY

## Internal glow color — glows emanating from inside units (reactor cores, forges, sensors).
## This is the faction's signature and never changes.
@export var color_internal_glow: Color = Color.WHITE

## Detail accent color — small markings, rivets, ornamentation unique to the faction.
@export var color_detail_accent: Color = Color.WHITE

## --- Faction Mechanic ---

## Identifier used to dispatch faction-specific logic.
## Values: "fortification", "neural_mesh", "heat_gauge", "salvage_mastery"
@export var mechanic_id: StringName = &""

## Human-readable mechanic name for UI display.
@export var mechanic_display_name: String = ""

## Brief description of the mechanic for tooltips.
@export_multiline var mechanic_description: String = ""

## --- Production Buildings ---
## These will reference building scene paths once those exist.

@export_group("Buildings")
@export var hq_scene: PackedScene
@export var basic_foundry_scene: PackedScene
@export var advanced_foundry_scene: PackedScene
@export var salvage_yard_scene: PackedScene
@export var generator_scene: PackedScene
@export var armory_scene: PackedScene

## --- Faction-Specific Power Building ---

## The unique power structure for this faction (e.g., Iron Citadel for Anvil).
@export var faction_power_building_scene: PackedScene
@export var faction_power_building_name: String = ""

## --- Unit Roster ---
## References to unit stat resources. Populated as UnitStatResource is built.

@export_group("Unit Roster")
@export var engineer_stats: Resource
@export var light_mech_stats: Resource
@export var medium_mech_stats: Resource
@export var heavy_mech_stats: Resource
