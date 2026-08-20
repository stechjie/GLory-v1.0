extends Node

# 守「买了再卖不可能赚钱」。
#
# 服务端账本早就修过这条：`EconomyLedger.sell_refund()` 按 **cost_basis**
# （你实际花了多少）退一半，文件里那段注释还专门解释了为什么 ——
# 旧规则按**定价表**退，折扣买入、原价退款就能刷钱。
# `adversarial_client` 里也有一条 `no_arbitrage_profit` 守着它。
#
# 但客户端**还是旧规则**，而且今天跑的就是客户端那份
# （账本锁在默认关闭的 economy_ledger_* 开关后面，request_economy 零调用点）：
#
#   PrepBoardController._sell_refund_for_cell()
#       floor(def.cost * star * 0.5)
#
# 两个问题叠在一起：
#   1. 按 `def.cost` 退，无视买入时的折扣宝物
#   2. 按 `def.cost` 退，**连 `shop_cost_multiplier` 都无视** ——
#      而 undead_small 的 cost 字段是 10、乘数 0.5，实际售价 5，
#      退款公式那个 ×0.5 正好把乘数抵消掉，变成 **100% 全额退款**
#
# 这条检查断言的是那条不变量本身，不绑定具体公式：
# **退款 <= floor(取得这个单位实际花掉的钱 * 0.5)**。
# 不管以后改成按 cost_basis 退还是别的算法，这条都得成立。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/sell_refund_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "sell_refund"
const REFUND_RATE := 0.5

var _h: CheckHarness
var _prep: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	_prep = packed.instantiate()
	add_child(_prep)
	await get_tree().process_frame

	_case_no_arbitrage()
	_case_matches_server_rule()

	_h.finish(get_tree())


func _set_owned(ids: Array) -> void:
	GameState.owned_treasures.clear()
	for id in ids:
		GameState.owned_treasures.append(str(id))


func _clearance_requires() -> Array:
	for row in DataRegistry.get_table("treasures").get("linkages", []):
		if str((row as Dictionary).get("id", "")) == "link_clearance_sale":
			return (row as Dictionary).get("requires", [])
	return []


# 造出 star 星需要的一星份数：2 星要 2 个，3 星要 2*3 = 6 个。
func _copies_for_star(star: int) -> int:
	var n := 1
	for s in range(1, star):
		n *= GameState.copies_to_upgrade(s)
	return n


# 硬不变量：卖出退款**必须严格小于**取得成本。
# 等于成本也不行 —— 那意味着可以零成本反复换阵容，退款率名义上是 50%。
func _case_no_arbitrage() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "units_empty", "race_units 表为空"):
		return
	var owned_cases: Array = [[], ["money_discount"]]
	var clearance := _clearance_requires()
	if not clearance.is_empty():
		owned_cases.append(clearance)
	else:
		_h.fail("clearance_linkage_missing", "treasures 表里找不到 link_clearance_sale")

	for owned in owned_cases:
		_set_owned(owned as Array)
		for row in units:
			var d: Dictionary = row
			var unit_price := int(_prep.call("_shop_unit_cost", d))
			for star in [1, 2, 3]:
				var paid := unit_price * _copies_for_star(star)
				var cell := {"id": str(d.get("id", "")), "star": star, "def": d}
				var refund := int(_prep.call("_sell_refund_for_cell", cell))
				if refund > paid:
					_h.fail("sell_for_profit",
						"%s %d星（持有 %s）：花 %d 退 %d —— 买了再卖净赚 %d 金" % [
							str(d.get("id", "?")), star, str(owned), paid, refund, refund - paid])
				elif refund == paid:
					_h.fail("sell_free_reroll",
						"%s %d星（持有 %s）：花 %d 退 %d —— 全额退款，可零成本反复换阵容" % [
							str(d.get("id", "?")), star, str(owned), paid, refund])
				else:
					_h.item()
	_set_owned([])


# 客户端退款必须等于服务端账本对同一笔实付给出的退款（floor(实付 * 0.5)）。
# 这条比上面那条严 —— 上面只要求不亏本，这条要求**退款率就是设计的 50%**。
func _case_matches_server_rule() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var owned_cases: Array = [[], ["money_discount"]]
	var clearance := _clearance_requires()
	if not clearance.is_empty():
		owned_cases.append(clearance)
	var diff := 0
	var total := 0
	for owned in owned_cases:
		_set_owned(owned as Array)
		for row in units:
			var d: Dictionary = row
			var paid := int(_prep.call("_shop_unit_cost", d))
			var cell := {"id": str(d.get("id", "")), "star": 1, "def": d}
			var client := int(_prep.call("_sell_refund_for_cell", cell))
			var server := int(EconomyLedger.sell_refund(paid))
			total += 1
			if client != server:
				diff += 1
			_h.expect(client == server, "refund_mismatch",
				"%s（持有 %s）：实付 %d，客户端退 %d、服务端账本退 %d" % [
					str(d.get("id", "?")), str(owned), paid, client, server])
	_set_owned([])
	print("[%s] 客户端与服务端退款不一致：%d/%d 组" % [CHECK_NAME, diff, total])
