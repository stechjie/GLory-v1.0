extends Control

const VFX_WARMUP := preload("res://effects/vfx3d/VFXWarmup.gd")

var _menu: Control
var _prep: Control
var _battle: Control
var _reconnect_overlay: CanvasLayer
var _pending_team_menu_action := ""
var _pending_team_room_id := 0
var _pending_public_token := ""
# 离线自测·单位测试模式(officetest):进入前的 team_mode 快照,退出时还原。
var _selftest_prev_team_mode := false

func _ready() -> void:
	# Idempotent on purpose: the DataRegistry autoload has already loaded by now, and
	# this used to be a second full synchronous re-read of all eight JSON files on
	# the way to the first frame. Kept as a call rather than deleted so the ordering
	# dependency stays visible if autoload order ever changes.
	DataRegistry.ensure_loaded()
	if not NetworkService.match_state_received.is_connected(_on_network_match_state_received):
		NetworkService.match_state_received.connect(_on_network_match_state_received)
	if not NetworkService.session_changed.is_connected(_on_global_session_changed):
		NetworkService.session_changed.connect(_on_global_session_changed)
	if not NetworkService.resume_completed.is_connected(_on_resume_completed):
		NetworkService.resume_completed.connect(_on_resume_completed)
	if not NetworkService.resume_failed.is_connected(_on_resume_failed):
		NetworkService.resume_failed.connect(_on_resume_failed)
	if not NetworkService.team_room_list_received.is_connected(_on_team_room_list_received):
		NetworkService.team_room_list_received.connect(_on_team_room_list_received)
	if not NetworkService.team_room_action_failed.is_connected(_on_team_room_action_failed):
		NetworkService.team_room_action_failed.connect(_on_team_room_action_failed)
	if not NetworkService.public_token_changed.is_connected(_on_public_token_changed):
		NetworkService.public_token_changed.connect(_on_public_token_changed)
	if not TutorialMode.skip_requested.is_connected(_on_tutorial_skip):
		TutorialMode.skip_requested.connect(_on_tutorial_skip)
	_start_vfx_warmup()
	_show_language_select()
	StartupTrace.mark(StartupTrace.T2_MAIN_READY)

# VFX shader 预热。挂在这里是因为从引擎就绪到连上服务器有约 44 秒的菜单导航时间，
# 而且这段时间还没有心跳需要维持 —— 详见 VFXWarmup.gd 顶部。
func _start_vfx_warmup() -> void:
	if NetworkService.state != NetworkService.SessionState.OFFLINE:
		return
	var warm := VFX_WARMUP.new()
	warm.name = "VFXWarmup"
	# 挂在 root 而不是 Main：Main._clear() 每次切界面都会把自己的子节点全部
	# queue_free，而 _show_language_select() 第一行就是 _clear()。预热要跨越
	# 「语言选择 → 教程 → 宠物 → 主菜单」这几屏才跑得完，挂在 Main 下会立刻被杀。
	# 同 _show_reconnect_overlay 的做法。
	get_tree().root.add_child.call_deferred(warm)
	warm.finished.connect(func(_report: Dictionary): warm.queue_free())
	# 延后到入树之后再启动：start() 里要 add_child 建离屏视口。
	warm.start.call_deferred()

# --- 断线重连 UI 与恢复落地 --------------------------------------------------

func _on_global_session_changed() -> void:
	if NetworkService.state == NetworkService.SessionState.RECONNECTING:
		_show_reconnect_overlay()
	else:
		_hide_reconnect_overlay()

func _show_reconnect_overlay() -> void:
	if _reconnect_overlay != null and is_instance_valid(_reconnect_overlay):
		return
	# 挂在 root 上：Main._clear() 切界面时不会误删
	_reconnect_overlay = CanvasLayer.new()
	_reconnect_overlay.name = "ReconnectOverlay"
	_reconnect_overlay.layer = 100
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reconnect_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)
	var lbl := Label.new()
	lbl.text = "连接中断，正在重连…" if not LocaleManager.get_locale().begins_with("en") else "Connection lost, reconnecting..."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80))
	box.add_child(lbl)
	var cancel := Button.new()
	cancel.text = "取消并返回主菜单" if not LocaleManager.get_locale().begins_with("en") else "Cancel and return to menu"
	cancel.custom_minimum_size = Vector2(260, 48)
	cancel.pressed.connect(_on_reconnect_cancel)
	box.add_child(cancel)
	get_tree().root.add_child(_reconnect_overlay)

func _hide_reconnect_overlay() -> void:
	if _reconnect_overlay != null and is_instance_valid(_reconnect_overlay):
		_reconnect_overlay.queue_free()
	_reconnect_overlay = null

func _on_reconnect_cancel() -> void:
	NetworkService.cancel_reconnect()
	GameState.team_mode = false
	_hide_reconnect_overlay()
	_show_menu()

func _on_resume_completed(payload: Dictionary) -> void:
	_hide_reconnect_overlay()
	GameState.team_mode = true
	# 只有内存里没有对局数据（app 重开导致 GameState 全新）才从磁盘恢复棋盘/备战席；
	# 活着的重连（网络抖动）内存就是最新状态，不能用可能过期的磁盘存档覆盖它。
	if _team_run_state_is_fresh():
		SaveManager.load_run()
	# 服务器权威数值覆盖本地
	# 键名跟着状态信封走（E2）：round_index -> round_id、enemy_team_hp -> rival_team_hp。
	# 快照现在还多带了连败与 PVE/Boss 计数（C5 缺的那几项）。
	GameState.round_index = int(payload.get("round_id", GameState.round_index))
	GameState.team_hp = int(payload.get("team_hp", GameState.team_hp))
	GameState.enemy_team_hp = int(payload.get("rival_team_hp", GameState.enemy_team_hp))
	GameState.gold = int(payload.get("gold", GameState.gold))
	GameState.loss_streak = int(payload.get("loss_streak", GameState.loss_streak))
	GameState.pve_completed = int(payload.get("pve_completed", GameState.pve_completed))
	GameState.boss_completed = int(payload.get("boss_completed", GameState.boss_completed))
	GameState.golden_altar_uses = int(payload.get("altar_uses", GameState.golden_altar_uses))
	# 宝物以服务端记录为准。磁盘存档可能落后一轮（app 被杀重开），而服务端的
	# owned_treasures 是 intent 授权出来的唯一真相；未领取的候选也一并接回来，
	# 否则重连玩家会永远丢掉这一轮的三选一。
	if payload.has("owned_treasures"):
		# 走同步 helper 而不是直接赋值：直接赋值会绕过图鉴 mark_seen 与联动解锁。
		TreasureService.sync_owned_from_server(payload.get("owned_treasures", []) as Array)
	var resumed_offer: Dictionary = payload.get("treasure_offer", {}) as Dictionary
	if resumed_offer.is_empty():
		# 服务端说没有待领取的候选 —— 必须**主动清掉**本地旧的三选一界面。
		# 只在有 offer 时才写，会让掉线前那次未领取的 UI 一直留在屏幕上：玩家点下去
		# 服务端已经 erase 过 offer，只会拿到 no_offer，表现为「点了没反应」。
		GameState.pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	else:
		GameState.pending_treasure = {
			"active": true,
			"round": int(resumed_offer.get("round", 0)),
			"candidates": (resumed_offer.get("candidates", []) as Array).duplicate(),
			"refresh_index": int(resumed_offer.get("refresh_index", 0)),
		}
	# 商店按恢复后的当前回合重新滚：旧商店在重连/跨回合后无意义，磁盘存档也可能是空的。
	# 清空后 PrepScreen._ready 会自动 _roll_shop() 出一批新的。
	GameState.clear_shop()
	if str(payload.get("phase", "prep")) == NetworkService.ROOM_LOBBY:
		_show_team3v3_lobby()
		return
	# prep/battle/result 一律落回备战：battle 阶段等本回合 match_state 到达后
	# 由全局处理器直接推进（= 跳过战斗），result 阶段服务器已补发 match_state。
	_show_prep()

func _team_run_state_is_fresh() -> bool:
	for cell in GameState.board_slots:
		if cell != null:
			return false
	for cell in GameState.bench_slots:
		if cell != null:
			return false
	return true

func _on_resume_failed(reason: String) -> void:
	_hide_reconnect_overlay()
	GameState.team_mode = false
	_show_menu()
	if is_instance_valid(_menu) and _menu.has_method("show_room_error"):
		_menu.show_room_error(reason)
	if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
		_menu.show_connection_error(reason)

func _on_tutorial_skip() -> void:
	# 跳过整段教学：结束教学态，回到主菜单让玩家自己选普通/组队。
	if not TutorialMode.active:
		return
	TutorialMode.finish()
	_show_menu()

# 界面场景一律运行时 load，不用 preload。
#
# 原因是实测出来的：GDScript 的 preload() **不管写在哪里都在脚本加载时解析**，包括永远
# 不会执行的函数体内。所以这几行原本写成 preload 时，加载 Main.gd 会连带把 MainMenu /
# Settings / Pet / Codex / Team3v3Lobby / PrepScreen / BattleScreen 的整张依赖图全拉进来 ——
# 而首屏语言选择页一个都不需要。更要命的是这发生在**第一个 autoload ready 之前**，
# 任何 GDScript 侧的优化都够不着它。
#
# 实测（--headless，同参数只改这一处，各跑多次）：t0_trace_ready
#   改前 3159 / 3177 / 3206 ms   改后 1651 / 1653 / 1658 / 1659 ms
# 约省 1.5 秒，引擎启动降 48%。作为对照，一个不引用这些界面的小场景是 974/980 ms ——
# 也就是说改完之后 Main 自身的预加载成本从 ~2.2 秒降到 ~0.7 秒。
#
# 代价是成本转移而非消失：每个界面**第一次**打开会变慢。这是刻意的取舍 —— 那些都发生在
# 玩家操作之后、可以配加载态，而 preload 是无条件压在启动路径上。
#
# 换成 load() 会丢掉 preload 的编译期路径校验，所以这里把 null 变成一条指名道姓的错误，
# 而不是让调用方在 null 上 .instantiate() 崩掉。全仓的 res:// 引用另有
# tools/asset_manifest_check 守着。
func _load_screen(path: String) -> PackedScene:
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("界面场景加载失败：%s" % path)
	return scene


func _instantiate_screen(path: String) -> Control:
	var scene := _load_screen(path)
	if scene == null:
		return null
	return scene.instantiate() as Control


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

func _show_language_select() -> void:
	_clear()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.075)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_constant_override("separation", 18)
	center.add_child(panel)

	var title := Label.new()
	title.text = "Select Language / 选择语言"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.96, 0.94, 0.82))
	panel.add_child(title)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)

	var zh_btn := Button.new()
	zh_btn.text = "中文"
	zh_btn.custom_minimum_size = Vector2(150, 54)
	zh_btn.pressed.connect(_select_language.bind("zh"))
	row.add_child(zh_btn)

	var en_btn := Button.new()
	en_btn.text = "English"
	en_btn.custom_minimum_size = Vector2(150, 54)
	en_btn.pressed.connect(_select_language.bind("en"))
	row.add_child(en_btn)

	# Deferred by one frame on purpose: the buttons exist now, but T3 is meant to be
	# "the player could have pressed one", which is only true once this frame has
	# been laid out and drawn.
	StartupTrace.mark_input_ready.call_deferred("language_select")

func _select_language(locale: String) -> void:
	LocaleManager.set_locale(locale)
	StartupTrace.mark_first_action("select_language", locale)
	TutorialMode.start()
	_show_prep()

func _show_menu() -> void:
	# 首次启动：进主菜单前强制选择初始宠物（三选一，选完才放行）。
	if PlayerProfile.needs_starter_pick:
		_show_starter_pet_gate()
		return
	_clear()
	# 重连改为手动：主菜单的"游戏重连"按钮（有本地凭证才显示）才连回上一场，
	# 不再一进菜单就偷偷自动连（那会把玩家拽进夹生半状态、按不动开始）。
	_menu = _instantiate_screen("res://scenes/menu/MainMenu.tscn")
	_menu.team_host_requested.connect(_on_team_host_requested)
	_menu.team_join_requested.connect(_on_team_join_requested)
	_menu.team_room_create_requested.connect(_on_team_room_create_requested)
	_menu.team_room_join_requested.connect(_on_team_room_join_requested)
	_menu.team_room_list_requested.connect(_on_team_room_list_requested)
	_menu.public_token_generate_requested.connect(_on_public_token_generate_requested)
	_menu.public_token_resume_requested.connect(_on_public_token_resume_requested)
	if not _menu.team_offline_requested.is_connected(_on_team_offline_requested):
		_menu.team_offline_requested.connect(_on_team_offline_requested)
	if not _menu.team_reconnect_requested.is_connected(_on_team_reconnect_requested):
		_menu.team_reconnect_requested.connect(_on_team_reconnect_requested)
	_menu.settings_requested.connect(_show_settings)
	_menu.prep_requested.connect(_show_pet_screen)
	_menu.codex_requested.connect(_show_codex_screen)
	add_child(_menu)

func _on_team_reconnect_requested() -> void:
	# 手动重连：读本地凭证连回上一场，弹重连遮罩，成功落回备战/结果，失败清凭证回菜单
	var rc := SaveManager.load_reconnect()
	var rc_token := str(rc.get("token", ""))
	var rc_address := str(rc.get("address", ""))
	if rc_token.is_empty() or rc_address.is_empty():
		return
	GameState.team_mode = true
	# 端口必须用存下来的那个：座位 token 是进程内的，多进程下连错端口 = 凭证失效。
	# 老存档没有 port 字段，退化为默认端口（等价于单进程时的旧行为）。
	NetworkService.begin_resume_from_disk(rc_token, rc_address, int(rc.get("port", NetworkService.DEFAULT_PORT)))

func _on_team_offline_requested() -> void:
	# 纯离线自测：断开任何联机会话，team_active 保持 false，进大厅走本地槽位。
	# 开始后 BattleScreen 的 `not team_active` 分支会本地算回放，无需服务器。
	NetworkService.disconnect_session()
	_show_team3v3_lobby()

func _show_settings() -> void:
	_clear()
	var settings := _instantiate_screen("res://scenes/menu/SettingsScreen.tscn")
	settings.back_requested.connect(_show_menu)
	add_child(settings)

# 备战界面（暂时只有宠物系统）。从主菜单「备战」按钮进入，返回回主菜单。
func _show_pet_screen() -> void:
	_clear()
	var pet_screen := _instantiate_screen("res://scenes/menu/PetScreen.tscn")
	pet_screen.back_requested.connect(_show_menu)
	add_child(pet_screen)

# 图鉴界面。从主菜单「图鉴」按钮进入，返回回主菜单。
func _show_codex_screen() -> void:
	_clear()
	var codex := _instantiate_screen("res://scenes/menu/CodexScreen.tscn")
	codex.back_requested.connect(_show_menu)
	add_child(codex)

# 首次启动的初始宠物三选一关卡：无返回按钮，选完后再进主菜单。
func _show_starter_pet_gate() -> void:
	_clear()
	var pet_screen := _instantiate_screen("res://scenes/menu/PetScreen.tscn")
	pet_screen.starter_picked.connect(_show_menu)
	add_child(pet_screen)

func _show_team3v3_lobby() -> void:
	_clear()
	var lobby := _instantiate_screen("res://scenes/menu/Team3v3Lobby.tscn")
	lobby.start_requested.connect(_on_team3v3_start)
	lobby.back_requested.connect(_on_lobby_back)
	lobby.selftest_requested.connect(_show_selftest)
	add_child(lobby)

# 离线自测·单位测试模式(officetest):独立场景,不走备战/回合/存档,
# 返回时还原 team_mode,不在 GameState 留任何痕迹。
func _show_selftest() -> void:
	_clear()
	_selftest_prev_team_mode = GameState.team_mode
	GameState.team_mode = true
	# load() (not preload) so this optional officetest scene never becomes a
	# parse-time dependency of Main on a cold boot before its .import exists.
	var screen: Node = (load("res://officetest/OfficeTestScreen.tscn") as PackedScene).instantiate()
	screen.back_requested.connect(_on_selftest_back)
	add_child(screen)

func _on_selftest_back() -> void:
	GameState.team_mode = _selftest_prev_team_mode
	_show_team3v3_lobby()

func _on_lobby_back() -> void:
	NetworkService.disconnect_session()
	_show_menu()

func _show_prep() -> void:
	# 保底：对局已结束（最终局打完）就不再进备战，直接游戏结束界面。
	# 堵住任何"结束后又被导航回备战"的残留路径（配合服务器封顶/不再开回合）。
	if GameState.team_mode and GameState.final_round_played:
		_show_game_over()
		return
	_clear()
	_prep = _instantiate_screen("res://scenes/prep/PrepScreen.tscn")
	_prep.battle_requested.connect(_on_battle_requested)
	add_child(_prep)
	SaveManager.save_run()

func _show_battle(battle_scene: PackedScene = null) -> void:
	_clear()
	var scene := battle_scene if battle_scene != null else _load_screen("res://scenes/battle/BattleScreen.tscn")
	_battle = scene.instantiate()
	_battle.battle_finished.connect(_on_battle_finished)
	add_child(_battle)

func _show_game_over() -> void:
	# 对局结束：重连凭证作废，避免下次启动误恢复到已结束的房间
	SaveManager.clear_reconnect()
	_clear()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.07)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_constant_override("separation", 12)
	center.add_child(panel)

	var title := Label.new()
	title.text = _game_over_title()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.96, 0.92, 0.78))
	panel.add_child(title)

	var body := Label.new()
	body.text = _game_over_body()
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(420, 90)
	body.add_theme_color_override("font_color", Color(0.86, 0.9, 0.9))
	panel.add_child(body)

	var menu_btn := Button.new()
	menu_btn.text = tr("gameover_back")
	menu_btn.custom_minimum_size = Vector2(180, 40)
	menu_btn.pressed.connect(_on_return_menu_requested)
	panel.add_child(menu_btn)

func _on_team_host_requested() -> void:
	# Debug-only local host. Production Android clients connect to the VPS.
	if NetworkService.team_host(NetworkService.DEFAULT_PORT):
		_show_team3v3_lobby()
	elif is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
		_menu.show_connection_error(NetworkService.last_error)

func _on_team_join_requested(address: String = NetworkService.DEFAULT_HOST) -> void:
	# Client-side production path: connect to the dedicated ENet server.
	# 开始新游戏 = 放弃上一场：清本地重连凭证，并让服务器把旧座位交给 AI
	# （若旧房间还有其他玩家；没人就靠超时自清）。之后从此连不回旧局。
	var rc := SaveManager.load_reconnect()
	var abandon_token := str(rc.get("token", ""))
	SaveManager.clear_reconnect()
	if not NetworkService.team_join(address, NetworkService.DEFAULT_PORT):
		if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
			_menu.show_connection_error(NetworkService.last_error)
		return
	if is_instance_valid(_menu) and _menu.has_method("show_connecting"):
		_menu.show_connecting()
	# 记下要放弃的旧座位 token，连上后由 NetworkService 发 abandon
	NetworkService.pending_abandon_token = abandon_token
	if not NetworkService.session_changed.is_connected(_on_pending_join_session_changed):
		NetworkService.session_changed.connect(_on_pending_join_session_changed)

func _on_pending_join_session_changed() -> void:
	match NetworkService.state:
		NetworkService.SessionState.READY:
			NetworkService.session_changed.disconnect(_on_pending_join_session_changed)
			_show_team3v3_lobby()
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			NetworkService.session_changed.disconnect(_on_pending_join_session_changed)
			if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
				_menu.show_connection_error(NetworkService.last_error if NetworkService.last_error != "" else "连接失败")

func _on_team_room_list_requested() -> void:
	_start_team_menu_action("list")

func _on_team_room_create_requested() -> void:
	_start_team_menu_action("create")

func _on_team_room_join_requested(room_id: int) -> void:
	_pending_team_room_id = room_id
	_start_team_menu_action("join")

func _on_public_token_generate_requested() -> void:
	_start_team_menu_action("token")

func _on_public_token_resume_requested(token_id: String) -> void:
	_pending_public_token = token_id
	_start_team_menu_action("resume_public")

# 这次动作该连哪个服务器进程（多进程分片）。
# "join" 是唯一一个目标进程由数据决定的动作：房间号里编了分片号，必须连到那个
# 分片，否则会在错误的进程上找不到房间。其余动作（建房/看列表/拿短码）连哪个
# 都行 —— 现在按默认分片，以后接了「分配端点」由它来决定。
func _target_port_for_action(action: String) -> int:
	if action == "join":
		return NetworkConfig.port_of_room(_pending_team_room_id)
	return NetworkService.DEFAULT_PORT

func _start_team_menu_action(action: String) -> void:
	_pending_team_menu_action = action
	var target_port := _target_port_for_action(action)
	# 这四个值决定下面走哪条分支。不记的话，一旦卡在 connecting，
	# 现场日志里只能看到“连上了然后没下文”，分不出是哪一步断的。
	NetworkService._net_log("team menu action=%s port=%d active=%s state=%d slot=%d" % [
		action, target_port, str(NetworkService.team_active),
		int(NetworkService.state), int(NetworkService.team_local_slot)])
	# 已连着、但连的是别的分片：必须先断开再连对的那个。
	if NetworkService.team_active and NetworkService.remote_port != target_port:
		NetworkService.disconnect_session()
	elif NetworkService.team_active and NetworkService.state == NetworkService.SessionState.READY and NetworkService.team_local_slot < 0:
		_run_pending_team_menu_action()
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, target_port):
		if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
			_menu.show_connection_error(NetworkService.last_error)
		return
	if is_instance_valid(_menu) and _menu.has_method("show_connecting"):
		_menu.show_connecting()
	if not NetworkService.session_changed.is_connected(_on_pending_team_menu_session_changed):
		NetworkService.session_changed.connect(_on_pending_team_menu_session_changed)

func _on_pending_team_menu_session_changed() -> void:
	match NetworkService.state:
		NetworkService.SessionState.READY:
			if NetworkService.session_changed.is_connected(_on_pending_team_menu_session_changed):
				NetworkService.session_changed.disconnect(_on_pending_team_menu_session_changed)
			_run_pending_team_menu_action()
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			if NetworkService.session_changed.is_connected(_on_pending_team_menu_session_changed):
				NetworkService.session_changed.disconnect(_on_pending_team_menu_session_changed)
			if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
				_menu.show_connection_error(NetworkService.last_error if NetworkService.last_error != "" else "连接失败")

func _run_pending_team_menu_action() -> void:
	match _pending_team_menu_action:
		"list":
			NetworkService.team_request_room_list()
		"create":
			_wait_for_room_join()
			NetworkService.team_request_create_room()
		"join":
			_wait_for_room_join()
			NetworkService.team_request_join_room(_pending_team_room_id)
		"token":
			NetworkService.team_request_public_token()
		"resume_public":
			NetworkService.team_request_public_resume(_pending_public_token)
		_:
			# 没有兜底分支的话，一个认不出的 action 会让本函数安静地什么都不做，
			# 而 UI 那边已经进了 connecting 状态在等回包 —— 就是永远卡住。
			NetworkService._net_log("team menu action unknown: '%s'（UI 会卡在 connecting）"
				% str(_pending_team_menu_action))

func _wait_for_room_join() -> void:
	if not NetworkService.team_lobby_changed.is_connected(_on_pending_room_joined):
		NetworkService.team_lobby_changed.connect(_on_pending_room_joined)

func _on_pending_room_joined() -> void:
	if NetworkService.team_local_slot < 0:
		return
	if NetworkService.team_lobby_changed.is_connected(_on_pending_room_joined):
		NetworkService.team_lobby_changed.disconnect(_on_pending_room_joined)
	_pending_team_menu_action = ""
	_show_team3v3_lobby()

func _on_team_room_list_received(rooms: Array) -> void:
	if is_instance_valid(_menu) and _menu.has_method("show_room_list"):
		_menu.show_room_list(rooms)

func _on_team_room_action_failed(reason: String) -> void:
	if NetworkService.team_lobby_changed.is_connected(_on_pending_room_joined):
		NetworkService.team_lobby_changed.disconnect(_on_pending_room_joined)
	if is_instance_valid(_menu) and _menu.has_method("show_room_error"):
		_menu.show_room_error(reason)

func _on_public_token_changed(token_id: String) -> void:
	if is_instance_valid(_menu) and _menu.has_method("show_public_token"):
		_menu.show_public_token(token_id)

func _on_team3v3_start() -> void:
	SaveManager.new_run()
	GameState.team_mode = true
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP
	if NetworkService.shared_seed == 0:
		NetworkService.shared_seed = randi()
	NetworkService.team_begin_round()
	_show_prep()

func _on_team_battle_finished(result: Dictionary) -> void:
	if NetworkService.team_active and not NetworkService.is_host:
		await _finish_server_authoritative_team_battle(result)
		return
	var completed_round := GameState.round_index
	var kind := str(result.get("kind", "pve"))
	# PvP 是规范化棋局（A 队 = "player"）。本地在 B 队时结果要镜像。
	# 视角反转走 TeamOutcome（C16），与服务端结算、BattleUI 字幕共用同一实现。
	var local_team := TeamOutcome.TEAM_A
	if NetworkService.team_active and GameConstants.team_of_slot(NetworkService.team_local_slot) == GameConstants.TEAM_BLUE:
		local_team = TeamOutcome.TEAM_B
	var player_wins := TeamOutcome.viewer_wins_battle(result, kind, local_team)
	var surviving_enemies := int(result.get("enemy_alive", result.get("enemy_count", 1)))
	# 伤到本队的存活者在 B 队视角下是 A 队（"player" 侧）那批。
	if kind == "pvp" and local_team == TeamOutcome.TEAM_B:
		surviving_enemies = int(result.get("player_alive", 0))
	# Host stamps BOTH teams' damage this round into the replay result so every
	# client can drive its own team HP and the rival team HP deterministically.
	var self_dmg := int(result.get("team_damage_self", -1))
	var rival_dmg := int(result.get("team_damage_rival", -1))
	if self_dmg >= 0:
		GameState.team_hp = maxi(0, GameState.team_hp - self_dmg)
		GameState.enemy_team_hp = maxi(0, GameState.enemy_team_hp - maxi(0, rival_dmg))
		# Formation Heal (法阵回春): host-authoritative regen, after damage, only if
		# still alive, capped at the starting HP.
		var heal_self := int(result.get("team_heal_self", 0))
		var heal_rival := int(result.get("team_heal_rival", 0))
		if GameState.team_hp > 0 and heal_self > 0:
			GameState.team_hp = mini(GameState.START_FORMATION_HP, GameState.team_hp + heal_self)
		if GameState.enemy_team_hp > 0 and heal_rival > 0:
			GameState.enemy_team_hp = mini(GameState.START_FORMATION_HP, GameState.enemy_team_hp + heal_rival)
	elif not player_wins:
		# Legacy fallback: only my team's HP, damage = surviving enemy count.
		GameState.team_hp = maxi(0, GameState.team_hp - maxi(1, surviving_enemies))
	# Economy: 全套战后结算走 EconomyService.settle_post_battle_gold —— 与专用服务器
	# 的 NetworkService._server_gold_after_battle 共用同一份实现，两处不能再各写各的。
	# 连败计数在这里维护（此前全代码从未 +1 过，安慰金因此恒为 +2）：胜利清零、
	# 失败 +1，安慰金按结算后的连败数计算。
	if player_wins:
		GameState.loss_streak = 0
	else:
		GameState.loss_streak += 1
	GameState.gold = EconomyService.settle_post_battle_gold({
		"gold_before": GameState.gold,
		"kill_gold": _team_local_kill_gold(result),
		"bonus_gold": int(result.get("bonus_gold", 0)),
		"kind": kind,
		"player_wins": player_wins,
		"round_index": completed_round,
		"loss_streak_after": GameState.loss_streak,
		"boss_hp_current": int(result.get("enemy_hp_current", 0)),
		"boss_hp_max": maxi(1, int(result.get("enemy_hp_max", 1))),
		"merchant_gold": EconomyService.merchant_gold_from_board(GameState.board_slots),
		"treasures": GameState.owned_treasures,
		"pet_id": PlayerProfile.get_active(),
	})
	_apply_post_battle_unit_outcomes(result)
	GameState.battle_history.append(result)
	if kind == "pve":
		GameState.pve_completed += 1
	elif kind == "boss":
		GameState.boss_completed += 1
	GameState.round_index = mini(GameState.round_index + 1, GameState.FINAL_ROUND)
	GameState.reset_shop_refreshes()
	GameState.clear_shop()
	GameState.clear_mercenaries()
	# (2) End the run the moment either team's formation HP reaches 0 (or round 21).
	var run_over := GameState.team_hp <= 0 or GameState.enemy_team_hp <= 0 or completed_round >= GameState.FINAL_ROUND
	if run_over:
		if completed_round >= GameState.FINAL_ROUND:
			GameState.final_round_played = true
		# 整局归属走 TeamOutcome（C16）。此前这里落进 else 分支按剩余水晶生命判，
		# 而服务端第 21 回合按最终战结果判 —— 两条规则会给出不同答案。
		# TeamOutcome 的入参是 A/B 绝对视角，所以本地的 team_hp/player_wins
		# 要先换算回 A 队视角再传进去。
		var hp_a := GameState.team_hp if local_team == TeamOutcome.TEAM_A else GameState.enemy_team_hp
		var hp_b := GameState.enemy_team_hp if local_team == TeamOutcome.TEAM_A else GameState.team_hp
		var a_wins := player_wins if local_team == TeamOutcome.TEAM_A else not player_wins
		GameState.team_run_outcome = TeamOutcome.run_outcome({
			"completed_round": completed_round,
			"final_round": GameState.FINAL_ROUND,
			"hp_a": hp_a,
			"hp_b": hp_b,
			"kind": kind,
			"battle_a_wins": a_wins,
			"battle_is_draw": bool(result.get("is_draw", false)),
		})
		GameState.team_run_won = TeamOutcome.team_won_run(GameState.team_run_outcome, local_team)
		SaveManager.save_run()
		_show_game_over()
		return
	NetworkService.team_begin_round()
	_start_treasure_for_completed_round(completed_round)
	_show_prep()

func _finish_server_authoritative_team_battle(result: Dictionary) -> void:
	if result.has("error"):
		# **技术失败，不是玩家退出**（B8/E3）：replay 没等到、解包失败之类。
		# 此前这里调 disconnect_session()，等于清掉重连凭证 —— 而服务器那边
		# 座位还好好留着。现在进可恢复状态，让重连流程去接。
		var reason := str(result.get("error", "replay_timeout"))
		print("[NET] team battle failed reason=%s class=%s" % [reason, NetError.class_name_of(reason)])
		NetworkService.enter_recoverable_failure(reason)
		if NetworkService.state != NetworkService.SessionState.RECONNECTING:
			_show_menu()
		return
	var completed_round := GameState.round_index
	var waited := 0.0
	while not _has_team_match_state(completed_round) and waited < NetworkService.REPLAY_TIMEOUT_SEC:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if not _has_team_match_state(completed_round):
		# 正在重连：不要拆会话回菜单，恢复流程会接管导航（resume 后落回备战）
		if NetworkService.state == NetworkService.SessionState.RECONNECTING:
			return
		# 同上：结算没等到是传输问题，不是"玩家要退出"。
		print("[NET] match_state timeout round=%d" % completed_round)
		NetworkService.enter_recoverable_failure("match_state_timeout")
		if NetworkService.state != NetworkService.SessionState.RECONNECTING:
			_show_menu()
		return
	var state_payload := NetworkService.latest_match_state.duplicate(true)
	_apply_team_match_state_payload(state_payload, result)
	print("[NET] client applied match_state round=%d next=%d gold=%d hp=%d" % [completed_round, GameState.round_index, GameState.gold, GameState.team_hp])
	if bool(state_payload.get("run_over", false)):
		SaveManager.save_run()
		_show_game_over()
		return
	NetworkService.team_begin_round()
	_show_prep()

func _has_team_match_state(completed_round: int) -> bool:
	return not NetworkService.latest_match_state.is_empty() and int(NetworkService.latest_match_state.get("completed_round", -1)) == completed_round and int(NetworkService.latest_match_state.get("protocol", -1)) == NetworkConfig.NETWORK_PROTOCOL_VERSION

func _apply_team_match_state_payload(state_payload: Dictionary, result: Dictionary = {}) -> void:
	if state_payload.is_empty():
		return
	GameState.team_hp = int(state_payload.get("team_hp", GameState.team_hp))
	GameState.enemy_team_hp = int(state_payload.get("enemy_team_hp", GameState.enemy_team_hp))
	GameState.gold = int(state_payload.get("gold", GameState.gold))
	GameState.pve_completed = int(state_payload.get("pve_completed", GameState.pve_completed))
	GameState.boss_completed = int(state_payload.get("boss_completed", GameState.boss_completed))
	GameState.loss_streak = int(state_payload.get("loss_streak", GameState.loss_streak))
	GameState.final_round_played = bool(state_payload.get("final_round_played", GameState.final_round_played))
	# run_outcome 是权威的绝对归属（TEAM_A/TEAM_B/DRAW）；team_run_won 只是本座位
	# 视角的派生布尔，单看它分不出"输了"和"平局"。
	GameState.team_run_outcome = int(state_payload.get("run_outcome", GameState.team_run_outcome))
	GameState.team_run_won = bool(state_payload.get("team_run_won", GameState.team_run_won))
	if not result.is_empty():
		_apply_post_battle_unit_outcomes(result)
		GameState.battle_history.append(result)
	GameState.round_index = int(state_payload.get("round_index", GameState.round_index))
	GameState.pending_treasure = (state_payload.get("pending_treasure", {"active": false, "round": 0, "candidates": [], "refresh_index": 0}) as Dictionary).duplicate(true)
	# 结算已经落到本地状态上了，现在才回执（E3）。服务器要等所有在线真人都确认
	# 才推进下一轮 —— 此前任意一个人按准备就能把还在看回放的人一起拽走（C7）。
	NetworkService.send_result_ack(str(state_payload.get("battle_id", "")))
	GameState.reset_shop_refreshes()
	GameState.clear_shop()
	GameState.clear_mercenaries()
	SaveManager.save_run()

func _team_local_kill_gold(result: Dictionary) -> int:
	var slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	return EconomyService.kill_gold_for_slot(result, maxi(0, slot))

func _on_battle_requested() -> void:
	var loaded_battle_scene: PackedScene = null
	if _prep != null and _prep.has_method("take_loaded_battle_scene"):
		loaded_battle_scene = _prep.call("take_loaded_battle_scene") as PackedScene
	if GameState.tutorial_mode:
		if TutorialMode.begin_battle():
			_show_battle(loaded_battle_scene)
		return
	# 3v3 gates on its own per-round ready sync (team_round_start); board
	# collection still happens in the battle screen.
	_show_battle(loaded_battle_scene)

func _on_return_menu_requested() -> void:
	SaveManager.save_run()
	NetworkService.disconnect_session()
	_show_menu()

func _on_battle_finished(result: Dictionary = {}) -> void:
	if GameState.tutorial_mode:
		TutorialMode.after_battle(result)
		if TutorialMode.step == TutorialMode.Step.DONE:
			TutorialMode.finish()
			_show_game_over()
			return
		_show_prep()
		return
	if GameState.team_mode:
		_on_team_battle_finished(result)
		return

func _game_over_title() -> String:
	if GameState.team_mode:
		if TeamOutcome.is_draw(GameState.team_run_outcome):
			return tr("gameover_final_draw")
		return tr("gameover_final_win") if GameState.team_run_won else tr("gameover_final_lost")
	if GameState.player_formation_hp <= 0:
		return tr("gameover_lost")
	if GameState.enemy_formation_hp <= 0:
		return tr("gameover_win")
	if GameState.final_round_played:
		var last := _last_battle_result()
		if bool(last.get("player_wins", false)):
			return tr("gameover_final_win")
		return tr("gameover_final_lost")
	return tr("gameover_lost")

func _game_over_body() -> String:
	if GameState.team_mode:
		var team_result := tr("gameover_result_win") if GameState.team_run_won else tr("gameover_result_lose")
		if TeamOutcome.is_draw(GameState.team_run_outcome):
			team_result = tr("gameover_result_draw")
		return tr("gameover_team_body") % [GameState.round_index, team_result, GameState.team_hp]
	var last := _last_battle_result()
	var result_text := tr("gameover_result_win") if bool(last.get("player_wins", false)) else tr("gameover_result_lose")
	return tr("gameover_body") % [
		GameState.round_index,
		result_text,
		GameState.player_formation_hp,
		GameState.enemy_formation_hp,
	]

func _last_battle_result() -> Dictionary:
	if GameState.battle_history.is_empty():
		return {}
	var last = GameState.battle_history.back()
	if typeof(last) == TYPE_DICTIONARY:
		return last
	return {}

func _on_network_match_state_received(state_payload: Dictionary) -> void:
	if _battle != null and is_instance_valid(_battle):
		return
	# 内嵌服务器会在本回合刚就绪时立刻把战后 match_state 发回，此刻玩家可能还在
	# 备战界面异步打包战斗（战斗场景尚未创建）。这时绝不能提前应用——否则
	# round_index 会在进战斗前就 +1，既跳了回合，又让备战的
	# _wait_for_team_match_state 等待条件永远错配、卡住进不去战斗。payload 已存在
	# NetworkService.latest_match_state 里，战斗播完后 _finish_server_authoritative_team_battle
	# 会统一应用。
	if _prep != null and is_instance_valid(_prep) and _prep.has_method("is_committing_to_battle") and bool(_prep.call("is_committing_to_battle")):
		return
	if GameState.team_mode:
		_apply_team_match_state_payload(state_payload)
		if _prep != null and is_instance_valid(_prep) and _prep.has_method("_refresh_all"):
			_prep.call_deferred("_refresh_all")

func _apply_post_battle_unit_outcomes(result: Dictionary) -> void:
	if not result.has("player_survivor_slots"):
		return
	var survivor_slots := {}
	for slot in result.get("player_survivor_slots", []):
		survivor_slots[int(slot)] = true
	for i in GameState.board_slots.size():
		var cell = GameState.board_slots[i]
		if cell == null or str(cell.get("def", {}).get("skill_id", "")) != "unique_king_growth":
			continue
		if survivor_slots.has(i):
			_grow_human_king(cell)
		else:
			GameState.board_slots[i] = null

func _grow_human_king(cell: Dictionary) -> void:
	var d: Dictionary = cell.get("def", {})
	var mul := 1.0 + float(d.get("post_battle_all_stat_growth", 0.20))
	for key in ["hp", "atk", "def"]:
		if d.has(key):
			d[key] = maxi(1, int(round(float(d[key]) * mul)))
	for key in ["attack_speed", "move_speed", "crit", "crit_dmg", "range"]:
		if d.has(key):
			d[key] = float(d[key]) * mul
	cell.def = d
	cell.king_growth_stacks = int(cell.get("king_growth_stacks", 0)) + 1

func _start_treasure_for_completed_round(completed_round: int) -> void:
	if bool(GameState.pending_treasure.get("active", false)):
		return
	if completed_round in GameState.claimed_treasure_rounds:
		return
	if not RoundService.is_treasure_round(completed_round) or not TreasureService.can_draw():
		return
	var candidates := TreasureService.roll_candidates(3)
	if candidates.is_empty():
		return
	GameState.pending_treasure = {
		"active": true,
		"round": completed_round,
		"candidates": candidates,
		"refresh_index": 0,
	}
