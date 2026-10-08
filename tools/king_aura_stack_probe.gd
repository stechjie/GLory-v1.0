extends Node
# 行为级探针：炎阳王者 king_aura 的「攻速加成是否永久叠加」。
# 不依赖任何重型 3D 场景，直接调 StatusEffectService + BattleSimSkills。
# 输出 PROBE / CHECK_RESULT 行，供门禁解析。

const TICK := 0.1
const AURA_PERIOD := 2.0      # BattleSimulator.gd:940  硬编码 skill_ready + 2.0
const ASPD_DURATION := 2.2    # BattleSimSkills.gd:296  add_status 写死 2.2


func _ready() -> void:
	var fails: Array[String] = []

	# ---- 1) 单次施加：攻速乘区是否为 1.25 ----
	var ally := _mk("ally_a")
	StatusEffectService.add_status(ally, "speed_bonus", ASPD_DURATION, {"pct": 0.25})
	var m1 := StatusEffectService.attack_speed_multiplier(ally)
	print("PROBE after_1_apply aspd_mult=%.4f remaining=%.3f" % [
		m1, float(ally.statuses.speed_bonus.get("remaining", -1.0))])
	_check(fails, absf(m1 - 1.25) <= 0.0001, "单次施加后攻速乘区应为 1.25，实为 %.4f" % m1)

	# ---- 2) 立刻再施加一次：乘法叠加还是覆盖？----
	StatusEffectService.add_status(ally, "speed_bonus", ASPD_DURATION, {"pct": 0.25})
	var m2 := StatusEffectService.attack_speed_multiplier(ally)
	print("PROBE after_2_apply aspd_mult=%.4f remaining=%.3f" % [m2, float(ally.statuses.speed_bonus.get("remaining", -1.0))])
	_check(fails, m2 <= 1.2501, "重复施加被乘法叠加：乘区升到 %.4f（预期保持 1.25 覆盖式）" % m2)

	# ---- 3) 冷却窗口内复施：remaining 是被 maxf 顶回，还是相加 ----
	var ally2 := _mk("ally_b")
	StatusEffectService.add_status(ally2, "speed_bonus", ASPD_DURATION, {"pct": 0.25})
	StatusEffectService.tick(ally2, 2.0)
	var before := float(ally2.statuses.speed_bonus.get("remaining", -1.0))
	StatusEffectService.add_status(ally2, "speed_bonus", ASPD_DURATION, {"pct": 0.25})
	var after := float(ally2.statuses.speed_bonus.get("remaining", -1.0))
	print("PROBE refresh_remaining before=%.3f after=%.3f" % [before, after])
	_check(fails, before > 0.0, "2.0s 后 speed_bonus 已过期（remaining=%.3f），无法验证刷新" % before)
	_check(fails, absf(after - ASPD_DURATION) <= 0.0001, "刷新后 remaining 应为 %.1f（maxf 语义），实为 %.3f" % [ASPD_DURATION, after])

	# ---- 4) 全程 tick：按光环周期复施，攻速加成是否连续无空窗 ----
	# 复现生产 tick 顺序：statuses 先 tick，再 _tick_skills 施法。
	var ally3 := _mk("ally_c")
	var t := 0.0
	var reapply_count := 0
	var gap_count := 0
	var min_mult := 99.0
	StatusEffectService.add_status(ally3, "speed_bonus", ASPD_DURATION, {"pct": 0.25})
	reapply_count = 1
	while t < 20.0:
		StatusEffectService.tick(ally3, TICK)
		t += TICK
		# 距上次施法满一个光环周期就复施（用 elapsed 阈值，不用 t 取模 —— 浮点累加
		# 会让取模阈值逐轮漂移，整段跑完可能一次都不施法，探针直接失效）
		if t >= float(reapply_count) * AURA_PERIOD:
			StatusEffectService.add_status(ally3, "speed_bonus", ASPD_DURATION, {"pct": 0.25})
			reapply_count += 1
			continue
		var m := StatusEffectService.attack_speed_multiplier(ally3)
		if m < min_mult:
			min_mult = m
		if m < 1.2499:
			gap_count += 1
			if gap_count <= 3:
				print("PROBE GAP at t=%.1f aspd_mult=%.4f" % [t, m])
	print("PROBE run_20s reapplies=%d gaps=%d min_mult=%.4f elapsed=%.2f" % [reapply_count, gap_count, min_mult, t])
	_check(fails, reapply_count >= 10, "20 秒内复施仅 %d 次，探针节奏不符预期" % reapply_count)
	_check(fails, gap_count == 0, "攻速加成出现 %d 次断档（应连续覆盖无空窗）" % gap_count)

	# ---- 5) 走真实技能入口 _skill_king_aura：光环范围与是否含自身 ----
	var king := _mk("king")
	king["def"] = {"skill_id": "king_aura", "aura_radius": 2, "ally_aspd_bonus": 0.25, "ally_crit_bonus": 0.25}
	king["pos"] = Vector2(0, 0)
	var near := _mk("near_ally")
	near["pos"] = Vector2(100, 0)     # 100px < 2*72=144px 光环内
	var far := _mk("far_ally")
	far["pos"] = Vector2(300, 0)      # 300px > 144px 光环外
	BattleSimSkills._skill_king_aura(king, [king, near, far], king.def)
	print("PROBE aura near=%.3f far=%.3f king=%.3f | crit near=%.3f far=%.3f king=%.3f" % [
		StatusEffectService.attack_speed_multiplier(near),
		StatusEffectService.attack_speed_multiplier(far),
		StatusEffectService.attack_speed_multiplier(king),
		float(near.get("crit_bonus", -1.0)),
		float(far.get("crit_bonus", -1.0)),
		float(king.get("crit_bonus", -1.0))])
	_check(fails, absf(StatusEffectService.attack_speed_multiplier(near) - 1.25) <= 0.0001, "光环内友军攻速乘区应为 1.25")
	_check(fails, absf(StatusEffectService.attack_speed_multiplier(far) - 1.0) <= 0.0001, "光环外友军不应获得攻速加成")
	_check(fails, float(far.get("crit_bonus", 0.0)) == 0.0, "光环外友军不应获得暴击加成")
	# 施放者自己也在 casters 里，且在半径 0 处 -> 必然吃到自身光环
	_check(fails, absf(StatusEffectService.attack_speed_multiplier(king) - 1.25) <= 0.0001, "施放者自身也应吃到光环攻速")

	# ---- 6) 两种加成的时间语义差异：攻速计时 vs 暴击永久字段 ----
	var crit_before := float(near.get("crit_bonus", 0.0))
	for i in 30:
		StatusEffectService.tick(near, TICK)
	var crit_after := float(near.get("crit_bonus", 0.0))
	var aspd_after := StatusEffectService.attack_speed_multiplier(near)
	print("PROBE after_3s crit %.3f -> %.3f  aspd=%.3f" % [crit_before, crit_after, aspd_after])
	_check(fails, absf(crit_after - crit_before) <= 0.0001, "暴击是永久字段，3 秒后不应衰减")
	_check(fails, aspd_after <= 1.0001, "攻速加成 3 秒后应已过期（实为 %.3f）" % aspd_after)

	# ---- 7) 复施时暴击走 maxf 语义（已有更高值不被压回）----
	near["crit_bonus"] = 0.60
	BattleSimSkills._skill_king_aura(king, [king, near, far], king.def)
	var crit_3 := float(near.get("crit_bonus", 0.0))
	print("PROBE crit_maxf self_0.600 then_aura -> %.3f" % crit_3)
	_check(fails, absf(crit_3 - 0.60) <= 0.0001, "暴击应为 maxf 语义，已有 0.60 不该被 0.25 覆盖")

	# ---- 7b) 用户问的核心：多次吃到光环，暴击是加到 0.25×N 还是封顶 0.25 ----
	var many := _mk("ally_e")
	var trace: Array[String] = []
	for i in 8:
		BattleSimSkills._skill_king_aura(king, [king, many], king.def)
		trace.append("%.2f" % float(many.get("crit_bonus", 0.0)))
	print("PROBE crit_reapply_8x -> [%s]" % ", ".join(trace))
	var crit_8 := float(many.get("crit_bonus", 0.0))
	_check(fails, absf(crit_8 - 0.25) <= 0.0001,
		"暴击复施 8 次后应为封顶 0.25（maxf 语义），实为 %.3f（若为 2.00 则是 += 累加）" % crit_8)

	# ---- 7c) 施放者自身反复吃光环，同样应封顶 ----
	var king_trace: Array[String] = []
	for i in 8:
		BattleSimSkills._skill_king_aura(king, [king, many], king.def)
		king_trace.append("%.2f" % float(king.get("crit_bonus", 0.0)))
	print("PROBE crit_self_reapply_8x -> [%s]" % ", ".join(king_trace))
	_check(fails, absf(float(king.get("crit_bonus", 0.0)) - 0.25) <= 0.0001, "施放者自身暴击也应封顶 0.25")

	# ---- 7d) 低起点不累加：从 0 起 8 次仍是 0.25，而不是 8×0.25 ----
	# （7b 已覆盖 0 起点；这里补“接力式”复施 + tick 之后仍不涨）
	for i in 12:
		StatusEffectService.tick(many, TICK)
	var crit_after_ticks := float(many.get("crit_bonus", 0.0))
	BattleSimSkills._skill_king_aura(king, [king, many], king.def)
	var crit_after_more := float(many.get("crit_bonus", 0.0))
	print("PROBE crit_after_ticks %.3f then_reapply -> %.3f" % [crit_after_ticks, crit_after_more])
	_check(fails, absf(crit_after_ticks - 0.25) <= 0.0001, "tick 不该影响顶层暴击字段（实为 %.3f）" % crit_after_ticks)
	_check(fails, absf(crit_after_more - 0.25) <= 0.0001, "过期后复施仍应封顶 0.25（实为 %.3f）" % crit_after_more)

	# ---- 8) 余量假设：攻速时长必须 > 光环周期，否则每轮留空窗 ----
	print("PROBE margin duration-period = %.2f (需 > 0)" % (ASPD_DURATION - AURA_PERIOD))
	_check(fails, ASPD_DURATION - AURA_PERIOD > 0.0, "攻速 buff 时长未超过光环周期，必然空窗")

	# ---- 9) remainning 累加超出时长不应溢出堆积 ----
	var ally4 := _mk("ally_d")
	for i in 10:
		StatusEffectService.add_status(ally4, "speed_bonus", ASPD_DURATION, {"pct": 0.25})
	var rem4 := float(ally4.statuses.speed_bonus.get("remaining", -1.0))
	print("PROBE ten_immediate_reapply remaining=%.3f (不应累加到 %.1f)" % [rem4, ASPD_DURATION * 10])
	_check(fails, rem4 <= ASPD_DURATION + 0.0001, "remaining 被累加堆积到 %.3f（预期被 maxf 封顶在 %.1f）" % [rem4, ASPD_DURATION])

	if fails.is_empty():
		print("CHECK_RESULT king_aura_stack_probe=PASS")
	else:
		for f in fails:
			print("CHECK_RESULT king_aura_stack_probe=FAIL reason=%s" % f)
	get_tree().quit(0 if fails.is_empty() else 1)


func _check(fails: Array[String], ok: bool, msg: String) -> void:
	if not ok:
		fails.append(msg)


func _mk(uid: String) -> Dictionary:
	return {
		"uid": uid, "id": uid, "alive": true, "hp": 1000, "max_hp": 1000,
		"pos": Vector2(0, 0), "statuses": {}, "attack_speed": 1.0,
	}
