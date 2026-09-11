extends PanelContainer

# 房间 / 局内自由文字的输入条（`docs/聊天系统设计.md` 批次 D）。
#
# **贴在屏幕顶部，不贴在聊天框旁边。** 手机上输入框一拿到焦点，系统键盘就从底部弹出、
# 盖住下半个屏幕 —— 而大厅聊天框在左下角、备战期的聊天入口在右下角，
# 输入框放在它们旁边就正好被键盘盖住，玩家看不见自己在打什么。
# Godot 不会替你把界面顶上去，所以只能一开始就放在键盘够不着的地方。
#
# 走 ModalStack：点外面就收起、返回键能关、页面切走（owner 被释放）自动关 ——
# 不会留下一块吃点击的玻璃板（ModalStack 顶部那段说的事故）。
#
# 按钮实例化 GloryActionButton.tscn，不写 Button.new()（V3 P1-08 棘轮）。
#
# 用法：
#   ChatInputBar.new().present(self, func(text: String) -> String:
#       return NetworkService.team_send_text(text))
# 回调返回空串 = 已发出（输入条收起）；否则是给玩家看的原因（输入条留着、文字不清空，
# 改一改还能再发）。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ChatText := preload("res://scripts/multiplayer/ChatText.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

# 固定 id：连点「打字」只会有一个输入条（ModalStack 拒绝重复 id，并收掉多出来的那个）。
const MODAL_ID := "chat_text_input"
# 高于页面级面板（40），低于 DialogService（100）—— 输入中弹出的确认框要盖在它上面。
const MODAL_PRIORITY := 50
const BAR_WIDTH := 880.0
const TOP_MARGIN := 24.0

var _on_submit: Callable = Callable()
var _input: LineEdit
var _error: Label


func present(owner: Object, on_submit: Callable) -> void:
	_on_submit = on_submit
	ModalStack.push(self, {
		"id": MODAL_ID,
		"owner": owner,
		"priority": MODAL_PRIORITY,
		# 点外面 = 不打了。这不是危险操作，不需要玩家明确选一边。
		"dismiss_on_backdrop": true,
	})


func _ready() -> void:
	theme = Theming.get_theme()
	# 顶部居中。宽度按屏幕收：比屏幕还宽的输入条两头会被切掉。
	var width := minf(BAR_WIDTH, get_viewport_rect().size.x - Tokens.PAD * 2.0)
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -width * 0.5
	offset_right = width * 0.5
	offset_top = TOP_MARGIN
	offset_bottom = TOP_MARGIN
	mouse_filter = Control.MOUSE_FILTER_STOP

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(row)

	_input = LineEdit.new()
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	# 与 ③ 那道校验同一个上限（tools/chat_check.gd 钉着，不许写死）。
	_input.max_length = ChatText.MAX_CHARS
	_input.placeholder_text = _text(
		"说点什么…（最多 %d 字）" % ChatText.MAX_CHARS,
		"Say something… (max %d)" % ChatText.MAX_CHARS)
	_input.text_submitted.connect(func(_submitted: String) -> void: _submit())
	row.add_child(_input)

	var send := _button(_text("发送", "Send"), _submit)
	send.theme_type_variation = Theming.VARIATION_PRIMARY
	row.add_child(send)

	var cancel := _button(_text("取消", "Cancel"), _close)
	cancel.theme_type_variation = Theming.VARIATION_GHOST
	row.add_child(cancel)

	_error = Label.new()
	_error.visible = false
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_error.add_theme_color_override("font_color", Tokens.DANGER_HOVER)
	col.add_child(_error)

	# 拿到焦点才会弹出系统键盘。延一帧：ModalStack 可能把挂树推迟到了本帧末。
	_input.grab_focus.call_deferred()


func _submit() -> void:
	if not _on_submit.is_valid():
		_close()
		return
	var reason := str(_on_submit.call(_input.text))
	if reason.is_empty():
		_close()
		return
	_error.text = reason
	_error.visible = true


func _close() -> void:
	ModalStack.pop(MODAL_ID)


func _button(label_text: String, on_press: Callable) -> Button:
	var button := ACTION_BUTTON.instantiate() as Button
	button.text = label_text
	button.custom_minimum_size = Vector2(120, Tokens.TOUCH_MIN)
	button.size_flags_horizontal = Control.SIZE_FILL
	button.pressed.connect(on_press)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
