class_name WreckSpawner
extends Node
## Spawns pre-placed wrecks in the test arena for immediate salvage.

@export var wreck_positions: Array[Vector3] = []
@export var salvage_per_wreck: int = 80


func _ready() -> void:
	# Default scatter for V2 Foundry-Belt scale (per SCOPE_V2 §Map 1):
	# - 2 small near-base clusters at each player's spawn (limited supply
	#   so the starvation gap pushes them forward)
	# - 3 mid-map clusters distributed E/W/center
	# - 2 deep-territory clusters near the player and AI safe deposits
	# - 1 battlefield-scar cluster mid-map with an Apex-class wreck
	var clusters: Array[Dictionary] = [
		# Player near-base
		{ "center": Vector3(12, 0, 8),    "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		{ "center": Vector3(-14, 0, 6),   "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		# AI near-base
		{ "center": Vector3(12, 0, -110), "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		{ "center": Vector3(-14, 0, -112),"spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		# Mid-map clusters
		{ "center": Vector3(0, 0, -60),   "spread": 6.0, "count": 6, "size_min": 1.0, "size_max": 1.8 },
		{ "center": Vector3(28, 0, -45),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(-30, 0, -45), "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(20, 0, -75),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(-22, 0, -78), "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		# Battlefield scar — denser cluster with one big wreck
		{ "center": Vector3(0, 0, -30),   "spread": 7.0, "count": 7, "size_min": 1.0, "size_max": 2.0, "apex": true },
	]

	for cluster: Dictionary in clusters:
		var center: Vector3 = cluster["center"] as Vector3
		var spread: float = cluster["spread"] as float
		var count: int = cluster["count"] as int
		var size_min: float = cluster["size_min"] as float
		var size_max: float = cluster["size_max"] as float
		for i: int in count:
			var wreck := Wreck.new()
			wreck.salvage_value = salvage_per_wreck
			wreck.salvage_remaining = salvage_per_wreck
			var sx: float = randf_range(size_min, size_max)
			var sz: float = randf_range(size_min, size_max)
			wreck.wreck_size = Vector3(sx, randf_range(0.3, 0.6), sz)
			wreck.position = center + Vector3(
				randf_range(-spread, spread),
				0,
				randf_range(-spread, spread)
			)
			get_tree().current_scene.add_child.call_deferred(wreck)
		# Apex-class wreck — bigger, worth more, blocks the Crawler.
		if cluster.get("apex", false):
			var apex := Wreck.new()
			apex.salvage_value = salvage_per_wreck * 4
			apex.salvage_remaining = apex.salvage_value
			apex.wreck_size = Vector3(2.5, 0.7, 2.5)
			apex.position = center
			get_tree().current_scene.add_child.call_deferred(apex)
