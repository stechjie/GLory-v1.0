extends Node

# 11.16 用户定：棋子、佣兵、法阵友军进战斗时主动技能先走满一次冷却才放；
# Boss 和被动技能不受影响；黄金重骑冷却统一 7 秒；血条下黄色冷却条只给主动技能。

const Harness := preload("res://tools/CheckHarness.gd")
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")

var _h


func _ready() -> void:
	_h = Harness.new("skill_opening_cooldown")
	_check_table_matches_simulator()
	_check_opening_ready_times()
	_check_lantern_waits_and_stays_simultaneous()
	_check_gold_charge_data()
	_check_cooldown_bar()
	_h.finish(get_tree())


# 表里每个缺省冷却必须与 _tick_skills 对应分支里的 skill_ready 赋值一致。
# 只在该分支体内匹配（分支头到下一个分支头），防止被别处的注释或代码满足。
func _check_table_matches_simulator() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimulator.gd")
	var tick_start := src.find("static func _tick_skills(")
	var tick_end := src.find("\nstatic func ", tick_start + 10)
	var body := src.substr(tick_start, tick_end - tick_start)
	var branch_re := RegEx.create_from_string("(?m)^\\t\\t\\t\"([a-z_]+)\":\\s*$")
	var branches := {}
	var matches := branch_re.search_all(body)
	for i in matches.size():
		var m: RegExMatch = matches[i]
		var end := matches[i + 1].get_start() if i + 1 < matches.size() else body.length()
		branches[m.get_string(1)] = body.substr(m.get_end(), end - m.get_end())
	for sid: String in BattleSimShared.ACTIVE_SKILL_DEFAULT_CD:
		var want := float(BattleSimShared.ACTIVE_SKILL_DEFAULT_CD[sid])
		var branch := str(branches.get(sid, ""))
		var ok := false
		if sid == "shell_guard":
			ok = branch.contains("float(state.elapsed) + %s" % _num(want))
		else:
			ok = branch.contains("d.get(\"skill_cd\", %s)" % _num(want))
		_h.expect(ok, "table_matches_" + sid,
			"%s 的缺省冷却 %s 与 _tick_skills 分支不一致" % [sid, _num(want)])


func _num(v: float) -> String:
	return str(v) if v != floorf(v) else "%.1f" % v


func _unit(id: String, d: Dictionary, team := "player") -> Dictionary:
	d["id"] = id
	return {"uid": "%s_%s" % [team, id], "id": id, "team": team, "def": d,
		"alive": true, "hp": 1000, "max_hp": 1000, "atk": 100, "defense": 0,
		"attack_speed": 1.0, "shield": 0, "dodge": 0.0, "statuses": {},
		"skill_ready": 0.0, "pos": Vector2.ZERO}


func _check_opening_ready_times() -> void:
	var angel := _unit("god_angel", {"skill_id": "nearby_ally_heal_buff", "skill_cd": 7.0, "opening_cd": 2.0})
	var king := _unit("god_king", {"skill_id": "global_divine_blast", "skill_cd": 6.0})
	var imp := _unit("dark_imp", {"skill_id": "curse_attack"})
	var doom := _unit("dark_doom", {"skill_id": "shared_hp_link"})
	var ally := _unit("ally_soul_chain", {"skill_id": "soul_chain", "skill_cd": 9.0, "opening_cd": 2.5, "skill_global": true})
	var charge := _unit("merc_taurus_charge", {"skill_id": "gold_charge"})
	var shell := _unit("merc_cancer_shell", {"skill_id": "shell_guard", "skill_cd": 99.0})
	# 11.24：数据里写了 first_cast_sec 的按它首发，不等满冷却。
	var steel := _unit("merc_capricorn_steel", {"skill_id": "steel_order", "skill_cd": 8.0, "first_cast_sec": 3.0})
	var boss := _unit("boss_test", {"skill_id": "stun", "skill_cd": 5.0, "is_boss": true}, "enemy")
	var player := [angel, king, imp, doom, ally, charge, shell, steel]
	var enemy := [boss]
	var state := {"player": player, "enemy": enemy, "elapsed": 0.0, "player_syn": {}, "enemy_syn": {},
		"kind": "pvp", "visual_events": [], "unit_stats": {}, "log": []}
	DamageService.set_stat_state(state)
	var log: Array[String] = []
	BattleSimulator._apply_opening_unit_skills(player, enemy, log, state)
	_h.expect(is_equal_approx(float(angel.skill_ready), 7.0), "angel_full_cd", "天使开场应等满 7 秒，不再用 opening_cd 2 秒")
	_h.expect(is_equal_approx(float(king.skill_ready), 6.0), "star4_cd_used", "开场冷却应读当前星级的 skill_cd")
	_h.expect(is_zero_approx(float(imp.skill_ready)), "passive_untouched", "被动技能不加开场冷却")
	_h.expect(is_zero_approx(float(doom.skill_ready)), "doom_link_untouched", "末日守卫血链保持开场生效")
	_h.expect(is_equal_approx(float(ally.skill_ready), 9.0), "formation_ally_full_cd", "法阵友军开场应等满 9 秒")
	_h.expect(is_equal_approx(float(charge.skill_ready), 7.0), "gold_charge_7", "黄金重骑开场应等 7 秒")
	_h.expect(is_equal_approx(float(shell.skill_ready), 6.0), "shell_guard_fixed_6", "甲壳守卫固定 6 秒")
	_h.expect(is_equal_approx(float(steel.skill_ready), 3.0), "first_cast_sec_used", "写了 first_cast_sec 的开场应按它首发（3 秒），而不是等满 8 秒冷却")
	# 11.26：对齐用户当天直接改在 mercenaries.json 里的首发时间（猎人 3.5→5、刺客 5→3、重骑 / 修女 6→5）。
	var expected_first := {"merc_sagittarius_rain": 5.0, "merc_gemini_assassin": 5.0, "merc_taurus_charge": 5.0, "merc_capricorn_steel": 3.0, "merc_aquarius_time": 6.0, "merc_virgo_heal": 5.0}
	for m: Dictionary in _all_dicts(DataRegistry.get_table("mercenaries")):
		var mid := str(m.get("id", ""))
		if expected_first.has(mid) and m.has("skill_id"):
			_h.expect(is_equal_approx(BattleSimShared.opening_skill_cooldown({"id": mid, "def": m}), float(expected_first[mid])), "merc_first_cast_" + mid, "%s 首次释放时间应为 %s 秒" % [mid, str(expected_first[mid])])
	_h.expect(is_zero_approx(float(boss.skill_ready)), "boss_untouched", "Boss 技能不加开场冷却")
	_h.expect(BattleSimShared.has_active_cooldown_skill(angel) and not BattleSimShared.has_active_cooldown_skill(imp)
		and not BattleSimShared.has_active_cooldown_skill(boss) and not BattleSimShared.has_active_cooldown_skill(doom),
		"active_flag", "主动/被动/Boss 判定不对")


func _check_lantern_waits_and_stays_simultaneous() -> void:
	var old_team_mode := GameState.team_mode
	GameState.team_mode = true
	var lantern_def := {"skill_id": "aoe_silence", "skill_cd": 10.0, "skill_global": true, "silence_duration": 3.0, "race": "crimson"}
	var p := _unit("lattern", lantern_def.duplicate(true))
	var e := _unit("lattern", lantern_def.duplicate(true), "enemy")
	p.lane = 0
	e.lane = 0
	var state := {"player": [p], "enemy": [e], "elapsed": 0.0, "player_syn": {}, "enemy_syn": {},
		"kind": "pvp", "visual_events": [], "unit_stats": {}, "log": []}
	DamageService.set_stat_state(state)
	var log: Array[String] = []
	BattleSimulator._apply_opening_unit_skills([p], [e], log, state)
	BattleSimulator._tick_ready_lanterns(state)
	_h.expect(not StatusEffectService.has_status(p, "silence") and not StatusEffectService.has_status(e, "silence"),
		"lantern_no_opening_cast", "赤灯使第 0 秒不应再施放")
	state.elapsed = 10.0
	BattleSimulator._tick_ready_lanterns(state)
	_h.expect(StatusEffectService.has_status(p, "silence") and StatusEffectService.has_status(e, "silence")
		and is_equal_approx(float(p.skill_ready), 20.0) and is_equal_approx(float(e.skill_ready), 20.0),
		"lantern_simultaneous_at_cd", "冷却好的那一刻双方赤灯使应同时结算")
	GameState.team_mode = old_team_mode


func _check_gold_charge_data() -> void:
	var found := false
	for m: Dictionary in _all_dicts(DataRegistry.get_table("mercenaries")):
		if str(m.get("id", "")) == "merc_taurus_charge" and m.has("skill_id"):
			found = is_equal_approx(float(m.get("skill_cd", 0.0)), 7.0)
	_h.expect(found, "gold_charge_data_7", "mercenaries.json 里黄金重骑 skill_cd 应为 7.0")


func _all_dicts(v: Variant) -> Array:
	var out: Array = []
	if v is Dictionary:
		out.append(v)
		for x in (v as Dictionary).values():
			out.append_array(_all_dicts(x))
	elif v is Array:
		for x in v:
			out.append_array(_all_dicts(x))
	return out


func _check_cooldown_bar() -> void:
	var root := Control.new()
	var f := _unit("dark_suc", {"skill_id": "stun", "skill_cd": 5.0})
	f.skill_ready = 5.0
	BattleRendererScript._add_skill_cooldown_bar(root, f)
	var fill := root.get_node_or_null("SkillCdFill") as ColorRect
	_h.expect(fill != null, "bar_for_active", "主动技能单位应有冷却条")
	if fill != null:
		BattleRendererScript.sync_skill_cooldown_bar(fill, f, 2.5)
		_h.expect(is_equal_approx(fill.scale.x, 0.5), "bar_half", "开场 2.5/5 秒应半条")
		BattleRendererScript.sync_skill_cooldown_bar(fill, f, 6.0)
		_h.expect(is_equal_approx(fill.scale.x, 1.0), "bar_full_ready", "冷却好、等目标时应满条")
		f.skill_ready = 11.0
		BattleRendererScript.sync_skill_cooldown_bar(fill, f, 6.0)
		_h.expect(is_zero_approx(fill.scale.x), "bar_reset_on_cast", "放完技能应从空条重新计时")
	var passive_root := Control.new()
	BattleRendererScript._add_skill_cooldown_bar(passive_root, _unit("dark_imp", {"skill_id": "curse_attack"}))
	_h.expect(passive_root.get_node_or_null("SkillCdFill") == null, "no_bar_for_passive", "被动技能不应有冷却条")
	root.free()
	passive_root.free()
