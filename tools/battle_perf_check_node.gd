extends Node

# 战斗模拟耗时与 replay 体积实测（B2 / B4 的决策数据来源）。
#
# 服务器是单线程同步主循环：算一场战斗的这段时间里，心跳、其他房间、清理全都停。
# 所以"最坏一场要多久"直接决定：一个进程能带几个房间、要开几个进程、要不要给
# 结算加并发闸、replay 要不要分块、阈值定多少。
#
# 这些数字此前**从来没量过**，文档里全是估算。本工具就是来把估算换成实测的。
#
# 不需要客户端、不需要 L2 测试台：直接驱动服务端会跑的那两个函数
# （compute_team_replay(0) / (1)），和 _room_compute_and_broadcast_replays 走的是同一条路。

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")

# 每个场景跑几遍取中位数。第一遍会包含数据表冷加载和各种 lazy init，不能算数。
const REPEATS := 5

func _ready() -> void:
	DataRegistry.load_all()
	print("[PERF] === 战斗模拟耗时实测 ===")
	print("[PERF] 硬上限: HARD_TIMEOUT=%.0fs TICK=%.2fs -> 最多 %d tick" % [
		BattleSimShared.HARD_TIMEOUT_SEC, BattleSimShared.TICK_SEC,
		int(BattleSimShared.HARD_TIMEOUT_SEC / BattleSimShared.TICK_SEC)])
	print("[PERF] 棋子上限=%d/人  佣兵上限=%d/人  每队 3 人" % [
		GameState.MAX_NORMAL_UNITS, GameState.MERCENARY_SLOTS])
	print("")

	# 由轻到重，看耗时怎么随规模涨
	_measure("典型 PVE（每人 4 兵，无佣兵）", 4, 0, 5, "pve")
	_measure("典型 PVP（每人 7 兵，无佣兵）", 7, 0, 5, "pvp")
	_measure("满棋盘 PVP（每人 7 兵 + 8 佣兵）", 7, 8, 5, "pvp")
	_measure("第 21 回合最终战（满配 + 血量友军）", 7, 8, GameState.FINAL_ROUND, "pvp")

	_measure_compression_cost()
	print("[PERF] 说明：单场 = compute_team_replay(0) 或 (1) 之一。")
	print("[PERF] 服务器每回合每房要算**两场**（A 队 + B 队），所以房间成本 = 单场 × 2。")
	get_tree().quit(0)

# 压缩本身也跑在主循环上，所以它的耗时同样要计入"这一帧被占用多久"。
# 如果压缩比模拟还贵，那"压缩换带宽"这笔账就不划算。
func _measure_compression_cost() -> void:
	_build_worst_case(7, GameState.MERCENARY_SLOTS, GameState.FINAL_ROUND)
	var replay: Dictionary = BattleSim.compute_team_replay(0)
	var t0 := Time.get_ticks_usec()
	var packed := var_to_bytes(replay)
	var ser_us := Time.get_ticks_usec() - t0
	var t1 := Time.get_ticks_usec()
	var zst := packed.compress(FileAccess.COMPRESSION_ZSTD)
	var zip_us := Time.get_ticks_usec() - t1
	var t2 := Time.get_ticks_usec()
	var back := zst.decompress(packed.size(), FileAccess.COMPRESSION_ZSTD)
	var unzip_us := Time.get_ticks_usec() - t2
	print("[PERF] 最坏 replay 的序列化/压缩开销（同样占用主循环）")
	print("[PERF]   var_to_bytes: %.1f ms   zstd 压缩: %.1f ms   解压(客户端): %.1f ms" % [
		ser_us / 1000.0, zip_us / 1000.0, unzip_us / 1000.0])
	print("[PERF]   %.1f KB -> %.1f KB；解压回 %d 字节" % [
		packed.size() / 1024.0, zst.size() / 1024.0, back.size()])
	print("")

# unit_count: 每个玩家棋盘上的棋子数
# merc_count: 每个玩家佣兵栏的佣兵数
func _measure(label: String, unit_count: int, merc_count: int, round_index: int, _kind: String) -> void:
	var times: Array = []
	var frames := 0
	var raw_bytes := 0
	var zstd_bytes := 0
	var roster := 0
	var reason := ""

	for i in REPEATS:
		_build_worst_case(unit_count, merc_count, round_index)
		var t0 := Time.get_ticks_usec()
		var replay: Dictionary = BattleSim.compute_team_replay(0)
		var elapsed := Time.get_ticks_usec() - t0
		times.append(elapsed)
		if i == REPEATS - 1:
			var f: Array = replay.get("frames", [])
			frames = f.size()
			var packed := var_to_bytes(replay)
			raw_bytes = packed.size()
			zstd_bytes = packed.compress(FileAccess.COMPRESSION_ZSTD).size()
			# roster 的容器类型不固定，用类型无关的方式数
			var roster_value = replay.get("roster", [])
			if typeof(roster_value) == TYPE_ARRAY:
				roster = (roster_value as Array).size()
			elif typeof(roster_value) == TYPE_DICTIONARY:
				roster = (roster_value as Dictionary).size()
			reason = str((replay.get("result", {}) as Dictionary).get("reason", ""))

	times.sort()
	var median: int = times[times.size() / 2]
	var worst: int = times[times.size() - 1]
	print("[PERF] %s" % label)
	print("[PERF]   单场耗时: 中位 %.1f ms / 最慢 %.1f ms" % [median / 1000.0, worst / 1000.0])
	print("[PERF]   一房一回合(两场): 中位 %.1f ms" % [median * 2 / 1000.0])
	print("[PERF]   帧数=%d  单位数=%d  结束原因=%s" % [frames, roster, reason])
	print("[PERF]   replay 体积: 原始 %.1f KB -> zstd %.1f KB (压缩率 %.2f)" % [
		raw_bytes / 1024.0, zstd_bytes / 1024.0, float(zstd_bytes) / maxf(1.0, float(raw_bytes))])
	print("")

# 构造一个"合法范围内尽可能重"的 3v3 局面：六个座位全是真人、棋盘和佣兵栏都填满。
func _build_worst_case(unit_count: int, merc_count: int, round_index: int) -> void:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = round_index
	# 第 21 回合会按水晶血量召唤友军，血量拉满走最重的那一档
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP

	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	assert(not units.is_empty(), "race_units 表为空")

	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	for i in mini(unit_count, GameConstants.CELL_COUNT):
		# 轮换不同单位：技能分支越杂，越接近真实最坏情况（同一个单位重复会让
		# 分支预测和缓存都偏乐观）
		var def: Dictionary = (units[i % units.size()] as Dictionary).duplicate(true)
		board[i] = {"id": def.get("id", "unit"), "star": 3, "def": def}

	var merc_slots: Array = []
	merc_slots.resize(GameState.MERCENARY_SLOTS)
	if not mercs.is_empty():
		for i in mini(merc_count, GameState.MERCENARY_SLOTS):
			var mdef: Dictionary = (mercs[i % mercs.size()] as Dictionary).duplicate(true)
			merc_slots[i] = {"id": mdef.get("id", "merc"), "star": 1, "def": mdef}

	GameState.board_slots = board.duplicate(true)
	GameState.mercenary_slots = merc_slots.duplicate(true)

	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = 987654321
	# 六席全真人 = 最多的单位、最多的羁绊计算
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var submission := NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots)
	var boards: Dictionary = {}
	for slot in 6:
		boards[slot] = submission.duplicate(true)
	NetworkService.team_boards = boards
