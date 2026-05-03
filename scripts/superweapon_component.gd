class_name SuperweaponComponent
extends Node
## Attached to buildings whose stats.superweapon_kind != &"". Owns
## the activation state machine (READY -> ARMING -> FIRING ->
## COOLDOWN -> READY), the cooldown timer, and the per-kind effect
## dispatch.
##
## Each match-end / building-destroyed event auto-cancels via the
## standard queue_free chain -- the component is a child of the
## building so freeing the building frees the state too.

enum State { READY, ARMING, FIRING, COOLDOWN }

const TELEGRAPH_PING_COLOR: Color = Color(1.0, 0.30, 0.20, 1.0)

var _building: Node = null
var _kind: StringName = &""
var _arming_sec: float = 15.0
var _firing_sec: float = 30.0
var _cooldown_sec: float = 240.0
var _radius: float = 30.0

var _state: int = State.READY
var _state_timer: float = 0.0
var _target_pos: Vector3 = Vector3.ZERO
## Per-kind effect tick scratch (e.g. MOLOT's shell-spawn timer).
var _effect_scratch: float = 0.0
## Last whole-second value pushed to the HUD's persistent warning
## banner, so the countdown re-emits exactly once per second instead
## of once per frame (or once at activation, like the old alert).
var _last_banner_sec: int = -1
## Stable key for the HUD warning banner + minimap pulse pin so we
## clear the same entries we set at telegraph time.
var _telegraph_key: String = ""


func _ready() -> void:
	_building = get_parent()
	if not _building or not ("stats" in _building):
		return
	var stats: BuildingStatResource = _building.get("stats") as BuildingStatResource
	if not stats:
		return
	_kind = stats.superweapon_kind
	_arming_sec = stats.superweapon_arming_sec
	_firing_sec = stats.superweapon_firing_sec
	_cooldown_sec = stats.superweapon_cooldown_sec
	_radius = stats.superweapon_radius


func is_ready() -> bool:
	return _state == State.READY


func get_state() -> int:
	return _state


func get_state_progress() -> float:
	## Returns [0..1] -- how much of the current non-READY state has
	## elapsed. READY returns 0.0. Useful for the HUD button label.
	var total: float = 0.0
	match _state:
		State.ARMING:
			total = _arming_sec
		State.FIRING:
			total = _firing_sec
		State.COOLDOWN:
			total = _cooldown_sec
	if total <= 0.0:
		return 0.0
	return 1.0 - clampf(_state_timer / total, 0.0, 1.0)


func get_state_label() -> String:
	match _state:
		State.READY:
			return "Ready"
		State.ARMING:
			return "Arming"
		State.FIRING:
			return "Firing"
		State.COOLDOWN:
			return "Cooldown"
	return ""


func get_remaining_seconds() -> float:
	return maxf(_state_timer, 0.0)


func get_radius() -> float:
	return _radius


func try_activate(target_pos: Vector3) -> bool:
	## Player-driven activation. Refuses if the building isn't
	## constructed, the superweapon isn't READY, or no kind is set.
	if _state != State.READY:
		return false
	if not _building or not _building.get("is_constructed"):
		return false
	if _kind == &"":
		return false
	_target_pos = target_pos
	_state = State.ARMING
	_state_timer = _arming_sec
	_emit_telegraph()
	return true


func _process(delta: float) -> void:
	if _state == State.READY:
		return
	_state_timer -= delta
	match _state:
		State.ARMING:
			_tick_arming_banner()
			if _state_timer <= 0.0:
				_clear_telegraph()
				_start_firing()
		State.FIRING:
			_firing_tick(delta)
			if _state_timer <= 0.0:
				_start_cooldown()
		State.COOLDOWN:
			if _state_timer <= 0.0:
				_state = State.READY


func _tick_arming_banner() -> void:
	## Re-emits the countdown to the HUD's persistent warning bar
	## once per second so the player sees a live timer instead of
	## the original 'fire once, fade after 3.5s' alert.
	var remaining: int = int(ceilf(_state_timer))
	if remaining == _last_banner_sec:
		return
	_last_banner_sec = remaining
	var hud: Node = _find_hud()
	if not hud or not hud.has_method("set_persistent_warning"):
		return
	if remaining > 0:
		var msg: String = "Incoming superweapon strike — %ds" % remaining
		hud.call("set_persistent_warning", _telegraph_key, msg, 2)


func _clear_telegraph() -> void:
	## Drop the warning banner + minimap pulse pin once arming ends
	## (the firing-window VFX takes over the visual from there).
	if _telegraph_key == "":
		return
	var hud: Node = _find_hud()
	if hud and hud.has_method("clear_persistent_warning"):
		hud.call("clear_persistent_warning", _telegraph_key)
	if hud:
		var minimap: Node = hud.get_node_or_null("Minimap")
		if minimap and minimap.has_method("stop_pulse_pin"):
			minimap.call("stop_pulse_pin", _telegraph_key)


func _find_hud() -> Node:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if not scene:
		return null
	var hud: Node = scene.get_node_or_null("HUD")
	if not hud:
		var canvas: Node = scene.get_node_or_null("HUDCanvas")
		if canvas:
			hud = canvas.get_node_or_null("HUD")
	return hud


func _start_firing() -> void:
	_state = State.FIRING
	_state_timer = maxf(_firing_sec, 0.0)
	_effect_scratch = 0.0
	# Per-kind firing onset hook -- instantaneous-effect weapons
	# apply their effect here and let the firing window play out
	# as a brief wind-down; over-time weapons (artillery) start
	# their loop in _firing_tick.


func _firing_tick(_delta: float) -> void:
	pass


func _start_cooldown() -> void:
	_state = State.COOLDOWN
	_state_timer = maxf(_cooldown_sec, 0.0)


func _emit_telegraph() -> void:
	## Surfaces a critical-severity warning banner + minimap pulse
	## pin at the target so every player (the firer included) sees
	## the incoming-superweapon warning. Banner is the persistent
	## variant -- _tick_arming_banner refreshes the seconds counter
	## once per second until ARMING ends; _clear_telegraph drops the
	## banner + pin together at that point.
	_telegraph_key = "superweapon_%d" % get_instance_id()
	_last_banner_sec = -1
	var hud: Node = _find_hud()
	if hud and hud.has_method("set_persistent_warning"):
		hud.call(
			"set_persistent_warning",
			_telegraph_key,
			"Incoming superweapon strike — %ds" % int(ceilf(_arming_sec)),
			2,
		)
	if hud:
		var minimap: Node = hud.get_node_or_null("Minimap")
		if minimap and minimap.has_method("start_pulse_pin"):
			minimap.call("start_pulse_pin", _telegraph_key, _target_pos, TELEGRAPH_PING_COLOR)
	# One-shot AlertManager ping for the audio cue + minimap flash.
	# The persistent banner above carries the visible countdown; the
	# alert is just the audible 'something is happening' chime.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		var alerts: Node = scene.get_node_or_null("AlertManager")
		if alerts and alerts.has_method("emit_alert"):
			alerts.call(
				"emit_alert",
				"Incoming superweapon strike",
				2,
				_target_pos,
			)
