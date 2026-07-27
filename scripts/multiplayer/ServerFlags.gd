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
	# 敌方队伍 replay（观战切镜头用）。默认 true = 保持现有行为。
	# 关掉能立刻省下约一半 replay 出口流量，但老客户端的「观战敌方」会变空——
	# 那是删功能，不是优化。真正的按需拉取要等第 3 批加客户端 replay_request 通道。
	# 这个开关的用途是：测量周临时关掉，量出敌方 replay 到底占多少带宽，为第 3 批定优先级。
	"send_rival_replay": true,
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
	_last_mtime = mtime
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		# 坏文件不能让开关集体失效（那等于悄悄回滚了一批改动）：保留上一次的好值。
		push_warning("ServerFlags: invalid JSON at %s, keeping previous values" % path)
		return
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
