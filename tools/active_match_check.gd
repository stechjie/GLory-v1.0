extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Rooms := preload("res://scripts/multiplayer/RoomService.gd")
const Tokens := preload("res://scripts/multiplayer/ReconnectService.gd")
var now := 100.0
var closed := 0

func _ready() -> void:
	var h := Harness.new("active_match")
	h.expect(NetworkService.ROOM_SUSPEND_GRACE_SEC == 120.0, "product_grace_120s", "All humans offline must release the match after 120 seconds")
	var tokens := Tokens.new()
	tokens.configure(func(): return now, func(_m): pass, {})
	var rooms := Rooms.new()
	rooms.configure(func(): return now, func(): return 1700000000.0, func(_m): pass, func(): return 0, {"room_suspend_grace_sec": NetworkService.ROOM_SUSPEND_GRACE_SEC}, tokens)
	var room := {"id": 1, "state": "prep", "run_over": false, "empty_since": 100.0, "peer_slot": {}, "slot_states": ["dummy", "dummy"], "seat_tokens": {0: "TEST"}, "state_started_at": 100.0}
	# RoomService counts seat_tokens via their live token index.
	tokens.token_seat["TEST"] = {"room_id": 1, "slot": 0}
	rooms.rooms[1] = room
	var close := func(r: Dictionary, _reason: String):
		closed += 1
		r.state = "closed"
	var advance := func(_r): pass
	now = 219.9
	rooms.cleanup_rooms(close, advance)
	h.expect(closed == 0, "grace", "Room closed before the recovery window")
	h.expect(rooms.room_online_count(room) == 0, "ai_not_human", "AI counted as an online human")
	now = 220.0
	rooms.cleanup_rooms(close, advance)
	h.expect(closed == 1 and rooms.rooms.is_empty(), "expiry", "Expired suspended room was not reclaimed")
	room.state = "prep"
	room.peer_slot = {7: 0}
	rooms.rooms[1] = room
	rooms.peer_room[7] = 1
	now = 200.0 + NetworkService.ROOM_SUSPEND_GRACE_SEC
	room.state_started_at = now
	rooms.cleanup_rooms(close, advance)
	h.expect(closed == 1 and float(room.empty_since) == 0.0, "human_keeps_match", "Online human did not preserve match")
	room.peer_slot = {}
	rooms.peer_room.clear()
	rooms.cleanup_rooms(close, advance)
	h.expect(float(room.empty_since) == now, "restart_timer", "Last human leaving did not restart grace")
	for phase in ["battle", "result"]:
		rooms.rooms.clear()
		var phase_room := {"id": 2, "state": phase, "run_over": false, "empty_since": 1000.0, "peer_slot": {}, "seat_tokens": {0: "PHASE"}, "state_started_at": 1000.0}
		tokens.token_seat["PHASE"] = {"room_id": 2, "slot": 0}
		rooms.rooms[2] = phase_room
		var before := closed
		now = 1119.9
		rooms.cleanup_rooms(close, advance)
		h.expect(closed == before and bool(phase_room.get("suspended", false)), phase + "_can_resume_before_120s", "Offline match must remain resumable before 120 seconds")
		now = 1120.0
		rooms.cleanup_rooms(close, advance)
		h.expect(closed == before + 1 and rooms.rooms.is_empty(), phase + "_expires_at_120s", "Offline match must close at 120 seconds")
	var saved := {}
	for suffix in ["", ".bak", ".tmp"]:
		var path: String = SaveManager.RECONNECT_PATH + suffix
		if FileAccess.file_exists(path): saved[path] = FileAccess.get_file_as_bytes(path)
	SaveManager.clear_reconnect()
	SaveManager.save_reconnect("TEST", "127.0.0.1", 8910)
	SaveManager.mark_match_started()
	SaveManager.save_reconnect("TEST", "127.0.0.1", 8910)
	h.expect(bool(SaveManager.load_reconnect().get("match_started", false)), "late_refresh", "Refresh erased started-match marker")
	h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "can_resume", "Started match is not resumable")
	await _check_status_superseded(h)
	NetworkService.request_user_leave()
	h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "explicit_leave", "Leaving a started match destroyed credentials")
	NetworkService.cancel_reconnect()
	h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "cancel_resume", "Cancelling resume unlocked a started match")
	var old_rooms: Dictionary = NetworkService._rooms
	var old_tokens: Dictionary = NetworkService._token_seat
	var old_peers: Dictionary = NetworkService._peer_room
	NetworkService._rooms = {1: {"id": 1, "state": "prep", "peer_slot": {7: 0}, "run_over": false}}
	NetworkService._token_seat = {"TEST": {"room_id": 1, "slot": 1}}
	NetworkService._peer_room = {7: 1}
	h.expect(not NetworkService._active_match_for_token("TEST").is_empty(), "other_human_blocks", "Other online human did not block new match")
	NetworkService._rooms[1].run_over = true
	h.expect(NetworkService._active_match_for_token("TEST").is_empty(), "finished_unlocks", "Finished match still blocks new match")
	NetworkService._rooms[1].run_over = false
	NetworkService._rooms[1].state = "lobby"
	h.expect(NetworkService._active_match_for_token("TEST").is_empty(), "lobby_unlocks", "Unstarted lobby blocks new match")
	h.expect(NetworkService._active_match_for_token("MISSING").is_empty(), "gone_unlocks", "Missing match still blocks new match")
	_check_one_seat_per_account(h)
	_check_lobby_reserve_grace(h)
	_check_match_status_three_states(h)
	NetworkService._rooms = old_rooms
	NetworkService._token_seat = old_tokens
	NetworkService._peer_room = old_peers
	SaveManager.save_reconnect("LOBBY", "127.0.0.1", 8910)
	SaveManager.mark_pending_leave("LEFT")
	h.expect(SaveManager.load_resumable_reconnect().is_empty(), "lobby_leave", "Lobby leave became resumable")
	SaveManager.clear_reconnect()
	for path in saved:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(saved[path])
		f.close()
	h.finish(get_tree())

# 状态查询的三态（协议 40）。覆盖的缺陷：大厅座位以前被答成 "clear"，客户端
# 当场 SaveManager.clear_reconnect() 删掉凭证 —— 在自定义房间里杀进程、重开之后
# 玩家落在主界面、连个「返回房间」的按钮都没有，而服务器还替他留着座位。
func _check_match_status_three_states(h: RefCounted) -> void:
	var seat := func(state: String, run_over: bool, online: bool) -> void:
		var room := {
			"id": 88, "state": state, "run_over": run_over, "empty_since": 0.0,
			"peer_slot": {5: 0} if online else {}, "seat_tokens": {0: "T"},
			"state_started_at": now,
		}
		NetworkService._rooms = {88: room}
		NetworkService._token_seat = {"T": {"room_id": 88, "slot": 0}}
		NetworkService._peer_room = {5: 88} if online else {}

	h.expect(NetworkService._match_status_for_token("NOPE") == "clear", "status_unknown_token_clear",
		"认不出来的 token 该答 clear")
	seat.call("lobby", false, true)
	h.expect(NetworkService._match_status_for_token("T") == "lobby", "status_lobby_is_lobby",
		"大厅座位被答成了别的 —— 答 clear 的话客户端会把凭证删掉")
	seat.call("prep", false, true)
	h.expect(NetworkService._match_status_for_token("T") == "active", "status_match_is_active",
		"正在打的局该答 active")
	seat.call("prep", true, true)
	h.expect(NetworkService._match_status_for_token("T") == "clear", "status_run_over_clear",
		"已结束的对局该答 clear")
	seat.call("closed", false, true)
	h.expect(NetworkService._match_status_for_token("T") == "clear", "status_closed_clear",
		"已关的房间该答 clear")
	# ⚠️ 还有一个分支**故意没在这里断言**：「开局中但全房没人、且过了恢复窗口」
	# 该答 clear（不能答 lobby —— 那会让玩家点一个注定失败的「返回房间」）。
	# 它过不去的原因是时钟：那条判据要 `empty_since > 0.0` 且距今 >= 120 秒，而
	# `NetworkService._now()` 是**进程启动以来的秒数**，门禁跑在第几秒上，构造不出
	# 一个既是正数又在 120 秒前的 empty_since。硬写一个只会静默走不到那条分支 ——
	# 那正是假绿。该分支的判定在 _room_is_active_match 里，而本文件开头那组
	# grace / expiry / *_expires_at_120s 用的是**可注入时钟的 RoomService 实例**，
	# 覆盖的就是同一段逻辑。

	# 两个纯判定。真正的风险不是这三态算错，而是**新增的 lobby 没人认** ——
	# 漏在 allow_new_match 里，在房间里坐过的人建房/排队会全被「暂时无法确认对局
	# 状态」堵死；漏在凭证那边，就回到改协议之前那个删凭证的缺陷。
	h.expect(NetworkService.status_allows_new_match("lobby"), "lobby_allows_new_match",
		"大厅座位把开新局堵住了 —— 这比幽灵座位严重")
	h.expect(NetworkService.status_allows_new_match("clear"), "clear_allows_new_match", "clear 该放行")
	h.expect(not NetworkService.status_allows_new_match("active"), "active_needs_confirm",
		"正在打的局必须先过退出确认，不能直接开新局")
	h.expect(not NetworkService.status_allows_new_match("unknown"), "unknown_blocks_new_match",
		"问不出来时不该放行 —— 那会让人把还在打的局丢掉")
	h.expect(NetworkService.credential_action_for_status("lobby") == "", "lobby_keeps_credential",
		"大厅座位动了凭证：删掉 = 没路回房间，打 match_started = 弹判负确认框")
	h.expect(NetworkService.credential_action_for_status("clear") == "clear_reconnect",
		"clear_drops_credential", "死凭证该删，否则那颗键永远挂着")
	h.expect(NetworkService.credential_action_for_status("active") == "mark_match_started",
		"active_marks_started", "正在打的局要打上标记，否则重连面板会给「不罚直接走」")
	h.expect(NetworkService.credential_action_for_status("unknown") == "", "unknown_keeps_credential",
		"问不出来时动凭证 = 拿一次网络抖动换掉玩家的一局")

# 大厅掉线的座位保留时长。覆盖的缺陷：自定义房间里杀进程之后，别人要盯着一个
# 永远不 ready 的幽灵座位 10 分钟，而**那 10 分钟一秒都兑现不了** —— app 重开后
# MainMenu 问 check_saved_match()，服务器按 _active_match_for_token 把大厅答成
# "clear"，客户端当场删掉重连凭证，玩家落在主界面连个「返回房间」的按钮都没有。
func _check_lobby_reserve_grace(h: RefCounted) -> void:
	var custom: float = NetworkService.CUSTOM_LOBBY_RESERVE_GRACE_SEC
	var matched: float = NetworkService.LOBBY_SUSPEND_GRACE_SEC
	h.expect(NetworkService._lobby_reserve_grace_sec({}) == custom, "custom_lobby_short_grace",
		"自定义房间的大厅座位用了长宽限 —— 幽灵座位会挂在那里挡着别人")
	h.expect(NetworkService._lobby_reserve_grace_sec({"matched": true}) == matched, "matched_lobby_keeps_grace",
		"匹配房间的座位被按自定义房间缩短了：那六个位置是账号服务器分配的，不能让别人顶")
	h.expect(custom < matched, "custom_shorter_than_matched", "两类大厅的宽限应当是分开的两个值")
	# 下限不是凑的：这个宽限唯一还兑现的是「app 没关、网抖一下」那条自动重连，
	# 而客户端要先判掉线（ENet 最少 15 秒 / 心跳 HEARTBEAT_TIMEOUT_SEC）才会开始重连。
	# 设得比判掉线还短 = 自动重连永远赶不上，等于悄悄把它关掉。
	h.expect(custom >= NetworkService.HEARTBEAT_TIMEOUT_SEC, "grace_outlives_disconnect_detection",
		"宽限短于掉线判定：自动重连回来时座位已经没了，等于把大厅重连整个关掉")
	# 上面四条验的是数值与分流。这一条走**真实路径** _room_reserve_peer()：
	# 常量对了但没接到那一行上，照样是 600 秒（先例：上面那两个 grace 常量就都存在过
	# "定义了但某条分支没用它" 的阶段）。
	for matched_room in [false, true]:
		var room := {
			"id": 77, "state": "lobby", "run_over": false, "matched": matched_room,
			"slot_states": ["player", "empty", "empty", "empty", "empty", "empty"],
			"ready": [false, false, false, false, false, false],
			"peer_slot": {9: 0}, "seat_tokens": {}, "reserve_deadline": {},
			"reserved": {}, "leader_slot": 0, "empty_since": 0.0,
		}
		NetworkService._rooms = {77: room}
		NetworkService._peer_room = {9: 77}
		NetworkService._room_reserve_peer(room, 9)
		var left: float = float((room.get("reserve_deadline", {}) as Dictionary).get(0, 0.0)) - NetworkService._now()
		var want: float = matched if matched_room else custom
		var label := "matched" if matched_room else "custom"
		h.expect(abs(left - want) < 2.0, "reserve_peer_uses_%s_grace" % label,
			"_room_reserve_peer 给 %s 大厅排的宽限是 %.0f 秒，应当是 %.0f 秒" % [label, left, want])

# 一人一座（按名片上的账号 id）。覆盖的缺陷：在自定义房间里杀进程、重开之后建房 /
# 进房 / 匹配入座，旧座位还在 600 秒保留期里，于是一个账号同时占两个座位 ——
# 同房的人看到一个永远不 ready 的幽灵，房间还因此坐不满。
#
# 这里直接验 NetworkService._release_stale_seats_for_pid：三个入座 RPC 共用它，
# 在那一层验等于三条路径一起验，而且不用起真 ENet。
func _check_one_seat_per_account(h: RefCounted) -> void:
	var make_room := func(state: String, holder: int) -> Dictionary:
		var room := {
			"id": 55, "state": state, "run_over": false, "empty_since": 0.0,
			"slot_states": ["player", "empty", "empty", "empty", "empty", "empty"],
			"ready": [false, false, false, false, false, false],
			"peer_slot": {}, "seat_tokens": {}, "seat_pid": {0: "ACCOUNT-A"},
			"leader_slot": 0, "state_started_at": now,
		}
		NetworkService._rooms = {55: room}
		NetworkService._token_seat = {}
		NetworkService._peer_room = {}
		if holder > 0:
			room.peer_slot[holder] = 0
			NetworkService._peer_room[holder] = 55
		return room

	# ① 杀进程留下的大厅幽灵：没有任何连接挂在这个座位上 -> 放行并释放旧座位。
	var ghost := make_room.call("lobby", 0) as Dictionary
	var released := NetworkService._release_stale_seats_for_pid(42, "ACCOUNT-A")
	h.expect(released, "stale_lobby_allows_seating", "大厅幽灵座位不该挡住本人重新入座")
	h.expect(str(ghost.slot_states[0]) == "empty", "stale_lobby_seat_freed",
		"大厅幽灵座位没被释放 —— 一个账号会同时占两个座位")
	h.expect((ghost.get("seat_pid", {}) as Dictionary).is_empty(), "stale_lobby_pid_cleared",
		"账号 id 留在空座位上：补了 AI 之后战报会把这个人记进这一局")

	# ② 正在打的对局：**一个座位都不许动**，入座请求要被拒。把人从活局里拽出来，
	#    对同房另外五个人等于「别人替他跑路」。
	var live := make_room.call("prep", 7) as Dictionary
	var rejected := NetworkService._release_stale_seats_for_pid(42, "ACCOUNT-A")
	h.expect(not rejected, "active_match_refuses_seating", "有一局正在打，还允许再入座")
	h.expect(str(live.slot_states[0]) == "player", "active_match_seat_untouched",
		"把正在打的局里的座位释放掉了 —— 这会让同房其他人替他承担跑路")

	# ③ 就是这条连接自己的座位：不算残留。误释放的话，「已经在这个房间里」那条
	#    重复请求判断永远不成立，客户端重发一次 join 就会被重新安排座位、重签 token。
	var mine := make_room.call("lobby", 42) as Dictionary
	h.expect(NetworkService._release_stale_seats_for_pid(42, "ACCOUNT-A"), "own_seat_allows_seating",
		"自己的座位把自己挡住了")
	h.expect(str(mine.slot_states[0]) == "player", "own_seat_untouched",
		"把这条连接自己的座位释放了 —— 重复 join 会重新签 token")

	# ④ 进程内门禁（tools/ 下的探针）不带名片，没有 pid 可判：照旧放行、不动任何东西。
	var no_card := make_room.call("lobby", 0) as Dictionary
	h.expect(NetworkService._release_stale_seats_for_pid(42, ""), "no_card_allows_seating",
		"没有名片的进程内路径被挡住了")
	h.expect(str(no_card.slot_states[0]) == "player", "no_card_touches_nothing",
		"拿不到账号 id 却去释放座位：那是在凭猜测清别人的位子")

func _check_status_superseded(h: RefCounted) -> void:
	var was_processing := NetworkService.is_processing()
	NetworkService.set_process(false)
	NetworkService.team_active = true
	NetworkService.remote_address = "127.0.0.1"
	NetworkService.remote_port = 8910
	NetworkService.state = NetworkService.SessionState.JOINING
	var replies: Array[String] = []
	_capture_status(replies)
	await get_tree().process_frame
	h.expect(NetworkService._match_check_busy, "status_pending", "Status check should reuse an in-progress transport")
	NetworkService.begin_resume_from_disk("TEST", "127.0.0.1", 8910)
	await get_tree().create_timer(0.2).timeout
	h.expect(replies == ["unknown"], "status_superseded", "Old status coroutine must stop after foreground resume")
	h.expect(not NetworkService._match_check_busy and NetworkService._match_check_id.is_empty(), "status_released", "Superseded status must not hold the query lock")
	h.expect(NetworkService.state == NetworkService.SessionState.RECONNECTING and not SaveManager.load_resumable_reconnect().is_empty(), "resume_preserved", "Status query must not reset the resumed session or erase credentials")
	NetworkService.reset()
	NetworkService.set_process(was_processing)

func _capture_status(replies: Array[String]) -> void:
	replies.append(await NetworkService.check_saved_match())
