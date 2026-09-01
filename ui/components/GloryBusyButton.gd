extends Button

# Button-side visual contract for AsyncActionController. The busy verb is written
# before disabled=true, so there is never a frame where the control silently stops
# responding. A caller may bind an existing child Label to preserve legacy layout.

const Theming := preload("res://ui/theme/GloryTheme.gd")

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
	disabled = true
	set_process(true)


func show_terminal(request_id: String, state: String, message: String) -> bool:
	if not _request_id.is_empty() and request_id != _request_id:
		return false
	_request_id = request_id
	_visual_state = state
	set_process(false)
	_apply_text(message)
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
	disabled = false
	return true


func action_snapshot() -> Dictionary:
	return {
		"request_id": _request_id,
		"state": _visual_state,
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
