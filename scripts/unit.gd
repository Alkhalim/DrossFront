class_name Unit
extends CharacterBody3D
## Base unit controller. Handles movement toward a target position.
## Composed with Selectable, etc. via child nodes.

signal arrived
signal selected
signal deselected

## The stat resource defining this unit's properties.
@export var stats: UnitStatResource

## Movement speed mapped from tier. Tunable later.
const SPEED_MAP: Dictionary = {
	&"static": 0.0,
	&"very_slow": 3.0,
	&"slow": 5.0,
	&"moderate": 8.0,
	&"fast": 12.0,
	&"very_fast": 16.0,
}

## Minimum distance to target before considering arrived.
const ARRIVE_THRESHOLD: float = 0.5

var move_target: Vector3 = Vector3.INF
var is_selected: bool = false
var _move_speed: float = 8.0


func _ready() -> void:
	add_to_group("units")
	if stats:
		_move_speed = SPEED_MAP.get(stats.speed_tier, 8.0)


func command_move(target: Vector3) -> void:
	move_target = target
	move_target.y = global_position.y


func stop() -> void:
	move_target = Vector3.INF
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if move_target == Vector3.INF:
		return

	var to_target := move_target - global_position
	to_target.y = 0.0
	var distance := to_target.length()

	if distance < ARRIVE_THRESHOLD:
		stop()
		arrived.emit()
		return

	var direction := to_target / distance
	velocity = direction * _move_speed

	# Face movement direction
	if direction.length_squared() > 0.001:
		var look_target := global_position + direction
		look_at(look_target, Vector3.UP)

	move_and_slide()


func select() -> void:
	if is_selected:
		return
	is_selected = true
	selected.emit()
	_update_selection_visual(true)


func deselect() -> void:
	if not is_selected:
		return
	is_selected = false
	deselected.emit()
	_update_selection_visual(false)


func _update_selection_visual(show: bool) -> void:
	var ring := get_node_or_null("SelectionRing")
	if ring:
		ring.visible = show
