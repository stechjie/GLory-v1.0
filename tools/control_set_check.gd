extends Node

# 11.26 控制 4 件套（用户定）：
#   · 持有者的普通棋子给敌人施加的控制和减益持续时间 +35%（中毒 / 流血 / 灼烧也延长）；
#   · 被它眩晕 / 沉默 / 缴械 / 恐惧的敌人，控制期间受到的治疗 -30%；
#   · 普攻击杀清技能冷却保留。

const Harness := preload("res://tools/CheckHarness.gd")
const SET_FOUR := ["ctrl_shockwave", "ctrl_corrosive_needle", "ctrl_interrupt_chain", "ctrl_time_compress"]
const SET_THREE := ["ctrl_shockwave", "ctrl_corrosive_needle", "ctrl_interrupt_chain"]

var _h


func _ready() -> void:
	_h = Harness.new("control_set")
	DataRegistry.load_all()
	_h.expect(is_equal_approx(StatusEffectService.CONTROL_SET_DURATION_BONUS, 0.35) and is_equal_approx(StatusEffectService.CONTROL_SET_ANTIHEAL_PCT, 0.30),
		"values", "控制套应为时长 +35%、减疗 30%")
	_h.expect(TreasureService.has_set_in(SET_FOUR, "control") and not TreasureService.has_set_in(SET_THREE, "control"),
		"fixture_set", "4 件激活、3 件不激活")

	# 时长：控制与减益 ×1.35；3 件不变；DoT 不延长。
	_h.expect(is_equal_approx(_applied("stun", 2.0, SET_FOUR), 2.7), "stun_extended", "眩晕 2 秒应变 2.7 秒，实际 %.2f" % _applied("stun", 2.0, SET_FOUR))
	_h.expect(is_equal_approx(_applied("interrupt", 1.5, SET_FOUR), 2.025), "disarm_extended", "缴械 1.5 秒应变 2.025 秒")
	_h.expect(is_equal_approx(_applied("slow", 2.0, SET_FOUR, {"move_pct": 0.25}), 2.7), "slow_extended", "减速 2 秒应变 2.7 秒")
	_h.expect(is_equal_approx(_applied("damage_down", 2.0, SET_FOUR, {"pct": 0.2}), 2.7), "damage_down_extended", "减伤害 2 秒应变 2.7 秒")
	_h.expect(is_equal_approx(_applied("stun", 2.0, SET_THREE), 2.0), "three_pieces_no_bonus", "只有 3 件时不延长")
	_h.expect(is_equal_approx(_applied("stun", 2.0, []), 2.0), "no_treasure_no_bonus", "没有宝藏时不延长")
	_h.expect(is_equal_approx(_applied("bleed", 3.0, SET_FOUR, {"pct_current_hp": 0.06, "tick_left": 0.0}), 4.05), "bleed_extended", "流血 3 秒应变 4.05 秒")
	_h.expect(is_equal_approx(_applied("poison", 4.0, SET_FOUR, {"pct_max_hp": 0.03, "tick_left": 0.0}), 5.4), "poison_extended", "中毒 4 秒应变 5.4 秒")
	_h.expect(is_equal_approx(_applied("burn", 2.0, SET_FOUR, {"tick_left": 0.0}), 2.7), "burn_extended", "灼烧 2 秒应变 2.7 秒")
	_h.expect(is_equal_approx(_applied("bleed", 3.0, SET_THREE, {"pct_current_hp": 0.06, "tick_left": 0.0}), 3.0), "bleed_three_pieces", "只有 3 件时流血不延长")
	# 佣兵 / 法阵友军不吃宝藏。
	_h.expect(is_equal_approx(_applied("stun", 2.0, SET_FOUR, {}, {"is_mercenary": true}), 2.0), "mercenary_no_bonus", "佣兵施加的控制不延长")
	# 给自己人上的状态（正面或误伤）不延长。
	_h.expect(is_equal_approx(_applied("slow", 2.0, SET_FOUR, {"move_pct": 0.1}, {}, true), 2.0), "ally_target_no_bonus", "对同队单位施加的状态不延长")

	# 减疗：被控制套控制住时治疗 ×0.7；减速不算被控制；控制结束后恢复；非套装来源的控制不减疗。
	_h.expect(_heal_after("stun", SET_FOUR) == 70, "controlled_heal_reduced", "被眩晕时 100 点治疗应只回 70，实际 %d" % _heal_after("stun", SET_FOUR))
	_h.expect(_heal_after("fear", SET_FOUR) == 70 and _heal_after("silence", SET_FOUR) == 70 and _heal_after("interrupt", SET_FOUR) == 70,
		"all_controls_reduce_heal", "沉默 / 缴械 / 恐惧同样减疗")
	_h.expect(_heal_after("slow", SET_FOUR) == 100, "slow_is_not_control", "只被减速不算被控制，治疗不减")
	_h.expect(_heal_after("stun", SET_THREE) == 100, "no_set_no_antiheal", "没有 4 件套的控制不减疗")
	var pair := _pair(SET_FOUR)
	_apply(pair, "stun", 1.0, {})
	StatusEffectService.tick(pair.target, 1.5)
	_h.expect(_heal(pair.target) == 100, "antiheal_ends_with_control", "控制结束后治疗恢复正常")
	# 别的来源刷新同一个控制，不把套装的减疗标记冲掉。
	pair = _pair(SET_FOUR)
	_apply(pair, "stun", 2.0, {})
	DamageService.clear_stat_context()
	StatusEffectService.add_status(pair.target, "stun", 1.0, {})
	_h.expect(_heal(pair.target) == 70, "antiheal_survives_refresh", "无来源的眩晕刷新后减疗仍在")

	# 击杀清冷却保留。
	var killer := _unit("killer", "player", SET_FOUR)
	killer.skill_ready = 9.0
	BattleSimTreasures._control_set_refresh_on_kill(killer, {"elapsed": 3.0})
	_h.expect(is_equal_approx(float(killer.skill_ready), 3.0), "kill_refresh_kept", "普攻击杀后技能冷却清零仍然生效")
	_h.finish(get_tree())


func _unit(uid: String, team: String, treasures: Array, extra: Dictionary = {}) -> Dictionary:
	var f := {"uid": uid, "id": "dummy", "team": team, "def": {"id": "dummy", "race": "human"}, "alive": true,
		"hp": 500, "max_hp": 1000, "atk": 10, "defense": 0, "mres": 0, "shield": 0, "dodge": 0.0, "statuses": {},
		"owner_treasures": treasures, "skill_ready": 0.0}
	f.merge(extra, true)
	return f


func _pair(treasures: Array, source_extra: Dictionary = {}, same_team := false) -> Dictionary:
	var source := _unit("src", "player", treasures, source_extra)
	var target := _unit("tgt", "player" if same_team else "enemy", [])
	var state := {"player": [source] + ([target] if same_team else []), "enemy": [] if same_team else [target], "elapsed": 5.0, "kind": "pve",
		"player_syn": {}, "enemy_syn": {}, "visual_events": [], "unit_stats": {}, "log": []}
	DamageService.set_stat_state(state)
	return {"source": source, "target": target, "state": state}


func _apply(pair: Dictionary, kind: String, duration: float, params: Dictionary) -> void:
	DamageService.begin_stat_context(pair.state, pair.source)
	StatusEffectService.add_status(pair.target, kind, duration, params)
	DamageService.clear_stat_context()


func _applied(kind: String, duration: float, treasures: Array, params: Dictionary = {}, source_extra: Dictionary = {}, same_team := false) -> float:
	var pair := _pair(treasures, source_extra, same_team)
	_apply(pair, kind, duration, params)
	return float((pair.target.statuses.get(kind, {}) as Dictionary).get("remaining", -1.0))


func _heal(target: Dictionary) -> int:
	var before := int(target.hp)
	BattleSimShared._heal_unit(target, 100)
	return int(target.hp) - before


func _heal_after(kind: String, treasures: Array) -> int:
	var pair := _pair(treasures)
	_apply(pair, kind, 2.0, {"move_pct": 0.25} if kind == "slow" else {})
	return _heal(pair.target)
