extends Node

# 11.01 叠加规则统一（参考 Dota 2：同类相加、不同类相乘）的行为门禁。
# 每一条期望值都按规则手算，不读实现抄数：
#   ① 同名状态取最强、各实例各自计时；slow 按字段分别取最大
#   ② 控制减免只缩短负面效果
#   ③ 攻速 / 攻击百分比相加，攻速总和夹在 [-60%, +150%]，攻击最低 10%
#   ④ 受到伤害修正相加，最多减到 30%
#   ⑤ 闪避按 1-(1-a)(1-b) 叠加，上限 50%
#   ⑥ 祝福按开战攻击相加、同一目标最多 3 层；人 7 / 暗 7 攻速进百分比池
#   ⑦ 开场百分比加成同类相加，固定值（铁壁）不被冲掉；分身剥金钱套用的除数正确
#   ⑧ 回放帧不带实例表

const Harness := preload("res://tools/CheckHarness.gd")
var h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _f() -> Dictionary:
	return {"uid": "probe", "def": {}, "statuses": {}, "alive": true, "attack_speed": 1.0}


func _run() -> void:
	h = Harness.new("stacking_rules")
	_check_merge()
	_check_control_reduction()
	_check_attack_speed_and_attack()
	_check_incoming_and_dodge()
	_check_permanent_buffs()
	_check_opening_pool()
	_check_replay_strip()
	h.finish(get_tree())


func _check_merge() -> void:
	var f := _f()
	StatusEffectService.add_status(f, "speed_bonus", 2.0, {"pct": 0.60})
	StatusEffectService.add_status(f, "speed_bonus", 5.0, {"pct": 0.25})
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(f), 1.60), "merge_strongest",
		"60% 加速不应被后来的 25% 覆盖（实为 %.3f）" % StatusEffectService.attack_speed_multiplier(f))
	StatusEffectService.tick(f, 2.5)
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(f), 1.25), "merge_weaker_survives",
		"强的过期后，较弱但更长的 25% 应继续生效（实为 %.3f）" % StatusEffectService.attack_speed_multiplier(f))
	StatusEffectService.tick(f, 3.0)
	h.expect(not f.statuses.has("speed_bonus"), "merge_all_expire", "两个实例都过期后状态应移除")

	var s := _f()
	StatusEffectService.add_status(s, "slow", 2.0, {"move_pct": 0.35, "attack_speed_pct": 0.35})
	StatusEffectService.add_status(s, "slow", 4.0, {"move_pct": 0.0, "attack_speed_pct": 0.08})
	h.expect(is_equal_approx(StatusEffectService.move_speed_multiplier(s), 0.65)
		and is_equal_approx(StatusEffectService.attack_speed_multiplier(s), 0.65), "slow_fields_kept",
		"诅咒的「只减攻速」不应抹掉冰冻的移速减速")
	StatusEffectService.tick(s, 2.5)
	h.expect(is_equal_approx(StatusEffectService.move_speed_multiplier(s), 1.0)
		and is_equal_approx(StatusEffectService.attack_speed_multiplier(s), 0.92), "slow_fields_expire",
		"冰冻过期后只剩诅咒的 8% 攻速减速")

	var r := _f()
	StatusEffectService.add_status(r, "damage_reduction", 3.0, {"pct": 0.20})
	StatusEffectService.add_status(r, "damage_reduction", 6.0, {"pct": 0.20})
	h.expect(not r.statuses.damage_reduction.has("instances")
		and is_equal_approx(float(r.statuses.damage_reduction.remaining), 6.0), "same_values_refresh",
		"数值相同的再次施加只刷新时长，不新增实例")

	var many := _f()
	for i in 6:
		StatusEffectService.add_status(many, "attack_down", 1.0 + float(i), {"pct": 0.05 * float(i + 1)})
	h.expect((many.statuses.attack_down.get("instances", []) as Array).size() == StatusEffectService.MAX_STATUS_INSTANCES,
		"instance_cap", "实例数应封顶 %d" % StatusEffectService.MAX_STATUS_INSTANCES)


func _check_control_reduction() -> void:
	var f := _f()
	f.statuses["control_time_reduction"] = {"remaining": 8.0, "pct": 0.30}
	StatusEffectService.add_status(f, "speed_bonus", 5.0, {"pct": 0.20})
	StatusEffectService.add_status(f, "invulnerable", 1.0, {"dot_pass": true})
	StatusEffectService.add_status(f, "stun", 2.0, {})
	h.expect(is_equal_approx(float(f.statuses.speed_bonus.remaining), 5.0)
		and is_equal_approx(float(f.statuses.invulnerable.remaining), 1.0), "ctr_positive_untouched",
		"控制减免不应缩短加速 / 无敌")
	h.expect(is_equal_approx(float(f.statuses.stun.remaining), 1.4), "ctr_negative_reduced",
		"控制减免 30% 应把 2 秒眩晕缩到 1.4 秒（实为 %.3f）" % float(f.statuses.stun.remaining))


func _check_attack_speed_and_attack() -> void:
	var f := _f()
	StatusEffectService.add_status(f, "speed_bonus", 5.0, {"pct": 0.30})
	StatusEffectService.add_status(f, "attack_set_speed_bonus", 5.0, {"pct": 0.08})
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(f), 1.38), "aspd_additive",
		"+30% 与 +8% 攻速应相加为 +38%（实为 %.4f）" % StatusEffectService.attack_speed_multiplier(f))
	var capped := _f()
	capped.aspd_bonus_pct = 3.0
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(capped), 2.5), "aspd_cap_high", "攻速总加成应封顶 +150%")
	var slowed := _f()
	StatusEffectService.add_status(slowed, "slow", 5.0, {"attack_speed_pct": 0.90, "move_pct": 0.0})
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(slowed), 0.4), "aspd_cap_low", "攻速总减速应封底 -60%")
	var dyn := _f()
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(dyn, 0.30), 1.30), "aspd_extra", "动态加成（血怒）应进同一个加法池")

	var a := _f()
	StatusEffectService.add_status(a, "crimson_attack", 5.0, {"pct": 0.20})
	a.crimson_resonance_stacks = 2
	h.expect(is_equal_approx(StatusEffectService.attack_multiplier(a), 1.30), "atk_additive", "攻击 +20% 与共鸣 2 层 +10% 应相加为 +30%")
	var weak := _f()
	StatusEffectService.add_status(weak, "attack_down", 5.0, {"pct": 0.95})
	h.expect(is_equal_approx(StatusEffectService.attack_multiplier(weak), 0.10), "atk_floor", "攻击最低保留 10%")


func _check_incoming_and_dodge() -> void:
	var f := _f()
	StatusEffectService.add_status(f, "damage_reduction", 5.0, {"pct": 0.50})
	StatusEffectService.add_status(f, "ice_vulnerable", 5.0, {"pct": 0.25})
	h.expect(is_equal_approx(DamageService.status_damage_taken_multiplier(f), 0.75), "incoming_additive",
		"减伤 50% 与易伤 25% 应相加为受到 75%")
	var g := _f()
	g.statuses["damage_reduction"] = {"remaining": 5.0, "pct": 0.90}
	h.expect(is_equal_approx(DamageService.status_damage_taken_multiplier(g), DamageService.INCOMING_DAMAGE_MIN_MUL),
		"incoming_floor", "受到伤害最多减到 30%")

	var d := _f()
	d.dodge = DamageService.stack_dodge(0.25, 0.20)
	h.expect(is_equal_approx(DamageService.dodge_chance(d), 0.40), "dodge_multiplicative", "25% 与 20% 闪避应叠成 40%")
	StatusEffectService.add_status(d, "dodge_bonus", 2.0, {"pct": 0.50})
	h.expect(is_equal_approx(DamageService.dodge_chance(d), DamageService.DODGE_CAP), "dodge_cap", "闪避上限 50%")


func _check_permanent_buffs() -> void:
	var t := _f()
	t.atk = 100
	t.defense = 20
	t.max_hp = 1000
	t.hp = 1000
	for i in 5:
		BattleSimSkills._apply_bless_stack(t, "nearest_ally_bless", 0.10, 0.15)
	h.expect(int(t.atk) == 130 and is_equal_approx(float(t.aspd_bonus_pct), 0.45) and is_equal_approx(float(t.attack_speed), 1.0),
		"bless_cap", "祝福 5 次应只生效 3 层：攻击 100+3×10、攻速池 +45%%，面板攻速不变（实为 atk=%d pool=%.2f）" % [int(t.atk), float(t.get("aspd_bonus_pct", 0.0))])
	BattleSimSkills._apply_bless_stack(t, "nearby_ally_heal_buff", 0.10, 0.15)
	h.expect(int(t.atk) == 140, "bless_per_skill", "不同技能各自计层")

	var r := _f()
	r.atk = 100
	r.defense = 10
	r.max_hp = 1000
	BattleSimShared._ensure_base_stats(r)
	BattleSimShared._add_base_pct_stats(r, 0.20)
	BattleSimShared._add_base_pct_stats(r, 0.20)
	h.expect(int(r.atk) == 140 and int(r.defense) == 14 and is_equal_approx(float(r.attack_speed), 1.0)
		and is_equal_approx(float(r.aspd_bonus_pct), 0.40), "rally_base_pct",
		"人 7 两档：攻击 / 防御按开战值各 +40%，攻速进百分比池 +40%")


func _check_opening_pool() -> void:
	var d := {"id": "probe", "name": "probe", "hp": 1000, "atk": 100, "def": 20, "attack_speed": 1.0, "range": 1, "move_speed": 1.0}
	var f: Dictionary = BattleSimShared._fighter_from_def(d, 0, "player", 0, 1)
	BattleSimShared._apply_defense_set_bonus(f)
	h.expect(int(f.max_hp) == 1300 and int(f.hp) == 1300 and int(f.defense) == 26
		and is_equal_approx(float(f.dodge), 0.15), "open_defense_set", "防御套：生命 / 防御 +30%、闪避 15%")
	f.defense = int(f.defense) + 10
	BattleSimShared._add_open_pct(f, "atk", 0.25)
	f["open_money_pct"] = 1.0
	BattleSimShared._add_open_pct(f, "max_hp", 1.0)
	BattleSimShared._add_open_pct(f, "atk", 1.0)
	h.expect(int(f.atk) == 225 and int(f.max_hp) == 2300 and int(f.defense) == 36, "open_additive",
		"血契 25% + 金钱 100% 应相加为攻击 ×2.25、生命 ×2.3，铁壁 +10 保留（实为 atk=%d hp=%d def=%d）" % [int(f.atk), int(f.max_hp), int(f.defense)])
	h.expect(is_equal_approx(float(f.money_set_multiplier), 2.25 / 1.25)
		and is_equal_approx(float(f.money_set_hp_multiplier), 2.3 / 1.3), "open_money_divisor",
		"分身剥金钱套的除数 = 含金钱倍率 ÷ 不含金钱倍率")


func _check_replay_strip() -> void:
	var f := _f()
	StatusEffectService.add_status(f, "speed_bonus", 2.0, {"pct": 0.60})
	StatusEffectService.add_status(f, "speed_bonus", 5.0, {"pct": 0.25})
	var out := BattleSimulator._replay_statuses(f)
	h.expect(out.has("speed_bonus") and not (out.speed_bonus as Dictionary).has("instances")
		and is_equal_approx(float(out.speed_bonus.pct), 0.60), "replay_strip",
		"回放只带合并后的生效值，不带实例表")
	h.expect(f.statuses.speed_bonus.has("instances"), "replay_strip_no_mutation", "回放剥离不能改到模拟里的状态")
