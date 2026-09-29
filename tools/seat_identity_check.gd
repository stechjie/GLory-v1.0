extends Node

# 门禁：战报里「哪个账号坐哪个座位」（2026-09-29）。
#
# 战报认人靠 room.seat_pid（入座名片上的账号 id）。它以前不在 RoomService.SEAT_SLOT_MAPS 里：
# 换座之后账号留在旧座位。用户实际遇到的两种结果都不报错：
#   · 旧座位被补成 AI → 历史里把他记成「AI + 掉线未归」、坐错队、胜负反了，还按跑路扣信誉分；
#   · 旧座位被别人坐走 → 他的账号被顶掉，整局历史里找不到他。
# 「打完返回房间」那条（_return_to_settlement_room）以前把**所有人**的账号整份抄进新房间，
# 没回来的人的账号留在空座位上 —— 房主补个 AI，就把一个不在场的人记进下一局。
#
# 这里走的是真实的 NetworkService 代码（传输打桩，同 tools/final_settlement_check.gd 的 TestServer），
# 最后查的是战报的原料 _room_report_ctx —— 不带私钥也能查，签章那一半在 battle_report_check。

const Harness := preload("res://tools/CheckHarness.gd")

const ME := "11111111-1111-1111-1111-111111111111"
const OTHER := "22222222-2222-2222-2222-222222222222"
const HOST := "33333333-3333-3333-3333-333333333333"

var h := Harness.new("seat_identity")


class TestServer extends "res://scripts/autoload/NetworkService.gd":
	var live := {}
	func _ready() -> void:
		_reconnect_service.configure(_now, _net_log, {})
		_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {}, _reconnect_service)
		_match_state.configure(_now)
	func _process(_delta: float) -> void:
		pass
	func _peer_connected(pid: int) -> bool:
		return live.has(pid)
	func _broadcast_room_lobby(room: Dictionary) -> void:
		_bump_room_seq(room)
	func _send_room_state(_room: Dictionary, _peer: int, _seq: int) -> void:
		pass
	func _voice_seat_released(_room: Dictionary, _slot: int, _identity: String) -> void:
		pass


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var server := TestServer.new()
	add_child(server)
	_case_swap_carries_account(server)
	_case_leave_clears_account(server)
	_case_rematch_copies_only_returning_seats(server)
	_case_report_carries_settlement(server)
	server.queue_free()
	h.finish(get_tree())


# 房主在 A（slot 0），我先落在 C（slot 2），再换到「1」（slot 3，跨队）。
func _lobby_with_me_at_c(server: TestServer) -> Dictionary:
	var room: Dictionary = server._new_room()
	var states: Array = room.slot_states
	states[0] = "player"
	states[2] = "player"
	room.slot_states = states
	room.peer_slot = {100: 0, 102: 2}
	server._room_store_seat_card(room, 0, {"pid": HOST})
	server._room_store_seat_card(room, 2, {"pid": ME})
	return room


func _pid_slots(room: Dictionary, pid: String) -> Array:
	var out := []
	var pids: Dictionary = room.get("seat_pid", {})
	for slot in pids:
		if str(pids[slot]) == pid:
			out.append(int(slot))
	out.sort()
	return out


func _case_swap_carries_account(server: TestServer) -> void:
	var room := _lobby_with_me_at_c(server)
	server._room_do_move(room, 102, 2, 3)
	h.expect(_pid_slots(room, ME) == [3], "swap_left_account_behind",
		"换座之后我的账号应该只在 slot 3，实际在 %s" % str(_pid_slots(room, ME)))

	# 空出来的 C 补 AI：战报里 C 是 AI、没有账号；我在 slot 3，在线、不是 AI。
	server._room_toggle_slot(room, 2)
	var ctx: Dictionary = server._room_report_ctx(room, 21, 1, 0, 30, {})
	var seats: Array = ctx.get("seats", [])
	var c: Dictionary = seats[2]
	var mine: Dictionary = seats[3]
	h.expect(str(c.pid) == "" and bool(c.was_ai), "ai_seat_has_account",
		"补了 AI 的旧座位不该带着我的账号（pid=%s）—— 那就是「AI + 掉线未归」、坐错队" % str(c.pid))
	h.expect(str(mine.pid) == ME and bool(mine.online_at_end) and not bool(mine.was_ai), "my_seat_wrong",
		"我真正坐的 slot 3 应该是我的账号、在线（pid=%s online=%s）" % [str(mine.pid), str(mine.online_at_end)])

	# 别人坐进 C：我的账号不能被顶掉（以前就是这样整局找不到我）。
	server._room_toggle_slot(room, 2)   # AI → 空位
	server._room_store_seat_card(room, 2, {"pid": OTHER})
	h.expect(_pid_slots(room, ME) == [3] and _pid_slots(room, OTHER) == [2], "account_overwritten",
		"别人坐进旧座位后：我应在 3（%s）、他在 2（%s）" % [str(_pid_slots(room, ME)), str(_pid_slots(room, OTHER))])


func _case_leave_clears_account(server: TestServer) -> void:
	var room := _lobby_with_me_at_c(server)
	server._room_do_move(room, 102, 2, 3)
	server._clear_seat_metadata(room, 3)
	h.expect(_pid_slots(room, ME).is_empty(), "leave_keeps_account",
		"离座之后账号还留在房间里（%s）—— 后坐进来的人会顶着我的账号进战报" % str(_pid_slots(room, ME)))


# 打完「返回房间」：只有真的会回来的人（还连着、座位标成 settling）才把身份带进新房间。
func _case_rematch_copies_only_returning_seats(server: TestServer) -> void:
	var old: Dictionary = server._new_room()
	old["state"] = "result"
	old["run_over"] = true
	old["mode"] = "custom"
	old["slot_states"] = ["player", "player", "empty", "player", "empty", "empty"]
	old["initial_seats"] = old.slot_states.duplicate()
	old["peer_slot"] = {11: 0, 12: 1, 13: 3}
	old["seat_pid"] = {0: HOST, 1: ME, 3: OTHER}
	old["seat_profiles"] = {0: {"player_name": "房主"}, 1: {"player_name": "我"}, 3: {"player_name": "走了的人"}}
	for pid in old.peer_slot:
		server._peer_room[pid] = int(old.id)
	server.live = {11: true, 12: true}   # 13 已经断了：不会回来
	var target: Dictionary = server._return_to_settlement_room(12)
	h.expect(not target.is_empty(), "rematch_room_missing", "返回房间没建出新房间")
	if target.is_empty():
		return
	var pids: Dictionary = target.get("seat_pid", {})
	h.expect(not pids.has(3) and not pids.has("3"), "absent_player_copied",
		"没回来的人（slot 3）的账号被抄进了新房间 —— 房主在那儿补 AI，他就被记进一局没打的对局")
	h.expect(not (target.get("seat_profiles", {}) as Dictionary).has(3), "absent_profile_copied",
		"没回来的人的资料也不该留在新房间")
	h.expect(str(pids.get(1, "")) == ME, "returning_player_lost",
		"回来的人（slot 1）账号要跟过去，实际 %s" % str(pids.get(1, "")))
	h.expect(str(pids.get(0, "")) == HOST, "pending_host_lost",
		"还没点返回、但还连着的房主（slot 0）要给他留着账号")


# 战报原料里带着结算面板那份数据（历史里的「详细战况」）。
func _case_report_carries_settlement(server: TestServer) -> void:
	var room := _lobby_with_me_at_c(server)
	room["match_uid"] = "f".repeat(32)
	var final_data := {
		"seats": [{}, {}, {"stones": {"sky": 2}, "total_gold": 1480}, {}, {}, {}],
		"allies": ["圣骑守护", "暗影守护"],
		"stats": [{"owner_slot": 2, "id": "unit_x", "damage_dealt": 5}],
	}
	var ctx: Dictionary = server._room_report_ctx(room, 21, 0, 30, 0, final_data)
	var seat: Dictionary = (ctx.get("seats", []) as Array)[2]
	h.expect(seat.get("stones", {}) == {"sky": 2} and int(seat.get("total_gold", 0)) == 1480,
		"settlement_seat_missing", "战报原料没带上升级石 / 总金币：%s" % str(seat))
	h.expect(ctx.get("allies", []) == ["圣骑守护", "暗影守护"] and (ctx.get("stats", []) as Array).size() == 1,
		"settlement_stats_missing", "战报原料没带上法阵守护 / 最后一战统计")
	h.expect(str(ctx.get("match_uid", "")) == "f".repeat(32), "match_uid_missing", "战报原料要带本局 match_uid")
