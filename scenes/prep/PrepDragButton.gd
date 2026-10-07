extends Button

# 可拖拽按钮 —— 商店卡片、棋盘格、待命格、佣兵卡都用它。
#
# D2 第三步从 PrepShared 的内部类里搬出来。搬的理由很具体：
# 商店面板要做成独立文件，而它的 `buttons: Array[DragButton]` 需要这个类型。
# 类型留在 PrepShared 里面板就引用不到，退成 Array[Button] 又会丢掉
# `drag_payload` 的静态检查（`btn.drag_payload` 直接编译不过）。
#
# 它本身零反向依赖：只认识 Control，对宿主的调用全部走 has_method 保护。
#
# ⚠️ 那几个 has_method 调用（_on_drag_started / _on_drag_ended）是编译器管不到的：
# 宿主那边一旦改名，这里会**静默不再通知**，拖拽看起来还能用但状态不同步。
# 由 tools/dynamic_call_check.tscn 守着。
#
# ---------------------------------------------------------------------------
# 10.04 bug 文档第 6 条：手机端「点一下没反应」
#
# 症状：手机端备战商店里点棋子卡，有时点一下完全没反应（选中态不切换）。
# 根因（实测，探针 work/_qa_shop/drag_mech_probe + drag_retry_probe）：
#
#   1. Godot 引擎在按下后的**累计位移超过 10px** 时会自动调一次 `_get_drag_data()`
#      （实测 ≤10px 根本不调，11px 才调 —— 这是引擎自带的阈值）；
#   2. 那次调用一旦返回了拖拽数据就**起了拖拽**，而起拖后的那一次松手
#      **再也不会发 `pressed`** ⇒ 手指抖十几像素的轻点被整颗吞掉；
#   3. 四张卡的矩形与命中层级完全一致，也没有任何控件压在卡上（逐点扫过），
#      所以「第 4 格格外不灵」只是拇指落点/手感差异，不是遮挡问题。
#
# 为什么不能只在 `_get_drag_data()` 里按位移返回 null（看着最省事）：
#   ★ 引擎这次尝试**只有一次机会** —— 实测首次尝试之后 `drag_attempted` 就锁死，
#     位移再大也**不会重试**；那样改会让「先抖一下、再拖」的用户永久失去拖拽
#     （实测 20px 的真拖拽也不再起拖）。
#   ★ 而且 `_get_drag_data(at_position)` 的 at_position 实测**恒等于按下点**，
#     在这个回调里根本拿不到当前位移。
#   （顺带：`get_local_mouse_position()` 也不可用 —— 合成输入下它读的是系统真实
#     光标位置，与推进视口的事件无关，实测恒为一个定值。）
#
# ⇒ 因此：`_get_drag_data()` **一律返回 null**（引擎永不接管 ⇒ `pressed` 永不被吞），
#   拖拽改由本脚本在 `gui_input` 里自己累计位移、够了再 `force_drag()` 发起。
# ---------------------------------------------------------------------------

## 手指位移超过这么多像素才**算拖拽**，否则算点击。
##
## ★ 必须大于引擎自己的 10px：阈值取 8px 之类的值等于把「吞掉点击」的起点从
##   10px 提前到 8px，反而更糟。
## ★ 10.07 bug 文档第 4 条（手机端商店第 4 格「小灵」点不着，其余三格正常）：
##   16px 在真机上太窄 —— 本工程按 `canvas_items` 拉伸、基准 1600 宽，1080 宽的
##   手机上 1 逻辑像素 ≈ 0.675 物理像素 ⇒ 16px 只有约 11 物理像素，比系统给
##   触摸留的容差（Android touch slop 8dp，高 dpi 机上折算 20+ 物理像素）还小。
##   拇指点最右那张卡（离「刷新」大按钮最近、行程最长）时，手抖十几像素就被判成
##   拖拽，那次松手的 `pressed` 被整颗吞掉 —— 表现就是「点一下没反应」。
##   （探针实测四张卡矩形与命中层级完全一致，分界就在这条阈值上。）
## ★ 28px ≈ 19 物理像素，既明显高于系统容差、又远低于一次有意的拖拽（30px+），
##   把「轻点允许的手抖」放宽到接近真机手感，同时保留拖拽。
## ★ 与 PrepDetailOverlay 的 8px 不是同一件事，别混：8px 是「不再算长按」的线，
##   这里的 28px 是「算不算拖拽」的线；中间那一段（8~28px）松手仍然是点击。
const DRAG_START_DISTANCE := 28.0

var drag_payload: Dictionary = {}
var drag_enabled := true
var drag_owner: Control

# 本次手势的按下点（按钮局部坐标）、有没有按着、有没有已经起过拖、跟的是哪根手指。
var _gesture_press_local := Vector2.ZERO
var _gesture_pressed := false
var _gesture_drag_launched := false
var _gesture_touch_pointer := -1


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		# ★ 这里**不能**改用 `_ready()` 挂勾子：PrepBoardCellButton 与
		#   PrepBenchCellButton 都覆写了 `_ready()` 而且没调 `super._ready()`，
		#   基类的 `_ready()` 会被整个顶掉 ⇒ 棋盘格与待命格的拖拽阈值静默失效
		#   （只有商店生效，一句报错都没有）。`_notification` 这两个子类都没覆写，
		#   基类实现能正常收到；NOTIFICATION_DRAG_END 的转发一直也是走这条。
		if not gui_input.is_connected(_on_drag_gesture_input):
			gui_input.connect(_on_drag_gesture_input)
		return
	if what == NOTIFICATION_DRAG_END:
		_reset_gesture()
		if drag_owner != null and drag_owner.has_method("_on_drag_ended"):
			drag_owner._on_drag_ended()


func _get_drag_data(_at_position: Vector2) -> Variant:
	# ★ 一律返回 null —— 把引擎的拖拽接管彻底让开，理由见文件头的第 6 条。
	#   这里不能再返回 drag_payload：那样只要手指累计抖过 10px 就会起拖，
	#   而起拖会把那一次松手的 `pressed` 整颗吞掉。
	return null


# 手势识别：按下记起点；位移到 DRAG_START_DISTANCE 才由自己发起拖拽。
#
# 手感口径（一次手势最多起一次拖）：
#   0 ~ 16px  松手 = 点击（`pressed` 照常发）
#   ≥ 16px    起拖，松手走拖放（`pressed` 不发）
#
# 两类事件都收：桌面与触摸模拟走 MouseButton + MouseMotion，
# 真触摸走 ScreenTouch + ScreenDrag（两条路径的 position 都是按钮局部坐标）。
func _on_drag_gesture_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_begin_gesture(mb.position, -1)
		else:
			_reset_gesture()
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_begin_gesture(touch.position, touch.index)
		elif _gesture_touch_pointer < 0 or touch.index == _gesture_touch_pointer:
			_reset_gesture()
		return
	if event is InputEventMouseMotion:
		_maybe_launch_drag((event as InputEventMouseMotion).position)
		return
	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _gesture_touch_pointer >= 0 and drag.index != _gesture_touch_pointer:
			return
		_maybe_launch_drag(drag.position)


func _begin_gesture(local_pos: Vector2, pointer: int) -> void:
	# 触摸事件与它模拟出来的鼠标事件都会到这里，位置一致、重复置位无副作用。
	# 多指只认第一根手指，与 PrepDetailOverlay 的口径一致。
	if _gesture_pressed and pointer >= 0 and _gesture_touch_pointer >= 0 and pointer != _gesture_touch_pointer:
		return
	_gesture_press_local = local_pos
	_gesture_pressed = true
	_gesture_drag_launched = false
	if pointer >= 0:
		_gesture_touch_pointer = pointer


func _reset_gesture() -> void:
	_gesture_pressed = false
	_gesture_drag_launched = false
	_gesture_touch_pointer = -1


func _maybe_launch_drag(local_pos: Vector2) -> void:
	if not _gesture_pressed or _gesture_drag_launched:
		return
	if disabled or not drag_enabled or drag_payload.is_empty():
		return
	if local_pos.distance_to(_gesture_press_local) < DRAG_START_DISTANCE:
		return
	_launch_drag()


func _launch_drag() -> void:
	_gesture_drag_launched = true
	# 下面这几条副作用与原 `_get_drag_data` 逐条对应，一条都不能少：
	# 停长按表（不停的话拖到一半会弹出详情框挡住视线）、标记本次不算长按、通知宿主。
	if has_meta("long_press_timer"):
		var timer = get_meta("long_press_timer")
		if timer is Timer:
			timer.stop()
	set_meta("long_press_cancelled", true)
	set_meta("dragging", true)
	if drag_owner != null and drag_owner.has_method("_on_drag_started"):
		drag_owner._on_drag_started(drag_payload)
	var preview := Label.new()
	preview.text = str(get_meta("drag_preview_text", text))
	preview.modulate = Color(1.0, 0.95, 0.65)
	preview.add_theme_font_size_override("font_size", 14)
	# force_drag 绕过引擎那套 _get_drag_data 取数流程直接起拖，数据与预览都由这里给；
	# 宿主的 _on_drag_ended 仍会经 NOTIFICATION_DRAG_END 收到（上面已转发）。
	force_drag(drag_payload.duplicate(true), preview)
