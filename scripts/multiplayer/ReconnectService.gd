extends RefCounted

# D1 目标结构里的 ReconnectService：**token / 宽限 / AI 接管**。
#
# 名字容易误读，先把范围钉死。README 给的定义不是"客户端那个重连相位机"
# （那部分只有 23 行纯逻辑，而且每次相位转换都要 create_client、动 multiplayer.peer，
# 和 peer 生命周期长在一起，抽出来是空壳）。这里做的是**服务端侧的座位保留域**：
#
#   token      重连凭证的签发与校验（会话 token、玩家手输的短码）
#   宽限       掉线座位保留多久、到期怎么判
#   AI 接管    宽限到期后把座位转 dummy，让本回合不被一个掉线的人卡住
#
# 与 RoomService 的分界（这条是刻意的，和 README 字面略有出入）：
# **token ↔ 座位的索引留在 RoomService**，因为它随房间快照持久化、且
# room_live_token_count / move_seat_metadata / clear_seat_metadata /
# save_snapshot / load_snapshot 都要用它。硬搬过来会让两个服务互相依赖。
# 这里拿走的是**行为**：签发、清洗校验、宽限记账、到期判定、接管时的状态变更。
#
# 与门面的分界（和 RoomService 一致）：本类是 RefCounted，够不着 multiplayer，
# 也不该够得着。所以"广播大厅""推进阶段"这类动作按 Callable 注入。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。

# 短码给玩家手输，所以不能太长；用 base32 去掉易混字符（0/O/1/I），
# 10 位 × 32 符号 ≈ 2^50，配合限流与失败计数，在线枚举不再可行。
const PUBLIC_TOKEN_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const PUBLIC_TOKEN_LENGTH := 10
const PUBLIC_TOKEN_MAX_TRIES := 8
# 客户端上报的短码长度上限。比 PUBLIC_TOKEN_LENGTH 宽是为了容忍历史格式，
# 但仍要有上限：不设限等于让对端决定这个字符串多长。
const MAX_PUBLIC_ID_LEN := 24

var _now_fn: Callable = Callable()
var _log_fn: Callable = Callable()
var _cfg: Dictionary = {}
var _crypto := Crypto.new()


func configure(now_fn: Callable, log_fn: Callable, cfg: Dictionary) -> void:
	_now_fn = now_fn
	_log_fn = log_fn
	_cfg = cfg


func _time() -> float:
	if _now_fn.is_valid():
		return float(_now_fn.call())
	return float(Time.get_ticks_msec()) / 1000.0


func _log(message: String) -> void:
	if _log_fn.is_valid():
		_log_fn.call(message)


# --- token 签发与校验 ---------------------------------------------------------

func make_token() -> String:
	return _crypto.generate_random_bytes(32).hex_encode()


# taken_fn(id) -> bool：这个短码是不是已经被占了。索引在 RoomService 手里，
# 所以由调用方把"查重"这一步传进来。
#
# 有界重试：原实现是 while 无界循环，短码空间被占满时服务器会在这里死循环卡住。
func make_public_token(taken_fn: Callable) -> String:
	for _try in PUBLIC_TOKEN_MAX_TRIES:
		var raw := _crypto.generate_random_bytes(PUBLIC_TOKEN_LENGTH)
		var id := ""
		for b in raw:
			id += PUBLIC_TOKEN_ALPHABET[int(b) % PUBLIC_TOKEN_ALPHABET.length()]
		if not bool(taken_fn.call(id)):
			return id
	_log("public token space exhausted after %d tries" % PUBLIC_TOKEN_MAX_TRIES)
	return ""


# 客户端上报的短码必须先过这里（A12）。
#
# 此前 create/join 直接把客户端自报的 public_id 当键写进映射，等于任何人都能
# 用别人的短码覆盖那条映射，把对方的重连凭证指向自己的座位。清洗不解决归属
# （完整版要服务端签发），但它挡住了"随便一个字符串都能当键"。
func sanitize_public_id(raw: String) -> String:
	var id := raw.strip_edges().to_upper()
	if id.is_empty():
		return ""
	if id.length() > MAX_PUBLIC_ID_LEN:
		return ""
	for i in id.length():
		if not PUBLIC_TOKEN_ALPHABET.contains(id[i]):
			return ""
	return id


# --- 宽限 ---------------------------------------------------------------------

# 座位掉线：进保留态并起宽限窗口。
# 座位与 token 依旧保留——整局期间随时可重连回来（届时落到当前阶段）。
# 宽限只决定"别人等你多久"，不决定"你还能不能回来"。
func reserve_seat(room: Dictionary, slot: int) -> void:
	var now := _time()
	var grace := float(_cfg.get("reserve_grace_sec", 20.0))
	var reserved: Dictionary = room.get("reserved", {})
	reserved[slot] = {"reserved_at": now}
	room.reserved = reserved
	var deadline: Dictionary = room.get("reserve_deadline", {})
	deadline[slot] = now + grace
	room.reserve_deadline = deadline


# 本人回来了 / 座位被永久释放：撤掉保留态。
func release_reservation(room: Dictionary, slot: int) -> void:
	(room.get("reserved", {}) as Dictionary).erase(slot)
	(room.get("reserve_deadline", {}) as Dictionary).erase(slot)


# 每秒扫描：宽限到期的保留座位 -> 交给 takeover_fn 替它完成当前阶段动作，
# 回合不被卡住。
#
# suspended 的房间跳过：房里一个真人都没有，此时把座位转 AI 只会启动一场纯 AI
# 战斗烧 CPU，而这些座位的主人还在恢复窗口内可能回来（B11/R2）。
func tick_reserved_seats(rooms: Dictionary, takeover_fn: Callable) -> void:
	var now := _time()
	for room in rooms.values():
		if bool(room.get("suspended", false)):
			continue
		var deadline: Dictionary = room.get("reserve_deadline", {})
		if deadline.is_empty():
			continue
		var expired: Array = []
		for slot in deadline.keys():
			if now >= float(deadline[slot]):
				expired.append(int(slot))
		for slot in expired:
			deadline.erase(slot)
			takeover_fn.call(room, slot)
		room.reserve_deadline = deadline


# --- AI 接管 ------------------------------------------------------------------

# 宽限到期 -> 座位转 AI(dummy)，其他玩家立刻面对真 AI、本回合不再卡。
# token 仍有效：本人之后按"游戏重连"回来，resume 会把 dummy 变回 player。
#
# 只做状态变更。广播与阶段推进留在门面——它们要发 RPC。
func apply_ai_takeover(room: Dictionary, slot: int) -> void:
	var states: Array = room.get("slot_states", [])
	var ready: Array = room.get("ready", [])
	if slot < states.size():
		states[slot] = "dummy"
		room.slot_states = states
	if slot < ready.size():
		ready[slot] = true
		room.ready = ready
	(room.get("reserved", {}) as Dictionary).erase(slot)
	_log("reserve grace expired room=%d slot=%d -> AI takeover" % [int(room.get("id", 0)), slot])
