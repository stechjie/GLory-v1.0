extends RefCounted

# Public presentation only: never include tokens, account IDs or signed cards.
static func build(room: Dictionary, replays: Array, outcome: int, gold_authoritative: bool) -> Dictionary:
	var seats: Array = []
	var profiles: Dictionary = room.get("seat_profiles", {})
	for slot in 6:
		var snap: Dictionary = room.get("battle_loadouts", {}).get(slot, room.get("boards", {}).get(slot, {}))
		var prep: Dictionary = room.get("prep", {}).get(slot, {})
		var owned: Array = snap.get("treasures", []) if bool(snap.get("is_ai", false)) else room.get("owned_treasures", {}).get(slot, [])
		var profile: Dictionary = profiles.get(slot, {})
		var states: Array = room.get("slot_states", [])
		var occupied := str(states[slot]) != "empty" if slot < states.size() else not snap.is_empty()
		var fallback_name := "AI" if slot < states.size() and str(states[slot]) == "dummy" else "玩家%d" % (slot + 1)
		seats.append({
			"slot": slot,
			# 10.04 bug 文档第 5 条：结算面板只显示昵称（隐藏 #好友码）。
			"name": AccountManager.display_name(str(profile.get("player_name", fallback_name)), str(profile.get("friend_code", "")), false) if occupied else "空位",
			"board": units(snap.get("board", [])),
			"mercenaries": units(snap.get("mercenaries", [])),
			"treasures": display_treasures(owned),
			"owned_treasures": owned.duplicate(),
			"income_by_reason": prep.get("income_by_reason", {}).duplicate(),
			"stones": (snap.get("stones_gained", {}) if bool(snap.get("is_ai", false)) else prep.get("stones_gained", {})).duplicate(),
			"total_gold": (GameState.START_GOLD + int(prep.get("battle_income_total", 0)) + int(prep.get("prep_income_total", 0) if gold_authoritative else snap.get("prep_income_total", 0))) if occupied else 0,
		})
	var stats: Array = []
	var element_by_slot := {}
	var allies := ["", ""]
	for side in replays.size():
		var replay: Dictionary = replays[side]
		var roster: Dictionary = replay.get("roster", {})
		for actor in roster.values():
			if bool(actor.get("is_formation_ally", false)):
				# PvP replays keep A=player and B=enemy in both views.
				var actor_side := (0 if str(actor.get("team", "")) == "player" else 1) if str(replay.get("kind", "")) in ["pvp", "final"] else side
				var actor_name := str(actor.get("name", "")).strip_edges()
				if actor_name.is_empty():
					actor_name = str(actor.get("def", {}).get("name", ""))
				if not actor_name.is_empty():
					allies[actor_side] = actor_name
		var raw: Dictionary = replay.get("result", {}).get("unit_stats", {})
		for entry in raw.values():
			var slot := int(entry.get("owner_slot", -1))
			# Each replay includes both sides in PvP. Select its own side exactly once.
			if slot < side * 3 or slot >= side * 3 + 3 or str(entry.get("group", "")) == "boss":
				continue
			stats.append(entry.duplicate(true))
		# 10.09 bug 文档第 4 条：无归属棋子的元素伤害（自爆灵死亡爆炸及其毒、寄生灵分身）
		# 用**同一套边选择口径**收进来，再并进席位总伤害。键在 JSON 里会变成字符串，
		# 所以一律 int() 归一。
		var raw_element: Variant = (replay.get("result", {}) as Dictionary).get("element_damage_by_slot", {})
		if typeof(raw_element) == TYPE_DICTIONARY:
			var element_map: Dictionary = raw_element
			for key in element_map.keys():
				var element_slot := int(key)
				if element_slot < side * 3 or element_slot >= side * 3 + 3:
					continue
				element_by_slot[element_slot] = int(element_by_slot.get(element_slot, 0)) + int(element_map[key])
	update_round_damage(seats, stats, element_by_slot)
	stats.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("damage_dealt", 0)) != int(b.get("damage_dealt", 0)):
			return int(a.get("damage_dealt", 0)) > int(b.get("damage_dealt", 0))
		return str(a.get("owner_slot", 0)) + str(a.get("position", "")) < str(b.get("owner_slot", 0)) + str(b.get("position", "")))
	var kind := str(replays[0].get("kind", "pve")) if not replays.is_empty() else "pve"
	# 10.07 bug 文档第 8 条：任何回合结束都有结算面板（PVE 也要算我方上阵佣兵的数据）
	# ⇒ 任何 kind 都能看详细战况。以前这里是 `kind in ["pvp", "final"]`，正是它把
	# PVE 回合的「查看详情」按钮吞掉的（面板照建，只是按钮不出现，看着像没结算）。
	return {"can_return_room": str(room.get("mode", "custom")) == "custom" and not bool(room.get("matched", false)), "outcome": outcome, "seats": seats, "stats": stats, "allies": allies,
		"element_damage_by_slot": element_by_slot,
		"match_uid": str(room.get("match_uid", "")), "mode": str(room.get("mode", "custom")),
		"kind": kind, "gold_authoritative": gold_authoritative, "show_details": true}

static func units(raw: Array) -> Array:
	var out: Array = []
	for index in raw.size():
		var cell: Variant = raw[index]
		if cell is Dictionary and not str(cell.get("id", "")).is_empty():
			out.append({"id": str(cell.id), "star": clampi(int(cell.get("star", 1)), 1, 4), "slot": int(cell.get("slot", index))})
	return out

# 10.09 bug 文档第 4 条：`element_by_slot` 是「没有棋子身份的元素伤害」账本
# （自爆灵死亡爆炸及其毒、寄生灵分身），只并进席位总伤害，不进逐棋子的 stats。
# 默认空表 ⇒ 没有这一项的旧记录/旧调用行为与以前完全一致。
static func update_round_damage(seats: Array, stats: Array, element_by_slot: Dictionary = {}) -> void:
	for seat in seats:
		seat["round_damage"] = 0
	for entry in stats:
		var slot := int(entry.get("owner_slot", -1))
		if slot >= 0 and slot < seats.size():
			seats[slot].round_damage += int(entry.get("damage_dealt", 0))
	for key in element_by_slot.keys():
		var element_slot := int(key)
		if element_slot >= 0 and element_slot < seats.size():
			seats[element_slot].round_damage += int(element_by_slot[key])

# Eligibility is a property of the completed battle, never of who won it.
# Older servers omit show_details; their match_state still contains kind.
#
# 10.07 bug 文档第 8 条：任何回合结束都有结算面板（PVE 回合也要算我方上阵佣兵的
# 数据）⇒ 这里对所有 kind 一律放行。判据本身保留（它还要认 model 里现成的
# show_details），只是不再按战斗种类把 PVE 挡在外面。
static func can_show_details(data: Dictionary, match_state: Dictionary, replay: Dictionary = {}) -> bool:
	var kind := str(match_state.get("kind", replay.get("kind", data.get("kind", ""))))
	if not kind.is_empty():
		return true
	return bool(data.get("show_details", false))

# Offline/custom local-host battles do not receive a server match_state.
# Capture their actual boards before Main clears mercenaries/advances the round.
static func build_local(replays: Array) -> Dictionary:
	var sim := preload("res://scripts/battle/BattleSimulator.gd")
	var states: Array = NetworkService.team_slot_states if NetworkService.team_active else GameState.team_slot_states
	var room := {"slot_states": states, "boards": {}, "owned_treasures": {}, "mode": "local"}
	for slot in 6:
		room.boards[slot] = {"board": sim._team_board_for_slot(slot, RngService.rng), "mercenaries": sim._team_mercs_for_slot(slot, RngService.rng)}
		room.owned_treasures[slot] = sim._team_owner_ctx_for_slot(slot).get("treasures", [])
	var data := build(room, replays, TeamOutcome.DRAW, false)
	data["local_team"] = GameConstants.team_of_slot(NetworkService.team_local_slot) if NetworkService.team_active else 0
	# The local path has no per-seat cumulative gold/stone ledger. Do not present
	# starting gold or remaining stones as lifetime earnings.
	for seat in data.seats:
		seat["total_gold"] = null
	return data

static func display_treasures(owned: Array) -> Array:
	var out := owned.duplicate()
	for link in DataRegistry.get_table("treasures").get("linkages", []):
		var id := str(link.get("id", ""))
		if TreasureService.has_linkage_in(owned, id) and not out.has(id):
			out.append(id)
	for category in TreasureService.SET_CATEGORIES:
		if TreasureService.has_set_in(owned, category):
			out.append(TreasureService.set_id(category))
	return out
