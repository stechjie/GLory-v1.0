extends Node

# Damage-over-time kills must pay the unit that applied the effect.
#
# Why this exists: BattleSimulator._process_pending_kill_rewards credits kill
# gold by reading victim.killer_uid, which DamageService stamps from the current
# damage context. _tick_statuses clears that context before every fighter, so a
# poison or bleed tick used to kill with an empty killer_uid — the sweep skipped
# the victim and the gold was not misattributed, it was **lost**. The comment at
# BattleSimulator.gd:1206 recorded that as a known limitation.
#
# Poison is 82-93% of what undead_poison actually deals, so the stats panel was
# crediting it with almost nothing either.
#
# determinism_check cannot cover this. It hashes replay output, and attribution
# changes neither damage numbers nor RNG ordering — the same reason the toxic
# armour path sat unexercised there (see four_star_values_check case 12).
#
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/dot_attribution_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "dot_attribution"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_poison_kill_credits_the_caster()
	_case_poison_damage_credits_the_caster()
	_case_bleed_kill_credits_the_caster()
	_case_last_hit_still_wins()
	_case_self_inflicted_bleed_credits_nobody()
	_case_poison_numbers_come_from_the_def()
	_h.finish(get_tree())


func _fighter(uid: String, hp: int) -> Dictionary:
	return {
		"uid": uid, "id": uid, "team": "player", "def": {},
		"hp": hp, "max_hp": hp, "atk": 10, "defense": 0,
		"alive": true, "shield": 0, "statuses": {},
	}


# DamageService._add_stat_value only credits uids already present in unit_stats
# (the real battle registers them in BattleSimShared when fighters are built), so
# a probe state has to register them too or every credit is silently dropped.
func _state(uids: Array) -> Dictionary:
	var stats := {}
	for uid in uids:
		stats[str(uid)] = {}
	return {"unit_stats": stats, "presentation_events": []}


# Applies `effect` to the victim while `caster` owns the damage context, exactly
# as a basic attack or skill dispatch would.
func _apply_from(caster: Dictionary, victim: Dictionary, state: Dictionary, effect: Callable) -> void:
	DamageService.set_stat_state(state)
	DamageService.begin_stat_context(state, caster)
	effect.call()
	DamageService.clear_stat_context()


# --- 1. A poison tick that kills stamps the caster --------------------------
func _case_poison_kill_credits_the_caster() -> void:
	var state := _state(["poisoner", "victim"])
	var caster := _fighter("poisoner", 500)
	var victim := _fighter("victim", 100)
	_apply_from(caster, victim, state, func(): StatusEffectService.add_poison(victim, 10.0, 1.0))

	# The battle loop clears the context before ticking each fighter; the tick has
	# to put the caster back on its own.
	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()
	StatusEffectService.tick(victim, 1.0)

	if not _h.expect(not bool(victim.get("alive", true)), "poison_did_not_kill",
			"毒跳伤没有打死目标（剩 %d 血），这条用例的前提就不成立" % int(victim.get("hp", 0))):
		return
	_h.expect(str(victim.get("killer_uid", "")) == "poisoner", "poison_kill_unattributed",
		"毒杀之后 killer_uid 是 %s，应为 poisoner —— 空串会让 _process_pending_kill_rewards "
			% _q(str(victim.get("killer_uid", "")))
		+ "跳过这次死亡，击杀金直接蒸发")


# --- 2. Poison damage shows up on the caster's damage_dealt -----------------
func _case_poison_damage_credits_the_caster() -> void:
	var state := _state(["poisoner", "victim"])
	var caster := _fighter("poisoner", 500)
	var victim := _fighter("victim", 10000)
	_apply_from(caster, victim, state, func(): StatusEffectService.add_poison(victim, 10.0, 0.05))

	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()
	StatusEffectService.tick(victim, 1.0)

	var stats: Dictionary = state.get("unit_stats", {})
	var dealt := int((stats.get("poisoner", {}) as Dictionary).get("damage_dealt", 0))
	_h.expect(dealt > 0, "poison_damage_unattributed",
		"毒跳伤打了 %d 点，但施法者的 damage_dealt 是 %d —— 战斗统计面板会严重低估毒系单位"
			% [int(10000 * 0.05), dealt])


# --- 3. Bleed credits the caster, and cannot kill ---------------------------
# StatusEffectService.bleed_damage returns 0 once current HP is 1, so bleed can
# never land the killing blow: there is no kill-gold hole here, only a stats one.
# The floor is pinned as well — if bleed ever becomes lethal, whoever makes that
# change has to come back and think about attribution.
func _case_bleed_kill_credits_the_caster() -> void:
	var state := _state(["bleeder", "victim"])
	var caster := _fighter("bleeder", 500)
	var victim := _fighter("victim", 2000)
	_apply_from(caster, victim, state, func(): StatusEffectService.add_bleed(victim, 30.0, 0.5))

	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()
	for _i in 40:
		StatusEffectService.tick(victim, 1.0)

	var stats: Dictionary = state.get("unit_stats", {})
	_h.expect(int((stats.get("bleeder", {}) as Dictionary).get("damage_dealt", 0)) > 0,
		"bleed_damage_unattributed",
		"失血伤害没有记到施法者头上 —— 战斗统计面板会漏掉血契之刃那条线的输出")
	_h.expect(bool(victim.get("alive", true)) and int(victim.get("hp", 0)) == 1,
		"bleed_became_lethal",
		"失血把目标打死了（剩 %d 血）—— bleed_damage 的 current_hp <= 1 下限没了，"
			% int(victim.get("hp", 0))
		+ "致死路径的归属要重新过一遍")


# --- 4. Last hit still wins -------------------------------------------------
# A unit finished off by someone else's attack must credit that attacker, not
# whoever poisoned it earlier. This is the half of the rule that already worked;
# the case exists so restoring the DoT source cannot quietly steal kills.
func _case_last_hit_still_wins() -> void:
	var state := _state(["poisoner", "striker", "victim"])
	var poisoner := _fighter("poisoner", 500)
	var striker := _fighter("striker", 500)
	var victim := _fighter("victim", 1000)
	_apply_from(poisoner, victim, state, func(): StatusEffectService.add_poison(victim, 10.0, 0.01))

	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()
	StatusEffectService.tick(victim, 1.0)          # poison chips it, does not kill
	if not _h.expect(bool(victim.get("alive", true)), "poison_killed_too_early",
			"用于对照的目标被毒先打死了，这条用例测不到最后一击"):
		return

	DamageService.begin_stat_context(state, striker)
	DamageService.apply_damage(victim, 99999, true)
	DamageService.clear_stat_context()

	_h.expect(not bool(victim.get("alive", true)), "strike_did_not_kill", "补刀没有打死目标")
	_h.expect(str(victim.get("killer_uid", "")) == "striker", "last_hit_stolen",
		"被 striker 补刀打死，killer_uid 却是 %s —— 中毒的来源把击杀抢走了"
			% _q(str(victim.get("killer_uid", ""))))


# --- 5. Self-inflicted bleed credits nobody ---------------------------------
# atk_blood_pact makes its own holder bleed as the cost. If that kills, the
# sweep must not pay the victim for its own death; _process_pending_kill_rewards
# already skips killer == victim, so this pins that the source we now record
# cannot route around it.
func _case_self_inflicted_bleed_credits_nobody() -> void:
	var state := _state(["loner"])
	var loner := _fighter("loner", 20)
	_apply_from(loner, loner, state, func(): StatusEffectService.add_bleed(loner, 10.0, 0.95))

	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()
	for _i in 30:
		if not bool(loner.get("alive", true)):
			break
		StatusEffectService.tick(loner, 1.0)

	if not bool(loner.get("alive", true)):
		_h.expect(str(loner.get("killer_uid", "")) == "loner", "self_bleed_source_lost",
			"自残失血致死，killer_uid 应当就是它自己（补结算据此跳过），实际是 %s"
				% _q(str(loner.get("killer_uid", ""))))
	else:
		_h.item()


# --- 6. Poison numbers come from the data table -----------------------------
# They were hardcoded in BattleSimulator._apply_attack_statuses, which is why the
# 4-star tier could not touch a poison unit's main output.
func _case_poison_numbers_come_from_the_def() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "units_empty", "race_units 表为空"):
		return
	var covered := 0
	for row in units:
		var d: Dictionary = row
		if str(d.get("skill_id", "")) != "poison_attack":
			continue
		covered += 1
		var uid := str(d.get("id", "?"))
		_h.expect(d.has("poison_pct_max_hp") and d.has("poison_duration"),
			"poison_fields_missing",
			"%s 是毒系单位，但数据表里没有 poison_pct_max_hp / poison_duration —— "
				% uid
			+ "会回落到硬编码默认值，4 星碰不到它的主要输出")
		var block: Dictionary = d.get("star4", {})
		var base_pct := float(d.get("poison_pct_max_hp", 0.03))
		var four_pct := float(block.get("poison_pct_max_hp", base_pct))
		_h.expect(four_pct > base_pct, "poison_not_stronger_at_four_star",
			"%s 的 4 星毒伤仍是 %s —— 毒伤按目标最大生命算，与自身攻击无关，"
				% [uid, str(four_pct)]
			+ "不给它单独的 4 星数值，这只棋子的 4 星等于只加了血和防")
	_h.note("毒系单位：%d 只" % covered)


func _q(text: String) -> String:
	return "「%s」" % text
