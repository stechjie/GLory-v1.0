extends Node

# 临时校验：EconomyService.settle_post_battle_gold 的结算数值必须与
# docs/金币系统.md 的公式与示例表一致。验证通过后此文件可删除。
# 金额已整体进位一位（旧值 ×10）。

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")

func _ready() -> void:
	var failures := 0

	# --- PVE：击杀金输赢都给（每只固定 15），回合奖励（回合号×10）仅胜利 ---
	# 胜：100 + 击杀60 + 回合2×10=20 → 180，利息 9 → 189
	failures += _check("PVE胜/第2回合杀4只", {
		"gold_before": 100, "kill_gold": 60, "kind": "pve", "player_wins": true,
		"round_index": 2,
	}, 189)
	# 败：击杀金照给，回合奖励没有。100 + 60 = 160，利息 8 → 168
	failures += _check("PVE败/击杀金照给", {
		"gold_before": 100, "kill_gold": 60, "kind": "pve", "player_wins": false,
		"round_index": 2, "loss_streak_after": 0,
	}, 168)
	# 回合奖励只看回合号，与 PVE 场次无关：第19回合胜 → 0 + 击杀225 + 190 = 415，利息20 → 435
	failures += _check("PVE胜/第19回合", {
		"gold_before": 0, "kill_gold": 225, "kind": "pve", "player_wins": true,
		"round_index": 19,
	}, 435)
	# 一只没杀又输了：只剩利息
	failures += _check("PVE败/零击杀", {
		"gold_before": 100, "kill_gold": 0, "kind": "pve", "player_wins": false,
		"round_index": 7, "loss_streak_after": 0,
	}, 105)

	# --- PVP：总奖励 = 击杀金币 + 胜负固定奖励（胜+100/负+50），击杀金币胜败都给 ---
	failures += _check("PVP胜", {
		"gold_before": 200, "kill_gold": 50, "kind": "pvp", "player_wins": true,
	}, 367)
	# 200 + 50 + 50 = 300，连败3 安慰金 3*20=60 → 360，利息 18 → 378
	failures += _check("PVP败/连败3", {
		"gold_before": 200, "kill_gold": 50, "kind": "pvp", "player_wins": false,
		"loss_streak_after": 3,
	}, 378)

	# --- Boss：只给固定奖励/补偿，不结算击杀金币 ---
	failures += _check("Boss胜/回合10", {
		"gold_before": 100, "kind": "boss", "player_wins": true, "round_index": 10,
	}, 262)
	failures += _check("Boss胜/忽略击杀金币", {
		"gold_before": 0, "kill_gold": 1000, "kind": "boss", "player_wins": true,
		"round_index": 5,
	}, 105)
	# 文档示例：回合10 胜利150，打掉60%（剩40%）→ 补偿 150-floor(150*0.4)=90
	failures += _check("Boss败/回合10打掉60%", {
		"gold_before": 100, "kind": "boss", "player_wins": false, "round_index": 10,
		"boss_hp_current": 40, "boss_hp_max": 100, "loss_streak_after": 0,
	}, 199)
	# 文档示例：回合20 胜利400，打掉75%（剩25%）→ 补偿 400-floor(400*0.25)=300
	failures += _check("Boss败/回合20打掉75%", {
		"gold_before": 0, "kind": "boss", "player_wins": false, "round_index": 20,
		"boss_hp_current": 25, "boss_hp_max": 100, "loss_streak_after": 0,
	}, 315)

	# --- 商人战后金币（★1→10 / ★2→20 / ★3→30）---
	# PVE胜：0 + 击杀0 + 回合1×10 + 商人30 = 40，利息 2 → 42
	failures += _check("商人金币到账", {
		"gold_before": 0, "kind": "pve", "player_wins": true, "round_index": 1,
		"merchant_gold": 30,
	}, 42)

	# --- 复利之道：利息额外 +5% ---
	failures += _check("复利之道", {
		"gold_before": 1000, "kind": "pvp", "player_wins": true,
		"treasures": ["money_compound"],
	}, 1210)

	# --- 安慰金随连败递增（每场 20 金）---
	for streak: int in [1, 2, 3, 4]:
		var expected: int = streak * 20
		expected += int(floor(float(expected) * 0.05))
		failures += _check("安慰金/连败%d" % streak, {
			"gold_before": 0, "kind": "pve", "player_wins": false,
			"round_index": 1, "loss_streak_after": streak,
		}, expected)

	# --- 单项公式 ---
	failures += _check_int("开局金币", GameState.START_GOLD, 100)
	failures += _check_int("PVE小怪单价", EconomyService.PVE_MONSTER_KILL_GOLD, 15)
	failures += _check_int("PVE回合奖励/第1回合", EconomyService.pve_win_bonus(1), 10)
	failures += _check_int("PVE回合奖励/第19回合", EconomyService.pve_win_bonus(19), 190)
	failures += _check_int("击杀/tier1★1", EconomyService.pvp_normal_kill_reward(1, 1), 10)
	failures += _check_int("击杀/tier1★2", EconomyService.pvp_normal_kill_reward(1, 2), 30)
	failures += _check_int("击杀/tier1★3", EconomyService.pvp_normal_kill_reward(1, 3), 40)
	failures += _check_int("击杀/tier3★3", EconomyService.pvp_normal_kill_reward(3, 3), 60)
	failures += _check_int("击杀佣兵/50费", EconomyService.pvp_mercenary_kill_reward(50), 10)
	failures += _check_int("击杀佣兵/600费", EconomyService.pvp_mercenary_kill_reward(600), 120)
	failures += _check_int("胜负奖励/胜", EconomyService.pvp_result_bonus(true), 100)
	failures += _check_int("胜负奖励/负", EconomyService.pvp_result_bonus(false), 50)

	# --- 商店刷新：首次免费，之后 10 起翻倍 ---
	var shop_expected := [0, 10, 20, 40, 80, 160, 320]
	for i in shop_expected.size():
		failures += _check_int("商店刷新/第%d次" % (i + 1),
			EconomyService.shop_refresh_cost(i, false), int(shop_expected[i]))
	failures += _check_int("商店刷新/金钱套装免费", EconomyService.shop_refresh_cost(5, true), 0)

	# --- 宝藏刷新：50 起，无上限翻倍 ---
	var treasure_expected := [50, 100, 200, 400, 800, 1600]
	for i in treasure_expected.size():
		failures += _check_int("宝藏刷新/第%d次" % (i + 1),
			TreasureService.refresh_cost(i, false), int(treasure_expected[i]))

	# --- 辅助函数 ---
	failures += _check_int("商人棋盘统计", EconomyService.merchant_gold_from_board([
		null,
		{"star": 2, "def": {"skill_id": "post_battle_gold_by_star"}},
		{"star": 3, "def": {"skill_id": "post_battle_gold_by_star"}},
		{"star": 3, "def": {"skill_id": "blood_rampage"}},
	]), 50)
	failures += _check_int("按座位取击杀金币", EconomyService.kill_gold_for_slot(
		{"kill_gold_by_slot": {4: 70}}, 4), 70)
	failures += _check_int("按座位取击杀金币/字符串键", EconomyService.kill_gold_for_slot(
		{"kill_gold_by_slot": {"4": 70}}, 4), 70)

	failures += _check_kill_split()
	failures += _check_data_costs()

	print("[ECONCHECK] failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)


# 跨路击杀分账：同路全额归击杀者；跨路对半分，余数归击杀者。
# 小怪单价 15 是奇数 → 8/7。
func _check_kill_split() -> int:
	var bad := 0
	var victim := {"def": {}, "star": 1, "lane": 2}
	var killer_same := {"owner_slot": 2, "lane": 2}
	var killer_cross := {"owner_slot": 0, "lane": 0}

	# 同路：15 全给击杀者（座位2）
	var s1 := _pve_state()
	BattleSim._add_kill_reward(s1, killer_same, victim, true)
	bad += _check_int("同路击杀/全额归击杀者", int(s1.kill_gold_by_slot.get(2, 0)), 15)
	bad += _check_int("同路击杀/无第三方分账", s1.kill_gold_by_slot.size(), 1)

	# 跨路：座位0 的棋子杀 lane2 的怪 → 击杀者 8、路线主(座位2) 7
	var s2 := _pve_state()
	BattleSim._add_kill_reward(s2, killer_cross, victim, true)
	bad += _check_int("跨路击杀/击杀者拿一半+余数", int(s2.kill_gold_by_slot.get(0, 0)), 8)
	bad += _check_int("跨路击杀/路线主拿一半", int(s2.kill_gold_by_slot.get(2, 0)), 7)

	# 队伍总额不变：分账只改分配
	var total := int(s2.kill_gold_by_slot.get(0, 0)) + int(s2.kill_gold_by_slot.get(2, 0))
	bad += _check_int("跨路击杀/总额不变", total, 15)

	# 敌方队伍杀我方棋子 → 用 rival_slots 找路线主（座位5）
	var s3 := _pve_state()
	var enemy_victim := {"def": {"tier": 1}, "star": 1, "lane": 2}
	var enemy_killer := {"owner_slot": 3, "lane": 0}
	BattleSim._add_kill_reward(s3, enemy_killer, enemy_victim, false)
	bad += _check_int("敌方跨路击杀/用rival_slots", int(s3.kill_gold_by_slot.get(5, 0)), 7)

	# 1v1（无 lane、无映射）：不分账
	var s4 := {"kind": "pve", "log": [], "kill_gold_by_slot": {}}
	BattleSim._add_kill_reward(s4, {"owner_slot": 0, "lane": -1}, {"def": {}, "star": 1, "lane": -1}, true)
	bad += _check_int("1v1无lane/不分账", int(s4.kill_gold_by_slot.get(0, 0)), 15)
	return bad


func _pve_state() -> Dictionary:
	return {
		"kind": "pve", "log": [], "kill_gold_by_slot": {},
		"ally_slots": [0, 1, 2], "rival_slots": [3, 4, 5],
	}


# 棋子 cost 应为 10/20/30/50；佣兵 cost 应为 50~600 且都是 50 的倍数。
func _check_data_costs() -> int:
	var bad := 0
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for u in units:
		var cost := int((u as Dictionary).get("cost", 0))
		if not (cost in [10, 20, 30, 50]):
			printerr("[ECONCHECK] FAIL 棋子 %s cost=%d 未进位" % [str((u as Dictionary).get("id", "?")), cost])
			bad += 1
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	for m in mercs:
		var cost := int((m as Dictionary).get("cost", 0))
		if cost < 50 or cost > 600 or cost % 50 != 0:
			printerr("[ECONCHECK] FAIL 佣兵 %s cost=%d 未进位" % [str((m as Dictionary).get("id", "?")), cost])
			bad += 1
	if bad == 0:
		print("[ECONCHECK] OK   数据表 cost 全部已进位 (棋子%d个 / 佣兵%d个)" % [units.size(), mercs.size()])
	return bad


func _check(label: String, ctx: Dictionary, expected: int) -> int:
	var got := EconomyService.settle_post_battle_gold(ctx)
	return _check_int(label, got, expected)


func _check_int(label: String, got: int, expected: int) -> int:
	if got == expected:
		print("[ECONCHECK] OK   %s -> %d" % [label, got])
		return 0
	printerr("[ECONCHECK] FAIL %s -> got %d, expected %d" % [label, got, expected])
	return 1
