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
# PrepRules 没有 class_name，要 preload 才能引用（PrepShared.gd 里也是这么拿的）。
const PrepRules := preload("res://scenes/prep/PrepRules.gd")

const CHECK_NAME := "merge_rule_parity"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()

	_case_copies_required_matches_client()
	_case_star_cap_enforced()
	_case_cost_basis_sums()
	_case_still_rejects_bad_input()
	await _case_auto_combine_caps_at_merge_star()
	await _case_auto_combine_still_cascades()

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


# 合成封顶在**三星**。四星存在，但只能靠升级石，不能靠同名合成 ——
# 不封的话服务端（和客户端）都能免费造出四星，升级石系统被整个绕过。
#
# ⚠️ 这条用例第一版是**假绿**：满星那次合成确实被拒了，但拒它的是份数检查
# （旧账本写死要 2 个，我给了 3 个），不是封顶。只断言「被拒了」不够 ——
# 必须断言**拒绝的理由就是封顶**，否则份数规则一改这条就悄悄失效。
#
# ⚠️ 第二次差点又假绿：加四星时把 MAX_STAR 提到 4，而这里读的是 MAX_UNIT_STAR，
# 用例于是悄悄变成「测 4 星不能合成 5 星」——必然通过，却**不再覆盖真正要守的
# 那条边界**。合成相关的断言一律读 MAX_MERGE_STAR。
func _case_star_cap_enforced() -> void:
	var cap := GameState.MAX_MERGE_STAR
	_h.expect(cap < GameState.MAX_UNIT_STAR, "merge_cap_not_below_star_cap",
		"MAX_MERGE_STAR(%d) 没有低于 MAX_UNIT_STAR(%d) —— 那样合成就能直接顶到最高星，升级石失去意义"
			% [cap, GameState.MAX_UNIT_STAR])
	# 客户端侧：两个满合成星的同名棋子不允许再合。
	var cell_a := {"id": "god_priest", "star": cap, "def": {"id": "god_priest"}}
	var cell_b := {"id": "god_priest", "star": cap, "def": {"id": "god_priest"}}
	_h.expect(not PrepRules.can_merge_cells(cell_a, cell_b), "client_star_cap_not_enforced",
		"客户端允许把两个 %d 星合成 %d 星 —— 四星只能靠升级石" % [cap, cap + 1])
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


# --- 自动合成：客户端的**第三份**合成实现 -------------------------------------
# 上面 _case_star_cap_enforced 守的是 PrepRules.can_merge_cells（手动合成）和
# EconomyLedger._merge（服务端）。客户端还有第三处：PrepBoardController
# ._auto_combine_pass —— 它自己遍历星级、自己调 copies_to_upgrade、自己写
# keeper.star，完全不经过前两者。
#
# 2026-09-09 实测：它的上界写的是 `range(1, GameState.MAX_UNIT_STAR)`，
# 在 MAX_STAR 从 3 提到 4 的那一刻就变成了 [1,2,3]，而 copies_to_upgrade(3)
# 落到 STAR_UPGRADE_COPIES.get(star, 3) 的默认值 3 —— 于是**三个三星自动融合成
# 四星**，不看 element、不看队伍仓库、不走 four_star_check，整个升级石经济被绕过。
# 而且 _auto_combine_all() 是 PrepUI._refresh_all() 的第一行，玩家连点都不用点。
#
# GameConstants.gd 顶部的注释一字不差地预言了这个坑，b21231「4 star」也确实改了
# 另外两处上限 —— 唯独漏了这一处，因为**没有任何用例覆盖它**。
#
# 断言的是结果（棋盘上有没有出现超过合成上限的星），不是那行 range 怎么写。
func _case_auto_combine_caps_at_merge_star() -> void:
	var cap := GameState.MAX_MERGE_STAR
	var screen := await _spawn_prep()
	if screen == null:
		return
	var need := GameState.copies_to_upgrade(cap)
	for i in need:
		GameState.bench_slots[i] = _piece("god_priest", cap)
	screen.call("_auto_combine_all")

	var top := 0
	var survivors := 0
	for arr in [GameState.board_slots, GameState.bench_slots]:
		for cell in arr:
			if typeof(cell) == TYPE_DICTIONARY:
				survivors += 1
				top = maxi(top, int((cell as Dictionary).get("star", 1)))
	_h.expect(top <= cap, "auto_combine_exceeds_merge_cap",
		"自动合成把 %d 个 %d 星融成了 %d 星 —— 四星只能靠升级石，这条路径绕过了整个升级石经济"
			% [need, cap, top])
	_h.expect(survivors == need, "auto_combine_ate_pieces",
		"自动合成吞掉了棋子：摆了 %d 个 %d 星，之后只剩 %d 个" % [need, cap, survivors])
	await _despawn(screen)


# 反向断言：修上界时最容易写出的假修是把 range 收成空的（比如 range(1, 1)），
# 那样上面那条会通过，而**级联合成整个失效** —— 玩家买的同名棋子再也不会自动升星，
# 且没有任何报错。这条用例的存在就是为了让那种改法红。
func _case_auto_combine_still_cascades() -> void:
	var cap := GameState.MAX_MERGE_STAR
	var screen := await _spawn_prep()
	if screen == null:
		return
	# 凑出恰好级联到合成上限所需的一星份数：copies(1) * copies(2) * ... * copies(cap-1)
	var need := 1
	for star in range(1, cap):
		need *= GameState.copies_to_upgrade(star)
	if not _h.expect(need <= GameState.BENCH_SLOTS, "bench_too_small",
			"备战席只有 %d 格，装不下级联所需的 %d 个一星" % [GameState.BENCH_SLOTS, need]):
		await _despawn(screen)
		return
	for i in need:
		GameState.bench_slots[i] = _piece("god_priest", 1)
	screen.call("_auto_combine_all")

	var top := 0
	for arr in [GameState.board_slots, GameState.bench_slots]:
		for cell in arr:
			if typeof(cell) == TYPE_DICTIONARY:
				top = maxi(top, int((cell as Dictionary).get("star", 1)))
	_h.expect(top == cap, "auto_combine_broken",
		"%d 个一星自动合成之后最高只有 %d 星，应当级联到 %d 星 —— 级联被改坏了"
			% [need, top, cap])
	await _despawn(screen)


func _piece(id: String, star: int) -> Dictionary:
	return {"id": id, "star": star, "def": {"id": id, "element": "sky"}}


# 自动合成是 PrepBoardController 上的方法，只能在真实的 PrepScreen 实例上调。
# 单机身份（team_active=false）进入，避免 _ready() 里的联机分支。
func _spawn_prep() -> Node:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return null
	GameState.reset_run()
	NetworkService.team_active = false
	NetworkService.is_host = false
	var screen: Node = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame
	return screen


func _despawn(screen: Node) -> void:
	screen.queue_free()
	await get_tree().process_frame
