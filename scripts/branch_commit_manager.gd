class_name BranchCommitManager
extends Node
## Manages branch commit state. Tracks which unit types have been committed
## and applies upgrades globally to all existing units. Multiple commits
## (one per base unit type) can run in parallel so a player with two or
## more armories can research distinct branches concurrently. The
## per-base-unit lock still prevents committing the same unit's branch
## from two armories at once.

## Emitted when a branch commit completes.
signal branch_committed(base_unit_name: String, branch_name: String)

## Map of base unit name → committed branch stats resource.
## Empty = no branch committed yet for that unit type.
var _committed_branches: Dictionary = {}

## Map of base_unit_name -> commit dict { "base_stats": Resource,
## "branch_stats": Resource, "branch_name": String, "timer": float,
## "duration": float }. Multiple entries = multiple parallel commits
## (one per base unit type, capped by the player's armory count).
var _active_commits: Dictionary = {}

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
	if _active_commits.is_empty():
		return
	# Walk a snapshot so a finish() call removing the entry mid-loop
	# doesn't trip the iterator.
	var keys: Array = _active_commits.keys()
	for key_v: Variant in keys:
		var key: String = key_v as String
		if not _active_commits.has(key):
			continue
		var commit: Dictionary = _active_commits[key] as Dictionary
		commit["timer"] = (commit["timer"] as float) + delta
		_active_commits[key] = commit
		if (commit["timer"] as float) >= (commit["duration"] as float):
			_finish_commit(key)


func is_committing() -> bool:
	## True when ANY branch commit is in flight. Kept as a global
	## predicate for the HUD's match-wide "research line".
	return not _active_commits.is_empty()


func is_committing_unit(base_unit_name: String) -> bool:
	## True when THIS specific base unit's branch commit is in flight.
	## The armory row uses this to decide whether to render its branch
	## buttons or the cancel-with-progress button.
	return _active_commits.has(base_unit_name)


func get_active_commit_keys() -> Array[String]:
	## Snapshot of base_unit_names currently mid-commit. Used by the
	## HUD global-queue line to render one progress chip per active
	## commit instead of squashing them into a single line.
	var out: Array[String] = []
	for k_v: Variant in _active_commits.keys():
		out.append(k_v as String)
	return out


func get_commit_progress(base_unit_name: String = "") -> float:
	## Without an argument, returns the FIRST active commit's progress
	## so older callers that only ran one commit at a time still work.
	## With a name, returns that specific commit's progress (0..1).
	var commit: Dictionary = _resolve_commit(base_unit_name)
	if commit.is_empty():
		return 0.0
	var timer: float = commit["timer"] as float
	var duration: float = commit["duration"] as float
	return clampf(timer / duration, 0.0, 1.0)


func get_commit_branch_name(base_unit_name: String = "") -> String:
	var commit: Dictionary = _resolve_commit(base_unit_name)
	if commit.is_empty():
		return ""
	return commit["branch_name"] as String


func get_commit_base_stats(base_unit_name: String = "") -> UnitStatResource:
	## Active commit's BASE unit stats — the row owner. Lets the HUD
	## show a cancel button on the matching armory row instead of all
	## of them. Without an argument, returns the first active commit
	## (legacy single-commit behaviour).
	var commit: Dictionary = _resolve_commit(base_unit_name)
	if commit.is_empty():
		return null
	return commit["base_stats"] as UnitStatResource


func _resolve_commit(base_unit_name: String) -> Dictionary:
	if base_unit_name != "":
		return _active_commits.get(base_unit_name, {}) as Dictionary
	if _active_commits.is_empty():
		return {}
	# Pick the alphabetically-first key for determinism so callers
	# that pass "" twice in the same frame see the same data.
	var keys: Array = _active_commits.keys()
	keys.sort()
	return _active_commits[keys[0]] as Dictionary


func has_committed(base_unit_name: String) -> bool:
	return _committed_branches.has(base_unit_name)


func get_committed_stats(base_unit_name: String) -> UnitStatResource:
	if _committed_branches.has(base_unit_name):
		return _committed_branches[base_unit_name] as UnitStatResource
	return null


func start_commit(base_stats: UnitStatResource, branch_stats: UnitStatResource, branch_name: String) -> bool:
	## Per-base-unit lock: rejects if this base already has an active
	## commit (so two armories can't double-commit the same unit) or
	## if the branch is already finalised. Distinct base units run in
	## parallel without contention.
	if not base_stats:
		return false
	if is_committing_unit(base_stats.unit_name):
		return false
	if has_committed(base_stats.unit_name):
		return false

	_active_commits[base_stats.unit_name] = {
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


func cancel_commit(base_unit_name: String = "") -> bool:
	## Aborts a specific in-flight commit. With an empty name, cancels
	## the first active commit (matches the legacy single-commit
	## behaviour). Caller refunds the cost via its ResourceManager.
	if _active_commits.is_empty():
		return false
	var key: String = base_unit_name
	if key == "":
		var keys: Array = _active_commits.keys()
		keys.sort()
		key = keys[0] as String
	if not _active_commits.has(key):
		return false
	_active_commits.erase(key)
	return true


func _finish_commit(base_unit_name: String) -> void:
	if not _active_commits.has(base_unit_name):
		return
	var commit: Dictionary = _active_commits[base_unit_name] as Dictionary
	var base_stats: UnitStatResource = commit["base_stats"] as UnitStatResource
	var branch_stats: UnitStatResource = commit["branch_stats"] as UnitStatResource
	var branch_name: String = commit["branch_name"] as String

	_committed_branches[base_stats.unit_name] = branch_stats
	_active_commits.erase(base_unit_name)

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
