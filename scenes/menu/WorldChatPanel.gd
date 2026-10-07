extends PanelContainer

# 世界频道页签（docs/聊天系统设计.md 批次 E，2026-09-27）。ChatScreen 里和私聊并列的第一个页签。
#
# 数据与订阅都在 ChatService，这里只画：
#   页签露出来 = ChatService.open_world()（订阅推送 + 拉最近 100 条）；
#   页签藏起来 / 离开聊天界面 = close_world()（退订，之后一个字节都不收）。
#
# 每条显示头像 + 昵称 + 好友码（昵称永远和好友码一起显示，同私聊界面第 1 条纪律）+ 时间。
# 点别人那条的名字 → 查看资料 / 举报这一条；自己的在右边。
# 往上翻：列表顶上一颗「加载更早的消息」。停在最底下时新消息跟着滚，往上翻着的时候不拽回去。
#
# 按钮一律实例化 GloryActionButton.tscn，不写 Button.new()（V3 P1-08 棘轮）。

signal profile_requested(friend_code: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const ReportDialog := preload("res://ui/components/ReportDialog.gd")

const AVATAR_SIZE := 40.0
# 离底部多近算「正看着最新消息」（同 ChatScreen）。
const STICK_TO_BOTTOM_PX := 64.0
# 气泡最宽占消息区的多少（比私聊宽：世界频道每条上面还有一行名字，左右对齐的对比没那么重要）。
const BUBBLE_MAX_RATIO := 0.72
const ACTIONS_MODAL_ID := "world_message_actions"
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")

var _scroll: ScrollContainer
var _list: VBoxContainer
var _status: Label
var _notice: Label
var _input: LineEdit
var _send_button: Button
var _sending := false


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER.darkened(0.42), Tokens.GAP_S))
	_build()
	ChatService.world_changed.connect(_on_world_changed)
	ChatService.world_message_added.connect(_on_world_message_added)
	ChatService.kicked_changed.connect(_on_kicked_changed)
	RealtimeService.connection_changed.connect(_on_connection_changed)
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _exit_tree() -> void:
	# ChatService / RealtimeService 是 autoload，活得比这个界面久：连接必须显式断开。
	# 离开聊天界面 = 不再看世界频道 = 退订（之后一个字节都不收）。
	ChatService.close_world()
	if ModalStack.has(ACTIONS_MODAL_ID):
		ModalStack.pop(ACTIONS_MODAL_ID)
	for pair in [[ChatService.world_changed, _on_world_changed],
			[ChatService.world_message_added, _on_world_message_added],
			[ChatService.kicked_changed, _on_kicked_changed],
			[RealtimeService.connection_changed, _on_connection_changed]]:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])


func _process(_delta: float) -> void:
	# 发出去之后按钮倒数（与服务器的 8 秒 CD 同步），免得点了才被回一句「发得太快了」。
	_refresh_send_button()


# --- 骨架 ---------------------------------------------------------------------


func _build() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	add_child(col)

	var head := HBoxContainer.new()
	head.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	head.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(head)

	var title := Label.new()
	title.text = _text("世界频道 · 所有玩家都看得到", "World · everyone can see this")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	title.add_theme_color_override("font_color", Tokens.GOLD)
	head.add_child(title)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	head.add_child(_status)

	_notice = Label.new()
	_notice.visible = false
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.add_theme_color_override("font_color", Tokens.DANGER_HOVER)
	col.add_child(_notice)

	var well := PanelContainer.new()
	well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	well.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.BG_DEEP, Tokens.BORDER.darkened(0.55), Tokens.GAP_S))
	col.add_child(well)

	_scroll = TouchScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	well.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", Tokens.GAP_S)
	_scroll.add_child(_list)

	var composer := PanelContainer.new()
	composer.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE_RAISED, Tokens.BORDER.darkened(0.25), Tokens.GAP_S))
	col.add_child(composer)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	composer.add_child(row)

	_input = LineEdit.new()
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	# 与服务端 text_guard.WORLD_MAX 同一个数（tools/chat_check.gd 钉着，不许写死）。
	_input.max_length = ChatService.WORLD_MAX_CHARS
	_input.placeholder_text = _text("说点什么…（所有玩家都看得到，最多 %d 字）" % ChatService.WORLD_MAX_CHARS,
		"Say something… (everyone sees it, max %d)" % ChatService.WORLD_MAX_CHARS)
	_input.text_submitted.connect(func(_submitted: String) -> void: _on_send_pressed())
	row.add_child(_input)

	_send_button = _button(_text("发送", "Send"), _on_send_pressed)
	_send_button.theme_type_variation = Theming.VARIATION_PRIMARY
	_send_button.custom_minimum_size = Vector2(104, Tokens.TOUCH_MIN)
	row.add_child(_send_button)

	# 玩家看得到的规矩：保留多久、不许留什么（设计文档第三节「玩家可见的承诺」同一个意思）。
	var rules := Label.new()
	rules.text = _text("ⓘ 保留 7 天 · 每 %d 秒一条 · 不要留联系方式或骂人，违规会被删除、禁言" % int(ChatService.WORLD_COOLDOWN_SEC),
		"ⓘ Kept 7 days · one message per %d s · no contact info or abuse" % int(ChatService.WORLD_COOLDOWN_SEC))
	rules.clip_text = true
	rules.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	rules.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
	col.add_child(rules)


# --- 页签开关 -----------------------------------------------------------------


func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_render(true)
		_refresh_status()
		await ChatService.open_world()
	else:
		ChatService.close_world()


# --- 数据来了 -----------------------------------------------------------------


func _on_world_changed() -> void:
	if is_visible_in_tree():
		_render(false)


func _on_world_message_added(message: Dictionary) -> void:
	if not is_visible_in_tree():
		return
	var stick := _near_bottom() or ChatService.is_mine(message)
	# 列表里只有「还没有人说话」那一行：整份重画（把它换掉）。
	if _list.get_child_count() == 1 and _list.get_child(0).has_meta("placeholder"):
		_render(true)
		return
	_list.add_child(_row(message, _bubble_max_width()))
	if stick:
		_scroll_to_bottom_later()


func _on_kicked_changed(_kicked: bool) -> void:
	_refresh_status()
	_refresh_send_button()


func _on_connection_changed(_state: int) -> void:
	_refresh_status()


# --- 发送 ---------------------------------------------------------------------


func _on_send_pressed() -> void:
	if _sending or ChatService.kicked:
		return
	var text := _input.text.strip_edges()
	if text.is_empty():
		return
	_sending = true
	_refresh_send_button()
	var problem: String = await ChatService.send_world(text)
	if not is_inside_tree():
		return
	_sending = false
	if problem.is_empty():
		_input.text = ""
		_set_notice("")
	else:
		# 字留在输入框里：改一改（例如去掉电话号码）还能再发。
		_set_notice(problem)
	_refresh_send_button()


func _refresh_send_button() -> void:
	if _send_button == null:
		return
	var left := ChatService.world_cooldown_left()
	var usable := not _sending and not ChatService.kicked and left <= 0.0
	_send_button.disabled = not usable
	_send_button.text = ("%ds" % ceili(left)) if left > 0.0 else _text("发送", "Send")
	_input.editable = not ChatService.kicked


func _refresh_status() -> void:
	if _status == null:
		return
	if ChatService.kicked:
		_status.text = _text("已在另一台设备登录", "Signed in elsewhere")
		_status.add_theme_color_override("font_color", Tokens.GOLD)
	elif RealtimeService.is_online():
		_status.text = _text("● 实时", "● Live")
		_status.add_theme_color_override("font_color", Tokens.CYAN)
	else:
		# 发送不受影响（走 HTTPS），受影响的只是「新消息实时出现」。
		_status.text = _text("连接中…", "Connecting…")
		_status.add_theme_color_override("font_color", Tokens.GOLD)


# --- 渲染 ---------------------------------------------------------------------


func _render(force_bottom: bool) -> void:
	var stick := force_bottom or _near_bottom()
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if ChatService.world_has_more:
		var older := _button(_text("加载更早的消息", "Load earlier messages"), _on_load_older)
		older.theme_type_variation = Theming.VARIATION_GHOST
		older.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_list.add_child(older)
	if ChatService.world_messages.is_empty():
		# 空白界面在玩家眼里就是坏了（设计文档第八节第 9 条）：说清楚是没人说话、不是没加载出来。
		var hint := _hint(_text("加载中…", "Loading…") if ChatService.world_loading
			else _text("世界频道还没有人说话，来说第一句吧。", "No one has said anything yet. Say hi!"))
		hint.set_meta("placeholder", true)
		_list.add_child(hint)
	else:
		var max_width := _bubble_max_width()
		for message in ChatService.world_messages:
			_list.add_child(_row(message, max_width))
	if stick:
		_scroll_to_bottom_later()


func _on_load_older() -> void:
	# 往上翻完之后停在原来那条的位置：记下现在离底部多远，排完版再按这个距离滚回去 ——
	# 否则上面多了 100 条，画面会跳到最顶上。
	var bar := _scroll.get_v_scroll_bar()
	var from_bottom := bar.max_value - _scroll.scroll_vertical
	var problem: String = await ChatService.load_older_world()
	if not is_inside_tree():
		return
	_set_notice(problem)
	await get_tree().process_frame
	await get_tree().process_frame
	if is_inside_tree():
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value - from_bottom)


func _row(message: Dictionary, max_width: float) -> Control:
	var mine := ChatService.is_mine(message)
	var code := str(message.get("from_code", ""))
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_END if mine else BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", Tokens.GAP_S)

	var avatar := TextureRect.new()
	avatar.texture = Catalog.texture_for(str(message.get("avatar", "")), true)
	avatar.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)

	var meta := HBoxContainer.new()
	meta.alignment = BoxContainer.ALIGNMENT_END if mine else BoxContainer.ALIGNMENT_BEGIN
	meta.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(meta)
	var who := AccountManager.display_name(str(message.get("name", "")), code)
	if mine:
		meta.add_child(_caption(_text("我", "Me"), Tokens.GOLD))
	else:
		# 点名字：查看资料 / 举报这一条。按钮做成「看着像名字」的样子（ghost），手机上仍有 48 高的判定区。
		var name_button := _button(who, _open_actions.bind(message))
		name_button.theme_type_variation = Theming.VARIATION_GHOST
		name_button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
		name_button.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
		meta.add_child(name_button)
	meta.add_child(_caption(ChatService.format_time(str(message.get("created_at", ""))), Tokens.TEXT_DISABLED))

	var bubble := PanelContainer.new()
	bubble.size_flags_horizontal = Control.SIZE_SHRINK_END if mine else Control.SIZE_SHRINK_BEGIN
	bubble.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.GOLD_PRESSED.darkened(0.64) if mine else Tokens.SURFACE_RAISED,
		Tokens.GOLD_PRESSED.darkened(0.18) if mine else Tokens.BORDER.darkened(0.28), 10))
	col.add_child(bubble)
	var body := Label.new()
	body.text = str(message.get("body", ""))
	body.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	# 同私聊：短消息按自然宽度，长消息在 max_width 处折行（自动折行的 Label 放在收缩容器里会
	# 退化成一个字一行，必须给它一个明确的宽度）。
	var natural := body.get_theme_font("font").get_string_size(
		body.text, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_BODY).x
	if natural > max_width:
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.custom_minimum_size = Vector2(max_width, 0)
	bubble.add_child(body)

	if mine:
		row.add_child(col)
		row.add_child(avatar)
	else:
		row.add_child(avatar)
		row.add_child(col)
	return row


# 点别人那条的名字：一块小面板，查看资料 / 举报这一条 / 取消。走 ModalStack（点外面就收起）。
func _open_actions(message: Dictionary) -> void:
	if ModalStack.has(ACTIONS_MODAL_ID):
		return
	var code := str(message.get("from_code", ""))
	var who := AccountManager.display_name(str(message.get("name", "")), code)
	var sheet := PanelContainer.new()
	sheet.theme = Theming.get_theme()
	sheet.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.PAD))
	var width := minf(460.0, get_viewport_rect().size.x - Tokens.PAD * 2.0)
	sheet.anchor_left = 0.5
	sheet.anchor_right = 0.5
	sheet.anchor_top = 0.5
	sheet.anchor_bottom = 0.5
	sheet.offset_left = -width * 0.5
	sheet.offset_right = width * 0.5
	sheet.grow_vertical = Control.GROW_DIRECTION_BOTH
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	sheet.add_child(col)
	var title := Label.new()
	title.text = who
	title.clip_text = true
	title.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	col.add_child(title)
	var quote := Label.new()
	quote.text = "「%s」" % str(message.get("body", ""))
	quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quote.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	quote.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	col.add_child(quote)
	var view := _button(_text("查看资料（加好友 / 屏蔽）", "View profile (add / block)"), func() -> void:
		ModalStack.pop(ACTIONS_MODAL_ID)
		profile_requested.emit(code))
	col.add_child(view)
	var report := _button(_text("举报这条消息", "Report this message"), func() -> void:
		ModalStack.pop(ACTIONS_MODAL_ID)
		ReportDialog.new().present(self, code, who, "world", int(message.get("message_id", 0))))
	report.theme_type_variation = Theming.VARIATION_DANGER
	col.add_child(report)
	var cancel := _button(_text("取消", "Cancel"), func() -> void: ModalStack.pop(ACTIONS_MODAL_ID))
	cancel.theme_type_variation = Theming.VARIATION_GHOST
	col.add_child(cancel)
	ModalStack.push(sheet, {"id": ACTIONS_MODAL_ID, "owner": self, "priority": 50, "dismiss_on_backdrop": true})


func _bubble_max_width() -> float:
	var avail := _scroll.size.x if _scroll != null else 0.0
	if avail <= 0.0:
		avail = get_viewport_rect().size.x - Tokens.PAD * 4
	return maxf(160.0, (avail - AVATAR_SIZE) * BUBBLE_MAX_RATIO)


func _near_bottom() -> bool:
	if _scroll == null:
		return true
	var bar := _scroll.get_v_scroll_bar()
	return bar.value >= bar.max_value - bar.page - STICK_TO_BOTTOM_PX


func _scroll_to_bottom_later() -> void:
	# 新节点要等排完版才知道高度（同 ChatScreen._scroll_to_bottom_later）。
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or _scroll == null:
		return
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


# --- 小工具 -------------------------------------------------------------------


func _set_notice(message: String) -> void:
	_notice.text = message
	_notice.visible = not message.is_empty()


func _caption(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	label.add_theme_color_override("font_color", color)
	return label


func _hint(message: String) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER.darkened(0.55), Tokens.GAP_M))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	panel.add_child(label)
	return panel


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
