extends "res://tools/replay_transport_check.gd"
const Fixture := preload("res://scripts/qa/FixedBattleFixture.gd")
const MobilePeer := preload("res://tools/mobile_reconnect_peer.gd")

# 10.18 备战阶段优化门禁：
#   ① 准备即提交棋盘（PREP 阶段服务端就收）
#   ② 取消准备 = 作废提交（boards + last_board 一起清）
#   ③ PREP 允许覆盖、BATTLE 拒重复
#   ④ round start 不清 boards（PREP 提交带进 finalize）
#   ⑤ 倒计时转 dummy 后补 finalize（BATTLE 场景不再干等 30s 看门狗）
#   ⑥ 备战不再弹战斗准备窗口（team_mode 不开 overlay，无论有没有掉线；失败仍有兜底面板）
#
# 网络段复用 replay_transport_check 的 ENet loopback 基建（同 mobile_reconnect_check）。

const WATCHDOG_SEC := 120.0
var _finished := false


func endpoint(label: String, peer: ENetMultiplayerPeer) -> Node:
	# 与父类一致，但挂 MobilePeer（带 _rpc_room_state / _rpc_resume_failed 回包）。
	var branch := Node.new()
	branch.name = label
	add_child(branch)
	branches.append(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	api.multiplayer_peer = peer
	api.server_relay = false
	var node := MobilePeer.new()
	node.name = "Network"
	branch.add_child(node)
	return node


func run() -> void:
	h = H.new("prep_submit_board")
	Engine.max_fps = 60
	_arm_watchdog()
	_check_static_contract()
	await _exercise()
	await cleanup()
	_done()


func _done() -> void:
	if _finished:
		return
	_finished = true
	h.finish(get_tree())


func _arm_watchdog() -> void:
	# 协程段一旦抛错，_ready/_run 链会中止、finish 永远不会来 ⇒ 进程挂住。
	# 看门狗把那种情况转成显式失败，比挂死好。
	get_tree().create_timer(WATCHDOG_SEC).timeout.connect(func() -> void:
		if not _finished:
			h.fail("watchdog_timeout", "check did not finish within %ds" % int(WATCHDOG_SEC))
			_done()
	)


# --- 第一节：静态契约（不联网） -------------------------------------------------

func _check_static_contract() -> void:
	var prep_script: GDScript = load("res://scenes/prep/PrepScreen.gd")
	var prep_consts: Dictionary = prep_script.get_script_constant_map()
	# 10.18 晚二：静默期整条机制随「战斗准备窗口」一起废除 —— 备战不再弹窗，
	# 无论有没有掉线；反馈交给开始按钮 busy 态与 BattleScreen 自己的读条。
	h.expect(not prep_consts.has("TEAM_WAIT_HINT_SEC"),
		"wait_hint_removed", "TEAM_WAIT_HINT_SEC 已废除，不应残留")
	var net_script: GDScript = load("res://scripts/autoload/NetworkService.gd")
	var net_consts: Dictionary = net_script.get_script_constant_map()
	h.expect(float(net_consts.get("BOARD_SUBMIT_TIMEOUT_SEC", -1.0)) == 30.0,
		"board_timeout_const", "NetworkService.BOARD_SUBMIT_TIMEOUT_SEC == 30.0（看门狗代交/转 AI 的时长）")
	h.expect(NetworkService.has_method("clear_last_team_submission"),
		"clear_api", "NetworkService.clear_last_team_submission() 存在（取消准备时客户端调）")
	# 源码接线断言：防止将来回滚时只回滚一半
	var flow := FileAccess.get_file_as_string("res://scenes/prep/PrepFlowController.gd")
	h.expect(flow.contains("team_submit_board(NetProtocol.team_board_submission"),
		"client_submit_wired", "PrepFlowController 在发 ready 之前提交棋盘")
	h.expect(flow.count("clear_last_team_submission()") == 2,
		"client_clear_wired", "取消准备两处（_on_start_battle / _mark_online_board_changed）都清缓存")
	var screen := FileAccess.get_file_as_string("res://scenes/prep/PrepScreen.gd")
	h.expect(screen.contains("not GameState.team_mode"),
		"no_prep_window_guard", "PrepScreen 备战路径（team_mode）不开战斗准备窗口")
	h.expect(not screen.contains("wait_team_server") and not screen.contains("_update_team_wait_status"),
		"wait_status_removed", "等待态刷新链路已随窗口废除，不应残留")
	var net_src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	h.expect(net_src.contains("not in [ROOM_BATTLE, ROOM_PREP]"),
		"server_prep_accepts", "服务端 _rpc_team_submit_board 接受 PREP 阶段提交")
	h.expect(net_src.contains("if boards.has(slot) and str(room.get(\"state\", ROOM_LOBBY)) != ROOM_PREP:"),
		"server_prep_overwrite", "PREP 允许覆盖、BATTLE 拒重复")


# --- 第二节：loopback 真实 RPC --------------------------------------------------

func _exercise() -> void:
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	if not h.expect(transport.create_server(0, 8) == OK, "server_socket", "Loopback server opens"):
		return
	port = transport.host.get_local_port()
	server = endpoint("Server", transport)
	server.enter_test_server_mode()
	server.multiplayer.peer_disconnected.connect(server._on_peer_disconnected)
	var a := add_client(0)
	var b := add_client(1)
	clients.append(a)
	clients.append(b)
	if not await _wait_peers(server, 2):
		return
	var a_id: int = a.multiplayer.get_unique_id()
	var b_id: int = b.multiplayer.get_unique_id()
	var room: Dictionary = server._new_room()
	room.state = server.ROOM_PREP
	room.round_index = 1
	room.peer_slot = {a_id: 0, b_id: 3}
	room.slot_states = ["player", "empty", "empty", "player", "empty", "empty"]
	room.ready = [false, false, false, false, false, false]
	server._peer_room[a_id] = int(room.id)
	server._peer_room[b_id] = int(room.id)
	server._peer_last_ping[a_id] = server._now()
	server._peer_last_ping[b_id] = server._now()

	# 场景 1：PREP 阶段提交被收下，并写 last_board 缓存
	a._rpc_team_submit_board.rpc_id(1, 0, _snap(10))
	await _settle()
	h.expect((room.get("boards", {}) as Dictionary).has(0),
		"prep_accepts", "PREP 阶段提交被服务端收下")
	h.expect((room.get("last_board", {}) as Dictionary).has(0),
		"prep_caches", "PREP 提交同时写 last_board 跨回合缓存")

	# 场景 2：PREP 允许覆盖（取消 → 调整 → 再准备 = 重新提交，以最后一次为准）
	a._rpc_team_submit_board.rpc_id(1, 0, _snap(20))
	await _settle()
	h.expect(int((room.boards[0] as Dictionary).get("gold", -1)) == 20,
		"prep_overwrite", "PREP 阶段允许覆盖， boards[0] 换成第二次那份")

	# 场景 3：取消准备 = 作废提交（boards 与 last_board 一起清）
	a._rpc_team_set_ready.rpc_id(1, 0, true)
	await _settle()
	h.expect(bool((room.ready as Array)[0]), "ready_set", "准备置位")
	a._rpc_team_set_ready.rpc_id(1, 0, false)
	await _settle()
	h.expect(not (room.get("boards", {}) as Dictionary).has(0),
		"cancel_clears_boards", "取消准备清掉已提交的棋盘")
	h.expect(not (room.get("last_board", {}) as Dictionary).has(0),
		"cancel_clears_cache", "取消准备连 last_board 缓存一起清（否则 30s 看门狗会把作废那份补交回来）")
	h.expect(not bool((room.ready as Array)[0]), "ready_cleared", "取消准备清 ready")

	# 场景 4：重新提交 → 掉线 → B 准备：boards 保留且 round start 不清
	a._rpc_team_submit_board.rpc_id(1, 0, _snap(30))
	await _settle()
	a._rpc_team_set_ready.rpc_id(1, 0, true)
	await _settle()
	h.expect((room.get("boards", {}) as Dictionary).has(0),
		"resubmit_after_cancel", "取消后重新准备会再交一份")
	# 掉线：真实断链检测由 mobile_reconnect_check 覆盖，这里直接走服务的断开入口
	server._on_peer_disconnected(a_id)
	await _settle()
	h.expect(str((room.slot_states as Array)[0]) == "player",
		"soft_remove", "掉线只软移除：座位仍是 player（保重连凭证）")
	h.expect((room.get("human_offline_since", {}) as Dictionary).has(0),
		"offline_marked", "记录 human_offline_since")
	h.expect((room.get("boards", {}) as Dictionary).has(0),
		"boards_survive_disconnect", "掉线不清棋盘")
	b._rpc_team_set_ready.rpc_id(1, 3, true)
	await _settle()
	h.expect(str(room.get("state", "")) == server.ROOM_BATTLE,
		"b_ready_starts_round", "B 准备即进 ROOM_BATTLE（A 的 ready 还是 true）")
	h.expect((room.get("boards", {}) as Dictionary).has(0),
		"round_start_keeps_boards", "_room_maybe_start_round 不再清 boards：PREP 提交带进 finalize")

	# 场景 5：BATTLE 阶段一回合一份（独立房间，避开场景 4 的 finalize）
	var room2: Dictionary = server._new_room()
	room2.state = server.ROOM_BATTLE
	room2.round_index = 1
	room2.peer_slot = {b_id: 3}
	room2.slot_states = ["player", "empty", "empty", "player", "empty", "empty"]
	room2.ready = [false, false, false, true, false, false]
	server._peer_room[b_id] = int(room2.id)
	server._peer_last_ping[b_id] = server._now()
	b._rpc_team_submit_board.rpc_id(1, 3, _snap(40))
	await _settle()
	var boards2: Dictionary = room2.get("boards", {}) as Dictionary
	h.expect(boards2.has(3),
		"battle_accepts", "BATTLE 阶段首份提交被收下")
	var gold_before: int = int((boards2.get(3, {}) as Dictionary).get("gold", -1))
	b._rpc_team_submit_board.rpc_id(1, 3, _snap(50))
	await _settle()
	h.expect(int(((room2.get("boards", {}) as Dictionary).get(3, {}) as Dictionary).get("gold", -1)) == gold_before,
		"battle_rejects_duplicate", "BATTLE 阶段重复提交被拒（一回合一份）")


func _snap(gold: int) -> Dictionary:
	var board := Fixture.board_from_ids(Fixture.lineup("a")[0])
	var snap: Dictionary = Fixture.board_submission(board, Fixture.empty_mercenary_slots())
	snap["round"] = 1
	snap["gold"] = gold
	return snap


func _settle() -> void:
	# ENet loopback 的 reliable RPC 需要若干帧才到达（round start 后客户端有信号处理，多等）
	for _i in 60:
		await get_tree().process_frame


func _wait_peers(node: Node, count: int) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while node.multiplayer.get_peers().size() < count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return h.expect(node.multiplayer.get_peers().size() >= count,
		"both_connected", "Server sees both clients")
