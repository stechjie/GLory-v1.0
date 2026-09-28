extends PanelContainer

# 举报一个玩家（backend/app/reports.py，2026-09-27）。资料页、世界频道共用。
#
# 玩家只选「为什么」+ 可选一句补充。**证据由服务器在举报那一刻复制**（他的世界频道发言、
# 你们的私聊、他当时的资料），客户端不上传任何聊天记录 —— 那可以伪造，也用不着玩家截图。
#
# 走 ModalStack（同 ChatInputBar）：点外面收起、返回键能关、页面切走（owner 被释放）自动关。
# 按钮实例化 GloryActionButton.tscn，不写 Button.new()（V3 P1-08 棘轮）。
#
# 用法：
#   ReportDialog.new().present(self, friend_code, "昵称 #好友码", "world", message_id)
# context 取 AccountManager.REPORT_CONTEXTS 之一；message_id 只有世界频道里举报某一条时才给。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

const MODAL_ID := "report_player"
# 高于页面级面板与输入条（50），低于 DialogService（100）—— 提交后弹的「已收到」要盖在它上面。
const MODAL_PRIORITY := 60
const WIDTH := 600.0
# 与 backend/app/text_guard.py 的 REPORT_DETAIL_MAX 一致。
const DETAIL_MAX := 200
# AccountManager.REPORT_REASONS 里每一项给玩家看的字（顺序跟着那边）。
const REASON_LABELS := {
	"abuse": ["辱骂 / 骚扰", "Abuse / harassment"],
	"ads": ["广告 / 留联系方式", "Ads / contact info"],
	"cheat": ["外挂 / 作弊", "Cheating"],
	"name": ["不当昵称 / 头像 / 签名", "Offensive name / avatar / bio"],
	"other": ["其他", "Other"],
}

var _code := ""
var _who := ""
var _context := "profile"
var _message_id := 0
var _reason := ""
var _reason_buttons: Dictionary = {}   # reason -> Button
var _detail: LineEdit
var _error: Label
var _submit_button: Button


func present(owner: Object, friend_code: String, who: String, context: String, message_id: int = 0) -> void:
	_code = friend_code
	_who = who
	_context = context
	_message_id = message_id
	ModalStack.push(self, {
		"id": MODAL_ID,
		"owner": owner,
		"priority": MODAL_PRIORITY,
		"dismiss_on_backdrop": true,
	})


func _ready() -> void:
	theme = Theming.get_theme()
	var width := minf(WIDTH, get_viewport_rect().size.x - Tokens.PAD * 2.0)
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -width * 0.5
	offset_right = width * 0.5
	grow_vertical = Control.GROW_DIRECTION_BOTH
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.PAD))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	add_child(col)

	var title := Label.new()
	title.text = _text("举报 %s", "Report %s") % _who
	title.clip_text = true
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	col.add_child(title)

	var hint := Label.new()
	hint.text = _text(
		"我们会核对服务器上的记录（他的发言、你们的私聊、他的资料），不用截图。举报对方不会知道是谁举报的。",
		"We check the server's own records (their messages, your chats, their profile) — no screenshots needed. They won't know who reported them.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	hint.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	col.add_child(hint)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Tokens.GAP_S)
	grid.add_theme_constant_override("v_separation", Tokens.GAP_S)
	col.add_child(grid)
	for reason in AccountManager.REPORT_REASONS:
		var labels: Array = REASON_LABELS.get(reason, [reason, reason])
		var button := _button(_text(str(labels[0]), str(labels[1])), _pick.bind(str(reason)))
		button.toggle_mode = true
		button.theme_type_variation = Theming.VARIATION_GHOST
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 选中态的外框（2026-09-28 反馈第 1 条）。GHOST 变体原本把 normal/hover/pressed
		# 三态都设成「透明底 + 一圈边框」，而 pressed（= 选中并被保持）用的边框色是
		# SURFACE_RAISED(0.105,0.121,0.161)，与弹窗底色 SURFACE(0.071,0.082,0.110)
		# 几乎一样 —— 于是**选中的那个按钮看起来没有边框**，未选中的反而有。
		# 这里按需求反过来：未选中（normal）无边框，选中（pressed）带金色外框。
		# 只覆写样式盒，不动布局/文字/字号 —— 需求原文「保持原有布局、文字、配色不变」。
		button.add_theme_stylebox_override("normal", Tokens.button_box(Tokens.BORDER, Tokens.BORDER, false))
		button.add_theme_stylebox_override("hover", Tokens.button_box(Tokens.CYAN, Tokens.CYAN, false))
		button.add_theme_stylebox_override("pressed", _selected_box())
		grid.add_child(button)
		_reason_buttons[str(reason)] = button

	_detail = LineEdit.new()
	_detail.max_length = DETAIL_MAX
	_detail.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_detail.placeholder_text = _text("补充说明（可不填）", "Anything else? (optional)")
	col.add_child(_detail)

	_error = Label.new()
	_error.visible = false
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_error.add_theme_color_override("font_color", Tokens.DANGER_HOVER)
	col.add_child(_error)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(row)
	var cancel := _button(_text("取消", "Cancel"), _close)
	cancel.theme_type_variation = Theming.VARIATION_GHOST
	row.add_child(cancel)
	_submit_button = _button(_text("提交举报", "Submit"), _submit)
	_submit_button.theme_type_variation = Theming.VARIATION_DANGER
	row.add_child(_submit_button)


func _pick(reason: String) -> void:
	_reason = reason
	for key in _reason_buttons:
		(_reason_buttons[key] as Button).set_pressed_no_signal(key == reason)
	_error.visible = false


func _submit() -> void:
	if _reason.is_empty():
		_show_error(_text("请选择举报原因", "Please choose a reason"))
		return
	_submit_button.disabled = true
	var result: Dictionary = await AccountManager.report_player(_code, _context, _reason, _message_id, _detail.text)
	if not is_inside_tree():
		return
	_submit_button.disabled = false
	if int(result.get("code", 0)) / 100 != 2:
		_show_error(str(result.get("error", _text("提交失败，请稍后再试", "Failed to submit, please retry"))))
		return
	_close()
	# 重复举报也是这一句（服务器那边同一个人对同一个人只算一条，不告诉举报人「你举报过了」）。
	DialogService.info({
		"title": _text("已收到", "Received"),
		"body": _text("举报已收到，我们会尽快核实处理。谢谢你帮忙维护游戏环境。",
			"Thanks — we've received your report and will review it soon."),
	})


func _show_error(message: String) -> void:
	_error.text = message
	_error.visible = true


func _close() -> void:
	ModalStack.pop(MODAL_ID)


# 「已选中」的外框（反馈第 1 条）：实底用比弹窗更亮一档的金色，
# 描边用 CYAN_HOVER —— 一眼分得出「这个被选中了」。底色仍保持透明，
# 不引入新的填充色（需求要求「保持原有配色不变」）。
static func _selected_box() -> StyleBoxFlat:
	var box := Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.CYAN_HOVER, false)
	# 选中框给两倍线宽：同色细框在深底上仍然容易看漏，加粗才算「带外边框」。
	box.set_border_width_all(Tokens.BORDER_WIDTH * 2)
	return box


func _button(label_text: String, on_press: Callable) -> Button:
	var button := ACTION_BUTTON.instantiate() as Button
	button.text = label_text
	button.custom_minimum_size = Vector2(120, Tokens.TOUCH_MIN)
	button.size_flags_horizontal = Control.SIZE_FILL
	button.pressed.connect(on_press)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
