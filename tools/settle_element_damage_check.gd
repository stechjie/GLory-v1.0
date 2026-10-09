extends Node

# 10.09 bug 文档第 4 条（结算面板没算元素伤害）的**行为判据**。
#
# 症状与实测（work/_qa_1009/probe_attr_paths.gd、probe_poison_credit.gd）：
#   * 「本回合总造成伤害」= 逐棋子 `unit_stats[uid].damage_dealt` 之和。普通棋子挂的
#     **毒/火伤其实已经计入**（实测：归毒 18000 全额记在挂毒棋子的 damage_dealt 上）。
#   * 真正丢失的只有两条**没有棋子身份**的路径：自爆灵死亡爆炸（连同它挂的毒）、
#     寄生灵分身打出的伤害。它们既不是这一击的攻击者、也不在 unit_stats 里，
#     谁都认领不到 ⇒ 直接从总伤害里消失（实测：爆炸 250 + 毒 600 = 850 全部丢失）。
#   * 用户口径：「把这类伤害计入本回合总造成伤害里，**但不计入棋子的个人伤害里**」。
#
# 修复落点：DamageService 的元素旁路（`state.element_damage_by_slot`）。
# 本门禁逐条钉住那个口径，并防两类回归：
#   ① 元素旁路里的伤害**不许**写进任何棋子的 damage_dealt；
#   ② 正常归属的毒**不许**被误记进元素旁路（否则总伤害会双计）。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/settle_element_damage_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Bomber := preload("res://scripts/battle/BattleSimTreasures.gd")
const Sim := preload("res://scripts/battle/BattleSimulator.gd")
const Settlement := preload("res://scripts/multiplayer/FinalSettlementData.gd")

const CHECK_NAME := "settle_element_damage"
# 与 probe_undead_damage 同一颗种子：整场 3v3 可复现。
const FIXED_SEED := 20261009

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.load_all()
	_case_death_explosion_and_its_poison()
	_case_parasite_clone()
	_case_attributed_poison_unchanged()
	_case_sudden_death_not_element()
	_case_update_round_damage_bucket()
	_case_team_replay_end_to_end()
	_h.finish(get_tree())


# --- 脚手架 -------------------------------------------------------------------

func _fighter(uid: String, team: String, owner_slot: int, hp: int, atk: int = 100, skill_id: String = "") -> Dictionary:
	return {
		"uid": uid, "id": uid, "name": uid, "team": team, "lane": 0, "owner_slot": owner_slot,
		"pos": Vector2(0, 0), "hp": hp, "max_hp": hp, "atk": atk, "defense": 0, "alive": true,
		"shield": 0, "dodge": 0.0, "statuses": {}, "attack_count": 0,
		"def": {"skill_id": skill_id, "damage_atk_pct": 2.5, "element": "sky"},
	}


func _state(fighters: Array) -> Dictionary:
	var stats := {}
	for f in fighters:
		stats[str(f.uid)] = {"id": str(f.uid), "owner_slot": int(f.owner_slot), "team": str(f.team),
			"damage_dealt": 0, "damage_taken": 0, "healing_done": 0, "debuffs": {}, "buffs": {}}
	return {"kind": "pvp", "player": [], "enemy": [], "elapsed": 5.0, "visual_events": [], "unit_stats": stats,
		"log": [], "owner_syn_by_key": {}, "owner_state": {}}


func _bucket(state: Dictionary) -> Dictionary:
	var raw: Variant = state.get("element_damage_by_slot", {})
	return raw if typeof(raw) == TYPE_DICTIONARY else {}


func _dealt(state: Dictionary, uid: String) -> int:
	var stats: Dictionary = state.get("unit_stats", {})
	if not stats.has(uid):
		return -1
	return int((stats[uid] as Dictionary).get("damage_dealt", 0))


func _taken(state: Dictionary, uid: String) -> int:
	var stats: Dictionary = state.get("unit_stats", {})
	if not stats.has(uid):
		return -1
	return int((stats[uid] as Dictionary).get("damage_taken", 0))


# --- 用例 1：自爆灵死亡爆炸 + 它挂的毒 -----------------------------------------

func _case_death_explosion_and_its_poison() -> void:
	var bomb := _fighter("p_bomb", "player", 1, 100, 100, "death_poison_explosion")
	bomb.alive = false
	bomb.hp = 0
	var victim := _fighter("e_x", "enemy", 4, 5000)
	var state := _state([bomb, victim])
	state["player"] = [bomb]
	state["enemy"] = [victim]
	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()

	# 与 step_state 同款：清掉上下文后走 per-tick 清扫（覆盖技能/AOE 致死）。
	Bomber._process_death_explosions(state)
	# 爆炸本体 = 250% ATK = 250（真伤、无来源 ⇒ 强度系数全是 1.0）。
	_h.expect(_bucket(state).get(1, 0) == 250, "explosion_into_element_bucket",
		"自爆灵爆炸(250) 没进元素账本：bucket=%s" % str(_bucket(state)))
	_h.expect(_dealt(state, "p_bomb") == 0, "explosion_not_piece_damage",
		"爆炸被记进了棋子的个人伤害（p_bomb.damage_dealt=%d，应为 0）" % _dealt(state, "p_bomb"))
	_h.expect(_taken(state, "e_x") == 250, "explosion_records_taken",
		"受害者的 damage_taken 应为 250，实际 %d" % _taken(state, "e_x"))
	_h.expect(bool(victim.statuses.has("poison")), "explosion_applies_poison",
		"爆炸应给范围内敌人挂毒，实际 statuses=%s" % str(victim.statuses.keys()))

	# 毒跳 6 秒：duration=4.0 ⇒ 4 跳 × (3% × 5000 = 150) = 600
	for i in 6:
		DamageService.clear_stat_context()
		StatusEffectService.tick(victim, 1.0)
	_h.expect(_bucket(state).get(1, 0) == 850, "explosion_poison_into_element_bucket",
		"爆炸 + 其毒的 850 应全在元素账本：bucket=%s" % str(_bucket(state)))
	_h.expect(_dealt(state, "p_bomb") == 0, "explosion_poison_not_piece_damage",
		"爆炸毒的后续跳伤被记进了个人伤害（p_bomb.damage_dealt=%d，应为 0）" % _dealt(state, "p_bomb"))
	_h.expect(_taken(state, "e_x") == 850, "explosion_poison_records_taken",
		"受害者 damage_taken 应为 850，实际 %d" % _taken(state, "e_x"))
	DamageService.clear_stat_context()


# --- 用例 2：寄生灵分身 -------------------------------------------------------

func _case_parasite_clone() -> void:
	var killer := _fighter("p_parasite", "player", 0, 1000, 100, "parasite_on_kill")
	var seed_victim := _fighter("e_seed", "enemy", 3, 5000)
	var target := _fighter("e_y", "enemy", 4, 5000)
	var state := _state([killer, seed_victim, target])
	state["player"] = [killer]
	state["enemy"] = [seed_victim, target]
	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()

	# 走真实入口，顺带验它确实打了「无归属」标记、且不在 unit_stats 里。
	_h.expect(Sim._maybe_spawn_parasite_clone(killer, seed_victim, state), "clone_spawned",
		"寄生灵击杀应召出分身")
	var clone: Dictionary = {}
	for f in state.player:
		if str(f.uid).contains("_parasite_"):
			clone = f
	if not _h.expect(not clone.is_empty(), "clone_present", "分身没进 player 列表"):
		return
	_h.expect(int(clone.get(DamageService.UNATTRIBUTED_OWNER_KEY, -1)) == 0, "clone_marked_unattributed",
		"分身应带 unattributed_owner_slot=0，实际 %s" % str(clone.get(DamageService.UNATTRIBUTED_OWNER_KEY, -1)))
	_h.expect(not state.unit_stats.has(str(clone.uid)), "clone_absent_from_unit_stats",
		"分身本来就不在 unit_stats 里（这正是它伤害丢失的原因），unit_stats=%d 项" % state.unit_stats.size())

	# 分身的普攻：500 应进元素账本，不进任何棋子。
	state["elapsed"] = 0.0
	DamageService.begin_stat_context(state, clone)
	DamageService.apply_damage(target, 500)
	DamageService.clear_stat_context()
	_h.expect(_bucket(state).get(0, 0) == 500, "clone_attack_into_element_bucket",
		"分身普攻(500) 应进元素账本：bucket=%s" % str(_bucket(state)))

	# 分身挂的毒：同样按 owner_slot 入账，且毒本身也进账本。
	DamageService.begin_stat_context(state, clone)
	StatusEffectService.add_poison(target, 4.0, 0.03)
	DamageService.clear_stat_context()
	for i in 6:
		DamageService.clear_stat_context()
		StatusEffectService.tick(target, 1.0)
	_h.expect(_bucket(state).get(0, 0) == 1100, "clone_poison_into_element_bucket",
		"分身 500 + 其毒 600 = 1100 应全在元素账本：bucket=%s" % str(_bucket(state)))
	_h.expect(_dealt(state, str(clone.uid)) == -1, "clone_never_credited",
		"分身不该出现在 unit_stats 里")
	DamageService.clear_stat_context()


# --- 用例 3：正常归属的毒仍然进个人伤害、不进元素账本（防双计） ---------------

func _case_attributed_poison_unchanged() -> void:
	var hero := _fighter("p_poison", "player", 2, 1000, 100, "poison_attack")
	var victim := _fighter("e_z", "enemy", 5, 100000)
	var state := _state([hero, victim])
	state["player"] = [hero]
	state["enemy"] = [victim]
	DamageService.set_stat_state(state)
	DamageService.begin_stat_context(state, hero)
	StatusEffectService.add_poison(victim, 6.0, 0.03)
	DamageService.clear_stat_context()
	for i in 6:
		DamageService.clear_stat_context()
		StatusEffectService.tick(victim, 1.0)
	var dealt := _dealt(state, "p_poison")
	_h.expect(dealt > 0, "attributed_poison_still_personal",
		"普通棋子挂的毒应照旧记进它的 damage_dealt，实际 %d" % dealt)
	_h.expect(_dealt(state, "p_poison") == _taken(state, "e_z"), "attributed_poison_matches_taken",
		"个人伤害(%d) 应等于受害者承伤(%d)" % [dealt, _taken(state, "e_z")])
	_h.expect(_bucket(state).is_empty(), "attributed_poison_not_in_element_bucket",
		"正常归属的毒不许再进元素账本（否则总伤害双计）：bucket=%s" % str(_bucket(state)))
	DamageService.clear_stat_context()


# --- 用例 4：环境伤害（65 秒衰减）不许被当成元素伤害 -------------------------

func _case_sudden_death_not_element() -> void:
	var hero := _fighter("p_env", "player", 0, 1000)
	var victim := _fighter("e_env", "enemy", 4, 5000)
	var state := _state([hero, victim])
	state["player"] = [hero]
	state["enemy"] = [victim]
	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()
	# 故意在外面开着元素旁路，模拟「上一次元素结算没清干净」的最坏情况。
	DamageService.set_element_owner_slot(0)
	DamageService.apply_sudden_death_damage(victim, 100)
	_h.expect(_bucket(state).get(0, 0) == 0, "sudden_death_not_element",
		"环境伤害被记进了元素账本：bucket=%s" % str(_bucket(state)))
	_h.expect(_taken(state, "e_env") == 100, "sudden_death_still_counted_taken",
		"环境伤害的 damage_taken 应照旧记 100，实际 %d" % _taken(state, "e_env"))
	DamageService.clear_stat_context()


# --- 用例 5：update_round_damage 的口径 ---------------------------------------

func _case_update_round_damage_bucket() -> void:
	var seats: Array = []
	for i in 6:
		seats.append({"slot": i, "round_damage": -1})
	var stats: Array = [
		{"owner_slot": 1, "damage_dealt": 1000},
		{"owner_slot": 1, "damage_dealt": 500},
		{"owner_slot": 4, "damage_dealt": 200},
	]
	# 键在 JSON 里会变字符串，故意混着放，验 int() 归一。
	var element: Dictionary = {1: 700, "4": 300}
	Settlement.update_round_damage(seats, stats, element)
	_h.expect(int(seats[1].round_damage) == 2200, "round_damage_includes_element",
		"席位 1 总伤害应为 1000+500+700=2200，实际 %d" % int(seats[1].round_damage))
	_h.expect(int(seats[4].round_damage) == 500, "round_damage_string_key_normalized",
		"席位 4 总伤害应为 200+300=500，实际 %d" % int(seats[4].round_damage))
	_h.expect(int(seats[0].round_damage) == 0, "round_damage_unaffected_slot",
		"无输出的席位应为 0，实际 %d" % int(seats[0].round_damage))
	# 个人伤害列不能被改动 —— 元素账本只进总伤害。
	_h.expect(int((stats[0] as Dictionary).damage_dealt) == 1000, "stats_untouched_by_element",
		"update_round_damage 不许改写 stats[].damage_dealt")
	# 默认参数（旧调用/旧记录）行为不变。
	var legacy: Array = [{"slot": 0, "round_damage": -1}, {"slot": 1, "round_damage": -1}]
	Settlement.update_round_damage(legacy, [{"owner_slot": 1, "damage_dealt": 42}])
	_h.expect(int(legacy[1].round_damage) == 42, "legacy_call_unchanged",
		"不传元素账本时行为应与以前完全一致，实际 %d" % int(legacy[1].round_damage))


# --- 用例 6：端到端（全灵族 3v3 真打一场） ------------------------------------

func _case_team_replay_end_to_end() -> void:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = 6
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP

	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var undead: Array = []
	for u in units:
		if str((u as Dictionary).get("race", "")) == "undead":
			undead.append(u)
	if not _h.expect(undead.size() > 0, "undead_units_present", "race_units 里挑不出灵族棋子"):
		return
	# 自爆灵（death_poison_explosion）与寄生灵（parasite_on_kill）都必须在场上，
	# 否则这一场根本覆盖不到本 bug 的两条路径。
	var has_bomb := false
	var has_parasite := false
	for u in undead:
		var sid := str((u as Dictionary).get("skill_id", ""))
		has_bomb = has_bomb or sid == "death_poison_explosion"
		has_parasite = has_parasite or sid == "parasite_on_kill"
	if not _h.expect(has_bomb and has_parasite, "bug_paths_on_field",
			"灵族表里应同时有 自爆灵(%s)/寄生灵(%s)" % [str(has_bomb), str(has_parasite)]):
		return

	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	for i in mini(undead.size(), GameConstants.CELL_COUNT):
		var def: Dictionary = (undead[i] as Dictionary).duplicate(true)
		board[i] = {"id": def.get("id", "unit"), "star": 3, "def": def}
	GameState.board_slots = board.duplicate(true)
	GameState.mercenary_slots = []
	GameState.mercenary_slots.resize(GameState.MERCENARY_SLOTS)

	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = FIXED_SEED
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var submission := NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots)
	var boards: Dictionary = {}
	for slot in 6:
		boards[slot] = submission.duplicate(true)
	NetworkService.team_boards = boards

	var replay: Dictionary = Sim.compute_team_replay(0)
	var result: Dictionary = replay.get("result", {})
	if not _h.expect(result.has("element_damage_by_slot"), "replay_carries_element_ledger",
			"replay.result 里没有 element_damage_by_slot —— 结算面板拿不到元素账本"):
		return
	var element: Dictionary = result.get("element_damage_by_slot", {})

	# 我方席位 0..2 的元素账本必须 > 0：自爆灵爆炸 + 其毒、寄生灵分身都真实发生过。
	var player_element := 0
	for key in element.keys():
		var slot := int(key)
		if slot >= 0 and slot < 3:
			player_element += int(element[key])
	_h.expect(player_element > 0, "player_element_damage_captured",
		"我方元素账本应 > 0（自爆灵/寄生灵都上阵且打完全场），实际 %d（bucket=%s）" % [player_element, str(element)])

	# 不变式：结算总伤害 == Σ(该席位 stats.damage_dealt) + 该席位元素账本。
	var stats: Dictionary = result.get("unit_stats", {})
	var seats: Array = []
	for i in 6:
		seats.append({"slot": i, "round_damage": 0})
	var side_stats: Array = []
	var expected: Dictionary = {}
	for uid in stats.keys():
		var entry: Dictionary = stats[uid]
		var slot := int(entry.get("owner_slot", -1))
		if slot < 0 or slot >= 3 or str(entry.get("group", "")) == "boss":
			continue
		side_stats.append(entry)
		expected[slot] = int(expected.get(slot, 0)) + int(entry.get("damage_dealt", 0))
	var element_side: Dictionary = {}
	for key in element.keys():
		var slot := int(key)
		if slot >= 0 and slot < 3:
			element_side[slot] = int(element[key])
			expected[slot] = int(expected.get(slot, 0)) + int(element[key])
	Settlement.update_round_damage(seats, side_stats, element_side)
	for i in 3:
		_h.expect(int(seats[i].round_damage) == int(expected.get(i, 0)), "round_damage_invariant",
			"席位 %d 总伤害 %d != Σ个人伤害 + 元素账本 %d" % [i, int(seats[i].round_damage), int(expected.get(i, 0))])
	# 个人伤害列本身不含元素账本 —— 这是上面那条不变式成立的前提，这里正面再钉一次：
	# 只要账本非空，Σ个人伤害 就必须**严格小于**总伤害。
	var element_total := 0
	for key in element_side.keys():
		element_total += int(element_side[key])
	if element_total > 0:
		var per_piece_total := 0
		for i in 3:
			per_piece_total += int(expected.get(i, 0)) - int(element_side.get(i, 0))
		var grand_total := 0
		for i in 3:
			grand_total += int(seats[i].round_damage)
		_h.expect(grand_total > per_piece_total, "element_not_in_per_piece",
			"总伤害(%d) 必须严格大于逐棋子个人伤害之和(%d)，差值即元素账本(%d)" % [
				grand_total, per_piece_total, element_total])
