class_name EconomyService
extends RefCounted

const BASE_INTEREST_RATE := 0.10
const CONSOLATION_GOLD_PER_LOSS := 2
const BOSS_WIN_REWARDS := {5: 10, 10: 15, 15: 25, 20: 40}
const PVP_WIN_BONUS := 10
const PVP_LOSS_BONUS := 5

static func pve_kill_reward(pve_completed_before: int) -> int:
	return maxi(1, int(floor(float(pve_completed_before) / 2.0)) + 1)

static func pvp_normal_kill_reward(tier: int, star: int) -> int:
	var t := maxi(1, tier)
	match clampi(star, 1, 3):
		1: return t
		2: return t + 2
		_: return t + 3

static func pvp_mercenary_kill_reward(cost: int) -> int:
	# 击杀佣兵的赏金 = 佣兵费用 ÷ 5（5费→1金，10费→2金，以此类推），只给击杀方。
	return int(floor(float(maxi(0, cost)) / 5.0))

static func pvp_result_bonus(player_wins: bool) -> int:
	return PVP_WIN_BONUS if player_wins else PVP_LOSS_BONUS

static func consolation_reward(loss_streak: int) -> int:
	return maxi(0, loss_streak) * CONSOLATION_GOLD_PER_LOSS

static func boss_win_reward(round_index: int) -> int:
	return int(BOSS_WIN_REWARDS.get(round_index, 10))

static func boss_loss_reward(round_index: int, boss_hp_current: int, boss_hp_max: int) -> int:
	var base := boss_win_reward(round_index)
	var pct := clampf(float(boss_hp_current) / float(maxi(1, boss_hp_max)), 0.0, 1.0)
	return maxi(0, base - int(floor(float(base) * pct)))

static func base_interest(gold_before_interest: int) -> int:
	return int(floor(float(gold_before_interest) * BASE_INTEREST_RATE))

# 宠物「猫」的额外利息（在 base_interest 基础上按宠物利息率加成）。pet_id 为空或非猫则为 0。
static func pet_interest_bonus(gold_before_interest: int, pet_id: String) -> int:
	return int(floor(float(maxi(0, gold_before_interest)) * PetService.interest_rate_bonus(pet_id)))

static func escalating_unit_price(step_index: int) -> int:
	var step := maxi(1, step_index)
	var price := 1
	for _i in range(1, step):
		price = int(round(float(price) * 1.5))
	return price

static func shop_refresh_cost(refresh_uses_before: int, all_free: bool) -> int:
	if all_free or refresh_uses_before <= 0:
		return 0
	return escalating_unit_price(refresh_uses_before)
