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

var team_seat_profiles: Dictionary = {}

func publish_lobby_identity() -> void:
	if not team_active or is_host or state != SessionState.READY or team_local_slot < 0:
		return
	var bearer := AccountManager.access_token()
	if not bearer.is_empty():
		_rpc_lobby_identity.rpc_id(1, bearer)

# Only verified account identity is broadcast. Private biography stays in HTTPS.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_lobby_identity(bearer: String) -> void:
	if not _dedicated_server or bearer.is_empty() or bearer.length() > 8192:
		return
	var sender := multiplayer.get_remote_sender_id()
	# 走独立的 lobby_identity 配额，且**软限流（不计 strike）**——与 ping 同一待遇。
	# 此前复用 public_token（3 次/10 秒、计 strike），而客户端每次换座位都会重发
	# 一次身份：连续换座 6 次 = 3 个 strike = 服务器直接断开连接。大厅阶段掉线
	# 会立刻作废座位 token，玩家自动重连必然撞 token_unknown 被弹回主菜单
	# （实测 bug：自定义房间连换 6 次座位必掉线）。身份上报不是攻击面
	# （要带有效 bearer，服务端下面还会校验座位归属），超频丢弃这次调用即可，
	# 拿 strike 踢人等于拿自己人的连接赌。
	if not _rate_ok(sender, "lobby_identity", false):
		return
	var room := _room_for_peer(sender)
	if room.is_empty():
		return
	var slot := int((room.get("peer_slot", {}) as Dictionary).get(sender, -1))
	var token := str((room.get("seat_tokens", {}) as Dictionary).get(slot, ""))
	var request := HTTPRequest.new()
	request.timeout = 8.0
	request.body_size_limit = 65536
	add_child(request)
	var config := preload("res://scripts/account/AccountConfig.gd")
	var err := request.request(config.backend_url() + "/v1/me/profile", PackedStringArray(["Authorization: Bearer " + bearer]))
	if err != OK:
		request.queue_free()
		return
	var reply: Array = await request.request_completed
	request.queue_free()
	if int(reply[0]) != HTTPRequest.RESULT_SUCCESS or int(reply[1]) != 200:
		return
	if _room_for_peer(sender) != room or int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != slot \
			or str((room.get("seat_tokens", {}) as Dictionary).get(slot, "")) != token:
		return
	var parsed: Variant = JSON.parse_string((reply[3] as PackedByteArray).get_string_from_utf8())
	if not parsed is Dictionary:
		return
	var identity := public_seat_identity(parsed)
	if identity.is_empty():
		return
	var profiles: Dictionary = room.get("seat_profiles", {})
	profiles[slot] = identity
	room["seat_profiles"] = profiles
	_touch_room(room)
	_broadcast_room_lobby(room)

static func public_seat_identity(profile_data: Dictionary) -> Dictionary:
	var code := str(profile_data.get("friend_code", ""))
	if code.length() != 8:
		return {}
	return {"friend_code": code, "player_name": str(profile_data.get("player_name", "")).left(64), "avatar": str(profile_data.get("avatar", "")).left(128)}

const ACTIVE_MATCH_HINT := "正在对局中，请进行游戏重连"
var _match_check_busy := false
var _match_check_id := ""
var _match_check_result := ""

func allow_new_match() -> bool:
	var result := await check_saved_match()
	if result == "clear":
		return true
	DialogService.info({"request_id": "active_match_guard", "title": "提示", "body": ACTIVE_MATCH_HINT if result == "active" else "暂时无法确认对局状态，请检查网络后重试", "owner": self})
	return false

# Check the original server/port without occupying a seat in the old match.
# Unknown/network failure never clears credentials or unlocks a new match.
func check_saved_match() -> String:
	var wait_deadline := Time.get_ticks_msec() + 9000
	while _match_check_busy and Time.get_ticks_msec() < wait_deadline:
		await get_tree().create_timer(0.1).timeout
	var rc := SaveManager.load_resumable_reconnect()
	if rc.is_empty():
		return "clear"
	if _match_check_busy:
		return "unknown"
	if state == SessionState.RECONNECTING or (team_local_slot >= 0 and bool(rc.get("match_started", false))):
		return "active"
	_match_check_busy = true
	var address := str(rc.get("address", ""))
	var port := int(rc.get("port", DEFAULT_PORT))
	var token := str(rc.get("token", ""))
	var deadline := Time.get_ticks_msec() + 8000
	if not (team_active and state == SessionState.READY and remote_address == address and remote_port == port):
		if not team_join(address, port):
			_match_check_busy = false
			return "unknown"
	while state == SessionState.JOINING and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout
	if state != SessionState.READY:
		_match_check_busy = false
		return "unknown"
	_match_check_id = _make_request_id()
	_match_check_result = ""
	_rpc_match_status_request.rpc_id(1, _match_check_id, token)
	while _match_check_result.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout
	var result := _match_check_result if not _match_check_result.is_empty() else "unknown"
	_match_check_id = ""
	_match_check_busy = false
	# Never erase credentials that changed while this request was in flight.
	if str(SaveManager.load_reconnect().get("token", "")) != token:
		return "unknown"
	if result == "clear":
		SaveManager.clear_reconnect()
	elif result == "active":
		SaveManager.mark_match_started()
	return result

func _active_match_for_token(token: String) -> Dictionary:
	var seat: Dictionary = _token_seat.get(token, {})
	var room: Dictionary = _rooms.get(int(seat.get("room_id", 0)), {})
	if room.is_empty() or str(room.get("state", ROOM_LOBBY)) in [ROOM_LOBBY, ROOM_CLOSED] or bool(room.get("run_over", false)):
		return {}
	if _room_online_count(room) == 0 and float(room.get("empty_since", 0.0)) > 0.0 \
			and _now() - float(room.empty_since) >= ROOM_SUSPEND_GRACE_SEC:
		return {}
	return room

@rpc("any_peer", "call_remote", "reliable")
func _rpc_match_status_request(request_id: String, token: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if request_id.length() > MAX_TOKEN_LEN or token.length() > MAX_TOKEN_LEN or not _rate_ok(sender, "room_list"):
		return
	_cleanup_rooms()
	_rpc_match_status_result.rpc_id(sender, request_id, not _active_match_for_token(token).is_empty())

@rpc("authority", "call_remote", "reliable")
func _rpc_match_status_result(request_id: String, active: bool) -> void:
	if request_id == _match_check_id and not request_id.is_empty():
		_match_check_result = "active" if active else "clear"

# HOSTING 随 1v1 P2P 路径一并移除：组队专用服务器模式下客户端只会经历
# JOINING -> READY，服务器进程自身不用这个枚举表状态。
enum SessionState { OFFLINE, JOINING, READY, FAILED, RECONNECTING }

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const DEFAULT_PORT := NetworkConfig.SERVER_PORT
const DEFAULT_HOST := NetworkConfig.SERVER_IP
const TEAM_MAX_CLIENTS := 512
var last_carrot_harvest_gain := 0
const TEAM_SLOTS := 6
const CLEANUP_INTERVAL_SEC := 1.0
const LOBBY_EMPTY_TTL_SEC := 60.0
# 全房零在线真人、但仍有有效 token 时的保留时长（B11，产品确认值）。
# 期间房间转 suspended：不推进阶段、不启动新模拟、不进公开房间列表。
# 任一有效 token 重连即取消；到期则关房并清理 token / 短码 / 缓存映射。
# 依赖 C20 的单调时钟 —— 用墙钟的话一次 NTP 校时就能让它提前或永不到期。
const ROOM_SUSPEND_GRACE_SEC := 30.0
const PREP_TIMEOUT_SEC := 30.0 * 60.0
const BATTLE_TIMEOUT_SEC := 5.0 * 60.0
const RESULT_TIMEOUT_SEC := 10.0 * 60.0
const ROOM_LOBBY := "lobby"
const ROOM_PREP := "prep"
const ROOM_BATTLE := "battle"
const ROOM_RESULT := "result"
const ROOM_CLOSED := "closed"
# 临时缓解（B7），不是修复。必须 > BOARD_SUBMIT_TIMEOUT_SEC(30) + 一次结算耗时 +
# replay 传输时间，否则客户端会在服务器看门狗介入之前就先放弃——那样看门狗、座位
# 宽限、僵尸清道夫三条补丁全部形同虚设。
# 真正的修法是 board ACK / 服务端进度 + battle_id 驱动（归最终同步协议批）；
# 60 秒只是让"客户端先于服务器放弃"这个窗口关掉，阈值最终由 P99 实测确定。
const REPLAY_TIMEOUT_SEC := 60.0
# --- 断线重连 ---
# 连接健康的阈值随判定逻辑搬到 ConnectionHealth；这里重新导出，既有引用零改动。
const HEARTBEAT_INTERVAL_SEC := ConnectionHealth.HEARTBEAT_INTERVAL_SEC
const HEARTBEAT_TIMEOUT_SEC := ConnectionHealth.HEARTBEAT_TIMEOUT_SEC
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

# --- 会话状态（D1 步骤 1.5）---------------------------------------------------
# 下面这一批曾是门面自己的字段，现已搬到 scripts/multiplayer/SessionContext.gd。
# 保留**原来的名字**作为转发属性：门面内部 417 处、仓库其它文件 189 处，合计 606 处
# 引用因此一处都不用改，且共享同一份引用、不会出双份状态。
# 声明放在这批属性**之前**：成员变量按声明顺序初始化，_session 必须先存在。
const SessionContext := preload("res://scripts/multiplayer/SessionContext.gd")
var _session: RefCounted = SessionContext.new()

# state 在这里保留枚举类型签名，SessionContext 里存 int ——
# SessionState 枚举有 33 处外部引用，搬它超出这一刀的范围。
var state: SessionState:
	get:
		return _session.state as SessionState
	set(value):
		_session.state = int(value)
var is_host: bool:
	get:
		return _session.is_host
	set(value):
		_session.is_host = value
var opponent_board_snapshot: Dictionary = {}
var latest_match_state: Dictionary = {}
var remote_address: String:
	get:
		return _session.remote_address
	set(value):
		_session.remote_address = value
var remote_port: int:
	get:
		return _session.remote_port
	set(value):
		_session.remote_port = value
var shared_seed := 0
var last_error: String:
	get:
		return _session.last_error
	set(value):
		_session.last_error = value
var _peer: ENetMultiplayerPeer
var _join_elapsed := 0.0
var _dedicated_server: bool:
	get:
		return _session.dedicated_server
	set(value):
		_session.dedicated_server = value
var _cleanup_elapsed := 0.0
# 房间状态已搬到 scripts/multiplayer/RoomService.gd（D1 第 4 刀）。
# 这里保留**原来的下划线名**作为转发属性：NetworkService 内部 60 多处引用、
# 以及 tools/ 下三个探针的 98 处直接访问（读 + 原地写）全都不用改，
# 且共享同一份引用，不会出现门面与服务各存一份的双份状态。
#
# 顺带删掉了 `_next_room_id`：房间号早已改成
# `_shard_index * SHARD_ID_STRIDE + randi_range(100000, 999999)`（见 _new_room），
# 那个自增计数器全仓只剩声明、没有任何使用点。
var _rooms: Dictionary:
	get:
		return _room_service.rooms
	set(value):
		_room_service.rooms = value

var _peer_room: Dictionary:
	get:
		return _room_service.peer_room
	set(value):
		_room_service.peer_room = value

var _public_token_seat: Dictionary:      # short player token -> session token
	get:
		return _reconnect_service.public_token_seat
	set(value):
		_reconnect_service.public_token_seat = value

var _peer_public_token: Dictionary:      # peer_id -> short player token used for this seat
	get:
		return _reconnect_service.peer_public_token
	set(value):
		_reconnect_service.peer_public_token = value
# --- 3v3 team lobby ---
var team_active: bool:
	get:
		return _session.team_active
	set(value):
		_session.team_active = value
var team_local_slot: int:
	get:
		return _session.team_local_slot
	set(value):
		_session.team_local_slot = value
# 6 x "empty"/"player"/"dummy"（host 权威）
var team_slot_states: Array:
	get:
		return _session.team_slot_states
	set(value):
		_session.team_slot_states = value
# 6 x bool
var team_ready: Array:
	get:
		return _session.team_ready
	set(value):
		_session.team_ready = value
# peer_id -> slot（仅 host）
var _team_peer_slot: Dictionary:
	get:
		return _session.team_peer_slot
	set(value):
		_session.team_peer_slot = value
# 在每回合备战中（区别于开局前的大厅）
var team_round_active: bool:
	get:
		return _session.team_round_active
	set(value):
		_session.team_round_active = value
var team_room_id: int:
	get:
		return _session.team_room_id
	set(value):
		_session.team_room_id = value
# --- 断线重连（客户端） ---
# 服务器签发的会话 token（重连凭证，非账号）
var session_token: String:
	get:
		return _session.session_token
	set(value):
		_session.session_token = value
# 玩家看得到的短 Token ID
var public_token_id: String:
	get:
		return _session.public_token_id
	set(value):
		_session.public_token_id = value
# 重连目标地址
var reconnect_address: String:
	get:
		return _session.reconnect_address
	set(value):
		_session.reconnect_address = value
# 开新游戏时要放弃的旧座位 token（连上后发给服务器）
var pending_abandon_token: String:
	get:
		return _session.pending_abandon_token
	set(value):
		_session.pending_abandon_token = value
# 当前房主座位（服务器广播；房主掉线会顺延）
var team_leader_slot: int:
	get:
		return _session.team_leader_slot
	set(value):
		_session.team_leader_slot = value
var _reconnect_retry_left := 0.0
var _public_resume_pending := false
var _ping_accum := 0.0
var _last_pong_at := 0.0
var _ping_sent_at := 0                    # RTT 测量：本轮 ping 的发出时刻（ticks_msec）
var _last_process_at := 0.0               # 冻结检测：上一帧的时间
# --- 客户端排障日志（查"为什么突然掉线"：原因在手机侧，服务器只看得到结果） ---
# 日志文件路径、轮转阈值、缓冲行数上限都在 ClientLogService
# （LOG_FILE / ROTATE_BYTES / MAX_LINES / SEND_LINE_MAX_CHARS）。
const PONG_GAP_WARN_SEC := ConnectionHealth.PONG_GAP_WARN_SEC
const PING_RTT_LOG_MS := ConnectionHealth.PING_RTT_LOG_MS
# 客户端日志缓冲/游标/轮转标记已随实现搬到 ClientLogService。
var _pong_gap_logged := false             # 心跳静默告警去重（属于 Transport，不是日志）
# --- 服务器权威回合同步（客户端） ---
var server_round_index := 0               # 服务器广播的权威回合号（0=未知）
var server_phase := ""                    # 服务器广播的房间阶段
var _last_team_submission: Dictionary = {} # 最后一次提交的棋盘（被拒后校准重交用）
var _resync_resubmitted_round := 0        # 防重交循环：每回合只自动补交一次
# --- 断线重连（服务器） ---
var _token_seat: Dictionary:              # token -> {"room_id": int, "slot": int}
	get:
		return _reconnect_service.token_seat
	set(value):
		_reconnect_service.token_seat = value
var _peer_last_ping: Dictionary = {}      # peer_id -> unix time
var _reserve_tick_accum := 0.0
# --- 限流（服务器） ---
# 四个维度，严格程度递减：per-peer 最严 -> per-token -> per-IP（只记录不拦截）->
# 全服熔断。per-IP 不拦截是刻意的：手机 4G/校园网走运营商级 NAT，一个公网 IP 后面
# 可能是几千个正常玩家，用没有实测分布支撑的阈值去封，等于封掉整片区域。
# 先记录，等埋点跑出真实分布再定阈值。
# 限流的窗口、每动作配额与 strike 阈值已随实现搬到
# scripts/multiplayer/RateLimitService.gd（WINDOW_SEC / LIMITS / STRIKES_BEFORE_KICK）。
# 这三个常量在本文件内只被 _rate_ok 用过，外部无任何引用，所以整体搬走。

# 宝物 id 长度硬上限。数据表里的 id 实际都远短于此；它挡的是「用一个超长字符串
# 做比较 / 拼接 / 写日志」这条放大路径（A3/R4）。
const MAX_TREASURE_ID_LEN := 64
# 会话 token 长度硬上限。_make_token 产出 64 个 hex 字符；这里留一倍余量，
# 挡的是「拿超长字符串当字典键」的分配放大面（A3/R4）。
const MAX_TOKEN_LEN := 128
# 玩家手输的短码。_make_public_token 固定 10 位，留余量给空格/大小写处理。
const MAX_PUBLIC_ID_LEN := 24
const MAX_ROOMS := 200                # 全服房间数熔断
const MAX_CLIENT_LOG_BYTES := 4000    # 单次 client_log 总字节上限（不只限行数）

const RateLimitService := preload("res://scripts/multiplayer/RateLimitService.gd")
var _rate_limiter: RefCounted = RateLimitService.new()

const ReplayTransferService := preload("res://scripts/multiplayer/ReplayTransferService.gd")
var _replay_transfer: RefCounted = ReplayTransferService.new()

const ClientLogService := preload("res://scripts/multiplayer/ClientLogService.gd")
var _client_log: RefCounted = ClientLogService.new()

const ConnectionHealth := preload("res://scripts/multiplayer/ConnectionHealth.gd")
var _conn_health: RefCounted = ConnectionHealth.new()

const ReconnectBackoff := preload("res://scripts/multiplayer/ReconnectBackoff.gd")
var _reconnect_backoff: RefCounted = ReconnectBackoff.new()

const RoomService := preload("res://scripts/multiplayer/RoomService.gd")
var _room_service: RefCounted = RoomService.new()
const ReconnectService := preload("res://scripts/multiplayer/ReconnectService.gd")
var _reconnect_service: RefCounted = ReconnectService.new()
const DedicatedServerService := preload("res://scripts/multiplayer/DedicatedServerService.gd")
var _server_service: RefCounted = DedicatedServerService.new()
const NetworkTransport := preload("res://scripts/multiplayer/NetworkTransport.gd")

# 传输层 DTLS（C14）。三个建 peer 的入口都必须过它，见各处调用点的注释。
const NetTLS := preload("res://scripts/multiplayer/NetTLS.gd")
var _transport: RefCounted = NetworkTransport.new()
const MatchStateService := preload("res://scripts/multiplayer/MatchStateService.gd")
var _match_state: RefCounted = MatchStateService.new()

func _ready() -> void:
	# 依赖注入：抽出的服务都不认识 NetworkService，也不碰 multiplayer。
	_rate_limiter.configure(_now, _net_log, _disconnect_peer)
	_replay_transfer.configure(_net_log)
	# 加密链路要用另一套分块阈值与块大小（C14）。理由与实测数字见
	# ReplayTransferService 的「加密链路下的另一套阈值」一节。
	_replay_transfer.set_transport_encrypted(NetworkConfig.USE_DTLS)
	# 房间服务只注入**行为**（时钟/日志/分片号）；房间域常量在服务里、门面重新导出。
	# TEAM_SLOTS / ROOM_LOBBY / ROOM_RESULT / RESERVE_GRACE_SEC 留在门面
	# （内部 43/24/11/5 处引用、外部还有引用），按配置传进去。
	_transport.configure(_net_log)
	_match_state.configure(_now)
	# 先配 ReconnectService：它持有 token 索引，RoomService 要注入它才能读写。
	_reconnect_service.configure(_now, _net_log, {
		"reserve_grace_sec": RESERVE_GRACE_SEC,
	})
	_room_service.configure(_now, _wall_now, _net_log, func(): return _shard_index, {
		"team_slots": TEAM_SLOTS,
		"room_lobby": ROOM_LOBBY,
		"room_result": ROOM_RESULT,
		"room_closed": ROOM_CLOSED,
		"reserve_grace_sec": RESERVE_GRACE_SEC,
		# 生命周期用到的阶段名与各档 TTL（第 4 步）。常量留在门面：
		# ROOM_PREP 之类在门面内外都有引用，按配置传进去比搬走省事。
		"room_prep": ROOM_PREP,
		"room_battle": ROOM_BATTLE,
		"lobby_empty_ttl_sec": LOBBY_EMPTY_TTL_SEC,
		"room_suspend_grace_sec": ROOM_SUSPEND_GRACE_SEC,
		"prep_timeout_sec": PREP_TIMEOUT_SEC,
		"battle_timeout_sec": BATTLE_TIMEOUT_SEC,
		"result_timeout_sec": RESULT_TIMEOUT_SEC,
	}, _reconnect_service)
	_server_service.configure(_room_service, _reconnect_service, _now, _wall_now, _net_log, {
		"team_slots": TEAM_SLOTS,
		"room_result": ROOM_RESULT,
		"room_closed": ROOM_CLOSED,
		"reserve_grace_sec": RESERVE_GRACE_SEC,
	})
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
	_setup_auth()
	if _should_boot_dedicated_server():
		_shard_index = _cmdline_int("--shard", 0)
		# 端口默认按分片推导（SERVER_PORT + shard），也允许 --port 显式覆盖。
		call_deferred("start_dedicated_server", _cmdline_int("--port", NetworkConfig.port_of_shard(_shard_index)))

# --- 握手（E1，对应 C10）-----------------------------------------------------
# 此前协议号唯一的实际拦截点是 `validate_team_snapshot` —— 也就是说版本不匹配的
# 客户端能**连上、进房、组队、打完整个备战**，直到第一次提交棋盘才被踢，
# 顺带把队友卡在等棋盘直到看门狗。握手把这道门提到连接建立之前。
#
# 三条实现约束（写下来，因为每条都能让整套认证形同虚设）：
#   ① `auth_callback` 必须在给 `multiplayer_peer` 赋值**之前**配置，
#      否则先连上来的 peer 直接绕过认证；
#   ② 必须设 `auth_timeout`，否则半开的认证连接会一直挂着 —— 那本身就是 A13
#      的连接槽面，而且是个不需要发任何包就能占住槽位的版本；
#   ③ 认证中的 peer 要有数量上限和 payload 字节上限。
#
# 按已确认的决定，E1 **只校验 protocol_version**。data/sim manifest 的字段
# 已经在协议里留好（允许为空、不参与校验），等打包流程能生成指纹了再启用 ——
# 这样以后加的时候不用再升一次协议。
# 握手相关常量随实现搬到 NetworkTransport；这里重新导出，门面内部与 tools/ 里的
# 既有引用一处都不用改。两处各存一份就是给自己造第二个真相源。
const AUTH_TIMEOUT_SEC := NetworkTransport.AUTH_TIMEOUT_SEC
const AUTH_MAX_PAYLOAD_BYTES := NetworkTransport.AUTH_MAX_PAYLOAD_BYTES
const AUTH_MAX_PENDING := NetworkTransport.AUTH_MAX_PENDING

var _auth_pending: Dictionary = {}   # peer_id -> 开始认证的时刻（单调）

func _setup_auth() -> void:
	var scene_mp := multiplayer as SceneMultiplayer
	if scene_mp == null:
		push_warning("[NET] MultiplayerAPI is not SceneMultiplayer; handshake disabled")
		return
	scene_mp.auth_timeout = AUTH_TIMEOUT_SEC
	scene_mp.auth_callback = _on_auth_payload
	if not scene_mp.peer_authenticating.is_connected(_on_peer_authenticating):
		scene_mp.peer_authenticating.connect(_on_peer_authenticating)
	if not scene_mp.peer_authentication_failed.is_connected(_on_peer_authentication_failed):
		scene_mp.peer_authentication_failed.connect(_on_peer_authentication_failed)

func _client_hello_bytes() -> PackedByteArray:
	return NetworkTransport.client_hello_bytes()

func _on_peer_authenticating(id: int) -> void:
	if _dedicated_server:
		# 服务端：只登记并做并发上限，等客户端把 hello 发过来
		if _auth_pending.size() >= AUTH_MAX_PENDING:
			_net_log("auth refused peer=%d reason=too_many_pending (%d)" % [id, _auth_pending.size()])
			multiplayer.multiplayer_peer.disconnect_peer(id)
			return
		_auth_pending[id] = _now()
		return
	# 客户端：主动把 hello 发给服务器
	var scene_mp := multiplayer as SceneMultiplayer
	if scene_mp != null:
		scene_mp.send_auth(id, _client_hello_bytes())

func _on_auth_payload(id: int, data: PackedByteArray) -> void:
	var scene_mp := multiplayer as SceneMultiplayer
	if scene_mp == null:
		return
	if not _dedicated_server:
		# 客户端收到服务端的裁决
		var verdict: Dictionary = _transport.client_verdict(data)
		if bool(verdict.get("accept", false)):
			scene_mp.complete_auth(id)
			return
		# 被拒：先把原因摆到 UI 上，再自己断开。
		# 服务端故意不主动断，靠 auth_timeout 兜底 —— 那样"发拒绝"和"断连接"
		# 之间没有竞态，客户端一定能读到原因。
		var code := str(verdict.get("code", "protocol_mismatch"))
		last_error = tr("net_err_handshake") % code
		state = SessionState.FAILED
		reset_peer_only()
		session_changed.emit()
		return

	# 服务端：校验 hello
	_auth_pending.erase(id)
	# 判定在 NetworkTransport，发包留这里 —— 发包要 SceneMultiplayer。
	var srv: Dictionary = _transport.server_verdict(data, id)
	if not bool(srv.get("accept", false)):
		scene_mp.send_auth(id, NetworkTransport.auth_reject_bytes(str(srv.get("code", "protocol_mismatch"))))
		return
	scene_mp.send_auth(id, NetworkTransport.auth_accept_bytes())
	scene_mp.complete_auth(id)

func _auth_reject(code: String) -> PackedByteArray:
	return NetworkTransport.auth_reject_bytes(code)

func _decode_auth(data: PackedByteArray) -> Dictionary:
	return NetworkTransport.decode_auth(data)

func _on_peer_authentication_failed(id: int) -> void:
	_auth_pending.erase(id)
	_net_log("auth timeout peer=%d" % id)
	if not _dedicated_server:
		last_error = tr("net_err_handshake") % "auth_timeout"
		state = SessionState.FAILED
		session_changed.emit()

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
		# 排在最前：本帧要算的战斗先算完，后面的心跳/清理才是基于最新状态的。
		# 每帧最多一个房间（见 _drain_finalize_queue 的说明）。
		_drain_finalize_queue()
		# 每帧排空一点回放队列（C14 节流）。必须在 1 秒累加器**之外**。
		_tick_replay_send()
		ServerFlags.poll_reload(proc_now)
		_cleanup_elapsed += delta
		if _cleanup_elapsed >= CLEANUP_INTERVAL_SEC:
			_cleanup_elapsed = 0.0
			_cleanup_rooms()
		# 房间快照（B5）：只在有变更时写，且限速。全量序列化跑在同步主循环上，
		# 无脑每帧写就是给自己造一个新的冻结源（和 B4 同一类问题）。
		# 落盘节奏（只在有变更时写、且限速）已搬到 DedicatedServerService.tick_snapshot()。
		_server_service.tick_snapshot(delta)
		_reserve_tick_accum += delta
		if _reserve_tick_accum >= 1.0:
			_reserve_tick_accum = 0.0
			_tick_reserved_seats()
			_tick_heartbeat_timeouts()
			_reap_zombie_peers()
			_tick_board_watchdog()
			_tick_idle_peers()
			_tick_leave_tombstones()
			_tick_replay_retry(delta)
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
	_tick_pending_leave(delta)
	_tick_tx_retry(delta)
	# 重组缓冲的过期回收。跑在收包侧：不回收的话，一个发一半就断的下发会把
	# 那几十 KB 一直钉在内存里（服务器重启/换局都不会碰它）。
	_replay_transfer.tick(delta)
	if state == SessionState.RECONNECTING:
		_tick_reconnect(delta)
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
	return DedicatedServerService.should_boot(PackedStringArray(OS.get_cmdline_args()))

# --- 房间持久化（B5）---------------------------------------------------------
# `systemctl restart` 会杀掉进程内的全部房间和 token，所有在场对局一起没。
# 这让"有人在线时永远不能更新"变成硬约束。最小版：把房间定期落盘，
# 重启后读回来，让"部署 = 全场掉线"降级成"卡几秒 + 各自重连"。
#
# **只存"恢复对局必需"的字段**。`boards` 和 `last_board` 是缓存类字段
# （每人一份含完整单位 def 的快照，一个房间就能到 MB 级），存它们会让快照
# 大两个数量级，而丢了最坏也只是看门狗转 AI —— 不值得。
#
# 时间字段一律存**相对量**，不存单调时钟的绝对值：单调时钟跨进程重启就归零，
# 存绝对值等于重启后所有 TTL 立刻到期或永不到期（见 C20 的说明）。
# 持久化的常量随实现搬到 DedicatedServerService（原始 README：端口/持久化）；
# 这里重新导出，让门面内部与 docs/tools 里的既有引用一处都不用改。
const ROOM_SNAPSHOT_PATH := DedicatedServerService.SNAPSHOT_PATH
const ROOM_SNAPSHOT_VERSION := DedicatedServerService.SNAPSHOT_VERSION
const ROOM_SNAPSHOT_INTERVAL_SEC := DedicatedServerService.SNAPSHOT_INTERVAL_SEC
const PERSISTED_ROOM_FIELDS := DedicatedServerService.PERSISTED_ROOM_FIELDS
const PERSISTED_ELAPSED_FIELDS := DedicatedServerService.PERSISTED_ELAPSED_FIELDS

var _server_epoch: int:
	get:
		return _server_service.server_epoch
	set(value):
		_server_service.server_epoch = value

var _rooms_dirty: bool:
	get:
		return _room_service.rooms_dirty
	set(value):
		_room_service.rooms_dirty = value
var _snapshot_accum := 0.0

# 本进程负责的分片号（多进程扩容用）。0 = 单进程/第一个分片。
# 房间号会把它编进去，客户端据此知道该连哪个进程 —— 见 NetworkConfig 的说明。
# 实际持有者是 DedicatedServerService，这里保留原名转发。
var _shard_index: int:
	get:
		return _server_service.shard_index
	set(value):
		_server_service.shard_index = value

# 解析 `--key=value` 形式的命令行参数。
# 不用 OS.get_cmdline_user_args()：那个只认 `--` 之后的部分，而 systemd 单元里
# 直接写 `--server --shard=2` 更顺手，也和现有的 `--server` / `--flags=` 写法一致。
func _cmdline_int(key: String, fallback: int) -> int:
	var prefix := key + "="
	for arg in OS.get_cmdline_args():
		if str(arg).begins_with(prefix):
			var raw := str(arg).substr(prefix.length())
			if raw.is_valid_int():
				return int(raw)
	return fallback

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
	# dtls= 与 key= 一起打出来，是部署之后**唯一能从外面确认加密真的开了**的地方
	# （C14）。journalctl -u glory-server 里看这一行；key 路径同时能证明
	# --tls-key= 有没有被吃掉。私钥内容当然不打。
	_net_log("server starting protocol=%d shard=%d port=%d max_fps=%d dtls=%s key=%s room_id_range=[%d,%d]" % [
		NetworkConfig.NETWORK_PROTOCOL_VERSION, _shard_index, port, Engine.max_fps,
		"on" if NetworkConfig.USE_DTLS else "off",
		NetTLS.server_key_path() if NetworkConfig.USE_DTLS else "-",
		_shard_index * NetworkConfig.SHARD_ID_STRIDE + 100000,
		_shard_index * NetworkConfig.SHARD_ID_STRIDE + 999999])
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
	# 不传 max_channels（B9）：默认就是 ENet 上限 255，传具体数字只会调低上限。
	var err := p.create_server(port, TEAM_MAX_CLIENTS)
	if err != OK:
		state = SessionState.FAILED
		last_error = tr("net_err_host_failed") % str(err)
		session_changed.emit()
		return false
	# DTLS（C14）。**必须在 multiplayer_peer 赋值之前** —— 赋值之后 ENet 就开始
	# service()，再配就晚了，而且不会报错、不会告警，只是没加密。
	# 拿不到密钥就**拒绝启动**，绝不静默退回明文（见 NetTLS 顶部 fail closed 一节）。
	if NetworkConfig.USE_DTLS:
		var tls_err := NetTLS.apply_server(p)
		if not tls_err.is_empty():
			state = SessionState.FAILED
			last_error = tr("net_err_tls_setup") % tls_err
			_net_log("DTLS server setup failed: %s" % tls_err)
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
		# server_epoch 用墙钟秒：单调时钟每次重启都从 0 开始，两次重启会撞，
		# 而这个值的用途正是"识别出服务器重启过了"（见状态信封 RFC）。
		_server_epoch = int(_wall_now())
		_load_rooms_snapshot()
		_net_log("server started protocol=%d port=%d epoch=%d rooms=%d" % [
			NetworkConfig.NETWORK_PROTOCOL_VERSION, port, _server_epoch, _rooms.size()])
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
	# DTLS（C14）。顺序同 team_host：赋值之前配，配不上就干净失败。
	if NetworkConfig.USE_DTLS:
		var tls_err := NetTLS.apply_client(p)
		if not tls_err.is_empty():
			state = SessionState.FAILED
			last_error = tr("net_err_tls_setup") % tls_err
			_net_log("DTLS client setup failed: %s" % tls_err)
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

# 下面三个入口原本都是「条件不满足就静默 return」。
#
# 2026-08-21 双设备实测撞上了它：打完一局离开房间后再点「创建房间」，
# UI 永远卡在 connecting。网络层其实已经连上（日志有 client connected
# peer=1 protocol=17），但请求包没发出去 —— 而这一步**不报错、不留日志**，
# 从现场日志里看到的只是“连上了然后什么都没发生”，根本无法定位。
#
# 静默失败本身就是缺陷的成因：调用方已经进入 AsyncAction 的 PENDING，
# 若网络层不说明为何拒绝发送，就只能一直等到超时。
func team_request_room_list() -> void:
	if not _can_send_room_request("room_list"):
		return
	_rpc_team_room_list_request.rpc_id(1)

func team_request_create_room() -> void:
	if not _can_send_room_request("create_room"):
		return
	_rpc_team_create_room.rpc_id(1, public_token_id)

func team_request_join_room(room_id: int) -> void:
	if not _can_send_room_request("join_room"):
		return
	_rpc_team_join_room.rpc_id(1, room_id, public_token_id)

# 能不能发房间请求。不能发时**必须留下原因**：
# 这条路径上唯一会出错的地方就是“以为连着其实没连”，而那两个条件分别
# 对应两种完全不同的成因，不分开记就白记了。
func _can_send_room_request(what: String) -> bool:
	if not team_active:
		_net_log("%s request dropped: team_active=false（会话已重置，需重新 team_join）" % what)
		return false
	if multiplayer.multiplayer_peer == null:
		_net_log("%s request dropped: multiplayer_peer=null（连接已关闭）" % what)
		return false
	return true

func team_request_public_token() -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_rpc_public_token_request.rpc_id(1)

func team_request_public_resume(token_id: String) -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		public_token_id = token_id.strip_edges().to_upper()
		SaveManager.save_public_token(public_token_id)
		# 短码恢复沿用同一份 room_state / resume_failed 协议，但它不是由
		# begin_resume_from_disk() 发起，state 不会进入 RECONNECTING。单独记住这次
		# 意图，收到状态信封时也发 resume_completed，避免客户端已恢复座位却永远
		# 不执行 Main 的恢复落地。只存 bool，不把玩家短码写进诊断状态。
		_public_resume_pending = true
		_rpc_public_resume_request.rpc_id(1, public_token_id)

func _team_next_free_slot() -> int:
	for i in TEAM_SLOTS:
		if str(team_slot_states[i]) == "empty":
			return i
	return -1

# 所有**时长**语义一律走单调时钟（C20）。
#
# 旧实现返回 `Time.get_unix_time_from_system()`（系统墙钟），而它参与心跳超时、
# 限流窗口、房间 TTL、座位宽限、重连 deadline —— 全是"两个时刻相减"的用法。
# 墙钟会被 NTP 校时和手工改时间拽动：
#   * 向前跳 → 所有计时瞬间"超时"，全场被误踢（和服务器冻结同款雪崩）；
#   * 向后跳 → 清理与限流长期停滞，房间和限流桶都回收不了。
# `Time.get_ticks_msec()` 是进程启动以来的毫秒数，不受校时影响。
#
# 边界（写进文档 C20）：
#   * 日志时间继续用墙钟（`_net_log` 走 `get_datetime_string_from_system`），
#     单调值对人不可读；
#   * 这个值**跨进程重启就失效**，未来做房间持久化时不能直接存裸 deadline，
#     必须存"剩余时长"或重启时重新基准化；
#   * 已有房间不能热重载这个改动，必须重启服务器。
func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

# 需要人类可读/跨进程可比的绝对时间时用这个（目前只有日志与将来的持久化）。
func _wall_now() -> float:
	return Time.get_unix_time_from_system()

# --- 限流 -------------------------------------------------------------------
# 返回 true = 放行；false = 超限（调用方必须立即 return，不做任何业务处理）。
# 注意能力边界：RPC 参数在进入本函数前已被引擎反序列化，所以这里挡不住「一个巨大
# Variant 的解码开销」——那一层要靠 NetProtocol 的容器上限 + 第 3 批的字节协议。
# 本函数挡的是「同一个动作被高频重复调用」。
# count_strike=false：超限只丢弃这一次调用，不累计 strike、不断开连接。
# 用于心跳这类「超频更可能是客户端 bug 或时钟抖动而非攻击」的动作——拿累计 strike
# 去踢心跳过快的人，等于用自己人的连接赌一个还没实测过的阈值。
#
# 能力边界（A8）：这只挡回包放大。恶意客户端仍可无限高频发包，反序列化与 handler
# 调用的开销照旧，连接也一直占着。入包侧要靠连接准入（A13）和包级字节预算（R4）。
# 限流实现已抽到 scripts/multiplayer/RateLimitService.gd（D1 第 1 刀）。
# 这两个函数保留为门面：内部 18 个调用点一个都不用改，外部也没有任何引用。
# "是否启用"留在这里判断，服务本身不需要知道专服模式这个概念。
func _rate_ok(peer_id: int, action: String, count_strike: bool = true) -> bool:
	if not _dedicated_server:
		return true
	return _rate_limiter.allow(peer_id, action, count_strike)

func _rate_forget(peer_id: int) -> void:
	_rate_limiter.forget(peer_id)

# 服务不碰 multiplayer，踢人这一步由门面代劳。
func _disconnect_peer(peer_id: int) -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)

# 不可信字符串进日志前必须过这里（A3/R4/R7）。
# 三件事:① 截断——不给对方用一个超长 id 把 journald 和磁盘刷爆的机会;
# ② 转义换行与控制字符——否则客户端可以伪造出看起来像服务器自己打的日志行;
# ③ 只保留可打印 ASCII 之外的字节数统计，不原样回显。
const LOG_UNTRUSTED_MAX := 32

func _log_safe(value: Variant) -> String:
	var raw := str(value)
	var clipped := raw.substr(0, LOG_UNTRUSTED_MAX)
	var out := ""
	for i in clipped.length():
		var c := clipped[i]
		var code := c.unicode_at(0)
		if code < 32 or code == 127:
			out += "."          # 换行/回车/控制字符一律吃掉，防日志注入
		else:
			out += c
	if raw.length() > LOG_UNTRUSTED_MAX:
		out += "…(len=%d)" % raw.length()
	return out

# 客户端日志的缓冲、轮转与落盘已抽到 scripts/multiplayer/ClientLogService.gd（D1 第 3 刀）。
# 这里保留为门面：115 个内部调用点一个都不用改，外部也没有任何引用。
# 专服开关（原来的 `if _dedicated_server: return`）按调用逐次传入，
# 不在服务里存一份镜像 —— `_dedicated_server` 在三处被写，镜像迟早会不同步。
func _net_log(message: String) -> void:
	_client_log.write(message, _dedicated_server)

# 重连/连接成功后，把断线前后的客户端现场回传服务器（落进 journald，和服务器
# 事件对着看）。只发增量，单行截断，服务器侧也再限量——不给弱网添堵。
# 取增量的逻辑在服务里；RPC 只能从 Node 发，所以这一层留在门面。
func _client_send_pending_logs() -> void:
	if is_host:
		return
	# 显式标类型：_client_log 声明为 RefCounted，返回值类型推不出来。
	var lines: PackedStringArray = _client_log.take_pending_lines()
	if lines.is_empty():
		return
	_rpc_client_log.rpc_id(1, lines)

# 诊断日志同样是"大且不急"，和 replay 共用 bulk 通道，别去挤控制流（B9）。
@rpc("any_peer", "call_remote", "reliable", NetworkConfig.CH_BULK)
func _rpc_client_log(lines: PackedStringArray) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "client_log"):
		return
	# 按总字节数封顶，不只按行数：200 字符 × 80 行仍可能被拿来刷爆 journald 和磁盘。
	# 行数上限与单行截断长度都取服务里的常量：客户端发多少、服务端收多少必须同源，
	# 两边各写一份迟早会不一致。
	var budget := MAX_CLIENT_LOG_BYTES
	for i in mini(lines.size(), ClientLogService.MAX_LINES):
		var line := str(lines[i]).substr(0, ClientLogService.SEND_LINE_MAX_CHARS)
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

# 房间创建已搬到 RoomService.new_room()。保留门面包装：
# tools/adversarial_client_node.gd 等探针共 98 处直接调用房间内部，包括 _new_room()。
func _new_room() -> Dictionary:
	return _room_service.new_room()

func _find_or_create_room() -> Dictionary:
	return _room_service.find_or_create_room()
func _room_player_count(room: Dictionary) -> int:
	return _room_service.room_player_count(room)
func _public_room_list() -> Array:
	return _room_service.public_room_list()
func _room_next_free_slot(room: Dictionary) -> int:
	return _room_service.room_next_free_slot(room)
func _room_for_peer(peer_id: int) -> Dictionary:
	return _room_service.room_for_peer(peer_id)
func _touch_room(room: Dictionary) -> void:
	_room_service.touch_room(room)
func _set_room_state(room: Dictionary, next_state: String) -> void:
	_room_service.set_room_state(room, next_state)
# --- 房间阶段权限矩阵（A11）--------------------------------------------------
# 任何改变成员或阶段的 RPC 都必须先声明自己允许在哪些阶段执行。
# 此前 start/toggle/kick/move 全程不检查 room.state：房主在 BATTLE/RESULT 再按一次
# 「开始游戏」，_room_start_authoritative 会把进行中的房间 _set_room_state 回
# ROOM_PREP 并向全房重发 team_start，客户端据此执行新局初始化——一个按钮就能毁掉
# 正在进行的对局，且不需要改客户端。
const PHASE_LOBBY_ONLY: Array = [ROOM_LOBBY]

func _phase_allows(room: Dictionary, allowed: Array, action: String, peer_id: int) -> bool:
	var phase := str(room.get("state", ROOM_LOBBY))
	if allowed.has(phase):
		return true
	_net_log("phase denied room=%d peer=%d action=%s phase=%s" % [
		int(room.get("id", 0)), peer_id, action, phase])
	return false

# 这个房间还有多少个**有效私有 session token**（B11 / R2）。
# "有效"= 仍映射到本房本座位、未被撤销。公开短码不算 —— 它只是查询入口，
# 真正的恢复凭证是私有 token。零有效 token 意味着没有任何人可能回来。
func _room_live_token_count(room: Dictionary) -> int:
	return _room_service.room_live_token_count(room)
func _room_online_count(room: Dictionary) -> int:
	return _room_service.room_online_count(room)
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

# --- 座位元数据的统一搬移与清理（C19/R5、A12）--------------------------------
# 一个座位上挂着好几份东西：会话 token、公开短码绑定、加入顺序、保留态、以及该
# 席位的对局进度（宝物 offer/持有、祭坛次数、缓存棋盘、金币）。此前它们散在四五个
# 函数里各搬各的 —— 换位搬了 token 和 join_seq 却漏了 seat_public_id，硬移除清了
# token 却没清 join_seq，于是「换位后离开短码释放不掉」「新人继承旧 join_seq」
# 这类问题必然出现。
#
# 规则：**搬要一起搬，清要一起清**。临时掉线（`_room_reserve_peer`）两者都不调 ——
# 那是"人还会回来"，座位上的东西必须原样留着。
# 席位映射清单随实现搬到 RoomService；重新导出，既有引用零改动。
const SEAT_SLOT_MAPS := RoomService.SEAT_SLOT_MAPS

func _move_seat_metadata(room: Dictionary, from_slot: int, to_slot: int) -> void:
	_room_service.move_seat_metadata(room, from_slot, to_slot)
# 永久释放座位（主动离开 / 被踢 / 放弃 / 关房）。临时掉线绝不能调这个。
func _clear_seat_metadata(room: Dictionary, slot: int) -> void:
	_room_service.clear_seat_metadata(room, slot)
# 释放一个座位绑定的公开短码。
# compare-and-delete：只有当这条映射**仍指向本座位的 token** 时才删。
# 无条件删会在短码碰撞（同一 id 被另一个座位重新绑定）时，让先离开的人把后来者的
# 映射一起删掉 —— 那是拿一个泄漏换一个更难查的串号。
# 注意这只缓解误删，不解决"客户端自报短码可覆盖别人映射"（A12 完整版要服务端签发）。
func _release_seat_public_id(room: Dictionary, slot: int) -> void:
	_room_service.release_seat_public_id(room, slot)
func _room_close(room: Dictionary, reason: String) -> void:
	room.state = ROOM_CLOSED
	room.finished_reason = reason
	# 房间没了：每个座位上挂的所有东西一并作废（token、短码绑定、加入顺序、进度）。
	# 房间是这些全局映射条目的最后一个持有者，这里不清就永远没人清了。
	for slot_i in TEAM_SLOTS:
		_clear_seat_metadata(room, slot_i)
	_rooms_dirty = true   # B5：关房也要落盘，否则重启后死房间会被读回来
	_net_log("room cleanup id=%d reason=%s" % [int(room.get("id", 0)), reason])
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if _peer_connected(int(peer_id)):
			_rpc_team_room_closed.rpc_id(int(peer_id), reason)
		_peer_room.erase(int(peer_id))

# 策略已搬到 RoomService.cleanup_rooms()（D1 第 4 刀第 4 步）。
# 留在这里的只有"发消息"：_room_close 要给还连着的 peer 发 room_closed，
# _room_begin_next_prep 要广播新回合 —— RoomService 是 RefCounted，够不着 multiplayer。
func _cleanup_rooms() -> void:
	_room_service.cleanup_rooms(_room_close, _room_begin_next_prep)

# --- 结算确认（E3，对应 C7 / B15）--------------------------------------------
# 此前**任意一个玩家**按下准备就能把全房推进下一回合 —— 别人还在看回放就被拽走。
# 现在改成：**所有仍在线的真人席位都确认收到并应用了本场结算**，才推进。
#
# 已确认的产品规则：**只等在线真人，掉线的不等**。掉线者重连时靠 room_state
# 全量快照追上 —— 这和现有的"座位宽限 + AI 代打"是同一条逻辑：
# 掉线的人不该拖住在线的人。
#
# AI 席位与空席由服务器自己算作已确认，**不伪造客户端 ACK**。
const RESULT_ACK_TIMEOUT_SEC := 60.0

func _room_result_acks_complete(room: Dictionary) -> bool:
	var battle_id := str(room.get("battle_id", ""))
	if battle_id.is_empty():
		return true   # 没有待确认的战斗（例如刚建房），不阻塞
	# 兜底：某个在线真人的客户端卡死时，不能让全房无限等。
	# 这不是"正常同步机制"，只是保险 —— 正常路径应该在几秒内全部 ACK。
	if _now() - float(room.get("state_started_at", 0.0)) >= RESULT_ACK_TIMEOUT_SEC:
		_net_log("result ack timeout room=%d battle=%s -> advancing anyway" % [
			int(room.get("id", 0)), battle_id])
		return true
	var acks: Dictionary = room.get("result_acks", {})
	var peer_slot: Dictionary = room.get("peer_slot", {})
	var online_slots := {}
	for pid in peer_slot.keys():
		online_slots[int(peer_slot[pid])] = true
	var states: Array = room.get("slot_states", [])
	for i in TEAM_SLOTS:
		if i >= states.size() or str(states[i]) != "player":
			continue          # AI / 空席：服务器代过
		if not online_slots.has(i):
			continue          # 掉线：不等（已确认的产品规则）
		if str(acks.get(i, "")) != battle_id:
			return false
	return true

func send_result_ack(battle_id: String) -> void:
	if battle_id.is_empty() or is_host or not team_active or multiplayer.multiplayer_peer == null:
		return
	_rpc_result_ack.rpc_id(1, battle_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_result_ack(battle_id: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "result_ack"):
		return
	if battle_id.length() > MAX_TREASURE_ID_LEN:
		return
	var room := _room_for_peer(sender)
	if room.is_empty():
		return
	var slot := int((room.get("peer_slot", {}) as Dictionary).get(sender, -1))
	if slot < 0 or slot >= TEAM_SLOTS:
		return
	# 只认当前这一场的确认。迟到的旧 ACK 直接丢 —— 否则上一场的确认会把
	# 这一场当成"已经确认过了"，玩家还在看回放就被推进下一轮。
	if battle_id != str(room.get("battle_id", "")):
		_net_log("stale result_ack room=%d slot=%d got=%s want=%s" % [
			int(room.get("id", 0)), slot, battle_id, str(room.get("battle_id", ""))])
		return
	var acks: Dictionary = room.get("result_acks", {})
	if str(acks.get(slot, "")) == battle_id:
		return   # 幂等：重复 ACK 不做任何事
	acks[slot] = battle_id
	room.result_acks = acks
	_touch_room(room)
	_net_log("result ack room=%d slot=%d battle=%s (%d acked)" % [
		int(room.get("id", 0)), slot, battle_id, acks.size()])
	# 全部在线真人确认完 -> 自动推进，不必再等谁按准备
	if str(room.get("state", "")) == ROOM_RESULT and _room_result_acks_complete(room):
		_room_begin_next_prep(room)

func _room_begin_next_prep(room: Dictionary) -> void:
	# 对局已结束（最终局打完）就不再开新回合，避免服务器把回合推过 FINAL_ROUND、
	# 与封顶在 21 的客户端分叉，导致客户端等一个对不上号的 match_state 死循环。
	if bool(room.get("run_over", false)):
		return
	# E3：所有在线真人确认收到结算之前不推进（C7）。
	# 唯一的例外是 _cleanup_rooms 的 RESULT 超时兜底 —— 那条路径下
	# _room_result_acks_complete 会因为超时返回 true。
	if str(room.get("state", "")) == ROOM_RESULT and not _room_result_acks_complete(room):
		return
	room.battle_id = ""
	room.result_acks = {}
	room.boards = {}
	# 上一场的回放不再需要：补看只在结算阶段有意义（_resume_seat 只在
	# ROOM_RESULT 下补发）。不清的话每个房间会带着约 196 KB 熝到下一场。
	room.replay_packed = {}
	room.prep_mercs = {}
	room.altar_uses = {}   # 祭坛次数按回合重置，和客户端 reset_shop_refreshes 同步
	# round_index 封顶到 FINAL_ROUND，和客户端一致（客户端从 match_state 拿的是 min(+1, 21)）。
	# 提前算出来：下面摇的商店属于**即将开始的那一轮**，而档位曲线是按回合走的，
	# 用自增前的旧值会让整条曲线慢一轮（第 5 回合才拿到第 4 回合的档位分布）。
	var next_round := mini(int(room.get("round_index", 1)) + 1, GameState.FINAL_ROUND)
	# 账本的按回合部分同样重置，并给每个座位摇一份新商店（P1）。
	# 金币与 roster **不重置** —— 那是跨回合累积的。
	if _economy_action_enabled("upgrade_harvest_tech"):
		var preps: Dictionary = room.get("prep", {})
		var refreshed_slots: Dictionary = {}
		# Keep the old behavior for reserved/disconnected seats whose prep ledger
		# still exists, then include newly active seats that did not have a ledger.
		for slot_key in preps.keys():
			refreshed_slots[int(slot_key)] = true
		var states_for_economy: Array = room.get("slot_states", [])
		for seat in TEAM_SLOTS:
			if seat < states_for_economy.size() and str(states_for_economy[seat]) == "player":
				refreshed_slots[seat] = true
		for slot_key in refreshed_slots.keys():
			var slot := int(slot_key)
			var prep: Dictionary = _room_prep(room, slot)
			# carrot-only rollout still uses the existing seat_gold mirror for
			# battle settlement and room snapshots. Keep the ledger's gold seed in
			# lockstep without changing the old authoritative ledger path.
			# 影子期（enabled 但未 authoritative）**也要**每回合重新锚定：
			# 战后结算的权威余额在 room.slot_gold 里，账本只在备战期跟着意图走。
			# 判据写成 economy_enabled() 时，开关一开这里就不再锚定，prep.gold
			# 会永远停在 START_GOLD —— 而 upgrade_harvest_tech 正是读它扣钱的，
			# 于是「采集科技永远买不起」。只有账本成为唯一真相之后才不能覆盖它。
			if not economy_authoritative():
				var slot_gold: Array = room.get("slot_gold", [])
				if slot < slot_gold.size() and slot_gold[slot] != null:
					prep["gold"] = int(slot_gold[slot])
			EconomyLedger.reset_round(prep)
			EconomyLedger.harvest_for_round(prep, next_round)
			var shop: Dictionary = prep.get("shop", {})
			shop["offers"] = _server_roll_shop_offers(GameState.SHOP_UNIT_SLOTS, next_round)
			shop["offer_id"] = _make_offer_id()
			var sold: Array = []
			sold.resize(GameState.SHOP_UNIT_SLOTS)
			sold.fill(false)
			shop["sold"] = sold
			prep["shop"] = shop
		room["prep"] = preps
	room.round_index = next_round
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
		if not _phase_allows(room, PHASE_LOBBY_ONLY, "toggle_slot", sender):
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
			# dummy 有两种来源：房主手动加的 AI（没有元数据），和真人掉线宽限到期后
			# 被 _room_auto_complete_seat 顶上的 AI（token/短码/join_seq 全都还在）。
			# 后者被切成 empty 就是「这个座位真的没了」——元数据必须一起清，
			# 否则旧 token 仍指向本房本槽，而后来坐进来的人会继承旧 join_seq。
			_clear_seat_metadata(room, slot)
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
	# 座位上挂着的所有东西一起搬（token / 短码绑定 / 加入顺序 / 对局进度）。
	# 逐项手搬过一次，结果就是漏了 seat_public_id —— 换位后离开时短码释放不掉。
	# 现在只有一个入口，加字段时只需改 SEAT_SLOT_MAPS。
	_move_seat_metadata(room, from_slot, to_slot)
	# 房主身份也必须跟着人搬（C19）。leader_slot 记的是槽位号，不搬的话房主换个位子
	# 之后 leader_slot 指向刚空出来的槽，can_control_room() 对谁都不成立——全房
	# 从此没人能开始游戏、加 AI 或踢人，只能解散重开。
	# 注意不能靠 _maybe_promote_leader 兜底：它会把房主让给编号最小的在线玩家，
	# 等于换位这个动作顺手把房主权交给了别人。
	if int(room.get("leader_slot", 0)) == from_slot:
		room.leader_slot = to_slot
		_net_log("leader moved with player room=%d %d->%d" % [int(room.get("id", 0)), from_slot, to_slot])
	_touch_room(room)
	# 房主变更、座位变更、凭证都在 room_state 里，一次全量广播就够 —— 不再需要
	# team_leader / team_assign_slot 两条各发各的（E2）。
	_broadcast_room_lobby(room)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_kick_slot(slot: int) -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		var room := _room_for_peer(sender)
		if room.is_empty() or int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != int(room.get("leader_slot", 0)):
			return
		if not _phase_allows(room, PHASE_LOBBY_ONLY, "kick", sender):
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

# 在途的 ready 请求（C24）。-1 = 没有在途请求；0/1 = 已发出但还没被服务器确认的目标值。
#
# 旧实现发完 RPC 就不管了，本地 team_ready 要等服务器 lobby 广播回来才更新。
# 于是"按下准备 → 回包到达前继续挪棋子"这段窗口里，编辑动作读到的还是旧的
# ready=false，**不会发取消**，而服务器那边已经按已准备锁盘 —— 玩家的棋盘还在改，
# 服务器却可能已经开战。
# 完整修法是 ready request/ACK + revision（归最终同步协议批）；这里先让本地
# 判断以"意图"为准，把这段窗口关掉。
var _pending_ready := -1

# 本地认为自己现在是不是已准备：在途请求优先于服务器最后一次广播。
func local_ready_intent() -> bool:
	if _pending_ready >= 0:
		return _pending_ready == 1
	if team_local_slot >= 0 and team_local_slot < team_ready.size():
		return bool(team_ready[team_local_slot])
	return false

func team_set_ready(value: bool) -> void:
	if team_local_slot < 0:
		return
	if is_host:
		team_ready[team_local_slot] = value
		_team_broadcast_lobby()
		team_lobby_changed.emit()
		_team_maybe_start_round()
	else:
		_pending_ready = 1 if value else 0
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
	# 守卫收进函数内部（不只靠调用点）：这个函数会把房间 _set_room_state 回 ROOM_PREP
	# 并向全房重发 team_start。在 BATTLE/RESULT 阶段执行等于把进行中的对局重置成新局，
	# 是 A11 里危害最大的一条。调用点已各自判过，这里是第二道门。
	if str(room.get("state", ROOM_LOBBY)) != ROOM_LOBBY:
		_net_log("start refused room=%d phase=%s (already running)" % [
			int(room.get("id", 0)), str(room.get("state", ""))])
		return
	if not _room_all_ready(room):
		return
	_touch_room(room)
	_set_room_state(room, ROOM_PREP)
	var ready: Array = room.get("ready", [])
	var states: Array = room.get("slot_states", [])
	if _economy_action_enabled("upgrade_harvest_tech"):
		# The first prep is a real round boundary. Seed each player once before
		# the first room_state so an authoritative client cannot miss the +3.
		for slot in TEAM_SLOTS:
			if slot < states.size() and str(states[slot]) == "player":
				var prep: Dictionary = _room_prep(room, slot)
				# 同 _room_next_round：影子期也要锚定，理由见那里的注释。
				if not economy_authoritative():
					var slot_gold: Array = room.get("slot_gold", [])
					if slot < slot_gold.size() and slot_gold[slot] != null:
						prep["gold"] = int(slot_gold[slot])
				EconomyLedger.harvest_for_round(prep, int(room.get("round_index", 1)))
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

# --- 状态信封 E2：房间权威状态的唯一下行通道 --------------------------------
# 此前房间状态被拆成四个各自为政的 RPC —— team_lobby（席位/ready/回合/阶段）、
# team_leader（房主）、team_assign_slot（座位与凭证）、resume_state（重连恢复）。
# 每个都能独立迟到、乱序、互相覆盖，由此派生出 B6（回合号双份真相）、
# C17（旧包覆盖新状态）、C5（恢复用的和平时发的口径不一样）一整串问题。
#
# 现在四合一成**一份带序号的全量快照**。三条规则：
#   ① `server_epoch` 认进程：服务器重启后 state_seq 从 0 重来，
#      没有 epoch 的话客户端会把新的 seq=3 当成倒退丢掉，从此永不同步；
#   ② `state_seq` 每次权威变更 +1，客户端拒收不前进的包；
#   ③ **全量快照 ⇒ 漏包自愈**。客户端漏了 seq=5、收到 seq=7 直接应用就对了，
#      不需要补差，服务器也不保留任何状态历史。这正是不做 delta 换来的简化。
#
# payload 是**按座位**生成的（金币、宝物、token 都是每人不同），所以逐 peer 发。
func _bump_room_seq(room: Dictionary) -> int:
	return _match_state.bump_seq(room)

func _build_room_state(room: Dictionary, slot: int) -> Dictionary:
	var hp: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	var own_team := 0 if slot < 3 else 1
	var slot_gold: Array = room.get("slot_gold", [])
	var gold := GameState.START_GOLD
	if slot >= 0 and slot < slot_gold.size() and slot_gold[slot] != null:
		gold = int(slot_gold[slot])
	# 结算阶段 round_index 还停在刚打完那一轮（惰性推进），客户端要进的是下一轮。
	# 给旧值会让客户端从此落后一轮、之后提交全被 wrong_round 拒收（实测确认过）。
	var round_id := int(room.get("round_index", 1))
	if str(room.get("state", "")) == ROOM_RESULT:
		round_id = mini(round_id + 1, GameState.FINAL_ROUND)
	var streak: Array = room.get("team_loss_streak", [0, 0])
	return {
		# --- 房间 ---
		"phase": str(room.get("state", ROOM_LOBBY)),
		"round_id": round_id,
		"leader_slot": int(room.get("leader_slot", 0)),
		"slot_states": (room.get("slot_states", []) as Array).duplicate(),
		"seat_profiles": (room.get("seat_profiles", {}) as Dictionary).duplicate(true),
		"ready": (room.get("ready", []) as Array).duplicate(),
		"suspended": bool(room.get("suspended", false)),
		# --- 本座位身份 ---
		"my_slot": slot,
		"session_token": str((room.get("seat_tokens", {}) as Dictionary).get(slot, "")),
		"public_id": str((room.get("seat_public_id", {}) as Dictionary).get(slot, "")),
		# --- 队伍 ---
		"team_hp": int(hp[own_team]),
		"rival_team_hp": int(hp[1 - own_team]),
		# --- 本座位的对局进度（C5 要求的那批）---
		"gold": gold,
		"loss_streak": int(streak[own_team]) if streak.size() > own_team else 0,
		"pve_completed": int(room.get("pve_completed", 0)),
		"boss_completed": int(room.get("boss_completed", 0)),
		"owned_treasures": _room_owned_treasures(room, slot).duplicate(),
		"treasure_offer": ((room.get("treasure_offer", {}) as Dictionary).get(slot, {}) as Dictionary).duplicate(true),
		"altar_uses": int((room.get("altar_uses", {}) as Dictionary).get(slot, 0)),
		"run_over": bool(room.get("run_over", false)),
		# --- 经济账本（P1）---
		# 影子期就下发：客户端可以拿它对账、也让重连的人立刻看到权威商店，
		# 但在 economy_ledger_authoritative 打开之前，客户端仍以本地值为准。
		"economy": _build_economy_state(room, slot),
	}

func _build_economy_state(room: Dictionary, slot: int) -> Dictionary:
	if not _economy_action_enabled("upgrade_harvest_tech"):
		return {}
	var prep := _room_prep(room, slot)
	var shop: Dictionary = prep.get("shop", {})
	return {
		"authoritative": economy_authoritative(),
		"carrot_authoritative": carrot_economy_enabled(),
		"revision": int(prep.get("revision", 0)),
		"gold": int(prep.get("gold", 0)),
		"carrots": int(prep.get("carrots", 0)),
		"harvest_tech_level": int(prep.get("harvest_tech_level", 0)),
		"merc_carrots_spent_total": int(prep.get("merc_carrots_spent_total", 0)),
		"last_harvest_round": int(prep.get("last_harvest_round", -1)),
		"last_harvest_gain": int(prep.get("last_harvest_gain", 0)),
		"stone_draw_used_round": int(prep.get("stone_draw_used_round", -1)),
		"team_upgrade_stones": _room_team_stones(room, slot).duplicate(true),
		"shop": {
			"offer_id": str(shop.get("offer_id", "")),
			"offers": (shop.get("offers", []) as Array).duplicate(true),
			"sold": (shop.get("sold", []) as Array).duplicate(),
			"refresh_uses": int(shop.get("refresh_uses", 0)),
		},
		"roster": (prep.get("roster", {}) as Dictionary).duplicate(true),
		"gamble_used": bool(prep.get("gamble_used", false)),
	}

func _send_room_state(room: Dictionary, peer_id: int, seq: int) -> void:
	var slot := int((room.get("peer_slot", {}) as Dictionary).get(peer_id, -1))
	if slot < 0:
		return
	_rpc_room_state.rpc_id(peer_id, {
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"server_epoch": _server_epoch,
		"room_id": int(room.get("id", 0)),
		"state_seq": seq,
		"message_type": "room_state",
		"payload": _build_room_state(room, slot),
	})

# 名字保留不变：十几个调用点都在调它，改名等于把这次改动摊到整个文件。
# 语义已经从"广播大厅"升级成"广播房间权威全量状态"。
func _broadcast_room_lobby(room: Dictionary) -> void:
	var seq := _bump_room_seq(room)
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if _peer_connected(int(peer_id)):
			_send_room_state(room, int(peer_id), seq)

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
	#
	# A14：**进循环之前就拒**。旧实现会把整个输入遍历完（只是不再往 out 里塞），
	# 所以一个 20 万元素的数组照样能让主循环转 20 万次 —— 而服务器是单线程同步的，
	# 那期间全服所有房间的心跳都停。合法输入最多 MERCENARY_SLOTS 个，
	# 超出这个数就没有任何"部分接受"的理由。
	if ids.size() > GameState.MERCENARY_SLOTS:
		_net_log("prep_mercs rejected: size=%d cap=%d" % [ids.size(), GameState.MERCENARY_SLOTS])
		return []
	var valid := {}
	for row in (DataRegistry.get_table("mercenaries").get("mercenaries", []) as Array):
		valid[str((row as Dictionary).get("id", ""))] = true
	var out: Array = []
	for id_value in ids:
		# 单个 id 也要有长度门：不然可以塞 8 个超长字符串，字典查找和日志都会被放大。
		var id := str(id_value)
		if id.length() > MAX_TREASURE_ID_LEN:
			continue
		if valid.has(id) and out.size() < GameState.MERCENARY_SLOTS:
			out.append(id)
	return out

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_prep_mercs_submit(slot: int, round_index: int, ids: Array) -> void:
	if _dedicated_server:
		var sender := multiplayer.get_remote_sender_id()
		# A14：这个 handler 此前既没限流、也没查阶段和回合 —— 配置表里明明有
		# "prep_mercs": 40 这一项，只是从来没人调过 _rate_ok。
		if not _rate_ok(sender, "prep_mercs"):
			return
		var room := _room_for_peer(sender)
		if room.is_empty() or slot < 0 or slot >= TEAM_SLOTS:
			return
		if int((room.get("peer_slot", {}) as Dictionary).get(sender, -1)) != slot:
			return
		# 佣兵同步只在备战阶段有意义。战斗/结算阶段收到就是乱序或伪造，直接丢。
		if str(room.get("state", ROOM_LOBBY)) != ROOM_PREP:
			return
		# 回合号对不上的是迟到包：应用它会让队友看到上一轮的佣兵列表。
		if round_index != int(room.get("round_index", 1)):
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

# 回放的存放与编解码已抽到 scripts/multiplayer/ReplayTransferService.gd（D1 第 2 刀）。
# 这两个属性用 get/set 访问器转发过去：外部 60 处引用（读、整体赋值、原地改）
# 一个都不用改，而且**共享同一份字典引用** —— 不会出现门面与服务各存一份的双份状态。
# （这一点在动手前用一次性探针实测过：整体赋值、读回、原地改、服务侧改动外部可见、
#  清空，五项全通过。）
var team_replay: Dictionary:            # this client's team replay (B3, host-authoritative)
	get:
		return _replay_transfer.team_replay
	set(value):
		_replay_transfer.team_replay = value

var team_replay_rival: Dictionary:      # 敌方队伍同回合的 replay（战斗中切镜头观战用）
	get:
		return _replay_transfer.team_replay_rival
	set(value):
		_replay_transfer.team_replay_rival = value

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
	# 打包一次、所有人复用（见 _pack_replay 的说明）
	var packed_a := _pack_replay(replay_a)
	var packed_b := _pack_replay(replay_b)
	for peer_id in _team_peer_slot:
		var slot: int = _team_peer_slot[peer_id]
		# 本地房主模式没有 room 字典，用回合号当 battle_id —— 分块只需要它能
		# 区分"这一场"和"上一场"，不需要它有别的含义。
		_send_replay_to_peer(int(peer_id), "host:%d" % GameState.round_index,
			packed_a if slot < 3 else packed_b, packed_b if slot < 3 else packed_a)

# --- replay 打包 -------------------------------------------------------------
# 实测（tools/battle_perf_check.tscn，第 21 回合满配最坏一场）：
#   原始 3639 KB -> zstd 61.8 KB   压缩率 0.017   压缩耗时 1.7 ms
#   var_to_bytes 25.7 ms（比压缩贵 15 倍）  客户端解压 1.3 ms
#
# 改这里之前，replay 是把 Dictionary 直接塞进 RPC 发的，而且是 rpc_id 逐个 peer 发：
#   * 不压缩 -> 每人收 2 × 3.6 MB = 7.3 MB，六人一轮 43 MB。这是弱网掉线可量化的直接原因
#   * 逐个发 -> 同一份 replay 被序列化 6 次 = 154 ms 纯浪费在主循环上
# 现在整局只做一次序列化 + 一次压缩，所有 peer 复用同一份 PackedByteArray
# （PackedByteArray 进 RPC 只是 memcpy，不再走嵌套容器的递归序列化）。
#
# 压缩后最坏 61.8 KB。分块/确认/重试现已实现（见下面“回放分块下发”一节），
# 但**阈值是 192 KiB，所以这个 61.8 KB 的最坏局仍然走单包路径** ——
# 分块只对离群大局和强制模式生效。这不是把它做成摆设，而是不愿意为一个
# 当前不存在的问题把重组缓冲（= 一个新的内存攻击面）放到典型路径上。
# 上限与包格式的实现都在 ReplayTransferService（MAX_UNCOMPRESSED_BYTES / PACK_HEADER_BYTES）。
# 编解码实现已随 team_replay 一起搬到 ReplayTransferService（PACK_HEADER_BYTES /
# MAX_UNCOMPRESSED_BYTES / pack / unpack）。这两个函数保留为门面薄包装：
# tools/adversarial_client_node.gd 与 tools/channel_check_node.gd 共 7 处直接调用它们
# （往返、空包、损坏包、解压炸弹、假长度头），保住包装就保住了这些用例。
func _pack_replay(replay: Dictionary) -> PackedByteArray:
	return _replay_transfer.pack(replay)

func _unpack_replay(packed: PackedByteArray) -> Dictionary:
	return _replay_transfer.unpack(packed)

# =============================================================================
# 回放分块下发 / 确认 / 重试（原始 README 给 ReplayTransferService 定的后三件事）
# =============================================================================
#
# 分界：切块、重组、缺块查询是**纯策略**，在 ReplayTransferService 里；
# 这里只负责发包、收包、计时——那三件都要 multiplayer，而服务是 RefCounted，够不着。
#
# 为什么要有阈值：实测最坏一场压缩后 61.8 KB（见上面 _pack_replay 的实测记录），
# 而 tools/channel_check 已经证明 200 KB 能过 CH_BULK。也就是说**生产里根本不会触发
# 分块**。这不是把分块做成摆设的理由，而是它必须带一个强制开关的理由：
# 一条永远走不到的代码路等于没写。门禁与真机双设备测试都走 force。
#
# 混合情况（本方大、敌方小）**一律两边都分块**：客户端因此只有两条路径而不是三条，
# "单包收到一半、分块收到另一半"那种状态机不值得为省几 KB 去维护。

# 没等到确认就重发的间隔。回放走 CH_BULK 可靠有序通道，正常情况不该丢；
# 这个超时兜的是"整条 ENet 连接抖了一下"，不是常规传输手段。
const REPLAY_ACK_TIMEOUT_SEC := 6.0
# 放弃前的重发次数。无限重试对一个卡死的客户端就是自造放大器：
# 每次重发都是几十 KB，而对面根本没在收。
const REPLAY_MAX_RETRIES := 3

# 服务端：peer_id -> {battle_id, kinds, payloads:{kind:PackedByteArray}, done:{kind:true},
#                    deadline: float, tries: int}
var _replay_out: Dictionary = {}
# 客户端：battle_id -> {kinds:int, done:{kind:PackedByteArray}}
# 重组本身在 ReplayTransferService 里，这里只记"哪几种收齐了"。
var _replay_in: Dictionary = {}
# 只给门禁与真机测试用：把生产里走不到的分块路径强制走一遍。
var _force_replay_chunking := false

# 待发的回放块，按 FIFO 排。每项 {peer_id, battle_id, kind, idx, total, kinds, data}。
#
# **为什么不直接 rpc_id 发完**：见 _tick_replay_send。一句话版本 ——
# 加密链路上一帧灌进去太多字节，接收端 UDP 缓冲会溢出丢包，然后 ENet 重传，
# 62 KB 的回放在零丢包的本机回环上要跑 2.7 秒。
var _replay_send_queue: Array = []

# 每帧允许送出的回放字节数。实测已知 32 KB/帧 可以、48 KB/帧 会塌，取 16 KB
# 留一倍余量。明文链路不受影响（那边阈值高，压根不会走到分块路径）。
const REPLAY_SEND_BUDGET_BYTES := 16 * 1024


func set_force_replay_chunking(on: bool) -> void:
	_force_replay_chunking = on
	_net_log("replay chunking forced=%s" % str(on))


# 给一个 peer 发一份回放。低于阈值走原来的单包 _rpc_team_replay（一个字节都不变），
# 超过阈值才走分块。两个发送点和重连补发都从这里过。
func _send_replay_to_peer(peer_id: int, battle_id: String, own: PackedByteArray, rival: PackedByteArray) -> void:
	if not (_replay_transfer.should_chunk(own, _force_replay_chunking)
			or _replay_transfer.should_chunk(rival, _force_replay_chunking)):
		_rpc_team_replay.rpc_id(peer_id, own, rival)
		return

	var payloads := {}
	payloads[ReplayTransferService.CHUNK_KIND_OWN] = own
	# 敌方回放可能是空的（例如只有一队时）。空的就不列入 kinds，
	# 否则客户端会永远差一种、凑不齐。
	if rival.size() > ReplayTransferService.PACK_HEADER_BYTES:
		payloads[ReplayTransferService.CHUNK_KIND_RIVAL] = rival

	_replay_out[peer_id] = {
		"battle_id": battle_id,
		"kinds": payloads.size(),
		"payloads": payloads,
		"done": {},
		"deadline": _now() + REPLAY_ACK_TIMEOUT_SEC,
		"tries": 0,
	}
	_net_log("replay chunked send peer=%d battle=%s kinds=%d bytes=%d/%d" % [
		peer_id, battle_id, payloads.size(), own.size(), rival.size()])
	_send_replay_chunks(peer_id, PackedInt32Array(), "")


# 发块。missing 为空 = 全发；否则只补这一 kind 缺的那几块（重试路径）。
func _send_replay_chunks(peer_id: int, missing: PackedInt32Array, only_kind: String) -> void:
	var pending: Dictionary = _replay_out.get(peer_id, {})
	if pending.is_empty():
		return
	var battle_id := str(pending.get("battle_id", ""))
	var kinds := int(pending.get("kinds", 0))
	var payloads: Dictionary = pending.get("payloads", {})
	var done: Dictionary = pending.get("done", {})
	for kind in payloads.keys():
		if not only_kind.is_empty() and str(kind) != only_kind:
			continue
		if done.has(kind):
			continue          # 这一种对方已经确认收齐，别再发
		var chunks: Array = _replay_transfer.split(payloads[kind], battle_id, str(kind))
		if chunks.is_empty():
			# split 拒绝了（超过单次传输上限）。这一份发不出去，如实记下来 ——
			# 静默丢弃的话玩家只会看到"回放不来"，日志里什么都没有。
			_net_log("replay chunk send aborted peer=%d kind=%s bytes=%d (split refused)" % [
				peer_id, str(kind), (payloads[kind] as PackedByteArray).size()])
			continue
		for env in chunks:
			var idx := int((env as Dictionary).get("idx", 0))
			if missing.size() > 0 and not missing.has(idx):
				continue
			# 入队，不直接发 —— 节流在 _tick_replay_send 里按字节预算放行。
			_replay_send_queue.append({
				"peer_id": peer_id,
				"battle_id": battle_id,
				"kind": str(kind),
				"idx": idx,
				"total": int((env as Dictionary).get("total", 0)),
				"kinds": kinds,
				"data": (env as Dictionary).get("data", PackedByteArray()),
			})


# 服务端下发的分块。authority：只有服务器能发，客户端这边照收。
#
# 校验全部在 ReplayTransferService.accept_chunk 里（重组缓冲有条数、单条、总量三道
# 上限加过期回收）—— 这里只做"收齐了就应用"。
@rpc("authority", "call_remote", "reliable", NetworkConfig.CH_BULK)
func _rpc_team_replay_chunk(battle_id: String, kind: String, idx: int, total: int,
		kinds: int, data: PackedByteArray) -> void:
	if battle_id.length() > MAX_TREASURE_ID_LEN:
		return
	if kinds <= 0 or kinds > 2:
		return
	var out: Dictionary = _replay_transfer.accept_chunk({
		"battle_id": battle_id, "kind": kind, "idx": idx, "total": total, "data": data,
	})
	if not str(out.get("error", "")).is_empty():
		return
	if not bool(out.get("complete", false)):
		return

	# 这一种收齐了：记下来并向服务端确认（missing 为空 = 收齐）。
	var slot_in: Dictionary = _replay_in.get(battle_id, {"kinds": kinds, "done": {}})
	(slot_in["done"] as Dictionary)[kind] = out.get("packed", PackedByteArray())
	slot_in["kinds"] = kinds
	_replay_in[battle_id] = slot_in
	_rpc_replay_ack.rpc_id(1, battle_id, kind, PackedInt32Array())

	if (slot_in["done"] as Dictionary).size() < kinds:
		return

	# 全部收齐：走和单包路径**完全一样**的落地动作，否则两条路径会有行为差。
	var done_map: Dictionary = slot_in["done"]
	team_replay = _unpack_replay(done_map.get(ReplayTransferService.CHUNK_KIND_OWN, PackedByteArray()))
	team_replay_rival = _unpack_replay(done_map.get(ReplayTransferService.CHUNK_KIND_RIVAL, PackedByteArray()))
	_replay_in.erase(battle_id)
	_net_log("client received chunked replay battle=%s kinds=%d" % [battle_id, kinds])
	team_replay_received.emit()


# 客户端 -> 服务端的确认 / 缺块上报。
#   missing 空     = 这一种收齐了，别再发
#   missing 非空   = 还缺这几块，只补这几块
#
# any_peer + 未经验证的输入：必须限流（和 _rpc_result_ack 同样处理）。
@rpc("any_peer", "call_remote", "reliable", NetworkConfig.CH_CONTROL)
func _rpc_replay_ack(battle_id: String, kind: String, missing: PackedInt32Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "replay_ack"):
		return
	if battle_id.length() > MAX_TREASURE_ID_LEN:
		return
	var pending: Dictionary = _replay_out.get(sender, {})
	if pending.is_empty():
		return
	# 只认当前这一场。迟到的旧确认会把这一场的下发误判成已完成 ——
	# 这和 _rpc_result_ack 用 battle_id 挡旧 ACK 是同一个理由。
	if str(pending.get("battle_id", "")) != battle_id:
		return
	var payloads: Dictionary = pending.get("payloads", {})
	if not payloads.has(kind):
		return

	if missing.is_empty():
		(pending["done"] as Dictionary)[kind] = true
		if (pending["done"] as Dictionary).size() >= int(pending.get("kinds", 0)):
			_replay_out.erase(sender)
			_net_log("replay delivery complete peer=%d battle=%s" % [sender, battle_id])
			return
		_replay_out[sender] = pending
		return

	# 缺块上报：只补缺的那几块，并把超时往后推——对方在动，不该被当成卡死。
	if missing.size() > ReplayTransferService.MAX_CHUNKS:
		return
	pending["deadline"] = _now() + REPLAY_ACK_TIMEOUT_SEC
	_replay_out[sender] = pending
	_net_log("replay nack peer=%d battle=%s kind=%s missing=%d" % [
		sender, battle_id, kind, missing.size()])
	_send_replay_chunks(sender, missing, kind)


# 重试。形状照抄 _tick_tx_retry：到期才动、有次数上限、放弃时如实记一笔。
#
# 为什么服务端要有超时重发而不是只等客户端上报缺块：客户端**一块都没收到**时
# 它根本不知道有这么一次下发，也就报不出缺块。那种情况只有服务端能发现。
func _tick_replay_retry(_delta: float) -> void:
	if _replay_out.is_empty():
		return
	var now := _now()
	for peer_id in _replay_out.keys():
		var pending: Dictionary = _replay_out[peer_id]
		if now < float(pending.get("deadline", 0.0)):
			continue
		if not _peer_connected(int(peer_id)):
			# 人已经掉了。留着只是占内存 —— 他重连回来时走 _resume_seat 补发。
			_replay_out.erase(peer_id)
			continue
		if int(pending.get("tries", 0)) >= REPLAY_MAX_RETRIES:
			# 放弃。回放只是播放素材，收不到不该阻塞任何东西：权威结算走的是
			# match_state / room_state，那两条都不经过这里。
			_net_log("replay give up peer=%d battle=%s tries=%d (replay only, settlement unaffected)" % [
				int(peer_id), str(pending.get("battle_id", "")), int(pending.get("tries", 0))])
			_replay_out.erase(peer_id)
			continue
		pending["tries"] = int(pending.get("tries", 0)) + 1
		pending["deadline"] = now + REPLAY_ACK_TIMEOUT_SEC
		_replay_out[peer_id] = pending
		_net_log("replay retry peer=%d battle=%s try=%d" % [
			int(peer_id), str(pending.get("battle_id", "")), int(pending["tries"])])
		_send_replay_chunks(int(peer_id), PackedInt32Array(), "")


# 按字节预算把排队的回放块发出去。**每帧都要跑**，不能挂在那个 1 秒的
# 累加器下面 —— 节流的全部意义就是把字节摊到多帧上。
#
# 这是 C14 能不能上线的前提，不是优化。DTLS 垫在 ENet 底下之后，ENet 一帧内
# 轰出去的分片会把接收端 UDP 缓冲挤爆，丢了再重传。实测（Godot 4.7.1，零丢包
# 本机回环）62 KB 单包从 20 ms 变成 2686 ms；同样的字节数摊成一帧 16 KB 之后
# 是 35 ms。决定成败的是「两次 poll 之间灌进去多少字节」。
#
# 至少放行一块：块大小若超过预算，一块也不发就是永远发不出去。
func _tick_replay_send() -> void:
	if _replay_send_queue.is_empty():
		return
	var budget := REPLAY_SEND_BUDGET_BYTES
	while not _replay_send_queue.is_empty():
		var item: Dictionary = _replay_send_queue[0]
		var peer_id := int(item.get("peer_id", 0))
		# 这一场已经确认收齐 / 对方掉线 / 已放弃 —— 队里的残块直接丢掉，
		# 不然会给一个不存在的传输继续发包。
		if not _replay_out.has(peer_id):
			_replay_send_queue.pop_front()
			continue
		var data: PackedByteArray = item.get("data", PackedByteArray())
		if data.size() > budget and budget < REPLAY_SEND_BUDGET_BYTES:
			return          # 本帧预算用得差不多了，剩下的下一帧再说
		_replay_send_queue.pop_front()
		_rpc_team_replay_chunk.rpc_id(peer_id, str(item.get("battle_id", "")),
			str(item.get("kind", "")), int(item.get("idx", 0)),
			int(item.get("total", 0)), int(item.get("kinds", 0)), data)
		budget -= data.size()
		if budget <= 0:
			return


# 断线时把这个 peer 的下发状态丢掉。不清的话每个掉线的人都留一份几十 KB 的
# payloads 在 _replay_out 里，而他重连回来走的是 _resume_seat 补发那条路。
func _replay_forget_peer(peer_id: int) -> void:
	_replay_out.erase(peer_id)
	# 队里可能还压着这个人的块。不清就是给一个已经没了的连接继续排队。
	if _replay_send_queue.is_empty():
		return
	var kept: Array = []
	for item in _replay_send_queue:
		if int((item as Dictionary).get("peer_id", 0)) != peer_id:
			kept.append(item)
	_replay_send_queue = kept

# B9：replay 走独立可靠通道 CH_BULK。它内部仍然有序、仍然可靠，
# 但**压不到控制流**——房间状态、结算、交易、握手都在 CH_CONTROL 上各走各的。
@rpc("authority", "call_remote", "reliable", NetworkConfig.CH_BULK)
func _rpc_team_replay(packed: PackedByteArray, packed_rival: PackedByteArray = PackedByteArray()) -> void:
	team_replay = _unpack_replay(packed)
	team_replay_rival = _unpack_replay(packed_rival)
	_net_log("client received replay round=%d kind=%s bytes=%d/%d" % [
		GameState.round_index, str(team_replay.get("kind", "")), packed.size(), packed_rival.size()])
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
				# 拒收不能是静默的。但**权威回合不再由这条消息携带**（E2）——
				# 它只是"你交的那份被拒了"的通知；正确的回合号来自 room_state。
				# 旧实现让这条也带状态，于是它和 team_lobby 成了两个能互相覆盖的
				# 状态源（B6 回合号双份真相）。
				_send_room_state(room, sender, _bump_room_seq(room))
				_rpc_board_rejected.rpc_id(sender, reason)
			return
		# 血统核验：四星必须来自一次成功的 use_upgrade_stone 交易。
		# 放在这里而不是 NetProtocol 里 —— 那边是纯静态、拿不到 room，而
		# _restamp_cached_board() 会拿跨回合缓存重跑它，塞进去会让看门狗代打
		# 因为「服务器重启后 boards/last_board 没持久化」而莫名拒掉整个座位。
		var provenance := _room_validate_provenance(room, slot, validation.get("snapshot", {}))
		if not bool(provenance.get("ok", false)):
			var bad := str(provenance.get("reason", "forged_four_star"))
			_net_log("board rejected reason=%s room=%d round=%d slot=%d" % [
				bad, int(room.get("id", 0)), int(room.get("round_index", 1)), slot])
			# 明确拒收 + 补一份 room_state。静默丢会让这个座位一直卡到看门狗超时。
			_send_room_state(room, sender, _bump_room_seq(room))
			_rpc_board_rejected.rpc_id(sender, bad)
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

# 遗留大包（本地房主路径），同样归 bulk 通道（B9）。
@rpc("authority", "call_remote", "reliable", NetworkConfig.CH_BULK)
func _rpc_team_boards(boards: Dictionary, seed: int) -> void:
	team_boards = boards
	shared_seed = seed
	team_boards_ready.emit()

# 「你交的那份棋盘被拒了」。**不携带任何权威状态**（E2）——
# 正确的回合号来自紧随其后的 room_state。旧实现让这条也带 round+phase，
# 于是它和 team_lobby 成了两个能互相覆盖的状态源，正是 B6「回合号双份真相」。
#
# 收到之后按已经对齐好的权威回合重交一次（每回合最多一次，防循环）。
# 这条链路修掉的是实测记录过的死循环："落后一轮 -> 提交永远被拒 ->
# 心跳被卡 -> 被踢 -> 重连回来还是旧回合"。
@rpc("authority", "call_remote", "reliable")
func _rpc_board_rejected(reason: String) -> void:
	_net_log("board rejected by server: %s (authoritative round=%d)" % [reason, server_round_index])
	if _last_team_submission.is_empty() or _resync_resubmitted_round == server_round_index:
		return
	_resync_resubmitted_round = server_round_index
	var snap: Dictionary = _last_team_submission.duplicate(true)
	snap.round = server_round_index
	team_submit_board(snap)

# 看门狗代交 / 重连补交时复用上一轮缓存棋盘（C6）。
# 旧实现直接 `boards[i] = last_board[i]`：那份快照带的是**上一轮**的 round 与 gold，
# 而且从没重新过一遍当前轮的 validate_team_snapshot。掉线玩家每被代打一轮，
# 金币就按旧值回滚一次，回合戳也和本轮对不上。
# 这里重新盖当前轮的戳并重新校验；校验不过就退回原样（宁可用一份旧的，
# 也不能让房间因为拿不到棋盘而卡到超时）。
# 经济部分的根治仍要等 P1 服务端账本 —— 这里只保证"不比上一轮更错"。
func _restamp_cached_board(room: Dictionary, slot: int, cached: Variant) -> Dictionary:
	if typeof(cached) != TYPE_DICTIONARY:
		return {}
	var round_index := int(room.get("round_index", 1))
	var snap: Dictionary = (cached as Dictionary).duplicate(true)
	snap["round"] = round_index
	# 金币以服务端记录为准，不用快照里那份上一轮的。
	var slot_gold: Array = room.get("slot_gold", [])
	if slot >= 0 and slot < slot_gold.size() and slot_gold[slot] != null:
		snap["gold"] = int(slot_gold[slot])
	var validation := NetProtocol.validate_team_snapshot(snap, round_index)
	if bool(validation.get("ok", false)):
		return validation.get("snapshot", {})
	_net_log("cached board restamp failed room=%d slot=%d reason=%s (using raw cache)" % [
		int(room.get("id", 0)), slot, str(validation.get("reason", ""))])
	return cached as Dictionary

func _room_try_finalize_boards(room: Dictionary) -> void:
	# 守卫收进函数内部。此前安全完全靠 5 个调用点各自先判 ROOM_BATTLE——漏一个就会
	# 同一回合算两次战斗、扣两次 HP、重复发一次宝物 offer。
	# 这只是状态门；跨包重复的幂等键（battle_id/round_id）归 R6/B6。
	if str(room.get("state", "")) != ROOM_BATTLE:
		return
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
	# 本场战斗的唯一标识（E3）。结算、replay、确认回执都靠它对齐 ——
	# 没有它就没法区分"这个 ACK 是这一场的"还是"上一场迟到的"。
	room.battle_id = "%d:%d:%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), int(room.get("state_seq", 0))]
	room.result_acks = {}
	# 不再向专服客户端广播 boards。它是全部 6 人的完整快照（每个单位带整份 def），
	# 而专服路径的客户端不本地模拟——它等的是 team_replay，replay 自带 roster。
	# 这份广播因此是纯浪费，还顺带把 shared_seed 提前交到客户端手里（可预演战斗）。
	# _rpc_team_boards 方法保留：删方法会平移整套 RPC 的 wire ID，属破坏性变更。
	# 本地房主调试路径仍走 _team_try_finalize_boards 里的广播，不受影响。
	_enqueue_finalize(room)

# --- 结算并发闸（B4 前半）-----------------------------------------------------
# 实测：一房一回合的两场战斗，最坏（第 21 回合满配）合计 1162 ms。
# 而多个房间的最后一份棋盘可能落在同一帧里（RPC 批量到达、或看门狗一次扫出好几个），
# 于是 N 个房间的战斗在**同一个调用栈里**连着算完 —— 20 个房间 = 23 秒，
# 这段时间 _process 一次都不跑：心跳不回、pong 不发，全服客户端一起判超时。
#
# 这道闸把「N 个房间挤一帧」摊成「每帧一个房间」。
#
# ⚠️ 它买到的**不是**总耗时变短 —— 20 个房间还是 23 秒。
# 买到的是**每两场战斗之间 _process 会跑一次**，心跳和 pong 挤得进去。
# 「单场 581 ms 本身就阻塞 17 帧」这件事它解决不了，那只能靠
# BattleContext 去全局化之后换 compute_team_replay_async（B4 后半）。
const FINALIZE_PER_FRAME := 1

var _finalize_queue: Array = []   # room_id，先进先出

func _enqueue_finalize(room: Dictionary) -> void:
	var rid := int(room.get("id", 0))
	if _finalize_queue.has(rid):
		return
	_finalize_queue.append(rid)

func _drain_finalize_queue() -> void:
	var budget := FINALIZE_PER_FRAME
	while budget > 0 and not _finalize_queue.is_empty():
		var rid := int(_finalize_queue.pop_front())
		var room: Dictionary = _rooms.get(rid, {})
		# 排队期间房间可能已经被回收/关闭/推进了阶段 —— 静默跳过，不补算。
		if room.is_empty() or str(room.get("state", "")) != ROOM_RESULT:
			continue
		budget -= 1
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
	# C8：这两个是**不同的东西**，此前共用 `final_battle_complete` 一个名字。
	#   room.run_over            服务端义：对局已结束（不再开新回合、不再可 resume）
	#   GameState.final_round_played  客户端义：第 21 战已经打过（RoundService 据此
	#                                 决定第 21 回合还算不算 "final" 编队）
	# 这里用 run_over 当保守代理：对局一旦结束就不会再算战斗，所以"不要再把第 21
	# 回合当 final 重算"这个效果是对的。名字分开后，读的人不会再以为两者同义。
	GameState.final_round_played = bool(room.get("run_over", false))
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
	var replay_a := BattleSim.compute_team_replay(0, str(room.get("battle_id", "")))
	var replay_b := BattleSim.compute_team_replay(1, str(room.get("battle_id", "")))
	BattleSim.stamp_team_round_damages(replay_a, replay_b)
	var match_states := _room_build_match_states(room, replay_a, replay_b)
	room.last_match_state = match_states
	_net_log("server replay/result generated room=%d round=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1))])
	# 序列化 + 压缩各做一次，六个 peer 复用同一份字节。
	# 此前是逐个 peer 发 Dictionary，同一份 replay 被序列化 6 次（实测 25.7 ms × 6
	# ≈ 154 ms 白烧在主循环上），而且完全没压缩（每人 7.3 MB，六人一轮 43 MB）。
	var pack_t0 := Time.get_ticks_usec()
	var packed_a := _pack_replay(replay_a)
	var packed_b := _pack_replay(replay_b)
	var pack_us := Time.get_ticks_usec() - pack_t0
	_net_log("replay packed room=%d round=%d a=%d B b=%d B pack_usec=%d" % [
		int(room.get("id", 0)), int(room.get("round_index", 1)), packed_a.size(), packed_b.size(), pack_us])
	_metrics_log_payloads(room, replay_a, packed_a.size(), packed_b.size(), match_states)
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		if not _peer_connected(int(peer_id)):
			continue
		var slot := int((room.get("peer_slot", {}) as Dictionary)[peer_id])
		# 顺序要紧：match_state（几百字节，权威结算）必须排在 replay 之前。
		# 反过来时结算状态被压在大包后面，弱网重传期间玩家就卡在「战斗打完但结算不来」——
		# 这正是 match_state 超时的直接成因。replay 只是播放素材，晚到无所谓。
		_rpc_receive_match_state.rpc_id(int(peer_id), match_states.get(slot, {}))
		# 两队 replay 一律全发（已确认的产品规则：玩家要能随时切镜头看另一队）。
		# 旧的 send_rival_replay 开关与这条规则冲突，已废除 —— 压缩后一份才 62 KB，
		# 当初"关掉它省带宽"的理由也不再成立。
		_send_replay_to_peer(int(peer_id), str(room.get("battle_id", "")),
			packed_a if slot < 3 else packed_b,
			packed_b if slot < 3 else packed_a)
		_net_log("match_state/replay sent room=%d round=%d peer=%d slot=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), int(peer_id), slot])
	# 留一份给重连的人补看（已确认的产品规则：重连回来的人应该补看那一场的回放）。
	# **只留内存，不进快照** —— DedicatedServerService.PERSISTED_ROOM_FIELDS 白名单
	# 刻意排除了 boards/last_board 这类缓存大字段，回放（两份约 196 KB）同理：
	# 快照是每 5 秒全量序列化写盘的，无脑塞进去就是给自己造一个新的冻结源。
	# 代价如实记：服务器重启后这一场的回放没了，重连者仍只能看到结算结果。
	room.replay_packed = {"a": packed_a, "b": packed_b}
	room.boards = {}

# 影子审计：只记录、不拦截。上线前必须先知道自己的误判率——直接开拦截会把
# 数据表不同步、存档迁移、重连边界上的诚实玩家一起判成作弊。
# 跑够一周零差异，再把这些规则翻成硬拒收（见整改方案「影子模式」）。
# 一份已过语法校验的棋盘里，每一枚四星是不是真的。
#
# 只凭客户端在快照里自报 star=4 是认不出伪造的 —— 改一下内存或存档就能造四星，
# 这是设计文档《萝卜采集与升级石系统设计实施方案》:246 点名要堵的洞。
#
# 判据：uid 必须在本座位的 four_star_uids 里，且 unit_id 对得上（防止把一枚
# 四星的 uid 挪到另一个单位上）。佣兵一律不许四星（设计文档 §2.6：佣兵只存在
# 一个回合，升星是白送）。
#
# ⚠️ 双实现登记：economy_ledger_enabled 打开之后 prep["roster"] 会记录每一枚棋子，
# 届时这里应当收敛成 roster[uid].star == MAX_STAR，**并删掉 four_star_uids**
# （见 EconomyLedger._use_upgrade_stone 顶部）。
func _room_validate_provenance(room: Dictionary, slot: int, snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty():
		return {"ok": true}
	var prep := _room_prep(room, slot)
	var granted: Dictionary = prep.get("four_star_uids", {})
	for key in ["board", "mercenaries"]:
		for cell in (snapshot.get(key, []) as Array):
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			var c: Dictionary = cell
			if int(c.get("star", 1)) < GameState.MAX_UNIT_STAR:
				continue
			if bool(c.get("is_mercenary", false)):
				return {"ok": false, "reason": "forged_four_star:mercenary"}
			var uid := str(c.get("uid", ""))
			if uid.is_empty() or not granted.has(uid):
				return {"ok": false, "reason": "forged_four_star:%s" % str(c.get("id", "?"))}
			if str((granted[uid] as Dictionary).get("unit_id", "")) != str(c.get("id", "")):
				return {"ok": false, "reason": "forged_four_star:unit_mismatch"}
	return {"ok": true}

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

	# (1b) 归属比对：客户端上报的持有集 vs 服务端实际发放并被领取的集合。
	# 这条比 (1) 的数量上界强——(1) 依赖两端 round_schedule.json 一致（C11），
	# 这条只依赖「服务器自己发过什么」，没有外部数据依赖，可以先于数据哈希转硬拒收。
	# 仍留在影子模式的原因：首批上线时房间里可能有本改动之前建立的座位，
	# owned_treasures 为空会把所有人误判。跑满一个版本零 unexpected 才翻开关。
	var server_owned := _room_owned_treasures(room, slot)
	var server_set := {}
	for t in server_owned:
		server_set[str(t)] = true
	var unexpected: Array = []
	for t in owned:
		if not server_set.has(str(t)):
			unexpected.append(str(t))
	if not unexpected.is_empty():
		_net_log("shadow treasure_unowned room=%d round=%d slot=%d client=%d server=%d unexpected=%s" % [
			int(room.get("id", 0)), round_index, slot, owned.size(), server_owned.size(), str(unexpected)])

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
	# (2b) P1 账本比对。上面那条比的是「和上次结算差多少」（备战期本来就会差，
	# 只能看分布）；这一条比的是「和账本记的差多少」——账本**知道**备战期发生了什么，
	# 所以这里的差值理论上应该恒为 0。**影子期零差异是翻 authoritative 开关的唯一依据。**
	_shadow_audit_economy(room, slot, int(raw.get("gold", 0)))

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
func _metrics_log_payloads(room: Dictionary, replay_a: Dictionary, packed_a_size: int, packed_b_size: int, match_states: Dictionary) -> void:
	if not ServerFlags.should_sample_battle():
		return
	# 压缩后的大小由发送路径直接给进来（packed_a/packed_b），这里**不再重复
	# 序列化+压缩一遍** —— 那是真实开销，在同步主循环上白烧 25 ms 只为记一行日志。
	# 仍要单独算的只有原始大小（用于算压缩率）和 boards / match_state 的体积。
	var t0 := Time.get_ticks_usec()
	var raw_a := var_to_bytes(replay_a)
	var serialize_usec := Time.get_ticks_usec() - t0
	var boards_bytes := var_to_bytes(room.get("boards", {})).size()
	var ms_bytes := var_to_bytes(match_states).size()
	var frames_a: Array = replay_a.get("frames", [])
	_net_log("metrics room=%d round=%d kind=%s frames=%d replay_a_raw=%d replay_a_zstd=%d replay_b_zstd=%d ratio=%.3f boards=%d match_state=%d ser_usec=%d" % [
		int(room.get("id", 0)),
		int(room.get("round_index", 1)),
		str(replay_a.get("kind", "")),
		frames_a.size(),
		raw_a.size(),
		packed_a_size,
		packed_b_size,
		(float(packed_a_size) / float(maxi(1, raw_a.size()))),
		boards_bytes,
		ms_bytes,
		serialize_usec,
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
	# 单场胜负走 TeamOutcome（C16）：服务端结算、BattleUI 字幕、Main fallback 三处
	# 共用同一份实现，不再各写各的。
	var team_wins := [
		TeamOutcome.team_wins_battle(res_a, res_b, kind, TeamOutcome.TEAM_A),
		TeamOutcome.team_wins_battle(res_a, res_b, kind, TeamOutcome.TEAM_B),
	]
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
		room.run_over = true
	# 整局归属同样走 TeamOutcome。规则见该文件：第 21 回合按最终战结果；
	# 双杀且无正面胜负可依时记平局，不再用 `hp_a >= hp_b`（0 >= 0）默认判 A 胜。
	var outcome := TeamOutcome.run_outcome({
		"completed_round": completed_round,
		"final_round": GameState.FINAL_ROUND,
		"hp_a": hp_a,
		"hp_b": hp_b,
		"kind": kind,
		"battle_a_wins": bool(res_a.get("player_wins", false)),
		"battle_is_draw": bool(res_a.get("is_draw", false)),
	})
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
		# 结算的起点金币：账本权威时读账本，否则退回**客户端自报**（历史行为）。
		# 后者正是 A5 的核心洞 —— 连"权威"的战后结算都是拿客户端给的数字当种子的。
		var gold_before := int(snap.get("gold", slot_gold[slot]))
		if economy_authoritative():
			gold_before = int(_room_prep(room, slot).get("gold", slot_gold[slot]))
		var gold_after := _server_gold_after_battle(gold_before, result, slot, snap, {
			"kind": kind,
			"player_wins": bool(team_wins[own_team]),
			"round_index": completed_round,
			"loss_streak_after": int(loss_streak[own_team]),
			"camp_income": CarrotEconomy.income_for_spent(int(_room_prep(room, slot).get("merc_carrots_spent_total", 0))),
		})
		slot_gold[slot] = gold_after
		# 战后收益回写账本，让下一轮备战从正确的余额开始（P1）。
		if _economy_action_enabled("upgrade_harvest_tech"):
			_room_prep(room, slot)["gold"] = gold_after
		out[slot] = {
			"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
			# 结算确认的锚点（E3）：客户端应用完这份结算后按它回 ACK，
			# 服务器据此判断"所有在线真人都看到结果了"才推进下一轮。
			"battle_id": str(room.get("battle_id", "")),
			"completed_round": completed_round,
			"round_index": next_round,
			"kind": kind,
			"slot": slot,
			"team_hp": hp_a if own_team == 0 else hp_b,
			"enemy_team_hp": hp_b if own_team == 0 else hp_a,
			"gold": gold_after,
			# 与 room_state 的 economy 段同一道门。以前这里无条件发萝卜字段、客户端
			# 只判 has("carrots")，于是开关关掉时每次战后结算都会拿服务端那份没动过的
			# 零值把客户端的萝卜/科技/消费总额/队伍石头**全部清掉**，且无从察觉。
			"carrot_authoritative": carrot_economy_enabled(),
			"carrots": int(_room_prep(room, slot).get("carrots", 0)),
			"harvest_tech_level": int(_room_prep(room, slot).get("harvest_tech_level", 0)),
			"merc_carrots_spent_total": int(_room_prep(room, slot).get("merc_carrots_spent_total", 0)),
			"last_harvest_round": int(_room_prep(room, slot).get("last_harvest_round", -1)),
			"stone_draw_used_round": int(_room_prep(room, slot).get("stone_draw_used_round", -1)),
			"team_upgrade_stones": _room_team_stones(room, slot).duplicate(true),
			"pve_completed": int(room.get("pve_completed", 0)),
			"boss_completed": int(room.get("boss_completed", 0)),
			"loss_streak": int(loss_streak[own_team]),
			"run_over": run_over,
			"final_round_played": completed_round >= GameState.FINAL_ROUND,
			# run_outcome 是权威值（TEAM_A / TEAM_B / DRAW）。
			# team_run_won 保留为派生的本队视角布尔：平局时两队都不算赢。
			"run_outcome": outcome,
			"team_run_won": TeamOutcome.team_won_run(outcome, own_team),
			"pending_treasure": _server_pending_treasure(room, slot, completed_round),
		}
	room.slot_gold = slot_gold
	_net_log("official match_state generated room=%d round=%d hp=%s gold=%s run_over=%s outcome=%s" % [
		int(room.get("id", 0)), completed_round, str(room.team_hp), str(slot_gold), str(run_over),
		["team_a", "team_b", "draw"][outcome]])
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
		"camp_income": int(round_ctx.get("camp_income", 0)),
	})

const TREASURE_OFFER_NONE := {"active": false, "round": 0, "candidates": [], "refresh_index": 0}

# 服务端认可的持有列表。这是「宝物归属」的唯一真相，与客户端上报的 snapshot.treasures
# 分开维护——后者仍然是客户端自报，只用于影子比对（见 _shadow_audit_submission）。
func _room_owned_treasures(room: Dictionary, slot: int) -> Array:
	var owned_map: Dictionary = room.get("owned_treasures", {})
	var owned = owned_map.get(slot, [])
	return (owned as Array) if typeof(owned) == TYPE_ARRAY else []

# 发放本回合的宝物候选，并把这份 offer 记进房间。
# 关键改动：`owned` 从「客户端上报的 treasures」换成「服务端记录的持有列表」——
# 否则客户端只要少报几件，服务器就会一直给它发新候选，MAX_OWNED 形同虚设。
func _server_pending_treasure(room: Dictionary, slot: int, completed_round: int) -> Dictionary:
	var offers: Dictionary = room.get("treasure_offer", {})
	var owned := _room_owned_treasures(room, slot)
	if not RoundService.is_treasure_round(completed_round) or owned.size() >= TreasureService.MAX_OWNED:
		offers.erase(slot)
		room.treasure_offer = offers
		return TREASURE_OFFER_NONE.duplicate(true)
	var candidates := _server_roll_treasure_candidates(owned, 3)
	if candidates.is_empty():
		offers.erase(slot)
		room.treasure_offer = offers
		return TREASURE_OFFER_NONE.duplicate(true)
	offers[slot] = {"round": completed_round, "candidates": candidates.duplicate(), "refresh_index": 0}
	room.treasure_offer = offers
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

# --- 退出与失败的分流（E3 / R1，对应 B8）------------------------------------
# 旧的 `disconnect_session()` 把两件完全不同的事混在一起：
#   * 玩家点"返回主菜单" —— 明确退出，凭证该作废
#   * replay 超时 / 结算没等到 —— **技术失败**，凭证还好好的
# 而它对两者都是"发 leave + 立刻清 token + 关 peer"。于是一个几秒后能自愈的
# 传输问题，被升级成"玩家永久回不去这一局"，服务器那边座位还留着等他。
#
# 现在分成两个入口，语义写在名字里。

const LEAVE_RECEIPT_TIMEOUT_SEC := 8.0

var _pending_leave_id := ""
var _leave_deadline := 0.0
# request_id -> 处理时刻。存在房间之外：最后一人退出会立刻关房，
# 而他仍然需要能凭同一个 id 重取回执（否则重试会被当成新请求）。
const LEAVE_TOMBSTONE_TTL_SEC := 600.0
var _leave_tombstones: Dictionary = {}

func _make_request_id() -> String:
	return _crypto.generate_random_bytes(8).hex_encode()

# --- 交易幂等：客户端侧（状态信封 E4）----------------------------------------
# 服务端负责"同一个 request_id 不重复执行"，客户端负责另外两件事：
#   1. **请求丢了要重发** —— 而且必须重发**同一个** request_id，否则服务端当新单子。
#   2. **回复重复了要丢掉** —— 慢包和重发的回复都到了，不能加两次金币。
const TX_RETRY_SEC := 3.0
const TX_MAX_TRIES := 3
const TX_DONE_CAP := 64

var _tx_pending: Dictionary = {}   # rid -> {kind, args, deadline, tries}
var _tx_done: Array = []           # 已消费的 rid，FIFO 定长

func _tx_begin(kind: String, args: Array) -> String:
	var rid := _make_request_id()
	_tx_pending[rid] = {"kind": kind, "args": args, "deadline": _now() + TX_RETRY_SEC, "tries": 1}
	return rid

func _tx_send(rid: String) -> void:
	var p: Dictionary = _tx_pending.get(rid, {})
	if p.is_empty() or multiplayer.multiplayer_peer == null:
		return
	var args: Array = p.get("args", [])
	match str(p.get("kind", "")):
		"treasure_choice":
			_rpc_treasure_choice.rpc_id(1, rid, str(args[0]))
		"treasure_refresh":
			_rpc_treasure_refresh.rpc_id(1, rid)
		"altar":
			_rpc_altar_request.rpc_id(1, rid)
		"economy":
			_rpc_economy_intent.rpc_id(1, rid, str(args[0]), args[1] as Dictionary)

# 回复到达时调用。返回 false = 这份回复该丢掉（重复，或不是本机发的单子）。
func _tx_consume(rid: String) -> bool:
	if rid.is_empty():
		return true   # 兼容：服务端主动下发（非交易回复）不带 rid
	if _tx_done.has(rid):
		return false
	if not _tx_pending.has(rid):
		return false  # 不是本机在等的单子（换会话后的迟到包）
	_tx_pending.erase(rid)
	_tx_done.append(rid)
	while _tx_done.size() > TX_DONE_CAP:
		_tx_done.pop_front()
	return true

func _tick_tx_retry(_delta: float) -> void:
	if _tx_pending.is_empty():
		return
	if multiplayer.multiplayer_peer == null or state != SessionState.READY:
		return   # 断线/重连期间不重发；连回来之后由 deadline 自然续上
	var now := _now()
	for rid in _tx_pending.keys():
		var p: Dictionary = _tx_pending[rid]
		if now < float(p.get("deadline", 0.0)):
			continue
		if int(p.get("tries", 0)) >= TX_MAX_TRIES:
			# 放弃重发。**结果按"未知"处理，不是按"失败"**：服务端可能已经成功了。
			# 这里只把 UI 解锁（否则宝物弹窗会永远转圈），权威值由下一份
			# room_state 快照纠正 —— owned_treasures / altar_uses 都在里面。
			_net_log("tx gave up rid=%s kind=%s (result unknown, awaiting room_state)" % [
				rid, str(p.get("kind", ""))])
			_tx_pending.erase(rid)
			_tx_done.append(rid)
			match str(p.get("kind", "")):
				"altar":
					altar_result.emit(false, GameState.team_hp, -1)
				"economy":
					# 经济意图必须发 economy_receipt，不能落进下面的默认分支 ——
					# 那会让一次超时的萝卜交易弹出「宝物领取失败」，还顺手把宝物
					# 三选一的 pick_pending 锁给解了（PrepFlowController._on_treasure_denied）。
					# 形状与真回执一致，好让唯一的监听方 PrepUI._on_carrot_economy_receipt
					# 直接走它现成的 ok==false 分支。
					# revision 用 -1 作哨兵：这份是**本地伪造**的，不是服务端说的，
					# 将来客户端按 revision 拒收迟到回执时它必须不可能被当成权威。
					var timeout_args: Array = p.get("args", [])
					economy_receipt.emit({
						"ok": false,
						"error": "timeout",
						"action": str(timeout_args[0]) if not timeout_args.is_empty() else "",
						"gold_before": GameState.gold,
						"delta": 0,
						"gold_after": GameState.gold,
						"revision": -1,
						"result": {},
					})
				_:
					treasure_denied.emit("timeout")
			continue
		p["tries"] = int(p.get("tries", 0)) + 1
		p["deadline"] = now + TX_RETRY_SEC
		_tx_pending[rid] = p
		_net_log("tx retry rid=%s kind=%s try=%d" % [rid, str(p.get("kind", "")), int(p["tries"])])
		_tx_send(rid)

# 玩家**明确退出**。走 request_id + 幂等回执：**收到服务端确认才清凭证**。
# 先把 pending_leave 落盘再发包 —— 进程这时候被杀，下次启动能凭它知道
# "这局是主动退的，别再提示重连"。
func request_user_leave() -> void:
	# Leaving a started match disconnects the player, but keeps their seat resumable.
	if not is_host and bool(SaveManager.load_reconnect().get("match_started", false)):
		reset()
		return
	if not (team_active and not is_host and multiplayer.multiplayer_peer != null and not session_token.is_empty()):
		# 本地房主局 / 还没拿到凭证：没有需要服务端确认的东西，直接清场
		SaveManager.clear_reconnect()
		reset()
		return
	if _pending_leave_id.is_empty():
		_pending_leave_id = _make_request_id()
	SaveManager.mark_pending_leave(_pending_leave_id)
	_leave_deadline = _now() + LEAVE_RECEIPT_TIMEOUT_SEC
	_net_log("user leave intent id=%s" % _pending_leave_id)
	_rpc_leave_intent.rpc_id(1, _pending_leave_id)
	# **不在这里清 token、不关连接** —— 等回执。UI 那边已经导航走了，
	# 这段等待对玩家不可见；超时兜底见 _tick_pending_leave。

# **技术失败**：不发 leave、不清凭证，进可恢复状态。
func enter_recoverable_failure(reason: String) -> void:
	_net_log("recoverable failure: %s (class=%s)" % [reason, NetError.class_name_of(reason)])
	if not session_token.is_empty() and not reconnect_address.is_empty():
		_begin_reconnect(reason)
		return
	# 手里没有可恢复的凭证（本地房主局等）：只能回菜单，但**仍然不主动清凭证**
	last_error = reason
	state = SessionState.FAILED
	reset_peer_only()
	session_changed.emit()

func _tick_pending_leave(_delta: float) -> void:
	if _pending_leave_id.is_empty() or _leave_deadline <= 0.0:
		return
	if _now() < _leave_deadline:
		return
	# 回执没等到：清掉本地会话，但**磁盘上的 pending_leave 标记留着** ——
	# 下次连上服务器时会用同一个 request_id 重发，服务端按幂等重放同一份回执。
	_net_log("leave receipt timeout id=%s (marker kept for retry)" % _pending_leave_id)
	_leave_deadline = 0.0
	reset()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_leave_intent(request_id: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "leave_intent"):
		return
	if request_id.length() > MAX_TOKEN_LEN:
		return
	# 幂等：同一个 request_id 重发（回执丢了、客户端重启后重试）必须拿回**同一份**
	# 结果，而不是被当成新请求。tombstone 存在房间之外 —— 最后一人退出会立刻关房，
	# 而他仍然需要能重取回执。
	if _leave_tombstones.has(request_id):
		_rpc_leave_receipt.rpc_id(sender, request_id)
		return
	var room := _room_for_peer(sender)
	_leave_tombstones[request_id] = _now()
	if not room.is_empty():
		_apply_peer_leave(room, sender)
	_net_log("leave applied id=%s peer=%d" % [request_id, sender])
	_rpc_leave_receipt.rpc_id(sender, request_id)

@rpc("authority", "call_remote", "reliable")
func _rpc_leave_receipt(request_id: String) -> void:
	if request_id != _pending_leave_id:
		return
	_net_log("leave receipt confirmed id=%s -> clearing credentials" % request_id)
	_pending_leave_id = ""
	_leave_deadline = 0.0
	SaveManager.clear_reconnect()
	reset()

func disconnect_session() -> void:
	# 兼容入口：语义等同"玩家明确退出"。
	# 技术失败**不要**调这个，调 enter_recoverable_failure。
	request_user_leave()

func reset_peer_only() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null

func reset() -> void:
	team_seat_profiles.clear()
	reset_peer_only()
	_public_resume_pending = false
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
	# 信封位置和上面这几个是**同一类**的每会话状态，必须一起清。
	#
	# 2026-08-21 双设备实测撞出的真缺陷：建房 -> 离开 -> 再建房，UI 永远卡在
	# connecting。新房间的 state_seq 从 0 重新开始（RoomService.gd:160），而
	# server_epoch 是进程级的、客户端重连不会改变它；于是打完一局后
	# applied_seq 已经涨到 N，新房广播的 seq=1 就被 should_apply 当成迟到包丢掉，
	# 整份房间状态不被应用，team_local_slot 永远是 -1。
	#
	# 不能放到 _begin_reconnect 里：那条路径**故意不调 reset()**，因为中途重连
	# 需要保留 seq 位置来挡真正的迟到包。
	_match_state.reset_applied()
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
	_pending_ready = -1
	_reconnect_phase = ReconnectPhase.BACKOFF
	_reconnect_attempt = 0
	# 交易上下文属于**这一局**：换局之后旧 rid 再也不会有回执，留着只会一直重发。
	_tx_pending.clear()
	_tx_done.clear()
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
	# 第一次尝试立刻发起（瞬断要快速恢复），失败后才进指数退避。
	_reconnect_phase = ReconnectPhase.BACKOFF
	_reconnect_attempt = 0
	_reconnect_retry_left = 0.0
	_last_pong_at = 0.0
	session_changed.emit()

# --- 重连状态机（B10）--------------------------------------------------------
# 旧实现：RECONNECTING 期间每 3 秒无条件调一次 _attempt_reconnect，而它开头就
# reset_peer_only()。于是「已经连上、正在等 resume 回包」的连接会被下一次 tick
# 亲手拆掉 —— 服务器只要处理 resume 慢过 3 秒（同步算一场战斗就够了），客户端
# 就永远连不上，表现为无限重连。单纯给 3 秒加随机抖动解决不了这个：问题不是
# 间隔太整齐，是**等待期间不该重试**。
#
# 三个阶段：
#   BACKOFF        没有 peer，在等下一次尝试
#   CONNECTING     peer 已创建，等 ENet 握手
#   WAITING_RESUME 已连上、resume 已发出，等服务器回 _rpc_resume_state
# 只有 BACKOFF 会发起新连接；另外两个阶段只认「失败事件」或「整次尝试超时」。
enum ReconnectPhase { BACKOFF, CONNECTING, WAITING_RESUME }

# 退避算法搬到 scripts/multiplayer/ReconnectBackoff.gd（D1 第 5 刀）；常量重新导出。
const RECONNECT_ATTEMPT_TIMEOUT_SEC := ReconnectBackoff.ATTEMPT_TIMEOUT_SEC
const RECONNECT_BACKOFF_BASE_SEC := ReconnectBackoff.BACKOFF_BASE_SEC
const RECONNECT_BACKOFF_MAX_SEC := ReconnectBackoff.BACKOFF_MAX_SEC

var _reconnect_phase: int = ReconnectPhase.BACKOFF
var _reconnect_attempt := 0
var _reconnect_deadline := 0.0

func _tick_reconnect(delta: float) -> void:
	match _reconnect_phase:
		ReconnectPhase.BACKOFF:
			_reconnect_retry_left -= delta
			if _reconnect_retry_left <= 0.0:
				_begin_reconnect_attempt()
		_:
			# 握手中 / 等 resume 中：**绝不能拆**。只有整次尝试超时才放弃重来。
			if _now() >= _reconnect_deadline:
				_net_log("reconnect attempt %d timed out (phase=%d)" % [_reconnect_attempt, _reconnect_phase])
				_enter_reconnect_backoff()

func _begin_reconnect_attempt() -> void:
	reset_peer_only()
	var p := ENetMultiplayerPeer.new()
	if p.create_client(reconnect_address, remote_port) != OK:
		_enter_reconnect_backoff()
		return
	# DTLS（C14）。**第三个入口，最容易漏的一个** —— 漏了它的症状是"正常进房能连，
	# 断线重连永远连不上"，而重连路径本来就难复现。配不上按普通重连失败退避，
	# 不要在这里放弃凭证：这是传输层问题，不是凭证失效（见 NetError 的分级）。
	if NetworkConfig.USE_DTLS:
		var tls_err := NetTLS.apply_client(p)
		if not tls_err.is_empty():
			_net_log("DTLS client setup failed on reconnect: %s" % tls_err)
			_enter_reconnect_backoff()
			return
	_peer = p
	multiplayer.multiplayer_peer = _peer
	_reconnect_phase = ReconnectPhase.CONNECTING
	_reconnect_deadline = float(_reconnect_backoff.deadline_from(_now()))
	_net_log("reconnect attempt %d -> connecting" % _reconnect_attempt)

func _enter_reconnect_backoff() -> void:
	reset_peer_only()
	_reconnect_phase = ReconnectPhase.BACKOFF
	_reconnect_attempt += 1
	# capped exponential full jitter。固定间隔会让全服客户端同步重试，把刚解冻的
	# 服务器再打垮一次（服务器冻结时所有人同时判超时，波峰完全叠加）。
	var cap: float = _reconnect_backoff.cap_for_attempt(_reconnect_attempt)
	_reconnect_retry_left = float(_reconnect_backoff.wait_seconds(_reconnect_attempt))
	_net_log("reconnect backoff attempt=%d wait=%.1fs (cap=%.1f)" % [_reconnect_attempt, _reconnect_retry_left, cap])

# 玩家点"取消并返回主菜单"：放弃重连，彻底清场。
func cancel_reconnect() -> void:
	if not bool(SaveManager.load_reconnect().get("match_started", false)):
		SaveManager.clear_reconnect()
	reset()

# app 重开后凭本地存的 token 恢复对局（Main 在启动时调用）。
# port 必须由调用方传进来：座位 token 是**进程内**的，多进程下连错端口 = 凭证失效。
func begin_resume_from_disk(token: String, address: String, port: int = DEFAULT_PORT) -> void:
	reset()
	team_active = true
	session_token = token
	reconnect_address = address
	remote_address = address
	remote_port = port
	state = SessionState.RECONNECTING
	_reconnect_phase = ReconnectPhase.BACKOFF
	_reconnect_attempt = 0
	_reconnect_retry_left = 0.0
	session_changed.emit()

# 会话 token / 战斗 seed / 短码 一律走 Crypto，不再消费全局 RNG。
# 旧实现 "%d-%d-%d" % [ticks, randi(), randi()] 有两个问题：一是熵不足且可预测；
# 二是把两个连续的原始 randi() 输出直接交到每个玩家手里——而同一条全局 PCG32 流
# 还在给房间 id、shared_seed、宝物候选洗牌供数，拿到连续输出可做状态恢复。
var _crypto := Crypto.new()

func _make_token() -> String:
	return _reconnect_service.make_token()
# 短码给玩家手输，所以不能太长；用 base32 去掉易混字符（0/O/1/I），
# 10 位 × 32 符号 ≈ 2^50，配合限流与失败计数，在线枚举不再可行。
# 客户端上报的短码必须先过这里（A12）。此前 create/join 直接把客户端自报的
# public_id 当键写进 _public_token_seat，等于任何人都能：
#   ① 用别人的短码覆盖那条映射，把对方的重连凭证指向自己的座位；
#   ② 用一个超长字符串在服务器上留一条常驻内存条目。
# 返回 "" 表示"没有有效短码"，调用方按无短码处理（不是报错，老客户端本来就可能不带）。
# 注意：这只是格式与长度门。真正的修法是服务端签发 + 绑定（A12 完整版），
# 但那要改协议，归最终同步协议批。
func _sanitize_public_id(raw: String) -> String:
	return _reconnect_service.sanitize_public_id(raw)
const PUBLIC_TOKEN_ALPHABET := RoomService.PUBLIC_TOKEN_ALPHABET
const PUBLIC_TOKEN_LENGTH := RoomService.PUBLIC_TOKEN_LENGTH
const PUBLIC_TOKEN_MAX_TRIES := RoomService.PUBLIC_TOKEN_MAX_TRIES

func _make_public_token() -> String:
	return _reconnect_service.make_public_token()
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
	if not _active_match_for_token(str(_public_token_seat.get(_sanitize_public_id(public_id), ""))).is_empty():
		_rpc_team_action_failed.rpc_id(sender, ACTIVE_MATCH_HINT)
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
	_assign_peer_to_room(sender, _new_room(), _sanitize_public_id(public_id))

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_join_room(room_id: int, public_id: String = "") -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "join_room"):
		return
	if not _active_match_for_token(str(_public_token_seat.get(_sanitize_public_id(public_id), ""))).is_empty():
		_rpc_team_action_failed.rpc_id(sender, ACTIVE_MATCH_HINT)
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
	_assign_peer_to_room(sender, room, _sanitize_public_id(public_id))

@rpc("any_peer", "call_remote", "reliable")
func _rpc_public_resume_request(public_id: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _rate_ok(sender, "public_resume"):
		return
	var id := _sanitize_public_id(public_id)
	if id.is_empty():
		# 格式就不对，连查表都不必——但仍计一次 strike，短码枚举的失败必须有代价。
		_rate_ok(sender, "public_resume")
		_rpc_resume_failed.rpc_id(sender, "token_id_unknown")
		return
	var token := str(_public_token_seat.get(id, ""))
	if token.is_empty():
		# 猜错也计入 strike：短码枚举是可行的在线攻击面，失败次数必须有代价。
		_rate_ok(sender, "public_resume")
		_rpc_resume_failed.rpc_id(sender, "token_id_unknown")
		return
	public_token_id = id
	_resume_seat(sender, token)

# B9：心跳走**不可靠**通道。它是周期性的，丢一发下一发几秒后就到；
# 而"被一份 62 KB 的 replay 压在可靠队列后面"才是实际观测到的故障模式 ——
# 客户端量到心跳超时 → 重连 → 再收一份 replay，正反馈。
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_ping() -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	# 超频的 ping 直接丢弃，但仍然刷新 last_ping：对方确实在说话，只是说得太快。
	# 不刷新的话，一个 ping 太快的客户端会被心跳超时判定为掉线——那是拿自己人开刀。
	_peer_last_ping[sender] = _now()
	if not _rate_ok(sender, "ping", false):
		return
	_rpc_pong.rpc_id(sender)

@rpc("authority", "call_remote", "unreliable")
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

# --- 未入房连接的存活上限（A13）---------------------------------------------
# 连上来但一直不进房间的 peer，只要持续发 ping 就能永久占着一个连接槽 ——
# 心跳超时（20 秒）只踢"不说话"的，踢不掉"一直说话但什么也不干"的。
# TEAM_MAX_CLIENTS = 512，也就是 512 个这样的连接就能让正常玩家连不进来，
# 而这不需要任何账号、不需要进房间，成本极低。
#
# 正常玩家从连上到进房间只有几个 RPC 的往返（建房或加入），秒级完成。
# 60 秒是很宽松的余量，够覆盖弱网下的重试。
const UNJOINED_PEER_TTL_SEC := ConnectionHealth.UNJOINED_PEER_TTL_SEC

var _peer_connected_at: Dictionary = {}   # peer_id -> 连上的时刻（单调）

func _tick_leave_tombstones() -> void:
	var now := _now()
	for key in _leave_tombstones.keys():
		if now - float(_leave_tombstones[key]) >= LEAVE_TOMBSTONE_TTL_SEC:
			_leave_tombstones.erase(key)

func _tick_idle_peers() -> void:
	var now := _now()
	for peer_key in _peer_connected_at.keys():
		var pid := int(peer_key)
		# 已经进房间的不管：它由座位/心跳/僵尸清道夫那套负责。
		if _peer_room.has(pid):
			_peer_connected_at.erase(pid)
			continue
		if now - float(_peer_connected_at[pid]) < UNJOINED_PEER_TTL_SEC:
			continue
		_net_log("idle peer dropped peer=%d (no room after %ds)" % [pid, int(UNJOINED_PEER_TTL_SEC)])
		_peer_connected_at.erase(pid)
		# 同上：peer 可能已经自己断了，此时 disconnect_peer 会报 ERR_CONDITION 错误栈。
		if _peer_connected(pid):
			multiplayer.multiplayer_peer.disconnect_peer(pid)

# --- 房间快照的存与读（B5）---------------------------------------------------

# 房间落盘/读回已搬到 RoomService（save_snapshot / load_snapshot / snapshot_path）。
# 这三个保留为门面薄包装：内部调用点与 tools/persist_check_node.gd 都不用改。
func _snapshot_path() -> String:
	return _server_service.snapshot_path()

func _save_rooms_snapshot() -> void:
	_server_service.save_snapshot()

func _load_rooms_snapshot() -> void:
	_server_service.load_snapshot()

func _tick_heartbeat_timeouts() -> void:
	# 判定在 ConnectionHealth（纯函数、有用例）；断开留在这里（要碰 multiplayer）。
	var stale: Array = _conn_health.timed_out_peers(_peer_last_ping, _now())
	for peer_id in stale:
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
		_peer_connected_at.erase(pid)
		# 僵尸路径此前漏了这两条清理（_on_peer_disconnected 有做）：限流桶与 strike
		# 计数会永久留存，短码的 peer 映射也不会释放。
		_rate_forget(pid)
		_peer_public_token.erase(pid)
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
		# 同上：suspended 房间不启动新模拟（B11/R2）
		if bool(room.get("suspended", false)):
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
				boards[i] = _restamp_cached_board(room, i, last_board[i])
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
	# A9：直连入口自己限流。此前只有 _rpc_public_resume_request 有限流，客户端
	# 直接 rpc 这个方法就把 A6 的短码保护整套绕开了（枚举不现实，但纯刷 CPU +
	# journald 可行）。阈值与 public_resume 一致，给正常重连风暴留足余量。
	if not _rate_ok(sender, "resume"):
		return
	# token 是不可信字符串且被当作字典键。签发值是 64 个 hex 字符，超长一律拒。
	if token.length() > MAX_TOKEN_LEN:
		_net_log("resume failed reason=token_too_long peer=%d len=%d" % [sender, token.length()])
		_rpc_resume_failed.rpc_id(sender, "token_unknown")
		return
	_resume_seat(sender, token)

# 直连 resume 与短码 resume 的共同实现。
# 限流在两个 RPC 入口各做一次，这里不再重复计数（A9）——短码入口自己有
# public_resume 配额用于抗短码枚举，两者语义不同，不能互相顶替。
func _resume_seat(sender: int, token: String) -> void:
	_cleanup_rooms()
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
	if bool(room.get("run_over", false)):
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
		if int(peer_slot[pid]) != slot or int(pid) == sender:
			continue
		# 座位被别的 peer 占着。绝大多数情况下那是**这个玩家自己的旧半开连接**：
		# ENet 还没判死、清道夫还没跑到，新连接就已经带着同一个 token 回来了。
		# 持有同一个 token 就是同一个人 —— 直接把旧 peer 顶掉，让他接回来。
		if not _peer_connected(int(pid)):
			_net_log("resume evicting stale peer=%d room=%d slot=%d" % [int(pid), int(room.get("id", 0)), slot])
			peer_slot.erase(int(pid))
			room.peer_slot = peer_slot
			_peer_room.erase(int(pid))
			_peer_last_ping.erase(int(pid))
			break
		# 旧 peer 真的还活着：这是**可重试**的竞态，不是凭证失效。
		# 回 seat_busy（而不是 seat_taken），客户端据此保留 token 并退避重试。
		_net_log("resume busy room=%d slot=%d peer=%d holder=%d" % [int(room.get("id", 0)), slot, sender, int(pid)])
		_rpc_resume_failed.rpc_id(sender, "seat_busy")
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
	_reconnect_service.release_reservation(room, slot)
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
			boards_now[slot] = _restamp_cached_board(room, slot, lb[slot])
			room.boards = boards_now
			_net_log("resume auto-submit cached board room=%d round=%d slot=%d" % [int(room.get("id", 0)), int(room.get("round_index", 1)), slot])
	# E2：恢复用的和平时广播的**是同一份东西** —— room_state 全量快照。
	# 此前 resume_state 和 team_lobby 是两套各自维护的字段集，
	# "平时发一部分、重连发另一部分"正是 C5 那些缺字段的由来。
	# 这里的一次广播同时把快照发给全房（含刚回来的这个 peer）。
	_broadcast_room_lobby(room)
	# 本回合结果已算出（结算阶段）：补发该座位的 match_state 与回放。
	#
	# 已确认的产品规则：**重连回来的人应该补看那一场的回放**。
	# 改这里之前只发 match_state，注释写的是“客户端直接跳过战斗”——
	# 那是有意的，但产品上不对：掉线重连的人会直接看到结果，中间那场战斗没了。
	#
	# 顺序跟广播路径一致：match_state（几百字节、权威结算）必须排在 replay 之前，
	# 否则结算状态被压在大包后面，玩家卡在“战斗打完但结算不来”。
	if str(room.get("state", "")) == ROOM_RESULT:
		var ms: Dictionary = (room.get("last_match_state", {}) as Dictionary).get(slot, {})
		if not ms.is_empty():
			_rpc_receive_match_state.rpc_id(sender, ms)
		# 回放只存内存（不进快照），所以服务器重启过的话这里是空的，
		# 重连者仍只能看到结算结果——这是已知且接受的代价。
		var kept: Dictionary = room.get("replay_packed", {})
		if not kept.is_empty():
			var own: PackedByteArray = kept.get("a" if slot < 3 else "b", PackedByteArray())
			var rival: PackedByteArray = kept.get("b" if slot < 3 else "a", PackedByteArray())
			if own.size() > 0:
				_send_replay_to_peer(sender, str(room.get("battle_id", "")), own, rival)
				_net_log("resume replay resent room=%d round=%d slot=%d bytes=%d/%d" % [
					int(room.get("id", 0)), int(room.get("round_index", 1)), slot,
					own.size(), rival.size()])
	# 战斗阶段：上面可能刚替它补交了棋盘，凑齐就立即结算，别等下一个提交者
	elif str(room.get("state", "")) == ROOM_BATTLE:
		_room_try_finalize_boards(room)

# --- 状态信封 E2：房间权威状态的唯一入口 ------------------------------------
# 取代了原来的 team_lobby / team_leader / team_assign_slot / resume_state 四条。
#
# 应用规则（RFC 第六节）：
#   epoch 不同   -> 服务器重启过（或这是第一份），接受
#   seq 未前进   -> 迟到包，丢弃
#   否则         -> **整份替换**
#
# `else` 分支刻意不检查连号：全量快照跳号直接应用就是对的，
# 这就是不做 delta 换来的"漏包自愈"。服务器因此不需要保留任何状态历史。
# 实际持有者是 MatchStateService，这里保留原名转发。
var _applied_epoch: int:
	get:
		return _match_state.applied_epoch
	set(value):
		_match_state.applied_epoch = value
var _applied_seq: int:
	get:
		return _match_state.applied_seq
	set(value):
		_match_state.applied_seq = value

@rpc("authority", "call_remote", "reliable")
func _rpc_room_state(envelope: Dictionary) -> void:
	var epoch := int(envelope.get("server_epoch", 0))
	var seq := int(envelope.get("state_seq", 0))
	var payload: Dictionary = envelope.get("payload", {}) as Dictionary
	if payload.is_empty():
		return
	# 判定在 MatchStateService。它刻意与"提交"分开：下面还有别的检查
	# （重连期间不许覆盖手里的 token），那些失败时不能把已应用位置往前推。
	if not _match_state.should_apply(epoch, seq):
		# 正常对局中的迟到包不记 —— room_state 来得很频，无脑记会把日志刷爆。
		# 只记「还没进任何房间却在丢状态」这一种：那是唯一可疑的情形，
		# 也正是上面那个卡死缺陷的现场特征。本次排查花掉大量时间，
		# 直接原因就是这里一行日志都没有。
		if team_local_slot < 0:
			_net_log("room_state 丢弃：epoch=%d seq=%d（已应用 %d/%d）且尚未入房 —— 信封位置可能没重置" % [
				epoch, seq, _match_state.applied_epoch, _match_state.applied_seq])
		return   # 迟到包
	var incoming_token := str(payload.get("session_token", ""))
	# 重连握手期间，服务器可能先把我们当新玩家分进别的房间并签发新 token ——
	# 绝不能让它覆盖手里真正的重连凭证（旧 token 的座位还在等我们）。
	# 手里没 token 时（短码冷启动恢复）不设防，那条路径本来就是来拿 token 的。
	if state == SessionState.RECONNECTING and not session_token.is_empty() \
			and not incoming_token.is_empty() and incoming_token != session_token:
		_net_log("room_state ignored during resume (foreign token)")
		return

	var was_reconnecting := state == SessionState.RECONNECTING
	var was_public_resuming := _public_resume_pending
	_public_resume_pending = false
	_match_state.mark_applied(epoch, seq)
	_apply_carrot_state((payload.get("economy", {}) as Dictionary))
	_apply_server_shop((payload.get("economy", {}) as Dictionary))

	team_active = true
	team_room_id = int(envelope.get("room_id", 0))
	team_local_slot = int(payload.get("my_slot", -1))
	team_leader_slot = int(payload.get("leader_slot", 0))
	team_slot_states = (payload.get("slot_states", []) as Array).duplicate()
	team_seat_profiles = (payload.get("seat_profiles", {}) as Dictionary).duplicate(true)
	team_ready = (payload.get("ready", []) as Array).duplicate()
	server_round_index = int(payload.get("round_id", 0))
	server_phase = str(payload.get("phase", ""))
	# 服务器确认了在途的 ready 请求 -> 撤销本地意图（C24）
	if _pending_ready >= 0 and team_local_slot >= 0 and team_local_slot < team_ready.size():
		if bool(team_ready[team_local_slot]) == (_pending_ready == 1):
			_pending_ready = -1

	# 凭证：token 与短码都在快照里，落地并原子写盘（B14 + C21）
	if not incoming_token.is_empty() and incoming_token != session_token:
		session_token = incoming_token
		if reconnect_address.is_empty():
			reconnect_address = remote_address
		SaveManager.save_reconnect(session_token, reconnect_address, remote_port)
	if server_phase in [ROOM_PREP, ROOM_BATTLE, ROOM_RESULT] and not bool(payload.get("run_over", false)):
		SaveManager.mark_match_started()
	var incoming_public := str(payload.get("public_id", ""))
	if not incoming_public.is_empty() and incoming_public != public_token_id:
		public_token_id = incoming_public
		SaveManager.save_public_token(public_token_id)
		public_token_changed.emit(public_token_id)

	if state != SessionState.READY:
		state = SessionState.READY
		last_error = ""
	_reconnect_attempt = 0
	_reconnect_phase = ReconnectPhase.BACKOFF
	_last_pong_at = _now()
	session_changed.emit()
	team_lobby_changed.emit()
	# 只有"重连中收到的第一份"才算恢复完成 —— 否则每次广播都会让 Main 重新导航。
	if was_reconnecting:
		_net_log("resume completed via room_state: slot=%d phase=%s round=%d seq=%d" % [
			team_local_slot, server_phase, server_round_index, seq])
		resume_completed.emit(payload)
	elif was_public_resuming:
		_net_log("public resume completed via room_state: slot=%d phase=%s round=%d seq=%d" % [
			team_local_slot, server_phase, server_round_index, seq])
		resume_completed.emit(payload)

# 玩家开新游戏时放弃旧座位：旧房间还有其他在线玩家 -> 该座位转 AI(dummy)；
# 没人了就不管（空房间靠超时自清）。token 作废，之后连不回。
@rpc("any_peer", "call_remote", "reliable")
func _rpc_abandon_seat(token: String) -> void:
	if not _dedicated_server:
		return
	if not _active_match_for_token(token).is_empty():
		return
	var seat: Dictionary = _token_seat.get(token, {})
	if seat.is_empty():
		return
	var room: Dictionary = _rooms.get(int(seat.get("room_id", 0)), {})
	var slot := int(seat.get("slot", -1))
	_token_seat.erase(token)
	if room.is_empty() or slot < 0 or slot >= TEAM_SLOTS:
		return
	_clear_seat_metadata(room, slot)
	if _room_online_count(room) <= 0:
		# 房里没别人了：不转 AI，让空房间自然超时回收
		_net_log("seat abandoned room=%d slot=%d (room empty, will time out)" % [int(room.get("id", 0)), slot])
		return
	# 还有其他玩家：座位转 AI 顶上，并推进当前阶段
	_room_auto_complete_seat(room, slot)
	_net_log("seat abandoned room=%d slot=%d -> AI takeover" % [int(room.get("id", 0)), slot])

@rpc("authority", "call_remote", "reliable")
func _rpc_resume_failed(reason: String) -> void:
	_public_resume_pending = false
	# 分级表统一在 NetError（E1）。此前这里挂着一个两元素的硬编码数组，
	# 而别处的失败路径各判各的 —— 同一个错误码在不同地方待遇不一样。
	_net_log("resume failed reason=%s class=%s" % [reason, NetError.class_name_of(reason)])
	if not NetError.should_clear_credentials(reason) and state == SessionState.RECONNECTING:
		# 保留 token 与 team 上下文，退避后再来。
		_enter_reconnect_backoff()
		return
	# 终局原因（token_unknown / room_gone / match_over / bad_slot …）：凭证确实没用了。
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
				_peer_connected_at[id] = _now()   # A13：未入房存活上限的起算点
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
	_peer_connected_at.erase(id)
	_rate_forget(id)
	_replay_forget_peer(id)
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
	# 记录加入顺序（R5 leader 接任依据）。只在首次占座时分配；换位会搬走这个序号，
	# 持 token 重连沿用原座位因而自然保留 —— 「谁先进的房间」在整局内稳定。
	var seq_map: Dictionary = room.get("join_seq", {})
	if not seq_map.has(slot):
		seq_map[slot] = int(room.get("next_join_seq", 0))
		room.next_join_seq = int(room.get("next_join_seq", 0)) + 1
		room.join_seq = seq_map
	# 签发会话 token：断线重连的凭证（非账号，一局一换）
	var token := _make_token()
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	seat_tokens[slot] = token
	room.seat_tokens = seat_tokens
	_token_seat[token] = {"room_id": int(room.get("id", 0)), "slot": slot}
	if not public_id.is_empty():
		# 同一短码换座位时先清掉旧映射，避免 _public_token_seat 里留下指向已作废
		# token 的孤儿条目（短码空间会被这些死条目占满，见 _make_public_token）。
		_public_token_seat[public_id] = token
		_peer_public_token[peer_id] = public_id
		var seat_public: Dictionary = room.get("seat_public_id", {})
		seat_public[slot] = public_id
		room.seat_public_id = seat_public
	_touch_room(room)
	# 座位号、token、短码、房主全部走 room_state（E2），不再单独发 assign_slot。
	# 保留的遗留通道，仍要判连接：peer 可能在入座和这一行之间就掉了，
	# 对不存在的 peer 发包会刷 "unknown peer ID" 错误栈（真错误会被淹掉）。
	if _peer_connected(peer_id):
		_rpc_team_lobby.rpc_id(peer_id, states, ready)
	_net_log("player joined room=%d peer=%d slot=%d" % [int(room.get("id", 0)), peer_id, slot])
	# 若这个房间的房主已经走了（leader_slot 指向空/离线座位），让新加入的玩家接任，
	# 并向全房广播正确的房主（含刚加入的这个 peer）。避免"房间没房主"。
	_maybe_promote_leader(room)
	# 房主在 room_state 里，下面这次广播就带上了 —— 不再单发一条 team_leader（E2）
	_broadcast_room_lobby(room)

# --- 交易幂等回执（状态信封 E4）----------------------------------------------
# 宝物选择、宝物刷新、黄金祭坛这三笔都是**一次性、有副作用、不可重放**的操作。
# 此前它们是「发出去就不管」：请求丢了玩家白点一次，**回复丢了后果更糟** ——
#
#   宝物选择：offer 用后即弃 -> 重试落到 no_offer。服务端已经记了归属，
#             客户端却永远收不到，两边宝物列表从此不一致。
#   宝物刷新：重试会**再摇一次**并再进一次 refresh_index —— 玩家为一次刷新付两次钱，
#             而且第一次看到的候选再也拿不回来。
#   黄金祭坛：重试再扣 1 点全队 HP、再消耗一次机会，而金币只按收到的回复加 ——
#             等于付了两份代价拿一份收益。
#
# 解法和 leave receipt 同一套：**request_id + 存结果 + 重试重放同一份结果**。
# 服务端不重做，只把上次的答案再念一遍；客户端按 request_id 去重，重复回复直接丢。
#
# 边界：这解决的是**同一笔交易不被重复执行**，不是**金币账目本身可信**。
# 金币仍是客户端自报（A5/P1）。慷慨命运赌博现在完全在客户端，没有 RPC 可幂等化 ——
# 它归 P1 账本，届时**出生就带 request_id**，走的是下面这同一套信封。
# 随实现搬到 MatchStateService；这里重新导出，既有引用一处不用改。
const TX_LOG_PER_SLOT := MatchStateService.TX_LOG_PER_SLOT

# room.tx_log: slot -> Array[{rid, kind, result, at}]，FIFO 定长。
# 用数组而不是嵌套字典：定长裁剪是一行，且 var_to_bytes 往返干净。
func _tx_find(room: Dictionary, slot: int, rid: String) -> Dictionary:
	return _match_state.find_receipt(room, slot, rid)

func _tx_record(room: Dictionary, slot: int, rid: String, kind: String, result: Dictionary) -> void:
	_match_state.record_receipt(room, slot, rid, kind, result)

# 重放上一次的答案。**不重做任何副作用** —— 这正是幂等的全部含义。
func _tx_replay(sender: int, rid: String, entry: Dictionary) -> void:
	var result: Dictionary = entry.get("result", {})
	var ok := bool(result.get("ok", false))
	match str(entry.get("kind", "")):
		"treasure_choice":
			if ok:
				_rpc_treasure_granted.rpc_id(sender, rid, str(result.get("tid", "")), result.get("owned", []))
			else:
				_rpc_treasure_denied.rpc_id(sender, rid, str(result.get("reason", "denied")))
		"treasure_refresh":
			if ok:
				_rpc_treasure_offer.rpc_id(sender, rid, result.get("candidates", []), int(result.get("refresh_index", 0)))
			else:
				_rpc_treasure_denied.rpc_id(sender, rid, str(result.get("reason", "denied")))
		"altar":
			_rpc_altar_result.rpc_id(sender, rid, ok, int(result.get("team_hp", 0)), int(result.get("uses", 0)))
		"economy":
			# 经济回执整份存、整份重放。里面含随机结果（赌博开奖、刷新出的商品），
			# 重放时绝不能重算 —— 那正是"断线重连刷好结果"的入口。
			_rpc_economy_receipt.rpc_id(sender, rid, entry.get("result", {}))

# 三个 RPC 的公共入口校验：限流、rid 合法性、房间与座位、以及**幂等命中**。
# 返回 slot < 0 表示调用方应直接 return（要么已重放、要么已拒绝）。
func _tx_context(sender: int, rid: String, limit_key: String) -> Dictionary:
	if not _rate_ok(sender, limit_key):
		return {"slot": -1}
	if rid.is_empty() or rid.length() > MAX_TOKEN_LEN:
		return {"slot": -1}
	var room := _room_for_peer(sender)
	if room.is_empty():
		return {"slot": -1}
	var slot := int((room.get("peer_slot", {}) as Dictionary).get(sender, -1))
	if slot < 0 or slot >= TEAM_SLOTS:
		return {"slot": -1}
	var hit := _tx_find(room, slot, rid)
	if not hit.is_empty():
		_net_log("tx replay room=%d slot=%d rid=%s kind=%s" % [
			int(room.get("id", 0)), slot, rid, str(hit.get("kind", ""))])
		_tx_replay(sender, rid, hit)
		return {"slot": -1}
	return {"room": room, "slot": slot}

# --- P1 备战经济账本（服务端权威） -------------------------------------------
# 账本本体在 scripts/multiplayer/EconomyLedger.gd（纯函数、零全局，可单独测）。
# 这里只做三件事：取/建座位账本、把随机数摇好、把 intent 接进 E4 的幂等机制。
#
# **两段式上线**（见 ServerFlags）：`economy_ledger_enabled` 先只记账+影子比对，
# `economy_ledger_authoritative` 才让它成为唯一真相。后者必须等客户端改造完成。
const ECONOMY_ACTIONS := [
	"buy", "merge", "sell", "hire_merc", "shop_refresh", "gamble",
	"upgrade_harvest_tech", "hire_merc_carrot", "draw_upgrade_stone",
	"use_upgrade_stone",
]
const MAX_MERGE_UIDS := 4

func economy_enabled() -> bool:
	return ServerFlags.get_bool("economy_ledger_enabled")

func carrot_economy_enabled() -> bool:
	return ServerFlags.get_bool("carrot_economy_enabled")

func _economy_action_enabled(action: String) -> bool:
	return economy_enabled() or (carrot_economy_enabled() and action in [
		"upgrade_harvest_tech", "hire_merc_carrot", "draw_upgrade_stone",
		# 花的是队伍升级石不是金币，所以归萝卜链路，跟着 carrot_economy_enabled 走。
		"use_upgrade_stone",
	])

func economy_authoritative() -> bool:
	# 权威必须蕴含启用：只开后者是配置错误，按"没上线"处理，不是按"权威"处理。
	return economy_enabled() and ServerFlags.get_bool("economy_ledger_authoritative")

func _room_prep(room: Dictionary, slot: int) -> Dictionary:
	var preps: Dictionary = room.get("prep", {})
	if not preps.has(slot):
		preps[slot] = EconomyLedger.new_prep(GameState.START_GOLD)
		room["prep"] = preps
	return preps[slot]

func _room_team_stones(room: Dictionary, slot: int) -> Dictionary:
	var raw: Variant = room.get("team_upgrade_stones", [])
	var warehouses: Array = []
	if typeof(raw) == TYPE_ARRAY:
		warehouses = raw as Array
	elif typeof(raw) == TYPE_DICTIONARY:
		# The prototype stored one room-wide warehouse. Preserve old snapshots
		# while migrating them to one independent warehouse per side.
		var legacy := (raw as Dictionary).duplicate(true)
		warehouses = [legacy.duplicate(true), legacy.duplicate(true)]
	while warehouses.size() < 2:
		warehouses.append({"sky": 0, "land": 0, "ren": 0})
	for team_index in 2:
		if typeof(warehouses[team_index]) != TYPE_DICTIONARY:
			warehouses[team_index] = {"sky": 0, "land": 0, "ren": 0}
	room["team_upgrade_stones"] = warehouses
	return warehouses[GameConstants.team_of_slot(clampi(slot, 0, TEAM_SLOTS - 1))] as Dictionary

func _room_owned_for_ledger(room: Dictionary, slot: int) -> Array:
	# 账本按**服务端记录的**持有宝物算折扣，不按客户端自报 —— 否则伪造一件
	# money_discount 就能让服务端跟着按折扣价扣钱。
	return _room_owned_treasures(room, slot)

# 商店重摇：随机在这里、不在账本里。用 Crypto 而不是 randi()，
# 与 A4/A6 的其余随机源保持同一标准（客户端不能预测下一轮商品）。
# 取一个密码学安全的 [0,1)。商店内容是钱能买到的东西，
# 用 randf() 等于把刷新结果做成可预测的（种子来自系统时间）。
func _crypto_unit_float() -> float:
	return float(_crypto.generate_random_bytes(4).decode_u32(0)) / 4294967296.0

# 档位曲线与客户端共用 ShopRoll —— 这里原本是**全表均匀随机**，
# 没有任何档位概念，等于把成长曲线整条抹掉（第一回合 19% 刷三档单位）。
# 随机源仍然是 Crypto，只是「怎么摇」这条规则不再各写一份。
func _server_roll_shop_offers(count: int, round_index: int) -> Array:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var out: Array = []
	if units.is_empty():
		return out
	for _i in count:
		out.append(ShopRoll.pick_offer(units, round_index,
			_crypto_unit_float(), _crypto_unit_float()))
	return out

func _make_offer_id() -> String:
	return _crypto.generate_random_bytes(6).hex_encode()

# 把这次 intent 需要的随机数与外部输入一次备齐。
# 账本拿到的永远是**已经定好的**值 —— 重放回执时不会重摇（P1 / E4 的共同要求）。
func _economy_ctx(room: Dictionary, slot: int, action: String) -> Dictionary:
	var owned := _room_owned_for_ledger(room, slot)
	var ctx := {
		"owned_treasures": owned,
		"merc_table": DataRegistry.get_table("mercenaries").get("mercenaries", []),
		"roster_cap": GameConstants.CELL_COUNT + GameState.BENCH_SLOTS,
		"merc_cap": GameState.MERCENARY_SLOTS,
		"round_index": int(room.get("round_index", 1)),
		"team_stones": _room_team_stones(room, slot),
	}
	match action:
		"shop_refresh":
			ctx["rolled_offers"] = _server_roll_shop_offers(GameState.SHOP_UNIT_SLOTS,
				int(room.get("round_index", 1)))
			ctx["offer_id"] = _make_offer_id()
		"gamble":
			# 用 Crypto 取 [0,1)：randf() 的种子是可预测的，而这是钱。
			ctx["roll"] = _crypto_unit_float()
			# 联动 id 必须和数据表逐字一致。写错不会报错，只会**永远判成没联动** ——
			# 玩家花钱拿到的 60%/保留 50% 会静默退化成 50%/保留 20%。
			# （初版我凭印象写了 `link_lucky_fortune`，数据表里根本没这个 id。）
			ctx["gamble_linked"] = TreasureService.has_linkage_in(owned, "link_fraud_fate")
			# 赌博是「慷慨命运」这件宝物的能力 —— 没有它根本不该开奖。
			# 客户端有这道门（PrepFlowController:183），服务端此前没有。
			ctx["gamble_entitled"] = owned.has("money_generous_fate")
		"draw_upgrade_stone":
			# 开奖发生在服务端，且在幂等回执检查之后；重放只重发原结果。
			ctx["stone_roll"] = _crypto_unit_float()
		"use_upgrade_stone":
			# 属性（element）只认**服务端数据表**里的那一份，不认客户端自报 ——
			# 否则改个 element 就能拿天石升地属性的棋子。
			ctx["unit_table"] = DataRegistry.get_table("race_units").get("units", [])
	return ctx

func request_economy(action: String, payload: Dictionary) -> String:
	if not (team_active and not is_host and multiplayer.multiplayer_peer != null):
		return ""
	var rid := _tx_begin("economy", [action, payload])
	_tx_send(rid)
	return rid

@rpc("any_peer", "call_remote", "reliable")
func _rpc_economy_intent(request_id: String, action: String, payload: Dictionary) -> void:
	if not _dedicated_server or not _economy_action_enabled(action):
		return
	var sender := multiplayer.get_remote_sender_id()
	# 幂等、限流、房间与座位校验全部复用 E4 那一套：
	# **先查回执再执行**（RFC 里最容易写反的一处 —— 反过来的话"执行成功但回执丢了"
	# 的重试会被 revision 判成 stale 而拒绝，玩家钱扣了东西没拿到）。
	var ctx0 := _tx_context(sender, request_id, "economy")
	var slot := int(ctx0.get("slot", -1))
	if slot < 0:
		return
	var room: Dictionary = ctx0["room"]
	var receipt := _room_apply_economy(room, slot, action, payload)
	receipt["action"] = action
	_tx_record(room, slot, request_id, "economy", receipt)
	_rpc_economy_receipt.rpc_id(sender, request_id, receipt)
	if bool(receipt.get("ok", false)):
		_touch_room(room)

func _room_apply_economy(room: Dictionary, slot: int, action: String, payload: Dictionary) -> Dictionary:
	if not ECONOMY_ACTIONS.has(action):
		return _economy_reject(room, slot, "unknown_action")
	# 经济操作只在备战阶段有效。战斗/结算阶段还能买卖，等于让人在结算跑的同时改棋盘。
	if str(room.get("state", ROOM_LOBBY)) != ROOM_PREP:
		return _economy_reject(room, slot, "bad_phase")
	if action == "merge" and (payload.get("uids", []) as Array).size() > MAX_MERGE_UIDS:
		return _economy_reject(room, slot, "bad_request")
	var prep := _room_prep(room, slot)
	var gold_before_sync := int(prep.get("gold", 0))
	if action == "upgrade_harvest_tech" and not economy_authoritative():
		# 未启用金币权威时，买卖仍由客户端结算（与战后 snapshot.gold 同源）。
		# 影子账本可能缺少旧棋子的卖出记录，不能用它或上轮余额否定卖棋收入。
		# 权威模式则完全忽略自报金币，继续由服务端账本判定。
		if typeof(payload.get("gold")) != TYPE_INT:
			return _economy_reject(room, slot, "gold_desync")
		var reported_gold := int(payload.get("gold", -1))
		if reported_gold < 0:
			return _economy_reject(room, slot, "gold_desync")
		prep["gold"] = reported_gold
	var receipt := EconomyLedger.apply(prep, action, payload, _economy_ctx(room, slot, action))
	receipt["action"] = action
	if bool(receipt.get("ok", false)):
		# carrot-only rollout still exposes slot_gold in the room snapshot. Keep
		# the mirror current when harvest tech spends gold so a later full state
		# cannot restore the pre-upgrade balance.
		var slot_gold: Array = room.get("slot_gold", [])
		if slot >= 0 and slot < slot_gold.size():
			slot_gold[slot] = int(receipt.get("gold_after", slot_gold[slot]))
			room["slot_gold"] = slot_gold
		_net_log("economy room=%d slot=%d %s delta=%d gold=%d rev=%d" % [
			int(room.get("id", 0)), slot, action,
			int(receipt.get("delta", 0)), int(receipt.get("gold_after", 0)),
			int(receipt.get("revision", 0))])
	else:
		# 失败的升级不应改变服务端余额（包括首回合锁定、满级、金币不足）。
		prep["gold"] = gold_before_sync
		_net_log("economy rejected room=%d slot=%d %s reason=%s" % [
			int(room.get("id", 0)), slot, action, str(receipt.get("error", ""))])
	return receipt

func _economy_reject(room: Dictionary, slot: int, reason: String) -> Dictionary:
	var prep := _room_prep(room, slot)
	var gold := int(prep.get("gold", 0))
	return {"ok": false, "error": reason, "action": "",
		"gold_before": gold, "delta": 0, "gold_after": gold,
		"revision": int(prep.get("revision", 0)), "result": {}}

@rpc("authority", "call_remote", "reliable")
func _rpc_economy_receipt(request_id: String, receipt: Dictionary) -> void:
	if not _tx_consume(request_id):
		return
	_apply_carrot_receipt(receipt)
	economy_receipt.emit(receipt)

signal economy_receipt(receipt: Dictionary)

# 服务端每回合摇好的商店。客户端以前完全不读它，自己用本机 RNG 另摇一份 ——
# 于是 EconomyLedger._buy 的 offer_id 校验必然 stale_offer，买入意图 100% 被拒，
# roster 永远是空的，账本也就永远记不成账。
var server_shop: Dictionary = {}

func _apply_server_shop(state: Dictionary) -> void:
	if state.is_empty():
		return
	var shop: Variant = state.get("shop", {})
	if typeof(shop) != TYPE_DICTIONARY:
		return
	if str((shop as Dictionary).get("offer_id", "")).is_empty():
		return
	server_shop = (shop as Dictionary).duplicate(true)


func _apply_carrot_state(state: Dictionary) -> void:
	if state.is_empty() or not bool(state.get("carrot_authoritative", false)):
		return
	GameState.carrots = maxi(0, int(state.get("carrots", GameState.carrots)))
	GameState.harvest_tech_level = clampi(int(state.get("harvest_tech_level", GameState.harvest_tech_level)), 0, CarrotEconomy.MAX_HARVEST_TECH_LEVEL)
	GameState.merc_carrots_spent_total = maxi(0, int(state.get("merc_carrots_spent_total", GameState.merc_carrots_spent_total)))
	GameState.last_harvest_round = int(state.get("last_harvest_round", GameState.last_harvest_round))
	last_carrot_harvest_gain = maxi(0, int(state.get("last_harvest_gain", 0)))
	GameState.stone_draw_used_round = int(state.get("stone_draw_used_round", GameState.stone_draw_used_round))
	var stones: Variant = state.get("team_upgrade_stones", {})
	if typeof(stones) == TYPE_DICTIONARY:
		GameState.team_upgrade_stones = (stones as Dictionary).duplicate(true)
	SaveManager.save_run()

func _apply_carrot_receipt(receipt: Dictionary) -> void:
	var action := str(receipt.get("action", ""))
	var result: Dictionary = receipt.get("result", {})
	if not bool(receipt.get("ok", false)):
		return
	match action:
		"upgrade_harvest_tech":
			GameState.gold = int(receipt.get("gold_after", GameState.gold))
			GameState.harvest_tech_level = int(result.get("harvest_tech_level", GameState.harvest_tech_level))
		"hire_merc_carrot":
			GameState.carrots = int(result.get("carrots", GameState.carrots))
			GameState.merc_carrots_spent_total = int(result.get("merc_carrots_spent_total", GameState.merc_carrots_spent_total))
			_apply_remote_mercenary(result)
		"draw_upgrade_stone":
			GameState.carrots = int(result.get("carrots", GameState.carrots))
			GameState.stone_draw_used_round = int(result.get("stone_draw_used_round", GameState.stone_draw_used_round))
			var stones: Variant = result.get("team_upgrade_stones", {})
			if typeof(stones) == TYPE_DICTIONARY:
				GameState.team_upgrade_stones = (stones as Dictionary).duplicate(true)
		"use_upgrade_stone":
			# 按 uid 找那一枚棋子 —— 不按格子号：从发出意图到回执回来，玩家可能已经
			# 把它拖到别的格子、或者棋盘被服务端快照覆盖过。
			_apply_four_star_to_uid(str(result.get("uid", "")))
			var stones_after: Variant = result.get("team_upgrade_stones", {})
			if typeof(stones_after) == TYPE_DICTIONARY:
				GameState.team_upgrade_stones = (stones_after as Dictionary).duplicate(true)
	SaveManager.save_run()

func _apply_four_star_to_uid(uid: String) -> void:
	if uid.is_empty():
		return
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for index in (slots as Array).size():
			var cell: Variant = (slots as Array)[index]
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			if str((cell as Dictionary).get("uid", "")) != uid:
				continue
			(cell as Dictionary)["star"] = GameState.MAX_UNIT_STAR
			return

func _apply_remote_mercenary(result: Dictionary) -> void:
	var slot := int(result.get("merc_slot", -1))
	var unit_id := str(result.get("unit_id", ""))
	if slot < 0 or slot >= GameState.mercenary_slots.size() or unit_id.is_empty():
		return
	if GameState.mercenary_slots[slot] != null:
		return
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	for row_value in mercs:
		var row: Dictionary = row_value
		if str(row.get("id", "")) == unit_id:
			var def := row.duplicate(true)
			def["is_mercenary"] = true
			GameState.mercenary_slots[slot] = {"id": unit_id, "uid": str(result.get("uid", GameState.mint_piece_uid())), "star": 1, "def": def, "is_mercenary": true}
			return

# 影子比对：客户端自报的钱 vs 账本记的钱。
# 这是 authoritative 开关能不能开的**唯一依据** —— 影子期零差异之前不许翻。
func _shadow_audit_economy(room: Dictionary, slot: int, reported_gold: int) -> void:
	if not economy_enabled():
		return
	var prep := _room_prep(room, slot)
	var ledger_gold := int(prep.get("gold", 0))
	if ledger_gold == reported_gold:
		return
	_net_log("shadow economy_gold room=%d round=%d slot=%d client=%d ledger=%d diff=%d rev=%d" % [
		int(room.get("id", 0)), int(room.get("round_index", 1)), slot,
		reported_gold, ledger_gold, reported_gold - ledger_gold, int(prep.get("revision", 0))])

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
		_tx_send(_tx_begin("altar", []))

@rpc("any_peer", "call_remote", "reliable")
func _rpc_altar_request(request_id: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var ctx := _tx_context(sender, request_id, "altar")
	var slot := int(ctx.get("slot", -1))
	if slot < 0:
		return
	var room: Dictionary = ctx["room"]
	var result := _room_apply_altar(room, slot)
	_tx_record(room, slot, request_id, "altar", result)
	_rpc_altar_result.rpc_id(sender, request_id,
		bool(result.get("ok", false)), int(result.get("team_hp", 0)), int(result.get("uses", 0)))
	if not bool(result.get("ok", false)):
		return
	# 同队其他人也要看到共享法阵 HP 的变化（祭坛扣的是全队 HP）。
	var team := 0 if slot < 3 else 1
	var hp := int(result.get("team_hp", 0))
	for peer_id in (room.get("peer_slot", {}) as Dictionary).keys():
		var other_slot := int((room.get("peer_slot", {}) as Dictionary)[peer_id])
		if int(peer_id) == sender or not _peer_connected(int(peer_id)):
			continue
		if (0 if other_slot < 3 else 1) == team:
			_rpc_altar_team_hp.rpc_id(int(peer_id), hp)

# 裁决与 RPC 分开（和本文件其余 _rpc_X → _room_X 的分层一致）：对抗台能直接驱动，
# 且返回值就是要存进 tx_log 的那份结果 —— 重放时不必再走一遍判断。
func _room_apply_altar(room: Dictionary, slot: int) -> Dictionary:
	# 只在备战阶段可用：战斗/结算阶段改 HP 会和正在进行的结算打架。
	if str(room.get("state", ROOM_LOBBY)) != ROOM_PREP:
		return {"ok": false, "team_hp": 0, "uses": 0, "reason": "bad_phase"}
	var uses_map: Dictionary = room.get("altar_uses", {})
	var used := int(uses_map.get(slot, 0))
	var team := 0 if slot < 3 else 1
	var hp_arr: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	var hp := int(hp_arr[team])
	if used >= ALTAR_MAX_USES_PER_ROUND or hp <= ALTAR_MIN_HP:
		return {"ok": false, "team_hp": hp, "uses": used, "reason": "exhausted"}
	hp -= 1
	hp_arr[team] = hp
	room.team_hp = hp_arr
	uses_map[slot] = used + 1
	room.altar_uses = uses_map
	_touch_room(room)
	# 金币记进账本（P1）。HP 和次数上限归房间管（那是共享状态），
	# 账本只负责"这 50 金进了谁的口袋"。
	if economy_enabled():
		EconomyLedger.apply(_room_prep(room, slot), "altar_grant", {}, {"altar_gold": ALTAR_GOLD})
	_net_log("altar granted room=%d slot=%d team=%d hp=%d uses=%d" % [
		int(room.get("id", 0)), slot, team, hp, used + 1])
	return {"ok": true, "team_hp": hp, "uses": used + 1, "reason": ""}

@rpc("authority", "call_remote", "reliable")
func _rpc_altar_result(request_id: String, granted: bool, team_hp: int, uses: int) -> void:
	if not _tx_consume(request_id):
		return
	altar_result.emit(granted, team_hp, uses)

# 队友用了祭坛：只同步共享 HP，不给金币。
@rpc("authority", "call_remote", "reliable")
func _rpc_altar_team_hp(team_hp: int) -> void:
	GameState.team_hp = team_hp
	altar_result.emit(false, team_hp, -1)

# --- 宝物归属（服务端 intent，A5/A10 的一部分）--------------------------------
# 服务端本来就在 _server_pending_treasure 里用 Crypto 摇候选并随 match_state 下发，
# 只是从不记录玩家最终选了哪个——于是「你拥有哪些宝物」仍然 100% 是客户端自报。
# 这一组 RPC 把闭环补上：只能选服务器发过的候选，选完记进 room.owned_treasures。
#
# 边界（不要高估这组改动买到了什么）：
# - 它建立的是**归属**，不是**代价**。刷新要花的金币仍由客户端自己扣，因为金币本身
#   还没有权威账本（A5/P1）。刷新次数服务端记，钱不记。
# - room.owned_treasures 目前只用于「发候选时算 owned」和影子比对。战斗与经济结算
#   仍读 snapshot.treasures（客户端自报）。切换成以服务端记录为准要等影子期零差异，
#   否则一次口径不一致就会把诚实玩家的宝物吞掉。
signal treasure_offer_changed(candidates: Array, refresh_index: int)
signal treasure_granted(tid: String, owned: Array)
signal treasure_denied(reason: String)

func request_treasure_choice(tid: String) -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_tx_send(_tx_begin("treasure_choice", [tid]))

func request_treasure_refresh() -> void:
	if team_active and multiplayer.multiplayer_peer != null:
		_tx_send(_tx_begin("treasure_refresh", []))

# 服务端侧取「这个座位当前的 offer」。房间与座位已由 _tx_context 校验过，
# 这里只管 offer 存不存在。返回 {} 表示调用方应直接 return。
func _treasure_offer_of(room: Dictionary, slot: int, action: String) -> Dictionary:
	var offers: Dictionary = room.get("treasure_offer", {})
	var offer = offers.get(slot)
	if typeof(offer) != TYPE_DICTIONARY:
		_net_log("treasure %s rejected room=%d slot=%d reason=no_offer" % [
			action, int(room.get("id", 0)), slot])
		return {}
	return {"offers": offers, "offer": offer as Dictionary}

@rpc("any_peer", "call_remote", "reliable")
func _rpc_treasure_choice(request_id: String, tid: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var ctx := _tx_context(sender, request_id, "treasure_choice")
	var slot := int(ctx.get("slot", -1))
	if slot < 0:
		return
	var room: Dictionary = ctx["room"]
	var outcome := _room_apply_treasure_choice(room, slot, tid)
	# 成功要连 tid 和 owned 一起存 —— 重放时要还原的是**这一份**答案，
	# 不是"再算一次现在的 owned"（那时 offer 已经没了，只会算出拒绝）。
	if bool(outcome.get("ok", false)):
		outcome["tid"] = tid
	_tx_record(room, slot, request_id, "treasure_choice", outcome)
	if not bool(outcome.get("ok", false)):
		_rpc_treasure_denied.rpc_id(sender, request_id, str(outcome.get("reason", "denied")))
		return
	_rpc_treasure_granted.rpc_id(sender, request_id, tid, outcome.get("owned", []))

# 选择裁决与 RPC 分开（和本文件其余 _rpc_X → _room_X 的分层一致），
# 这样对抗测试台能直接驱动裁决逻辑，不必伪造 remote sender id。
func _room_apply_treasure_choice(room: Dictionary, slot: int, tid: String) -> Dictionary:
	# 长度门放在最前面：tid 是完全不可信的客户端字符串，在做任何比较、拼接或写日志
	# 之前就要挡掉。宝物 id 来自数据表，实际长度都在 32 以内，这个上限不会误伤。
	# 超限时连 _log_safe 都不调用完整值——只记长度。
	if tid.length() > MAX_TREASURE_ID_LEN:
		_net_log("treasure choice rejected room=%d slot=%d reason=tid_too_long len=%d" % [
			int(room.get("id", 0)), slot, tid.length()])
		return {"ok": false, "reason": "bad_request"}
	var offers: Dictionary = room.get("treasure_offer", {})
	var offer_value = offers.get(slot)
	if typeof(offer_value) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "no_offer"}
	var offer: Dictionary = offer_value
	# 整条链的门：只能选服务器这一轮实际发给这个座位的候选。
	if not (offer.get("candidates", []) as Array).has(tid):
		_net_log("treasure choice rejected room=%d round=%d slot=%d tid=%s reason=not_offered" % [
			int(room.get("id", 0)), int(offer.get("round", 0)), slot, _log_safe(tid)])
		return {"ok": false, "reason": "not_offered"}
	var owned := _room_owned_treasures(room, slot)
	if owned.has(tid) or owned.size() >= TreasureService.MAX_OWNED:
		return {"ok": false, "reason": "cannot_own"}
	owned = owned.duplicate()
	owned.append(tid)
	var owned_map: Dictionary = room.get("owned_treasures", {})
	owned_map[slot] = owned
	room.owned_treasures = owned_map
	# offer 用后即弃：同一轮不能再选第二件，重复请求会落到 no_offer。
	offers.erase(slot)
	room.treasure_offer = offers
	_touch_room(room)
	_net_log("treasure granted room=%d round=%d slot=%d tid=%s owned=%d" % [
		int(room.get("id", 0)), int(offer.get("round", 0)), slot, tid, owned.size()])
	return {"ok": true, "reason": "", "owned": owned}

@rpc("any_peer", "call_remote", "reliable")
func _rpc_treasure_refresh(request_id: String) -> void:
	if not _dedicated_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var ctx := _tx_context(sender, request_id, "treasure_refresh")
	var slot := int(ctx.get("slot", -1))
	if slot < 0:
		return
	var room: Dictionary = ctx["room"]
	var outcome := _room_apply_treasure_refresh(room, slot)
	_tx_record(room, slot, request_id, "treasure_refresh", outcome)
	if not bool(outcome.get("ok", false)):
		_rpc_treasure_denied.rpc_id(sender, request_id, str(outcome.get("reason", "denied")))
		return
	_rpc_treasure_offer.rpc_id(sender, request_id,
		outcome.get("candidates", []), int(outcome.get("refresh_index", 0)))

func _room_apply_treasure_refresh(room: Dictionary, slot: int) -> Dictionary:
	var oc := _treasure_offer_of(room, slot, "refresh")
	if oc.is_empty():
		return {"ok": false, "reason": "no_offer"}
	var offer: Dictionary = oc["offer"]
	var owned := _room_owned_treasures(room, slot)
	var candidates := _server_roll_treasure_candidates(owned, 3)
	if candidates.is_empty():
		return {"ok": false, "reason": "pool_empty"}
	var next_index := int(offer.get("refresh_index", 0)) + 1
	# 刷新费用记进账本（P1）。**先扣钱再重摇** —— 钱不够就整笔不做，
	# 否则会出现"候选换了但没收费"的免费刷新（正是 4.6 里保留着的那个洞）。
	if economy_enabled():
		var paid := EconomyLedger.apply(_room_prep(room, slot), "treasure_refresh_cost",
			{"refresh_index": int(offer.get("refresh_index", 0))},
			{"owned_treasures": owned})
		if not bool(paid.get("ok", false)):
			return {"ok": false, "reason": str(paid.get("error", "not_enough_gold"))}
	var offers: Dictionary = oc["offers"]
	offers[slot] = {
		"round": int(offer.get("round", 0)),
		"candidates": candidates.duplicate(),
		"refresh_index": next_index,
	}
	room.treasure_offer = offers
	_touch_room(room)
	_net_log("treasure refreshed room=%d slot=%d index=%d" % [int(room.get("id", 0)), slot, next_index])
	return {"ok": true, "reason": "", "candidates": candidates, "refresh_index": next_index}

@rpc("authority", "call_remote", "reliable")
func _rpc_treasure_offer(request_id: String, candidates: Array, refresh_index: int) -> void:
	if not _tx_consume(request_id):
		return
	treasure_offer_changed.emit(candidates, refresh_index)

@rpc("authority", "call_remote", "reliable")
func _rpc_treasure_granted(request_id: String, tid: String, owned: Array) -> void:
	if not _tx_consume(request_id):
		return
	treasure_granted.emit(tid, owned)

@rpc("authority", "call_remote", "reliable")
func _rpc_treasure_denied(request_id: String, reason: String) -> void:
	if not _tx_consume(request_id):
		return
	_net_log("treasure denied reason=%s" % reason)
	treasure_denied.emit(reason)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_team_leave() -> void:
	if not _dedicated_server:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var room := _room_for_peer(peer_id)
	if room.is_empty():
		return
	_apply_peer_leave(room, peer_id)

# 离场的实际处理，供 `_rpc_team_leave`（遗留）与 `_rpc_leave_intent`（E3）共用。
func _apply_peer_leave(room: Dictionary, peer_id: int) -> void:
	# Lobby leaves release the seat; started-match leaves preserve it for resuming.
	if str(room.get("state", ROOM_LOBBY)) == ROOM_LOBBY:
		_room_remove_peer(room, peer_id)
		return
	_room_reserve_peer(room, peer_id)

func _room_remove_peer(room: Dictionary, peer_id: int) -> void:
	# 硬移除（大厅掉线/主动离开/被踢）：座位彻底释放，token 作废。
	var peer_slot: Dictionary = room.get("peer_slot", {})
	var slot := int(peer_slot.get(peer_id, -1))
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	if slot >= 0 and slot < TEAM_SLOTS:
		states[slot] = "empty"
		ready[slot] = false
		# 座位彻底释放：token、短码绑定、加入顺序、对局进度一起清。
		# 只清一部分就会让后来坐进这个位子的人继承前一个人的 join_seq 或宝物记录。
		_clear_seat_metadata(room, slot)
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
	# 宽限记账已搬到 ReconnectService.reserve_seat()。
	_reconnect_service.reserve_seat(room, slot)
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
	# R5：从在线真人中选 join_seq 最小者（最早加入），不是最小 slot。
	# 旧实现按 slot 顺延，而 slot 0–2 恒为 A 队 —— 等于每次房主失效都优先把管理权
	# 交给 A 队，是一条系统性的队伍偏置。缺 join_seq 的座位（旧房间/异常路径）
	# 退化为按 slot 排在所有正常序号之后，保证任何情况下都能选出房主。
	var seq_map: Dictionary = room.get("join_seq", {})
	var next_leader := -1
	var best_seq := 0
	for s in online_slots.keys():
		var slot_i := int(s)
		var seq := int(seq_map.get(slot_i, 1000000 + slot_i))
		if next_leader < 0 or seq < best_seq:
			next_leader = slot_i
			best_seq = seq
	if next_leader < 0:
		return
	room.leader_slot = next_leader
	_net_log("leader promoted room=%d slot=%d join_seq=%d" % [int(room.get("id", 0)), next_leader, best_seq])
	_broadcast_room_lobby(room)

# 遗留通道（同 _rpc_team_lobby）：专服路径的房主变更已经在 room_state 里。
# 保留是因为删 @rpc 方法会平移整套 RPC 的 wire ID —— 而本地房主路径还需要它。
@rpc("authority", "call_remote", "reliable")
func _rpc_team_leader(leader_slot: int) -> void:
	team_leader_slot = leader_slot
	team_lobby_changed.emit()

# 每秒扫描：宽限到期的保留座位 -> 替它完成当前阶段动作，回合不被卡住。
# 座位与 token 依旧保留——整局期间随时可重连回来（届时落到当前阶段）。
# 扫描策略已搬到 ReconnectService.tick_reserved_seats()（D1 第 4 刀第 4 步）。
# _room_auto_complete_seat 留在门面：它要改席位状态并广播出去。
func _tick_reserved_seats() -> void:
	_reconnect_service.tick_reserved_seats(_rooms, _room_auto_complete_seat)

# 方案乙：宽限到期 -> 座位转 AI(dummy)，其他玩家立刻面对真 AI、本回合不再卡。
# token 仍有效：A 之后按"游戏重连"回来，resume 会把 dummy 变回 player、A 从存档恢复棋盘。
func _room_auto_complete_seat(room: Dictionary, slot: int) -> void:
	# 状态变更已搬到 ReconnectService.apply_ai_takeover()。留在这里的是发消息与
	# 阶段推进：广播大厅、按当前阶段决定接下来做什么 —— 那些都要发 RPC。
	_reconnect_service.apply_ai_takeover(room, slot)
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
		# 进入 WAITING_RESUME：这之后到 deadline 之前，_tick_reconnect 不会碰这个 peer。
		_reconnect_phase = ReconnectPhase.WAITING_RESUME
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
		# 握手失败是明确的失败事件：立刻进退避，不用干等 attempt deadline。
		_enter_reconnect_backoff()
		return
	state = SessionState.FAILED
	last_error = tr("net_err_connect_failed")
	session_changed.emit()

func _on_server_disconnected() -> void:
	_net_log("server disconnected (enet-level)")
	# 已经在重连流程里又断了（握手成功后立刻被踢、或等 resume 期间连接死掉）：
	# _begin_reconnect 会因为 state 已是 RECONNECTING 而早退，所以这里要显式进退避，
	# 否则会白等一整个 attempt deadline。
	if state == SessionState.RECONNECTING:
		_enter_reconnect_backoff()
		return
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
		SaveManager.save_reconnect(session_token, reconnect_address, remote_port)
	team_lobby_changed.emit()

# 遗留通道：**只有本地房主调试路径**还在用（`_team_broadcast_lobby`）。
# 那条路径用的是扁平变量而不是 room 字典，没有 state_seq 可言。
# 专服路径已全部改走 `_rpc_room_state`（E2）——两者不会同时出现在一个会话里：
# 要么连的是专服（只收 room_state），要么是本地房主局（只收这条）。
# C17 的"只升不降"补丁随之删除：seq 已经在信封层解决了迟到包的问题。
@rpc("authority", "call_remote", "reliable")
func _rpc_team_lobby(states: Array, ready: Array, _server_round: int = 0, _server_phase_name: String = "") -> void:
	team_slot_states = states.duplicate()
	team_ready = ready.duplicate()
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
		# 只有"按下准备"才推进结算阶段（C7）。此前不看 value：客户端发一个
		# ready=false（取消准备）同样能把全房推进下一回合，别人还在看回放就被拽走。
		# 完整修法是每座位独立的 result_applied_ack + 阶段函数幂等，归 R6。
		if value and str(room.get("state", ROOM_LOBBY)) == ROOM_RESULT:
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
		if not _phase_allows(room, PHASE_LOBBY_ONLY, "start", sender):
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
