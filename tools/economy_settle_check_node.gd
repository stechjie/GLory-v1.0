extends Node

# 临时校验：EconomyService.settle_post_battle_gold 的结算数值必须与
# docs/金币系统.md 的公式与示例表一致。验证通过后此文件可删除。
# 金额已整体进位一位（旧值 ×10），期望值同步更新。

func _ready() -> void:
	var failures := 0

	# --- PVE：总奖励 = 击杀金币 + (floor(已完成PVE次数/2)+1 档) × 10，失败 0 ---
	# 100 + (击杀30 + 首胜10) = 140，利息 floor(140*0.1)=14 → 154
	failures += _check("PVE胜/首次", {
		"gold_before": 100, "kill_gold": 30, "kind": "pve", "player_wins": true,
		"pve_completed_before": 0,
	}, 154)
	# 已完成4次 → 固定奖励 (floor(4/2)+1)×10 = 30；100 + 30 + 30 = 160，利息 16 → 176
	failures += _check("PVE胜/已完成4次", {
		"gold_before": 100, "kill_gold": 30, "kind": "pve", "player_wins": true,
		"pve_completed_before": 4,
	}, 176)
	# PVE 失败：一分不给（击杀金币也不给），只有利息 floor(100*0.1)=10 → 110
	failures += _check("PVE败/无奖励", {
		"gold_before": 100, "kill_gold": 50, "kind": "pve", "player_wins": false,
		"loss_streak_after": 0,
	}, 110)

	# --- PVP：总奖励 = 击杀金币 + 胜负固定奖励（胜+100/负+50），击杀金币胜败都给 ---
	# 200 + 50 + 100 = 350，利息 35 → 385
	failures += _check("PVP胜", {
		"gold_before": 200, "kill_gold": 50, "kind": "pvp", "player_wins": true,
	}, 385)
	# 200 + 50 + 50 = 300，连败3 安慰金 3*20=60 → 360，利息 36 → 396
	failures += _check("PVP败/连败3", {
		"gold_before": 200, "kill_gold": 50, "kind": "pvp", "player_wins": false,
		"loss_streak_after": 3,
	}, 396)

	# --- Boss：只给固定奖励/补偿，不结算击杀金币 ---
	# 回合10 胜利 150：100 + 150 = 250，利息 25 → 275
	failures += _check("Boss胜/回合10", {
		"gold_before": 100, "kind": "boss", "player_wins": true, "round_index": 10,
	}, 275)
	# 击杀金币在 Boss 局必须被忽略：回合5 胜利100 → 0 + 100 = 100，利息 10 → 110
	failures += _check("Boss胜/忽略击杀金币", {
		"gold_before": 0, "kill_gold": 1000, "kind": "boss", "player_wins": true,
		"round_index": 5,
	}, 110)
	# 文档示例：回合10 胜利150，打掉60%（剩40%）→ 补偿 150-floor(150*0.4)=90
	# 100 + 90 = 190，利息 19 → 209
	failures += _check("Boss败/回合10打掉60%", {
		"gold_before": 100, "kind": "boss", "player_wins": false, "round_index": 10,
		"boss_hp_current": 40, "boss_hp_max": 100, "loss_streak_after": 0,
	}, 209)
	# 文档示例：回合20 胜利400，打掉75%（剩25%）→ 补偿 400-floor(400*0.25)=300
	# 0 + 300 = 300，利息 30 → 330
	failures += _check("Boss败/回合20打掉75%", {
		"gold_before": 0, "kind": "boss", "player_wins": false, "round_index": 20,
		"boss_hp_current": 25, "boss_hp_max": 100, "loss_streak_after": 0,
	}, 330)

	# --- 商人战后金币（★1→10 / ★2→20 / ★3→30）---
	# PVE胜：0 + (0 + 10) + 商人30 = 40，利息 floor(40*0.1)=4 → 44
	failures += _check("商人金币到账", {
		"gold_before": 0, "kind": "pve", "player_wins": true,
		"pve_completed_before": 0, "merchant_gold": 30,
	}, 44)

	# --- 复利之道：利息额外 +5% ---
	# 1000 + 100 = 1100，利息 floor(1100*0.1)=110 + floor(1100*0.05)=55 → 1265
	failures += _check("复利之道", {
		"gold_before": 1000, "kind": "pvp", "player_wins": true,
		"treasures": ["money_compound"],
	}, 1265)

	# --- 安慰金随连败递增（每场 20 金）---
	for streak: int in [1, 2, 3, 4]:
		# 0 + PVE败 = 0，安慰金 streak*20，利息 floor(streak*20*0.1)
		var expected: int = streak * 20
		expected += int(floor(float(expected) * 0.10))
		failures += _check("安慰金/连败%d" % streak, {
			"gold_before": 0, "kind": "pve", "player_wins": false,
			"loss_streak_after": streak,
		}, expected)

	# --- 单项公式：进位后的基数 ---
	failures += _check_int("开局金币", GameState.START_GOLD, 100)
	failures += _check_int("PVE胜/档位0", EconomyService.pve_kill_reward(0), 10)
	failures += _check_int("PVE胜/档位4", EconomyService.pve_kill_reward(4), 30)
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

	# --- 宝藏刷新：50 起，40x 档位后无上限翻倍 ---
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
	failures += _check_int("按座位取击杀金币/无此座位", EconomyService.kill_gold_for_slot(
		{"kill_gold_by_slot": {0: 90}}, 3), 0)

	# --- 数据表的 cost 也必须整体进位 ---
	failures += _check_data_costs()

	print("[ECONCHECK] failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)


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
