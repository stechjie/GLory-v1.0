extends RefCounted

# D1 第 2 刀：从 NetworkService 抽出的回放传输（存放 + 压缩编解码）。
#
# 不用 class_name：make_server_zip.ps1 会把 .godot/global_script_class_cache.cfg
# 一起打包，新增的全局类如果没先重建缓存就打包，服务器会在解析阶段直接挂
# （见 docs/CHECKS.md）。用 preload 就没有这个问题。
#
# 依赖注入：本类只需要一个日志出口，不认识 NetworkService、不碰 multiplayer。
#
# 留在门面（NetworkService）上的部分，以及为什么：
#   * `_rpc_team_replay` —— @rpc 方法必须挂在 autoload 的 Node 上，服务对象没有节点路径
#   * `team_replay_received` 信号 —— 外部连的是 NetworkService 的信号
#   * `team_begin_round()` —— 那是回合生命周期，清空回放只是它做的若干件事之一
#   * `team_replay` / `team_replay_rival` 两个属性 —— 门面用 get/set 访问器转发到这里，
#     外部 60 处引用一个都不用改，且**共享同一份字典引用**（已实测：原地改能生效，
#     不会出现门面与服务各存一份的双份状态）

const PACK_HEADER_BYTES := 8
const MAX_UNCOMPRESSED_BYTES := 16 * 1024 * 1024

# 本客户端这一回合的 replay（B3，host 权威）
var team_replay: Dictionary = {}
# 敌方队伍同回合的 replay（战斗中切镜头观战用）
var team_replay_rival: Dictionary = {}

var _log_fn: Callable = Callable()


func configure(log_fn: Callable) -> void:
	_log_fn = log_fn


func clear() -> void:
	team_replay = {}
	team_replay_rival = {}
	# 重组中的分块一并丢掉。换局/重连时留着旧槽有两个后果：占着 MAX_INFLIGHT_TRANSFERS
	# 的名额，以及上一场的块可能和新一场拼在一起（battle_id 不同挡得住，但不该依赖它）。
	_inflight.clear()


# 包格式：[8 字节 小端 u64 原始长度][zstd 压缩数据]
# 长度头是必需的：`decompress()` 要求预先知道输出大小，而 `decompress_dynamic()`
# 只支持 brotli/gzip/deflate、**不支持 ZSTD**（实测踩过）。
# 头同时充当防护门：解压前先看这个数，超限直接拒 —— 不解压、不分配。
func pack(replay: Dictionary) -> PackedByteArray:
	if replay.is_empty():
		return PackedByteArray()
	var raw := var_to_bytes(replay)
	var out := PackedByteArray()
	out.resize(PACK_HEADER_BYTES)
	out.encode_u64(0, raw.size())
	out.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return out


func unpack(packed: PackedByteArray) -> Dictionary:
	if packed.size() <= PACK_HEADER_BYTES:
		return {}
	var declared := int(packed.decode_u64(0))
	# 防解压炸弹：只看头 8 字节就能判掉「几 KB 压缩包声称解出几 GB」，
	# 全程不解压、不分配。实测最坏原始 3.6 MB，16 MB 是 4 倍余量。
	if declared <= 0 or declared > MAX_UNCOMPRESSED_BYTES:
		_log("replay unpack rejected: declared=%d cap=%d packed=%d" % [
			declared, MAX_UNCOMPRESSED_BYTES, packed.size()])
		return {}
	var raw := packed.slice(PACK_HEADER_BYTES).decompress(declared, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != declared:
		# 头和实际内容对不上：损坏、截断、或者头被改过。安静失败，不崩。
		_log("replay unpack failed: got=%d declared=%d" % [raw.size(), declared])
		return {}
	# 用 bytes_to_var 而不是 bytes_to_var_with_objects：后者能从字节流里构造对象，
	# 在明文链路上（C14 未做）等于给中间人一个执行面。
	var value = bytes_to_var(raw)
	return value if typeof(value) == TYPE_DICTIONARY else {}


func _log(message: String) -> void:
	if _log_fn.is_valid():
		_log_fn.call(message)


# =============================================================================
# 分块 / 确认 / 重试（原始 README 给本服务定的四件事里的后三件）
# =============================================================================
#
# 分界和其余五个服务一致：本类是 RefCounted，**够不着 multiplayer**。
# 这里只回答三个问题 —— 该不该切、这块收下了没、还缺哪几块。
# 发包、收包、重试计时全部留在门面 NetworkService 上。
#
# 为什么要有阈值而不是一律分块：实测压缩后典型一场约 98 KiB，而 tools/channel_check
# 已经证明 200 KB 能过 CH_BULK。一律分块等于为了一个当前不存在的问题，
# 给自己换来一个重组缓冲（= 一个新的内存攻击面）。所以**低于阈值走原来的单包路径，
# 一个字节的行为都不变**，分块只对离群的大局生效（最坏一场原始 5.32 MiB）。
#
# 这个决定的代价必须写明：分块路径在生产里几乎不会被走到，等于养一条没人验的代码路。
# 对策是 should_chunk() 带一个 force 参数，门禁和真机双设备测试都走强制模式 ——
# 「实现了」和「验过了」是两回事。

# 超过它才分块。192 KiB：低于 channel_check 实证过的 200 KB，高于典型局的 98 KiB。
const CHUNK_THRESHOLD_BYTES := 192 * 1024
# 每块净荷。留在 ENet 可靠包舒适区内，且 4 MiB 的传输上限对应 88 块，远低于 MAX_CHUNKS。
const CHUNK_PAYLOAD_BYTES := 48 * 1024

# --- 加密链路下的另一套阈值（C14）--------------------------------------------
#
# DTLS 垫在 ENet 底下，ENet 一帧内把一个大包的分片全轰出去时，**接收端的 UDP
# 接收缓冲一次装不下就丢**，然后 ENet 重传 —— 在完全没有丢包的本机回环上都会
# 塌。实测（Godot 4.7.1，tools/dtls_check.tscn 里固化成用例）：
#
#     明文 62 KB 单包                    20 ms
#     DTLS 62 KB 单包                  2686 ms   ← 134 倍，刷 Buffer full 告警
#     DTLS 48 KB × 2，一帧一块         2969 ms   ← 分块但仍太大，照样塌
#     DTLS 32 KB × 2，一帧一块           21 ms
#     DTLS 16 KB × 4，一帧一块           35 ms
#
# 结论有两条，第二条是反直觉的那条：
#   ① 真实 replay 压缩后 61.8 KB，**远低于 192 KiB 阈值**，所以生产里从来不分块
#      —— 也就是说加密之后线上跑的正是最坏的那一行。
#   ② **分块本身不是解药，节流才是。** 8 KB 一块但一帧全发 = 4896 ms；
#      同样 8 KB 一块、一帧一块 = 62 ms。决定成败的是"两次 poll 之间灌进去多少
#      字节"，不是"每块多大"。发送侧的节流在 NetworkService._tick_replay_send。
#
# 安全余量：已知 32 KB/帧 可以、48 KB/帧 不行，取 16 KB —— 服务器限帧 30、
# 客户端 60，真实网络还有抖动，不在悬崖边上取值。
const CHUNK_THRESHOLD_ENCRYPTED_BYTES := 16 * 1024
const CHUNK_PAYLOAD_ENCRYPTED_BYTES := 16 * 1024
# 单次传输的压缩后字节上限。unpack() 那道 16 MiB 是解压**后**的上限，
# 挡不住「声称有一万块」这种在重组阶段就该被拒的输入，所以这里要单独设一道。
const MAX_TRANSFER_BYTES := 4 * 1024 * 1024
# 所有重组中传输的字节总和上限。单条限死了、总量不限，等于允许开很多条把内存吃光。
const MAX_REASSEMBLY_BYTES := 8 * 1024 * 1024
# 同时重组中的传输条数上限。
const MAX_INFLIGHT_TRANSFERS := 4
# 单次传输允许的最大块数。先用它判掉离谱的 total，再决定要不要分配任何东西。
# 512 而不是 256：加密模式下每块 16 KiB，4 MiB 上限正好对应 256 块 —— 卡在
# 等号上没有余量，再调小一次块大小就会把合法传输判成非法。真正的内存闸是
# MAX_TRANSFER_BYTES / MAX_REASSEMBLY_BYTES，这一条只挡"声称有一万块"。
const MAX_CHUNKS := 512
# 多久没有新块就回收。重组缓冲不带过期 = 一个发一半就跑的对端能把内存钉死。
const REASSEMBLY_TTL_SEC := 30.0

# 回放的两个方向。kind 必须是白名单里的值：不校验就等于让对端拿它当任意字典键，
# 每来一个新 kind 就多占一条重组槽。
const CHUNK_KIND_OWN := "own"
const CHUNK_KIND_RIVAL := "rival"

# key（"battle_id|kind"）-> {total:int, chunks:{idx:PackedByteArray}, bytes:int, age:float}
var _inflight: Dictionary = {}

# 链路是不是加密的（C14）。由 NetworkService 在建 peer 时告知 —— 本类是
# RefCounted，够不着 NetworkConfig 以外的任何运行时状态，也不该自己去猜。
var _encrypted := false


func set_transport_encrypted(on: bool) -> void:
	_encrypted = on


func chunk_payload_bytes() -> int:
	return CHUNK_PAYLOAD_ENCRYPTED_BYTES if _encrypted else CHUNK_PAYLOAD_BYTES


# 低于阈值返回 false —— 调用方据此走原来的单包 _rpc_team_replay。
# force 只给门禁和真机测试用，理由见本节开头。
func should_chunk(packed: PackedByteArray, force: bool = false) -> bool:
	if packed.size() <= PACK_HEADER_BYTES:
		return false          # 空包/只有头：没有可分的东西
	if force:
		return true
	if _encrypted:
		return packed.size() > CHUNK_THRESHOLD_ENCRYPTED_BYTES
	return packed.size() > CHUNK_THRESHOLD_BYTES


# 切块。返回 Array[Dictionary]，每块 {battle_id, kind, idx, total, data}。
# 切不了（空包、超过单次传输上限）返回空数组 —— 调用方必须处理这个情况，
# 不能默认「切出来一定非空」。
func split(packed: PackedByteArray, battle_id: String, kind: String) -> Array:
	if packed.size() <= PACK_HEADER_BYTES:
		return []
	if not _kind_ok(kind):
		_log("replay split rejected: bad kind=%s" % kind)
		return []
	if packed.size() > MAX_TRANSFER_BYTES:
		_log("replay split rejected: bytes=%d cap=%d" % [packed.size(), MAX_TRANSFER_BYTES])
		return []
	var payload_bytes := chunk_payload_bytes()
	var total := int(ceil(float(packed.size()) / float(payload_bytes)))
	if total <= 0 or total > MAX_CHUNKS:
		_log("replay split rejected: total=%d cap=%d" % [total, MAX_CHUNKS])
		return []
	var out: Array = []
	for i in total:
		var from := i * payload_bytes
		var to: int = min(from + payload_bytes, packed.size())
		out.append({
			"battle_id": battle_id,
			"kind": kind,
			"idx": i,
			"total": total,
			"data": packed.slice(from, to),
		})
	return out


# 收一块。返回 {"complete": bool, "packed": PackedByteArray, "error": String}。
#
# 这个函数的输入**完全由对端控制**，所以每一条校验都对应一种具体的滥用：
#   total 离谱      -> 一个包就能让重组表按一万块去记账
#   idx 越界        -> 写到别的槽里
#   data 超长       -> 绕过按块数算出来的上限
#   total 中途变化  -> 用第二个 total 把已有的记账搅乱
#   条数/总量超限   -> 开很多条把内存吃光
# 任何一条不过都**安静拒收**（返回 error，不抛、不崩）—— 和 unpack() 对损坏包的
# 处理方式保持一致。
func accept_chunk(env: Dictionary) -> Dictionary:
	var battle_id := str(env.get("battle_id", ""))
	var kind := str(env.get("kind", ""))
	var idx := int(env.get("idx", -1))
	var total := int(env.get("total", 0))
	var data: PackedByteArray = env.get("data", PackedByteArray())

	if battle_id.is_empty():
		return _chunk_error("missing_battle_id")
	if not _kind_ok(kind):
		return _chunk_error("bad_kind")
	if total <= 0 or total > MAX_CHUNKS:
		return _chunk_error("bad_total=%d" % total)
	if idx < 0 or idx >= total:
		return _chunk_error("bad_idx=%d/%d" % [idx, total])
	if data.size() > CHUNK_PAYLOAD_BYTES:
		return _chunk_error("chunk_too_large=%d" % data.size())

	var key := _chunk_key(battle_id, kind)
	var entry: Dictionary = _inflight.get(key, {})
	if entry.is_empty():
		if _inflight.size() >= MAX_INFLIGHT_TRANSFERS:
			return _chunk_error("too_many_inflight")
		# 按声称的 total 先算一遍最坏体积，超限的话一块都不收 ——
		# 「先收着再说」正是解压炸弹那类问题的成因。
		if total * CHUNK_PAYLOAD_BYTES > MAX_TRANSFER_BYTES:
			return _chunk_error("declared_too_large=%d" % total)
		entry = {"total": total, "chunks": {}, "bytes": 0, "age": 0.0}
		_inflight[key] = entry
	elif int(entry.get("total", 0)) != total:
		# 同一次传输里 total 变了：要么是 bug，要么是有人在搅记账。整条丢掉重来。
		_inflight.erase(key)
		return _chunk_error("total_changed")

	var chunks: Dictionary = entry.get("chunks", {})
	if chunks.has(idx):
		# 重复块（重试会造成）：幂等收下，但**不重复计字节**，否则总量记账会虚高。
		return {"complete": false, "packed": PackedByteArray(), "error": ""}
	if _total_bytes() + data.size() > MAX_REASSEMBLY_BYTES:
		return _chunk_error("reassembly_budget")

	chunks[idx] = data
	entry["chunks"] = chunks
	entry["bytes"] = int(entry.get("bytes", 0)) + data.size()
	entry["age"] = 0.0
	_inflight[key] = entry

	if chunks.size() < total:
		return {"complete": false, "packed": PackedByteArray(), "error": ""}

	# 齐了：**按 idx 顺序**拼回去。字典键序不保证，靠索引循环而不是 keys()。
	var out := PackedByteArray()
	for i in total:
		out.append_array(chunks[i])
	_inflight.erase(key)
	return {"complete": true, "packed": out, "error": ""}


# 还缺哪几块。供确认（收齐了报空）和重试（只补缺的那几块）用。
# 完全没见过这次传输时返回空 —— 调用方要能区分「不缺」和「没开始」，
# 那由 has_inflight() 回答。
func missing_chunks(battle_id: String, kind: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var entry: Dictionary = _inflight.get(_chunk_key(battle_id, kind), {})
	if entry.is_empty():
		return out
	var chunks: Dictionary = entry.get("chunks", {})
	for i in int(entry.get("total", 0)):
		if not chunks.has(i):
			out.append(i)
	return out


func has_inflight(battle_id: String, kind: String) -> bool:
	return _inflight.has(_chunk_key(battle_id, kind))


# 过期回收。用 tick 累加的年龄而不是墙钟：本类因此不需要时间源注入，
# 且门禁可以直接 tick(31.0) 把过期跑出来，不用等真实时间。
func tick(delta: float) -> void:
	if _inflight.is_empty():
		return
	var dead: Array = []
	for key in _inflight.keys():
		var entry: Dictionary = _inflight[key]
		entry["age"] = float(entry.get("age", 0.0)) + delta
		_inflight[key] = entry
		if float(entry["age"]) >= REASSEMBLY_TTL_SEC:
			dead.append(key)
	for key in dead:
		var entry2: Dictionary = _inflight[key]
		_log("replay reassembly expired: key=%s have=%d/%d bytes=%d" % [
			str(key), (entry2.get("chunks", {}) as Dictionary).size(),
			int(entry2.get("total", 0)), int(entry2.get("bytes", 0))])
		_inflight.erase(key)


func inflight_count() -> int:
	return _inflight.size()


func _chunk_key(battle_id: String, kind: String) -> String:
	return "%s|%s" % [battle_id, kind]


func _kind_ok(kind: String) -> bool:
	return kind == CHUNK_KIND_OWN or kind == CHUNK_KIND_RIVAL


func _total_bytes() -> int:
	var sum := 0
	for key in _inflight.keys():
		sum += int((_inflight[key] as Dictionary).get("bytes", 0))
	return sum


func _chunk_error(reason: String) -> Dictionary:
	_log("replay chunk rejected: %s" % reason)
	return {"complete": false, "packed": PackedByteArray(), "error": reason}
