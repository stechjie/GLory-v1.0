extends Control
class_name GloryConfirmDialog

# 全项目统一的确认/提示框（V3 P1-02）。
#
# 替换掉的是 TutorialMode._show_skip_confirm()：那里现场 new 出 ColorRect +
# PanelContainer + 两个 140×40 的默认 Button，按钮几乎是 Godot 原生外观，没有主次、
# 没有按压态，40 的高度在手机上也低于 48 dp 的触控下限。
#
# 合同（调用方只需要知道这一条）：
#   configure(spec) 之后，resolved 信号**恰好发一次**，携带 confirmed / cancelled
#   / dismissed 之一和调用方给的 request_id。连点确认 10 次也只发一次 —— 危险操作
#   （放弃教学、删档）不能因为手抖执行两遍。
#
# 遮罩不归本类管：由 ModalStack 创建和销毁，见 ui/services/ModalStack.gd。
# 本类只负责那张卡片本身。

signal resolved(result: String, request_id: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")

enum Intent {
	NORMAL,  ## 普通确认：主按钮暖金
	DANGER,  ## 不可逆操作：主按钮暗红，且默认焦点留在取消
	INFO,    ## 只有一个「知道了」，没有取消
}

const RESULT_CONFIRMED := "confirmed"
const RESULT_CANCELLED := "cancelled"
const RESULT_DISMISSED := "dismissed"

var _request_id := ""
var _intent: int = Intent.NORMAL
var _resolved_once := false

var _card: PanelContainer
var _title_label: Label
var _body_scroll: ScrollContainer
var _body_label: Label
var _confirm_btn: Button
var _cancel_btn: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 卡片之外的区域不吃输入 —— 那是 ModalStack 的 backdrop 该管的事。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = Theming.get_theme()


# spec:
#   title / body          已本地化的最终文案（调用方用自己的 _t 生成）
#   intent                Intent 之一，默认 NORMAL
#   confirm_text          默认「确定」
#   cancel_text           默认「取消」
#   request_id            回调时原样带回，用于去重与埋点
func configure(spec: Dictionary) -> void:
	_request_id = str(spec.get("request_id", ""))
	_intent = int(spec.get("intent", Intent.NORMAL))

	if _card != null and is_instance_valid(_card):
		_card.queue_free()
	_build(spec)
	_animate_in()


func request_id() -> String:
	return _request_id


# Back / ui_cancel 走这里，语义等同点「取消」。
func cancel(reason: String = RESULT_CANCELLED) -> void:
	_resolve(reason)


# --- 构建 ---------------------------------------------------------------------

func _build(spec: Dictionary) -> void:
	var center := CenterContainer.new()
	center.name = "DialogCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	_card.name = "DialogCard"
	_card.custom_minimum_size = Vector2(Tokens.DIALOG_WIDTH, 0)
	_card.add_theme_stylebox_override("panel", Tokens.panel_box())
	center.add_child(_card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.GAP_L)
	_card.add_child(box)

	var title := str(spec.get("title", ""))
	if not title.is_empty():
		_title_label = Label.new()
		_title_label.name = "DialogTitle"
		_title_label.text = title
		_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_title_label.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
		_title_label.add_theme_color_override("font_color", Tokens.GOLD)
		box.add_child(_title_label)

	# 正文放进 ScrollContainer：长文（错误码、断线说明）必须能滚，
	# 不能把按钮顶出安全区（P1-02 交互要求）。
	#
	# 坑：ScrollContainer 的最小尺寸**不**随子节点增长，默认会塌成 0 高，
	# 于是正文整段看不见（第一次抓图就是这样：标题和按钮在，正文没了）。
	# 所以高度必须进树后按实际文本量算，见 _fit_body_scroll()。
	_body_scroll = ScrollContainer.new()
	_body_scroll.name = "DialogBodyScroll"
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_body_scroll)
	var scroll := _body_scroll

	_body_label = Label.new()
	_body_label.name = "DialogBody"
	_body_label.text = str(spec.get("body", ""))
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body_label.custom_minimum_size = Vector2(Tokens.DIALOG_WIDTH - Tokens.PAD * 2, 0)
	_body_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_body_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	scroll.add_child(_body_label)

	# 按钮组居中。组内仍是「取消在左、主操作在右」，改的只是这一组在卡片里的位置。
	# 靠右排会让手指从屏幕中心多移一段，且卡片左半边空出一大块，视觉重心偏。
	var row := HBoxContainer.new()
	row.name = "DialogButtons"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", Tokens.GAP_L)
	box.add_child(row)

	if _intent != Intent.INFO:
		_cancel_btn = _make_button(
			str(spec.get("cancel_text", "取消")),
			Theming.VARIATION_GHOST)
		_cancel_btn.name = "CancelButton"
		_cancel_btn.pressed.connect(_on_cancel_pressed)
		row.add_child(_cancel_btn)

	var confirm_variation := (Theming.VARIATION_DANGER
		if _intent == Intent.DANGER
		else Theming.VARIATION_PRIMARY)
	_confirm_btn = _make_button(str(spec.get("confirm_text", "确定")), confirm_variation)
	_confirm_btn.name = "ConfirmButton"
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	row.add_child(_confirm_btn)

	_apply_default_focus()
	_fit_body_scroll.call_deferred()


# 正文区高度 = 文本实际需要的高度，但不超过上限；超过就变成可滚区域，
# 保证按钮永远留在卡片里、不被顶出安全区。
func _fit_body_scroll() -> void:
	if _body_scroll == null or not is_instance_valid(_body_scroll):
		return
	if _body_label == null or not is_instance_valid(_body_label):
		return
	var wanted := _body_label.get_combined_minimum_size().y
	_body_scroll.custom_minimum_size.y = minf(wanted, Tokens.DIALOG_MAX_BODY_HEIGHT)


func _make_button(text: String, variation: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.theme_type_variation = variation
	# 高度取 BUTTON_HEIGHT 而不是原来的 40：手机触控目标下限是 48 dp。
	btn.custom_minimum_size = Vector2(Tokens.BUTTON_MIN_WIDTH, Tokens.BUTTON_HEIGHT)
	btn.focus_mode = Control.FOCUS_ALL
	btn.button_down.connect(_on_button_down.bind(btn))
	btn.button_up.connect(_on_button_up.bind(btn))
	return btn


# 默认焦点落在「安全」的那一侧：有取消就停在取消，避免键盘/手柄用户
# 一个回车就把不可逆操作执行了（P1-02 交互要求）。
func _apply_default_focus() -> void:
	var target := _cancel_btn if _cancel_btn != null else _confirm_btn
	if target != null:
		# 用 Callable 而不是 call_deferred("grab_focus")：按名字调用会计入
		# dynamic_call_check 的棘轮，而这里完全没必要放弃静态检查。
		target.grab_focus.call_deferred()


# --- 结果 ---------------------------------------------------------------------

func _on_confirm_pressed() -> void:
	_resolve(RESULT_CONFIRMED)


func _on_cancel_pressed() -> void:
	_resolve(RESULT_CANCELLED)


# 唯一的出口。_resolved_once 是「连点只算一次」的全部实现：
# 按钮不禁用也不会重复发信号，所以不需要在每个调用方各写一遍防抖。
func _resolve(result: String) -> void:
	if _resolved_once:
		return
	_resolved_once = true
	resolved.emit(result, _request_id)


# --- 动效 ---------------------------------------------------------------------

func _animate_in() -> void:
	if _card == null:
		return
	var duration := Tokens.motion(Tokens.MOTION_DIALOG_IN)
	if duration <= 0.0:
		# reduced motion：直接是最终状态，不留半透明的中间帧。
		_card.modulate.a = 1.0
		return
	_card.modulate.a = 0.0
	if not is_inside_tree():
		# create_tween() 要求节点在树上。ModalStack 在 root 忙时会推迟挂载，
		# 所以这里不能假定 configure() 时已经进树，否则动画报错、卡片停在全透明。
		tree_entered.connect(_start_in_tween.bind(duration), CONNECT_ONE_SHOT)
		return
	_start_in_tween(duration)


func _start_in_tween(duration: float) -> void:
	if _card == null or not is_instance_valid(_card) or not is_inside_tree():
		return
	var tween := create_tween()
	tween.tween_property(_card, "modulate:a", 1.0, duration)


func _on_button_down(btn: Button) -> void:
	_scale_button(btn, Tokens.PRESS_SCALE)


func _on_button_up(btn: Button) -> void:
	_scale_button(btn, 1.0)


func _scale_button(btn: Button, target: float) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	btn.pivot_offset = btn.size * 0.5
	var duration := Tokens.motion(Tokens.MOTION_PRESS)
	if duration <= 0.0 or not is_inside_tree():
		btn.scale = Vector2(target, target)
		return
	var tween := create_tween()
	tween.tween_property(btn, "scale", Vector2(target, target), duration)
