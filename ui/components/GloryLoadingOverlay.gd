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

# 等待到多久要说话（V3 P1-05）。计时按**进度**复位而不只是阶段：进度在动就
# 不算慢。慢和卡是两件事，把慢说成卡会把正常的冷启动讲成故障。
const EXPLAIN_AFTER_SEC := 2.0
const ESCAPE_AFTER_SEC := 8.0
# 进度推进多少算「有动静」。太小会被浮点抖动一直复位，升级就永远不发生。
const PROGRESS_EPSILON := 0.01

enum Escalation { QUIET, EXPLAINED, ESCAPE_OFFERED }

var _request_id := ""
var _mode := MODE_PENDING
var _stage_key := ""
var _error_code := ""
var _last_progress := 0.0
var _indeterminate := true
var _spinner_elapsed := 0.0
var _spinner_phase := 0
var _resolution_sent := false
var _stage_elapsed := 0.0
var _escalation := Escalation.QUIET
var _escalation_progress := 0.0
# 调用方可以给一句针对本阶段的解释。不给的话，升级时用当前阶段文案兜底 ——
# 兜底也必须指向真实阶段，写死一句「请稍候」等于什么都没说。
var _slow_explanation := ""
var _cancellable := false
var _cancel_reason := ""
var _retryable := false

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
	_cancellable = bool(spec.get("cancellable", false))
	_cancel_reason = str(spec.get("cancel_reason", ""))
	_cancel_button.visible = _cancellable
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
	# 换阶段 = 有进展，等待重新计时。
	_reset_escalation()
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
	_cancellable = cancellable
	_cancel_reason = reason
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
	_retryable = retryable
	_reset_escalation()
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
	_reset_escalation()
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
		"elapsed_sec": _stage_elapsed,
		"escalation": _escalation,
		"escalation_name": Escalation.keys()[_escalation],
		"explanation_visible": _detail_label != null and _detail_label.visible
			and not _detail_label.text.strip_edges().is_empty(),
		"policy_visible": _policy_label != null and _policy_label.visible,
	}


func _process(delta: float) -> void:
	_tick_escalation(delta)
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


# --- 等待升级（V3 P1-05）------------------------------------------------
#
# 两级：2 秒解释为什么慢，8 秒给出路。都不改进度条 —— 用等待时间伪造完成度
# 是清单明令禁止的，而且玩家一旦发现进度条会自己爬，之后就再也不信它。
func _tick_escalation(delta: float) -> void:
	if _mode != MODE_PENDING:
		return
	if not _indeterminate:
		var ratio := _last_progress
		if absf(ratio - _escalation_progress) >= PROGRESS_EPSILON:
			# 进度在动 = 有进展。慢不等于卡。
			_escalation_progress = ratio
			_reset_escalation()
			return
	_stage_elapsed += delta
	var next_level := Escalation.QUIET
	if _stage_elapsed >= ESCAPE_AFTER_SEC:
		next_level = Escalation.ESCAPE_OFFERED
	elif _stage_elapsed >= EXPLAIN_AFTER_SEC:
		next_level = Escalation.EXPLAINED
	if next_level == _escalation:
		return
	_escalation = next_level
	_apply_escalation()


func _apply_escalation() -> void:
	match _escalation:
		Escalation.EXPLAINED:
			_detail_label.text = _slow_text()
			_detail_label.visible = true
		Escalation.ESCAPE_OFFERED:
			_detail_label.text = _slow_text()
			_detail_label.visible = true
			if _cancellable:
				_cancel_button.visible = true
			else:
				# 不可取消时**不造**一个按不动的取消键 —— 那比没有更糟。
				# 改为把「为什么走不掉」摆到明面上（清单：不可取消时显示原因）。
				_policy_label.text = _no_escape_text()
				_policy_label.visible = true
			if _retryable:
				_retry_button.visible = true


func _reset_escalation() -> void:
	_stage_elapsed = 0.0
	_escalation = Escalation.QUIET
	# 复位的含义是「基线就是现在」，不是「基线未知」。不记的话，复位之后的
	# 第一帧会被自己造出来的进度差吃掉，两个门槛整体晚一帧。
	_escalation_progress = _last_progress


func set_slow_explanation(text: String) -> void:
	_slow_explanation = text


# 兜底文案也必须指向真实阶段。写死一句「请稍候」等于什么都没说，
# 而这道门槛的全部意义就是让玩家知道在等什么。
func _slow_text() -> String:
	if not _slow_explanation.strip_edges().is_empty():
		return _slow_explanation
	var stage := _stage_label.text.strip_edges() if _stage_label != null else ""
	if stage.is_empty():
		stage = _stage_key
	if TranslationServer.get_locale().begins_with("en"):
		return "Still on: %s. This is taking longer than usual." % stage
	return "仍在「%s」，比平时久一些，仍在继续" % stage


func _no_escape_text() -> String:
	if not _cancel_reason.strip_edges().is_empty():
		return _cancel_reason
	if TranslationServer.get_locale().begins_with("en"):
		return "This step cannot be cancelled once started; leaving now would" \
			+ " desync the match."
	return "这一步开始后不能中断，中途离开会让对局状态对不上"


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
