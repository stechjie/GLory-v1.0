extends Node

# C-10 production-wiring gate for the first migrated Main team-menu action.
# It runs against Main.gd, but replaces only the outbound token request so no
# socket or dedicated server is needed.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "main_team_token_action"


class FakeMenu:
	extends Control

	var connecting_count := 0
	var connection_errors: Array[String] = []
	var room_errors: Array[String] = []
	var shown_tokens: Array[String] = []


	func show_connecting() -> void:
		connecting_count += 1


	func show_connection_error(message: String) -> void:
		connection_errors.append(message)


	func show_room_error(reason: String) -> void:
		room_errors.append(reason)


	func show_public_token(token_id: String) -> void:
		shown_tokens.append(token_id)


class TokenRequestProbe:
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
	AsyncActionController.reset(MainScript.PUBLIC_TOKEN_ACTION)
	if not AsyncActionController.action_state_changed.is_connected(_record_action_state):
		AsyncActionController.action_state_changed.connect(_record_action_state)

	var main: MainScript = MainScript.new()
	add_child(main)
	await get_tree().process_frame
	var menu := FakeMenu.new()
	main.add_child(menu)
	_h.expect(main.set_public_token_menu_for_check(menu), "debug_menu_seam_rejected",
		"debug 构建拒绝安装 Main token 菜单探针")
	var request_probe := TokenRequestProbe.new()
	_h.expect(main.set_public_token_request_check_hook(request_probe.invoke),
		"debug_request_seam_rejected", "debug 构建拒绝安装 token 请求探针")

	await _check_rapid_taps_and_success(main, menu, request_probe)
	await _check_failure(main, menu, request_probe)
	await _check_timeout_and_late_result(main, menu, request_probe)
	await _check_cancel_and_late_result(main, menu, request_probe)
	await _check_navigation_cancels_owner(main, menu, request_probe)
	_check_source_contract()

	if AsyncActionController.action_state_changed.is_connected(_record_action_state):
		AsyncActionController.action_state_changed.disconnect(_record_action_state)
	var final_request := main.public_token_request_id_for_check()
	await get_tree().process_frame
	AsyncActionController.reset(MainScript.PUBLIC_TOKEN_ACTION, final_request)
	main.queue_free()
	_restore_network_state(saved)
	_h.finish(get_tree())


func _check_rapid_taps_and_success(
	main: MainScript,
	menu: FakeMenu,
	probe: TokenRequestProbe
) -> void:
	var calls_before := probe.call_count
	for _i in 100:
		main._on_public_token_generate_requested()
	var request_id := main.public_token_request_id_for_check()
	_h.expect(not request_id.is_empty(), "rapid_request_id_missing",
		"100 次点击后没有 token request id")
	_h.expect(probe.call_count - calls_before == 1, "rapid_tap_duplicate_request",
		"100 次快速点击发出了 %d 次 token 请求，应为 1" % (probe.call_count - calls_before))
	_h.expect(menu.connecting_count == 1, "rapid_tap_duplicate_busy_ui",
		"100 次快速点击刷新 connecting UI %d 次，应为 1" % menu.connecting_count)
	var states: Array = _states.get(request_id, [])
	_h.expect(states.has(AsyncActionController.STATE_PRESSED), "pressed_state_missing",
		"token 动作没有经过 PRESSED")
	_h.expect(states.has(AsyncActionController.STATE_PENDING), "pending_state_missing",
		"token 动作没有经过 PENDING")

	main._on_public_token_changed("token_success")
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_SUCCEEDED,
		"success_state_missing", "token 回包后没有进入 SUCCEEDED")
	_h.expect(menu.shown_tokens == ["token_success"], "success_ui_missing",
		"成功 token 没有恰好显示一次：%s" % str(menu.shown_tokens))
	main._on_public_token_changed("token_late_success")
	_h.expect(menu.shown_tokens == ["token_success"], "late_success_updated_ui",
		"已完成动作的迟到 token 仍更新了 UI")
	await get_tree().process_frame


func _check_failure(main: MainScript, menu: FakeMenu, probe: TokenRequestProbe) -> void:
	var calls_before := probe.call_count
	main._on_public_token_generate_requested()
	var request_id := main.public_token_request_id_for_check()
	_h.expect(probe.call_count - calls_before == 1, "failure_request_not_dispatched",
		"失败用例没有发出 token 请求")
	main._on_team_room_action_failed("token_id_failed")
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_FAILED,
		"failure_state_missing", "team_room_action_failed 没有结算 token 动作为 FAILED")
	_h.expect(menu.room_errors.has("token_id_failed"), "failure_ui_missing",
		"token 请求失败没有沿用房间错误 UI")
	await get_tree().process_frame


func _check_timeout_and_late_result(
	main: MainScript,
	menu: FakeMenu,
	probe: TokenRequestProbe
) -> void:
	var calls_before := probe.call_count
	var errors_before := menu.connection_errors.size()
	var tokens_before := menu.shown_tokens.size()
	main._on_public_token_generate_requested()
	var request_id := main.public_token_request_id_for_check()
	_h.expect(probe.call_count - calls_before == 1, "timeout_request_not_dispatched",
		"超时用例没有发出 token 请求")
	AsyncActionController.poll(Time.get_ticks_msec() + MainScript.PUBLIC_TOKEN_TIMEOUT_MSEC + 1)
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_TIMED_OUT,
		"timeout_state_missing", "超过 token deadline 后没有进入 TIMED_OUT")
	_h.expect(menu.connection_errors.size() == errors_before + 1, "timeout_ui_missing",
		"token 超时没有显示连接错误")
	main._on_public_token_changed("token_after_timeout")
	_h.expect(menu.shown_tokens.size() == tokens_before, "timeout_late_result_updated_ui",
		"超时后的迟到 token 仍更新了 UI")
	await get_tree().process_frame


func _check_cancel_and_late_result(
	main: MainScript,
	menu: FakeMenu,
	probe: TokenRequestProbe
) -> void:
	var calls_before := probe.call_count
	var tokens_before := menu.shown_tokens.size()
	main._on_public_token_generate_requested()
	var request_id := main.public_token_request_id_for_check()
	_h.expect(probe.call_count - calls_before == 1, "cancel_request_not_dispatched",
		"取消用例没有发出 token 请求")
	_h.expect(AsyncActionController.cancel(request_id, "check_cancel"),
		"cancel_rejected", "当前 token request 无法取消")
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_CANCELLED,
		"cancel_state_missing", "取消后没有进入 CANCELLED")
	main._on_public_token_changed("token_after_cancel")
	_h.expect(menu.shown_tokens.size() == tokens_before, "cancel_late_result_updated_ui",
		"取消后的迟到 token 仍更新了 UI")
	await get_tree().process_frame


func _check_navigation_cancels_owner(
	main: MainScript,
	_menu: FakeMenu,
	probe: TokenRequestProbe
) -> void:
	var calls_before := probe.call_count
	main._on_public_token_generate_requested()
	var request_id := main.public_token_request_id_for_check()
	_h.expect(probe.call_count - calls_before == 1, "owner_request_not_dispatched",
		"页面离开用例没有发出 token 请求")
	main._clear()
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_CANCELLED,
		"menu_replace_not_cancelled", "Main._clear() 没有取消菜单 owner 的 token 动作")
	await get_tree().process_frame


func _check_source_contract() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	_h.expect(source.contains("AsyncActionController.begin(PUBLIC_TOKEN_ACTION"),
		"token_not_controller_owned", "公开 token 没有接入 AsyncActionController")
	_h.expect(source.contains("clear_for_owner(_menu, \"menu_replaced\")"),
		"menu_owner_cancel_missing", "菜单切换没有主动取消 owner 动作")
	_h.expect(not source.contains("\"token\":\n\t\t\tNetworkService.team_request_public_token()"),
		"legacy_token_branch_present", "token 仍留在共享 string pending 分支")
	_h.expect(source.contains("if AsyncActionController.succeed(_public_token_request_id)"),
		"late_result_gate_missing", "token 回包没有通过 request id 终态门禁")
	_h.expect(source.contains("OS.is_debug_build() and _public_token_request_check_hook.is_valid()"),
		"request_hook_not_debug_guarded", "token 请求故障注入没有 debug build 守卫")


func _record_action_state(
	action: String,
	request_id: String,
	state: String,
	_snapshot: Dictionary
) -> void:
	if action != MainScript.PUBLIC_TOKEN_ACTION:
		return
	if not _states.has(request_id):
		_states[request_id] = []
	(_states[request_id] as Array).append(state)


func _state_of(request_id: String) -> String:
	var states: Array = _states.get(request_id, [])
	return str(states.back()) if not states.is_empty() else ""


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
