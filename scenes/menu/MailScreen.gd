extends Control

# 邮件界面（docs/邮件系统设计.md）。入口：主菜单右上角「邮件」。
#
# 左边列表、右边详情（照 AnnouncementScreen 的样子）。点开一封就算读过（红点灭）。
# 数据只从 MailService 拿；打开时强制刷新一次，到了就重画。
#
# 顶上两个批量按钮：一键领取、删除已读（删除要确认）。
# 详情里：附件清单（钻石 / 金币 / 头像 / 头像框 / 宠物）+ 领取 / 删除。
#
# 没有「写信」：发邮件只在 Supabase 里（database/012_mail.sql）。

signal back_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
# 9.17 音效。preload 而不是全局类名，理由见 Main.gd 顶上那条注释。
const SfxService := preload("res://ui/services/SfxService.gd")
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")
# 新按钮一律实例化组件，不写 Button.new()：procedural_ui_ratchet 按文件只许降。
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")
const Currency := preload("res://scripts/account/Currency.gd")

const LIST_WIDTH := 460.0
const ROW_HEIGHT := 64.0
const HEADER_BUTTON_WIDTH := 180.0
const CHIP_ICON := Vector2(30, 30)
const DAY_SEC := 86400
const HOUR_SEC := 3600

var _selected_id := 0
var _busy := false
var _notice := ""
var _notice_bad := false

var _list_box: VBoxContainer
var _detail_box: VBoxContainer
var _empty_label: Label
var _notice_label: Label
var _title_label: Label
var _meta_label: Label
var _body_label: Label
var _attach_title: Label
var _attach_box: HFlowContainer
var _claim_button: Button
var _delete_button: Button
var _claim_all_button: Button
var _delete_read_button: Button


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	# deferred：mark_read 会发 changed，而它常常发生在列表按钮自己的 pressed 回调里 ——
	# 同步重画会在回调中途把那个按钮释放掉（同 AnnouncementScreen）。
	MailService.changed.connect(_render, CONNECT_DEFERRED)
	_render()
	MailService.refresh(true)


func _exit_tree() -> void:
	# MailService 是 autoload，活得比这个界面久 —— 连接必须显式断开。
	if MailService.changed.is_connected(_render):
		MailService.changed.disconnect(_render)


func selected_id() -> int:
	return _selected_id


# 点列表里的一封。
func select(id: int) -> void:
	_selected_id = id
	_render.call_deferred()


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
	_notice_label.name = "Notice"
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_notice_label.visible = false
	root.add_child(_notice_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", Tokens.GAP_M)
	root.add_child(body)

	var list_panel := PanelContainer.new()
	list_panel.custom_minimum_size = Vector2(LIST_WIDTH, 0)
	list_panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_S))
	body.add_child(list_panel)
	var list_scroll := ScrollContainer.new()
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_panel.add_child(list_scroll)
	_list_box = VBoxContainer.new()
	_list_box.name = "List"
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", Tokens.GAP_S)
	list_scroll.add_child(_list_box)

	var detail_panel := PanelContainer.new()
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_M))
	body.add_child(detail_panel)
	var detail_scroll := ScrollContainer.new()
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_panel.add_child(detail_scroll)
	_detail_box = VBoxContainer.new()
	_detail_box.name = "Detail"
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_box.add_theme_constant_override("separation", Tokens.GAP_M)
	detail_scroll.add_child(_detail_box)

	_empty_label = _label("Empty", Tokens.FONT_BODY, Tokens.TEXT_SECONDARY)
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label = _label("Title", Tokens.FONT_TITLE, Tokens.GOLD)
	_meta_label = _label("Meta", Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY)
	# 正文是纯文本（Label，不是 RichTextLabel）：写信的是管理员，但这里不需要任何格式，
	# 不开 BBCode 就不用操心谁往正文里塞了标签。
	_body_label = _label("Body", Tokens.FONT_BODY, Tokens.TEXT_PRIMARY)
	_attach_title = _label("AttachTitle", Tokens.FONT_BODY, Tokens.GOLD)

	_attach_box = HFlowContainer.new()
	_attach_box.name = "Attachments"
	_attach_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_attach_box.add_theme_constant_override("h_separation", Tokens.GAP_S)
	_attach_box.add_theme_constant_override("v_separation", Tokens.GAP_S)
	_detail_box.add_child(_attach_box)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", Tokens.GAP_M)
	_detail_box.add_child(actions)
	_claim_button = _button("Claim", _t("领取", "Claim"), Theming.VARIATION_PRIMARY)
	_claim_button.pressed.connect(func() -> void: _claim(_selected_id))
	actions.add_child(_claim_button)
	_delete_button = _button("Delete", _t("删除", "Delete"), Theming.VARIATION_GHOST)
	_delete_button.pressed.connect(func() -> void: _delete(_selected_id))
	actions.add_child(_delete_button)


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back: Button = ACTION_BUTTON.instantiate()
	back.name = "Back"
	back.text = _t("← 返回", "← Back")
	back.custom_minimum_size = Vector2(160, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)

	var title := Label.new()
	title.text = _t("邮件", "Mail")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(title)

	_claim_all_button = _button("ClaimAll", _t("一键领取", "Claim all"), Theming.VARIATION_PRIMARY)
	_claim_all_button.custom_minimum_size = Vector2(HEADER_BUTTON_WIDTH, Tokens.TOUCH_MIN)
	_claim_all_button.pressed.connect(_claim_all)
	row.add_child(_claim_all_button)

	_delete_read_button = _button("DeleteRead", _t("删除已读", "Delete read"), Theming.VARIATION_GHOST)
	_delete_read_button.custom_minimum_size = Vector2(HEADER_BUTTON_WIDTH, Tokens.TOUCH_MIN)
	_delete_read_button.pressed.connect(_confirm_delete_read)
	row.add_child(_delete_read_button)
	return row


func _button(node_name: String, text: String, variation: String) -> Button:
	var button: Button = ACTION_BUTTON.instantiate()
	button.name = node_name
	button.text = text
	button.theme_type_variation = variation
	button.custom_minimum_size = Vector2(Tokens.BUTTON_MIN_WIDTH, Tokens.TOUCH_MIN)
	return button


func _label(node_name: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	_detail_box.add_child(label)
	return label


# --- 渲染 ---------------------------------------------------------------------

func _render() -> void:
	if _list_box == null or not is_inside_tree():
		return
	var list := MailService.mails()
	if list.is_empty():
		_selected_id = 0
	elif MailService.find(_selected_id).is_empty():
		_selected_id = int((list[0] as Dictionary).get("id", 0))
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	for entry in list:
		_list_box.add_child(_list_row(entry as Dictionary))
	_notice_label.visible = not _notice.is_empty()
	_notice_label.text = _notice
	_notice_label.add_theme_color_override("font_color", Tokens.DANGER if _notice_bad else Tokens.GOLD)
	_claim_all_button.disabled = _busy or MailService.claimable_count() == 0
	_delete_read_button.disabled = _busy or MailService.deletable_count() == 0
	_render_detail()


func _list_row(entry: Dictionary) -> Control:
	var id := int(entry.get("id", 0))
	var button: Button = ACTION_BUTTON.instantiate()
	button.name = "Mail_%d" % id
	button.toggle_mode = true
	button.button_pressed = id == _selected_id
	button.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# PASS：手指按在按钮上拖也能滚动列表。
	button.mouse_filter = Control.MOUSE_FILTER_PASS
	button.text = row_text(entry)
	button.pressed.connect(func() -> void: select(id))

	# 红点：没读，或者附件没领。
	var dot := Label.new()
	dot.name = "Dot"
	dot.text = "●"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
	dot.add_theme_font_size_override("font_size", 20)
	dot.visible = not bool(entry.get("read", false)) or MailService.is_claimable(entry)
	button.add_child(dot)
	dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	dot.position.x -= Tokens.GAP_S
	return button


# 列表一行：标题，有没领的附件时后面标出来。
func row_text(entry: Dictionary) -> String:
	var text := _pick(entry, "title")
	if MailService.is_claimable(entry):
		text += _t("  · 附件", "  · Gift")
	return text


func _render_detail() -> void:
	var entry := MailService.find(_selected_id)
	var has_mail := not entry.is_empty()
	_empty_label.visible = not has_mail
	if not has_mail:
		_empty_label.text = _t("正在载入…", "Loading…") if not MailService.is_loaded() \
			else _t("邮箱是空的", "Your mailbox is empty")
	for node in [_title_label, _meta_label, _body_label]:
		(node as Control).visible = has_mail
	_claim_button.visible = has_mail and MailService.is_claimable(entry)
	_claim_button.disabled = _busy
	_delete_button.visible = has_mail and MailService.is_deletable(entry)
	_delete_button.disabled = _busy
	_render_attachments(entry)
	if not has_mail:
		return
	_title_label.text = _pick(entry, "title")
	_meta_label.text = meta_text(entry)
	var body := _pick(entry, "body")
	_body_label.text = body
	_body_label.visible = not body.is_empty()
	# 显示出来就算读过。已读时 mark_read 什么都不做，所以不会来回重画。
	MailService.mark_read(_selected_id)


# 「3 天前 · 还剩 27 天」。时间都是服务端算好的相对值（手机的钟可能是错的）。
func meta_text(entry: Dictionary) -> String:
	var age := int(entry.get("age_sec", 0))
	var left := int(entry.get("expires_in_sec", 0))
	var sent: String
	if age < HOUR_SEC:
		sent = _t("刚刚", "Just now")
	elif age < DAY_SEC:
		sent = _t("%d 小时前" % (age / HOUR_SEC), "%dh ago" % (age / HOUR_SEC))
	else:
		sent = _t("%d 天前" % (age / DAY_SEC), "%dd ago" % (age / DAY_SEC))
	var expiry: String
	if left < DAY_SEC:
		expiry = _t("今天过期", "Expires today")
	else:
		expiry = _t("还剩 %d 天" % (left / DAY_SEC), "Expires in %dd" % (left / DAY_SEC))
	return "%s · %s" % [sent, expiry]


func _render_attachments(entry: Dictionary) -> void:
	for child in _attach_box.get_children():
		_attach_box.remove_child(child)
		child.queue_free()
	var show := not entry.is_empty() and MailService.has_attachments(entry)
	_attach_title.visible = show
	_attach_box.visible = show
	if not show:
		return
	var claimed := bool(entry.get("claimed", false))
	_attach_title.text = _t("附件（已领取）", "Attachments (claimed)") if claimed else _t("附件", "Attachments")
	if int(entry.get("diamond", 0)) > 0:
		_attach_box.add_child(_chip(Currency.icon("diamond"), "×" + Currency.comma(int(entry.get("diamond", 0))), claimed))
	if int(entry.get("coin", 0)) > 0:
		_attach_box.add_child(_chip(Currency.icon("coin"), "×" + Currency.comma(int(entry.get("coin", 0))), claimed))
	for item in entry.get("items", []):
		if item is Dictionary:
			_attach_box.add_child(_chip(null, item_text(item as Dictionary), claimed))


# 附件里的一样东西：「宠物：猫」。名字是服务端按商品目录给的，客户端不自己查。
func item_text(item: Dictionary) -> String:
	var kind := str(item.get("kind", ""))
	var name_text := str(item.get("name_en" if _english() else "name", item.get("id", "")))
	var label := ""
	match kind:
		"pet":
			label = _t("宠物", "Pet")
		"avatar":
			label = _t("头像", "Avatar")
		"avatar_frame":
			label = _t("头像框", "Frame")
	if label.is_empty():
		return name_text
	return "%s: %s" % [label, name_text] if _english() else "%s：%s" % [label, name_text]


func _chip(icon: Texture2D, text: String, dim: bool) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE_RAISED, Tokens.BORDER, Tokens.GAP_S))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(row)
	if icon != null:
		var rect := TextureRect.new()
		rect.texture = icon
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.custom_minimum_size = CHIP_ICON
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.modulate.a = 0.5 if dim else 1.0
		row.add_child(rect)
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", Tokens.TEXT_DISABLED if dim else Tokens.TEXT_PRIMARY)
	row.add_child(label)
	return panel


# --- 领取 ---------------------------------------------------------------------

func _claim(id: int) -> void:
	if _busy or id <= 0:
		return
	_busy = true
	_render()
	var outcome: Dictionary = await MailService.claim(id)
	_busy = false
	if not is_inside_tree():
		return
	_show_claim_outcome(outcome, false)
	_render()


func _claim_all() -> void:
	if _busy:
		return
	_busy = true
	_render()
	var outcome: Dictionary = await MailService.claim_all()
	_busy = false
	if not is_inside_tree():
		return
	_show_claim_outcome(outcome, true)
	_render()


func _show_claim_outcome(outcome: Dictionary, batch: bool) -> void:
	if not bool(outcome.get("ok", false)):
		var reason := str(outcome.get("error", ""))
		_set_notice(reason if not reason.is_empty() else _t("领取失败，稍后再试", "Could not claim — try again later"), true)
		return
	if bool(outcome.get("replayed", false)):
		_set_notice(_t("这封的附件之前已经领过了", "You already claimed this one"), false)
		return
	var parts: Array[String] = []
	var diamond := int(outcome.get("diamond", 0))
	var coin := int(outcome.get("coin", 0))
	if diamond > 0:
		parts.append(_t("钻石 +%s" % Currency.comma(diamond), "Diamonds +%s" % Currency.comma(diamond)))
	if coin > 0:
		parts.append(_t("金币 +%s" % Currency.comma(coin), "Coins +%s" % Currency.comma(coin)))
	for item in outcome.get("granted", []):
		if item is Dictionary:
			parts.append(item_text(item as Dictionary))
	if parts.is_empty() and (outcome.get("skipped", []) as Array).is_empty():
		_set_notice(_t("没有可领取的附件", "Nothing to claim") if batch else _t("领取完成", "Claimed"), false)
		return
	var sep := _t("、", ", ")
	var message := ""
	if not parts.is_empty():
		message = _t("领取成功：", "Claimed: ") + sep.join(parts)
	var skipped: Array[String] = []
	for item in outcome.get("skipped", []):
		if item is Dictionary:
			skipped.append(item_text(item as Dictionary))
	if not skipped.is_empty():
		# 已拥有的跳过、不折算（docs/邮件系统设计.md 拍板）—— 要明说，不然玩家以为少发了。
		var note := _t("已经拥有，跳过：", "Already owned, skipped: ") + sep.join(skipped)
		message = note if message.is_empty() else message + _t("（%s）" % note, " (%s)" % note)
	_set_notice(message, false)
	if diamond > 0 or coin > 0:
		SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN)


# --- 删除 ---------------------------------------------------------------------

func _delete(id: int) -> void:
	if _busy or id <= 0:
		return
	_busy = true
	_render()
	var outcome: Dictionary = await MailService.delete_mail(id)
	_busy = false
	if not is_inside_tree():
		return
	if bool(outcome.get("ok", false)):
		_set_notice(_t("已删除", "Deleted"), false)
	else:
		var reason := str(outcome.get("error", ""))
		_set_notice(reason if not reason.is_empty() else _t("删不掉，稍后再试", "Could not delete — try again later"), true)
	_render()


func _confirm_delete_read() -> void:
	if _busy:
		return
	var count := MailService.deletable_count()
	if count <= 0:
		return
	DialogService.confirm({
		"title": _t("删除已读邮件", "Delete read mail"),
		"body": _t("删除 %d 封已读、附件已领完的邮件？删除后就看不到了。" % count,
			"Delete %d read mail with nothing left to claim? You won't see them again." % count),
		"confirm_text": _t("删除", "Delete"),
		"owner": self,
		"on_result": func(result: String, _request_id: String) -> void:
			if result == ConfirmDialog.RESULT_CONFIRMED:
				await _delete_read(),
	})


func _delete_read() -> void:
	if _busy:
		return
	_busy = true
	_render()
	var deleted: int = await MailService.delete_read()
	_busy = false
	if not is_inside_tree():
		return
	if deleted < 0:
		_set_notice(_t("删不掉，稍后再试", "Could not delete — try again later"), true)
	else:
		_set_notice(_t("删除了 %d 封" % deleted, "Deleted %d" % deleted), false)
	_render()


# --- 小工具 -------------------------------------------------------------------

func _set_notice(text: String, bad: bool) -> void:
	_notice = text
	_notice_bad = bad


# 中英文两份，英文空着显示中文（同公告）。
func _pick(entry: Dictionary, field: String) -> String:
	var zh := str(entry.get(field + "_zh", ""))
	if _english():
		var en := str(entry.get(field + "_en", ""))
		if not en.is_empty():
			return en
	return zh


func _english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _t(zh: String, en: String) -> String:
	return en if _english() else zh
