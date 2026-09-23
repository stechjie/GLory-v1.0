extends Node

# V3 P1-04 门禁：按钮的确认音与触觉。
#
# ## 这条门禁验什么、不验什么
#
# **不验发声。** 这条门禁管的是**裁决与次数**：该不该播、播了几次。
# 而且 headless 用的是 Dummy 音频驱动，就算有素材也听不见。
#
# 2026-09-17 更新：当时「仓里一个 UI 音效素材都没有、本批刻意只搭管线不放音」
# 的前置条件**已经不成立** —— 24 条 SFX 已落盘并接线，确认音与拒绝音都走
# `ui/services/SfxService.gd`。本文件仍然**不验发声**，改的是另一条门禁：
# 「素材在不在、每条 cue 有没有生产调用点、静音门生不生效、金币收支响得对不对」
# 归 `tools/audio_sfx_check.gd`（96 项）。两边分工是有意的：
# 这里验「该不该发」，那边验「有没有东西可发、发出来的门生不生效」。
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
const SfxService := preload("res://ui/services/SfxService.gd")
const Toast := preload("res://ui/components/GloryToast.gd")
const ModalStackScript := preload("res://ui/services/ModalStack.gd")
const ProviderScript := preload("res://scripts/tutorial/TutorialTargetProvider.gd")
const DisabledReason := preload("res://ui/components/GloryDisabledReason.gd")
const BusyButtonScene := preload("res://ui/components/GloryBusyButton.tscn")
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
	_check_vibrate_permission()
	await _check_toast()
	await _check_reject()
	_check_gold_rejections_speak()
	await _check_disabled_reason()
	# 收尾：9.17 起确认音/拒绝音都走 SfxService，这一跑会真的建出播放器池。
	# 拆掉它能把「Node / 流缓存」那部分收干净；混音线程持有的 AudioStreamPlayback
	# 仍偶发残留（详见 SfxService.shutdown），那部分不影响 CHECK_RESULT。
	SfxService.shutdown()
	_h.finish(get_tree())


# --- 总线 -------------------------------------------------------------------

func _check_bus_layout() -> void:
	# project.godot 里**没有** [audio] 段，这是对的，不是漏了：
	# audio/buses/default_bus_layout 的引擎默认值就是
	# "res://default_bus_layout.tres"，Godot 重写 project.godot 时会把停留在
	# 默认值的设置删掉。第一版显式写了那一行，跑一次就被引擎抹掉了 ——
	# 别再照着「怎么没注册」把它加回去。总线到底在不在，以这条断言为准。
	_h.expect(AudioServer.get_bus_index(Feedback.SFX_BUS) >= 0,
		"sfx_bus_missing",
		"没有 %s 总线 —— default_bus_layout.tres 里的 bus/1/name 改了？"
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

	# **显式建立前置条件：开关开 + Master 没静音。**
	#
	# 不能指望「环境里本来就是开的」—— `ui_sound` 是落盘持久化的
	# （PlayerProfile.save_profile），**上一跑的收尾状态就是这一跑的初值**。
	# 9.17 实测：磁盘里留着 `ui_sound_enabled=false`（某次收尾没走到还原），
	# 于是这里「成功该发一次」的两条断言红；而更糟的是
	# `_check_confirm_respects_toggle` 里「关掉就不发」那条**空过**——
	# 一个恒不发声的实现同样能绿。这是本仓栽过的
	# 「断言被前置条件满足」的又一种形态，只不过前置来自磁盘不是来自注释。
	#
	# 下面的 `_check_no_haptics_on_desktop` 就是显式建前置的写法，这里补齐同款。
	var sound_before: bool = PlayerProfile.get_presentation_toggle("ui_sound")
	var master := AudioServer.get_bus_index("Master")
	var mute_before: bool = AudioServer.is_bus_mute(master) if master >= 0 else false
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	if master >= 0:
		AudioServer.set_bus_mute(master, false)
	_h.expect(Presentation.ui_sound_allowed(), "ui_sound_precondition_failed",
		"开关开着、Master 总线没静音，ui_sound_allowed() 却是 false —— 下面几条断言无从谈起")

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

	# 还原现场。还原成 `before` 而不是硬写成 true：门禁不该改写玩家的偏好，
	# 上面那几条断言要的只是「这一刻是开的」。
	PlayerProfile.set_presentation_toggle("ui_sound", sound_before)
	if master >= 0:
		AudioServer.set_bus_mute(master, mute_before)


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


# VIBRATE 权限必须在**受 git 跟踪的模板**里请求。
#
# export_presets.cfg 本身进不了 git（export_presets_check 自己有一条断言守着
# 它保持被忽略），所以这里只能证明模板请求了这个权限。漂移由
# export_presets_check._check_no_drift 负责：两个文件不一致会转红。
#
# **但这两条加起来仍然证明不了导出的 APK 真的带上了这个权限** ——
# 在一台从没同步过 live cfg 的机器上导出就是没有，CI 也看不见。
# 那一半是 external，写在交接里，不在这里假装验过。
#
# 只查 drift 不够：模板和 live 一起被重新生成回 false 时 drift 仍然是 0。
# 所以要一条正向断言。按行首匹配，不用整文件 find —— 本文件自己的注释里
# 就写着 permissions/vibrate，整文件 find 会匹配到检查器自己。
func _check_vibrate_permission() -> void:
	var src := FileAccess.get_file_as_string("res://export_presets.template.cfg")
	var found := false
	for raw in src.split("
"):
		if str(raw).strip_edges().begins_with("permissions/vibrate="):
			found = str(raw).strip_edges() == "permissions/vibrate=true"
			break
	_h.expect(found, "vibrate_permission_not_requested",
		"export_presets.template.cfg 没有请求 VIBRATE 权限 —— 触觉在真机上永远不会响")


# --- Toast ------------------------------------------------------------------

func _check_toast() -> void:
	# 层级必须压过模态栈。拒绝动作**就发生在**打开的模态里 ——
	# 原因盖在模态底下等于没写。留出的余量是给栈深的（BASE_LAYER + i）。
	_h.expect(Toast.TOAST_LAYER > ModalStackScript.BASE_LAYER + 16,
		"toast_below_modals",
		"toast 层 %d 不够高，模态栈基线是 %d —— 模态里的拒绝原因会被盖住"
			% [Toast.TOAST_LAYER, ModalStackScript.BASE_LAYER])

	Toast.dismiss()
	await get_tree().process_frame
	Toast.reset_counters_for_check()

	_h.expect(Toast.show_text("门禁提示 A"), "toast_show_returned_false",
		"GloryToast.show_text() 返回 false —— 后面的断言无从谈起")
	await get_tree().process_frame
	_h.expect(Toast.shown_count() == 1 and Toast.last_text() == "门禁提示 A",
		"toast_not_shown",
		"show_text 之后计数=%d、文本=%s" % [Toast.shown_count(), Toast.last_text()])
	_h.expect(Toast.is_showing(), "toast_not_visible",
		"show_text 之后 is_showing() 仍然是 false")

	# 挂在 current_scene 而不是 root：页面切换时 Main._clear() 会释放自己所有
	# 子节点，层和计时器一起没。挂 root 上就会跨页面残留。
	var layer := get_tree().current_scene.get_node_or_null(Toast.LAYER_NAME)
	_h.expect(layer != null, "toast_not_parented_to_scene",
		"toast 层没挂在 current_scene 下 —— 页面切换时不会被回收")

	# 连点只能替换，不能堆叠：屏幕上永远只有一条。
	for i in 5:
		Toast.show_text("门禁提示 %d" % i)
	await get_tree().process_frame
	# 按**层号**数，不按名字。
	#
	# 名字这条路走不通：add_child 遇到重名兄弟会自动改成
	# "@GloryToastLayer@2" —— 前缀是 @，所以精确相等和 begins_with 都数不到
	# 第二层，断言会永远是绿的。两种写法都实测过，记在这里免得再绕一圈。
	var layers := 0
	for child in get_tree().current_scene.get_children():
		if child is CanvasLayer and (child as CanvasLayer).layer == Toast.TOAST_LAYER:
			layers += 1
	_h.expect(layers == 1, "toast_stacks",
		"连发 6 条之后屏幕上有 %d 层 toast" % layers)
	_h.expect(Toast.last_text() == "门禁提示 4", "toast_text_not_replaced",
		"重复显示之后文本停在 %s" % Toast.last_text())

	Toast.dismiss()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(not Toast.is_showing(), "toast_not_dismissed",
		"dismiss() 之后 is_showing() 仍然是 true")

	# 教学反馈在备战页之外也必须看得见。
	#
	# 此前 show_feedback() 只是对 _feedback 的转发，而唯一的生产绑定在
	# PrepUI 里，所以出了备战页一律 return false、什么都不显示。
	Toast.reset_counters_for_check()
	var provider = ProviderScript.new()
	var shown: bool = provider.show_feedback("门禁：未绑定回调时的教学反馈")
	await get_tree().process_frame
	_h.expect(shown and Toast.shown_count() == 1,
		"tutorial_feedback_silent_without_binding",
		"没有绑定 _feedback 时教学反馈静默失效了（返回 %s，toast 计数 %d）"
			% [str(shown), Toast.shown_count()])
	Toast.dismiss()
	await get_tree().process_frame


# --- 拒绝动作 ---------------------------------------------------------------

func _check_reject() -> void:
	var shake_before: bool = PlayerProfile.get_presentation_toggle("screen_shake")
	# ★★ 9.23 第五批：`screen_shake` **不是唯一的门**。
	#
	# `UiFeedback.shake()` 里还有一道：`Tokens.reduced_motion()`（设置页的
	# 「降低动态效果」）为真时把幅度直接归零、返回 false。这条检查只快照了
	# `screen_shake`，于是**凡是把「降低动态效果」开着的机器上它必红**
	# ——本批实测：`user://profile.json` 里 `reduced_motion_enabled=true`，
	# 唯一那条失败就是 `shake_did_not_start`，看起来像产品回归，其实是环境。
	#
	# 更要紧的是**它同时制造了一批假绿**：`shake()` 提前返回 false 时不建 tween、
	# 不动控件，于是下面 `shake_does_not_restore_rotation` /
	# `shake_does_not_restore_pivot` / `shake_leaks_tracking` 三条全部「通过」——
	# 什么都没抖，当然什么都没坏。真出了「抖完不回原值」的 bug 也照样绿。
	#
	# 门禁不许依赖「自己没管过的持久化状态」：把两个开关都纳入快照，
	# 测抖动那一段强制关掉 reduced_motion，收尾老实还原。
	var motion_before: bool = PlayerProfile.get_presentation_toggle("reduced_motion")
	PlayerProfile.set_presentation_toggle("reduced_motion", false)
	var host := Control.new()
	host.size = Vector2(200, 56)
	add_child(host)
	var btn := Button.new()
	btn.size = Vector2(200, 56)
	# 故意给一个非零的初始变换：还原必须回到**这个值**，不是回到 0。
	# 「抖完设成 0」是这类实现最经典的写法，也最经典地错。
	btn.rotation = 0.21
	btn.pivot_offset = Vector2(7, 9)
	host.add_child(btn)
	await get_tree().process_frame

	PlayerProfile.set_presentation_toggle("screen_shake", true)
	Toast.reset_counters_for_check()
	Feedback.reset_counters_for_check()

	_h.expect(Feedback.shake(btn), "shake_did_not_start",
		"屏震开着，shake() 却返回 false")
	# 重入：连点五次。原值必须始终取第一次存下的那份，
	# 否则每抖一次就把「抖到一半的角度」当成新的原值，控件会越歪越远。
	for _i in 5:
		Feedback.shake(btn)
	await get_tree().create_timer(Feedback.SHAKE_SEC + 0.35).timeout
	_h.expect(is_equal_approx(btn.rotation, 0.21),
		"shake_does_not_restore_rotation",
		"抖完之后 rotation=%.4f，应该回到 0.2100" % btn.rotation)
	_h.expect(btn.pivot_offset.is_equal_approx(Vector2(7, 9)),
		"shake_does_not_restore_pivot",
		"抖完之后 pivot_offset=%s，应该回到 (7, 9)" % str(btn.pivot_offset))
	_h.expect(Feedback.shake_tracked_count() == 0, "shake_leaks_tracking",
		"抖完之后还有 %d 个控件留在记账里" % Feedback.shake_tracked_count())

	# 进入「关掉屏震」这一段之前先把控件摆回已知状态。
	#
	# 不这么做的话，上一段没还原干净的 pivot 会漏进来，把
	# shake_moved_control_when_off 也一起弄红 —— 两条断言看起来就像同一条。
	# 每条断言只该为自己那一段负责。
	btn.rotation = 0.21
	btn.pivot_offset = Vector2(7, 9)

	# 关掉屏震：不抖，但**原因照样要说**。
	# 抖动是吸引注意力的通道，原因文字是可达性通道，后者不能被前者的开关关掉。
	PlayerProfile.set_presentation_toggle("screen_shake", false)
	Toast.reset_counters_for_check()
	_h.expect(not Feedback.shake(btn), "shake_ignores_toggle",
		"屏震已关，shake() 仍然返回 true")
	Feedback.reject(btn, "门禁：拒绝原因")
	await get_tree().process_frame
	_h.expect(Toast.shown_count() == 1 and Toast.last_text() == "门禁：拒绝原因",
		"reject_reason_lost_with_shake_off",
		"屏震关掉之后拒绝原因也没了：计数 %d、文本 %s"
			% [Toast.shown_count(), Toast.last_text()])
	# rotation 和 pivot 都要查：只查 rotation 的话，「在开关判断之前就把
	# pivot 改掉」这种写法能溜过去 —— 那已经动了别人的状态。
	_h.expect(is_equal_approx(btn.rotation, 0.21)
			and btn.pivot_offset.is_equal_approx(Vector2(7, 9)),
		"shake_moved_control_when_off",
		"屏震已关，控件却被动过：rotation=%.4f pivot=%s"
			% [btn.rotation, str(btn.pivot_offset)])

	PlayerProfile.set_presentation_toggle("screen_shake", shake_before)
	# 两个开关都要还原。**只还原 screen_shake 是本条检查原来那个坑的另一半**：
	# 留着 reduced_motion=false 不动，就是把「降低动态效果」这个无障碍偏好
	# 悄悄改掉 —— 后面的门禁、乃至用户下次进设置页看到的状态都跟着变。
	PlayerProfile.set_presentation_toggle("reduced_motion", motion_before)
	_h.expect(PlayerProfile.get_presentation_toggle("reduced_motion") == motion_before,
		"reduced_motion_not_restored",
		"这条检查改过「降低动态效果」却没还原回 %s —— 会毒到后面跑的门禁" % str(motion_before))
	Toast.dismiss()
	host.queue_free()
	await get_tree().process_frame


# 买不起必须有话说。
#
# 这是本轮排查里最刺眼的一处不一致：同一个「金币不够」，走商店面板会提示
# （ShopPanel 发 ui_not_enough_gold），走拖拽购买 / 雇佣佣兵 / 刷新商店则
# 一声不吭 —— 而且静默 return 的**上面两行**就是会提示的 toast_unique_limit
# 和 toast_board_full。玩家看到的是「拖过去，弹回来，没有任何解释」。
#
# 写成穷举规则而不是逐点断言：下一个人再加一处 `gold < cost: return`
# 时要当场红，而不是等下一次复审再发现。
func _check_gold_rejections_speak() -> void:
	var src := _code_only(FileAccess.get_file_as_string(
		"res://scenes/prep/PrepBoardController.gd"))
	var lines := src.split("
")
	var silent: Array[String] = []
	var total := 0
	for i in lines.size():
		var line := str(lines[i])
		if not line.strip_edges().begins_with("if GameState.gold <"):
			continue
		total += 1
		# 往下看，直到缩进回到 if 这一层为止。
		var indent := line.length() - line.lstrip("	").length()
		var speaks := false
		for j in range(i + 1, mini(i + 8, lines.size())):
			var body := str(lines[j])
			if body.strip_edges().is_empty():
				continue
			var body_indent := body.length() - body.lstrip("	").length()
			if body_indent <= indent:
				break
			if body.contains("show_message(") or body.contains("reject("):
				speaks = true
				break
		if not speaks:
			silent.append("第 %d 行" % (i + 1))
	_h.expect(total > 0, "gold_guard_not_found",
		"PrepBoardController 里一处 `if GameState.gold <` 都没找到 —— 断言可能已失效")
	_h.expect(silent.is_empty(), "gold_rejection_is_silent",
		"金币不足时一声不吭的分支：%s（共 %d 处金币判断）" % [str(silent), total])


# --- 禁用态可以问原因 --------------------------------------------------------

func _check_disabled_reason() -> void:
	var btn := Button.new()
	btn.size = Vector2(160, 48)
	btn.disabled = true
	add_child(btn)
	var business := {"pressed": 0}
	btn.pressed.connect(func(): business["pressed"] += 1)
	DisabledReason.attach(btn, "门禁：正在处理中")
	await get_tree().process_frame

	Toast.reset_counters_for_check()
	_send(btn, _mouse(true))
	_send(btn, _mouse(false))
	await get_tree().process_frame
	_h.expect(Toast.shown_count() == 1,
		"disabled_button_gives_no_reason",
		"点了禁用按钮之后 toast 计数是 %d，应该正好 1" % Toast.shown_count())
	_h.expect(Toast.last_text() == "门禁：正在处理中",
		"disabled_reason_text_wrong",
		"禁用原因显示成了 %s" % Toast.last_text())
	# 解释归解释，业务绝不能被触发 —— 那才是「禁用」这两个字的含义。
	_h.expect(int(business["pressed"]) == 0, "disabled_button_runs_business",
		"点禁用按钮触发了 %d 次业务" % int(business["pressed"]))

	# 一次点击只能出一条。按下和松开是两个事件，两个都认就会弹两条；
	# Android 上还会再来一路模拟鼠标事件。
	Toast.reset_counters_for_check()
	_send(btn, _touch(true))
	_send(btn, _touch(false))
	await get_tree().process_frame
	_h.expect(Toast.shown_count() == 1, "disabled_reason_fires_twice_per_tap",
		"一次触摸出了 %d 条原因" % Toast.shown_count())

	# 清掉之后不再解释。
	DisabledReason.clear(btn)
	Toast.reset_counters_for_check()
	_send(btn, _mouse(true))
	_send(btn, _mouse(false))
	await get_tree().process_frame
	_h.expect(Toast.shown_count() == 0, "disabled_reason_not_cleared",
		"clear() 之后还在解释，出了 %d 条" % Toast.shown_count())
	btn.queue_free()

	# GloryBusyButton：全游戏最常被点的禁用按钮。
	var busy := BusyButtonScene.instantiate()
	add_child(busy)
	await get_tree().process_frame
	busy.show_pending("check_req", "正在连接")
	_h.expect(busy.disabled, "busy_button_not_disabled",
		"show_pending 之后按钮没有进禁用态 —— 后面的断言无从谈起")
	_h.expect(DisabledReason.reason_for(busy) == "正在连接",
		"busy_button_has_no_reason",
		"忙碌中的按钮问不出原因，拿到的是「%s」" % DisabledReason.reason_for(busy))
	busy.reset_idle("check_req")
	_h.expect(DisabledReason.reason_for(busy).is_empty(),
		"busy_reason_not_cleared",
		"回到闲置态之后原因还挂着：「%s」" % DisabledReason.reason_for(busy))
	busy.queue_free()
	Toast.dismiss()
	await get_tree().process_frame


func _send(control: Control, event: InputEvent) -> void:
	control.gui_input.emit(event)


func _mouse(pressed: bool) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = Vector2(10, 10)
	return e


func _touch(pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.pressed = pressed
	e.position = Vector2(10, 10)
	return e


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
