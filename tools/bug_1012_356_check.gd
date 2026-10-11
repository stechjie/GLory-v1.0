extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
const Deadline := preload("res://scripts/rounds/PrepDeadline.gd")

func _ready() -> void:
	var h := Harness.new("bug_1012_356")
	DataRegistry.load_all()
	GameState.reset_run()
	for r in range(1, 22):
		var kind := RoundService.schedule_kind_for_round(r)
		h.expect(Deadline.duration(r) == (50.0 if kind in ["pvp", "final"] else 35.0), "duration_%d" % r, "Round kind controls deadline")
	h.expect(Deadline.remaining({"state": "prep", "round_index": 1, "state_started_at": 10.0}, 44.0) == 1.0, "last_second", "Server clock")
	h.expect(Deadline.remaining({"state": "battle"}, 100.0) == -1.0, "not_prep", "Battle has no prep timeout")
	var unit: Dictionary = DataRegistry.get_table("race_units").get("units", [])[0]
	var board: Array = []; board.resize(16)
	var bench: Array = [null, {"id": "left", "star": 2}, {"id": "right"}]
	var result := Deadline.deploy(board, bench, [unit], [false], 100, [], 7)
	h.expect(board[7].id == "left" and bench[1] == null and bench[2].id == "right", "bench_order", "Leftmost reserve deployed, others untouched")
	h.expect(int(result.gold) == 100, "bench_free", "Existing unit does not cost gold")
	board.fill(null)
	var sold: Array = [false, false]
	result = Deadline.deploy(board, [], [unit, unit], sold, 1000, [], 3)
	h.expect(sold[0] and not sold[1] and board[3].id == unit.id, "shop_order", "First unsold offer at random legal cell")
	h.expect(int(result.gold) == 1000 - EconomyLedger.unit_cost(unit, []), "real_price", "Normal shop pricing")
	var after := var_to_bytes(board)
	Deadline.deploy(board, [], [unit], [false], 1000, [], 2)
	h.expect(after == var_to_bytes(board), "idempotent_deploy", "Repeated round-start doesn't add another unit")
	board.fill(null)
	result = Deadline.deploy(board, [], [unit], [false], 0, [], 0)
	h.expect(not result.changed and board[0] == null and result.gold == 0, "no_free_units", "No negative balances or gifted units")
	for seed in range(20):
		var bot := Bot.new_state(seed, 1)
		Bot.prepare_round(bot, 1)
		h.expect(_merc_cost(bot) <= 3 and int(bot.carrots) + _merc_cost(bot) == 3, "r1_carrots_%d" % seed, "First-round carrot conservation")
		var first := var_to_bytes(bot)
		Bot.prepare_round(bot, 1)
		h.expect(first == var_to_bytes(bot), "repeat_prep_%d" % seed, "No duplicate harvest or purchase")
		var gold_before := int(bot.gold)
		var result_real := {"kill_gold_by_slot": {1: 0}, "enemy_hp_current": 10, "enemy_hp_max": 10}
		var settled := Bot.settle_round(bot, result_real, {"round_index": 1, "kind": "pve", "player_wins": false})
		h.expect(int(bot.gold) == gold_before + int(settled.income_total), "actual_income_%d" % seed, "Only actual settlement credited")
		var settled_once := var_to_bytes(bot)
		Bot.settle_round(bot, result_real, {"round_index": 1, "kind": "pve", "player_wins": true})
		h.expect(settled_once == var_to_bytes(bot), "settle_once_%d" % seed, "Duplicate settlement ignored")
		Bot.prepare_round(bot, 2)
		h.expect(_merc_cost(bot) <= 3, "r2_no_reused_mercs_%d" % seed, "Round 1 mercenaries cannot fight again for free")
		h.expect(int(bot.gold) >= 0 and int(bot.carrots) >= 0, "no_debt_%d" % seed, "Live bot must afford every operation")
	var isolated := Bot.new_state(123, 2)
	isolated.gold = 0
	Bot.prepare_round(isolated, 5)
	h.expect(int(isolated.gold) == 0 and isolated.roster.is_empty(), "no_imaginary_income", "Late takeover cannot invent historical winnings")
	var tex := load("res://assets/models/units/crimson_refined/Icey/Icey_m0_albedo.png") as Texture2D
	h.expect(tex != null and tex.get_width() <= 1024, "hair_resource", "Actual restored texture imports within budget")
	h.finish(get_tree())

func _merc_cost(bot: Dictionary) -> int:
	var total := 0
	for merc in bot.mercs:
		total += int(merc.def.get("carrot_cost", 0))
	return total
