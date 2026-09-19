extends RefCounted

# 出战种族的**规则** —— 备战界面、本机摇商店、战斗服务器、门禁共用同一份（同 ShopRoll）。
#
# 玩法（2026-09-15 定）：每名玩家在备战界面选定 PICK_COUNT 个种族，对局里**自己的**
# 商店只刷这几族的棋子。3v3 每人各选各的 —— 商店本来就是每个座位各摇各的、
# 没有共享牌库，谁选什么互不影响。
#
# 为什么是「正好 4 个」：卡池越浅，同名棋子越容易刷到、升星越快。以后种族变多，
# 每人的池子仍是 4 族的量，今天调好的升星节奏不会被稀释。反过来也说明
# **少选就是作弊**：服务器必须自己核对（NetworkService._room_accept_seat_races），
# 不能信客户端。
#
# 种族列表从棋子表里读，不在这里写死 —— 加一族棋子，备战界面自动多一张卡。
# 但加新族**不只是加表行**：羁绊计数、服务端羁绊重算、羁绊栏、种族图标、种族名、
# 战斗特效各有一处写死了四族（SynergyService.count_races_from_board 等），要一起改。
# 并且战斗服务器的数据必须先于或同时于客户端更新：客户端多一族、服务器不认识，
# 选了那一族的玩家会按不下准备。
#
# 全静态、不持状态。只读 DataRegistry，不读 PlayerProfile / GameState ——
# 服务器上几百个座位共用这份规则，「当前玩家」在那里没有意义。

const PICK_COUNT := 4


# 棋子表里出现过的全部种族，按首次出现的顺序（与羁绊栏一致：神、暗、灵、人）。
static func all_races() -> Array[String]:
	var out: Array[String] = []
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var race := str((raw as Dictionary).get("race", ""))
		if not race.is_empty() and not out.has(race):
			out.append(race)
	return out


# 实际要选几个。种族总数不足 PICK_COUNT 时只能全选 —— 否则「必须选 4 个」
# 永远达不成，谁都准备不了。
static func required_count() -> int:
	return mini(PICK_COUNT, all_races().size())


# 种族总数没有超过要选的数量 = 没得选（今天四族选四个就是这样），界面整页锁定。
static func is_forced() -> bool:
	return all_races().size() <= PICK_COUNT


# 某一族在棋子表里有几个棋子（界面卡片上显示）。
static func unit_count(race: String) -> int:
	var n := 0
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) == TYPE_DICTIONARY and str((raw as Dictionary).get("race", "")) == race:
			n += 1
	return n


# 清洗一份来路不明的选择（网络包、存档）。合法就返回按 all_races() 顺序排好的副本，
# 不合法一律返回空数组。
#
# **不帮忙修**：少一族就补、多一族就砍，等于替改过包的客户端把包改对。
# 来路：出战名片（账号服务器只查资格、不管个数）、账号服务器的答复、局内存档。
#
# 先判容器大小再遍历（NetProtocol 顶部那条：来路是网络的容器必须在常数级步数内被拒）。
static func sanitize(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		return out
	var arr: Array = value
	var known := all_races()
	var need := mini(PICK_COUNT, known.size())
	if need <= 0 or arr.size() != need:
		return out
	var picked := {}
	for raw in arr:
		if typeof(raw) != TYPE_STRING and typeof(raw) != TYPE_STRING_NAME:
			return out
		var race := str(raw)
		if not known.has(race) or picked.has(race):
			return out
		picked[race] = true
	for race in known:
		if picked.has(race):
			out.append(race)
	return out


# 从没选过、或选择已经不合法（比如某族被删了）时用这一份：表里前 PICK_COUNT 族。
static func default_races() -> Array[String]:
	var known := all_races()
	var out: Array[String] = []
	for i in mini(PICK_COUNT, known.size()):
		out.append(known[i])
	return out


# 存档 / 座位上记的选择 -> 真正生效的那份。不合法就用默认，永远不会让商店刷空。
static func resolve(value: Variant) -> Array[String]:
	var clean := sanitize(value)
	if clean.is_empty():
		return default_races()
	return clean


# 这一份选择能刷到的棋子。
#
# ⚠️ 必须**先过滤、再交给 ShopRoll.pick_offer**：pick_offer 在「这一档没有棋子」时
# 会退回传进去的整张表。先传全表、摇完再挑，退回那一下就会刷出没选的族。
# 今天每族 1/2/3 阶都有，这条暂时碰不到；以后某个新族缺一阶，它就会漏。
static func shop_pool(units: Array, races: Variant) -> Array:
	var allowed := resolve(races)
	var out: Array = []
	for raw in units:
		if typeof(raw) == TYPE_DICTIONARY and allowed.has(str((raw as Dictionary).get("race", ""))):
			out.append(raw)
	return out
