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
## V3 §"Pillar 6" — Iron Gate Crossing is the asymmetric-test map
## with mixed terrain emphasising concealment and flanking.
enum MapId { FOUNDRY_BELT, ASHPLAINS_CROSSING, IRON_GATE_CROSSING }
## V3 introduces Sable as the second playable faction. Two factions are
## enough to validate the asymmetric architecture (Pillar 1 of the V3
## scope); Synod / Inheritors come later.
enum FactionId { ANVIL, SABLE }
## AI build / behaviour archetypes. RANDOM picks one of the four
## non-random options on match start (per-AI). Other values force the
## archetype, e.g. for the menu's "AI Charlie: Turret Heavy" picker.
enum AiPersonality { RANDOM, BALANCED, TURRET_HEAVY, ECONOMY_HEAVY, RUSH }

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

## Player team colour. Picked on the match-setup screen.
## TestArenaController._setup_player_registry overrides the local
## player's roster colour with this value, then auto-shuffles any
## AI colour that collides with a player or earlier-AI pick so no
## two participants share the same swatch.
const PLAYER_COLOR_PALETTE: Array[Color] = [
	Color(0.08, 0.25, 0.85, 1.0),  # blue
	Color(0.80, 0.10, 0.10, 1.0),  # red
	Color(0.18, 0.72, 0.22, 1.0),  # green
	Color(0.95, 0.55, 0.10, 1.0),  # orange
	Color(0.78, 0.35, 1.00, 1.0),  # violet
	Color(0.15, 0.78, 0.95, 1.0),  # cyan
	Color(0.45, 0.30, 0.18, 1.0),  # brown
	Color(0.55, 0.55, 0.58, 1.0),  # grey
	Color(0.95, 0.92, 0.55, 1.0),  # pale yellow
	Color(0.10, 0.42, 0.20, 1.0),  # dark green
]
const PLAYER_COLOR_NAMES: Array[String] = [
	"Blue", "Red", "Green", "Orange", "Violet", "Cyan",
	"Brown", "Grey", "Pale Yellow", "Dark Green",
]
var player_color: Color = Color(0.08, 0.25, 0.85, 1.0)
## Faction the AI opponent (or each AI enemy in 2v2) plays. ANVIL by
## default — Sable AI gets enabled once Sable's roster is wired up.
var enemy_faction: FactionId = FactionId.ANVIL
## Per-AI overrides keyed by player_id. When an entry exists for a
## given AI slot, that AI uses it; otherwise the AI falls back to
## the team-based default (player_faction for allies, enemy_faction
## for enemies; global difficulty; RANDOM personality).
##   ai_factions[player_id]      : FactionId
##   ai_personalities[player_id] : AiPersonality
##   ai_difficulties[player_id]  : Difficulty
var ai_factions: Dictionary = {}
var ai_personalities: Dictionary = {}
var ai_difficulties: Dictionary = {}


func get_ai_personality(player_id: int) -> AiPersonality:
	## Returns the configured personality for an AI, defaulting to
	## RANDOM if the slot wasn't set.
	if ai_personalities.has(player_id):
		return ai_personalities[player_id] as AiPersonality
	return AiPersonality.RANDOM


func get_ai_difficulty(player_id: int) -> Difficulty:
	## Per-AI difficulty falls back to the match's global `difficulty`
	## setting (the legacy field) if no per-AI override is set.
	if ai_difficulties.has(player_id):
		return ai_difficulties[player_id] as Difficulty
	return difficulty


func has_ai_faction(player_id: int) -> bool:
	return ai_factions.has(player_id)


func get_ai_faction(player_id: int) -> FactionId:
	## Per-AI faction override. Callers should check has_ai_faction()
	## first; if no override, the caller's team-based fallback (ally
	## takes player_faction, enemy takes enemy_faction) still applies.
	if ai_factions.has(player_id):
		return ai_factions[player_id] as FactionId
	return enemy_faction


func get_faction_label(f: FactionId) -> String:
	match f:
		FactionId.SABLE: return "Sable Concord"
		_: return "Anvil Directive"


func get_map_label() -> String:
	match map_id:
		MapId.ASHPLAINS_CROSSING: return "The Ashline"
		MapId.IRON_GATE_CROSSING: return "Gatepoint Rhin"
		_: return "Corridor 7"


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
