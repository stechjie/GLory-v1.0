class_name OfficeTestSim
extends RefCounted

const UnitGrowth := preload("res://scripts/units/UnitGrowth.gd")

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
	for slot in 6:
		(out[slot] as Array).sort_custom(func(a, b): return int(a.get('cell', 0)) < int(b.get('cell', 0)))
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


# 人王「战后存活 ⇒ 增加属性」的层数，记在摆放字典上（就地改，位置不动）。
# ★ 重摆 / 改星会经过 `set_placement` 重建字典 → 层数归零，这是有意的：
#   星变了两套上限也不同（1~3 星 5 层 / 4 星 8 层），沿用旧层数会算错。
static func set_king_growth(config: Dictionary, slot: int, cell: int, stacks: int) -> void:
	var p := placement_at(config, slot, cell)
	if p.is_empty():
		return
	p["king_growth_stacks"] = maxi(0, stacks)


static func side_unit_count(config: Dictionary, team_a: bool) -> int:
	var n := 0
	for p in config.get("placements", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var slot := int(p.get("slot", -1))
		var wanted := GameConstants.TEAM_RED if team_a else GameConstants.TEAM_BLUE
		if slot >= 0 and slot < 6 and GameConstants.team_of_slot(slot) == wanted:
			n += 1
	return n


# 与 SynergyService.count_races_from_board 同口径:只有普通棋子计入种族羁绊。
static func _syn_for_slot(slot_placements: Array) -> Dictionary:
	var counts := {"god": 0, "dark": 0, "undead": 0, "human": 0, "crimson": 0}
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
	# 人王「战后存活 ⇒ 生命 / 攻击 / 防御成长」的层数重放。
	#
	# 正式局：每活一场 UnitGrowth.grow_king（层数 +1、倍率 ×(1+当前星级成长率)，到顶不长），
	# 开战时 BattleSimShared._fighter_from_cell 把倍率乘到 hp / atk / def 上。离线自测把层数记在
	# 摆放字典上，这里按同一份规则重放到 def —— 属性面板 / 长按详情看到的才是真的加成后的数值。
	var stacks := int(p.get("king_growth_stacks", 0))
	if stacks > 0:
		var probe := {"def": def, "star": star_for_placement(p)}
		for _i in stacks:
			UnitGrowth.grow_king(probe)
		UnitGrowth.apply_to_def(def, UnitGrowth.king_mult(probe))
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
	if config.has("shared_seed"):
		RngService.seed_from_parts([config.get("shared_seed"), int(config.get("round_index", GameState.round_index)), "pvp"])
	else:
		RngService.rng.randomize()
	var player: Array = []
	var enemy: Array = []
	var by_slot := placements_by_slot(config)
	var ctx_list: Array = []
	# 对手棋盘镜不镜像跟正式战斗同一条规则（普通 PvP 不镜像：正上方对正下方）。
	var mirror_enemy := BattleSimulator.mirror_enemy_for(TEST_KIND, false)
	for slot in 6:
		var is_red := GameConstants.team_of_slot(slot) == GameConstants.TEAM_RED
		var team := "player" if is_red else "enemy"
		var lane := slot % GameConstants.TEAM_SIDE_SIZE
		var treasures := slot_treasures(config, slot)
		var syn := _syn_for_slot(by_slot[slot])
		ctx_list.append({"treasures": treasures, "syn": syn})
		var out := player if is_red else enemy
		for p in by_slot[slot]:
			if str(p.get("kind", "piece")) == "merc":
				continue
			var f := _fighter_for_placement(p, team)
			if f.is_empty():
				continue
			# 需求:全部单位统一用"棋子进战斗的起始位子"(96 个格点)。
			BattleSimulator._place_in_lane(f, int(p.get("cell", 0)), team, lane, mirror_enemy)
			f.uid = "%s_L%d_%d" % [team, lane, int(p.get("cell", 0))]
			var owns_board_effects := str(p.get("kind", "piece")) == "piece"
			f["owner_treasures"] = treasures if owns_board_effects else []
			f["owner_syn"] = syn if owns_board_effects else {}
			f["owner_slot"] = slot
			f["owner_pet"] = str(config.get("slot_pets", {}).get(slot, "")) if owns_board_effects else ""
			f["owner_gold"] = maxi(0, int(config.get("slot_gold", {}).get(slot, 0))) if owns_board_effects else 0
			out.append(f)
	# 联机先加入三路棋盘棋子，再加入佣兵；佣兵不继承主人羁绊、宝藏或宠物。
	for slot in 6:
		var is_red := GameConstants.team_of_slot(slot) == GameConstants.TEAM_RED
		var team := "player" if is_red else "enemy"
		var lane := slot % GameConstants.TEAM_SIDE_SIZE
		var out := player if is_red else enemy
		var merc_index := 0
		for p in by_slot[slot]:
			if str(p.get("kind", "piece")) != "merc":
				continue
			var f := _fighter_for_placement(p, team)
			if f.is_empty():
				continue
			BattleSimulator._place_in_lane(f, int(p.get("cell", 0)), team, lane, mirror_enemy)
			f.slot = GameConstants.CELL_COUNT + merc_index
			f.uid = "%s_L%d_merc%d" % [team, lane, merc_index]
			f["owner_treasures"] = []
			f["owner_syn"] = {}
			f["owner_slot"] = slot
			f["owner_pet"] = ""
			f["owner_gold"] = 0
			out.append(f)
			merc_index += 1

	# ---- 以下拷贝自 BattleSimulator.prepare_team_state()(原版改动需手动同步) ----
	var battle_log: Array[String] = []
	battle_log.append("单位测试:我方 %d 个单位,敌方 %d 个单位。" % [player.size(), enemy.size()])
	var state := {"kind": TEST_KIND, "player": player, "enemy": enemy, "elapsed": 0.0, "next_sudden_death_tick": BattleFrenzyService.SUDDEN_DEATH_SEC, "finished": false, "log": battle_log, "player_syn": {}, "enemy_deaths": 0, "total_deaths": 0, "field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0, "race_trait_processed_deaths": {}, "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0, "kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0, "temporary_deaths": [], "visual_events": [], "unit_stats": {}}
	state["ally_slots"] = [0, 1, 2]
	state["rival_slots"] = [3, 4, 5]
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
	BattleSimulator._finalize_team_opening(state)
	return state
	# ---- 拷贝段结束 ----


# 与 BattleSimulator.compute_team_replay_async 同构,只是状态来自 build_test_state,
# 模拟/录制全部引用原版 static。
#
# 9.29 用户复报「面板攻速不实时」第三问：离线自测的「开始测试」走的是**先录帧后回放**
# （本函数 + BattleScreen._apply_replay_frame），而回放帧是 **13 列冻结结构**
# （uid/pos/hp/alive/attack_count/skill_ready/shield/skill_stacks/statuses/damage_dealt/...），
# **没有 atk / attack_speed / defense / crit_bonus** ⇒ 回放侧的 fighter 永远只有 def 基准值，
# 面板的「攻击 / 攻速 / 防御 / 暴击」就恒等于面板打开前的那份基准（大祭司被队友强化到
# 28/1.05，面板仍显示 26/0.90 就是这么来的）。
# 修复：**不能给 frames 加列**（改冻结哈希、联机回放会漂），所以在这条**离线自测专用**
# 录制循环里另带一份「活字段旁路快照」 live_stats：uid -> [ {f,atk,as,df,cb}, ... ]，
# 只在数值真正变化的那一帧记一条。OfficeTestScreen 播放时查「≤ 当前帧的最近一条」
# 补进面板副本。联机回放没有这份旁路 → 空字典 → 面板原样走 def 基准，行为不变。
static func compute_test_replay_async(config: Dictionary, budget_usec: int = 8000) -> Dictionary:
	var state := build_test_state(config)
	var roster: Dictionary = {}
	var frames: Array = []
	# 和 BattleSimulator 的回放循环一样，捕获每帧的视觉事件（母灵处决 / 屏震 /
	# 技能演出），否则 officetest 回放里这些只在 live sim 出现的事件会全部丢失。
	var frame_events: Array = []
	# 活字段旁路快照（离线自测专用，见上注释）。键 = uid，值 = 按帧升序的变化记录。
	var live_stats: Dictionary = {}
	var last_live: Dictionary = {}
	BattleSimulator._replay_capture_roster(state, roster)
	var steps := 0
	var tree := Engine.get_main_loop() as SceneTree
	var slice_start := Time.get_ticks_usec()
	while not bool(state.get("finished", false)) and steps < 4000:
		BattleSimulator.step_state(state)
		steps += 1
		BattleSimulator._replay_capture_roster(state, roster)
		BattleSimulator._replay_capture_frame(state, frames, frame_events)
		_capture_live_stats(state, frames.size() - 1, live_stats, last_live)
		if tree != null and Time.get_ticks_usec() - slice_start > budget_usec:
			await tree.process_frame
			slice_start = Time.get_ticks_usec()
	var payload: Dictionary = BattleSimulator._team_replay_payload(state, roster, frames, frame_events)
	if not live_stats.is_empty():
		payload["live_stats"] = live_stats
	return payload


# 逐帧比对活字段（atk / attack_speed / defense / crit_bonus / 赤潮与符文层数），变了才记一条。
# 与 frames 的索引严格对齐：调用点传进来的 frame_index 就是 _replay_capture_frame 刚写
# 进去的那一帧下标（frames.size()-1），面板用它做「≤ 当前帧取最近一条」的查询。
static func _capture_live_stats(state: Dictionary, frame_index: int, live_stats: Dictionary, last_live: Dictionary) -> void:
	for f: Dictionary in (state.get("player", []) + state.get("enemy", [])):
		var uid := str(f.get("uid", ""))
		if uid.is_empty():
			continue
		var atk := int(f.get("atk", 0))
		var aspd := float(f.get("attack_speed", 0.0))
		var dfn := int(f.get("defense", 0))
		var cb := float(f.get("crit_bonus", 0.0))
		var cps := int(f.get("crimson_pulse_stacks", 0))
		var crs := CrimsonRuneService.stack_count(f)
		var prev: Variant = last_live.get(uid, null)
		var changed := true
		if typeof(prev) == TYPE_ARRAY and (prev as Array).size() == 6:
			var p: Array = prev
			changed = int(p[0]) != atk or absf(float(p[1]) - aspd) > 1e-6 \
				or int(p[2]) != dfn or absf(float(p[3]) - cb) > 1e-6 or int(p[4]) != cps or int(p[5]) != crs
		if not changed:
			continue
		last_live[uid] = [atk, aspd, dfn, cb, cps, crs]
		if not live_stats.has(uid):
			live_stats[uid] = []
		(live_stats[uid] as Array).append({
			"f": int(frame_index),
			"atk": atk,
			"as": aspd,
			"df": dfn,
			"cb": cb,
			"cps": cps,
			"crs": crs,
		})


# 编辑器格点的模拟坐标 = BattleSimShared._place_in_lane 的同款公式
# (slot 的 4x4 棋盘格 -> lane 内战场坐标),保证测试站位与真实对局一致。
static func grid_sim_pos(slot: int, cell: int) -> Vector2:
	var team := "player" if GameConstants.team_of_slot(slot) == GameConstants.TEAM_RED else "enemy"
	var lane := slot % GameConstants.TEAM_SIDE_SIZE
	return BattleSimulator.board_cell_pos(cell, team, float(BattleSimulator.TEAM_LANE_CENTERS[lane]),
		BattleSimulator.mirror_enemy_for(TEST_KIND, false))
