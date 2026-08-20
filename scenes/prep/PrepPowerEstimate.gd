extends RefCounted

# D2 第六步：把「战力估算公式」抽成纯工具。
#
# 备战界面三处都用它：玩家当前战力、下一波小怪估算、下一个 Boss 估算。
# 公式本身只读传入的单位定义字典，不碰任何成员变量 —— 属于那 86 个
# 「完全不碰成员变量且被多处调用」的函数之一（见 docs/CHECKS.md 4.8）。
#
# 抽出来的理由和 PrepPowerFormat 一样：**纯数值、零覆盖、写错了不会崩**。
# 战力估算偏了只会让玩家做出错误的备战决策，没有任何报错，
# 而它同时被玩家侧和敌方侧使用 —— 公式一改，两边的相对关系就变了。
#
# 全静态、不持状态。

# 技能 DPS。三种配法按优先级取第一个命中的：
#   skill_damage    固定伤害
#   damage_atk_pct  攻击力百分比
#   skill_atk_pct   同上（历史遗留的另一个字段名）
# 冷却 <= 0 视为不会释放，返回 0（而不是除零）。
static func skill_dps_from_def(d: Dictionary, atk: float) -> float:
	var cd := float(d.get("skill_cd", d.get("default_skill_cd", 8.0)))
	if cd <= 0.0:
		return 0.0
	if d.has("skill_damage"):
		return float(d.get("skill_damage", 0)) / cd
	if d.has("damage_atk_pct"):
		return atk * float(d.get("damage_atk_pct", 0.0)) / cd
	if d.has("skill_atk_pct"):
		return atk * float(d.get("skill_atk_pct", 0.0)) / cd
	return 0.0


# 单位战力 = 有效血量 + （普攻 DPS + 技能 DPS）× 10
#
# 有效血量把防御折算进去：def 每 50 点等于血量翻一倍。
# 普攻 DPS 计入攻速与暴击期望。
# 末尾的 ×10 是把「每秒伤害」换算成与血量同量纲的权重 ——
# 相当于假定一场交战持续 10 秒。这个系数决定了「坦度」与「输出」的相对价值，
# 改它会整体改变所有单位的战力排序。
static func unit_power_from_def(d: Dictionary) -> float:
	var hp := float(d.get("hp", 0))
	var atk := float(d.get("atk", 0))
	var defense := float(d.get("def", d.get("defense", 0)))
	var attack_speed := float(d.get("attack_speed", 1.0))
	var crit := float(d.get("crit", 0.0))
	var crit_dmg := float(d.get("crit_dmg", 1.5))
	var effective_hp := hp * (1.0 + defense / 50.0)
	var basic_dps := atk * attack_speed * (1.0 + crit * maxf(0.0, crit_dmg - 1.0))
	var skill_dps := skill_dps_from_def(d, atk)
	return effective_hp + (basic_dps + skill_dps) * 10.0
