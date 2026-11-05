extends Control
# 选宝卡的卡框，全部用代码画（不用任何贴图）。
#
# 坐标写在 600×800 的卡面空间里，_draw 时按实际尺寸等比缩放、居中。
# 颜色按宝藏类别取（攻击红 / 防御蓝 / 控制紫 / 金钱金 / 元素青），一眼能分出类别。
# 图标、名字、效果、徽记不在这里画，由 TreasureCardView 叠在上面；
# 这里只提供它们该放在哪（ICON_CENTER / NAME_Y / MEDAL_CENTER 等常量）。

const CARD := Vector2(600.0, 800.0)

const ACCENT := {
	"attack": Color("e0503f"),
	"defense": Color("4f93e0"),
	"control": Color("a066e0"),
	"money": Color("e8b030"),
	"element": Color("2fc0a8"),
}
const GOLD_HI := Color("ffe9a8")
const GOLD := Color("d9a441")
const GOLD_DARK := Color("7a5418")
const BODY_TOP := Color("2a2230")
const BODY_BOTTOM := Color("140f18")

const OUTER_CHAMFER := 34.0
const TRIM_INSET := 14.0
const PANEL_RECT := Rect2(40.0, 52.0, 520.0, 640.0)
const PANEL_CHAMFER := 22.0

const ICON_CENTER := Vector2(300.0, 250.0)
const ICON_GLOW_RADIUS := 190.0
const NAME_Y := 470.0          # 名字中线
const DIVIDER_Y := 512.0
const MEDAL_CENTER := Vector2(300.0, 724.0)
const MEDAL_RADIUS := 66.0

var category := "attack"
# 动画时间（秒）与相位，由 TreasureCardView 每帧推进；静止时保持 0。
var anim_time := 0.0
var anim_phase := 0.0
var animated := false

const MOTE_COUNT := 9


func set_category(value: String) -> void:
	category = value
	queue_redraw()


func accent() -> Color:
	return ACCENT.get(category, GOLD)


# 卡面空间 → 本控件局部坐标的缩放与原点。
func card_scale() -> float:
	return minf(size.x / CARD.x, size.y / CARD.y)


func card_origin() -> Vector2:
	return (size - CARD * card_scale()) * 0.5


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var s := card_scale()
	if s <= 0.0:
		return
	draw_set_transform(card_origin(), 0.0, Vector2(s, s))
	var a := accent()
	var outer := Rect2(Vector2.ZERO, CARD)

	# 投影
	for i in 6:
		var grow := 4.0 + float(i) * 4.0
		_fill(_chamfer(outer.grow(grow), OUTER_CHAMFER + grow), Color(0, 0, 0, 0.07))

	# 卡身：深色竖向渐变
	_gradient(_chamfer(outer, OUTER_CHAMFER), BODY_TOP, BODY_BOTTOM)

	# 双层金边：外亮内暗
	_outline(_chamfer(outer.grow(-4.0), OUTER_CHAMFER - 2.0), GOLD_DARK, 6.0)
	_outline(_chamfer(outer.grow(-6.0), OUTER_CHAMFER - 3.0), GOLD, 3.0)
	_outline(_chamfer(outer.grow(-TRIM_INSET), OUTER_CHAMFER - 8.0), a.darkened(0.25), 2.0)

	# 面板：类别色压暗的渐变 + 图标后光晕
	var panel := _chamfer(PANEL_RECT, PANEL_CHAMFER)
	_gradient(panel, a.darkened(0.62), Color("100c14"))
	# 光晕随时间一明一暗（约 3.6 秒一个来回）
	var pulse := 1.0
	if animated:
		pulse = 0.78 + 0.22 * sin(anim_time * 1.75 + anim_phase)
	for i in 28:
		var t := float(i) / 27.0
		draw_circle(ICON_CENTER, ICON_GLOW_RADIUS * (1.0 - t * 0.85) * (0.96 + 0.04 * pulse), Color(a.r, a.g, a.b, (0.035 + t * 0.02) * pulse))
	if animated:
		_draw_motes(a)
	_outline(panel, GOLD_DARK, 4.0)
	_outline(_chamfer(PANEL_RECT.grow(-3.0), PANEL_CHAMFER - 1.0), Color(GOLD.r, GOLD.g, GOLD.b, 0.55), 1.5)

	# 名字下的分隔线 + 中间小菱形
	var half := 170.0
	draw_line(Vector2(300.0 - half, DIVIDER_Y), Vector2(288.0, DIVIDER_Y), GOLD, 2.0, true)
	draw_line(Vector2(312.0, DIVIDER_Y), Vector2(300.0 + half, DIVIDER_Y), GOLD, 2.0, true)
	_gem(Vector2(300.0, DIVIDER_Y), 9.0, a)

	# 四角宝石
	var c := OUTER_CHAMFER + 4.0
	for p in [Vector2(c, c), Vector2(CARD.x - c, c), Vector2(c, CARD.y - c), Vector2(CARD.x - c, CARD.y - c)]:
		_gem(p, 11.0, a)

	# 顶部尖角徽章
	var crest := PackedVector2Array([Vector2(258, 0), Vector2(342, 0), Vector2(322, 30), Vector2(300, 46), Vector2(278, 30)])
	_fill(crest, GOLD_DARK)
	var crest_in := PackedVector2Array([Vector2(266, 3), Vector2(334, 3), Vector2(317, 27), Vector2(300, 40), Vector2(283, 27)])
	_gradient(crest_in, GOLD_HI, GOLD)
	_gem(Vector2(300, 18), 9.0, a)

	# 底部徽章：金圈 + 深色章面（徽记由 TreasureCardView 叠上）
	draw_circle(MEDAL_CENTER, MEDAL_RADIUS + 10.0, GOLD_DARK)
	draw_circle(MEDAL_CENTER, MEDAL_RADIUS + 7.0, GOLD)
	draw_circle(MEDAL_CENTER, MEDAL_RADIUS + 2.0, GOLD_DARK)
	draw_circle(MEDAL_CENTER, MEDAL_RADIUS, Color("1b1520"))
	draw_arc(MEDAL_CENTER, MEDAL_RADIUS - 6.0, 0.0, TAU, 64, Color(a.r, a.g, a.b, 0.55), 2.0, true)
	draw_arc(MEDAL_CENTER, MEDAL_RADIUS + 7.0, PI * 1.15, PI * 1.6, 24, GOLD_HI, 2.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 图标周围缓缓上飘的光点：每颗有自己的起点、周期和摆动，淡入淡出。
func _draw_motes(a: Color) -> void:
	for i in MOTE_COUNT:
		var seed := float(i) * 1.618 + anim_phase
		var period := 3.2 + fmod(seed * 7.3, 2.2)
		var t := fmod(anim_time / period + fmod(seed * 3.1, 1.0), 1.0)
		var x := ICON_CENTER.x + (fmod(seed * 97.0, 300.0) - 150.0) + sin(anim_time * 1.3 + seed * 5.0) * 10.0
		var y := lerpf(ICON_CENTER.y + 150.0, ICON_CENTER.y - 170.0, t)
		var fade := sin(t * PI)
		var r := 2.2 + fmod(seed * 13.0, 2.6)
		var col := a.lightened(0.45)
		draw_circle(Vector2(x, y), r * 2.4, Color(col.r, col.g, col.b, 0.10 * fade))
		draw_circle(Vector2(x, y), r, Color(col.r, col.g, col.b, 0.75 * fade))


# 切角矩形（八边形）。
func _chamfer(r: Rect2, c: float) -> PackedVector2Array:
	var x0 := r.position.x
	var y0 := r.position.y
	var x1 := r.end.x
	var y1 := r.end.y
	return PackedVector2Array([
		Vector2(x0 + c, y0), Vector2(x1 - c, y0), Vector2(x1, y0 + c), Vector2(x1, y1 - c),
		Vector2(x1 - c, y1), Vector2(x0 + c, y1), Vector2(x0, y1 - c), Vector2(x0, y0 + c),
	])


func _fill(pts: PackedVector2Array, col: Color) -> void:
	draw_colored_polygon(pts, col)


# 竖向渐变：按每个顶点的高度插值颜色。
func _gradient(pts: PackedVector2Array, top: Color, bottom: Color) -> void:
	var y_min := INF
	var y_max := -INF
	for p in pts:
		y_min = minf(y_min, p.y)
		y_max = maxf(y_max, p.y)
	var cols := PackedColorArray()
	for p in pts:
		cols.append(top.lerp(bottom, (p.y - y_min) / maxf(y_max - y_min, 1.0)))
	draw_polygon(pts, cols)


func _outline(pts: PackedVector2Array, col: Color, width: float) -> void:
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, col, width, true)


# 菱形宝石：金边 + 类别色 + 左上高光。
func _gem(center: Vector2, r: float, col: Color) -> void:
	var outer := PackedVector2Array([center + Vector2(0, -r - 3), center + Vector2(r + 3, 0), center + Vector2(0, r + 3), center + Vector2(-r - 3, 0)])
	_fill(outer, GOLD_DARK)
	var inner := PackedVector2Array([center + Vector2(0, -r), center + Vector2(r, 0), center + Vector2(0, r), center + Vector2(-r, 0)])
	_gradient(inner, col.lightened(0.35), col.darkened(0.35))
	var hi := PackedVector2Array([center + Vector2(0, -r * 0.8), center + Vector2(r * 0.35, -r * 0.3), center + Vector2(-r * 0.35, -r * 0.3)])
	_fill(hi, Color(1, 1, 1, 0.55))
