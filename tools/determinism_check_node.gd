extends Node

# D3 —— 回放确定性：SHA-256 + 种子矩阵 + 首差异定位。
#
# 改造前的样子（以及为什么不够）：
#   * 用 32 位 String.hash() —— 碰撞概率对"证明两份回放逐位相同"来说太高
#   * 只哈希 frames + result —— frame_events 和 roster 完全没进哈希，
#     也就是说演出事件流和出场名单变了它也发现不了
#   * 单一 seed、单一回合、4 种单位 —— 覆盖不到 Boss / 最终战 / 佣兵 / 宝物 / 复活 / 打断
#   * 不一致时只说"哈希不等"，不指出差在哪
#   * 用 assert()，失败会中断脚本，后面的用例一个都不跑
#
# 现在：整份 replay（含 frames / frame_events / roster / result）走 SHA-256，
# 与 scripts/qa/battle_presentation_baseline.gd **共用** scripts/qa/ReplayDigest.gd 的
# 规范化与哈希实现 —— 两份实现会漂移，跨平台比对就没有意义。
#
# 覆盖不是靠"跑了几个 case"声称的：每个 case 都要用 expect 断言它那一维
# 真的出现在 roster/帧里（Boss 真刷出来了、佣兵真上场了、复活真发生了）。
# 否则就是又一个假绿 —— 跑满 14 个 case 却一个 Boss 都没打到。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/determinism_check.tscn
#   不要加 --quit-after。
#
# 仍未覆盖（不得写成通过）：
#   跨平台（桌面 vs Android ARM64）。Android 按用户决定暂停，恢复后才能补。

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const CheckHarness := preload("res://tools/CheckHarness.gd")
const ReplayDigest := preload("res://scripts/qa/ReplayDigest.gd")

const CHECK_NAME := "determinism"

# 与 battle_presentation_baseline.gd 同源，便于两边结果互相印证。
const SEED := 20260807
const FILL_ORDER: Array[int] = [1, 2, 0, 3, 5, 6, 4, 7]
# 固定样本不能继承账号当前选中的宠物，否则换个账号跑结果就变了。
# 只钉这份夹具，不写 PlayerProfile。
const FIXED_PET_ID := ""

const LINEUPS := {
	"human": ["human_swordsman", "human_archer", "human_king", "human_mage"],
	"god": ["god_guard", "god_arbiter", "god_king", "god_priestess"],
	"dark": ["dark_suc", "dark_scythe", "dark_dragon", "dark_mage"],
	"undead": ["undead_spike", "undead_bomb", "undead_mother", "undead_poison"],
}

const MERC_IDS := ["merc_leo_sun", "merc_virgo_heal"]

# link_phoenix 是联动而非单件宝物：requires = [atk_wail_resonance, def_soul_counter]。
# 两件都持有才会触发 BattleSimTreasures._queue_phoenix_revive()。
const PHOENIX_TREASURES := ["atk_wail_resonance", "def_soul_counter"]
const INTERRUPT_TREASURES := ["ctrl_interrupt_chain"]
const MIXED_TREASURES := ["def_iron_wall", "def_life_monument", "ctrl_shockwave"]

# expect 取值：boss / mercenary / formation_ally / revive / interrupt / death
#
# 每个 case 都会额外断言 a 方阵容的单位真的出现在 player 队的 roster 里。
# 这条是必须的：第一版没有它，结果 round 3 是 PVE 回合、对手是怪物而不是 b 方，
# 于是换 b 方阵容对结果毫无影响 —— 四个"不同种族"的 case 里有两对哈希完全相同，
# 声称覆盖四种族，实际只覆盖了 a 方那两种。
#
# b 方阵容只在 PVP/final 回合真正参战（RoundService 的排期：6/12/18 是 PVP，21 是 final），
# 所以种族维度靠轮换 **a 方** 来覆盖，b 方差异放在 pvp_round_06 和 final_round_21 上验证。
const CASES := [
	{"name": "race_human", "round": 3, "a": "human", "b": "dark", "expect": ["death"]},
	{"name": "race_god", "round": 3, "a": "god", "b": "dark", "expect": ["death"]},
	{"name": "race_dark", "round": 3, "a": "dark", "b": "human", "expect": ["death"]},
	{"name": "race_undead", "round": 3, "a": "undead", "b": "human", "expect": ["death"]},
	{"name": "pvp_round_06", "round": 6, "a": "human", "b": "undead", "expect": []},
	{"name": "boss_round_05", "round": 5, "a": "human", "b": "dark", "expect": ["boss"]},
	{"name": "boss_round_10", "round": 10, "a": "god", "b": "undead", "expect": ["boss"]},
	{"name": "boss_round_15", "round": 15, "a": "human", "b": "undead", "expect": ["boss"]},
	{"name": "boss_round_20", "round": 20, "a": "god", "b": "dark", "expect": ["boss"]},
	{"name": "final_round_21", "round": 21, "a": "human", "b": "dark", "expect": ["formation_ally"]},
	{"name": "mercenaries", "round": 3, "a": "human", "b": "dark", "mercs": true, "expect": ["mercenary"]},
	{"name": "treasures_mixed", "round": 3, "a": "human", "b": "dark", "treasures": MIXED_TREASURES, "expect": []},
	# 复活要求**我方**单位阵亡。实测：PVE 与 Boss 回合（3/5/10/15/20）里 3 星阵容全胜不掉人，
	# 死的全是怪物，而怪物没有宝物 —— 所以那些回合放 phoenix 永远不会触发。
	# 全矩阵里只有 pvp_round_06 与 final_round_21 出现 death_player，故放在 PVP 回合。
	# death_player 也写进 expect：将来若数值调整导致我方不再阵亡，报错会直接指出前提没满足，
	# 而不是含糊地说"复活没出现"。
	{"name": "revive_phoenix", "round": 6, "a": "human", "b": "dark", "treasures": PHOENIX_TREASURES, "expect": ["death_player", "revive"]},
	{"name": "interrupt_chain", "round": 3, "a": "human", "b": "dark", "treasures": INTERRUPT_TREASURES, "expect": ["interrupt"]},
]

var _h: CheckHarness
var _unit_defs_cache: Dictionary = {}
var _coverage: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var started := Time.get_ticks_msec()
	for case in CASES:
		await _run_case(case as Dictionary)
	print("[%s] 覆盖汇总：%s" % [CHECK_NAME, _coverage_summary()])
	print("[%s] 用例 %d 个，耗时 %.1f 秒" % [
		CHECK_NAME, CASES.size(), (Time.get_ticks_msec() - started) / 1000.0])
	print("[%s] 未覆盖：跨平台（桌面 vs Android）—— Android 暂停中，不得视为通过" % CHECK_NAME)
	_h.finish(get_tree())


func _run_case(case: Dictionary) -> void:
	var case_name := str(case.get("name", "?"))
	_setup_case(case)

	# 三次计算之间**不**重建状态：这样才能证明计算本身不会污染共享状态。
	# 重建后再比只能证明"同样的输入给同样的输出"，是更弱的性质。
	var sync_1: Dictionary = BattleSim.compute_team_replay(0)
	var sync_2: Dictionary = BattleSim.compute_team_replay(0)
	var async_1: Dictionary = await BattleSim.compute_team_replay_async(0)

	var h_sync_1 := ReplayDigest.sha256_variant(sync_1)
	var h_sync_2 := ReplayDigest.sha256_variant(sync_2)
	var h_async := ReplayDigest.sha256_variant(async_1)

	if not _h.expect(not h_sync_1.is_empty(), "hash_failed", "%s：SHA-256 计算失败" % case_name):
		return

	# 不一致时必须指出**第一个**不同的路径。README D3 验收：
	# 「跨平台差异给出首个不同 tick、事件和字段，不允许只输出总哈希不一致」
	if h_sync_1 != h_sync_2:
		_h.fail("sync_not_repeatable", "%s：同步两次结果不同，首差异 %s" % [
			case_name, ReplayDigest.first_difference(sync_1, sync_2)])
	else:
		_h.item()
	if h_sync_1 != h_async:
		_h.fail("sync_vs_async", "%s：同步与分帧结果不同，首差异 %s" % [
			case_name, ReplayDigest.first_difference(sync_1, async_1)])
	else:
		_h.item()

	var found := _detect_coverage(sync_1)
	for token in found:
		_coverage[token] = int(_coverage.get(token, 0)) + 1
	for want in (case.get("expect", []) as Array):
		var token := str(want)
		_h.expect(found.has(token), "coverage_missing",
			"%s：声称覆盖 %s，但回放里没有出现（该用例没有证明这一维）" % [case_name, token])

	# 我摆的阵容真的上场了吗？没有这条，"换了阵容却毫无影响"会静默通过。
	_check_lineup_fielded(case, sync_1)

	var roster: Dictionary = sync_1.get("roster", {})
	var frames: Array = sync_1.get("frames", [])
	var events: Array = sync_1.get("frame_events", [])
	print("[%s] %-22s roster=%-3d frames=%-4d events=%-4d cover=[%s] sha=%s" % [
		CHECK_NAME, case_name, roster.size(), frames.size(),
		_count_events(events), ", ".join(found), h_sync_1.substr(0, 16)])


# --- 用例构造 -----------------------------------------------------------------

func _setup_case(case: Dictionary) -> void:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = int(case.get("round", 3))
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP

	# 宝物必须在建 submission 之前设：NetProtocol.team_board_submission()
	# 是在调用那一刻读 GameState.owned_treasures 的。
	GameState.owned_treasures.clear()
	for tid in (case.get("treasures", []) as Array):
		GameState.owned_treasures.append(str(tid))

	var use_mercs := bool(case.get("mercs", false))
	var mercs := _merc_slots() if use_mercs else _empty_mercs()
	GameState.mercenary_slots = mercs.duplicate(true)
	GameState.board_slots = _board_from_ids(LINEUPS[str(case.get("a", "human"))] as Array)

	# 这些字段每个 case 都整体重设，避免上一个 case 的状态渗到下一个 ——
	# 那种污染的症状是"偶尔不一致"，是最难查的一类。
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = SEED
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = {}
	for lane in 3:
		boards[lane] = _submission(_board_from_ids(LINEUPS[str(case.get("a", "human"))] as Array), mercs)
		boards[lane + 3] = _submission(_board_from_ids(LINEUPS[str(case.get("b", "dark"))] as Array), mercs)
	NetworkService.team_boards = boards


func _submission(board: Array, mercenaries: Array) -> Dictionary:
	var snapshot: Dictionary = NetProtocol.team_board_submission(board, mercenaries)
	snapshot["pet"] = FIXED_PET_ID
	return snapshot


func _board_from_ids(unit_ids: Array) -> Array:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	var defs := _unit_defs()
	var placed := 0
	for value in unit_ids:
		if placed >= FILL_ORDER.size() or placed >= GameState.MAX_NORMAL_UNITS:
			break
		var unit_id := str(value)
		if not defs.has(unit_id):
			_h.fail("unknown_unit", "阵容引用了不存在的单位 '%s'" % unit_id)
			continue
		board[FILL_ORDER[placed]] = {"id": unit_id, "star": 3, "def": (defs[unit_id] as Dictionary).duplicate(true)}
		placed += 1
	return board


func _merc_slots() -> Array:
	var slots := _empty_mercs()
	var defs := _merc_defs()
	var index := 0
	for merc_id in MERC_IDS:
		if index >= slots.size():
			break
		if not defs.has(merc_id):
			_h.fail("unknown_mercenary", "佣兵表里没有 '%s'" % merc_id)
			continue
		slots[index] = {"id": merc_id, "star": 1, "def": (defs[merc_id] as Dictionary).duplicate(true), "is_mercenary": true}
		index += 1
	return slots


func _empty_mercs() -> Array:
	var slots: Array = []
	slots.resize(GameState.MERCENARY_SLOTS)
	return slots


func _unit_defs() -> Dictionary:
	if _unit_defs_cache.is_empty():
		for row in DataRegistry.get_table("race_units").get("units", []):
			_unit_defs_cache[str((row as Dictionary).get("id", ""))] = row
	return _unit_defs_cache


func _merc_defs() -> Dictionary:
	var out: Dictionary = {}
	for row in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		out[str((row as Dictionary).get("id", ""))] = row
	return out


# --- 覆盖检测 -----------------------------------------------------------------

# 从实际回放里读出这一场到底发生了什么，而不是相信用例的声明。
func _detect_coverage(replay: Dictionary) -> Array[String]:
	var found: Array[String] = []
	var roster: Dictionary = replay.get("roster", {})
	# 死亡要分阵营：只说"有单位死了"不足以支撑复活用例 —— 复活要求**我方**阵亡，
	# 而 PVE 回合死的往往全是怪物，怪物没有宝物，自然不会触发 phoenix。
	var team_of: Dictionary = {}
	for uid in roster:
		var row: Dictionary = roster[uid]
		team_of[str(uid)] = str(row.get("team", ""))
		var unit_id := str(row.get("id", ""))
		if unit_id.begins_with("boss_") and not found.has("boss"):
			found.append("boss")
		if bool(row.get("is_mercenary", false)) and not found.has("mercenary"):
			found.append("mercenary")
		if bool(row.get("is_formation_ally", false)) and not found.has("formation_ally"):
			found.append("formation_ally")
		if str(uid).contains("_phoenix_") and not found.has("revive"):
			found.append("revive")
	for frame in (replay.get("frames", []) as Array):
		for unit in (frame as Array):
			if not (unit is Array) or (unit as Array).size() < 10:
				continue
			var row: Array = unit
			if not bool(row[4]):
				if not found.has("death"):
					found.append("death")
				var token := "death_player" if str(team_of.get(str(row[0]), "")) == "player" else "death_enemy"
				if not found.has(token):
					found.append(token)
			if str(row[9]).contains("interrupt") and not found.has("interrupt"):
				found.append("interrupt")
	found.sort()
	return found


# a 方阵容的每个单位都必须出现在 player 队的 roster 里。
# 这条断言是补上来的：没有它，「改了阵容但那一侧根本没参战」会安静通过。
func _check_lineup_fielded(case: Dictionary, replay: Dictionary) -> void:
	var case_name := str(case.get("name", "?"))
	var fielded: Dictionary = {}
	for uid in (replay.get("roster", {}) as Dictionary):
		var row: Dictionary = (replay.get("roster", {}) as Dictionary)[uid]
		if str(row.get("team", "")) == "player":
			fielded[str(row.get("id", ""))] = true
	for unit_id in (LINEUPS[str(case.get("a", "human"))] as Array):
		_h.expect(fielded.has(str(unit_id)), "lineup_not_fielded",
			"%s：摆了 %s 但它没出现在 player 队的 roster 里" % [case_name, str(unit_id)])


func _count_events(frame_events: Array) -> int:
	var total := 0
	for bucket in frame_events:
		if bucket is Array:
			total += (bucket as Array).size()
	return total


func _coverage_summary() -> String:
	var keys: Array = _coverage.keys()
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		parts.append("%s×%d" % [str(key), int(_coverage[key])])
	return ", ".join(parts) if not parts.is_empty() else "(空)"
