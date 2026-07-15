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

const REF_SIZE := Vector2(1672.0, 941.0)
const TEX_BACKGROUND := preload("res://assets/ui/start_menu/background.png")
const TEX_PROFILE := preload("res://assets/ui/start_menu/profile.png")
const TEX_VIP := preload("res://assets/ui/start_menu/vip.png")
const TEX_MAIL := preload("res://assets/ui/start_menu/mail.png")
const TEX_BAG := preload("res://assets/ui/start_menu/bag.png")
const TEX_SETTINGS := preload("res://assets/ui/start_menu/settings.png")
const TEX_SMALL_BUTTON := preload("res://assets/ui/start_menu/small_button.png")
const TEX_PANEL := preload("res://assets/ui/start_menu/panel.png")
const TEX_BOTTOM_BAR := preload("res://assets/ui/start_menu/bottom_bar.png")
const MENU_MUSIC_PATH := "res://assets/audio/bgm/menu_music.mp3"

var _menu_music_player: AudioStreamPlayer
var _address_edit: LineEdit
var _net_status: Label
var _coming_soon: AcceptDialog
var _room_overlay: Control
var _room_list_box: VBoxContainer
var _room_id_edit: LineEdit
var _room_status: Label
var _token_id_edit: LineEdit
var _token_label: Label
var _placed: Array[Dictionary] = []
var _screen_bands: Array[Dictionary] = []

func _ready() -> void:
	_build()
	_layout()
	_start_menu_music()

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
	add_child(bg)

	_add_screen_band(Color(0, 0, 0, 0.13), 0.0, 110.0, false)
	_add_screen_band(Color(0, 0, 0, 0.13), 0.0, 281.0, true)

	_add_texture(TEX_PROFILE, Vector2(34, 12), Vector2(430, 181))
	_add_texture(TEX_VIP, Vector2(452, 51), Vector2(96, 69))
	_add_label("VIP", Vector2(468, 68), Vector2(60, 28), 18)

	_add_pill(_menu_text("金币", "Gold"), Vector2(1002, 44), Vector2(144, 34))
	_add_pill(_menu_text("点券", "Coupon"), Vector2(1162, 44), Vector2(144, 34))

	_add_texture(TEX_SMALL_BUTTON, Vector2(38, 266), Vector2(300, 100))
	_add_label(_menu_text("朋友", "Friends"), Vector2(88, 290), Vector2(200, 42), 30)
	_add_hit(Vector2(38, 266), Vector2(300, 100), _show_coming_soon)

	_add_texture(TEX_SMALL_BUTTON, Vector2(38, 380), Vector2(300, 100))
	_add_label(_menu_text("聊天室", "Chat"), Vector2(88, 404), Vector2(200, 42), 30)
	_add_hit(Vector2(38, 380), Vector2(300, 100), _show_coming_soon)

	_add_texture(_bag_texture(), Vector2(1308, 8), Vector2(118, 118))
	_add_hit(Vector2(1308, 8), Vector2(118, 118), _show_coming_soon)
	_add_texture(TEX_MAIL, Vector2(1424, 9), Vector2(120, 120))
	_add_hit(Vector2(1424, 9), Vector2(120, 120), _show_coming_soon)
	_add_texture(TEX_SETTINGS, Vector2(1548, 24), Vector2(86, 88))
	_add_hit(Vector2(1548, 24), Vector2(86, 88), _show_coming_soon)

	_add_texture(TEX_PANEL, Vector2(1248, 126), Vector2(288, 267))
	_add_label(_menu_text("商店", "Shop"), Vector2(1280, 134), Vector2(226, 36), 26)
	_add_label(_menu_text("模型皮肤", "Skins"), Vector2(1295, 228), Vector2(198, 36), 22)
	_add_hit(Vector2(1248, 126), Vector2(288, 267), _show_coming_soon)

	_add_texture(TEX_PANEL, Vector2(1248, 414), Vector2(288, 267))
	_add_label(_menu_text("公告 / 活动", "News / Events"), Vector2(1280, 422), Vector2(226, 36), 26)
	_add_hit(Vector2(1248, 414), Vector2(288, 267), _show_coming_soon)

	_add_texture(TEX_BOTTOM_BAR, Vector2(70, 660), Vector2(1532, 277))
	_add_label(_menu_text("备战", "Prep"), Vector2(140, 848), Vector2(230, 46), 28)
	_add_label(_menu_text("娱乐模式", "Casual"), Vector2(405, 848), Vector2(230, 46), 28)
	_add_label(_menu_text("排位", "Ranked"), Vector2(732, 765), Vector2(196, 68), 38)
	_add_label(_menu_text("自定房间", "Custom"), Vector2(1028, 848), Vector2(230, 46), 28)
	_add_label(_menu_text("图鉴", "Gallery"), Vector2(1300, 848), Vector2(220, 46), 28)
	_add_hit(Vector2(78, 724), Vector2(306, 190), _show_coming_soon)
	_add_hit(Vector2(394, 724), Vector2(300, 190), _show_coming_soon)
	_add_hit(Vector2(704, 664), Vector2(264, 228), _show_coming_soon)
	_add_hit(Vector2(970, 724), Vector2(300, 190), _show_room_overlay)
	_add_hit(Vector2(1276, 724), Vector2(292, 190), _show_coming_soon)

	_add_text_button(_menu_text("生成 Token ID", "Generate Token"), Vector2(960, 586), Vector2(165, 52), _emit_generate_token)
	_add_text_button(_menu_text("输入 Token ID", "Enter Token"), Vector2(1138, 586), Vector2(165, 52), _show_token_prompt)

	# 离线自测入口：不联网直接进 3v3 大厅（team_active=false），可单人 vs AI 试玩。
	# 独立样式按钮，放左下角空白处，不动原有美术布局。
	var offline_btn := Button.new()
	offline_btn.text = _menu_text("离线自测", "Offline")
	offline_btn.focus_mode = Control.FOCUS_NONE
	offline_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var ob_style := StyleBoxFlat.new()
	ob_style.bg_color = Color(1.0, 0.96, 0.82, 0.9)
	ob_style.border_color = Color(0.57, 0.38, 0.13)
	ob_style.set_border_width_all(2)
	ob_style.set_corner_radius_all(26)
	offline_btn.add_theme_stylebox_override("normal", ob_style)
	offline_btn.add_theme_stylebox_override("hover", ob_style)
	offline_btn.add_theme_stylebox_override("pressed", ob_style)
	offline_btn.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
	offline_btn.add_theme_font_size_override("font_size", 22)
	offline_btn.pressed.connect(_emit_offline)
	add_child(offline_btn)
	_track(offline_btn, Vector2(40, 876), Vector2(210, 54))

	# 游戏重连：放在"开始游戏（自定房间 970,724）"正上方，仅在本地存在重连凭证时显示。
	# 按它才连回上一场；按开始游戏则放弃旧局开新的一场。
	var reconnect_btn := Button.new()
	reconnect_btn.text = _menu_text("↩ 游戏重连", "↩ Reconnect")
	reconnect_btn.focus_mode = Control.FOCUS_NONE
	reconnect_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var rc_style := StyleBoxFlat.new()
	rc_style.bg_color = Color(0.24, 0.62, 0.32, 0.95)
	rc_style.border_color = Color(0.85, 0.98, 0.80)
	rc_style.set_border_width_all(3)
	rc_style.set_corner_radius_all(26)
	reconnect_btn.add_theme_stylebox_override("normal", rc_style)
	reconnect_btn.add_theme_stylebox_override("hover", rc_style)
	reconnect_btn.add_theme_stylebox_override("pressed", rc_style)
	reconnect_btn.add_theme_color_override("font_color", Color(1.0, 1.0, 0.95))
	reconnect_btn.add_theme_font_size_override("font_size", 26)
	reconnect_btn.pressed.connect(_emit_reconnect)
	# 仅在有重连凭证时才显示（没得连时不给一个点了没用的按钮）
	reconnect_btn.visible = not SaveManager.load_reconnect().is_empty()
	add_child(reconnect_btn)
	_track(reconnect_btn, Vector2(985, 656), Vector2(270, 58))

	_net_status = _add_label("", Vector2(640, 64), Vector2(320, 32), 20)
	_net_status.add_theme_color_override("font_color", Color(0.98, 0.88, 0.55))

	_address_edit = LineEdit.new()
	_address_edit.text = NetworkConfig.SERVER_IP
	_address_edit.visible = false
	add_child(_address_edit)

	_coming_soon = AcceptDialog.new()
	_coming_soon.title = ""
	_coming_soon.dialog_text = _menu_text("敬请期待", "Coming Soon")
	add_child(_coming_soon)
	_build_room_overlay()

func _build_room_overlay() -> void:
	_room_overlay = Control.new()
	_room_overlay.visible = false
	_room_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_room_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_room_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_room_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(920, 560)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.96, 0.84, 0.96)
	style.border_color = Color(0.58, 0.40, 0.16)
	style.set_border_width_all(4)
	style.set_corner_radius_all(24)
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

	left.add_child(_dialog_button(_menu_text("关闭", "Close"), func(): _room_overlay.visible = false))

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
	_room_overlay.visible = true
	_room_status.text = ""
	team_room_list_requested.emit()

func _show_token_prompt() -> void:
	_room_overlay.visible = true
	_room_status.text = _menu_text("输入 Token ID 后点恢复", "Enter Token ID, then Resume")
	_token_id_edit.grab_focus()

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

func _show_coming_soon() -> void:
	_coming_soon.popup_centered(Vector2(260, 120))

func _menu_text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh

func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var scale := minf(viewport_size.x / REF_SIZE.x, viewport_size.y / REF_SIZE.y)
	var origin := (viewport_size - REF_SIZE * scale) * 0.5
	for band in _screen_bands:
		var rect := band.node as Control
		var height := float(band.height) * scale
		rect.position = Vector2(0.0, viewport_size.y - height if bool(band.from_bottom) else float(band.y) * scale)
		rect.size = Vector2(viewport_size.x, height)
	for item in _placed:
		var node := item.node as Control
		var pos := item.pos as Vector2
		var size := item.size as Vector2
		node.position = origin + pos * scale
		node.size = size * scale
		if node is Label:
			node.add_theme_font_size_override("font_size", maxi(10, int(item.font_size * scale)))

func _add_texture(texture: Texture2D, pos: Vector2, size: Vector2) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	add_child(rect)
	_track(rect, pos, size)
	return rect

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

func _add_label(text: String, pos: Vector2, size: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
	label.add_theme_color_override("font_outline_color", Color(1.0, 0.94, 0.78))
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)
	_track(label, pos, size, font_size)
	return label

func _add_pill(text: String, pos: Vector2, size: Vector2) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1.0, 0.96, 0.82, 0.76)
	bg.border_color = Color(0.57, 0.38, 0.13)
	bg.set_border_width_all(2)
	bg.corner_radius_top_left = int(size.y * 0.5)
	bg.corner_radius_top_right = int(size.y * 0.5)
	bg.corner_radius_bottom_left = int(size.y * 0.5)
	bg.corner_radius_bottom_right = int(size.y * 0.5)
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)
	_track(panel, pos, size)
	_add_label(text, pos, size, 22)

func _add_hit(pos: Vector2, size: Vector2, cb: Callable) -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.modulate = Color(1, 1, 1, 0)
	btn.pressed.connect(cb)
	add_child(btn)
	_track(btn, pos, size)
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
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.94, 0.76, 0.95)
	style.border_color = Color(0.58, 0.40, 0.16)
	style.set_border_width_all(2)
	style.set_corner_radius_all(18)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
	btn.add_theme_font_size_override("font_size", 20)
	btn.pressed.connect(cb)
	return btn

func _track(node: Control, pos: Vector2, size: Vector2, font_size: int = 0) -> void:
	_placed.append({"node": node, "pos": pos, "size": size, "font_size": font_size})

func _bag_texture() -> Texture2D:
	var atlas := AtlasTexture.new()
	atlas.atlas = TEX_BAG
	atlas.region = Rect2(14, 14, 572, 572)
	return atlas
