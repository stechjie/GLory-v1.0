extends Node

# 11.05 魔抗（参考 LoL / TFT 的物理 / 魔法 / 真伤三分）行为门禁。期望值全部按规则手算：
#   ① 每个棋子 / 佣兵 / Boss / 野怪都填了魔抗（非负整数）
#   ② 魔抗与防御同一套星级倍率；Boss 魔抗每打过一只 ×1.15，野怪跟防御成长
#   ③ 普攻走防御、技能（施法派发里的 "skill" 标记，或显式 magic）走魔抗、真伤两样都不吃
#   ④ 没填魔抗的单位按自身防御兜底
#   ⑤ 圣愈祭司由 boss_balance_check 覆盖，这里不重复

const Harness := preload("res://tools/CheckHarness.gd")
var h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	h = Harness.new("magic_resist")
	DataRegistry.ensure_loaded()
	_check_data()
	_check_scaling()
	_check_damage_types()
	h.finish(get_tree())


func _check_data() -> void:
	for spec in [["race_units", "units"], ["mercenaries", "mercenaries"], ["bosses", "bosses"], ["pve_monsters", "monsters"]]:
		var rows: Array = DataRegistry.get_table(str(spec[0])).get(str(spec[1]), [])
		h.expect(not rows.is_empty(), "table_%s" % spec[0], "%s 表是空的" % spec[0])
		var missing: Array[String] = []
		for row in rows:
			var v = (row as Dictionary).get("mres", null)
			if typeof(v) not in [TYPE_INT, TYPE_FLOAT] or float(v) < 0.0 or float(v) != floor(float(v)):
				missing.append(str(row.get("id", "?")))
		h.expect(missing.is_empty(), "mres_filled_%s" % spec[0], "%s 缺魔抗或不是非负整数：%s" % [spec[0], ", ".join(missing)])


func _unit(id: String) -> Dictionary:
	for row in DataRegistry.get_table("race_units").get("units", []):
		if str(row.get("id", "")) == id:
			return row
	return {}


func _check_scaling() -> void:
	var guard := _unit("god_guard")
	var base := int(guard.get("mres", -1))
	var four := UnitFactory.apply_star_stats(guard, 4)
	var three := UnitFactory.apply_star_stats(guard, 3)
	h.expect(int(three.mres) == int(round(float(base) * 3.0)) and int(four.mres) == int(round(float(base) * 3.0 * 1.15)),
		"star_scaling", "光之卫士魔抗升星应与防御同倍率：1★%d → 3★%d / 4★%d，实为 %d / %d" % [base, int(round(base * 3.0)), int(round(base * 3.45)), int(three.mres), int(four.mres)])
	var f: Dictionary = BattleSimShared._fighter_from_def(four, 0, "player", 0, 1)
	h.expect(int(f.get("mres", -1)) == int(four.mres), "fighter_field", "战斗单位应带上 mres 字段")

	var growth := BossService.growth_for_completed(2)
	h.expect(is_equal_approx(float(growth.get("mres", 0.0)), 1.15 * 1.15), "boss_growth_rate", "Boss 魔抗每只 ×1.15")
	var boss_def: Dictionary = {}
	for row in DataRegistry.get_table("bosses").get("bosses", []):
		if str(row.get("id", "")) == "boss_holy_priest":
			boss_def = row
	var saved := GameState.boss_completed
	GameState.boss_completed = 2
	var out: Array = []
	BattleSimShared._append_lane_boss(out, 0, boss_def)
	GameState.boss_completed = saved
	var want := int(round(float(boss_def.get("mres", 0)) * 1.15 * 1.15 * BossService.GLOBAL_STAT_MULTIPLIER))
	h.expect(not out.is_empty() and int(out[0].get("mres", -1)) == want, "boss_spawn_mres",
		"第 3 只圣愈祭司魔抗应为 %d，实为 %s" % [want, str(out[0].get("mres", "缺") if not out.is_empty() else "没生成")])


func _target(defense: int, mres = null) -> Dictionary:
	var t := {"uid": "t", "team": "enemy", "alive": true, "hp": 100000, "max_hp": 100000, "def": {}, "statuses": {}, "defense": defense, "dodge": 0.0, "shield": 0}
	if mres != null:
		t["mres"] = int(mres)
	return t


func _hit(t: Dictionary, kind: String, ignore_defense := false, magic := false) -> int:
	DamageService.set_hit_context(kind)
	var dealt := DamageService.apply_damage(t, 1000, ignore_defense, false, magic)
	DamageService.clear_hit_context()
	return dealt


func _check_damage_types() -> void:
	DamageService.clear_stat_context()
	# 魔抗 100、防御 0：技能减半，普攻不减
	h.expect(_hit(_target(0, 100), "skill") == 500, "skill_uses_mres", "技能伤害应按魔抗 100 减半")
	h.expect(_hit(_target(0, 100), "basic") == 1000, "basic_ignores_mres", "普攻不应吃魔抗")
	# 防御 100、魔抗 0：普攻减半，技能不减
	h.expect(_hit(_target(100, 0), "basic") == 500, "basic_uses_def", "普攻应按防御 100 减半")
	h.expect(_hit(_target(100, 0), "skill") == 1000, "skill_ignores_def", "技能不应再吃防御")
	# 真伤两样都不吃
	h.expect(_hit(_target(100, 100), "skill", true) == 1000, "true_damage", "真伤不吃防御也不吃魔抗")
	# 显式 magic（自爆灵毒爆走宝藏上下文）按魔抗
	h.expect(_hit(_target(0, 100), "treasure", false, true) == 500, "forced_magic", "显式 magic 的伤害应按魔抗算")
	# 没填魔抗：按防御兜底
	h.expect(_hit(_target(100), "skill") == 500, "fallback_defense", "没填魔抗的单位，技能伤害按防御算")
