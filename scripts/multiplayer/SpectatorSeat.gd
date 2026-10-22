extends RefCounted

# 观战：把「上一回合冻结的某个座位的阵容」装进 GameState，让选手的备战界面原样画出来
# （用户口径：观战者看到的就是选手看到的界面，不加不减；延迟一回合，见 SpectatorService）。
#
# 只装**显示**要的字段。观战期间 SaveManager 不写盘（save_run 的观战守卫），
# 所以这些值不会落进观战者自己的存档；离开观战时 Main 再从存档读回来。
#
# 商店一律清空：设计定了观战不看商店（选手的商店是下一回合的信息）。

static func apply(view: Dictionary, state: Dictionary, slot: int) -> void:
	var seats: Dictionary = view.get("seats", {})
	var seat: Dictionary = seats.get(slot, seats.get(str(slot), {}))
	GameState.team_mode = true
	GameState.round_index = maxi(1, int(state.get("round_id", int(view.get("round", 0)) + 1)))
	GameState.FINAL_ROUND = int(state.get("final_round", GameState.FINAL_ROUND))
	GameState.final_round_played = false
	GameState.board_slots = _cells(seat.get("board", []), GameConstants.CELL_COUNT)
	GameState.bench_slots = _cells(seat.get("bench", []), GameState.BENCH_SLOTS)
	var mercs := _cells(seat.get("mercenaries", []), GameState.MERCENARY_SLOTS, true)
	GameState.mercenary_slots = mercs
	var treasures: Array[String] = []
	for id in (seat.get("treasures", []) as Array):
		treasures.append(str(id))
	GameState.owned_treasures = treasures
	var gold := int(seat.get("gold", -1))
	GameState.gold = gold if gold >= 0 else 0
	# 商店面板按格子下标读（ShopPanel.refresh），所以给满格的空位，而不是空数组。
	var offers := []
	var sold := []
	for _i in GameState.SHOP_UNIT_SLOTS:
		offers.append({})
		sold.append(false)
	GameState.shop_offers = offers
	GameState.shop_sold = sold
	# 两队血量：观战状态里两队都给（[红, 蓝]），按被看的那一队摆「我方 / 对方」。
	var hp: Array = state.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	if hp.size() == 2:
		var own := GameConstants.team_of_slot(slot)
		GameState.team_hp = int(hp[own])
		GameState.enemy_team_hp = int(hp[1 - own])


static func has_seat(view: Dictionary, slot: int) -> bool:
	var seats: Dictionary = view.get("seats", {})
	return seats.has(slot) or seats.has(str(slot))


# 快照里的格子已经由服务器洗过（NetProtocol.validate_team_snapshot / 机器人生成）。
# 再过一遍 sanitize_cell：补齐 def、丢掉坏格子 —— 观战者手里的数据同样来自网络。
# compact=true（佣兵）：按顺序排，不保留空位。
static func _cells(raw: Variant, size: int, compact: bool = false) -> Array:
	var out := []
	out.resize(size)
	out.fill(null)
	if typeof(raw) != TYPE_ARRAY:
		return out
	var next := 0
	for i in (raw as Array).size():
		var clean = NetProtocol.sanitize_cell((raw as Array)[i])
		if clean == null:
			continue
		var index := next if compact else i
		if index >= size:
			continue
		out[index] = clean
		next += 1
	return out
