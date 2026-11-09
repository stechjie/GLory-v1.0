extends RefCounted
## AI 的静态估值（2026-11-07，五档难度）。
##
## 只回答「这一套阵容大概多强」，给买牌、卖牌、选上阵、选方向打分用。**不参与战斗** ——
## 战斗永远走 BattleSimulator 的真实规则；这里的数只影响 AI 怎么选，选错了就是 AI 打得差，
## 不会让任何棋子变强或变弱。
##
## 单位强度 = sqrt(有效血量 × 每秒输出)，星级系数直接读 GameState.star_stat_multiplier。
## 羁绊加成是手填的估计值（SYNERGY），以后由 tools/ai_arena 的批量对战校准。
##
## 纯函数，不读房间状态，不消耗任何 RNG。不用 class_name（同 BotPlayer 的理由）。

# 技能对「纸面强度」的修正：治疗 / 增益 / 嘲讽这类数值低但有用的技能往上抬，
# 商人是经济棋子（战斗价值打折，金币价值在 BotPlayer 里另算）。
const SKILL_FACTOR := {
	"lowest_ally_heal": 1.35, "nearby_ally_heal_buff": 1.3, "every_fifth_group_heal": 1.3,
	"nearest_ally_bless": 1.25, "random_ally_damage_reduction": 1.2, "random_ally_buff": 1.2,
	"team_random_stack": 1.2, "guardian_shield_taunt": 1.2, "block_guard": 1.15,
	"global_divine_blast": 1.15, "black_hole": 1.15, "aoe_silence": 1.15, "line_pierce": 1.1,
	"unique_king_growth": 1.25, "post_battle_gold_by_star": 0.75,
}
# 「替左边邻居挡死」的人仆攻击是 1，按 sqrt 公式会被算成 0 —— 给它一个保底输出。
const SACRIFICE_DPS_FLOOR := 40.0
# 4 星的属性只多 15%，主要价值在技能升级（GameState.star_stat_multiplier 的注释）。
const FOUR_STAR_SKILL_BONUS := 1.25

# 羁绊估值：[门槛, 作用范围, 加成]。race = 只加该族棋子，team = 全队。
# 门槛与 SynergyService.flags_from_counts 一致；加成是对 sqrt(血×攻) 的粗估。
const SYNERGY := {
	"god": [[3, "race", 0.10], [7, "team", 0.25]],
	"dark": [[2, "team", 0.05], [5, "race", 0.15], [7, "race", 0.12]],
	"undead": [[2, "team", 0.04], [4, "race", 0.15], [7, "race", 0.12]],
	"human": [[2, "race", 0.08], [7, "team", 0.20]],
	"crimson": [[2, "race", 0.04], [4, "race", 0.12], [7, "team", 0.20]],
}


# 同一种棋子同一星级的强度只算一次。键里带上血和攻击：人王会成长、四星有覆盖值，
# 同名不同数值的要分开。表最多几百条（40 种棋子 × 4 星 × 少量成长值），满了整表清空。
static var _power_cache: Dictionary = {}
const POWER_CACHE_LIMIT := 2048


static func unit_power(definition: Dictionary, star: int) -> float:
	# 两层字典 id → [星级 → [hp, atk, 强度]]，不拼字符串键（拼键本身就占了大半耗时）。
	var id: Variant = definition.get("id", "")
	var hp: Variant = definition.get("hp", 0)
	var atk: Variant = definition.get("atk", 0)
	var by_star: Variant = _power_cache.get(id)
	if by_star != null:
		var hit: Variant = (by_star as Dictionary).get(star)
		if hit != null and hit[0] == hp and hit[1] == atk:
			return hit[2]
	elif _power_cache.size() >= POWER_CACHE_LIMIT:
		_power_cache.clear()
	var power := _compute_power(definition, star)
	if by_star == null:
		by_star = {}
		_power_cache[id] = by_star
	(by_star as Dictionary)[star] = [hp, atk, power]
	return power


static func _compute_power(definition: Dictionary, star: int) -> float:
	var mult := GameState.star_stat_multiplier(star, definition)
	var hp := float(definition.get("hp", 1)) * mult
	var atk := float(definition.get("atk", 1)) * mult
	var defense := float(definition.get("def", 0)) * mult
	var speed := maxf(0.2, float(definition.get("attack_speed", 1.0)))
	var crit := clampf(float(definition.get("crit", 0.0)), 0.0, 1.0)
	var crit_dmg := maxf(1.0, float(definition.get("crit_dmg", 1.5)))
	var ehp := hp * (1.0 + defense / 100.0)
	var dps := atk * speed * (1.0 + crit * (crit_dmg - 1.0))
	var skill := str(definition.get("skill_id", ""))
	if skill == "left_neighbor_sacrifice":
		dps = maxf(dps, SACRIFICE_DPS_FLOOR * mult)
	var power := sqrt(maxf(0.0, ehp * dps)) * float(SKILL_FACTOR.get(skill, 1.0))
	if star >= GameConstants.MAX_STAR:
		power *= FOUR_STAR_SKILL_BONUS
	return power


static func merc_power(definition: Dictionary) -> float:
	return unit_power(definition, 1)


# 羁绊系数。knowledge：0 = 不懂羁绊；1 = 只认第一档；2 = 全部门槛。
# 返回 {"team": 全队加成, "race": {race: 该族加成}}。
static func synergy_bonus(counts: Dictionary, knowledge: int) -> Dictionary:
	var team := 0.0
	var by_race := {}
	if knowledge <= 0:
		return {"team": team, "race": by_race}
	for race in SYNERGY:
		var n := int(counts.get(race, 0))
		var tiers: Array = SYNERGY[race]
		for index in tiers.size():
			if knowledge == 1 and index > 0:
				break
			var tier: Array = tiers[index]
			if n < int(tier[0]):
				break
			if str(tier[1]) == "team":
				team += float(tier[2])
			else:
				by_race[race] = float(by_race.get(race, 0.0)) + float(tier[2])
	return {"team": team, "race": by_race}


# 一组上阵棋子的总估值。units = [{def, star}]。
static func board_value(units: Array, knowledge: int) -> float:
	var powers: Array[float] = []
	var races: Array[String] = []
	for u in units:
		powers.append(unit_power(u.def, int(u.star)))
		races.append(str((u.def as Dictionary).get("race", "")))
	var all: Array[int] = []
	for i in units.size():
		all.append(i)
	return _value_of(all, powers, races, knowledge)


static func _value_of(picked: Array[int], powers: Array[float], races: Array[String], knowledge: int) -> float:
	var counts := {}
	for i in picked:
		counts[races[i]] = int(counts.get(races[i], 0)) + 1
	var bonus := synergy_bonus(counts, knowledge)
	var by_race: Dictionary = bonus.race
	var total := 0.0
	for i in picked:
		total += powers[i] * (1.0 + float(by_race.get(races[i], 0.0)))
	return total * (1.0 + float(bonus.team))


# 从 roster 里挑上阵的 cap 个。候选方案：纯按单卡强度取前 cap；以及「某一族优先」各一套
# （懂羁绊的档位才会因此选到凑羁绊的阵容）。唯一棋子同名只上一个。返回 roster 里的原对象。
# 每个棋子的强度先算好放数组里 —— 排序比较函数里现算会被调几十次（11-07 实测一回合 200 ms）。
static func pick_board(roster: Array, cap: int, knowledge: int) -> Array:
	var out: Array = []
	for i in pick_board_indices(roster, cap, knowledge):
		out.append(roster[i])
	return out


# 同 pick_board，返回 roster 里的下标（判断「谁在上阵」用下标，不用 Array.has(字典) 逐字段比）。
static func pick_board_indices(roster: Array, cap: int, knowledge: int) -> Array[int]:
	if roster.is_empty() or cap <= 0:
		return []
	var n := roster.size()
	var powers: Array[float] = []
	var races: Array[String] = []
	var keys: Array = []
	for i in n:
		var u: Dictionary = roster[i]
		var power := unit_power(u.def, int(u.star))
		powers.append(power)
		races.append(str((u.def as Dictionary).get("race", "")))
		# 原生排序：强度高 → 星级高 → id 字典序 → 原下标（同分时结果固定）。
		keys.append([-power, -int(u.star), str(u.id), i])
	keys.sort()
	var order: Array[int] = []
	for key in keys:
		order.append(int(key[3]))
	var best := _fill(roster, order, [], cap)
	if knowledge > 0:
		var best_value := _value_of(best, powers, races, knowledge)
		var seen := {}
		var race_keys: Array[String] = []
		for i in order:
			if not seen.has(races[i]):
				seen[races[i]] = true
				race_keys.append(races[i])
		race_keys.sort()
		for race in race_keys:
			var first: Array[int] = []
			for i in order:
				if races[i] == race:
					first.append(i)
			var option := _fill(roster, order, first, cap)
			var value := _value_of(option, powers, races, knowledge)
			if value > best_value + 0.0001:
				best_value = value
				best = option
	return best


static func _fill(roster: Array, order: Array[int], preferred: Array[int], cap: int) -> Array[int]:
	var chosen: Array[int] = []
	var taken := {}
	var unique_used := {}
	for source in [preferred, order]:
		for i in source:
			if chosen.size() >= cap:
				return chosen
			if taken.has(i):
				continue
			var u: Dictionary = roster[i]
			if bool((u.def as Dictionary).get("unique_on_board", false)):
				if unique_used.has(str(u.id)):
					continue
				unique_used[str(u.id)] = true
			taken[i] = true
			chosen.append(i)
	return chosen


# 整个 roster 的估值：上阵部分 + 备战席上「还在凑星」的潜力。
# merge_weight = 0 的档位不看潜力（新手只看眼前）。horizon = 还剩几回合，越晚潜力越不值钱。
static func roster_value(roster: Array, cap: int, knowledge: int, merge_weight: float, horizon: int) -> float:
	var board := pick_board(roster, cap, knowledge)
	var value := board_value(board, knowledge)
	if merge_weight <= 0.0 or horizon <= 0:
		return value
	return value + merge_weight * merge_potential(roster, horizon)


# 同名棋子凑星的潜力：按「一星当量」数份数（二星 = 2 份，三星 = 6 份），
# 期望收益 = （三星强度 − 现在强度）× 进度²。三星已到合成上限，不再算潜力。
# 平方（凸）是有意的：越接近凑齐，每多一份越值钱；单张新卡离三星最远、潜力最小。
# 试过线性 —— 一张新卡的潜力反而比给已有的凑对还大，等于鼓励摊大饼（10.30 回归的
# buy_existing_first 当场红）。首批实测三星偏少（普通 2.9 vs 简单 5.3）的问题靠档位里的
# merge_weight 放大和卖牌时保护凑了一半的那几张来解决，不靠改形状。
static func merge_potential(roster: Array, horizon: int) -> float:
	var copies := {}
	var defs := {}
	for u in roster:
		var star := int(u.star)
		if star >= GameConstants.MAX_MERGE_STAR:
			continue
		var id := str(u.id)
		copies[id] = int(copies.get(id, 0)) + (1 if star == 1 else GameConstants.copies_to_upgrade(1))
		defs[id] = u.def
	var total := 0.0
	var time_factor := clampf(float(horizon) / 8.0, 0.15, 1.0)
	for id in copies:
		var c := int(copies[id])
		var need_three := GameConstants.copies_to_upgrade(1) * GameConstants.copies_to_upgrade(2)
		var gain := unit_power(defs[id], 3) - unit_power(defs[id], 2 if c >= 2 else 1)
		var progress := clampf(float(c) / float(need_three), 0.0, 1.0)
		total += gain * progress * progress * time_factor
	return total
