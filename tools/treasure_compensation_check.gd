extends Node

# 第 10 点（10.01 反馈）：某一回合掉线错过选宝 → 随机补发一件未拥有的宝藏。
#
# 用户原文：「若玩家在选宝回合未选择宝藏，则随机获得一种还未拥有的宝藏进行补偿，
# 以保证游戏的公平性。」
#
# 这一点的判据不是「玩家掉线了」——**掉线是可自愈的**：重连的 resume payload 会把
# treasure_offer 一起带回来（NetworkService._build_room_state），玩家仍能正常三选一。
# 真正丢宝的时刻是 offer 到期被丢掉的那一刻。所以门禁盯的是那条路径：
#   藏宝回合发候选 → 下一轮（非藏宝）结算 → offer 未消费 ⇒ 必须补一件。
#
# 五节：
#   A 发候选没被补偿逻辑吃掉（藏宝回合仍然正常三选一）
#   B 补偿：该补的补、补的必须是未拥有的真宝物、只补一件
#   C 客户端接线：只增入袋（add_owned），不做删除同步
#   D 回归：选宝主路径与「胡牌手」+2 队血没被共用 helper 改坏
#   E 判别力：不该补的都不补（已消费 / 已满 / 没 offer / offer 轮次不合法 / 别的座位）

const H := preload("res://tools/CheckHarness.gd")
const NET_SRC := "res://scripts/autoload/NetworkService.gd"
const MAIN_SRC := "res://scenes/main/Main.gd"
const HU_PAI := "link_hu_pai_master"

var h
var _treasure_round := -1
var _plain_round := -1


func _ready() -> void:
	h = H.new("treasure_compensation")
	for r in range(1, GameState.FINAL_ROUND + 1):
		var is_t := RoundService.is_treasure_round(r)
		if is_t and _treasure_round < 0:
			_treasure_round = r
		elif (not is_t) and _treasure_round > 0 and _plain_round < 0:
			_plain_round = r
	if _treasure_round < 0 or _plain_round < 0:
		# 前提体检：轮次表读不到就什么都验不了，先红在这里。
		h.fail("fixture_rounds", "轮次表里找不到「藏宝回合 + 紧随其后的普通回合」")
		h.finish(get_tree())
		return
	h.expect(RoundService.is_treasure_round(_treasure_round), "fixture_treasure_round", "藏宝回合判据")
	h.expect(not RoundService.is_treasure_round(_plain_round), "fixture_plain_round", "普通回合判据")

	_section_offer()
	_section_compensation()
	_section_client()
	_section_regression()
	_section_discrimination()
	h.finish(get_tree())


func _room() -> Dictionary:
	var room: Dictionary = NetworkService._new_room()
	room.state = NetworkService.ROOM_PREP
	room.slot_states = ["player", "player", "dummy", "dummy", "dummy", "dummy"]
	return room


# ── A. 藏宝回合照常发候选 ───────────────────────────────────────────────────

func _section_offer() -> void:
	var room := _room()
	var offer: Dictionary = NetworkService._server_pending_treasure(room, 0, _treasure_round)
	h.expect(bool(offer.get("active", false)), "offer_active", "藏宝回合必须发候选")
	h.expect((offer.get("candidates", []) as Array).size() == 3, "offer_three",
		"还是三选一，实际 %d 个" % (offer.get("candidates", []) as Array).size())
	h.expect(not offer.has("compensated"), "offer_no_compensation",
		"正常发候选这一步不该冒出 compensation")
	h.expect(int(offer.get("round", -1)) == _treasure_round, "offer_round", "候选记录的轮次")
	var owned := NetworkService._room_owned_treasures(room, 0)
	h.expect(owned.is_empty(), "offer_grants_nothing", "只是发候选，手里不该多出宝物")


# ── B. 补偿 ─────────────────────────────────────────────────────────────────

func _section_compensation() -> void:
	var room := _room()
	# ★ 前提体检：手里必须先有东西。玩家一无所获时「补的必须是还没有的」是空转判据
	#   —— 任何一件都是「还没有的」。塞 1 件，这条判据才有回旋余地（变异能把它打红）。
	var free_ids := TreasureService.unowned_ids()
	h.expect(free_ids.size() >= 5, "comp_fixture_pool", "宝物池至少 5 件，先决条件")
	if free_ids.size() < 5:
		return
	var seed_map: Dictionary = room.get("owned_treasures", {})
	seed_map[0] = [str(free_ids[0])]
	room.owned_treasures = seed_map

	NetworkService._server_pending_treasure(room, 0, _treasure_round)
	var before := NetworkService._room_owned_treasures(room, 0).duplicate()
	h.expect(before.size() == 1, "comp_fixture_seeded", "前提体检：座位 0 手里先有 1 件")

	# 下一轮（非藏宝）结算 —— offer 没被消费，必须补。
	var expired: Dictionary = NetworkService._server_pending_treasure(room, 0, _plain_round)
	var granted := str(expired.get("compensated", ""))
	var owned := NetworkService._room_owned_treasures(room, 0)

	h.expect(not granted.is_empty(), "comp_granted", "错过选宝必须补一件")
	h.expect(not bool(expired.get("active", false)), "comp_not_an_offer",
		"过期这份不能同时被当成新候选（那会让客户端弹出三选一）")
	h.expect(owned.size() == before.size() + 1, "comp_exactly_one",
		"恰好补 1 件，实际 %d -> %d" % [before.size(), owned.size()])
	h.expect(owned.has(granted), "comp_recorded", "补的那件必须记进服务端持有列表")
	h.expect(not TreasureService.treasure_by_id(granted).is_empty(), "comp_real_treasure",
		"补的必须是数据表里真实存在的宝物：%s" % granted)
	h.expect(not before.has(granted), "comp_was_unowned", "补的必须是玩家还没有的")
	h.expect(TreasureService.unowned_ids().has(granted) or not GameState.owned_treasures.has(granted),
		"comp_in_pool", "补的那件来自「未拥有」池")

	# 幂等：同一份 offer 只会被补一次（offer 紧接着被 erase）。
	var again: Dictionary = NetworkService._server_pending_treasure(room, 0, _plain_round)
	h.expect(str(again.get("compensated", "")).is_empty(), "comp_idempotent",
		"同一次错过只能补一次")
	h.expect(NetworkService._room_owned_treasures(room, 0).size() == owned.size(), "comp_no_double",
		"再结算一次也不能多给")
	h.expect(not (room.get("treasure_offer", {}) as Dictionary).has(0), "comp_offer_cleared",
		"补完要把这份 offer 清掉，否则每轮都会再触发一次")


# ── C. 客户端接线 ───────────────────────────────────────────────────────────

func _section_client() -> void:
	var src := FileAccess.get_file_as_string(MAIN_SRC).replace("\r\n", "\n")
	var body := _strip_comments(_fn_body(src, "func _apply_team_match_state_payload("))
	h.expect(not body.is_empty(), "cli_fn_found", "找得到 _apply_team_match_state_payload")
	if body.is_empty():
		return
	h.expect(body.contains("pending_treasure"), "cli_reads_pending", "结算里仍然读 pending_treasure")
	h.expect(body.contains('get("compensated"'), "cli_reads_compensated", "读服务端补发的那件")
	h.expect(body.contains("TreasureService.add_owned("), "cli_add_owned",
		"入袋走 add_owned（只增）")
	# ★ 判别力：这段里**绝不能**出现 sync_owned_from_server —— 它会删掉服务端列表里
	#   没有的条目，而这里的字段只覆盖「本座位这一轮」，拿它裁决全部持有会吞玩家的宝物。
	#   文本断言必须先剥注释，否则我写在正文里的「不走 xxx」说明就会把这条判红。
	h.expect(not body.contains("sync_owned_from_server"), "cli_no_destructive_sync",
		"结算路径不许做以服务端为准的删除同步（那条路只在重连 resume 上）")

	# 语义证据：两个函数的差别就是「只增」和「会删」—— 上面那条选择不是随口说的。
	var saved: Array[String] = GameState.owned_treasures.duplicate()
	var pool := TreasureService.unowned_ids()
	if pool.size() >= 3:
		GameState.owned_treasures.assign([pool[0], pool[1], pool[2]])
		TreasureService.add_owned(pool[3])
		h.expect(GameState.owned_treasures.has(pool[0]) and GameState.owned_treasures.has(pool[3]),
			"cli_add_owned_is_additive", "add_owned 只增不删")
		TreasureService.sync_owned_from_server([pool[3]])
		h.expect(not GameState.owned_treasures.has(pool[0]), "cli_sync_is_subtractive",
			"sync_owned_from_server 会把服务端没报的条目删掉（所以不能用在结算路径上）")
	else:
		h.fail("cli_pool_too_small", "宝物池不足 3 件，无法验证只增/会删的差别")
	GameState.owned_treasures.assign(saved)

	# 重连那条路仍然以服务端为准（补偿靠它落到玩家手上）。同样只看活代码。
	var main_all := _strip_comments(FileAccess.get_file_as_string(MAIN_SRC).replace("\r\n", "\n"))
	h.expect(main_all.contains("sync_owned_from_server"), "cli_resume_sync",
		"重连 resume 仍然以服务端持有列表为准（补偿的落点）")
	var net_src := FileAccess.get_file_as_string(NET_SRC)
	var rs := _strip_comments(_fn_body(net_src.replace("\r\n", "\n"), "func _build_room_state("))
	h.expect(rs.contains('"owned_treasures"'), "cli_resume_carries_owned",
		"重连 payload 带着服务端持有列表")


# ── D. 回归 ─────────────────────────────────────────────────────────────────

func _section_regression() -> void:
	# 选宝主路径：仍然只能选发过的，选完全局记录，重复选被拒。
	var room := _room()
	var offer: Dictionary = NetworkService._server_pending_treasure(room, 0, _treasure_round)
	var cands: Array = offer.get("candidates", [])
	var forged: Dictionary = NetworkService._room_apply_treasure_choice(room, 0, "not_offered_xyz")
	h.expect(not bool(forged.get("ok", false)), "reg_forged_rejected", "没发过的 id 仍然拒收")
	if cands.is_empty():
		h.fail("reg_no_candidates", "藏宝回合没摇出候选")
		return
	var legit: Dictionary = NetworkService._room_apply_treasure_choice(room, 0, str(cands[0]))
	h.expect(bool(legit.get("ok", false)), "reg_legit_ok", "发过的 id 仍然入账")
	h.expect(NetworkService._room_owned_treasures(room, 0).has(str(cands[0])), "reg_recorded",
		"选中的那件进了服务端持有列表")
	var replay: Dictionary = NetworkService._room_apply_treasure_choice(room, 0, str(cands[0]))
	h.expect(not bool(replay.get("ok", false)), "reg_replay_rejected", "同一轮再选一次仍然拒收")
	h.expect(NetworkService._room_owned_treasures(room, 0).size() == 1, "reg_one_only",
		"选宝只入账一件")

	# 共用 helper 没改坏「胡牌手」的 +2 队血（选宝与补偿都走它）。
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	var requires: Array = []
	for link in links:
		if str((link as Dictionary).get("id", "")) == HU_PAI:
			requires = (link as Dictionary).get("requires", [])
	h.expect(requires.size() >= 2, "reg_hu_pai_requires", "找得到胡牌手的组成宝物")
	if requires.size() >= 2:
		var hp_room := _room()
		var start_hp := GameState.START_FORMATION_HP
		hp_room.team_hp = [start_hp - 4, start_hp]
		var partial: Array = []
		for i in range(requires.size() - 1):
			partial.append(str(requires[i]))
		hp_room.owned_treasures = {0: partial}
		h.expect(not TreasureService.has_linkage_in(partial, HU_PAI), "reg_hu_pai_partial",
			"少一件时联动未达成（前提体检）")
		NetworkService._room_grant_owned_treasure(hp_room, 0, str(requires[requires.size() - 1]))
		var hp_after: Array = hp_room.team_hp
		h.expect(int(hp_after[GameConstants.team_of_slot(0)]) == start_hp - 4 + 2,
			"reg_hu_pai_bonus", "凑齐胡牌手要 +2 队血，实际 %d" % int(hp_after[0]))
		h.expect(TreasureService.has_linkage_in(NetworkService._room_owned_treasures(hp_room, 0), HU_PAI),
			"reg_hu_pai_active", "联动确实达成了")

	# 候选只从「未拥有」里摇。
	var owned: Array = NetworkService._room_owned_treasures(room, 0)
	var pool: Array = NetworkService._server_roll_treasure_candidates(owned, 3)
	var clean := true
	for tid in pool:
		if owned.has(str(tid)):
			clean = false
	h.expect(clean, "reg_pool_unowned", "候选不会出现已经拥有的宝物")
	h.expect(pool.size() == 3, "reg_pool_size", "候选数量仍是 3，实际 %d" % pool.size())


# ── E. 判别力 ───────────────────────────────────────────────────────────────

func _section_discrimination() -> void:
	# (1) offer 已经被消费（选过了）—— 不能补。
	var consumed := _room()
	var offer: Dictionary = NetworkService._server_pending_treasure(consumed, 0, _treasure_round)
	var cands: Array = offer.get("candidates", [])
	if cands.is_empty():
		h.fail("disc_no_candidates", "藏宝回合没摇出候选")
		return
	NetworkService._room_apply_treasure_choice(consumed, 0, str(cands[0]))
	var after_pick := NetworkService._room_owned_treasures(consumed, 0).size()
	var expired: Dictionary = NetworkService._server_pending_treasure(consumed, 0, _plain_round)
	h.expect(str(expired.get("compensated", "")).is_empty(), "disc_consumed_not_compensated",
		"已经选过了就不能再补（否则正常玩家会白拿一件）")
	h.expect(NetworkService._room_owned_treasures(consumed, 0).size() == after_pick,
		"disc_consumed_count", "选过的座位持有数不变")

	# (2) 已经拿满 —— 不能补。
	var full := _room()
	var all_ids := TreasureService.unowned_ids()
	var five: Array = []
	for i in range(mini(TreasureService.MAX_OWNED, all_ids.size())):
		five.append(all_ids[i])
	full.owned_treasures = {0: five}
	full.treasure_offer = {0: {"round": _treasure_round, "candidates": [str(all_ids[0])], "refresh_index": 0}}
	var full_expired: Dictionary = NetworkService._server_pending_treasure(full, 0, _plain_round)
	h.expect(str(full_expired.get("compensated", "")).is_empty(), "disc_full_not_compensated",
		"已经拿满 %d 件就不能再补" % TreasureService.MAX_OWNED)
	h.expect(NetworkService._room_owned_treasures(full, 0).size() == five.size(),
		"disc_full_count", "拿满的座位持有数不变")

	# (2b) ★ 直接调补偿函数、且 offer 记的轮次**合法** —— 内层那道「拿满不补」必须自己顶住。
	#      只在 _server_pending_treasure 里验是不够的：那里**外层**的 MAX_OWNED 会先
	#      return，根本走不到补偿 ⇒ 内层这道删掉也照样全绿（变异 M2 实测 GREEN=假绿）。
	#      判据要打在机制自己身上，不能靠调用者的前置条件替它挡枪。
	var full_direct := _room()
	full_direct.owned_treasures = {0: five}
	full_direct.treasure_offer = {0: {"round": _treasure_round, "candidates": [str(all_ids[0])], "refresh_index": 0}}
	h.expect(NetworkService._server_compensate_missed_treasure(full_direct, 0).is_empty(),
		"disc_full_direct_no_grant", "直接调用补偿：拿满也不许补（内层上限自证）")
	h.expect(NetworkService._room_owned_treasures(full_direct, 0).size() == five.size(),
		"disc_full_direct_count", "直接调用补偿后持有数仍不变")

	# (3) 本来就没有 offer —— 不能补。
	var empty_room := _room()
	var none: Dictionary = NetworkService._server_pending_treasure(empty_room, 0, _plain_round)
	h.expect(str(none.get("compensated", "")).is_empty(), "disc_no_offer_not_compensated",
		"从没发过候选的座位不会被补")

	# (4) offer 记的轮次不是藏宝回合（数据被改坏/旧版本残留）—— 不猜，不补。
	var bogus := _room()
	bogus.treasure_offer = {0: {"round": _plain_round, "candidates": ["x"], "refresh_index": 0}}
	var bogus_got := NetworkService._server_compensate_missed_treasure(bogus, 0)
	h.expect(bogus_got.is_empty(), "disc_bogus_round", "轮次不合法的 offer 一律不补")
	h.expect(NetworkService._room_owned_treasures(bogus, 0).is_empty(), "disc_bogus_no_grant",
		"不补就不能凭空多出宝物")

	# (5) 别的座位不受影响：slot 0 补了，slot 1（没有 offer）不补。
	var two := _room()
	NetworkService._server_pending_treasure(two, 0, _treasure_round)
	NetworkService._server_pending_treasure(two, 0, _plain_round)
	NetworkService._server_pending_treasure(two, 1, _plain_round)
	h.expect(NetworkService._room_owned_treasures(two, 0).size() == 1, "disc_slot0_compensated",
		"座位 0 补到了")
	h.expect(NetworkService._room_owned_treasures(two, 1).is_empty(), "disc_slot1_untouched",
		"座位 1 没 offer，不该被牵连")

	# (6) 空转：补偿函数对没有 offer 的座位直接返回空串，不抛错。
	h.expect(NetworkService._server_compensate_missed_treasure(_room(), 3).is_empty(),
		"disc_idle_empty", "没有 offer 的座位返回空串")


# ── 工具 ────────────────────────────────────────────────────────────────────

# 取一个函数的函数体（到下一个顶格 func 为止）。先归一化行尾：源码是 CRLF，
# 直接找 "\nfunc " 会永远找不到。
func _fn_body(src: String, signature: String) -> String:
	var start := src.find(signature)
	if start < 0:
		return ""
	var rest := src.substr(start + signature.length())
	var end := rest.find("\nfunc ")
	return rest if end < 0 else rest.substr(0, end)


# ★ 剥掉整行注释与行尾注释后再做文本断言。
#   本仓踩过的坑：`contains("sync_owned_from_server")` 这类否定断言会被**自己的
#   解释性注释**满足或破坏 —— 写在注释里的反例说明一样能命中字符串。不剥注释，
#   结构断言就不是在测代码，而是在测注释的措辞。
func _strip_comments(text: String) -> String:
	var out: Array[String] = []
	for line in text.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		var cut := line.find("#")
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)
