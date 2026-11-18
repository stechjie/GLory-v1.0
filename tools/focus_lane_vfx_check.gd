extends SceneTree

# 显示优先：玩家自己正在打的路（11.13）。
# Run with: Godot --headless --path . --script res://tools/focus_lane_vfx_check.gd
#
# 用户口径：「显示主要是玩家自己的要优先，比如玩家是中间的，就中间的需要优先，打完中间后开的
# 旁边的路就也要优先」。全部走生产入口（BattleVfx._refresh_battle_vfx / cue_play_basic_attack /
# _play_boss_procedural / _spawn_hit_number / _unit_audio_context），钉住：
#
#   1. 「正在打的路」= 自己那一路 + 自己还活着的棋子现在站着的路（按位置，不按出生的路）；
#      没有自己的棋子（观战另一队）时为空。决赛三路上下排开，按 y 分路。
#   2. 小特效名额：别的路最多用 VFXBlockRoot.OFF_FOCUS_LIGHT_SHARE，其余留给正在打的路；
#      生产入口里别的路的普攻在那条线上被省，自己的照出。技能不受影响。
#   3. 群体技能先画正在打的路上的目标，一一对应的数组跟着换序；4 个以内原样不动。
#   4. 伤害数字池满时别的路的数字不顶掉正在打的路的；正在打的路的数字先顶别的路的。
#   5. 音效 off_focus 跟着位置走：棋子走进旁边的路，那一路的声音不再被压低。

const Harness := preload("res://tools/CheckHarness.gd")
const MID_X := 500.0
const LEFT_X := 230.0
const RIGHT_X := 770.0

var h := Harness.new("focus_lane_vfx")
var _factory: Script
var _block_script: Script
# 模拟脚本运行期 load：--script 的主脚本在解析期认不到 autoload（GameState），直接写
# BattleSimShared 会让整族模拟脚本编译失败，连带生产代码里的调用也变成「函数不存在」。
var _shared: Script
var _fillers: Array = []
var _filler_parent: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
	root.get_node("DataRegistry").call("load_all")
	_factory = load("res://scripts/units/UnitFactory.gd")
	_block_script = load("res://effects/vfx3d/VFXBlockRoot.gd")
	_shared = load("res://scripts/battle/BattleSimShared.gd")
	var game_state := root.get_node("GameState")
	var network := root.get_node("NetworkService")
	var previous_team_mode: bool = game_state.get("team_mode")
	var previous_round: int = game_state.get("round_index")
	var previous_active: bool = network.get("team_active")
	var previous_tier: int = VFXQualityBudget.tier
	game_state.set("team_mode", true)
	game_state.set("round_index", 3)
	network.set("team_active", false)
	VFXQualityBudget.tier = VFXQualityBudget.Tier.MEDIUM
	_filler_parent = Node3D.new()
	root.add_child(_filler_parent)
	await _check_focus_lanes()
	await _check_final_round_lanes(game_state)
	await _check_light_share()
	await _check_basic_attack_priority()
	await _check_target_order()
	await _check_hit_numbers()
	await _check_audio_focus()
	VFXQualityBudget.tier = previous_tier
	game_state.set("team_mode", previous_team_mode)
	game_state.set("round_index", previous_round)
	network.set("team_active", previous_active)
	h.finish(self)


# ── 1. 正在打的路 ─────────────────────────────────────────────────────────

func _check_focus_lanes() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var mine_a := _fighter("p_mine_a", "human_swordsman", "player", 1, 0, Vector2(MID_X - 20.0, 330.0))
	var mine_b := _fighter("p_mine_b", "human_archer", "player", 1, 0, Vector2(MID_X + 20.0, 360.0))
	var mate := _fighter("p_mate", "human_swordsman", "player", 0, 1, Vector2(LEFT_X, 330.0))
	var foe := _fighter("e_foe", "human_swordsman", "enemy", 1, -1, Vector2(MID_X, 200.0))
	var state := {"player": [mine_a, mine_b, mate], "enemy": [foe], "visual_events": []}
	_seed(battle, state)
	h.expect(_focus(battle) == [1], "home_lane_only", "开局只有自己那一路（中路）优先（实际 %s）" % str(_focus(battle)))
	# 中路打完，自己的一个棋子走进右路：右路加进来，左路（只有队友）不加。
	mine_b["pos"] = Vector2(RIGHT_X, 300.0)
	battle.call("_refresh_battle_vfx", state)
	h.expect(_focus(battle) == [1, 2], "follows_own_pieces", "自己的棋子走进右路，右路也要优先、左路不要（实际 %s）" % str(_focus(battle)))
	# 那个棋子死了：右路退出，自己那一路一直在。
	mine_b["alive"] = false
	battle.call("_refresh_battle_vfx", state)
	h.expect(_focus(battle) == [1], "dead_piece_leaves", "走过去的棋子死了，那一路不再优先（实际 %s）" % str(_focus(battle)))
	mine_a["alive"] = false
	battle.call("_refresh_battle_vfx", state)
	h.expect(_focus(battle) == [1], "home_kept_when_all_dead", "自己的棋子全死了，自己那一路仍然优先（实际 %s）" % str(_focus(battle)))
	# 观战另一队：画面里没有自己的棋子，什么都不分先后。
	var rival := {"player": [mate], "enemy": [foe], "visual_events": []}
	battle.set("_state", rival)
	battle.call("_refresh_battle_vfx", rival)
	h.expect(_focus(battle).is_empty(), "no_focus_without_own_pieces", "没有自己的棋子时不该有优先的路（实际 %s）" % str(_focus(battle)))
	h.expect(not bool(battle.call("_world_off_focus", [Vector3(9.0, 0.0, 0.0)])), "nothing_off_focus_without_focus",
		"没有优先的路时，任何特效都不算「别的路」")
	# 分路判断和模拟的三路等宽一致；3D 坐标里的判断和模拟坐标的判断一致。
	battle.set("_state", state)
	battle.call("_refresh_battle_vfx", state)
	var lanes_ok := true
	var world_ok := true
	for lane in 3:
		var band: Vector2 = _shared.call("lane_band_x", lane)
		for x: float in [band.x + 2.0, (band.x + band.y) * 0.5, band.y - 2.0]:
			if int(battle.call("_sim_lane", Vector2(x, 300.0))) != lane:
				lanes_ok = false
			var world: Vector3 = battle.call("_sim_to_world_pos", Vector2(x, 300.0))
			if int(battle.call("_world_lane", world)) != lane:
				world_ok = false
	h.expect(lanes_ok, "sim_lane_matches_bands", "按位置分路要和 BattleSimShared.lane_band_x 的三路等宽一致")
	h.expect(world_ok, "world_lane_matches_sim", "3D 特效坐标的分路要和模拟坐标的分路一致")
	battle.queue_free()
	await process_frame


func _check_final_round_lanes(game_state: Node) -> void:
	game_state.set("round_index", int(game_state.get("FINAL_ROUND")))
	var setup := _battle()
	var battle: Control = setup.battle
	var ok := true
	for lane in 3:
		var y := float((_shared.get_script_constant_map()["FINAL_LANE_CENTERS_Y"] as Array)[lane])
		if int(battle.call("_sim_lane", Vector2(300.0, y))) != lane or int(battle.call("_sim_lane", Vector2(700.0, y + 30.0))) != lane:
			ok = false
	h.expect(ok, "final_round_lanes_by_y", "决赛三路上下排开，要按 y 分路")
	battle.queue_free()
	await process_frame
	game_state.set("round_index", 3)


# ── 2. 小特效名额：别的路最多用一部分 ────────────────────────────────────────

func _check_light_share() -> void:
	var light := VFXBlockRoot.BudgetClass.LIGHT
	var full_cap := VFXBlockRoot.light_cap(false)
	var share_cap := VFXBlockRoot.light_cap(true)
	h.expect(share_cap >= 1 and share_cap < full_cap, "share_smaller_than_cap",
		"别的路的上限（%d）应该小于整个小特效名额（%d）" % [share_cap, full_cap])
	var off_added := _fill(light, true)
	h.expect(off_added == share_cap, "off_focus_stops_at_share",
		"别的路只能占到 %d 个，实际占了 %d 个" % [share_cap, off_added])
	var focus_added := _fill(light, false)
	h.expect(focus_added == full_cap - share_cap, "focus_gets_the_rest",
		"别的路占满自己那份以后，正在打的路还要有 %d 个位置（实际 %d）" % [full_cap - share_cap, focus_added])
	VFXBlockRoot.begin_off_focus(true)
	var forced := VFXBlockRoot.spawn_block(_block_script, _filler_parent, true)
	VFXBlockRoot.end_off_focus()
	h.expect(forced != null, "skills_ignore_focus", "强制生成的技能不看是不是别的路")
	_fillers.append(forced)
	await _release_fillers()
	h.expect(VFXBlockRoot.gated_block_count(light) == 0 and VFXBlockRoot.off_focus_light_count() == 0, "light_released",
		"特效释放后名额要还回来（小特效 %d，其中别的路 %d）" % [VFXBlockRoot.gated_block_count(light), VFXBlockRoot.off_focus_light_count()])
	# 正在打的路先占了几个：别的路仍然有自己那一半（只要总数没满），不会被正在打的路挤掉。
	var focus_first := mini(4, full_cap - share_cap)
	for i in focus_first:
		VFXBlockRoot.begin_budget_class(light)
		_fillers.append(VFXBlockRoot.spawn_block(_block_script, _filler_parent))
		VFXBlockRoot.end_budget_class()
	var off_after_focus := _fill(light, true)
	h.expect(off_after_focus == share_cap, "off_focus_keeps_its_half",
		"正在打的路占了 %d 个以后，别的路仍然要能占满自己那 %d 个（实际 %d）" % [focus_first, share_cap, off_after_focus])
	await _release_fillers()
	# 正在打的路几乎占满：别的路只能用剩下的，总数不超过名额。
	_fill(light, false)
	h.expect(_fill(light, true) == 0 and VFXBlockRoot.gated_block_count(light) == full_cap, "total_never_exceeds_cap",
		"正在打的路占满名额时，别的路一个都不能再加")
	await _release_fillers()


func _check_basic_attack_priority() -> void:
	var light := VFXBlockRoot.BudgetClass.LIGHT
	var setup := _battle()
	var battle: Control = setup.battle
	var mine := _fighter("p_mine", "human_archer", "player", 1, 0, Vector2(MID_X, 360.0))
	mine["attack_count"] = 1
	var mid_foe := _fighter("e_mid", "human_swordsman", "enemy", 1, -1, Vector2(MID_X, 200.0))
	var other := _fighter("p_other", "human_archer", "player", 2, 2, Vector2(RIGHT_X, 360.0))
	other["attack_count"] = 1
	var side_foe := _fighter("e_side", "human_swordsman", "enemy", 2, -1, Vector2(RIGHT_X, 200.0))
	var state := {"player": [mine, other], "enemy": [mid_foe, side_foe], "visual_events": []}
	_seed(battle, state)
	# 别的路已经占满了它那一份。
	_fill(light, true)
	var before := VFXBlockRoot.gated_block_count(light)
	battle.call("cue_play_basic_attack", "p_other", "e_side", true)
	h.expect(VFXBlockRoot.gated_block_count(light) == before, "side_lane_attack_yields",
		"别的路占满自己那份以后，右路的普攻要被省掉（小特效 %d→%d）" % [before, VFXBlockRoot.gated_block_count(light)])
	battle.call("cue_play_basic_attack", "p_mine", "e_mid", true)
	h.expect(VFXBlockRoot.gated_block_count(light) > before, "own_lane_attack_plays",
		"同一时刻自己那一路的普攻要照出（小特效 %d→%d）" % [before, VFXBlockRoot.gated_block_count(light)])
	# 自己的棋子走进右路：右路的普攻也优先了。
	mine["pos"] = Vector2(RIGHT_X - 30.0, 300.0)
	battle.call("_refresh_battle_vfx", state)
	before = VFXBlockRoot.gated_block_count(light)
	battle.call("cue_play_basic_attack", "p_other", "e_side", true)
	h.expect(VFXBlockRoot.gated_block_count(light) > before, "opened_lane_attack_plays",
		"自己的棋子走进右路以后，右路的普攻也要优先（小特效 %d→%d）" % [before, VFXBlockRoot.gated_block_count(light)])
	await _release_fillers()
	battle.queue_free()
	await process_frame
	await process_frame


# ── 3. 群体技能先画正在打的路上的目标 ────────────────────────────────────────

func _check_target_order() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var mine := _fighter("p_mine", "human_swordsman", "player", 1, 0, Vector2(MID_X, 360.0))
	var foe := _fighter("e_foe", "human_swordsman", "enemy", 1, -1, Vector2(MID_X, 200.0))
	var state := {"player": [mine], "enemy": [foe], "visual_events": []}
	_seed(battle, state)
	var xs := [RIGHT_X, LEFT_X, RIGHT_X, MID_X, LEFT_X, MID_X + 30.0, RIGHT_X + 20.0]
	var targets: Array = []
	var nodes: Array = []
	for i in xs.size():
		targets.append(battle.call("_sim_to_world_pos", Vector2(float(xs[i]), 200.0 + float(i))))
		nodes.append("n%d" % i)
	var context := {"targets": targets.duplicate(), "target_nodes": nodes.duplicate(), "target_sim_uids": ["a", "b"]}
	battle.call("_focus_targets_first", context)
	var ordered: Array = context["targets"]
	var lanes: Array = []
	for value in ordered:
		lanes.append(int(battle.call("_world_lane", value)))
	h.expect(lanes.slice(0, 2) == [1, 1], "focus_targets_first", "中路的目标要排在最前面（实际按路 %s）" % str(lanes))
	h.expect(context["target_nodes"] == ["n3", "n5", "n0", "n1", "n2", "n4", "n6"], "parallel_arrays_follow",
		"和目标一一对应的数组要跟着同样换序（实际 %s）" % str(context["target_nodes"]))
	h.expect(context["target_sim_uids"] == ["a", "b"], "unrelated_arrays_untouched", "长度对不上的数组不能动")
	var small := {"targets": targets.slice(0, 4)}
	battle.call("_focus_targets_first", small)
	h.expect(small["targets"] == targets.slice(0, 4), "small_groups_untouched", "4 个以内谁都不会被截，原样不动")
	# 生产入口：特效根实际收到的目标顺序和「别的路」开关（换成只记账的替身）。
	var recorder_script := GDScript.new()
	recorder_script.source_code = "extends Node3D\nvar calls: Array = []\nfunc play(effect_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> Node3D:\n\tcalls.append({\"effect\": effect_id, \"context\": context, \"off_focus\": VFXBlockRoot.is_off_focus()})\n\treturn null\n"
	recorder_script.reload()
	var recorder: Node3D = recorder_script.new()
	battle.add_child(recorder)
	battle.set("_battle_3d_vfx_root", recorder)
	battle.call("_play_boss_procedural", "arrow_rain", targets[3], targets[3], {"targets": targets.duplicate(), "target_nodes": nodes.duplicate()})
	battle.call("_play_boss_procedural", "basic_attack_ranged_human", targets[0], targets[2], {})
	battle.call("_play_boss_procedural", "basic_attack_ranged_human", targets[0], targets[3], {})
	var calls: Array = recorder.get("calls")
	if h.expect(calls.size() == 3, "recorder_called", "特效根要收到 3 次调用（实际 %d）" % calls.size()):
		var received: Dictionary = (calls[0] as Dictionary)["context"]
		h.expect(received["target_nodes"] == ["n3", "n5", "n0", "n1", "n2", "n4", "n6"], "play_receives_focus_first",
			"群体技能交给特效的目标要中路在前（实际 %s）" % str(received["target_nodes"]))
		h.expect(bool((calls[1] as Dictionary)["off_focus"]) and not bool((calls[2] as Dictionary)["off_focus"]), "play_marks_off_focus",
			"起点和落点都在别的路才算「别的路」；落点在中路就不算")
	battle.queue_free()
	await process_frame


# ── 4. 伤害数字 ─────────────────────────────────────────────────────────────

func _check_hit_numbers() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var mine := _fighter("p_mine", "human_swordsman", "player", 1, 0, Vector2(MID_X, 360.0))
	var foe := _fighter("e_foe", "human_swordsman", "enemy", 1, -1, Vector2(MID_X, 200.0))
	var state := {"player": [mine], "enemy": [foe], "visual_events": []}
	_seed(battle, state)
	var pool_size := int(battle.get("_HIT_NUMBER_POOL_SIZE"))
	for i in pool_size:
		battle.call("_spawn_hit_number", Vector2(400.0, 300.0), 100 + i, "dmg", false, false, "", false)
	var focus_texts := _number_texts(battle)
	battle.call("_spawn_hit_number", Vector2(400.0, 300.0), 7777, "dmg", false, false, "", true)
	h.expect(_number_texts(battle) == focus_texts, "off_focus_never_evicts_focus",
		"数字池全是正在打的路的数字时，别的路的数字不该顶掉它们")
	battle.call("_spawn_hit_number", Vector2(400.0, 300.0), 8888, "dmg", false, false, "", false)
	h.expect("8888" in _number_texts(battle), "focus_number_still_shows", "正在打的路的数字照样能显示（顶掉最早的那个）")
	# 池子里有别的路的数字：正在打的路的新数字先顶它。
	_hide_numbers(battle)
	for i in pool_size:
		battle.call("_spawn_hit_number", Vector2(400.0, 300.0), 200 + i, "dmg", false, false, "", i != 5)
	var kept_focus := str((battle.get("_hit_number_pool")[5] as Label).text)
	battle.call("_spawn_hit_number", Vector2(400.0, 300.0), 9999, "dmg", false, false, "", false)
	h.expect(str((battle.get("_hit_number_pool")[5] as Label).text) == kept_focus and "9999" in _number_texts(battle),
		"focus_evicts_off_focus_first", "正在打的路的数字要先顶掉别的路的，而不是顶掉自己这边的")
	# 有空位时别的路的数字照常显示。
	_hide_numbers(battle)
	battle.call("_spawn_hit_number", Vector2(400.0, 300.0), 4321, "dmg", false, false, "", true)
	h.expect("4321" in _number_texts(battle), "off_focus_shows_when_room", "数字池有空位时，别的路的数字照常显示")
	battle.queue_free()
	await process_frame


# ── 5. 音效 ─────────────────────────────────────────────────────────────────

func _check_audio_focus() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var mine := _fighter("p_mine", "human_swordsman", "player", 1, 0, Vector2(MID_X, 360.0))
	var side := _fighter("p_side", "human_archer", "player", 2, 2, Vector2(RIGHT_X, 360.0))
	var state := {"player": [mine, side], "enemy": [], "visual_events": []}
	_seed(battle, state)
	var before: Dictionary = battle.call("_unit_audio_context", "p_side", "skill")
	h.expect(bool(before.get("off_focus", false)), "side_audio_off_focus", "右路的声音在只打中路时要算「别的路」")
	h.expect(not bool((battle.call("_unit_audio_context", "p_mine", "skill") as Dictionary).get("off_focus", true)),
		"own_audio_in_focus", "自己那一路的声音不算「别的路」")
	mine["pos"] = Vector2(RIGHT_X - 30.0, 300.0)
	battle.call("_refresh_battle_vfx", state)
	var after: Dictionary = battle.call("_unit_audio_context", "p_side", "skill")
	h.expect(not bool(after.get("off_focus", true)), "audio_follows_opened_lane",
		"自己的棋子走进右路以后，右路的声音不再被压低")
	battle.queue_free()
	await process_frame


# ── 工具 ─────────────────────────────────────────────────────────────────

func _focus(battle: Control) -> Array:
	var lanes: Array = (battle.get("_focus_lanes") as Dictionary).keys()
	lanes.sort()
	return lanes


func _fill(budget_class: int, off_focus: bool) -> int:
	var added := 0
	VFXBlockRoot.begin_budget_class(budget_class)
	VFXBlockRoot.begin_off_focus(off_focus)
	while added < 400:
		var filler := VFXBlockRoot.spawn_block(_block_script, _filler_parent)
		if filler == null:
			break
		_fillers.append(filler)
		added += 1
	VFXBlockRoot.end_off_focus()
	VFXBlockRoot.end_budget_class()
	return added


func _release_fillers() -> void:
	for filler in _fillers:
		if is_instance_valid(filler):
			(filler as Node).queue_free()
	_fillers.clear()
	await process_frame
	await process_frame


func _number_texts(battle: Control) -> Array:
	var out: Array = []
	for lbl: Label in battle.get("_hit_number_pool"):
		if lbl.visible:
			out.append(lbl.text)
	return out


func _hide_numbers(battle: Control) -> void:
	for lbl: Label in battle.get("_hit_number_pool"):
		if lbl.has_meta("hit_tween"):
			var tween: Variant = lbl.get_meta("hit_tween")
			if tween is Tween and (tween as Tween).is_valid():
				(tween as Tween).kill()
		lbl.visible = false
	battle.set("_hit_number_cursor", 0)


func _battle() -> Dictionary:
	var battle: Control = (load("res://scenes/battle/BattleVfx.gd") as Script).new()
	root.add_child(battle)
	var arena := Control.new()
	arena.size = Vector2(1000.0, 520.0)
	battle.add_child(arena)
	battle.set("_arena", arena)
	var route: Node3D = (load("res://effects/BossProceduralVFX3D.gd") as Script).new()
	battle.add_child(route)
	battle.set("_battle_3d_vfx_root", route)
	return {"battle": battle, "route": route}


func _seed(battle: Control, state: Dictionary) -> void:
	battle.set("_state", state)
	battle.call("_refresh_battle_vfx", state)
	battle.call("_refresh_battle_vfx", state)


func _fighter(uid: String, unit_id: String, team: String, lane: int, owner_slot: int, pos: Vector2) -> Dictionary:
	var definition: Dictionary = {"id": unit_id}
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/race_units.json"))
	for value: Dictionary in parsed.get("units", []):
		if str(value.get("id", "")) == unit_id:
			definition = _factory.call("apply_star_stats", value, 1)
	return {"uid": uid, "id": unit_id, "name": str(definition.get("name", "")), "team": team, "lane": lane,
		"owner_slot": owner_slot, "hp": 1000, "max_hp": 1000, "shield": 0, "alive": true, "pos": pos,
		"def": definition, "statuses": {}, "range_px": 32.0 + maxf(0.0, float(definition.get("range", 1)) - 1.0) * 72.0,
		"skill_ready": 0.0, "attack_count": 0, "star": 1, "vfx_attack_target_uid": "", "vfx_skill_target_uid": ""}
