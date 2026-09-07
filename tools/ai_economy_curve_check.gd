extends Node

# V12-08 / V12-09：假想敌经济、阵容和小灵定位的可复现量化门禁。
#
# 这份检查刻意不写“第几回合应该输/赢”的产品阈值。它负责：
# 1. 证明 Bot 的档位与真人商店共用 ShopRoll；
# 2. 证明 Bot 的升星份数与客户端/服务端共用 GameConstants；
# 3. 固定 100 个种子采样 1/4/5/9/10/15/21 回合的预算、场上投入、星级和阵容；
# 4. 将 legacy_estimate_v1 与真实 EconomyService 在相同储备策略下的全胜/全败账本并列；
# 5. 单列 undead_small 的同价/同档/同种族对照，不把“便宜”自动判成失衡。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BotBudget := preload("res://scripts/economy/BotEconomyBudget.gd")
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")

const CHECK_NAME := "ai_economy_curve"
const SAMPLE_COUNT := 100
const TARGET_ROUNDS := [1, 4, 5, 9, 10, 15, 21]
const SEED_BASE := 202609070000
const REPORT_PATH := "user://v12_ai_economy_curve.json"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.load_all()
	GameState.reset_run()

	_check_versioned_budget_contract()
	_check_shop_tier_parity()
	_check_merge_parity()
	var report := _sample_curves()
	_check_undead_small(report)
	_write_report(report)
	_h.finish(get_tree())


func _check_versioned_budget_contract() -> void:
	_h.expect(BotBudget.MODEL_ID == "legacy_estimate_v1", "budget_model_unversioned",
		"Bot 预算必须有明确模型版本，禁止无名公式静默改变难度")
	for round_index in TARGET_ROUNDS:
		_h.expect(BattleSimShared._dummy_total_gold(round_index) == BotBudget.cumulative_earned(round_index),
			"budget_wiring_drift", "回合 %d 未使用版本化 Bot 预算接口" % round_index)
	var has_gap := false
	for round_index in TARGET_ROUNDS:
		var legacy := BotBudget.cumulative_earned(round_index)
		var win_ledger := BotBudget.canonical_same_reserve_ledger(round_index, true)
		if legacy != int(win_ledger.get("cumulative_earned", legacy)):
			has_gap = true
	_h.expect(has_gap, "audit_not_discriminating",
		"真实 EconomyService 对照必须能显出 legacy 模型的口径差异")


func _check_shop_tier_parity() -> void:
	for round_index in TARGET_ROUNDS:
		for seed_offset in 20:
			var a := RandomNumberGenerator.new()
			var b := RandomNumberGenerator.new()
			a.seed = SEED_BASE + round_index * 100 + seed_offset
			b.seed = a.seed
			var got := BattleSimShared._dummy_tier_for_round(round_index, a)
			var want := ShopRoll.tier_for_roll(round_index, b.randf())
			_h.expect(got == want, "shop_tier_drift",
				"回合 %d seed %d：Bot tier%d，ShopRoll tier%d" % [
					round_index, seed_offset, got, want])


func _check_merge_parity() -> void:
	var copies_per_two := GameConstants.copies_to_upgrade(1)
	var copies_per_three := copies_per_two * GameConstants.copies_to_upgrade(2)
	for copies in 31:
		var buckets := BattleSimShared._dummy_star_buckets(copies)
		var represented := int(buckets[1]) + int(buckets[2]) * copies_per_two \
			+ int(buckets[3]) * copies_per_three
		_h.expect(represented == copies, "merge_copy_loss",
			"%d 份经 Bot 升星后只表示 %d 份" % [copies, represented])
		_h.expect(int(buckets[1]) < copies_per_two, "merge_one_overflow",
			"%d 份仍留下过量一星：%s" % [copies, buckets])
		_h.expect(int(buckets[2]) < GameConstants.copies_to_upgrade(2), "merge_two_overflow",
			"%d 份仍留下过量二星：%s" % [copies, buckets])


func _sample_curves() -> Dictionary:
	var report := {
		"schema": 1,
		"budget_model": BotBudget.MODEL_ID,
		"sample_count": SAMPLE_COUNT,
		"seed_base": SEED_BASE,
		"rounds": [],
		"undead_small": {},
	}
	for round_index in TARGET_ROUNDS:
		GameState.round_index = round_index
		var unit_total := 0
		var fielded_cost_total := 0
		var star_totals := {1: 0, 2: 0, 3: 0}
		var id_frequency: Dictionary = {}
		var undead_small_boards := 0
		for sample_index in SAMPLE_COUNT:
			var seed_value: int = SEED_BASE + round_index * 1000 + sample_index
			var rng_a := RandomNumberGenerator.new()
			var rng_b := RandomNumberGenerator.new()
			rng_a.seed = seed_value
			rng_b.seed = seed_value
			var board := BattleSimShared.build_dummy_board(rng_a)
			var duplicate := BattleSimShared.build_dummy_board(rng_b)
			_h.expect(var_to_bytes(board) == var_to_bytes(duplicate), "board_not_deterministic",
				"回合 %d seed %d 的假想敌阵容不可重复" % [round_index, seed_value])
			var saw_undead_small := false
			for cell_value in board:
				if typeof(cell_value) != TYPE_DICTIONARY:
					continue
				var cell: Dictionary = cell_value
				var unit_def: Dictionary = cell.get("def", {})
				var unit_id := str(cell.get("id", unit_def.get("id", "")))
				var star := clampi(int(cell.get("star", 1)), 1, 3)
				var represented_copies := _copies_for_star(star)
				unit_total += 1
				fielded_cost_total += int(unit_def.get("cost", 0)) * represented_copies
				star_totals[star] = int(star_totals.get(star, 0)) + 1
				id_frequency[unit_id] = int(id_frequency.get(unit_id, 0)) + 1
				if unit_id == "undead_small":
					saw_undead_small = true
			if saw_undead_small:
				undead_small_boards += 1

		var legacy := BotBudget.cumulative_earned(round_index)
		var win_ledger := BotBudget.canonical_same_reserve_ledger(round_index, true)
		var loss_ledger := BotBudget.canonical_same_reserve_ledger(round_index, false)
		var row := {
			"round": round_index,
			"legacy_cumulative_earned": legacy,
			"legacy_board_budget": int(floor(float(legacy) * BattleSimShared.DUMMY_BOARD_BUDGET_SHARE)),
			"canonical_all_wins_cumulative_earned": int(win_ledger.get("cumulative_earned", 0)),
			"canonical_all_losses_cumulative_earned": int(loss_ledger.get("cumulative_earned", 0)),
			"mean_fielded_units": snappedf(float(unit_total) / SAMPLE_COUNT, 0.001),
			"mean_fielded_copy_cost": snappedf(float(fielded_cost_total) / SAMPLE_COUNT, 0.001),
			"star_counts": star_totals,
			"undead_small_board_rate": snappedf(float(undead_small_boards) / SAMPLE_COUNT, 0.001),
			"unit_field_frequency": id_frequency,
		}
		(report["rounds"] as Array).append(row)
		_h.expect(unit_total > 0, "empty_sample", "回合 %d 的 100-seed 样本没有任何单位" % round_index)
		print("[%s] r%02d legacy=%d canonical(loss/win)=%d/%d units=%.2f fielded_cost=%.1f small=%.1f%%" % [
			CHECK_NAME, round_index, legacy,
			int(loss_ledger.get("cumulative_earned", 0)), int(win_ledger.get("cumulative_earned", 0)),
			float(row["mean_fielded_units"]), float(row["mean_fielded_copy_cost"]),
			float(row["undead_small_board_rate"]) * 100.0])
	return report


func _copies_for_star(star: int) -> int:
	var copies := 1
	for current_star in range(1, clampi(star, 1, 3)):
		copies *= GameConstants.copies_to_upgrade(current_star)
	return copies


func _check_undead_small(report: Dictionary) -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var subject: Dictionary = {}
	for unit_value in units:
		var unit: Dictionary = unit_value
		if str(unit.get("id", "")) == "undead_small":
			subject = unit
			break
	if not _h.expect(not subject.is_empty(), "undead_small_missing", "race_units 中缺少 undead_small"):
		return
	var same_cost: Array = []
	var same_tier: Array = []
	var same_race: Array = []
	for unit_value in units:
		var unit: Dictionary = unit_value
		if str(unit.get("id", "")) == "undead_small":
			continue
		if int(unit.get("cost", -1)) == int(subject.get("cost", -2)):
			same_cost.append(_combat_summary(unit))
		if int(unit.get("tier", -1)) == int(subject.get("tier", -2)):
			same_tier.append(_combat_summary(unit))
		if str(unit.get("race", "")) == str(subject.get("race", "_")):
			same_race.append(_combat_summary(unit))
	report["undead_small"] = {
		"subject": _combat_summary(subject),
		"same_cost_peers": same_cost,
		"same_tier_peers": same_tier,
		"same_race_peers": same_race,
		"finding": "no_same_cost_peer" if same_cost.is_empty() else "same_cost_peers_available",
	}
	_h.expect(int(subject.get("cost", -1)) == 10, "undead_small_cost_drift", "小灵当前价格不是审计基线 10")
	_h.expect(same_cost.is_empty(), "undead_small_same_cost_assumption_changed",
		"当前基线预期没有第二个 10 金单位；若新增同价单位，应更新 V12 对照结论")
	_h.note("undead_small 同价对照数=%d、同 tier 对照数=%d、同种族对照数=%d；本检查不自动改平衡" % [
		same_cost.size(), same_tier.size(), same_race.size()])


func _combat_summary(unit: Dictionary) -> Dictionary:
	return {
		"id": str(unit.get("id", "")),
		"cost": int(unit.get("cost", 0)),
		"tier": int(unit.get("tier", 0)),
		"race": str(unit.get("race", "")),
		"element": str(unit.get("element", "")),
		"hp": int(unit.get("hp", 0)),
		"atk": int(unit.get("atk", 0)),
		"def": int(unit.get("def", 0)),
		"attack_speed": float(unit.get("attack_speed", 0.0)),
		"range": int(unit.get("range", 0)),
		"move_speed": float(unit.get("move_speed", 0.0)),
		"skill_id": str(unit.get("skill_id", "")),
	}


func _write_report(report: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if not _h.expect(file != null, "report_open_failed", "无法写入 %s" % REPORT_PATH):
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	_h.expect(FileAccess.file_exists(REPORT_PATH), "report_missing", "量化报告没有落盘")
	print("[%s] report=%s" % [CHECK_NAME, ProjectSettings.globalize_path(REPORT_PATH)])
