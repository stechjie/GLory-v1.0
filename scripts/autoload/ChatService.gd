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

var _unread: Dictionary = {}  # friend_code -> true
var _open_code := ""  # 当前在聊天界面上打开着的会话


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
	if str(payload.get("t", "")) != DM_TYPE:
		return
	var code := AccountManager.normalize_friend_code(str(payload.get("from", "")))
	var message: Variant = payload.get("message", {})
	if code.is_empty() or not (message is Dictionary):
		return
	if code != _open_code and not _unread.has(code):
		_unread[code] = true
		unread_changed.emit(true)
	dm_received.emit(code, message as Dictionary)


func _on_connection_changed(_state: int) -> void:
	# 连上（含断线重连）之后对一次账：断线期间的推送全漏了，未读只能以服务端为准。
	if RealtimeService.is_online():
		await refresh_unread()


func _on_kicked() -> void:
	_set_kicked(true)


func _set_kicked(value: bool) -> void:
	if kicked == value:
		return
	kicked = value
	kicked_changed.emit(value)
