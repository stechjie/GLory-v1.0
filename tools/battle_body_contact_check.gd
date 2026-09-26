extends Node
const H = preload("res://tools/CheckHarness.gd")
const Sim = preload("res://scripts/battle/BattleSimulator.gd")
var h
func fighter(uid: String, pos: Vector2, cells := 1) -> Dictionary:
	return {"uid": uid, "pos": pos, "alive": true, "hp": 100, "footprint_cells": cells}
func penetration(units: Array) -> float:
	var worst := 0.0
	for i in units.size():
		for j in range(i + 1, units.size()):
			worst = maxf(worst, Sim.body_radius(units[i]) + Sim.body_radius(units[j]) - units[i].pos.distance_to(units[j].pos))
	return worst
func _ready() -> void:
	h = H.new("battle_body_contact")
	var allies: Array = DataRegistry.get_table("formation_allies").get("allies", [])
	for definition in allies:
		var cells := int(definition.get("footprint_cells", 1))
		h.expect(cells >= 3, "formation_ally_body", "Large formation allies need an explicit simulation footprint")
		var giant := Sim._fighter_from_def(definition, 0, "player", 0, 26, 1, false, true)
		var small := fighter("small", Vector2(500,260))
		h.expect(Sim.body_radius(giant) >= 45.0, "formation_radius", "Formation body must not fall back to a normal 15px radius")
		h.expect(Sim._effective_attack_distance(giant, small) >= Sim.body_radius(giant) + Sim.body_radius(small), "formation_reach", "A large melee body must still be able to reach its opponent")
	var pair := [fighter("a", Vector2(500,260),2),fighter("b",Vector2(501,260),2)]
	for tick in 4: Sim._separate_units(pair, [])
	h.expect(penetration(pair) <= 0.1, "large_pair", "Two large units must not remain permanently interpenetrating")
	var crowd: Array = []
	var pile: Array = []
	for i in 16: pile.append(fighter("pile_%02d" % i, Vector2(500,260)))
	Sim._separate_units(pile, [])
	for unit in pile:
		h.expect(unit.pos.distance_to(Vector2(500,260)) <= 20.001,
			"tick_travel_bound", "Crowd correction must not throw an actor across the arena")
	for i in 16: crowd.append(fighter("crowd_%02d" % i, Vector2(460+(i%4)*20,220+(i/4)*20)))
	var reverse := crowd.duplicate(true)
	reverse.reverse()
	for tick in 10:
		Sim._separate_units(crowd, [])
		Sim._separate_units(reverse, [])
	h.expect(penetration(crowd) <= 0.1,"dense_contacts", "Dense contacts settle: %.4f" % penetration(crowd))
	for a in crowd:
		for b in reverse:
			if a.uid == b.uid: h.expect(a.pos == b.pos,"order_independent", "Input order must not alter contacts")
	var before := crowd.duplicate(true)
	for tick in 60: Sim._separate_units(crowd, [])
	var drift := 0.0
	for i in crowd.size(): drift = maxf(drift,crowd[i].pos.distance_to(before[i].pos))
	h.expect(drift <= 0.001,"resting_no_drift","Settled units must not keep sliding: %.6f" % drift)
	var edge := [fighter("edge_a",Vector2(45,40)), fighter("edge_b",Vector2(46,40)), fighter("edge_c",Vector2(47,40))]
	for tick in 15: Sim._separate_units(edge, [])
	h.expect(penetration(edge) <= 0.1, "edge_contacts", "Wall contacts must settle: %.4f" % penetration(edge))
	for unit in edge:
		h.expect(unit.pos.x >= 45 and unit.pos.y >= 40, "arena_bounds", "Contact correction must stay in arena")
	var dead := fighter("dead",Vector2(500,260));dead.alive=false;dead.hp=0
	var alive := fighter("live",Vector2(500,260))
	Sim._separate_units([alive,dead],[])
	h.expect(alive.pos == Vector2(500,260),"dead_no_push","A corpse must not push a living unit")
	_check_walking_pressure()
	h.note("settled penetration=%.6f drift=%.6f" % [penetration(crowd),drift])
	h.finish(get_tree())

func _check_walking_pressure() -> void:
	# Exercise the actual movement/attack branch, then the contact solver, for
	# 60 seconds. The original resting-only tests missed this accumulating shove.
	var defender := fighter("defender", Vector2(500,200))
	defender.team = "enemy"
	defender.def = {}
	var attackers: Array = []
	for row in 4:
		for col in 3:
			var unit := fighter("attacker_%d_%d" % [row,col], Vector2(466+col*34,240+row*34))
			unit.merge({"team":"player", "def":{"no_basic_attack":true}, "range_px":32.0,
				"move_speed_px":165.0, "next_attack":0.0})
			attackers.append(unit)
	var stationary: Vector2 = defender.pos
	var worst := 0.0
	for tick in 600:
		Sim._step_team(attackers, [defender], float(tick)*0.1, {})
		Sim._separate_units(attackers,[defender])
		worst = maxf(worst, penetration(attackers+[defender]))
	h.expect(defender.pos.distance_to(stationary) < 0.01, "walking_cannot_shove_enemy",
		"Ordinary melee pressure moved the defender %.3fpx" % defender.pos.distance_to(stationary))
	h.expect(worst < 0.1,"walking_keeps_collision", "Movement must block bodies; worst penetration %.3f" % worst)
	var mover := fighter("walker",Vector2(400,260))
	var wall := fighter("blocker",Vector2(500,260))
	Sim._move_without_pushing(mover, Vector2(250,0), [mover,wall])
	h.expect(mover.pos.distance_to(wall.pos) >= 29.99,"swept_contact","Fast walking cannot tunnel through a body")
	h.expect(wall.pos == Vector2(500,260),"walking_does_not_move_blocker","Only the walker may move")
	var a := fighter("a",Vector2(400,260))
	var b := a.duplicate(true)
	var obstacles := [fighter("x",Vector2(430,260)),fighter("y",Vector2(450,295))]
	Sim._move_without_pushing(a,Vector2(30,0),obstacles)
	obstacles.reverse()
	Sim._move_without_pushing(b,Vector2(30,0),obstacles)
	h.expect(a.pos == b.pos,"walking_order_independent","Obstacle array order must not change movement")
	var caster := fighter("fear",Vector2(400,260))
	caster.team = "player"
	caster.def = {}
	var victim := fighter("victim",Vector2(440,260))
	victim.team = "enemy"
	victim.def = {}
	BattleSimSkills._skill_fear(caster,[victim],{}, {})
	h.expect(victim.pos.distance_to(Vector2(530,260)) < 0.01,"skill_knockback_preserved","Explicit fear knockback still moves its target 90px")
