extends RefCounted

# Public presentation only: never include tokens, account IDs or signed cards.
static func build(room: Dictionary, replays: Array, outcome: int, gold_authoritative: bool) -> Dictionary:
	var seats: Array = []
	var profiles: Dictionary = room.get("seat_profiles", {})
	for slot in 6:
		var snap: Dictionary = room.get("boards", {}).get(slot, {})
		var prep: Dictionary = room.get("prep", {}).get(slot, {})
		var profile: Dictionary = profiles.get(slot, {})
		var states: Array = room.get("slot_states", [])
		var occupied := str(states[slot]) != "empty" if slot < states.size() else not snap.is_empty()
		var fallback_name := "AI" if slot < states.size() and str(states[slot]) == "dummy" else "玩家%d" % (slot + 1)
		seats.append({
			"slot": slot,
			"name": AccountManager.display_name(str(profile.get("player_name", fallback_name)), str(profile.get("friend_code", ""))) if occupied else "空位",
			"board": units(snap.get("board", [])),
			"mercenaries": units(snap.get("mercenaries", [])),
			"treasures": display_treasures(room.get("owned_treasures", {}).get(slot, [])),
			"income_by_reason": prep.get("income_by_reason", {}).duplicate(),
			"stones": prep.get("stones_gained", {}).duplicate(),
			"total_gold": (GameState.START_GOLD + int(prep.get("battle_income_total", 0)) + int(prep.get("prep_income_total", 0) if gold_authoritative else snap.get("prep_income_total", 0))) if occupied else 0,
		})
	var stats: Array = []
	var allies := ["", ""]
	for side in replays.size():
		var replay: Dictionary = replays[side]
		var roster: Dictionary = replay.get("roster", {})
		for actor in roster.values():
			if bool(actor.get("is_formation_ally", false)):
				# PvP replays keep A=player and B=enemy in both views.
				var actor_side := (0 if str(actor.get("team", "")) == "player" else 1) if str(replay.get("kind", "")) == "pvp" else side
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
	for seat in seats:
		seat["round_damage"] = 0
	for entry in stats:
		var slot := int(entry.get("owner_slot", -1))
		if slot >= 0 and slot < seats.size():
			seats[slot].round_damage += maxi(0, int(entry.get("damage_dealt", 0)))
	stats.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("damage_dealt", 0)) != int(b.get("damage_dealt", 0)):
			return int(a.get("damage_dealt", 0)) > int(b.get("damage_dealt", 0))
		return str(a.get("owner_slot", 0)) + str(a.get("position", "")) < str(b.get("owner_slot", 0)) + str(b.get("position", "")))
	return {"can_return_room": str(room.get("mode", "custom")) == "custom" and not bool(room.get("matched", false)), "outcome": outcome, "seats": seats, "stats": stats, "allies": allies,
		"gold_authoritative": gold_authoritative, "show_details": not replays.is_empty() and str(replays[0].get("kind", "pve")) == "pvp"}

static func units(raw: Array) -> Array:
	var out: Array = []
	for index in raw.size():
		var cell: Variant = raw[index]
		if cell is Dictionary and not str(cell.get("id", "")).is_empty():
			out.append({"id": str(cell.id), "star": clampi(int(cell.get("star", 1)), 1, 4), "slot": int(cell.get("slot", index))})
	return out

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
