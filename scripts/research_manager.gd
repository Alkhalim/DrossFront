class_name ResearchManager
extends Node
## Tracks researched upgrades for the local player. Add as a child of the
## scene root (TestArena) — HUD reads its state for buttons; gameplay
## systems (e.g. Crawler) check `is_researched("anchor_mode")`.
##
## v3.3 design rule: upgrades are additive (modify stats, sometimes toggle
## an existing capability) — they do not change unit AI. The manager is
## intentionally tiny: just a set of unlocked IDs and timed progress for
## the in-flight project.

signal research_started(upgrade_id: StringName)
signal research_progressed(upgrade_id: StringName, percent: float)
signal research_finished(upgrade_id: StringName)

## Currently in-flight project. Empty StringName = none.
var current_id: StringName = &""
var current_label: String = ""
var current_total_time: float = 0.0
var _current_elapsed: float = 0.0

## Set of completed upgrade IDs.
var _completed: Dictionary = {}


func is_researched(upgrade_id: StringName) -> bool:
	return _completed.get(upgrade_id, false)


func is_in_progress() -> bool:
	return current_id != &""


func get_progress() -> float:
	if current_total_time <= 0.0:
		return 0.0
	return clampf(_current_elapsed / current_total_time, 0.0, 1.0)


func start_research(upgrade_id: StringName, label: String, time_sec: float) -> bool:
	## Returns true if the project was started; false if something is already
	## in flight or this upgrade is already complete. Cost handling is the
	## caller's responsibility (so HUD can validate affordability + spend
	## resources atomically before committing).
	if is_in_progress():
		return false
	if is_researched(upgrade_id):
		return false
	current_id = upgrade_id
	current_label = label
	current_total_time = maxf(time_sec, 0.0)
	_current_elapsed = 0.0
	research_started.emit(upgrade_id)
	return true


func _process(delta: float) -> void:
	if current_id == &"":
		return
	_current_elapsed += delta
	research_progressed.emit(current_id, get_progress())
	if _current_elapsed >= current_total_time:
		_complete_current()


func _complete_current() -> void:
	var finished_id: StringName = current_id
	_completed[finished_id] = true
	current_id = &""
	current_label = ""
	current_total_time = 0.0
	_current_elapsed = 0.0
	research_finished.emit(finished_id)
