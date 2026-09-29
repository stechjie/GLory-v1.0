extends Node

const Harness := preload("res://tools/CheckHarness.gd")

var _h


func _ready() -> void:
	_h = Harness.new("battle_frenzy")
	_probe_stage_table()
	_probe_damage()
	_probe_healing_and_shields()
	_probe_sudden_death()
	_h.finish(get_tree())


func _fighter(uid: String, team: String = "player") -> Dictionary:
	return {
		"uid": uid, "id": uid, "name": uid, "team": team,
		"alive": true, "hp": 1000, "max_hp": 1000, "shield": 0,
		"defense": 0, "dodge": 0.0, "statuses": {}, "def": {},
	}


func _state(elapsed: float, player: Array = [], enemy: Array = []) -> Dictionary:
	var state := {
		"kind": "pvp", "elapsed": elapsed, "player": player, "enemy": enemy,
		"next_sudden_death_tick": BattleFrenzyService.SUDDEN_DEATH_SEC,
		"finished": false, "log": [], "visual_events": [], "unit_stats": {},
	}
	DamageService.set_stat_state(state)
	return state


func _probe_stage_table() -> void:
	_h.expect(BattleFrenzyService.stage_for_elapsed(34.9) == 0, "stage_before_35", "34.9s must be normal")
	_h.expect(BattleFrenzyService.stage_for_elapsed(35.0) == 1, "stage_35", "35s must be Frenzy I")
	_h.expect(BattleFrenzyService.stage_for_elapsed(45.0) == 2, "stage_45", "45s must be Frenzy II")
	_h.expect(BattleFrenzyService.stage_for_elapsed(55.0) == 3, "stage_55", "55s must be Frenzy III")
	_h.expect(BattleFrenzyService.stage_for_elapsed(65.0) == 4, "stage_65", "65s must be sudden death")


func _probe_damage() -> void:
	for entry in [[0.0, 100], [35.0, 120], [45.0, 150], [55.0, 200], [65.0, 200]]:
		var source := _fighter("source")
		var target := _fighter("target", "enemy")
		var state := _state(float(entry[0]), [source], [target])
		DamageService.begin_stat_context(state, source)
		var dealt := DamageService.apply_damage(target, 100, true, true)
		DamageService.clear_stat_context()
		_h.expect(dealt == int(entry[1]), "damage_%d" % int(entry[0]),
			"%.0fs dealt %d, expected %d" % [float(entry[0]), dealt, int(entry[1])])


func _probe_healing_and_shields() -> void:
	for entry in [[35.0, 80, 100], [45.0, 50, 70], [55.0, 20, 40]]:
		var unit := _fighter("sustain")
		unit.hp = 500
		_state(float(entry[0]), [unit], [])
		BattleSimShared._heal_unit(unit, 100)
		_h.expect(int(unit.hp) == 500 + int(entry[1]), "heal_%d" % int(entry[0]),
			"%.0fs healed to %d" % [float(entry[0]), int(unit.hp)])
		BattleSimShared._grant_shield(unit, 100)
		_h.expect(int(unit.shield) == int(entry[2]), "shield_%d" % int(entry[0]),
			"%.0fs shield %d" % [float(entry[0]), int(unit.shield)])
	var reduced := _fighter("reduced")
	reduced.hp = 500
	reduced.statuses = {"heal_reduction": {"remaining": 5.0, "pct": 0.50}}
	_state(45.0, [reduced], [])
	BattleSimShared._heal_unit(reduced, 100)
	_h.expect(int(reduced.hp) == 525, "heal_multiplicative", "50% global and 50% debuff should heal 25")


func _probe_sudden_death() -> void:
	var player := _fighter("player")
	var enemy := _fighter("enemy", "enemy")
	player.shield = 20
	player.statuses = {"invulnerable": {"remaining": 5.0}}
	var state := _state(65.0, [player], [enemy])
	BattleSimulator._process_frenzy(state, [player], [enemy])
	_h.expect(int(player.shield) == 0 and int(player.hp) == 970, "sudden_shield_first",
		"5%% max HP must consume 20 shield then 30 HP, got shield=%d hp=%d" % [int(player.shield), int(player.hp)])
	_h.expect(int(enemy.hp) == 950, "sudden_both_sides", "enemy must take the same simultaneous tick")
	_h.expect(is_equal_approx(float(state.next_sudden_death_tick), 66.0), "sudden_interval", "next tick must be 66s")

