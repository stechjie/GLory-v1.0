extends RefCounted

# 备战界面的**规则查询** —— D2 第二步。
#
# 这里全是「这一步合不合法 / 上限是多少 / 还有没有空位」这类问题。
# 它们只读 GameState 与 autoload（TutorialMode / DataRegistry / RoundService），
# 不碰备战界面的任何成员变量 —— 也就是说，它们从来不需要「宿主」。
#
# 为什么要抽：
# README 的 D2 要让五个面板通过明确的输入事件与 PrepFlowController 通信。
# 但面板在**决定要不要发出事件之前**得先知道「这步能不能做」——
# 拖到这一格合法吗？待命区还有位置吗？这个单位上场数到上限了吗？
# 如果这些还留在宿主身上，面板就得为了问一句话去调宿主，
# 那条依赖会一直把面板拴住。
#
# 与 EconomyLedger 的分工：
#   EconomyLedger  服务端权威账本，**不许读 GameState**（几百个房间会串）
#   PrepRules      客户端界面用，GameState 就是当前这一局，直接读没有问题
# 两者规则重叠的部分（升星份数、星级上限、单位定价）已经统一到
# GameConstants / EconomyLedger 的静态函数，这里只是把它们组合成界面要问的问题。
#
# 全静态、不持状态。

const CheckMaxStar := preload("res://scripts/core/GameConstants.gd")


# --- 上场限制 -----------------------------------------------------------------

# 同名单位允许同时上场的数量上限。数据表不写就是 1。
static func board_limit_for_def(d: Dictionary) -> int:
	return maxi(1, int(d.get("board_limit", 1)))


# 场上同名单位是否已达上限。
# ignore_index 用于「把这一格挪到别处」的判定 —— 自己不该算进自己的上限里。
static func has_unique_board_unit(unit_id: String, limit: int = 1, ignore_index: int = -1) -> bool:
	if unit_id.is_empty():
		return false
	var count := 0
	for i in GameState.board_slots.size():
		if i == ignore_index:
			continue
		var cell = GameState.board_slots[i]
		if cell != null and str(cell.get("id", "")) == unit_id:
			count += 1
	return count >= maxi(1, limit)


# --- 合成 ---------------------------------------------------------------------

# 两格能不能合：同名、同星、且没到满星。
# 满星判定用 GameState.MAX_UNIT_STAR，它再导出自 GameConstants.MAX_STAR ——
# 与服务端账本 EconomyLedger._merge() 的封顶读的是同一个常量。
static func can_merge_cells(target: Dictionary, incoming: Dictionary) -> bool:
	if target.is_empty() or incoming.is_empty():
		return false
	return str(target.get("id", "")) == str(incoming.get("id", "")) \
		and int(target.get("star", 1)) == int(incoming.get("star", 1)) \
		and int(target.get("star", 1)) < GameState.MAX_MERGE_STAR


# 这一格是不是「可用于合成的同名同星棋子」。
# 传进来的可能是 null（空格），所以先查类型，不能直接当 Dictionary 用。
static func is_merge_piece(cell: Variant, id: String, star: int) -> bool:
	if typeof(cell) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = cell
	return str(d.get("id", "")) == id and int(d.get("star", 1)) == star


# --- 出售 ---------------------------------------------------------------------

# 我方当前拥有的棋子总数（棋盘 + 备战席）。
# 佣兵不计入：佣兵是花萝卜/金币临时雇的（`GameState.mercenary_slots`），
# 和"自己攒出来的棋子"是两套东西，不能拿它去顶"还有没有棋子可用"。
static func owned_unit_count() -> int:
	var count := 0
	for cell in GameState.board_slots:
		if cell != null:
			count += 1
	for cell in GameState.bench_slots:
		if cell != null:
			count += 1
	return count


# 还能不能卖棋子：**只剩最后一枚时不允许出售**。
#
# 原因（9.10 测试报告）：卖掉最后一枚之后，玩家既没有能上场的棋子，
# 又可能因为金币不足买不起商店里的棋子 —— 于是这一回合直接变成"空棋盘挨打"的死局，
# 且没有任何手段可以补救（商店刷新也要钱）。与其让玩家自己承担这个不可逆的后果，
# 不如在出口处直接挡住。
#
# 服务端账本 EconomyLedger._sell() 有同一条规则（错误码 last_unit），
# 权威经济打开后由服务端兜底，两者口径一致。
static func can_sell_unit() -> bool:
	return owned_unit_count() > 1


# --- 空位 ---------------------------------------------------------------------

static func first_empty_bench_slot() -> int:
	for i in GameState.bench_slots.size():
		if GameState.bench_slots[i] == null:
			return i
	return -1


static func first_empty_mercenary_slot() -> int:
	for i in GameState.mercenary_slots.size():
		if GameState.mercenary_slots[i] == null:
			return i
	return -1


static func bench_count() -> int:
	var count := 0
	for cell in GameState.bench_slots:
		if cell != null:
			count += 1
	return count


# --- 拖放合法性 ---------------------------------------------------------------

# 拖放的 data 是 {"kind": "shop"|"board"|"bench", "index": int}。
# 三种来源的判定完全不同，所以用 match 而不是一串 if —— 漏一种会静默返回 false，
# 表现是「这个东西怎么拖不动」，没有任何报错。
static func can_drop_on_board(board_index: int, data: Variant) -> bool:
	if board_index < 0 or board_index >= GameState.board_slots.size() or typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	match str(d.get("kind", "")):
		"shop":
			# 教学关不允许从商店直接拖上场：教学要玩家按步骤点击购买。
			if GameState.tutorial_mode:
				return false
			var idx := int(d.get("index", -1))
			return idx >= 0 and idx < GameState.shop_offers.size() and not bool(GameState.shop_sold[idx])
		"board":
			return int(d.get("index", -1)) != board_index
		"bench":
			if GameState.tutorial_mode and TutorialMode.step == TutorialMode.Step.BUY_3:
				return false
			return int(d.get("index", -1)) >= 0
	return false


static func can_drop_on_bench(bench_index: int, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	match str(d.get("kind", "")):
		"shop":
			var idx := int(d.get("index", -1))
			return idx >= 0 and idx < GameState.shop_offers.size() and not bool(GameState.shop_sold[idx])
		"board":
			var idx2 := int(d.get("index", -1))
			return idx2 >= 0 and idx2 < GameState.board_slots.size()
		"bench":
			return int(d.get("index", -1)) != bench_index
	return false


# --- 佣兵 ---------------------------------------------------------------------

static func can_hire_mercenary(index: int) -> bool:
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if index < 0 or index >= mercs.size():
		return false
	if first_empty_mercenary_slot() < 0:
		return false
	var merc: Dictionary = mercs[index]
	# 教学流程仍使用旧金币教程；正式对局的佣兵统一使用萝卜。
	if GameState.tutorial_mode:
		return GameState.gold >= int(merc.get("cost", 0))
	var carrot_cost := int(merc.get("carrot_cost", -1))
	return carrot_cost >= 0 and GameState.carrots >= carrot_cost


# --- 回合 ---------------------------------------------------------------------

# 下一场战斗的类型。组队模式走固定赛程；教学关的类型来自 TutorialMode ——
# 与 BattleScreen 用的是同一个来源，所以界面标签永远和实际打的那一场一致。
static func next_round_kind() -> String:
	if GameState.team_mode:
		return RoundService.schedule_kind_for_round(GameState.round_index)
	return TutorialMode.battle_kind()
