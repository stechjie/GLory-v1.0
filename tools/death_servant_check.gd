extends Node

# 11.18 死侍改动：
# - 1~3 星：周围友军防御 +10、魔抗 +10；只绑自己正后方的棋子。
# - 4 星：防御、魔抗按百分比；只绑正后方；死侍自己先阵亡（不是替死）时己方全员回复 25% 最大生命。

const Harness := preload("res://tools/CheckHarness.gd")

var _h


func _ready() -> void:
	_h = Harness.new("death_servant")
	var base: Dictionary = {}
	for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
		if str(unit.get("id", "")) == "human_death_servant":
			base = unit
			break
	if not _h.expect(not base.is_empty() and int(base.get("ally_def_bonus", 0)) == 10
			and int(base.get("ally_mres_bonus", 0)) == 10
			and is_equal_approx(float(base.get("star4", {}).get("death_heal_pct", 0.0)), 0.25),
			"servant_data", "死侍数据必须是防御 +10、魔抗 +10，四星阵亡回血 25%"):
		_h.finish(get_tree())
		return
	var four: Dictionary = UnitFactory.apply_star_stats(base, 4)
	_h.expect(float(four.get("ally_def_pct", 0.0)) > 0.0 and is_equal_approx(float(four.get("death_heal_pct", 0.0)), 0.25),
		"servant_star4_data", "四星覆写必须带百分比防御和 death_heal_pct")

	var old_team_mode := GameState.team_mode
	GameState.team_mode = false

	# ---- 1~3 星：正后方绑定 + 固定值光环 ----
	# 死侍在第 1 排第 1 列（格 5）：前 = 1，后 = 9，左 = 4，右 = 6；斜角 = 0；
	# 格 4 的「编号相邻」格 3 在上一排最右，不算相邻；队友棋盘上的同位置格也不算。
	var servant := _fighter("servant", 5, base)
	var front := _fighter("front", 1, {})
	var left := _fighter("left", 4, {})
	var right := _fighter("right", 6, {})
	var behind := _fighter("behind", 9, {})
	var diagonal := _fighter("diagonal", 0, {})
	var mate := _fighter("mate", 4, {})
	mate.owner_slot = 1
	mate.lane = 1
	# 格 13 隔了一排；格 3 与格 4 编号相邻但在上一排最右，离死侍两列。
	var far := _fighter("far", 13, {})
	var wrap := _fighter("wrap", 3, {})
	var team := [servant, front, left, right, behind, diagonal, mate, far, wrap]
	var state := _state(team)
	var log: Array[String] = []
	BattleSimulator._apply_opening_unit_skills(team, [], log, state)
	_h.expect(behind.has("sacrifice_guardian") and str(servant.get("guard_target_uid", "")) == "player_behind"
		and not left.has("sacrifice_guardian") and not right.has("sacrifice_guardian"),
		"servant_binds_behind", "死侍只绑自己正后方的棋子，不再绑左右")
	_h.expect(DamageService.effective_defense(left) == 30 and DamageService.effective_magic_resist(left) == 25
		and DamageService.effective_defense(right) == 30 and DamageService.effective_magic_resist(right) == 25,
		"servant_aura_flat", "1~3 星周围友军防御 +10、魔抗 +10")
	_h.expect(DamageService.effective_defense(front) == 30 and DamageService.effective_magic_resist(behind) == 25
		and DamageService.effective_defense(behind) == 30,
		"servant_aura_front_back", "前、后 1 格的队友（含被绑的正后方棋子）也吃到光环")
	_h.expect(DamageService.effective_defense(diagonal) == 30 and DamageService.effective_magic_resist(diagonal) == 25,
		"servant_aura_diagonal", "斜角格的队友也吃到光环")
	_h.expect(DamageService.effective_defense(far) == 20 and DamageService.effective_magic_resist(far) == 15
		and DamageService.effective_defense(wrap) == 20 and DamageService.effective_defense(mate) == 20,
		"servant_aura_range", "隔一格的、编号相邻但跨排的、队友棋盘上的棋子不吃光环")
	StatusEffectService.tick(left, 5.1)
	_h.expect(DamageService.effective_defense(left) == 20 and DamageService.effective_magic_resist(left) == 15,
		"servant_aura_expires", "光环 5 秒后必须消失")

	# 被绑棋子阵亡：死侍替死，被绑棋子满血复活。
	behind.hp = 1
	DamageService.apply_damage(behind, 99999, true)
	_h.expect(bool(behind.alive) and int(behind.hp) == int(behind.max_hp) and not bool(servant.alive)
		and bool(servant.get("sacrificed", false)),
		"servant_sacrifice", "被绑棋子首次阵亡时死侍替死并使其满血复活")

	# ---- 最后一排：没有正后方，不绑定 ----
	var back := _fighter("back", 13, base)
	var back_left := _fighter("back_left", 12, {})
	team = [back, back_left]
	state = _state(team)
	BattleSimulator._apply_opening_unit_skills(team, [], log, state)
	_h.expect(not back.has("guard_target_uid") and not back_left.has("sacrifice_guardian"),
		"servant_back_row", "死侍站最后一排时没有可绑的棋子")

	# ---- 4 星：百分比光环 ----
	var s4 := _fighter("s4", 1, four)
	var l4 := _fighter("l4", 0, {})
	var b4 := _fighter("b4", 5, {})
	team = [s4, l4, b4]
	state = _state(team)
	BattleSimulator._apply_opening_unit_skills(team, [], log, state)
	_h.expect(DamageService.effective_defense(l4) == 28 and DamageService.effective_magic_resist(l4) == 21
		and b4.has("sacrifice_guardian"),
		"servant_star4_aura", "四星防御、魔抗 +40%，仍只绑正后方")

	# 4 星替死：不触发全员回血。
	l4.hp = 400
	b4.hp = 1
	DamageService.apply_damage(b4, 99999, true)
	BattleSimulator._process_death_servant_fall(state)
	_h.expect(not bool(s4.alive) and bool(b4.alive) and int(l4.hp) == 400,
		"servant_star4_sacrifice_no_heal", "替死而亡不算自己先阵亡，不回血")

	# 4 星自己先阵亡：全员回复 25% 最大生命，只触发一次。
	var s5 := _fighter("s5", 1, four)
	var l5 := _fighter("l5", 0, {})
	var b5 := _fighter("b5", 5, {})
	team = [s5, l5, b5]
	state = _state(team)
	BattleSimulator._apply_opening_unit_skills(team, [], log, state)
	l5.hp = 400
	b5.hp = 900
	s5.hp = 1
	DamageService.apply_damage(s5, 99999, true)
	BattleSimulator._process_death_servant_fall(state)
	_h.expect(not bool(s5.alive) and int(l5.hp) == 650 and int(b5.hp) == 1000,
		"servant_star4_death_heal", "四星死侍自己先阵亡时己方全员回复 25% 最大生命（不超过上限）")
	l5.hp = 400
	BattleSimulator._process_death_servant_fall(state)
	_h.expect(int(l5.hp) == 400, "servant_star4_death_heal_once", "阵亡回血每只死侍只触发一次")
	# 死侍先死后，被绑棋子不再有替死。
	b5.hp = 1
	DamageService.apply_damage(b5, 99999, true)
	_h.expect(not bool(b5.alive), "servant_dead_no_revive", "死侍已阵亡，被绑棋子不再复活")

	# 1~3 星自己先阵亡：没有回血。
	var s3 := _fighter("s3", 1, base)
	var l3 := _fighter("l3", 0, {})
	team = [s3, l3]
	state = _state(team)
	l3.hp = 400
	s3.hp = 0
	s3.alive = false
	BattleSimulator._process_death_servant_fall(state)
	_h.expect(int(l3.hp) == 400, "servant_base_no_death_heal", "1~3 星死侍阵亡不回血")

	GameState.team_mode = old_team_mode
	_h.finish(get_tree())


func _state(team: Array) -> Dictionary:
	var state := {"player": team, "enemy": [], "elapsed": 0.0,
		"player_syn": {}, "enemy_syn": {}, "kind": "pvp", "visual_events": [],
		"unit_stats": {}, "log": []}
	DamageService.set_stat_state(state)
	return state


func _fighter(id: String, slot: int, unit_def: Dictionary) -> Dictionary:
	var d: Dictionary = unit_def.duplicate(true) if not unit_def.is_empty() else {"id": id, "race": "human"}
	return {"uid": "player_%s" % id, "id": id, "team": "player", "def": d,
		"alive": true, "hp": 1000, "max_hp": 1000, "atk": 100, "defense": 20, "mres": 15,
		"attack_speed": 1.0, "shield": 0, "dodge": 0.0, "statuses": {}, "skill_ready": 0.0,
		"slot": slot, "owner_slot": 0, "lane": 0, "pos": Vector2(100 + slot * 40, 500)}
