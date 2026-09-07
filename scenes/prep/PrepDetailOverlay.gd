extends RefCounted

# 备战界面的**详情浮层** —— D2 第三步。
#
# 长按棋子/宝物/商店卡片弹出的那个说明框，以及点金币弹出的利息小框。
# 四个面板（商店 / 宝物 / 羁绊 / 战力统计）都要用它，所以它不属于任何一个面板，
# 是它们共用的一个**自带状态的组件**。
#
# 与 PrepWidgets / PrepRules 的区别：那两个是纯静态工具，这个**有状态** ——
# 它持有弹窗节点、文本节点，以及「等待松手」那套关闭时序。
# 所以它是实例（每个备战界面一个），不是静态函数集合。
#
# 为什么要抽：
# 抽掉之后，商店面板对宿主的调用从 11 个降到 5 个，宝物面板从 6 个降到 3 个。
# 剩下的才是真正需要变成信号的**动作**（买入、合成、刷新全屏）。
#
# 「等待松手」是什么：
# 长按弹出详情后手指还按着，如果这时就允许「点空白处关闭」，
# 松手那一下会立刻把刚弹出来的框关掉。所以弹出后先进入
# waiting_for_release，看到一次按下、再看到松开，才允许关闭。

var popup: PopupPanel
var text_label: RichTextLabel

# 关闭时序，见上面「等待松手」。
var waiting_for_release := false
var release_seen_press := false

# 金币利息框是「活的」：金币变化时要实时改写文本，所以要知道当前开的是不是它。
var gold_interest_open := false


func bind(p: PopupPanel, label: RichTextLabel) -> void:
	popup = p
	text_label = label


func is_ready() -> bool:
	return popup != null and text_label != null


func is_showing() -> bool:
	return popup != null and popup.visible


# 常规详情框（棋子属性、宝物说明、商店卡片）。
func show_text(text: String) -> void:
	_show(text, Vector2(500, 340), Vector2i(540, 390), false)


# 战力推荐框，比常规的矮一些。
func show_power(text: String) -> void:
	_show(text, Vector2(400, 210), Vector2i(440, 240), false)


# 金币利息小框。gold_interest_open 置位，之后金币一变就会实时改写文本。
func show_gold_interest(text: String) -> void:
	_show(text, Vector2(180, 72), Vector2i(220, 104), true)


func _show(text: String, min_size: Vector2, popup_size: Vector2i, is_gold: bool) -> void:
	if not is_ready():
		return
	gold_interest_open = is_gold
	text_label.custom_minimum_size = min_size
	text_label.text = text
	waiting_for_release = false
	release_seen_press = false
	popup.popup_centered(popup_size)


# 金币数变了：只有当前开着的就是利息框时才改写，否则会把别的详情内容覆盖掉。
func refresh_gold_interest(text: String) -> void:
	if gold_interest_open and is_showing():
		text_label.text = text


func hide_detail() -> void:
	if popup != null and popup.visible:
		popup.hide()
	gold_interest_open = false
	waiting_for_release = false
	release_seen_press = false


# 每帧调用：处理「按下再松开才允许关闭」的时序。
func update_release_state() -> void:
	if popup == null or not popup.visible:
		waiting_for_release = false
		release_seen_press = false
		return
	if not waiting_for_release:
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		release_seen_press = true
	elif release_seen_press:
		hide_detail()


# 给按钮装上「长按 0.7 秒弹详情」。
#
# 手势状态都存在按钮 meta 上：
#   long_press_cancelled  手指移动超过 8 像素 = 用户在拖拽，不是长按
#   long_press_triggered  已经弹出过，松手时**不要**顺手收起（详情要常驻）
#   long_press_consumed   业务 pressed 必须被消费，不能继续执行领取/购买
#   long_press_pointer    多指时只跟踪发起本次手势的 pointer
#   long_press_down_msec  诊断时可确认真实按住时间
#   dragging              拖拽中，同样不算长按
# 少判一个的表现都是「长按有时不灵 / 拖着拖着弹出说明框 / 松手误操作」，没有报错。
func attach_long_press(btn: BaseButton, cb: Callable) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 0.7
	btn.add_child(timer)
	btn.set_meta("long_press_timer", timer)
	timer.timeout.connect(func():
		if not bool(btn.get_meta("long_press_cancelled", false)) and not bool(btn.get_meta("dragging", false)):
			btn.set_meta("long_press_triggered", true)
			btn.set_meta("long_press_consumed", true)
			cb.call()
	)
	btn.button_down.connect(func():
		btn.set_meta("long_press_start", btn.get_local_mouse_position())
		btn.set_meta("long_press_down_msec", Time.get_ticks_msec())
		btn.set_meta("long_press_pointer", -1)
		btn.set_meta("long_press_cancelled", false)
		btn.set_meta("long_press_triggered", false)
		btn.set_meta("long_press_consumed", false)
		btn.set_meta("dragging", false)
		timer.start()
	)
	btn.button_up.connect(func():
		timer.stop()
		btn.set_meta("dragging", false)
		# 长按看属性「常驻」：松手后详情保留，靠点击弹窗外部/下一次操作关闭。
		# 若这次没触发长按（只是轻点），才顺手收起可能残留的详情。
		if not bool(btn.get_meta("long_press_triggered", false)):
			hide_detail()
	)
	btn.gui_input.connect(func(event: InputEvent):
		if event is InputEventScreenTouch:
			var touch := event as InputEventScreenTouch
			if touch.pressed:
				btn.set_meta("long_press_pointer", touch.index)
				btn.set_meta("long_press_start", touch.position)
			elif touch.canceled:
				btn.set_meta("long_press_cancelled", true)
				timer.stop()
		if not timer.time_left > 0.0:
			return
		if event is InputEventMouseMotion or event is InputEventScreenDrag:
			var current := btn.get_local_mouse_position()
			if event is InputEventMouseMotion:
				current = (event as InputEventMouseMotion).position
			else:
				var drag := event as InputEventScreenDrag
				var pointer := int(btn.get_meta("long_press_pointer", -1))
				if pointer >= 0 and drag.index != pointer:
					return
				current = drag.position
			var start: Vector2 = btn.get_meta("long_press_start", current)
			if current.distance_to(start) > 8.0:
				btn.set_meta("long_press_cancelled", true)
				timer.stop()
	)


# pressed 信号的业务回调调用这个函数。返回 true 表示本次激活来自长按、
# 超阈值移动或触摸取消，调用方必须直接返回；同时只消费一次。
func consume_long_press(btn: BaseButton) -> bool:
	if btn == null:
		return false
	var blocked := (
		bool(btn.get_meta("long_press_consumed", false))
		or bool(btn.get_meta("long_press_cancelled", false)))
	btn.set_meta("long_press_consumed", false)
	btn.set_meta("long_press_triggered", false)
	btn.set_meta("long_press_cancelled", false)
	return blocked
