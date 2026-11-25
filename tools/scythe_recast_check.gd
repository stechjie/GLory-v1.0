extends Node

# 偷袭者释放时机：无冷却；开战 2 秒后可用；每次突袭前吟唱 0.5 秒；目标死亡后再次吟唱突袭下一个。

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
			and bool(unit_def.get("skill_global", false)) and not unit_def.has("skill_cd")
			and is_equal_approx(float(unit_def.get("opening_delay", 0.0)), 2.0)
			and is_equal_approx(float(unit_def.get("chant_sec", 0.0)), 0.9),
			"scythe_data", "偷袭者数据必须是无冷却、开场 2 秒后可用、吟唱 0.9 秒"):
		_h.finish(get_tree())
		return
	# 11.16 的「主动技能开场先走满一次冷却」不适用于偷袭者（它走自己的 opening_delay）。
	_h.expect(is_zero_approx(BattleSimShared.opening_skill_cooldown({"id": "dark_scythe", "def": unit_def}))
		and not BattleSimShared.has_active_cooldown_skill({"id": "dark_scythe", "def": unit_def}),
		"scythe_no_opening_wait", "偷袭者不走通用的开场冷却，也不显示冷却条")

	var chant := float(unit_def.get("chant_sec", 0.0))
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
	var battle_log: Array[String] = []
	BattleSimulator._apply_opening_unit_skills(state.player, state.enemy, battle_log, state)
	_h.expect(is_equal_approx(float(scythe.skill_ready), 2.0), "scythe_opening_delay", "开战 2 秒后才能第一次用技能")

	# 前 2 秒：不吟唱、不突袭。
	var start_pos := Vector2(scythe.pos)
	while float(state.elapsed) < 1.85:
		BattleSimulator._tick_skills([scythe], state.enemy, state)
		_advance(state, scythe)
	_h.expect(not scythe.has("blink_chant_until") and int(soft.hp) == 100000 and Vector2(scythe.pos) == start_pos,
		"scythe_waits_two_seconds", "开战 2 秒内不能吟唱或突袭")

	# 2 秒起：先吟唱 0.5 秒（原地、挂 skill_chant 状态），吟唱完才位移和造成伤害。
	var chant_start := _tick_until(state, scythe, func(): return scythe.has("blink_chant_until"))
	_h.expect(chant_start >= 1.95 and chant_start <= 2.15 and StatusEffectService.has_status(scythe, "skill_chant")
		and int(soft.hp) == 100000 and Vector2(scythe.pos) == start_pos,
		"scythe_chant_start", "2 秒时开始吟唱；吟唱开始时不位移、不造成伤害")
	var cast_time := _tick_until(state, scythe, func(): return int(soft.hp) < 100000)
	_h.expect(cast_time >= chant_start + chant - 0.11 and cast_time <= chant_start + chant + 0.11
		and str(scythe.get("blink_target_uid", "")) == "enemy_soft"
		and Vector2(scythe.pos).distance_to(Vector2(soft.pos)) < 60.0 and not scythe.has("blink_chant_until"),
		"scythe_cast_after_chant", "吟唱 0.5 秒后才突袭低防目标（目标在射程外也照样突袭）")
	_h.expect(float(scythe.skill_ready) > cast_time, "scythe_cast_edge", "突袭必须给表现层一个 skill_ready 上升沿")

	# 目标活着：过多久都不再吟唱、不再放。
	var hp_after_first := int(soft.hp)
	var tank_hp := int(tank.hp)
	for i in 100:
		_advance(state, scythe)
		BattleSimulator._tick_skills([scythe], state.enemy, state)
	_h.expect(int(soft.hp) == hp_after_first and int(tank.hp) == tank_hp and not scythe.has("blink_chant_until"),
		"scythe_no_recast_while_target_alive", "目标还活着时不能再次吟唱或突袭")

	# 目标被别人打死：马上开始吟唱，0.5 秒后突袭下一个。
	soft.alive = false
	soft.hp = 0
	var rechant := _tick_until(state, scythe, func(): return scythe.has("blink_chant_until"))
	var recast := _tick_until(state, scythe, func(): return int(tank.hp) < tank_hp)
	_h.expect(recast >= rechant + chant - 0.11 and recast <= rechant + chant + 0.11 and str(scythe.get("blink_target_uid", "")) == "enemy_tank",
		"scythe_recast_on_target_death", "目标死亡后再次吟唱 0.5 秒并突袭下一个目标")

	# 突袭本身打死目标：同样再吟唱一次接下一个。
	var weak := _fighter("weak", "enemy", 1, Vector2(500, 100))
	weak.defense = 0
	tank.alive = false
	var last := _fighter("last", "enemy", 100000, Vector2(700, 100))
	last.defense = 50
	state.enemy = [weak, last]
	var kill_time := _tick_until(state, scythe, func(): return not bool(weak.alive))
	var chain_time := _tick_until(state, scythe, func(): return str(scythe.get("blink_target_uid", "")) == "enemy_last")
	_h.expect(kill_time > 0.0 and chain_time >= kill_time + chant - 0.11 and chain_time <= kill_time + chant + 0.25,
		"scythe_chain_on_kill", "突袭击杀后再吟唱一次，接着突袭下一个目标")

	# 场上没有可突袭的目标时不空吟唱。
	last.alive = false
	for i in 20:
		_advance(state, scythe)
		BattleSimulator._tick_skills([scythe], state.enemy, state)
	_h.expect(not scythe.has("blink_chant_until"), "scythe_no_empty_chant", "没有目标时不吟唱")

	GameState.team_mode = old_team_mode
	_h.finish(get_tree())


func _fighter(id: String, team: String, hp: int, pos: Vector2) -> Dictionary:
	return {"uid": "%s_%s" % [team, id], "id": id, "team": team,
		"def": {"id": id, "race": "dark"}, "alive": true, "hp": hp, "max_hp": hp,
		"atk": 100, "defense": 0, "attack_speed": 1.0, "shield": 0,
		"dodge": 0.0, "statuses": {}, "skill_ready": 0.0, "pos": pos}

# 推进 0.1 秒：时间前进，并让偷袭者身上的状态（skill_chant）跟着走。
func _advance(state: Dictionary, scythe: Dictionary) -> void:
	state.elapsed = float(state.elapsed) + 0.1
	StatusEffectService.tick(scythe, 0.1)


# 一直 tick 到条件成立，返回成立那一刻的战斗时间；5 秒内不成立返回 -1。
func _tick_until(state: Dictionary, scythe: Dictionary, done: Callable) -> float:
	for i in 50:
		BattleSimulator._tick_skills([scythe], state.enemy, state)
		if done.call():
			return float(state.elapsed)
		_advance(state, scythe)
	return -1.0
