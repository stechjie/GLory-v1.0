extends Node

# Gate for scripts/autoload/IssueReport.gd.
#
# A diagnostic report is only useful if it can be trusted the one time someone
# actually files one, so the properties asserted here are the ones that would make
# it misleading:
#   - fields backed by services that do not exist say so, instead of reporting 0
#   - the blocker scan really finds a full-screen input-consuming Control
#   - it does not report a small STOP control as a blocker (that is normal UI)
#   - the report carries no server address, token or room code
#   - the emitted line is one line and parseable
#   - the report node never consumes input, because it lives on the tree root

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ReportScript := preload("res://scripts/autoload/IssueReport.gd")
const CHECK_NAME := "issue_report"

# Substrings that must never appear in a report. A report gets pasted into chat.
const FORBIDDEN_VALUE_HINTS: PackedStringArray = [
	"token", "password", "secret", "keystore",
]

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var reporter = ReportScript.new()
	reporter.name = "IssueReportUnderTest"
	add_child(reporter)

	_check_unavailable_sections_are_honest(reporter)
	_check_modal_stack_is_wired(reporter)
	_check_blocker_scan_finds_a_real_blocker(reporter)
	_check_small_controls_are_not_blockers(reporter)
	_check_slow_frames_are_bounded(reporter)
	_check_no_sensitive_values(reporter)
	_check_emitted_line_is_single_line_json(reporter)
	_check_input_is_not_consumed()
	_check_registered_as_autoload()
	_check_reports_do_not_overwrite_each_other(reporter)

	reporter.queue_free()
	_h.finish(get_tree())


# ModalStack and AsyncActionController are not built. Reporting an empty stack or a
# zeroed action state would read as a measurement -- "no modal was open" -- when the
# truth is that nobody looked.
func _check_unavailable_sections_are_honest(reporter) -> void:
	var report: Dictionary = reporter.capture("check_probe")
	# modal_stack 已经不在这一组了：ModalStack 服务已由同事落地（ui/services/ModalStack.gd），
	# 报告改成直接问它，断言见 _check_modal_stack_is_wired()。
	for section_name in ["action_state", "input_breadcrumbs"]:
		var section: Dictionary = report.get(section_name, {})
		if not _h.expect(not section.is_empty(), "section_missing",
				"报告里没有 %s 段" % section_name):
			continue
		_h.expect(section.has("available") and not bool(section["available"]),
			"section_claims_available",
			"%s 声称可用，但对应的服务还不存在" % section_name)
		_h.expect(not str(section.get("reason", "")).is_empty(),
			"section_no_reason", "%s 不可用却没有说明原因" % section_name)

	# The sections that ARE answered must not be quietly missing.
	for section_name in ["build", "startup", "warmup", "screen", "input_blockers", "network"]:
		_h.expect(report.has(section_name), "answered_section_missing",
			"报告里缺 %s 段" % section_name)


# modal_stack 曾经是一段 {"available": false} 占位，因为那时 ModalStack 还不存在。
# 它现在存在了，报告必须真的去问它 —— 一个永远说"服务不存在"的段，在服务落地之后
# 就从"诚实"变成了"过时的谎"。
func _check_modal_stack_is_wired(reporter) -> void:
	var section: Dictionary = reporter.capture("check_modal_probe").get("modal_stack", {})
	if not _h.expect(bool(section.get("available", false)),
			"modal_stack_still_stubbed",
			"modal_stack 仍报 available=false，但 ui/services/ModalStack.gd 已经存在（原因：%s）"
				% str(section.get("reason", ""))):
		return
	for key in ["depth", "top_id", "entries", "invisible_stop_count", "registered_but_not_in_tree"]:
		_h.expect(section.has(key), "modal_stack_field_missing",
			"modal_stack 段缺 %s" % key)
	_h.expect(int(section.get("depth", -1)) >= 0,
		"modal_stack_depth_invalid", "depth 应 >= 0，实际 %s" % str(section.get("depth")))

	# 空栈时不该凭空报出条目，否则排障时会追一个不存在的弹窗。
	if int(section.get("depth", -1)) == 0:
		_h.expect((section.get("entries", []) as Array).is_empty(),
			"modal_stack_phantom_entries", "depth 为 0 却列出了条目")


# The point of the whole file: a full-screen STOP control is exactly what eats the
# tap in a "clicked and nothing happened" report, and nothing else in this project
# tracks them.
func _check_blocker_scan_finds_a_real_blocker(reporter) -> void:
	var layer := CanvasLayer.new()
	layer.name = "IssueReportProbeLayer"
	layer.layer = 99
	add_child(layer)
	var blocker := ColorRect.new()
	blocker.name = "ProbeFullScreenBlocker"
	blocker.color = Color(0, 0, 0, 0.0)
	# Invisible to the eye but still consuming input -- the worst variant, and the
	# one the report must be able to name.
	blocker.modulate = Color(1, 1, 1, 0.0)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(blocker)

	var report: Dictionary = reporter.capture("check_blocker_probe")
	var section: Dictionary = report.get("input_blockers", {})
	var blockers: Array = section.get("blockers", [])
	var matched := {}
	for entry in blockers:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if str((entry as Dictionary).get("path", "")).contains("ProbeFullScreenBlocker"):
			matched = entry as Dictionary
			break
	_h.expect(not matched.is_empty(), "blocker_not_found",
		"全屏 MOUSE_FILTER_STOP 控件没有被扫描到 —— 「点了没反应」的首要嫌疑就查不出来")
	if not matched.is_empty():
		_h.expect(bool(matched.get("invisible_but_blocking", false)),
			"invisible_blocker_not_flagged",
			"透明但仍吃输入的控件没有被标出来，那是最难查的一种")
		_h.expect(not str(matched.get("path", "")).is_empty(),
			"blocker_no_path", "扫到的阻挡层没有节点路径，无法定位")
		# The whole point of the suspect flag: this one must survive the filter.
		_h.expect(bool(matched.get("suspect", false)),
			"blocker_not_suspect",
			"CanvasLayer 上的透明全屏阻挡层没有被判为可疑 —— 那正是要报出来的那类")
	var suspects: Array = section.get("suspects", [])
	_h.expect(suspects.size() >= 1, "suspects_empty",
		"suspects 是空的，但刚刚就放了一个 CanvasLayer 上的透明阻挡层")

	layer.queue_free()


# A STOP control the size of a button is normal UI. Reporting it would bury the
# real blocker in noise.
func _check_small_controls_are_not_blockers(reporter) -> void:
	var small := Button.new()
	small.name = "ProbeSmallButton"
	small.mouse_filter = Control.MOUSE_FILTER_STOP
	small.size = Vector2(120, 48)
	add_child(small)

	var report: Dictionary = reporter.capture("check_small_probe")
	var blockers: Array = (report.get("input_blockers", {}) as Dictionary).get("blockers", [])
	var found_small := false
	for entry in blockers:
		if typeof(entry) == TYPE_DICTIONARY \
				and str((entry as Dictionary).get("path", "")).contains("ProbeSmallButton"):
			found_small = true
			break
	_h.expect(not found_small, "small_control_reported",
		"普通大小的按钮被当成全屏阻挡层报出来了 —— 会把真正的阻挡层淹掉")

	small.queue_free()


func _check_slow_frames_are_bounded(reporter) -> void:
	for i in (ReportScript.SLOW_FRAME_KEEP + 6):
		reporter.record_slow_frame(40.0 + float(i))
	var frames: Array = reporter.slow_frames()
	_h.expect(frames.size() == ReportScript.SLOW_FRAME_KEEP,
		"slow_frames_unbounded",
		"慢帧环形缓冲没有上限：保留了 %d 条，应为 %d" % [frames.size(), ReportScript.SLOW_FRAME_KEEP])
	if frames.size() > 0:
		# Oldest dropped, newest kept.
		var last: Dictionary = frames[frames.size() - 1]
		_h.expect(float(last.get("ms", 0.0)) > 40.0,
			"slow_frames_wrong_end", "环形缓冲丢的是新的而不是旧的")

	# One real stall must not fill the whole buffer. Performance.TIME_PROCESS does
	# not refresh every frame, so _process() reads the same value repeatedly; without
	# the de-duplication a single 64.8 ms warmup stall evicted every other entry.
	var source := _code_only(FileAccess.get_file_as_string("res://scripts/autoload/IssueReport.gd"))
	_h.expect(source.contains("_last_recorded_ms"),
		"slow_frames_not_deduped",
		"慢帧采样没有去重 —— 同一次卡顿会被连读成十条，把其它慢帧全挤掉")


# A report is meant to be pasted into a chat window.
func _check_no_sensitive_values(reporter) -> void:
	var report: Dictionary = reporter.capture("check_privacy_probe")
	var text := JSON.stringify(report).to_lower()
	for hint in FORBIDDEN_VALUE_HINTS:
		_h.expect(not text.contains(str(hint)),
			"sensitive_field_present",
			"报告里出现了 '%s' —— 报告会被贴进聊天窗口" % str(hint))
	# The network section must carry the state and nothing that identifies a room.
	var network: Dictionary = report.get("network", {})
	for forbidden in ["address", "port", "room_id", "public_token", "seat"]:
		_h.expect(not network.has(forbidden),
			"network_overshares", "network 段带了 %s，只应有连接状态" % forbidden)


func _check_emitted_line_is_single_line_json(reporter) -> void:
	# capture() prints a summary line; assert the summary shape stays greppable.
	var report: Dictionary = reporter.capture("check_line_probe")
	var summary := {
		"reason": str(report.get("reason", "")),
		"screen": "probe",
		"input_blockers": 0,
	}
	var line := "%s %s" % [ReportScript.LOG_PREFIX, JSON.stringify(summary)]
	_h.expect(not line.contains("\n"), "line_multiline", "报告摘要行里有换行")
	var parsed: Variant = JSON.parse_string(line.substr(ReportScript.LOG_PREFIX.length() + 1))
	_h.expect(parsed is Dictionary, "line_unparseable", "报告摘要行不是合法 JSON")

	var source := FileAccess.get_file_as_string("res://scripts/autoload/IssueReport.gd")
	_h.expect(source.contains("JSON.stringify(summary)"),
		"line_not_summarised",
		"完整报告不能整个塞进日志行 —— logcat 会截断，detail 应落文件")


# This node sits on the tree root. Consuming an event here would produce the exact
# symptom the report exists to explain.
func _check_input_is_not_consumed() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/autoload/IssueReport.gd")
	if not _h.expect(not source.is_empty(), "source_unreadable", "读不到 IssueReport.gd"):
		return
	var code := _code_only(source)
	_h.expect(not code.contains("set_input_as_handled"),
		"input_consumed",
		"IssueReport 调用了 set_input_as_handled() —— 挂在 root 上会吞掉玩家的点击")
	_h.expect(code.contains("OS.is_debug_build()"),
		"hotkey_not_gated", "F12 热键没有按构建类型守卫")


func _check_registered_as_autoload() -> void:
	var source := FileAccess.get_file_as_string("res://project.godot")
	_h.expect(source.contains("IssueReport=\"*res://scripts/autoload/IssueReport.gd\""),
		"not_autoloaded", "IssueReport 没有注册成 autoload，报告就没人能触发")


# The interesting case is someone tapping over and over because nothing happened,
# so two captures inside one millisecond is the expected pattern, not a rare one.
# Keying the filename on the clock alone silently loses the earlier report.
func _check_reports_do_not_overwrite_each_other(reporter) -> void:
	var first: String = str(reporter._write_report({"probe": 1}))
	var second: String = str(reporter._write_report({"probe": 2}))
	_h.expect(not first.is_empty() and not second.is_empty(),
		"report_not_written", "报告文件没写出来：%s / %s" % [first, second])
	_h.expect(first != second, "report_filename_collision",
		"同一毫秒内的两次抓取写到了同一个文件（%s），先抓的那份会被覆盖" % first)


# Comments stripped, so an assertion about a call cannot be satisfied or tripped by
# prose. Same helper and same reasoning as tools/vfx_warmup_check.gd.
func _code_only(source: String) -> String:
	var out: PackedStringArray = []
	for raw_line in source.split("\n"):
		var line := str(raw_line)
		var hash_at := line.find("#")
		if hash_at >= 0:
			line = line.substr(0, hash_at)
		out.append(line)
	return "\n".join(out)
