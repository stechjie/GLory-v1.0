extends Control

signal start_requested
signal back_requested
signal selftest_requested

const REF_SIZE := Vector2(1672.0, 941.0)
const SLOT_LABELS := ["A", "B", "C", "1", "2", "3"]
const SLOT_POS := [
	Vector2(447, 229), Vector2(739, 229), Vector2(1015, 229),
	Vector2(447, 502), Vector2(739, 502), Vector2(1015, 502),
]
const SLOT_SIZE := Vector2(184, 175)
const TEX_BACKGROUND := preload("res://assets/ui/room_v2/background.png")
const TEX_BACK := preload("res://assets/ui/room_v2/back.png")
const TEX_TITLE := preload("res://assets/ui/room_v2/title.png")
const TEX_SLOT := preload("res://assets/ui/room_v2/slot.png")
const TEX_FRIENDS := preload("res://assets/ui/room_v2/friends.png")
const TEX_CHAT := preload("res://assets/ui/room_v2/chat.png")
const TEX_START := preload("res://assets/ui/room_v2/start.png")
const TEX_VS := preload("res://assets/ui/room/vs.png")
const MENU_MUSIC_PATH := "res://assets/audio/bgm/menu_music.mp3"

var _slot_states: Array = ["empty", "empty", "empty", "empty", "empty", "empty"]
var _slot_ready: Array = [false, false, false, false, false, false]
var _local_slot := 0

var _placed: Array[Dictionary] = []
var _slot_name_lbls: Array = []
var _slot_status_lbls: Array = []
var _slot_x_btns: Array = []
var _slot_ai_btns: Array = []
var _status_lbl: Label
var _room_id_lbl: Label
var _start_btn: Button
var _start_lbl: Label
var _host_hint_lbl: Label
var _selftest_btn: Button
var _screen_bands: Array[Dictionary] = []
var _menu_music_player: AudioStreamPlayer

func _ready() -> void:
	_slot_states[_local_slot] = "player"
	if not NetworkService.session_changed.is_connected(_on_session_changed):
		NetworkService.session_changed.connect(_on_session_changed)
	if not NetworkService.team_lobby_changed.is_connected(_on_session_changed):
		NetworkService.team_lobby_changed.connect(_on_session_changed)
	if not NetworkService.team_start_requested.is_connected(_on_team_start_requested):
		NetworkService.team_start_requested.connect(_on_team_start_requested)
	_build()
	_refresh()
	_layout()
	_start_menu_music()

func _start_menu_music() -> void:
	if _menu_music_player != null:
		return
	# 与摆放界面同款：必须用 load() 走资源系统，Android 导出包只含 mp3 的导入产物。
	var stream := load(MENU_MUSIC_PATH) as AudioStream
	if stream == null:
		push_warning("房间界面音乐读取失败：%s" % MENU_MUSIC_PATH)
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

func _exit_tree() -> void:
	if NetworkService.session_changed.is_connected(_on_session_changed):
		NetworkService.session_changed.disconnect(_on_session_changed)
	if NetworkService.team_lobby_changed.is_connected(_on_session_changed):
		NetworkService.team_lobby_changed.disconnect(_on_session_changed)
	if NetworkService.team_start_requested.is_connected(_on_team_start_requested):
		NetworkService.team_start_requested.disconnect(_on_team_start_requested)

func _online() -> bool:
	return NetworkService.team_active

func _states() -> Array:
	if _online() and NetworkService.team_slot_states.size() == 6:
		return NetworkService.team_slot_states
	if _online():
		return ["empty", "empty", "empty", "empty", "empty", "empty"]
	return _slot_states

# 房主席位号。联机局以服务端广播的 team_leader_slot 为准（它会因掉线顺延、
# 也会跟着换位搬走）；单机/本地调试没有服务端广播，退化为 0 号位。
func _leader_slot() -> int:
	return NetworkService.team_leader_slot if _online() else 0

func _ready_arr() -> Array:
	if _online() and NetworkService.team_ready.size() == 6:
		return NetworkService.team_ready
	if _online():
		return [false, false, false, false, false, false]
	return _slot_ready

func _my_slot() -> int:
	return NetworkService.team_local_slot if _online() else _local_slot

func _on_team_start_requested() -> void:
	start_requested.emit()

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = TEX_BACKGROUND
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# 左上返回、左下聊天框：锚定屏幕左边（edge="left"）
	_add_cropped_texture(TEX_BACK, Rect2(60, 118, 280, 164), Vector2(80, 35), Vector2(143, 83), "left")
	_add_hit(Vector2(80, 35), Vector2(143, 83), func(): back_requested.emit(), "left")
	_add_cropped_texture(TEX_TITLE, Rect2(158, 206, 964, 308), Vector2(599, 21), Vector2(475, 143))
	_room_id_lbl = _add_label("", Vector2(646, 72), Vector2(244, 30), 20, Color(0.45, 0.27, 0.08))
	_add_label(_room_text("自定义房间", "CUSTOM GAME"), Vector2(646, 31), Vector2(244, 42), 32)
	# 右侧朋友列表：锚定屏幕右边（edge="right"）
	_add_cropped_texture(TEX_FRIENDS, Rect2(324, 124, 432, 832), Vector2(1391, 181), Vector2(218, 400), "right")
	_add_label(_room_text("朋友列表", "Friends"), Vector2(1292, 226), Vector2(156, 42), 28, Color(0.47, 0.28, 0.08), "right")
	_add_cropped_texture(TEX_CHAT, Rect2(312, 194, 656, 332), Vector2(147, 704), Vector2(432, 212), "left")
	_add_label(_room_text("目前暂无聊天功能", "Chat coming soon"), Vector2(150, 870), Vector2(270, 34), 22, Color(0.53, 0.40, 0.27), "left")
	_add_texture(TEX_VS, Vector2(746, 427), Vector2(180, 85))

	_slot_name_lbls.resize(6)
	_slot_status_lbls.resize(6)
	_slot_x_btns.resize(6)
	_slot_ai_btns.resize(6)
	for i in 6:
		_build_slot(i)

	# 右下开始按钮组、自测、提示：锚定屏幕右边（edge="right"）
	_add_cropped_texture(TEX_START, Rect2(412, 264, 456, 192), Vector2(1306, 789), Vector2(267, 96), "right")
	_start_lbl = _add_label("", Vector2(1340, 812), Vector2(200, 42), 28, Color(0.96, 0.87, 0.70), "right")
	_start_btn = _add_hit(Vector2(1306, 789), Vector2(267, 96), _on_primary_pressed, "right")
	# 离线自测专用入口(officetest):开始游戏上方,仅离线显示,纯追加不动原布局。
	_selftest_btn = _add_ai_button(Vector2(1310, 719), Vector2(255, 55), func(): selftest_requested.emit(), "right")
	_selftest_btn.text = _room_text("自测开始", "Self-Test")
	_selftest_btn.add_theme_font_size_override("font_size", 24)
	_selftest_btn.visible = not _online()
	_host_hint_lbl = _add_label(_room_text("等待其他玩家准备后可按", "Waiting for players"), Vector2(1218, 934), Vector2(320, 30), 20, Color(1.0, 0.94, 0.78), "right")
	_status_lbl = _add_label("", Vector2(626, 167), Vector2(420, 28), 17, Color(0.98, 0.94, 0.78))

func _build_slot(index: int) -> void:
	var pos: Vector2 = SLOT_POS[index]
	_add_cropped_texture(TEX_SLOT, Rect2(0, 24, 388, 356), pos, SLOT_SIZE)
	_add_hit(pos + Vector2(25, 30), Vector2(140, 120), _on_slot_pressed.bind(index))
	var name_pos := Vector2(pos.x - 10, pos.y - 46) if index < 3 else Vector2(pos.x - 10, pos.y + SLOT_SIZE.y + 4)
	_slot_name_lbls[index] = _add_label("", name_pos, Vector2(SLOT_SIZE.x + 20, 36), 28)
	_slot_status_lbls[index] = _add_label("", pos + Vector2(34, 72), Vector2(122, 42), 20, Color(0.42, 0.28, 0.12))
	var x_btn := _add_x_button(pos + Vector2(138, 30), Vector2(38, 38), _on_slot_x.bind(index))
	_slot_x_btns[index] = x_btn
	var ai_btn := _add_ai_button(pos + Vector2(58, 132), Vector2(74, 34), _on_slot_ai.bind(index))
	_slot_ai_btns[index] = ai_btn

func _on_slot_pressed(index: int) -> void:
	if str(_states()[index]) != "empty":
		return
	var from := _my_slot()
	if from < 0:
		return
	if _online():
		NetworkService.team_request_move(index)
		return
	if str(_slot_states[from]) == "player":
		_slot_states[from] = "empty"
		_slot_ready[from] = false
	_slot_states[index] = "player"
	_local_slot = index
	_refresh()

func _on_slot_ai(index: int) -> void:
	if not _is_host_seat() or index == _my_slot():
		return
	var state := str(_states()[index])
	if state != "empty" and state != "dummy":
		return
	_toggle_dummy(index)

func _on_slot_x(index: int) -> void:
	if not _is_host_seat() or index == _my_slot():
		return
	var state := str(_states()[index])
	if state == "player":
		if _online():
			NetworkService.team_kick_slot(index)
	else:
		_toggle_dummy(index)

func _on_primary_pressed() -> void:
	if _is_host_seat():
		_on_start()
		return
	var my_slot := _my_slot()
	if my_slot < 0:
		return
	var now_ready := bool(_ready_arr()[my_slot])
	if _online():
		NetworkService.team_set_ready(not now_ready)
	else:
		_slot_ready[my_slot] = not now_ready
		_refresh()

func _toggle_dummy(index: int) -> void:
	if _online():
		NetworkService.team_toggle_slot(index)
		return
	var state := str(_slot_states[index])
	if state == "empty":
		_slot_states[index] = "dummy"
		_slot_ready[index] = true
	elif state == "dummy":
		_slot_states[index] = "empty"
		_slot_ready[index] = false
	_refresh()

func _refresh() -> void:
	var states := _states()
	var ready_arr := _ready_arr()
	var my_slot := _my_slot()
	var is_host_seat := _is_host_seat()
	for i in 6:
		var state := str(states[i])
		var name_lbl: Label = _slot_name_lbls[i]
		var status_lbl: Label = _slot_status_lbls[i]
		var x_btn: Button = _slot_x_btns[i]
		var ai_btn: Button = _slot_ai_btns[i]
		name_lbl.text = _slot_name(i, state, i == my_slot)
		match state:
			"player":
				# 房主席位不显示准备状态（他用的是"开始游戏"按钮）。
				# C25：此前写死 `i == 0`，而房主会因掉线顺延、也会因换位搬走
				# （见 C19/R5）——迁移之后 slot 0 上的普通玩家准备状态被隐藏，
				# 真正的房主又按普通玩家显示。改成认服务端广播的 leader_slot。
				status_lbl.text = "" if i == _leader_slot() else (tr("lobby_ready_done") if bool(ready_arr[i]) else tr("lobby_ready"))
			"dummy":
				status_lbl.text = _room_text("假想敌", "AI")
			_:
				status_lbl.text = _room_text("空位", "Empty")
		x_btn.visible = is_host_seat and i != my_slot and state != "empty"
		ai_btn.visible = is_host_seat and i != my_slot and (state == "empty" or state == "dummy")
		ai_btn.text = "- AI" if state == "dummy" else "+ AI"
	if _status_lbl != null:
		_status_lbl.text = _lobby_status_text()
	if _room_id_lbl != null:
		_room_id_lbl.text = _room_text("房间 ID：%d", "Room ID: %d") % NetworkService.team_room_id if _online() and NetworkService.team_room_id > 0 else ""
	if _start_btn != null:
		# 房主按钮不再因有人未准备而禁用——点了会显示具体原因（房主也不免检）
		_start_btn.disabled = false
	if _start_lbl != null:
		if is_host_seat:
			_start_lbl.text = _room_text("开始游戏", "Start Game")
		else:
			var ready := my_slot >= 0 and bool(_ready_arr()[my_slot])
			_start_lbl.text = tr("lobby_ready_done") if ready else tr("lobby_ready")
	if _host_hint_lbl != null:
		_host_hint_lbl.visible = is_host_seat
	if _selftest_btn != null:
		_selftest_btn.visible = not _online()

# 3v3 大厅状态：取代原先误显示的 1v1 session_label（棋盘/对手准备那套）。
func _lobby_status_text() -> String:
	var states := _states()
	var ready_arr := _ready_arr()
	var players := 0
	var ais := 0
	for i in 6:
		var st := str(states[i])
		if st == "player":
			players += 1
		elif st == "dummy":
			ais += 1
	var mode := _room_text("在线", "Online") if _online() else _room_text("离线", "Offline")
	# 房主视角把自己视为将 ready（按开始即准备）；具体阻止原因由 _start_block_reason 给。
	var reason := _start_block_reason(_is_host_seat())
	var tail := reason if not reason.is_empty() else _room_text("可以开始", "Ready to start")
	return _room_text("%s ｜ 玩家%d AI%d ｜ %s", "%s | Players %d AI %d | %s") % [mode, players, ais, tail]

func _slot_name(index: int, state: String, self_slot: bool) -> String:
	if state == "empty":
		return _room_text("空位 %s", "Empty %s") % SLOT_LABELS[index]
	var base := _room_text("玩家 %s", "Player %s") if state == "player" else _room_text("假想敌 %s", "AI %s")
	return (base % SLOT_LABELS[index]) + (_room_text("（你）", " (You)") if self_slot else "")

func _is_host_seat() -> bool:
	if _online():
		return NetworkService.can_control_room()
	return true

# 返回不能开始的原因（空字符串=可以开始）。房主不再免检：所有 player 座位都要 ready。
# host_ready=true 表示"把本地房主座位视为已准备"（房主按开始游戏即自动 ready）。
func _start_block_reason(host_ready: bool) -> String:
	var states := _states()
	var ready_arr: Array = _ready_arr().duplicate()
	var my_slot := _my_slot()
	if host_ready and my_slot >= 0 and my_slot < ready_arr.size():
		ready_arr[my_slot] = true
	if _online() and (states.size() < 6 or ready_arr.size() < 6):
		return _room_text("房间状态同步中", "Room state syncing")
	var side_a := 0
	var side_b := 0
	for i in 6:
		var state := str(states[i])
		if state == "player" and not bool(ready_arr[i]):
			return _room_text("玩家%s 还未准备", "Player %s is not ready") % SLOT_LABELS[i]
		if state != "empty":
			if i < 3:
				side_a += 1
			else:
				side_b += 1
	if side_a <= 0 or side_b <= 0:
		return _room_text("敌我双方都需要至少1个占位", "Both sides need at least one occupant")
	return ""

func _on_start() -> void:
	GameState.team_mode = true
	var my_slot := _my_slot()
	# 房主按开始游戏即自动提交自己的 ready（不再免检）
	if _online():
		if my_slot >= 0:
			NetworkService.team_set_ready(true)
	else:
		if my_slot >= 0 and my_slot < _slot_ready.size():
			_slot_ready[my_slot] = true
	# 有阻止原因就显示到状态栏、不开始
	var reason := _start_block_reason(true)
	if not reason.is_empty():
		_refresh()
		if _status_lbl != null:
			_status_lbl.text = reason
		return
	if _online():
		NetworkService.team_start()
		return
	GameState.team_slot_states = _slot_states.duplicate()
	start_requested.emit()

func _on_session_changed() -> void:
	_refresh()

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

func _add_texture(texture: Texture2D, pos: Vector2, size: Vector2, stretch := TextureRect.STRETCH_KEEP_ASPECT, edge: String = "") -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = stretch
	add_child(rect)
	_track(rect, pos, size, 0, edge)
	return rect

func _add_cropped_texture(texture: Texture2D, region: Rect2, pos: Vector2, size: Vector2, edge: String = "") -> TextureRect:
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = region
	return _add_texture(atlas, pos, size, TextureRect.STRETCH_KEEP_ASPECT, edge)

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

func _add_label(text: String, pos: Vector2, size: Vector2, font_size: int, color := Color(0.47, 0.28, 0.08), edge: String = "") -> Label:
	pos = _edge_label_pos(pos)
	size = _edge_label_size(pos, size)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(1.0, 0.94, 0.78))
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)
	_track(label, pos, size, font_size, edge)
	return label

func _edge_label_pos(pos: Vector2) -> Vector2:
	if pos == Vector2(646, 31):
		return Vector2(650, 51)
	if pos == Vector2(646, 72):
		return Vector2(712, 103)
	if pos == Vector2(1292, 226):
		return Vector2(1421, 199)
	if pos == Vector2(150, 870):
		return Vector2(186, 780)
	if pos == Vector2(1218, 934):
		return Vector2(1285, 880)
	return pos

func _edge_label_size(pos: Vector2, size: Vector2) -> Vector2:
	if pos == Vector2(650, 51):
		return Vector2(372, 48)
	if pos == Vector2(712, 103):
		return Vector2(250, 30)
	if pos == Vector2(1421, 199):
		return Vector2(158, 42)
	if pos == Vector2(186, 780):
		return Vector2(335, 36)
	if pos == Vector2(1285, 880):
		return Vector2(310, 28)
	return size

func _add_hit(pos: Vector2, size: Vector2, cb: Callable, edge: String = "") -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.modulate = Color(1, 1, 1, 0)
	btn.pressed.connect(cb)
	add_child(btn)
	_track(btn, pos, size, 0, edge)
	return btn

func _add_ai_button(pos: Vector2, size: Vector2, cb: Callable, edge: String = "") -> Button:
	var btn := Button.new()
	btn.text = "+ AI"
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", 15)
	btn.add_theme_color_override("font_color", Color(0.43, 0.26, 0.08))
	btn.add_theme_color_override("font_outline_color", Color(1.0, 0.94, 0.78))
	btn.add_theme_constant_override("outline_size", 2)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.93, 0.80, 0.82)
	sb.border_color = Color(0.70, 0.42, 0.14)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, sb)
	btn.pressed.connect(cb)
	add_child(btn)
	_track(btn, pos, size, 15, edge)
	return btn

func _add_x_button(pos: Vector2, size: Vector2, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = "X"
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", Color(0.82, 0.06, 0.08))
	btn.add_theme_color_override("font_outline_color", Color(1.0, 0.93, 0.76))
	btn.add_theme_constant_override("outline_size", 2)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.93, 0.80, 0.88)
	sb.border_color = Color(0.70, 0.42, 0.14)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(18)
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, sb)
	btn.pressed.connect(cb)
	add_child(btn)
	_track(btn, pos, size)
	return btn

func _track(node: Control, pos: Vector2, size: Vector2, font_size: int = 0, edge: String = "") -> void:
	_placed.append({"node": node, "pos": pos, "size": size, "font_size": font_size, "edge": edge})

func _room_text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
