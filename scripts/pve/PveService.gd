class_name PveService
extends RefCounted

# 11.18：成长倍数改为读 data/pve/pve_monsters.json 的 growth_per_completed_pve
# （以前这里写死 1.10 / 1.08 / 1.05，表里那一行没人读）。表里缺项时用这份缺省值。
const DEFAULT_GROWTH := {"hp": 1.09, "atk": 1.06, "def": 1.04, "skill_damage": 1.08}


static func growth_for_completed(completed: int) -> Dictionary:
	var table_value: Variant = DataRegistry.get_table("pve_monsters").get("growth_per_completed_pve", {})
	var table: Dictionary = table_value if typeof(table_value) == TYPE_DICTIONARY else {}
	var out := {}
	for key: String in DEFAULT_GROWTH:
		var per_round := float(table.get(key, DEFAULT_GROWTH[key]))
		if per_round <= 0.0:
			per_round = float(DEFAULT_GROWTH[key])
		out[key] = pow(per_round, completed)
	return out
