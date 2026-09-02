extends Node

# V2 P1-07 专项门禁：教学第 15 步（FILL_7）的三个子阶段与防卡死。
#
# **驱动方式**：全部走真实生产接口，没有屏幕坐标、没有伪造「点击成功」——
#   * 买棋子   -> `_shop.buttons[i].pressed` 选卡 + `_shop.buy_button.pressed` 采购，
#                 与玩家点的是同两个 Button，成不成交仍由宿主的钱/待命区/售罄判断决定
#   * 开关商店 -> `_shop.open_button.pressed`
#   * 上阵     -> `_board_hud.bench_buttons[i].pressed` + `_board_hud.buttons[j].pressed`
#   * 继续     -> 教学气泡自己的透明热区 `TutorialMode._hotspot.pressed`
#   * 战斗     -> `TutorialMode.begin_battle()` + `after_battle({})`，无需服务器
#
# **覆盖范围**：完整 17 个实际到访步骤（不是只跑 HIRE_MERC→DONE）。
# 之所以能做到，是因为战斗步不依赖网络：`begin_battle()` 只校验 `can_start_battle()`，
# `after_battle()` 只按当前步推进并派发下一批商店/宝藏。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "tutorial_step15_flow"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

const RUNS := 20
# 每个阶段的驱动动作上限，防止实现回归时门禁变成死循环而不是红灯。
const ACTION_BUDGET := 40

const METRICS: PackedStringArray = [
	"root_children", "canvas_layers", "stop_controls", "invisible_stop",
	"modal_depth", "timers", "signal_connections", "orphans", "nodes",
]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	_check_sequence_contract()
	await _check_twenty_runs()
	await _check_recovery_auto_merge()
	await _check_recovery_bench_full()
	await _check_recovery_already_owned()
	await _check_recovery_unbuyable_shop()
	await _check_idempotent_events()
	await _check_no_internal_keys_in_text()

	TutorialMode.finish()
	GameState.reset_run()
	await _settle(4)
	_h.finish(get_tree())


# --- 17 步没有被删减（序列合同）------------------------------------------------

func _check_sequence_contract() -> void:
	_h.expect(TutorialScript.STEP_SEQUENCE.size() == 17, "sequence_size_changed",
		"STEP_SEQUENCE 现在是 %d 步，本门禁按 17 个实际到访步骤写"
			% TutorialScript.STEP_SEQUENCE.size())
	_h.expect(int(TutorialScript.STEP_SEQUENCE[14]) == TutorialScript.Step.FILL_7,
		"fill7_not_fifteenth",
		"第 15 个到访步骤不再是 FILL_7 —— 本任务按稳定的步骤状态表达，不写 step==15 特判，"
		+ "但门禁要能发现序列被改动")
	_h.expect(TutorialScript.FILL_TARGET_UNITS == GameConstants.NORMAL_UNIT_CAP,
		"fill_target_detached",
		"FILL_TARGET_UNITS 脱离了生产常量 NORMAL_UNIT_CAP")


# --- 20 次完整流程 --------------------------------------------------------------

func _check_twenty_runs() -> void:
	# 先跑一轮热身，吸收场景/材质/字体这类一次性懒初始化，再取泄漏基线。
	var warm := await _run_once(0, false)
	_h.expect(bool(warm.get("done", false)), "warmup_run_failed",
		"热身那一轮就没跑到 DONE：%s" % str(warm.get("why", "")))
	await _settle(6)
	var baseline := _snapshot()
	_h.note("热身后的基线：%s" % JSON.stringify(baseline))

	var completed := 0
	var worst_phase_issue := ""
	for i in RUNS:
		var r := await _run_once(i + 1, true)
		if bool(r.get("done", false)):
			completed += 1
		else:
			if worst_phase_issue.is_empty():
				worst_phase_issue = str(r.get("why", ""))
		# 三个子阶段必须按 BUY -> CLOSE_SHOP -> DEPLOY 的顺序各出现一次，不跳、不倒退。
		var phases: Array = r.get("phases", [])
		_h.expect(phases == [
				TutorialScript.FillPhase.BUY,
				TutorialScript.FillPhase.CLOSE_SHOP,
				TutorialScript.FillPhase.DEPLOY,
			], "phase_order_wrong",
			"第 %d 轮的子阶段序列是 %s，应为 BUY -> CLOSE_SHOP -> DEPLOY" % [i + 1, str(phases)])
		var bought: Array = r.get("bought_trace", [])
		var regressed := false
		for k in range(1, bought.size()):
			if int(bought[k]) < int(bought[k - 1]):
				regressed = true
		_h.expect(not regressed, "buy_progress_regressed",
			"第 %d 轮购买进度倒退了：%s" % [i + 1, str(bought)])
		_h.expect(int(r.get("visited", 0)) == 17, "not_all_steps_visited",
			"第 %d 轮只走到 %d 个实际步骤，应为 17" % [i + 1, int(r.get("visited", 0))])

	_h.expect(completed == RUNS, "completion_rate_below_100",
		"%d/%d 轮跑到 DONE，完成率不是 100%%（首个失败原因：%s）"
			% [completed, RUNS, worst_phase_issue])

	await _settle(8)
	var after := _snapshot()
	_h.note("%d 轮后：%s" % [RUNS, JSON.stringify(after)])
	var grew := _growth(baseline, after)
	_h.expect(grew.is_empty(), "run_loop_left_residue",
		"%d 轮完整教学之后相对热身基线仍有残留：%s" % [RUNS, _describe(grew)])


# 跑一整局教学。返回 {done, visited, phases, bought_trace, why}
func _run_once(index: int, trace: bool) -> Dictionary:
	var out := {
		"done": false, "visited": 0, "phases": [], "bought_trace": [], "why": "",
	}
	TutorialMode.start()
	var prep := _new_prep()
	if prep == null:
		out["why"] = "PrepScreen 实例化失败"
		return out
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)

	var visited: Array = []
	var phases: Array = []
	var bought: Array = []
	var guard := 0
	while TutorialMode.step != TutorialScript.Step.DONE and guard < 200:
		guard += 1
		var before_step: int = TutorialMode.step
		# 记的是**序列位置**而不是枚举值：FORMATION_HP 在 STEP_SEQUENCE 里出现两次，
		# 按枚举去重永远只有 16 个。
		var pos := TutorialMode.step_number()
		if not visited.has(pos):
			visited.append(pos)
		if before_step == TutorialScript.Step.FILL_7:
			var ph: int = TutorialMode.fill_phase()
			if phases.is_empty() or int(phases[phases.size() - 1]) != ph:
				phases.append(ph)
			bought.append(int(TutorialMode.fill_buy_progress()[0]))
		await _drive_current_step(prep)
		if TutorialMode.step == before_step and guard % 8 == 0:
			# 卡住了：再推一次 sync 也没用就直接失败，不要空转到 guard 上限。
			TutorialMode.sync()
			await _settle(2)
	if TutorialMode.step == TutorialScript.Step.DONE and not visited.has(TutorialMode.step_number()):
		visited.append(TutorialMode.step_number())
	out["visited"] = visited.size()
	out["phases"] = phases
	out["bought_trace"] = bought
	out["done"] = TutorialMode.step == TutorialScript.Step.DONE
	if not bool(out["done"]):
		out["why"] = "停在 %s（guard=%d）" % [TutorialMode.step_key(), guard]
	prep.queue_free()
	await _settle(4)
	return out


# 按当前步用真实生产接口推进一步。
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
			await _tap_continue(prep)
		TutorialScript.Step.HIRE_MERC:
			await _hire_merc(prep)
		TutorialScript.Step.FILL_7:
			await _drive_fill_step(prep)
		_:
			await _settle(1)


# FILL_7 的三个子阶段，每个都用它自己的真实入口推进。
func _drive_fill_step(prep: PrepScript) -> void:
	match TutorialMode.fill_phase():
		TutorialScript.FillPhase.BUY:
			await _open_shop(prep)
			await _buy_one(prep)
		TutorialScript.FillPhase.CLOSE_SHOP:
			await _close_shop(prep)
		_:
			await _place_one(prep)


# --- 真实操作 -------------------------------------------------------------------

func _open_shop(prep: PrepScript) -> void:
	if not prep._shop.picker_open and prep._shop.open_button != null:
		prep._shop.open_button.pressed.emit()
		await _settle(2)


func _close_shop(prep: PrepScript) -> void:
	if prep._shop.picker_open and prep._shop.open_button != null:
		prep._shop.open_button.pressed.emit()
		await _settle(2)


# 选一张还没卖掉的卡，再按钱袋上的采购热区 —— 与玩家的两下点击完全一致。
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
	# begin_battle() 会 _detach()，打完要重新挂回当前屏。
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


func _tap_continue(prep: PrepScript) -> void:
	# 教学气泡自己的透明热区，就是玩家「点一下继续」按到的那个 Button。
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


# --- 三类恢复路径 ---------------------------------------------------------------

# 1. 购买过程中发生自动合成：买够了但可上阵数量不足 7，必须自动补偿。
func _check_recovery_auto_merge() -> void:
	var prep := await _arrive_at_fill_step()
	if prep == null:
		return
	var target: int = int(TutorialMode.fill_buy_progress()[1])
	# 造一次必然发生的合成：在待命区放一个与 FILL_SHOP 首项同名同星的棋子，
	# 玩家买它时会融合，成交计数 +1、可上阵数量却不增加。
	var merge_id := str(TutorialScript.FILL_SHOP[0])
	_force_bench_unit(merge_id)
	await _settle(2)
	var owned_before := _owned_count()
	var budget := 0
	while TutorialMode.fill_phase() == TutorialScript.FillPhase.BUY and budget < ACTION_BUDGET:
		budget += 1
		await _open_shop(prep)
		await _buy_one(prep)
	_h.expect(TutorialMode.fill_phase() != TutorialScript.FillPhase.BUY,
		"merge_stuck_in_buy",
		"制造自动合成之后购买阶段没能结束（成交 %d/%d）"
			% [int(TutorialMode.fill_buy_progress()[0]), target])
	_h.expect(_owned_count() >= TutorialScript.FILL_TARGET_UNITS,
		"merge_left_unreachable",
		"离开购买阶段时只有 %d 个可上阵棋子，凑不满 %d —— 上阵阶段将永远完不成"
			% [_owned_count(), TutorialScript.FILL_TARGET_UNITS])
	# 这一组必须真的发生过合成，否则它只是又跑了一遍普通购买、什么都没验证。
	# 没有合成时：持有增长 == 成交数 + 补偿数；合成吃掉一个就会少 1。
	var bought_n := int(TutorialMode.fill_buy_progress()[0])
	var comp := TutorialMode.fill_compensated_count()
	var gained := _owned_count() - owned_before
	_h.expect(gained < bought_n + comp, "merge_scenario_vacuous",
		("这一组本该制造一次自动合成，但持有增长 %d == 成交 %d + 补偿 %d —— "
			+ "合成根本没发生，用例是空过的") % [gained, bought_n, comp])
	_h.note("自动合成用例：持有 %d -> %d，成交 %d，自动补偿 %d 个"
		% [owned_before, _owned_count(), bought_n, comp])
	await _finish_fill_and_expect_next(prep, "merge")


# 2. 待命区在进入或过程中已满。
func _check_recovery_bench_full() -> void:
	var prep := await _arrive_at_fill_step()
	if prep == null:
		return
	for i in GameState.bench_slots.size():
		if GameState.bench_slots[i] == null:
			_force_bench_unit(str(TutorialScript.FILL_SHOP[i % TutorialScript.FILL_SHOP.size()]))
	await _settle(2)
	var full := true
	for cell in GameState.bench_slots:
		if cell == null:
			full = false
	_h.expect(full, "bench_full_setup_failed", "待命区没能填满，这一组用例没有真的跑到")
	TutorialMode.sync()
	await _settle(2)
	_h.expect(TutorialMode.fill_phase() != TutorialScript.FillPhase.BUY,
		"bench_full_stuck_in_buy",
		"待命区已满却还停在购买阶段 —— 玩家买不进去，这是死局")
	_h.expect(_owned_count() >= TutorialScript.FILL_TARGET_UNITS,
		"bench_full_not_enough",
		"待命区满时可上阵棋子只有 %d 个" % _owned_count())
	await _finish_fill_and_expect_next(prep, "bench_full")


# 3. 玩家已经提前达到部分或全部上阵目标。
func _check_recovery_already_owned() -> void:
	var prep := await _arrive_at_fill_step()
	if prep == null:
		return
	# 直接把棋盘补满到 7 —— 模拟玩家在前面几步就攒够了。
	_force_board_to(TutorialScript.FILL_TARGET_UNITS)
	await _settle(2)
	TutorialMode.sync()
	await _settle(3)
	_h.expect(TutorialMode.step == TutorialScript.Step.FORMATION_HP,
		"already_owned_did_not_advance",
		"上阵数已经达标，第 15 步却没有推进（当前 %s）" % TutorialMode.step_key())
	prep.queue_free()
	await _settle(3)


# 4. FILL_SHOP 某个候选不可购买 / 不可生成。
func _check_recovery_unbuyable_shop() -> void:
	var prep := await _arrive_at_fill_step()
	if prep == null:
		return
	# 把商店整排清空：等价于 FILL_SHOP 的候选在数据表里取不到 def。
	for i in GameState.shop_offers.size():
		GameState.shop_offers[i] = {}
	await _settle(1)
	TutorialMode.sync()
	await _settle(3)
	_h.expect(TutorialMode.fill_phase() != TutorialScript.FillPhase.BUY,
		"unbuyable_stuck_in_buy",
		"商店里一个买得到的都没有，购买阶段却不肯结束 —— 玩家被卡死")
	_h.expect(_owned_count() >= TutorialScript.FILL_TARGET_UNITS,
		"unbuyable_not_compensated",
		"商店买不到东西时没有补偿到 %d 个（现在 %d 个）"
			% [TutorialScript.FILL_TARGET_UNITS, _owned_count()])
	# 这一组是**补偿路径本身**的正面覆盖：必须真的发过棋子，不能是「刚好本来就够」。
	_h.expect(TutorialMode.fill_compensated_count() > 0, "compensation_never_ran",
		"商店一个都买不到，自动补偿却一个都没发 —— 补偿分支没有被真正执行过")
	_h.note("商店买不到用例：自动补偿 %d 个，持有 %d 个"
		% [TutorialMode.fill_compensated_count(), _owned_count()])
	await _finish_fill_and_expect_next(prep, "unbuyable")


# --- 幂等：重复开关商店、重复 sync() --------------------------------------------

func _check_idempotent_events() -> void:
	var prep := await _arrive_at_fill_step()
	if prep == null:
		return
	var target: int = int(TutorialMode.fill_buy_progress()[1])

	# 重复开关商店：购买阶段还没完成时不得推进阶段，也不得改动成交计数。
	for i in 5:
		await _open_shop(prep)
		await _close_shop(prep)
	_h.expect(TutorialMode.fill_phase() == TutorialScript.FillPhase.BUY,
		"toggle_skipped_buy_phase",
		"还没买够就因为反复开关商店跳过了购买阶段")
	_h.expect(int(TutorialMode.fill_buy_progress()[0]) == 0, "toggle_faked_progress",
		"反复开关商店制造了 %d 次假的购买进度" % int(TutorialMode.fill_buy_progress()[0]))

	# 先真的买一个，再拿重复 sync() 去砸它 —— 只有已经有进度时，
	# 「重复 sync 不能让计数倒退」这条才检验得出来。
	await _open_shop(prep)
	await _buy_one(prep)
	var bought_after_one := int(TutorialMode.fill_buy_progress()[0])
	_h.expect(bought_after_one >= 1, "single_buy_not_counted",
		"买了一个，成交计数却还是 %d" % bought_after_one)

	# 重复 sync()：不得推进、不得重复补偿、不得把已有进度打回去。
	var comp_before := TutorialMode.fill_compensated_count()
	for i in 10:
		TutorialMode.sync()
	await _settle(2)
	_h.expect(int(TutorialMode.fill_buy_progress()[0]) >= bought_after_one,
		"sync_reset_progress",
		"重复 sync() 把购买进度从 %d 打回到了 %d —— 子阶段被重新初始化了"
			% [bought_after_one, int(TutorialMode.fill_buy_progress()[0])])
	# 只在「还没买够」时才该停在购买阶段；若目标本来就是 1，买完那一个就该往前走。
	if bought_after_one < target:
		_h.expect(TutorialMode.fill_phase() == TutorialScript.FillPhase.BUY,
			"sync_skipped_phase", "还没买够，重复 sync() 却把子阶段推过去了")
	_h.expect(TutorialMode.fill_compensated_count() == comp_before,
		"sync_recompensated", "重复 sync() 重复发放了补偿")
	_h.expect(int(TutorialMode.fill_buy_progress()[1]) == target,
		"sync_reset_target", "重复 sync() 把购买目标重算了 —— 初始化不是只做一次")

	# 买满之后再连点采购：成交计数不得超过目标，阶段不得跳过关闭商店。
	var budget := 0
	while TutorialMode.fill_phase() == TutorialScript.FillPhase.BUY and budget < ACTION_BUDGET:
		budget += 1
		await _open_shop(prep)
		await _buy_one(prep)
	_h.expect(TutorialMode.fill_phase() == TutorialScript.FillPhase.CLOSE_SHOP,
		"did_not_require_close_shop",
		"买齐之后没有进入「关闭商店」阶段（当前 %d）" % TutorialMode.fill_phase())
	_h.expect(int(TutorialMode.fill_buy_progress()[0]) <= target,
		"buy_progress_overflowed",
		"购买进度冲过了目标：%d/%d" % [int(TutorialMode.fill_buy_progress()[0]), target])

	# 关闭商店必须靠真实关闭事件，不是靠等。
	await _settle(6)
	_h.expect(TutorialMode.fill_phase() == TutorialScript.FillPhase.CLOSE_SHOP,
		"close_phase_auto_skipped",
		"没有关商店，「关闭商店」阶段却自己过去了 —— 这是延时跳过，不是观察事件")
	await _close_shop(prep)
	_h.expect(TutorialMode.fill_phase() == TutorialScript.FillPhase.DEPLOY,
		"close_event_ignored", "真的关了商店，阶段却没有推进到上阵")

	await _finish_fill_and_expect_next(prep, "idempotent")


# --- 中英文反馈不得泄漏内部 key -------------------------------------------------

func _check_no_internal_keys_in_text() -> void:
	var locale_before := LocaleManager.get_locale()
	var prep := await _arrive_at_fill_step()
	if prep == null:
		LocaleManager.set_locale(locale_before)
		return
	var forbidden := ["BUY_3", "FILL_7", "PLACE_3", "FORMATION_HP", "START_PVP",
		"HIRE_MERC", "CLOSE_SHOP", "DEPLOY", "FillPhase"]
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(str(locale))
		for phase_pass in 3:
			TutorialMode.sync()
			var text := TutorialMode.current_text()
			_h.expect(not text.is_empty(), "fill_text_empty",
				"%s 下第 15 步的气泡文案是空的" % str(locale))
			for key in forbidden:
				_h.expect(not text.contains(str(key)), "fill_text_leaked_key",
					"%s 下第 15 步文案泄漏了内部标识 %s：%s" % [str(locale), str(key), text])
			_h.expect(not TutorialMode.step_display_name().contains("_"),
				"step_name_leaked_key",
				"%s 下第 15 步的步骤名看起来像内部 key：%s"
					% [str(locale), TutorialMode.step_display_name()])
			# 推进一个子阶段再看下一段文案。
			if TutorialMode.fill_phase() == TutorialScript.FillPhase.BUY:
				await _open_shop(prep)
				var budget := 0
				while TutorialMode.fill_phase() == TutorialScript.FillPhase.BUY \
						and budget < ACTION_BUDGET:
					budget += 1
					await _buy_one(prep)
			elif TutorialMode.fill_phase() == TutorialScript.FillPhase.CLOSE_SHOP:
				await _close_shop(prep)
			else:
				await _settle(1)
	LocaleManager.set_locale(locale_before)
	prep.queue_free()
	await _settle(3)


# --- 脚手架 ---------------------------------------------------------------------

# 从全新教学状态一路开到 FILL_7 的入口，返回活着的 PrepScreen。
func _arrive_at_fill_step() -> PrepScript:
	TutorialMode.start()
	var prep := _new_prep()
	if prep == null:
		return null
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)
	var guard := 0
	while TutorialMode.step != TutorialScript.Step.FILL_7 and guard < 200:
		guard += 1
		await _drive_current_step(prep)
	if not _h.expect(TutorialMode.step == TutorialScript.Step.FILL_7,
			"could_not_reach_fill_step",
			"没能开到第 15 步（停在 %s）" % TutorialMode.step_key()):
		prep.queue_free()
		await _settle(3)
		return null
	return prep


# 把当前这一局的第 15 步走完，断言确实进到了下一步。
func _finish_fill_and_expect_next(prep: PrepScript, tag: String) -> void:
	var guard := 0
	while TutorialMode.step == TutorialScript.Step.FILL_7 and guard < 200:
		guard += 1
		await _drive_fill_step(prep)
	_h.expect(TutorialMode.step == TutorialScript.Step.FORMATION_HP,
		"recovery_did_not_reach_next_step",
		"%s 恢复路径没能走到下一步（停在 %s）" % [tag, TutorialMode.step_key()])
	prep.queue_free()
	await _settle(3)


func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return null
	var prep: PrepScript = packed.instantiate() as PrepScript
	if not _h.expect(prep != null, "prep_wrong_type", "实例化出来的不是 PrepScreen"):
		return null
	add_child(prep)
	return prep


func _owned_count() -> int:
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


func _unit_def(id: String) -> Dictionary:
	# 单位表的键是 race_units（与 TutorialMode._unit_def 一致），不是 units。
	for raw in DataRegistry.get_table("race_units").get("units", []):
		var d: Dictionary = raw
		if str(d.get("id", "")) == id:
			return d
	return {}


func _force_bench_unit(id: String) -> void:
	var def := _unit_def(id)
	if def.is_empty():
		return
	var slot := GameState.bench_slots.find(null)
	if slot < 0:
		return
	GameState.bench_slots[slot] = {"id": id, "star": 1, "def": def.duplicate(true)}


func _force_board_to(count: int) -> void:
	var id := str(TutorialScript.FILL_SHOP[0])
	var def := _unit_def(id)
	if def.is_empty():
		return
	var have := GameState.normal_unit_count()
	for i in GameState.board_slots.size():
		if have >= count:
			break
		if GameState.board_slots[i] == null:
			GameState.board_slots[i] = {"id": id, "star": 1, "def": def.duplicate(true)}
			have += 1


func _snapshot() -> Dictionary:
	var counts := {"canvas_layers": 0, "stop_controls": 0, "timers": 0}
	_walk(get_tree().root, counts)
	return {
		"root_children": get_tree().root.get_child_count(),
		"canvas_layers": int(counts["canvas_layers"]),
		"stop_controls": int(counts["stop_controls"]),
		"invisible_stop": ModalStack.find_invisible_stop_controls().size(),
		"modal_depth": ModalStack.depth(),
		"timers": int(counts["timers"]),
		"signal_connections": TutorialMode.completed.get_connections().size(),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}


func _walk(node: Node, counts: Dictionary) -> void:
	if node is CanvasLayer:
		counts["canvas_layers"] = int(counts["canvas_layers"]) + 1
	if node is Timer:
		counts["timers"] = int(counts["timers"]) + 1
	if node is Control and (node as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
		counts["stop_controls"] = int(counts["stop_controls"]) + 1
	for child in node.get_children():
		_walk(child, counts)


func _growth(before: Dictionary, after: Dictionary) -> Dictionary:
	var out := {}
	for key in METRICS:
		var delta := int(after.get(key, 0)) - int(before.get(key, 0))
		if delta > 0:
			out[key] = delta
	return out


func _describe(d: Dictionary) -> String:
	var parts: Array[String] = []
	for key in d.keys():
		parts.append("%s %+d" % [str(key), int(d[key])])
	return ", ".join(parts)


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
