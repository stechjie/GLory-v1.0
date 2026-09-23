extends Control
# 匹配排队面板（docs/排位系统设计.md 第五节）。入口是主菜单「休闲」。
#
# **整条流程都在这一个面板身上**：排队 → 凑齐 → 确认框 → 拿到分配 → 交给 Main 去连。
# 面板的生命周期 = 排队的生命周期，关掉它就退出队列。
#
# 不新开 autoload：那要改 project.godot，而那个文件在这台机器上有行尾陷阱
# （见开发笔记）。而且这套状态本来就不该活得比界面久 —— 玩家退出界面就是退出队列。
#
# 三条在改这个文件之前必须知道的：
#
# 1. **推送是主路径，轮询是兜底。** 状态变化走 WebSocket（RealtimeService 的
#    `t: "match"`）。但手机切一次后台 WS 就断了，只靠推送会让人卡在「匹配中」
#    再也出不来 —— 所以还有一个低频轮询。两边解析的是**同一个形状**
#    （backend/app/routes/matchmaking.py 顶上那条）。
#
# 2. **确认框的倒计时只是显示。** 真正的时限在账号服务器
#    （matchmaking.ACCEPT_TIMEOUT_SEC）。客户端的钟不准、切后台不跑帧，
#    拿它当判据的话会出现「本地还剩 10 秒，服务器已经解散了」。
#
# 3. **拿到 ready 之后就不归这个面板管了。** 它 emit `match_ready` 然后关掉，
#    连战斗服务器、领名片、入座都是 Main 的活（同「开始游戏」那条路）。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const SfxService := preload("res://ui/services/SfxService.gd")

# 拿到对局分配，可以去连战斗服务器了。
signal match_ready()
# 玩家自己退出，或者出错退不下去了。
signal dismissed()

# WS 断着时的兜底轮询间隔。**不能太密** —— 后端 /v1/match/state 的额度是
# 120/分钟，而这只是兜底；推送正常时它每次拿到的都是同一个状态。
const POLL_SEC := 3.0

# 确认框倒计时的显示上限。与 matchmaking.ACCEPT_TIMEOUT_SEC 一致，
# 对不上只是显示不准（真正的时限在服务器，见文件头第 2 条）。
const ACCEPT_SEC := 30.0

var _mode := "casual"
var _state := "idle"
var _accept_deadline := 0.0
var _poll_timer := 0.0
var _busy := false

var _title: Label
var _detail: Label
var _accept_btn: Button
var _leave_btn: Button


func configure(mode: String) -> void:
	_mode = mode


func _ready() -> void:
	theme = Theming.get_theme()
	_build()
	if not RealtimeService.message_received.is_connected(_on_realtime_message):
		RealtimeService.message_received.connect(_on_realtime_message)
	_join()


func _exit_tree() -> void:
	if RealtimeService.message_received.is_connected(_on_realtime_message):
		RealtimeService.message_received.disconnect(_on_realtime_message)


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(560, 0)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(column)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	_title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	column.add_child(_title)

	_detail = Label.new()
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size = Vector2(0, 52)
	_detail.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(_detail)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", Tokens.GAP_M)
	column.add_child(row)

	_accept_btn = ACTION_BUTTON.instantiate() as Button
	_accept_btn.text = _text("确认", "Accept")
	_accept_btn.visible = false
	_accept_btn.pressed.connect(_on_accept)
	row.add_child(_accept_btn)

	_leave_btn = ACTION_BUTTON.instantiate() as Button
	_leave_btn.text = _text("取消排队", "Leave Queue")
	_leave_btn.pressed.connect(_on_leave)
	row.add_child(_leave_btn)

	_apply({"state": "idle"})


# --- 网络 ---------------------------------------------------------------------

func _join() -> void:
	_set_detail(_text("正在进入队列…", "Joining queue…"))
	var result: Dictionary = await AccountManager.join_match_queue(_mode)
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		# 窗口外 / 信誉分不够 / 被禁赛 / 未登录 / 服务器不在：说清楚，然后让玩家退出去。
		# 卡在一条永远凑不齐的队里是最让人摸不着头脑的一种失败。
		#
		# 文案用服务器给的那一句（backend/app/routes/matchmaking.py 的 _GATE_TEXT）——
		# 闸的规则在服务器，文案跟着规则走，客户端再写一份迟早对不上。
		_fail(str(result.get("error", _text("进不了队列", "Could not join the queue"))))
		return
	_apply((result.get("body", {}) as Dictionary).get("state", {}))


func _on_accept() -> void:
	if _busy:
		return
	_busy = true
	_accept_btn.disabled = true
	_set_detail(_text("已确认，等其他人…", "Accepted, waiting for others…"))
	var result: Dictionary = await AccountManager.accept_match()
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		_fail(str(result.get("error", _text("确认失败", "Accept failed"))))
		return
	_apply((result.get("body", {}) as Dictionary).get("state", {}))


func _on_leave() -> void:
	SfxService.play(SfxService.CUE_UI_CONFIRM)
	# 不等回执就关：退队列是「尽力而为」的动作，等一趟网络只会让界面卡住。
	# 真没退成的话，服务器那边的掉线宽限会收拾（QUEUE_GRACE_SEC）。
	AccountManager.leave_match_queue()
	dismissed.emit()


# WS 推送与轮询走同一个函数 —— 两边是同一个形状（见文件头第 1 条）。
func _on_realtime_message(payload: Dictionary) -> void:
	if str(payload.get("t", "")) == "match":
		_apply(payload)


func _process(delta: float) -> void:
	if _state == "found" and _accept_deadline > 0.0:
		var left := maxi(0, int(ceil(_accept_deadline - Time.get_ticks_msec() / 1000.0)))
		_title.text = "%s %d" % [_text("找到对局！", "Match found!"), left]
	if _state in ["idle", "ready"]:
		return
	# WS 断着时的兜底。连着的时候也轮询，只是拿到的都是同一个状态 ——
	# 代价可忽略，而少了它就得判断「WS 到底算不算连着」，那比多发一个请求难得多。
	_poll_timer += delta
	if _poll_timer < POLL_SEC:
		return
	_poll_timer = 0.0
	_poll()


func _poll() -> void:
	if _busy:
		return
	_busy = true
	var result: Dictionary = await AccountManager.fetch_match_state()
	_busy = false
	if not is_inside_tree() or int(result.get("code", 0)) != 200:
		return
	_apply((result.get("body", {}) as Dictionary).get("state", {}))


# --- 状态机 -------------------------------------------------------------------

func _apply(state: Dictionary) -> void:
	var next := str(state.get("state", "idle"))
	_state = next
	match next:
		"queued":
			_title.text = _text("匹配中…", "Searching…")
			var position := int(state.get("position", 0))
			_set_detail(_text("队列位置 %d · %s" % [position, _mode_word()],
				"Queue position %d · %s" % [position, _mode_word()]))
			_accept_btn.visible = false
			_accept_btn.disabled = false
			_leave_btn.text = _text("取消排队", "Leave Queue")
		"found":
			SfxService.play(SfxService.CUE_UI_POPUP)
			# 倒计时只是显示，真正的时限在服务器（见文件头第 2 条）。
			_accept_deadline = Time.get_ticks_msec() / 1000.0 + minf(
				ACCEPT_SEC, float(state.get("accept_sec", ACCEPT_SEC)))
			_title.text = _text("找到对局！", "Match found!")
			_set_detail(_text("六个人都确认才开始。不确认会被移出队列。",
				"All six must accept. Not accepting drops you from the queue."))
			_accept_btn.visible = true
			_accept_btn.disabled = false
			_leave_btn.text = _text("拒绝", "Decline")
		"ready":
			_title.text = _text("准备进入对局", "Entering match")
			_set_detail(_text("正在连接对战服务器…", "Connecting to the battle server…"))
			_accept_btn.visible = false
			_leave_btn.visible = false
			match_ready.emit()
		_:
			# idle：被解散、被移出队列、或者自己退了。
			_title.text = _text("不在队列中", "Not in queue")
			if str(state.get("reason", "")) == "declined":
				_set_detail(_text("你没有确认，已被移出队列。",
					"You did not accept and were removed from the queue."))
			_accept_btn.visible = false
			_leave_btn.text = _text("关闭", "Close")


func _fail(message: String) -> void:
	_state = "idle"
	_title.text = _text("排不了队", "Cannot queue")
	_set_detail(message)
	_accept_btn.visible = false
	_leave_btn.text = _text("关闭", "Close")


func _set_detail(text_value: String) -> void:
	if _detail != null and is_instance_valid(_detail):
		_detail.text = text_value


func _mode_word() -> String:
	match _mode:
		"ranked": return _text("排位", "Ranked")
		_: return _text("休闲", "Casual")


func _text(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
