class_name MeshSystem
extends Node
## V3 §"Pillar 2 — Neural Mesh". Scene-level singleton (instanced once
## by the test arena controller) that tracks every Sable Mesh provider
## and supplies a cheap per-position strength lookup so Sable units +
## the combat system can read their current Mesh bonus without each
## one walking the units / buildings groups every frame.
##
## A "provider" is anything with a positive `mesh_provider_radius`
## (units or buildings) owned by a Sable player. A Sable unit's Mesh
## strength is the number of friendly providers whose auras cover its
## position, capped at MAX_PROVIDERS = 3.
##
## Strength → bonus mapping (per spec):
##   1 provider  : +5%  accuracy, +3%  reload
##   2 providers : +10% accuracy, +7%  reload
##   3 providers : +15% accuracy, +10% reload

const MAX_PROVIDERS: int = 3
const REBUILD_INTERVAL: float = 0.4

## Cached snapshot of all live providers. Each entry:
##   { "pos": Vector3, "r2": float (squared radius), "owner_id": int }
var _providers: Array[Dictionary] = []
var _rebuild_timer: float = 0.0
var _registry: PlayerRegistry = null


func _ready() -> void:
	_registry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	_rebuild_provider_list()


func _process(delta: float) -> void:
	_rebuild_timer -= delta
	if _rebuild_timer <= 0.0:
		_rebuild_timer = REBUILD_INTERVAL
		_rebuild_provider_list()


func _rebuild_provider_list() -> void:
	_providers.clear()
	# Buildings — Black Pylon today, future Mesh-anchor structures.
	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if not node.get("is_constructed"):
			continue
		var bstat: BuildingStatResource = node.get("stats") as BuildingStatResource
		if not bstat or bstat.mesh_provider_radius <= 0.0:
			continue
		_providers.append({
			"pos": (node as Node3D).global_position,
			"r2": bstat.mesh_provider_radius * bstat.mesh_provider_radius,
			"owner_id": node.get("owner_id") as int,
		})
	# Units — Glitch / Sensor Carrier / Overseer / Pulsefont (only
	# Harbinger base form provides today as a placeholder for the
	# Overseer branch).
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		if not ("alive_count" in node) or (node.get("alive_count") as int) <= 0:
			continue
		var ustat: UnitStatResource = node.get("stats") as UnitStatResource
		if not ustat or ustat.mesh_provider_radius <= 0.0:
			continue
		_providers.append({
			"pos": (node as Node3D).global_position,
			"r2": ustat.mesh_provider_radius * ustat.mesh_provider_radius,
			"owner_id": node.get("owner_id") as int,
		})


func strength_for(pos: Vector3, owner_id: int) -> int:
	## How many friendly providers cover this position. Capped at
	## MAX_PROVIDERS. Friendly = same owner OR registry-allied.
	var count: int = 0
	for p: Dictionary in _providers:
		var p_owner: int = p["owner_id"] as int
		var allied: bool = false
		if _registry:
			allied = _registry.are_allied(owner_id, p_owner)
		else:
			allied = (p_owner == owner_id)
		if not allied:
			continue
		var ppos: Vector3 = p["pos"] as Vector3
		var dx: float = ppos.x - pos.x
		var dz: float = ppos.z - pos.z
		var d2: float = dx * dx + dz * dz
		if d2 <= (p["r2"] as float):
			count += 1
			if count >= MAX_PROVIDERS:
				break
	return count


func accuracy_bonus(strength: int) -> float:
	match strength:
		0: return 0.0
		1: return 0.05
		2: return 0.10
		_: return 0.15


func reload_factor(strength: int) -> float:
	## Returns the multiplier applied to weapon ROF (smaller = faster).
	match strength:
		0: return 1.0
		1: return 1.0 / 1.03
		2: return 1.0 / 1.07
		_: return 1.0 / 1.10


func get_provider_snapshot() -> Array[Dictionary]:
	## Read-only snapshot for the visualization overlay.
	return _providers
