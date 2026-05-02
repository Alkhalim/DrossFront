class_name FogOfWar
extends Node
## Age-of-Empires-style fog of war.
##
## Three states per cell:
##   UNEXPLORED — never seen by the local player or its allies.
##   EXPLORED   — seen at some point in the past, no current vision.
##   VISIBLE    — currently within sight of an allied unit or building.
##
## Allied vision shares — units owned by any player on the local
## player's team contribute to vision. Single-player mode (no allies)
## just looks at owner_id == local_id.
##
## Recomputed at FOW_REFRESH_HZ (5 Hz). All consumers (per-unit
## visibility, terrain overlay, minimap) read from the cached grid
## via is_visible_world / is_explored_world helpers.

enum CellState { UNEXPLORED, EXPLORED, VISIBLE }

## Cell side length in world units. 4u per cell on a 320x320 map
## yields an 80x80 grid (6400 cells). Fine enough that a unit's
## sight radius covers ~5x5 cells, coarse enough to recompute at
## 5 Hz without sweat.
const CELL_SIZE: float = 4.0

## Map covers a square centred on the world origin from
## -MAP_HALF_EXTENT to +MAP_HALF_EXTENT on both X and Z axes.
## Sized to comfortably contain V2's largest map.
const MAP_HALF_EXTENT: float = 200.0

## Cells per side derived from extent + cell size. Stored as a
## constant so the grid arrays can be sized at _ready.
const GRID_SIZE: int = int((MAP_HALF_EXTENT * 2.0) / CELL_SIZE)

const FOW_REFRESH_HZ: float = 5.0

## Material overlay applied to each MeshInstance3D inside an entity
## sitting in an explored-but-not-currently-visible cell. Renders
## on top of the regular material with the fog tint, so buildings /
## rocks / wrecks dim along with the ground beneath them. Built
## lazily so headless test scenes that never light up the visual
## pipeline don't pay for it.
var _fog_dim_overlay: Material = null


func _make_fog_dim_overlay() -> Material:
	if _fog_dim_overlay:
		return _fog_dim_overlay
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_fog_dim_overlay = mat
	return mat


func _apply_fog_dim(node: Node3D, dim: bool) -> void:
	## Walks down the entity's tree and toggles material_overlay on
	## every MeshInstance3D / GeometryInstance3D it finds. Skips the
	## traversal entirely when the existing dim state already matches,
	## using a meta flag on the entity, so steady-state cells don't
	## pay the walk cost on every 5Hz refresh.
	if not is_instance_valid(node):
		return
	var current_dim: bool = node.get_meta("_fow_dimmed", false) as bool
	if current_dim == dim:
		return
	node.set_meta("_fow_dimmed", dim)
	var overlay: Material = _make_fog_dim_overlay() if dim else null
	_apply_fog_dim_recursive(node, overlay)


func _apply_fog_dim_recursive(node: Node, overlay: Material) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).material_overlay = overlay
	for child: Node in node.get_children():
		_apply_fog_dim_recursive(child, overlay)

## Sight-tier -> radius in world units. Units / buildings without
## a stat resource fall through DEFAULT_SIGHT_RADIUS.
const DEFAULT_SIGHT_RADIUS: float = 18.0
const SIGHT_RADIUS_BY_TIER: Dictionary = {
	&"short": 12.0,
	&"medium": 18.0,
	&"long": 26.0,
	&"very_long": 36.0,
	&"extreme": 50.0,
}

## Vision range buildings provide if they have no explicit override.
## Headquarters / forward bases project enough vision that the
## player isn't fog-blind around their own base.
const BUILDING_SIGHT_RADIUS: float = 28.0

## Disable the entire system at runtime — used by the unit /
## building visibility hooks so they can short-circuit when fog
## isn't part of the active match. Currently always on once the
## node is in the tree.
var enabled: bool = true

## Local-player id this fog instance tracks. Always 0 (the human
## player) — the AI doesn't render through the fog system, it
## reads ground truth.
var local_player_id: int = 0

## Per-cell state, flat array of length GRID_SIZE * GRID_SIZE.
var _cells: PackedByteArray = PackedByteArray()

## Cached PlayerRegistry — used to expand vision to allies.
var _registry: PlayerRegistry = null

var _refresh_accum: float = 0.0
const _REFRESH_INTERVAL: float = 1.0 / FOW_REFRESH_HZ

## Bumped every recompute so consumers (overlay shader, minimap)
## know whether they need to re-upload the grid texture.
var revision: int = 0

## Temporary reveal entries — non-unit vision sources that stamp
## visibility on the grid for a few seconds (satellite-crash flares,
## scan pings, etc.). Each entry: { pos: Vector3, radius: float,
## expires_at: float (engine seconds) }.
var _temp_reveals: Array[Dictionary] = []


func _ready() -> void:
	add_to_group("fog_of_war")
	_cells.resize(GRID_SIZE * GRID_SIZE)
	for i: int in _cells.size():
		_cells[i] = CellState.UNEXPLORED
	_registry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	# Full first pass on enter so cells around the local-player base
	# are visible the moment the HUD wakes up.
	_recompute_visibility()


func _process(delta: float) -> void:
	if not enabled:
		return
	_refresh_accum += delta
	if _refresh_accum < _REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	_recompute_visibility()


## --- World <-> grid helpers -----------------------------------------------

func _world_to_cell(world_pos: Vector3) -> Vector2i:
	# Round (not floor) so cell N is centred at world (N*CELL_SIZE -
	# MAP_HALF_EXTENT). A unit at world (0, 0, 0) lands in cell
	# (GRID_SIZE/2, GRID_SIZE/2) whose centre IS world (0, 0, 0)
	# instead of being a half-cell biased away. The floor variant
	# was causing a visible ~2u offset between a unit's actual
	# position and the centre of its FOW vision circle.
	var cx: int = int(round((world_pos.x + MAP_HALF_EXTENT) / CELL_SIZE))
	var cz: int = int(round((world_pos.z + MAP_HALF_EXTENT) / CELL_SIZE))
	cx = clampi(cx, 0, GRID_SIZE - 1)
	cz = clampi(cz, 0, GRID_SIZE - 1)
	return Vector2i(cx, cz)


func _cell_index(cx: int, cz: int) -> int:
	return cz * GRID_SIZE + cx


## --- Public visibility API ------------------------------------------------

func is_visible_world(pos: Vector3) -> bool:
	if not enabled:
		return true
	var c: Vector2i = _world_to_cell(pos)
	return _cells[_cell_index(c.x, c.y)] == CellState.VISIBLE


func is_explored_world(pos: Vector3) -> bool:
	if not enabled:
		return true
	var c: Vector2i = _world_to_cell(pos)
	return _cells[_cell_index(c.x, c.y)] != CellState.UNEXPLORED


func cell_state_at(pos: Vector3) -> CellState:
	if not enabled:
		return CellState.VISIBLE
	var c: Vector2i = _world_to_cell(pos)
	return _cells[_cell_index(c.x, c.y)] as CellState


## Read direct grid access (used by the overlay + minimap).
func get_grid_size() -> int:
	return GRID_SIZE


func get_cells() -> PackedByteArray:
	return _cells


func reveal_area(pos: Vector3, radius: float, duration_sec: float) -> void:
	## Briefly stamps cells around `pos` as VISIBLE for the given
	## duration regardless of whether any unit is in range. Used
	## by satellite crashes (visible long enough for the player to
	## see the crash + plan a recovery), scan pings, etc.
	var expires_at: float = float(Time.get_ticks_msec()) / 1000.0 + maxf(duration_sec, 0.0)
	_temp_reveals.append({
		"pos": pos,
		"radius": radius,
		"expires_at": expires_at,
	})
	# Stamp immediately so the next renderer tick sees the reveal
	# instead of waiting up to 200ms for the next 5 Hz recompute.
	_stamp_visibility(pos, radius)
	revision += 1


## --- Visibility recompute -------------------------------------------------

func _recompute_visibility() -> void:
	# Demote currently-VISIBLE cells to EXPLORED. New vision will
	# bump them back up below; cells that were visible last tick but
	# aren't this tick stay EXPLORED so the player can still see
	# terrain features but not live enemy positions.
	for i: int in _cells.size():
		if _cells[i] == CellState.VISIBLE:
			_cells[i] = CellState.EXPLORED

	# Walk every unit + building owned by the local player or any
	# ally and stamp visible cells around them.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		if not _is_friendly(node):
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var radius: float = _unit_sight_radius(node)
		_stamp_visibility((node as Node3D).global_position, radius)

	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		if not _is_friendly(node):
			continue
		# Under-construction buildings don't project vision -- the
		# foundation is intent only / not a fully-staffed structure
		# yet. The reveal kicks in the moment construction completes
		# (is_constructed flips true).
		if "is_constructed" in node and not (node.get("is_constructed") as bool):
			continue
		_stamp_visibility((node as Node3D).global_position, BUILDING_SIGHT_RADIUS)

	# Temporary reveals — satellite-crash flares, scan pings, etc.
	# Drop expired entries first; the rest stamp visibility just
	# like a unit would.
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	var i: int = _temp_reveals.size() - 1
	while i >= 0:
		var entry: Dictionary = _temp_reveals[i]
		if (entry["expires_at"] as float) <= now_sec:
			_temp_reveals.remove_at(i)
		else:
			_stamp_visibility(entry["pos"] as Vector3, entry["radius"] as float)
		i -= 1

	revision += 1
	# Apply the new grid to every enemy unit + building so the
	# scene renders the player's view of the world. Friendly +
	# neutral entities stay always-visible; enemies hide unless
	# their cell is currently VISIBLE.
	_apply_entity_visibility()


func _apply_entity_visibility() -> void:
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var node3d: Node3D = node as Node3D
		if not node3d:
			continue
		var owner_id: int = (node.get("owner_id") as int) if "owner_id" in node else local_player_id
		# Friendly + ally entities stay visible regardless of FOW.
		if owner_id == local_player_id or _is_friendly(node):
			node3d.visible = true
			continue
		# Enemy / neutral unit — hide unless its current cell is
		# in line of sight. Cell state is sampled at the entity's
		# world position; aircraft sample the same way (the cell
		# grid is 2D over X/Z, ignoring altitude).
		node3d.visible = is_visible_world(node3d.global_position)

	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b3d: Node3D = node as Node3D
		if not b3d:
			continue
		var owner_id: int = (node.get("owner_id") as int) if "owner_id" in node else local_player_id
		if owner_id == local_player_id or _is_friendly(node):
			b3d.visible = true
			_apply_fog_dim(b3d, false)
			continue
		# Foundations the placing engineer hasn't reached yet are
		# placement intent only -- they don't physically exist for
		# opponents until construction actually starts. Hide regardless
		# of explored / visible state.
		if "construction_started" in node and not (node.get("construction_started") as bool):
			if "is_constructed" in node and not (node.get("is_constructed") as bool):
				b3d.visible = false
				continue
		# Enemy buildings stick around once explored — Age-of-Empires
		# behaviour: the player remembers seeing the structure even
		# after losing live vision (terrain doesn't change, the
		# building hasn't moved). Buildings the player has never
		# seen stay hidden.
		var b_explored: bool = is_explored_world(b3d.global_position)
		var b_visible: bool = is_visible_world(b3d.global_position)
		b3d.visible = b_explored
		# Dim the building when the player remembers it but isn't
		# currently looking at it -- ground fog overlay alone leaves
		# the structure reading at full brightness over a fogged
		# floor, which breaks the "lights off in that cell" feel.
		_apply_fog_dim(b3d, b_explored and not b_visible)

	# Wrecks + fuel deposits behave like terrain features: the
	# player should be able to see scrap piles / fuel tanks they've
	# scouted before even after losing live vision (they don't
	# move), but anything inside an unexplored cell stays hidden.
	for node: Node in get_tree().get_nodes_in_group("wrecks"):
		if not is_instance_valid(node):
			continue
		var w3d: Node3D = node as Node3D
		if w3d:
			var w_explored: bool = is_explored_world(w3d.global_position)
			var w_visible: bool = is_visible_world(w3d.global_position)
			w3d.visible = w_explored
			_apply_fog_dim(w3d, w_explored and not w_visible)
	for node: Node in get_tree().get_nodes_in_group("fuel_deposits"):
		if not is_instance_valid(node):
			continue
		var f3d: Node3D = node as Node3D
		if f3d:
			var f_explored: bool = is_explored_world(f3d.global_position)
			var f_visible: bool = is_visible_world(f3d.global_position)
			f3d.visible = f_explored
			_apply_fog_dim(f3d, f_explored and not f_visible)

	# Projectiles — strictly LOS-only. A missile fired from an
	# unscouted Hammerhead would otherwise leak the unit's position
	# by drawing its arc through the fog. Only currently-VISIBLE
	# cells render projectiles; once they enter LOS they show.
	for node: Node in get_tree().get_nodes_in_group("projectiles"):
		if not is_instance_valid(node):
			continue
		var p3d: Node3D = node as Node3D
		if p3d:
			p3d.visible = is_visible_world(p3d.global_position)

	# Terrain decoration — rocks, ramps, plateaus, ruins, ammo
	# dumps. Same rule as wrecks / fuel deposits: hidden until
	# scouted, then sticks around once explored. The ground
	# collision shape itself is also in the "terrain" group; it's
	# invisible by default so toggling its `visible` is harmless.
	# Skip terrain whose owner is a building (some terrain pieces
	# get parented to live structures and shouldn't fight with the
	# building-side visibility hook).
	for node: Node in get_tree().get_nodes_in_group("terrain"):
		if not is_instance_valid(node):
			continue
		var t3d: Node3D = node as Node3D
		if t3d:
			var t_explored: bool = is_explored_world(t3d.global_position)
			var t_visible: bool = is_visible_world(t3d.global_position)
			t3d.visible = t_explored
			_apply_fog_dim(t3d, t_explored and not t_visible)


func _is_friendly(node: Node) -> bool:
	if not ("owner_id" in node):
		return false
	var owner_id: int = node.get("owner_id") as int
	if owner_id == local_player_id:
		return true
	# Lazy registry lookup — FOW._ready can run before
	# TestArenaController has finished wiring the PlayerRegistry,
	# in which case _registry started as null and ally vision
	# never engaged. Refetch every check until we have one (cheap
	# get_node_or_null) so allies start contributing the moment
	# the registry exists.
	if not _registry:
		_registry = get_tree().current_scene.get_node_or_null("PlayerRegistry") as PlayerRegistry
	if _registry and _registry.has_method("are_allied"):
		return _registry.are_allied(local_player_id, owner_id)
	return false


func _unit_sight_radius(node: Node) -> float:
	var stats: UnitStatResource = node.get("stats") as UnitStatResource if "stats" in node else null
	if not stats:
		return DEFAULT_SIGHT_RADIUS
	if stats is UnitStatResource:
		return (stats as UnitStatResource).resolved_sight_radius()
	return SIGHT_RADIUS_BY_TIER.get(stats.sight_tier, DEFAULT_SIGHT_RADIUS) as float


func _stamp_visibility(world_pos: Vector3, radius: float) -> void:
	# Compute the cell-bounding box of the radius and walk every
	# cell inside it, marking those whose centre falls inside the
	# circle as VISIBLE. Square -> circle filter is cheap because
	# the bounding-box loop is small (sight radius capped well
	# below the map size).
	var cell_radius: int = int(ceil(radius / CELL_SIZE))
	var c: Vector2i = _world_to_cell(world_pos)
	var x0: int = maxi(c.x - cell_radius, 0)
	var x1: int = mini(c.x + cell_radius, GRID_SIZE - 1)
	var z0: int = maxi(c.y - cell_radius, 0)
	var z1: int = mini(c.y + cell_radius, GRID_SIZE - 1)
	var radius_sq: float = radius * radius
	# Cell N centre = N * CELL_SIZE - MAP_HALF_EXTENT (matches
	# _world_to_cell's round-based mapping). The previous
	# +CELL_SIZE * 0.5 offset stacked with floor's bias and pulled
	# the visibility footprint half a cell off-target.
	for cz: int in range(z0, z1 + 1):
		for cx: int in range(x0, x1 + 1):
			var cell_centre := Vector3(
				float(cx) * CELL_SIZE - MAP_HALF_EXTENT,
				world_pos.y,
				float(cz) * CELL_SIZE - MAP_HALF_EXTENT,
			)
			if cell_centre.distance_squared_to(world_pos) <= radius_sq:
				_cells[_cell_index(cx, cz)] = CellState.VISIBLE
