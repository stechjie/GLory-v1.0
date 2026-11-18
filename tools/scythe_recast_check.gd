extends Node

# 11.18 偷袭者释放时机：无冷却、开场直接突袭、目标死亡后立刻突袭下一个。

const Harness := preload("res://tools/CheckHarness.gd")

var _h


func _ready() -> void:
	_h = Harness.new("scythe_recast")
	var unit_def: Dictionary = {}
	for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
		if str(unit.get("id", "")) == "dark_scythe":
			unit_def = unit
			break
	if not _h.expect(not unit_def.is_empty() and bool(unit_def.get("recast_on_target_death", false))
			and bool(unit_def.get("skill_global", false)) and not unit_def.has("skill_cd"),
			"scythe_data", "偷袭者数据必须是无冷却 + 开场直接释放"):
		_h.finish(get_tree())
		return

	var old_team_mode := GameState.team_mode
	GameState.team_mode = false
	var scythe := _fighter("scythe", "player", 1000, Vector2(100, 900))
	scythe.def = unit_def.duplicate(true)
	scythe.atk = 100
	# 两个目标都远在射程外；soft 防御更低，应先被选中。
	var soft := _fighter("soft", "enemy", 100000, Vector2(100, 100))
	soft.defense = 0
	var tank := _fighter("tank", "enemy", 100000, Vector2(300, 100))
	tank.defense = 50
	var state := {"player": [scythe], "enemy": [soft, tank], "elapsed": 0.0,
		"player_syn": {}, "enemy_syn": {}, "kind": "pvp", "visual_events": [],
		"unit_stats": {}, "log": []}
	DamageService.set_stat_state(state)

	BattleSimulator._tick_skills([scythe], state.enemy, state)
	_h.expect(str(scythe.get("blink_target_uid", "")) == "enemy_soft" and int(soft.hp) < 100000
		and Vector2(scythe.pos).distance_to(Vector2(soft.pos)) < 60.0,
		"scythe_opening_cast", "开场 0 秒、目标在射程外也必须直接突袭低防目标")
	_h.expect(float(scythe.skill_ready) > 0.0, "scythe_cast_edge", "突袭必须给表现层一个 skill_ready 上升沿")

	# 目标活着：过多久都不再放。
	var hp_after_first := int(soft.hp)
	var tank_hp := int(tank.hp)
	for i in 100:
		state.elapsed = float(state.elapsed) + 0.1
		BattleSimulator._tick_skills([scythe], state.enemy, state)
	_h.expect(int(soft.hp) == hp_after_first and int(tank.hp) == tank_hp,
		"scythe_no_recast_while_target_alive", "目标还活着时不能再次突袭")

	# 目标被别人打死：下一 tick 立刻突袭下一个。
	soft.alive = false
	soft.hp = 0
	state.elapsed = float(state.elapsed) + 0.1
	BattleSimulator._tick_skills([scythe], state.enemy, state)
	_h.expect(str(scythe.get("blink_target_uid", "")) == "enemy_tank" and int(tank.hp) < tank_hp,
		"scythe_recast_on_target_death", "目标死亡后必须立刻突袭下一个目标")

	# 突袭本身打死目标：下一 tick 也立刻再放。
	var weak := _fighter("weak", "enemy", 1, Vector2(500, 100))
	weak.defense = 0
	tank.alive = false
	var last := _fighter("last", "enemy", 100000, Vector2(700, 100))
	last.defense = 50
	state.enemy = [weak, last]
	state.elapsed = float(state.elapsed) + 0.1
	BattleSimulator._tick_skills([scythe], state.enemy, state)
	state.elapsed = float(state.elapsed) + 0.1
	BattleSimulator._tick_skills([scythe], state.enemy, state)
	_h.expect(not bool(weak.alive) and str(scythe.get("blink_target_uid", "")) == "enemy_last",
		"scythe_chain_on_kill", "突袭击杀后必须立刻接下一个目标")

	GameState.team_mode = old_team_mode
	_h.finish(get_tree())


func _fighter(id: String, team: String, hp: int, pos: Vector2) -> Dictionary:
	return {"uid": "%s_%s" % [team, id], "id": id, "team": team,
		"def": {"id": id, "race": "dark"}, "alive": true, "hp": hp, "max_hp": hp,
		"atk": 100, "defense": 0, "attack_speed": 1.0, "shield": 0,
		"dodge": 0.0, "statuses": {}, "skill_ready": 0.0, "pos": pos}
