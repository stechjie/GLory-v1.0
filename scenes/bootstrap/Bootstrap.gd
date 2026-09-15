extends Control

# V3 P0-02: the first project scene must be cheap enough to draw before Main and
# its screen graph are loaded.  Keep this file free of battle/model/VFX preloads.

signal main_scene_ready(path: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const AccountConfig := preload("res://scripts/account/AccountConfig.gd")
const ServiceStatus := preload("res://scripts/account/ServiceStatus.gd")

const DEFAULT_MAIN_SCENE := "res://scenes/main/Main.tscn"
const ERROR_MAIN_LOAD := "BOOT-MAIN-LOAD"
const ERROR_STUCK := "BOOT-STUCK"
const ERROR_ENTRY_LOGIN := "BOOT-ENTRY-LOGIN"
const ERROR_ENTRY_CONNECT := "BOOT-ENTRY-CONNECT"
const ERROR_ENTRY_KICKED := "BOOT-ENTRY-KICKED"
const ERROR_ENTRY_MAINTENANCE := "BOOT-ENTRY-MAINTENANCE"

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

enum Phase { FIRST_FRAME, PREPARE_DATA, LOAD_MAIN, ENTRY, READY, FAILED }

# --- 进门（同时在线上限与排队，2026-09-14）------------------------------------
#
# 主界面载完之后、切过去之前多一步：**登录成功，并且账号后端放行**，才进门。
# 满了就停在这里排队（backend/app/admission.py）。
#
# 🔴 已定：连不上账号后端就不让进。所以这一步没有「等久了就放行」——
# 登录失败、连不上、被顶号，都停在这里自动重试或等玩家点，永远不自己放人。
# 唯一的例外是 ENTRY_LEGACY_SERVER_SEC：连上了、但从来不回名额消息，说明账号后端
# 还是没有排队功能的旧版（部署顺序反了）。那是「连得上」，不是「连不上」。
#
# 刻意不走看门狗：排队可能要等十几分钟，那不是「启动卡住」。
const ENTRY_POLL_SEC := 0.25
# 登录失败后第 1、2、3… 次自动重试前等多久。
const ENTRY_LOGIN_RETRY_SEC := [3.0, 6.0, 12.0, 24.0, 30.0]
# 注册被限流（429）时。服务端的限流窗口是小时级的，几秒重试一次只是白打。
const ENTRY_RATE_LIMITED_RETRY_SEC := 60.0
# 连续握手失败这么多次、或者登录后这么久还没连上，才把「连不上」摆出来。
# 太敏感的话，重连一闪而过也会弹错误面板。
const ENTRY_CONNECT_FAILURES := 2
const ENTRY_CONNECT_PATIENCE_SEC := 8.0
# 连上了但一直没收到名额消息，按「旧版账号后端」放行。见上面那段。
const ENTRY_LEGACY_SERVER_SEC := 10.0
# 进不去的时候多久读一次维护公告文件（scripts/account/ServiceStatus.gd）。
const ENTRY_STATUS_POLL_SEC := 20.0
const ENTRY_STATUS_TIMEOUT_SEC := 10.0

@export_file("*.tscn") var next_scene_path := DEFAULT_MAIN_SCENE
@export var auto_start := true
@export var auto_transition := true
# 进门这一步（见上面「进门」那段）。门禁场景测线程载入时关掉 —— 那里没有账号后端可连。
@export var entry_gate := true

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

var _entry_state := ""
var _entry_elapsed := 0.0
var _entry_poll := 0.0
var _entry_offline_sec := 0.0
var _entry_unanswered_sec := 0.0
var _entry_login_attempts := 0
# 下一次自动重试登录的时刻（_entry_elapsed 的刻度）。< 0 = 还没排。
var _entry_login_retry_at := -1.0
# 维护公告（docs/公告系统设计.md）。非空 = /status.json 说在维护、还没过期。
var _service_status: Dictionary = {}
var _status_checked_at := -ENTRY_STATUS_POLL_SEC
var _status_request: HTTPRequest


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
	if _phase == Phase.ENTRY:
		_tick_entry(delta)
		return
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
	if _phase == Phase.ENTRY:
		_retry_entry()
		return
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
		"entry_state": _entry_state,
	}


func _after_first_frame() -> void:
	await RenderingServer.frame_post_draw
	if not is_inside_tree():
		return
	StartupTrace.mark("bootstrap_first_frame", {"scene": "bootstrap"})
	if auto_start:
		start_loading()
	_kick_off_account_login()


# 账号登录：第一帧之后就发出去，**和主界面载入并行**，这里不 await。
#
# 挂在这里而不是 AccountManager._ready()，有两个理由：
#   1. autoload 的 _ready 在第一帧之前跑，会和启动关键路径抢时间；
#   2. 更要紧的是 tools/ 下那一堆检查场景**不经过 Bootstrap** ——
#      放在 autoload 里的话，每跑一次门禁都会去建一个真实账号。
#
# 2026-09-14 起主界面载完之后要等它（进门那一步，见 Phase.ENTRY）：登录不成功就不让进。
# 但载入本身仍然不等登录 —— 两件事并行，谁慢等谁。
#
# 开关见 AccountConfig.AUTO_LOGIN_DEFAULT（默认开）。
func _kick_off_account_login() -> void:
	if not AccountConfig.auto_login_enabled():
		return
	if AccountManager.is_logged_in():
		return
	AccountManager.login()


func _finish_loading() -> void:
	_load_started = false
	var resource := ResourceLoader.load_threaded_get(next_scene_path)
	_loaded_scene = resource as PackedScene
	if _loaded_scene == null:
		_fail(ERROR_MAIN_LOAD, _tr_text("主界面资源类型不正确。", "The main screen resource has the wrong type."))
		return
	_stuck = false
	_error_panel.visible = false
	if _entry_gate_required():
		_begin_entry()
		return
	_enter_ready()


func _enter_ready() -> void:
	_entry_state = ""
	_error_panel.visible = false
	_retry_button.text = _tr_text("重试", "Retry")
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
	# 进门时载入已经 100% 了；排队画面上挂一根满格进度条会被读成「马上就好」。
	_progress.visible = next_phase != Phase.FAILED and next_phase != Phase.ENTRY
	# 放在最后：_reset_watchdog() 要把**新**阶段的进度记成基线。放在开头的话
	# 记下的是上一阶段的值，第一次 tick 会被「进度变了」吃掉，三个门槛整体晚一秒。
	if phase_changed:
		_reset_watchdog()


# --- 进门 ---------------------------------------------------------------------

func _entry_gate_required() -> bool:
	return entry_gate and AccountConfig.auto_login_enabled()


func _begin_entry() -> void:
	_entry_elapsed = 0.0
	_entry_poll = 0.0
	_entry_offline_sec = 0.0
	_entry_unanswered_sec = 0.0
	_entry_login_attempts = 0
	_entry_login_retry_at = -1.0
	_set_phase(Phase.ENTRY, _tr_text("正在进入游戏", "Entering the game"), "", 1.0)
	_tick_entry(0.0, true)


func _tick_entry(delta: float, force := false) -> void:
	if not _entry_gate_required():
		_enter_ready()
		return
	_entry_elapsed += delta
	var logged_in := AccountManager.is_logged_in()
	var online := logged_in and RealtimeService.is_online()
	_entry_offline_sec = _entry_offline_sec + delta if logged_in and not online else 0.0
	var unanswered := online and not RealtimeService.is_admitted() and RealtimeService.queue_position <= 0
	_entry_unanswered_sec = _entry_unanswered_sec + delta if unanswered else 0.0
	_entry_poll -= delta
	if not force and _entry_poll > 0.0:
		return
	_entry_poll = ENTRY_POLL_SEC
	_drive_entry()
	var view := entry_view(_entry_facts())
	_show_entry(view)
	# 进不去的时候去看一眼是不是在维护（账号服务器停了，Caddy 照样给这个文件）。
	if str(view.get("state", "")) in ["login_failed", "connect_failed", "maintenance"]:
		_poll_service_status()
	if bool(view.get("pass", false)):
		if bool(view.get("legacy_server", false)):
			push_warning("[BOOT] 账号后端连上了但 %.0f 秒没回名额消息，按旧版后端放行" % ENTRY_LEGACY_SERVER_SEC)
		_enter_ready()


# 这一步要主动做的事：登录没发就发、失败了按退避重试、登录上了就连 WebSocket。
func _drive_entry() -> void:
	if not AccountManager.is_logged_in():
		match AccountManager.state:
			AccountManager.State.IDLE:
				AccountManager.login()
			AccountManager.State.FAILED:
				if _entry_login_retry_at < 0.0:
					_entry_login_retry_at = _entry_elapsed + _entry_login_backoff()
				elif _entry_elapsed >= _entry_login_retry_at:
					_retry_entry_login()
		return
	_entry_login_retry_at = -1.0
	# 🔴 被顶号之后绝不自动重连（RealtimeService._kicked 那条：两台设备会无限互踢）。
	if not RealtimeService.is_kicked():
		RealtimeService.start()


func _entry_login_backoff() -> float:
	if AccountManager.last_failure == AccountManager.Failure.RATE_LIMITED:
		return ENTRY_RATE_LIMITED_RETRY_SEC
	return float(ENTRY_LOGIN_RETRY_SEC[mini(_entry_login_attempts, ENTRY_LOGIN_RETRY_SEC.size() - 1)])


func _retry_entry_login() -> void:
	_entry_login_attempts += 1
	_entry_login_retry_at = -1.0
	AccountManager.login()


# 错误面板上那个按钮。三种情况三种做法，不能混：
#   被顶号   -> 只能由玩家亲手触发重连（ChatService.reconnect_here），会把另一台设备顶下线
#   没登录上 -> 立刻再登一次，不等退避
#   连不上   -> 跳过 WebSocket 的退避，立刻再连
func _retry_entry() -> void:
	if RealtimeService.is_kicked():
		ChatService.reconnect_here()
	elif not AccountManager.is_logged_in():
		if AccountManager.state != AccountManager.State.WORKING:
			_retry_entry_login()
	else:
		RealtimeService.retry_now()
	_tick_entry(0.0, true)


func _entry_facts() -> Dictionary:
	var login := "working"
	if AccountManager.is_logged_in():
		login = "logged_in"
	elif AccountManager.state == AccountManager.State.FAILED:
		login = "failed"
	return {
		"login": login,
		"rate_limited": AccountManager.last_failure == AccountManager.Failure.RATE_LIMITED,
		"login_retry_in": _entry_login_retry_at - _entry_elapsed if _entry_login_retry_at >= 0.0 else -1.0,
		"kicked": RealtimeService.is_kicked(),
		"online": RealtimeService.is_online(),
		"admitted": RealtimeService.is_admitted(),
		"queue_position": RealtimeService.queue_position,
		"failed_handshakes": RealtimeService.failed_handshakes(),
		"offline_sec": _entry_offline_sec,
		"unanswered_sec": _entry_unanswered_sec,
		"maintenance": not _service_status.is_empty(),
	}


# 这一步显示什么、放不放行。**纯函数** —— tools/bootstrap_check 直接喂事实表测它，
# 不用真的去连账号后端。state 是稳定标识，文案在 _show_entry 里按它拼。
static func entry_view(facts: Dictionary) -> Dictionary:
	if bool(facts.get("admitted", false)):
		return {"state": "pass", "pass": true}
	match str(facts.get("login", "working")):
		"failed":
			# 维护公告只替换「连不上」的说法，不改变放不放行。
			# 注册被限流不算：服务器没在维护，说成维护会让玩家一直干等。
			if bool(facts.get("maintenance", false)) and not bool(facts.get("rate_limited", false)):
				return {"state": "maintenance", "actions": true}
			return {"state": "login_failed", "actions": true,
				"rate_limited": bool(facts.get("rate_limited", false)),
				"retry_in": float(facts.get("login_retry_in", -1.0))}
		"logged_in":
			pass
		_:
			return {"state": "login"}
	if bool(facts.get("kicked", false)):
		return {"state": "kicked", "actions": true}
	if not bool(facts.get("online", false)):
		if int(facts.get("failed_handshakes", 0)) >= ENTRY_CONNECT_FAILURES \
				or float(facts.get("offline_sec", 0.0)) >= ENTRY_CONNECT_PATIENCE_SEC:
			if bool(facts.get("maintenance", false)):
				return {"state": "maintenance", "actions": true}
			return {"state": "connect_failed", "actions": true}
		return {"state": "connecting"}
	# 排着队就一直排，等多久都不放 —— 下面那条「旧版后端」只看从没收到过名额消息的情况。
	var position := int(facts.get("queue_position", 0))
	if position > 0:
		return {"state": "queued", "position": position}
	if float(facts.get("unanswered_sec", 0.0)) >= ENTRY_LEGACY_SERVER_SEC:
		return {"state": "pass", "pass": true, "legacy_server": true}
	return {"state": "checking"}


func _show_entry(view: Dictionary) -> void:
	_entry_state = str(view.get("state", ""))
	var actions := bool(view.get("actions", false))
	var title := ""
	var detail := ""
	var error := ""
	match _entry_state:
		"login":
			title = _tr_text("正在登录", "Signing in")
			detail = _tr_text("进入游戏前要先连上账号服务器", "Connecting to the account server before entering")
		"login_failed":
			title = _tr_text("登录失败", "Sign-in failed")
			var reason := _tr_text("暂时连不上账号服务器，连不上时无法进入游戏。",
				"The account server can't be reached; the game can't be entered without it.")
			if bool(view.get("rate_limited", false)):
				reason = _tr_text("新账号注册太频繁，服务器暂时不接受。",
					"Too many new accounts right now; the server isn't accepting more yet.")
			var retry_in := int(ceil(float(view.get("retry_in", -1.0))))
			var countdown := _tr_text("正在重试。", "Retrying.")
			if retry_in >= 0:
				countdown = _tr_text("%d 秒后自动重试。" % retry_in, "Retrying in %d s." % retry_in)
			error = _entry_error(reason + countdown, ERROR_ENTRY_LOGIN)
		"kicked":
			title = _tr_text("账号在另一台设备登录", "Signed in elsewhere")
			error = _entry_error(_tr_text("你的账号正在另一台设备上使用。在这台设备上继续，会让另一台设备下线。",
				"Your account is in use on another device. Continuing here signs that device out."),
				ERROR_ENTRY_KICKED)
		"connecting":
			title = _tr_text("正在连接服务器", "Connecting to the server")
		"connect_failed":
			title = _tr_text("连不上服务器", "Can't reach the server")
			error = _entry_error(_tr_text("暂时连不上服务器，正在自动重试。连上之前无法进入游戏。",
				"The server can't be reached; retrying automatically. The game can't be entered until it connects."),
				ERROR_ENTRY_CONNECT)
		"maintenance":
			# 文案由管理员写在 /status.json 里；没写的部分用默认说法补上。
			var english := LocaleManager.get_locale().begins_with("en")
			title = str(_service_status.get("title_en" if english else "title_zh", ""))
			if title.is_empty():
				title = _tr_text("服务器维护中", "Server maintenance")
			var message := str(_service_status.get("message_en" if english else "message_zh", ""))
			if message.is_empty():
				message = _tr_text("服务器正在维护。", "The server is under maintenance.")
			error = _entry_error(message + "\n" + _tr_text("维护结束后会自动进入，不用重启游戏。",
				"You'll get in automatically once it's over; no need to restart."), ERROR_ENTRY_MAINTENANCE)
		"checking":
			title = _tr_text("正在确认名额", "Checking for a free slot")
		"queued":
			var position := int(view.get("position", 0))
			title = _tr_text("排队中", "In queue")
			detail = _tr_text(
				"当前排在第 %d 位\n服务器人数已满，有人离开后按先后顺序进入。离开这个画面太久会失去位置。" % position,
				"You are number %d in line\nThe server is full; players get in as others leave. Leaving this screen for too long loses your place." % position)
		_:
			return
	_status.text = title
	_detail.text = detail
	_detail.visible = not detail.is_empty()
	_error_panel.visible = actions
	if actions:
		_error_text.text = error
		_retry_button.text = _tr_text("在这台设备上继续", "Continue here") if _entry_state == "kicked" \
			else _tr_text("重试", "Retry")


func _entry_error(message: String, code: String) -> String:
	return "%s\n%s" % [message, _tr_text("错误码：%s" % code, "Error code: %s" % code)]


# 读维护公告文件（scripts/account/ServiceStatus.gd 顶部）。只在进不去的时候、每 ENTRY_STATUS_POLL_SEC 读一次。
# 读不到（404 = 没在维护、整台机器挂了、网络不通）一律当没在维护：显示原来那句「连不上」。
func _poll_service_status() -> void:
	if _status_request != null or _entry_elapsed - _status_checked_at < ENTRY_STATUS_POLL_SEC:
		return
	_status_checked_at = _entry_elapsed
	var request := HTTPRequest.new()
	request.timeout = ENTRY_STATUS_TIMEOUT_SEC
	request.body_size_limit = 16 * 1024
	add_child(request)
	_status_request = request
	if request.request(AccountConfig.endpoint(ServiceStatus.PATH)) != OK:
		request.queue_free()
		_status_request = null
		return
	var result: Array = await request.request_completed
	request.queue_free()
	_status_request = null
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		_service_status = {}
		return
	var server_unix := ServiceStatus.server_time_from_headers(result[2])
	if server_unix <= 0:
		server_unix = int(Time.get_unix_time_from_system())
	_service_status = ServiceStatus.parse((result[3] as PackedByteArray).get_string_from_utf8(), server_unix)


# --- 启动看门狗（V3 P0-10）---------------------------------------------
#
# 三级都只**说明当前真实阶段**，不编造进度、不伪造百分比、不在主线程强杀。
# 15 秒之后仍然不进 Phase.FAILED：线程载入还在跑，随时可能完成，那时
# _finish_loading() 会照常切场景，玩家自己就走出去了。
func _tick_watchdog(delta: float) -> void:
	if _phase == Phase.READY or _phase == Phase.FAILED or _phase == Phase.ENTRY:
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
