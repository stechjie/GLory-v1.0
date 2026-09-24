extends RefCounted

# 9.24 种族羁绊 7 档 / 攻击·控制套装 / 目标锁定 改版的行为检查。
# 跑法：godot --headless --path . res://tools/synergy_0924_runner.tscn
# （用场景而不是 -s：-s 脚本在 autoload 注册之前编译，找不到 GameState 等全局名。）
# 全部调用真实的 BattleSimulator / BattleSimTreasures 代码，不复制判定逻辑。

var _fails := 0
var _passes := 0


var _host: Node


func run(host: Node) -> void:
	_host = host
	_run()


func _expect(ok: bool, name: String, detail: String) -> void:
	if ok:
		_passes += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		_fails += 1
		print("FAIL  %s  %s" % [name, detail])


func _run() -> void:
	GameState.team_mode = true
	_check_flags()
	_check_human_rally()
	_check_human_phoenix()
	_check_god_pulse()
	_check_undead_heal()
	_check_dark_sap()
	_check_attack_execute()
	_check_control_refresh()
	_check_target_lock()
	print("synergy_0924_check: %d passed, %d failed" % [_passes, _fails])
	_host.get_tree().quit(1 if _fails > 0 else 0)


# --- helpers -------------------------------------------------------------------

func _def(id: String, race: String, atk: int, hp: int = 3000, def_val: int = 0) -> Dictionary:
	return {"id": id, "name": id, "hp": hp, "atk": atk, "def": def_val,
		"attack_speed": 1.0, "range": 1, "move_speed": 3.0, "crit": 0.0, "crit_dmg": 1.0,
		"skill_id": "none", "tier": 1, "element": "-", "race": race}


func _unit(uid: String, race: String, team: String, lane: int, syn: Dictionary, atk: int = 100, hp: int = 3000, treasures: Array = []) -> Dictionary:
	var f: Dictionary = BattleSimShared._fighter_from_def(_def("probe_" + uid, race, atk, hp), 0, team, 0, 1, 1, false, false)
	f.uid = uid
	f["lane"] = lane
	f["owner_treasures"] = treasures.duplicate()
	f["owner_syn"] = syn
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
	DamageService.set_stat_state(st)
	BattleSimShared._snapshot_base_stats(player + enemy)
	return st


func _kill(state: Dictionary, f: Dictionary) -> void:
	f.hp = 0
	f.alive = false
	BattleSimTreasures._process_race_death_traits(state)


# --- SynergyService flags --------------------------------------------------------

func _check_flags() -> void:
	var f7 := SynergyService.flags_from_counts({"god": 7, "dark": 7, "undead": 7, "human": 7})
	var f6 := SynergyService.flags_from_counts({"god": 6, "dark": 6, "undead": 6, "human": 6})
	_expect(bool(f7.god_divine_pulse) and bool(f7.dark_sap) and float(f7.undead_poison_heal) == 0.15 and bool(f7.human_death_rally),
		"flags_7", str(f7))
	_expect(not bool(f6.god_divine_pulse) and not bool(f6.dark_sap) and float(f6.undead_poison_heal) == 0.0 and not bool(f6.human_death_rally),
		"flags_6", "6 人不激活")
	_expect(not f7.has("god_invulnerable_opening") and not f7.has("human_last_stand") and not f7.has("dark_debuff_duration"),
		"flags_old_removed", "旧 7 档 flag 已删除")
	_expect(int(f7.undead_death_clone_threshold) == 30 and float(f7.undead_threshold_mul) == 1.0,
		"flags_undead_threshold", "灵7 不再降低阈值：%d / %.2f" % [int(f7.undead_death_clone_threshold), float(f7.undead_threshold_mul)])


# --- 人7 -------------------------------------------------------------------------

func _check_human_rally() -> void:
	var syn := {"human_death_rally": true}
	var team: Array = []
	for i in 7:
		team.append(_unit("h%d" % i, "human", "player", 0, syn, 100, 1000))
	var other_lane := _unit("other_lane", "human", "player", 1, syn, 100, 1000)
	var merc := _unit("merc", "human", "player", 0, syn, 100, 1000)
	merc.is_mercenary = true
	var foe := _unit("foe", "dark", "enemy", 0, {}, 100, 1000)
	var st := _state(team + [other_lane, merc], [foe])
	var last: Dictionary = team[6]
	last.hp = 500
	# 死 1 个：其余 6 个 +1 档
	_kill(st, team[0])
	var s1 := "atk %d def %d aspd %.2f max_hp %d hp %d crit %.2f critdmg %.2f" % [int(last.atk), int(last.defense), float(last.attack_speed), int(last.max_hp), int(last.hp), float(last.get("crit_bonus", 0.0)), float(last.get("crit_dmg_bonus", 0.0))]
	_expect(int(last.atk) == 120 and int(last.max_hp) == 1200 and int(last.hp) == 700 and is_equal_approx(float(last.attack_speed), 1.2)
		and is_equal_approx(float(last.crit_bonus), 0.2) and is_equal_approx(float(last.crit_dmg_bonus), 0.1),
		"human_rally_1", s1)
	_expect(int(other_lane.atk) == 100 and int(merc.atk) == 100, "human_rally_scope",
		"别路 atk %d / 佣兵 atk %d（都应不变）" % [int(other_lane.atk), int(merc.atk)])
	# 死满 5 个 = 旧版翻倍
	for i in range(1, 5):
		_kill(st, team[i])
	_expect(int(last.atk) == 200 and int(last.max_hp) == 2000 and is_equal_approx(float(last.attack_speed), 2.0)
		and is_equal_approx(float(last.crit_bonus), 1.0) and is_equal_approx(float(last.crit_dmg_bonus), 0.5),
		"human_rally_5", "atk %d max_hp %d aspd %.2f crit %.2f critdmg %.2f（= 旧版背水一战）" % [int(last.atk), int(last.max_hp), float(last.attack_speed), float(last.crit_bonus), float(last.crit_dmg_bonus)])
	# 第 6 个死：超过旧版
	_kill(st, team[5])
	_expect(int(last.atk) == 220 and int(last.human_rally_stacks) == 6, "human_rally_6", "atk %d stacks %d" % [int(last.atk), int(last.human_rally_stacks)])
	# 同一个单位不会被重复计数
	BattleSimTreasures._process_race_death_traits(st)
	_expect(int(last.human_rally_stacks) == 6, "human_rally_once", "重复扫描不重复加层")
	# 佣兵死亡不计数
	_kill(st, merc)
	_expect(int(last.human_rally_stacks) == 6, "human_rally_merc_death", "佣兵死亡不算")
	# 敌方死亡不给我方加层
	_kill(st, foe)
	_expect(int(last.human_rally_stacks) == 6, "human_rally_enemy_death", "敌方死亡不算")


func _check_human_phoenix() -> void:
	var syn := {"human_death_rally": true}
	var a := _unit("pa", "human", "player", 0, syn, 100, 1000, ["atk_wail_resonance", "def_soul_counter"])
	var b := _unit("pb", "human", "player", 0, syn, 100, 1000)
	var foe := _unit("pfoe", "dark", "enemy", 0, {}, 100, 1000)
	var st := _state([a, b], [foe])
	a.hp = 0
	a.alive = false
	BattleSimTreasures._queue_phoenix_revive(a, st)
	BattleSimTreasures._process_race_death_traits(st)
	_expect(int(b.get("human_rally_stacks", 0)) == 0, "human_phoenix_fake", "凤凰第一次倒下不算：stacks %d" % int(b.get("human_rally_stacks", 0)))
	# 复活体 3.1 秒后真死：算
	st.elapsed = 0.2
	BattleSimTreasures._process_revives(st)
	st.elapsed = 3.5
	BattleSimTreasures._process_temporary_deaths(st)
	BattleSimTreasures._process_race_death_traits(st)
	_expect(int(b.get("human_rally_stacks", 0)) == 1, "human_phoenix_real", "复活体真死算 1 层：stacks %d" % int(b.get("human_rally_stacks", 0)))


# --- 神7 -------------------------------------------------------------------------

func _check_god_pulse() -> void:
	var syn := {"god_divine_pulse": true}
	var g := _unit("g", "god", "player", 0, syn, 100, 5000)
	var merc := _unit("gm", "god", "player", 0, syn, 100, 5000)
	merc.is_mercenary = true
	var foe := _unit("gfoe", "dark", "enemy", 0, {}, 100, 5000)
	g.pos = Vector2(500, 900)
	foe.pos = Vector2(500, -900)
	merc.pos = Vector2(100, 900)
	var st := _state([g, merc], [foe])
	var windows: Array = []
	var was := false
	for i in 170:
		BattleSimulator.step_state(st)
		var now := StatusEffectService.has_status(g, "invulnerable")
		if now and not was:
			windows.append(snappedf(float(st.elapsed) - 0.1, 0.1))
		was = now
	_expect(windows == [1.0, 6.0, 11.0, 16.0], "god_pulse_timing", "无敌开始时刻 %s" % str(windows))
	_expect(not StatusEffectService.has_status(merc, "invulnerable"), "god_pulse_no_merc", "佣兵不吃")
	# 无敌期间：普攻/技能伤害为 0，中毒照吃
	var g2 := _unit("g2", "god", "player", 0, syn, 100, 5000)
	var st2 := _state([g2], [])
	StatusEffectService.add_status(g2, "invulnerable", 1.0, {"dot_pass": true})
	var hit := DamageService.apply_damage(g2, 500, false)
	StatusEffectService.add_poison(g2, 4.0, 0.03, 0.0)
	var hp_before := int(g2.hp)
	StatusEffectService.tick(g2, 0.1)
	_expect(hit == 0 and int(g2.hp) < hp_before, "god_pulse_dot_pass",
		"直接伤害 %d（应为 0），中毒后 hp %d -> %d" % [hit, hp_before, int(g2.hp)])
	# 凤凰的完全无敌仍然挡中毒
	var g3 := _unit("g3", "god", "player", 0, {}, 100, 5000)
	StatusEffectService.add_status(g3, "invulnerable", 3.0, {})
	StatusEffectService.add_poison(g3, 4.0, 0.03, 0.0)
	var hp3 := int(g3.hp)
	StatusEffectService.tick(g3, 0.1)
	_expect(int(g3.hp) == hp3, "full_invuln_blocks_dot", "凤凰无敌不受中毒影响")


# --- 灵7 -------------------------------------------------------------------------

func _check_undead_heal() -> void:
	var syn := {"undead_poison_heal": 0.15}
	var u := _unit("u", "undead", "player", 0, syn, 100, 1000)
	u.hp = 500
	var h := _unit("uh", "human", "player", 0, syn, 100, 1000)
	h.hp = 500
	var t := _unit("ut", "dark", "enemy", 0, {}, 0, 1000000)
	var st := _state([u, h], [t])
	DamageService.begin_stat_context(st, u)
	BattleSimulator._perform_attack(u, t, st)
	var no_poison_hp := int(u.hp)
	StatusEffectService.add_poison(t, 4.0, 0.03, 0.0)
	BattleSimulator._perform_attack(u, t, st)
	var poisoned_hp := int(u.hp)
	BattleSimulator._perform_attack(h, t, st)
	DamageService.clear_stat_context()
	_expect(no_poison_hp == 500 and poisoned_hp == 650, "undead_poison_heal",
		"没毒 hp %d（应 500），有毒 hp %d（应 650）" % [no_poison_hp, poisoned_hp])
	_expect(int(h.hp) == 500, "undead_heal_race_only", "非灵族不吃：hp %d" % int(h.hp))


# --- 暗7 -------------------------------------------------------------------------

func _check_dark_sap() -> void:
	var syn := {"dark_sap": true}
	var d := _unit("d", "dark", "player", 0, syn, 100, 100000)
	var t := _unit("dt", "human", "enemy", 0, {}, 200, 10000000)
	t.defense = 100
	t.def["def"] = 100
	var st := _state([d], [t])
	DamageService.begin_stat_context(st, d)
	BattleSimulator._perform_attack(d, t, st)
	_expect(int(t.atk) == 200 and int(d.atk) == 100, "dark_sap_needs_debuff", "目标没负面时不触发")
	StatusEffectService.add_status(t, "slow", 99.0, {"attack_speed_pct": 0.0, "move_pct": 0.0})
	BattleSimulator._perform_attack(d, t, st)
	_expect(int(t.atk) == 194 and int(t.defense) == 97 and int(d.atk) == 102, "dark_sap_1",
		"目标 atk %d def %d，自己 atk %d" % [int(t.atk), int(t.defense), int(d.atk)])
	for i in 30:
		BattleSimulator._perform_attack(d, t, st)
	DamageService.clear_stat_context()
	_expect(int(t.dark_sap_taken) == 15 and int(t.atk) == 110 and int(d.atk) == 130 and is_equal_approx(float(d.attack_speed), 1.3),
		"dark_sap_cap", "15 层封顶：目标 atk %d（应 110），自己 atk %d（应 130），自己攻速 %.2f" % [int(t.atk), int(d.atk), float(d.attack_speed)])


# --- 4 攻击 / 4 控制 --------------------------------------------------------------

const ATK_4 := ["atk_blood_pact", "atk_burst_core", "atk_frenzy_assault", "atk_fury_roster"]
const CTRL_4 := ["ctrl_shockwave", "ctrl_corrosive_needle", "ctrl_interrupt_chain", "ctrl_binding_weight"]


func _check_attack_execute() -> void:
	var a := _unit("ea", "-", "player", 0, {}, 100, 3000, ATK_4)
	var t := _unit("et", "-", "enemy", 0, {}, 0, 3000)
	t.hp = 350
	var st := _state([a], [t])
	DamageService.begin_stat_context(st, a)
	BattleSimulator._perform_attack(a, t, st)
	DamageService.clear_stat_context()
	_expect(not bool(t.alive), "attack_execute", "350 血挨 100 → ≤10%% → 斩杀：alive=%s" % str(t.alive))


func _check_control_refresh() -> void:
	var a := _unit("ca", "-", "player", 0, {}, 100, 3000, CTRL_4)
	a.pos = Vector2(500, 330)
	a.skill_ready = 40.0
	var t := _unit("ct", "-", "enemy", 0, {}, 0, 3000)
	t.hp = 50
	t.pos = Vector2(500, 300)
	var st := _state([a], [t])
	st.elapsed = 2.0
	BattleSimulator._step_team([a], [t], 2.0, st)
	_expect(not bool(t.alive) and is_equal_approx(float(a.skill_ready), 2.0), "control_refresh",
		"普攻击杀后 skill_ready = %.1f（应 2.0）" % float(a.skill_ready))


# --- 目标锁定 ---------------------------------------------------------------------

func _check_target_lock() -> void:
	var a := _unit("la", "-", "player", 0, {}, 1, 3000)
	a.pos = Vector2(500, 420)
	var e1 := _unit("l1", "-", "enemy", 0, {}, 0, 3000)
	e1.pos = Vector2(500, 300)
	var e2 := _unit("l2", "-", "enemy", 0, {}, 0, 3000)
	e2.pos = Vector2(500, 100)
	var st := _state([a], [e1, e2])
	var targets := {}
	for i in 60:
		# 每 tick 把 l2 往攻击者身上挪，模拟「别人走得更近」
		e2.pos = e2.pos.move_toward(a.pos + Vector2(0, -20), 15.0)
		e1.pos = e1.pos.move_toward(Vector2(500, 250), 2.0)
		BattleSimulator._step_team([a], [e1, e2], float(i) * 0.1, st)
		var tu := str(a.get("vfx_attack_target_uid", ""))
		if not tu.is_empty():
			targets[tu] = true
		st.elapsed = float(i) * 0.1
	_expect(targets.keys() == ["l1"], "target_lock_live", "60 tick 里实际打过的目标：%s（应只有 l1）" % str(targets.keys()))
	var picked := str(BattleSimShared._select_target(a, [e1, e2]).get("uid", ""))
	e1.alive = false
	e1.hp = 0
	var after := str(BattleSimShared._select_target(a, [e1, e2]).get("uid", ""))
	_expect(picked == "l1" and after == "l2", "target_lock_release", "锁定 %s，死后换成 %s" % [picked, after])
	# 嘲讽可以抢走，嘲讽结束回到原目标
	var a2 := _unit("la2", "-", "player", 0, {}, 1, 3000)
	a2.pos = Vector2(500, 420)
	var m1 := _unit("m1", "-", "enemy", 0, {}, 0, 3000)
	m1.pos = Vector2(500, 300)
	var tank := _unit("tank", "-", "enemy", 0, {}, 0, 3000)
	tank.pos = Vector2(500, 200)
	var p0 := str(BattleSimShared._select_target(a2, [m1, tank]).get("uid", ""))
	tank.taunt_active = true
	tank.taunt_radius = 400.0
	var p1 := str(BattleSimShared._select_target(a2, [m1, tank]).get("uid", ""))
	tank.taunt_active = false
	var p2 := str(BattleSimShared._select_target(a2, [m1, tank]).get("uid", ""))
	_expect(p0 == "m1" and p1 == "tank" and p2 == "m1", "target_lock_taunt", "%s → 嘲讽 %s → 结束 %s" % [p0, p1, p2])
