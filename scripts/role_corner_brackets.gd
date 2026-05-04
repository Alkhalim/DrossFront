class_name RoleCornerBrackets
extends Control
## Translucent L-shaped corner brackets in a role color, drawn on top
## of a faction-styled button face so the button's category reads
## without burying the steel / cyber base texture.
##
## Usage:
##   var brackets := RoleCornerBrackets.new()
##   brackets.role_color = my_role_color
##   brackets.set_anchors_preset(Control.PRESET_FULL_RECT)
##   brackets.mouse_filter = Control.MOUSE_FILTER_IGNORE
##   button.add_child(brackets)
##
## The brackets are drawn into the button's own rect via _draw, so
## adding them as a full-rect child anchored to PRESET_FULL_RECT
## keeps them in sync automatically when the button resizes.
##
## `enabled = false` dims the brackets so locked / disabled buttons
## still convey their category but visibly de-emphasise it.

@export var role_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var enabled: bool = true:
	set(v):
		enabled = v
		queue_redraw()
@export var bracket_length: float = 14.0
@export var bracket_thickness: float = 2.0
@export var inset: float = 3.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# We drape over the parent button's full rect so corner positions
	# always match the button's edges.
	if get_parent() is Control:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		offset_left = 0.0
		offset_top = 0.0
		offset_right = 0.0
		offset_bottom = 0.0


func set_role(c: Color, is_enabled: bool) -> void:
	## Convenience setter so callers can update both fields with a
	## single call + queue_redraw().
	role_color = c
	enabled = is_enabled
	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var c: Color = role_color
	if not enabled:
		# Dim disabled brackets so locked tiles don't shout their
		# category. Halve alpha and desaturate slightly toward grey.
		c.a *= 0.45
	# Mounting socket -- darker recessed bed under each bracket so
	# the role colour reads as inset into the plate rather than as
	# a translucent overlay floating above it. Drawn first; the
	# bracket strokes layer on top with a tiny bright top-left
	# highlight pixel for the "stamped metal" emboss.
	var L: float = bracket_length
	var t: float = bracket_thickness
	var i: float = inset
	var socket: Color = Color(0.0, 0.0, 0.0, 0.55) if enabled else Color(0.0, 0.0, 0.0, 0.30)
	var hi: Color = Color(1.0, 1.0, 1.0, 0.30) if enabled else Color(1.0, 1.0, 1.0, 0.12)
	var pad: float = 1.0  # how much the socket extends past the bracket on each side
	# Each corner: socket bed (slightly larger), bracket strokes,
	# bright pixel highlight at the inner corner of the L.
	# Top-left
	draw_rect(Rect2(i - pad, i - pad, L + pad * 2.0, t + pad * 2.0), socket, true)
	draw_rect(Rect2(i - pad, i - pad, t + pad * 2.0, L + pad * 2.0), socket, true)
	draw_rect(Rect2(i, i, L, t), c, true)
	draw_rect(Rect2(i, i, t, L), c, true)
	draw_rect(Rect2(i, i, 1.0, 1.0), hi, true)
	# Top-right
	draw_rect(Rect2(size.x - i - L - pad, i - pad, L + pad * 2.0, t + pad * 2.0), socket, true)
	draw_rect(Rect2(size.x - i - t - pad, i - pad, t + pad * 2.0, L + pad * 2.0), socket, true)
	draw_rect(Rect2(size.x - i - L, i, L, t), c, true)
	draw_rect(Rect2(size.x - i - t, i, t, L), c, true)
	draw_rect(Rect2(size.x - i - 1.0, i, 1.0, 1.0), hi, true)
	# Bottom-left
	draw_rect(Rect2(i - pad, size.y - i - t - pad, L + pad * 2.0, t + pad * 2.0), socket, true)
	draw_rect(Rect2(i - pad, size.y - i - L - pad, t + pad * 2.0, L + pad * 2.0), socket, true)
	draw_rect(Rect2(i, size.y - i - t, L, t), c, true)
	draw_rect(Rect2(i, size.y - i - L, t, L), c, true)
	draw_rect(Rect2(i, size.y - i - 1.0, 1.0, 1.0), hi, true)
	# Bottom-right
	draw_rect(Rect2(size.x - i - L - pad, size.y - i - t - pad, L + pad * 2.0, t + pad * 2.0), socket, true)
	draw_rect(Rect2(size.x - i - t - pad, size.y - i - L - pad, t + pad * 2.0, L + pad * 2.0), socket, true)
	draw_rect(Rect2(size.x - i - L, size.y - i - t, L, t), c, true)
	draw_rect(Rect2(size.x - i - t, size.y - i - L, t, L), c, true)
	draw_rect(Rect2(size.x - i - 1.0, size.y - i - 1.0, 1.0, 1.0), hi, true)
