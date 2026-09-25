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
	var pair := [fighter("a", Vector2(500,260),2),fighter("b",Vector2(501,260),2)]
	for tick in 4: Sim._separate_units(pair, [])
	h.expect(penetration(pair) <= 0.1, "large_pair", "Two large units must not remain permanently interpenetrating")
	var crowd: Array = []
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
	h.note("settled penetration=%.6f drift=%.6f" % [penetration(crowd),drift])
	h.finish(get_tree())
