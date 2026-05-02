class_name FloatingNumber
extends RefCounted
## Helper for spawning a colored "+N" floating number that drifts up
## and fades out. Used by every income / damage / heal source so the
## visual language stays consistent across the game.
##
## Usage:
##   FloatingNumber.spawn(get_tree().current_scene, world_pos, "+25 F", FloatingNumber.COLOR_FUEL)

const COLOR_SALVAGE: Color = Color(1.00, 0.78, 0.30, 1.0)   # warm gold
const COLOR_FUEL: Color = Color(0.30, 0.85, 1.00, 1.0)      # cyan
const COLOR_MICROCHIPS: Color = Color(0.85, 0.55, 1.00, 1.0) # violet
const COLOR_HEAL: Color = Color(0.60, 1.00, 0.55, 1.0)      # bright green
const COLOR_DAMAGE: Color = Color(1.00, 0.30, 0.25, 1.0)    # red


static func spawn(scene: Node, world_pos: Vector3, text: String, color: Color, lift: float = 1.6, dur: float = 1.4) -> void:
	## Spawns one floating Label3D at world_pos that drifts up by
	## `lift` units over `dur` seconds while fading to alpha 0, then
	## frees itself. Skipped silently when `scene` is null so the
	## caller doesn't have to guard around scene-tree teardown.
	if not scene or not is_instance_valid(scene):
		return
	var label := Label3D.new()
	label.text = text
	label.font_size = 32
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = color
	label.outline_size = 8
	label.outline_modulate = Color(0.0, 0.0, 0.0, 1.0)
	scene.add_child(label)
	label.global_position = world_pos
	var tween: Tween = label.create_tween().set_parallel(true)
	tween.tween_property(label, "global_position", world_pos + Vector3(0.0, lift, 0.0), dur).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)
