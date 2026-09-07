extends Node

# V12-08：以真实 BattleSimulator 跑 100 seeds × 7 个目标回合的 Bot 存活曲线。
# 这里只测量，不写目标胜率断言；产品尚未定义“第几回合应有多强”。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")

const CHECK_NAME := "ai_survival_curve"
const SAMPLE_COUNT := 100
const TARGET_ROUNDS := [1, 4, 5, 9, 10, 15, 21]
const SEED_BASE := 202609071000
const REPORT_PATH := "user://v12_ai_survival_curve.json"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.load_all()
	var report := {
		"schema": 1,
		"sample_count": SAMPLE_COUNT,
		"seed_base": SEED_BASE,
		"fixture": "six independently seeded Bot boards; no treasures, pets or mercenaries",
		"rounds": [],
	}
	for round_index in TARGET_ROUNDS:
		(report["rounds"] as Array).append(_measure_round(round_index))
	_write_report(report)
	_h.finish(get_tree())


func _measure_round(round_index: int) -> Dictionary:
	var wins := 0
	var draws := 0
	var timeouts := 0
	var player_alive_total := 0
	var enemy_alive_total := 0
	var player_hp_ratio_total := 0.0
	var elapsed_total := 0.0
	var kind := ""
	for sample_index in SAMPLE_COUNT:
		var seed_value: int = SEED_BASE + round_index * 1000 + sample_index
		var result := _simulate(round_index, seed_value)
		if sample_index == 0:
			var repeated := _simulate(round_index, seed_value)
			_h.expect(var_to_bytes(result) == var_to_bytes(repeated), "result_not_deterministic",
				"回合 %d seed %d 的 final result 不可重复" % [round_index, seed_value])
		kind = str(result.get("kind", ""))
		if bool(result.get("player_wins", false)):
			wins += 1
		if bool(result.get("is_draw", false)):
			draws += 1
		if str(result.get("reason", "")) == "hard_timeout_power":
			timeouts += 1
		var player_alive := int(result.get("player_alive", -1))
		var enemy_alive := int(result.get("enemy_alive", -1))
		_h.expect(player_alive >= 0 and enemy_alive >= 0, "survivor_count_missing",
			"回合 %d seed %d 缺存活数量" % [round_index, seed_value])
		player_alive_total += maxi(0, player_alive)
		enemy_alive_total += maxi(0, enemy_alive)
		var hp_max := maxi(1, int(result.get("player_hp_max", 1)))
		player_hp_ratio_total += clampf(float(result.get("player_hp_current", 0)) / hp_max, 0.0, 1.0)
		elapsed_total += float(result.get("elapsed", 0.0))
	var row := {
		"round": round_index,
		"kind": kind,
		"win_rate": snappedf(float(wins) / SAMPLE_COUNT, 0.001),
		"draw_rate": snappedf(float(draws) / SAMPLE_COUNT, 0.001),
		"hard_timeout_rate": snappedf(float(timeouts) / SAMPLE_COUNT, 0.001),
		"mean_player_survivors": snappedf(float(player_alive_total) / SAMPLE_COUNT, 0.001),
		"mean_enemy_survivors": snappedf(float(enemy_alive_total) / SAMPLE_COUNT, 0.001),
		"mean_player_hp_ratio": snappedf(player_hp_ratio_total / SAMPLE_COUNT, 0.001),
		"mean_elapsed_sec": snappedf(elapsed_total / SAMPLE_COUNT, 0.001),
	}
	print("[%s] r%02d kind=%s win=%.1f%% draw=%.1f%% timeout=%.1f%% alive=%.2f/%.2f hp=%.1f%% sec=%.2f" % [
		CHECK_NAME, round_index, kind, float(row["win_rate"]) * 100.0,
		float(row["draw_rate"]) * 100.0, float(row["hard_timeout_rate"]) * 100.0,
		float(row["mean_player_survivors"]), float(row["mean_enemy_survivors"]),
		float(row["mean_player_hp_ratio"]) * 100.0, float(row["mean_elapsed_sec"])])
	_h.expect(not kind.is_empty(), "round_kind_missing", "回合 %d 没有战斗类型" % round_index)
	return row


func _simulate(round_index: int, seed_value: int) -> Dictionary:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = round_index
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = seed_value
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = {}
	for slot in 6:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value * 10 + slot
		var board := BattleSimShared.build_dummy_board(rng)
		boards[slot] = {
			"version": NetProtocol.SNAPSHOT_VERSION,
			"round": round_index,
			"board": board,
			"mercenaries": [],
			"treasures": [],
			"syn": NetProtocol.rebuild_syn_from_board(board),
			"pet": "",
		}
	NetworkService.team_boards = boards
	var state := BattleSim.prepare_team_state(0)
	var steps := 0
	while not bool(state.get("finished", false)) and steps < 4000:
		BattleSim.step_state(state)
		steps += 1
	var result := BattleSim.result_from_state(state)
	result["steps"] = steps
	return result


func _write_report(report: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if not _h.expect(file != null, "report_open_failed", "无法写入 %s" % REPORT_PATH):
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	_h.expect(FileAccess.file_exists(REPORT_PATH), "report_missing", "存活曲线报告没有落盘")
	print("[%s] report=%s" % [CHECK_NAME, ProjectSettings.globalize_path(REPORT_PATH)])
