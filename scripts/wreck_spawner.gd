class_name WreckSpawner
extends Node
## Spawns pre-placed wrecks in the test arena for immediate salvage.

@export var wreck_positions: Array[Vector3] = []
@export var salvage_per_wreck: int = 80


func _ready() -> void:
	# Default wreck positions if none set in inspector
	if wreck_positions.is_empty():
		wreck_positions = [
			Vector3(15, 0, 10),
			Vector3(-15, 0, 12),
			Vector3(20, 0, -5),
			Vector3(-18, 0, -8),
			Vector3(8, 0, -15),
			Vector3(-10, 0, 20),
			Vector3(25, 0, 0),
			Vector3(-25, 0, 5),
		]

	for pos: Vector3 in wreck_positions:
		var wreck := Wreck.new()
		wreck.salvage_value = salvage_per_wreck
		wreck.salvage_remaining = salvage_per_wreck
		wreck.wreck_size = Vector3(
			randf_range(1.0, 2.0),
			randf_range(0.3, 0.6),
			randf_range(1.0, 2.0)
		)
		# Set local position before adding to tree — global_position requires the
		# node to already be in-tree, but we add deferred. The wreck is added
		# directly under the scene root so local == global once attached.
		wreck.position = pos
		get_tree().current_scene.add_child.call_deferred(wreck)
