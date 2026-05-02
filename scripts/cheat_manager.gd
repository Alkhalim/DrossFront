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
			return "Cheat: max resources granted."
	return "Unknown cheat: %s" % code


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
