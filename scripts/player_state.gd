class_name PlayerState
extends Resource
## Per-player metadata: identity, team, color, faction. One instance per
## participant in a match (player + AI opponents + AI allies + neutral).
##
## This is the v2 PlayerState abstraction — it lets the rest of the codebase
## reason about *which player and which team* an action belongs to instead of
## hardcoding `owner_id == 0` everywhere. For 1v1 it's straightforward
## (player on team 0, AI on team 1, neutrals on team 2); for the 2v2 work
## later in v2 the same shape extends without each system needing its own
## ad-hoc player/team logic.

## Stable id used as the unit/building `owner_id` value. 0 = local human,
## 1+ = AI / other-human players, 2 reserved for neutrals (deposit guards
## and the like) until v2's 2v2 work expands the live-player count.
@export var player_id: int = 0

## Team grouping for friend / foe checks. Two players on the same team are
## allied: friendly fire off, vision shared, gifting allowed.
@export var team_id: int = 0

## Faction shapes/colors come from this resource. Players can be on the
## same faction with different player_color (per `05_player_colors.md`).
@export var faction_id: StringName = &"anvil"

## Per-player accent — the small overlays / banners / minimap dots. Faction
## paint stays the same across same-faction players; this is the secondary
## tint that distinguishes them.
@export var player_color: Color = Color(0.15, 0.45, 0.9, 1.0)

## True for the local human, false for AI. Networked humans are still false
## here — they're just AI from this client's perspective until netcode lands.
@export var is_human: bool = false

## Friendly UI string ("Player", "AI Bravo", "Neutral").
@export var display_name: String = ""

## True while at least one HQ-class building survives. Match end logic flips
## this to false; ResourceManager / vision systems can then short-circuit.
var is_alive: bool = true


static func make(p_id: int, t_id: int, color: Color, human: bool = false, name: String = "") -> PlayerState:
	var s := PlayerState.new()
	s.player_id = p_id
	s.team_id = t_id
	s.player_color = color
	s.is_human = human
	s.display_name = name if name != "" else "Player %d" % p_id
	return s
