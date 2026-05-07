class_name SalvageYardComponent
extends Node
## Attaches to a Building node. Spawns autonomous workers that harvest wrecks.

## Per v3.3 §1.2 spec: Yards are cheap, fragile, slow-spawning, max 2 workers,
## with a small self-trickle so an idle Yard still pays back something.
const WORKER_SPAWN_INTERVAL: float = 24.0
const COLLECTION_RADIUS: float = 30.0
## Passive salvage trickle independent of workers (per v3.3 §1.2).
const SELF_TRICKLE_PER_SEC: float = 0.5

## Worker pool size — defaults to the Yard spec (2). Crawlers raise this to 4.
## Doubled (was 2). Combined with HARVEST_RATE halved, the per-yard
## throughput stays similar but the standing worker count is twice as
## high, so a raid that picks off 2 workers takes longer to recover
## from (population matters more, training-back-to-full is meaningful).
@export var max_workers: int = 4
## Worker harvest radius. Defaults to Yard spec (30); Crawlers override to 45.
@export var harvest_radius: float = COLLECTION_RADIUS
## Worker spawn cadence. Defaults to Yard spec (24s); Crawlers override to 18s.
@export var worker_spawn_interval: float = WORKER_SPAWN_INTERVAL
## Self-trickle salvage/sec. Defaults to Yard 0.5; Crawlers override to 1.0.
@export var self_trickle_per_sec: float = SELF_TRICKLE_PER_SEC

var _trickle_accumulator: float = 0.0

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

	# Self-trickle — small passive income so an idle Yard still earns something.
	# Power efficiency throttles it just like everything else powered.
	var resource_mgr: Node = _building.get("resource_manager")
	if resource_mgr and resource_mgr.has_method("add_salvage"):
		var efficiency: float = 1.0
		if _building.has_method("get_power_efficiency"):
			efficiency = _building.get_power_efficiency()
		_trickle_accumulator += self_trickle_per_sec * efficiency * delta
		if _trickle_accumulator >= 1.0:
			var amt: int = int(_trickle_accumulator)
			_trickle_accumulator -= float(amt)
			resource_mgr.add_salvage(amt)

	# Clean up dead worker references
	var i: int = _workers.size() - 1
	while i >= 0:
		if not is_instance_valid(_workers[i]):
			_workers.remove_at(i)
		i -= 1

	if _workers.size() >= max_workers:
		_spawn_timer = 0.0
		return

	var efficiency: float = 1.0
	if _building.has_method("get_power_efficiency"):
		efficiency = _building.get_power_efficiency()
	_spawn_timer += delta * efficiency

	if _spawn_timer >= worker_spawn_interval:
		_spawn_timer -= worker_spawn_interval
		_spawn_worker()


func _spawn_worker() -> void:
	var worker := SalvageWorker.new()
	worker.home_yard = _building
	worker.resource_manager = _building.get("resource_manager")
	worker.search_radius = harvest_radius
	# Inherit the yard owner so workers belong to the right side and pick up
	# the matching team-color stripe.
	worker.owner_id = _building.get("owner_id") as int

	var spawn_offset := Vector3(randf_range(-2.0, 2.0), 0, randf_range(-2.0, 2.0))
	var spawn_pos: Vector3 = _building.global_position + spawn_offset

	get_tree().current_scene.add_child(worker)
	worker.global_position = spawn_pos
	_workers.append(worker)
	_total_spawned += 1


func get_worker_count() -> int:
	return _workers.size()


func get_max_workers() -> int:
	return max_workers


func get_spawn_progress() -> float:
	if _workers.size() >= max_workers:
		return 0.0
	return clampf(_spawn_timer / worker_spawn_interval, 0.0, 1.0)


func get_collection_radius() -> float:
	return harvest_radius


## Sum of `salvage_remaining` across every wreck in the harvest radius.
## Used by the HUD to display "Salvage in area: X" on a selected yard /
## crawler so the player can see at a glance whether the yard's still
## productive. Cheap O(N) walk over the wrecks group; called only on
## selection change + the HUD's per-frame stats refresh on selected
## buildings, not per-frame for every yard.
##
## Anchored crawlers temporarily have a +30% radius bonus baked into
## `harvest_radius` (see SalvageCrawler.AnchorState handler) — so a
## deployed crawler's "Salvage in area" is intentionally larger than
## an unanchored one's. That's per-design.
func get_nearby_salvage() -> int:
	if not _building or not is_instance_valid(_building):
		return 0
	var origin: Vector3 = _building.global_position
	var r2: float = harvest_radius * harvest_radius
	var total: int = 0
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		var w: Node3D = node as Node3D
		if not w:
			continue
		var dx: float = w.global_position.x - origin.x
		var dz: float = w.global_position.z - origin.z
		if dx * dx + dz * dz > r2:
			continue
		# Defensive cast: salvage_remaining is declared as int on Wreck
		# but get() returns Variant. Skip non-int values silently —
		# wrecks created by an old code path might have a nil here.
		var sv_v: Variant = w.get("salvage_remaining") if "salvage_remaining" in w else 0
		var sv_i: int = 0
		if sv_v is int:
			sv_i = sv_v as int
		elif sv_v is float:
			sv_i = int(sv_v as float)
		# Sanity clamp: a runaway value (millions) would mask a real bug
		# and isn't useful info. Cap per-wreck contribution at something
		# sane. A typical wreck has 30-200 salvage; satellite piles cap
		# around 300. 10000 is a generous ceiling that can never realistically
		# be hit by legitimate game state but stops a corrupted wreck from
		# producing the "way too high" total the user reported.
		sv_i = clampi(sv_i, 0, 10000)
		total += sv_i
	return total


func show_range() -> void:
	if _range_indicator:
		_range_indicator.visible = true
		return

	_range_indicator = MeshInstance3D.new()
	# Flat cylinder as range circle. Use harvest_radius (the actual
	# per-instance value — crawlers override it to 45u via salvage_crawler
	# setup) instead of the COLLECTION_RADIUS constant; the constant only
	# matched the default yard's value, so crawler ring previously drew
	# at the wrong size.
	var cyl := CylinderMesh.new()
	cyl.top_radius = harvest_radius
	cyl.bottom_radius = harvest_radius
	cyl.height = 0.05
	cyl.radial_segments = 48
	_range_indicator.mesh = cyl

	var mat := StandardMaterial3D.new()
	# Brighter than the previous 0.08 alpha — the old value was nearly
	# invisible in the crawler ring case, especially over green/teal
	# ground. 0.22 reads as a clear amber footprint without obscuring
	# the wrecks underneath.
	mat.albedo_color = Color(0.95, 0.65, 0.15, 0.22)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.65, 0.15, 1.0)
	mat.emission_energy_multiplier = 0.4
	_range_indicator.set_surface_override_material(0, mat)

	_range_indicator.position = Vector3(0, 0.1, 0)
	_building.add_child(_range_indicator)


func hide_range() -> void:
	if _range_indicator:
		_range_indicator.visible = false
