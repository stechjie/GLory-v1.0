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
