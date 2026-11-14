extends Control

# Decorative state only: 0 = idle, 1 = ready, 2 = loading.
# Insert before the button artwork. Front strokes use z=1; text uses z=2.
const MAGIC_RING := preload("res://assets/ui/buttons/ready_loading_rune.png")
const SEGMENTS := 64
const FRAME_STEP := 1.0 / 30.0
# Layered golden body and additive pale-hot light,
# adapted to 2D: no dependency on battle state or 3D glow/postprocessing.
const CRIMSON := Color(1.0, 0.67, 0.08)
const HOT := Color(1.0, 0.96, 0.65)
var _mode := 0
var _phase := 0.0
var _elapsed := 0.0
var _loading := 0.0
var _opacity := 0.0
var _draw_elapsed := 0.0
var _rear: GlowLayer
var _front: GlowLayer
var _rear_light: GlowLayer
var _front_light: GlowLayer

class GlowLayer extends Control:
	var effect: Control
	var front := false
	var light := false
	func _draw() -> void:
		effect.paint_layer(self, front, light)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rear = GlowLayer.new()
	_rear.effect = self
	_rear.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rear)
	_rear.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_front = GlowLayer.new()
	_front.effect = self
	_front.front = true
	_front.z_index = 1
	_front.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_front)
	_front.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rear_light = _make_light_layer(false)
	_front_light = _make_light_layer(true)
	resized.connect(_redraw)
	visible = _mode != 0
	set_process(_mode != 0)

func _make_light_layer(front: bool) -> GlowLayer:
	var layer := GlowLayer.new()
	layer.effect = self
	layer.front = front
	layer.light = true
	layer.z_index = 1 if front else 0
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	layer.material = additive
	add_child(layer)
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return layer

func set_mode(mode: int) -> void:
	mode = clampi(mode, 0, 2)
	if _mode == mode:
		return
	_mode = mode
	if mode == 0:
		_opacity = 0.0
		_loading = 0.0
		visible = false
		set_process(false)
	else:
		visible = true
		set_process(true)
	# Do not restart phase when ready becomes loading or the label refreshes.
	_redraw()

func _process(delta: float) -> void:
	_elapsed += delta
	_phase = fposmod(_phase + delta * lerpf(1.1, 1.5, _loading), TAU)
	_opacity = move_toward(_opacity, 1.0, delta * 5.0)
	_loading = move_toward(_loading, 1.0 if _mode == 2 else 0.0, delta * 3.0)
	_draw_elapsed += delta
	if _draw_elapsed >= FRAME_STEP:
		_draw_elapsed = fmod(_draw_elapsed, FRAME_STEP)
		_redraw()

func _redraw() -> void:
	if is_instance_valid(_rear):
		_rear.queue_redraw()
		_front.queue_redraw()
		if is_instance_valid(_rear_light):
			_rear_light.queue_redraw()
			_front_light.queue_redraw()

func _point(angle: float, orbit: int) -> Vector2:
	var x := cos(angle) * size.x * (0.55 if orbit == 0 else 0.53)
	var y := sin(angle) * size.y * (0.36 if orbit == 0 else 0.31)
	return size * 0.5 + Vector2(x, y + x * (-0.105 if orbit == 0 else 0.105))

func paint_layer(layer: Control, front: bool, light: bool) -> void:
	if _mode == 0 or size.x <= 0.0:
		return
	if not front and not light and _loading > 0.001:
		# The sprite includes a transparent outer margin; the luminous rim fits
		# between the screen edge and round label without moving the button.
		var diameter := minf(size.y * 1.16, size.x * 0.5)
		layer.draw_set_transform(size * 0.5 + Vector2(0, 2), _elapsed * 0.32)
		layer.draw_texture_rect(MAGIC_RING, Rect2(Vector2.ONE * -diameter * 0.5,
			Vector2.ONE * diameter), false, Color(1.0, 0.91, 0.65, _loading * _opacity))
		layer.draw_set_transform(Vector2.ZERO)
	for orbit in 2:
		var head := _phase + float(orbit) * PI
		for i in SEGMENTS:
			var a := TAU * float(i) / float(SEGMENTS)
			var b := TAU * float(i + 1) / float(SEGMENTS)
			if (sin((a + b) * 0.5) >= 0.0) != front:
				continue
			var trail := 1.0 - fposmod(head - a, TAU) / TAU
			var alpha := (0.48 + 0.52 * pow(trail, 4.0)) * _opacity
			var p := _point(a, orbit)
			var q := _point(b, orbit)
			if light:
				# Soft golden fringe plus a narrow, travelling white-hot core.
				layer.draw_line(p, q, Color(1.0, 0.61, 0.05, alpha * 0.12), 11.0 + _loading * 2.0, true)
				layer.draw_line(p, q, Color(1.0, 0.78, 0.16, alpha * 0.23), 6.0, true)
				var hot := Color(1.0, 0.84, 0.38).lerp(HOT, pow(trail, 4.0))
				layer.draw_line(p, q, Color(hot, (0.66 + 0.25 * trail) * _opacity), 1.1 + _loading * 0.4, true)
			else:
				layer.draw_line(p, q, Color(0.32, 0.16, 0.01, 0.35 * _opacity), 5.2, true)
				layer.draw_line(p, q, Color(CRIMSON, 0.88 * _opacity), 3.0 + _loading * 0.5, true)
		if light and (sin(head) >= 0.0) == front:
			_spark(layer, _point(head, orbit), 1.0 + _loading * 0.25)
	# Three small faceted pink crystals follow the rails, passing behind the
	# button on the rear half. They never block the input or the text.
	if light:
		return
	for i in 3:
		var angle := _phase * 0.72 + float(i) * TAU / 3.0 + 0.7
		if (sin(angle) >= 0.0) == front:
			_crystal(layer, _point(angle, i % 2), 4.0 + float(i % 2) * 1.5, angle * 0.25)
	# Sparse glints sit around the rails, not across the label's center.
	for i in 6:
		var angle := _phase * 0.46 + float(i) * TAU / 6.0
		if (sin(angle) >= 0.0) == front:
			var p := _point(angle, i % 2)
			var glint := 0.35 + 0.65 * pow(0.5 + 0.5 * sin(_elapsed * 3.2 + i), 4.0)
			layer.draw_circle(p, 1.2, Color(HOT, glint * _opacity), true, -1.0, true)

func _spark(layer: Control, p: Vector2, power: float) -> void:
	layer.draw_circle(p, 6.0 * power, Color(1.0, 0.57, 0.06, 0.24 * _opacity), true, -1.0, true)
	layer.draw_circle(p, 3.0 * power, Color(1.0, 0.82, 0.28, 0.55 * _opacity), true, -1.0, true)
	layer.draw_circle(p, 1.6, Color(1.0, 0.99, 0.82, _opacity), true, -1.0, true)
	layer.draw_line(p - Vector2(4, 0), p + Vector2(4, 0), Color(HOT, 0.9 * _opacity), 1.0, true)

func _crystal(layer: Control, p: Vector2, radius: float, angle: float) -> void:
	var points := PackedVector2Array()
	for v in [Vector2(0, -1.7), Vector2(0.8, -0.45), Vector2(0.6, 0.8), Vector2(0, 1.6), Vector2(-0.8, 0.4), Vector2(-0.6, -0.8)]:
		points.append(p + (v * radius).rotated(angle))
	layer.draw_circle(p, radius * 1.7, Color(1.0, 0.33, 0.48, 0.16 * _opacity), true, -1.0, true)
	layer.draw_colored_polygon(points, Color(0.96, 0.30, 0.48, _opacity))
	layer.draw_colored_polygon(PackedVector2Array([points[0], points[1], p, points[5]]), Color(1.0, 0.78, 0.86, _opacity))
	layer.draw_colored_polygon(PackedVector2Array([points[1], points[2], points[3], p]), Color(0.74, 0.15, 0.36, _opacity))
	points.append(points[0])
	layer.draw_polyline(points, Color(1.0, 0.81, 0.87, _opacity), 0.8, true)
