class_name CheatManager
extends Node
## Holds match-wide cheat state. Lives as a scene child so the rest of
## the systems (Building prereq checks, HUD lockup, ResourceManager
## fills) can opt into the cheat overrides via a single get_node lookup.
##
## Cheats are intentionally simple boolean toggles or one-shot actions
## triggered by typed codes from the chat input. No persistence -- each
## match starts fresh.

## When true, every unit unlock_prerequisite + every building
## prerequisite check returns true automatically. Lets the player
## prototype the late-game roster without having to walk the tech
## tree every match.
var tech_craze: bool = false

## Multiplies build / production speed (engineer construction +
## HQ/Foundry unit training) for the local player. 1.0 = normal.
## Set to 5.0 by the geschwindigkeit cheat.
var build_speed_mult: float = 1.0

## When true, every building's power-efficiency lookup returns 1.0
## regardless of consumption vs production — i.e. "infinite power".
## Set by cashmoneten so the player isn't throttled mid-test.
var infinite_power: bool = false


func cheat_catalogue() -> Array:
	## Returns every recognised cheat as { code, desc } pairs. Used by
	## the HUD's chat help overlay so the listing lives next to the
	## apply_code dispatch -- adding a new cheat means updating one
	## file, not two.
	return [
		{"code": "techcraze", "desc": "Unlock every unit + building tech gate for the rest of the match."},
		{"code": "cashmoneten", "desc": "Fill salvage / fuel / microchips / contracts to cap + infinite Power."},
		{"code": "geschwindigkeit", "desc": "5x build + train speed for the rest of the match."},
		{"code": "einfachturbo", "desc": "Applies cashmoneten + geschwindigkeit + techcraze in one go."},
		{"code": "nofog", "desc": "Disable fog of war for the local player."},
	]


func apply_code(raw: String) -> String:
	## Normalises the typed cheat code, applies its effect, and
	## returns a short status line for the chat HUD to echo back.
	## Empty return means the input wasn't a recognised cheat (the
	## chat HUD treats that as "do nothing").
	var code: String = raw.strip_edges().to_lower()
	if code == "":
		return ""
	match code:
		"techcraze":
			tech_craze = true
			return "Cheat: tech tree unlocked."
		"cashmoneten":
			_max_resources_for_local_player()
			_max_contracts_for_local_player()
			infinite_power = true
			return "Cheat: max resources + contracts + infinite Power."
		"geschwindigkeit":
			build_speed_mult = 5.0
			return "Cheat: build / train speed x5."
		"einfachturbo":
			tech_craze = true
			_max_resources_for_local_player()
			_max_contracts_for_local_player()
			infinite_power = true
			build_speed_mult = 5.0
			return "Cheat: einfachturbo — tech, resources, contracts, power, x5 speed."
		"nofog":
			if _set_omniscient_local():
				return "Cheat: fog of war disabled."
			return "Cheat: no fog-of-war system in this scene."
	return "Unknown cheat: %s" % code


func _max_contracts_for_local_player() -> void:
	## Top up the local player's Meridian contract pool. No-op for
	## non-Meridian players (Anvil / Inheritor / Heliarch never had a
	## contract pool to fill).
	var mcm: Node = get_tree().current_scene.get_node_or_null("MeridianContractsManager") if get_tree() else null
	if mcm == null or not mcm.has_method("refund"):
		return
	# refund() caps at MAX_CONTRACTS so passing a large value safely
	# fills the pool to whatever the current ceiling is.
	mcm.call("refund", 0, 99)


func _set_omniscient_local() -> bool:
	## Flips FogOfWar.omniscient_local on so the local player sees the
	## entire map + every enemy entity. Returns false if no FOW node is
	## present in the current scene (so the chat HUD can echo a useful
	## message rather than 'cheat applied' silently).
	var fow: FogOfWar = get_tree().current_scene.get_node_or_null("FogOfWar") as FogOfWar if get_tree() else null
	if not fow:
		return false
	fow.omniscient_local = true
	return true


func _max_resources_for_local_player() -> void:
	## Grants the local player's resource manager the cap on every
	## resource pool. Looks up the manager by the standard scene path
	## so the cheat works without wiring extra references.
	var rm: Node = get_tree().current_scene.get_node_or_null("ResourceManager") if get_tree() else null
	if not rm:
		return
	if rm.has_method("add_salvage"):
		rm.call("add_salvage", ResourceManager.SALVAGE_CAP)
	if rm.has_method("add_fuel"):
		var cap: int = (rm.get("fuel_cap") as int) if "fuel_cap" in rm else ResourceManager.FUEL_CAP_BASE
		rm.call("add_fuel", cap)
	if rm.has_method("add_microchips"):
		rm.call("add_microchips", ResourceManager.MICROCHIPS_CAP)
