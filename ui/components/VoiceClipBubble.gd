extends PanelContainer

# 聊天里的一条语音（docs/聊天系统设计.md「语音消息」，2026-10-11）。
#
# 私聊、世界频道、房间与对局内**共用这一个**：三条投递路不同，但收到之后长得一样，
# 两套画法迟早会漂（一边有「正在播」一边没有，这种不一致不会报错）。
#
# 点一下放，再点一下停。播放由 VoiceClipService 统一管 —— 同时只响一条，
# 所以这里不自己持播放器，只监听「现在在放哪条」。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

const PLAY_GLYPH := "▶"
const STOP_GLYPH := "■"
# 条宽按秒数长一点，像微信那样一眼看出长短。30 秒封顶。
const MIN_WIDTH := 92.0
const MAX_WIDTH := 220.0

var _clip_id := ""
var _media := ""
var _seconds := 0.0
var _button: Button = null
var _label: Label = null


# message 是私聊 / 世界频道那条消息本身（payload 带 clip_id、media、seconds）。
static func build(message: Dictionary, mine: bool) -> Control:
	var payload := ChatService.voice_payload(message)
	var bubble := new()
	bubble._setup(
		str(payload.get("clip_id", "")),
		str(payload.get("media", "")),
		float(payload.get("seconds", 0.0)),
		mine)
	return bubble


func _setup(clip_id: String, media: String, seconds: float, mine: bool) -> void:
	_clip_id = clip_id
	_media = media
	_seconds = maxf(1.0, seconds)
	add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.GOLD_PRESSED.darkened(0.64) if mine else Tokens.SURFACE_RAISED,
		Tokens.GOLD_PRESSED.darkened(0.18) if mine else Tokens.BORDER.darkened(0.28),
		12))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	add_child(row)

	_button = ACTION_BUTTON.instantiate() as Button
	_button.text = PLAY_GLYPH
	_button.custom_minimum_size = Vector2(44, 36)
	_button.pressed.connect(_toggle)
	row.add_child(_button)

	_label = Label.new()
	_label.text = "%d″" % int(round(_seconds))
	_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_label)

	# 越长的语音条越宽（封顶 30 秒），不用读秒数也能看出长短。
	custom_minimum_size = Vector2(
		lerpf(MIN_WIDTH, MAX_WIDTH, clampf(_seconds / VoiceClipService.MAX_SECONDS, 0.0, 1.0)), 0)


func _ready() -> void:
	if not VoiceClipService.playback_changed.is_connected(_on_playback_changed):
		VoiceClipService.playback_changed.connect(_on_playback_changed)
	_refresh()


func _exit_tree() -> void:
	# VoiceClipService 是常驻的，活得比这个气泡久 —— 不断开的话，
	# 滚动久了会攒下一堆指向已销毁节点的连接。
	if VoiceClipService.playback_changed.is_connected(_on_playback_changed):
		VoiceClipService.playback_changed.disconnect(_on_playback_changed)


func _toggle() -> void:
	if _media.is_empty():
		return
	VoiceClipService.play(_clip_id, _media)


func _on_playback_changed(_clip_id_changed: String, _playing: bool) -> void:
	_refresh()


func _refresh() -> void:
	if _button == null or not is_instance_valid(_button):
		return
	_button.text = STOP_GLYPH if VoiceClipService.is_playing(_clip_id) else PLAY_GLYPH
