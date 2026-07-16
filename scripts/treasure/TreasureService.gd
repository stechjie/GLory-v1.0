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
	GameState.owned_treasures.append(tid)

static func _shuffle_strings(items: Array[String]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(items.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := items[i]
		items[i] = items[j]
		items[j] = tmp




