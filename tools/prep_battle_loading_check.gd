extends Node

# V3 P0-06 component/integration gate. Actual battle math is intentionally not
# run here; replay parity remains owned by the existing desktop/Android baselines.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const OverlayScene := preload("res://ui/components/GloryLoadingOverlay.tscn")
const PrepScreenScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "prep_battle_loading"


class BattlePrepareProbe:
	extends RefCounted

	signal released

	var modes: Array[String] = []
	var call_count := 0


	func invoke(_request_id: String) -> Dictionary:
		call_count += 1
		var mode := modes[call_count - 1] if call_count <= modes.size() else "succeeded"
		match mode:
			"hold_succeeded":
				await released
				return {"result": "succeeded"}
			"invalid_replay":
				return {
					"result": "failed",
					"error_code": "TEAM_REPLAY_INVALID",
					"message": "Injected invalid replay",
					"retryable": true,
				}
			"network_interrupted":
				return {
					"result": "failed",
					"error_code": "NETWORK_INTERRUPTED",
					"message": "Injected network interruption",
					"retryable": true,
				}
		return {"result": "succeeded"}


var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_effect_prefetch_roster()
	var baseline: Array = ModalStack.find_invisible_stop_controls()
	await _check_overlay_contract()
	await _check_failure_recovery_paths()
	await _check_offline_success_path()
	await _check_wait_escalation()
	await _check_wait_resets_on_progress()
	await get_tree().process_frame
	var after: Array = ModalStack.find_invisible_stop_controls()
	var leaked: Array = []
	for path in after:
		if not baseline.has(path):
			leaked.append(path)
	_h.expect(leaked.is_empty(), "loading_overlay_stop_leak",
		"关闭加载层后残留不可见 STOP 控件：%s" % ", ".join(leaked))
	_check_prep_source_contract()
	_h.finish(get_tree())


func _check_effect_prefetch_roster() -> void:
	var board := GameState.board_slots
	var mercenaries := GameState.mercenary_slots
	var round_before := GameState.round_index
	var seed_before := NetworkService.shared_seed
	GameState.board_slots = [{"id":"prefetch_player", "def":{"skill_id":"every_fourth_combo"}}]
	GameState.mercenary_slots = [{"id":"prefetch_mercenary", "def":{"skill_id":"black_hole"}}]
	NetworkService.shared_seed = 314159
	var prep := PrepScreenScript.new()
	for round_number in range(1, GameState.FINAL_ROUND + 1):
		GameState.round_index = round_number
		var roster: Dictionary = prep._effect_prefetch_replay().roster
		_h.expect(roster.has("prefetch_player") and roster.has("prefetch_mercenary"),
			"deployed_roster_missing", "预热阵容必须包含当前棋盘和佣兵")
		var kind := RoundService.schedule_kind_for_round(round_number)
		if kind in ["pvp", "final"]:
			_h.expect(roster.size() == 2, "unknown_enemy_prefetched", "PVP 未知敌人不能编造预热阵容")
		else:
			var expected := BattleSimShared._round_monster_template(round_number)
			_h.expect(roster.has(str(expected.id)), "wrong_round_prefetched", "预热应命中即将开战的当前回合怪物")
			if kind == "boss":
				var boss := BattleSimShared._round_boss_template(round_number)
				_h.expect(roster.has(str(boss.id)), "boss_not_prefetched", "Boss 回合必须提前预热 Boss")
	prep.free()
	GameState.board_slots = board
	GameState.mercenary_slots = mercenaries
	GameState.round_index = round_before
	NetworkService.shared_seed = seed_before


func _check_overlay_contract() -> void:
	_h.expect(ModalStack.depth() == 0, "modal_stack_dirty_start",
		"加载检查开始时 ModalStack depth=%d" % ModalStack.depth())
	var overlay = OverlayScene.instantiate()
	var modal_id := ModalStack.push(overlay, {
		"id": "check_battle_loading",
		"owner": self,
		"priority": 80,
	})
	overlay.configure({
		"request_id": "load_1",
		"title": "Battle Preparation",
		"stage_key": "wait_server",
		"stage_text": "Waiting for Server",
		"detail": "Team ready 1/2",
		"cancellable": true,
	})
	await get_tree().process_frame

	_h.expect(not modal_id.is_empty(), "loading_modal_push_failed", "加载层无法进入 ModalStack")
	_h.expect(ModalStack.depth() == 1, "loading_modal_depth_wrong",
		"加载层打开后 ModalStack depth=%d，应为 1" % ModalStack.depth())
	var host := overlay.get_parent()
	while host != null and not (host is CanvasLayer):
		host = host.get_parent()
	_h.expect(host is CanvasLayer, "loading_not_on_canvas_layer",
		"加载 UI 没有位于独立 CanvasLayer")
	var dump: Array = ModalStack.dump_modal_stack()
	_h.expect(not dump.is_empty() and str(dump[0].get("backdrop_filter", "")) == "STOP",
		"loading_does_not_block_input", "加载期间没有明确的全屏输入阻挡层")

	# A fatal/error dialog priority sits above loading. Here a dummy high-priority
	# modal proves the ordering without opening a production dialog.
	var fatal := Control.new()
	fatal.name = "FatalProbe"
	var fatal_id := ModalStack.push(fatal, {"id": "fatal_probe", "owner": self, "priority": 100})
	await get_tree().process_frame
	_h.expect(ModalStack.top_id() == fatal_id, "fatal_dialog_below_loading",
		"高优先级错误层没有显示在战斗加载层上方")
	ModalStack.pop(fatal_id, "check")

	# Unknown duration: spinner, no fabricated percentage.
	overlay.set_stage("wait_server", "Waiting for Server", "Team ready 1/2", -1.0)
	var progress := overlay.find_child("LoadingProgress", true, false) as ProgressBar
	var spinner := overlay.find_child("IndeterminateMarker", true, false) as Label
	_h.expect(progress != null and not progress.visible, "unknown_progress_shows_percent",
		"未知时长阶段仍显示百分比，会伪造进度")
	_h.expect(spinner != null and spinner.visible, "unknown_progress_no_indeterminate",
		"未知时长阶段没有 indeterminate 反馈")

	# Known progress is monotonic even if a late producer reports an older value.
	overlay.set_progress(0.62, "Models 6/10")
	overlay.set_progress(0.31, "Models 6/10")
	var snap: Dictionary = overlay.snapshot()
	_h.expect(is_equal_approx(float(snap.get("progress", 0.0)), 0.62),
		"loading_progress_regressed", "进度从 62% 被迟到更新退回到 31%")
	await _capture_if_requested("")

	# Failure always has a stable code and at most one emitted recovery action.
	var retries := [0]
	overlay.retry_requested.connect(func(_rid: String) -> void: retries[0] = int(retries[0]) + 1)
	overlay.set_failed("TEAM_REPLAY_TIMEOUT", "Timed out", true)
	var retry := overlay.find_child("RetryButton", true, false) as Button
	var cancel := overlay.find_child("CancelButton", true, false) as Button
	var error := overlay.find_child("LoadingErrorCode", true, false) as Label
	_h.expect(retry != null and retry.visible, "loading_retry_missing", "可重试失败页没有 Retry")
	_h.expect(cancel != null and cancel.visible, "loading_return_missing", "失败页没有返回备战")
	_h.expect(error != null and error.visible and error.text.contains("TEAM_REPLAY_TIMEOUT"),
		"loading_error_code_missing", "失败页没有稳定错误码")
	await _capture_if_requested("_failed")
	retry.pressed.emit()
	retry.pressed.emit()
	_h.expect(int(retries[0]) == 1, "loading_recovery_double_emit",
		"失败页快速连点触发 %d 次 retry，应为 1" % int(retries[0]))

	ModalStack.pop(modal_id, "check")
	await get_tree().process_frame
	_h.expect(ModalStack.depth() == 0, "loading_modal_not_closed",
		"加载层关闭后 ModalStack depth=%d" % ModalStack.depth())


func _check_prep_source_contract() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/prep/PrepScreen.gd")
	_h.expect(not source.is_empty(), "prep_source_unreadable", "无法读取 PrepScreen.gd")
	_h.expect(not source.contains("z_index = -4"), "loading_still_behind_prep",
		"旧 z_index=-4 加载条仍存在")
	_h.expect(source.contains("AsyncActionController.begin(BATTLE_ACTION"),
		"start_battle_not_controller_owned", "开始战斗没有接入 AsyncActionController")
	_h.expect(source.contains("show_pending(request_id, tr(\"battle_load_busy\"))"),
		"start_button_silent_disabled", "开始战斗没有在 pending 时显示 busy 动词")
	for stage in ["submit_roster", "wait_team_server", "generate_replay", "receive_replay",
			"load_battle_scene", "load_battle_assets", "enter_battle"]:
		_h.expect(source.contains("\"%s\"" % stage), "battle_stage_missing",
			"开始战斗缺阶段 %s" % stage)
	_h.expect(source.contains("BattleAssetService.release_owner(BattleAssetService.OWNER_BATTLE)"),
		"cancel_does_not_release_assets", "失败/取消没有释放 battle 资源 owner")
	_h.expect(source.contains("if not _battle_request_is_active(request_id)"),
		"late_result_guard_missing", "异步等待后没有 request id 迟到结果守卫")
	_h.expect(source.contains("if OS.is_debug_build() and _battle_prepare_check_hook.is_valid()"),
		"failure_injection_not_debug_guarded", "故障注入接口没有被 debug build 守卫")


func _check_failure_recovery_paths() -> void:
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "failure_prep_scene_load_failed",
			"故障恢复用例无法加载 PrepScreen"):
		return
	var prep: PrepScreenScript = packed.instantiate() as PrepScreenScript
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	var prefetch_deadline := Time.get_ticks_msec() + 5000
	while PrepScreenScript._cached_battle_scene == null and Time.get_ticks_msec() < prefetch_deadline:
		await get_tree().process_frame
	_h.expect(PrepScreenScript._cached_battle_scene is PackedScene and not prep.is_committing_to_battle(),
		"scene_not_prefetched_in_prep", "未开始战斗时就应异步载入并持有战斗场景")
	var emitted := [0]
	prep.battle_requested.connect(func() -> void: emitted[0] = int(emitted[0]) + 1)

	# Invalid replay must be visible and retry must create a fresh request. The
	# retry is then failed as an interrupted network response, proving that the
	# second result cannot be mistaken for the first request's result.
	var failure_probe := BattlePrepareProbe.new()
	failure_probe.modes = ["invalid_replay", "network_interrupted"]
	_h.expect(prep.set_battle_prepare_check_hook(failure_probe.invoke),
		"failure_hook_rejected", "debug 构建拒绝安装战斗准备故障注入 hook")
	prep._emit_battle_request_once()
	var invalid_snap := await _wait_for_loading_mode(prep, "failed")
	var invalid_request := prep.battle_action_request_id_for_check()
	_h.expect(str(invalid_snap.get("error_code", "")) == "TEAM_REPLAY_INVALID",
		"invalid_replay_code_missing", "无效 replay 失败页没有 TEAM_REPLAY_INVALID")
	prep._on_battle_loading_retry_requested(invalid_request)
	var network_snap := await _wait_for_loading_mode(prep, "failed")
	var retry_request := prep.battle_action_request_id_for_check()
	_h.expect(not retry_request.is_empty() and retry_request != invalid_request,
		"retry_reused_request_id", "Retry 没有创建新的 request id")
	_h.expect(str(network_snap.get("error_code", "")) == "NETWORK_INTERRUPTED",
		"network_interruption_code_missing", "网络中断失败页没有 NETWORK_INTERRUPTED")
	_return_from_failed_loading(prep)
	await get_tree().process_frame

	# A resource can finish threaded loading and still be the wrong type. This
	# covers the scene decode/type error without referencing a deliberately
	# missing path (which would pollute the engine-error gate).
	var scene_probe := BattlePrepareProbe.new()
	scene_probe.modes = ["succeeded"]
	prep.set_battle_prepare_check_hook(scene_probe.invoke)
	prep.set_battle_scene_path_for_check("res://scripts/autoload/LocaleManager.gd")
	prep._emit_battle_request_once()
	var scene_snap := await _wait_for_loading_mode(prep, "failed")
	_h.expect(str(scene_snap.get("error_code", "")) == "BATTLE_SCENE_EMPTY",
		"scene_type_failure_code_missing", "错误资源类型没有稳定 BATTLE_SCENE_EMPTY 错误码")
	_return_from_failed_loading(prep)
	prep.set_battle_scene_path_for_check("")
	await get_tree().process_frame

	# Deterministically move the watchdog clock beyond the 90 s deadline. The
	# pending producer is released afterwards; its late success must be ignored.
	var timeout_probe := BattlePrepareProbe.new()
	timeout_probe.modes = ["hold_succeeded"]
	prep.set_battle_prepare_check_hook(timeout_probe.invoke)
	prep._emit_battle_request_once()
	await _wait_for_probe_call(timeout_probe, 1)
	AsyncActionController.poll(Time.get_ticks_msec() + 120000)
	var timeout_snap := await _wait_for_loading_mode(prep, "failed")
	_h.expect(str(timeout_snap.get("error_code", "")) == "ACTION_TIMEOUT",
		"timeout_failure_code_missing", "超时失败页没有 ACTION_TIMEOUT")
	timeout_probe.released.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(int(emitted[0]) == 0, "timed_out_result_entered_battle",
		"已超时 producer 的迟到结果仍触发了 battle_requested")
	_return_from_failed_loading(prep)
	await get_tree().process_frame

	# Cancel a held producer, start a fresh request, then release the old one.
	# Exactly the fresh request may enter battle.
	var cancel_probe := BattlePrepareProbe.new()
	cancel_probe.modes = ["hold_succeeded", "succeeded"]
	prep.set_battle_prepare_check_hook(cancel_probe.invoke)
	prep._emit_battle_request_once()
	await _wait_for_probe_call(cancel_probe, 1)
	var cancelled_request := prep.battle_action_request_id_for_check()
	prep._on_battle_loading_cancel_requested(cancelled_request)
	await get_tree().process_frame
	_h.expect(prep.battle_loading_snapshot_for_check().is_empty(),
		"cancelled_overlay_leaked", "取消后战斗加载 overlay 未关闭")
	_h.expect(int(AsyncActionController.dump_action_state().get("active_count", -1)) == 0,
		"cancelled_action_stale", "取消后仍有 pending action")
	prep._emit_battle_request_once()
	await _wait_for_probe_call(cancel_probe, 2)
	var fresh_request := prep.battle_action_request_id_for_check()
	_h.expect(not fresh_request.is_empty() and fresh_request != cancelled_request,
		"cancel_retry_reused_request_id", "取消后重试没有创建新的 request id")
	var enter_deadline := Time.get_ticks_msec() + 15000
	while int(emitted[0]) == 0 and Time.get_ticks_msec() < enter_deadline:
		await get_tree().process_frame
	cancel_probe.released.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(int(emitted[0]) == 1, "cancel_late_result_wrong_emit_count",
		"取消+重试+迟到响应后 battle_requested 次数=%d，应为 1" % int(emitted[0]))
	_h.expect(ModalStack.depth() == 0, "failure_recovery_overlay_leaked",
		"故障恢复用例结束后 ModalStack depth=%d，应为 0" % ModalStack.depth())
	prep.take_loaded_battle_scene()
	prep.queue_free()
	await get_tree().process_frame


func _wait_for_loading_mode(prep: PrepScreenScript, wanted_mode: String,
		timeout_msec: int = 5000) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_msec
	var snapshot: Dictionary = prep.battle_loading_snapshot_for_check()
	while str(snapshot.get("mode", "")) != wanted_mode and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		snapshot = prep.battle_loading_snapshot_for_check()
	return snapshot


func _wait_for_probe_call(probe: BattlePrepareProbe, wanted_count: int,
		timeout_msec: int = 5000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while probe.call_count < wanted_count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_h.expect(probe.call_count >= wanted_count, "prepare_probe_not_called",
		"故障注入 producer 调用次数=%d，预期至少 %d" % [probe.call_count, wanted_count])


func _return_from_failed_loading(prep: PrepScreenScript) -> void:
	var request_id := prep.battle_action_request_id_for_check()
	if not request_id.is_empty():
		prep._on_battle_loading_cancel_requested(request_id)


func _check_offline_success_path() -> void:
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "离线成功用例无法加载 PrepScreen"):
		return
	var prep: PrepScreenScript = packed.instantiate() as PrepScreenScript
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	var emitted := [0]
	prep.battle_requested.connect(func() -> void: emitted[0] = int(emitted[0]) + 1)
	prep._emit_battle_request_once()
	var deadline := Time.get_ticks_msec() + 15000
	while int(emitted[0]) == 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_h.expect(int(emitted[0]) == 1, "offline_start_did_not_complete",
		"离线开始战斗在 15 秒内没有恰好发出一次 battle_requested")
	_h.expect(ModalStack.depth() == 0, "offline_success_overlay_leaked",
		"离线成功后加载 overlay 仍留在 ModalStack")
	var action_dump: Dictionary = AsyncActionController.dump_action_state()
	_h.expect(int(action_dump.get("active_count", -1)) == 0,
		"offline_success_action_stale", "离线成功后仍有 pending action")
	var loaded = prep.take_loaded_battle_scene()
	_h.expect(loaded is PackedScene, "offline_success_scene_missing",
		"离线成功发信号时没有准备好 BattleScreen PackedScene")
	prep.queue_free()
	await get_tree().process_frame


func _capture_if_requested(suffix: String) -> void:
	var requested := OS.get_environment("BATTLE_LOADING_CAPTURE_PATH")
	if requested.is_empty():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var path := requested
	if not suffix.is_empty():
		path = requested.get_basename() + suffix + ".png"
	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		_h.note("headless renderer 没有 viewport texture，跳过可选截图：%s" % path)
		return
	var image := viewport_texture.get_image()
	if image == null:
		_h.note("headless renderer 没有可读 image，跳过可选截图：%s" % path)
		return
	_h.expect(image.save_png(path) == OK, "loading_capture_failed",
		"加载界面截图无法写入 %s" % path)


# V3 P1-05：等待到 2 秒解释原因、8 秒给出路。
#
# 迁移前加载层完全没有时间维度：卡在「等待服务器」上无论多久，画面都是同一句话
# 加一个转圈的菱形。玩家唯一能做的判断是「它是不是死了」，而那个判断没有依据。
#
# 三条硬约束一起查：
#   1. 不用等待时间伪造完成度（进度条一格都不许自己爬）
#   2. 兜底文案必须指向真实阶段（写死一句「请稍候」等于什么都没说）
#   3. 不可取消时不造一个按不动的取消键，改为把「为什么走不掉」摆到明面上
func _check_wait_escalation() -> void:
	var overlay = OverlayScene.instantiate()
	add_child(overlay)
	await get_tree().process_frame
	overlay.configure({
		"request_id": "slow_1",
		"title": "Battle Preparation",
		"stage_key": "wait_server",
		"stage_text": "等待服务器",
		"cancellable": false,
	})
	# 不确定进度（转圈）：这正是最容易让人以为死机的形态。
	overlay.set_progress(-1.0)
	var progress_before: float = overlay.snapshot().get("progress", -99.0)

	var levels: Array[String] = []
	for i in 10:
		overlay._tick_escalation(1.0)
		levels.append(str(overlay.snapshot().get("escalation_name", "")))

	_h.expect(levels[0] == "QUIET", "wait_escalates_too_early",
		"等待 1 秒就升级了（%s）—— 正常加载会被它吵到" % levels[0])
	_h.expect(levels[1] == "EXPLAINED", "wait_explain_missed",
		"等待 2 秒没有解释原因，实际是 %s" % levels[1])
	_h.expect(levels[7] == "ESCAPE_OFFERED", "wait_escape_missed",
		"等待 8 秒没有给出路，实际是 %s" % levels[7])

	var snap: Dictionary = overlay.snapshot()
	_h.expect(is_equal_approx(float(snap.get("progress", -99.0)), float(progress_before)),
		"wait_escalation_fakes_progress",
		"升级过程推动了进度 —— 那是在用等待时间伪造完成度")
	_h.expect(bool(snap.get("explanation_visible", false)),
		"wait_explanation_not_shown", "升级之后没有任何可见解释")
	# 不可取消：不给假的取消键，但必须说清为什么走不掉。
	_h.expect(not bool(snap.get("cancel_visible", true)),
		"wait_fabricates_cancel",
		"不可取消的动作在 8 秒后长出了取消键 —— 按不动的出口比没有更糟")
	_h.expect(bool(snap.get("policy_visible", false)),
		"wait_no_reason_when_uncancellable",
		"不可取消却没有说明原因，玩家只能干等")

	# 换成可取消的同一条路径：8 秒后必须真的给出取消键。
	var overlay2 = OverlayScene.instantiate()
	add_child(overlay2)
	await get_tree().process_frame
	overlay2.configure({
		"request_id": "slow_2",
		"title": "Battle Preparation",
		"stage_key": "wait_server",
		"stage_text": "等待服务器",
		"cancellable": true,
	})
	overlay2.set_progress(-1.0)
	overlay2._cancel_button.visible = false
	for i in 10:
		overlay2._tick_escalation(1.0)
	_h.expect(bool(overlay2.snapshot().get("cancel_visible", false)),
		"wait_escape_not_offered",
		"可取消的动作等了 8 秒仍然没有露出取消键")

	# 文案必须跟着阶段走：换个阶段名，解释里那一句得跟着变。
	var text_a: String = overlay._detail_label.text
	overlay.set_stage("wait_opponent", "等待对手", "", -1.0)
	for i in 10:
		overlay._tick_escalation(1.0)
	_h.expect(overlay._detail_label.text != text_a, "wait_text_ignores_stage",
		"两个阶段慢下来时给出同一句话 —— 玩家看不出在等什么")

	overlay.queue_free()
	overlay2.queue_free()
	await get_tree().process_frame


# 进度在动就不算慢。冷启动第一次解压资源本来就慢，那种情况下弹「是不是卡住了」
# 比不弹更糟 —— 玩家会去杀进程。
func _check_wait_resets_on_progress() -> void:
	var overlay = OverlayScene.instantiate()
	add_child(overlay)
	await get_tree().process_frame
	overlay.configure({
		"request_id": "slow_3",
		"title": "Battle Preparation",
		"stage_key": "download",
		"stage_text": "下载对局数据",
		"cancellable": true,
	})
	for i in 10:
		# 每秒推进 10%：慢，但一直在动。
		overlay.set_progress(float(i + 1) * 0.1)
		overlay._tick_escalation(1.0)
	_h.expect(str(overlay.snapshot().get("escalation_name", "")) == "QUIET",
		"wait_ignores_progress",
		"进度一直在推进却升到了 %s —— 慢被当成了卡住"
			% str(overlay.snapshot().get("escalation_name", "")))
	overlay.queue_free()
	await get_tree().process_frame
