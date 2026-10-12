extends HBoxContainer

# 房间 / 对局记录里的一条语音（docs/聊天系统设计.md「语音消息」，2026-10-11）。
#
# 和私聊 / 世界频道的 VoiceClipBubble 不是同一个东西：那边是独立气泡，
# 这边是**在原来那行字前面加一颗播放键** —— 大厅和摆放界面的记录是一行一条的纯文字列表
# （羊皮纸底、字号跟着布局缩放），塞气泡进去会和周围完全不搭。
# 那行字仍由 RoomChatLog.line_text 出（「【全部】小林：[语音 12″]」），
# 所以名字、范围标记、回合分段三处规则只有一份。
#
# 🔴 **不自动播**（2026-10-11 定）。对局里一条 30 秒的语音自动响起来，等于把别人的声音
# 塞进一局正在打的对战；点一下才响，谁都不会被突然打断。
#
# 两个界面共用这一个：播放键的样式、停下来的字形、断开信号的时机只有一份实现。
# 按钮实例化 GloryActionButton.tscn，不写 Button.new()（V3 P1-08 棘轮）。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

const PLAY_GLYPH := "▶"
const STOP_GLYPH := "■"

var _clip_id := ""
var _media := ""
var _button: Button = null


# entry 是 RoomChatLog 的那条记录；line 是调用方自己排好版的那个 Label
# （字号 / 颜色 / 折行都归调用方 —— 大厅和摆放界面的样式本来就不一样）。
static func wrap(entry: Dictionary, line: Control, button_size: Vector2 = Vector2(38, 30)) -> Control:
	var voice: Dictionary = entry.get("voice", {})
	var row := new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	row._clip_id = str(voice.get("clip_id", ""))
	row._media = str(voice.get("media", ""))

	row._button = ACTION_BUTTON.instantiate() as Button
	row._button.text = PLAY_GLYPH
	row._button.custom_minimum_size = button_size
	row._button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row._button.pressed.connect(row._toggle)
	row.add_child(row._button)

	# 那行字本来是 MOUSE_FILTER_IGNORE（记录是只读的）；放进来不用改 ——
	# 能点的只有播放键。
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(line)
	return row


func _ready() -> void:
	if not VoiceClipService.playback_changed.is_connected(_on_playback_changed):
		VoiceClipService.playback_changed.connect(_on_playback_changed)
	_refresh()


func _exit_tree() -> void:
	# VoiceClipService 常驻，活得比记录面板久：不断开的话翻几次记录就攒一堆
	# 指向已销毁节点的连接（同 VoiceClipBubble）。
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
