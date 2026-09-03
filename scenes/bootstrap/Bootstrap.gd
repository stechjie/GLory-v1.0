extends Control

# V3 P0-02: the first project scene must be cheap enough to draw before Main and
# its screen graph are loaded.  Keep this file free of battle/model/VFX preloads.

signal main_scene_ready(path: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")

const DEFAULT_MAIN_SCENE := "res://scenes/main/Main.tscn"
const ERROR_MAIN_LOAD := "BOOT-MAIN-LOAD"

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


func retry() -> void:
	if _phase != Phase.FAILED:
		return
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
	_phase = next_phase
	_status.text = title
	_detail.text = detail
	_detail.visible = not detail.is_empty()
	_progress.value = clampf(ratio, 0.0, 1.0) * 100.0
	_progress.visible = next_phase != Phase.FAILED


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
