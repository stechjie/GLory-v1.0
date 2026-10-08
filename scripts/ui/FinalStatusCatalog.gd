class_name FinalStatusCatalog
extends RefCounted

# Presentation catalog exported from docs/balance/final status.xlsx.
# Gameplay values continue to come from their existing runtime data and the server.
static func _section(name: String) -> Dictionary:
	var table: Dictionary = DataRegistry.get_table("final_status")
	return table.get(name, {})

static func unit_skill_cn(unit_id: String, star: int) -> String:
	var row: Dictionary = _section("units").get(unit_id, {})
	if row.is_empty():
		return ""
	return str(row.get("skill_cn_4" if star >= 4 else "skill_cn_1to3", ""))

static func pet_summary_cn(pet_id: String) -> String:
	return str(_section("pets").get(pet_id, {}).get("summary_cn", ""))

static func pet_detail_cn(pet_id: String) -> String:
	return str(_section("pets").get(pet_id, {}).get("detail_cn", ""))

static func synergy_cn(race: String, threshold: int) -> Dictionary:
	for row in _section("synergies").get(race, []):
		if int(row.get("threshold", 0)) == threshold:
			var display: Dictionary = row.duplicate()
			display["detail_cn"] = _display_text(row.get("detail_cn", ""))
			return display
	return {}

static func treasure_effect_cn(treasure_id: String) -> String:
	return str(_section("treasures").get(treasure_id, {}).get("effect_cn", ""))

static func linkage_effect_cn(linkage_id: String) -> String:
	return _display_text(_section("linkages").get(linkage_id, {}).get("effect_cn", ""))

static func _display_text(value: Variant) -> String:
	var result := str(value)
	var debug_start := result.find("\n表内字段")
	if debug_start >= 0:
		result = result.substr(0, debug_start)
	return result.replace("代码里没有上限", "无层数上限").replace("（计入 bonus_gold）", "")
