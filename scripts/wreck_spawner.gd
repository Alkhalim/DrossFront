class_name WreckSpawner
extends Node
## Spawns pre-placed wrecks in the test arena for immediate salvage.

@export var wreck_positions: Array[Vector3] = []
@export var salvage_per_wreck: int = 80


func _ready() -> void:
	var clusters: Array[Dictionary] = _clusters_for_map()

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
		# Apex-class wreck — bigger, much more salvage, blocks the
		# Crawler. Per V2 §"Map 1" this is the heavy-guarded mid-late
		# game objective on Foundry Belt.
		if cluster.get("apex", false):
			var apex := Wreck.new()
			apex.salvage_value = salvage_per_wreck * 6  # 480 vs 80 — a real prize
			apex.salvage_remaining = apex.salvage_value
			apex.wreck_size = Vector3(3.6, 1.0, 3.6)    # noticeably bigger than light/medium wrecks
			apex.position = center
			get_tree().current_scene.add_child.call_deferred(apex)


func _clusters_for_map() -> Array[Dictionary]:
	# Dispatch the wreck-cluster layout off the active V2 map. Foundry
	# Belt is dense + has an Apex scar; Ashplains is intentionally
	# sparse (V2 §"Map 2": "Fewer wreck clusters than Map 1").
	var settings: Node = get_node_or_null("/root/MatchSettings")
	var is_ashplains: bool = false
	if settings and "map_id" in settings:
		is_ashplains = (settings.get("map_id") as int) == 1
	if is_ashplains:
		return _clusters_ashplains()
	return _clusters_foundry_belt()


func _clusters_foundry_belt() -> Array[Dictionary]:
	# Default scatter for V2 Foundry-Belt scale (per SCOPE_V2 §Map 1):
	# - 2 small near-base clusters at each player's spawn (limited supply
	#   so the starvation gap pushes them forward)
	# - 3 mid-map clusters distributed E/W/center
	# - 2 deep-territory clusters near the player and AI safe deposits
	# - 1 battlefield-scar cluster mid-map with an Apex-class wreck
	# Symmetric around z = 0 so neither player has more salvage in arm's
	# reach than the other. Density boosted so AI forward-yard expansion
	# (every ~35s) actually has fresh clusters to claim.
	return [
		# Player near-base (z ≈ 100, north)
		{ "center": Vector3(12, 0, 100),  "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		{ "center": Vector3(-14, 0, 102), "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		# AI near-base (mirrored on z ≈ -100, south)
		{ "center": Vector3(12, 0, -100), "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		{ "center": Vector3(-14, 0, -102),"spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.5 },
		# Mid-map clusters along the central z = 0 axis.
		{ "center": Vector3(0, 0, 55),    "spread": 6.0, "count": 6, "size_min": 1.0, "size_max": 1.8 },
		{ "center": Vector3(0, 0, -55),   "spread": 6.0, "count": 6, "size_min": 1.0, "size_max": 1.8 },
		{ "center": Vector3(28, 0, 25),   "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(-30, 0, 25),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(20, 0, -25),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(-22, 0, -25), "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		# Battlefield scar — denser cluster with one Apex-class wreck.
		# Tucked just south of center so it doesn't sit underneath the
		# central plateau geometry.
		{ "center": Vector3(0, 0, -45),   "spread": 7.0, "count": 7, "size_min": 1.0, "size_max": 2.0, "apex": true },
		# Far-flank "old battlefield" clusters — give the AI / player
		# legitimate forward-expansion targets along the east + west
		# corridors.
		{ "center": Vector3(85, 0, 50),   "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.7 },
		{ "center": Vector3(-85, 0, 50),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.7 },
		{ "center": Vector3(85, 0, -50),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.7 },
		{ "center": Vector3(-85, 0, -50), "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.7 },
		# Northern + southern clusters between the safe deposits and mid
		# — secondary harvest zones the AI's yard expansion can reach
		# safely once it owns the safe-side deposit.
		{ "center": Vector3(50, 0, 65),   "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(-50, 0, 65),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(50, 0, -65),  "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
		{ "center": Vector3(-50, 0, -65), "spread": 5.0, "count": 5, "size_min": 0.9, "size_max": 1.6 },
	]


func _clusters_ashplains() -> Array[Dictionary]:
	# Ashplains is sparse on initial salvage by design (V2 §"Map 2") —
	# fewer clusters, smaller, no Apex scar. Forces players to fight
	# over the central deposit + ridge instead of comfortably harvesting
	# their own half.
	return [
		# One small cluster behind each player — enough to bootstrap the
		# economy, not enough to comfortably stay home.
		{ "center": Vector3(0, 0, 100),  "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.4 },
		{ "center": Vector3(0, 0, -100), "spread": 4.0, "count": 4, "size_min": 0.8, "size_max": 1.4 },
		# A thin band of mid-map clusters along the central ridge so
		# combat naturally pulls in that direction.
		{ "center": Vector3(35, 0, 0),   "spread": 4.5, "count": 4, "size_min": 0.9, "size_max": 1.5 },
		{ "center": Vector3(-35, 0, 0),  "spread": 4.5, "count": 4, "size_min": 0.9, "size_max": 1.5 },
		# Two flank clusters at the far east/west edges — long-trip
		# salvage runs that leave Crawlers exposed.
		{ "center": Vector3(100, 0, 50),  "spread": 5.0, "count": 4, "size_min": 0.9, "size_max": 1.5 },
		{ "center": Vector3(-100, 0, -50), "spread": 5.0, "count": 4, "size_min": 0.9, "size_max": 1.5 },
	]
