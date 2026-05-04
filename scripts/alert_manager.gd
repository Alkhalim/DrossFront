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
	# Minimap ping flash at the alert's world position. Severity
	# determines the colour: critical = red, warning = orange,
	# info = teal. Ignored when world_pos is the default zero.
	if world_pos != Vector3.ZERO:
		var scene: Node = get_tree().current_scene if get_tree() else null
		var minimap: Node = null
		if scene:
			# HUD lives at UILayer/HUD in the current arena scene.
			# Two legacy paths kept as fallback for older scenes.
			minimap = scene.get_node_or_null("UILayer/HUD/Minimap")
			if not minimap:
				minimap = scene.get_node_or_null("HUD/Minimap")
			if not minimap:
				minimap = scene.get_node_or_null("HUDCanvas/HUD/Minimap")
		if minimap and minimap.has_method("ping"):
			var ping_color: Color = Color(0.4, 0.85, 1.0, 1.0)
			if severity >= 2:
				ping_color = Color(1.0, 0.30, 0.20, 1.0)
			elif severity >= 1:
				ping_color = Color(1.0, 0.65, 0.20, 1.0)
			minimap.call("ping", world_pos, ping_color)
	# Commander voiceline for combat alerts. Building damage / unit
	# damage / unit destruction all surface as warning-or-critical
	# alerts on dedicated channels — the channel cooldown above
	# already rate-limits the trigger so we don't get a wall of
	# voicelines when the base is under sustained fire.
	if severity >= Severity.WARNING and (channel.begins_with("building_attack") or channel.begins_with("unit_attack")):
		var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager") if get_tree() else null
		if audio and audio.has_method("play_voice_attacked"):
			audio.play_voice_attacked()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
