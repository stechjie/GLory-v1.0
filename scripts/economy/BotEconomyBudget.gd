class_name BotEconomyBudget
extends RefCounted

# 假想敌金币模型的显式版本边界。
#
# 这个模型保留旧版数值，目的不是声称它与真人经济等价，而是先把散落在
# BattleSimShared 里的裸数收口并给回放/量化报告一个可追踪的身份。V12-08 的
# 100-seed 审计会把它与 EconomyService 的真实结算并列；产品确定 Bot 应采用的
# 胜负/击杀前提前，不用一次“看起来合理”的公式静默改难度。
const MODEL_ID := "legacy_estimate_v1"
const BASE_INCOME_PER_ROUND := 5
const KILL_ESTIMATE_BASE := 2
const KILL_ESTIMATE_ROUND_DIVISOR := 3
const INTEREST_BALANCE_CAP := 50
const RESERVE_CAP := 40
const RESERVE_PER_ROUND := 4


static func cumulative_earned(round_index: int) -> int:
	var gold := GameState.START_GOLD
	var earned := gold
	for current_round in range(2, maxi(1, round_index) + 1):
		var interest := int(floor(
			float(mini(gold, INTEREST_BALANCE_CAP)) * EconomyService.BASE_INTEREST_RATE))
		var kill_gold := KILL_ESTIMATE_BASE + current_round / KILL_ESTIMATE_ROUND_DIVISOR
		var income := BASE_INCOME_PER_ROUND + interest + kill_gold
		gold += income
		earned += income
		gold = mini(gold, mini(RESERVE_CAP, RESERVE_PER_ROUND * current_round))
	return earned


# 使用与旧 Bot 相同的“每轮结算后压到 round×4、最多 40 金”储备策略，
# 但收入逐项走 EconomyService。它只用于审计，不直接驱动生产阵容：
# - 结算 round_index 之前已经完成的回合，消除旧模型把当前回合收入提前算入的问题；
# - PVE 假定杀完该轮表内全部怪物；
# - all_wins=true 时每场获胜，false 时每场失败；
# - 不含宝藏、宠物、商人、战斗额外金币和 PVP 击杀金。
# 返回累计收入而不是手头余额，才能与 cumulative_earned 的预算语义比较。
static func canonical_same_reserve_ledger(round_index: int, all_wins: bool) -> Dictionary:
	var gold := GameState.START_GOLD
	var earned := gold
	var loss_streak := 0
	var rows: Array = []
	var monster_counts: Dictionary = DataRegistry.get_table("pve_monsters").get(
		"enemy_count_by_round", {})
	for completed_round in range(1, maxi(1, round_index)):
		var kind := RoundService.schedule_kind_for_round(completed_round)
		var wins := all_wins
		loss_streak = 0 if wins else loss_streak + 1
		var kill_gold := 0
		if kind == "pve":
			kill_gold = maxi(0, int(monster_counts.get(str(completed_round), 3))) \
				* EconomyService.PVE_MONSTER_KILL_GOLD
		var before := gold
		var settled := EconomyService.settle_post_battle_gold({
			"gold_before": before,
			"kill_gold": kill_gold,
			"bonus_gold": 0,
			"kind": kind,
			"player_wins": wins,
			"round_index": completed_round,
			"loss_streak_after": loss_streak,
			"boss_hp_current": 1,
			"boss_hp_max": 1,
			"merchant_gold": 0,
			"treasures": [],
			"pet_id": "",
		})
		var income := settled - before
		earned += income
		gold = mini(settled, mini(RESERVE_CAP, RESERVE_PER_ROUND * (completed_round + 1)))
		rows.append({
			"round": completed_round,
			"kind": kind,
			"wins": wins,
			"kill_gold": kill_gold,
			"income": income,
			"reserve_after_spend": gold,
		})
	return {
		"round_start": maxi(1, round_index),
		"scenario": "all_wins" if all_wins else "all_losses",
		"cumulative_earned": earned,
		"reserve": gold,
		"rows": rows,
	}
