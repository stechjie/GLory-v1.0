extends Node

# D1 第 3 刀的验收：scripts/multiplayer/ClientLogService.gd 的行为用例。
#
# 与限流同样的情况：抽这块之前，客户端日志在整个仓库里**没有任何自动化覆盖** ——
# handshake / persist / reconnect / channel / adversarial 五个探针里一次都没提到它。
# 那几个探针全绿，对"日志缓冲有没有被抽坏"零信息量。
#
# 重点覆盖环形缓冲与已发游标的联动：缓冲满了要 pop_front，同时把 _sent 往回退一格，
# 否则会把还没回传过的行当成已发的跳过去 —— 这类 off-by-one 在真实链路上表现为
# "重连后少了几行现场"，几乎不可能靠人工发现。
#
# 落盘路径通过 configure() 注入到临时文件，不污染正式的 user://net_log.txt。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/client_log_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ClientLogService := preload("res://scripts/multiplayer/ClientLogService.gd")

const CHECK_NAME := "client_log"
const TEST_LOG := "user://_test_client_log.txt"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_server_mode_skips_buffer()
	_case_client_buffers()
	_case_ring_buffer_cap()
	_case_pending_increment_only()
	_case_cursor_follows_eviction()
	_case_line_truncation()
	_case_clear()
	_case_file_written()
	_cleanup()
	_h.finish(get_tree())


func _new_service() -> RefCounted:
	_remove_test_log()
	var service := ClientLogService.new()
	service.configure(TEST_LOG)
	return service


func _remove_test_log() -> void:
	if FileAccess.file_exists(TEST_LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_LOG))


func _cleanup() -> void:
	_remove_test_log()


# --- 用例 ---------------------------------------------------------------------

# 专服有 journald，不双写：server_mode=true 时不进缓冲。
func _case_server_mode_skips_buffer() -> void:
	var s := _new_service()
	for _i in 5:
		s.write("server side message", true)
	_h.expect(s.buffered_count() == 0, "server_mode_buffered",
		"专服模式不该进缓冲，实际缓冲了 %d 行" % s.buffered_count())
	_h.expect(not s.has_pending(), "server_mode_pending", "专服模式不该有待回传内容")


func _case_client_buffers() -> void:
	var s := _new_service()
	s.write("hello", false)
	_h.expect(s.buffered_count() == 1, "client_not_buffered",
		"客户端模式应进缓冲，实际 %d 行" % s.buffered_count())
	_h.expect(s.has_pending(), "client_no_pending", "写入后应有待回传内容")


# 缓冲是环形的：超过 MAX_LINES 就丢最老的一行。
func _case_ring_buffer_cap() -> void:
	var s := _new_service()
	var over := ClientLogService.MAX_LINES + 20
	for i in over:
		s.write("line %d" % i, false)
	_h.expect(s.buffered_count() == ClientLogService.MAX_LINES, "ring_cap_broken",
		"缓冲上限应为 %d，实际 %d" % [ClientLogService.MAX_LINES, s.buffered_count()])
	var lines: PackedStringArray = s.take_pending_lines()
	_h.expect(lines.size() == ClientLogService.MAX_LINES, "ring_pending_size",
		"待回传行数应为 %d，实际 %d" % [ClientLogService.MAX_LINES, lines.size()])
	# 最老的那些行应已被挤掉：首行不该还是 line 0。
	if lines.size() > 0:
		_h.expect(not str(lines[0]).contains("line 0 "), "oldest_line_kept",
			"缓冲已满但最老的行没有被挤掉：%s" % str(lines[0]))


# 只发增量：取过一次之后没有新写入就不该再有待回传。
func _case_pending_increment_only() -> void:
	var s := _new_service()
	for i in 5:
		s.write("m%d" % i, false)
	var first: PackedStringArray = s.take_pending_lines()
	_h.expect(first.size() == 5, "first_take_size", "首次应取到 5 行，实际 %d" % first.size())
	_h.expect(not s.has_pending(), "still_pending_after_take", "取过之后不该还有待回传")
	_h.expect(s.take_pending_lines().is_empty(), "repeat_take_nonempty",
		"没有新写入时重复取应为空（否则会重复回传同样的行）")
	s.write("m5", false)
	var second: PackedStringArray = s.take_pending_lines()
	_h.expect(second.size() == 1, "increment_size",
		"新写 1 行后应只取到 1 行增量，实际 %d" % second.size())


# 关键用例：缓冲满时 pop_front，已发游标必须跟着退一格。
# 否则下一次 take 会从错位的下标开始，把没发过的行当成已发的跳过去。
func _case_cursor_follows_eviction() -> void:
	var s := _new_service()
	for i in ClientLogService.MAX_LINES:
		s.write("old %d" % i, false)
	s.take_pending_lines()   # 全部标记为已发
	_h.expect(s.sent_count() == ClientLogService.MAX_LINES, "cursor_after_take",
		"游标应等于缓冲长度，实际 %d" % s.sent_count())
	# 再写 3 行：缓冲已满，会挤掉 3 行最老的，游标也应退 3 格。
	for i in 3:
		s.write("new %d" % i, false)
	_h.expect(s.sent_count() == ClientLogService.MAX_LINES - 3, "cursor_not_rewound",
		"挤掉 3 行后游标应退到 %d，实际 %d" % [ClientLogService.MAX_LINES - 3, s.sent_count()])
	var pending: PackedStringArray = s.take_pending_lines()
	_h.expect(pending.size() == 3, "eviction_lost_lines",
		"应恰好取到 3 行新内容，实际 %d 行（游标错位会漏发或重发）" % pending.size())
	if pending.size() == 3:
		_h.expect(str(pending[0]).contains("new 0"), "eviction_wrong_lines",
			"取到的第一行应是 new 0，实际 %s" % str(pending[0]))


func _case_line_truncation() -> void:
	var s := _new_service()
	var long_line := ""
	for _i in 400:
		long_line += "x"
	s.write(long_line, false)
	var lines: PackedStringArray = s.take_pending_lines()
	if not lines.is_empty():
		_h.expect(str(lines[0]).length() <= ClientLogService.SEND_LINE_MAX_CHARS,
			"line_not_truncated",
			"回传单行应截断到 %d 字符，实际 %d" % [
				ClientLogService.SEND_LINE_MAX_CHARS, str(lines[0]).length()])


func _case_clear() -> void:
	var s := _new_service()
	for i in 10:
		s.write("m%d" % i, false)
	s.take_pending_lines()
	s.clear()
	_h.expect(s.buffered_count() == 0, "clear_buffer", "clear() 后缓冲应为空")
	_h.expect(s.sent_count() == 0, "clear_cursor", "clear() 后游标应归零")
	_h.expect(not s.has_pending(), "clear_pending", "clear() 后不应有待回传")


# 落盘：app 被杀也要留得住现场。
func _case_file_written() -> void:
	var s := _new_service()
	s.write("persisted line", false)
	_h.expect(FileAccess.file_exists(TEST_LOG), "log_file_missing",
		"写日志后应生成文件 %s" % TEST_LOG)
	var text := FileAccess.get_file_as_string(TEST_LOG)
	_h.expect(text.contains("persisted line"), "log_file_content",
		"日志文件里没有写入的内容")
	# 追加而不是覆盖
	s.write("second line", false)
	text = FileAccess.get_file_as_string(TEST_LOG)
	_h.expect(text.contains("persisted line") and text.contains("second line"),
		"log_file_overwritten", "第二次写入把第一行覆盖掉了（应为追加）")
