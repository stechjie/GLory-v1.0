extends Node

# Focused checks for the new pets and strengthened starter pets.
const Harness := preload("res://tools/CheckHarness.gd")
const Carrots := preload("res://scripts/economy/CarrotEconomy.gd")
const Ledger := preload("res://scripts/multiplayer/EconomyLedger.gd")
const Battle := preload("res://scripts/battle/BattleSimShared.gd")
const Preview := preload("res://scripts/pets/PetPreview.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
const Handover := preload("res://scripts/economy/AiHandover.gd")

var _h: RefCounted

func _ready() -> void:
	_h = Harness.new("pet_feature")
	_check_squirrel()
	_check_starters()
	_check_tiger_ledger()
	_check_tiger_battle()
	_check_monkey_ledger()
	_check_monkey_bot()
	await _check_models()
	_h.finish(get_tree())

func _check_squirrel() -> void:
	_h.expect(Carrots.total_production(0, 0, 0.20) == 4,
		"squirrel_min_one", "3 carrots should become 4")
	_h.expect(Carrots.total_production(2, 0, 0.20) == 10,
		"squirrel_floor_nine", "9 carrots should become 10")
	_h.expect(Carrots.total_production(1, 20, 0.20) == 12,
		"squirrel_floor_ten", "10 carrots should become 12")
	_h.expect(Carrots.capacity_for_spent(0, 0.20) == 14,
		"squirrel_capacity", "12 capacity should become 14")
	var capped := Carrots.harvest(13, 0, 0, 0.20)
	_h.expect(int(capped.gain) == 1 and int(capped.after) == 14,
		"squirrel_cap", "harvest must still obey increased capacity")
	var prep := Ledger.new_prep(0)
	var result := Ledger.harvest_for_round(prep, 1, 0.20)
	_h.expect(int(result.gain) == 4 and int(result.capacity) == 14,
		"squirrel_online", "ledger and local squirrel harvest differ")

func _check_starters() -> void:
	_h.expect(is_equal_approx(PetService.opening_hp_mult("pet_mushroom"), 1.10),
		"mushroom_ten", "mushroom HP must be +10%")
	_h.expect(is_equal_approx(PetService.opening_atk_mult("pet_rabbit"), 1.10),
		"rabbit_ten", "rabbit attack must be +10%")
	_h.expect(EconomyService.base_interest(99)
			+ EconomyService.pet_interest_bonus(99, "pet_cat") == 9,
		"cat_interest", "cat combined interest should floor 99 x 10% to 9")

func _check_tiger_ledger() -> void:
	var prep := Ledger.new_prep(100)
	prep.roster = {
		"a": {"unit_id": "test", "star": 1, "cost_basis": 10, "kind": "unit"},
		"b": {"unit_id": "test", "star": 1, "cost_basis": 10, "kind": "unit"},
		"c": {"unit_id": "other", "star": 1, "cost_basis": 10, "kind": "unit"},
	}
	var ctx := {"tiger_growth_rate": 0.05}
	var merged := Ledger.apply(prep, "merge", {"uids": ["a", "b"], "keeper_uid": "a"}, ctx)
	_h.expect(bool(merged.ok) and int(prep.tiger_starup_count) == 1,
		"tiger_merge", "a successful star merge must add one stack")
	var sold := Ledger.apply(prep, "sell", {"uid": "a"}, ctx)
	_h.expect(bool(sold.ok) and int(prep.tiger_starup_count) == 1,
		"tiger_sell", "selling the upgraded piece must keep the stack")
	prep.roster["d"] = {"unit_id": "test2", "star": 1, "cost_basis": 10, "kind": "unit"}
	prep.roster["e"] = {"unit_id": "test2", "star": 1, "cost_basis": 10, "kind": "unit"}
	var second := Ledger.apply(prep, "merge", {"uids": ["d", "e"], "keeper_uid": "d"}, ctx)
	_h.expect(bool(second.ok) and int(prep.tiger_starup_count) == 2,
		"tiger_repeat", "later merges must continue the same stack")

# 老虎层数记在每枚棋子上（UnitGrowth.tiger_stacks），建 fighter 时按主人的老虎成长率乘上去。
# 完整的规则（升星给谁加、合成继承、服务器截上限）在 tools/unit_growth_check.gd。
func _check_tiger_battle() -> void:
	var rate := PetService.tier1_growth_rate("pet_tiger")
	var tier1 := {"id": "test1", "def": {"id": "test1", "hp": 100, "atk": 100, "def": 20, "tier": 1}, "star": 1, "tiger_stacks": 2}
	var tier2 := {"id": "test2", "def": {"id": "test2", "hp": 100, "atk": 100, "def": 20, "tier": 2}, "star": 1, "tiger_stacks": 2}
	var f1 := Battle._fighter_from_cell(tier1, 0, "player", false, rate)
	var f2 := Battle._fighter_from_cell(tier2, 1, "player", false, rate)
	_h.expect(int(f1.max_hp) == 110 and int(f1.atk) == 110 and int(f1.defense) == 22,
		"tiger_tier1", "two stacks should add 10% HP/ATK/DEF to a tier 1 piece")
	_h.expect(int(f2.max_hp) == 100 and int(f2.atk) == 100 and int(f2.defense) == 20,
		"tiger_tier2", "tier 2 must not receive the tiger bonus")
	var f3 := Battle._fighter_from_cell(tier1, 0, "player", false, PetService.tier1_growth_rate("pet_cat"))
	_h.expect(int(f3.max_hp) == 100, "tiger_other_pet", "stacks must do nothing when the owner's pet is not the tiger")

# 猴子（11-25）：每回合买的第一个棋子免费多一张 1 星，和这一笔 buy 在同一张回执里。
func _check_monkey_ledger() -> void:
	_h.expect(PetService.copies_first_buy("pet_monkey") and not PetService.copies_first_buy("pet_tiger"),
		"monkey_effect", "only the monkey copies the first purchase")
	var unit := {"id": "test_unit", "cost": 10, "tier": 1}
	var other := {"id": "test_other", "cost": 10, "tier": 1}
	var prep := Ledger.new_prep(100)
	prep.shop = {"offer_id": "o1", "offers": [unit, other, unit, other], "sold": [false, false, false, false]}
	var ctx := {"round_index": 3, "pet_first_buy_copy": true, "roster_cap": 24, "owned_treasures": []}
	var first := Ledger.apply(prep, "buy", {"shop_index": 0, "offer_id": "o1", "uid": "m1",
		"pet_copy": {"uid": "m2", "sold": false}}, ctx)
	var roster: Dictionary = prep.roster
	_h.expect(bool(first.ok) and roster.has("m1") and roster.has("m2"),
		"monkey_copy_kept", "first buy of the round must add the bought piece and a free copy")
	_h.expect(int(prep.gold) == 90 and roster.has("m2") and int(roster.m2.cost_basis) == 10
			and int(roster.m2.star) == 1,
		"monkey_copy_free", "the copy is free, 1-star, and records the piece's own price as cost_basis")
	var second := Ledger.apply(prep, "buy", {"shop_index": 1, "offer_id": "o1", "uid": "m3",
		"pet_copy": {"uid": "m4", "sold": false}}, ctx)
	_h.expect(bool(second.ok) and not (second.result as Dictionary).has("pet_copy") and roster.size() == 3,
		"monkey_once_per_round", "only the first purchase of a round is copied")
	var merged := Ledger.apply(prep, "merge", {"uids": ["m1", "m2"], "keeper_uid": "m1"}, ctx)
	_h.expect(bool(merged.ok) and int(prep.roster.m1.star) == 2 and int(prep.roster.m1.cost_basis) == 20,
		"monkey_copy_merges", "the copy merges like a bought piece")
	var next_round := ctx.duplicate()
	next_round.round_index = 4
	var sold := Ledger.apply(prep, "buy", {"shop_index": 2, "offer_id": "o1", "uid": "m5",
		"pet_copy": {"uid": "m6", "sold": true}}, next_round)
	var sold_copy: Dictionary = (sold.result as Dictionary).get("pet_copy", {})
	_h.expect(bool(sold.ok) and bool(sold_copy.get("sold", false)) and int(sold_copy.get("refund", 0)) == 5
			and not prep.roster.has("m6") and int(prep.gold) == 75,
		"monkey_copy_sold", "with no room the copy is sold at half its price (80 - 10 + 5)")
	_h.expect(bool(prep.gold_spent_this_round),
		"monkey_buy_counts_as_spending", "a buy whose copy was sold still spent gold this round")
	var plain := ctx.duplicate()
	plain.round_index = 5
	plain.pet_first_buy_copy = false
	var no_pet := Ledger.apply(prep, "buy", {"shop_index": 3, "offer_id": "o1", "uid": "m7"}, plain)
	_h.expect(bool(no_pet.ok) and not (no_pet.result as Dictionary).has("pet_copy"),
		"monkey_needs_pet", "no copy without the monkey")
	var full := Ledger.new_prep(100)
	full.shop = {"offer_id": "o2", "offers": [unit], "sold": [false]}
	var cramped := {"round_index": 1, "pet_first_buy_copy": true, "roster_cap": 1, "owned_treasures": []}
	var forced := Ledger.apply(full, "buy", {"shop_index": 0, "offer_id": "o2", "uid": "f1",
		"pet_copy": {"uid": "f2", "sold": false}}, cramped)
	_h.expect(bool(forced.ok) and not full.roster.has("f2") and int(full.gold) == 95,
		"monkey_roster_full_sells", "a full roster can only sell the copy")


func _check_monkey_bot() -> void:
	var offer := {"id": "test_unit", "cost": 10, "tier": 1}
	var bot := {"roster": [{"id": "test_unit", "star": 1, "def": offer, "cost_basis": 10}],
		"pet_id": "pet_monkey", "gold": 0, "treasures": [], "first_buy_round": -1}
	var copy := Bot._pet_first_buy_copy(bot, offer, 5)
	_h.expect(not copy.is_empty() and (bot.roster as Array).size() == 2 and int(copy.cost_basis) == 10,
		"monkey_bot_copy", "an AI-run seat with the monkey copies its first purchase")
	_h.expect(Bot._pet_first_buy_copy(bot, offer, 5).is_empty(),
		"monkey_bot_once", "the AI copies only once per round")
	var seeded := {"roster": [], "pet_id": "pet_monkey", "gold": 0, "treasures": [], "first_buy_round": 9}
	_h.expect(Bot._pet_first_buy_copy(seeded, offer, 9).is_empty(),
		"monkey_bot_after_player_buy", "a player who bought before disconnecting is not copied again by the AI")
	var no_pet := {"roster": [], "pet_id": "", "gold": 0, "treasures": [], "first_buy_round": -1}
	_h.expect(Bot._pet_first_buy_copy(no_pet, offer, 1).is_empty(),
		"monkey_bot_needs_pet", "fill-in AI seats have no pet effect")
	var cap := Handover.board_cap([]) + Bot.BENCH_CAP
	var crowded := {"roster": [], "pet_id": "pet_monkey", "gold": 0, "treasures": [], "first_buy_round": -1}
	for i in cap:
		(crowded.roster as Array).append({"id": "filler_%d" % i, "star": 1, "def": offer, "cost_basis": 10})
	var extra := Bot._pet_first_buy_copy(crowded, offer, 2)
	Bot._sell_copy_without_room(crowded, extra)
	_h.expect((crowded.roster as Array).size() == cap and int(crowded.gold) == 5,
		"monkey_bot_sells_copy", "with no room the AI sells the copy itself, not another piece")


func _check_models() -> void:
	for pet_id in ["pet_squirrel", "pet_tiger", "pet_monkey"]:
		var pet_def := PetService.pet_by_id(pet_id)
		_h.expect(not pet_def.is_empty(), pet_id + "_data", "pet missing from pets.json")
		var icon_path := str(pet_def.get("icon", ""))
		_h.expect(ResourceLoader.exists(icon_path), pet_id + "_art", "hand art missing")
		var scene := load(PetService.model_path(pet_id)) as PackedScene
		if not _h.expect(scene != null, pet_id + "_model", "3D scene failed to load"):
			continue
		var model := scene.instantiate() as Node3D
		add_child(model)
		await get_tree().process_frame
		var idle_height := Preview.aabb_of(model).size.y
		_h.expect(idle_height > 0.0,
			pet_id + "_mesh", "3D model has no visible mesh bounds")
		_h.expect(model.has_method("play_idle") and model.has_method("play_run"),
			pet_id + "_motion", "main menu movement hooks missing")
		if model.has_method("play_run"):
			# ★ 10.10 用户反馈「老虎一移动就消失、地上还有它的影子」。
			#   成因：待机 / 跑是**两份导出**，老虎的 walk.glb 比 idle 小约 488 倍，
			#   靠 `ImportedPetAnimated.run_model_scale` 放大回来。这个 @export 只写
			#   在 .tscn 里 —— 重存场景 / re-import 时极易被丢掉（同事 8c4cf64 就丢了
			#   那一行，10.10 回灌带回本地 ⇒ 一跑就缩成看不见，影子是独立节点所以还在）。
			#
			#   判据刻意量「跑起来**真的画出来**多高」（Preview.aabb_of 只算当前显示
			#   的那份子模型），而不是 grep `run_model_scale` 那个字段名 ——
			#   字段名在、值写错一样是坏的。
			model.call("play_run")
			await get_tree().process_frame
			var run_height := Preview.aabb_of(model).size.y
			var ratio := run_height / maxf(idle_height, 0.0001)
			_h.note("%s 跑/待机可见高度比 = %.4f（run=%.4f idle=%.4f）"
				% [pet_id, ratio, run_height, idle_height])
			_h.expect(ratio > 0.5 and ratio < 2.0, pet_id + "_run_visible_scale",
				"跑起来的可见高度只有待机的 %.4f 倍 ⇒ 一移动就看不见（run_model_scale 丢了？）"
					% ratio)
		model.queue_free()
