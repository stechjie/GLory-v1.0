extends Node

# Boss 技能行为门禁。
#
# 11.06：所有期望值都从 Boss 的数据（bosses.json，由 Excel「06_Boss」导出、--check 保证
# 两边一致）现算，不再写死数字。以前这里写着 20% 吸血、10% 护盾、954 攻击之类的常数，
# Excel 一改数值，检查就跟数据对不上、长期挂红。现在检查只管「行为对不对」：
# 谁被打到、有没有封顶、会不会重复触发；数值本身以 Excel 为准。
# 站位距离也按数据里的半径 / 锥形尺寸取比例，改范围不会让站位失效。

const Harness := preload("res://tools/CheckHarness.gd")
var h


func _ready() -> void:
	h = Harness.new("boss_balance")
	DataRegistry.ensure_loaded()
	GameState.reset_run()
	GameState.team_mode = true
	check_meteor()
	check_thunder()
	check_mirror_priest()
	check_rage_blood()
	check_soul()
	check_twin()
	check_apocalypse()
	GameState.reset_run()
	h.finish(get_tree())


func boss_def(id: String) -> Dictionary:
	for d: Dictionary in DataRegistry.get_table("bosses").get("bosses", []):
		if str(d.get("id", "")) == id:
			return d
	return {}


func spawn(id: String) -> Dictionary:
	var out: Array = []
	BattleSimShared._append_lane_boss(out, 0, boss_def(id))
	h.expect(not out.is_empty(), "spawn_" + id, "Boss did not spawn")
	return out[0] if not out.is_empty() else {}


func piece(uid: String, team: String, pos: Vector2, armor: int = 0, lane: int = 0) -> Dictionary:
	var d := {"id": "probe_piece", "name": "probe", "hp": 2000, "atk": 1,
		"def": armor, "attack_speed": 1.0, "range": 1, "move_speed": 1.0,
		"skill_id": "none", "race": "human", "element": "ren"}
	var f: Dictionary = BattleSimShared._fighter_from_def(d, 0, team, 0, 1)
	f.uid = uid
	f.pos = pos
	f.lane = lane
	return f


func state(player: Array, enemy: Array) -> Dictionary:
	var s := {"kind": "boss", "player": player, "enemy": enemy, "elapsed": 1.0,
		"log": [], "visual_events": [], "unit_stats": {}, "revive_queue": [],
		"race_trait_processed_deaths": {}, "soul_devour_processed_deaths": {}}
	DamageService.set_stat_state(s)
	return s


func num(d: Dictionary, key: String) -> float:
	h.expect(d.has(key), "field_" + key, "Boss 数据缺字段 %s" % key)
	return float(d.get(key, 0.0))


func check_meteor() -> void:
	var b := spawn("boss_meteor_caster")
	var radius := num(b.def, "aoe_radius")
	var dmg := int(num(b.def, "skill_damage"))  # 已含 Boss 首场 ×1.5
	b.pos = Vector2(500, 100)
	var a := piece("a", "player", Vector2(500, 200))
	var near := piece("near", "player", Vector2(500.0 + radius * 0.8, 200))
	var far := piece("far", "player", Vector2(500.0 + radius * 1.04, 200))
	var targets := [a, near, far]
	var s := state(targets, [b])
	DamageService.begin_stat_context(s, b)
	BattleSimSkills._skill_element_meteor(b, targets, b.def)
	DamageService.clear_stat_context()
	h.expect(a.hp == 2000 - dmg and near.hp == 2000 - dmg and far.hp == 2000,
		"meteor_radius", "%.0fpx meteor (%d true damage) hit wrong targets: %d/%d/%d" % [radius, dmg, a.hp, near.hp, far.hp])


func check_thunder() -> void:
	var b := spawn("boss_thunder_core")
	var radius := num(b.def, "splash_radius")
	var main_dmg := int(num(b.def, "skill_damage"))
	var splash := int(num(b.def, "splash_damage"))
	var a := piece("attacker", "player", Vector2(500, 300))
	var near := piece("near", "player", Vector2(500.0 + radius * 0.5, 300))
	var far := piece("far", "player", Vector2(500.0 + radius * 1.6, 300))
	var s := state([a, near, far], [b])
	b.skill_stacks = int(num(b.def, "hit_threshold")) - 1
	BattleSimTreasures._apply_defender_reaction(a, b, 1, s)
	h.expect(a.hp == 2000 - main_dmg and near.hp == 2000 - splash and far.hp == 2000,
		"thunder_splash", "%d main + %d splash: %d/%d/%d" % [main_dmg, splash, a.hp, near.hp, far.hp])
	var shown := 0
	for e: Dictionary in s.visual_events:
		if str(e.get("type", "")) == "hit_number" and str(e.get("skill_id", "")) == "overload_counter":
			shown += 1
	h.expect(shown == 2, "thunder_numbers", "expected two visible thunder damage numbers")


func check_mirror_priest() -> void:
	var mirror := spawn("boss_mirror_lord")
	var step := num(mirror.def, "clone_per_missing_hp_pct")
	mirror.hp = int(round(float(mirror.max_hp) * (1.0 - step * 1.2)))
	var s := state([], [mirror])
	var spawned := BattleSimSkills._skill_mirror_clone(mirror, s, mirror.def)
	var want_atk := int(round(float(mirror.atk) * num(mirror.def, "clone_atk_pct")))
	h.expect(spawned == 1 and s.enemy.size() == 2 and int(s.enemy[1].atk) == want_atk,
		"mirror_attack", "mirror attack should be %d (source × clone_atk_pct)" % want_atk)
	for round_index in [5, 10, 15, 20]:
		var escort := BattleSimShared._round_boss_monster_template(boss_def("boss_holy_priest"), round_index)
		h.expect(not escort.is_empty() and float(escort.get("range", 1)) > 1.0,
			"priest_escort_%d" % round_index, "priest escort must be ranged")
	# 11.05 圣愈祭司：只作用于自己和身边半径内的友军；自己只拿护盾不回血；护盾刷新到上限、不累加。
	var priest := spawn("boss_holy_priest")
	var heal_pct := num(priest.def, "heal_pct")
	var shield_pct := num(priest.def, "shield_pct")
	var radius := float(priest.def.get("heal_radius", BattleSimSkills.HOLY_PURIFY_RADIUS))
	var ally := piece("ally", "enemy", Vector2(priest.pos) + Vector2(radius * 0.4, 0))
	ally.hp = 1000
	var far := piece("far", "enemy", Vector2(priest.pos) + Vector2(radius * 1.6, 0))
	far.hp = 1000
	priest.hp = int(priest.max_hp) - 500
	var priest_hp_before := int(priest.hp)
	var all_allies := [priest, ally, far]
	BattleSimSkills._skill_holy_purify(priest, all_allies, priest.def)
	var ally_heal := int(round(2000.0 * heal_pct))
	var ally_cap := int(round(2000.0 * shield_pct))
	h.expect(ally.hp == 1000 + ally_heal and ally.shield == ally_cap, "priest_heal_shield",
		"nearby ally: expected +%d HP and %d shield; got HP=%d shield=%d" % [ally_heal, ally_cap, ally.hp, ally.shield])
	h.expect(far.hp == 1000 and int(far.get("shield", 0)) == 0, "priest_range",
		"ally outside %.0f must get nothing; got HP=%d shield=%d" % [radius, far.hp, int(far.get("shield", 0))])
	var priest_cap := int(round(float(priest.max_hp) * shield_pct))
	h.expect(int(priest.hp) == priest_hp_before and int(priest.shield) == priest_cap, "priest_self_shield_only",
		"Boss itself: no heal, shield %d; got HP %d->%d shield=%d" % [priest_cap, priest_hp_before, int(priest.hp), int(priest.shield)])
	for i in 5:
		BattleSimSkills._skill_holy_purify(priest, all_allies, priest.def)
	h.expect(int(priest.shield) == priest_cap and ally.shield == ally_cap, "priest_shield_no_stack",
		"shield must refresh to the cap, not stack; got Boss=%d ally=%d" % [int(priest.shield), ally.shield])


func check_rage_blood() -> void:
	var rage := spawn("boss_rage_beast")
	var s := state([], [rage])
	# 11.01 叠加规则：每层 +开战攻击的 atk_per_hit（相加，不复利），攻速每层 +aspd_per_hit 进百分比池，
	# 面板攻速 attack_speed 本身不再被改写；攻速总加成封顶 +150%。
	var cap := int(num(rage.def, "max_stacks"))
	var rage_base := int(rage.atk)
	var rage_aspd := float(rage.attack_speed)
	var rage_expected := rage_base + cap * int(round(float(rage_base) * num(rage.def, "atk_per_hit")))
	var pool := float(cap) * num(rage.def, "aspd_per_hit")
	for i in range(cap):
		BattleSimTreasures._apply_boss_attacker_passives(rage, s)
	h.expect(rage.atk == rage_expected and rage.skill_stacks == cap and is_equal_approx(rage.attack_speed, rage_aspd)
		and is_equal_approx(float(rage.aspd_bonus_pct), pool)
		and is_equal_approx(StatusEffectService.attack_speed_multiplier(rage), 1.0 + minf(pool, StatusEffectService.ASPD_PCT_MAX)),
		"rage_full", "%d stacks should give ATK %d and +%.0f%% AS pool, base AS untouched (got ATK %d)" % [cap, rage_expected, pool * 100.0, int(rage.atk)])
	BattleSimTreasures._apply_boss_attacker_passives(rage, s)
	h.expect(rage.atk == rage_expected and rage.skill_stacks == cap, "rage_cap", "stack cap failed")

	var blood := spawn("boss_blood_demon")
	s = state([], [blood])
	var base_atk := int(blood.atk)
	var base_aspd := float(blood.attack_speed)
	blood.hp = int(floor(float(blood.max_hp) * num(blood.def, "trigger_hp_pct")))
	var hp_at_trigger := int(blood.hp)
	BattleSimTreasures._process_boss_health_triggers(s)
	var enraged_atk := base_atk + int(round(float(base_atk) * num(blood.def, "atk_bonus")))
	h.expect(bool(blood.get("blood_rage_active", false)) and blood.atk == enraged_atk and is_equal_approx(blood.attack_speed, base_aspd)
		and is_equal_approx(float(blood.get("aspd_bonus_pct", 0.0)), num(blood.def, "aspd_bonus")),
		"blood_threshold", "enrage at threshold should give ATK %d and +%.0f%% AS to the pool (got ATK %d)" % [enraged_atk, num(blood.def, "aspd_bonus") * 100.0, int(blood.atk)])
	BattleSimTreasures._apply_boss_attack_lifesteal(blood, blood.def, 100)
	var steal := maxi(1, int(round(100.0 * num(blood.def, "lifesteal"))))
	h.expect(blood.hp == hp_at_trigger + steal, "blood_lifesteal",
		"%.0f%% lifesteal on 100 damage should heal %d (got %d)" % [num(blood.def, "lifesteal") * 100.0, steal, int(blood.hp) - hp_at_trigger])
	BattleSimTreasures._process_boss_health_triggers(s)
	h.expect(blood.atk == enraged_atk, "blood_once", "enrage repeated")


func check_soul() -> void:
	# 11.05：层数封顶，满层后照样回血。
	var b := spawn("boss_soul_devourer")
	var entry_atk := float(b.get("def", {}).get("atk", b.atk))
	var heal := int(round(float(b.max_hp) * num(b.def, "kill_heal_pct")))
	var atk_stack := num(b.def, "atk_stack")
	var aspd_stack := num(b.def, "aspd_stack")
	var cap := int(num(b.def, "max_stacks"))
	b.hp = b.max_hp - 1000
	var s := state([], [b])
	var m := piece("monster", "enemy", Vector2(900, 200))
	m.id = "pve_probe"
	BattleSimTreasures._apply_soul_devour_on_death(s, m)
	h.expect(b.hp == b.max_hp - 1000 + mini(1000, heal) and b.atk == int(round(entry_atk * (1.0 + atk_stack))) and is_equal_approx(float(b.get("aspd_bonus_pct", 0.0)), aspd_stack),
		"soul_monster", "same-lane monster death: expected +%d HP, ATK %d, +%.0f%% AS (hp=%d atk=%d)" % [mini(1000, heal), int(round(entry_atk * (1.0 + atk_stack))), aspd_stack * 100.0, b.hp, b.atk])
	BattleSimTreasures._apply_soul_devour_on_death(s, m)
	h.expect(b.soul_devour_stacks == 1, "soul_dedupe", "death counted twice")
	var p := piece("piece", "player", Vector2(900, 200))
	BattleSimTreasures._apply_soul_devour_on_death(s, p)
	h.expect(b.soul_devour_stacks == 2 and b.atk == int(round(entry_atk * (1.0 + 2.0 * atk_stack))), "soul_piece", "enemy piece did not count")
	BattleSimTreasures._apply_soul_devour_on_death(s, piece("other_lane", "player", Vector2(900, 200), 0, 2))
	h.expect(b.soul_devour_stacks == 2, "soul_lane", "other lane counted")
	for i in range(cap + 6):
		BattleSimTreasures._apply_soul_devour_on_death(s, piece("extra_%d" % i, "player", Vector2(900, 200)))
	var capped_atk := int(round(entry_atk * (1.0 + float(cap) * atk_stack)))
	h.expect(b.soul_devour_stacks == cap and b.atk == capped_atk
		and is_equal_approx(StatusEffectService.attack_speed_multiplier(b), 1.0 + minf(float(cap) * aspd_stack, StatusEffectService.ASPD_PCT_MAX)),
		"soul_cap", "deaths past the cap should stop at %d stacks = ATK %d (got %d stacks, atk %d)" % [cap, capped_atk, int(b.soul_devour_stacks), int(b.atk)])
	b.hp = 1
	BattleSimTreasures._apply_soul_devour_on_death(s, piece("after_cap", "player", Vector2(900, 200)))
	h.expect(b.hp == 1 + heal and b.soul_devour_stacks == cap, "soul_heal_after_cap", "deaths after the cap must still heal without adding stacks")


func check_twin() -> void:
	var b := spawn("boss_twin_gate")
	var dist := num(b.def, "cleave_distance")
	var w0 := num(b.def, "cleave_start_half_width")
	var w1 := num(b.def, "cleave_end_half_width")
	var along := dist * 0.55
	var width_here := w0 + (w1 - w0) * 0.55
	b.pos = Vector2(500, 200)
	var a := piece("primary", "player", Vector2(500, 300))
	var behind := piece("behind", "player", Vector2(500, 300.0 + along))
	var armor := piece("armor", "player", Vector2(500.0 + width_here * 0.7, 300.0 + along), 80)
	var outside := piece("outside", "player", Vector2(500.0 + w1 * 2.2, 300.0 + along))
	var front := piece("front", "player", Vector2(500, 250))
	var targets := [a, behind, armor, outside, front]
	var s := state(targets, [b])
	DamageService.begin_stat_context(s, b)
	BattleSimulator._apply_twin_cleave(b, a, s, [b], targets)
	DamageService.clear_stat_context()
	var cleave := maxi(1, int(round(float(b.atk) * num(b.def, "cleave_atk_pct"))))
	h.expect(a.hp == 2000 and behind.hp == 2000 - cleave and armor.hp > 2000 - cleave and armor.hp < 2000 and outside.hp == 2000 and front.hp == 2000,
		"twin_cone", "%d physical cleave did not respect cone or defense (behind %d, armor %d)" % [cleave, behind.hp, armor.hp])
	var revive := num(b.def, "revive_hp_pct")
	h.expect(revive > 0.0 and revive <= 1.0, "twin_revive", "revive HP must be within (0%%, 100%%], got %.2f" % revive)


func check_apocalypse() -> void:
	var b := spawn("boss_apocalypse")
	var p := piece("victim", "player", Vector2(500, 300))
	var s := state([p], [b])
	h.expect(num(b.def, "skill_cd") > 0.0, "apocalypse_cd", "cooldown must be positive")
	var started := BattleSimSkills._skill_apocalypse_charge(b, s, b.def)
	var shield := int(round(float(b.max_hp) * num(b.def, "charge_shield_pct")))
	h.expect(started and b.shield == shield, "apocalypse_shield",
		"charge shield should be %d (%.0f%% max HP), got %d" % [shield, num(b.def, "charge_shield_pct") * 100.0, int(b.shield)])
	s.elapsed = float(s.elapsed) + num(b.def, "charge_sec") + 0.1
	BattleSimulator._process_boss_charges(s)
	var blast := int(round(float(b.atk) * num(b.def, "damage_atk_pct")))
	h.expect(p.hp == 2000 - blast, "apocalypse_damage",
		"%.0f%% of %d attack should deal %d true damage (got %d)" % [num(b.def, "damage_atk_pct") * 100.0, int(b.atk), blast, 2000 - p.hp])
