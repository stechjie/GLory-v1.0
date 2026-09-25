extends Node

# V2 P1-08 专项门禁：教程断点恢复与 Android 返回键。
#
# 背景：`SaveManager._write_now()` 第一行是 `if GameState.tutorial_mode: return` ——
# 教程期间主存档整个被跳过，所以 Back 退出、被系统杀死或切后台之后必然从 BUY_3 重来
# （V2 的 R-10 记录的就是这个）。断点因此走**独立文件**，不碰主存档，
# 主存档参与 replay / final-state SHA，V2 收尾要求那些字节不变。
#
# 这条门禁覆盖 MD 要求的「步骤 1/6/10/15 × 强杀/Back/切后台」矩阵中
# **headless 能确定性复现的那部分**：
#   * 强杀   -> 清空运行时状态再 restore_checkpoint()，等价于进程重开
#   * Back   -> Main._on_back_requested()，验优先级与「不直接退桌面」
#   * 切后台 -> NOTIFICATION_APPLICATION_PAUSED，验断点被强制落盘
# 真机上的实际杀进程/切后台由 F3 的设备验收补，不由这条代替。
#
# ⚠️ 绝不真的走到第二次 Back：那会 `get_tree().quit()` 把门禁自己杀掉。
# 二次确认只验「第一次按下把退出武装起来、且没有退出」——
# 门禁还能继续跑下去，本身就是「没退桌面」的证据。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const MainScript := preload("res://scenes/main/Main.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "tutorial_checkpoint"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

# MD 点名的四个断点。用序列位置（1 起）而不是枚举值，与进度条口径一致。
# 9.25：再加第 18 步（FOUR_STAR）—— 萝卜、升级石、采集等级、收获/领奖标记
# 都要从断点里原样恢复，四星那一步才接得上。
const CHECKPOINT_STEPS := [1, 6, 10, 15, 18]
# 教程里只增不减的三样。断点里它们回退就说明写进去的是过期快照。
const MONOTONE_FIELDS := ["宝藏", "佣兵", "采购"]
const ACTION_BUDGET := 60

var _h: CheckHarness
var _saved_tutorial_bytes: PackedByteArray = PackedByteArray()
var _tutorial_file_existed := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	# 门禁会写真实的断点文件，先整份快照，结束逐字还原。
	_tutorial_file_existed = FileAccess.file_exists(SaveManager.TUTORIAL_PATH)
	if _tutorial_file_existed:
		_saved_tutorial_bytes = FileAccess.get_file_as_bytes(SaveManager.TUTORIAL_PATH)

	_check_source_contract()
	for position in CHECKPOINT_STEPS:
		await _check_restore_at(int(position))
	await _check_back_priority()
	await _check_no_checkpoint_falls_back_to_fresh()
	await _check_every_step_persists_immediately()
	_check_step_writes_are_funnelled()

	TutorialMode.finish()
	GameState.reset_run()
	_restore_tutorial_file()
	await _settle(3)
	_h.expect(not _file_drifted(), "tutorial_file_not_restored",
		"测试结束后 %s 没有逐字还原" % SaveManager.TUTORIAL_PATH)
	_h.finish(get_tree())


# --- 强杀恢复：步骤 1 / 6 / 10 / 15 ------------------------------------------

func _check_restore_at(position: int) -> void:
	TutorialMode.start()
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)

	var guard := 0
	while TutorialMode.step_number() < position and guard < 400:
		guard += 1
		await _drive_current_step(prep)
	if not _h.expect(TutorialMode.step_number() == position, "could_not_reach_step",
			"开不到第 %d 步（停在 %d / %s）"
				% [position, TutorialMode.step_number(), TutorialMode.step_key()]):
		prep.queue_free()
		await _settle(3)
		return

	TutorialMode.save_checkpoint(true)
	_h.expect(TutorialMode.has_checkpoint(), "checkpoint_not_written",
		"第 %d 步 save_checkpoint() 之后断点文件不存在" % position)
	var before := _snapshot_state()

	# 模拟强杀：页面销毁 + 运行时状态全清，等价于进程重开后的初始状态。
	prep.queue_free()
	await _settle(4)
	TutorialMode.active = false
	GameState.reset_run()
	await _settle(2)
	_h.expect(GameState.normal_unit_count() == 0, "kill_simulation_ineffective",
		"模拟强杀之后棋盘还有棋子，这一组等于没测")

	var restored := TutorialMode.restore_checkpoint()
	_h.expect(restored, "restore_failed", "第 %d 步的断点恢复失败" % position)
	if not restored:
		return
	var after := _snapshot_state()

	_h.expect(TutorialMode.active, "restore_left_inactive", "恢复后 TutorialMode 不是 active")
	_h.expect(GameState.tutorial_mode, "restore_left_tutorial_mode_off",
		"恢复后 GameState.tutorial_mode 是 false")
	for key in before.keys():
		_h.item()
		_h.expect(after.get(key) == before.get(key), "restore_state_mismatch",
			"第 %d 步恢复后 %s 不一致：%s -> %s"
				% [position, str(key), str(before.get(key)), str(after.get(key))])
	_h.expect(TutorialMode.step_number() == position, "restore_step_drifted",
		"恢复后停在第 %d 步，应为第 %d 步" % [TutorialMode.step_number(), position])

	# 恢复之后必须能接着往下走，不是一个只能看的死状态。
	var prep2 := _new_prep()
	if prep2 != null:
		await _settle(3)
		TutorialMode.attach(prep2.tutorial_target_provider())
		await _settle(2)
		var before_step := TutorialMode.step_number()
		var budget := 0
		while TutorialMode.step_number() == before_step and budget < ACTION_BUDGET:
			budget += 1
			await _drive_current_step(prep2)
		_h.expect(TutorialMode.step_number() > before_step, "restored_state_is_stuck",
			"从第 %d 步恢复之后推不动了" % position)
		prep2.queue_free()
		await _settle(3)


# 只取「玩家实际拥有的东西」，不取金币这类每帧被 sync() 重置的量。
func _snapshot_state() -> Dictionary:
	return {
		"step": TutorialMode.step,
		"progress_index": TutorialMode.step_number(),
		"board": GameState.normal_unit_count(),
		"owned_units": _owned_units(),
		"mercs": _merc_count(),
		"treasures": GameState.owned_treasures.size(),
		"claimed": GameState.claimed_treasure_rounds.size(),
		"pending_active": bool(GameState.pending_treasure.get("active", false)),
		"fill_phase": TutorialMode.fill_phase(),
		"fill_bought": int(TutorialMode.fill_buy_progress()[0]),
		"round_index": GameState.round_index,
		# 9.25 萝卜 / 四星教学
		"carrots": GameState.carrots,
		"harvest_tech_level": GameState.harvest_tech_level,
		"stones": GameState.team_upgrade_stones.duplicate(true),
		"carrot_spent": GameState.merc_carrots_spent_total,
		"harvest_gain": TutorialMode.last_harvest_gain(),
	}


# --- Back 优先级 ---------------------------------------------------------------

func _check_back_priority() -> void:
	TutorialMode.start()
	var main: MainScript = MainScript.new()
	add_child(main)
	await _settle(3)
	var prep := _new_prep()
	if prep == null:
		main.queue_free()
		await _settle(3)
		return
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)
	main._prep = prep

	# 1. 最上层 modal 优先
	ModalStack.close_all()
	await _settle(3)
	var content := Control.new()
	content.name = "BackProbeModal"
	var modal_id := ModalStack.push(content, {"id": "back_probe", "owner": main})
	await _settle(2)
	_h.expect(not modal_id.is_empty(), "probe_modal_push_failed", "探针模态没推上去")
	var armed_before := main._back_exit_armed_until
	main._on_back_requested()
	await _settle(3)
	_h.expect(not ModalStack.has("back_probe"), "back_did_not_close_modal",
		"返回键没有先关掉最上层 modal")
	_h.expect(main._back_exit_armed_until == armed_before, "back_armed_exit_with_modal_open",
		"modal 还开着就把退出武装起来了 —— 优先级反了")

	# 2. 页面自己的面板其次
	prep._shop.open_button.pressed.emit()
	await _settle(3)
	_h.expect(prep._shop.picker_open, "shop_probe_setup_failed", "商店没打开，这一组没测到")
	armed_before = main._back_exit_armed_until
	main._on_back_requested()
	await _settle(3)
	_h.expect(not prep._shop.picker_open, "back_did_not_close_panel",
		"返回键没有关掉备战页自己的商店面板")
	_h.expect(main._back_exit_armed_until == armed_before, "back_armed_exit_with_panel_open",
		"面板还开着就把退出武装起来了")

	# 3. 都没有时才武装退出 —— 而且**不能真的退出**
	armed_before = main._back_exit_armed_until
	main._on_back_requested()
	await _settle(3)
	_h.expect(main._back_exit_armed_until > armed_before, "back_did_not_arm_exit",
		"没有可关的东西时，返回键没有进入二次确认状态")
	# 门禁能跑到这一行，本身就证明第一次 Back 没有 quit()。
	_h.expect(is_instance_valid(main), "back_quit_on_first_press",
		"第一次按返回键就退出了")
	_h.expect(TutorialMode.has_checkpoint(), "back_did_not_save_checkpoint",
		"教程中按返回键没有把断点落盘")

	# 4. 切后台必须强制落盘
	TutorialMode.clear_checkpoint()
	_h.expect(not TutorialMode.has_checkpoint(), "clear_checkpoint_ineffective",
		"clear_checkpoint() 之后断点还在")
	main._notification(main.NOTIFICATION_APPLICATION_PAUSED)
	await _settle(2)
	_h.expect(TutorialMode.has_checkpoint(), "pause_did_not_save_checkpoint",
		"切后台（APPLICATION_PAUSED）没有把断点落盘")

	ModalStack.close_all()
	prep.queue_free()
	main.queue_free()
	await _settle(4)


# --- 没有断点时必须退回全新教程，不能半恢复 -----------------------------------

func _check_no_checkpoint_falls_back_to_fresh() -> void:
	TutorialMode.finish()
	TutorialMode.clear_checkpoint()
	await _settle(2)
	_h.expect(not TutorialMode.has_checkpoint(), "checkpoint_should_be_absent",
		"清空之后断点仍然存在")
	_h.expect(not TutorialMode.restore_checkpoint(), "restored_from_nothing",
		"没有断点时 restore_checkpoint() 却报成功")

	# 损坏的断点同样必须被拒绝，而不是恢复出一个夹生状态。
	SaveManager.save_tutorial({"version": 999, "step": 3})
	_h.expect(not TutorialMode.restore_checkpoint(), "restored_wrong_version",
		"版本不符的断点被接受了")
	SaveManager.save_tutorial({"version": TutorialScript.CHECKPOINT_VERSION, "step": -1})
	_h.expect(not TutorialMode.restore_checkpoint(), "restored_invalid_step",
		"step 非法的断点被接受了")
	TutorialMode.clear_checkpoint()


func _check_source_contract() -> void:
	var main_src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	_h.expect(main_src.contains("NOTIFICATION_WM_GO_BACK_REQUEST"),
		"back_notification_missing", "Main 没有处理 NOTIFICATION_WM_GO_BACK_REQUEST")
	_h.expect(main_src.contains("ModalStack.handle_back_request()"),
		"back_does_not_use_modal_stack", "返回键没有先问 ModalStack")
	# 退出必须在「已武装」之后，不能是无条件 quit。
	var armed_index := main_src.find("_back_exit_armed_until")
	var quit_index := main_src.find("get_tree().quit()")
	_h.expect(armed_index >= 0 and quit_index > armed_index, "quit_not_guarded",
		"get_tree().quit() 不在二次确认之后 —— 可能一按就退桌面")
	# 上面三条都是**源码**断言，而返回键真正的成败在引擎设置上：
	# 派发完 NOTIFICATION_WM_GO_BACK_REQUEST 之后，引擎默认还会自己退出，
	# Main.gd 里的三级优先级写得再对也拦不住。
	#
	# 2026-09-03 真机实测撞到过：设置保持默认 true 时按第一下返回键 app 就退了，
	# 而上面那三条源码断言**全部照常通过**。典型的「源码对、行为错」，
	# headless 门禁只看文本就永远发现不了 —— 所以这一条查运行时取值。
	_h.expect(not bool(ProjectSettings.get_setting("application/config/quit_on_go_back", true)),
		"engine_quits_on_go_back",
		("application/config/quit_on_go_back 不是 false —— "
			+ "引擎会绕过返回键处理器直接退出，二次确认形同虚设"))
	# 二次确认要成立，玩家得先**看见**提示。第一版把 Label 直接挂在 Main 上，
	# 真机实测被备战页的商店按钮压住，只露出半截字 —— 功能在、提示看不见，
	# 玩家按第二下前根本不知道自己在确认什么。
	_h.expect(main_src.contains("CanvasLayer.new()") and main_src.contains("BACK_EXIT_HINT_LAYER"),
		"back_hint_not_on_own_layer",
		"返回键提示没有自带 CanvasLayer —— 会被当前页面的 UI 盖住")

	# V3 P0-09：桌面 Esc 必须复用同一条返回路径，不能另写一套。
	#
	# 分成两套实现是这类需求最常见的坏法：两边各自漂移，而 QA 通常只在一个平台
	# 点得到。所以断言的是「Esc 落到 _on_back_requested()」，而不是「有处理 Esc」。
	#
	# 断言限定在函数体里、并用带缩进的代码形状 —— 本轮已经三次栽在
	# 「整文件 contains 被自己写的注释满足」上（见 source-assert-contains-trap）。
	var esc_at := main_src.find("func _unhandled_input(event: InputEvent) -> void:")
	if _h.expect(esc_at >= 0, "esc_not_wired",
			"Main 没有 _unhandled_input —— 桌面 Esc 到不了返回逻辑"):
		var esc_end := main_src.find("\nfunc ", esc_at + 1)
		if esc_end < 0:
			esc_end = main_src.length()
		var esc_body := main_src.substr(esc_at, esc_end - esc_at)
		_h.expect(esc_body.contains("is_action_pressed(\"ui_cancel\")"),
			"esc_not_ui_cancel",
			"_unhandled_input 没有按 ui_cancel 判断")
		_h.expect(esc_body.contains("\t_on_back_requested()"),
			"esc_has_own_logic",
			("Esc 没有落到 _on_back_requested() —— 两套返回逻辑会各自漂移，"
				+ "而 QA 通常只在一个平台点得到"))
		_h.expect(esc_body.contains("set_input_as_handled()"),
			"esc_not_consumed",
			"Esc 处理完没有 set_input_as_handled()，事件会继续冒泡")

	_check_back_route_matrix(main_src)

	var save_src := FileAccess.get_file_as_string("res://scripts/autoload/SaveManager.gd")
	_h.expect(save_src.contains("TUTORIAL_PATH"), "tutorial_path_missing",
		"SaveManager 没有教程断点路径")
	_h.expect(save_src.contains("if GameState.tutorial_mode:"),
		"run_save_guard_removed",
		("主存档里那条 `if GameState.tutorial_mode: return` 被删了 —— "
			+ "教程状态会混进 replay/final-state，V2 要求这些字节不变"))


# --- 驱动（与 tutorial_step15_flow 同一套真实入口）-----------------------------

func _drive_current_step(prep: PrepScript) -> void:
	match TutorialMode.step:
		# 9.13 #4：第 1 步买到 3 个之后多了一个「关闭商店」子阶段（与 FILL_7 的
		# CLOSE_SHOP 同源，由 record_shop_toggled 的生产事件推进）。买完仍停在第 1 步
		# 就把商店关掉；下一次迭代还要接着买时会重新打开 —— 与玩家的真实操作序列一致。
		TutorialScript.Step.BUY_3:
			await _open_shop(prep)
			await _buy_one(prep)
			if TutorialMode.step == TutorialScript.Step.BUY_3:
				await _close_shop(prep)
		TutorialScript.Step.UPGRADE_2, \
		TutorialScript.Step.UPGRADE_3, TutorialScript.Step.UPGRADE_OTHERS:
			await _open_shop(prep)
			await _buy_one(prep)
		TutorialScript.Step.PLACE_3:
			await _place_one(prep)
		TutorialScript.Step.START_PVE_1, TutorialScript.Step.START_PVE_2, \
		TutorialScript.Step.START_BOSS, TutorialScript.Step.START_PVP:
			await _fight(prep)
		TutorialScript.Step.TAKE_TREASURE_1, TutorialScript.Step.TAKE_TREASURE_2:
			await _take_treasure(prep)
		TutorialScript.Step.BOND_HINT, TutorialScript.Step.VIEW_TREASURE, \
		TutorialScript.Step.FORMATION_HP:
			await _tap_continue()
		TutorialScript.Step.HIRE_MERC:
			await _hire_merc(prep)
		TutorialScript.Step.CARROT_CAMP, TutorialScript.Step.HARVEST_UPGRADE, \
		TutorialScript.Step.DRAW_STONE, TutorialScript.Step.FOUR_STAR:
			await _drive_carrot_step(prep)
		TutorialScript.Step.CARROT_HARVEST:
			await _tap_continue()
		TutorialScript.Step.FILL_7:
			await _drive_fill(prep)
		_:
			await _settle(1)


func _drive_fill(prep: PrepScript) -> void:
	match TutorialMode.fill_phase():
		TutorialScript.FillPhase.BUY:
			await _open_shop(prep)
			await _buy_one(prep)
		TutorialScript.FillPhase.CLOSE_SHOP:
			await _close_shop(prep)
		_:
			await _place_one(prep)


func _open_shop(prep: PrepScript) -> void:
	if not prep._shop.picker_open and prep._shop.open_button != null:
		prep._shop.open_button.pressed.emit()
		await _settle(2)


func _close_shop(prep: PrepScript) -> void:
	if prep._shop.picker_open and prep._shop.open_button != null:
		prep._shop.open_button.pressed.emit()
		await _settle(2)


func _buy_one(prep: PrepScript) -> void:
	var slot := -1
	for i in GameState.shop_offers.size():
		if i >= GameState.shop_sold.size() or bool(GameState.shop_sold[i]):
			continue
		var offer = GameState.shop_offers[i]
		if typeof(offer) == TYPE_DICTIONARY and not (offer as Dictionary).is_empty():
			slot = i
			break
	if slot < 0 or slot >= prep._shop.buttons.size():
		await _settle(1)
		return
	prep._shop.buttons[slot].pressed.emit()
	await _settle(1)
	if prep._shop.buy_button != null:
		prep._shop.buy_button.pressed.emit()
	await _settle(2)


func _place_one(prep: PrepScript) -> void:
	var bench := -1
	for i in GameState.bench_slots.size():
		if GameState.bench_slots[i] != null and i < prep._board_hud.bench_buttons.size():
			bench = i
			break
	var board := -1
	for j in GameState.board_slots.size():
		if GameState.board_slots[j] == null and j < prep._board_hud.buttons.size():
			board = j
			break
	if bench < 0 or board < 0:
		await _settle(1)
		return
	prep._board_hud.bench_buttons[bench].pressed.emit()
	await _settle(1)
	prep._board_hud.buttons[board].pressed.emit()
	await _settle(2)


func _fight(prep: PrepScript) -> void:
	if not TutorialMode.begin_battle():
		await _settle(1)
		return
	TutorialMode.after_battle({})
	TutorialMode.attach(prep.tutorial_target_provider())
	TutorialMode.sync()
	await _settle(2)


func _take_treasure(prep: PrepScript) -> void:
	var cands: Array = GameState.pending_treasure.get("candidates", [])
	if cands.is_empty():
		await _settle(1)
		return
	prep._pick_treasure(str(cands[0]))
	TutorialMode.sync()
	await _settle(2)


func _tap_continue() -> void:
	if TutorialMode._hotspot != null and is_instance_valid(TutorialMode._hotspot):
		TutorialMode._hotspot.pressed.emit()
	await _settle(2)


func _hire_merc(prep: PrepScript) -> void:
	for i in GameState.mercenary_slots.size():
		if _merc_count() >= 2:
			break
		prep._on_hire_mercenary(i)
		await _settle(1)
	TutorialMode.sync()
	await _settle(2)


# --- 9.25 萝卜 / 四星教学：全部走真实控件 ---------------------------------------
#   营地开合 -> 右侧 `_carrot_button.pressed` / 面板右上角 × 的 pressed
#   切页签   -> 面板的 `_camp_tab` / `_stone_tab` 的 pressed
#   升级采集 -> `_tech_button.pressed`；抽石头 -> `_draw_button.pressed`
#   升四星   -> 四星列表那一行的「升至四星」pressed，再在详情弹窗里
#              `upgrade_panel.action.pressed` 两次（升级至四星 -> 确认升级）
# 成不成交仍由宿主的教学步骤门槛、萝卜、石头、金币判断决定。
func _drive_carrot_step(prep: PrepScript) -> void:
	var panel = prep._carrot_panel
	if panel == null or not is_instance_valid(panel):
		await _settle(1)
		return
	if not panel.visible:
		prep._carrot_button.pressed.emit()
		await _settle(2)
		return
	match TutorialMode.step:
		TutorialScript.Step.HARVEST_UPGRADE:
			if GameState.harvest_tech_level >= 1:
				panel.tutorial_close_button().pressed.emit()
			elif panel.current_page() != TutorialScript.CAMP_PAGE_CAMP:
				panel.tutorial_camp_tab().pressed.emit()
			else:
				panel.tutorial_harvest_button().pressed.emit()
		TutorialScript.Step.DRAW_STONE:
			if panel.current_page() != TutorialScript.CAMP_PAGE_STONE:
				panel.tutorial_stone_tab().pressed.emit()
			else:
				panel.tutorial_draw_button().pressed.emit()
		TutorialScript.Step.FOUR_STAR:
			if panel.current_page() != TutorialScript.CAMP_PAGE_STONE:
				panel.tutorial_stone_tab().pressed.emit()
			else:
				var row := panel.tutorial_four_star_target() as Button
				if row != null and not row.disabled:
					row.pressed.emit()
					await _settle(2)
					var upgrade = prep._overlay.upgrade_panel
					if upgrade != null:
						upgrade.action.pressed.emit()
						await _settle(1)
						upgrade.action.pressed.emit()
		_:
			pass
	await _settle(2)


# --- 脚手架 ---------------------------------------------------------------------

func _owned_units() -> int:
	var n := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) == TYPE_DICTIONARY:
			n += 1
	return n


func _merc_count() -> int:
	var n := 0
	for cell in GameState.mercenary_slots:
		if cell != null:
			n += 1
	return n


func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return null
	var prep: PrepScript = packed.instantiate() as PrepScript
	if not _h.expect(prep != null, "prep_wrong_type", "实例化出来的不是 PrepScreen"):
		return null
	add_child(prep)
	return prep


func _restore_tutorial_file() -> void:
	if _tutorial_file_existed:
		var f := FileAccess.open(SaveManager.TUTORIAL_PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_saved_tutorial_bytes)
			f = null
	else:
		SaveManager.clear_tutorial()


func _file_drifted() -> bool:
	var exists := FileAccess.file_exists(SaveManager.TUTORIAL_PATH)
	if _tutorial_file_existed != exists:
		return true
	if not exists:
		return false
	return FileAccess.get_file_as_bytes(SaveManager.TUTORIAL_PATH) != _saved_tutorial_bytes


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame


# V3 P0-09：返回键的全页面矩阵。
#
# 迁移前每个子页面都有 back_requested 信号接了返回路由，但那**只有页面自己的
# 返回按钮**会发。Android Back / 桌面 Esc 落到第 2 级只问 PrepScreen，其余页面
# 直接掉到「再按一次退出」—— 玩家在设置页按返回会看到退出提示。
#
# 这里断言的是**不变式**而不是页面名单：凡是接了 back_requested 的 _show_*，
# 同一个函数体里必须登记 _page_back_route。点名单的写法在加新页面时会静默漏掉，
# 而漏掉正是这条缺陷本身的成因。
func _check_back_route_matrix(main_src: String) -> void:
	var funcs := _split_funcs(main_src)

	var pages_with_signal: Array[String] = []
	var pages_missing_route: Array[String] = []
	for fname in funcs.keys():
		var body: String = funcs[fname]
		if not body.contains(".back_requested.connect("):
			continue
		pages_with_signal.append(fname)
		if not body.contains("\t_page_back_route = "):
			pages_missing_route.append(fname)

	# 先证明这条断言有东西可查。页面全被改名/信号全被换掉时，上面的循环会一个都
	# 收不到，而「没有缺路由的页面」在空集上恒真 —— 那样断言就成了摆设。
	_h.expect(pages_with_signal.size() >= 5, "back_route_matrix_found_nothing",
		("只找到 %d 个接 back_requested 的页面（预期 ≥5）—— "
			+ "断言可能已经查不到任何东西了") % pages_with_signal.size())
	_h.expect(pages_missing_route.is_empty(), "page_without_back_route",
		("这些页面接了返回按钮却没登记 _page_back_route，"
			+ "Android Back / Esc 会跳过它们直接问退出：%s") % str(pages_missing_route))

	# 路由必须在切页时清掉，否则返回键会把玩家送回一个已经不在树上的界面。
	var clear_body: String = funcs.get("_clear", "")
	_h.expect(clear_body.contains("_page_back_route = Callable()"),
		"back_route_not_cleared",
		"_clear() 没有重置 _page_back_route —— 上一页的路由会漏到下一页")

	# 阶梯顺序：ModalStack → 页面自己的面板 → 页面返回出口 → 二次确认退出。
	# 顺序错了每一条单独看都还在，所以按下标比较，而不是各查各的 contains。
	var back_body: String = funcs.get("_on_back_requested", "")
	var i_modal := back_body.find("ModalStack.handle_back_request()")
	var i_prep := back_body.find("handle_back_request()", i_modal + 1)
	var i_route := back_body.find("_page_back_route.is_valid()")
	var i_quit := back_body.find("get_tree().quit()")
	_h.expect(i_modal >= 0 and i_prep > i_modal and i_route > i_prep and i_quit > i_route,
		"back_ladder_out_of_order",
		("返回键阶梯顺序不对（modal=%d prep=%d route=%d quit=%d），"
			+ "必须是 Modal → 页内面板 → 页面出口 → 二次确认退出")
			% [i_modal, i_prep, i_route, i_quit])


# 按顶层 func 切开源码，返回 {函数名: 函数体}。
#
# 门禁里「整文件 contains」会被自己写的注释满足 —— 本轮已经栽过三次。
# 限定到函数体是最可靠的一种修法，所以这里做成公共的。
func _split_funcs(src: String) -> Dictionary:
	var out := {}
	var lines := src.split("\n")
	var name := ""
	var buf := PackedStringArray()
	for raw in lines:
		var line := raw.trim_suffix("\r")
		if line.begins_with("func "):
			if name != "":
				out[name] = "\n".join(buf)
			var open_paren := line.find("(")
			name = line.substr(5, open_paren - 5) if open_paren > 5 else line.substr(5)
			buf = PackedStringArray()
			continue
		if name != "":
			buf.append(line)
	if name != "":
		out[name] = "\n".join(buf)
	return out


# V3 P0-08：走完整条教程，每一次步骤推进之后**立刻**比对落盘内容。
#
# V2 实测缺陷：按下「继续」或点热点推进之后强杀 app，回来还在按之前那一步。
# 根因是 _on_continue_pressed() / _on_hotspot_pressed() 推进了 step 却从不落盘，
# 断点要等玩家在备战页再做点什么触发 sync() 才跟上 —— 而那两步之后玩家做的
# 第一件事就是开战，中间隔着整场战斗。
#
# 上面那组 CHECKPOINT_STEPS 只抽查 1/6/10/15，而且是在 save_checkpoint(true)
# **之后**才读，天然测不到「谁忘了落盘」。这里改成：只推进、不强制落盘，
# 每换一步就读一次盘。覆盖全部步骤 —— 任务书点名不能只修 step 10。
func _check_every_step_persists_immediately() -> void:
	TutorialMode.start()
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)

	# 教程期间主存档必须一个字节都不动：_write_now() 第一行就是
	# `if GameState.tutorial_mode: return`，而主存档参与 replay / final-state SHA。
	var main_save_before := _main_save_digest()

	var seen: Array[int] = []
	var lagged: Array[String] = []
	var mismatched: Array[String] = []
	var monotone := [0, 0, 0]
	var last_step := TutorialMode.step
	var guard := 0
	while TutorialMode.step != TutorialScript.Step.DONE and guard < 600:
		guard += 1
		await _drive_current_step(prep)
		if TutorialMode.step == last_step:
			continue
		last_step = TutorialMode.step
		seen.append(int(last_step))
		# 关键：这里**不调** save_checkpoint()。盘上是什么就是什么。
		var saved := SaveManager.load_tutorial()
		var saved_step := int(saved.get("step", -1))
		if saved_step != int(last_step):
			lagged.append("%s(盘上=%d)" % [TutorialMode.step_key(), saved_step])
		else:
			# 步号也必须跟上，否则恢复后进度条会倒退。
			var saved_index := int(saved.get("progress_index", -1))
			if saved_index != TutorialMode.step_number() - 1:
				lagged.append("%s(步号盘上=%d 实际=%d)"
					% [TutorialMode.step_key(), saved_index + 1, TutorialMode.step_number()])
		# 步号对上还不够：断点还得是**这一局**的快照，不能是某个旧状态。
		#
		# 不能拿盘上的内容去比实时状态 —— 断点是推进那一刻的快照，之后玩家还会
		# 继续买、继续摆，几帧后再比必然不等，那样的断言只是把噪声当缺陷。
		# 真正的不变式是单调性：教程里宝藏、佣兵、累计采购只增不减，
		# 断点里这三个数一旦回退，就说明写进去的是一份过期快照。
		var owned := [
			int((saved.get("owned_treasures", []) as Array).size()),
			_non_null_count(saved.get("mercenary_slots", [])),
			int(saved.get("bought_units", 0)),
		]
		for i in owned.size():
			if owned[i] < monotone[i]:
				mismatched.append("%s[%s] %d -> %d"
					% [TutorialMode.step_key(), MONOTONE_FIELDS[i], monotone[i], owned[i]])
			monotone[i] = maxi(monotone[i], owned[i])

	# 守卫：走不完就别拿「没有落后的步骤」当通过 —— 空集上恒真。
	_h.expect(seen.size() >= 12, "step_walk_covered_too_little",
		"只推进了 %d 步（预期 ≥12）—— 这一组等于没测" % seen.size())
	_h.expect(TutorialMode.step == TutorialScript.Step.DONE, "step_walk_did_not_finish",
		"教程没走到 DONE，停在 %s" % TutorialMode.step_key())
	_h.expect(lagged.is_empty(), "checkpoint_lags_behind_step",
		"这些步骤推进后断点没有立刻跟上（强杀会退回上一步）：%s" % str(lagged))
	_h.expect(mismatched.is_empty(), "checkpoint_state_went_backwards",
		"这些步骤的断点里，只增不减的东西反而变少了（写进去的是过期快照）：%s"
			% str(mismatched))
	_h.expect(monotone[0] >= 2 and monotone[1] >= 2 and monotone[2] >= 3,
		"monotone_probe_saw_too_little",
		("走完全程后断点里只见到 宝藏=%d 佣兵=%d 采购=%d —— "
			+ "样本太少，单调性断言等于没测") % [monotone[0], monotone[1], monotone[2]])
	_h.expect(_main_save_digest() == main_save_before, "tutorial_touched_main_save",
		"教程走完之后主存档字节变了 —— 它参与 replay / final-state SHA，必须原封不动")

	prep.queue_free()
	await _settle(3)
	TutorialMode.finish()
	GameState.reset_run()


# step 只能由三处直接赋值：start()（刚 clear 过断点）、restore_checkpoint()
# （正在从断点读回来）、以及 _advance_to() 自己。别处直接赋值就会漏落盘 ——
# 逐点补 save_checkpoint() 治不住，下次加步骤照样会漏。
func _check_step_writes_are_funnelled() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/tutorial/TutorialMode.gd")
	var funcs := _split_funcs(src)
	const ALLOWED := ["start", "restore_checkpoint", "_advance_to"]
	var offenders: Array[String] = []
	for fname in funcs.keys():
		if ALLOWED.has(str(fname)):
			continue
		var body: String = funcs[fname]
		for raw in body.split("\n"):
			var line := str(raw)
			var trimmed := line.strip_edges()
			if trimmed.begins_with("step = ") or trimmed.begins_with("step="):
				offenders.append("%s: %s" % [fname, trimmed])
	_h.expect(offenders.is_empty(), "step_assigned_outside_mutator",
		("这些地方绕过 _advance_to() 直接赋值 step —— 推进不会落盘：%s")
			% str(offenders))
	var mutator: String = funcs.get("_advance_to", "")
	_h.expect(mutator.contains("save_checkpoint()"), "mutator_does_not_persist",
		"_advance_to() 没有落盘 —— 收口了但没解决问题")
	_h.expect(mutator.contains("_sync_progress_index()"), "mutator_skips_progress_index",
		"_advance_to() 没有同步步号 —— 盘上的 progress_index 会落后一步")


# 主存档三个变体的字节摘要。教程期间这个值必须一动不动。
func _main_save_digest() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for path in [SaveManager.SAVE_PATH, SaveManager.SAVE_PATH + ".bak",
			SaveManager.SAVE_PATH + ".tmp"]:
		ctx.update(path.to_utf8_buffer())
		if FileAccess.file_exists(path):
			ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


func _non_null_count(value) -> int:
	if not (value is Array):
		return 0
	var n := 0
	for entry in (value as Array):
		if entry != null:
			n += 1
	return n
