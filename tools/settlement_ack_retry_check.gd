extends Node
# 结算确认的双向重试（10.01 反馈第 8 条）。
#
# 症状：真实玩家 3v3 自定义对战里六个人都进了「等待其他玩家」，却几分钟不进备战。
# 机制：结算确认是**单向、一次性**的 —— 服务端等「在线真人全部 ACK」，而客户端
# 那条 ACK 只发一次；客户端 4 个静默 return、服务端 6 个静默丢弃，任一条命中就
# 多出一个「在线但永不确认」的座位，全房只能等满 result_ack_deadline
# （最短 78s、带回放 206~480s）。
#
# 本检查盯三件事：
#   A/B/C 服务端 —— 每拍把结算重推给还没确认的在线真人（幂等）。
#   D     客户端 —— 等待期间周期性重发 ACK，且**不许**自己抢跑推进。
#   E     判别力 —— 三个输入各做一次正反对照，证明 A 段不是恒真断言。
#
# 为什么服务端那半抽成 static 纯函数 + 一个可覆写的小缝：发 RPC 要碰 multiplayer，
# 门禁里指不到真的对端。把「该推给谁」抽纯、把「推一次」留成缝，就能把每种座位
# 组合都验一遍，而不是靠"看着像对的"。
const H := preload("res://tools/CheckHarness.gd")
var h := H.new("settlement_ack_retry")

const NET_SRC := "res://scripts/autoload/NetworkService.gd"
const MAIN_SRC := "res://scenes/main/Main.gd"

const BATTLE_ID := "900001:4:7"
const OLD_BATTLE_ID := "900001:3:6"


# 脱树实例：覆写时钟、RPC 发送缝、在线名单、日志与推进，其余全走生产实现。
class NudgeProbe extends "res://scripts/autoload/NetworkService.gd":
	var sent_peers: Array = []
	var sent_slots: Array = []
	var advanced: Array[int] = []
	var online: Array = []
	var clock := 1000.0

	func _now() -> float:
		return clock

	func _resend_result_state(peer_id: int, ms: Dictionary) -> void:
		sent_peers.append(peer_id)
		sent_slots.append(int(ms.get("slot", -1)))

	func _peer_connected(peer_id: int) -> bool:
		return online.has(peer_id)

	func _touch_room(_room: Dictionary) -> void:
		pass

	func _net_log(_message: String) -> void:
		pass

	func _room_begin_next_prep(room: Dictionary) -> void:
		advanced.append(int(room.id))
		room.state = "prep"


# 六人房：座位 0..5 全是真人，peer 11..16 各占一座。
func room_fixture() -> Dictionary:
	var ms := {}
	for i in 6:
		ms[i] = {"completed_round": 4, "slot": i, "battle_id": BATTLE_ID}
	return {
		"id": 900001,
		"battle_id": BATTLE_ID,
		"state": "result",
		"slot_states": ["player", "player", "player", "player", "player", "player"],
		"peer_slot": {11: 0, 12: 1, 13: 2, 14: 3, 15: 4, 16: 5},
		"result_acks": {},
		"last_match_state": ms,
		"state_started_at": 1000.0,
		"result_ack_deadline": 1300.0,
		"result_ack_window_sec": 300.0,
		"result_ack_hard_deadline": 1480.0,
	}


func all_online() -> Array:
	return [11, 12, 13, 14, 15, 16]


func pending(room: Dictionary, online: Array) -> Array:
	return NetworkService.result_ack_pending_peers(room, online)


func _ready() -> void:
	NetworkService.set_process(false)
	# 前置体检：整套判据都建立在「六人房、六个真人座位」上，TEAM_SLOTS 或阶段名
	# 一变下面的下标就全错 —— 先量出来，别让断言静默走错分支。
	h.expect(NetworkService.TEAM_SLOTS == 6, "team_slots_is_6", "Six seats are the fixture contract")
	h.expect(NetworkService.ROOM_RESULT == "result", "result_phase_name", "Room phase constant unchanged")
	_section_a()
	_section_b()
	_section_c()
	_section_d()
	_section_e()
	h.finish(get_tree())


# ── A. 纯判据：该推给谁 ─────────────────────────────────────────────────────

func _section_a() -> void:
	var room := room_fixture()
	h.expect(str(pending(room, all_online())) == str([11, 12, 13, 14, 15, 16]),
		"a1_none_acked_all_six", "Every online human is pending before any ACK")

	room = room_fixture()
	room.result_acks = {0: BATTLE_ID}
	var p := pending(room, all_online())
	h.expect(p.size() == 5 and not p.has(11), "a2_acked_seat_dropped", "A seat that confirmed this battle is not nudged")

	room = room_fixture()
	for i in 6:
		room.result_acks[i] = BATTLE_ID
	h.expect(pending(room, all_online()).is_empty(), "a3_all_acked_empty", "Nothing left to nudge once everyone confirmed")

	# 掉线：不在在线名单里的人不催（产品规则：不等掉线者；且往断开的 peer 发
	# RPC 会刷 unknown peer ID）。
	room = room_fixture()
	var off := pending(room, [11, 13, 14, 15, 16])
	h.expect(not off.has(12), "a4_offline_skipped", "Offline seat is never nudged")
	h.expect(off.size() == 5, "a4b_offline_others_still_pending", "Dropping one peer leaves the other five pending")

	# AI / 空席：服务器代过，永远不需要确认。
	room = room_fixture()
	room.slot_states[2] = "dummy"
	h.expect(not pending(room, all_online()).has(13), "a5_dummy_seat_skipped", "AI seat needs no confirmation")
	room = room_fixture()
	room.slot_states[2] = "empty"
	h.expect(not pending(room, all_online()).has(13), "a5b_empty_seat_skipped", "Empty seat needs no confirmation")

	# 结果还没算出来（模拟在排队/计算中）：没有东西可推 —— 推空字典会把客户端的
	# latest_match_state 覆盖成空壳。
	room = room_fixture()
	room.last_match_state = {}
	h.expect(pending(room, all_online()).is_empty(), "a6_unpublished_result_nothing", "Queued simulation has nothing to push")

	room = room_fixture()
	room.battle_id = ""
	h.expect(pending(room, all_online()).is_empty(), "a7_no_battle_id_nothing", "No battle identity means no settlement to nudge")

	# ★ ACK 是**上一场**的，不能当成"这个座位确认过了"。
	room = room_fixture()
	room.result_acks = {0: OLD_BATTLE_ID}
	h.expect(pending(room, all_online()).has(11), "a8_stale_ack_still_pending", "Last round's ACK does not confirm this round")

	room = room_fixture()
	room.peer_slot = {11: -1, 12: 6, 13: 2}
	var bad := pending(room, all_online())
	h.expect(not bad.has(11) and not bad.has(12) and bad == [13], "a9_illegal_slot_skipped", "Out-of-range seat numbers are ignored")

	room = room_fixture()
	room.last_match_state.erase(2)
	h.expect(not pending(room, all_online()).has(13), "a10_missing_payload_skipped", "A seat with no settlement payload cannot be nudged")

	# ★ 与 _room_result_acks_complete 同源对照：全在线时「没有待催的人」必须等价于
	#   「可以推进了」。两条判据一旦分叉，就会出现「催到没人可催、却还是推进不了」
	#   的活锁 —— 那正是本轮要消灭的那类 bug。
	var cases: Array = []
	var r0 := room_fixture()
	cases.append(r0)
	var r1 := room_fixture()
	r1.result_acks = {0: BATTLE_ID, 3: BATTLE_ID}
	cases.append(r1)
	var r2 := room_fixture()
	for i in 6:
		r2.result_acks[i] = BATTLE_ID
	cases.append(r2)
	var r3 := room_fixture()
	r3.result_acks = {0: OLD_BATTLE_ID}
	cases.append(r3)
	var same_source := true
	var probe := NudgeProbe.new()
	for case_room in cases:
		if bool(probe._room_result_acks_complete(case_room)) != pending(case_room, all_online()).is_empty():
			same_source = false
	h.expect(same_source, "a11_same_predicate_as_acks_complete", "Nudge predicate and advance predicate agree on every fixture")
	probe.free()


# ── B. 行为：真推几次、推给谁、间隔 ──────────────────────────────────────────

func _section_b() -> void:
	var probe := NudgeProbe.new()
	probe.online = all_online()
	probe.clock = 1000.0

	# 六人在线，只有座位 4（peer 15）没确认。
	var room := room_fixture()
	room.result_acks = {0: BATTLE_ID, 1: BATTLE_ID, 2: BATTLE_ID, 3: BATTLE_ID, 5: BATTLE_ID}
	probe._room_nudge_result_ack(room, probe.clock)
	h.expect(str(probe.sent_peers) == str([15]), "b1_nudges_only_missing_seat", "Only the unconfirmed seat is re-sent")
	h.expect(str(probe.sent_slots) == str([4]), "b1b_payload_is_that_seat", "The payload re-sent is that seat's own settlement")
	h.expect(is_equal_approx(float(room.get("result_ack_nudge_at", 0.0)), probe.clock),
		"b4_nudge_stamp_written", "Nudge time is stamped so maintenance does not spam every tick")

	probe._room_nudge_result_ack(room, probe.clock)
	h.expect(probe.sent_peers.size() == 1, "b2_interval_blocks_repeat", "Same instant cannot nudge twice")

	probe.clock += float(NetworkService.RESULT_ACK_NUDGE_SEC)
	probe._room_nudge_result_ack(room, probe.clock)
	h.expect(probe.sent_peers.size() == 2, "b3_nudges_again_after_interval", "Nudge resumes after the interval")

	# 全部确认：不推、也不刷新时间戳（否则一个安静的房每 10 秒白写一次盘）。
	var quiet := room_fixture()
	for i in 6:
		quiet.result_acks[i] = BATTLE_ID
	var before := probe.sent_peers.size()
	probe._room_nudge_result_ack(quiet, probe.clock)
	h.expect(probe.sent_peers.size() == before, "b5_no_nudge_when_complete", "A fully confirmed room is left alone")
	h.expect(not quiet.has("result_ack_nudge_at"), "b5b_no_stamp_when_complete", "No timestamp churn on a quiet room")

	# 掉线的座位不推 —— 即使它也没确认。
	var off := NudgeProbe.new()
	off.online = [11, 12, 13, 14, 16]
	off.clock = 1000.0
	var room2 := room_fixture()
	room2.result_acks = {0: BATTLE_ID, 1: BATTLE_ID, 2: BATTLE_ID, 3: BATTLE_ID, 5: BATTLE_ID}
	off._room_nudge_result_ack(room2, off.clock)
	h.expect(off.sent_peers.is_empty(), "b6_offline_seat_not_nudged", "Never send an RPC to a peer already gone")
	off.free()

	# 结果未发布：不推。
	var un := NudgeProbe.new()
	un.online = all_online()
	un.clock = 1000.0
	var room3 := room_fixture()
	room3.last_match_state = {}
	un._room_nudge_result_ack(room3, un.clock)
	h.expect(un.sent_peers.is_empty(), "b7_unpublished_not_nudged", "No settlement exists yet, so nothing is re-sent")
	un.free()

	# 两个座位都没确认：一次推两个，且不重复。
	var two := NudgeProbe.new()
	two.online = all_online()
	two.clock = 1000.0
	var room4 := room_fixture()
	room4.result_acks = {0: BATTLE_ID, 1: BATTLE_ID, 2: BATTLE_ID, 3: BATTLE_ID}
	two._room_nudge_result_ack(room4, two.clock)
	h.expect(str(two.sent_peers) == str([15, 16]), "b8_two_pending_two_sends", "Every unconfirmed online seat gets exactly one copy")
	two.free()

	probe.free()


# ── C. 集成：维护点每拍做什么 ───────────────────────────────────────────────

func _section_c() -> void:
	# C1 未到 deadline 且缺 ACK -> 催促，不推进。
	var probe := NudgeProbe.new()
	probe.online = all_online()
	probe.clock = 1000.0
	var room := room_fixture()
	room.result_acks = {0: BATTLE_ID}
	probe._rooms[room.id] = room
	probe._tick_result_ack_deadlines()
	h.expect(not probe.sent_peers.is_empty(), "c1_pending_room_nudged", "Maintenance retries a room that is still waiting")
	h.expect(probe.advanced.is_empty(), "c1b_no_advance_before_deadline", "Retry must not advance a seat that may still be watching")

	# C2 到 deadline -> 推进，且不再催。
	probe.clock = 1301.0
	var sent_before := probe.sent_peers.size()
	probe._tick_result_ack_deadlines()
	h.expect(str(probe.advanced) == str([900001]), "c2_advances_at_deadline", "The existing bounded fallback still advances")
	h.expect(probe.sent_peers.size() == sent_before, "c2b_no_nudge_when_advancing", "Advancing does not also re-send the settlement")
	probe.free()

	# C5 未到 deadline、但**在线真人已经全部确认** -> 必须立刻推进。
	# 这条与 _rpc_result_ack 末尾那条推进路径同源：1350-1353 的既有注释明确
	# "These are ceilings, not delays: all online human ACKs still advance the
	# room immediately."。此前 _tick_result_ack_deadlines 多要一个
	# `now >= deadline`，等于把兜底上限当成强制延迟 —— 六个人全确认完，房间
	# 仍要干等满整个窗口（最短 78s、带回放 206~480s），这就是第 8 条的
	# 「等待时间过长」。超时兜底由 _room_result_acks_complete 自己负责。
	var fresh := NudgeProbe.new()
	fresh.online = all_online()
	fresh.clock = 1000.0                      # 远早于 deadline = 1300
	var r5 := room_fixture()
	r5.result_acks = {0: BATTLE_ID, 1: BATTLE_ID, 2: BATTLE_ID,
		3: BATTLE_ID, 4: BATTLE_ID, 5: BATTLE_ID}
	fresh._rooms[r5.id] = r5
	fresh._tick_result_ack_deadlines()
	h.expect(str(fresh.advanced) == str([900001]), "c5_all_acked_advances_before_deadline",
		"Once every online human confirmed, the room advances at once -- the window is a ceiling, not a delay")
	h.expect(fresh.sent_peers.is_empty(), "c5b_nothing_to_nudge_when_all_acked",
		"A fully confirmed room has nobody left to remind")
	fresh.free()

	# C3/C4 不该被碰的房间：run_over / suspended / 非 result 阶段。
	var guarded := [[true, false, "result"], [false, true, "result"], [false, false, "prep"]]
	for entry in guarded:
		var p := NudgeProbe.new()
		p.online = all_online()
		p.clock = 1000.0
		var r := room_fixture()
		r.result_acks = {0: BATTLE_ID}
		r.run_over = bool(entry[0])
		r.suspended = bool(entry[1])
		r.state = str(entry[2])
		p._rooms[r.id] = r
		p._tick_result_ack_deadlines()
		var tag := "run_over" if bool(entry[0]) else ("suspended" if bool(entry[1]) else "not_result")
		h.expect(p.sent_peers.is_empty(), "c3_%s_untouched_nudge" % tag, "Guarded room is not nudged (%s)" % tag)
		h.expect(p.advanced.is_empty(), "c4_%s_untouched_advance" % tag, "Guarded room is not advanced (%s)" % tag)
		p.free()


# ── D. 客户端重发 ───────────────────────────────────────────────────────────

func _section_d() -> void:
	var src := FileAccess.get_file_as_string(MAIN_SRC)
	if not h.expect(not src.is_empty(), "d0_main_src_readable", "Main.gd is readable"):
		return
	var body := func_body(src, "func _finish_server_authoritative_team_battle(")
	if not h.expect(not body.is_empty(), "d1_func_found", "The settlement-wait entry point exists"):
		return
	h.expect(body.contains("var settlement_ack_id := str(state_payload.get(\"battle_id\", \"\"))"),
		"d2_ack_id_extracted", "The ACK identity is computed once and reused")
	h.expect(count(body, "NetworkService.send_result_ack(settlement_ack_id)") >= 2,
		"d3_ack_sent_again_while_waiting", "The wait loop re-sends the ACK, not just once")
	h.expect(body.contains("NetworkService.RESULT_ACK_RESEND_SEC"),
		"d5_resend_uses_interval_const", "Resend cadence comes from the shared constant")
	# ★ 反向红线：客户端**不许**自己推进。一旦本地抢跑，GameState.round_index 会
	#   领先服务器的 room.round_index，之后提交棋盘会被 wrong_round 拒收 ——
	#   那是个比"多等一会儿"更显眼的新 bug。
	#   注意判据只能盯**等待循环体内**：_show_prep() / team_begin_round() 在循环
	#   **之后**是这条路的正常出口，盯整函数会把正确实现判红。
	var loop := between(body, "while not NetworkService.server_prep_confirmed(completed_round + 1):",
		"_apply_team_match_state_payload(state_payload, result)")
	if h.expect(not loop.is_empty(), "d6a_wait_loop_found", "The wait loop body can be isolated"):
		h.expect(not loop.contains("break") and not loop.contains("_show_prep(")
			and not loop.contains("team_begin_round("),
			"d6_client_never_force_advances", "The wait loop only retries; it never jumps into prep on its own")
		h.expect(loop.contains("await get_tree().create_timer(0.1).timeout"),
			"d6b_wait_loop_yields", "The loop still yields every frame instead of busy-waiting")
	# 判据没被放松：还是 9.12 特意收紧的那一条（服务端回合号 + 备战阶段）。
	h.expect(body.contains("while not NetworkService.server_prep_confirmed(completed_round + 1):"),
		"d7_keeps_server_prep_gate", "The 9.12 round+phase gate is untouched")

	var resend := float(NetworkService.RESULT_ACK_RESEND_SEC)
	var nudge := float(NetworkService.RESULT_ACK_NUDGE_SEC)
	h.expect(resend > 0.0 and resend <= 5.0, "d8_resend_interval_sane", "Client retry interval is a few seconds")
	h.expect(nudge >= resend, "d9_nudge_not_faster_than_resend",
		"Server nudge is not denser than the client's own retry")
	h.expect(resend * 3.0 < 78.0, "d10_resend_beats_min_window",
		"Retry is far inside the server's shortest ACK window (78s)")

	var nsrc := FileAccess.get_file_as_string(NET_SRC)
	if not h.expect(not nsrc.is_empty(), "d11_nsrc_readable", "NetworkService.gd is readable"):
		return
	# 重发安全的前提：服务端对同一 battle_id 的 ACK 幂等、旧 battle_id 仍然拒收。
	h.expect(nsrc.contains('if str(acks.get(slot, "")) == battle_id:') and nsrc.contains("# 幂等：重复 ACK 不做任何事"),
		"d12_ack_is_idempotent", "Duplicate ACKs stay a no-op, so retry cannot double-count")
	h.expect(nsrc.contains("if battle_id.is_empty() or is_host or not team_active or multiplayer.multiplayer_peer == null:"),
		"d13_send_ack_still_guarded", "Client-side send guards were not loosened to make retry easier")
	h.expect(nsrc.contains("if battle_id != str(room.get(\"battle_id\", \"\")):"),
		"d14_stale_ack_still_rejected", "A late ACK from the previous battle is still dropped")


# ── E. 判别力自检 ───────────────────────────────────────────────────────────

func _section_e() -> void:
	# E1 result_acks 真的被读了：同一房间只翻这一个字段，结果必须变。
	var room := room_fixture()
	var before := pending(room, all_online()).size()
	for i in 6:
		room.result_acks[i] = BATTLE_ID
	h.expect(before == 6 and pending(room, all_online()).is_empty(),
		"e1_acks_actually_read", "Flipping result_acks alone changes the answer")

	# E2 slot_states 真的被读了。
	var r2 := room_fixture()
	var human := pending(r2, all_online()).size()
	r2.slot_states[1] = "dummy"
	h.expect(human == 6 and pending(r2, all_online()).size() == 5,
		"e2_states_actually_read", "Flipping slot_states alone changes the answer")

	# E3 last_match_state 真的被读了。
	var r3 := room_fixture()
	var published := pending(r3, all_online()).size()
	r3.last_match_state = {}
	h.expect(published == 6 and pending(r3, all_online()).is_empty(),
		"e3_published_flag_actually_read", "Flipping last_match_state alone changes the answer")

	# E4 在线名单真的被读了。
	var r4 := room_fixture()
	h.expect(pending(r4, all_online()).size() == 6 and pending(r4, [11]).size() == 1,
		"e4_online_list_actually_read", "Flipping the online list alone changes the answer")

	# E5 反向：一个"谁都不要催"的房（全 dummy）必须返回空 —— 否则上面
	#    「跳过 AI/空席」那条就是被别的东西满足的。
	var r5 := room_fixture()
	r5.slot_states = ["dummy", "dummy", "dummy", "dummy", "dummy", "dummy"]
	h.expect(pending(r5, all_online()).is_empty(), "e5_all_ai_nothing_to_nudge", "An all-AI room has nobody to remind")


func func_body(src: String, header: String) -> String:
	var at := src.find(header)
	if at < 0:
		return ""
	var rest := src.substr(at)
	var lines := rest.split("\n")
	var out := PackedStringArray()
	for idx in lines.size():
		var line := lines[idx]
		if idx > 0 and not line.begins_with("\t") and not line.strip_edges().is_empty():
			break
		out.append(line)
	return "\n".join(out)


# src 里 [from, to) 之间的那段文本；任一端找不到就返回空串。
# 用来把「一个循环体」从整个函数里切出来 —— 只对循环体断言，不对整函数断言。
func between(src: String, from: String, to: String) -> String:
	var a := src.find(from)
	if a < 0:
		return ""
	a += from.length()
	var b := src.find(to, a)
	if b < 0:
		return ""
	return src.substr(a, b - a)


func count(hay: String, needle: String) -> int:
	var n := 0
	var at := hay.find(needle)
	while at >= 0:
		n += 1
		at = hay.find(needle, at + needle.length())
	return n
