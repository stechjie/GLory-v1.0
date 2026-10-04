extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const RacePick := preload("res://scripts/units/RacePick.gd")
const OfficeTestScreenScript := preload("res://officetest/OfficeTestScreen.gd")

var _h

func _ready() -> void:
	_h = Harness.new("crimson_integration")
	_check_catalog()
	_check_combat()
	_check_runes()
	_check_lantern()
	_check_simulator_dispatch()
	_check_office_test_synergy()
	_h.finish(get_tree())


func _fighter(id: String, team: String = "player", hp: int = 1000) -> Dictionary:
	return {"uid": "%s_%s" % [team, id], "id": id, "team": team,
		"def": {"id": id, "race": "crimson"}, "alive": true, "hp": hp, "max_hp": hp,
		"atk": 100, "defense": 0, "attack_speed": 1.0, "shield": 0,
		"dodge": 0.0, "statuses": {}, "skill_ready": 10.0, "pos": Vector2.ZERO}


func _state(player: Array, enemy: Array = [], elapsed: float = 0.0, count: int = 7) -> Dictionary:
	var syn := SynergyService.flags_from_counts({"crimson": count})
	var state := {"player": player, "enemy": enemy, "elapsed": elapsed,
		"player_syn": syn, "enemy_syn": {}, "kind": "pvp", "visual_events": [],
		"unit_stats": {}, "log": []}
	DamageService.set_stat_state(state)
	return state


func _check_runes() -> void:
	_h.expect(bool(SynergyService.flags_from_counts({"crimson": 1}).get("crimson_rune", false)) and not bool(SynergyService.flags_from_counts({"crimson": 0}).get("crimson_rune", false)),
		"rune_base_tier", "Battle Runes must unlock with one Crimson unit")
	var caster := _fighter("rune_caster")
	var ally := _fighter("rune_ally")
	var enemy := _fighter("rune_enemy", "enemy")
	var state := _state([caster, ally], [enemy], 0.0, 1)
	CrimsonRuneService.begin_action(caster, state)
	DamageService.begin_stat_context(state, caster)
	StatusEffectService.add_status(ally, "speed_bonus", 3.0, {"pct": 0.20})
	StatusEffectService.add_status(enemy, "slow", 3.0, {"attack_speed_pct": 0.20})
	_h.expect(CrimsonRuneService.stack_count(caster) == 0, "rune_self_only", "Effects on other units must not grant runes at Crimson 1")
	StatusEffectService.add_status(caster, "speed_bonus", 3.0, {"pct": 0.20})
	StatusEffectService.add_status(caster, "damage_down", 3.0, {"pct": 0.20})
	_h.expect(CrimsonRuneService.stack_count(caster) == 1, "rune_one_action", "Two self statuses in one action must grant one rune")
	DamageService.clear_stat_context()
	CrimsonRuneService.end_action(caster)
	for _i in 8:
		CrimsonRuneService.begin_action(caster, state)
		CrimsonRuneService.note_self_effect(caster, state)
		CrimsonRuneService.end_action(caster)
	_h.expect(CrimsonRuneService.stack_count(caster) == 9 and not CrimsonRuneService.note_self_effect(caster, state),
		"rune_cap", "Battle Runes must stop at nine stacks")
	_h.expect(is_equal_approx(CrimsonRuneService.crit_bonus(caster), 0.30)
		and is_equal_approx(CrimsonRuneService.attack_speed_multiplier(caster), 1.60)
		and is_equal_approx(CrimsonRuneService.crit_damage_bonus(caster), 0.90),
		"rune_milestones", "Three, six, and nine runes must grant cumulative crit, speed, and crit damage")
	caster.def.crit = 0.05
	_h.expect(is_equal_approx(OfficeTestScreenScript.live_crit(caster), 0.35), "rune_crit_panel", "Live crit panel missed the rune bonus")
	var hit_target := _fighter("rune_hit_target", "enemy")
	caster = _fighter("rune_strike")
	caster.crimson_rune_stacks = 9
	caster.def.crit = 1.0
	caster.def.crit_dmg = 1.5
	state = _state([caster], [hit_target], 0.0, 1)
	DamageService.begin_stat_context(state, caster)
	BattleSimulator._perform_attack(caster, hit_target, state)
	DamageService.clear_stat_context()
	_h.expect(int(hit_target.hp) == 760, "rune_crit_damage", "Nine runes should make a 100 ATK critical hit deal 240 damage")
	var live_stats := {}
	var last_live := {}
	OfficeTestSim._capture_live_stats(state, 0, live_stats, last_live)
	var replay_view := OfficeTestScreenScript.patched_with_live_stats({"uid": caster.uid, "def": caster.def}, live_stats, 0)
	_h.expect(CrimsonRuneService.stack_count(replay_view) == 9 and is_equal_approx(OfficeTestScreenScript.live_crit(replay_view), 1.0),
		"rune_office_replay", "Offline replay must preserve rune stacks in the live stat panel")

	caster = _fighter("rune_resonance")
	enemy = _fighter("rune_resonance_target", "enemy")
	state = _state([caster], [enemy], 0.0, 4)
	CrimsonRuneService.begin_action(caster, state)
	DamageService.begin_stat_context(state, caster)
	CrimsonCombat.apply_status(caster, caster, "crimson_attack", 3.0, {"pct": 0.20}, state)
	CrimsonCombat.apply_status(caster, enemy, "ice_vulnerable", 3.0, {"pct": 0.20}, state)
	_h.expect(CrimsonRuneService.stack_count(caster) == 1, "rune_resonance_dedup", "A self buff plus Resonance in one action must count once")
	DamageService.clear_stat_context()
	CrimsonRuneService.end_action(caster)
	CrimsonRuneService.begin_action(caster, state)
	DamageService.begin_stat_context(state, caster)
	CrimsonCombat.apply_status(caster, enemy, "ice_vulnerable", 3.0, {"pct": 0.20}, state)
	_h.expect(CrimsonRuneService.stack_count(caster) == 2, "rune_resonance_self_buff", "Crimson 4 Resonance must grant a rune on a later action")
	DamageService.clear_stat_context()
	CrimsonRuneService.end_action(caster)

	caster = _fighter("rune_pulse")
	state = _state([caster], [], 2.0, 7)
	CrimsonCombat.pulse(state)
	_h.expect(CrimsonRuneService.stack_count(caster) == 1, "rune_red_tide", "Crimson 7 Red Tide must grant one rune")


func _check_lantern() -> void:
	var unit_def: Dictionary = {}
	for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
		if str(unit.get("id", "")) == "lattern":
			unit_def = unit
			break
	_h.expect(not unit_def.is_empty() and bool(unit_def.get("skill_global", false))
		and not unit_def.has("damage_atk_pct")
		and is_equal_approx(float(unit_def.get("silence_duration", 0.0)), 3.0)
		and is_equal_approx(float(unit_def.get("skill_cd", 0.0)), 10.0),
		"lantern_base_data", "Lantern base skill data is wrong")
	if unit_def.is_empty():
		return
	var four_def := UnitFactory.apply_star_stats(unit_def, 4)
	_h.expect(not four_def.has("damage_atk_pct")
		and is_equal_approx(float(four_def.get("silence_duration", 0.0)), 4.0)
		and is_equal_approx(float(four_def.get("skill_cd", 0.0)), 9.0),
		"lantern_star4_data", "Lantern fourth-star skill data is wrong")

	var old_team_mode := GameState.team_mode
	GameState.team_mode = true
	var both_player := _fighter("lattern")
	both_player.def = unit_def.duplicate(true)
	both_player.lane = 0
	both_player.skill_ready = 0.0
	var both_enemy := _fighter("lattern", "enemy")
	both_enemy.def = unit_def.duplicate(true)
	both_enemy.lane = 0
	both_enemy.skill_ready = 0.0
	var both_state := _state([both_player], [both_enemy], 0.0, 0)
	BattleSimulator._tick_opening_lanterns(both_state)
	_h.expect(StatusEffectService.has_status(both_player, "silence")
		and StatusEffectService.has_status(both_enemy, "silence")
		and int(both_player.hp) == 1000 and int(both_enemy.hp) == 1000,
		"lantern_both_sides_silenced", "Both sides must be silenced without damage by simultaneous opening casts")
	var player_lantern := _fighter("lattern")
	player_lantern.def = unit_def.duplicate(true)
	player_lantern.lane = 0
	player_lantern.skill_ready = 0.0
	var player_ally := _fighter("player_ally")
	player_ally.lane = 0
	var enemy_lantern := _fighter("lattern", "enemy")
	enemy_lantern.def = unit_def.duplicate(true)
	enemy_lantern.lane = 0
	enemy_lantern.skill_ready = 0.0
	var enemy_ally := _fighter("enemy_ally", "enemy")
	enemy_ally.lane = 0
	var next_lane := _fighter("next_lane", "enemy")
	next_lane.lane = 1
	next_lane.pos = Vector2(2000, 0)
	var state := _state([player_lantern, player_ally], [enemy_lantern, enemy_ally, next_lane], 0.0, 0)
	BattleSimulator._tick_opening_lanterns(state)
	_h.expect(bool(enemy_lantern.alive) and is_equal_approx(float(enemy_lantern.skill_ready), 10.0)
		and StatusEffectService.has_status(enemy_lantern, "silence")
		and StatusEffectService.has_status(player_lantern, "silence")
		and StatusEffectService.has_status(player_ally, "silence"),
		"lantern_simultaneous_opening", "Both opening casts must resolve despite the opposing silence")
	_h.expect(int(player_ally.hp) == 1000 and StatusEffectService.has_status(enemy_ally, "silence")
		and not StatusEffectService.has_status(next_lane, "silence")
		and int(next_lane.hp) == 1000,
		"lantern_own_lane_first", "The opening cast must hit every enemy in its lane and cannot spill into another lane")
	_h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(player_ally), 0.7)
		and is_equal_approx(float(player_ally.statuses.silence.remaining), 3.0),
		"lantern_silence_slow", "Lantern silence must reduce attack speed by 30% for 3.0 seconds")
	StatusEffectService.add_status(player_ally, "silence", 5.0, {})
	StatusEffectService.tick(player_ally, 3.0)
	_h.expect(StatusEffectService.has_status(player_ally, "silence")
		and is_equal_approx(StatusEffectService.attack_speed_multiplier(player_ally), 1.0),
		"lantern_slow_independent", "A different silence may extend control but not Lantern's attack-speed penalty")
	BattleSimulator._tick_opening_lanterns(state)
	_h.expect(is_equal_approx(float(player_lantern.skill_ready), 10.0),
		"lantern_opening_once", "Opening Lantern cast must not repeat")

	StatusEffectService.tick(player_lantern, 3.0)
	enemy_lantern.alive = false
	enemy_ally.alive = false
	state.elapsed = 10.0
	BattleSimulator._tick_skills([player_lantern], state.enemy, state)
	_h.expect(int(next_lane.hp) == 1000 and StatusEffectService.has_status(next_lane, "silence")
		and is_equal_approx(float(player_lantern.skill_ready), 20.0),
		"lantern_next_cast_cross_lane", "The next cast must reach another lane after the caster's lane is cleared")

	var four := _fighter("lattern_four")
	four.def = four_def
	four.lane = 0
	four.skill_ready = 0.0
	var four_target := _fighter("four_target", "enemy")
	four_target.lane = 0
	state = _state([four], [four_target], 0.0, 0)
	BattleSimulator._tick_opening_lanterns(state)
	_h.expect(int(four_target.hp) == 1000 and is_equal_approx(float(four_target.statuses.silence.remaining), 4.0)
		and is_equal_approx(float(four.skill_ready), 9.0),
		"lantern_star4_opening", "Fourth-star opening must deal no damage and use the 4.0-second silence and 9.0-second cooldown")
	var boss := _fighter("boss_lantern_target", "enemy")
	boss.lane = 0
	state = _state([four], [boss], 0.0, 0)
	DamageService.begin_stat_context(state, four)
	CrimsonCombat.skill_lantern(four, [boss], {"silence_duration": 4.0}, state)
	DamageService.clear_stat_context()
	_h.expect(is_equal_approx(float(boss.statuses.silence.remaining), 2.0)
		and is_equal_approx(StatusEffectService.attack_speed_multiplier(boss), 0.7),
		"lantern_boss_duration", "Boss control duration must be halved while the Lantern slow remains 30%")
	var immune := _fighter("immune", "enemy")
	immune.lane = 0
	StatusEffectService.add_status(immune, "control_immune", 6.0, {})
	state = _state([four], [immune], 0.0, 0)
	DamageService.begin_stat_context(state, four)
	CrimsonCombat.skill_lantern(four, [immune], {"silence_duration": 4.0}, state)
	DamageService.clear_stat_context()
	_h.expect(int(immune.hp) == 1000 and not StatusEffectService.has_status(immune, "silence")
		and is_equal_approx(StatusEffectService.attack_speed_multiplier(immune), 1.0),
		"lantern_control_immune", "Control immunity must block silence and its slow with no damage")
	GameState.team_mode = old_team_mode


func _check_catalog() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var crimson: Array = units.filter(func(unit): return str(unit.get("race", "")) == "crimson")
	_h.expect(crimson.size() == 8, "eight_units", "Expected 8 Crimson units")
	var by_id := {}
	for unit: Dictionary in crimson:
		by_id[str(unit.id)] = unit
	_h.expect(is_equal_approx(float(by_id.crimson.block_chance), 0.20) and is_equal_approx(float(UnitFactory.apply_star_stats(by_id.crimson, 4).block_chance), 0.30), "guard_balance", "Guard block chance must be 20% / 30%")
	_h.expect(is_equal_approx(float(by_id.drumer.stack_pct), 0.05) and is_equal_approx(float(UnitFactory.apply_star_stats(by_id.drumer, 4).stack_pct), 0.08) and int(by_id.drumer.max_stacks) == 15 and is_equal_approx(float(by_id.drumer.heal_pct), 0.05), "drummer_balance", "War Drum values are not 5% / 8%, 15 stacks, 5% heal")
	_h.expect(is_equal_approx(float(UnitFactory.apply_star_stats(by_id.Icey, 4).damage_atk_pct), 3.0), "icey_balance", "Fourth-star Icey must deal 300% ATK")
	_h.expect(RacePick.all_races().size() == 5 and RacePick.required_count() == 4, "four_of_five", "Exactly four races must be selected")
	var selected := ["god", "dark", "human", "crimson"]
	_h.expect(RacePick.sanitize(selected).size() == 4, "valid_pick", "Crimson selection rejected")
	var pool := RacePick.shop_pool(units, selected)
	_h.expect(pool.size() == 32 and pool.all(func(unit): return str(unit.get("race", "")) != "undead"), "filtered_pool", "Unselected race leaked into shop")
	var tiers := {1: 0, 2: 0, 3: 0}
	for unit: Dictionary in crimson:
		tiers[int(unit.get("tier", 0))] += 1
		var star4 := UnitFactory.apply_star_stats(unit, 4)
		_h.expect(not star4.has("star4") and int(star4.get("star", 0)) == 4, "star4_%s" % str(unit.id), "Fourth-star definition did not resolve")
		_h.expect(not UnitDetailFormat.format_skill_detail(star4).contains("暂未") and not UnitDetailFormat.format_skill_detail(star4).contains("not yet"),
			"skill_text_%s" % str(unit.id), "Crimson skill text missing")
		var path := "res://assets/ui/unit_portraits/%s.png" % str(unit.id)
		var portrait := load(path) as Texture2D
		_h.expect(portrait != null and portrait.get_size() == Vector2(330, 330), "portrait_%s" % str(unit.id), "Portrait is missing or not 330x330")
		var visual := UnitVisualResolver.resolve_definition(str(unit.id), unit)
		var model_path := "res://assets/models/units/crimson_race/%s.glb" % str(unit.id)
		var model_scene := load(model_path) as PackedScene
		_h.expect(str(visual.get("model", "")) == model_path and model_scene != null,
			"model_%s" % str(unit.id), "Crimson model did not resolve or import")
		_h.expect(str(visual.get("portrait", "")) == path,
			"portrait_fallback_%s" % str(unit.id), "Crimson portrait fallback is unavailable")
		if model_scene != null:
			var model_instance := model_scene.instantiate()
			var animation_players := model_instance.find_children("*", "AnimationPlayer", true, false)
			var has_actions := false
			for player: AnimationPlayer in animation_players:
				if player.has_animation("idle") and player.has_animation("attack") and player.has_animation("run"):
					has_actions = true
					break
			_h.expect(has_actions, "animations_%s" % str(unit.id), "Crimson model is missing idle, attack or run")
			model_instance.free()
	_h.expect(tiers == {1: 2, 2: 4, 3: 2}, "tiers", "Expected 2 / 4 / 2 tier split")
	_h.expect(load("res://assets/ui/race_logos/crimson.png") is Texture2D, "logo", "Crimson logo is missing")
	_h.expect(bool(SynergyService.flags_from_counts({"crimson": 2}).get("crimson_duration", false)), "synergy_2", "Crimson 2 inactive")
	_h.expect(bool(SynergyService.flags_from_counts({"crimson": 4}).get("crimson_resonance", false)), "synergy_4", "Crimson 4 inactive")
	_h.expect(bool(SynergyService.flags_from_counts({"crimson": 7}).get("crimson_pulse", false)), "synergy_7", "Crimson 7 inactive")
	var board: Array = [{"def": {"race": "crimson"}}, {"def": {"race": "crimson"}}]
	_h.expect(bool(NetProtocol.rebuild_syn_from_board(board).get("crimson_duration", false)), "server_syn", "Server did not count Crimson pieces")


func _check_combat() -> void:
	var guard := _fighter("crimson")
	guard.def.skill_id = "block_guard"
	guard.def.block_chance = 1.0
	var source := _fighter("attacker", "enemy")
	var state := _state([guard], [source])
	DamageService.begin_stat_context(state, source)
	DamageService.set_hit_context("basic")
	_h.expect(DamageService.apply_damage(guard, 100) == 0 and int(guard.hp) == 1000, "guard_block", "Guard did not block direct hit")
	DamageService.clear_hit_context()
	DamageService.clear_stat_context()

	var dancer := _fighter("dancer")
	var ally := _fighter("ally")
	state = _state([dancer, ally])
	CrimsonCombat.skill_dancer(dancer, [dancer, ally], {"ally_count": 1, "buff_duration": 3.0, "buff_pct": 0.2}, state)
	_h.expect(str(dancer.get("vfx_skill_target_uid", "")) == str(ally.uid), "dancer_ally_priority", "Dancer chose herself while a teammate was alive")
	CrimsonCombat.skill_dancer(dancer, [dancer, ally], {"ally_count": 2, "buff_duration": 3.0, "buff_pct": 0.2}, state)
	_h.expect(int(dancer.get("crimson_resonance_stacks", 0)) == 3 and str(dancer.get("vfx_skill_target_uid", "")) == str(dancer.uid), "dancer_two", "Dancer did not choose teammate before self fallback")

	var breaker := _fighter("armbreaker")
	breaker.def.skill_id = "stacking_def_break"
	breaker.def.break_chance = 1.0
	var victim := _fighter("victim", "enemy")
	state = _state([breaker], [victim])
	CrimsonCombat.passive_attack(breaker, victim, state)
	_h.expect(int(victim.get("crimson_def_break", 0)) == 2, "armor_break", "Permanent defense break failed")

	var hunter := _fighter("hunter")
	hunter.def.skill_id = "current_hp_strike"
	hunter.def.current_hp_pct = 0.10
	hunter.crimson_target_hp_before = 1000
	victim = _fighter("victim", "enemy")
	state = _state([hunter], [victim])
	DamageService.begin_stat_context(state, hunter)
	CrimsonCombat.passive_attack(hunter, victim, state)
	_h.expect(int(victim.hp) == 900, "hunter_current_hp", "Hunter rider should take 10% of pre-hit HP")
	DamageService.clear_stat_context()
	victim = _fighter("armored_victim", "enemy")
	victim.defense = 100
	state = _state([hunter], [victim])
	DamageService.begin_stat_context(state, hunter)
	CrimsonCombat.passive_attack(hunter, victim, state)
	_h.expect(int(victim.hp) == 950, "hunter_defense", "Hunter's extra damage should respect target defense")
	DamageService.clear_stat_context()

	var drummer_ally := _fighter("drummer_ally")
	for _i in 15:
		drummer_ally.get_or_add("crimson_drum_atk", []).append({"pct": 0.05})
		drummer_ally.get_or_add("crimson_drum_speed", []).append({"pct": 0.05})
	_h.expect(is_equal_approx(StatusEffectService.attack_multiplier(drummer_ally), 1.75), "drummer_attack_stacks", "Fifteen 5% attack layers should total 75%")
	_h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(drummer_ally), 1.75), "drummer_speed_stacks", "Fifteen 5% speed layers should total 75%")
	var drummer_four := _fighter("drummer_four")
	for _i in 15:
		drummer_four.get_or_add("crimson_drum_atk", []).append({"pct": 0.08})
	_h.expect(is_equal_approx(StatusEffectService.attack_multiplier(drummer_four), 2.20), "drummer_star4_stacks", "Fifteen 8% attack layers should total 120%")
	drummer_four.crimson_resonance_stacks = 2
	_h.expect(is_equal_approx(StatusEffectService.attack_multiplier(drummer_four), 2.42), "resonance_attack", "Two 5% Resonance layers should multiply attack by 1.10")

	var icey := _fighter("Icey")
	icey.def.skill_id = "frost_status"
	victim = _fighter("victim", "enemy")
	victim.pos = Vector2(50, 0)
	var ice_near := _fighter("ice_near", "enemy")
	ice_near.pos = Vector2(100, 0)
	var ice_boss := _fighter("boss_ice", "enemy")
	ice_boss.def.is_boss = true
	ice_boss.pos = Vector2(120, 0)
	var ice_far := _fighter("ice_far", "enemy")
	ice_far.pos = Vector2(200, 0)
	state = _state([icey], [victim, ice_near, ice_boss, ice_far], 0.0, 0)
	DamageService.begin_stat_context(state, icey)
	CrimsonCombat.skill_icey(icey, [victim, ice_near, ice_boss, ice_far], {"damage_atk_pct": 1.7, "ice_duration": 3.0, "ice_vulnerable_pct": 0.25, "aoe_radius": 144.0}, state)
	_h.expect(int(victim.hp) == 830 and int(ice_near.hp) == 830 and int(ice_boss.hp) < 1000, "ice_aoe_damage", "Ice skill did not damage every enemy inside two cells")
	_h.expect(str(icey.get("vfx_skill_target_uid", "")) == str(victim.uid), "ice_aoe_center", "Ice skill lost its primary target for battle focus")
	_h.expect(int(ice_far.hp) == 1000 and not StatusEffectService.has_status(ice_far, "ice_vulnerable"), "ice_aoe_boundary", "Ice skill hit an enemy outside two cells")
	_h.expect(is_equal_approx(float(victim.statuses.ice_vulnerable.pct), 0.25) and is_equal_approx(float(ice_near.statuses.ice_vulnerable.pct), 0.25), "ice_aoe_vulnerability", "Ice skill missed the 25% vulnerability")
	_h.expect(is_equal_approx(float(ice_boss.statuses.ice_vulnerable.pct), 0.125), "ice_boss_vulnerability", "Boss vulnerability should be 12.5%")
	_h.expect(is_equal_approx(float(victim.statuses.ice_vulnerable.remaining), 3.0), "ice_duration", "Normal Ice Vulnerable duration should be 3 seconds")
	var hp_before_vulnerability := int(victim.hp)
	DamageService.apply_damage(victim, 100, false)
	_h.expect(hp_before_vulnerability - int(victim.hp) == 125, "ice_damage_taken", "Ice Vulnerable did not increase subsequent damage by 25%")
	DamageService.clear_stat_context()
	var icey_four := _fighter("Icey_four")
	var ice_four_target := _fighter("ice_four_target", "enemy")
	ice_four_target.pos = Vector2(50, 0)
	state = _state([icey_four], [ice_four_target], 0.0, 0)
	DamageService.begin_stat_context(state, icey_four)
	CrimsonCombat.skill_icey(icey_four, [ice_four_target], {"damage_atk_pct": 3.0, "ice_duration": 5.0, "ice_vulnerable_pct": 0.25, "aoe_radius": 144.0}, state)
	_h.expect(int(ice_four_target.hp) == 700 and is_equal_approx(float(ice_four_target.statuses.ice_vulnerable.remaining), 5.0), "ice_star4", "Fourth-star Icey damage or duration is wrong")
	DamageService.clear_stat_context()

	var lantern := _fighter("lattern")
	lantern.def.skill_id = "aoe_silence"
	victim = _fighter("victim", "enemy")
	victim.pos = Vector2(50, 0)
	var second := _fighter("second", "enemy")
	second.pos = Vector2(80, 0)
	state = _state([lantern], [victim, second])
	DamageService.begin_stat_context(state, lantern)
	CrimsonCombat.skill_lantern(lantern, CrimsonCombat.lantern_targets(lantern, [victim, second]), {"silence_duration": 3.0}, state)
	_h.expect(StatusEffectService.has_status(victim, "silence") and StatusEffectService.has_status(second, "silence")
		and int(victim.hp) == 1000 and int(second.hp) == 1000,
		"lantern_aoe", "Lantern must silence every targetable enemy without dealing damage")
	DamageService.clear_stat_context()

	var piercer := _fighter("skypierce")
	piercer.pos = Vector2.ZERO
	var primary := _fighter("primary", "enemy")
	primary.pos = Vector2(50, 0)
	second = _fighter("second", "enemy")
	second.pos = Vector2(100, 10)
	_h.expect(CrimsonCombat.pierce_targets(piercer, primary, [primary, second]).size() == 1, "pierce_line", "Line target not found")

	guard = _fighter("crimson")
	guard.hp = 500
	guard.skill_ready = 9.0
	state = _state([guard], [], 2.0)
	CrimsonCombat.pulse(state)
	_h.expect(int(guard.hp) == 560 and float(guard.skill_ready) == 8.0 and int(guard.get("crimson_pulse_stacks", 0)) == 1, "pulse", "Crimson 7 pulse failed")
	_h.expect(is_equal_approx(StatusEffectService.attack_multiplier(guard), 1.10) and is_equal_approx(StatusEffectService.attack_speed_multiplier(guard), 1.10), "pulse_first_stack", "First Crimson 7 stack did not raise attack and speed")
	CrimsonCombat.tick_fighter(guard, 6.0)
	_h.expect(int(guard.get("crimson_pulse_stacks", 0)) == 1, "pulse_permanent", "Crimson 7 stack expired before battle end")
	for pulse_time in [7.0, 12.0, 17.0, 22.0, 27.0]:
		state.elapsed = pulse_time
		CrimsonCombat.pulse(state)
	_h.expect(int(guard.get("crimson_pulse_stacks", 0)) == 5, "pulse_cap", "Crimson 7 exceeded five permanent stacks")
	_h.expect(CrimsonRuneService.stack_count(guard) == 6, "pulse_rune_count", "Each Red Tide action must add one Battle Rune")
	_h.expect(is_equal_approx(StatusEffectService.attack_multiplier(guard), 1.50) and is_equal_approx(StatusEffectService.attack_speed_multiplier(guard), 2.40), "pulse_max_stats", "Five Red Tide stacks and six Battle Runes must combine correctly")
	_h.expect(is_equal_approx(OfficeTestScreenScript.live_crit(guard), 0.80), "pulse_crit", "Red Tide and Battle Runes must combine in the live crit value")


func _check_simulator_dispatch() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var by_id := {}
	for unit: Dictionary in units:
		by_id[str(unit.id)] = unit
	var hunter := _fighter("hunter")
	hunter.def = by_id.hunter
	hunter.skill_ready = 0.0
	var target := _fighter("target", "enemy")
	target.def.element = "land"
	target.pos = Vector2(50, 0)
	var state := _state([hunter], [target])
	DamageService.begin_stat_context(state, hunter)
	BattleSimulator._perform_attack(hunter, target, state)
	DamageService.clear_stat_context()
	_h.expect(int(target.hp) <= 850, "hunter_dispatch", "Simulator attack skipped Hunter's current-HP rider")
	var pulse_probe := _fighter("pulse_probe")
	pulse_probe.def.skill_id = "none"
	pulse_probe.def.crit = 0.50
	pulse_probe.def.crit_dmg = 2.0
	pulse_probe.def.element = "land"
	pulse_probe.crimson_pulse_stacks = 5
	pulse_probe.range_px = 104.0
	pulse_probe.next_attack = 0.0
	pulse_probe.move_speed_px = 170.0
	target = _fighter("pulse_target", "enemy")
	target.def.element = "land"
	target.pos = Vector2(50, 0)
	state = _state([pulse_probe], [target], 0.0)
	BattleSimulator._step_team([pulse_probe], [target], 0.0, state)
	_h.expect(int(target.hp) == 700, "pulse_crit_damage", "Five Crimson 7 stacks must affect actual hit damage and crit chance")
	_h.expect(is_equal_approx(float(pulse_probe.next_attack), 2.0 / 3.0), "pulse_attack_interval", "Five Crimson 7 stacks must shorten the actual attack interval")

	var icey := _fighter("Icey")
	icey.def = by_id.Icey
	icey.skill_ready = 0.0
	icey.range_px = 248.0
	target = _fighter("target", "enemy")
	target.pos = Vector2(50, 0)
	var ice_dispatch_near := _fighter("ice_dispatch_near", "enemy")
	ice_dispatch_near.pos = Vector2(80, 0)
	state = _state([icey], [target, ice_dispatch_near])
	BattleSimulator._tick_skills([icey], [target, ice_dispatch_near], state)
	_h.expect(float(icey.skill_ready) == 6.0 and StatusEffectService.has_status(target, "ice_vulnerable") and StatusEffectService.has_status(ice_dispatch_near, "ice_vulnerable"), "ice_dispatch", "Simulator active-skill dispatch skipped Icey area vulnerability")

	var piercer := _fighter("skypierce")
	piercer.def = by_id.skypierce
	piercer.range_px = 104.0
	piercer.next_attack = 0.0
	piercer.move_speed_px = 170.0
	var first := _fighter("first", "enemy")
	first.pos = Vector2(50, 0)
	var second := _fighter("second", "enemy")
	second.pos = Vector2(90, 0)
	state = _state([piercer], [first, second])
	BattleSimulator._step_team([piercer], [first, second], 0.0, state)
	_h.expect(int(first.hp) < 1000 and int(second.hp) < 1000, "pierce_dispatch", "Simulator attack did not pierce second target")


func _check_office_test_synergy() -> void:
	var ids := ["crimson", "dancer", "drumer", "hunter", "armbreaker", "Icey", "skypierce"]
	var placements: Array = []
	for i in ids.size():
		placements.append({"slot": 0, "cell": i, "kind": "piece", "unit_id": ids[i], "star": 1})
	var two: Dictionary = OfficeTestSim._syn_for_slot(placements.slice(0, 2))
	var four: Dictionary = OfficeTestSim._syn_for_slot(placements.slice(0, 4))
	var seven: Dictionary = OfficeTestSim._syn_for_slot(placements)
	_h.expect(bool(two.get("crimson_duration", false)) and not bool(two.get("crimson_resonance", false)), "office_crimson_2", "Offline self-test did not activate Crimson 2")
	_h.expect(bool(four.get("crimson_resonance", false)) and not bool(four.get("crimson_pulse", false)), "office_crimson_4", "Offline self-test did not activate Crimson 4")
	_h.expect(bool(seven.get("crimson_pulse", false)), "office_crimson_7", "Offline self-test did not activate Crimson 7")
	placements.append({"slot": 3, "cell": 0, "kind": "piece", "unit_id": "god_priest", "star": 1})
	var state: Dictionary = OfficeTestSim.build_test_state({"placements": placements})
	_h.expect(state.get("player", []).size() == 7 and bool(state.player[0].get("owner_syn", {}).get("crimson_pulse", false)), "office_crimson_owner", "Offline battle state did not pass Crimson 7 to its fighters")
	state.elapsed = 2.0
	CrimsonCombat.pulse(state)
	_h.expect(int(state.player[0].get("crimson_pulse_stacks", 0)) == 1, "office_crimson_pulse", "Crimson 7 did not trigger from an actual offline battle state")
