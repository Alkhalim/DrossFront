class_name SalvageYardComponent
extends Node
## Attaches to a Building node. Spawns autonomous workers that harvest wrecks.

const WORKER_SPAWN_INTERVAL: float = 15.0
const MAX_WORKERS: int = 3
## Workers search for wrecks within this radius of the yard.
const COLLECTION_RADIUS: float = 30.0

var _spawn_timer: float = 0.0
var _workers: Array[SalvageWorker] = []
var _building: Node = null
var _total_spawned: int = 0
var _range_indicator: MeshInstance3D = null
var _initial_spawned: bool = false


func _ready() -> void:
	_building = get_parent()
	# Spawn the first worker the instant the yard finishes construction so the
	# economy starts up without a 15-second wait.
	if _building and _building.has_signal("construction_complete"):
		_building.construction_complete.connect(_on_construction_complete)


func _on_construction_complete() -> void:
	if _initial_spawned:
		return
	_initial_spawned = true
	_spawn_worker()


func _process(delta: float) -> void:
	if not _building or not _building.get("is_constructed"):
		return

	# Catch the AI-instant-built case (skips construction_complete signal).
	if not _initial_spawned:
		_initial_spawned = true
		_spawn_worker()

	# Clean up dead worker references
	var i: int = _workers.size() - 1
	while i >= 0:
		if not is_instance_valid(_workers[i]):
			_workers.remove_at(i)
		i -= 1

	if _workers.size() >= MAX_WORKERS:
		_spawn_timer = 0.0
		return

	var efficiency: float = 1.0
	if _building.has_method("get_power_efficiency"):
		efficiency = _building.get_power_efficiency()
	_spawn_timer += delta * efficiency

	if _spawn_timer >= WORKER_SPAWN_INTERVAL:
		_spawn_timer -= WORKER_SPAWN_INTERVAL
		_spawn_worker()


func _spawn_worker() -> void:
	var worker := SalvageWorker.new()
	worker.home_yard = _building
	worker.resource_manager = _building.get("resource_manager")
	worker.search_radius = COLLECTION_RADIUS
	# Inherit the yard owner so workers belong to the right side and pick up
	# the matching team-color stripe.
	worker.owner_id = _building.get("owner_id") as int

	var spawn_offset := Vector3(randf_range(-2.0, 2.0), 0, randf_range(-2.0, 2.0))
	worker.global_position = _building.global_position + spawn_offset

	get_tree().current_scene.add_child(worker)
	_workers.append(worker)
	_total_spawned += 1


func get_worker_count() -> int:
	return _workers.size()


func get_max_workers() -> int:
	return MAX_WORKERS


func get_spawn_progress() -> float:
	if _workers.size() >= MAX_WORKERS:
		return 0.0
	return clampf(_spawn_timer / WORKER_SPAWN_INTERVAL, 0.0, 1.0)


func get_collection_radius() -> float:
	return COLLECTION_RADIUS


func show_range() -> void:
	if _range_indicator:
		_range_indicator.visible = true
		return

	_range_indicator = MeshInstance3D.new()
	# Flat cylinder as range circle
	var cyl := CylinderMesh.new()
	cyl.top_radius = COLLECTION_RADIUS
	cyl.bottom_radius = COLLECTION_RADIUS
	cyl.height = 0.05
	cyl.radial_segments = 48
	_range_indicator.mesh = cyl

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.6, 0.1, 0.08)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_range_indicator.set_surface_override_material(0, mat)

	_range_indicator.position = Vector3(0, 0.1, 0)
	_building.add_child(_range_indicator)


func hide_range() -> void:
	if _range_indicator:
		_range_indicator.visible = false
