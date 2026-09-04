extends Node

# V3 P1-04 门禁：按钮的确认音与触觉。
#
# ## 这条门禁验什么、不验什么
#
# **不验发声。** 仓里一个 UI 音效素材都没有，音频许可本身还是未闭环的
# blocker，本批刻意只搭管线不放音（见 ui/services/UiFeedback.gd 的抬头）。
# 而且 headless 用的是 Dummy 音频驱动，就算有素材也听不见。
# 所以这里验的是**裁决与次数**：该不该播、播了几次。
#
# 「12 ms 的震动在真机上能不能感觉到」「权限有没有真的进 APK」都是
# external，写在交接里，不在这里假装验过。
#
# ## 一次点击只发一次 —— 靠锚点，不靠事后去重
#
# 确认反馈只接 AsyncActionController.action_resolved。`_resolve()` 只在
# 「找得到这个 request_id」**且**「它的状态属于 ACTIVE_STATES」时才发信号，
# 其余路径记面包屑后返回 false。所以一个 request_id 最多产生一次
# action_resolved —— 这是结构上的保证，不是一个 bool 标志位。
#
# 反例就在仓里：PrepScreen._input() 用 if/elif 同时处理 InputEventMouseButton
# 与 InputEventScreenTouch，两条路之间没有任何去重。今天无害（关面板是幂等的），
# 但只要把播音挂进去，Android 上一次触摸就会响两次 —— 而
# **在 Windows 开发机上完全看不出来**，桌面只有鼠标那一路会来。
# 这种「桌面正常、真机翻倍」的不对称正是它必须机械化成规则、
# 而不能靠人 review 的原因。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/ui_feedback_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Feedback := preload("res://ui/services/UiFeedback.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

const CHECK_NAME := "ui_feedback"

# 「不许在输入回调里调反馈」这条规则的扫描范围。
const SCAN_ROOTS: Array[String] = [
	"res://scenes", "res://scripts", "res://ui", "res://effects",
]
const INPUT_HANDLERS: Array[String] = [
	"func _input(", "func _unhandled_input(", "func _gui_input(",
	"func _shortcut_input(", "func _unhandled_key_input(",
]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_bus_layout()
	_check_confirm_fires_once()
	_check_confirm_respects_toggle()
	_check_no_haptics_on_desktop()
	_check_vibrate_has_single_call_site()
	_check_feedback_not_called_from_input_handlers()
	_check_main_installs_feedback()
	_h.finish(get_tree())


# --- 总线 -------------------------------------------------------------------

func _check_bus_layout() -> void:
	_h.expect(AudioServer.get_bus_index(Feedback.SFX_BUS) >= 0,
		"sfx_bus_missing",
		"没有 %s 总线 —— default_bus_layout.tres 没被 project.godot 注册？"
			% Feedback.SFX_BUS)

	# 刻意**没有** Music 总线：四处 BGM 代码写的是
	# `bus = "Music" if get_bus_index("Music") >= 0 else "Master"`，
	# 加一条 Music 会让它们同时改走一条从没调过音量的总线。
	# 这不是疏忽，是这一批不做的事，所以钉住它，别让谁「顺手补上」。
	_h.expect(AudioServer.get_bus_index("Music") < 0,
		"music_bus_added_silently",
		"多了一条 Music 总线 —— 四处 BGM 会同时改走它，那是独立的一件事，"
			+ "不该混在按钮反馈里")


# --- 一次解决 = 一次确认 -----------------------------------------------------

func _check_confirm_fires_once() -> void:
	Feedback.install()
	Feedback.install()  # 幂等：连两次也只能连上一条
	_reset()

	var request_id := AsyncActionController.begin("ui_feedback_check",
		{"control_id": "check/confirm_once", "timeout_msec": 5000})
	_h.expect(not str(request_id).is_empty(), "begin_returned_empty",
		"AsyncActionController.begin() 没有返回 request_id，后面的断言无从谈起")
	AsyncActionController.succeed(request_id)
	_h.expect(Feedback.confirm_request_count() == 1,
		"confirm_not_played_once",
		"业务成功之后确认反馈发了 %d 次，应该是 1 次"
			% Feedback.confirm_request_count())

	# 同一个 request_id 再解决五次：_resolve() 找不到活动条目，一次都不该再发。
	# 玩家侧对应的是「点了没反应就连点」。
	for _i in 5:
		AsyncActionController.succeed(request_id)
	_h.expect(Feedback.confirm_request_count() == 1,
		"confirm_played_more_than_once",
		"重复解决同一个 request_id 之后确认反馈累计发了 %d 次"
			% Feedback.confirm_request_count())

	# 失败不该播确认音。「确认」这个词是有含义的：业务没成，别给玩家一个成了的信号。
	_reset()
	var failed_id := AsyncActionController.begin("ui_feedback_check",
		{"control_id": "check/confirm_fail", "timeout_msec": 5000})
	AsyncActionController.fail(failed_id, "check_forced_failure")
	_h.expect(Feedback.confirm_request_count() == 0,
		"confirm_played_on_failure",
		"业务失败之后仍然播了 %d 次确认反馈" % Feedback.confirm_request_count())


func _check_confirm_respects_toggle() -> void:
	var before: bool = PlayerProfile.get_presentation_toggle("ui_sound")
	PlayerProfile.set_presentation_toggle("ui_sound", false)
	_reset()
	var request_id := AsyncActionController.begin("ui_feedback_check",
		{"control_id": "check/confirm_muted", "timeout_msec": 5000})
	AsyncActionController.succeed(request_id)
	_h.expect(Feedback.confirm_request_count() == 0,
		"confirm_ignores_sound_toggle",
		"界面音效开关已关，确认反馈仍然通过了裁决 %d 次"
			% Feedback.confirm_request_count())
	PlayerProfile.set_presentation_toggle("ui_sound", before)


func _check_no_haptics_on_desktop() -> void:
	if OS.get_name() in ["Android", "iOS"]:
		_h.note("本次在手持设备上运行，跳过「桌面不震」的断言")
		return
	var before: bool = PlayerProfile.get_presentation_toggle("haptics")
	PlayerProfile.set_presentation_toggle("haptics", true)
	_reset()
	var request_id := AsyncActionController.begin("ui_feedback_check",
		{"control_id": "check/haptic_desktop", "timeout_msec": 5000})
	AsyncActionController.succeed(request_id)
	# 开关是开的、业务也成功了 —— 唯一该拦住它的是平台判断。
	_h.expect(Feedback.vibrate_call_count() == 0,
		"haptic_fired_on_desktop",
		"桌面上调用了 %d 次 Input.vibrate_handheld()" % Feedback.vibrate_call_count())
	PlayerProfile.set_presentation_toggle("haptics", before)


# --- 源码合同 ---------------------------------------------------------------

# 震动只能有一个调用点。
#
# 散落的 vibrate 调用绕过 haptics_allowed()，玩家关掉开关照样震 —— 而这种
# 缺陷在桌面上永远复现不了。
#
# 扫的是**去掉注释之后的代码**。第一版没去注释，被
# PresentationSettings.gd 里一句「Input.vibrate_handheld() 在桌面是 no-op」
# 的注释判成了违规 —— 和「整文件 contains 被自己写的注释满足」是同一个坑，
# 只是方向反过来：注释这次制造的是假红。规则要指着代码形状。
func _check_vibrate_has_single_call_site() -> void:
	var callers: Array[String] = []
	for root in SCAN_ROOTS:
		for path in _gd_files(root):
			var src := _code_only(FileAccess.get_file_as_string(path))
			if src.contains("Input.vibrate_handheld("):
				callers.append(path)
	callers.sort()
	_h.expect(callers == ["res://ui/services/UiFeedback.gd"],
		"vibrate_called_outside_feedback",
		"Input.vibrate_handheld() 只能由 UiFeedback 调用，实测调用方：%s"
			% str(callers))


# 反馈不得从任何输入回调里调用。
#
# 限定到**函数体**，不做整文件 contains —— 整文件 contains 会被文件自己写的
# 注释满足，这一轮已经栽过三次。
func _check_feedback_not_called_from_input_handlers() -> void:
	var offenders: Array[String] = []
	for root in SCAN_ROOTS:
		for path in _gd_files(root):
			var src := _code_only(FileAccess.get_file_as_string(path))
			if not src.contains("UiFeedback"):
				continue
			for handler in INPUT_HANDLERS:
				for body in _function_bodies(src, handler):
					if body.contains("UiFeedback"):
						offenders.append("%s %s" % [path, handler])
	_h.expect(offenders.is_empty(),
		"feedback_called_from_input_handler",
		("反馈被挂进了输入回调：%s —— Android 上 mouse+touch 双路会让它发两次，"
			+ "而在 Windows 上看不出来") % str(offenders))


# Main 必须真的调 install()。
#
# 运行时那几条断言是门禁自己调 install() 之后测的，证明的是 install() 本身
# 正确；「有没有人在生产路径上调它」得另外钉。限定在 _ready 的函数体内。
func _check_main_installs_feedback() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	var bodies := _function_bodies(src, "func _ready(")
	_h.expect(bodies.size() == 1, "main_ready_not_found",
		"在 Main.gd 里找到 %d 个 _ready —— 下面的断言可能已失效" % bodies.size())
	var body := "" if bodies.is_empty() else bodies[0]
	_h.expect(body.contains("UiFeedbackService.install()"),
		"main_does_not_install_feedback",
		"Main._ready() 没有调 UiFeedbackService.install() —— 确认反馈整条链是断的")


# --- 工具 -------------------------------------------------------------------

func _reset() -> void:
	Feedback.reset_counters_for_check()


# 去掉行注释。字符串里的 # 不能算 —— 状态机跟着引号走，别用正则。
func _code_only(source: String) -> String:
	var out: Array[String] = []
	for raw in source.split("
"):
		var line := str(raw)
		var quote := ""
		var cut := -1
		for i in line.length():
			var ch := line[i]
			if not quote.is_empty():
				if ch == quote and (i == 0 or line[i - 1] != "\\"):
					quote = ""
				continue
			if ch == "\"" or ch == "'":
				quote = ch
				continue
			if ch == "#":
				cut = i
				break
		out.append(line if cut < 0 else line.substr(0, cut))
	return "
".join(out)


func _gd_files(root: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := root.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				out.append_array(_gd_files(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


# 一个文件里可能有多个同名回调（不同内部类），全部收上来。
func _function_bodies(source: String, signature: String) -> Array[String]:
	var out: Array[String] = []
	if source.is_empty():
		return out
	var current: Array[String] = []
	var inside := false
	for raw in source.split("\n"):
		var line := str(raw)
		if not inside:
			if line.begins_with(signature):
				inside = true
				current = [line]
			continue
		# 顶格且非空 = 函数体结束（GDScript 的函数体一定有缩进）
		if not line.is_empty() and not line.begins_with("\t") and not line.begins_with(" "):
			out.append("\n".join(current))
			inside = false
			continue
		current.append(line)
	if inside:
		out.append("\n".join(current))
	return out
