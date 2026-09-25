extends Node

# 9.25 萝卜 / 四星教学（方案 B）的逻辑门禁：不建备战页，用 fake provider 驱动
# TutorialMode，经济动作全部走生产代码里的同一批 GameState 函数。
#
# 覆盖：
#   * 步骤顺序：FORMATION_HP -> CARROT_CAMP -> HARVEST_UPGRADE -> START_BOSS ->
#     TAKE_TREASURE_2 -> CARROT_HARVEST -> DRAW_STONE -> FOUR_STAR -> HIRE_MERC
#   * 「强制按顺序」：每个萝卜动作只在对应那一步放行（allows_carrot_action）
#   * 收获一次（升级后的产量）、领 100 萝卜、固定抽到与 3 星民兵同属性的石头
#   * 断点：萝卜 / 石头 / 收获标记原样恢复；旧版本（1）断点被拒收
#   * 防卡死：3 星民兵被卖掉、萝卜不够时的补偿
#
# 跑法：godot --headless --path . res://tools/tutorial_carrot_flow_check.tscn
# （与 tools/*_check.tscn 同一种场景入口；也可以用 tools/run_check.ps1 -Name tutorial_carrot_flow）

const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const ProviderScript := preload("res://scripts/tutorial/TutorialTargetProvider.gd")
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")

var _fails := 0
var _passes := 0
var _harvest_action_calls := 0
var _host: Control
var _fake: ProviderScript
# 这条检查会写真实的教学断点文件：开始前整份快照，结束逐字还原（与 tutorial_checkpoint_check 同一做法）。
var _tutorial_file_existed := false
var _saved_tutorial_bytes := PackedByteArray()


func _ready() -> void:
	await get_tree().process_frame
	_tutorial_file_existed = FileAccess.file_exists(SaveManager.TUTORIAL_PATH)
	if _tutorial_file_existed:
		_saved_tutorial_bytes = FileAccess.get_file_as_bytes(SaveManager.TUTORIAL_PATH)
	_host = Control.new()
	_host.size = Vector2(1600, 720)
	add_child(_host)
	_fake = ProviderScript.new("FakeProvider", _host)
	for target_id in ProviderScript.required_target_ids():
		var b := Button.new()
		b.name = str(target_id)
		b.position = Vector2(700, 300)
		b.size = Vector2(120, 60)
		_host.add_child(b)
		_fake.bind_target(str(target_id), func(): return b)
	_fake.bind_action(ProviderScript.ACTION_CLOSE_MERCENARY, func(): pass)
	_fake.bind_action(ProviderScript.ACTION_REFRESH_VIEW, func(): pass)
	_fake.bind_action(ProviderScript.ACTION_PLAY_CARROT_HARVEST, func(): _harvest_action_calls += 1)
	_fake.bind_feedback(func(_t): pass)

	_check_sequence()
	await _check_happy_path()
	await _check_checkpoint_roundtrip()
	await _check_recovery()

	TutorialMode.finish()
	GameState.reset_run()
	_restore_tutorial_file()
	print("tutorial_carrot_flow_check: %d passed, %d failed" % [_passes, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _restore_tutorial_file() -> void:
	if _tutorial_file_existed:
		var f := FileAccess.open(SaveManager.TUTORIAL_PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_saved_tutorial_bytes)
			f.close()
	elif FileAccess.file_exists(SaveManager.TUTORIAL_PATH):
		DirAccess.remove_absolute(SaveManager.TUTORIAL_PATH)


func _expect(ok: bool, name: String, detail: String) -> bool:
	if ok:
		_passes += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		_fails += 1
		print("FAIL  %s  %s" % [name, detail])
	return ok


func _check_sequence() -> void:
	var seq: Array = TutorialScript.STEP_SEQUENCE
	var S = TutorialScript.Step
	var expected := [S.BUY_3, S.PLACE_3, S.START_PVE_1, S.UPGRADE_2, S.START_PVE_2,
		S.TAKE_TREASURE_1, S.UPGRADE_3, S.UPGRADE_OTHERS, S.BOND_HINT, S.VIEW_TREASURE,
		S.FORMATION_HP, S.CARROT_CAMP, S.HARVEST_UPGRADE, S.START_BOSS, S.TAKE_TREASURE_2,
		S.CARROT_HARVEST, S.DRAW_STONE, S.FOUR_STAR, S.HIRE_MERC, S.FILL_7,
		S.FORMATION_HP, S.START_PVP]
	_expect(seq == expected, "sequence", "%d 步" % seq.size())
	_expect(TutorialScript.CHECKPOINT_VERSION == 2, "checkpoint_version", str(TutorialScript.CHECKPOINT_VERSION))


# 把教程摆到「第一次讲完法阵 HP」：棋盘上一个 3 星民兵 + 若干棋子，已有 1 件宝藏。
func _arrive_at_formation_hp() -> void:
	TutorialMode.start()
	GameState.board_slots[5] = _cell("human_militia", 3)
	GameState.board_slots[6] = _cell("human_archer", 2)
	GameState.board_slots[7] = _cell("human_merchant", 2)
	GameState.owned_treasures.append("def_iron_wall")
	TutorialMode.attach(_fake)
	# 真实推进：沿序列一步步走到第 11 步（FORMATION_HP），让进度指针一致。
	for s in [TutorialScript.Step.PLACE_3, TutorialScript.Step.START_PVE_1, TutorialScript.Step.UPGRADE_2,
			TutorialScript.Step.START_PVE_2, TutorialScript.Step.TAKE_TREASURE_1, TutorialScript.Step.UPGRADE_3,
			TutorialScript.Step.UPGRADE_OTHERS, TutorialScript.Step.BOND_HINT, TutorialScript.Step.VIEW_TREASURE,
			TutorialScript.Step.FORMATION_HP]:
		TutorialMode._advance_to(s)
	TutorialMode.update_overlay()


func _cell(id: String, star: int) -> Dictionary:
	var def: Dictionary = {}
	for u in DataRegistry.get_table("race_units").get("units", []):
		if str(u.get("id", "")) == id:
			def = (u as Dictionary).duplicate(true)
	return {"id": id, "uid": GameState.mint_piece_uid(), "star": star, "def": def}


func _tap() -> void:
	TutorialMode._on_hotspot_pressed()


# 与 PrepBoardController.request_upgrade_stone_draw 的本地结算同一串调用。
func _draw_like_prep() -> bool:
	if GameState.tutorial_mode and not TutorialMode.allows_carrot_action("draw_stone"):
		return false
	if not GameState.can_draw_upgrade_stone(GameState.round_index):
		return false
	var cost := GameState.upgrade_stone_draw_cost()
	if GameState.carrots < cost:
		return false
	GameState.carrots -= cost
	GameState.stone_draw_used_round = GameState.round_index
	GameState.stone_draw_count += 1
	GameState.apply_team_stone(TutorialMode.forced_stone_type())
	TutorialMode.sync()
	return true


func _militia() -> Dictionary:
	for c in GameState.board_slots + GameState.bench_slots:
		if typeof(c) == TYPE_DICTIONARY and str(c.get("id", "")) == "human_militia":
			return c
	return {}


func _check_happy_path() -> void:
	_arrive_at_formation_hp()
	_expect(not TutorialMode.carrot_ui_unlocked(), "carrot_ui_hidden_before", "萝卜入口在萝卜教学前隐藏")
	_expect(not TutorialMode.allows_carrot_action("harvest_upgrade"), "gate_harvest_early", "升级采集不能提前")
	_tap()
	_expect(TutorialMode.step == TutorialScript.Step.CARROT_CAMP, "formation_to_camp", TutorialMode.step_key())
	_expect(TutorialMode.carrot_ui_unlocked(), "carrot_ui_shown", "萝卜入口出现")
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_CARROT_CAMP, "target_camp", TutorialMode._carrot_target_id())

	# 开营地
	TutorialMode.record_carrot_camp_state(true, TutorialScript.CAMP_PAGE_CAMP)
	_expect(TutorialMode.step == TutorialScript.Step.HARVEST_UPGRADE, "camp_open_advances", TutorialMode.step_key())
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_HARVEST_UPGRADE, "target_harvest", TutorialMode._carrot_target_id())
	_expect(TutorialMode.allows_carrot_action("harvest_upgrade"), "gate_harvest_open", "此刻可以升级采集")
	_expect(not TutorialMode.allows_carrot_action("draw_stone"), "gate_draw_closed", "此刻不能抽石头")
	_expect(not TutorialMode.allows_carrot_action("hire_merc"), "gate_merc_closed", "此刻不能雇佣兵")
	# 第 1 回合也能升级（教学放开了回合门槛）
	var gold_before := GameState.gold
	var up := GameState.upgrade_harvest_tech()
	_expect(bool(up.get("ok", false)) and GameState.harvest_tech_level == 1 and GameState.gold == gold_before - CarrotEconomy.tech_price(0),
		"harvest_upgrade_round1", "round=%d level=%d gold %d->%d" % [GameState.round_index, GameState.harvest_tech_level, gold_before, GameState.gold])
	TutorialMode.sync()
	_expect(TutorialMode.step == TutorialScript.Step.HARVEST_UPGRADE, "stay_until_closed", "升级后要关营地才推进")
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_CARROT_CLOSE, "target_close", TutorialMode._carrot_target_id())
	_expect(not TutorialMode.allows_carrot_action("harvest_upgrade"), "gate_harvest_once", "升级只允许一次")
	TutorialMode.record_carrot_camp_state(false, TutorialScript.CAMP_PAGE_CAMP)
	_expect(TutorialMode.step == TutorialScript.Step.START_BOSS, "close_to_boss", TutorialMode.step_key())

	# 打 Boss -> 选第 2 件宝藏
	_expect(TutorialMode.begin_battle(), "boss_battle_allowed", "")
	TutorialMode.after_battle({})
	TutorialMode.attach(_fake)
	_expect(TutorialMode.step == TutorialScript.Step.TAKE_TREASURE_2, "boss_to_treasure", TutorialMode.step_key())
	_expect(GameState.carrots == 0, "no_harvest_yet", "选宝藏前还没收获：%d" % GameState.carrots)
	GameState.owned_treasures.append("atk_fury_roster")
	_harvest_action_calls = 0
	TutorialMode.sync()
	var production := CarrotEconomy.total_production(1, 0)
	_expect(TutorialMode.step == TutorialScript.Step.CARROT_HARVEST, "treasure_to_harvest", TutorialMode.step_key())
	_expect(GameState.carrots == production and TutorialMode.last_harvest_gain() == production and _harvest_action_calls == 1,
		"harvest_once", "收获 %d（应为升级后的 %d），动画请求 %d 次" % [GameState.carrots, production, _harvest_action_calls])
	TutorialMode.sync()
	TutorialMode.sync()
	_expect(GameState.carrots == production and _harvest_action_calls == 1, "harvest_idempotent", "重复 sync 不重复收获")
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_CARROT_COUNTER, "target_counter", TutorialMode._carrot_target_id())
	# 点一下领奖
	_tap()
	_expect(TutorialMode.step == TutorialScript.Step.DRAW_STONE and GameState.carrots == production + TutorialScript.TUTORIAL_CARROT_GIFT,
		"gift", "萝卜 %d，步骤 %s" % [GameState.carrots, TutorialMode.step_key()])
	_expect(GameState.carrots > GameState.carrot_capacity(), "gift_over_capacity", "%d / %d（教学奖励可以超容量）" % [GameState.carrots, GameState.carrot_capacity()])

	# 抽石头：营地关着 -> 入口；营地页 -> 升级石页签；升级石页 -> 抽取
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_CARROT_CAMP, "draw_target_closed", TutorialMode._carrot_target_id())
	TutorialMode.record_carrot_camp_state(true, TutorialScript.CAMP_PAGE_CAMP)
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_CARROT_STONE_TAB, "draw_target_tab", TutorialMode._carrot_target_id())
	TutorialMode.record_carrot_camp_state(true, TutorialScript.CAMP_PAGE_STONE)
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_STONE_DRAW, "draw_target_button", TutorialMode._carrot_target_id())
	_expect(TutorialMode.forced_stone_type() == "land", "forced_land", TutorialMode.forced_stone_type())
	var carrots_before := GameState.carrots
	_expect(_draw_like_prep(), "draw_ok", "")
	_expect(int(GameState.team_upgrade_stones.get("land", 0)) == 1 and GameState.carrots == carrots_before - 50,
		"draw_result", "地石 %d，萝卜 %d -> %d" % [int(GameState.team_upgrade_stones.get("land", 0)), carrots_before, GameState.carrots])
	_expect(TutorialMode.step == TutorialScript.Step.FOUR_STAR, "draw_to_four_star", TutorialMode.step_key())
	_expect(not _draw_like_prep(), "draw_once", "四星这一步不能再抽")
	_expect(TutorialMode._carrot_target_id() == ProviderScript.TARGET_FOUR_STAR_ROW, "target_row", TutorialMode._carrot_target_id())
	_expect(TutorialMode.allows_carrot_action("four_star") and bool(GameState.four_star_check(_militia()).get("ok", false)),
		"four_star_ready", str(GameState.four_star_check(_militia())))

	# 升四星（与 PrepBoardController._execute_four_star_upgrade 本地路径同一个函数）
	var res := GameState.upgrade_cell_to_four_star(_militia())
	TutorialMode.sync()
	_expect(bool(res.get("ok", false)) and int(_militia().get("star", 0)) == 4, "four_star_done", str(res))
	_expect(TutorialMode.step == TutorialScript.Step.HIRE_MERC, "four_star_to_merc", TutorialMode.step_key())
	_expect(TutorialMode.allows_carrot_action("hire_merc") and not TutorialMode.allows_carrot_action("four_star"),
		"gate_merc_open", "")
	# 萝卜够雇两个最贵的里面挑剩下的
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	var most := 0
	for m in mercs:
		most = maxi(most, int(m.get("carrot_cost", 0)))
	var cheapest := 1 << 30
	for m in mercs:
		cheapest = mini(cheapest, int(m.get("carrot_cost", 0)))
	_expect(GameState.carrots - most >= cheapest, "merc_budget",
		"剩 %d 萝卜：先雇最贵的 %d 还剩 %d ≥ 最便宜 %d" % [GameState.carrots, most, GameState.carrots - most, cheapest])
	await get_tree().process_frame


func _check_checkpoint_roundtrip() -> void:
	_arrive_at_formation_hp()
	_tap()
	TutorialMode.record_carrot_camp_state(true, 0)
	GameState.upgrade_harvest_tech()
	TutorialMode.record_carrot_camp_state(false, 0)
	TutorialMode.begin_battle()
	TutorialMode.after_battle({})
	TutorialMode.attach(_fake)
	GameState.owned_treasures.append("atk_fury_roster")
	TutorialMode.sync()
	_tap()
	TutorialMode.record_carrot_camp_state(true, 1)
	_draw_like_prep()
	var before := {
		"step": TutorialMode.step, "num": TutorialMode.step_number(), "carrots": GameState.carrots,
		"tech": GameState.harvest_tech_level, "stones": GameState.team_upgrade_stones.duplicate(),
		"gain": TutorialMode.last_harvest_gain(), "gift": TutorialMode._carrot_gift_claimed,
		"harvested": TutorialMode._carrot_harvested, "draws": GameState.stone_draw_count,
	}
	TutorialMode.save_checkpoint(true)
	TutorialMode.active = false
	GameState.reset_run()
	var ok := TutorialMode.restore_checkpoint()
	var after := {
		"step": TutorialMode.step, "num": TutorialMode.step_number(), "carrots": GameState.carrots,
		"tech": GameState.harvest_tech_level, "stones": GameState.team_upgrade_stones.duplicate(),
		"gain": TutorialMode.last_harvest_gain(), "gift": TutorialMode._carrot_gift_claimed,
		"harvested": TutorialMode._carrot_harvested, "draws": GameState.stone_draw_count,
	}
	_expect(ok and before == after, "checkpoint_roundtrip", "%s -> %s" % [str(before), str(after)])
	_expect(not TutorialMode.carrot_camp_open(), "restore_camp_closed", "恢复后营地是关着的")
	# 旧版本断点必须被拒收
	var data := SaveManager.load_tutorial()
	data["version"] = 1
	SaveManager.save_tutorial(data)
	TutorialMode.active = false
	_expect(not TutorialMode.restore_checkpoint(), "old_checkpoint_rejected", "版本 1 的断点不恢复")
	TutorialMode.clear_checkpoint()
	await get_tree().process_frame


func _check_recovery() -> void:
	# 3 星民兵被卖掉：进抽石头那一步时补一枚回来
	_arrive_at_formation_hp()
	_tap()
	TutorialMode.record_carrot_camp_state(true, 0)
	GameState.upgrade_harvest_tech()
	TutorialMode.record_carrot_camp_state(false, 0)
	TutorialMode.begin_battle()
	TutorialMode.after_battle({})
	TutorialMode.attach(_fake)
	GameState.owned_treasures.append("atk_fury_roster")
	TutorialMode.sync()
	GameState.board_slots[5] = null  # 卖掉民兵
	GameState.carrots = 0            # 萝卜也花光了
	_tap()
	GameState.carrots = 10
	TutorialMode.sync()
	_expect(not _militia().is_empty() and int(_militia().get("star", 0)) == 3, "recover_militia", "补回 3 星民兵：%s" % str(_militia().get("star", 0)))
	_expect(GameState.carrots >= GameState.upgrade_stone_draw_cost(), "recover_carrots", "萝卜补到够抽一次：%d" % GameState.carrots)
	TutorialMode.record_carrot_camp_state(true, 1)
	_expect(_draw_like_prep() and TutorialMode.step == TutorialScript.Step.FOUR_STAR, "recover_draw", TutorialMode.step_key())
	# 石头被（异常地）清空：四星这一步补一颗同属性石头
	GameState.team_upgrade_stones = CarrotEconomy.empty_stones()
	TutorialMode.sync()
	_expect(int(GameState.team_upgrade_stones.get("land", 0)) == 1, "recover_stone", str(GameState.team_upgrade_stones))
	await get_tree().process_frame
