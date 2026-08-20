extends Node

# 守「客户端合成规则」与「服务端账本合成规则」一致。
#
# 单一真相应当是 `GameState.STAR_UPGRADE_COPIES = {1: 2, 2: 3}`：
#   1 星 -> 2 星 需要 2 个同名同星
#   2 星 -> 3 星 需要 3 个
# 以及 `GameState.MAX_UNIT_STAR = 3` —— 三星封顶。
#
# 这两条在客户端都有（`_can_merge_cells` / `copies_to_upgrade`），
# 服务端账本 `EconomyLedger._merge()` 需要自己也守住，否则联机权威模式下
# 两边对「什么是合法合成」的判断不一致：
#   * 服务端只要 2 个就给升星  -> 2 个二星换一个三星（客户端要 3 个）
#   * 服务端不封顶            -> 能造出四星、五星，客户端根本没有这个概念
#
# 这条检查直接调 `EconomyLedger.apply()`，不依赖 `economy_ledger_*` 开关 ——
# 账本是纯静态函数，规则对不对与它有没有上线无关。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/merge_rule_parity_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "merge_rule_parity"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()

	_case_copies_required_matches_client()
	_case_star_cap_enforced()
	_case_cost_basis_sums()
	_case_still_rejects_bad_input()

	_h.finish(get_tree())


# 造一个只含 N 个「同名同星」单位的账本，返回 [prep, uids]。
func _make_prep(unit_id: String, star: int, count: int, basis_each: int) -> Array:
	var prep: Dictionary = EconomyLedger.new_prep(GameState.START_GOLD)
	var uids: Array = []
	for _i in count:
		var uid := EconomyLedger._add_unit(prep, unit_id, star, basis_each, "unit")
		uids.append(uid)
	return [prep, uids]


func _merge(prep: Dictionary, uids: Array) -> Dictionary:
	return EconomyLedger.apply(prep, "merge", {"uids": uids}, {})


# 服务端要求的份数必须逐星等于客户端的 GameState.copies_to_upgrade()。
func _case_copies_required_matches_client() -> void:
	for star in [1, 2]:
		var need := GameState.copies_to_upgrade(star)
		# 正好够 -> 必须成功
		var made := _make_prep("god_priest", star, need, 3)
		var ok := _merge(made[0] as Dictionary, made[1] as Array)
		_h.expect(bool(ok.get("ok", false)), "merge_correct_count_rejected",
			"%d 星升级要 %d 个（客户端规则），服务端却拒了：%s" % [
				star, need, str(ok.get("error", "?"))])
		if bool(ok.get("ok", false)):
			_h.expect(int((ok.get("result", {}) as Dictionary).get("star", 0)) == star + 1,
				"merge_star_wrong", "%d 星合成后应为 %d 星" % [star, star + 1])
		# 少一个 -> 必须拒。少给也能合 = 白捡一个单位。
		if need > 1:
			var short_made := _make_prep("god_priest", star, need - 1, 3)
			var bad := _merge(short_made[0] as Dictionary, short_made[1] as Array)
			_h.expect(not bool(bad.get("ok", false)), "merge_short_count_accepted",
				"%d 星升级只给了 %d 个（要 %d 个），服务端却放行了 —— 玩家能白捡一个单位" % [
					star, need - 1, need])


# 三星封顶。不封顶的话服务端能造出客户端根本没有的四星。
#
# ⚠️ 这条用例第一版是**假绿**：满星那次合成确实被拒了，但拒它的是份数检查
# （旧账本写死要 2 个，我给了 3 个），不是封顶。只断言「被拒了」不够 ——
# 必须断言**拒绝的理由就是封顶**，否则份数规则一改这条就悄悄失效。
func _case_star_cap_enforced() -> void:
	var cap := GameState.MAX_UNIT_STAR
	for count in [2, 3, GameState.copies_to_upgrade(cap)]:
		var made := _make_prep("god_priest", cap, count, 3)
		var r := _merge(made[0] as Dictionary, made[1] as Array)
		_h.expect(not bool(r.get("ok", false)), "star_cap_not_enforced",
			"服务端把 %d 个 %d 星合成了 %d 星 —— 上限就是 %d 星" % [count, cap, cap + 1, cap])
		_h.expect(str(r.get("error", "")) == "star_capped", "star_cap_wrong_reason",
			"%d 个满星合成的拒绝理由是 %s，应为 star_capped —— " % [count, str(r.get("error", "?"))] +
			"被别的检查顺带挡下不算数，份数规则一改就会漏")


# cost_basis 相加：出售退款按「这一坨总共花了多少」的一半算，
# 加错了就是退款金额错，而且不会报错。
func _case_cost_basis_sums() -> void:
	var need := GameState.copies_to_upgrade(1)
	var made := _make_prep("god_priest", 1, need, 7)
	var r := _merge(made[0] as Dictionary, made[1] as Array)
	if not _h.expect(bool(r.get("ok", false)), "merge_failed", "基础合成失败了"):
		return
	var res: Dictionary = r.get("result", {})
	_h.expect(int(res.get("cost_basis", -1)) == 7 * need, "cost_basis_not_summed",
		"%d 个成本 7 的单位合成后 cost_basis 应为 %d，实际 %d" % [
			need, 7 * need, int(res.get("cost_basis", -1))])
	# 参与合成的原单位必须全部从 roster 里消失，否则等于凭空多出单位
	var prep: Dictionary = made[0]
	var roster: Dictionary = prep.get("roster", {})
	for uid in (made[1] as Array):
		_h.expect(not roster.has(str(uid)), "merge_source_not_consumed",
			"合成后原单位 %s 还留在 roster 里 —— 凭空多出一个单位" % str(uid))
	_h.expect(roster.has(str(res.get("uid", ""))), "merge_result_missing",
		"合成产物没进 roster")


# 这几条原本就该拒，改动不能把它们放松掉。
func _case_still_rejects_bad_input() -> void:
	var need := GameState.copies_to_upgrade(1)
	# 同一个 uid 重复提交 = 自己合自己
	var made := _make_prep("god_priest", 1, 1, 3)
	var dup: Array = []
	for _i in need:
		dup.append((made[1] as Array)[0])
	_h.expect(str(_merge(made[0] as Dictionary, dup).get("error", "")) == "duplicate_uid",
		"duplicate_uid_allowed", "同一个单位重复提交应被拒（自己合自己）")
	# 不存在的 uid
	var made2 := _make_prep("god_priest", 1, need, 3)
	var ghost: Array = (made2[1] as Array).duplicate()
	ghost[0] = "no_such_uid"
	_h.expect(str(_merge(made2[0] as Dictionary, ghost).get("error", "")) == "unknown_uid",
		"unknown_uid_allowed", "不存在的 uid 应被拒")
	# 不同单位混合
	var mixed: Dictionary = EconomyLedger.new_prep(GameState.START_GOLD)
	var mixed_uids: Array = [
		EconomyLedger._add_unit(mixed, "god_priest", 1, 3, "unit"),
		EconomyLedger._add_unit(mixed, "god_guard", 1, 3, "unit"),
	]
	while mixed_uids.size() < need:
		mixed_uids.append(EconomyLedger._add_unit(mixed, "god_priest", 1, 3, "unit"))
	_h.expect(str(_merge(mixed, mixed_uids).get("error", "")) == "mismatched_units",
		"mismatched_units_allowed", "不同单位混合应被拒")
	# 星级不同
	var diff: Dictionary = EconomyLedger.new_prep(GameState.START_GOLD)
	var diff_uids: Array = [
		EconomyLedger._add_unit(diff, "god_priest", 1, 3, "unit"),
		EconomyLedger._add_unit(diff, "god_priest", 2, 3, "unit"),
	]
	while diff_uids.size() < need:
		diff_uids.append(EconomyLedger._add_unit(diff, "god_priest", 1, 3, "unit"))
	_h.expect(str(_merge(diff, diff_uids).get("error", "")) == "mismatched_units",
		"mismatched_star_allowed", "星级不同应被拒")
