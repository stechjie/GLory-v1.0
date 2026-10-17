extends RefCounted
## AI 托管 -> 玩家收回座位时，把服务端账本落地成客户端的棋盘 / 备战席 / 佣兵席 / 金币。
##
## 数据来源是 room_state 的 `economy` 段（NetworkService._build_economy_state）：
##   roster[uid] = {unit_id, star, cost_basis, kind, slot?, merc_slot?}
##   gold / ai_handover_round / ai_handover_seq
##
## 为什么不复用 SaveManager.load_run()：那是**本地存档**，掉线期间它没有 AI 打的
## 任何一笔 —— 用它会得到掉线前那张空棋盘 + 起始金，正是 10.17 bug 文档第 1 条
## 那个现象（"AI 托管时棋子和经济与 AI 一致"这一侧的另一半）。
##
## 不用 class_name：新增全局类要靠编辑器导入才进 global_script_class_cache，
## 直接 --headless 跑检查场景时可能解析不到（同 ReconnectService / LiveBotEconomy 的写法）。


## 把一份 economy 段落进 GameState。返回是否真的改了棋盘。
static func apply(state: Dictionary) -> bool:
	var roster: Variant = state.get("roster", {})
	if typeof(roster) != TYPE_DICTIONARY or (roster as Dictionary).is_empty():
		return false
	var slots := build_slots(roster)
	if int(slots["placed"]) <= 0:
		return false
	GameState.board_slots = slots["board"]
	GameState.bench_slots = slots["bench"]
	GameState.mercenary_slots = slots["mercs"]
	GameState.gold = int(state.get("gold", GameState.gold))
	return true


## 纯函数：账本 roster -> {board(16), bench(8), mercs(8), placed, missing}。
##   * 带 `slot` 的棋子（LiveBotEconomy.mirror 写进去的 AI 站位）就落回那一格；
##   * 没 slot / 那一格被占 -> 先找棋盘空格，棋盘满了进备战席；
##   * 佣兵按 `merc_slot` 进佣兵席，越界或被占就找第一个空位；
##   * 单位 id 在数据表里查不到（旧版本棋子被删）时计 missing，绝不塞半个格子。
static func build_slots(roster: Dictionary) -> Dictionary:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	board.fill(null)
	var bench: Array = []
	bench.resize(GameState.BENCH_SLOTS)
	bench.fill(null)
	var mercs: Array = []
	mercs.resize(GameState.MERCENARY_SLOTS)
	mercs.fill(null)
	var placed := 0
	var missing := 0
	# Dictionary 的键序在不同 uid 生成顺序下不一样，显式排序让同一个账本永远落成同一张棋盘。
	var keys := roster.keys()
	keys.sort()
	for raw_uid in keys:
		var uid := str(raw_uid)
		if uid.is_empty():
			continue
		var raw_entry: Variant = roster[raw_uid]
		if typeof(raw_entry) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = raw_entry
		var unit_id := str(entry.get("unit_id", ""))
		var definition: Dictionary = DataRegistry.canonical_unit_def(unit_id)
		if definition.is_empty():
			missing += 1
			continue
		# canonical_unit_def 返回的是数据表里的**那一份本身**，必须复制再用。
		var cell := {"id": unit_id, "uid": uid, "star": int(entry.get("star", 1)),
			"def": definition.duplicate(true), "cost_basis": int(entry.get("cost_basis", 0))}
		if str(entry.get("kind", "unit")) == "merc":
			cell["is_mercenary"] = true
			(cell["def"] as Dictionary)["is_mercenary"] = true
			var merc_index := _place(mercs, int(entry.get("merc_slot", -1)))
			if merc_index < 0:
				continue
			mercs[merc_index] = cell
			placed += 1
			continue
		var index := _place(board, int(entry.get("slot", -1)))
		if index >= 0:
			board[index] = cell
		else:
			var bench_index := _place(bench, -1)
			if bench_index < 0:
				continue
			bench[bench_index] = cell
		placed += 1
	return {"board": board, "bench": bench, "mercs": mercs, "placed": placed, "missing": missing}


## 优先落到 wanted；wanted 越界或被占就找第一个空位。都满了返回 -1。
static func _place(target: Array, wanted: int) -> int:
	if wanted >= 0 and wanted < target.size() and target[wanted] == null:
		return wanted
	return target.find(null)
