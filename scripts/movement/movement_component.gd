class_name MovementComponent
extends Node                  # attached as child of CharacterBody3D, not the body itself
## Abstract base for all movement. Attached to a Node3D (or
## CharacterBody3D) unit chassis. Reads `target` from the order
## layer or its own routing logic; produces a desired velocity each
## physics frame; writes velocity to its parent body.
##
## When the parent is a CharacterBody3D (ground units), velocity is
## written via move_and_slide(). When the parent is a plain Node3D
## (aircraft, drones), position is integrated directly.
##
## Subclasses (GroundMovement / AircraftMovement / CrawlerMovement)
## implement neighbor and obstacle queries plus path planning. The
## base owns force composition and inertia. See spec §6.

signal path_unreachable(reason: int)
const REASON_NO_NAVMESH_PATH: int = 0
const REASON_GOAL_IN_OBSTACLE: int = 1
const REASON_REPEATEDLY_STUCK: int = 2
const REASON_AGENT_OFF_NAVMESH: int = 3

# --- Configurable per-instance (set by owning unit on _ready) ---
var max_speed: float = 8.0
var max_accel: float = 30.0
var max_turn_rate_rad_s: float = TAU            # default: one full rotation per second (2π rad/s)
var separate_min_distance: float = 2.5
var separate_repel: float = 6.0
var avoid_min_distance: float = 3.0
var avoid_repel: float = 24.0
@export var arrival_radius: float = 3.0

# --- Set every frame by the order layer or solo logic ---
var target: Vector3 = Vector3.INF                # INF = no active order; checked via has_target()
var effective_max_speed_cap: float = INF         # convoy cap from SquadGroup
var effective_max_turn_rate_cap: float = INF

# --- Internal state ---
var _velocity: Vector3 = Vector3.ZERO
var _body: Node3D = null                       # primary reference: position reads
var _body_physics: CharacterBody3D = null      # set if parent is CharacterBody3D
## Cached separate+avoid force from the last heavy tick. Rebuilt
## every Nth tick (per-component phase chosen from instance_id);
## reused on the other ticks so the SpatialIndex.nearby × 2 cost
## per heavy tick is amortized across N ticks. SEEK runs every
## tick on top of this so the unit still reacts to a moving
## target without the cost of full recomputation.
##
## STAGGER_PERIOD = 3 means heavy steering happens every 3rd
## physics tick per unit. At 20 Hz physics that's ~6.7 Hz
## neighbor queries; cached force is at most ~150 ms stale, ≈0.5
## u of position drift on a 4 u/s unit. Visible only if units
## are packed very tight; for typical squad spacing the cached
## force is fine.
const STAGGER_PERIOD: int = 3
var _cached_neighbor_force: Vector3 = Vector3.ZERO
var _phase_bit: int = 0
## Cached output of _is_combat_engaged. Recomputed on heavy-tick
## frames; reused on intervening ticks. The previous build called
## the virtual method (which itself does a string-keyed has_method
## lookup + dynamic dispatch + a Node.get(string) inside the unit's
## _in_active_combat) every physics tick on every unit -- 200 × 20 Hz
## = 4000 calls/sec just to gate _stuck_step. Combat state changes
## on the order of seconds; tracking it at 7 Hz is plenty.
var _combat_engaged_cached: bool = false
## When true, neighbor queries (separate / avoid) run only on the
## tick whose phase matches _phase_bit modulo STAGGER_PERIOD.
## Subclasses with fast-moving / sparse populations
## (AircraftMovement) override to false because stale neighbor
## force visibly oscillates them. Ground / crawler / worker
## movement keeps stagger on; the cost saving is worth the
## sub-tick lag for slow ground units.
var _stagger_enabled: bool = true
## PF-A — kernel registration handle. 0 means not registered (flag-off path).
var kernel_handle: int = 0
## Cached SpatialIndex reference (moved from GroundMovement so
## both ground and aircraft paths can share it). The base
## tick_movement does ONE nearby query per heavy tick and feeds
## the raw list to both _separate_neighbors and _avoid_obstacles
## via the optional `prefetched` arg — half the SpatialIndex
## hits compared to the old "each helper queries its own".
var _cached_spatial_idx: SpatialIndex = null


func _get_spatial_idx() -> SpatialIndex:
	if _cached_spatial_idx == null or not is_instance_valid(_cached_spatial_idx):
		_cached_spatial_idx = SpatialIndex.get_instance(get_tree().current_scene)
	return _cached_spatial_idx

func _ready() -> void:
	var p: Node = get_parent()
	if not (p is Node3D):
		push_error("MovementComponent must be a child of Node3D or CharacterBody3D")
		set_physics_process(false)
		return
	_body = p as Node3D
	if p is CharacterBody3D:
		_body_physics = p as CharacterBody3D
	_stuck_last_pos = _body.global_position
	# Stable per-instance phase so each unit's heavy tick lands
	# on a different frame. Modulo STAGGER_PERIOD spreads the
	# load evenly across that many frames.
	_phase_bit = int(get_instance_id()) % STAGGER_PERIOD
	# Register with the central MovementOrchestrator so we get
	# driven from one physics callback per tick instead of one
	# per component. The orchestrator disables our _physics_process
	# on registration; if no orchestrator exists yet (unit-test
	# scenes, headless boot) the fallback _physics_process below
	# runs as before.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		var orch: MovementOrchestrator = MovementOrchestrator.get_instance(scene)
		if orch:
			orch.register(self)
		# PF-A: when use_flowfield is on, register with the steering kernel.
		# Flag-off path is unchanged. Use the class-name directly (not
		# load().call()) — Script.call() doesn't reliably invoke static
		# methods on GDScript resources, and was returning null silently,
		# leaving kernel_handle = 0 and the orchestrator's flag-on path
		# inactive.
		if MovementFlags.use_flowfield():
			var kernel: Object = MovementNativeBootstrap.get_kernel(scene)
			if kernel != null:
				kernel_handle = kernel.call("register_agent",
					int(get_instance_id()),
					_agent_class_for_self(),
					_radius_for_self(),
					max_speed,
					max_accel,
					max_turn_rate_rad_s) as int


func _exit_tree() -> void:
	# Drop ourselves from the orchestrator so it doesn't keep
	# walking a freed handle. is_instance_valid in the orchestrator
	# loop handles late frees too, but explicit unregister keeps
	# the array tight.
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		var orch_node: Node = scene.get_node_or_null("MovementOrchestrator")
		if orch_node and orch_node is MovementOrchestrator:
			(orch_node as MovementOrchestrator).unregister(self)
	# PF-A: unregister from the steering kernel if we were registered.
	if kernel_handle != 0:
		if scene:
			var kernel: Object = MovementNativeBootstrap.get_kernel(scene)
			if kernel != null:
				kernel.call("unregister_agent", kernel_handle)
		kernel_handle = 0


func _physics_process(delta: float) -> void:
	## Fallback path. The orchestrator disables this on register
	## so it only fires when no orchestrator is in the scene
	## (unit tests, isolated bench scenes).
	tick_movement(delta, 0)


## Per-physics-tick movement work. Called by MovementOrchestrator
## once per registered component per tick. `frame_phase` is 0 or 1
## and lets implementations stagger heavy work across alternating
## ticks (heavy work on the tick whose phase matches the
## component's own instance-id-derived phase, light integration on
## both). Subclasses override this and call super.tick_movement
## for the base steering / inertia / move_and_slide logic.
func tick_movement(delta: float, frame_phase: int) -> void:
	if _body == null:
		return

	# PF-A: when use_flowfield is on, the kernel drives velocity. The
	# orchestrator reads kernel.get_velocity and applies it via
	# move_and_slide; we skip our own GDScript steering entirely.
	if kernel_handle != 0 and MovementFlags.use_flowfield():
		return

	# EMP paralysis: zero velocity, skip steering. Mirrors the legacy
	# path in unit.gd's _physics_process.
	var owner_unit: Node = get_parent()
	if owner_unit != null and "_emp_paralysis_remaining" in owner_unit:
		var emp_state: Variant = owner_unit.get("_emp_paralysis_remaining")
		var emp_active: bool = false
		if emp_state is float:
			emp_active = (emp_state as float) > 0.0
		if emp_active:
			_velocity = Vector3.ZERO
			if _body_physics != null:
				_body_physics.velocity = Vector3.ZERO
				_body_physics.move_and_slide()
			return

	# Heavy-tick gate also drives the combat-engaged + stuck-analysis
	# refresh below. Hoisted up here so it's one bool we can pass
	# down rather than re-evaluating the same boolean three times.
	var is_heavy_tick: bool = (not _stagger_enabled) or frame_phase == _phase_bit
	if is_heavy_tick:
		_combat_engaged_cached = _is_combat_engaged()

	if not has_target():
		# Decelerate to rest and idle. Once a CharacterBody3D unit is
		# (a) at rest, (b) on the floor, and (c) has nothing to do,
		# move_and_slide is doing zero useful work but still costs an
		# engine collide-and-slide pass per frame. The profile showed
		# this is the bulk of MovementComponent._physics_process time
		# (move_and_slide itself is engine-side and invisible to the
		# script profiler, but per-call it's the most expensive thing
		# in the loop). Skipping it once a unit has fully settled
		# saves ~half the per-frame movement cost across an idle
		# blob.
		const IDLE_VEL_EPS_SQ: float = 0.04  # 0.2 u/s squared
		var v_sq: float = _velocity.length_squared()
		# Skip the inertia step entirely when the unit is already at
		# rest. inertia_step is the largest leaf-cost in the script
		# profile (76 s session in profile 534) and an idle unit was
		# calling it every tick just to lerp 0 toward 0. The fast-path
		# branches inside inertia_step still ran and returned zero —
		# now we don't even invoke them. Gain scales with the idle
		# fraction of the population (typically ~50% of units at any
		# moment in an RTS).
		if v_sq < IDLE_VEL_EPS_SQ:
			_velocity = Vector3.ZERO
		else:
			_velocity = Steering.inertia_step(
				_velocity, Vector3.ZERO, max_accel, max_turn_rate_rad_s, delta)
		if _body_physics != null:
			_body_physics.velocity = _velocity
			# IDLE_VEL_EPS chosen so a freshly-stopped unit (velocity
			# very small but not zero from inertia rounding) still
			# slides one extra frame to fully settle. After that the
			# velocity is < eps and we skip the engine call entirely.
			var still_settling: bool = _velocity.length_squared() > IDLE_VEL_EPS_SQ
			if still_settling or not _body_physics.is_on_floor():
				_body_physics.move_and_slide()
		else:
			_body.global_position += _velocity * delta
		_stuck_step(delta, _combat_engaged_cached, is_heavy_tick)
		return

	var pos: Vector3 = _body.global_position
	var cap: float = _capped_speed()
	# Stagger: only re-query neighbors and rebuild the
	# separate+avoid force on the tick that matches our phase.
	# Cached force is re-used the off-tick so SpatialIndex queries
	# happen at half the previous rate. SEEK is recomputed every
	# tick (cheap) so the unit still tracks a moving target
	# between cache refreshes.
	if is_heavy_tick:
		# ONE SpatialIndex.nearby query per heavy tick instead of
		# two (one in _separate_neighbors, one in _avoid_obstacles).
		# The query radius is the larger of the two needs; subclass
		# filters dispose of the extras. Halves the SpatialIndex
		# cost on the heavy-tick path. Subclasses that override
		# _separate_neighbors / _avoid_obstacles accept the
		# prefetched raw list and skip their own query.
		var idx: SpatialIndex = _get_spatial_idx()
		var raw_neighbors: Array = []
		if idx != null:
			var query_radius: float = maxf(
					separate_min_distance + 1.0,
					avoid_min_distance + 2.0)
			raw_neighbors = idx.nearby(pos, query_radius)
		var sep_force: Vector3 = Steering.separate(pos,
				_separate_neighbors(raw_neighbors),
				separate_min_distance,
				separate_repel)
		var avoid_force: Vector3 = Steering.avoid_static(pos,
				_avoid_obstacles(raw_neighbors),
				avoid_min_distance,
				avoid_repel)
		_cached_neighbor_force = sep_force + avoid_force
	var desired: Vector3 = Steering.seek(pos, target, cap, arrival_radius)
	desired += _cached_neighbor_force
	if _stuck_pushout_frames_left > 0:
		desired += _stuck_pushout_dir * max_speed
		_stuck_pushout_frames_left -= 1
	# Clamp composed magnitude to capped speed
	var dlen: float = desired.length()
	if dlen > cap:
		desired = desired * (cap / dlen)

	_velocity = Steering.inertia_step(
		_velocity, desired, max_accel, _capped_turn_rate(), delta)
	if _body_physics != null:
		_body_physics.velocity = _velocity
		_body_physics.move_and_slide()
	else:
		_body.global_position += _velocity * delta
	_stuck_step(delta, _combat_engaged_cached, is_heavy_tick)

func has_target() -> bool:
	return not _is_inf(target)


## Whether this component still has work to do this tick. The
## orchestrator skips dispatching tick_movement when this returns
## false — saves the per-tick dispatch + idle-path overhead for
## fully parked units (no target, near-zero velocity, no active
## stuck-pushout). With ~50% of units typically idle in an RTS,
## halves the orchestrator's per-tick cost. Wake-up is automatic:
## the orchestrator iterates every component each tick and re-asks
## this method, so setting target / clearing target / taking damage
## that nudges velocity all transition the unit back to active on
## the very next physics tick.
func needs_tick() -> bool:
	if has_target():
		return true
	if _stuck_pushout_frames_left > 0:
		return true
	# 0.04 = 0.2 u/s squared — same epsilon used by the idle path's
	# settle check below.
	return _velocity.length_squared() > 0.04


func clear_target() -> void:
	target = Vector3.INF

## Returns the position the unit is ultimately trying to reach. For
## path-routed units, this is the final waypoint, not the live target
## (which advances waypoint by waypoint during transit). The unit-level
## arrival poll checks distance to this so it doesn't fire spuriously
## when the unit slows near an intermediate waypoint. Subclasses with
## path waypoints override this to return the path's endpoint.
func arrival_target() -> Vector3:
	return target

# --- Subclass hooks ---

## Return non-group-member dynamic agents within sensing range.
## When `prefetched` is non-empty, subclasses should filter from
## that list instead of running their own SpatialIndex query —
## the base tick_movement does ONE combined query per heavy tick
## and passes the raw list to both this and _avoid_obstacles.
func _separate_neighbors(_prefetched: Array = []) -> Array:
	return []

## Return static obstacles (buildings, wrecks, terrain hazards).
## Same `prefetched` semantics as _separate_neighbors.
func _avoid_obstacles(_prefetched: Array = []) -> Array:
	return []

# --- Helpers ---

func _capped_speed() -> float:
	return minf(max_speed, effective_max_speed_cap)

func _capped_turn_rate() -> float:
	return minf(max_turn_rate_rad_s, effective_max_turn_rate_cap)

static func _is_inf(v: Vector3) -> bool:
	return is_inf(v.x) or is_inf(v.y) or is_inf(v.z)

# --- Stuck detector ---
@export var stuck_progress_ratio_threshold: float = 0.05
@export var stuck_window_frames: int = 30
@export var stuck_repath_cooldown: float = 1.5
@export var stuck_pushout_cooldown: float = 2.0
@export var stuck_pushout_duration_frames: int = 10
@export var stuck_drop_cooldown: float = 3.0
@export var stuck_goal_snap_radius: float = 4.0

var _stuck_buffer: PackedFloat32Array = PackedFloat32Array()
var _stuck_buffer_idx: int = 0
var _stuck_last_pos: Vector3 = Vector3.ZERO
var _stuck_level: int = 0                       # 0 = healthy, 1 = repathed, 2 = pushed-out
var _stuck_cooldown_remaining: float = 0.0
var _stuck_pushout_frames_left: int = 0
var _stuck_pushout_dir: Vector3 = Vector3.ZERO

func _ensure_stuck_buffer() -> void:
	if _stuck_buffer.size() != stuck_window_frames:
		_stuck_buffer.resize(stuck_window_frames)
		var phys_dt: float = 1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
		for i: int in stuck_window_frames:
			_stuck_buffer[i] = max_speed * phys_dt  # seed as healthy
		_stuck_buffer_idx = 0

func _stuck_step(delta: float, combat_engaged: bool, is_heavy_tick: bool) -> void:
	# Cheap early-out for idle units (no active move target).
	# The stuck detector only matters while travelling; running
	# the displacement bookkeeping every tick on idle units was
	# the bulk of MovementComponent._stuck_step's call count
	# (886 in the latest profile, ~half of which were idle).
	# When a unit later gets a move order, the buffer reseeds
	# from _stuck_last_pos via the _ensure_stuck_buffer path.
	if not has_target():
		_stuck_last_pos = _body.global_position
		return
	_ensure_stuck_buffer()
	if _stuck_cooldown_remaining > 0.0:
		_stuck_cooldown_remaining -= delta
	var pos: Vector3 = _body.global_position
	var disp: float = (pos - _stuck_last_pos).length()
	_stuck_last_pos = pos
	_stuck_buffer[_stuck_buffer_idx] = disp
	_stuck_buffer_idx = (_stuck_buffer_idx + 1) % _stuck_buffer.size()

	# Stuck analysis (sum loop + ratio check + escalate) only fires
	# on heavy-tick frames. The displacement record above stays
	# per-tick so the 30-frame buffer keeps a continuous fine-grained
	# trace; the analysis just samples it at 1-in-3 rate (~7 Hz) since
	# stuck escalation works on the order of seconds anyway. Saves
	# the 30-iteration sum loop on 2/3 of all travel-path ticks.
	if not is_heavy_tick:
		return
	if combat_engaged:
		return
	if _stuck_cooldown_remaining > 0.0:
		return
	# Arrived at destination — not stuck, just standing still on slot.
	# Reset escalation level so a future actual-stuck case starts fresh.
	if arrival_radius > 0.0:
		var d_to_target: float = Vector2(pos.x - target.x, pos.z - target.z).length()
		if d_to_target < arrival_radius:
			_stuck_level = 0
			return

	var sum: float = 0.0
	for v: float in _stuck_buffer:
		sum += v
	var mean_disp: float = sum / float(_stuck_buffer.size())
	var phys_dt: float = 1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	var expected: float = max_speed * phys_dt
	if expected <= 0.0:
		return
	var ratio: float = mean_disp / expected
	if ratio > 0.5:
		# Healthy progress — reset escalation level
		_stuck_level = 0
		return
	if ratio < stuck_progress_ratio_threshold:
		_escalate()

func _escalate() -> void:
	_stuck_level += 1
	match _stuck_level:
		1:
			_stuck_cooldown_remaining = stuck_repath_cooldown
			_on_stuck_level_1_repath()
		2:
			_stuck_cooldown_remaining = stuck_pushout_cooldown
			_stuck_pushout_frames_left = stuck_pushout_duration_frames
			_stuck_pushout_dir = _compute_pushout_dir()
			_on_stuck_level_2_pushout()
		3:
			_stuck_cooldown_remaining = stuck_drop_cooldown
			_on_stuck_level_3_drop()
		_:
			# Level 4 used to halt and clear_target — for blob movement
			# that's too aggressive. A unit briefly tangled near a building
			# corner could escalate through 1→2→3→4 (~10s of bad luck) and
			# then lose its target permanently, looking like it "arrived"
			# mid-route. Now: emit the signal (so listeners — AI, HUD —
			# can react if they want) and reset back to level 0 so the
			# unit retries the recovery cycle from scratch instead of
			# giving up. The cooldown spaces retries out so we don't
			# burn CPU on a genuinely unreachable target.
			path_unreachable.emit(REASON_REPEATEDLY_STUCK)
			_on_stuck_level_4_abandon()
			_stuck_level = 0
			_stuck_cooldown_remaining = stuck_drop_cooldown

## Subclass override — request a fresh path.
func _on_stuck_level_1_repath() -> void:
	pass

## Subclass override; default no-op. The pushout direction is
## applied by the base (in _physics_process) for
## stuck_pushout_duration_frames after this fires.
func _on_stuck_level_2_pushout() -> void:
	pass

## Subclass override — drop from SquadGroup with NO_PROGRESS reason,
## then retry with a wider goal-snap radius. Default: no-op.
func _on_stuck_level_3_drop() -> void:
	pass

## Subclass override — terminal halt. Default: no-op (the base class
## already zeroed velocity and emitted path_unreachable).
func _on_stuck_level_4_abandon() -> void:
	pass

func _compute_pushout_dir() -> Vector3:
	## Default: opposite of mean obstacle direction. If no obstacles,
	## return a stable arbitrary perpendicular to current velocity.
	var pos: Vector3 = _body.global_position
	var obstacles: Array = _avoid_obstacles()
	if obstacles.is_empty():
		if _velocity.length() < 0.001:
			return Vector3.RIGHT
		return Vector3(-_velocity.z, 0, _velocity.x).normalized()
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for o: Variant in obstacles:
		if not is_instance_valid(o) or not (o is Node3D):
			continue
		sum += pos - (o as Node3D).global_position
		n += 1
	if n == 0:
		return Vector3.RIGHT
	sum.y = 0
	return sum.normalized()

## Subclass override — returns true if the unit is currently in
## combat (suppresses stuck detection per spec §11).
func _is_combat_engaged() -> bool:
	return false


## PF-A — agent class lookup for the steering kernel. Subclasses override
## (GroundMovement keeps default small; Aircraft sets aircraft flag in PF-B;
## Crawler returns large in PF-B).
func _agent_class_for_self() -> int:
	return 0  # AGENT_CLASS_SMALL


func _radius_for_self() -> float:
	return 0.6  # default small radius


## PF-A — called by MovementOrchestrator under flag-on with the velocity
## the C++ kernel computed for this agent. Default applies it to
## CharacterBody3D + move_and_slide; subclasses override to add
## entity-specific post-processing (GroundMovement adds gravity + body
## yaw rotation; AircraftMovement will add altitude + banking in PF-B).
func _apply_kernel_velocity(v: Vector3, delta: float) -> void:
	if _body_physics != null:
		_body_physics.velocity = v
		_body_physics.move_and_slide()
	elif _body != null:
		_body.global_position += v * delta
