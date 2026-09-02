extends Node

# C-10 production-wiring gate for Main's player-visible short-code resume. The
# outbound RPC and final navigation are replaced; normalization, lifecycle and
# stale-result handling run through production Main.gd.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "main_team_short_code_resume_action"
const RAW_TOKEN := "  abcd-efgh  "
const NORMALIZED_TOKEN := "ABCD-EFGH"


class FakeMenu:
	extends Control

	var connecting_count := 0
	var connection_errors: Array[String] = []


	func show_connecting() -> void:
		connecting_count += 1


	func show_connection_error(message: String) -> void:
		connection_errors.append(message)


class RequestProbe:
	extends RefCounted

	var call_count := 0
	var request_ids: Array[String] = []
	var token_ids: Array[String] = []


	func invoke(request_id: String, token_id: String) -> void:
		call_count += 1
		request_ids.append(request_id)
		token_ids.append(token_id)


class ResultProbe:
	extends RefCounted

	var call_count := 0
	var request_ids: Array[String] = []
	var results: Array[bool] = []


	func invoke(request_id: String, succeeded: bool) -> void:
		call_count += 1
		request_ids.append(request_id)
		results.append(succeeded)


class OneArgProbe:
	extends RefCounted

	var call_count := 0


	func invoke(_request_id: String) -> void:
		call_count += 1


var _h: CheckHarness
var _states: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var saved := _save_network_state()
	_configure_ready_transport()
	AsyncActionController.reset(MainScript.SHORT_CODE_RESUME_ACTION)
	AsyncActionController.reset(MainScript.PUBLIC_TOKEN_ACTION)
	AsyncActionController.reset(MainScript.ROOM_LIST_ACTION)
	if not AsyncActionController.action_state_changed.is_connected(_record_action_state):
		AsyncActionController.action_state_changed.connect(_record_action_state)

	var main: MainScript = MainScript.new()
	add_child(main)
	await get_tree().process_frame
	var menu := FakeMenu.new()
	main.add_child(menu)
	_h.expect(main.set_team_menu_for_check(menu), "debug_menu_seam_rejected",
		"debug 构建拒绝安装 Main 短码恢复菜单探针")
	var request_probe := RequestProbe.new()
	var result_probe := ResultProbe.new()
	_h.expect(main.set_short_code_resume_request_check_hook(request_probe.invoke),
		"debug_request_seam_rejected", "debug 构建拒绝安装短码恢复请求探针")
	_h.expect(main.set_short_code_resume_result_check_hook(result_probe.invoke),
		"debug_result_seam_rejected", "debug 构建拒绝安装短码恢复结果探针")

	await _check_rapid_taps_normalization_and_success(main, menu, request_probe, result_probe)
	await _check_failure(main, request_probe, result_probe)
	await _check_timeout_and_late_result(main, menu, request_probe, result_probe)
	await _check_cancel_and_late_result(main, request_probe, result_probe)
	await _check_read_actions_are_superseded(main, request_probe, result_probe)
	await _check_empty_token_is_rejected(main, request_probe)
	await _check_navigation_cancels_owner(main, request_probe)
	_check_source_contract()

	if AsyncActionController.action_state_changed.is_connected(_record_action_state):
		AsyncActionController.action_state_changed.disconnect(_record_action_state)
	var final_request := main.short_code_resume_request_id_for_check()
	await get_tree().process_frame
	AsyncActionController.reset(MainScript.SHORT_CODE_RESUME_ACTION, final_request)
	main.queue_free()
	_restore_network_state(saved)
	_h.finish(get_tree())


func _check_rapid_taps_normalization_and_success(
	main: MainScript,
	menu: FakeMenu,
	request_probe: RequestProbe,
	result_probe: ResultProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	for _i in 100:
		main._on_public_token_resume_requested(RAW_TOKEN)
	var request_id := main.short_code_resume_request_id_for_check()
	_h.expect(not request_id.is_empty(), "rapid_request_id_missing",
		"100 次点击后没有短码恢复 request id")
	_h.expect(request_probe.call_count - calls_before == 1,
		"rapid_tap_duplicate_request",
		"100 次快速点击发出了 %d 次短码恢复请求，应为 1" %
			(request_probe.call_count - calls_before))
	_h.expect(menu.connecting_count == 1, "rapid_tap_duplicate_busy_ui",
		"100 次快速点击刷新 connecting UI %d 次，应为 1" % menu.connecting_count)
	_h.expect(request_probe.token_ids.back() == NORMALIZED_TOKEN,
		"token_not_normalized", "短码没有按既有规则 trim + uppercase")
	var snapshot := AsyncActionController.snapshot_for(MainScript.SHORT_CODE_RESUME_ACTION)
	_h.expect(not JSON.stringify(snapshot).contains(NORMALIZED_TOKEN),
		"token_leaked_to_snapshot", "玩家短码泄漏进 AsyncAction 公开快照")
	_h.expect(not JSON.stringify(AsyncActionController.recent_breadcrumbs(10)).contains(NORMALIZED_TOKEN),
		"token_leaked_to_breadcrumb", "玩家短码泄漏进诊断 breadcrumb")
	var states: Array = _states.get(request_id, [])
	_h.expect(states.has(AsyncActionController.STATE_PRESSED), "pressed_state_missing",
		"短码恢复动作没有经过 PRESSED")
	_h.expect(states.has(AsyncActionController.STATE_PENDING), "pending_state_missing",
		"短码恢复动作没有经过 PENDING")

	main._on_resume_completed({"phase": "lobby"})
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_SUCCEEDED,
		"success_state_missing", "恢复状态到达后没有进入 SUCCEEDED")
	_h.expect(result_probe.call_count == 1 and result_probe.results.back(),
		"success_result_missing", "成功短码恢复没有恰好落地一次")
	main._on_resume_completed({"phase": "lobby"})
	_h.expect(result_probe.call_count == 1, "late_success_landed_again",
		"已完成动作的迟到恢复结果再次落地")
	await get_tree().process_frame


func _check_failure(
	main: MainScript,
	request_probe: RequestProbe,
	result_probe: ResultProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	var results_before := result_probe.call_count
	main._on_public_token_resume_requested(NORMALIZED_TOKEN)
	var request_id := main.short_code_resume_request_id_for_check()
	_h.expect(request_probe.call_count - calls_before == 1,
		"failure_request_not_dispatched", "失败用例没有发出短码恢复请求")
	main._on_resume_failed("token_id_unknown")
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_FAILED,
		"failure_state_missing", "resume_failed 没有结算短码恢复为 FAILED")
	_h.expect(result_probe.call_count == results_before + 1 and not result_probe.results.back(),
		"failure_result_missing", "短码恢复失败没有恰好落地一次")
	await get_tree().process_frame


func _check_timeout_and_late_result(
	main: MainScript,
	menu: FakeMenu,
	request_probe: RequestProbe,
	result_probe: ResultProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	var errors_before := menu.connection_errors.size()
	var results_before := result_probe.call_count
	main._on_public_token_resume_requested(NORMALIZED_TOKEN)
	var request_id := main.short_code_resume_request_id_for_check()
	_h.expect(request_probe.call_count - calls_before == 1,
		"timeout_request_not_dispatched", "超时用例没有发出短码恢复请求")
	AsyncActionController.poll(Time.get_ticks_msec() + MainScript.SHORT_CODE_RESUME_TIMEOUT_MSEC + 1)
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_TIMED_OUT,
		"timeout_state_missing", "超过短码恢复 deadline 后没有进入 TIMED_OUT")
	_h.expect(menu.connection_errors.size() == errors_before + 1, "timeout_ui_missing",
		"短码恢复超时没有显示连接错误")
	_h.expect(not NetworkService.team_active, "timeout_transport_not_closed",
		"短码恢复已发出后超时仍保留网络会话")
	main._on_resume_completed({"phase": "lobby"})
	_h.expect(result_probe.call_count == results_before, "timeout_late_result_landed",
		"超时后的迟到恢复结果仍落地")
	await get_tree().process_frame


func _check_cancel_and_late_result(
	main: MainScript,
	request_probe: RequestProbe,
	result_probe: ResultProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	var results_before := result_probe.call_count
	main._on_public_token_resume_requested(NORMALIZED_TOKEN)
	var request_id := main.short_code_resume_request_id_for_check()
	_h.expect(request_probe.call_count - calls_before == 1,
		"cancel_request_not_dispatched", "取消用例没有发出短码恢复请求")
	_h.expect(AsyncActionController.cancel(request_id, "check_cancel"),
		"cancel_rejected", "当前短码恢复 request 无法取消")
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_CANCELLED,
		"cancel_state_missing", "取消后没有进入 CANCELLED")
	_h.expect(not NetworkService.team_active, "cancel_transport_not_closed",
		"取消已发出的短码恢复后仍保留网络会话")
	main._on_resume_failed("token_id_unknown")
	_h.expect(result_probe.call_count == results_before, "cancel_late_result_landed",
		"取消后的迟到失败结果仍落地")
	await get_tree().process_frame


func _check_read_actions_are_superseded(
	main: MainScript,
	resume_probe: RequestProbe,
	result_probe: ResultProbe
) -> void:
	var read_probe := OneArgProbe.new()
	_h.expect(main.set_public_token_request_check_hook(read_probe.invoke),
		"token_hook_rejected", "交叉动作测试无法安装 token 请求探针")
	_h.expect(main.set_room_list_request_check_hook(read_probe.invoke),
		"room_list_hook_rejected", "交叉动作测试无法安装房间列表请求探针")

	_configure_ready_transport()
	main._on_public_token_generate_requested()
	var token_request := main.public_token_request_id_for_check()
	_h.expect(AsyncActionController.is_current(token_request), "token_setup_not_active",
		"交叉动作前置 token 没有进入 active")
	var resume_calls_before := resume_probe.call_count
	main._on_public_token_resume_requested(NORMALIZED_TOKEN)
	var resume_after_token := main.short_code_resume_request_id_for_check()
	_h.expect(_state_for_action(MainScript.PUBLIC_TOKEN_ACTION) ==
		AsyncActionController.STATE_CANCELLED, "resume_did_not_supersede_token",
		"后点短码恢复没有取消先前 token 生成 request")
	_h.expect(resume_probe.call_count - resume_calls_before == 1 and
		AsyncActionController.is_current(resume_after_token), "resume_after_token_not_active",
		"取消 token 生成后，短码恢复 request 没有保持 active")
	main._on_resume_failed("cross_check_cleanup")
	await get_tree().process_frame

	_configure_ready_transport()
	main._on_team_room_list_requested()
	var list_request := main.room_list_request_id_for_check()
	_h.expect(AsyncActionController.is_current(list_request), "list_setup_not_active",
		"交叉动作前置房间列表没有进入 active")
	resume_calls_before = resume_probe.call_count
	var results_before := result_probe.call_count
	main._on_public_token_resume_requested(NORMALIZED_TOKEN)
	var resume_after_list := main.short_code_resume_request_id_for_check()
	_h.expect(_state_for_action(MainScript.ROOM_LIST_ACTION) ==
		AsyncActionController.STATE_CANCELLED, "resume_did_not_supersede_list",
		"后点短码恢复没有取消先前房间列表 request")
	_h.expect(resume_probe.call_count - resume_calls_before == 1 and
		AsyncActionController.is_current(resume_after_list), "resume_after_list_not_active",
		"取消列表后，短码恢复 request 没有保持 active")
	main._on_resume_failed("cross_check_cleanup")
	_h.expect(result_probe.call_count == results_before + 1,
		"cross_cleanup_not_settled", "交叉动作清理没有结算短码恢复")
	await get_tree().process_frame


func _check_empty_token_is_rejected(main: MainScript, probe: RequestProbe) -> void:
	var calls_before := probe.call_count
	main._on_public_token_resume_requested("   ")
	_h.expect(probe.call_count == calls_before, "empty_token_dispatched",
		"空短码仍发出了恢复请求")
	await get_tree().process_frame


func _check_navigation_cancels_owner(main: MainScript, probe: RequestProbe) -> void:
	_configure_ready_transport()
	var calls_before := probe.call_count
	main._on_public_token_resume_requested(NORMALIZED_TOKEN)
	var request_id := main.short_code_resume_request_id_for_check()
	_h.expect(probe.call_count - calls_before == 1, "owner_request_not_dispatched",
		"页面离开用例没有发出短码恢复请求")
	main._clear()
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_CANCELLED,
		"menu_replace_not_cancelled", "Main._clear() 没有取消菜单 owner 的短码恢复")
	_h.expect(not NetworkService.team_active, "owner_cancel_transport_not_closed",
		"菜单 owner 销毁后短码恢复会话仍保持活动")
	await get_tree().process_frame


func _check_source_contract() -> void:
	var main_source := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	var network_source := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	_h.expect(main_source.contains("AsyncActionController.begin(SHORT_CODE_RESUME_ACTION"),
		"resume_not_controller_owned", "短码恢复没有接入 AsyncActionController")
	_h.expect(not main_source.contains("_start_team_menu_action(\"resume_public\")"),
		"legacy_resume_branch_present", "短码恢复仍留在共享 string pending 分支")
	_h.expect(main_source.contains("NetworkService.team_request_public_resume(_short_code_resume_token)"),
		"resume_rpc_changed", "短码恢复没有保持既有 team_request_public_resume RPC")
	_h.expect(main_source.contains("SHORT_CODE_CONNECT_START_FAILED") and
		main_source.contains("SHORT_CODE_CONNECT_FAILED") and
		main_source.contains("SHORT_CODE_RESUME_FAILED"),
		"failure_taxonomy_missing", "短码恢复缺少连接启动/连接状态/恢复失败分类")
	_h.expect(main_source.contains("OS.is_debug_build() and _short_code_resume_request_check_hook.is_valid()"),
		"request_hook_not_debug_guarded", "短码恢复请求故障注入没有 debug build 守卫")
	_h.expect(network_source.contains("_public_resume_pending = true") and
		network_source.contains("elif was_public_resuming:") and
		network_source.contains("resume_completed.emit(payload)"),
		"room_state_completion_bridge_missing", "状态信封没有结算短码恢复成功")
	_h.expect(network_source.contains("public_token_id = token_id.strip_edges().to_upper()") and
		network_source.contains("SaveManager.save_public_token(public_token_id)"),
		"token_normalize_or_save_changed", "短码清洗或存档语义被改变")


func _record_action_state(
	action: String,
	request_id: String,
	state: String,
	_snapshot: Dictionary
) -> void:
	if action != MainScript.SHORT_CODE_RESUME_ACTION:
		return
	if not _states.has(request_id):
		_states[request_id] = []
	(_states[request_id] as Array).append(state)


func _state_of(request_id: String) -> String:
	var states: Array = _states.get(request_id, [])
	return str(states.back()) if not states.is_empty() else ""


func _state_for_action(action: String) -> String:
	return str(AsyncActionController.snapshot_for(action).get("state", ""))


func _configure_ready_transport() -> void:
	NetworkService.team_active = true
	NetworkService.state = NetworkService.SessionState.READY
	NetworkService.team_local_slot = -1
	NetworkService.remote_port = NetworkService.DEFAULT_PORT
	NetworkService.last_error = ""


func _save_network_state() -> Dictionary:
	return {
		"team_active": NetworkService.team_active,
		"state": NetworkService.state,
		"team_local_slot": NetworkService.team_local_slot,
		"remote_port": NetworkService.remote_port,
		"last_error": NetworkService.last_error,
		"public_token_id": NetworkService.public_token_id,
	}


func _restore_network_state(saved: Dictionary) -> void:
	NetworkService.team_active = bool(saved.get("team_active", false))
	NetworkService.state = int(saved.get("state", NetworkService.SessionState.OFFLINE)) as NetworkService.SessionState
	NetworkService.team_local_slot = int(saved.get("team_local_slot", -1))
	NetworkService.remote_port = int(saved.get("remote_port", NetworkService.DEFAULT_PORT))
	NetworkService.last_error = str(saved.get("last_error", ""))
	NetworkService.public_token_id = str(saved.get("public_token_id", ""))
