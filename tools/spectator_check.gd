extends Node

# 门禁：观战席位（协议 44，scripts/multiplayer/SpectatorService.gd，2026-10-22 定稿）。
#
# 每条断言对着一条和用户逐条定下的规则，失败时都**不报错**，只会悄悄开洞：
#   * 观战者拿到私有字段（金币、账本、宝物候选、重连 token）—— 等于看选手底牌；
#   * 观战者看到本回合的棋盘 —— 「延迟一回合」白做，选手点了准备棋盘就已经在服务器上了；
#   * 观战者的话传到选手那里 / 观战者看到队内聊天 —— 场外报信绕过延迟；
#   * 游客能发言 —— 没有账号就没有举报和封禁的抓手；
#   * 观战者占座位、算在线人数 —— 只剩观战者的房间不转 suspended、永不回收；
#   * 第 11 个观战者能进 / 房主关了观战旧人还在 / 被踢了还在列表里；
#   * 选手能起身去观战（定了不可以）；观战者坐下后还留在观战席上（同一连接两份身份）；
#   * 掉线 / 僵尸 / 关房后观战映射不清 —— 观战位被死连接占满；
#   * 备战区不合法就拒整份棋盘 —— 显示用的字段让人这回合交不了棋盘。
#
# 走的是真实的 NetworkService 代码（传输打桩，同 tools/seat_identity_check.gd 的 TestServer）。

const Harness := preload("res://tools/CheckHarness.gd")
const SpectatorService := preload("res://scripts/multiplayer/SpectatorService.gd")
const DedicatedServerService := preload("res://scripts/multiplayer/DedicatedServerService.gd")

const LEADER := 100
const PLAYER_B := 103
const MARKER_UID := "spectator-check-current-round-marker"

# 选手 room_state 里有、观战者绝不能有的字段（_build_room_state 里「本座位」那几段）。
const PRIVATE_KEYS := [
	"gold", "economy", "session_token", "public_id", "owned_treasures", "treasure_offer",
	"my_races", "altar_uses", "my_slot", "completed_settlement", "team_clearance_sale",
]

var h := Harness.new("spectator")


class TestServer extends "res://scripts/autoload/NetworkService.gd":
	var live := {}
	var room_states := []      # [peer, payload]
	var spectate_states := []  # [peer, payload]
	var views := []            # [peer, view]
	var match_state_sends := []
	var replays := []          # [peer, battle_id, own, rival]
	var fails := []            # [peer, reason]
	var ended := []            # [peer, reason]
	var chats := []            # [peer, sid, phrase_id, text]
	func _ready() -> void:
		_reconnect_service.configure(_now, _net_log, {})
		_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {}, _reconnect_service)
		_match_state.configure(_now)
	func _process(_delta: float) -> void:
		pass
	func _peer_connected(pid: int) -> bool:
		return live.has(pid)
	func _send_room_state(room: Dictionary, peer: int, _seq: int) -> void:
		var slot := int((room.get("peer_slot", {}) as Dictionary).get(peer, -1))
		if slot >= 0:
			room_states.append([peer, _build_room_state(room, slot)])
	func _send_spectate_state(room: Dictionary, peer: int, _seq: int) -> void:
		var sid := SpectatorService.sid_of_peer(room, peer)
		if sid >= 0:
			spectate_states.append([peer, _build_spectate_state(room, sid)])
	func _spectate_deliver_view(peer: int, view: Dictionary) -> void:
		views.append([peer, view])
	func _spectate_deliver_match_states(peer: int, battle_id: String, states: Dictionary) -> void:
		match_state_sends.append([peer, battle_id, states])
	func _send_replay_to_peer(peer: int, battle_id: String, own: PackedByteArray, rival: PackedByteArray) -> void:
		replays.append([peer, battle_id, own, rival])
	func _spectate_fail(peer: int, reason: String) -> void:
		fails.append([peer, reason])
	func _spectate_notify_ended(peer: int, reason: String) -> void:
		ended.append([peer, reason])
	func _spectate_deliver_chat(peer: int, sid: int, _identity: Dictionary, phrase_id: int, text: String) -> void:
		chats.append([peer, sid, phrase_id, text])
	# 带名片的观战者：门禁里不验签，"CARD:<名字>" 就当一张验过的名片。
	func _accept_seat_card(_sender: int, card_text: String) -> Dictionary:
		var name := card_text.trim_prefix("CARD:")
		return {"pid": "pid-" + name, "code": "AB%06d" % (name.hash() % 1000000), "name": name}
	func _voice_seat_released(_room: Dictionary, _slot: int, _identity: String) -> void:
		pass
	func _voice_rooms_closed(_room: Dictionary) -> void:
		pass
	func reset_capture() -> void:
		for a in [room_states, spectate_states, views, match_state_sends, replays, fails, ended, chats]:
			(a as Array).clear()
	func last_fail(peer: int) -> String:
		for i in range(fails.size() - 1, -1, -1):
			if int(fails[i][0]) == peer:
				return str(fails[i][1])
		return ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var server := TestServer.new()
	add_child(server)
	_case_guest_joins_without_seat(server)
	_case_spectator_state_is_public(server)
	_case_cap_ten(server)
	_case_seated_player_cannot_spectate(server)
	_case_kick_and_close(server)
	_case_spectator_sits_down(server)
	_case_disconnect_and_zombie(server)
	_case_chat_isolation(server)
	_case_view_is_one_round_late(server)
	_case_mid_battle_join_gets_replay(server)
	_case_room_close_notifies(server)
	_case_room_list(server)
	_case_not_persisted()
	_case_bench_snapshot()
	server.queue_free()
	h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

# 房主坐 0 号（红队第一个座位），另一个人坐 3 号（蓝队）。
func _room(server: TestServer, state: String = "lobby") -> Dictionary:
	var room: Dictionary = server._new_room()
	var states: Array = room.slot_states
	states[0] = "player"
	states[3] = "player"
	room.slot_states = states
	room.peer_slot = {LEADER: 0, PLAYER_B: 3}
	room.leader_slot = 0
	room.state = state
	server._peer_room[LEADER] = int(room.id)
	server._peer_room[PLAYER_B] = int(room.id)
	return room


func _join(server: TestServer, room: Dictionary, peer: int, card: String = "") -> void:
	server.live[peer] = true
	server._spectate_join(peer, int(room.id), card)


func _all_text(value: Variant) -> String:
	return var_to_str(value)


# --- 用例 ---------------------------------------------------------------------

func _case_guest_joins_without_seat(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server)
	var seats_before: Dictionary = (room.peer_slot as Dictionary).duplicate()
	var online_before: int = server._room_online_count(room)
	# 房主在线才收得到广播（_broadcast_room_lobby 只发给连着的人）。
	server.live[LEADER] = true
	_join(server, room, 501)
	server.live.erase(LEADER)
	h.expect(SpectatorService.count(room) == 1 and int(server._peer_spectate.get(501, 0)) == int(room.id),
		"guest_not_listed", "没带名片（游客）也要能进观战，并且出现在观战列表里")
	h.expect(not (room.peer_slot as Dictionary).has(501) and not server._peer_room.has(501),
		"spectator_took_seat", "观战者进了 peer_slot / _peer_room —— 他会被当成选手，买卖、交棋盘、语音钥匙都对他开放")
	h.expect(room.peer_slot == seats_before and server._room_online_count(room) == online_before,
		"spectator_counted_online", "观战者不能算在线人数：只剩观战者的房间必须照常转 suspended")
	var entry := SpectatorService.entry_of_peer(room, 501)
	h.expect(bool(entry.get("guest", false)) and not SpectatorService.can_chat(entry),
		"guest_can_chat", "游客只能看、不能发言（2026-10-22 定）")
	# 进门这一轮就该拿到第一份观战状态，选手那边也要刷新（观战列表多一行）。
	var got_state := false
	for row in server.spectate_states:
		got_state = got_state or int(row[0]) == 501
	h.expect(got_state, "no_initial_state", "进观战后没有收到第一份观战状态")
	var player_saw_list := false
	for row in server.room_states:
		if int(row[0]) == LEADER:
			player_saw_list = ((row[1] as Dictionary).get("spectators", []) as Array).size() == 1
	h.expect(player_saw_list, "players_miss_list", "选手的 room_state 里要有观战列表（大厅左侧那一栏）")
	SpectatorService.remove_peer(room, 501)
	server._peer_spectate.erase(501)


func _case_spectator_state_is_public(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server, "prep")
	room.slot_gold = [77, 6, 6, 88, 6, 6]
	room.seat_tokens = {0: "secret-token-0", 3: "secret-token-3"}
	_join(server, room, 502, "CARD:Watcher")
	var payload: Dictionary = {}
	for row in server.spectate_states:
		if int(row[0]) == 502:
			payload = row[1]
	h.expect(not payload.is_empty(), "no_state", "拿不到观战状态")
	for key in PRIVATE_KEYS:
		h.expect(not payload.has(key), "private_field_leaked:" + key,
			"观战状态里出现了「本座位」私有字段 %s —— 那是按座位给选手的，观战者看到等于看底牌" % key)
	var text := _all_text(payload)
	h.expect(not text.contains("secret-token"), "token_leaked", "观战状态里出现了选手的重连 token")
	# 公开列表里绝不能有连接号：peer_id 是连接层的东西，不该发给任何客户端。
	for row in SpectatorService.public_list(room):
		h.expect(not (row as Dictionary).has("peer") and not _all_text(row).contains("502"),
			"peer_id_leaked", "观战列表里出现了连接号 peer_id")
	h.expect(bool(payload.get("can_chat", false)) and int(payload.get("my_sid", -1)) >= 1,
		"carded_cannot_chat", "带名片的观战者应当能发言、并拿到自己的观战编号")
	h.expect((payload.get("team_hp", []) as Array).size() == 2,
		"team_hp_shape", "观战者没有「己方」，两队血量都要给")
	SpectatorService.remove_peer(room, 502)
	server._peer_spectate.erase(502)


func _case_cap_ten(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server)
	for i in SpectatorService.MAX_SPECTATORS:
		_join(server, room, 600 + i)
	h.expect(SpectatorService.count(room) == 10, "cap_not_reached", "前 10 个观战者都应该进得去")
	_join(server, room, 699)
	h.expect(SpectatorService.count(room) == 10 and server.last_fail(699) == "spectate_full",
		"cap_exceeded", "第 11 个观战者必须被拒（spectate_full），观战席最多 10 人")
	# 同一条连接重复进同一间：不占第二个位子。
	server.live.erase(699)
	_join(server, room, 600)
	h.expect(SpectatorService.count(room) == 10, "duplicate_join_takes_two", "同一连接重复进观战占了两个位子")
	for i in SpectatorService.MAX_SPECTATORS:
		server._spectate_detach(600 + i)
	h.expect(SpectatorService.count(room) == 0, "detach_incomplete", "离开观战后列表没有清空")


func _case_seated_player_cannot_spectate(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server)
	var other := _room(server)
	server._spectate_join(PLAYER_B, int(other.id), "")
	h.expect(SpectatorService.count(other) == 0 and server.last_fail(PLAYER_B) == "spectate_seated",
		"seated_player_spectates", "坐着的选手不能起身去观战（2026-10-22 定）")
	h.expect(int((room.peer_slot as Dictionary).get(PLAYER_B, -1)) == 3,
		"seat_lost", "被拒的观战请求不能动他原来的座位")


func _case_kick_and_close(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server, "prep")
	_join(server, room, 701, "CARD:A")
	_join(server, room, 702, "CARD:B")
	var sid_a := SpectatorService.sid_of_peer(room, 701)
	# 非房主踢人无效。
	server._spectate_kick(PLAYER_B, sid_a)
	h.expect(SpectatorService.count(room) == 2, "non_leader_kicks", "只有房主能踢观战者")
	server._spectate_kick(LEADER, sid_a)
	h.expect(SpectatorService.sid_of_peer(room, 701) < 0 and not server._peer_spectate.has(701),
		"kick_ignored", "房主踢掉的观战者还在列表 / 映射里")
	h.expect(server.ended.has([701, "spectate_kicked"]), "kick_not_notified", "被踢的观战者要收到通知")
	# 非房主关观战无效；房主关观战 = 现有观战者全部请出去 + 新人进不来。
	server._spectate_set_open(PLAYER_B, false)
	h.expect(SpectatorService.is_open(room), "non_leader_closes", "只有房主能关观战")
	server._spectate_set_open(LEADER, false)
	h.expect(not SpectatorService.is_open(room) and SpectatorService.count(room) == 0
		and server.ended.has([702, "spectate_closed"]),
		"close_keeps_old", "房主关观战后，已经在看的人也必须被请出去（只挡新人房主会以为没人在看）")
	_join(server, room, 703)
	h.expect(SpectatorService.count(room) == 0 and server.last_fail(703) == "spectate_closed",
		"closed_room_admits", "关了观战的房间还能进")
	server._spectate_set_open(LEADER, true)
	_join(server, room, 703)
	h.expect(SpectatorService.count(room) == 1, "reopen_fails", "重新打开观战后应能再进")
	server._spectate_detach(703)


func _case_spectator_sits_down(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server)
	_join(server, room, 801, "CARD:Sitter")
	# 入座路径（_rpc_team_join_room 最后调的就是它）。不标在线，免得打桩外的遗留 rpc 真发出去。
	server.live.erase(801)
	server._assign_peer_to_room(801, room, "", {})
	h.expect((room.peer_slot as Dictionary).has(801), "sit_failed", "观战者在大厅点空位应能坐下")
	h.expect(SpectatorService.sid_of_peer(room, 801) < 0 and not server._peer_spectate.has(801),
		"double_identity", "坐下之后还留在观战席上：同一条连接会同时收到选手和观战两份状态、还占一个观战位")
	server._room_remove_peer(room, 801)
	server._peer_room.erase(801)


func _case_disconnect_and_zombie(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server, "battle")
	_join(server, room, 901)
	_join(server, room, 902)
	server._on_peer_disconnected(901)
	h.expect(SpectatorService.sid_of_peer(room, 901) < 0 and not server._peer_spectate.has(901),
		"disconnect_keeps_spectator", "观战者掉线后还占着观战位（观战者没有座位可保留，掉线就是离开）")
	# 僵尸：ENet 丢了但没走掉线回调。
	server.live.erase(902)
	server._reap_zombie_peers()
	h.expect(SpectatorService.sid_of_peer(room, 902) < 0 and not server._peer_spectate.has(902),
		"zombie_keeps_spectator", "僵尸观战连接没被清道夫回收 —— 10 个位子会被死连接慢慢占满")


func _case_chat_isolation(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server, "prep")
	_join(server, room, 1001, "CARD:Talker")
	_join(server, room, 1002)   # 游客
	server._spectate_chat(1002, -1, "hello from guest")
	h.expect(server.chats.is_empty(), "guest_spoke", "游客发言被转发了（游客只能看，2026-10-22 定）")
	server._spectate_chat(1001, -1, "hi spectators")
	var receivers := []
	for row in server.chats:
		receivers.append(int(row[0]))
	receivers.sort()
	h.expect(receivers == [1001, 1002], "spectator_chat_recipients",
		"观战者的话只发给观战者（含自己），实际收件人 %s" % str(receivers))
	h.expect(not receivers.has(LEADER) and not receivers.has(PLAYER_B),
		"spectator_reached_player", "观战者的话传到了选手那里 —— 场外报信，延迟一回合就白做了")
	server.chats.clear()
	server._spectate_chat(1001, 9999, "")
	h.expect(server.chats.is_empty(), "bad_phrase_forwarded", "不存在的快捷短语也被转发了")
	# 选手 → 观战者：只有全体聊天。
	var team_only: Array = server.spectator_chat_recipients(room, true)
	var all_chat: Array = server.spectator_chat_recipients(room, false)
	h.expect(team_only.is_empty(), "team_chat_to_spectators", "队内聊天传给了观战者（定了只看全体聊天）")
	all_chat.sort()
	h.expect(all_chat == [1001, 1002], "all_chat_missing", "选手的全体聊天观战者应当看得到")
	# 三条选手聊天入口都必须接上观战收件人（代码形状，不是注释）。
	var src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	h.expect(src.count("chat_recipients(room, slot, team_only) + spectator_chat_recipients(room, team_only):") == 3,
		"player_chat_not_wired", "短语 / 文字 / 语音三条选手聊天转发里，应有三处同时转给观战者")
	server._spectate_detach(1001)
	server._spectate_detach(1002)


func _case_view_is_one_round_late(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server, "prep")
	room.round_index = 3
	# 本回合（3）选手已经点了准备：棋盘在 room.boards 和 last_board 里。观战者绝不能看到它。
	var current := {"board": [{"id": "x", "uid": MARKER_UID}], "bench": [{"uid": MARKER_UID}], "gold": 41}
	room.boards = {0: current}
	room.last_board = {0: current}
	room.battle_loadouts = {0: current}
	_join(server, room, 1101)
	h.expect(not _all_text(server.views).contains(MARKER_UID) and not _all_text(server.spectate_states).contains(MARKER_UID),
		"current_round_leaked", "观战者看到了本回合的棋盘（room.boards / last_board）—— 延迟一回合失效")
	h.expect(server.views.is_empty(), "view_before_any_battle", "还没打过任何一场时不该有阵容可看（第 1 回合是 loading）")
	# 第 2 回合那场发布时冻结的阵容，才是第 3 回合备战期该看的。
	var played := {"board": [{"id": "y", "uid": "played-r2"}], "bench": [{"id": "z", "uid": "bench-r2"}],
		"mercenaries": [], "treasures": ["t1"], "syn": {}, "gold": 12}
	var ai := {"board": [{"id": "ai"}], "mercenaries": [], "treasures": [], "is_ai": true}
	SpectatorService.freeze_view(room, 2, "room:2:9", {0: played, 1: ai})
	server.reset_capture()
	server._spectate_send_round(room, 1101)
	var view: Dictionary = server.views[0][1] if not server.views.is_empty() else {}
	var seat0: Dictionary = (view.get("seats", {}) as Dictionary).get(0, {})
	h.expect(int(view.get("round", 0)) == 2 and _all_text(seat0).contains("played-r2"),
		"frozen_view_missing", "上一回合冻结的阵容没发给观战者")
	h.expect(_all_text(seat0.get("bench", [])).contains("bench-r2") and int(seat0.get("gold", -1)) == 12,
		"bench_or_gold_missing", "延迟阵容里要有备战区和金币（和选手界面同一批，商店除外）")
	h.expect(not seat0.has("shop") and not _all_text(view).contains(MARKER_UID),
		"view_has_current_or_shop", "延迟阵容里出现了商店或本回合的棋盘")
	h.expect(bool(((view.get("seats", {}) as Dictionary).get(1, {}) as Dictionary).get("is_ai", false)),
		"ai_seat_missing", "AI 座位也要有可看的阵容（取自 battle_loadouts）")
	# 冻结点必须在战斗结果发布里、取 battle_loadouts（代码形状，限定在函数体里）。
	var src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	var body := _fn_body(src, "func _room_publish_replays(room: Dictionary, job: RefCounted) -> void:")
	h.expect(body.contains("SpectatorService.freeze_view(room, int(job.round_index)") and body.contains("room.get(\"battle_loadouts\", {}))"),
		"freeze_point_moved", "冻结阵容必须发生在战斗结果发布时、取这一场的 battle_loadouts")
	for fn in ["func _build_spectate_state(room: Dictionary, sid: int) -> Dictionary:",
			"func _spectate_send_round(room: Dictionary, peer_id: int) -> void:"]:
		var fbody := _fn_body(src, fn)
		h.expect(not fbody.is_empty() and not fbody.contains("\"boards\"") and not fbody.contains("\"last_board\""),
			"spectator_reads_live_boards", "%s 读了 boards / last_board —— 那是本回合的" % fn)
	server._spectate_detach(1101)


func _case_mid_battle_join_gets_replay(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server, "result")
	room.battle_id = "x:5:1"
	room.last_match_state = {0: {"completed_round": 5}, 3: {"completed_round": 5}}
	room.replay_packed = {"a": PackedByteArray([1, 2, 3]), "b": PackedByteArray([4, 5, 6])}
	_join(server, room, 1201)
	h.expect(server.replays.size() == 1 and server.replays[0][2] == PackedByteArray([1, 2, 3])
		and server.replays[0][3] == PackedByteArray([4, 5, 6]),
		"mid_battle_no_replay", "战斗中进来的观战者要拿到这场两队的回放（红队 own、蓝队 rival，从头播）")
	h.expect(server.match_state_sends.size() == 1 and (server.match_state_sends[0][2] as Dictionary).size() == 2,
		"mid_battle_no_settlement", "结算阶段进来的观战者要拿到各座位的结算（界面按选中的选手显示）")
	server._spectate_detach(1201)
	# 备战期进来不补回放（上一场的回放已经过期）。
	server.reset_capture()
	var prep := _room(server, "prep")
	prep.replay_packed = {"a": PackedByteArray([1]), "b": PackedByteArray([2])}
	_join(server, prep, 1202)
	h.expect(server.replays.is_empty(), "prep_replay_sent", "备战期进来的观战者不该收到回放")
	server._spectate_detach(1202)


func _case_room_close_notifies(server: TestServer) -> void:
	server.reset_capture()
	var room := _room(server, "prep")
	_join(server, room, 1301)
	server._room_close(room, "test_close")
	h.expect(server.ended.has([1301, "room_closed"]) and not server._peer_spectate.has(1301)
		and SpectatorService.count(room) == 0,
		"close_leaves_spectator", "关房时观战者要被告知、映射要清掉")


func _case_room_list(server: TestServer) -> void:
	for room in server._rooms.values():
		room.state = "closed"
	var lobby := _room(server, "lobby")
	var running := _room(server, "prep")
	var shut := _room(server, "battle")
	shut[SpectatorService.KEY_OPEN] = false
	var rows: Array = server._room_list_with_spectate()
	var by_id := {}
	for row in rows:
		by_id[int(row.id)] = row
	h.expect(by_id.has(int(lobby.id)) and bool(by_id[int(lobby.id)].get("joinable", false)),
		"lobby_not_joinable", "大厅里有空位的房间在列表里应是可加入的")
	h.expect(by_id.has(int(running.id)) and not bool(by_id[int(running.id)].get("joinable", true)),
		"running_not_spectatable", "已开局的房间要出现在列表里（只能观战）")
	h.expect(not by_id.has(int(shut.id)), "closed_spectate_listed", "关了观战的已开局房间不该出现在观战列表里")


func _case_not_persisted() -> void:
	for key in [SpectatorService.KEY_LIST, SpectatorService.KEY_NEXT_SID, SpectatorService.KEY_OPEN, SpectatorService.KEY_VIEW]:
		h.expect(not DedicatedServerService.PERSISTED_ROOM_FIELDS.has(key), "persisted:" + key,
			"观战字段 %s 进了持久化白名单 —— 重启后会读回一批早已断开的观战者" % key)


func _case_bench_snapshot() -> void:
	var saved_bench: Array = GameState.bench_slots.duplicate(true)
	var saved_board: Array = GameState.board_slots.duplicate(true)
	var unit_id := ""
	for row in (DataRegistry.get_table("race_units").get("units", []) as Array):
		unit_id = str((row as Dictionary).get("id", ""))
		if not unit_id.is_empty():
			break
	GameState.bench_slots.fill(null)
	GameState.bench_slots[2] = {"id": unit_id, "uid": "bench-u1", "star": 2}
	var snap := NetProtocol.team_board_submission(GameState.board_slots)
	h.expect((snap.get("bench", []) as Array).size() == 1, "bench_not_submitted", "提交的棋盘快照里要带备战区")
	var ok := NetProtocol.validate_team_snapshot(snap, GameState.round_index)
	var bench: Array = (ok.get("snapshot", {}) as Dictionary).get("bench", [])
	h.expect(bool(ok.get("ok", false)) and bench.size() == GameState.BENCH_SLOTS
		and typeof(bench[2]) == TYPE_DICTIONARY and str(bench[2].get("uid", "")) == "bench-u1",
		"bench_lost_in_validation", "服务端校验后备战区丢了或位置错了")
	# 不合法的备战区：丢掉备战区，**不拒整份棋盘**（显示用字段不能让人交不了棋盘）。
	snap["bench"] = [{"slot": 99, "id": unit_id}]
	var bad := NetProtocol.validate_team_snapshot(snap, GameState.round_index)
	var bad_bench: Array = (bad.get("snapshot", {}) as Dictionary).get("bench", [null])
	h.expect(bool(bad.get("ok", false)) and bad_bench.count(null) == bad_bench.size(),
		"bad_bench_rejects_board", "备战区不合法时应丢掉备战区、照收棋盘")
	snap.erase("bench")
	h.expect(bool(NetProtocol.validate_team_snapshot(snap, GameState.round_index).get("ok", false)),
		"missing_bench_rejected", "没有备战区字段的快照（旧形状 / 门禁手搓）也要能收")
	GameState.bench_slots = saved_bench
	GameState.board_slots = saved_board


# 取函数体（到下一个顶格 func 为止）。断言限定在函数体里，免得被注释满足。
func _fn_body(src: String, header: String) -> String:
	var start := src.find(header)
	if start < 0:
		return ""
	var stop := src.find("\nfunc ", start + header.length())
	return src.substr(start, (stop - start) if stop > 0 else -1)
