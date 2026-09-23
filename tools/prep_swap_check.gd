extends Node

# 「两个同星级人王交换无效」的修复探针（2026-09-22，用户 bug 文档第 1 条）。
#
# ## 现场（用户修正后的原话）
#
# 两只**同星**人王**都在备战区**，把这两只的位置互换 —— 换不动；
# 而**不同星**的两只人王能换。关键变量是**星级**，不是「在不在场上」。
#
# ## 根因
#
# `PrepRules.can_merge_cells(to, from)` 判的是「同名 + 同星 + 没到满星」。它
# **不判「这一下合得成」** —— 升星要几份是 `GameConstants.STAR_UPGRADE_COPIES
# = {1: 2, 2: 3}`（1 星靠这两份就够，2 星还得再凑第 3 份）。凑不出第 3 份时
# `_merge_copies_into_cell` 返回 false，而 `_move_or_merge_*` 四个函数在旧写法里
# 对这条路径直接 `return` —— 于是**整个操作什么都不发生**，玩家看到的就是「交换无效」。
#
# 星级边界（`MAX_MERGE_STAR = 3`）刚好解释用户那句「不同星级的却可以」：
#
#   * **1 星**：`copies_to_upgrade(1) == 2`，这 2 份就够了 → 旧写法会**合成**（升 2 星），
#     不是「无效」，所以 1 星看不出这个 bug；
#   * **2 星**：还差第 3 份 → 凑不出 → 旧写法静默 return → **交换无效**（用户报的就是这段）；
#   * **3 星**：`star < MAX_MERGE_STAR` 不成立 → `can_merge_cells` 为假 → 走 else 交换，
#     旧写法本来就是好的。
#
# 为什么偏偏是人王让人察觉：人王 `unique_on_board`（场上上限 1）**但备战区可以放多只**，
# 两只同星人王同时待在备战区是常态；而每只的成长层数（`king_growth_stacks`）各自独立，
# 所以「换位置」是玩家真会做、且一眼能看出没生效的操作。
# 普通棋子同样中招，只是两只同星等价、换不换看不出来，所以一直没被报上来。
#
# ## 修法
#
# 把「能合」与「合得成」并成一个条件（`and _merge_copies_into_cell(...)`），
# 合不成就落到本来就在下面的**交换分支**。安全性：`_merge_copies_into_cell`
# 在失败路径上不改任何状态（extra 找不到就直接返回空字典，
# `_take_extra_merge_piece` 只在真的取到时才清格子），所以不存在「合了一半再去交换」。
#
# ## 这个探针要证明的四句话
#
#   ① **修复前提为真**：凑不出第三份时 `_merge_copies_into_cell` 返回 false，
#      且**不改动任何格子**（这是「并进条件里安全」的全部依据）。
#   ② **四条路都换得动**：场↔场 / 场↔待命区 / 待命区↔待命区 在「同星 + 无第三份」下
#      真的把两只棋子的位置换过来了（按 uid 认身份，不是看数量）。
#   ③ **没有把合成弄坏**：第三份存在时仍然合成（`can_merge_cells` 那条路不能被改成交换）。
#   ④ **星级边界钉死**：1 星照旧合成、3 星照旧交换 —— 即「为什么只在 2 星暴露」。
#
# 变异验证（`work/_qa_922/mutate_swap_fix.py`，2026-09-23 复跑）：
#   * 基线 PASS（checked=26）；
#   * 把 `_move_or_merge_board_to_bench` 改回旧写法 → FAIL（failures=3）；
#   * 把 `_move_or_merge_bench`（用户报的待命区↔待命区）改回旧写法 → FAIL（failures=1）；
#   * 两次还原后 sha256 均与 known-good 一致，收尾门禁回 PASS。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "prep_swap"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await _case_merge_impossible_is_side_effect_free()
	await _case_board_to_bench_king_swap()
	await _case_bench_to_board_king_swap()
	await _case_board_to_board_swap()
	await _case_bench_to_bench_swap()
	await _case_merge_still_wins_when_third_copy_exists()
	await _case_bench_swap_star_boundary()
	await _case_different_units_still_swap()
	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

func _king_def() -> Dictionary:
	for row in DataRegistry.get_table("race_units").get("units", []):
		if str((row as Dictionary).get("id", "")) == "human_king":
			return row as Dictionary
	_h.fail("king_def_missing", "race_units 里找不到 human_king —— 下面的用例全部无意义")
	return {}


# 人王棋子。`stacks` 就是那两只人王唯一的身份差别（成长层数各自独立）。
func _king(stacks: int, star: int = 2) -> Dictionary:
	return {
		"id": "human_king", "uid": GameState.mint_piece_uid(), "star": star,
		"def": _king_def(), "king_growth_stacks": stacks,
	}


func _piece(id: String, star: int = 1) -> Dictionary:
	return {"id": id, "uid": GameState.mint_piece_uid(), "star": star, "def": {"id": id, "element": "sky"}}


func _stacks(cell: Variant) -> int:
	if typeof(cell) != TYPE_DICTIONARY:
		return -1
	return int((cell as Dictionary).get("king_growth_stacks", -1))


func _star(cell: Variant) -> int:
	if typeof(cell) != TYPE_DICTIONARY:
		return -1
	return int((cell as Dictionary).get("star", -1))


func _uid(cell: Variant) -> String:
	if typeof(cell) != TYPE_DICTIONARY:
		return ""
	return str((cell as Dictionary).get("uid", ""))


func _spawn() -> Node:
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


# 清空全部格子 + 待命区，避免上一个用例的残留影响判定。
func _clear_slots() -> void:
	for i in GameState.board_slots.size():
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null


func _despawn(screen: Node) -> void:
	screen.queue_free()
	await get_tree().process_frame


# --- ① 前提：凑不出第三份 = 返回 false 且不动任何格子 ---------------------------

func _case_merge_impossible_is_side_effect_free() -> void:
	var screen := await _spawn()
	if screen == null:
		return
	_clear_slots()
	var target := _king(5)
	var incoming := _king(1)
	var board_before := GameState.board_slots.duplicate()
	var bench_before := GameState.bench_slots.duplicate()

	var merged: bool = screen.call("_merge_copies_into_cell", target, incoming, [0, 1], [0, 1])
	_h.expect(not merged, "merge_impossible_returned_true",
		"没有第三份同名同星时 `_merge_copies_into_cell` 返回了 true —— 修复的前提不成立，用例结论无意义")
	_h.expect(int(target.get("star", 0)) == 2, "impossible_merge_mutated_target",
		"失败的合成把 target 的星级推进到了 %d 星 —— 「合不成」不再是无副作用的" % int(target.get("star", 0)))
	_h.expect(JSON.stringify(GameState.board_slots) == JSON.stringify(board_before) \
			and JSON.stringify(GameState.bench_slots) == JSON.stringify(bench_before),
		"impossible_merge_mutated_slots",
		"失败的合成动了棋盘/待命区 —— 把 `_merge_copies_into_cell` 并进 `and` 条件就不再安全")
	await _despawn(screen)


# --- ② 四条路 -----------------------------------------------------------------

# 场上的 2 星人王 ↔ 待命区的 2 星人王（与用户现场同一处修复的另一条路）。
func _case_board_to_bench_king_swap() -> void:
	var screen := await _spawn()
	if screen == null:
		return
	_clear_slots()
	var on_board := _king(5)
	var on_bench := _king(1)
	GameState.board_slots[0] = on_board
	GameState.bench_slots[0] = on_bench

	screen.call("_move_or_merge_board_to_bench", 0, 0)

	_h.expect(_uid(GameState.bench_slots[0]) == _uid(on_board), "king_board_to_bench_no_move",
		"场上的 2 星人王没有被换到待命区 —— 交换无效（用户报的 bug 仍然存在）")
	_h.expect(_uid(GameState.board_slots[0]) == _uid(on_bench), "king_board_to_bench_no_swap",
		"待命区的 2 星人王没有补到场上 —— 只走了一半，等于把棋子挪走了")
	_h.expect(_stacks(GameState.board_slots[0]) == 1 and _stacks(GameState.bench_slots[0]) == 5,
		"king_board_to_bench_identity_lost",
		"换完之后成长层数没跟着棋子走（场上 %d / 待命 %d）—— 换的是位置，不该换成长"
			% [_stacks(GameState.board_slots[0]), _stacks(GameState.bench_slots[0])])
	_h.expect(_count_id("human_king") == 2, "king_board_to_bench_count_changed",
		"交换之后人王只剩 %d 只 —— 被合成吃掉了（这两只凑不出第三份，不该合）" % _count_id("human_king"))
	await _despawn(screen)


# 待命区的 2 星人王 ↔ 场上的 2 星人王（反方向）。
func _case_bench_to_board_king_swap() -> void:
	var screen := await _spawn()
	if screen == null:
		return
	_clear_slots()
	var on_board := _king(7)
	var on_bench := _king(2)
	GameState.board_slots[0] = on_board
	GameState.bench_slots[0] = on_bench

	screen.call("_move_or_merge_bench_to_board", 0, 0)

	_h.expect(_uid(GameState.board_slots[0]) == _uid(on_bench), "king_bench_to_board_no_move",
		"待命区的 2 星人王没有换到场上 —— 交换无效")
	_h.expect(_uid(GameState.bench_slots[0]) == _uid(on_board), "king_bench_to_board_no_swap",
		"场上那只 2 星人王没有退回待命区 —— 只走了一半")
	_h.expect(_count_id("human_king") == 2, "king_bench_to_board_count_changed",
		"交换之后人王只剩 %d 只 —— 被合成吃掉了" % _count_id("human_king"))
	await _despawn(screen)


# 场上两只同名同星（凑不出第三份）—— 同一处修复的另一条路。
func _case_board_to_board_swap() -> void:
	var screen := await _spawn()
	if screen == null:
		return
	_clear_slots()
	var a := _king(5)
	var b := _king(1)
	GameState.board_slots[0] = a
	GameState.board_slots[1] = b

	screen.call("_move_or_merge_board", 0, 1)

	_h.expect(_uid(GameState.board_slots[0]) == _uid(b) and _uid(GameState.board_slots[1]) == _uid(a),
		"board_to_board_no_swap",
		"场上两只同星人王没有互换（[0]=%s / [1]=%s）—— 交换无效"
			% [_uid(GameState.board_slots[0]), _uid(GameState.board_slots[1])])
	_h.expect(_count_id("human_king") == 2, "board_to_board_count_changed",
		"交换之后人王只剩 %d 只 —— 被合成吃掉了" % _count_id("human_king"))
	await _despawn(screen)


# 待命区两只同名同星 —— **用户报的现场**：两只 2 星人王都在备战区，互换位置无效。
func _case_bench_to_bench_swap() -> void:
	var screen := await _spawn()
	if screen == null:
		return
	_clear_slots()
	var a := _king(5)
	var b := _king(1)
	GameState.bench_slots[0] = a
	GameState.bench_slots[1] = b

	screen.call("_move_or_merge_bench", 0, 1)

	_h.expect(_uid(GameState.bench_slots[0]) == _uid(b) and _uid(GameState.bench_slots[1]) == _uid(a),
		"bench_to_bench_no_swap",
		"待命区两只同星人王没有互换 —— 交换无效")
	_h.expect(_count_id("human_king") == 2, "bench_to_bench_count_changed",
		"交换之后人王只剩 %d 只 —— 被合成吃掉了" % _count_id("human_king"))
	await _despawn(screen)


# --- ③ 反证：第三份存在时仍然合成 ---------------------------------------------

func _case_merge_still_wins_when_third_copy_exists() -> void:
	var screen := await _spawn()
	if screen == null:
		return
	_clear_slots()
	var target := _king(5)
	var incoming := _king(1)
	GameState.bench_slots[1] = _king(3)   # 第三份
	var before := _count_id("human_king")
	_h.expect(before == 1, "third_copy_fixture_wrong",
		"夹具摆错了：待命区第 1 格应该是第三份人王（当前总数 %d）" % before)

	var merged: bool = screen.call("_merge_copies_into_cell", target, incoming, [], [])
	_h.expect(merged, "merge_impossible_with_third_copy",
		"凑得出第三份时 `_merge_copies_into_cell` 仍然返回 false —— 修复把合成也挡住了")
	_h.expect(int(target.get("star", 0)) == 3, "merge_did_not_advance_star",
		"合成之后 target 是 %d 星（应为 3 星）" % int(target.get("star", 0)))
	_h.expect(_count_id("human_king") == 0, "third_copy_not_consumed",
		"第三份人王没有被消耗掉（还在 %d 只）—— 合成路径漏了" % _count_id("human_king"))
	await _despawn(screen)


# --- ④ 星级边界：1 星照旧合成、3 星照旧交换 -------------------------------------

# 把用户那句「不同星级的却可以」钉成可执行的事实，同时说明「为什么只在 2 星暴露」
# （推导见文件头「星级边界」）。1 星与 3 星在旧写法下本来就是好的 —— 这条用例
# 是修复的**边界回归**，不是修复本身。
func _case_bench_swap_star_boundary() -> void:
	var screen := await _spawn()
	if screen == null:
		return

	# 1 星 × 2：`copies_to_upgrade(1) == 2`，这 2 份就够升星 → 应当**合成**。
	_clear_slots()
	GameState.bench_slots[0] = _king(5, 1)
	GameState.bench_slots[1] = _king(1, 1)
	screen.call("_move_or_merge_bench", 0, 1)
	_h.expect(_count_id("human_king") == 1 and _star(GameState.bench_slots[1]) == 2,
		"bench_star1_should_merge",
		"两只 1 星人王在备战区应当合成成 1 只 2 星（实际 %d 只 / 星 %d）—— 1 星不该走交换"
			% [_count_id("human_king"), _star(GameState.bench_slots[1])])

	# 3 星 × 2：已到合成封顶（`star < MAX_MERGE_STAR` 不成立）→ `can_merge_cells` 为假
	# → 应当**交换**。这是「不同星级能换」在满星侧的对照组。
	_clear_slots()
	var hi_a := _king(5, GameState.MAX_MERGE_STAR)
	var hi_b := _king(1, GameState.MAX_MERGE_STAR)
	GameState.bench_slots[0] = hi_a
	GameState.bench_slots[1] = hi_b
	screen.call("_move_or_merge_bench", 0, 1)
	_h.expect(_uid(GameState.bench_slots[0]) == _uid(hi_b) and _uid(GameState.bench_slots[1]) == _uid(hi_a),
		"bench_star%d_no_swap" % GameState.MAX_MERGE_STAR,
		"两只满星（%d 星）人王在备战区没有互换 —— 回归" % GameState.MAX_MERGE_STAR)
	_h.expect(_count_id("human_king") == 2, "bench_star3_count_changed",
		"满星人王被合掉了（只剩 %d 只）—— 合成封顶失效" % _count_id("human_king"))
	await _despawn(screen)


# --- 回归：不同棋子之间的交换照旧 ----------------------------------------------

func _case_different_units_still_swap() -> void:
	var screen := await _spawn()
	if screen == null:
		return
	_clear_slots()
	var a := _piece("god_priest")
	var b := _piece("human_swordsman")
	GameState.board_slots[0] = a
	GameState.board_slots[1] = b

	screen.call("_move_or_merge_board", 0, 1)

	_h.expect(_uid(GameState.board_slots[0]) == _uid(b) and _uid(GameState.board_slots[1]) == _uid(a),
		"different_units_no_swap", "不同棋子之间的交换被改坏了")
	await _despawn(screen)


func _count_id(unit_id: String) -> int:
	var n := 0
	for arr in [GameState.board_slots, GameState.bench_slots]:
		for cell in arr:
			if typeof(cell) == TYPE_DICTIONARY and str((cell as Dictionary).get("id", "")) == unit_id:
				n += 1
	return n
