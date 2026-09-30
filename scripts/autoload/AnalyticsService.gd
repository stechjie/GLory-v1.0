extends Node
# 运营数据第二批：游戏往账号服务器报事件（docs/运营数据.md 第六节）。
#
# 记的是「玩家走到了哪一步、哪里出了问题」：新手教学每一步、对局开始 / 每回合结果 / 中途离开、
# 战斗播放完没完、重连成没成、脚本报错、每 5 分钟一次帧率。
# **不记**：聊天内容、令牌、服务器地址、设备序列号。报错文字里的路径 / IP / 长串会先抹掉。
#
# ## 🔴 上报失败不能影响游戏
#
# track() 只往内存队列里放一条；每 15 秒挑一批（最多 50 条）经 AccountManager 发出去。
# 发不出去就攒着（本机文件 QUEUE_PATH，最多 MAX_QUEUE 条，7 天前的丢掉），指数退避再试。
# 服务器按事件编号去重：同一条发两次只记一次，所以「发出去了但没收到回复」时重发是安全的。
#
# ## 换号不串号
#
# 每条记下记录那一刻登录的 player_id。发的时候只发「没登录时记的」和「现在这个号记的」，
# 别的号记的直接丢 —— 不能把上一个人的记录挂到下一个人名下。
#
# ## 专服与门禁不跑
#
# 同一个工程也是战斗服务器（--server），tools/ 的门禁都是 headless 跑的：这两种情况整个关掉，
# track() 什么都不做。和 PerfLog / IssueReport 同一条判断。

const QUEUE_PATH := "user://glory_analytics.bin"
# 随机编号，只用来认出「同一次安装」（卸载重装就换一个）。**不是设备标识**。
const INSTALL_PATH := "user://glory_install_id.txt"

const MAX_QUEUE := 500
const BATCH_MAX := 50
const FLUSH_INTERVAL_SEC := 15.0
const PERSIST_INTERVAL_SEC := 30.0
const MAX_AGE_MS := 7 * 24 * 3600 * 1000
const BACKOFF_MAX_SEC := 600.0
const MAX_PROP_KEYS := 16
const MAX_STRING := 160
# 同一次启动里最多报几种不同的报错（同一种只报第一次）。其余只计数，进 perf 那条。
const MAX_ERROR_KINDS := 30
const PERF_INTERVAL_SEC := 300.0
# 一帧超过这么久算卡（低于 20 帧）。
const SLOW_FRAME_SEC := 0.05
# 启动耗时：等到「第一个能点的界面出来」（StartupTrace 的 t3）才报，最多等这么久。
const LAUNCH_WAIT_SEC := 180.0

var _enabled := false
# 门禁换成自己的临时文件，不碰这台电脑上真实的队列。
var queue_path := QUEUE_PATH
var _queue: Array = []
var _dirty := false
var _flushing := false
var _dropped := 0
var _backoff_sec := 0.0
var _next_flush_msec := 0
var _persist_timer := 0.0
var _flush_timer := 0.0
var _crypto: Crypto
var session_id := ""
var install_id := ""

# 前台时钟：手机切后台那段不算（教学步骤耗时要的是「玩家真在看」的时间）。
var _background_msec := 0
var _paused_at_msec := -1

var _tutorial_step_fg := 0

# 进行中的对局。_match_id 是本机给这一局起的编号，把这一局的几条记录串起来。
var _mode := ""
var _match_id := ""
var _match_over := true
var _reported_rounds: Dictionary = {}

var _catcher: ErrorCatcher
var _error_kinds: Dictionary = {}
var _error_count := 0
var _scrubbers: Array[Array] = []
var _digits: RegEx

var _launch_reported := false
var _perf_elapsed := 0.0
var _perf_frames := 0
var _perf_slow := 0


# 引擎的报错钩子（Godot 4.5+）。**可能在任何线程被调**：这里只加锁记下来，
# 由主线程的 _process 取走。钩子里不能 print / push_error —— 那会再进来一次。
class ErrorCatcher extends Logger:
	var mutex := Mutex.new()
	var pending: Array = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtrace: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		var where := "%s:%d" % [file, line]
		var fn := function
		if not script_backtrace.is_empty() and script_backtrace[0].get_frame_count() > 0:
			where = "%s:%d" % [script_backtrace[0].get_frame_file(0), script_backtrace[0].get_frame_line(0)]
			fn = script_backtrace[0].get_frame_function(0)
		mutex.lock()
		if pending.size() < 100:
			pending.append([error_type, where, fn, code if rationale.is_empty() else rationale])
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> Array:
		mutex.lock()
		var out := pending
		pending = []
		mutex.unlock()
		return out


func _ready() -> void:
	var args := OS.get_cmdline_args()
	if "--server" in args or "--dedicated-server" in args or DisplayServer.get_name() == "headless":
		set_process(false)
		return
	enable()
	_load_queue()
	var first_open := _load_install_id()
	_catcher = ErrorCatcher.new()
	OS.add_logger(_catcher)
	var screen := DisplayServer.screen_get_size()
	track("app_open", {
		"first": first_open,
		"platform": OS.get_name(),
		"model": OS.get_model_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"screen": "%dx%d" % [screen.x, screen.y],
		"cpus": OS.get_processor_count(),
		"locale": OS.get_locale(),
		"build": int(StartupTrace.build_info().get("version_code", 0)),
	})
	NetworkService.team_start_requested.connect(_on_match_started)
	NetworkService.match_state_received.connect(_on_match_state)
	NetworkService.resume_completed.connect(_on_resume_completed)
	NetworkService.resume_failed.connect(_on_resume_failed)
	NetworkService.team_room_action_failed.connect(_on_room_action_failed)


# 打开记录（只准备内存里的东西：编号、抹字用的正则）。_ready 里调；
# tools/analytics_check 也调它，在一份不挂进场景树的实例上验逻辑。
func enable() -> void:
	_enabled = true
	_crypto = Crypto.new()
	session_id = _uuid()
	_scrubbers = [
		[_regex("\\b\\d{1,3}(\\.\\d{1,3}){3}\\b"), "<ip>"],
		# 前面不能是字母：res:// 和 user:// 里的「s:/」「r:/」不是盘符。
		[_regex("(?<![A-Za-z])[A-Za-z]:[\\\\/][^\\s\"']*"), "<path>"],
		[_regex("/(home|Users|data|storage|sdcard)/[^\\s\"']*"), "<path>"],
		[_regex("[^\\s@]+@[^\\s@]+\\.[A-Za-z]{2,}"), "<email>"],
		[_regex("[A-Za-z0-9_\\-\\.=]{32,}"), "<redacted>"],
	]
	_digits = _regex("\\d+")


func _exit_tree() -> void:
	if _catcher != null:
		OS.remove_logger(_catcher)
		_catcher = null
	_persist()


func _notification(what: int) -> void:
	if not _enabled:
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			if _paused_at_msec < 0:
				_paused_at_msec = Time.get_ticks_msec()
			# 切后台可能就是最后一眼：系统随时会杀进程。
			_persist()
		NOTIFICATION_APPLICATION_RESUMED:
			if _paused_at_msec >= 0:
				_background_msec += Time.get_ticks_msec() - _paused_at_msec
				_paused_at_msec = -1
			_flush_timer = FLUSH_INTERVAL_SEC
		NOTIFICATION_WM_CLOSE_REQUEST:
			_persist()


func _process(delta: float) -> void:
	_drain_errors()
	if _paused_at_msec < 0:
		_perf_elapsed += delta
		_perf_frames += 1
		if delta > SLOW_FRAME_SEC:
			_perf_slow += 1
		if _perf_elapsed >= PERF_INTERVAL_SEC:
			_report_perf()
	if not _launch_reported:
		_maybe_report_launch()
	_flush_timer += delta
	if _flush_timer >= FLUSH_INTERVAL_SEC:
		_flush_timer = 0.0
		_flush()
	_persist_timer += delta
	if _persist_timer >= PERSIST_INTERVAL_SEC:
		_persist_timer = 0.0
		if _dirty:
			_persist()


# --- 记 ---------------------------------------------------------------------------

func track(event_name: String, props: Dictionary = {}) -> void:
	if not _enabled:
		return
	_queue.append({
		"id": _uuid(),
		"name": event_name,
		"t": _now_msec(),
		"pid": AccountManager.player_id,
		"sid": session_id,
		"props": _clean(props),
	})
	if _queue.size() > MAX_QUEUE:
		_queue.pop_front()
		_dropped += 1
	_dirty = true


# 前台时钟（毫秒）。手机切后台那段不走。
func foreground_msec() -> int:
	var now := Time.get_ticks_msec()
	var paused := (now - _paused_at_msec) if _paused_at_msec >= 0 else 0
	return now - _background_msec - paused


# --- 新手教学（TutorialMode 调）-----------------------------------------------------

func tutorial_started() -> void:
	_tutorial_step_fg = foreground_msec()
	track("tutorial_start")


func tutorial_resumed(step_key: String, index: int) -> void:
	_tutorial_step_fg = foreground_msec()
	track("tutorial_resume", {"step": step_key, "index": index})


# 走完一步。to == "DONE" 就是整段教学完成。ms = 在 from 那一步停了多久（前台）。
func tutorial_step(from_key: String, to_key: String, from_index: int) -> void:
	var now := foreground_msec()
	track("tutorial_step", {"from": from_key, "to": to_key, "index": from_index, "ms": now - _tutorial_step_fg})
	_tutorial_step_fg = now


func tutorial_skipped(step_key: String, index: int) -> void:
	track("tutorial_skip", {"step": step_key, "index": index, "ms": foreground_msec() - _tutorial_step_fg})


# --- 对局 -------------------------------------------------------------------------

# 接下来进的房间是什么模式：排队时（AccountManager.join_match_queue）是 casual / ranked，
# 自己建房、按房号进房时是 custom。开局那一刻用。
func note_mode(mode: String) -> void:
	_mode = mode


func _on_match_started() -> void:
	_match_id = _uuid()
	_match_over = false
	_reported_rounds.clear()
	var humans := 0
	var bots := 0
	for state in GameState.team_slot_states:
		if str(state) == "player":
			humans += 1
		elif str(state) == "dummy":
			bots += 1
	track("match_start", {"m": _match_id, "mode": _mode, "slot": NetworkService.team_local_slot,
		"humans": humans, "bots": bots})


# 每回合服务器发下来的结算（每个客户端都收到自己那一份）。重连时同一回合可能再来一次，按回合去重。
func _on_match_state(state: Dictionary) -> void:
	var round_index := int(state.get("completed_round", 0))
	var battle := str(state.get("battle_id", ""))
	var key := "%s|%d" % [battle, round_index]
	if round_index <= 0 or _reported_rounds.has(key):
		return
	_reported_rounds[key] = true
	var slot := int(state.get("slot", -1))
	var over := bool(state.get("run_over", false))
	track("round_result", {
		"m": _match_id, "mode": _mode, "round": round_index, "kind": str(state.get("kind", "")),
		"battle": battle, "team": 0 if slot < 3 else 1,
		# 服务器每回合按队伍维护连败：赢了清零。
		"won": int(state.get("loss_streak", 1)) == 0,
		"hp": int(state.get("team_hp", 0)), "enemy_hp": int(state.get("enemy_team_hp", 0)),
		"gold": int(state.get("gold", 0)), "carrots": int(state.get("carrots", 0)),
		"harvest": int(state.get("harvest_tech_level", 0)),
		"over": over, "run_won": bool(state.get("team_run_won", false)),
		"outcome": int(state.get("run_outcome", -1)) if over else -1,
	})
	if over:
		_match_over = true


# 对局没打完就回了主菜单（Main 调）。
func match_left(reason: String) -> void:
	if _match_id.is_empty() or _match_over:
		return
	track("match_leave", {"m": _match_id, "mode": _mode, "round": GameState.round_index, "reason": reason})
	_match_over = true


func _on_resume_completed(_payload: Dictionary) -> void:
	track("reconnect", {"ok": true, "m": _match_id})


func _on_resume_failed(reason: String) -> void:
	track("reconnect", {"ok": false, "reason": reason, "m": _match_id})


func _on_room_action_failed(reason: String) -> void:
	track("room_action_failed", {"reason": reason, "mode": _mode})


# --- 启动耗时、帧率、报错 ------------------------------------------------------------

func _maybe_report_launch() -> void:
	if StartupTrace.has_mark(StartupTrace.T3_INPUT_READY):
		_launch_reported = true
		track("app_launch", {
			"t0": StartupTrace.ms_of(StartupTrace.T0_TRACE_READY),
			"t1": StartupTrace.ms_of(StartupTrace.T1_FIRST_FRAME),
			"t2": StartupTrace.ms_of(StartupTrace.T2_MAIN_READY),
			"t3": StartupTrace.ms_of(StartupTrace.T3_INPUT_READY),
		})
	elif Time.get_ticks_msec() > LAUNCH_WAIT_SEC * 1000.0:
		_launch_reported = true


func _report_perf() -> void:
	var ctx := "menu"
	if GameState.tutorial_mode:
		ctx = "tutorial"
	elif GameState.team_mode:
		ctx = "match"
	track("perf", {
		"sec": int(_perf_elapsed),
		"fps": float(_perf_frames) / maxf(_perf_elapsed, 0.001),
		"slow": _perf_slow,
		"errors": _error_count,
		"mem_mb": int(OS.get_static_memory_usage() / 1048576),
		"ctx": ctx,
	})
	_perf_elapsed = 0.0
	_perf_frames = 0
	_perf_slow = 0


func _drain_errors() -> void:
	if _catcher == null:
		return
	for entry in _catcher.take():
		_error_count += 1
		var kind: String = ["error", "warning", "script", "shader"][clampi(int(entry[0]), 0, 3)]
		var message := _scrub(str(entry[3]))
		# 同一处、同一句话（数字不算）算同一种。
		var fingerprint := "%s|%s|%s" % [kind, entry[1], _digits.sub(message.left(80), "#", true)]
		if _error_kinds.has(fingerprint) or _error_kinds.size() >= MAX_ERROR_KINDS:
			continue
		_error_kinds[fingerprint] = true
		track("client_error", {"kind": kind, "where": str(entry[1]), "fn": str(entry[2]), "msg": message})


# --- 发 ---------------------------------------------------------------------------

func _flush() -> void:
	if _flushing or _queue.is_empty() or not AccountManager.is_logged_in():
		return
	if Time.get_ticks_msec() < _next_flush_msec:
		return
	keep_only_player(AccountManager.player_id)
	if _dropped > 0:
		track("events_dropped", {"n": _dropped})
		_dropped = 0
	var batch: Array = []
	for event in _queue.slice(0, BATCH_MAX):
		batch.append({"id": event["id"], "name": event["name"], "t": event["t"], "sid": event["sid"],
			"props": event["props"]})
	_flushing = true
	var res: Dictionary = await AccountManager.post_events({
		"sent_at": _now_msec(), "install_id": install_id, "events": batch})
	_flushing = false
	var code := int(res.get("code", 0))
	if code >= 200 and code < 300:
		var body: Dictionary = res.get("body", {})
		var done := {}
		for key in ["accepted", "duplicate"]:
			for event_id in body.get(key, []):
				done[str(event_id)] = true
		for rejected in body.get("rejected", []):
			if rejected is Dictionary:
				done[str((rejected as Dictionary).get("id", ""))] = true
		_drop_ids(done)
		_backoff_sec = 0.0
		_next_flush_msec = 0
		# 还有没发完的：不等下一个 15 秒。
		if not _queue.is_empty() and not done.is_empty():
			_flush_timer = FLUSH_INTERVAL_SEC
		return
	if code == 400 or code == 413 or code == 422:
		# 这一批本身不对（格式、太大）：重发多少次都一样，丢掉免得卡住后面的。
		# 别的 4xx 不丢：404 = 账号服务器还没更新到有这个接口（新包先发了），401 / 403 = 令牌问题，都是等等就好。
		var bad := {}
		for event in batch:
			bad[str(event["id"])] = true
		_drop_ids(bad)
		return
	# 连不上、5xx、429、404、令牌问题：留着，退避再试（最长 10 分钟一次）。
	# 加一点随机：服务器重启后几百台手机不该在同一秒一起重发。
	_backoff_sec = clampf(maxf(_backoff_sec * 2.0, FLUSH_INTERVAL_SEC), FLUSH_INTERVAL_SEC, BACKOFF_MAX_SEC)
	_next_flush_msec = Time.get_ticks_msec() + int(_backoff_sec * randf_range(0.8, 1.2) * 1000.0)


# 换过号：上一个号记的丢掉，不挂到这个号名下。没登录时记的（pid 空）归现在这个号。
func keep_only_player(me: String) -> void:
	var mine: Array = []
	for event in _queue:
		var owner := str(event.get("pid", ""))
		if owner.is_empty() or owner == me:
			mine.append(event)
	if mine.size() != _queue.size():
		_queue = mine
		_dirty = true


func _drop_ids(ids: Dictionary) -> void:
	if ids.is_empty():
		return
	var kept: Array = []
	for event in _queue:
		if not ids.has(str(event.get("id", ""))):
			kept.append(event)
	_queue = kept
	_dirty = true


# --- 本机存 -------------------------------------------------------------------------

func _persist() -> void:
	if not _enabled or not _dirty:
		return
	if SaveManager.atomic_write_bytes(queue_path, var_to_bytes(_queue)):
		_dirty = false


func _load_queue() -> void:
	var data := SaveManager.read_bytes_with_fallback(queue_path)
	if data.is_empty():
		return
	var saved: Variant = bytes_to_var(data)
	if not (saved is Array):
		return
	var oldest := _now_msec() - MAX_AGE_MS
	for event in saved:
		if event is Dictionary and (event as Dictionary).has("id") and int((event as Dictionary).get("t", 0)) >= oldest:
			_queue.append(event)
	if _queue.size() > MAX_QUEUE:
		_queue = _queue.slice(_queue.size() - MAX_QUEUE)


# 返回「这是不是这次安装第一次打开」。
func _load_install_id() -> bool:
	if FileAccess.file_exists(INSTALL_PATH):
		install_id = FileAccess.get_file_as_string(INSTALL_PATH).strip_edges()
		if install_id.length() == 36:
			return false
	install_id = _uuid()
	var f := FileAccess.open(INSTALL_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(install_id)
	return true


# --- 小工具 -------------------------------------------------------------------------

func _regex(pattern: String) -> RegEx:
	return RegEx.create_from_string(pattern)


func _scrub(text: String) -> String:
	for pair in _scrubbers:
		text = (pair[0] as RegEx).sub(text, str(pair[1]), true)
	return text.left(MAX_STRING)


func _clean(props: Dictionary) -> Dictionary:
	var out := {}
	for key in props:
		if out.size() >= MAX_PROP_KEYS:
			break
		var value: Variant = props[key]
		match typeof(value):
			TYPE_BOOL, TYPE_INT:
				out[str(key)] = value
			TYPE_FLOAT:
				out[str(key)] = snappedf(value, 0.01)
			TYPE_STRING, TYPE_STRING_NAME:
				# 所有文字都过一遍抹字：失败原因这类字段也可能夹着地址。
				out[str(key)] = _scrub(str(value))
	return out


func _now_msec() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func _uuid() -> String:
	var b := _crypto.generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]
