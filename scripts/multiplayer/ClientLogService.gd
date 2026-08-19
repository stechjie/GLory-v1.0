extends RefCounted

# D1 第 3 刀：从 NetworkService 抽出的客户端诊断日志。
#
# 做三件事：
#   1. 调试构建下 print 到控制台（发布版静音 —— print 在手机上每次都是一次系统调用）
#   2. 进内存环形缓冲，重连成功后把断线前后的现场回传服务器（落 journald，与服务端事件对着看）
#   3. 落盘，app 被杀也留得住现场；文件超限时每进程轮转一次
#
# 专服不走这里（`server_mode`）：服务器有 journald，不用双写。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。
#
# 留在门面（NetworkService）上的：
#   * `_net_log()` —— 115 个内部调用点，保留为薄包装，一个都不用改
#   * `_client_send_pending_logs()` —— 要调 `.rpc_id(1, lines)`，RPC 只能从 Node 发
#   * `_rpc_client_log` —— @rpc 必须挂在 autoload 的 Node 上

const MAX_LINES := 80
const LOG_FILE := "user://net_log.txt"
const ROTATE_BYTES := 1000000
# 回传时的单行截断长度。和服务端侧的总字节封顶是两道独立的闸。
const SEND_LINE_MAX_CHARS := 200

var _buffer: Array = []
var _sent := 0
var _rotated := false
var _file_path := LOG_FILE


# file_path 只为测试可注入：默认值与原实现一致，正式路径不受影响。
func configure(file_path: String = LOG_FILE) -> void:
	_file_path = file_path


func write(message: String, server_mode: bool) -> void:
	# print 在手机上每次都是一次系统调用，发布版必须静音。
	if OS.is_debug_build():
		print("[NET] %s" % message)
	if server_mode:
		return  # 服务器有 journald，不用双写
	var line := "%s | %s" % [Time.get_datetime_string_from_system(), message]
	_buffer.append(line)
	if _buffer.size() > MAX_LINES:
		_buffer.pop_front()
		# 缓冲整体前移了一格，已发游标必须跟着退一格，
		# 否则会把还没发过的行当成已发的跳过去。
		if _sent > 0:
			_sent -= 1
	_write_file(line)


# 取出还没回传的增量并推进游标。没有增量时返回空数组。
func take_pending_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	if _buffer.size() <= _sent:
		return lines
	for i in range(_sent, _buffer.size()):
		lines.append(str(_buffer[i]).substr(0, SEND_LINE_MAX_CHARS))
	_sent = _buffer.size()
	return lines


func has_pending() -> bool:
	return _buffer.size() > _sent


func buffered_count() -> int:
	return _buffer.size()


func sent_count() -> int:
	return _sent


func clear() -> void:
	_buffer.clear()
	_sent = 0


func _write_file(line: String) -> void:
	# 每进程只轮转一次：超限就整份删掉重来。保留半份旧日志的价值不大，
	# 而每行都去 stat 一次文件长度的代价不小。
	if not _rotated:
		_rotated = true
		var probe := FileAccess.open(_file_path, FileAccess.READ)
		if probe != null and probe.get_length() > ROTATE_BYTES:
			probe = null
			DirAccess.remove_absolute(ProjectSettings.globalize_path(_file_path))
	var f := FileAccess.open(_file_path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_file_path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(line)
