extends Node

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


func check_meteor() -> void:
	var b := spawn("boss_meteor_caster")
	b.pos = Vector2(500, 100)
	var a := piece("a", "player", Vector2(500, 200))
	var near := piece("near", "player", Vector2(700, 200))
	var far := piece("far", "player", Vector2(760, 200))
	var targets := [a, near, far]
	var s := state(targets, [b])
	DamageService.begin_stat_context(s, b)
	BattleSimSkills._skill_element_meteor(b, targets, b.def)
	DamageService.clear_stat_context()
	h.expect(a.hp == 1640 and near.hp == 1640 and far.hp == 2000,
		"meteor_radius", "250px meteor hit wrong targets: %d/%d/%d" % [a.hp, near.hp, far.hp])


func check_thunder() -> void:
	var b := spawn("boss_thunder_core")
	var a := piece("attacker", "player", Vector2(500, 300))
	var near := piece("near", "player", Vector2(600, 300))
	var far := piece("far", "player", Vector2(800, 300))
	var s := state([a, near, far], [b])
	b.skill_stacks = 7
	BattleSimTreasures._apply_defender_reaction(a, b, 1, s)
	h.expect(a.hp == 1550 and near.hp == 1800 and far.hp == 2000,
		"thunder_splash", "450 main + 200 splash: %d/%d/%d" % [a.hp, near.hp, far.hp])
	var shown := 0
	for e: Dictionary in s.visual_events:
		if str(e.get("type", "")) == "hit_number" and str(e.get("skill_id", "")) == "overload_counter":
			shown += 1
	h.expect(shown == 2, "thunder_numbers", "expected two visible thunder damage numbers")


func check_mirror_priest() -> void:
	var mirror := spawn("boss_mirror_lord")
	mirror.hp = int(round(float(mirror.max_hp) * 0.70))
	var s := state([], [mirror])
	var spawned := BattleSimSkills._skill_mirror_clone(mirror, s, mirror.def)
	h.expect(spawned == 1 and s.enemy.size() == 2 and int(s.enemy[1].atk) == int(mirror.atk),
		"mirror_attack", "mirror attack should equal source attack")
	for round_index in [5, 10, 15, 20]:
		var escort := BattleSimShared._round_boss_monster_template(boss_def("boss_holy_priest"), round_index)
		h.expect(not escort.is_empty() and float(escort.get("range", 1)) > 1.0,
			"priest_escort_%d" % round_index, "priest escort must be ranged")
	var priest := spawn("boss_holy_priest")
	var ally := piece("ally", "enemy", Vector2(500, 200))
	ally.hp = 1000
	BattleSimSkills._skill_holy_purify(priest, [ally], priest.def)
	h.expect(ally.hp == 1400 and ally.shield == 300, "priest_heal_shield",
		"expected 20%% heal and 15%% shield; got HP=%d shield=%d" % [ally.hp, ally.shield])


func check_rage_blood() -> void:
	var rage := spawn("boss_rage_beast")
	var s := state([], [rage])
	for i in range(50):
		BattleSimTreasures._apply_boss_attacker_passives(rage, s)
	h.expect(rage.atk == 954 and rage.skill_stacks == 50 and is_equal_approx(rage.attack_speed, 2.5),
		"rage_50", "50 stacks should give 954 ATK, cap 50 and 2.5 AS")
	BattleSimTreasures._apply_boss_attacker_passives(rage, s)
	h.expect(rage.atk == 954 and rage.skill_stacks == 50, "rage_cap", "stack cap failed")
	var blood := spawn("boss_blood_demon")
	s = state([], [blood])
	blood.hp = int(blood.max_hp / 2)
	BattleSimTreasures._process_boss_health_triggers(s)
	h.expect(bool(blood.get("blood_rage_active", false)) and blood.atk == 184 and is_equal_approx(blood.attack_speed, 1.35),
		"blood_threshold", "50% enrage should double attack and add 0.50 AS")
	BattleSimTreasures._apply_boss_attack_lifesteal(blood, blood.def, 100)
	h.expect(blood.hp == int(blood.max_hp / 2) + 20, "blood_lifesteal", "20% lifesteal failed")
	BattleSimTreasures._process_boss_health_triggers(s)
	h.expect(blood.atk == 184, "blood_once", "enrage repeated")


func check_soul() -> void:
	var b := spawn("boss_soul_devourer")
	b.hp = b.max_hp - 1000
	var s := state([], [b])
	var m := piece("monster", "enemy", Vector2(900, 200))
	m.id = "pve_probe"
	BattleSimTreasures._apply_soul_devour_on_death(s, m)
	h.expect(b.hp == b.max_hp - 370 and b.atk == 143 and is_equal_approx(b.attack_speed, 1.5),
		"soul_monster", "same-lane monster death did not grant 20% heal/attack and +0.20 AS")
	BattleSimTreasures._apply_soul_devour_on_death(s, m)
	h.expect(b.soul_devour_stacks == 1, "soul_dedupe", "death counted twice")
	var p := piece("piece", "player", Vector2(900, 200))
	BattleSimTreasures._apply_soul_devour_on_death(s, p)
	h.expect(b.soul_devour_stacks == 2 and b.atk == 167, "soul_piece", "enemy piece did not count")
	BattleSimTreasures._apply_soul_devour_on_death(s, piece("other_lane", "player", Vector2(900, 200), 0, 2))
	h.expect(b.soul_devour_stacks == 2, "soul_lane", "other lane counted")
	for i in range(16):
		BattleSimTreasures._apply_soul_devour_on_death(s, piece("extra_%d" % i, "player", Vector2(900, 200)))
	h.expect(b.soul_devour_stacks == 18 and b.atk == 547 and is_equal_approx(b.attack_speed, 2.5),
		"soul_4_6x", "18 deaths should be 4.6x entry ATK with 2.5 AS cap")


func check_twin() -> void:
	var b := spawn("boss_twin_gate")
	b.pos = Vector2(500, 200)
	var a := piece("primary", "player", Vector2(500, 300))
	var behind := piece("behind", "player", Vector2(500, 400))
	var armor := piece("armor", "player", Vector2(550, 400), 80)
	var outside := piece("outside", "player", Vector2(700, 400))
	var front := piece("front", "player", Vector2(500, 250))
	var targets := [a, behind, armor, outside, front]
	var s := state(targets, [b])
	DamageService.begin_stat_context(s, b)
	BattleSimulator._apply_twin_cleave(b, a, s, [b], targets)
	DamageService.clear_stat_context()
	h.expect(a.hp == 2000 and behind.hp == 1952 and armor.hp > 1952 and armor.hp < 2000 and outside.hp == 2000 and front.hp == 2000,
		"twin_cone", "50% physical cleave did not respect cone or defense")
	h.expect(is_equal_approx(float(b.def.get("revive_hp_pct", 0)), 0.60), "twin_revive", "revive must be 60%")


func check_apocalypse() -> void:
	var b := spawn("boss_apocalypse")
	var p := piece("victim", "player", Vector2(500, 300))
	var s := state([p], [b])
	h.expect(is_equal_approx(float(b.def.get("skill_cd", 0)), 8.0), "apocalypse_cd", "cooldown must be 8s")
	var started := BattleSimSkills._skill_apocalypse_charge(b, s, b.def)
	h.expect(started and b.shield == int(round(float(b.max_hp) * 0.10)), "apocalypse_shield", "10% shield failed")
	s.elapsed = 3.1
	BattleSimulator._process_boss_charges(s)
	h.expect(p.hp == 1752, "apocalypse_damage", "250% of 99 attack should deal 248 true damage")
