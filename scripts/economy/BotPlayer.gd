extends RefCounted
## 假想敌（Bot）推演 —— 9.25 新增，替代旧的「按累计金币随机买一堆」模型。
##
## 旧模型的问题：
##   1. 钱只有真人的 1/10 左右：经济整体进位 ×10 之后，BotEconomyBudget 还在用
##      每回合 5 金 + 击杀 2 金的旧数（第 11 回合 AI 只有 ~167 金可花）。
##   2. 站位全随机、不看种族羁绊、每回合阵容重新随机。
##   3. 没有宝藏 / 升级石 / 4 星；羁绊和宝藏在战斗里也没生效（owner ctx 返回空）。
##
## 现在的做法：按真人同一套规则，从第 1 回合一路推演到当前回合：
##   经济（EconomyService.settle_post_battle_gold，五五开胜率）→ 商店（ShopRoll 同一
##   条档位曲线，递增刷新价）→ 买牌（主种族优先、凑对升星）→ 合成（2 个一星 = 二星，
##   3 个二星 = 三星）→ 胡萝卜 / 收获科技 / 升级石 → 4 星 → 宝藏（第 4/8/12/16/20
##   回合 3 选 1）→ 佣兵 → 选 7 人上阵并按射程站位（近战前排、远程后排）。
##
## 确定性：只用 hash(seed, 座位号) 播种的独立 RNG，结果只取决于
## shared_seed + 座位号 + 回合号 —— 所有客户端算出同一个假想敌，也不消耗
## RngService.rng，战斗随机流不受影响。纯函数，结果按 key 缓存。
##
## 不用 class_name：新增全局类要靠编辑器导入才进 global_script_class_cache，
## 由 BattleSimShared 直接 preload。

const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
const CarrotRules := preload("res://scripts/economy/CarrotEconomy.gd")

## 按「跟普通真人差不多」设定：每场五五开。
const WIN_RATE := 0.5
const SHOP_SLOTS := 4
const MAX_REFRESH_PER_ROUND := 8
const BENCH_CAP := 8
const MAX_TECH_LEVEL := 3
const CACHE_LIMIT := 64
## PvP 击杀金估算：赢了打死约 3 个、输了约 1 个（按 2 档 2 星计）。
const PVP_KILLS_WIN := 3
const PVP_KILLS_LOSS := 1
## 宝藏里带随机的两项（幸运信封、金钱魔法联动）用期望值结算，
## 否则 EconomyService 里的 Crypto 随机会让各客户端推演出不同的金币。
const RANDOM_MONEY_TREASURES := ["money_lucky_envelope"]
const LUCKY_ENVELOPE_EXPECTED := 20
const MONEY_MAGIC_EXPECTED := 70
const TIER_WEIGHT := {1: 1.0, 2: 1.6, 3: 2.4}
const FRONT_SLOTS := [1, 2, 0, 3, 5, 6, 4, 7]      # 第 1、2 行，中间优先
const BACK_SLOTS := [13, 14, 12, 15, 9, 10, 8, 11]  # 第 4、3 行，中间优先

static var _cache: Dictionary = {}


## 返回 {board: Array(16), mercs: Array, treasures: Array, syn: Dictionary,
##       gold: int, main_race: String, stones: Dictionary}
static func state_for(seed: Variant, slot: int, round_n: int) -> Dictionary:
	var key := "%s/%d/%d" % [str(seed), slot, round_n]
	if _cache.has(key):
		return _cache[key]
	if _cache.size() >= CACHE_LIMIT:
		_cache.clear()
	var result := _simulate(seed, slot, maxi(1, round_n))
	_cache[key] = result
	return result


static func clear_cache() -> void:
	_cache.clear()


# ---------------------------------------------------------------- 推演主循环

static func _simulate(seed: Variant, slot: int, round_n: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(["glory_bot_v1", str(seed), slot])
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var races := _races(units)
	var bot := {
		"gold": GameState.START_GOLD,
		"roster": [],            # [{id, star, def, cost_basis}]
		"treasures": [],
		"stones": CarrotRules.empty_stones(),
		"carrots": 0,
		"carrot_spent": 0,
		"tech": 0,
		"stone_draws": 0,
		"loss_streak": 0,
		"main_race": races[rng.randi_range(0, races.size() - 1)] if not races.is_empty() else "",
		"mercs": [],
	}
	# JSON 数字读进来是 float，Array.has(int) 对不上，先转成 int。
	var draw_rounds: Array[int] = []
	for v in DataRegistry.get_table("treasures").get("draw_rounds", [4, 8, 12, 16, 20]):
		draw_rounds.append(int(v))
	for r in range(1, round_n + 1):
		if r > 1:
			_settle_battle(bot, r - 1, rng)
			if draw_rounds.has(r - 1):
				_pick_treasure(bot, rng)
		_harvest(bot)
		_prep_round(bot, r, rng, units)
	var board := _arrange_board(bot)
	var counts := {"god": 0, "dark": 0, "undead": 0, "human": 0}
	for cell in board:
		if typeof(cell) == TYPE_DICTIONARY:
			var race := str((cell.def as Dictionary).get("race", ""))
			if counts.has(race):
				counts[race] += 1
	return {
		"board": board,
		"mercs": (bot.mercs as Array).duplicate(true),
		"treasures": (bot.treasures as Array).duplicate(),
		"syn": SynergyService.flags_from_counts(counts),
		"gold": int(bot.gold),
		"main_race": str(bot.main_race),
		"stones": (bot.stones as Dictionary).duplicate(),
	}


static func _races(units: Array) -> Array[String]:
	var out: Array[String] = []
	for u in units:
		var race := str((u as Dictionary).get("race", ""))
		if not race.is_empty() and not out.has(race):
			out.append(race)
	out.sort()
	return out


# ---------------------------------------------------------------- 战后结算

static func _settle_battle(bot: Dictionary, round_index: int, rng: RandomNumberGenerator) -> void:
	var kind := RoundService.schedule_kind_for_round(round_index)
	var wins := rng.randf() < WIN_RATE
	bot.loss_streak = 0 if wins else int(bot.loss_streak) + 1
	var kill_gold := 0
	match kind:
		"pve":
			var counts: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
			var monsters := maxi(0, int(counts.get(str(round_index), 3)))
			if not wins:
				monsters = monsters / 2
			kill_gold = monsters * EconomyService.PVE_MONSTER_KILL_GOLD
		"pvp", "final":
			kill_gold = (PVP_KILLS_WIN if wins else PVP_KILLS_LOSS) * EconomyService.pvp_normal_kill_reward(2, 2)
	var owned: Array = bot.treasures
	var deterministic_treasures: Array = []
	for tid in owned:
		if not RANDOM_MONEY_TREASURES.has(str(tid)):
			deterministic_treasures.append(tid)
	var board := _arrange_board(bot)
	var ctx := {
		"gold_before": int(bot.gold),
		"kill_gold": kill_gold,
		"bonus_gold": 0,
		"kind": kind,
		"player_wins": wins,
		"round_index": round_index,
		"loss_streak_after": int(bot.loss_streak),
		"boss_hp_current": 1 if wins else 50,
		"boss_hp_max": 100,
		"merchant_gold": EconomyService.merchant_gold_from_board(board),
		# 金钱魔法联动需要幸运信封 → 已被剔除，这里不会触发它的随机分支。
		"treasures": deterministic_treasures,
		"pet_id": "",
		"camp_income": CarrotRules.income_for_spent(int(bot.carrot_spent)),
	}
	var gold := EconomyService.settle_post_battle_gold(ctx)
	if owned.has("money_lucky_envelope"):
		gold += LUCKY_ENVELOPE_EXPECTED
	if TreasureService.has_linkage_in(owned, "link_money_magic"):
		gold += MONEY_MAGIC_EXPECTED
	bot.gold = gold


# ---------------------------------------------------------------- 胡萝卜 / 升级石

static func _harvest(bot: Dictionary) -> void:
	var h := CarrotRules.harvest(int(bot.carrots), int(bot.carrot_spent), int(bot.tech))
	bot.carrots = int(h.after)


# 胡萝卜的用法与真人一致：
#   * 雇佣兵花胡萝卜（不花金币），同时累计「已花胡萝卜」→ 农场升级 → 容量 / 产量 / 营地收入上涨；
#   * 升级石每回合最多抽 1 次，花胡萝卜，而且要求农场容量 ≥ 这次的价格。
# 策略：容量还不够抽石头时，胡萝卜全拿去雇佣兵养农场；够了就攒着抽石头，
# 抽完剩下的再雇佣兵。
static func _spend_carrots(bot: Dictionary, round_index: int, rng: RandomNumberGenerator) -> void:
	var cost := CarrotRules.stone_cost_for_draw(int(bot.stone_draws))
	var capacity := CarrotRules.capacity_for_spent(int(bot.carrot_spent))
	if round_index >= 3 and capacity >= cost:
		if int(bot.carrots) >= cost:
			bot.carrots = int(bot.carrots) - cost
			bot.stone_draws = int(bot.stone_draws) + 1
			var stone := CarrotRules.draw_type_from_roll(rng.randf())
			bot.stones[stone] = int(bot.stones.get(stone, 0)) + 1
		else:
			return  # 攒着下回合抽
	_hire_mercs(bot)


# ---------------------------------------------------------------- 备战

static func _reserve(bot: Dictionary, round_index: int) -> int:
	if round_index <= 2:
		return 0
	var reserve := 30
	# 手上有三星、也有同属性石头 → 存钱升 4 星。
	var target := _four_star_candidate(bot)
	if not target.is_empty():
		reserve += CarrotRules.four_star_gold(int((target.def as Dictionary).get("tier", 1)))
	return reserve


static func _prep_round(bot: Dictionary, round_index: int, rng: RandomNumberGenerator, units: Array) -> void:
	_try_four_star(bot)
	_try_tech(bot, round_index)
	_spend_carrots(bot, round_index, rng)
	var money_set := TreasureService.has_set_in(bot.treasures, "money")
	var refreshes := 0
	var offers := _roll_shop(units, round_index, rng)
	while true:
		for i in offers.size():
			var offer: Dictionary = offers[i]
			if offer.is_empty():
				continue
			var cost := int(offer.get("cost", 1))
			if int(bot.gold) - cost < _reserve(bot, round_index):
				continue
			if not _wants(bot, offer):
				continue
			bot.gold = int(bot.gold) - cost
			(bot.roster as Array).append({"id": str(offer.get("id", "")), "star": 1, "def": offer, "cost_basis": cost})
			offers[i] = {}
			_merge(bot)
			_trim_roster(bot)
		if refreshes >= MAX_REFRESH_PER_ROUND:
			break
		var refresh_cost := EconomyService.shop_refresh_cost(refreshes, money_set)
		if int(bot.gold) - _reserve(bot, round_index) < refresh_cost + 60:
			break
		bot.gold = int(bot.gold) - refresh_cost
		refreshes += 1
		offers = _roll_shop(units, round_index, rng)
	_update_second_race(bot)
	_try_four_star(bot)


static func _roll_shop(units: Array, round_index: int, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for _i in SHOP_SLOTS:
		out.append(ShopRoll.pick_offer(units, round_index, rng.randf(), rng.randf()))
	return out


static func _copies(bot: Dictionary, id: String) -> int:
	var n := 0
	for u in bot.roster:
		if str(u.id) == id:
			n += 1
	return n


static func _normal_count(bot: Dictionary) -> int:
	return (bot.roster as Array).size()


static func _wants(bot: Dictionary, offer: Dictionary) -> bool:
	var id := str(offer.get("id", ""))
	var race := str(offer.get("race", ""))
	# 唯一棋子：已有就不再买。
	if bool(offer.get("unique_on_board", false)) and _copies(bot, id) > 0:
		return false
	var owned_same := false
	for u in bot.roster:
		if str(u.id) == id and int(u.star) < GameConstants.MAX_MERGE_STAR:
			owned_same = true
			break
	var score := 15.0
	if owned_same:
		score = 100.0
	elif race == str(bot.main_race):
		score = 60.0
	elif race == str(bot.get("second_race", "")):
		score = 35.0
	elif int(offer.get("tier", 1)) >= 3:
		score = 40.0
	var size := _normal_count(bot)
	if size < GameConstants.NORMAL_UNIT_CAP:
		return true
	if size < GameConstants.NORMAL_UNIT_CAP + BENCH_CAP:
		return score >= 35.0
	return score >= 100.0


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
				var def_ref: Dictionary = bot.roster[int(take[0])].def
				for i in take:
					basis += int(bot.roster[int(i)].cost_basis)
				take.sort()
				take.reverse()
				for i in take:
					(bot.roster as Array).remove_at(int(i))
				(bot.roster as Array).append({"id": str(key), "star": star + 1, "def": def_ref, "cost_basis": basis})
				changed = true
				break
			if changed:
				break


static func _unit_value(bot: Dictionary, u: Dictionary) -> float:
	var d: Dictionary = u.def
	var v := float(TIER_WEIGHT.get(int(d.get("tier", 1)), 1.0)) * GameState.star_stat_multiplier(int(u.star), d)
	var race := str(d.get("race", ""))
	if race == str(bot.main_race):
		v *= 1.35
	elif race == str(bot.get("second_race", "")):
		v *= 1.15
	return v


static func _trim_roster(bot: Dictionary) -> void:
	var cap := GameConstants.NORMAL_UNIT_CAP + BENCH_CAP
	while (bot.roster as Array).size() > cap:
		var worst := 0
		var worst_v := INF
		for i in (bot.roster as Array).size():
			var v := _unit_value(bot, bot.roster[i])
			if v < worst_v:
				worst_v = v
				worst = i
		var sold: Dictionary = bot.roster[worst]
		bot.gold = int(bot.gold) + int(floor(float(sold.cost_basis) * 0.5))
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


static func _try_tech(bot: Dictionary, round_index: int) -> void:
	if round_index < 3 or int(bot.tech) >= MAX_TECH_LEVEL:
		return
	var price := CarrotRules.tech_price(int(bot.tech))
	if int(bot.gold) - _reserve(bot, round_index) >= price + 100:
		bot.gold = int(bot.gold) - price
		bot.tech = int(bot.tech) + 1


static func _four_star_candidate(bot: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_v := -1.0
	for u in bot.roster:
		if int(u.star) != GameConstants.MAX_MERGE_STAR:
			continue
		# 商人这类经济棋子不值得花 500+ 金升 4 星。
		if str((u.def as Dictionary).get("skill_id", "")) == "post_battle_gold_by_star":
			continue
		var element := str((u.def as Dictionary).get("element", ""))
		if not CarrotRules.valid_stone_type(element) or int(bot.stones.get(element, 0)) <= 0:
			continue
		var v := _unit_value(bot, u)
		if v > best_v:
			best_v = v
			best = u
	return best


static func _try_four_star(bot: Dictionary) -> void:
	var target := _four_star_candidate(bot)
	if target.is_empty():
		return
	var cost := CarrotRules.four_star_gold(int((target.def as Dictionary).get("tier", 1)))
	if cost < 0 or int(bot.gold) < cost:
		return
	var element := str((target.def as Dictionary).get("element", ""))
	bot.gold = int(bot.gold) - cost
	bot.stones[element] = int(bot.stones[element]) - 1
	target.star = GameState.MAX_UNIT_STAR


static func _hire_mercs(bot: Dictionary) -> void:
	var table: Array = DataRegistry.get_table("mercenaries").get("mercenaries", []).duplicate()
	if table.is_empty():
		return
	# 同价按 id 排，保证数据表行序变化不改变结果。
	table.sort_custom(func(a, b):
		var ca := int(a.get("carrot_cost", 0))
		var cb := int(b.get("carrot_cost", 0))
		if ca != cb:
			return ca < cb
		return str(a.get("id", "")) < str(b.get("id", ""))
	)
	var owned: Array = bot.mercs
	while owned.size() < GameState.MERCENARY_SLOTS:
		# 雇得起的里面最贵（最强）的一只。
		var pick: Dictionary = {}
		for m in table:
			var c := int(m.get("carrot_cost", -1))
			if c >= 0 and c <= int(bot.carrots):
				pick = m
		if pick.is_empty():
			break
		var carrots := int(pick.get("carrot_cost", 0))
		bot.carrots = int(bot.carrots) - carrots
		bot.carrot_spent = int(bot.carrot_spent) + carrots
		owned.append({"id": str(pick.get("id", "")), "star": 1, "def": (pick as Dictionary).duplicate(true), "is_mercenary": true})


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
	var counts := TreasureService.tag_counts_for(owned)
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
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
		score += rng.randf() * 0.5
		if score > best_score:
			best_score = score
			best = tid
	if not best.is_empty():
		owned.append(best)


# ---------------------------------------------------------------- 上阵与站位

static func _arrange_board(bot: Dictionary) -> Array:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	board.fill(null)
	var ranked: Array = (bot.roster as Array).duplicate()
	ranked.sort_custom(func(a, b):
		var va := _unit_value(bot, a)
		var vb := _unit_value(bot, b)
		if va != vb:
			return va > vb
		if int(a.star) != int(b.star):
			return int(a.star) > int(b.star)
		return str(a.id) < str(b.id)
	)
	var chosen: Array = []
	var unique_used := {}
	for u in ranked:
		if chosen.size() >= GameConstants.NORMAL_UNIT_CAP:
			break
		var d: Dictionary = u.def
		if bool(d.get("unique_on_board", false)):
			if unique_used.has(str(u.id)):
				continue
			unique_used[str(u.id)] = true
		chosen.append(u)
	var front: Array = []
	var back: Array = []
	for u in chosen:
		var d: Dictionary = u.def
		if float(d.get("range", 1)) <= 1.5 or str(d.get("skill_id", "")) == "guardian_shield_taunt":
			front.append(u)
		else:
			back.append(u)
	# 前排：血厚的站中间；后排：攻击高的站中间。
	front.sort_custom(func(a, b):
		var ha := float((a.def as Dictionary).get("hp", 1)) * GameState.star_stat_multiplier(int(a.star), a.def)
		var hb := float((b.def as Dictionary).get("hp", 1)) * GameState.star_stat_multiplier(int(b.star), b.def)
		if ha != hb:
			return ha > hb
		return str(a.id) < str(b.id)
	)
	back.sort_custom(func(a, b):
		var aa := float((a.def as Dictionary).get("atk", 1)) * GameState.star_stat_multiplier(int(a.star), a.def)
		var ab := float((b.def as Dictionary).get("atk", 1)) * GameState.star_stat_multiplier(int(b.star), b.def)
		if aa != ab:
			return aa > ab
		return str(a.id) < str(b.id)
	)
	for i in front.size():
		var u: Dictionary = front[i]
		board[int(FRONT_SLOTS[mini(i, FRONT_SLOTS.size() - 1)])] = _cell(u)
	for i in back.size():
		var u: Dictionary = back[i]
		board[int(BACK_SLOTS[mini(i, BACK_SLOTS.size() - 1)])] = _cell(u)
	return board


static func _cell(u: Dictionary) -> Dictionary:
	return {"def": (u.def as Dictionary).duplicate(true), "star": int(u.star), "is_mercenary": false, "id": str(u.id)}
