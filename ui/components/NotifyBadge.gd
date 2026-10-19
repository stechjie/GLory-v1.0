extends Control

# 页签 / 按钮右上角的提醒角标。两种形态：
#   · dot   —— 一颗**金色**小点：「这里有东西」（例：队伍有升级石，但现在还没有能升 4★ 的棋子）
#   · count —— **红底白字**的数字：「这里有 N 件能做的事」（例：有 N 枚三星现在就能升 4★）
#
# 颜色不单独表达信息（game-ui-design 的 Color-Only Information 那条）：金点与红色数字
# 除了颜色，形状大小也不同 —— 一个是无字的小点，一个是带数字的圆。
#
# 纯 `_draw()` + 一个 Label：不碰 StyleBoxFlat.new() / Button.new()（procedural_ui_ratchet）。

const DOT_SIZE := 12.0
const COUNT_SIZE := 24.0
const DOT_COLOR := Color(1.0, 0.80, 0.30)
const COUNT_COLOR := Color(0.88, 0.20, 0.18)
const RING_COLOR := Color(0.06, 0.05, 0.03, 0.95)

var _count := 0
var _label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 钉在宿主右上角，并往外探出一半 —— 角标压在按钮的角上，而不是缩在按钮里面。
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_label)
	show_dot()


func show_dot() -> void:
	_count = 0
	_resize(DOT_SIZE)
	_label.visible = false
	queue_redraw()


func show_count(count: int) -> void:
	_count = maxi(1, count)
	_resize(COUNT_SIZE)
	_label.text = str(_count) if _count < 10 else "9+"
	_label.visible = true
	queue_redraw()


func _resize(diameter: float) -> void:
	offset_left = -diameter * 0.75
	offset_right = diameter * 0.25
	offset_top = -diameter * 0.25
	offset_bottom = diameter * 0.75


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5
	# 深色描边圈：角标压在金色 / 草绿 / 深色任意底上都分得出边。
	draw_circle(center, radius + 2.0, RING_COLOR)
	draw_circle(center, radius, COUNT_COLOR if _count > 0 else DOT_COLOR)
