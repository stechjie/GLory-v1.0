extends Node

# 五档 AI 难度的规则门禁（2026-11-07）。不跑战斗，只查决策是否守规矩：
#   * 档位表读得到、段位 → 档位的换算
#   * 队伍仓库：队里有真人时 AI 只用自己抽的石头、放满 2 回合；真人用掉了要对账；
#     第 21 回合真人用不上可以直接用；全 AI 队不用等
#   * 萝卜：佣兵按预算凑一组；想攒石头的回合不乱花
#   * 不作弊：21 回合推演里金币不为负、石头不为负、四星一定扣过石头、上阵不超上限；
#     同样的种子两次推演结果一字不差

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
const Profile := preload("res://scripts/economy/ai/BotProfile.gd")
const Carrots := preload("res://scripts/economy/ai/BotCarrots.gd")
const Handover := preload("res://scripts/economy/AiHandover.gd")
const CarrotRules := preload("res://scripts/economy/CarrotEconomy.gd")

var h: CheckHarness


func _ready() -> void:
	h = CheckHarness.new("ai_difficulty")
	DataRegistry.load_all()
	GameState.reset_run()
	_profiles()
	_stone_rule()
	_merc_pack()
	_legal_and_deterministic()
	h.finish(get_tree())


func _profiles() -> void:
	h.expect(not Profile.table().is_empty(), "profiles_loaded", "data/ai/bot_profiles.json 读不到")
	for level in range(1, 6):
		var p := Profile.for_level(level)
		h.expect(int(p.level) == level and not str(p.name).is_empty(), "profile_%d" % level, "第 %d 档参数不完整" % level)
	for tier in range(0, 5):
		h.expect(Profile.level_for_tier(tier) == tier + 1, "tier_%d" % tier, "段位 %d 应对应第 %d 档" % [tier, tier + 1])
	h.expect(Profile.handover_level() == 3, "handover_normal", "掉线托管应是普通档（用户 11-07 定）")
	h.expect(Profile.level_of({}) == Profile.default_level(), "default_level", "没写档位的 AI 用默认档")
	h.expect(Profile.for_level(1).stone_draw == false and Profile.for_level(5).stone_draw == true,
		"beginner_no_stones", "新手不抽升级石、大师会抽")


func _stone_rule() -> void:
	var bot := Bot.new_state("stone", 0)
	bot.stones = {"sky": 1, "land": 0, "ren": 0}
	bot["own_stones"] = [{"type": "sky", "round": 10}]
	bot["team_has_humans"] = true
	bot["final_round"] = 21
	h.expect(Carrots.usable_stone_count(bot, "sky", 10) == 0 and Carrots.usable_stone_count(bot, "sky", 11) == 0,
		"wait_two_rounds", "队里有真人：AI 抽的石头放满 2 回合前不能用")
	h.expect(Carrots.usable_stone_count(bot, "sky", 12) == 1, "usable_after_two", "放满 2 回合后真人没用，AI 可以用")
	bot.stones.sky = 0
	Carrots.reconcile_own_stones(bot)
	h.expect((bot.own_stones as Array).is_empty(), "human_used_it", "真人用掉了同属性的石头，AI 那颗要划掉")
	# 真人抽的石头 AI 不碰。
	bot.stones = {"sky": 0, "land": 2, "ren": 0}
	bot.own_stones = []
	h.expect(Carrots.usable_stone_count(bot, "land", 15) == 0, "human_stone_untouched", "真人抽的石头 AI 不能用")
	# 第 21 回合：真人用不上就能用，用得上就照旧等。
	bot.stones = {"sky": 0, "land": 0, "ren": 1}
	bot.own_stones = [{"type": "ren", "round": 20}]
	bot["human_stone_elements"] = []
	h.expect(Carrots.usable_stone_count(bot, "ren", 21) == 1, "final_round_free", "决赛回合真人用不上，AI 可以直接用")
	bot["human_stone_elements"] = ["ren"]
	h.expect(Carrots.usable_stone_count(bot, "ren", 21) == 0, "final_round_humans_first", "决赛回合真人有对应三星，照旧等")
	# 全 AI 队：仓库里的都能用，不用等。
	bot["team_has_humans"] = false
	bot.stones = {"sky": 0, "land": 1, "ren": 0}
	bot.own_stones = []
	h.expect(Carrots.usable_stone_count(bot, "land", 5) == 1, "all_ai_team", "全 AI 队不用让，仓库里的石头都能用")


func _merc_pack() -> void:
	var bot := Bot.new_state("merc", 1)
	bot.carrots = 30
	Carrots._hire_pack(bot, 30)
	var spent := 0
	for m in bot.mercs:
		spent += int(m.def.get("carrot_cost", 0))
	h.expect((bot.mercs as Array).size() >= 2 and spent <= 30 and int(bot.carrots) == 30 - spent,
		"merc_pack", "30 萝卜应凑出一组（不止一个）佣兵、不超支：%d 个花 %d" % [(bot.mercs as Array).size(), spent])
	var greedy := Bot.new_state("merc", 2)
	greedy.carrots = 30
	Carrots._hire_greedy(greedy)
	h.expect((greedy.mercs as Array).size() == 1, "merc_greedy", "新手档：有萝卜就叫买得起的最贵一个")
	# 想攒石头：容量够、有三星、仓库里没对应石头、不是关键回合 → 这回合不叫佣兵。
	var saver := Bot.new_state("merc", 3)
	saver["ai_level"] = 3
	saver.carrot_spent = 40
	saver.carrots = 30
	var unit: Dictionary = DataRegistry.get_table("race_units").units[0].duplicate(true)
	saver.roster = [{"id": str(unit.id), "def": unit, "star": 3, "cost_basis": 120}]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var quiet_round := 7
	h.expect(not Carrots.important_round(quiet_round), "quiet_round_fixture", "第 7 回合应是普通 PvE 回合")
	Carrots.spend(saver, quiet_round, rng, Profile.for_level(3))
	h.expect((saver.mercs as Array).is_empty() and int(saver.carrots) == 30, "save_for_stone",
		"普通档想抽石头时这回合先攒萝卜，不叫佣兵")


# 21 回合推演（后备路径，同一套决策代码），每回合都查一遍不作弊的条件。
func _legal_and_deterministic() -> void:
	for level in range(1, 6):
		var first := _run(level, 4242)
		var second := _run(level, 4242)
		h.expect(var_to_bytes(first) == var_to_bytes(second), "deterministic_%d" % level,
			"第 %d 档同一个种子两次推演结果不同" % level)


func _run(level: int, seed_value: int) -> Dictionary:
	var bot := Bot.new_state(seed_value, 0)
	bot["ai_level"] = level
	bot["final_round"] = 21
	bot["server_treasures"] = false
	for round_index in range(1, 22):
		var stones_before: Dictionary = (bot.stones as Dictionary).duplicate()
		var fours_before := _count_star(bot, 4)
		var draws_before := int(bot.stone_draws)
		Bot.prepare_round(bot, round_index)
		h.expect(int(bot.gold) >= 0, "gold_%d_%d" % [level, round_index], "第 %d 档第 %d 回合金币为负" % [level, round_index])
		for kind in bot.stones:
			h.expect(int(bot.stones[kind]) >= 0, "stones_%d_%d" % [level, round_index], "石头为负")
		var used := 0
		for kind in bot.stones:
			used += int(stones_before.get(kind, 0)) - int(bot.stones[kind])
		used += int(bot.stone_draws) - draws_before
		h.expect(_count_star(bot, 4) - fours_before <= maxi(0, used), "four_star_paid_%d_%d" % [level, round_index],
			"第 %d 档第 %d 回合多出的四星没有对应的石头" % [level, round_index])
		var view := Bot.view(bot)
		var fielded := 0
		for cell in view.board:
			if cell is Dictionary:
				fielded += 1
		h.expect(fielded <= Handover.board_cap(bot.treasures), "cap_%d_%d" % [level, round_index], "上阵超过上限")
		h.expect((bot.roster as Array).size() <= Handover.board_cap(bot.treasures) + Bot.BENCH_CAP,
			"bench_%d_%d" % [level, round_index], "棋子总数超过上阵 + 备战席")
		# 结算用后备路径的五五开估算（不跑战斗），只为把下一回合的金币推下去。
		Bot.settle_round(bot, {}, {"kind": RoundService.schedule_kind_for_round(round_index),
			"player_wins": round_index % 2 == 0, "round_index": round_index})
	return {"gold": bot.gold, "roster": (bot.roster as Array).map(func(u): return [str(u.id), int(u.star)]),
		"stones": bot.stones, "mercs": (bot.mercs as Array).size(), "treasures": bot.treasures}


func _count_star(bot: Dictionary, star: int) -> int:
	var n := 0
	for u in bot.roster:
		if int(u.star) == star:
			n += 1
	return n
