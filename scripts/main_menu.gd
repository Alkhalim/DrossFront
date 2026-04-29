extends Control
## Main menu — entry point of the game. Lets the player pick difficulty,
## start a tutorial run, adjust settings, or quit. Builds its UI in code so
## the .tscn stays minimal.

const ARENA_SCENE: String = "res://scenes/test_arena.tscn"

const COLOR_TITLE := Color(0.95, 0.92, 0.78, 1.0)
const COLOR_SUBTITLE := Color(0.55, 0.95, 0.55, 1.0)
const COLOR_HINT := Color(0.7, 0.85, 0.95, 1.0)
const COLOR_PANEL_BG := Color(0.08, 0.09, 0.10, 0.92)

var _root_vbox: VBoxContainer = null
var _main_buttons: VBoxContainer = null
var _difficulty_panel: VBoxContainer = null
var _settings_panel: VBoxContainer = null


func _ready() -> void:
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
	btn_pressed.bg_color = Color(0.12, 0.14, 0.16, 1.0)
	btn_pressed.border_color = Color(0.95, 0.78, 0.32, 1.0)

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

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 28)
	_root_vbox.add_child(spacer)

	_build_main_buttons()
	_build_difficulty_panel()
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


func _build_difficulty_panel() -> void:
	_difficulty_panel = VBoxContainer.new()
	_difficulty_panel.add_theme_constant_override("separation", 10)
	_difficulty_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_difficulty_panel.visible = false
	_root_vbox.add_child(_difficulty_panel)

	var heading := Label.new()
	heading.text = "Choose Difficulty"
	heading.add_theme_font_size_override("font_size", 22)
	heading.add_theme_color_override("font_color", COLOR_SUBTITLE)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_difficulty_panel.add_child(heading)

	for entry: Dictionary in [
		{ "label": "Easy",   "value": MatchSettingsClass.Difficulty.EASY,   "blurb": "Slow AI economy, light pressure" },
		{ "label": "Normal", "value": MatchSettingsClass.Difficulty.NORMAL, "blurb": "Balanced AI" },
		{ "label": "Hard",   "value": MatchSettingsClass.Difficulty.HARD,   "blurb": "Aggressive AI, faster waves" },
	]:
		var btn := Button.new()
		btn.text = "%s — %s" % [entry["label"], entry["blurb"]]
		btn.custom_minimum_size = Vector2(360, 44)
		btn.pressed.connect(_on_difficulty_chosen.bind(entry["value"]))
		_difficulty_panel.add_child(btn)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(160, 36)
	back.pressed.connect(_show_main)
	_difficulty_panel.add_child(back)


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

	var vol_label := Label.new()
	vol_label.text = "Master Volume"
	vol_label.add_theme_font_size_override("font_size", 16)
	vol_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_settings_panel.add_child(vol_label)

	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(320, 24)
	slider.min_value = -40.0
	slider.max_value = 6.0
	slider.step = 1.0
	slider.value = AudioServer.get_bus_volume_db(0)
	slider.value_changed.connect(_on_volume_changed)
	_settings_panel.add_child(slider)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(160, 36)
	back.pressed.connect(_show_main)
	_settings_panel.add_child(back)


## --- Navigation ---

func _show_main() -> void:
	_main_buttons.visible = true
	_difficulty_panel.visible = false
	_settings_panel.visible = false


func _show_difficulty() -> void:
	_main_buttons.visible = false
	_difficulty_panel.visible = true
	_settings_panel.visible = false


func _show_settings() -> void:
	_main_buttons.visible = false
	_difficulty_panel.visible = false
	_settings_panel.visible = true


## --- Button handlers ---

func _on_play_pressed() -> void:
	MatchSettings.tutorial_mode = false
	_show_difficulty()


func _on_tutorial_pressed() -> void:
	MatchSettings.tutorial_mode = true
	# Tutorial always runs on Easy so new players aren't crushed while reading.
	MatchSettings.difficulty = MatchSettingsClass.Difficulty.EASY
	_start_match()


func _on_settings_pressed() -> void:
	_show_settings()


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_difficulty_chosen(diff: int) -> void:
	MatchSettings.difficulty = diff
	_start_match()


func _on_volume_changed(db: float) -> void:
	AudioServer.set_bus_volume_db(0, db)


func _start_match() -> void:
	get_tree().change_scene_to_file(ARENA_SCENE)
