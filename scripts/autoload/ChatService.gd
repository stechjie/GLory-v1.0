extends Node

# 私聊的客户端状态（docs/聊天系统设计.md 批次 C）。
#
# 分工：
#   AccountManager   发、拉、标记已读（HTTPS）
#   RealtimeService  收推送（WebSocket）
#   本文件           未读红点、当前打开着的会话、被顶号的状态 —— 界面只看这里
#
# 为什么单独一个 autoload：未读红点要在三个界面上同时对 —— 主菜单「聊天」按钮、
# 好友列表每一行、聊天界面左栏 —— 而推送随时可能到。状态只能有一份，
# 否则一定会出现「这里亮着、那里灭了」。
#
# 第一版**只做内存缓存，不落 user://**（设计文档第八节第 8 条）：落盘就要处理
# 「本地缓存与服务端游标不一致」，而那只在换设备、清数据这些边角场景出现 ——
# 最难测、最容易错。代价是每次打开会话都拉一次，可以接受。

signal unread_changed(any_unread: bool)
signal dm_received(friend_code: String, message: Dictionary)
signal kicked_changed(kicked: bool)

# 9.17 第二批：新私聊的提示音。
#
# 挂在**这里**而不是界面上：私聊推送是随时到的（玩家可能正在备战、正在主菜单、
# 正在好友列表），而界面只有当前那一页。挂在服务上就一处覆盖全部场景。
#
# 「10 秒内只响一次」不在这里判 —— 那是 SfxService.CUE_COOLDOWN_MSEC 里
# 按 cue 记的节流窗口，和「朋友申请」共用同一条 cue 与同一个窗口
# （素材本来就是一条《聊天新信息、朋友申请》）。
const SfxService := preload("res://ui/services/SfxService.gd")

# 与 backend/app/routes/chat.py 的 DM_TYPE 一致。⚠️ 两处都有 ——
# 对不上的话推送全部掉进 RealtimeService 的「未知类型」分支：不报错，就是收不到。
const DM_TYPE := "dm"
# 与 backend/app/text_guard.py 的 CHAT_MAX、database/007 的 chat_body_length 一致。
const MAX_BODY_CHARS := 200
# 与 backend/app/chat.py 的 KEEP_PER_CONVERSATION 一致：服务端只存这么多，
# 客户端的内存缓存也只留这么多。（tools/chat_check.gd 钉着这三处。）
const HISTORY_LIMIT := 200

# 被另一台设备顶下线了。RealtimeService 那边已经停了且**不会自动重连**，
# 等玩家在聊天界面亲手点「在本设备重新连接」。
var kicked := false

# 玩家此刻在不在「对局」里（备战 / 战斗 / 结算 / 自测）。
#
# ⚠️ **不含房间（3v3 大厅）**：用户口径是「大厅、房间收到信息会即时响，对局收到不响」。
# 3v3 大厅属于「房间」，收到新消息照响；只有真正开打前后（备战→战斗→结算）才静音。
#
# 由 Main 在对局界面进出时推。**新消息的提示音只在不在对局时响**（9.28 反馈第 4 条）：
#   ① 大厅 / 房间收到 → 立即响；
#   ② 对局中（备战/战斗/结算）收到 → **不响**（打起来时一声提示音会盖住战斗音、也分心）；
#   ③ 对局结束回大厅 → 只亮红点、不补响（音效只挂在实时推送那一条路径上，
#      refresh_unread / apply_chat_list 本来就只更新红点、不播音）。
#
# 为什么要一个显式标志而不是查 NetworkService/server_phase：账号门面（HTTPS）与
# 战斗门面（ENet）是两条链路，不该互相认识（docs/账号系统RFC.md 第三节）。
# 而且「对局」不等于「有 server_phase」——自测这类本地对局也要算进去。
var in_match := false

var _unread: Dictionary = {}  # friend_code -> true
var _open_code := ""  # 当前在聊天界面上打开着的会话

# --- 世界频道（docs/聊天系统设计.md 批次 E，2026-09-27）-------------------------------
#
# **只在世界页签开着的时候订阅**（{"t": "sub", "topic": "world"}）：对局里、别的界面上一个字节都不收。
# 打开时拉最近 100 条垫底，往上翻才查库（最远 7 天前）。世界频道不挂红点 —— 它一直有人说话，
# 红点会永远亮着。只存内存，不落 user://（同私聊，设计文档第八节第 8 条）。

signal world_changed                              # 列表整体变了：打开 / 重连补拉 / 往上翻 / 有一条被删
signal world_message_added(message: Dictionary)   # 新来的一条（推送或自己发的），界面据此决定要不要跟着滚

# 与 backend/app/world_chat.py 的 TOPIC / PUSH_TYPE / HIDE_TYPE 一致（tools/chat_check.gd 钉着）——
# 对不上的话推送落进 RealtimeService 的「未知类型」分支：不报错，就是收不到。
const WORLD_TOPIC := "world"
const WORLD_TYPE := "world"
const WORLD_HIDE_TYPE := "world_hide"
# 与 backend/app/text_guard.py 的 WORLD_MAX 一致。
const WORLD_MAX_CHARS := 100
# 与 backend/app/world_chat.py 的 COOLDOWN_SEC 一致：发出去之后按钮倒数这么久，
# 免得玩家点了才被服务器回一句「发得太快了」。
const WORLD_COOLDOWN_SEC := 8.0
# 内存里最多留几条。往上翻到这么多就不再翻；新消息把最老的挤掉。
const WORLD_KEEP := 1000

# 聊天界面上次停在哪个页签（"world" / "dm"），下次打开回到那里。只存内存。
var last_chat_tab := "world"
var world_messages: Array[Dictionary] = []   # 旧到新
var world_has_more := false                   # 往上翻还可能有更早的
var world_open := false
var world_loading := false
var _world_cooldown_until_msec := 0
# 网络失败的那一句：同一句再点发送时复用它的 client_msg_id —— 它可能其实发出去了，
# 服务器认出同一个 id 就不会发两条。
var _world_retry: Dictionary = {}
# 我拉黑的人（好友码 -> true）：他们在世界频道的发言不显示。打开页签时从服务器拉一次。
var _world_blocked: Dictionary = {}


func _ready() -> void:
	RealtimeService.message_received.connect(_on_realtime_message)
	RealtimeService.connection_changed.connect(_on_connection_changed)
	RealtimeService.kicked_by_other_device.connect(_on_kicked)


# --- 对外 ---------------------------------------------------------------------

func any_unread() -> bool:
	return not _unread.is_empty()


func has_unread(code: String) -> bool:
	return _unread.has(AccountManager.normalize_friend_code(code))


# 聊天界面打开 / 切换会话时调，关掉时传空串。
# 打开着的会话收到新消息不亮红点 —— 玩家正看着它，界面会自己标已读。
func set_open_conversation(code: String) -> void:
	_open_code = "" if code.is_empty() else AccountManager.normalize_friend_code(code)
	if not _open_code.is_empty() and _unread.erase(_open_code):
		unread_changed.emit(any_unread())


# 用服务端的会话列表对账（聊天界面每次拉列表之后、WebSocket 连上之后）。
# **以服务端为准**：断线期间的推送全漏了，本地的红点只能推倒重来。
func apply_chat_list(chats: Array) -> void:
	var fresh := {}
	for entry in chats:
		if not (entry is Dictionary):
			continue
		var item := entry as Dictionary
		if not bool(item.get("unread", false)):
			continue
		var code := str(item.get("friend_code", ""))
		if not code.is_empty() and code != _open_code:
			fresh[code] = true
	if fresh != _unread:
		_unread = fresh
		unread_changed.emit(any_unread())


func refresh_unread() -> void:
	if not AccountManager.is_logged_in():
		return
	var result: Dictionary = await AccountManager.fetch_chats()
	if int(result.get("code", 0)) / 100 == 2:
		apply_chat_list((result.get("body", {}) as Dictionary).get("chats", []))


# 界面把某个会话显示到了 last_read_id 那条。红点先灭（不等网络），再告诉服务端。
func mark_read(code: String, last_read_id: int) -> void:
	var norm := AccountManager.normalize_friend_code(code)
	if _unread.erase(norm):
		unread_changed.emit(any_unread())
	if last_read_id > 0:
		await AccountManager.mark_chat_read(norm, last_read_id)


# 玩家在聊天界面点了「在本设备重新连接」。这一下会把另一台设备顶下线 ——
# 所以必须是玩家亲手点的，**绝不能自动**（否则两台设备无限互踢）。
func reconnect_here() -> void:
	_set_kicked(false)
	RealtimeService.start()


# 登出时由 Main 调。上一个账号的红点不该留给下一个人。
func reset() -> void:
	_unread.clear()
	_open_code = ""
	_set_kicked(false)
	unread_changed.emit(false)
	world_open = false
	world_messages.clear()
	world_has_more = false
	_world_retry = {}
	_world_blocked.clear()
	_world_cooldown_until_msec = 0


# --- 世界频道 ------------------------------------------------------------------------

# 世界页签打开：订阅推送、拉一次我拉黑的人、拉最近 100 条。
func open_world() -> void:
	if world_open:
		return
	world_open = true
	# 🔴 重新打开页签 = 重新拿一份，不接着用手上的旧缓存。关着页签（或者手机锁屏、断线）的那段时间，
	# 运营删掉的消息收不到推送（没订阅）；接着用旧缓存的话，删掉的那条会一直显示到重开游戏 ——
	# 2026-09-28 本机端到端复现过（用户报的「删除没有实时同步」）。
	world_messages.clear()
	world_has_more = false
	world_loading = true
	world_changed.emit()
	RealtimeService.send({"t": "sub", "topic": WORLD_TOPIC})
	await _refresh_world_blocks()
	await refresh_world()


# 世界页签关上（切到私聊、离开聊天界面）：退订，之后一个字节都不收。
func close_world() -> void:
	if not world_open:
		return
	world_open = false
	RealtimeService.send({"t": "unsub", "topic": WORLD_TOPIC})


# 最近 100 条（打开页签、断线重连之后），与手上的对账（reconcile_world）后合并。
# 返回空串 = 成功，否则是给玩家看的原因。
func refresh_world() -> String:
	world_loading = true
	var result: Dictionary = await AccountManager.fetch_world_messages()
	world_loading = false
	if int(result.get("code", 0)) / 100 != 2:
		world_changed.emit()
		return str(result.get("error", _text("加载失败", "Failed to load")))
	var body: Dictionary = result.get("body", {})
	var incoming: Array = body.get("messages", [])
	var kept := reconcile_world(world_messages, incoming)
	if kept.is_empty():
		world_has_more = bool(body.get("has_more", false))
	world_messages = kept
	_merge_world(incoming)
	world_changed.emit()
	return ""


# 断线重连后拿到的「最近一页」和手上的缓存对账，返回缓存里要留下的。纯函数，tools/chat_check 直接调。
#
# 这一页覆盖的范围（>= 这页最老的一条）**以服务器为准**：缓存里落在这个范围、这页却没有的，
# 是断线那会儿被运营删掉的（那条删除推送漏了），不留。这页之前的（往上翻出来的）照留。
# 接不上（中间漏的比一页还多）或者这页是空的：整份不留，往上翻从新的这一批开始。
static func reconcile_world(cached: Array[Dictionary], fresh: Array) -> Array[Dictionary]:
	var kept: Array[Dictionary] = []
	if cached.is_empty() or fresh.is_empty():
		return kept
	var fresh_ids := {}
	var oldest_fresh := -1
	for raw in fresh:
		if raw is Dictionary:
			var fresh_id := int((raw as Dictionary).get("message_id", 0))
			fresh_ids[fresh_id] = true
			oldest_fresh = fresh_id if oldest_fresh < 0 else mini(oldest_fresh, fresh_id)
	if oldest_fresh > int(cached.back().get("message_id", 0)):
		return kept
	for message in cached:
		var cached_id := int(message.get("message_id", 0))
		if cached_id < oldest_fresh or fresh_ids.has(cached_id):
			kept.append(message)
	return kept


# 往上翻：比手上最老的那条更早的一页。
func load_older_world() -> String:
	if world_loading or world_messages.is_empty() or world_messages.size() >= WORLD_KEEP:
		return ""
	world_loading = true
	var result: Dictionary = await AccountManager.fetch_world_messages(
		int(world_messages[0].get("message_id", 0)))
	world_loading = false
	if int(result.get("code", 0)) / 100 != 2:
		return str(result.get("error", _text("加载失败", "Failed to load")))
	var body: Dictionary = result.get("body", {})
	world_has_more = bool(body.get("has_more", false))
	_merge_world(body.get("messages", []))
	world_changed.emit()
	return ""


# 发一条。返回空串 = 发出去了；否则是给玩家看的原因（输入框里的字留着，改一改再发）。
func send_world(text: String) -> String:
	var body := text.strip_edges()
	if body.is_empty():
		return ""
	var left := world_cooldown_left()
	if left > 0.0:
		return _text("发得太快了，%d 秒后再发" % ceili(left), "Too fast. Try again in %d s" % ceili(left))
	var client_msg_id := str(_world_retry.get("id", "")) if str(_world_retry.get("text", "")) == body \
		else new_client_msg_id()
	var result: Dictionary = await AccountManager.send_world_message(body, client_msg_id)
	var code := int(result.get("code", 0))
	if code / 100 == 2:
		_world_retry = {}
		_world_cooldown_until_msec = Time.get_ticks_msec() + int(WORLD_COOLDOWN_SEC * 1000.0)
		# 推送也会送来同一条（我也订阅着），按 message_id 去重。先放进来是为了不等推送。
		var sent: Variant = (result.get("body", {}) as Dictionary).get("message")
		if sent is Dictionary:
			for added in _merge_world([sent]):
				world_message_added.emit(added)
		return ""
	if code == 0:
		_world_retry = {"text": body, "id": client_msg_id}
	return str(result.get("error", _text("发送失败", "Failed to send")))


func world_cooldown_left() -> float:
	return maxf(0.0, float(_world_cooldown_until_msec - Time.get_ticks_msec()) / 1000.0)


func is_mine(message: Dictionary) -> bool:
	var mine := str(AccountManager.profile.get("friend_code", ""))
	return not mine.is_empty() and str(message.get("from_code", "")) == mine


# 在世界频道里拉黑了某人：他已经显示的发言当场收起来，之后的也不显示。
func hide_world_sender(code: String) -> void:
	var norm := AccountManager.normalize_friend_code(code)
	_world_blocked[norm] = true
	var kept: Array[Dictionary] = []
	for message in world_messages:
		if str(message.get("from_code", "")) != norm:
			kept.append(message)
	if kept.size() != world_messages.size():
		world_messages = kept
		world_changed.emit()


func _refresh_world_blocks() -> void:
	var result: Dictionary = await AccountManager.fetch_blocks()
	if int(result.get("code", 0)) / 100 != 2:
		return  # 拉不到就先不过滤；拉黑的人照样发不了私聊，这里只是少显示他几句
	_world_blocked.clear()
	for entry in (result.get("body", {}) as Dictionary).get("blocks", []):
		if entry is Dictionary:
			_world_blocked[str((entry as Dictionary).get("friend_code", ""))] = true


# 合并进 world_messages（按 message_id 去重、排序、过滤拉黑的人）。返回真正新加进来的。
func _merge_world(incoming: Array) -> Array[Dictionary]:
	var known := {}
	for message in world_messages:
		known[int(message.get("message_id", 0))] = true
	var added: Array[Dictionary] = []
	for raw in incoming:
		if not (raw is Dictionary):
			continue
		var message_id := int((raw as Dictionary).get("message_id", 0))
		if message_id <= 0 or known.has(message_id):
			continue
		if _world_blocked.has(str((raw as Dictionary).get("from_code", ""))):
			continue
		known[message_id] = true
		var message := (raw as Dictionary).duplicate()
		world_messages.append(message)
		added.append(message)
	world_messages.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("message_id", 0)) < int(b.get("message_id", 0)))
	while world_messages.size() > WORLD_KEEP:
		world_messages.pop_front()
		world_has_more = true
	return added


# 消息旁边的时间（私聊、世界频道共用）。服务端给的是 UTC 的 isoformat（带时区与微秒）：
# 只取到秒按 UTC 解析，再换成本地时间；今天的只显示时分。
static func format_time(iso: String) -> String:
	if iso.length() < 19:
		return ""
	var unix := Time.get_unix_time_from_datetime_string(iso.substr(0, 19))
	var bias_minutes := int(Time.get_time_zone_from_system().get("bias", 0))
	var local := Time.get_datetime_dict_from_unix_time(unix + bias_minutes * 60)
	var now := Time.get_datetime_dict_from_system()
	var clock := "%02d:%02d" % [int(local["hour"]), int(local["minute"])]
	if int(local["year"]) == int(now["year"]) and int(local["month"]) == int(now["month"]) \
			and int(local["day"]) == int(now["day"]):
		return clock
	return "%02d-%02d %s" % [int(local["month"]), int(local["day"]), clock]


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh


# 客户端给每条消息生成的 uuid（v4 形状）。重试同一条时**原样复用**。
# 用 Crypto 而不是 randi()：同 RealtimeService._make_device_id 的理由 ——
# RngService 是给回放确定性用的，同一个种子在两台设备上会签出同一个 id。
static func new_client_msg_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12)]


# --- 内部 ---------------------------------------------------------------------

func _on_realtime_message(payload: Dictionary) -> void:
	match str(payload.get("t", "")):
		DM_TYPE:
			_on_dm_push(payload)
		WORLD_TYPE:
			# 没开着页签时服务器本来就不推；万一推来了（退订还在路上）也不收。
			var message: Variant = payload.get("message")
			if world_open and message is Dictionary:
				for added in _merge_world([message]):
					world_message_added.emit(added)
		WORLD_HIDE_TYPE:
			# 运营删了一条（网页后台）：正开着页签的人这边当场消失。
			var hidden_id := int(payload.get("message_id", 0))
			for i in world_messages.size():
				if int(world_messages[i].get("message_id", 0)) == hidden_id:
					world_messages.remove_at(i)
					world_changed.emit()
					break


func _on_dm_push(payload: Dictionary) -> void:
	var code := AccountManager.normalize_friend_code(str(payload.get("from", "")))
	var message: Variant = payload.get("message", {})
	if code.is_empty() or not (message is Dictionary):
		return
	if code != _open_code and not _unread.has(code):
		_unread[code] = true
		unread_changed.emit(true)
		# 红点任何时候都亮（红点不打扰，音效才打扰）。
		#
		# 音效只在这两种情况响：
		#   · 不在对局里（大厅 / 房间 / 各种菜单）—— 9.28 反馈第 4 条 ①；
		#   · 而且不是「正在看着的那个会话」（code == _open_code，消息就在眼前，
		#     再响一声是噪音）。
		# 对局中（in_match）**不响** —— 反馈 ②。对局结束回大厅时也不会补响：
		# 音效只挂在实时推送这一条路径上，而 refresh_unread / apply_chat_list 只更新红点。
		if not in_match:
			SfxService.play(SfxService.CUE_CHAT_ALERT)
	dm_received.emit(code, message as Dictionary)


func _on_connection_changed(_state: int) -> void:
	# 连上（含断线重连）之后对一次账：断线期间的推送全漏了，未读只能以服务端为准。
	if RealtimeService.is_online():
		# 世界页签开着：订阅是挂在那条旧连接上的，新连接要重新订一次，再补拉断线期间漏掉的。
		if world_open:
			RealtimeService.send({"t": "sub", "topic": WORLD_TOPIC})
			refresh_world()
		await refresh_unread()


func _on_kicked() -> void:
	_set_kicked(true)


func _set_kicked(value: bool) -> void:
	if kicked == value:
		return
	kicked = value
	kicked_changed.emit(value)
