extends Node

# 门禁：退出对局（2026-10-06 用户要求；**2026-10-11 第 7 条改了口径**）。
#   · 断线了除了重连可以直接退出，退出要让玩家确认（只说会不会扣，不写扣多少）
#   · ★ 退出对局 = 该玩家**掉线超过 30 秒**：座位与重连凭证**都留着**，
#     对局没结束前**可以重连**、但**不可参与新房间**（10.11 第 7 条，推翻 10-06 的
#     「退出即可开新局」）。这一局结束（房内超过 30 秒没有活人 ⇒ 服务端自动作废；
#     或正常打完）之后凭证才会被清掉，那时才放行新局。
#   · 摆放界面的静音键改成「设定」（同主界面那一页），对局里「重新体验教学」换成「退出对局」
#
# 扣不扣、判不判负的规则在账号服务器，backend/tests/test_ranked.py 钉着（自定房间不碰信誉分、跑路判负）。
# 这里钉客户端这一半：
#   1. 确认框文字：四种模式各说各的，不出现数字；且**不能再说「不能再回来」**（现在是能重连的）
#   2. 重连凭证记下模式，同一个座位再存一次不丢、换座位不串
#   3. 退出对局 = 凭证与短码**都留着**（留着才能重连、也才会被服务器拦住开新房），
#      并给服务端发一条 _rpc_manual_exit_seat（**不是** _rpc_abandon_seat：那条会清座位）
#   4. 开新局被上一局拦住：弹的是「退出对局」，确认了**仍然开不了**（这一局还没结束）；取消不动凭证
#   5. 断线遮罩：开打了的局按钮是「退出对局」，点了先弹确认框、后台照样重连；连回去了确认框自动收掉；
#      确认了才退、才回主菜单（凭证仍留着）。没开打的局照旧「取消并返回主菜单」
#   6. 摆放界面右上角是「设定」：弹层打开设定页，联网对局里有「退出对局」、没有「重新体验教学」；
#      ★ 10.11 第 7 条：**离线自测对局里也要有**「退出对局」，只是行为不同 ——
#      联网先弹判负 / 扣分确认框，离线自测走 Main._exit_offline_team_match 直接退出、直接结束。
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
	"user://glory_public_token.txt",
	"user://glory_public_token.txt.bak",
	"user://glory_public_token.txt.tmp",
]
const DUMMY_PUBLIC_ID := "GATEXQ2345"


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
	await _case_abandon_keeps_resumable()
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
		# ★ 规则 2026-10-11 **下午改判，本条随之翻面**（上午那版要求的恰好相反）：
		#   上午：退出 = 按掉线算，座位与凭证留着、**能重连回来**，这一局结束前开不了新局
		#   下午：退出 = **彻底结束**这一局，回不去，但**能马上开新局**
		# 实现侧对应 NetworkService._revoke_seat_credentials（注销回来的资格，
		# 但**保留 seat_pid** —— 身份一清，结算时他反而一分不扣）。
		#
		# 为什么这句话值得一条门禁：它正是给「网络抖了、盯着断线遮罩、不耐烦想退」
		# 的人看的，他最可能照着它做决定。规则和文案任何一边单独改，都是主动误导。
		_h.expect(str(text).contains("无法再回到这一局"), "text_missing_irreversible",
			"确认框没说清「退出后回不去」—— 玩家会以为还能重连回来：%s" % text)
		_h.expect(not str(text).contains("游戏重连"), "text_still_promises_reconnect",
			"确认框还写着能「游戏重连」回来 —— 退出之后凭证已被服务器注销，这是假话：%s" % text)
		_h.expect(not str(text).contains("开不了新局"), "text_still_blocks_new_match",
			"确认框还写着「这一局结束前开不了新局」—— 改判之后退完就能开：%s" % text)
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


# --- 3. 退出 = 凭证与短码都留着、只发「我按掉线算」；这一局结束前开不了新局 ------------------
#
# ★ 10.11 第 7 条把这一整段反过来了。改之前钉的是「退出后凭证必须为空、服务器不再拦建房」，
#   而 10-06 那套口径正是本轮要修的：玩家一退出就再也回不去还没结束的局。
func _case_abandon_keeps_resumable() -> void:
	_started_record("casual")
	NetworkService.cancel_reconnect()
	_h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "cancel_now_abandons",
		"「取消并返回主菜单」不该删开打了的局的凭证（那是「退出对局」的事，要先确认）")
	_started_record("casual")
	NetworkService.pending_abandon_token = "gate_should_be_cleared"
	# 短码在服务器上还绑着旧座位，建房时服务器凭它拒（ACTIVE_MATCH_HINT）。10.11 起这是
	# **要的行为**：留着它 = 「不可参与新房间」。照 _rpc_team_create_room 开头那道闸对一遍。
	SaveManager.save_public_token(DUMMY_PUBLIC_ID)
	SaveManager.save_public_token(DUMMY_PUBLIC_ID)   # 第二次写出 .bak —— 只写空串的话会从 .bak 读回来
	NetworkService.public_token_id = DUMMY_PUBLIC_ID
	var server_before := {"rooms": NetworkService._rooms, "tokens": NetworkService._token_seat,
		"peers": NetworkService._peer_room, "public": NetworkService._public_token_seat}
	NetworkService._rooms = {1: {"id": 1, "state": "prep", "peer_slot": {7: 0}, "run_over": false}}
	NetworkService._token_seat = {"gate_old_seat": {"room_id": 1, "slot": 1}}
	NetworkService._peer_room = {7: 1}
	NetworkService._public_token_seat = {DUMMY_PUBLIC_ID: "gate_old_seat"}
	_h.expect(_server_guard_blocks(SaveManager.load_public_token()), "guard_fixture_broken",
		"夹具没搭好：退出前服务器就该凭短码拦住建房")
	NetworkService.abandon_started_match()
	_h.expect(not SaveManager.load_reconnect().is_empty(), "abandon_kept_credentials",
		"退出对局之后重连凭证没了 —— 玩家再也回不去这个还没结束的局（第 7 条明确要求能重连）")
	_h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "abandon_still_resumable",
		"退出对局之后凭证虽然还在，但不是「可重连」状态（主菜单那颗键会灰掉）")
	_h.expect(not SaveManager.load_public_token().is_empty()
			and NetworkService.public_token_id == DUMMY_PUBLIC_ID,
		"abandon_kept_public_id",
		"退出对局之后短码被清了 —— 服务器不再拦建房，于是「不可参与新房间」失效")
	_h.expect(_server_guard_blocks(SaveManager.load_public_token()), "server_still_blocks",
		"退出对局之后服务器不再以「正在对局中」拒建房 —— 第 7 条要求这一局结束前开不了新局")
	NetworkService._rooms = server_before.rooms
	NetworkService._token_seat = server_before.tokens
	NetworkService._peer_room = server_before.peers
	NetworkService._public_token_seat = server_before.public
	_h.expect(NetworkService.pending_abandon_token.is_empty(), "abandon_kept_pending_token", "退出对局之后还挂着待发的 abandon")
	# 结构：退出对局必须是「发一条按掉线算的通知 + 断开」，而且**不能用** _rpc_abandon_seat。
	var body := _function_body("res://scripts/autoload/NetworkService.gd", "func abandon_started_match")
	if _h.expect(not body.is_empty(), "abandon_func_missing", "找不到 NetworkService.abandon_started_match"):
		_h.expect(body.contains("_notice_manual_exit_then_reset()"), "abandon_no_notice",
			"开打了的局退出时没走「通知服务端 + 断开」这条路 —— 服务端不知道这人走了，"
			+ "全房没活人也不会自动作废")
		_h.expect(not body.contains("_rpc_abandon_seat"), "abandon_sends_abandon_seat",
			"退出对局发了 _rpc_abandon_seat —— 它会清掉座位上的账号、把座位转 AI，"
			+ "跑路的人反而一分不扣，而且对**正在打的局**根本不生效")
		_h.expect(not body.contains("mark_pending_leave"), "abandon_marks_pending_leave",
			"退出对局打了 pending_leave 标记 —— 那会让主菜单的「游戏重连」消失（第 7 条要求仍在）")
	# 通知那条路：发的是 _rpc_manual_exit_seat，而且**发完要等两帧**才 reset。
	var notice := _function_body("res://scripts/autoload/NetworkService.gd", "func _notice_manual_exit_then_reset")
	if _h.expect(not notice.is_empty(), "notice_func_missing", "找不到 _notice_manual_exit_then_reset"):
		_h.expect(notice.contains("_rpc_manual_exit_seat.rpc_id(1, session_token)"), "notice_wrong_rpc",
			"通知必须走 _rpc_manual_exit_seat（座位留着这条才成立）")
		var first_await := notice.find("await get_tree().process_frame")
		var reset_at := notice.find("\n\treset()")
		_h.expect(first_await > 0 and reset_at > first_await, "notice_no_flush_wait",
			"发完通知没等 flush 就 reset() —— ENet 的包要等下一次 poll，同帧断开会把包直接丢掉")
	_h.expect(notice.count("await get_tree().process_frame") >= 2, "notice_flush_frames",
		"至少要等两帧再断开，一帧在弱网下不一定够（丢了包 = 服务端永远不知道这人退了）")
	# 服务端那条 RPC（规则 2026-10-11 下午改判，本段随之翻面）：
	#   上午：**不许**动 token —— 退出后还要能重连回来
	#   下午：**必须**注销回来的资格，但**绝不能**碰 seat_pid
	#
	# 🔴 后半句是这条门禁真正的价值。`_clear_seat_metadata()` 会把 seat_pid 一起清掉，
	# 而扣分的依据链是 seat_pid → 战报 seats[].pid → ranked.settle 按 online_at_end
	# 判 abandon。身份一清，结算时这个位置被当成 AI，**跑路的人反而一分不扣** ——
	# 正好和改判的目的相反。所以「注销凭证」和「清座位」必须是两件事。
	var ns_src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	var exit_rpc := _function_body("res://scripts/autoload/NetworkService.gd", "func _rpc_manual_exit_seat")
	if _h.expect(not exit_rpc.is_empty(), "manual_exit_rpc_missing",
			"服务端没有 _rpc_manual_exit_seat —— 手动退出这条通知没人收"):
		_h.expect(not exit_rpc.contains("_clear_seat_metadata"),
			"manual_exit_rpc_clears_identity",
			"_rpc_manual_exit_seat 调了 _clear_seat_metadata —— 它会连 seat_pid 一起清掉，"
			+ "结算时这个座位被当成 AI，跑路的人反而一分不扣")
		_h.expect(exit_rpc.contains("_revoke_seat_credentials"),
			"manual_exit_rpc_keeps_credentials",
			"_rpc_manual_exit_seat 没注销座位的重连资格 —— 改判后退出就该回不去，"
			+ "留着 token 的话他照样能重连，而客户端那边已经按「能开新局」放行了")
		var revoke := _function_body("res://scripts/autoload/NetworkService.gd", "func _revoke_seat_credentials")
		_h.expect(revoke.contains("_token_seat.erase"), "revoke_keeps_token_index",
			"_revoke_seat_credentials 没断开 token -> 座位 的索引，resume 还能回来")
		_h.expect(not revoke.contains("seat_pid"), "revoke_touches_identity",
			"_revoke_seat_credentials 碰了 seat_pid —— 那是结算认人用的，碰了就扣不到分")
		_h.expect(exit_rpc.contains('manual[slot] = true'), "manual_exit_rpc_no_flag",
			"_rpc_manual_exit_seat 没打 manual_exit_slots —— 服务端仍把他算成活人，"
			+ "全房没活人的局不会自动结束（第 7 条上半条就废了）")
		_h.expect(exit_rpc.contains("get_remote_sender_id()") and exit_rpc.contains("!= slot"),
			"manual_exit_rpc_unauthenticated",
			"_rpc_manual_exit_seat 不校验发送者就是座位主人 —— 任何人拿别人 token 就能作废对方那局")
	_h.expect(ns_src.contains("func _tick_void_watchdog()"), "void_watchdog_missing",
		"没有 _tick_void_watchdog —— 「30 秒无活人自动结束」没有巡检者")


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
			# ★ 规则 2026-10-11 下午改判，本条翻面：确认退出之后**放行**开新局
			#   （上午那版是「这一局结束前一律拦」）。
			_h.expect(bool(box.get("ok", false)), "guard_confirm_still_blocked",
				"确认退出之后还是不放行开新局 —— 改判后退出就是彻底结束，该能马上开新局")
			# 🔴 这一条**没有**跟着翻：凭证仍然不许客户端自己删。
			# 它现在扛的是「退出通知丢包」那条路 —— 服务器那边座位还活着，玩家建房会被
			# ACTIVE_MATCH_HINT 挡下，这时凭证还在才回得去（「游戏重连」可用）。
			# 删了的话就变成既开不了新局、也回不去，两头走不通。
			# 凭证的唯一删除点是 check_saved_match 听到服务器回 clear（credential_action_for_status）。
			_h.expect(not SaveManager.load_reconnect().is_empty(), "guard_confirm_cleared_credentials",
				"确认退出之后客户端自己把凭证删了 —— 必须等服务器回 clear 再删，"
				+ "否则退出通知丢包时玩家既回不去、也开不了新局")
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
		_h.expect(not SaveManager.load_reconnect().is_empty(), "confirm_cleared_credentials",
			"确认退出之后凭证被删了 —— 断线遮罩那条路退出后也要求仍能重连（第 7 条）")
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
	# ★★ 10.11 第 7 条：**离线自测的对局也要有「退出对局」**，而且它是
	# 「直接退出、直接结束对局」——不弹判负 / 扣分确认框。
	#
	# 判据必须是 NetworkService.is_offline_team_match()（offline_selftest 且非 team_active），
	# **不能**是「team_active 为假」：联网对局掉线时 team_active 也为假（正是重连遮罩
	# 出现的时候），那条路径必须照旧弹确认框。
	NetworkService.team_active = false
	NetworkService.offline_selftest = true
	_h.expect(NetworkService.is_offline_team_match(), "offline_flag_on",
		"offline_selftest 置起且无联机会话时，is_offline_team_match() 必须为真")
	NetworkService.team_active = true
	_h.expect(not NetworkService.is_offline_team_match(), "offline_flag_ignored_when_online",
		"有联机会话时即使 offline_selftest 为真也不能算本地自测"
		+ "（否则联机对局退出会跳过判负确认框，而这条是 10-06 用户明确要的）")
	NetworkService.team_active = false
	settings_btn.pressed.emit()
	await _settle(2)
	var offline_page := ModalStack.top().get("content") as SettingsScreenScript
	var offline_leave: Button = null
	if offline_page != null:
		offline_leave = offline_page.find_child("LeaveMatch", true, false) as Button
	_h.expect(offline_leave != null and offline_leave.text == "退出对局", "offline_selftest_has_leave",
		"离线自测的对局里必须有「退出对局」（用户口径：直接退出、直接结束对局）")
	if offline_leave != null:
		offline_leave.pressed.emit()
		await _settle(1)
		_h.expect(leaves[0] == 2, "offline_leave_forwarded",
			"离线自测点「退出对局」也要交给 Main（leave_match_requested 累计发了 %d 次）" % leaves[0])
	if offline_page != null:
		offline_page.back_requested.emit()
		await _settle(2)
	NetworkService.offline_selftest = false
	NetworkService.team_active = false
	# 结构：分叉真的在 request_exit_match 里（行为断言看不见「谁分叉」——
	# 把确认框那一支删掉、两边都走直接退出，行为断言照样绿）。
	var req_body := _function_body("res://scenes/main/Main.gd", "func request_exit_match")
	if _h.expect(not req_body.is_empty(), "exit_func_missing", "找不到 Main.request_exit_match"):
		_h.expect(req_body.contains("NetworkService.is_offline_team_match()")
			and req_body.contains("_exit_offline_team_match()"), "offline_exit_branch",
			"request_exit_match 必须先判本地自测并走直接退出（第 7 条）")
	var prep_src := FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd")
	_h.expect(prep_src.contains("NetworkService.is_offline_team_match()"),
		"prep_offline_leave_wired",
		"PrepUI 开设定页时必须把「本地自测」算进 can_leave_match，否则那颗按钮根本不出现")
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

# 同 NetworkService._rpc_team_create_room / join_room / join_matched 开头那道闸：
# 客户端带来的短码在服务器上指向一个没打完的对局，就拒。team_join 带的短码是从磁盘读的。
func _server_guard_blocks(public_id: String) -> bool:
	var token := str(NetworkService._public_token_seat.get(NetworkService._sanitize_public_id(public_id), ""))
	return not NetworkService._active_match_for_token(token).is_empty()

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
