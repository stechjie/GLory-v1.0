extends Node

const PrepRules := preload("res://scenes/prep/PrepRules.gd")

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "board_4x4_smoke"

var _h: CheckHarness

# 取棋盘簇的字段。D2 之后这些成员搬进了 PrepShared.BoardPanel 内部类，
# 不能再用 prep.get("BoardHud.buttons") —— Object.get() 收的是属性名不是路径，
# 那样会静默返回 null。
func _board_field(prep: Node, name: String) -> Variant:
	var board: Variant = prep.get("_board_hud")
	return null if board == null else board.get(name)

func _ready() -> void:
	# 原本全篇用 assert()。assert 失败会中断脚本执行：后面的检查一条都不跑，
	# 末尾的 get_tree().quit() 也永远到不了，进程只能靠 --quit-after 强杀，
	# 退出码于是恒为 0。改成 _h.expect() 之后失败会累计并跑完全部用例。
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	var prep := packed.instantiate()
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	# 联机客机的萝卜由 room_state 直接写入 GameState；入口计数必须跟着
	# session_changed 刷新，不能只在玩家本地操作时刷新。
	var carrot_counter := prep.get("_carrot_counter_label") as Label
	var initial_carrots := GameState.carrots
	GameState.carrots = mini(7, GameState.carrot_capacity())
	prep.call("_on_network_session_changed")
	_h.expect(carrot_counter != null, "carrot_counter_missing",
		"Carrot Camp 入口缺少常驻萝卜数量")
	if carrot_counter != null:
		_h.expect(carrot_counter.text == "%d / %d" % [GameState.carrots, GameState.carrot_capacity()],
			"carrot_counter_stale_after_room_state",
			"room_state 同步后入口显示 %s，实际为 %d / %d" % [
				carrot_counter.text, GameState.carrots, GameState.carrot_capacity()])
	GameState.carrots = initial_carrots
	prep.call("_refresh_carrot_counter")
	_h.expect(GameState.board_slots.size() == GameConstants.CELL_COUNT,
		"board_slots_size", "GameState.board_slots 有 %d 格，期望 %d" % [
			GameState.board_slots.size(), GameConstants.CELL_COUNT])
	_h.expect(GameConstants.BOARD_ROWS == 4, "board_rows",
		"BOARD_ROWS=%d，期望 4" % GameConstants.BOARD_ROWS)
	_h.expect(GameConstants.BOARD_COLUMNS == 4, "board_columns",
		"BOARD_COLUMNS=%d，期望 4" % GameConstants.BOARD_COLUMNS)
	var buttons: Array = _board_field(prep, "buttons")
	_h.expect(buttons.size() == GameConstants.CELL_COUNT, "board_button_count",
		"BoardHud.buttons 有 %d 个，期望 %d" % [buttons.size(), GameConstants.CELL_COUNT])
	var standby_buttons: Array = _board_field(prep, "bench_buttons")
	_h.expect(standby_buttons.size() == GameState.BENCH_SLOTS, "bench_button_count",
		"BoardHud.bench_buttons 有 %d 个，期望 %d" % [standby_buttons.size(), GameState.BENCH_SLOTS])
	for i in standby_buttons.size():
		_h.expect((standby_buttons[i] as Control).has_method("_has_point"),
			"bench_button_no_has_point", "待命区按钮 %d 缺 _has_point()" % i)
	_h.expect(not PrepRules.can_drop_on_board(-1, {"kind": "bench", "index": 0}),
		"drop_accepts_negative_index", "PrepRules.can_drop_on_board(-1) 应当拒绝")
	_h.expect(not PrepRules.can_drop_on_board(GameConstants.CELL_COUNT, {"kind": "bench", "index": 0}),
		"drop_accepts_overflow_index", "PrepRules.can_drop_on_board(%d) 应当拒绝" % GameConstants.CELL_COUNT)
	for index in GameConstants.CELL_COUNT:
		_h.expect(PrepRules.can_drop_on_board(index, {"kind": "bench", "index": 0}),
			"drop_rejects_valid_index", "PrepRules.can_drop_on_board(%d) 应当接受" % index)

	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "race_units_empty", "race_units 表为空，后续用例无法构造"):
		_h.finish(get_tree())
		return
	var first_def: Dictionary = units[0].duplicate(true)

	# --- 25 格旧盘面迁移 ---
	# 这里必须用数据表里的**真实** id。原来写的是 "legacy_first"/"legacy_last"，
	# 而 NetProtocol.sanitize_cell() 会先后走 _trusted_def()/_safe_def() 按 id 查表，
	# 查不到就返回 null —— 那是服务端权威净化的正确行为，不是迁移 bug。
	# 用假 id 断言"迁移后还剩 2 格"等于要求 sanitize_board 信任未知单位。
	var real_id := str(first_def.get("id", ""))
	var legacy_board: Array = []
	legacy_board.resize(25)
	legacy_board.fill(null)
	legacy_board[0] = {"id": real_id, "star": 1, "def": first_def.duplicate(true)}
	legacy_board[24] = {"id": real_id, "star": 1, "def": first_def.duplicate(true)}
	var migrated: Array = SaveManager.call("_normalize_board_slots", legacy_board)
	_h.expect(migrated.size() == GameConstants.CELL_COUNT, "save_migration_size",
		"SaveManager 迁移后 %d 格，期望 %d" % [migrated.size(), GameConstants.CELL_COUNT])
	_h.expect(migrated.filter(func(cell): return cell != null).size() == 2,
		"save_migration_lost_units",
		"SaveManager 迁移后非空格 %d 个，期望 2（第 24 格应被重排到空位而不是丢弃）"
			% migrated.filter(func(cell): return cell != null).size())
	var network_migrated := NetProtocol.sanitize_board(legacy_board)
	_h.expect(network_migrated.size() == GameConstants.CELL_COUNT, "net_migration_size",
		"sanitize_board 迁移后 %d 格，期望 %d" % [network_migrated.size(), GameConstants.CELL_COUNT])
	_h.expect(network_migrated.filter(func(cell): return cell != null).size() == 2,
		"net_migration_lost_units",
		"sanitize_board 迁移后非空格 %d 个，期望 2" % network_migrated.filter(func(cell): return cell != null).size())

	# 反向用例：未知 id 必须被丢弃。这是 sanitize_board 的真实契约
	# （不信任客户端上报的单位），得有断言守住，否则将来有人"修"成信任未知 id。
	var spoofed: Array = []
	spoofed.resize(GameConstants.CELL_COUNT)
	spoofed.fill(null)
	spoofed[0] = {"id": "not_a_real_unit_id", "star": 1, "def": {"id": "not_a_real_unit_id"}}
	var sanitized_spoof := NetProtocol.sanitize_board(spoofed)
	_h.expect(sanitized_spoof.filter(func(cell): return cell != null).is_empty(),
		"net_accepts_unknown_unit",
		"sanitize_board 放行了数据表里不存在的单位 id —— 客户端可借此上报任意单位")
	for index in GameState.BENCH_SLOTS:
		GameState.bench_slots[index] = {
			"id": first_def.get("id", "unit"),
			"star": 1,
			"def": first_def.duplicate(true),
		}
	for index in GameConstants.CELL_COUNT:
		GameState.board_slots[index] = {
			"id": first_def.get("id", "unit"),
			"star": 1,
			"def": first_def.duplicate(true),
		}
	_hud(prep).refresh_board()
	_hud(prep).refresh_bench()
	await get_tree().process_frame
	var fighters := BattleSim.build_tutorial_player_fighters("pve")
	_h.expect(fighters.size() == GameConstants.CELL_COUNT, "fighter_count",
		"build_tutorial_player_fighters 产出 %d 个，期望 %d" % [fighters.size(), GameConstants.CELL_COUNT])
	var positions: Dictionary = {}
	for fighter in fighters:
		positions[str(Vector2(fighter.pos))] = true
	_h.expect(positions.size() == GameConstants.CELL_COUNT, "fighter_position_collision",
		"%d 个出场单位只占了 %d 个不同坐标" % [fighters.size(), positions.size()])
	if buttons.size() >= GameConstants.CELL_COUNT:
		var first_button := buttons[0] as Control
		var last_button := buttons[GameConstants.CELL_COUNT - 1] as Control
		_h.expect(first_button.size.x > 0.0 and first_button.size.y > 0.0,
			"board_button_zero_size", "首格按钮尺寸为 %s" % str(first_button.size))
		_h.expect(last_button.size.x > 0.0 and last_button.size.y > 0.0,
			"board_button_zero_size", "末格按钮尺寸为 %s" % str(last_button.size))
	GameState.board_slots.fill(null)
	_hud(prep).refresh_board()
	prep.call("_on_drag_started", {"kind": "board", "index": 0})
	_hud(prep).set_standby_drop_hover(5)
	_h.expect(bool(_board_field(prep, "standby_drop_highlight_active")),
		"standby_highlight_inactive", "拖拽中待命区高亮未激活")
	_h.expect(int(_board_field(prep, "standby_drop_hover_index")) == 5,
		"standby_hover_index", "待命区 hover 下标为 %d，期望 5" % int(_board_field(prep, "standby_drop_hover_index")))
	for i in buttons.size():
		_h.expect((buttons[i] as Control).has_method("_has_point"),
			"board_button_no_has_point", "棋盘按钮 %d 缺 _has_point()" % i)
	prep.call("_on_drag_started", {"kind": "bench", "index": 0})
	_hud(prep).set_board_drop_hover(10)
	_h.expect(bool(_board_field(prep, "drop_highlight_active")),
		"board_highlight_inactive", "拖拽中棋盘高亮未激活")
	_h.expect(int(_board_field(prep, "drop_hover_index")) == 10,
		"board_hover_index", "棋盘 hover 下标为 %d，期望 10" % int(_board_field(prep, "drop_hover_index")))
	var capture_path := OS.get_environment("BOARD_4X4_CAPTURE_PATH")
	if not capture_path.is_empty():
		for _frame in 20:
			await get_tree().process_frame
		var image := get_viewport().get_texture().get_image()
		_h.expect(image.save_png(capture_path) == OK, "capture_save_failed",
			"截图写入 %s 失败" % capture_path)
	print("BOARD_4X4_SMOKE cells=%d unique_positions=%d first=%s last=%s" % [
		buttons.size(),
		positions.size(),
		str(fighters[0].pos) if not fighters.is_empty() else "-",
		str(fighters[GameConstants.CELL_COUNT - 1].pos) if fighters.size() >= GameConstants.CELL_COUNT else "-",
	])
	_h.finish(get_tree())


# 棋盘刷新与拖放高亮已随 D2 搬进 BoardHud 节点。
# 用节点引用直接调，不再按名字调 —— 按名字的调用会被 dynamic_call 的棘轮记账。
func _hud(prep: Node) -> Node:
	return prep.get("_board_hud") as Node
