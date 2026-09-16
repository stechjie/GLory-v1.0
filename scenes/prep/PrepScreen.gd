extends "res://scenes/prep/PrepBoardController.gd"

signal startup_ready
var startup_staged := false

const BattleReplayUtil = preload("res://scripts/battle/BattleReplayUtil.gd")
const BattleSim = preload("res://scripts/battle/BattleSimulator.gd")
# 只为拿它的 static 资源缓存（BattleRenderer.gd 没有 class_name）。战斗资源在这里
# 就绪之后，BattleScreen 那边 _scene_for_model_path 直接命中缓存、不再同步读盘。
const BattleRendererScript = preload("res://scenes/battle/BattleRenderer.gd")
const BattleLoadingOverlayScene := preload("res://ui/components/GloryLoadingOverlay.tscn")
const BattleLoadingOverlayScript := preload("res://ui/components/GloryLoadingOverlay.gd")

const PREP_MUSIC_PATH := "res://assets/audio/bgm/prep_music.mp3"
const PREP_PVP_MUSIC_PATH := "res://assets/audio/bgm/pvp_round_music.mp3"
# Player-facing frame rate only. Build identity remains in the startup log.
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
const BATTLE_ACTION := "start_battle"
const BATTLE_ACTION_TIMEOUT_MSEC := 90000
const BATTLE_LOADING_MODAL_PRIORITY := 80

var _prep_music_player: AudioStreamPlayer
var _fps_label: Label
var _fps_accum := 0.0

var _battle_transition_running := false
var _battle_thread_requested := false
var _battle_thread_path := ""
var _loaded_battle_scene: PackedScene
var _battle_action_request_id := ""
var _battle_loading_overlay: BattleLoadingOverlayScript
var _battle_loading_modal_id := ""
var _battle_failure_code := ""
var _battle_failure_message := ""
var _battle_failure_retryable := true
var _battle_asset_fallback_used := false
# Debug-only seams for deterministic failure injection. They are inert in normal
# play and setters reject Release builds; no production branch reads test data.
var _battle_prepare_check_hook := Callable()
var _battle_scene_path_for_check := ""

func _ready() -> void:
	# 回合采集是备战入口的幂等结算点。动画和面板重建不会再次发放。
	#
	# 「谁负责发放」必须与本作其余萝卜动作用**同一条判据**：只有「联机且不是房主」
	# 交给服务端，其余（单人、房主）一律本地结算。对照
	# PrepBoardController.request_carrot_harvest_upgrade / request_upgrade_stone_draw，
	# 两者都是 `if team_active and not is_host: 走服务端`；买佣兵扣萝卜更是直接改
	# GameState，压根没有联网分支。房主在萝卜上本来就是本地权威。
	#
	# 此前这里写的是 `not NetworkService.team_active`，判据比其余动作**多挡了房主**：
	# 一进 3v3 大厅 team_active 就为 true（team_host/team_join 都会置位，本机开房也算），
	# 于是房主既不本地采集，也收不到自己广播的 room_state —— _apply_carrot_state 只在
	# 「客户端收包」和「重连恢复」两条路径上被调用，房主两条都不走，萝卜恒为 0。
	#
	# 不能改成「房主从 room.prep 回灌」：房主买佣兵只扣 GameState.carrots、不动账本，
	# 回灌会把花掉的萝卜还回来。
	var carrot_harvest_gain := 0
	var carrot_harvest_gains: Dictionary = {}
	var carrot_server_authoritative := NetworkService.team_active and not NetworkService.is_host
	if not GameState.tutorial_mode and not carrot_server_authoritative:
		var harvest := GameState.harvest_carrots_for_round(GameState.round_index)
		if bool(harvest.get("ok", false)):
			carrot_harvest_gain = int(harvest.get("gain", 0))
			var local_slot := clampi(NetworkService.team_local_slot, 0, 5) if NetworkService.team_active else 4
			carrot_harvest_gains[local_slot] = carrot_harvest_gain
			SaveManager.save_run()
	elif carrot_server_authoritative and GameState.last_harvest_round == GameState.round_index:
		carrot_harvest_gain = NetworkService.last_carrot_harvest_gain
		if NetworkService.team_carrot_harvest_round == GameState.round_index:
			carrot_harvest_gains = NetworkService.team_carrot_harvest_gains.duplicate(true)
		if carrot_harvest_gains.is_empty():
			carrot_harvest_gains[clampi(NetworkService.team_local_slot, 0, 5)] = carrot_harvest_gain
	# 这套系统的失败模式全是**静默**的：不采集、被覆盖、被幂等挡掉，界面上一模一样，
	# 都只表现为"萝卜不涨"。留一行 Debug 日志，出问题时一眼能分辨是哪一种，
	# 不必再靠猜。Release 不打。
	if OS.is_debug_build():
		print("[CARROT] round=%d 本地采集=%s（team_active=%s is_host=%s tutorial=%s）本回合到账=%d 余额=%d/%d last_harvest_round=%d" % [
			GameState.round_index, str(not carrot_server_authoritative and not GameState.tutorial_mode),
			str(NetworkService.team_active), str(NetworkService.is_host), str(GameState.tutorial_mode),
			carrot_harvest_gain, GameState.carrots, GameState.carrot_capacity(),
			GameState.last_harvest_round])
	_board_hud.setup_cell_styles()
	if not NetworkService.session_changed.is_connected(_on_network_session_changed):
		NetworkService.session_changed.connect(_on_network_session_changed)
	if not NetworkService.team_lobby_changed.is_connected(_on_network_session_changed):
		NetworkService.team_lobby_changed.connect(_on_network_session_changed)
	if not NetworkService.team_round_start.is_connected(_on_team_round_start):
		NetworkService.team_round_start.connect(_on_team_round_start)
	if not AsyncActionController.action_state_changed.is_connected(_on_async_action_state_changed):
		AsyncActionController.action_state_changed.connect(_on_async_action_state_changed)
	if GameState.shop_offers.is_empty() or GameState.shop_offers[0].is_empty():
		_roll_shop()
	await _build(startup_staged)
	if not carrot_harvest_gains.is_empty():
		# 记账：客机那条路径（_maybe_play_pending_carrot_harvest）也会在权威采集
		# 到达时补播，两边共用这个标记保证一回合只播一次。
		_carrot_feedback_round = GameState.round_index
		call_deferred("play_carrot_harvest_feedback", carrot_harvest_gains)
	# 这条连接必须放在最派生的类里：_connect_treasure_signals 定义在 PrepFlowController，
	# 而面板的接线在 PrepUI._build() 里 —— 父类看不见子类的方法。
	if not _treasure.net_signals_needed.is_connected(_connect_treasure_signals):
		_treasure.net_signals_needed.connect(_connect_treasure_signals)
	# 备战期只做**增量**：把后几轮的怪排进后台队列。
	# 大批量加载在大厅完成（Team3v3Lobby._setup_asset_loader）—— 备战期玩家在拖
	# 棋子、看羁绊，3D 棋盘和 UI 都在跑，往这里塞几百 MB 会直接卡到操作。
	if not GameState.tutorial_mode:
		BattleRendererScript.prefetch_upcoming_rounds(GameState.round_index)
	_start_prep_music()
	_setup_fps_overlay()
	_maybe_start_pending_treasure()
	_refresh_all()
	if GameState.tutorial_mode:
		TutorialMode.attach(tutorial_target_provider())
	_maybe_show_pvp_warning.call_deferred(PrepRules.next_round_kind())
	startup_ready.emit()

func _start_prep_music() -> void:
	if _prep_music_player != null:
		return
	# 下一回合是 PVP（含最终 PVP）时放专属音乐，否则放普通摆放音乐。
	var next_kind := PrepRules.next_round_kind()
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
	_fps_label = Label.new()
	_fps_label.name = "FpsOverlay"
	_fps_label.text = "FPS --"
	# B8: moved off the very top-left corner so the readout is clearly visible on
	# mobile (was Vector2(8, 2), jammed into the edge per bug report 9.9bug提交及修复08 #8).
	_fps_label.position = Vector2(16, 8)
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
	if AsyncActionController.action_state_changed.is_connected(_on_async_action_state_changed):
		AsyncActionController.action_state_changed.disconnect(_on_async_action_state_changed)
	AsyncActionController.clear_for_owner(self, "prep_scene_exit")
	# 聊天入口建在 PrepUI 层，但生命周期钩子只有这一层有。
	_teardown_chat_entry()
	_close_battle_loading_overlay()
	release_tutorial_target_provider()

func _on_team_round_start() -> void:
	# All players readied -> launch this round's battle.
	RaceRelationService.finalize_for_battle(GameState.board_slots, GameState.bench_slots)
	SaveManager.save_run()
	_emit_battle_request_once()

func _process(delta: float) -> void:
	refresh_four_star_visuals(delta)
	_overlay.update_release_state()
	if GameState.tutorial_mode:
		# A detail popup is a deliberate reading task. Pause the unrelated tutorial
		# chrome while it is topmost, then restore from the same semantic target.
		TutorialMode.set_overlay_suppressed(_overlay.is_showing())
		TutorialMode.update_overlay()
	if _fps_label != null:
		_fps_accum += delta
		if _fps_accum >= 0.25:
			_fps_accum = 0.0
			_fps_label.text = "FPS %d" % int(Engine.get_frames_per_second())

func _input(event: InputEvent) -> void:
	# Keep the selected UID and its gold stable until the server settles this
	# transaction. The detail panel shows the pending state; no early VFX/charge.
	if not NetworkService.four_star_request_id.is_empty():
		get_viewport().set_input_as_handled()
		return
	if _detail != null and _detail.visible:
		# PopupPanel owns outside-click/Escape dismissal. Its input positions
		# are popup-local, so the main viewport must not reinterpret them.
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
	if _shop.picker_open and _shop.panel != null and _shop.panel.visible:
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
		var click_on_shop: bool = _shop.panel.get_global_rect().has_point(shop_pointer) \
			or (shop_hovered != null and (shop_hovered == _shop.panel or _shop.panel.is_ancestor_of(shop_hovered)))
		var click_on_shop_btn: bool = _shop.open_button != null and _shop.open_button.get_global_rect().has_point(shop_pointer)
		# 外挂层（钱袋A购买键 / 刷新）虽然不在商店面板矩形内，但点它们也算"点商店"，不收起。
		# 只认"悬停控件是它的子孙"——外挂层本身满屏且 IGNORE，不能用矩形判断（否则永远不关店）。
		var click_on_shop_side: bool = _shop.side_controls != null and _shop.side_controls.visible \
			and shop_hovered != null and _shop.side_controls.is_ancestor_of(shop_hovered)
		if shop_should_check and not click_on_shop and not click_on_shop_btn and not click_on_shop_side:
			_shop.close_picker()
	# 佣兵选择层原本在这里手写「点面板矩形之外就关」。它已迁进 ModalStack
	# （C-11 的 C3），关闭改由 backdrop 的 dismiss_on_backdrop 承担 ——
	# backdrop 在 _unhandled_input 之前就消费掉那一下点击，这段永远不会再触发。
	# 而且 _merc_overlay 现在是每次开合重建的瞬时节点，留着这段就是一处读死指针的
	# 死代码，所以删掉而不是留着。商店那段仍是自建面板，保持原样。

func take_loaded_battle_scene() -> PackedScene:
	var scene := _loaded_battle_scene
	_loaded_battle_scene = null
	return scene


func set_battle_prepare_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	_battle_prepare_check_hook = hook
	return true


func set_battle_scene_path_for_check(path: String) -> bool:
	if not OS.is_debug_build():
		return false
	_battle_scene_path_for_check = path
	return true


func battle_action_request_id_for_check() -> String:
	return _battle_action_request_id if OS.is_debug_build() else ""


func battle_loading_snapshot_for_check() -> Dictionary:
	if not OS.is_debug_build() or _battle_loading_overlay == null \
			or not is_instance_valid(_battle_loading_overlay):
		return {}
	return _battle_loading_overlay.snapshot()


func _battle_scene_path() -> String:
	if OS.is_debug_build() and not _battle_scene_path_for_check.is_empty():
		return _battle_scene_path_for_check
	return BATTLE_SCREEN_PATH


func _on_start_battle_input_down() -> void:
	var action := "team_ready_toggle" if NetworkService.team_active else BATTLE_ACTION
	AsyncActionController.record_input_received(action, "prep/start_battle")


func _open_battle_loading_overlay(request_id: String, cancellable: bool) -> bool:
	_close_battle_loading_overlay()
	_battle_loading_overlay = BattleLoadingOverlayScene.instantiate() as BattleLoadingOverlayScript
	if _battle_loading_overlay == null:
		_set_battle_failure("LOAD_UI_CREATE", tr("battle_load_error_scene"), true)
		return false
	_battle_loading_overlay.cancel_requested.connect(_on_battle_loading_cancel_requested)
	_battle_loading_overlay.retry_requested.connect(_on_battle_loading_retry_requested)
	_battle_loading_modal_id = ModalStack.push(_battle_loading_overlay, {
		"id": "battle_loading_%s" % request_id,
		"owner": self,
		"priority": BATTLE_LOADING_MODAL_PRIORITY,
		"dismiss_on_backdrop": false,
	})
	if _battle_loading_modal_id.is_empty():
		_battle_loading_overlay = null
		_set_battle_failure("LOAD_UI_MODAL", tr("battle_load_error_scene"), true)
		return false
	_battle_loading_overlay.configure({
		"request_id": request_id,
		"title": tr("battle_load_title"),
		"stage_key": "submit_roster",
		"stage_text": tr("battle_load_submit"),
		"detail": tr("battle_load_submit_detail"),
		"cancellable": cancellable,
		"cancel_text": tr("battle_load_cancel"),
		"cancel_reason": "" if cancellable else tr("battle_load_cannot_cancel"),
	})
	return true


func _close_battle_loading_overlay() -> void:
	if not _battle_loading_modal_id.is_empty():
		ModalStack.pop(_battle_loading_modal_id, "battle_loading_closed")
	_battle_loading_modal_id = ""
	_battle_loading_overlay = null


func _set_battle_stage(
	stage_key: String,
	stage_text: String,
	detail: String = "",
	ratio: float = -1.0,
	counts: String = ""
) -> void:
	if not _battle_action_request_id.is_empty():
		AsyncActionController.update_context(_battle_action_request_id, {
			"stage": stage_key,
			"progress": ratio,
		})
	if _battle_loading_overlay != null and is_instance_valid(_battle_loading_overlay):
		_battle_loading_overlay.set_stage(stage_key, stage_text, detail, ratio, counts)


func _set_battle_failure(code: String, message: String, retryable: bool) -> void:
	_battle_failure_code = code
	_battle_failure_message = message
	_battle_failure_retryable = retryable


func _emit_battle_request_once() -> void:
	var cancellable := not NetworkService.team_active
	var request_id := AsyncActionController.begin(BATTLE_ACTION, {
		"owner": self,
		"control_id": "prep/start_battle",
		"timeout_msec": BATTLE_ACTION_TIMEOUT_MSEC,
		"cancellable": cancellable,
		"cancel_reason": "" if cancellable else "team_resolution_committed",
		"stage": "submit_roster",
	})
	if request_id.is_empty():
		return
	if _battle_launch_emitted or _battle_transition_running:
		return
	_battle_action_request_id = request_id
	_battle_failure_code = ""
	_battle_failure_message = ""
	_battle_failure_retryable = true
	_battle_asset_fallback_used = false
	RaceRelationService.finalize_for_battle(GameState.board_slots, GameState.bench_slots)
	_battle_launch_emitted = true
	_battle_transition_running = true
	GameState.clear_pending_battle_package()
	_loaded_battle_scene = null
	_battle_thread_requested = false
	_battle_thread_path = ""
	if _start_battle_button != null:
		_start_battle_button.show_pending(request_id, tr("battle_load_busy"))
	if not _open_battle_loading_overlay(request_id, cancellable):
		AsyncActionController.fail(request_id, _battle_failure_code, true)
		return
	AsyncActionController.mark_pending(request_id)
	_start_battle_thread_load()
	var battle_ready := await _prepare_battle_package_before_scene(request_id)
	if not _battle_request_is_active(request_id):
		return
	if not battle_ready:
		_fail_current_battle_action()
		return
	if not await _finish_battle_thread_load(request_id):
		if _battle_request_is_active(request_id):
			_fail_current_battle_action()
		return
	if not _battle_request_is_active(request_id):
		return
	# 单位模型/贴图必须在这里等完，不能等进了战斗再同步加载 —— 那正是实测里
	# 首回合 14.8 秒、后续每回合 2.3–5.1 秒主线程冻结的来源。
	await _preload_battle_assets(request_id)
	if not _battle_request_is_active(request_id):
		return
	_set_battle_stage("enter_battle", tr("battle_load_enter"), "", 1.0)
	if _battle_loading_overlay != null and is_instance_valid(_battle_loading_overlay):
		_battle_loading_overlay.set_entering(tr("battle_load_enter"))
	AsyncActionController.succeed(request_id)
	_close_battle_loading_overlay()
	_battle_transition_running = false
	battle_requested.emit()

# 本场会用到的模型/待机动画/技能贴图，全部等到就绪再进战斗。
# 清单直接来自 replay 的 roster（uid -> def），不是按阵容猜 —— 服务器已经把整场
# 算完发过来了，谁会出场是确定的。
func _preload_battle_assets(request_id: String) -> void:
	# 兜底，不是主力。资源本该在大厅（seed 无关的公共资源 + 本局怪物名单）和
	# 备战期（增量）就绪；这里只补还没齐的部分 —— 玩家手速极快、第一回合、
	# 或 PVP 对手 replay 刚到的情况。
	#
	# 清单来自 replay 的 roster：服务器已经把整场算完发过来了，出场名单是确定的。
	var model_paths: Array[String] = []
	var texture_paths: Array[String] = []
	for replay in [NetworkService.team_replay, NetworkService.team_replay_rival]:
		for p in BattleAssetManifest.replay_paths(replay):
			if not model_paths.has(p):
				model_paths.append(p)
		for raw_texture in BattleAssetManifest.replay_texture_paths(replay):
			var texture_path := str(raw_texture)
			if not texture_path.is_empty() and not texture_paths.has(texture_path):
				texture_paths.append(texture_path)
	VFXManager.preload_textures(texture_paths)
	BattleAssetService.acquire_many(model_paths, BattleAssetService.OWNER_BATTLE)
	# 本回合真打到了：把大厅/备战期为这一轮预取的 owner 转成 battle/current，
	# 资源全程不落地。
	BattleAssetService.promote_future_to_battle(GameState.round_index)

	var model_total := model_paths.size()
	var texture_total := texture_paths.size()
	var item_total := model_total + texture_total
	var model_done := BattleAssetService.ready_count(model_paths)
	var texture_done := VFXManager.ready_texture_count(texture_paths)
	var initial_asset_ratio := 1.0 if item_total == 0 else float(model_done + texture_done) / float(item_total)
	_set_battle_stage("load_battle_assets", tr("battle_load_assets"), "",
		0.70 + initial_asset_ratio * 0.28,
		tr("battle_load_asset_counts") % [model_done, model_total, texture_done, texture_total])
	if item_total == 0 or model_done + texture_done == item_total:
		return
	# 逐帧等待。绝不调用阻塞版 load_threaded_get() —— 那会让进度条自己卡住不动，
	# 玩家看到的是"假死"，比原来的卡顿更糟。
	var deadline := Time.get_ticks_msec() + ASSET_PRELOAD_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		BattleAssetService.harvest()
		model_done = BattleAssetService.ready_count(model_paths)
		texture_done = VFXManager.ready_texture_count(texture_paths)
		var done := model_done + texture_done
		_set_battle_stage("load_battle_assets", tr("battle_load_assets"), "",
			0.70 + float(done) / float(item_total) * 0.28,
			tr("battle_load_asset_counts") % [model_done, model_total, texture_done, texture_total])
		if done == item_total:
			return
		if not _battle_request_is_active(request_id):
			return
		await get_tree().process_frame
		if not is_inside_tree():
			return
	# 超时兜底：不无限等。没就绪的退回战斗中按需加载（即旧行为）。
	push_warning("战斗资源预加载超时，剩余项退回战斗内加载")
	_battle_asset_fallback_used = true
	AsyncActionController.annotate(_battle_action_request_id, "asset_timeout", {
		"stage": "load_battle_assets",
		"error_code": "ASSET_PRELOAD_FALLBACK",
	})
	if _battle_loading_overlay != null and is_instance_valid(_battle_loading_overlay):
		_battle_loading_overlay.set_stage("asset_fallback", tr("battle_load_assets"),
			tr("battle_load_asset_fallback"), -1.0,
			tr("battle_load_asset_counts") % [model_done, model_total, texture_done, texture_total])
	# 只在真的触发 15 秒兜底时留出短时间让提示可见；正常路径不增加延迟。
	await get_tree().create_timer(0.65).timeout

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
	_battle_thread_path = _battle_scene_path()
	var err := ResourceLoader.load_threaded_request(_battle_thread_path)
	if err != OK and err != ERR_BUSY:
		push_warning("BattleScreen async load request failed: %s (%s)" % [err, _battle_thread_path])

func _finish_battle_thread_load(request_id: String) -> bool:
	if not _battle_thread_requested:
		_start_battle_thread_load()
	var scene_path := _battle_thread_path
	if scene_path.is_empty():
		scene_path = _battle_scene_path()
	_set_battle_stage("load_battle_scene", tr("battle_load_scene"), "", 0.55)
	var progress := []
	while true:
		if not _battle_request_is_active(request_id):
			return false
		var status := ResourceLoader.load_threaded_get_status(scene_path, progress)
		if not progress.is_empty():
			_set_battle_stage("load_battle_scene", tr("battle_load_scene"), "",
				0.55 + clampf(float(progress[0]), 0.0, 1.0) * 0.15)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			_set_battle_stage("load_battle_scene", tr("battle_load_scene"), "", 0.70)
			_loaded_battle_scene = ResourceLoader.load_threaded_get(scene_path) as PackedScene
			if _loaded_battle_scene == null:
				_set_battle_failure("BATTLE_SCENE_EMPTY", tr("battle_load_error_scene"), true)
				return false
			return true
		if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_loaded_battle_scene = load(scene_path) as PackedScene
			if _loaded_battle_scene == null:
				_set_battle_failure("BATTLE_SCENE_LOAD", tr("battle_load_error_scene"), true)
				return false
			_set_battle_stage("load_battle_scene", tr("battle_load_scene"), "", 0.70)
			return true
		await get_tree().process_frame
	return false

func _prepare_battle_package_before_scene(request_id: String) -> bool:
	if OS.is_debug_build() and _battle_prepare_check_hook.is_valid():
		var injected: Variant = await _battle_prepare_check_hook.call(request_id)
		if not _battle_request_is_active(request_id):
			return false
		if injected is Dictionary:
			var result: Dictionary = injected
			match str(result.get("result", "continue")):
				"succeeded":
					return true
				"failed":
					_set_battle_failure(
						str(result.get("error_code", "INJECTED_FAILURE")),
						str(result.get("message", tr("battle_load_error_sync"))),
						bool(result.get("retryable", true)))
					return false
	if GameState.team_mode:
		return await _prepare_team_battle_package(request_id)
	_set_battle_stage("submit_roster", tr("battle_load_submit"), tr("battle_load_submit_detail"), 0.08)
	return true

func _prepare_team_battle_package(request_id: String) -> bool:
	_set_battle_stage("submit_roster", tr("battle_load_submit"), tr("battle_load_submit_detail"), 0.08)
	if not NetworkService.team_active:
		_set_battle_stage("generate_replay", tr("battle_load_generate_replay"), "", -1.0)
		var local_a: Dictionary = await BattleSim.compute_team_replay_async(0)
		if not _battle_request_is_active(request_id):
			return false
		var local_b: Dictionary = await BattleSim.compute_team_replay_async(1)
		if not _battle_request_is_active(request_id):
			return false
		BattleSim.stamp_team_round_damages(local_a, local_b)
		NetworkService.team_replay_rival = local_b
		return _store_team_battle_package(local_a, request_id)

	AsyncActionController.set_cancellable(_battle_action_request_id, false, "team_resolution_committed")
	if _battle_loading_overlay != null and is_instance_valid(_battle_loading_overlay):
		_battle_loading_overlay.set_cancel_policy(false, tr("battle_load_cannot_cancel"))
	NetworkService.team_replay = {}
	NetworkService.team_replay_rival = {}
	NetworkService.team_submit_board(NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots))
	_set_battle_stage("wait_team_server", tr("battle_load_wait_server"), "", -1.0)
	var my_team := GameConstants.team_of_slot(NetworkService.team_local_slot)
	if NetworkService.is_host and not bool(NetworkService.get("_dedicated_server")):
		if not await _wait_for_team_boards(request_id):
			return false
		_set_battle_stage("generate_replay", tr("battle_load_generate_replay"), "", -1.0)
		var replay_a: Dictionary = await BattleSim.compute_team_replay_async(0)
		if not _battle_request_is_active(request_id):
			return false
		var replay_b: Dictionary = await BattleSim.compute_team_replay_async(1)
		if not _battle_request_is_active(request_id):
			return false
		BattleSim.stamp_team_round_damages(replay_a, replay_b)
		NetworkService.team_broadcast_replays(replay_a, replay_b)
		NetworkService.team_replay_rival = replay_b if my_team == 0 else replay_a
		return _store_team_battle_package(replay_a if my_team == 0 else replay_b, request_id)
	_set_battle_stage("receive_replay", tr("battle_load_receive_replay"), "", -1.0)
	return await _wait_for_team_replay(request_id)

func _wait_for_team_boards(request_id: String) -> bool:
	var wait_elapsed := 0.0
	while not NetworkService.team_boards_available():
		if NetworkService.state == NetworkService.SessionState.FAILED or NetworkService.state == NetworkService.SessionState.RECONNECTING:
			# 掉线：中止本次打包，重连遮罩/恢复流程接管
			_set_battle_failure("NETWORK_INTERRUPTED", tr("battle_load_error_network"), true)
			return false
		if not _battle_request_is_active(request_id):
			return false
		_update_team_wait_status(wait_elapsed, request_id)
		await get_tree().create_timer(0.1).timeout
		wait_elapsed += 0.1
		if wait_elapsed >= TEAM_BATTLE_PREP_TIMEOUT_SEC:
			_set_battle_failure("TEAM_BOARD_TIMEOUT", tr("battle_load_error_sync"), true)
			return false
	return true

func _wait_for_team_replay(request_id: String) -> bool:
	var wait_elapsed := 0.0
	while not BattleReplayUtil.valid_team_replay(NetworkService.team_replay):
		if NetworkService.state == NetworkService.SessionState.FAILED or NetworkService.state == NetworkService.SessionState.RECONNECTING:
			_set_battle_failure("NETWORK_INTERRUPTED", tr("battle_load_error_network"), true)
			return false
		if not NetworkService.team_replay.is_empty():
			_set_battle_failure("TEAM_REPLAY_INVALID", tr("battle_load_error_replay"), true)
			return false
		if not _battle_request_is_active(request_id):
			return false
		_update_team_wait_status(wait_elapsed, request_id)
		await get_tree().create_timer(0.1).timeout
		wait_elapsed += 0.1
		if wait_elapsed >= TEAM_BATTLE_PREP_TIMEOUT_SEC:
			_set_battle_failure("TEAM_REPLAY_TIMEOUT", tr("battle_load_error_sync"), true)
			return false
	if NetworkService.team_active and not NetworkService.is_host:
		if not await _wait_for_team_match_state(GameState.round_index, request_id):
			return false
	return _store_team_battle_package(NetworkService.team_replay, request_id)

func _wait_for_team_match_state(completed_round: int, request_id: String) -> bool:
	var wait_elapsed := 0.0
	while not _has_team_match_state(completed_round):
		if NetworkService.state == NetworkService.SessionState.FAILED or NetworkService.state == NetworkService.SessionState.RECONNECTING:
			_set_battle_failure("NETWORK_INTERRUPTED", tr("battle_load_error_network"), true)
			return false
		if not _battle_request_is_active(request_id):
			return false
		_update_team_wait_status(wait_elapsed, request_id)
		await get_tree().create_timer(0.1).timeout
		wait_elapsed += 0.1
		if wait_elapsed >= TEAM_BATTLE_PREP_TIMEOUT_SEC:
			_set_battle_failure("TEAM_RESULT_TIMEOUT", tr("battle_load_error_sync"), true)
			return false
	return true

func _has_team_match_state(completed_round: int) -> bool:
	return not NetworkService.latest_match_state.is_empty() and int(NetworkService.latest_match_state.get("completed_round", -1)) == completed_round and int(NetworkService.latest_match_state.get("protocol", -1)) == NetworkConfig.NETWORK_PROTOCOL_VERSION

func _store_team_battle_package(replay: Dictionary, request_id: String) -> bool:
	if not _battle_request_is_active(request_id):
		return false
	if not BattleReplayUtil.valid_team_replay(replay):
		_set_battle_failure("TEAM_REPLAY_INVALID", tr("battle_load_error_replay"), true)
		return false
	NetworkService.team_replay = replay
	GameState.set_pending_battle_package({
		"mode": "team_replay",
		"round_index": GameState.round_index,
		"replay": replay,
	})
	return true


func _update_team_wait_status(wait_elapsed: float, request_id: String) -> void:
	if not _battle_request_is_active(request_id):
		return
	if _battle_loading_overlay == null or not is_instance_valid(_battle_loading_overlay):
		return
	var total := 0
	var ready := 0
	for i in NetworkService.team_slot_states.size():
		var state := str(NetworkService.team_slot_states[i])
		if state == "empty":
			continue
		total += 1
		if state == "dummy" or (i < NetworkService.team_ready.size() and bool(NetworkService.team_ready[i])):
			ready += 1
	var remaining := maxf(0.0, TEAM_BATTLE_PREP_TIMEOUT_SEC - wait_elapsed)
	_battle_loading_overlay.set_stage("wait_team_server", tr("battle_load_wait_server"),
		tr("battle_load_wait_ready") % [ready, total, remaining], -1.0)
	_battle_loading_overlay.set_network_text(tr("battle_load_network_state") % _network_state_label())


func _network_state_label() -> String:
	match NetworkService.state:
		NetworkService.SessionState.READY:
			return "READY"
		NetworkService.SessionState.JOINING:
			return "JOINING"
		NetworkService.SessionState.RECONNECTING:
			return "RECONNECTING"
		NetworkService.SessionState.FAILED:
			return "FAILED"
		_:
			return "OFFLINE"


func _battle_request_is_active(request_id: String) -> bool:
	return is_inside_tree() and not request_id.is_empty() \
		and request_id == _battle_action_request_id \
		and AsyncActionController.is_current(request_id)


func _fail_current_battle_action() -> void:
	if _battle_failure_code.is_empty():
		_set_battle_failure("BATTLE_PREP_FAILED", tr("battle_load_error_sync"), true)
	AsyncActionController.fail(_battle_action_request_id, _battle_failure_code, _battle_failure_retryable)


func _on_async_action_state_changed(
	action: String,
	request_id: String,
	state: String,
	snapshot: Dictionary
) -> void:
	if action != BATTLE_ACTION or request_id != _battle_action_request_id:
		return
	match state:
		AsyncActionController.STATE_SUCCEEDED:
			if _start_battle_button != null:
				_start_battle_button.show_terminal(request_id, state, tr("battle_load_enter"))
		AsyncActionController.STATE_FAILED:
			_recover_battle_prepare(true, state, snapshot)
		AsyncActionController.STATE_TIMED_OUT:
			if _battle_failure_code.is_empty():
				_set_battle_failure("ACTION_TIMEOUT", tr("battle_load_error_sync"), true)
			_recover_battle_prepare(true, state, snapshot)
		AsyncActionController.STATE_CANCELLED:
			_recover_battle_prepare(false, state, snapshot)


func _recover_battle_prepare(show_failure: bool, state: String, snapshot: Dictionary) -> void:
	GameState.clear_pending_battle_package()
	BattleAssetService.release_owner(BattleAssetService.OWNER_BATTLE)
	_loaded_battle_scene = null
	_battle_thread_requested = false
	_battle_thread_path = ""
	_battle_transition_running = false
	_battle_launch_emitted = false
	if _start_battle_button != null:
		_start_battle_button.show_terminal(_battle_action_request_id, state,
			tr("battle_load_failed") if show_failure else tr("ui_start_battle_btn"))
	if show_failure:
		var code := _battle_failure_code
		if code.is_empty():
			code = str(snapshot.get("error_code", "BATTLE_PREP_FAILED"))
		if _battle_loading_overlay != null and is_instance_valid(_battle_loading_overlay):
			_battle_loading_overlay.set_failed(code, _battle_failure_message, _battle_failure_retryable)
	else:
		_close_battle_loading_overlay()
		if _start_battle_button != null:
			_start_battle_button.reset_idle(_battle_action_request_id)


func _on_battle_loading_cancel_requested(request_id: String) -> void:
	if request_id != _battle_action_request_id:
		return
	var overlay_state := _battle_loading_overlay.snapshot() if _battle_loading_overlay != null else {}
	if str(overlay_state.get("mode", "")) == BattleLoadingOverlayScript.MODE_FAILED:
		_close_battle_loading_overlay()
		AsyncActionController.reset(BATTLE_ACTION, request_id)
		if _start_battle_button != null:
			_start_battle_button.reset_idle(request_id)
		_battle_action_request_id = ""
		return
	if not AsyncActionController.cancel(request_id, "user_cancelled"):
		if _battle_loading_overlay != null and is_instance_valid(_battle_loading_overlay):
			_battle_loading_overlay.set_cancel_policy(false, tr("battle_load_cannot_cancel"))


func _on_battle_loading_retry_requested(request_id: String) -> void:
	if request_id != _battle_action_request_id:
		return
	_close_battle_loading_overlay()
	AsyncActionController.reset(BATTLE_ACTION, request_id)
	if _start_battle_button != null:
		_start_battle_button.reset_idle(request_id)
	_battle_action_request_id = ""
	_emit_battle_request_once.call_deferred()


# V2 P1-08：返回键落到备战页时，先关掉页面自己的面板再谈退出。
# 顺序与玩家的心智一致：最后打开的最先关。ModalStack 管的那几层（宝藏、佣兵、
# 重连提示）已经在 Main 里更早一步处理掉了，这里只管备战页自建的面板。
#
# 返回 true 表示「这一下被消费了」，Main 就不再往下走二次确认退出。
func handle_back_request() -> bool:
	if _shop != null and _shop.picker_open:
		_shop.close_picker()
		return true
	if _merc_picker_open:
		_close_merc_picker()
		return true
	if _team_mercs_open:
		_close_team_mercs_picker()
		return true
	return false
