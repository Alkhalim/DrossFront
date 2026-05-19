class_name FactionUIStyle
extends RefCounted
## Single source of truth for faction-themed StyleBoxes. Every HUD
## surface that wants the Anvil / Sable look pulls its background +
## hover + pressed + disabled styles from here so palette tweaks are
## one-line changes. The textures used by the styleboxes are
## produced by FactionUITextures.
##
## Faction id mirrors MatchSettings.FactionId: 0 = Anvil, 1 = Sable.
##
## Each builder returns FRESH StyleBox instances so callers can
## further customise (corner radius, content margins) without
## mutating shared state. The underlying ImageTexture is shared.

# Palette doctrine — pulled from docs/03_factions.md "Visual Language".
# Each faction has a single primary identity color and a base shade;
# the four primaries are intentionally non-overlapping so a glance at
# the HUD reveals whose perspective you're playing:
#   Combine (Anvil) → brass / sodium-amber (forge interior).
#   Meridian (Sable) → cool blue-white / cyan (signal indicator).
#   Inheritor → pale-gold + architect violet-white (Inheritor's
#       exclusive color per the lore — none of the other factions use violet).
#   Heliarch → reactor amber / hot brass (pyre / heat-tier glow).

# --- Anvil palette — Combine forge-cathedral (brass + sodium-amber, no neon) ---
const _ANVIL_BORDER: Color       = Color(0.55, 0.46, 0.30, 1.0)  # brass
const _ANVIL_BORDER_HOT: Color   = Color(0.85, 0.70, 0.40, 1.0)  # hover — burnished
const _ANVIL_BORDER_DIM: Color   = Color(0.30, 0.25, 0.18, 1.0)  # disabled
const _ANVIL_PRESS_TINT: Color   = Color(0.65, 0.55, 0.40, 1.0)  # pressed flash
const _ANVIL_DISABLED_BG: Color  = Color(0.20, 0.18, 0.16, 0.85)
const _ANVIL_TEXT: Color         = Color(0.95, 0.92, 0.82, 1.0)  # pale brass / off-white
const _ANVIL_TEXT_DIM: Color     = Color(0.60, 0.55, 0.45, 1.0)

# --- Sable palette — Meridian Protocol cool blue-white / cyan ---
# Per docs/03_factions.md §2.3: "Cool blue-white as the indicator and
# weapon-glow color (the only saturated color on a Meridian mech). Faint
# cyan accent lighting on sensor arrays." Critically, the docs reserve
# VIOLET for the Inheritor faction ("the Architect's signature — a color
# none of the other factions use"). The previous palette mis-painted
# Sable in violet; this rework realigns to cyan.
const _SABLE_BORDER: Color       = Color(0.55, 0.85, 1.00, 1.0)  # cool blue-white
const _SABLE_BORDER_HOT: Color   = Color(0.80, 0.95, 1.00, 1.0)  # hover — near-white
const _SABLE_BORDER_DIM: Color   = Color(0.22, 0.36, 0.48, 1.0)  # darker steel-cyan
const _SABLE_PRESS_TINT: Color   = Color(0.90, 0.98, 1.00, 1.0)  # almost-white
const _SABLE_DISABLED_BG: Color  = Color(0.05, 0.06, 0.08, 0.85)  # anthracite
const _SABLE_TEXT: Color         = Color(0.92, 0.96, 0.98, 1.0)  # cool white
const _SABLE_TEXT_DIM: Color     = Color(0.48, 0.58, 0.65, 1.0)  # cool grey

# --- Inheritor palette — Architect AI / consecrated bronze + violet-white ---
# Per docs/03_factions.md §4.4: pale concrete-grey chassis + patinated
# bronze + verdigris + pale-gold leaf trim + subtle violet-white emissive
# (the Architect's signature). Violet is the Inheritor's exclusive
# indicator color; bronze + gold are the dominant readable tones.
const _INHERITOR_BORDER: Color      = Color(0.78, 0.62, 0.32, 1.0)  # pale-gold leaf (primary)
const _INHERITOR_BORDER_HOT: Color  = Color(1.00, 0.85, 0.55, 1.0)  # hover — bright gold
const _INHERITOR_BORDER_DIM: Color  = Color(0.34, 0.28, 0.18, 1.0)  # dark bronze
const _INHERITOR_PRESS_TINT: Color  = Color(0.85, 0.65, 1.00, 1.0)  # architect violet flash
const _INHERITOR_DISABLED_BG: Color = Color(0.10, 0.10, 0.10, 0.85)  # concrete shadow
const _INHERITOR_TEXT: Color        = Color(0.92, 0.86, 0.65, 1.0)  # warm gold text
const _INHERITOR_TEXT_DIM: Color    = Color(0.55, 0.50, 0.42, 1.0)

# --- Heliarch palette — reactor temple / brass + amber + sooted iron ---
# Per docs/03_factions.md §3.4: sooted iron grey base + brass/copper
# ritual metalwork + reactor amber as the signature emissive (visible
# through chassis grilles, vent stacks, exposed cores).
const _HELIARCH_BORDER: Color       = Color(1.00, 0.55, 0.20, 1.0)  # reactor amber (primary)
const _HELIARCH_BORDER_HOT: Color   = Color(1.00, 0.78, 0.42, 1.0)  # hover — pyre-warm
const _HELIARCH_BORDER_DIM: Color   = Color(0.45, 0.28, 0.14, 1.0)
const _HELIARCH_PRESS_TINT: Color   = Color(1.00, 0.92, 0.65, 1.0)  # white-hot Tier-3 flash
const _HELIARCH_DISABLED_BG: Color  = Color(0.14, 0.10, 0.06, 0.85)
const _HELIARCH_TEXT: Color         = Color(0.95, 0.85, 0.62, 1.0)
const _HELIARCH_TEXT_DIM: Color     = Color(0.55, 0.45, 0.30, 1.0)


# ---------------------------------------------------------------- API

static func border_color(faction: int) -> Color:
	match faction:
		1: return _SABLE_BORDER
		2: return _INHERITOR_BORDER
		3: return _HELIARCH_BORDER
		_: return _ANVIL_BORDER


static func border_hot(faction: int) -> Color:
	match faction:
		1: return _SABLE_BORDER_HOT
		2: return _INHERITOR_BORDER_HOT
		3: return _HELIARCH_BORDER_HOT
		_: return _ANVIL_BORDER_HOT


static func border_dim(faction: int) -> Color:
	match faction:
		1: return _SABLE_BORDER_DIM
		2: return _INHERITOR_BORDER_DIM
		3: return _HELIARCH_BORDER_DIM
		_: return _ANVIL_BORDER_DIM


static func text_color(faction: int) -> Color:
	match faction:
		1: return _SABLE_TEXT
		2: return _INHERITOR_TEXT
		3: return _HELIARCH_TEXT
		_: return _ANVIL_TEXT


static func text_dim(faction: int) -> Color:
	match faction:
		1: return _SABLE_TEXT_DIM
		2: return _INHERITOR_TEXT_DIM
		3: return _HELIARCH_TEXT_DIM
		_: return _ANVIL_TEXT_DIM


static func make_button_normal(faction: int) -> StyleBoxTexture:
	## Faction-textured button background. The role-color tint that
	## used to be flat-painted on top of this is now drawn separately
	## as L-shaped corner brackets via RoleCornerBrackets.
	# Corner radius doctrine per faction:
	#   Anvil — rounded plate (3 px) for industrial weight
	#   Sable — square chamfer (0) for corpo sleekness
	#   Inheritor — rounded (4 px) for cathedral / reliquary read
	#   Heliarch — square (0) for improvised camp / brass-bolted plates
	var corner_r: int = 0
	match faction:
		0: corner_r = 3
		2: corner_r = 4
	return _make_textured_box(
		FactionUITextures.get_button_face(faction),
		border_color(faction),
		2,
		corner_r,
	)


static func make_button_hover(faction: int) -> StyleBoxTexture:
	var box: StyleBoxTexture = make_button_normal(faction)
	box.modulate_color = Color(1.15, 1.15, 1.15, 1.0)
	return box


static func make_button_pressed(faction: int) -> StyleBoxTexture:
	var box: StyleBoxTexture = make_button_normal(faction)
	box.modulate_color = Color(0.78, 0.78, 0.78, 1.0)
	return box


static func make_button_disabled(faction: int) -> StyleBoxFlat:
	## Disabled buttons drop the texture for a flat dark fill so
	## locked-tier entries read as inert at a glance. Border keeps
	## the faction color for category continuity.
	var box := StyleBoxFlat.new()
	match faction:
		1: box.bg_color = _SABLE_DISABLED_BG
		2: box.bg_color = _INHERITOR_DISABLED_BG
		3: box.bg_color = _HELIARCH_DISABLED_BG
		_: box.bg_color = _ANVIL_DISABLED_BG
	var bd: Color = border_dim(faction)
	box.border_color = bd
	box.border_width_top = 1
	box.border_width_bottom = 1
	box.border_width_left = 1
	box.border_width_right = 1
	# Corner radius matches make_button_normal's per-faction doctrine.
	match faction:
		0: box.set_corner_radius_all(3)
		2: box.set_corner_radius_all(4)
	box.content_margin_left = 6
	box.content_margin_right = 6
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


static func make_panel(faction: int) -> StyleBoxTexture:
	## Background for selection / info panels. Larger texture, slightly
	## thicker border so the panel reads as substantial chrome behind
	## the buttons it hosts.
	var corner_r: int = 0
	match faction:
		0: corner_r = 4
		2: corner_r = 5  # Inheritor cathedral arch hint
	return _make_textured_box(
		FactionUITextures.get_panel_face(faction),
		border_color(faction),
		3,
		corner_r,
	)


static func make_top_bar(faction: int) -> StyleBoxTexture:
	## Wide banner used for the top resource bar. Border lives only
	## along the bottom edge so the banner blends with the screen
	## edge above and reads as a docked HUD strip.
	var box := StyleBoxTexture.new()
	box.texture = FactionUITextures.get_top_bar(faction)
	box.modulate_color = Color.WHITE
	box.draw_center = true
	box.set_content_margin_all(8)
	return box


static func make_tooltip_panel(faction: int) -> StyleBoxTexture:
	var corner_r: int = 0
	match faction:
		0: corner_r = 3
		2: corner_r = 4
	return _make_textured_box(
		FactionUITextures.get_panel_face(faction),
		border_color(faction),
		2,
		corner_r,
	)


# ---------------------------------------------------------------- helpers

static func _make_textured_box(tex: Texture2D, border: Color, border_w: int, corner_radius: int) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = tex
	box.modulate_color = Color.WHITE
	# Texture is sampled tiled so the rivet / hex pattern continues
	# beyond the source texture's bounds when the button is bigger.
	# Godot 4's enum is AXIS_STRETCH_MODE_TILE (not AXIS_STRETCH_TILE
	# as in 3.x) -- the wrong constant name killed StyleBoxTexture
	# compilation, which cascaded through every HUD helper that
	# referenced FactionUIStyle.
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	# Texture margin: how many pixels from each edge of the source
	# texture are treated as the corner / edge ring (NOT the centre
	# tile). Keeps the rivets glued to the corners as the button
	# resizes.
	box.texture_margin_left = 12
	box.texture_margin_right = 12
	box.texture_margin_top = 12
	box.texture_margin_bottom = 12
	# Content margin: where text / children sit inside the box. We
	# need extra inside breathing room so role-color corner brackets
	# don't crowd the label.
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	# StyleBoxTexture has no border_color directly; we layer a thin
	# StyleBoxFlat outline by wrapping in a CanvasItem _draw on the
	# button is overkill -- instead we let the texture's pre-baked
	# trim carry the border. The border_w + corner_radius args are
	# kept on the API so callers can future-swap to StyleBoxFlat
	# borders without changing the call site.
	# Suppress the unused-arg warning by no-op-touching.
	var _w: int = border_w
	var _r: int = corner_radius
	var _b: Color = border
	return box
