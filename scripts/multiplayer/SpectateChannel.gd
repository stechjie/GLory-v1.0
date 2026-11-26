extends RefCounted

# 观战通道：从 NetworkService 里搬出来的观战**服务端流程**（2026-11-24 起，分步搬）。
#
# 分工（三层）：
#   * SpectatorService.gd —— 纯数据规则：观战者表怎么增删、给观战者看什么。不碰网络、不碰房间表。
#   * 本文件 —— 流程：谁能踢谁、关观战要清谁、进房要查什么。要读写 NetworkService 的
#     房间表和连接表，所以每个函数第一个参数都是 net（NetworkService 自己）。
#   * NetworkService.gd —— 只剩 @rpc 入口（取 sender、限流）和一行转调。RPC 留在那里是故意的：
#     Godot 的 RPC 按节点路径配对，搬走就要客户端服务器一起升协议；留着就什么都不用升。
#
# 为什么是 RefCounted 而不是子节点：同 RoomService —— 不占场景树、门禁能直接 new；
# 而且 tools/spectator_check.gd 是继承 NetworkService 来打桩的（覆写 _spectate_fail 这类出口），
# 所以这里**所有出口都走 net._spectate_xxx**，不直接 rpc，打桩才接得住。
#
# 不用 class_name：理由同 RoomService（make_server_zip.ps1 打包的全局类缓存）。
#
# 搬迁进度（每搬一块跑一次 tools/跑观战门禁.bat）：
#   [x] 第 1 块：房主管理 —— kick / set_open / sender_is_leader
#   [x] 第 2 块：聊天 —— chat
#   [x] 第 3 块：进出 —— join / detach / end / remove_account_spectators
#   [x] 第 4 块：下发 —— build_state / send_round / room_list（send_state 留在 NetworkService：直接 rpc_id，门禁覆写）

const SpectatorService := preload("res://scripts/multiplayer/SpectatorService.gd")
const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")
const ChatText := preload("res://scripts/multiplayer/ChatText.gd")
const BattleCard := preload("res://scripts/multiplayer/BattleCard.gd")
const PrepDeadline := preload("res://scripts/rounds/PrepDeadline.gd")


# --- 第 1 块：房主管理 -----------------------------------------------------------

static func sender_is_leader(room: Dictionary, sender: int) -> bool:
	return not room.is_empty() \
		and int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) == int(room.get("leader_slot", 0))


# 房主踢一个观战者。sid 不在表里就当没发生（客户端列表可能已经过期）。
static func kick(net: Node, sender: int, sid: int) -> void:
	var room: Dictionary = net._room_for_peer(sender)
	if not sender_is_leader(room, sender):
		return
	var spectators := SpectatorService.list(room)
	if not spectators.has(sid):
		return
	net._spectate_end(room, int((spectators[sid] as Dictionary).get("peer", 0)), "spectate_kicked")
	net._broadcast_room_lobby(room)


# 房主开 / 关本房间观战。
# 关观战 = 现有观战者全部请出去。只挡新人不清旧人，房主会以为没人在看。
static func set_open(net: Node, sender: int, open: bool) -> void:
	var room: Dictionary = net._room_for_peer(sender)
	if not sender_is_leader(room, sender):
		return
	room[SpectatorService.KEY_OPEN] = open
	if not open:
		for peer_id in SpectatorService.peers(room):
			net._spectate_end(room, peer_id, "spectate_closed")
	net._touch_room(room)
	net._broadcast_room_lobby(room)


# --- 第 2 块：聊天 -----------------------------------------------------------------

# 观战者发言。游客不能发言（没有账号 = 举报和封禁都没有抓手）；客户端也挡了，这里是权威的那道。
# 开局前（ROOM_LOBBY）整间房共用聊天，发给观战席 + 座位；开局后观战者对谁都不能说（场外报信）。
static func chat(net: Node, sender: int, phrase_id: int, text: String) -> void:
	var room: Dictionary = net._rooms.get(int(net._peer_spectate.get(sender, 0)), {})
	var entry := SpectatorService.entry_of_peer(room, sender)
	if str(room.get("state", "")) != net.ROOM_LOBBY or not SpectatorService.can_chat(entry):
		return
	var clean := ""
	if phrase_id < 0:
		clean = ChatText.clean(text)
		if clean.is_empty():
			return
	elif not ChatPhrases.is_valid_id(phrase_id) or not text.is_empty():
		return
	var sid := SpectatorService.sid_of_peer(room, sender)
	var identity: Dictionary = entry.get("identity", {})
	for peer_id in SpectatorService.peers(room) + (room.get("peer_slot", {}) as Dictionary).keys():
		if net._peer_connected(int(peer_id)):
			net._spectate_deliver_chat(int(peer_id), sid, identity, phrase_id, clean)


# --- 第 3 块：进出 -----------------------------------------------------------------

static func remove_account_spectators(net: Node, room: Dictionary, account_pid: String, code: String, keep_peer: int = -1) -> void:
	for peer_id in SpectatorService.peers(room):
		if peer_id == keep_peer:
			continue
		var entry := SpectatorService.entry_of_peer(room, peer_id)
		var same_pid := not account_pid.is_empty() and str(entry.get("account_pid", "")) == account_pid
		var same_code := not code.is_empty() and str((entry.get("identity", {}) as Dictionary).get("friend_code", "")) == code
		if same_pid or same_code:
			if peer_id == keep_peer:
				continue
			end(net, room, peer_id, "spectate_replaced")


static func join(net: Node, sender: int, room_id: int, card: String) -> void:
	var seated_room: Dictionary = net._room_for_peer(sender)
	if not seated_room.is_empty() and (int(seated_room.get("id", 0)) != room_id or str(seated_room.get("state", "")) != net.ROOM_LOBBY):
		net._spectate_fail(sender, "spectate_seated")
		return
	var room: Dictionary = net._rooms.get(room_id, {})
	if room.is_empty() or str(room.get("state", "")) == net.ROOM_CLOSED:
		net._spectate_fail(sender, "room_not_found")
		return
	# Completed rooms are retained for existing viewers, not new room discovery.
	if bool(room.get("run_over", false)) and SpectatorService.sid_of_peer(room, sender) < 0:
		net._spectate_fail(sender, "room_not_found")
		return
	# 名片可选：没有 = 游客。带了就必须是真的 —— 验不过说明客户端有问题，按原因拒，
	# 不能悄悄降级成游客（那样改包的人可以拿一张假名片换一个假名字进列表）。
	var identity := {}
	var account_pid := ""
	if not card.is_empty():
		var seat_card: Dictionary = net._accept_seat_card(sender, card)
		if seat_card.is_empty():
			return
		identity = net.get_script().public_seat_identity(BattleCard.profile_of(seat_card))
		account_pid = str(seat_card.get("pid", ""))
		if seated_room.is_empty() and net._restore_account_seat(sender, room, account_pid) >= 0:
			return
	if card.is_empty() and not seated_room.is_empty():
		var slot := int((room.get("peer_slot", {}) as Dictionary).get(sender, -1))
		account_pid = str((room.get("seat_pid", {}) as Dictionary).get(slot, ""))
		if not account_pid.is_empty():
			identity = net.get_script().public_seat_identity((room.get("seat_profiles", {}) as Dictionary).get(slot, {}))
	remove_account_spectators(net, room, account_pid, str(identity.get("friend_code", "")), sender)
	var associated: Dictionary = net._listed_spectator_peers(room)
	if not associated.has(sender) and associated.size() >= SpectatorService.MAX_SPECTATORS:
		net._spectate_fail(sender, "spectate_full")
		return
	if not SpectatorService.is_open(room):
		net._spectate_fail(sender, "spectate_closed")
		return
	# 换房观战：先离开原来的观战席（同一条连接只能看一间）。
	if int(net._peer_spectate.get(sender, 0)) != room_id:
		detach(net, sender)
	var result := SpectatorService.add(room, sender, identity, net._now(), account_pid)
	if not bool(result.get("ok", false)):
		net._spectate_fail(sender, str(result.get("reason", "spectate_failed")))
		return
	net._peer_spectate[sender] = room_id
	if not seated_room.is_empty():
		net._room_remove_peer(seated_room, sender)
	net._peer_last_ping[sender] = net._now()
	net._net_log("spectator joined room=%d peer=%d sid=%d guest=%s count=%d" % [
		room_id, sender, int(result.get("sid", -1)), str(identity.is_empty()), SpectatorService.count(room)])
	# 全房广播：选手大厅里的观战列表要多一行；新观战者自己也在这一轮里拿到第一份状态。
	net._broadcast_room_lobby(room)
	# 补发：上一回合的阵容；正处在结算阶段的话，再补这一场的结算和回放（从头播）。
	net._spectate_send_round(room, sender)

# 把一条连接从观战席上摘下来（主动离开、掉线、坐下、换房都走这里）。
# 房间还在就广播一次，让两边的观战列表少一行。返回是否真的摘了。
static func detach(net: Node, peer_id: int, keep_lobby_voice: bool = false) -> bool:
	if not net._peer_spectate.has(peer_id):
		return false
	var room_id := int(net._peer_spectate[peer_id])
	net._peer_spectate.erase(peer_id)
	var room: Dictionary = net._rooms.get(room_id, {})
	if room.is_empty():
		return true
	if net._voice_admin != null and bool(room.get("voice_used", false)) and not (keep_lobby_voice and str(room.get("state", "")) == net.ROOM_LOBBY):
		var old_sid := SpectatorService.sid_of_peer(room, peer_id)
		net._voice_admin.remove_participant(net.spectator_voice_room_name(room), net.get_script().spectator_voice_identity(SpectatorService.entry_of_peer(room, peer_id), old_sid, str(room.get("state", "")) == net.ROOM_LOBBY))
	if SpectatorService.remove_peer(room, peer_id).is_empty():
		return true
	net._net_log("spectator left room=%d peer=%d count=%d" % [room_id, peer_id, SpectatorService.count(room)])
	# Same-room seating detaches first, then immediately claims the seat.
	if not keep_lobby_voice and str(room.get("state", "")) == net.ROOM_LOBBY \
			and not bool(room.get("matched", false)) and net._room_player_count(room) == 0 \
			and SpectatorService.count(room) == 0:
		net._room_close(room, "empty_no_tokens")
		net._rooms.erase(room_id)
		return true
	if str(room.get("state", "")) != net.ROOM_CLOSED:
		net._broadcast_room_lobby(room)
	return true

# 服务器请观战者离开（被踢、房主关了观战、房间关了）。**不广播** —— 调用方处理完一批再广播一次。
static func end(net: Node, room: Dictionary, peer_id: int, reason: String) -> void:
	if net._voice_admin != null and bool(room.get("voice_used", false)):
		var sid := SpectatorService.sid_of_peer(room, peer_id)
		net._voice_admin.remove_participant(net.spectator_voice_room_name(room), net.get_script().spectator_voice_identity(SpectatorService.entry_of_peer(room, peer_id), sid, str(room.get("state", "")) == net.ROOM_LOBBY))
	SpectatorService.remove_peer(room, peer_id)
	net._peer_spectate.erase(peer_id)
	net._replay_forget_peer(peer_id)
	if net._peer_connected(peer_id):
		net._spectate_notify_ended(peer_id, reason)
	net._net_log("spectator ended room=%d peer=%d reason=%s" % [int(room.get("id", 0)), peer_id, reason])


# --- 第 4 块：下发 -----------------------------------------------------------------

static func build_state(net: Node, room: Dictionary, sid: int) -> Dictionary:
	var hp: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	# 回合号口径同 _build_room_state：结算阶段要报「即将开始的那一轮」。
	var round_id := int(room.get("round_index", 1))
	if str(room.get("state", "")) == net.ROOM_RESULT:
		round_id = mini(round_id + 1, int(net._room_final_round(room)))
	var replays: Dictionary = room.get("replay_packed", {})
	var replay_available := not (replays.get("a", PackedByteArray()) as PackedByteArray).is_empty() \
		and not (replays.get("b", PackedByteArray()) as PackedByteArray).is_empty()
	var entry: Dictionary = SpectatorService.list(room).get(sid, {})
	return {
		# --- 房间（与选手同一批公开字段）---
		"phase": str(room.get("state", net.ROOM_LOBBY)),
		"mode": str(room.get("mode", "custom")),
		"prep_seconds_left": PrepDeadline.remaining(room, float(net._now())),
		"round_id": round_id,
		"ruleset": str(room.get("ruleset", "normal")),
		"final_round": net._room_final_round(room),
		"battle_id": str(room.get("battle_id", "")),
		"battle_round": int(room.get("round_index", 1)),
		# 预载资源清单只在战斗计算期间有：那时所有棋盘都已锁定，提前给不泄露任何东西。
		"asset_prefetch": room.get("asset_prefetch", {}) if bool(room.get("replay_pending", false)) else {},
		"replay_pending": str(room.get("state", "")) == net.ROOM_BATTLE or bool(room.get("replay_pending", false)),
		"replay_available": replay_available,
		"replay_error": str(room.get("replay_error", "")),
		"leader_slot": int(room.get("leader_slot", 0)),
		"reconnecting_slots": net._room_reconnecting_slots(room),
		"slot_states": (room.get("slot_states", []) as Array).duplicate(),
		"seat_profiles": (room.get("seat_profiles", {}) as Dictionary).duplicate(true),
		"seat_pets": net._build_public_seat_pets(room),
		"seat_ai_skins": net._build_public_seat_ai_skins(room),
		"seat_ai_levels": net._build_public_seat_ai_levels(room),
		"ready":(room.get("ready", []) as Array).duplicate(),
		"suspended": bool(room.get("suspended", false)),
		"run_over": bool(room.get("run_over", false)),
		# 两队都给：观战者没有「己方」，界面按当前选中的选手决定哪边是己方。
		"team_hp": [int(hp[0]), int(hp[1])],
		"team_loss_streak": (room.get("team_loss_streak", [0, 0]) as Array).duplicate(),
		"pve_completed": int(room.get("pve_completed", 0)),
		"boss_completed": int(room.get("boss_completed", 0)),
		# --- 观战 ---
		"spectators": SpectatorService.public_list(room),
		"spectate_open": SpectatorService.is_open(room),
		"spectate_max": SpectatorService.MAX_SPECTATORS,
		"view_round": int(SpectatorService.current_view(room).get("round", 0)),
		# --- 本观战者 ---
		"my_sid": sid,
		"can_chat": str(room.get("state", "")) == net.ROOM_LOBBY and SpectatorService.can_chat(entry),
	}

# 一回合的观战数据：冻结的上一回合阵容；正处在结算阶段就再加本场的结算与回放。
# 战斗发布时对所有观战者调一次；中途进来的观战者进门时调一次（回放从头播）。
static func send_round(net: Node, room: Dictionary, peer_id: int) -> void:
	if not net._peer_connected(peer_id):
		return
	var view: Dictionary = SpectatorService.current_view(room)
	if not view.is_empty():
		net._spectate_deliver_view(peer_id, view)
	if str(room.get("state", "")) != net.ROOM_RESULT:
		return
	var battle_id := str(room.get("battle_id", ""))
	var match_states: Dictionary = room.get("last_match_state", {})
	if not match_states.is_empty():
		net._spectate_deliver_match_states(peer_id, battle_id, match_states)
	var packed: Dictionary = room.get("replay_packed", {})
	var packed_a: PackedByteArray = packed.get("a", PackedByteArray())
	var packed_b: PackedByteArray = packed.get("b", PackedByteArray())
	if not packed_a.is_empty() and not packed_b.is_empty():
		net._send_replay_to_peer(peer_id, battle_id, packed_a, packed_b)

static func room_list(net: Node) -> Array:
	var out: Array = []
	var listed := {}
	for entry in (net._public_room_list() as Array):
		var row: Dictionary = (entry as Dictionary).duplicate()
		var room: Dictionary = net._rooms.get(int(row.get("id", 0)), {})
		row["joinable"] = true
		row["spectate_open"] = SpectatorService.is_open(room)
		row["spectators"] = net._listed_spectator_peers(room).size()
		out.append(row)
		listed[int(row.get("id", 0))] = true
	var spectate_rows: Array = []
	for room in net._rooms.values():
		var rid := int(room.get("id", 0))
		if listed.has(rid) or bool(room.get("run_over", false)) or str(room.get("state", "")) != net.ROOM_LOBBY:
			continue
		if bool(room.get("matched", false)) or str(room.get("mode", "custom")) != "custom":
			continue
		if not SpectatorService.is_open(room) or bool(room.get("suspended", false)) or net._room_player_count(room) <= 0:
			continue
		spectate_rows.append({
			"id": rid,
			"players": net._room_player_count(room),
			"max": net.TEAM_SLOTS,
			"state": str(room.get("state", net.ROOM_LOBBY)),
			"joinable": false,
			"spectate_open": true,
			"spectators": net._listed_spectator_peers(room).size(),
		})
	spectate_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("id", 0)) < int(b.get("id", 0)))
	return out + spectate_rows.slice(0, net.SPECTATE_LIST_MAX)
