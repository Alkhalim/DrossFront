extends Control
## Main menu — entry point of the game. Three top-level pages:
##   - Main: Play / Tutorial / Settings / Quit
##   - Match Setup: every match-config control on one screen
##     (mode, map+thumbnail, faction+icon, per-AI difficulty +
##     personality dropdowns)
##   - Settings: SFX / Voice / Music volume sliders
## All UI is built in code so the .tscn stays minimal; helper Controls
## (FactionIcon / MapPreview) draw their visuals procedurally.

const ARENA_SCENE: String = "res://scenes/test_arena.tscn"

const COLOR_TITLE := Color(0.95, 0.92, 0.78, 1.0)
const COLOR_SUBTITLE := Color(0.55, 0.95, 0.55, 1.0)
const COLOR_HINT := Color(0.7, 0.85, 0.95, 1.0)
const COLOR_HEADING := Color(0.85, 0.85, 0.80, 1.0)

const FactionIconScript: GDScript = preload("res://scripts/faction_icon.gd")
const MapPreviewScript: GDScript = preload("res://scripts/map_preview.gd")

var _root_vbox: VBoxContainer = null
var _main_buttons: VBoxContainer = null
var _setup_panel: VBoxContainer = null
var _settings_panel: VBoxContainer = null
var _campaigns_panel: VBoxContainer = null
var _scenarios_panel: VBoxContainer = null
var _tactical_bg: Control = null
## Brief white-flash overlay used during the command-center screen
## transition (Campaigns / back). Hidden until a transition fires.
var _transition_flash: ColorRect = null
## Camera-sweep overlay -- a dark vertical bar that slides across
## the screen during the radar -> Europe-map transition, mimicking
## the operator physically turning toward another monitor.
var _camera_sweep: ColorRect = null
## Refs to the stump buttons so the campaigns transition can stagger
## them in with a per-button "ping" tween once the map fills the
## screen.
var _campaign_stumps: Array[Button] = []

# Setup-screen state — populated by the radio buttons / faction picks.
var _selected_mode: int = MatchSettingsClass.Mode.ONE_V_ONE
var _selected_map: int = MatchSettingsClass.MapId.FOUNDRY_BELT
var _selected_faction: int = MatchSettingsClass.FactionId.ANVIL

# Setup-screen widgets so the mode toggle can rebuild the AI rows.
var _mode_buttons: Array[Button] = []
var _map_dropdown: OptionButton = null
var _map_preview: Control = null
var _map_info_label: Label = null
var _faction_summary_panel: PanelContainer = null
var _ai_rows_container: VBoxContainer = null
var _ai_faction_dropdowns: Dictionary = {}    # player_id → OptionButton
var _ai_difficulty_dropdowns: Dictionary = {}  # player_id → OptionButton
var _ai_personality_dropdowns: Dictionary = {}  # player_id → OptionButton

const _MAP_INFO: Dictionary = {
	MatchSettingsClass.MapId.FOUNDRY_BELT: {
		"label": "Corridor 7",
		"blurb": "Numbered industrial transit corridor, contested.\nMultiple chokepoints, dense salvage,\nApex wreck objective.",
	},
	MatchSettingsClass.MapId.ASHPLAINS_CROSSING: {
		"label": "The Ashline",
		"blurb": "Contaminated flatland crossing point.\nLong sightlines, sparse cover,\nfavours ranged combat.",
	},
	MatchSettingsClass.MapId.IRON_GATE_CROSSING: {
		"label": "Gatepoint Rhin",
		"blurb": "Militarized crossing on the Rhine corridor.\nDense ruin clusters favour stealth flanks,\ncentral corridor favours heavy push.",
	},
	MatchSettingsClass.MapId.SCHWARZWALD: {
		"label": "Schwarzwald",
		"blurb": "Dense forest carved by chokepoint corridors.\nTrees block sight + movement, drop salvage when felled.\nHeavy / slow weapons clear vegetation; rapid fire bounces off.",
	},
}


func _ready() -> void:
	# Install the gunmetal cursor so the main menu shares the in-game
	# cursor look. Loaded via preload to avoid the class-name lookup
	# parsing window — the static helper builds the texture directly
	# without instancing a CursorManager node.
	var cursor_script: GDScript = preload("res://scripts/cursor_manager.gd")
	cursor_script.apply_default_cursor()
	_apply_theme()
	_build_layout()
	_show_main()
	# Universal music for the menus — the MusicManager child node
	# loads the Universal/ folder and cycles through it indefinitely.
	var mm: Node = get_node_or_null("MusicManager")
	if mm and mm.has_method("start"):
		mm.call("start", -1)


func _apply_theme() -> void:
	## Command-center theme. Sharp-cornered steel slate with a thin
	## brass border, no rounded corners. Hover lights the border up
	## brass + brightens the fill so each button reads as a tactical
	## terminal entry rather than a generic dialog control. The L-
	## shaped corner brackets that complete the look are added per-
	## button by _add_command_center_brackets().
	var theme_res := Theme.new()
	theme_res.set_default_font_size(16)

	var btn_normal := StyleBoxFlat.new()
	btn_normal.bg_color = Color(0.10, 0.11, 0.13, 1.0)
	btn_normal.border_color = Color(0.55, 0.46, 0.30, 0.85)  # dim brass
	btn_normal.border_width_top = 1
	btn_normal.border_width_bottom = 1
	btn_normal.border_width_left = 1
	btn_normal.border_width_right = 1
	# No rounded corners -- the chamfered industrial silhouette is
	# carried by the corner brackets, not by softened edges.
	btn_normal.corner_radius_top_left = 0
	btn_normal.corner_radius_top_right = 0
	btn_normal.corner_radius_bottom_left = 0
	btn_normal.corner_radius_bottom_right = 0
	# Generous left margin so the ">" label prefix sits flush left
	# with breathing room before the entry text.
	btn_normal.content_margin_left = 18
	btn_normal.content_margin_right = 14
	btn_normal.content_margin_top = 8
	btn_normal.content_margin_bottom = 8

	var btn_hover := btn_normal.duplicate() as StyleBoxFlat
	btn_hover.bg_color = Color(0.16, 0.14, 0.10, 1.0)
	btn_hover.border_color = Color(1.00, 0.78, 0.32, 1.0)  # bright brass
	btn_hover.set_border_width_all(2)

	var btn_pressed := btn_normal.duplicate() as StyleBoxFlat
	# Pressed = darker fill, brighter accent border, content nudged
	# down 1px so the click reads as a physical key press.
	btn_pressed.bg_color = Color(0.05, 0.05, 0.07, 1.0)
	btn_pressed.border_color = Color(1.0, 0.92, 0.55, 1.0)
	btn_pressed.set_border_width_all(2)
	btn_pressed.content_margin_top = 9
	btn_pressed.content_margin_bottom = 7
	btn_pressed.shadow_color = Color(0, 0, 0, 0.5)
	btn_pressed.shadow_size = 2
	btn_pressed.shadow_offset = Vector2(0, 1)

	theme_res.set_stylebox("normal", "Button", btn_normal)
	theme_res.set_stylebox("hover", "Button", btn_hover)
	theme_res.set_stylebox("pressed", "Button", btn_pressed)
	theme_res.set_stylebox("focus", "Button", btn_hover)
	theme_res.set_color("font_color", "Button", Color(0.92, 0.88, 0.78, 1.0))
	theme_res.set_color("font_hover_color", "Button", Color(1.00, 0.95, 0.78, 1.0))
	theme_res.set_color("font_pressed_color", "Button", Color(1.00, 0.92, 0.55, 1.0))

	theme = theme_res


func _build_layout() -> void:
	# Dark backdrop covering the screen.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.06, 0.07, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Tactical overview backdrop — procedurally-drawn command-center feel:
	# fading scan grid, contour lines, scattered unit pips, and a slow
	# sweeping radar arc. Sits between the flat backdrop and the menu
	# widgets so the UI text stays cleanly readable on top.
	var tactical_bg := _build_tactical_background()
	add_child(tactical_bg)
	_tactical_bg = tactical_bg

	# Centered column.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_root_vbox = VBoxContainer.new()
	_root_vbox.add_theme_constant_override("separation", 14)
	_root_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(_root_vbox)

	# Title block — letter-spaced "DROSSFRONT" with a heavy iron-plate
	# weight, brass-accented glow, and a pair of bracketing rules so it
	# reads like a stamped insignia rather than a system label.
	var title := Label.new()
	title.text = "D R O S S F R O N T"
	title.add_theme_font_size_override("font_size", 88)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.add_theme_color_override("font_outline_color", Color(0.10, 0.07, 0.04, 1.0))
	title.add_theme_constant_override("outline_size", 8)
	title.add_theme_color_override("font_shadow_color", Color(0.95, 0.55, 0.20, 0.45))
	title.add_theme_constant_override("shadow_offset_x", 0)
	title.add_theme_constant_override("shadow_offset_y", 0)
	title.add_theme_constant_override("shadow_outline_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root_vbox.add_child(title)

	# Pair of thin horizontal rules above and below the title — the
	# "stamped onto a chassis plate" feel. Drawn as ColorRects so we
	# don't need a font with built-in decorations.
	var rule_below := ColorRect.new()
	rule_below.custom_minimum_size = Vector2(420, 2)
	rule_below.color = Color(0.95, 0.65, 0.28, 0.85)
	rule_below.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_root_vbox.add_child(rule_below)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 28)
	_root_vbox.add_child(spacer)

	_build_main_buttons()
	_build_setup_panel()
	_build_settings_panel()
	_build_campaigns_panel()
	_build_scenarios_panel()
	# Transition flash -- a fullscreen white ColorRect that pulses
	# briefly during command-center screen changes (Campaigns / back).
	# Lives ABOVE every other UI layer so the flash dominates the
	# transition midpoint. mouse_filter = IGNORE so it doesn't eat
	# clicks while sitting at modulate.a = 0.
	_transition_flash = ColorRect.new()
	_transition_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_transition_flash.color = Color(0.85, 1.0, 0.85, 0.0)
	_transition_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_transition_flash)


func _build_main_buttons() -> void:
	_main_buttons = VBoxContainer.new()
	_main_buttons.add_theme_constant_override("separation", 10)
	_main_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_root_vbox.add_child(_main_buttons)

	# Command-center entry list. The "▌ NN" prefix reads as a
	# command-line index marker and the all-caps label sells the
	# tactical / military terminal feel without forcing a font swap.
	# Buttons themselves are deliberately narrow (220x42) so they
	# stack like a chassis-plate menu instead of stretching like a
	# generic web form.
	var entries: Array[Dictionary] = [
		{ "label": "Skirmish",  "callback": Callable(self, "_on_play_pressed") },
		{ "label": "Campaigns", "callback": Callable(self, "_on_campaigns_pressed") },
		{ "label": "Tutorial",  "callback": Callable(self, "_on_tutorial_pressed") },
		{ "label": "Settings",  "callback": Callable(self, "_on_settings_pressed") },
		{ "label": "Quit",      "callback": Callable(self, "_on_quit_pressed") },
	]
	for i: int in entries.size():
		var entry: Dictionary = entries[i]
		var btn := Button.new()
		btn.text = "▌ %02d  %s" % [i + 1, (entry["label"] as String).to_upper()]
		btn.custom_minimum_size = Vector2(220, 42)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(entry["callback"] as Callable)
		_main_buttons.add_child(btn)
		_add_command_center_brackets(btn)


func _add_command_center_brackets(btn: Button) -> void:
	## Drape a custom-drawn Control over the button that paints
	## brass L-shaped corner brackets. The Control resizes with the
	## button (PRESET_FULL_RECT) and ignores mouse input so clicks
	## still reach the underlying button. Hover state tracks the
	## button's pressed/hovered look via a tiny callback.
	var deco := Control.new()
	deco.name = "CmdCenterBrackets"
	deco.set_anchors_preset(Control.PRESET_FULL_RECT)
	deco.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(deco)
	# Render via a dedicated draw helper so we can re-use the same
	# bracket shapes elsewhere if more menus need them.
	deco.draw.connect(_draw_command_center_brackets.bind(deco, btn))
	# Repaint on hover state changes so the brackets glow brighter
	# when the user is over the button.
	btn.mouse_entered.connect(deco.queue_redraw)
	btn.mouse_exited.connect(deco.queue_redraw)
	btn.focus_entered.connect(deco.queue_redraw)
	btn.focus_exited.connect(deco.queue_redraw)


func _draw_command_center_brackets(deco: Control, btn: Button) -> void:
	## Paints four L-shaped brackets at the button corners + a small
	## diamond accent at the right edge so the silhouette reads as a
	## tactical terminal entry rather than a flat slab.
	var sz: Vector2 = deco.size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	var hot: bool = btn.has_focus() or btn.get_global_rect().has_point(btn.get_global_mouse_position())
	var col: Color = Color(1.00, 0.78, 0.32, 1.0) if hot else Color(0.55, 0.46, 0.30, 0.85)
	var L: float = 11.0
	var t: float = 2.0
	var inset: float = 3.0
	# Four corner L brackets.
	deco.draw_rect(Rect2(inset, inset, L, t), col, true)
	deco.draw_rect(Rect2(inset, inset, t, L), col, true)
	deco.draw_rect(Rect2(sz.x - inset - L, inset, L, t), col, true)
	deco.draw_rect(Rect2(sz.x - inset - t, inset, t, L), col, true)
	deco.draw_rect(Rect2(inset, sz.y - inset - t, L, t), col, true)
	deco.draw_rect(Rect2(inset, sz.y - inset - L, t, L), col, true)
	deco.draw_rect(Rect2(sz.x - inset - L, sz.y - inset - t, L, t), col, true)
	deco.draw_rect(Rect2(sz.x - inset - t, sz.y - inset - L, t, L), col, true)
	# Right-edge diamond accent -- small rotated square 6px in from
	# the right edge, visually anchors the "row" feel of each entry.
	# Drawn as two triangles so we don't need a transform stack.
	var dx: float = sz.x - 12.0
	var dy: float = sz.y * 0.5
	var d: float = 4.0
	deco.draw_colored_polygon(
		PackedVector2Array([
			Vector2(dx, dy - d),
			Vector2(dx + d, dy),
			Vector2(dx, dy + d),
			Vector2(dx - d, dy),
		]),
		col,
	)


## --- Match Setup panel (single consolidated screen) ----------------------

func _build_setup_panel() -> void:
	_setup_panel = VBoxContainer.new()
	_setup_panel.add_theme_constant_override("separation", 14)
	_setup_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_setup_panel.visible = false
	_root_vbox.add_child(_setup_panel)

	var heading := Label.new()
	heading.text = "Match Setup"
	heading.add_theme_font_size_override("font_size", 24)
	heading.add_theme_color_override("font_color", COLOR_SUBTITLE)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_setup_panel.add_child(heading)

	# Two-column layout — controls on the left (mode / faction / AI
	# rows), map picker on the right (dropdown + preview thumbnail +
	# info blurb stacked vertically).
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 28)
	split.alignment = BoxContainer.ALIGNMENT_CENTER
	_setup_panel.add_child(split)

	var left_col := VBoxContainer.new()
	left_col.add_theme_constant_override("separation", 12)
	split.add_child(left_col)

	var right_col := VBoxContainer.new()
	right_col.add_theme_constant_override("separation", 8)
	right_col.alignment = BoxContainer.ALIGNMENT_CENTER
	split.add_child(right_col)

	_build_mode_section(left_col)
	_build_faction_section(left_col)
	_build_color_section(left_col)
	_build_ai_section(left_col)
	_build_map_section(right_col)
	_build_setup_buttons()


func _build_mode_section(parent: Container) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	parent.add_child(hbox)

	var label := Label.new()
	label.text = "Match Format:"
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", COLOR_HEADING)
	hbox.add_child(label)

	for entry: Dictionary in [
		{ "label": "1v1", "value": MatchSettingsClass.Mode.ONE_V_ONE },
		{ "label": "2v2", "value": MatchSettingsClass.Mode.TWO_V_TWO },
	]:
		var btn := Button.new()
		btn.text = entry["label"] as String
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(80, 36)
		btn.pressed.connect(_on_mode_toggle.bind(entry["value"] as int))
		_mode_buttons.append(btn)
		hbox.add_child(btn)
	_apply_mode_toggle_state()


func _build_map_section(parent: Container) -> void:
	var heading := Label.new()
	heading.text = "Map:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	parent.add_child(heading)

	# Dropdown — pick a map by name. The preview image + info blurb
	# below update automatically when selection changes.
	_map_dropdown = OptionButton.new()
	_map_dropdown.custom_minimum_size = Vector2(240, 32)
	for map_id_v: int in [
		MatchSettingsClass.MapId.FOUNDRY_BELT,
		MatchSettingsClass.MapId.ASHPLAINS_CROSSING,
		MatchSettingsClass.MapId.IRON_GATE_CROSSING,
		MatchSettingsClass.MapId.SCHWARZWALD,
	]:
		var info: Dictionary = _MAP_INFO[map_id_v] as Dictionary
		_map_dropdown.add_item(info["label"] as String, map_id_v)
	_map_dropdown.selected = _map_dropdown.get_item_index(_selected_map)
	_map_dropdown.item_selected.connect(_on_map_dropdown_selected)
	parent.add_child(_map_dropdown)

	# Procedural map preview thumbnail.
	_map_preview = MapPreviewScript.new()
	_map_preview.map_id = _selected_map
	_map_preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(_map_preview)

	# Info blurb (multi-line label) under the preview.
	_map_info_label = Label.new()
	_map_info_label.add_theme_font_size_override("font_size", 14)
	_map_info_label.add_theme_color_override("font_color", COLOR_HINT)
	_map_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_info_label.custom_minimum_size = Vector2(240, 64)
	parent.add_child(_map_info_label)
	_apply_map_dropdown_state()


## Faction roster for the dropdown picker. Adding a new faction
## drops a new entry here and the rest of the UI (dropdown +
## summary panel + tech-tree route) picks it up automatically.
const _PLAYABLE_FACTIONS: Array[Dictionary] = [
	{ "value": MatchSettingsClass.FactionId.ANVIL,
	  "icon_id": 0,  # FactionIconScript.Faction.ANVIL
	  "label": "Anvil Directive",
	  "tagline": "Heavy industrial — armored, deliberate, anchors a position." },
	{ "value": MatchSettingsClass.FactionId.SABLE,
	  "icon_id": 1,  # FactionIconScript.Faction.SABLE
	  "label": "Sable Concord",
	  "tagline": "Information warfare — fast, fragile, plays the whole map." },
]


func _build_faction_section(parent: Container) -> void:
	var heading := Label.new()
	heading.text = "Your Faction:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	parent.add_child(heading)

	# Dropdown picker -- using OptionButton so adding a new faction
	# is just an entry in _PLAYABLE_FACTIONS and the picker grows
	# without the layout changing.
	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(280, 32)
	for i: int in _PLAYABLE_FACTIONS.size():
		var entry: Dictionary = _PLAYABLE_FACTIONS[i]
		picker.add_item(entry["label"] as String, entry["value"] as int)
	# Pre-select the currently-stored faction.
	for i: int in picker.item_count:
		if picker.get_item_id(i) == _selected_faction:
			picker.select(i)
			break
	picker.item_selected.connect(_on_faction_dropdown_changed.bind(picker))
	parent.add_child(picker)

	# Summary panel below the dropdown -- icon + tagline + View
	# Tech Tree button. Refreshed via _refresh_faction_summary
	# whenever the dropdown changes.
	_faction_summary_panel = PanelContainer.new()
	_faction_summary_panel.custom_minimum_size = Vector2(280, 140)
	parent.add_child(_faction_summary_panel)
	_refresh_faction_summary()


func _on_faction_dropdown_changed(index: int, picker: OptionButton) -> void:
	var faction_id: int = picker.get_item_id(index)
	_selected_faction = faction_id as MatchSettingsClass.FactionId
	_refresh_faction_summary()


func _refresh_faction_summary() -> void:
	if not _faction_summary_panel:
		return
	for child: Node in _faction_summary_panel.get_children():
		child.queue_free()
	# Resolve the entry for the currently-selected faction.
	var entry: Dictionary = {}
	for e: Dictionary in _PLAYABLE_FACTIONS:
		if (e["value"] as int) == int(_selected_faction):
			entry = e
			break
	if entry.is_empty():
		return

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	_faction_summary_panel.add_child(hbox)

	# Icon column.
	var icon_col := VBoxContainer.new()
	icon_col.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_child(icon_col)
	var icon: Control = FactionIconScript.new()
	icon.faction = entry["icon_id"] as int
	icon.custom_minimum_size = Vector2(72, 72)
	icon_col.add_child(icon)

	# Text + button column.
	var text_col := VBoxContainer.new()
	text_col.add_theme_constant_override("separation", 6)
	text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(text_col)

	var name_lbl := Label.new()
	name_lbl.text = entry["label"] as String
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", COLOR_HEADING)
	text_col.add_child(name_lbl)

	var tag := Label.new()
	tag.text = entry["tagline"] as String
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tag.custom_minimum_size = Vector2(180, 0)
	tag.add_theme_font_size_override("font_size", 12)
	tag.add_theme_color_override("font_color", Color(0.78, 0.85, 0.95, 1.0))
	text_col.add_child(tag)

	var tech_btn := Button.new()
	tech_btn.text = "View Tech Tree"
	tech_btn.custom_minimum_size = Vector2(180, 28)
	tech_btn.pressed.connect(_show_faction_tech_tree.bind(int(_selected_faction)))
	text_col.add_child(tech_btn)


## Active player-colour swatch buttons. Held in an array so the
## click handler can flip pressed-state on the lot in one pass
## (toggle group: only one selected at a time).
var _color_swatches: Array[Button] = []


func _build_color_section(parent: Container) -> void:
	var heading := Label.new()
	heading.text = "Your Color:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	parent.add_child(heading)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	_color_swatches.clear()
	# Pre-select whichever palette index matches the current
	# MatchSettings.player_color (or 0 if nothing matches).
	var sel: int = 0
	for i: int in MatchSettingsClass.PLAYER_COLOR_PALETTE.size():
		if MatchSettingsClass.PLAYER_COLOR_PALETTE[i].is_equal_approx(MatchSettings.player_color):
			sel = i
			break

	for i: int in MatchSettingsClass.PLAYER_COLOR_PALETTE.size():
		var col: Color = MatchSettingsClass.PLAYER_COLOR_PALETTE[i]
		var swatch := Button.new()
		swatch.toggle_mode = true
		swatch.custom_minimum_size = Vector2(40, 32)
		swatch.tooltip_text = MatchSettingsClass.PLAYER_COLOR_NAMES[i]
		# StyleBoxFlat per state so the swatch reads as a coloured
		# tile with a thin border that brightens when toggled.
		var fill := StyleBoxFlat.new()
		fill.bg_color = col
		fill.border_color = Color(0.10, 0.10, 0.12, 1.0)
		fill.border_width_top = 2
		fill.border_width_bottom = 2
		fill.border_width_left = 2
		fill.border_width_right = 2
		fill.corner_radius_top_left = 4
		fill.corner_radius_top_right = 4
		fill.corner_radius_bottom_left = 4
		fill.corner_radius_bottom_right = 4
		swatch.add_theme_stylebox_override("normal", fill)
		swatch.add_theme_stylebox_override("hover", fill)
		swatch.add_theme_stylebox_override("focus", fill)
		var fill_pressed := fill.duplicate() as StyleBoxFlat
		fill_pressed.border_color = Color(1.0, 0.95, 0.78, 1.0)
		fill_pressed.border_width_top = 3
		fill_pressed.border_width_bottom = 3
		fill_pressed.border_width_left = 3
		fill_pressed.border_width_right = 3
		swatch.add_theme_stylebox_override("pressed", fill_pressed)
		swatch.button_pressed = (i == sel)
		swatch.pressed.connect(_on_color_swatch_pressed.bind(i))
		_color_swatches.append(swatch)
		row.add_child(swatch)


func _on_color_swatch_pressed(index: int) -> void:
	if index < 0 or index >= MatchSettingsClass.PLAYER_COLOR_PALETTE.size():
		return
	MatchSettings.player_color = MatchSettingsClass.PLAYER_COLOR_PALETTE[index]
	# Toggle group -- enforce one-of selection by depressing the
	# others; pressed-state needs a manual sync because Button's
	# toggle_mode doesn't natively group siblings.
	for i: int in _color_swatches.size():
		_color_swatches[i].button_pressed = (i == index)


func _build_ai_section(parent: Container) -> void:
	var heading := Label.new()
	heading.text = "AI Setup:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	parent.add_child(heading)

	_ai_rows_container = VBoxContainer.new()
	_ai_rows_container.add_theme_constant_override("separation", 6)
	parent.add_child(_ai_rows_container)
	_rebuild_ai_rows()


func _rebuild_ai_rows() -> void:
	## Tear down + rebuild the AI dropdown rows whenever the mode
	## toggle flips. 1v1 has one enemy AI; 2v2 has the ally + two
	## enemies. Each row holds a faction + difficulty + personality
	## dropdown.
	for child: Node in _ai_rows_container.get_children():
		child.queue_free()
	_ai_faction_dropdowns.clear()
	_ai_difficulty_dropdowns.clear()
	_ai_personality_dropdowns.clear()
	# Roster definitions match TestArenaController's roster constants.
	var ais: Array[Dictionary] = []
	if _selected_mode == MatchSettingsClass.Mode.ONE_V_ONE:
		ais.append({"id": 1, "name": "AI Bravo", "team": 1})
	else:
		ais.append({"id": 1, "name": "AI Charlie (ally)", "team": 0})
		ais.append({"id": 3, "name": "AI Bravo", "team": 1})
		ais.append({"id": 4, "name": "AI Delta", "team": 1})
	for entry: Dictionary in ais:
		_build_ai_row(entry["id"] as int, entry["name"] as String, entry["team"] as int)


func _build_ai_row(player_id: int, label_text: String, team: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_ai_rows_container.add_child(row)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.custom_minimum_size = Vector2(140, 30)
	# Ally rows tinted green, enemy rows red — same colour scheme as
	# the minimap so the player reads at a glance which is which.
	if team == 0:
		name_label.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55, 1.0))
	else:
		name_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.50, 1.0))
	row.add_child(name_label)

	# Per-AI faction dropdown — defaults to the team-based fallback
	# (ally takes player_faction, enemy takes the opposite). Selecting
	# an explicit faction here writes ai_factions[player_id] on Start.
	var fac_dropdown := OptionButton.new()
	fac_dropdown.custom_minimum_size = Vector2(110, 32)
	for fac_entry: Dictionary in [
		{"label": "Anvil", "value": MatchSettingsClass.FactionId.ANVIL},
		{"label": "Sable", "value": MatchSettingsClass.FactionId.SABLE},
	]:
		fac_dropdown.add_item(fac_entry["label"] as String, fac_entry["value"] as int)
	# Default selection mirrors the team-based fallback so the player
	# doesn't need to touch every dropdown if they're happy with the
	# auto-pick: ally inherits the player's faction, enemy gets the
	# opposite.
	if team == 0:
		fac_dropdown.selected = fac_dropdown.get_item_index(_selected_faction)
	else:
		var opp: int = (
			MatchSettingsClass.FactionId.SABLE
			if _selected_faction == MatchSettingsClass.FactionId.ANVIL
			else MatchSettingsClass.FactionId.ANVIL
		)
		fac_dropdown.selected = fac_dropdown.get_item_index(opp)
	row.add_child(fac_dropdown)
	_ai_faction_dropdowns[player_id] = fac_dropdown

	var diff_dropdown := OptionButton.new()
	diff_dropdown.custom_minimum_size = Vector2(110, 32)
	for diff_entry: Dictionary in [
		{"label": "Easy", "value": MatchSettingsClass.Difficulty.EASY},
		{"label": "Normal", "value": MatchSettingsClass.Difficulty.NORMAL},
		{"label": "Hard", "value": MatchSettingsClass.Difficulty.HARD},
	]:
		diff_dropdown.add_item(diff_entry["label"] as String, diff_entry["value"] as int)
	diff_dropdown.selected = 1  # default Normal
	row.add_child(diff_dropdown)
	_ai_difficulty_dropdowns[player_id] = diff_dropdown

	var pers_dropdown := OptionButton.new()
	pers_dropdown.custom_minimum_size = Vector2(150, 32)
	for pers_entry: Dictionary in [
		{"label": "Random", "value": MatchSettingsClass.AiPersonality.RANDOM},
		{"label": "Balanced", "value": MatchSettingsClass.AiPersonality.BALANCED},
		{"label": "Turret-Heavy", "value": MatchSettingsClass.AiPersonality.TURRET_HEAVY},
		{"label": "Economy-Heavy", "value": MatchSettingsClass.AiPersonality.ECONOMY_HEAVY},
		{"label": "Rush", "value": MatchSettingsClass.AiPersonality.RUSH},
	]:
		pers_dropdown.add_item(pers_entry["label"] as String, pers_entry["value"] as int)
	pers_dropdown.selected = 0  # default Random
	row.add_child(pers_dropdown)
	_ai_personality_dropdowns[player_id] = pers_dropdown


func _build_setup_buttons() -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	_setup_panel.add_child(spacer)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_setup_panel.add_child(hbox)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(160, 36)
	back.pressed.connect(_show_main)
	hbox.add_child(back)

	var start := Button.new()
	start.text = "Start Match"
	start.custom_minimum_size = Vector2(220, 40)
	start.pressed.connect(_on_start_match_pressed)
	hbox.add_child(start)


## --- Settings panel (3 audio sliders) ------------------------------------

func _build_settings_panel() -> void:
	_settings_panel = VBoxContainer.new()
	_settings_panel.add_theme_constant_override("separation", 10)
	_settings_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_settings_panel.visible = false
	_root_vbox.add_child(_settings_panel)

	var heading := Label.new()
	heading.text = "Settings"
	heading.add_theme_font_size_override("font_size", 22)
	heading.add_theme_color_override("font_color", COLOR_SUBTITLE)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_settings_panel.add_child(heading)

	# One slider per audio bus. Range from -40 dB (effectively muted) to
	# +6 dB (a tad above unity). The bus init values (-3 dB SFX, +5 dB
	# Voiceline, 0 dB Music) load as the slider's starting position.
	for entry: Dictionary in [
		{"label": "SFX", "bus": "SFX"},
		{"label": "Voices", "bus": "Voiceline"},
		{"label": "Music", "bus": "Music"},
	]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_settings_panel.add_child(row)

		var label := Label.new()
		label.text = entry["label"] as String
		label.add_theme_font_size_override("font_size", 16)
		label.custom_minimum_size = Vector2(80, 24)
		row.add_child(label)

		var slider := HSlider.new()
		slider.custom_minimum_size = Vector2(280, 24)
		slider.min_value = -40.0
		slider.max_value = 6.0
		slider.step = 1.0
		var bus_idx: int = AudioServer.get_bus_index(entry["bus"] as String)
		if bus_idx >= 0:
			slider.value = AudioServer.get_bus_volume_db(bus_idx)
		else:
			slider.value = 0.0
		slider.value_changed.connect(_on_bus_volume_changed.bind(entry["bus"] as String))
		row.add_child(slider)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(160, 36)
	back.pressed.connect(_show_main)
	_settings_panel.add_child(back)


## --- Navigation ---

func _show_main() -> void:
	_root_vbox.visible = true
	_main_buttons.visible = true
	_setup_panel.visible = false
	_settings_panel.visible = false
	if _campaigns_panel:
		_campaigns_panel.visible = false
	if _scenarios_panel:
		_scenarios_panel.visible = false


func _show_setup() -> void:
	_root_vbox.visible = true
	_main_buttons.visible = false
	_setup_panel.visible = true
	_settings_panel.visible = false
	if _campaigns_panel:
		_campaigns_panel.visible = false
	if _scenarios_panel:
		_scenarios_panel.visible = false


func _show_settings() -> void:
	_root_vbox.visible = true
	_main_buttons.visible = false
	_setup_panel.visible = false
	_settings_panel.visible = true
	if _campaigns_panel:
		_campaigns_panel.visible = false
	if _scenarios_panel:
		_scenarios_panel.visible = false


func _show_campaigns() -> void:
	# Campaigns swaps to a full-screen Control (the Europe-map page
	# should fill the screen, not live as a small window over the
	# main-menu layout). Hide the centered root VBox while the
	# campaigns page is up so the title block + main buttons don't
	# bleed through.
	_root_vbox.visible = false
	_main_buttons.visible = false
	_setup_panel.visible = false
	_settings_panel.visible = false
	if _campaigns_panel:
		_campaigns_panel.visible = true
	if _scenarios_panel:
		_scenarios_panel.visible = false


func _show_scenarios() -> void:
	# Scenarios likewise gets the full-screen treatment so the cards
	# can be read at a comfortable size.
	_root_vbox.visible = false
	_main_buttons.visible = false
	_setup_panel.visible = false
	_settings_panel.visible = false
	if _campaigns_panel:
		_campaigns_panel.visible = false
	if _scenarios_panel:
		_scenarios_panel.visible = true


## --- Toggle / dropdown handlers ---

func _on_mode_toggle(value: int) -> void:
	_selected_mode = value
	_apply_mode_toggle_state()
	_rebuild_ai_rows()


func _apply_mode_toggle_state() -> void:
	# Mode buttons added in this order: ONE_V_ONE, TWO_V_TWO.
	if _mode_buttons.size() < 2:
		return
	_mode_buttons[0].button_pressed = (_selected_mode == MatchSettingsClass.Mode.ONE_V_ONE)
	_mode_buttons[1].button_pressed = (_selected_mode == MatchSettingsClass.Mode.TWO_V_TWO)


func _on_map_dropdown_selected(idx: int) -> void:
	if not _map_dropdown:
		return
	_selected_map = _map_dropdown.get_item_id(idx)
	_apply_map_dropdown_state()


func _apply_map_dropdown_state() -> void:
	if _map_dropdown:
		var dropdown_idx: int = _map_dropdown.get_item_index(_selected_map)
		if dropdown_idx >= 0:
			_map_dropdown.selected = dropdown_idx
	if _map_preview:
		_map_preview.map_id = _selected_map
	if _map_info_label:
		var info: Dictionary = _MAP_INFO.get(_selected_map, {}) as Dictionary
		_map_info_label.text = info.get("blurb", "") as String


## --- Button handlers ---

func _on_play_pressed() -> void:
	MatchSettings.tutorial_mode = false
	# Reset any scenario flag a previous Special Ops launch may have
	# set so the standard Play path always lands in a vanilla skirmish.
	MatchSettings.scenario = MatchSettingsClass.Scenario.NONE
	_show_setup()


func _on_tutorial_pressed() -> void:
	MatchSettings.tutorial_mode = true
	MatchSettings.scenario = MatchSettingsClass.Scenario.NONE
	# Tutorial: Anvil player, Sable enclave as the southern (uh,
	# northern — +Z) target. enemy_faction flips to SABLE so the
	# enclave's HQ + emplacements + SAM build with the Sable
	# faceted-hull silhouette + violet accents instead of looking
	# like Anvil structures the player has to attack.
	MatchSettings.difficulty = MatchSettingsClass.Difficulty.EASY
	MatchSettings.mode = MatchSettingsClass.Mode.ONE_V_ONE
	MatchSettings.map_id = MatchSettingsClass.MapId.FOUNDRY_BELT
	MatchSettings.player_faction = MatchSettingsClass.FactionId.ANVIL
	MatchSettings.enemy_faction = MatchSettingsClass.FactionId.SABLE
	MatchSettings.ai_personalities = {}
	MatchSettings.ai_difficulties = {}
	MatchSettings.ai_factions = {}
	_start_match()


func _on_settings_pressed() -> void:
	_show_settings()


func _on_campaigns_pressed() -> void:
	# Animated screen-change feel -- the radar fades + slides off,
	# the command-center flashes briefly, and the Europe map slides
	# in from the right. Mimics the operator panning to a different
	# screen on the wall.
	_transition_to_campaigns()


func _transition_to_campaigns() -> void:
	## Cross-fade + slide transition into the Campaigns full-screen
	## page. Phase 1 (~0.32s): radar + main UI fade out and slide
	## left while a soft phosphor flash fires at the midpoint. Phase
	## 2 (~0.32s): _campaigns_panel slides in from the right and
	## fades up to full opacity.
	# Phase 1 -- pull the current view away.
	if _tactical_bg:
		var t1: Tween = create_tween()
		t1.set_parallel(true)
		t1.tween_property(_tactical_bg, "modulate:a", 0.35, 0.32)
		t1.tween_property(_tactical_bg, "position:x", -120.0, 0.32)
	if _root_vbox:
		var t2: Tween = create_tween()
		t2.set_parallel(true)
		t2.tween_property(_root_vbox, "modulate:a", 0.0, 0.30)
		t2.tween_property(_root_vbox, "position:x", _root_vbox.position.x - 80.0, 0.30)
	# Mid-transition phosphor flash -- short bright blip then fade.
	if _transition_flash:
		var tf: Tween = create_tween()
		tf.tween_property(_transition_flash, "color:a", 0.30, 0.18)
		tf.tween_property(_transition_flash, "color:a", 0.0, 0.30)
	# Phase 2 -- show campaigns AFTER the fade-out lands. Reset the
	# tactical bg / root_vbox state so the next time we come back
	# they slide in cleanly.
	get_tree().create_timer(0.34).timeout.connect(_finish_show_campaigns, CONNECT_ONE_SHOT)


func _finish_show_campaigns() -> void:
	# Hide the previous layer; show the campaigns panel pre-positioned
	# off-screen-right then slide it in.
	_root_vbox.visible = false
	if _campaigns_panel:
		_campaigns_panel.visible = true
		_campaigns_panel.modulate.a = 0.0
		_campaigns_panel.position.x = 90.0
		var t3: Tween = create_tween()
		t3.set_parallel(true)
		t3.tween_property(_campaigns_panel, "modulate:a", 1.0, 0.32)
		t3.tween_property(_campaigns_panel, "position:x", 0.0, 0.32)


func _restore_main_view_after_campaigns() -> void:
	## Reverse of _transition_to_campaigns -- called when the player
	## hits Back from the campaigns / scenarios pages. Slides the
	## radar + main menu back in.
	if _tactical_bg:
		var t1: Tween = create_tween()
		t1.set_parallel(true)
		t1.tween_property(_tactical_bg, "modulate:a", 1.0, 0.32)
		t1.tween_property(_tactical_bg, "position:x", 0.0, 0.32)
	if _root_vbox:
		_root_vbox.visible = true
		_root_vbox.modulate.a = 0.0
		var t2: Tween = create_tween()
		t2.set_parallel(true)
		t2.tween_property(_root_vbox, "modulate:a", 1.0, 0.32)
		t2.tween_property(_root_vbox, "position:x", 0.0, 0.32)
	if _transition_flash:
		var tf: Tween = create_tween()
		tf.tween_property(_transition_flash, "color:a", 0.20, 0.16)
		tf.tween_property(_transition_flash, "color:a", 0.0, 0.30)


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_start_match_pressed() -> void:
	# Commit setup-screen state to MatchSettings.
	MatchSettings.mode = _selected_mode as MatchSettingsClass.Mode
	MatchSettings.map_id = _selected_map as MatchSettingsClass.MapId
	MatchSettings.player_faction = _selected_faction as MatchSettingsClass.FactionId
	# Enemy AI defaults to the OPPOSITE faction so picking Sable triggers
	# an asymmetric Anvil-vs-Sable match. (Per-AI faction overrides
	# could be added to the dropdown rows in the future.)
	if _selected_faction == MatchSettingsClass.FactionId.ANVIL:
		MatchSettings.enemy_faction = MatchSettingsClass.FactionId.SABLE
	else:
		MatchSettings.enemy_faction = MatchSettingsClass.FactionId.ANVIL
	# Read each AI's per-row dropdown selection.
	var diffs: Dictionary = {}
	var pers: Dictionary = {}
	var facs: Dictionary = {}
	for player_id_v: Variant in _ai_difficulty_dropdowns.keys():
		var pid: int = player_id_v as int
		var dropdown: OptionButton = _ai_difficulty_dropdowns[pid] as OptionButton
		if dropdown:
			diffs[pid] = dropdown.get_selected_id()
	for player_id_v: Variant in _ai_personality_dropdowns.keys():
		var pid: int = player_id_v as int
		var dropdown: OptionButton = _ai_personality_dropdowns[pid] as OptionButton
		if dropdown:
			pers[pid] = dropdown.get_selected_id()
	for player_id_v: Variant in _ai_faction_dropdowns.keys():
		var pid: int = player_id_v as int
		var dropdown: OptionButton = _ai_faction_dropdowns[pid] as OptionButton
		if dropdown:
			facs[pid] = dropdown.get_selected_id()
	MatchSettings.ai_difficulties = diffs
	MatchSettings.ai_personalities = pers
	MatchSettings.ai_factions = facs
	# Legacy `difficulty` field used for any AI without a per-slot
	# override — set to whichever difficulty appears most often in
	# the per-AI selections (defaults to Normal).
	MatchSettings.difficulty = _modal_difficulty(diffs)
	_start_match()


func _modal_difficulty(diffs: Dictionary) -> int:
	## Pick the most frequent difficulty in the per-AI dropdowns as
	## the legacy global `difficulty` value (used by code that hasn't
	## migrated to per-AI yet).
	if diffs.is_empty():
		return MatchSettingsClass.Difficulty.NORMAL
	var counts: Dictionary = {}
	for v: Variant in diffs.values():
		counts[v] = (counts.get(v, 0) as int) + 1
	var best: int = MatchSettingsClass.Difficulty.NORMAL
	var best_count: int = 0
	for k: Variant in counts.keys():
		var c: int = counts[k] as int
		if c > best_count:
			best_count = c
			best = k as int
	return best


func _on_bus_volume_changed(db: float, bus_name: String) -> void:
	## Slider position drives both the bus volume and the bus mute
	## flag. The slider's minimum (-40 dB) was nominally "muted" but
	## still passed audio at ~1%; calling set_bus_mute when the
	## slider sits at its minimum guarantees full silence so a player
	## who drags Music to 0 actually gets no music. Any position
	## above the minimum re-enables audio at the requested level.
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	if db <= -40.0:
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, db)


func _start_match() -> void:
	## Route through the loading screen so the player gets the
	## map-zoom briefing animation between menu and arena. The
	## loading screen handles change_scene_to_file(ARENA_SCENE)
	## itself once the zoom finishes.
	get_tree().change_scene_to_file("res://scenes/loading_screen.tscn")


const _FACTION_ROSTER: Dictionary = {
	# Per-faction roster keyed by the slot the in-match tech tree
	# fills — keys map to the chain rows in _show_faction_tech_tree.
	# light_a/light_b are the two baseline Foundry units, heavy_base
	# is the Adv-Foundry baseline, heavy_adv is the Adv-Armory-gated
	# heavy slot, air_base is the Aerodrome baseline, air_adv is the
	# Adv-Armory-gated air slot, transport_adv is Sable's third Adv-
	# Foundry unit (Courier Tank), pylon_air is the Black-Pylon-gated
	# Wraith. Anvil leaves slots it doesn't fill empty.
	0: {
		"label": "Anvil Directive",
		"engineer":      "res://resources/units/anvil_ratchet.tres",
		"crawler":       "res://resources/units/anvil_crawler.tres",
		"light_a":       "res://resources/units/anvil_rook.tres",
		"light_b":       "res://resources/units/anvil_hound.tres",
		"heavy_base":    "res://resources/units/anvil_bulwark.tres",
		"heavy_adv":     "res://resources/units/anvil_forgemaster.tres",
		"air_base":      "res://resources/units/anvil_phalanx.tres",
		"air_adv":       "res://resources/units/anvil_hammerhead.tres",
	},
	1: {
		"label": "Sable Concord",
		"engineer":      "res://resources/units/sable_rigger.tres",
		"crawler":       "res://resources/units/anvil_crawler.tres",  # shared chassis
		"light_a":       "res://resources/units/sable_specter.tres",
		"light_b":       "res://resources/units/sable_jackal.tres",
		"heavy_base":    "res://resources/units/sable_harbinger.tres",
		"heavy_adv":     "res://resources/units/sable_pulsefont.tres",
		"transport_adv": "res://resources/units/sable_courier_tank.tres",
		"air_base":      "res://resources/units/sable_switchblade.tres",
		"air_adv":       "res://resources/units/sable_fang.tres",
		"pylon_air":     "res://resources/units/sable_wraith.tres",
	},
}


func _show_faction_tech_tree(faction_id: int) -> void:
	## Modal overlay — lists the chosen faction's full unit roster
	## with role hints, costs, and the building prerequisite chain
	## the player needs to follow to unlock each unit. Lets the
	## player evaluate the faction before committing to play it.
	var roster: Dictionary = _FACTION_ROSTER.get(faction_id, {}) as Dictionary
	if roster.is_empty():
		return

	var canvas := CanvasLayer.new()
	canvas.layer = 200
	add_child(canvas)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.78)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)

	# Faction palette -- Anvil = warm industrial (brass / orange),
	# Sable = cool corpo (cyan / violet). Drives the card border,
	# title hue, and unit-chip accents so the tech-tree modal reads
	# as belonging to the chosen faction.
	var palette: Dictionary = _faction_palette(faction_id)

	# Tooltip theme override applied below to the card PanelContainer
	# (CanvasLayer extends Node, not Control, so it doesn't have a
	# `theme` property -- assignment crashes). PanelContainer is the
	# nearest Control ancestor that wraps every interactive child.
	var tooltip_theme: Theme = _make_tech_tree_tooltip_theme(palette)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(1100, 640)
	card.theme = tooltip_theme
	# Faction-tinted card frame.
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = palette["card_bg"] as Color
	card_style.border_color = palette["card_border"] as Color
	card_style.border_width_top = 2
	card_style.border_width_bottom = 2
	card_style.border_width_left = 2
	card_style.border_width_right = 2
	card_style.corner_radius_top_left = 6
	card_style.corner_radius_top_right = 6
	card_style.corner_radius_bottom_left = 6
	card_style.corner_radius_bottom_right = 6
	card_style.content_margin_left = 16
	card_style.content_margin_right = 16
	card_style.content_margin_top = 14
	card_style.content_margin_bottom = 14
	card.add_theme_stylebox_override("panel", card_style)
	center.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	var title := Label.new()
	title.text = "%s — Tech Tree" % (roster["label"] as String)
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", palette["title"] as Color)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Faction summary — civ-bonus-style overview, sits above the
	# graph so the player gets the doctrine pitch before scanning.
	var summary_lbl := Label.new()
	summary_lbl.text = _faction_summary(faction_id)
	summary_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary_lbl.custom_minimum_size = Vector2(1060, 0)
	summary_lbl.add_theme_font_size_override("font_size", 13)
	summary_lbl.add_theme_color_override("font_color", Color(0.78, 0.85, 0.95, 1.0))
	vbox.add_child(summary_lbl)

	# Layered tech-tree graph -- columns by build-tier (depth from
	# HQ in the prereq chain), arrows drawn as a Control overlay
	# between connected building cards.
	var graph_scroll := ScrollContainer.new()
	graph_scroll.custom_minimum_size = Vector2(1060, 480)
	graph_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(graph_scroll)
	graph_scroll.add_child(_build_tech_tree_graph(faction_id, roster, palette))

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(160, 36)
	close_btn.pressed.connect(canvas.queue_free)
	vbox.add_child(close_btn)


## Tech-tree building list (faction-agnostic). Each entry has:
##   id          building_id (StringName)
##   name        display name
##   cost        cost string ("190 S" or "200 S / 90 F")
##   prereqs     Array[StringName] of building_ids this depends on
##   roles       Array[String] of roster keys this building unlocks
##                 (matches _FACTION_ROSTER keys -- empty if the
##                  building is purely economic / utility / defensive)
##   sable_only  bool -- skip on Anvil
##   anvil_only  bool -- skip on Sable
const _TECH_GRAPH_NODES: Array[Dictionary] = [
	{"id": &"headquarters",        "name": "Headquarters",      "cost": "(start)",       "prereqs": [],                "roles": ["engineer", "crawler"]},
	{"id": &"basic_foundry",       "name": "Basic Foundry",     "cost": "190 S",         "prereqs": [&"headquarters"], "roles": ["light_a", "light_b"]},
	{"id": &"salvage_yard",        "name": "Salvage Yard",      "cost": "75 S",          "prereqs": [&"headquarters"], "roles": []},
	{"id": &"basic_generator",     "name": "Generator",         "cost": "180 S",         "prereqs": [&"headquarters"], "roles": []},
	{"id": &"advanced_foundry",    "name": "Adv. Foundry",      "cost": "265 S",         "prereqs": [&"basic_foundry"],"roles": ["heavy_base"]},
	{"id": &"basic_armory",        "name": "Basic Armory",      "cost": "150 S / 65 F",  "prereqs": [&"basic_foundry"],"roles": []},
	{"id": &"aerodrome",           "name": "Aerodrome",         "cost": "160 S / 65 F",  "prereqs": [&"advanced_foundry"], "roles": ["air_base"]},
	{"id": &"advanced_armory",     "name": "Adv. Armory",       "cost": "200 S / 90 F",  "prereqs": [&"basic_armory"], "roles": ["heavy_adv", "transport_adv", "air_adv"]},
	{"id": &"sam_site",            "name": "SAM Site",          "cost": "125 S / 55 F",  "prereqs": [&"basic_armory"], "roles": []},
	{"id": &"gun_emplacement",     "name": "Gun Emplacement",   "cost": "150 S",         "prereqs": [],                "roles": [], "anvil_only": true},
	{"id": &"gun_emplacement_basic","name": "Gun Emplacement",  "cost": "150 S",         "prereqs": [],                "roles": [], "sable_only": true},
	{"id": &"black_pylon",         "name": "Black Pylon",       "cost": "200 S / 90 F",  "prereqs": [&"basic_armory"], "roles": ["pylon_air"], "sable_only": true},
]


func _make_tech_tree_tooltip_theme(palette: Dictionary) -> Theme:
	## Theme override making the engine tooltip popup readable
	## over the modal's dark card. Default tooltip is ~50% alpha
	## which disappears against the dark bg.
	var theme := Theme.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.05, 0.05, 0.07, 0.96)
	box.border_color = (palette.get("node_border", Color(0.55, 0.62, 0.78, 0.95))) as Color
	box.border_width_top = 1
	box.border_width_bottom = 1
	box.border_width_left = 1
	box.border_width_right = 1
	box.corner_radius_top_left = 4
	box.corner_radius_top_right = 4
	box.corner_radius_bottom_left = 4
	box.corner_radius_bottom_right = 4
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	theme.set_stylebox("panel", "TooltipPanel", box)
	theme.set_color("font_color", "TooltipLabel", Color(0.95, 0.95, 0.95, 1.0))
	theme.set_color("font_shadow_color", "TooltipLabel", Color(0.0, 0.0, 0.0, 0.0))
	return theme


func _faction_palette(faction_id: int) -> Dictionary:
	## Per-faction colour kit for the tech-tree modal. Anvil =
	## warm industrial (brass title, tan border, dark-warm card bg).
	## Sable = cool corpo specops (violet/cyan title, dark cool card
	## bg). Falls back to Anvil for unknown ids.
	if faction_id == 1:
		return {
			"title":         Color(0.78, 0.45, 1.00, 1.0),  # SABLE_NEON
			"card_bg":       Color(0.06, 0.07, 0.10, 0.96),
			"card_border":   Color(0.78, 0.45, 1.00, 0.9),
			"node_bg":       Color(0.08, 0.09, 0.13, 0.96),
			"node_border":   Color(0.55, 0.78, 1.00, 0.85),
			"node_name":     Color(0.92, 0.92, 0.98, 1.0),
			"node_cost":     Color(0.78, 0.85, 0.95, 1.0),
			"unit_text":     Color(0.85, 0.85, 0.92, 1.0),
			"arrow":         Color(0.78, 0.55, 1.00, 0.85),
			"arrow_head":    Color(0.92, 0.78, 1.00, 0.95),
		}
	# Anvil default.
	return {
		"title":         Color(0.95, 0.78, 0.32, 1.0),  # warm brass
		"card_bg":       Color(0.10, 0.08, 0.06, 0.96),
		"card_border":   Color(0.85, 0.55, 0.20, 0.85),
		"node_bg":       Color(0.13, 0.10, 0.08, 0.96),
		"node_border":   Color(0.78, 0.55, 0.20, 0.85),
		"node_name":     Color(0.95, 0.92, 0.78, 1.0),
		"node_cost":     Color(0.95, 0.85, 0.55, 1.0),
		"unit_text":     Color(0.92, 0.88, 0.78, 1.0),
		"arrow":         Color(0.95, 0.65, 0.20, 0.85),
		"arrow_head":    Color(1.00, 0.85, 0.40, 0.95),
	}


func _build_tech_tree_graph(faction_id: int, roster: Dictionary, palette: Dictionary = {}) -> Control:
	## Returns a Control containing per-tier building cards laid out
	## in columns + an arrow overlay drawing prereq links. The whole
	## thing sits inside a ScrollContainer so wide trees scroll
	## horizontally rather than getting clipped.

	# Filter graph nodes by faction.
	var nodes: Array[Dictionary] = []
	for n: Dictionary in _TECH_GRAPH_NODES:
		var anvil_only: bool = n.get("anvil_only", false) as bool
		var sable_only: bool = n.get("sable_only", false) as bool
		if anvil_only and faction_id != 0:
			continue
		if sable_only and faction_id != 1:
			continue
		nodes.append(n)

	# Compute tier (depth) per node from prereqs. HQ = 0.
	var tier_of: Dictionary = {}  # building_id -> tier int
	# Iterate to fixed point (small graph; 10 iterations is plenty).
	for _pass: int in 8:
		for n: Dictionary in nodes:
			var prereqs: Array = n.get("prereqs", []) as Array
			if prereqs.is_empty():
				tier_of[n["id"]] = 0
				continue
			var max_pre_tier: int = -1
			var all_known: bool = true
			for pid_v: Variant in prereqs:
				var pid: StringName = pid_v
				if not tier_of.has(pid):
					all_known = false
					break
				max_pre_tier = maxi(max_pre_tier, tier_of[pid] as int)
			if all_known:
				tier_of[n["id"]] = max_pre_tier + 1

	# Bucket nodes by tier.
	var by_tier: Dictionary = {}
	var max_tier: int = 0
	for n: Dictionary in nodes:
		var t: int = tier_of.get(n["id"], 0) as int
		max_tier = maxi(max_tier, t)
		if not by_tier.has(t):
			by_tier[t] = []
		(by_tier[t] as Array).append(n)

	# Layout constants. Card width fixed; column spacing leaves room
	# for the arrow overlay between cards.
	var col_w: int = 220
	var col_gap: int = 50
	var row_h: int = 150
	var row_gap: int = 16
	var pad: int = 16

	# Compute total area.
	var max_per_col: int = 0
	for t_v: Variant in by_tier:
		max_per_col = maxi(max_per_col, (by_tier[t_v] as Array).size())
	var total_w: int = pad * 2 + (max_tier + 1) * col_w + max_tier * col_gap
	var total_h: int = pad * 2 + max_per_col * (row_h + row_gap)

	# Root container -- a Control we size manually so the arrow
	# overlay can use the same coordinate space.
	var root := Control.new()
	root.custom_minimum_size = Vector2(total_w, total_h)
	root.size = Vector2(total_w, total_h)

	# Arrow overlay drawn first so cards render on top.
	var arrows := _TechTreeArrowOverlay.new()
	arrows.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arrows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrows.card_rects = {}  # building_id -> Rect2 (filled below)
	arrows.edges = []       # array of [from_id, to_id]
	if palette.has("arrow"):
		arrows.line_color = palette["arrow"] as Color
	if palette.has("arrow_head"):
		arrows.head_color = palette["arrow_head"] as Color
	root.add_child(arrows)

	# Place each tier's cards.
	for t_int: int in range(max_tier + 1):
		var col_x: int = pad + t_int * (col_w + col_gap)
		var col_nodes: Array = by_tier.get(t_int, []) as Array
		for j: int in col_nodes.size():
			var n_data: Dictionary = col_nodes[j] as Dictionary
			var card_pos: Vector2 = Vector2(col_x, pad + j * (row_h + row_gap))
			var card_rect: Rect2 = Rect2(card_pos, Vector2(col_w, row_h))
			arrows.card_rects[n_data["id"]] = card_rect
			var card_panel: Control = _build_tech_tree_card(n_data, roster, palette)
			card_panel.position = card_pos
			card_panel.size = card_rect.size
			root.add_child(card_panel)
			# Edges from each prereq to this node.
			for pid_v: Variant in (n_data.get("prereqs", []) as Array):
				var pid: StringName = pid_v
				arrows.edges.append([pid, n_data["id"]])
	# Force overlay to sit above the same coordinate space as the
	# cards (size matches root).
	arrows.custom_minimum_size = root.custom_minimum_size
	arrows.size = root.size
	arrows.queue_redraw()
	return root


func _build_tech_tree_card(n: Dictionary, roster: Dictionary, palette: Dictionary = {}) -> PanelContainer:
	## Single building card -- name, cost, and a list of unit chips
	## for the units this gate unlocks. Compact enough to fit a
	## 220x150 cell. Honors the faction palette for bg / border so
	## cards visually match the modal's faction theme.
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = (palette.get("node_bg", Color(0.10, 0.12, 0.16, 0.95))) as Color
	style.border_color = (palette.get("node_border", Color(0.55, 0.62, 0.78, 0.85))) as Color
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	panel.add_child(col)

	var name_lbl := Label.new()
	name_lbl.text = n["name"] as String
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.add_theme_color_override("font_color", (palette.get("node_name", Color(0.92, 0.92, 0.78, 1.0))) as Color)
	col.add_child(name_lbl)

	var cost_lbl := Label.new()
	cost_lbl.text = n["cost"] as String
	cost_lbl.add_theme_font_size_override("font_size", 11)
	cost_lbl.add_theme_color_override("font_color", (palette.get("node_cost", Color(0.78, 0.85, 0.95, 1.0))) as Color)
	col.add_child(cost_lbl)

	var sep := HSeparator.new()
	col.add_child(sep)

	var roles: Array = n.get("roles", []) as Array
	if roles.is_empty():
		var note := Label.new()
		note.text = "(no units)"
		note.add_theme_font_size_override("font_size", 11)
		note.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7, 1.0))
		col.add_child(note)
	else:
		for role_v: Variant in roles:
			var role: String = role_v as String
			var path: String = roster.get(role, "") as String
			if path.is_empty():
				continue
			var unit_stat: UnitStatResource = load(path) as UnitStatResource
			if not unit_stat:
				continue
			# Use a Label-shaped tooltip-aware container. Plain Label
			# in Godot doesn't surface mouse_filter properly for
			# tooltip dispatch, so wrap in a Button styled flat to
			# get hover behaviour without the click affordance.
			var u_btn := Button.new()
			u_btn.text = "• %s  (%dS%s)" % [
				unit_stat.unit_name,
				unit_stat.cost_salvage,
				"" if unit_stat.cost_fuel == 0 else " / %dF" % unit_stat.cost_fuel,
			]
			u_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			u_btn.flat = true
			u_btn.focus_mode = Control.FOCUS_NONE
			u_btn.add_theme_font_size_override("font_size", 12)
			u_btn.add_theme_color_override("font_color", (palette.get("unit_text", Color(0.85, 0.85, 0.85, 1.0))) as Color)
			u_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.78, 1.0))
			u_btn.tooltip_text = _tech_tree_unit_tooltip(unit_stat)
			col.add_child(u_btn)

	return panel


class _TechTreeArrowOverlay extends Control:
	## Custom-drawn arrows between tech-tree cards. Reads card_rects
	## (filled by the parent _build_tech_tree_graph) and edges as
	## [from_id, to_id] pairs. Routes lines from the right edge of
	## the source card to the left edge of the target card with a
	## small horizontal-then-vertical-then-horizontal stagger so
	## multi-prereq fans don't collapse onto each other.
	var card_rects: Dictionary = {}
	var edges: Array = []
	var line_color: Color = Color(0.55, 0.78, 1.0, 0.85)
	var head_color: Color = Color(0.78, 0.92, 1.0, 0.95)

	func _draw() -> void:
		var color: Color = line_color
		var arrow_color: Color = head_color
		for edge_v: Variant in edges:
			var edge: Array = edge_v as Array
			if edge.size() < 2:
				continue
			var from_rect: Rect2 = card_rects.get(edge[0], Rect2()) as Rect2
			var to_rect: Rect2 = card_rects.get(edge[1], Rect2()) as Rect2
			if from_rect.size == Vector2.ZERO or to_rect.size == Vector2.ZERO:
				continue
			var from_pt: Vector2 = Vector2(from_rect.position.x + from_rect.size.x, from_rect.position.y + from_rect.size.y * 0.5)
			var to_pt: Vector2 = Vector2(to_rect.position.x, to_rect.position.y + to_rect.size.y * 0.5)
			var mid_x: float = (from_pt.x + to_pt.x) * 0.5
			# Three-segment route: horiz out of source, vert to
			# target row, horiz into target. Reads as a clean
			# orthogonal arrow.
			draw_line(from_pt, Vector2(mid_x, from_pt.y), color, 2.0, true)
			draw_line(Vector2(mid_x, from_pt.y), Vector2(mid_x, to_pt.y), color, 2.0, true)
			draw_line(Vector2(mid_x, to_pt.y), to_pt, color, 2.0, true)
			# Arrowhead at the target end.
			var head_size: float = 6.0
			var head_a: Vector2 = to_pt + Vector2(-head_size, -head_size * 0.6)
			var head_b: Vector2 = to_pt + Vector2(-head_size, head_size * 0.6)
			draw_polygon(PackedVector2Array([to_pt, head_a, head_b]), PackedColorArray([arrow_color]))


func _tech_tree_unit_tooltip(stat: UnitStatResource) -> String:
	## Compact info readout for hovering a unit chip in the tech-tree
	## modal. Plain text only -- Godot's tooltip_text rendering doesn't
	## interpret BBCode, so star bars / colored chips would show as
	## literal tags. Keeps the lines short so the tooltip popup
	## doesn't grow off-screen on small panels.
	if not stat:
		return ""
	var lines: PackedStringArray = PackedStringArray()
	lines.append("%s — %s" % [stat.unit_name, str(stat.unit_class).capitalize()])
	lines.append("HP %d   Squad %d   Pop %d" % [stat.hp_total, stat.squad_size, stat.population])
	lines.append("Cost  %dS / %dF   Build %.1fs" % [stat.cost_salvage, stat.cost_fuel, stat.build_time])
	lines.append("Armor %s   Speed %.0f u/s   Sight %.0fu" % [
		str(stat.armor_class).capitalize(),
		stat.resolved_speed(),
		stat.resolved_sight_radius(),
	])
	if stat.primary_weapon:
		var pw: WeaponResource = stat.primary_weapon
		lines.append("Primary: %s — %s, %d dmg, %.0fu, %.2fs cd" % [
			pw.weapon_name if pw.weapon_name else "Cannon",
			str(pw.role_tag),
			pw.resolved_damage(),
			pw.resolved_range(),
			pw.resolved_rof_seconds(),
		])
	if stat.secondary_weapon:
		var sw: WeaponResource = stat.secondary_weapon
		lines.append("Secondary: %s — %s, %d dmg" % [
			sw.weapon_name if sw.weapon_name else "Backup",
			str(sw.role_tag),
			sw.resolved_damage(),
		])
	if stat.special_description != "":
		lines.append("")
		lines.append(stat.special_description)
	return "\n".join(lines)


func _faction_summary(faction_id: int) -> String:
	## AoE-style civ-bonus blurb. Lists the tangible mechanical
	## differentiators a player would care about when picking a
	## faction: doctrine emphasis, where the faction is stronger /
	## weaker, and the unique structures or units it has access to.
	## Keep these honest -- they should read like a "what am I
	## actually getting" summary, not flavor copy.
	if faction_id == 0:
		return ("ANVIL DIRECTIVE — Industrial doctrine. Tougher static "
			+ "defenses (specialised Gun Emplacement: +15% HP, +15% "
			+ "damage, switchable Balanced / Anti-Light / Anti-Heavy "
			+ "profiles vs the baseline ground turret). Standard "
			+ "production tempo, mid-tier mobility. Heavy ground "
			+ "lineup (Bulwark + Forgemaster) leans on sustain and "
			+ "slow advance; air tier (Phalanx + Hammerhead) is "
			+ "gunship-doctrine — punchy, expensive, slower. Best "
			+ "when you want to anchor a position and grind forward.")
	elif faction_id == 1:
		return ("SABLE CONCORD — Shadow-ops doctrine. Standard ground "
			+ "turret (no profile swap, ground only -- pair with a SAM "
			+ "Site for air). Larger overall unit roster, including "
			+ "the Courier Tank transport and the Pulsefont caster, "
			+ "and faster / lighter aircraft (Switchblade + Fang "
			+ "drone swarm). Unique structure: Black Pylon (Mesh "
			+ "anchor + unlocks the Wraith stealth bomber). Best "
			+ "when you want flexibility, vision, and an answer for "
			+ "every threat type rather than a single hard-anchored "
			+ "front.")
	return ""


func _build_tactical_background() -> Control:
	## A non-interactive Control that paints a slow tactical-overview
	## scene behind the menu UI: a faint scan grid, soft contour
	## blobs, scattered unit pips, and a sweeping radar arc that
	## rotates over time. Built procedurally with Control._draw so it
	## doesn't depend on any imported assets.
	var script: GDScript = load("res://scripts/tactical_background.gd") as GDScript
	var bg := Control.new()
	bg.name = "TacticalBackground"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if script:
		bg.set_script(script)
	return bg


## --- Campaigns + Special Operations ----------------------------------------

func _build_campaigns_panel() -> void:
	## Full-screen Campaigns page: the Europe map fills the centre,
	## a heading sits at the top, and a Back button anchors the
	## bottom-left. Anchored as a top-level child of `self` so it
	## can take the full viewport rather than getting squeezed inside
	## the main menu's centered VBox.
	_campaigns_panel = VBoxContainer.new()
	_campaigns_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_campaigns_panel.add_theme_constant_override("separation", 12)
	_campaigns_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_campaigns_panel.visible = false
	# Slight inner margin so the map doesn't touch the screen edges.
	_campaigns_panel.offset_left = 24
	_campaigns_panel.offset_right = -24
	_campaigns_panel.offset_top = 18
	_campaigns_panel.offset_bottom = -18
	add_child(_campaigns_panel)

	var heading := Label.new()
	heading.text = "Campaigns — European Theatre"
	heading.add_theme_font_size_override("font_size", 30)
	heading.add_theme_color_override("font_color", COLOR_SUBTITLE)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_campaigns_panel.add_child(heading)

	var hint := Label.new()
	hint.text = "Select a deployment site. CERN site offers Special Operations missions."
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", COLOR_HINT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_campaigns_panel.add_child(hint)

	# The map + buttons live in a Control wrapper so the stumps can be
	# positioned absolutely on top of the painted backdrop without the
	# parent VBox stretching them around. The wrapper takes the
	# vertical fill so the map sits in the middle of the page.
	var map_holder := CenterContainer.new()
	map_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_campaigns_panel.add_child(map_holder)

	var map_script: GDScript = preload("res://scripts/europe_map.gd")
	var map: Control = Control.new()
	map.set_script(map_script)
	map.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	map.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	map_holder.add_child(map)

	# Deferred stump placement -- the map's _ready (which sets its
	# custom_minimum_size) needs to fire before we ask for marker
	# coordinates. call_deferred lets us layer the buttons after the
	# control has its real size.
	map.call_deferred("_ready")
	_attach_campaign_stumps(map)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(180, 40)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(_back_from_campaigns)
	_campaigns_panel.add_child(back)


func _back_from_campaigns() -> void:
	## Slide the campaigns panel off-screen, then show + slide the
	## main menu back in. Mirrors _transition_to_campaigns.
	if _campaigns_panel:
		var t1: Tween = create_tween()
		t1.set_parallel(true)
		t1.tween_property(_campaigns_panel, "modulate:a", 0.0, 0.30)
		t1.tween_property(_campaigns_panel, "position:x", 90.0, 0.30)
	get_tree().create_timer(0.32).timeout.connect(_finish_back_from_campaigns, CONNECT_ONE_SHOT)


func _finish_back_from_campaigns() -> void:
	if _campaigns_panel:
		_campaigns_panel.visible = false
		_campaigns_panel.position.x = 0.0
	_restore_main_view_after_campaigns()


func _attach_campaign_stumps(map: Control) -> void:
	## Pin a stump button on top of the Europe map at each marker
	## site. Stumps are anchored to the map's local coordinates so the
	## label / button rides with the underlying paint regardless of
	## menu resizing.
	var stumps: Array[Dictionary] = [
		{ "key": "uk",      "label": "Western\nFront",  "enabled": false },
		{ "key": "germany", "label": "Northern\nFront", "enabled": false },
		{ "key": "russia",  "label": "Eastern\nFront",  "enabled": false },
		{ "key": "italy",   "label": "Southern\nFront", "enabled": false },
		{ "key": "cern",    "label": "Special\nOps",    "enabled": true  },
	]
	const STUMP_SIZE := Vector2(110, 56)
	for s: Dictionary in stumps:
		var btn := Button.new()
		btn.text = s["label"] as String
		btn.custom_minimum_size = STUMP_SIZE
		btn.size = STUMP_SIZE
		btn.disabled = not (s["enabled"] as bool)
		if s["enabled"] as bool:
			btn.pressed.connect(_show_scenarios)
			btn.tooltip_text = "Geneva (CERN) -- Special Operations Proving Grounds."
		else:
			btn.tooltip_text = "Campaign coming soon."
		map.add_child(btn)
		# Defer the actual position write until the map control has
		# resolved its layout size; otherwise get_marker_position
		# multiplies by a still-zero MAP_SIZE on the very first tick.
		var key: String = s["key"] as String
		_position_stump_deferred.call_deferred(map, btn, key, STUMP_SIZE)


func _position_stump_deferred(map: Control, btn: Button, key: String, stump_size: Vector2) -> void:
	if not is_instance_valid(map) or not is_instance_valid(btn):
		return
	var p: Vector2 = map.call("get_marker_position", key) as Vector2
	btn.position = p - stump_size * 0.5


func _build_scenarios_panel() -> void:
	## Three Special Operations scenario cards. Each card sets up
	## MatchSettings (faction, mode, scenario flag) and launches the
	## arena scene; TestArenaController reads MatchSettings.scenario
	## and seeds the match accordingly. Anchored full-rect like the
	## Campaigns panel so the cards have room to breathe.
	_scenarios_panel = VBoxContainer.new()
	_scenarios_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scenarios_panel.add_theme_constant_override("separation", 12)
	_scenarios_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_scenarios_panel.visible = false
	_scenarios_panel.offset_left = 24
	_scenarios_panel.offset_right = -24
	_scenarios_panel.offset_top = 30
	_scenarios_panel.offset_bottom = -18
	add_child(_scenarios_panel)

	var heading := Label.new()
	heading.text = "Special Operations"
	heading.add_theme_font_size_override("font_size", 24)
	heading.add_theme_color_override("font_color", COLOR_SUBTITLE)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scenarios_panel.add_child(heading)

	var subtitle := Label.new()
	subtitle.text = "CERN Black-Site Proving Grounds"
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", COLOR_HINT)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scenarios_panel.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	_scenarios_panel.add_child(spacer)

	var scenario_defs: Array[Dictionary] = [
		{
			"id": MatchSettingsClass.Scenario.SPECOPS_SABLE_PROVING,
			"title": "Sable Proving Ground",
			"blurb": "Play Sable. Established base + full economy.\nThree Anvil opponents with parity setups.\nTest Sable's full toolkit at scale.",
		},
		{
			"id": MatchSettingsClass.Scenario.SPECOPS_ANVIL_PROVING,
			"title": "Anvil Proving Ground",
			"blurb": "Play Anvil. Same parity setup, mirrored.\nThree Sable opponents, full economy on every side.\nTest the Directive's discipline.",
		},
		{
			"id": MatchSettingsClass.Scenario.SPECOPS_STRESS_TEST,
			"title": "Iron Curtain — Stress Test",
			"blurb": "250-pop army, decent base, AI ally vs 2 enemies.\nEveryone starts at full pop on a battlefield of\nscattered terrain. Test what the engine can hold.",
		},
	]
	for sdef: Dictionary in scenario_defs:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(420, 100)
		_scenarios_panel.add_child(card)
		var card_vbox := VBoxContainer.new()
		card_vbox.add_theme_constant_override("separation", 4)
		card.add_child(card_vbox)
		var t := Label.new()
		t.text = sdef["title"] as String
		t.add_theme_font_size_override("font_size", 18)
		t.add_theme_color_override("font_color", COLOR_TITLE)
		card_vbox.add_child(t)
		var b := Label.new()
		b.text = sdef["blurb"] as String
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9, 1.0))
		card_vbox.add_child(b)
		var launch := Button.new()
		launch.text = "Deploy"
		launch.custom_minimum_size = Vector2(140, 32)
		var sid: int = sdef["id"] as int
		launch.pressed.connect(_on_scenario_pressed.bind(sid))
		card_vbox.add_child(launch)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(160, 36)
	back.pressed.connect(_show_campaigns)
	_scenarios_panel.add_child(back)


func _on_scenario_pressed(scenario_id: int) -> void:
	## Configures MatchSettings for the picked scenario and starts the
	## arena. The arena controller reads MatchSettings.scenario and
	## post-processes its standard setup with the scenario's seeded
	## state (pre-built bases, full economy, scattered terrain, etc).
	MatchSettings.tutorial_mode = false
	MatchSettings.ai_personalities = {}
	MatchSettings.ai_difficulties = {}
	MatchSettings.ai_factions = {}
	MatchSettings.scenario = scenario_id as MatchSettingsClass.Scenario
	match scenario_id:
		MatchSettingsClass.Scenario.SPECOPS_SABLE_PROVING:
			MatchSettings.mode = MatchSettingsClass.Mode.TWO_V_TWO
			MatchSettings.player_faction = MatchSettingsClass.FactionId.SABLE
			MatchSettings.enemy_faction = MatchSettingsClass.FactionId.ANVIL
			MatchSettings.difficulty = MatchSettingsClass.Difficulty.HARD
			MatchSettings.map_id = MatchSettingsClass.MapId.FOUNDRY_BELT
		MatchSettingsClass.Scenario.SPECOPS_ANVIL_PROVING:
			MatchSettings.mode = MatchSettingsClass.Mode.TWO_V_TWO
			MatchSettings.player_faction = MatchSettingsClass.FactionId.ANVIL
			MatchSettings.enemy_faction = MatchSettingsClass.FactionId.SABLE
			MatchSettings.difficulty = MatchSettingsClass.Difficulty.HARD
			MatchSettings.map_id = MatchSettingsClass.MapId.FOUNDRY_BELT
		MatchSettingsClass.Scenario.SPECOPS_STRESS_TEST:
			MatchSettings.mode = MatchSettingsClass.Mode.TWO_V_TWO
			MatchSettings.player_faction = MatchSettingsClass.FactionId.ANVIL
			MatchSettings.enemy_faction = MatchSettingsClass.FactionId.SABLE
			MatchSettings.difficulty = MatchSettingsClass.Difficulty.HARD
			MatchSettings.map_id = MatchSettingsClass.MapId.IRON_GATE_CROSSING
	_start_match()
