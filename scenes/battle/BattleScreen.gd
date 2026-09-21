extends "res://scenes/battle/BattleResult.gd"

const BattleReplayUtil = preload("res://scripts/battle/BattleReplayUtil.gd")
const BattlePresentationDirectorScript := preload("res://effects/runtime/presentation/BattlePresentationDirector.gd")
const LegacyBattleVfxAdapterScript := preload("res://effects/runtime/presentation/adapters/LegacyBattleVfxAdapter.gd")
const VfxProfileResolverScript := preload("res://effects/runtime/presentation/VfxProfileResolver.gd")

# Upper bound on how long the result page may wait for presentation cues.
const PRESENTATION_DRAIN_TIMEOUT_SEC := 3.0

# --- V2 P1-01：最短可读演出时长 -----------------------------------------------
#
# 问题：固定 seed 的两个 PVE 回合实测只有 46 帧和 35 帧，按 SIM_TICK_SEC=0.1 播出来
# 就是 4.6 秒和 3.5 秒。技能起手、命中、死亡挤在一起，玩家来不及看清发生了什么。
#
# 做法：**只改播放节奏，不碰模拟**。回放是一个已经算完的帧数组，播放速度决定的只是
# 走多快；帧的内容、顺序、最终状态都不受影响。所以这里拉长的是可读窗口，
# 不是战斗本身 —— final_state / replay / frame_events 三个哈希必须逐字不变，
# 这一点由 tools/battle_presentation_baseline 的改前/改后对比守住。
#
# 刻意不做的事：
#   * 不改 SIM_TICK_SEC（那是模拟步长，动它就是改战斗）
#   * 不加速：natural >= 目标时保持 1.0，长战不会被压缩
#   * 拉长有上限（READABLE_MIN_PLAYBACK_SPEED），否则一场 1 秒的战斗会被抻成慢动作
#
# 覆盖范围：**只覆盖回放路径**。本地模拟分支事先不知道总时长，无法据此定速度；
# 那条路要另想办法（按事件密度动态调速），不在本项范围内。
const READABLE_MIN_SEC := 5.0
const READABLE_MIN_SEC_BOSS := 8.0
# 最慢到 0.5 倍速，也就是最多拉长一倍。再慢就从"看得清"变成"拖沓"。
const READABLE_MIN_PLAYBACK_SPEED := 0.5

# 本场回放的播放倍率。1.0 表示自然时长已经够读，不做任何拉伸。
var _readable_speed := 1.0
const VFXSummonSpawn3D := preload("res://effects/vfx3d/modules/VFXSummonSpawn3D.gd")
const FINAL_SUMMON_RED := preload("res://effects/vfx3d/profiles/formation/summon_formation_red.tres")
const FINAL_SUMMON_BLUE := preload("res://effects/vfx3d/profiles/formation/summon_formation_blue.tres")
const FINAL_ROUND_INTRO_SEC := 2.05

var _replay: Dictionary = {}
var _replay_mode := false
var _replay_frame := 0
# 已灌入 visual_events 的最高回放帧号，避免重复播放同一帧的视觉事件。
var _replay_events_applied := -1
var _replay_by_uid: Dictionary = {}
var _battle_setup_ready := false
var _final_round_intro_active := false
var _final_round_intro_started := false
# 切镜头观战：_replay 永远是"正在播放"的那份；自己队伍的原始 replay 存在
# _replay_own（结算/跳过必须用它），敌方队伍的存在 _replay_rival。
var _replay_own: Dictionary = {}
var _replay_rival: Dictionary = {}
var _view_toggle_btn: Button
# 9.13 #2：自己这一场已经播完（含"跳过画面"）、正在等其他人结束时置真。
# 这个状态下允许继续切镜头看另一队的战斗 —— 打完之后切过去只推回放，
# 不再走任何结算/返回逻辑（_finish_replay 只允许跑一次）。
var _settlement_waiting := false
# 补看另一队时的播放游标是否已经到末帧（到了就停住，不再推进、也不触发结算）。
var _spectate_done := false
# B8: on-screen frame-rate readout (player-facing only, like PrepScreen).
# Battle scene had none before this; see bug report 9.9bug提交及修复08 #8.
var _fps_label: Label
var _fps_accum := 0.0
var _presentation_director: RefCounted = BattlePresentationDirectorScript.new()
# D4: migration-period adapter. It only plays cues for units in
# BattlePresentationSlice; everything else is completed immediately and keeps
# being drawn by the legacy snapshot-diff path in BattleVfx.
var _legacy_vfx_adapter: RefCounted = LegacyBattleVfxAdapterScript.new()
# D5: resolves the .tres cue profile for each event. Loaded on the first battle
# so the profiles are not read during scene instantiation.
var _vfx_profile_resolver: RefCounted = VfxProfileResolverScript.new()
var _vfx_profiles_loaded := false
# 临时缓解（B7），与 PrepScreen.TEAM_BATTLE_PREP_TIMEOUT_SEC /
# NetworkService.REPLAY_TIMEOUT_SEC 必须保持同量级：三处任何一处偏小，
# 客户端就会先于服务器看门狗放弃。这是 fallback 路径，主路径在 PrepScreen。
const TEAM_REPLAY_WAIT_TIMEOUT_SEC := 60.0

func _ready() -> void:
	_setup_fps_overlay()
	_setup_voice_controls()
	if GameState.team_mode:
		var package := GameState.take_pending_battle_package()
		if str(package.get("mode", "")) == "team_replay":
			var prepared_replay: Dictionary = package.get("replay", {}) as Dictionary
			if BattleReplayUtil.valid_team_replay(prepared_replay):
				_start_replay(prepared_replay)
				return
			push_warning("Prepared team replay was invalid; falling back to BattleScreen wait.")
		_kind = "team"
		await get_tree().process_frame
		if not is_inside_tree():
			return
		_build()
		await get_tree().process_frame
		if not is_inside_tree():
			return
		_show_team_waiting()
		_start_battle_music()   # start BGM immediately, before the host's board-wait
		_battle_setup_ready = true
		if not NetworkService.team_active:
			# 分帧计算：算的过程中玩家可能退出战斗界面，await 回来必须先确认还在树上。
			var local_a: Dictionary = await BattleSim.compute_team_replay_async(0)
			if not is_inside_tree():
				return
			var local_b: Dictionary = await BattleSim.compute_team_replay_async(1)
			if not is_inside_tree():
				return
			BattleSim.stamp_team_round_damages(local_a, local_b)
			NetworkService.team_replay_rival = local_b
			_start_replay(local_a)
			return
		NetworkService.team_replay = {}
		NetworkService.team_replay_rival = {}
		NetworkService.team_submit_board(NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots))
		var my_team := GameConstants.team_of_slot(NetworkService.team_local_slot)
		if NetworkService.is_host and not bool(NetworkService.get("_dedicated_server")):
			# Host waits for everyone's board, computes BOTH teams' replays, sends
			# each player their team's, and plays its own.
			while not NetworkService.team_boards_available():
				await get_tree().create_timer(0.1).timeout
			var replay_a: Dictionary = await BattleSim.compute_team_replay_async(0)
			if not is_inside_tree():
				return
			var replay_b: Dictionary = await BattleSim.compute_team_replay_async(1)
			if not is_inside_tree():
				return
			BattleSim.stamp_team_round_damages(replay_a, replay_b)
			NetworkService.team_broadcast_replays(replay_a, replay_b)
			NetworkService.team_replay_rival = replay_b if my_team == 0 else replay_a
			_start_replay(replay_a if my_team == 0 else replay_b)
		else:
			# Client waits for the host's replay, then plays it.
			var wait_elapsed := 0.0
			print("[NET] waiting for replay round=%d" % GameState.round_index)
			while not _valid_team_replay(NetworkService.team_replay):
				await get_tree().create_timer(0.1).timeout
				# 本函数其余每个 await 点都有这道守卫，唯独这个循环漏了。
				# 场景被 Main._clear() 移除后（例如重连成功落回备战），这个协程还在
				# 计时，到点就 _fail_team_replay -> battle_finished(error)，把一个已经
				# 好好待在备战界面的玩家踹回主菜单。
				# 注意这只是止血：完整修法是整段流程用 cancel token / attempt
				# generation，并校验 battle_id 与代次（B12，见文档 1B-5）。
				if not is_inside_tree():
					return
				wait_elapsed += 0.1
				if not NetworkService.team_replay.is_empty() and not _valid_team_replay(NetworkService.team_replay):
					print("[NET] replay invalid round=%d" % GameState.round_index)
					_fail_team_replay("invalid_replay")
					return
				if wait_elapsed >= TEAM_REPLAY_WAIT_TIMEOUT_SEC:
					print("[NET] replay timeout round=%d" % GameState.round_index)
					_fail_team_replay("replay_timeout")
					return
			print("[NET] replay received round=%d" % GameState.round_index)
			_start_replay(NetworkService.team_replay)
		return
	# 到这里 team_mode 必为 false，而那只有教学会留成 false（见 prepare_tutorial_state）。
	_kind = TutorialMode.battle_kind()
	_state = BattleSim.prepare_tutorial_state(_kind)
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_prefetch_battle_assets()
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_build()
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_start_battle_music()
	await get_tree().process_frame
	if not is_inside_tree():
		return
	await _prepare_battle_models()
func _exit_tree() -> void:
	_presentation_director.dispose()
	if _voice_controls != null:
		_voice_controls.teardown()
	_stop_battle_music()
	# 本回合的敌人资源到此为止；玩家阵容留着，下回合还要用。
	release_round_assets()

func _process(delta: float) -> void:
	# B8: keep the on-screen FPS readout live in every mode (team + tutorial).
	if _fps_label != null:
		_fps_accum += delta
		if _fps_accum >= 0.25:
			_fps_accum = 0.0
			_fps_label.text = "FPS %d" % int(Engine.get_frames_per_second())
	if not _battle_setup_ready:
		return
	# _update_vfx_camera_shake is defined in BattleVfx (a base class), so the old
	# per-frame has_method() check was always true — pure overhead.
	_update_vfx_camera_shake()
	# 水晶演出要在 _finished 之后才播（结算时才召唤），所以必须放在下面那个
	# `if _finished: return` 之前，否则水晶不漂浮、血量数字也不会跟到水晶脚下。
	_update_crystal_demo(delta)
	if _finished:
		# 9.13 #2：自己打完了（或跳过了动画）在等别人时，仍然让「查看另一队」能用。
		# 这里只推进补看的回放，绝不重入 _finish_replay —— 结算与 battle_finished
		# 只能发一次，否则会被重复拉进备战/结算。
		if _settlement_waiting and _watching_rival and _replay_mode:
			_advance_spectate(delta)
		return
	if _final_round_intro_active:
		return
	if _replay_mode:
		# 累加器必须封顶，否则慢帧会自我放大成死亡螺旋：一帧慢 -> delta 变大 ->
		# 下一帧要补更多回放帧（每帧还要把 visual_events 灌进 _state 生成特效）
		# -> 更慢 -> 补更多。实测一次发作是 683ms -> 冻结 5s -> 单帧 4655ms，
		# 全程 draw call 反而从 274 掉到 24（画面越空越卡），直到回放播完才恢复。
		# 封顶后追不上就丢时间，宁可回放比实时略慢，也不攒出无限积压。
		# 下面本地模拟那条分支一直有 MAX_STEPS_PER_FRAME，只有这里漏了。
		_sim_accumulator = minf(_sim_accumulator + delta * PLAYBACK_SPEED * _readable_speed,
			SIM_TICK_SEC * MAX_STEPS_PER_FRAME)
		var frames: Array = _replay.get("frames", [])
		# 时间线终点：看自己时就是己方 replay 的长度；观战敌方时取两边较长者，
		# 敌方打得久也能看完，且己方结果照常在时间线走完后结算。
		var own_size := (_replay_own.get("frames", []) as Array).size()
		var timeline_end := maxi(frames.size(), own_size) if _watching_rival else frames.size()
		while _sim_accumulator >= SIM_TICK_SEC and _replay_frame < timeline_end:
			_sim_accumulator -= SIM_TICK_SEC
			if _replay_frame < frames.size():
				_apply_replay_frame(_replay_frame)
			_replay_frame += 1
		_refresh_visuals()
		if _replay_frame >= timeline_end:
			_finish_replay()
		return
	# 3v3 只播服务器 replay;replay 没到时 _state 还是空 {}，绝不能跑本地模拟
	# （否则每帧 step_state({}) 崩溃刷屏，表现成“一直断线”）。replay 一到
	# _start_replay 会把 _replay_mode 置真，走上面的播放分支。
	if GameState.team_mode:
		return
	# _vfx_hit_stop_active() already returns VFXManager.is_hitstop_active(); the old
	# condition checked the same thing twice and resolved a node path every frame.
	if _vfx_hit_stop_active():
		_refresh_visuals()
		return
	_sim_accumulator += delta * PLAYBACK_SPEED
	var steps := 0
	while _sim_accumulator >= SIM_TICK_SEC and steps < MAX_STEPS_PER_FRAME:
		_sim_accumulator -= SIM_TICK_SEC
		steps += 1
		BattleSim.step_state(_state)
		if bool(_state.get("finished", false)):
			_finish_simulation()
			break
	if _return_emitted:
		return
	_refresh_visuals()

# --- B2: replay playback ----------------------------------------------------
func _start_replay(replay: Dictionary) -> void:
	if not _valid_team_replay(replay):
		_show_team_waiting()
		return
	if _result_overlay_lbl != null:
		_result_overlay_lbl.visible = false
	_replay = replay
	_replay_own = replay
	_replay_rival = NetworkService.team_replay_rival if _valid_team_replay(NetworkService.team_replay_rival) else {}
	_watching_rival = false
	_replay_mode = true
	_replay_frame = 0
	_replay_events_applied = -1
	# 9.19：每局重置「末日守卫技能音已响过」记录，否则同一实例跑第二局（离线自测
	# 回编辑态后再演示）时那一次也不会响。见 BattleVfx._doom_skill_sfx_played。
	_doom_skill_sfx_played.clear()
	# 9.19：人王奖励音/flash 的同款每局一次标记，也要跟着清。
	_human_king_reward_played = false
	# 上一局的胜利收束不能带进这一局，否则镜头会一场比一场紧。
	reset_battle_camera_framing()
	_begin_presentation_replay(replay)
	_load_replay_roster(replay)
	# 9.20：换了一局就必须把 VFX 差分缓存**重新播种**（下面的方法里写清了理由）。
	_reseat_vfx_diff_for_new_battle()
	_prefetch_battle_assets()
	# (4) PvP canonical arrangement puts team A at the bottom. If I'm on team B, flip
	# the arena vertically so my own units are always the ones at the bottom.
	var my_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	var my_team := GameConstants.team_of_slot(my_slot)
	# 决赛除外：那一局的战斗轴是左右（_apply_final_round_left_right_layout），翻 Y
	# 换不到"自己在下方"，只会把 B 队玩家的画面上下镜像。决赛 replay 的 kind 同样是
	# "pvp"（被 prepare_team_state 改写过），所以必须按回合号单独排除。
	_arena_flip_y = str(replay.get("kind", "")) == "pvp" and my_team == 1 \
		and GameState.round_index != GameState.FINAL_ROUND
	if not replay.get("frames", []).is_empty():
		_apply_replay_frame(0)
		_build()
		_setup_view_toggle()
		_start_battle_music()
		await _prepare_battle_models()
		# Actors are registered now, so queued cues may resolve their anchors.
		_readable_speed = _compute_readable_speed()
		_presentation_director.set_playback_speed(PLAYBACK_SPEED * _readable_speed)


# 每帧最多建几个单位模型。3 个是折中：太小则读条拖长，太大则单帧又开始卡。
# 实测单个单位模型的实例化 + bounds + 动画绑定在这台机器上约 20–60 ms。
const MODELS_PER_FRAME := 3

# 分帧建单位模型，全程隐藏，建完一次性显形，建完才开打。
#
# 三件事各自的理由：
#   分帧：一帧建 491 个节点实测 proc=1104ms，整帧堵死，心跳都发不出去
#         （实测 process freeze 6.3s + pong silence，差点被服务器判掉线）。
#         分帧不减少总耗时，收益是主线程不断流。
#   隐藏：上一版分帧是「建一个显一个」，玩家看到棋子一个一个冒出来。
#         整个建造期把 3D 根藏起来，最后一次性打开，观感上就是「一起出现」。
#   读条：顶部细线接住备战界面那条蓝线，空棋盘期不至于像「画面卡住」。
#
# 必须「建完才开打」——否则 _apply_replay_frame 会去定位还不存在的单位。
func _prepare_battle_models() -> void:
	var living: Array = []
	for f in (_state.get("player", []) + _state.get("enemy", [])):
		if typeof(f) == TYPE_DICTIONARY and bool(f.get("alive", false)):
			living.append(f)
	var total := living.size()
	if _battle_3d_root != null:
		_battle_3d_root.visible = false
	var bar := _make_battle_prepare_bar() if total > MODELS_PER_FRAME else null
	var done := 0
	for f in living:
		# 只建不删（prune=false）：_sync_3d_model_nodes 的收尾会清掉「不在传入列表里」
		# 的模型，而这里一次只喂一个单位，照常清理的话每建一个就会毁掉前面全部。
		# facing_delta=0：此处没跑过 _begin_visual_frame，帧内单位表是空的，
		# 转向要等第一次 _refresh_visuals 再算（那次会直接吸附到位）。
		_sync_3d_model_nodes([f], 0.0, false)
		done += 1
		if done % MODELS_PER_FRAME == 0:
			if bar != null:
				bar.value = 100.0 * float(done) / float(maxi(1, total))
			await get_tree().process_frame
			if not is_inside_tree() or _finished:
				# 中途退出也要把根恢复可见，否则这个节点被复用时棋盘是空的。
				if _battle_3d_root != null:
					_battle_3d_root.visible = true
				return
	if bar != null and is_instance_valid(bar):
		bar.queue_free()
	_refresh_visuals()
	if _battle_3d_root != null:
		_battle_3d_root.visible = true
	_battle_setup_ready = true
	# 9.17：Boss 登场。放在这里而不是 _start_battle_music() 里 ——
	# 后者在进场景那一刻就会被调一次（BattleScreen.gd:98），那时 replay 还没到、
	# 单位模型还没建，声音会比画面早一整段读条。
	#
	# 这里是「模型全部建完、战斗马上开打」，而且 _prepare_battle_models() 每场
	# 只跑一次（_start_replay 里那一条调用），天然不会重复。
	#
	# 判据用 _effective_kind() 而不是 _kind：3v3 时 _kind 停在占位的 "team"，
	# 真正的类型要么在 replay 里，要么按回合表算（boss 回合 = 5/10/15/20）。
	#
	# 「停掉备战 BGM + 响登场音」打包在 BattleUI._begin_boss_intro() 里：两件事必须
	# **同一时刻**发生（9.17 第三轮反馈），拆在两个地方迟早漂移。
	if _effective_kind() == "boss":
		_begin_boss_intro()
	# 9.21 用户口径第 3 条：最终回合 pvp 战斗场景开局音。
	#
	# 位置与 boss 登场音并列，理由相同（见上一段）：这里是「模型全建完、战斗马上
	# 开打」，不是进场景那一刻。演出顺序是「响开局音 → 播完 → 起 pvp 战斗 BGM」，
	# 由本函数末尾的 _resolve_pending_battle_music() 收口。
	#
	# ★ 判据是 `_effective_kind() == "final"`，**不是** _try_start_final_round_intro()
	#   的成功与否：后者只在「场上真有阵型盟友」时才演出召唤，而开局音是场景级的
	#   开场（用户要的是「最终回合时开局播放」）。挂在那个返回值上会让没有阵型
	#   盟友的最终回合整场没有开场音。
	if _effective_kind() == "final":
		_begin_final_round_intro()
	_try_start_final_round_intro()
	# 9.17 反馈第 4 条：登场音播完之后才起 pve 战斗 BGM。
	# 放在本函数**最末尾**：这是「模型全建完、战斗马上开打」的那一刻，
	# 也是本函数里唯一保证会走到的收口点（前面几个早退分支都在建模型循环里）。
	await _resolve_pending_battle_music()

# 顶部一条细进度条，接着备战界面那条蓝线继续走，避免「画面停住」的观感。
func _make_battle_prepare_bar() -> ProgressBar:
	var bar := ProgressBar.new()
	bar.name = "BattlePrepareBar"
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	# 只设 custom_minimum_size，不要再写 bar.size.y —— PRESET_TOP_WIDE 左右锚点
	# 不相等，直接写 size 会被 _ready() 后的布局覆盖并刷一条警告。
	bar.custom_minimum_size = Vector2(0.0, 5.0)
	bar.z_index = 200
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.02, 0.13, 0.16, 0.55)
	var fill := StyleBoxFlat.new()
	# 和备战界面 RiverLaneProgressBar 的填充色一致，视觉上是同一条读条接力。
	fill.bg_color = Color(0.20, 0.95, 0.92, 0.82)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	add_child(bar)
	return bar

func _try_start_final_round_intro() -> void:
	if _final_round_intro_started or GameState.round_index != GameState.FINAL_ROUND:
		return
	var formation_allies: Array = []
	for fighter in _state.get("player", []) + _state.get("enemy", []):
		if bool(fighter.get("alive", false)) and bool(fighter.get("is_formation_ally", false)):
			formation_allies.append(fighter)
	if formation_allies.is_empty() or _battle_3d_world == null:
		return
	_final_round_intro_started = true
	_final_round_intro_active = true
	_set_formation_allies_intro_hidden(true)
	for fighter in formation_allies:
		var fx := VFXSummonSpawn3D.new()
		fx.name = "FinalRoundFormationSummon_%s" % str(fighter.get("team", "side"))
		_battle_3d_world.add_child(fx)
		var profile = FINAL_SUMMON_RED if str(fighter.get("team", "")) == "player" else FINAL_SUMMON_BLUE
		fx.reveal_requested.connect(_reveal_final_formation_ally.bind(_visual_id(fighter)))
		fx.play_summon(_sim_to_world_pos(Vector2(fighter.get("pos", Vector2.ZERO))), profile)
	_finish_final_round_intro_after_delay()


func _reveal_final_formation_ally(id: String) -> void:
	var model_node: Node3D = _battle_3d_models.get(id)
	var unit_node: Control = _unit_nodes.get(id)
	if unit_node != null and is_instance_valid(unit_node):
		unit_node.visible = true
	if model_node == null or not is_instance_valid(model_node):
		return
	model_node.visible = true
	var resting_y := model_node.position.y
	model_node.position.y = resting_y - 0.75
	model_node.scale *= 0.72
	var target_scale := model_node.scale / 0.72
	var tween := model_node.create_tween()
	tween.set_parallel(true)
	tween.tween_property(model_node, "position:y", resting_y, 0.38).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(model_node, "scale", target_scale, 0.38).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _finish_final_round_intro_after_delay() -> void:
	await get_tree().create_timer(FINAL_ROUND_INTRO_SEC).timeout
	if not is_inside_tree() or _finished:
		return
	_set_formation_allies_intro_hidden(false)
	_final_round_intro_active = false


func _load_replay_roster(replay: Dictionary) -> void:
	_replay_by_uid = {}
	var players: Array = []
	var enemies: Array = []
	var roster: Dictionary = replay.get("roster", {})
	for uid in roster:
		var r: Dictionary = roster[uid]
		var f := {
			"uid": uid, "id": str(r.get("id", "")), "name": str(r.get("name", "")),
			"name_en": str(r.get("name_en", "")),
			"team": str(r.get("team", "")), "lane": int(r.get("lane", 0)),
			"max_hp": int(r.get("max_hp", 1)), "hp": int(r.get("max_hp", 1)),
			"is_mercenary": bool(r.get("is_mercenary", false)), "star": int(r.get("star", 1)),
			"is_formation_ally": bool(r.get("is_formation_ally", false)),
			"footprint_cells": int(r.get("footprint_cells", 1)), "def": r.get("def", {}),
			"owner_slot": int(r.get("owner_slot", -1)),
			"pos": Vector2.ZERO, "alive": false, "statuses": {}, "shield": 0,
			"range_px": float(r.get("range_px", float(r.get("def", {}).get("range", 1)) * BattleSim.ATTACK_RANGE_SCALE)),
			"attack_count": 0, "skill_ready": 0.0, "skill_stacks": 0,
			"vfx_attack_target_uid": "", "vfx_skill_target_uid": "",
		}
		_replay_by_uid[uid] = f
		if str(r.get("team", "")) == "player":
			players.append(f)
		else:
			enemies.append(f)
	_state = {"kind": str(replay.get("kind", "pve")), "player": players, "enemy": enemies, "elapsed": 0.0, "finished": false, "log": [], "visual_events": [], "unit_stats": {}}

func _valid_team_replay(replay: Dictionary) -> bool:
	return BattleReplayUtil.valid_team_replay(replay)

# --- 切镜头观战敌方队伍 ------------------------------------------------------
func _setup_view_toggle() -> void:
	if _view_toggle_btn != null:
		return
	if not _valid_team_replay(_replay_rival):
		return
	# PVP/决赛双方同场对战，敌方就在画面里，没有第二个战场可切。
	var kind := str(_replay_own.get("kind", ""))
	if kind == "pvp" or kind == "final":
		return
	_view_toggle_btn = Button.new()
	_view_toggle_btn.text = tr("battle_view_rival")
	_view_toggle_btn.custom_minimum_size = Vector2(120, 36)
	_view_toggle_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_view_toggle_btn.offset_left = -136
	_view_toggle_btn.offset_top = 56
	_view_toggle_btn.offset_right = -16
	_view_toggle_btn.offset_bottom = 92
	_view_toggle_btn.z_index = 100
	_view_toggle_btn.pressed.connect(_on_view_toggle_pressed)
	add_child(_view_toggle_btn)

func _on_view_toggle_pressed() -> void:
	# 正常对局中 _return_emitted 之前都能切；进入结算等待后（_settlement_waiting）
	# 虽然 _return_emitted 已经是 true，仍然允许切过去补看另一队（9.13 #2）。
	if _return_emitted and not _settlement_waiting:
		return
	if not _replay_mode:
		return
	_set_watching_rival(not _watching_rival)

func _set_watching_rival(watch_rival: bool) -> void:
	if _watching_rival == watch_rival:
		return
	if watch_rival and not _valid_team_replay(_replay_rival):
		return
	_watching_rival = watch_rival
	if _view_toggle_btn != null:
		_view_toggle_btn.text = tr("battle_view_own") if _watching_rival else tr("battle_view_rival")
	_switch_active_replay(_replay_rival if _watching_rival else _replay_own)

# 结算等待期「补看另一队」的播放推进。与 _process 里的主线播放是**两套**：
# 这里只到末帧为止，不调用 _finish_replay（结算已经发过了）。
func _advance_spectate(delta: float) -> void:
	if _spectate_done:
		return
	# 与主线同一个封顶策略：慢帧不得攒出无限积压。
	_sim_accumulator = minf(_sim_accumulator + delta * PLAYBACK_SPEED * _readable_speed,
		SIM_TICK_SEC * MAX_STEPS_PER_FRAME)
	var frames: Array = _replay.get("frames", [])
	while _sim_accumulator >= SIM_TICK_SEC and _replay_frame < frames.size():
		_sim_accumulator -= SIM_TICK_SEC
		_apply_replay_frame(_replay_frame)
		_replay_frame += 1
	_refresh_visuals()
	if _replay_frame >= frames.size():
		_spectate_done = true

# B8: lightweight on-screen FPS readout for the battle scene.
# 组队语音（docs/聊天系统设计.md 第九节 v1.1）：右上角「跳过」（y 12~48）「切镜头」（y 56~92）下面，
# 竖着放语音与队友两个按钮。只在联机对局里建；档位跨场景保持（VoiceService 是 autoload），
# 这里只是给玩家一个随手开关。
const VoiceControls := preload("res://ui/components/VoiceControls.gd")
const VOICE_BTN_TOP := 100.0
const VOICE_BTN_SIZE := Vector2(120, 36)
const VOICE_BTN_STEP := 42.0
var _voice_controls: VoiceControls = null

func _setup_voice_controls() -> void:
	if _voice_controls != null or not NetworkService.team_active:
		return
	_voice_controls = VoiceControls.new()
	# 9.20 bug 文档第 3 条：战斗界面也要能切语音档位。
	# 此前这里没传 panel_context，于是「队友」按钮既不计人数、打开的面板也拿不到
	# 上下文 —— 玩家在战斗里点它，看不出自己当前在哪一档（关 / 只听 / 开麦）。
	# 与 PrepUI._build_voice_button() 传 "prep" 同一个道理，这里传 "battle"。
	_voice_controls.build(self, VOICE_BTN_SIZE, VOICE_BTN_SIZE, 14, {"panel_context": "battle"})
	var top := VOICE_BTN_TOP
	for button in [_voice_controls.voice_button, _voice_controls.members_button]:
		var control := button as Button
		control.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		control.offset_left = -16.0 - VOICE_BTN_SIZE.x
		control.offset_right = -16.0
		control.offset_top = top
		control.offset_bottom = top + VOICE_BTN_SIZE.y
		# 同「跳过」按钮：盖在全屏战场之上。
		control.z_index = 100
		add_child(control)
		top += VOICE_BTN_STEP

# Mirrors PrepScreen._setup_fps_overlay; positioned slightly off the top-left
# corner (see bug report 9.9bug提交及修复08 #8 — old corner spot was hard to
# see on mobile, "too close to the edge").
func _setup_fps_overlay() -> void:
	if _fps_label != null:
		return
	_fps_label = Label.new()
	_fps_label.name = "FpsOverlay"
	_fps_label.text = "FPS --"
	_fps_label.position = Vector2(16, 8)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_fps_label.add_theme_constant_override("outline_size", 3)
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fps_label.z_index = 300
	add_child(_fps_label)

func _switch_active_replay(replay: Dictionary) -> void:
	_clear_unit_visuals()
	_replay = replay
	# 切换到另一份 replay：视觉事件游标随之重置，从新时间线重新灌。
	_replay_events_applied = -1
	_state["visual_events"] = []
	_vfx_visual_event_index = 0
	_spectate_done = false
	_load_replay_roster(replay)
	_begin_presentation_replay(replay)
	_prefetch_battle_assets()
	var frames: Array = replay.get("frames", [])
	if not frames.is_empty():
		# 两份 replay 同为 0.1s/帧的时间线，直接续在当前进度上（短的那份停在末帧）。
		var target_tick := clampi(_replay_frame - 1, 0, frames.size() - 1)
		# 切换观战目标属于 seek：重建当前姿态，但不重播已经发生的数字、屏震或瞬态 cue。
		_presentation_director.seek_to_tick(target_tick)
		_apply_replay_frame(target_tick)
	_refresh_visuals()
	# _refresh_visuals() re-registered the new roster, so cues can resolve again.
	_presentation_director.set_playback_speed(PLAYBACK_SPEED * _readable_speed)

func _clear_unit_visuals() -> void:
	# 两份 replay 的 uid 命名会撞车（都是 player_L0_0 这类），
	# 切换前必须整场清空，否则旧模型会被错认成新阵容复用。
	for node in _unit_nodes.values():
		if node != null and is_instance_valid(node):
			node.queue_free()
	_unit_nodes.clear()
	_hp_fill_by_id.clear()
	for node in _battle_3d_models.values():
		if node != null and is_instance_valid(node):
			node.queue_free()
	_battle_3d_models.clear()
	cue_release_corpses()
	_unit_actor_registry.clear()
	_status_vfx_by_id.clear()
	# VFX 差分缓存也按 uid 记上一帧血量/存活，不清会在切换瞬间放出假伤害/死亡特效。
	_reseat_vfx_diff_for_new_battle()


# 9.20：把「按 uid 记上一帧」的 VFX 缓存整场重播种。
#
# 两个调用点 —— `_start_replay()`（开一局 / 换一局）与 `_clear_unit_visuals()`
# （切看另一队回放）—— 都是「另一份 uid 空间要开始了」，所以合并成一个定义。
#
# 不清的后果有二（两条都在 9.20 用户实测里出现过或差点出现）：
#   * `BattleVfx._play_opening_unit_vfx()` 是**播种帧专用**（只在 `_vfx_seeded`
#     还是 false 的那一帧跑）。同一个 BattleScreen 实例上再开一局却不重播种，
#     它整场都不会跑 —— 凡是「开局就发生」的演出都会静默：死侍开场绑定音/绑定特效、
#     血契连线、护盾嘲讽。用户报的「死侍开局绑定音不响」就是这一条
#     （officetest 的编辑态预览先占掉了播种帧）。
#   * 回放的 roster 会把战斗中途才出生的单位（寄生分身）提前放进 `_state`，
#     于是第一帧的 diff 会把它们当成「上一帧就在」。
# `visual_events` 游标同步归零：调用点刚把 `_state.visual_events` 换成空数组
# （`_load_replay_roster()` / `_switch_active_replay()`），游标若停在上一局的位置，
# 新一局的前 N 条事件会被静默跳过。
func _reseat_vfx_diff_for_new_battle() -> void:
	_vfx_prev_units = {}
	_vfx_seeded = false
	_vfx_visual_event_index = 0
	_parasite_spawn_announced.clear()

func show_settlement_waiting() -> void:
	_settlement_waiting = true
	# 9.13 #2：另一队的 replay 可能在本场开播之后才到（房主要把两队的都算完才广播），
	# 那时 _setup_view_toggle() 会因为拿不到对手回放直接放弃，按钮压根没建出来。
	# 进等待期时补一次：先补读 replay，再（幂等地）重建按钮。
	if not _valid_team_replay(_replay_rival) and _valid_team_replay(NetworkService.team_replay_rival):
		_replay_rival = NetworkService.team_replay_rival
	_setup_view_toggle()
	if _view_toggle_btn != null:
		# PVP / 决赛两队同场，没有第二个战场可切 —— 与 _setup_view_toggle 同一判据。
		var kind := str(_replay_own.get("kind", ""))
		_view_toggle_btn.visible = _valid_team_replay(_replay_rival) \
			and kind != "pvp" and kind != "final"
	_show_team_waiting()
	if _result_overlay_lbl != null:
		_result_overlay_lbl.text = "需等待其他人战斗结束"

func _show_team_waiting() -> void:
	if _result_overlay_lbl == null:
		return
	_result_overlay_lbl.text = tr("battle_preparing")
	_result_overlay_lbl.add_theme_font_size_override("font_size", 34)
	_result_overlay_lbl.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	_result_overlay_lbl.visible = true


# 入队前把这一 tick 会用到、却还没建出来的身体补上。
#
# 慢设备上回放要追帧：一次 _apply_replay_frame() 可能跨好几个回放帧，于是 j 从
# _replay_events_applied+1 到 i 的 tick 会**一次性全部入队**，而建模要等循环之后的
# _refresh_visuals()。这批 tick 里刚被召唤出来的单位那时还没有 actor，它的第一条
# cue 会被 Director 判成 missing_actor:source 丢掉。
#
# 2026-08-20 实测：桌面每渲染帧恒定推进 1 个回放帧，所以从来不触发；真机第 20 回合
# 只有 8.9 FPS，步长出现 2（26 次）和 3（2 次），镜像领主的镜像因此在 tick 15 丢了
# 两条 attack_start —— 设备 2 条、桌面 0 条。
#
# 这和上面 cue_claim_corpses() 是对称的：那条在入队前把**要死的**身体扣下来，
# 免得 _refresh_visuals() 先把它释放掉；这条在入队前把**刚出生的**身体建出来，
# 免得它还不存在。两条都是同一句话：让渲染层在 Director 排这一 tick 之前就绪。
func _spawn_actors_for_tick(tick_index: int, tick_events: Array) -> void:
	var frames: Array = _replay.get("frames", [])
	if tick_index < 0 or tick_index >= frames.size() or typeof(frames[tick_index]) != TYPE_ARRAY:
		return
	var wanted: Dictionary = {}
	for event_value in tick_events:
		if not (event_value is Dictionary):
			continue
		var uid := str((event_value as Dictionary).get("source_uid", ""))
		if uid.is_empty() or wanted.has(uid):
			continue
		if _unit_actor_registry.get_actor(uid) == null:
			wanted[uid] = true
	if wanted.is_empty():
		return
	for entry in frames[tick_index]:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 5:
			continue
		var uid := str(entry[0])
		if not wanted.has(uid):
			continue
		# 只给这一帧确实活着的单位建体。已经死掉的不该在这里复活，
		# 它的 cue 本来就该按 source_dead 走。
		if not bool(entry[4]):
			continue
		var f = _replay_by_uid.get(uid)
		if f == null:
			continue
		f.pos = Vector2(float(entry[1]), float(entry[2]))
		f.hp = int(entry[3])
		f.alive = true
		# prune=false：这里一次只喂一个单位，照常清理会把其余模型全毁掉
		# （理由同 _prepare_battle_models 里的那段注释）。
		_sync_3d_model_nodes([f], 0.0, false)

func _apply_replay_frame(i: int) -> void:
	var frames: Array = _replay.get("frames", [])
	if i < 0 or i >= frames.size():
		return
	# 把本帧记录的视觉事件（母灵处决 / 屏震 / 技能演出）灌回 _state.visual_events，
	# 前端 _play_visual_events 靠递增游标消费。用 _replay_events_applied 去重，
	# 保证顺序播放每帧只灌一次、来回 seek 也不会重播。
	if i > _replay_events_applied:
		var frame_events: Array = _replay.get("frame_events", [])
		var ve: Array = _state.get("visual_events", [])
		for j in range(_replay_events_applied + 1, i + 1):
			if j >= 0 and j < frame_events.size() and frame_events[j] is Array:
				var tick_events: Array = frame_events[j]
				# D2 dual route: Director becomes the bounded scheduler while the old
				# BattleVfx array remains a compatibility bridge until D6 migration.
				# Claim dying bodies before the Director queues the tick: the next
				# _refresh_visuals() would otherwise free them before the death cue runs.
				cue_claim_corpses(tick_events)
				_spawn_actors_for_tick(j, tick_events)
				_presentation_director.enqueue_tick(j, tick_events)
				for ev in tick_events:
					ve.append(ev)
		_state["visual_events"] = ve
		_replay_events_applied = i
	for f in _replay_by_uid.values():
		f.alive = false
	if typeof(frames[i]) != TYPE_ARRAY:
		return
	for entry in frames[i]:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 5:
			continue
		var f = _replay_by_uid.get(str(entry[0]))
		if f == null:
			continue
		f.pos = Vector2(float(entry[1]), float(entry[2]))
		f.hp = int(entry[3])
		f.alive = bool(entry[4])
		if entry.size() > 5:
			f.attack_count = int(entry[5])
		if entry.size() > 6:
			f.skill_ready = float(entry[6])
		if entry.size() > 7:
			f.shield = int(entry[7])
		if entry.size() > 8:
			f.skill_stacks = int(entry[8])
		if entry.size() > 9 and typeof(entry[9]) == TYPE_DICTIONARY:
			f.statuses = (entry[9] as Dictionary).duplicate(true)
		else:
			f.statuses = {}
		if entry.size() > 10:
			f.damage_dealt = int(entry[10])
		if entry.size() > 11:
			f.vfx_attack_target_uid = str(entry[11])
		if entry.size() > 12:
			f.vfx_skill_target_uid = str(entry[12])

func _fail_team_replay(reason: String) -> void:
	if _return_emitted:
		return
	_return_emitted = true
	_finished = true
	_presentation_director.skip_to_result()
	_stop_battle_music()
	_result = {"kind": "team", "player_wins": false, "error": reason, "log": [reason]}
	if _result_overlay_lbl != null:
		_result_overlay_lbl.text = tr("battle_sync_failed")
		_result_overlay_lbl.visible = true
	battle_finished.emit(_result)

func _finish_replay() -> void:
	if _return_emitted:
		return
	# 结算永远基于己方 replay：正观战敌方时先切回我方战场收尾。
	if _watching_rival:
		_set_watching_rival(false)
	# 9.13 #2：这里**不隐藏**「查看另一队」按钮 —— Main 随后会调
	# show_settlement_waiting()，等待期间玩家要能继续切过去补看另一队。
	# 按钮最终随本场景一起销毁。
	# D4: with a real adapter the cues are asynchronous, so DRAINING actually has
	# something to wait for. Checklist 4.6: hold the result page for the
	# critical/important cues, but never past the cap.
	_presentation_director.begin_draining()
	_finished = true
	_result = _replay.get("result", {})
	_return_emitted = true
	_stop_battle_music()
	# 9.19：人王奖励音 + 升级闪光（见 BattleVfx._play_human_king_reward）。
	# 本地模拟那条路在 BattleResult._emit_finished 里调，这里是 replay/组队那条。
	_play_human_king_reward()
	await _await_presentation_drained()
	await _play_crystal_attack_sequence(_result)
	# V2 P1-05 第 3 条：镜头轻收束 + 幸存者定格，然后才出胜负字样。
	# 9.17 反馈第 3 条：停留时长改为「至少等胜负音播完」（见
	# BattleResult._result_linger_seconds —— 它是 RESULT_DISPLAY_SECONDS
	# 与胜负音实际时长的 max，所以 V2 那条「至少 0.8 秒」仍然被兜住）。
	play_victory_finish()
	_show_result_overlay()
	await get_tree().create_timer(_result_linger_seconds()).timeout
	battle_finished.emit(_result)

func _skip_animation() -> void:
	if _replay_mode:
		if _return_emitted:
			return
		if _watching_rival:
			_set_watching_rival(false)
		_presentation_director.skip_to_result()
		var frames: Array = _replay.get("frames", [])
		if not frames.is_empty():
			_apply_replay_frame(frames.size() - 1)
		_replay_frame = frames.size()
		_refresh_visuals()
		_finish_replay()
		return
	super._skip_animation()


# Skipping calls skip_to_result() first, which clears every queued cue, so this
# returns on the first check instead of stalling the result page.
# 纯函数，供门禁直接喂合成输入验证（见 tools/battle_readable_pace_check.gd）。
#
# 只依赖帧数与回合类型。刻意不看战斗内容 —— 演出节奏不该由谁打赢了决定。
static func readable_speed_for(frame_count: int, tick_sec: float, is_boss: bool) -> float:
	if frame_count <= 0 or tick_sec <= 0.0:
		return 1.0
	var natural_sec := float(frame_count) * tick_sec
	var want_sec := READABLE_MIN_SEC_BOSS if is_boss else READABLE_MIN_SEC
	if natural_sec >= want_sec:
		# 自然就够长：不加速、不减速。长战绝不被压缩。
		return 1.0
	return maxf(natural_sec / want_sec, READABLE_MIN_PLAYBACK_SPEED)


# 让这场回放至少播满可读窗口。返回 1.0 表示自然时长已经够长，不做拉伸。
func _compute_readable_speed() -> float:
	var frames: Array = _replay.get("frames", [])
	var speed := readable_speed_for(frames.size(), SIM_TICK_SEC, _effective_kind() == "boss")
	# 打一行可观测的证据：真机/基线日志里能直接看到这场拉伸了没有、拉了多少。
	if not is_equal_approx(speed, 1.0):
		print("[READABLE_PACE] frames=%d natural=%.2fs speed=%.3f -> %.2fs kind=%s"
			% [frames.size(), float(frames.size()) * SIM_TICK_SEC, speed,
				float(frames.size()) * SIM_TICK_SEC / speed, _effective_kind()])
	return speed


func _await_presentation_drained() -> void:
	var deadline := Time.get_ticks_msec() + int(PRESENTATION_DRAIN_TIMEOUT_SEC * 1000.0)
	while _presentation_director.has_blocking_cues() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if not is_inside_tree():
			return


func _begin_presentation_replay(replay: Dictionary) -> void:
	# Resolver/budget/real adapters intentionally remain null in D2. The existing
	# UnitActorRegistry is passed now so D3 can add anchors without changing the
	# BattleScreen ownership boundary.
	_legacy_vfx_adapter.configure_host(self)
	_legacy_vfx_adapter.reset_stats()
	if not _vfx_profiles_loaded:
		var loaded := int(_vfx_profile_resolver.load_profiles())
		_vfx_profiles_loaded = loaded > 0
		if loaded == 0:
			push_warning("[VFX_PROFILE] no cue profile loaded; every cue runs on the built-in fallback")
	_vfx_profile_resolver.reset_reports()
	_presentation_director.configure(_unit_actor_registry, _vfx_profile_resolver, null, _legacy_vfx_adapter)
	_presentation_director.begin_battle({
		"battle_id": _presentation_battle_id(replay),
		"kind": str(replay.get("kind", "team")),
	})
	# D3: stay paused until every actor is registered. Ticks still enqueue and
	# de-duplicate while paused (_pump_track early-returns at speed 0), so no
	# event is lost; playing them before _prepare_battle_models() finishes would
	# resolve anchors against an empty registry and drop the whole first tick.
	_presentation_director.set_playback_speed(0.0)


func _presentation_battle_id(replay: Dictionary) -> String:
	for bucket_value in (replay.get("frame_events", []) as Array):
		if not (bucket_value is Array):
			continue
		for event_value in (bucket_value as Array):
			if event_value is Dictionary:
				var battle_id := str((event_value as Dictionary).get("battle_id", ""))
				if not battle_id.is_empty():
					return battle_id
	return "local:%s:round%d" % [str(replay.get("kind", "team")), GameState.round_index]
