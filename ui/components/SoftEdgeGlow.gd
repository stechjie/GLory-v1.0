extends Control

# 「软边光」：给一个控件的外圈画一层会呼吸的亮边。
#
# 10.05 反馈第 4 条：宝藏选择页的刷新按钮不够突出，要「醒目且符合游戏风格的颜色 +
# 边缘光呼吸效果」。颜色部分由 PrepWidgets.apply_refresh_button_styles 负责，这层光
# 由本节点负责。
#
# 纯 `_draw()` 画，**刻意不用 `Panel` + `StyleBoxFlat(draw_center=false, shadow_*)`**：
# 本仓有 procedural_ui_ratchet 棘轮 —— 业务代码里的 `StyleBoxFlat.new()` 只能下降，
# 而且按文件记账。用 StyleBoxFlat 实现这层光会把棘轮顶红，所以走纯绘制。
#
# 呼吸由调用方对 `modulate:a` 做 Tween（见 TreasureChoicePanel._start_refresh_glow）——
# 本节点只管「长什么样」，不管动效，也就不必关心自己进没进树。

const RoundedRectDraw := preload("res://ui/components/RoundedRectDraw.gd")

# 外圈 5 环、每环外扩 3px：够软，又不会糊一大团。
const GLOW_RINGS := 5
const RING_STEP := 3.0

var edge_color := Color(1.0, 0.86, 0.42)
var glow_color := Color(1.0, 0.66, 0.18, 0.38)
var corner_radius := 11.0
var edge_width := 2.0


func _ready() -> void:
	# 光的本体不该吃输入 —— 按钮的点击必须照常落到按钮上。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show_behind_parent = true
	resized.connect(queue_redraw)


func _draw() -> void:
	var box := Rect2(Vector2.ZERO, size)
	RoundedRectDraw.draw_soft_glow(self, box, corner_radius, glow_color, GLOW_RINGS, RING_STEP, edge_width)
	draw_polyline(RoundedRectDraw.closed(RoundedRectDraw.rounded_rect(box, corner_radius)),
		edge_color, edge_width, true)
