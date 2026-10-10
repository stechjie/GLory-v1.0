extends RefCounted

# 棋子收藏：商城「棋子」页与备战「种族」页共用的那几条规则（2026-10-10 赤律族上商城）。
#
# ## 规则，与服务端 backend/app/shop.py 同一口径
#
#   - 棋子的内容 id = "unit:" + 棋子 id（棋子 id 照抄 data/units/race_units.json，大小写一样）。
#     🔴 必须带前缀：赤卫的棋子 id 就叫 crimson，和种族 id 撞名。
#   - 某一族只要有棋子在商城里卖（目录里有 kind=unit 且棋子属于这一族），这一族就要
#     **种族那一行归属**（内容 id = 种族 id）才能出战。
#   - 种族归属由服务端在集齐最后一个棋子的那一笔里发（老玩家由 database/031 补发）。
#     客户端**只读**这一行，不自己判「八个都有就算解锁」—— 两边各算一遍迟早会分叉，
#     而出战名片只认服务端那一行。
#
# 目录拉不到（断网、旧服务端）时 items 是空的 -> 哪一族都不算「要买」-> 界面不锁；
# 真正挡人的是服务端（存种族回 race_not_owned、名片去掉没资格的族），这里只管显示。
#
# 不用 class_name：理由见 AccountConfig.gd 顶部（服务器打包的全局类缓存）。

const CONTENT_PREFIX := "unit:"


static func content_id(unit_id: String) -> String:
	return CONTENT_PREFIX + unit_id


# 不是棋子的内容 id 返回空串。
static func unit_id_of(content: String) -> String:
	if not content.begins_with(CONTENT_PREFIX):
		return ""
	return content.substr(CONTENT_PREFIX.length())


static func unit_def(unit_id: String) -> Dictionary:
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) == TYPE_DICTIONARY and str((raw as Dictionary).get("id", "")) == unit_id:
			return raw as Dictionary
	return {}


# 某一族的全部棋子：按阶位升序，同阶按棋子表里的顺序。
#
# 不用 sort_custom：Godot 的排序不稳定，同阶的棋子每次打开顺序可能不一样。
static func units_of(race: String) -> Array[Dictionary]:
	var by_tier := {}
	var tiers: Array[int] = []
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var unit := raw as Dictionary
		if str(unit.get("race", "")) != race:
			continue
		var tier := int(unit.get("tier", 1))
		if not by_tier.has(tier):
			by_tier[tier] = []
			tiers.append(tier)
		(by_tier[tier] as Array).append(unit)
	tiers.sort()
	var out: Array[Dictionary] = []
	for tier in tiers:
		for unit in by_tier[tier]:
			out.append(unit as Dictionary)
	return out


# 目录（GET /v1/shop 的 items，或本地 shop.json 的 items）里卖的棋子：{棋子 id: 商品}。
static func sold_units(items: Array) -> Dictionary:
	var out := {}
	for raw in items:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var item := raw as Dictionary
		if str(item.get("kind", "")) != "unit" or not bool(item.get("enabled", true)):
			continue
		var unit_id := unit_id_of(str(item.get("grants", "")))
		if not unit_id.is_empty():
			out[unit_id] = item
	return out


# 有棋子在卖的种族，按棋子表里种族首次出现的顺序（与羁绊栏、备战页一致）。
static func races_on_sale(items: Array) -> Array[String]:
	var sold := sold_units(items)
	var out: Array[String] = []
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var unit := raw as Dictionary
		var race := str(unit.get("race", ""))
		if sold.has(str(unit.get("id", ""))) and not out.has(race):
			out.append(race)
	return out


static func race_requires_purchase(race: String, items: Array) -> bool:
	return races_on_sale(items).has(race)


# owned = {内容 id: true}（GET /v1/me/entitlements 的 items）。
static func is_race_locked(race: String, items: Array, owned: Dictionary) -> bool:
	return race_requires_purchase(race, items) and not owned.has(race)


static func owned_count(race: String, owned: Dictionary) -> int:
	var n := 0
	for unit in units_of(race):
		if owned.has(content_id(str(unit.get("id", "")))):
			n += 1
	return n


static func total_count(race: String) -> int:
	return units_of(race).size()
