class_name SynergyService
extends RefCounted

static func count_races_from_board() -> Dictionary:
	var counts := {"god": 0, "dark": 0, "undead": 0, "human": 0}
	for cell in GameState.board_slots:
		if cell == null:
			continue
		var race := str(cell.def.get("race", ""))
		if counts.has(race):
			counts[race] += 1
	return counts

static func flags_from_counts(counts: Dictionary) -> Dictionary:
	var god := int(counts.get("god", 0))
	var dark := int(counts.get("dark", 0))
	var undead := int(counts.get("undead", 0))
	var human := int(counts.get("human", 0))
	return {
		"counts": counts,
		"god_death_cleanse": god > 0,
		"god_lifesteal": 0.20 if god >= 3 else 0.0,
		"god_invulnerable_opening": god >= 7,
		"dark_death_stack_enabled": dark > 0,
		"dark_damage_bonus": 0.25 if dark >= 5 else 0.0,
		"dark_debuff_strength": 0.25 if dark >= 2 else 0.0,
		"dark_debuff_duration": 0.50 if dark >= 7 else 0.0,
		"undead_poison_bonus": 1.0 if undead >= 4 else 0.0,
		"undead_threshold_mul": 0.75 if undead >= 7 else 1.0,
		"undead_death_clone_threshold": int(ceil(30.0 * (0.75 if undead >= 7 else 1.0))) if undead > 0 else 0,
		"human_shield": human >= 2,
		"human_last_stand": human >= 7,
	}

static func current_player_flags() -> Dictionary:
	return flags_from_counts(count_races_from_board())

# 战斗代码读羁绊系数的唯一入口。inf/NaN 乘进伤害会污染整场状态（hp 被 int() 截断成
# 垃圾值），而 clamp 挡不住 NaN——任何比较都返回 false。所以先判 is_finite。
# 正常值域见 flags_from_counts：最大的也只是 1.0 量级。
# fallback 是「字段缺失或不可用」时的中性值：加成类是 0.0，乘数类是 1.0。
static func safe_factor(syn: Dictionary, key: String, max_value: float = 8.0, fallback: float = 0.0) -> float:
	var raw := float(syn.get(key, fallback))
	if not is_finite(raw):
		return fallback
	return clampf(raw, 0.0, max_value)

