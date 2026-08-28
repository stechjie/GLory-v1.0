extends Node

# RoomService 的独立门禁（D1 第 4 刀的验收条款：每个子服务有独立 headless 测试）。
#
# 抽出来的时候它是零覆盖的：515 行、24 个函数，是 D1 至今最大的一块，而
# handshake / persist / reconnect / channel 四个探针没有一个直接驱动它。
# 小的四个服务（ClientLog / RateLimit / ConnectionHealth / ReconnectBackoff）
# 反而都补了测试 —— 方向正好反了，最大的那块风险最高却最没网。
#
# 断言不是照着函数列表凑的，每一条都对着源码注释里写明的**真实故障**：
#   * 房间号不编分片 -> 两个进程各摇六位随机数，撞了之后玩家输房间号加入，
#     系统不知道该去哪个进程
#   * make_public_token 无界重试 -> 短码空间占满时服务器在这里死循环卡住
#   * move_seat_metadata 漏搬反向索引 -> 这人重连被放回旧槽位，队伍和身份色一起变回去
#   * release_seat_public_id 无条件删 -> 短码碰撞时先离开的人删掉后来者的映射（串号）
#   * 快照版本对不上却照读 -> 拿语义可能已变的存档恢复对局，产生查不出来的错乱
#   * 快照恢复不清 peer -> 房间以为一堆不存在的 peer 还在线，永远判不空、永远不回收
#
# 时钟走注入的假时钟，不用真时间：断言"宽限窗口按新基准重建"需要能控制 now。
#
# 快照往返与版本拒收的用例已随实现搬到 tools/dedicated_server_check.tscn ——
# 持久化按原始 README 归 DedicatedServerService（端口/持久化）。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RoomServiceScript := preload("res://scripts/multiplayer/RoomService.gd")
const ReconnectServiceScript := preload("res://scripts/multiplayer/ReconnectService.gd")
const CHECK_NAME := "room_service"

const TEST_SHARD := 11

var _h: RefCounted
var _now := 1000.0
var _logs: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	_check_room_id_encodes_shard()
	_check_room_ids_unique()
	_check_public_token_is_bounded()
	_check_seat_move_carries_everything()
	_check_seat_clear_releases_token()
	_check_public_id_release_is_compare_and_delete()
	_check_slot_queries()
	_check_find_or_create()
	_check_dirty_and_state_transitions()
	_check_public_room_list_filters()
	_check_counts()
	_check_injected_clock_is_used()
	_check_cleanup_policy()
	# _check_reserved_seat_expiry() 已删除 —— 见文件下方的说明。

	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

func _make_service() -> RefCounted:
	# token 索引已按 README 字面搬到 ReconnectService，RoomService 经注入读写它。
	var tokens: RefCounted = ReconnectServiceScript.new()
	tokens.configure(func() -> float: return _now, func(_m: String) -> void: pass, {})
	var svc: RefCounted = RoomServiceScript.new()
	svc.configure(
		func() -> float: return _now,
		func() -> float: return 1700000000.0,
		func(msg: String) -> void: _logs.append(msg),
		func() -> int: return TEST_SHARD,
		{
			"team_slots": 6,
			"room_lobby": "lobby",
			"room_result": "result",
			"room_closed": "closed",
			"reserve_grace_sec": 60.0,
			"room_prep": "prep",
			"room_battle": "battle",
			"lobby_empty_ttl_sec": 60.0,
			"room_suspend_grace_sec": 300.0,
			"prep_timeout_sec": 1800.0,
			"battle_timeout_sec": 300.0,
			"result_timeout_sec": 600.0,
		}, tokens)
	return svc

# --- 房间号 -------------------------------------------------------------------

# 房间号本身就是路由信息：NetworkConfig.shard_of_room() 要能反解出分片。
func _check_room_id_encodes_shard() -> void:
	var svc := _make_service()
	for i in 8:
		var room: Dictionary = svc.new_room()
		var id := int(room.get("id", 0))
		_h.expect(NetworkConfig.shard_of_room(id) == TEST_SHARD,
			"room_id_shard", "房间号 %d 反解出的分片不是 %d —— 多进程下路由会失效" % [id, TEST_SHARD])


func _check_room_ids_unique() -> void:
	var svc := _make_service()
	var seen := {}
	for i in 40:
		var id := int((svc.new_room() as Dictionary).get("id", 0))
		_h.expect(not seen.has(id), "room_id_collision", "同一分片内摇出了重复房间号 %d" % id)
		seen[id] = true


# --- 短码 ---------------------------------------------------------------------

# 原实现是 while 无界循环：空间被占满时服务器在这里死循环。有界之后必须返回空串。
func _check_public_token_is_bounded() -> void:
	var svc := _make_service()
	var id := str(svc.make_public_token())
	_h.expect(id.length() == RoomServiceScript.PUBLIC_TOKEN_LENGTH,
		"public_token_length", "短码长度应为 %d，实际 %d" % [RoomServiceScript.PUBLIC_TOKEN_LENGTH, id.length()])
	for ch in id:
		_h.expect(RoomServiceScript.PUBLIC_TOKEN_ALPHABET.contains(ch),
			"public_token_alphabet", "短码含字母表外的字符 '%s'（0/O/1/I 易混，已刻意排除）" % ch)

	# 空间耗尽走源码断言，不走行为断言：短码空间是 32^10，填不满，而 Crypto 生成的
	# id 无法预知，没有办法确定性地造出"每次都撞"。能验的是"循环是有界的"本身 ——
	# 原实现是 while 无界循环，空间占满时服务器会在这里死循环卡住。
	var source := FileAccess.get_file_as_string("res://scripts/multiplayer/RoomService.gd")
	var at := source.find("func make_public_token")
	_h.expect(at >= 0, "public_token_source", "找不到 make_public_token，断言可能已失效")
	if at >= 0:
		var body := source.substr(at, 420)
		_h.expect(body.contains("for _try in PUBLIC_TOKEN_MAX_TRIES"),
			"public_token_unbounded", "make_public_token 必须是有界重试；无界 while 会在短码空间占满时把服务器卡死")
		# 逐行判、且跳过注释行：直接 contains("while ") 会命中函数里那句
		# "原实现是 while 无界循环" 的**注释**，把描述旧 bug 的文字当成 bug 本身。
		var has_while := false
		for raw_line in body.split("
"):
			var line := str(raw_line).strip_edges()
			if line.begins_with("#"):
				continue
			if line.begins_with("while "):
				has_while = true
		_h.expect(not has_while,
			"public_token_while", "make_public_token 里出现了 while 语句 —— 无界循环正是这里修掉的问题")


# --- 席位元数据 ---------------------------------------------------------------

func _check_seat_move_carries_everything() -> void:
	var svc := _make_service()
	var room: Dictionary = svc.new_room()
	var token := "tok_move"
	room.seat_tokens = {0: token}
	room.seat_public_id = {0: "PUBLIC0000"}
	room.join_seq = {0: 3}
	room.reserved = {0: {"reserved_at": _now}}
	room.reserve_deadline = {0: _now + 60.0}
	room.owned_treasures = {0: ["treasure_a"]}
	room.altar_uses = {0: 2}
	room.tx_log = {0: ["receipt"]}
	room.prep = {0: {"gold": 7}}
	var gold: Array = room.get("slot_gold", [])
	gold[0] = 42
	room.slot_gold = gold
	svc.token_seat[token] = {"room_id": int(room.id), "slot": 0}

	svc.move_seat_metadata(room, 0, 4)

	for map_name in RoomServiceScript.SEAT_SLOT_MAPS:
		var m: Dictionary = room.get(map_name, {})
		if m.is_empty():
			continue
		_h.expect(not m.has(0), "seat_move_leftover",
			"%s 换位后旧槽位仍有残留 —— 后来坐进这个位子的人会继承前一个人的身份或进度" % map_name)
		_h.expect(m.has(4), "seat_move_missing", "%s 换位后没搬到新槽位" % map_name)

	_h.expect(int((room.get("slot_gold", []) as Array)[4]) == 42,
		"seat_move_gold", "每席位金币没跟着换位搬（它按数组索引存，不在 SEAT_SLOT_MAPS 里）")

	# 反向索引：漏改的话这人重连会被放回旧槽位，队伍和身份色一起变回去；
	# 旧槽位要是已经有人坐了，resume 直接判 seat_taken 连不回来。
	var seat: Dictionary = svc.token_seat.get(token, {})
	_h.expect(int(seat.get("slot", -1)) == 4,
		"seat_move_reverse_index", "token -> seat 的反向索引没跟着改，重连会回到旧槽位")


func _check_seat_clear_releases_token() -> void:
	var svc := _make_service()
	var room: Dictionary = svc.new_room()
	var token := "tok_clear"
	room.seat_tokens = {2: token}
	room.owned_treasures = {2: ["t"]}
	svc.token_seat[token] = {"room_id": int(room.id), "slot": 2}
	var gold: Array = room.get("slot_gold", [])
	gold[2] = 99
	room.slot_gold = gold

	svc.clear_seat_metadata(room, 2)

	_h.expect(not svc.token_seat.has(token),
		"seat_clear_token", "永久释放座位后 token -> seat 映射应当删除，否则旧 token 还能重连进来")
	for map_name in RoomServiceScript.SEAT_SLOT_MAPS:
		_h.expect(not (room.get(map_name, {}) as Dictionary).has(2),
			"seat_clear_leftover", "%s 在座位释放后仍有残留" % map_name)
	_h.expect(int((room.get("slot_gold", []) as Array)[2]) == GameState.START_GOLD,
		"seat_clear_gold", "座位释放后金币应重置为初始值")


# compare-and-delete：只有当映射仍指向本座位的 token 时才删。
# 无条件删会在短码碰撞时，让先离开的人把后来者的映射一起删掉 —— 拿一个泄漏换串号。
func _check_public_id_release_is_compare_and_delete() -> void:
	var svc := _make_service()
	var room: Dictionary = svc.new_room()
	var shared_id := "COLLIDE001"

	# 情形一：映射仍指向本座位 -> 应当删除
	room.seat_tokens = {0: "tok_a"}
	room.seat_public_id = {0: shared_id}
	svc.public_token_seat[shared_id] = "tok_a"
	svc.release_seat_public_id(room, 0)
	_h.expect(not svc.public_token_seat.has(shared_id),
		"public_id_not_released", "短码仍指向本座位时应当释放，否则条目只增不减")

	# 情形二：同一短码已被另一个座位重新绑定 -> 本座位离开时**不能**删
	room.seat_tokens = {1: "tok_old"}
	room.seat_public_id = {1: shared_id}
	svc.public_token_seat[shared_id] = "tok_newcomer"
	svc.release_seat_public_id(room, 1)
	_h.expect(str(svc.public_token_seat.get(shared_id, "")) == "tok_newcomer",
		"public_id_stole_newcomer", "短码已被后来者绑定，先离开的人不得删掉它 —— 那会造成串号")
	_h.expect(not (room.get("seat_public_id", {}) as Dictionary).has(1),
		"public_id_seat_entry", "座位自己的 seat_public_id 条目仍应清掉")


# --- 房间查询 -----------------------------------------------------------------

func _check_slot_queries() -> void:
	var svc := _make_service()
	var room: Dictionary = svc.new_room()
	_h.expect(svc.room_next_free_slot(room) == 0, "free_slot_empty", "全空房间的首个空位应是 0")
	room.slot_states = ["player", "player", "empty", "dummy", "empty", "empty"]
	_h.expect(svc.room_next_free_slot(room) == 2, "free_slot_skip", "应跳过 player/dummy 返回首个 empty")
	_h.expect(svc.room_player_count(room) == 2, "player_count", "只数 player，不数 dummy/empty")
	room.slot_states = ["player", "player", "player", "player", "player", "player"]
	_h.expect(svc.room_next_free_slot(room) == -1, "free_slot_full", "满房应返回 -1")


func _check_find_or_create() -> void:
	var svc := _make_service()
	var first: Dictionary = svc.new_room()
	var found: Dictionary = svc.find_or_create_room()
	_h.expect(int(found.get("id", -1)) == int(first.get("id", 0)),
		"find_reuse", "有空位的 lobby 房间应被复用，而不是每次新建")

	first.slot_states = ["player", "player", "player", "player", "player", "player"]
	var made: Dictionary = svc.find_or_create_room()
	_h.expect(int(made.get("id", -1)) != int(first.get("id", 0)),
		"find_create_when_full", "满房时应新建房间")

	made.state = "prep"
	first.slot_states = ["empty", "empty", "empty", "empty", "empty", "empty"]
	var back: Dictionary = svc.find_or_create_room()
	_h.expect(str(back.get("state", "")) == "lobby",
		"find_only_lobby", "只应复用 lobby 阶段的房间")


func _check_dirty_and_state_transitions() -> void:
	var svc := _make_service()
	var room: Dictionary = svc.new_room()
	svc.rooms_dirty = false
	svc.touch_room(room)
	_h.expect(svc.rooms_dirty, "touch_not_dirty", "touch_room 应置脏 —— 它是房间变更的主要汇聚口")
	_h.expect(is_equal_approx(float(room.get("last_activity_at", 0.0)), _now),
		"touch_time", "touch_room 应写入注入时钟的当前值")

	svc.rooms_dirty = false
	var before := float(room.get("state_started_at", 0.0))
	svc.set_room_state(room, str(room.get("state", "")))
	_h.expect(not svc.rooms_dirty, "state_noop_dirty", "阶段没变时不应置脏")
	_h.expect(is_equal_approx(float(room.get("state_started_at", 0.0)), before),
		"state_noop_time", "阶段没变时不应重置 state_started_at")

	_now += 50.0
	svc.set_room_state(room, "prep")
	_h.expect(svc.rooms_dirty, "state_change_dirty", "阶段切换必须置脏，否则重启后房间停在旧阶段")
	_h.expect(is_equal_approx(float(room.get("state_started_at", 0.0)), _now),
		"state_change_time", "阶段切换应重置 state_started_at")


func _check_public_room_list_filters() -> void:
	var svc := _make_service()
	var open_room: Dictionary = svc.new_room()
	var busy: Dictionary = svc.new_room()
	busy.state = "prep"
	var full: Dictionary = svc.new_room()
	full.slot_states = ["player", "player", "player", "player", "player", "player"]
	var suspended: Dictionary = svc.new_room()
	suspended.suspended = true

	var listed: Array = svc.public_room_list()
	var ids := []
	for entry in listed:
		ids.append(int((entry as Dictionary).get("id", 0)))
	_h.expect(ids.has(int(open_room.id)), "list_missing_open", "有空位的 lobby 房间应出现在公开列表")
	_h.expect(not ids.has(int(busy.id)), "list_has_busy", "非 lobby 阶段的房间不该进公开列表")
	_h.expect(not ids.has(int(full.id)), "list_has_full", "满房不该进公开列表")
	_h.expect(not ids.has(int(suspended.id)), "list_has_suspended",
		"suspended 房间正在等原班人马回来，不该被路人加入")

	var sorted_ids := ids.duplicate()
	sorted_ids.sort()
	_h.expect(ids == sorted_ids, "list_unsorted", "公开列表应按房间号排序")


func _check_counts() -> void:
	var svc := _make_service()
	var room: Dictionary = svc.new_room()
	var rid := int(room.id)
	room.peer_slot = {101: 0, 102: 1, 103: 2}
	svc.peer_room[101] = rid
	svc.peer_room[102] = rid
	svc.peer_room[103] = 999999      # 已经不在本房了
	_h.expect(svc.room_online_count(room) == 2,
		"online_count", "只应数 peer_room 仍指向本房的 peer")

	room.seat_tokens = {0: "t0", 1: "t1", 2: "t2"}
	svc.token_seat["t0"] = {"room_id": rid, "slot": 0}
	svc.token_seat["t1"] = {"room_id": rid, "slot": 5}   # 槽位对不上
	_h.expect(svc.room_live_token_count(room) == 1,
		"live_token_count", "房间号与槽位都对得上才算有效 token")

	_h.expect(int(svc.room_for_peer(101).get("id", 0)) == rid,
		"room_for_peer", "room_for_peer 应按 peer_room 反查")
	_h.expect(svc.room_for_peer(404).is_empty(),
		"room_for_peer_unknown", "未知 peer 应返回空字典而不是报错")


func _check_injected_clock_is_used() -> void:
	var svc := _make_service()
	_now = 4242.0
	var room: Dictionary = svc.new_room()
	_h.expect(is_equal_approx(float(room.get("created_at", 0.0)), 4242.0),
		"clock_not_injected", "时钟没走注入的 now_fn —— 这会让所有时间相关断言无法确定性验证")
	_now = 1000.0
# --- 生命周期（第 4 步搬进来的策略）------------------------------------------

# cleanup_rooms 是 62 行策略，搬进来时回归网里没有一个用例驱动过它。
# 这里按"零在线真人时依据还有没有有效 token 决定去留"（B11）逐条钉住。
func _check_cleanup_policy() -> void:
	var closed: Array[Dictionary] = []
	var next_prep: Array[int] = []
	var close_fn := func(room: Dictionary, reason: String) -> void:
		closed.append({"id": int(room.get("id", 0)), "reason": reason})
		room.state = "closed"
	var prep_fn := func(room: Dictionary) -> void:
		next_prep.append(int(room.get("id", 0)))

	# ① 零在线、零有效 token -> 立刻关，不等任何 TTL
	var svc := _make_service()
	var a: Dictionary = svc.new_room()
	a.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
	a.empty_since = _now
	svc.cleanup_rooms(close_fn, prep_fn)
	_h.expect(closed.size() == 1 and str(closed[0].reason) == "empty_no_tokens",
		"cleanup_no_tokens", "零在线且无有效 token 时应立刻关房，实际 %s" % str(closed))
	_h.expect(not svc.rooms.has(int(a.id)), "cleanup_not_deleted", "关掉的房间应从 rooms 里删除")

	# ② 零在线但仍有有效 token、且在 300 秒窗口内 -> 转 suspended，不关
	closed.clear()
	var svc2 := _make_service()
	var b: Dictionary = svc2.new_room()
	b.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
	b.seat_tokens = {0: "live_tok"}
	svc2.token_seat["live_tok"] = {"room_id": int(b.id), "slot": 0}
	b.empty_since = _now
	svc2.cleanup_rooms(close_fn, prep_fn)
	_h.expect(closed.is_empty(), "cleanup_closed_recoverable",
		"恢复窗口内且仍有有效 token 的房间不该关，实际 %s" % str(closed))
	_h.expect(bool(b.get("suspended", false)), "cleanup_not_suspended",
		"恢复窗口内应转 suspended —— 否则空房会继续推进阶段、跑 AI 对局烧 CPU（R2）")

	# ③ 超过 300 秒窗口 -> 即使还有 token 也关
	closed.clear()
	_now += 400.0
	svc2.cleanup_rooms(close_fn, prep_fn)
	_h.expect(closed.size() == 1 and str(closed[0].reason) == "suspend_expired",
		"cleanup_suspend_expired", "过了恢复窗口应以 suspend_expired 关房，实际 %s" % str(closed))
	_now -= 400.0

	# ④ suspended 房间不参与阶段推进：结算超时也不该推进下一备战
	closed.clear()
	next_prep.clear()
	var svc3 := _make_service()
	var c: Dictionary = svc3.new_room()
	c.state = "result"
	c.suspended = true
	c.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
	c.seat_tokens = {0: "tok_c"}
	svc3.token_seat["tok_c"] = {"room_id": int(c.id), "slot": 0}
	c.empty_since = _now
	c.state_started_at = _now - 9999.0
	svc3.cleanup_rooms(close_fn, prep_fn)
	_h.expect(next_prep.is_empty(), "cleanup_suspended_advanced",
		"suspended 房间不得推进阶段，实际推进了 %s" % str(next_prep))

	# ⑤ 有人在线时：清掉 empty_since 并解除 suspended
	var svc4 := _make_service()
	var d: Dictionary = svc4.new_room()
	var rid := int(d.id)
	d.peer_slot = {900: 0}
	svc4.peer_room[900] = rid
	d.suspended = true
	d.empty_since = _now - 10.0
	svc4.cleanup_rooms(close_fn, prep_fn)
	_h.expect(not bool(d.get("suspended", false)), "cleanup_not_resumed", "有人在线时应解除 suspended")
	_h.expect(is_equal_approx(float(d.get("empty_since", -1.0)), 0.0),
		"cleanup_empty_since", "有人在线时应清掉 empty_since")

	# ⑥ 备战超时 -> 关房
	closed.clear()
	var svc5 := _make_service()
	var e: Dictionary = svc5.new_room()
	e.state = "prep"
	e.peer_slot = {901: 0}
	svc5.peer_room[901] = int(e.id)
	e.state_started_at = _now - 1801.0
	svc5.cleanup_rooms(close_fn, prep_fn)
	_h.expect(closed.size() == 1 and str(closed[0].reason) == "prep_timeout",
		"cleanup_prep_timeout", "备战超时应关房，实际 %s" % str(closed))

	# ⑦ 结算超时且对局未结束 -> 推进下一备战而不是关房
	closed.clear()
	next_prep.clear()
	var svc6 := _make_service()
	var f: Dictionary = svc6.new_room()
	f.state = "result"
	f.peer_slot = {902: 0}
	svc6.peer_room[902] = int(f.id)
	f.state_started_at = _now - 601.0
	svc6.cleanup_rooms(close_fn, prep_fn)
	_h.expect(next_prep.size() == 1 and closed.is_empty(),
		"cleanup_result_next_prep", "对局未结束时结算超时应推进下一备战，实际 closed=%s prep=%s" % [str(closed), str(next_prep)])


# 预留座位到期的覆盖不在这里 —— 见 tools/reconnect_service_check.gd 的
# _check_expiry_and_takeover / _check_suspended_room_is_skipped。
#
# 这里原本有一份同名测试，调用 RoomService.tick_reserved_seats(auto_fn)。那个方法
# 在 RoomService 上从来不存在：D1 第 4 刀把扫描策略搬到了 ReconnectService，签名也
# 变成 tick_reserved_seats(rooms, takeover_fn) 两个参数。于是那段测试每次都在
# "Nonexistent function" 上中止 —— 而 GDScript 的报错只中止当前函数，_run() 照常
# 往下走，CheckHarness 最后照样打印 status=PASS checked=132。也就是说它一直是绿的，
# 一次都没执行过。2026-08-28 由 tools/run_check.ps1 的引擎级错误检测首次发现。
#
# 删掉而不是搬过去，是因为 reconnect_service_check 已经把这四条（到期转 AI、
# 截止清除、未到期保留、suspended 跳过）测全了，还多测了"时间推进后第二个座位到期"。
#
# 附带一条线索：NetworkService.gd 里那句注释写着"扫描策略已搬到
# RoomService.tick_reserved_seats()"，但下一行调用的是 _reconnect_service。
# 注释指错了类，多半就是这段测试当初写错接收者的原因。那是产品代码，本轮未改。
