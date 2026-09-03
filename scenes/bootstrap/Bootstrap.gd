extends Control

# V3 P0-02: the first project scene must be cheap enough to draw before Main and
# its screen graph are loaded.  Keep this file free of battle/model/VFX preloads.

signal main_scene_ready(path: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")

const DEFAULT_MAIN_SCENE := "res://scenes/main/Main.tscn"
const ERROR_MAIN_LOAD := "BOOT-MAIN-LOAD"
const ERROR_STUCK := "BOOT-STUCK"

# 看门狗三级（V3 P0-10）。计时器由**进度**驱动而不只是阶段：慢但在推进的
# 载入不该被叫做卡住，而阶段不变、进度也不动才是真的没动静。
#
# 三级都不碰载入本身。线程载入继续跑，随时可能完成 —— 主线程强杀只会把
# 一次「慢」变成一次「坏」，而且丢掉本来能自己恢复的那条路。
const WATCHDOG_NOTICE_SEC := 3.0
const WATCHDOG_EXPLAIN_SEC := 8.0
const WATCHDOG_STUCK_SEC := 15.0
# 进度推进多少算「有动静」。线程载入的进度是分段跳的，太小的阈值会被
# 浮点抖动一直重置，看门狗就永远升不了级。
const WATCHDOG_PROGRESS_EPSILON := 0.01

enum WatchdogLevel { QUIET, NOTICE, EXPLAIN, STUCK }

enum Phase { FIRST_FRAME, PREPARE_DATA, LOAD_MAIN, READY, FAILED }

@export_file("*.tscn") var next_scene_path := DEFAULT_MAIN_SCENE
@export var auto_start := true
@export var auto_transition := true

@onready var _logo: TextureRect = %Logo
@onready var _status: Label = %Status
@onready var _detail: Label = %Detail
@onready var _progress: ProgressBar = %Progress
@onready var _error_panel: VBoxContainer = %ErrorPanel
@onready var _error_text: Label = %ErrorText
@onready var _retry_button: Button = %RetryButton
@onready var _exit_button: Button = %ExitButton

var _phase := Phase.FIRST_FRAME
var _load_started := false
var _transition_queued := false
var _loaded_scene: PackedScene
var _pulse_elapsed := 0.0
var _phase_elapsed := 0.0
var _watchdog_level := WatchdogLevel.QUIET
var _watchdog_progress := 0.0
# 卡住不等于失败：载入还在后台跑，随时可能完成。所以不进 Phase.FAILED，
# 只把重试/退出这条出路摆出来。
var _stuck := false


func _ready() -> void:
	theme = Theming.get_theme()
	_retry_button.pressed.connect(retry)
	_exit_button.pressed.connect(exit_app)
	_apply_locale()
	_set_phase(Phase.FIRST_FRAME, _tr_text("正在启动 Glory", "Starting Glory"),
		_tr_text("正在显示轻量启动画面", "Presenting the lightweight startup screen"), 0.0)
	set_process(true)
	call_deferred("_after_first_frame")


func _process(delta: float) -> void:
	_update_breathing(delta)
	_tick_watchdog(delta)
	if not _load_started or _phase != Phase.LOAD_MAIN:
		return
	var progress_values: Array = []
	var status := ResourceLoader.load_threaded_get_status(next_scene_path, progress_values)
	if not progress_values.is_empty():
		_progress.value = clampf(float(progress_values[0]), 0.0, 1.0) * 100.0
	match status:
		ResourceLoader.THREAD_LOAD_LOADED:
			_finish_loading()
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_fail(ERROR_MAIN_LOAD, _tr_text(
				"主界面无法载入。请重试；若问题持续，请在系统设置中清除应用缓存后重新打开。",
				"The main screen could not be loaded. Retry; if it persists, clear the app cache in system settings and reopen."))


func start_loading() -> void:
	if _load_started or _phase == Phase.READY:
		return
	_error_panel.visible = false
	_set_phase(Phase.PREPARE_DATA, _tr_text("准备数据", "Preparing data"),
		_tr_text("确认游戏数据可用", "Checking that game data is available"), 0.08)
	DataRegistry.ensure_loaded()
	if not DataRegistry.is_ready():
		_fail("BOOT-DATA", _tr_text(
			"游戏数据未能载入。请重试；若问题持续，请重新安装完整资源包。",
			"Game data could not be loaded. Retry; if it persists, reinstall the complete asset package."))
		return
	if next_scene_path.is_empty() or not ResourceLoader.exists(next_scene_path, "PackedScene"):
		_fail(ERROR_MAIN_LOAD, _tr_text("找不到主界面资源。", "The main screen resource is missing."))
		return
	_set_phase(Phase.LOAD_MAIN, _tr_text("载入界面", "Loading interface"),
		_tr_text("准备语言与主菜单", "Preparing language and main menu"), 0.12)
	var error := ResourceLoader.load_threaded_request(next_scene_path, "PackedScene", true)
	if error != OK:
		_fail(ERROR_MAIN_LOAD, _tr_text("主界面载入请求失败。", "The main screen load request failed."))
		return
	_load_started = true


# 卡住时也允许重试：那时 _phase 还是 LOAD_MAIN（载入没失败，只是没回来）。
func retry() -> void:
	if _phase != Phase.FAILED and not _stuck:
		return
	# 在途的那次线程载入**不取消**：取消要在主线程等它收尾，正是
	# 「不在主线程强杀」要避免的。让它自己跑完，结果被下面这次重发丢弃。
	_stuck = false
	_error_panel.visible = false
	_load_started = false
	_transition_queued = false
	_loaded_scene = null
	start_loading()


func exit_app() -> void:
	get_tree().quit()


func snapshot() -> Dictionary:
	return {
		"phase": _phase,
		"phase_name": Phase.keys()[_phase],
		"path": next_scene_path,
		"progress": float(_progress.value) / 100.0,
		"error_visible": _error_panel.visible,
		"error_text": _error_text.text,
		"loaded": _loaded_scene != null,
		"watchdog_level": _watchdog_level,
		"watchdog_level_name": WatchdogLevel.keys()[_watchdog_level],
		"phase_elapsed_sec": _phase_elapsed,
		"stuck": _stuck,
	}


func _after_first_frame() -> void:
	await RenderingServer.frame_post_draw
	if not is_inside_tree():
		return
	StartupTrace.mark("bootstrap_first_frame", {"scene": "bootstrap"})
	if auto_start:
		start_loading()


func _finish_loading() -> void:
	_load_started = false
	var resource := ResourceLoader.load_threaded_get(next_scene_path)
	_loaded_scene = resource as PackedScene
	if _loaded_scene == null:
		_fail(ERROR_MAIN_LOAD, _tr_text("主界面资源类型不正确。", "The main screen resource has the wrong type."))
		return
	_stuck = false
	_error_panel.visible = false
	_set_phase(Phase.READY, _tr_text("准备完成", "Ready"),
		_tr_text("正在进入 Glory", "Entering Glory"), 1.0)
	main_scene_ready.emit(next_scene_path)
	if auto_transition and not _transition_queued:
		_transition_queued = true
		call_deferred("_transition_to_main")


func _transition_to_main() -> void:
	if _loaded_scene == null:
		return
	var error := get_tree().change_scene_to_packed(_loaded_scene)
	if error != OK:
		_transition_queued = false
		_fail(ERROR_MAIN_LOAD, _tr_text("无法切换到主界面。", "Could not switch to the main screen."))


func _fail(code: String, message: String) -> void:
	_load_started = false
	_set_phase(Phase.FAILED, _tr_text("启动失败", "Startup failed"), "", 0.0)
	_error_text.text = "%s\n%s" % [message, _tr_text("错误码：%s" % code, "Error code: %s" % code)]
	_error_panel.visible = true


func _set_phase(next_phase: int, title: String, detail: String, ratio: float) -> void:
	var phase_changed := next_phase != _phase
	_phase = next_phase
	_status.text = title
	_detail.text = detail
	_detail.visible = not detail.is_empty()
	_progress.value = clampf(ratio, 0.0, 1.0) * 100.0
	_progress.visible = next_phase != Phase.FAILED
	# 放在最后：_reset_watchdog() 要把**新**阶段的进度记成基线。放在开头的话
	# 记下的是上一阶段的值，第一次 tick 会被「进度变了」吃掉，三个门槛整体晚一秒。
	if phase_changed:
		_reset_watchdog()


# --- 启动看门狗（V3 P0-10）---------------------------------------------
#
# 三级都只**说明当前真实阶段**，不编造进度、不伪造百分比、不在主线程强杀。
# 15 秒之后仍然不进 Phase.FAILED：线程载入还在跑，随时可能完成，那时
# _finish_loading() 会照常切场景，玩家自己就走出去了。
func _tick_watchdog(delta: float) -> void:
	if _phase == Phase.READY or _phase == Phase.FAILED:
		return
	var ratio := float(_progress.value) / 100.0
	if absf(ratio - _watchdog_progress) >= WATCHDOG_PROGRESS_EPSILON:
		# 进度在动 = 没卡住。慢不等于坏。
		_watchdog_progress = ratio
		_reset_watchdog()
		return
	_phase_elapsed += delta
	var next_level := WatchdogLevel.QUIET
	if _phase_elapsed >= WATCHDOG_STUCK_SEC:
		next_level = WatchdogLevel.STUCK
	elif _phase_elapsed >= WATCHDOG_EXPLAIN_SEC:
		next_level = WatchdogLevel.EXPLAIN
	elif _phase_elapsed >= WATCHDOG_NOTICE_SEC:
		next_level = WatchdogLevel.NOTICE
	if next_level == _watchdog_level:
		return
	_watchdog_level = next_level
	_apply_watchdog_level()


func _apply_watchdog_level() -> void:
	match _watchdog_level:
		WatchdogLevel.NOTICE:
			_detail.text = _tr_text(
				"%s，比平时久一些，仍在继续" % _phase_noun(),
				"Still %s. This is taking longer than usual." % _phase_gerund())
			_detail.visible = true
		WatchdogLevel.EXPLAIN:
			_detail.text = "%s\n%s" % [
				_tr_text("%s，比平时久一些，仍在继续" % _phase_noun(),
					"Still %s. This is taking longer than usual." % _phase_gerund()),
				_phase_explanation(),
			]
			_detail.visible = true
		WatchdogLevel.STUCK:
			_stuck = true
			_error_text.text = "%s\n%s\n%s" % [
				_tr_text("启动比预期慢很多。载入仍在后台继续，可以再等一会儿，
					也可以重试或退出。",
					"Startup is much slower than expected. Loading is still running in"
					+ " the background; you can keep waiting, retry, or exit."),
				_phase_explanation(),
				_tr_text("错误码：%s" % ERROR_STUCK, "Error code: %s" % ERROR_STUCK),
			]
			_error_panel.visible = true


func _reset_watchdog() -> void:
	_phase_elapsed = 0.0
	_watchdog_level = WatchdogLevel.QUIET
	# 重置的含义是「基线就是现在」，不是「基线未知」。不记下来的话，
	# 复位之后的第一次 tick 会被自己造出来的进度差吃掉。
	_watchdog_progress = float(_progress.value) / 100.0


# 看门狗的文案必须指向**真实**阶段。写死一句「正在载入」在 PREPARE_DATA
# 卡住时就是假话，而这条门槛的全部意义就是让玩家知道卡在哪一步。
func _phase_noun() -> String:
	match _phase:
		Phase.FIRST_FRAME:
			return "正在显示启动画面"
		Phase.PREPARE_DATA:
			return "正在准备数据"
		Phase.LOAD_MAIN:
			return "正在载入界面"
		_:
			return "正在启动"


func _phase_gerund() -> String:
	match _phase:
		Phase.FIRST_FRAME:
			return "presenting the startup screen"
		Phase.PREPARE_DATA:
			return "preparing data"
		Phase.LOAD_MAIN:
			return "loading the interface"
		_:
			return "starting up"


func _phase_explanation() -> String:
	match _phase:
		Phase.PREPARE_DATA:
			return _tr_text("正在校验游戏数据表。",
				"Verifying the game data tables.")
		Phase.LOAD_MAIN:
			return _tr_text("主界面资源较大，首次启动需要解压，仍在后台载入。",
				"The main screen is large and is unpacked on first launch;"
				+ " it is still loading in the background.")
		_:
			return _tr_text("仍在等待启动流程推进。",
				"Still waiting for startup to advance.")


func _apply_locale() -> void:
	%Title.text = "GLORY"
	%Subtitle.text = _tr_text("荣耀启程", "Begin in Glory")
	_retry_button.text = _tr_text("重试", "Retry")
	_exit_button.text = _tr_text("退出", "Exit")


func _tr_text(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh


func _update_breathing(delta: float) -> void:
	if Tokens.reduced_motion():
		_logo.modulate.a = 1.0
		return
	_pulse_elapsed += delta
	_logo.modulate.a = 0.86 + sin(_pulse_elapsed * 2.4) * 0.14
