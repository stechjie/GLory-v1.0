extends ScrollContainer

# 「按住拖拽就能滚」的列表容器 —— 备战（四星升级石）、最终结算、商店共用。
#
# 为什么不能用 ScrollContainer 自带的触摸拖拽：本仓这几个列表的内容**全是按钮**。
# 手指按在按钮上时，按下事件被子按钮吃掉，ScrollContainer 的 `_gui_input` 就再也
# 收不到后续的 ScreenDrag —— 玩家实测的表现就是「只能滚轮、或者按住右侧滚动条」。
# 所以这里在**子控件之前**（`_input`）观察原始事件：
#   * 一次轻点（位移没到阈值）原样放行，按钮照常响应；
#   * 一次纵向拖动超过阈值就吃掉后续事件并滚动，同时发 `NOTIFICATION_SCROLL_BEGIN`，
#     `BaseButton` 收到它会取消当前这次按压 —— 拖完松手不会误触发列表里的按钮。
#
# 三类输入都接：
#   * InputEventScreenTouch / InputEventScreenDrag   —— 真机触摸
#   * InputEventMouseButton / InputEventMouseMotion  —— 桌面与模拟器的鼠标拖拽
#   * 鼠标滚轮保持 ScrollContainer 原行为（不拦、不标记已处理）
# Android 上 `emulate_mouse_from_touch` 默认开着，同一次触摸会来「触摸 + 模拟鼠标」
# 两路；用「先到的那一路占住手势」去重，不依赖设备号，也不怕模拟开关被关掉。
#
# 10.05 反馈（升级石界面「向下滚动不便」）补的两条：
#   1. 命中判定不能只看本控件自己的矩形。根视口在 stretch=canvas_items 下会把窗口
#      坐标换算成画布坐标再投递，而带缩放的 CanvasLayer 里的控件又是画布层局部坐标
#      —— 手机分辨率与 1600×720 基准不同时两者差一个缩放系数，只按一种坐标判定会
#      「怎么按都滚不动」且没有任何日志。所以两种坐标各判一次，任一命中即算命中，
#      滚动增量也按命中的那套坐标系换算。
#   2. 可用 `set_drag_zone()` 指定一块更大的「手势区」（例如整张升星卡片），
#      实现「按住升星区域上下滑动就能滚」的手感。手势区只扩大**起点**判定范围，
#      轻点仍照常落到子按钮上 —— 所以不会抢走卡片里其他控件的点击。

const DRAG_THRESHOLD := 5.0   # 纵向位移超过它才算滚动，轻点不受影响（原来 6.0）
const HIT_SLOP := 6.0         # 命中框外扩，容忍边缘像素与安全区取整误差

var _pointer := ""            # "" / "touch" / "mouse"，空 = 当前没有手势
var _touch_index := -1
var _mouse_button := -1
var _start := Vector2.ZERO    # 手势起点的**局部**坐标
var _start_scroll := 0
var _dragging := false
var _window_space := false    # 事件是否停留在窗口坐标（路径 2），影响增量换算
var _drag_zone: Callable = Callable()   # 返回 Control；无效时只用本控件矩形


func _ready() -> void:
	# `_input` 只在开启输入处理后才会被调用。写了 `_input` 的脚本在编辑器里通常
	# 会被自动打开，但运行时自查一次更稳 —— 关掉就是「怎么拖都没反应」且不报错。
	set_process_input(true)


# 手势区：一个返回 Control 的 Callable（通常是「装着本列表的那张卡片」）。
# 传无效 Callable 表示只用本控件自己的矩形。
func set_drag_zone(getter: Callable) -> void:
	_drag_zone = getter


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		_reset()
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_begin("touch", touch.index, -1, touch.position)
		elif _pointer == "touch" and touch.index == _touch_index:
			_end()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _pointer == "touch" and drag.index == _touch_index:
			_advance(drag.position)
		elif _dragging:
			# 手势被模拟鼠标那一路占住时，触摸那一路的移动也要吃掉，
			# 否则它会穿透到子控件上（Android 双路投递）。
			_consume()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
				MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			return   # 滚轮交给 ScrollContainer 自己
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_begin("mouse", -1, mb.button_index, mb.position)
		elif _pointer == "mouse" and mb.button_index == _mouse_button:
			_end()
	elif event is InputEventMouseMotion:
		if _pointer == "mouse":
			_advance((event as InputEventMouseMotion).position)
		elif _dragging:
			_consume()


# --- 手势 ---------------------------------------------------------------------

func _begin(kind: String, touch_index: int, mouse_button: int, pos: Vector2) -> void:
	# 已经在处理一次手势：第二路（触摸模拟出来的鼠标）不再重开，
	# 「先到先占」去重，Android 上不会一条手势滚两倍。
	if _pointer != "":
		return
	# 显式标 Variant：本工程把 `inference_on_variant` 当错误（`:=` 从 Variant 推断会
	# 直接编译失败，且只在日志里报一行、门禁不一定计入）。
	var local: Variant = _accepts(pos)
	if local == null:
		return
	_pointer = kind
	_touch_index = touch_index
	_mouse_button = mouse_button
	_start = local
	_start_scroll = scroll_vertical
	_dragging = false


func _advance(pos: Vector2) -> void:
	var movement := _to_local(pos) - _start
	if not _dragging:
		if absf(movement.y) < DRAG_THRESHOLD or absf(movement.y) <= absf(movement.x):
			return
		_dragging = true
		propagate_notification(NOTIFICATION_SCROLL_BEGIN)
	scroll_vertical = _start_scroll - roundi(movement.y / _gain())
	_consume()


func _end() -> void:
	if _dragging:
		# 拖着松手：吃掉这一下，列表里被按住的按钮不会触发。
		_consume()
		propagate_notification(NOTIFICATION_SCROLL_END)
	_reset()


func _reset() -> void:
	_pointer = ""
	_touch_index = -1
	_mouse_button = -1
	_dragging = false
	_window_space = false


func _consume() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


# --- 坐标 ---------------------------------------------------------------------

# 起点是否落在「本控件矩形 ∪ 手势区」里；是则返回它的**局部**坐标，否则 null。
func _accepts(pos: Vector2) -> Variant:
	var own_rect := Rect2(Vector2.ZERO, size).grow(HIT_SLOP)
	# 路径 1：事件已经是画布坐标（根视口 stretch 换算后的正常情况）。
	var local := get_global_transform().affine_inverse() * pos
	if own_rect.has_point(local) or _in_drag_zone(pos):
		_window_space = false
		return local
	# 路径 2：事件仍是窗口坐标（带缩放的 CanvasLayer / 自绘层）。
	local = get_global_transform_with_canvas().affine_inverse() * pos
	if own_rect.has_point(local) or _in_drag_zone(pos):
		_window_space = true
		return local
	return null


func _to_local(pos: Vector2) -> Vector2:
	# 坐标空间在 press 时定下来，拖动过程沿用同一套 —— 中途换算基准变了
	# 会让滚动量突然跳一下（列表「抖」一下）。
	if _window_space:
		return get_global_transform_with_canvas().affine_inverse() * pos
	return get_global_transform().affine_inverse() * pos


func _gain() -> float:
	var xform := get_global_transform_with_canvas() if _window_space else get_global_transform()
	return maxf(0.01, xform.get_scale().y)


func _in_drag_zone(pos: Vector2) -> bool:
	if not _drag_zone.is_valid():
		return false
	var zone: Variant = _drag_zone.call()
	if not (zone is Control) or not is_instance_valid(zone):
		return false
	var control := zone as Control
	if not control.is_visible_in_tree():
		return false
	return _hits_control(control, pos)


# 同一个双坐标空间判定，给手势区复用。
func _hits_control(control: Control, pos: Vector2) -> bool:
	var rect := Rect2(Vector2.ZERO, control.size).grow(HIT_SLOP)
	if rect.has_point(control.get_global_transform().affine_inverse() * pos):
		return true
	return rect.has_point(control.get_global_transform_with_canvas().affine_inverse() * pos)
