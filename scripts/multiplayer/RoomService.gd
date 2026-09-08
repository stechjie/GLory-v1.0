extends RefCounted

# D1 第 4 刀：从 NetworkService 抽出的房间服务。
#
# 这一刀比前三刀大一个量级：37 个函数、约 1065 行，占整个文件的 25%。
# 因此分步进行，每步跑一次完整回归：
#   4-1 状态搬迁（7 个变量）—— 已完成
#   4-2 持久化 + 房间创建     —— 本步
#   4-3 room_* 基础操作、席位元数据、token 生成
#   4-4 生命周期乱麻（_process 相关、_assign_peer_to_room、_cleanup_rooms）
# 一次性搬 1065 行、只有函数级探针兜底，风险不可控。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。
#
# 命名约定：这里用不带下划线的公开名（rooms / peer_room / …），
# 门面 NetworkService 上保留**原来的下划线名**作为转发属性。
# 这样做的原因很实际：
#   * NetworkService 内部有 60 多处 `_rooms` / `_peer_room` 这样的引用
#   * tools/ 下三个探针另有 98 处直接访问 `NetworkService._rooms` 等内部状态，
#     而且是**读 + 原地写**（`NetworkService._peer_room[777] = int(room.id)`）
# 属性转发让这 150 多处一个都不用改，且共享同一份引用、不会出双份状态
# （PR2 已用一次性探针实测过原地改能穿透 getter）。
#
# 房间域的常量搬到这里、门面用 `const X := RoomService.X` 重新导出：
# `TEAM_SLOTS` 之类在门面内部有 43 处引用、外部还有若干，重新导出后一处都不用改。
# （该写法也用一次性探针验证过。）

# 房间持久化的常量与实现随 DedicatedServerService 搬走（见下方"持久化"分节）。

# --- 状态 ---------------------------------------------------------------------

# room_id -> room Dictionary
var rooms: Dictionary = {}
# peer_id -> room_id
var peer_room: Dictionary = {}
# token ↔ 座位的三份索引已按 README 字面搬到 ReconnectService（token/宽限/AI 接管）。
# 这里通过注入的服务读写，依赖方向单向 Room -> Reconnect，不成环。
# 用属性转发而不是逐处改调用：本文件有 12 处引用，转发之后一处都不用改，
# 且和门面对外的做法一致。
var _tokens: RefCounted = null
var token_seat: Dictionary:
	get:
		return _tokens.token_seat
	set(value):
		_tokens.token_seat = value
var public_token_seat: Dictionary:
	get:
		return _tokens.public_token_seat
	set(value):
		_tokens.public_token_seat = value
var peer_public_token: Dictionary:
	get:
		return _tokens.peer_public_token
	set(value):
		_tokens.peer_public_token = value
# 房间有改动、待落盘
var rooms_dirty := false
# 服务器代数：进程重启后 +1，客户端据此判断"服务器换过一轮了"
var server_epoch := 0

# --- 注入的依赖 ---------------------------------------------------------------
# 只注入**行为**（时钟/日志/分片号）。房间域常量在本文件里，门面重新导出；
# 而 TEAM_SLOTS / ROOM_LOBBY / ROOM_RESULT / RESERVE_GRACE_SEC 这几个
# 在门面里有 43/24/11/5 处引用、外部也有引用，留在门面、按配置传进来更省事。
var _now_fn: Callable = Callable()
var _wall_now_fn: Callable = Callable()
var _log_fn: Callable = Callable()
var _shard_index_fn: Callable = Callable()
var _cfg: Dictionary = {}


func configure(now_fn: Callable, wall_now_fn: Callable, log_fn: Callable,
		shard_index_fn: Callable, cfg: Dictionary, tokens: RefCounted = null) -> void:
	_tokens = tokens
	_now_fn = now_fn
	_wall_now_fn = wall_now_fn
	_log_fn = log_fn
	_shard_index_fn = shard_index_fn
	_cfg = cfg


# 清空全部房间状态。
#
# 注意：**当前仓库里没有任何地方调用它**（2026-08-21 全仓搜索确认）。注释说它
# 对应 NetworkService.reset() 里那几行，但 reset() 是**客户端会话重置**，
# 不该把服务端的房间一起抹掉，所以没接上大概率是对的。留着但标明现状，
# 免得下一个人以为 reset 会清房间。
func clear() -> void:
	rooms.clear()
	peer_room.clear()
	# token 索引归 ReconnectService，由门面在同一处调它的 clear_tokens()。
	# 这里不再顺手清：清别人的状态是"两处都要记得"的开始。
	rooms_dirty = false


# --- 房间创建 -----------------------------------------------------------------

func new_room() -> Dictionary:
	# 房间号把分片号编进去（多进程）。两个进程各自摇六位随机数，早晚会撞 ——
	# 撞了之后玩家输房间号加入，系统根本不知道该去哪个进程。
	# 加了偏移之后，房间号本身就是路由信息：NetworkConfig.shard_of_room() 能反解。
	var base := _shard_index() * NetworkConfig.SHARD_ID_STRIDE
	var id := base + randi_range(100000, 999999)
	while rooms.has(id):
		id = base + randi_range(100000, 999999)
	var now := _time()
	var team_slots := int(_cfg.get("team_slots", 6))
	var slot_gold := []
	slot_gold.resize(team_slots)
	slot_gold.fill(GameState.START_GOLD)
	var room := {
		"id": id,
		"state": str(_cfg.get("room_lobby", "lobby")),
		"slot_states": ["empty", "empty", "empty", "empty", "empty", "empty"],
		"ready": [false, false, false, false, false, false],
		"peer_slot": {},
		"boards": {},
		"slot_gold": slot_gold,
		# One shared warehouse per side (slots 0..2 and slots 3..5).
		"team_upgrade_stones": [
			{"sky": 0, "land": 0, "ren": 0},
			{"sky": 0, "land": 0, "ren": 0},
		],
		"team_hp": [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP],
		"pve_completed": 0,
		"boss_completed": 0,
		"team_loss_streak": [0, 0],
		"run_over": false,   # 服务端义：对局已结束（不再开新回合、不再可 resume）
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
		"tx_log": {},            # slot -> Array[交易回执]（E4 幂等，定长 TX_LOG_PER_SLOT）
		"prep": {},              # slot -> EconomyLedger 座位账本（P1）
		# --- 宝物归属（服务端权威）---
		# 服务端本来就在 _server_pending_treasure 里摇候选并下发，只是从不记录玩家选了
		# 哪个。记下来之后「这件宝物是不是服务器发给你的」就有了可信来源，不必等 P1
		# 备战账本。注意这解决的是归属，不是代价：刷新的金币消耗仍是客户端自报。
		"treasure_offer": {},    # slot -> {"round": int, "candidates": Array, "refresh_index": int}
		"owned_treasures": {},   # slot -> Array[String]（服务端认可的持有列表）
		# slot -> 该座位绑定的公开短码。存在房间里是为了让座位释放时能反查并清掉
		# public_token_seat —— 此前只有 peer_id -> 短码 的映射，peer 一断开就没了，
		# 短码条目从此无人认领，只增不减（见 A12）。
		"seat_public_id": {},
		# leader 接任顺序（R5）。按「最早成功加入者」而不是最小 slot：
		# slot 0–2 恒为 A 队，按最小 slot 顺延会让房主权系统性偏向 A 队。
		# 换位与持 token 重连都保留原序号，所以「谁先进的房间」在整局内稳定。
		"join_seq": {},          # slot -> int
		"next_join_seq": 0,
		# B11/R2：零在线真人但仍有有效 token 时进入 suspended。
		# suspended 房间不推进阶段、不启动新模拟、不进公开列表。
		"suspended": false,
		# 状态信封（E2）：本房权威状态的版本号，每次变更 +1。
		"state_seq": 0,
		# 结算确认（E3）：本场战斗的唯一标识，以及各座位的确认状态。
		"battle_id": "",
		"result_acks": {},      # slot -> 已确认的 battle_id
	}
	rooms[id] = room
	_log("room created id=%d protocol=%d" % [id, NetworkConfig.NETWORK_PROTOCOL_VERSION])
	return room


# --- 持久化 -------------------------------------------------------------------
# 快照的读写与落盘节奏已按原始 README 字面搬到 DedicatedServerService
#（"DedicatedServerService（端口/持久化）"）。持久化的理由是让进程重启不等于全场
# 掉线 —— 那是部署问题，不是房间问题。
#
# 本服务只保留 rooms_dirty 这个"有没有变更"的信号，由那边决定何时真的写盘。


# --- 注入依赖的取值 -----------------------------------------------------------

func _time() -> float:
	if _now_fn.is_valid():
		return float(_now_fn.call())
	return float(Time.get_ticks_msec()) / 1000.0


func _wall_time() -> float:
	if _wall_now_fn.is_valid():
		return float(_wall_now_fn.call())
	return float(Time.get_unix_time_from_system())


func _shard_index() -> int:
	if _shard_index_fn.is_valid():
		return int(_shard_index_fn.call())
	return 0


func _log(message: String) -> void:
	if _log_fn.is_valid():
		_log_fn.call(message)


# --- 席位元数据（纯数据操作，不发 RPC）---------------------------------------

# 一个座位上挂着好几份东西：会话 token、公开短码绑定、加入顺序、保留态、以及该
# 座位的对局进度。它们必须整组一起搬/一起清 —— 只动其中一部分，就会让后来坐进
# 这个位子的人继承前一个人的身份或进度。
const SEAT_SLOT_MAPS := [
	"seat_tokens", "seat_public_id", "join_seq",
	"reserved", "reserve_deadline",
	"treasure_offer", "owned_treasures", "altar_uses", "last_board", "boards",
	"tx_log",   # E4：座位没了，这个座位的交易回执也没有意义了
	"prep",     # P1：座位账本同理
]

# 短码给玩家手输，所以不能太长；用 base32 去掉易混字符（0/O/1/I），
# 10 位 × 32 符号 ≈ 2^50，配合限流与失败计数，在线枚举不再可行。
const PUBLIC_TOKEN_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const PUBLIC_TOKEN_LENGTH := 10
const PUBLIC_TOKEN_MAX_TRIES := 8

var _crypto := Crypto.new()


func room_for_peer(peer_id: int) -> Dictionary:
	var room_id := int(peer_room.get(peer_id, 0))
	return rooms.get(room_id, {})


func room_online_count(room: Dictionary) -> int:
	var count := 0
	var room_id := int(room.get("id", 0))
	var peer_slot: Dictionary = room.get("peer_slot", {})
	for peer_id in peer_slot.keys():
		if int(peer_room.get(int(peer_id), 0)) == room_id:
			count += 1
	return count


func room_live_token_count(room: Dictionary) -> int:
	var count := 0
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	var room_id := int(room.get("id", 0))
	for slot in seat_tokens.keys():
		var token := str(seat_tokens[slot])
		var seat: Dictionary = token_seat.get(token, {})
		if seat.is_empty():
			continue
		if int(seat.get("room_id", 0)) == room_id and int(seat.get("slot", -1)) == int(slot):
			count += 1
	return count


func move_seat_metadata(room: Dictionary, from_slot: int, to_slot: int) -> void:
	for map_name in SEAT_SLOT_MAPS:
		var m: Dictionary = room.get(map_name, {})
		if not m.has(from_slot):
			continue
		m[to_slot] = m[from_slot]
		m.erase(from_slot)
		room[map_name] = m
	# token -> seat 的反向索引也要改，否则这人重连会被放回旧槽位（队伍和身份色
	# 一起变回去）；旧槽位要是已经有人坐了，resume 直接判 seat_taken 连不回来。
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	if seat_tokens.has(to_slot):
		var token := str(seat_tokens[to_slot])
		var seat: Dictionary = token_seat.get(token, {})
		if not seat.is_empty():
			seat["slot"] = to_slot
			token_seat[token] = seat
	# 每席位金币按数组索引存，不在 SEAT_SLOT_MAPS 里，单独搬。
	# 换位目前只在 LOBBY 开放、各席位金币相同，但不能依赖这个巧合。
	var slot_gold: Array = room.get("slot_gold", [])
	if from_slot < slot_gold.size() and to_slot < slot_gold.size():
		slot_gold[to_slot] = slot_gold[from_slot]
		slot_gold[from_slot] = GameState.START_GOLD
		room.slot_gold = slot_gold


# 永久释放座位（主动离开 / 被踢 / 放弃 / 关房）。临时掉线绝不能调这个。
func clear_seat_metadata(room: Dictionary, slot: int) -> void:
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	if seat_tokens.has(slot):
		token_seat.erase(str(seat_tokens[slot]))
	# 必须在清 seat_public_id 之前调 —— 它要靠这份映射反查短码。
	release_seat_public_id(room, slot)
	for map_name in SEAT_SLOT_MAPS:
		var m: Dictionary = room.get(map_name, {})
		if m.has(slot):
			m.erase(slot)
			room[map_name] = m
	var slot_gold: Array = room.get("slot_gold", [])
	if slot < slot_gold.size():
		slot_gold[slot] = GameState.START_GOLD
		room.slot_gold = slot_gold


# 释放一个座位绑定的公开短码。
# compare-and-delete：只有当这条映射**仍指向本座位的 token** 时才删。
# 无条件删会在短码碰撞（同一 id 被另一个座位重新绑定）时，让先离开的人把后来者的
# 映射一起删掉 —— 那是拿一个泄漏换一个更难查的串号。
# 注意这只缓解误删，不解决"客户端自报短码可覆盖别人映射"（A12 完整版要服务端签发）。
func release_seat_public_id(room: Dictionary, slot: int) -> void:
	var seat_public: Dictionary = room.get("seat_public_id", {})
	if not seat_public.has(slot):
		return
	var id := str(seat_public[slot])
	var seat_tokens: Dictionary = room.get("seat_tokens", {})
	var my_token := str(seat_tokens.get(slot, ""))
	if not my_token.is_empty() and str(public_token_seat.get(id, "")) == my_token:
		public_token_seat.erase(id)
	seat_public.erase(slot)
	room.seat_public_id = seat_public


# --- token 生成 ---------------------------------------------------------------

func make_token() -> String:
	return _crypto.generate_random_bytes(32).hex_encode()


func make_public_token() -> String:
	# 原实现是 while 无界循环：短码空间被占满时服务器会在这里死循环卡住。
	for _try in PUBLIC_TOKEN_MAX_TRIES:
		var raw := _crypto.generate_random_bytes(PUBLIC_TOKEN_LENGTH)
		var id := ""
		for b in raw:
			id += PUBLIC_TOKEN_ALPHABET[int(b) % PUBLIC_TOKEN_ALPHABET.length()]
		if not public_token_seat.has(id):
			return id
	_log("public token space exhausted after %d tries" % PUBLIC_TOKEN_MAX_TRIES)
	return ""


# --- 房间查询与阶段（纯数据操作，不发 RPC）-----------------------------------

func room_next_free_slot(room: Dictionary) -> int:
	var states: Array = room.get("slot_states", [])
	for i in int(_cfg.get("team_slots", 6)):
		if i < states.size() and str(states[i]) == "empty":
			return i
	return -1


func room_player_count(room: Dictionary) -> int:
	var count := 0
	for st in (room.get("slot_states", []) as Array):
		if str(st) == "player":
			count += 1
	return count


func find_or_create_room() -> Dictionary:
	var room_lobby := str(_cfg.get("room_lobby", "lobby"))
	for room in rooms.values():
		if str(room.get("state", "")) == room_lobby and room_next_free_slot(room) >= 0:
			return room
	return new_room()


func touch_room(room: Dictionary) -> void:
	room.last_activity_at = _time()
	rooms_dirty = true   # B5：这是房间变更的主要汇聚口


func set_room_state(room: Dictionary, next_state: String) -> void:
	if str(room.get("state", "")) == next_state:
		return
	room.state = next_state
	room.state_started_at = _time()
	rooms_dirty = true   # B5：阶段切换必须落盘，否则重启后房间停在旧阶段


func public_room_list() -> Array:
	var room_lobby := str(_cfg.get("room_lobby", "lobby"))
	var team_slots := int(_cfg.get("team_slots", 6))
	var out: Array = []
	for room in rooms.values():
		if str(room.get("state", "")) != room_lobby or room_next_free_slot(room) < 0:
			continue
		# suspended 的房间正在等原班人马回来，不该被路人加入（B11）
		if bool(room.get("suspended", false)):
			continue
		out.append({
			"id": int(room.get("id", 0)),
			"players": room_player_count(room),
			"max": team_slots,
			"state": str(room.get("state", room_lobby)),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("id", 0)) < int(b.get("id", 0)))
	return out


# --- 生命周期（D1 第 4 刀第 4 步）---------------------------------------------
#
# 这两个原本在门面里，是文件头计划里的"生命周期乱麻"。搬进来的是**策略**——
# 什么时候该关、什么时候该转 suspended、各档 TTL 怎么算；留在门面的是**发消息**。
# 分界线很实在：RoomService 是 RefCounted，够不着 multiplayer，也不该够得着。
#
# 于是 close_fn / begin_next_prep_fn / auto_complete_fn 按 Callable 注入，
# 和已有的 now_fn / log_fn 是同一套写法。


# 每秒扫描一次房间：回收空房、进出 suspended、各阶段超时。
#
# close_fn(room, reason)         关房（门面那边会给还连着的 peer 发 room_closed）
# begin_next_prep_fn(room)       结算超时且对局未结束时推进到下一备战
func cleanup_rooms(close_fn: Callable, begin_next_prep_fn: Callable) -> void:
	var now := _time()
	var room_lobby := str(_cfg.get("room_lobby", "lobby"))
	var room_closed := str(_cfg.get("room_closed", "closed"))
	var room_prep := str(_cfg.get("room_prep", "prep"))
	var room_battle := str(_cfg.get("room_battle", "battle"))
	var room_result := str(_cfg.get("room_result", "result"))
	var lobby_empty_ttl := float(_cfg.get("lobby_empty_ttl_sec", 60.0))
	var suspend_grace := float(_cfg.get("room_suspend_grace_sec", 300.0))
	var prep_timeout := float(_cfg.get("prep_timeout_sec", 1800.0))
	var battle_timeout := float(_cfg.get("battle_timeout_sec", 300.0))
	var result_timeout := float(_cfg.get("result_timeout_sec", 600.0))

	var to_delete: Array = []
	for room_id in rooms.keys():
		var room: Dictionary = rooms[room_id]
		var state_name := str(room.get("state", room_lobby))
		var online_count := room_online_count(room)
		var match_over := bool(room.get("run_over", false))
		if online_count <= 0:
			if float(room.get("empty_since", 0.0)) <= 0.0:
				room.empty_since = now
			var empty_for := now - float(room.empty_since)
			# B11：零在线真人时的回收，依据是**还有没有有效 token**（= 还有没有人
			# 可能回来），不是房间处于哪个阶段。
			# 旧实现只回收 LOBBY 和已打完的房间，进了 PREP 的空房要等 PREP_TIMEOUT
			# （30 分钟），而 RESULT 超时又会把它推回 PREP 重新计时 —— 最长约 40 分钟
			# 占着 MAX_ROOMS 的名额。约 200 个这样的房间就能让全服 server_busy。
			var live_tokens := room_live_token_count(room)
			if live_tokens <= 0:
				# 没有任何人能回来了：立刻关，不必等任何 TTL。
				close_fn.call(room, "empty_no_tokens")
			elif match_over and empty_for >= lobby_empty_ttl:
				# 已打完的房间：没人在线就限时回收（不回收会永远卡在 ROOM_RESULT，
				# _room_begin_next_prep 对 final 房间直接 return，内存只涨不降）。
				close_fn.call(room, "match_over")
			elif empty_for >= suspend_grace:
				# 有有效 token，但过了产品确认的 300 秒恢复窗口。
				close_fn.call(room, "suspend_expired")
			else:
				# 恢复窗口内：转 suspended。**不推进阶段、不启动新模拟**，
				# 否则一个空房还会继续跑 AI 对局烧 CPU（R2）。
				if not bool(room.get("suspended", false)):
					room.suspended = true
					_log("room suspended id=%d tokens=%d grace=%ds" % [
						int(room.get("id", 0)), live_tokens, int(suspend_grace)])
		else:
			room.empty_since = 0.0
			if bool(room.get("suspended", false)):
				room.suspended = false
				_log("room resumed id=%d" % int(room.get("id", 0)))
		if str(room.get("state", "")) == room_closed:
			to_delete.append(room_id)
			continue
		# suspended 房间不参与任何阶段推进：既不超时关闭也不开新回合。
		# 它的生死只由上面那段（token 数 + 300 秒窗口）决定。
		if bool(room.get("suspended", false)):
			continue
		var age := now - float(room.get("state_started_at", now))
		if state_name == room_prep and age >= prep_timeout:
			close_fn.call(room, "prep_timeout")
		elif state_name == room_battle and age >= battle_timeout:
			close_fn.call(room, "battle_timeout")
		elif state_name == room_result and age >= result_timeout:
			# final 房间超时兜底：就算还有 peer 挂着（看完结算不退），也强制关闭
			if match_over:
				close_fn.call(room, "match_over")
			else:
				begin_next_prep_fn.call(room)
		if str(room.get("state", "")) == room_closed:
			to_delete.append(room_id)
	for room_id in to_delete:
		rooms.erase(room_id)


# 宽限到期扫描曾短暂放在这里（D1 步骤 2），后按原始 README 的目标结构挪到
# ReconnectService —— 那份 README 把它归在 ReconnectService（token/宽限/AI 接管）。
