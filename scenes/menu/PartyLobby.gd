extends Control

signal back_requested
signal queue_started(mode: String, host: bool)
# ★★ 10.07h 第 9(6) 条：队里**任意成员**取消了排队 → Main 要关掉「匹配中」弹窗。
# `canceller` 是取消者的昵称（无数字 ID），拿不到就是空串。
# 与 `queue_started` 配对：有开就有开，不然房主那边的面板会一直挂着。
signal queue_canceled(canceller: String)

const REF := Vector2(1672, 941)
const BG := preload("res://assets/ui/main_menu_live/background.png")
const PET_STAGE := preload("res://scenes/menu/MainMenuPet.gd")
const PARTY_VOICE := preload("res://scenes/menu/PartyVoice.gd")
# 10.10：BGM 压低（开麦时）。排位房的语音是独立 PartyVoice，靠探针接进来。
const MUSIC_SERVICE := preload("res://ui/services/MusicService.gd")
const AVATARS := preload("res://scripts/account/AvatarCatalog.gd")
const RANKS := preload("res://scenes/menu/RankedTiers.gd")
const PROFILE_DISC := preload("res://assets/ui/main_menu_live/profile_avatar.png")
const ACTION := preload("res://ui/components/GloryActionButton.tscn")
const BUTTON_PRIMARY := preload("res://assets/ui/party_lobby/party_button_primary.png")
const BUTTON_SECONDARY := preload("res://assets/ui/party_lobby/party_button_secondary.png")
const BUTTON_MODE_IDLE := preload("res://assets/ui/party_lobby/party_button_mode_idle.png")
const BUTTON_MODE_ACTIVE := preload("res://assets/ui/party_lobby/party_button_mode_active.png")
const GOLD := Color("e6c984")
const CREAM := Color("f8f0d8")
const MUTED := Color("bbc5b9")
const GREEN := Color("9cdbba")
const DARK := Color("101b1c")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
# 头像上的「正在说话」小麦克风（10-08，所有用到语音的地方共用 VoiceControls 里那两个函数）。
const VoiceControls := preload("res://ui/components/VoiceControls.gd")
const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
# 与自定义房间的静音键同源（Team3v3Lobby 同一个 preload）。
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
# 「房主更换了休闲/排位模式」这类临时提示在房间里停留多久。
const NOTICE_SEC := 4.0
const SPEAKING_REFRESH_SEC := 0.2
# 在线状态推送的事件名。必须和 backend/app/presence.py 的 PRESENCE_EVENT 一致。
const PRESENCE_PUSH := "presence"
# 好友列表的兜底轮询。
#
# 🔴 **推送不能取代它。** 推送只覆盖「上线 / 换房间」—— 这两件事有 HTTP 请求可挂。
# **「下线」没有事件**：进程被杀、网断了，客户端不会发「我下线了」，离线是服务端
# 按 TTL 推算的。所以离线多久能显示出来，等于这个轮询周期，和另外两个好友界面
# （FriendsScreen / Team3v3Lobby）保持一致的 5 秒。
#
# 这个常量之前**根本不存在** —— 组队房只在 _ready() 里拉一次好友，谁上线都不会变。
# 而这个界面的「邀请」按钮是 `disabled = not online`，所以一个其实已经上线、却被
# 显示成离线的好友**根本邀请不了**（不是文字不好看，是这个界面的主要动作被卡住）。
const FRIENDS_REFRESH_SEC := 5.0
# 只能单人或满 3 人开始匹配（docs/排位系统设计.md；服务器 matchmaking.PARTY_SIZES 同口径）。
const STARTABLE_SIZES := [1, 3]
# 排位房展示宠物的上限（与服务端 party.MAX_PETS 一致）：房主的出战宠物必占一席。
const MAX_DISPLAY_PETS := 5
# 10-08 用户要求：**所有按键大小照自定义房间**（Team3v3Lobby）走，图案不变。
# 两个房间的设计稿都是 1672×941，尺寸一比一照搬；括号里是 Team3v3Lobby 的出处。
const BACK_SIZE := Vector2(143, 83)            # 返回（_build 里 TEX_BACK 那颗）
const ACTION_SIZE := Vector2(270, 95)          # 开始 / 准备（hit_start）
const VOICE_BTN_SIZE := Vector2(78, 60)        # 语音按钮（VOICE_BTN_SIZE）
const TOP_BTN_SIZE := Vector2(140, 62)         # 静音（MUTE_BTN_SIZE）；休闲 / 排位、宠物自定义房间没有，也按它
const PHRASE_ENTRY_SIZE := Vector2(196, 40)    # 「＋ 快捷短语」入口（CHAT_ENTRY_SPLIT × 40）
const PHRASE_PANEL_SIZE := Vector2(360, 304)   # PHRASE_PANEL_SIZE
const PHRASE_BTN_SIZE := Vector2(162, 40)      # PHRASE_BTN_SIZE，两列
const PHRASE_BTN_STEP := Vector2(170, 48)      # PHRASE_BTN_STEP
const PHRASE_BTN_FONT := 15
const KICK_BTN_SIZE := Vector2(38, 38)         # 座位上的「×」
# 席位头像框的基准盒（154×154，既有值）。只当「反推内孔」的基准用 —— 框真正画多大
# 由 `_seat_hole_target()` 反推，见 `_render_seats`。
const SEAT_FRAME_SIZE := Vector2(154, 154)
const CHAT_POS := Vector2(37, 724)
const CHAT_SIZE := Vector2(430, 190)           # 聊天框宽 430（TEX_CHAT）
const CHAT_EXPANDED_H := 437.0
# 长按扬声器看语音面板（同 VoiceControls 的 700 毫秒）。
const SPEAKER_HOLD_MSEC := 700
# 「开始匹配」能按时的明暗脉动（同自定义房间的开始键，Team3v3Lobby._update_start_pulse）。
const START_BRIGHT := Color(1.22, 1.16, 1.0, 1.0)
const START_DIM := Color(0.78, 0.76, 0.70, 1.0)

var _initial_mode := "casual"
var _invite_id := ""
var _preview := ""
var _room: Dictionary = {}
var _friends: Array = []
var _friends_busy := false
# 10.10：好友列表的「内容签名」。数据没变就不重建列表 —— 否则 presence 推送 /
# 5 秒轮询会把玩家正在拖动的滚动条连同滚动位置一起重置（真机表现为「滚动条消失」）。
var _friends_sig := ""
var _local_only := true
var _load_error := ""
var _loading_room := false
var _busy := false
var _queue_opened := false
# ★★ 10.07i 第 9(6) 条：**「队伍曾经进过排队」的闩**，与 `_queue_opened` 分开。
#
# 为什么不能复用 `_queue_opened`：它在 `_apply()` 里只要 `queued=false` 就被清掉
# （见 `_apply` 末尾），而取消排队的推送**顺序**是
#   `party` 快照（queued=false，`_apply` 顺手清了 `_queue_opened`）
#   → `match idle`（真正说明「有人取消」的那条）
# 于是等 `match idle` 到达时判据已经全被抹平 ⇒ 房主面板照旧挂着「匹配中」。
#
# 这个闩**只在「收到 idle 并处理掉」或「自己离开房间」时才落**，不被
# `queued=false` 的快照影响 —— 它回答的是「这次 idle 是不是我这次排队的收尾」。
var _party_queue_active := false
var _match_found := false
# 六个人都确认了（match ready）：队伍房间随即在服务器上关掉（matchmaking._finalise），
# 而 Main 要等连上战斗服务器、进了对局大厅才收掉本界面。这几秒里本界面不能再轮询 / 复查房间 ——
# 查到「房间没了」就会退回主界面，把正在进对局的人拉出来。
var _match_ready := false
var _canvas: Control
var _stage: Control
var _seat_layer: Control
var _friend_list: VBoxContainer
var _pet_list: VBoxContainer
var _friend_rail: VBoxContainer
var _friends_drawer: Panel
var _pets_drawer: Panel
var _friends_toggle: Button
var _pet_toggle: Button
var _chat_panel: Panel
var _chat_toggle: Button
var _chat_expanded := false
var _chat_list: VBoxContainer
var _chat_scroll: ScrollContainer
var _chat_input: LineEdit
var _send_button: Button
var _mode_casual: Button
var _mode_ranked: Button
var _action: Button
var _notice: Label
# 10.07 第 9 条：房间语音改为「麦克风 + 扬声器」两个图标按钮（房间里只有队友，
# 不需要听众选择）。
var _voice_mic: Button
var _voice_speaker: Button
var _notice_timer: SceneTreeTimer
# 「房主更换了休闲/排位模式」这类提示要顶过紧随其后的房间快照重绘。
var _sticky_notice := ""
var _party_voice: Node
var _poll_elapsed := 0.0
# 10-08 对齐自定义房间补上的：语音出错原因、整局静音、快捷短语、点头像的成员卡、开始键脉动。
var _voice_status: Label
var _mute_button: Button
var _phrase_button: Button
var _phrase_panel: Panel
var _voice_backdrop: Button
var _voice_panel: Panel
var _voice_panel_status: Label
# 好友码 -> {"mic": Control, "mute": Button}（语音面板里每个队友那一行）
var _voice_panel_rows: Dictionary = {}
var _speaker_hold_started := -1
var _speaker_hold_opened := false
# 好友码 -> 座位上的头像框（挂「正在说话」小麦克风的地方）。每次重画座位都重建。
var _seat_frames: Dictionary = {}
var _start_tween: Tween


func configure(mode: String, invite_id: String = "") -> void:
	_initial_mode = mode
	_invite_id = invite_id


func configure_preview(role: String) -> void:
	_preview = role
	_initial_mode = "ranked"


func _ready() -> void:
	_build()
	# 10.10 需求：排位房开麦后 BGM 要变小（与自定义房间、对局一致）。
	# 本页语音走独立的 PartyVoice（自带 mode，不写 VoiceService.mode），所以给
	# MusicService 注册一个探针补上这条判据；出树时清掉。
	MUSIC_SERVICE.set_talk_probe(_party_voice_talking)
	get_viewport().size_changed.connect(_layout)
	_layout()
	if not RealtimeService.message_received.is_connected(_on_realtime):
		RealtimeService.message_received.connect(_on_realtime)
	if _preview != "":
		_apply(_preview_room())
		_friends = [
			{"friend_code": "KLMN2345", "player_name": "月影", "online": true},
			{"friend_code": "QWER7788", "player_name": "小木", "online": true},
			{"friend_code": "RSTU5621", "player_name": "北辰", "online": false},
		]
		_render_friends()
	else:
		if not AccountManager.profile_changed.is_connected(_on_local_profile_changed):
			AccountManager.profile_changed.connect(_on_local_profile_changed)
		if not PlayerProfile.pets_changed.is_connected(_on_local_pets_changed):
			PlayerProfile.pets_changed.connect(_on_local_pets_changed)
		_show_local_identity()
		_load_room()
		_load_friends()
		# 兜底轮询：推送只管上线 / 换房间，下线没有事件可挂（见 FRIENDS_REFRESH_SEC）。
		# 只在真实模式起 —— _preview 那条路的好友是写死的假数据，拉一次就被盖掉。
		var friends_timer := Timer.new()
		friends_timer.wait_time = FRIENDS_REFRESH_SEC
		friends_timer.autostart = true
		friends_timer.timeout.connect(_load_friends)
		add_child(friends_timer)


func _exit_tree() -> void:
	MUSIC_SERVICE.clear_talk_probe()
	if RealtimeService.message_received.is_connected(_on_realtime):
		RealtimeService.message_received.disconnect(_on_realtime)
	if AccountManager.profile_changed.is_connected(_on_local_profile_changed):
		AccountManager.profile_changed.disconnect(_on_local_profile_changed)
	if PlayerProfile.pets_changed.is_connected(_on_local_pets_changed):
		PlayerProfile.pets_changed.disconnect(_on_local_pets_changed)


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := TextureRect.new()
	bg.texture = BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var shade := ColorRect.new()
	shade.color = Color(0.025, 0.065, 0.07, 0.12)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	_stage = PET_STAGE.new() as Control
	_stage.configure_party_display([], Vector2(385, 315), Vector2(920, 355))
	add_child(_stage)
	_canvas = Control.new()
	_canvas.custom_minimum_size = REF
	_canvas.size = REF
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_canvas)

	var back := _button(_canvas, "‹  " + _text("返回", "Back"), Vector2(43, 30), BACK_SIZE)
	_style_paper_button(back, false)
	back.pressed.connect(_leave)
	_mode_casual = _button(_canvas, _text("休闲", "CASUAL"), Vector2(686, 38), TOP_BTN_SIZE)
	_mode_ranked = _button(_canvas, _text("排位", "RANKED"), Vector2(836, 38), TOP_BTN_SIZE)
	_mode_casual.pressed.connect(func() -> void: _change_mode("casual"))
	_mode_ranked.pressed.connect(func() -> void: _change_mode("ranked"))
	_pet_toggle = _button(_canvas, _text("宠物", "PETS"), Vector2(1325, 38), TOP_BTN_SIZE)
	_style_paper_button(_pet_toggle, false)
	_pet_toggle.pressed.connect(_toggle_pets_drawer)
	# 10-08：整局静音（同自定义房间右上角那颗，Team3v3Lobby._toggle_mute）。
	_mute_button = _button(_canvas, _mute_text(), Vector2(1475, 38), TOP_BTN_SIZE)
	_style_paper_button(_mute_button, false)
	_mute_button.pressed.connect(_toggle_mute)

	_chat_panel = _paper_panel(_canvas, CHAT_POS, CHAT_SIZE, 0.91)
	_label(_chat_panel, _text("队内聊天", "PARTY CHAT"), Vector2(18, 12), Vector2(150, 36), 22, Color("425331"))
	_chat_toggle = _button(_chat_panel, "⌃", Vector2(382, 10), Vector2(38, 34))
	_style_paper_button(_chat_toggle, false)
	_chat_toggle.pressed.connect(_toggle_chat)
	_chat_scroll = TouchScrollContainer.new()
	_chat_scroll.position = Vector2(17, 58)
	_chat_scroll.size = Vector2(396, 70)
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_panel.add_child(_chat_scroll)
	_chat_list = VBoxContainer.new()
	_chat_list.custom_minimum_size.x = 380
	_chat_list.add_theme_constant_override("separation", 7)
	_chat_scroll.add_child(_chat_list)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = _text("给队友发消息…", "Message your team…")
	_chat_input.position = Vector2(15, 136)
	_chat_input.size = Vector2(332, 40)
	_style_chat_input(_chat_input)
	_chat_input.text_submitted.connect(func(_t: String) -> void: _send_chat())
	_chat_panel.add_child(_chat_input)
	_send_button = _button(_chat_panel, _text("发送", "Send"), Vector2(355, 136), Vector2(60, 40))
	_style_paper_button(_send_button, true)
	_send_button.pressed.connect(_send_chat)
	# 10-08：快捷短语（同自定义房间的「＋ 快捷短语」，入口与面板尺寸照搬）。点哪句发哪句，走同一个队内聊天接口。
	_phrase_button = _button(_chat_panel, _text("＋ 快捷短语", "＋ Quick chat"), Vector2(176, 8), PHRASE_ENTRY_SIZE)
	_style_paper_button(_phrase_button, false)
	_phrase_button.pressed.connect(_toggle_phrase_panel)

	_seat_layer = Control.new()
	_seat_layer.position = Vector2(377, 179)
	_seat_layer.size = Vector2(922, 237)
	_seat_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_seat_layer)
	# 开始键下面一行，比开始键宽：长一点的提示（某某取消了排队 / 某某没接受对局）一行放得下。
	_notice = _label(_canvas, "", Vector2(566, 899), Vector2(540, 36), 18, CREAM)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action = _button(_canvas, _text("开始匹配", "START MATCH"), Vector2(701, 800), ACTION_SIZE)
	_action.pressed.connect(_act)

	_friends_toggle = _button(_canvas, _text("好友", "FRIENDS"), Vector2(1481, 166), Vector2(159, TOP_BTN_SIZE.y))
	_style_paper_button(_friends_toggle, false)
	_friends_toggle.pressed.connect(_toggle_friends_drawer)
	_friend_rail = VBoxContainer.new()
	_friend_rail.position = Vector2(1520, 248)
	_friend_rail.size = Vector2(104, 354)
	_friend_rail.add_theme_constant_override("separation", 12)
	_canvas.add_child(_friend_rail)

	_friends_drawer = _paper_panel(_canvas, Vector2(1221, 157), Vector2(419, 567), 0.97)
	_label(_friends_drawer, _text("在线好友", "FRIENDS ONLINE"), Vector2(25, 22), Vector2(280, 39), 27, Color("425331"))
	var close_friends := _button(_friends_drawer, "×", Vector2(361, 18), Vector2(37, 37))
	_style_paper_button(close_friends, false)
	close_friends.pressed.connect(_toggle_friends_drawer)
	var friends_scroll := TouchScrollContainer.new()
	friends_scroll.position = Vector2(20, 78)
	friends_scroll.size = Vector2(379, 463)
	friends_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_friends_drawer.add_child(friends_scroll)
	_friend_list = VBoxContainer.new()
	_friend_list.custom_minimum_size.x = 359
	_friend_list.add_theme_constant_override("separation", 8)
	friends_scroll.add_child(_friend_list)
	_friends_drawer.visible = false

	_pets_drawer = _paper_panel(_canvas, Vector2(1203, 123), Vector2(343, 394), 0.97)
	_label(_pets_drawer, _text("展示宠物", "DISPLAY PETS"), Vector2(21, 15), Vector2(241, 38), 25, Color("425331"))
	var close_pets := _button(_pets_drawer, "×", Vector2(286, 14), Vector2(38, 37))
	_style_paper_button(close_pets, false)
	close_pets.pressed.connect(_toggle_pets_drawer)
	var pet_scroll := TouchScrollContainer.new()
	pet_scroll.position = Vector2(18, 66)
	pet_scroll.size = Vector2(307, 305)
	pet_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_pets_drawer.add_child(pet_scroll)
	_pet_list = VBoxContainer.new()
	_pet_list.custom_minimum_size.x = 295
	_pet_list.add_theme_constant_override("separation", 8)
	pet_scroll.add_child(_pet_list)
	_pets_drawer.visible = false

	# 10.07 第 9 条：房间语音改为两个图标按钮 —— 麦克风 + 扬声器（房间里只有队友，
	# 不做听众选择）。原先是一个「语音 · 关闭/收听/开麦」循环切换的文字按钮。
	# 10-08：尺寸照自定义房间（78×60，间隔 8），放在聊天框右边。
	# 长按扬声器打开语音面板（谁在说话、单独不听某人），同自定义房间。
	_voice_mic = _icon_button(_canvas, Vector2(485, 812), VOICE_BTN_SIZE)
	_voice_mic.pressed.connect(_toggle_voice_mic)
	_voice_speaker = _icon_button(_canvas, Vector2(571, 812), VOICE_BTN_SIZE)
	_voice_speaker.pressed.connect(_toggle_voice_speaker)
	_voice_speaker.button_down.connect(func() -> void:
		_speaker_hold_started = Time.get_ticks_msec()
		_speaker_hold_opened = false)
	_voice_speaker.button_up.connect(func() -> void: _speaker_hold_started = -1)
	_party_voice = PARTY_VOICE.new()
	# ★ 10.07 第 9 条返工：状态一变就**重画图标**，不只改 tooltip。
	#   旧回调只写 tooltip ⇒ 开关状态是在 `_sync_mode() → _join()` 里改的，而 `_join()`
	#   有 `await fetch_party_voice_token()`，**图标要等这次往返回来才更新**。
	#   玩家点一下看不到任何变化、再点一下（这次 mode 又变了、恰好撞上上一次的 await 返回）
	#   才见到图标动 —— 真机反馈的「要按两下才切换」就是这么来的。
	#   这里在信号到达时立刻重画，把视觉反馈从「等网络」解耦成「即时」。
	_party_voice.state_changed.connect(func(label: String) -> void:
		if is_instance_valid(_voice_mic):
			_voice_mic.tooltip_text = label
		_refresh_voice_icons())
	add_child(_party_voice)
	_refresh_voice_icons()
	# 10-08：语音出错的原因写在两个语音按钮下面。手机上没有悬停提示，原来只写进 tooltip 等于没写。
	_voice_status = _label(_canvas, "", Vector2(485, 876), Vector2(164, 58), 13, Color("ffe0a8"))
	_voice_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_voice_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_voice_status.add_theme_color_override("font_outline_color", Color("2c1b11"))
	_voice_status.add_theme_constant_override("outline_size", 4)
	var speaking_timer := Timer.new()
	speaking_timer.wait_time = SPEAKING_REFRESH_SEC
	speaking_timer.autostart = true
	speaking_timer.timeout.connect(_refresh_speaking)
	add_child(speaking_timer)


func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	var factor := minf(viewport_size.x / REF.x, viewport_size.y / REF.y)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = (viewport_size - REF * factor) * 0.5


func _on_local_profile_changed(_profile: Dictionary) -> void:
	if _local_only:
		_show_local_identity()


func _on_local_pets_changed() -> void:
	if _local_only:
		_show_local_identity()


func _show_local_identity() -> void:
	var profile: Dictionary = AccountManager.profile
	var code := str(profile.get("friend_code", ""))
	var name := str(profile.get("player_name", AccountManager.player_name))
	if name.is_empty():
		name = _text("我", "Me")
	var selected: Array = []
	for pet_id in PlayerProfile.owned_pets:
		if selected.size() >= 5:
			break
		selected.append(pet_id)
	_room = {"state": "room", "mode": _initial_mode, "host_code": code,
		"members": [{"friend_code": code, "player_name": name,
			"avatar": str(profile.get("avatar", AVATARS.default_avatar())),
			"avatar_frame": str(profile.get("avatar_frame", AVATARS.default_frame())),
			"tier": -1, "host": true, "ready": true}],
		"pets": with_host_pet(selected, str(PlayerProfile.active_pet)),
		"host_pet": str(PlayerProfile.active_pet),
		"messages": [], "queued": false}
	_render_seats()
	_render_pets()
	_stage.configure_party_display(_display_pet_ids(), Vector2(385, 315), Vector2(920, 355),
		_audible_pet())
	_mode_casual.disabled = true
	_mode_ranked.disabled = true
	_style_mode(_mode_casual, _initial_mode == "casual")
	_style_mode(_mode_ranked, _initial_mode == "ranked")
	_pet_toggle.visible = false
	_pets_drawer.visible = false
	_chat_input.editable = false
	_chat_input.placeholder_text = _text("队伍服务未连接", "Party service unavailable")
	_send_button.disabled = true
	_phrase_button.disabled = true
	if _voice_mic != null:
		_voice_mic.disabled = true
	if _voice_speaker != null:
		_voice_speaker.disabled = true
	_action.text = _text("开始匹配", "START MATCH")
	_action.disabled = true
	_style_action()
	_notice.text = _load_error if not _load_error.is_empty() else _text("正在连接队伍…", "Connecting to party…")


func _apply(next: Dictionary) -> void:
	if str(next.get("state", "")) != "room":
		return
	_local_only = false
	_load_error = ""
	_room = next
	_chat_input.editable = true
	_chat_input.placeholder_text = _text("给队友发消息…", "Message your team…")
	_send_button.disabled = false
	_phrase_button.disabled = false
	if _voice_speaker != null:
		_voice_speaker.disabled = _local_only
	_refresh_voice_icons()
	var host := _is_host()
	var mode := str(_room.get("mode", _initial_mode))
	_pet_toggle.visible = host and not bool(_room.get("queued", false))
	if not _pet_toggle.visible:
		_pets_drawer.visible = false
	_mode_casual.disabled = not host or bool(_room.get("queued", false))
	_mode_ranked.disabled = not host or bool(_room.get("queued", false))
	_style_mode(_mode_casual, mode == "casual")
	_style_mode(_mode_ranked, mode == "ranked")
	_render_seats()
	_render_chat()
	_render_pets()
	_stage.configure_party_display(_display_pet_ids(), Vector2(385, 315), Vector2(920, 355),
		_audible_pet())
	if _preview == "":
		_party_voice.configure(_room)
	var members: Array = _room.get("members", [])
	if host:
		var all_ready := true
		for raw in members:
			var entry: Dictionary = raw
			if not bool(entry.get("host", false)) and not bool(entry.get("ready", false)):
				all_ready = false
		# 只能单人或满 3 人开始（2 人车队不排，见 STARTABLE_SIZES）。先说人数，再说准备。
		var size_ok := STARTABLE_SIZES.has(members.size())
		_action.text = _text("开始匹配", "START MATCH")
		_action.disabled = not size_ok or not all_ready or bool(_room.get("queued", false))
		if not size_ok:
			_notice.text = _text("只能单人或满 3 人开始匹配", "Solo or a full team of 3 only")
		else:
			_notice.text = _text("等待队友准备", "Waiting for team") if not all_ready else ""
	else:
		var mine := _my_member()
		var ready := bool(mine.get("ready", false))
		_action.text = _text("取消准备" if ready else "准备", "CANCEL READY" if ready else "READY")
		_action.disabled = bool(_room.get("queued", false))
		_notice.text = _text("等待房主开始", "Waiting for host") if ready else ""
	if bool(_room.get("queued", false)) and not _queue_opened and _preview == "":
		_queue_opened = true
		# ★★ 10.07i 第 9(6) 条：进队那一刻把闩立上。它**不随 queued=false 落**，
		#    必须活到 `match idle` 到达，否则取消提示又会被顺序问题吃掉。
		_party_queue_active = true
		queue_started.emit(mode, host)
	elif not bool(_room.get("queued", false)):
		# 注意：这里只清 `_queue_opened`，**不动** `_party_queue_active` ——
		# 那一位的语义是「我这次排队还没收尾」，收尾在 `match idle` 那一段。
		_queue_opened = false
	if _sticky_notice != "":
		_notice.text = _sticky_notice
	_style_action()
	_update_start_pulse(host and not _action.disabled)
	# 语音面板开着时队伍成员变了（有人进出、被踢）：按新名单重建。
	if _voice_panel != null:
		_open_voice_panel()


# 席位头像框的**目标内孔直径** = 盘盒 × 默认圆盘的内孔占比。
#
# ★ 口径与 `MainMenu._profile_hole_target()` / `Team3v3Lobby._slot_hole_target()`
#   完全一致：内孔取「默认圆盘那一档」，**不是**头像直径本身。
#   内孔必须 **≤ 头像**（这里 154×0.6271 ≈ 96.6 < 100）：框画在头像**下面**，
#   内孔一旦大过头像，头像外面就会露出一圈背景缝。这条由门禁
#   `seat_frame_check` 的 `party_hole_not_larger_than_avatar` 锁住。
# ★ 不写死数字：素材换图或 FRAME_HOLE_FRAC 被改错时，这里跟着默认圆盘一起走。
static func _seat_hole_target() -> float:
	return SEAT_FRAME_SIZE.x * AVATARS.default_disc_hole_fraction()


func _render_seats() -> void:
	_clear_children(_seat_layer)
	_seat_frames.clear()
	var members: Array = _room.get("members", [])
	var by_seat := _members_by_seat(members)
	for i in range(3):
		var x := float(i) * 313.0
		var seat := Control.new()
		seat.position = Vector2(x, 0)
		seat.size = Vector2(214, 231)
		seat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_seat_layer.add_child(seat)
		if not by_seat.has(i):
			# 10-08 用户定：**点空位 = 换到这个位置**（同自定义房间），邀请只在好友列表里。
			# 选的位置会带进对局（服务器 party.move_seat → matchmaking.allocate_seats → 名片 seat）。
			# 排队中不能换：队伍已经锁定，服务器也会拒。
			var add := _button(seat, "", Vector2(37, 12), Vector2(140, 140))
			_style_empty_seat(add)
			add.disabled = _local_only or bool(_room.get("queued", false))
			add.pressed.connect(_move_to_seat.bind(i))
			var empty_text := _text("空位", "OPEN SEAT") if add.disabled else \
				_text("点击换到这里", "TAP TO MOVE HERE")
			var empty_name := _label(seat, empty_text,
				Vector2(0, 169), Vector2(214, 34), 21, CREAM)
			empty_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			continue
		var member: Dictionary = by_seat[i]
		var frame := TextureRect.new()
		frame.texture = AVATARS.frame_texture_for(str(member.get("avatar_frame", "")))
		if frame.texture == null:
			frame.texture = PROFILE_DISC
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seat.add_child(frame)
		var mask := Panel.new()
		mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
		mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var circle := StyleBoxFlat.new()
		circle.bg_color = Color.WHITE
		circle.set_corner_radius_all(55)
		mask.add_theme_stylebox_override("panel", circle)
		seat.add_child(mask)
		mask.position = Vector2(57, 27)
		mask.size = Vector2(100, 100)
		# 10.10：头像框按「内孔对头像圆」定位（与自定义房间同一套 catalog 几何）。
		# 原来是固定 154×154 + KEEP_ASPECT，框的内孔与头像圆对不齐，真机上看起来
		# 「框只露出一半」。改为：以头像圆心为锚、按框自身的内孔比例反推绘制尺寸与
		# 落点（frame_drawn_size / frame_box_origin），孔位对齐后框就完整了。
		#
		# ★★ 10.10 返工：上一版**没归一化 id**，等于没生效 —— `avatar_frame` 存的是
		#    `preset:<id>`，而 `frame_drawn_size` / `frame_box_origin` 要的是裸 id。
		#    传原始值时 `frame_source_size()` 读不到素材、`FRAME_HOLE_FRAC` 也查不到，
		#    直接返回 (0,0)，静默掉进下面的 else 分支、退回旧的固定 154 盒 ——
		#    真机上框依旧只露一半（用户第二次反馈）。必须先 `id_from_value()`。
		var frame_value := str(member.get("avatar_frame", ""))
		var frame_id := AVATARS.id_from_value(frame_value)
		if frame_id.is_empty():
			# 认不出来的值（空串 / 以后的 upload:）当默认框画 —— 与上面
			# `frame_texture_for()` 的回退同一个口径，免得「图是默认框、几何是别的」。
			frame_id = AVATARS.id_from_value(AVATARS.default_frame())
		var disc_center := mask.position + mask.size * 0.5
		var hole := _seat_hole_target()
		var frame_drawn := AVATARS.frame_drawn_size(frame_id, hole)
		if frame_drawn.x > 0.0:
			frame.size = frame_drawn
			frame.position = AVATARS.frame_box_origin(frame_id, hole, disc_center)
		else:
			frame.size = SEAT_FRAME_SIZE
			frame.position = disc_center - frame.size * 0.5
		var portrait := TextureRect.new()
		portrait.texture = AVATARS.texture_for(str(member.get("avatar", "")), true)
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		mask.add_child(portrait)
		portrait.position = Vector2.ZERO
		portrait.size = mask.size
		var name := str(member.get("player_name", ""))
		var code := str(member.get("friend_code", ""))
		# 10-08：正在说话的人头像上挂小麦克风；点别人的头像看资料（同自定义房间）。
		VoiceControls.attach_speaking_mic(frame, 0.3)
		_seat_frames[code] = frame
		var others_seat := not _local_only and code != _my_code()
		if others_seat:
			var tap := _button(seat, "", frame.position, frame.size)
			tap.flat = true
			tap.focus_mode = Control.FOCUS_NONE
			tap.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			tap.tooltip_text = _text("查看资料", "View profile")
			tap.pressed.connect(_view_member_profile.bind(code))
		var name_label := _label(seat, AccountManager.display_name(name, code, false),
			Vector2(0, 163), Vector2(214, 35), 23, CREAM)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var rank_text := _text("段位加载中", "Rank loading") if _local_only else \
			RANKS.name_of(int(member.get("tier", -1)), _is_en())
		var rank_label := _label(seat, rank_text,
			Vector2(0, 198), Vector2(214, 29), 19, GOLD)
		rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var state := _text("房主", "HOST") if bool(member.get("host", false)) else \
			(_text("已准备", "READY") if bool(member.get("ready", false)) else _text("未准备", "WAITING"))
		var badge := _paper_panel(seat, Vector2(134, 110), Vector2(83, 33), 0.92)
		var badge_label := _label(badge, state, Vector2.ZERO, badge.size, 16,
			Color("5e512f") if bool(member.get("host", false)) else (Color("366a4d") if bool(member.get("ready", false)) else Color("6b6b60")))
		badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# 房主在队友的位置上有「×」= 移出队伍（同自定义房间座位上的 ×，点了直接踢）。
		# 排队中队伍已锁定，不给踢。最后加，盖在头像点击区上面。
		if others_seat and _is_host() and not bool(_room.get("queued", false)):
			var kick := _button(seat, "×", Vector2(150, 4), KICK_BTN_SIZE)
			_style_compact_button(kick, false)
			kick.tooltip_text = _text("移出队伍", "Remove from party")
			kick.pressed.connect(_kick_member.bind(code))


func _render_friends() -> void:
	var room_count := (_room.get("members", []) as Array).size()
	var online_count := 0
	for raw in _friends:
		var friend: Dictionary = raw
		if bool(friend.get("online", false)):
			online_count += 1
	_friends_toggle.text = _text("好友  %d 在线" % online_count, "FRIENDS  %d" % online_count)
	# ★★ 10.10 修「拖动时滚动条消失」：数据没变就**不重建**。原来 presence 推送与
	# 5 秒轮询都无条件 _clear_children + 重设尺寸，玩家正往下拖时列表整个被换掉，
	# 滚动位置被 clamp、滚动条随内容高度瞬时归零 —— 看起来就是「滚动条突然没了」。
	var sig := _friends_signature(room_count)
	if sig == _friends_sig and _friend_list.get_child_count() > 0:
		return
	_friends_sig = sig
	_clear_children(_friend_list)
	_clear_children(_friend_rail)
	var drawer_height := minf(567.0, maxf(180.0, 103.0 + float(_friends.size()) * 90.0))
	_friends_drawer.custom_minimum_size.y = drawer_height
	_friends_drawer.size.y = drawer_height
	(_friend_list.get_parent() as ScrollContainer).size.y = drawer_height - 101.0
	var quick_count := 0
	for online_pass in [true, false]:
		for raw in _friends:
			var friend: Dictionary = raw
			var online := bool(friend.get("online", false))
			if online != online_pass:
				continue
			var row := _paper_panel(_friend_list, Vector2.ZERO, Vector2(359, 82), 0.75)
			row.custom_minimum_size = Vector2(359, 82)
			var code := str(friend.get("friend_code", ""))
			# 10-08：点好友这一行就是邀请（同自定义房间的好友列表）；空位不再弹邀请。
			var row_tap := _button(row, "", Vector2.ZERO, Vector2(359, 82))
			row_tap.flat = true
			row_tap.focus_mode = Control.FOCUS_NONE
			row_tap.disabled = _local_only or not online or room_count >= 3
			row_tap.pressed.connect(func() -> void: _invite(code))
			var avatar := _friend_avatar(row, friend, Vector2(8, 7), 67)
			avatar.disabled = _local_only or not online or room_count >= 3
			avatar.pressed.connect(func() -> void: _invite(code))
			var name := _label(row, str(friend.get("player_name", "")), Vector2(85, 13), Vector2(152, 31), 21,
				Color("31412e") if online else Color("8b8d7b"))
			name.clip_text = true
			_label(row, _text("在线", "Online") if online else _text("离线", "Offline"),
				Vector2(85, 46), Vector2(140, 24), 16, Color("438663") if online else Color("8b8d7b"))
			var invite := _button(row, _text("邀请", "Invite"), Vector2(254, 20), Vector2(87, 42))
			_style_paper_button(invite, true)
			invite.disabled = _local_only or not online or room_count >= 3
			invite.pressed.connect(func() -> void: _invite(code))
			if online and quick_count < 3:
				var quick := _friend_avatar(_friend_rail, friend, Vector2.ZERO, 72)
				quick.disabled = _local_only or room_count >= 3
				quick.pressed.connect(func() -> void: _invite(code))
				quick_count += 1
	if _friends.is_empty():
		_label(_friend_list, _text("暂无好友", "No friends yet"), Vector2(18, 16), Vector2(312, 36), 19, Color("657057"))
	elif online_count == 0:
		_label(_friend_rail, _text("暂无在线好友", "No one online"), Vector2.ZERO, Vector2(105, 50), 16, CREAM)


# 好友列表的内容签名：把参与渲染的字段按顺序拼起来（含房间人数与本地预览开关，
# 它们决定邀请按钮是否禁用）。签名不变 ⇒ 重建结果完全一致 ⇒ 跳过重建。
func _friends_signature(room_count: int) -> String:
	var parts := PackedStringArray()
	parts.append("room=%d" % room_count)
	parts.append("preview=%s" % _preview)
	parts.append("local=%s" % str(_local_only))
	for raw in _friends:
		var f: Dictionary = raw
		parts.append("%s|%s|%s|%s" % [
			str(f.get("friend_code", "")), str(f.get("online", false)),
			str(f.get("player_name", "")), str(f.get("avatar", ""))])
	return ";;".join(parts)


func _render_pets() -> void:
	_clear_children(_pet_list)
	var selected: Array = _room.get("pets", [])
	var owned: Array = PlayerProfile.owned_pets
	if _preview != "":
		owned = ["pet_cat", "pet_rabbit", "pet_mushroom"]
	var host_pet := _host_pet()
	for raw in owned:
		var pet_id := str(raw)
		# 10.09：房主的出战宠物必须展示 —— 始终打勾、勾选锁死（点不动）、走暗色
		# （复用 Button 的 disabled 样式）。其余行照旧可勾可选。
		var locked := pet_row_locked(pet_id, host_pet)
		var checked := selected.has(pet_id) or locked
		var choice := ACTION.instantiate() as Button
		choice.text = ("✓  " if checked else "○  ") + _pet_name(pet_id)
		choice.custom_minimum_size = Vector2(295, 50)
		_style_paper_button(choice, checked)
		choice.disabled = locked or _local_only or not _is_host() or bool(_room.get("queued", false))
		if not locked:
			choice.pressed.connect(func() -> void: _toggle_pet(pet_id))
		_pet_list.add_child(choice)
	if owned.is_empty():
		var hint := Label.new()
		hint.text = _text("当前没有可展示的宠物", "No pets to display")
		hint.add_theme_color_override("font_color", Color("657057"))
		_pet_list.add_child(hint)
	_render_friends()


func _render_chat() -> void:
	_clear_children(_chat_list)
	var messages: Array = _room.get("messages", [])
	var first := 0 if _chat_expanded else maxi(0, messages.size() - 1)
	for index in range(first, messages.size()):
		var raw: Variant = messages[index]
		var message: Dictionary = raw
		var label := Label.new()
		label.text = "%s：%s" % [str(message.get("name", "")), str(message.get("text", ""))]
		label.custom_minimum_size.x = 380
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", Color("405039"))
		label.add_theme_font_size_override("font_size", 18)
		_chat_list.add_child(label)
	call_deferred("_scroll_chat_bottom")


func _scroll_chat_bottom() -> void:
	if is_instance_valid(_chat_scroll):
		_chat_scroll.scroll_vertical = int(_chat_scroll.get_v_scroll_bar().max_value)


func _load_room() -> void:
	if _loading_room:
		return
	_loading_room = true
	var result: Dictionary
	var invite_error := ""
	if _invite_id != "":
		result = await AccountManager.join_party(_invite_id)
		var join_code := int(result.get("code", 0))
		if join_code != 200 and join_code != 0:
			# 10-08：邀请过期 / 队伍满了 / 已经开始匹配 —— 说明原因，然后照常进自己的队伍。
			# 原来会一直拿这个进不去的邀请每 30 秒重试，玩家停在一个什么都点不了的房间里。
			# （code 0 是网络没通，那时邀请可能还有效，留着下次再试。）
			invite_error = str(result.get("error", _text("组队邀请已失效", "Invitation expired")))
			_invite_id = ""
			result = await _fetch_or_create_party()
	else:
		result = await _fetch_or_create_party()
	_loading_room = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) == 200:
		_apply((result.get("body", {}) as Dictionary).get("state", {}))
		if invite_error != "":
			_show_sticky_notice(invite_error)
	elif _local_only:
		if int(result.get("code", 0)) == 404 and str(result.get("error", "")) == "Not Found":
			_load_error = _text("组队服务未更新（404）", "Party service unavailable (404)")
		else:
			_load_error = str(result.get("error", _text("无法进入队伍", "Unable to join party")))
		_notice.text = _load_error


# 没有邀请（或邀请进不去）时：已经在队伍里就用那个队伍，没有就建一个；
# 自己一个人的队伍模式不对就顺手改成这次进来的模式。
func _fetch_or_create_party() -> Dictionary:
	var result: Dictionary = await AccountManager.fetch_party()
	if int(result.get("code", 0)) != 200:
		return result
	var state: Dictionary = (result.get("body", {}) as Dictionary).get("state", {})
	if str(state.get("state", "")) != "room":
		return await AccountManager.create_party(_initial_mode)
	if str(state.get("mode", "")) != _initial_mode and str(state.get("host_code", "")) == _my_code() \
			and (state.get("members", []) as Array).size() == 1 and not bool(state.get("queued", false)):
		return await AccountManager.set_party_mode(_initial_mode)
	return result


func _load_friends() -> void:
	# 并发守卫：5 秒一拍的轮询 + 推送触发的立即重拉，遇上慢网会叠在一起。
	# 同 FriendsScreen._reload 的 _busy 与 Team3v3Lobby 的 _friends_loading。
	if _friends_busy:
		return
	_friends_busy = true
	var result: Dictionary = await AccountManager.fetch_friends()
	_friends_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) == 200:
		_friends = (result.get("body", {}) as Dictionary).get("friends", [])
		_render_friends()


# ★★ 10.07h 第 9(4) / 9(6) 条：收到「房主走了」「队列被撤了」这类推送时，**就地复查**
# 一次房间状态。与 `_load_room` 的区别是**它只读不写** —— 不建房、不入房、不改模式。
#
# 为什么需要它：这两条推送都只说明「服务器那边变了」，变了之后我到底还算不算在房里、
# 新快照长什么样，只有 fetch 一次才知道。原实现把「退不退房」押在**下一条别人推来的
# 快照**上：推得到就正常，推丢/推晚就停在旧界面（用户真机看到的就是这个）。
# 主动复查把这条路径变成**自证**，不再依赖别人的推送时序。
#
# `_loading_room` 仍复用：与 `_load_room` 抢同一个闸，避免两条请求同时在飞。
# ⚠️ 不复用 `_load_room` 本身 —— 那里在拿到非 room 状态时会**自动建一个新房**，
#    而这条路径恰恰是「我可能已经被踢了」，建房会把玩家又拖回一个空房间。
func _refresh_room_now() -> void:
	if _local_only or _preview != "" or _match_ready:
		return
	if _loading_room:
		return
	_loading_room = true
	var result: Dictionary = await AccountManager.fetch_party()
	_loading_room = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		return
	var state: Dictionary = (result.get("body", {}) as Dictionary).get("state", {})
	if str(state.get("state", "")) == "room":
		_apply(state)
	else:
		# 复查说「我已经不在房里了」——这一条才是真·退房依据。
		stop_party_voice()
		back_requested.emit()


func _on_realtime(payload: Dictionary) -> void:
	var kind := str(payload.get("t", ""))
	if kind == PRESENCE_PUSH:
		# 好友上线 / 换房间（backend/app/presence.py 的 _notify_watchers）。
		#
		# 推送只当**失效信号**用，不拿它里面的字段去打补丁：三个界面各写一份
		# 增量合并，就有三份会和拉回来的数据分叉的机会，而分叉的症状是
		# 「列表闪一下又变回去」。重新拉一次最简单，也不会有第二个真相。
		# 并发由 _load_friends 自己的 _friends_busy 挡（好几个好友同时上线时）。
		_load_friends()
		return
	if kind == "party":
		if str(payload.get("state", "")) == "room":
			_apply(payload)
		elif str(payload.get("state", "")) == "closed" and _preview == "":
			# ★★ 10.07h 第 9(4) 条返工（用户真机反馈「房主退出后，房间依旧解散，
			#    成员强制被返回主界面」）：**收到 closed 不等于我该退房**。
			#
			#    服务器在「房主退出但房里还有人」时，会把 `{"state":"closed"}` 推给
			#    **退出的房主本人**（他确实该退），房间本身是**保留**的、房主已交接。
			#    原实现收到 closed 就 `back_requested`，一旦这条消息因为广播口径变化
			#    或被其它路径顺带发到成员手上，成员就被无条件踢回主界面 —— 表现就是
			#    「房间解散了」。这里改成**先自证**：复查一次，真不在房里才退。
			_refresh_room_now()
	elif kind == "party_notice":
		# 10.07 第 12/13 条：房主交接、房主换模式都会推这个。
		# 房主交接那条服务器也发给退出的房主本人，他这时已经不在房间里，忽略掉；
		# 留下的成员收到的是「房主换人了」，紧接着会来一条 room 快照刷新界面。
		#
		# ★★ 10.07h 第 9(4) 条返工（用户真机反馈「房主退出后，房间依旧解散，成员
		#    强制被返回主界面」）：`host_left` 这条**不能直接丢**——
		#    它正是「房主走了但队伍还在、我升级成了房主」的信号。原样 return 会让
		#    成员在等房主端那条 `broadcast` 快照期间界面停在旧房主视图；若那条
		#    广播有任何延迟/丢失，玩家看到的就是「房主没了、房间好像散了」。
		#    现在收到 host_left 就地**主动复查一次**房间状态（见 `_refresh_room_now`），
		#    自己确认还在房里就继续待着，确认不在才退 —— 不把「退房」押在别人推得上。
		match str(payload.get("kind", "")):
			"host_left":
				_show_sticky_notice(str(payload.get("text", "")))
				_refresh_room_now()
			"kicked":
				# 10-08 房主踢人：服务器先推这条、紧接着推 party closed（那条会复查房间并退回主界面）。
				# 提示框挂在主界面上 —— 挂在本界面的话，界面一关提示框就跟着关了。
				if _preview == "":
					DialogService.info({"owner": get_parent(), "body": str(payload.get("text", ""))})
			"mode_changed":
				# 服务器的顺序是「party_notice」先到、紧跟一条「party」房间快照，
				# 而 _apply() 会按房主/队员身份重写 _notice。`_show_sticky_notice` 会把
				# 提示词记成 sticky，_apply() 收尾时补回去（见 _apply 末尾）。房主自己点的不提示。
				if _preview == "" and not _is_host():
					_show_sticky_notice(str(payload.get("text", "")))
	elif kind == "match":
		var match_state := str(payload.get("state", ""))
		if match_state == "ready":
			_match_ready = true
		elif match_state == "found":
			_match_found = true
			# 凑齐了 = 这次排队正常收尾，落闩；后面即便来一条 idle 也不算「取消」。
			_party_queue_active = false
		elif match_state == "queued":
			# ★★ 10.07i 第 9(6) 条再返工（用户真机反馈「再次修复后，反而 bug 增加了。
			#    现在点开始匹配后发现匹配中弹窗消失了」）：
			#
			#    `queued` 是**正常排队回波**，永远不是「取消」。上一版把它和 `idle`
			#    合在一个分支里、单靠 `was_queued` 判「有人取消」，而房主点开始匹配
			#    时服务器先广播 party 快照（`queued=true` → `_apply` 把 `_room.queued`
			#    置真、并发 `queue_started` 推开弹窗），**紧接着**才推这条 `match
			#    queued`。于是这条自己的回波被读成「队友取消了」→ `queue_canceled`
			#    → `ModalStack.pop` 把刚弹出的「匹配中」面板当场关掉。
			#
			#    正确判据只有一个方向：**服务器说队列没了（`idle`）才算取消**。
			#    `queued` 只表示「还在排」，这里什么都不做 —— 面板自己会轮询/推送
			#    刷新队列位置。
			#
			# 10-08：例外是「凑齐之后又回到 queued」—— 那一桌里别人没接受，我们整队被放回
			# 队列最前面（matchmaking._dissolve 不再拆队）。这次排队还没收尾，闩要重新立上，
			# 否则之后队友再取消排队，就提示不出「XX 取消了排队」。
			if _match_found:
				_match_found = false
				_party_queue_active = true
				_show_sticky_notice(_text("有人没有接受对局，已为你们重新排队", "Someone declined; your team is back in the queue"))
		elif match_state == "idle":
			# 队列被撤掉的信号就是这个（服务器 `leave_group` + `idle_message`）。
			# **不能只在 `_match_found` 时处理** —— 那个字段只有走到「凑齐确认」
			# 才会置真；普通排队中被队友取消时它还是 false，于是这条推送被整个
			# 吞掉，房主面板停在「匹配中」直到下一次 7 秒轮询才刷新。
			#
			# ★★ 10.07i 第 9(6) 条：判据**不能**用 `_room.queued` / `_queue_opened`
			#    —— 服务器 `/cancel` 的顺序是「先广播 `party`（queued=false）再推
			#    `match idle`」，等这条 idle 到达时那两个字段已被快照抹平（详见
			#    `_party_queue_active` 字段上的注释）。
			#    改用**闩**：进了队就立、处理完才落。落闩即「这次排队的收尾」。
			var was_queued := _party_queue_active
			if was_queued:
				_party_queue_active = false
				var canceller := str(payload.get("by_name", ""))
				# 提示语就地显示在房间里（玩家取消排队后正是回到这个界面）。
				# 昵称拿不到（旧版服务器 / 非组队队列）时退到不带名字的说法，
				# 不显示成「取消了排队」这种缺主语的句子。
				var tip := _text("%s 取消了排队" % canceller, "%s cancelled the queue" % canceller) \
					if canceller != "" else _text("队友取消了排队", "Your teammate cancelled the queue")
				_show_sticky_notice(tip)
				queue_canceled.emit(canceller)
				_refresh_room_now()
			if _match_found:
				# 10-08：凑齐之后被拆桌、而且我们队里有人没接受 —— 整队回到这个房间
				# （服务器不再在成桌时关房间，见 matchmaking._party_back_to_room）。
				# 原来这里直接退回主界面：队伍没了、三个人各自单排。现在复查一次房间，
				# 还在房里就留下（真不在了 _refresh_room_now 会自己退回主界面）。
				_match_found = false
				var reason := str(payload.get("reason", ""))
				var who := str(payload.get("by_name", ""))
				if reason == "declined":
					_show_sticky_notice(_text("你没有接受对局，已回到队伍", "You did not accept; back to your party"))
				elif reason == "party_declined":
					_show_sticky_notice(_text("%s 没有接受对局，已回到队伍" % who, "%s declined; back to your party" % who) if who != ""
						else _text("队友没有接受对局，已回到队伍", "A teammate declined; back to your party"))
				queue_canceled.emit(who)
				_refresh_room_now()


func _process(delta: float) -> void:
	if _preview != "" or _busy or _match_ready:
		return
	_poll_elapsed += delta
	if _poll_elapsed >= (30.0 if _local_only else 7.0):
		_poll_elapsed = 0.0
		if _local_only:
			_load_room()
			return
		var result: Dictionary = await AccountManager.fetch_party()
		if is_inside_tree() and int(result.get("code", 0)) == 200:
			var state: Dictionary = (result.get("body", {}) as Dictionary).get("state", {})
			if str(state.get("state", "")) == "room":
				_apply(state)
			elif bool(_room.get("queued", false)):
				# ★★ 10.07h 第 9(4) 条：排队中拿到「非 room」就退房，**必须先确认
				#    服务端是明确答复**（`state` 字段存在且不是 room），而不是
				#    响应体形状不对/字段缺失时的空串。空串当「不在房」会因一次
				#    脏响应把玩家踢回主界面 —— 与「房主退出被解散」是同一类误退。
				var explicit_none := str(state.get("state", "")) != ""
				if explicit_none:
					stop_party_voice()
					back_requested.emit()


func _change_mode(mode: String) -> void:
	if _local_only:
		return
	if _preview != "":
		_room["mode"] = mode
		_apply(_room)
		return
	_run(AccountManager.set_party_mode.bind(mode))


func _invite(code: String) -> void:
	if _local_only:
		return
	if _preview != "":
		_notice.text = _text("已发送邀请", "Invitation sent")
		return
	# ★★ 10.07h 第 9(2) 条返工（用户真机反馈「邀请后，聊天里没有邀请的消息」）：
	#
	# 邀请成功后，服务端会**同时落一条私聊消息**（routes/party.py 的 chat.send，
	# kind=party_invite），所以聊天里本该有这条。但它由服务端产生、**不会**主动推到
	# 邀请人这一侧 —— 邀请人只有下次打开聊天界面全量拉列表时才看得到。
	# 于是真机上就是「我邀了人，聊天里什么都没有」。
	#
	# 这里做两件事（都在**成功之后**）：
	#   ① 立刻刷新会话列表（ChatService.refresh_unread），让聊天列表/红点当帧就对；
	#   ② 在房间界面给一条 sticky 提示 —— 原来的 `_run()` 成功后会用房间快照
	#      重绘 `_notice`，把「已发送」抹掉，玩家收不到任何反馈。
	#
	# 说明：这里**不**在本地伪造一条消息塞进聊天流 —— 真正的那条由服务端落库，
	# 本地伪造会和它按 message_id 去重时打架（两条看起来一样、id 不同）。
	#
	# `_busy` 与 `_run()` 同一把闸：邀请是「发出去就别连点第二次」的动作
	# （服务端还有一道 _invite_limiter，但本地先拦住能省一次 429 提示）。
	if _busy:
		return
	_busy = true
	var result: Dictionary = await AccountManager.invite_to_party(code)
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		_notice.text = str(result.get("error", _text("邀请失败", "Invitation failed")))
		return
	_show_sticky_notice(_text("已发送邀请", "Invitation sent"))
	# 不 await：这只是刷新会话列表/红点，别让房间界面等网络。
	ChatService.refresh_unread()


func _toggle_pet(pet_id: String) -> void:
	if _local_only:
		return
	# 10.09：房主的出战宠物不能被取消展示（UI 那行已锁死，这里是第二道闸）。
	if pet_row_locked(pet_id, _host_pet()):
		return
	var chosen: Array = (_room.get("pets", []) as Array).duplicate()
	if chosen.has(pet_id):
		chosen.erase(pet_id)
	elif chosen.size() < 5:
		chosen.append(pet_id)
	else:
		_notice.text = _text("最多展示 5 只宠物", "Display up to 5 pets")
		return
	if _preview != "":
		_room["pets"] = chosen
		_apply(_room)
		return
	_run(AccountManager.set_party_pets.bind(chosen))


func _send_chat() -> void:
	if _local_only:
		return
	var message := _chat_input.text.strip_edges()
	if message.is_empty() or _busy:
		return
	_chat_input.clear()
	if _preview != "":
		var log: Array = _room.get("messages", [])
		log.append({"name": "我", "text": message})
		_room["messages"] = log
		_render_chat()
		return
	_run(AccountManager.send_party_chat.bind(message))


func _act() -> void:
	if _local_only:
		return
	if _preview != "":
		_notice.text = _text("预览模式", "Preview mode")
		return
	if _is_host():
		_run(AccountManager.start_party_match)
	else:
		_run(AccountManager.set_party_ready.bind(not bool(_my_member().get("ready", false))))


func _leave() -> void:
	# 自己退房 = 这次排队彻底结束。落闩，免得下一个房间收到一条 idle 时
	# 被算成「队友取消了排队」（那种提示会出现在一个根本没排过队的新房间里）。
	note_self_canceled_queue()
	if _preview == "" and not _local_only:
		await AccountManager.leave_party()
	back_requested.emit()


# ★★ 10.07i 第 9(6) 条：**「这一下取消是我自己按的」**。
#
# 面板按「取消排队」→ `dismissed` → `Main._on_match_queue_dismissed()` → 这里。
# 落闩之后，服务器随之推来的那条**给自己**的裸 `idle`（不带 by_name）就只是
# 队列收尾，不再被读成「队友取消了排队」——避免自己取消却提示别人取消。
# 不退房、不弹提示，只落闩。
func note_self_canceled_queue() -> void:
	_party_queue_active = false
	_queue_opened = false
	if _sticky_notice == "": 
		return
	# 连带把「队友取消了排队」这类残留提示清掉：玩家已经回到房间，提示没有意义。
	_clear_notice()


func _run(action: Callable) -> void:
	if _busy:
		return
	_busy = true
	var result: Dictionary = await action.call()
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) == 200:
		_apply((result.get("body", {}) as Dictionary).get("state", {}))
	else:
		_notice.text = str(result.get("error", _text("操作失败", "Action failed")))


func _is_host() -> bool:
	if _preview != "":
		return _preview == "host"
	return str(_room.get("host_code", "")) == str(AccountManager.profile.get("friend_code", ""))


# 10.09：房主的出战宠物（服务端快照带 host_pet）。它**必须**出现在展示列表里，
# 那行的勾选锁死（点不动 + 暗色），并且排位里只有它的脚步声能被听见。
func _host_pet() -> String:
	return host_pet_of(str(_room.get("host_pet", "")), _is_host(),
		str(PlayerProfile.active_pet))


# 排位里该发声的那只 = 房主的出战宠物。万一快照没带（旧服务端 / 房主没设置出战宠物）
# 就退回自己的出战宠物，免得整屋静音。
func _audible_pet() -> String:
	var host_pet := _host_pet()
	return host_pet if not host_pet.is_empty() else str(PlayerProfile.active_pet)


# 舞台上该展示的宠物列表：房间选中的那批，但**房主的出战宠物必须在里头**
# （旧服务端没把它塞进 room.pets 时由客户端补，规则与服务端 `_with_host_pet` 一致）。
func _display_pet_ids() -> Array:
	return with_host_pet(_room.get("pets", []), _host_pet())


# ★ 10.09 真机复测的兜底：线上后端若还没带上 host_pet（旧版本 / 未部署），
#   `_room.get("host_pet")` 是空串 ⇒ 房主那行既不锁也不暗（真机 bug）。
#   但只要「房主就是本机玩家」，他的出战宠物客户端本来就知道（PlayerProfile.active_pet），
#   所以房主这一侧照样锁得死。纯静态（入参即全部依赖）⇒ 门禁可直接喂数据驱动。
static func host_pet_of(room_host_pet: String, is_host: bool, own_active_pet: String) -> String:
	if room_host_pet != "":
		return room_host_pet
	if is_host:
		return own_active_pet
	return ""


# 10.09：某一行的勾选是否该锁死 —— 房主的出战宠物必须展示、不能取消（点不动 + 暗色）。
# 纯静态（入参即全部依赖）⇒ 门禁可以直接喂 id 驱动验证，不必实例化整个房间界面。
static func pet_row_locked(pet_id: String, host_pet: String) -> bool:
	return not host_pet.is_empty() and pet_id == host_pet


# 10.09：展示列表必须含房主的出战宠物 —— 去重、缺则挤掉末位补上、封顶 MAX_DISPLAY_PETS。
# 与服务端 `Party._with_host_pet` **同一规则**（纯静态 ⇒ 门禁可直接喂数据驱动）。
static func with_host_pet(pet_ids: Array, host_pet: String) -> Array:
	var out: Array = []
	for raw in pet_ids:
		var pet_id := str(raw)
		if pet_id != "" and not out.has(pet_id):
			out.append(pet_id)
	if host_pet != "" and not out.has(host_pet):
		out = out.slice(0, MAX_DISPLAY_PETS - 1)
		out.append(host_pet)
	return out.slice(0, MAX_DISPLAY_PETS)


# 「房主更换了休闲/排位模式」提示到时自动清掉，别一直挂在通知栏上。
# 显示一条「过几秒自动消失」的提示，并把它记成 sticky —— `_apply()` 收尾会把它
# 补回 `_notice`，不会被「按房主/队员身份重写 _notice」那一步冲掉（见 _apply 末尾）。
#
# ★ **先清后建**：旧实现只在 `_notice_timer == null` 时建计时器，于是连着来两条提示
#   （比如「房主换了模式」紧跟「队友取消了排队」）时，第二条沿用第一条剩下的时间，
#   可能刚显示就消失。这里无条件把旧的杀掉重来。
func _show_sticky_notice(text: String) -> void:
	_sticky_notice = text
	if is_instance_valid(_notice):
		_notice.text = text
	if _notice_timer != null:
		# SceneTreeTimer 不能 kill —— 断掉回调就行（它是 RefCounted，会被回收）。
		var old := _notice_timer
		if old.timeout.is_connected(_clear_notice):
			old.timeout.disconnect(_clear_notice)
	_notice_timer = get_tree().create_timer(NOTICE_SEC)
	_notice_timer.timeout.connect(_clear_notice)


func _clear_notice() -> void:
	_notice_timer = null
	_sticky_notice = ""
	if is_instance_valid(_notice):
		_notice.text = ""


func _my_member() -> Dictionary:
	if _preview != "":
		# 预览：房主视角是第一个人，队员视角是第二个人（_preview_room 那两个）。
		var members: Array = _room.get("members", [])
		var index := 1 if _preview == "guest" else 0
		return members[index] if index < members.size() else {}
	var code := str(AccountManager.profile.get("friend_code", ""))
	for raw in _room.get("members", []):
		var entry: Dictionary = raw
		if str(entry.get("friend_code", "")) == code:
			return entry
	return {}


func _preview_room() -> Dictionary:
	return {"state": "room", "id": "preview", "mode": "ranked", "host_code": "ABCD1234",
		"members": [
			{"friend_code": "ABCD1234", "player_name": "星河", "avatar": AVATARS.default_avatar(),
			 "avatar_frame": AVATARS.default_frame(), "tier": 3, "host": true, "ready": true},
			{"friend_code": "EFGH5678", "player_name": "风铃", "avatar": AVATARS.default_avatar(),
			 "avatar_frame": AVATARS.default_frame(), "tier": 2, "host": false, "ready": _preview == "host"},
		], "pets": ["pet_cat", "pet_rabbit", "pet_mushroom"], "host_pet": "pet_cat", "messages": [
			{"name": "星河", "text": "等你准备，我们就去排位。"},
			{"name": "风铃", "text": "好，宠物都在这里呢！"}], "queued": false}


func _toggle_voice_mic() -> void:
	if _local_only:
		return
	if _preview != "":
		_notice.text = _text("预览模式未连接语音", "Voice is offline in preview")
		return
	var error: String = _party_voice.set_mic_enabled(not bool(_party_voice.get("mic_enabled")))
	if not error.is_empty():
		_notice.text = error
	_refresh_voice_icons()


func _toggle_voice_speaker() -> void:
	if _speaker_hold_opened:
		# 这一下是长按（已经打开了语音面板），松手不算一次开关。
		_speaker_hold_opened = false
		return
	if _local_only:
		return
	if _preview != "":
		_notice.text = _text("预览模式未连接语音", "Voice is offline in preview")
		return
	var error: String = _party_voice.set_speaker_enabled(not bool(_party_voice.get("speaker_enabled")))
	if not error.is_empty():
		_notice.text = error
	_refresh_voice_icons()


func stop_party_voice() -> void:
	if _party_voice != null:
		_party_voice.stop()


# MusicService 的语音探针（10.10）：排位房此刻是否在通话（开麦 + 桥接已连上）。
# 与对局/自定义房间那条判据同口径 —— 都是「真的在录音才算通话」，权限没给、
# 连接失败时 PartyVoice 自己会把 mic_enabled 落回 false，这里自然就返回 false。
func _party_voice_talking() -> bool:
	if not is_instance_valid(_party_voice):
		return false
	if not bool(_party_voice.get("mic_enabled")):
		return false
	return bool(_party_voice.call("connected"))


func _my_code() -> String:
	if _preview != "":
		return str(_my_member().get("friend_code", ""))
	return str(AccountManager.profile.get("friend_code", ""))


# --- 10-08 对齐自定义房间补上的功能 -----------------------------------------------------------

# 头像上的「正在说话」小麦克风 + 语音出错的原因。0.2 秒一次（桥接状态本身 0.25 秒才变）。
func _refresh_speaking() -> void:
	if _party_voice == null:
		return
	var speaking: Array = _party_voice.speaking_codes()
	var me := _my_code()
	for code in _seat_frames:
		var talking := speaking.has(code) or (str(code) == me and bool(_party_voice.self_speaking()))
		VoiceControls.show_speaking_mic(_seat_frames[code], talking)
	if _voice_status != null:
		_voice_status.text = str(_party_voice.last_error())
	if _speaker_hold_started >= 0 and not _speaker_hold_opened \
			and Time.get_ticks_msec() - _speaker_hold_started >= SPEAKER_HOLD_MSEC:
		_speaker_hold_opened = true
		_open_voice_panel()
	_refresh_voice_panel()


# 「开始匹配」能按时明暗脉动（同自定义房间的开始键）。任何时候最多一个 tween：
# 该脉动且已经在脉动就不动（每次房间快照都会调到这里，重建会把脉动打回起点）。
func _update_start_pulse(active: bool) -> void:
	var want := active and Tokens.motion(1.0) > 0.0
	var running := _start_tween != null and _start_tween.is_valid()
	if want and running:
		return
	if running:
		_start_tween.kill()
	_start_tween = null
	_action.modulate = Color.WHITE
	if not want:
		return
	_start_tween = create_tween().set_loops()
	_start_tween.set_trans(Tween.TRANS_SINE)
	_start_tween.set_ease(Tween.EASE_IN_OUT)
	_start_tween.tween_property(_action, "modulate", START_BRIGHT, 0.9)
	_start_tween.tween_property(_action, "modulate", START_DIM, 0.9)


# 整局静音：与自定义房间那颗同一个口径（Team3v3Lobby._toggle_mute）—— 静的是游戏声音（Master 总线），
# 不是队友语音；语音走下面那两个图标。
func _is_audio_muted() -> bool:
	var master := AudioServer.get_bus_index("Master")
	if master >= 0 and AudioServer.is_bus_mute(master):
		return true
	return not Presentation.music_allowed()


func _mute_text() -> String:
	return _text("已静音", "Muted") if _is_audio_muted() else _text("静音", "Mute")


func _toggle_mute() -> void:
	var master := AudioServer.get_bus_index("Master")
	var want_mute := not _is_audio_muted()
	if master >= 0:
		AudioServer.set_bus_mute(master, want_mute)
	if not want_mute:
		PlayerProfile.set_presentation_toggle("music", true)
	_mute_button.text = _mute_text()


# 快捷短语：列在聊天框上方，点哪句发哪句（同一个队内聊天接口 —— 服务器那边就是一条普通消息）。
func _toggle_phrase_panel() -> void:
	if _phrase_panel != null:
		_close_phrase_panel()
		return
	if _local_only:
		return
	_phrase_panel = _paper_panel(_canvas,
		Vector2(_chat_panel.position.x, _chat_panel.position.y - PHRASE_PANEL_SIZE.y - 8.0), PHRASE_PANEL_SIZE, 0.97)
	_phrase_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var index := 0
	for group in ChatPhrases.GROUP_ORDER:
		for phrase_id in ChatPhrases.ids_in_group(str(group)):
			var text := ChatPhrases.text(int(phrase_id))
			var pos := Vector2(12, 12) + Vector2(PHRASE_BTN_STEP.x * float(index % 2),
				PHRASE_BTN_STEP.y * float(floori(index / 2.0)))
			var choice := _button(_phrase_panel, text, pos, PHRASE_BTN_SIZE)
			_style_paper_button(choice, false)
			choice.add_theme_font_size_override("font_size", PHRASE_BTN_FONT)
			choice.pressed.connect(_send_phrase.bind(text))
			index += 1


func _close_phrase_panel() -> void:
	if _phrase_panel != null and is_instance_valid(_phrase_panel):
		_phrase_panel.queue_free()
	_phrase_panel = null


func _send_phrase(text: String) -> void:
	_close_phrase_panel()
	if _local_only:
		return
	if _preview != "":
		var log: Array = _room.get("messages", [])
		log.append({"name": "我", "text": text})
		_room["messages"] = log
		_render_chat()
		return
	_run(AccountManager.send_party_chat.bind(text))


# 点队友的位置：看他的资料（同自定义房间 Team3v3Lobby._view_seat_profile）。
func _view_member_profile(code: String) -> void:
	if _preview != "" or code.length() != 8:
		return
	var screen := load("res://scenes/menu/ProfileScreen.tscn").instantiate() as Control
	screen.configure_public(code)
	var modal_id := "party_member_profile"
	screen.back_requested.connect(func(): ModalStack.pop(modal_id))
	ModalStack.push(screen, {"id": modal_id, "owner": self, "priority": 50, "dismiss_on_backdrop": false})


# 座位上的「×」：房主把队友移出队伍（同自定义房间，点了直接踢，不再二次确认）。
func _kick_member(code: String) -> void:
	if _preview != "":
		_notice.text = _text("预览模式", "Preview mode")
		return
	_run(AccountManager.kick_party_member.bind(code))


# 点空位：换到这个位置（同自定义房间）。选的位置会带进对局。
func _move_to_seat(seat: int) -> void:
	if _local_only or bool(_room.get("queued", false)):
		return
	SfxService.play(SfxService.CUE_ROOM_SEAT_CHANGE)
	if _preview != "":
		_my_member()["seat"] = seat
		_apply(_room)
		return
	_run(AccountManager.move_party_seat.bind(seat))


# 成员按座位号摆：{座位: 成员}。旧服务器的快照没有 seat，就按入队顺序；
# 座位号对不上（越界 / 重复）的往后挪到空位，不让任何人从画面上消失。
func _members_by_seat(members: Array) -> Dictionary:
	var out := {}
	var leftovers: Array = []
	for index in members.size():
		var entry: Dictionary = members[index]
		var seat := int(entry.get("seat", index))
		if seat < 0 or seat > 2 or out.has(seat):
			leftovers.append(entry)
		else:
			out[seat] = entry
	for entry in leftovers:
		for seat in range(3):
			if not out.has(seat):
				out[seat] = entry
				break
	return out


# --- 语音面板（长按扬声器，同自定义房间的 VoicePanel：谁在说话、单独不听某人）----------------

func _open_voice_panel() -> void:
	_close_voice_panel()
	if _local_only:
		return
	var me := _my_code()
	var others: Array = []
	for raw in _room.get("members", []):
		var entry: Dictionary = raw
		if str(entry.get("friend_code", "")) != me:
			others.append(entry)
	_voice_backdrop = _button(_canvas, "", Vector2.ZERO, REF)
	_voice_backdrop.flat = true
	_voice_backdrop.focus_mode = Control.FOCUS_NONE
	_voice_backdrop.pressed.connect(_close_voice_panel)
	var height := 124.0 + 56.0 * float(maxi(1, others.size()))
	_voice_panel = _paper_panel(_canvas, Vector2((REF.x - 380.0) * 0.5, 250), Vector2(380, height), 0.97)
	_voice_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_label(_voice_panel, _text("队伍语音", "PARTY VOICE"), Vector2(20, 14), Vector2(280, 36), 24, Color("425331"))
	var close := _button(_voice_panel, "×", Vector2(326, 14), Vector2(38, 38))
	_style_paper_button(close, false)
	close.pressed.connect(_close_voice_panel)
	_voice_panel_status = _label(_voice_panel, "", Vector2(20, 56), Vector2(340, 52), 16, Color("6f7a60"))
	_voice_panel_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_voice_panel_rows.clear()
	if others.is_empty():
		_label(_voice_panel, _text("暂时没有队友", "No teammates yet"), Vector2(20, 116), Vector2(340, 40), 19, Color("6f7a60"))
	var y := 112.0
	for entry in others:
		var code := str(entry.get("friend_code", ""))
		var name := _label(_voice_panel, AccountManager.display_name(str(entry.get("player_name", "")), code, false),
			Vector2(20, y + 6), Vector2(190, 36), 20, Color("31412e"))
		name.clip_text = true
		var mic := Control.new()
		mic.position = Vector2(214, y + 4)
		mic.size = Vector2(40, 40)
		mic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_voice_panel.add_child(mic)
		VoiceControls.attach_speaking_mic(mic, 1.0)
		var mute := _button(_voice_panel, "", Vector2(262, y + 2), Vector2(100, 44))
		_style_paper_button(mute, false)
		mute.pressed.connect(func() -> void:
			VoiceService.set_code_muted(code, not VoiceService.is_code_muted(code))
			_refresh_voice_panel())
		_voice_panel_rows[code] = {"mic": mic, "mute": mute}
		y += 56.0
	_refresh_voice_panel()


func _close_voice_panel() -> void:
	for node in [_voice_panel, _voice_backdrop]:
		if node != null and is_instance_valid(node):
			node.queue_free()
	_voice_panel = null
	_voice_backdrop = null
	_voice_panel_status = null
	_voice_panel_rows.clear()


func _refresh_voice_panel() -> void:
	if _voice_panel == null or _party_voice == null:
		return
	var speaking: Array = _party_voice.speaking_codes()
	for code in _voice_panel_rows:
		var row: Dictionary = _voice_panel_rows[code]
		VoiceControls.show_speaking_mic(row["mic"], speaking.has(code))
		var muted := VoiceService.is_code_muted(str(code))
		(row["mute"] as Button).text = _text("恢复", "Unmute") if muted else _text("不听", "Mute")
	if _voice_panel_status != null:
		_voice_panel_status.text = _voice_state_text()


func _voice_state_text() -> String:
	var error := str(_party_voice.last_error())
	if not error.is_empty():
		return error
	if int(_party_voice.get("mode")) == 0:
		return _text("语音已关闭，点扬声器打开", "Voice is off — tap the speaker to turn it on")
	if not bool(_party_voice.connected()):
		return _text("正在连接队伍语音…", "Connecting party voice…")
	if bool(_party_voice.get("mic_enabled")):
		return _text("已连接 · 麦克风开着", "Connected · mic on")
	return _text("已连接 · 只听", "Connected · listening")


func _toggle_friends_drawer() -> void:
	_pets_drawer.visible = false
	_friends_drawer.visible = not _friends_drawer.visible
	_friend_rail.visible = not _friends_drawer.visible
	_friends_toggle.visible = not _friends_drawer.visible
	# 刚点开就该是新的，不用等下一个轮询周期。原来这个函数只翻 visible ——
	# 配上「只在 _ready() 里拉一次」，抽屉里看到的就是进房那一刻的快照。
	if _friends_drawer.visible and _preview == "":
		_load_friends()


func _toggle_pets_drawer() -> void:
	_friends_drawer.visible = false
	_friend_rail.visible = true
	_friends_toggle.visible = true
	_pets_drawer.visible = not _pets_drawer.visible


func _toggle_chat() -> void:
	_chat_expanded = not _chat_expanded
	_chat_panel.position.y = CHAT_POS.y + CHAT_SIZE.y - CHAT_EXPANDED_H if _chat_expanded else CHAT_POS.y
	_chat_panel.size.y = CHAT_EXPANDED_H if _chat_expanded else CHAT_SIZE.y
	_chat_scroll.size.y = 317 if _chat_expanded else 70
	_chat_input.position.y = 383 if _chat_expanded else 136
	_chat_toggle.text = "⌄" if _chat_expanded else "⌃"
	# 只有「发送」跟着输入框走；标题栏上的「短语」「⌃」不动。
	_send_button.position.y = 383 if _chat_expanded else 136
	_close_phrase_panel()
	_render_chat()


func _paper_panel(parent: Control, pos: Vector2, dimensions: Vector2, opacity: float) -> Panel:
	var panel := Panel.new()
	panel.position = pos
	panel.size = dimensions
	panel.custom_minimum_size = dimensions
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.93, 0.90, 0.77, opacity)
	style.border_color = Color(0.83, 0.68, 0.34, 0.88)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel


func _friend_avatar(parent: Control, entry: Dictionary, pos: Vector2, diameter: int) -> Button:
	var button := Button.new()
	button.position = pos
	button.size = Vector2(diameter, diameter)
	button.custom_minimum_size = button.size
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.tooltip_text = str(entry.get("player_name", ""))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.98, 0.95, 0.83, 0.96)
	style.border_color = GOLD
	style.set_border_width_all(2)
	style.set_corner_radius_all(diameter / 2)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, style)
	parent.add_child(button)
	var mask := Panel.new()
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color.WHITE
	circle.set_corner_radius_all(diameter / 2)
	mask.add_theme_stylebox_override("panel", circle)
	button.add_child(mask)
	mask.position = Vector2(8, 8)
	mask.size = Vector2(diameter - 16, diameter - 16)
	var portrait := TextureRect.new()
	portrait.texture = AVATARS.texture_for(str(entry.get("avatar", "")), true)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(portrait)
	portrait.position = Vector2.ZERO
	portrait.size = mask.size
	var dot := Panel.new()
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = Color("4fc980") if bool(entry.get("online", false)) else Color("999b8e")
	dot_style.border_color = Color.WHITE
	dot_style.set_border_width_all(2)
	dot_style.set_corner_radius_all(10)
	dot.add_theme_stylebox_override("panel", dot_style)
	button.add_child(dot)
	dot.position = Vector2(diameter - 22, diameter - 22)
	dot.size = Vector2(17, 17)
	return button


func _style_paper_button(button: Button, selected: bool) -> void:
	if button.size.x <= 80.0:
		_style_compact_button(button, selected)
		return
	var normal := _button_plate(BUTTON_SECONDARY,
		Color(1.0, 0.97, 0.88) if selected else Color.WHITE)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("focus", normal)
	button.add_theme_stylebox_override("hover", _button_plate(BUTTON_SECONDARY,
		Color(1.12, 1.08, 0.96)))
	button.add_theme_stylebox_override("pressed", _button_plate(BUTTON_SECONDARY,
		Color(0.84, 0.82, 0.78)))
	button.add_theme_stylebox_override("hover_pressed", _button_plate(BUTTON_SECONDARY,
		Color(0.84, 0.82, 0.78)))
	button.add_theme_stylebox_override("disabled", _button_plate(BUTTON_SECONDARY,
		Color(0.66, 0.67, 0.63, 0.74)))
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", Color("fff7df"))
	button.add_theme_color_override("font_pressed_color", CREAM)
	button.add_theme_color_override("font_disabled_color", Color("d1c8ad"))
	button.add_theme_color_override("font_outline_color", Color("2c1b11"))
	button.add_theme_constant_override("outline_size", 2)
	button.add_theme_font_size_override("font_size", 18)


func _style_compact_button(button: Button, selected: bool) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("a16c30") if selected else Color("684528")
	normal.border_color = Color("e6c984")
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("b17a38")
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color("503c29")
	for state in ["normal", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover_pressed", pressed)
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", CREAM)
	button.add_theme_color_override("font_pressed_color", CREAM)
	button.add_theme_color_override("font_disabled_color", Color("c5b796"))
	button.add_theme_font_size_override("font_size", 18)


func _button_plate(texture: Texture2D, tint: Color) -> StyleBoxTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	# Crop the generated transparent padding in source-image coordinates.
	# The region scales with Godot's mobile-friendly texture import size limit.
	var source_size: Vector2
	var crop: Rect2
	if texture == BUTTON_PRIMARY:
		source_size = Vector2(1916, 821)
		crop = Rect2(26, 96, 1866, 620)
	elif texture == BUTTON_SECONDARY:
		source_size = Vector2(1944, 809)
		crop = Rect2(31, 168, 1886, 472)
	elif texture == BUTTON_MODE_IDLE:
		source_size = Vector2(2022, 778)
		crop = Rect2(27, 135, 1969, 506)
	else:
		source_size = Vector2(2023, 777)
		crop = Rect2(23, 125, 1977, 512)
	var scale: Vector2 = texture.get_size() / source_size
	atlas.region = Rect2(crop.position * scale, crop.size * scale)
	var style := StyleBoxTexture.new()
	style.texture = atlas
	style.modulate_color = tint
	return style


func _style_chat_input(input: LineEdit) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.98, 0.90, 0.86)
	style.border_color = Color("c5ad75")
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	input.add_theme_stylebox_override("normal", style)
	input.add_theme_stylebox_override("focus", style)
	input.add_theme_color_override("font_color", Color("354330"))
	input.add_theme_color_override("font_placeholder_color", Color("7c816e"))


func _style_empty_seat(button: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.96, 0.91, 0.69, 0.13)
	normal.border_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.92)
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(70)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.96, 0.91, 0.69, 0.31)
	for state in ["normal", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, normal)
	for state in ["hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, hover)
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_disabled_color", CREAM)
	button.add_theme_font_size_override("font_size", 64)


func _label(parent: Control, value: String, pos: Vector2,
		dimensions: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = pos
	label.size = dimensions
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _button(parent: Control, value: String, pos: Vector2, dimensions: Vector2) -> Button:
	var button := Button.new()
	button.text = value
	button.position = pos
	button.custom_minimum_size = dimensions
	button.size = dimensions
	parent.add_child(button)
	return button


# 圆形/圆角「图标按钮」：底图用紧凑纸牌样式，图标用 TextureRect 铺在中间。
# 图标本身 `MOUSE_FILTER_IGNORE`，点击照常落到按钮上。
func _icon_button(parent: Control, pos: Vector2, dimensions: Vector2) -> Button:
	var button := _button(parent, "", pos, dimensions)
	_style_compact_button(button, false)
	var art := TextureRect.new()
	art.name = "VoiceIcon"
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	button.add_child(art)
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.offset_left = 9
	art.offset_right = -9
	art.offset_top = 9
	art.offset_bottom = -9
	return button


func _set_voice_icon(button: Button, key: String) -> void:
	if button == null or not is_instance_valid(button):
		return
	var art := button.get_node_or_null("VoiceIcon") as TextureRect
	if art == null:
		return
	if art.get_meta("voice_icon", "") == key:
		return
	art.texture = load("res://assets/ui/voice/%s.svg" % key)
	art.set_meta("voice_icon", key)


# 麦克风/扬声器图标随状态刷新。**两个开关互相独立**（10.07 第 9 条返工）：
# 扬声器关只表示「我听不见」，不等于「我不能说」—— 所以这里**不再禁用麦克风按钮**。
# 旧实现是 `_voice_mic.disabled = _local_only or not speaker_on`，玩家必须先把扬声器
# 打开才能碰麦克风，正是真机反馈的「麦克风没法独立打开」。
func _refresh_voice_icons() -> void:
	if _party_voice == null:
		return
	var mic_on := bool(_party_voice.get("mic_enabled"))
	var speaker_on := bool(_party_voice.get("speaker_enabled"))
	_set_voice_icon(_voice_mic, "mic_on" if mic_on else "mic_off")
	_set_voice_icon(_voice_speaker, "speaker_on" if speaker_on else "speaker_off")
	if _voice_mic != null:
		_voice_mic.tooltip_text = _text("关闭麦克风" if mic_on else "打开麦克风", "Toggle microphone")
		_voice_mic.disabled = _local_only
	if _voice_speaker != null:
		_voice_speaker.tooltip_text = _text("关闭扬声器" if speaker_on else "打开扬声器", "Toggle speaker")
		_voice_speaker.disabled = _local_only


func _style_mode(button: Button, selected: bool) -> void:
	var texture: Texture2D = BUTTON_MODE_ACTIVE if selected else BUTTON_MODE_IDLE
	var normal := _button_plate(texture, Color.WHITE)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("focus", normal)
	button.add_theme_stylebox_override("hover", _button_plate(texture,
		Color(1.10, 1.08, 1.02)))
	button.add_theme_stylebox_override("pressed", _button_plate(texture,
		Color(0.87, 0.86, 0.83)))
	button.add_theme_stylebox_override("hover_pressed", _button_plate(texture,
		Color(0.87, 0.86, 0.83)))
	button.add_theme_stylebox_override("disabled", _button_plate(texture,
		Color(0.64, 0.65, 0.62, 0.72)))
	var text_color := CREAM
	button.add_theme_color_override("font_color", text_color)
	button.add_theme_color_override("font_hover_color", text_color)
	button.add_theme_color_override("font_pressed_color", text_color)
	button.add_theme_color_override("font_disabled_color", Color("d1c8ad"))
	button.add_theme_color_override("font_outline_color", Color("342010"))
	button.add_theme_constant_override("outline_size", 2)
	button.add_theme_font_size_override("font_size", 24)


func _style_action() -> void:
	var normal := _button_plate(BUTTON_PRIMARY, Color.WHITE)
	_action.add_theme_stylebox_override("normal", normal)
	_action.add_theme_stylebox_override("focus", normal)
	_action.add_theme_stylebox_override("hover", _button_plate(BUTTON_PRIMARY,
		Color(1.10, 1.08, 1.02)))
	_action.add_theme_stylebox_override("pressed", _button_plate(BUTTON_PRIMARY,
		Color(0.85, 0.83, 0.80)))
	_action.add_theme_stylebox_override("hover_pressed", _button_plate(BUTTON_PRIMARY,
		Color(0.85, 0.83, 0.80)))
	_action.add_theme_stylebox_override("disabled", _button_plate(BUTTON_PRIMARY,
		Color(0.65, 0.66, 0.63, 0.73)))
	_action.add_theme_color_override("font_color", CREAM)
	_action.add_theme_color_override("font_hover_color", Color("fff7df"))
	_action.add_theme_color_override("font_pressed_color", CREAM)
	_action.add_theme_color_override("font_disabled_color", Color("d6d0b4"))
	_action.add_theme_color_override("font_outline_color", Color("342010"))
	_action.add_theme_constant_override("outline_size", 3)
	_action.add_theme_font_size_override("font_size", 28)


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _pet_name(pet_id: String) -> String:
	# 10.10：改走 PetService.display_name（LocaleManager 的 pet_name_* 全家桶），
	# 不再只硬编码 3 只 —— 之前老虎/松鼠会露出原始 id "pet_tiger"/"pet_squirrel"。
	return PetService.display_name(pet_id)


func _is_en() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _text(zh: String, en: String) -> String:
	return en if _is_en() else zh
