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
const CHECKPOINT_STEPS := [1, 6, 10, 15]
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
		TutorialScript.Step.BUY_3, TutorialScript.Step.UPGRADE_2, \
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
