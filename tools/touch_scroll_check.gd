extends Node

# `ui/components/TouchScrollContainer.gd` 的行为判据（10.05 反馈第 1 条）。
#
# 反馈原话：「升级石界面向下滚动存在操作不便捷的问题……改为：可按住升星区域上下滑动
# 进行滚动」。它的根因不在样式，在这个容器**只认触摸事件**且命中判定只用了一种坐标
# 空间 —— PC 与模拟器上「怎么按都滚不动」且不报错。修完之后谁也不敢只靠读源码说它对。
#
# ★ 判据一律走**真实事件**：`get_viewport().push_input(...)` 投递 InputEventMouseButton /
#   InputEventMouseMotion，而不是直接调 `_begin()` / `_advance()`。
#   直接调私有方法只能证明「函数写得对」，证明不了「事件真的会走到它」——
#   而这一条反馈的现场恰恰是「事件根本没走到」。
#
# 覆盖：
#   * 按住拖动 → 滚动量真的变了；松手不会顺带触发列表里被按住的按钮
#   * 轻点（位移不到阈值）→ 不滚动、按钮照常响应
#   * `set_drag_zone()` 把可起手区域扩大到整张卡片（「按住升星区域」的手感）
#   * 手势区**只扩大起点判定**：没设手势区时，矩形外起手不该滚动
#   * 根视口 canvas 带缩放时的**双坐标回退**（只认一种坐标就会脱靶）
#
# 变异结论（2026-10-05，脚本 `其他/work/_mutate_gate.py`，改动已还原、sha256 核对）：
#   m1 鼠标按下不起手势   → RED 3 条（drag_scrolls / drag_keeps_scrolling / drag_zone_scrolls）
#   m2 取消手势区支持     → RED 1 条（drag_zone_scrolls）
#   m3 去掉位移阈值       → RED 2 条（tiny_move_no_scroll / tiny_move_still_click）
#   m4 删掉双坐标回退     → RED 1 条（scaled_canvas_fallback_scrolls）
#   注：m4 的判据不是白送的 —— 不给根视口加缩放 canvas transform 时它是 STILL GREEN，
#   因为 headless 下两条坐标路径数值相同。这条断言是专门为它造的。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/touch_scroll_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TouchScrollScript := preload("res://ui/components/TouchScrollContainer.gd")

const CHECK_NAME := "touch_scroll"

const VIEW_SIZE := Vector2(200.0, 150.0)
const CONTENT_HEIGHT := 900.0
const DRAG_DELTA := 60.0
const TINY_DELTA := 2.0          # 小于 DRAG_THRESHOLD(5.0)，应当被当成轻点

var _h: CheckHarness
var _scroll: ScrollContainer
var _button: Button
var _pressed_count := 0


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_build_scene()
	await get_tree().process_frame
	await get_tree().process_frame

	_case_click_does_not_scroll()
	_case_drag_scrolls()
	_case_drag_does_not_press_button()
	_case_tiny_move_is_a_click()
	_case_drag_zone_extends_start()
	_case_no_zone_means_no_drag_outside()
	_case_canvas_scaled_fallback()

	_h.finish(get_tree())


func _build_scene() -> void:
	var zone := Control.new()
	zone.name = "DragZone"
	zone.position = Vector2.ZERO
	zone.size = Vector2(400.0, 300.0)
	# 手势区不能吃输入，否则它会替按钮接走点击。
	zone.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(zone)

	_scroll = TouchScrollScript.new()
	_scroll.name = "Scroll"
	_scroll.position = Vector2(60.0, 80.0)
	_scroll.size = VIEW_SIZE
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	zone.add_child(_scroll)

	var content := Control.new()
	content.name = "Content"
	content.custom_minimum_size = Vector2(VIEW_SIZE.x, CONTENT_HEIGHT)
	_scroll.add_child(content)

	_button = Button.new()
	_button.name = "RowButton"
	_button.size = Vector2(VIEW_SIZE.x, 120.0)
	_button.position = Vector2.ZERO
	_button.focus_mode = Control.FOCUS_NONE
	_button.pressed.connect(_on_button_pressed)
	content.add_child(_button)


func _on_button_pressed() -> void:
	_pressed_count += 1


# --- 事件投递 -----------------------------------------------------------------
#
# ★ 必须走 `push_input(event, true)` —— 第二个参数是「坐标已经是视口本地坐标」。
#   漏掉它就是 `false`（默认），引擎会把坐标当成「窗口/嵌入方坐标」再乘一遍
#   最终变换的逆。--headless 下窗口尺寸是 (0,0)，视口退回拉伸基准
#   （实测 `get_final_transform().get_scale() == 0.04`）⇒ 逆变换是 **×25**，
#   我最初投 (150,120) 事件落点变成 (3750,3000)，全部脱靶，6 个用例里 5 个假红。
#   本仓已有的同类写法见 `tools/voice_redesign_check.gd:111`。

func _press(local_point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = local_point
	get_viewport().push_input(event, true)


func _move(local_point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = local_point
	get_viewport().push_input(event, true)


func _release(local_point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = local_point
	get_viewport().push_input(event, true)


# 一次「按住 -> 拖动 -> 松手」。delta.y 为负表示手指往上推（列表往下滚）。
func _drag(start: Vector2, delta: Vector2) -> void:
	_press(start)
	_move(start + delta * 0.5)
	_move(start + delta)
	_release(start + delta)


# --- 用例 ---------------------------------------------------------------------

func _case_click_does_not_scroll() -> void:
	_scroll.scroll_vertical = 0
	_pressed_count = 0
	var start := _scroll.position + Vector2(100.0, 40.0)
	_press(start)
	_release(start)
	_h.expect(_scroll.scroll_vertical == 0, "click_no_scroll",
		"轻点不该滚动列表，实际滚到 %d" % _scroll.scroll_vertical)
	_h.expect(_pressed_count == 1, "click_reaches_button",
		"轻点应当照常传到子按钮（列表里全是按钮，这条断了就没法点任何东西），实际触发 %d 次" % _pressed_count)


func _case_drag_scrolls() -> void:
	_scroll.scroll_vertical = 0
	_pressed_count = 0
	var start := _scroll.position + Vector2(100.0, 40.0)
	_drag(start, Vector2(0.0, -DRAG_DELTA))
	_h.expect(_scroll.scroll_vertical > 0, "drag_scrolls",
		"按住向上拖动应当让列表向下滚，实际 scroll_vertical=%d（反馈第 1 条）" % _scroll.scroll_vertical)
	var first := _scroll.scroll_vertical
	_drag(start, Vector2(0.0, -DRAG_DELTA))
	_h.expect(_scroll.scroll_vertical > first, "drag_keeps_scrolling",
		"再拖一次应当继续往下滚：%d -> %d" % [first, _scroll.scroll_vertical])


func _case_drag_does_not_press_button() -> void:
	_scroll.scroll_vertical = 0
	_pressed_count = 0
	var start := _scroll.position + Vector2(100.0, 40.0)
	_drag(start, Vector2(0.0, -DRAG_DELTA))
	_h.expect(_pressed_count == 0, "drag_no_accidental_press",
		"拖动结束后不该顺带触发列表里被按住的那个按钮，实际触发了 %d 次" % _pressed_count)


func _case_tiny_move_is_a_click() -> void:
	_scroll.scroll_vertical = 0
	_pressed_count = 0
	var start := _scroll.position + Vector2(100.0, 40.0)
	_drag(start, Vector2(0.0, -TINY_DELTA))
	_h.expect(_scroll.scroll_vertical == 0, "tiny_move_no_scroll",
		"位移小于阈值的抖动不该被当成滚动，实际滚到 %d" % _scroll.scroll_vertical)
	_h.expect(_pressed_count == 1, "tiny_move_still_click",
		"小于阈值的抖动仍应算一次点击，实际触发 %d 次" % _pressed_count)


# 「按住升星区域（整张卡片）上下滑动就能滚」—— 起手点落在容器矩形之外、
# 但落在手势区里时，也必须能滚。
func _case_drag_zone_extends_start() -> void:
	_scroll.scroll_vertical = 0
	_pressed_count = 0
	var zone: Control = get_node("DragZone")
	_scroll.set_drag_zone(func() -> Control: return zone)
	# ★ 起手点必须真的在容器矩形**外**：容器在 (60,80)，尺寸 200x150
	#   ⇒ 占 (60,80)-(260,230)。原先写 `_scroll.position + (8,8)` 其实落在容器
	#   **内部**，这两条用例等于什么都没测（第一条会恒绿、第二条会恒红）。
	#   改成往左上退 (-40,-50) → (20,30)：在手势区(400x300)里、在容器外。
	var outside := _scroll.position + Vector2(-40.0, -50.0)
	_drag(outside, Vector2(0.0, -DRAG_DELTA))
	_h.expect(_scroll.scroll_vertical > 0, "drag_zone_scrolls",
		"在卡片（手势区）内、容器外起手也应当能滚，实际 scroll_vertical=%d" % _scroll.scroll_vertical)
	_h.expect(_pressed_count == 0, "drag_zone_no_press",
		"手势区起手的拖动同样不该触发按钮，实际触发 %d 次" % _pressed_count)
	_scroll.set_drag_zone(Callable())


# 反向对照：没设手势区时，容器外起手**不该**滚动 ——
# 否则上面那条断言在「命中判定本来就过宽」的实现下也会绿。
func _case_no_zone_means_no_drag_outside() -> void:
	_scroll.scroll_vertical = 0
	_pressed_count = 0
	var outside := _scroll.position + Vector2(-40.0, -50.0)   # 同上的「容器外」起手点
	_drag(outside, Vector2(0.0, -DRAG_DELTA))
	_h.expect(_scroll.scroll_vertical == 0, "outside_start_no_scroll",
		"没设手势区时，容器矩形之外起手不该滚动，实际滚到 %d" % _scroll.scroll_vertical)


# 双坐标回退（`_accepts` 的路径 2）的判据。
#
# 为什么需要它：--headless 下根视口的 canvas transform 是**恒等矩阵**，两条坐标路径
# 算出来的局部坐标完全一样 ⇒ 把回退整段删掉门禁照样全绿（实测变异 m4 = STILL GREEN，
# 一条判不出东西的断言等于没有）。所以这里**手动给根视口一个缩放过的 canvas transform**，
# 把两条路径拉开：
#   * 路径 1（按控件自身坐标判定）→ 落点跑出控件矩形 → 不认；
#   * 路径 2（按窗口/画布坐标判定）→ 落点正落在控件上 → 认。
# 于是这条断言**只有回退还在时才绿**。真机上的对应场景就是「高分辨率手机 / 带缩放的
# CanvasLayer 里，两种坐标差一个缩放系数」—— 反馈第 1 条「怎么按都滚不动」的现场。
func _case_canvas_scaled_fallback() -> void:
	_scroll.scroll_vertical = 0
	_pressed_count = 0
	var viewport := get_viewport()
	var saved := viewport.canvas_transform
	viewport.canvas_transform = Transform2D().scaled(Vector2(2.0, 2.0))
	# 起手点 (300,350) 是刻意挑的：路径 1 判到 (240,270)、路径 2 判到 (30,15)，
	# 后者落在 200x150(+6 外扩) 的矩形内，前者落在矩形外。
	var start := Vector2(300.0, 350.0)
	_drag(start, Vector2(0.0, -60.0))
	viewport.canvas_transform = saved
	_h.expect(_scroll.scroll_vertical > 0, "scaled_canvas_fallback_scrolls",
		"根视口 canvas 带缩放时（真机高分辨率 / 带缩放 CanvasLayer 的情形）只按控件坐标判定会脱靶，实际 scroll_vertical=%d" % _scroll.scroll_vertical)
