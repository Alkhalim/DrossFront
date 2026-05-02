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

# Setup-screen state — populated by the radio buttons / faction picks.
var _selected_mode: int = MatchSettingsClass.Mode.ONE_V_ONE
var _selected_map: int = MatchSettingsClass.MapId.FOUNDRY_BELT
var _selected_faction: int = MatchSettingsClass.FactionId.ANVIL

# Setup-screen widgets so the mode toggle can rebuild the AI rows.
var _mode_buttons: Array[Button] = []
var _map_dropdown: OptionButton = null
var _map_preview: Control = null
var _map_info_label: Label = null
var _faction_buttons: Array[Button] = []
var _faction_icons: Array[Control] = []
var _ai_rows_container: VBoxContainer = null
var _ai_faction_dropdowns: Dictionary = {}    # player_id → OptionButton
var _ai_difficulty_dropdowns: Dictionary = {}  # player_id → OptionButton
var _ai_personality_dropdowns: Dictionary = {}  # player_id → OptionButton

const _MAP_INFO: Dictionary = {
	MatchSettingsClass.MapId.FOUNDRY_BELT: {
		"label": "Foundry Belt",
		"blurb": "Cluttered industrial map.\nMultiple chokepoints, dense salvage,\nApex wreck objective.",
	},
	MatchSettingsClass.MapId.ASHPLAINS_CROSSING: {
		"label": "Ashplains Crossing",
		"blurb": "Volcanic ash flats with one elevated ridge.\nLong sightlines, sparse cover,\nfavours ranged combat.",
	},
	MatchSettingsClass.MapId.IRON_GATE_CROSSING: {
		"label": "Iron Gate Crossing",
		"blurb": "Semi-controlled district between corp cores.\nDense ruin clusters favour stealth flanks,\ncentral corridor favours heavy push.",
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
	## Mini-theme matching the in-game HUD (dark steel + green/gold accents).
	var theme_res := Theme.new()
	theme_res.set_default_font_size(16)

	var btn_normal := StyleBoxFlat.new()
	btn_normal.bg_color = Color(0.16, 0.18, 0.20, 1.0)
	btn_normal.border_color = Color(0.4, 0.42, 0.46, 1.0)
	btn_normal.set_border_width_all(1)
	btn_normal.corner_radius_top_left = 4
	btn_normal.corner_radius_top_right = 4
	btn_normal.corner_radius_bottom_left = 4
	btn_normal.corner_radius_bottom_right = 4
	btn_normal.content_margin_left = 12
	btn_normal.content_margin_right = 12
	btn_normal.content_margin_top = 8
	btn_normal.content_margin_bottom = 8

	var btn_hover := btn_normal.duplicate() as StyleBoxFlat
	btn_hover.bg_color = Color(0.24, 0.28, 0.32, 1.0)
	btn_hover.border_color = Color(0.7, 0.85, 0.95, 1.0)

	var btn_pressed := btn_normal.duplicate() as StyleBoxFlat
	# Same "physical press" treatment as the in-game HUD buttons —
	# darker fill, brighter accent border, content nudged 1px down,
	# and a soft drop shadow so the click reads as a real push.
	btn_pressed.bg_color = Color(0.08, 0.10, 0.12, 1.0)
	btn_pressed.border_color = Color(1.0, 0.82, 0.35, 1.0)
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
	theme_res.set_color("font_color", "Button", Color(0.95, 0.95, 0.95, 1.0))

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


func _build_main_buttons() -> void:
	_main_buttons = VBoxContainer.new()
	_main_buttons.add_theme_constant_override("separation", 10)
	_main_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_root_vbox.add_child(_main_buttons)

	for entry: Dictionary in [
		{ "label": "Play",     "callback": Callable(self, "_on_play_pressed") },
		{ "label": "Tutorial", "callback": Callable(self, "_on_tutorial_pressed") },
		{ "label": "Settings", "callback": Callable(self, "_on_settings_pressed") },
		{ "label": "Quit",     "callback": Callable(self, "_on_quit_pressed") },
	]:
		var btn := Button.new()
		btn.text = entry["label"] as String
		btn.custom_minimum_size = Vector2(280, 44)
		btn.pressed.connect(entry["callback"] as Callable)
		_main_buttons.add_child(btn)


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


func _build_faction_section(parent: Container) -> void:
	var heading := Label.new()
	heading.text = "Your Faction:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	parent.add_child(heading)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	parent.add_child(hbox)

	for entry: Dictionary in [
		{ "value": MatchSettingsClass.FactionId.ANVIL,
		  "icon_id": FactionIconScript.Faction.ANVIL,
		  "label": "Anvil Directive",
		  "blurb": "Heavy industrial. Slow, armored." },
		{ "value": MatchSettingsClass.FactionId.SABLE,
		  "icon_id": FactionIconScript.Faction.SABLE,
		  "label": "Sable Concord",
		  "blurb": "Information warfare. Fast, fragile." },
	]:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 4)
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		hbox.add_child(col)

		var icon: Control = FactionIconScript.new()
		icon.faction = entry["icon_id"]
		icon.custom_minimum_size = Vector2(72, 72)
		icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_faction_icons.append(icon)
		col.add_child(icon)

		var btn := Button.new()
		btn.text = "%s\n%s" % [entry["label"], entry["blurb"]]
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(220, 50)
		btn.pressed.connect(_on_faction_toggle.bind(entry["value"] as int))
		_faction_buttons.append(btn)
		col.add_child(btn)

		# Tech-tree button under each faction — opens a modal listing
		# the faction's full unit roster + production prerequisites.
		# Lets the player vet a faction before committing to play it.
		var tech_btn := Button.new()
		tech_btn.text = "View Tech Tree"
		tech_btn.custom_minimum_size = Vector2(220, 28)
		tech_btn.pressed.connect(_show_faction_tech_tree.bind(entry["value"] as int))
		col.add_child(tech_btn)
	_apply_faction_toggle_state()


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
	_main_buttons.visible = true
	_setup_panel.visible = false
	_settings_panel.visible = false


func _show_setup() -> void:
	_main_buttons.visible = false
	_setup_panel.visible = true
	_settings_panel.visible = false


func _show_settings() -> void:
	_main_buttons.visible = false
	_setup_panel.visible = false
	_settings_panel.visible = true


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


func _on_faction_toggle(value: int) -> void:
	_selected_faction = value
	_apply_faction_toggle_state()


func _apply_faction_toggle_state() -> void:
	if _faction_buttons.size() < 2:
		return
	_faction_buttons[0].button_pressed = (_selected_faction == MatchSettingsClass.FactionId.ANVIL)
	_faction_buttons[1].button_pressed = (_selected_faction == MatchSettingsClass.FactionId.SABLE)
	if _faction_icons.size() >= 2:
		_faction_icons[0].selected = _faction_buttons[0].button_pressed
		_faction_icons[1].selected = _faction_buttons[1].button_pressed


## --- Button handlers ---

func _on_play_pressed() -> void:
	MatchSettings.tutorial_mode = false
	_show_setup()


func _on_tutorial_pressed() -> void:
	MatchSettings.tutorial_mode = true
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
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, db)


func _start_match() -> void:
	get_tree().change_scene_to_file(ARENA_SCENE)


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

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(620, 560)
	center.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	var title := Label.new()
	title.text = "%s — Tech Tree" % (roster["label"] as String)
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(580, 440)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)

	# Faction summary — civ-bonus-style overview of doctrine, role
	# emphasis, and the headline mechanical differentiators. Reads
	# above the build chain so the player gets the "why pick this
	# faction" pitch before they scan the unit list.
	var summary_lbl := Label.new()
	summary_lbl.text = _faction_summary(faction_id)
	summary_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary_lbl.custom_minimum_size = Vector2(560, 0)
	summary_lbl.add_theme_font_size_override("font_size", 13)
	summary_lbl.add_theme_color_override("font_color", Color(0.78, 0.85, 0.95, 1.0))
	rows.add_child(summary_lbl)
	var summary_spacer := Control.new()
	summary_spacer.custom_minimum_size = Vector2(0, 8)
	rows.add_child(summary_spacer)

	# Build chain — each entry shows the building gate + the units
	# unlocked at that gate. Reads top-down as the actual progression
	# the player follows in match. Slots a roster doesn't fill (e.g.
	# Anvil has no transport_adv, Sable has no pylon_air for Anvil)
	# are silently skipped by the per-tier role iteration below.
	var chain: Array[Dictionary] = [
		{"gate": "Headquarters (start)", "roles": ["engineer", "crawler"]},
		{"gate": "Basic Foundry (250 S, requires Headquarters)", "roles": ["light_a", "light_b"]},
		{"gate": "Advanced Foundry (350 S, requires Basic Foundry)", "roles": ["heavy_base"]},
		{"gate": "Aerodrome (300 S, requires Advanced Foundry)", "roles": ["air_base"]},
		{"gate": "Advanced Armory (320 S, requires Basic Armory) — unlocks the second slot at Adv Foundry & Aerodrome and houses their branch upgrades", "roles": ["heavy_adv", "transport_adv", "air_adv"]},
		{"gate": "Black Pylon (Sable only, requires Basic Armory) — Mesh anchor; unlocks the Wraith bomber", "roles": ["pylon_air"]},
	]
	for tier: Dictionary in chain:
		var tier_lbl := Label.new()
		tier_lbl.text = tier["gate"] as String
		tier_lbl.add_theme_font_size_override("font_size", 16)
		tier_lbl.add_theme_color_override("font_color", COLOR_HEADING)
		rows.add_child(tier_lbl)
		for role: String in tier["roles"]:
			var path: String = roster.get(role, "") as String
			if path.is_empty():
				continue
			var unit_stat: UnitStatResource = load(path) as UnitStatResource
			if not unit_stat:
				continue
			var unit_lbl := Label.new()
			unit_lbl.text = "    • %s — %s   (%dS / %dF, Pop %d)" % [
				unit_stat.unit_name,
				str(unit_stat.unit_class).capitalize(),
				unit_stat.cost_salvage,
				unit_stat.cost_fuel,
				unit_stat.population,
			]
			unit_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
			rows.add_child(unit_lbl)
			if unit_stat.special_description != "":
				var blurb := Label.new()
				blurb.text = "        " + unit_stat.special_description
				blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				blurb.custom_minimum_size = Vector2(540, 0)
				blurb.add_theme_font_size_override("font_size", 12)
				blurb.add_theme_color_override("font_color", Color(0.65, 0.70, 0.78, 1.0))
				rows.add_child(blurb)
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		rows.add_child(spacer)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(160, 36)
	close_btn.pressed.connect(canvas.queue_free)
	vbox.add_child(close_btn)


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
