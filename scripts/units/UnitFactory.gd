class_name UnitFactory
extends RefCounted

static func apply_star_stats(unit_def: Dictionary, star: int) -> Dictionary:
	var out := unit_def.duplicate(true)
	# 系数按单位取：4 星允许用数据表字段 star4_multiplier 覆写默认的 ×1.15。
	var mul := GameState.star_stat_multiplier(star, out)
	out.hp = maxi(1, int(round(float(out.get("hp", 1)) * mul)))
	out.atk = maxi(1, int(round(float(out.get("atk", 1)) * mul)))
	out.def = maxi(0, int(round(float(out.get("def", out.get("defense", 0))) * mul)))
	# 上限读常量。这里以前硬写 3，是加四星时最容易漏掉的一处 ——
	# 漏了不会报错，只会让四星棋子被静默降级成三星属性。
	out.star = clampi(star, 1, GameConstants.MAX_STAR)
	return out
