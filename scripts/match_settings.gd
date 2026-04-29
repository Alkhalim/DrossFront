class_name MatchSettingsClass
extends Node
## Autoload that carries the player's lobby choices (difficulty, tutorial)
## from the main menu into the match scene. Registered in project.godot
## as `MatchSettings` so any node can read e.g. `MatchSettings.difficulty`.

enum Difficulty { EASY, NORMAL, HARD }

## Picked on the main menu before launching a match.
var difficulty: Difficulty = Difficulty.NORMAL
## True when the player launched via the Tutorial button — the HUD shows a
## controls overlay on first load.
var tutorial_mode: bool = false


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
