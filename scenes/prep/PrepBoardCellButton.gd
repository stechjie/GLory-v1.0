extends "res://scenes/prep/PrepDragButton.gd"

# 棋盘格按钮 —— D2 步骤 4′ 从 PrepShared 的内部类搬出来。
# 搬的理由和 PrepDragButton 一样：棋盘面板要独立成文件，
# 而它的 buttons: Array[BoardCellButton] 需要这个类型。
#
# 它对宿主的调用全部走 has_method 保护（_set_board_drop_hover / _drop_on_board）——
# 那类调用编译器管不到，由 tools/dynamic_call_check.tscn 守着。

const PrepRules := preload("res://scenes/prep/PrepRules.gd")

# 拖放高亮与配色归棋盘面板管（D2 步骤 4′ 之后）。
# 直接持面板引用、静态调用 —— 原来走 screen.has_method(...) 的写法，
# 方法一搬走就变成静默失效（has_method 返回 false，高亮永远不亮，且不报错）。
var hud: Node

var board_index := -1
var screen: Control
var cell_polygon := PackedVector2Array()
var deployment_visible := false
var deployment_hovered := false

func _ready() -> void:
	mouse_exited.connect(_on_mouse_exited)

func configure_polygon(points: PackedVector2Array) -> void:
	cell_polygon = points
	queue_redraw()

func set_deployment_highlight(enabled: bool, hovered: bool = false) -> void:
	deployment_visible = enabled
	deployment_hovered = enabled and hovered
	queue_redraw()

func _has_point(point: Vector2) -> bool:
	if cell_polygon.size() < 3:
		return false
	if Geometry2D.is_point_in_polygon(point, cell_polygon):
		return true
	# (10) The perspective-tilted board makes edge columns (esp. the far right)
	# a thin sliver — hard to tap on Android. Enlarge the hit rect so every
	# cell, including the rightmost column, is reliably touchable.
	var minx := cell_polygon[0].x
	var miny := cell_polygon[0].y
	var maxx := minx
	var maxy := miny
	for p in cell_polygon:
		minx = minf(minx, p.x)
		miny = minf(miny, p.y)
		maxx = maxf(maxx, p.x)
		maxy = maxf(maxy, p.y)
	return Rect2(minx, miny, maxx - minx, maxy - miny).grow(16.0).has_point(point)

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	# 拖放合法性是**规则**，不是宿主状态 —— 直接问 PrepRules，不必绕 screen。
	# 原来这里是 screen.has_method("_can_drop_on_board") and screen._can_drop_on_board(...)，
	# 那种写法有个隐患：方法一旦改名或删除，has_method 返回 false，
	# 拖放会**静默全部失效**，编译期一句话都不报。
	var can_drop: bool = PrepRules.can_drop_on_board(board_index, data)
	if hud != null:
		hud.set_board_drop_hover(board_index if can_drop else -1)
	return can_drop

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if screen != null and screen.has_method("_drop_on_board"):
		screen._drop_on_board(board_index, data)

func _on_mouse_exited() -> void:
	if deployment_visible and hud != null:
		hud.set_board_drop_hover(-1)

func _draw() -> void:
	# BoardReadabilityLayer owns all board guide rendering in one CanvasItem.
	# This button keeps only touch/drag hit testing, so the 16 cells no longer
	# duplicate guide draw calls or drift away from the shared style resource.
	pass

