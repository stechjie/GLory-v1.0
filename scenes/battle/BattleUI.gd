extends Control


@warning_ignore("unused_signal")
signal battle_finished(result: Dictionary)

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const SIM_TICK_SEC := 0.1
const PLAYBACK_SPEED := 1.0
const MAX_STEPS_PER_FRAME := 3
const SKIP_STEPS_PER_FRAME := 80
const SKIP_FRAME_BUDGET_MSEC := 8
const SIM_W := 1000.0
const SIM_H := 520.0
const UNIT_VISUAL_SIZE := Vector2(82, 104)
const UNIT_VISUAL_OFFSET := Vector2(41, 66)
const PVP_RESULT_REQUEST_INTERVAL_SEC := 1.0
const RESULT_DISPLAY_SECONDS := 1.0
const MODEL_FACING_UPDATE_SEC := 0.18
const MODEL_FACING_LERP := 0.18
const MODEL_FACING_PLAYER_YAW_OFFSET := 0.0
const MODEL_FACING_ENEMY_YAW_OFFSET := 180.0
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
var _arena: Control
var _title_lbl: Label
var _battle_state_lbl: Label
var _result_overlay_lbl: Label
var _unit_nodes: Dictionary = {}
var _finished := false
var _waiting_authoritative_result := false
var _skip_fast_forward := false
var _sim_accumulator := 0.0
var _return_emitted := false
var _pvp_result_request_elapsed := 0.0
var _model_facing_elapsed := 0.0
var _model_facing_due := true
var _battle_3d_viewport: SubViewport
var _battle_3d_camera: Camera3D
var _battle_3d_world: Node3D
var _battle_3d_root: Node3D
var _battle_arena_load_started := false
var _battle_arena_ready := false
var _battle_3d_models: Dictionary = {}
var _model_scene_cache: Dictionary = {}
var _model_load_started: Dictionary = {}
var _model_animation_scene_cache: Dictionary = {}
var _battle_music_player: AudioStreamPlayer

func _uses_authoritative_online_result() -> bool:
	return not GameState.team_mode and NetworkService.is_online() and (_kind == "pvp" or _kind == "final")



func _finish_simulation() -> void:
	pass

func _skip_animation() -> void:
	pass

func _battle_music_path() -> String:
	var kind := str(_state.get("kind", _kind))
	# 3v3 组队：开局播 BGM 时服务器 replay 还没到，_state 为空、_kind 只是 "team"，
	# 与 BattleArena._uses_pvp_battlefield() 同理，用赛程表提前判断本回合类型。
	if kind == "team" or kind == "":
		kind = RoundService.schedule_kind_for_round(GameState.round_index)
	return PVP_BATTLE_MUSIC_PATH if kind == "pvp" or kind == "final" else BATTLE_MUSIC_PATH

func _start_battle_music() -> void:
	if _battle_music_player != null:
		return
	var music_path := _battle_music_path()
	var stream := load(music_path) as AudioStream
	if stream == null:
		push_warning("战斗音乐读取失败：%s" % music_path)
		return
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	_battle_music_player = AudioStreamPlayer.new()
	_battle_music_player.name = "BattleMusicPlayer"
	_battle_music_player.stream = stream
	_battle_music_player.bus = "Music" if AudioServer.get_bus_index("Music") >= 0 else "Master"
	add_child(_battle_music_player)
	_battle_music_player.play()

func _stop_battle_music() -> void:
	if _battle_music_player == null:
		return
	_battle_music_player.stop()

# 3v3 PvP 用规范化棋局（result 的 "player" 方恒为 A 队），B 队本地显示
# 胜负/存活时必须换视角。回合结算的同款反转在 Main._on_team_battle_finished
# （Main.gd）——两处逻辑必须保持一致，改一处要同步另一处。
func _result_is_team_b_pvp_perspective(result: Dictionary) -> bool:
	return (
		str(result.get("kind", _state.get("kind", ""))) == "pvp"
		and NetworkService.team_active
		and NetworkService.team_local_slot >= 3
	)

func _local_player_wins(result: Dictionary) -> bool:
	var wins := bool(result.get("player_wins", false))
	return not wins if _result_is_team_b_pvp_perspective(result) else wins

func _refresh_summary() -> void:
	var lines: Array[String] = []
	lines.append(_encounter_summary())
	lines.append(tr("battle_time") % [float(_state.get("elapsed", 0.0)), tr("battle_ended_suffix") if _finished else ""])
	if _waiting_authoritative_result:
		lines.append(tr("battle_wait_authoritative"))
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
	var win := bool(result.get("player_wins", false))
	var gold_base := 0
	match _kind:
		"pve":
			if win:
				var kill_gold := int(result.get("player_kill_gold", 0))
				gold_base += kill_gold
				gold_base += EconomyService.pve_kill_reward(GameState.pve_completed)
				lines.append(tr("settle_pve_kill") % kill_gold)
				lines.append(tr("settle_pve_win") % EconomyService.pve_kill_reward(GameState.pve_completed))
		"boss":
			if win:
				gold_base += EconomyService.boss_win_reward(GameState.round_index)
				lines.append(tr("settle_boss_win") % EconomyService.boss_win_reward(GameState.round_index))
			else:
				var loss_reward := EconomyService.boss_loss_reward(GameState.round_index, int(result.get("enemy_hp_current", 0)), maxi(1, int(result.get("enemy_hp_max", 1))))
				gold_base += loss_reward
				lines.append(tr("settle_boss_loss") % loss_reward)
		"pvp", "final":
			var kill_gold := int(result.get("player_kill_gold", 0))
			var result_bonus := EconomyService.pvp_result_bonus(win)
			gold_base += kill_gold
			gold_base += result_bonus
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
	var formation_damage := _formation_damage_preview(result, win)
	lines.append(tr("settle_formation_change") % (tr("settle_enemy_formation") % formation_damage if win else tr("settle_self_formation") % formation_damage))
	return tr("settle_prefix") + " | ".join(lines)

func _formation_damage_preview(result: Dictionary, player_wins: bool) -> int:
	var damage := int(result.get("player_alive", 0)) if player_wins else int(result.get("enemy_alive", 0))
	if _kind == "boss" and not player_wins:
		damage += 4
	return maxi(0, damage)

func _merchant_gold_preview() -> int:
	var total := 0
	for cell in GameState.board_slots:
		if cell != null and str(cell.get("def", {}).get("skill_id", "")) == "post_battle_gold_by_star":
			total += int(cell.get("star", 1))
	return total

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
	match _kind:
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
