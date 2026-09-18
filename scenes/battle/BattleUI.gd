extends Control


@warning_ignore("unused_signal")
signal battle_finished(result: Dictionary)

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const UnitActorRegistryScript := preload("res://effects/runtime/presentation/UnitActorRegistry.gd")
const BoardReadabilityLayerScene := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")
const SIM_TICK_SEC := 0.1
const PLAYBACK_SPEED := 1.0
const MAX_STEPS_PER_FRAME := 3
const SKIP_STEPS_PER_FRAME := 80
const SKIP_FRAME_BUDGET_MSEC := 8
const SIM_W := 1000.0
const SIM_H := 520.0
const UNIT_VISUAL_SIZE := Vector2(82, 104)
const UNIT_VISUAL_OFFSET := Vector2(41, 66)
const RESULT_DISPLAY_SECONDS := 1.0
# Free-look facing: models turn toward what they are actually doing (running
# somewhere, hitting someone) instead of holding a fixed per-team yaw.
# 360 deg/s reads as a deliberate, weighty turn rather than a snap.
const MODEL_FACING_TURN_SPEED_DEG := 360.0
# Simulation-space travel required before movement counts as a heading. Matches
# the run animation's own threshold so the two agree on "this unit is moving".
const MODEL_FACING_MOVE_EPS_SIM := 1.0
# Facing advances on wall-clock time, so clamp the step: a frame hitch (or a
# one-off _refresh_visuals outside _process) must not snap everyone at once.
const MODEL_FACING_MAX_DELTA := 0.1
# Spawn pose only, before the first real facing update snaps the model onto its
# aim direction: stand the two sides facing each other.
const MODEL_FACING_SPAWN_ENEMY_YAW := 180.0
const BATTLE_BG_PATH := "res://assets/board/battle_toon_autochess_arena.png"
const BATTLE_USE_3D_ARENA := false
const BATTLE_ARENA_MODEL_PATH := "res://assets/models/arena/battle_scene.glb"
const BATTLE_ARENA_TARGET_WIDTH := 22.0
const BATTLE_ARENA_TARGET_DEPTH := 12.4
const BATTLE_ARENA_GROUND_Y := -0.14
const BATTLE_ARENA_YAW := 0.0
const BATTLE_ARENA_FOREST_TINT := true
const BATTLE_ARENA_FOREST_ALBEDO := Color(0.38, 0.58, 0.30)
const BATTLE_ARENA_FOREST_BLEND := 0.62
const BATTLE_3D_WIDTH := 22.0
const BATTLE_3D_DEPTH := 12.4
const MODEL_SEPARATION_RADIUS := 78.0
const MODEL_SEPARATION_STRENGTH := 42.0
const MODEL_SEPARATION_MAX_OFFSET := 54.0
const MODEL_SEPARATION_BASE_NUDGE := 18.0
const BATTLE_CAMERA_SIZE := 7.2
const BATTLE_CAMERA_POS := Vector3(0.0, 7.4, 7.0)
const BATTLE_PLAYABLE_WIDTH := 14.5
const BATTLE_PLAYABLE_DEPTH := 10.0
const BATTLE_PLAYABLE_OFFSET := Vector3(0.0, 0.0, 0.0)
const BATTLE_VISUAL_MIN := Vector2(95.0, 68.0)
const BATTLE_VISUAL_MAX := Vector2(905.0, 452.0)
const BATTLE_MUSIC_PATH := "res://assets/audio/bgm/fighting_music.mp3"
const PVP_BATTLE_MUSIC_PATH := "res://assets/audio/bgm/pvp_battle_music.mp3"

# 9.17 音效（boss 登场 / 人王阵亡 / 胜负）。
#
# 声明在继承链最底这一层，子类（BattleArena / BattleRenderer / BattleVfx /
# BattleResult / BattleScreen）直接继承，各自再声明一次会撞「成员在父类里已存在」。
#
# **BGM 归 BGM，音效归音效**：BGM 走常驻的 MusicService（播放器挂 root，一个
# 播放器、一首当前曲目），音效一律走 SfxService 的 root 播放器池 ——
# 音效要求「换场景也不被掐断」（胜负音就是在换场景那一刻响的），BGM 要求
# 「离开战斗就停」，而两者都不能挂在战斗场景的子节点上（Main._clear() 会
# 把整个页面子树释放掉）。
const SfxService := preload("res://ui/services/SfxService.gd")
const MusicService := preload("res://ui/services/MusicService.gd")

@export_group("Battle Unit Layout")
@export_range(0.35, 1.0, 0.01) var battle_unit_visual_scale := 0.42
@export_range(-0.5, 2.0, 0.01) var battle_unit_y_offset := 1.0

var _kind := "pve"
var _state: Dictionary = {}
var _result: Dictionary = {}
var _summary_lbl: RichTextLabel
var _top5_atk_lbl: RichTextLabel
# (4) When the local player is on the top (canonical "enemy") side of a PvP replay,
# flip the arena vertically so THEIR units always appear at the bottom.
var _arena_flip_y := false
# 观战敌方战场中（BattleScreen 切镜头置位）。渲染层据此反转敌我配色：
# 敌方棋子显示红色阵营，他们打的怪显示绿色阵营。
var _watching_rival := false
var _arena: Control
var _title_lbl: Label
var _battle_state_lbl: Label
var _result_overlay_lbl: Label
var _unit_nodes: Dictionary = {}
var _board_readability_layer: BoardReadabilityLayer
var _selected_battle_unit_id := ""
var _board_readability_static_signature := ""
var _finished := false
var _skip_fast_forward := false
var _sim_accumulator := 0.0
var _return_emitted := false
var _model_facing_last_msec := 0
var _battle_3d_viewport: SubViewport
var _battle_3d_camera: Camera3D
var _battle_3d_world: Node3D
var _battle_3d_root: Node3D
var _battle_3d_vfx_root: Node3D
var _battle_arena_load_started := false
var _battle_arena_ready := false
var _battle_3d_models: Dictionary = {}
var _unit_actor_registry = UnitActorRegistryScript.new()
# 模型/动画缓存已移到 BattleAssetService：
#   * 跨场景存活（Main._show_battle() 每回合重建 BattleScreen，实例变量会跟着没）
#   * 与备战棋盘共用一份（以前两边各一套，同一个模型加载两遍）
#   * 按 owner/lease 释放，未来回合的预取不会被回合末清理误删
# 9.17 第二批：BGM 改走常驻的 MusicService，这里不再持有播放器。
#
# boss 登场音与 pve 战斗 BGM 的先后（9.17 反馈第 4 条）用这两个标志协调：
# 见 _start_battle_music / BattleScreen._prepare_battle_models 末尾。
var _boss_intro_pending := false
var _boss_intro_played := false
var _battle_audio_generation := 0

func _finish_simulation() -> void:
	pass

func _skip_animation() -> void:
	pass

# 本回合真实的战斗类型。3v3 组队时 _kind 只是占位的 "team"（BattleScreen 直接播
# 服务器 replay 时更是停在默认值 "pve"），必须优先取 replay/模拟状态里的 kind，
# 再退回赛程表——与 BattleArena._uses_pvp_battlefield() 同理。
# 结算面板、遭遇文案、法阵伤害、BGM 都得走这里：直接读 _kind 会按错误的类型算。
func _effective_kind() -> String:
	# 决赛先判回合号，理由同 BattleArena._battlefield_kind()：replay 里的 kind 已被
	# prepare_team_state 改写成 "pvp"，只信它的话 _final_summary() 永远是死代码。
	if GameState.round_index == GameState.FINAL_ROUND:
		return "final"
	var kind := str(_state.get("kind", _kind))
	if kind == "team" or kind == "":
		kind = RoundService.schedule_kind_for_round(GameState.round_index)
	return kind

func _battle_music_path() -> String:
	var kind := _effective_kind()
	return PVP_BATTLE_MUSIC_PATH if kind == "pvp" or kind == "final" else BATTLE_MUSIC_PATH

# boss 登场的那一下：**先让上一页那首 BGM 让位，再响登场音。**
#
# 9.17 第三轮反馈（第二批之后）：「boss 回合进入战斗场景时，备战 bgm 没停止，
# 应该响起 boss 登场音效时，备战 bgm 停止，音效结束后，pve 战斗 bgm 响起。」
#
# 第二批只做对了一半：`_start_battle_music()` 在 boss 回合会把战斗 BGM **推迟**到
# 登场音之后（`_boss_intro_pending`），却**没有任何人叫停「上一页还在放的那首」**。
# MusicService 是「一个播放器、一首当前曲目」，`play()` 只在路径不同时才换曲 ——
# 于是从进战斗场景到登场音结束这整段（含分帧建模型的读条）耳朵里一直是备战页那首，
# 登场音是**叠在它上面**出来的。
#
# 顺序是「先停、再响」而不是反过来：反过来的话登场音的头几毫秒会和备战 BGM 叠在
# 一起，而反馈的原话就是「响起 boss 登场音效时，备战 bgm 停止」。
#
# 登场音之后那首 pve 战斗 BGM **不在这里起**：它在 BattleScreen._prepare_battle_models()
# 末尾的 `_resolve_pending_battle_music()` 里等够素材时长再起（那一段本来就是对的）。
func _begin_boss_intro() -> void:
	_battle_audio_generation += 1
	MusicService.stop()
	# 标记「登场音已经响过」—— `_start_battle_music()` 靠它区分
	# 「还没登场，先把 BGM 挡住」和「登场完了，该起 BGM 了」。
	_boss_intro_played = true
	SfxService.play(SfxService.CUE_BOSS_APPEAR)


func _start_battle_music() -> void:
	# 9.17 反馈第 4 条：「在 boss 回合战斗场景，先播放 boss 登场音效完毕后，
	# 再播放 pve 战斗 bgm。」
	#
	# 原实现两件事互不知情：本函数在进场景那一刻就起 BGM（BattleScreen 的
	# 98 / 171 / 286 三处），而 boss 登场音在 _prepare_battle_models() 末尾
	# （模型全部建完之后）才响 —— 于是登场音是叠在已经响着的 BGM 上出来的。
	#
	# 现在 boss 回合先不起 BGM，只记一个 pending；由 BattleScreen 在**登场音
	# 播完之后**再调一次本函数（那时 _boss_intro_played 已经是 true，不会再被挡）。
	#
	# 用 `_boss_intro_played` 而不是「pending 清掉就不再 defer」：本函数在一场
	# 战斗里会被调多次（_start_replay 里那一次就在 _prepare_battle_models 之前），
	# 只靠 pending 会让后一次调用又把 BGM 挡回去，boss 回合整场没有战斗 BGM。
	if _effective_kind() == "boss" and not _boss_intro_played:
		_boss_intro_pending = true
		return
	# 「同一首不重启」由 MusicService 内部判等负责：本函数被重复调用是常态。
	MusicService.play(_battle_music_path())

func _stop_battle_music() -> void:
	_battle_audio_generation += 1
	SfxService.stop_cue(SfxService.CUE_BOSS_APPEAR)
	# 停的是「战斗这一首」。不切回菜单那首：离开战斗的下一页（备战/主菜单/
	# 结算后的路由）都会自己 play 它要的那一首，这里多切一次只会多一次从头播。
	# pending 也要清掉，否则退场后再也没有人来收口，BGM 会永远不响。
	_boss_intro_pending = false
	_boss_intro_played = false
	MusicService.stop()


# battle 场景的收口：把 `_start_battle_music()` 挡下来的那次补上。
#
# 只在 boss 回合真的挡过（`_boss_intro_pending`）时才等 —— 非 boss 回合这里是
# 一条空调用，BGM 早在 `_start_battle_music()` 那一刻就起了，不额外拖一帧。
#
# 等的是**素材的真实长度**（SfxService.cue_length）而不是写死的秒数：
# 换一条更长/更短的登场音，这条会自动跟上。
func _resolve_pending_battle_music() -> void:
	if not _boss_intro_pending:
		return
	_boss_intro_pending = false
	# 理论上 pending 只会在 boss 回合被置起，这里再判一次是兜底：
	# 万一 kind 在两次采样之间变了，宁可立刻起 BGM，也不要整场没声音。
	if _effective_kind() == "boss":
		var generation := _battle_audio_generation
		var intro_sec := SfxService.cue_length(SfxService.CUE_BOSS_APPEAR)
		if intro_sec > 0.0:
			await get_tree().create_timer(intro_sec).timeout
			if not is_inside_tree() or generation != _battle_audio_generation:
				return
	_start_battle_music()

# 3v3 PvP 用规范化棋局（result 的 "player" 方恒为 A 队），B 队本地显示
# 胜负/存活时必须换视角。回合结算的同款反转在 Main._on_team_battle_finished
# （Main.gd）——两处逻辑必须保持一致，改一处要同步另一处。
func _result_is_team_b_pvp_perspective(result: Dictionary) -> bool:
	return (
		str(result.get("kind", _state.get("kind", ""))) == "pvp"
		and NetworkService.team_active
		and GameConstants.team_of_slot(NetworkService.team_local_slot) == GameConstants.TEAM_BLUE
	)

func _local_player_wins(result: Dictionary) -> bool:
	# 视角反转走 TeamOutcome（C16）：服务端结算、这里的字幕、Main 的 fallback
	# 此前是三份独立实现，任何一处漂移都会让 B 队"画面显示胜利但按失败结算"。
	var kind := str(result.get("kind", _state.get("kind", "")))
	var viewer_team := TeamOutcome.TEAM_A
	if NetworkService.team_active and GameConstants.team_of_slot(NetworkService.team_local_slot) == GameConstants.TEAM_BLUE:
		viewer_team = TeamOutcome.TEAM_B
	return TeamOutcome.viewer_wins_battle(result, kind, viewer_team)

func _refresh_summary() -> void:
	var lines: Array[String] = []
	lines.append(_encounter_summary())
	lines.append(tr("battle_time") % [float(_state.get("elapsed", 0.0)), tr("battle_ended_suffix") if _finished else ""])
	lines.append(_live_count_summary())
	if not _result.is_empty():
		var self_alive := int(_result.get("player_alive", 0))
		var rival_alive := int(_result.get("enemy_alive", 0))
		var self_power := float(_result.get("player_power", 0.0))
		var rival_power := float(_result.get("enemy_power", 0.0))
		if _result_is_team_b_pvp_perspective(_result):
			var swap_alive := self_alive
			self_alive = rival_alive
			rival_alive = swap_alive
			var swap_power := self_power
			self_power = rival_power
			rival_power = swap_power
		lines.append(tr("battle_result_line") % [tr("battle_result_win") if _local_player_wins(_result) else tr("battle_result_lose"), str(_result.get("reason", ""))])
		lines.append(tr("battle_alive_power") % [self_alive, rival_alive, self_power, rival_power])
		lines.append(_kill_reward_summary(_result))
		lines.append(_settlement_preview(_result))
	lines.append(_event_log_summary())
	_summary_lbl.text = "\n".join(lines)

func _live_count_summary() -> String:
	var player_alive := BattleSim.living_units({"player": _state.get("player", []), "enemy": []}).size()
	var enemy_alive := BattleSim.living_units({"player": [], "enemy": _state.get("enemy", [])}).size()
	return tr("battle_live") % [player_alive, enemy_alive, GameState.player_formation_hp, GameState.enemy_formation_hp, GameState.gold]

func _settlement_preview(result: Dictionary) -> String:
	var lines: Array[String] = []
	# 面板必须和 EconomyService.settle_post_battle_gold（实际到账）用同一批输入：
	# 胜负走本地视角（3v3 PvP 的 B 队要反转），击杀金币取本地座位那份。
	var win := _local_player_wins(result)
	var kind := _effective_kind()
	var slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	var kill_gold := EconomyService.kill_gold_for_slot(result, maxi(0, slot))
	var gold_base := 0
	match kind:
		"pve":
			# 击杀金输赢都给，只有回合奖励是胜利专属。
			gold_base += kill_gold
			lines.append(tr("settle_pve_kill") % kill_gold)
			if win:
				var pve_bonus := EconomyService.pve_win_bonus(GameState.round_index)
				gold_base += pve_bonus
				lines.append(tr("settle_pve_win") % pve_bonus)
		"boss":
			if win:
				gold_base += EconomyService.boss_win_reward(GameState.round_index)
				lines.append(tr("settle_boss_win") % EconomyService.boss_win_reward(GameState.round_index))
			else:
				var loss_reward := EconomyService.boss_loss_reward(GameState.round_index, int(result.get("enemy_hp_current", 0)), maxi(1, int(result.get("enemy_hp_max", 1))))
				gold_base += loss_reward
				lines.append(tr("settle_boss_loss") % loss_reward)
		"pvp", "final":
			var result_bonus := EconomyService.pvp_result_bonus(win)
			gold_base += kill_gold + result_bonus
			lines.append(tr("settle_kill") % kill_gold)
			lines.append(tr("settle_result_bonus") % [tr("battle_result_win") if win else tr("battle_result_lose"), result_bonus])
	var merchant_gold := _merchant_gold_preview()
	var bonus_gold := int(result.get("bonus_gold", 0))
	var consolation_gold := 0
	if not win:
		consolation_gold = EconomyService.consolation_reward(GameState.loss_streak + 1)
	var before_interest := GameState.gold + gold_base + consolation_gold + merchant_gold + bonus_gold
	var interest := EconomyService.base_interest(before_interest)
	if GameState.owned_treasures.has("money_compound"):
		interest += int(floor(float(before_interest) * 0.05))
	interest += EconomyService.pet_interest_bonus(before_interest, PlayerProfile.get_active())
	var camp_income := GameState.carrot_camp_income()
	if merchant_gold > 0:
		lines.append(tr("settle_merchant") % merchant_gold)
	if bonus_gold > 0:
		lines.append(tr("settle_bonus") % bonus_gold)
	if consolation_gold > 0:
		lines.append(tr("settle_consolation") % [GameState.loss_streak + 1, consolation_gold])
	if GameState.owned_treasures.has("def_formation_heal"):
		var formation_heal := 2 if TreasureService.has_linkage("link_hu_pai_master") else 1
		lines.append(tr("settle_formation_heal") % formation_heal)
	if GameState.owned_treasures.has("money_lucky_envelope"):
		lines.append(tr("settle_lucky_envelope"))
	if TreasureService.has_linkage("link_money_magic"):
		lines.append(tr("settle_money_magic"))
	lines.append(tr("settle_interest") % interest)
	if camp_income > 0:
		lines.append(("Carrot Camp income +%dG" if LocaleManager.get_locale().begins_with("en") else "萝卜营地收入 +%d金") % camp_income)
	var formation_damage := _formation_damage_preview(result, win)
	lines.append(tr("settle_formation_change") % (tr("settle_enemy_formation") % formation_damage if win else tr("settle_self_formation") % formation_damage))
	return tr("settle_prefix") + " | ".join(lines)

func _formation_damage_preview(result: Dictionary, player_wins: bool) -> int:
	var damage := int(result.get("player_alive", 0)) if player_wins else int(result.get("enemy_alive", 0))
	if _effective_kind() == "boss" and not player_wins:
		damage += 4
	return maxi(0, damage)

func _merchant_gold_preview() -> int:
	return EconomyService.merchant_gold_from_board(GameState.board_slots)

func _event_log_summary() -> String:
	var log_items: Array = _result.get("log", _state.get("log", []))
	if log_items.is_empty():
		return tr("event_log_none")
	var parts: Array[String] = []
	var start := maxi(0, log_items.size() - 6)
	for i in range(start, log_items.size()):
		parts.append(str(log_items[i]))
	return tr("event_log_prefix") + " | ".join(parts)

func _encounter_summary() -> String:
	match _effective_kind():
		"boss": return _boss_summary()
		"pvp": return tr("encounter_pvp")
		"final": return _final_summary()
		_: return _pve_summary()

func _final_summary() -> String:
	return tr("encounter_final")

func _kill_reward_summary(result: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append(tr("kill_gold_line") % [int(result.get("player_kill_gold", 0)), int(result.get("enemy_kill_gold", 0)), int(result.get("bonus_gold", 0))])
	var player_kills: Array = result.get("player_kills", [])
	if not player_kills.is_empty():
		lines.append(tr("kill_player") % _format_kill_records(player_kills))
	var enemy_kills: Array = result.get("enemy_kills", [])
	if not enemy_kills.is_empty():
		lines.append(tr("kill_enemy") % _format_kill_records(enemy_kills))
	return "\n".join(lines)

func _format_kill_records(records: Array) -> String:
	var parts: Array[String] = []
	var start := maxi(0, records.size() - 4)
	for i in range(start, records.size()):
		var r: Dictionary = records[i]
		parts.append("%s>%s +%d" % [str(r.get("killer", "?")), str(r.get("victim", "?")), int(r.get("reward", 0))])
	return " | ".join(parts)

func _pve_summary() -> String:
	var count_by_round: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
	var count := int(count_by_round.get(str(GameState.round_index), 3))
	var growth := PveService.growth_for_completed(GameState.pve_completed)
	return tr("encounter_pve") % [count, float(growth.hp), float(growth.atk), float(growth.def)]

func _boss_summary() -> String:
	var growth := BossService.growth_for_completed(GameState.boss_completed)
	return tr("encounter_boss") % [BossService.GLOBAL_STAT_MULTIPLIER, float(growth.hp), float(growth.atk), float(growth.def), EconomyService.boss_win_reward(GameState.round_index)]
