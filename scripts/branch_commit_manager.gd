class_name BranchCommitManager
extends Node
## Manages branch commit state. Tracks which unit types have been committed
## and applies upgrades globally to all existing units.

## Emitted when a branch commit completes.
signal branch_committed(base_unit_name: String, branch_name: String)

## Map of base unit name → committed branch stats resource.
## Empty = no branch committed yet for that unit type.
var _committed_branches: Dictionary = {}

## Active commit in progress: { "base_stats": Resource, "branch_stats": Resource,
## "branch_name": String, "timer": float, "duration": float }
var _active_commit: Dictionary = {}

const COMMIT_DURATION: float = 20.0

## Resource cost of a branch commit. Microchips are the primary
## currency (rare, satellite-crash drops); fuel is the secondary
## (most upgrades cost more fuel than salvage); salvage is a small
## token nudge so the player has paid into all three pools. These
## are the SAME for every branch in v1 — the upgrade IS the
## investment, regardless of unit class. Tier-specific scaling can
## come later if the cheap-Rook / expensive-Bulwark branches feel
## too uniform.
const COMMIT_COST_MICROCHIPS: int = 2
const COMMIT_COST_FUEL: int = 60
const COMMIT_COST_SALVAGE: int = 30


func _process(delta: float) -> void:
	if _active_commit.is_empty():
		return

	_active_commit["timer"] = (_active_commit["timer"] as float) + delta
	var timer: float = _active_commit["timer"] as float
	var duration: float = _active_commit["duration"] as float

	if timer >= duration:
		_finish_commit()


func is_committing() -> bool:
	return not _active_commit.is_empty()


func get_commit_progress() -> float:
	if _active_commit.is_empty():
		return 0.0
	var timer: float = _active_commit["timer"] as float
	var duration: float = _active_commit["duration"] as float
	return clampf(timer / duration, 0.0, 1.0)


func get_commit_branch_name() -> String:
	if _active_commit.is_empty():
		return ""
	return _active_commit["branch_name"] as String


func get_commit_base_stats() -> UnitStatResource:
	## Active commit's BASE unit stats — the row owner. Lets the HUD
	## show a cancel button on the matching armory row instead of all
	## of them.
	if _active_commit.is_empty():
		return null
	return _active_commit["base_stats"] as UnitStatResource


func has_committed(base_unit_name: String) -> bool:
	return _committed_branches.has(base_unit_name)


func get_committed_stats(base_unit_name: String) -> UnitStatResource:
	if _committed_branches.has(base_unit_name):
		return _committed_branches[base_unit_name] as UnitStatResource
	return null


func start_commit(base_stats: UnitStatResource, branch_stats: UnitStatResource, branch_name: String) -> bool:
	if is_committing():
		return false
	if has_committed(base_stats.unit_name):
		return false

	_active_commit = {
		"base_stats": base_stats,
		"branch_stats": branch_stats,
		"branch_name": branch_name,
		"timer": 0.0,
		"duration": COMMIT_DURATION,
	}

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_production_started"):
		audio.play_production_started()

	return true


func cancel_commit() -> bool:
	## Aborts the in-flight branch commit. Returns true if a commit was
	## actually cancelled. The caller (HUD) is responsible for refunding
	## the cost via the player ResourceManager so the manager stays
	## resource-agnostic.
	if _active_commit.is_empty():
		return false
	_active_commit.clear()
	return true


func _finish_commit() -> void:
	var base_stats: UnitStatResource = _active_commit["base_stats"] as UnitStatResource
	var branch_stats: UnitStatResource = _active_commit["branch_stats"] as UnitStatResource
	var branch_name: String = _active_commit["branch_name"] as String

	_committed_branches[base_stats.unit_name] = branch_stats
	_active_commit.clear()

	# Upgrade all existing units of this type
	_upgrade_existing_units(base_stats, branch_stats)

	branch_committed.emit(base_stats.unit_name, branch_name)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_construction_complete"):
		audio.play_construction_complete()


func _upgrade_existing_units(base_stats: UnitStatResource, branch_stats: UnitStatResource) -> void:
	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not ("stats" in node):
			continue
		var unit_stats: UnitStatResource = node.get("stats") as UnitStatResource
		if not unit_stats:
			continue
		# Match by unit_name (base Hound → upgrade to Tracker/Ripper)
		if unit_stats.unit_name == base_stats.unit_name:
			node.set("stats", branch_stats)
			# Re-init HP with new stats (heal to new max)
			if node.has_method("_init_hp"):
				node._init_hp()
			# Rebuild visuals so the upgrade reads on existing squads.
			# Unit uses `_build_squad_visuals`, not the Building-only
			# `_apply_placeholder_shape` we used to call here.
			if node.has_method("_build_squad_visuals"):
				node._build_squad_visuals()
