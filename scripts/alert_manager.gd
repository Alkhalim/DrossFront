class_name AlertManager
extends Node
## Routes player-relevant battlefield events into a single signal stream so
## the HUD can present a notification bar without each system poking the UI
## directly. Per design (SCOPE_VERTICAL_SLICE_V2.md §"Alert/notification"):
## only player-affecting events surface here — every battlefield event would
## drown the screen.

signal alert_emitted(message: String, severity: int, world_pos: Vector3)

enum Severity { INFO = 0, WARNING = 1, CRITICAL = 2 }

## Cooldown per "channel" so a single building taking sustained fire doesn't
## spam the alert log every frame. Channels are arbitrary string keys chosen
## by the caller (e.g. "base_attack", "deposit:%d" % deposit_id).
const DEFAULT_COOLDOWN: float = 6.0

var _channel_next_at: Dictionary = {}


func emit_alert(message: String, severity: int = Severity.INFO, world_pos: Vector3 = Vector3.ZERO, channel: String = "", cooldown: float = DEFAULT_COOLDOWN) -> void:
	if channel != "":
		var now: float = _now()
		var next: float = _channel_next_at.get(channel, 0.0) as float
		if now < next:
			return
		_channel_next_at[channel] = now + cooldown
	alert_emitted.emit(message, severity, world_pos)


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
