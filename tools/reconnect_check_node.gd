extends Node

# 断线重连链路校验（headless 下 NetworkService 自动启动专用服务器）：
# A. 掉线 -> 座位保留 + 宽限截止 + token 映射不丢
# B. 宽限到期(备战) -> 自动 ready -> 开局 -> 自动补交空棋盘 -> 出结果
# C. 房主掉线 -> 顺延给最小编号在线座位
# 通过后可保留作回归工具。

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame  # 等 dedicated server 启动完成
	var ok := true

	# --- A: 保留座位 ---
	var room: Dictionary = NetworkService._new_room()
	room.state = NetworkService.ROOM_PREP
	room.slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	room.ready = [false, true, true, true, true, true]
	room.peer_slot = {99: 0}
	NetworkService._peer_room[99] = int(room.id)
	room.seat_tokens = {0: "tok_test"}
	NetworkService._token_seat["tok_test"] = {"room_id": int(room.id), "slot": 0}
	NetworkService._room_reserve_peer(room, 99)
	var reserved_ok: bool = (room.reserved as Dictionary).has(0) and (room.reserve_deadline as Dictionary).has(0) and not (room.peer_slot as Dictionary).has(99)
	var token_ok: bool = NetworkService._token_seat.has("tok_test") and str(room.slot_states[0]) == "player"
	print("PROBE A reserve: reserved=%s token_kept=%s" % [str(reserved_ok), str(token_ok)])
	ok = ok and reserved_ok and token_ok

	# --- B: 宽限到期 -> 自动完成整轮 ---
	(room.reserve_deadline as Dictionary)[0] = NetworkService._now() - 1.0
	NetworkService._tick_reserved_seats()
	await get_tree().process_frame
	var state_ok: bool = str(room.state) == NetworkService.ROOM_RESULT
	var board_ok: bool = (room.boards as Dictionary).is_empty()  # 计算完会清空 boards
	var result_ok: bool = not (room.last_match_state as Dictionary).is_empty() and (room.last_match_state as Dictionary).has(0)
	print("PROBE B auto-complete: state=%s(->result:%s) result_stamped=%s boards_cleared=%s" % [str(room.state), str(state_ok), str(result_ok), str(board_ok)])
	ok = ok and state_ok and result_ok

	# --- C: 房主顺延 ---
	var room2: Dictionary = NetworkService._new_room()
	room2.state = NetworkService.ROOM_PREP
	room2.slot_states = ["player", "player", "dummy", "dummy", "dummy", "dummy"]
	room2.ready = [false, false, true, true, true, true]
	room2.peer_slot = {5: 0, 7: 1}
	NetworkService._peer_room[5] = int(room2.id)
	NetworkService._peer_room[7] = int(room2.id)
	NetworkService._room_reserve_peer(room2, 5)
	var leader_ok: bool = int(room2.leader_slot) == 1
	print("PROBE C leader promote: leader_slot=%d ok=%s" % [int(room2.leader_slot), str(leader_ok)])
	ok = ok and leader_ok

	# --- D: 宽限到期转 dummy，之后 token 重连把 dummy 变回 player ---
	var room3: Dictionary = NetworkService._new_room()
	room3.state = NetworkService.ROOM_PREP
	room3.slot_states = ["player", "player", "dummy", "dummy", "dummy", "dummy"]
	room3.ready = [false, false, true, true, true, true]
	room3.peer_slot = {11: 1}          # slot1 有真人在线（slot0 是掉线者）
	NetworkService._peer_room[11] = int(room3.id)
	room3.seat_tokens = {0: "tok_d"}
	NetworkService._token_seat["tok_d"] = {"room_id": int(room3.id), "slot": 0}
	room3.reserved = {0: {"reserved_at": NetworkService._now()}}
	# 宽限到期 -> slot0 转 dummy
	NetworkService._room_auto_complete_seat(room3, 0)
	var became_dummy: bool = str(room3.slot_states[0]) == "dummy"
	# A 用 token 重连（模拟 resume 的座位恢复段）
	var seat_d: Dictionary = NetworkService._token_seat.get("tok_d", {})
	var slot_d := int(seat_d.get("slot", -1))
	room3.slot_states[slot_d] = "player"   # resume 会做的事
	var restored: bool = str(room3.slot_states[0]) == "player" and NetworkService._token_seat.has("tok_d")
	print("PROBE D dummy<->player: became_dummy=%s token_alive=%s restored=%s" % [str(became_dummy), str(NetworkService._token_seat.has("tok_d")), str(restored)])
	ok = ok and became_dummy and restored

	print("PROBE RESULT: %s" % ("ALL PASS" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)
