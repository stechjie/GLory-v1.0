class_name ServerFlags
extends RefCounted

# 服务端特性开关。整改分批上线时，每一项都要能单独关掉而不必再 restart
# （restart 会杀掉所有在场对局，见 docs/联机审计与整改方案.md B5）。
#
# 用法：
#   服务器启动时读一次；之后每 RELOAD_INTERVAL_SEC 检查文件 mtime，改了就热重载。
#   运维改完 JSON 存盘即可生效，无需重启进程。
#
# 文件位置：默认 user://server_flags.json，可用 --flags=<绝对路径> 覆盖。
# 文件不存在 = 全部取默认值（等价于「什么都没开」），不报错。

const DEFAULT_PATH := "user://server_flags.json"
const RELOAD_INTERVAL_SEC := 5.0

# 开关默认值。新增开关一律默认 false/保守值：漏配时的行为必须等于「改动没上线」。
const DEFAULTS := {
	# 载荷埋点。var_to_bytes 一份几 MB 的 replay 本身就有 CPU 开销，而服务器是
	# 同步主循环（B4），长期开着可能自己造成冻结 —— 只在测量周开。
	"metrics_payload_sizes": false,
	# 每 N 场战斗采样一次，1 = 每场都测。测量周先用 1，量到 P99 后调大或整个关掉。
	"metrics_sample_every_n_battles": 1,
	# P1 备战经济账本（EconomyLedger）。
	#
	# 两段式上线，这是 RFC 里"L4 必须和 L1–L3 一起发布"那条规矩的落地方式：
	#   economy_ledger_enabled = true   服务端开始记账、随 room_state 下发、
	#                                   在棋盘提交时与客户端自报值**影子比对**。
	#                                   此时账本仍**不是**权威 —— 客户端照旧自己算钱。
	#   economy_ledger_authoritative    账本成为唯一真相：战后结算不再读
	#                                   snapshot.gold，客户端切成 receipt-only。
	#
	# **第二个开关必须等客户端改造完成后才能开。** 只开它而客户端还在自己预扣，
	# 或者反过来，都会让两边账目分叉。默认全 false = 等于这批改动没上线。
	"economy_ledger_enabled": false,
	"economy_ledger_authoritative": false,
	# 已移除：send_rival_replay
	# 它和已确认的产品规则「两队 replay 一律全发（玩家要能随时切镜头看另一队）」
	# 直接冲突 —— 一个生产开关能悄悄破坏产品不变量，本身就是缺陷。
	# 而它当初的用途（测量周关掉省带宽）在 replay 压缩之后也不成立了：
	# 实测压缩后一份才 61.8 KB，两份 124 KB，没有省的必要。
}

static var _values: Dictionary = {}
static var _path := ""
static var _last_mtime := 0
static var _last_check_at := 0.0
static var _loaded := false

static func resolve_path() -> String:
	if not _path.is_empty():
		return _path
	for arg in OS.get_cmdline_args():
		if str(arg).begins_with("--flags="):
			_path = str(arg).substr(8).strip_edges()
			return _path
	_path = DEFAULT_PATH
	return _path

static func get_bool(key: String) -> bool:
	return bool(_flag(key))

static func get_int(key: String) -> int:
	return int(_flag(key))

static func _flag(key: String) -> Variant:
	if not _loaded:
		reload(true)
	if _values.has(key):
		return _values[key]
	return DEFAULTS.get(key, false)

# 定期调用（服务器 _process 的清理 tick 里）。文件 mtime 没变就直接返回，代价接近零。
static func poll_reload(now: float) -> void:
	if now - _last_check_at < RELOAD_INTERVAL_SEC:
		return
	_last_check_at = now
	reload(false)

static func reload(force: bool) -> void:
	_loaded = true
	var path := resolve_path()
	if not FileAccess.file_exists(path):
		if force:
			_values = {}
		return
	var mtime := int(FileAccess.get_modified_time(path))
	if not force and mtime == _last_mtime:
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		# 坏文件不能让开关集体失效（那等于悄悄回滚了一批改动）：保留上一次的好值。
		# **不更新 _last_mtime**：否则这次坏内容会被记成"已处理"，运维把 JSON 修好
		# 之后如果 mtime 不变（同秒内改回、或编辑器保留时间戳），就再也不会重读了。
		push_warning("ServerFlags: invalid JSON at %s, keeping previous values" % path)
		return
	_last_mtime = mtime
	_values = parsed
	print("[NET] server flags loaded: %s" % JSON.stringify(_values))

# 每 N 场采样一次的计数器。返回 true 表示这一场要测。
static var _battle_counter := 0

static func should_sample_battle() -> bool:
	if not get_bool("metrics_payload_sizes"):
		return false
	var every := maxi(1, get_int("metrics_sample_every_n_battles"))
	_battle_counter += 1
	return _battle_counter % every == 0
