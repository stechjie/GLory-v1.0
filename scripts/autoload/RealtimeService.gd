extends Node

# ①↔② 的 WebSocket 长连接（`docs/聊天系统设计.md` 批次 B）。
#
# 与另外两条链路的分工：
#   AccountManager   ①↔② HTTPS，问一句答一句，**无状态**
#   NetworkService   ①↔③ ENet + DTLS，战斗
#   本文件           ①↔② WebSocket，聊天（世界频道 + 私聊）
#
# 房间与局内聊天**不走这里**，走 ③ 的 ENet ——
# 因为只有 ③ 知道谁真的在房间里，② 那边的 room_id 是客户端自报的
# （见设计文档第一节那条红线）。
#
# ## 为什么不用 ReconnectService.gd 那套
#
# 思路可以抄，代码不能共用：那套是给 ENet 的（`ENetMultiplayerPeer` +
# `multiplayer_peer`），这里是 `WebSocketPeer`，连状态枚举都不是一套东西。
# 抄的时候要连它踩过的坑一起抄，别只抄结构。

signal connection_changed(state: int)
signal message_received(payload: Dictionary)
# 被顶号。**与普通断线是两回事**，界面上必须分开处理 ——
# 玩家看到「连接已断开」和「你的账号在其他设备登录」的反应完全不同。
signal kicked_by_other_device
# 名额变了：被放行，或者排队位次变了（backend/app/admission.py）。启动画面靠它判断放不放人进门。
signal admission_changed

const AccountConfig := preload("res://scripts/account/AccountConfig.gd")

enum State { OFFLINE, CONNECTING, ONLINE }

# 与 backend/app/realtime.py 的同名常量对应。⚠️ 两处都有，改一个必须改另一个 ——
# 对不上的症状是「弱网玩家成片掉线」或「幽灵连接清不掉」，两种都不会报错。
const CLOSE_KICKED := 4001
const CLOSE_IDLE := 4002
# 服务端在 ready 里下发真实值，这个只是它还没到之前的兜底。
const DEFAULT_PING_INTERVAL_SEC := 30.0

# 同时在线上限与排队。与 backend/app/admission.py 的 HEADER / MESSAGE_TYPE / ENTER / RESUME 对应。
# ⚠️ 两处都有，tools/chat_check 钉着。对不上的症状是被服务器当成旧版客户端（从不排队），
# 或者永远收不到放行、全体卡在启动画面 —— 两种都不报错。
const ADMISSION_HEADER := "X-Glory-Admission"
const ADMISSION_TYPE := "admission"
const ADMISSION_ENTER := "enter"
const ADMISSION_RESUME := "resume"

# 重连退避。首次快、之后指数涨、封顶 30 秒。
#
# 封顶是必须的：没有上限的话，一次长时间断网之后玩家要等好几分钟才会重试，
# 而那时网络早就好了。封顶太小同样不行 —— 服务端真挂了的时候，
# 几千个客户端每秒重连一次就是一次自制的 DDoS。
const RECONNECT_BASE_SEC := 1.0
const RECONNECT_MAX_SEC := 30.0
# 连续握手失败几次之后强制续一次令牌（见 _failed_handshakes）。
const FORCE_REFRESH_AFTER_FAILURES := 2

# 设备标识。**不是凭证**，只是一个不透明串，让服务端能把「同一台设备重连」
# 与「换了台设备登录」分开（见 backend/app/realtime.py 顶部那张表）。
#
# 丢了是安全的：最坏结果是被当成一台新设备，于是自己把自己的旧连接顶掉 ——
# 而那条旧连接本来就已经断了。所以这里**不需要** AccountManager 那套
# 原子写 + .bak 回退，普通读写就够。
const DEVICE_FILE := "user://glory_device.json"

var state: int = State.OFFLINE:
	set(value):
		if state == value:
			return
		state = value
		connection_changed.emit(value)

var _socket: WebSocketPeer = null
var _device_id := ""
var _ping_interval := DEFAULT_PING_INTERVAL_SEC
var _ping_timer := 0.0
var _reconnect_delay := RECONNECT_BASE_SEC
var _reconnect_timer := 0.0
var _want_connection := false
# 🔴 被顶号之后**绝不能自动重连**。
# 两台设备都在自动重连的话会变成无限互踢：A 连上把 B 踢下线，B 重连把 A 踢下线，
# 循环到有人关掉游戏为止。玩家看到的是两台设备都在疯狂闪断。
var _kicked := false
# 建连中（在等令牌续期）。_process 每帧都可能再调 _open()，靠它挡住重入。
var _opening := false
# 连续握手失败的次数（从没收到过 ready 就断了）。服务端在 accept 之前拒绝时，
# 客户端这边只看得到「握手失败」，分不出是令牌被拒还是网络不通 ——
# 失败够次数就强制续一次令牌，而不是拿着同一张过期票永远重试。
var _failed_handshakes := 0
# 这个进程里服务器有没有放行过。🔴 **一旦为 true 就不再变回 false**（stop() 也不清）：
# 放进来之后的每一次重连都带 resume，服务器保证不会把已经在游戏里的人踢回队列。
# 清掉它，玩家会在对局中因为一次断线重连被当成「新来的」去排队。
var _admitted := false
# 排队位次（1 起）。0 = 不在排队 / 还不知道。
var queue_position := 0


func _ready() -> void:
	set_process(false)
	_device_id = _load_or_make_device_id()


# --- 对外 ---------------------------------------------------------------------

func is_online() -> bool:
	return state == State.ONLINE


func device_id() -> String:
	return _device_id


func is_admitted() -> bool:
	return _admitted


func is_kicked() -> bool:
	return _kicked


# 连续握手失败的次数（从没收到过 ready 就断了）。启动画面用它区分「真连不上」和「重连一闪而过」。
func failed_handshakes() -> int:
	return _failed_handshakes


# 跳过当前的退避等待，下一帧就重连（启动画面的「重试」）。
# 被顶号时无效 —— 那只能走 ChatService.reconnect_here，理由见 _kicked。
func retry_now() -> void:
	if not _want_connection or _kicked or _socket != null or _opening:
		return
	_reconnect_timer = 0.0


func start() -> void:
	"""开始保持连接。断了会自动重连，直到 stop()。

	登录成功后由 Main._install_realtime() 调（批次 C 起有私聊可收）。
	被顶号之后**只能由玩家亲手触发**（ChatService.reconnect_here）——
	自动再连会让两台设备无限互踢。
	"""
	if _want_connection:
		return
	_want_connection = true
	_kicked = false
	_failed_handshakes = 0
	_reconnect_delay = RECONNECT_BASE_SEC
	set_process(true)
	_open()


func stop() -> void:
	_want_connection = false
	set_process(false)
	_close_socket(1000)
	state = State.OFFLINE


func send(payload: Dictionary) -> bool:
	if state != State.ONLINE or _socket == null:
		return false
	return _socket.send_text(JSON.stringify(payload)) == OK


# --- 连接 ---------------------------------------------------------------------

func _open() -> void:
	if _opening:
		return
	_opening = true
	# 先保证令牌够新（设计文档第二节「token 过期后重连」）。连着失败时强制续一次，
	# 理由见 _failed_handshakes 的注释。
	if _failed_handshakes >= FORCE_REFRESH_AFTER_FAILURES:
		await AccountManager.refresh_session()
	else:
		await AccountManager.ensure_fresh_token()
	_opening = false
	# 等续期的这段时间里可能已经 stop() 了，或者被顶号了。
	if not _want_connection or _kicked:
		return

	var token := AccountManager.access_token()
	if token.is_empty():
		# 还没登录。不是错误 —— 启动早期就会走到这里。退避后再试，
		# 期间 AccountManager 多半已经把登录跑完了。
		_schedule_reconnect()
		return

	_socket = WebSocketPeer.new()
	# 🔴 令牌走 header，**不走 query string**。
	# `?token=xxx` 是 WebSocket 认证最常见的写法（因为浏览器的 WebSocket 构造器
	# 不让设自定义头），但我们不受那个限制。query string 会被写进每一层的
	# 访问日志 —— 那等于把凭证抄进日志文件。
	_socket.handshake_headers = PackedStringArray([
		"Authorization: Bearer %s" % token,
		"X-Device-Session: %s" % _device_id,
		# 名额来意（backend/app/admission.py）。不带这个头的会被服务器当成旧版客户端。
		"%s: %s" % [ADMISSION_HEADER, _admission_intent()],
	])
	var err := _socket.connect_to_url(_ws_url())
	if err != OK:
		push_warning("[Realtime] 连接发起失败：%d" % err)
		_socket = null
		_schedule_reconnect()
		return
	state = State.CONNECTING


func _ws_url() -> String:
	# https -> wss、http -> ws。**顺序不能反** —— 先替换 "http" 的话，
	# "https://" 会先被改成 "ws://s"，而那个 URL 连得上才有鬼。
	var base := AccountConfig.backend_url()
	if base.begins_with("https://"):
		return "wss://" + base.substr(8) + "/v1/ws"
	if base.begins_with("http://"):
		return "ws://" + base.substr(7) + "/v1/ws"
	return base + "/v1/ws"


# 已经被放进来过（这个进程里）、或者本地有没打完的对局 -> resume：服务器满了也直接放。
# 冷启动回来接着打那一局的人不该去排队 —— 排完队，那局早被 AI 打完了。
func _admission_intent() -> String:
	if _admitted or not SaveManager.load_resumable_reconnect().is_empty():
		return ADMISSION_RESUME
	return ADMISSION_ENTER


func _close_socket(code: int) -> void:
	if _socket != null:
		_socket.close(code)
		_socket = null


func _schedule_reconnect() -> void:
	if not _want_connection or _kicked:
		return
	state = State.OFFLINE
	_reconnect_timer = _reconnect_delay
	_reconnect_delay = minf(_reconnect_delay * 2.0, RECONNECT_MAX_SEC)


# --- 主循环 -------------------------------------------------------------------

func _process(delta: float) -> void:
	if _socket == null:
		_tick_reconnect(delta)
		return

	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_drain_packets()
			_tick_ping(delta)
		WebSocketPeer.STATE_CLOSED:
			_on_closed()
		_:
			pass


func _tick_reconnect(delta: float) -> void:
	if not _want_connection or _kicked:
		return
	_reconnect_timer -= delta
	if _reconnect_timer <= 0.0:
		_open()


func _tick_ping(delta: float) -> void:
	_ping_timer += delta
	if _ping_timer < _ping_interval:
		return
	_ping_timer = 0.0
	# 应用层心跳，不是 TCP keepalive。**TCP 不会告诉你对端已经没了** ——
	# 手机进隧道、被系统冻结、NAT 表项过期，连接看起来都还"连着"。
	send({"t": "ping"})


func _on_closed() -> void:
	var code := _socket.get_close_code()
	_socket = null
	if state == State.CONNECTING:
		# 从没收到过 ready 就断了 = 握手没成。
		_failed_handshakes += 1
	if code == CLOSE_KICKED:
		# 服务端在关之前还发了一条 kicked 消息，正常情况下 _drain_packets
		# 已经处理过了。这里再判一次关闭码是兜底：那条消息可能因为弱网没读到，
		# 而"被顶号却当成掉线一直重连"正是最不能出的错。
		_mark_kicked()
		return
	_schedule_reconnect()


func _drain_packets() -> void:
	while _socket.get_available_packet_count() > 0:
		var raw := _socket.get_packet().get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(raw)
		if typeof(parsed) != TYPE_DICTIONARY:
			# 服务端只发 JSON 对象。收到别的说明协议对不上，丢掉即可 ——
			# 断开连接是过度反应，且会把一个小问题变成"聊天完全不能用"。
			continue
		_handle(parsed as Dictionary)


func _handle(payload: Dictionary) -> void:
	match str(payload.get("t", "")):
		"ready":
			state = State.ONLINE
			_failed_handshakes = 0
			# 重连成功才清退避。放在 _open() 里清是错的 ——
			# 那样每次尝试都会把延迟重置成 1 秒，指数退避直接失效，
			# 而这个 bug 只在服务端真的挂掉时才显形（那时它最要命）。
			_reconnect_delay = RECONNECT_BASE_SEC
			_ping_timer = 0.0
			# 心跳间隔由服务端下发，客户端不写死。两边各写一份的话，
			# 改了服务端而客户端还按旧值发，会被判成超时掉线。
			_ping_interval = maxf(5.0, float(payload.get("heartbeat_sec", DEFAULT_PING_INTERVAL_SEC)))
		"pong":
			pass
		"kicked":
			_mark_kicked()
		ADMISSION_TYPE:
			_apply_admission(payload)
		_:
			message_received.emit(payload)


func _apply_admission(payload: Dictionary) -> void:
	match str(payload.get("state", "")):
		"admitted":
			_admitted = true
			queue_position = 0
		"queued":
			# 放进来过就不会再排（服务器对 resume 的保证）。万一收到，
			# 也不能把已经在游戏里的人标回「排队中」。
			if _admitted:
				return
			queue_position = maxi(1, int(payload.get("position", 1)))
		_:
			return
	admission_changed.emit()


func _mark_kicked() -> void:
	if _kicked:
		return
	_kicked = true
	_want_connection = false
	_close_socket(1000)
	state = State.OFFLINE
	set_process(false)
	# 🔴 只发信号，**不在这里弹对话框、更不自己跳回登录界面**。
	# 已定：被顶号必须由玩家手动确认之后才回登录页 —— 画面自己跳走
	# 在玩家眼里就是崩溃或掉线，他会去截图报 bug，而不会想到"号被别人登了"。
	# 谁弹、什么时候弹由界面层决定（对局中先挂提示，回主界面再弹）。
	kicked_by_other_device.emit()


# --- 设备标识 -----------------------------------------------------------------

func _load_or_make_device_id() -> String:
	if FileAccess.file_exists(DEVICE_FILE):
		var f := FileAccess.open(DEVICE_FILE, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				var existing := str((parsed as Dictionary).get("device_id", ""))
				if _is_valid_device_id(existing):
					return existing
	var fresh := _make_device_id()
	var out := FileAccess.open(DEVICE_FILE, FileAccess.WRITE)
	if out != null:
		out.store_string(JSON.stringify({"device_id": fresh}))
		out.close()
	return fresh


func _make_device_id() -> String:
	# 用 Crypto 而不是 randi()：同 SaveSchema.new_player_id() 那条理由 ——
	# RngService 是给回放确定性用的，同一个种子在两台设备上产生同一串数，
	# 拿它签设备号会直接撞号，而撞号的两台设备会互相顶来顶去。
	var crypto := Crypto.new()
	return "d-" + crypto.generate_random_bytes(16).hex_encode()


static func _is_valid_device_id(value: String) -> bool:
	# 与 backend/app/routes/ws.py 的 _DEVICE_RE 保持一致：[A-Za-z0-9_-]{8,64}。
	# ⚠️ 两处都有。对不上的症状是**握手被服务端拒绝**（1008），
	# 而客户端只会看到"连不上"，查起来会先怀疑令牌。
	if value.length() < 8 or value.length() > 64:
		return false
	for ch in value:
		var ok := (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
			or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-"
		if not ok:
			return false
	return true
