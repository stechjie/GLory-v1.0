extends Node

# D2 第六步的验收：scenes/prep/PrepPowerEstimate.gd。
#
# 抽出来之前零覆盖。战力公式写错**不会崩、不会报错**，
# 只会让玩家看到偏的数字并据此做错误的备战决策；
# 而它同时算玩家侧和敌方侧，系数一动两边的相对关系就全变了。
#
# 用例都用手算得出的期望值，不是把当前实现的输出抄下来当基准 ——
# 后者只能证明"没变过"，证明不了"算得对"。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/prep_power_estimate_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Power := preload("res://scenes/prep/PrepPowerEstimate.gd")

const CHECK_NAME := "prep_power_estimate"
const EPS := 0.001

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_skill_dps_variants()
	_case_skill_cd_guard()
	_case_skill_field_priority()
	_case_defense_effective_hp()
	_case_crit_expectation()
	_case_defense_field_alias()
	_case_empty_and_defaults()
	_case_monotonic()
	_h.finish(get_tree())


func _near(got: float, want: float, code: String, msg: String) -> void:
	_h.expect(abs(got - want) < EPS, code, "%s：期望 %.4f，实际 %.4f" % [msg, want, got])


func _case_skill_dps_variants() -> void:
	# 固定伤害：120 / cd 6 = 20
	_near(Power.skill_dps_from_def({"skill_damage": 120, "skill_cd": 6.0}, 0.0),
		20.0, "skill_damage_wrong", "skill_damage 120 / cd 6")
	# 攻击百分比：atk 100 × 2.0 / cd 8 = 25
	_near(Power.skill_dps_from_def({"damage_atk_pct": 2.0, "skill_cd": 8.0}, 100.0),
		25.0, "damage_atk_pct_wrong", "damage_atk_pct 2.0 × atk 100 / cd 8")
	# 历史字段名同样生效
	_near(Power.skill_dps_from_def({"skill_atk_pct": 1.5, "skill_cd": 3.0}, 60.0),
		30.0, "skill_atk_pct_wrong", "skill_atk_pct 1.5 × atk 60 / cd 3")
	# 没有任何技能字段 -> 0
	_near(Power.skill_dps_from_def({"skill_cd": 5.0}, 100.0),
		0.0, "no_skill_field_nonzero", "无技能字段")


# cd <= 0 必须返回 0 而不是除零（除零在 GDScript 里给 inf，会让战力变成 inf）。
func _case_skill_cd_guard() -> void:
	for cd in [0.0, -1.0]:
		var got := Power.skill_dps_from_def({"skill_damage": 100, "skill_cd": float(cd)}, 0.0)
		_h.expect(got == 0.0 and is_finite(got), "cd_guard_broken",
			"cd=%.1f 应返回 0，实际 %s" % [float(cd), str(got)])
	# 缺省冷却 8 秒
	_near(Power.skill_dps_from_def({"skill_damage": 80}, 0.0),
		10.0, "default_cd_wrong", "缺 skill_cd 时应用默认 8 秒")


# 三个技能字段同时存在时的优先级：skill_damage > damage_atk_pct > skill_atk_pct。
# 顺序错了会让配了固定伤害的单位按百分比算，数值差一个量级。
func _case_skill_field_priority() -> void:
	var d := {"skill_damage": 100, "damage_atk_pct": 9.0, "skill_atk_pct": 9.0, "skill_cd": 10.0}
	_near(Power.skill_dps_from_def(d, 1000.0), 10.0, "priority_skill_damage",
		"三者并存时应取 skill_damage")
	var d2 := {"damage_atk_pct": 2.0, "skill_atk_pct": 9.0, "skill_cd": 10.0}
	_near(Power.skill_dps_from_def(d2, 100.0), 20.0, "priority_damage_atk_pct",
		"后两者并存时应取 damage_atk_pct")


# 有效血量 = hp × (1 + def/50)。def 50 -> 翻倍。
func _case_defense_effective_hp() -> void:
	# 纯肉：hp 1000, def 50, 无攻击 -> 1000 × 2 = 2000
	_near(Power.unit_power_from_def({"hp": 1000, "def": 50, "atk": 0, "attack_speed": 0.0}),
		2000.0, "effective_hp_wrong", "hp 1000 def 50 无输出")
	# def 0 -> 不加成
	_near(Power.unit_power_from_def({"hp": 1000, "def": 0, "atk": 0, "attack_speed": 0.0}),
		1000.0, "no_def_bonus_wrong", "hp 1000 def 0 无输出")


# 普攻 DPS = atk × 攻速 × (1 + 暴击率 × (暴伤 - 1))，再 ×10 计入战力。
func _case_crit_expectation() -> void:
	# atk 100, 攻速 1, 无暴击 -> dps 100 -> 战力 1000
	_near(Power.unit_power_from_def({"hp": 0, "def": 0, "atk": 100, "attack_speed": 1.0}),
		1000.0, "basic_dps_wrong", "atk 100 攻速 1 无暴击")
	# 暴击率 0.5、暴伤 2.0 -> ×(1 + 0.5×1.0) = 1.5 -> dps 150 -> 战力 1500
	_near(Power.unit_power_from_def({"hp": 0, "def": 0, "atk": 100, "attack_speed": 1.0,
		"crit": 0.5, "crit_dmg": 2.0}), 1500.0, "crit_expectation_wrong",
		"暴击率 0.5 暴伤 2.0")
	# 暴伤 < 1 不能变成负加成（maxf 兜底）
	_near(Power.unit_power_from_def({"hp": 0, "def": 0, "atk": 100, "attack_speed": 1.0,
		"crit": 1.0, "crit_dmg": 0.5}), 1000.0, "crit_dmg_below_one",
		"暴伤 0.5 应被 maxf 夹到不减益")


# 防御字段有两个名字：def 与 defense。数据表两种都出现过。
func _case_defense_field_alias() -> void:
	var a := Power.unit_power_from_def({"hp": 100, "def": 50, "atk": 0, "attack_speed": 0.0})
	var b := Power.unit_power_from_def({"hp": 100, "defense": 50, "atk": 0, "attack_speed": 0.0})
	_h.expect(abs(a - b) < EPS, "defense_alias_broken",
		"def 与 defense 应等价，实际 %.4f vs %.4f" % [a, b])


func _case_empty_and_defaults() -> void:
	var empty := Power.unit_power_from_def({})
	_h.expect(empty == 0.0 and is_finite(empty), "empty_def_nonzero",
		"空定义应为 0 战力，实际 %s" % str(empty))
	# 缺 attack_speed 时默认 1.0：atk 10 -> dps 10 -> 战力 100
	_near(Power.unit_power_from_def({"hp": 0, "atk": 10}), 100.0,
		"default_attack_speed", "缺 attack_speed 应默认 1.0")


# 单调性：任何一项属性变强，战力都不能变小。
# 这条守的是"改公式时某一项被写成了负相关"这种低级但致命的错误。
func _case_monotonic() -> void:
	var base := {"hp": 500, "def": 10, "atk": 50, "attack_speed": 1.0, "crit": 0.1, "crit_dmg": 1.5}
	var base_power := Power.unit_power_from_def(base)
	for key in ["hp", "def", "atk", "attack_speed", "crit"]:
		var stronger := base.duplicate(true)
		stronger[key] = float(stronger[key]) * 2.0 + 1.0
		var p := Power.unit_power_from_def(stronger)
		_h.expect(p > base_power, "not_monotonic",
			"%s 变强后战力反而没涨：%.2f -> %.2f" % [str(key), base_power, p])
