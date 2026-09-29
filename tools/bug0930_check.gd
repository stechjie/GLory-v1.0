extends Node

# 门禁：9.30 bug 文档（桌面 `bug提交及优化.docx`）两条修复。
#
# ## ① 羁绊「神3·吸血」未判种族
#
# 官方文案（scenes/prep/panels/SynergyPanel.gd:154）：
#   「神3·吸血：**神族单位**造成伤害时回复实际伤害 20% 生命。」
# 修复前 `BattleSimulator._perform_attack` 只取了队伍羁绊 `syn` 就直接 `_heal_unit`
# ⇒ 队伍凑够 3 神之后，**非神族**棋子（含佣兵）普攻也吸血 20%。
# 修法：条件补 `str(d.get("race","")) == "god"`，与同函数里暗族的写法对齐。
#
# ## ② 自爆灵被技能击杀时自爆失效
#
# 自爆灵（`undead_bomb` / `death_poison_explosion`）的爆炸本体原来**只**写在
# `BattleSimulator._on_unit_killed` —— 那是**普攻致死**入口，被技能/AOE 打死时
# 一声不响。修法：把爆炸本体抽成 `BattleSimTreasures.apply_death_poison_explosion`，
# 普攻入口保持即时引爆，另加一条 per-tick 清扫 `_process_death_explosions`
# （与 `_process_race_death_traits` / `_process_pending_kill_rewards` 同款）
# 覆盖其余致死方式；两边用 `death_explosion_done` 去重。
#
# ## 这条门禁验什么（行为 + 结构，缺一不可）
#
#   1. 行为：神来数 3、`god_lifesteal` 0.20（前置体检，不成立则用例作废）
#   2. 行为：**神族**普攻的回血 == round(dealt × 20%)
#   3. 行为：**非神族**普攻回血 == 0          ← ① 的判据
#   4. 行为：技能/AOE 致死 ⇒ 爆炸（掉血 = atk × damage_atk_pct）+ 中毒  ← ② 的判据
#   5. 行为：普攻致死 ⇒ 仍然即时爆炸（回归，不许被改坏）
#   6. 行为：同一具尸体连扫两次，第二次掉血 0（两个调用点去重）
#   7. 结构：`step_state` 收尾调了清扫；`_perform_attack` 的吸血行带种族判定；
#      公共爆炸函数的判据（存活 / `_can_target` / 180 / 中毒）齐全；
#      普攻入口走公共函数并落标记
#   8. 体检：断言总数不得低于下界（用例中途 return 时不许静默变绿）
#
# ## 跑
#   godot --headless --path <项目> tools/bug0930_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const SIM_PATH := "res://scripts/battle/BattleSimulator.gd"
const TREASURES_PATH := "res://scripts/battle/BattleSimTreasures.gd"
const FLOW_PATH := "res://scenes/prep/PrepFlowController.gd"

const CHECK_NAME := "bug0930"
# 用例全部跑完时的断言数约 55；取 45 做下界，中途 return 会立刻跌破。
const MIN_EXPECTS := 45

const EXPLOSION_RADIUS := 180.0

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	# 本门禁的用例都是同步的（不 await 任何构建），无需 await；
	# 但用例体里带前置 return，所以结尾必须有体检断言兜住「没跑到」。
	_case_god_lifesteal()
	_case_bomb_skill_kill()
	_case_bomb_skill_kill_with_ally()
	_case_bomb_dot_kill_tail_sweep()
	_case_bomb_attack_kill()
	_case_bomb_dedup()
	_case_structure()
	_h.expect(_h.checked_count() >= MIN_EXPECTS, "cases_not_executed",
		"实际断言数 %d 低于下界 %d —— 有用例没跑到（构造失败或提前 return）" % [
			_h.checked_count(), MIN_EXPECTS])
	_h.finish(get_tree())


# ---------- 夹具 ----------

func _mk(placements: Array) -> Dictionary:
	var cfg := {"placements": [], "slot_treasures": {}}
	for p in placements:
		OfficeTestSim.set_placement(cfg, int(p["slot"]), int(p["cell"]), "piece",
			str(p["id"]), int(p["star"]))
	# ★ display_only 必须为 false：true 会在 _finalize_team_opening 之前 return，
	#   开场技能全不应用（既有的假阴性坑）。
	return OfficeTestSim.build_test_state(cfg, false)


func _find(state: Dictionary, team: String, id: String) -> Dictionary:
	for f in state.get(team, []):
		if f is Dictionary and str(f.get("def", {}).get("id", "")) == id:
			return f
	return {}


func _first_alive(state: Dictionary, team: String) -> Dictionary:
	for f in state.get(team, []):
		if f is Dictionary and bool(f.get("alive", false)):
			return f
	return {}


# ---------- ① 神3·吸血 ----------

func _case_god_lifesteal() -> void:
	var state := _mk([
		{"slot": 0, "cell": 0, "id": "god_priestess", "star": 1},
		{"slot": 0, "cell": 1, "id": "god_guard", "star": 1},
		{"slot": 0, "cell": 2, "id": "god_aurora", "star": 1},
		{"slot": 0, "cell": 3, "id": "undead_small", "star": 1},   # 非神族对照组
		{"slot": 3, "cell": 0, "id": "undead_mother", "star": 1},
	])
	var att := _find(state, "player", "god_priestess")
	if att.is_empty():
		_h.fail("god_fixture_missing", "构造不出大祭司 —— 用例作废")
		return
	# 前置体检：读「攻击者真正用的那一份 syn」（生产口径），不是 state.player_syn。
	var syn: Dictionary = BattleSimulator._resolve_syn(att, state)
	var ls := SynergyService.safe_factor(syn, "god_lifesteal")
	_h.expect(int(syn.get("counts", {}).get("god", -1)) == 3, "god_count_not_3",
		"神来数 %s ≠ 3 —— 夹具没触发神3，本用例无效" % str(syn.get("counts", {}).get("god", -1)))
	_h.expect(absf(ls - 0.20) < 1e-6, "god_lifesteal_value_changed",
		"god_lifesteal=%s ≠ 0.20 —— 档位数值变了，本用例的期望值要跟着改" % str(ls))

	# 行为：神族普攻必须回血 = round(dealt × 20%)
	var r_god := _strike(state, "god_priestess")
	_h.expect(int(r_god["dealt"]) > 0, "god_dealt_zero",
		"神族这一下没打出伤害（dealt=0）—— 吸血无从谈起，用例无效")
	var want := maxi(1, int(round(float(r_god["dealt"]) * ls)))
	_h.expect(int(r_god["delta"]) == want, "god_lifesteal_amount_mismatch",
		"神族回血 %d ≠ 期望 %d（dealt=%d × %s）" % [r_god["delta"], want, r_god["dealt"], str(ls)])

	# 行为：非神族普攻**不许**回血  ← 本条修复的判据
	var r_ng := _strike(state, "undead_small")
	_h.expect(int(r_ng["dealt"]) > 0, "nongod_dealt_zero",
		"非神族这一下没打出伤害（dealt=0）—— 用例无效")
	_h.expect(int(r_ng["delta"]) == 0, "nongod_got_lifesteal",
		"非神族单位也吸到了血（+%d，dealt=%d）—— 神3 又没判种族" % [r_ng["delta"], r_ng["dealt"]])


# 打一下并读数：返回 {dealt, delta}。每次先把攻击者扣到半血，否则看不出回血。
func _strike(state: Dictionary, id: String) -> Dictionary:
	var att := _find(state, "player", id)
	if att.is_empty():
		return {"dealt": -1, "delta": 0}
	StatusEffectService.ensure_status(att)
	att.hp = int(int(att.get("max_hp", 0)) / 2)
	var before := int(att.get("hp", 0))
	var tgt := _first_alive(state, "enemy")
	if tgt.is_empty():
		return {"dealt": -1, "delta": 0}
	StatusEffectService.ensure_status(tgt)
	var dealt := BattleSimulator._perform_attack(att, tgt, state)
	return {"dealt": dealt, "delta": int(att.get("hp", 0)) - before}


# ---------- ② 自爆灵 ----------

func _bomb_state() -> Dictionary:
	return _mk([
		{"slot": 0, "cell": 0, "id": "undead_bomb", "star": 1},
		{"slot": 3, "cell": 0, "id": "undead_mother", "star": 1},
	])


# 把自爆灵贴到靶子身边并返回 {bomb, tgt, want}；取不到则返回空字典。
func _bomb_fixture(state: Dictionary, code_prefix: String) -> Dictionary:
	var bomb := _find(state, "player", "undead_bomb")
	var tgt := _first_alive(state, "enemy")
	if bomb.is_empty() or tgt.is_empty():
		_h.fail(code_prefix + "_fixture_missing", "构造不出自爆灵/靶子 —— 用例作废")
		return {}
	var vd: Dictionary = bomb.get("def", {})
	_h.expect(str(vd.get("skill_id", "")) == "death_poison_explosion", code_prefix + "_skill_id_missing",
		"自爆灵的 skill_id 不是 death_poison_explosion（实际 %s）—— 夹具变了" % str(vd.get("skill_id", "")))
	var want := maxi(1, int(round(float(bomb.get("atk", 0)) * float(vd.get("damage_atk_pct", 2.5)))))
	bomb.pos = tgt.pos + Vector2(40.0, 0.0)
	StatusEffectService.ensure_status(tgt)
	return {"bomb": bomb, "tgt": tgt, "want": want}


func _case_bomb_skill_kill() -> void:
	# ★ 这一条走的是**最凶的那条路径**：自爆灵是玩家最后一个阵亡的单位。
	#   step_state 里胜负判定 `p_alive.is_empty()` 会**直接 return**，tick 尾部
	#   那处清扫根本轮不到 —— 所以清扫必须在胜负判定之前先扫一遍（本轮一起修的）。
	var state := _bomb_state()
	var f := _bomb_fixture(state, "bomb_skill")
	if f.is_empty():
		return
	var bomb: Dictionary = f["bomb"]
	var tgt: Dictionary = f["tgt"]
	var hp0 := int(tgt.get("hp", 0))
	# 技能 / AOE 致死：只走 DamageService，**不**经普攻入口 `_on_unit_killed`
	DamageService.apply_damage(bomb, 999999, true, true)
	_h.expect(int(bomb.get("hp", 0)) <= 0 or not bool(bomb.get("alive", true)), "bomb_not_dead",
		"自爆灵没被打死 —— 用例无效")
	_h.expect(not bool(bomb.get("death_explosion_done", false)), "bomb_marked_before_sweep",
		"普攻入口被走到了 —— 本用例要验的正是「不经普攻入口」那条路")
	# ★ 必须走**真实入口**（推进一个 tick）。直接调 `_process_death_explosions` 只能
	#   证明函数本身写得对，证明不了「它真的被战斗跑到」。
	BattleSimulator.step_state(state)
	var lost := hp0 - int(tgt.get("hp", 0))
	_h.expect(lost == int(f["want"]), "bomb_skill_kill_no_explosion",
		"技能/AOE 打死自爆灵（且它是最后一只），敌人掉 %d 血（期望 %d）—— 自爆没触发" % [lost, int(f["want"])])
	_h.expect(StatusEffectService.has_status(tgt, "poison"), "bomb_skill_kill_no_poison",
		"技能/AOE 致死路径没给敌人上中毒")


func _case_bomb_dot_kill_tail_sweep() -> void:
	# ★ 专门隔离「tick **尾部**那处清扫」。
	#   在 step_state 之前手动杀死自爆灵是验不到尾部的 —— 胜负判定前那处清扫会抢先
	#   处理掉（本门禁第一版就是这么写的，M2 变异只红了结构断言、行为判据全绿）。
	#   要精确隔离，必须让它在**本 tick 进行中**死亡：用 DoT。
	#   毒发在 `_tick_statuses`（tick 中段），而胜负判定前那处清扫更早 —— 那时它还活着，
	#   所以本 tick 唯一能炸它的就是尾部那处。
	var state := _bomb_state_with_ally()
	var f := _bomb_fixture(state, "bomb_dot")
	if f.is_empty():
		return
	var bomb: Dictionary = f["bomb"]
	var tgt: Dictionary = f["tgt"]
	StatusEffectService.add_poison(bomb, 4.0, 5.0, 0.0, true)
	_h.expect(StatusEffectService.has_status(bomb, "poison"), "bomb_dot_not_applied",
		"毒没挂上 —— 用例无效")
	var hp0 := int(tgt.get("hp", 0))
	BattleSimulator.step_state(state)
	_h.expect(int(bomb.get("hp", 0)) <= 0 or not bool(bomb.get("alive", true)), "bomb_dot_not_dead",
		"自爆灵没被毒死（活着时本就不该炸）—— 用例无效")
	_h.expect(StatusEffectService.has_status(tgt, "poison"), "bomb_tail_sweep_missing",
		"本 tick 中途毒死的自爆灵没炸 —— tick 尾部那处清扫没生效")
	var lost := hp0 - int(tgt.get("hp", 0))
	_h.expect(lost >= int(f["want"]), "bomb_tail_sweep_damage_missing",
		"靶子掉血 %d < 爆炸伤害 %d —— 尾部清扫没补上爆炸" % [lost, int(f["want"])])


func _bomb_state_with_ally() -> Dictionary:
	# 队友站另一条 lane，避免它的普攻污染「靶子掉血量」这个读数；
	# 它的作用只是让 `p_alive` 非空 ⇒ 走正常的 tick 尾部清扫路径。
	return _mk([
		{"slot": 0, "cell": 0, "id": "undead_bomb", "star": 1},
		{"slot": 0, "cell": 3, "id": "undead_titan", "star": 4},
		{"slot": 3, "cell": 0, "id": "undead_mother", "star": 1},
	])


func _case_bomb_skill_kill_with_ally() -> void:
	# ★ 这一条走**正常路径**：自爆灵不是最后一只 ⇒ 战斗继续跑 ⇒ 由 tick 尾部的
	#   清扫补炸。两条路径都要有行为覆盖，否则「修了开头忘了尾部」看不出来。
	var state := _bomb_state_with_ally()
	var f := _bomb_fixture(state, "bomb_ally")
	if f.is_empty():
		return
	var bomb: Dictionary = f["bomb"]
	var tgt: Dictionary = f["tgt"]
	# ★ 前置体检：玩家必须**不止一只**存活单位，否则 step_state 会在
	#   `p_alive.is_empty()` 直接 return，本用例就退化成「最后一只」那条路径，
	#   tick 尾部那处清扫等于没被验到（两条路径覆盖成了假的）。
	var alive_before := 0
	for p in state.get("player", []):
		if p is Dictionary and bool(p.get("alive", false)):
			alive_before += 1
	_h.expect(alive_before >= 2, "bomb_ally_fixture_single_unit",
		"夹具里玩家只有 %d 只存活单位 —— 走的是「最后一只」路径，覆盖不到尾部清扫" % alive_before)
	var hp0 := int(tgt.get("hp", 0))
	DamageService.apply_damage(bomb, 999999, true, true)
	_h.expect(not bool(bomb.get("death_explosion_done", false)), "bomb_ally_marked_before_sweep",
		"普攻入口被走到了 —— 用例无效")
	BattleSimulator.step_state(state)
	_h.expect(not bool(state.get("finished", false)), "bomb_ally_battle_ended_early",
		"推进一个 tick 后战斗就结束了 —— 本用例没走到尾部清扫，覆盖无效")
	var lost := hp0 - int(tgt.get("hp", 0))
	# 队友在同一 tick 里可能也打到靶子 ⇒ 掉血量只做下界断言；
	# 「中毒」是自爆独有的签名（队友普攻与母灵技能都不挂毒），用它当特征判据。
	_h.expect(lost >= int(f["want"]), "bomb_ally_explosion_missing",
		"自爆灵（非最后一只）被技能打死，靶子只掉 %d 血（至少该有爆炸的 %d）" % [lost, int(f["want"])])
	_h.expect(StatusEffectService.has_status(tgt, "poison"), "bomb_ally_no_poison",
		"tick 尾部那条清扫没补上爆炸（靶子没中毒）")


func _case_bomb_attack_kill() -> void:
	var state := _bomb_state()
	var f := _bomb_fixture(state, "bomb_attack")
	if f.is_empty():
		return
	var bomb: Dictionary = f["bomb"]
	var tgt: Dictionary = f["tgt"]
	var hp0 := int(tgt.get("hp", 0))
	var killer := _first_alive(state, "enemy")
	# 普攻致死：走原入口
	BattleSimulator._on_unit_killed(killer, bomb, state, state.get("enemy", []), state.get("player", []))
	_h.expect(bool(bomb.get("death_explosion_done", false)), "bomb_attack_path_not_marked",
		"普攻致死后没落 death_explosion_done ⇒ per-tick 清扫会再炸一次")
	var lost := hp0 - int(tgt.get("hp", 0))
	_h.expect(lost == int(f["want"]), "bomb_attack_kill_broken",
		"普攻致死的即时爆炸被改坏了：掉 %d 血（期望 %d）" % [lost, int(f["want"])])


func _case_bomb_dedup() -> void:
	var state := _bomb_state()
	var f := _bomb_fixture(state, "bomb_dedup")
	if f.is_empty():
		return
	var bomb: Dictionary = f["bomb"]
	var tgt: Dictionary = f["tgt"]
	DamageService.apply_damage(bomb, 999999, true, true)
	BattleSimTreasures._process_death_explosions(state)
	var hp1 := int(tgt.get("hp", 0))
	BattleSimTreasures._process_death_explosions(state)
	var again := hp1 - int(tgt.get("hp", 0))
	_h.expect(again == 0, "bomb_exploded_twice",
		"同一具尸体炸了两回（第二次仍掉 %d 血）—— 两个调用点没去重" % again)


# ---------- 结构 ----------

func _case_structure() -> void:
	var sim := _strip_comments(_src(SIM_PATH))
	var tre := _strip_comments(_src(TREASURES_PATH))

	# ① 吸血那一行必须带种族判定（作用域限 `_perform_attack`）
	var atk_body := _fn_body(sim, "static func _perform_attack(")
	_h.expect(not atk_body.is_empty(), "attack_fn_not_found",
		"切不出 _perform_attack 的函数体 —— 结构断言失去作用域")
	var has_race := false
	var lines := atk_body.split("\n")
	for i in lines.size():
		if not lines[i].contains("god_lifesteal"):
			continue
		# 条件可能被折到下一行，取两行窗口
		var window := lines[i]
		if i + 1 < lines.size():
			window += "\n" + lines[i + 1]
		if window.contains("race"):
			has_race = true
	_h.expect(has_race, "god_lifesteal_no_race_check",
		"吸血那段条件里没有 race 判定 —— 非神族又会跟着吸")

	# ② per-tick 清扫必须挂在**两处**：
	#      · 胜负判定之前 —— 自爆灵是最后一个阵亡单位时，step_state 会在
	#        `p_alive.is_empty()` 直接 return，只有这一处能救
	#      · tick 尾部 —— 补本 tick 战斗中刚死的
	#    ★ 只写 `contains(...)` 会被「两处里还剩一处」骗过去（删掉一处照样为真）
	#      ⇒ 用**计数 + 位置**双重判据。
	var call_text := "BattleSimTreasures._process_death_explosions(state)"
	var call_count := sim.count(call_text)
	_h.expect(call_count >= 2, "sweep_call_sites_lt_2",
		"清扫调用点只有 %d 处（需要 2 处：胜负判定前兜底 + tick 尾部补）" % call_count)
	var i_win := sim.find("var p_alive := _alive(player)")
	var i_first := sim.find(call_text)
	_h.expect(i_win > 0, "win_check_anchor_missing",
		"找不到 `var p_alive := _alive(player)` —— 位置断言失去锚点")
	_h.expect(i_first > 0 and i_first < i_win, "sweep_after_win_check",
		"第一处清扫没排在胜负判定之前 —— 自爆灵是最后一只时永远不会炸")

	# ③ 爆炸本体的判据必须齐全（作用域限公共函数）
	var expl := _fn_body(tre, "static func apply_death_poison_explosion(")
	_h.expect(not expl.is_empty(), "explosion_fn_not_found",
		"找不到 apply_death_poison_explosion —— 两个调用点会各写一份判据")
	_h.expect(expl.contains("alive"), "explosion_no_alive_check",
		"爆炸没判目标存活")
	_h.expect(expl.contains("_can_target"), "explosion_no_can_target",
		"爆炸没走 _can_target（组队模式的分路门禁会失效）")
	_h.expect(expl.contains(str(EXPLOSION_RADIUS)), "explosion_radius_changed",
		"爆炸半径不是 %s —— 与门禁里声明的常量漂移" % str(EXPLOSION_RADIUS))
	_h.expect(expl.contains("add_poison"), "explosion_no_poison",
		"爆炸没给目标上中毒")

	# ④ 清扫自身的去重标记
	var sweep := _fn_body(tre, "static func _process_death_explosions(")
	_h.expect(not sweep.is_empty(), "sweep_fn_not_found",
		"找不到 _process_death_explosions")
	_h.expect(sweep.contains("death_explosion_done"), "sweep_no_mark",
		"清扫里没有 death_explosion_done 去重")
	_h.expect(sweep.contains("apply_death_poison_explosion"), "sweep_not_using_shared_fn",
		"清扫没走公共爆炸函数 —— 判据会漂成两份")

	# ⑥ 宝物入袋后必须重新对齐棋盘格子（第 3 条 bug：上阵光圈偏移）
	#    —— 单机与联机两条路径必须共用同一份收尾，不许各写一份（只修一条）。
	var flow := _strip_comments(_src(FLOW_PATH))
	var fin := _fn_body(flow, "func _finish_treasure_change(")
	_h.expect(not fin.is_empty(), "finish_treasure_change_missing",
		"找不到 _finish_treasure_change —— 宝物入袋收尾没共用同一份")
	_h.expect(fin.contains("_refresh_all"), "finish_treasure_no_refresh",
		"共享收尾里没调 _refresh_all")
	_h.expect(fin.contains("_queue_prep_model_layout_refresh"), "finish_treasure_no_realign",
		"共享收尾里没调 _queue_prep_model_layout_refresh —— 光圈偏移会复发")

	var pick := _fn_body(flow, "func _pick_treasure(")
	_h.expect(not pick.is_empty(), "pick_treasure_fn_not_found",
		"切不出 _pick_treasure 的函数体")
	_h.expect(pick.contains("_finish_treasure_change"), "local_pick_missing_realign",
		"单机选宝藏没走共享收尾 ⇒ 光圈偏移 bug 复发（用户实测：点赌博才恢复）")

	var granted := _fn_body(flow, "func _on_treasure_granted(")
	_h.expect(not granted.is_empty(), "granted_fn_not_found",
		"切不出 _on_treasure_granted 的函数体")
	_h.expect(granted.contains("_finish_treasure_change"), "online_grant_not_shared",
		"联机授权路径没走共享收尾 —— 两条路各写一份，迟早只修一条")

	# 赌博与黄金祭坛各自也有「面板内容变化 ⇒ 棋盘平移」，必须各自收尾。
	var gamble := _fn_body(flow, "func _on_generous_fate_gamble(")
	_h.expect(not gamble.is_empty(), "gamble_fn_not_found", "切不出 _on_generous_fate_gamble")
	_h.expect(gamble.contains("_queue_prep_model_layout_refresh"), "gamble_realign_missing",
		"赌博路径没重新对齐棋盘（它现在有，别在重构时弄丢）")

	var altar := _fn_body(flow, "func _on_altar_result(")
	_h.expect(not altar.is_empty(), "altar_fn_not_found", "切不出 _on_altar_result")
	_h.expect(altar.contains("_queue_prep_model_layout_refresh"), "altar_realign_missing",
		"黄金祭坛路径没重新对齐棋盘（它的按钮文案同样会挤动棋盘）")

	# ⑦ 普攻入口走同一份判据 + 落标记
	var killed := _fn_body(sim, "static func _on_unit_killed(")
	_h.expect(not killed.is_empty(), "on_killed_fn_not_found",
		"切不出 _on_unit_killed 的函数体")
	_h.expect(killed.contains("apply_death_poison_explosion"), "attack_path_not_using_shared_fn",
		"普攻致死入口没走公共爆炸函数")
	_h.expect(killed.contains("death_explosion_done"), "attack_path_no_mark",
		"普攻致死入口没落 death_explosion_done")


# ---------- 小工具 ----------

func _src(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# 剥掉整行注释与行尾注释再做文本断言：
# 不剥注释的 contains 会被**自己的注释**满足（"写了注释就算通过"）。
func _strip_comments(text: String) -> String:
	var out: Array[String] = []
	for line in text.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		var cut := line.find("#")
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)


# 切出某个函数体。★ 只按 `\nfunc ` 切会一路吃到后面 —— 本仓 `static func` 遍地，
# 必须**同时**按 `\nfunc ` / `\nstatic func ` / `\n# ---` 三个锚点各切一次取最短。
func _fn_body(src: String, anchor: String) -> String:
	var i := src.find(anchor)
	if i < 0:
		return ""
	var rest := src.substr(i)
	var best := rest
	for a in ["\nfunc ", "\nstatic func ", "\n# ---"]:
		var j := rest.find(a, anchor.length())
		if j > 0 and j < best.length():
			best = rest.substr(0, j)
	return best
