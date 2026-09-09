extends Node

# V3 P0-05 生产接线门禁：主菜单「游戏重连」按钮。
#
# 迁移前这是 Main 里唯一没走 AsyncActionController 的联网动作，三个后果：
#   1. 按下到 NetworkService 报 RECONNECTING 之间没有任何反馈
#   2. 连点会重复调 begin_resume_from_disk()，而它每次都 reset() 传输
#   3. 凭证不全时直接 return —— 按钮的显隐判据却是 `load_reconnect().is_empty()`，
#      一条只剩 port 字段的记录会让按钮可见、点了没反应
#
# 这条门禁走**生产 Main.gd**，不是 Controller 夹具：请求派发与最终导航被探针
# 替掉，生命周期、去重、迟到结果、取消结算全部跑真实代码路径。
#
# ⚠️ 这条门禁会写真实的重连凭证文件。开头把主文件与 .bak/.tmp 三个变体整份
# 快照成字节，结尾逐字还原，并在最后断言字节一致 —— 不是「内容看起来一样」。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "main_team_manual_reconnect_action"
const TOKEN := "RECONNECT-TOKEN"
const ADDRESS := "127.0.0.1"
const PORT := 8910


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


	func invoke(request_id: String) -> void:
		call_count += 1
		request_ids.append(request_id)


var _h: CheckHarness
var _states: Dictionary = {}
var _saved_files: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_snapshot_reconnect_files()
	var saved_net := _save_network_state()
	AsyncActionController.reset(MainScript.MANUAL_RECONNECT_ACTION)
	AsyncActionController.reset(MainScript.SHORT_CODE_RESUME_ACTION)
	if not AsyncActionController.action_state_changed.is_connected(_record_action_state):
		AsyncActionController.action_state_changed.connect(_record_action_state)

	var main: MainScript = MainScript.new()
	add_child(main)
	await get_tree().process_frame
	var menu := FakeMenu.new()
	main.add_child(menu)
	_h.expect(main.set_team_menu_for_check(menu), "debug_menu_seam_rejected",
		"debug 构建拒绝安装 Main 菜单探针")
	var probe := RequestProbe.new()
	_h.expect(main.set_manual_reconnect_request_check_hook(probe.invoke),
		"debug_request_seam_rejected", "debug 构建拒绝安装手动重连请求探针")

	await _check_rapid_taps_dedupe(main, menu, probe)
	await _check_success(main)
	await _check_failure(main, probe)
	await _check_incomplete_credential_is_rejected_visibly(main, menu, probe)
	await _check_pending_leave_cannot_resume(main, menu, probe)
	await _check_superseded_by_other_action(main, probe)
	_check_source_contract()

	if AsyncActionController.action_state_changed.is_connected(_record_action_state):
		AsyncActionController.action_state_changed.disconnect(_record_action_state)
	AsyncActionController.reset(MainScript.MANUAL_RECONNECT_ACTION,
		main.manual_reconnect_request_id_for_check())
	ModalStack.close_all()
	main.queue_free()
	await get_tree().process_frame
	_restore_network_state(saved_net)
	_restore_reconnect_files()
	_h.expect(_reconnect_files_match_snapshot(), "reconnect_files_not_restored",
		"测试结束后重连凭证文件没有按字节还原")
	_h.finish(get_tree())


# --- 连点去重 ----------------------------------------------------------------

func _check_rapid_taps_dedupe(main: MainScript, menu: FakeMenu, probe: RequestProbe) -> void:
	_configure_offline_transport()
	SaveManager.save_reconnect(TOKEN, ADDRESS, PORT)
	var calls_before := probe.call_count
	var connecting_before := menu.connecting_count
	# 100 次是照着其余五个动作门禁的口径来的：真机上玩家等不到反馈就会连点。
	for _i in 100:
		main._on_team_reconnect_requested()
	var request_id := main.manual_reconnect_request_id_for_check()
	_h.expect(not request_id.is_empty(), "rapid_request_id_missing",
		"100 次点击之后没有手动重连的 request id")
	_h.expect(probe.call_count - calls_before == 1, "rapid_tap_duplicate_request",
		"100 次快速点击派发了 %d 次重连，应为 1" % (probe.call_count - calls_before))
	_h.expect(menu.connecting_count - connecting_before == 1, "rapid_tap_duplicate_busy_ui",
		"100 次快速点击刷新 connecting UI %d 次，应为 1"
			% (menu.connecting_count - connecting_before))

	var states: Array = _states.get(request_id, [])
	_h.expect(states.has(AsyncActionController.STATE_PRESSED), "pressed_state_missing",
		"手动重连没有经过 PRESSED —— 按下瞬间没有可见状态")
	_h.expect(states.has(AsyncActionController.STATE_PENDING), "pending_state_missing",
		"手动重连没有经过 PENDING —— 联网期间没有 busy 态")

	# 连点必须留下 rejected 面包屑，否则「没执行」和「执行了没反应」在诊断里没法区分。
	var crumbs := JSON.stringify(AsyncActionController.recent_breadcrumbs(20))
	_h.expect(crumbs.contains("duplicate_pending"), "duplicate_tap_left_no_breadcrumb",
		"重复点击没有留下 duplicate_pending 面包屑")
	# 凭证是玩家的会话身份，不该出现在公开快照或诊断里。
	_h.expect(not JSON.stringify(
			AsyncActionController.snapshot_for(MainScript.MANUAL_RECONNECT_ACTION)).contains(TOKEN),
		"token_leaked_to_snapshot", "重连 token 泄漏进 AsyncAction 公开快照")
	_h.expect(not crumbs.contains(TOKEN), "token_leaked_to_breadcrumb",
		"重连 token 泄漏进诊断 breadcrumb")
	await get_tree().process_frame


# --- 成功结算 ----------------------------------------------------------------

func _check_success(main: MainScript) -> void:
	var request_id := main.manual_reconnect_request_id_for_check()
	if not _h.expect(not request_id.is_empty(), "success_setup_missing",
			"进入成功用例时没有在途的重连请求"):
		return
	# RECONNECTING 不是终态：会话还在退避重试，动作必须继续挂在 PENDING。
	NetworkService.state = NetworkService.SessionState.RECONNECTING
	NetworkService.session_changed.emit()
	await get_tree().process_frame
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_PENDING,
		"reconnecting_resolved_too_early",
		"RECONNECTING 就把动作结算了 —— 那是重试中，不是结果")

	NetworkService.state = NetworkService.SessionState.READY
	NetworkService.session_changed.emit()
	await get_tree().process_frame
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_SUCCEEDED,
		"success_state_missing", "会话 READY 之后动作没有进入 SUCCEEDED")
	_h.expect(main.manual_reconnect_request_id_for_check().is_empty(),
		"success_left_request_id", "成功之后没有清掉 request id —— 下一次点击会被当成连点")
	# 结算后必须摘掉监听，否则后续任何会话变化都会再进一次结算分支。
	_h.expect(not NetworkService.session_changed.is_connected(
			main._on_manual_reconnect_session_changed),
		"success_left_listener", "成功之后还挂着 session_changed 监听")
	await get_tree().process_frame


# --- 失败结算与可重试 --------------------------------------------------------

func _check_failure(main: MainScript, probe: RequestProbe) -> void:
	_configure_offline_transport()
	SaveManager.save_reconnect(TOKEN, ADDRESS, PORT)
	var calls_before := probe.call_count
	main._on_team_reconnect_requested()
	var request_id := main.manual_reconnect_request_id_for_check()
	_h.expect(probe.call_count - calls_before == 1, "failure_request_not_dispatched",
		"失败用例没有派发重连请求")
	NetworkService.state = NetworkService.SessionState.FAILED
	NetworkService.session_changed.emit()
	await get_tree().process_frame
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_FAILED,
		"failure_state_missing", "会话 FAILED 之后动作没有进入 FAILED")
	_h.expect(main.manual_reconnect_request_id_for_check().is_empty(),
		"failure_left_request_id", "失败之后没有清掉 request id")

	# 失败必须可重试：连接失败是暂时的，不能让按钮从此按不动。
	_configure_offline_transport()
	var calls_before_retry := probe.call_count
	main._on_team_reconnect_requested()
	_h.expect(probe.call_count - calls_before_retry == 1, "retry_after_failure_blocked",
		"失败之后再点一次没有重新派发 —— 按钮变成了死的")
	var retry_id := main.manual_reconnect_request_id_for_check()
	AsyncActionController.cancel(retry_id, "check_cleanup", true)
	main._disconnect_manual_reconnect_session_handler()
	await get_tree().process_frame


# --- 凭证残缺：必须可见地拒绝，而不是静默 return ------------------------------

func _check_incomplete_credential_is_rejected_visibly(
	main: MainScript, menu: FakeMenu, probe: RequestProbe
) -> void:
	AsyncActionController.reset(MainScript.MANUAL_RECONNECT_ACTION,
		main.manual_reconnect_request_id_for_check())
	_configure_offline_transport()
	# 走生产 API 写一条 token/address 为空的凭证 —— 这是真能落到盘上的形状，
	# 不是手搓的假数据。`load_reconnect().is_empty()` 为假（还有 port 字段），
	# 所以主菜单那个按钮**是可见的**；而 token/address 都取不到。
	# 迁移前这一路直接 return，玩家点了什么都不发生。
	SaveManager.save_reconnect("", "", PORT)
	var calls_before := probe.call_count
	var errors_before := menu.connection_errors.size()
	main._on_team_reconnect_requested()
	await get_tree().process_frame
	_h.expect(probe.call_count == calls_before, "incomplete_credential_dispatched",
		"凭证残缺时仍然派发了重连")
	_h.expect(menu.connection_errors.size() - errors_before == 1,
		"incomplete_credential_is_silent",
		"凭证残缺时没有给玩家任何反馈 —— 按钮可见但点了没反应")
	var last_error := str(menu.connection_errors.back()) if not menu.connection_errors.is_empty() else ""
	_h.expect(not last_error.strip_edges().is_empty(), "rejection_reason_is_blank",
		"拒绝反馈是空串，等于没提示")
	var crumbs := JSON.stringify(AsyncActionController.recent_breadcrumbs(10))
	_h.expect(crumbs.contains("RECONNECT_NO_CREDENTIAL"),
		"rejection_left_no_breadcrumb",
		"凭证残缺的拒绝没有留下 breadcrumb —— 诊断上和「根本没点」无法区分")
	_h.expect(main.manual_reconnect_request_id_for_check().is_empty(),
		"rejection_left_request_id", "拒绝之后没有清掉 request id")
	_h.expect(not NetworkService.session_changed.is_connected(
			main._on_manual_reconnect_session_changed),
		"rejection_left_listener", "拒绝之后挂上了 session_changed 监听")
	await get_tree().process_frame


# --- 被其它组队动作顶掉 ------------------------------------------------------

func _check_superseded_by_other_action(main: MainScript, probe: RequestProbe) -> void:
	AsyncActionController.reset(MainScript.MANUAL_RECONNECT_ACTION,
		main.manual_reconnect_request_id_for_check())
	_configure_offline_transport()
	SaveManager.save_reconnect(TOKEN, ADDRESS, PORT)
	var calls_before := probe.call_count
	main._on_team_reconnect_requested()
	var request_id := main.manual_reconnect_request_id_for_check()
	if not _h.expect(probe.call_count - calls_before == 1, "supersede_setup_failed",
			"顶替用例没有派发出重连请求"):
		return
	main._supersede_other_team_action(MainScript.ROOM_LIST_ACTION)
	await get_tree().process_frame
	_h.expect(_state_of(request_id) == AsyncActionController.STATE_CANCELLED,
		"not_superseded_by_other_action",
		"别的组队动作开始时没有把在途的手动重连顶掉")
	_h.expect(main.manual_reconnect_request_id_for_check().is_empty(),
		"supersede_left_request_id", "被顶掉之后没有清掉 request id")
	_h.expect(not NetworkService.session_changed.is_connected(
			main._on_manual_reconnect_session_changed),
		"supersede_left_listener", "被顶掉之后还挂着 session_changed 监听")
	await get_tree().process_frame


# --- 源码合同 ----------------------------------------------------------------

func _check_pending_leave_cannot_resume(main: MainScript, menu: FakeMenu, probe: RequestProbe) -> void:
	_configure_offline_transport()
	SaveManager.clear_reconnect()
	SaveManager.save_reconnect(TOKEN, ADDRESS, PORT)
	_h.expect(not SaveManager.load_resumable_reconnect().is_empty(),
		"normal_resume", "A disconnected session must remain resumable")
	SaveManager.mark_pending_leave("leave-regression")
	_h.expect(SaveManager.load_resumable_reconnect().is_empty(),
		"pending_leave_visible", "An explicitly left room is still resumable")
	_h.expect(str(SaveManager.load_reconnect().get("pending_leave", "")) == "leave-regression",
		"leave_receipt_lost", "Filtering deleted credentials needed by the leave receipt")
	var menu_script := load("res://scenes/menu/MainMenu.gd") as Script
	var actual_menu: Control = menu_script.new()
	actual_menu._build()
	var found := false
	for child in actual_menu.get_children():
		if child is Button and child.pressed.is_connected(actual_menu._emit_reconnect):
			found = true
			_h.expect(not child.visible, "leave_button_visible", "Real menu shows Reconnect after leaving")
	_h.expect(found, "reconnect_button_missing", "Test did not find the real reconnect button")
	actual_menu.free()
	var before := probe.call_count
	var errors_before := menu.connection_errors.size()
	main._on_team_reconnect_requested()
	_h.expect(probe.call_count == before, "leave_resume_dispatched", "Stale button dispatched a resume after leave")
	_h.expect(menu.connection_errors.size() == errors_before + 1,
		"leave_resume_unsettled", "Rejected resume did not settle visibly")
	SaveManager.save_reconnect(TOKEN, ADDRESS, PORT)
	_h.expect(SaveManager.load_resumable_reconnect().is_empty(),
		"late_refresh_revived_leave", "Same-session refresh erased the leave marker")
	SaveManager.save_reconnect("NEW-SESSION", ADDRESS, PORT)
	_h.expect(not SaveManager.load_resumable_reconnect().is_empty(),
		"new_session_blocked", "Old leave marker blocked a new session")
	SaveManager.clear_reconnect()
	_h.expect(SaveManager.load_resumable_reconnect().is_empty(),
		"receipt_resurrected_backup", "Cleared credentials reappeared through fallback")
	await get_tree().process_frame


func _check_source_contract() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	var at := src.find("func _on_team_reconnect_requested() -> void:")
	if not _h.expect(at >= 0, "handler_missing", "Main 没有 _on_team_reconnect_requested"):
		return
	var end := src.find("\nfunc ", at + 1)
	if end < 0:
		end = src.length()
	var body := src.substr(at, end - at)
	# 断言限定在函数体里。整文件 contains 会被自己写的注释满足 —— 本轮栽过三次。
	_h.expect(body.contains("AsyncActionController.begin(MANUAL_RECONNECT_ACTION"),
		"handler_not_controlled",
		"手动重连没有走 AsyncActionController.begin() —— 又回到没有 busy 态的老样子")
	_h.expect(body.contains("AsyncActionController.record_input_received("),
		"handler_no_input_breadcrumb",
		"手动重连没有记 input_received —— 按下瞬间在诊断里不可见")
	# 「静默 return」正是这条缺陷本身。派发之前的每一处 return 都必须先结算动作。
	_h.expect(body.contains("\t\tAsyncActionController.fail(request_id, \"RECONNECT_NO_CREDENTIAL\""),
		"missing_credential_returns_silently",
		"凭证残缺时没有结算成 FAILED —— 玩家点了没反应，诊断里也查不到")
	_h.expect(body.contains("_supersede_other_team_action(MANUAL_RECONNECT_ACTION)"),
		"handler_does_not_supersede",
		"手动重连没有顶掉其它在途组队动作")


# --- 夹具 --------------------------------------------------------------------

func _record_action_state(
	_action: String, request_id: String, state: String, _snapshot: Dictionary
) -> void:
	if not _states.has(request_id):
		_states[request_id] = []
	(_states[request_id] as Array).append(state)


# 取最后一个**非 idle** 的状态。结算之后 AsyncActionController 会把动作放回
# idle，所以直接取 back() 会把「已成功」读成「idle」—— 取决于断言前隔了几帧，
# 那种写法时红时绿。
func _state_of(request_id: String) -> String:
	var states: Array = _states.get(request_id, [])
	for i in range(states.size() - 1, -1, -1):
		var st := str(states[i])
		if st != AsyncActionController.STATE_IDLE:
			return st
	return ""


# 主文件 + .bak + .tmp 一起快照。只存主文件的话，还原之后 _read_with_fallback()
# 会从残留的兜底文件里把测试用的 token 读回来。
func _reconnect_variants() -> Array[String]:
	return [
		SaveManager.RECONNECT_PATH,
		SaveManager.RECONNECT_PATH + ".bak",
		SaveManager.RECONNECT_PATH + ".tmp",
	]


func _snapshot_reconnect_files() -> void:
	_saved_files = {}
	for path in _reconnect_variants():
		if FileAccess.file_exists(path):
			_saved_files[path] = FileAccess.get_file_as_bytes(path)


func _restore_reconnect_files() -> void:
	for path in _reconnect_variants():
		if _saved_files.has(path):
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_buffer(_saved_files[path])
				f.close()
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _reconnect_files_match_snapshot() -> bool:
	for path in _reconnect_variants():
		var existed: bool = _saved_files.has(path)
		if existed != FileAccess.file_exists(path):
			return false
		if existed and FileAccess.get_file_as_bytes(path) != _saved_files[path]:
			return false
	return true


func _configure_offline_transport() -> void:
	NetworkService.team_active = false
	NetworkService.state = NetworkService.SessionState.OFFLINE
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
