extends RefCounted
## AI 的萝卜：叫佣兵、抽升级石、用升级石升四星（2026-11-07）。
##
## 改之前的问题（实测 60 局 × 21 回合）：一次升级石都没抽过、零个四星，每回合只叫 1 个佣兵。
## 原因是「抽不起就把萝卜全花在买得起的最贵佣兵上」—— 第一次抽石要 50 萝卜，永远攒不到。
##
## 所有交易仍走 EconomyLedger.apply（和真人同一份规则），这里只决定「做不做、做哪个」。
##
## 队伍仓库的石头（用户 11-07 定）：
##   * 队里有真人时，AI 只用**自己抽的**石头，而且要在仓库里放满 2 回合 —— 2 回合后还在，
##     说明真人不能用或没用，AI 才拿去升四星。真人队友有没有对应的三星都一样要等。
##   * 例外：第 21 回合（决赛）只要真人队友用不上（没有对应属性的三星），AI 可以直接用。
##   * 真人抽的石头 AI 一律不碰。全是 AI 的队伍没人可让，仓库里的都能用。
##   仓库只记「天 / 地 / 人各几颗」，所以 AI 在 bot.own_stones 里记自己抽的每一颗是哪回合抽的；
##   真人把同属性的用掉了，就按「用掉的是 AI 那颗」对账（从最早的划掉）。

const CarrotRules := preload("res://scripts/economy/CarrotEconomy.gd")
const Eval := preload("res://scripts/economy/ai/BotEval.gd")

const STONE_WAIT_ROUNDS := 2


static func important_round(round_index: int) -> bool:
	var kind := RoundService.schedule_kind_for_round(round_index)
	return kind == "boss" or kind == "pvp" or kind == "final"


# ---------------------------------------------------------------- 抽石 + 佣兵

static func spend(bot: Dictionary, round_index: int, rng: RandomNumberGenerator, profile: Dictionary) -> void:
	reconcile_own_stones(bot)
	var mode := str(profile.get("carrots", "plan"))
	if mode == "greedy":
		_hire_greedy(bot)
		return
	var final_round := int(bot.get("final_round", 21))
	var want_stone := bool(profile.get("stone_draw", false)) and _wants_stone(bot, round_index, final_round)
	if want_stone or mode == "pack":
		_try_draw(bot, round_index, rng)
	var budget := int(bot.carrots)
	if mode in ["plan", "plan_rounds"] and want_stone and not _drew_this_round(bot, round_index):
		# 攒着下一回合抽石。plan_rounds 在 Boss / PvP / 决赛回合照样叫佣兵 —— 那一场更值钱。
		var hold := mode == "plan" or not important_round(round_index)
		if hold and _stone_capacity_ok(bot):
			budget = 0
	_hire_pack(bot, budget)


static func _drew_this_round(bot: Dictionary, round_index: int) -> bool:
	return int(bot.get("stone_draw_used_round", -1)) == round_index


static func _next_stone_cost(bot: Dictionary, round_index: int) -> int:
	if str(bot.get("ruleset", "normal")) == "seedling" and round_index >= 6 and not bool(bot.get("free_stone_claimed", false)):
		return 0
	return CarrotRules.stone_cost_for_draw(int(bot.get("stone_draws", 0)))


static func _stone_capacity_ok(bot: Dictionary) -> bool:
	var capacity := CarrotRules.capacity_for_spent(int(bot.carrot_spent), float(bot.get("carrot_bonus_rate", 0.0)))
	return capacity >= CarrotRules.stone_cost_for_draw(int(bot.get("stone_draws", 0)))


# 值得为四星攒萝卜：容量够付下一颗、手上有能升四星的三星（同属性还没有可用的石头）、
# 而且抽到之后来得及用（队里有真人时要等 2 回合）。
static func _wants_stone(bot: Dictionary, round_index: int, final_round: int) -> bool:
	if round_index < 3 or not _stone_capacity_ok(bot):
		return false
	# 队里有真人时抽到要等 2 回合才轮到 AI：来不及在决赛前用上就不攒。
	var wait := STONE_WAIT_ROUNDS if bool(bot.get("team_has_humans", false)) else 0
	if round_index + wait > final_round:
		return false
	var elements := four_star_elements(bot)
	if elements.is_empty():
		return false
	for element in elements:
		if usable_stone_count(bot, element, round_index) <= 0:
			return true
	return false


static func _try_draw(bot: Dictionary, round_index: int, rng: RandomNumberGenerator) -> void:
	if _drew_this_round(bot, round_index) or round_index < 3:
		return
	var ledger := {"carrots": int(bot.carrots), "merc_carrots_spent_total": int(bot.carrot_spent),
		"stone_draw_count": int(bot.stone_draws), "stone_draw_used_round": int(bot.get("stone_draw_used_round", -1)),
		"free_stone_claimed": bool(bot.get("free_stone_claimed", false))}
	var before: Dictionary = (bot.stones as Dictionary).duplicate()
	var draw := EconomyLedger.apply(ledger, "draw_upgrade_stone", {}, {
		"round_index": round_index, "ruleset": str(bot.get("ruleset", "normal")),
		"carrot_bonus_rate": float(bot.get("carrot_bonus_rate", 0.0)),
		"team_stones": bot.stones, "stone_roll": rng.randf()})
	if not bool(draw.get("ok", false)):
		return
	bot.carrots = int(ledger.carrots)
	bot.stone_draws = int(ledger.stone_draw_count)
	bot["stone_draw_used_round"] = round_index
	bot["free_stone_claimed"] = bool(ledger.get("free_stone_claimed", false))
	var own: Array = bot.get("own_stones", [])
	for kind in bot.stones:
		var gained := maxi(0, int(bot.stones[kind]) - int(before.get(kind, 0)))
		bot.stones_gained[kind] = int(bot.stones_gained.get(kind, 0)) + gained
		for _i in gained:
			own.append({"type": str(kind), "round": round_index})
	bot["own_stones"] = own


# 有萝卜就叫买得起的最贵一个（新手档；也是 11-07 之前所有 AI 的做法）。
static func _hire_greedy(bot: Dictionary) -> void:
	var table := _merc_table()
	var owned: Array = bot.mercs
	while owned.size() < GameState.MERCENARY_SLOTS:
		var pick: Dictionary = {}
		for m in table:
			var c := int(m.get("carrot_cost", -1))
			if c >= 0 and c <= int(bot.carrots):
				pick = m
		if pick.is_empty():
			break
		_hire(bot, pick)


# 预算内凑「总强度最高」的一组佣兵（同一个可以叫多个）。小背包：预算 × 空位 × 12 种。
static func _hire_pack(bot: Dictionary, budget: int) -> void:
	var owned: Array = bot.mercs
	var slots := GameState.MERCENARY_SLOTS - owned.size()
	budget = mini(budget, int(bot.carrots))
	if slots <= 0 or budget <= 0:
		return
	var table := _merc_table()
	var costs: Array[int] = []
	var values: Array[float] = []
	for m in table:
		var c := int(m.get("carrot_cost", -1))
		if c > 0:
			costs.append(c)
			values.append(Eval.merc_power(m))
	# best[k][b] = 用 k 个、花不超过 b 时的最大强度；choice 记最后一个选了谁。
	var best: Array = []
	var choice: Array = []
	for k in slots + 1:
		var row: Array[float] = []
		var pick: Array[int] = []
		row.resize(budget + 1)
		row.fill(0.0)
		pick.resize(budget + 1)
		pick.fill(-1)
		best.append(row)
		choice.append(pick)
	for k in range(1, slots + 1):
		for b in range(budget + 1):
			best[k][b] = best[k - 1][b]
			choice[k][b] = -1
			for i in costs.size():
				if costs[i] <= b:
					var v: float = best[k - 1][b - costs[i]] + values[i]
					if v > best[k][b] + 0.0001:
						best[k][b] = v
						choice[k][b] = i
	var picks: Array[int] = []
	var k := slots
	var b := budget
	while k > 0 and b >= 0:
		var i: int = choice[k][b]
		if i >= 0:
			picks.append(i)
			b -= costs[i]
		k -= 1
	# 先叫贵的：佣兵席按叫的先后编号，强的站前面那几个位置。
	picks.sort_custom(func(x, y): return costs[x] > costs[y] or (costs[x] == costs[y] and x < y))
	var hireable := table.filter(func(m): return int(m.get("carrot_cost", -1)) > 0)
	for i in picks:
		_hire(bot, hireable[i])


static func _merc_table() -> Array:
	var table: Array = DataRegistry.get_table("mercenaries").get("mercenaries", []).duplicate()
	# 同价按 id 排，保证数据表行序变化不改变结果。
	table.sort_custom(func(a, b):
		var ca := int(a.get("carrot_cost", 0))
		var cb := int(b.get("carrot_cost", 0))
		if ca != cb:
			return ca < cb
		return str(a.get("id", "")) < str(b.get("id", ""))
	)
	return table


static func _hire(bot: Dictionary, merc: Dictionary) -> void:
	var carrots := int(merc.get("carrot_cost", 0))
	if carrots > int(bot.carrots):
		return
	bot.carrots = int(bot.carrots) - carrots
	bot.carrot_spent = int(bot.carrot_spent) + carrots
	var owned: Array = bot.mercs
	owned.append({"id": str(merc.get("id", "")), "star": 1, "def": merc.duplicate(true),
		"is_mercenary": true, "cost_basis": 0, "merc_slot": owned.size()})


# ---------------------------------------------------------------- 队伍仓库的石头

# 真人用掉了同属性的石头 → 按「用掉的是 AI 那颗」划掉最早的。
static func reconcile_own_stones(bot: Dictionary) -> void:
	var own: Array = bot.get("own_stones", [])
	if own.is_empty():
		return
	var counts := {}
	for entry in own:
		counts[str(entry.type)] = int(counts.get(str(entry.type), 0)) + 1
	for kind in counts:
		var extra := int(counts[kind]) - int((bot.stones as Dictionary).get(kind, 0))
		var index := 0
		while extra > 0 and index < own.size():
			if str(own[index].type) == kind:
				own.remove_at(index)
				extra -= 1
			else:
				index += 1
	bot["own_stones"] = own


# 这一刻 AI 能用几颗 element 属性的石头（规则见文件头）。
static func usable_stone_count(bot: Dictionary, element: String, round_index: int) -> int:
	var warehouse := int((bot.stones as Dictionary).get(element, 0))
	if warehouse <= 0:
		return 0
	if not bool(bot.get("team_has_humans", false)):
		return warehouse
	var final_round := int(bot.get("final_round", 21))
	var humans_need := (bot.get("human_stone_elements", []) as Array).has(element)
	var n := 0
	for entry in bot.get("own_stones", []):
		if str(entry.type) != element:
			continue
		if round_index - int(entry.round) >= STONE_WAIT_ROUNDS or (round_index >= final_round and not humans_need):
			n += 1
	return mini(n, warehouse)


# 扣一颗：仓库 -1，AI 自己那颗（最早的）划掉。调用前先 usable_stone_count > 0。
static func take_stone(bot: Dictionary, element: String) -> void:
	bot.stones[element] = maxi(0, int(bot.stones.get(element, 0)) - 1)
	var own: Array = bot.get("own_stones", [])
	for index in own.size():
		if str(own[index].type) == element:
			own.remove_at(index)
			break
	bot["own_stones"] = own


# 手上能升四星的三星都是什么属性（商人这类经济棋子不算）。
static func four_star_elements(bot: Dictionary) -> Array:
	var out: Array = []
	for u in bot.roster:
		if int(u.star) != GameConstants.MAX_MERGE_STAR:
			continue
		if str((u.def as Dictionary).get("skill_id", "")) == "post_battle_gold_by_star":
			continue
		var element := str((u.def as Dictionary).get("element", ""))
		if CarrotRules.valid_stone_type(element) and not out.has(element):
			out.append(element)
	return out
