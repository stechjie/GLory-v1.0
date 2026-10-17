extends Node
## 10.17 bug 文档第 1 条的门禁：「AI 托管要继承玩家离线时的棋子/经济/商店，
## 玩家回来要和 AI 此刻的状态一致」。
##
## 两头都钉：
##   A. 客户端落地侧 —— AiHandover.build_slots / apply。站位、佣兵席、溢出到备战席、
##      查不到的单位 id。
##   B. 服务端接管侧 —— LiveBotEconomy.prepare / mirror。喂一份真人账本（含佣兵、
##      已卖格的商店、金币 250），断言 bot 是**继承**的（不是另起一套），
##      并且 mirror 把同一份状态写回账本（玩家回来读的就是它）。
##
## 为什么用 prepare() 而不是直接调 _seed_from_human()：门禁**不得在编译期绑定
## 被测代码的新符号** —— 直接写新函数名的话，未修复的构建上整个脚本解析失败、
## 场景没有脚本、进程不退出（是挂住，不是判红）。这里只用 prepare()/mirror()
## 这两个**修复前就存在**的入口，判据落在数据上。
##
## 跑法：Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> _qa_1017/ai_handover_check.tscn

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const LiveBotEconomy := preload("res://scripts/economy/LiveBotEconomy.gd")
const AiHandover := preload("res://scripts/economy/AiHandover.gd")

const CELL_COUNT := 16
const BENCH_SLOTS := 8
const MERC_SLOTS := 8

var h: CheckHarness
var _unit_ids: Array[String] = []
var _merc_id := ""


func _ready() -> void:
	h = CheckHarness.new("ai_handover")
	DataRegistry.ensure_loaded()
	_collect_ids()
	if _unit_ids.size() < 3 or _merc_id.is_empty():
		h.fail("data_missing", "棋子表/佣兵表读不到足够的行（units=%d merc=%s）" % [
			_unit_ids.size(), _merc_id])
		h.finish(get_tree())
		return
	_run_section(_check_layout, 19, "section_layout_incomplete")
	_run_section(_check_server_inheritance, 21, "section_server_incomplete")
	_run_section(_check_client_apply, 7, "section_apply_incomplete")
	h.finish(get_tree())


# 跑一段断言，并核对它真的跑够了条数。Godot 的脚本错误只中止**当前函数**，
# 于是"某一段整体抛错"会表现成"这一段一条都没跑、别的段照跑、最后 PASS" —— 假绿。
func _run_section(section: Callable, min_checks: int, code: String) -> void:
	var before := h.checked_count()
	section.call()
	var done := h.checked_count() - before
	if done < min_checks:
		h.fail(code, "本节只跑了 %d 条断言（应 >= %d）—— 中途抛错，不算跑过" % [done, min_checks])


# ---------------------------------------------------------------- 数据准备

func _collect_ids() -> void:
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var id := str((raw as Dictionary).get("id", ""))
		if id.is_empty() or _unit_ids.has(id):
			continue
		_unit_ids.append(id)
		if _unit_ids.size() >= 3:
			break
	for raw in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var merc_id := str((raw as Dictionary).get("id", ""))
		if not merc_id.is_empty():
			_merc_id = merc_id
			break


func _def(unit_id: String) -> Dictionary:
	return DataRegistry.canonical_unit_def(unit_id).duplicate(true)


func _cell_uid(slots: Array, index: int) -> String:
	if index < 0 or index >= slots.size():
		return ""
	var cell: Variant = slots[index]
	if typeof(cell) != TYPE_DICTIONARY:
		return ""
	return str((cell as Dictionary).get("uid", ""))


func _filled(slots: Array) -> int:
	var n := 0
	for cell in slots:
		if cell != null:
			n += 1
	return n


func _find_star(roster: Array, uid: String) -> int:
	for raw in roster:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		if str((raw as Dictionary).get("uid", "")) == uid:
			return int((raw as Dictionary).get("star", 0))
	return -1


func _roster_uid_keys(roster: Dictionary) -> String:
	var out: Array[String] = []
	for key in roster.keys():
		out.append(str(key))
	out.sort()
	return ",".join(out)


func _uid_set_of_units(units: Array) -> Dictionary:
	var out := {}
	for raw in units:
		if typeof(raw) == TYPE_DICTIONARY:
			out[str((raw as Dictionary).get("uid", ""))] = true
	return out


# ---------------------------------------------------------------- A. 客户端落地

func _check_layout() -> void:
	var a := _unit_ids[0]
	var b := _unit_ids[1]

	# 1) 账本里带 slot 的棋子落回同一格（AI 的站位不许被重排）
	var slots := AiHandover.build_slots({
		"u-1": {"unit_id": a, "star": 2, "cost_basis": 20, "kind": "unit", "slot": 5},
		"u-2": {"unit_id": b, "star": 1, "cost_basis": 10, "kind": "unit", "slot": 9},
	})
	h.expect(_cell_uid(slots["board"], 5) == "u-1", "board_slot_kept",
		"slot=5 的棋子没有落回 5 号格（实测 %s）" % _cell_uid(slots["board"], 5))
	h.expect(_cell_uid(slots["board"], 9) == "u-2", "board_slot_kept_b",
		"slot=9 的棋子没有落回 9 号格（实测 %s）" % _cell_uid(slots["board"], 9))
	h.expect(int((slots["board"][5] as Dictionary).get("star", 0)) == 2, "star_kept",
		"星级没有跟着账本走")
	h.expect(int((slots["board"][5] as Dictionary).get("cost_basis", -1)) == 20, "cost_basis_kept",
		"cost_basis 没有跟着账本走（出售退款会算错）")
	h.expect(_filled(slots["board"]) == 2, "board_count_two", "棋盘上格子数不对")
	h.expect(int(slots["placed"]) == 2, "placed_two", "placed 计数不对")

	# 2) 没有 slot / 那一格被占 —— 先找棋盘空格，不覆盖别人
	slots = AiHandover.build_slots({
		"u-1": {"unit_id": a, "star": 1, "cost_basis": 10, "kind": "unit", "slot": 0},
		"u-2": {"unit_id": b, "star": 1, "cost_basis": 10, "kind": "unit", "slot": 0},
	})
	h.expect(_cell_uid(slots["board"], 0) == "u-1", "duplicate_slot_keeps_first",
		"两枚棋子抢同一格时 0 号格被后到的覆盖了（实测 %s）" % _cell_uid(slots["board"], 0))
	h.expect(_cell_uid(slots["board"], 1) == "u-2", "duplicate_slot_spills",
		"抢格失败的那一枚没有落到空格（实测 1 号格 = %s）" % _cell_uid(slots["board"], 1))
	h.expect(int(slots["placed"]) == 2, "duplicate_slot_placed", "两枚都该在棋盘上")

	# 3) 佣兵进佣兵席，不上棋盘
	slots = AiHandover.build_slots({
		"m-1": {"unit_id": _merc_id, "star": 1, "cost_basis": 0, "kind": "merc", "merc_slot": 3},
	})
	h.expect(_cell_uid(slots["mercs"], 3) == "m-1", "merc_slot_kept",
		"佣兵没有落回账本记的 3 号佣兵席（实测 %s）" % _cell_uid(slots["mercs"], 3))
	h.expect(_filled(slots["board"]) == 0, "merc_not_on_board", "佣兵被塞到棋盘上了")
	h.expect(bool((slots["mercs"][3] as Dictionary).get("is_mercenary", false)), "merc_flag",
		"落地的佣兵格没有 is_mercenary 标记")

	# 4) merc_slot 越界 —— 落到第一个空佣兵席，不能丢
	slots = AiHandover.build_slots({
		"m-1": {"unit_id": _merc_id, "star": 1, "cost_basis": 0, "kind": "merc", "merc_slot": 99},
	})
	h.expect(_cell_uid(slots["mercs"], 0) == "m-1", "merc_slot_overflow",
		"merc_slot 越界时佣兵被丢掉了（0 号佣兵席实测 %s）" % _cell_uid(slots["mercs"], 0))

	# 5) 查不到的单位 id —— 计 missing，不塞半个格子
	slots = AiHandover.build_slots({"x-1": {"unit_id": "__no_such_unit__", "star": 1, "kind": "unit"}})
	h.expect(int(slots["missing"]) == 1, "unknown_unit_missing", "查不到的单位没有计入 missing")
	h.expect(int(slots["placed"]) == 0, "unknown_unit_not_placed", "查不到的单位被塞进了棋盘")

	# 6) 20 枚全上 —— 棋盘 16 格占满，剩下 4 枚进备战席，一枚都不丢
	var many := {}
	for i in 20:
		many["u-%d" % i] = {"unit_id": a, "star": 1, "cost_basis": 10, "kind": "unit"}
	slots = AiHandover.build_slots(many)
	h.expect(int(slots["placed"]) == 20, "overflow_placed",
		"20 枚只落地 %d 枚" % int(slots["placed"]))
	h.expect(_filled(slots["board"]) == CELL_COUNT, "overflow_board_full",
		"棋盘没有占满 16 格（实测 %d）" % _filled(slots["board"]))
	h.expect(_filled(slots["bench"]) == BENCH_SLOTS - 4, "overflow_bench",
		"备战席应有 4 枚（实测 %d）" % _filled(slots["bench"]))
	var landed := {}
	for cell in (slots["board"] as Array) + (slots["bench"] as Array):
		if typeof(cell) == TYPE_DICTIONARY:
			landed[str((cell as Dictionary).get("uid", ""))] = true
	h.expect(landed.size() == 20, "overflow_no_loss",
		"棋盘+备战席只找到 %d 个不同 uid" % landed.size())


# ---------------------------------------------------------------- B. 服务端接管

func _check_server_inheritance() -> void:
	var a := _unit_ids[0]
	var b := _unit_ids[1]

	# 金币故意给 60：`_reserve` 在 round>2 是 30，于是
	# 「gold - reserve < refresh_cost + 60」立刻成立 ⇒ AI 这一轮**刷不了店**。
	# 这样 bot.shop 里的货架只可能是从账本继承来的那一批，断言才钉得住
	# 「AI 用的是玩家那批商店」而不是「AI 自己摇了一批、碰巧也 4 格」。
	var ledger := EconomyLedger.new_prep(60)
	ledger["carrots"] = 4
	ledger["harvest_tech_level"] = 1
	ledger["last_harvest_round"] = 3
	ledger["roster"] = {
		# 3 星：_merge 只合 1/2 星，3 星原封不动 —— 这样 uid 不会被合成吃掉，
		# 「继承」这条断言才真正钉在**继承**上，而不是钉在「这一轮没被合掉」上。
		"u-1": {"unit_id": a, "star": 3, "cost_basis": 30, "kind": "unit"},
		"u-2": {"unit_id": b, "star": 3, "cost_basis": 30, "kind": "unit"},
		"m-1": {"unit_id": _merc_id, "star": 1, "cost_basis": 0, "kind": "merc", "merc_slot": 2},
	}
	var shelf: Array = [_def(a), _def(b), _def(a), _def(b)]
	# 数据表里的行不会带这个键 —— 自己摇出来的货架永远不可能有它。
	shelf[2]["qa_marker"] = "from_player_shop"
	ledger["shop"] = {
		"offer_id": "human_abcdef",
		"offers": shelf,
		"sold": [false, true, false, false],
		"refresh_uses": 1,
	}
	var room := {
		"bot_states": {}, "slot_states": ["dummy"], "initial_seats": ["player"],
		"round_index": 3, "shared_seed": 4242, "prep": {0: ledger},
		"slot_gold": [60], "owned_treasures": {0: ["money_discount"]},
		"seat_races": {0: ["human", "undead"]}, "team_upgrade_stones": [{}, {}],
	}
	var bots := LiveBotEconomy.prepare(room)
	var bot: Dictionary = bots.get(0, {})
	if not h.expect(not bot.is_empty(), "bot_created", "prepare() 没有给 dummy 座位建出 bot"):
		return

	# 继承：账本里那两枚棋子必须还在（不是另起一套推演）
	var unit_uids := _uid_set_of_units(bot.get("roster", []))
	h.expect(unit_uids.has("u-1"), "inherits_unit_u1",
		"接管后账本里的 u-1 不见了 —— bot 自己另起了一套阵容")
	h.expect(unit_uids.has("u-2"), "inherits_unit_u2",
		"接管后账本里的 u-2 不见了")
	h.expect(_find_star(bot.get("roster", []), "u-1") == 3, "inherits_unit_star",
		"u-1 的星级没有继承（实测 %d）" % _find_star(bot.get("roster", []), "u-1"))

	# 佣兵：以前这里被 kind == "merc" 直接 continue 掉
	var merc_uids := _uid_set_of_units(bot.get("mercs", []))
	h.expect(merc_uids.has("m-1"), "inherits_merc",
		"AI 接管后玩家雇的佣兵不见了（bot.mercs 里没有 m-1）")
	var merc_slot := -1
	for raw in bot.get("mercs", []):
		if str((raw as Dictionary).get("uid", "")) == "m-1":
			merc_slot = int((raw as Dictionary).get("merc_slot", -1))
	h.expect(merc_slot == 2, "inherits_merc_slot",
		"佣兵席没有继承（实测 merc_slot=%d）" % merc_slot)

	# 商店：AI 从玩家那一批里买（sold[1] 已经卖掉了，谁都不能再买）
	var shop: Dictionary = bot.get("shop", {})
	var shop_offers: Array = shop.get("offers", [])
	var shop_sold: Array = shop.get("sold", [])
	h.expect(shop_offers.size() == 4, "inherits_shop_offers",
		"AI 没有继承玩家那一批商店（offers=%d）" % shop_offers.size())
	var shelf_marker := ""
	if shop_offers.size() > 2 and typeof(shop_offers[2]) == TYPE_DICTIONARY:
		shelf_marker = str((shop_offers[2] as Dictionary).get("qa_marker", ""))
	h.expect(shelf_marker == "from_player_shop", "inherits_shop_shelf",
		"AI 报上来的货架不是玩家那一批（qa_marker 实测 %s）" % shelf_marker)
	h.expect(shop_sold.size() > 1 and bool(shop_sold[1]), "inherits_shop_sold",
		"玩家已经买掉的格子没有继承（sold[1] 应为 true）")

	h.expect((bot.get("treasures", []) as Array).has("money_discount"), "inherits_treasures",
		"宝藏没有继承")

	# 反面对照：同样的房间但座位本来就不是真人 —— 不许出现 u-1
	var plain_room: Dictionary = room.duplicate(true)
	plain_room["bot_states"] = {}
	plain_room["initial_seats"] = ["dummy"]
	plain_room["prep"] = {}
	var plain := LiveBotEconomy.prepare(plain_room)
	var plain_uids := _uid_set_of_units((plain.get(0, {}) as Dictionary).get("roster", []))
	h.expect(not plain_uids.has("u-1"), "no_ledger_no_inherit",
		"纯 bot 座位也出现了账本里的 u-1 —— 继承判据读错了来源")

	# mirror：AI 打完的状态必须写回账本（玩家回来读的就是这份）
	var prep_after: Dictionary = (room["prep"] as Dictionary).get(0, {})
	var written: Dictionary = prep_after.get("roster", {})
	h.expect(written.has("u-1"), "mirror_keeps_unit",
		"mirror 没有把 u-1 写回账本")
	h.expect(str((written.get("m-1", {}) as Dictionary).get("kind", "")) == "merc",
		"mirror_keeps_merc", "mirror 没有把佣兵写回账本（kind != merc）")
	h.expect(int((written.get("m-1", {}) as Dictionary).get("merc_slot", -1)) == 2,
		"mirror_keeps_merc_slot", "mirror 写回的佣兵席不对")
	h.expect(int(prep_after.get("gold", -1)) == int(bot.get("gold", -2)), "mirror_gold",
		"mirror 没有把金币写回账本")
	var kept_slot := int((written.get("u-1", {}) as Dictionary).get("slot", -1))
	h.expect(kept_slot >= 0 and kept_slot < CELL_COUNT, "mirror_unit_slot",
		"mirror 没有把站位写回账本（slot=%d）" % kept_slot)
	var shop_after: Dictionary = prep_after.get("shop", {})
	var sold_after: Array = shop_after.get("sold", [])
	h.expect(sold_after.size() > 1 and bool(sold_after[1]), "mirror_shop_sold",
		"mirror 没有把商店的已卖格写回账本")
	h.expect(str(shop_after.get("offer_id", "")).begins_with("bot_"), "mirror_shop_offer_id",
		"mirror 写回的 offer_id 还是人摇的那个 —— 客户端不会重新采纳这批商店")

	# 幂等：同一轮再跑一遍，账本与 bot 都不许漂（玩家回来看到的必须稳定）
	var gold_snapshot := int(bot.get("gold", 0))
	var keys_before := _roster_uid_keys(prep_after.get("roster", {}))
	LiveBotEconomy.prepare(room)
	var bot_again: Dictionary = (room["bot_states"] as Dictionary).get(0, {})
	h.expect(int(bot_again.get("gold", -1)) == gold_snapshot, "repeat_prepare_gold_stable",
		"同轮重复 prepare 把金币改了：%d -> %d" % [gold_snapshot, int(bot_again.get("gold", -1))])
	var prep_again: Dictionary = (room["prep"] as Dictionary).get(0, {})
	h.expect(_roster_uid_keys(prep_again.get("roster", {})) == keys_before,
		"repeat_prepare_roster_stable", "同轮重复 prepare 把账本 roster 改了")

	# 佣兵只活一轮：下一轮必须过期，不能一直白拿
	room["slot_gold"][0] = int(bot_again.get("gold", 0))
	room["round_index"] = 4
	LiveBotEconomy.prepare(room)
	var bot_next: Dictionary = (room["bot_states"] as Dictionary).get(0, {})
	h.expect(not _uid_set_of_units(bot_next.get("mercs", [])).has("m-1"), "merc_expires_next_round",
		"跨轮之后 m-1 这个佣兵还在场上 —— 佣兵应当只活一轮")


# ---------------------------------------------------------------- C. 落地接线

func _check_client_apply() -> void:
	var board_before := GameState.board_slots.duplicate(true)
	var bench_before := GameState.bench_slots.duplicate(true)
	var mercs_before := GameState.mercenary_slots.duplicate(true)
	var gold_before := GameState.gold

	var economy := {
		"gold": 777, "ai_handover_round": 5, "ai_handover_seq": 1,
		"roster": {
			"u-1": {"unit_id": _unit_ids[0], "star": 3, "cost_basis": 30, "kind": "unit", "slot": 4},
			"m-1": {"unit_id": _merc_id, "star": 1, "cost_basis": 0, "kind": "merc", "merc_slot": 6},
		},
	}
	h.expect(AiHandover.apply(economy), "apply_ok", "apply() 说有账本却返回 false")
	h.expect(GameState.gold == 777, "apply_gold",
		"金币没有跟着账本走（实测 %d）" % GameState.gold)
	h.expect(not GameState.board_slots.is_empty() and _cell_uid(GameState.board_slots, 4) == "u-1",
		"apply_board", "棋盘上没有落回 u-1")
	h.expect(int((GameState.board_slots[4] as Dictionary).get("star", 0)) == 3, "apply_star",
		"落地后星级不对")
	h.expect(not GameState.mercenary_slots.is_empty() \
		and _cell_uid(GameState.mercenary_slots, 6) == "m-1", "apply_merc",
		"佣兵席上没有落回 m-1")

	# 空账本不许把棋盘清空、也不许把金币改掉
	h.expect(not AiHandover.apply({"gold": 1, "roster": {}}), "apply_rejects_empty",
		"空 roster 也返回 true —— 会把玩家棋盘清空")
	h.expect(GameState.gold == 777, "apply_keeps_gold_on_empty", "空 roster 把金币改了")

	GameState.board_slots = board_before
	GameState.bench_slots = bench_before
	GameState.mercenary_slots = mercs_before
	GameState.gold = gold_before
