extends Control

# 母灵（undead_mother）击杀计数：血条正上方一排魂火，亮几盏 = 当前计数，总盏数 = 触发阈值
# （数据 death_threshold × 亡灵羁绊系数，四星 4 盏、其余 5 盏）。纯表现，数据来自模拟器
# 的展示字段 vfx_mother_count / vfx_mother_threshold（回放里走 undead_mother_count_events）。
# 计满触发处决时计数归零：所有魂火先一起爆亮、向上飘散，再回到全灭的空槽。
# 与赤律族徽章一样挂在单位 2D 根节点上，跟随血条、随死亡一起淡出。

const MAX_PIPS := 8
const WIDTH := 72.0
const HEIGHT := 16.0
const LIT := Color(0.42, 1.0, 0.70)
const LIT_CORE := Color(0.90, 1.0, 0.94)
const DIM := Color(0.10, 0.26, 0.20, 0.85)
const RIM := Color(0.02, 0.10, 0.07, 0.95)

var _count := 0
var _threshold := 0
var _clock := 0.0
var _pop_index := -1
var _pop_age := 9.0
var _burst_age := 9.0
var _burst_count := 0
var _count_label: Label


func _ready() -> void:
	name = "MotherSoulBadge"
	position = Vector2(5, -12)
	size = Vector2(WIDTH, HEIGHT)
	z_index = 22
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_count_label = Label.new()
	_count_label.name = "Count"
	_count_label.position = Vector2(WIDTH - 22, -3)
	_count_label.size = Vector2(26, 18)
	_count_label.add_theme_font_size_override("font_size", 11)
	_count_label.add_theme_color_override("font_color", LIT)
	_count_label.add_theme_color_override("font_outline_color", RIM)
	_count_label.add_theme_constant_override("outline_size", 3)
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_label.visible = false
	add_child(_count_label)
	set_process(false)


func set_counter(count: int, threshold: int) -> void:
	var next_threshold := maxi(0, threshold)
	var next_count := clampi(count, 0, maxi(next_threshold, 0))
	if next_threshold == _threshold and next_count == _count:
		return
	if next_threshold == _threshold and next_count < _count:
		# 计数回落 = 处决触发（计满归零）。以「满格」状态爆一下再清空。
		_burst_count = _threshold
		_burst_age = 0.0
	elif next_count > _count:
		_pop_index = next_count - 1
		_pop_age = 0.0
	_count = next_count
	_threshold = next_threshold
	visible = _threshold > 0
	_count_label.visible = _threshold > MAX_PIPS
	_count_label.text = "%d/%d" % [_count, _threshold]
	set_process(visible)
	queue_redraw()


func get_counter() -> Vector2i:
	return Vector2i(_count, _threshold)


func _process(delta: float) -> void:
	_clock += delta
	_pop_age += delta
	_burst_age += delta
	queue_redraw()


func _draw() -> void:
	if _threshold <= 0:
		return
	var pips := mini(_threshold, MAX_PIPS)
	var span := WIDTH - (26.0 if _threshold > MAX_PIPS else 0.0)
	var step := minf(13.0, span / float(pips))
	var left := (span - step * float(pips - 1)) * 0.5
	var lit := mini(_count, pips) if _threshold <= MAX_PIPS else int(round(float(pips) * float(_count) / float(_threshold)))
	var bursting := _burst_age < 0.55
	for i in pips:
		var center := Vector2(left + step * float(i), HEIGHT * 0.62)
		var on := i < lit
		var scale := 1.0
		var alpha := 1.0
		var rise := 0.0
		if on and i == _pop_index and _pop_age < 0.3:
			scale = 1.0 + 0.6 * sin(_pop_age / 0.3 * PI)
		if bursting and i < mini(_burst_count, pips):
			var b := _burst_age / 0.55
			on = true
			scale = 1.0 + 0.5 * b
			rise = 9.0 * b
			alpha = 1.0 - b
		var flicker := 0.85 + 0.15 * sin(_clock * 11.0 + float(i) * 1.7)
		_draw_flame(center + Vector2(0, -rise), 5.0 * scale * (flicker if on else 1.0), on, alpha)
		if bursting and i < mini(_burst_count, pips):
			_draw_flame(center, 5.0, false, 1.0 - alpha)


func _draw_flame(center: Vector2, r: float, on: bool, alpha: float) -> void:
	# 水滴形魂火：下圆上尖。
	var points := PackedVector2Array()
	for k in 14:
		var t := float(k) / 14.0 * TAU
		var p := Vector2(sin(t), -cos(t))
		var tip := clampf(-p.y, 0.0, 1.0)
		points.append(center + Vector2(p.x * r * (1.0 - 0.55 * tip), p.y * r * (1.0 + 0.9 * tip) + r * 0.25))
	var outline := points.duplicate()
	outline.append(points[0])
	if on:
		draw_colored_polygon(points, Color(LIT, alpha))
		var core := PackedVector2Array()
		for p in points:
			core.append(center + (p - center) * 0.45 + Vector2(0, r * 0.25))
		draw_colored_polygon(core, Color(LIT_CORE, alpha))
	else:
		draw_colored_polygon(points, Color(DIM, DIM.a * alpha))
	draw_polyline(outline, Color(RIM, RIM.a * alpha), 1.2, true)
