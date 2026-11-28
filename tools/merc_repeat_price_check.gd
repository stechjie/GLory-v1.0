extends Node

# 11.28 同种佣兵加价（用户定）：前 3 只原价，第 4 只 +50% 萝卜、第 5 只 +100%，以此类推。
# 规则只有一份（CarrotEconomy.merc_hire_cost）；这里钉规则本身、服务器账本、单机判定、电脑对手四处。

const Harness := preload("res://tools/CheckHarness.gd")
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const Ledger := preload("res://scripts/multiplayer/EconomyLedger.gd")
const PrepRules := preload("res://scenes/prep/PrepRules.gd")
const BotCarrots := preload("res://scripts/economy/ai/BotCarrots.gd")

const MERC_ID := "merc_sagittarius_rain"  # 星轨猎人，原价 24


func _ready() -> void:
	var h := Harness.new("merc_repeat_price")
	DataRegistry.load_all()
	var merc: Dictionary = {}
	for row: Dictionary in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		if str(row.get("id", "")) == MERC_ID:
			merc = row
	var base := int(merc.get("carrot_cost", -1))
	h.expect(base == 24, "base_price", "星轨猎人原价应为 24，实际 %d" % base)

	# 规则：已有 0～7 只时，下一只的价格。
	var expected := [24, 24, 24, 36, 48, 60, 72, 84]
	var pcts := [0, 0, 0, 50, 100, 150, 200, 250]
	for owned in 8:
		h.expect(CarrotEconomy.merc_hire_cost(base, owned) == int(expected[owned]), "rule_price",
			"已有 %d 只时应为 %d，实际 %d" % [owned, int(expected[owned]), CarrotEconomy.merc_hire_cost(base, owned)])
		h.expect(CarrotEconomy.merc_hire_surcharge_pct(owned) == int(pcts[owned]), "rule_pct",
			"已有 %d 只时加价应为 +%d%%" % [owned, int(pcts[owned])])
	h.expect(CarrotEconomy.merc_hire_cost(3, 3) == 5, "rule_round_up", "3 萝卜的第 4 只 = 4.5 向上取整 5，实际 %d" % CarrotEconomy.merc_hire_cost(3, 3))
	h.expect(CarrotEconomy.merc_hire_cost(-1, 5) == -1, "rule_missing_cost", "没填价格的原样返回 -1")

	# 服务器账本：连叫 5 只，按 24 / 24 / 24 / 36 / 48 扣；别的佣兵不受影响。
	var ctx := {"merc_cap": 8, "merc_table": DataRegistry.get_table("mercenaries").get("mercenaries", [])}
	var prep := {"carrots": 1000, "roster": {}, "next_uid": 1, "merc_carrots_spent_total": 0}
	var paid: Array = []
	for slot in 5:
		var out: Dictionary = Ledger._hire_merc_carrot(prep, {"merc_id": MERC_ID, "merc_slot": slot}, ctx)
		paid.append(int((out.get("result", {}) as Dictionary).get("carrot_cost", -1)) if bool(out.get("ok", false)) else -1)
	h.expect(paid == [24, 24, 24, 36, 48], "ledger_prices", "账本连叫 5 只应扣 24/24/24/36/48，实际 %s" % str(paid))
	h.expect(int(prep.carrots) == 1000 - 156 and int(prep.merc_carrots_spent_total) == 156, "ledger_totals",
		"账本余额 / 累计花费应为 844 / 156，实际 %d / %d" % [int(prep.carrots), int(prep.merc_carrots_spent_total)])
	var other: Dictionary = Ledger._hire_merc_carrot(prep, {"merc_id": "merc_pisces_bubble", "merc_slot": 5}, ctx)
	h.expect(int((other.get("result", {}) as Dictionary).get("carrot_cost", -1)) == 3, "ledger_other_merc", "别的佣兵仍是原价 3")
	# 萝卜只够原价、不够加价后的价格时要被拒。
	var poor := {"carrots": 30, "roster": {}, "next_uid": 1, "merc_carrots_spent_total": 0}
	for i in 3:
		(poor.roster as Dictionary)["u%d" % i] = {"unit_id": MERC_ID, "star": 1, "cost_basis": 0, "kind": "merc", "merc_slot": i}
	var refused: Dictionary = Ledger._hire_merc_carrot(poor, {"merc_id": MERC_ID, "merc_slot": 3}, ctx)
	h.expect(not bool(refused.get("ok", true)) and str(refused.get("error", "")) == "not_enough_carrots" and int(poor.carrots) == 30,
		"ledger_refuses_underpay", "第 4 只要 36，手上 30 应拒绝且不扣萝卜：%s" % str(refused))

	# 单机 / 卡面：读自己佣兵席上的同种数量。
	var saved_slots: Array = GameState.mercenary_slots.duplicate(true)
	var saved_carrots := int(GameState.carrots)
	for i in GameState.mercenary_slots.size():
		GameState.mercenary_slots[i] = null
	h.expect(PrepRules.mercenary_hire_cost(merc) == 24 and PrepRules.mercenary_hire_surcharge_pct(merc) == 0, "client_price_empty", "空席时卡面价 24、不加价")
	for i in 3:
		GameState.mercenary_slots[i] = {"id": MERC_ID, "uid": "t%d" % i, "star": 1, "def": merc, "is_mercenary": true}
	GameState.mercenary_slots[3] = {"id": "merc_pisces_bubble", "uid": "t3", "star": 1, "def": {}, "is_mercenary": true}
	h.expect(PrepRules.mercenary_hire_cost(merc) == 36 and PrepRules.mercenary_hire_surcharge_pct(merc) == 50, "client_price_fourth",
		"已有 3 只时卡面价应为 36（+50%%），实际 %d" % PrepRules.mercenary_hire_cost(merc))
	GameState.mercenary_slots[4] = {"id": MERC_ID, "uid": "t4", "star": 1, "def": merc, "is_mercenary": true}
	h.expect(PrepRules.mercenary_hire_cost(merc) == 48 and PrepRules.mercenary_hire_surcharge_pct(merc) == 100, "client_price_fifth", "已有 4 只时卡面价应为 48（+100%）")
	GameState.mercenary_slots = saved_slots
	GameState.carrots = saved_carrots

	# 电脑对手：和真人同价。
	var bot := {"carrots": 1000, "carrot_spent": 0, "mercs": []}
	for i in 5:
		BotCarrots._hire(bot, merc)
	h.expect((bot.mercs as Array).size() == 5 and int(bot.carrot_spent) == 156, "bot_prices",
		"电脑对手连叫 5 只应花 156，实际 %d 只 / %d" % [(bot.mercs as Array).size(), int(bot.carrot_spent)])
	h.finish(get_tree())
