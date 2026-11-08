extends RefCounted
## 线上 AI 座位的大脑：匹配补位、自定义房间的 AI、掉线托管（LiveBotEconomy 驱动，状态跨回合保存）。
##
## 每回合的步骤和真人一样：采集萝卜 → 四星 → 采集科技 → 萝卜（抽升级石 / 叫佣兵）→ 商店（买、合成、
## 刷新、卖）→ 宝藏（3 选 1）→ 选人上阵、站位。所有花钱的规则都调同一份 EconomyLedger / EconomyService。
##
## 11-07：五档难度。每一步「怎么选」都按档位参数走（data/ai/bot_profiles.json，读法见 ai/BotProfile.gd）：
## 买牌按阵容估值涨多少（ai/BotEval.gd）、萝卜在攒石头和叫佣兵之间取舍（ai/BotCarrots.gd，含
## 「AI 抽的石头放 2 回合让真人先用」）、站位按坦克 / 输出 / 辅助（ai/BotFormation.gd）。
## 困难 / 大师和普通只差采集科技上限（11-08 对战台逐项量过，别的「高级」设置都没有可测的好处）。
## 档位只改决策，**不改任何战斗数值、不多拿钱、不看隐藏信息**。
##
## 没有线上状态时的「从第 1 回合推演到当前回合」（教学局、预览、审计、冷启动兜底）用 11-07 之前的
## 那一版：ai/LegacyBotPlayer.gd（教学数值按它调过，手机上也便宜）。
##
## 确定性：只用 hash(seed, 座位号) 播种的独立 RNG，结果只取决于
## shared_seed + 座位号 + 回合号 —— 所有客户端算出同一个假想敌，也不消耗
## RngService.rng，战斗随机流不受影响。纯函数，结果按 key 缓存。
##
## 不用 class_name：新增全局类要靠编辑器导入才进 global_script_class_cache，
## 由 BattleSimShared 直接 preload。

const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
const CarrotRules := preload("res://scripts/economy/CarrotEconomy.gd")
const Handover := preload("res://scripts/economy/AiHandover.gd")
const RaceRules := preload("res://scripts/units/RacePick.gd")
const Profile := preload("res://scripts/economy/ai/BotProfile.gd")
const Eval := preload("res://scripts/economy/ai/BotEval.gd")
const Carrots := preload("res://scripts/economy/ai/BotCarrots.gd")
const Formation := preload("res://scripts/economy/ai/BotFormation.gd")
const Legacy := preload("res://scripts/economy/ai/LegacyBotPlayer.gd")

const SHOP_SLOTS := 4
const BENCH_CAP := 8
const CACHE_LIMIT := 64
# 买牌时对主种族 / 第二种族的偏好（在估值涨幅上再乘）。
const MAIN_RACE_BIAS := 1.2
const SECOND_RACE_BIAS := 1.08
# 卖牌时已上阵的棋子按强度的几倍算（轻易不卖上阵的）。
const FIELDED_KEEP_WEIGHT := 3.0
# 决赛全花：刷新次数放开到这么多、刷完至少还剩这么多金（还买得起一张一费卡）。
const FINAL_PUSH_REFRESHES := 12
const FINAL_PUSH_MARGIN := 20
# 从这一回合起，lineup 档不再拿经济宝藏。
const LATE_MONEY_ROUND := 12

static var _cache: Dictionary = {}
# 一次备战里同一套阵容的估值只算一次（_prep_round 开头清空）。商店刷新后、买牌前后
# 会反复估「现在这套」和「买了某张之后那套」，大部分都重复。键 = 上阵上限 + 每个棋子的 id:星级。
static var _value_memo: Dictionary = {}


## 返回 {board: Array(16), mercs: Array, treasures: Array, syn: Dictionary,
##       gold: int, main_race: String, stones: Dictionary}
static func state_for(seed: Variant, slot: int, round_n: int) -> Dictionary:
	# Real matches carry their own persistent economy; historical simulation is
	# only a fallback for previews/audits without a running room.
	# Tutorial AI deliberately uses its scripted roster and outcome plan instead.
	var live: Dictionary = NetworkService.team_bot_states.get(slot, {})
	if not GameState.tutorial_mode and int(live.get("round", -1)) == round_n and str(live.get("battle_seed", live.get("seed", ""))) == str(seed):
		return view(live)
	var key := state_cache_key(seed, slot, round_n)
	if _cache.has(key):
		return _cache[key]
	if _cache.size() >= CACHE_LIMIT:
		_cache.clear()
	var result := _simulate(seed, slot, maxi(1, round_n))
	_cache[key] = result
	return result


# The scheduler and state_for must use the same identity. Tutorial rules and
# final-round variants deliberately own separate deterministic fallback states.
static func state_cache_key(seed: Variant, slot: int, round_n: int) -> String:
	return "%s/%d/%d/%s/%d" % [str(seed), slot, round_n,
		"tutorial" if GameState.tutorial_mode else "normal", GameState.FINAL_ROUND]


# Query only: never generate a board or allocate a live-state presentation view.
# A stale live entry must not bypass incremental fallback preparation.
static func has_cached_state(seed: Variant, slot: int, round_n: int) -> bool:
	var live: Dictionary = NetworkService.team_bot_states.get(slot, {})
	if not GameState.tutorial_mode and int(live.get("round", -1)) == round_n and str(live.get("battle_seed", live.get("seed", ""))) == str(seed):
		return true
	return _cache.has(state_cache_key(seed, slot, round_n))


static func clear_cache() -> void:
	_cache.clear()


# Persistent state for live games. No estimated wins, kills or future income.
static func new_state(seed: Variant, slot: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(["glory_live_bot_v2", str(seed), slot])
	var races := _races(DataRegistry.get_table("race_units").get("units", []))
	while races.size() > RaceRules.required_count():
		races.remove_at(rng.randi_range(0, races.size() - 1))
	return {"seed": str(seed), "slot": slot, "round": 0, "settled_round": 0,
		"races": races,
		"gold": GameState.START_GOLD, "roster": [], "treasures": [],
		"stones": CarrotRules.empty_stones(), "stones_gained": CarrotRules.empty_stones(),
		"carrots": 0, "carrot_spent": 0, "tech": 0, "stone_draws": 0, "own_stones": [],
		"loss_streak": 0, "mercs": [], "gold_spent_this_round": false,
		"main_race": races[rng.randi_range(0, races.size() - 1)] if not races.is_empty() else ""}


static func prepare_round(bot: Dictionary, round_index: int) -> void:
	if int(bot.get("round", 0)) >= round_index:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(["glory_live_bot_prep_v2", bot.seed, bot.slot, round_index])
	# 佣兵只活一轮。但 AI 接管真人座位是**半路**接手 —— 那一轮雇的佣兵还在场上，
	# 必须留着（merc_round 记着它是哪一轮搬进来的），下一轮才照常清空。
	if int(bot.get("merc_round", -1)) != round_index:
		bot.mercs = []
	if int(bot.get("skip_reset_spending_round", -1)) != round_index:
		bot.gold_spent_this_round = false
	var ledger := {"carrots": int(bot.carrots), "merc_carrots_spent_total": int(bot.carrot_spent),
		"harvest_tech_level": int(bot.tech), "last_harvest_round": int(bot.get("round", 0))}
	if int(bot.get("skip_harvest_round", -1)) != round_index:
		EconomyLedger.harvest_for_round(ledger, round_index, float(bot.get("carrot_bonus_rate", 0.0)))
	bot.carrots = int(ledger.carrots)
	if int(bot.get("skip_harvest_round", -1)) != round_index:
		bot["harvest_gain"] = int(ledger.get("last_harvest_gain", 0))
	_prep_round(bot, round_index, rng, RaceRules.shop_pool(
		DataRegistry.get_table("race_units").get("units", []), bot.get("races", RaceRules.default_races())))
	# 佣兵也要 uid：账本是按 uid 记账的，没有 uid 的佣兵 mirror 不出去、
	# 玩家收回座位时也就看不到（10.17 第 1 条）。
	for unit in (bot.roster as Array) + (bot.mercs as Array):
		if str(unit.get("uid", "")).is_empty():
			var serial := int(bot.get("next_uid", 0)) + 1
			bot["next_uid"] = serial
			var used := {}
			for other in (bot.roster as Array) + (bot.mercs as Array):
				used[str(other.get("uid", ""))] = true
			while used.has("bot_%s_%s" % [str(bot.slot), str(serial)]):
				serial += 1
			bot["next_uid"] = serial
			unit["uid"] = "bot_%s_%s" % [str(bot.slot), str(serial)]
	bot["merc_round"] = round_index
	bot.round = round_index


static func view(bot: Dictionary) -> Dictionary:
	var board := _arrange_board(bot)
	var counts := {}
	for cell in board:
		if cell is Dictionary:
			var race := str(cell.def.get("race", ""))
			counts[race] = int(counts.get(race, 0)) + 1
	return {"board": board, "mercs": (bot.mercs as Array).duplicate(true),
		"treasures": (bot.treasures as Array).duplicate(), "syn": SynergyService.flags_from_counts(counts),
		"gold": int(bot.gold), "stones": bot.stones.duplicate(), "stones_gained": bot.stones_gained.duplicate(),
		"main_race": str(bot.main_race), "gold_spent_this_round": bool(bot.get("gold_spent_this_round", false))}


static func settle_round(bot: Dictionary, result: Dictionary, context: Dictionary) -> Dictionary:
	var round_index := int(context.get("round_index", bot.round))
	if int(bot.get("settled_round", 0)) >= round_index:
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(["glory_live_bot_settle_v2", bot.seed, bot.slot, round_index])
	bot.loss_streak = 0 if bool(context.get("player_wins", false)) else int(bot.loss_streak) + 1
	var ctx := context.duplicate()
	ctx.merge({"gold_before": int(bot.gold), "kill_gold": EconomyService.kill_gold_for_slot(result, int(bot.slot)),
		"bonus_gold": int(result.get("bonus_gold", 0)), "loss_streak_after": int(bot.loss_streak),
		"boss_hp_current": int(result.get("enemy_hp_current", 0)), "boss_hp_max": maxi(1, int(result.get("enemy_hp_max", 1))),
		"merchant_gold": EconomyService.merchant_gold_from_board(_arrange_board(bot)),
		"treasures": bot.treasures, "gold_spent_this_round": bool(bot.get("gold_spent_this_round", false)),
		"camp_income": CarrotRules.income_for_spent(int(bot.carrot_spent)),
		"pet_id": str(bot.get("pet_id", "")), "rng": rng}, true)
	var settlement := EconomyService.settle_post_battle_breakdown(ctx)
	bot.gold = int(settlement.gold_after)
	bot.settled_round = round_index
	# PvP 输了，下一场左右翻转站位换一种对位（flip_on_loss 的档位才用，见 _arrange_board）。
	var kind := str(context.get("kind", ""))
	if (kind == "pvp" or kind == "final") and not bool(context.get("player_wins", false)):
		bot["formation_flip"] = not bool(bot.get("formation_flip", false))
	if RoundService.is_treasure_round(round_index) and not bool(bot.get("server_treasures", false)):
		_pick_treasure(bot, rng)
	return settlement


# ---------------------------------------------------------------- 后备推演

# 没有线上状态时（教学局、预览、审计、冷启动兜底）从第 1 回合推到当前回合：
# 用 11-07 之前的那一版（LegacyBotPlayer），理由见那个文件的开头。
static func _simulate(seed: Variant, slot: int, round_n: int) -> Dictionary:
	return Legacy._simulate(seed, slot, round_n)


static func _races(units: Array) -> Array[String]:
	var out: Array[String] = []
	for u in units:
		var race := str((u as Dictionary).get("race", ""))
		if not race.is_empty() and not out.has(race):
			out.append(race)
	out.sort()
	return out


# ---------------------------------------------------------------- 备战

# 决策噪声和抽石开奖用的 RNG，与摇商店的那一条分开：AI 多想一步、少想一步，
# 都不该改变它接下来刷出来的货（否则对战台比较两档时混进了商店运气）。
static func _decide_rng(bot: Dictionary, round_index: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(["glory_bot_decide_v1", str(bot.get("seed", "")), int(bot.get("slot", -1)), round_index])
	return rng


static func _reserve(bot: Dictionary, round_index: int, profile: Dictionary = {}) -> int:
	var p := profile if not profile.is_empty() else Profile.for_bot(bot)
	if round_index <= 2:
		return 0
	if bool(p.final_all_in) and round_index >= int(bot.get("final_round", 21)):
		return 0
	var reserve := 0
	var losing := int(bot.get("loss_streak", 0)) >= 2
	match str(p.reserve):
		"flat":
			reserve = int(p.flat_reserve)
		"interest":
			# 利息 5% 不封顶：平时攒着，Boss / PvP 回合和连败时花出去。
			reserve = clampi(round_index * 10, 30, 200)
			if losing or Carrots.important_round(round_index):
				reserve /= 2
		"plan":
			# 关键回合（Boss / PvP / 决赛）前一回合多攒一点，关键回合当回合花下去。
			reserve = clampi(40 + round_index * 12, 40, 300)
			if losing or Carrots.important_round(round_index):
				reserve /= 4
			elif Carrots.important_round(round_index + 1):
				reserve = int(reserve * 1.2)
	# 有可用的石头和三星 → 把四星的金币留出来。试过「四星只花多出来的钱」（11-07 第四批）：
	# 四星从每座位 0.8 个掉到 0.1 个，对旧 AI 胜率 80% → 63%，三星也没因此多起来 —— 四星值这个钱。
	var target := _four_star_candidate(bot, round_index, p)
	if not target.is_empty():
		reserve += _four_star_cost(bot, target)
	return reserve


static func _prep_round(bot: Dictionary, round_index: int, rng: RandomNumberGenerator, units: Array) -> void:
	var p := Profile.for_bot(bot)
	var decide := _decide_rng(bot, round_index)
	_value_memo.clear()
	if (bot.treasures as Array).has("money_generous_fate") and int(bot.gold) >= 100 and int(bot.get("gamble_used_round", -1)) != round_index:
		var gamble := {"gold": int(bot.gold), "gamble_used": false}
		EconomyLedger.apply(gamble, "gamble", {}, {"gamble_entitled": true,
			"gamble_linked": TreasureService.has_linkage_in(bot.treasures, "link_fraud_fate"), "roll": rng.randf()})
		bot.gold = int(gamble.gold)
		bot["gamble_used_round"] = round_index
	_update_direction(bot, round_index, p)
	_try_four_star(bot, round_index, p)
	_try_tech(bot, round_index, p)
	Carrots.spend(bot, round_index, decide, p)
	_shop_phase(bot, round_index, rng, decide, units, p)
	_update_direction(bot, round_index, p)
	_try_four_star(bot, round_index, p)


static func _shop_phase(bot: Dictionary, round_index: int, rng: RandomNumberGenerator,
		decide: RandomNumberGenerator, units: Array, p: Dictionary) -> void:
	# 商店：接管真人的座位用**玩家那一批**（bot.shop 由 LiveBotEconomy 从账本搬来），
	# 纯 bot 座位才自己摇。以前一律 _roll_shop() 重摇，于是玩家回来看到的是一批
	# 从没被 AI 花过钱的货 —— 商店状态和 AI 打的那一轮对不上（10.17 第 1 条）。
	var shop := _shop_for_round(bot, round_index, units, rng)
	var final_push := bool(p.final_all_in) and round_index >= int(bot.get("final_round", 21))
	var max_refresh := maxi(int(p.max_refresh), FINAL_PUSH_REFRESHES) if final_push else int(p.max_refresh)
	var margin := FINAL_PUSH_MARGIN if final_push else int(p.refresh_margin)
	var refreshes := 0
	while true:
		_buy_from_shop(bot, shop, round_index, decide, p)
		if refreshes >= max_refresh:
			break
		var refresh_cost := EconomyService.shop_refresh_cost(int(shop.get("refresh_uses", 0)), false)
		if int(bot.gold) - _reserve(bot, round_index, p) < refresh_cost + margin:
			break
		bot.gold = int(bot.gold) - refresh_cost
		if refresh_cost > 0:
			bot.gold_spent_this_round = true
		refreshes += 1
		_roll_shop_into(bot, shop, units, round_index, rng)


# 一批货里反复挑「买了之后阵容估值涨得最多」的那一格，直到没有值得买的或钱不够。
static func _buy_from_shop(bot: Dictionary, shop: Dictionary, round_index: int,
		decide: RandomNumberGenerator, p: Dictionary) -> void:
	var horizon := maxi(0, int(bot.get("final_round", 21)) - round_index)
	while true:
		var offers: Array = shop["offers"]
		var sold: Array = shop["sold"]
		var base := _roster_score(bot.roster, bot, p, horizon)
		var reserve := _reserve(bot, round_index, p)
		var best := -1
		var best_value := 0.0
		var best_cost := 0
		for i in offers.size():
			var offer: Dictionary = offers[i] if typeof(offers[i]) == TYPE_DICTIONARY else {}
			if offer.is_empty() or (i < sold.size() and bool(sold[i])):
				continue
			# 唯一棋子：已有就不再买。
			if bool(offer.get("unique_on_board", false)) and _copies(bot, str(offer.get("id", ""))) > 0:
				continue
			var cost := EconomyLedger.unit_cost(offer, bot.treasures, bool(bot.get("team_discount", false)))
			if int(bot.gold) - cost < reserve:
				continue
			var value := _offer_gain(bot, offer, cost, base, p, horizon)
			# 冲动消费（新手 / 简单）：看着顺眼就买，不管阵容用不用得上 —— 备战席塞满了就半价卖掉
			# 最差的那个。这是新手真实的样子（乱花钱），而不是攒着不花（11-07 首批实测：
			# 只买严格变强的新手会囤 7800 金，利息不封顶，越滚越多）。
			var impulse := float(p.get("impulse", 0.0))
			if impulse > 0.0:
				value = maxf(value, 0.0) + impulse * Eval.unit_power(offer, 1) * decide.randf()
			value *= 1.0 + float(p.noise) * decide.randfn()
			value -= float(p.buy_threshold) * cost
			if value > best_value:
				best_value = value
				best = i
				best_cost = cost
		if best < 0:
			return
		var offer: Dictionary = offers[best]
		bot.gold = int(bot.gold) - best_cost
		bot.gold_spent_this_round = true
		(bot.roster as Array).append({"id": str(offer.get("id", "")), "star": 1, "def": offer, "cost_basis": best_cost})
		# 卖掉的那一格只打 sold 标记、**不清空** offer：账本里的商店要原样
		# 留给回来的玩家（客户端按 sold 格置灰，和真人买过之后一模一样）。
		if best < sold.size():
			sold[best] = true
			shop["sold"] = sold
		_merge(bot)
		_trim_roster(bot, p, horizon)


static func _roster_score(roster: Array, bot: Dictionary, p: Dictionary, horizon: int) -> float:
	var cap := Handover.board_cap(bot.treasures)
	var parts: PackedStringArray = []
	for u in roster:
		parts.append("%s:%d" % [u.id, int(u.star)])
	parts.sort()
	var key := "%d|%d|%s" % [cap, int(p.level), ",".join(parts)]
	var cached: Variant = _value_memo.get(key)
	if cached != null:
		return float(cached)
	var value := Eval.roster_value(roster, cap, int(p.synergy_knowledge), float(p.merge_weight), horizon)
	_value_memo[key] = value
	return value


# 买下这一格之后（合成、超出备战席就卖掉最不值钱的那个）阵容估值涨多少。
static func _offer_gain(bot: Dictionary, offer: Dictionary, cost: int, base: float, p: Dictionary, horizon: int) -> float:
	var id := str(offer.get("id", ""))
	var trial := {"roster": (bot.roster as Array).duplicate(), "treasures": bot.treasures}
	var owned_copy := false
	for u in bot.roster:
		if str(u.id) == id and int(u.star) < GameConstants.MAX_MERGE_STAR:
			owned_copy = true
			break
	(trial.roster as Array).append({"id": id, "star": 1, "def": offer, "cost_basis": cost})
	_merge(trial)
	var cap := Handover.board_cap(bot.treasures) + BENCH_CAP
	while (trial.roster as Array).size() > cap:
		(trial.roster as Array).remove_at(_least_valuable(trial.roster, bot, p, horizon))
	var gain := _roster_score(trial.roster, bot, p, horizon) - base
	if gain <= 0.0:
		return gain
	# 方向偏好：主种族 / 第二种族；已有同名的（离升星更近）再往上抬。
	var race := str(offer.get("race", ""))
	if race == str(bot.main_race):
		gain *= MAIN_RACE_BIAS
	elif race == str(bot.get("second_race", "")):
		gain *= SECOND_RACE_BIAS
	if owned_copy:
		gain *= float(p.get("owned_bonus", 1.0))
	return gain


# 最该卖的那个：没上阵、离升星最远、强度最低。只在超出备战席时调用。
static func _least_valuable(roster: Array, bot: Dictionary, p: Dictionary, horizon: int) -> int:
	var fielded := {}
	for i in Eval.pick_board_indices(roster, Handover.board_cap(bot.treasures), int(p.synergy_knowledge)):
		fielded[i] = true
	var copies := {}
	for u in roster:
		if int(u.star) < GameConstants.MAX_MERGE_STAR:
			copies[str(u.id)] = int(copies.get(str(u.id), 0)) + (1 if int(u.star) == 1 else GameConstants.copies_to_upgrade(1))
	var worst := 0
	var worst_value := INF
	for i in roster.size():
		var u: Dictionary = roster[i]
		var value := Eval.unit_power(u.def, int(u.star))
		if fielded.has(i):
			value *= FIELDED_KEEP_WEIGHT
		# 凑了一半的同名棋子轻易不卖：每多一份当量，按凑星权重抬高保留价值。
		if int(u.star) < GameConstants.MAX_MERGE_STAR and horizon > 0:
			value *= 1.0 + float(p.merge_weight) * 0.5 * float(int(copies.get(str(u.id), 1)) - 1)
		if value < worst_value or (value == worst_value and str(u.id) > str(roster[worst].id)):
			worst_value = value
			worst = i
	return worst


# 这一轮要用的商店。接管来的那一批只在**同一轮**有效：bot.shop 记着自己属于哪一轮，
# 跨轮就作废（新的一轮由服务端 _room_begin_next_prep 重新摇好、再搬进来）。
static func _shop_for_round(bot: Dictionary, round_index: int, units: Array, rng: RandomNumberGenerator) -> Dictionary:
	var inherited: Variant = bot.get("shop", {})
	if typeof(inherited) == TYPE_DICTIONARY:
		var shop: Dictionary = inherited
		var offers: Array = shop.get("offers", [])
		if int(shop.get("round", -1)) == round_index and not offers.is_empty():
			shop["offers"] = offers.duplicate(true)
			var sold: Array = (shop.get("sold", []) as Array).duplicate()
			while sold.size() < offers.size():
				sold.append(false)
			shop["sold"] = sold
			shop["refresh_uses"] = int(shop.get("refresh_uses", 0))
			bot["shop"] = shop
			return shop
	var fresh := {"round": round_index, "offer_id": "", "slot": int(bot.get("slot", -1)),
		"refresh_uses": 0, "offers": [], "sold": []}
	_roll_shop_into(bot, fresh, units, round_index, rng, false)
	return fresh


# 摇一批新货架进 shop。`bump` 区分"本轮第一次摇"（refresh_uses 保持 0）和"花钱刷新"。
static func _roll_shop_into(bot: Dictionary, shop: Dictionary, units: Array, round_index: int,
		rng: RandomNumberGenerator, bump: bool = true) -> void:
	if bump:
		shop["refresh_uses"] = int(shop.get("refresh_uses", 0)) + 1
	var offers := _roll_shop(units, round_index, rng, int(bot.get("final_round", 21)))
	shop["offers"] = offers
	var sold: Array = []
	sold.resize(offers.size())
	sold.fill(false)
	shop["sold"] = sold
	shop["round"] = round_index
	# offer_id 变了客户端才会重新采纳这批商店（PrepBoardController._adopt_server_shop）。
	shop["offer_id"] = "bot_%d_%d_%d" % [int(bot.get("slot", -1)), round_index,
		int(shop.get("refresh_uses", 0))]
	bot["shop"] = shop


static func _roll_shop(units: Array, round_index: int, rng: RandomNumberGenerator,
		final_round: int = 21) -> Array:
	var out: Array = []
	for _i in SHOP_SLOTS:
		out.append(ShopRoll.pick_offer(units, round_index, rng.randf(), rng.randf(), final_round))
	return out


static func _copies(bot: Dictionary, id: String) -> int:
	var n := 0
	for u in bot.roster:
		if str(u.id) == id:
			n += 1
	return n


static func _merge(bot: Dictionary) -> void:
	var changed := true
	while changed:
		changed = false
		for star in range(1, GameConstants.MAX_MERGE_STAR):
			var need := GameConstants.copies_to_upgrade(star)
			var groups := {}
			for i in (bot.roster as Array).size():
				var u: Dictionary = bot.roster[i]
				if int(u.star) != star:
					continue
				var key := str(u.id)
				if not groups.has(key):
					groups[key] = []
				(groups[key] as Array).append(i)
			var keys := groups.keys()
			keys.sort()
			for key in keys:
				var idxs: Array = groups[key]
				if idxs.size() < need:
					continue
				var take := idxs.slice(0, need)
				var basis := 0
				var keeper: Dictionary = bot.roster[int(take[0])].duplicate()
				var def_ref: Dictionary = keeper.def
				for i in take:
					basis += int(bot.roster[int(i)].cost_basis)
				take.sort()
				take.reverse()
				for i in take:
					(bot.roster as Array).remove_at(int(i))
				# As in the player ledger, the keeper survives a merge. Retain its
				# identity so reconnect snapshots do not invent a replacement unit.
				keeper.merge({"id": str(key), "star": star + 1, "def": def_ref, "cost_basis": basis}, true)
				(bot.roster as Array).append(keeper)
				changed = true
				break
			if changed:
				break


static func _trim_roster(bot: Dictionary, profile: Dictionary = {}, horizon: int = 10) -> void:
	var p := profile if not profile.is_empty() else Profile.for_bot(bot)
	var cap := Handover.board_cap(bot.treasures) + BENCH_CAP
	while (bot.roster as Array).size() > cap:
		var worst := _least_valuable(bot.roster, bot, p, horizon)
		var sold: Dictionary = bot.roster[worst]
		bot.gold = int(bot.gold) + EconomyLedger.sell_refund(int(sold.cost_basis))
		(bot.roster as Array).remove_at(worst)


static func _update_second_race(bot: Dictionary) -> void:
	var counts := {}
	for u in bot.roster:
		var race := str((u.def as Dictionary).get("race", ""))
		if race == str(bot.main_race):
			continue
		counts[race] = int(counts.get(race, 0)) + 1
	var best := ""
	var best_n := 0
	var keys := counts.keys()
	keys.sort()
	for race in keys:
		if int(counts[race]) > best_n:
			best_n = int(counts[race])
			best = str(race)
	bot["second_race"] = best


# 主种族：random 开局定了不改；owned 第 3–8 回合跟着手上最多的那一族；
# eval 按手上各族的强度合计，别的族比现在的强出 pivot_margin 倍就转。
static func _update_direction(bot: Dictionary, round_index: int, p: Dictionary) -> void:
	match str(p.direction):
		"owned":
			if round_index >= 3 and round_index <= 8:
				prioritize_owned_races(bot)
				return
		"eval":
			if round_index >= 3 and not (bot.roster as Array).is_empty():
				var scores := {}
				for u in bot.roster:
					var race := str((u.def as Dictionary).get("race", ""))
					scores[race] = float(scores.get(race, 0.0)) + Eval.unit_power(u.def, int(u.star))
				var best := str(bot.main_race)
				var races := scores.keys()
				races.sort()
				for race in races:
					if float(scores[race]) > float(scores.get(best, 0.0)):
						best = str(race)
				if best != str(bot.main_race) and float(scores[best]) > maxf(1.0, float(scores.get(str(bot.main_race), 0.0))) * float(p.pivot_margin):
					bot["main_race"] = best
	_update_second_race(bot)


static func _try_tech(bot: Dictionary, round_index: int, p: Dictionary) -> void:
	if round_index < 3 or int(bot.tech) >= int(p.tech_cap):
		return
	var price := CarrotRules.tech_price(int(bot.tech))
	if int(bot.gold) - _reserve(bot, round_index, p) >= price + int(p.tech_margin):
		bot.gold = int(bot.gold) - price
		bot.gold_spent_this_round = true
		bot.tech = int(bot.tech) + 1


static func _four_star_cost(bot: Dictionary, target: Dictionary) -> int:
	if str(bot.get("ruleset", "normal")) == "seedling":
		return CarrotRules.seedling_four_star_gold(int(bot.get("four_star_upgrade_count", 0)))
	return CarrotRules.four_star_gold(int((target.def as Dictionary).get("tier", 1)))


# 现在就能升四星的三星：同属性的石头按队伍规则可用（BotCarrots.usable_stone_count）。
# greedy 取找到的第一个，value 取升完强度涨得最多的。商人这类经济棋子不值得花 500+ 金。
static func _four_star_candidate(bot: Dictionary, round_index: int, p: Dictionary) -> Dictionary:
	if str(p.four_star) == "none":
		return {}
	var best: Dictionary = {}
	var best_gain := -1.0
	for u in bot.roster:
		if int(u.star) != GameConstants.MAX_MERGE_STAR:
			continue
		if str((u.def as Dictionary).get("skill_id", "")) == "post_battle_gold_by_star":
			continue
		var element := str((u.def as Dictionary).get("element", ""))
		if not CarrotRules.valid_stone_type(element) or Carrots.usable_stone_count(bot, element, round_index) <= 0:
			continue
		if str(p.four_star) == "greedy":
			return u
		var gain := Eval.unit_power(u.def, GameConstants.MAX_STAR) - Eval.unit_power(u.def, GameConstants.MAX_MERGE_STAR)
		if gain > best_gain:
			best_gain = gain
			best = u
	return best


static func _try_four_star(bot: Dictionary, round_index: int, p: Dictionary) -> void:
	var target := _four_star_candidate(bot, round_index, p)
	if target.is_empty():
		return
	var cost := _four_star_cost(bot, target)
	if cost < 0 or int(bot.gold) < cost:
		return
	var element := str((target.def as Dictionary).get("element", ""))
	bot.gold = int(bot.gold) - cost
	bot.gold_spent_this_round = true
	Carrots.take_stone(bot, element)
	target.star = GameState.MAX_UNIT_STAR
	if str(bot.get("ruleset", "normal")) == "seedling":
		bot["four_star_upgrade_count"] = int(bot.get("four_star_upgrade_count", 0)) + 1


# ---------------------------------------------------------------- 宝藏

static func _pick_treasure(bot: Dictionary, rng: RandomNumberGenerator) -> void:
	var owned: Array = bot.treasures
	if owned.size() >= TreasureService.MAX_OWNED:
		return
	var pool: Array[String] = []
	for t in DataRegistry.get_table("treasures").get("treasures", []):
		var tid := str((t as Dictionary).get("id", ""))
		if not tid.is_empty() and not owned.has(tid):
			pool.append(tid)
	if pool.is_empty():
		return
	# 与真人一样 3 选 1。
	for i in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	var candidates := pool.slice(0, mini(3, pool.size()))
	var best := preferred_treasure(bot, candidates)
	if not best.is_empty():
		owned.append(best)


# random：不看就拿（按座位和已有件数定一个，结果可复现）；set：往 4 件套 / 联动凑；
# lineup：再看自己阵容 —— 多一个上阵位（狂怒名册）最值钱，后期不再拿经济宝藏。
static func preferred_treasure(bot: Dictionary, candidates: Array) -> String:
	if candidates.is_empty():
		return ""
	var p := Profile.for_bot(bot)
	var owned: Array = bot.treasures
	if str(p.treasure) == "random":
		return str(candidates[absi(hash([str(bot.get("seed", "")), int(bot.get("slot", -1)), owned.size(), candidates])) % candidates.size()])
	var counts := TreasureService.tag_counts_for(owned)
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	var lineup := str(p.treasure) == "lineup"
	var late := int(bot.get("round", 0)) >= LATE_MONEY_ROUND
	var best := ""
	var best_score := -INF
	for tid in candidates:
		var cat := str(TreasureService.treasure_by_id(tid).get("category", ""))
		var score := float(counts.get(cat, 0)) * 2.0       # 往 4 件套凑
		for link in links:
			var req: Array = (link as Dictionary).get("requires", [])
			if req.has(tid):
				for other in req:
					if str(other) != tid and owned.has(str(other)):
						score += 5.0                          # 能直接凑出联动
		if cat == "money" and owned.size() <= 1:
			score += 1.5                                      # 早期偏好经济
		if lineup:
			if str(tid) == "atk_fury_roster":
				score += 4.0                                  # 多一个上阵位
			if cat == "money" and late:
				score -= 2.0
		if score > best_score:
			best_score = score
			best = tid
	return best


# ---------------------------------------------------------------- 上阵与站位

# 上阵谁按档位的羁绊认知挑（BotEval.pick_board），放哪按档位的站位方式（BotFormation）。
# 纯函数：view / board_slots / 结算的商人金都调它，必须每次算出同一个棋盘。
static func _arrange_board(bot: Dictionary) -> Array:
	var p := Profile.for_bot(bot)
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	board.fill(null)
	var chosen := Eval.pick_board(bot.roster, Handover.board_cap(bot.treasures), int(p.synergy_knowledge))
	var flip := bool(p.flip_on_loss) and bool(bot.get("formation_flip", false))
	for pair in Formation.arrange(chosen, str(p.formation), flip):
		board[int(pair[1])] = _cell(pair[0])
	return board


# uid -> 棋盘格下标。给 LiveBotEconomy.mirror 用：玩家收回座位时按这张表落位，
# 看到的就是 AI 打这一场时的站位（_arrange_board 是纯函数，两边算出来一致）。
static func board_slots(bot: Dictionary) -> Dictionary:
	var out := {}
	var board := _arrange_board(bot)
	for index in board.size():
		var cell = board[index]
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var uid := str((cell as Dictionary).get("uid", ""))
		if not uid.is_empty():
			out[uid] = index
	return out


# 没上阵的那些（备战席），给队友「查看棋盘」用（NetworkService._room_prep_view）。
static func bench_cells(bot: Dictionary) -> Array:
	var placed := board_slots(bot)
	var out: Array = []
	for u in bot.roster:
		if out.size() >= BENCH_CAP:
			break
		if placed.has(str(u.get("uid", ""))):
			continue
		out.append(_cell(u))
	return out


static func _cell(u: Dictionary) -> Dictionary:
	return {"def": (u.def as Dictionary).duplicate(true), "star": int(u.star), "is_mercenary": false,
		"id": str(u.id), "uid": str(u.get("uid", "")), "cost_basis": int(u.get("cost_basis", 0))}

static func prioritize_owned_races(bot: Dictionary) -> void:
	var counts := {}
	for u in bot.roster:
		var race := str((u.def as Dictionary).get("race", ""))
		counts[race] = int(counts.get(race, 0)) + 1
	var best := ""
	var most := 0
	var races := counts.keys()
	races.sort()
	for race in races:
		if int(counts[race]) > most:
			best = str(race)
			most = int(counts[race])
	if not best.is_empty():
		bot["main_race"] = best
	_update_second_race(bot)
