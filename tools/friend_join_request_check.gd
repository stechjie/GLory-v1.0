extends Node

# 11-26：好友界面的「加入」要**那位好友同意**才进房（用户定）。
#   · 只管好友界面那颗键；邀请上的「加入」照旧直接进（ChatScreen → _join_room_by_id）。
#   · 账号服务器还是旧版（没有申请接口）时，退回老的直接加入 —— 功能不能因为没部署就断。
#
# 这里钉客户端这半边：
#   1. 两个纯判据直接喂数据（FriendsScreen.join_request_waiting / Main.join_request_outcome）；
#   2. 接线：好友行的键发的是申请、Main 接了申请 / 回复 / 撤回三种推送、同意才进房、
#      邀请那条路没被改成也要申请。
# 服务端规则（只能向在线好友申请、只有被申请的人能回、过期作废、撤回通知收框）在
# backend/tests/test_join_requests.py。
#
# 没覆盖（要两台真机 / 两个账号）：问询框真的弹出来、同意后真的进了房、30 秒超时两边的表现。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/friend_join_request_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const FriendsScreen := preload("res://scenes/menu/FriendsScreen.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "friend_join_request"
const FRIENDS_SRC := "res://scenes/menu/FriendsScreen.gd"
const MAIN_SRC := "res://scenes/main/Main.gd"
const ACCOUNT_SRC := "res://scripts/autoload/AccountManager.gd"
const CHAT_SRC := "res://scenes/menu/ChatScreen.gd"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_pure_rules()
	_case_friends_screen_wiring()
	_case_main_wiring()
	_case_backend_shape()
	_h.finish(get_tree())


func _code_of(path: String) -> String:
	var src := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	_h.expect(not src.is_empty(), "src_readable_%s" % path.get_file(), "读不到 %s" % path)
	# 剥掉注释行：注释里会逐字写旧实现来解释为什么改，裸 contains 会把它当成代码命中。
	var code := ""
	for line in src.split("\n"):
		if (line as String).strip_edges().begins_with("#"):
			continue
		code += line + "\n"
	return code


func _slice_func(code: String, name: String) -> String:
	var start := code.find("func " + name + "(")
	if start < 0:
		return ""
	var next := code.find("\nfunc ", start + 1)
	var next_static := code.find("\nstatic func ", start + 1)
	if next_static >= 0 and (next < 0 or next_static < next):
		next = next_static
	return code.substr(start) if next < 0 else code.substr(start, next - start)


func _case_pure_rules() -> void:
	# 键什么时候写「已申请」并点不动。
	_h.expect(not FriendsScreen.join_request_waiting({}, "AAAA2222", 1000),
		"not_waiting_by_default", "没申请过 ⇒ 键能点")
	_h.expect(FriendsScreen.join_request_waiting({"AAAA2222": 5000}, "AAAA2222", 1000),
		"waiting_before_deadline", "申请发出去、还没到点 ⇒ 等回复中")
	_h.expect(not FriendsScreen.join_request_waiting({"AAAA2222": 5000}, "AAAA2222", 5000),
		"not_waiting_after_deadline", "到点了 ⇒ 键恢复（对方一直不理也不会永远卡着）")
	_h.expect(not FriendsScreen.join_request_waiting({"AAAA2222": 5000}, "BBBB3333", 1000),
		"waiting_is_per_friend", "向甲申请不影响乙那一行的键")
	_h.expect(FriendsScreen.JOIN_ASK_MSEC > 30000,
		"lock_outlasts_server_ttl", "键锁的时间要比服务器的 30 秒长一点（服务器那边先过期）")
	# 服务器回的状态码该怎么办。
	_h.expect(MainScript.join_request_outcome(200) == "sent", "outcome_sent", "200 ⇒ 申请发出去了")
	_h.expect(MainScript.join_request_outcome(404) == "direct" and MainScript.join_request_outcome(405) == "direct",
		"outcome_old_server", "404 / 405（旧服务器没有这个接口）⇒ 照旧直接加入")
	for status in [0, 401, 403, 409, 429, 500, 503]:
		_h.expect(MainScript.join_request_outcome(status) == "failed", "outcome_failed_%d" % status,
			"%d ⇒ 没发出去（不能当成同意，也不能偷偷直接加入）" % status)


func _case_friends_screen_wiring() -> void:
	var code := _code_of(FRIENDS_SRC)
	_h.expect(code.contains("signal join_request_requested(friend_code: String, friend_name: String, room_id: int, on_failed: Callable)"),
		"request_signal", "FriendsScreen 要有 join_request_requested 信号")
	var row := _slice_func(code, "_friend_row")
	_h.expect(not row.is_empty(), "friend_row_found", "切不出 FriendsScreen._friend_row")
	_h.expect(row.contains("join.pressed.connect(_ask_to_join.bind(code, str(entry.get(\"player_name\", \"\")), room_id))"),
		"join_button_asks", "好友行的「加入」键要走 _ask_to_join（发申请）")
	_h.expect(not row.contains("join_room_requested.emit("),
		"join_button_no_direct_join", "★ 好友行的「加入」键不能再直接发 join_room_requested（那是一按就进）")
	_h.expect(row.contains("join.disabled = waiting"),
		"join_button_locks_while_waiting", "等回复时键点不动")
	var ask := _slice_func(code, "_ask_to_join")
	_h.expect(ask.contains("join_request_requested.emit(code, friend_name, room_id,")
			and ask.contains("_join_asked[code] ="),
		"ask_emits_and_marks", "_ask_to_join：记下「已申请」并把申请交给 Main")
	_h.expect(not ask.contains("join_room_requested.emit("),
		"ask_never_joins", "_ask_to_join 里不能直接加入")
	var push := _slice_func(code, "_on_presence_push")
	_h.expect(push.contains("JOIN_REPLY_PUSH") and push.contains("_join_asked.erase("),
		"reply_unlocks_button", "收到好友的回复 ⇒ 那一行的键恢复")
	# 观战没动：对局中的好友还是「观战」。
	_h.expect(row.contains("spectate_room_requested.emit(room_id)"),
		"spectate_untouched", "对局中的好友那颗「观战」不受影响")


func _case_main_wiring() -> void:
	var code := _code_of(MAIN_SRC)
	var friends := _slice_func(code, "_show_friends_screen")
	_h.expect(friends.contains("screen.join_request_requested.connect(_request_join_friend_room)"),
		"main_connects_request", "Main 要接 FriendsScreen 的 join_request_requested")
	_h.expect(code.contains("RealtimeService.message_received.connect(_on_join_request_realtime)"),
		"main_listens_pushes", "Main 要接申请 / 回复 / 撤回的推送")
	var realtime := _slice_func(code, "_on_join_request_realtime")
	for kind in ["room_join_request", "room_join_reply", "room_join_cancel"]:
		_h.expect(realtime.contains("\"%s\"" % kind), "push_%s_handled" % kind, "要处理 %s 推送" % kind)
	# 申请人这边：只有「同意」才进房，而且进的是自己记下的那个房间。
	var replied := _slice_func(code, "_on_join_request_replied")
	_h.expect(not replied.is_empty(), "replied_found", "切不出 Main._on_join_request_replied")
	var reject_at := replied.find("if not bool(payload.get(\"accept\", false)):")
	var join_at := replied.find("_join_room_by_id(room_id)")
	_h.expect(reject_at >= 0 and join_at > reject_at,
		"join_only_after_accept", "★ 先判「没同意就 return」，后面才是 _join_room_by_id")
	_h.expect(replied.contains("str(_join_request_out.get(\"id\", \"\")) != str(payload.get(\"request_id\", \"\"))"),
		"reply_must_match_my_request", "回复的编号对不上我现在等的那张 ⇒ 不理（过期的 / 伪造的）")
	_h.expect(replied.contains("var room_id := int(_join_request_out.get(\"room_id\", 0))"),
		"room_from_own_record", "进哪个房间用自己记下的，不用推送里带回来的")
	# 发申请：旧服务器退回直接加入；失败时把键恢复。
	var request := _slice_func(code, "_request_join_friend_room")
	_h.expect(request.contains("await AccountManager.request_room_join(code, room_id)")
			and request.contains("join_request_outcome("),
		"request_goes_to_server", "发申请走 AccountManager.request_room_join，结果按 join_request_outcome 分")
	_h.expect(request.count("on_failed.call()") >= 2,
		"request_failure_unlocks", "没发出去 / 退回直接加入时要把好友界面那颗键恢复")
	# 好友这边：弹问询框；不在那个房间大厅里就直接回拒绝。
	var received := _slice_func(code, "_on_join_request_received")
	_h.expect(received.contains("DialogService.confirm(") and received.contains("\"on_result\": _on_join_request_answered"),
		"prompt_shown", "有人申请 ⇒ 弹同意 / 拒绝的问询框")
	_h.expect(received.contains("if not _can_answer_join_request(room_id):")
			and received.contains("AccountManager.reply_room_join(request_id, false)"),
		"auto_decline_when_not_in_room", "不在那个房间大厅里（开打了 / 走了）⇒ 直接回拒绝，不让对方干等")
	var answered := _slice_func(code, "_on_join_request_answered")
	_h.expect(answered.contains("var accept := result == ConfirmDialog.RESULT_CONFIRMED")
			and answered.contains("await AccountManager.reply_room_join(request_id, accept)"),
		"only_confirm_is_accept", "★ 只有点了「同意」才算同意；拒绝、框被关掉都回拒绝")
	_h.expect(answered.contains("if _join_request_in.is_empty():"),
		"no_reply_after_self_close", "超时 / 对方撤回时框是自己关的，不再多回一条")
	# 邀请那条路没动：聊天里邀请卡片的「加入」还是直接进。
	var chat_screen := _slice_func(code, "_show_chat_screen")
	_h.expect(chat_screen.contains("screen.join_room_requested.connect(_join_room_by_id)"),
		"invite_still_joins_directly", "邀请上的「加入」照旧直接进（用户定：邀请直接进）")
	var chat_src := _code_of(CHAT_SRC)
	_h.expect(not chat_src.contains("join_request_requested"),
		"chat_has_no_request_path", "聊天界面不走申请那条路")
	var account := _code_of(ACCOUNT_SRC)
	for needed in ["func request_room_join(code: String, room_id: int) -> Dictionary:",
			"func reply_room_join(request_id: String, accept: bool) -> Dictionary:",
			"func cancel_room_join() -> Dictionary:"]:
		_h.expect(account.contains(needed), "account_api_%s" % needed.get_slice("(", 0).get_slice(" ", 1),
			"AccountManager 缺接口：%s" % needed)
	_h.expect(account.contains("\"/v1/me/join-requests\""), "account_api_path", "申请接口的路径要和后端一致")


func _case_backend_shape() -> void:
	var route := FileAccess.get_file_as_string("res://backend/app/routes/join_requests.py")
	if not _h.expect(not route.is_empty(), "be_route_readable", "读不到 backend/app/routes/join_requests.py"):
		return
	_h.expect(route.contains("APIRouter(prefix=\"/v1/me/join-requests\""), "be_prefix", "后端路由前缀要和客户端一致")
	for kind in ["room_join_request", "room_join_reply", "room_join_cancel"]:
		_h.expect(route.contains("\"t\": \"%s\"" % kind), "be_push_%s" % kind, "后端要推 %s" % kind)
	_h.expect(route.contains("relation != \"friends\""), "be_friends_only", "只能向好友申请")
	var main_py := FileAccess.get_file_as_string("res://backend/app/main.py")
	_h.expect(main_py.contains("app.include_router(join_request_routes.router)"),
		"be_router_registered", "路由要挂进 app（写了不挂 = 线上 404，客户端会一直走「直接加入」而没人发现）")
