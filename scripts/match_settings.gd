class_name MatchSettingsClass
extends Node
## Autoload that carries the player's lobby choices (difficulty, tutorial)
## from the main menu into the match scene. Registered in project.godot
## as `MatchSettings` so any node can read e.g. `MatchSettings.difficulty`.

enum Difficulty { EASY, NORMAL, HARD }
enum Mode { ONE_V_ONE, TWO_V_TWO }
## V2 ships two hand-crafted maps. Foundry Belt is the original cluttered
## industrial map (the v1 test arena, kept and expanded). Ashplains
## Crossing is the new wide-open ash-flats map with a single ridgeline
## and minimal cover — tests heavy mech / ranged combat.
enum MapId { FOUNDRY_BELT, ASHPLAINS_CROSSING }
## V3 introduces Sable as the second playable faction. Two factions are
## enough to validate the asymmetric architecture (Pillar 1 of the V3
## scope); Synod / Inheritors come later.
enum FactionId { ANVIL, SABLE }

## Picked on the main menu before launching a match.
var difficulty: Difficulty = Difficulty.NORMAL
## True when the player launched via the Tutorial button — the HUD shows a
## controls overlay on first load.
var tutorial_mode: bool = false
## Match format. ONE_V_ONE = local human vs one AI; TWO_V_TWO = local human +
## one AI ally vs two AI enemies (Pillar 3 architecture sanity check).
var mode: Mode = Mode.ONE_V_ONE
## Hand-crafted map the match is fought on.
var map_id: MapId = MapId.FOUNDRY_BELT
## Local human player's faction.
var player_faction: FactionId = FactionId.ANVIL
## Faction the AI opponent (or each AI enemy in 2v2) plays. ANVIL by
## default — Sable AI gets enabled once Sable's roster is wired up.
var enemy_faction: FactionId = FactionId.ANVIL


func get_faction_label(f: FactionId) -> String:
	match f:
		FactionId.SABLE: return "Sable Concord"
		_: return "Anvil Directive"


func get_map_label() -> String:
	match map_id:
		MapId.ASHPLAINS_CROSSING: return "Ashplains Crossing"
		_: return "Foundry Belt"


func get_difficulty_label() -> String:
	match difficulty:
		Difficulty.EASY: return "Easy"
		Difficulty.HARD: return "Hard"
		_: return "Normal"


## Scales the AI's passive salvage trickle and unit costs effectively.
func get_ai_economy_multiplier() -> float:
	match difficulty:
		Difficulty.EASY: return 0.6
		Difficulty.HARD: return 1.6
		_: return 1.0


## Scales how many units the AI sends per wave and how quickly it shifts
## from economy → army → attack states.
func get_ai_aggression_multiplier() -> float:
	match difficulty:
		Difficulty.EASY: return 0.7
		Difficulty.HARD: return 1.4
		_: return 1.0
