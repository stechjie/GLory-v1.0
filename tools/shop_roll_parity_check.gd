extends Node

# 守「客户端商店」与「服务端商店」摇的是同一条档位曲线。
#
# 起因：服务端 `_server_roll_shop_offers()` 原本是**全表均匀随机**，
# 客户端 `_roll_shop_tier()` 有一整套按回合的档位曲线。两边分布完全不同：
# 第 1 回合服务端有 ~19% 概率刷出三档单位，设计上那里应该是 0%。
#
# 为什么这条检查必须**直接采样服务端函数**，而不是只测 ShopRoll 的规则：
# 规则抽出来之后，测规则只能证明"规则本身没写错"，
# 证明不了"服务端真的在用它"。这次坏掉的正是后者 ——
# 服务端有自己的一套，而计划中用来验收上线的影子比对只对金币
# （`_shadow_audit_economy`），刷新价两边一分不差，**结构上抓不到内容差异**。
#
# 两类断言：
#   1. 硬断言（零抽样风险）：10 回合以前**绝不允许**出现三档单位
#   2. 分布断言：采样 8000 次，各档占比须落在曲线 ±5 个百分点内
# 均匀随机在第 1 回合会给出 ~19% 的三档，第 1 类断言当场就红。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/shop_roll_parity_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")

const CHECK_NAME := "shop_roll_parity"
const SAMPLES := 8000
const TOLERANCE := 0.05

var _h: CheckHarness
var _prep: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()

	_case_curve_boundaries()
	_case_server_no_tier3_before_round10()
	_case_server_distribution()
	_case_client_matches_curve()
	_case_pick_offer_respects_tier()
	_case_server_wiring_passes_round()
	_case_next_prep_uses_upcoming_round()

	_h.finish(get_tree())


# 期望的档位占比。这张表是曲线的**独立副本** ——
# 故意不从 ShopRoll 读，否则改了曲线检查会跟着一起改，等于没测。
func _expected(round_index: int) -> Dictionary:
	if round_index >= 15:
		return {1: 0.15, 2: 0.60, 3: 0.25}
	if round_index >= 10:
		return {1: 0.25, 2: 0.60, 3: 0.15}
	if round_index >= 5:
		return {1: 0.50, 2: 0.50, 3: 0.00}
	return {1: 0.80, 2: 0.20, 3: 0.00}


# 阈值边界逐点钉死。这些是确定性的，能抓到 < 写成 <= 之类的偏移。
func _case_curve_boundaries() -> void:
	var cases := [
		# [回合, roll, 期望档位]
		[1, 0.0, 1], [1, 0.799, 1], [1, 0.80, 2], [1, 0.999, 2],
		[4, 0.799, 1], [4, 0.80, 2],
		[5, 0.499, 1], [5, 0.50, 2], [5, 0.999, 2],
		[9, 0.499, 1], [9, 0.50, 2],
		[10, 0.249, 1], [10, 0.25, 2], [10, 0.849, 2], [10, 0.85, 3],
		[14, 0.25, 2], [14, 0.85, 3],
		[15, 0.149, 1], [15, 0.15, 2], [15, 0.749, 2], [15, 0.75, 3],
		[21, 0.0, 1], [21, 0.999, 3],
	]
	for c in cases:
		var r := int(c[0])
		var roll := float(c[1])
		var want := int(c[2])
		var got := ShopRoll.tier_for_roll(r, roll)
		_h.expect(got == want, "tier_boundary_wrong",
			"回合 %d、roll %.3f 应出 tier%d，实际 tier%d" % [r, roll, want, got])


func _server_tier_histogram(round_index: int, count: int) -> Dictionary:
	var hist := {1: 0, 2: 0, 3: 0}
	var drawn := 0
	while drawn < count:
		var batch: Array = NetworkService.call("_server_roll_shop_offers",
			GameState.SHOP_UNIT_SLOTS, round_index)
		if batch.is_empty():
			break
		for entry in batch:
			var t := int((entry as Dictionary).get("tier", 1))
			hist[t] = int(hist.get(t, 0)) + 1
			drawn += 1
	hist["_total"] = drawn
	return hist


# 硬断言：10 回合以前一个三档单位都不该出现。
# 这条不依赖统计容差 —— 均匀随机会立刻违反它。
func _case_server_no_tier3_before_round10() -> void:
	for r in [1, 4, 5, 9]:
		var hist := _server_tier_histogram(r, SAMPLES)
		var total := int(hist.get("_total", 0))
		if not _h.expect(total >= SAMPLES, "server_sample_short",
				"回合 %d 只采到 %d 个样本（期望 %d）" % [r, total, SAMPLES]):
			continue
		_h.expect(int(hist.get(3, 0)) == 0, "server_tier3_too_early",
			"回合 %d 服务端刷出了 %d 个三档单位 —— 曲线在这一段应为 0%%（均匀随机约 19%%）" % [
				r, int(hist.get(3, 0))])


func _case_server_distribution() -> void:
	for r in [1, 5, 10, 15, 21]:
		var hist := _server_tier_histogram(r, SAMPLES)
		var total := int(hist.get("_total", 0))
		if not _h.expect(total >= SAMPLES, "server_sample_short",
				"回合 %d 只采到 %d 个样本" % [r, total]):
			continue
		var want := _expected(r)
		var line := "回合 %2d 服务端实测 " % r
		for tier in [1, 2, 3]:
			var share := float(int(hist.get(tier, 0))) / float(total)
			var exp_share := float(want.get(tier, 0.0))
			line += "t%d=%.1f%%(期望%.0f%%) " % [tier, share * 100.0, exp_share * 100.0]
			_h.expect(absf(share - exp_share) <= TOLERANCE, "server_share_off",
				"回合 %d tier%d 占比 %.1f%%，期望 %.0f%%（容差 ±%.0f 个百分点）" % [
					r, tier, share * 100.0, exp_share * 100.0, TOLERANCE * 100.0])
		print("[%s] %s" % [CHECK_NAME, line])


# 客户端侧走的是同一条曲线（经由 PrepBoardController._roll_shop_tier）。
func _case_client_matches_curve() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return
	_prep = packed.instantiate()
	add_child(_prep)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var saved_round := GameState.round_index
	for r in [1, 5, 10, 15, 21]:
		GameState.round_index = r
		var hist := {1: 0, 2: 0, 3: 0}
		for _i in SAMPLES:
			var t := int(_prep.call("_roll_shop_tier", rng))
			hist[t] = int(hist.get(t, 0)) + 1
		var want := _expected(r)
		for tier in [1, 2, 3]:
			var share := float(int(hist.get(tier, 0))) / float(SAMPLES)
			_h.expect(absf(share - float(want.get(tier, 0.0))) <= TOLERANCE, "client_share_off",
				"客户端回合 %d tier%d 占比 %.1f%%，期望 %.0f%%" % [
					r, tier, share * 100.0, float(want.get(tier, 0.0)) * 100.0])
	GameState.round_index = saved_round


# pick_offer 选出来的单位，tier 必须真的等于摇到的档位。
# 曲线对了但选池写错（比如过滤条件反了）同样是静默错误。
func _case_pick_offer_respects_tier() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "units_empty", "race_units 表为空"):
		return
	var seen := {}
	for i in 400:
		var tier_roll := float(i) / 400.0
		for j in 8:
			var pick_roll := float(j) / 8.0
			var want_tier := ShopRoll.tier_for_roll(21, tier_roll)
			var offer := ShopRoll.pick_offer(units, 21, tier_roll, pick_roll)
			_h.expect(not offer.is_empty(), "pick_offer_empty",
				"tier_roll %.3f / pick_roll %.3f 摇出了空单位" % [tier_roll, pick_roll])
			if offer.is_empty():
				continue
			_h.expect(int(offer.get("tier", 1)) == want_tier, "pick_offer_wrong_tier",
				"曲线要 tier%d，pick_offer 给了 tier%d（%s）" % [
					want_tier, int(offer.get("tier", 1)), str(offer.get("id", "?"))])
			seen[str(offer.get("id", "?"))] = true
	_h.expect(seen.size() >= 20, "pick_offer_low_coverage",
		"3200 次抽样只覆盖到 %d 个不同单位 —— 选池可能被卡死在少数几个" % seen.size())
	# 返回的必须是副本：调回来的字典若与数据表同一引用，
	# 玩家买卖时改一下就把全局数据表改了。
	var probe := ShopRoll.pick_offer(units, 1, 0.0, 0.0)
	probe["__probe"] = true
	var leaked := false
	for u in units:
		if (u as Dictionary).has("__probe"):
			leaked = true
			break
	_h.expect(not leaked, "pick_offer_not_a_copy",
		"pick_offer 返回的是数据表里的原对象，不是副本 —— 改它会污染全局单位表")


# 直接调 _server_roll_shop_offers() 只能证明「函数本身按曲线摇」。
# 真正会坏的是**接线** —— 回合号有没有从房间正确传进去。
# 这里走完整路径：_room_apply_economy -> _economy_ctx -> _server_roll_shop_offers。
func _case_server_wiring_passes_round() -> void:
	var ns := NetworkService
	var saved_values: Dictionary = ServerFlags._values.duplicate(true)
	var saved_loaded: bool = ServerFlags._loaded
	ServerFlags._values = {"economy_ledger_enabled": true}
	ServerFlags._loaded = true

	for probe in [[1, false], [21, true]]:
		var round_index := int(probe[0])
		var want_tier3 := bool(probe[1])
		var room: Dictionary = ns._new_room()
		room.state = ns.ROOM_PREP
		room.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
		room.round_index = round_index
		var prep: Dictionary = ns._room_prep(room, 0)
		var tier3 := 0
		var total := 0
		for _i in 300:
			# 刷新价是**翻倍**递增（10, 20, 40...），17 次就上百万。
			# 这条用例测的是摇出来的东西，不是价格阶梯，所以每次都把钱和次数复位。
			prep["gold"] = 999999
			((prep.get("shop", {}) as Dictionary))["refresh_uses"] = 0
			# 9.13：非权威（影子）模式下服务端要求 shop_refresh 自带自报金币，
			# 否则 _room_apply_economy 判 typeof(payload.gold) != int → gold_desync
			# （这正是 9.13 #1 首回合刷新的报错）。这条用例测的是「摇出来的档位」，
			# 所以按真实客户端那样把刷新前的余额一并报上去。
			var r: Dictionary = ns._room_apply_economy(room, 0, "shop_refresh",
				{"gold": int(prep.get("gold", 0))})
			if not bool(r.get("ok", false)):
				_h.fail("wiring_refresh_denied",
					"回合 %d 的 shop_refresh 被拒：%s" % [round_index, str(r.get("error", "?"))])
				break
			for entry in ((ns._room_prep(room, 0).get("shop", {}) as Dictionary).get("offers", []) as Array):
				total += 1
				if int((entry as Dictionary).get("tier", 1)) == 3:
					tier3 += 1
		if not _h.expect(total > 0, "wiring_no_samples", "回合 %d 一个商品都没摇出来" % round_index):
			continue
		if want_tier3:
			_h.expect(tier3 > 0, "wiring_round_not_passed",
				"房间 round_index=%d，%d 个商品里一个三档都没有 —— 回合号八成没传到摇商店那一步" % [
					round_index, total])
		else:
			_h.expect(tier3 == 0, "wiring_round_not_passed",
				"房间 round_index=%d，却摇出了 %d/%d 个三档 —— 回合号没生效" % [
					round_index, tier3, total])

	ServerFlags._values = saved_values
	ServerFlags._loaded = saved_loaded


# _room_begin_next_prep() 摇的是**下一轮**的商店，而它在 round_index 自增之前。
# 用自增前的旧值会让整条曲线慢一轮 —— 这条断言把那个 off-by-one 钉住。
# 取 round_index=9：自增后是 10，正好跨过「开始出三档」那道坎。
func _case_next_prep_uses_upcoming_round() -> void:
	var ns := NetworkService
	var saved_values: Dictionary = ServerFlags._values.duplicate(true)
	var saved_loaded: bool = ServerFlags._loaded
	ServerFlags._values = {"economy_ledger_enabled": true}
	ServerFlags._loaded = true

	var tier3 := 0
	var total := 0
	for _i in 200:
		var room: Dictionary = ns._new_room()
		room.state = ns.ROOM_RESULT
		room.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
		room.round_index = 9
		ns._room_prep(room, 0)
		ns._room_begin_next_prep(room)
		if int(room.get("round_index", 0)) != 10:
			_h.fail("next_prep_did_not_advance",
				"_room_begin_next_prep 后 round_index=%d，期望 10" % int(room.get("round_index", 0)))
			break
		for entry in ((ns._room_prep(room, 0).get("shop", {}) as Dictionary).get("offers", []) as Array):
			total += 1
			if int((entry as Dictionary).get("tier", 1)) == 3:
				tier3 += 1
	if _h.expect(total > 0, "next_prep_no_samples", "新回合一个商品都没摇出来"):
		# 第 10 回合期望约 15% 三档；用旧值(9)则恒为 0。
		_h.expect(tier3 > 0, "next_prep_round_off_by_one",
			"从第 9 轮进入第 10 轮，%d 个商品里一个三档都没有 —— " % total +
			"摇商店用的多半还是自增前的旧回合号，整条曲线慢一轮")

	ServerFlags._values = saved_values
	ServerFlags._loaded = saved_loaded
