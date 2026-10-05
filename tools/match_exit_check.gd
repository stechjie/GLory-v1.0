extends Node

# 门禁：退出对局（2026-10-06 用户要求）。
#   · 断线了除了重连可以直接退出，退出要显示惩罚、让玩家确认（只说会不会扣，不写扣多少）
#   · 对局要退出了才能开新局
#   · 摆放界面的静音键改成「设定」（同主界面那一页），对局里「重新体验教学」换成「退出对局」
#
# 扣不扣、判不判负的规则在账号服务器，backend/tests/test_ranked.py 钉着（自定房间不碰信誉分、跑路判负）。
# 这里钉客户端这一半：
#   1. 确认框文字：四种模式各说各的，不出现数字
#   2. 重连凭证记下模式，同一个座位再存一次不丢、换座位不串
#   3. 退出 = 删凭证、不发任何 RPC（发 abandon 会让跑路的人一分不扣）；删完能开新局
#   4. 开新局被上一局拦住：弹的是「退出对局」，确认了这次照常开；取消不动凭证
#   5. 断线遮罩：开打了的局按钮是「退出对局」，点了先弹确认框、后台照样重连；连回去了确认框自动收掉；
#      确认了才退、才回主菜单。没开打的局照旧「取消并返回主菜单」
#   6. 摆放界面右上角是「设定」：弹层打开设定页，联网对局里有「退出对局」、没有「重新体验教学」
#   7. 对局历史：对局结束时我不在线 = 负，队伍赢了也一样
#
# 动到 user://glory_reconnect.json：三个变体先逐字快照、跑完还原。另外请用隔离的 APPDATA 跑。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MatchExitPenalty := preload("res://scripts/multiplayer/MatchExitPenalty.gd")
const MainScript := preload("res://scenes/main/Main.gd")
const PrepScreenScript := preload("res://scenes/prep/PrepScreen.gd")
const SettingsScreenScript := preload("res://scenes/menu/SettingsScreen.gd")
const MatchHistoryPanelScript := preload("res://scenes/menu/MatchHistoryPanel.gd")
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")

const DUMMY_TOKEN := "gate_exit_token"
const DUMMY_ADDRESS := "127.0.0.1"
const DUMMY_PORT := 7777
const USER_FILES: PackedStringArray = [
	"user://glory_reconnect.json",
	"user://glory_reconnect.json.bak",
	"user://glory_reconnect.json.tmp",
]


# 只数「回主菜单」发生了几次（Main 的 debug 导航探针）。
class NavProbe:
	extends RefCounted

	var count := 0

	func invoke() -> void:
		count += 1


var _h: CheckHarness


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new("match_exit")
	var files_before := _snapshot_files()
	var net_before := _save_network_state()
	var team_mode_before: bool = GameState.team_mode
	var locale_before := LocaleManager.get_locale()
	LocaleManager.set_locale("zh")
	ModalStack.close_all()
	await _settle(2)

	_case_penalty_text()
	_case_saved_mode()
	await _case_abandon_clears_and_unlocks()
	await _case_new_match_guard()
	await _case_reconnect_overlay()
	await _case_prep_settings()
	_case_history_judged_loss()

	ModalStack.close_all()
	await _settle(2)
	_restore_files(files_before)
	_restore_network_state(net_before)
	GameState.team_mode = team_mode_before
	LocaleManager.set_locale(locale_before)
	_h.finish(get_tree())


# --- 1. 确认框文字 -----------------------------------------------------------------

func _case_penalty_text() -> void:
	var custom := MatchExitPenalty.body("custom", false)
	var casual := MatchExitPenalty.body("casual", false)
	var ranked := MatchExitPenalty.body("ranked", false)
	var unknown := MatchExitPenalty.body("", false)
	for text in [custom, casual, ranked, unknown]:
		_h.expect(str(text).contains("判负") and str(text).contains("不能再回来"), "text_missing_forfeit",
			"确认框要说清判负、退了回不来：%s" % text)
		_h.expect(not _has_digit(str(text)), "text_has_number", "确认框不写扣多少（用户定）：%s" % text)
	_h.expect(custom.contains("不扣") and not custom.contains("会扣"), "custom_text", "自定房间要说不扣分：%s" % custom)
	_h.expect(casual.contains("会扣信誉分") and not casual.contains("排位分"), "casual_text", "休闲只扣信誉分：%s" % casual)
	_h.expect(ranked.contains("信誉分") and ranked.contains("排位分"), "ranked_text", "排位扣信誉分和排位分：%s" % ranked)
	_h.expect(unknown.contains("匹配和排位局会扣分"), "unknown_text", "不知道模式时说通用的那句：%s" % unknown)
	for mode in ["custom", "casual", "ranked", ""]:
		var en := MatchExitPenalty.body(str(mode), true)
		_h.expect(not en.is_empty() and not _has_cjk(en) and not _has_digit(en), "en_text",
			"英文版不能空、不能混中文、不写数字：%s" % en)


# --- 2. 重连凭证记下模式 --------------------------------------------------------------

func _case_saved_mode() -> void:
	SaveManager.clear_reconnect()
	SaveManager.save_reconnect(DUMMY_TOKEN, DUMMY_ADDRESS, DUMMY_PORT, "ranked")
	_h.expect(str(SaveManager.load_reconnect().get("mode", "")) == "ranked", "mode_not_saved", "重连凭证没记下模式")
	SaveManager.mark_match_started()
	SaveManager.save_reconnect(DUMMY_TOKEN, DUMMY_ADDRESS, DUMMY_PORT)
	var rc := SaveManager.load_reconnect()
	_h.expect(str(rc.get("mode", "")) == "ranked" and bool(rc.get("match_started", false)), "mode_lost_on_refresh",
		"同一个座位再存一次，把模式或开局标记丢了")
	SaveManager.save_reconnect("gate_other_token", DUMMY_ADDRESS, DUMMY_PORT)
	_h.expect(str(SaveManager.load_reconnect().get("mode", "")).is_empty(), "mode_leaked_to_new_seat",
		"换了座位还带着上一个座位的模式")
	SaveManager.clear_reconnect()


# --- 3. 退出 = 删凭证、不发 RPC，删完能开新局 ---------------------------------------------

func _case_abandon_clears_and_unlocks() -> void:
	_started_record("casual")
	NetworkService.cancel_reconnect()
	_h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "cancel_now_abandons",
		"「取消并返回主菜单」不该删开打了的局的凭证（那是「退出对局」的事，要先确认）")
	_started_record("casual")
	NetworkService.pending_abandon_token = "gate_should_be_cleared"
	NetworkService.abandon_started_match()
	_h.expect(SaveManager.load_reconnect().is_empty(), "abandon_kept_credentials", "退出对局之后重连凭证还在 —— 开不了新局")
	_h.expect(NetworkService.pending_abandon_token.is_empty(), "abandon_kept_pending_token", "退出对局之后还挂着待发的 abandon")
	var ok: bool = await NetworkService.allow_new_match()
	_h.expect(ok and not DialogService.is_open("active_match_guard"), "abandon_did_not_unlock", "退出对局之后开新局还被拦")
	var body := _function_body("res://scripts/autoload/NetworkService.gd", "func abandon_started_match")
	if _h.expect(not body.is_empty(), "abandon_func_missing", "找不到 NetworkService.abandon_started_match"):
		_h.expect(not body.contains(".rpc") and not body.contains("_rpc_"), "abandon_sends_rpc",
			"退出对局发了 RPC —— _rpc_abandon_seat 会清掉座位上的账号，结算时当成 AI，跑路的人反而不扣分")


# --- 4. 开新局被上一局拦住 --------------------------------------------------------------

func _case_new_match_guard() -> void:
	for answer in ["cancel", "confirm"]:
		_started_record("ranked")
		# 坐在座位上 + 凭证标了开局 → check_saved_match 直接判 active，不连服务器。
		NetworkService.team_local_slot = 2
		var box := {}
		var runner := func() -> void:
			box["ok"] = await NetworkService.allow_new_match()
		runner.call()
		await _settle(2)
		var dialog := _top_dialog()
		if not _h.expect(dialog != null and DialogService.is_open("active_match_guard"), "guard_no_dialog",
				"上一局没打完时开新局没弹框"):
			ModalStack.close_all()
			break
		_h.expect(dialog._confirm_btn.text == "退出对局", "guard_confirm_text",
			"被拦时的确认键应是「退出对局」，实际「%s」" % dialog._confirm_btn.text)
		_h.expect(dialog._body_label.text.contains("会扣信誉分和排位分") and dialog._body_label.text.contains("游戏重连"),
			"guard_body", "被拦时要说清会扣分、也能回去重连：%s" % dialog._body_label.text)
		if answer == "confirm":
			dialog._confirm_btn.pressed.emit()
		else:
			dialog._cancel_btn.pressed.emit()
		await _settle(3)
		if answer == "confirm":
			_h.expect(bool(box.get("ok", false)), "guard_confirm_blocked", "确认退出之后这次开新局还是被拦")
			_h.expect(SaveManager.load_reconnect().is_empty(), "guard_confirm_kept_credentials", "确认退出之后凭证还在")
		else:
			_h.expect(box.has("ok") and not bool(box["ok"]), "guard_cancel_allowed", "取消之后不该放行开新局")
			_h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "guard_cancel_cleared", "取消也把上一局的凭证删了")
	NetworkService.team_local_slot = -1
	SaveManager.clear_reconnect()


# --- 5. 断线遮罩 --------------------------------------------------------------------

func _case_reconnect_overlay() -> void:
	# 同 main_reconnect_modal_check：置 READY 让 Main._ready() 跳过 VFX 预热。
	NetworkService.state = NetworkService.SessionState.READY
	NetworkService.team_active = true
	NetworkService.session_token = DUMMY_TOKEN
	NetworkService.reconnect_address = DUMMY_ADDRESS
	GameState.team_mode = true
	var main: MainScript = MainScript.new()
	add_child(main)
	await _settle(3)
	var nav := NavProbe.new()
	_h.expect(main.set_reconnect_cancel_navigation_check_hook(nav.invoke), "nav_seam_rejected", "debug 构建拒绝安装导航探针")

	# 没开打（还在房间里）：照旧「取消并返回主菜单」。
	SaveManager.clear_reconnect()
	SaveManager.save_reconnect(DUMMY_TOKEN, DUMMY_ADDRESS, DUMMY_PORT, "custom")
	_set_state(NetworkService.SessionState.RECONNECTING)
	await _settle(3)
	_h.expect(main._reconnect_cancel_button != null and main._reconnect_cancel_button.text == "取消并返回主菜单",
		"lobby_button_changed", "没开打的局，断线遮罩上的键应照旧是「取消并返回主菜单」")
	_set_state(NetworkService.SessionState.READY)
	await _settle(2)

	# 开打了：键是「退出对局」，点了先弹确认框 —— 会话、凭证、导航一样都不动。
	_started_record("ranked")
	_set_state(NetworkService.SessionState.RECONNECTING)
	await _settle(3)
	var button: Button = main._reconnect_cancel_button
	if not _h.expect(button != null and button.text == "退出对局", "started_button_text",
			"开打了的局，断线遮罩上的键应是「退出对局」"):
		await _drop_main(main)
		return
	button.pressed.emit()
	await _settle(2)
	var dialog := _top_dialog()
	_h.expect(dialog != null and DialogService.is_open(MainScript.EXIT_MATCH_DIALOG_ID), "overlay_no_dialog",
		"点「退出对局」没弹确认框")
	if dialog != null:
		_h.expect(dialog._body_label.text.contains("会扣信誉分和排位分"), "overlay_body",
			"排位局的确认框要说会扣信誉分和排位分：%s" % dialog._body_label.text)
		_h.expect(dialog._cancel_btn.text == "继续重连", "overlay_cancel_text",
			"断线时确认框的取消键应是「继续重连」，实际「%s」" % dialog._cancel_btn.text)
	_h.expect(NetworkService.state == NetworkService.SessionState.RECONNECTING
			and not SaveManager.load_resumable_reconnect().is_empty() and nav.count == 0,
		"overlay_press_acted", "确认之前就动了会话 / 凭证 / 导航")

	# 连回去了：确认框自动收掉，什么都不退。
	_set_state(NetworkService.SessionState.READY)
	await _settle(3)
	_h.expect(not DialogService.is_open(MainScript.EXIT_MATCH_DIALOG_ID), "dialog_survived_reconnect",
		"已经连回对局了，退出确认框还开着 —— 手一滑就退了")
	_h.expect(not SaveManager.load_resumable_reconnect().is_empty() and nav.count == 0, "reconnect_close_acted",
		"收掉确认框不等于退出")

	# 再断一次，这次确认退出。
	_set_state(NetworkService.SessionState.RECONNECTING)
	await _settle(3)
	main._reconnect_cancel_button.pressed.emit()
	await _settle(2)
	dialog = _top_dialog()
	if _h.expect(dialog != null, "second_dialog_missing", "第二次点「退出对局」没弹确认框"):
		dialog._confirm_btn.pressed.emit()
		await _settle(4)
		_h.expect(nav.count == 1, "confirm_no_nav", "确认退出之后没回主菜单（导航 %d 次）" % nav.count)
		_h.expect(SaveManager.load_reconnect().is_empty(), "confirm_kept_credentials", "确认退出之后凭证还在")
		_h.expect(NetworkService.state != NetworkService.SessionState.RECONNECTING
				and not ModalStack.has(MainScript.RECONNECT_MODAL_ID), "confirm_still_reconnecting",
			"确认退出之后还在重连，或者遮罩还在")
		_h.expect(not GameState.team_mode, "confirm_team_mode", "确认退出之后还在组队模式")
	await _drop_main(main)


func _drop_main(main: MainScript) -> void:
	main.set_reconnect_cancel_navigation_check_hook(Callable())
	ModalStack.close_all()
	main.queue_free()
	await _settle(2)


# --- 6. 摆放界面的「设定」 -------------------------------------------------------------

func _case_prep_settings() -> void:
	GameState.reset_run()
	NetworkService.state = NetworkService.SessionState.OFFLINE
	NetworkService.team_active = false
	var prep: PrepScreenScript = (load("res://scenes/prep/PrepScreen.tscn") as PackedScene).instantiate()
	add_child(prep)
	await _settle(12)
	var settings_btn := prep.find_child("SettingsButton", true, false) as Button
	if not _h.expect(settings_btn != null and settings_btn.text == "设定", "prep_settings_button",
			"摆放界面右上角应是「设定」"):
		prep.queue_free()
		await _settle(2)
		return
	_h.expect(not _tree_has_button_text(prep, "静音") and not _tree_has_button_text(prep, "已静音"), "prep_mute_left",
		"摆放界面上还有静音键")
	var leaves := [0]
	prep.leave_match_requested.connect(func() -> void: leaves[0] += 1)
	for online in [false, true]:
		NetworkService.team_active = online
		settings_btn.pressed.emit()
		await _settle(2)
		var top: Dictionary = ModalStack.top()
		var page := top.get("content") as SettingsScreenScript
		if not _h.expect(str(top.get("id", "")) == PrepScreenScript.SETTINGS_MODAL_ID and page != null and page.in_match,
				"settings_not_modal", "「设定」没以弹层打开设定页（不能整页切走：摆放界面一拆，对局就断了）"):
			break
		_h.expect(not _tree_has_button_text(page, tr("settings_replay_tutorial")), "settings_has_replay",
			"对局里的设定不该有「重新体验教学」")
		var leave := page.find_child("LeaveMatch", true, false) as Button
		if online:
			if _h.expect(leave != null and leave.text == "退出对局", "settings_no_leave", "联网对局的设定里要有「退出对局」"):
				leave.pressed.emit()
				await _settle(1)
				_h.expect(leaves[0] == 1, "settings_leave_not_forwarded",
					"点「退出对局」没交给 Main（leave_match_requested 发了 %d 次）" % leaves[0])
			# 换语言时设定页整页重建，「退出对局」不能丢。
			LocaleManager.set_locale("en")
			await _settle(2)
			var leave_en := page.find_child("LeaveMatch", true, false) as Button
			_h.expect(leave_en != null and leave_en.text == "Leave Match", "settings_leave_lost_on_locale",
				"换成英文后「退出对局」不见了")
			LocaleManager.set_locale("zh")
			await _settle(2)
		else:
			_h.expect(leave == null, "offline_has_leave", "离线 / 教学的设定里不该有「退出对局」")
		page.back_requested.emit()
		await _settle(2)
		_h.expect(not ModalStack.has(PrepScreenScript.SETTINGS_MODAL_ID), "settings_back_not_closing",
			"设定页点「返回」没关掉")
	# 主界面的设定页照旧。
	var menu_page: SettingsScreenScript = (load("res://scenes/menu/SettingsScreen.tscn") as PackedScene).instantiate()
	add_child(menu_page)
	await _settle(1)
	_h.expect(_tree_has_button_text(menu_page, tr("settings_replay_tutorial"))
			and menu_page.find_child("LeaveMatch", true, false) == null, "menu_settings_changed",
		"主界面的设定页应照旧有「重新体验教学」、没有「退出对局」")
	menu_page.queue_free()
	prep.queue_free()
	await _settle(2)
	NetworkService.team_active = false


# --- 7. 对局历史 --------------------------------------------------------------------

func _case_history_judged_loss() -> void:
	var panel: MatchHistoryPanelScript = MatchHistoryPanelScript.new()
	var left := [{"slot": 0, "player_id": "me", "online_at_end": false},
		{"slot": 3, "player_id": "rival", "online_at_end": true}]
	_h.expect(panel._my_result({"outcome": "team_a", "my_slot": 0, "seats": left}) == "loss", "history_leaver_won",
		"队伍赢了但我掉线未归：应算负")
	_h.expect(panel._my_result({"outcome": "draw", "my_slot": 0, "seats": left}) == "loss", "history_leaver_draw",
		"平局但我掉线未归：应算负")
	var stayed := [{"slot": 0, "player_id": "me", "online_at_end": true},
		{"slot": 1, "player_id": "mate", "online_at_end": false}]
	_h.expect(panel._my_result({"outcome": "team_a", "my_slot": 0, "seats": stayed}) == "win", "history_teammate_left",
		"队友跑了不影响我的胜负")
	_h.expect(panel._my_result({"outcome": "team_b", "my_slot": 0}) == "loss"
			and panel._my_result({"outcome": "draw", "my_slot": 0}) == "draw", "history_basic",
		"没有座位明细的旧记录照旧按队伍结果算")
	panel.free()


# --- 工具 --------------------------------------------------------------------------

func _started_record(mode: String) -> void:
	SaveManager.clear_reconnect()
	SaveManager.save_reconnect(DUMMY_TOKEN, DUMMY_ADDRESS, DUMMY_PORT, mode)
	SaveManager.mark_match_started()


func _set_state(to: NetworkService.SessionState) -> void:
	NetworkService.state = to
	NetworkService.session_changed.emit()


func _top_dialog() -> ConfirmDialog:
	var content: Variant = ModalStack.top().get("content")
	return content as ConfirmDialog if content is ConfirmDialog else null


func _tree_has_button_text(root: Node, text: String) -> bool:
	if root is Button and (root as Button).text == text:
		return true
	for child in root.get_children():
		if _tree_has_button_text(child, text):
			return true
	return false


# 函数体（不含注释行）：从函数头到下一个顶层 func。
func _function_body(path: String, header: String) -> String:
	var src := FileAccess.get_file_as_string(path)
	var at := src.find(header)
	if at < 0:
		return ""
	var end := src.find("\nfunc ", at + header.length())
	var body := src.substr(at, (end - at) if end > 0 else -1)
	var lines: PackedStringArray = []
	for line in body.split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _has_digit(text: String) -> bool:
	for i in text.length():
		if "0123456789".contains(text[i]):
			return true
	return false


func _has_cjk(text: String) -> bool:
	for i in text.length():
		var code := text.unicode_at(i)
		if code >= 0x3000 and code <= 0x9FFF:
			return true
	return false


func _settle(frames: int = 2) -> void:
	for _i in frames:
		await get_tree().process_frame


func _snapshot_files() -> Dictionary:
	var out := {}
	for path in USER_FILES:
		out[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	return out


func _restore_files(snap: Dictionary) -> void:
	for path in snap.keys():
		var want = snap[path]
		if want == null:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(want)
			f.close()


func _save_network_state() -> Dictionary:
	return {
		"state": NetworkService.state,
		"team_active": NetworkService.team_active,
		"session_token": NetworkService.session_token,
		"reconnect_address": NetworkService.reconnect_address,
		"team_local_slot": NetworkService.team_local_slot,
		"pending_abandon_token": NetworkService.pending_abandon_token,
		"match_mode": NetworkService.match_mode,
	}


func _restore_network_state(saved: Dictionary) -> void:
	NetworkService.state = int(saved.get("state", NetworkService.SessionState.OFFLINE)) as NetworkService.SessionState
	NetworkService.team_active = bool(saved.get("team_active", false))
	NetworkService.session_token = str(saved.get("session_token", ""))
	NetworkService.reconnect_address = str(saved.get("reconnect_address", ""))
	NetworkService.team_local_slot = int(saved.get("team_local_slot", -1))
	NetworkService.pending_abandon_token = str(saved.get("pending_abandon_token", ""))
	NetworkService.match_mode = str(saved.get("match_mode", ""))
