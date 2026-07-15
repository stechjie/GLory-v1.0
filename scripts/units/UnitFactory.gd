class_name UnitFactory
extends RefCounted

static func apply_star_stats(unit_def: Dictionary, star: int) -> Dictionary:
	var out := unit_def.duplicate(true)
	var mul := GameState.star_stat_multiplier(star)
	out.hp = maxi(1, int(round(float(out.get("hp", 1)) * mul)))
	out.atk = maxi(1, int(round(float(out.get("atk", 1)) * mul)))
	out.def = maxi(0, int(round(float(out.get("def", out.get("defense", 0))) * mul)))
	out.star = clampi(star, 1, 3)
	return out
