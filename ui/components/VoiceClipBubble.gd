extends Button

# 私聊和世界频道共用语音气泡，播放交给 VoiceClipService。
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const MIN_WIDTH := 96.0
const MAX_WIDTH := 224.0
const TAIL_WIDTH := 7.0
const INK := Color("4a2c14")
const EDGE := Color("ae7b34")
const MINE_FILL := Color("f5c877")
const OTHER_FILL := Color("f7e4c1")

var _clip_id := ""
var _media := ""
var _seconds := 0.0
var _mine := false
var _state := "sent"
var _playing := false
var _wave_time := 0.0
var _body_style := Tokens.flat_box(OTHER_FILL, EDGE, 1, 9)
var _focus_style := Tokens.focus_box()
var _status: Label


static func build(message: Dictionary, mine: bool) -> Control:
	var payload := ChatService.voice_payload(message)
	var bubble := new()
	bubble._setup(
		str(payload.get("clip_id", "")),
		str(payload.get("media", "")),
		float(payload.get("seconds", 0.0)),
		mine,
		str(message.get("state", "sent")))
	return bubble


func _setup(clip_id: String, media: String, seconds: float, mine: bool, state: String) -> void:
	_clip_id = clip_id
	_media = media
	_seconds = clampf(seconds, 1.0, VoiceClipService.MAX_SECONDS)
	_mine = mine
	_state = state
	custom_minimum_size = Vector2(lerpf(MIN_WIDTH, MAX_WIDTH, _seconds / VoiceClipService.MAX_SECONDS),
		44.0 if _state == "sent" else 58.0)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for style in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		add_theme_stylebox_override(style, StyleBoxEmpty.new())
	pressed.connect(_toggle)
	for appearance_changed in [mouse_entered, mouse_exited, button_down, button_up, focus_entered, focus_exited]:
		appearance_changed.connect(queue_redraw)

	var duration := Label.new()
	duration.text = "%d″" % roundi(_seconds)
	duration.add_theme_font_override("font", UIFontFallback.bold_font())
	duration.add_theme_font_size_override("font_size", 17)
	duration.add_theme_color_override("font_color", INK)
	duration.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	duration.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if _mine else HORIZONTAL_ALIGNMENT_LEFT
	duration.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(duration)
	duration.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	duration.offset_left = 10.0 if _mine else 41.0
	duration.offset_right = -41.0 if _mine else -10.0
	duration.offset_bottom = -16.0 if _state != "sent" else 0.0

	if _state != "sent":
		_status = Label.new()
		_status.add_theme_color_override("font_color", Color("902c1d") if _state == "failed" else Color("765332"))
		_status.add_theme_font_size_override("font_size", 13)
		_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_status)
		_status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_status.anchor_top = 1.0
		_status.offset_top = -24.0
		_status.offset_bottom = -4.0
		_status.offset_left = 6.0
		_status.offset_right = -6.0


func _ready() -> void:
	LocaleManager.locale_changed.connect(_refresh_locale)
	VoiceClipService.playback_changed.connect(_on_playback_changed)
	_refresh_playback()


func _exit_tree() -> void:
	if LocaleManager.locale_changed.is_connected(_refresh_locale):
		LocaleManager.locale_changed.disconnect(_refresh_locale)
	if VoiceClipService.playback_changed.is_connected(_on_playback_changed):
		VoiceClipService.playback_changed.disconnect(_on_playback_changed)


func _draw() -> void:
	var body := Rect2(Vector2(0.0 if _mine else TAIL_WIDTH, 0.0),
		Vector2(size.x - TAIL_WIDTH, size.y))
	var fill := MINE_FILL if _mine else OTHER_FILL
	match get_draw_mode():
		DRAW_PRESSED, DRAW_HOVER_PRESSED:
			fill = fill.darkened(0.08)
		DRAW_HOVER:
			fill = fill.lightened(0.17)
	_body_style.bg_color = fill
	draw_style_box(_body_style, body)
	if has_focus() and not is_hovered():
		draw_style_box(_focus_style, body.grow(-3.0))
	var sign_x := 1.0 if _mine else -1.0
	var tail := Vector2(body.end.x - 2.0 if _mine else body.position.x + 2.0, size.y * 0.5)
	var tip := tail + Vector2(sign_x * (TAIL_WIDTH + 1.0), 0.0)
	draw_colored_polygon(PackedVector2Array([tail + Vector2(0, -6), tip, tail + Vector2(0, 6)]), fill)
	draw_polyline(PackedVector2Array([tail + Vector2(sign_x, -6), tip, tail + Vector2(sign_x, 6)]), EDGE, 1.0, true)

	var wave := Vector2(body.end.x - 16.0 if _mine else body.position.x + 16.0,
		(size.y - (16.0 if _state != "sent" else 0.0)) * 0.5)
	draw_circle(wave + Vector2(sign_x * 4.0, 0.0), 1.6, INK, true, -1.0, true)
	var facing := PI if _mine else 0.0
	for index in 3:
		var color := INK
		if _playing and index > int(_wave_time / 0.16):
			color.a = 0.27
		var radius := 4.5 + index * 3.3
		draw_arc(wave + Vector2(sign_x * 4.0, 0.0), radius,
			facing - 0.65, facing + 0.65, 12, color, 1.7, true)


func _process(delta: float) -> void:
	_wave_time = fmod(_wave_time + delta, 0.48)
	queue_redraw()


func _toggle() -> void:
	if not _media.is_empty():
		VoiceClipService.play(_clip_id, _media)


func _on_playback_changed(_clip_id_changed: String, _active: bool) -> void:
	_refresh_playback()


func _refresh_playback() -> void:
	_playing = VoiceClipService.is_playing(_clip_id)
	_wave_time = 0.0
	set_process(_playing)
	_refresh_locale()
	queue_redraw()


func _refresh_locale(_locale: String = "") -> void:
	var english := LocaleManager.get_locale().begins_with("en")
	var action := ("Stop voice message" if english else "停止播放语音") if _playing \
		else ("Play voice message" if english else "播放语音")
	accessibility_name = "%s · %d″" % [action, roundi(_seconds)]
	if _status != null:
		_status.text = ("Not sent" if english else "未发送") if _state == "failed" \
			else ("Sending…" if english else "发送中…")
