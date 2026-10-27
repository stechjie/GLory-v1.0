extends RefCounted

static func duration(round_index: int, ruleset: String = "normal", mode: String = "") -> float:
	# A 13-round ranked match shares the schedule, not Seedling prep timing.
	if ruleset == "seedling" and not mode.begins_with("ranked"):
		return 60.0
	# Dedicated servers host both schedules at once; never read GameState.FINAL_ROUND here.
	var schedule: Dictionary = DataRegistry.get_table("rounds")
	if ruleset == "seedling":
		schedule = schedule.get("seedling", {})
	var final_round := int(schedule.get("final_round", 13 if ruleset == "seedling" else 21))
	if round_index == final_round:
		return 60.0
	for value in schedule.get("pvp_rounds", []):
		if int(value) == round_index:
			return 60.0
	return 45.0

static func remaining(room: Dictionary, now: float) -> float:
	if str(room.get("state", "")) != "prep":
		return -1.0
	return maxf(0.0, duration(int(room.get("round_index", 1)),
		str(room.get("ruleset", "normal")), str(room.get("mode", "custom"))) - (now - float(room.get("state_started_at", now))))

# Mutates only the supplied slots after all checks succeed. No free units or
# negative gold when a player has spent everything on refreshes/technology.
static func deploy(board: Array, bench: Array, offers: Array, sold: Array,
		gold: int, treasures: Array, cell_index: int, team_discount: bool = false) -> Dictionary:
	for cell in board:
		if cell is Dictionary:
			return {"changed": false, "gold": gold}
	if board.is_empty():
		return {"changed": false, "gold": gold}
	var target := clampi(cell_index, 0, board.size() - 1)
	for i in bench.size():
		if bench[i] is Dictionary:
			board[target] = bench[i]
			bench[i] = null
			return {"changed": true, "gold": gold, "bench_index": i}
	for i in offers.size():
		if i < sold.size() and bool(sold[i]):
			continue
		if not offers[i] is Dictionary or (offers[i] as Dictionary).is_empty():
			continue
		var d: Dictionary = offers[i]
		var cost := EconomyLedger.unit_cost(d, treasures, team_discount)
		if gold < cost:
			return {"changed": false, "gold": gold, "error": "not_enough_gold"}
		board[target] = {"id": str(d.get("id", "")), "star": 1,
			"def": d.duplicate(true), "cost_basis": cost}
		if sold.size() < offers.size():
			sold.resize(offers.size())
		sold[i] = true
		return {"changed": true, "gold": gold - cost, "shop_index": i, "cell_index": target, "cost": cost}
	return {"changed": false, "gold": gold, "error": "no_offer"}
