extends RefCounted

# D1 目标结构里的 DedicatedServerService：**端口 / 持久化**。
#
# 两件事看着不相干，放在一起是有理由的：它们都属于"这个服务器进程的生命周期"，
# 而不是任何一局对战的内容。
#
#   端口     这个进程该不该以专用服务器启动、监听哪个端口、是第几个分片
#   持久化   房间快照的落盘与读回，以及落盘的节奏
#
# 为什么快照归这里而不是 RoomService：`systemctl restart` 会杀掉进程内的全部房间
# 和 token，所有在场对局一起没。快照存在的唯一理由是**让进程重启不等于全场掉线**，
# 那是部署问题，不是房间问题。README 也把"持久化"划给了本服务。
#
# 依赖方向单向，不成环：
#   DedicatedServer -> RoomService（要存/读房间）
#   DedicatedServer -> ReconnectService（要存/读 token 索引）
#   Room -> Reconnect（索引）
# 反过来谁都不认识本服务。
#
# 与门面的分界（和其它服务一致）：本类是 RefCounted，够不着 multiplayer。
# create_server / 端口绑定留在门面，这里只回答"该不该起、用哪个端口、第几分片"。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。

const SNAPSHOT_PATH := "user://server_rooms.bin"
const SNAPSHOT_VERSION := 1
const SNAPSHOT_INTERVAL_SEC := 5.0

# 白名单：只有这些字段进快照。加字段时要显式想清楚它该不该持久化。
#
# **只存"恢复对局必需"的字段**。`boards` 和 `last_board` 是缓存类字段
# （每人一份含完整单位 def 的快照，一个房间就能到 MB 级），存它们会让快照
# 大两个数量级，而丢了最坏也只是看门狗转 AI —— 不值得。
const PERSISTED_ROOM_FIELDS := [
	"id", "state", "slot_states", "ready",
	"slot_gold", "team_hp", "pve_completed", "boss_completed", "team_loss_streak",
	"run_over", "last_match_state", "shared_seed", "round_index",
	"seat_tokens", "seat_public_id", "join_seq", "next_join_seq",
	"leader_slot", "altar_uses", "treasure_offer", "owned_treasures",
	"prep_mercs", "suspended",
	# state_seq 必须一起存（信封 E2）：重启后从 0 重来的话，客户端手里
	# 还留着重启前的号，会把新包当迟到包丢掉。epoch 变了是第二道防线，
	# 但两条都在才稳。
	"state_seq",
	# tx_log 必须一起存（信封 E4）：重启后客户端会重发还没拿到回执的交易，
	# 丢了回执日志就等于同一笔宝物/祭坛被执行两次。定长 16/座位，代价可忽略。
	"tx_log",
	# 账本必须持久化：它是"这个人还剩多少钱、买过什么"的唯一记录（P1）。
	# 丢了就只能拿客户端自报值重建 —— 那正是这套东西要消灭的东西。
	"prep",
]
# 时间字段一律存**相对量**，不存单调时钟的绝对值：单调时钟跨进程重启就归零，
# 存绝对值等于重启后所有 TTL 立刻到期或永不到期（见 C20 的说明）。
const PERSISTED_ELAPSED_FIELDS := ["last_activity_at", "state_started_at", "created_at", "empty_since"]

# 本进程负责的分片号（多进程扩容用）。0 = 单进程/第一个分片。
# 房间号会把它编进去，客户端据此知道该连哪个进程 —— 见 NetworkConfig 的说明。
var shard_index := 0
# 服务器代数：进程重启后 +1，客户端据此判断"服务器换过一轮了"。
var server_epoch := 0

var _rooms_service: RefCounted = null
var _tokens: RefCounted = null
var _now_fn: Callable = Callable()
var _wall_now_fn: Callable = Callable()
var _log_fn: Callable = Callable()
var _cfg: Dictionary = {}
var _snapshot_accum := 0.0


func configure(rooms_service: RefCounted, tokens: RefCounted,
		now_fn: Callable, wall_now_fn: Callable, log_fn: Callable, cfg: Dictionary) -> void:
	_rooms_service = rooms_service
	_tokens = tokens
	_now_fn = now_fn
	_wall_now_fn = wall_now_fn
	_log_fn = log_fn
	_cfg = cfg


func _time() -> float:
	if _now_fn.is_valid():
		return float(_now_fn.call())
	return float(Time.get_ticks_msec()) / 1000.0


func _wall_time() -> float:
	if _wall_now_fn.is_valid():
		return float(_wall_now_fn.call())
	return float(Time.get_unix_time_from_system())


func _log(message: String) -> void:
	if _log_fn.is_valid():
		_log_fn.call(message)


# --- 端口与启动判定 -----------------------------------------------------------

# 这个进程该不该以专用服务器启动。
#
# argv 由调用方传进来而不是直接读 OS：这样测试能确定性地喂各种命令行，
# 不必真的换一次进程参数。
static func should_boot(argv: PackedStringArray) -> bool:
	return "--server" in argv or "--dedicated-server" in argv


# 解析 `--key=value` 形式的命令行参数。
#
# 不用 OS.get_cmdline_user_args()：那个只认 `--` 之后的部分，而 systemd 单元里
# 直接写 `--server --shard=2` 更顺手，也和现有的 `--server` / `--flags=` 写法一致。
static func cmdline_int(argv: PackedStringArray, key: String, fallback: int) -> int:
	var prefix := key + "="
	for a in argv:
		var s := str(a)
		if s.begins_with(prefix):
			var raw := s.substr(prefix.length())
			if raw.is_valid_int():
				return int(raw)
			return fallback
	return fallback


# --- 快照路径与落盘节奏 -------------------------------------------------------

func snapshot_path() -> String:
	# 多进程时每个分片一份，否则互相覆盖
	return SNAPSHOT_PATH if shard_index == 0 else "%s.%d" % [SNAPSHOT_PATH, shard_index]


# 每帧调用。只在**有变更时**写，且限速。
#
# 全量序列化跑在同步主循环上，无脑每帧写就是给自己造一个新的冻结源
# （和 B4 特效预算同一类问题：不是单次贵，是频率没有上限）。
func tick_snapshot(delta: float) -> void:
	_snapshot_accum += delta
	if not bool(_rooms_service.rooms_dirty):
		return
	if _snapshot_accum < SNAPSHOT_INTERVAL_SEC:
		return
	_snapshot_accum = 0.0
	save_snapshot()


# --- 快照读写 -----------------------------------------------------------------

func save_snapshot() -> void:
	var now := _time()
	var out_rooms: Array = []
	var room_closed := str(_cfg.get("room_closed", "closed"))
	for room in _rooms_service.rooms.values():
		if str(room.get("state", "")) == room_closed:
			continue
		var entry: Dictionary = {}
		for key in PERSISTED_ROOM_FIELDS:
			if room.has(key):
				entry[key] = room[key]
		# 时间转相对量
		for key in PERSISTED_ELAPSED_FIELDS:
			var t := float(room.get(key, 0.0))
			entry["_elapsed_" + key] = (now - t) if t > 0.0 else -1.0
		# 座位宽限：存"还剩多久"
		var deadline: Dictionary = room.get("reserve_deadline", {})
		var remain: Dictionary = {}
		for slot in deadline.keys():
			remain[slot] = maxf(0.0, float(deadline[slot]) - now)
		entry["_reserve_remaining"] = remain
		out_rooms.append(entry)
	var payload := {
		"version": SNAPSHOT_VERSION,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"shard": shard_index,
		"server_epoch": server_epoch,
		"saved_at_wall": _wall_time(),
		"rooms": out_rooms,
		"token_seat": _tokens.token_seat,
		"public_token_seat": _tokens.public_token_seat,
	}
	if SaveManager.atomic_write_bytes(snapshot_path(), var_to_bytes(payload)):
		_rooms_service.rooms_dirty = false


func load_snapshot() -> void:
	var raw := SaveManager.read_bytes_with_fallback(snapshot_path())
	if raw.is_empty():
		return
	var value = bytes_to_var(raw)
	if typeof(value) != TYPE_DICTIONARY:
		_log("room snapshot unreadable, starting empty")
		return
	var payload: Dictionary = value
	# 版本或协议对不上就整份丢弃：宁可全场重开，也不能用一份语义可能已经变了的
	# 快照去恢复对局（那会产生谁也查不出来的错乱）。
	if int(payload.get("version", -1)) != SNAPSHOT_VERSION \
			or int(payload.get("protocol", -1)) != NetworkConfig.NETWORK_PROTOCOL_VERSION:
		_log("room snapshot discarded: version=%s protocol=%s (want %d/%d)" % [
			str(payload.get("version")), str(payload.get("protocol")),
			SNAPSHOT_VERSION, NetworkConfig.NETWORK_PROTOCOL_VERSION])
		SaveManager.remove_all_variants(snapshot_path())
		return

	var now := _time()
	var team_slots := int(_cfg.get("team_slots", 6))
	var room_result := str(_cfg.get("room_result", "result"))
	var reserve_grace := float(_cfg.get("reserve_grace_sec", 60.0))
	var restored := 0
	var dropped := 0
	for entry_value in (payload.get("rooms", []) as Array):
		if typeof(entry_value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_value
		var room: Dictionary = _rooms_service.new_room()
		_rooms_service.rooms.erase(int(room.id))   # new_room 摇了个新号，这里要用存档里的
		for key in PERSISTED_ROOM_FIELDS:
			if entry.has(key):
				room[key] = entry[key]
		# 时间基准重建：单调时钟重启后归零，所以用"已过去多久"倒推
		for key in PERSISTED_ELAPSED_FIELDS:
			var elapsed := float(entry.get("_elapsed_" + key, -1.0))
			room[key] = (now - elapsed) if elapsed >= 0.0 else 0.0
		# 崩在结算中途的房间无法重建（boards 不入快照），直接丢弃而不是留个死房间
		if str(room.get("state", "")) == room_result and (room.get("last_match_state", {}) as Dictionary).is_empty():
			dropped += 1
			continue
		# **所有 peer 状态一律清空**。存档里的 peer_id 重启后全部失效，
		# 留着会让房间以为一堆不存在的 peer 还在线，永远判不空、永远不回收。
		room.peer_slot = {}
		room.boards = {}
		room.last_board = {}
		room.suspended = false
		room.empty_since = now
		# 每个占着的座位都当成"刚掉线"：给一份完整宽限，等原主人带 token 回来。
		var reserved: Dictionary = {}
		var deadline: Dictionary = {}
		var states: Array = room.get("slot_states", [])
		for i in team_slots:
			if i < states.size() and str(states[i]) == "player":
				reserved[i] = {"reserved_at": now}
				deadline[i] = now + reserve_grace
		room.reserved = reserved
		room.reserve_deadline = deadline
		_rooms_service.rooms[int(room.id)] = room
		restored += 1

	var saved_tokens = payload.get("token_seat", {})
	if typeof(saved_tokens) == TYPE_DICTIONARY:
		_tokens.token_seat = saved_tokens
	var saved_public = payload.get("public_token_seat", {})
	if typeof(saved_public) == TYPE_DICTIONARY:
		_tokens.public_token_seat = saved_public
	_log("room snapshot restored: rooms=%d dropped=%d tokens=%d prev_epoch=%d new_epoch=%d" % [
		restored, dropped, _tokens.token_seat.size(), int(payload.get("server_epoch", 0)), server_epoch])
