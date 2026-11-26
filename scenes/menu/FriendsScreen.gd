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
# 11-26 用户定：好友这一行的「加入」不能一按就进，要**那位好友同意**才进。
# 所以这颗键现在发的是「申请」：Main 把申请交给账号服务器转给好友，好友同意后
# Main 再走 _join_room_by_id（就是上面 join_room_requested 原来接的那条路）。
# on_failed：申请没发出去（好友刚下线、点太快…）时 Main 调它，把键恢复成能点。
signal join_request_requested(friend_code: String, friend_name: String, room_id: int, on_failed: Callable)
# 观战好友正在打的那一局（协议 44，2026-10-22）。走 Main 的观战流程，同「加入」一样先回主菜单。
signal spectate_room_requested(room_id: int)
# 私聊。带好友码 —— Main 用它开 ChatScreen 并定位到这个人。
signal chat_requested(friend_code: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")
# 新按钮一律实例化组件，不写 Button.new()：V3 P1-08 的棘轮盯着本文件的自绘按钮数，只能降。
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
# 11.11 换成羊皮纸风（ui/theme/ParchmentKit.gd），背景暂用主菜单森林图。
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const UiJuice := preload("res://ui/theme/UiJuice.gd")
# 羊皮纸上的状态色：比深色界面那套更深，才压得住浅底
const ONLINE_COLOR := Color("2f7d45")
const OFFLINE_COLOR := Color("8c7a66")
const NOTICE_BAD := Color("a3271a")
const NOTICE_OK := Color("7a5210")
const DEFAULT_FRAME_TEX := preload("res://assets/ui/shop/headframes/frame_default.png")

# 面板开着时的刷新间隔。**不是心跳** —— 这是读，心跳是写。
const REFRESH_SEC := 5.0
# 在线状态推送的事件名。必须和 backend/app/presence.py 的 PRESENCE_EVENT 一致。
const PRESENCE_PUSH := "presence"
# 加入申请的回复推送（backend/app/routes/join_requests.py）。
const JOIN_REPLY_PUSH := "room_join_reply"
# 申请发出去后键锁多久。比服务器的 30 秒多 2 秒：让服务器那边先过期，免得这边刚解锁、
# 玩家再点一次，上一张其实还没作废。
const JOIN_ASK_MSEC := 32000
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
# 「⋯」菜单（删除好友 / 拉黑）。与自定义房间的 AI 难度列表同一个组件。
const LobbyPopover := preload("res://ui/components/LobbyPopover.gd")
const MORE_MENU_MODAL_ID := "friends_more_menu"
# 参考像素（本页没有整体缩放，k 恒为 1）。行里的按钮是 48 高、19 号字，菜单项要明显更大、更容易点中。
const MORE_MENU_W := 200.0
const MORE_MENU_ITEM_H := 64.0
const MORE_MENU_FONT := 22
# 菜单开着时，选中那张好友卡片四周留亮的余量（其余整屏压暗，见 _spotlight_rect）。
const SPOTLIGHT_PAD := 6.0

enum Tab { FRIENDS, REQUESTS, ADD }

var _tab: int = Tab.FRIENDS
var _busy := false
var _friends: Array = []
var _incoming: Array = []
var _outgoing: Array = []
var _blocks: Array = []
var _recent: Array = []
var _notice := ""
var _notice_bad := false

var _list_box: VBoxContainer
# 包着 _list_box 的滚动框。暗幕的洞要裁到它的可见区域里（见 _spotlight_rect）。
var _list_scroll: Control
# 「⋯」菜单开着时到点的重建先记下来，关菜单时补一次（见 _render 开头）。
var _render_deferred := false
var _notice_label: Label
var _tab_buttons: Dictionary = {}
var _code_input: LineEdit
var _refresh_timer: Timer
# 好友码 -> 这张加入申请到什么时候（Time.get_ticks_msec）为止算「等对方回复中」。
# 列表 5 秒重建一次，所以状态记在这里而不是记在按钮上。
var _join_asked: Dictionary = {}
# 切页签 / 首次拉到数据时让卡片依次弹入；5 秒一次的后台刷新不弹（会一直闪）。
var _animate_rows := true


func _ready() -> void:
	theme = Kit.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	ChatService.unread_changed.connect(_on_chat_unread_changed)
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_SEC
	_refresh_timer.timeout.connect(func() -> void: await _reload(false))
	add_child(_refresh_timer)
	_refresh_timer.start()
	# 好友上线 / 换房间的推送（backend/app/presence.py）。上面那个定时器仍然留着 ——
	# 推送只覆盖上线，**下线没有事件可挂**（见 PartyLobby.FRIENDS_REFRESH_SEC 的说明）。
	if not RealtimeService.message_received.is_connected(_on_presence_push):
		RealtimeService.message_received.connect(_on_presence_push)
	# 「⋯」菜单关掉时补刷列表；窗口尺寸一变就收起菜单（暗幕的洞对不上了）。
	if not ModalStack.modal_closed.is_connected(_on_modal_closed):
		ModalStack.modal_closed.connect(_on_modal_closed)
	if not get_viewport().size_changed.is_connected(_on_viewport_resized):
		get_viewport().size_changed.connect(_on_viewport_resized)
	await _reload(true)


# 推送只当**失效信号**用，不拿 payload 里的字段打补丁：这个界面一次拉四份
# （好友 / 申请 / 黑名单 / 最近一起玩过），只给其中一行打补丁就会和另外三份
# 不同步。并发由 _reload 自己的 _busy 挡。
func _on_presence_push(payload: Dictionary) -> void:
	var kind := str(payload.get("t", ""))
	if kind == JOIN_REPLY_PUSH:
		# 好友回了（同意 / 拒绝）：这一行的键恢复。同意的话 Main 会带玩家进房，这个界面随后就没了。
		_join_asked.erase(str(payload.get("from_code", "")))
		_render()
		return
	if kind == PRESENCE_PUSH:
		await _reload(false)


# 这位好友的加入申请是不是还在等回复。纯静态（入参即全部依赖）⇒ 门禁可以直接喂数据。
static func join_request_waiting(asked: Dictionary, code: String, now_msec: int) -> bool:
	return asked.has(code) and now_msec < int(asked[code])


func _ask_to_join(code: String, friend_name: String, room_id: int) -> void:
	if join_request_waiting(_join_asked, code, Time.get_ticks_msec()):
		return
	_join_asked[code] = Time.get_ticks_msec() + JOIN_ASK_MSEC
	_render()
	join_request_requested.emit(code, friend_name, room_id, func() -> void:
		_join_asked.erase(code)
		if is_inside_tree():
			_render())


func _exit_tree() -> void:
	# 关掉就停。留着的话玩家在战斗里还在替一个已经不存在的界面拉好友列表。
	if _refresh_timer != null:
		_refresh_timer.stop()
	# RealtimeService 是 autoload，活得比这个界面久 —— 连接必须显式断开。
	if RealtimeService.message_received.is_connected(_on_presence_push):
		RealtimeService.message_received.disconnect(_on_presence_push)
	# ChatService 是 autoload，活得比这个界面久 —— 连接必须显式断开。
	if ChatService.unread_changed.is_connected(_on_chat_unread_changed):
		ChatService.unread_changed.disconnect(_on_chat_unread_changed)
	# ModalStack 是 autoload、视口也活得比这个界面久 —— 同样显式断开。
	if ModalStack.modal_closed.is_connected(_on_modal_closed):
		ModalStack.modal_closed.disconnect(_on_modal_closed)
	var viewport := get_viewport()
	if viewport != null and viewport.size_changed.is_connected(_on_viewport_resized):
		viewport.size_changed.disconnect(_on_viewport_resized)


# 私聊红点跟着 ChatService 走（状态只有一份）。私聊按钮只在「好友」页签上。
func _on_chat_unread_changed(_any_unread: bool) -> void:
	if _tab == Tab.FRIENDS:
		_render()


# --- 骨架 ---------------------------------------------------------------------


func _build() -> void:
	Kit.backdrop(self, "friends_camp")

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)
	# 灵动岛 / 圆角那几条让出来；背景（bg、dim）照样铺满（ui/services/SafeArea.gd）。
	SafeArea.track(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 18)
	margin.add_child(root)

	var header := _header()
	root.add_child(header)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 24)
	root.add_child(body)
	var rail := _tabs()
	body.add_child(rail)
	var content_panel := PanelContainer.new()
	content_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_panel.add_theme_stylebox_override("panel", Kit.box("panel"))
	body.add_child(content_panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	content_panel.add_child(content)

	_notice_label = Label.new()
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice_label.visible = false
	content.add_child(_notice_label)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_list_scroll = scroll

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_list_box)

	UiJuice.pop_in([header, rail, content_panel], 0.0, 0.07, 0.9)


func _header() -> Control:
	# 右上角刷新：图标键（原来是一颗写着「刷新」的深色按钮）
	var refresh := Kit.image_button("icon_refresh", func() -> void: await _reload(true), 56.0)
	refresh.name = "Refresh"
	refresh.accessibility_name = _text("刷新", "Refresh")
	return Kit.header(_text("好友", "Friends"), func() -> void: back_requested.emit(), refresh)


func _tabs() -> Control:
	var rail := VBoxContainer.new()
	rail.custom_minimum_size.x = 196
	rail.add_theme_constant_override("separation", 14)
	for spec in [
		[Tab.FRIENDS, _text("好友", "Friends")],
		[Tab.REQUESTS, _text("请求", "Requests")],
		[Tab.ADD, _text("添加", "Add")],
	]:
		var tab_id: int = spec[0]
		var button := ACTION_BUTTON.instantiate() as Button
		button.text = str(spec[1])
		Kit.style_tab(button, 62.0, 22)
		button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(func() -> void: _switch_tab(tab_id))
		_tab_buttons[tab_id] = button
		rail.add_child(button)
	return rail


func _switch_tab(tab_id: int) -> void:
	_tab = tab_id
	_animate_rows = true
	if _tab == Tab.REQUESTS:
		AccountManager.mark_friend_requests_seen(_incoming)
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
	var recent_result: Dictionary = await AccountManager.fetch_recent_players()
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
		if _tab == Tab.REQUESTS:
			AccountManager.mark_friend_requests_seen(_incoming)
	elif failed.is_empty():
		failed = str(requests_result.get("error", ""))
	if int(blocks_result.get("code", 0)) / 100 == 2:
		_blocks = (blocks_result.get("body", {}) as Dictionary).get("blocks", [])
	elif failed.is_empty():
		failed = str(blocks_result.get("error", ""))
	if int(recent_result.get("code", 0)) / 100 == 2:
		_recent = (recent_result.get("body", {}) as Dictionary).get("players", [])
	elif failed.is_empty():
		failed = str(recent_result.get("error", ""))

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
			"font_color", NOTICE_BAD if bad else NOTICE_OK)


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
		var outcome := str((result.get("body", {}) as Dictionary).get("result", ""))
		_set_notice(_text("已成为好友", "You are now friends") if outcome == "accepted" else ok_message, false)
		await _reload(true)
	else:
		_set_notice(str(result.get("error", _text("操作失败", "Action failed"))), true)
		_render()


# --- 渲染 ---------------------------------------------------------------------


func _render() -> void:
	if _list_box == null:
		return
	# ★ 10.08 反馈第 7 条：手机在「添加」页呼出键盘、正往好友码输入框里打字时，
	#   每 5 秒一次的后台刷新会把整个列表 queue_free 重建 —— 连同 _code_input
	#   一起销毁，LineEdit 一没，软键盘立刻自动收起（看起来就是「打一半键盘没了」）。
	#   正在编辑就**跳过这次重建**：这一次刷新只是「顺带更新」，少刷一次没有副作用，
	#   等玩家打完字、焦点离开，下一个 5 秒周期自然会重建。
	if _is_editing_code():
		return
	# ★ 11-26：「⋯」菜单开着时不重建。菜单开着时整屏压暗、只留选中那一行亮着，而洞是按
	#   打开那一刻的位置挖的；好友按「在线在前」排序，这时有人上线、列表一重排，亮着的就成了
	#   别人那一行 —— 正好和「看清是对谁操作、防误删」相反。定时刷新、上线推送、加入回复、
	#   私聊红点都从这里过，所以只拦这一处；关菜单时 _on_modal_closed 补一次。
	if ModalStack.has(MORE_MENU_MODAL_ID):
		_render_deferred = true
		return
	for child in _list_box.get_children():
		child.queue_free()
	for tab_id in _tab_buttons:
		var tab_button := _tab_buttons[tab_id] as Button
		tab_button.set_pressed_no_signal(tab_id == _tab)
	var request_tab: Button = _tab_buttons.get(Tab.REQUESTS)
	if request_tab != null:
		var badge := request_tab.get_node_or_null("RequestBadge") as Label
		if badge == null:
			badge = Label.new()
			badge.name = "RequestBadge"
			badge.text = "!"
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
			badge.add_theme_font_size_override("font_size", 24)
			request_tab.add_child(badge)
			badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
			badge.position.x -= 40
		badge.visible = AccountManager.has_unread_friend_requests(_incoming)
	_set_notice(_notice, _notice_bad)

	match _tab:
		Tab.FRIENDS:
			_render_friends()
		Tab.REQUESTS:
			_render_requests()
		_:
			_render_add()
	if _animate_rows:
		_animate_rows = false
		UiJuice.pop_in(_list_box.get_children(), 0.05, 0.04, 0.94)


func _render_friends() -> void:
	var online_count := 0
	for entry in _friends:
		if typeof(entry) == TYPE_DICTIONARY and bool((entry as Dictionary).get("online", false)):
			online_count += 1
	_list_box.add_child(_section(_text("好友 %d · 在线 %d" % [_friends.size(), online_count],
		"%d friends · %d online" % [_friends.size(), online_count])))
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
		_list_box.add_child(_wrap_card(_friend_row(entry as Dictionary)))


func _friend_row(entry: Dictionary) -> Control:
	var code := str(entry.get("friend_code", ""))
	var row := _card()
	row.add_child(_avatar_stage(entry, code))

	var name_label := Label.new()
	# 昵称永远带好友码 —— 唯一实现在 AccountManager.display_name()。
	name_label.text = AccountManager.display_name(str(entry.get("player_name", "")), code)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", 20)
	row.add_child(name_label)

	var online := bool(entry.get("online", false))
	name_label.add_theme_color_override("font_color", Kit.INK if online else OFFLINE_COLOR)
	var status := Label.new()
	status.text = _text("● 在线", "● Online") if online else _text("○ 离线", "○ Offline")
	status.custom_minimum_size.x = 112
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status.add_theme_color_override(
		"font_color", ONLINE_COLOR if online else OFFLINE_COLOR)
	row.add_child(status)

	var room_value: Variant = entry.get("room_id")
	var room_id := int(room_value) if room_value != null else 0
	# 好友正在对局里（in_match 已由账号服务器按对方的房间可见性过滤过）：「加入」必然被拒
	#（room_started），换成「观战」。还在房间大厅里的照旧给「加入」。
	if room_id > 0 and bool(entry.get("in_match", false)):
		var watch := ACTION_BUTTON.instantiate() as Button
		watch.name = "spectate"
		watch.text = _text("观战", "Watch")
		watch.custom_minimum_size = Vector2(92, Tokens.TOUCH_MIN)
		_style_primary_button(watch)
		watch.pressed.connect(func() -> void: spectate_room_requested.emit(room_id))
		row.add_child(watch)
	elif room_id > 0:
		var join := ACTION_BUTTON.instantiate() as Button
		join.name = "join"
		# 11-26：点「加入」= 向这位好友发申请，他同意了才进（见 join_request_requested）。
		# 申请发出去之后这颗键写「已申请」并点不动，直到对方回复或 30 秒过去。
		var waiting := join_request_waiting(_join_asked, code, Time.get_ticks_msec())
		join.text = _text("已申请", "Asked") if waiting else _text("加入", "Join")
		join.disabled = waiting
		join.custom_minimum_size = Vector2(92, Tokens.TOUCH_MIN)
		_style_primary_button(join)
		join.pressed.connect(_ask_to_join.bind(code, str(entry.get("player_name", "")), room_id))
		row.add_child(join)

	# 私聊。实例化组件而不是 Button.new()（见 ACTION_BUTTON 的注释）。
	var chat := ACTION_BUTTON.instantiate() as Button
	chat.text = _text("私聊", "Chat")
	chat.custom_minimum_size = Vector2(94, Tokens.TOUCH_MIN)
	chat.size_flags_horizontal = Control.SIZE_FILL
	_style_quiet_button(chat)
	chat.pressed.connect(func() -> void: chat_requested.emit(code))
	if ChatService.has_unread(code):
		_attach_unread_dot(chat)
	row.add_child(chat)

	var more := ACTION_BUTTON.instantiate() as Button
	more.text = "⋯"
	more.accessibility_name = _text("更多操作", "More actions")
	more.custom_minimum_size = Vector2(56, Tokens.TOUCH_MIN)
	_style_quiet_button(more)
	row.add_child(more)
	more.pressed.connect(_open_more_menu.bind(more, entry))
	return row


# 11-26 用户反馈：原来的 PopupMenu 是引擎默认样式（没套羊皮纸主题），两项字小、行矮，
# 手机上很难点准。改用 LobbyPopover.open_choice_list：羊皮纸底板、每项 64 高（> TOUCH_MIN），
# 走 ModalStack —— 点外面 / 按返回键就收起，页面切走时按 owner 自动收掉。
# 挂在页面（self）上而不是这颗键上：列表每 5 秒重建一次，挂在键上会被刷新连带关掉。
# 同日第二条：菜单开着时除了选中那一行，其余整屏压暗（spotlight），玩家看得清是对谁操作。
func _open_more_menu(anchor: Button, entry: Dictionary) -> void:
	if not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return
	var rect := anchor.get_global_rect()
	# 键在屏幕下半截就往上展开，免得被屏幕底边夹回来、盖住这颗键。
	var open_up := rect.get_center().y > get_viewport_rect().size.y * 0.5
	var items: Array = [
		{"text": _text("删除好友", "Remove friend"), "value": "remove"},
		{"text": _text("拉黑", "Block"), "value": "block"},
	]
	LobbyPopover.open_choice_list(self, MORE_MENU_MODAL_ID, rect, 1.0, items,
		_on_more_menu_pick.bind(entry), open_up, MORE_MENU_W, MORE_MENU_FONT, MORE_MENU_ITEM_H,
		_spotlight_rect(anchor))


# 暗幕要留亮的那一块：「⋯」所在的整张好友卡片（_wrap_card 的羊皮纸条，四角叶子都在框内），
# 四周多留 SPOTLIGHT_PAD，再裁到列表滚动框的可见区域里 —— 滚到一半的卡片，
# 露在列表框外面的那截照样压暗。找不到卡片时只留这颗键亮着（不该发生，兜底）。
func _spotlight_rect(anchor: Control) -> Rect2:
	var card: Control = anchor
	var node := anchor.get_parent()
	while node != null and node != _list_box:
		if node is PanelContainer:
			card = node as Control
			break
		node = node.get_parent()
	var hole := card.get_global_rect().grow(SPOTLIGHT_PAD)
	if _list_scroll != null and is_instance_valid(_list_scroll):
		hole = hole.intersection(_list_scroll.get_global_rect().grow(SPOTLIGHT_PAD))
	return hole


func _on_modal_closed(id: String, _reason: String) -> void:
	if id != MORE_MENU_MODAL_ID or not _render_deferred:
		return
	_render_deferred = false
	if is_inside_tree():
		_render()


# 改窗口大小（Windows）/ 转屏：暗幕的洞是按打开那一刻的位置挖的，尺寸一变就对不上，直接收起菜单。
func _on_viewport_resized() -> void:
	if ModalStack.has(MORE_MENU_MODAL_ID):
		ModalStack.pop(MORE_MENU_MODAL_ID)


# LobbyPopover 先关菜单再调这里；两条都还要再过一道确认框（_confirm_remove / _confirm_block）。
func _on_more_menu_pick(action: Variant, entry: Dictionary) -> void:
	if str(action) == "remove":
		_confirm_remove(entry)
	elif str(action) == "block":
		_confirm_block(entry)


func _avatar_stage(entry: Dictionary, code: String) -> Control:
	var stage := Control.new()
	stage.custom_minimum_size = Vector2(82, 82)
	var avatar := TextureRect.new()
	Catalog.set_avatar_texture(avatar, Catalog.texture_for(str(entry.get("avatar", "")), true))
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(avatar)
	avatar.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	avatar.position = Vector2(14, 14)
	avatar.size = Vector2(54, 54)
	var frame_value := str(entry.get("avatar_frame", ""))
	var frame_id := Catalog.id_from_value(frame_value)
	if frame_id.is_empty():
		frame_value = Catalog.default_frame()
		frame_id = Catalog.id_from_value(frame_value)
	var frame_texture: Texture2D = DEFAULT_FRAME_TEX if frame_id == "frame_default" else Catalog.frame_texture_for(frame_value, false)
	if frame_texture != null:
		var frame := TextureRect.new()
		Catalog.set_frame_texture(frame, frame_texture)
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.size = Catalog.frame_drawn_size(frame_id, 49.0)
		frame.position = Catalog.frame_box_origin(frame_id, 49.0, Vector2(41, 41))
		stage.add_child(frame)
	var hit := ACTION_BUTTON.instantiate() as Button
	hit.text = ""
	hit.accessibility_name = _text("查看资料", "View profile")
	hit.custom_minimum_size = Vector2.ZERO
	hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var clear := Tokens.flat_box(Color.TRANSPARENT, Color.TRANSPARENT, 0)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		hit.add_theme_stylebox_override(state, clear)
	hit.pressed.connect(func() -> void: profile_requested.emit(code))
	stage.add_child(hit)
	return stage


func _render_requests() -> void:
	if _incoming.is_empty() and _outgoing.is_empty():
		_list_box.add_child(_hint(_text("没有待处理的请求。", "No pending requests.")))
		return
	if not _incoming.is_empty():
		_list_box.add_child(_section(_text("收到的", "Received")))
		for entry in _incoming:
			_list_box.add_child(_wrap_card(_request_row(entry as Dictionary, true)))
	if not _outgoing.is_empty():
		_list_box.add_child(_section(_text("发出的", "Sent")))
		for entry in _outgoing:
			_list_box.add_child(_wrap_card(_request_row(entry as Dictionary, false)))


func _request_row(entry: Dictionary, incoming: bool) -> Control:
	var code := str(entry.get("friend_code", ""))
	var row := _card()
	row.add_child(_avatar_stage(entry, code))

	var name_label := Label.new()
	name_label.text = AccountManager.display_name(str(entry.get("player_name", "")), code)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Kit.INK)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
	row.add_child(name_label)

	var view := _make_button()
	view.text = _text("看资料", "Profile")
	view.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
	view.pressed.connect(func() -> void: profile_requested.emit(code))
	row.add_child(view)

	if incoming:
		var accept := _make_button(true)
		accept.text = _text("通过", "Accept")
		accept.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
		accept.pressed.connect(func() -> void:
			await _run(func(): return await AccountManager.accept_friend_request(code),
				_text("已成为好友", "You are now friends")))
		row.add_child(accept)

	var drop := _make_button()
	# 拒绝和取消是同一个接口（都是删掉那一行），文案分开只是为了讲人话。
	drop.text = _text("拒绝", "Decline") if incoming else _text("取消", "Cancel")
	drop.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
	drop.pressed.connect(func() -> void:
		await _run(func(): return await AccountManager.drop_friend_request(code),
			_text("已处理", "Done")))
	row.add_child(drop)
	return row


# 玩家此刻是不是正在好友码输入框里打字？
#
# 「添加」页的输入框是每次重建列表时**新建**的（_render_add），所以判据不能只看
# 对象还在不在，要看**焦点在不在它身上**：有焦点 = 键盘已经弹出来、玩家正在输入，
# 这时候任何重建都会把键盘连带收走（10.08 反馈第 7 条）。
# 顺带把「页签还是不是添加页」一起判了 —— 切到别的页签本来就该重建。
func _is_editing_code() -> bool:
	if _tab != Tab.ADD:
		return false
	if _code_input == null or not is_instance_valid(_code_input):
		return false
	return _code_input.has_focus()


func _render_add() -> void:
	_list_box.add_child(_section(_text("用好友码添加", "Add by friend code")))
	var add_row := _card()
	_code_input = LineEdit.new()
	_code_input.placeholder_text = _text("输入 8 位好友码", "Enter 8-character code")
	_code_input.max_length = 8
	_code_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_input.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	add_row.add_child(_code_input)

	var submit := _make_button(true)
	submit.text = _text("发送请求", "Send request")
	submit.custom_minimum_size = Vector2(136, Tokens.TOUCH_MIN)
	submit.pressed.connect(_on_add_pressed)
	add_row.add_child(submit)
	_list_box.add_child(_wrap_card(add_row))

	# 自己的好友码：加人这件事最真实的路径是把码发给朋友，不是在游戏里找人。
	var mine := str(AccountManager.profile.get("friend_code", ""))
	if not mine.is_empty():
		var my_row := _card()
		var label := Label.new()
		label.text = _text("我的好友码：", "My code: ") + mine
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		my_row.add_child(label)
		var copy := _make_button()
		copy.text = _text("复制", "Copy")
		copy.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
		copy.pressed.connect(func() -> void:
			DisplayServer.clipboard_set(mine)
			_set_notice(_text("已复制好友码", "Code copied"), false))
		my_row.add_child(copy)
		_list_box.add_child(_wrap_card(my_row))

	# 最近一起玩过 —— 加人最真实的路径之一：刚打完一局配合不错，顺手加。
	# 列表里只有「还不是好友」的人（后端已经排掉好友/待处理/拉黑/隐身）。
	_list_box.add_child(_section(_text("最近一起玩过", "Recently played with")))
	if _recent.is_empty():
		_list_box.add_child(_hint(_text(
			"最近没有一起玩过的人。打几局 3v3 之后这里会有人。",
			"Nobody yet. Play a few 3v3 matches and they will show up here.")))
	else:
		for entry in _recent:
			var recent: Dictionary = entry
			var rcode := str(recent.get("friend_code", ""))
			var rrow := _card()
			var rname := Label.new()
			rname.text = AccountManager.display_name(str(recent.get("player_name", "")), rcode)
			rname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			rname.add_theme_color_override("font_color", OFFLINE_COLOR)
			rrow.add_child(rname)
			var rview := _make_button()
			rview.text = _text("看资料", "Profile")
			rview.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
			rview.pressed.connect(func() -> void: profile_requested.emit(rcode))
			rrow.add_child(rview)
			var radd := _make_button(true)
			radd.text = _text("加好友", "Add")
			radd.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
			radd.pressed.connect(func() -> void:
				await _run(func(): return await AccountManager.send_friend_request(rcode),
					_text("已发送好友请求", "Friend request sent")))
			rrow.add_child(radd)
			_list_box.add_child(_wrap_card(rrow))

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
		name_label.add_theme_color_override("font_color", OFFLINE_COLOR)
		row.add_child(name_label)
		var unblock := _make_button()
		unblock.text = _text("解除", "Unblock")
		unblock.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
		unblock.pressed.connect(func() -> void:
			await _run(func(): return await AccountManager.unblock_player(code),
				_text("已解除拉黑。要重新加好友需要再发一次请求。",
					"Unblocked. You will need to send a new friend request.")))
		row.add_child(unblock)
		_list_box.add_child(_wrap_card(row))


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
		"on_result": func(result: String, _request_id: String) -> void:
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
		"on_result": func(result: String, _request_id: String) -> void:
			if result == ConfirmDialog.RESULT_CONFIRMED:
				await _run(func(): return await AccountManager.block_player(code),
					_text("已拉黑", "Blocked")),
	})


# --- 小工具 -------------------------------------------------------------------


# 按钮右上角的未读红点。与「请求」页签上那个「!」同色（Tokens.UNREAD_DOT）。
func _attach_unread_dot(button: Control) -> void:
	var dot := Label.new()
	dot.text = "●"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
	button.add_child(dot)
	dot.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	dot.position.x -= 18


func _card() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.custom_minimum_size.y = 84
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row


func _wrap_card(content: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Kit.row_box())
	panel.add_child(content)
	return panel


func _make_button(primary: bool = false) -> Button:
	var button := ACTION_BUTTON.instantiate() as Button
	button.custom_minimum_size = Vector2(110, Tokens.TOUCH_MIN)
	if primary:
		_style_primary_button(button)
	else:
		_style_quiet_button(button)
	return button


func _style_quiet_button(button: Button) -> void:
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	Kit.style_plate(button, false)


func _style_primary_button(button: Button) -> void:
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	Kit.style_plate(button, true)


func _section(title: String) -> Control:
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.y = 36
	label.add_theme_font_size_override("font_size", 21)
	label.add_theme_color_override("font_color", Color("8a4b12"))
	return label


func _hint(message: String) -> Control:
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.y = 88
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Kit.INK_SOFT)
	return label


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
