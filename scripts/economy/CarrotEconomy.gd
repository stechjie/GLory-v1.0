extends RefCounted

## Pure rules for the per-run carrot economy.
## No GameState, NetworkService or UI access belongs in this file.

const BASE_PRODUCTION := 3
const MAX_HARVEST_TECH_LEVEL := 5
const HARVEST_TECH_PRICES := [100, 200, 400, 800, 1600]
const HARVEST_TECH_BONUSES := [0, 3, 6, 10, 15, 25]
const FARM_THRESHOLDS := [0, 9, 20, 35, 55, 75]
const FARM_CAPACITIES := [12, 24, 40, 60, 90, 150]
const FARM_INCOME := [0, 10, 25, 45, 70, 100]
# 萝卜田等级带来的额外产量。
#
# 没有这一项时，容量由「花掉的萝卜」决定、产量只由「金币买的采集科技」决定，
# 两条线互不相干 —— 结果是高等级的田根本填不满：Lv6 容量 150、基础产量 3，
# 要 50 回合才能装满，而一局只有 21 回合。容量成了纯装饰。
#
# 加上之后各级的装满耗时收敛到 4~10 回合，容量上限重新变成一个有意义的
# 「该花萝卜了」的信号。数值取值参考：装满耗时 ≈ 容量 / (基础 3 + 本表)。
const FARM_PRODUCTION := [0, 2, 4, 6, 8, 12]
const STONE_COST := 50
const STONE_DRAW_PER_ROUND := 1
const STONE_TYPES := ["sky", "land", "ren"]
const FOUR_STAR_COST_VERSION := 1
const FOUR_STAR_GOLD := {1: 500, 2: 800, 3: 1100}

static func four_star_gold(tier: int) -> int:
	return int(FOUR_STAR_GOLD.get(tier, -1))

static func production_for_tech(level: int) -> int:
	return BASE_PRODUCTION + int(HARVEST_TECH_BONUSES[clampi(level, 0, MAX_HARVEST_TECH_LEVEL)])

static func farm_production_bonus(total: int) -> int:
	return int(FARM_PRODUCTION[farm_level_for_spent(total)])

## 每回合总产量 = 基础 + 采集科技加成 + 萝卜田等级加成。
## 所有需要「这一回合能产多少萝卜」的地方都必须走这里，不要单独调
## production_for_tech() —— 那是只含科技的半个答案，漏掉田等级加成不会报错，
## 只会让显示和实发对不上（本作已经为「同一规则两份实现」付过两次学费，
## 见 ShopRoll.gd 顶部与 EconomyService.settle_post_battle_gold() 的注释）。
static func total_production(tech_level: int, spent_total: int) -> int:
	return production_for_tech(tech_level) + farm_production_bonus(spent_total)

static func tech_price(level: int) -> int:
	if level < 0 or level >= HARVEST_TECH_PRICES.size():
		return -1
	return int(HARVEST_TECH_PRICES[level])

static func farm_level_for_spent(total: int) -> int:
	var result := 0
	for level in FARM_THRESHOLDS.size():
		if total >= int(FARM_THRESHOLDS[level]):
			result = level
	return result

static func capacity_for_spent(total: int) -> int:
	return int(FARM_CAPACITIES[farm_level_for_spent(total)])

static func income_for_spent(total: int) -> int:
	return int(FARM_INCOME[farm_level_for_spent(total)])

static func next_threshold_for_spent(total: int) -> int:
	var level := farm_level_for_spent(total)
	return int(FARM_THRESHOLDS[level + 1]) if level + 1 < FARM_THRESHOLDS.size() else -1

static func harvest(carrot_balance: int, spent_total: int, tech_level: int) -> Dictionary:
	var capacity := capacity_for_spent(spent_total)
	var production := total_production(tech_level, spent_total)
	var before := clampi(carrot_balance, 0, capacity)
	var gained := mini(production, capacity - before)
	return {
		"before": before,
		"gain": gained,
		"overflow": production - gained,
		"after": before + gained,
		"production": production,
		"capacity": capacity,
	}

static func valid_stone_type(stone_type: String) -> bool:
	return stone_type in STONE_TYPES

static func empty_stones() -> Dictionary:
	return {"sky": 0, "land": 0, "ren": 0}

static func draw_type_from_roll(roll: float) -> String:
	var bounded := clampf(roll, 0.0, 0.999999)
	return STONE_TYPES[mini(2, int(floor(bounded * 3.0)))]
