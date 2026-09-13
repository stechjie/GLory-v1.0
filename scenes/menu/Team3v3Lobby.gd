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
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
var _slot_avatars: Array[TextureRect] = []
var _friends_box: VBoxContainer
var _friends_loading := false

func _reload_online_friends() -> void:
	if _friends_loading or not AccountManager.is_logged_in():
		return
	_friends_loading = true
	var result: Dictionary = await AccountManager.fetch_friends()
	_friends_loading = false
	if not is_inside_tree() or _friends_box == null:
		return
	if int(result.get("code", 0)) >= 200 and int(result.get("code", 0)) < 300:
		_render_online_friends((result.get("body", {}) as Dictionary).get("friends", []))

func _render_online_friends(friends: Array) -> void:
	for child in _friends_box.get_children():
		_friends_box.remove_child(child)
		child.queue_free()
	for entry in friends:
		if not entry is Dictionary or not bool(entry.get("online", false)):
			continue
		var label := Label.new()
		label.text = AccountManager.display_name(str(entry.get("player_name", "")), str(entry.get("friend_code", "")))
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_outline_color", Color(0.15, 0.1, 0.05))
		label.add_theme_constant_override("outline_size", 2)
		label.add_theme_font_size_override("font_size", 14)
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.tooltip_text = label.text
		_friends_box.add_child(label)

func _seat_profile(index: int) -> Dictionary:
	if index == _my_slot():
		return AccountManager.profile
	return NetworkService.team_seat_profiles.get(index, NetworkService.team_seat_profiles.get(str(index), {}))

func _publish_identity(_profile: Dictionary = {}) -> void:
	NetworkService.publish_lobby_identity()
	_refresh()

func _view_seat_profile(index: int) -> void:
	if index == _my_slot() or index < 0 or index >= _states().size() or str(_states()[index]) != "player":
		return
	var identity := _seat_profile(index)
	var code := str(identity.get("friend_code", ""))
	if code.length() != 8:
		DialogService.info({"owner": self, "body": _room_text("玩家资料正在加载，请稍后重试", "Player profile is loading. Please retry shortly.")})
		return
	var screen := load("res://scenes/menu/ProfileScreen.tscn").instantiate() as Control
	screen.configure_public(code)
	var modal_id := "lobby_player_profile"
	screen.back_requested.connect(func(): ModalStack.pop(modal_id))
	ModalStack.push(screen, {"id": modal_id, "owner": self, "priority": 50, "dismiss_on_backdrop": false})
const TEX_BACKGROUND := preload("res://assets/ui/room_v2/background.png")
const TEX_BACK := preload("res://assets/ui/room_v2/back.png")
const TEX_TITLE := preload("res://assets/ui/room_v2/title.png")
const TEX_SLOT := preload("res://assets/ui/room_v2/slot.png")
const TEX_FRIENDS := preload("res://assets/ui/room_v2/friends.png")
const TEX_CHAT := preload("res://assets/ui/room_v2/chat.png")
const TEX_START := preload("res://assets/ui/room_v2/start.png")
const TEX_VS := preload("res://assets/ui/room/vs.png")
const MENU_MUSIC_PATH := "res://assets/audio/bgm/menu_music.mp3"
const SELFTEST_SCENE_PATH := "res://officetest/OfficeTestScreen.tscn"

# ── 布局调试overlay ────────────────────────────────────────────────
# 与主界面同款：黑线 = 空间划分（参考画布边界 / 功能分区 / 席位格 / 每个元素占位框）
#               红线 = 所有按钮的点击判定区（返回 / 入座 / X / ±AI / 自测 / 开始）
# 游戏里按 F3 开关。调完把 DEBUG_LAYOUT 改回 false 即可。
const DEBUG_LAYOUT := false
# 参考画布(1672x941)下的功能分区，只用于画黑色分区带；首尾相接，覆盖整块画布
const DEBUG_BANDS := [
	{"name": "顶部标题区", "y": 0.0, "h": 164.0},
	{"name": "状态/资源行 + 我方名牌", "y": 164.0, "h": 60.0},
	{"name": "我方席位 A/B/C", "y": 224.0, "h": 186.0},
	{"name": "VS 分隔带", "y": 410.0, "h": 92.0},
	{"name": "敌方席位 1/2/3", "y": 502.0, "h": 175.0},
	{"name": "底部：敌方名牌 / 聊天 / 开始", "y": 677.0, "h": 264.0},
]

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
var _debug_layer: Control
var _debug_on := DEBUG_LAYOUT
var _layout_scale := 1.0
var _layout_origin := Vector2.ZERO

func _ready() -> void:
	AccountManager.profile_changed.connect(_publish_identity)
	_slot_states[_local_slot] = "player"
	if not NetworkService.session_changed.is_connected(_on_session_changed):
		NetworkService.session_changed.connect(_on_session_changed)
	if not NetworkService.team_lobby_changed.is_connected(_on_session_changed):
		NetworkService.team_lobby_changed.connect(_on_session_changed)
	if not NetworkService.team_start_requested.is_connected(_on_team_start_requested):
		NetworkService.team_start_requested.connect(_on_team_start_requested)
	if not NetworkService.team_chat_received.is_connected(_on_chat_received):
		NetworkService.team_chat_received.connect(_on_chat_received)
	if not NetworkService.team_chat_text_received.is_connected(_on_chat_text_received):
		NetworkService.team_chat_text_received.connect(_on_chat_text_received)
	_build()
	_refresh()
	var friends_timer := Timer.new()
	friends_timer.wait_time = 5.0
	friends_timer.autostart = true
	friends_timer.timeout.connect(_reload_online_friends)
	add_child(friends_timer)
	_reload_online_friends()
	NetworkService.publish_lobby_identity()
	var identity_retry := Timer.new()
	identity_retry.wait_time = 10.0
	identity_retry.autostart = true
	identity_retry.timeout.connect(func():
		if _online() and not NetworkService.team_seat_profiles.has(_my_slot()):
			NetworkService.publish_lobby_identity())
	add_child(identity_retry)
	# 必须在 _layout() 之前：_add_label 只是把控件登记进 _placed，
	# 真正定位是 _layout() 干的。放在它后面创建的标签会停在默认位置、看不见。
	_setup_asset_loader()
	_layout()
	_start_menu_music()

# --- 开局资源预载 --------------------------------------------------------------
#
# 大厅是整个流程里唯一真正空闲的窗口：玩家在等人进房，画面基本静止。
# 备战期不行 —— 那时玩家在拖棋子、看羁绊，3D 棋盘和 UI 都在跑，往里塞几百 MB
# 会直接卡到操作。战斗开始前更不行，那是玩家已经在等的时刻。
#
# 分两段，因为 shared_seed 到达有先后：
#   A 段（进大厅立刻）：与 seed 无关 —— 外部 VFX 8 类、商店池全部候选
#   B 段（收到 seed 后）：本局怪物 / Boss 名单，预载前 3 轮
#
# 只发请求 + 逐帧收割，不阻塞。玩家随时可以按开始 —— 没加载完的部分由
# PrepScreen 的读条兜底。
const ASSET_LOAD_TICK := 0.25

var _asset_total := 0
var _asset_seed_stage_done := false
var _asset_tick := 0.0
var _asset_lbl: Label

func _setup_asset_loader() -> void:
	var vfx := BattleAssetManifest.seed_independent_paths()
	var shop := BattleAssetManifest.shop_pool_paths()
	BattleAssetService.acquire_many(vfx, BattleAssetService.OWNER_PLAYER)
	BattleAssetService.acquire_many(shop, BattleAssetService.OWNER_PLAYER)
	_asset_total = BattleAssetService.pending_count()
	print("[ASSET] 大厅预载启动：外部VFX %d 个、商店池 %d 个 -> 待加载 %d 个"
		% [vfx.size(), shop.size(), _asset_total])
	# Keep preload progress outside the center status/seat-name band. The previous
	# 626..1046 × 197..221 rectangle crossed the top B/C seat titles on device.
	_asset_lbl = _add_label("", Vector2(1340, 600), Vector2(230, 28), 14,
		Color(0.62, 0.86, 0.98), "right")
	set_process(true)

func _process(delta: float) -> void:
	_asset_tick += delta
	if _asset_tick < ASSET_LOAD_TICK:
		return
	_asset_tick = 0.0
	# seed 是服务器在开打时下发的；一旦拿到就把本局名单也排进来。
	if not _asset_seed_stage_done and BattleAssetManifest.has_seed():
		_asset_seed_stage_done = true
		var by_round := BattleAssetManifest.rounds_enemy_paths(
			GameState.round_index, BattleAssetManifest.LOOKAHEAD_ROUNDS)
		for n in by_round:
			BattleAssetService.acquire_many(
				by_round[n], BattleAssetService.owner_future(int(n)))
		_asset_total = maxi(_asset_total, BattleAssetService.pending_count())
	var pending := BattleAssetService.harvest()
	if _asset_lbl == null:
		return
	if pending == 0:
		print("[ASSET] 大厅预载完成：缓存 %d 个场景" % BattleAssetService.cached_count())
		_asset_lbl.text = "资源已就绪"
		set_process(false)
		return
	var done := maxi(0, _asset_total - pending)
	_asset_lbl.text = "资源载入 %d%%" % int(round(100.0 * float(done) / maxf(1.0, float(_asset_total))))

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
	if NetworkService.team_chat_received.is_connected(_on_chat_received):
		NetworkService.team_chat_received.disconnect(_on_chat_received)
	if NetworkService.team_chat_text_received.is_connected(_on_chat_text_received):
		NetworkService.team_chat_text_received.disconnect(_on_chat_text_received)
	if VoiceService.mode_changed.is_connected(_on_voice_mode_changed):
		VoiceService.mode_changed.disconnect(_on_voice_mode_changed)

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
	_add_texture(TEX_BACK, Vector2(80, 35), Vector2(143, 83), "left")
	_add_hit(Vector2(80, 35), Vector2(143, 83), func(): back_requested.emit(), "left", "hit_back")
	_add_texture(TEX_TITLE, Vector2(599, 21), Vector2(475, 143))
	_room_id_lbl = _add_label("", Vector2(712, 103), Vector2(250, 30), 20, Color(0.45, 0.27, 0.08))
	_add_label(_room_text("自定义房间", "CUSTOM GAME"), Vector2(650, 51), Vector2(372, 48), 32)
	# 右侧朋友列表：锚定屏幕右边（edge="right"）
	_add_texture(TEX_FRIENDS, Vector2(1340, 180), Vector2(230, 400), "right")
	_add_label(_room_text("朋友列表", "Friends"), Vector2(1340, 215), Vector2(230, 42), 28, Color(0.47, 0.28, 0.08), "right")
	var friends_scroll := ScrollContainer.new()
	friends_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(friends_scroll)
	_track(friends_scroll, Vector2(1350, 270), Vector2(210, 290), 0, "right")
	_friends_box = VBoxContainer.new()
	_friends_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	friends_scroll.add_child(_friends_box)
	_add_texture(TEX_CHAT, Vector2(80, 704), Vector2(430, 210), "left")
	_build_chat_box()
	_add_texture(TEX_VS, Vector2(746, 427), Vector2(180, 85))

	_slot_name_lbls.resize(6)
	_slot_status_lbls.resize(6)
	_slot_x_btns.resize(6)
	_slot_ai_btns.resize(6)
	_slot_avatars.resize(6)
	for i in 6:
		_build_slot(i)

	# 右下开始按钮组、自测、提示：锚定屏幕右边（edge="right"）
	_add_texture(TEX_START, Vector2(1300, 760), Vector2(270, 130), "right")
	_start_lbl = _add_label("", Vector2(1300, 790), Vector2(270, 95), 28, Color(0.96, 0.87, 0.70), "right")
	_start_btn = _add_hit(Vector2(1300, 790), Vector2(270, 95), _on_primary_pressed, "right", "hit_start")
	# 离线自测专用入口(officetest):开始游戏上方,仅离线显示,纯追加不动原布局。
	#
	# V3 P1-07 先加了 debug 守卫；V12-12 再补资源能力判断。普通 Debug APK
	# 同样会按 preset 排除 officetest/，所以只看 is_debug_build() 仍会显示死入口。
	_selftest_btn = _add_ai_button(Vector2(1310, 719), Vector2(255, 55), func(): selftest_requested.emit(), "right", "btn_selftest", 24)
	_selftest_btn.text = _room_text("自测开始", "Self-Test")
	_selftest_btn.visible = selftest_available() and not _online()
	_host_hint_lbl = _add_label(_room_text("等待其他玩家准备后可按", "Waiting for players"), Vector2(1285, 880), Vector2(310, 28), 20, Color(1.0, 0.94, 0.78), "right")
	_status_lbl = _add_label("", Vector2(626, 142), Vector2(420, 28), 17, Color(0.98, 0.94, 0.78))
	_build_debug_layer()

func _build_slot(index: int) -> void:
	var pos: Vector2 = SLOT_POS[index]
	_add_texture(TEX_SLOT, pos, SLOT_SIZE)
	var avatar := _add_texture(null, pos + Vector2(39, 40), Vector2(106, 106))
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; void fragment(){vec4 c=texture(TEXTURE,UV); c.a*=1.0-smoothstep(0.48,0.5,length(UV-vec2(0.5))); COLOR=c;}"
	var material := ShaderMaterial.new()
	material.shader = shader
	avatar.material = material
	_slot_avatars[index] = avatar
	_add_hit(pos + Vector2(0, 0), Vector2(182, 125), _on_slot_pressed.bind(index),
		"", "hit_slot_%s" % SLOT_LABELS[index])
	var name_pos := Vector2(pos.x - 10, pos.y - 46) if index < 3 else Vector2(pos.x - 10, pos.y + SLOT_SIZE.y + 4)
	_slot_name_lbls[index] = _add_label("", name_pos, Vector2(SLOT_SIZE.x + 20, 36), 28)
	_slot_status_lbls[index] = _add_label("", pos + Vector2(34, 72), Vector2(122, 42), 20, Color(0.42, 0.28, 0.12))
	var x_btn := _add_x_button(pos + Vector2(138, 30), Vector2(38, 38), _on_slot_x.bind(index),
		"btn_kick_%s" % SLOT_LABELS[index])
	_slot_x_btns[index] = x_btn
	var ai_btn := _add_ai_button(pos + Vector2(51, 133), Vector2(80, 40), _on_slot_ai.bind(index),
		"", "btn_ai_%s" % SLOT_LABELS[index])
	_slot_ai_btns[index] = ai_btn

func _on_slot_pressed(index: int) -> void:
	if str(_states()[index]) == "player":
		if index != _my_slot():
			_view_seat_profile(index)
		return
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
		name_lbl.text = _slot_name(i, state, false)
		var identity := _seat_profile(i)
		_slot_avatars[i].visible = state == "player"
		if state == "player":
			_slot_avatars[i].texture = AvatarCatalog.texture_for(str(identity.get("avatar", AvatarCatalog.default_avatar())))
			if not identity.is_empty():
				name_lbl.text = AccountManager.display_name(str(identity.get("player_name", "")), str(identity.get("friend_code", "")))
			name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var is_me := state == "player" and i == my_slot
		if is_me:
			var suffix := _room_text("（我）", " (Me)")
			var base_name := name_lbl.text
			var font := name_lbl.get_theme_font("font")
			# 给身份后缀预留宽度，长昵称不能把“我”挤出省略区域。
			while base_name.length() > 1 and font.get_string_size(base_name + suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x > SLOT_SIZE.x + 12:
				base_name = base_name.left(base_name.length() - 1)
			if base_name != name_lbl.text:
				base_name = base_name.left(maxi(0, base_name.length() - 1)) + "…"
			name_lbl.text = base_name + suffix
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.82, 0.18) if is_me else Color(0.47, 0.28, 0.08))
		name_lbl.add_theme_color_override("font_outline_color", Color(0.22, 0.12, 0.02) if is_me else Color(1.0, 0.94, 0.78))
		for placement in _placed:
			if placement.node == name_lbl:
				placement.font_size = 20 if state == "player" else 28
			if placement.node == status_lbl:
				placement.pos = SLOT_POS[i] + (Vector2(39, 137) if state == "player" else Vector2(34, 72))
				placement.size = Vector2(106, 32) if state == "player" else Vector2(122, 42)
				placement.font_size = 17 if state == "player" else 20
		match state:
			"player":
				# 使用当前房主席位，兼容换位及房主迁移。
				status_lbl.text = _room_text("房主", "Host") if i == _leader_slot() else (_room_text("准备", "Ready") if bool(ready_arr[i]) else _room_text("未准备", "Not ready"))
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
		_selftest_btn.visible = selftest_available() and not _online()


func selftest_available() -> bool:
	# Debug is necessary but not sufficient: normal debug APKs deliberately exclude
	# officetest/. Capability-gating prevents a visible button whose scene cannot load.
	return OS.is_debug_build() and ResourceLoader.exists(SELFTEST_SCENE_PATH, "PackedScene")

# 3v3 大厅状态：取代原先误显示的 1v1 session_label（棋盘/对手准备那套）。
func _lobby_status_text() -> String:
	var states := _states()
	var players := 0
	var ais := 0
	for i in 6:
		var st := str(states[i])
		if st == "player":
			players += 1
		elif st == "dummy":
			ais += 1
	var mode := _room_text("在线", "Online") if _online() else _room_text("离线", "Offline")
	var reason := _start_block_reason(true)
	var tail := reason if not reason.is_empty() else (_room_text("可以开始", "Ready to start") if _is_host_seat() else _room_text("等待房主开始游戏", "Waiting for host to start"))
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
	var leader := _leader_slot()
	if host_ready and leader >= 0 and leader < ready_arr.size():
		ready_arr[leader] = true
	if _online() and (states.size() < 6 or ready_arr.size() < 6):
		return _room_text("房间状态同步中", "Room state syncing")
	var side_a := 0
	var side_b := 0
	for i in 6:
		var state := str(states[i])
		if state != "empty":
			if i < 3:
				side_a += 1
			else:
				side_b += 1
	if side_a <= 0 or side_b <= 0:
		return _room_text("敌我双方至少一个占位", "Both sides need at least one occupant")
	for i in 6:
		if str(states[i]) == "player" and not bool(ready_arr[i]):
			return _room_text("有玩家未准备", "Some players are not ready")
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
		return
	if _online():
		NetworkService.team_start()
		return
	GameState.team_slot_states = _slot_states.duplicate()
	start_requested.emit()

func _on_session_changed() -> void:
	_refresh()
	_layout()
	# 换座位**不要**重发身份：服务端 _room_do_move 会把 seat_profiles 随座位
	# 一起搬（SEAT_SLOT_MAPS），换位后各端看到的身份本来就是对的。
	# 此前这里每次换座都 publish_lobby_identity()，连续快速换座会在 10 秒
	# 窗口里打出多条身份上报，曾触发服务端限流踢线（换座 6 次必掉线 bug）。
	# 身份需要（重新）上报的场景只剩三个，都已各自覆盖：
	#   进大厅（_ready）、账号资料变更（profile_changed 信号）、
	#   座位上迟迟没有身份（下方 10 秒重试定时器）。

func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var scale := minf(viewport_size.x / REF_SIZE.x, viewport_size.y / REF_SIZE.y)
	var origin := (viewport_size - REF_SIZE * scale) * 0.5
	_layout_scale = scale
	_layout_origin = origin
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
		# 字号也要跟着缩放，否则窗口一小文字就撑破按钮框、窗口一大文字又显得过小。
		# font_size=0 的（纯判定区 _add_hit）没有文字，跳过。
		if int(item.font_size) > 0 and (node is Label or node is Button):
			node.add_theme_font_size_override("font_size", maxi(10, int(item.font_size * scale)))
	if _debug_layer != null:
		_debug_layer.queue_redraw()

# 素材都是裁好的成品图（一张 PNG = 一个元素），所以整张画、不再做图集裁切。
# STRETCH_SCALE = 拉满给定的框，不保持原始宽高比：框写多大就画多大，
# 不会像 KEEP_ASPECT 那样在框里居中留边。想要不变形就把框调成图的比例。
func _add_texture(texture: Texture2D, pos: Vector2, size: Vector2, edge: String = "") -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	if texture == TEX_CHAT:
		var chat_material := ShaderMaterial.new()
		chat_material.shader = preload("res://scenes/menu/chat_no_badge.gdshader")
		rect.material = chat_material
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(rect)
	_track(rect, pos, size, 0, edge)
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

func _add_label(text: String, pos: Vector2, size: Vector2, font_size: int, color := Color(0.47, 0.28, 0.08), edge: String = "") -> Label:
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

func _add_hit(pos: Vector2, size: Vector2, cb: Callable, edge: String = "", dbg_name: String = "") -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.modulate = Color(1, 1, 1, 0)
	btn.pressed.connect(cb)
	if not dbg_name.is_empty():
		btn.name = dbg_name
	add_child(btn)
	_track(btn, pos, size, 0, edge)
	return btn

func _add_ai_button(pos: Vector2, size: Vector2, cb: Callable, edge: String = "", dbg_name: String = "", font_size: int = 15) -> Button:
	var btn := Button.new()
	btn.text = "+ AI"
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", font_size)
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
	if not dbg_name.is_empty():
		btn.name = dbg_name
	add_child(btn)
	_track(btn, pos, size, font_size, edge)
	return btn

func _add_x_button(pos: Vector2, size: Vector2, cb: Callable, dbg_name: String = "") -> Button:
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
	if not dbg_name.is_empty():
		btn.name = dbg_name
	add_child(btn)
	_track(btn, pos, size, 18)
	return btn

func _track(node: Control, pos: Vector2, size: Vector2, font_size: int = 0, edge: String = "") -> void:
	_placed.append({"node": node, "pos": pos, "size": size, "font_size": font_size, "edge": edge})

# ── 房间快捷短语（docs/聊天系统设计.md 批次 A）────────────────────────────
# 预留位置就是原来那句「目前暂无聊天功能」所在的 TEX_CHAT 框：(80,704) 430×210。
#
# ⚠️ 这块是 edge="left" 左锚列的**宽度基准** —— 见 _draw_debug_layer 里那句
# 「左列最宽的是聊天框(147+432)」。往右扩会推动 edge=left 那条分界线，
# 进而影响所有左锚元素的位置。改宽度前先按 F3 看一眼那条线。
#
# 网络上只走 phrase_id，文本在本地查表。理由见 ChatPhrases.gd 顶部。

const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")
# 自由文字（批次 D）：输入条贴在屏幕顶部，理由见 ChatInputBar.gd 顶部（手机键盘）。
const ChatInputBar := preload("res://ui/components/ChatInputBar.gd")

# 短语面板的样式与控件**直接复用备战期那套**（PrepWidgets），不是照着抄一份参数。
# 它是「全静态、不持任何界面状态」的工具箱，且 make_menu_button 的注释写着
# 「仿主界面『离线自测』样式」—— 在大厅用它是回到本源，不是跨界引用。
# 这样两个界面的短语按钮是**同一份样式代码**，不存在改了一边忘了另一边。
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")

const CHAT_LINES := 4                              # 210 高的框放得下的行数上限
const CHAT_LINE_H := 28.0
# 🔴 文字区不能贴聊天框的边（框是 80,704 430×210），要让开贴图自带的边框装饰。
# 实测两轮（tools/chat_ui_capture.tscn 出的图）：714 时第一行上半截被压住，
# 726 仍蹭到，732 才干净；左边同理，96 时首字紧贴边框，收到 104。
# **这件事在代码里完全看不出来，只有出图才看得见** —— 那个截图工具因此值得留着。
# 框内可用区约 732 ~ 890：4 行 ×28 = 112 到 844，底下 848 起是短语入口，正好填满。
const CHAT_FIRST_LINE_Y := 732.0
const CHAT_ENTRY_Y := 848.0
const CHAT_TEXT_X := 104.0
const CHAT_TEXT_W := 392.0                         # 右边界 496，与下面那块判定区一致
# 🔴 消息那 4 行还要再让开贴图左上角自带的**对话气泡图标**（约 x 97~130、y 725~762）。
# 上面的 732 / 104 只让开了边框，气泡图标仍压着第一行开头两个字 ——
# 2026-09-11 把截图放大两倍才看清，原尺寸下它像是边框的一部分。
# 只动消息列，不动下面的入口行（图标够不到 848 那一行）。
# 右边界不变（496），一行少放一两个字；折行按 CHAT_MSG_W 算，不会被截断。
const CHAT_MSG_X := 138.0
const CHAT_MSG_W := 358.0
const CHAT_TEXT_COLOR := Color(0.53, 0.40, 0.27)   # 沿用原占位文字的颜色
# 入口那一行对半分：左「快捷短语」、右「打字」（批次 D）。
const CHAT_ENTRY_SPLIT := 196.0

# 短语面板：从聊天框顶部往上弹。往下、往左都没地方 —— 聊天框已经贴着左下角。
#
# 宽度刻意收到 360（比聊天框的 430 窄）：再宽就会盖到敌方席位 1 的左半边
# （SLOT_POS[3] 的 x 是 447）。面板是临时 UI，盖住一点无所谓，但能不盖就不盖。
const PHRASE_PANEL_POS := Vector2(80, 392)
const PHRASE_PANEL_SIZE := Vector2(360, 304)
const PHRASE_BTN_SIZE := Vector2(162, 40)
const PHRASE_BTN_STEP := Vector2(170, 48)          # 按钮间距 8
const PHRASE_BTN_ORIGIN := Vector2(92, 404)        # 面板内边距 12
const PHRASE_BTN_FONT := 15
const PHRASE_COLUMNS := 2

var _chat_labels: Array[Label] = []
var _chat_history: Array[String] = []
var _phrase_panel: Panel = null
var _phrase_buttons: Array[Button] = []
var _phrase_btn_label: Label = null
var _type_btn_label: Label = null

func _build_chat_box() -> void:
	# 必须在 _layout() 之前被调用（_build 里）—— _add_label 只是登记进 _placed，
	# 真正定位是 _layout() 干的。同 _ready 里那条注释。
	for i in CHAT_LINES:
		var lbl := _add_label("", Vector2(CHAT_MSG_X, CHAT_FIRST_LINE_Y + i * CHAT_LINE_H),
			Vector2(CHAT_MSG_W, CHAT_LINE_H), CHAT_FONT_SIZE, CHAT_TEXT_COLOR, "left")
		# _add_label 默认居中。聊天是逐行累积的文本，居中会让每来一条整块字都在跳。
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		# 昵称最长 24 字，一行放不下时截断而不是把框撑破。
		lbl.clip_text = true
		_chat_labels.append(lbl)
	_phrase_btn_label = _add_label(_room_text("＋ 快捷短语", "＋ Quick chat"),
		Vector2(CHAT_TEXT_X, CHAT_ENTRY_Y), Vector2(CHAT_ENTRY_SPLIT, 40), 20, CHAT_TEXT_COLOR, "left")
	_phrase_btn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_add_hit(Vector2(CHAT_TEXT_X, CHAT_ENTRY_Y), Vector2(CHAT_ENTRY_SPLIT, 40), _toggle_phrase_panel,
		"left", "hit_chat_phrase")
	_type_btn_label = _add_label(_room_text("＋ 打字", "＋ Type"),
		Vector2(CHAT_TEXT_X + CHAT_ENTRY_SPLIT, CHAT_ENTRY_Y),
		Vector2(CHAT_TEXT_W - CHAT_ENTRY_SPLIT, 40), 20, CHAT_TEXT_COLOR, "left")
	_type_btn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	# 右半边判定区的右边界 496，**刻意把贴图右下角那个黄色箭头也圈进来** ——
	# 那个箭头是聊天框贴图自带的，看着就是「发送」，玩家一定会去点它。
	# 圈不进来的话它点了没反应，而没反应的按钮比没有按钮更让人困惑。
	# 批次 A 时它归「快捷短语」；有了打字之后归「打字」，语义更对得上。
	_add_hit(Vector2(CHAT_TEXT_X + CHAT_ENTRY_SPLIT, CHAT_ENTRY_Y),
		Vector2(CHAT_TEXT_W - CHAT_ENTRY_SPLIT, 40), _open_text_input, "left", "hit_chat_text")
	_build_voice_button()
	_build_phrase_panel()
	_refresh_chat()

# 语音按钮（docs/聊天系统设计.md 第九节）：一个按钮三档循环，关 → 只听 → 开麦。
# 放在聊天框正上方（x 180~330、y 650~696）：左边是石柱装饰，右边从 x=447 起是敌方席位 1。
# 短语面板打开时会盖住它（面板 z=40），面板本来就是临时的。
const VOICE_BTN_POS := Vector2(180, 650)
const VOICE_BTN_SIZE := Vector2(150, 46)
const VOICE_BTN_FONT := 18
var _voice_button: Button = null

func _build_voice_button() -> void:
	_voice_button = PrepWidgets.make_menu_button(VoiceService.mode_label(), VOICE_BTN_SIZE,
		VOICE_BTN_FONT, _on_voice_pressed)
	# 同短语按钮：清掉 make_menu_button 设的最小尺寸，否则窗口缩小时被顶回原尺寸（见 _build_phrase_panel）。
	_voice_button.custom_minimum_size = Vector2.ZERO
	_voice_button.name = "VoiceToggle"
	add_child(_voice_button)
	_track(_voice_button, VOICE_BTN_POS, VOICE_BTN_SIZE, VOICE_BTN_FONT, "left")
	if not VoiceService.mode_changed.is_connected(_on_voice_mode_changed):
		VoiceService.mode_changed.connect(_on_voice_mode_changed)
	# 按钮后面的「●」跟着有没有人在说话变，0.25 秒刷一次（插件那边的状态也是这个节奏）。
	var timer := Timer.new()
	timer.wait_time = 0.25
	timer.autostart = true
	timer.timeout.connect(_refresh_voice_button)
	add_child(timer)

func _on_voice_pressed() -> void:
	var reason := VoiceService.cycle_mode()
	if not reason.is_empty():
		DialogService.info({"owner": self, "body": reason})
	_refresh_voice_button()

func _on_voice_mode_changed(_mode: int) -> void:
	_refresh_voice_button()

func _refresh_voice_button() -> void:
	if _voice_button != null and is_instance_valid(_voice_button):
		_voice_button.text = VoiceService.mode_label() + VoiceService.activity_mark()

func _build_phrase_panel() -> void:
	# 面板与按钮**都在 _build 期建好、默认隐藏**，不是点开时才创建。
	# 这是被 _layout() 逼出来的：它只给 _placed 里登记过的控件定位与缩放，
	# 而登记发生在创建时。点开时才 new 的控件不在 _placed 里，
	# 会停在默认位置（左上角、原始尺寸）—— 那正是 _ready() 里那句
	# 「放在 _layout() 后面创建的标签会停在默认位置、看不见」说的坑。
	_phrase_panel = Panel.new()
	_phrase_panel.name = "PhrasePanel"
	# 与备战期那块面板同一套参数（PrepUI._build_chat_panel）。
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.075, 0.095, 0.055, 0.96)
	style.border_color = Color(0.78, 0.57, 0.20, 0.92)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_phrase_panel.add_theme_stylebox_override("panel", style)
	# 面板与按钮都要盖在后面才创建的席位/开始按钮之上，所以显式给 z_index，
	# 不依赖 add_child 的先后顺序（_build_chat_box 在 _build 中段就被调了）。
	_phrase_panel.z_index = 40
	_phrase_panel.visible = false
	add_child(_phrase_panel)
	_track(_phrase_panel, PHRASE_PANEL_POS, PHRASE_PANEL_SIZE, 0, "left")

	# 按 id 升序铺 2 列。**不放分组标题** —— 两列网格里塞不下，
	# 备战期那块也没有，两边保持一致。12 条扫一眼就完了，标题是噪音。
	var index := 0
	for group in ChatPhrases.GROUP_ORDER:
		for phrase_id in ChatPhrases.ids_in_group(group):
			var btn := PrepWidgets.make_menu_button(
				ChatPhrases.text(phrase_id), PHRASE_BTN_SIZE, PHRASE_BTN_FONT,
				_on_phrase_picked.bind(int(phrase_id)))
			# 🔴 必须清掉。make_menu_button 会设 custom_minimum_size = size，
			# 而 Control.size 的 setter 会把值 clamp 到 custom_minimum_size ——
			# 于是 _layout() 在窗口缩小（scale < 1）时设的尺寸会被顶回原值，
			# 按钮不缩小、整块布局散开。备战期那边不用清，它走的是容器布局。
			btn.custom_minimum_size = Vector2.ZERO
			btn.z_index = 41
			btn.visible = false
			add_child(btn)
			_track(btn, PHRASE_BTN_ORIGIN + Vector2(
				float(index % PHRASE_COLUMNS) * PHRASE_BTN_STEP.x,
				float(index / PHRASE_COLUMNS) * PHRASE_BTN_STEP.y),
				PHRASE_BTN_SIZE, PHRASE_BTN_FONT, "left")
			_phrase_buttons.append(btn)
			index += 1

func _toggle_phrase_panel() -> void:
	if not _online():
		DialogService.info({"owner": self,
			"body": _room_text("联机对局中才能发送", "Available in online matches only")})
		return
	_set_phrase_panel_visible(not _phrase_panel.visible)

func _set_phrase_panel_visible(shown: bool) -> void:
	if _phrase_panel == null or not is_instance_valid(_phrase_panel):
		return
	_phrase_panel.visible = shown
	for btn in _phrase_buttons:
		btn.visible = shown

func _on_phrase_picked(phrase_id: int) -> void:
	# 只发不显示。本地回显要等服务器广播回来 —— 服务器是唯一定序者，
	# 本地抢先显示会让自己看到的顺序和别人不一样。见 NetworkService.team_send_phrase。
	NetworkService.team_send_phrase(phrase_id)
	# 发完收起，同备战期。面板压着敌方席位的一角，没理由让它一直开着。
	_set_phrase_panel_visible(false)

func _on_chat_received(slot: int, phrase_id: int) -> void:
	var body := ChatPhrases.text(phrase_id)
	if body.is_empty():
		# id 不合法。ChatPhrases.text() 刻意返回空串而不是「未知短语」这类占位符 ——
		# 占位符会让一个协议错误在界面上长得像一条正常消息，于是没人会去查。
		return
	_push_chat_entry("%s：%s" % [_chat_speaker_name(slot), body])


func _on_chat_text_received(slot: int, text: String) -> void:
	_push_chat_entry("%s：%s" % [_chat_speaker_name(slot), text])


# 打字入口（批次 D）。离线时同短语那句提示 —— 一个点了没反应的入口比没有更让人困惑。
func _open_text_input() -> void:
	if not _online():
		DialogService.info({"owner": self,
			"body": _room_text("联机对局中才能发送", "Available in online matches only")})
		return
	_set_phrase_panel_visible(false)
	ChatInputBar.new().present(self, func(text: String) -> String:
		return NetworkService.team_send_text(text))


# 一条消息可能占好几行（自由文字最多 40 字，加上昵称一行放不下）。
# 按聊天框的实际宽度折好行再进历史，4 行放不下时最老的行先出去。
#
# 不改用 Label 自带的自动折行：这 4 行是 _placed 登记的固定位置标签，
# 换成一个自动折行的大标签会动到批次 A 已经出图验过的版面。
func _push_chat_entry(line: String) -> void:
	for part in _wrap_chat_line(line):
		_chat_history.append(part)
	while _chat_history.size() > CHAT_LINES:
		_chat_history.pop_front()
	_refresh_chat()


# 消息标签的字号（_build_chat_box 建标签用的也是它）。
const CHAT_FONT_SIZE := 19
# 不能出现在行首的标点（中文排版的「避头」）。碰到它们换行时，把上一行最后一个字
# 一起带下来，而不是让逗号、句号孤零零地顶在下一行开头。
const CHAT_NO_LINE_START := "，。、；：！？）」』】》…,.;:!?)"

func _wrap_chat_line(line: String) -> PackedStringArray:
	if _chat_labels.is_empty():
		return PackedStringArray([line])
	# 按参考画布上的尺寸量（宽 CHAT_MSG_W —— 消息列的宽，不是入口行的）。
	# _layout() 缩放时字号与宽度同比例变，参考尺寸下折好的行，缩放之后一样放得下。
	return wrap_chat_text(line, _chat_labels[0].get_theme_font("font"), CHAT_FONT_SIZE, CHAT_MSG_W)


# 逐字符折行：中文没有空格可断；英文单词偶尔会被拆开，聊天里可以接受。
# 静态、不碰界面状态 —— tools/chat_check 直接调它量「最长的一条放不放得下」。
static func wrap_chat_text(line: String, font: Font, font_size: int, width: float) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	for i in line.length():
		var ch := line[i]
		var candidate := current + ch
		if current.is_empty() or font.get_string_size(
				candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
			current = candidate
		elif CHAT_NO_LINE_START.contains(ch) and current.length() > 1:
			# 避头：上一行让出最后一个字，陪这个标点一起换行。
			out.append(current.left(-1))
			current = current.right(1) + ch
		else:
			out.append(current)
			current = ch
	if not current.is_empty():
		out.append(current)
	return out

func _chat_speaker_name(slot: int) -> String:
	var identity := _seat_profile(slot)
	var who := str(identity.get("player_name", "")).strip_edges()
	if not who.is_empty():
		return who
	# 资料还没到（publish_lobby_identity 是异步的，还带 10 秒重试）。
	# 用座位号顶着 —— 空名字会让这条消息看起来像是没有人说的。
	# 显式标 String：SLOT_LABELS 是无类型 Array，取出来是 Variant，
	# `:=` 推断不出类型会直接变成解析错误（而解析错误在 headless 下不产生结果，
	# 只打一行 SCRIPT ERROR —— 见 docs/CHECKS.md）。
	var seat: String = SLOT_LABELS[slot] if slot >= 0 and slot < SLOT_LABELS.size() else "?"
	return "%s%s" % [_room_text("席位", "Seat "), seat]

func _refresh_chat() -> void:
	for i in _chat_labels.size():
		_chat_labels[i].text = _chat_history[i] if i < _chat_history.size() else ""

func _room_text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh

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
	# V3 P1-07：F3 切排布调试网格，也只在 debug 包响应 —— Release 桌面版有真实
	# 键盘，玩家按到 F3 不该看见内部调试线。
	if not OS.is_debug_build():
		return
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

	# 3.5) 六个席位格：底板范围 + 席位号（入座判定比底板小一圈，看红框对比）
	for i in 6:
		var sp: Vector2 = SLOT_POS[i]
		var slot_rect := Rect2(origin + sp * scale, SLOT_SIZE * scale)
		_debug_layer.draw_rect(slot_rect, black, false, 2.0)
		_debug_layer.draw_string(font, slot_rect.position + Vector2(6.0, -4.0),
			"席位%s (%d,%d) %dx%d" % [SLOT_LABELS[i], int(sp.x), int(sp.y),
			int(SLOT_SIZE.x), int(SLOT_SIZE.y)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, black)

	# 4) edge=left / edge=right 锚定边（这两列贴真实屏幕边，不跟画布走）
	#    左列最宽的是聊天框(147+432)、右列最靠左的是房主提示(1285)
	var left_edge_x := 579.0 * scale
	var right_edge_x := viewport_size.x - (REF_SIZE.x - 1285.0) * scale
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
