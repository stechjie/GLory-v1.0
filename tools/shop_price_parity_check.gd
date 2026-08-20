extends Node

# 守「客户端显示的价格」与「服务端实际扣的价格」一致。
#
# 起因：`PrepBoardController._shop_unit_cost()` 原本有一份与
# `EconomyLedger.unit_cost()` **逐行相同**的定价公式 —— 基础价 →
# `shop_cost_multiplier` → `link_clearance_sale` ×0.6 / `money_discount` ×0.8
# （两者互斥、不叠加），每步都 `maxi(1, ceil(...))`。
#
# 同一套算钱逻辑存两份，改一处忘另一处的后果是：**客户端显示一个价、
# 服务端扣另一个价**，而且不会有任何报错 —— 玩家只会觉得"钱怎么不对"。
# 已经把客户端改成委托服务端那份（服务端是权威裁决方）。
#
# 本检查做两件事：
#   1. 逐个真实单位 × 各种宝物组合，断言两边报价相同
#   2. 把定价规则本身钉住（倍率、折扣互斥、下限 1、向上取整）
# 第 1 条守的是"以后有人又把客户端改回自己算"。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/shop_price_parity_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "shop_price_parity"

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

	_case_parity_over_real_units()
	_case_rule_multiplier()
	_case_rule_discount_exclusive()
	_case_rule_floor_and_ceil()

	_h.finish(get_tree())


func _client_cost(unit_def: Dictionary) -> int:
	return int(_prep.call("_shop_unit_cost", unit_def))


func _set_owned(ids: Array) -> void:
	GameState.owned_treasures.clear()
	for id in ids:
		GameState.owned_treasures.append(str(id))


# 逐个真实单位 × 三种持有状态，客户端与服务端报价必须一致。
func _case_parity_over_real_units() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "units_empty", "race_units 表为空，检查集为空不算通过"):
		return
	var owned_cases := [
		[],
		["money_discount"],
		["atk_fury_roster", "money_discount"],   # 折扣券 + 无关宝物
	]
	var compared := 0
	for owned in owned_cases:
		_set_owned(owned as Array)
		for row in units:
			var d: Dictionary = row
			var client := _client_cost(d)
			var server := int(EconomyLedger.unit_cost(d, GameState.owned_treasures))
			_h.expect(client == server, "price_mismatch",
				"单位 %s（持有 %s）：客户端 %d vs 服务端 %d —— 显示价与实扣价不一致" % [
					str(d.get("id", "?")), str(owned), client, server])
			compared += 1
	_set_owned([])
	print("[%s] 比对 %d 组（单位 × 持有状态）" % [CHECK_NAME, compared])


func _case_rule_multiplier() -> void:
	_set_owned([])
	# cost 10 × 0.5 = 5
	_h.expect(_client_cost({"cost": 10, "shop_cost_multiplier": 0.5}) == 5,
		"multiplier_wrong", "shop_cost_multiplier 0.5 未生效")
	# 向上取整：10 × 0.55 = 5.5 -> 6
	_h.expect(_client_cost({"cost": 10, "shop_cost_multiplier": 0.55}) == 6,
		"multiplier_not_ceil", "倍率结果应向上取整（5.5 -> 6）")


# 联动与折扣券**互斥**（elif），不叠加。
# 写成两个 if 的话 clearance + discount 会变成 ×0.48，等于凭空多一档折扣。
func _case_rule_discount_exclusive() -> void:
	var d := {"cost": 100}
	_set_owned([])
	var base := _client_cost(d)
	_set_owned(["money_discount"])
	var discounted := _client_cost(d)
	_h.expect(discounted == 80, "discount_wrong",
		"money_discount 应为 ×0.8（100 -> 80），实际 %d" % discounted)
	# 凑齐 clearance 联动所需的宝物后应变成 ×0.6，且**不与 ×0.8 叠加**
	var link_rows: Array = DataRegistry.get_table("treasures").get("linkages", [])
	var requires: Array = []
	for row in link_rows:
		if str((row as Dictionary).get("id", "")) == "link_clearance_sale":
			requires = (row as Dictionary).get("requires", [])
			break
	if requires.is_empty():
		_h.fail("clearance_linkage_missing", "treasures 表里找不到 link_clearance_sale 的 requires")
		_set_owned([])
		return
	var with_link: Array = requires.duplicate()
	with_link.append("money_discount")
	_set_owned(with_link)
	var linked := _client_cost(d)
	_h.expect(linked == 60, "clearance_wrong_or_stacked",
		"clearance 联动应为 ×0.6（100 -> 60），实际 %d；若为 48 说明与 money_discount 叠加了" % linked)
	_h.expect(base == 100, "base_changed", "无宝物时不该有折扣")
	_set_owned([])


# 价格下限为 1：再多折扣也不能白送或变成 0/负数。
func _case_rule_floor_and_ceil() -> void:
	_set_owned(["money_discount"])
	_h.expect(_client_cost({"cost": 1}) == 1, "floor_broken",
		"1 金单位打折后仍应为 1，不能变成 0")
	_h.expect(_client_cost({"cost": 1, "shop_cost_multiplier": 0.01}) == 1,
		"floor_broken_multiplier", "极低倍率下仍应为 1")
	_set_owned([])
	# 缺 cost 字段时默认 1
	_h.expect(_client_cost({}) == 1, "missing_cost_default", "缺 cost 字段应默认 1")
