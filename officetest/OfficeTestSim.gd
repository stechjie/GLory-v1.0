class_name OfficeTestSim
extends RefCounted

# ============================================================================
# 离线自测 · 单位测试模式的战斗状态组装器(officetest 专用,不改现有逻辑)。
#
# 原则:能引用的全部引用 BattleSimulator / BattleSimShared 的 static 函数
# (_fighter_from_cell / _fighter_from_def / _place_in_lane / step_state /
#  _replay_capture_* / _team_replay_payload 等)。
# 唯一"自开一份"的段落是 BattleSimulator.prepare_team_state() 函数体内部
# 写死的开战后处理(state 字典 + 防御套装/人族开盾/神族无敌 + 开战技能/宝藏),
# 那段不是独立函数没法引用。原版若改动,需要手动同步下面标记的段落。
# ============================================================================

const TEST_KIND := "pvp"

# 单位类别 -> DataRegistry 表名/列表键
const CATALOG := {
	"piece": {"table": "race_units", "list": "units"},
	"merc": {"table": "mercenaries", "list": "mercenaries"},
	"monster": {"table": "pve_monsters", "list": "monsters"},
	"boss": {"table": "bosses", "list": "bosses"},
	"formation": {"table": "formation_allies", "list": "allies"},
}

# config 结构(全部内存态,不落盘):
# {
#   "placements": [ {"slot":0..5, "cell":0..15, "kind":"piece|merc|monster|boss|formation",
#                    "unit_id":"...", "star":1..3} ],
#   "slot_treasures": {0:[treasure_ids], ... 5:[...]}
# }


static func unit_list(kind: String) -> Array:
	var entry: Dictionary = CATALOG.get(kind, {})
	if entry.is_empty():
		return []
	return DataRegistry.get_table(str(entry.table)).get(str(entry.list), [])


static func find_def(kind: String, unit_id: String) -> Dictionary:
	for d in unit_list(kind):
		if typeof(d) == TYPE_DICTIONARY and str((d as Dictionary).get("id", "")) == unit_id:
			return (d as Dictionary).duplicate(true)
	return {}


static func treasure_list() -> Array:
	return DataRegistry.get_table("treasures").get("treasures", [])


static func slot_treasures(config: Dictionary, slot: int) -> Array:
	var by_slot: Dictionary = config.get("slot_treasures", {})
	var list = by_slot.get(slot, [])
	return list if list is Array else []


static func placements_by_slot(config: Dictionary) -> Dictionary:
	var out := {}
	for s in 6:
		out[s] = []
	for p in config.get("placements", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var slot := int((p as Dictionary).get("slot", -1))
		if slot >= 0 and slot < 6:
			(out[slot] as Array).append(p)
	return out


static func placement_at(config: Dictionary, slot: int, cell: int) -> Dictionary:
	for p in config.get("placements", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("slot", -1)) == slot and int(p.get("cell", -1)) == cell:
			return p
	return {}


static func remove_placement(config: Dictionary, slot: int, cell: int) -> void:
	var placements: Array = config.get("placements", [])
	for i in range(placements.size() - 1, -1, -1):
		var p = placements[i]
		if typeof(p) == TYPE_DICTIONARY and int(p.get("slot", -1)) == slot and int(p.get("cell", -1)) == cell:
			placements.remove_at(i)


static func set_placement(config: Dictionary, slot: int, cell: int, kind: String, unit_id: String, star: int) -> void:
	remove_placement(config, slot, cell)
	var placements: Array = config.get("placements", [])
	placements.append({"slot": slot, "cell": cell, "kind": kind, "unit_id": unit_id, "star": clampi(star, 1, GameConstants.MAX_STAR)})


static func side_unit_count(config: Dictionary, team_a: bool) -> int:
	var n := 0
	for p in config.get("placements", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var slot := int(p.get("slot", -1))
		if (team_a and slot >= 0 and slot < 3) or (not team_a and slot >= 3 and slot < 6):
			n += 1
	return n


# 与 SynergyService.count_races_from_board 同口径:只有普通棋子计入种族羁绊。
static func _syn_for_slot(slot_placements: Array) -> Dictionary:
	var counts := {"god": 0, "dark": 0, "undead": 0, "human": 0}
	for p in slot_placements:
		if str(p.get("kind", "")) != "piece":
			continue
		var def := find_def("piece", str(p.get("unit_id", "")))
		var race := str(def.get("race", ""))
		if counts.has(race):
			counts[race] += 1
	return SynergyService.flags_from_counts(counts)


# 摆放 -> 实际参战用的 def(Boss 全局倍率 / 法阵 tier 等已应用)。
# _fighter_for_placement 与「长按看详情」共用同一份,避免两处数值口径跑偏。
static func def_for_placement(p: Dictionary) -> Dictionary:
	var kind := str(p.get("kind", "piece"))
	var def := find_def(kind, str(p.get("unit_id", "")))
	if def.is_empty():
		return {}
	match kind:
		"boss":
			# 同 _append_lane_boss:成长按 0 档,只保留 Boss 全局倍率。
			var boss_mul: float = BossService.GLOBAL_STAT_MULTIPLIER
			def.hp = maxi(1, int(round(float(def.get("hp", 1)) * boss_mul)))
			def.atk = maxi(1, int(round(float(def.get("atk", 1)) * boss_mul)))
			def.def = maxi(0, int(round(float(def.get("def", 0)) * boss_mul)))
			if def.has("skill_damage"):
				def.skill_damage = maxi(1, int(round(float(def.get("skill_damage", 0)) * boss_mul)))
		"formation":
			# 同 BattleSimShared._formation_ally_def_for_hp:tier 4、cost 0。
			def.tier = 4
			def.cost = 0
	return def


# 星级口径:只有 piece 吃星级倍率,佣兵/怪兽/Boss/法阵一律按 1 星(倍率 1.0)。
static func star_for_placement(p: Dictionary) -> int:
	return int(p.get("star", 1)) if str(p.get("kind", "piece")) == "piece" else 1


static func _fighter_for_placement(p: Dictionary, team: String) -> Dictionary:
	var kind := str(p.get("kind", "piece"))
	var cell_idx := int(p.get("cell", 0))
	var unit_id := str(p.get("unit_id", ""))
	var def := def_for_placement(p)
	if def.is_empty():
		return {}
	match kind:
		"piece":
			var cell := {"id": unit_id, "def": def, "star": int(p.get("star", 1))}
			return BattleSimulator._fighter_from_cell(cell, cell_idx, team)
		"merc":
			var cell := {"id": unit_id, "def": def, "is_mercenary": true}
			return BattleSimulator._fighter_from_cell(cell, cell_idx, team)
		"monster":
			# 同 _append_lane_monsters:成长按 0 档(倍率 1.0),即原始属性。
			return BattleSimulator._fighter_from_def(def, cell_idx, team, cell_idx, GameConstants.CELL_COUNT)
		"boss":
			return BattleSimulator._fighter_from_def(def, cell_idx, team, cell_idx, GameConstants.CELL_COUNT)
		"formation":
			return BattleSimulator._fighter_from_def(def, cell_idx, team, cell_idx, GameConstants.CELL_COUNT, 1, false, true)
	return {}


# display_only=true:只组装单位和站位(编辑态预览用),跳过开战后处理,
# 保证编辑画面上的单位不带开场技能/护盾等战斗副作用。
static func build_test_state(config: Dictionary, display_only := false) -> Dictionary:
	RngService.rng.randomize()
	var player: Array = []
	var enemy: Array = []
	var by_slot := placements_by_slot(config)
	var ctx_list: Array = []
	for slot in 6:
		var team := "player" if slot < 3 else "enemy"
		var lane := slot % 3
		var treasures := slot_treasures(config, slot)
		var syn := _syn_for_slot(by_slot[slot])
		ctx_list.append({"treasures": treasures, "syn": syn})
		var out := player if slot < 3 else enemy
		for p in by_slot[slot]:
			var f := _fighter_for_placement(p, team)
			if f.is_empty():
				continue
			# 需求:全部单位统一用"棋子进战斗的起始位子"(96 个格点)。
			BattleSimulator._place_in_lane(f, int(p.get("cell", 0)), team, lane)
			f.uid = "test_s%d_c%d" % [slot, int(p.get("cell", 0))]
			f["owner_treasures"] = treasures
			f["owner_syn"] = syn
			f["owner_slot"] = slot
			out.append(f)

	# ---- 以下拷贝自 BattleSimulator.prepare_team_state()(原版改动需手动同步) ----
	var battle_log: Array[String] = []
	battle_log.append("单位测试:我方 %d 个单位,敌方 %d 个单位。" % [player.size(), enemy.size()])
	var state := {"kind": TEST_KIND, "player": player, "enemy": enemy, "elapsed": 0.0, "next_decay": BattleSimulator.DECAY_START_SEC, "finished": false, "log": battle_log, "player_syn": {}, "enemy_deaths": 0, "total_deaths": 0, "field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0, "undead_trait_death_counter": 0, "race_trait_processed_deaths": {}, "death_history": [], "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0, "kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0, "temporary_deaths": [], "visual_events": [], "unit_stats": {}}
	state.team_heal_ally = BattleSimulator._team_formation_heal_total(ctx_list.slice(0, 3))
	state.team_heal_rival = BattleSimulator._team_formation_heal_total(ctx_list.slice(3, 6))
	var owner_syn_by_key: Dictionary = {}
	for lane in 3:
		owner_syn_by_key["player_%d" % lane] = (ctx_list[lane] as Dictionary).syn
		owner_syn_by_key["enemy_%d" % lane] = (ctx_list[3 + lane] as Dictionary).syn
	state.owner_syn_by_key = owner_syn_by_key
	state.owner_state = {}
	if display_only:
		return state
	if player.is_empty():
		state.finished = true
		state.forced_result = {"player_wins": false, "reason": "no_player_units", "log": ["我方没有单位。"]}
		return state
	if enemy.is_empty():
		state.finished = true
		state.forced_result = {"player_wins": true, "reason": "no_enemy_units", "log": ["敌方没有单位。"]}
		return state
	for f in (player + enemy):
		if BattleSimulator._ignores_treasure(f):
			continue
		if BattleSimulator._f_has_set(f, "defense"):
			f.max_hp = maxi(1, int(round(float(f.max_hp) * 1.30)))
			f.hp = int(f.max_hp)
			f.defense = maxi(0, int(round(float(f.defense) * 1.30)))
			f.dodge = float(f.get("dodge", 0.0)) + 0.15
		if bool(BattleSimulator._f_syn(f).get("human_shield", false)):
			f.shield = maxi(int(f.get("shield", 0)), int(float(f.get("max_hp", 1)) * 0.08))
		if bool(BattleSimulator._f_syn(f).get("god_invulnerable_opening", false)):
			StatusEffectService.add_status(f, "invulnerable", 1.5, {})
	BattleSimulator._init_unit_stats(state)
	DamageService.set_stat_state(state)
	BattleSimulator._apply_opening_unit_skills(player, enemy, battle_log, state)
	BattleSimTreasures._apply_opening_treasures(player, battle_log)
	BattleSimTreasures._apply_opening_treasures(enemy, battle_log)
	return state
	# ---- 拷贝段结束 ----


# 与 BattleSimulator.compute_team_replay_async 同构,只是状态来自 build_test_state,
# 模拟/录制全部引用原版 static。
static func compute_test_replay_async(config: Dictionary, budget_usec: int = 8000) -> Dictionary:
	var state := build_test_state(config)
	var roster: Dictionary = {}
	var frames: Array = []
	BattleSimulator._replay_capture_roster(state, roster)
	var steps := 0
	var tree := Engine.get_main_loop() as SceneTree
	var slice_start := Time.get_ticks_usec()
	while not bool(state.get("finished", false)) and steps < 4000:
		BattleSimulator.step_state(state)
		steps += 1
		BattleSimulator._replay_capture_roster(state, roster)
		BattleSimulator._replay_capture_frame(state, frames)
		if tree != null and Time.get_ticks_usec() - slice_start > budget_usec:
			await tree.process_frame
			slice_start = Time.get_ticks_usec()
	return BattleSimulator._team_replay_payload(state, roster, frames)


# 编辑器格点的模拟坐标 = BattleSimShared._place_in_lane 的同款公式
# (slot 的 4x4 棋盘格 -> lane 内战场坐标),保证测试站位与真实对局一致。
static func grid_sim_pos(slot: int, cell: int) -> Vector2:
	var team := "player" if slot < 3 else "enemy"
	var lane := slot % 3
	var col := cell % GameConstants.BOARD_COLUMNS
	var row := floori(float(cell) / float(GameConstants.BOARD_COLUMNS))
	var lane_x: float = BattleSimulator.TEAM_LANE_CENTERS[lane] + (float(col) - 1.5) * 24.0
	var y := BattleSimulator._opening_y(team, 300.0 + float(row) * 40.0 if team == "player" else 220.0 - float(row) * 40.0)
	return Vector2(clampf(lane_x, 80.0, BattleSimulator.ARENA_W - 80.0), clampf(y, 60.0, BattleSimulator.ARENA_H - 60.0))
