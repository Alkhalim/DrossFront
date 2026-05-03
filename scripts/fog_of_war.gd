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

## Cell side length in world units. Pulled in to 1.6u so the
## exploration steps render at finer grain than the previous 2u
## block; the recent FOW perf wins (occluder-free fast-path,
## cached scene refs) leave headroom for the ~1.6x grid bump
## without the recompute spike the 1.35u attempt produced.
const CELL_SIZE: float = 1.6

## Map covers a square centred on the world origin from
## -MAP_HALF_EXTENT to +MAP_HALF_EXTENT on both X and Z axes.
## Sized to comfortably contain V2's largest map.
const MAP_HALF_EXTENT: float = 200.0

## Cells per side derived from extent + cell size. Stored as a
## constant so the grid arrays can be sized at _ready.
const GRID_SIZE: int = int((MAP_HALF_EXTENT * 2.0) / CELL_SIZE)

const FOW_REFRESH_HZ: float = 5.0

## Plateau-top elevation flag per cell. 1 = cell sits on top of a
## walkable plateau; 0 = ground / open. Set by the arena setup via
## register_plateau_footprint() once plateau geometry is placed.
## Used during _stamp_visibility -- ground observers' vision skips
## plateau-top cells (they can't see uphill); plateau-top observers
## and aircraft pass through the gate.
var _plateau_cells: PackedByteArray = PackedByteArray()
## LOS-occluder grid -- 1 = the cell contains tall terrain that
## blocks line of sight (rock pile, derelict building block, dense
## tree). Vision stamping below walks a Bresenham line from observer
## to candidate cell and stops at the first occluder, so units on
## the far side of a forest / rock spine stay hidden until the
## observer moves into the gap. Marked by terrain spawners via
## `register_los_occluder` / `unregister_los_occluder`.
var _occluder_cells: PackedByteArray = PackedByteArray()
## True iff at least one occluder cell is currently set. Lets
## _stamp_visibility skip the Bresenham line walk entirely when no
## terrain has registered as an LOS blocker (Foundry Belt + most v1
## maps), saving ~80% of the recompute cost on those maps.
var _has_any_occluders: bool = false

## Y threshold above which an observer counts as "elevated" for
## plateau LOS purposes. Plateaus are 2.5-3u tall in v2, so anything
## standing above ~1.0u is on top of one (or in the air).
const ELEVATED_OBSERVER_Y: float = 1.0

## Sight bonus multiplier for elevated observers. +30% reads as a
## meaningful "high ground advantage" without making plateau-top
## squads functionally omniscient.
const ELEVATED_SIGHT_BONUS: float = 1.30


func register_plateau_footprint(centre: Vector3, top_size: Vector2) -> void:
	## Marks every cell whose centre falls inside the AABB
	## [centre.xz - top_size/2, centre.xz + top_size/2] as plateau-top.
	## Called by arena setup once a walkable plateau is placed; the
	## ground footprint defaults to 0 (non-plateau).
	if _plateau_cells.size() != _cells.size():
		_plateau_cells.resize(_cells.size())
	if _occluder_cells.size() != _cells.size():
		_occluder_cells.resize(_cells.size())
	var hx: float = top_size.x * 0.5
	var hz: float = top_size.y * 0.5
	var min_x: float = centre.x - hx
	var max_x: float = centre.x + hx
	var min_z: float = centre.z - hz
	var max_z: float = centre.z + hz
	# Convert AABB to cell range (inclusive).
	var c_min: Vector2i = _world_to_cell(Vector3(min_x, 0.0, min_z))
	var c_max: Vector2i = _world_to_cell(Vector3(max_x, 0.0, max_z))
	for cz: int in range(c_min.y, c_max.y + 1):
		for cx: int in range(c_min.x, c_max.x + 1):
			if cx < 0 or cx >= GRID_SIZE or cz < 0 or cz >= GRID_SIZE:
				continue
			_plateau_cells[_cell_index(cx, cz)] = 1


func register_los_occluder(world_pos: Vector3, radius: float = 1.5) -> void:
	## Marks every cell within `radius` of `world_pos` as a LOS
	## occluder. Tall terrain (rocks, ruins, dense trees) call this
	## from their setup so vision stamping stops at the first
	## occluder cell along the observer-to-cell line. Cheap O(N) per
	## terrain piece called once at spawn.
	if _occluder_cells.size() != _cells.size():
		_occluder_cells.resize(_cells.size())
	var cell_radius: int = maxi(int(ceil(radius / CELL_SIZE)), 0)
	var c: Vector2i = _world_to_cell(world_pos)
	var x0: int = maxi(c.x - cell_radius, 0)
	var x1: int = mini(c.x + cell_radius, GRID_SIZE - 1)
	var z0: int = maxi(c.y - cell_radius, 0)
	var z1: int = mini(c.y + cell_radius, GRID_SIZE - 1)
	var radius_sq: float = radius * radius
	for cz: int in range(z0, z1 + 1):
		for cx: int in range(x0, x1 + 1):
			var cell_centre := Vector3(
				float(cx) * CELL_SIZE - MAP_HALF_EXTENT,
				world_pos.y,
				float(cz) * CELL_SIZE - MAP_HALF_EXTENT,
			)
			if cell_centre.distance_squared_to(world_pos) > radius_sq:
				continue
			_occluder_cells[_cell_index(cx, cz)] = 1
			_has_any_occluders = true


func unregister_los_occluder(world_pos: Vector3, radius: float = 1.5) -> void:
	## Inverse of register -- clears the cells when a tree is felled
	## or a rock destroyed. Walks the same footprint and zeroes the
	## occluder bit so vision opens up again on the next recompute.
	if _occluder_cells.size() != _cells.size():
		return
	var cell_radius: int = maxi(int(ceil(radius / CELL_SIZE)), 0)
	var c: Vector2i = _world_to_cell(world_pos)
	var x0: int = maxi(c.x - cell_radius, 0)
	var x1: int = mini(c.x + cell_radius, GRID_SIZE - 1)
	var z0: int = maxi(c.y - cell_radius, 0)
	var z1: int = mini(c.y + cell_radius, GRID_SIZE - 1)
	var radius_sq: float = radius * radius
	for cz: int in range(z0, z1 + 1):
		for cx: int in range(x0, x1 + 1):
			var cell_centre := Vector3(
				float(cx) * CELL_SIZE - MAP_HALF_EXTENT,
				world_pos.y,
				float(cz) * CELL_SIZE - MAP_HALF_EXTENT,
			)
			if cell_centre.distance_squared_to(world_pos) > radius_sq:
				continue
			_occluder_cells[_cell_index(cx, cz)] = 0


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
	# Entire subtree opt-out -- terrain landmarks (plateaus, rocks,
	# ruins) carry `_fow_skip_dim` so they stay at full brightness once
	# explored. Composited dim was producing near-solid-black plateau
	# walls.
	if node.get_meta("_fow_skip_dim", false):
		return
	var current_dim: bool = node.get_meta("_fow_dimmed", false) as bool
	if current_dim == dim:
		return
	node.set_meta("_fow_dimmed", dim)
	var overlay: Material = _make_fog_dim_overlay() if dim else null
	_apply_fog_dim_recursive(node, overlay)


func _apply_fog_dim_recursive(node: Node, overlay: Material) -> void:
	# UI-style indicator meshes (capture-area rings, capture bars,
	# floating labels) opt out of the fog dim by carrying the
	# `_fow_skip_dim` meta. The dim overlay composited over their
	# already-translucent material was producing visible flicker as
	# the FOW visibility state toggled near vision boundaries.
	if node is GeometryInstance3D:
		if not node.get_meta("_fow_skip_dim", false):
			(node as GeometryInstance3D).material_overlay = overlay
	for child: Node in node.get_children():
		_apply_fog_dim_recursive(child, overlay)

## Hound Tracker recon-support aura. Friendly units inside this
## radius of a Tracker get a sight bonus, mirroring the Tracker's
## "this branch makes the army see further" identity. Cheap to
## scan -- trackers are sparse on the field.
const TRACKER_AURA_RADIUS: float = 25.0
const TRACKER_AURA_BONUS: float = 1.15

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

## Cheat-only override. When true, _recompute_visibility skips its
## normal vision pass and stamps every cell as VISIBLE so the local
## player sees the entire map and every enemy entity. Toggled by
## the 'nofog' cheat code.
var omniscient_local: bool = false

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
	# Plateau-elevation grid pre-sized so register_plateau_footprint
	# can stamp into it without an additional resize.
	if _plateau_cells.size() != _cells.size():
		_plateau_cells.resize(_cells.size())
	if _occluder_cells.size() != _cells.size():
		_occluder_cells.resize(_cells.size())
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
	# Cheat: skip the normal vision pass and stamp every cell as
	# VISIBLE. Bump revision so the overlay + minimap pick it up.
	if omniscient_local:
		for i: int in _cells.size():
			_cells[i] = CellState.VISIBLE
		revision += 1
		_apply_entity_visibility()
		return

	# Demote currently-VISIBLE cells to EXPLORED. New vision will
	# bump them back up below; cells that were visible last tick but
	# aren't this tick stay EXPLORED so the player can still see
	# terrain features but not live enemy positions.
	for i: int in _cells.size():
		if _cells[i] == CellState.VISIBLE:
			_cells[i] = CellState.EXPLORED

	# Pre-collect Hound Tracker positions so the per-unit sight loop
	# below can apply the +15% sight aura when a friendly Anvil unit
	# stands within TRACKER_AURA_RADIUS of any Tracker. Cheap because
	# trackers are usually few; we stop scanning once the boost is
	# applied to a given unit.
	var tracker_positions: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node) or not _is_friendly(node):
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var ts: UnitStatResource = (node.get("stats") as UnitStatResource) if "stats" in node else null
		if ts and ts.unit_name.findn("Tracker") >= 0:
			tracker_positions.append((node as Node3D).global_position)

	# Walk every unit + building owned by the local player or any
	# ally and stamp visible cells around them.
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		if not _is_friendly(node):
			continue
		if "alive_count" in node and (node.get("alive_count") as int) <= 0:
			continue
		var node3d: Node3D = node as Node3D
		var radius: float = _unit_sight_radius(node)
		var is_air: bool = node.is_in_group("aircraft")
		var is_elevated: bool = is_air or node3d.global_position.y >= ELEVATED_OBSERVER_Y
		# +30% radius for elevated observers (plateau-top units +
		# aircraft) so high ground actually translates to a longer
		# spotting range.
		if is_elevated and not is_air:
			radius *= ELEVATED_SIGHT_BONUS
		# Tracker aura: any friendly unit within TRACKER_AURA_RADIUS
		# of a Hound Tracker gains +15% sight. Trackers themselves
		# also benefit when stacked. The aura is cheap-passive (no
		# resource cost, no UI) -- the Tracker's recon-support role
		# is its identity.
		if not tracker_positions.is_empty():
			for tp: Vector3 in tracker_positions:
				if node3d.global_position.distance_to(tp) <= TRACKER_AURA_RADIUS:
					radius *= TRACKER_AURA_BONUS
					break
		_stamp_visibility(node3d.global_position, radius, is_elevated, is_air)

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
		var b3d: Node3D = node as Node3D
		var b_elevated: bool = b3d.global_position.y >= ELEVATED_OBSERVER_Y
		_stamp_visibility(b3d.global_position, BUILDING_SIGHT_RADIUS, b_elevated, false)

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


## Per-entity visibility cache. Keyed by instance_id; value is a
## packed (cell_index << 2 | cell_state) so a single int compare
## detects 'this entity hasn't moved between cells AND its cell's
## state hasn't changed since last tick'. When the cache hits, the
## per-entity work is skipped entirely. Saves the dominant chunk of
## the recompute on busy maps because most entities are stationary
## inside non-changing cells.
var _entity_visibility_cache: Dictionary = {}


func _entity_state_key(node3d: Node3D) -> int:
	## Packs the entity's current cell index + cell state into a
	## single int for the visibility cache. Cell state lives in the
	## bottom 2 bits (CellState fits in 0..2); cell index shifts
	## above. Returns -1 when the position is out of grid bounds so
	## the cache miss path always re-evaluates.
	var c: Vector2i = _world_to_cell(node3d.global_position)
	var idx: int = _cell_index(c.x, c.y)
	if idx < 0 or idx >= _cells.size():
		return -1
	return (idx << 2) | (_cells[idx] & 0x3)


func _apply_entity_visibility() -> void:
	for node: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node):
			continue
		var node3d: Node3D = node as Node3D
		if not node3d:
			continue
		var owner_id: int = (node.get("owner_id") as int) if "owner_id" in node else local_player_id
		# Friendly + ally entities stay visible regardless of FOW.
		# Skip the cache + work entirely -- they're always visible.
		if owner_id == local_player_id or _is_friendly(node):
			if not node3d.visible:
				node3d.visible = true
			continue
		# Enemy / neutral unit — hide unless its current cell is
		# in line of sight. Cell state cache early-out: same cell +
		# same state as last tick = nothing to do.
		var iid: int = node3d.get_instance_id()
		var key: int = _entity_state_key(node3d)
		if _entity_visibility_cache.get(iid, -2) == key:
			continue
		_entity_visibility_cache[iid] = key
		node3d.visible = is_visible_world(node3d.global_position)

	for node: Node in get_tree().get_nodes_in_group("buildings"):
		if not is_instance_valid(node):
			continue
		var b3d: Node3D = node as Node3D
		if not b3d:
			continue
		var owner_id: int = (node.get("owner_id") as int) if "owner_id" in node else local_player_id
		if owner_id == local_player_id or _is_friendly(node):
			if not b3d.visible:
				b3d.visible = true
			_apply_fog_dim(b3d, false)
			continue
		# Foundations the placing engineer hasn't reached yet are
		# placement intent only -- they don't physically exist for
		# opponents until construction actually starts. Hide regardless
		# of explored / visible state.
		if "construction_started" in node and not (node.get("construction_started") as bool):
			if "is_constructed" in node and not (node.get("is_constructed") as bool):
				if b3d.visible:
					b3d.visible = false
				continue
		# Cache early-out: stationary buildings rarely change cell or
		# state, so the dominant case is 'no change since last tick'.
		# Skipping the recompute drops the per-tick cost of the
		# buildings sweep to one hash lookup per building.
		var b_iid: int = b3d.get_instance_id()
		var b_key: int = _entity_state_key(b3d)
		if _entity_visibility_cache.get(b_iid, -2) == b_key:
			continue
		_entity_visibility_cache[b_iid] = b_key
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
		if not w3d:
			continue
		var w_iid: int = w3d.get_instance_id()
		var w_key: int = _entity_state_key(w3d)
		if _entity_visibility_cache.get(w_iid, -2) == w_key:
			continue
		_entity_visibility_cache[w_iid] = w_key
		var w_explored: bool = is_explored_world(w3d.global_position)
		var w_visible: bool = is_visible_world(w3d.global_position)
		w3d.visible = w_explored
		_apply_fog_dim(w3d, w_explored and not w_visible)
	for node: Node in get_tree().get_nodes_in_group("fuel_deposits"):
		if not is_instance_valid(node):
			continue
		var f3d: Node3D = node as Node3D
		if not f3d:
			continue
		var f_iid: int = f3d.get_instance_id()
		var f_key: int = _entity_state_key(f3d)
		if _entity_visibility_cache.get(f_iid, -2) == f_key:
			continue
		_entity_visibility_cache[f_iid] = f_key
		var f_explored: bool = is_explored_world(f3d.global_position)
		var f_visible: bool = is_visible_world(f3d.global_position)
		f3d.visible = f_explored
		_apply_fog_dim(f3d, f_explored and not f_visible)

	# Projectiles — strictly LOS-only. A missile fired from an
	# unscouted Hammerhead would otherwise leak the unit's position
	# by drawing its arc through the fog. Only currently-VISIBLE
	# cells render projectiles; once they enter LOS they show.
	# Projectiles move every frame so cache-skipping wouldn't help;
	# they bypass the cache entirely.
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
		if not t3d:
			continue
		var t_iid: int = t3d.get_instance_id()
		var t_key: int = _entity_state_key(t3d)
		if _entity_visibility_cache.get(t_iid, -2) == t_key:
			continue
		_entity_visibility_cache[t_iid] = t_key
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


func _stamp_visibility(world_pos: Vector3, radius: float, observer_elevated: bool = false, observer_aircraft: bool = false) -> void:
	# Compute the cell-bounding box of the radius and walk every
	# cell inside it, marking those whose centre falls inside the
	# circle as VISIBLE. Square -> circle filter is cheap because
	# the bounding-box loop is small (sight radius capped well
	# below the map size).
	#
	# Plateau LOS: ground-level observers can't reveal cells that
	# sit on top of a plateau -- the elevation breaks line of
	# sight from below. Aircraft and observers already standing on
	# a plateau bypass the gate. Temporary reveals (sat crash
	# flares, ping pong) reveal regardless because they represent
	# events, not unit vision.
	var has_plateau_data: bool = _plateau_cells.size() == _cells.size()
	var skip_plateau_cells: bool = has_plateau_data and not observer_elevated and not observer_aircraft
	# Aircraft see straight over forests / rock spines, so LOS
	# occlusion only gates ground observers. Plateau-top observers
	# are typically firing DOWN into rocks/trees so they also bypass
	# the gate; keeps the elevation tradeoff consistent with the
	# 'high ground sees more' rule.
	# Skip the entire Bresenham line-walk path when the map has no
	# registered occluders. On Foundry Belt / Ashplains / Iron Gate
	# without any LOS-blocking terrain registered, this saves
	# ~14 cell reads per stamped cell -- the dominant per-recompute
	# cost on dense observer counts.
	var has_occluder_data: bool = _occluder_cells.size() == _cells.size() and _has_any_occluders
	var honour_occluders: bool = has_occluder_data and not observer_aircraft and not observer_elevated
	var origin_cell: Vector2i = _world_to_cell(world_pos)

	var cell_radius: int = int(ceil(radius / CELL_SIZE))
	var x0: int = maxi(origin_cell.x - cell_radius, 0)
	var x1: int = mini(origin_cell.x + cell_radius, GRID_SIZE - 1)
	var z0: int = maxi(origin_cell.y - cell_radius, 0)
	var z1: int = mini(origin_cell.y + cell_radius, GRID_SIZE - 1)
	var radius_sq: float = radius * radius
	for cz: int in range(z0, z1 + 1):
		for cx: int in range(x0, x1 + 1):
			var cell_centre := Vector3(
				float(cx) * CELL_SIZE - MAP_HALF_EXTENT,
				world_pos.y,
				float(cz) * CELL_SIZE - MAP_HALF_EXTENT,
			)
			if cell_centre.distance_squared_to(world_pos) > radius_sq:
				continue
			var idx: int = _cell_index(cx, cz)
			if skip_plateau_cells and _plateau_cells[idx] == 1:
				# Ground observer near a plateau -- can't see what's
				# on top, but absolutely *knows* the plateau exists.
				# Promote the cell from UNEXPLORED to EXPLORED so the
				# plateau geometry renders (dimmed) instead of leaving
				# a solid-black hole where the ground is cut and the
				# StaticBody3D stays hidden via t3d.visible = false.
				# Aircraft / plateau-top observers still drive the
				# full VISIBLE promotion below.
				if _cells[idx] == CellState.UNEXPLORED:
					_cells[idx] = CellState.EXPLORED
				continue
			# LOS occluder gate: walk the cell-grid line from the
			# observer's cell to (cx, cz) and stop at the first
			# occluder cell along the way. The occluder cell itself
			# stays visible (the player sees the trunk / rock face);
			# anything past it doesn't get a vision stamp this tick.
			# The observer's own cell never blocks; same for the
			# destination so a unit standing inside a forest still
			# reveals that cell.
			if honour_occluders and not _line_of_sight_clear(origin_cell.x, origin_cell.y, cx, cz):
				continue
			_cells[idx] = CellState.VISIBLE


func _line_of_sight_clear(x0: int, y0: int, x1: int, y1: int) -> bool:
	## Bresenham line walk between two grid cells. Returns true when
	## no cell along the line (excluding the endpoints) carries the
	## occluder flag. Endpoint cells are excluded so an observer
	## standing inside a forest still reveals its own cell, and a
	## tree at the destination still gets revealed (the player sees
	## the trunk; cells PAST the trunk are what get blocked).
	var dx: int = absi(x1 - x0)
	var dy: int = absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx - dy
	var cx: int = x0
	var cy: int = y0
	while cx != x1 or cy != y1:
		var e2: int = err * 2
		if e2 > -dy:
			err -= dy
			cx += sx
		if e2 < dx:
			err += dx
			cy += sy
		if cx == x1 and cy == y1:
			break
		if _occluder_cells[_cell_index(cx, cy)] == 1:
			return false
	return true
