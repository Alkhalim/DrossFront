class_name AIDebugOverlay
extends CanvasLayer
## Floating debug panel that shows live snapshots of every AIController
## in the scene. Designed to ride alongside the regular HUD without
## polluting it -- self-contained CanvasLayer + a single RichTextLabel
## per AI in a vertical stack on the right side of the screen.
##
## ## Toggling
## Off by default. The pause-screen Settings dialog has a
## "Show AI investigation tool" toggle that flips
## AIDebugOverlay.user_enabled at runtime. The overlay always
## instantiates so the toggle can flip it back on without a
## scene reload, but its CanvasLayer stays hidden + its tick
## work skips while user_enabled is false. The AIController-side
## instrumentation (kill / loss tallies, blocker capture in
## _try_place) stays cheap and always-on so the overlay never
## has a 'cold start' lag when re-enabled.

## Backwards-compat const -- left as a hard kill switch in case
## the overlay file itself ever needs to be removed from the
## build entirely. Defaults true; the runtime user_enabled flag
## below is the regular on/off.
const DEBUG_HARNESS_ENABLED: bool = true

## Per-session opt-in flag. Static so the value persists when
## the pause overlay rebuilds and so a future Settings panel
## save/load can write to it directly. Defaults to false so a
## regular player never sees the harness without explicitly
## opting in via the Settings dialog.
static var user_enabled: bool = false

## Layout knobs.
const PANEL_WIDTH: float = 300.0
const PANEL_HEIGHT_PER_AI: float = 212.0
const PANEL_GAP: float = 8.0
const RIGHT_MARGIN: float = 12.0
const TOP_MARGIN: float = 90.0          # Sits below the player's HUD bar.
const REFRESH_INTERVAL: float = 0.25    # Match the AIController tick rate.

var _container: VBoxContainer = null
var _panels: Dictionary = {}            # owner_id -> RichTextLabel
var _refresh_accum: float = 0.0


func _ready() -> void:
	# Float above the regular HUD so it doesn't compete for input.
	# Layer 50 sits above HUD (default 0) but below pause menus (100).
	layer = 50
	# Initial visibility tracks the runtime opt-in flag. The
	# Settings dialog flips user_enabled at runtime, so this just
	# sets the start state -- _process re-syncs every tick.
	visible = user_enabled
	_container = VBoxContainer.new()
	_container.name = "AIDebugContainer"
	_container.add_theme_constant_override("separation", int(PANEL_GAP))
	_container.anchor_left = 1.0
	_container.anchor_right = 1.0
	_container.anchor_top = 0.0
	_container.anchor_bottom = 0.0
	_container.offset_left = -PANEL_WIDTH - RIGHT_MARGIN
	_container.offset_right = -RIGHT_MARGIN
	_container.offset_top = TOP_MARGIN
	_container.size = Vector2(PANEL_WIDTH, 0.0)
	add_child(_container)
	# First refresh on the next frame so the AIControllers' _setup
	# call_deferred has a chance to run.
	set_process(true)


func _process(delta: float) -> void:
	# Sync visibility to the runtime opt-in flag. When toggled off
	# we hide the layer and skip the per-tick refresh entirely so
	# the harness costs nothing while the player isn't looking at
	# it. Toggling back on re-shows the panels on the next tick
	# without a scene reload.
	if visible != user_enabled:
		visible = user_enabled
	if not user_enabled:
		return
	_refresh_accum += delta
	if _refresh_accum < REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	_refresh()


func _refresh() -> void:
	var ais: Array[Node] = get_tree().get_nodes_in_group("ai_controllers")
	# Drop panels for AIs that have left the scene (e.g. defeated).
	var seen: Dictionary = {}
	for node: Node in ais:
		if not is_instance_valid(node):
			continue
		var oid: int = node.get("owner_id") as int
		seen[oid] = true
		var panel: RichTextLabel = _panels.get(oid, null) as RichTextLabel
		if not panel:
			panel = _make_panel(oid)
			_panels[oid] = panel
			_container.add_child(panel)
		if not node.has_method("get_debug_snapshot"):
			continue
		var snap: Dictionary = node.call("get_debug_snapshot") as Dictionary
		panel.text = _format_snapshot(snap)
	# Prune panels for AIs that vanished.
	for oid_v: Variant in _panels.keys().duplicate():
		var oid: int = oid_v as int
		if not seen.has(oid):
			var p: RichTextLabel = _panels[oid] as RichTextLabel
			if p and is_instance_valid(p):
				p.queue_free()
			_panels.erase(oid)


func _make_panel(owner_id: int) -> RichTextLabel:
	var panel := RichTextLabel.new()
	panel.name = "AIPanel_%d" % owner_id
	panel.bbcode_enabled = true
	panel.fit_content = false
	panel.scroll_active = false
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT_PER_AI)
	panel.add_theme_font_size_override("normal_font_size", 12)
	panel.add_theme_font_size_override("bold_font_size", 12)
	panel.add_theme_color_override("default_color", Color(0.92, 0.92, 0.96, 1.0))
	# Dark translucent backdrop so the text reads against bright maps.
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	bg.set_corner_radius_all(4)
	bg.set_content_margin_all(8)
	bg.border_color = Color(1.0, 0.55, 0.18, 0.65)
	bg.set_border_width_all(1)
	panel.add_theme_stylebox_override("normal", bg)
	return panel


func _format_snapshot(s: Dictionary) -> String:
	var oid: int = s.get("owner_id", -1) as int
	var faction_str: String = "Anvil" if (s.get("faction", 0) as int) == 0 else "Sable"
	var color_hex: String = _color_for_owner(oid)
	var lines: Array[String] = []
	lines.append("[color=%s][b]AI %d[/b][/color]  %s · %s · %s" % [
		color_hex, oid, faction_str,
		s.get("strategy", "?") as String,
		s.get("state", "?") as String,
	])
	var sps: float = s.get("salvage_per_sec", 0.0) as float
	var fps: float = s.get("fuel_per_sec", 0.0) as float
	lines.append("Salv [b]%d[/b] (+%.1f/s)   Fuel [b]%d[/b] (+%.1f/s)" % [
		s.get("salvage", 0) as int, sps,
		s.get("fuel", 0) as int, fps,
	])
	lines.append("Units [b]%d[/b]/%d (wave %d)   K/L [color=#7df27d]%d[/color]/[color=#f27d7d]%d[/color]" % [
		s.get("unit_count", 0) as int,
		s.get("wave_target", 0) as int,
		s.get("wave_count", 0) as int,
		s.get("kills", 0) as int,
		s.get("losses", 0) as int,
	])
	var nb: String = s.get("next_build", "") as String
	var blocker: String = s.get("next_build_blocker", "") as String
	if nb == "":
		lines.append("Next build: [i]idle / nothing pending[/i]")
	elif blocker == "":
		lines.append("Next build: [b]%s[/b]" % nb)
	else:
		lines.append("Next build: [b]%s[/b] [color=#cccc66](%s)[/color]" % [nb, blocker])
	# Last successful placement -- pairs with the next-blocked line
	# so the user can see what the AI is actually doing, not just
	# what it can't do. Empty when nothing has been placed yet.
	var lp: String = s.get("last_placed", "") as String
	var lp_age: float = s.get("last_placed_age_sec", -1.0) as float
	if lp != "" and lp_age >= 0.0:
		lines.append("Last placed: [b]%s[/b] [color=#7df27d](%ds ago)[/color]" % [lp, int(round(lp_age))])
	# Engineer state breakdown -- helps diagnose 'no free engineer'
	# blockers. Snapshot is refreshed once per AI tick directly off
	# each engineer's current state, so the displayed mix reflects
	# the moment in time, not the last placement attempt.
	var eng_t: int = s.get("eng_total", 0) as int
	var eng_i: int = s.get("eng_idle", 0) as int
	var eng_b: int = s.get("eng_build", 0) as int
	var eng_r: int = s.get("eng_repair", 0) as int
	var eng_g: int = s.get("eng_garrison", 0) as int
	var eng_m: int = s.get("eng_moving", 0) as int
	lines.append("Engineers: [b]%d[/b] (idle %d / mov %d / build %d / rep %d / garr %d)" % [
		eng_t, eng_i, eng_m, eng_b, eng_r, eng_g,
	])
	var sec: float = s.get("sec_until_attack", 0.0) as float
	if sec < 0.0:
		lines.append("Attack: [color=#ffaa66]ATTACKING NOW[/color]")
	else:
		lines.append("Next attack in: [b]%ds[/b] (worst case)" % int(round(sec)))
	return "\n".join(lines)


func _color_for_owner(owner_id: int) -> String:
	# Match the in-game team palette so the overlay rows are
	# instantly recognisable. Player 0 is blue, AI 1 red, AI 2
	# orange, AI 3 violet -- mirrors test_arena_controller's
	# starter palette.
	match owner_id:
		0: return "#4d8cff"
		1: return "#e84a4a"
		2: return "#e8a04a"
		3: return "#a14ae8"
	return "#cccccc"
