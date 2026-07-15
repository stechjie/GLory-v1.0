class_name FormationCrystal
extends Control

# A self-drawn glowing crystal for the formation HP display. Its glow, body
# brightness and orbiting light motes all scale with hp_ratio (1.0 -> full glow,
# 0.0 -> a dark, dead crystal). Drive it with set_hp_ratio(current_hp / max_hp).

const DEAD_COLOR := Color(0.20, 0.23, 0.27)

const REDRAW_INTERVAL := 1.0 / 15.0  # decorative pulse; 15Hz is indistinguishable and saves GPU

var base_color := Color(0.25, 0.65, 1.0)   # blue by default; enemy uses red
var hp_ratio := 1.0
var _t := 0.0
var _redraw_accum := 0.0

func _ready() -> void:
	custom_minimum_size = Vector2(56, 56)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)

func set_color(c: Color) -> void:
	base_color = c
	queue_redraw()

func set_hp_ratio(r: float) -> void:
	hp_ratio = clampf(r, 0.0, 1.0)
	queue_redraw()

func _process(delta: float) -> void:
	# Animate the pulse and orbiting motes only while the crystal is still lit.
	if hp_ratio > 0.0 and is_visible_in_tree():
		_t += delta
		_redraw_accum += delta
		if _redraw_accum >= REDRAW_INTERVAL:
			_redraw_accum = 0.0
			queue_redraw()

func _draw() -> void:
	var c := size * 0.5
	var r := hp_ratio
	var pulse := 1.0 + 0.06 * sin(_t * 2.5)

	# Glow halo: concentric translucent rings, fading with HP.
	if r > 0.0:
		for i in 4:
			var rad := (9.0 + float(i) * 6.0) * pulse
			var a := maxf(0.0, (0.24 - float(i) * 0.055) * r)
			draw_circle(c, rad, Color(base_color.r, base_color.g, base_color.b, a))

	# Crystal body — a vertical gem, brightness driven by HP.
	var col := DEAD_COLOR.lerp(base_color, r)
	var left_face := col.lightened(0.18)
	var right_face := col.darkened(0.35)
	var top := c + Vector2(0.0, -size.y * 0.40)
	var bot := c + Vector2(0.0, size.y * 0.42)
	var ul := c + Vector2(-size.x * 0.28, -size.y * 0.14)
	var ll := c + Vector2(-size.x * 0.28, size.y * 0.22)
	var ur := c + Vector2(size.x * 0.28, -size.y * 0.14)
	var lr := c + Vector2(size.x * 0.28, size.y * 0.22)
	draw_colored_polygon([top, ur, lr, bot], right_face)
	draw_colored_polygon([top, ul, ll, bot], left_face)

	# Bright inner core when healthy.
	if r > 0.0:
		draw_circle(c, size.x * 0.10 * pulse, Color(1.0, 1.0, 1.0, 0.5 * r))

	# Edge outline.
	var edge := col.lightened(0.35)
	edge.a = 0.55 + 0.45 * r
	var outline := PackedVector2Array([top, ur, lr, bot, ll, ul, top])
	draw_polyline(outline, edge, 1.5, true)

	# Highlight glint on the upper-left facet.
	if r > 0.0:
		var glint := Color(1.0, 1.0, 1.0, 0.45 * r)
		draw_line(top.lerp(ul, 0.25), top.lerp(ul, 0.85), glint, 1.5, true)

	# Orbiting light motes — count and opacity scale with HP.
	var motes := int(round(r * 5.0))
	for i in motes:
		var ang := _t * 0.8 + float(i) * TAU / 5.0
		var orbit := size.x * 0.42 + 3.0 * sin(_t * 1.5 + float(i))
		var p := c + Vector2(cos(ang), sin(ang)) * orbit
		draw_circle(p, 1.6, Color(base_color.r, base_color.g, base_color.b, 0.8 * r))
