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
var _map_buttons: Array[Button] = []
var _map_previews: Array[Control] = []
var _faction_buttons: Array[Button] = []
var _faction_icons: Array[Control] = []
var _ai_rows_container: VBoxContainer = null
var _ai_difficulty_dropdowns: Dictionary = {}  # player_id → OptionButton
var _ai_personality_dropdowns: Dictionary = {}  # player_id → OptionButton


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

	# Centered column.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_root_vbox = VBoxContainer.new()
	_root_vbox.add_theme_constant_override("separation", 14)
	_root_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(_root_vbox)

	# Title block.
	var title := Label.new()
	title.text = "DROSSFRONT"
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root_vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "A real-time strategy on a dying industrial world"
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", COLOR_HINT)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root_vbox.add_child(subtitle)

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

	_build_mode_section()
	_build_map_section()
	_build_faction_section()
	_build_ai_section()
	_build_setup_buttons()


func _build_mode_section() -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_setup_panel.add_child(hbox)

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


func _build_map_section() -> void:
	var heading := Label.new()
	heading.text = "Map:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	_setup_panel.add_child(heading)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_setup_panel.add_child(hbox)

	for entry: Dictionary in [
		{ "value": MatchSettingsClass.MapId.FOUNDRY_BELT, "preview_id": MapPreviewScript.MapId.FOUNDRY_BELT },
		{ "value": MatchSettingsClass.MapId.ASHPLAINS_CROSSING, "preview_id": MapPreviewScript.MapId.ASHPLAINS_CROSSING },
	]:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 4)
		hbox.add_child(col)

		# Procedural preview thumbnail + click button below.
		var preview: Control = MapPreviewScript.new()
		preview.map_id = entry["preview_id"]
		_map_previews.append(preview)
		col.add_child(preview)

		var btn := Button.new()
		btn.text = "Foundry Belt" if entry["value"] == MatchSettingsClass.MapId.FOUNDRY_BELT else "Ashplains Crossing"
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(220, 36)
		btn.pressed.connect(_on_map_toggle.bind(entry["value"] as int))
		_map_buttons.append(btn)
		col.add_child(btn)
	_apply_map_toggle_state()


func _build_faction_section() -> void:
	var heading := Label.new()
	heading.text = "Your Faction:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	_setup_panel.add_child(heading)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_setup_panel.add_child(hbox)

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
	_apply_faction_toggle_state()


func _build_ai_section() -> void:
	var heading := Label.new()
	heading.text = "AI Setup:"
	heading.add_theme_font_size_override("font_size", 16)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	_setup_panel.add_child(heading)

	_ai_rows_container = VBoxContainer.new()
	_ai_rows_container.add_theme_constant_override("separation", 6)
	_setup_panel.add_child(_ai_rows_container)
	_rebuild_ai_rows()


func _rebuild_ai_rows() -> void:
	## Tear down + rebuild the AI dropdown rows whenever the mode
	## toggle flips. 1v1 has one enemy AI; 2v2 has the ally + two
	## enemies. Each row holds a difficulty + personality dropdown.
	for child: Node in _ai_rows_container.get_children():
		child.queue_free()
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
	name_label.custom_minimum_size = Vector2(200, 30)
	# Ally rows tinted green, enemy rows red — same colour scheme as
	# the minimap so the player reads at a glance which is which.
	if team == 0:
		name_label.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55, 1.0))
	else:
		name_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.50, 1.0))
	row.add_child(name_label)

	var diff_dropdown := OptionButton.new()
	diff_dropdown.custom_minimum_size = Vector2(120, 32)
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
	pers_dropdown.custom_minimum_size = Vector2(160, 32)
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


func _on_map_toggle(value: int) -> void:
	_selected_map = value
	_apply_map_toggle_state()


func _apply_map_toggle_state() -> void:
	if _map_buttons.size() < 2:
		return
	_map_buttons[0].button_pressed = (_selected_map == MatchSettingsClass.MapId.FOUNDRY_BELT)
	_map_buttons[1].button_pressed = (_selected_map == MatchSettingsClass.MapId.ASHPLAINS_CROSSING)
	if _map_previews.size() >= 2:
		_map_previews[0].selected = _map_buttons[0].button_pressed
		_map_previews[1].selected = _map_buttons[1].button_pressed


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
	# Tutorial always runs on Easy + 1v1 + Foundry Belt + Anvil vs Anvil.
	MatchSettings.difficulty = MatchSettingsClass.Difficulty.EASY
	MatchSettings.mode = MatchSettingsClass.Mode.ONE_V_ONE
	MatchSettings.map_id = MatchSettingsClass.MapId.FOUNDRY_BELT
	MatchSettings.player_faction = MatchSettingsClass.FactionId.ANVIL
	MatchSettings.enemy_faction = MatchSettingsClass.FactionId.ANVIL
	MatchSettings.ai_personalities = {}
	MatchSettings.ai_difficulties = {}
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
	MatchSettings.ai_difficulties = diffs
	MatchSettings.ai_personalities = pers
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
