extends Node

# 守萝卜经济的几条硬不变量。
#
# 为什么要有这个检查：
#   项目里已经有 shop_price_parity / shop_roll_parity / merge_rule_parity 三道闸，
#   它们存在的原因写在 ShopRoll.gd 顶部和 EconomyService.settle_post_battle_gold()
#   的注释里 —— 同一条规则在客户端和服务端各写一份，改一处忘另一处，而且**不会报错**。
#
#   萝卜是目前唯一一个**默认走服务端权威**的经济系统
#   （ServerFlags: carrot_economy_enabled 默认 true，两个 economy_ledger_* 默认 false），
#   却一条检查都没有。2026-09-08 就踩过一次：`PrepScreen._ready()` 的采集判据写成
#   `not team_active`，比其余萝卜动作（`team_active and not is_host`）多挡了房主，
#   于是房主既不本地采集、也收不到自己广播的 room_state，萝卜恒为 0 —— 无人发现。
#
# 断言的是**性质**，不绑定具体数值表。改产量/容量/价格表时这些断言仍应成立。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/carrot_economy_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const EconomyLedgerScript := preload("res://scripts/multiplayer/EconomyLedger.gd")

const CHECK_NAME := "carrot_economy"
const FINAL_ROUND := 21

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_table_shape()
	_case_harvest_formula()
	_case_idempotent()
	_case_client_server_parity()
	_case_capacity_fillable()
	_case_stone_reachable()
	_case_four_star_upgrade()
	await _case_harvest_owner()
	_h.finish(get_tree())


# --- 1. 等级表形状 -------------------------------------------------------------
# 三张按萝卜田等级索引的表必须等长且单调。少一项就会在 farm_level_for_spent()
# 返回最高级时越界；不单调则"升级反而变差"，且不会有任何报错。
func _case_table_shape() -> void:
	var n := CarrotEconomy.FARM_THRESHOLDS.size()
	_h.expect(CarrotEconomy.FARM_CAPACITIES.size() == n, "farm_table_length",
		"FARM_CAPACITIES 长度 %d != FARM_THRESHOLDS 长度 %d" % [CarrotEconomy.FARM_CAPACITIES.size(), n])
	_h.expect(CarrotEconomy.FARM_INCOME.size() == n, "farm_table_length",
		"FARM_INCOME 长度 %d != FARM_THRESHOLDS 长度 %d" % [CarrotEconomy.FARM_INCOME.size(), n])
	_h.expect(CarrotEconomy.FARM_PRODUCTION.size() == n, "farm_table_length",
		"FARM_PRODUCTION 长度 %d != FARM_THRESHOLDS 长度 %d" % [CarrotEconomy.FARM_PRODUCTION.size(), n])
	_h.expect(CarrotEconomy.HARVEST_TECH_BONUSES.size() == CarrotEconomy.MAX_HARVEST_TECH_LEVEL + 1,
		"tech_table_length", "HARVEST_TECH_BONUSES 长度 %d != MAX_HARVEST_TECH_LEVEL+1 = %d"
			% [CarrotEconomy.HARVEST_TECH_BONUSES.size(), CarrotEconomy.MAX_HARVEST_TECH_LEVEL + 1])
	_h.expect(CarrotEconomy.HARVEST_TECH_PRICES.size() == CarrotEconomy.MAX_HARVEST_TECH_LEVEL,
		"tech_table_length", "HARVEST_TECH_PRICES 长度 %d != MAX_HARVEST_TECH_LEVEL = %d"
			% [CarrotEconomy.HARVEST_TECH_PRICES.size(), CarrotEconomy.MAX_HARVEST_TECH_LEVEL])

	_assert_monotonic(CarrotEconomy.FARM_THRESHOLDS, "FARM_THRESHOLDS")
	_assert_monotonic(CarrotEconomy.FARM_CAPACITIES, "FARM_CAPACITIES")
	_assert_monotonic(CarrotEconomy.FARM_INCOME, "FARM_INCOME")
	_assert_monotonic(CarrotEconomy.FARM_PRODUCTION, "FARM_PRODUCTION")
	_assert_monotonic(CarrotEconomy.HARVEST_TECH_BONUSES, "HARVEST_TECH_BONUSES")
	_assert_monotonic(CarrotEconomy.HARVEST_TECH_PRICES, "HARVEST_TECH_PRICES")


func _assert_monotonic(table: Array, label: String) -> void:
	for i in range(1, table.size()):
		if int(table[i]) < int(table[i - 1]):
			_h.fail("table_not_monotonic",
				"%s 在第 %d 项回落：%d -> %d —— 升级不该让数值变差" % [label, i, int(table[i - 1]), int(table[i])])
		else:
			_h.item()


# --- 2. 采集公式 ---------------------------------------------------------------
# 硬不变量（不绑定具体数值）：
#   到账 = min(产量, 上限 - 采集前)      —— 永不超上限
#   浪费 = 产量 - 到账                   —— 溢出必须被显式记账，不能凭空消失
#   采集后 = 采集前 + 到账
# 面板的「下回合 +N」也读这个函数（CarrotCampPanel.refresh 拿它做无副作用预演），
# 所以这条同时守住了显示与实发一致。
func _case_harvest_formula() -> void:
	for tech in range(0, CarrotEconomy.MAX_HARVEST_TECH_LEVEL + 1):
		for level in CarrotEconomy.FARM_THRESHOLDS.size():
			var spent := int(CarrotEconomy.FARM_THRESHOLDS[level])
			var capacity := CarrotEconomy.capacity_for_spent(spent)
			var production := CarrotEconomy.total_production(tech, spent)
			# 空仓、半仓、差一格满、正好满、以及越界的脏值
			for before in [0, capacity / 2, maxi(0, capacity - 1), capacity, capacity + 7]:
				var r := CarrotEconomy.harvest(before, spent, tech)
				var clamped := clampi(before, 0, capacity)
				var want_gain := mini(production, capacity - clamped)
				var tag := "tech%d/farmLv%d/before%d" % [tech, level + 1, before]
				if int(r.get("gain", -1)) != want_gain:
					_h.fail("harvest_gain_wrong", "%s：到账 %d，应为 min(%d, %d-%d)=%d"
						% [tag, int(r.get("gain", -1)), production, capacity, clamped, want_gain])
				elif int(r.get("after", -1)) != clamped + want_gain:
					_h.fail("harvest_after_wrong", "%s：采集后 %d，应为 %d"
						% [tag, int(r.get("after", -1)), clamped + want_gain])
				elif int(r.get("after", -1)) > capacity:
					_h.fail("harvest_over_capacity", "%s：采集后 %d 超出上限 %d"
						% [tag, int(r.get("after", -1)), capacity])
				elif int(r.get("overflow", -1)) != production - want_gain:
					_h.fail("harvest_overflow_wrong", "%s：浪费 %d，应为 %d - %d = %d"
						% [tag, int(r.get("overflow", -1)), production, want_gain, production - want_gain])
				else:
					_h.item()


# --- 3. 幂等 -------------------------------------------------------------------
# 备战界面每次重建都会调一次采集（PrepScreen._ready）。重复调用必须无副作用，
# 否则打开一次面板 = 白拿一份萝卜。
func _case_idempotent() -> void:
	GameState.reset_run()
	for r in range(1, 6):
		GameState.round_index = r
		var first := GameState.harvest_carrots_for_round(r)
		var after_first := GameState.carrots
		if not _h.expect(bool(first.get("ok", false)), "first_harvest_rejected",
				"第 %d 回合首次采集被拒" % r):
			continue
		for _repeat in 3:
			var again := GameState.harvest_carrots_for_round(r)
			if bool(again.get("ok", false)):
				_h.fail("double_harvest", "第 %d 回合重复采集被接受 —— 可反复开面板刷萝卜" % r)
			elif GameState.carrots != after_first:
				_h.fail("double_harvest", "第 %d 回合重复采集改变了余额：%d -> %d"
					% [r, after_first, GameState.carrots])
			else:
				_h.item()
	# 回合号非法时必须拒绝，且不改余额
	var balance := GameState.carrots
	for bad in [0, -1]:
		var res := GameState.harvest_carrots_for_round(bad)
		if bool(res.get("ok", false)) or GameState.carrots != balance:
			_h.fail("bad_round_accepted", "回合号 %d 的采集被接受了" % bad)
		else:
			_h.item()


# --- 4. 客户端 / 服务端一致性（本检查的核心）-----------------------------------
# GameState.harvest_carrots_for_round() 与 EconomyLedger.harvest_for_round()
# 是同一条规则的两份实现（前者给单人和房主，后者给专用服务器）。
# 它们对同一输入必须给出**逐字段相同**的结果 —— 一旦分叉，房主和客机会拿到
# 不同数量的萝卜，而且没有任何报错。
func _case_client_server_parity() -> void:
	for tech in range(0, CarrotEconomy.MAX_HARVEST_TECH_LEVEL + 1):
		for level in CarrotEconomy.FARM_THRESHOLDS.size():
			var spent := int(CarrotEconomy.FARM_THRESHOLDS[level])
			GameState.reset_run()
			GameState.harvest_tech_level = tech
			GameState.merc_carrots_spent_total = spent
			var prep: Dictionary = EconomyLedgerScript.new_prep(GameState.START_GOLD)
			prep["harvest_tech_level"] = tech
			prep["merc_carrots_spent_total"] = spent

			for r in range(1, FINAL_ROUND + 1):
				GameState.round_index = r
				var mine := GameState.harvest_carrots_for_round(r)
				var theirs := EconomyLedgerScript.harvest_for_round(prep, r)
				var tag := "tech%d/farmLv%d/round%d" % [tech, level + 1, r]
				if bool(mine.get("ok", false)) != bool(theirs.get("ok", false)):
					_h.fail("parity_ok_flag", "%s：客户端 ok=%s，服务端 ok=%s"
						% [tag, str(mine.get("ok")), str(theirs.get("ok"))])
				elif int(mine.get("gain", -1)) != int(theirs.get("gain", -2)):
					_h.fail("parity_gain", "%s：客户端到账 %d，服务端到账 %d"
						% [tag, int(mine.get("gain", -1)), int(theirs.get("gain", -2))])
				elif GameState.carrots != int(prep.get("carrots", -1)):
					_h.fail("parity_balance", "%s：客户端余额 %d，服务端余额 %d"
						% [tag, GameState.carrots, int(prep.get("carrots", -1))])
				elif GameState.last_harvest_round != int(prep.get("last_harvest_round", -99)):
					_h.fail("parity_last_round", "%s：客户端 last_harvest_round=%d，服务端 %d"
						% [tag, GameState.last_harvest_round, int(prep.get("last_harvest_round", -99))])
				else:
					_h.item()


# --- 5. 容量必须填得满 ---------------------------------------------------------
# 每一级萝卜田的容量，在**不买任何采集科技**（tech 0，最保守）的前提下，
# 必须能在一局 21 回合之内装满。装不满 = 那一级的容量是纯装饰，玩家花萝卜
# 升上去却什么都没得到，而且界面上完全看不出来。
#
# 这条正是 FARM_PRODUCTION 存在的理由：加它之前 Lv6 是「容量 150 / 产量 3」，
# 要 50 回合才满，是这张表里最明显的死数值。
func _case_capacity_fillable() -> void:
	for level in CarrotEconomy.FARM_THRESHOLDS.size():
		var spent := int(CarrotEconomy.FARM_THRESHOLDS[level])
		var capacity := CarrotEconomy.capacity_for_spent(spent)
		var production := CarrotEconomy.total_production(0, spent)
		if not _h.expect(production > 0, "zero_production",
				"萝卜田 Lv%d 的产量为 0 —— 永远装不满" % [level + 1]):
			continue
		var rounds := int(ceil(float(capacity) / float(production)))
		if rounds > FINAL_ROUND:
			_h.fail("capacity_unfillable",
				"萝卜田 Lv%d：容量 %d / 产量 %d = 要 %d 回合才装满，而一局只有 %d 回合 —— 这一级的容量是死数值"
					% [level + 1, capacity, production, rounds, FINAL_ROUND])
		else:
			_h.item()
	# 把各级的装满耗时打出来，改表时一眼能看出节奏有没有走形。
	var shape: Array[String] = []
	for level in CarrotEconomy.FARM_THRESHOLDS.size():
		var spent2 := int(CarrotEconomy.FARM_THRESHOLDS[level])
		var cap2 := CarrotEconomy.capacity_for_spent(spent2)
		var prod2 := CarrotEconomy.total_production(0, spent2)
		shape.append("Lv%d %d/%d=%d回合" % [level + 1, cap2, prod2, int(ceil(float(cap2) / float(prod2)))])
	_h.note("装满耗时（采集科技 0 级）：" + " · ".join(shape))


# --- 6. 升级石可达性 -----------------------------------------------------------
# 石头价必须小于等于某一级萝卜田的容量，否则玩家永远存不到那么多萝卜，
# 升级石会变成一条无法触发的死内容 —— 而且界面上看不出来。
func _case_stone_reachable() -> void:
	var max_capacity := 0
	var first_level := -1
	for level in CarrotEconomy.FARM_CAPACITIES.size():
		var cap := int(CarrotEconomy.FARM_CAPACITIES[level])
		max_capacity = maxi(max_capacity, cap)
		if first_level < 0 and cap >= CarrotEconomy.STONE_COST:
			first_level = level + 1
	if not _h.expect(first_level > 0, "stone_unreachable",
			"升级石要 %d 萝卜，但最大容量只有 %d —— 玩家永远抽不到，这是死内容"
				% [CarrotEconomy.STONE_COST, max_capacity]):
		return
	_h.note("升级石（%d 萝卜）最早在萝卜田 Lv%d 可存下" % [CarrotEconomy.STONE_COST, first_level])
	# 1 级田存不下石头是有意设计（逼玩家先花萝卜升级），这里只登记不失败。
	if int(CarrotEconomy.FARM_CAPACITIES[0]) < CarrotEconomy.STONE_COST:
		_h.note("1 级田容量 %d < 石头价 %d：不花萝卜升级就永远抽不到石头，UI 必须讲清楚"
			% [int(CarrotEconomy.FARM_CAPACITIES[0]), CarrotEconomy.STONE_COST])


# --- 7. 四星升级 ---------------------------------------------------------------
# 四星只能由「三星 + 同属性升级石」获得。这里守四条：
#   1. 属性必须对得上（拿天石升不了地属性的棋子）
#   2. 没石头不能升，且失败时**一颗石头都不能少**
#   3. 升级正好消耗一颗，且只消耗对应属性那一种
#   4. 四星不能再升（不能靠反复点消耗石头）
func _case_four_star_upgrade() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "units_empty", "race_units 表为空"):
		return
	var by_element := {}
	for row in units:
		var d: Dictionary = row
		by_element[str(d.get("element", ""))] = d
	for stone in CarrotEconomy.STONE_TYPES:
		if not by_element.has(stone):
			continue
		var d: Dictionary = by_element[stone]
		var name := str(d.get("name", d.get("id", "?")))

		# 2. 没石头不能升
		GameState.reset_run()
		var cell := {"id": str(d.get("id", "")), "star": GameState.MAX_MERGE_STAR, "def": d}
		var denied := GameState.upgrade_cell_to_four_star(cell)
		if bool(denied.get("ok", false)):
			_h.fail("four_star_without_stone", "%s：仓库里没有%s石却升成功了" % [name, stone])
		elif int(cell.get("star", 0)) != GameState.MAX_MERGE_STAR:
			_h.fail("four_star_failed_but_mutated", "%s：升级被拒，但星级被改成了 %d" % [name, int(cell.get("star", 0))])
		else:
			_h.item()

		# 1. 属性不匹配的石头不能用
		for other in CarrotEconomy.STONE_TYPES:
			if other == stone:
				continue
			GameState.reset_run()
			GameState.apply_team_stone(other)
			var cell2 := {"id": str(d.get("id", "")), "star": GameState.MAX_MERGE_STAR, "def": d}
			var wrong := GameState.upgrade_cell_to_four_star(cell2)
			if bool(wrong.get("ok", false)):
				_h.fail("four_star_wrong_element",
					"%s（%s属性）被%s石升级了 —— 属性门槛失效" % [name, stone, other])
			elif int(GameState.team_upgrade_stones.get(other, 0)) != 1:
				_h.fail("four_star_stone_leak", "%s：升级失败却消耗了%s石" % [name, other])
			else:
				_h.item()

		# 3. 正确的石头恰好消耗一颗，且不动别的属性
		GameState.reset_run()
		for s in CarrotEconomy.STONE_TYPES:
			GameState.apply_team_stone(s)
			GameState.apply_team_stone(s)
		var cell3 := {"id": str(d.get("id", "")), "star": GameState.MAX_MERGE_STAR, "def": d}
		GameState.gold = 2000
		var ok := GameState.upgrade_cell_to_four_star(cell3)
		_h.expect(GameState.gold == 2000 - CarrotEconomy.four_star_gold(int(d.get("tier", 0))), "four_star_gold_cost", "四星费用必须按档位扣除")
		if not _h.expect(bool(ok.get("ok", false)), "four_star_denied",
				"%s：有%s石、是三星，却升不了（error=%s）" % [name, stone, str(ok.get("error", "?"))]):
			continue
		if int(cell3.get("star", 0)) != GameState.MAX_UNIT_STAR:
			_h.fail("four_star_wrong_star", "%s：升级后星级是 %d，应为 %d"
				% [name, int(cell3.get("star", 0)), GameState.MAX_UNIT_STAR])
		elif int(GameState.team_upgrade_stones.get(stone, 0)) != 1:
			_h.fail("four_star_stone_count", "%s：升级后%s石剩 %d 颗，应为 1"
				% [name, stone, int(GameState.team_upgrade_stones.get(stone, 0))])
		else:
			_h.item()
		for other2 in CarrotEconomy.STONE_TYPES:
			if other2 == stone:
				continue
			if int(GameState.team_upgrade_stones.get(other2, 0)) != 2:
				_h.fail("four_star_stone_count", "%s：升级动了不相干的%s石" % [name, other2])
			else:
				_h.item()

		# 4. 四星不能再升
		var again := GameState.upgrade_cell_to_four_star(cell3)
		if bool(again.get("ok", false)):
			_h.fail("four_star_repeatable", "%s：四星还能再升 —— 可反复点消耗石头" % name)
		elif int(GameState.team_upgrade_stones.get(stone, 0)) != 1:
			_h.fail("four_star_stone_leak", "%s：对四星再次升级消耗了石头" % name)
		else:
			_h.item()

	# 四星的**属性**必须真的生效。最静默的失败模式是 UnitFactory 里的星级 clamp
	# 漏改（历史上那里硬写 3）：棋子显示四星、属性却按三星算，战斗里没有任何提示。
	var scale_def: Dictionary = units[0]
	var s3 := UnitFactory.apply_star_stats(scale_def, GameState.MAX_MERGE_STAR)
	var s4 := UnitFactory.apply_star_stats(scale_def, GameState.MAX_UNIT_STAR)
	if int(s4.get("star", 0)) != GameState.MAX_UNIT_STAR:
		_h.fail("four_star_clamped", "apply_star_stats 返回的星级是 %d，应为 %d —— 四星被静默降级"
			% [int(s4.get("star", 0)), GameState.MAX_UNIT_STAR])
	elif int(s4.get("hp", 0)) <= int(s3.get("hp", 0)) or int(s4.get("atk", 0)) <= int(s3.get("atk", 0)):
		_h.fail("four_star_stats_not_applied",
			"四星属性没有高于三星：hp %d→%d、atk %d→%d"
				% [int(s3.get("hp", 0)), int(s4.get("hp", 0)), int(s3.get("atk", 0)), int(s4.get("atk", 0))])
	else:
		_h.item()
	# 按单位覆写：star4_multiplier 必须真的被读到（小灵靠它拿 ×1.50 而非默认 ×1.15）。
	var override_def := scale_def.duplicate(true)
	override_def["star4_multiplier"] = 1.50
	var s4o := UnitFactory.apply_star_stats(override_def, GameState.MAX_UNIT_STAR)
	if int(s4o.get("hp", 0)) <= int(s4.get("hp", 0)):
		_h.fail("star4_multiplier_ignored",
			"star4_multiplier=1.50 的棋子 hp 是 %d，不高于默认的 %d —— 覆写字段没被读到"
				% [int(s4o.get("hp", 0)), int(s4.get("hp", 0))])
	else:
		_h.item()

	# 四星必须能**存档往返**，也必须能过联机校验。
	# SaveManager 整块存 board_slots，但 NetProtocol 对 star 有 clamp 与白名单校验
	# （读 MAX_UNIT_STAR）。加四星时漏改那里的表现是「重开游戏 / 提交棋盘后四星退回
	# 三星」或「棋盘被整个拒收」，两种都不报错。
	var probe_def: Dictionary = units[0]
	var probe := {"id": str(probe_def.get("id", "")), "star": GameState.MAX_UNIT_STAR,
		"def": probe_def}
	GameState.reset_run()
	GameState.board_slots[0] = probe
	# save_run() 是**去抖**的（挂一个 SAVE_DEBOUNCE_SEC 的定时器），同一帧调完立刻
	# load_run() 会读到上一次的文件。检查里必须显式落盘，否则这条会假红。
	SaveManager.save_run()
	SaveManager._flush_pending_save()
	if not _h.expect(SaveManager.load_run(), "save_read_failed", "存档写入后读不回来"):
		return
	var reloaded = GameState.board_slots[0]
	if typeof(reloaded) != TYPE_DICTIONARY:
		_h.fail("four_star_save_lost", "存档往返后 0 号格子空了")
	elif int((reloaded as Dictionary).get("star", 0)) != GameState.MAX_UNIT_STAR:
		_h.fail("four_star_save_downgraded", "存档往返后星级变成 %d，应为 %d —— 四星被静默降级"
			% [int((reloaded as Dictionary).get("star", 0)), GameState.MAX_UNIT_STAR])
	else:
		_h.item()
	var submission := NetProtocol.team_board_submission(GameState.board_slots)
	var validated := NetProtocol.validate_team_snapshot(submission, GameState.round_index)
	if not bool(validated.get("ok", true)):
		_h.fail("four_star_net_rejected", "四星棋盘被联机校验拒收：%s" % str(validated.get("reason", "?")))
	else:
		_h.item()

	# 佣兵不能升四星
	GameState.reset_run()
	for s2 in CarrotEconomy.STONE_TYPES:
		GameState.apply_team_stone(s2)
	var merc_cell := {"id": "merc_x", "star": GameState.MAX_MERGE_STAR, "is_mercenary": true,
		"def": {"id": "merc_x", "element": "sky", "is_mercenary": true}}
	var merc_res := GameState.upgrade_cell_to_four_star(merc_cell)
	if bool(merc_res.get("ok", false)):
		_h.fail("four_star_mercenary", "佣兵被升成了四星 —— 佣兵只存在一个回合，升星是白送")
	else:
		_h.item()


# --- 8. 采集权责判据 -----------------------------------------------------------
# 守 2026-09-08 那个 bug：谁在本地采集，必须与本作其余萝卜动作用同一条判据
#   —— 只有「联机且不是房主」交给服务端，其余（单人、房主）一律本地结算。
# 对照 PrepBoardController.request_carrot_harvest_upgrade / request_upgrade_stone_draw。
# 这里直接进真实的 PrepScreen，断言的是**结果**（萝卜有没有到账），不是判据的写法。
func _case_harvest_owner() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return
	var was_active := NetworkService.team_active
	var was_host := NetworkService.is_host
	# [标签, team_active, is_host, 期望本地到账]
	var cases := [
		["单人局", false, false, true],
		["房主（本机开房）", true, true, true],
		["客机（加入别人的房）", true, false, false],
	]
	for row in cases:
		var label := str(row[0])
		GameState.reset_run()
		NetworkService.team_active = bool(row[1])
		NetworkService.is_host = bool(row[2])
		var screen := packed.instantiate()
		add_child(screen)          # _ready() 在这里跑，采集也在这里发生
		await get_tree().process_frame
		var got := GameState.carrots
		var expect_gain := bool(row[3])
		if expect_gain and got <= 0:
			_h.fail("host_not_harvesting",
				"%s：进备战后萝卜仍为 %d —— 该本地采集却没采（team_active=%s is_host=%s）"
					% [label, got, str(row[1]), str(row[2])])
		elif not expect_gain and got > 0:
			_h.fail("client_double_harvest",
				"%s：进备战后本地自行发放了 %d 萝卜 —— 该由服务端结算，会与服务端重复计数"
					% [label, got])
		else:
			_h.item()
		screen.queue_free()
		await get_tree().process_frame
	NetworkService.team_active = was_active
	NetworkService.is_host = was_host
