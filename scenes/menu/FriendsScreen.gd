extends Control

# 好友界面。入口是主菜单左侧的「朋友」按钮（此前是「敬请期待」）。
#
# 设计文档：docs/交友系统设计.md。三个页签：
#
#   好友    列表 + 在线状态 + 「加入」（对方在房间时）
#   请求    收到的（通过 / 拒绝）+ 发出的（取消）
#   添加    输入好友码加人、复制自己的码、拉黑列表
#
# ## 三条纪律
#
# 1. **昵称永远和好友码一起显示。** players.player_name 不唯一（database/001），
#    别人改名成同样的名字就能冒充。显示名只走 AccountManager.display_name()，
#    这里不许有第二个拼法。
#
# 2. **不许持续轮询。** 打开拉一次、开着时每 30 秒刷一次、关掉就停
#    （见 _exit_tree）。心跳那一半在 AccountManager，跟这里无关。
#
# 3. **删好友要说清楚双向消失。** 对方不会收到通知，但操作的人必须知道
#    「对方也会从他的列表里消失」—— 这是给点删除的人看的，不是通知被删的人。

signal back_requested
# 点头像看资料。带好友码 —— Main 用它开 ProfileScreen.configure_public()。
signal profile_requested(friend_code: String)
# 一键加入好友所在的房间。Main 会先回主菜单再走已有的加入流程（那里才有
# 「连接中」与失败提示），见 Main._join_room_by_id 的注释。
signal join_room_requested(room_id: int)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")

# 面板开着时的刷新间隔。**不是心跳** —— 这是读，心跳是写。
const REFRESH_SEC := 30.0

enum Tab { FRIENDS, REQUESTS, ADD }

var _tab: int = Tab.FRIENDS
var _busy := false
var _friends: Array = []
var _incoming: Array = []
var _outgoing: Array = []
var _blocks: Array = []
var _notice := ""
var _notice_bad := false

var _list_box: VBoxContainer
var _notice_label: Label
var _tab_buttons: Dictionary = {}
var _code_input: LineEdit
var _refresh_timer: Timer


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_SEC
	_refresh_timer.timeout.connect(func() -> void: await _reload(false))
	add_child(_refresh_timer)
	_refresh_timer.start()
	await _reload(true)


func _exit_tree() -> void:
	# 关掉就停。留着的话玩家在战斗里还在替一个已经不存在的界面拉好友列表。
	if _refresh_timer != null:
		_refresh_timer.stop()


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
	root.add_child(_tabs())

	_notice_label = Label.new()
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice_label.visible = false
	root.add_child(_notice_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", Tokens.GAP_S)
	scroll.add_child(_list_box)


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back := Button.new()
	back.text = _text("← 返回", "← Back")
	back.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)

	var title := Label.new()
	title.text = _text("朋友", "Friends")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(title)

	var refresh := Button.new()
	refresh.text = _text("刷新", "Refresh")
	refresh.custom_minimum_size = Vector2(96, Tokens.TOUCH_MIN)
	refresh.pressed.connect(func() -> void: await _reload(true))
	row.add_child(refresh)
	return row


func _tabs() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	for spec in [
		[Tab.FRIENDS, _text("好友", "Friends")],
		[Tab.REQUESTS, _text("请求", "Requests")],
		[Tab.ADD, _text("添加", "Add")],
	]:
		var tab_id: int = spec[0]
		var button := Button.new()
		button.text = str(spec[1])
		button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.pressed.connect(func() -> void: _switch_tab(tab_id))
		_tab_buttons[tab_id] = button
		row.add_child(button)
	return row


func _switch_tab(tab_id: int) -> void:
	_tab = tab_id
	_notice = ""
	_render()


# --- 数据 ---------------------------------------------------------------------


# show_errors=false 用于后台定时刷新：那时玩家可能正在打字或看别的东西，
# 弹一条「网络错误」只会打断他，而下一次刷新多半就好了。
func _reload(show_errors: bool) -> void:
	if _busy:
		return
	_busy = true
	var friends_result: Dictionary = await AccountManager.fetch_friends()
	var requests_result: Dictionary = await AccountManager.fetch_friend_requests()
	var blocks_result: Dictionary = await AccountManager.fetch_blocks()
	_busy = false
	if not is_inside_tree():
		return

	var failed := ""
	if int(friends_result.get("code", 0)) / 100 == 2:
		_friends = (friends_result.get("body", {}) as Dictionary).get("friends", [])
	else:
		failed = str(friends_result.get("error", ""))
	if int(requests_result.get("code", 0)) / 100 == 2:
		var body: Dictionary = requests_result.get("body", {})
		_incoming = body.get("incoming", [])
		_outgoing = body.get("outgoing", [])
	elif failed.is_empty():
		failed = str(requests_result.get("error", ""))
	if int(blocks_result.get("code", 0)) / 100 == 2:
		_blocks = (blocks_result.get("body", {}) as Dictionary).get("blocks", [])
	elif failed.is_empty():
		failed = str(blocks_result.get("error", ""))

	if show_errors and not failed.is_empty():
		_set_notice(failed, true)
	_render()


func _set_notice(message: String, bad: bool) -> void:
	_notice = message
	_notice_bad = bad
	if _notice_label != null:
		_notice_label.text = message
		_notice_label.visible = not message.is_empty()
		_notice_label.add_theme_color_override(
			"font_color", Tokens.DANGER if bad else Tokens.GOLD)


# 跑一个会改动数据的动作，成功就整体刷新。
# **所有写操作都从这里过** —— 否则很容易出现「改了但列表没刷新」。
func _run(action: Callable, ok_message: String) -> void:
	if _busy:
		return
	_busy = true
	var result: Dictionary = await action.call()
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 == 2:
		_set_notice(ok_message, false)
		await _reload(true)
	else:
		_set_notice(str(result.get("error", _text("操作失败", "Action failed"))), true)
		_render()


# --- 渲染 ---------------------------------------------------------------------


func _render() -> void:
	if _list_box == null:
		return
	for child in _list_box.get_children():
		child.queue_free()
	for tab_id in _tab_buttons:
		(_tab_buttons[tab_id] as Button).button_pressed = tab_id == _tab
	_set_notice(_notice, _notice_bad)

	match _tab:
		Tab.FRIENDS:
			_render_friends()
		Tab.REQUESTS:
			_render_requests()
		_:
			_render_add()


func _render_friends() -> void:
	if _friends.is_empty():
		_list_box.add_child(_hint(_text(
			"还没有好友。到「添加」页签用好友码加人。",
			"No friends yet. Use the Add tab to invite someone by code.")))
		return
	# 在线的排前面 —— 玩家来这个界面多半是为了找人一起玩。
	var sorted := _friends.duplicate()
	sorted.sort_custom(func(a, b) -> bool:
		var ao := bool((a as Dictionary).get("online", false))
		var bo := bool((b as Dictionary).get("online", false))
		if ao != bo:
			return ao
		return str((a as Dictionary).get("player_name", "")) \
			< str((b as Dictionary).get("player_name", "")))
	for entry in sorted:
		_list_box.add_child(_friend_row(entry as Dictionary))


func _friend_row(entry: Dictionary) -> Control:
	var code := str(entry.get("friend_code", ""))
	var row := _card()

	var avatar := TextureButton.new()
	avatar.texture_normal = Catalog.texture_for(str(entry.get("avatar", "")), true)
	avatar.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	avatar.ignore_texture_size = true
	avatar.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	avatar.pressed.connect(func() -> void: profile_requested.emit(code))
	row.add_child(avatar)

	var name_label := Label.new()
	# 昵称永远带好友码 —— 唯一实现在 AccountManager.display_name()。
	name_label.text = AccountManager.display_name(str(entry.get("player_name", "")), code)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var online := bool(entry.get("online", false))
	var status := Label.new()
	status.text = _text("在线", "Online") if online else _text("离线", "Offline")
	status.add_theme_color_override(
		"font_color", Tokens.CYAN if online else Tokens.TEXT_DISABLED)
	row.add_child(status)

	var room_id := int(entry.get("room_id", 0))
	if room_id > 0:
		var join := Button.new()
		join.text = _text("加入", "Join")
		join.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
		join.pressed.connect(func() -> void: join_room_requested.emit(room_id))
		row.add_child(join)

	var remove := Button.new()
	remove.text = _text("删除", "Remove")
	remove.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	remove.pressed.connect(func() -> void: _confirm_remove(entry))
	row.add_child(remove)

	var block := Button.new()
	block.text = _text("拉黑", "Block")
	block.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	block.pressed.connect(func() -> void: _confirm_block(entry))
	row.add_child(block)
	return row


func _render_requests() -> void:
	if _incoming.is_empty() and _outgoing.is_empty():
		_list_box.add_child(_hint(_text("没有待处理的请求。", "No pending requests.")))
		return
	if not _incoming.is_empty():
		_list_box.add_child(_section(_text("收到的", "Received")))
		for entry in _incoming:
			_list_box.add_child(_request_row(entry as Dictionary, true))
	if not _outgoing.is_empty():
		_list_box.add_child(_section(_text("发出的", "Sent")))
		for entry in _outgoing:
			_list_box.add_child(_request_row(entry as Dictionary, false))


func _request_row(entry: Dictionary, incoming: bool) -> Control:
	var code := str(entry.get("friend_code", ""))
	var row := _card()

	var name_label := Label.new()
	name_label.text = AccountManager.display_name(str(entry.get("player_name", "")), code)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var view := Button.new()
	view.text = _text("看资料", "Profile")
	view.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	view.pressed.connect(func() -> void: profile_requested.emit(code))
	row.add_child(view)

	if incoming:
		var accept := Button.new()
		accept.text = _text("通过", "Accept")
		accept.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
		accept.pressed.connect(func() -> void:
			await _run(func(): return await AccountManager.accept_friend_request(code),
				_text("已成为好友", "You are now friends")))
		row.add_child(accept)

	var drop := Button.new()
	# 拒绝和取消是同一个接口（都是删掉那一行），文案分开只是为了讲人话。
	drop.text = _text("拒绝", "Decline") if incoming else _text("取消", "Cancel")
	drop.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	drop.pressed.connect(func() -> void:
		await _run(func(): return await AccountManager.drop_friend_request(code),
			_text("已处理", "Done")))
	row.add_child(drop)
	return row


func _render_add() -> void:
	_list_box.add_child(_section(_text("用好友码添加", "Add by friend code")))

	var add_row := _card()
	_code_input = LineEdit.new()
	_code_input.placeholder_text = _text("输入 8 位好友码", "Enter 8-character code")
	_code_input.max_length = 8
	_code_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_input.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	add_row.add_child(_code_input)

	var submit := Button.new()
	submit.text = _text("发送请求", "Send request")
	submit.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	submit.pressed.connect(_on_add_pressed)
	add_row.add_child(submit)
	_list_box.add_child(add_row)

	# 自己的好友码：加人这件事最真实的路径是把码发给朋友，不是在游戏里找人。
	var mine := str(AccountManager.profile.get("friend_code", ""))
	if not mine.is_empty():
		var my_row := _card()
		var label := Label.new()
		label.text = _text("我的好友码：", "My code: ") + mine
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		my_row.add_child(label)
		var copy := Button.new()
		copy.text = _text("复制", "Copy")
		copy.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
		copy.pressed.connect(func() -> void:
			DisplayServer.clipboard_set(mine)
			_set_notice(_text("已复制好友码", "Code copied"), false))
		my_row.add_child(copy)
		_list_box.add_child(my_row)

	_list_box.add_child(_section(_text("已拉黑", "Blocked")))
	if _blocks.is_empty():
		_list_box.add_child(_hint(_text("没有拉黑任何人。", "You have not blocked anyone.")))
		return
	for entry in _blocks:
		var blocked: Dictionary = entry
		var code := str(blocked.get("friend_code", ""))
		var row := _card()
		var name_label := Label.new()
		name_label.text = AccountManager.display_name(str(blocked.get("player_name", "")), code)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var unblock := Button.new()
		unblock.text = _text("解除", "Unblock")
		unblock.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
		unblock.pressed.connect(func() -> void:
			await _run(func(): return await AccountManager.unblock_player(code),
				_text("已解除拉黑。要重新加好友需要再发一次请求。",
					"Unblocked. You will need to send a new friend request.")))
		row.add_child(unblock)
		_list_box.add_child(row)


# --- 动作 ---------------------------------------------------------------------


func _on_add_pressed() -> void:
	if _code_input == null:
		return
	var code := _code_input.text
	var problem := AccountManager.friend_code_problem(code)
	if not problem.is_empty():
		# 本地就能判掉的失败不必往返一次。
		_set_notice(problem, true)
		return
	await _run(func(): return await AccountManager.send_friend_request(code), "")
	# result 是 'pending' 还是 'accepted' 决定文案：后者是交叉请求
	# （对方已经先加过我），这一下直接成为好友，说「已发送」会让人困惑。
	if _notice.is_empty():
		_set_notice(_text("已发送好友请求", "Friend request sent"), false)
	if _code_input != null and is_instance_valid(_code_input):
		_code_input.text = ""


func _confirm_remove(entry: Dictionary) -> void:
	var code := str(entry.get("friend_code", ""))
	var who := AccountManager.display_name(str(entry.get("player_name", "")), code)
	DialogService.confirm({
		"title": _text("删除好友", "Remove friend"),
		# **必须说清楚双向消失。** 对方不会收到通知，但操作的人要知道自己在做什么。
		"body": _text(
			"删除 %s 之后，你也会从对方的好友列表里消失。对方不会收到通知。",
			"After removing %s, you will also disappear from their list. They are not notified."
		) % who,
		"intent": ConfirmDialog.Intent.DANGER,
		"confirm_text": _text("删除", "Remove"),
		"owner": self,
		"on_result": func(result: String) -> void:
			if result == ConfirmDialog.RESULT_CONFIRMED:
				await _run(func(): return await AccountManager.remove_friend(code),
					_text("已删除好友", "Friend removed")),
	})


func _confirm_block(entry: Dictionary) -> void:
	var code := str(entry.get("friend_code", ""))
	var who := AccountManager.display_name(str(entry.get("player_name", "")), code)
	DialogService.confirm({
		"title": _text("拉黑", "Block"),
		# 拉黑会连带删掉好友关系（服务端在同一事务里做），这点要说。
		# 与举报分开：举报是给我们看的、异步的，入口在资料页。
		"body": _text(
			"拉黑 %s 会同时解除好友关系，对方也无法再向你发送好友请求。",
			"Blocking %s also removes the friendship and stops them from sending requests."
		) % who,
		"intent": ConfirmDialog.Intent.DANGER,
		"confirm_text": _text("拉黑", "Block"),
		"owner": self,
		"on_result": func(result: String) -> void:
			if result == ConfirmDialog.RESULT_CONFIRMED:
				await _run(func(): return await AccountManager.block_player(code),
					_text("已拉黑", "Blocked")),
	})


# --- 小工具 -------------------------------------------------------------------


func _card() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row


func _section(title: String) -> Control:
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", Tokens.GOLD)
	return label


func _hint(message: String) -> Control:
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	return label


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
