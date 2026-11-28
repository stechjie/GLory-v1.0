extends Node

# 11.28 痛苦女王（用户定）：痛苦凝视叠到 4 层起，每次普攻使目标攻速 -20%（2 秒，每击刷新）；
# 换目标后层数归 1，新目标要重新叠到 4 层才吃减攻速。恐惧魔 1 星防御 7 → 10。

const Harness := preload("res://tools/CheckHarness.gd")

var _h


func _ready() -> void:
	_h = Harness.new("dark_queen_gaze")
	DataRegistry.load_all()
	var queen_def := _unit_def("dark_queen")
	var fear_def := _unit_def("dark_fear")
	_h.expect(int(queen_def.get("aspd_down_at_stacks", 0)) == 4 and is_equal_approx(float(queen_def.get("aspd_down_pct", 0.0)), 0.20)
		and is_equal_approx(float(queen_def.get("aspd_down_sec", 0.0)), 2.0), "queen_data", "痛苦女王数据：4 层起减攻速 20%、2 秒")
	_h.expect(int(fear_def.get("def", 0)) == 10, "fear_def", "恐惧魔 1 星防御应为 10，实际 %d" % int(fear_def.get("def", 0)))

	var queen: Dictionary = BattleSimShared._fighter_from_def(queen_def, 0, "player", 0, 1, 1, false, false)
	queen.uid = "queen"
	queen["owner_syn"] = {}
	queen["owner_treasures"] = []
	var a := _dummy("a")
	var b := _dummy("b")
	var st := _state([queen], [a, b])
	DamageService.begin_stat_context(st, queen)
	for i in 3:
		BattleSimulator._perform_attack(queen, a, st)
	_h.expect(int(queen.skill_stacks) == 3 and not StatusEffectService.has_status(a, "slow"), "no_slow_before_4",
		"3 层时还没有减攻速（层数 %d）" % int(queen.skill_stacks))
	BattleSimulator._perform_attack(queen, a, st)
	var slow: Dictionary = a.statuses.get("slow", {})
	_h.expect(int(queen.skill_stacks) == 4 and is_equal_approx(float(slow.get("attack_speed_pct", 0.0)), 0.20)
		and is_zero_approx(float(slow.get("move_pct", 0.0))) and is_equal_approx(float(slow.get("remaining", 0.0)), 2.0),
		"slow_at_4", "第 4 层：攻速 -20%%、不减移速、2 秒，实际 %s" % str(slow))
	_h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(a), 0.80), "aspd_multiplier",
		"目标攻速倍率应为 0.80，实际 %.2f" % StatusEffectService.attack_speed_multiplier(a))
	# 过 1 秒后再打一下：时间刷新回 2 秒，数值不叠加。
	StatusEffectService.tick(a, 1.0)
	BattleSimulator._perform_attack(queen, a, st)
	slow = a.statuses.get("slow", {})
	_h.expect(is_equal_approx(float(slow.get("attack_speed_pct", 0.0)), 0.20) and is_equal_approx(float(slow.get("remaining", 0.0)), 2.0),
		"slow_refresh_no_stack", "再打一下只刷新时间、不叠加，实际 %s" % str(slow))
	# 换目标：层数归 1，新目标不吃减攻速。
	BattleSimulator._perform_attack(queen, b, st)
	_h.expect(int(queen.skill_stacks) == 1 and not StatusEffectService.has_status(b, "slow"), "switch_resets",
		"换目标后层数归 1、新目标没有减攻速（层数 %d）" % int(queen.skill_stacks))
	DamageService.clear_stat_context()
	_h.finish(get_tree())


func _unit_def(id: String) -> Dictionary:
	for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
		if str(unit.get("id", "")) == id:
			return unit.duplicate(true)
	return {}


func _dummy(uid: String) -> Dictionary:
	var d := {"id": "probe_" + uid, "name": uid, "hp": 1000000, "atk": 10, "def": 0, "attack_speed": 1.0, "range": 1,
		"move_speed": 3.0, "crit": 0.0, "crit_dmg": 1.0, "skill_id": "none", "tier": 1, "element": "-", "race": "human"}
	var f: Dictionary = BattleSimShared._fighter_from_def(d, 0, "enemy", 0, 1, 1, false, false)
	f.uid = uid
	f["owner_syn"] = {}
	f["owner_treasures"] = []
	return f


func _state(player: Array, enemy: Array) -> Dictionary:
	var st := {
		"kind": "pvp", "player": player, "enemy": enemy, "elapsed": 0.0,
		"next_decay": 999.0, "finished": false, "log": [],
		"player_syn": {}, "enemy_syn": {}, "enemy_deaths": 0, "total_deaths": 0,
		"field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0,
		"undead_trait_death_counter": 0, "race_trait_processed_deaths": {},
		"death_history": [], "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0,
		"kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0,
		"temporary_deaths": [], "visual_events": [], "unit_stats": {},
		"owner_syn_by_key": {}, "owner_state": {},
	}
	BattleSimShared._init_unit_stats(st)
	return st
