extends Control

signal back_requested
signal queue_started(mode: String, host: bool)
# ★★ 10.07h 第 9(6) 条：队里**任意成员**取消了排队 → Main 要关掉「匹配中」弹窗。
# `canceller` 是取消者的昵称（无数字 ID），拿不到就是空串。
# 与 `queue_started` 配对：有开就有开，不然房主那边的面板会一直挂着。
signal queue_canceled(canceller: String)
signal tutorial_mode_selected
signal tutorial_requested

const REF := Vector2(1672, 941)
# 11.11 羊皮纸风：石台竞技场背景 + 羊皮纸部件（ui/theme/ParchmentKit.gd）。
const BG := preload("res://assets/ui/page_backgrounds/rooms_arena.png")
const Kit := preload("res://ui/theme/ParchmentKit.gd")
# 空座位：主菜单那个中间透明的头像圆环
# 11.16：空座位也用新的默认框（空心），旧的主菜单圆环不再出现。
const SEAT_RING := preload("res://assets/ui/shop/headframes/frame_default.png")
const PET_STAGE := preload("res://scenes/menu/MainMenuPet.gd")
const PARTY_VOICE := preload("res://scenes/menu/PartyVoice.gd")
# 10.10：BGM 压低（开麦时）。排位房的语音是独立 PartyVoice，靠探针接进来。
const MUSIC_SERVICE := preload("res://ui/services/MusicService.gd")
const AVATARS := preload("res://scripts/account/AvatarCatalog.gd")
const RANKS := preload("res://scenes/menu/RankedTiers.gd")
const PROFILE_DISC := preload("res://assets/ui/shop/headframes/frame_default.png")
const ACTION := preload("res://ui/components/GloryActionButton.tscn")
const BUTTON_SECONDARY := preload("res://assets/ui/party_lobby/party_button_secondary.png")
const BUTTON_MODE_IDLE := preload("res://assets/ui/party_lobby/party_button_mode_idle.png")
const BUTTON_MODE_ACTIVE := preload("res://assets/ui/party_lobby/party_button_mode_active.png")
# 11-26：聊天框、麦克风 / 听筒、开始键、好友列表的底图、位置、尺寸**照自定义房间**（Team3v3Lobby）。
# 两个房间的设计稿都是 1672×941，下面这些数和那边一个一个对着抄的 —— 改那边记得改这边
# （门禁 party_room_1126_check 会把两边的数对一遍）。
const TEX_CHAT := preload("res://assets/ui/room_parchment/chat.png")
const TEX_START := preload("res://assets/ui/room_parchment/start.png")
const TEX_FRIENDS_WIDE := preload("res://assets/ui/room_parchment/friends_wide.png")
const CHAT_NO_BADGE := preload("res://scenes/menu/chat_no_badge.gdshader")
const ChatInputBar := preload("res://ui/components/ChatInputBar.gd")
const CHAT_POS := Vector2(80, 704)             # 聊天框（TEX_CHAT）
const CHAT_SIZE := Vector2(430, 210)
const CHAT_TEXT_X := 143.0                     # 纸面内可写字的范围（避开四个卷角）
const CHAT_TEXT_W := 309.0
const CHAT_FIRST_LINE_Y := 757.0
const CHAT_LINES := 3                          # 不滚动时看得到几行
const CHAT_LINE_H := 26.0
const CHAT_ENTRY_Y := 836.0                    # 底下那一行：左「＋ 快捷短语」右「＋ 打字」
const CHAT_ENTRY_SPLIT := 154.0
const CHAT_FONT := 19
const VOICE_MIC_POS := Vector2(522, 779)       # 聊天框右缘外 12，垂直对齐聊天框中线
const VOICE_SPEAKER_POS := Vector2(608, 779)
const VOICE_STATUS_POS := Vector2(522, 843)
const ACTION_POS := Vector2(1300, 760)         # 开始匹配（TEX_START）
const ACTION_SIZE := Vector2(270, 130)
const NOTICE_POS := Vector2(1245, 668)         # 提示写在开始键正上方
const NOTICE_SIZE := Vector2(380, 88)
const FRIENDS_PANEL_POS := Vector2(1255, 180)  # 朋友列表（TEX_FRIENDS_WIDE）
const FRIENDS_PANEL_SIZE := Vector2(345, 400)
const FRIENDS_TITLE_POS := Vector2(1317, 228)
const FRIENDS_TITLE_SIZE := Vector2(220, 35)
const FRIENDS_LIST_POS := Vector2(1295, 273)
const FRIENDS_LIST_SIZE := Vector2(264, 266)
const FRIEND_ROW_H := 54.0
const FRIEND_ONLINE_COLOR := Color("2f7d45")
const FRIEND_BUSY_COLOR := Color("a0661c")
const FRIEND_OFFLINE_COLOR := Color("8c7a66")
const PARCH_SECTION := Color("8a4b12")
# 宠物走动的范围（设计稿坐标）。右边收到 1222，不走进朋友列表底下。
const PET_AREA_POS := Vector2(372, 315)
const PET_AREA_SIZE := Vector2(850, 355)
const PETS_DRAWER_POS := Vector2(1257, 104)
const PETS_DRAWER_SIZE := Vector2(343, 394)
const CHOICE_DIALOG := preload("res://scenes/menu/PartyChoiceDialog.gd")
const RacePick := preload("res://scripts/units/RacePick.gd")
const MODE_MODAL_ID := "party_lobby_mode_picker"
const RACES_MODAL_ID := "party_lobby_seedling_races"
const GOLD := Color("e6c984")
const CREAM := Color("f8f0d8")
const MUTED := Color("bbc5b9")
const GREEN := Color("9cdbba")
const DARK := Color("101b1c")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
# 11-26：好友卡片 / 私聊叠层，与自定义房间共用（ui/components/LobbyPopover.gd）。
const LobbyPopover := preload("res://ui/components/LobbyPopover.gd")
const FRIEND_CARD_MODAL_ID := "party_friend_card"
# 头像上的「正在说话」小麦克风（10-08，所有用到语音的地方共用 VoiceControls 里那两个函数）。
const VoiceControls := preload("res://ui/components/VoiceControls.gd")
const VoiceButtonArt := preload("res://ui/components/VoiceButtonArt.gd")
const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
# 10.11 第 2 条：右上角那颗键从「静音 / 已静音」改成「设定」，打开的是与主界面同一页设置
# （同自定义房间 Team3v3Lobby._open_settings）。房间这一档走 `lobby_mode`，
# 内容比**对局里**的设定少一行「退出对局」（房间还没开打，谈不上退出）。
const SettingsScreenScript := preload("res://scenes/menu/SettingsScreen.gd")
const SETTINGS_SCENE := preload("res://scenes/menu/SettingsScreen.tscn")
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
# 几个人能开始匹配，以房间快照里服务器下发的 startable_sizes 为准（10-15：开关在账号服务器
# .env 的 GLORY_PARTY_FULL_TEAM_ONLY，翻它不用出新包）。这里只是没有那个键的老服务器的口径。
const STARTABLE_SIZES := [1, 3]
# 10-08 用户要求：**所有按键大小照自定义房间**（Team3v3Lobby）走，图案不变。
# 两个房间的设计稿都是 1672×941，尺寸一比一照搬；括号里是 Team3v3Lobby 的出处。
const BACK_SIZE := Vector2(143, 83)            # 返回（_build 里 TEX_BACK 那颗）
const VOICE_BTN_SIZE := Vector2(78, 60)        # 语音按钮（VOICE_BTN_SIZE）
const TOP_BTN_SIZE := Vector2(140, 62)         # 右上角「设定」（原静音 MUTE_BTN_SIZE）；休闲 / 排位、宠物也按它
# 10.11 第 2 条：右上角「设定」推上 ModalStack 的 id。刻意与自定义房间的
# `"lobby_settings"` 分开 —— 两个房间理论上不会同时在树里，但共用同一个 id 时，
# 若其中一个被提前释放而 ModalStack 里的条目还在，另一个就会永远打不开设置页。
const LOBBY_SETTINGS_MODAL_ID := "party_lobby_settings"
const PHRASE_PANEL_W := 380.0                  # 快捷短语面板宽；高按短语行数算
const PHRASE_PANEL_TOP := 48.0                 # 标题木条以下才排按钮
const PHRASE_BTN_SIZE := Vector2(162, 40)      # PHRASE_BTN_SIZE，两列
const PHRASE_BTN_STEP := Vector2(170, 48)      # PHRASE_BTN_STEP
const PHRASE_BTN_FONT := 15
const KICK_BTN_SIZE := Vector2(38, 38)         # 座位上的「×」
# 席位头像框的基准盒（154×154，既有值）。只当「反推内孔」的基准用 —— 框真正画多大
# 由 `_seat_hole_target()` 反推，见 `_render_seats`。
const SEAT_FRAME_SIZE := Vector2(154, 154)
# 长按扬声器看语音面板（同 VoiceControls 的 700 毫秒）。
const SPEAKER_HOLD_MSEC := 700
# 「开始匹配」能按时的明暗脉动（同自定义房间的开始键，Team3v3Lobby._update_start_pulse）。
const START_BRIGHT := Color(1.22, 1.16, 1.0, 1.0)
const START_DIM := Color(0.78, 0.76, 0.70, 1.0)

var _initial_mode := "casual"
var _restore_existing_party := false
var _invite_id := ""
var _preview := ""
var _tutorial_mode_chosen := false
var _room: Dictionary = {}
var _friends: Array = []
var _friends_busy := false
# 10.10：好友列表的「内容签名」。数据没变就不重建列表 —— 否则 presence 推送 /
# 5 秒轮询会把玩家正在拖动的滚动条连同滚动位置一起重置（真机表现为「滚动条消失」）。
var _friends_sig := ""
# 好友卡片此刻对着谁（好友码，空 = 没开）、卡片上的邀请键、邀请是否正在发。
var _card_code := ""
var _card_invite_btn: Button = null
var _card_inviting := false
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
var _queue_ban_deadline := -1
var _match_found := false
# 六个人都确认了（match ready）：队伍房间随即在服务器上关掉（matchmaking._finalise），
# 而 Main 要等连上战斗服务器、进了对局大厅才收掉本界面。这几秒里本界面不能再轮询 / 复查房间 ——
# 查到「房间没了」就会退回主界面，把正在进对局的人拉出来。
var _match_ready := false
# 画面分三块，都按同一个比例缩放（设计稿 1672×941）：
#   _canvas  中间那块（模式牌、三个席位），永远居中 —— 宠物舞台也是按居中算的，两者要对得上；
#   _left    贴屏幕左边（返回、聊天框、麦克风 / 听筒），让开刘海；
#   _right   贴屏幕右边（宠物、设定、朋友列表、开始匹配），让开刘海。
# 16:9 的屏上三块正好拼成原来那一整张；更宽的屏上左右两块跟着贴边（同自定义房间）。
var _canvas: Control
var _left: Control
var _right: Control
# 盖在最上面的一层（语音面板）。
var _overlay: Control
var _layout_sig := ""
var _stage: Control
var _seat_layer: Control
var _friends_group: Control
var _friends_panel: TextureRect
var _friend_list: VBoxContainer
var _pet_list: VBoxContainer
var _pets_drawer: Panel
var _pet_toggle: Button
# 正在等服务器回「换出战宠物」：这期间整列点不动，免得连点两只。
var _pet_switching := false
var _chat_group: Control
var _chat_list: VBoxContainer
var _chat_scroll: ScrollContainer
var _chat_sig := ""
var _type_button: Button
var _mode_button: Button
var _mode_hint: Label
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
# 10-08 对齐自定义房间补上的：语音出错原因、右上角设定键、快捷短语、点头像的成员卡、开始键脉动。
var _voice_status: Label
# 10.11 第 2 条：原来是「静音 / 已静音」那颗（_mute_button），改成打开设置页的「设定」。
var _settings_button: Button
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


func configure(mode: String, invite_id: String = "", restore_existing: bool = false) -> void:
	_initial_mode = mode
	_invite_id = invite_id
	_restore_existing_party = restore_existing


func configure_preview(role: String) -> void:
	_preview = role
	_initial_mode = "ranked"


func configure_tutorial_intro() -> void:
	_preview = "tutorial"
	_initial_mode = "casual"


func tutorial_mode_target() -> Control:
	return _mode_button


func tutorial_start_target() -> Control:
	return _action


func _ready() -> void:
	_build()
	# 10.10 需求：排位房开麦后 BGM 要变小（与自定义房间、对局一致）。
	# 本页语音走独立的 PartyVoice（自带 mode，不写 VoiceService.mode），所以给
	# MusicService 注册一个探针补上这条判据；出树时清掉。
	MUSIC_SERVICE.set_talk_probe(_party_voice_talking)
	# 11.16：排位 / 匹配组队房与主菜单同一组 BGM。从主菜单进来时什么都不变（接着放）；
	# 对局结算「返回队伍」直接落到这里时，结算那首要换回主菜单这组。
	# 11.18：回到组队房 = 这局结束，下一局摆放 / 战斗音乐重新随机。
	MUSIC_SERVICE.end_match()
	MUSIC_SERVICE.play_group(MUSIC_SERVICE.MENU_GROUP, true)
	get_viewport().size_changed.connect(_layout)
	if not SafeArea.changed.is_connected(_layout):
		SafeArea.changed.connect(_layout)
	_layout()
	if not RealtimeService.message_received.is_connected(_on_realtime):
		RealtimeService.message_received.connect(_on_realtime)
	if _preview != "":
		_apply(_preview_room())
		if _preview == "tutorial":
			_action.text = _text("匹配 AI", "MATCH AI")
			_action.disabled = true
			_mode_button.disabled = false
			_notice.text = _text("点击青苗，开始第一次教学", "Choose Seedling for your first lesson")
			for control in [_friends_group, _pet_toggle, _chat_group,
					_voice_mic, _voice_speaker, _voice_status]:
				if control != null:
					control.visible = false
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
	if SafeArea.changed.is_connected(_layout):
		SafeArea.changed.disconnect(_layout)
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
	_stage.configure_party_members([], PET_AREA_POS, PET_AREA_SIZE)
	add_child(_stage)
	_canvas = _make_group("Center")
	_left = _make_group("LeftEdge")
	_right = _make_group("RightEdge")
	_overlay = _make_group("Overlay")

	var back := _button(_left, "‹  " + _text("返回", "Back"), Vector2(43, 30), BACK_SIZE)
	_style_paper_button(back, false)
	back.pressed.connect(_leave)
	_mode_button = _button(_canvas, "", Vector2(621, 27), Vector2(430, 94))
	_mode_button.pressed.connect(_open_mode_picker)
	_mode_hint = _label(_canvas, "", Vector2(563, 116), Vector2(546, 34), 19, CREAM)
	_mode_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_hint.add_theme_color_override("font_outline_color", Color("1c2b23"))
	_mode_hint.add_theme_constant_override("outline_size", 3)
	_update_mode_display(_initial_mode)
	# 11-26：「宠物」键改成**换自己的出战宠物**（原来是房主勾选「展示哪几只」），所以队员也看得到。
	_pet_toggle = _button(_right, _text("宠物", "PETS"), Vector2(1325, 38), TOP_BTN_SIZE)
	_style_paper_button(_pet_toggle, false)
	_pet_toggle.name = "PetButton"
	_pet_toggle.pressed.connect(_toggle_pets_drawer)
	# 10.11 第 2 条：右上角那颗键从「静音 / 已静音」改成「设定」（同自定义房间
	# Team3v3Lobby._build_settings_button）。位置 / 尺寸 / 纸纹样式全部照旧，只换文案与动作 ——
	# 静音没丢：设置页里的「背景音乐」就是同一个开关，还多控了音效与画质。
	_settings_button = _button(_right, _text("设定", "Settings"), Vector2(1475, 38), TOP_BTN_SIZE)
	_style_paper_button(_settings_button, false)
	_settings_button.name = "SettingsButton"
	_settings_button.pressed.connect(_open_settings)

	_build_chat()

	_seat_layer = Control.new()
	_seat_layer.position = Vector2(377, 179)
	_seat_layer.size = Vector2(922, 237)
	_seat_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_seat_layer)

	_build_friends()

	# 提示写在开始键正上方，贴着开始键往上长（最多三行）。
	_notice = _label(_right, "", NOTICE_POS, NOTICE_SIZE, 18, CREAM)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_notice.max_lines_visible = 3
	_notice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_notice.clip_text = true
	_notice.add_theme_color_override("font_outline_color", Color("1c2b23"))
	_notice.add_theme_constant_override("outline_size", 4)
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 11-26：开始键换成自定义房间那块木牌（TEX_START），位置 / 大小也照那边（右下角）。
	_action = _button(_right, _text("开始匹配", "START MATCH"), ACTION_POS, ACTION_SIZE)
	_action.name = "StartButton"
	_action.pressed.connect(_act)

	# 换出战宠物的小面板：盖在朋友列表上面，选完自己点 × 收起。
	_pets_drawer = _paper_panel(_right, PETS_DRAWER_POS, PETS_DRAWER_SIZE, 0.97)
	_pets_drawer.name = "PetsDrawer"
	# 面板要吃掉点击：它底下就是朋友列表，漏下去会点到好友。
	_pets_drawer.mouse_filter = Control.MOUSE_FILTER_STOP
	_label(_pets_drawer, _text("出战宠物", "ACTIVE PET"), Vector2(21, 15), Vector2(241, 38), 25, Color("425331"))
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
	# 11-26：位置照自定义房间 —— 聊天框外右侧，垂直对齐聊天框中线（尺寸 78×60 本来就一样）。
	# 长按扬声器打开语音面板（谁在说话、单独不听某人），同自定义房间。
	_voice_mic = _icon_button(_left, VOICE_MIC_POS, VOICE_BTN_SIZE)
	_voice_mic.pressed.connect(_toggle_voice_mic)
	_voice_speaker = _icon_button(_left, VOICE_SPEAKER_POS, VOICE_BTN_SIZE)
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
	_party_voice.state_changed.connect(func(_label: String) -> void: _refresh_voice_icons())
	add_child(_party_voice)
	_refresh_voice_icons()
	# 10-08：语音出错的原因写在两个语音按钮下面。手机上没有悬停提示，原来只写进 tooltip 等于没写。
	_voice_status = _label(_left, "", VOICE_STATUS_POS, Vector2(164, 58), 13, Color("ffe0a8"))
	_voice_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_voice_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_voice_status.add_theme_color_override("font_outline_color", Color("2c1b11"))
	_voice_status.add_theme_constant_override("outline_size", 4)
	var speaking_timer := Timer.new()
	speaking_timer.wait_time = SPEAKING_REFRESH_SEC
	speaking_timer.autostart = true
	speaking_timer.timeout.connect(_refresh_speaking)
	add_child(speaking_timer)


# 一块按设计稿（1672×941）摆东西的透明板。自己不吃点击，只有上面的控件吃。
func _make_group(group_name: String) -> Control:
	var group := Control.new()
	group.name = group_name
	group.size = REF
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(group)
	return group


# 11-26：聊天框照自定义房间 —— 同一张羊皮纸（TEX_CHAT）、同一个位置和大小；
# 消息直接写在纸面上（往上拖能翻以前的），底下一行左「＋ 快捷短语」右「＋ 打字」。
# 原来那种「框里一个输入框 + 发送键 + 展开 / 收起」拿掉了：打字改成点「＋ 打字」弹输入条
# （ChatInputBar，贴屏幕顶，手机键盘弹出来不会盖住），和自定义房间、对局里是同一个。
func _build_chat() -> void:
	_chat_group = Control.new()
	_chat_group.name = "ChatBox"
	_chat_group.size = REF
	_chat_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left.add_child(_chat_group)
	var paper := TextureRect.new()
	paper.texture = TEX_CHAT
	# 这张图左上角自带一个「聊天」角标，自定义房间用这个着色器把它抹掉，这里一样。
	var paper_material := ShaderMaterial.new()
	paper_material.shader = CHAT_NO_BADGE
	paper.material = paper_material
	paper.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	paper.stretch_mode = TextureRect.STRETCH_SCALE
	paper.position = CHAT_POS
	paper.size = CHAT_SIZE
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_group.add_child(paper)
	_chat_scroll = TouchScrollContainer.new()
	_chat_scroll.name = "ChatScroll"
	_chat_scroll.position = Vector2(CHAT_TEXT_X, CHAT_FIRST_LINE_Y)
	_chat_scroll.size = Vector2(CHAT_TEXT_W, CHAT_LINE_H * float(CHAT_LINES))
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_chat_group.add_child(_chat_scroll)
	_chat_list = VBoxContainer.new()
	_chat_list.custom_minimum_size.x = CHAT_TEXT_W
	_chat_list.add_theme_constant_override("separation", 0)
	_chat_scroll.add_child(_chat_list)
	_phrase_button = _chat_entry(_text("＋ 快捷短语", "＋ Quick chat"),
		Vector2(CHAT_TEXT_X, CHAT_ENTRY_Y), Vector2(CHAT_ENTRY_SPLIT, 40))
	_phrase_button.name = "PhraseEntry"
	_phrase_button.pressed.connect(_toggle_phrase_panel)
	_type_button = _chat_entry(_text("＋ 打字", "＋ Type"),
		Vector2(CHAT_TEXT_X + CHAT_ENTRY_SPLIT, CHAT_ENTRY_Y),
		Vector2(CHAT_TEXT_W - CHAT_ENTRY_SPLIT, 40))
	_type_button.name = "TypeEntry"
	_type_button.pressed.connect(_open_text_input)


# 聊天框底下那两个入口：没有底板，就是写在纸上的黑字（同自定义房间）。
func _chat_entry(value: String, pos: Vector2, dimensions: Vector2) -> Button:
	var entry := _button(_chat_group, value, pos, dimensions)
	var empty := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		entry.add_theme_stylebox_override(state, empty)
	entry.focus_mode = Control.FOCUS_NONE
	entry.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	entry.add_theme_font_size_override("font_size", 20)
	entry.add_theme_color_override("font_color", Tokens.CHAT_INK)
	entry.add_theme_color_override("font_hover_color", Color("5a3410"))
	entry.add_theme_color_override("font_pressed_color", Color("5a3410"))
	entry.add_theme_color_override("font_focus_color", Tokens.CHAT_INK)
	entry.add_theme_color_override("font_disabled_color", Color(Tokens.CHAT_INK, 0.4))
	return entry


func _set_chat_enabled(enabled: bool) -> void:
	_phrase_button.disabled = not enabled
	_type_button.disabled = not enabled
	if not enabled:
		_close_phrase_panel()


# 11-26：朋友列表照自定义房间 —— 一直摆在右边的那块宽羊皮纸（TEX_FRIENDS_WIDE），
# 列出全部好友（可邀请 → 对局中 → 离线），点一行弹好友卡片。
# 原来的「好友 N 在线」键 + 三个快捷头像 + 点开才出来的抽屉都拿掉了。
func _build_friends() -> void:
	_friends_group = Control.new()
	_friends_group.name = "Friends"
	_friends_group.size = REF
	_friends_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right.add_child(_friends_group)
	_friends_panel = TextureRect.new()
	_friends_panel.name = "FriendsPanel"
	_friends_panel.texture = TEX_FRIENDS_WIDE
	_friends_panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_friends_panel.stretch_mode = TextureRect.STRETCH_SCALE
	_friends_panel.position = FRIENDS_PANEL_POS
	_friends_panel.size = FRIENDS_PANEL_SIZE
	_friends_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_friends_group.add_child(_friends_panel)
	var title := _label(_friends_group, _text("朋友列表", "Friends"), FRIENDS_TITLE_POS,
		FRIENDS_TITLE_SIZE, 24, PARCH_SECTION)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var friends_scroll := TouchScrollContainer.new()
	friends_scroll.name = "FriendsScroll"
	friends_scroll.position = FRIENDS_LIST_POS
	friends_scroll.size = FRIENDS_LIST_SIZE
	friends_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_friends_group.add_child(friends_scroll)
	_friend_list = VBoxContainer.new()
	_friend_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_list.add_theme_constant_override("separation", 4)
	friends_scroll.add_child(_friend_list)


func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	# 比例和中间那块的位置按整个屏幕算（宠物舞台 MainMenuPet 也是这么算的，两边要对得上）；
	# 左右两块贴安全区的边：iPhone 横屏的灵动岛 / 圆角让出来，更宽的屏上跟着贴边。
	var factor := minf(viewport_size.x / REF.x, viewport_size.y / REF.y)
	var origin := (viewport_size - REF * factor) * 0.5
	var safe := SafeArea.rect()
	var left_x := safe.position.x
	var right_x := safe.end.x - REF.x * factor
	# 好友卡片按打开那一刻的锚点摆，画面一变就收起。
	# ⚠️ 只在**真的变了**时收：安全区信号可能重复发，无条件收的话卡片会自己消失。
	var sig := "%.4f|%.1f|%.1f|%.1f|%.1f" % [factor, origin.x, origin.y, left_x, right_x]
	if sig != _layout_sig and ModalStack.has(FRIEND_CARD_MODAL_ID):
		ModalStack.pop(FRIEND_CARD_MODAL_ID)
	_layout_sig = sig
	for group in [_canvas, _left, _right, _overlay]:
		(group as Control).scale = Vector2.ONE * factor
	_canvas.position = origin
	_overlay.position = origin
	_left.position = Vector2(left_x, origin.y)
	_right.position = Vector2(right_x, origin.y)


func _on_local_profile_changed(_profile: Dictionary) -> void:
	if _local_only:
		_show_local_identity()


# 自己的宠物数据变了（换了出战宠物、买了新的、试用到期）：面板和场上那只都跟着变。
# 场上「我的那只」直接读本机的出战宠物，不等服务器那份房间快照回来 —— 点了马上就换。
func _on_local_pets_changed() -> void:
	if _local_only:
		_show_local_identity()
		return
	_render_pets()
	_sync_stage()


func _show_local_identity() -> void:
	var profile: Dictionary = AccountManager.profile
	var code := str(profile.get("friend_code", ""))
	var name := str(profile.get("player_name", AccountManager.player_name))
	if name.is_empty():
		name = _text("我", "Me")
	_room = {"state": "room", "mode": _initial_mode, "host_code": code,
		"members": [{"friend_code": code, "player_name": name,
			"avatar": str(profile.get("avatar", AVATARS.default_avatar())),
			"avatar_frame": str(profile.get("avatar_frame", AVATARS.default_frame())),
			"tier": -1, "host": true, "ready": true,
			"pet": str(PlayerProfile.active_pet)}],
		"pets": [], "host_pet": str(PlayerProfile.active_pet),
		"messages": [], "queued": false}
	_render_seats()
	_render_pets()
	_render_friends()
	_render_chat()
	_sync_stage()
	_mode_button.disabled = true
	_update_mode_display(_initial_mode)
	# 队伍服务没连上时不让换宠物：换了队友也看不到，等连上再说。
	_pet_toggle.disabled = true
	_pets_drawer.visible = false
	_set_chat_enabled(false)
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
	_set_chat_enabled(true)
	if _voice_speaker != null:
		_voice_speaker.disabled = _local_only
	_refresh_voice_icons()
	var host := _is_host()
	var mode := str(_room.get("mode", _initial_mode))
	# 11-26：谁都能换自己的出战宠物；排队中锁住（服务器也会拒，见 routes/shop.py）——
	# 排上了就按那一刻的宠物进对局，不能让「房间里看到的」和「带进去的」对不上。
	_pet_toggle.disabled = bool(_room.get("queued", false))
	if _pet_toggle.disabled:
		_pets_drawer.visible = false
	_mode_button.disabled = not host or bool(_room.get("queued", false))
	_update_mode_display(mode)
	_render_seats()
	_render_chat()
	_render_pets()
	_render_friends()
	_sync_stage()
	if _preview == "":
		_party_voice.configure(_room)
	var members: Array = _room.get("members", [])
	if host:
		var all_ready := true
		for raw in members:
			var entry: Dictionary = raw
			if not bool(entry.get("host", false)) and not bool(entry.get("ready", false)):
				all_ready = false
		# 人数不对先说人数，再说准备（见 STARTABLE_SIZES）。
		var size_ok := _startable_sizes().has(members.size())
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
	if _queue_ban_deadline >= 0:
		_notice.text = AccountManager.queue_ban_text(_queue_ban_deadline)
	elif _sticky_notice != "":
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
		AVATARS.set_frame_texture(frame, AVATARS.frame_texture_for(str(member.get("avatar_frame", ""))))
		if frame.texture == null:
			AVATARS.set_frame_texture(frame, PROFILE_DISC)
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
		# ★ 11.16 用户要求框在头像**上面**（内圈压住头像边缘）：把框挪到头像之后。
		seat.move_child(frame, mask.get_index())
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
		AVATARS.set_avatar_texture(portrait, AVATARS.texture_for(str(member.get("avatar", "")), true))
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		mask.add_child(portrait)
		portrait.position = Vector2.ZERO
		portrait.size = mask.size
		var name := str(member.get("player_name", ""))
		var code := str(member.get("friend_code", ""))
		# 10-08：正在说话的人头像上挂小麦克风；点别人的头像看资料（同自定义房间）。
		VoiceControls.attach_speaking_mic(mask, 0.3, 18.0)
		_seat_frames[code] = mask
		var others_seat := not _local_only and code != _my_code()
		if others_seat:
			var tap := _button(seat, "", frame.position, frame.size)
			tap.flat = true
			tap.focus_mode = Control.FOCUS_NONE
			tap.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			tap.accessibility_name = _text("查看资料", "View profile")
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
			kick.accessibility_name = _text("移出队伍", "Remove from party")
			kick.pressed.connect(_kick_member.bind(code))


# 10.11 第 3 条：好友列表的三档，排序就是 可邀请(0) -> 对局中(1) -> 离线(2)。
const FRIEND_INVITABLE := 0
const FRIEND_IN_MATCH := 1
const FRIEND_OFFLINE := 2

# 只此一份判据：列表分档、按钮文案、快捷栏取谁全走它。
# 「对局中」是后端随好友列表一起返回的 in_match（database/032 / friends._in_match_visible），
# 已经替我们排掉了「不在线」和「对方关掉房间可见性」两种，所以这里只看字段本身。
func _friend_bucket(friend: Dictionary) -> int:
	if not bool(friend.get("online", false)):
		return FRIEND_OFFLINE
	return FRIEND_IN_MATCH if bool(friend.get("in_match", false)) else FRIEND_INVITABLE

func _friend_state_text(bucket: int) -> String:
	match bucket:
		FRIEND_IN_MATCH:
			return _text("对局中", "In match")
		FRIEND_OFFLINE:
			return _text("离线", "Offline")
		_:
			return _text("在线", "Online")


func _render_friends() -> void:
	var room_count := (_room.get("members", []) as Array).size()
	# ★★ 10.10 修「拖动时滚动条消失」：数据没变就**不重建**。原来 presence 推送与
	# 5 秒轮询都无条件 _clear_children + 重设尺寸，玩家正往下拖时列表整个被换掉，
	# 滚动位置被 clamp、滚动条随内容高度瞬时归零 —— 看起来就是「滚动条突然没了」。
	var sig := _friends_signature(room_count)
	if sig == _friends_sig and _friend_list.get_child_count() > 0:
		_refresh_friend_card()
		return
	_friends_sig = sig
	_clear_children(_friend_list)
	# 10.11 第 3 条：按「可邀请 → 对局中 → 离线」分档（同一档内保持服务端给的顺序）。
	# 判据只有一处（_friend_bucket）。
	for bucket in [FRIEND_INVITABLE, FRIEND_IN_MATCH, FRIEND_OFFLINE]:
		for raw in _friends:
			if not raw is Dictionary:
				continue
			var friend: Dictionary = raw
			if _friend_bucket(friend) != bucket:
				continue
			_friend_list.add_child(_friend_row(friend, bucket))
	if _friends.is_empty():
		# 10.19：空状态告诉玩家下一步。暂无站内「加好友」入口，先只写提示。
		var empty := _label(_friend_list, _text("还没有好友\n加好友后，就能在这里邀请组队",
			"No friends yet\nAdd friends to invite them here"),
			Vector2.ZERO, Vector2(FRIENDS_LIST_SIZE.x - 12.0, 110), 16, FRIEND_OFFLINE_COLOR)
		empty.custom_minimum_size = Vector2(FRIENDS_LIST_SIZE.x - 12.0, 110)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_refresh_friend_card()


# 一行好友：头像、昵称、状态字，有未读私聊时末尾一颗红点。点一下 = 弹好友卡片。
# 样子和自定义房间那一行一样（Team3v3Lobby._online_friend_row）：羊皮纸小底板，高 54。
#
# 行是 GloryActionButton 的实例。必须是按钮类：TouchScrollContainer 在手指拖动超过阈值时
# 会取消 BaseButton 的这次按压，拖着滚列表不会误弹卡片。
func _friend_row(friend: Dictionary, bucket: int) -> Button:
	var code := str(friend.get("friend_code", ""))
	var row := ACTION.instantiate() as Button
	row.name = "FriendRow_%s" % code
	row.text = ""
	row.custom_minimum_size = Vector2(0, maxf(Tokens.TOUCH_MIN, FRIEND_ROW_H))
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.focus_mode = Control.FOCUS_NONE
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.disabled = _local_only
	Kit.style_plate(row, false)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 16.0
	line.offset_right = -18.0
	var avatar := TextureRect.new()
	avatar.custom_minimum_size = Vector2.ONE * 36.0
	AVATARS.set_avatar_texture(avatar, AVATARS.texture_for(str(friend.get("avatar", AVATARS.default_avatar())), true))
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 离线的头像压暗一点：一眼分得出谁在线（颜色之外再给一层明暗，不只靠颜色表达）。
	avatar.modulate = Color(1, 1, 1, 0.55) if bucket == FRIEND_OFFLINE else Color.WHITE
	line.add_child(avatar)
	var name := Label.new()
	name.text = AccountManager.display_name(str(friend.get("player_name", "")), code, false)
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name.clip_text = true
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name.add_theme_color_override("font_color", FRIEND_OFFLINE_COLOR if bucket == FRIEND_OFFLINE else Kit.INK)
	name.add_theme_font_size_override("font_size", 17)
	name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(name)
	var status := Label.new()
	status.name = "Status"
	status.text = _friend_state_text(bucket)
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status.add_theme_color_override("font_color", _friend_state_color(bucket))
	status.add_theme_font_size_override("font_size", 14)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(status)
	if ChatService.has_unread(code):
		# 有未读私聊：行尾一颗红点（同 FriendsScreen 私聊键上的红点）。
		var unread := Label.new()
		unread.name = "UnreadDot"
		unread.text = "●"
		unread.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		unread.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
		unread.add_theme_font_size_override("font_size", 14)
		unread.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(unread)
	# ★ 11-26 与自定义房间统一：点好友这一行 = 弹好友卡片（LobbyPopover.open_friend_card），
	#   卡片上 [查看资料] [邀请] [私聊] 排在同一排。离线 / 对局中的好友卡片照样能开
	#   （看资料、私聊），只有卡片上的「邀请」按档位禁用。
	row.pressed.connect(_open_friend_card.bind(code, row))
	return row


func _friend_state_color(bucket: int) -> Color:
	match bucket:
		FRIEND_IN_MATCH:
			return FRIEND_BUSY_COLOR
		FRIEND_OFFLINE:
			return FRIEND_OFFLINE_COLOR
	return FRIEND_ONLINE_COLOR


# 好友列表的内容签名：把参与渲染的字段按顺序拼起来（含房间人数与本地预览开关，
# 它们决定邀请按钮是否禁用）。签名不变 ⇒ 重建结果完全一致 ⇒ 跳过重建。
func _friends_signature(room_count: int) -> String:
	var parts := PackedStringArray()
	parts.append("room=%d" % room_count)
	parts.append("preview=%s" % _preview)
	parts.append("local=%s" % str(_local_only))
	for raw in _friends:
		var f: Dictionary = raw
		# in_match 必须进签名（10.11 第 3 条）：它一翻，行要换档、按钮文案要换 ——
		# 漏了它就会「数据变了但列表不重建」，而 10.10 加的签名去重是**按内容**跳过的。
		# 11-26：未读私聊也进签名 —— 行尾那颗红点要跟着出 / 消。
		parts.append("%s|%s|%s|%s|%s|%s" % [
			str(f.get("friend_code", "")), str(f.get("online", false)),
			str(f.get("in_match", false)),
			str(f.get("player_name", "")), str(f.get("avatar", "")),
			str(ChatService.has_unread(str(f.get("friend_code", ""))))])
	return ";;".join(parts)


# ── 好友卡片（11-26，与自定义房间 Team3v3Lobby 同一套 LobbyPopover）──────────────
#
# 卡片长在朋友列表**左边**、与被点的那一行垂直对齐；[查看资料] [邀请] [私聊] 同一排。
# 朋友列表在 _right 里（整块按 _layout 的 factor 缩放），所以换算系数就是 _right.scale.x。
func _open_friend_card(code: String, row: Control) -> void:
	if _preview != "" or row == null or not is_instance_valid(row) or not row.is_inside_tree():
		return
	var friend := _friend_entry(code)
	if friend.is_empty():
		return
	var row_rect := row.get_global_rect()
	var left := minf(row_rect.position.x, _friends_panel.get_global_rect().position.x)
	var anchor := Rect2(Vector2(left, row_rect.position.y), Vector2(row_rect.end.x - left, row_rect.size.y))
	var bucket := _friend_bucket(friend)
	_card_code = code
	_card_invite_btn = LobbyPopover.open_friend_card(self, FRIEND_CARD_MODAL_ID, anchor, _right.scale.x,
		friend, _friend_state_text(bucket), _friend_state_color(bucket),
		_friend_invite_state(friend), {
			"profile": func() -> void: _view_member_profile(code),
			"invite": func(button: Button) -> void: _invite_from_card(code, button),
			"chat": func() -> void: LobbyPopover.open_private_chat(self, code),
		})
	if _card_invite_btn == null:
		_card_code = ""


func _friend_entry(code: String) -> Dictionary:
	for raw in _friends:
		if raw is Dictionary and str((raw as Dictionary).get("friend_code", "")) == code:
			return raw
	return {}


# 卡片上「邀请」键的字和能不能点：对局中 / 离线按 10.11 第 3 条的口径写明原因；
# 已经在队里的、队伍满了（3 人）的、本地预览的都不能点。
func _friend_invite_state(friend: Dictionary) -> Dictionary:
	match _friend_bucket(friend):
		FRIEND_IN_MATCH:
			return {"text": _text("对局中", "In match"), "enabled": false}
		FRIEND_OFFLINE:
			return {"text": _text("离线", "Offline"), "enabled": false}
	var code := str(friend.get("friend_code", ""))
	var members: Array = _room.get("members", [])
	for raw in members:
		if raw is Dictionary and str((raw as Dictionary).get("friend_code", "")) == code:
			return {"text": _text("已在队伍", "In party"), "enabled": false}
	if _card_inviting:
		return {"text": _text("发送中…", "Sending…"), "enabled": false}
	if _local_only or members.size() >= 3:
		return {"text": _text("邀请", "Invite"), "enabled": false}
	return {"text": _text("邀请", "Invite"), "enabled": true}


# 列表数据（5 秒轮询 / 上线推送）或房间人数变了，卡片还开着的话邀请键跟着变；
# 好友从列表里消失（被删）就收起卡片。
func _refresh_friend_card() -> void:
	if _card_code.is_empty():
		return
	if not ModalStack.has(FRIEND_CARD_MODAL_ID) or not is_instance_valid(_card_invite_btn):
		_card_code = ""
		_card_invite_btn = null
		return
	var friend := _friend_entry(_card_code)
	if friend.is_empty():
		ModalStack.pop(FRIEND_CARD_MODAL_ID)
		_card_code = ""
		_card_invite_btn = null
		return
	if _card_invite_btn.text == _text("已邀请", "Invited"):
		return
	var state := _friend_invite_state(friend)
	LobbyPopover.set_card_invite(_card_invite_btn, str(state.text), bool(state.enabled))


# 卡片上点「邀请」：走原来的 _invite（同一把 _busy 闸、同一条 sticky 提示），
# 成功后键改成「已邀请」，失败恢复成能点。
func _invite_from_card(code: String, button: Button) -> void:
	if _card_inviting:
		return
	_card_inviting = true
	LobbyPopover.set_card_invite(button, _text("发送中…", "Sending…"), false)
	var ok := await _invite(code)
	_card_inviting = false
	if not is_inside_tree():
		return
	if ok:
		LobbyPopover.set_card_invite(button, _text("已邀请", "Invited"), false)
	else:
		var friend := _friend_entry(code)
		var state := _friend_invite_state(friend) if not friend.is_empty() else {"text": _text("邀请", "Invite"), "enabled": false}
		LobbyPopover.set_card_invite(button, str(state.text), bool(state.enabled))


# ── 出战宠物（11-26）─────────────────────────────────────────────────────────
#
# 用户定的规则：
#   · 房间里走动的宠物 = **每个成员当前的出战宠物**，一人一只，模型脚下写玩家名字；
#   · 「宠物」键 = 直接换**自己的**出战宠物（就是背包里换出战的那个接口，换了哪儿都生效）；
#   · 排队中不能换；只听得到自己那只的脚步声。
# 原来那套「房主勾选展示哪几只（最多 5 只）、房主的出战宠物必须在里头」整个拿掉了。
func _render_pets() -> void:
	_clear_children(_pet_list)
	var owned: Array = PlayerProfile.owned_pets
	if _preview != "":
		owned = ["pet_cat", "pet_rabbit", "pet_mushroom"]
	var active := _my_pet()
	var locked := pet_switch_locked(_local_only, bool(_room.get("queued", false)), _pet_switching)
	for raw in owned:
		var pet_id := str(raw)
		var current := pet_id == active
		var choice := ACTION.instantiate() as Button
		var title := ("✓  " if current else "○  ") + _pet_name(pet_id)
		if _preview == "" and PlayerProfile.pet_trials.has(pet_id):
			title += _text("（试用）", " (trial)")
		choice.text = title
		choice.custom_minimum_size = Vector2(295, 50)
		_style_paper_button(choice, current)
		choice.disabled = locked
		if not current:
			choice.pressed.connect(_switch_pet.bind(pet_id))
		_pet_list.add_child(choice)
	if owned.is_empty():
		var hint := Label.new()
		hint.text = _text("还没有宠物", "No pets yet")
		hint.add_theme_color_override("font_color", Color("657057"))
		_pet_list.add_child(hint)


# 面板上的行什么时候点不动。纯静态（入参即全部依赖）⇒ 门禁可以直接喂数据。
static func pet_switch_locked(local_only: bool, queued: bool, switching: bool) -> bool:
	return local_only or queued or switching


# 我现在的出战宠物。真实房间里读本机那份（换了马上就对）；预览里读假房间。
func _my_pet() -> String:
	if _preview != "":
		return str(_my_member().get("pet", ""))
	return str(PlayerProfile.active_pet)


# 点面板上的一只：换成自己的出战宠物。
func _switch_pet(pet_id: String) -> void:
	if pet_switch_locked(_local_only, bool(_room.get("queued", false)), _pet_switching):
		return
	if _preview != "":
		var mine := _my_member()
		mine["pet"] = pet_id
		_apply(_room)
		return
	_pet_switching = true
	_render_pets()
	# PlayerProfile.set_active 成功后自己会发 pets_changed（_on_local_pets_changed 重画面板和场上那只）；
	# 服务器同时把新的房间快照推给全队，队友那边跟着换。
	var ok: bool = await PlayerProfile.set_active(pet_id)
	_pet_switching = false
	if not is_inside_tree():
		return
	if not ok:
		_notice.text = _text("没换成，请稍后再试", "Couldn't switch pet — try again")
	_render_pets()
	_sync_stage()


# 场上该出哪些宠物：一个成员一只。
func _stage_members() -> Array:
	var out: Array = []
	var me := _my_code()
	var own_pet := "" if _preview != "" else str(PlayerProfile.active_pet)
	var host_pet := str(_room.get("host_pet", ""))
	for raw in _room.get("members", []):
		if not raw is Dictionary:
			continue
		var member: Dictionary = raw
		var code := str(member.get("friend_code", ""))
		var mine := not me.is_empty() and code == me
		out.append({
			"key": code,
			"pet": member_pet_of(member, mine, own_pet, host_pet),
			"name": AccountManager.display_name(str(member.get("player_name", "")), code, false),
			# 只听自己那只的脚步声（用户定）：三只一起响太吵，也分不清谁是谁。
			"audible": mine,
		})
	return out


# 某个成员该出哪只宠物。纯静态（入参即全部依赖）⇒ 门禁可以直接喂数据。
#   · 是我自己：用本机的出战宠物（换了马上就对，不等服务器的快照回来）；
#   · 别人：用房间快照里他那一条的 pet；
#   · 账号服务器还是旧版（成员条目里没有 pet）：只有房主那只认得出来（快照的 host_pet），
#     其他队友先不出宠物 —— 宁可少一只，也不拿别人的宠物冒充。
static func member_pet_of(member: Dictionary, is_me: bool, own_active_pet: String,
		room_host_pet: String) -> String:
	if is_me and not own_active_pet.is_empty():
		return own_active_pet
	var pet := str(member.get("pet", ""))
	if not pet.is_empty():
		return pet
	if bool(member.get("host", false)):
		return room_host_pet
	return ""


func _sync_stage() -> void:
	_stage.configure_party_members(_stage_members(), PET_AREA_POS, PET_AREA_SIZE)


# 消息直接写在聊天框的纸面上，一条一行「名字：内容」（长的自动换行），最新的在最底下。
# 内容没变就不重建 —— 房间快照 7 秒来一次，每次都重建的话，玩家往上翻着看就被拽回底部。
func _render_chat() -> void:
	var messages: Array = _room.get("messages", [])
	var sig := "%d:%d" % [messages.size(), messages.hash()]
	if sig == _chat_sig and _chat_list.get_child_count() > 0:
		return
	_chat_sig = sig
	_clear_children(_chat_list)
	if messages.is_empty():
		var hint := _chat_line(_text("还没有人说话", "No messages yet"))
		hint.add_theme_color_override("font_color", Color(Tokens.CHAT_INK, 0.55))
		_chat_list.add_child(hint)
		return
	for raw in messages:
		if not raw is Dictionary:
			continue
		var message: Dictionary = raw
		_chat_list.add_child(_chat_line("%s：%s" % [str(message.get("name", "")), str(message.get("text", ""))]))
	_scroll_chat_bottom.call_deferred()


# 用 Label（不是 RichTextLabel）：玩家打的「[」不能被当成标记解析。
func _chat_line(value: String) -> Label:
	var line := Label.new()
	line.text = value
	line.custom_minimum_size.x = CHAT_TEXT_W
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.add_theme_font_size_override("font_size", CHAT_FONT)
	line.add_theme_color_override("font_color", Tokens.CHAT_INK)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _scroll_chat_bottom() -> void:
	# 自动换行的 Label 要等排版过一帧才有真实高度；只等一次时滚动条最大值还是旧的，
	# 换行的长消息会把最新一条挤到可视区外。
	await get_tree().process_frame
	await get_tree().process_frame
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
	else:
		if int(result.get("code", 0)) == 404 and str(result.get("error", "")) == "Not Found":
			_load_error = _text("组队服务未更新（404）", "Party service unavailable (404)")
		else:
			_load_error = str(result.get("error", _text("无法进入队伍", "Unable to join party")))
		_notice.text = _load_error


# 没有邀请（或邀请进不去）时：已经在队伍里就用那个队伍，没有就建一个；
# 自己一个人的队伍模式不对就顺手改成这次进来的模式。
func _fetch_or_create_party() -> Dictionary:
	var reconciled: Dictionary = await AccountManager.reconcile_finished_assignment()
	if int(reconciled.get("code", 0)) != 200:
		return reconciled
	var result: Dictionary = await AccountManager.fetch_party()
	if int(result.get("code", 0)) != 200:
		return result
	var state: Dictionary = (result.get("body", {}) as Dictionary).get("state", {})
	if str(state.get("state", "")) != "room":
		return await AccountManager.create_party(_initial_mode)
	if _should_align_existing_mode(state):
		return await AccountManager.set_party_mode(_initial_mode)
	return result


func _should_align_existing_mode(state: Dictionary) -> bool:
	return not _restore_existing_party and str(state.get("mode", "")) != _initial_mode \
		and str(state.get("host_code", "")) == _my_code() \
		and (state.get("members", []) as Array).size() == 1 and not bool(state.get("queued", false))

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
	if _preview != "":
		return
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
	if _queue_ban_deadline >= 0:
		var message := AccountManager.queue_ban_text(_queue_ban_deadline)
		if _notice.text != message:
			_notice.text = message
		if Time.get_ticks_msec() >= _queue_ban_deadline:
			_queue_ban_deadline = -1
			_show_sticky_notice(message)
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


func _update_mode_display(mode: String) -> void:
	if _mode_button == null:
		return
	match mode:
		"casual_normal":
			_mode_button.text = _text("普通  ·  21 回合    ▾", "NORMAL  ·  21 ROUNDS    ▾")
			_mode_hint.text = _text("21回合·至少携带4族·休闲娱乐", "21 rounds · equip at least 4 races · casual play")
		"ranked", "ranked_normal":
			_mode_button.text = _text("排位  ·  21 回合    ▾", "RANKED  ·  21 ROUNDS    ▾")
			_mode_hint.text = _text("21回合·至少携带4族·段位积分", "21 rounds · equip at least 4 races · ranked points")
		_:
			_mode_button.text = _text("青苗  ·  13 回合    ▾", "SEEDLING  ·  13 ROUNDS    ▾")
			_mode_hint.text = _text("13回合·最多3族·休闲娱乐", "13 rounds · up to 3 races · casual play")
	_style_mode(_mode_button, true)


func _open_mode_picker() -> void:
	if _preview == "tutorial":
		_tutorial_mode_chosen = true
		_mode_button.text = _text("青苗  ·  13 回合  ✓", "SEEDLING  ·  13 ROUNDS  ✓")
		_mode_button.disabled = true
		_action.disabled = false
		_notice.text = _text("已选择青苗 · 13 回合", "Seedling selected · 13 rounds")
		tutorial_mode_selected.emit()
		return
	if _local_only or ModalStack.has(MODE_MODAL_ID):
		return
	var dialog := CHOICE_DIALOG.new() as Control
	dialog.configure_modes(str(_room.get("mode", _initial_mode)))
	dialog.canceled.connect(func() -> void: ModalStack.pop(MODE_MODAL_ID))
	dialog.selected.connect(func(value: Variant) -> void:
		ModalStack.pop(MODE_MODAL_ID)
		_change_mode(str(value)))
	ModalStack.push(dialog, {"id": MODE_MODAL_ID, "owner": self,
		"priority": 50, "dismiss_on_backdrop": true})


func _open_seedling_race_picker(available: Array) -> void:
	if ModalStack.has(RACES_MODAL_ID):
		return
	var dialog := CHOICE_DIALOG.new() as Control
	dialog.configure_races(available)
	dialog.canceled.connect(func() -> void: ModalStack.pop(RACES_MODAL_ID))
	dialog.selected.connect(func(value: Variant) -> void:
		ModalStack.pop(RACES_MODAL_ID)
		_start_with_races(value as Array))
	ModalStack.push(dialog, {"id": RACES_MODAL_ID, "owner": self,
		"priority": 50, "dismiss_on_backdrop": false})


func _change_mode(mode: String) -> void:
	if _local_only:
		return
	if _preview != "":
		_room["mode"] = mode
		_apply(_room)
		return
	_run(AccountManager.set_party_mode.bind(mode))


# 11-26：返回「这次邀请发出去了没有」，好友卡片据此把键改成「已邀请」。
func _invite(code: String) -> bool:
	if _local_only:
		return false
	if _preview != "":
		_notice.text = _text("已发送邀请", "Invitation sent")
		return true
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
		return false
	_busy = true
	var result: Dictionary = await AccountManager.invite_to_party(code)
	_busy = false
	if not is_inside_tree():
		return false
	if int(result.get("code", 0)) != 200:
		_notice.text = str(result.get("error", _text("邀请失败", "Invitation failed")))
		return false
	_show_sticky_notice(_text("已发送邀请", "Invitation sent"))
	# 不 await：这只是刷新会话列表/红点，别让房间界面等网络。
	ChatService.refresh_unread()
	return true


# 「＋ 打字」：弹输入条（贴屏幕顶，手机键盘不会盖住它；同自定义房间 / 对局里）。
func _open_text_input() -> void:
	if _local_only:
		return
	_close_phrase_panel()
	ChatInputBar.new().present(self, func(text: String) -> String:
			return _submit_chat(text))


# 输入条点「发送」。返回空串 = 发出去了（输入条收起）；非空 = 原因，输入条留着把它写给玩家看。
func _submit_chat(text: String) -> String:
	var message := text.strip_edges()
	if message.is_empty():
		return ""
	if _local_only:
		return _text("队伍服务未连接", "Party service unavailable")
	if _busy:
		# _run 忙的时候会直接丢掉这次请求；这里先说出来，免得字打了半天一点没反应。
		return _text("上一个操作还没完成，请再点一次发送", "Still busy — tap send again")
	_send_text(message)
	return ""


# 快捷短语和打字共用：发一条队内消息。
func _send_text(message: String) -> void:
	if _preview != "":
		var log: Array = _room.get("messages", [])
		log.append({"code": _my_code(), "name": _text("我", "Me"), "text": message})
		_room["messages"] = log
		_render_chat()
		return
	_run(AccountManager.send_party_chat.bind(message))


func _act() -> void:
	if _preview == "tutorial":
		if _tutorial_mode_chosen:
			tutorial_requested.emit()
		return
	if _local_only or _busy:
		return
	if _preview != "":
		_notice.text = _text("预览模式", "Preview mode")
		return
	if str(_room.get("mode", "casual")) == "casual" and (
		_is_host() or not bool(_my_member().get("ready", false))):
		_busy = true
		var response: Dictionary = await AccountManager.fetch_entitlements()
		_busy = false
		if not is_inside_tree():
			return
		if int(response.get("code", 0)) != 200:
			_notice.text = _text("种族资料读取失败，请重试", "Could not load your races. Try again.")
			return
		# 体验中的种族也能选（体验卡，backend/app/trial.py）：items 是永久拥有，trials 是体验中。
		var usable: Array = ((response.get("body", {}) as Dictionary).get("items", []) as Array).duplicate()
		var trials: Variant = (response.get("body", {}) as Dictionary).get("trials", {})
		if trials is Dictionary:
			usable.append_array((trials as Dictionary).keys())
		var available := available_seedling_races(usable)
		if available.size() >= 4:
			_open_seedling_race_picker(available)
			return
	_start_with_races([])


static func available_seedling_races(entitlements: Array) -> Array[String]:
	var owned := {}
	for raw in entitlements:
		owned[str(raw)] = true
	var available: Array[String] = []
	var known: Array[String] = RacePick.all_races()
	if known.has("human") and owned.has("human"):
		available.append("human")
	for race in known:
		if race != "human" and owned.has(race):
			available.append(race)
	return available


func _start_with_races(races: Array) -> void:
	if _is_host():
		_run(AccountManager.start_party_match.bind(races))
	else:
		_run(AccountManager.set_party_ready.bind(
			not bool(_my_member().get("ready", false)), races))


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
	_queue_ban_deadline = int(result.get("queue_ban_deadline", -1))
	if int(result.get("code", 0)) == 200:
		_apply((result.get("body", {}) as Dictionary).get("state", {}))
	elif _queue_ban_deadline >= 0:
		_notice.text = AccountManager.queue_ban_text(_queue_ban_deadline)
	else:
		_notice.text = str(result.get("error", _text("操作失败", "Action failed")))


func _is_host() -> bool:
	if _preview != "":
		return _preview in ["host", "tutorial"]
	return str(_room.get("host_code", "")) == str(AccountManager.profile.get("friend_code", ""))


# 服务器下发的「几个人能开始匹配」。JSON 里的数字是 float，Godot 4 的 Array.has(2)
# 不认 2.0，所以要逐个转回 int。
func _startable_sizes() -> Array:
	var raw: Variant = _room.get("startable_sizes")
	if not raw is Array:
		return STARTABLE_SIZES
	var out := []
	for value in raw:
		out.append(int(value))
	return out


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
	if _preview == "tutorial":
		return {"state": "room", "id": "tutorial_local", "mode": "casual",
			"host_code": "TUTORIAL", "members": [{"friend_code": "TUTORIAL",
			"player_name": str(AccountManager.profile.get("player_name", "Player")),
			"avatar": AVATARS.default_avatar(), "avatar_frame": AVATARS.default_frame(),
			"tier": 0, "host": true, "ready": true, "pet": ""}], "pets": [],
			"host_pet": "", "messages": [], "queued": false}
	return {"state": "room", "id": "preview", "mode": "ranked", "host_code": "ABCD1234",
		"members": [
			{"friend_code": "ABCD1234", "player_name": "星河", "avatar": AVATARS.default_avatar(),
			 "avatar_frame": AVATARS.default_frame(), "tier": 3, "host": true, "ready": true,
			 "pet": "pet_cat"},
			{"friend_code": "EFGH5678", "player_name": "风铃", "avatar": AVATARS.default_avatar(),
			 "avatar_frame": AVATARS.default_frame(), "tier": 2, "host": false, "ready": _preview == "host",
			 "pet": "pet_rabbit"},
		], "pets": [], "host_pet": "pet_cat", "messages": [
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
	_refresh_voice_status()
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


# 房间里的设置页（10.11 第 2 条）。原来是 `_is_audio_muted / _mute_text / _toggle_mute`
# 那套「整局静音」—— 现在整页搬进 SettingsScreen，这里只负责把它推上 ModalStack。
#
# `lobby_mode = true` 让页脚只剩「返回」：既没有「重新体验教学」，也没有「退出对局」
# （用户口径：「内容上要比对局里的设定少个『退出对局』按钮」）。
# `can_leave_match = false` 是同一件事的兜底 —— 万一 lobby_mode 被谁改回 false，
# 也不会在房间里冒出一颗点不到的「退出对局」。
func _open_settings() -> void:
	if ModalStack.has(LOBBY_SETTINGS_MODAL_ID):
		return
	var screen := SETTINGS_SCENE.instantiate() as SettingsScreenScript
	screen.lobby_mode = true
	screen.can_leave_match = false
	screen.back_requested.connect(func() -> void: ModalStack.pop(LOBBY_SETTINGS_MODAL_ID))
	ModalStack.push(screen, {
		"id": LOBBY_SETTINGS_MODAL_ID,
		"owner": self,
		"priority": 50,
		"dismiss_on_backdrop": false,
	})


# 快捷短语：列在聊天框上方，点哪句发哪句（同一个队内聊天接口 —— 服务器那边就是一条普通消息）。
func _toggle_phrase_panel() -> void:
	if _phrase_panel != null:
		_close_phrase_panel()
		return
	if _local_only:
		return
	var phrase_count := 0
	for group in ChatPhrases.GROUP_ORDER:
		phrase_count += ChatPhrases.ids_in_group(str(group)).size()
	# 高 = 标题木条 + 行数 × 行距 + 底边框。
	var panel_size := Vector2(PHRASE_PANEL_W,
		PHRASE_PANEL_TOP + ceilf(phrase_count / 2.0) * PHRASE_BTN_STEP.y + 22.0)
	_phrase_panel = _frame_panel(_left,
		Vector2(CHAT_POS.x, CHAT_POS.y - panel_size.y - 8.0), panel_size, "card")
	_phrase_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_title_label(_phrase_panel, _text("快捷短语", "QUICK CHAT"), Vector2(22, 13), Vector2(200, 27), 16)
	var index := 0
	for group in ChatPhrases.GROUP_ORDER:
		for phrase_id in ChatPhrases.ids_in_group(str(group)):
			var text := ChatPhrases.text(int(phrase_id))
			var pos := Vector2(24, PHRASE_PANEL_TOP) + Vector2(PHRASE_BTN_STEP.x * float(index % 2),
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
	_send_text(text)


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
	# 底下那层透明挡板铺满整个屏幕（点面板外面 = 收起）；面板放在最上面那一层。
	_voice_backdrop = _button(self, "", Vector2.ZERO, Vector2.ZERO)
	_voice_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	move_child(_overlay, -1)
	_voice_backdrop.flat = true
	_voice_backdrop.focus_mode = Control.FOCUS_NONE
	_voice_backdrop.pressed.connect(_close_voice_panel)
	var height := 124.0 + 56.0 * float(maxi(1, others.size()))
	_voice_panel = _paper_panel(_overlay, Vector2((REF.x - 380.0) * 0.5, 250), Vector2(380, height), 0.97)
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


func _toggle_pets_drawer() -> void:
	if _pet_toggle.disabled:
		_pets_drawer.visible = false
		return
	_pets_drawer.visible = not _pets_drawer.visible
	if _pets_drawer.visible:
		# 面板盖在朋友列表上：开着的好友卡片先收掉，免得悬在一块看不见的行旁边。
		if ModalStack.has(FRIEND_CARD_MODAL_ID):
			ModalStack.pop(FRIEND_CARD_MODAL_ID)
		_render_pets()


# 羊皮纸面板（11.11 起）。piece：小面板用 "card"（四角小一号），大的用 "panel"。
func _frame_panel(parent: Control, pos: Vector2, dimensions: Vector2, piece: String) -> Panel:
	var panel := Panel.new()
	panel.position = pos
	panel.size = dimensions
	panel.custom_minimum_size = dimensions
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", Kit.box(piece, Vector4.ZERO))
	parent.add_child(panel)
	return panel


# 深色标题木条上的标题：奶油字 + 深描边。
func _title_label(parent: Control, value: String, pos: Vector2, dimensions: Vector2, font_size: int) -> Label:
	# 11.11：标题现在写在羊皮纸上（原来是深色木条），改深棕字
	var label := _label(parent, value, pos, dimensions, font_size, Color("8a4b12"))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_outline_color", Kit.INK_OUTLINE)
	label.add_theme_constant_override("outline_size", 3)
	return label


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
	button.add_theme_color_override("font_color", Kit.INK)
	button.add_theme_color_override("font_hover_color", Kit.INK)
	button.add_theme_color_override("font_pressed_color", Kit.INK)
	button.add_theme_color_override("font_disabled_color", Color(0.42, 0.35, 0.27, 0.75))
	button.add_theme_color_override("font_outline_color", Kit.INK_OUTLINE)
	button.add_theme_constant_override("outline_size", 2)
	button.add_theme_font_size_override("font_size", 18)


func _style_compact_button(button: Button, selected: bool) -> void:
	# 小按钮：羊皮纸小底板，选中的用金色
	Kit.style_plate(button, selected)
	button.add_theme_font_size_override("font_size", 18)


func _button_plate(texture: Texture2D, tint: Color) -> StyleBoxTexture:
	# 11.11：旧的四张木牌按钮图换成羊皮纸部件 —— 主操作金色卷轴、次操作羊皮纸卷轴、
	# 模式页签用卷轴页签（选中金色）。调用方传进来的还是旧常量，只在这里换图。
	var piece := "button"
	if texture == BUTTON_MODE_IDLE:
		piece = "tab"
	elif texture == BUTTON_MODE_ACTIVE:
		piece = "tab_active"
	var style := StyleBoxTexture.new()
	style.texture = Kit.tex(piece)
	style.modulate_color = tint
	return style


func _style_empty_seat(button: Button) -> void:
	# 11.11：空座位画成主菜单那个透明孔的头像圆环（等比居中，不拉伸），悬停稍微提亮
	var empty := StyleBoxEmpty.new()
	for state in ["normal", "disabled", "focus", "hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, empty)
	if button.get_node_or_null("SeatRing") == null:
		var ring := TextureRect.new()
		ring.name = "SeatRing"
		AVATARS.set_frame_texture(ring, SEAT_RING)
		ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ring.show_behind_parent = true
		button.add_child(ring)
		button.mouse_entered.connect(func() -> void: ring.modulate = Color(1.12, 1.1, 1.02))
		button.mouse_exited.connect(func() -> void: ring.modulate = Color.WHITE)
	button.text = "+"
	button.add_theme_color_override("font_color", Color(1.0, 0.95, 0.82))
	button.add_theme_color_override("font_hover_color", Color(1.0, 0.98, 0.9))
	button.add_theme_color_override("font_disabled_color", Color(1.0, 0.95, 0.82, 0.55))
	button.add_theme_color_override("font_outline_color", Color(0.12, 0.07, 0.025, 0.9))
	button.add_theme_constant_override("outline_size", 6)
	button.add_theme_font_size_override("font_size", 56)


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
	VoiceButtonArt.use_art_as_button_background(button)
	var art := TextureRect.new()
	art.name = "VoiceIcon"
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	button.add_child(art)
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.offset_left = 0
	art.offset_right = 0
	art.offset_top = 0
	art.offset_bottom = 0
	return button


func _set_voice_icon(button: Button, key: String) -> void:
	if button == null or not is_instance_valid(button):
		return
	var art := button.get_node_or_null("VoiceIcon") as TextureRect
	if art == null:
		return
	if art.get_meta("voice_icon", "") == key:
		return
	art.texture = VoiceButtonArt.texture_for(key)
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
		_voice_mic.accessibility_name = _text("关闭麦克风" if mic_on else "打开麦克风", "Toggle microphone")
		_voice_mic.disabled = _local_only
	if _voice_speaker != null:
		_voice_speaker.accessibility_name = _text("关闭扬声器" if speaker_on else "打开扬声器", "Toggle speaker")
		_voice_speaker.disabled = _local_only
	for b in [_voice_mic, _voice_speaker]:
		if b != null:
			var icon := b.get_node_or_null("VoiceIcon") as TextureRect
			if icon != null:
				icon.modulate.a = 0.55 if b.disabled else 1.0


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
	var text_color := Kit.INK_ON_GOLD if selected else Kit.INK
	button.add_theme_color_override("font_color", text_color)
	button.add_theme_color_override("font_hover_color", text_color)
	button.add_theme_color_override("font_pressed_color", text_color)
	button.add_theme_color_override("font_disabled_color", Color(0.42, 0.35, 0.27, 0.75))
	button.add_theme_color_override("font_outline_color", Kit.INK_OUTLINE)
	button.add_theme_constant_override("outline_size", 2)
	button.add_theme_font_size_override("font_size", 24)


# 11-26：开始键用自定义房间那块木牌（TEX_START），整张拉满 270×130。
func _style_action() -> void:
	var normal := _action_plate(Color.WHITE)
	_action.add_theme_stylebox_override("normal", normal)
	_action.add_theme_stylebox_override("focus", normal)
	_action.add_theme_stylebox_override("hover", _action_plate(Color(1.10, 1.08, 1.02)))
	_action.add_theme_stylebox_override("pressed", _action_plate(Color(0.85, 0.83, 0.80)))
	_action.add_theme_stylebox_override("hover_pressed", _action_plate(Color(0.85, 0.83, 0.80)))
	_action.add_theme_stylebox_override("disabled", _action_plate(Color(0.65, 0.66, 0.63, 0.73)))
	_action.add_theme_color_override("font_color", Kit.INK_ON_GOLD)
	_action.add_theme_color_override("font_hover_color", Kit.INK_ON_GOLD)
	_action.add_theme_color_override("font_pressed_color", Kit.INK_ON_GOLD)
	_action.add_theme_color_override("font_disabled_color", Color(0.42, 0.35, 0.27, 0.8))
	_action.add_theme_color_override("font_outline_color", Kit.INK_OUTLINE)
	_action.add_theme_constant_override("outline_size", 2)
	_action.add_theme_font_size_override("font_size", 26)


func _action_plate(tint: Color) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = TEX_START
	style.modulate_color = tint
	return style


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


func _refresh_voice_status() -> void:
	if _voice_status == null:
		return
	var error := str(_party_voice.last_error())
	_voice_status.text = "" if error.is_empty() else _text("队伍语音暂不可用", "Party voice unavailable")
	_voice_status.accessibility_description = error
