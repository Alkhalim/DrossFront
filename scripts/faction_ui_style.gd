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

# --- Anvil palette ---
const _ANVIL_BORDER: Color       = Color(0.55, 0.46, 0.30, 1.0)  # brass
const _ANVIL_BORDER_HOT: Color   = Color(0.85, 0.70, 0.40, 1.0)  # hover
const _ANVIL_BORDER_DIM: Color   = Color(0.30, 0.25, 0.18, 1.0)  # disabled
const _ANVIL_PRESS_TINT: Color   = Color(0.65, 0.55, 0.40, 1.0)  # pressed flash
const _ANVIL_DISABLED_BG: Color  = Color(0.20, 0.18, 0.16, 0.85)
const _ANVIL_TEXT: Color         = Color(0.95, 0.92, 0.82, 1.0)
const _ANVIL_TEXT_DIM: Color     = Color(0.60, 0.55, 0.45, 1.0)

# --- Sable palette ---
const _SABLE_BORDER: Color       = Color(0.78, 0.42, 1.00, 1.0)  # violet emissive
const _SABLE_BORDER_HOT: Color   = Color(0.92, 0.65, 1.00, 1.0)
const _SABLE_BORDER_DIM: Color   = Color(0.30, 0.18, 0.42, 1.0)
const _SABLE_PRESS_TINT: Color   = Color(0.95, 0.55, 1.00, 1.0)
const _SABLE_DISABLED_BG: Color  = Color(0.06, 0.06, 0.10, 0.85)
const _SABLE_TEXT: Color         = Color(0.92, 0.90, 0.98, 1.0)
const _SABLE_TEXT_DIM: Color     = Color(0.55, 0.50, 0.65, 1.0)


# ---------------------------------------------------------------- API

static func border_color(faction: int) -> Color:
	return _SABLE_BORDER if faction == 1 else _ANVIL_BORDER


static func border_hot(faction: int) -> Color:
	return _SABLE_BORDER_HOT if faction == 1 else _ANVIL_BORDER_HOT


static func border_dim(faction: int) -> Color:
	return _SABLE_BORDER_DIM if faction == 1 else _ANVIL_BORDER_DIM


static func text_color(faction: int) -> Color:
	return _SABLE_TEXT if faction == 1 else _ANVIL_TEXT


static func text_dim(faction: int) -> Color:
	return _SABLE_TEXT_DIM if faction == 1 else _ANVIL_TEXT_DIM


static func make_button_normal(faction: int) -> StyleBoxTexture:
	## Faction-textured button background. The role-color tint that
	## used to be flat-painted on top of this is now drawn separately
	## as L-shaped corner brackets via RoleCornerBrackets.
	return _make_textured_box(
		FactionUITextures.get_button_face(faction),
		border_color(faction),
		2,
		3 if faction == 0 else 0,  # Anvil rounded plate, Sable square chamfer
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
	box.bg_color = _SABLE_DISABLED_BG if faction == 1 else _ANVIL_DISABLED_BG
	var bd: Color = border_dim(faction)
	box.border_color = bd
	box.border_width_top = 1
	box.border_width_bottom = 1
	box.border_width_left = 1
	box.border_width_right = 1
	if faction == 0:
		box.set_corner_radius_all(3)
	box.content_margin_left = 6
	box.content_margin_right = 6
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


static func make_panel(faction: int) -> StyleBoxTexture:
	## Background for selection / info panels. Larger texture, slightly
	## thicker border so the panel reads as substantial chrome behind
	## the buttons it hosts.
	return _make_textured_box(
		FactionUITextures.get_panel_face(faction),
		border_color(faction),
		3,
		4 if faction == 0 else 0,
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
	return _make_textured_box(
		FactionUITextures.get_panel_face(faction),
		border_color(faction),
		2,
		3 if faction == 0 else 0,
	)


# ---------------------------------------------------------------- helpers

static func _make_textured_box(tex: Texture2D, border: Color, border_w: int, corner_radius: int) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = tex
	box.modulate_color = Color.WHITE
	# Texture is sampled tiled so the rivet / hex pattern continues
	# beyond the source texture's bounds when the button is bigger.
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_TILE
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_TILE
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
