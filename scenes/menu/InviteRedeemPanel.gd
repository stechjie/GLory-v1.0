extends PanelContainer

# 资料页「资料设置」里的「邀请与兑换码」（backend/app/invites.py、redeem.py；2026-11-03 用户拍板）。
#
# 放资料页、不放设定页：设定页在对局里也会弹出来（见 ProfileScreen._account_section 的注释），
# 而这两样都要联网、会发奖。
#
# 拆成单独一个面板（同 ProgressionPanel / MatchHistoryPanel）：资料页已经很长；
# 拆出来门禁就能脱离整个资料页、注入一个假的 api 单独测（tools/invite_redeem_check）。
#
# 🔴 邀请了几个人、到账几个**不显示**（用户定），服务器也不下发。这里只有：
#    自己的码、规则说明、填好友的码（只有还能填的新账号才出现）、兑换码。
#    奖励一律发到邮箱，这里不碰钱包。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
# 11.11 只在资料页用：跟着资料页换成羊皮纸卡片。
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

# 门禁注入假的；平时就是 AccountManager（fetch_invite / bind_invite / redeem_code）。
var api: Object = null
# 发奖之后让邮箱马上去拉一次，不等最多 30 秒的推送。门禁注入一个计数用的 Callable。
var refresh_mail: Callable = Callable()

var _friend_code := ""
var _busy := false

var _code_label: Label
var _copy_btn: Button
var _rule_label: Label
var _bind_row: HBoxContainer
var _bind_edit: LineEdit
var _bind_btn: Button
var _bound_label: Label
var _redeem_edit: LineEdit
var _redeem_btn: Button
var _message: Label


func _ready() -> void:
	if api == null:
		api = AccountManager
	if not refresh_mail.is_valid():
		refresh_mail = func() -> void: MailService.refresh(true)
	_build()
	load_status()


# 资料页拿到自己的资料后调。码就是好友码，资料里本来就有，不再单独要一次。
func set_friend_code(code: String) -> void:
	_friend_code = code
	if _code_label == null:
		return
	_code_label.text = code if not code.is_empty() else "—"
	_copy_btn.disabled = code.is_empty()


func load_status() -> void:
	var result: Dictionary = await api.fetch_invite()
	if not is_inside_tree():
		return
	var ok := int(result.get("code", 0)) == 200 and result.get("body") is Dictionary
	# 读不到就当「什么都不能填」：只留自己的码和兑换码。宁可少一个入口，
	# 也不要摆出一个点了必报错的输入框。
	apply_status(result["body"] if ok else {})


func apply_status(status: Dictionary) -> void:
	var level := int(status.get("reward_level", 0))
	var mine := int(status.get("inviter_diamond", 0))
	var theirs := int(status.get("invitee_diamond", 0))
	# 门槛和钻石数都从服务器拿：改 .env 就变，不用出包。
	_rule_label.visible = level > 0
	_rule_label.text = _text(
		"好友填你的邀请码、升到 %d 级时：你得 %d 钻石，Ta 得 %d 钻石" % [level, mine, theirs],
		"When a friend enters your code and reaches level %d: you get %d diamonds, they get %d" % [level, mine, theirs])
	_bind_row.visible = bool(status.get("can_bind", false))
	var bound := bool(status.get("bound", false))
	_bound_label.visible = bound
	if not bound:
		return
	if bool(status.get("rewarded", false)):
		_bound_label.text = _text("邀请奖励已发到邮箱", "Your invite reward has been sent to your mailbox")
	else:
		_bound_label.text = _text(
			"已填写好友的邀请码：升到 %d 级后，奖励发到邮箱" % level,
			"Invite code entered. Reach level %d and your reward will arrive by mail" % level)


func _build() -> void:
	add_theme_stylebox_override("panel", Kit.box("card"))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	add_child(column)

	var title := Label.new()
	title.text = _text("邀请与兑换码", "Invites & codes")
	title.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	title.add_theme_color_override("font_color", Color("8a4b12"))
	column.add_child(title)

	var code_row := HBoxContainer.new()
	code_row.add_theme_constant_override("separation", Tokens.GAP_S)
	column.add_child(code_row)
	var caption := _small(_text("我的邀请码", "My invite code"))
	# 横排里的标签**不能**自动换行：会被挤到最小宽度、一个字一行，把整块撑高（11-03 实渲截图踩到）。
	caption.autowrap_mode = TextServer.AUTOWRAP_OFF
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	code_row.add_child(caption)
	_code_label = Label.new()
	_code_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_code_label.add_theme_color_override("font_color", Kit.INK)
	_code_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	code_row.add_child(_code_label)
	_copy_btn = _button(_text("复制", "Copy"))
	_copy_btn.pressed.connect(_on_copy)
	code_row.add_child(_copy_btn)

	_rule_label = _small("")
	_rule_label.visible = false
	column.add_child(_rule_label)

	_bind_row = HBoxContainer.new()
	_bind_row.add_theme_constant_override("separation", Tokens.GAP_S)
	_bind_row.visible = false
	column.add_child(_bind_row)
	_bind_edit = _code_edit(_text("好友的邀请码", "Friend's code"), 12)
	_bind_edit.text_submitted.connect(func(_t: String) -> void: _on_bind())
	_bind_row.add_child(_bind_edit)
	_bind_btn = _button(_text("确定", "Enter"))
	_bind_btn.pressed.connect(_on_bind)
	_bind_row.add_child(_bind_btn)

	_bound_label = _small("")
	_bound_label.visible = false
	column.add_child(_bound_label)

	var redeem_row := HBoxContainer.new()
	redeem_row.add_theme_constant_override("separation", Tokens.GAP_S)
	column.add_child(redeem_row)
	_redeem_edit = _code_edit(_text("兑换码", "Redeem code"), 30)
	_redeem_edit.text_submitted.connect(func(_t: String) -> void: _on_redeem())
	redeem_row.add_child(_redeem_edit)
	_redeem_btn = _button(_text("兑换", "Redeem"))
	_redeem_btn.pressed.connect(_on_redeem)
	redeem_row.add_child(_redeem_btn)

	_message = _small("")
	_message.visible = false
	column.add_child(_message)
	set_friend_code(_friend_code)


func _on_copy() -> void:
	if _friend_code.is_empty():
		return
	DisplayServer.clipboard_set(_friend_code)
	_say(_text("已复制邀请码", "Invite code copied"))


func _on_bind() -> void:
	var code := _bind_edit.text.strip_edges()
	if _busy or code.is_empty():
		return
	_set_busy(true)
	_say(_text("提交中…", "Submitting…"))
	var result: Dictionary = await api.bind_invite(code)
	_set_busy(false)
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		# 输入框保留：多半是抄错了一个字，改一下再点。
		_say(_failure(result))
		return
	var body: Dictionary = result["body"] if result.get("body") is Dictionary else {}
	_bind_edit.text = ""
	apply_status(body)
	_say(_text("填写成功", "Code accepted"))
	# 填的时候已经够级了，服务器当场就发了：让邮箱马上亮。
	if bool(body.get("rewarded", false)):
		refresh_mail.call()


func _on_redeem() -> void:
	var code := _redeem_edit.text.strip_edges()
	if _busy or code.is_empty():
		return
	_set_busy(true)
	_say(_text("兑换中…", "Redeeming…"))
	var result: Dictionary = await api.redeem_code(code)
	_set_busy(false)
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		_say(_failure(result))
		return
	_redeem_edit.text = ""
	_say(_text("兑换成功，奖励已发到邮箱", "Redeemed! Your reward has been sent to your mailbox"))
	refresh_mail.call()


func _set_busy(busy: bool) -> void:
	_busy = busy
	_bind_btn.disabled = busy
	_redeem_btn.disabled = busy


func _failure(result: Dictionary) -> String:
	if int(result.get("code", 0)) == 0:
		return _text("连不上服务器，稍后再试", "Can't reach the server, try again later")
	# AccountManager 已经按语言翻好了服务器的 detail（AccountErrorText）。
	return str(result.get("error", ""))


func _say(text_value: String) -> void:
	_message.text = text_value
	# 空着也占一行高；这一栏还要放注销，一行都省。
	_message.visible = not text_value.is_empty()


func _small(text_value: String) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY - 4)
	label.add_theme_color_override("font_color", Kit.INK_SOFT)
	return label


func _code_edit(placeholder: String, max_chars: int) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	# 留余量：玩家抄码常带空格、连字符，服务器会去掉。
	edit.max_length = max_chars
	edit.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return edit


func _button(label: String) -> Button:
	var button := ACTION_BUTTON.instantiate() as Button
	button.text = label
	button.custom_minimum_size = Vector2(96, Tokens.TOUCH_MIN)
	# 横排会把子节点竖着拉满：旁边有一块多行文字时，按钮会被拉成一根竖条。
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
