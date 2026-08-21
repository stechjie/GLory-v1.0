extends Node

# DedicatedServerService 的独立门禁（D1 验收条款：每个子服务有独立 headless 测试）。
#
# 覆盖原始 README 给这个服务定的两件事：**端口 / 持久化**。
#
# 端口那一半以前完全没测过：`_should_boot_dedicated_server` 直接读 OS.get_cmdline_args()，
# 没有 seam，测试没法喂参数。搬进服务时改成 argv 传参的静态函数，才第一次测得到。
#
# 持久化这半的用例是从 tools/room_service_check.gd 搬过来的 —— 实现搬到哪，
# 用例就跟到哪，否则实现换了家、测试还在原地空转。
#
# 这些失败都是**重启后才暴露**的类型：
#   * 快照版本对不上却照读 -> 拿语义已变的存档恢复对局，产生查不出来的错乱
#   * 恢复不清 peer -> 房间以为一堆不存在的 peer 还在线，永远判不空、永远不回收
#   * 时间存绝对值 -> 单调时钟重启归零，所有 TTL 要么立刻到期要么永不到期
#   * 落盘不限速 -> 全量序列化每帧跑在主循环上，自己造一个新的冻结源
#
# 分片号用 12（避开 persist_check 的 7 与 room_service_check 的 11），跑完删干净。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ServerScript := preload("res://scripts/multiplayer/DedicatedServerService.gd")
const RoomServiceScript := preload("res://scripts/multiplayer/RoomService.gd")
const ReconnectServiceScript := preload("res://scripts/multiplayer/ReconnectService.gd")
const CHECK_NAME := "dedicated_server"

const TEST_SHARD := 12

var _h: RefCounted
var _now := 1000.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_should_boot()
	_check_cmdline_int()
	_check_snapshot_path_per_shard()
	_check_snapshot_round_trip()
	_check_snapshot_rejects_foreign_version()
	_check_snapshot_cadence()
	_check_replay_not_persisted()
	_check_resume_resends_replay()
	_cleanup()
	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

func _make() -> Dictionary:
	var tokens: RefCounted = ReconnectServiceScript.new()
	tokens.configure(func() -> float: return _now, func(_m: String) -> void: pass, {})
	var rooms: RefCounted = RoomServiceScript.new()
	rooms.configure(
		func() -> float: return _now,
		func() -> float: return 1700000000.0,
		func(_m: String) -> void: pass,
		func() -> int: return TEST_SHARD,
		{"team_slots": 6, "room_lobby": "lobby", "room_result": "result",
		 "room_closed": "closed", "reserve_grace_sec": 60.0},
		tokens)
	var srv: RefCounted = ServerScript.new()
	srv.configure(rooms, tokens,
		func() -> float: return _now,
		func() -> float: return 1700000000.0,
		func(_m: String) -> void: pass,
		{"team_slots": 6, "room_result": "result", "room_closed": "closed",
		 "reserve_grace_sec": 60.0})
	srv.shard_index = TEST_SHARD
	return {"srv": srv, "rooms": rooms, "tokens": tokens}


func _cleanup() -> void:
	SaveManager.remove_all_variants(_make()["srv"].snapshot_path())


# --- 端口与启动判定 -----------------------------------------------------------

func _check_should_boot() -> void:
	_h.expect(ServerScript.should_boot(PackedStringArray(["--server"])),
		"boot_server_flag", "--server 应判定为专用服务器启动")
	_h.expect(ServerScript.should_boot(PackedStringArray(["--dedicated-server"])),
		"boot_dedicated_flag", "--dedicated-server 应判定为专用服务器启动")
	_h.expect(ServerScript.should_boot(PackedStringArray(["--x", "--server", "--shard=2"])),
		"boot_flag_position", "flag 出现在任何位置都应生效")
	_h.expect(not ServerScript.should_boot(PackedStringArray([])),
		"boot_empty", "没有 flag 时不该以服务器启动")
	_h.expect(not ServerScript.should_boot(PackedStringArray(["--serverish", "--server=1"])),
		"boot_prefix_match", "近似写法不得误判为服务器启动 —— 客户端被当成服务器起来会直接占端口")


func _check_cmdline_int() -> void:
	var argv := PackedStringArray(["--server", "--shard=3", "--port=9001"])
	_h.expect(ServerScript.cmdline_int(argv, "--shard", 0) == 3,
		"cmdline_parse", "--shard=3 应解析出 3")
	_h.expect(ServerScript.cmdline_int(argv, "--port", 0) == 9001,
		"cmdline_parse_port", "--port=9001 应解析出 9001")
	_h.expect(ServerScript.cmdline_int(argv, "--missing", 42) == 42,
		"cmdline_fallback", "缺失的键应返回兜底值")
	_h.expect(ServerScript.cmdline_int(PackedStringArray(["--shard=abc"]), "--shard", 7) == 7,
		"cmdline_bad_int", "非整数值应返回兜底值而不是 0 —— 0 是合法分片号，静默变成 0 会让两个进程抢同一分片")


func _check_snapshot_path_per_shard() -> void:
	var kit := _make()
	kit["srv"].shard_index = 0
	_h.expect(str(kit["srv"].snapshot_path()) == ServerScript.SNAPSHOT_PATH,
		"snapshot_path_shard0", "0 号分片应用不带后缀的路径")
	kit["srv"].shard_index = 5
	_h.expect(str(kit["srv"].snapshot_path()).ends_with(".5"),
		"snapshot_path_sharded", "非 0 分片必须各用各的文件，否则多进程互相覆盖")


# --- 持久化 -------------------------------------------------------------------

func _check_snapshot_round_trip() -> void:
	var kit := _make()
	var srv: RefCounted = kit["srv"]
	SaveManager.remove_all_variants(srv.snapshot_path())

	var room: Dictionary = kit["rooms"].new_room()
	var rid := int(room.id)
	room.state = "prep"
	room.round_index = 7
	room.team_hp = [33, 29]
	room.slot_states = ["player", "player", "empty", "empty", "empty", "empty"]
	room.state_seq = 12
	room.tx_log = {0: ["r1"]}
	room.peer_slot = {555: 0}
	room.boards = {0: {"heavy": "cache"}}
	kit["tokens"].token_seat["tok_snap"] = {"room_id": rid, "slot": 0}
	kit["tokens"].public_token_seat["PUB1234567"] = "tok_snap"
	kit["rooms"].rooms_dirty = true
	srv.save_snapshot()
	_h.expect(not bool(kit["rooms"].rooms_dirty), "snapshot_still_dirty", "落盘成功后应清掉脏标记")

	# 换一个进程该有的样子：全新服务实例、时钟往前跳。
	_now += 500.0
	var fresh := _make()
	fresh["srv"].load_snapshot()

	var back: Dictionary = fresh["rooms"].rooms.get(rid, {})
	if not _h.expect(not back.is_empty(), "snapshot_room_missing", "快照没把房间读回来"):
		return
	_h.expect(int(back.get("round_index", 0)) == 7, "snapshot_round", "round_index 没恢复")
	_h.expect(str(back.get("team_hp", [])) == str([33, 29]), "snapshot_hp", "team_hp 没恢复")
	_h.expect(int(back.get("state_seq", -1)) == 12, "snapshot_state_seq",
		"state_seq 没恢复 —— 重启后从 0 重来，客户端会把新包当迟到包丢掉")
	_h.expect(str((back.get("tx_log", {}) as Dictionary).get(0, [])) == str(["r1"]),
		"snapshot_tx_log", "tx_log 没恢复 —— 客户端重发未回执交易会被执行两次")
	_h.expect((back.get("peer_slot", {}) as Dictionary).is_empty(),
		"snapshot_peer_kept", "恢复后 peer_slot 必须清空")
	_h.expect((back.get("boards", {}) as Dictionary).is_empty(),
		"snapshot_boards_kept", "boards 是缓存类字段，不入快照也不该恢复")

	# 房间是在存盘前一刻建的，所以存进去的"已过去多久"≈0，恢复后 created_at 应≈当前时刻。
	# 松成 "created > 0 且 <= now" 是测不出东西的：存绝对值（1000）时恢复出来是
	# now - 1000 = 500，照样落在那个区间里。证伪时"时间存绝对值却没变红"才发现。
	var created := float(back.get("created_at", -1.0))
	_h.expect(absf(created - _now) < 1.0,
		"snapshot_time_rebase", "时间字段没按新基准重建：created_at=%.1f，期望≈%.1f。存绝对值的话重启后所有 TTL 要么立刻到期要么永不到期" % [created, _now])

	var deadline: Dictionary = back.get("reserve_deadline", {})
	_h.expect(deadline.size() == 2, "snapshot_grace_count",
		"两个 player 座位都该进宽限，实际 %d 个" % deadline.size())
	for slot in deadline.keys():
		var remain := float(deadline[slot]) - _now
		_h.expect(remain > 0.0 and remain <= 60.0 + 1.0,
			"snapshot_grace_window", "宽限窗口没按新基准重建（还剩 %.1f 秒）" % remain)

	_h.expect(fresh["tokens"].token_seat.has("tok_snap"), "snapshot_tokens",
		"token 索引没恢复 —— 重启后没人认得回自己的座位")
	_h.expect(fresh["tokens"].public_token_seat.has("PUB1234567"), "snapshot_public_tokens",
		"短码索引没恢复")


func _check_snapshot_rejects_foreign_version() -> void:
	var kit := _make()
	var srv: RefCounted = kit["srv"]
	SaveManager.remove_all_variants(srv.snapshot_path())
	var payload := {
		"version": ServerScript.SNAPSHOT_VERSION + 99,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"shard": TEST_SHARD,
		"rooms": [{"id": 1234, "state": "prep"}],
		"token_seat": {"ghost": {"room_id": 1234, "slot": 0}},
	}
	SaveManager.atomic_write_bytes(srv.snapshot_path(), var_to_bytes(payload))

	var fresh := _make()
	fresh["srv"].load_snapshot()
	_h.expect(fresh["rooms"].rooms.is_empty(),
		"snapshot_foreign_version_loaded", "版本对不上的快照必须整份丢弃，不得恢复出房间")
	_h.expect(fresh["tokens"].token_seat.is_empty(),
		"snapshot_foreign_tokens_loaded", "版本对不上的快照里的 token 也不得恢复")
	_h.expect(not FileAccess.file_exists(srv.snapshot_path()),
		"snapshot_foreign_kept", "被丢弃的快照应当删除，否则每次启动都要重新发现一遍")


# 全量序列化跑在同步主循环上。无脑每帧写就是给自己造一个新的冻结源
# （和 B4 特效预算同一类问题：不是单次贵，是频率没有上限）。
func _check_snapshot_cadence() -> void:
	var kit := _make()
	var srv: RefCounted = kit["srv"]
	SaveManager.remove_all_variants(srv.snapshot_path())

	# 累加器的语义是"距上次落盘多久"，不是"脏了多久"：空闲很久之后一变脏就会立刻写。
	# 这是搬迁前就有的行为，这里原样保留。第一版测试按"脏了多久"写期望，因此误报了
	# 一次 —— 用例写错比实现写错更难发现，因为它会把正确的实现判成错的。
	kit["rooms"].rooms_dirty = false
	srv.tick_snapshot(ServerScript.SNAPSHOT_INTERVAL_SEC + 1.0)
	_h.expect(not FileAccess.file_exists(srv.snapshot_path()),
		"cadence_wrote_when_clean", "没有变更时不该落盘")

	# 有变更但距上次落盘不够久：不该写。用全新实例，让累加器从 0 起。
	var fresh := _make()
	var srv2: RefCounted = fresh["srv"]
	SaveManager.remove_all_variants(srv2.snapshot_path())
	fresh["rooms"].new_room()
	fresh["rooms"].rooms_dirty = true
	srv2.tick_snapshot(ServerScript.SNAPSHOT_INTERVAL_SEC * 0.1)
	_h.expect(not FileAccess.file_exists(srv2.snapshot_path()),
		"cadence_wrote_too_soon", "有变更但距上次落盘不够久时不该写 —— 限速正是这个函数存在的理由")

	# 攒够了：写，并清脏标记
	srv = srv2
	kit = fresh
	srv.tick_snapshot(ServerScript.SNAPSHOT_INTERVAL_SEC)
	_h.expect(FileAccess.file_exists(srv.snapshot_path()),
		"cadence_never_wrote", "有变更且攒够间隔后必须落盘")
	_h.expect(not bool(kit["rooms"].rooms_dirty),
		"cadence_still_dirty", "落盘后应清掉脏标记，否则下次又会白写一遍")


# --- 接线：重连补回放 ---------------------------------------------------------
#
# 已确认的产品规则：**重连回来的人应该补看那一场的回放**。
# 在这之前 _resume_seat 只补发 match_state，注释写的是"客户端直接跳过战斗"——
# 那是有意的，但产品上不对：掉线重连的人会直接看到结果，中间那场战斗没了。
#
# 这一条只能做成源码级断言：_resume_seat 要 multiplayer（真 peer、真房间），
# RefCounted 的检查进程里够不着。真正的行为验证是双设备实测（战斗中断网再连回）。
# 所以这里的目标不是"证明它работает"，而是**挡住它被人顺手删掉**。
#
# 关键：断言必须限定在 _resume_seat 的函数体内。直接全文 contains
# "_send_replay_to_peer" 会命中它自己的定义，那样即使 resume 里根本没调用也照样绿——
# 这个坑在 BattleScreen 的 _spawn_actors_for_tick 上踩过一次，代价是一次假绿。
func _check_resume_resends_replay() -> void:
	var body := _function_body("res://scripts/autoload/NetworkService.gd", "func _resume_seat")
	_h.expect(not body.is_empty(), "resume_body_missing",
		"读不到 _resume_seat 的函数体 —— 断言可能已失效（函数被改名？）")
	_h.expect(body.contains("_send_replay_to_peer("),
		"resume_no_replay", "_resume_seat 必须补发回放，否则重连回来的人会直接跳到结算")
	_h.expect(body.contains("replay_packed"),
		"resume_no_kept_replay", "_resume_seat 应从 room.replay_packed 取那一场留存的回放")
	# 顺序：match_state 必须排在 replay 之前。反过来时权威结算被压在大包后面，
	# 玩家卡在"战斗打完但结算不来"——这正是广播路径上那条注释记的教训。
	var i_ms := body.find("_rpc_receive_match_state")
	var i_rp := body.find("_send_replay_to_peer(")
	_h.expect(i_ms >= 0 and i_rp > i_ms,
		"resume_order", "match_state 必须排在 replay 之前（几百字节的权威结算不该被大包压住）")


# 服务端留存的回放**不得进快照**。
#
# 快照是每 5 秒全量序列化写盘的，而回放两份约 196 KB —— 塞进去就是给自己造一个新的
# 冻结源（DedicatedServerService 的白名单注释里对 boards/last_board 写的是同一件事）。
# 代价已知且接受：服务器重启后那一场的回放没了，重连者只能看到结算结果。
func _check_replay_not_persisted() -> void:
	var fields: Array = ServerScript.PERSISTED_ROOM_FIELDS
	_h.expect(not fields.has("replay_packed"),
		"replay_persisted", "replay_packed 不得进快照白名单 —— 每 5 秒全量写盘 196 KB 是新的冻结源")
	# 顺带钉住既有的两个缓存字段，理由完全一样。它们此前只有注释在说，没有断言在管。
	_h.expect(not fields.has("boards") and not fields.has("last_board"),
		"cache_persisted", "boards/last_board 是缓存类字段，同样不得进快照")


# 取一个函数的函数体：从 `func 名字` 那行开始，到**下一个顶格非空行**为止。
#
# 边界用"顶格非空行"而不是"下一个 func/@rpc"：后者会把函数末尾的注释和紧跟的
# const 一起吃进来（在 NetworkService 上实测踩过，body_range 多吃了一个 const）。
func _function_body(path: String, signature: String) -> String:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		return ""
	var lines := source.split("\n")
	var out: Array[String] = []
	var inside := false
	for raw in lines:
		var line := str(raw)
		if not inside:
			if line.begins_with(signature):
				inside = true
				out.append(line)
			continue
		# 顶格且非空 = 函数体结束（GDScript 的函数体一定是缩进的）
		if not line.is_empty() and not line.begins_with("\t") and not line.begins_with(" "):
			break
		out.append(line)
	return "\n".join(out)
