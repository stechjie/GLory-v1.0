extends Control

signal new_game_requested
signal continue_requested
signal settings_requested
signal team_host_requested
signal team_join_requested(address: String)
signal team_room_create_requested
signal team_room_join_requested(room_id: int)
signal team_room_list_requested
signal public_token_generate_requested
signal public_token_resume_requested(token_id: String)
signal team_offline_requested   # 不联网，本地单人 vs AI 自测
signal team_reconnect_requested # 手动重连回上一场对局
signal prep_requested           # 「备战」按钮：进入备战界面（暂时只有宠物系统）
signal codex_requested          # 「图鉴」按钮：进入图鉴界面
signal profile_requested        # 左上角名牌：进入玩家资料界面

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const REF_SIZE := Vector2(1672.0, 941.0)

# V3 P0-07：房间面板改由 ModalStack 收口。
# priority 40 与组队佣兵检阅台同档 —— 都是页面级面板，
# 低于 pvp_warning 60 < 战斗加载 80 < 重连 90 < DialogService 100。
const ROOM_MODAL_ID := "main_menu_room_panel"
const ROOM_MODAL_PRIORITY := 40
const TEX_BACKGROUND := preload("res://assets/ui/main_menu_live/background.png")
const TEX_PROFILE_PANEL := preload("res://assets/ui/main_menu_live/profile_panel.png")
const TEX_PROFILE_AVATAR := preload("res://assets/ui/main_menu_live/profile_avatar.png")
const TEX_GOLD := preload("res://assets/ui/main_menu_live/gold.png")
const TEX_DIAMOND := preload("res://assets/ui/main_menu_live/diamond.png")
const TEX_MAIL := preload("res://assets/ui/main_menu_live/mail.png")
const TEX_BAG := preload("res://assets/ui/main_menu_live/bag.png")
const TEX_SETTINGS := preload("res://assets/ui/main_menu_live/settings.png")
const TEX_FRIENDS := preload("res://assets/ui/main_menu_live/friends.png")
const TEX_CHAT := preload("res://assets/ui/main_menu_live/chat.png")
const TEX_SHOP := preload("res://assets/ui/main_menu_live/shop.png")
const TEX_NEWS := preload("res://assets/ui/main_menu_live/news.png")
const TEX_PREP := preload("res://assets/ui/main_menu_live/prep.png")
const TEX_CASUAL := preload("res://assets/ui/main_menu_live/casual.png")
const TEX_RANKED := preload("res://assets/ui/main_menu_live/ranked.png")
const TEX_CUSTOM := preload("res://assets/ui/main_menu_live/custom.png")
const TEX_GALLERY := preload("res://assets/ui/main_menu_live/gallery.png")
const MAIN_MENU_AMBIENCE := preload("res://scenes/menu/MainMenuAmbience.gd")
const MAIN_MENU_PET := preload("res://scenes/menu/MainMenuPet.gd")
const MENU_MUSIC_PATH := "res://assets/audio/bgm/menu_music.mp3"

# ── 布局调试overlay ────────────────────────────────────────────────
# 打开后：黑线 = 空间划分（参考画布边界 / 功能分区 / 每个元素占位框）
#         红线 = 所有按钮的点击判定区（_add_hit 与真实 Button）
# 游戏里按 F3 开关。调完把 DEBUG_LAYOUT 改回 false 即可。
const DEBUG_LAYOUT := false
# 参考画布(1672x941)下的功能分区，只用于画黑色分区带
const DEBUG_BANDS := [
	{"name": "顶部 HUD", "y": 0.0, "h": 135.0},
	{"name": "左侧社交栏", "y": 290.0, "h": 290.0},
	{"name": "右侧商店/公告", "y": 130.0, "h": 580.0},
	{"name": "令牌行", "y": 585.0, "h": 75.0},
	{"name": "底部主按钮区", "y": 640.0, "h": 280.0},
]

# 左上角名牌上的两行字。要在账号资料到达后就地刷新，所以留引用。
var _profile_portrait: TextureRect
var _profile_name_label: Label
var _profile_sub_label: Label
var _menu_music_player: AudioStreamPlayer
var _address_edit: LineEdit
var _net_status: Label
# 「敬请期待」不再持有 AcceptDialog 节点：见 _show_coming_soon()。
# 迁移前这是常驻在 MainMenu 下的 overlay 节点。现在面板由 ModalStack 持有，
# 开关状态用 ModalStack.has(ROOM_MODAL_ID) 问，不再自己记一个节点引用。
var _room_list_box: VBoxContainer
var _room_id_edit: LineEdit
var _room_status: Label
var _token_id_edit: LineEdit
var _token_label: Label
var _placed: Array[Dictionary] = []
var _screen_bands: Array[Dictionary] = []
var _debug_layer: Control
var _debug_on := DEBUG_LAYOUT
var _layout_scale := 1.0
var _layout_origin := Vector2.ZERO

func _ready() -> void:
	_build()
	_layout()
	_start_menu_music()
	if not AccountManager.profile_changed.is_connected(_on_account_profile_changed):
		AccountManager.profile_changed.connect(_on_account_profile_changed)
	_refresh_profile_plate()
	_ensure_profile_loaded()

func _exit_tree() -> void:
	if AccountManager.profile_changed.is_connected(_on_account_profile_changed):
		AccountManager.profile_changed.disconnect(_on_account_profile_changed)

func _on_account_profile_changed(_profile: Dictionary) -> void:
	_refresh_profile_plate()

func _start_menu_music() -> void:
	if _menu_music_player != null:
		return
	# 与摆放界面同款：必须用 load() 走资源系统，Android 导出包只含 mp3 的导入产物。
	var stream := load(MENU_MUSIC_PATH) as AudioStream
	if stream == null:
		push_warning("主菜单音乐读取失败：%s" % MENU_MUSIC_PATH)
		return
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	_menu_music_player = AudioStreamPlayer.new()
	_menu_music_player.name = "MenuMusicPlayer"
	_menu_music_player.stream = stream
	_menu_music_player.bus = "Music" if AudioServer.get_bus_index("Music") >= 0 else "Master"
	add_child(_menu_music_player)
	_menu_music_player.play()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = TEX_BACKGROUND
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var ambience := MAIN_MENU_AMBIENCE.new() as Control
	add_child(ambience)

	# 中心草地上的宠物（拥有几只出几只）。加在这里 = 在背景之上、所有 UI 之下。
	add_child(MAIN_MENU_PET.new() as Control)

	# 左上角个人信息、左侧朋友/聊天：锚定到屏幕左边（edge="left"）
	# 个人信息按钮 = 资料框 + 头像框两张图叠出来，整组一个判定区。
	# 头像框压在资料框左边 1/3，因为是正方形所以上下各凸出约 33。
	# 素材原始比例：资料框 1325x267 (4.96:1)、头像框 850x825 (1.03:1)，
	# 改尺寸时按比例改，不然 STRETCH_KEEP_ASPECT 会在框里留边错位。
	# 顺序 = 绘制层级，hit 必须放最后（TextureRect 默认会吃掉点击）。
	# TODO 以后往头像框里放玩家立绘：要一张圆心透明的头像框，立绘那行插在头像框之前垫底。
	_add_texture(TEX_PROFILE_PANEL, Vector2(18, 46), Vector2(550, 110), "left")
	_add_texture(TEX_PROFILE_AVATAR, Vector2(18, 12), Vector2(180, 175), "left")
	# 头像画在框**之上**，不是垫在底下。
	#
	# 顶部原来那条 TODO 写的是「以后往头像框里放玩家立绘：要一张圆心透明的头像框，
	# 立绘那行插在头像框之前垫底」—— 但 profile_avatar.png 的圆心**不是透明的洞**，
	# 实测是不透明深棕（RGB 59,44,25 / alpha 255）。垫在底下会被整个盖住。
	#
	# 所以改成盖在上面 + 裁成圆形。等美术出了圆心透明的版本，可以把这行挪到
	# 上一行之前并去掉裁剪，那样更省一次绘制。
	_profile_portrait = _add_round_portrait(Vector2(46, 36), Vector2(123, 123), "left")
	# 这两行**曾经是写死的假数据**（"GloryMaster" / "等级 45"）。等级系统不存在，
	# 所以第二行现在放注册天数 —— 有真实来源，且比精确注册日期少泄漏一点。
	# 等级/段位做出来之后再换回去，那时第二行才有真东西可放。
	_profile_name_label = _add_label("", Vector2(200, 70), Vector2(330, 35), 24, "left")
	_profile_sub_label = _add_label("", Vector2(200, 104), Vector2(330, 24), 18, "left")
	_add_hit(Vector2(18, 12), Vector2(550, 178), _emit_profile, "left")
	_add_texture(TEX_GOLD, Vector2(645, 35), Vector2(220, 55))
	_add_label("89,450", Vector2(645, 35), Vector2(220, 55), 24)
	_add_texture(TEX_DIAMOND, Vector2(885, 35), Vector2(220, 55))
	_add_label("2,350", Vector2(885, 35), Vector2(220, 55), 24)

	_add_texture(TEX_FRIENDS, Vector2(28, 300), Vector2(132, 132), "left")
	_add_label(_menu_text("朋友", "Friends"), Vector2(47, 380), Vector2(94, 30), 21, "left")
	_add_hit(Vector2(28, 300), Vector2(132, 132), _show_coming_soon, "left")
	_add_texture(TEX_CHAT, Vector2(28, 440), Vector2(132, 132), "left")
	_add_label(_menu_text("聊天", "Chat"), Vector2(47, 520), Vector2(94, 30), 21, "left")
	_add_hit(Vector2(28, 440), Vector2(132, 132), _show_coming_soon, "left")

	# 右上角背包/邮件/设置、右侧商店/公告：锚定到屏幕右边（edge="right"）
	_add_texture(TEX_BAG, Vector2(1340, 25), Vector2(100, 100), "right")
	_add_label(_menu_text("背包", "Bag"), Vector2(1340, 95), Vector2(100, 7), 7, "right")
	_add_hit(Vector2(1340, 25), Vector2(100, 100), _show_coming_soon, "right")
	_add_texture(TEX_MAIL, Vector2(1450, 25), Vector2(100, 100), "right")
	_add_label(_menu_text("邮件", "Mail"), Vector2(1450, 95), Vector2(100, 7), 7, "right")
	_add_hit(Vector2(1450, 25), Vector2(100, 100), _show_coming_soon, "right")
	_add_texture(TEX_SETTINGS, Vector2(1560, 25), Vector2(100, 100), "right")
	_add_label(_menu_text("设定", "Setting"), Vector2(1560, 95), Vector2(100, 7), 7, "right")
	_add_hit(Vector2(1560, 25), Vector2(100, 100), _emit_settings, "right")

	_add_texture(TEX_SHOP, Vector2(1380, 140), Vector2(270, 250), "right")
	_add_label(_menu_text("商店", "Shop"), Vector2(1380, 150), Vector2(270, 34), 24, "right")
	_add_hit(Vector2(1380, 140), Vector2(270, 250), _show_coming_soon, "right")
	_add_texture(TEX_NEWS, Vector2(1380, 400), Vector2(270, 250), "right")
	_add_label(_menu_text("公告 / 活动", "News / Events"), Vector2(1380, 407), Vector2(270, 34), 22, "right")
	_add_hit(Vector2(1380, 400), Vector2(270, 250), _show_coming_soon, "right")

	_add_texture(TEX_PREP, Vector2(215, 690), Vector2(220, 190))
	_add_texture(TEX_CASUAL, Vector2(455, 690), Vector2(220, 190))
	_add_texture(TEX_RANKED, Vector2(685, 650), Vector2(310, 260))
	_add_texture(TEX_CUSTOM, Vector2(1025, 690), Vector2(220, 190))
	_add_texture(TEX_GALLERY, Vector2(1265, 690), Vector2(220, 190))
	_add_label(_menu_text("备战", "Prep"), Vector2(200, 807), Vector2(220, 36), 26)
	_add_label(_menu_text("休闲", "Casual"), Vector2(440, 808), Vector2(220, 36), 26)
	_add_label(_menu_text("排位", "Ranked"), Vector2(680, 820), Vector2(310, 43), 32)
	_add_label(_menu_text("自定义", "Custom"), Vector2(1010, 809), Vector2(220, 36), 26)
	_add_label(_menu_text("图鉴", "Gallery"), Vector2(1250, 807), Vector2(220, 36), 26)
	_add_hit(Vector2(200, 690), Vector2(220, 190), _emit_prep)
	_add_hit(Vector2(440, 690), Vector2(220, 190), _show_coming_soon)
	_add_hit(Vector2(680, 650), Vector2(310, 260), _show_coming_soon)
	_add_hit(Vector2(1010, 690), Vector2(220, 190), _show_room_overlay)
	_add_hit(Vector2(1250, 690), Vector2(220, 190), _emit_codex)

	var offline_btn := Button.new()
	offline_btn.text = _menu_text("离线自测", "Offline")
	offline_btn.focus_mode = Control.FOCUS_NONE
	offline_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var ob_style := Tokens.flat_box(Tokens.INK_PANEL, Tokens.INK_EDGE, 2, 26)
	offline_btn.add_theme_stylebox_override("normal", ob_style)
	offline_btn.add_theme_stylebox_override("hover", ob_style)
	offline_btn.add_theme_stylebox_override("pressed", ob_style)
	offline_btn.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	offline_btn.add_theme_font_size_override("font_size", 22)
	offline_btn.pressed.connect(_emit_offline)
	add_child(offline_btn)
	_track(offline_btn, Vector2(40, 876), Vector2(210, 54), 0, "left")

	# 游戏重连：放在"开始游戏（自定房间 970,724）"正上方，仅在本地存在重连凭证时显示。
	# 按它才连回上一场；按开始游戏则放弃旧局开新的一场。
	var reconnect_btn := Button.new()
	reconnect_btn.text = _menu_text("↩ 游戏重连", "↩ Reconnect")
	reconnect_btn.focus_mode = Control.FOCUS_NONE
	reconnect_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var rc_style := Tokens.flat_box(Tokens.INK_PANEL, Tokens.INK_EDGE, 3, 26)
	reconnect_btn.add_theme_stylebox_override("normal", rc_style)
	reconnect_btn.add_theme_stylebox_override("hover", rc_style)
	reconnect_btn.add_theme_stylebox_override("pressed", rc_style)
	reconnect_btn.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	reconnect_btn.add_theme_font_size_override("font_size", 26)
	reconnect_btn.pressed.connect(_emit_reconnect)
	# 仅在有重连凭证时才显示（没得连时不给一个点了没用的按钮）
	reconnect_btn.visible = not SaveManager.load_reconnect().is_empty()
	add_child(reconnect_btn)
	_track(reconnect_btn, Vector2(1110, 594), Vector2(235, 58))

	_net_status = _add_label("", Vector2(640, 64), Vector2(320, 32), 20)
	_net_status.add_theme_color_override("font_color", Color(0.98, 0.88, 0.55))

	_address_edit = LineEdit.new()
	_address_edit.text = NetworkConfig.SERVER_IP
	_address_edit.visible = false
	add_child(_address_edit)

	_build_debug_layer()

# 每次开层现建一份。ModalStack.push() 接管所有权，pop 时连同宿主层一起释放，
# 所以这里**不能**挂到 MainMenu 下 —— 那样切界面时会被清理逻辑连带删掉。
#
# 也不再自带 dim：背景交给 ModalStack 的 backdrop。自建那层不参与
# 「只有栈顶 backdrop 吃输入」的合同，而且两层黑会叠在一起。
func _build_room_panel() -> Control:
	var center := CenterContainer.new()
	center.name = "RoomPanel"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(920, 560)
	var style := Tokens.flat_box(Tokens.PARCHMENT, Tokens.PARCHMENT_EDGE, 4, 24)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 28)
	panel.add_child(root)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(330, 0)
	left.add_theme_constant_override("separation", 12)
	root.add_child(left)

	var title := Label.new()
	title.text = _menu_text("自定义房间", "Custom Room")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
	left.add_child(title)

	_token_label = Label.new()
	_token_label.text = _menu_text("Token ID：", "Token ID: ") + SaveManager.load_public_token()
	_token_label.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
	left.add_child(_token_label)

	_token_id_edit = LineEdit.new()
	_token_id_edit.placeholder_text = _menu_text("输入 Token ID", "Enter Token ID")
	_token_id_edit.text = SaveManager.load_public_token()
	left.add_child(_token_id_edit)

	var token_row := HBoxContainer.new()
	token_row.add_theme_constant_override("separation", 8)
	left.add_child(token_row)
	token_row.add_child(_dialog_button(_menu_text("生成", "Generate"), _emit_generate_token))
	token_row.add_child(_dialog_button(_menu_text("恢复", "Resume"), _emit_resume_token))

	left.add_child(_dialog_button(_menu_text("创建房间", "Create Room"), _emit_create_room))

	_room_id_edit = LineEdit.new()
	_room_id_edit.placeholder_text = _menu_text("输入房间 ID", "Enter Room ID")
	left.add_child(_room_id_edit)
	left.add_child(_dialog_button(_menu_text("加入房间", "Join Room"), _emit_join_room))

	_room_status = Label.new()
	_room_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_room_status.custom_minimum_size = Vector2(300, 90)
	_room_status.add_theme_color_override("font_color", Color(0.55, 0.22, 0.12))
	left.add_child(_room_status)

	left.add_child(_dialog_button(_menu_text("关闭", "Close"), _close_room_panel))

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(500, 0)
	right.add_theme_constant_override("separation", 10)
	root.add_child(right)

	var list_head := HBoxContainer.new()
	right.add_child(list_head)
	var list_title := Label.new()
	list_title.text = _menu_text("可加入房间", "Open Rooms")
	list_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_title.add_theme_font_size_override("font_size", 24)
	list_title.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
	list_head.add_child(list_title)
	list_head.add_child(_dialog_button(_menu_text("刷新", "Refresh"), _emit_room_list))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	_room_list_box = VBoxContainer.new()
	_room_list_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_room_list_box)
	return center

func show_connecting() -> void:
	if _net_status == null:
		return
	_net_status.add_theme_color_override("font_color", Color(0.98, 0.88, 0.55))
	_net_status.text = tr("menu_connecting")

func show_connection_error(msg: String) -> void:
	if _net_status == null:
		return
	_net_status.add_theme_color_override("font_color", Color(0.95, 0.45, 0.42))
	_net_status.text = tr("menu_connect_failed") % msg
	if _room_status != null:
		_room_status.text = msg

func show_public_token(token_id: String) -> void:
	if _token_label != null:
		_token_label.text = _menu_text("Token ID：", "Token ID: ") + token_id
	if _token_id_edit != null:
		_token_id_edit.text = token_id
	if _room_status != null:
		_room_status.text = _menu_text("Token ID 已生成", "Token ID generated")

func show_room_list(rooms: Array) -> void:
	if _room_list_box == null:
		return
	for child in _room_list_box.get_children():
		child.queue_free()
	if rooms.is_empty():
		var empty := Label.new()
		empty.text = _menu_text("目前没有可加入房间", "No open rooms")
		empty.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
		_room_list_box.add_child(empty)
		return
	for entry in rooms:
		var d := entry as Dictionary
		var id := int(d.get("id", 0))
		var players := int(d.get("players", 0))
		var max_players := int(d.get("max", 6))
		var text := _menu_text("房间 %d    %d/%d", "Room %d    %d/%d") % [id, players, max_players]
		var btn := _dialog_button(text, func(room_id := id): team_room_join_requested.emit(room_id))
		btn.custom_minimum_size = Vector2(460, 46)
		_room_list_box.add_child(btn)

func show_room_error(reason: String) -> void:
	if _room_status == null:
		return
	match reason:
		"room_not_found":
			_room_status.text = _menu_text("找不到房间", "Room not found")
		"room_started":
			_room_status.text = _menu_text("房间已经开始游戏", "Room already started")
		"room_full":
			_room_status.text = _menu_text("房间已满", "Room is full")
		"token_id_unknown":
			_room_status.text = _menu_text("没有找到可恢复的 Token ID", "No resumable game for this Token ID")
		_:
			_room_status.text = reason

func _emit_join() -> void:
	var address := NetworkConfig.SERVER_IP
	if _address_edit != null:
		address = _address_edit.text.strip_edges()
	if address.is_empty():
		address = NetworkConfig.SERVER_IP
	team_join_requested.emit(address)

func _show_room_overlay() -> void:
	# 去重交给 has()：连点两次「自定房间」不该开出两层。
	if ModalStack.has(ROOM_MODAL_ID):
		return
	var content := _build_room_panel()
	var modal_id := ModalStack.push(content, {
		"id": ROOM_MODAL_ID,
		"owner": self,
		"priority": ROOM_MODAL_PRIORITY,
		# 点外面可以关：这是纯浏览面板，没有未完成的强制选择。
		"dismiss_on_backdrop": true,
	})
	if modal_id.is_empty():
		# content 已被 push 收走，不能再 free，只清引用。
		_room_status = null
		_room_list_box = null
		return
	if _room_status != null:
		_room_status.text = ""
	team_room_list_requested.emit()


func _close_room_panel() -> void:
	ModalStack.pop(ROOM_MODAL_ID)

func _emit_generate_token() -> void:
	public_token_generate_requested.emit()

func _emit_resume_token() -> void:
	var token_id := _token_id_edit.text.strip_edges().to_upper()
	if token_id.is_empty():
		_room_status.text = _menu_text("请先输入 Token ID", "Enter Token ID first")
		return
	public_token_resume_requested.emit(token_id)

func _emit_create_room() -> void:
	team_room_create_requested.emit()

func _emit_join_room() -> void:
	var room_id := int(_room_id_edit.text.strip_edges())
	if room_id <= 0:
		_room_status.text = _menu_text("请输入正确的房间 ID", "Enter a valid Room ID")
		return
	team_room_join_requested.emit(room_id)

func _emit_room_list() -> void:
	team_room_list_requested.emit()

func _emit_offline() -> void:
	team_offline_requested.emit()

func _emit_reconnect() -> void:
	team_reconnect_requested.emit()

func _emit_prep() -> void:
	prep_requested.emit()

func _emit_codex() -> void:
	codex_requested.emit()

func _emit_settings() -> void:
	settings_requested.emit()

# 原来是 Godot 默认 AcceptDialog：系统标题栏、默认灰按钮，和游戏其余部分完全两种风格。
# 主菜单上有 9 个热区都指向它，所以它是玩家最常看到的弹窗（V3 P1-03 迁移清单第 2 项）。
# 固定 request_id 让连点多个热区只出一个框。
func _show_coming_soon() -> void:
	DialogService.info({
		"request_id": "main_menu_coming_soon",
		"owner": self,
		"title": _menu_text("敬请期待", "Coming Soon"),
		"body": _menu_text("这个功能还在开发中。", "This feature is still in development."),
		"confirm_text": _menu_text("知道了", "Got it"),
	})

func _emit_profile() -> void:
	profile_requested.emit()

# 名牌上的昵称与副行。**不自己拼显示名** —— 只从 AccountManager.display_name 出，
# 那是全仓唯一的拼法。理由：player_name 不唯一（database/001 的设计），
# 任何一处只显示昵称的地方，改名冒充就成立。
func _refresh_profile_plate() -> void:
	if _profile_name_label == null or not is_instance_valid(_profile_name_label):
		return
	var profile: Dictionary = AccountManager.profile
	if profile.is_empty():
		# 还没登录 / 还没拉到资料。**不放假名字** —— 玩家看到一个陌生昵称
		# 比看到一条横线更糟，而且那正是这次要消灭的东西。
		# 头像同理：宁可空着露出框里的深棕底，也不要先画一个默认头像再跳变。
		_profile_name_label.text = _menu_text("玩家", "Player")
		_profile_sub_label.text = "—"
		if _profile_portrait != null and is_instance_valid(_profile_portrait):
			_profile_portrait.texture = null
		return
	if _profile_portrait != null and is_instance_valid(_profile_portrait):
		_profile_portrait.texture = AvatarCatalog.texture_for(str(profile.get("avatar", "")))
	_profile_name_label.text = AccountManager.display_name(
		str(profile.get("player_name", "")), str(profile.get("friend_code", "")))
	var days := int(profile.get("days_since_created", 1))
	_profile_sub_label.text = _menu_text("第 %d 天" % days, "Day %d" % days)

# 首次进主菜单时拉一次资料，之后吃 AccountManager 的缓存。
# 每次回主菜单都发一次请求既慢又费流量，而这些字段只有玩家自己能改。
func _ensure_profile_loaded() -> void:
	if not AccountManager.profile.is_empty():
		return
	if not AccountManager.is_logged_in():
		return
	await AccountManager.fetch_my_profile()

func _menu_text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh

func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var scale := minf(viewport_size.x / REF_SIZE.x, viewport_size.y / REF_SIZE.y)
	var origin := (viewport_size - REF_SIZE * scale) * 0.5
	_layout_scale = scale
	_layout_origin = origin
	if _debug_layer != null:
		_debug_layer.queue_redraw()
	for band in _screen_bands:
		var rect := band.node as Control
		var height := float(band.height) * scale
		rect.position = Vector2(0.0, viewport_size.y - height if bool(band.from_bottom) else float(band.y) * scale)
		rect.size = Vector2(viewport_size.x, height)
	for item in _placed:
		var node := item.node as Control
		var pos := item.pos as Vector2
		var size := item.size as Vector2
		# edge=left/right 的元素锚定到真实屏幕边（消除宽屏下的左右留白）；
		# 其余保持 16:9 画布居中缩放。垂直方向一律跟随居中画布。
		var x: float
		match str(item.get("edge", "")):
			"left":
				x = pos.x * scale
			"right":
				x = viewport_size.x - (REF_SIZE.x - pos.x) * scale
			_:
				x = origin.x + pos.x * scale
		node.position = Vector2(x, origin.y + pos.y * scale)
		node.size = size * scale
		if node is Label:
			node.add_theme_font_size_override("font_size", maxi(10, int(item.font_size * scale)))

func _add_texture(texture: Texture2D, pos: Vector2, size: Vector2, edge: String = "") -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	add_child(rect)
	_track(rect, pos, size, 0, edge)
	return rect

# 圆形头像。用一个画满圆角的 Panel 当遮罩，clip_children 只画被它盖住的部分 ——
# 比写 shader 轻，也不用等美术出新素材。
#
# 位置与直径是从 profile_avatar.png 量出来的：图 850x825，内圆直径 532px、
# 圆心 (423, 399)，换算到参考画布是直径约 113、圆心 (107.6, 96.6)。
# 这里取 104 略小一圈，免得压到金色圆环。**换了那张框图就要重新量。**
func _add_round_portrait(pos: Vector2, size: Vector2, edge: String = "") -> TextureRect:
	var mask := Panel.new()
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 只画孩子、不画自己，用自己的形状当裁剪蒙版。
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color.WHITE
	# 圆角给到边长，引擎会自动收敛成正圆。
	circle.set_corner_radius_all(int(maxf(size.x, size.y)))
	mask.add_theme_stylebox_override("panel", circle)
	add_child(mask)

	var portrait := TextureRect.new()
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# COVERED 而不是 KEEP_ASPECT：立绘不是正方形，留边会在圆里露出缺口。
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(portrait)

	_track(mask, pos, size, 0, edge)
	return portrait

func _add_rect(color: Color, pos: Vector2, size: Vector2) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = color
	add_child(rect)
	_track(rect, pos, size)
	return rect

func _add_screen_band(color: Color, y: float, height: float, from_bottom: bool) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = color
	add_child(rect)
	_screen_bands.append({"node": rect, "y": y, "height": height, "from_bottom": from_bottom})
	return rect

func _add_label(text: String, pos: Vector2, size: Vector2, font_size: int, edge: String = "") -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.63))
	label.add_theme_color_override("font_outline_color", Color(0.12, 0.07, 0.025, 0.95))
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)
	_track(label, pos, size, font_size, edge)
	return label

func _add_pill(text: String, pos: Vector2, size: Vector2) -> void:
	# 四角同值，等价于原来逐角赋的 size.y * 0.5（药丸形）。
	var bg := Tokens.flat_box(Tokens.PARCHMENT_SOFT, Tokens.PARCHMENT_EDGE_SOFT,
		2, int(size.y * 0.5))
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)
	_track(panel, pos, size)
	_add_label(text, pos, size, 22)

func _add_hit(pos: Vector2, size: Vector2, cb: Callable, edge: String = "") -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.modulate = Color(1, 1, 1, 0)
	btn.pressed.connect(cb)
	btn.name = "hit_%s" % cb.get_method()
	add_child(btn)
	_track(btn, pos, size, 0, edge)
	return btn

func _add_text_button(text: String, pos: Vector2, size: Vector2, cb: Callable) -> Button:
	var btn := _dialog_button(text, cb)
	btn.add_theme_font_size_override("font_size", 18)
	add_child(btn)
	_track(btn, pos, size)
	return btn

func _dialog_button(text: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.custom_minimum_size = Vector2(150, 42)
	var style := Tokens.flat_box(Tokens.PARCHMENT_BUTTON, Tokens.PARCHMENT_EDGE, 2, 18)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
	btn.add_theme_font_size_override("font_size", 20)
	btn.pressed.connect(cb)
	return btn

func _track(node: Control, pos: Vector2, size: Vector2, font_size: int = 0, edge: String = "") -> void:
	_placed.append({"node": node, "pos": pos, "size": size, "font_size": font_size, "edge": edge})

# ── 布局调试overlay ────────────────────────────────────────────────
func _build_debug_layer() -> void:
	_debug_layer = Control.new()
	_debug_layer.name = "DebugLayoutOverlay"
	_debug_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_debug_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_layer.z_index = 4096
	_debug_layer.visible = _debug_on
	_debug_layer.draw.connect(_draw_debug_layout)
	add_child(_debug_layer)

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_F3:
		return
	_debug_on = not _debug_on
	if _debug_layer != null:
		_debug_layer.visible = _debug_on
		_debug_layer.queue_redraw()
	get_viewport().set_input_as_handled()

func _draw_debug_layout() -> void:
	if _debug_layer == null:
		return
	var viewport_size := get_viewport_rect().size
	var scale := _layout_scale
	var origin := _layout_origin
	var font := ThemeDB.fallback_font
	var black := Color(0.0, 0.0, 0.0, 0.95)
	var black_soft := Color(0.0, 0.0, 0.0, 0.45)
	var red := Color(1.0, 0.10, 0.10, 0.95)

	# 1) 参考画布 1672x941 的外框（居中缩放的那块 16:9 区域）
	var canvas := Rect2(origin, REF_SIZE * scale)
	_debug_layer.draw_rect(canvas, black, false, 3.0)
	_debug_layer.draw_string(font, origin + Vector2(6.0, -6.0),
		"参考画布 %dx%d  scale=%.3f  视口 %dx%d" % [int(REF_SIZE.x), int(REF_SIZE.y), scale,
		int(viewport_size.x), int(viewport_size.y)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 2) 画布中线 + 四等分竖线（摆按钮时用来对齐）
	for i in range(1, 4):
		var gx := origin.x + REF_SIZE.x * scale * float(i) / 4.0
		_debug_layer.draw_line(Vector2(gx, canvas.position.y), Vector2(gx, canvas.end.y),
			black if i == 2 else black_soft, 2.0 if i == 2 else 1.0)

	# 3) 功能分区带（横向黑带，标注参考坐标 y 范围）
	for band in DEBUG_BANDS:
		var by := origin.y + float(band.y) * scale
		var bh := float(band.h) * scale
		_debug_layer.draw_rect(Rect2(canvas.position.x, by, canvas.size.x, bh), black, false, 2.0)
		_debug_layer.draw_string(font, Vector2(canvas.position.x + 8.0, by + 18.0),
			"%s  y=%d~%d" % [band.name, int(band.y), int(band.y) + int(band.h)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 3.5) 宠物活动区域（中心草地）
	var pet_rect := Rect2(origin + MAIN_MENU_PET.AREA_POS * scale, MAIN_MENU_PET.AREA_SIZE * scale)
	_debug_layer.draw_rect(pet_rect, black, false, 2.0)
	_debug_layer.draw_string(font, pet_rect.position + Vector2(8.0, 18.0),
		"宠物活动区 (%d,%d) %dx%d" % [int(MAIN_MENU_PET.AREA_POS.x), int(MAIN_MENU_PET.AREA_POS.y),
		int(MAIN_MENU_PET.AREA_SIZE.x), int(MAIN_MENU_PET.AREA_SIZE.y)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 4) edge=left / edge=right 锚定边（这两列贴真实屏幕边，不跟画布走）
	var left_edge_x := 176.0 * scale
	var right_edge_x := viewport_size.x - (REF_SIZE.x - 1355.0) * scale
	_debug_layer.draw_line(Vector2(left_edge_x, 0.0), Vector2(left_edge_x, viewport_size.y), black, 2.0)
	_debug_layer.draw_line(Vector2(right_edge_x, 0.0), Vector2(right_edge_x, viewport_size.y), black, 2.0)
	_debug_layer.draw_string(font, Vector2(6.0, viewport_size.y - 26.0),
		"edge=left 贴屏幕左", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)
	_debug_layer.draw_string(font, Vector2(right_edge_x + 6.0, viewport_size.y - 26.0),
		"edge=right 贴屏幕右", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 5) 每个元素的占位框：按钮判定区红色，其余（图片/文字）黑色细框
	for item in _placed:
		var node := item.node as Control
		if node == null or not node.is_visible_in_tree():
			continue
		var rect := Rect2(node.position, node.size)
		var pos := item.pos as Vector2
		var size := item.size as Vector2
		if node is Button:
			_debug_layer.draw_rect(rect, red, false, 2.0)
			var edge_tag := str(item.get("edge", ""))
			var tag := "%s  (%d,%d) %dx%d%s" % [node.name, int(pos.x), int(pos.y),
				int(size.x), int(size.y), "" if edge_tag.is_empty() else "  edge=" + edge_tag]
			_debug_layer.draw_string(font, rect.position + Vector2(2.0, -4.0), tag,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, red)
		else:
			_debug_layer.draw_rect(rect, black_soft, false, 1.0)
