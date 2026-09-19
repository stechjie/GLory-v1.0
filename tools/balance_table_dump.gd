extends Node

# 数值总表导出器 —— **不读文档、不抄 JSON**，全部调用游戏自己的运行时函数。
#
# 目的：产出的每个数字都必须是战斗/结算代码真正会用到的那一份。所以：
#   * 属性：走 BattleSimShared._fighter_from_cell()（棋盘格 → 战斗单位的唯一入口，
#     单机与联机共用），而不是自己重算 hp × 系数。
#   * 4★ 技能数值：走 UnitFactory.apply_star_stats() 摊平后的 def。
#   * 「这个技能到底会不会发动」：**实跑**。把单位丢进真实的战斗函数里
#     （_apply_opening_unit_skills / _tick_skills / _perform_attack /
#      _on_unit_killed / _apply_defender_reaction），看有没有任何状态真的变化。
#     没变化就是没发动 —— 数据表里写了什么、文档里写了什么，一概不算。
#   * 经济：调 EconomyService / CarrotEconomy / ShopRoll / TreasureService 本体。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/balance_table_dump.tscn
# 输出：
#   res://work/balance_runtime_dump.json

const BattleSimTreasures := preload("res://scripts/battle/BattleSimTreasures.gd")
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
const EconomyLedger := preload("res://scripts/multiplayer/EconomyLedger.gd")

const OUT_PATH := "res://work/balance_runtime_dump.json"
const DUMMY_HP := 50000000

var _out := {}


func _ready() -> void:
	DataRegistry.load_all()
	GameState.team_mode = false
	GameState.owned_treasures.clear()
	RngService.rng.seed = 12345

	_out["meta"] = {
		"godot": Engine.get_version_info(),
		"generated_utc": Time.get_datetime_string_from_system(true),
		"note": "每个数字都来自游戏运行时函数的返回值；skill_probe 是实跑战斗函数的结果。",
	}
	print("[dump] globals"); _out["globals"] = _dump_globals()
	print("[dump] units"); _out["units"] = _dump_units()
	print("[dump] monsters"); _out["monsters"] = _dump_monsters()
	print("[dump] bosses"); _out["bosses"] = _dump_bosses()
	print("[dump] mercs"); _out["mercenaries"] = _dump_mercs()
	print("[dump] allies"); _out["formation_allies"] = _dump_allies()
	print("[dump] rounds"); _out["rounds"] = _dump_rounds()
	print("[dump] economy"); _out["economy"] = _dump_economy()
	print("[dump] carrot"); _out["carrot"] = _dump_carrot()
	print("[dump] synergy"); _out["synergy"] = _dump_synergy()
	print("[dump] treasures"); _out["treasures"] = _dump_treasures()
	print("[dump] live_battle"); _out["live_battle"] = _dump_live_battle()

	DirAccess.make_dir_recursive_absolute("res://work")
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(_out, "  "))
	f.close()
	print("[balance_table_dump] wrote ", ProjectSettings.globalize_path(OUT_PATH))
	print("[balance_table_dump] units=", _out.units.size(), " monsters=", _out.monsters.size(),
		" bosses=", _out.bosses.size(), " mercs=", _out.mercenaries.size(), " allies=", _out.formation_allies.size())
	get_tree().quit(0)


# ---------------------------------------------------------------- 全局常量
func _dump_globals() -> Dictionary:
	var dmg_curve := {}
	for d in [0, 5, 10, 20, 30, 50, 80, 100, 150, 200]:
		dmg_curve[str(d)] = DamageService.damage_reduction(int(d))
	var star_mul := {}
	for s in [1, 2, 3, 4]:
		star_mul[str(s)] = GameState.star_stat_multiplier(int(s), {})
	star_mul["4_undead_small"] = GameState.star_stat_multiplier(4, {"star4_multiplier": 1.5})
	var elem := {}
	for a in ["sky", "land", "ren"]:
		for b in ["sky", "land", "ren"]:
			elem["%s>%s" % [a, b]] = BattleSimShared._element_multiplier(str(a), str(b))
	return {
		"MAX_STAR": GameConstants.MAX_STAR,
		"MAX_MERGE_STAR": GameConstants.MAX_MERGE_STAR,
		"copies_to_upgrade": {"1": GameConstants.copies_to_upgrade(1), "2": GameConstants.copies_to_upgrade(2), "3": GameConstants.copies_to_upgrade(3)},
		"star_stat_multiplier": star_mul,
		"START_FORMATION_HP": GameState.START_FORMATION_HP,
		"START_GOLD": GameState.START_GOLD,
		"MAX_NORMAL_UNITS": GameState.MAX_NORMAL_UNITS,
		"normal_unit_cap_no_treasure": GameState.normal_unit_cap(),
		"CELL_COUNT": GameConstants.CELL_COUNT,
		"BENCH_SLOTS": GameState.BENCH_SLOTS,
		"MERCENARY_SLOTS": GameState.MERCENARY_SLOTS,
		"SHOP_UNIT_SLOTS": GameState.SHOP_UNIT_SLOTS,
		"FINAL_ROUND": GameState.FINAL_ROUND,
		"DECAY_START_SEC": BattleSimShared.DECAY_START_SEC,
		"DECAY_INTERVAL_SEC": BattleSimShared.DECAY_INTERVAL_SEC,
		"HARD_TIMEOUT_SEC": BattleSimShared.HARD_TIMEOUT_SEC,
		"TICK_SEC": BattleSimShared.TICK_SEC,
		"ATTACK_RANGE_SCALE": BattleSimShared.ATTACK_RANGE_SCALE,
		"MOVE_SPEED_SCALE": 55.0,
		"damage_reduction_curve": dmg_curve,
		"element_multiplier": elem,
		"race_relation_enabled": RaceRelationService.ENABLED,
		"race_relation_stat_change": RaceRelationService.STAT_CHANGE,
		"boss_global_stat_multiplier": BossService.GLOBAL_STAT_MULTIPLIER,
		"treasure_max_owned": TreasureService.MAX_OWNED,
		"treasure_set_threshold": 4,
		"probe_output_dummy_max_hp": PROBE_OUTPUT_MAX_HP,
		"probe_survive_dummy_max_hp": PROBE_SURVIVE_MAX_HP,
		"probe_dummy_defense": 0,
	}


# ---------------------------------------------------------------- 单位构造
func _cell_for(d: Dictionary, star: int, is_merc: bool = false) -> Dictionary:
	return {"def": d.duplicate(true), "star": star, "is_mercenary": is_merc, "id": str(d.get("id", ""))}


func _fighter_of(d: Dictionary, star: int, team: String, is_merc: bool = false) -> Dictionary:
	# 走真实入口：棋盘格 → 战斗单位。星级系数、4★ 覆写、死侍攻击=1 都在里面。
	var f: Dictionary = BattleSimShared._fighter_from_cell(_cell_for(d, star, is_merc), 0, team)
	return f


func _fighter_from_raw(d: Dictionary, team: String, star: int = 1, is_merc: bool = false, is_ally: bool = false) -> Dictionary:
	# 野怪 / Boss / 法阵友军走的是 _fighter_from_def（不吃星级）。
	return BattleSimShared._fighter_from_def(d.duplicate(true), 0, team, 0, 1, star, is_merc, is_ally)


# 探针靶子。
#
# 关键设计：max_hp 设成一个**真实量级**（3000 = 一只 3★ 肉盾的水平），
# 但 current hp 给到 5000 万让它撑得住 60 秒。
#
# 为什么必须分开：一大票效果是按「目标最大生命的百分比」结算的
# （神王裁决 max_hp_bonus_pct、中毒 poison_pct_max_hp、哀鸣共鸣、属性套装…）。
# 如果直接拿 5000 万当 max_hp，中毒一秒就打 150 万，导出的"伤害"全是假的。
# 代码里 apply_damage 只从 hp 扣、从不把 hp 夹到 max_hp，所以这样设是安全的。
# 防御给 0 —— 导出的伤害就是**未经减伤的原始输出**，跨单位可直接横向比较。
const DUMMY_MAX_HP := 3000

func _dummy(team: String, hp: int = DUMMY_HP, max_hp: int = DUMMY_MAX_HP) -> Dictionary:
	var d := {"id": "probe_dummy", "name": "靶子", "hp": max_hp, "atk": 0, "def": 0,
		"attack_speed": 0.0, "range": 1, "move_speed": 0.0, "crit": 0.0, "crit_dmg": 1.0,
		"skill_id": "none", "tier": 1, "element": "-", "race": "-"}
	var f: Dictionary = BattleSimShared._fighter_from_def(d, 1, team, 0, 1, 1, false, false)
	f.max_hp = max_hp
	f.hp = hp
	return f


func _state(player: Array, enemy: Array) -> Dictionary:
	var st := {
		"kind": "pvp", "player": player, "enemy": enemy, "elapsed": 0.0,
		"next_decay": BattleSimShared.DECAY_START_SEC, "finished": false, "log": [],
		"player_syn": {}, "enemy_syn": {}, "enemy_deaths": 0, "total_deaths": 0,
		"field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0,
		"undead_trait_death_counter": 0, "race_trait_processed_deaths": {},
		"death_history": [], "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0,
		"kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0,
		"temporary_deaths": [], "visual_events": [], "unit_stats": {},
	}
	BattleSimShared._init_unit_stats(st)
	DamageService.set_stat_state(st)
	return st


func _snap(f: Dictionary) -> Dictionary:
	return {
		"hp": int(f.get("hp", 0)), "max_hp": int(f.get("max_hp", 0)), "atk": int(f.get("atk", 0)),
		"defense": int(f.get("defense", 0)), "aspd": float(f.get("attack_speed", 0.0)),
		"shield": int(f.get("shield", 0)), "stacks": int(f.get("skill_stacks", 0)),
		"statuses": (f.get("statuses", {}) as Dictionary).keys(),
		"dodge": float(f.get("dodge", 0.0)), "crit_bonus": float(f.get("crit_bonus", 0.0)),
		"alive": bool(f.get("alive", true)), "pos": [f.pos.x, f.pos.y],
	}


func _diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for k in a.keys():
		if k == "statuses":
			var added := []
			for s in b["statuses"]:
				if not (s in a["statuses"]):
					added.append(s)
			if not added.is_empty():
				out["statuses_added"] = added
			continue
		if k == "pos":
			if abs(a.pos[0] - b.pos[0]) > 0.5 or abs(a.pos[1] - b.pos[1]) > 0.5:
				out["moved"] = true
			continue
		if a[k] != b[k]:
			out[k] = "%s -> %s" % [str(a[k]), str(b[k])]
	return out


# ---------------------------------------------------------------- 技能实跑探针
# 一次探针 = 把这个单位放进真实的战斗函数里跑，返回「到底发生了什么」。
func _probe(d: Dictionary, star: int, is_merc: bool = false, raw: bool = false, is_ally: bool = false) -> Dictionary:
	RngService.rng.seed = 987654321
	var caster: Dictionary = _fighter_from_raw(d, "player", star, is_merc, is_ally) if raw else _fighter_of(d, star, "player", is_merc)
	var foe: Dictionary = _dummy("enemy")
	# 贴脸：近战射程也进得去，_skill_target_in_range 一定过。
	caster.pos = Vector2(500.0, 300.0)
	foe.pos = Vector2(500.0, 290.0)
	# 有些技能要求自己已经掉血（镜像分裂 / 血怒 / 血怒暴走）。
	caster.hp = maxi(1, int(float(caster.max_hp) * 0.30))
	var st := _state([caster], [foe])

	var res := {"skill_id": str(caster.get("def", {}).get("skill_id", "none"))}

	# ① 开场技（护盾嘲讽 / 死侍光环 / 开场冷却 / 控制免疫）
	var c0 := _snap(caster)
	# _apply_opening_unit_skills 的第 3 个形参是 Array[String]，必须传强类型数组。
	var open_log: Array[String] = []
	BattleSimulator._apply_opening_unit_skills(st.player, st.enemy, open_log, st)
	var opening := _diff(c0, _snap(caster))
	if caster.has("taunt_active"):
		opening["taunt_active"] = true
		opening["taunt_radius"] = float(caster.get("taunt_radius", 0.0))
	res["opening_log"] = open_log
	res["opening_hook"] = opening
	res["opening_fired"] = not opening.is_empty()

	# ② 主动技：推进时间跑 _tick_skills，看 skill_ready 有没有被改写
	var fired := false
	var casts := 0
	var first_cast_t := -1.0
	var foe0 := _snap(foe)
	var c1 := _snap(caster)
	var n_player0: int = st.player.size()
	var n_enemy0: int = st.enemy.size()
	for i in 600:   # 60 秒
		st.elapsed = float(i) * BattleSimShared.TICK_SEC
		var ready_before := float(caster.get("skill_ready", 0.0))
		BattleSimulator._tick_skills([caster], [foe], st)
		if not is_equal_approx(float(caster.get("skill_ready", 0.0)), ready_before):
			casts += 1
			if not fired:
				first_cast_t = st.elapsed
			fired = true
	res["active_fired"] = fired
	res["active_casts_in_60s"] = casts
	res["active_first_cast_sec"] = first_cast_t
	res["active_effect_on_enemy"] = _diff(foe0, _snap(foe))
	res["active_effect_on_self"] = _diff(c1, _snap(caster))
	res["spawned_units"] = (st.player.size() - n_player0) + (st.enemy.size() - n_enemy0)

	# ③ 普攻挂钩（被动）：真的打 12 下
	RngService.rng.seed = 4242
	var caster2: Dictionary = _fighter_from_raw(d, "player", star, is_merc, is_ally) if raw else _fighter_of(d, star, "player", is_merc)
	var foe2: Dictionary = _dummy("enemy")
	caster2.pos = Vector2(500.0, 300.0)
	foe2.pos = Vector2(500.0, 290.0)
	var st2 := _state([caster2], [foe2])
	var f20 := _snap(foe2)
	var c20 := _snap(caster2)
	var dealt_total := 0
	for i in 12:
		st2.elapsed = float(i) * 1.0
		DamageService.begin_stat_context(st2, caster2)
		dealt_total += BattleSimulator._perform_attack(caster2, foe2, st2)
		DamageService.clear_stat_context()
	res["basic_attack_12hits_damage"] = dealt_total
	res["basic_attack_avg_damage"] = int(round(float(dealt_total) / 12.0))
	res["attack_hook_on_enemy"] = _diff(f20, _snap(foe2))
	res["attack_hook_on_self"] = _diff(c20, _snap(caster2))

	# ④ 被命中挂钩（毒甲 / 过载反击）
	RngService.rng.seed = 777
	var caster3: Dictionary = _fighter_from_raw(d, "player", star, is_merc, is_ally) if raw else _fighter_of(d, star, "player", is_merc)
	var atk3: Dictionary = _dummy("enemy")
	caster3.pos = Vector2(500.0, 300.0)
	atk3.pos = Vector2(500.0, 290.0)
	var st3 := _state([caster3], [atk3])
	var a30 := _snap(atk3)
	var c30 := _snap(caster3)
	for i in 12:
		st3.elapsed = float(i)
		BattleSimTreasures._apply_defender_reaction(atk3, caster3, 100)
	res["on_hit_taken_on_attacker"] = _diff(a30, _snap(atk3))
	res["on_hit_taken_on_self"] = _diff(c30, _snap(caster3))

	# ⑤ 死亡挂钩（自爆灵）
	RngService.rng.seed = 555
	var victim: Dictionary = _fighter_from_raw(d, "player", star, is_merc, is_ally) if raw else _fighter_of(d, star, "player", is_merc)
	var killer: Dictionary = _dummy("enemy")
	victim.pos = Vector2(500.0, 300.0)
	killer.pos = Vector2(500.0, 290.0)
	var st5 := _state([victim], [killer])
	var k50 := _snap(killer)
	victim.hp = 0
	victim.alive = false
	BattleSimulator._on_unit_killed(killer, victim, st5, [killer], [victim])
	res["on_death_effect_on_killer"] = _diff(k50, _snap(killer))

	# ⑥ 击杀挂钩（噬魂 / 冥界处决回血）
	RngService.rng.seed = 333
	var hunter: Dictionary = _fighter_from_raw(d, "player", star, is_merc, is_ally) if raw else _fighter_of(d, star, "player", is_merc)
	var prey: Dictionary = _dummy("enemy", 10, 10)
	hunter.hp = maxi(1, int(float(hunter.max_hp) * 0.5))
	hunter.pos = Vector2(500.0, 300.0)
	prey.pos = Vector2(500.0, 290.0)
	var st6 := _state([hunter], [prey])
	var h60 := _snap(hunter)
	prey.hp = 0
	prey.alive = false
	BattleSimulator._on_unit_killed(hunter, prey, st6, [hunter], [prey])
	res["on_kill_effect_on_self"] = _diff(h60, _snap(hunter))

	res["any_hook_fired"] = (res.opening_fired or res.active_fired
		or not (res.attack_hook_on_enemy as Dictionary).is_empty()
		or not (res.attack_hook_on_self as Dictionary).is_empty()
		or not (res.on_hit_taken_on_attacker as Dictionary).is_empty()
		or not (res.on_hit_taken_on_self as Dictionary).is_empty()
		or not (res.on_death_effect_on_killer as Dictionary).is_empty()
		or not (res.on_kill_effect_on_self as Dictionary).is_empty()
		or res.spawned_units != 0)
	DamageService.set_stat_state({})
	return res


# ---------------------------------------------------------------- 真实战斗 tick 探针
# 用 BattleSimulator.step_state() —— 玩家实战每 0.1 秒跑的就是这一个函数。
# 它会一并跑：状态结算、双方技能、走位、第 10 秒起的战斗衰减、击杀结算、种族死亡特性。
# 所以近战放完技能把目标推开之后会自己走回去，长冷却技能也能真正转好几轮。
#
# 分成两个口径，因为一份靶子没法同时满足两个要求：
#   A「输出测量」 靶子最大生命 20000、只跑 10 秒（衰减之前）。
#      按最大生命百分比结算的效果（中毒、神王裁决）在这个量级下是真实的，
#      10 秒内也不会被打死，所以得到的是一份干净的「原始输出」。
#   B「技能释放」 靶子最大生命 5000 万、跑满 60 秒。
#      只数技能释放次数，靶子必须活到最后；衰减会把 hp 夹到 max_hp，
#      所以 max_hp 必须够大（这正是 A 用不了 60 秒的原因）。
const PROBE_OUTPUT_MAX_HP := 20000
const PROBE_SURVIVE_MAX_HP := 50000000

func _probe_live(d: Dictionary, star: int, is_merc := false, raw := false, is_ally := false,
		ticks := 600, dummy_max_hp := PROBE_SURVIVE_MAX_HP) -> Dictionary:
	RngService.rng.seed = 20260912
	GameState.team_mode = false
	var caster: Dictionary = _fighter_from_raw(d, "player", star, is_merc, is_ally) if raw else _fighter_of(d, star, "player", is_merc)
	var foe: Dictionary = _dummy("enemy", dummy_max_hp, dummy_max_hp)
	caster.pos = Vector2(500.0, 300.0)
	foe.pos = Vector2(500.0, 290.0)
	var st := _state([caster], [foe])
	var open_log: Array[String] = []
	BattleSimulator._apply_opening_unit_skills(st.player, st.enemy, open_log, st)
	var start_hp := int(foe.hp)
	var casts := 0
	var first := -1.0
	var prev_ready := float(caster.get("skill_ready", 0.0))
	var steps := 0
	var statuses_seen := {}
	while steps < ticks and not bool(st.get("finished", false)):
		BattleSimulator.step_state(st)
		steps += 1
		var now := float(caster.get("skill_ready", 0.0))
		if not is_equal_approx(now, prev_ready):
			casts += 1
			if first < 0.0:
				first = float(st.elapsed)
			prev_ready = now
		for k in (foe.get("statuses", {}) as Dictionary).keys():
			statuses_seen[str(k)] = true
	return {
		"sim_seconds": float(steps) * BattleSimShared.TICK_SEC,
		"ticks_requested": ticks,
		"finished_early": bool(st.get("finished", false)),
		"dummy_max_hp": dummy_max_hp,
		"casts": casts,
		"first_cast_sec": first,
		"damage_to_dummy": maxi(0, start_hp - int(foe.hp)),
		"dummy_killed": not bool(foe.get("alive", true)),
		"enemy_statuses_seen": statuses_seen.keys(),
		"self_hp_end": int(caster.hp),
		"self_atk_end": int(caster.atk),
		"self_def_end": int(caster.defense),
		"self_shield_end": int(caster.get("shield", 0)),
		"field_units_end": st.player.size() + st.enemy.size(),
	}


# A 口径：10 秒原始输出（衰减之前，靶子 20000 最大生命 / 0 防御）
func _probe_output(d: Dictionary, star: int, is_merc := false, raw := false, is_ally := false) -> Dictionary:
	return _probe_live(d, star, is_merc, raw, is_ally, 100, PROBE_OUTPUT_MAX_HP)


# ---------------------------------------------------------------- 棋子
func _dump_units() -> Array:
	var out: Array = []
	for u in DataRegistry.get_table("race_units").get("units", []):
		var row := {"id": str(u.get("id", "")), "raw": u.duplicate(true), "stars": {}}
		for star in [1, 2, 3, 4]:
			var f: Dictionary = _fighter_of(u, star, "player")
			var eff: Dictionary = f.get("def", {})
			row.stars[str(star)] = {
				"runtime_def": eff.duplicate(true),
				"hp": int(f.hp), "max_hp": int(f.max_hp), "atk": int(f.atk),
				"defense": int(f.defense), "attack_speed": float(f.attack_speed),
				"range_px": float(f.range_px), "move_speed_px": float(f.move_speed_px),
				"dodge": float(f.get("dodge", 0.0)),
				"star_reported": int(eff.get("star", star)),
				"has_star4_leftover": eff.has("star4"),
				"probe": _probe(u, star),
				"live": _probe_live(u, star),
				"output10s": _probe_output(u, star),
				"kill_reward_pvp": EconomyService.pvp_normal_kill_reward(int(u.get("tier", 1)), star),
				"four_star_gold": CarrotEconomy.four_star_gold(int(u.get("tier", 0))),
				"shop_cost": EconomyLedger.unit_cost(u, []),
				"shop_cost_discount": EconomyLedger.unit_cost(u, ["money_discount"]),
				"shop_cost_clearance": EconomyLedger.unit_cost(u, ["atk_fury_roster", "money_discount"]),
			}
		row["skill_detail_cn"] = UnitDetailFormat.format_skill_detail(_fighter_of(u, 1, "player").get("def", {}))
		row["skill_detail_cn_4star"] = UnitDetailFormat.format_skill_detail(_fighter_of(u, 4, "player").get("def", {}))
		out.append(row)
	return out


# ---------------------------------------------------------------- 野怪
func _dump_monsters() -> Array:
	var t: Dictionary = DataRegistry.get_table("pve_monsters")
	var out: Array = []
	for m in t.get("monsters", []):
		var f: Dictionary = _fighter_from_raw(m, "enemy")
		out.append({
			"id": str(m.get("id", "")), "raw": m.duplicate(true),
			"hp": int(f.hp), "atk": int(f.atk), "defense": int(f.defense),
			"attack_speed": float(f.attack_speed), "range_px": float(f.range_px),
			"move_speed_px": float(f.move_speed_px),
			"probe": _probe(m, 1, false, true),
			"live": _probe_live(m, 1, false, true),
			"output10s": _probe_output(m, 1, false, true),
			"kill_reward_pve": EconomyService.PVE_MONSTER_KILL_GOLD,
			"skill_detail_cn": UnitDetailFormat.format_skill_detail(m),
		})
	return out


# ---------------------------------------------------------------- Boss
func _dump_bosses() -> Array:
	var out: Array = []
	for b in DataRegistry.get_table("bosses").get("bosses", []):
		# 复刻 _append_lane_boss 的实际处理：growth(n=0) × GLOBAL_STAT_MULTIPLIER
		var g := BossService.growth_for_completed(0)
		var d: Dictionary = (b as Dictionary).duplicate(true)
		var mul := BossService.GLOBAL_STAT_MULTIPLIER
		d.hp = maxi(1, int(round(float(d.get("hp", 1)) * float(g.hp) * mul)))
		d.atk = maxi(1, int(round(float(d.get("atk", 1)) * float(g.atk) * mul)))
		d.def = maxi(0, int(round(float(d.get("def", 0)) * float(g.def) * mul)))
		if d.has("skill_damage"):
			d.skill_damage = maxi(1, int(round(float(d.get("skill_damage", 0)) * float(g.skill_damage) * mul)))
		var f: Dictionary = _fighter_from_raw(d, "enemy")
		var per_round := {}
		for n in 4:
			var gn := BossService.growth_for_completed(n)
			per_round[str([5, 10, 15, 20][n])] = {
				"hp": int(round(float(b.get("hp", 1)) * float(gn.hp) * mul)),
				"atk": int(round(float(b.get("atk", 1)) * float(gn.atk) * mul)),
				"def": int(round(float(b.get("def", 0)) * float(gn.def) * mul)),
				"skill_damage": int(round(float(b.get("skill_damage", 0)) * float(gn.skill_damage) * mul)) if b.has("skill_damage") else null,
				"win_gold": EconomyService.boss_win_reward([5, 10, 15, 20][n]),
			}
		out.append({
			"id": str(b.get("id", "")), "raw": b.duplicate(true),
			"runtime_first_appearance": {"hp": int(f.hp), "atk": int(f.atk), "defense": int(f.defense)},
			"attack_speed": float(f.attack_speed), "range_px": float(f.range_px),
			"move_speed_px": float(f.move_speed_px), "footprint_cells": int(f.get("footprint_cells", 1)),
			"by_boss_round": per_round,
			"probe": _probe(d, 1, false, true),
			"live": _probe_live(d, 1, false, true),
			"output10s": _probe_output(d, 1, false, true),
			"skill_detail_cn": UnitDetailFormat.format_skill_detail(d),
		})
	return out


# ---------------------------------------------------------------- 佣兵
func _dump_mercs() -> Array:
	var out: Array = []
	for m in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		var f: Dictionary = _fighter_of(m, 1, "player", true)
		out.append({
			"id": str(m.get("id", "")), "raw": m.duplicate(true),
			"hp": int(f.hp), "atk": int(f.atk), "defense": int(f.defense),
			"attack_speed": float(f.attack_speed), "range_px": float(f.range_px),
			"move_speed_px": float(f.move_speed_px),
			"is_mercenary_flag": bool(f.get("is_mercenary", false)),
			"kill_reward": EconomyService.pvp_mercenary_kill_reward(int(m.get("cost", 0))),
			"probe": _probe(m, 1, true),
			"live": _probe_live(m, 1, true),
			"output10s": _probe_output(m, 1, true),
			"skill_detail_cn": UnitDetailFormat.format_skill_detail(m),
		})
	return out


# ---------------------------------------------------------------- 法阵友军
func _dump_allies() -> Array:
	var out: Array = []
	for a in DataRegistry.get_table("formation_allies").get("allies", []):
		var band: Array = a.get("hp_band", [0, 0])
		# 用真实入口验证「这个血量真的会召唤到这一只」
		var probe_hp := int(band[0])
		var resolved := FormationAllyService.ally_id_for_hp(probe_hp)
		var d: Dictionary = BattleSimShared._formation_ally_def_for_hp(probe_hp)
		var f: Dictionary = _fighter_from_raw(d, "player", 1, false, true)
		out.append({
			"id": str(a.get("id", "")), "raw": a.duplicate(true),
			"hp_band": band,
			"resolved_by_service": resolved,
			"resolve_matches": resolved == str(a.get("id", "")),
			"runtime_tier": int(d.get("tier", -1)), "runtime_cost": int(d.get("cost", -1)),
			"hp": int(f.hp), "atk": int(f.atk), "defense": int(f.defense),
			"attack_speed": float(f.attack_speed), "range_px": float(f.range_px),
			"move_speed_px": float(f.move_speed_px),
			"ignores_treasure": BattleSimShared._ignores_treasure(f),
			"kill_reward": 0,
			"probe": _probe(d, 1, false, true, true),
			"live": _probe_live(d, 1, false, true, true),
			"output10s": _probe_output(d, 1, false, true, true),
			"skill_detail_cn": UnitDetailFormat.format_skill_detail(d),
		})
	var map := {}
	for hp in range(0, 56):
		map[str(hp)] = FormationAllyService.ally_id_for_hp(hp)
	return [{"hp_to_ally_map": map}] + out


# ---------------------------------------------------------------- 回合
func _dump_rounds() -> Array:
	var out: Array = []
	var cnt: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
	var pve_done := 0
	var boss_done := 0
	for rd in range(1, 22):
		GameState.round_index = rd
		GameState.final_round_played = false
		var kind := RoundService.schedule_kind_for_round(rd)
		var pg := PveService.growth_for_completed(pve_done)
		var bg := BossService.growth_for_completed(boss_done)
		out.append({
			"round": rd, "kind": kind,
			"is_treasure_round": RoundService.is_treasure_round(rd),
			"monsters_per_lane": int(cnt.get(str(rd), 3)) if kind in ["pve", "boss"] else 0,
			"pve_completed_before": pve_done,
			"monster_hp_mul": pg.hp, "monster_atk_mul": pg.atk, "monster_def_mul": pg.def,
			"boss_completed_before": boss_done,
			"boss_hp_mul": bg.hp, "boss_atk_mul": bg.atk, "boss_def_mul": bg.def,
			"pve_win_bonus": EconomyService.pve_win_bonus(rd),
			"boss_win_reward": EconomyService.boss_win_reward(rd) if kind == "boss" else 0,
			"shop_tier_probs": _shop_probs(rd),
		})
		if kind == "pve": pve_done += 1
		elif kind == "boss": boss_done += 1
	GameState.round_index = 1
	return out


func _shop_probs(rd: int) -> Dictionary:
	# 真的把 0..1 扫一遍，让曲线由 ShopRoll 自己说。
	var n := 10000
	var c := {"1": 0, "2": 0, "3": 0}
	for i in n:
		var t := ShopRoll.tier_for_roll(rd, float(i) / float(n))
		c[str(t)] = int(c[str(t)]) + 1
	return {"tier1": float(c["1"]) / float(n), "tier2": float(c["2"]) / float(n), "tier3": float(c["3"]) / float(n)}


# ---------------------------------------------------------------- 经济
func _dump_economy() -> Dictionary:
	var interest := []
	for g in [0, 50, 100, 200, 300, 500, 800, 1000, 1500, 2000]:
		interest.append({
			"gold": g,
			"base_5pct": EconomyService.base_interest(g),
			"plus_compound_treasure": EconomyService.base_interest(g) + int(floor(float(g) * 0.05)),
			"pet_cat_bonus": EconomyService.pet_interest_bonus(g, "pet_cat"),
			"all_three_total": EconomyService.base_interest(g) + int(floor(float(g) * 0.05)) + EconomyService.pet_interest_bonus(g, "pet_cat"),
		})
	var refresh := []
	for i in 8:
		refresh.append({"nth": i, "shop_cost": EconomyService.shop_refresh_cost(i, false),
			"shop_cost_money_set": EconomyService.shop_refresh_cost(i, true),
			"treasure_cost": TreasureService.refresh_cost(i, false),
			"treasure_cost_money_set": TreasureService.refresh_cost(i, true)})
	var kill := []
	for tier in [1, 2, 3]:
		for star in [1, 2, 3, 4]:
			kill.append({"tier": tier, "star": star, "gold": EconomyService.pvp_normal_kill_reward(tier, star)})
	var merchant := []
	for star in [1, 2, 3, 4]:
		merchant.append({"star": star, "gold": EconomyService.merchant_gold_from_board(
			[{"def": {"skill_id": "post_battle_gold_by_star"}, "star": star}])})
	var consolation := []
	for s in range(0, 7):
		consolation.append({"loss_streak": s, "gold": EconomyService.consolation_reward(s)})
	# 走真实结算函数，做几个典型场景
	var scenarios := []
	for sc in [
		{"name": "PVE 第1回合 胜 (杀3怪)", "gold_before": 100, "kind": "pve", "player_wins": true, "round_index": 1, "kill_gold": 45},
		{"name": "PVE 第13回合 胜 (杀8怪)", "gold_before": 300, "kind": "pve", "player_wins": true, "round_index": 13, "kill_gold": 120},
		{"name": "PVE 第13回合 败 (杀5怪)", "gold_before": 300, "kind": "pve", "player_wins": false, "round_index": 13, "kill_gold": 75, "loss_streak_after": 2},
		{"name": "Boss 第10回合 胜", "gold_before": 300, "kind": "boss", "player_wins": true, "round_index": 10},
		{"name": "Boss 第10回合 败(Boss剩30%)", "gold_before": 300, "kind": "boss", "player_wins": false, "round_index": 10, "boss_hp_current": 30, "boss_hp_max": 100, "loss_streak_after": 1},
		{"name": "PVP 第12回合 胜(击杀120)", "gold_before": 400, "kind": "pvp", "player_wins": true, "round_index": 12, "kill_gold": 120},
		{"name": "PVP 第12回合 败", "gold_before": 400, "kind": "pvp", "player_wins": false, "round_index": 12, "kill_gold": 40, "loss_streak_after": 1},
	]:
		var ctx: Dictionary = sc.duplicate()
		var nm: String = str(ctx.get("name", ""))
		ctx.erase("name")
		ctx["treasures"] = []
		ctx["pet_id"] = ""
		var after := EconomyService.settle_post_battle_gold(ctx)
		scenarios.append({"scenario": nm, "gold_before": int(sc.get("gold_before", 0)), "gold_after": after,
			"net": after - int(sc.get("gold_before", 0))})
	return {
		"BASE_INTEREST_RATE": EconomyService.BASE_INTEREST_RATE,
		"PVE_MONSTER_KILL_GOLD": EconomyService.PVE_MONSTER_KILL_GOLD,
		"PVE_WIN_BONUS_PER_ROUND": EconomyService.PVE_WIN_BONUS_PER_ROUND,
		"PVP_WIN_BONUS": EconomyService.PVP_WIN_BONUS,
		"PVP_LOSS_BONUS": EconomyService.PVP_LOSS_BONUS,
		"CONSOLATION_GOLD_PER_LOSS": EconomyService.CONSOLATION_GOLD_PER_LOSS,
		"KILL_GOLD_PER_TIER": EconomyService.KILL_GOLD_PER_TIER,
		"MERCHANT_GOLD_PER_STAR": EconomyService.MERCHANT_GOLD_PER_STAR,
		"BOSS_WIN_REWARDS": EconomyService.BOSS_WIN_REWARDS,
		"ALTAR_GOLD": NetworkService.ALTAR_GOLD,
		"ALTAR_MIN_HP": NetworkService.ALTAR_MIN_HP,
		"ALTAR_MAX_USES_PER_ROUND": NetworkService.ALTAR_MAX_USES_PER_ROUND,
		"interest_table": interest,
		"refresh_costs": refresh,
		"kill_gold_table": kill,
		"merchant_gold": merchant,
		"consolation": consolation,
		"settle_scenarios": scenarios,
		"sell_refund_examples": [
			{"cost_basis": 20, "refund": EconomyLedger.sell_refund(20)},
			{"cost_basis": 30, "refund": EconomyLedger.sell_refund(30)},
			{"cost_basis": 50, "refund": EconomyLedger.sell_refund(50)},
		],
	}


# ---------------------------------------------------------------- 萝卜
func _dump_carrot() -> Dictionary:
	var tech := []
	for lv in range(0, 10):
		tech.append({"level": lv, "upgrade_price": CarrotEconomy.tech_price(lv),
			"production_only_tech": CarrotEconomy.production_for_tech(lv)})
	var farm := []
	for lv in range(0, 12):
		var spent := CarrotEconomy.farm_threshold_for_level(lv)
		farm.append({
			"level": CarrotEconomy.farm_level_for_spent(spent),
			"spent_threshold": spent,
			"capacity": CarrotEconomy.capacity_for_spent(spent),
			"camp_income_gold": CarrotEconomy.income_for_spent(spent),
			"farm_production_bonus": CarrotEconomy.farm_production_bonus(spent),
			"total_production_tech0": CarrotEconomy.total_production(0, spent),
			"total_production_tech5": CarrotEconomy.total_production(5, spent),
			"next_threshold": CarrotEconomy.next_threshold_for_spent(spent),
		})
	var harvest := []
	for spent in [0, 9, 20, 35, 55, 75]:
		for tech_lv in [0, 3, 5]:
			var cap: int = CarrotEconomy.capacity_for_spent(spent)
			var h: Dictionary = CarrotEconomy.harvest(cap - 1, spent, tech_lv)
			harvest.append({"spent": spent, "tech": tech_lv, "near_full_gain": h.gain,
				"production": h.production, "capacity": h.capacity, "overflow": h.overflow})
	var four := []
	for tier in [1, 2, 3]:
		four.append({"tier": tier, "gold": CarrotEconomy.four_star_gold(tier)})
	return {
		"BASE_PRODUCTION": CarrotEconomy.BASE_PRODUCTION,
		"STONE_FIRST_COST": CarrotEconomy.STONE_FIRST_COST,
		"STONE_COST_INCREMENT": CarrotEconomy.STONE_COST_INCREMENT,
		"stone_draw_prices": [CarrotEconomy.stone_cost_for_draw(0), CarrotEconomy.stone_cost_for_draw(1), CarrotEconomy.stone_cost_for_draw(2)],
		"STONE_DRAW_PER_ROUND": CarrotEconomy.STONE_DRAW_PER_ROUND,
		"STONE_TYPES": CarrotEconomy.STONE_TYPES,
		"harvest_tech": tech,
		"farm_levels": farm,
		"harvest_near_full": harvest,
		"four_star_gold": four,
		"merc_carrot_costs": _merc_carrot_costs(),
	}


func _merc_carrot_costs() -> Array:
	var out: Array = []
	for m in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		out.append({"id": str(m.get("id", "")), "name": str(m.get("name", "")),
			"carrot_cost": int(m.get("carrot_cost", -1)), "gold_cost_field": int(m.get("cost", -1))})
	return out


# ---------------------------------------------------------------- 羁绊
func _dump_synergy() -> Array:
	var out: Array = []
	for n in range(0, 10):
		for race in ["god", "dark", "undead", "human"]:
			var counts := {"god": 0, "dark": 0, "undead": 0, "human": 0}
			counts[race] = n
			var flags := SynergyService.flags_from_counts(counts)
			flags.erase("counts")
			out.append({"race": race, "count": n, "flags": flags})
	return out


# ---------------------------------------------------------------- 宝藏
func _dump_treasures() -> Array:
	var t: Dictionary = DataRegistry.get_table("treasures")
	var out: Array = []
	for tr in t.get("treasures", []):
		var tid := str(tr.get("id", ""))
		out.append({"id": tid, "raw": tr.duplicate(true),
			"category": str(tr.get("category", "")),
			"set_active_alone": TreasureService.has_set_in([tid], str(tr.get("category", "")))})
	# 套装门槛实测
	var set_probe := []
	for cat in ["defense", "control", "attack", "money", "element"]:
		var ids: Array = []
		for tr in t.get("treasures", []):
			if str(tr.get("category", "")) == cat:
				ids.append(str(tr.get("id", "")))
		var thresholds := {}
		for k in range(1, ids.size() + 1):
			thresholds[str(k)] = TreasureService.has_set_in(ids.slice(0, k), cat)
		set_probe.append({"category": cat, "member_count": ids.size(), "members": ids, "active_at_n": thresholds})
	var link_probe := []
	for l in t.get("linkages", []):
		var req: Array = l.get("requires", [])
		link_probe.append({"id": str(l.get("id", "")), "requires": req,
			"active_with_all": TreasureService.has_linkage_in(req, str(l.get("id", ""))),
			"active_missing_one": TreasureService.has_linkage_in(req.slice(0, maxi(0, req.size() - 1)), str(l.get("id", ""))),
			"extra_fields": _link_extra(l)})
	# 开场宝藏实测：拿一只基准棋子，分别只持有一件宝藏，看开场后属性差多少
	var opening := []
	var base_unit: Dictionary = DataRegistry.get_table("race_units").get("units", [])[0]
	for tid in ["def_iron_wall", "def_life_monument", "def_phantom_step", "ctrl_time_compress",
			"atk_blood_pact", "atk_burst_core"]:
		var f: Dictionary = _fighter_of(base_unit, 3, "player")
		f["owner_treasures"] = [tid]
		# 固定为「无出战宠物」：否则 _f_pet 会回落到本机账号的出战宠物，
		# 把蘑菇的 +1% 生命混进「只装这一件宝藏」的实测差异里。
		f["owner_pet"] = ""
		var st := _state([f], [])
		DamageService.set_stat_state(st)
		var b := _snap(f)
		var lg: Array[String] = []
		BattleSimTreasures._apply_opening_treasures([f], lg)
		opening.append({"treasure": tid, "on_3star_" + str(base_unit.get("id", "")): _diff(b, _snap(f)),
			"skill_cd_multiplier": float(f.get("skill_cd_multiplier", 1.0))})
	return [{"set_thresholds": set_probe, "linkages": link_probe, "opening_effect_probe": opening}] + out


func _link_extra(l: Dictionary) -> Dictionary:
	var out := {}
	for k in l.keys():
		if k in ["id", "requires"]:
			continue
		out[k] = l[k]
	return out


# ---------------------------------------------------------------- 真实整场战斗
# 让引擎跑一场真正的 3v3 回放（和玩家开打走的是同一个 compute_team_replay），
# 从结果里统计「哪些 skill_id 真的进了冷却 / 真的产生了演出事件」。
func _dump_live_battle() -> Dictionary:
	GameState.team_mode = true
	GameState.round_index = 12   # pvp 回合：双方都是棋子，技能面最全
	GameState.final_round_played = false
	GameState.team_slot_states = ["player", "empty", "empty", "dummy", "dummy", "dummy"]
	GameState.board_slots.resize(GameConstants.CELL_COUNT)
	for i in GameConstants.CELL_COUNT:
		GameState.board_slots[i] = null
	# 手动摆一套：把尽量多种技能塞进 7 个格子（上场上限）
	var want := ["god_priest", "god_guard", "god_aurora", "dark_imp", "undead_poison", "human_archer", "human_cleric"]
	var idx := 0
	for id in want:
		var u: Dictionary = {}
		for cand in DataRegistry.get_table("race_units").get("units", []):
			if str((cand as Dictionary).get("id", "")) == str(id):
				u = cand
				break
		if u.is_empty():
			continue
		GameState.board_slots[idx] = {"def": u.duplicate(true), "star": 3, "is_mercenary": false, "id": id}
		idx += 1
	GameState.mercenary_slots.resize(GameState.MERCENARY_SLOTS)
	for i in GameState.MERCENARY_SLOTS:
		GameState.mercenary_slots[i] = null
	var mlist: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	for i in mini(3, mlist.size()):
		var m: Dictionary = mlist[i * 4]
		GameState.mercenary_slots[i] = {"def": m.duplicate(true), "star": 1, "is_mercenary": true, "id": str(m.get("id", ""))}

	NetworkService.shared_seed = 424242
	var replay := BattleSimulator.compute_team_replay(0, "balance_dump")
	var skill_events := {}
	for frame in replay.get("frame_events", []):
		for ev in frame:
			if typeof(ev) != TYPE_DICTIONARY:
				continue
			var sid := str((ev as Dictionary).get("skill_id", ""))
			if sid.is_empty() or sid.begins_with("basic_") or sid in ["heal", "death"]:
				continue
			skill_events[sid] = int(skill_events.get(sid, 0)) + 1
	var roster_ids := {}
	for uid in replay.get("roster", {}):
		var r: Dictionary = replay.roster[uid]
		roster_ids[str(r.get("id", ""))] = true
	GameState.team_mode = false
	return {
		"kind": str(replay.get("kind", "")),
		"frames": (replay.get("frames", []) as Array).size(),
		"sim_seconds": float((replay.get("frames", []) as Array).size()) * BattleSimShared.TICK_SEC,
		"result": replay.get("result", {}),
		"skill_event_counts": skill_events,
		"participant_ids": roster_ids.keys(),
	}
