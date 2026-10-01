extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const RacePick := preload("res://scripts/units/RacePick.gd")

var _h

func _ready() -> void:
	_h = Harness.new("crimson_integration")
	_check_catalog()
	_check_combat()
	_check_simulator_dispatch()
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


func _check_catalog() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var crimson: Array = units.filter(func(unit): return str(unit.get("race", "")) == "crimson")
	_h.expect(crimson.size() == 8, "eight_units", "Expected 8 Crimson units")
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
		_h.expect(str(visual.get("model", "")).is_empty() and str(visual.get("portrait", "")) == path,
			"fallback_%s" % str(unit.id), "Model-free fighter did not resolve its portrait fallback")
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
	CrimsonCombat.skill_dancer(dancer, [dancer, ally], {"ally_count": 2, "buff_duration": 3.0, "buff_pct": 0.2}, state)
	_h.expect(int(dancer.get("crimson_resonance_stacks", 0)) == 2, "dancer_two", "Dancer did not affect two distinct allies")

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
	for _i in 5:
		drummer_ally.get_or_add("crimson_drum_atk", []).append({"pct": 0.03})
		drummer_ally.get_or_add("crimson_drum_speed", []).append({"pct": 0.03})
	_h.expect(is_equal_approx(StatusEffectService.attack_multiplier(drummer_ally), 1.15), "drummer_attack_stacks", "Five 3% attack layers should total 15%")
	_h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(drummer_ally), 1.15), "drummer_speed_stacks", "Five 3% speed layers should total 15%")

	var icey := _fighter("Icey")
	icey.def.skill_id = "frost_status"
	victim = _fighter("victim", "enemy")
	victim.pos = Vector2(50, 0)
	state = _state([icey], [victim])
	DamageService.begin_stat_context(state, icey)
	CrimsonCombat.skill_icey(icey, [victim], {"damage_atk_pct": 1.7, "ice_duration": 3.0}, state)
	_h.expect(int(victim.hp) < 1000 and StatusEffectService.has_status(victim, "ice_affected"), "ice_skill", "Ice skill did not damage and apply status")
	DamageService.clear_stat_context()

	var lantern := _fighter("lattern")
	lantern.def.skill_id = "aoe_silence"
	victim = _fighter("victim", "enemy")
	victim.pos = Vector2(50, 0)
	var second := _fighter("second", "enemy")
	second.pos = Vector2(80, 0)
	state = _state([lantern], [victim, second])
	DamageService.begin_stat_context(state, lantern)
	CrimsonCombat.skill_lantern(lantern, [victim, second], {"damage_atk_pct": 1.3, "silence_duration": 2.5, "aoe_radius": 144.0}, state)
	_h.expect(StatusEffectService.has_status(victim, "silence") and StatusEffectService.has_status(second, "silence"), "lantern_aoe", "Lantern missed an enemy inside radius")
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
	_h.expect(int(guard.hp) == 560 and float(guard.skill_ready) == 8.0 and StatusEffectService.has_status(guard, "crimson_pulse"), "pulse", "Crimson 7 pulse failed")


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

	var icey := _fighter("Icey")
	icey.def = by_id.Icey
	icey.skill_ready = 0.0
	icey.range_px = 248.0
	target = _fighter("target", "enemy")
	target.pos = Vector2(50, 0)
	state = _state([icey], [target])
	BattleSimulator._tick_skills([icey], [target], state)
	_h.expect(float(icey.skill_ready) == 6.0 and StatusEffectService.has_status(target, "ice_affected"), "ice_dispatch", "Simulator active-skill dispatch skipped Icey")

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
