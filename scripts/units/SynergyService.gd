class_name SynergyService
extends RefCounted

# 羁绊档位阈值。**必须与 SynergyPanel._race_entries() 显示的那几档一致** ——
# 那边是给玩家看的文案表（带 name / detail），这边是判「刚跨过哪一档」用的
# 纯数字表。两份漂移的症状是「面板写着 7 档、音效在 5 档就响」。
# tools/audio_sfx_check 会拿这两个函数对一遍，对不上直接红。
#
# 取值的来源是 flags_from_counts() 下面那一堆比较：god 1/3/7、dark 1/2/5/7、
# undead 1/4/7、human 1/2/7。
const RACE_THRESHOLDS := {
	"god": [1, 3, 7],
	"dark": [1, 2, 5, 7],
	"undead": [1, 4, 7],
	"human": [1, 2, 7],
}

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
		# 神7（9.24 改）：开场 1 秒后起每 5 秒全队无敌 1 秒（只免普攻与技能，DoT 照吃）。
		# 旧的「开场无敌 1.5 秒」(god_invulnerable_opening) 已删除。
		"god_divine_pulse": god >= 7,
		"dark_death_stack_enabled": dark > 0,
		"dark_damage_bonus": 0.25 if dark >= 5 else 0.0,
		"dark_debuff_strength": 0.25 if dark >= 2 else 0.0,
		# 暗7（9.24 改）：普攻带负面的目标 → 目标攻/防/攻速 -3%、自己 +2%，各最多 15 层。
		# 旧的「负面时长 +50%」(dark_debuff_duration) 已删除，_dark_duration 读不到即为 0。
		"dark_sap": dark >= 7,
		"undead_poison_bonus": 1.0 if undead >= 4 else 0.0,
		# 灵7（9.24 改）：灵族普攻已中毒的目标 → 回复自身最大生命 15%。
		# 旧的「克隆/母灵阈值 ×0.75」已删除，undead_threshold_mul 恒为 1.0。
		"undead_poison_heal": 0.15 if undead >= 7 else 0.0,
		"undead_threshold_mul": 1.0,
		"undead_death_clone_threshold": 30 if undead > 0 else 0,
		"human_shield": human >= 2,
		# 人7（9.24 改）：己方棋盘每死 1 个，活着的全部 +1 档（每档 +20%，见 BattleSimTreasures._owner_human_rally）。
		# 旧的「只剩最后 1 个时属性翻倍」已删除。
		"human_death_rally": human >= 7,
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

