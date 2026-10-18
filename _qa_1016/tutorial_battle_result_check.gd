extends Node
# ============================================================================
# 2026-10-16 第 1 条门禁：教程战斗必胜 + 教程收口不弹联机结算详情。
#
# 【反馈原文】（桌面《10.16bug提交及修复.docx》第 1 点）
#   「经玩家测试发现新手教程有存在bug：点开"重新体验教学"，根据新手步骤教学
#     进入战斗阶段发现和原来预设的新手教程战斗不同；新手教程结束有弹出结算
#     面板的情况。」
#
# 【要钉住什么】四层兜底，任何一层被改坏都要红：
#   ① 根因钉子（真模拟）：空棋盘开战 ⇒ prepare_tutorial_state 直接返回
#      forced_result.player_wins=false（no_player_units），**瞬间判负**；
#      而 3 个 1 星棋子打 3 只教学小怪（80HP/6ATK/0DEF）必赢。
#      这两条是「为什么会看到 Defeat」的全部依据，模拟行为若变必须红，
#      让人回来重读第 1/2 层还需不需要，而不是默默绿着。
#   ② 第 1 层（结果显示前改写）：TutorialMode.coerce_victory() 把失败/平局
#      结果改写成胜利，且**不动 GameState.enemy_formation_hp**（备战界面的
#      敌方法阵血量在教程中途要保持 10/10）。接线位置必须在
#      BattleResult._finish_simulation() 里「拿到结果之后、_emit_finished 之前」
#      —— 那正是本地模拟路的唯一收口点，字幕/胜负音/水晶演出/battle_finished
#      都读同一份结果。挂在 after_battle() 里是修不好的：那时字幕早播完了。
#   ③ 第 2 层（开战闸 + 自愈）：begin_battle() 在上阵数不足时先从待命区补
#      （跳过会触发合成的、跳过重复的唯一棋子），补完仍不够就返回 false
#      并弹「上阵棋子数目少于N」—— 不烧调用方的一次性发射锁。
#   ④ 第 3/4 层（结算收口 + 残留清洗）：can_show_details() 空 data 一律 false
#      （教程是本地模拟，从来不产生 final_settlement）；_enter_tutorial_from_startup()
#      无条件清掉 latest_match_state / team_replay / team_replay_rival，
#      且清在 TutorialMode.start() / restore_checkpoint() **之前**。
#
# 【为什么这些断言不依赖调用方做对】
#   ①②③都挂在「生产链自己会走到的那一个点」上：_finish_simulation 是
#   BattleScreen._process 的 finished 分支与 _skip_animation 两条路的汇点；
#   begin_battle() 是 Main._on_battle_requested 开战前的最后一个函数，
#   包括 PrepScreen 的战斗加载重试、team_round_start 这些**不走按钮处理函数**
#   的旁路。所以「旁路不过闸」这个根因在结构上被消掉，而不是靠记得加判断。
#
# 【本门禁量不到的东西】
#   `--headless` 不渲染，所以「字幕到底显示 Victory 还是 Defeat」拿不到画面真值
#   —— 那部分由真机/视频确认。本门禁钉的是**契约与数据**：结果字典被改成胜利、
#   闸门会拒战、残留被清空。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/tutorial_battle_result.tscn
#   退出码 0 = PASS，1 = FAIL。
#
# 【写法铁律】TutorialMode 的新增方法（coerce_victory / required_board_units /
#   _auto_deploy_from_bench / _ensure_board_ready_for_battle）一律走
#   has_method + Callable，**不编译期绑定** —— 否则未修复构建整个脚本解析失败、
#   场景无脚本、进程不退出（假挂而不是判红）。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const FinalSettlementData := preload("res://scripts/multiplayer/FinalSettlementData.gd")

const CHECK_NAME := "tutorial_battle_result"
const BATTLE_RESULT_SRC := "res://scenes/battle/BattleResult.gd"
const MAIN_SRC := "res://scenes/main/Main.gd"

var _h: CheckHarness
var _tut: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_tut = TutorialMode
	await _run()
	# 收尾：把 autoload 状态还回去，避免同进程里后续检查被污染。
	TutorialMode.finish()
	GameState.reset_run()
	_h.expect(_h.checked_count() >= 20, "too_few_assertions",
		"整个门禁只量到 %d 条断言，等于没验" % _h.checked_count())
	_h.finish(get_tree())


func _run() -> void:
	# ---- ① 根因钉子：空棋盘 = 强制判负，3 个棋子 = 必赢 ----
	GameState.reset_run()
	GameState.tutorial_mode = true
	var empty_state: Dictionary = BattleSim.prepare_tutorial_state("pve")
	var empty_result: Dictionary = BattleSim.result_from_state(empty_state)
	_h.expect(bool(empty_state.get("finished", false)), "empty_board_not_finished",
		"空棋盘状态没有立即 finished（%s）" % str(empty_state.get("finished", false)))
	_h.expect(not bool(empty_result.get("player_wins", true))
		and str(empty_result.get("reason", "")) == "no_player_units",
		"empty_board_not_forced_loss",
		"空棋盘不再产生 no_player_units 强制判负（player_wins=%s reason=%s）—— 根因假设变了，第 1 层要重新评估"
		% [str(bool(empty_result.get("player_wins", false))), str(empty_result.get("reason", ""))])

	GameState.reset_run()
	GameState.tutorial_mode = true
	_place("human_militia", 1, 0)
	_place("human_archer", 1, 1)
	_place("human_merchant", 1, 2)
	var full_state: Dictionary = BattleSim.prepare_tutorial_state("pve")
	var steps := 0
	while not bool(full_state.get("finished", false)) and steps < 100000:
		BattleSim.step_state(full_state)
		steps += 1
	var full_result: Dictionary = BattleSim.result_from_state(full_state)
	_h.expect(bool(full_result.get("player_wins", false)), "three_units_lose_to_monsters",
		"3 个 1 星棋子打 3 只教学小怪居然会输（reason=%s alive=%d/%d）—— 「必赢」前提变了，第 1 层从兜底变成了日常路径"
		% [str(full_result.get("reason", "")), int(full_result.get("player_alive", 0)), int(full_result.get("enemy_alive", 0))])

	# ---- ② 第 1 层：coerce_victory 行为 ----
	if _tut.has_method("coerce_victory"):
		TutorialMode.step = TutorialMode.Step.START_PVE_1
		var hp_before: int = GameState.enemy_formation_hp
		var probe: Dictionary = empty_result.duplicate(true)
		Callable(_tut, "coerce_victory").call(probe)
		_h.expect(bool(probe.get("player_wins", false)), "coerce_not_win",
			"coerce_victory 之后 player_wins 仍为假")
		_h.expect(not bool(probe.get("is_draw", true)), "coerce_still_draw",
			"coerce_victory 之后 is_draw 仍为真")
		_h.expect(int(probe.get("enemy_alive", -1)) == 0, "coerce_enemy_alive",
			"coerce_victory 之后 enemy_alive=%s（应为 0）" % str(probe.get("enemy_alive", "<missing>")))
		_h.expect(str(probe.get("kind", "")) == "pve", "coerce_kind",
			"coerce_victory 之后 kind=%s（应为 pve）" % str(probe.get("kind", "")))
		_h.expect(GameState.enemy_formation_hp == hp_before, "coerce_touched_formation_hp",
			"coerce_victory 改了 GameState.enemy_formation_hp（%d -> %d）—— 备战界面的敌方血量会被显示成 0/10"
			% [hp_before, GameState.enemy_formation_hp])
	else:
		_h.fail("coerce_victory_missing", "TutorialMode.coerce_victory() 不存在 —— 第 1 层（结果显示前强制胜）没了")

	# ---- ② 第 1 层接线位置（源码序）----
	# 先剥注释再定位：注释里出现 "_emit_finished()" 这类字样是常事（解释顺序），
	# 直接 find 会把注释当成调用点，量出一个假的顺序。
	var result_body := _strip_comments(_func_body(BATTLE_RESULT_SRC, "_finish_simulation"))
	var sim_at := result_body.find("BattleSim.result_from_state")
	var coerce_at := result_body.find("TutorialMode.coerce_victory(")
	var emit_at := result_body.find("_emit_finished()")
	var guard_at := result_body.find("GameState.tutorial_mode")
	_h.expect(not result_body.is_empty() and sim_at > 0 and coerce_at > 0 and emit_at > 0
		and sim_at < coerce_at and coerce_at < emit_at,
		"layer1_wrong_position",
		"BattleResult._finish_simulation 里教程强制胜没有接在「拿到结果之后、_emit_finished 之前」（sim=%d coerce=%d emit=%d）"
		% [sim_at, coerce_at, emit_at])
	_h.expect(guard_at > 0 and guard_at < coerce_at, "layer1_unguarded",
		"coerce_victory 的调用没有挂在 GameState.tutorial_mode 守卫之下（guard=%d coerce=%d）—— 联机/自测对局会被一起改成必胜"
		% [guard_at, coerce_at])

	# ---- ③ 第 2 层：开战闸 + 自愈 ----
	GameState.reset_run()
	GameState.tutorial_mode = true
	TutorialMode.step = TutorialMode.Step.START_PVE_1
	_bench_put("human_militia", 1, 0)
	_bench_put("human_archer", 1, 1)
	_bench_put("human_merchant", 1, 2)
	var healed: bool = TutorialMode.begin_battle()
	_h.expect(healed and GameState.normal_unit_count() == TutorialMode.EARLY_DEPLOY_UNITS,
		"self_heal_not_deploying",
		"空棋盘 + 待命区 3 个时 begin_battle 没有自愈（allowed=%s count=%d）—— 空棋盘还是会开战、还是会瞬间判负"
		% [str(healed), GameState.normal_unit_count()])

	GameState.reset_run()
	GameState.tutorial_mode = true
	TutorialMode.step = TutorialMode.Step.START_PVE_1
	var refused: bool = TutorialMode.begin_battle()
	_h.expect(not refused and GameState.normal_unit_count() == 0,
		"no_refuse_when_nothing_to_deploy",
		"棋盘和待命区都空时 begin_battle 仍然放行（allowed=%s）—— 没有兜底拒战"
		% str(refused))

	if _tut.has_method("_auto_deploy_from_bench"):
		# 合成守卫：放上去会凑满一份合成的必须跳过（1 星 2 个同名同星就合）
		GameState.reset_run()
		GameState.tutorial_mode = true
		TutorialMode.step = TutorialMode.Step.START_PVE_1
		_place("human_militia", 1, 0)
		_bench_put("human_militia", 1, 0)
		var merge_moved: int = Callable(_tut, "_auto_deploy_from_bench").call(1)
		_h.expect(merge_moved == 0 and GameState.normal_unit_count() == 1,
			"merge_guard_broken",
			"会触发合成的棋子也被搬上棋盘了（moved=%d count=%d）—— 自愈会越补越少"
			% [merge_moved, GameState.normal_unit_count()])

		# 唯一棋子守卫：unique_on_board 的棋子棋盘上只允许 board_limit 个
		var unique_id := _first_unique_unit_id()
		if _h.expect(not unique_id.is_empty(), "no_unique_unit_fixture",
			"race_units 里找不到 unique_on_board 棋子，唯一守卫这条没有数据可验"):
			GameState.reset_run()
			GameState.tutorial_mode = true
			TutorialMode.step = TutorialMode.Step.START_PVE_1
			_place(unique_id, 1, 0)
			_bench_put(unique_id, 1, 0)
			var unique_moved: int = Callable(_tut, "_auto_deploy_from_bench").call(1)
			_h.expect(unique_moved == 0 and GameState.normal_unit_count() == 1,
				"unique_guard_broken",
				"唯一棋子的第二份也被搬上棋盘了（moved=%d）—— 战斗侧会把它跳掉，纯占格子"
				% unique_moved)
	else:
		_h.fail("auto_deploy_missing", "TutorialMode._auto_deploy_from_bench() 不存在 —— 第 2 层的自愈没了")

	# ---- ③ 闸门同源：required_board_units 与 gate 文案必须同一个数 ----
	if _tut.has_method("required_board_units"):
		var start_steps: Array = [
			TutorialMode.Step.START_PVE_1, TutorialMode.Step.START_PVE_2,
			TutorialMode.Step.START_BOSS, TutorialMode.Step.START_PVP,
			TutorialMode.Step.BUY_3, TutorialMode.Step.FILL_7,
		]
		for s in start_steps:
			TutorialMode.step = s
			var need: int = _tut.call("required_board_units")
			GameState.reset_run()
			GameState.tutorial_mode = true
			var msg: String = TutorialMode.battle_board_gate_message()
			if need <= 0:
				_h.expect(msg.is_empty(), "gate_message_on_non_start_step",
					"步骤 %d 不是开战步，却弹了上阵数拦截（%s）" % [int(s), msg])
			else:
				_h.expect(not msg.is_empty() and msg.contains(str(need)),
					"gate_helper_and_message_drifted",
					"步骤 %d 的门禁文案与 required_board_units 不一致（need=%d msg=%s）" % [int(s), need, msg])
	else:
		_h.fail("required_board_units_missing", "TutorialMode.required_board_units() 不存在 —— 闸门数字与文案失去同一来源")

	# ---- ④ 第 3 层：空结算包不得放行详情 ----
	_h.expect(not FinalSettlementData.can_show_details({}, {"kind": "pvp", "completed_round": 21}, {}),
		"empty_settlement_opens_details",
		"空结算包 + 残留 match_state 仍然放行详情 —— 教程通关会弹出装着上一场联机数据的结算面板")
	_h.expect(not FinalSettlementData.can_show_details({}, {}, {"kind": "pve"}),
		"empty_settlement_opens_details_via_replay",
		"空结算包 + replay 的 kind 仍然放行详情")
	_h.expect(FinalSettlementData.can_show_details({"seats": [{"slot": 0, "total_gold": 10}], "kind": "pve"}, {"kind": "pve"}, {}),
		"real_settlement_lost_details",
		"真结算包反而拿不到详情按钮了 —— 第 3 层误伤了正常路径")
	_h.expect(not FinalSettlementData.can_show_details({"seats": [{"slot": 0}], "show_details": false}, {}, {}),
		"show_details_flag_ignored",
		"结算包明确写了 show_details=false 却仍然放行")

	# ---- ④ 第 4 层：进教程无条件清联机残留（源码序）----
	# 同样先剥注释：这段的注释里就写着 TutorialMode.start() 与 restore_checkpoint()
	# 的字样，不剥就会把「解释」当成「调用」。
	var enter_body := _strip_comments(_func_body(MAIN_SRC, "_enter_tutorial_from_startup"))
	var clear_at := enter_body.find("NetworkService.latest_match_state = {}")
	var start_at := enter_body.find("TutorialMode.start()")
	var restore_at := enter_body.find("TutorialMode.restore_checkpoint()")
	_h.expect(clear_at > 0 and (start_at < 0 or clear_at < start_at) and (restore_at < 0 or clear_at < restore_at),
		"layer4_residual_not_cleared",
		"_enter_tutorial_from_startup 没有在开教程之前无条件清掉 latest_match_state（clear=%d start=%d restore=%d）"
		% [clear_at, start_at, restore_at])
	_h.expect(enter_body.contains("NetworkService.team_replay = {}")
		and enter_body.contains("NetworkService.team_replay_rival = {}"),
		"layer4_replay_residual_kept",
		"team_replay / team_replay_rival 的残留没清 —— _battle 失效时 _show_game_over 会拿它当结算 replay")
	# 「无条件」也要钉：三条清理必须落在函数体**顶层**（行首一个缩进）。
	# 只钉位置钉不住「被包进 if NetworkService.team_active:」—— 那正是本 bug 的路径：
	# 打完联机回来 team_active 往往是假的，条件分支不执行，残留全留着。
	_h.expect(enter_body.contains("\n\tNetworkService.latest_match_state = {}")
		and enter_body.contains("\n\tNetworkService.team_replay = {}")
		and enter_body.contains("\n\tNetworkService.team_replay_rival = {}"),
		"layer4_clear_nested",
		"三条残留清理不在函数体顶层（被包进了 if 之类）—— team_active 为假时不会执行，而那正是本 bug 的路径")


# --- 工具 ---------------------------------------------------------------------

func _place(id: String, star: int, slot: int) -> void:
	var def := _unit_def(id)
	if def.is_empty():
		return
	GameState.board_slots[slot] = {"id": id, "uid": GameState.mint_piece_uid(), "star": star, "def": def}


func _bench_put(id: String, star: int, slot: int) -> void:
	var def := _unit_def(id)
	if def.is_empty():
		return
	GameState.bench_slots[slot] = {"id": id, "uid": GameState.mint_piece_uid(), "star": star, "def": def}


func _unit_def(id: String) -> Dictionary:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for u in units:
		if typeof(u) != TYPE_DICTIONARY:
			continue
		if str((u as Dictionary).get("id", "")) == id:
			return (u as Dictionary).duplicate(true)
	return {}


func _first_unique_unit_id() -> String:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for u in units:
		if typeof(u) != TYPE_DICTIONARY:
			continue
		if bool((u as Dictionary).get("unique_on_board", false)):
			return str((u as Dictionary).get("id", ""))
	return ""


# 取一个函数体的源码（从 `func name(` 到下一个顶层 `func `）。
# 用来验接线顺序 —— 这类断言量的是「生产代码自己长什么样」。
func _func_body(path: String, name: String) -> String:
	var src := _read_source(path)
	var start := src.find("func %s(" % name)
	if start < 0:
		return ""
	var end := src.find("\nfunc ", start + 8)
	if end < 0:
		end = src.length()
	return src.substr(start, end - start)


# 剥掉 GDScript 注释（`#` 到行尾），字符串字面量里的 `#` 不动。
#
# 为什么需要它：源码序断言（「A 必须写在 B 之前」）如果直接在原文上 find，
# 注释里提到被排序的那些名字就会被当成调用点 —— 本门禁第一版就栽在这：
# _finish_simulation 的注释解释了「_emit_finished 之后才 battle_finished」，
# 于是 emit_at 量到的是注释、不是调用，报出一个假的顺序错误。
func _strip_comments(src: String) -> String:
	var out := ""
	var i := 0
	var in_str := false
	var quote := ""
	while i < src.length():
		var c := src[i]
		if in_str:
			out += c
			if c == "\\" and i + 1 < src.length():
				out += src[i + 1]
				i += 2
				continue
			if c == quote:
				in_str = false
			i += 1
			continue
		if c == "\"" or c == "'":
			in_str = true
			quote = c
			out += c
			i += 1
			continue
		if c == "#":
			while i < src.length() and src[i] != "\n":
				i += 1
			# 保留换行：行号与语句相对位置不被抹掉。
			out += "\n"
			i += 1
			continue
		out += c
		i += 1
	return out


func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text
