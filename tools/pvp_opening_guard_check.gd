extends Node

# 11.24 PVP 开场保护：对战开打后的头 2 秒，所有人受到的伤害 -50%；
# 打怪 / Boss 回合没有；小怪和 Boss 本身不受保护。

const Harness := preload("res://tools/CheckHarness.gd")

var _h


func _ready() -> void:
	_h = Harness.new("pvp_opening_guard")
	_h.expect(is_equal_approx(DamageService.PVP_OPENING_GUARD_SEC, 2.0) and is_equal_approx(DamageService.PVP_OPENING_GUARD_PCT, 0.5),
		"guard_values", "开场保护应为 2 秒、减伤 50%")
	_h.expect(_hit("pvp", 0.0, {}) == 50, "pvp_first_tick_halved", "PVP 第 0 秒受到的伤害减半")
	_h.expect(_hit("pvp", 1.9, {}) == 50, "pvp_last_protected_tick", "PVP 第 1.9 秒仍受保护")
	_h.expect(_hit("pvp", 2.0, {}) == 100, "pvp_guard_ends", "PVP 满 2 秒后保护结束")
	# 模拟器里的时间是 0.1 一步步加出来的，累加值和 2.0 差一点点浮点误差，也必须算保护结束。
	var stepped := 0.0
	for i in 20:
		stepped += 0.1
	_h.expect(_hit("pvp", stepped, {}) == 100, "pvp_guard_ends_stepped", "按 0.1 秒累加到第 2 秒时保护必须已经结束")
	_h.expect(_hit("pve", 0.0, {}) == 100, "pve_no_guard", "打怪回合没有开场保护")
	_h.expect(_hit("pvp_manual", 0.0, {}) == 100, "manual_pvp_state_no_guard", "没走真实开场流程的对战状态（教学、检查脚本手搭的）不带开场保护")
	var src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimulator.gd")
	_h.expect(src.contains('state["pvp_opening_guard"] = true') and src.contains('if kind == "pvp":'), "real_pvp_turns_guard_on", "prepare_team_state 必须在对战回合打开开场保护")
	_h.expect(_hit("boss", 0.0, {}) == 100, "boss_round_no_guard", "Boss 回合没有开场保护")
	_h.expect(_hit("pvp", 0.0, {"is_boss": true}) == 100, "boss_unit_unprotected", "Boss 本身不受保护")
	_h.expect(_hit("pvp", 0.0, {"series": "sky"}) == 100, "monster_unit_unprotected", "小怪本身不受保护")
	# 护盾在保护之后结算：100 伤害先减半成 50，30 护盾吸掉 30，实际掉 20 血。
	var shielded := _target({})
	shielded.shield = 30
	_state("pvp", 0.0, shielded)
	DamageService.apply_damage(shielded, 100, true, true)
	_h.expect(int(shielded.hp) == 980 and int(shielded.shield) == 0, "guard_before_shield", "保护在护盾之前结算")
	_h.finish(get_tree())


func _target(extra_def: Dictionary) -> Dictionary:
	var d := {"id": "dummy", "race": "human"}
	d.merge(extra_def)
	return {"uid": "enemy_dummy", "id": "dummy", "team": "enemy", "def": d, "alive": true,
		"hp": 1000, "max_hp": 1000, "atk": 10, "defense": 0, "mres": 0, "shield": 0, "dodge": 0.0, "statuses": {}}


func _state(kind: String, elapsed: float, target: Dictionary) -> void:
	var state := {"player": [], "enemy": [target], "elapsed": elapsed, "kind": kind,
		"player_syn": {}, "enemy_syn": {}, "visual_events": [], "unit_stats": {}, "log": []}
	# 真实对战由 BattleSimulator.prepare_team_state 在 kind == "pvp" 时打开这个开关。
	if kind == "pvp":
		state["pvp_opening_guard"] = true
	elif kind == "pvp_manual":
		state["kind"] = "pvp"
	DamageService.set_stat_state(state)
	DamageService.clear_stat_context()


# 真伤、跳过闪避地打 100 点，返回实际掉血。
func _hit(kind: String, elapsed: float, extra_def: Dictionary) -> int:
	var target := _target(extra_def)
	_state(kind, elapsed, target)
	DamageService.apply_damage(target, 100, true, true)
	return 1000 - int(target.hp)