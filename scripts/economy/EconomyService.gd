class_name EconomyService
extends RefCounted

# 金额一律以「进位后」的基数直接书写，不在公式外面套 ×10。
# 比率（利息率、折扣倍率等）不是金额，不随之进位。
const BASE_INTEREST_RATE := 0.10
const CONSOLATION_GOLD_PER_LOSS := 20
const BOSS_WIN_REWARDS := {5: 100, 10: 150, 15: 250, 20: 400}
const BOSS_WIN_REWARD_FALLBACK := 100
const PVP_WIN_BONUS := 100
const PVP_LOSS_BONUS := 50
# PVE 小怪单价：固定值，不随场次成长。PVE 收入的成长已经由另外两处提供——
# 怪数（enemy_count_by_round 从 3 涨到 15）与胜利奖励（回合号从 1 涨到 19）；
# 单价再挂场次就是第三重成长，三者相乘会让中后期金币失控。
const PVE_MONSTER_KILL_GOLD := 15
const PVE_WIN_BONUS_PER_ROUND := 10    # PVE 胜利奖励 = 当前回合号 × 此值
# 下面几个是公式里原本隐含的「每档 1 金」基数——没有字面量可改，
# 因此提成具名常量，直接写进位后的值。
const KILL_GOLD_PER_TIER := 10         # 普通棋子击杀金 = tier 档位 × 此值
const KILL_GOLD_STAR2_BONUS := 20      # 2 星额外
const KILL_GOLD_STAR3_BONUS := 30      # 3 星额外
const MERCHANT_GOLD_PER_STAR := 10     # 商人棋子按星级给金

# PVE 胜利奖励：当前回合号 × 10，只有赢了才给。
# 击杀金（小怪 × PVE_MONSTER_KILL_GOLD）输赢都给，不走这里。
static func pve_win_bonus(round_index: int) -> int:
	return maxi(0, round_index) * PVE_WIN_BONUS_PER_ROUND

static func pvp_normal_kill_reward(tier: int, star: int) -> int:
	var t := maxi(1, tier) * KILL_GOLD_PER_TIER
	match clampi(star, 1, 3):
		1: return t
		2: return t + KILL_GOLD_STAR2_BONUS
		_: return t + KILL_GOLD_STAR3_BONUS

static func pvp_mercenary_kill_reward(cost: int) -> int:
	# 击杀佣兵的赏金 = 佣兵费用 ÷ 5（50费→10金，100费→20金，以此类推），只给击杀方。
	# 佣兵 cost 本身已进位，除数 5 是比例不是金额，故不动。
	return int(floor(float(maxi(0, cost)) / 5.0))

static func pvp_result_bonus(player_wins: bool) -> int:
	return PVP_WIN_BONUS if player_wins else PVP_LOSS_BONUS

static func consolation_reward(loss_streak: int) -> int:
	return maxi(0, loss_streak) * CONSOLATION_GOLD_PER_LOSS

static func boss_win_reward(round_index: int) -> int:
	return int(BOSS_WIN_REWARDS.get(round_index, BOSS_WIN_REWARD_FALLBACK))

static func boss_loss_reward(round_index: int, boss_hp_current: int, boss_hp_max: int) -> int:
	var base := boss_win_reward(round_index)
	var pct := clampf(float(boss_hp_current) / float(maxi(1, boss_hp_max)), 0.0, 1.0)
	return maxi(0, base - int(floor(float(base) * pct)))

static func base_interest(gold_before_interest: int) -> int:
	return int(floor(float(gold_before_interest) * BASE_INTEREST_RATE))

# 宠物「猫」的额外利息（在 base_interest 基础上按宠物利息率加成）。pet_id 为空或非猫则为 0。
static func pet_interest_bonus(gold_before_interest: int, pet_id: String) -> int:
	return int(floor(float(maxi(0, gold_before_interest)) * PetService.interest_rate_bonus(pet_id)))

# 3v3 的击杀金币按座位记账（result.kill_gold_by_slot），每人只拿自己打死的那份。
# 实际结算（Main / NetworkService）与结算面板（BattleUI）必须取同一个值，
# 否则面板显示的是全队总额、到账的却只有自己那份。
static func kill_gold_for_slot(result: Dictionary, slot: int) -> int:
	var by_slot: Dictionary = result.get("kill_gold_by_slot", {})
	var s := maxi(0, slot)
	return int(by_slot.get(s, by_slot.get(str(s), 0)))

# 商人棋子（post_battle_gold_by_star）：棋盘上每个商人按星级给金。
# board 既可以是 GameState.board_slots，也可以是 NetProtocol.extract_board(snapshot)
# 的服务器端棋盘——两者的格子都带 def 与 star。
static func merchant_gold_from_board(board: Array) -> int:
	var total := 0
	for cell in board:
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var c: Dictionary = cell
		if str((c.get("def", {}) as Dictionary).get("skill_id", "")) == "post_battle_gold_by_star":
			total += clampi(int(c.get("star", 1)), 1, GameState.MAX_UNIT_STAR) * MERCHANT_GOLD_PER_STAR
	return total

# 战后金币结算——唯一实现，返回结算后的总金币。
# 本地/房主（Main._on_team_battle_finished）与专用服务器
# （NetworkService._server_gold_after_battle）都必须调用它：两处过去各写各的，
# 结果实际到账只有「击杀金币 + bonus_gold + 5」，而 BattleUI 的结算面板却按本文件
# 的公式显示 PVE/Boss/胜负/安慰金，玩家看到的和拿到的对不上。
# 累加顺序与 docs/金币系统.md「战后金币结算顺序」一致。
# ctx 键：gold_before, kill_gold, bonus_gold, kind, player_wins, round_index,
#         loss_streak_after, boss_hp_current, boss_hp_max,
#         merchant_gold, treasures(Array), pet_id(String)
static func settle_post_battle_gold(ctx: Dictionary) -> int:
	var gold := maxi(0, int(ctx.get("gold_before", 0)))
	var kind := str(ctx.get("kind", "pve"))
	var player_wins := bool(ctx.get("player_wins", false))
	var kill_gold := maxi(0, int(ctx.get("kill_gold", 0)))
	var treasures: Array = ctx.get("treasures", [])
	# (1)(2)(3) 战斗类型基础奖励 / 补偿 + 击杀金币 + 胜负固定奖励。
	# Boss 局按设计只给固定奖励与补偿，不结算击杀金币。
	# PVE：击杀金输赢都给，只有回合奖励是胜利专属。
	match kind:
		"pve":
			gold += kill_gold
			if player_wins:
				gold += pve_win_bonus(int(ctx.get("round_index", 0)))
		"boss":
			var round_index := int(ctx.get("round_index", 0))
			if player_wins:
				gold += boss_win_reward(round_index)
			else:
				gold += boss_loss_reward(round_index, int(ctx.get("boss_hp_current", 0)), maxi(1, int(ctx.get("boss_hp_max", 1))))
		"pvp", "final":
			gold += kill_gold + pvp_result_bonus(player_wins)
	# (4) 败方安慰金：loss_streak_after 是本场结算后的连败数（胜利时调用方已清零）。
	if not player_wins:
		gold += consolation_reward(int(ctx.get("loss_streak_after", 0)))
	# (5) 商人战后金币
	gold += maxi(0, int(ctx.get("merchant_gold", 0)))
	# (6) 战斗额外金币（富裕之路等战斗内产出）
	gold += maxi(0, int(ctx.get("bonus_gold", 0)))
	# (7) 宝藏战后金币。随机档位之间相隔 10 金：幸运信封 10/20/30，金钱魔法 50/60/70。
	if treasures.has("money_lucky_envelope"):
		gold += 10 + (randi() % 3) * 10
	if TreasureService.has_linkage_in(treasures, "link_money_magic"):
		gold += 50 + (randi() % 3) * 10
		if randf() < 0.10:
			gold += 100
	# (8) 利息
	var interest := base_interest(gold)
	if treasures.has("money_compound"):
		interest += int(floor(float(gold) * 0.05))
	interest += pet_interest_bonus(gold, str(ctx.get("pet_id", "")))
	gold += interest
	return maxi(0, gold)

# 商店刷新的递增价：首价 10 金，之后每次翻倍 → 10, 20, 40, 80, 160, 320…
# 翻倍是整数运算，不再需要旧的 round(×1.5)。
static func escalating_unit_price(step_index: int) -> int:
	var step := maxi(1, step_index)
	var price := 10
	for _i in range(1, step):
		price *= 2
	return price

static func shop_refresh_cost(refresh_uses_before: int, all_free: bool) -> int:
	if all_free or refresh_uses_before <= 0:
		return 0
	return escalating_unit_price(refresh_uses_before)
