extends RefCounted

# D1 目标结构里的 MatchStateService：**状态信封 / epoch / seq**。
#
# 这是六个服务里最该有独立测试的一个：它决定客户端**接受还是丢弃**一份房间状态。
# 判错的症状不是崩溃，而是"界面停在上一秒不动"或"状态莫名回退"，两种都极难从
# 日志里看出根因。
#
# 应用规则（状态信封 RFC 第六节）：
#   epoch 不同   -> 服务器重启过（或这是第一份），接受
#   seq 未前进   -> 迟到包，丢弃
#   否则         -> 整份替换
#
# 最后那条刻意**不检查连号**：全量快照跳号直接应用就是对的，这正是不做 delta
# 换来的"漏包自愈"，服务器因此不需要保留任何状态历史。这条容易被后来者当成 bug
# "顺手修好"，所以在这里和测试里都写明。
#
# 交易幂等（信封 E4）也归这里：客户端重连后会重发还没拿到回执的交易，
# 服务端靠 rid 找回上次的答案并**重放结果、不重做副作用** —— 那正是幂等的全部含义。
# 丢了这份日志就等于同一笔宝物/祭坛被执行两次。
#
# 与门面的分界（和其它服务一致）：本类是 RefCounted，够不着 multiplayer。
# 下发信封、回执 RPC 都留在门面，这里只回答"该不该应用""上次的答案是什么"。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。

# 每座位保留的交易回执条数。定长：客户端只会重发"还没拿到回执"的那几笔，
# 留太多只是占快照体积（这份日志要随房间快照持久化）。
const TX_LOG_PER_SLOT := 16

var _now_fn: Callable = Callable()

# --- 客户端侧：已应用到哪一份 -------------------------------------------------
var applied_epoch := 0
var applied_seq := 0


func configure(now_fn: Callable) -> void:
	_now_fn = now_fn


func _time() -> float:
	if _now_fn.is_valid():
		return float(_now_fn.call())
	return float(Time.get_ticks_msec()) / 1000.0


# --- 服务端：序号递增 ---------------------------------------------------------

# 每次房间权威状态变更都要 +1。重启后从 0 重来的话，客户端手里还留着重启前的号，
# 会把新包当迟到包丢掉 —— 所以 state_seq 必须随房间快照一起持久化，
# epoch 变了是第二道防线，但两条都在才稳。
func bump_seq(room: Dictionary) -> int:
	var next := int(room.get("state_seq", 0)) + 1
	room.state_seq = next
	return next


# --- 客户端：该不该应用这一份 -------------------------------------------------

# 只做判断，不改自己的状态 —— 门面在真正应用成功之后才调 mark_applied()。
# 分开是有意的：判定与提交之间还有别的检查（比如重连期间不许覆盖手里的 token），
# 那些检查失败时**不能**把 applied_seq 往前推，否则真正该应用的那一份会被当成迟到包。
func should_apply(epoch: int, seq: int) -> bool:
	if epoch != applied_epoch:
		# 服务器重启过，或这是第一份。seq 从新的一轮重新计数，不能拿旧号去比。
		return true
	# 同一代内：seq 必须前进。这里刻意**不要求连号** —— 全量快照跳号直接应用
	# 就是对的，那是"漏包自愈"，不是需要修的缺口。
	return seq > applied_seq


func mark_applied(epoch: int, seq: int) -> void:
	applied_epoch = epoch
	applied_seq = seq


# 回到"没应用过任何一份"。换局/重连时用：留着旧号会让新一轮的前几份被当成迟到包。
func reset_applied() -> void:
	applied_epoch = 0
	applied_seq = 0


# --- 交易幂等（信封 E4）------------------------------------------------------

# 找回这一笔的上次答案。找不到返回空字典，调用方据此决定"新交易"还是"重发"。
func find_receipt(room: Dictionary, slot: int, rid: String) -> Dictionary:
	if rid.is_empty():
		return {}
	var log_map: Dictionary = room.get("tx_log", {})
	var entries: Array = log_map.get(slot, [])
	for e in entries:
		if typeof(e) == TYPE_DICTIONARY and str((e as Dictionary).get("rid", "")) == rid:
			return e as Dictionary
	return {}


func record_receipt(room: Dictionary, slot: int, rid: String, kind: String, result: Dictionary) -> void:
	var log_map: Dictionary = room.get("tx_log", {})
	var entries: Array = log_map.get(slot, [])
	entries.append({"rid": rid, "kind": kind, "result": result, "at": _time()})
	# 定长环：超出就丢最旧的。丢的是"早就拿到回执"的那几笔，重发不会再问它们。
	while entries.size() > TX_LOG_PER_SLOT:
		entries.pop_front()
	log_map[slot] = entries
	room.tx_log = log_map
