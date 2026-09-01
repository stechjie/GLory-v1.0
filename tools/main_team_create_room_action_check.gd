extends Node

# C-10 production-wiring gate for Main's create-room action. Only outbound RPC
# and successful navigation are replaced; lifecycle and terminal signals run
# through production Main.gd.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "main_team_create_room_action"


class FakeMenu:
	extends Control

	var connecting_count := 0
	var connection_errors: Array[String] = []
	var room_errors: Array[String] = []


	func show_connecting() -> void:
		connecting_count += 1


	func show_connection_error(message: String) -> void:
		connection_errors.append(message)


	func show_room_error(reason: String) -> void:
		room_errors.append(reason)


class RequestProbe:
	extends RefCounted

	var call_count := 0
	var request_ids: Array[String] = []


	func invoke(request_id: String) -> void:
		call_count += 1
		request_ids.append(request_id)


var _h: CheckHarness
var _states: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var saved := _save_network_state()
	_configure_ready_transport()
	AsyncActionController.reset(MainScript.CREATE_ROOM_ACTION)
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
		"debug 构建拒绝安装 Main 创建房间菜单探针")
	var request_probe := RequestProbe.new()
	var navigation_probe := RequestProbe.new()
	_h.expect(main.set_create_room_request_check_hook(request_probe.invoke),
		"debug_request_seam_rejected", "debug 构建拒绝安装创建房间请求探针")
	_h.expect(main.set_create_room_navigation_check_hook(navigation_probe.invoke),
		"debug_navigation_seam_rejected", "debug 构建拒绝安装创建房间导航探针")

	await _check_rapid_taps_and_success(main, menu, request_probe, navigation_probe)
	await _check_failure(main, menu, request_probe)
	await _check_timeout_and_late_result(main, menu, request_probe, navigation_probe)
	await _check_cancel_and_late_result(main, request_probe, navigation_probe)
	await _check_read_actions_are_superseded(main, request_probe)
	await _check_navigation_cancels_owner(main, request_probe)
	_check_source_contract()

	if AsyncActionController.action_state_changed.is_connected(_record_action_state):
		AsyncActionController.action_state_changed.disconnect(_record_action_state)
	var final_request := main.create_room_request_id_for_check()
	await get_tree().process_frame
	AsyncActionController.reset(MainScript.CREATE_ROOM_ACTION, final_request)
	main.queue_free()
	_restore_network_state(saved)
	_h.finish(get_tree())


func _check_rapid_taps_and_success(
	main: MainScript,
	menu: FakeMenu,
	request_probe: RequestProbe,
	navigation_probe: RequestProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	for _i in 100:
		main._on_team_room_create_requested()
	var request_id := main.create_room_request_id_for_check()
	_h.expect(not request_id.is_empty(), "rapid_request_id_missing",
		"100 次点击后没有创建房间 request id")
	_h.expect(request_probe.call_count - calls_before == 1,
		"rapid_tap_duplicate_request",
		"100 次快速点击发出了 %d 次创建请求，应为 1" %
			(request_probe.call_count - calls_before))
	_h.expect(menu.connecting_count == 1, "rapid_tap_duplicate_busy_ui",
		"100 次快速点击刷新 connecting UI %d 次，应为 1" % menu.connecting_count)
	var states: Array = _states.get(request_id, [])
	_h.expect(states.has(AsyncActionController.STATE_PRESSED), "pressed_state_missing",
		"创建房间动作没有经过 PRESSED")
	_h.expect(states.has(AsyncActionController.STATE_PENDING), "pending_state_missing",
		"创建房间动作没有经过 PENDING")

	NetworkService.team_local_slot = 0
	main._on_create_room_lobby_changed()
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_SUCCEEDED,
		"success_state_missing", "取得房间槽位后没有进入 SUCCEEDED")
	_h.expect(navigation_probe.call_count == 1, "success_navigation_missing",
		"成功创建房间没有恰好导航一次")
	main._on_create_room_lobby_changed()
	_h.expect(navigation_probe.call_count == 1, "late_success_navigated_again",
		"已完成动作的迟到 lobby 信号再次触发导航")
	await get_tree().process_frame


func _check_failure(
	main: MainScript,
	menu: FakeMenu,
	request_probe: RequestProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	main._on_team_room_create_requested()
	var request_id := main.create_room_request_id_for_check()
	_h.expect(request_probe.call_count - calls_before == 1,
		"failure_request_not_dispatched", "失败用例没有发出创建房间请求")
	main._on_team_room_action_failed("create_room_failed")
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_FAILED,
		"failure_state_missing", "team_room_action_failed 没有结算创建动作为 FAILED")
	_h.expect(menu.room_errors.has("create_room_failed"), "failure_ui_missing",
		"创建房间失败没有沿用房间错误 UI")
	await get_tree().process_frame


func _check_timeout_and_late_result(
	main: MainScript,
	menu: FakeMenu,
	request_probe: RequestProbe,
	navigation_probe: RequestProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	var errors_before := menu.connection_errors.size()
	var navigations_before := navigation_probe.call_count
	main._on_team_room_create_requested()
	var request_id := main.create_room_request_id_for_check()
	_h.expect(request_probe.call_count - calls_before == 1,
		"timeout_request_not_dispatched", "超时用例没有发出创建房间请求")
	AsyncActionController.poll(Time.get_ticks_msec() + MainScript.CREATE_ROOM_TIMEOUT_MSEC + 1)
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_TIMED_OUT,
		"timeout_state_missing", "超过创建房间 deadline 后没有进入 TIMED_OUT")
	_h.expect(menu.connection_errors.size() == errors_before + 1, "timeout_ui_missing",
		"创建房间超时没有显示连接错误")
	_h.expect(not NetworkService.team_active, "timeout_transport_not_closed",
		"创建请求已发出后超时仍保留网络会话，可能接收迟到槽位")
	NetworkService.team_local_slot = 0
	main._on_create_room_lobby_changed()
	_h.expect(navigation_probe.call_count == navigations_before,
		"timeout_late_result_navigated", "超时后的迟到槽位仍触发大厅导航")
	await get_tree().process_frame


func _check_cancel_and_late_result(
	main: MainScript,
	request_probe: RequestProbe,
	navigation_probe: RequestProbe
) -> void:
	_configure_ready_transport()
	var calls_before := request_probe.call_count
	var navigations_before := navigation_probe.call_count
	main._on_team_room_create_requested()
	var request_id := main.create_room_request_id_for_check()
	_h.expect(request_probe.call_count - calls_before == 1,
		"cancel_request_not_dispatched", "取消用例没有发出创建房间请求")
	_h.expect(AsyncActionController.cancel(request_id, "check_cancel"),
		"cancel_rejected", "当前创建房间 request 无法取消")
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_CANCELLED,
		"cancel_state_missing", "取消后没有进入 CANCELLED")
	_h.expect(not NetworkService.team_active, "cancel_transport_not_closed",
		"取消已发出的创建请求后仍保留网络会话")
	NetworkService.team_local_slot = 0
	main._on_create_room_lobby_changed()
	_h.expect(navigation_probe.call_count == navigations_before,
		"cancel_late_result_navigated", "取消后的迟到槽位仍触发大厅导航")
	await get_tree().process_frame


func _check_read_actions_are_superseded(
	main: MainScript,
	create_probe: RequestProbe
) -> void:
	var read_probe := RequestProbe.new()
	_h.expect(main.set_public_token_request_check_hook(read_probe.invoke),
		"token_hook_rejected", "交叉动作测试无法安装 token 请求探针")
	_h.expect(main.set_room_list_request_check_hook(read_probe.invoke),
		"room_list_hook_rejected", "交叉动作测试无法安装房间列表请求探针")

	_configure_ready_transport()
	main._on_public_token_generate_requested()
	var token_request := main.public_token_request_id_for_check()
	_h.expect(AsyncActionController.is_current(token_request), "token_setup_not_active",
		"交叉动作前置 token 没有进入 active")
	var create_calls_before := create_probe.call_count
	main._on_team_room_create_requested()
	var create_after_token := main.create_room_request_id_for_check()
	_h.expect(_state_for_action(MainScript.PUBLIC_TOKEN_ACTION) ==
		AsyncActionController.STATE_CANCELLED, "create_did_not_supersede_token",
		"后点创建房间没有取消先前 token request")
	_h.expect(create_probe.call_count - create_calls_before == 1 and
		AsyncActionController.is_current(create_after_token), "create_after_token_not_active",
		"取消 token 后，创建房间 request 没有保持 active")
	main._on_team_room_action_failed("cross_check_cleanup")
	await get_tree().process_frame

	_configure_ready_transport()
	main._on_team_room_list_requested()
	var list_request := main.room_list_request_id_for_check()
	_h.expect(AsyncActionController.is_current(list_request), "list_setup_not_active",
		"交叉动作前置房间列表没有进入 active")
	create_calls_before = create_probe.call_count
	main._on_team_room_create_requested()
	var create_after_list := main.create_room_request_id_for_check()
	_h.expect(_state_for_action(MainScript.ROOM_LIST_ACTION) ==
		AsyncActionController.STATE_CANCELLED, "create_did_not_supersede_list",
		"后点创建房间没有取消先前房间列表 request")
	_h.expect(create_probe.call_count - create_calls_before == 1 and
		AsyncActionController.is_current(create_after_list), "create_after_list_not_active",
		"取消列表后，创建房间 request 没有保持 active")
	main._on_team_room_action_failed("cross_check_cleanup")
	await get_tree().process_frame


func _check_navigation_cancels_owner(main: MainScript, probe: RequestProbe) -> void:
	_configure_ready_transport()
	var calls_before := probe.call_count
	main._on_team_room_create_requested()
	var request_id := main.create_room_request_id_for_check()
	_h.expect(probe.call_count - calls_before == 1, "owner_request_not_dispatched",
		"页面离开用例没有发出创建房间请求")
	main._clear()
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_CANCELLED,
		"menu_replace_not_cancelled", "Main._clear() 没有取消菜单 owner 的创建动作")
	_h.expect(not NetworkService.team_active, "owner_cancel_transport_not_closed",
		"菜单 owner 销毁后创建房间会话仍保持活动")
	await get_tree().process_frame


func _check_source_contract() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	_h.expect(source.contains("AsyncActionController.begin(CREATE_ROOM_ACTION"),
		"create_room_not_controller_owned", "创建房间没有接入 AsyncActionController")
	_h.expect(not source.contains("\"create\":\n\t\t\t_wait_for_room_join()"),
		"legacy_create_branch_present", "创建房间仍留在共享 string pending 分支")
	_h.expect(source.contains("AsyncActionController.succeed(request_id)"),
		"late_result_gate_missing", "创建房间成功没有通过 request id 终态门禁")
	_h.expect(source.contains("CREATE_ROOM_CONNECT_START_FAILED") and
		source.contains("CREATE_ROOM_CONNECT_FAILED") and
		source.contains("CREATE_ROOM_REQUEST_FAILED"),
		"failure_taxonomy_missing", "创建房间缺少连接启动/连接状态/RPC 失败分类")
	_h.expect(source.contains("OS.is_debug_build() and _create_room_request_check_hook.is_valid()"),
		"request_hook_not_debug_guarded", "创建房间请求故障注入没有 debug build 守卫")
	_h.expect(source.contains("OS.is_debug_build() and _create_room_navigation_check_hook.is_valid()"),
		"navigation_hook_not_debug_guarded", "创建房间导航故障注入没有 debug build 守卫")


func _record_action_state(
	action: String,
	request_id: String,
	state: String,
	_snapshot: Dictionary
) -> void:
	if action != MainScript.CREATE_ROOM_ACTION:
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
	}


func _restore_network_state(saved: Dictionary) -> void:
	NetworkService.team_active = bool(saved.get("team_active", false))
	NetworkService.state = int(saved.get("state", NetworkService.SessionState.OFFLINE)) as NetworkService.SessionState
	NetworkService.team_local_slot = int(saved.get("team_local_slot", -1))
	NetworkService.remote_port = int(saved.get("remote_port", NetworkService.DEFAULT_PORT))
	NetworkService.last_error = str(saved.get("last_error", ""))
