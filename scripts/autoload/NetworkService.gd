extends Node

signal match_state_received(state: Dictionary)
signal session_changed
signal team_lobby_changed
signal team_start_requested
signal team_round_start          # 3v3: all players readied -> launch this round's battle
signal resume_completed(payload: Dictionary)   # 断线重连成功，payload 为服务器推的恢复状态
signal resume_failed(reason: String)           # token 失效/房间已不存在
signal team_room_list_received(rooms: Array)
signal team_room_action_failed(reason: String)
signal public_token_changed(token_id: String)

# HOSTING 随 1v1 P2P 路径一并移除：组队专用服务器模式下客户端只会经历
# JOINING -> READY，服务器进程自身不用这个枚举表状态。
enum SessionState { OFFLINE, JOINING, READY, FAILED, RECONNECTING }

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const DEFAULT_PORT := NetworkConfig.SERVER_PORT
const DEFAULT_HOST := NetworkConfig.SERVER_IP
const TEAM_MAX_CLIENTS := 512
const TEAM_SLOTS := 6
const CLEANUP_INTERVAL_SEC := 5.0
const LOBBY_EMPTY_TTL_SEC := 60.0
const PREP_TIMEOUT_SEC := 30.0 * 60.0
const BATTLE_TIMEOUT_SEC := 5.0 * 60.0
const RESULT_TIMEOUT_SEC := 10.0 * 60.0
const ROOM_LOBBY := "lobby"
const ROOM_PREP := "prep"
const ROOM_BATTLE := "battle"
const ROOM_RESULT := "result"
const ROOM_CLOSED := "closed"
const REPLAY_TIMEOUT_SEC := 20.0
# --- 断线重连 ---
const HEARTBEAT_INTERVAL_SEC := 3.0    # 客户端 ping 间隔
const HEARTBEAT_TIMEOUT_SEC := 20.0    # 超过没消息判掉线（双端）。12s 时被服务器自身
									   # 卡顿(e2-small CPU 限速可冻 20s+)误伤过全场，放宽。
const RECONNECT_RETRY_SEC := 3.0       # 客户端自动重连间隔
# 主线程冻结宽恕：两帧间隔超过此值说明进程刚被卡住（CPU 限速/GC），时钟跳变会让
# 所有心跳计时瞬间"超时"。此时重置计时而不是把全场健康玩家一起踢掉。
const FREEZE_FORGIVE_SEC := 5.0
# 战斗收集阶段看门狗：进入 ROOM_BATTLE 超过此时长仍有 player 槽没交棋盘（客户端
# 卡死/重连落备战/任何原因），服务器用缓存棋盘代交或转 AI，绝不让一个人卡整房。
const BOARD_SUBMIT_TIMEOUT_SEC := 30.0
# 掉线座位宽限：期内其他玩家会等他；到期服务器代打、游戏继续。
# 注意这只是"别人等多久"——重连窗口是整局（座位/token 保留到比赛结束，
# 迟到者重连后落到服务器当前回合）。
const RESERVE_GRACE_SEC := 20.0

var state: SessionState = SessionState.OFFLINE
var is_host := false
var opponent_board_snapshot: Dictionary = {}
var latest_match_state: Dictionary = {}
var remote_address := DEFAULT_HOST
var remote_port := DEFAULT_PORT
var shared_seed := 0
var last_error := ""
var _peer: ENetMultiplayerPeer
var _join_elapsed := 0.0
var _dedicated_server := false
var _cleanup_elapsed := 0.0
var _next_room_id := 1
var _rooms: Dictionary = {}
var _peer_room: Dictionary = {}
var _public_token_seat: Dictionary = {}  # short player token -> session token
var _peer_public_token: Dictionary = {}  # peer_id -> short player token used for this seat
# --- 3v3 team lobby ---
var team_active := false
var team_local_slot := -1
var team_slot_states: Array = []          # 6 x "empty"/"player"/"dummy" (host-authoritative)
var team_ready: Array = []                # 6 x bool
var _team_peer_slot: Dictionary = {}      # peer_id -> slot (host only)
var team_round_active := false            # true during per-round prep (vs the pre-match lobby)
var team_room_id := 0
# --- 断线重连（客户端） ---
var session_token := ""                   # 服务器签发的会话 token（重连凭证，非账号）
var public_token_id := ""                 # 玩家看得到的短 Token ID
var reconnect_address := ""               # 重连目标地址
var pending_abandon_token := ""           # 开新游戏时要放弃的旧座位 token（连上后发给服务器）
var team_leader_slot := 0                 # 当前房主座位（服务器广播；房主掉线会顺延）
var _reconnect_retry_left := 0.0
var _ping_accum := 0.0
var _last_pong_at := 0.0
var _ping_sent_at := 0                    # RTT 测量：本轮 ping 的发出时刻（ticks_msec）
var _last_process_at := 0.0               # 冻结检测：上一帧的时间
# --- 客户端排障日志（查"为什么突然掉线"：原因在手机侧，服务器只看得到结果） ---
const NET_LOG_FILE := "user://net_log.txt"
const NET_LOG_ROTATE_BYTES := 1000000
const CLIENT_LOG_MAX_LINES := 80
const PONG_GAP_WARN_SEC := 6.0            # 静默预警线：还没到超时，但网络已经不对劲
const PING_RTT_LOG_MS := 400              # 心跳往返超过这个值才记，正常网络不刷日志
var _client_log_buffer: Array = []        # 内存环形缓冲；重连成功后回传服务器进 journald
var _client_log_sent := 0
var _net_log_rotated := false
var _pong_gap_logged := false
# --- 服务器权威回合同步（客户端） ---
var server_round_index := 0               # 服务器广播的权威回合号（0=未知）
var server_phase := ""                    # 服务器广播的房间阶段
var _last_team_submission: Dictionary = {} # 最后一次提交的棋盘（被拒后校准重交用）
var _resync_resubmitted_round := 0        # 防重交循环：每回合只自动补交一次
# --- 断线重连（服务器） ---
var _token_seat: Dictionary = {}          # token -> {"room_id": int, "slot": int}
var _peer_last_ping: Dictionary = {}      # peer_id -> unix time
var _reserve_tick_accum := 0.0
# --- 限流（服务器） ---
# 四个维度，严格程度递减：per-peer 最严 -> per-token -> per-IP（只记录不拦截）->
# 全服熔断。per-IP 不拦截是刻意的：手机 4G/校园网走运营商级 NAT，一个公网 IP 后面
# 可能是几千个正常玩家，用没有实测分布支撑的阈值去封，等于封掉整片区域。
# 先记录，等埋点跑出真实分布再定阈值。
const RATE_WINDOW_SEC := 10.0
const RATE_LIMITS := {          # action -> 每 RATE_WINDOW_SEC 内允许次数
	"create_room": 3,
	"join_room": 6,
	"room_list": 10,
	"public_token": 3,
	"public_resume": 5,
	"client_log": 4,
	"set_ready": 30,
	"submit_board": 10,
	"prep_mercs": 40,
	"toggle_slot": 30,
	"kick": 10,
	"move": 30,
	"altar": 12,          # 每回合上限 3 次，留足重试余量
}
const RATE_STRIKES_BEFORE_KICK := 3   # 连续超限这么多次就断开
const MAX_ROOMS := 200                # 全服房间数熔断
const MAX_CLIENT_LOG_BYTES := 4000    # 单次 client_log 总字节上限（不只限行数）
var _rate_buckets: Dictionary = {}    # peer_id -> {action: [count, window_start]}
var _rate_strikes: Dictionary = {}    # peer_id -> int

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	set_process(true)
	# 切断 client→client 转发。Godot 默认允许客户端 rpc_id 到另一个客户端、由服务器
	# 中转，于是任何玩家都能给别人塞伪造的 match_state（金币/血量/胜负全由他定）。
	# team 模式下客户端只会 rpc_id(1,...)，关掉它不影响任何现存客户端。
	# 必须在 create_server 之前、任何 peer 接入之前设置。
	multiplayer.server_relay = false
	if _should_boot_dedicated_server():
		call_deferred("start_dedicated_server")

func _process(delta: float) -> void:
	# 冻结宽恕（双端）：进程刚被卡住过（服务器 CPU 被限速时实测冻 10~22 秒），
	# 时钟一跳所有心跳计时全部失真——重置计时，不许拿自己的卡顿判别人超时。
	var proc_now := _now()
	if _last_process_at > 0.0 and proc_now - _last_process_at >= FREEZE_FORGIVE_SEC:
		_net_log("process freeze %.1fs -> heartbeat timers reset" % (proc_now - _last_process_at))
		for pid in _peer_last_ping.keys():
			_peer_last_ping[pid] = proc_now
		if _last_pong_at > 0.0:
			_last_pong_at = proc_now
	_last_process_at = proc_now
	if _dedicated_server:
		ServerFlags.poll_reload(proc_now)
		_cleanup_elapsed += delta
		if _cleanup_elapsed >= CLEANUP_INTERVAL_SEC:
			_cleanup_elapsed = 0.0
			_cleanup_rooms()
		_reserve_tick_accum += delta
		if _reserve_tick_accum >= 1.0:
			_reserve_tick_accum = 0.0
			_tick_reserved_seats()
			_tick_heartbeat_timeouts()
			_reap_zombie_peers()
			_tick_board_watchdog()
	# 客户端心跳：比干等 ENet 超时更快发现半开连接
	if team_active and not is_host and state == SessionState.READY and multiplayer.multiplayer_peer != null:
		_ping_accum += delta
		if _ping_accum >= HEARTBEAT_INTERVAL_SEC:
			_ping_accum = 0.0
			_ping_sent_at = Time.get_ticks_msec()
			_rpc_ping.rpc_id(1)
		if _last_pong_at > 0.0:
			var silence := _now() - _last_pong_at
			if silence > HEARTBEAT_TIMEOUT_SEC:
				_net_log("heartbeat timeout -> reconnect")
				_begin_reconnect("heartbeat_timeout")
				return
			elif silence >= PONG_GAP_WARN_SEC and not _pong_gap_logged:
				# 预警：网络已静默数秒但还没到断线线——这行是"掉线前现场"的关键证据
				_pong_gap_logged = true
				_net_log("pong silence %.1fs (network degrading)" % silence)
	if state == SessionState.RECONNECTING:
		_reconnect_retry_left -= delta
		if _reconnect_retry_left <= 0.0:
			_reconnect_retry_left = RECONNECT_RETRY_SEC
			_attempt_reconnect()
		return
	if state != SessionState.JOINING:
		return
	_join_elapsed += delta
	if _join_elapsed < NetworkConfig.CONNECTION_TIMEOUT:
		return
	last_error = tr("net_err_timeout") % [remote_address, remote_port]
	state = SessionState.FAILED
	reset_peer_only()
	session_changed.emit()

# 只认显式命令行参数。曾经把「裸 headless」也当成启动信号，导致 tools/ 下每个
# headless 工具节点跑起来时旁边都挂着一个真的监听服务器：与工具共用同一个
# NetworkService 实例、占着 8080、还会让确定性验收在被污染的环境里得出结论。
# 工具需要服务器逻辑时请显式调用 enter_test_server_mode()（不开监听 socket）。
func _should_boot_dedicated_server() -> bool:
	return "--server" in OS.get_cmdline_args() or "--dedicated-server" in OS.get_cmdline_args()

# 供 tools/ 下的 in-process 工具节点使用：只打开服务器侧逻辑（房间/座位/结算），
# 不创建 ENet peer、不占端口。因此多个工具可以并行跑，也不会与真服务器抢 8080。
func enter_test_server_mode() -> void:
	_dedicated_server = true
	team_active = true
	is_host = true
	if team_slot_states.is_empty():
		team_slot_states = ["empty", "empty", "empty", "empty", "empty", "empty"]
	if team_ready.is_empty():
		team_ready = [false, false, false, false, false, false]

func start_dedicated_server(port: int = DEFAULT_PORT) -> bool:
	# Server-side entry point for Google Cloud VPS. The server owns room state,
	# slot validation, ready flow, board collection, and battle replay compute.
	_dedicated_server = true
	# 关键：无画面 Godot 默认不限帧，_process 每秒空转数千次会把一个 CPU 核打满，
	# 小机型(GCP 突发积分)积分耗尽后被限速到卡死、连 SSH 都进不去、只能 reset。
	# 服务器只跑房间/心跳/清理，30 FPS 绰绰有余，限帧后 CPU 占用降到几乎为 0。
	Engine.max_fps = 30
	_net_log("server starting protocol=%d port=%d max_fps=%d" % [NetworkConfig.NETWORK_PROTOCOL_VERSION, port, Engine.max_fps])
	return team_host(port, true)

# --- 3v3 team lobby --------------------------------------------------------
func team_host(port: int = DEFAULT_PORT, dedicated: bool = false) -> bool:
	if not dedicated and not _local_host_allowed():
		state = SessionState.FAILED
		last_error = tr("net_err_no_local_host")
		session_changed.emit()
		return false
	reset()
	_dedicated_server = dedicated
	team_active = true
	remote_port = port
	var p := ENetMultiplayerPeer.new()
	var err := p.create_server(port, TEAM_MAX_CLIENTS)
	if err != OK:
		state = SessionState.FAILED
		last_error = tr("net_err_host_failed") % str(err)
		session_changed.emit()
		return false
	_peer = p
	multiplayer.multiplayer_peer = _peer
	state = SessionState.READY
	is_host = true
	shared_seed = randi()
	team_local_slot = -1 if dedicated else 0
	team_slot_states = ["empty", "empty", "empty", "empty", "empty", "empty"] if dedicated else ["player", "empty", "empty", "empty", "empty", "empty"]
	team_ready = [false, false, false, false, false, false]
	team_prep_mercs = {}
	_team_peer_slot.clear()
	last_error = ""
	if dedicated:
		_net_log("server started protocol=%d port=%d" % [NetworkConfig.NETWORK_PROTOCOL_VERSION, port])
	session_changed.emit()
	team_lobby_changed.emit()
	return true

func team_join(address: String = DEFAULT_HOST, port: int = DEFAULT_PORT) -> bool:
	reset()
	team_active = true
	public_token_id = SaveManager.load_public_token()
	remote_address = address.strip_edges()
	remote_port = port
	var p := ENetMultiplayerPeer.new()
	var err := p.create_client(remote_address, remote_port)
	if err != OK:
		state = SessionState.FAILED
		last_error = tr("net_err_join_failed") % str(err)
		session_changed.emit()
		return false
	_peer = p
	multiplayer.multiplayer_peer = _peer
	state = SessionState.JOINING
	_join_elapsed = 0.0
	is_host = false
	last_error = ""
	session_changed.emit()
	return true

func team_request_room_list() -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_rpc_team_room_list_request.rpc_id(1)

func team_request_create_room() -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_rpc_team_create_room.rpc_id(1, public_token_id)

func team_request_join_room(room_id: int) -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_rpc_team_join_room.rpc_id(1, room_id, public_token_id)

func team_request_public_token() -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_rpc_public_token_request.rpc_id(1)

func team_request_public_resume(token_id: String) -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		public_token_id = token_id.strip_edges().to_upper()
		SaveManager.save_public_token(public_token_id)
		_rpc_public_resume_request.rpc_id(1, public_token_id)

func _team_next_free_slot() -> int:
	for i in TEAM_SLOTS:
		if str(team_slot_states[i]) == "empty":
			return i
	return -1

func _now() -> float:
	return Time.get_unix_time_from_system()

# --- 限流 -------------------------------------------------------------------
# 返回 true = 放行；false = 超限（调用方必须立即 return，不做任何业务处理）。
# 注意能力边界：RPC 参数在进入本函数前已被引擎反序列化，所以这里挡不住「一个巨大
# Variant 的解码开销」——那一层要靠 NetProtocol 的容器上限 + 第 3 批的字节协议。
# 本函数挡的是「同一个动作被高频重复调用」。
func _rate_ok(peer_id: int, action: String) -> bool:
	if not _dedicated_server:
		return true
	var limit := int(RATE_LIMITS.get(action, 20))
	var now := _now()
	var buckets: Dictionary = _rate_buckets.get(peer_id, {})
	var entry: Array = buckets.get(action, [0, now])
	if now - float(entry[1]) >= RATE_WINDOW_SEC:
		entry = [0, now]
	entry[0] = int(entry[0]) + 1
	buckets[action] = entry
	_rate_buckets[peer_id] = buckets
	if int(entry[0]) <= limit:
		return true
	var strikes := int(_rate_strikes.get(peer_id, 0)) + 1
	_rate_strikes[peer_id] = strikes
	_net_log("rate limit peer=%d action=%s count=%d/%d strike=%d" % [peer_id, action, int(entry[0]), limit, strikes])
	if strikes >= RATE_STRIKES_BEFORE_KICK:
		_net_log("rate limit exceeded -> disconnect peer=%d" % peer_id)
		if multiplayer.multiplayer_peer != null:
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)
	return false

func _rate_forget(peer_id: int) -> void:
	_rate_buckets.erase(peer_id)
	_rate_strikes.erase(peer_id)

func _net_log(message: String) -> void:
	# print 在手机上每次都是一次系统调用，发布版必须静音。
	if OS.is_debug_build():
		print("[NET] %s" % message)
	if _dedicated_server:
		return  # 服务器有 journald，不用双写
	# 客户端：进内存缓冲（重连后回传服务器）+ 落盘（app 被杀也留得住现场）
	var line := "%s | %s" % [Time.get_datetime_string_from_system(), message]
	_client_log_buffer.append(line)
	if _client_log_buffer.size() > CLIENT_LOG_MAX_LINES:
		_client_log_buffer.pop_front()
		if _client_log_sent > 0:
			_client_log_sent -= 1
	_client_file_log(line)

func _client_file_log(line: String) -> void:
	if not _net_log_rotated:
		_net_log_rotated = true
		var probe := FileAccess.open(NET_LOG_FILE, FileAccess.READ)
		if probe != null and probe.get_length() > NET_LOG_ROTATE_BYTES:
			probe = null
			DirAccess.remove_absolute(ProjectSettings.globalize_path(NET_LOG_FILE))
	var f := FileAccess.open(NET_LOG_FILE, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(NET_LOG_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(line)

# 重连/连接成功后，把断线前后的客户端现场回传服务器（落进 journald，和服务器
# 事件对着看）。只发增量，单行截断，服务器侧也再限量——不给弱网添堵。
func _client_send_pending_logs() -> void:
	if is_host or _client_log_buffer.size() <= _client_log_sent:
		return
	var lines := PackedStringArray()
	for i in range(_client_log_sent, _client_log_buffer.size()):
		lines.append(str(_client_log_buffer[i]).substr(0, 200))
	_client_log_sent = _client_log_buffer.size()
	_rpc_client_log.rpc_id(1, lines)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_log(lines: PackedStringArray) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "client_log"):
		return
	# 按总字节数封顶，不只按行数：200 字符 × 80 行仍可能被拿来刷爆 journald 和磁盘。
	var budget := MAX_CLIENT_LOG_BYTES
	for i in mini(lines.size(), CLIENT_LOG_MAX_LINES):
		var line := str(lines[i]).substr(0, 200)
		budget -= line.length()
		if budget <= 0:
			_net_log("clientlog peer=%d | (truncated, byte budget exhausted)" % sender)
			return
		_net_log("clientlog peer=%d | %s" % [sender, line])

# app 生命周期事件：锁屏/切后台是手机掉线的头号惯犯，记下来和断线时间对照。
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_net_log("app paused (backgrounded/screen off)")
		NOTIFICATION_APPLICATION_RESUMED:
			_net_log("app resumed")
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_net_log("app focus out")
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_net_log("app focus in")

func _new_room() -> Dictionary:
	var id := randi_range(100000, 999999)
	while _rooms.has(id):
		id = randi_range(100000, 999999)
	var now := _now()
	var slot_gold := []
	slot_gold.resize(TEAM_SLOTS)
	slot_gold.fill(GameState.START_GOLD)
	var room := {
		"id": id,
		"state": ROOM_LOBBY,
		"slot_states": ["empty", "empty", "empty", "empty", "empty", "empty"],
		"ready": [false, false, false, false, false, false],
		"peer_slot": {},
		"boards": {},
		"slot_gold": slot_gold,
		"team_hp": [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP],
		"pve_completed": 0,
		"boss_completed": 0,
		"team_loss_streak": [0, 0],
		"final_battle_complete": false,
		"last_match_state": {},
		"shared_seed": randi(),
		"round_index": 1,
		"created_at": now,
		"last_activity_at": now,
		"state_started_at": now,
		"empty_since": now,
		# --- 断线重连 ---
		"seat_tokens": {},       # slot -> token（会话凭证）
		"last_board": {},        # slot -> 最后一次通过校验的棋盘快照（跨回合缓存，补交用）
		"reserved": {},          # slot -> {"reserved_at": float}（掉线保留中）
		"reserve_deadline": {},  # slot -> 宽限截止 unix time
		"leader_slot": 0,        # 房主座位，掉线顺延
		"altar_uses": {},        # slot -> 本回合黄金祭坛已用次数（服务端权威，每回合清零）
	}
	_rooms[id] = room
	_net_log("room created id=%d protocol=%d" % [id, NetworkConfig.NETWORK_PROTOCOL_VERSION])
	return room

func _find_or_create_room() -> Dictionary:
	for room in _rooms.values():
		if str(room.get("state", "")) == ROOM_LOBBY and _room_next_free_slot(room) >= 0:
			return room
	return _new_room()

func _room_player_count(room: Dictionary) -> int:
	var count := 0
	for st in (room.get("slot_states", []) as Array):
		if str(st) == "player":
			count += 1
	return count

func _public_room_list() -> Array:
	var out: Array = []
	for room in _rooms.values():
		if str(room.get("state", "")) != ROOM_LOBBY or _room_next_free_slot(room) < 0:
			continue
		out.append({
			"id": int(room.get("id", 0)),
			"players": _room_player_count(room),
			"max": TEAM_SLOTS,
			"state": str(room.get("state", ROOM_LOBBY)),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("id", 0)) < int(b.get("id", 0)))
	return out

func _room_next_free_slot(room: Dictionary) -> int:
	var states: Array = room.get("slot_states", [])
	for i in TEAM_SLOTS:
		if i < states.size() and str(states[i]) == "empty":
			return i
	return -1

func _room_for_peer(peer_id: int) -> Dictionary:
	var room_id := int(_peer_room.get(peer_id, 0))
	return _rooms.get(room_id, {})

func _touch_room(room: Dictionary) -> void:
	room.last_activity_at = _now()

func _set_room_state(room: Dictionary, next_state: String) -> void:
	if str(room.get("state", "")) == next_state:
		return
	room.state = next_state
	room.state_started_at = _now()

func _room_online_count(room: Dictionary) -> int:
	var count := 0
	var room_id := int(room.get("id", 0))
	var peer_slot: Dictionary = room.get("peer_slot", {})
	for peer_id in peer_slot.keys():
		if int(_peer_room.get(int(peer_id), 0)) == room_id:
			count += 1
	return count

# peer 是否还连着（服务器给某个 peer 发 RPC 前必须先查，否则对已断开的 peer 发
# 会刷 "Attempt to call RPC with unknown peer ID" 错误、并可能中断后续清理）。
func _peer_connected(peer_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if peer_id == 1:
		return true
	if not multiplayer.get_peers().has(peer_id):
		return false
	# ENet 层可能已经半死（断开中/超时中）但 SceneMultiplayer 还没发 disconnect 信号。
	# 对这种 peer 发包必失败（"Unable to send packet"+堆栈刷屏，在受限 CPU 上足以
	# 拖出秒级冻结）——一并视为已断开，交给清道夫回收。
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null:
		var ep := enet.get_peer(peer_id)
		if ep == null or ep.get_state() != ENetPacketPeer.STATE_CONNECTED:
			return false
	return true

func _room_close(room: Dictionary, reason: String) -> void:
	room.state = ROOM_CLOSED
	room.finished_reason = reason
	# 房间没了，所有座位 token 一并作废
	for t in (room.get("seat_tokens", {}) as Dictionary).values():
		_token_seat.erase(str(t))
	_net_log("room cleanup id=%d reason=%s" % [int(room.get("id", 0)), reason])
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if _peer_connected(int(peer_id)):
			_rpc_team_room_closed.rpc_id(int(peer_id), reason)
		_peer_room.erase(int(peer_id))

func _cleanup_rooms() -> void:
	var now := _now()
	var to_delete: Array = []
	for room_id in _rooms.keys():
		var room: Dictionary = _rooms[room_id]
		var state_name := str(room.get("state", ROOM_LOBBY))
		var online_count := _room_online_count(room)
		var match_over := bool(room.get("final_battle_complete", false))
		if online_count <= 0:
			if float(room.get("empty_since", 0.0)) <= 0.0:
				room.empty_since = now
			# 打完的房间（final_battle_complete）没人在线就限时回收，token 一并作废。
			# 不回收的话它会永远卡在 ROOM_RESULT：_room_begin_next_prep 对 final 房间
			# 直接 return，原逻辑没有任何路径能删掉它 -> 服务器内存无限涨。
			if match_over and now - float(room.empty_since) >= LOBBY_EMPTY_TTL_SEC:
				_room_close(room, "match_over")
			elif state_name == ROOM_LOBBY and now - float(room.empty_since) >= LOBBY_EMPTY_TTL_SEC:
				_room_close(room, "empty_lobby")
		else:
			room.empty_since = 0.0
		var age := now - float(room.get("state_started_at", now))
		if state_name == ROOM_PREP and age >= PREP_TIMEOUT_SEC:
			_room_close(room, "prep_timeout")
		elif state_name == ROOM_BATTLE and age >= BATTLE_TIMEOUT_SEC:
			_room_close(room, "battle_timeout")
		elif state_name == ROOM_RESULT and age >= RESULT_TIMEOUT_SEC:
			# final 房间超时兜底：就算还有 peer 挂着（看完结算不退），也强制关闭
			if match_over:
				_room_close(room, "match_over")
			else:
				_room_begin_next_prep(room)
		if str(room.get("state", "")) == ROOM_CLOSED:
			to_delete.append(room_id)
	for room_id in to_delete:
		_rooms.erase(room_id)

func _room_begin_next_prep(room: Dictionary) -> void:
	# 对局已结束（最终局打完）就不再开新回合，避免服务器把回合推过 FINAL_ROUND、
	# 与封顶在 21 的客户端分叉，导致客户端等一个对不上号的 match_state 死循环。
	if bool(room.get("final_battle_complete", false)):
		return
	room.boards = {}
	room.prep_mercs = {}
	room.altar_uses = {}   # 祭坛次数按回合重置，和客户端 reset_shop_refreshes 同步
	# round_index 封顶到 FINAL_ROUND，和客户端一致（客户端从 match_state 拿的是 min(+1, 21)）
	room.round_index = mini(int(room.get("round_index", 1)) + 1, GameState.FINAL_ROUND)
	var ready: Array = room.get("ready", [])
	var states: Array = room.get("slot_states", [])
	for i in TEAM_SLOTS:
		if i < states.size() and str(states[i]) == "player":
			ready[i] = false
	room.ready = ready
	_set_room_state(room, ROOM_PREP)
	_net_log("room prep id=%d round=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1))])
	_broadcast_room_lobby(room)

func team_toggle_slot(slot: int) -> void:
	# Server-side room control. In dedicated mode, slot A's client requests this
	# and the server validates before changing dummy slots.
	if not can_control_room() or slot < 0 or slot >= TEAM_SLOTS:
		return
	if not is_host:
		_rpc_team_toggle_slot.rpc_id(1, slot)
		return
	_team_toggle_slot_authoritative(slot)

func team_kick_slot(slot: int) -> void:
	if not can_control_room() or slot < 0 or slot >= TEAM_SLOTS or slot == team_local_slot:
		return
	if not is_host:
		_rpc_team_kick_slot.rpc_id(1, slot)
		return
	_team_kick_slot_authoritative(slot)

func _team_kick_slot_authoritative(slot: int) -> void:
	if not is_host or slot < 0 or slot >= TEAM_SLOTS:
		return
	var kicked_peer := -1
	for peer_id in _team_peer_slot.keys():
		if int(_team_peer_slot[peer_id]) == slot:
			kicked_peer = int(peer_id)
			break
	if kicked_peer < 0:
		return
	_team_peer_slot.erase(kicked_peer)
	team_slot_states[slot] = "empty"
	team_ready[slot] = false
	_rpc_team_kicked.rpc_id(kicked_peer, "kicked", "")
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.disconnect_peer(kicked_peer)
	_team_broadcast_lobby()
	team_lobby_changed.emit()

func _team_toggle_slot_authoritative(slot: int) -> void:
	if not is_host or slot < 0 or slot >= TEAM_SLOTS:
		return
	match str(team_slot_states[slot]):
		"empty":
			team_slot_states[slot] = "dummy"
			team_ready[slot] = true
		"dummy":
			team_slot_states[slot] = "empty"
			team_ready[slot] = false
		_:
			return
	_team_broadcast_lobby()
	team_lobby_changed.emit()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_toggle_slot(slot: int) -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		var room := _room_for_peer(sender)
		if room.is_empty() or int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != int(room.get("leader_slot", 0)):
			return
		_room_toggle_slot(room, slot)
		return
	if not is_host or int(_team_peer_slot.get(multiplayer.get_remote_sender_id(), -1)) != 0:
		return
	_team_toggle_slot_authoritative(slot)

func _room_toggle_slot(room: Dictionary, slot: int) -> void:
	if slot < 0 or slot >= TEAM_SLOTS:
		return
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	match str(states[slot]):
		"empty":
			states[slot] = "dummy"
			ready[slot] = true
		"dummy":
			states[slot] = "empty"
			ready[slot] = false
		_:
			return
	room.slot_states = states
	room.ready = ready
	_touch_room(room)
	_broadcast_room_lobby(room)

func team_request_move(target_slot: int) -> void:
	# A player asks to move into an empty slot. Host-authoritative.
	if not team_active or team_local_slot < 0:
		return
	if is_host:
		_team_do_move(team_local_slot, target_slot)
	else:
		_rpc_team_move.rpc_id(1, team_local_slot, target_slot)

func _team_do_move(from_slot: int, to_slot: int) -> void:
	if not is_host:
		return
	# 换位只允许在开赛前。开赛后换位会改变队伍归属和身份色，而 slot 是这两者
	# 唯一的真相来源——中途换掉等于把人换队。
	if team_round_active:
		return
	if from_slot < 0 or from_slot >= TEAM_SLOTS or to_slot < 0 or to_slot >= TEAM_SLOTS or from_slot == to_slot:
		return
	if str(team_slot_states[from_slot]) != "player":
		return
	if str(team_slot_states[to_slot]) != "empty":
		return
	var was_ready := bool(team_ready[from_slot])
	team_slot_states[from_slot] = "empty"
	team_ready[from_slot] = false
	team_slot_states[to_slot] = "player"
	team_ready[to_slot] = was_ready
	if team_local_slot == from_slot:
		team_local_slot = to_slot
	for pid in _team_peer_slot.keys():
		if int(_team_peer_slot[pid]) == from_slot:
			_team_peer_slot[pid] = to_slot
			_rpc_team_assign_slot.rpc_id(pid, to_slot)
			break
	_team_broadcast_lobby()
	team_lobby_changed.emit()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_move(from_slot: int, to_slot: int) -> void:
	if _dedicated_server:
		var sender_id := multiplayer.get_remote_sender_id()
		var room := _room_for_peer(sender_id)
		if room.is_empty() or int((room.get("peer_slot", {}) as Dictionary).get(sender_id, -1)) != from_slot:
			return
		# 同 _team_do_move：换位只在大厅阶段开放。客户端 UI 本来就只在大厅暴露入口，
		# 但这个 RPC 任何 peer 都能发，所以门必须在服务器这边。
		if str(room.get("state", ROOM_LOBBY)) != ROOM_LOBBY:
			return
		_room_do_move(room, sender_id, from_slot, to_slot)
		return
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if int(_team_peer_slot.get(sender, -1)) != from_slot:
		return
	_team_do_move(from_slot, to_slot)

func _room_do_move(room: Dictionary, peer_id: int, from_slot: int, to_slot: int) -> void:
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	if from_slot < 0 or from_slot >= TEAM_SLOTS or to_slot < 0 or to_slot >= TEAM_SLOTS or from_slot == to_slot:
		return
	if str(states[from_slot]) != "player" or str(states[to_slot]) != "empty":
		return
	var was_ready := bool(ready[from_slot])
	states[from_slot] = "empty"
	ready[from_slot] = false
	states[to_slot] = "player"
	ready[to_slot] = was_ready
	var peer_slot: Dictionary = room.get("peer_slot", {})
	peer_slot[peer_id] = to_slot
	room.slot_states = states
	room.ready = ready
	room.peer_slot = peer_slot
	# 会话凭证必须跟着人搬。_token_seat 记的是 slot，不搬的话这人重连会被放回旧
	# 槽位（队伍和身份色一起变回去）；旧槽位要是已经有人坐了，resume 直接判
	# seat_taken，他连不回来。
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	if seat_tokens.has(from_slot):
		var token := str(seat_tokens[from_slot])
		seat_tokens.erase(from_slot)
		seat_tokens[to_slot] = token
		room.seat_tokens = seat_tokens
		var seat: Dictionary = _token_seat.get(token, {})
		if not seat.is_empty():
			seat["slot"] = to_slot
			_token_seat[token] = seat
	_touch_room(room)
	_rpc_team_assign_slot.rpc_id(peer_id, to_slot)
	_broadcast_room_lobby(room)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_kick_slot(slot: int) -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		var room := _room_for_peer(sender)
		if room.is_empty() or int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != int(room.get("leader_slot", 0)):
			return
		_room_kick_slot(room, slot)
		return
	if not is_host or int(_team_peer_slot.get(multiplayer.get_remote_sender_id(), -1)) != 0:
		return
	_team_kick_slot_authoritative(slot)

func _room_kick_slot(room: Dictionary, slot: int) -> void:
	# 不能踢房主自己（房主可能已顺延到非 0 号位）
	if slot < 0 or slot >= TEAM_SLOTS or slot == int(room.get("leader_slot", 0)):
		return
	var peer_slot: Dictionary = room.get("peer_slot", {})
	for peer_id in peer_slot.keys():
		if int(peer_slot[peer_id]) == slot:
			_rpc_team_kicked.rpc_id(int(peer_id), "kicked", "")
			if multiplayer.multiplayer_peer != null:
				multiplayer.multiplayer_peer.disconnect_peer(int(peer_id))
			_room_remove_peer(room, int(peer_id))
			return

func team_set_ready(value: bool) -> void:
	if team_local_slot < 0:
		return
	if is_host:
		team_ready[team_local_slot] = value
		_team_broadcast_lobby()
		team_lobby_changed.emit()
		_team_maybe_start_round()
	else:
		_rpc_team_set_ready.rpc_id(1, team_local_slot, value)

func team_all_ready() -> bool:
	# Empty slots are allowed (e.g. a 2v2). Requirements: every connected real
	# player is ready, and each side has at least one occupant (player or dummy).
	if team_slot_states.size() < TEAM_SLOTS:
		return false
	var side_a := 0
	var side_b := 0
	for i in TEAM_SLOTS:
		var st := str(team_slot_states[i])
		# 房主不再免检：任何 player 座位（含房主）都必须 ready。房主的"开始游戏"
		# 会先把自己 ready=true 再走到这里（见 team_start / _rpc_team_start_request）。
		if st == "player" and not bool(team_ready[i]):
			return false
		if st != "empty":
			if i < 3:
				side_a += 1
			else:
				side_b += 1
	return side_a > 0 and side_b > 0

func team_start() -> void:
	# Server-authoritative match start. Dedicated room leader presses Start;
	# the server validates readiness and launches for everyone.
	if not is_host:
		if can_control_room():
			_rpc_team_start_request.rpc_id(1)
		return
	# 本地房主：按开始游戏即自动提交自己的 ready，再做权威开局检查
	if team_local_slot >= 0 and team_local_slot < team_ready.size():
		team_ready[team_local_slot] = true
		_team_broadcast_lobby()
		team_lobby_changed.emit()
	_team_start_authoritative()

func _team_start_authoritative() -> void:
	if not is_host or not team_all_ready():
		return
	GameState.team_slot_states = team_slot_states.duplicate()
	_rpc_team_start.rpc()
	team_start_requested.emit()

func _team_broadcast_lobby() -> void:
	if is_host and is_online():
		_rpc_team_lobby.rpc(team_slot_states, team_ready)

func _room_all_ready(room: Dictionary) -> bool:
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	if states.size() < TEAM_SLOTS or ready.size() < TEAM_SLOTS:
		return false
	var side_a := 0
	var side_b := 0
	for i in TEAM_SLOTS:
		var st := str(states[i])
		# 房主不再免检：每回合备战里房主也要按"准备"；大厅开局时房主的 ready 由
		# _rpc_team_start_request 先置 true。这条修掉"进回合摆棋就自动开战"。
		if st == "player" and not bool(ready[i]):
			return false
		if st != "empty":
			if i < 3:
				side_a += 1
			else:
				side_b += 1
	return side_a > 0 and side_b > 0

func _room_start_authoritative(room: Dictionary) -> void:
	if not _room_all_ready(room):
		return
	_touch_room(room)
	_set_room_state(room, ROOM_PREP)
	var ready: Array = room.get("ready", [])
	var states: Array = room.get("slot_states", [])
	for i in TEAM_SLOTS:
		if str(states[i]) == "player":
			ready[i] = false
	room.ready = ready
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if _peer_connected(int(peer_id)):
			_rpc_team_start.rpc_id(int(peer_id))
	_net_log("all players ready room=%d match started" % int(room.get("id", 0)))
	_broadcast_room_lobby(room)

func _room_maybe_start_round(room: Dictionary) -> void:
	if str(room.get("state", ROOM_LOBBY)) != ROOM_PREP or not _room_all_ready(room):
		return
	_set_room_state(room, ROOM_BATTLE)
	room.boards = {}
	_net_log("PVP round started room=%d round=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1))])
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if _peer_connected(int(peer_id)):
			_rpc_team_round_start.rpc_id(int(peer_id))
	# 若这一回合没有任何"player"座位要交棋盘（全 dummy/全掉线转 AI），立即结算，
	# 否则会卡在 ROOM_BATTLE 等一个永远不来的提交。有真人时此调用直接返回（等提交）。
	_room_try_finalize_boards(room)

func _broadcast_room_lobby(room: Dictionary) -> void:
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	# 回合号/阶段随大厅同步一起广播：客户端回合号从此有权威来源，不再只靠
	# 自己那局的 match_state 推进（漏一次就永久落后 -> 提交被 wrong_round 拒 -> 卡死）
	var round_i := int(room.get("round_index", 1))
	var phase := str(room.get("state", ROOM_LOBBY))
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if _peer_connected(int(peer_id)):
			_rpc_team_lobby.rpc_id(int(peer_id), states, ready, round_i, phase)

# --- 3v3 prep mercenary sync ------------------------------------------------
# 备战阶段实时同步每个玩家已雇的佣兵 id 列表，供「队伍佣兵」弹窗展示。
# 载荷极小（≤8 个 id + 回合号），每次雇佣发一次。条目带回合号，读取时按当前
# 回合过滤，跨回合的旧数据自然失效，不依赖显式清理。
signal team_prep_mercs_changed

var team_prep_mercs: Dictionary = {}   # slot(int) -> {"round": int, "ids": Array[String]}

func team_send_prep_mercs() -> void:
	if not team_active or team_local_slot < 0:
		return
	var ids: Array = []
	for cell in GameState.mercenary_slots:
		if typeof(cell) == TYPE_DICTIONARY:
			ids.append(str((cell as Dictionary).get("id", "")))
	if is_host:
		_store_team_prep_mercs(team_local_slot, GameState.round_index, ids)
		_rpc_team_prep_mercs.rpc(team_local_slot, GameState.round_index, ids)
	else:
		_rpc_team_prep_mercs_submit.rpc_id(1, team_local_slot, GameState.round_index, ids)

func team_prep_merc_ids(slot: int, round_index: int) -> Array:
	var entry_value = team_prep_mercs.get(slot)
	if typeof(entry_value) != TYPE_DICTIONARY:
		return []
	var entry: Dictionary = entry_value
	if int(entry.get("round", -1)) != round_index:
		return []
	return (entry.get("ids", []) as Array).duplicate()

func _store_team_prep_mercs(slot: int, round_index: int, ids: Array) -> void:
	team_prep_mercs[slot] = {"round": round_index, "ids": _sanitize_prep_merc_ids(ids)}
	team_prep_mercs_changed.emit()

func _sanitize_prep_merc_ids(ids: Array) -> Array:
	# 来路是网络：只收佣兵表里存在的 id，数量封顶佣兵栏容量。
	var valid := {}
	for row in (DataRegistry.get_table("mercenaries").get("mercenaries", []) as Array):
		valid[str((row as Dictionary).get("id", ""))] = true
	var out: Array = []
	for id_value in ids:
		var id := str(id_value)
		if valid.has(id) and out.size() < GameState.MERCENARY_SLOTS:
			out.append(id)
	return out

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_prep_mercs_submit(slot: int, round_index: int, ids: Array) -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		var room := _room_for_peer(sender)
		if room.is_empty() or slot < 0 or slot >= TEAM_SLOTS:
			return
		if int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != slot:
			return
		var clean := _sanitize_prep_merc_ids(ids)
		var prep_mercs: Dictionary = room.get("prep_mercs", {})
		prep_mercs[slot] = {"round": round_index, "ids": clean}
		room.prep_mercs = prep_mercs
		for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
			if int(peer_id) != sender and _peer_connected(int(peer_id)):
				_rpc_team_prep_mercs.rpc_id(int(peer_id), slot, round_index, clean)
		return
	if not is_host or slot < 0 or slot >= TEAM_SLOTS:
		return
	if int(_team_peer_slot.get(multiplayer.get_remote_sender_id(), -1)) != slot:
		return
	_store_team_prep_mercs(slot, round_index, ids)
	_rpc_team_prep_mercs.rpc(slot, round_index, team_prep_merc_ids(slot, round_index))

@rpc("authority", "call_remote", "reliable")
func _rpc_team_prep_mercs(slot: int, round_index: int, ids: Array) -> void:
	if slot < 0 or slot >= TEAM_SLOTS:
		return
	_store_team_prep_mercs(slot, round_index, ids)

# --- 3v3 team board collection (N2) ----------------------------------------
# After everyone presses "start battle" in prep, each player submits their board
# snapshot. The host gathers all real-player boards, then broadcasts the full
# per-slot set (+ shared seed) so every client builds the same battle.
signal team_boards_ready
signal team_replay_received

var team_boards: Dictionary = {}          # slot(int) -> snapshot Dictionary (after broadcast)
var _team_boards_collecting: Dictionary = {}
var team_replay: Dictionary = {}          # this client's team replay (B3, host-authoritative)
var team_replay_rival: Dictionary = {}    # 敌方队伍同回合的 replay（战斗中切镜头观战用）

func team_begin_round() -> void:
	team_boards = {}
	_team_boards_collecting = {}
	team_replay = {}
	team_replay_rival = {}
	team_prep_mercs = {}
	# 权威回合对齐：本地回合号落后服务器（重连/漏包后遗症）时，提交棋盘会被
	# wrong_round 拒收、整轮卡死。进新回合是安全的对齐时机（不会打断战斗播放）。
	# 只升不降：结算阶段客户端可以合法领先服务器一轮（见 _room_begin_next_prep 惰性推进）。
	if not is_host and server_round_index > GameState.round_index:
		_net_log("round aligned to server: %d -> %d" % [GameState.round_index, server_round_index])
		GameState.round_index = server_round_index
	# Enter per-round prep: real players must re-ready this round; dummies stay ready.
	team_round_active = true
	if is_host:
		for i in TEAM_SLOTS:
			if i < team_slot_states.size() and str(team_slot_states[i]) == "player":
				team_ready[i] = false
		_team_broadcast_lobby()
		team_lobby_changed.emit()
	else:
		# 客户端（专用服务器模式）：进新回合先乐观重置自己的 ready 显示，
		# 避免带着上一回合遗留的"已准备"进来（服务器 _room_begin_next_prep 会最终确认）。
		if team_local_slot >= 0 and team_local_slot < team_ready.size():
			team_ready[team_local_slot] = false
		team_lobby_changed.emit()

# Host-only: once everyone in the round is ready, launch the battle for all.
func _team_maybe_start_round() -> void:
	if not is_host or not team_round_active or not team_all_ready():
		return
	team_round_active = false
	GameState.team_slot_states = team_slot_states.duplicate()
	_rpc_team_round_start.rpc()
	team_round_start.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_team_round_start() -> void:
	team_round_active = false
	GameState.team_slot_states = team_slot_states.duplicate()
	team_round_start.emit()

# B3: host computes both teams' replays and sends each player their team's one.
func team_broadcast_replays(replay_a: Dictionary, replay_b: Dictionary) -> void:
	if not is_host:
		return
	for peer_id in _team_peer_slot:
		var slot: int = _team_peer_slot[peer_id]
		_rpc_team_replay.rpc_id(peer_id, replay_a if slot < 3 else replay_b, replay_b if slot < 3 else replay_a)

@rpc("authority", "call_remote", "reliable")
func _rpc_team_replay(replay: Dictionary, rival_replay: Dictionary = {}) -> void:
	team_replay = replay
	team_replay_rival = rival_replay
	_net_log("client received replay round=%d kind=%s" % [GameState.round_index, str(replay.get("kind", ""))])
	team_replay_received.emit()

func team_submit_board(snapshot: Dictionary) -> void:
	if not team_active or team_local_slot < 0:
		return
	# 提交前校准：快照回合号落后服务器权威值就重盖戳，否则会被 wrong_round 静默拒收
	if not is_host and server_round_index > int(snapshot.get("round", 0)):
		snapshot = snapshot.duplicate(true)
		snapshot.round = server_round_index
		GameState.round_index = maxi(GameState.round_index, server_round_index)
	_last_team_submission = snapshot
	if is_host:
		_team_boards_collecting[team_local_slot] = snapshot
		_team_try_finalize_boards()
	else:
		_rpc_team_submit_board.rpc_id(1, team_local_slot, snapshot)

func _team_try_finalize_boards() -> void:
	if not is_host:
		return
	for i in TEAM_SLOTS:
		if str(team_slot_states[i]) == "player" and not _team_boards_collecting.has(i):
			return
	var boards: Dictionary = {}
	for i in TEAM_SLOTS:
		if str(team_slot_states[i]) == "player":
			boards[i] = _team_boards_collecting[i]
	team_boards = boards
	_rpc_team_boards.rpc(boards, shared_seed)
	team_boards_ready.emit()
	if _dedicated_server:
		_team_compute_and_broadcast_replays()

func _team_compute_and_broadcast_replays() -> void:
	# Server-side authoritative battle calculation. Clients submit boards and
	# only play the replay/result returned by this host.
	if not is_host:
		return
	GameState.team_mode = true
	GameState.team_slot_states = team_slot_states.duplicate()
	# 故意用同步版而非 compute_team_replay_async：这是专用服务器路径，冻结不影响
	# 手机端；且计算前刚写入的 GameState 全局在分帧 await 期间可能被其他逻辑改掉。
	var replay_a := BattleSim.compute_team_replay(0)
	var replay_b := BattleSim.compute_team_replay(1)
	BattleSim.stamp_team_round_damages(replay_a, replay_b)
	team_broadcast_replays(replay_a, replay_b)

func team_boards_available() -> bool:
	return not team_boards.is_empty() or not _has_any_team_player()

func _has_any_team_player() -> bool:
	for i in TEAM_SLOTS:
		if i < team_slot_states.size() and str(team_slot_states[i]) == "player":
			return true
	return false

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_submit_board(slot: int, snapshot: Dictionary) -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		if not _rate_ok(sender, "submit_board"):
			return
		var room := _room_for_peer(sender)
		if room.is_empty() or int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != slot:
			_net_log("board rejected reason=bad_peer_or_slot peer=%d slot=%d" % [sender, slot])
			return
		if str(room.get("state", ROOM_LOBBY)) != ROOM_BATTLE:
			_net_log("board rejected reason=wrong_state peer=%d slot=%d state=%s" % [sender, slot, str(room.get("state", ""))])
			return
		var boards: Dictionary = room.get("boards", {})
		if boards.has(slot):
			_net_log("board rejected reason=duplicate room=%d round=%d slot=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), slot])
			return
		var validation := NetProtocol.validate_team_snapshot(snapshot, int(room.get("round_index", 1)))
		if not bool(validation.get("ok", false)):
			var reason := str(validation.get("reason", "malformed"))
			_net_log("board rejected reason=%s room=%d round=%d slot=%d" % [reason, int(room.get("id", 0)), int(room.get("round_index", 1)), slot])
			if reason == "protocol_mismatch":
				_rpc_team_room_closed.rpc_id(sender, "protocol_mismatch")
				if multiplayer.multiplayer_peer != null:
					multiplayer.multiplayer_peer.disconnect_peer(sender)
			elif reason.begins_with("wrong_round"):
				# 拒收不能是静默的：告知客户端权威回合，它会校准后自动重交
				_rpc_round_resync.rpc_id(sender, int(room.get("round_index", 1)), str(room.get("state", "")))
			return
		_shadow_audit_submission(room, slot, snapshot, validation.get("snapshot", {}))
		boards[slot] = validation.get("snapshot", {})
		room.boards = boards
		# 跨回合缓存最后一次合法棋盘：该座位掉线时用它补交（room.boards 每轮清空）
		var last_board: Dictionary = room.get("last_board", {})
		last_board[slot] = validation.get("snapshot", {})
		room.last_board = last_board
		_touch_room(room)
		_net_log("board accepted room=%d round=%d slot=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), slot])
		_room_try_finalize_boards(room)
		return
	if not is_host:
		return
	if int(_team_peer_slot.get(multiplayer.get_remote_sender_id(), -1)) != slot:
		return
	_team_boards_collecting[slot] = snapshot
	_team_try_finalize_boards()

@rpc("authority", "call_remote", "reliable")
func _rpc_team_boards(boards: Dictionary, seed: int) -> void:
	team_boards = boards
	shared_seed = seed
	team_boards_ready.emit()

# 服务器 wrong_round 拒收后的校准通知：对齐权威回合，并把刚被拒的棋盘
# 重盖戳补交一次（每回合最多一次，防循环）。修掉"落后一轮->提交永远被拒->
# 心跳被卡->被踢->重连回来还是旧回合"的静默死循环（实测日志确认过该链路）。
@rpc("authority", "call_remote", "reliable")
func _rpc_round_resync(server_round: int, server_phase_name: String) -> void:
	_net_log("round resync from server: round=%d phase=%s" % [server_round, server_phase_name])
	server_round_index = server_round
	server_phase = server_phase_name
	if GameState.round_index < server_round:
		GameState.round_index = server_round
	if not _last_team_submission.is_empty() and _resync_resubmitted_round != server_round:
		_resync_resubmitted_round = server_round
		var snap: Dictionary = _last_team_submission.duplicate(true)
		snap.round = server_round
		team_submit_board(snap)
	team_lobby_changed.emit()

func _room_try_finalize_boards(room: Dictionary) -> void:
	var states: Array = room.get("slot_states", [])
	var boards: Dictionary = room.get("boards", {})
	for i in TEAM_SLOTS:
		if str(states[i]) == "player" and not boards.has(i):
			return
	_net_log("all boards ready room=%d round=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1))])
	_set_room_state(room, ROOM_RESULT)
	# 棋盘已全部锁定，现在才生成本回合战斗 seed：客户端无法提前预演。
	# 看门狗/重连补交也走 _room_try_finalize_boards，所以「先替补齐、再摇 seed」这个
	# 顺序在所有路径上都成立。
	room.shared_seed = _roll_battle_seed()
	# 不再向专服客户端广播 boards。它是全部 6 人的完整快照（每个单位带整份 def），
	# 而专服路径的客户端不本地模拟——它等的是 team_replay，replay 自带 roster。
	# 这份广播因此是纯浪费，还顺带把 shared_seed 提前交到客户端手里（可预演战斗）。
	# _rpc_team_boards 方法保留：删方法会平移整套 RPC 的 wire ID，属破坏性变更。
	# 本地房主调试路径仍走 _team_try_finalize_boards 里的广播，不受影响。
	_room_compute_and_broadcast_replays(room)

func _room_compute_and_broadcast_replays(room: Dictionary) -> void:
	_net_log("server battle simulation started room=%d round=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1))])
	GameState.team_mode = true
	GameState.team_slot_states = (room.get("slot_states", []) as Array).duplicate()
	GameState.round_index = int(room.get("round_index", 1))
	GameState.pve_completed = int(room.get("pve_completed", 0))
	GameState.boss_completed = int(room.get("boss_completed", 0))
	# 让 schedule_kind_for_round 在服务器算战斗时用 room 权威的 final 状态，
	# 保证服务器和客户端对"第21回合是不是 final"判断一致（掐断 kind 不对称）。
	GameState.final_battle_complete = bool(room.get("final_battle_complete", false))
	# 第21回合法阵友军按血量区间召唤（_add_team_final_formation_allies 读
	# GameState.team_hp / enemy_team_hp）。服务器进程这两个全局从没人写过，
	# 恒为初始 50，导致双方永远召出最后一档厄夜；必须从 room 权威血量同步。
	# final 棋局是规范化的："player" 侧恒为 A 队，所以 [0]=A / [1]=B 两次
	# compute_team_replay 都成立。
	var room_hp: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	GameState.team_hp = int(room_hp[0])
	GameState.enemy_team_hp = int(room_hp[1])
	team_slot_states = (room.get("slot_states", []) as Array).duplicate()
	team_ready = (room.get("ready", []) as Array).duplicate()
	team_boards = (room.get("boards", {}) as Dictionary).duplicate(true)
	shared_seed = int(room.get("shared_seed", 0))
	# 故意用同步版：房间路径在计算前直接改 team_boards/shared_seed 等全局，
	# 分帧 await 会让其他房间的收尾插进来污染这份上下文。服务器冻结无所谓。
	var replay_a := BattleSim.compute_team_replay(0)
	var replay_b := BattleSim.compute_team_replay(1)
	BattleSim.stamp_team_round_damages(replay_a, replay_b)
	var match_states := _room_build_match_states(room, replay_a, replay_b)
	room.last_match_state = match_states
	_net_log("server replay/result generated room=%d round=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1))])
	_metrics_log_payloads(room, replay_a, replay_b, match_states)
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if not _peer_connected(int(peer_id)):
			continue
		var slot := int((room.get("peer_slot", {}) as Dictionary)[peer_id])
		# 顺序要紧：match_state（几百字节，权威结算）必须排在 replay（可达数 MB）之前。
		# 反过来时结算状态被压在大包后面，弱网重传期间玩家就卡在「战斗打完但结算不来」——
		# 这正是 match_state 超时的直接成因。replay 只是播放素材，晚到无所谓。
		_rpc_receive_match_state.rpc_id(int(peer_id), match_states.get(slot, {}))
		var own_replay: Dictionary = replay_a if slot < 3 else replay_b
		var rival_replay: Dictionary = replay_b if slot < 3 else replay_a
		if not ServerFlags.get_bool("send_rival_replay"):
			rival_replay = {}
		_rpc_team_replay.rpc_id(int(peer_id), own_replay, rival_replay)
		_net_log("match_state/replay sent room=%d round=%d peer=%d slot=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), int(peer_id), slot])
	room.boards = {}

# 影子审计：只记录、不拦截。上线前必须先知道自己的误判率——直接开拦截会把
# 数据表不同步、存档迁移、重连边界上的诚实玩家一起判成作弊。
# 跑够一周零差异，再把这些规则翻成硬拒收（见整改方案「影子模式」）。
func _shadow_audit_submission(room: Dictionary, slot: int, raw_snapshot: Variant, clean: Dictionary) -> void:
	if typeof(raw_snapshot) != TYPE_DICTIONARY:
		return
	var raw: Dictionary = raw_snapshot
	var round_index := int(room.get("round_index", 1))

	# (1) 宝物数量上界：宝物在宝物轮「战后」发放，所以提交第 N 回合棋盘时，
	# 合法上限 = 严格小于 N 的宝物轮次数。用 <= N 会让玩家在第 4 回合开打前就多带一件。
	# 注意这条隐含依赖服务端与客户端 round_schedule.json 一致 —— 数据表哈希握手
	# （第 3 批）上线前，它只能停留在影子模式。
	var max_treasures := 0
	for r in range(1, round_index):
		if RoundService.is_treasure_round(r):
			max_treasures += 1
	var owned: Array = clean.get("treasures", [])
	if owned.size() > max_treasures:
		_net_log("shadow treasure_overflow room=%d round=%d slot=%d owned=%d max=%d" % [
			int(room.get("id", 0)), round_index, slot, owned.size(), max_treasures])

	# (2) 金币差值：服务端只知道上一战结算后的值，不知道备战期的买/卖/刷新/祭坛/赌博。
	# 所以这里绝不能拦截，只统计分布——赌博一次就能合法翻倍，任何「上界规则」都会误伤。
	# 攒够真实分布后，才知道 P1 的备战账本要覆盖哪些路径。
	var slot_gold: Array = room.get("slot_gold", [])
	if slot < slot_gold.size() and slot_gold[slot] != null:
		var reported := int(raw.get("gold", 0))
		var expected := int(slot_gold[slot])
		if reported != expected:
			_net_log("shadow gold_delta room=%d round=%d slot=%d reported=%d last_settled=%d delta=%d" % [
				int(room.get("id", 0)), round_index, slot, reported, expected, reported - expected])

	# (3) syn 口径比对：服务端已经改为自己重建（见 NetProtocol.rebuild_syn_from_board）。
	# 这里比的是「客户端派生的和服务端重建的一不一致」——不一致意味着两边对羁绊的
	# 理解有分歧，玩家界面会和实际战斗对不上。
	var client_syn = raw.get("syn", {})
	if typeof(client_syn) == TYPE_DICTIONARY:
		var server_syn: Dictionary = clean.get("syn", {})
		for key in server_syn.keys():
			if not (client_syn as Dictionary).has(key):
				continue
			if str(server_syn[key]) != str((client_syn as Dictionary)[key]):
				_net_log("shadow syn_mismatch room=%d round=%d slot=%d key=%s server=%s client=%s" % [
					int(room.get("id", 0)), round_index, slot, str(key),
					str(server_syn[key]), str((client_syn as Dictionary)[key])])

# 载荷埋点（默认关，见 ServerFlags）。量的是「决定要不要投资确定性客户端模拟」所需的
# 事实：replay 原始/压缩后字节数、team_boards 与 match_state 的相对大小、序列化耗时。
# 这些数字在 docs/联机审计与整改方案.md 里目前全是估算，测量周结束后要回填。
#
# 注意：var_to_bytes 一份大 replay 本身有 CPU 开销，而服务器是同步主循环——所以它
# 挂在开关后面，并支持每 N 场采样一次，不允许长期裸跑。
func _metrics_log_payloads(room: Dictionary, replay_a: Dictionary, replay_b: Dictionary, match_states: Dictionary) -> void:
	if not ServerFlags.should_sample_battle():
		return
	var t0 := Time.get_ticks_usec()
	var raw_a := var_to_bytes(replay_a)
	var raw_b := var_to_bytes(replay_b)
	var serialize_usec := Time.get_ticks_usec() - t0
	var t1 := Time.get_ticks_usec()
	var zst_a := raw_a.compress(FileAccess.COMPRESSION_ZSTD)
	var compress_usec := Time.get_ticks_usec() - t1
	var boards_bytes := var_to_bytes(room.get("boards", {})).size()
	var ms_bytes := var_to_bytes(match_states).size()
	var frames_a: Array = replay_a.get("frames", [])
	_net_log("metrics room=%d round=%d kind=%s frames=%d replay_a_raw=%d replay_b_raw=%d replay_a_zstd=%d ratio=%.3f boards=%d match_state=%d ser_usec=%d zstd_usec=%d" % [
		int(room.get("id", 0)),
		int(room.get("round_index", 1)),
		str(replay_a.get("kind", "")),
		frames_a.size(),
		raw_a.size(),
		raw_b.size(),
		zst_a.size(),
		(float(zst_a.size()) / float(maxi(1, raw_a.size()))),
		boards_bytes,
		ms_bytes,
		serialize_usec,
		compress_usec,
	])

func _room_build_match_states(room: Dictionary, replay_a: Dictionary, replay_b: Dictionary) -> Dictionary:
	var completed_round := int(room.get("round_index", 1))
	var team_hp: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	var res_a: Dictionary = replay_a.get("result", {})
	var res_b: Dictionary = replay_b.get("result", {})
	var kind := str(replay_a.get("kind", "pve"))
	# 金币结算要按队伍的胜负给。PVE/Boss：两队各打各的怪，胜负互相独立；
	# PVP：replay 是规范化棋局（A 队恒为 "player" 方），B 队胜负取反。
	# 同款视角反转也在 Main._on_team_battle_finished 与 BattleUI._local_player_wins。
	var team_wins := [bool(res_a.get("player_wins", false)), false]
	if kind == "pvp":
		team_wins[1] = not bool(res_a.get("player_wins", false))
	else:
		team_wins[1] = bool(res_b.get("player_wins", false))
	# 连败计数按队维护：胜利清零、失败 +1。每回合只能走一次，不能放进座位循环。
	var loss_streak: Array = room.get("team_loss_streak", [0, 0])
	if loss_streak.size() < 2:
		loss_streak = [0, 0]
	for t in 2:
		loss_streak[t] = 0 if team_wins[t] else int(loss_streak[t]) + 1
	room.team_loss_streak = loss_streak
	var hp_a := maxi(0, int(team_hp[0]) - maxi(0, int(res_a.get("team_damage_self", 0))))
	var hp_b := maxi(0, int(team_hp[1]) - maxi(0, int(res_a.get("team_damage_rival", 0))))
	if hp_a > 0:
		hp_a = mini(GameState.START_FORMATION_HP, hp_a + maxi(0, int(res_a.get("team_heal_self", 0))))
	if hp_b > 0:
		hp_b = mini(GameState.START_FORMATION_HP, hp_b + maxi(0, int(res_a.get("team_heal_rival", 0))))
	room.team_hp = [hp_a, hp_b]
	if kind == "pve":
		room.pve_completed = int(room.get("pve_completed", 0)) + 1
	elif kind == "boss":
		room.boss_completed = int(room.get("boss_completed", 0)) + 1
	var run_over := hp_a <= 0 or hp_b <= 0 or completed_round >= GameState.FINAL_ROUND
	# 记入 room：对局结束后服务器不再开新回合、也不再把第21回合当 final 重算（见
	# _room_begin_next_prep / _room_compute_and_broadcast_replays），掐断卡死循环。
	if run_over:
		room.final_battle_complete = true
	var team_a_won: bool
	if completed_round >= GameState.FINAL_ROUND:
		# 最终局（设计意图）：只看这一战谁赢，无视之前的血量差。整场只有一个
		# player_wins（A队视角），B队 team_run_won 取反 -> 两队必定相反、不会都赢，
		# 且与战斗结束字幕（同样基于 player_wins）显示一致。
		team_a_won = bool(res_a.get("player_wins", false))
	else:
		# 中途因某队血量归零而结束的普通局：存活方赢
		team_a_won = hp_a >= hp_b
		if hp_a <= 0 and hp_b > 0:
			team_a_won = false
		elif hp_b <= 0 and hp_a > 0:
			team_a_won = true
		elif kind == "pvp" and hp_a <= 0 and hp_b <= 0:
			team_a_won = bool(res_a.get("player_wins", false))
	var next_round := mini(completed_round + 1, GameState.FINAL_ROUND)
	var out := {}
	var slot_gold: Array = room.get("slot_gold", [])
	if slot_gold.size() < TEAM_SLOTS:
		slot_gold.resize(TEAM_SLOTS)
		for i in TEAM_SLOTS:
			if slot_gold[i] == null:
				slot_gold[i] = GameState.START_GOLD
	var boards: Dictionary = room.get("boards", {})
	for slot in TEAM_SLOTS:
		var replay := replay_a if slot < 3 else replay_b
		var result: Dictionary = replay.get("result", {})
		var snap: Dictionary = boards.get(slot, {})
		var own_team := GameConstants.team_of_slot(slot)
		var gold_before := int(snap.get("gold", slot_gold[slot]))
		var gold_after := _server_gold_after_battle(gold_before, result, slot, snap, {
			"kind": kind,
			"player_wins": bool(team_wins[own_team]),
			"round_index": completed_round,
			"loss_streak_after": int(loss_streak[own_team]),
		})
		slot_gold[slot] = gold_after
		out[slot] = {
			"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
			"completed_round": completed_round,
			"round_index": next_round,
			"kind": kind,
			"slot": slot,
			"team_hp": hp_a if own_team == 0 else hp_b,
			"enemy_team_hp": hp_b if own_team == 0 else hp_a,
			"gold": gold_after,
			"pve_completed": int(room.get("pve_completed", 0)),
			"boss_completed": int(room.get("boss_completed", 0)),
			"loss_streak": int(loss_streak[own_team]),
			"run_over": run_over,
			"final_battle_complete": completed_round >= GameState.FINAL_ROUND,
			"team_run_won": team_a_won if own_team == 0 else not team_a_won,
			"pending_treasure": _server_pending_treasure(completed_round, snap),
		}
	room.slot_gold = slot_gold
	_net_log("official match_state generated room=%d round=%d hp=%s gold=%s run_over=%s" % [int(room.get("id", 0)), completed_round, str(room.team_hp), str(slot_gold), str(run_over)])
	return out

# 专用服务器的权威结算：与本地/房主的 Main._on_team_battle_finished 共用
# EconomyService.settle_post_battle_gold，两处不能再各写各的。
# round_ctx 由 _room_build_match_states 按队伍算好：kind / player_wins /
# round_index / loss_streak_after。
func _server_gold_after_battle(gold_before: int, result: Dictionary, slot: int, snapshot: Dictionary, round_ctx: Dictionary) -> int:
	return EconomyService.settle_post_battle_gold({
		"gold_before": gold_before,
		"kill_gold": EconomyService.kill_gold_for_slot(result, slot),
		"bonus_gold": int(result.get("bonus_gold", 0)),
		"kind": str(round_ctx.get("kind", "pve")),
		"player_wins": bool(round_ctx.get("player_wins", false)),
		"round_index": int(round_ctx.get("round_index", 0)),
		"loss_streak_after": int(round_ctx.get("loss_streak_after", 0)),
		"boss_hp_current": int(result.get("enemy_hp_current", 0)),
		"boss_hp_max": maxi(1, int(result.get("enemy_hp_max", 1))),
		"merchant_gold": EconomyService.merchant_gold_from_board(NetProtocol.extract_board(snapshot)),
		"treasures": snapshot.get("treasures", []),
		"pet_id": NetProtocol.extract_pet(snapshot),
	})

func _server_pending_treasure(completed_round: int, snapshot: Dictionary) -> Dictionary:
	var owned: Array = snapshot.get("treasures", [])
	if not RoundService.is_treasure_round(completed_round) or owned.size() >= TreasureService.MAX_OWNED:
		return {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	var candidates := _server_roll_treasure_candidates(owned, 3)
	if candidates.is_empty():
		return {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	return {"active": true, "round": completed_round, "candidates": candidates, "refresh_index": 0}

func _server_roll_treasure_candidates(owned: Array, count: int) -> Array:
	var pool := []
	for t in DataRegistry.get_table("treasures").get("treasures", []):
		var tid := str((t as Dictionary).get("id", ""))
		if not tid.is_empty() and not owned.has(tid):
			pool.append(tid)
	# 洗牌用 Crypto，不消费全局 RNG：宝物候选是玩家每轮都能观测到的输出，
	# 让它和 token/房间 id 共用一条 PCG32 流等于持续泄漏那条流的状态。
	for i in range(pool.size() - 1, 0, -1):
		var j := int(_crypto.generate_random_bytes(4).decode_u32(0)) % (i + 1)
		var tmp = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	return pool.slice(0, mini(count, pool.size()))

func is_online() -> bool:
	return state == SessionState.READY

# opponent_board_snapshot 是单机 PVP 回合的敌方棋盘来源（BattleSimulator
# _build_pvp_fighters / _enemy_syn_for_kind）。它已不再有任何网络收发——
# 1v1 P2P 联机路径（start_host/join_host 及其 RPC、ready/棋盘互传、权威结果回传）
# 已整体删除，组队联机走的是 team_* 那一套。
func receive_opponent_snapshot(snapshot: Variant) -> void:
	opponent_board_snapshot = NetProtocol.normalize_snapshot(snapshot)
	session_changed.emit()

func clear_opponent_snapshot() -> void:
	opponent_board_snapshot.clear()
	session_changed.emit()

func disconnect_session() -> void:
	_net_log("user quit session")
	if team_active and not is_host and multiplayer.multiplayer_peer != null:
		_rpc_team_leave.rpc_id(1)
	# 主动退出 = 干净离场，作废重连凭证
	SaveManager.clear_reconnect()
	reset()

func reset_peer_only() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null

func reset() -> void:
	reset_peer_only()
	state = SessionState.OFFLINE
	_join_elapsed = 0.0
	is_host = false
	opponent_board_snapshot.clear()
	latest_match_state.clear()
	shared_seed = 0
	last_error = ""
	team_active = false
	team_local_slot = -1
	team_room_id = 0
	team_slot_states = []
	team_ready = []
	team_round_active = false
	_team_peer_slot.clear()
	session_token = ""
	reconnect_address = ""
	pending_abandon_token = ""
	team_leader_slot = 0
	_reconnect_retry_left = 0.0
	_ping_accum = 0.0
	_last_pong_at = 0.0
	server_round_index = 0
	server_phase = ""
	_last_team_submission = {}
	_resync_resubmitted_round = 0
	session_changed.emit()

# --- 断线重连 ---------------------------------------------------------------

# 掉线 -> 进入 RECONNECTING：保留 team 上下文，仅重置网络对象，自动重试。
func _begin_reconnect(reason: String) -> void:
	if session_token.is_empty() or reconnect_address.is_empty():
		return
	reset_peer_only()
	if state == SessionState.RECONNECTING:
		return
	_net_log("connection lost (%s) -> reconnecting to %s" % [reason, reconnect_address])
	state = SessionState.RECONNECTING
	last_error = tr("net_status_reconnecting")
	_reconnect_retry_left = 0.0
	_last_pong_at = 0.0
	session_changed.emit()

func _attempt_reconnect() -> void:
	reset_peer_only()
	var p := ENetMultiplayerPeer.new()
	if p.create_client(reconnect_address, remote_port) != OK:
		return  # 下个周期再试
	_peer = p
	multiplayer.multiplayer_peer = _peer
	# 保持 RECONNECTING；连上后 _on_connected_to_server 会带 token 请求恢复

# 玩家点"取消并返回主菜单"：放弃重连，彻底清场。
func cancel_reconnect() -> void:
	SaveManager.clear_reconnect()
	reset()

# app 重开后凭本地存的 token 恢复对局（Main 在启动时调用）。
func begin_resume_from_disk(token: String, address: String) -> void:
	reset()
	team_active = true
	session_token = token
	reconnect_address = address
	remote_address = address
	remote_port = DEFAULT_PORT
	state = SessionState.RECONNECTING
	_reconnect_retry_left = 0.0
	session_changed.emit()

# 会话 token / 战斗 seed / 短码 一律走 Crypto，不再消费全局 RNG。
# 旧实现 "%d-%d-%d" % [ticks, randi(), randi()] 有两个问题：一是熵不足且可预测；
# 二是把两个连续的原始 randi() 输出直接交到每个玩家手里——而同一条全局 PCG32 流
# 还在给房间 id、shared_seed、宝物候选洗牌供数，拿到连续输出可做状态恢复。
var _crypto := Crypto.new()

func _make_token() -> String:
	return _crypto.generate_random_bytes(32).hex_encode()

# 短码给玩家手输，所以不能太长；用 base32 去掉易混字符（0/O/1/I），
# 10 位 × 32 符号 ≈ 2^50，配合限流与失败计数，在线枚举不再可行。
const PUBLIC_TOKEN_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const PUBLIC_TOKEN_LENGTH := 10
const PUBLIC_TOKEN_MAX_TRIES := 8

func _make_public_token() -> String:
	# 原实现是 while 无界循环：短码空间被占满时服务器会在这里死循环卡住。
	for _try in PUBLIC_TOKEN_MAX_TRIES:
		var raw := _crypto.generate_random_bytes(PUBLIC_TOKEN_LENGTH)
		var id := ""
		for b in raw:
			id += PUBLIC_TOKEN_ALPHABET[int(b) % PUBLIC_TOKEN_ALPHABET.length()]
		if not _public_token_seat.has(id):
			return id
	_net_log("public token space exhausted after %d tries" % PUBLIC_TOKEN_MAX_TRIES)
	return ""

# 每回合战斗 seed：锁盘之后才生成，用后即弃。
# 旧实现是房间创建时 randi() 一次、整局不变，且随 boards 广播和 resume 下发——
# 客户端因此在提交棋盘前就知道 seed，可以本地把 PVE/Boss 回合暴力预演到最优解。
func _roll_battle_seed() -> int:
	var raw := _crypto.generate_random_bytes(8)
	var v := 0
	for b in raw:
		v = (v << 8) | int(b)
	return absi(v)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_public_token_request() -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "public_token"):
		return
	var id := _make_public_token()
	if id.is_empty():
		_rpc_team_action_failed.rpc_id(sender, "token_unavailable")
		return
	_public_token_seat[id] = ""
	_rpc_public_token_created.rpc_id(sender, id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_room_list_request() -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "room_list"):
		return
	_rpc_team_room_list.rpc_id(sender, _public_room_list())

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_create_room(public_id: String = "") -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "create_room"):
		return
	# 一人一房不变量：不加这条时，循环调用会把 _rooms 撑爆，并在每个旧房间里留下
	# 一个永不 ready 的幽灵座位（实测 25 次调用 = 25 个幽灵座位）。
	var existing := _room_for_peer(sender)
	if not existing.is_empty():
		if str(existing.get("state", ROOM_LOBBY)) == ROOM_LOBBY:
			_room_remove_peer(existing, sender)   # 还在大厅：释放旧座位后允许换房
		else:
			_rpc_team_action_failed.rpc_id(sender, "already_in_match")
			return
	if _rooms.size() >= MAX_ROOMS:
		_net_log("room cap reached (%d) -> refusing create peer=%d" % [MAX_ROOMS, sender])
		_rpc_team_action_failed.rpc_id(sender, "server_busy")
		return
	_assign_peer_to_room(sender, _new_room(), public_id.strip_edges().to_upper())

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_join_room(room_id: int, public_id: String = "") -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "join_room"):
		return
	var existing := _room_for_peer(sender)
	if not existing.is_empty():
		if int(existing.get("id", 0)) == room_id:
			return                                 # 已经在这个房间里，忽略重复请求
		if str(existing.get("state", ROOM_LOBBY)) == ROOM_LOBBY:
			_room_remove_peer(existing, sender)
		else:
			_rpc_team_action_failed.rpc_id(sender, "already_in_match")
			return
	var room: Dictionary = _rooms.get(room_id, {})
	if room.is_empty():
		_rpc_team_action_failed.rpc_id(sender, "room_not_found")
		return
	if str(room.get("state", "")) != ROOM_LOBBY:
		_rpc_team_action_failed.rpc_id(sender, "room_started")
		return
	if _room_next_free_slot(room) < 0:
		_rpc_team_action_failed.rpc_id(sender, "room_full")
		return
	_assign_peer_to_room(sender, room, public_id.strip_edges().to_upper())

@rpc("any_peer", "call_remote", "reliable")
func _rpc_public_resume_request(public_id: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "public_resume"):
		return
	var id := public_id.strip_edges().to_upper()
	var token := str(_public_token_seat.get(id, ""))
	if token.is_empty():
		# 猜错也计入 strike：短码枚举是可行的在线攻击面，失败次数必须有代价。
		_rate_ok(sender, "public_resume")
		_rpc_resume_failed.rpc_id(sender, "token_id_unknown")
		return
	public_token_id = id
	_rpc_resume_request(token)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_ping() -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	_peer_last_ping[sender] = _now()
	_rpc_pong.rpc_id(sender)

@rpc("authority", "call_remote", "reliable")
func _rpc_pong() -> void:
	if _pong_gap_logged:
		_pong_gap_logged = false
		_net_log("pong recovered")
	_last_pong_at = _now()
	# RTT 实测值：排查掉线时「网络本来就慢」和「被大包堵住」是两回事，只有静默
	# 告警区分不开。超过阈值才记，正常情况下不刷日志。
	if _ping_sent_at > 0:
		var rtt := Time.get_ticks_msec() - _ping_sent_at
		_ping_sent_at = 0
		if rtt > PING_RTT_LOG_MS:
			_net_log("pong rtt=%dms" % rtt)

# 服务器：心跳超时的 peer 主动断开，走正常掉线->座位保留流程。
func _tick_heartbeat_timeouts() -> void:
	var now := _now()
	for peer_id in _peer_last_ping.keys():
		if now - float(_peer_last_ping[peer_id]) > HEARTBEAT_TIMEOUT_SEC:
			_net_log("heartbeat timeout peer=%d -> force disconnect" % int(peer_id))
			_peer_last_ping.erase(peer_id)
			if multiplayer.multiplayer_peer != null:
				multiplayer.multiplayer_peer.disconnect_peer(int(peer_id))

# 每秒扫描：ENet 已经丢了、但 peer_disconnected 信号没触发的"僵尸连接"（实测
# 存在，日志表现为对某 peer 发 RPC 报 unknown peer ID，但它从没走过掉线清理）。
# 僵尸会永远占着 peer_slot：房间判不空、永不回收，且每次广播都对它报错烧 CPU。
# 主动替它走一遍正常掉线流程（大厅=释放座位；开赛=保留座位等重连）。
func _reap_zombie_peers() -> void:
	for peer_key in _peer_room.keys():
		var pid := int(peer_key)
		if _peer_connected(pid):
			continue
		_net_log("zombie peer reaped peer=%d" % pid)
		_peer_last_ping.erase(pid)
		var room := _room_for_peer(pid)
		if room.is_empty():
			_peer_room.erase(pid)
			continue
		if str(room.get("state", ROOM_LOBBY)) == ROOM_LOBBY:
			_room_remove_peer(room, pid)
		else:
			_room_reserve_peer(room, pid)

# 战斗收集阶段看门狗：某 player 槽超时没交棋盘（客户端卡死/重连落备战/半开连接
# 等任何原因），有缓存棋盘就代交、没有就转 AI——保证一个人永远卡不住整个房间。
func _tick_board_watchdog() -> void:
	var now := _now()
	for room in _rooms.values():
		if str(room.get("state", "")) != ROOM_BATTLE:
			continue
		if now - float(room.get("state_started_at", now)) < BOARD_SUBMIT_TIMEOUT_SEC:
			continue
		var states: Array = room.get("slot_states", [])
		var boards: Dictionary = room.get("boards", {})
		var last_board: Dictionary = room.get("last_board", {})
		var changed := false
		for i in TEAM_SLOTS:
			if i >= states.size() or str(states[i]) != "player" or boards.has(i):
				continue
			if last_board.has(i):
				boards[i] = last_board[i]
				_net_log("board watchdog auto-submit room=%d round=%d slot=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), i])
			else:
				_net_log("board watchdog no cache room=%d slot=%d -> AI takeover" % [int(room.get("id", 0)), i])
				_room_auto_complete_seat(room, i)
			changed = true
		if changed:
			room.boards = boards
			_room_try_finalize_boards(room)

# 客户端带 token 请求恢复座位。
@rpc("any_peer", "call_remote", "reliable")
func _rpc_resume_request(token: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var seat: Dictionary = _token_seat.get(token, {})
	if seat.is_empty():
		_net_log("resume failed reason=token_unknown peer=%d" % sender)
		_rpc_resume_failed.rpc_id(sender, "token_unknown")
		return
	var room: Dictionary = _rooms.get(int(seat.get("room_id", 0)), {})
	if room.is_empty() or str(room.get("state", "")) == ROOM_CLOSED:
		_token_seat.erase(token)
		_net_log("resume failed reason=room_gone peer=%d" % sender)
		_rpc_resume_failed.rpc_id(sender, "room_gone")
		return
	# 对局已打完的房间不可恢复：按失败处理让客户端回主菜单。否则重连者会被
	# resume 进一个永不开下一回合的死房间（客户端落备战界面干等）——实测日志里
	# 出现过 "resume ok state=result" 后玩家卡死的案例。
	if bool(room.get("final_battle_complete", false)):
		_token_seat.erase(token)
		_net_log("resume failed reason=match_over peer=%d" % sender)
		_rpc_resume_failed.rpc_id(sender, "match_over")
		return
	var slot := int(seat.get("slot", -1))
	if slot < 0 or slot >= TEAM_SLOTS:
		_net_log("resume failed reason=bad_slot peer=%d" % sender)
		_rpc_resume_failed.rpc_id(sender, "bad_slot")
		return
	var peer_slot: Dictionary = room.get("peer_slot", {})
	for pid in peer_slot.keys():
		if int(peer_slot[pid]) == slot and int(pid) != sender:
			_net_log("resume failed reason=seat_taken room=%d slot=%d peer=%d" % [int(room.get("id", 0)), slot, sender])
			_rpc_resume_failed.rpc_id(sender, "seat_taken")
			return
	# 连接握手时这个 peer 可能已被自动分进某个大厅房占了座——撤掉那个占位，
	# 否则两个房间会同时把他算作成员、同时向他广播大厅状态（互相覆盖显示）。
	var prev_room := _room_for_peer(sender)
	if not prev_room.is_empty() and int(prev_room.get("id", 0)) != int(room.get("id", 0)):
		_net_log("resume: releasing auto-assigned lobby seat room=%d peer=%d" % [int(prev_room.get("id", 0)), sender])
		_room_remove_peer(prev_room, sender)
	peer_slot[sender] = slot
	room.peer_slot = peer_slot
	_peer_room[sender] = int(room.get("id", 0))
	# 座位可能仍是 reserved，也可能宽限已过被转成了 dummy(AI 顶着)——都要变回 player。
	# A 重连后需重新准备，故 ready 复位 false。
	var states: Array = room.get("slot_states", [])
	if slot < states.size():
		states[slot] = "player"
		room.slot_states = states
	var ready_arr: Array = room.get("ready", [])
	if slot < ready_arr.size():
		ready_arr[slot] = false
		room.ready = ready_arr
	(room.get("reserved", {}) as Dictionary).erase(slot)
	(room.get("reserve_deadline", {}) as Dictionary).erase(slot)
	room.empty_since = 0.0
	_peer_last_ping[sender] = _now()
	# 全员掉线后有人重连时，原房主可能还没回来 -> 把房主顺延给这个在线玩家，
	# 否则房间没房主、谁都开不了游戏/加不了 AI。在构建 payload 前做，payload 才带对。
	_maybe_promote_leader(room)
	_touch_room(room)
	_net_log("resume ok room=%d slot=%d peer=%d state=%s" % [int(room.get("id", 0)), slot, sender, str(room.get("state", ""))])
	var hp: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	var own_team := GameConstants.team_of_slot(slot)
	var slot_gold: Array = room.get("slot_gold", [])
	var gold := GameState.START_GOLD
	if slot < slot_gold.size() and slot_gold[slot] != null:
		gold = int(slot_gold[slot])
	# 战斗收集阶段重连：这一轮已经开打，重连客户端落回备战、不会再补交棋盘，
	# 而它的座位刚被翻回 player（服务器会死等它的棋盘）。有缓存就替它补交，
	# 本轮正常结算；没缓存就留给看门狗转 AI——两条路都不会卡住别人。
	if str(room.get("state", "")) == ROOM_BATTLE:
		var boards_now: Dictionary = room.get("boards", {})
		var lb: Dictionary = room.get("last_board", {})
		if not boards_now.has(slot) and lb.has(slot):
			boards_now[slot] = lb[slot]
			room.boards = boards_now
			_net_log("resume auto-submit cached board room=%d round=%d slot=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), slot])
	# 结算阶段 round_index 还停在刚打完的那一轮（惰性推进），客户端要进的是下一轮。
	# 给旧值会让客户端从此落后一轮、之后提交全被 wrong_round 拒收（实测日志确认）。
	var resume_round := int(room.get("round_index", 1))
	if str(room.get("state", "")) == ROOM_RESULT:
		resume_round = mini(resume_round + 1, GameState.FINAL_ROUND)
	var payload := {
		"phase": str(room.get("state", ROOM_PREP)),
		"room_id": int(room.get("id", 0)),
		"slot": slot,
		"leader_slot": int(room.get("leader_slot", 0)),
		"slot_states": (room.get("slot_states", []) as Array).duplicate(),
		"ready": (room.get("ready", []) as Array).duplicate(),
		"round_index": resume_round,
		# 不再下发 shared_seed：重连恢复只需要回合与阶段，而提前拿到 seed 等于
		# 恢复了「备战期就能预演本回合战斗」的能力。客户端不本地模拟，用不到它。
		"team_hp": int(hp[own_team]),
		"enemy_team_hp": int(hp[1 - own_team]),
		"gold": gold,
	}
	_rpc_resume_state.rpc_id(sender, payload)
	_broadcast_room_lobby(room)
	# 本回合结果已算出（结算阶段）：补发该座位的 match_state，客户端直接跳过战斗
	if str(room.get("state", "")) == ROOM_RESULT:
		var ms: Dictionary = (room.get("last_match_state", {}) as Dictionary).get(slot, {})
		if not ms.is_empty():
			_rpc_receive_match_state.rpc_id(sender, ms)
	# 战斗阶段：上面可能刚替它补交了棋盘，凑齐就立即结算，别等下一个提交者
	elif str(room.get("state", "")) == ROOM_BATTLE:
		_room_try_finalize_boards(room)

@rpc("authority", "call_remote", "reliable")
func _rpc_resume_state(payload: Dictionary) -> void:
	team_active = true
	team_local_slot = int(payload.get("slot", -1))
	team_room_id = int(payload.get("room_id", 0))
	team_leader_slot = int(payload.get("leader_slot", 0))
	team_slot_states = (payload.get("slot_states", []) as Array).duplicate()
	team_ready = (payload.get("ready", []) as Array).duplicate()
	shared_seed = int(payload.get("shared_seed", shared_seed))
	server_round_index = int(payload.get("round_index", 0))
	server_phase = str(payload.get("phase", ""))
	state = SessionState.READY
	last_error = ""
	_last_pong_at = _now()
	_net_log("resume state received slot=%d phase=%s round=%d" % [team_local_slot, str(payload.get("phase", "")), int(payload.get("round_index", 1))])
	session_changed.emit()
	team_lobby_changed.emit()
	resume_completed.emit(payload)

# 玩家开新游戏时放弃旧座位：旧房间还有其他在线玩家 -> 该座位转 AI(dummy)；
# 没人了就不管（空房间靠超时自清）。token 作废，之后连不回。
@rpc("any_peer", "call_remote", "reliable")
func _rpc_abandon_seat(token: String) -> void:
	if not _dedicated_server:
		return
	var seat: Dictionary = _token_seat.get(token, {})
	if seat.is_empty():
		return
	var room: Dictionary = _rooms.get(int(seat.get("room_id", 0)), {})
	var slot := int(seat.get("slot", -1))
	_token_seat.erase(token)
	if room.is_empty() or slot < 0 or slot >= TEAM_SLOTS:
		return
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	seat_tokens.erase(slot)
	room.seat_tokens = seat_tokens
	(room.get("reserved", {}) as Dictionary).erase(slot)
	(room.get("reserve_deadline", {}) as Dictionary).erase(slot)
	if _room_online_count(room) <= 0:
		# 房里没别人了：不转 AI，让空房间自然超时回收
		_net_log("seat abandoned room=%d slot=%d (room empty, will time out)" % [int(room.get("id", 0)), slot])
		return
	# 还有其他玩家：座位转 AI 顶上，并推进当前阶段
	_room_auto_complete_seat(room, slot)
	_net_log("seat abandoned room=%d slot=%d -> AI takeover" % [int(room.get("id", 0)), slot])

@rpc("authority", "call_remote", "reliable")
func _rpc_resume_failed(reason: String) -> void:
	_net_log("resume failed reason=%s" % reason)
	SaveManager.clear_reconnect()
	session_token = ""
	reconnect_address = ""
	reset_peer_only()
	team_active = false
	team_local_slot = -1
	state = SessionState.FAILED
	last_error = tr("net_err_resume_failed") % reason
	session_changed.emit()
	resume_failed.emit(reason)

func _local_host_allowed() -> bool:
	return _dedicated_server or NetworkConfig.ALLOW_LOCAL_HOST_DEBUG or OS.is_debug_build() or "--allow-local-host" in OS.get_cmdline_args()

func can_control_room() -> bool:
	# 房主可能因掉线顺延（team_leader_slot 由服务器广播），不再硬编码 0 号位
	return is_host or (team_active and team_local_slot == team_leader_slot)

# ENet 传输层超时放宽。默认最快 5 秒就可能单方面判死：手机一次重负载卡顿、
# 服务器一次 CPU 限速冻结都可能超过它——应用层心跳(20s)还没表态，底层先拆线。
# 放宽到 15~45 秒，把"判死权"交给应用层心跳 + 座位宽限这套可恢复的机制。
func _tune_peer_timeout(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var ep := enet.get_peer(peer_id)
	if ep != null:
		ep.set_timeout(64, 15000, 45000)

func _on_peer_connected(id: int) -> void:
	_net_log("client connected peer=%d protocol=%d" % [id, NetworkConfig.NETWORK_PROTOCOL_VERSION])
	_tune_peer_timeout(id)
	if team_active:
		if is_host:
			if _dedicated_server:
				_peer_last_ping[id] = _now()
				return
			var slot := _team_next_free_slot()
			if slot >= 0:
				team_slot_states[slot] = "player"
				_team_peer_slot[id] = slot
				# 本地调试房不支持重连，token 传空
				_rpc_team_assign_slot.rpc_id(id, slot, "")
			_team_broadcast_lobby()
			team_lobby_changed.emit()

func _on_peer_disconnected(id: int) -> void:
	_net_log("client disconnected peer=%d" % id)
	_peer_last_ping.erase(id)
	_rate_forget(id)
	# 短 token 映射过去从不清理，peer 断开也不 erase —— 内存只涨不降。
	var short_token := str(_peer_public_token.get(id, ""))
	if not short_token.is_empty():
		_peer_public_token.erase(id)
	if team_active:
		if _dedicated_server:
			var room := _room_for_peer(id)
			if not room.is_empty():
				# 大厅阶段掉线 = 直接释放座位（还没开赛，无需保留）；
				# 开赛后掉线 = 保留座位进入宽限，等 token 重连。
				if str(room.get("state", ROOM_LOBBY)) == ROOM_LOBBY:
					_room_remove_peer(room, id)
				else:
					_room_reserve_peer(room, id)
			return
		if is_host and _team_peer_slot.has(id):
			var slot: int = _team_peer_slot[id]
			team_slot_states[slot] = "empty"
			team_ready[slot] = false
			_team_peer_slot.erase(id)
			_team_broadcast_lobby()
			team_lobby_changed.emit()
		return
	clear_opponent_snapshot()
	state = SessionState.OFFLINE
	session_changed.emit()

func _assign_peer_to_room(peer_id: int, room: Dictionary = {}, public_id: String = "") -> void:
	if room.is_empty():
		room = _find_or_create_room()
	var slot := _room_next_free_slot(room)
	if slot < 0:
		_rpc_team_action_failed.rpc_id(peer_id, "room_full")
		return
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	var peer_slot: Dictionary = room.get("peer_slot", {})
	states[slot] = "player"
	ready[slot] = false
	peer_slot[peer_id] = slot
	room.slot_states = states
	room.ready = ready
	room.peer_slot = peer_slot
	room.empty_since = 0.0
	_peer_room[peer_id] = int(room.get("id", 0))
	_peer_last_ping[peer_id] = _now()
	# 签发会话 token：断线重连的凭证（非账号，一局一换）
	var token := _make_token()
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	seat_tokens[slot] = token
	room.seat_tokens = seat_tokens
	_token_seat[token] = {"room_id": int(room.get("id", 0)), "slot": slot}
	if not public_id.is_empty():
		_public_token_seat[public_id] = token
		_peer_public_token[peer_id] = public_id
	_touch_room(room)
	_rpc_team_assign_slot.rpc_id(peer_id, slot, token, int(room.get("id", 0)), public_id)
	_rpc_team_lobby.rpc_id(peer_id, states, ready)
	_net_log("player joined room=%d peer=%d slot=%d" % [int(room.get("id", 0)), peer_id, slot])
	# 若这个房间的房主已经走了（leader_slot 指向空/离线座位），让新加入的玩家接任，
	# 并向全房广播正确的房主（含刚加入的这个 peer）。避免"房间没房主"。
	_maybe_promote_leader(room)
	_rpc_team_leader.rpc_id(peer_id, int(room.get("leader_slot", 0)))
	_broadcast_room_lobby(room)

# --- 黄金祭坛（服务端权威 intent） ------------------------------------------
# 祭坛拿「法阵 HP」换金币，而 HP 是服务端权威、金币目前还是客户端自报——两边分属
# 不同权威源，客户端自己扣 HP 会在下一份 match_state 被覆盖掉，等于代价蒸发、
# 每回合白拿 150 金。所以这一笔必须由服务端记账：服务端扣自己的 team_hp，
# 客户端只在收到授权后才加金币。
#
# 说明：这里不校验「你是否真的拥有这件宝物」——服务端目前没有可信的宝物归属
# （客户端选宝物、服务端不记账），伪造宝物归属和伪造金币是同一类问题，
# 由 P1 的备战账本统一解决。本 RPC 修的是「代价能不能落地」，不是宝物归属。
signal altar_result(granted: bool, team_hp: int, uses: int)

const ALTAR_MAX_USES_PER_ROUND := 3
const ALTAR_MIN_HP := 10
const ALTAR_GOLD := 50

func request_golden_altar() -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_rpc_altar_request.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_altar_request() -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "altar"):
		return
	var room := _room_for_peer(sender)
	if room.is_empty():
		return
	var slot := int((room.get("peer_slot", {}) as Dictionary).get(sender, -1))
	if slot < 0 or slot >= TEAM_SLOTS:
		return
	# 只在备战阶段可用：战斗/结算阶段改 HP 会和正在进行的结算打架。
	if str(room.get("state", ROOM_LOBBY)) != ROOM_PREP:
		_rpc_altar_result.rpc_id(sender, false, 0, 0)
		return
	var uses_map: Dictionary = room.get("altar_uses", {})
	var used := int(uses_map.get(slot, 0))
	var team := 0 if slot < 3 else 1
	var hp_arr: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	var hp := int(hp_arr[team])
	if used >= ALTAR_MAX_USES_PER_ROUND or hp <= ALTAR_MIN_HP:
		_rpc_altar_result.rpc_id(sender, false, hp, used)
		return
	hp -= 1
	hp_arr[team] = hp
	room.team_hp = hp_arr
	uses_map[slot] = used + 1
	room.altar_uses = uses_map
	_touch_room(room)
	_net_log("altar granted room=%d slot=%d team=%d hp=%d uses=%d" % [int(room.get("id", 0)), slot, team, hp, used + 1])
	_rpc_altar_result.rpc_id(sender, true, hp, used + 1)
	# 同队其他人也要看到共享法阵 HP 的变化（祭坛扣的是全队 HP）。
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		var other_slot := int((room.get("peer_slot", {}) as Dictionary)[peer_id])
		if int(peer_id) == sender or not _peer_connected(int(peer_id)):
			continue
		if (0 if other_slot < 3 else 1) == team:
			_rpc_altar_team_hp.rpc_id(int(peer_id), hp)

@rpc("authority", "call_remote", "reliable")
func _rpc_altar_result(granted: bool, team_hp: int, uses: int) -> void:
	altar_result.emit(granted, team_hp, uses)

# 队友用了祭坛：只同步共享 HP，不给金币。
@rpc("authority", "call_remote", "reliable")
func _rpc_altar_team_hp(team_hp: int) -> void:
	GameState.team_hp = team_hp
	altar_result.emit(false, team_hp, -1)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_leave() -> void:
	if not _dedicated_server:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var room := _room_for_peer(peer_id)
	if room.is_empty():
		return
	_room_remove_peer(room, peer_id)

func _room_remove_peer(room: Dictionary, peer_id: int) -> void:
	# 硬移除（大厅掉线/主动离开/被踢）：座位彻底释放，token 作废。
	var peer_slot: Dictionary = room.get("peer_slot", {})
	var slot := int(peer_slot.get(peer_id, -1))
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	if slot >= 0 and slot < TEAM_SLOTS:
		states[slot] = "empty"
		ready[slot] = false
		var seat_tokens: Dictionary = room.get("seat_tokens", {})
		if seat_tokens.has(slot):
			_token_seat.erase(str(seat_tokens[slot]))
			seat_tokens.erase(slot)
			room.seat_tokens = seat_tokens
		(room.get("reserved", {}) as Dictionary).erase(slot)
		(room.get("reserve_deadline", {}) as Dictionary).erase(slot)
	peer_slot.erase(peer_id)
	_peer_room.erase(peer_id)
	room.slot_states = states
	room.ready = ready
	room.peer_slot = peer_slot
	if _room_online_count(room) <= 0:
		room.empty_since = _now()
	_maybe_promote_leader(room)
	_touch_room(room)
	_broadcast_room_lobby(room)

# 软移除（开赛后掉线）：座位保留为"重连中"，slot_states 仍是 "player"，
# 棋盘/回合进度不丢；起 RESERVE_GRACE_SEC 宽限，期内 token 重连无损续上。
func _room_reserve_peer(room: Dictionary, peer_id: int) -> void:
	var peer_slot: Dictionary = room.get("peer_slot", {})
	var slot := int(peer_slot.get(peer_id, -1))
	if slot < 0:
		return
	peer_slot.erase(peer_id)
	_peer_room.erase(peer_id)
	room.peer_slot = peer_slot
	var reserved: Dictionary = room.get("reserved", {})
	reserved[slot] = {"reserved_at": _now()}
	room.reserved = reserved
	var deadline: Dictionary = room.get("reserve_deadline", {})
	deadline[slot] = _now() + RESERVE_GRACE_SEC
	room.reserve_deadline = deadline
	if _room_online_count(room) <= 0:
		room.empty_since = _now()
	_maybe_promote_leader(room)
	_touch_room(room)
	_broadcast_room_lobby(room)
	_net_log("seat reserved room=%d slot=%d grace=%ds" % [int(room.get("id", 0)), slot, int(RESERVE_GRACE_SEC)])

# 房主掉线/离开 -> 顺延给最小编号的在线座位并广播。回来也不收回（避免反复切换）。
# 保证 leader_slot 始终指向一个"在线真人"座位。当前房主离线/变 dummy/座位为空时，
# 顺延给最小编号的在线玩家。必须在任何可能让房主失效的动作后调用：掉线保留、
# 硬移除、重连恢复、新人加入——否则会出现"房间没房主，谁都开不了/加不了 AI"。
func _maybe_promote_leader(room: Dictionary) -> void:
	var leader := int(room.get("leader_slot", 0))
	var peer_slot: Dictionary = room.get("peer_slot", {})
	var online_slots := {}
	for pid in peer_slot.keys():
		online_slots[int(peer_slot[pid])] = true
	# 房主仍是在线玩家 -> 不动；一个在线玩家都没有 -> 无人可顺延（房间会超时回收）
	if online_slots.has(leader) or online_slots.is_empty():
		return
	var next_leader := TEAM_SLOTS
	for s in online_slots.keys():
		next_leader = mini(next_leader, int(s))
	room.leader_slot = next_leader
	_net_log("leader promoted room=%d slot=%d" % [int(room.get("id", 0)), next_leader])
	for pid in peer_slot.keys():
		if _peer_connected(int(pid)):
			_rpc_team_leader.rpc_id(int(pid), next_leader)

@rpc("authority", "call_remote", "reliable")
func _rpc_team_leader(leader_slot: int) -> void:
	team_leader_slot = leader_slot
	team_lobby_changed.emit()

# 每秒扫描：宽限到期的保留座位 -> 替它完成当前阶段动作，回合不被卡住。
# 座位与 token 依旧保留——整局期间随时可重连回来（届时落到当前阶段）。
func _tick_reserved_seats() -> void:
	var now := _now()
	for room in _rooms.values():
		var deadline: Dictionary = room.get("reserve_deadline", {})
		if deadline.is_empty():
			continue
		var expired: Array = []
		for slot in deadline.keys():
			if now >= float(deadline[slot]):
				expired.append(int(slot))
		for slot in expired:
			deadline.erase(slot)
			_room_auto_complete_seat(room, slot)
		room.reserve_deadline = deadline

# 方案乙：宽限到期 -> 座位转 AI(dummy)，其他玩家立刻面对真 AI、本回合不再卡。
# token 仍有效：A 之后按"游戏重连"回来，resume 会把 dummy 变回 player、A 从存档恢复棋盘。
func _room_auto_complete_seat(room: Dictionary, slot: int) -> void:
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	if slot < states.size():
		states[slot] = "dummy"
		room.slot_states = states
	if slot < ready.size():
		ready[slot] = true
		room.ready = ready
	(room.get("reserved", {}) as Dictionary).erase(slot)
	_net_log("reserve grace expired room=%d slot=%d -> AI takeover" % [int(room.get("id", 0)), slot])
	_broadcast_room_lobby(room)
	# 转 dummy 后推进当前阶段：备战->可开局；战斗->dummy 由模拟自动出兵、不再被等待
	match str(room.get("state", ROOM_LOBBY)):
		ROOM_PREP:
			_room_maybe_start_round(room)
		ROOM_BATTLE:
			_room_try_finalize_boards(room)

@rpc("authority", "call_remote", "reliable")
func _rpc_team_kicked(_reason: String, _unused: String) -> void:
	reset()
	last_error = "kicked"
	session_changed.emit()

func _on_connected_to_server() -> void:
	_last_pong_at = _now()
	_net_log("connected to server")
	_tune_peer_timeout(1)  # 放宽对服务器连接的 ENet 超时（防服务器短冻结时底层先拆线）
	# 断线前后的客户端现场回传服务器（journald 里 clientlog 行），排查掉线原因用
	_client_send_pending_logs()
	# 重连场景：连上后不直接进 READY，先带 token 请求恢复座位
	if state == SessionState.RECONNECTING and team_active and not session_token.is_empty():
		_net_log("reconnected, requesting resume")
		_rpc_resume_request.rpc_id(1, session_token)
		return
	# 开新游戏时若有要放弃的旧座位：连上后立即通知服务器（旧座位转 AI 或自清）
	if not pending_abandon_token.is_empty():
		_rpc_abandon_seat.rpc_id(1, pending_abandon_token)
		pending_abandon_token = ""
	state = SessionState.READY
	session_changed.emit()

func _on_connection_failed() -> void:
	_net_log("connection failed")
	if state == SessionState.RECONNECTING:
		# 重连尝试失败：保持 RECONNECTING，等下个周期再试
		reset_peer_only()
		return
	state = SessionState.FAILED
	last_error = tr("net_err_connect_failed")
	session_changed.emit()

func _on_server_disconnected() -> void:
	_net_log("server disconnected (enet-level)")
	if team_active:
		# 有 token 就走自动重连，不再直接拆会话（否则玩家卡死）
		if not session_token.is_empty() and not reconnect_address.is_empty():
			_begin_reconnect("server_disconnected")
			return
		team_active = false
		team_local_slot = -1
		state = SessionState.OFFLINE
		last_error = tr("net_err_server_disconnected")
		session_changed.emit()
		team_lobby_changed.emit()
		return
	clear_opponent_snapshot()
	state = SessionState.OFFLINE
	last_error = tr("net_err_server_disconnected")
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_public_token_created(token_id: String) -> void:
	public_token_id = token_id.strip_edges().to_upper()
	SaveManager.save_public_token(public_token_id)
	public_token_changed.emit(public_token_id)

@rpc("authority", "call_remote", "reliable")
func _rpc_team_room_list(rooms: Array) -> void:
	team_room_list_received.emit(rooms)

@rpc("authority", "call_remote", "reliable")
func _rpc_team_action_failed(reason: String) -> void:
	last_error = reason
	team_room_action_failed.emit(reason)

@rpc("authority", "call_remote", "reliable")
func _rpc_team_assign_slot(slot: int, token: String = "", room_id: int = 0, short_token: String = "") -> void:
	# 重连握手期间，服务器会先把我们当新玩家分进大厅房、发来新 token——绝不能让
	# 它覆盖手里真正的重连凭证（旧 token 的座位还在等我们；新房间马上会被回收，
	# 存了它 = 下次掉线拿死 token 重连必失败）。实测日志确认过这条链路。
	if state == SessionState.RECONNECTING and not session_token.is_empty():
		_net_log("ignoring lobby assign during resume (slot=%d)" % slot)
		return
	team_local_slot = slot
	team_room_id = room_id
	if not short_token.is_empty():
		public_token_id = short_token.strip_edges().to_upper()
		SaveManager.save_public_token(public_token_id)
		public_token_changed.emit(public_token_id)
	if not token.is_empty():
		# 存下重连凭证（内存 + 磁盘），app 被杀重开也能凭它恢复对局
		session_token = token
		reconnect_address = remote_address
		SaveManager.save_reconnect(session_token, reconnect_address)
	team_lobby_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_team_lobby(states: Array, ready: Array, server_round: int = 0, server_phase_name: String = "") -> void:
	team_slot_states = states.duplicate()
	team_ready = ready.duplicate()
	if server_round > 0:
		server_round_index = server_round
	if not server_phase_name.is_empty():
		server_phase = server_phase_name
	team_lobby_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_team_room_closed(reason: String) -> void:
	team_active = false
	team_local_slot = -1
	team_slot_states = []
	team_ready = []
	team_prep_mercs = {}
	state = SessionState.FAILED
	last_error = tr("net_err_room_closed") % reason
	session_changed.emit()
	team_lobby_changed.emit()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_set_ready(slot: int, value: bool) -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		if not _rate_ok(sender, "set_ready"):
			return
		var room := _room_for_peer(sender)
		if room.is_empty() or slot < 0 or slot >= TEAM_SLOTS:
			return
		if int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != slot:
			return
		# 在线玩家的座位可能被看门狗/宽限转成了 AI（dummy）——他人还连着并且在按
		# 准备，说明活得好好的，立刻还他 player 身份，否则他之后交的棋盘会被无视。
		var seat_states: Array = room.get("slot_states", [])
		if slot < seat_states.size() and str(seat_states[slot]) == "dummy":
			seat_states[slot] = "player"
			room.slot_states = seat_states
			_net_log("dummy seat restored to player room=%d slot=%d" % [int(room.get("id", 0)), slot])
		if str(room.get("state", ROOM_LOBBY)) == ROOM_RESULT:
			_room_begin_next_prep(room)
		var ready: Array = room.get("ready", [])
		ready[slot] = value
		room.ready = ready
		_touch_room(room)
		_net_log("ready received room=%d peer=%d slot=%d ready=%s round=%d" % [int(room.get("id", 0)), sender, slot, str(value), int(room.get("round_index", 1))])
		_broadcast_room_lobby(room)
		_room_maybe_start_round(room)
		return
	if not is_host or slot < 0 or slot >= TEAM_SLOTS:
		return
	if int(_team_peer_slot.get(multiplayer.get_remote_sender_id(), -1)) != slot:
		return
	team_ready[slot] = value
	_team_broadcast_lobby()
	team_lobby_changed.emit()
	_team_maybe_start_round()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_start_request() -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		var room := _room_for_peer(sender)
		var slot := int((room.get("peer_slot", {}) as Dictionary).get(sender, -1))
		if room.is_empty() or slot != int(room.get("leader_slot", 0)):
			return
		# 房主按"开始游戏"即自动提交自己的 ready，再做权威开局检查（房主不再免检）
		var ready: Array = room.get("ready", [])
		if slot >= 0 and slot < ready.size():
			ready[slot] = true
			room.ready = ready
			_broadcast_room_lobby(room)
		_room_start_authoritative(room)
		return
	if not is_host or int(_team_peer_slot.get(multiplayer.get_remote_sender_id(), -1)) != 0:
		return
	_team_start_authoritative()

@rpc("authority", "call_remote", "reliable")
func _rpc_team_start() -> void:
	GameState.team_slot_states = team_slot_states.duplicate()
	team_start_requested.emit()

# 权威结算下行。必须是 authority：改成 any_peer 时任何客户端都能给别人塞一份
# 伪造的 match_state（金币/血量/胜负/宝物候选全由他定）。
# 配合 _ready() 里的 server_relay = false，客户端之间连转发通道都没有。
@rpc("authority", "call_remote", "reliable")
func _rpc_receive_match_state(state_payload: Dictionary) -> void:
	if is_host:
		return
	# RPC 载荷是引擎刚反序列化出来的独立字典，没有其他引用，无需拷贝。
	latest_match_state = state_payload
	_net_log("client received match_state round=%d slot=%d" % [int(state_payload.get("completed_round", 0)), int(state_payload.get("slot", -1))])
	match_state_received.emit(latest_match_state)
