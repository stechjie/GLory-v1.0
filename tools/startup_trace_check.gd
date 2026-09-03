extends Node

# Gate for scripts/autoload/StartupTrace.gd.
#
# A timing record is only worth anything if it cannot be quietly bent, so the
# properties asserted here are the ones that would make the numbers lie:
#   - a mark's timestamp is set once and never moved by a later caller
#   - the log line is one line and is valid JSON (tools/android_smoke.sh greps it
#     out of logcat and parses it; a multi-line payload silently drops fields)
#   - metadata cannot carry a token or a room address into a release logcat
#   - Main.gd actually calls the marks, because an autoload nobody calls records a
#     perfectly consistent, perfectly empty timeline
#
# Runs against a fresh instance rather than the live autoload: the autoload already
# holds this process's own boot marks, and asserting against those would test the
# check scene's startup instead of the API.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TraceScript := preload("res://scripts/autoload/StartupTrace.gd")
const CHECK_NAME := "startup_trace"

const MAIN_PATH := "res://scenes/main/Main.gd"
const TRACE_SOURCE_PATH := "res://scripts/autoload/StartupTrace.gd"
const ANDROID_SMOKE_PATH := "res://tools/android_smoke.sh"
const PROJECT_PATH := "res://project.godot"

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var trace = TraceScript.new()
	trace.name = "StartupTraceUnderTest"
	add_child(trace)

	_check_engine_boot_mark(trace)
	_check_first_frame_provenance()
	_check_marks_are_write_once(trace)
	_check_ordering(trace)
	_check_missing_marks_are_visible(trace)
	_check_metadata_is_sanitized(trace)
	_check_values_are_scrubbed(trace)
	_check_log_line_is_single_line_json(trace)
	_check_call_sites_exist()
	_check_registered_first()
	_check_build_info_absence_is_honest(trace)
	_check_build_info_line(trace)
	_check_overlay_is_build_gated()
	_check_android_install_identity_contract()
	_check_android_startup_report_contract()

	trace.queue_free()
	_h.finish(get_tree())


# V3 P0-01: T1 must come from a real present.
#
# The ordering assertion cannot catch this. If someone moves the T1 mark into
# `_ready()` or behind a timer, T1 still lands before T2 and every existing
# assertion here stays green -- while the number stops meaning "the player saw a
# frame" and starts meaning "a script ran". That is the same shape as the V2
# `quit_on_go_back` defect: source reads fine, behaviour is wrong.
#
# So this asserts the wiring itself: T1 is emitted from the `frame_post_draw`
# handler, that handler is connected to `RenderingServer`, and it is not reachable
# from `_ready()` or a timer.
func _check_first_frame_provenance() -> void:
	var source := FileAccess.get_file_as_string(TRACE_SOURCE_PATH)
	if not _h.expect(not source.is_empty(), "trace_source_unreadable",
			"读不到 %s" % TRACE_SOURCE_PATH):
		return
	_h.expect(source.contains("RenderingServer.frame_post_draw.connect(_on_first_frame)"),
		"t1_not_wired_to_present",
		"T1 没有接到 RenderingServer.frame_post_draw —— 那它就不是「玩家看到了一帧」")

	# The mark must live inside the present handler, not anywhere else.
	var handler_at := source.find("func _on_first_frame() -> void:")
	if not _h.expect(handler_at >= 0, "first_frame_handler_missing",
			"找不到 _on_first_frame 处理器"):
		return
	var handler_end := source.find("\nfunc ", handler_at + 1)
	if handler_end < 0:
		handler_end = source.length()
	var handler_body := source.substr(handler_at, handler_end - handler_at)
	_h.expect(handler_body.contains("mark(T1_FIRST_FRAME)"),
		"t1_not_marked_in_handler",
		"T1 不是在 frame_post_draw 处理器里打的")

	# And nowhere else may emit it. Two emitters means the earlier one wins and the
	# present-based one becomes decorative.
	var occurrences := source.count("mark(T1_FIRST_FRAME)")
	_h.expect(occurrences == 1, "t1_marked_more_than_once",
		("T1_FIRST_FRAME 在 StartupTrace 里被打了 %d 次 —— "
			+ "写入点必须唯一，否则最早的那次赢，present 那次就成了摆设") % occurrences)

	# mark_first_frame() is a public convenience that must not become a second
	# startup-path emitter: if Main called it, T1 would mean "Main ran".
	var main_source := FileAccess.get_file_as_string(MAIN_PATH)
	_h.expect(not main_source.contains("mark_first_frame"),
		"main_marks_first_frame",
		"Main 自己打了 T1 —— 那测的是脚本执行，不是 present")


# `ordering_is_sane()` skips marks that never arrived, so it cannot answer
# "did startup finish". V3 P0-01 wants a missing mark to be visible, not silent.
func _check_missing_marks_are_visible(trace) -> void:
	var missing = trace.missing_ordered_marks()
	_h.expect(missing is Array, "missing_marks_api_broken",
		"missing_ordered_marks() 没有返回数组")
	# T4 is the player's first action; a check scene never performs one, so the
	# spine is legitimately incomplete here. That is exactly what makes this a
	# usable assertion: incomplete must be *reported*, not silently sane.
	_h.expect(not trace.startup_is_complete(),
		"complete_claimed_without_t4",
		"检查场景没有触发 T4，startup_is_complete() 却说完整了")
	_h.expect(trace.ordering_is_sane(),
		"ordering_confused_with_completeness",
		"缺 T4 不应该让顺序判定失败 —— 两个问题必须分开回答")
	_h.expect(missing.has(TraceScript.T4_FIRST_ACTION),
		"missing_mark_not_named",
		"missing_ordered_marks() 没有点名缺失的 T4：%s" % str(missing))


# The first value wins. If a later call could overwrite it, a slow path could be
# made to look fast by marking it twice.
func _check_marks_are_write_once(trace) -> void:
	trace.mark("probe_alpha")
	var first := int(trace.ms_of("probe_alpha"))
	_h.expect(first >= 0, "mark_not_recorded", "mark() 之后 ms_of() 仍是 -1")

	# Burn some real time so an overwrite would be visible rather than coincidental.
	var spin_until := Time.get_ticks_msec() + 12
	while Time.get_ticks_msec() < spin_until:
		pass

	trace.mark("probe_alpha")
	_h.expect(int(trace.ms_of("probe_alpha")) == first,
		"mark_overwritten", "重复 mark() 改写了首次时间戳：%d -> %d" % [first, int(trace.ms_of("probe_alpha"))])

	var timeline: Dictionary = trace.timeline()
	var duplicates: Array = timeline.get("duplicates", [])
	_h.expect(duplicates.has("probe_alpha"),
		"duplicate_not_reported", "重复 mark() 没有被记进 duplicates，问题会静默")
	var order: Array = timeline.get("order", [])
	_h.expect(order.count("probe_alpha") == 1,
		"duplicate_in_order", "重复 mark() 在 order 里出现了 %d 次" % order.count("probe_alpha"))


# t0 is the whole point of the mark: it must be recorded by StartupTrace._ready()
# itself, before that autoload does anything else, or it stops meaning "engine boot".
func _check_engine_boot_mark(trace) -> void:
	_h.expect(trace.has_mark(TraceScript.T0_TRACE_READY),
		"t0_not_marked",
		"StartupTrace._ready() 没有标记 %s —— 引擎启动那段又变回没有测量的黑区"
			% TraceScript.T0_TRACE_READY)
	_h.expect(int(trace.ms_of(TraceScript.T0_TRACE_READY)) >= 0,
		"t0_negative", "t0 时间戳无效")
	_h.expect(str(TraceScript.ORDERED_MARKS[0]) == TraceScript.T0_TRACE_READY,
		"t0_not_first_in_spine", "t0 必须排在 ORDERED_MARKS 首位")

	var source := FileAccess.get_file_as_string("res://scripts/autoload/StartupTrace.gd")
	if not _h.expect(not source.is_empty(), "source_unreadable", "读不到 StartupTrace.gd"):
		return
	var ready_at := source.find("func _ready() -> void:")
	var mark_at := source.find("mark(T0_TRACE_READY", ready_at)
	var build_at := source.find("_load_build_info()", ready_at)
	_h.expect(ready_at >= 0 and mark_at > ready_at,
		"t0_not_in_ready", "t0 不是在 _ready() 里标记的")
	_h.expect(build_at < 0 or mark_at < build_at,
		"t0_after_work",
		"t0 排在 _load_build_info() 之后 —— 读文件的耗时会被算进引擎启动")


func _check_ordering(trace) -> void:
	_h.expect(trace.ordering_is_sane(),
		"ordering_broken", "空/部分时间线不应判为乱序")
	trace.mark(TraceScript.T1_FIRST_FRAME)
	trace.mark(TraceScript.T2_MAIN_READY)
	trace.mark(TraceScript.T3_INPUT_READY)
	_h.expect(trace.ordering_is_sane(),
		"ordering_false_negative", "t1 -> t2 -> t3 顺序正常却被判乱序")
	_h.expect(int(trace.ms_of(TraceScript.T3_INPUT_READY)) >= int(trace.ms_of(TraceScript.T2_MAIN_READY)),
		"ordering_timestamps", "t3 的时间戳早于 t2")


# Release logcat is world-readable on a rooted device and gets pasted into bug
# reports. Timing metadata has no business carrying identity or network detail.
func _check_metadata_is_sanitized(trace) -> void:
	var line := _line_for(trace, "probe_meta", {
		"session_token": "abcd1234",
		"server_address": "203.0.113.7:9000",
		"screen": "language_select",
	})
	if not _h.expect(not line.is_empty(), "meta_line_missing", "拿不到 probe_meta 的日志行"):
		return
	_h.expect(not line.contains("abcd1234"),
		"token_leaked", "token 值出现在启动日志里：%s" % line)
	_h.expect(not line.contains("203.0.113.7"),
		"address_leaked", "服务器地址出现在启动日志里：%s" % line)
	_h.expect(line.contains("language_select"),
		"benign_meta_dropped", "无害的 screen 字段被误删了，字段过滤太宽")


# V3 P0-01: the check above only proves *key-based* redaction -- both its probes use
# key names that are already on the blocklist. A leak under an innocuous key name
# would have sailed through, and "用户路径" was not on that list at all.
#
# So this probes the opposite shape: harmless keys, dangerous values.
func _check_values_are_scrubbed(trace) -> void:
	var line := _line_for(trace, "probe_values", {
		"note": "connecting to 198.51.100.23:9000 now",
		"detail": "restored from user://glory_beta_004.save",
		"win_path": "C:\\Users\\Leno\\Desktop\\Beta 0.04\\save.json",
		"screen": "main_menu",
		"engine": "4.7.stable",
	})
	if not _h.expect(not line.is_empty(), "value_line_missing", "拿不到 probe_values 的日志行"):
		return
	_h.expect(not line.contains("198.51.100.23"),
		"ip_value_leaked",
		"无害键名下的 IP 泄漏到启动日志：%s" % line)
	_h.expect(not line.contains("glory_beta_004.save"),
		"user_path_leaked",
		"user:// 存档路径泄漏到启动日志：%s" % line)
	_h.expect(not line.contains("Leno"),
		"home_dir_leaked",
		"用户主目录名泄漏到启动日志：%s" % line)

	# 断言「被替换了」而不只是「不见了」—— 不见了也可能是整条 mark 被丢掉。
	_h.expect(line.contains(TraceScript.IP_PLACEHOLDER),
		"ip_not_replaced", "IP 没有被占位符替换，可能是整个字段被丢弃了")
	_h.expect(line.contains(TraceScript.PATH_PLACEHOLDER),
		"path_not_replaced", "路径没有被占位符替换，可能是整个字段被丢弃了")

	# 反方向：过滤不能宽到吃掉正常内容。版本号的点分段数不够，不该被当成 IP。
	_h.expect(line.contains("main_menu"),
		"benign_value_dropped", "无害的 screen 值被误删了")
	_h.expect(line.contains("4.7.stable"),
		"version_string_eaten", "版本号被当成 IP 吃掉了，过滤太宽")


# android_smoke.sh pulls these out of logcat with grep and feeds each hit to a JSON
# parser. A payload that wraps across lines loses everything after the break.
func _check_log_line_is_single_line_json(trace) -> void:
	var line := _line_for(trace, "probe_json", {"screen": "prep", "count": 7})
	if not _h.expect(not line.is_empty(), "json_line_missing", "拿不到 probe_json 的日志行"):
		return
	_h.expect(not line.contains("\n"), "json_multiline", "启动日志行里有换行，logcat grep 会截断")
	_h.expect(line.begins_with(TraceScript.LOG_PREFIX + " "),
		"json_prefix", "日志行没有以 %s 开头，无法从 logcat 里筛出来" % TraceScript.LOG_PREFIX)

	var payload_text := line.substr(TraceScript.LOG_PREFIX.length() + 1)
	var parsed: Variant = JSON.parse_string(payload_text)
	if not _h.expect(parsed is Dictionary, "json_unparseable", "载荷不是合法 JSON：%s" % payload_text):
		return
	var payload: Dictionary = parsed
	_h.expect(str(payload.get("mark", "")) == "probe_json",
		"json_mark_field", "载荷里没有正确的 mark 字段")
	_h.expect(payload.has("ms"), "json_ms_field", "载荷里没有 ms 字段")
	# The one number this file must never imply it has.
	_h.expect(str(payload.get("base", "")) == "engine_init",
		"json_base_field", "载荷缺 base=engine_init —— 少了它就会被当成从进程启动起算")


# An autoload nobody calls produces a flawless empty timeline. These are the call
# sites the whole thing rests on.
func _check_call_sites_exist() -> void:
	var source := FileAccess.get_file_as_string(MAIN_PATH)
	if not _h.expect(not source.is_empty(), "main_unreadable", "读不到 %s" % MAIN_PATH):
		return
	_h.expect(source.contains("StartupTrace.mark(StartupTrace.T2_MAIN_READY)"),
		"missing_t2_call", "Main.gd 没有标记 t2_godot_main_ready")
	_h.expect(source.contains("StartupTrace.mark_input_ready"),
		"missing_t3_call", "Main.gd 没有标记 t3_first_input_ready")
	_h.expect(source.contains("StartupTrace.mark_first_action"),
		"missing_t4_call", "Main.gd 没有标记 t4_first_action_complete")


# Autoloads are readied in declaration order. If something is constructed before the
# tracer, the time it costs lands outside every measurement taken here.
func _check_registered_first() -> void:
	var source := FileAccess.get_file_as_string(PROJECT_PATH)
	if not _h.expect(not source.is_empty(), "project_unreadable", "读不到 %s" % PROJECT_PATH):
		return
	var in_autoload := false
	var first_entry := ""
	for raw_line in source.split("\n"):
		var line := str(raw_line).strip_edges()
		if line == "[autoload]":
			in_autoload = true
			continue
		if not in_autoload or line.is_empty():
			continue
		if line.begins_with("["):
			break
		var at := line.find("=")
		if at > 0:
			first_entry = line.substr(0, at)
			break
	_h.expect(first_entry == "StartupTrace",
		"not_first_autoload",
		"[autoload] 的第一项是 %s，不是 StartupTrace —— 排在它前面的自动加载耗时测不到" % first_entry)


# The failure mode worth guarding: a desktop run reporting itself as some build.
# build_info.json is written by tools/android_smoke.sh right before the export, so
# in the editor and in every tools/ check it is simply absent. That must read as
# "no build", never as zeros or the current time.
func _check_build_info_absence_is_honest(trace) -> void:
	var info: Dictionary = trace.build_info()
	_h.expect(info.has("available"), "build_info_no_available_flag",
		"build_info() 没有 available 字段，调用方无法区分「没有构建」和「构建全是 0」")
	if bool(info.get("available", false)):
		# A real build_info.json is present (someone exported into this tree).
		_h.expect(not str(info.get("git_commit", "")).is_empty(),
			"build_info_commit_empty", "build_info 声称可用却没有 git_commit")
		# JSON gives back floats; an identity field printed as "v5.0" will not match
		# the "5" that dumpsys and export_presets report.
		for int_key in ["schema_version", "dirty_tracked_files", "version_code"]:
			if info.has(int_key):
				_h.expect(typeof(info[int_key]) == TYPE_INT,
					"build_info_float_id",
					"build_info 的 %s 是浮点（%s）—— 会显示成 5.0，和 dumpsys/预设对不上"
						% [int_key, str(info[int_key])])
		return
	_h.expect(not str(info.get("reason", "")).is_empty(),
		"build_info_no_reason", "build_info 不可用时必须给出原因")
	for forbidden in ["git_commit", "version_code", "package_id", "build_utc"]:
		_h.expect(not info.has(forbidden),
			"build_info_fabricated",
			"build_info 不可用却仍带 %s —— 那会被读成一个真实构建" % forbidden)
	var label := str(trace.build_info_label())
	_h.expect(label.contains("?"),
		"build_label_pretends", "没有构建时角标应明确显示未知，实际是 %s" % label)


# The build line has to survive the same logcat grep as the marks.
func _check_build_info_line(trace) -> void:
	var source := FileAccess.get_file_as_string("res://scripts/autoload/StartupTrace.gd")
	_h.expect(source.contains("_load_build_info()"),
		"build_info_not_loaded", "StartupTrace._ready() 没有读取 build_info")

	trace._emit_build_line()
	var line := str(trace.last_line())
	if not _h.expect(not line.is_empty(), "build_line_missing", "拿不到 GLORY_BUILD 行"):
		return
	_h.expect(not line.contains("\n"), "build_line_multiline", "GLORY_BUILD 行里有换行")
	_h.expect(line.begins_with(TraceScript.BUILD_LOG_PREFIX + " "),
		"build_line_prefix", "GLORY_BUILD 行前缀不对，logcat 筛不出来")
	var parsed: Variant = JSON.parse_string(line.substr(TraceScript.BUILD_LOG_PREFIX.length() + 1))
	_h.expect(parsed is Dictionary, "build_line_unparseable", "GLORY_BUILD 载荷不是合法 JSON")


# V2 P1-11 / V3 P1-07: the FPS corner must not be hardcoded on. It shipped that way,
# which is why a release build drew "FPS 110-121" over the prep screen.
func _check_overlay_is_build_gated() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/prep/PrepScreen.gd")
	if not _h.expect(not source.is_empty(), "prep_unreadable", "读不到 PrepScreen.gd"):
		return
	_h.expect(not source.contains("SHOW_FPS_OVERLAY := true"),
		"overlay_hardcoded_on", "PrepScreen 又把调试角标硬写成常开")
	_h.expect(source.contains("OS.is_debug_build()"),
		"overlay_not_build_gated", "调试角标没有按构建类型开关")
	_h.expect(source.contains("StartupTrace.build_info_label()"),
		"overlay_missing_identity",
		"QA 角标只显示 FPS —— 真机报告最缺的是「这是哪个包」，不是帧率")


# `pm install` can print Success immediately before the adb transport drops. A
# previous revision logged `install ok` at that point and then discovered that the
# old package was still installed. versionCode is not enough because QA builds
# intentionally reuse it, so the device's base.apk must match the local APK hash.
func _check_android_install_identity_contract() -> void:
	var source := FileAccess.get_file_as_string("res://tools/android_smoke.sh")
	if not _h.expect(not source.is_empty(), "android_smoke_unreadable", "读不到 android_smoke.sh"):
		return

	var transport_at := source.find("if _wait_transport; then")
	var verified_note_at := source.find("install verified via on-device APK sha256")
	_h.expect(transport_at >= 0, "install_transport_gate_missing",
		"android_smoke.sh 没有等待安装后的 adb 通道恢复")
	_h.expect(verified_note_at > transport_at, "install_verified_too_early",
		"安装成功仍在设备通道恢复与身份核验之前宣布")
	_h.expect(not source.contains("note \"install ok via $INSTALL_METHOD\""),
		"install_ok_from_pm_output",
		"脚本又把 pm install 的 Success 直接写成 install ok，可能测到旧包")
	_h.expect(source.contains("^Success([[:space:](]|$)"),
		"install_success_match_not_anchored",
		"安装日志成功匹配没有锚定 PackageManager 的 Success 行")
	_h.expect(not source.contains("grep -qi 'Success'"),
		"install_success_match_too_broad",
		"宽泛 Success 匹配会把 adb 的 daemon started successfully 当成安装成功")
	_h.expect(source.contains("INSTALLED_APK_SHA") and source.contains("= \"$APK_SHA\""),
		"installed_apk_hash_not_compared",
		"设备 base.apk SHA-256 没有与本地 APK_SHA 比较")
	_h.expect(source.contains("installed_apk_hash_mismatch"),
		"installed_apk_hash_mismatch_not_fatal",
		"设备与本地 APK 哈希不一致时没有明确失败码")
	_h.expect(source.contains("\"installed_apk_sha256\""),
		"installed_apk_hash_missing_from_evidence",
		"smoke.json 没保存设备 APK 哈希，事后无法审计")
	_h.expect(source.contains("\"identity_verified\""),
		"install_identity_verdict_missing",
		"smoke.json 没有安装身份核验结论")


# Returns the line the tracer actually emitted for this mark, not a reconstruction:
# re-deriving it here would assert that the test can format JSON, which is not the
# thing that has to keep working.
func _line_for(trace, mark_name: String, meta: Dictionary = {}) -> String:
	trace.mark(mark_name, meta)
	return str(trace.last_line())


# V3 P0-01 §5.2: a startup report has to be attributable and actionable.
#
# The absolute marks answer "how long"; they do not answer "which segment", and a
# `verdict: reported_only` line does not answer "by how much did it miss". Both of
# those are what someone reads the report to find out, so the script must emit them
# and this asserts it keeps doing so.
#
# The cache condition matters because comparing a warm-cache launch against a cold
# budget is not a comparison. This script force-stops the process but cannot drop the
# page cache, so the honest label is warm_after_force_stop -- calling it "cold" would
# make the T1 number look better than the thing it is supposed to measure.
func _check_android_startup_report_contract() -> void:
	var source := FileAccess.get_file_as_string(ANDROID_SMOKE_PATH)
	if not _h.expect(not source.is_empty(), "android_smoke_unreadable_startup",
			"读不到 android_smoke.sh"):
		return

	for field in ["segments_ms", "over_budget_ms", "cache_condition"]:
		_h.expect(source.contains("\"%s\"" % field),
			"startup_report_field_missing",
			"smoke.json 的 startup 块缺 %s —— 报告答不出「哪一段」或「超了多少」" % field)

	for segment in ["t0_to_t1", "t1_to_t2", "t2_to_t3"]:
		_h.expect(source.contains("\"%s\"" % segment),
			"startup_segment_missing", "分段耗时缺 %s" % segment)

	# 超预算差值必须在 --assert-startup 之外也算。否则「当前不通过就保持关闭」
	# 会退化成「什么都不说」，读的人还得自己去减。
	var assert_at := source.find("if [ \"$ASSERT_STARTUP\" -eq 1 ]")
	var over_at := source.find("T1_OVER_MS=\"$(over ")
	_h.expect(over_at >= 0 and assert_at >= 0 and over_at < assert_at,
		"over_budget_computed_only_when_asserting",
		"超预算差值是在 --assert-startup 分支里算的 —— 关闭时报告就不说超了多少")

	# 断言**赋值**而不是「文件里出现过这个词」。
	# 第一版写成 `source.contains("warm_after_force_stop")`，结果把赋值改成 "cold"
	# 之后断言照样通过 —— 因为那个词还留在同一文件的 note 说明里。
	# 自己的反向变异抓到了这条不可证伪的断言，改成盯赋值行。
	_h.expect(source.contains("CACHE_CONDITION=\"warm_after_force_stop\""),
		"cache_condition_overclaimed",
		("CACHE_CONDITION 的赋值不是 warm_after_force_stop —— 本脚本只 force-stop 进程，"
			+ "清不掉 page cache，标成 cold 会让 T1 与预算的比较失去意义"))
