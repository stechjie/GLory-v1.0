extends RefCounted

# 电脑版 Steam 的 GDScript 一侧（docs/三方登录设计.md 第八节）。插件是 addons/godotsteam（GDExtension）。
#
# 只负责三件事：Steam 能不能用、现在登录 Steam 的是谁、向 Steam 要一张给账号服务器验的票。
# 拿票去换登录是 AccountManager 的事。
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

# 门禁换成替身用（tools/account_steam_check）。替身要有 getSteamID / getPersonaName / getAuthTicketForWebApi
# 三个方法和 get_ticket_for_web_api 信号；设了替身就不做真初始化。
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
