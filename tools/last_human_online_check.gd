extends Node
const H := preload("res://tools/CheckHarness.gd")
class Server extends "res://scripts/autoload/NetworkService.gd":
	var clock := 1000.0
	var live := {11: true}
	var sent: Array = []
	var signed_count := 0
	# 打开后签章时顺手记下战报里的座位（账号服务器按它扣分：pid + online_at_end）。
	var capture_ctx := false
	var signed_seats: Array = []
	func _ready() -> void:
		_reconnect_service.configure(_now, _net_log, {})
		_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {}, _reconnect_service)
		_match_state.configure(_now)
	func _process(_delta: float) -> void:
		pass
	func _now() -> float:
		return clock
	func _peer_connected(pid: int) -> bool:
		return live.has(pid)
	func _broadcast_room_lobby(_r: Dictionary) -> void:
		pass
	func _resend_result_state(pid: int, ms: Dictionary) -> void:
		sent.append([pid, ms])
	func _room_sign_report(_r: Dictionary, _n: int, _o: int, _a: int, _b: int, _f: Dictionary) -> String:
		signed_count += 1
		if capture_ctx:
			signed_seats = _room_report_ctx(_r, _n, _o, _a, _b, _f).get("seats", [])
		return "signed_fixture"
	func _voice_seat_released(_r: Dictionary, _s: int, _i: String) -> void:
		pass
# 顶替 BattleReportUplink：只记下交了什么，不发 HTTP。
class Uplink extends RefCounted:
	var got: Array = []
	func submit(match_uid: String, wire: String) -> void:
		got.append([match_uid, wire])
class Client extends "res://scenes/main/Main.gd":
	var shown := 0
	var applied: Dictionary = {}
	func _ready() -> void:
		pass
	func _apply_team_match_state_payload(ms: Dictionary, _result: Dictionary = {}) -> void:
		applied = ms
	func _show_game_over(_data: Dictionary = {}) -> void:
		shown += 1
		_clear()
func _ready() -> void:
	NetworkService.set_process(false)
	var h := H.new("last_human_online")
	var s := Server.new()
	add_child(s)
	for phase in ["prep", "battle", "result"]:
		for survivor in [0, 3]:
			s.clock = 1000.0
			s.live = {11: true}
			var r: Dictionary = s._new_room()
			r.state = phase
			r.round_index = 3
			r.peer_slot = {11: survivor}
			r.initial_seats = ["player", "player", "dummy", "player", "dummy", "empty"]
			r.slot_states = r.initial_seats.duplicate()
			r.battle_id = "%d:3:1" % int(r.id)
			r.human_offline_since = {0: 1000.0, 1: 1000.0, 3: 1000.0}
			r.human_offline_since.erase(survivor)
			s.clock = 1119.0
			h.expect(s._last_online_human_winner(r) == -1, phase + str(survivor) + "_119", "No early victory")
			s.clock = 1120.0
			h.expect(s._last_online_human_winner(r) == survivor, phase + str(survivor) + "_120", "Last survivor after grace")
			s.live[12] = true
			r.peer_slot[12] = 1
			h.expect(s._last_online_human_winner(r) == -1, "two_online", "Any second human blocks victory")
			r.peer_slot.erase(12)
			s.live.erase(12)
			r.slot_states[1] = "dummy"
			h.expect(s._last_online_human_winner(r) == survivor, "ai_preserves_human_history", "AI replacement is not an original bot")
			var old_id: String = r.battle_id
			var gold: Array = r.slot_gold.duplicate()
			var hp: Array = r.team_hp.duplicate()
			s._replay_out[11] = {"battle_id": old_id}
			var before := s.signed_count
			s._tick_reserved_seats()
			h.expect(not s._replay_out.has(11), "cancel_old_delivery", "No stale replay retransmit after terminal result")
			h.expect(r.run_over and r.state == "result", "terminal", "Tick ends entire match")
			h.expect(r.last_match_state[survivor].team_run_won and not r.last_match_state[3 if survivor == 0 else 0].team_run_won, "perspective", "Winner is correct on both teams")
			h.expect(r.slot_gold == gold and r.team_hp == hp, "no_rewards", "No invented round rewards or damage")
			h.expect(not s._simulation_is_current(r.id, old_id), "cancel_old_simulation", "Late simulation cannot overwrite result")
			s._finish_abandoned_match(r, survivor)
			h.expect(s.signed_count == before + 1, "idempotent", "Only one signed terminal result")
	var solo: Dictionary = s._new_room()
	solo.state = "prep"
	solo.initial_seats = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	solo.peer_slot = {11: 0}
	h.expect(s._last_online_human_winner(solo) == -1, "solo_ai", "Solo practice does not auto-win")
	solo.initial_seats[3] = "player"
	solo.human_offline_since = {3: 0.0}
	solo.peer_slot = {}
	h.expect(s._last_online_human_winner(solo) == -1, "zero_online", "No winner with zero online")
	solo.peer_slot = {11: 0}
	solo.state = "lobby"
	h.expect(s._last_online_human_winner(solo) == -1, "lobby", "Lobby not a match")
	# A reconnect cancels abandonment; another disconnect receives a new clock.
	solo.state = "prep"
	solo.slot_states = solo.initial_seats.duplicate()
	solo.peer_slot[12] = 3
	s.live[12] = true
	s._room_reserve_peer(solo, 12)
	s.live.erase(12)
	h.expect(s._last_online_human_winner(solo) == -1, "fresh_disconnect", "A second outage starts a fresh grace")
	s.clock += 119.0
	h.expect(s._last_online_human_winner(solo) == -1, "fresh_119", "Earlier outage does not shorten new grace")
	s.clock += 1.0
	h.expect(s._last_online_human_winner(solo) == 0, "fresh_120", "New outage eventually expires")
	solo.peer_slot[12] = 3
	s.live[12] = true
	s._reconnect_service.release_reservation(solo, 3)
	h.expect(s._last_online_human_winner(solo) == -1, "returned_peer", "Returned player cancels forfeit")
	# Last arriving disconnect controls the grace, not the first departure.
	solo.peer_slot.erase(12)
	s.live.erase(12)
	solo.initial_seats[1] = "player"
	solo.human_offline_since[1] = s.clock - 1.0
	h.expect(s._last_online_human_winner(solo) == -1, "staggered_outages", "Every absent human receives full grace")
	GameState.team_mode = true
	var c := Client.new()
	add_child(c)
	c._resume_replay_pending = {"waiting": true}
	var ms: Dictionary = s.sent[0][1]
	c._on_network_match_state_received(ms)
	h.expect(c.shown == 1 and c.applied.run_over and c._resume_replay_pending.is_empty(), "client_interrupt", "Terminal result interrupts replay recovery")
	c._on_network_match_state_received(ms)
	h.expect(c.shown == 1, "client_duplicate", "Duplicate delivery does not reopen panel")
	# Exercise active battle and preparation owners as well as replay recovery.
	for field in ["_battle", "_prep"]:
		var screen := Control.new()
		c.add_child(screen)
		c.set(field, screen)
		var next := ms.duplicate(true)
		next.battle_id = str(ms.battle_id) + field
		var count := c.shown
		c._on_network_match_state_received(next)
		h.expect(c.shown == count + 1 and not screen.is_inside_tree(), field + "_interrupted", "No lingering battle/loading owner after termination")

	# ---- 10.11 第 7 条：无活人 -> 对局作废 ------------------------------------
	# 2026-11-03（甲）：掉线等满重连窗口才作废；作废的战报直接交给账号服务器。
	var grace: float = s.NO_LIVE_HUMAN_END_SEC
	h.expect(is_equal_approx(grace, s.RESERVE_GRACE_SEC), "void_grace_is_reconnect_window",
		"掉线作废必须等满重连窗口（%s 秒），实测 %s" % [str(s.RESERVE_GRACE_SEC), str(grace)])
	var uplink := Uplink.new()
	s._report_uplink = uplink
	for phase in ["prep", "battle", "result"]:
		s.clock = 5000.0
		s.live = {}
		uplink.got.clear()
		var v: Dictionary = s._new_room()
		v.state = phase
		v.round_index = 4
		v.match_uid = "%032x" % (0x5000 + int(v.id))
		v.peer_slot = {11: 0, 12: 3}
		# 真人只有 0 号与 3 号两格（其余是 AI / 空位），好让「活人数」一眼可数。
		v.initial_seats = ["player", "dummy", "dummy", "player", "dummy", "empty"]
		v.slot_states = v.initial_seats.duplicate()
		v.battle_id = "%d:4:1" % int(v.id)
		# 两个真人都还在重连窗口内：还算活人 -> 不作废。
		v.human_offline_since = {0: s.clock - (grace - 1.0), 3: s.clock - (grace - 1.0)}
		h.expect(s._room_live_human_count(v) == 2, phase + "_live_within_grace",
			"掉线未超重连窗口的真人仍算活人")
		h.expect(not s._void_room_eligible(v), phase + "_not_eligible_within_grace",
			"掉线未超重连窗口时不该作废")
		# 🔴 窗口内座位被 AI 代打了（备战倒计时到点 / 30 秒没交棋盘）也还算 —— 回来照样接上。
		v.slot_states[0] = "dummy"
		v.slot_states[3] = "dummy"
		h.expect(s._room_live_human_count(v) == 2, phase + "_ai_covered_within_grace",
			"重连窗口内被 AI 代打的掉线真人仍算活人（否则会提前作废、按跑路扣分）")
		h.expect(not s._void_room_eligible(v), phase + "_ai_covered_not_eligible",
			"重连窗口内座位转 AI 不该作废")
		# 窗口过了：一个活人都不剩 -> 作废。
		v.human_offline_since = {0: s.clock - grace, 3: s.clock - (grace + 1.0)}
		h.expect(s._room_live_human_count(v) == 0, phase + "_live_expired",
			"掉线超过重连窗口不再算活人")
		h.expect(s._void_room_eligible(v), phase + "_eligible", "无活人时该作废")
		s._tick_void_watchdog()
		h.expect(v.run_over and v.state == "result", phase + "_voided", "无活人的对局应被作废")
		# 一个连着的人都没有 —— 只有战斗服务器自己交，这局才记得上（11-02 线上 5 局全丢）。
		h.expect(uplink.got.count([str(v.match_uid), "signed_fixture"]) == 1,
			phase + "_void_report_delivered",
			"作废的战报必须直接交给账号服务器，实测 %s" % str(uplink.got))
		var seat0: Dictionary = v.last_match_state.get(0, {})
		var seat3: Dictionary = v.last_match_state.get(3, {})
		h.expect(not bool(seat0.get("team_run_won", true)) and not bool(seat3.get("team_run_won", true)),
			phase + "_void_no_winner", "作废时两队都不算赢（DRAW）")
		h.expect(str(seat0.get("end_reason", "")) == "no_live_human", phase + "_void_reason",
			"作废的 end_reason 应是 no_live_human，实测 %s" % str(seat0.get("end_reason", "")))
		# 再来一次：已经作废过的局不能再被作废（幂等）。
		var signed_after := s.signed_count
		s._tick_void_watchdog()
		h.expect(s.signed_count == signed_after, phase + "_void_idempotent",
			"作废只签一次终局战报")
		h.expect(uplink.got.count([str(v.match_uid), "signed_fixture"]) == 1, phase + "_void_delivered_once", "作废只交一次")

	# 纯 AI 房永不触发（不加这条每局一开局就自杀）。
	var bots: Dictionary = s._new_room()
	bots.state = "prep"
	bots.initial_seats = ["dummy", "dummy", "dummy", "dummy", "dummy", "dummy"]
	bots.slot_states = bots.initial_seats.duplicate()
	h.expect(s._room_live_human_count(bots) == 0, "bots_zero_live", "纯 AI 房没有活人")
	h.expect(not s._void_room_eligible(bots), "bots_never_voided", "纯 AI 房不该被判作废")

	# 手动「退出对局」的座位立刻不算活人，不等掉线那个重连窗口。
	# 这正是 11-02 的现场：AI 补位排位局，唯一的真人点了退出。
	s.clock = 6000.0
	uplink.got.clear()
	var manual: Dictionary = s._new_room()
	manual.state = "prep"
	manual.round_index = 5
	manual.match_uid = "%032x" % 0x6000
	manual.initial_seats = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	manual.slot_states = manual.initial_seats.duplicate()
	manual.peer_slot = {}
	h.expect(s._room_live_human_count(manual) == 1, "manual_live_before", "手动退出前算活人")
	manual.manual_exit_slots = {0: true}
	# _rpc_manual_exit_seat 顺手记的掉线时刻是「刚刚」—— 有它也必须立刻不算。
	manual.human_offline_since = {0: s.clock}
	h.expect(s._room_live_human_count(manual) == 0, "manual_not_live", "手动退出后立刻不算活人")
	h.expect(s._void_room_eligible(manual), "manual_eligible",
		"最后一名活人手动退出 -> 立刻可以作废")
	s._tick_void_watchdog()
	h.expect(bool(manual.get("run_over", false)) and uplink.got.count([str(manual.match_uid), "signed_fixture"]) == 1,
		"manual_void_report_delivered", "唯一真人退出后，作废的战报由战斗服务器直接交上去，实测 %s" % str(uplink.got))

	# 大厅阶段不是对局，不作废。
	var lobby_room: Dictionary = s._new_room()
	lobby_room.state = "lobby"
	lobby_room.initial_seats = ["player", "player", "dummy", "player", "dummy", "empty"]
	lobby_room.slot_states = lobby_room.initial_seats.duplicate()
	lobby_room.human_offline_since = {0: s.clock - 100.0, 1: s.clock - 100.0, 3: s.clock - 100.0}
	h.expect(not s._void_room_eligible(lobby_room), "lobby_not_voided", "大厅阶段不该被作废")

	# ---- 2026-11-07：关房前必须先作废（测试服房间 985648）-------------------------
	# 作废看门狗和房间清理各自每秒一跑。清理先到就直接关房、清掉 seat_pid —— 这局不签战报，
	# 跑路的人一分不扣。下面**只跑清理、不跑看门狗**，就是「清理先到」那一种。
	# 用一台新的 Server：上面那台的房间会混进清理里。
	var t := Server.new()
	add_child(t)
	t.capture_ctx = true
	t.live = {}
	t._room_service.configure(t._now, t._wall_now, t._net_log, func(): return 0,
		{"room_suspend_grace_sec": t.ROOM_SUSPEND_GRACE_SEC}, t._reconnect_service)
	var close_uplink := Uplink.new()
	t._report_uplink = close_uplink
	const PID := "f36fcb11-1c53-49b0-b4c1-54cc98b75014"
	# AI 补位排位局：0 号是唯一的真人，其余 5 个 AI（线上 985648 的 slots 原样）。
	var make_solo := func(uid: int) -> Dictionary:
		var room: Dictionary = t._new_room()
		room.state = "prep"
		room.round_index = 2
		room.mode = "ranked"
		room.match_uid = "%032x" % uid
		room.initial_seats = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
		room.slot_states = room.initial_seats.duplicate()
		room.seat_pid = {0: PID}
		var token := "tok_%x" % uid
		room.seat_tokens = {0: token}
		t._token_seat[token] = {"room_id": int(room.id), "slot": 0}
		room.peer_slot = {21: 0}
		t._peer_room[21] = int(room.id)
		return room
	var charged := func(label: String, room: Dictionary) -> void:
		h.expect(close_uplink.got.count([str(room.match_uid), "signed_fixture"]) == 1, label + "_report_delivered",
			"关房前必须先作废并把战报交给账号服务器，实测 %s" % str(close_uplink.got))
		var seat0: Dictionary = t.signed_seats[0] if not t.signed_seats.is_empty() else {}
		h.expect(str(seat0.get("pid", "")) == PID and not bool(seat0.get("online_at_end", true)), label + "_seat_charged",
			"战报里 0 号座位必须是他本人、且结束时不在线（账号服务器才会扣信誉分），实测 %s" % str(seat0))
		h.expect(str(room.get("state", "")) == "closed", label + "_closed", "作废完照样关房")

	# ① 手动「退出对局」：照 _rpc_manual_exit_seat 的函数体做（门禁里没有 RPC 发送方），然后客户端断开。
	t.clock = 7000.0
	var exited: Dictionary = make_solo.call(0x7000)
	exited.manual_exit_slots = {0: true}
	exited.human_offline_since = {0: t.clock}
	t._revoke_seat_credentials(exited, 0)
	t._room_reserve_peer(exited, 21)
	h.expect(t._room_live_token_count(exited) == 0 and t._room_online_count(exited) == 0, "close_manual_setup",
		"退出后应是零有效凭证、零在线（线上就是这样被 empty_no_tokens 关掉的）")
	t._cleanup_rooms()
	h.expect(str(exited.get("finished_reason", "")) == "empty_no_tokens", "close_manual_path",
		"复现的应是线上那条关房路径，实测 %s" % str(exited.get("finished_reason", "")))
	charged.call("close_manual", exited)

	# ② 杀进程 = 掉线、凭证还在：窗口内只挂起；到 ROOM_SUSPEND_GRACE_SEC 被 suspend_expired 关掉之前要先作废。
	t.clock = 8000.0
	close_uplink.got.clear()
	t.signed_seats = []
	var killed: Dictionary = make_solo.call(0x8000)
	t._room_reserve_peer(killed, 21)
	t.clock += 1.0
	t._cleanup_rooms()
	h.expect(bool(killed.get("suspended", false)) and str(killed.state) == "prep" and close_uplink.got.is_empty(),
		"close_killed_window_kept", "重连窗口内只挂起：不关房、不作废")
	t.clock = 8000.0 + t.ROOM_SUSPEND_GRACE_SEC
	t._cleanup_rooms()
	h.expect(str(killed.get("finished_reason", "")) == "suspend_expired", "close_killed_path",
		"复现的应是 suspend_expired 关房，实测 %s" % str(killed.get("finished_reason", "")))
	charged.call("close_killed", killed)

	# ③ 不该补的不补：纯 AI 房、大厅、已经作废过的局（不能交第二份）。
	close_uplink.got.clear()
	var bots_close: Dictionary = t._new_room()
	bots_close.state = "prep"
	bots_close.match_uid = "%032x" % 0x9000
	bots_close.initial_seats = ["dummy", "dummy", "dummy", "dummy", "dummy", "dummy"]
	bots_close.slot_states = bots_close.initial_seats.duplicate()
	var lobby_close: Dictionary = make_solo.call(0x9001)
	lobby_close.state = "lobby"
	lobby_close.peer_slot = {}
	t._token_seat.erase("tok_9001")
	lobby_close.seat_tokens = {}
	var voided: Dictionary = make_solo.call(0x9002)
	voided.manual_exit_slots = {0: true}
	t._revoke_seat_credentials(voided, 0)
	t._room_reserve_peer(voided, 21)
	t._tick_void_watchdog()
	h.expect(close_uplink.got.count([str(voided.match_uid), "signed_fixture"]) == 1, "close_watchdog_first",
		"看门狗先到时照旧由它作废")
	t._cleanup_rooms()
	h.expect(str(bots_close.state) == "closed" and str(lobby_close.state) == "closed" and str(voided.state) == "closed",
		"close_negatives_closed", "三间房都该被清理关掉")
	h.expect(close_uplink.got.size() == 1, "close_no_extra_report",
		"纯 AI 房 / 大厅不交战报，已作废的局关房时不交第二份，实测 %s" % str(close_uplink.got))
	t.queue_free()

	c.queue_free()
	s.queue_free()
	# 结构：tick 里必须**真的调到**它（函数定义 ≠ 已接线 —— 只写个 func 永远不会跑）。
	var ns_src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	h.expect(ns_src.contains("\t\t\t_tick_void_watchdog()"), "watchdog_wired",
		"服务端 tick 必须调用 _tick_void_watchdog()，否则这条规则永远不跑")
	h.expect(ns_src.contains("const NO_LIVE_HUMAN_END_SEC := RESERVE_GRACE_SEC"), "void_threshold_reconnect_window",
		"无活人阈值必须和重连窗口是同一个常量（2026-11-03 用户定），不能另写一个数")
	h.expect(ns_src.contains("\t\t_report_uplink_setup()\n"), "uplink_wired_on_dedicated",
		"专服启动时必须建好战报直交（_report_uplink_setup），否则作废局又没人交")
	h.expect(ns_src.contains("_finish_abandoned_match(room, -1, \"no_live_human\")"),
		"void_no_winner", "作废必须走「无胜者」那条（winner_slot = -1 + end_reason=no_live_human）")
	h.expect(ns_src.contains("room[\"manual_exit_slots\"] = manual") and ns_src.contains("manual[slot] = true"),
		"manual_exit_marked",
		"手动退出对局的座位必须打 manual_exit_slots 标记（否则最后一人退出后房间永不结束）")
	var close_src := ns_src.substr(ns_src.find("func _room_close("), 1500)
	var hook_at := close_src.find("_void_before_close(room, reason)")
	h.expect(hook_at >= 0 and hook_at < close_src.find("_clear_seat_metadata(room, slot_i)"), "void_before_clear_seats",
		"_room_close 必须在清座位之前先 _void_before_close —— 清完 seat_pid 再作废，战报里就没有该扣分的人")
	h.finish(get_tree())
