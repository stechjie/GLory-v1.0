extends RefCounted

const Bot := preload("res://scripts/economy/BotPlayer.gd")

static func prepare(room: Dictionary) -> Dictionary:
	var bots: Dictionary = room.get("bot_states", {})
	var states: Array = room.get("slot_states", [])
	var round_index := int(room.get("round_index", 1))
	for slot in states.size():
		if str(states[slot]) != "dummy":
			bots.erase(slot)
			continue
		if not bots.has(slot):
			var bot := Bot.new_state(room.get("shared_seed", 0), slot)
			# A disconnected player keeps their real balance and owned units.
			# Never grant a round-N estimated army to a bankrupt player.
			var initial: Array = room.get("initial_seats", [])
			if slot < initial.size() and str(initial[slot]) == "player":
				_seed_from_human(bot, room, slot, round_index)
			bots[slot] = bot
		var pet := str(room.get("seat_pets", {}).get(slot, ""))
		bots[slot]["carrot_bonus_rate"] = PetService.carrot_bonus_rate(pet)
		bots[slot]["stones"] = NetworkService._room_team_stones(room, slot)
		Bot.prepare_round(bots[slot], round_index)
		mirror(room, slot, bots[slot])
	room["bot_states"] = bots
	return bots


# 座位账本可能以 int 或 String 作键（旧快照 / JSON 往返），两种都认。
static func _prep_for(room: Dictionary, slot: int) -> Dictionary:
	var preps: Dictionary = room.get("prep", {})
	var raw: Variant = preps.get(slot, preps.get(str(slot), null))
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	return {}


# 接管一个真人座位：把他离线那一刻的账本**整份**搬进 bot，再让 bot 在这份状态上继续打。
#
# 以前这里只搬了金币和一部分棋子：佣兵被 `kind == "merc"` 跳过、商店另摇一批、
# 站位每次重排、mirror 又不回写佣兵与商店 —— 玩家回来看到的就是"凭空一套"
# （10.17 bug 文档第 1 条）。
static func _seed_from_human(bot: Dictionary, room: Dictionary, slot: int, round_index: int) -> void:
	var prep: Dictionary = _prep_for(room, slot)
	var snapshot: Dictionary = room.get("last_board", {}).get(slot, {})
	var gold: Array = room.get("slot_gold", [])
	bot.gold = int(gold[slot]) if slot < gold.size() and gold[slot] != null else int(prep.get("gold", 0))
	bot.carrots = int(prep.get("carrots", 0))
	bot.carrot_spent = int(prep.get("merc_carrots_spent_total", 0))
	bot.tech = int(prep.get("harvest_tech_level", 0))
	bot.stone_draws = int(prep.get("stone_draw_count", 0))
	bot["races"] = Bot.RaceRules.resolve(room.get("seat_races", {}).get(slot, []))
	bot.treasures = room.get("owned_treasures", {}).get(slot, snapshot.get("treasures", [])).duplicate()
	var owned: Dictionary = prep.get("roster", {})
	bot.mercs = _mercs_from_roster(owned)
	# 佣兵只活一轮，但接管是**半路**接手：他这一轮雇的还在场上，所以这一轮不清，
	# 下一轮由 prepare_round 按 merc_round 照常过期。
	bot["merc_round"] = round_index
	var cells: Array = NetProtocol.extract_board(snapshot)
	if not owned.is_empty():
		# 账本比棋盘快照更权威：快照可能是上一轮提交的那一份。
		cells = []
		for uid in owned:
			var entry: Dictionary = owned[uid]
			if str(entry.get("kind", "unit")) == "merc":
				continue
			var definition: Dictionary = DataRegistry.canonical_unit_def(str(entry.get("unit_id", "")))
			if definition.is_empty():
				continue
			cells.append({"id": str(definition.get("id", "")), "uid": str(uid), "def": definition,
				"star": int(entry.get("star", 1)), "cost_basis": int(entry.get("cost_basis", 0))})
	for cell in cells:
		if cell is Dictionary:
			var d: Dictionary = cell.get("def", {})
			bot.roster.append({"id": str(cell.get("id", d.get("id", ""))),
				"uid": str(cell.get("uid", "")), "star": int(cell.get("star", 1)), "def": d.duplicate(true),
				"cost_basis": int(cell.get("cost_basis", EconomyLedger.unit_cost(d, bot.treasures)))})
	_seed_shop(bot, prep, round_index)
	# The human seat has already harvested this prep round.
	if int(prep.get("last_harvest_round", -1)) == round_index:
		bot["skip_harvest_round"] = round_index


# 账本里的佣兵记录（kind == "merc"）-> bot.mercs。`merc_slot` 一起带过来，
# 玩家收回座位时才能落回同一个佣兵席。
static func _mercs_from_roster(owned: Dictionary) -> Array:
	var out: Array = []
	if owned.is_empty():
		return out
	for uid in owned:
		var entry: Dictionary = owned[uid]
		if str(entry.get("kind", "unit")) != "merc":
			continue
		var definition: Dictionary = DataRegistry.canonical_unit_def(str(entry.get("unit_id", "")))
		if definition.is_empty():
			continue
		out.append({"id": str(definition.get("id", "")), "uid": str(uid),
			"star": int(entry.get("star", 1)), "def": definition.duplicate(true),
			"is_mercenary": true, "cost_basis": int(entry.get("cost_basis", 0)),
			"merc_slot": int(entry.get("merc_slot", -1))})
	return out


# 玩家离线那一刻的商店（服务端每轮开始替他摇的那一批）。AI 接着从这批招，
# 花掉的格子标 sold —— 玩家回来接的就是同一个货架，而不是重新摇一份新的。
static func _seed_shop(bot: Dictionary, prep: Dictionary, round_index: int) -> void:
	var shop: Dictionary = prep.get("shop", {})
	var offers: Array = shop.get("offers", [])
	if offers.is_empty():
		return
	var sold: Array = (shop.get("sold", []) as Array).duplicate()
	while sold.size() < offers.size():
		sold.append(false)
	bot["shop"] = {"round": round_index, "offer_id": str(shop.get("offer_id", "")),
		"offers": offers.duplicate(true), "sold": sold,
		"refresh_uses": int(shop.get("refresh_uses", 0))}

static func mirror(room: Dictionary, slot: int, bot: Dictionary) -> void:
	var preps: Dictionary = room.get("prep", {})
	var prep: Dictionary = {}
	var raw_prep: Variant = preps.get(slot, preps.get(str(slot), null))
	if typeof(raw_prep) == TYPE_DICTIONARY:
		prep = raw_prep
	else:
		prep = EconomyLedger.new_prep(int(bot.gold))
	prep.merge({"gold": int(bot.gold), "carrots": int(bot.carrots),
		"harvest_tech_level": int(bot.tech), "merc_carrots_spent_total": int(bot.carrot_spent),
		"last_harvest_round": int(bot.round), "last_harvest_gain": int(bot.get("harvest_gain", 0)),
		"stone_draw_count": int(bot.stone_draws), "gold_spent_this_round": bool(bot.get("gold_spent_this_round", false))}, true)
	# 站位一起写进账本：`slot` 是这一枚在棋盘上的格子下标，玩家收回座位时按它落位。
	var slots: Dictionary = Bot.board_slots(bot)
	var roster := {}
	for unit in bot.roster:
		var uid := str(unit.get("uid", ""))
		roster[uid] = {"unit_id": str(unit.id), "star": int(unit.star),
			"cost_basis": int(unit.get("cost_basis", 0)), "kind": "unit",
			"slot": int(slots.get(uid, -1))}
	# 佣兵也要回写。以前这里只写 bot.roster —— 玩家花萝卜雇的佣兵回来时凭空消失。
	for raw_merc in bot.mercs:
		var merc: Dictionary = raw_merc
		var merc_uid := str(merc.get("uid", ""))
		if merc_uid.is_empty():
			continue
		roster[merc_uid] = {"unit_id": str(merc.get("id", "")), "star": int(merc.get("star", 1)),
			"cost_basis": int(merc.get("cost_basis", 0)), "kind": "merc",
			"merc_slot": int(merc.get("merc_slot", -1))}
	prep["roster"] = roster
	# 商店：AI 花掉哪一格、刷新过几次，原样回写。
	var shop: Dictionary = bot.get("shop", {})
	if not (shop.get("offers", []) as Array).is_empty():
		prep["shop"] = {"offer_id": _bot_offer_id(slot, int(bot.get("round", 0)), int(shop.get("refresh_uses", 0))),
			"offers": (shop.get("offers", []) as Array).duplicate(true),
			"sold": (shop.get("sold", []) as Array).duplicate(),
			"refresh_uses": int(shop.get("refresh_uses", 0))}
	preps[slot] = prep
	room["prep"] = preps
	var gold: Array = room.get("slot_gold", [])
	if slot < gold.size():
		gold[slot] = int(bot.gold)
	var owned: Dictionary = room.get("owned_treasures", {})
	owned[slot] = bot.treasures.duplicate()
	room["owned_treasures"] = owned


# 客户端认 offer_id 变了才会重新采纳这批商店（PrepBoardController._adopt_server_shop）。
# 人摇出来的 id 是随机 hex，这里给一个确定性的 —— 只要 AI 接管过就一定不同。
static func _bot_offer_id(slot: int, round_index: int, refresh_uses: int) -> String:
	return "bot_%d_%d_%d" % [slot, round_index, refresh_uses]
