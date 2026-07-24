extends "res://scenes/battle/BattleResult.gd"

const BattleReplayUtil = preload("res://scripts/battle/BattleReplayUtil.gd")

var _replay: Dictionary = {}
var _replay_mode := false
var _replay_frame := 0
# 已灌入 visual_events 的最高回放帧号，避免重复播放同一帧的视觉事件。
var _replay_events_applied := -1
var _replay_by_uid: Dictionary = {}
var _battle_setup_ready := false
# 切镜头观战：_replay 永远是"正在播放"的那份；自己队伍的原始 replay 存在
# _replay_own（结算/跳过必须用它），敌方队伍的存在 _replay_rival。
var _replay_own: Dictionary = {}
var _replay_rival: Dictionary = {}
var _view_toggle_btn: Button
const TEAM_REPLAY_WAIT_TIMEOUT_SEC := 20.0

func _ready() -> void:
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
		var my_team := 0 if NetworkService.team_local_slot < 3 else 1
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
	if _uses_authoritative_online_result():
		NetworkService.clear_pvp_result()
		if not NetworkService.pvp_result_received.is_connected(_on_pvp_result_received):
			NetworkService.pvp_result_received.connect(_on_pvp_result_received)
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
	_refresh_visuals()
	_battle_setup_ready = true
func _exit_tree() -> void:
	_stop_battle_music()

func _process(delta: float) -> void:
	if not _battle_setup_ready:
		return
	# _update_vfx_camera_shake is defined in BattleVfx (a base class), so the old
	# per-frame has_method() check was always true — pure overhead.
	_update_vfx_camera_shake()
	_model_facing_elapsed += delta
	if _model_facing_elapsed >= MODEL_FACING_UPDATE_SEC:
		_model_facing_elapsed = 0.0
		_model_facing_due = true
	if _waiting_authoritative_result:
		_poll_authoritative_result(delta)
		return
	if _finished:
		return
	if _replay_mode:
		_sim_accumulator += delta * PLAYBACK_SPEED
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
	_load_replay_roster(replay)
	_prefetch_battle_assets()
	# (4) PvP canonical arrangement puts team A at the bottom. If I'm on team B, flip
	# the arena vertically so my own units are always the ones at the bottom.
	var my_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	var my_team := 0 if my_slot < 3 else 1
	_arena_flip_y = str(replay.get("kind", "")) == "pvp" and my_team == 1
	if not replay.get("frames", []).is_empty():
		_apply_replay_frame(0)
		_build()
		_setup_view_toggle()
		_start_battle_music()
		_refresh_visuals()
		_battle_setup_ready = true

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
	if _finished or _return_emitted or not _replay_mode:
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

func _switch_active_replay(replay: Dictionary) -> void:
	_clear_unit_visuals()
	_replay = replay
	# 切换到另一份 replay：视觉事件游标随之重置，从新时间线重新灌。
	_replay_events_applied = -1
	_state["visual_events"] = []
	_vfx_visual_event_index = 0
	_load_replay_roster(replay)
	_prefetch_battle_assets()
	var frames: Array = replay.get("frames", [])
	if not frames.is_empty():
		# 两份 replay 同为 0.1s/帧的时间线，直接续在当前进度上（短的那份停在末帧）。
		_apply_replay_frame(clampi(_replay_frame - 1, 0, frames.size() - 1))
	_refresh_visuals()

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
	_status_vfx_by_id.clear()
	# VFX 差分缓存也按 uid 记上一帧血量/存活，不清会在切换瞬间放出假伤害/死亡特效。
	_vfx_prev_units = {}
	_vfx_seeded = false
	_vfx_visual_event_index = 0

func _show_team_waiting() -> void:
	if _result_overlay_lbl == null:
		return
	_result_overlay_lbl.text = tr("battle_preparing")
	_result_overlay_lbl.add_theme_font_size_override("font_size", 34)
	_result_overlay_lbl.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	_result_overlay_lbl.visible = true

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
				for ev in frame_events[j]:
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
	if _view_toggle_btn != null:
		_view_toggle_btn.visible = false
	_finished = true
	_result = _replay.get("result", {})
	_return_emitted = true
	_stop_battle_music()
	_show_result_overlay()
	await get_tree().create_timer(RESULT_DISPLAY_SECONDS).timeout
	battle_finished.emit(_result)

func _skip_animation() -> void:
	if _replay_mode:
		if _return_emitted:
			return
		if _watching_rival:
			_set_watching_rival(false)
		var frames: Array = _replay.get("frames", [])
		if not frames.is_empty():
			_apply_replay_frame(frames.size() - 1)
		_replay_frame = frames.size()
		_refresh_visuals()
		_finish_replay()
		return
	super._skip_animation()
