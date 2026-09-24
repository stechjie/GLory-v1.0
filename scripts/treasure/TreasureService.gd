class_name TreasureService
extends RefCounted

const MAX_OWNED := 5
const REFRESH_COSTS := [50, 100, 200, 400]

static func refresh_cost(index: int, money_set_active: bool) -> int:
	if money_set_active:
		return 0
	var i := maxi(index, 0)
	# 50, 100, 200, 400, then keep doubling with no cap: 800, 1600, ...
	if i < REFRESH_COSTS.size():
		return int(REFRESH_COSTS[i])
	var cost := int(REFRESH_COSTS[REFRESH_COSTS.size() - 1])
	for _step in range(i - (REFRESH_COSTS.size() - 1)):
		cost *= 2
	return cost

static func can_draw() -> bool:
	return GameState.owned_treasures.size() < MAX_OWNED

# 保留有效候选顺序，用未拥有的宝藏补足；用于本地教学及旧存档修复。
static func available_candidates(preferred: Array, count: int = 3) -> Array:
	var result: Array = []
	if not can_draw():
		return result
	for value in preferred + unowned_ids():
		var tid := str(value)
		if result.size() >= count:
			break
		if tid in GameState.owned_treasures or tid in result or treasure_by_id(tid).is_empty():
			continue
		result.append(tid)
	return result

static func claim_local_choice(tid: String) -> bool:
	if not bool(GameState.pending_treasure.get("active", false)):
		return false
	if tid not in GameState.pending_treasure.get("candidates", []) or tid in GameState.owned_treasures or treasure_by_id(tid).is_empty() or not can_draw():
		return false
	add_owned(tid)
	return tid in GameState.owned_treasures

# 用服务端权威持有列表覆盖本地（联机 resume / grant 用，每次 _on_treasure_granted
# 都会调，不止重连）。
# 不能直接 `GameState.owned_treasures = server_owned`：那会绕过 add_owned 里的
# PlayerProfile.mark_seen 与联动解锁，玩家重连一次就少解锁一批图鉴条目。
# 这里先按服务端列表裁掉本地多出来的项（服务端说没有就是没有——本地多出来的
# 只可能来自过期存档或未走 intent 的路径），腾出名额之后再逐个走 add_owned
# 补齐、拿到副作用。
static func sync_owned_from_server(server_owned: Array) -> void:
	var authoritative: Array = []
	for value in server_owned:
		var tid := str(value)
		if not tid.is_empty() and not authoritative.has(tid):
			authoritative.append(tid)
	# 🔴 必须先裁、后补，不能反过来。add_owned() 卡着 MAX_OWNED=5：
	# 如果先补，本地一条服务端已经不认的过期条目还占着名额，新条目会被
	# add_owned 的容量检查静默挡回去、永远补不回来——而这条过期条目随后
	# 才在裁剪步骤里被删掉，玩家净亏一件，且不报错（只有 size 对不上时
	# _on_treasure_granted 那条 push_warning 会响，但看不出真正原因）。
	# 就地改数组而不是整体替换，避免别处持有的引用失效。
	for i in range(GameState.owned_treasures.size() - 1, -1, -1):
		if str(GameState.owned_treasures[i]) not in authoritative:
			GameState.owned_treasures.remove_at(i)
	for tid in authoritative:
		if tid not in GameState.owned_treasures:
			add_owned(tid)

static func tag_counts() -> Dictionary:
	var counts := {"defense": 0, "control": 0, "attack": 0, "money": 0, "element": 0}
	var treasures: Array = DataRegistry.get_table("treasures").get("treasures", [])
	for tid in GameState.owned_treasures:
		for t in treasures:
			if str(t.get("id", "")) == tid:
				var cat := str(t.get("category", ""))
				if counts.has(cat):
					counts[cat] += 1
				break
	return counts

static func has_set(category: String) -> bool:
	return int(tag_counts().get(category, 0)) >= 4

# 五个 4 件套装。图鉴条目 id 是 set_<类别>，与宝藏 / 联动 id 不会撞。
const SET_CATEGORIES := ["defense", "control", "attack", "money", "element"]

static func set_id(category: String) -> String:
	return "set_" + category

static func active_set_ids() -> Array[String]:
	var out: Array[String] = []
	for category in SET_CATEGORIES:
		if has_set(category):
			out.append(set_id(category))
	return out

# set_<类别> → 类别；不是套装 id 时返回空串。
static func set_category_of(bonus_id: String) -> String:
	if not bonus_id.begins_with("set_"):
		return ""
	var category := bonus_id.trim_prefix("set_")
	return category if category in SET_CATEGORIES else ""

# 促成这条联动 / 这个套装的那几件宝藏（联动特效的光线从它们射出）。
# 联动取 requires；套装取 owned 里该类别的全部。
static func bonus_sources(bonus_id: String, owned: Array) -> Array[String]:
	var out: Array[String] = []
	var category := set_category_of(bonus_id)
	if not category.is_empty():
		for tid in owned:
			if str(treasure_by_id(str(tid)).get("category", "")) == category:
				out.append(str(tid))
		return out
	for raw in DataRegistry.get_table("treasures").get("linkages", []):
		var d := raw as Dictionary
		if d != null and str(d.get("id", "")) == bonus_id:
			for r in d.get("requires", []):
				out.append(str(r))
	return out

static func has_linkage(link_id: String) -> bool:
	return has_linkage_in(GameState.owned_treasures, link_id)

# Owner-aware versions (3v3: each unit uses ITS owner's treasures, not GameState).
static func tag_counts_for(owned: Array) -> Dictionary:
	var counts := {"defense": 0, "control": 0, "attack": 0, "money": 0, "element": 0}
	var treasures: Array = DataRegistry.get_table("treasures").get("treasures", [])
	for tid in owned:
		for t in treasures:
			if str(t.get("id", "")) == str(tid):
				var cat := str(t.get("category", ""))
				if counts.has(cat):
					counts[cat] += 1
				break
	return counts

static func has_set_in(owned: Array, category: String) -> bool:
	return int(tag_counts_for(owned).get(category, 0)) >= 4

static func has_linkage_in(owned: Array, link_id: String) -> bool:
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	for link in links:
		var d: Dictionary = link
		if str(d.get("id", "")) != link_id:
			continue
		for required_id in d.get("requires", []):
			if not owned.has(str(required_id)):
				return false
		return true
	return false

static func unowned_ids() -> Array[String]:
	var out: Array[String] = []
	var treasures: Array = DataRegistry.get_table("treasures").get("treasures", [])
	for t in treasures:
		var tid := str(t.get("id", ""))
		if not tid.is_empty() and tid not in GameState.owned_treasures:
			out.append(tid)
	return out

static func roll_candidates(count: int = 3) -> Array[String]:
	var pool := unowned_ids()
	_shuffle_strings(pool)
	return pool.slice(0, mini(count, pool.size()))

static func random_unowned() -> String:
	var pool := unowned_ids()
	if pool.is_empty():
		return ""
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return pool[rng.randi_range(0, pool.size() - 1)]

static func treasure_by_id(tid: String) -> Dictionary:
	var treasures: Array = DataRegistry.get_table("treasures").get("treasures", [])
	for t in treasures:
		if str(t.get("id", "")) == tid:
			return t
	return {}

static func add_owned(tid: String) -> void:
	if tid.is_empty() or tid in GameState.owned_treasures or GameState.owned_treasures.size() >= MAX_OWNED:
		return
	# 联动激活的音效与特效不在这里：这个函数也被断线重连的补同步调用，
	# 在这里放会在重连时乱响。备战界面在领宝前后各取一次 active_*_ids()，
	# 差集才是「这一次领宝引起的激活」（PrepUI._queue_bonus_fx）。
	GameState.owned_treasures.append(tid)
	PlayerProfile.mark_seen(tid)
	# A linkage has no pickup of its own: it activates the moment its two treasures
	# are both owned, so that is when it enters the codex. A set likewise enters
	# the codex the first time a fourth treasure of its category is owned.
	_mark_active_linkages()
	var sets_now := active_set_ids()
	if not sets_now.is_empty():
		PlayerProfile.mark_seen_many(sets_now)


# 当前已满足条件的联动 id。顺序跟数据表一致，所以「哪一条先激活」是可预期的。
#
# _mark_active_linkages() 用它算该写进图鉴的集合；备战界面用它做领宝前后的差集。
static func active_linkage_ids() -> Array[String]:
	var out: Array[String] = []
	for raw in DataRegistry.get_table("treasures").get("linkages", []):
		var d := raw as Dictionary
		if d == null:
			continue
		var link_id := str(d.get("id", ""))
		if not link_id.is_empty() and has_linkage(link_id):
			out.append(link_id)
	return out


static func _mark_active_linkages() -> void:
	var unlocked := active_linkage_ids()
	if not unlocked.is_empty():
		PlayerProfile.mark_seen_many(unlocked)

static func _shuffle_strings(items: Array[String]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(items.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := items[i]
		items[i] = items[j]
		items[j] = tmp




