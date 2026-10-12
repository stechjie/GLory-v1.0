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
				var prep: Dictionary = room.get("prep", {}).get(slot, {})
				var snapshot: Dictionary = room.get("last_board", {}).get(slot, {})
				var gold: Array = room.get("slot_gold", [])
				bot.gold = int(gold[slot]) if slot < gold.size() and gold[slot] != null else int(prep.get("gold", 0))
				bot.carrots = int(prep.get("carrots", 0))
				bot.carrot_spent = int(prep.get("merc_carrots_spent_total", 0))
				bot.tech = int(prep.get("harvest_tech_level", 0))
				bot.stone_draws = int(prep.get("stone_draw_count", 0))
				bot["races"] = Bot.RaceRules.resolve(room.get("seat_races", {}).get(slot, []))
				bot.treasures = room.get("owned_treasures", {}).get(slot, snapshot.get("treasures", [])).duplicate()
				var cells: Array = NetProtocol.extract_board(snapshot)
				var owned: Dictionary = prep.get("roster", {})
				if not owned.is_empty():
					cells = []
					for uid in owned:
						var entry: Dictionary = owned[uid]
						if str(entry.get("kind", "unit")) == "merc":
							continue
						for definition in DataRegistry.get_table("race_units").get("units", []):
							if str(definition.id) == str(entry.get("unit_id", "")):
								cells.append({"id": definition.id, "uid": str(uid), "def": definition,
									"star": int(entry.get("star", 1)), "cost_basis": int(entry.get("cost_basis", 0))})
								break
				for cell in cells:
					if cell is Dictionary:
						var d: Dictionary = cell.get("def", {})
						bot.roster.append({"id": str(cell.get("id", d.get("id", ""))),
							"uid": str(cell.get("uid", "")), "star": int(cell.get("star", 1)), "def": d.duplicate(true),
							"cost_basis": int(cell.get("cost_basis", EconomyLedger.unit_cost(d, bot.treasures)))})
				# The human seat has already harvested this prep round.
				if int(prep.get("last_harvest_round", -1)) == round_index:
					bot["skip_harvest_round"] = round_index
			bots[slot] = bot
		var pet := str(room.get("seat_pets", {}).get(slot, ""))
		bots[slot]["carrot_bonus_rate"] = PetService.carrot_bonus_rate(pet)
		bots[slot]["stones"] = NetworkService._room_team_stones(room, slot)
		Bot.prepare_round(bots[slot], round_index)
		mirror(room, slot, bots[slot])
	room["bot_states"] = bots
	return bots

static func mirror(room: Dictionary, slot: int, bot: Dictionary) -> void:
	var preps: Dictionary = room.get("prep", {})
	var prep: Dictionary = preps.get(slot, EconomyLedger.new_prep(int(bot.gold)))
	prep.merge({"gold": int(bot.gold), "carrots": int(bot.carrots),
		"harvest_tech_level": int(bot.tech), "merc_carrots_spent_total": int(bot.carrot_spent),
		"last_harvest_round": int(bot.round), "last_harvest_gain": int(bot.get("harvest_gain", 0)),
		"stone_draw_count": int(bot.stone_draws), "gold_spent_this_round": bool(bot.get("gold_spent_this_round", false))}, true)
	var roster := {}
	for unit in bot.roster:
		roster[str(unit.uid)] = {"unit_id": str(unit.id), "star": int(unit.star),
			"cost_basis": int(unit.get("cost_basis", 0)), "kind": "unit"}
	prep["roster"] = roster
	preps[slot] = prep
	room["prep"] = preps
	var gold: Array = room.get("slot_gold", [])
	if slot < gold.size():
		gold[slot] = int(bot.gold)
	var owned: Dictionary = room.get("owned_treasures", {})
	owned[slot] = bot.treasures.duplicate()
	room["owned_treasures"] = owned
