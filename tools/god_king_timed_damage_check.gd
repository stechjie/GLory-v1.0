extends Node

# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/god_king_timed_damage_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new("god_king_timed_damage")
	_case_damage_is_five_pulses_over_two_seconds()
	_case_dodge_is_rolled_once()
	_case_later_invulnerability_blocks_only_due_pulse()
	_case_star4_uses_sixteen_percent()
	_h.finish(get_tree())


func _fighter(uid: String, team: String, hp: int, atk: int = 100) -> Dictionary:
	return {
		"uid": uid,
		"id": uid,
		"team": team,
		"lane": 1,
		"pos": Vector2.ZERO,
		"hp": hp,
		"max_hp": hp,
		"atk": atk,
		"defense": 0,
		"alive": true,
		"shield": 0,
		"dodge": 0.0,
		"statuses": {},
		"def": {},
	}


func _state(caster: Dictionary, target: Dictionary) -> Dictionary:
	return {
		"player": [caster],
		"enemy": [target],
		"elapsed": 1.0,
		"visual_events": [],
		"pending_skill_damage": [],
		"unit_stats": {
			str(caster.uid): {},
			str(target.uid): {},
		},
	}


func _def() -> Dictionary:
	return {
		"skill_id": "global_divine_blast",
		"race": "god",
		"damage_atk_pct": 1.6,
		"max_hp_bonus_pct": 0.08,
		"damage_tick_count": 5,
		"damage_tick_interval": 0.5,
	}


func _cast(caster: Dictionary, target: Dictionary, state: Dictionary, d: Dictionary) -> void:
	RngService.rng.seed = 20260927
	DamageService.begin_stat_context(state, caster)
	DamageService.set_hit_context("skill", false, "god", "global_divine_blast")
	BattleSimSkills._skill_god_king(caster, [target], d, state)
	DamageService.clear_stat_context()


func _advance(state: Dictionary, ticks: int) -> void:
	for _i in ticks:
		BattleSimSkills.tick_pending_skill_damage(state)


func _case_damage_is_five_pulses_over_two_seconds() -> void:
	var caster := _fighter("god_king", "player", 5000, 100)
	var target := _fighter("target", "enemy", 10000)
	var state := _state(caster, target)
	_cast(caster, target, state, _def())
	# Raw total = 100*1.6 + 10000*0.08 = 960; five equal pulses = 192.
	_h.expect(int(target.hp) == 9808, "first_pulse_not_split",
		"施法帧应只扣第一段 192，实际剩余 %d" % int(target.hp))
	_advance(state, 4)
	_h.expect(int(target.hp) == 9808, "pulse_too_early",
		"0.5 秒前不应出现第二段，实际剩余 %d" % int(target.hp))
	_advance(state, 1)
	_h.expect(int(target.hp) == 9616, "second_pulse_not_at_half_second",
		"第 5 个固定 tick 应结算第二段，实际剩余 %d" % int(target.hp))
	_advance(state, 15)
	_h.expect(int(target.hp) == 9040, "five_pulse_total_wrong",
		"2 秒后总伤害应为 960，实际总伤害 %d" % (10000 - int(target.hp)))
	_h.expect((state.get("pending_skill_damage", []) as Array).is_empty(), "queue_not_drained",
		"第五段后定时伤害队列没有清空")
	var stats: Dictionary = state.get("unit_stats", {})
	_h.expect(int((stats.get("god_king", {}) as Dictionary).get("damage_dealt", 0)) == 960,
		"timed_damage_unattributed", "五段伤害没有完整记到神王统计")
	var hit_numbers := 0
	for event in state.get("visual_events", []):
		if str((event as Dictionary).get("type", "")) == "hit_number":
			hit_numbers += 1
	_h.expect(hit_numbers == 5, "pulse_numbers_missing",
		"应显示 5 个技能伤害数字，实际 %d 个" % hit_numbers)


func _case_dodge_is_rolled_once() -> void:
	var caster := _fighter("god_king_dodge", "player", 5000, 100)
	var target := _fighter("dodge_target", "enemy", 10000)
	target.dodge = 1.0
	var state := _state(caster, target)
	_cast(caster, target, state, _def())
	_advance(state, 25)
	_h.expect(int(target.hp) == 10000, "dodged_judgement_kept_ticking",
		"施法判定已闪避，后续不应再偷偷扣血")
	_h.expect((state.get("pending_skill_damage", []) as Array).is_empty(), "dodge_left_queue",
		"整次裁决闪避后不应留下后续队列")
	_h.expect(str(caster.get("vfx_skill_target_uid", "")) == "dodge_target",
		"dodged_target_lost_vfx", "被闪避的技能目标仍应显示落雷")


func _case_later_invulnerability_blocks_only_due_pulse() -> void:
	var caster := _fighter("god_king_invuln", "player", 5000, 100)
	var target := _fighter("invuln_target", "enemy", 10000)
	var state := _state(caster, target)
	_cast(caster, target, state, _def())
	StatusEffectService.add_status(target, "invulnerable", 1.0, {})
	_advance(state, 5)
	_h.expect(int(target.hp) == 9808, "later_invulnerability_ignored",
		"第二段到期时目标无敌，应保持第一段后的血量")
	target.statuses.erase("invulnerable")
	_advance(state, 15)
	_h.expect(int(target.hp) == 9232, "blocked_pulse_replayed",
		"被无敌挡掉的一段不应补发；预期总计 4 段，实际剩余 %d" % int(target.hp))


func _case_star4_uses_sixteen_percent() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for row in units:
		var d: Dictionary = row
		if str(d.get("id", "")) != "god_king":
			continue
		var star4: Dictionary = d.get("star4", {})
		_h.expect(is_equal_approx(float(star4.get("max_hp_bonus_pct", 0.0)), 0.16),
			"star4_max_hp_pct_wrong", "四星神王目标最大生命系数必须是 16%")
		_h.expect(int(d.get("damage_tick_count", 0)) == 5 and is_equal_approx(float(d.get("damage_tick_interval", 0.0)), 0.5),
			"timing_not_data_driven", "神王应由数据表配置为 5 段、每段间隔 0.5 秒")
		return
	_h.expect(false, "god_king_missing", "race_units 表里找不到 god_king")
