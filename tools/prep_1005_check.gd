extends Node

# 10.05 反馈（10.05bug提交及修复.docx）第 2、3、4 条的**行为判据**。
#
# 为什么要新写一个门禁，而不是复用已有的：
#   * 第 3 条（待命区满时的买入自动分流）是本轮**唯一动钱的**改动 —— 四条分支
#     （棋盘升星 / 棋盘空格 / 待命区升星 / 拒绝）动的是 `GameState.gold`、
#     `board_slots`、`bench_slots`。而 `prep_shop_check` 守的是商店卡片与购买理由，
#     **一个购买分支都不驱动**；`board_4x4_smoke` 里一个商店调用都没有。
#   * 第 2 条（平时隐藏 16 个圆圈/光圈、只留棋盘正中的计数图案）与第 4 条
#     （刷新按钮旁的剩余金币）都是「平时/点了之后会怎样」的问题，静态读源码证明不了。
#
# 本检查驱动的是真实入口（与 prep_shop_check 同一路数）：
#   PrepScreen._on_shop_buy_requested() / _sync_prep_board_readability_state()
#   BoardReadabilityLayer.prep_cell_visible()
#   TreasureChoicePanel.refresh()
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/prep_1005_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const GloryToastScript := preload("res://ui/components/GloryToast.gd")
const PrepRules := preload("res://scenes/prep/PrepRules.gd")
const LAYER_SCENE := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")

const CHECK_NAME := "prep_1005"
const BOARD_CELLS := 16

var _h: CheckHarness
var _prep: Node
var _unit_ids: Array[String] = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	_prep = packed.instantiate()
	add_child(_prep)
	await get_tree().process_frame
	await get_tree().process_frame

	_unit_ids = _pick_unit_ids()
	if not _h.expect(_unit_ids.size() >= 2, "unit_table_empty",
			"race_units 表里挑不出两个可用于用例的棋子 id —— 这一组用例没有真的跑到"):
		_h.finish(get_tree())
		return

	_case_bench_full_board_merge()
	_case_bench_full_board_empty_slot()
	_case_fully_full_refuses()
	_case_bench_has_room_uses_bench()

	_case_cap_board_bench_room_uses_bench()
	_case_cap_board_merge_wins_when_bench_full()
	_case_cap_board_bench_merge_uses_bench()
	_case_cap_board_all_full_refuses()

	# 10.09 bug 文档第 1 条：商店拖「唯一棋子」到棋盘（用户给的三条意图）
	_case_unique_shop_drag_merges_board()
	_case_unique_shop_drag_falls_to_bench()
	_case_unique_shop_drag_refuses_when_all_full()

	_case_counter_visibility()
	_case_shop_drag_hides_counter()
	_case_readability_idle_hidden()
	_case_treasure_gold_label()

	_h.finish(get_tree())


# --- 用例脚手架 ---------------------------------------------------------------

func _pick_unit_ids() -> Array[String]:
	var out: Array[String] = []
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for unit in units:
		if out.size() >= 2:
			break
		# 「同名唯一」的棋子会让上限判定横插一脚，用普通棋子把变量压到最少。
		if bool((unit as Dictionary).get("unique_on_board", false)):
			continue
		var id := str((unit as Dictionary).get("id", ""))
		if not id.is_empty():
			out.append(id)
	return out


func _def_for(id: String) -> Dictionary:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for unit in units:
		if str((unit as Dictionary).get("id", "")) == id:
			return unit as Dictionary
	return {}


# 唯一棋子（`unique_on_board`）的 id。10.09 第 1 条的现场就是它（人王）。
# 与 `_pick_unit_ids` 刻意相反：那边专挑**非唯一**棋子，这边专挑唯一棋子。
func _unique_unit_id() -> String:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for unit in units:
		var d: Dictionary = unit
		if bool(d.get("unique_on_board", false)) and not str(d.get("id", "")).is_empty():
			return str(d.get("id", ""))
	return ""


func _piece(id: String, star: int) -> Dictionary:
	return {"id": id, "uid": GameState.mint_piece_uid(), "star": star, "def": _def_for(id)}


# 重开一局，摆好棋盘与待命区（非空则整片填满同一枚棋子），并让商店只剩下标 0 一张可买的卡。
#
# ★ 填充棋子必须用 **MAX_MERGE_STAR（3 星）**，不能用 1 星。
#   踩过的坑：`_refresh_all()` 的**第一步**就是 `_auto_combine_all()`，而它遍历
#   `range(1, MAX_MERGE_STAR)` 把同名同星的够数棋子自动合掉。用 1 星填充时，
#   16 枚同名 1 星会在买之前就自己融成 4 枚 —— 于是「棋盘满」这个前置条件
#   根本没成立，用例测的是另一件事（实测棋盘 16→4、待命区 8→3）。
#   3 星既不落在自动合成的遍历区间里，也过不了 `can_merge_cells` 的
#   `star < MAX_MERGE_STAR`，所以填进去就不会自己动。
func _setup(offer_id: String, board_fill: String, bench_fill: String) -> Dictionary:
	var filler_star := GameState.MAX_MERGE_STAR
	GameState.reset_run()
	GameState.gold = 500
	GameState.tutorial_mode = false
	if not board_fill.is_empty():
		for i in BOARD_CELLS:
			GameState.board_slots[i] = _piece(board_fill, filler_star)
	if not bench_fill.is_empty():
		for i in GameState.bench_slots.size():
			GameState.bench_slots[i] = _piece(bench_fill, filler_star)
	for i in GameState.shop_offers.size():
		GameState.shop_offers[i] = {}
		GameState.shop_sold[i] = false
	var offer: Dictionary = _def_for(offer_id).duplicate(true)
	GameState.shop_offers[0] = offer
	return offer


# 前置条件守卫：摆完之后棋盘/待命区必须真的都是满的。
# 没有它的话，一旦上面的摆法失效（例如填充棋子被自动合成掉），后面那些
# 「不该扣钱 / 不该占格」的断言会**全部恒真**，门禁一片绿却什么都没测。
func _expect_board_and_bench_full() -> bool:
	return _h.expect(GameState.normal_unit_count() == BOARD_CELLS
			and PrepRules.bench_count() == GameState.bench_slots.size(),
		"setup_not_full",
		"用例前置条件不成立：棋盘应 %d 枚（实际 %d）、待命区应 %d 枚（实际 %d）"
			% [BOARD_CELLS, GameState.normal_unit_count(),
				GameState.bench_slots.size(), PrepRules.bench_count()])


func _offer_cost(offer: Dictionary) -> int:
	return EconomyLedger.unit_cost(offer, GameState.owned_treasures, GameState.team_clearance_sale_active)


func _count_id_on_board(id: String) -> int:
	var n := 0
	for cell in GameState.board_slots:
		if typeof(cell) == TYPE_DICTIONARY and str((cell as Dictionary).get("id", "")) == id:
			n += 1
	return n


# --- 第 3 条：待命区满时的买入自动分流 -----------------------------------------

# ① 棋盘上有能升星的同名同星棋子 → 直接升星（最优先）。
# 摆法刻意让「放空格」那条分支走不到（棋盘 16 格全满），于是唯一能成的路只剩升星——
# 这样「升星分支被删掉」就会被下面两条断言同时抓到，而不是被空格分支悄悄兜住。
func _case_bench_full_board_merge() -> void:
	var target := _unit_ids[0]
	var fill := _unit_ids[1]
	var offer := _setup(target, fill, fill)
	GameState.board_slots[0] = _piece(target, 1)
	_expect_board_and_bench_full()
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)
	var bench_before := PrepRules.bench_count()

	_prep.call("_on_shop_buy_requested", 0)

	_h.expect(GameState.gold == gold_before - cost, "merge_gold",
		"待命区满 + 棋盘可升星：应当买下并扣 %d 金，实际 %d -> %d" % [cost, gold_before, GameState.gold])
	_h.expect(bool(GameState.shop_sold[0]), "merge_sold", "升星路径应当把这张卡标记为已售")
	var merged: Dictionary = GameState.board_slots[0]
	_h.expect(int(merged.get("star", 0)) == 2, "merge_star",
		"棋盘上那枚应当升到 2 星，实际 %d 星" % int(merged.get("star", 0)))
	_h.expect(GameState.normal_unit_count() == BOARD_CELLS, "merge_no_new_cell",
		"升星不该额外占格：棋盘应仍是 %d 枚，实际 %d" % [BOARD_CELLS, GameState.normal_unit_count()])
	_h.expect(PrepRules.bench_count() == bench_before, "merge_bench_untouched",
		"升星路径不该动待命区：%d -> %d" % [bench_before, PrepRules.bench_count()])


# ② 待命区满但棋盘还有空位 → 随机放到棋盘空格上。
# 卡片用的是**另一个 id**，所以棋盘那枚不能跟它合成 —— 走的只能是「放空格」。
func _case_bench_full_board_empty_slot() -> void:
	var target := _unit_ids[0]
	var other := _unit_ids[1]
	var offer := _setup(other, "", target)
	# 棋盘只留一枚 target（与卡片不同名 ⇒ 合不了），其余 15 格空着。
	GameState.board_slots[0] = _piece(target, 1)
	_h.expect(PrepRules.bench_count() == GameState.bench_slots.size()
			and GameState.normal_unit_count() == 1, "setup_not_full",
		"用例前置条件不成立：待命区应满 8 枚（实际 %d）、棋盘应只有 1 枚（实际 %d）"
			% [PrepRules.bench_count(), GameState.normal_unit_count()])
	var placed_before := _count_id_on_board(other)
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)

	_prep.call("_on_shop_buy_requested", 0)

	_h.expect(GameState.gold == gold_before - cost, "slot_gold",
		"待命区满 + 棋盘有空位：应当买下并扣 %d 金，实际 %d -> %d" % [cost, gold_before, GameState.gold])
	_h.expect(bool(GameState.shop_sold[0]), "slot_sold", "放空格路径应当把这张卡标记为已售")
	_h.expect(_count_id_on_board(other) == placed_before + 1, "slot_placed",
		"棋盘还有空位时应当把棋子放上去：棋盘上的 %s 从 %d 变 %d" % [other, placed_before, _count_id_on_board(other)])
	_h.expect(PrepRules.bench_count() == GameState.bench_slots.size(), "slot_bench_still_full",
		"放空格路径不该再往待命区塞东西")


# ③ 棋盘满 + 待命区满 + 无法升星 → 只提示，不扣钱。
func _case_fully_full_refuses() -> void:
	var target := _unit_ids[0]
	var fill := _unit_ids[1]
	_setup(target, fill, fill)
	_expect_board_and_bench_full()
	var gold_before := GameState.gold

	GloryToastScript._last_text = ""
	_prep.call("_on_shop_buy_requested", 0)

	_h.expect(GameState.gold == gold_before, "refuse_no_spend",
		"都满且无法升星时不该扣钱：%d -> %d" % [gold_before, GameState.gold])
	_h.expect(not bool(GameState.shop_sold[0]), "refuse_not_sold", "拒绝时不该把卡标记为已售")
	_h.expect(GloryToastScript._last_text == tr("ui_pieces_full"), "refuse_toast",
		"应当提示「%s」，实际提示「%s」" % [tr("ui_pieces_full"), GloryToastScript._last_text])


# ④ 待命区**还有空位**时照旧走待命区 —— 新分流只管「待命区满」，不该抢这条老路。
func _case_bench_has_room_uses_bench() -> void:
	var target := _unit_ids[0]
	var fill := _unit_ids[1]
	var offer := _setup(target, "", "")
	# 填充同样要用 MAX_MERGE_STAR：1 星会被 `_refresh_all()` 的自动合成吃掉
	# （7 枚同名 1 星实测会自己融到 2 枚）。
	GameState.board_slots[0] = _piece(fill, GameState.MAX_MERGE_STAR)
	for i in GameState.bench_slots.size() - 1:
		GameState.bench_slots[i] = _piece(fill, GameState.MAX_MERGE_STAR)
	_h.expect(PrepRules.bench_count() == GameState.bench_slots.size() - 1, "setup_not_roomy",
		"用例前置条件不成立：待命区应当恰好空 1 格，实际 %d 枚" % PrepRules.bench_count())
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)

	_prep.call("_on_shop_buy_requested", 0)

	_h.expect(GameState.gold == gold_before - cost, "bench_gold",
		"待命区有空位：应当买下并扣 %d 金，实际 %d -> %d" % [cost, gold_before, GameState.gold])
	_h.expect(PrepRules.bench_count() == GameState.bench_slots.size(), "bench_filled",
		"待命区有空位时应当照旧填进待命区：应 %d 枚，实际 %d 枚（gold %d -> %d）"
			% [GameState.bench_slots.size(), PrepRules.bench_count(), gold_before, GameState.gold])
	_h.expect(_count_id_on_board(target) == 0, "bench_not_board",
		"待命区有空位时不该往棋盘上放")


# --- 第 3 条（10.05 返工追加）：棋盘满 + 待命区未满，拖到棋盘要落到待命区 ---------
#
# 用户原话：「所以是第3条增加多一种情况：棋盘满 待命区未满，拖动商店的棋子到棋盘
# 会自动落到待命区，如果可升星，会自动升星。」
#
# 与上面四例的区别有两处，都很关键：
#   * 上面四例驱动的是 `_on_shop_buy_requested`（**点购买**）；这一组驱动的是
#     `_drop_on_board`（**拖到棋盘**真正会走的入口：PrepBoardCellButton._drop_data
#     → screen._drop_on_board）。两条路这一轮要分开守 —— 改动只落在后者。
#   * 上面四例的棋盘是**16 格全满**；这一组是**上阵已达上限但棋盘还有空格**
#     （反馈截图现场就是 8/8 + 16 格棋盘 + 待命区没满）。
#     改之前这一路只弹一句「棋盘人口已满（N）」就 return，棋子哪儿也不去。

# 把棋盘摆成「前 cap 格有子、后面全空」—— 即上阵刚好到上限。
# `_setup` 会把 16 格全填满，所以这里把 cap 之后的格清掉。
func _setup_board_at_cap(offer_id: String, board_fill: String, bench_fill: String, bench_used: int) -> Dictionary:
	var offer := _setup(offer_id, board_fill, "")
	var cap := GameState.normal_unit_cap()
	for i in range(cap, BOARD_CELLS):
		GameState.board_slots[i] = null
	# 待命区只摆 bench_used 个（刻意留空位），填充一律 3 星，理由见 `_setup`。
	for i in bench_used:
		GameState.bench_slots[i] = _piece(bench_fill, GameState.MAX_MERGE_STAR)
	return offer


# 拖到棋盘上一个**空格**。这就是用户截图里那一下。
func _drop_shop_on_empty_board_cell() -> void:
	_prep.call("_drop_on_board", GameState.normal_unit_cap(), {"kind": "shop", "index": 0})


func _count_id_in(slots: Array, id: String) -> int:
	var n := 0
	for cell in slots:
		if typeof(cell) == TYPE_DICTIONARY and str((cell as Dictionary).get("id", "")) == id:
			n += 1
	return n


func _expect_cap_board_ready() -> bool:
	var cap := GameState.normal_unit_cap()
	return _h.expect(GameState.normal_unit_count() == cap
			and PrepRules.empty_slot_indices(GameState.board_slots).size() > 0,
		"setup_not_at_cap",
		"用例前置条件不成立：棋盘应当恰好 %d 枚（上阵上限）且还有空格，实际 %d 枚、空格 %d 个"
			% [cap, GameState.normal_unit_count(), PrepRules.empty_slot_indices(GameState.board_slots).size()])


# ④「棋盘满、待命区未满」—— 本轮返工要的正文：拖到棋盘 -> 自动落到待命区。
func _case_cap_board_bench_room_uses_bench() -> void:
	var target := _unit_ids[0]
	var fill := _unit_ids[1]
	var offer := _setup_board_at_cap(target, fill, fill, 5)
	if not _expect_cap_board_ready():
		return
	if not _h.expect(PrepRules.first_empty_bench_slot() >= 0, "setup_bench_room",
			"用例前置条件不成立：待命区应当还有空位"):
		return
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)
	var bench_before := PrepRules.bench_count()

	GloryToastScript._last_text = ""
	_drop_shop_on_empty_board_cell()

	_h.expect(GameState.gold == gold_before - cost, "cap_room_gold",
		"棋盘满 + 待命区有空位：拖到棋盘也应当买下并扣 %d 金，实际 %d -> %d"
			% [cost, gold_before, GameState.gold])
	_h.expect(bool(GameState.shop_sold[0]), "cap_room_sold",
		"落到待命区这条路也应当把这张卡标记为已售")
	_h.expect(PrepRules.bench_count() == bench_before + 1
			and _count_id_in(GameState.bench_slots, target) == 1,
		"cap_room_lands_in_bench",
		"棋盘满时拖到棋盘应当自动落到待命区：待命区应 %d 枚（多出的那枚是 %s），实际 %d 枚、其中 %s 有 %d 枚"
			% [bench_before + 1, target, PrepRules.bench_count(), target, _count_id_in(GameState.bench_slots, target)])
	_h.expect(GameState.normal_unit_count() == GameState.normal_unit_cap(), "cap_room_board_unchanged",
		"上阵已满，这枚不该挤上棋盘：棋盘应仍是 %d 枚，实际 %d"
			% [GameState.normal_unit_cap(), GameState.normal_unit_count()])
	# ★ 改之前这里弹的就是这句 —— 用户截图里的那一句。
	_h.expect(GloryToastScript._last_text != tr("toast_board_full") % GameState.normal_unit_cap(),
		"cap_room_no_reject_toast",
		"待命区收得下的时候不该再弹「%s」，实际提示「%s」"
			% [tr("toast_board_full") % GameState.normal_unit_cap(), GloryToastScript._last_text])


# 「如果可升星，会自动升星」—— ① 棋盘上先升星。
#
# ★ 为什么这一例把**待命区塞满**：`_refresh_all()` 的第一步是 `_auto_combine_all()`，
#   而它 `_gather_star_pieces` 会把**棋盘+待命区**的同名同星凑在一起算，且
#   `_combine_copies_auto` 的 keeper「优先选棋盘格」。于是「把 1 星买进待命区」这条路
#   最后也会被自动合成挪成「棋盘那枚变 2 星」—— 与「就地升星」**结果完全一样**。
#   留着空位就等于让自动合成替我们把断言做绿（实测：把棋盘升星分支整段删掉，
#   这一组仍是 PASS）。待命区一满，自动合成的第二条同名同星就不存在了，
#   这条判据才真的有判别力（删掉分支 -> 直接退回「棋子已满，无法购买」-> 变红）。
func _case_cap_board_merge_wins_when_bench_full() -> void:
	var target := _unit_ids[0]
	var fill := _unit_ids[1]
	var offer := _setup_board_at_cap(target, fill, fill, GameState.bench_slots.size())
	GameState.board_slots[0] = _piece(target, 1)
	if not _expect_cap_board_ready():
		return
	if not _h.expect(PrepRules.first_empty_bench_slot() < 0, "setup_bench_full",
			"用例前置条件不成立：待命区必须是满的（否则自动合成会替我们把断言做绿）"):
		return
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)
	var bench_before := PrepRules.bench_count()

	_drop_shop_on_empty_board_cell()

	_h.expect(int(GameState.board_slots[0].get("star", 0)) == 2, "cap_board_merge_star",
		"棋盘上有同名同星能升星时，棋盘满也要就地升星：棋盘那枚应升到 2 星，实际 %d 星"
			% int(GameState.board_slots[0].get("star", 0)))
	_h.expect(GameState.gold == gold_before - cost, "cap_board_merge_gold",
		"升星这条路应当买下并扣 %d 金，实际 %d -> %d" % [cost, gold_before, GameState.gold])
	_h.expect(bool(GameState.shop_sold[0]), "cap_board_merge_sold", "升星这条路应当把这张卡标记为已售")
	_h.expect(PrepRules.bench_count() == bench_before, "cap_board_merge_bench_untouched",
		"棋盘升星不该动待命区：应保持 %d 枚，实际 %d 枚" % [bench_before, PrepRules.bench_count()])


# 「如果可升星，会自动升星」—— ② 棋盘升不了时，在待命区升星。
#
# 同样把待命区塞满：这样「升星」与「塞空位」不再是等价的（没有空位可塞），
# 把待命区升星那一步去掉就会直接退回拒绝。
func _case_cap_board_bench_merge_uses_bench() -> void:
	var target := _unit_ids[0]
	var fill := _unit_ids[1]
	var offer := _setup_board_at_cap(target, fill, fill, GameState.bench_slots.size())
	GameState.bench_slots[0] = _piece(target, 1)
	if not _expect_cap_board_ready():
		return
	if not _h.expect(PrepRules.first_empty_bench_slot() < 0, "setup_bench_full",
			"用例前置条件不成立：待命区必须是满的"):
		return
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)
	var bench_before := PrepRules.bench_count()

	_drop_shop_on_empty_board_cell()

	_h.expect(int(GameState.bench_slots[0].get("star", 0)) == 2, "cap_bench_merge_star",
		"待命区有同名同星能升星时应当就地升星：待命区那枚应升到 2 星，实际 %d 星"
			% int(GameState.bench_slots[0].get("star", 0)))
	_h.expect(GameState.gold == gold_before - cost, "cap_bench_merge_gold",
		"待命区升星这条路应当买下并扣 %d 金，实际 %d -> %d" % [cost, gold_before, GameState.gold])
	_h.expect(PrepRules.bench_count() == bench_before, "cap_bench_merge_no_new_slot",
		"升星不该额外占待命区格子：应仍是 %d 枚，实际 %d 枚" % [bench_before, PrepRules.bench_count()])


# 「棋盘满、待命区也满、且都升不了星」—— 拖到棋盘仍然只提示、不扣钱。这是第 3 条之（3）。
func _case_cap_board_all_full_refuses() -> void:
	var target := _unit_ids[0]
	var fill := _unit_ids[1]
	_setup_board_at_cap(target, fill, fill, GameState.bench_slots.size())
	if not _expect_cap_board_ready():
		return
	if not _h.expect(PrepRules.first_empty_bench_slot() < 0, "setup_bench_full",
			"用例前置条件不成立：待命区应当是满的"):
		return
	var gold_before := GameState.gold
	var bench_before := PrepRules.bench_count()

	GloryToastScript._last_text = ""
	_drop_shop_on_empty_board_cell()

	_h.expect(GameState.gold == gold_before, "cap_refuse_no_spend",
		"棋盘满 + 待命区满 + 无法升星时不该扣钱：%d -> %d" % [gold_before, GameState.gold])
	_h.expect(not bool(GameState.shop_sold[0]), "cap_refuse_not_sold", "拒绝时不该把卡标记为已售")
	_h.expect(PrepRules.bench_count() == bench_before, "cap_refuse_bench_untouched",
		"拒绝时不该动待命区：%d -> %d" % [bench_before, PrepRules.bench_count()])
	_h.expect(GloryToastScript._last_text == tr("ui_pieces_full"), "cap_refuse_toast",
		"两边都收不下时应当提示「%s」，实际提示「%s」" % [tr("ui_pieces_full"), GloryToastScript._last_text])


# --- 10.09 第 1 条：拖「唯一棋子」到棋盘 ---------------------------------------
#
# 用户原话：「当棋盘上人王时，从商店里拖动人王到棋盘上（即便此时棋盘上是一个一星人王，
# 也不会自动升星），会显示『传奇棋子只能上场一个』，不会进行购买操作。优化为：
#   （1）棋盘上已上阵的同一唯一棋子此时满足了升星条件 → 进行升星；
#   （2）不满足升星条件 → 新拖动的唯一棋子进入备战区；
#   （3）同（2）但不满足升星条件且备战区已满 → 这时才显示『传奇棋子只能上场一个』。」
#
# 三条意图与「上阵已满」那条分流**完全同构**，所以改动就是让这一支复用同一个
# `_auto_dispatch_shop_card()`（原 `_auto_dispatch_shop_when_board_full`，本轮改名）。
# 改之前这一支只有一句 `show_message(toast_unique_limit)` + `return`：玩家拖过来的
# 那一枚既没升星、也没进备战区，直接被吞掉（连钱都不扣）。
#
# ★ 三个用例都拖到**空格**（`_drop_shop_on_empty_board_cell`）：拖到已有同名棋子上
#   本来就走 `can_merge_cells` 那一支合成，现场坏掉的是**空格**这条路。
# ★ 棋盘/待命区的填充一律 MAX_MERGE_STAR，理由同 `_setup` 顶上那段长注释。
func _setup_unique_board(unique: String, star: int, bench_used: int) -> Dictionary:
	var fill := _unit_ids[1]
	var offer := _setup(unique, fill, fill)
	# 棋盘：只留前 cap 格，第 0 格放那枚唯一棋子（星级由调用方定），cap 之后全空。
	for i in range(GameState.normal_unit_cap(), BOARD_CELLS):
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = _piece(fill, GameState.MAX_MERGE_STAR) if i < bench_used else null
	GameState.board_slots[0] = _piece(unique, star)
	# 唯一棋子往往是最贵的那档，500 金可能买不起 —— 买不起会让三条断言全部恒假。
	GameState.gold = 2000
	return offer


func _case_unique_shop_drag_merges_board() -> void:
	var unique := _unique_unit_id()
	if not _h.expect(not unique.is_empty(), "unique_unit_missing",
			"race_units 表里挑不出一枚 unique_on_board 棋子 —— 这一组用例没有真的跑到"):
		return
	# 棋盘那枚是 1 星：商店这枚（1 星）正好是它升 2 星缺的那一枚。
	# 待命区塞满 ⇒「落到待命区」这条路被堵死，只剩「就地升星」这一条能绿。
	var offer := _setup_unique_board(unique, 1, GameState.bench_slots.size())
	if not _expect_cap_board_ready():
		return
	if not _h.expect(PrepRules.first_empty_bench_slot() < 0, "setup_bench_full",
			"用例前置条件不成立：待命区必须是满的（否则自动合成会替我们把断言做绿）"):
		return
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)

	GloryToastScript._last_text = ""
	_drop_shop_on_empty_board_cell()

	_h.expect(int(GameState.board_slots[0].get("star", 0)) == 2, "unique_merge_star",
		"棋盘上有同名 1 星唯一棋子时应当就地升到 2 星，实际 %d 星（用户意图(1)）"
			% int(GameState.board_slots[0].get("star", 0)))
	_h.expect(GameState.gold == gold_before - cost, "unique_merge_gold",
		"升星这条路应当买下并扣 %d 金，实际 %d -> %d" % [cost, gold_before, GameState.gold])
	_h.expect(bool(GameState.shop_sold[0]), "unique_merge_sold", "升星这条路应当把这张卡标记为已售")
	_h.expect(PrepRules.bench_count() == GameState.bench_slots.size(), "unique_merge_bench_untouched",
		"棋盘升星不该动待命区，实际 %d 枚" % PrepRules.bench_count())
	_h.expect(GloryToastScript._last_text != tr("toast_unique_limit"), "unique_merge_no_reject",
		"能升星时不该再弹「%s」，实际提示「%s」"
			% [tr("toast_unique_limit"), GloryToastScript._last_text])


func _case_unique_shop_drag_falls_to_bench() -> void:
	var unique := _unique_unit_id()
	if not _h.expect(not unique.is_empty(), "unique_unit_missing",
			"race_units 表里挑不出一枚 unique_on_board 棋子 —— 这一组用例没有真的跑到"):
		return
	# 棋盘那枚已是 2 星 ⇒ 商店这枚 1 星合不了（can_merge_cells 要求同名同星）。
	var offer := _setup_unique_board(unique, 2, 5)
	if not _expect_cap_board_ready():
		return
	if not _h.expect(PrepRules.first_empty_bench_slot() >= 0, "setup_bench_room",
			"用例前置条件不成立：待命区应当还有空位"):
		return
	var gold_before := GameState.gold
	var cost := _offer_cost(offer)
	var bench_before := PrepRules.bench_count()

	GloryToastScript._last_text = ""
	_drop_shop_on_empty_board_cell()

	_h.expect(int(GameState.board_slots[0].get("star", 0)) == 2, "unique_bench_board_star_kept",
		"棋盘那枚（已 2 星）不该被改动，实际 %d 星" % int(GameState.board_slots[0].get("star", 0)))
	_h.expect(_count_id_in(GameState.bench_slots, unique) == 1, "unique_bench_landed",
		"升不了星时新拖来的唯一棋子应当进备战区：待命区里 %s 应有 1 枚，实际 %d 枚（用户意图(2)）"
			% [unique, _count_id_in(GameState.bench_slots, unique)])
	_h.expect(PrepRules.bench_count() == bench_before + 1, "unique_bench_count",
		"待命区应当多 1 枚：%d -> %d" % [bench_before, PrepRules.bench_count()])
	_h.expect(GameState.gold == gold_before - cost, "unique_bench_gold",
		"落到待命区这条路也应当买下并扣 %d 金，实际 %d -> %d" % [cost, gold_before, GameState.gold])
	_h.expect(bool(GameState.shop_sold[0]), "unique_bench_sold", "这条路应当把这张卡标记为已售")
	_h.expect(GloryToastScript._last_text != tr("toast_unique_limit"), "unique_bench_no_reject",
		"备战区收得下时不该弹「%s」，实际提示「%s」"
			% [tr("toast_unique_limit"), GloryToastScript._last_text])


func _case_unique_shop_drag_refuses_when_all_full() -> void:
	var unique := _unique_unit_id()
	if not _h.expect(not unique.is_empty(), "unique_unit_missing",
			"race_units 表里挑不出一枚 unique_on_board 棋子 —— 这一组用例没有真的跑到"):
		return
	# 棋盘 2 星（合不了）+ 待命区全满 ⇒ 真收不下，这时才是用户意图(3) 的那句提示。
	_setup_unique_board(unique, 2, GameState.bench_slots.size())
	if not _expect_cap_board_ready():
		return
	if not _h.expect(PrepRules.first_empty_bench_slot() < 0, "setup_bench_full",
			"用例前置条件不成立：待命区应当是满的"):
		return
	var gold_before := GameState.gold
	var bench_before := PrepRules.bench_count()

	GloryToastScript._last_text = ""
	_drop_shop_on_empty_board_cell()

	_h.expect(GameState.gold == gold_before, "unique_refuse_no_spend",
		"棋盘与待命区都收不下时不该扣钱：%d -> %d" % [gold_before, GameState.gold])
	_h.expect(not bool(GameState.shop_sold[0]), "unique_refuse_not_sold", "拒绝时不该把卡标记为已售")
	_h.expect(PrepRules.bench_count() == bench_before, "unique_refuse_bench_untouched",
		"拒绝时不该动待命区：%d -> %d" % [bench_before, PrepRules.bench_count()])
	_h.expect(GloryToastScript._last_text == tr("toast_unique_limit"), "unique_refuse_toast",
		"两边都收不下时才该提示「%s」，实际提示「%s」（用户意图(3)）"
			% [tr("toast_unique_limit"), GloryToastScript._last_text])


# --- 第 2 条（含 10.05 返工）：贴地计数图案与 16 张站位圆圈互斥 -----------------
#
# 返工的三件事，各有一条可判定的量：
#   * 圆圈要一起藏 —— 上次只藏了 2D 光圈，棋盘上那 16 枚「站位」图案还亮着；
#   * 商店拖拽那条路也要让位 —— 根因见 _case_shop_drag_hides_counter；
#   * 图案要贴地、在棋子脚下 —— 断言离地高度不高于站位图层、渲染层级与站位图同层。
# 断言一律走 `prep_deploy_counter_snapshot()`（生产代码自己的口径），不另抄一套。

func _case_counter_visibility() -> void:
	_setup(_unit_ids[0], "", "")
	for i in 3:
		GameState.board_slots[i] = _piece(_unit_ids[0], 1)
	var snap: Dictionary = _prep.call("prep_deploy_counter_snapshot")
	# 先确认它**确实建出来了、而且是 3D 场景里的物体** —— 旧版是 2D 控件，
	# 而 2D 层整块压在 3D 视口之上，那正是「图案盖住棋子」的直接原因。
	if not _h.expect(bool(snap.get("counter_is_3d", false)), "counter_not_3d",
			"棋盘正中的计数图案必须是 3D 场景里的 MeshInstance3D，否则一定会盖住棋子"):
		return
	# 比「是不是 3D 节点」更实质的一条：它必须和棋子渲染在**同一个 3D 视口**里。
	# 2D 层与 3D 视口不在一个渲染空间，只有同空间才谈得上深度排序、才可能在棋子脚下。
	_h.expect(bool(snap.get("counter_in_board_world", false)), "counter_in_board_world",
		"计数图案必须挂在棋盘/棋子所属的那个 3D 视口里（挂在 2D 层上就又回到压住棋子的老问题）")
	_h.expect(int(snap.get("cell_mark_count", 0)) == BOARD_CELLS, "cell_mark_nodes",
		"应当为 16 格各建一张站位图，实际 %d 张" % int(snap.get("cell_mark_count", 0)))

	_prep.call("_sync_prep_board_readability_state")
	snap = _prep.call("prep_deploy_counter_snapshot")
	_h.expect(str(snap.get("counter_text", "")) == "3/%d" % GameState.normal_unit_cap(), "counter_text",
		"计数图案应当显示「上阵数/上限」，实际 %s（期望 3/%d）"
			% [str(snap.get("counter_text", "")), GameState.normal_unit_cap()])
	_h.expect(bool(snap.get("counter_visible", false)), "counter_visible_idle",
		"没在拖动棋子时应当显示计数图案")
	# ★ 这就是用户截图里剩下的那 16 个圆圈。
	_h.expect(int(snap.get("cell_mark_visible_count", -1)) == 0, "idle_circles_hidden",
		"平时 16 张站位圆圈也必须一起藏起来（上次只藏了光圈），实际还亮着 %d 张"
			% int(snap.get("cell_mark_visible_count", -1)))

	var hud: Variant = _prep.get("_board_hud")
	hud.set("drop_highlight_active", true)
	_prep.call("_sync_prep_board_readability_state")
	snap = _prep.call("prep_deploy_counter_snapshot")
	_h.expect(not bool(snap.get("counter_visible", true)), "counter_hidden_while_dragging",
		"拖动棋子上阵时应当隐藏计数图案，把棋盘让给圆圈与光圈")
	_h.expect(int(snap.get("cell_mark_visible_count", -1)) == BOARD_CELLS, "dragging_circles_shown",
		"拖动棋子上阵时 16 张站位圆圈应当全部出现当落点引导，实际 %d 张"
			% int(snap.get("cell_mark_visible_count", -1)))
	hud.set("drop_highlight_active", false)
	_prep.call("_sync_prep_board_readability_state")
	snap = _prep.call("prep_deploy_counter_snapshot")
	_h.expect(bool(snap.get("counter_visible", false)), "counter_returns_after_drop",
		"松手之后计数图案应当回来")
	_h.expect(int(snap.get("cell_mark_visible_count", -1)) == 0, "circles_hidden_after_drop",
		"松手之后 16 张站位圆圈应当收起来，实际还亮着 %d 张"
			% int(snap.get("cell_mark_visible_count", -1)))

	# 贴地 + 在棋子脚下。
	var y_lift := float(snap.get("counter_y_lift", 99.0))
	var cell_lift := float(snap.get("cell_mark_y_lift", 0.0))
	var priority := int(snap.get("counter_render_priority", -1))
	_h.expect(y_lift > 0.0 and y_lift <= cell_lift, "counter_grounded",
		"计数图案必须贴在地面上（离地 %.4f，站位图那层是 %.4f）—— 高过它就会浮起来、压到棋子"
			% [y_lift, cell_lift])
	_h.expect(priority == 5, "counter_layer_priority",
		"计数图案应当与站位图同渲染层（5，低于待命区平台的 7），实际 %d" % priority)


# 第 2 条返工的核心回归：**商店卡片**那条拖拽路。
#
# 根因（读码得到，不是猜）：`PrepDragButton._launch_drag()` 只通知 `drag_owner`，
# 而商店卡的 `drag_owner` 是商店面板自己（ShopPanel.build_hand_cards），宿主因此
# 收不到商店这条路的起拖/松手 —— 表现就是「在商店里拖棋子上阵时，计数图案不让位、
# 圆圈也不出现」，而棋盘/待命区两条路是好的。
# 这里按引擎会调的那两个名字驱动商店面板（`drag_owner.has_method("_on_drag_started")`）。
func _case_shop_drag_hides_counter() -> void:
	_setup(_unit_ids[0], "", "")
	var shop: Variant = _prep.get("_shop")
	if not _h.expect(shop != null, "shop_missing", "商店面板没有建出来"):
		return
	if not _h.expect(shop.has_method("_on_drag_started") and shop.has_method("_on_drag_ended"),
			"shop_drag_callbacks_missing",
			"商店面板必须实现 _on_drag_started / _on_drag_ended —— PrepDragButton 按这两个名字回调 drag_owner"):
		return
	_prep.call("_sync_prep_board_readability_state")
	var idle: Dictionary = _prep.call("prep_deploy_counter_snapshot")
	_h.expect(bool(idle.get("counter_visible", false)), "shop_pre_idle_counter",
		"前置条件不成立：没在拖动时计数图案应当是显示的")

	var hud: Variant = _prep.get("_board_hud")
	shop.call("_on_drag_started", {"kind": "shop", "index": 0})
	_h.expect(bool(hud.get("drop_highlight_active")), "shop_drag_sets_drop_state",
		"商店起拖应当把棋盘切到「拖拽中」状态 —— 以前这条路根本没通知宿主")
	var dragging: Dictionary = _prep.call("prep_deploy_counter_snapshot")
	_h.expect(not bool(dragging.get("counter_visible", true)), "shop_drag_hides_counter",
		"在商店里把棋子拖向棋盘时，正中的计数图案必须让位")
	_h.expect(int(dragging.get("cell_mark_visible_count", -1)) == BOARD_CELLS, "shop_drag_shows_circles",
		"商店拖拽时 16 张站位圆圈应当出现当落点引导，实际 %d 张"
			% int(dragging.get("cell_mark_visible_count", -1)))

	shop.call("_on_drag_ended")
	_h.expect(not bool(hud.get("drop_highlight_active")), "shop_drop_clears_drop_state",
		"松手后「拖拽中」状态应当清掉")
	var after: Dictionary = _prep.call("prep_deploy_counter_snapshot")
	_h.expect(bool(after.get("counter_visible", false)), "shop_drop_restores_counter",
		"松手之后计数图案应当回来")
	_h.expect(int(after.get("cell_mark_visible_count", -1)) == 0, "shop_drop_hides_circles",
		"松手之后 16 张站位圆圈应当收起来，实际还亮着 %d 张"
			% int(after.get("cell_mark_visible_count", -1)))


# 可读性层自己的判据：**平时一个格子都不画**。断言走的是 `_draw_prep()` 用的同一个
# 谓词 `prep_cell_visible()`，不是另抄一套判断 —— 否则「平时不画光圈」永远测不到。
func _case_readability_idle_hidden() -> void:
	var layer := LAYER_SCENE.instantiate()
	add_child(layer)
	layer.configure_prep()
	var cells: Array[PackedVector2Array] = []
	for index in BOARD_CELLS:
		var x := float(index % 4) * 24.0
		var y := float(index / 4) * 20.0
		cells.append(PackedVector2Array([Vector2(x, y), Vector2(x + 18, y), Vector2(x + 18, y + 14), Vector2(x, y + 14)]))
	layer.set_prep_cells(cells)

	layer.set_prep_state(-1, PackedInt32Array(), false, -1, Color(0.2, 0.8, 0.8))
	_h.expect(_drawn_cells(layer) == 0, "idle_draws_nothing",
		"没拖动、没选中时不该画任何格子（10.05 第 2 条：平时隐藏 16 圆圈与光圈），实际画了 %d 格"
			% _drawn_cells(layer))

	layer.set_prep_state(5, PackedInt32Array([1, 4]), false, -1, Color(0.2, 0.8, 0.8))
	_h.expect(_drawn_cells(layer) == 3, "selected_kept",
		"选中格与射程是点一下才出现的即时反馈，必须保留：期望 3 格，实际 %d 格" % _drawn_cells(layer))

	layer.set_prep_state(5, PackedInt32Array([1, 4]), true, 6, Color(0.2, 0.8, 0.8))
	_h.expect(_drawn_cells(layer) == BOARD_CELLS, "dragging_shows_all",
		"拖动棋子上阵时 16 格应当全部出现：实际 %d 格" % _drawn_cells(layer))
	layer.queue_free()


func _drawn_cells(layer: Node) -> int:
	return int(layer.contract_snapshot().get("prep_drawn_cell_count", -1))


# --- 第 4 条：刷新按钮旁的剩余金币 ---------------------------------------------

func _case_treasure_gold_label() -> void:
	GameState.reset_run()
	GameState.gold = 37
	GameState.pending_treasure = {"active": true, "round": 1, "candidates": [], "refresh_index": 0}
	var panel: Variant = _prep.get("_treasure")
	if not _h.expect(panel != null, "treasure_panel_missing",
			"PrepScreen 上没有宝物面板，这一组用例没真的跑到"):
		return
	panel.call("refresh")

	var label: Variant = panel.get("_treasure_gold_lbl")
	if not _h.expect(label != null, "gold_label_missing",
			"刷新按钮右边应当有「当前剩余金」标签（10.05 第 4 条）"):
		return
	var expected := tr("ui_treasure_gold_left") % 37
	_h.expect(str(label.text) == expected, "gold_label_text",
		"剩余金文案不符：实际「%s」，期望「%s」" % [str(label.text), expected])

	# 花金刷新后必须当场变小 —— 只断言「标签在」证明不了「实时更新」。
	GameState.gold = 25
	panel.call("refresh")
	var expected_after := tr("ui_treasure_gold_left") % 25
	_h.expect(str(label.text) == expected_after, "gold_label_live",
		"金额变化后文案没有实时更新：实际「%s」，期望「%s」" % [str(label.text), expected_after])

	var button: Variant = panel.get("_treasure_refresh_btn")
	var glow: Variant = null if button == null else button.get_node_or_null("RefreshEdgeGlow")
	_h.expect(glow != null, "glow_missing", "刷新按钮应当带一圈边缘光（10.05 第 4 条）")
	if glow != null:
		_h.expect(bool(glow.show_behind_parent), "glow_behind_button",
			"边缘光必须画在按钮背后，否则会盖住按钮自己的金底")
		_h.expect(str(glow.get_script().resource_path) == "res://ui/components/SoftEdgeGlow.gd", "glow_impl",
			"边缘光应当是纯绘制的 SoftEdgeGlow（StyleBoxFlat 会把 procedural_ui_ratchet 顶红）")

	# 收尾：把浮层关回去，别留给后面的用例。
	GameState.pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	panel.call("refresh")
