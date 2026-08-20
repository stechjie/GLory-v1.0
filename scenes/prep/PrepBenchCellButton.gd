extends "res://scenes/prep/PrepDragButton.gd"

# 待命区格按钮 —— 同 PrepBoardCellButton，从 PrepShared 内部类搬出。

const PrepRules := preload("res://scenes/prep/PrepRules.gd")

# 拖放高亮与配色归棋盘面板管（D2 步骤 4′ 之后）。
# 直接持面板引用、静态调用 —— 原来走 screen.has_method(...) 的写法，
# 方法一搬走就变成静默失效（has_method 返回 false，高亮永远不亮，且不报错）。
var hud: Node

var bench_index := -1
var screen: Control
var cell_polygon := PackedVector2Array()
var standby_visible := false
var standby_hovered := false

func _ready() -> void:
	mouse_exited.connect(_on_mouse_exited)

func configure_polygon(points: PackedVector2Array) -> void:
	cell_polygon = points
	queue_redraw()

func set_standby_highlight(enabled: bool, hovered: bool = false) -> void:
	standby_visible = enabled
	standby_hovered = enabled and hovered
	queue_redraw()

func _has_point(point: Vector2) -> bool:
	if cell_polygon.size() < 3:
		return false
	if Geometry2D.is_point_in_polygon(point, cell_polygon):
		return true
	# Square touch area centered on the circle: the projected ellipses get very
	# flat near the top rows, so use max(width, height) as the side length to
	# keep every bench spot reliably tappable on Android.
	var minx := cell_polygon[0].x
	var miny := cell_polygon[0].y
	var maxx := minx
	var maxy := miny
	for p in cell_polygon:
		minx = minf(minx, p.x)
		miny = minf(miny, p.y)
		maxx = maxf(maxx, p.x)
		maxy = maxf(maxy, p.y)
	var center := Vector2((minx + maxx) * 0.5, (miny + maxy) * 0.5)
	var side := maxf(maxx - minx, maxy - miny) + 16.0
	return Rect2(center - Vector2(side, side) * 0.5, Vector2(side, side)).has_point(point)

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if hud != null:
		hud.set_standby_drop_hover(bench_index)
	return PrepRules.can_drop_on_bench(bench_index, data)

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if screen != null and screen.has_method("_drop_on_bench"):
		screen._drop_on_bench(bench_index, data)

func _on_mouse_exited() -> void:
	if standby_visible and hud != null:
		hud.set_standby_drop_hover(-1)

func _draw() -> void:
	if not standby_visible or cell_polygon.size() < 3 or screen == null:
		return
	var player_color: Color = screen.standby_hover_line
	if hud != null:
		player_color = hud.player_color()
	var fill: Color = Color(player_color.r, player_color.g, player_color.b, 0.25) if standby_hovered else screen.standby_idle_fill
	var line: Color = Color(player_color.r, player_color.g, player_color.b, 0.92) if standby_hovered else screen.standby_idle_line
	var outline := cell_polygon.duplicate()
	outline.append(cell_polygon[0])
	if standby_hovered:
		var bounds := Rect2(cell_polygon[0], Vector2.ZERO)
		for p in cell_polygon:
			bounds = bounds.expand(p)
		var center := bounds.get_center()
		var source_y := bounds.position.y + bounds.size.y * 0.46
		var beam_top_y := bounds.position.y - maxf(18.0, bounds.size.y * 0.95)
		var source_half := bounds.size.x * 0.12
		var top_half := bounds.size.x * 0.42
		var beam := PackedVector2Array([
			Vector2(center.x - source_half, source_y),
			Vector2(center.x - top_half, beam_top_y),
			Vector2(center.x + top_half, beam_top_y),
			Vector2(center.x + source_half, source_y),
		])
		var beam_core := PackedVector2Array([
			Vector2(center.x - source_half * 0.45, source_y),
			Vector2(center.x - top_half * 0.36, beam_top_y),
			Vector2(center.x + top_half * 0.36, beam_top_y),
			Vector2(center.x + source_half * 0.45, source_y),
		])
		draw_colored_polygon(beam, Color(line.r, line.g, line.b, 0.10))
		draw_colored_polygon(beam_core, Color(line.r, line.g, line.b, 0.18))
		draw_line(Vector2(center.x, source_y), Vector2(center.x, beam_top_y), Color(line.r, line.g, line.b, 0.26), 2.5, true)
	draw_colored_polygon(cell_polygon, fill)
	draw_polyline(outline, line, 2.5 if standby_hovered else 1.25, true)
	if standby_hovered:
		draw_polyline(outline, Color(line.r, line.g, line.b, 0.26), 7.0, true)
