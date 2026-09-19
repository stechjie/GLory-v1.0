extends Control

# 私聊界面（docs/聊天系统设计.md 批次 C，第六节「方案一」）。
#
# 入口两个：主菜单左侧「聊天」按钮（此前是「敬请期待」），好友列表每一行的「私聊」。
# 左栏是**全部好友** —— 聊过的按最后一条消息排前面、带未读红点，没聊过的排后面，
# 所以这里兼做选人。右边是消息区。世界频道（批次 E）以后作为另一个页签加进来。
#
# ## 四条纪律
#
# 1. **昵称永远和好友码一起显示**，只走 AccountManager.display_name()（同好友界面）。
# 2. **正确性靠游标，不靠推送。** 推送只是「快」：打开会话时全量拉一次，
#    WebSocket 重连之后按 after=<最后一条> 补拉。推送漏了只会晚到，不会丢。
# 3. **按钮不用 Button.new()**，一律实例化 ui/components/GloryActionButton.tscn ——
#    V3 P1-08 的棘轮盯着业务代码里自绘按钮的数量，只能降不能涨。
# 4. **被顶号时不自动重连。** 显示原因 +「在本设备重新连接」，玩家亲手点才连 ——
#    自动再连会让两台设备无限互踢。

signal back_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")

const LIST_WIDTH := 332.0
const ROW_HEIGHT := 72.0
const AVATAR_SIZE := 46.0
# 标题栏左右两侧等宽：左边是返回按钮，右边垫同样宽的空白，标题才在正中。
const HEADER_SIDE_WIDTH := 120.0
# 气泡最宽占消息区的多少。再宽就看不出「谁说的」—— 左右对齐靠留白才读得出来。
const BUBBLE_MAX_RATIO := 0.62
# 离底部多近算「正看着最新消息」。在这个范围内来了新消息就跟着滚到底；
# 往上翻历史的时候不跟 —— 否则每来一条都会把人拽回底部。
const STICK_TO_BOTTOM_PX := 64.0

var _focus_code := ""
var _chats: Array = []
var _open_code := ""
# 当前会话的消息。已确认的按 message_id 升序；发送中 / 发送失败的排在最后，按本地序号。
var _messages: Array[Dictionary] = []
var _local_seq := 0
var _list_loading := false

var _list_box: VBoxContainer
var _friend_count_label: Label
var _status_label: Label
var _notice_label: Label
var _peer_label: Label
var _peer_code_label: Label
var _peer_avatar: TextureRect
var _kicked_bar: Control
var _msg_scroll: ScrollContainer
var _msg_box: VBoxContainer
var _input: LineEdit
var _send_button: Button


# 从好友列表进来时带上对方的好友码，打开就定位到那个会话。
func configure(focus_code: String) -> void:
	_focus_code = "" if focus_code.is_empty() else AccountManager.normalize_friend_code(focus_code)


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	ChatService.dm_received.connect(_on_dm_received)
	ChatService.unread_changed.connect(_on_unread_changed)
	ChatService.kicked_changed.connect(_on_kicked_changed)
	RealtimeService.connection_changed.connect(_on_connection_changed)
	_on_kicked_changed(ChatService.kicked)
	_render_messages()
	await _reload_list()
	if not _focus_code.is_empty() and is_inside_tree():
		await _open(_focus_code)


func _exit_tree() -> void:
	# ChatService / RealtimeService 是 autoload，活得比这个界面久 —— 连接必须显式断开，
	# 否则界面关掉之后，回调还会打到一个已经不在树上的节点。
	ChatService.set_open_conversation("")
	if ChatService.dm_received.is_connected(_on_dm_received):
		ChatService.dm_received.disconnect(_on_dm_received)
	if ChatService.unread_changed.is_connected(_on_unread_changed):
		ChatService.unread_changed.disconnect(_on_unread_changed)
	if ChatService.kicked_changed.is_connected(_on_kicked_changed):
		ChatService.kicked_changed.disconnect(_on_kicked_changed)
	if RealtimeService.connection_changed.is_connected(_on_connection_changed):
		RealtimeService.connection_changed.disconnect(_on_connection_changed)


# --- 骨架 ---------------------------------------------------------------------


func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = MENU_BG_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var dim := ColorRect.new()
	dim.color = Tokens.BACKDROP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, Tokens.PAD)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", Tokens.GAP_M)
	margin.add_child(root)
	root.add_child(_header())

	_notice_label = Label.new()
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice_label.visible = false
	root.add_child(_notice_label)

	# 好友与对话属于同一个通讯面板。统一外框比两个并排的金边黑框更像游戏内设施，
	# 中间只留一条低对比度分隔线，让注意力落在玩家与消息上。
	var shell := PanelContainer.new()
	shell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	shell.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.INK_PANEL, Tokens.INK_EDGE, Tokens.GAP_S))
	root.add_child(shell)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", Tokens.GAP_S)
	shell.add_child(body)
	body.add_child(_list_panel())

	var divider := ColorRect.new()
	divider.custom_minimum_size = Vector2(1, 0)
	divider.color = Tokens.INK_EDGE.darkened(0.42)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(divider)
	body.add_child(_conversation_panel())


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)
	var back := _button(_text("← 返回", "← Back"), func() -> void: back_requested.emit())
	back.custom_minimum_size = Vector2(HEADER_SIDE_WIDTH, Tokens.TOUCH_MIN)
	row.add_child(back)

	var title := Label.new()
	title.text = _text("好友私聊", "Friend Chat")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(title)

	# 右边垫一块与返回按钮等宽的空白 —— 否则标题会随右边有没有东西左右漂
	# （第一版把连接状态放在这里，出图一看，标题在两种状态下不在同一个位置）。
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(HEADER_SIDE_WIDTH, 0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	return row


func _list_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(LIST_WIDTH, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER.darkened(0.42), Tokens.GAP_S))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(col)

	var list_head := HBoxContainer.new()
	list_head.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	col.add_child(list_head)

	var list_title := Label.new()
	list_title.text = _text("好友", "Friends")
	list_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_title.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	list_title.add_theme_color_override("font_color", Tokens.GOLD)
	list_head.add_child(list_title)

	_friend_count_label = Label.new()
	_friend_count_label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_friend_count_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	list_head.add_child(_friend_count_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", Tokens.GAP_S)
	scroll.add_child(_list_box)

	# 隐私义务：保留规则必须出现在玩家看得到的地方（设计文档第三节）。
	var retention := Label.new()
	retention.text = _text(
		"ⓘ 最近 %d 条 · 解除好友后最多保留 30 天" % ChatService.HISTORY_LIMIT,
		"ⓘ Latest %d · kept for 30 days" % ChatService.HISTORY_LIMIT)
	retention.tooltip_text = _text(
		"与每位好友只保留最近 %d 条消息；解除好友后，记录最多再保留 30 天。" % ChatService.HISTORY_LIMIT,
		"Only your latest %d messages with each friend are kept; after unfriending, they are kept for at most 30 more days." % ChatService.HISTORY_LIMIT)
	retention.clip_text = true
	retention.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	retention.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
	col.add_child(retention)
	return panel


func _conversation_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER.darkened(0.42), Tokens.GAP_S))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(col)

	# 顶上一行：在跟谁聊 + 连接状态。状态放这里而不是标题栏 ——
	# 它说的是「这段对话的新消息会不会实时出现」，挨着对话才读得懂。
	var head_panel := PanelContainer.new()
	head_panel.custom_minimum_size = Vector2(0, 64)
	head_panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE_RAISED, Tokens.BORDER.darkened(0.25), Tokens.GAP_S))
	col.add_child(head_panel)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Tokens.GAP_S)
	head_panel.add_child(head)

	_peer_avatar = TextureRect.new()
	_peer_avatar.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	_peer_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_peer_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_peer_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_peer_avatar)

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 0)
	head.add_child(identity)

	_peer_label = Label.new()
	_peer_label.clip_text = true
	_peer_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	_peer_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	identity.add_child(_peer_label)

	_peer_code_label = Label.new()
	_peer_code_label.clip_text = true
	_peer_code_label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_peer_code_label.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
	identity.add_child(_peer_code_label)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_status_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	head.add_child(_status_label)

	_kicked_bar = _build_kicked_bar()
	col.add_child(_kicked_bar)

	var message_well := PanelContainer.new()
	message_well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	message_well.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.BG_DEEP, Tokens.BORDER.darkened(0.55), Tokens.GAP_S))
	col.add_child(message_well)

	_msg_scroll = ScrollContainer.new()
	_msg_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_msg_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	message_well.add_child(_msg_scroll)

	_msg_box = VBoxContainer.new()
	_msg_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msg_box.add_theme_constant_override("separation", Tokens.GAP_S)
	_msg_scroll.add_child(_msg_box)

	var composer := PanelContainer.new()
	composer.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE_RAISED, Tokens.BORDER.darkened(0.25), Tokens.GAP_S))
	col.add_child(composer)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", Tokens.GAP_S)
	composer.add_child(input_row)

	_input = LineEdit.new()
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	# 与服务端 text_guard.CHAT_MAX 同一个数（tools/chat_check.gd 钉着，不许写死）。
	_input.max_length = ChatService.MAX_BODY_CHARS
	_input.placeholder_text = _text("说点什么…", "Say something…")
	_input.text_submitted.connect(func(_submitted: String) -> void: _on_send_pressed())
	input_row.add_child(_input)

	_send_button = _button(_text("发送", "Send"), _on_send_pressed)
	_send_button.theme_type_variation = Theming.VARIATION_PRIMARY
	_send_button.custom_minimum_size = Vector2(104, Tokens.TOUCH_MIN)
	input_row.add_child(_send_button)
	return panel


func _build_kicked_bar() -> Control:
	var panel := PanelContainer.new()
	panel.visible = false
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.GOLD_PRESSED.darkened(0.72), Tokens.GOLD_PRESSED, Tokens.GAP_S))

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(bar)

	var icon := Label.new()
	icon.text = "!"
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	icon.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	icon.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	bar.add_child(icon)

	var reason := Label.new()
	# 说清楚是**什么事**，不是「连接已断开」这种什么都没说的话（设计文档第五节）。
	reason.text = _text(
		"你的账号在另一台设备上登录了，这里的聊天已断开。",
		"Your account signed in on another device, so chat here was disconnected.")
	reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reason.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reason.add_theme_color_override("font_color", Tokens.GOLD)
	bar.add_child(reason)

	# 这一下会把另一台设备顶下线 —— 所以只能是玩家亲手点。
	var reconnect := _button(_text("在本设备重新连接", "Reconnect here"),
		func() -> void: ChatService.reconnect_here())
	reconnect.theme_type_variation = Theming.VARIATION_PRIMARY
	bar.add_child(reconnect)
	return panel


# --- 数据 ---------------------------------------------------------------------


func _reload_list() -> void:
	if _list_loading:
		return
	_list_loading = true
	var result: Dictionary = await AccountManager.fetch_chats()
	_list_loading = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 != 2:
		_set_notice(str(result.get("error", _text("加载失败", "Failed to load"))), true)
		return
	_chats = (result.get("body", {}) as Dictionary).get("chats", [])
	# 顺手用服务端的列表对一次红点的账（以服务端为准）。
	ChatService.apply_chat_list(_chats)
	_render_list()
	_update_peer_label()


func _open(code: String) -> void:
	if code.is_empty():
		return
	_open_code = code
	ChatService.set_open_conversation(code)
	_messages.clear()
	_set_notice("", false)
	_update_peer_label()
	_render_list()
	_render_messages()
	await _fetch_messages(true)


# full=true：打开会话时全量拉最近 HISTORY_LIMIT 条。
# full=false：WebSocket 重连之后按游标补拉 —— 断线期间的推送全漏了，只能靠它。
func _fetch_messages(full: bool) -> void:
	var code := _open_code
	if code.is_empty():
		return
	var after := 0 if full else _last_confirmed_id()
	var result: Dictionary = await AccountManager.fetch_chat_messages(code, after)
	if not is_inside_tree() or code != _open_code:
		return  # 等的时候切走了，这批结果已经不属于当前界面
	if int(result.get("code", 0)) / 100 != 2:
		_set_notice(str(result.get("error", _text("加载失败", "Failed to load"))), true)
		return
	_merge((result.get("body", {}) as Dictionary).get("messages", []))
	_render_messages(full)
	_mark_latest_read()


func _merge(incoming: Array) -> void:
	var known := {}
	for msg in _messages:
		var known_id := int(msg.get("message_id", 0))
		if known_id > 0:
			known[known_id] = true
	for raw in incoming:
		if not (raw is Dictionary):
			continue
		var incoming_id := int((raw as Dictionary).get("message_id", 0))
		# 推送与补拉可能送来同一条，按 message_id 去重。
		if incoming_id <= 0 or known.has(incoming_id):
			continue
		known[incoming_id] = true
		var msg := (raw as Dictionary).duplicate()
		msg["state"] = "sent"
		_messages.append(msg)
	_messages.sort_custom(_before)
	# 与服务端一样只留 HISTORY_LIMIT 条已确认的（发送中 / 失败的另算，排在末尾）。
	var confirmed := 0
	for msg in _messages:
		if int(msg.get("message_id", 0)) > 0:
			confirmed += 1
	while confirmed > ChatService.HISTORY_LIMIT:
		_messages.remove_at(0)
		confirmed -= 1


# 已确认的按 message_id 升序在前；发送中 / 失败的按本地序号排在最后。
func _before(a: Dictionary, b: Dictionary) -> bool:
	var ia := int(a.get("message_id", 0))
	var ib := int(b.get("message_id", 0))
	if (ia > 0) != (ib > 0):
		return ia > 0
	if ia > 0:
		return ia < ib
	return int(a.get("seq", 0)) < int(b.get("seq", 0))


func _last_confirmed_id() -> int:
	var best := 0
	for msg in _messages:
		best = maxi(best, int(msg.get("message_id", 0)))
	return best


func _mark_latest_read() -> void:
	var last := _last_confirmed_id()
	if last > 0 and not _open_code.is_empty():
		ChatService.mark_read(_open_code, last)


# 左栏那一行的「最后一条」跟着更新并挪到最前面 —— 不必为此再拉一次列表。
func _note_last_message(code: String, msg: Dictionary) -> void:
	for i in _chats.size():
		var entry: Variant = _chats[i]
		if entry is Dictionary and str((entry as Dictionary).get("friend_code", "")) == code:
			var updated := (entry as Dictionary).duplicate()
			updated["last_message"] = {
				"message_id": int(msg.get("message_id", 0)),
				"from_me": bool(msg.get("from_me", false)),
				"body": str(msg.get("body", "")),
				"created_at": str(msg.get("created_at", "")),
			}
			_chats.remove_at(i)
			_chats.push_front(updated)
			_render_list()
			return
	# 列表里没有这个人（比如打开界面之后才成为好友的）：整体重拉。
	_reload_list()


# --- 发送 ---------------------------------------------------------------------


func _on_send_pressed() -> void:
	if _open_code.is_empty() or ChatService.kicked or _input == null:
		return
	var text := _input.text.strip_edges()
	if text.is_empty():
		return
	_input.text = ""
	_local_seq += 1
	var msg := {
		"message_id": 0,
		"from_me": true,
		"body": text,
		"created_at": "",
		"state": "pending",
		"seq": _local_seq,
		# 重发时**原样复用** —— 服务端靠它认出重发，对方不会收到两条。
		"client_msg_id": ChatService.new_client_msg_id(),
	}
	_messages.append(msg)
	_render_messages(true)
	await _deliver(msg)


func _deliver(msg: Dictionary) -> void:
	# 被顶号时这台设备不再发。输入框已经禁用、「重发」也藏了，这里是兜底 ——
	# 第一版漏了它，出图时看到被顶号状态下「重发」照样能点。
	if ChatService.kicked:
		return
	var code := _open_code
	msg["state"] = "pending"
	_render_messages()
	var result: Dictionary = await AccountManager.send_chat_message(
		code, str(msg.get("body", "")), str(msg.get("client_msg_id", "")))
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 == 2:
		var server: Dictionary = (result.get("body", {}) as Dictionary).get("message", {})
		msg["message_id"] = int(server.get("message_id", 0))
		# 显示**存下来的**版本（服务端会把换行压成空格等），不是自己发的原文。
		msg["body"] = str(server.get("body", msg.get("body", "")))
		msg["created_at"] = str(server.get("created_at", ""))
		msg["state"] = "sent"
		_note_last_message(code, msg)
	else:
		msg["state"] = "failed"
		msg["error"] = str(result.get("error", _text("网络错误", "Network error")))
	if code == _open_code:
		_messages.sort_custom(_before)
		_render_messages()


# --- 推送与连接 ---------------------------------------------------------------


func _on_dm_received(code: String, message: Dictionary) -> void:
	_note_last_message(code, message)
	if code != _open_code:
		return
	_merge([message])
	_render_messages()
	_mark_latest_read()


func _on_unread_changed(_any_unread: bool) -> void:
	_render_list()


func _on_connection_changed(_state: int) -> void:
	_refresh_status()
	if not RealtimeService.is_online():
		return
	# 重连成功：断线期间的推送全漏了，按游标补拉（正确性靠游标，不靠推送）。
	if not _open_code.is_empty():
		await _fetch_messages(false)
	if is_inside_tree():
		await _reload_list()


func _on_kicked_changed(kicked: bool) -> void:
	if _kicked_bar != null:
		_kicked_bar.visible = kicked
	_refresh_status()
	_refresh_input()
	# 失败消息旁边的「重发」也要跟着藏起来 / 露出来（见 _bubble）。
	_render_messages()


func _refresh_status() -> void:
	if _status_label == null:
		return
	if ChatService.kicked:
		# 被顶号的原因由消息区上方那一条说，这里不重复。
		_status_label.text = ""
	elif RealtimeService.is_online():
		if _open_code.is_empty():
			_status_label.text = ""
			return
		var peer_online := false
		for entry in _chats:
			if entry is Dictionary and str((entry as Dictionary).get("friend_code", "")) == _open_code:
				peer_online = bool((entry as Dictionary).get("online", false))
				break
		_status_label.text = _text("● 在线", "● Online") if peer_online else _text("● 离线", "● Offline")
		_status_label.add_theme_color_override("font_color",
			Tokens.CYAN if peer_online else Tokens.TEXT_DISABLED)
	else:
		# 发送不受影响（走 HTTPS），受影响的只是「新消息实时出现」。
		_status_label.text = _text("连接中…", "Connecting…")
		_status_label.tooltip_text = _text(
			"正在连接，新消息可能晚一点到", "Connecting; new messages may be delayed")
		_status_label.add_theme_color_override("font_color", Tokens.GOLD)


func _refresh_input() -> void:
	if _input == null or _send_button == null:
		return
	var usable := not _open_code.is_empty() and not ChatService.kicked
	_input.editable = usable
	_send_button.disabled = not usable


# --- 渲染 ---------------------------------------------------------------------


func _render_list() -> void:
	if _list_box == null:
		return
	if _friend_count_label != null:
		_friend_count_label.text = _text("%d 位" % _chats.size(), "%d total" % _chats.size())
	for child in _list_box.get_children():
		child.queue_free()
	if _chats.is_empty():
		_list_box.add_child(_hint(_text(
			"还没有好友。先到「朋友」里用好友码加人，才能私聊。",
			"No friends yet. Add someone by friend code in Friends first.")))
		return
	for entry in _chats:
		if entry is Dictionary:
			_list_box.add_child(_chat_row(entry as Dictionary))


func _chat_row(entry: Dictionary) -> Control:
	var code := str(entry.get("friend_code", ""))
	var row := _button("", func() -> void: _open(code))
	row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.toggle_mode = true
	row.button_pressed = code == _open_code
	var selected := code == _open_code
	var base := Tokens.GOLD_PRESSED.darkened(0.72) if selected else Tokens.SURFACE
	var edge := Tokens.GOLD_PRESSED if selected else Tokens.BORDER.darkened(0.42)
	row.add_theme_stylebox_override("normal", Tokens.button_box(base, edge))
	row.add_theme_stylebox_override("hover", Tokens.button_box(
		Tokens.SURFACE_RAISED, Tokens.GOLD_PRESSED))
	row.add_theme_stylebox_override("pressed", Tokens.button_box(
		Tokens.GOLD_PRESSED.darkened(0.78), Tokens.GOLD))
	row.add_theme_stylebox_override("focus", Tokens.focus_box())

	# 按钮不会给子节点排版：内容挂在一个铺满的容器里，且一律不吃点击 ——
	# 否则点在名字上会被 Label 吞掉，按钮收不到。
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, Tokens.GAP_S)
	row.add_child(margin)

	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", Tokens.GAP_S)
	margin.add_child(line)

	var avatar_panel := PanelContainer.new()
	avatar_panel.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	avatar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar_panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.BG_DEEP, Tokens.GOLD_PRESSED if selected else Tokens.BORDER, 2))
	line.add_child(avatar_panel)

	var avatar := TextureRect.new()
	avatar.texture = Catalog.texture_for(str(entry.get("avatar", "")), true)
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar_panel.add_child(avatar)

	var texts := VBoxContainer.new()
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 0)
	line.add_child(texts)

	var name_line := HBoxContainer.new()
	name_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_line.add_theme_constant_override("separation", Tokens.GAP_S)
	texts.add_child(name_line)

	var online_dot := Label.new()
	online_dot.text = "●"
	online_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	online_dot.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	online_dot.add_theme_color_override("font_color",
		Tokens.CYAN if bool(entry.get("online", false)) else Tokens.TEXT_DISABLED)
	name_line.add_child(online_dot)

	var name_label := Label.new()
	var identity_text := AccountManager.display_name(str(entry.get("player_name", "")), code)
	var code_suffix := " #" + code
	name_label.text = identity_text.trim_suffix(code_suffix)
	name_label.clip_text = true
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_color_override("font_color", Tokens.GOLD if selected else Tokens.TEXT_PRIMARY)
	name_line.add_child(name_label)

	var code_label := Label.new()
	code_label.text = identity_text.trim_prefix(name_label.text).strip_edges()
	code_label.clip_text = true
	code_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	code_label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	code_label.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
	name_line.add_child(code_label)

	var preview_line := HBoxContainer.new()
	preview_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_line.add_theme_constant_override("separation", Tokens.GAP_S)
	texts.add_child(preview_line)

	var preview := Label.new()
	preview.text = _preview_text(entry)
	preview.clip_text = true
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	preview.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	preview_line.add_child(preview)

	var stamp := Label.new()
	stamp.text = _friend_time(entry)
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stamp.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	stamp.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
	preview_line.add_child(stamp)

	var dot := Label.new()
	dot.text = "●"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
	dot.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	# 红点只看 ChatService —— 状态只有一份，主菜单和好友列表看的也是它。
	dot.visible = ChatService.has_unread(code)
	line.add_child(dot)
	return row


func _preview_text(entry: Dictionary) -> String:
	var last: Variant = entry.get("last_message")
	if not (last is Dictionary):
		return _text("还没有消息", "No messages yet")
	var msg := last as Dictionary
	var body := str(msg.get("body", ""))
	if bool(msg.get("from_me", false)):
		body = _text("我：", "Me: ") + body
	return body


func _friend_time(entry: Dictionary) -> String:
	var last: Variant = entry.get("last_message")
	if not (last is Dictionary):
		return ""
	return _format_time(str((last as Dictionary).get("created_at", "")))


func _update_peer_label() -> void:
	if _peer_label == null:
		return
	if _open_code.is_empty():
		_peer_label.text = _text("选择一位好友", "Choose a friend")
		_peer_code_label.text = _text("从左侧列表开始私聊", "Select someone from the list")
		_peer_avatar.texture = null
		return
	var peer_name := ""
	var peer_avatar := ""
	var peer_online := false
	for entry in _chats:
		if entry is Dictionary and str((entry as Dictionary).get("friend_code", "")) == _open_code:
			peer_name = str((entry as Dictionary).get("player_name", ""))
			peer_avatar = str((entry as Dictionary).get("avatar", ""))
			peer_online = bool((entry as Dictionary).get("online", false))
			break
	var identity_text := AccountManager.display_name(peer_name, _open_code)
	var code_suffix := " #" + _open_code
	_peer_label.text = identity_text.trim_suffix(code_suffix)
	_peer_code_label.text = identity_text.trim_prefix(_peer_label.text).strip_edges()
	_peer_avatar.texture = Catalog.texture_for(peer_avatar, true)
	_peer_label.tooltip_text = identity_text
	if RealtimeService.is_online() and not ChatService.kicked:
		_status_label.text = _text("● 在线", "● Online") if peer_online else _text("● 离线", "● Offline")
		_status_label.add_theme_color_override("font_color",
			Tokens.CYAN if peer_online else Tokens.TEXT_DISABLED)


func _render_messages(force_bottom: bool = false) -> void:
	if _msg_box == null:
		return
	var stick := force_bottom or _near_bottom()
	for child in _msg_box.get_children():
		child.queue_free()
	if _open_code.is_empty():
		_msg_box.add_child(_hint(_text(
			"从左边选一个好友开始聊天。", "Pick a friend on the left to start chatting.")))
	elif _messages.is_empty():
		_msg_box.add_child(_hint(_text("还没有消息，打个招呼吧。", "No messages yet. Say hi!")))
	else:
		var max_width := _bubble_max_width()
		for msg in _messages:
			_msg_box.add_child(_bubble(msg, max_width))
	_refresh_input()
	if stick:
		_scroll_to_bottom_later()


func _bubble(msg: Dictionary, max_width: float) -> Control:
	var mine := bool(msg.get("from_me", false))
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_END if mine else BoxContainer.ALIGNMENT_BEGIN

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.GOLD_PRESSED.darkened(0.64) if mine else Tokens.SURFACE_RAISED,
		Tokens.GOLD_PRESSED.darkened(0.18) if mine else Tokens.BORDER.darkened(0.28),
		12))
	col.add_child(panel)

	var label := Label.new()
	label.text = str(msg.get("body", ""))
	label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	# 短消息按自然宽度，长消息在 max_width 处折行。自动折行的 Label 放在收缩容器里
	# 会退化成「一个字一行」—— 必须给它一个明确的宽度。
	var natural := label.get_theme_font("font").get_string_size(
		label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_BODY).x
	if natural > max_width:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(max_width, 0)
	panel.add_child(label)

	var meta := HBoxContainer.new()
	meta.alignment = BoxContainer.ALIGNMENT_END if mine else BoxContainer.ALIGNMENT_BEGIN
	meta.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(meta)

	var caption := Label.new()
	caption.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if mine else HORIZONTAL_ALIGNMENT_LEFT
	var state := str(msg.get("state", "sent"))
	match state:
		"pending":
			caption.text = _text("••• 发送中", "••• Sending")
			caption.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
		"failed":
			caption.text = _text("未发送", "Not sent")
			caption.tooltip_text = str(msg.get("error", ""))
			caption.add_theme_color_override("font_color", Tokens.DANGER_HOVER)
		_:
			caption.text = _format_time(str(msg.get("created_at", "")))
			caption.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
	meta.add_child(caption)

	if state == "failed" and not ChatService.kicked:
		var retry := _button(_text("重发", "Retry"), func() -> void: _deliver(msg))
		retry.theme_type_variation = Theming.VARIATION_GHOST
		retry.custom_minimum_size = Vector2(76, Tokens.TOUCH_MIN)
		retry.size_flags_horizontal = Control.SIZE_SHRINK_END
		meta.add_child(retry)
	return row


func _bubble_max_width() -> float:
	var avail := _msg_scroll.size.x if _msg_scroll != null else 0.0
	if avail <= 0.0:
		# 第一次渲染时可能还没排过版。按屏幕宽度估一个，下一次渲染就准了。
		avail = get_viewport_rect().size.x - LIST_WIDTH - Tokens.PAD * 4
	return maxf(160.0, avail * BUBBLE_MAX_RATIO)


func _near_bottom() -> bool:
	if _msg_scroll == null:
		return true
	var bar := _msg_scroll.get_v_scroll_bar()
	return bar.value >= bar.max_value - bar.page - STICK_TO_BOTTOM_PX


func _scroll_to_bottom_later() -> void:
	# 新节点要等排完版才知道高度（旧节点也要到帧末才真正移除）；
	# 现在滚只会滚到旧的底部。
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or _msg_scroll == null:
		return
	_msg_scroll.scroll_vertical = int(_msg_scroll.get_v_scroll_bar().max_value)


# --- 小工具 -------------------------------------------------------------------


# 服务端给的是 UTC 的 isoformat（带时区与微秒）。只取到秒按 UTC 解析，再换成本地时间。
static func _format_time(iso: String) -> String:
	if iso.length() < 19:
		return ""
	var unix := Time.get_unix_time_from_datetime_string(iso.substr(0, 19))
	var bias_minutes := int(Time.get_time_zone_from_system().get("bias", 0))
	var local := Time.get_datetime_dict_from_unix_time(unix + bias_minutes * 60)
	var now := Time.get_datetime_dict_from_system()
	var clock := "%02d:%02d" % [int(local["hour"]), int(local["minute"])]
	if int(local["year"]) == int(now["year"]) and int(local["month"]) == int(now["month"]) \
			and int(local["day"]) == int(now["day"]):
		return clock
	return "%02d-%02d %s" % [int(local["month"]), int(local["day"]), clock]


func _set_notice(message: String, bad: bool) -> void:
	if _notice_label == null:
		return
	_notice_label.text = message
	_notice_label.visible = not message.is_empty()
	_notice_label.add_theme_color_override("font_color", Tokens.DANGER if bad else Tokens.GOLD)


func _hint(message: String) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER.darkened(0.55), Tokens.GAP_M))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	panel.add_child(label)
	return panel


# 所有按钮都从这里出：实例化组件，不写 Button.new()（见文件头第 3 条）。
func _button(label_text: String, on_press: Callable) -> Button:
	var button := ACTION_BUTTON.instantiate() as Button
	button.text = label_text
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	button.size_flags_horizontal = Control.SIZE_FILL
	if on_press.is_valid():
		button.pressed.connect(on_press)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
