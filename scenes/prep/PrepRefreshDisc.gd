extends Control

# 商店刷新键圆框里面的羊皮纸底（11.12）。
#
# 圆框图（assets/ui/prep_buttons/refresh_ring.png，360×340）中间是全透明的，
# 底色在这里画：跟摆放界面那排新按钮同一种纸色（#eec79b，从按钮图上取的），
# 边上一圈往里收的淡阴影，像压进金框里的一张纸。
# 位置按圆框图里洞的位置算（洞心 189,171、半径 133），跟圆框用同一种「保持比例居中」缩放。

const RING_SIZE := Vector2(360.0, 340.0)
const HOLE_CENTER := Vector2(189.0, 171.0)
const HOLE_RADIUS := 133.0
const PAPER := Color("eec79b")
const PAPER_LIGHT := Color("f6dcb5")
const SHADE := Color(0.55, 0.33, 0.12)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	var s := minf(size.x / RING_SIZE.x, size.y / RING_SIZE.y)
	var origin := (size - RING_SIZE * s) * 0.5
	var c := origin + HOLE_CENTER * s
	var r := (HOLE_RADIUS + 4.0) * s
	draw_circle(c, r, PAPER, true, -1.0, true)
	# 中间偏上一点亮，像光从上面打下来
	draw_circle(c + Vector2(0, -r * 0.18), r * 0.62, Color(PAPER_LIGHT, 0.55), true, -1.0, true)
	# 边缘往里收的阴影：几圈半透明描边叠出来
	for i in 6:
		var t := float(i) / 6.0
		draw_arc(c, r * (1.0 - t * 0.16), 0.0, TAU, 48, Color(SHADE, 0.16 * (1.0 - t)), r * 0.06, true)
