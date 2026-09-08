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
const STONE_COST := 50
const STONE_DRAW_PER_ROUND := 1
const STONE_TYPES := ["sky", "land", "ren"]

static func production_for_tech(level: int) -> int:
	return BASE_PRODUCTION + int(HARVEST_TECH_BONUSES[clampi(level, 0, MAX_HARVEST_TECH_LEVEL)])

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
	var production := production_for_tech(tech_level)
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
