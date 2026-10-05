extends Control

# 备战界面棋盘正中的「已上阵 / 上阵上限」计数图案（10.05 反馈第 2 条）。
#
# 参考金铲铲的写法：数字前面是一个小小的「棋子」图标，整体取玩家位置对应的颜色
# （3v3 时是座位色，单机时是棋盘默认青色）。图案全部用矢量画出来，不新增图片素材。
#
# 它和 BoardReadabilityLayer 画的 16 个圆圈/光圈是**互斥**的：
#   * 平时（没在拖棋子）：只显示这个图案；
#   * 一开始拖动棋子上阵：圆圈与光圈出现，这个图案隐藏，辅助玩家看落点。
# 互斥由 PrepUI 同步 visible，本节点只管画自己。
#
# 做成独立节点而不是画进 BoardReadabilityLayer：可读性层能被玩家在设置里关掉
# （PlayerProfile.board_readability_enabled），而「我还能上几个」是核心信息，
# 不该跟着那个开关一起消失。
#
# ══ 10.05 第 2 条**返工**：它现在是**贴在地面上的 3D 图案**，不再是浮在画面上的徽章 ══
# 旧版把本节点直接 add_child 到 `_board_hud.grid`（z_index 6），而 3D 视口
# （PrepRiverArenaLayer）的 z_index 是 -19 —— 2D 层整块压在 3D 之上，于是这枚徽章
# **盖住了棋子**，而且看起来像贴纸浮在空中。
# 现在：本节点被塞进一个 SubViewport 渲成贴图，贴到 PrepBoardModels 建的
# 一块躺在地面上的 PlaneMesh 上（与 16 张站位图同一 y 层）。棋子是不透明 3D
# 物体、离相机更近，深度测试自然把它挡在身后 ⇒ 图案落在棋子脚下。
# 画布因此要比底板大一圈（GLOW_MARGIN），SubViewport 不会把外发光裁成直边。

const BADGE_SIZE := Vector2(138.0, 64.0)
const CORNER_RADIUS := 30
const TEXT_SIZE := 27
const ICON_WIDTH := 24.0
const ICON_GAP := 7.0
# 10.05 第 2 条返工：图案不再直接挂在 2D 层，而是渲进 SubViewport 再贴到地面上。
# SubViewport 会**在边界裁掉**越界像素，而外发光是往外画 3*3=9px 的，所以画布必须
# 比底板大一圈，否则最外那圈光被切成一条直边 —— 看起来就是"贴了一张方图在地上"，
# 正好是这次要除掉的突兀感。下面这个边距与 PrepBoardModels 的
# PREP_DEPLOY_COUNTER_VIEWPORT_SIZE(162×88) 一一对应，改一个必须改另一个。
const GLOW_MARGIN := 12.0
const CANVAS_SIZE := BADGE_SIZE + Vector2(GLOW_MARGIN, GLOW_MARGIN) * 2.0
# 面片在 3D 世界里的节点名（PrepBoardModels 建节点时用它）。
const NODE_NAME := "PrepDeployCounter"
# 图案全用 `_draw()` 画，**刻意不用 StyleBoxFlat**：本仓有 procedural_ui_ratchet
# 棘轮 —— 业务代码（scenes/ ui/ scripts/）里的 `StyleBoxFlat.new()` / `Button.new()`
# 只能下降，而且按文件记账（「总数没涨、换个文件写」同样判红）。这块图案正是新写在
# `scenes/prep/panels/` 下的，用 StyleBoxFlat 会直接把棘轮顶红。
# 圆角矩形与外发光的画法在 RoundedRectDraw 里，与宝藏页的刷新按钮外发光共用一份。
const GLOW_RINGS := 3
const GLOW_STEP := 3.0
const GLOW_ALPHA := 0.34
const BORDER_WIDTH := 2.0
# 底板透明度：用户 10.05 给的参考图（棋盘正中那枚图案）是**深色半透明底板 + 玩家色细描边
# + 一圈柔和外发光**，贴在草地上自然、又不至于看不清数字。照这个调，不另外发明风格。
const PLATE_BG := Color(0.045, 0.078, 0.070, 0.55)
const RoundedRectDraw := preload("res://ui/components/RoundedRectDraw.gd")

var _count := 0
var _cap := 0
var _color := Color(0.48, 1.0, 0.92, 0.55)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = CANVAS_SIZE
	size = CANVAS_SIZE
	# 尺寸变了要重画；否则换分辨率后还是按旧宽度摆字。
	resized.connect(queue_redraw)


func configure(count: int, cap: int, player_color: Color) -> void:
	var next_count := maxi(0, count)
	var next_cap := maxi(0, cap)
	if next_count == _count and next_cap == _cap and player_color == _color:
		return
	_count = next_count
	_cap = next_cap
	_color = player_color
	queue_redraw()


func deploy_text() -> String:
	return "%d/%d" % [_count, _cap]


func _draw() -> void:
	# 底板内缩一个发光边距，把外圈留给发光本身（见 GLOW_MARGIN 注释）。
	var box := Rect2(Vector2(GLOW_MARGIN, GLOW_MARGIN), BADGE_SIZE)
	var center := box.get_center()
	# 外发光：从外到内叠几圈描边，越外侧越淡 —— 顶替 StyleBoxFlat 的 shadow_size。
	RoundedRectDraw.draw_soft_glow(self, box, float(CORNER_RADIUS), _alpha(_color, GLOW_ALPHA),
		GLOW_RINGS, GLOW_STEP, BORDER_WIDTH)
	draw_colored_polygon(RoundedRectDraw.rounded_rect(box, float(CORNER_RADIUS)), PLATE_BG)
	draw_polyline(RoundedRectDraw.closed(RoundedRectDraw.rounded_rect(box, float(CORNER_RADIUS))),
		_alpha(_color, 0.92), BORDER_WIDTH, true)
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var text := deploy_text()
	var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_SIZE).x
	var total := ICON_WIDTH + ICON_GAP + text_width
	var left := center.x - total * 0.5
	# 垂直居中用 ascent/descent 算，而不是「半个字号的魔数」：
	# 这枚图案会被渲成贴图再贴到 3D 地面上，万一真机上视口贴图的 V 轴与普通贴图相反
	# （结构门禁测不到这一点），垂直居中的字在两版朝向里落点几乎一样 —— 别让文字
	# 先因为「偏上偏下」暴露出来。
	var baseline := center.y + (font.get_ascent(TEXT_SIZE) - font.get_descent(TEXT_SIZE)) * 0.5
	_draw_piece_icon(Vector2(left + ICON_WIDTH * 0.5, center.y))
	# 描边靠「同一串字画两遍」：先深色偏移一像素，再画亮色。
	draw_string(font, Vector2(left + ICON_WIDTH + ICON_GAP, baseline + 1.5), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_SIZE, Color(0.02, 0.045, 0.035, 0.92))
	draw_string(font, Vector2(left + ICON_WIDTH + ICON_GAP, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_SIZE, _text_color())


# 「棋子」剪影：圆头 + 收腰身体 + 底座。整体高度约 30px，宽约 20px。
func _draw_piece_icon(center: Vector2) -> void:
	var color := _text_color()
	var head_radius := 5.6
	var head_y := center.y - 9.6
	draw_circle(Vector2(center.x, head_y), head_radius, color)
	var shoulder := head_y + head_radius + 1.2
	var bottom := center.y + 7.6
	draw_colored_polygon(PackedVector2Array([
		Vector2(center.x - 3.8, shoulder),
		Vector2(center.x + 3.8, shoulder),
		Vector2(center.x + 8.4, bottom),
		Vector2(center.x - 8.4, bottom),
	]), color)
	# 底座：一条圆头粗线，比身体略宽一点，形成「落地」的观感。
	draw_line(Vector2(center.x - 9.6, bottom + 3.0), Vector2(center.x + 9.6, bottom + 3.0),
		color, 3.4, true)


func _text_color() -> Color:
	# 玩家色本身偏暗（单机时是半透明的青色），数字需要提亮才读得清。
	return _color.lightened(0.55)


func _alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0))
