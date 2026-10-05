extends PanelContainer

# 摆放界面左上角头像点开的小卡片（2026-10-06 用户要求）：看清是谁，并且可以「不看留言」「不听语音」。
#
# 屏蔽都是**只影响自己**、对方不知道：
#   留言 → NetworkService.room_chat_log.set_muted（大厅和摆放界面的聊天都从那里取，被屏蔽的人说的不显示）
#   语音 → VoiceService.set_muted（让语音桥接把这个人的音量设成 0）
# 两边都按好友码认人，换座位跟着人走；整个游戏进程内有效，重开游戏清空。
#
# 按钮一律实例化 GloryActionButton.tscn、样式走 GloryTokens：procedural_ui_ratchet 盯着
# Button.new() / StyleBoxFlat.new()，新文件从 0 开始，写一个就红。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")

const AVATAR_SIZE := 72.0
const CARD_WIDTH := 300.0

var slot := -1
var _chat_button: Button = null
var _voice_button: Button = null


# 卡片要显示的东西，全从 NetworkService 现取。门禁直接调它对账。
#   title      名字 #好友码（自己加「（我）」；没有资料的 AI 座位叫 AI）
#   can_mute   别人才能屏蔽：自己不行，没有资料的 AI 不行（没人在说话）
static func describe(p_slot: int) -> Dictionary:
	var is_self := p_slot == int(NetworkService.team_local_slot)
	var identity: Dictionary = AccountManager.profile if is_self else NetworkService.team_seat_profiles.get(
		p_slot, NetworkService.team_seat_profiles.get(str(p_slot), {}))
	var states: Array = NetworkService.team_slot_states
	var state := str(states[p_slot]) if p_slot >= 0 and p_slot < states.size() else "empty"
	var who := str(identity.get("player_name", "")).strip_edges()
	var code := str(identity.get("friend_code", "")).strip_edges()
	var title := ""
	if not who.is_empty():
		title = AccountManager.display_name(who, code)
	elif state == "dummy":
		title = "AI"
	else:
		title = _text("玩家", "Player")
	if is_self:
		title += _text("（我）", " (me)")
	return {
		"title": title,
		"is_self": is_self,
		"is_ai": state == "dummy" and who.is_empty(),
		"can_mute": not is_self and (state == "player" or not who.is_empty()),
		"avatar": str(identity.get("avatar", "")),
		"avatar_frame": str(identity.get("avatar_frame", "")),
	}


func setup(p_slot: int) -> void:
	slot = p_slot


func _ready() -> void:
	var info := describe(slot)
	# 弹窗层不在游戏主题底下（同 PrepUI 的详情面板 _detail）：不挂的话按钮是 Godot 默认的灰底，
	# 在深色卡片上几乎看不见。
	theme = Theming.get_theme()
	custom_minimum_size = Vector2(CARD_WIDTH, 0)
	add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_M))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	add_child(column)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Tokens.GAP_M)
	column.add_child(head)
	head.add_child(_avatar(str(info.avatar), str(info.avatar_frame)))

	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(names)
	var title := Label.new()
	title.name = "Title"
	title.text = str(info.title)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	names.add_child(title)
	var relation := Label.new()
	relation.text = _relation_text()
	relation.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	relation.add_theme_color_override("font_color", GameConstants.team_color_of_slot(slot))
	names.add_child(relation)

	if bool(info.can_mute):
		_chat_button = _toggle_button(_toggle_chat)
		_chat_button.name = "MuteChat"
		column.add_child(_chat_button)
		_voice_button = _toggle_button(_toggle_voice)
		_voice_button.name = "MuteVoice"
		column.add_child(_voice_button)
		_refresh_buttons()
		NetworkService.room_chat_log.mutes_changed.connect(_refresh_buttons)
		VoiceService.mutes_changed.connect(_refresh_buttons)
	elif bool(info.is_ai):
		var note := Label.new()
		note.text = _text("电脑代打，没有留言和语音", "Computer player: no chat or voice")
		note.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
		note.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
		column.add_child(note)


func _exit_tree() -> void:
	# 两个都是 autoload，活得比卡片久：连接要显式断开。
	if NetworkService.room_chat_log.mutes_changed.is_connected(_refresh_buttons):
		NetworkService.room_chat_log.mutes_changed.disconnect(_refresh_buttons)
	if VoiceService.mutes_changed.is_connected(_refresh_buttons):
		VoiceService.mutes_changed.disconnect(_refresh_buttons)


func chat_muted() -> bool:
	return NetworkService.room_chat_log.is_muted(slot, NetworkService.team_seat_profiles)


func voice_muted() -> bool:
	return VoiceService.is_muted(slot)


func _toggle_chat() -> void:
	NetworkService.room_chat_log.set_muted(slot, NetworkService.team_seat_profiles, not chat_muted())


func _toggle_voice() -> void:
	VoiceService.set_muted(slot, not voice_muted())


# 文案就是用户的说法：「不看留言」「不听语音」；屏蔽中换成「恢复…」、按钮变红。
# （试过变暗一档的 GloryGhost：在深色卡片上和平常看不出区别。）
func _refresh_buttons() -> void:
	if _chat_button != null:
		_chat_button.text = _text("恢复看留言", "Show messages") if chat_muted() else _text("不看留言", "Hide messages")
		_chat_button.theme_type_variation = Theming.VARIATION_DANGER if chat_muted() else ""
	if _voice_button != null:
		_voice_button.text = _text("恢复听语音", "Unmute voice") if voice_muted() else _text("不听语音", "Mute voice")
		_voice_button.theme_type_variation = Theming.VARIATION_DANGER if voice_muted() else ""


func _toggle_button(on_press: Callable) -> Button:
	var button := ACTION_BUTTON.instantiate() as Button
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(on_press)
	return button


func _relation_text() -> String:
	var local := int(NetworkService.team_local_slot)
	var team := _text("红队", "Red team") if GameConstants.team_of_slot(slot) == 0 else _text("蓝队", "Blue team")
	if slot == local:
		return team
	if local >= 0 and GameConstants.team_of_slot(slot) == GameConstants.team_of_slot(local):
		return team + _text(" · 队友", " · teammate")
	return team + _text(" · 对手", " · opponent")


# 和摆放界面左上角的头像同一画法：先画框，再把头像裁圆画在框里。
func _avatar(avatar: String, frame_id: String) -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame := TextureRect.new()
	frame.texture = AvatarCatalog.frame_texture_for(frame_id)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_child(frame)
	var inset := roundi(AVATAR_SIZE * 0.18)
	var mask := Panel.new()
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.offset_left = inset
	mask.offset_top = inset
	mask.offset_right = -inset
	mask.offset_bottom = -inset
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_theme_stylebox_override("panel", Tokens.flat_box(Color.WHITE, Color.WHITE, 0, roundi(AVATAR_SIZE)))
	box.add_child(mask)
	var portrait := TextureRect.new()
	portrait.texture = AvatarCatalog.texture_for(avatar)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.add_child(portrait)
	return box


static func _text(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
