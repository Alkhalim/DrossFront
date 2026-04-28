class_name SalvageYardComponent
extends Node
## Attaches to a Building node. Spawns autonomous workers that harvest wrecks.

const WORKER_SPAWN_INTERVAL: float = 15.0
const MAX_WORKERS: int = 3

var _spawn_timer: float = 0.0
var _workers: Array[SalvageWorker] = []
var _building: Building = null


func _ready() -> void:
	_building = get_parent() as Building


func _process(delta: float) -> void:
	if not _building or not _building.is_constructed:
		return

	# Clean up dead worker references
	var i: int = _workers.size() - 1
	while i >= 0:
		if not is_instance_valid(_workers[i]):
			_workers.remove_at(i)
		i -= 1

	if _workers.size() >= MAX_WORKERS:
		return

	var efficiency: float = _building.get_power_efficiency()
	_spawn_timer += delta * efficiency

	if _spawn_timer >= WORKER_SPAWN_INTERVAL:
		_spawn_timer -= WORKER_SPAWN_INTERVAL
		_spawn_worker()


func _spawn_worker() -> void:
	var worker := SalvageWorker.new()
	worker.home_yard = _building
	worker.resource_manager = _building.resource_manager

	var spawn_offset := Vector3(randf_range(-2.0, 2.0), 0, randf_range(-2.0, 2.0))
	worker.global_position = _building.global_position + spawn_offset

	get_tree().current_scene.add_child(worker)
	_workers.append(worker)
