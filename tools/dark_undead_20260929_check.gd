extends Node

var failed := 0


func _expect(ok: bool, label: String, detail: String) -> void:
	if ok:
		print("PASS ", label, " ", detail)
	else:
		failed += 1
		print("FAIL ", label, " ", detail)


func _unit(id: String, team: String, syn: Dictionary, pos: Vector2) -> Dictionary:
	var d := OfficeTestSim.find_def("piece", id)
	var f := BattleSimShared._fighter_from_def(d, 5, team, 5, 16)
	f.uid = "%s_%s" % [team, id]
	f.lane = 0
	f.pos = pos
	f.owner_syn = syn
	f.owner_treasures = []
	f.owner_gold = 0
	f.owner_pet = ""
	f.dodge = 0.0
	return f


func _ready() -> void:
	GameState.team_mode = true
	var dark_syn := SynergyService.flags_from_counts({"god": 0, "dark": 2, "undead": 0, "human": 0})
	var undead_syn := SynergyService.flags_from_counts({"god": 0, "dark": 0, "undead": 2, "human": 0})
	var fear_caster := _unit("dark_fear", "player", dark_syn, Vector2(500, 300))
	var victim := _unit("human_king", "enemy", {}, Vector2(500, 450))
	victim.defense = 0
	var state := {"player": [fear_caster], "enemy": [victim], "elapsed": 0.0,
		"visual_events": [], "unit_stats": {}, "kind": "pvp"}
	DamageService.begin_stat_context(state, fear_caster)
	StatusEffectService.add_status(victim, "attack_down", 4.0, {"pct": 0.10})
	_expect(is_equal_approx(float(victim.statuses.attack_down.pct), 0.13), "dark2_numeric", str(victim.statuses.attack_down))
	StatusEffectService.add_status(victim, "stun", 2.0, {})
	_expect(is_equal_approx(float(victim.statuses.stun.remaining), 2.6), "dark2_control", str(victim.statuses.stun))
	StatusEffectService.clear_negative_statuses(victim)
	BattleSimSkills._skill_fear(fear_caster, [victim], fear_caster.def, state)
	_expect(StatusEffectService.has_status(victim, "fear") and is_equal_approx(float(victim.statuses.fear.remaining), 2.6),
		"fear_status", str(victim.statuses))
	var start_y := float(victim.pos.y)
	BattleSimulator._step_team([victim], [fear_caster], 0.0, state)
	var retreat_y := float(victim.pos.y)
	StatusEffectService.tick(victim, 3.0)
	BattleSimulator._step_team([victim], [fear_caster], 3.0, state)
	_expect(retreat_y > start_y and float(victim.pos.y) < retreat_y, "fear_retreat_return",
		"start=%s retreat=%s return=%s" % [start_y, retreat_y, float(victim.pos.y)])
	DamageService.clear_stat_context()

	var succubus := _unit("dark_suc", "player", dark_syn, Vector2(500, 300))
	var succ_target := _unit("human_king", "enemy", {}, Vector2(500, 320))
	succ_target.defense = 0
	var succ_state := {"player": [succubus], "enemy": [succ_target], "elapsed": 0.0,
		"visual_events": [], "unit_stats": {}, "kind": "pvp"}
	DamageService.begin_stat_context(succ_state, succubus)
	var before := int(succ_target.hp)
	BattleSimSkills._skill_stun(succubus, [succ_target], succubus.def, succ_state)
	_expect(int(succ_target.hp) == before - int(round(float(succubus.atk) * 1.5)) and StatusEffectService.has_status(succ_target, "stun"),
		"succubus_damage_stun", "damage=%d stun=%s" % [before - int(succ_target.hp), str(succ_target.statuses.get("stun", {}))])
	DamageService.clear_stat_context()

	var poison_caster := _unit("undead_poison", "player", undead_syn, Vector2(500, 300))
	var poison_target := _unit("human_king", "enemy", {}, Vector2(500, 320))
	poison_target.hp = 500
	poison_target.max_hp = 1000
	var poison_state := {"player": [poison_caster], "enemy": [poison_target], "elapsed": 0.0,
		"visual_events": [], "unit_stats": {}, "kind": "pvp"}
	DamageService.begin_stat_context(poison_state, poison_caster)
	StatusEffectService.add_poison(poison_target, 4.0, 0.03)
	BattleSimShared._heal_unit(poison_target, 100)
	_expect(int(poison_target.hp) == 570 and is_equal_approx(float(poison_target.statuses.poison.antiheal_pct), 0.30),
		"undead2_all_healing", "healed=%d poison=%s" % [int(poison_target.hp) - 500, str(poison_target.statuses.poison)])
	DamageService.clear_stat_context()
	var other_source := _unit("human_king", "player", {}, Vector2(500, 300))
	var other_target := _unit("human_king", "enemy", {}, Vector2(500, 320))
	other_target.hp = 500
	other_target.max_hp = 1000
	var other_state := {"player": [other_source], "enemy": [other_target], "elapsed": 0.0,
		"visual_events": [], "unit_stats": {}, "kind": "pvp",
		"owner_syn_by_key": {"player_0": undead_syn, "enemy_0": {}}}
	DamageService.begin_stat_context(other_state, other_source)
	StatusEffectService.add_poison(other_target, 4.0, 0.03)
	BattleSimShared._heal_unit(other_target, 100)
	_expect(int(other_target.hp) == 570, "undead2_any_poison_source", "non-undead poison healed=%d" % [int(other_target.hp) - 500])
	DamageService.clear_stat_context()
	var undead7 := SynergyService.flags_from_counts({"god": 0, "dark": 0, "undead": 7, "human": 0})
	poison_caster.owner_syn = undead7
	poison_caster.hp = 500
	poison_caster.max_hp = 1000
	BattleSimTreasures._apply_undead_poison_heal(poison_caster, poison_state, true)
	_expect(int(poison_caster.hp) == 650, "undead7_self_max_hp", "500 + 15 percent of 1000 = %d" % int(poison_caster.hp))
	_expect(not undead7.has("undead_death_clone_threshold"), "clone_removed", str(undead7))
	print("DARK_UNDEAD_20260929_RESULT failed=%d" % failed)
	get_tree().quit(1 if failed > 0 else 0)
