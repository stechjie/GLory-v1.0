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
# 10.10 bug 第 6 条：确认阶段要画两支队伍的头像（打√表示已确认）。
const AVATARS := preload("res://scripts/account/AvatarCatalog.gd")

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
var _party_queue := false
# 10.07 第 14 条后取消对全队一视同仁，这个旗标不再决定行为；保留它是为了不
# 动 configure() 的签名（Main.gd 仍然按原有位置传 host 标记）。
var _party_host := false
var _state := "idle"
var _accept_deadline := 0.0
var _poll_timer := 0.0
var _busy := false

var _title: Label
var _detail: Label
var _accept_btn: Button
var _leave_btn: Button
# 10.10 bug 第 6 条：确认阶段的两队头像条（两行三列，同对局内左上角的排法）。
var _roster: VBoxContainer


func configure(mode: String, party_queue: bool = false, party_host: bool = false) -> void:
	_mode = mode
	_party_queue = party_queue
	_party_host = party_host


func _ready() -> void:
	theme = Theming.get_theme()
	_build()
	if not RealtimeService.message_received.is_connected(_on_realtime_message):
		RealtimeService.message_received.connect(_on_realtime_message)
	if _party_queue:
		_poll()
	else:
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

	# 10.10 bug 第 6 条：两队头像（上=红队三席、下=蓝队三席）。只在 found 状态显示。
	_roster = VBoxContainer.new()
	_roster.add_theme_constant_override("separation", 10)
	_roster.visible = false
	column.add_child(_roster)

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
	# 10.10 bug 第 6 条：不再写「已确认，等其他人…」—— 确认后自己那颗头像会打√
	# （服务端 found 消息带 seats），这里只把提示清掉，避免和头像重复。
	_set_detail("")
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
	if _party_queue and _state == "queued":
		# 10.07 第 14 条：队里**任意成员**取消都只是取消匹配，全队回到房间。
		# 以前非房主走 leave_party()，那是退房 —— 房主以外的队友一点取消就掉出队伍。
		AccountManager.cancel_party_match()
		dismissed.emit()
		return
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
		# 10.10 bug 第 6 条：标题改成「匹配成功。确认倒计时：N」。
		_title.text = _text("匹配成功。确认倒计时：%d", "Match found. Confirming in %d") % left
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
	# 上一个状态要在覆盖之前记下来：下面 found 分支的音效只能在**刚进入** found
	# 时响。原来是无条件 play，而 _poll() 每 3 秒就会带着同一个 found 再走一遍
	# _apply —— 于是那 30 秒确认窗口里弹窗音效会响十次。
	var previous := _state
	_state = next
	match next:
		"queued":
			_title.text = _text("匹配中…", "Searching…")
			var position := int(state.get("position", 0))
			_set_detail(_text("队列位置 %d · %s" % [position, _mode_word()],
				"Queue position %d · %s" % [position, _mode_word()]))
			_accept_btn.visible = false
			_accept_btn.disabled = false
			_roster.visible = false
			_leave_btn.text = _text("取消排队", "Leave Queue")
		"found":
			if previous != "found":
				SfxService.play(SfxService.CUE_UI_POPUP)
			# 倒计时只是显示，真正的时限在服务器（见文件头第 2 条）。
			_accept_deadline = Time.get_ticks_msec() / 1000.0 + minf(
				ACCEPT_SEC, float(state.get("accept_sec", ACCEPT_SEC)))
			_title.text = _text("匹配成功。确认倒计时：%d", "Match found. Confirming in %d") % int(
				ceil(minf(ACCEPT_SEC, float(state.get("accept_sec", ACCEPT_SEC)))))
			# 10.10 bug 第 6 条：删掉「已确认 N/6，等其他人…」，换成**两队头像 + √** ——
			# 谁确认了直接看头像上有没有√，比一行计数更清楚，也不会和轮询重画打架。
			_render_roster(state.get("seats", []))
			# 「我按了没」由服务器说（协议里原来没有这一位）。
			var accepted := bool(state.get("accepted", false))
			if accepted:
				_set_detail("")
				# 按钮留在原位但禁用：直接隐藏会让布局跳一下，而玩家刚按完正盯着它。
				_accept_btn.visible = true
				_accept_btn.disabled = true
			else:
				_set_detail(_text("六个人都确认才开始。不确认会被移出队列。",
					"All six must confirm to start. Not confirming drops you from the queue."))
				_accept_btn.visible = true
				_accept_btn.disabled = false
			_leave_btn.text = _text("拒绝", "Decline")
		"ready":
			_title.text = _text("准备进入对局", "Entering match")
			_set_detail(_text("正在连接对战服务器…", "Connecting to the battle server…"))
			_roster.visible = false
			_accept_btn.visible = false
			_leave_btn.visible = false
			# 🔴 **只在刚进入 ready 时发一次。**
			#
			# ready 现在有两条送达路径：自己那次 accept 的 HTTP 回包，和服务端
			# `_finalise` 的推送（后者是 2026-10-08 新加的，修「匹配成功跳主界面」）。
			# 第 6 个按确认的人会两条都收到，发两次的后果不是多余而是**有害**：
			# Main._on_match_ready() 第二遍会再调一次 team_join()，而它开头就
			# reset()，等于把第一次正在进行的连接亲手拆掉。
			if previous != "ready":
				match_ready.emit()
		_:
			# idle：被解散、被移出队列、或者自己退了。
			_title.text = _text("不在队列中", "Not in queue")
			if str(state.get("reason", "")) == "declined":
				_set_detail(_text("你没有确认，已被移出队列。",
					"You did not accept and were removed from the queue."))
			_accept_btn.visible = false
			_roster.visible = false
			_leave_btn.text = _text("关闭", "Close")


func _fail(message: String) -> void:
	_state = "idle"
	_title.text = _text("排不了队", "Cannot queue")
	_set_detail(message)
	_accept_btn.visible = false
	_roster.visible = false
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


# --- 10.10 bug 第 6 条：两队头像（确认的人打√）-----------------------------------
#
# 服务端 found 消息带 seats：每项 {team, seat, name, avatar, avatar_frame, accepted, me}
# （backend/app/matchmaking.py 的 _Pending.seat_roster，白名单只出昵称/头像/头像框）。
# 排法照对局内左上角：**红队一行、蓝队一行，每行三席**。
# 老服务端不下发 seats ⇒ 不画这一条，退回原来那句计数提示，不会崩。

# 单格盒边长：要**容得下最大的头像框**。框绘制尺寸 ≈ 内孔 ÷ 内孔占比，商城框最小
# 占比 0.5581 ⇒ 60 / 0.5581 ≈ 107.5，所以盒取 112。
const SEAT_CHIP := 112.0
# 头像圆直径。它**同时是「框内孔的目标直径」**：框按这个值反推绘制尺寸，头像圆正好
# 盖住内孔、框环露在外面（与自定义房间 / 3v3 大厅同一套 catalog 几何）。
const SEAT_DISC := 60.0
# 已确认的记号。不是汉字，不必进 LocaleManager。
const TICK := "√"


# 把 seats 画成「红队一行、蓝队一行」。空 / 老协议（没有 seats）就整条收起来。
func _render_roster(seats: Variant) -> void:
	if not (seats is Array) or (seats as Array).is_empty():
		_roster.visible = false
		return
	_roster.visible = true
	_clear_children(_roster)
	var rows: Array = [HBoxContainer.new(), HBoxContainer.new()]
	for row in rows:
		var line: HBoxContainer = row
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.add_theme_constant_override("separation", Tokens.GAP_S)
		_roster.add_child(line)
	for seat in seats:
		if not (seat is Dictionary):
			continue
		var team := clampi(int((seat as Dictionary).get("team", 0)), 0, 1)
		(rows[team] as HBoxContainer).add_child(_seat_chip(seat))


# 画一格头像。**框在头像下面**，头像做圆裁剪后盖住内孔。
#
# ★ 顺序不能反：`frame_default` 的素材中心是**不透明的**金棕圆盘（实测
#   assets/ui/main_menu_live/profile_avatar.png 中心 alpha=255），框画在头像上面
#   会把整张头像盖掉；而头像缩略图是**方图、四角不透明**，不裁剪会从圆孔的四角戳出来。
#   所以必须「框在下 + 头像圆裁剪在上 + 内孔对齐头像圆」—— 与 PartyLobby /
#   Team3v3Lobby 的席位头像同一套（frame_drawn_size / frame_box_origin）。
func _seat_chip(seat: Dictionary) -> Control:
	var accepted := bool(seat.get("accepted", false))
	var frame_value := str(seat.get("avatar_frame", ""))
	var frame_id := AVATARS.id_from_value(frame_value)
	var center := Vector2(SEAT_CHIP, SEAT_CHIP) * 0.5

	var box := Control.new()
	box.custom_minimum_size = Vector2(SEAT_CHIP, SEAT_CHIP)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# ① 框（在下面）：内孔圆心压在头像圆心上，尺寸由内孔反推。
	var frame := TextureRect.new()
	frame.texture = AVATARS.frame_texture_for(frame_value)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var drawn := AVATARS.frame_drawn_size(frame_id, SEAT_DISC)
	if frame.texture != null and drawn.x > 0.0:
		frame.size = drawn
		frame.position = AVATARS.frame_box_origin(frame_id, SEAT_DISC, center)
	else:
		# 图缺失 / 算不出尺寸：宁可少一个装饰，也不能留一个盖住头像的空框。
		frame.size = Vector2(SEAT_CHIP, SEAT_CHIP)
		frame.position = center - frame.size * 0.5
	box.add_child(frame)

	# ② 头像（在上面）：圆裁剪，直径 == 内孔目标。
	var mask := Panel.new()
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color.WHITE
	circle.set_corner_radius_all(int(SEAT_DISC * 0.5))
	mask.add_theme_stylebox_override("panel", circle)
	mask.size = Vector2(SEAT_DISC, SEAT_DISC)
	mask.position = center - mask.size * 0.5
	box.add_child(mask)
	var avatar := str(seat.get("avatar", ""))
	if avatar.is_empty():
		avatar = AVATARS.default_avatar()
	var portrait := TextureRect.new()
	portrait.texture = AVATARS.texture_for(avatar, true)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.position = Vector2.ZERO
	portrait.size = mask.size
	mask.add_child(portrait)

	if accepted:
		var tick := Label.new()
		tick.text = TICK
		tick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tick.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tick.add_theme_font_size_override("font_size", 30)
		tick.add_theme_color_override("font_color", Color("7ce6a0"))
		tick.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		tick.add_theme_constant_override("outline_size", 8)
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tick.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.add_child(tick)
	else:
		# 还没确认 → 整格（框 + 头像一起）压暗。一眼看出「谁还没按」，省掉那行计数文案。
		box.modulate = Color(1, 1, 1, 0.32)
	return box


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
