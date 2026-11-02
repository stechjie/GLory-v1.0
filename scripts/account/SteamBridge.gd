extends RefCounted

# 电脑版 Steam 的 GDScript 一侧（docs/三方登录设计.md 第八节）。插件是 addons/godotsteam（GDExtension）。
#
# 只负责几件事：Steam 能不能用、现在登录 Steam 的是谁、向 Steam 要一张给账号服务器验的票、
# 充值时等 Steam 确认窗口的结果（docs/充值系统设计.md 第五节）。拿票去换登录 / 下单是 AccountManager 的事。
#
# 🔴 代码里**不直接写 `Steam`**，一律 Engine.get_singleton：手机包和战斗服务器里没有这个插件，
# 直接写类名会让整个脚本解析失败（同 SignInBridge / VoiceService 的做法）。
# 不做 autoload、不 preload 资源、不声明 class_name —— 理由同 SignInBridge 顶上那段。

const SINGLETON := "Steam"
# 与 backend/app/config.py 的 steam_app_id 一致（Steamworks 后台的 Glory）。
const STEAM_APP_ID := 4919850
# 与 backend/app/config.py 的 steam_ticket_identity 一字不差：Steam 只放行用同一个 identity 开的票。
const TICKET_IDENTITY := "glory-account"
const TICKET_TIMEOUT_SEC := 15.0
# GetTicketForWebApiResponse_t 的 m_eResult：1 = k_EResultOK。
const RESULT_OK := 1
# 本机存着的登录凭证属于哪个 SteamID（共用电脑时判断要不要换号）。不是凭证，只是一个公开的编号。
const OWNER_PATH := "user://glory_steam_owner.txt"

# 充值时玩家可能在确认窗口里看半天、切去给 Steam 钱包充值。等满了也不算失败 ——
# 服务器每分钟扫一遍待付款的 Steam 单，点了确认的照样入账（app/iap_sync.py）。
const MICROTXN_TIMEOUT_SEC := 600.0

# 门禁换成替身用（tools/account_steam_check、tools/iap_check）。替身要有 getSteamID / getPersonaName /
# getAuthTicketForWebApi / isOverlayEnabled 四个方法和 get_ticket_for_web_api、microtransaction_auth_response
# 两个信号；设了替身就不做真初始化。
static var bridge_override: Object = null
static var _init_done := false
static var _init_ok := false


static func _steam() -> Object:
	if bridge_override != null:
		return bridge_override
	# 只有 Windows 电脑版用 Steam。Mac 编辑器里插件也在（为了不报错才带的库），但不该去连 Steam；
	# 无界面运行（门禁、战斗服务器）也不连。
	if not OS.has_feature("windows") or DisplayServer.get_name() == "headless":
		return null
	if not Engine.has_singleton(SINGLETON):
		return null
	return Engine.get_singleton(SINGLETON)


# 插件在、Steam 客户端开着并且已登录、初始化成功。只初始化一次。
static func available() -> bool:
	var steam := _steam()
	if steam == null:
		return false
	if bridge_override != null:
		return true
	if not _init_done:
		_init_done = true
		# embed_callbacks = true：插件自己每帧跑 Steam 回调，我们不用在哪个 _process 里记得调。
		var result: Variant = steam.call("steamInitEx", STEAM_APP_ID, true)
		var status := int((result as Dictionary).get("status", -1)) if result is Dictionary else -1
		_init_ok = status == 0
		if not _init_ok:
			# 最常见：Steam 客户端没开 / 没登录 / 这个账号库里没有 Glory。
			push_warning("[STEAM] 初始化失败：%s" % str((result as Dictionary).get("verbal", status) if result is Dictionary else result))
	return _init_ok


# 现在登录 Steam 的人。不可用时是空串。
static func steam_id() -> String:
	if not available():
		return ""
	var id := str(_steam().call("getSteamID"))
	return "" if id == "0" else id


static func persona_name() -> String:
	return str(_steam().call("getPersonaName")) if available() else ""


# 向 Steam 要一张给账号服务器验的票（GetAuthTicketForWebApi）。返回：
#   {"ok": true, "ticket": 十六进制}
#   {"ok": false, "error": 给人看的一句话}
# 🔴 票是凭证（几分钟内能拿它登录），不打印、不存盘。
static func ticket(tree: SceneTree) -> Dictionary:
	if not available():
		return {"ok": false, "error": "没有连上 Steam，请先打开并登录 Steam"}
	var steam := _steam()
	var waiter := _TicketWaiter.new()
	steam.connect("get_ticket_for_web_api", waiter.on_ticket)
	var handle := int(steam.call("getAuthTicketForWebApi", TICKET_IDENTITY))
	waiter.handle = handle
	var waited := 0.0
	while not waiter.done and waited < TICKET_TIMEOUT_SEC:
		await tree.create_timer(0.1).timeout
		waited += 0.1
	if steam.is_connected("get_ticket_for_web_api", waiter.on_ticket):
		steam.disconnect("get_ticket_for_web_api", waiter.on_ticket)
	if not waiter.done:
		return {"ok": false, "error": "Steam 没有回应，请稍后再试"}
	if waiter.result != RESULT_OK or waiter.buffer.is_empty():
		push_warning("[STEAM] 拿票失败 result=%d" % waiter.result)
		return {"ok": false, "error": "Steam 没给登录凭证，请稍后再试"}
	return {"ok": true, "ticket": waiter.buffer.hex_encode()}


class _TicketWaiter extends RefCounted:
	var handle := -1
	var done := false
	var result := 0
	var buffer := PackedByteArray()

	func on_ticket(auth_ticket: int, p_result: int, _ticket_size: int, ticket_buffer: PackedByteArray) -> void:
		# 信号是广播的：别的地方同时要票时，也会收到不属于自己的那张。
		if handle >= 0 and auth_ticket != handle:
			return
		result = p_result
		buffer = ticket_buffer
		done = true


# --- 充值（docs/充值系统设计.md 第五节）---------------------------------------------------
# 服务器先向 Steam 下单（InitTxn），Steam 在游戏画面上弹确认窗口。玩家点了确认 / 取消，
# Steam 回 MicroTxnAuthorizationResponse（插件里是 microtransaction_auth_response 信号）。
# 回调里的 authorized 只是提示：扣不扣钱、入不入账由服务器去问 Steam。

# 游戏里的 Steam 界面（overlay）能不能用。不能用 = 确认窗口弹不出来，钻石宝库改去浏览器付款。
# 玩家在 Steam 设置里关了「游戏中启用 Steam 界面」就是 false；刚启动那几秒也是（还在挂上来）。
static func overlay_ready() -> bool:
	return available() and bool(_steam().call("isOverlayEnabled"))


# 等确认窗口的结果。order_no = 下单时报给 Steam 的 orderid（服务器回的 steam_order_no）。
# keep_waiting 返回 false（或者它所在的窗口已经没了）就不等了：窗口关了、玩家选了改用浏览器。
# 返回 {"state": …} 之一：
#   authorized  玩家点了确认 —— 交给服务器去扣款入账，**还不算到账**
#   declined    玩家点了取消
#   timeout     等太久 —— 不算失败，服务器会自己扫这张单
#   abandoned   keep_waiting 说不等了
static func wait_microtxn(tree: SceneTree, order_no: int, timeout_sec: float = MICROTXN_TIMEOUT_SEC,
		keep_waiting: Callable = Callable()) -> Dictionary:
	if not available():
		return {"state": "timeout"}
	var steam := _steam()
	var waiter := _MicroTxnWaiter.new()
	waiter.order_no = order_no
	steam.connect("microtransaction_auth_response", waiter.on_response)
	var waited := 0.0
	var abandoned := false
	while not waiter.done and waited < timeout_sec:
		if not keep_waiting.is_null() and (not keep_waiting.is_valid() or not bool(keep_waiting.call())):
			abandoned = true
			break
		await tree.create_timer(0.1).timeout
		waited += 0.1
	if steam.is_connected("microtransaction_auth_response", waiter.on_response):
		steam.disconnect("microtransaction_auth_response", waiter.on_response)
	if waiter.done:
		return {"state": "authorized" if waiter.authorized else "declined"}
	return {"state": "abandoned" if abandoned else "timeout"}


class _MicroTxnWaiter extends RefCounted:
	var order_no := 0
	var done := false
	var authorized := false

	func on_response(_app_id: int, order_id: int, p_authorized: bool) -> void:
		# 信号是广播的：上一张没等到结果的单，它的回调也可能这时才来 —— 按 orderid 认。
		if order_id != order_no:
			return
		authorized = p_authorized
		done = true


# --- 共用电脑 -----------------------------------------------------------------------
# 本机存的登录凭证是谁的 Steam。下次启动时现在登录 Steam 的人对不上，就不用那张凭证，改用 Steam 重新登录
# —— 不然 B 打开游戏会进到 A 的号里。

static func remembered_owner() -> String:
	if not FileAccess.file_exists(OWNER_PATH):
		return ""
	return FileAccess.get_file_as_string(OWNER_PATH).strip_edges()


static func remember_owner(id: String) -> void:
	var f := FileAccess.open(OWNER_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(id)


static func forget_owner() -> void:
	if FileAccess.file_exists(OWNER_PATH):
		DirAccess.remove_absolute(OWNER_PATH)
