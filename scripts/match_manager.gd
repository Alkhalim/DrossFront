class_name MatchManager
extends Node
## Tracks win/lose conditions per team. A team is eliminated when its last
## HQ-class building is destroyed; the local player's team winning fires
## VICTORY, losing fires DEFEAT. Works the same way for 1v1 (one HQ per
## team) and 2v2 (two HQs per team).

signal match_over(victory: bool)

## Per-HQ entry: { hq: Node, owner_id: int, team_id: int }
var _hqs: Array[Dictionary] = []
var _match_ended: bool = false
var _victory_panel: Control = null
var _match_timer: float = 0.0
var _registry: Node = null

## Lightweight stats tally — surfaced on the end screen so the player has
## something to read after the dust settles. Updated via signals from the
## existing combat / building paths so we don't have to instrument every
## damage call.
var _enemy_units_lost: int = 0    # squads on opposing team that died
var _own_units_lost: int = 0      # squads on local team that died
var _enemy_buildings_lost: int = 0
var _own_buildings_lost: int = 0

## Peak concurrent army for the local team. Sampled at PEAK_SAMPLE_INTERVAL
## from the units group so we don't pay for it every frame.
var _peak_army: int = 0
var _peak_sample_accum: float = 0.0
const PEAK_SAMPLE_INTERVAL: float = 2.0

## Most-trained-unit tally. unit_name (StringName) → cumulative spawn count
## for the local team. The MVP label on the end screen is derived from the
## highest entry. Counts squads (a Borzoi pair = 1 entry) rather than
## members because that matches what the player perceives as "how many of X
## did I build".
var _trained_by_unit: Dictionary = {}
var _tracked_spawns: Dictionary = {}  # iid → true (dedupe)

## Time-series snapshots for the post-battle graphs. Sampled every
## HISTORY_SAMPLE_INTERVAL_SEC throughout the match. The end-of-match
## screen renders these as line graphs (military strength + economy
## over time). All arrays share the same index — entry[i] is the
## state at _history_times[i] seconds into the match.
const HISTORY_SAMPLE_INTERVAL_SEC: float = 8.0
var _history_times: Array[float] = []
var _history_local_army: Array[int] = []       # local-team alive unit count
var _history_enemy_army: Array[int] = []       # enemy-team alive unit count
var _history_local_salvage: Array[int] = []    # cumulative salvage earned (local player RM)
var _history_enemy_kills: Array[int] = []      # cumulative enemy squads killed (running total)
var _history_sample_accum: float = 0.0


func _ready() -> void:
	call_deferred("_find_hqs")


func _find_hqs() -> void:
	_registry = get_tree().current_scene.get_node_or_null("PlayerRegistry")
	var buildings: Array[Node] = get_tree().get_nodes_in_group("buildings")
	for node: Node in buildings:
		_register_hq_if_eligible(node)

	# Wire up the kill counters for any units that already exist (rare —
	# usually only the starter armies). Future units register themselves
	# via the unit-spawned signal in _on_unit_added.
	for unit: Node in get_tree().get_nodes_in_group("units"):
		_attach_unit_listener(unit)
	# Catch units spawned mid-match (foundry production, AI replenishments).
	get_tree().node_added.connect(_on_node_added)


func _register_hq_if_eligible(node: Node) -> void:
	if not ("stats" in node):
		return
	var stats: Resource = node.get("stats")
	if not stats or not ("building_id" in stats):
		return
	if stats.get("building_id") != &"headquarters":
		return
	var oid: int = node.get("owner_id") as int
	var tid: int = (_registry.get_team(oid) as int) if _registry else (0 if oid == 0 else 1)
	_hqs.append({"hq": node, "owner_id": oid, "team_id": tid})
	node.connect("destroyed", _on_hq_destroyed.bind(node))
	# Buildings count toward the side-totals on the end screen.
	node.connect("destroyed", _on_building_destroyed.bind(oid))


func _on_node_added(node: Node) -> void:
	if node.is_in_group("units"):
		# Wait one frame so groups + properties are populated.
		call_deferred("_attach_unit_listener", node)
	elif node.is_in_group("buildings"):
		call_deferred("_register_hq_if_eligible", node)
		call_deferred("_attach_building_listener", node)


func _attach_unit_listener(unit: Node) -> void:
	if not is_instance_valid(unit):
		return
	if not unit.has_signal("squad_destroyed"):
		return
	if unit.is_connected("squad_destroyed", _on_unit_died):
		return
	var oid: int = unit.get("owner_id") as int
	unit.connect("squad_destroyed", _on_unit_died.bind(oid))
	# MVP tally — count local-team spawns by unit_name. Dedupe via
	# instance id so a unit that briefly toggles in/out of the group
	# (during respawn / garrison) is only counted once.
	var local_team_id: int = _local_team()
	var their_team: int = (_registry.get_team(oid) as int) if _registry else (0 if oid == 0 else 1)
	if their_team != local_team_id:
		return
	var iid: int = unit.get_instance_id()
	if _tracked_spawns.has(iid):
		return
	_tracked_spawns[iid] = true
	var stats_v: Variant = unit.get("stats")
	if stats_v == null:
		return
	var uname: StringName = stats_v.get("unit_name") as StringName
	if uname == &"":
		return
	# Skip engineer / crawler / militia composition entries from the MVP
	# tally — the "Most-built unit" stat reads as nonsense if it's always
	# "Mekh" (the engineer the player constantly replaces). Combat-only.
	if "can_build" in stats_v and (stats_v.get("can_build") as bool):
		return
	if stats_v.get("unit_class") == &"crawler":
		return
	_trained_by_unit[uname] = (_trained_by_unit.get(uname, 0) as int) + 1


func _attach_building_listener(building: Node) -> void:
	if not is_instance_valid(building):
		return
	if not building.has_signal("destroyed"):
		return
	# Don't double-connect on HQs (already wired by _register_hq_if_eligible).
	for entry: Dictionary in _hqs:
		if entry["hq"] == building:
			return
	if building.is_connected("destroyed", _on_building_destroyed):
		return
	var oid: int = building.get("owner_id") as int
	building.connect("destroyed", _on_building_destroyed.bind(oid))


func _process(delta: float) -> void:
	if _match_ended:
		return
	_match_timer += delta
	# Peak-army sampler. Walks the local team's units group every
	# PEAK_SAMPLE_INTERVAL and keeps the running max. Cheap (one
	# group walk per 2s) and gives the end screen a "Peak army"
	# headline number without per-frame bookkeeping.
	_peak_sample_accum += delta
	if _peak_sample_accum >= PEAK_SAMPLE_INTERVAL:
		_peak_sample_accum = 0.0
		_sample_peak_army()
	# Time-series history sampler for post-battle graphs. Same group
	# walks as the peak-army sampler but recorded as a series.
	_history_sample_accum += delta
	if _history_sample_accum >= HISTORY_SAMPLE_INTERVAL_SEC:
		_history_sample_accum = 0.0
		_sample_history()


func _sample_history() -> void:
	## Snapshot the current army counts + salvage total for the end-
	## of-match graphs. One sample per HISTORY_SAMPLE_INTERVAL_SEC.
	var local_team_id: int = _local_team()
	var local_army: int = 0
	var enemy_army: int = 0
	for unit: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit):
			continue
		if "alive_count" in unit and (unit.get("alive_count") as int) <= 0:
			continue
		var oid: int = unit.get("owner_id") as int
		var tid: int = (_registry.get_team(oid) as int) if _registry else (0 if oid == 0 else 1)
		var count: int = (unit.get("alive_count") as int) if "alive_count" in unit else 1
		if tid == local_team_id:
			local_army += count
		else:
			enemy_army += count
	var salvage_earned: int = _query_local_salvage_earned()
	_history_times.append(_match_timer)
	_history_local_army.append(local_army)
	_history_enemy_army.append(enemy_army)
	_history_local_salvage.append(salvage_earned)
	_history_enemy_kills.append(_enemy_units_lost)


func _sample_peak_army() -> void:
	var local_team_id: int = _local_team()
	var cur: int = 0
	for unit: Node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit):
			continue
		var oid: int = unit.get("owner_id") as int
		var tid: int = (_registry.get_team(oid) as int) if _registry else (0 if oid == 0 else 1)
		if tid != local_team_id:
			continue
		# Count alive members across the squad so the headline reflects
		# actual fielded mass rather than empty-shell squad nodes.
		if "alive_count" in unit:
			cur += unit.get("alive_count") as int
		else:
			cur += 1
	if cur > _peak_army:
		_peak_army = cur


func _local_team() -> int:
	if not _registry:
		return 0
	var local_id: int = _registry.get("local_player_id") as int
	return _registry.get_team(local_id) as int


func _on_hq_destroyed(destroyed_node: Node) -> void:
	if _match_ended:
		return

	# Was this the local player's own HQ? If so, defeat is immediate —
	# losing your own HQ ends your game even if an ally is still alive.
	var lost_was_local_player: bool = false
	if _registry:
		for entry: Dictionary in _hqs:
			if entry["hq"] == destroyed_node:
				if (entry["owner_id"] as int) == (_registry.get("local_player_id") as int):
					lost_was_local_player = true
				break

	# Drop the entry for the fallen HQ.
	var i: int = _hqs.size() - 1
	while i >= 0:
		if _hqs[i]["hq"] == destroyed_node:
			_hqs.remove_at(i)
		i -= 1

	if lost_was_local_player:
		# Tutorial mode skips the HQ-loss-equals-defeat rule. The
		# player starts the mission HQ-less and only claims one
		# partway through; losing it later (or never having one
		# to begin with) shouldn't end the run. Win is gated on
		# the TutorialMission's enemy-cleared check instead.
		var settings: Node = get_node_or_null("/root/MatchSettings")
		if settings and settings.get("tutorial_mode"):
			return
		# Pathfinding test scenarios (Special Operations → Pathfinding
		# Tests) suppress match end too — the dev-only smoke scenes
		# don't have HQs and any combat in future tests shouldn't
		# auto-defeat the player just because a probe gets killed.
		if settings and settings.get("disable_match_end"):
			return
		_end_match(false)
		return

	# Tutorial mode owns its own end-of-mission timing — the
	# TutorialMission detects "enclave cleared" via its WIN stage
	# trigger and fires _end_match(true) itself, with a closing
	# dialogue beat in between. Skipping the auto-tally here also
	# dodges the stale-team_id bug (the player's HQ registers as
	# owner 2 = neutral ruin at scene start; its team_id cache
	# never updates when the player claims it, so the auto-tally
	# would mis-count surviving teams).
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if settings and settings.get("tutorial_mode"):
		return

	# Tally surviving HQs per team. Match ends as soon as one team has
	# zero HQs left. Re-query owner_id from the live HQ node so a
	# captured ruin (owner flipped post-registration) tallies under
	# its CURRENT team rather than the cached one from registration.
	var local_team_alive: int = 0
	var enemy_teams_alive: int = 0
	var local_team_id: int = _local_team()
	for entry: Dictionary in _hqs:
		var hq: Node = entry["hq"]
		if not is_instance_valid(hq):
			continue
		var live_oid: int = hq.get("owner_id") as int
		var live_tid: int = (_registry.get_team(live_oid) as int) if _registry else (0 if live_oid == 0 else 1)
		if live_tid == local_team_id:
			local_team_alive += 1
		else:
			enemy_teams_alive += 1

	if local_team_alive == 0:
		_end_match(false)
	elif enemy_teams_alive == 0:
		_end_match(true)


func _on_unit_died(owner_id: int) -> void:
	# Counts squads (a Borzoi dying = +1, not +2) so the end-screen totals
	# read at-a-glance rather than ballooning into per-member numbers.
	var local_team_id: int = _local_team()
	var their_team: int = (_registry.get_team(owner_id) as int) if _registry else (0 if owner_id == 0 else 1)
	if their_team == local_team_id:
		_own_units_lost += 1
	else:
		_enemy_units_lost += 1


func _on_building_destroyed(owner_id: int) -> void:
	var local_team_id: int = _local_team()
	var their_team: int = (_registry.get_team(owner_id) as int) if _registry else (0 if owner_id == 0 else 1)
	if their_team == local_team_id:
		_own_buildings_lost += 1
	else:
		_enemy_buildings_lost += 1


## Seconds between win-condition met and the victory overlay
## actually appearing. Lets the player watch their final salvo
## resolve. _match_ended flips to true the moment the condition
## triggers (so the loss-detection branches stop firing inside the
## delay window — the player can't lose during this grace period).
const VICTORY_DECLARATION_DELAY_SEC: float = 4.5


func _end_match(victory: bool) -> void:
	# Idempotent. Called from _on_hq_destroyed AND directly from
	# TutorialMission._stage_win_enter; the second call must be a
	# no-op or we'd stack a second end-screen overlay.
	if _match_ended:
		return
	_match_ended = true
	match_over.emit(victory)
	# Match-end stinger — defeat sample on loss, synthesised major-
	# triad fanfare on win.
	var audio: Node = get_tree().current_scene.get_node_or_null("AudioManager")
	if audio:
		if victory and audio.has_method("play_victory"):
			audio.play_victory()
		elif not victory and audio.has_method("play_defeat"):
			audio.play_defeat()
	# Defer the actual end-screen so the player gets to see their
	# final salvo land. Loss path keeps the immediate overlay —
	# delaying the defeat stinger reads as the game refusing to
	# acknowledge the loss. _match_ended already flipped above so
	# nothing in the delay window can flip the result back.
	if victory:
		var tree: SceneTree = get_tree()
		if tree:
			var timer: SceneTreeTimer = tree.create_timer(VICTORY_DECLARATION_DELAY_SEC)
			timer.timeout.connect(_show_end_screen.bind(true))
			return
	_show_end_screen(victory)


func _show_end_screen(victory: bool) -> void:
	# Faction context for styling + flavor copy. We pull the LOCAL
	# player's faction from MatchSettings; if it's missing (e.g. test
	# scenes that don't push the autoload), fall back to Anvil.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	var local_faction: int = 0
	if settings and "player_faction" in settings:
		local_faction = settings.get("player_faction") as int

	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)

	_victory_panel = Control.new()
	_victory_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(_victory_panel)

	# Semi-transparent vignette. Faction-tinted very lightly so the
	# background reads as part of the same chrome as the card.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.78)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_victory_panel.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_victory_panel.add_child(center)

	# Card — faction-themed panel with the faction's accent border.
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(540, 0)
	var card_style: StyleBoxTexture = FactionUIStyle.make_panel(local_faction)
	card.add_theme_stylebox_override("panel", card_style)
	center.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(vbox)

	# Faction icon at the top — same procedural draw the HUD uses, so the
	# end screen visually anchors in the player's chosen faction.
	var icon_row := CenterContainer.new()
	vbox.add_child(icon_row)
	var icon: FactionIcon = FactionIcon.new()
	icon.faction = local_faction as FactionIcon.Faction
	icon.custom_minimum_size = Vector2(72, 72)
	icon_row.add_child(icon)

	# Faction-flavored title. Each faction has its own win/lose stinger.
	var title := Label.new()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = _faction_flavor_title(local_faction, victory)
	var win_color: Color = FactionUIStyle.border_hot(local_faction)
	var lose_color: Color = Color(0.95, 0.3, 0.25, 1.0)
	title.add_theme_color_override("font_color", win_color if victory else lose_color)
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	title.add_theme_constant_override("outline_size", 6)
	vbox.add_child(title)

	# Subtitle — the boring "VICTORY / DEFEAT" word under the flavor line,
	# so the player isn't left guessing whether they won.
	var subtitle := Label.new()
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.text = "VICTORY" if victory else "DEFEAT"
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", FactionUIStyle.text_dim(local_faction))
	vbox.add_child(subtitle)

	# Separator strip.
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	vbox.add_child(sep)

	# Stat block — two columns of label / value pairs so the eye can
	# scan rather than parse a wall of text.
	var stats_grid := GridContainer.new()
	stats_grid.columns = 2
	stats_grid.add_theme_constant_override("h_separation", 18)
	stats_grid.add_theme_constant_override("v_separation", 4)
	vbox.add_child(stats_grid)

	@warning_ignore("integer_division")
	var mins: int = int(_match_timer) / 60
	var secs: int = int(_match_timer) % 60
	var salvage_earned: int = _query_local_salvage_earned()
	var mvp_name: String = _resolve_mvp_unit_name()

	# Derived stats — kill / loss ratio, average salvage / minute,
	# total squad-trade ratio, etc. Add them to the grid so the
	# player gets more readable insight than raw totals.
	var kdr: String = "—"
	if _own_units_lost > 0:
		kdr = "%.2f" % (float(_enemy_units_lost) / float(_own_units_lost))
	elif _enemy_units_lost > 0:
		kdr = "∞"
	var spm: String = "—"
	if _match_timer > 1.0:
		spm = "%.0f / min" % (float(salvage_earned) * 60.0 / _match_timer)
	# Peak army across both teams — quick read for "how big did this fight get".
	var peak_enemy: int = 0
	for ea: int in _history_enemy_army:
		if ea > peak_enemy:
			peak_enemy = ea
	var rows: Array = [
		["Match length",        "%d:%02d" % [mins, secs]],
		["Enemy squads killed", str(_enemy_units_lost)],
		["Own squads lost",     str(_own_units_lost)],
		["Squad kill / loss",   kdr],
		["Enemy buildings",     str(_enemy_buildings_lost) + " destroyed"],
		["Own buildings",       str(_own_buildings_lost) + " lost"],
		["Peak own army",       str(_peak_army) + " units"],
		["Peak enemy army",     str(peak_enemy) + " units"],
		["Salvage gathered",    str(salvage_earned)],
		["Salvage / minute",    spm],
		["Most-built unit",     mvp_name],
	]
	var label_color: Color = FactionUIStyle.text_dim(local_faction)
	var value_color: Color = FactionUIStyle.text_color(local_faction)
	for entry: Array in rows:
		var lab := Label.new()
		lab.text = (entry[0] as String) + ":"
		lab.add_theme_color_override("font_color", label_color)
		lab.add_theme_font_size_override("font_size", 16)
		stats_grid.add_child(lab)
		var val := Label.new()
		val.text = entry[1] as String
		val.add_theme_color_override("font_color", value_color)
		val.add_theme_font_size_override("font_size", 16)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stats_grid.add_child(val)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	vbox.add_child(spacer)

	# --- Time-series graphs.
	# Two stacked graphs: military strength (own + enemy army counts
	# over time) and economy (cumulative salvage earned + cumulative
	# enemy kills). Only render when there's actually data to plot —
	# very-short matches (< one sample interval) draw text instead.
	if _history_times.size() >= 2:
		var graph_section := VBoxContainer.new()
		graph_section.add_theme_constant_override("separation", 8)
		vbox.add_child(graph_section)
		# Military graph.
		var mil_title := Label.new()
		mil_title.text = "Military strength over time"
		mil_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mil_title.add_theme_font_size_override("font_size", 14)
		mil_title.add_theme_color_override("font_color", label_color)
		graph_section.add_child(mil_title)
		var mil_graph: Control = _build_line_graph(
			_history_times,
			[
				{"label": "Own army", "color": value_color, "values": _history_local_army},
				{"label": "Enemy army", "color": Color(0.95, 0.30, 0.25, 1.0), "values": _history_enemy_army},
			],
		)
		graph_section.add_child(mil_graph)
		# Economy graph.
		var econ_title := Label.new()
		econ_title.text = "Economy over time"
		econ_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		econ_title.add_theme_font_size_override("font_size", 14)
		econ_title.add_theme_color_override("font_color", label_color)
		graph_section.add_child(econ_title)
		var econ_graph: Control = _build_line_graph(
			_history_times,
			[
				{"label": "Salvage earned", "color": Color(0.95, 0.78, 0.32, 1.0), "values": _history_local_salvage},
				{"label": "Enemy kills", "color": Color(0.55, 0.85, 1.00, 1.0), "values": _history_enemy_kills},
			],
		)
		graph_section.add_child(econ_graph)
		var graph_spacer := Control.new()
		graph_spacer.custom_minimum_size = Vector2(0, 10)
		vbox.add_child(graph_spacer)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var restart_btn := Button.new()
	restart_btn.text = "Restart"
	restart_btn.custom_minimum_size = Vector2(180, 44)
	restart_btn.add_theme_stylebox_override("normal", FactionUIStyle.make_button_normal(local_faction))
	restart_btn.add_theme_stylebox_override("hover", FactionUIStyle.make_button_hover(local_faction))
	restart_btn.add_theme_stylebox_override("pressed", FactionUIStyle.make_button_pressed(local_faction))
	restart_btn.add_theme_color_override("font_color", FactionUIStyle.text_color(local_faction))
	restart_btn.pressed.connect(_on_restart)
	btn_row.add_child(restart_btn)

	var menu_btn := Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.custom_minimum_size = Vector2(180, 44)
	menu_btn.add_theme_stylebox_override("normal", FactionUIStyle.make_button_normal(local_faction))
	menu_btn.add_theme_stylebox_override("hover", FactionUIStyle.make_button_hover(local_faction))
	menu_btn.add_theme_stylebox_override("pressed", FactionUIStyle.make_button_pressed(local_faction))
	menu_btn.add_theme_color_override("font_color", FactionUIStyle.text_color(local_faction))
	menu_btn.pressed.connect(_on_main_menu)
	btn_row.add_child(menu_btn)

	get_tree().paused = true
	_victory_panel.process_mode = Node.PROCESS_MODE_ALWAYS


## Line-graph control used by the post-match summary. Renders one or
## more named time series sharing the same X axis (match time in
## seconds). Each series in `series` is a dict { label, color, values }
## where `values` is an Array[int] indexed the same as `times`.
class _GraphCanvas extends Control:
	var times: Array[float] = []
	var series: Array[Dictionary] = []
	const PAD_L: float = 36.0
	const PAD_R: float = 12.0
	const PAD_T: float = 10.0
	const PAD_B: float = 28.0

	func _ready() -> void:
		custom_minimum_size = Vector2(440, 130)

	func _draw() -> void:
		var sz: Vector2 = size
		var plot_rect := Rect2(
			Vector2(PAD_L, PAD_T),
			Vector2(maxf(sz.x - PAD_L - PAD_R, 1.0), maxf(sz.y - PAD_T - PAD_B, 1.0)),
		)
		# Background plate + grid.
		draw_rect(plot_rect, Color(0.06, 0.06, 0.08, 0.85), true)
		draw_rect(plot_rect, Color(0.4, 0.4, 0.42, 0.85), false, 1.0)
		var grid_color := Color(0.18, 0.18, 0.22, 0.85)
		for g_i: int in 4:
			var gy: float = plot_rect.position.y + plot_rect.size.y * float(g_i + 1) / 5.0
			draw_line(
				Vector2(plot_rect.position.x, gy),
				Vector2(plot_rect.position.x + plot_rect.size.x, gy),
				grid_color, 1.0,
			)
		# Axis range.
		var t_min: float = times[0]
		var t_max: float = times[times.size() - 1]
		var t_span: float = maxf(t_max - t_min, 0.001)
		var v_max: float = 1.0
		for s: Dictionary in series:
			var values: Array = s["values"] as Array
			for v_v: Variant in values:
				var v: float = float(v_v as int)
				if v > v_max:
					v_max = v
		# Round v_max up to a nice number so the Y label reads clean.
		var v_axis: float = ceilf(v_max / 10.0) * 10.0 if v_max < 1000.0 else ceilf(v_max / 100.0) * 100.0
		v_axis = maxf(v_axis, 1.0)
		# Y-axis labels — three ticks (top, mid, bottom).
		var lbl_color := Color(0.75, 0.75, 0.78, 1.0)
		for y_tick: int in 3:
			var frac: float = float(y_tick) / 2.0
			var y_val: float = v_axis * (1.0 - frac)
			var y_pos: float = plot_rect.position.y + plot_rect.size.y * frac
			var lbl: String = str(int(round(y_val)))
			draw_string(
				ThemeDB.fallback_font,
				Vector2(2, y_pos + 4),
				lbl,
				HORIZONTAL_ALIGNMENT_LEFT, 32, 10,
				lbl_color,
			)
		# X-axis labels — start + end match-time (mm:ss).
		@warning_ignore("integer_division")
		var mins_start: int = int(t_min) / 60
		var secs_start: int = int(t_min) % 60
		@warning_ignore("integer_division")
		var mins_end: int = int(t_max) / 60
		var secs_end: int = int(t_max) % 60
		draw_string(
			ThemeDB.fallback_font,
			Vector2(plot_rect.position.x, plot_rect.position.y + plot_rect.size.y + 14),
			"%d:%02d" % [mins_start, secs_start],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			lbl_color,
		)
		draw_string(
			ThemeDB.fallback_font,
			Vector2(plot_rect.position.x + plot_rect.size.x - 28, plot_rect.position.y + plot_rect.size.y + 14),
			"%d:%02d" % [mins_end, secs_end],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			lbl_color,
		)
		# Draw each series as a polyline.
		var legend_y: float = 4.0
		for series_i: int in series.size():
			var s2: Dictionary = series[series_i]
			var values2: Array = s2["values"] as Array
			var color: Color = s2["color"] as Color
			var label: String = s2["label"] as String
			var pts := PackedVector2Array()
			pts.resize(values2.size())
			for i: int in values2.size():
				var t_norm: float = (times[i] - t_min) / t_span
				var v_norm: float = clampf(float(values2[i] as int) / v_axis, 0.0, 1.0)
				pts[i] = Vector2(
					plot_rect.position.x + plot_rect.size.x * t_norm,
					plot_rect.position.y + plot_rect.size.y * (1.0 - v_norm),
				)
			# Polyline — connect consecutive points with thick lines.
			for i2: int in pts.size() - 1:
				draw_line(pts[i2], pts[i2 + 1], color, 2.0, true)
			# Legend swatch + label in the top-right corner.
			draw_rect(
				Rect2(Vector2(plot_rect.position.x + plot_rect.size.x - 90, legend_y), Vector2(10, 10)),
				color, true,
			)
			draw_string(
				ThemeDB.fallback_font,
				Vector2(plot_rect.position.x + plot_rect.size.x - 76, legend_y + 10),
				label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				lbl_color,
			)
			legend_y += 14.0


func _build_line_graph(times: Array[float], series: Array) -> Control:
	## Construct + return a configured _GraphCanvas. Caller adds it to
	## whatever container; size + drawing handled internally.
	var canvas := _GraphCanvas.new()
	canvas.times = times
	canvas.series = series
	return canvas


func _faction_flavor_title(faction: int, victory: bool) -> String:
	## Per-faction win/lose stinger that sells the doctrine. Anvil's
	## industrial-cling, Sable's signal-protocol register, Inheritor's
	## reliquary cadence, Heliarch's reactor-pyre imagery.
	if victory:
		match faction:
			1: return "PROTOCOL FULFILLED"
			2: return "THE MOULD HOLDS"
			3: return "THE REACTOR ENDURES"
			_: return "STEEL HOLDS"
	match faction:
		1: return "SIGNAL LOST"
		2: return "THE PATTERN BROKE"
		3: return "THE PYRE GOES OUT"
		_: return "THE LINE BROKE"


func _query_local_salvage_earned() -> int:
	## Reads the local player's ResourceManager total. Returns 0 if the
	## registry or RM isn't reachable (test scenes / pathfinding-test
	## scenarios don't wire one up).
	if not _registry:
		return 0
	var local_id: int = _registry.get("local_player_id") as int
	if not _registry.has_method("get_resource_manager"):
		return 0
	var rm: Node = _registry.call("get_resource_manager", local_id)
	if rm == null or not ("total_salvage_earned" in rm):
		return 0
	return rm.get("total_salvage_earned") as int


func _resolve_mvp_unit_name() -> String:
	## Picks the most-trained combat unit class from _trained_by_unit
	## and returns its display name (falling back to unit_name if no
	## display_name is set). Defaults to em-dash when nothing combatant
	## was ever trained — quiet rather than dishonest.
	if _trained_by_unit.is_empty():
		return "—"
	var best_name: StringName = &""
	var best_count: int = -1
	for k_v: Variant in _trained_by_unit.keys():
		var k: StringName = k_v as StringName
		var n: int = _trained_by_unit[k] as int
		if n > best_count:
			best_count = n
			best_name = k
	if best_name == &"":
		return "—"
	return "%s ×%d" % [String(best_name).capitalize(), best_count]


func _on_restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
