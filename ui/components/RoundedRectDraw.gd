extends RefCounted

# 圆角矩形的**纯绘制**工具（10.05 反馈第 2 条与第 4 条共用）。
#
# 为什么要单独抽一个文件：这一批新增了两处自绘 UI —— 棋盘正中的「已上阵 / 上限」计数
# 图案、宝藏页刷新按钮的一圈呼吸边缘光 —— 两者都要「圆角矩形 + 外发光」，而两者
# **都不能用 StyleBoxFlat**：本仓有 procedural_ui_ratchet 棘轮，业务代码
# （`res://scenes`、`res://ui`、`res://scripts`）里的 `StyleBoxFlat.new()` /
# `Button.new()` 只能下降，而且按文件记账 —— 总数没涨、只是换个文件写，同样判红。
# 所以几何与发光的画法放这里共用一份，不在两个文件里各写一遍。
#
# 全静态、不持状态（与 PrepRules 同一种定位）。
#
# ⚠️ `draw_soft_glow()` 会代调 `canvas.draw_polyline()`，所以只能在
# **canvas 自己的 `_draw()` 里**调它，并且 canvas 必须传自己 —— Godot 的
# draw_* 只在 NOTIFICATION_DRAW 期间有效，换到别处调会直接报错。

const STEPS_PER_CORNER := 6


# 圆角矩形的顶点表。每个角用 steps 段圆弧（真圆角，不是切角），
# 填充与外描边共用同一套点，保证两者完全重合、不会露出锯齿。
static func rounded_rect(rect: Rect2, radius: float, steps: int = STEPS_PER_CORNER) -> PackedVector2Array:
	var r := minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	var points := PackedVector2Array()
	# 每项 = [圆心, 起始角]，按 右上 → 右下 → 左下 → 左上 铺一圈。
	var corners := [
		[Vector2(rect.end.x - r, rect.position.y + r), -PI * 0.5],
		[Vector2(rect.end.x - r, rect.end.y - r), 0.0],
		[Vector2(rect.position.x + r, rect.end.y - r), PI * 0.5],
		[Vector2(rect.position.x + r, rect.position.y + r), PI],
	]
	for corner in corners:
		var center: Vector2 = corner[0]
		var start: float = corner[1]
		for step in steps + 1:
			var angle: float = start + PI * 0.5 * float(step) / float(steps)
			points.append(center + Vector2(cos(angle), sin(angle)) * r)
	return points


# `draw_polyline` 不会自己闭合，末点必须显式接回起点。
static func closed(points: PackedVector2Array) -> PackedVector2Array:
	var out := points.duplicate()
	if not out.is_empty():
		out.append(out[0])
	return out


# 外发光：由外到内叠 rings 圈描边，越外侧越淡 —— 顶替 StyleBoxFlat 的
# `shadow_color` + `shadow_size`。`color` 的 alpha 用作**最内那一圈**的不透明度。
static func draw_soft_glow(canvas: CanvasItem, rect: Rect2, radius: float, color: Color,
		rings: int, step: float, width: float) -> void:
	if canvas == null or rings <= 0:
		return
	for ring in range(rings, 0, -1):
		var grow := float(ring) * step
		var ring_alpha := color.a * (1.0 - float(ring - 1) / float(rings))
		var shade := Color(color.r, color.g, color.b, clampf(ring_alpha, 0.0, 1.0))
		canvas.draw_polyline(closed(rounded_rect(rect.grow(grow), radius + grow)), shade, width, true)
