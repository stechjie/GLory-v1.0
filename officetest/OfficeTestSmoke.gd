extends Node

# 冒烟测试(headless):
#   godot --headless res://officetest/OfficeTestSmoke.tscn
# 验证:配置组装 -> 状态构建 -> 回放计算 -> 编辑场景实例化/摆放/演示切换。
# 只打印 [SMOKE] 行,PASS/FAIL 后退出;不碰存档。

var _fails := 0


func _check(cond: bool, what: String) -> void:
	if cond:
		print("[SMOKE] PASS: %s" % what)
	else:
		_fails += 1
		print("[SMOKE] FAIL: %s" % what)


func _first_id(kind: String) -> String:
	var list := OfficeTestSim.unit_list(kind)
	return str((list[0] as Dictionary).get("id", "")) if not list.is_empty() else ""


func _ready() -> void:
	print("[SMOKE] start")
	var config := {"placements": [], "slot_treasures": {}}
	OfficeTestSim.set_placement(config, 0, 5, "piece", _first_id("piece"), 2)
	OfficeTestSim.set_placement(config, 1, 0, "merc", _first_id("merc"), 1)
	OfficeTestSim.set_placement(config, 2, 15, "piece", _first_id("piece"), 3)
	OfficeTestSim.set_placement(config, 3, 5, "monster", _first_id("monster"), 1)
	OfficeTestSim.set_placement(config, 4, 9, "boss", _first_id("boss"), 1)
	OfficeTestSim.set_placement(config, 5, 2, "formation", _first_id("formation"), 1)
	config["slot_treasures"] = {0: ["def_iron_wall", "atk_blood_pact"], 4: ["def_phantom_step"]}

	_check(OfficeTestSim.side_unit_count(config, true) == 3, "A 队 3 个单位")
	_check(OfficeTestSim.side_unit_count(config, false) == 3, "B 队 3 个单位")

	var display_state := OfficeTestSim.build_test_state(config, true)
	_check((display_state.player as Array).size() == 3, "编辑预览:player 3")
	_check((display_state.enemy as Array).size() == 3, "编辑预览:enemy 3")
	for f in (display_state.player as Array) + (display_state.enemy as Array):
		_check(not str(f.get("uid", "")).is_empty(), "fighter uid: %s" % str(f.get("id", "?")))

	# 格点坐标与真实 _place_in_lane 公式一致
	var f0: Dictionary = (display_state.player as Array)[0]
	var expect := OfficeTestSim.grid_sim_pos(0, 5)
	_check((f0.pos as Vector2).distance_to(expect) < 0.01, "格点坐标与战斗站位一致")

	var replay: Dictionary = await OfficeTestSim.compute_test_replay_async(config)
	_check(not (replay.get("frames", []) as Array).is_empty(), "回放帧非空(%d 帧)" % (replay.get("frames", []) as Array).size())
	_check((replay.get("roster", {}) as Dictionary).size() == 6, "roster 6 个单位")
	_check((replay.get("result", {}) as Dictionary).has("player_wins"), "结果含 player_wins")
	print("[SMOKE] result: ", replay.get("result", {}).get("player_wins"), " elapsed=", replay.get("result", {}).get("elapsed"))

	# 场景实例化(编辑态)
	GameState.team_mode = true
	var screen := (load("res://officetest/OfficeTestScreen.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(screen)
	for i in 8:
		await get_tree().process_frame
	_check(screen._battle_setup_ready, "编辑场景就绪")
	_check(screen._grid_buttons.size() == 96, "96 个格点按钮")

	# 模拟摆放 + 演示 + 回编辑
	screen._config = config
	screen._rebuild_edit_preview()
	await get_tree().process_frame
	_check((screen._state.player as Array).size() == 3, "屏幕预览 player 3")
	screen._start_test_demo()
	for i in 40:
		await get_tree().process_frame
		if screen._replay_mode:
			break
	_check(screen._replay_mode, "演示回放已开始")
	screen._skip_animation()
	await get_tree().process_frame
	_check(screen._finished, "跳过后演示结束")
	_check(screen._summary_panel.visible, "测试结算面板显示")
	screen._return_to_edit()
	await get_tree().process_frame
	_check(screen._edit_mode and not screen._summary_panel.visible, "已回到编辑态")
	_check((screen._state.player as Array).size() == 3, "回编辑后摆放保留")

	print("[SMOKE] done, fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
