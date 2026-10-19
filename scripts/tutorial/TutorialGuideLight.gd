extends Control

# Presentation only. The tutorial target provider remains the sole source of
# target geometry; this node never intercepts or simulates an input event.
const PERIOD := 1.0
const TRAVEL_TIME := 0.66

var emitter := Vector2.ZERO
var target_rect := Rect2()
var reduced_motion := false
var _elapsed := 0.0
var _redraw_elapsed := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func aim(from_point: Vector2, to_rect: Rect2, reduce_motion: bool) -> void:
	emitter = from_point
	target_rect = to_rect
	reduced_motion = reduce_motion
	visible = to_rect.size.x > 0.0 and to_rect.size.y > 0.0
	queue_redraw()


func _process(delta: float) -> void:
	if not visible or reduced_motion:
		return
	_elapsed = fmod(_elapsed + delta, PERIOD)
	_redraw_elapsed += delta
	if _redraw_elapsed >= 1.0 / 30.0:
		_redraw_elapsed = 0.0
		queue_redraw()


func _curve_point(a: Vector2, b: Vector2, c: Vector2, d: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return a * u * u * u + b * 3.0 * u * u * t + c * 3.0 * u * t * t + d * t * t * t


func _draw() -> void:
	if target_rect.size.x <= 0.0 or target_rect.size.y <= 0.0:
		return
	var end := target_rect.get_center()
	var delta := end - emitter
	var bend := minf(95.0, delta.length() * 0.16)
	var side := -1.0 if delta.x >= 0.0 else 1.0
	var control_a := emitter + delta * 0.26 + Vector2(side * bend, -bend * 0.48)
	var control_b := emitter + delta * 0.76 + Vector2(-side * bend * 0.30, -bend * 0.18)
	var phase := 0.72 if reduced_motion else _elapsed / PERIOD
	var linear := clampf(phase / TRAVEL_TIME, 0.0, 1.0)
	var head_t := linear * linear * (3.0 - 2.0 * linear)
	var tail_t := maxf(0.0, head_t - 0.26)
	# Only the travelling burst is visible. Leave no guide rail after it arrives.
	var in_flight := reduced_motion or phase <= TRAVEL_TIME
	var fade := 1.0 if reduced_motion else minf(1.0, phase * 8.0)
	if in_flight:
		var moving := PackedVector2Array()
		for i in 13:
			moving.append(_curve_point(emitter, control_a, control_b, end,
				lerpf(tail_t, head_t, float(i) / 12.0)))
		draw_polyline(moving, Color(0.93, 0.53, 0.12, 0.12 * fade), 22.0, true)
		draw_polyline(moving, Color(1.0, 0.75, 0.30, 0.42 * fade), 9.0, true)
		draw_polyline(moving, Color(1.0, 0.96, 0.73, 0.95 * fade), 2.5, true)
	var head := _curve_point(emitter, control_a, control_b, end, head_t)
	for layer in 5:
		var radius := 24.0 - float(layer) * 4.5
		draw_circle(emitter, radius, Color(1.0, 0.69, 0.25, (0.025 + float(layer) * 0.012)))
		if in_flight:
			draw_circle(head, radius * 0.7, Color(1.0, 0.81, 0.43, (0.025 + float(layer) * 0.015) * fade))
	if in_flight:
		for i in 7:
			var t := maxf(0.0, head_t - float(i) * 0.032)
			var mote := _curve_point(emitter, control_a, control_b, end, t)
			var wobble := sin(float(i) * 7.3 + _elapsed * 17.0) * (2.0 + float(i) * 0.4)
			draw_circle(mote + Vector2(wobble, -wobble * 0.6), 2.8 - float(i) * 0.24,
				Color(1.0, 0.91, 0.64, 0.75 * fade))
	var impact := 0.0
	if not reduced_motion and phase > 0.62 and phase < 0.96:
		impact = sin((phase - 0.62) / 0.34 * PI)
	var base := target_rect.grow(8.0 + impact * 4.0)
	draw_rect(base.grow(8.0), Color(1.0, 0.70, 0.25, 0.10 + impact * 0.08), false, 12.0)
	draw_rect(base, Color(1.0, 0.88, 0.52, 0.80), false, 2.5 + impact * 1.5)
	if impact > 0.0:
		draw_rect(target_rect.grow(18.0 + impact * 9.0),
			Color(1.0, 0.88, 0.52, impact * 0.45), false, 2.0)
