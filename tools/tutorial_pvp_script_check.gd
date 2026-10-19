extends Node

# ============================================================================
# 2026-10-20 门禁：教程 PVP（第 6 / 11 / 13 回合）的脚本化胜负与法阵点数同步。
#
# 【反馈原文】（桌面《10.19bug提交及修复.docx》第 2 点）
#   「第6、第11、第13回合的战斗，我方棋子战败，但是仍然显示胜利且不触发法阵
#     扣除点数的问题；我方真实胜利，但对方法阵点数归0，出来后仍为10的问题。」
#
# 【修法三条，本门禁逐条钉住】
#   ① 按玩家棋盘强度调整双方 AI 的**星级配比**（TutorialMode.ai_roster_plan）：
#      AI 一兵不删（第 6/11/13 回合都是 7 人满编，随回合自然变强），
#      玩家弱 ⇒ 对手收着打、队友补强；玩家强 ⇒ 队友少补、对手加码。
#      计划为空时行为必须原样 —— 普通对局与其它门禁不受影响。
#   ② 第 11 回合不再被 coerce_victory 改写成胜利（脚本败要照实播）。
#   ③ 战斗里的 team_damage_self / team_damage_rival 落进 GameState.team_hp /
#      enemy_team_hp（6 / 11 保底留 1 点，13 回合敌方清零），并把
#      player_formation_hp / enemy_formation_hp 镜像成同一份（结算正文读它们）。
#
# 【写法铁律】计划 / 落账函数一律 has_method + Callable，不编译期绑定 ——
#   未修复构建整份脚本仍要能解析、跑起来判红，而不是场景无脚本假挂。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       res://tools/tutorial_pvp_script_check.tscn
#   退出码 0 = PASS，1 = FAIL。
# ============================================================================

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const BotPlayer := preload("res://scripts/economy/BotPlayer.gd")

const CHECK_NAME := "tutorial_pvp_script"
const ROUND_WIN_A := 6
const ROUND_LOSS := 11
const ROUND_FINAL := 13
const MAX_NOTCHES := 4

var _h: CheckHarness
var _tut: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_tut = TutorialMode
	await _run()
	TutorialMode.finish()
	GameState.reset_run()
	_h.expect(_h.checked_count() >= 24, "too_few_assertions",
		"整个门禁只量到 %d 条断言，等于没验" % _h.checked_count())
	_h.finish(get_tree())


func _run() -> void:
	# ---- 能力自检（缺函数也要先记账，再退出）----
	var has_plan := _tut.has_method("set_ai_roster_plan") \
		and _tut.has_method("clear_ai_roster_plan") \
		and _tut.has_method("_roster_plan_active")
	_h.expect(has_plan, "roster_plan_missing",
		"TutorialMode 没有 set/clear/_roster_plan_active —— 第 2 条修复（动态调阵容）不存在")
	var has_expect := _tut.has_method("script_round_expects_win") \
		and _tut.has_method("scripted_pvp_round")
	_h.expect(has_expect, "script_round_api_missing",
		"TutorialMode 缺 script_round_expects_win / scripted_pvp_round —— 脚本胜负判据不存在")
	var has_apply := _tut.has_method("_apply_scripted_team_damage")
	_h.expect(has_apply, "team_damage_apply_missing",
		"TutorialMode._apply_scripted_team_damage 不存在 —— 法阵点数不会落账")
	if not has_plan or not has_expect or not has_apply:
		return

	# ---- ① 空计划 = 原样（普通对局 / 其它门禁不受污染）----
	_setup_round(ROUND_WIN_A)
	_tut.call("clear_ai_roster_plan")
	_h.expect(not _roster_active(), "empty_plan_still_active",
		"没设计划时 _roster_plan_active() 仍为真 —— 普通对局会被本批改动污染")
	_h.expect(bool(_tut.call("scripted_pvp_round")), "round6_not_scripted_pvp",
		"第 %d 回合没被识别为教程脚本 PVP" % ROUND_WIN_A)

	# ---- ② 第 6 回合：双方都保留整副阵容，真实推演判胜 ----
	_setup_round(ROUND_WIN_A)
	_place("human_militia", 1, 0)
	_place("human_archer", 1, 1)
	_place("human_merchant", 1, 2)
	_h.expect(bool(_tut.call("script_round_expects_win")), "round6_expect_not_win",
		"第 %d 回合脚本应为「玩家胜」" % ROUND_WIN_A)
	_tut.call("set_ai_roster_plan", 0)
	var state_a: Dictionary = BattleSim.prepare_team_state(0)
	_h.expect(str(state_a.get("kind", "")) == "pvp", "round6_kind_not_pvp",
		"第 %d 回合的战斗类型是 %s（应为 pvp）" % [ROUND_WIN_A, str(state_a.get("kind", ""))])
	var enemy_a := _pieces(state_a.get("enemy", []))
	var ally_a := _pieces(state_a.get("player", []))
	_expect_three_full_lanes(enemy_a, ROUND_WIN_A, "对手")
	_expect_three_full_lanes(ally_a, ROUND_WIN_A, "队友")
	var won_a := _settle_script(ROUND_WIN_A, true)
	_h.expect(won_a, "round6_never_won",
		"第 %d 回合试完 %d 档阵容后真实推演仍判玩家负 —— 脚本（玩家胜）无法达成"
			% [ROUND_WIN_A, MAX_NOTCHES])

	# ---- ③ 第 11 回合：对手加码 / 队友收着打，真实推演判负 ----
	_setup_round(ROUND_LOSS)
	_place("human_militia", 1, 0)
	_place("human_archer", 2, 1)
	_place("human_merchant", 1, 2)
	_place("human_cleric", 1, 3)
	_h.expect(not bool(_tut.call("script_round_expects_win")), "round11_expect_not_lose",
		"第 %d 回合脚本应为「玩家败」" % ROUND_LOSS)
	_tut.call("set_ai_roster_plan", 0)
	var state_b: Dictionary = BattleSim.prepare_team_state(0)
	var enemy_b := _pieces(state_b.get("enemy", []))
	var ally_b := _pieces(state_b.get("player", []))
	_expect_three_full_lanes(enemy_b, ROUND_LOSS, "对手")
	_expect_three_full_lanes(ally_b, ROUND_LOSS, "队友")
	# 一兵不删：调整后每条路的棋子数不得少于 BotPlayer 的原始阵容。
	_h.expect(enemy_b.size() >= _baseline_count(3, ROUND_LOSS) * 3, "round11_enemy_shrunk",
		"第 %d 回合对手只剩 %d 枚（基线每路 %d 枚 × 3 路）—— AI 又被削成残阵了"
			% [ROUND_LOSS, enemy_b.size(), _baseline_count(3, ROUND_LOSS)])
	var lost_b := _settle_script(ROUND_LOSS, false)
	_h.expect(lost_b, "round11_never_lost",
		"第 %d 回合试完 %d 档阵容后真实推演仍判玩家胜 —— 脚本（玩家败）无法达成"
			% [ROUND_LOSS, MAX_NOTCHES])

	# ---- ③.2 玩家棋盘很强（4★ 人王 + 高星满编）时，第 11 回合仍然必须败 ----
	# 10-20 二修：用户实测「用人王四星战胜了对手」。这一条按真实强棋盘复现。
	_setup_round(ROUND_LOSS)
	_place("human_king", 4, 0)
	_place("human_militia", 3, 1)
	_place("human_archer", 3, 2)
	_place("human_merchant", 3, 3)
	_place("human_swordsman", 2, 4)
	_place("human_mage", 2, 5)
	_place("human_cleric", 2, 6)
	_tut.call("set_ai_roster_plan", 0)
	var st_strong: Dictionary = BattleSim.prepare_team_state(0)
	_expect_three_full_lanes(_pieces(st_strong.get("enemy", [])), ROUND_LOSS, "强棋盘对手")
	_h.expect(_settle_script(ROUND_LOSS, false), "round11_strong_board_won",
		"第 %d 回合玩家 4★ 人王 + 高星满编时仍判玩家胜 —— 脚本（玩家败）没兜住"
			% ROUND_LOSS)

	# ---- ③.5 AI 阵容随回合恒定上升（用户 10.20 口径）----
	var p6 := _baseline_power(3, ROUND_WIN_A)
	var p11 := _baseline_power(3, ROUND_LOSS)
	var p13 := _baseline_power(3, ROUND_FINAL)
	_h.expect(p11 >= p6 and p13 >= p11, "ai_roster_not_rising",
		"假想敌阵容强度不是随回合上升的：第 6 回合 %.0f、第 11 回合 %.0f、第 13 回合 %.0f"
			% [p6, p11, p13])

	# ---- ④ 第 11 回合的结果不能被 coerce_victory 改写 ----
	_setup_round(ROUND_LOSS)
	var loss_result := {"kind": "pvp", "player_wins": false, "is_draw": false,
		"enemy_alive": 4, "player_alive": 0}
	_tut.call("coerce_victory", loss_result)
	_h.expect(not bool(loss_result.get("player_wins", true)),
		"round11_coerced_to_victory",
		"第 %d 回合的「失败」又被 coerce_victory 改成胜利 —— 玩家仍会看到假胜利" % ROUND_LOSS)
	_setup_round(ROUND_WIN_A)
	var win_result := {"kind": "pvp", "player_wins": false, "is_draw": false,
		"enemy_alive": 2, "player_alive": 1}
	_tut.call("coerce_victory", win_result)
	_h.expect(bool(win_result.get("player_wins", false)), "round6_not_coerced",
		"第 %d 回合的兜底强制胜被误关了（PVE / 极端棋盘还靠它）" % ROUND_WIN_A)

	# ---- ⑤ 法阵点数落账：6 / 11 保底留 1 ----
	_setup_round(ROUND_WIN_A)
	GameState.team_hp = 10
	GameState.enemy_team_hp = 10
	_tut.call("_apply_scripted_team_damage", {"kind": "pvp", "player_wins": true,
		"team_damage_self": 0, "team_damage_rival": 3})
	_h.expect(GameState.enemy_team_hp == 7, "round6_enemy_hp_not_applied",
		"第 %d 回合胜后敌方法阵是 %d（应为 10-3=7）—— 伤害没落账"
			% [ROUND_WIN_A, GameState.enemy_team_hp])
	_h.expect(GameState.enemy_formation_hp == GameState.enemy_team_hp,
		"round6_formation_not_mirrored",
		"敌方法阵 formation_hp(%d) 与 team_hp(%d) 不同步 —— 结算正文会写错数"
			% [GameState.enemy_formation_hp, GameState.enemy_team_hp])
	_setup_round(ROUND_LOSS)
	GameState.team_hp = 2
	_tut.call("_apply_scripted_team_damage", {"kind": "pvp", "player_wins": false,
		"team_damage_self": 5, "team_damage_rival": 0})
	_h.expect(GameState.team_hp == 1, "round11_hp_floor_broken",
		"第 %d 回合败后我方法阵是 %d（应保底 1，不能扣完）" % [ROUND_LOSS, GameState.team_hp])
	_h.expect(GameState.player_formation_hp == 1, "round11_formation_not_mirrored",
		"我方 formation_hp(%d) 没跟 team_hp 同步" % GameState.player_formation_hp)

	# ---- ⑥ PVE 不玩法阵：伤害不许落账 ----
	_setup_round(ROUND_WIN_A)
	GameState.team_hp = 10
	_tut.call("_apply_scripted_team_damage", {"kind": "pve", "player_wins": false,
		"team_damage_self": 3, "team_damage_rival": 0})
	_h.expect(GameState.team_hp == 10, "pve_touched_team_hp",
		"PVE 回合扣了我方法阵（%d）—— 教学里 PVE 不玩法阵" % GameState.team_hp)

	# ---- ⑦ 第 13 回合：敌方扣完所有剩余点数 ----
	_setup_round(ROUND_FINAL)
	GameState.team_hp = 10
	GameState.enemy_team_hp = 3
	_h.expect(bool(_tut.call("script_round_expects_win")), "round13_expect_not_win",
		"第 %d 回合脚本应为「玩家胜」" % ROUND_FINAL)
	_tut.call("_apply_scripted_team_damage", {"kind": "pvp", "player_wins": true,
		"team_damage_self": 0, "team_damage_rival": 5})
	_h.expect(GameState.enemy_team_hp == 0, "round13_enemy_not_zeroed",
		"第 %d 回合胜后敌方法阵是 %d（应清零）" % [ROUND_FINAL, GameState.enemy_team_hp])
	_place("human_militia", 1, 0)
	_place("human_archer", 1, 1)
	_place("human_merchant", 1, 2)
	var won_final := _settle_script(ROUND_FINAL, true)
	_h.expect(won_final, "round13_never_won",
		"第 %d 回合试完 %d 档阵容后真实推演仍判玩家负 —— 脚本（玩家胜）无法达成"
			% [ROUND_FINAL, MAX_NOTCHES])

	# ---- ⑧ 计划用完必须能清空 ----
	_tut.call("clear_ai_roster_plan")
	_h.expect(not _roster_active(), "plan_not_cleared",
		"clear_ai_roster_plan() 之后计划仍生效 —— 下一场（PVE / 新回合）会捡到旧计划")


# ---------------------------------------------------------------- 工具

# 与 PrepScreen._prepare_tutorial_scripted_replay 同一套语义：
# 逐档调阵容、真推一场、比对真实 player_wins，最多 MAX_NOTCHES 档。
# ⚠ 不调 _setup_round()：那会清空棋盘，本函数要沿用调用方摆好的棋子。
func _settle_script(round_n: int, expect_win: bool) -> bool:
	GameState.round_index = round_n
	GameState.team_hp = 10
	GameState.enemy_team_hp = 10
	for notch in MAX_NOTCHES:
		_tut.call("set_ai_roster_plan", notch)
		var state: Dictionary = BattleSim.prepare_team_state(0)
		var steps := 0
		while not bool(state.get("finished", false)) and steps < 4000:
			BattleSim.step_state(state)
			steps += 1
		var result: Dictionary = BattleSim.result_from_state(state)
		if bool(result.get("player_wins", not expect_win)) == expect_win:
			return true
	return false


func _setup_round(round_n: int) -> void:
	GameState.reset_run()
	GameState.tutorial_mode = true
	GameState.team_mode = true
	GameState.team_slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	# 青苗赛程只在 FINAL_ROUND == 13 时生效（RoundService.active_schedule()）；
	# 不设这一条，第 11 回合会被当成 PVE，量到的是「三路小怪」而不是对手棋盘。
	GameState.FINAL_ROUND = 13
	GameState.round_index = round_n
	GameState.team_hp = 10
	GameState.enemy_team_hp = 10
	GameState.player_formation_hp = 10
	GameState.enemy_formation_hp = 10
	NetworkService.shared_seed = 20261019


func _roster_active() -> bool:
	if not _tut.has_method("_roster_plan_active"):
		return false
	return bool(_tut.call("_roster_plan_active"))


# 棋盘上的棋子（排除佣兵与决赛法阵援军：它们没有 board_cell）。
func _pieces(arr: Array) -> Array:
	var out: Array = []
	for raw in arr:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var f := raw as Dictionary
		if bool(f.get("is_mercenary", false)):
			continue
		if not f.has("board_cell"):
			continue
		out.append(f)
	return out


func _lane_counts(pieces: Array) -> Dictionary:
	var lanes := {}
	for raw in pieces:
		var lane := int((raw as Dictionary).get("lane", -1))
		lanes[lane] = int(lanes.get(lane, 0)) + 1
	return lanes


# 10.20 用户口径：AI 不许为了凑胜负被削成 1 个棋子，三路都要是一支完整队伍。
func _expect_three_full_lanes(pieces: Array, round_n: int, who: String) -> void:
	var lanes := _lane_counts(pieces)
	_h.expect(lanes.size() == 3, "lane_missing_%s" % who,
		"第 %d 回合%s只出现了 %d 路（应为 3 路）—— 有一路被清空了" % [round_n, who, lanes.size()])
	for lane in lanes:
		_h.expect(int(lanes[lane]) >= 2, "lane_thin_%s_%d" % [who, int(lane)],
			"第 %d 回合%s第 %d 路只有 %d 枚棋子 —— AI 不能只剩一个，玩家会觉得对面不智能"
				% [round_n, who, int(lane), int(lanes[lane])])


# 假想敌的**原始**阵容（未经本批调整）棋子数：用来钉「只调星、不删人」。
func _baseline_count(slot: int, round_n: int) -> int:
	var board: Array = _baseline_board(slot, round_n)
	var count := 0
	for cell in board:
		if typeof(cell) == TYPE_DICTIONARY:
			count += 1
	return count


func _baseline_power(slot: int, round_n: int) -> float:
	var total := 0.0
	for cell in _baseline_board(slot, round_n):
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var data := cell as Dictionary
		var star := maxi(1, int(data.get("star", 1)))
		var def: Dictionary = data.get("def", {})
		total += float(maxi(1, int(def.get("cost", 1)))) * float(star * star)
	return total


func _baseline_board(slot: int, round_n: int) -> Array:
	GameState.tutorial_mode = true
	NetworkService.shared_seed = 20261019
	var bot: Dictionary = BotPlayer.state_for(NetworkService.shared_seed, slot, round_n)
	return bot.get("board", []) as Array


func _place(id: String, star: int, slot: int) -> void:
	var def := _unit_def(id)
	if def.is_empty():
		return
	GameState.board_slots[slot] = {"id": id, "uid": GameState.mint_piece_uid(),
		"star": star, "def": def}


func _unit_def(id: String) -> Dictionary:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for raw in units:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		if str((raw as Dictionary).get("id", "")) == id:
			return (raw as Dictionary).duplicate(true)
	return {}
