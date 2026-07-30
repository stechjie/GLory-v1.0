extends "res://scenes/prep/PrepDetails.gd"

const BattleReplayUtil = preload("res://scripts/battle/BattleReplayUtil.gd")
const BattleSim = preload("res://scripts/battle/BattleSimulator.gd")
# 只为拿它的 static 资源缓存（BattleRenderer.gd 没有 class_name）。战斗资源在这里
# 就绪之后，BattleScreen 那边 _scene_for_model_path 直接命中缓存、不再同步读盘。
const BattleRendererScript = preload("res://scenes/battle/BattleRenderer.gd")

const PREP_MUSIC_PATH := "res://assets/audio/bgm/prep_music.mp3"
const PREP_PVP_MUSIC_PATH := "res://assets/audio/bgm/pvp_round_music.mp3"
# 左上角 FPS 角标（安卓性能对比用）。不需要时改成 false。
const SHOW_FPS_OVERLAY := true
# BattleScreen path: loaded on Start Battle before entering battle.
const BATTLE_SCREEN_PATH := "res://scenes/battle/BattleScreen.tscn"
# 临时缓解（B7），不是修复。这是**主路径**的超时：原值 20 秒短于服务器的
# BOARD_SUBMIT_TIMEOUT_SEC(30)，任何需要看门狗兜底的回合，客户端都会先一步取消
# 战斗准备退回备战，而服务器随后才补交/转 AI —— 迟到的结算会跳过单位阵亡与成长，
# 造成客户端与服务器分叉。最终修法是 board ACK/服务端进度驱动，见文档 1B-1。
const TEAM_BATTLE_PREP_TIMEOUT_SEC := 60.0
# 战斗资源预加载的上限。到点还没齐就照旧进战斗（退回按需加载），
# 宁可卡一下，也不要读条停在那里让玩家以为死机。
const ASSET_PRELOAD_TIMEOUT_MSEC := 15000

var _prep_music_player: AudioStreamPlayer
var _fps_label: Label
var _fps_accum := 0.0

var _battle_transition_running := false
var _battle_thread_requested := false
var _loaded_battle_scene: PackedScene
var _battle_scene_load_ratio := 0.0
var _battle_data_ratio := 0.0
var _battle_load_visual: Control
var _battle_load_bar: ProgressBar
var _battle_load_particles: CPUParticles2D

func _ready() -> void:
	_setup_board_cell_styles()
	if not NetworkService.session_changed.is_connected(_on_network_session_changed):
		NetworkService.session_changed.connect(_on_network_session_changed)
	if not NetworkService.team_lobby_changed.is_connected(_on_network_session_changed):
		NetworkService.team_lobby_changed.connect(_on_network_session_changed)
	if not NetworkService.team_round_start.is_connected(_on_team_round_start):
		NetworkService.team_round_start.connect(_on_team_round_start)
	if GameState.shop_offers.is_empty() or GameState.shop_offers[0].is_empty():
		_roll_shop()
	_build()
	_setup_battle_load_visual()
	# 备战期只做**增量**：把后几轮的怪排进后台队列。
	# 大批量加载在大厅完成（Team3v3Lobby._setup_asset_loader）—— 备战期玩家在拖
	# 棋子、看羁绊，3D 棋盘和 UI 都在跑，往这里塞几百 MB 会直接卡到操作。
	BattleRendererScript.prefetch_upcoming_rounds(GameState.round_index)
	_start_prep_music()
	_setup_fps_overlay()
	_maybe_start_pending_treasure()
	_refresh_all()
	if GameState.tutorial_mode:
		TutorialMode.attach(self)
	_maybe_show_pvp_warning.call_deferred(_next_round_kind())

func _start_prep_music() -> void:
	if _prep_music_player != null:
		return
	# 下一回合是 PVP（含最终 PVP）时放专属音乐，否则放普通摆放音乐。
	var next_kind := _next_round_kind()
	var music_path := PREP_PVP_MUSIC_PATH if next_kind == "pvp" or next_kind == "final" else PREP_MUSIC_PATH
	# 必须用 load() 走资源系统：Android 导出包只含 mp3 的导入产物、不含原始文件，
	# FileAccess.get_file_as_bytes 在真机上读到空字节（编辑器里却正常，因为原始
	# 文件就在磁盘上）。战斗音乐用 load() 所以手机上一直有声，这里保持一致。
	var stream := load(music_path) as AudioStream
	if stream == null:
		push_warning("准备界面音乐读取失败：%s" % music_path)
		return
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	_prep_music_player = AudioStreamPlayer.new()
	_prep_music_player.name = "PrepMusicPlayer"
	_prep_music_player.stream = stream
	_prep_music_player.bus = "Music" if AudioServer.get_bus_index("Music") >= 0 else "Master"
	add_child(_prep_music_player)
	_prep_music_player.play()

func _setup_fps_overlay() -> void:
	if not SHOW_FPS_OVERLAY:
		return
	_fps_label = Label.new()
	_fps_label.name = "FpsOverlay"
	_fps_label.text = "FPS --"
	_fps_label.position = Vector2(8, 2)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_fps_label.add_theme_constant_override("outline_size", 3)
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fps_label.z_index = 300
	add_child(_fps_label)

func _exit_tree() -> void:
	if NetworkService.session_changed.is_connected(_on_network_session_changed):
		NetworkService.session_changed.disconnect(_on_network_session_changed)
	if NetworkService.team_lobby_changed.is_connected(_on_network_session_changed):
		NetworkService.team_lobby_changed.disconnect(_on_network_session_changed)
	if NetworkService.team_round_start.is_connected(_on_team_round_start):
		NetworkService.team_round_start.disconnect(_on_team_round_start)

func _on_team_round_start() -> void:
	# All players readied -> launch this round's battle.
	RaceRelationService.finalize_for_battle(GameState.board_slots, GameState.bench_slots)
	SaveManager.save_run()
	_emit_battle_request_once()

func _process(delta: float) -> void:
	_update_detail_release_state()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()
	if _fps_label != null:
		_fps_accum += delta
		if _fps_accum >= 0.25:
			_fps_accum = 0.0
			_fps_label.text = "FPS %d" % int(Engine.get_frames_per_second())

func _input(event: InputEvent) -> void:
	if _detail != null and _detail.visible:
		if event is InputEventMouseButton:
			var detail_mouse_event := event as InputEventMouseButton
			if detail_mouse_event.pressed:
				_hide_detail()
		elif event is InputEventScreenTouch:
			var detail_touch_event := event as InputEventScreenTouch
			if detail_touch_event.pressed:
				_hide_detail()
		return
	if _team_mercs_open and _team_mercs_overlay != null and _team_mercs_overlay.visible:
		var team_pointer := Vector2.ZERO
		var team_should_check := false
		if event is InputEventMouseButton:
			var team_mouse := event as InputEventMouseButton
			if team_mouse.pressed and team_mouse.button_index == MOUSE_BUTTON_LEFT:
				team_pointer = team_mouse.position
				team_should_check = true
		elif event is InputEventScreenTouch:
			var team_touch := event as InputEventScreenTouch
			if team_touch.pressed:
				team_pointer = team_touch.position
				team_should_check = true
		if team_should_check and not _team_mercs_overlay.get_global_rect().has_point(team_pointer):
			_close_team_mercs_picker()
		return
	if _shop_picker_open and _shop_panel != null and _shop_panel.visible:
		var shop_pointer := Vector2.ZERO
		var shop_should_check := false
		if event is InputEventMouseButton:
			var shop_mouse := event as InputEventMouseButton
			if shop_mouse.pressed and shop_mouse.button_index == MOUSE_BUTTON_LEFT:
				shop_pointer = shop_mouse.position
				shop_should_check = true
		elif event is InputEventScreenTouch:
			var shop_touch := event as InputEventScreenTouch
			if shop_touch.pressed:
				shop_pointer = shop_touch.position
				shop_should_check = true
		# 点「弹窗 / 商店按钮 / 商店子树里的任何控件」之外才收起。用悬停控件判断是否属于商店
		# 子树，这样刷新、钱袋等就算被摆到面板矩形【外面】，点它们也不会被误判成关店。
		# 弹窗非模态、不 return：这次点击继续往下传，可以直接点棋盘/拖单位。
		var shop_hovered := get_viewport().gui_get_hovered_control()
		var click_on_shop: bool = _shop_panel.get_global_rect().has_point(shop_pointer) \
			or (shop_hovered != null and (shop_hovered == _shop_panel or _shop_panel.is_ancestor_of(shop_hovered)))
		var click_on_shop_btn: bool = _shop_open_button != null and _shop_open_button.get_global_rect().has_point(shop_pointer)
		# 外挂层（钱袋A购买键 / 刷新）虽然不在商店面板矩形内，但点它们也算"点商店"，不收起。
		# 只认"悬停控件是它的子孙"——外挂层本身满屏且 IGNORE，不能用矩形判断（否则永远不关店）。
		var click_on_shop_side: bool = _shop_side_controls != null and _shop_side_controls.visible \
			and shop_hovered != null and _shop_side_controls.is_ancestor_of(shop_hovered)
		if shop_should_check and not click_on_shop and not click_on_shop_btn and not click_on_shop_side:
			_close_shop_picker()
	if not _merc_picker_open or _merc_overlay == null or not _merc_overlay.visible:
		return
	var pointer_position := Vector2.ZERO
	var should_check := false
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
			pointer_position = mouse_event.position
			should_check = true
	elif event is InputEventScreenTouch:
		var touch_event := event as InputEventScreenTouch
		if touch_event.pressed:
			pointer_position = touch_event.position
			should_check = true
	if should_check and not _merc_overlay.get_global_rect().has_point(pointer_position):
		_close_merc_picker()

func take_loaded_battle_scene() -> PackedScene:
	var scene := _loaded_battle_scene
	_loaded_battle_scene = null
	return scene


func _setup_battle_load_visual() -> void:
	if _battle_load_visual != null:
		return
	_battle_load_visual = Control.new()
	_battle_load_visual.name = "BattleLoadProgress"
	_battle_load_visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_battle_load_visual.visible = false
	_battle_load_visual.z_index = -4
	add_child(_battle_load_visual)

	_battle_load_bar = ProgressBar.new()
	_battle_load_bar.name = "RiverLaneProgressBar"
	_battle_load_bar.min_value = 0.0
	_battle_load_bar.max_value = 100.0
	_battle_load_bar.value = 0.0
	_battle_load_bar.show_percentage = false
	_battle_load_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.02, 0.13, 0.16, 0.48)
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	_battle_load_bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.20, 0.95, 0.92, 0.82)
	fill.corner_radius_top_left = 4
	fill.corner_radius_top_right = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4
	_battle_load_bar.add_theme_stylebox_override("fill", fill)
	_battle_load_visual.add_child(_battle_load_bar)

	_battle_load_particles = CPUParticles2D.new()
	_battle_load_particles.name = "RiverLaneLoadParticles"
	_battle_load_particles.amount = 10
	_battle_load_particles.lifetime = 0.55
	_battle_load_particles.texture = _make_soft_dot_texture()
	_battle_load_particles.direction = Vector2(1.0, 0.0)
	_battle_load_particles.spread = 24.0
	_battle_load_particles.gravity = Vector2.ZERO
	_battle_load_particles.initial_velocity_min = 18.0
	_battle_load_particles.initial_velocity_max = 48.0
	_battle_load_particles.scale_amount_min = 0.18
	_battle_load_particles.scale_amount_max = 0.38
	_battle_load_particles.color = Color(0.35, 1.0, 0.95, 0.85)
	_battle_load_particles.local_coords = false
	_battle_load_particles.emitting = false
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_battle_load_particles.material = mat
	_battle_load_visual.add_child(_battle_load_particles)
	_layout_battle_load_visual()

func _layout_battle_load_visual() -> void:
	if _battle_load_visual == null or _battle_load_bar == null or _start_battle_button == null:
		return
	var button_rect := _start_battle_button.get_global_rect()
	# Progress lane: full thin river line behind the Start Battle button.
	var viewport_width := get_viewport_rect().size.x
	var lane_width := clampf(button_rect.size.x * 3.4, button_rect.size.x, viewport_width - 48.0)
	var lane_size := Vector2(lane_width, 8.0)
	var lane_pos := Vector2(button_rect.position.x + button_rect.size.x * 0.5 - lane_size.x * 0.5, button_rect.position.y + button_rect.size.y * 0.5 + 8.0)
	_battle_load_visual.position = lane_pos
	_battle_load_visual.size = lane_size
	_battle_load_bar.position = Vector2.ZERO
	_battle_load_bar.size = lane_size
	_set_battle_load_progress(0.0)

func _set_battle_load_progress(ratio: float) -> void:
	if _battle_load_bar == null:
		return
	var clamped := clampf(ratio, 0.0, 1.0)
	_battle_load_bar.value = clamped * 100.0
	if _battle_load_particles != null:
		_battle_load_particles.position = Vector2(_battle_load_bar.size.x * clamped, _battle_load_bar.size.y * 0.5)

func _set_battle_scene_load_progress(ratio: float) -> void:
	_battle_scene_load_ratio = clampf(ratio, 0.0, 1.0)
	_update_battle_prepare_progress()

func _set_battle_data_progress(ratio: float) -> void:
	_battle_data_ratio = clampf(ratio, 0.0, 1.0)
	_update_battle_prepare_progress()

func _update_battle_prepare_progress() -> void:
	_set_battle_load_progress(_battle_scene_load_ratio * 0.35 + _battle_data_ratio * 0.65)

func _show_battle_load_visual() -> void:
	_setup_battle_load_visual()
	_layout_battle_load_visual()
	_battle_scene_load_ratio = 0.0
	_battle_data_ratio = 0.0
	_battle_load_visual.visible = true
	_set_battle_load_progress(0.0)
	if _battle_load_particles != null:
		_battle_load_particles.emitting = true

func _hide_battle_load_visual() -> void:
	if _battle_load_particles != null:
		_battle_load_particles.emitting = false
	if _battle_load_visual != null:
		_battle_load_visual.visible = false
func _emit_battle_request_once() -> void:
	if _battle_launch_emitted or _battle_transition_running:
		return
	RaceRelationService.finalize_for_battle(GameState.board_slots, GameState.bench_slots)
	_battle_launch_emitted = true
	_battle_transition_running = true
	GameState.clear_pending_battle_package()
	if _start_battle_button != null:
		_start_battle_button.disabled = true
	_loaded_battle_scene = null
	_battle_thread_requested = false
	_show_battle_load_visual()
	_start_battle_thread_load()
	var battle_ready := await _prepare_battle_package_before_scene()
	if not battle_ready:
		_cancel_battle_prepare()
		return
	await _finish_battle_thread_load()
	# 单位模型/贴图必须在这里等完，不能等进了战斗再同步加载 —— 那正是实测里
	# 首回合 14.8 秒、后续每回合 2.3–5.1 秒主线程冻结的来源。
	await _preload_battle_assets()
	_set_battle_data_progress(1.0)
	_hide_battle_load_visual()
	_battle_transition_running = false
	battle_requested.emit()

# 本场会用到的模型/待机动画/技能贴图，全部等到就绪再进战斗。
# 清单直接来自 replay 的 roster（uid -> def），不是按阵容猜 —— 服务器已经把整场
# 算完发过来了，谁会出场是确定的。
func _preload_battle_assets() -> void:
	# 兜底，不是主力。资源本该在大厅（seed 无关的公共资源 + 本局怪物名单）和
	# 备战期（增量）就绪；这里只补还没齐的部分 —— 玩家手速极快、第一回合、
	# 或 PVP 对手 replay 刚到的情况。
	#
	# 清单来自 replay 的 roster：服务器已经把整场算完发过来了，出场名单是确定的。
	var model_paths: Array[String] = []
	var texture_paths: Array = []
	for replay in [NetworkService.team_replay, NetworkService.team_replay_rival]:
		for p in BattleAssetManifest.replay_paths(replay):
			if not model_paths.has(p):
				model_paths.append(p)
		texture_paths.append_array(BattleAssetManifest.replay_texture_paths(replay))
	VFXManager.preload_textures(texture_paths)
	BattleAssetService.acquire_many(model_paths, BattleAssetService.OWNER_BATTLE)
	# 本回合真打到了：把大厅/备战期为这一轮预取的 owner 转成 battle/current，
	# 资源全程不落地。
	BattleAssetService.promote_future_to_battle(GameState.round_index)

	var total := BattleAssetService.pending_count() + VFXManager.pending_texture_count()
	if total == 0:
		return
	# 逐帧等待。绝不调用阻塞版 load_threaded_get() —— 那会让进度条自己卡住不动，
	# 玩家看到的是"假死"，比原来的卡顿更糟。
	var deadline := Time.get_ticks_msec() + ASSET_PRELOAD_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var remaining := BattleAssetService.harvest() + VFXManager.pending_texture_count()
		_set_battle_data_progress(0.65 + 0.35 * (1.0 - float(remaining) / maxf(1.0, float(total))))
		if remaining == 0:
			return
		await get_tree().process_frame
		if not is_inside_tree():
			return
	# 超时兜底：不无限等。没就绪的退回战斗中按需加载（即旧行为）。
	push_warning("战斗资源预加载超时，剩余项退回战斗内加载")

# True from the moment this round commits to launching its battle until the
# battle scene is actually created — i.e. the async replay-packaging window.
# Main uses this to hold off applying a server match_state that arrives early
# (see Main._on_network_match_state_received).
func is_committing_to_battle() -> bool:
	return _battle_launch_emitted or _battle_transition_running

func _start_battle_thread_load() -> void:
	if _battle_thread_requested:
		return
	_battle_thread_requested = true
	var err := ResourceLoader.load_threaded_request(BATTLE_SCREEN_PATH)
	if err != OK and err != ERR_BUSY:
		push_warning("BattleScreen async load request failed: %s" % err)

func _finish_battle_thread_load() -> void:
	if not _battle_thread_requested:
		_start_battle_thread_load()
	var progress := []
	while true:
		var status := ResourceLoader.load_threaded_get_status(BATTLE_SCREEN_PATH, progress)
		if not progress.is_empty():
			_set_battle_scene_load_progress(float(progress[0]))
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			_set_battle_scene_load_progress(1.0)
			_loaded_battle_scene = ResourceLoader.load_threaded_get(BATTLE_SCREEN_PATH) as PackedScene
			return
		if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_set_battle_scene_load_progress(1.0)
			_loaded_battle_scene = load(BATTLE_SCREEN_PATH) as PackedScene
			return
		await get_tree().process_frame

func _prepare_battle_package_before_scene() -> bool:
	if GameState.team_mode:
		return await _prepare_team_battle_package()
	_set_battle_data_progress(1.0)
	return true

func _prepare_team_battle_package() -> bool:
	_set_battle_data_progress(0.1)
	if not NetworkService.team_active:
		var local_a: Dictionary = await BattleSim.compute_team_replay_async(0)
		if not is_inside_tree():
			return false
		_set_battle_data_progress(0.55)
		var local_b: Dictionary = await BattleSim.compute_team_replay_async(1)
		if not is_inside_tree():
			return false
		BattleSim.stamp_team_round_damages(local_a, local_b)
		NetworkService.team_replay_rival = local_b
		return _store_team_battle_package(local_a)

	NetworkService.team_replay = {}
	NetworkService.team_replay_rival = {}
	NetworkService.team_submit_board(NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots))
	_set_battle_data_progress(0.25)
	var my_team := GameConstants.team_of_slot(NetworkService.team_local_slot)
	if NetworkService.is_host and not bool(NetworkService.get("_dedicated_server")):
		if not await _wait_for_team_boards():
			show_message("Battle sync timeout")
			return false
		var replay_a: Dictionary = await BattleSim.compute_team_replay_async(0)
		if not is_inside_tree():
			return false
		_set_battle_data_progress(0.75)
		var replay_b: Dictionary = await BattleSim.compute_team_replay_async(1)
		if not is_inside_tree():
			return false
		BattleSim.stamp_team_round_damages(replay_a, replay_b)
		NetworkService.team_broadcast_replays(replay_a, replay_b)
		NetworkService.team_replay_rival = replay_b if my_team == 0 else replay_a
		return _store_team_battle_package(replay_a if my_team == 0 else replay_b)
	return await _wait_for_team_replay()

func _wait_for_team_boards() -> bool:
	var wait_elapsed := 0.0
	while not NetworkService.team_boards_available():
		if NetworkService.state == NetworkService.SessionState.FAILED or NetworkService.state == NetworkService.SessionState.RECONNECTING:
			# 掉线：中止本次打包，重连遮罩/恢复流程接管
			return false
		await get_tree().create_timer(0.1).timeout
		wait_elapsed += 0.1
		_set_battle_data_progress(0.25 + minf(wait_elapsed / TEAM_BATTLE_PREP_TIMEOUT_SEC, 1.0) * 0.35)
		if wait_elapsed >= TEAM_BATTLE_PREP_TIMEOUT_SEC:
			return false
	return true

func _wait_for_team_replay() -> bool:
	var wait_elapsed := 0.0
	while not BattleReplayUtil.valid_team_replay(NetworkService.team_replay):
		if NetworkService.state == NetworkService.SessionState.FAILED or NetworkService.state == NetworkService.SessionState.RECONNECTING:
			return false
		if not NetworkService.team_replay.is_empty():
			show_message("Battle replay invalid")
			return false
		await get_tree().create_timer(0.1).timeout
		wait_elapsed += 0.1
		_set_battle_data_progress(0.35 + minf(wait_elapsed / TEAM_BATTLE_PREP_TIMEOUT_SEC, 1.0) * 0.40)
		if wait_elapsed >= TEAM_BATTLE_PREP_TIMEOUT_SEC:
			show_message("Battle replay timeout")
			return false
	if NetworkService.team_active and not NetworkService.is_host:
		if not await _wait_for_team_match_state(GameState.round_index):
			return false
	return _store_team_battle_package(NetworkService.team_replay)

func _wait_for_team_match_state(completed_round: int) -> bool:
	var wait_elapsed := 0.0
	while not _has_team_match_state(completed_round):
		if NetworkService.state == NetworkService.SessionState.FAILED or NetworkService.state == NetworkService.SessionState.RECONNECTING:
			return false
		await get_tree().create_timer(0.1).timeout
		wait_elapsed += 0.1
		_set_battle_data_progress(0.75 + minf(wait_elapsed / TEAM_BATTLE_PREP_TIMEOUT_SEC, 1.0) * 0.25)
		if wait_elapsed >= TEAM_BATTLE_PREP_TIMEOUT_SEC:
			show_message("Battle result sync timeout")
			return false
	_set_battle_data_progress(1.0)
	return true

func _has_team_match_state(completed_round: int) -> bool:
	return not NetworkService.latest_match_state.is_empty() and int(NetworkService.latest_match_state.get("completed_round", -1)) == completed_round and int(NetworkService.latest_match_state.get("protocol", -1)) == NetworkConfig.NETWORK_PROTOCOL_VERSION

func _store_team_battle_package(replay: Dictionary) -> bool:
	if not BattleReplayUtil.valid_team_replay(replay):
		show_message("Battle replay invalid")
		return false
	NetworkService.team_replay = replay
	GameState.set_pending_battle_package({
		"mode": "team_replay",
		"round_index": GameState.round_index,
		"replay": replay,
	})
	_set_battle_data_progress(1.0)
	return true

func _cancel_battle_prepare() -> void:
	GameState.clear_pending_battle_package()
	_hide_battle_load_visual()
	_battle_transition_running = false
	_battle_launch_emitted = false
	if _start_battle_button != null:
		_start_battle_button.disabled = false
