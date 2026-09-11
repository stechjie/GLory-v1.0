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
	# 4 星的技能数值覆写。数据表里每个单位可以带一个可选的 `star4` 子对象，
	# 里面的键在这里**整块覆盖**到 def 上（见 docs/四星技能与数值设计规格.md §3）。
	#
	# 这是全项目唯一的解析点：apply_star_stats() 是产出「按星级缩放后的 def」的
	# 唯一函数（调用方只有 BattleSimShared 与 BattleStatsPanel），战斗代码一律读
	# d.get(...)，所以覆写完就自动生效，不需要在技能实现里到处判星级。
	#
	# 无论几星都 erase：留着的话 1~3 星的 def 上会挂一份四星数值，任何一处
	# 直接读 def 的地方（比如详情文案）都可能拿错那一份 —— 那就是第二份数值真相。
	if out.star >= GameConstants.MAX_STAR and typeof(out.get("star4", null)) == TYPE_DICTIONARY:
		for key in (out["star4"] as Dictionary):
			out[key] = (out["star4"] as Dictionary)[key]
	# 死侍各星级基础攻击固定为 1，包括旧存档和四星覆写。
	if str(out.get("id", "")) == "human_death_servant":
		out.atk = 1
	out.erase("star4")
	return out
