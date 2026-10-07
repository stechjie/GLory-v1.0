extends Node

# 10.07 bug 文档第 8 条：任何回合结束都要有结算面板（PVE 回合也要算我方上阵佣兵的
# 数据），并且对局历史里也同步。
#
# 这条修复有四层都要真的成立，缺一层玩家就看不到：
#   1. 数据层（FinalSettlementData）：PVE 的 model 也要带 `show_details = true` ——
#      以前这里是 `kind in ["pvp","final"]`，正是它把 PVE 的「查看详情」吞掉的。
#   2. 佣兵（核心要求）：PVE 面板里**我方**那一列必须真的有佣兵数据，不是空列表。
#      ★ 这条最容易假绿：代码「没报错」不代表佣兵在里面。所以判据不查源码字符串，
#        直接调 build_local()，断言 seats[我方].mercenaries 非空且 id 对得上。
#      ★ 而且 build_local 读的是 GameState.mercenary_slots（离线槽 0），所以调用
#        时机必须在 Main 的 clear_mercenaries() 之前 —— 时序那一层由主路径断言兜。
#   3. 历史（MatchHistoryPanel）：settlement.kind == "pve" 的记录也要有详细战况。
#   4. 接线（Main）：**只在整局结束（输或赢）时**建 settlement、弹面板，非终局回合直接进
#      摆放界面（2026-10-07 用户定）；那次构建必须在 clear_mercenaries() **之前**
#      （否则佣兵列全空）。原话「任何回合结束游戏都会有结算面板」指的是不管在哪个回合
#      结束游戏都要有面板 —— 当天一度改成每回合弹，用户否了。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/round_settlement_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Settlement := preload("res://scripts/multiplayer/FinalSettlementData.gd")
const HistoryPanel := preload("res://scenes/menu/MatchHistoryPanel.gd")

const CHECK_NAME := "round_settlement"
const MAIN_SRC := "res://scenes/main/Main.gd"

var _h: CheckHarness
var _saved_team_active := false
var _saved_merc: Array = []
var _saved_board: Array = []
var _saved_states: Array = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_pristine()
	_case_pve_model_has_details()
	_case_pve_keeps_our_mercenaries()
	_case_history_pve_has_details()
	_case_main_settles_only_at_run_end()
	_restore()
	_h.finish(get_tree())


# 把状态摆成「离线 PVE、我方槽 0 上有棋盘 + 佣兵」。
func _pristine() -> void:
	_saved_team_active = NetworkService.team_active
	_saved_merc = GameState.mercenary_slots.duplicate(true)
	_saved_board = GameState.board_slots.duplicate(true)
	_saved_states = GameState.team_slot_states.duplicate(true)
	NetworkService.team_active = false
	GameState.team_slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]


func _restore() -> void:
	NetworkService.team_active = _saved_team_active
	GameState.mercenary_slots = _saved_merc
	GameState.board_slots = _saved_board
	GameState.team_slot_states = _saved_states


# --- 1. 数据层：PVE model 也带 show_details --------------------------------

func _case_pve_model_has_details() -> void:
	var room := _room_fixture()
	var replay := _replay_fixture()
	var model: Dictionary = Settlement.build(room, [replay, replay.duplicate(true)], TeamOutcome.TEAM_A, false)
	_h.expect(model.get("kind", "") == "pve", "fixture_is_pve", "夹具应该是 PVE（kind=pve）")
	_h.expect(bool(model.get("show_details", false)), "pve_model_show_details",
		"PVE 回合的结算 model 仍然没有 show_details —— 它的「查看详情」会被藏掉")
	# can_show_details：显式 kind 一律放行；没 kind 的仍看 show_details。
	_h.expect(Settlement.can_show_details(model, {"kind": "pve"}), "can_details_pve",
		"can_show_details 还把 PVE 挡在外面")
	_h.expect(Settlement.can_show_details({"show_details": true}, {}), "can_details_flag",
		"没有 kind 时应该回落到 show_details 标志")
	_h.expect(not Settlement.can_show_details({}, {}), "can_details_empty",
		"空 model 且无 kind 时不该放行 —— 判据要真的区分")


# --- 2. 佣兵：PVE 面板里我方那一列必须有真佣兵 --------------------------------

func _case_pve_keeps_our_mercenaries() -> void:
	# ★ 棋盘格里必须有 `def`（SynergyService.count_races_from_board 读 cell.def.get("race")）。
	#   少了它 build_local → _team_owner_ctx_for_slot 会直接抛错，测出来的是夹具坏而不是实现坏。
	GameState.board_slots = [{"id": "human_king", "star": 4, "def": {"name": "人王", "race": "human"}}, null, null]
	GameState.mercenary_slots = [{"id": "merc_pisces_bubble", "star": 1, "def": {"name": "双鱼泡泡", "race": "god"}}, null]
	var model: Dictionary = Settlement.build_local([_replay_fixture(), {}])
	var seat := _seat(model, 0)
	_h.expect(not seat.is_empty(), "local_seat0_exists", "本地路径没有建出槽 0 的座位")
	var mercs: Array = seat.get("mercenaries", []) if typeof(seat.get("mercenaries")) == TYPE_ARRAY else []
	var ids := []
	for entry in mercs:
		if typeof(entry) == TYPE_DICTIONARY:
			ids.append(str(entry.get("id", "")))
	_h.expect(ids.has("merc_pisces_bubble"), "pve_mercenary_present",
		"PVE 结算里我方上阵佣兵丢了（要求原文：PVE 回合也要计算我方上阵佣兵的数据）")
	var board: Array = seat.get("board", []) if typeof(seat.get("board")) == TYPE_ARRAY else []
	var board_ids := []
	for entry in board:
		if typeof(entry) == TYPE_DICTIONARY:
			board_ids.append(str(entry.get("id", "")))
	_h.expect(board_ids.has("human_king"), "pve_board_present",
		"PVE 结算里我方棋盘上的棋子丢了")


# --- 3. 历史：PVE 记录也要有详细战况 -----------------------------------------

func _case_history_pve_has_details() -> void:
	var item := {
		"rounds": 1, "mode": "custom", "my_slot": 0,
		"seats": [], "settlement": {"kind": "pve", "seats": [], "stats": [], "allies": ["", ""]},
	}
	_h.expect(HistoryPanel.has_settlement_details(item), "history_pve_details",
		"对局历史里 PVE 记录仍然被当成「无结算详情」")
	# 反向：没有 settlement（023 之前的局）仍然不给按钮 —— 判据不能一律返回 true。
	var legacy := {"rounds": 1, "mode": "custom", "my_slot": 0, "seats": [], "settlement": null}
	_h.expect(not HistoryPanel.has_settlement_details(legacy), "history_legacy_blocked",
		"旧版本记录（settlement 为 null）不该有详细战况")


# --- 4. 接线：只在整局结束时结算，且那次构建在 clear_mercenaries() 之前 ------------

func _case_main_settles_only_at_run_end() -> void:
	var src := FileAccess.get_file_as_string(MAIN_SRC)
	# _fn_body 会把 CRLF 统一成 \n（Main.gd 是 CRLF），下面按 \n 找。
	var body := _fn_body(src, "func _on_team_battle_finished(")
	_h.expect(not body.is_empty(), "main_fn_found", "没找到 Main._on_team_battle_finished")
	# ★ 注释里也会出现 `GameState.clear_mercenaries()`（说明为什么必须提前建），
	#   所以只认**语句**：前面顶一个制表符 + 整行只有这一个调用。
	var build_at := body.find("build_local(")
	var clear_at := body.find("\n\tGameState.clear_mercenaries()")
	_h.expect(build_at >= 0, "main_builds_local",
		"Main._on_team_battle_finished 里不再调 build_local（整局结束的面板就没数据了）")
	_h.expect(clear_at >= 0, "main_finds_clear", "找不到 GameState.clear_mercenaries() 语句")
	_h.expect(clear_at >= 0 and build_at >= 0 and build_at < clear_at, "main_build_before_clear",
		"build_local 在 clear_mercenaries() 之后才跑 —— 佣兵列会是空的")
	var guard_at := body.find("if GameState.team_hp <= 0 or GameState.enemy_team_hp <= 0 or completed_round >= GameState.FINAL_ROUND:")
	_h.expect(guard_at >= 0 and guard_at < build_at, "main_builds_only_at_run_end",
		"结算数据不该每回合都建 —— 只有整局结束（任一方水晶归零或打完最后一回合）才要")
	# 非终局：game over 那个分支 return 之后直接进摆放界面，中间不许再出任何结算面板。
	# 截「game over 那句之后 → _show_prep() 之前」这一段，里面出现 settlement 就是又弹了面板
	#（不分大小写：当天那个函数叫 _show_round_settlement）。
	var over_stmt := "_show_game_over(local_settlement)\n\t\treturn"
	var over_at := body.find(over_stmt)
	var prep_at := body.find("_show_prep()", over_at)
	_h.expect(over_at >= 0 and prep_at > over_at, "main_mid_run_goes_to_prep",
		"非终局回合打完应直接进摆放界面")
	if over_at >= 0 and prep_at > over_at:
		var mid_run := body.substr(over_at + over_stmt.length(), prep_at - over_at - over_stmt.length())
		_h.expect(not mid_run.to_lower().contains("settlement"), "main_no_round_panel",
			"非终局回合又弹了结算面板 —— 用户 10-07 定：只有输赢定了才进结算")
	# 服务端权威那条路同一个规矩。
	var server_body := _fn_body(src, "func _finish_server_authoritative_team_battle(")
	var s_stmt := "_show_game_over()\n\t\treturn"
	var s_over := server_body.find(s_stmt)
	var s_prep := server_body.find("_show_prep()", s_over)
	_h.expect(s_over >= 0 and s_prep > s_over
			and not server_body.substr(s_over + s_stmt.length(), s_prep - s_over - s_stmt.length()).to_lower().contains("settlement"),
		"server_mid_run_goes_to_prep", "服务端权威路径的非终局回合应直接进摆放界面、不弹结算面板")


# --- 夹具 ---------------------------------------------------------------------

func _room_fixture() -> Dictionary:
	return {
		"slot_states": ["player", "dummy", "dummy", "dummy", "dummy", "dummy"],
		"boards": {0: {"board": [{"id": "human_king", "star": 4}], "mercenaries": [{"id": "merc_pisces_bubble", "star": 1}]}},
		"owned_treasures": {0: []},
		"seat_profiles": {}, "prep": {}, "mode": "local",
	}


func _replay_fixture() -> Dictionary:
	return {
		"kind": "pve",
		"roster": {"a": {"team": "player", "is_formation_ally": true, "name": "红队守护者"}},
		"result": {"unit_stats": {
			"a": {"id": "human_king", "name": "人王", "star": 4, "slot": 0, "owner_slot": 0, "damage_dealt": 321},
		}},
	}


func _seat(model: Dictionary, slot: int) -> Dictionary:
	for entry in (model.get("seats", []) as Array):
		if typeof(entry) == TYPE_DICTIONARY and int((entry as Dictionary).get("slot", -1)) == slot:
			return entry
	return {}


# 取一个函数的函数体。★ 归一化成 LF 再返回：仓库里 .gd 是 CRLF，如果直接用
# `\n` 去 find 一个跨行片段（比如「_show_game_over(...)\n\t\treturn」）永远匹配不到，
# 而 find 返回 -1 只会让断言安静地判假 —— 那就是「锚点行尾不一致 = 静默 SKIP」。
func _fn_body(source: String, signature: String) -> String:
	var normalized := source.replace("\r\n", "\n").replace("\r", "\n")
	var at := normalized.find(signature)
	if at < 0:
		return ""
	var rest := normalized.substr(at + signature.length())
	var nxt := rest.find("\nfunc ")
	return rest if nxt < 0 else rest.substr(0, nxt)


