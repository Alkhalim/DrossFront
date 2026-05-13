extends Node3D
## PF perf scratchpad — 2 players, 20+ Combine Borzoi squads per side, no win
## conditions. Boots empty with a HUD slider so you can pick the squad
## count, hit Spawn, eyeball perf, hit Clear, pick a new count, repeat.
## Pre-placed Mekh/Strelet/Borzoi and PlayerHQ are stripped on scene load
## so the arena starts clean.

const MIN_SQUADS: int = 1
const MAX_SQUADS: int = 200
const DEFAULT_SQUADS: int = 20
const SLIDER_STEP: int = 1
const PLAYER_CENTER: Vector3 = Vector3(-60, 0, 0)
const ENEMY_CENTER: Vector3 = Vector3(60, 0, 0)
# Spacing scales with squad count so high counts still fit on the map
# without overlapping at spawn. At 200 squads (~14 cols x 15 rows) we
# need ~3m spacing to keep the formation under ~45m wide.
const MIN_SPACING: float = 3.0
const MAX_SPACING: float = 4.0

var _arena: Node = null
var _units_node: Node = null
var _slider: HSlider = null
var _count_label: Label = null
var _status_label: Label = null

func _ready() -> void:
	print_debug("[PF-PERF] path_test_flowfield_perf starting")
	if not MovementFlags.use_flowfield():
		push_warning("[PF-PERF] use_flowfield is OFF — set drossfront/movement/use_flowfield=true to exercise the new system")
	_arena = $TestArena if has_node("TestArena") else null
	if _arena == null:
		push_warning("[PF-PERF] TestArena child not found")
		return
	_units_node = _arena.get_node_or_null("Units")
	if _units_node == null:
		push_warning("[PF-PERF] Units node not found")
		return

	# Strip pre-placed Mekh/Strelet/Borzoi — perf test is Borzoi-only.
	for child: Node in _units_node.get_children():
		child.queue_free()
	# Strip PlayerHQ for player-symmetry — neither side has an HQ.
	# disable_match_end (set by is_path_test()) prevents auto-defeat.
	var hq: Node = _arena.get_node_or_null("PlayerHQ")
	if hq != null:
		hq.queue_free()

	_build_hud()


func _build_hud() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 100
	add_child(layer)

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.offset_left = -240
	panel.offset_right = 240
	panel.offset_top = 16
	panel.offset_bottom = 96
	layer.add_child(panel)

	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	var label: Label = Label.new()
	label.text = "Squads per side:"
	hbox.add_child(label)

	_slider = HSlider.new()
	_slider.min_value = MIN_SQUADS
	_slider.max_value = MAX_SQUADS
	_slider.step = SLIDER_STEP
	_slider.value = DEFAULT_SQUADS
	_slider.custom_minimum_size = Vector2(220, 0)
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.value_changed.connect(_on_slider_changed)
	hbox.add_child(_slider)

	_count_label = Label.new()
	_count_label.text = str(DEFAULT_SQUADS)
	_count_label.custom_minimum_size = Vector2(36, 0)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(_count_label)

	var spawn_btn: Button = Button.new()
	spawn_btn.text = "Spawn"
	spawn_btn.pressed.connect(_on_spawn_pressed)
	hbox.add_child(spawn_btn)

	var clear_btn: Button = Button.new()
	clear_btn.text = "Clear"
	clear_btn.pressed.connect(_on_clear_pressed)
	hbox.add_child(clear_btn)

	_status_label = Label.new()
	_status_label.text = "Empty arena. Pick a count and Spawn."
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	# Stack status label below the row.
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	# Replace the panel's child with a vbox holding hbox + status.
	panel.remove_child(hbox)
	panel.add_child(vbox)
	vbox.add_child(hbox)
	vbox.add_child(_status_label)


func _on_slider_changed(v: float) -> void:
	if _count_label != null:
		_count_label.text = str(int(v))


func _on_spawn_pressed() -> void:
	_clear_units()
	# Defer one frame so the queue_freed units actually leave the tree
	# before we spawn replacements (otherwise the kernel briefly sees
	# both sets and the SelectionManager can grab freed nodes).
	await get_tree().process_frame
	var n: int = int(_slider.value)
	var p_count: int = _spawn_grid(PLAYER_CENTER, 0, n)
	var e_count: int = _spawn_grid(ENEMY_CENTER, 1, n)
	_status_label.text = "Spawned %d player hounds + %d enemy hounds" % [p_count, e_count]
	print_debug("[PF-PERF] spawned %d player + %d enemy hounds" % [p_count, e_count])


func _on_clear_pressed() -> void:
	_clear_units()
	_status_label.text = "Cleared. Pick a count and Spawn."
	print_debug("[PF-PERF] cleared")


func _clear_units() -> void:
	if _units_node == null:
		return
	for child: Node in _units_node.get_children():
		child.queue_free()


func _spawn_grid(center: Vector3, owner: int, count: int) -> int:
	# Choose the smallest near-square grid that holds `count` units, then
	# pick spacing so high counts still fit on the map (lerps between
	# MAX_SPACING for low counts and MIN_SPACING at MAX_SQUADS).
	var cols: int = int(ceil(sqrt(float(count))))
	var rows: int = int(ceil(float(count) / float(cols)))
	var t: float = clampf(float(count) / float(MAX_SQUADS), 0.0, 1.0)
	var spacing: float = lerpf(MAX_SPACING, MIN_SPACING, t)
	var x_offset: float = -float(cols - 1) * 0.5 * spacing
	var z_offset: float = -float(rows - 1) * 0.5 * spacing
	var spawned: int = 0
	for row: int in rows:
		for col: int in cols:
			if spawned >= count:
				break
			var pos: Vector3 = center + Vector3(
				x_offset + col * spacing,
				0.0,
				z_offset + row * spacing)
			if _spawn_unit("anvil_hound", pos, owner) != null:
				spawned += 1
	return spawned


func _spawn_unit(stats_path: String, pos: Vector3, owner: int) -> Node:
	var unit_scene: PackedScene = load("res://scenes/unit.tscn")
	if unit_scene == null:
		return null
	var stats: Resource = load("res://resources/units/" + stats_path + ".tres")
	if stats == null:
		return null
	var u: Node = unit_scene.instantiate()
	u.set("stats", stats)
	u.set("owner_id", owner)
	_units_node.add_child(u)
	u.global_position = pos
	return u
