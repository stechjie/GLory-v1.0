extends Control
## 战斗开场字幕：只保留金色文字，不加背景、装饰、描边或阴影。

var _label: Label
var _punch: Tween
var phase := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 100
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Color("ffe6a0"))
	add_child(_label)
	resized.connect(_layout)
	_layout()

func _layout() -> void:
	if _label == null:
		return
	var factor := clampf(minf(size.x / 1280.0, size.y / 720.0), 0.45, 2.0)
	_label.add_theme_font_size_override("font_size", int(100.0 * factor))
	_label.size = Vector2(560, 170) * factor
	_label.position = (size - _label.size) * 0.5
	_label.pivot_offset = _label.size * 0.5

func show_phase(value: String) -> void:
	phase = value
	_label.text = value
	if _punch != null:
		_punch.kill()
	_label.scale = Vector2.ONE * 1.22
	_punch = create_tween()
	_punch.tween_property(_label, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
