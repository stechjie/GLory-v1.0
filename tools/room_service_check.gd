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
# 分片号用 11，且跑完删干净。判定依赖磁盘状态的检查必须自己管好磁盘，否则它是
# 顺序相关的 —— tools/multiplayer_regression.sh 里对 persist_check 有同样的处理。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RoomServiceScript := preload("res://scripts/multiplayer/RoomService.gd")
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
	_check_snapshot_round_trip()
	_check_snapshot_rejects_foreign_version()

	_cleanup_snapshot()
	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

func _make_service() -> RefCounted:
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
		})
	return svc


func _cleanup_snapshot() -> void:
	var svc := _make_service()
	SaveManager.remove_all_variants(svc.snapshot_path())


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


# --- 快照往返 -----------------------------------------------------------------

func _check_snapshot_round_trip() -> void:
	var svc := _make_service()
	SaveManager.remove_all_variants(svc.snapshot_path())

	var room: Dictionary = svc.new_room()
	var rid := int(room.id)
	room.state = "prep"
	room.round_index = 7
	room.team_hp = [33, 29]
	room.slot_states = ["player", "player", "empty", "empty", "empty", "empty"]
	room.state_seq = 12
	room.tx_log = {0: ["r1"]}
	room.peer_slot = {555: 0}
	room.boards = {0: {"heavy": "cache"}}
	svc.token_seat["tok_snap"] = {"room_id": rid, "slot": 0}
	svc.public_token_seat["PUB1234567"] = "tok_snap"
	svc.rooms_dirty = true
	svc.save_snapshot()
	_h.expect(not svc.rooms_dirty, "snapshot_still_dirty", "落盘成功后应清掉脏标记")

	# 换一个进程该有的样子：新服务实例、时钟往前跳。
	_now += 500.0
	var restored := _make_service()
	restored.load_snapshot()

	var back: Dictionary = restored.rooms.get(rid, {})
	if not _h.expect(not back.is_empty(), "snapshot_room_missing", "快照没把房间读回来"):
		return
	_h.expect(int(back.get("round_index", 0)) == 7, "snapshot_round", "round_index 没恢复")
	_h.expect(str(back.get("team_hp", [])) == str([33, 29]), "snapshot_hp", "team_hp 没恢复")
	_h.expect(int(back.get("state_seq", -1)) == 12, "snapshot_state_seq",
		"state_seq 没恢复 —— 重启后从 0 重来，客户端会把新包当迟到包丢掉")
	_h.expect(str((back.get("tx_log", {}) as Dictionary).get(0, [])) == str(["r1"]),
		"snapshot_tx_log", "tx_log 没恢复 —— 客户端重发未回执交易会被执行两次")

	# peer 状态一律清空：留着会让房间以为不存在的 peer 还在线，永远判不空、永远不回收。
	_h.expect((back.get("peer_slot", {}) as Dictionary).is_empty(),
		"snapshot_peer_kept", "恢复后 peer_slot 必须清空")
	_h.expect((back.get("boards", {}) as Dictionary).is_empty(),
		"snapshot_boards_kept", "boards 是缓存类字段，不入快照也不该恢复")

	# 时间基准重建：存的是相对量，读回来要用新的单调基准。
	var created := float(back.get("created_at", -1.0))
	_h.expect(created > 0.0 and created <= _now,
		"snapshot_time_rebase", "时间字段没按新基准重建（created_at=%f now=%f）" % [created, _now])

	# 每个占着的座位都当成刚掉线，给一份完整宽限。
	var deadline: Dictionary = back.get("reserve_deadline", {})
	_h.expect(deadline.size() == 2, "snapshot_grace_count",
		"两个 player 座位都该进宽限，实际 %d 个" % deadline.size())
	for slot in deadline.keys():
		var remain := float(deadline[slot]) - _now
		_h.expect(remain > 0.0 and remain <= 60.0 + 1.0,
			"snapshot_grace_window", "宽限窗口没按新基准重建（还剩 %.1f 秒）" % remain)

	_h.expect(restored.token_seat.has("tok_snap"), "snapshot_tokens", "token_seat 没恢复")
	_h.expect(restored.public_token_seat.has("PUB1234567"), "snapshot_public_tokens",
		"public_token_seat 没恢复")


# 版本或协议对不上就整份丢弃：宁可全场重开，也不能用语义可能已变的存档恢复对局。
func _check_snapshot_rejects_foreign_version() -> void:
	var svc := _make_service()
	SaveManager.remove_all_variants(svc.snapshot_path())
	var payload := {
		"version": RoomServiceScript.SNAPSHOT_VERSION + 99,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"shard": TEST_SHARD,
		"rooms": [{"id": 1234, "state": "prep"}],
		"token_seat": {"ghost": {"room_id": 1234, "slot": 0}},
	}
	SaveManager.atomic_write_bytes(svc.snapshot_path(), var_to_bytes(payload))

	var loader := _make_service()
	loader.load_snapshot()
	_h.expect(loader.rooms.is_empty(),
		"snapshot_foreign_version_loaded", "版本对不上的快照必须整份丢弃，不得恢复出房间")
	_h.expect(loader.token_seat.is_empty(),
		"snapshot_foreign_tokens_loaded", "版本对不上的快照里的 token 也不得恢复")
	_h.expect(not FileAccess.file_exists(svc.snapshot_path()),
		"snapshot_foreign_kept", "被丢弃的快照应当删除，否则每次启动都要重新发现一遍")
