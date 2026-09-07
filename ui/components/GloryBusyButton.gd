extends Button

# Button-side visual contract for AsyncActionController. The busy verb is written
# before disabled=true, so there is never a frame where the control silently stops
# responding. A caller may bind an existing child Label to preserve legacy layout.

const Theming := preload("res://ui/theme/GloryTheme.gd")
const DisabledReason := preload("res://ui/components/GloryDisabledReason.gd")

const STATE_IDLE := "idle"
const STATE_PRESSED := "pressed"
const STATE_PENDING := "pending"
const STATE_SUCCEEDED := "succeeded"
const STATE_FAILED := "failed"
const STATE_CANCELLED := "cancelled"
const STATE_TIMED_OUT := "timed_out"

var _content_label: Label
var _idle_text := ""
var _request_id := ""
var _visual_state := STATE_IDLE
var _busy_verb := ""
var _dot_phase := 0
var _dot_elapsed := 0.0
# 闲时用的主题变体，进忙碌态前记下来，结算后还回去。不记的话，
# 一个 GloryPrimary 按钮跑完一次异步动作就永久变成默认样式。
var _idle_variation := &""


func _ready() -> void:
	if theme == null:
		theme = Theming.get_theme()
	button_down.connect(_on_internal_button_down)
	button_up.connect(_on_internal_button_up)
	set_process(false)


func bind_content_label(label: Label) -> void:
	_content_label = label
	_apply_text(_idle_text)


func set_idle_text(value: String) -> void:
	_idle_text = value
	if _visual_state == STATE_IDLE:
		_apply_text(value)


func show_pending(request_id: String, verb: String) -> void:
	_request_id = request_id
	_busy_verb = verb
	_visual_state = STATE_PENDING
	_dot_phase = 0
	_dot_elapsed = 0.0
	_apply_busy_text()
	# The visible verb is set first. Do not reverse these two lines.
	#
	# disabled=true 之外还要换成忙碌变体（V3 P1-01）。只置 disabled 的话，
	# 「你点到了、正在做」和「这个按钮现在不能点」长得一模一样 ——
	# 玩家读成后者就会继续找别的地方点，或者反复点这一个。
	_enter_busy_look()
	# 忙碌中被点到时能说出「正在做什么」。
	#
	# 这是全游戏最常被点的禁用按钮：玩家点了没立刻变化，本能就是再点一下。
	# 挂在这里一处，所有走 AsyncActionController 的按钮一起有了解释，
	# 不用去每个 _start_*_action() 里逐个补。
	DisabledReason.attach(self, verb)
	disabled = true
	set_process(true)


func show_terminal(request_id: String, state: String, message: String) -> bool:
	if not _request_id.is_empty() and request_id != _request_id:
		return false
	_request_id = request_id
	_visual_state = state
	set_process(false)
	_apply_text(message)
	_restore_idle_look()
	DisabledReason.clear(self)
	disabled = false
	return true


func reset_idle(request_id: String = "") -> bool:
	if not request_id.is_empty() and not _request_id.is_empty() and request_id != _request_id:
		return false
	_request_id = ""
	_visual_state = STATE_IDLE
	_busy_verb = ""
	set_process(false)
	_apply_text(_idle_text)
	_restore_idle_look()
	DisabledReason.clear(self)
	disabled = false
	return true


func _enter_busy_look() -> void:
	if theme_type_variation != Theming.VARIATION_BUSY:
		_idle_variation = theme_type_variation
	theme_type_variation = Theming.VARIATION_BUSY


func _restore_idle_look() -> void:
	theme_type_variation = _idle_variation


func action_snapshot() -> Dictionary:
	return {
		"request_id": _request_id,
		"state": _visual_state,
		"variation": str(theme_type_variation),
		"looks_busy": theme_type_variation == Theming.VARIATION_BUSY,
		"busy_text_visible": _visual_state == STATE_PENDING and not _display_text().strip_edges().is_empty(),
		"disabled": disabled,
	}


func _process(delta: float) -> void:
	if _visual_state != STATE_PENDING:
		return
	_dot_elapsed += delta
	if _dot_elapsed < 0.35:
		return
	_dot_elapsed = 0.0
	_dot_phase = (_dot_phase + 1) % 3
	_apply_busy_text()


func _on_internal_button_down() -> void:
	if _visual_state == STATE_IDLE:
		_visual_state = STATE_PRESSED


func _on_internal_button_up() -> void:
	if _visual_state == STATE_PRESSED:
		_visual_state = STATE_IDLE


func _apply_busy_text() -> void:
	_apply_text(_busy_verb + ".".repeat(_dot_phase + 1))


func _apply_text(value: String) -> void:
	if _content_label != null and is_instance_valid(_content_label):
		_content_label.text = value
	else:
		text = value


func _display_text() -> String:
	if _content_label != null and is_instance_valid(_content_label):
		return _content_label.text
	return text
