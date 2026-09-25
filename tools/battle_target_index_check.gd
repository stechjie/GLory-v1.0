extends Node

const Harness = preload("res://tools/CheckHarness.gd")
const Sim = preload("res://scripts/battle/BattleSimShared.gd")
var h = Harness.new("battle_target_index")

func fighter(uid: String, lane: int, pos: Vector2) -> Dictionary:
	return {"uid": uid, "team": "enemy", "lane": lane, "pos": pos,
		"hp": 100, "max_hp": 100, "alive": true, "def": {}}

func compare(attacker: Dictionary, opponents: Array, index: Dictionary, label: String) -> void:
	var original := attacker.duplicate(true)
	var indexed := attacker.duplicate(true)
	var expected: Dictionary = Sim._select_target(original, opponents)
	var actual: Dictionary = Sim._select_attack_target(indexed, opponents, index)
	h.expect(is_same(expected, actual) or (expected.is_empty() and actual.is_empty()),
		"target_changed", label)
	h.expect(original.get("locked_target_uid", "") == indexed.get("locked_target_uid", ""),
		"lock_changed", label)

func _ready() -> void:
	NetworkService.set_process(false)
	var original_mode := GameState.team_mode
	GameState.team_mode = true
	var a := fighter("attacker", 0, Vector2.ZERO)
	a.team = "player"
	var first := fighter("first", 0, Vector2(20, 0))
	var second := fighter("second", 0, Vector2(-20, 0))
	first.taunt_active = true
	second.taunt_active = true
	var opponents := [first, second, fighter("other_lane", 1, Vector2(1, 0))]
	var index := Sim._attack_target_index(opponents)
	a.locked_target_uid = "other_lane"
	compare(a, opponents, index, "equal-distance taunt retains original array order")
	first.alive = false
	compare(a, opponents, index, "dead taunter skipped without rebuilding")
	first.alive = true
	first.pos = Vector2(500, 0)
	compare(a, opponents, index, "taunt position and radius are read live")
	first.taunt_active = false
	second.taunt_active = false
	a.locked_target_uid = "first"
	first.hp = 0
	compare(a, opponents, index, "zero-HP lock uses original fallback")
	first.alive = false
	second.alive = false
	compare(a, opponents, index, "last own-lane death opens other lanes")
	first.hp = 100
	first.alive = true
	compare(a, opponents, index, "revival closes other lanes immediately")
	# Duplicate IDs preserve the original first-match behavior, even if dead.
	opponents = [fighter("duplicate", 1, Vector2(10,0)), fighter("duplicate", 1, Vector2(30,0))]
	opponents[0].alive = false
	a.locked_target_uid = "duplicate"
	compare(a, opponents, Sim._attack_target_index(opponents), "first duplicate ID is dead")
	# Skills can change membership between passes; the next pass must rebuild.
	opponents.remove_at(0)
	compare(a, opponents, Sim._attack_target_index(opponents), "conversion between attack passes")
	var rng := RandomNumberGenerator.new()
	rng.seed = 260926
	for sample in 300:
		opponents = []
		GameState.team_mode = sample % 2 == 0
		a.lane = rng.randi_range(-1, 2)
		a.is_formation_ally = sample % 7 == 0
		a.def = {"skill_id": "death_hunt" if sample % 3 == 0 else ""}
		for i in rng.randi_range(0, 50):
			var f := fighter("unit_%d" % i, rng.randi_range(0,2), Vector2(rng.randf_range(-500,500),rng.randf_range(-300,300)))
			f.taunt_active = i % 9 == 0
			f.taunt_radius = rng.randf_range(1,400)
			opponents.append(f)
		index = Sim._attack_target_index(opponents)
		for step in 8:
			for f in opponents:
				f.alive = rng.randf() > 0.25
				f.hp = rng.randi_range(0,100)
				f.pos += Vector2(rng.randf_range(-10,10),rng.randf_range(-10,10))
			a.locked_target_uid = "unit_%d" % rng.randi_range(0,50)
			compare(a, opponents, index, "random sample=%d step=%d" % [sample, step])
	GameState.team_mode = original_mode
	h.finish(get_tree())
