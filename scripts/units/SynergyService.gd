class_name SynergyService
extends RefCounted

static func count_races_from_board() -> Dictionary:
	var counts := {"god": 0, "dark": 0, "undead": 0, "human": 0}
	for cell in GameState.board_slots:
		if cell == null or bool(cell.get("is_mercenary", false)):
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

