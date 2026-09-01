extends Control

# Reusable modal loading/failure panel. ModalStack supplies the independent
# CanvasLayer and input-blocking backdrop; this component supplies stage, real
# progress/counts, network context and the only retry/return controls.

signal cancel_requested(request_id: String)
signal retry_requested(request_id: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")

const MODE_PENDING := "pending"
const MODE_FAILED := "failed"
const MODE_SUCCEEDED := "succeeded"

var _request_id := ""
var _mode := MODE_PENDING
var _stage_key := ""
var _error_code := ""
var _last_progress := 0.0
var _indeterminate := true
var _spinner_elapsed := 0.0
var _spinner_phase := 0
var _resolution_sent := false

var _card: PanelContainer
var _title_label: Label
var _stage_label: Label
var _detail_label: Label
var _network_label: Label
var _progress_bar: ProgressBar
var _spinner_label: Label
var _count_label: Label
var _policy_label: Label
var _error_label: Label
var _retry_button: Button
var _cancel_button: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = Theming.get_theme()
	_ensure_built()
	set_process(true)


func configure(spec: Dictionary) -> void:
	_ensure_built()
	_request_id = str(spec.get("request_id", ""))
	_mode = MODE_PENDING
	_stage_key = ""
	_error_code = ""
	_last_progress = 0.0
	_indeterminate = true
	_resolution_sent = false
	_title_label.text = str(spec.get("title", ""))
	_error_label.visible = false
	_retry_button.visible = false
	_cancel_button.visible = bool(spec.get("cancellable", false))
	_cancel_button.text = str(spec.get("cancel_text", "取消并返回备战"))
	_policy_label.text = str(spec.get("cancel_reason", ""))
	_policy_label.visible = not _policy_label.text.is_empty()
	set_stage(
		str(spec.get("stage_key", "starting")),
		str(spec.get("stage_text", "正在准备战斗")),
		str(spec.get("detail", "")),
		-1.0,
		str(spec.get("counts", "")))
	set_network_text(str(spec.get("network", "")))


# ratio < 0 means unknown. In that state the bar is hidden and only the animated
# marker is shown, so elapsed time is never presented as fake completion.
func set_stage(
	stage_key: String,
	stage_text: String,
	detail: String,
	ratio: float = -1.0,
	counts: String = ""
) -> void:
	_ensure_built()
	_stage_key = stage_key
	_stage_label.text = stage_text
	_detail_label.text = detail
	_detail_label.visible = not detail.is_empty()
	_count_label.text = counts
	_count_label.visible = not counts.is_empty()
	set_progress(ratio)


func set_progress(ratio: float, counts: String = "") -> void:
	_ensure_built()
	if not counts.is_empty():
		_count_label.text = counts
		_count_label.visible = true
	if ratio < 0.0:
		_indeterminate = true
		_progress_bar.visible = false
		_spinner_label.visible = true
		return
	_indeterminate = false
	_last_progress = maxf(_last_progress, clampf(ratio, 0.0, 1.0))
	_progress_bar.value = _last_progress * 100.0
	_progress_bar.visible = true
	_spinner_label.visible = false


func set_network_text(text: String) -> void:
	_ensure_built()
	_network_label.text = text
	_network_label.visible = not text.is_empty()


func set_cancel_policy(cancellable: bool, reason: String = "") -> void:
	_ensure_built()
	_cancel_button.visible = cancellable or _mode == MODE_FAILED
	_policy_label.text = reason
	_policy_label.visible = not reason.is_empty()


func set_failed(error_code: String, message: String, retryable: bool) -> void:
	_ensure_built()
	_mode = MODE_FAILED
	_error_code = error_code
	_resolution_sent = false
	_indeterminate = false
	_stage_key = "failed"
	_stage_label.text = tr("battle_load_failed")
	_detail_label.text = message
	_detail_label.visible = not message.is_empty()
	_progress_bar.visible = false
	_spinner_label.visible = false
	_count_label.visible = false
	_network_label.visible = false
	_error_label.text = tr("battle_load_error_code") % error_code
	_error_label.visible = true
	_retry_button.text = tr("battle_load_retry")
	_retry_button.visible = retryable
	_cancel_button.text = tr("battle_load_back_to_prep")
	_cancel_button.visible = true
	_policy_label.visible = false


func set_entering(stage_text: String) -> void:
	_ensure_built()
	_mode = MODE_SUCCEEDED
	_error_code = ""
	_stage_key = "enter_battle"
	_stage_label.text = stage_text
	_detail_label.visible = false
	_network_label.visible = false
	_count_label.visible = false
	_error_label.visible = false
	_retry_button.visible = false
	_cancel_button.visible = false
	_policy_label.visible = false
	set_progress(1.0)


func snapshot() -> Dictionary:
	return {
		"request_id": _request_id,
		"mode": _mode,
		"stage": _stage_key,
		"error_code": _error_code,
		"progress": -1.0 if _indeterminate else _last_progress,
		"retry_visible": _retry_button != null and _retry_button.visible,
		"cancel_visible": _cancel_button != null and _cancel_button.visible,
	}


func _process(delta: float) -> void:
	if not _indeterminate or _spinner_label == null or not _spinner_label.visible:
		return
	if Tokens.reduced_motion():
		_spinner_label.text = "◆"
		return
	_spinner_elapsed += delta
	if _spinner_elapsed < 0.3:
		return
	_spinner_elapsed = 0.0
	_spinner_phase = (_spinner_phase + 1) % 4
	_spinner_label.text = "◆" + ".".repeat(_spinner_phase)


func _ensure_built() -> void:
	if _card != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var center := CenterContainer.new()
	center.name = "LoadingCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	_card.name = "LoadingCard"
	_card.custom_minimum_size = Vector2(620, 0)
	_card.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.CYAN, Tokens.PAD))
	center.add_child(_card)

	var content := VBoxContainer.new()
	content.name = "LoadingContent"
	content.add_theme_constant_override("separation", Tokens.GAP_M)
	_card.add_child(content)

	_title_label = _make_label("LoadingTitle", Tokens.FONT_TITLE, Tokens.GOLD)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_title_label)

	_stage_label = _make_label("LoadingStage", Tokens.FONT_BODY + 2, Tokens.TEXT_PRIMARY)
	_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_stage_label)

	_spinner_label = _make_label("IndeterminateMarker", Tokens.FONT_TITLE, Tokens.CYAN)
	_spinner_label.text = "◆"
	_spinner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_spinner_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.name = "LoadingProgress"
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size.y = 14
	_progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_bar.visible = false
	content.add_child(_progress_bar)

	_detail_label = _make_label("LoadingDetail", Tokens.FONT_BODY, Tokens.TEXT_SECONDARY)
	_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_detail_label)

	_count_label = _make_label("LoadingCounts", Tokens.FONT_BODY, Tokens.CYAN_HOVER)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_count_label)

	_network_label = _make_label("LoadingNetwork", Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY)
	_network_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_network_label)

	_policy_label = _make_label("CancelPolicy", Tokens.FONT_CAPTION, Tokens.TEXT_DISABLED)
	_policy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_policy_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_policy_label)

	_error_label = _make_label("LoadingErrorCode", Tokens.FONT_CAPTION, Tokens.DANGER_HOVER)
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.visible = false
	content.add_child(_error_label)

	var buttons := HBoxContainer.new()
	buttons.name = "LoadingActions"
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", Tokens.GAP_L)
	content.add_child(buttons)

	_retry_button = _make_button("RetryButton", tr("battle_load_retry"), Theming.VARIATION_PRIMARY)
	_retry_button.visible = false
	_retry_button.pressed.connect(_on_retry_pressed)
	buttons.add_child(_retry_button)

	_cancel_button = _make_button("CancelButton", tr("battle_load_back_to_prep"), Theming.VARIATION_GHOST)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	buttons.add_child(_cancel_button)


func _make_label(node_name: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _make_button(node_name: String, value: String, variation: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = value
	button.theme_type_variation = variation
	button.custom_minimum_size = Vector2(Tokens.BUTTON_MIN_WIDTH, Tokens.BUTTON_HEIGHT)
	button.focus_mode = Control.FOCUS_ALL
	return button


func _on_cancel_pressed() -> void:
	if _resolution_sent:
		return
	_resolution_sent = true
	cancel_requested.emit(_request_id)


func _on_retry_pressed() -> void:
	if _resolution_sent:
		return
	_resolution_sent = true
	retry_requested.emit(_request_id)
