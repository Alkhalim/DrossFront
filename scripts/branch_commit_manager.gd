class_name BranchCommitManager
extends Node
## Manages branch commit state. Tracks which unit types have been committed
## and applies upgrades to existing units belonging to the COMMITTING PLAYER.
## Multiple commits (one per base unit type per owner) can run in parallel
## so a player with two or more armories can research distinct branches
## concurrently. The per-(owner, base unit) lock prevents committing the
## same unit's branch from two of an owner's armories at once.
##
## Owner-scoped: when the player commits Tracker on Borzoi, only the
## PLAYER's existing + future Borzois receive the upgrade — the enemy
## AI's Borzois keep the base stats. Was previously a single global
## map keyed by unit_name only, which leaked branch upgrades to opponents
## (playtest 2026-05-15).

## Emitted when a branch commit completes. owner_id is the player who
## owns the commit.
signal branch_committed(owner_id: int, base_unit_name: String, branch_name: String)

## Per-owner committed branches: { owner_id: { base_unit_name: branch_stats } }.
var _committed_branches: Dictionary = {}

## Per-owner active commits: { owner_id: { base_unit_name: commit_dict } }.
## commit_dict = { base_stats, branch_stats, branch_name, timer, duration }.
var _active_commits: Dictionary = {}

const COMMIT_DURATION: float = 20.0

## Resource cost of a branch commit. Microchips are the primary
## currency (rare, satellite-crash drops); fuel is the secondary
## (most upgrades cost more fuel than salvage); salvage is a small
## token nudge so the player has paid into all three pools. These
## are the SAME for every branch in v1 — the upgrade IS the
## investment, regardless of unit class. Tier-specific scaling can
## come later if the cheap-Strelet / expensive-Bulwark branches feel
## too uniform.
const COMMIT_COST_MICROCHIPS: int = 2
const COMMIT_COST_FUEL: int = 60
const COMMIT_COST_SALVAGE: int = 30


func _owner_active(owner_id: int) -> Dictionary:
	return _active_commits.get(owner_id, {}) as Dictionary


func _owner_committed(owner_id: int) -> Dictionary:
	return _committed_branches.get(owner_id, {}) as Dictionary


func _process(delta: float) -> void:
	if _active_commits.is_empty():
		return
	# Walk a snapshot so a finish() call removing the entry mid-loop
	# doesn't trip the iterator. Two-level walk: owner_id -> unit_name.
	var owner_keys: Array = _active_commits.keys()
	for owner_v: Variant in owner_keys:
		var owner_id: int = owner_v as int
		var per_owner: Dictionary = _active_commits.get(owner_id, {}) as Dictionary
		var keys: Array = per_owner.keys()
		for key_v: Variant in keys:
			var key: String = key_v as String
			if not per_owner.has(key):
				continue
			var commit: Dictionary = per_owner[key] as Dictionary
			commit["timer"] = (commit["timer"] as float) + delta
			per_owner[key] = commit
			if (commit["timer"] as float) >= (commit["duration"] as float):
				_finish_commit(owner_id, key)


func is_committing(owner_id: int = 0) -> bool:
	## True when this owner has ANY branch commit in flight. Kept as a
	## per-owner predicate for the HUD's match-wide "research line".
	return not _owner_active(owner_id).is_empty()


func is_committing_unit(base_unit_name: String, owner_id: int = 0) -> bool:
	## True when THIS owner has an in-flight commit for this base unit.
	return _owner_active(owner_id).has(base_unit_name)


func get_active_commit_keys(owner_id: int = 0) -> Array[String]:
	## Snapshot of this owner's base_unit_names currently mid-commit.
	## Used by the HUD global-queue line to render one progress chip per
	## active commit instead of squashing them into a single line.
	var out: Array[String] = []
	for k_v: Variant in _owner_active(owner_id).keys():
		out.append(k_v as String)
	return out


func get_commit_progress(base_unit_name: String = "", owner_id: int = 0) -> float:
	## Without an argument, returns the FIRST active commit's progress
	## so older callers that only ran one commit at a time still work.
	## With a name, returns that specific commit's progress (0..1).
	var commit: Dictionary = _resolve_commit(base_unit_name, owner_id)
	if commit.is_empty():
		return 0.0
	var timer: float = commit["timer"] as float
	var duration: float = commit["duration"] as float
	return clampf(timer / duration, 0.0, 1.0)


func get_commit_branch_name(base_unit_name: String = "", owner_id: int = 0) -> String:
	var commit: Dictionary = _resolve_commit(base_unit_name, owner_id)
	if commit.is_empty():
		return ""
	return commit["branch_name"] as String


func get_commit_base_stats(base_unit_name: String = "", owner_id: int = 0) -> UnitStatResource:
	## Active commit's BASE unit stats — the row owner. Lets the HUD
	## show a cancel button on the matching armory row instead of all
	## of them. Without an argument, returns the first active commit
	## (legacy single-commit behaviour).
	var commit: Dictionary = _resolve_commit(base_unit_name, owner_id)
	if commit.is_empty():
		return null
	return commit["base_stats"] as UnitStatResource


func _resolve_commit(base_unit_name: String, owner_id: int) -> Dictionary:
	var per_owner: Dictionary = _owner_active(owner_id)
	if base_unit_name != "":
		return per_owner.get(base_unit_name, {}) as Dictionary
	if per_owner.is_empty():
		return {}
	# Pick the alphabetically-first key for determinism so callers
	# that pass "" twice in the same frame see the same data.
	var keys: Array = per_owner.keys()
	keys.sort()
	return per_owner[keys[0]] as Dictionary


func has_committed(base_unit_name: String, owner_id: int = 0) -> bool:
	return _owner_committed(owner_id).has(base_unit_name)


func get_committed_stats(base_unit_name: String, owner_id: int = 0) -> UnitStatResource:
	var per_owner: Dictionary = _owner_committed(owner_id)
	if per_owner.has(base_unit_name):
		return per_owner[base_unit_name] as UnitStatResource
	return null


func start_commit(base_stats: UnitStatResource, branch_stats: UnitStatResource, branch_name: String, owner_id: int = 0) -> bool:
	## Per-(owner, base unit) lock: rejects if this owner already has an
	## active commit for the base, or already finalised it. Distinct
	## base units (or distinct owners) run in parallel without contention.
	if not base_stats:
		return false
	if is_committing_unit(base_stats.unit_name, owner_id):
		return false
	if has_committed(base_stats.unit_name, owner_id):
		return false

	if not _active_commits.has(owner_id):
		_active_commits[owner_id] = {}
	(_active_commits[owner_id] as Dictionary)[base_stats.unit_name] = {
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


func cancel_commit(base_unit_name: String = "", owner_id: int = 0) -> bool:
	## Aborts a specific in-flight commit for this owner. Empty name =
	## first active commit (legacy single-commit behaviour). Caller
	## refunds the cost via its ResourceManager.
	var per_owner: Dictionary = _owner_active(owner_id)
	if per_owner.is_empty():
		return false
	var key: String = base_unit_name
	if key == "":
		var keys: Array = per_owner.keys()
		keys.sort()
		key = keys[0] as String
	if not per_owner.has(key):
		return false
	per_owner.erase(key)
	# Clean up empty owner slot.
	if per_owner.is_empty():
		_active_commits.erase(owner_id)
	return true


func _finish_commit(owner_id: int, base_unit_name: String) -> void:
	var per_owner_active: Dictionary = _owner_active(owner_id)
	if not per_owner_active.has(base_unit_name):
		return
	var commit: Dictionary = per_owner_active[base_unit_name] as Dictionary
	var base_stats: UnitStatResource = commit["base_stats"] as UnitStatResource
	var branch_stats: UnitStatResource = commit["branch_stats"] as UnitStatResource
	var branch_name: String = commit["branch_name"] as String

	if not _committed_branches.has(owner_id):
		_committed_branches[owner_id] = {}
	(_committed_branches[owner_id] as Dictionary)[base_stats.unit_name] = branch_stats
	per_owner_active.erase(base_unit_name)
	if per_owner_active.is_empty():
		_active_commits.erase(owner_id)

	# Upgrade only this owner's existing units of this type — opponents
	# keep base stats.
	_upgrade_existing_units(base_stats, branch_stats, owner_id)

	branch_committed.emit(owner_id, base_stats.unit_name, branch_name)

	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio and audio.has_method("play_construction_complete"):
		audio.play_construction_complete()


func _upgrade_existing_units(base_stats: UnitStatResource, branch_stats: UnitStatResource, owner_id: int) -> void:
	var units: Array[Node] = get_tree().get_nodes_in_group("units")
	for node: Node in units:
		if not ("stats" in node):
			continue
		if not ("owner_id" in node):
			continue
		# Owner-scope: only upgrade units belonging to the committing
		# player. Was previously unfiltered — a player's commit
		# upgraded enemy units of the same unit_name too.
		if (node.get("owner_id") as int) != owner_id:
			continue
		var unit_stats: UnitStatResource = node.get("stats") as UnitStatResource
		if not unit_stats:
			continue
		# Match by unit_name (base Borzoi → upgrade to Tracker/Ripper)
		if unit_stats.unit_name == base_stats.unit_name:
			node.set("stats", branch_stats)
			# Re-init HP with new stats (heal to new max)
			if node.has_method("_init_hp"):
				node._init_hp()
			# Rebuild visuals so the upgrade reads on existing squads.
			if node.has_method("_build_squad_visuals"):
				node._build_squad_visuals()
