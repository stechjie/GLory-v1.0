extends Node
# 账号门面。**Godot 侧唯一与账号后端说话的地方。**
#
# 这条规矩来自 docs/账号系统RFC.md 第三节：UI、玩法、商城都只认这个门面，
# 谁都不许自己拼 HTTP 请求。换后端时要改的是这一个文件，不是几十个 .gd。
# 与 NetworkService（战斗链路）平级 —— 那条走 ENet，这条走 HTTPS，互不相干。
#
# 启动流程：
#
#   本地有 refresh token？
#      有 ──> POST /v1/auth/refresh
#              成功 ──> 登录完成
#              401  ──> 凭证已失效，清掉，往下走
#      没有 ─> POST /v1/auth/anonymous（带上本机 player_id）
#
# ⚠️ **绝不能反过来先试匿名注册。** /v1/auth/anonymous 天然不幂等，
# 每调一次就在 Supabase 多一个用户、在 players 多一行 —— 玩家每次启动都会
# 变成新玩家，进度看起来就没了。有凭证时必须走 refresh。

const AccountConfig := preload("res://scripts/account/AccountConfig.gd")

signal login_started()
signal login_succeeded(player_id: String, player_name: String)
signal login_failed(reason: String)
# 登出（含注销账号）。WebSocket 与私聊的客户端状态靠它收尾。
signal logged_out()

enum State { IDLE, WORKING, LOGGED_IN, FAILED }

# 失败分类。**给日志与 bug 报告用的稳定标识，不是给玩家看的文案。**
#
# 为什么不直接用 last_error 那句话：它可能带上后端地址或上游返回的原文，
# 而 IssueReport 顶部的隐私规则明写着「绝不带服务器地址」——报告是要被粘进
# 聊天窗口的。分类是枚举名，粘到哪都安全，而且不会因为改了一句提示文案就让
# 日志里的历史记录对不上。
enum Failure {
	NONE,
	OFFLINE,        # 请求没发出去 / 没收到响应：断网、后端没起、DNS、超时
	RATE_LIMITED,   # 429，注册太频繁
	SERVER_ERROR,   # 5xx，后端或它上游出错
	AUTH_REJECTED,  # 401，凭证不再有效（正常流程会自动改走注册，走到这说明注册也失败了）
	CONFLICT,       # 409 且重签后仍冲突
	BAD_RESPONSE,   # HTTP 200 但响应里缺东西
	UNKNOWN,
}

var state: int = State.IDLE
var player_id := ""
var player_name := ""
# 给人看的一句话，可能含地址等细节。**不要**把它写进结构化日志或 IssueReport。
var last_error := ""
# 给机器看的分类，可以安全地进日志与报告。
var last_failure: int = Failure.NONE

# access token **只在内存里**，永不落盘。
#
# 它一小时就过期，存它没有任何收益，却多一处会泄漏的地方（日志、崩溃报告、
# 玩家发来的截图）。落盘的只有 refresh token，在 SaveManager.ACCOUNT_PATH。
var _access_token := ""

# access token 的到期时刻（本机墙钟，unix 秒）。0 = 不知道 / 没登录。
#
# 🔴 **必须用墙钟，不能用 Timer。** 手机切到后台时引擎不跑帧，Timer 也跟着停；
# 回到前台时它还以为离过期很远，而令牌早就过期了。
var _token_expires_at := 0.0
# 续期的单飞标志：同一时刻只允许一次续期在飞。
# 🔴 Supabase 的 refresh token 会轮换：两次并发续期拿同一张旧票去换，后到的那次
# 会被当成重放，严重时整条会话被吊销 —— 玩家直接掉号。
var _refreshing := false
signal _refresh_finished(ok: bool)
# 续期被 401 拒过 = 凭证已经失效。**不在会话中途改走匿名注册**（那等于游戏开着开着
# 换了一个号），等下次启动由 login() 按原流程处理。
var _refresh_dead := false
var _last_refresh_failed_at := 0.0

# 登录流程的互斥标志。**只保护登录**，不保护资料等其它请求 ——
# 那些是可以并发的，见 _request 顶部关于「每次自建 HTTPRequest」的说明。
var _busy := false


func is_logged_in() -> bool:
	return state == State.LOGGED_IN and not player_id.is_empty()


# 内存里的 access token。给以后需要带令牌的接口用；**不要写进任何文件或日志**。
func access_token() -> String:
	return _access_token


# --- 登录 ---------------------------------------------------------------------

# 启动时调一次。重复调用在进行中会被忽略，避免连点两次开出两个账号。
func login() -> void:
	if _busy:
		return
	_busy = true
	state = State.WORKING
	last_error = ""
	last_failure = Failure.NONE
	login_started.emit()

	var saved: Dictionary = SaveManager.load_account_credentials()
	var refresh_token := str(saved.get("refresh_token", ""))
	if not refresh_token.is_empty():
		var refreshed := await _post("/v1/auth/refresh", {"refresh_token": refresh_token})
		if int(refreshed.get("code", 0)) == 200:
			_finish_success(refreshed.get("body", {}))
			return
		if int(refreshed.get("code", 0)) == 401:
			# 凭证过期 / 已被轮换掉 / 被吊销。清干净再走注册，
			# 留着只会让下次启动再失败一次。
			print("[ACCOUNT] refresh 凭证已失效，改走匿名注册")
			SaveManager.clear_account_credentials()
		else:
			# 网络不通、后端没起、5xx —— 这些**不是**凭证问题。
			# 这时候绝不能去注册新账号：那会把一个临时故障变成永久丢号。
			_finish_failure(str(refreshed.get("error", "刷新失败")),
				classify(int(refreshed.get("code", 0))))
			return

	var created := await _post("/v1/auth/anonymous", {"player_id": PlayerProfile.player_id})
	if int(created.get("code", 0)) == 200:
		_finish_success(created.get("body", {}))
		return
	if int(created.get("code", 0)) == 409:
		# 本机签发的 player_id 撞号了（概率约等于零）。服务器不许我们接管别人的
		# 账号，只能重签一个再试一次。见 backend/app/routes/auth.py 里同一处说明。
		push_warning("[ACCOUNT] player_id 已被占用，重新签发后重试")
		PlayerProfile.reissue_player_id()
		var retried := await _post("/v1/auth/anonymous", {"player_id": PlayerProfile.player_id})
		if int(retried.get("code", 0)) == 200:
			_finish_success(retried.get("body", {}))
			return
		_finish_failure(str(retried.get("error", "注册失败")),
			classify(int(retried.get("code", 0))))
		return
	_finish_failure(str(created.get("error", "注册失败")),
		classify(int(created.get("code", 0))))


func logout() -> void:
	SaveManager.clear_account_credentials()
	_access_token = ""
	_token_expires_at = 0.0
	_refresh_dead = false
	player_id = ""
	player_name = ""
	state = State.IDLE
	# 资料缓存必须一起清。留着的话，下一个人在这台设备上登录后，
	# 主菜单名牌会先画出上一个账号的昵称与好友码，直到第一次拉取回来。
	profile = {}
	profile_changed.emit(profile)
	logged_out.emit()


func _finish_success(body: Dictionary) -> void:
	player_id = str(body.get("player_id", ""))
	player_name = str(body.get("player_name", ""))
	_access_token = str(body.get("access_token", ""))
	_note_token_lifetime(body)
	_refresh_dead = false
	var refresh_token := str(body.get("refresh_token", ""))

	# ⚠️ 必须存**返回的**那个 refresh token。Supabase 默认轮换，
	# 存回旧的等于下次刷新必失败。
	if not refresh_token.is_empty() and not player_id.is_empty():
		SaveManager.save_account_credentials(refresh_token, player_id)

	state = State.LOGGED_IN
	last_failure = Failure.NONE
	_busy = false
	# 只打 player_id，**不打任何 token**。
	print("[ACCOUNT] 登录成功 player_id=%s" % player_id)
	_emit_status()
	login_succeeded.emit(player_id, player_name)


func _finish_failure(reason: String, failure: int = Failure.UNKNOWN) -> void:
	state = State.FAILED
	last_error = reason
	last_failure = failure
	_busy = false
	# push_warning 只在编辑器/调试里显眼，真机上没人看得到；结构化那行才是
	# 能在 logcat 里被 tools/android_logcat_errors.py 扫到的。两条都留。
	push_warning("[ACCOUNT] 登录失败：%s" % reason)
	_emit_status()
	login_failed.emit(reason)


# --- 令牌续期（docs/聊天系统设计.md 第二节「token 过期后重连」）----------------
#
# access token 一小时就过期（backend/app/jwt_verify.py：exp = iat + 3600）。
# 在这之前，登录之后**从来没有续过期** —— 开着游戏满一小时，好友列表、在线心跳
# 全部开始 401，而界面只会显示「请求失败」。私聊是第一个让这件事显形的功能：
# 聊天界面常开，WebSocket 断线重连时拿着过期令牌会永远握手失败。
#
# 做法是**按需续期**，不是定时器（理由见 _token_expires_at 的注释）：
#   1. 每次带令牌的请求之前，看墙钟离到期是否不足 TOKEN_REFRESH_MARGIN_SEC，是就先续
#   2. 请求仍然收到 401（令牌被提前吊销、本机时钟不准），续一次、重试一次
#   3. RealtimeService 建连之前同样先 ensure_fresh_token()

const TOKEN_REFRESH_MARGIN_SEC := 120.0
# 续期失败（断网、5xx）之后多久内不再试。在线心跳 10 秒一次，
# 断网时每一次都去续期只会把续期接口的限流额度打光。
const REFRESH_RETRY_COOLDOWN_SEC := 15.0


func _note_token_lifetime(body: Dictionary) -> void:
	var expires_in := int(body.get("expires_in", 0))
	# 后端没给就按 Supabase 默认的一小时算。宁可早续，不要晚续。
	if expires_in <= 0:
		expires_in = 3600
	_token_expires_at = Time.get_unix_time_from_system() + float(expires_in)


func _token_needs_refresh() -> bool:
	return _token_expires_at > 0.0 \
		and Time.get_unix_time_from_system() >= _token_expires_at - TOKEN_REFRESH_MARGIN_SEC


# 令牌够新就直接返回 true；快过期了就先续。给 RealtimeService 建连前用。
func ensure_fresh_token() -> bool:
	if not is_logged_in():
		return false
	if _token_needs_refresh():
		return await refresh_session()
	return true


# 用落盘的 refresh token 换一张新的 access token。返回是否成功。
#
# **单飞**：并发调用只发出一次请求，其余的等同一个结果（见 _refreshing 的注释）。
# **不改走匿名注册**：被 401 拒了只标记失效，见 _refresh_dead 的注释。
func refresh_session() -> bool:
	if _refreshing:
		return await _refresh_finished
	if not is_logged_in() or _refresh_dead:
		return false
	var now := Time.get_unix_time_from_system()
	if now - _last_refresh_failed_at < REFRESH_RETRY_COOLDOWN_SEC:
		return false
	var refresh_token := str(SaveManager.load_account_credentials().get("refresh_token", ""))
	if refresh_token.is_empty():
		return false

	_refreshing = true
	var result := await _post("/v1/auth/refresh", {"refresh_token": refresh_token})
	var code := int(result.get("code", 0))
	var ok := false
	if code == 200:
		ok = _apply_refreshed_session(result.get("body", {}))
	elif code == 401:
		_refresh_dead = true
		push_warning("[ACCOUNT] 续期被拒：凭证已失效，下次启动会重新走登录流程")
	else:
		_last_refresh_failed_at = now
	_refreshing = false
	_refresh_finished.emit(ok)
	return ok


# 只换令牌，**不发 login_succeeded**：那个信号的订阅者（资料同步、在线状态补报、
# 聊天连线）都是「刚登录」时才该做的事，续期时再跑一遍只会平白多几轮请求。
func _apply_refreshed_session(body: Dictionary) -> bool:
	# 续期换回来的必须还是同一个玩家。对不上说明凭证串了（比如存档被换过），
	# 这时绝不能在游戏开着的情况下悄悄换号。
	if str(body.get("player_id", "")) != player_id:
		push_warning("[ACCOUNT] 续期返回的 player_id 与当前不一致，放弃这次续期")
		return false
	var token := str(body.get("access_token", ""))
	if token.is_empty():
		return false
	_access_token = token
	_note_token_lifetime(body)
	# ⚠️ 同 _finish_success：必须存**返回的**那个 refresh token（Supabase 默认轮换）。
	var rotated := str(body.get("refresh_token", ""))
	if not rotated.is_empty():
		SaveManager.save_account_credentials(rotated, player_id)
	return true


# 把 HTTP 结果映射成稳定分类。
static func classify(code: int) -> int:
	if code == 0:
		return Failure.OFFLINE
	if code == 429:
		return Failure.RATE_LIMITED
	if code == 401 or code == 403:
		return Failure.AUTH_REJECTED
	if code == 409:
		return Failure.CONFLICT
	if code >= 500:
		return Failure.SERVER_ERROR
	return Failure.UNKNOWN


# 结构化状态行的载荷。**单独一个函数是为了能被门禁断言。**
#
# 硬规则：**不含任何凭证，也不含后端地址与 last_error。**
# 日志会进 logcat、会被贴进 issue、会被截图。player_id 是打的 ——
# 它不是凭证，而且没有它就没法把一份报告和库里的账号对上，那正是它的用途。
#
# tools/account_check.tscn 断言这里的键集合恰好是这四个，并用哨兵值验证
# 内存里的 access token 不会出现在输出里。加字段前先想清楚它会不会泄漏。
func status_payload() -> Dictionary:
	return {
		"state": State.keys()[state],
		"failure": Failure.keys()[last_failure],
		"player_id": player_id,
		"has_saved_credential": not str(
			SaveManager.load_account_credentials().get("refresh_token", "")).is_empty(),
	}


# 体例同 GLORY_STARTUP / GLORY_BUILD / GLORY_ISSUE，真机上 logcat 扫得到。
func _emit_status() -> void:
	print("GLORY_ACCOUNT %s" % JSON.stringify(status_payload()))


# --- 玩家资料 -----------------------------------------------------------------
#
# 设计与取舍见 docs/玩家资料系统设计.md。这四个方法是 UI 与资料后端之间的
# **全部**通道 —— ProfileScreen、MainMenu 名牌、以后的好友列表都只认它们。
#
# 全部返回 _request 的原始形状 {"code": int, "body": Dictionary, "error": String}：
# 不再包一层，是因为调用方真正要分支的就是 code（400 要显示后端那句话、
# 409 是改名冷却、0 是断网），包装只会把这些信息压扁。

# 资料的本地缓存。主菜单名牌要在**不发请求**的情况下画出真实昵称与好友码 ——
# 每次回主菜单都拉一次接口既慢又费流量，而这些字段只有玩家自己能改。
# 任何一次成功的拉取或修改都会刷新它并发信号。
var profile: Dictionary = {}

signal profile_changed(profile: Dictionary)


# 昵称永远和好友码一起显示的**唯一实现**。
#
# 刻意**不是 static**：调用方拿到的都是 autoload 实例，在实例上调静态函数
# 会被引擎警告「应当直接从类型调用」，而把警告留在控制台里久了就没人看了。
#
# ⚠️ players.player_name 不唯一（database/001 的设计）。你叫 Leno，
# 别人改名成 Leno 就能冒充你 —— 只要 UI 里存在任何一处只显示昵称的地方，
# 冒充就成立。所以显示名只能从这里出，不许有第二个拼法。
func display_name(player_name: String, friend_code: String) -> String:
	if friend_code.is_empty():
		return player_name
	return "%s #%s" % [player_name, friend_code]


func cached_display_name() -> String:
	return display_name(
		str(profile.get("player_name", "")),
		str(profile.get("friend_code", "")),
	)


func _remember_profile(result: Dictionary) -> Dictionary:
	if int(result.get("code", 0)) == 200:
		profile = result.get("body", {})
		profile_changed.emit(profile)
	return result


# 自己的完整资料，含隐藏字段与可见性开关。**一次请求拿全** ——
# 后端刻意没有拆成 /me + /me/bio，见设计文档第六节。
func fetch_my_profile() -> Dictionary:
	await sync_active_pet()
	return _remember_profile(await _request(HTTPClient.METHOD_GET, "/v1/me/profile", null, true))

var _pet_sync_busy := false

func sync_active_pet() -> void:
	if _pet_sync_busy or not is_logged_in():
		return
	_pet_sync_busy = true
	while is_logged_in():
		var pet := PlayerProfile.get_active()
		var current: Variant = profile.get("showcase_pet", "")
		if pet == ("" if current == null else str(current)):
			break
		var result := await update_profile({"showcase_pet": pet})
		if int(result.get("code", 0)) != 200:
			break
		if PlayerProfile.get_active() == pet:
			break
	_pet_sync_busy = false


# 昵称 / 头像 / 头像框 / 展示宠物。只传要改的键。
# showcase_pet 传空字符串表示清空（与「不传」区分开）。
func update_profile(fields: Dictionary) -> Dictionary:
	return _remember_profile(
		await _request(HTTPClient.METHOD_PATCH, "/v1/me/profile", fields, true)
	)


# 性别 / 生日 / 地区 / 签名 + 三个可见性开关。**整份覆盖**，不是打补丁。
# 生日只能设一次：已经设过时后端会保留原值，这里不用特判。
func update_bio(fields: Dictionary) -> Dictionary:
	return _remember_profile(await _request(HTTPClient.METHOD_PUT, "/v1/me/bio", fields, true))


# 别人的资料。**不带令牌** —— 它只返回对方选择公开的内容，不需要身份。
# 隐藏的字段在响应里连键都没有，所以客户端不用（也不能）自己判可见性。
func fetch_public_profile(friend_code: String) -> Dictionary:
	var code := friend_code.strip_edges().to_upper()
	if code.length() != 8:
		# 本地就能判的失败，不必往返。用 404 让调用方的处理路径和「查无此人」一致。
		return {"code": 404, "error": "好友码是 8 位"}
	# **登录了就带上令牌**，好换回 relation 字段（「加好友 / 已是好友 / 待通过」）。
	# 没登录就照旧匿名请求 —— 这个接口本来就不要求登录，
	# 而 _request 在 authed=true 且没有令牌时会直接返回 401、根本不发请求。
	return await _request(HTTPClient.METHOD_GET, "/v1/players/by-code/%s" % code,
		null, is_logged_in())


# 注销账号。**不可撤销。**
#
# 成功之后本地必须做三件事，缺一件这个「删除」就是假的：
#   1. 清掉 refresh token（logout）—— 否则下次启动还拿着一张指向不存在玩家的凭证
#   2. 清掉资料缓存（logout）—— 否则主菜单名牌还画着刚删掉的那个人
#   3. **重签 player_id**（PlayerProfile.reset_account_state）——
#      不重签的话下次匿名注册会把同一个 id 报上去，服务端看它空着就收下，
#      同一个身份原地复活
#
# 顺序不能反：先删服务器、成功了再动本地。反过来的话，服务器删失败时
# 本地已经把凭证扔了，玩家会丢失一个**还存在**的账号。
func delete_account(confirm_friend_code: String) -> Dictionary:
	var result := await _request(
		HTTPClient.METHOD_POST, "/v1/me/delete",
		{"friend_code": confirm_friend_code}, true)
	if int(result.get("code", 0)) != 200:
		return result
	logout()
	PlayerProfile.reset_account_state()
	return result


# --- 交友（docs/交友系统设计.md）------------------------------------------------
#
# 全部走同一个 _request 出口。**列表接口的响应体是对象不是数组** ——
# _request 只接受 Dictionary，后端因此把列表包了一层（有测试钉着）。

# 心跳间隔。必须与后端 friends.HEARTBEAT_INTERVAL_SEC 一致：
# 后端按 PRESENCE_TTL(30s) 判在线，发得比它慢就会显示成离线。
const PRESENCE_HEARTBEAT_SEC := 10.0

var _presence_timer: Timer
# 房间号从哪来。**刻意用注入的 Callable，不直接引用 NetworkService** ——
# 账号门面（HTTPS）与战斗门面（ENet）是两条链路，不该互相认识
# （docs/账号系统RFC.md 第三节）。接线在 Main.gd 一处可见。
var _room_provider: Callable = Callable()
# 上一次心跳还没回来时不叠加：弱网下会堆出一串在途请求，
# 而它们携带的房间号已经过期了。
var _presence_busy := false


func _ready() -> void:
	PlayerProfile.pets_changed.connect(sync_active_pet)
	login_succeeded.connect(func(_id: String, _name: String): sync_active_pet())
	_presence_timer = Timer.new()
	_presence_timer.wait_time = PRESENCE_HEARTBEAT_SEC
	_presence_timer.autostart = false
	_presence_timer.timeout.connect(_on_presence_tick)
	add_child(_presence_timer)


# 好友码归一：去空白 + 转大写。**唯一实现** —— 库里一律存大写（database/004），
# 玩家会照着截图手抄，不该因为按了大写锁或多打一个空格失败。
static func normalize_friend_code(code: String) -> String:
	return code.strip_edges().to_upper()


# 本地就能判掉的失败，不必往返。返回空串表示合法，否则是给玩家看的原因。
static func friend_code_problem(code: String) -> String:
	var norm := normalize_friend_code(code)
	if norm.length() != 8:
		return "好友码是 8 位"
	# 与 database/004 的 check 约束同一个字母表（排掉 0 O 1 I L）。
	var re := RegEx.create_from_string("^[2-9A-HJKMNP-Z]{8}$")
	if re.search(norm) == null:
		return "好友码里有无效字符"
	return ""


func fetch_friends() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/friends", null, true)

# 已读只作用于当前账号和当前请求；同一玩家重新发送的新请求仍会提醒。
var friend_request_seen: Dictionary = {}

func friend_request_key(entry: Dictionary) -> String:
	return player_id + ":" + str(entry.get("friend_code", "")) + ":" + str(entry.get("created_at", ""))

func has_unread_friend_requests(incoming: Array) -> bool:
	for entry in incoming:
		if entry is Dictionary and not friend_request_seen.has(friend_request_key(entry)):
			return true
	return false

func mark_friend_requests_seen(incoming: Array) -> void:
	for entry in incoming:
		if entry is Dictionary:
			friend_request_seen[friend_request_key(entry)] = true

func normalize_list_response(path: String, value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	# 兼容旧账号服务的顶层数组响应，避免成功响应静默变为空列表。
	var keys := {"/v1/me/friends": "friends", "/v1/me/blocks": "blocks", "/v1/me/recent-players": "players"}
	if value is Array and keys.has(path):
		return {keys[path]: value}
	return {}


# 收到的 + 发出的**一次拿全**。后端刻意没拆成两个接口 ——
# 拆开会出「收到的到了、发出的没到」的中间态。
func fetch_friend_requests() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/friends/requests", null, true)


# 返回体的 result 是 'pending' 或 'accepted'。
# 'accepted' 是交叉请求：对方已经先加过我，这一下直接成为好友 ——
# 界面要据此提示「已成为好友」而不是「已发送」。
func send_friend_request(code: String) -> Dictionary:
	var problem := friend_code_problem(code)
	if not problem.is_empty():
		return {"code": 400, "error": problem}
	return await _request(HTTPClient.METHOD_POST, "/v1/me/friends/requests",
		{"friend_code": normalize_friend_code(code)}, true)


func accept_friend_request(code: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST,
		"/v1/me/friends/requests/%s/accept" % normalize_friend_code(code), null, true)


# 拒绝收到的 / 取消发出的 —— **两者都是删掉那一行**，没有「已拒绝」状态。
func drop_friend_request(code: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_DELETE,
		"/v1/me/friends/requests/%s" % normalize_friend_code(code), null, true)


# 删好友。**双向消失** —— 界面必须提示「对方也会从他的列表里消失」。
# 不通知对方（通知等于制造对抗，而且对方也做不了什么）。
func remove_friend(code: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_DELETE,
		"/v1/me/friends/%s" % normalize_friend_code(code), null, true)


# --- 匹配队列（docs/排位系统设计.md 第五节，backend/app/routes/matchmaking.py）----
#
# 四个接口的返回都是同一个形状：`{"state": {...}}`，而里面那份与 WebSocket 推的
# `t: "match"` 消息**一模一样**。推送是主路径，这几个是 WS 正好断着时的兜底 ——
# 两边形状一致，客户端才只需要写一套解析。

func join_match_queue(mode: String = "casual") -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/match/queue", {"mode": mode}, true)


func leave_match_queue() -> Dictionary:
	return await _request(HTTPClient.METHOD_DELETE, "/v1/match/queue", null, true)


func fetch_match_state() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/match/state", null, true)


# 确认。**重复确认不是错误** —— 弱网下客户端会重发，玩家也会点两下。
func accept_match() -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/match/accept", null, true)


# 交一份战斗服务器签过章的战报（docs/排位系统设计.md 第七节）。
#
# 客户端**不解析、不改** —— 它只是个搬运工，报文是不透明字符串。
# 一份战报里有全场六个座位的结果，所以六个人里只要有一个交上来就够；
# 账号服务器按 match_uid 去重，第二份起回 `recorded=false`，**那是成功不是失败**。
func submit_battle_report(report: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/battle/report", {"report": report}, true)


# 我的排位分、段位与信誉分。资料页「战绩」块用（docs/排位系统设计.md 第三、四节）。
#
# 段位是服务器按分数算好发下来的（tier / tier_progress），**客户端别自己再除一遍**
# —— 那就是第二个真相，改段位宽窄时两边会分叉。
func fetch_ranked() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/ranked", null, true)


# 排位时间窗口。**不要登录** —— 按钮上要显示「还有多久开」。
func fetch_ranked_window() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/match/window", null, false)


# 我打过的局（新的在前）。战绩页用。
func fetch_matches(limit: int = 20) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/matches?limit=%d" % limit, null, true)


# 最近一起玩过、但还不是好友的人。**不是战绩** ——
# 它是靠「同一时间报了同一个房间号」关联出来的，只用于加人。
func fetch_recent_players() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/recent-players", null, true)


func fetch_blocks() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/blocks", null, true)


# 拉黑。服务端会在同一事务里删掉已有好友关系与待处理请求。
# **与举报是两件事**：举报是给我们看的、异步的；拉黑即时生效。
func block_player(code: String) -> Dictionary:
	var problem := friend_code_problem(code)
	if not problem.is_empty():
		return {"code": 400, "error": problem}
	return await _request(HTTPClient.METHOD_POST, "/v1/me/blocks",
		{"friend_code": normalize_friend_code(code)}, true)


# 解除拉黑**不恢复好友关系** —— 那在拉黑时已经删掉了，要重新走请求流程。
func unblock_player(code: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_DELETE,
		"/v1/me/blocks/%s" % normalize_friend_code(code), null, true)


func fetch_presence_visibility() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/presence/visibility", null, true)


# 两个开关**整份覆盖**。取值只有 'friends' / 'nobody'（在线状态只对好友可见）。
func update_presence_visibility(presence_visibility: String, room_visibility: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_PUT, "/v1/me/presence/visibility", {
		"presence_visibility": presence_visibility,
		"room_visibility": room_visibility,
	}, true)


# --- 私聊（docs/聊天系统设计.md 批次 C）---------------------------------------
#
# 发送走这里（HTTPS），**接收走 RealtimeService 的推送**，红点等状态在 ChatService。
# 为什么发送不走 WebSocket，见 backend/app/routes/chat.py 顶部。

# 会话列表：**全部好友**，各自带最后一条与未读。聊天界面兼做选人。
func fetch_chats() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/chats", null, true)


# 某个好友的消息，按 message_id 升序。after_id > 0 是增量：只要比它新的 ——
# 断线重连、推送漏掉之后靠它补齐。推送只是「快」，正确性全押在这个游标上。
func fetch_chat_messages(code: String, after_id: int = 0) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET,
		"/v1/me/chats/%s/messages?after=%d" % [normalize_friend_code(code), maxi(0, after_id)],
		null, true)


# client_msg_id 由调用方生成，重试同一条时**原样复用** —— 服务端靠它认出重发，
# 弱网下「我发了一次、对方收到两条」就是它在挡。
func send_chat_message(code: String, body: String, client_msg_id: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST,
		"/v1/me/chats/%s/messages" % normalize_friend_code(code),
		{"body": body, "client_msg_id": client_msg_id}, true)


func mark_chat_read(code: String, last_read_id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST,
		"/v1/me/chats/%s/read" % normalize_friend_code(code),
		{"last_read_id": maxi(0, last_read_id)}, true)


# --- 公告（docs/公告系统设计.md）------------------------------------------------
#
# 只有拉列表。看过哪些、弹过哪些在 AnnouncementService（存本机），图片在 AnnouncementImages。

func fetch_announcements() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/announcements", null, true)


# 每个请求都带上客户端版本（docs/公告系统设计.md「报版本号」）。**今天服务端还不读它** ——
# 加它是为了以后能「只给旧版本弹请更新」：已经发出去的包补不上这个头，只能从这一版开始带。
# build 取 build_info.json 的 version_code；编辑器里跑没有这个文件，记 0。
const CLIENT_HEADER := "X-Glory-Client"
var _client_header_line := ""


func client_header_line() -> String:
	if _client_header_line.is_empty():
		var info: Dictionary = StartupTrace.build_info()
		_client_header_line = "%s: protocol=%d; build=%d" % [
			CLIENT_HEADER, NetworkConfig.NETWORK_PROTOCOL_VERSION, int(info.get("version_code", 0))]
	return _client_header_line


# --- 商城（docs/商城系统设计.md）------------------------------------------------
#
# 客户端**只发意图**：买什么。价格从服务端目录取、余额从服务端钱包取，
# 请求体里一个数字都不带（同 docs/P1经济账本RFC.md 第六节）。
#
# ⚠️ 这里的钱和局内金币无关。局内金币是 GameState.gold，一局一清，走战斗服务器。


# 目录**不带令牌**：它对所有人一样、不含任何玩家数据。带上反而让没登录时看不了商城。
# 「我买过没有」由调用方拿 fetch_entitlements() 自己比对。
func fetch_shop() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/shop", null, false)


# {"diamond": int, "coin": int}。付费与赠送的分账**不下发** —— 那是退款与对账的口径。
func fetch_wallet() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/wallet", null, true)


# 拥有的**内容 id**（pet_cat / preset:avatar_005），不是商品 id。
#
# 🔴 **不在这个列表里 ≠ 没有。** 不在服务端目录里的内容一律免费 ——
# 现有那 20 张头像和默认头像框都不会出现在这里。拿它当「有没有资格用」的唯一判据，
# 会让每个玩家的头像一夜之间全部失效。要判资格得先问「它卖不卖」。
func fetch_entitlements() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/entitlements", null, true)


# client_order_id 由调用方生成，**重试同一笔时原样复用** —— 服务端靠它认出重发，
# 重放原回执而不是再扣一次钱。换一个新的就是新订单，会再扣一次。
#
# 回执里的 replayed 说明这次是重放还是真的执行了：重放时别再放一次发货动画，
# 玩家早就看过了。
func place_shop_order(client_order_id: String, item_id: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/shop/orders",
		{"client_order_id": client_order_id, "item_id": item_id}, true)


# {"owned": [...], "active": "...", "needs_starter_pick": bool}
func fetch_pets() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/pets", null, true)


# 出战宠物。服务端会校验归属 —— 没有的宠物设不上去，回 403。
func set_active_pet(pet_id: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_PUT, "/v1/me/pets/active", {"pet_id": pet_id}, true)


# 新手三选一。走和购买同一条发货路径（同一张订单表、同一个幂等键），价格是 0。
func pick_starter_pet(client_order_id: String, pet_id: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/me/pets/starter",
		{"client_order_id": client_order_id, "pet_id": pet_id}, true)


# --- 出战配置与出战名片（docs/商城系统设计.md 第五节）----------------------------


# {"races": [...] | null}。null = 从没选过，用默认（默认值由 RacePick 按棋子表算，
# 账号服务器刻意不替客户端填）。
func fetch_races() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/races", null, true)


# 存出战种族。账号服务器只查「每一族你有没有资格用」；「必须正好 4 个」由
# 备战界面与战斗服务器按 RacePick 管。
func save_races(races: Array) -> Dictionary:
	return await _request(HTTPClient.METHOD_PUT, "/v1/me/races", {"races": races}, true)


# 领一张出战名片，入座（建房 / 加入房间）之前用。返回名片字符串，领不到返回空串。
#
# **不透明，原样交给战斗服务器，不解析、不改。** 验章在战斗服务器上。
# 有效期很短（60 秒），所以每次入座现领，不缓存。
func fetch_battle_card() -> String:
	var result: Dictionary = await _request(HTTPClient.METHOD_POST, "/v1/battle/card", {}, true)
	if int(result.get("code", 0)) / 100 != 2:
		return ""
	return str((result.get("body", {}) as Dictionary).get("card", ""))


# 一笔购买的幂等键（uuid v4 形状）。**生成一次，整笔重试期间都用同一个。**
#
# 用 Crypto 而不是 randi()：同 ChatService.new_client_msg_id 的理由 ——
# RngService 是给回放确定性用的，同一个种子在两台设备上会签出同一个 id，
# 那意味着两个玩家的订单幂等键会撞。
#
# ⚠️ 这是仓库里第三份逐字一样的 uuid v4 生成器
# （另两份：SaveSchema.new_player_id、ChatService.new_client_msg_id）。该合并了，
# 但那要动存档与聊天两条已经在线上跑的路径，不该顺手塞进商城这一批。
static func new_client_order_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12)]


# --- 系统邮件（docs/邮件系统设计.md）--------------------------------------------
#
# 界面不直接调这些 —— 走 MailService，那里管邮箱快照和红点。
# 这边没有「发」：发邮件只在 Supabase 里（database/012_mail.sql 的 send_mail）。

func fetch_mail() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/v1/me/mail", null, true)


func read_mail(mail_id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/me/mail/%d/read" % mail_id, {}, true)


# 领取天然幂等：服务端先锁状态行，领过的再点只回当前余额（replayed = true），不用幂等键。
func claim_mail(mail_id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/me/mail/%d/claim" % mail_id, {}, true)


func claim_all_mail() -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/me/mail/claim-all", {}, true)


func delete_mail(mail_id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/me/mail/%d/delete" % mail_id, {}, true)


func delete_read_mail() -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/v1/me/mail/delete-read", {}, true)


# --- 在线状态心跳 -------------------------------------------------------------
#
# **事件驱动 + 慢心跳**，不是纯轮询：进出房间时立刻补一次（report_presence_now），
# 平时 10 秒一次保活。状态变化那一刻才有价值，中间的重复上报没有。


# 接线入口。room_provider 返回当前房间号，0 或负数表示不在房间。
func configure_presence(room_provider: Callable) -> void:
	_room_provider = room_provider


func start_presence() -> void:
	if _presence_timer != null and _presence_timer.is_stopped():
		_presence_timer.start()
	report_presence_now()


func stop_presence() -> void:
	if _presence_timer != null:
		_presence_timer.stop()


# 进出房间、回主菜单时调它。**不等定时器** —— 好友看到的房间号要跟得上，
# 慢一个轮询周期的话「点进去发现人已经走了」会很常见。
func report_presence_now() -> void:
	await _send_presence()


func _on_presence_tick() -> void:
	await _send_presence()


func _send_presence() -> void:
	if _presence_busy or not is_logged_in():
		return
	var room := 0
	if _room_provider.is_valid():
		room = int(_room_provider.call())
	_presence_busy = true
	# room_id 传 null 表示「在线但不在房间」。0 / 负数都归到这一档 ——
	# 后端有 check (room_id is null or room_id > 0)，传 0 会被拒。
	var payload := {"room_id": room if room > 0 else null}
	await _request(HTTPClient.METHOD_PUT, "/v1/me/presence", payload, true)
	_presence_busy = false


# --- HTTP --------------------------------------------------------------------

# 所有账号请求的唯一出口。返回 {"code": int, "body": Dictionary, "error": String}。
# code 为 0 表示请求根本没发出去或没收到响应（断网、后端没起、超时）。
#
# ⚠️ **每次调用自建一个 HTTPRequest，用完就 queue_free，绝不共用一个节点。**
#
# 这里原本是全类共用一个 `_http`。那样只要有两个请求同时在飞，
# `await _http.request_completed` 就会**收到串台的信号** —— A 请求拿到 B 的响应。
# 它不报错、不崩溃，表现是「偶尔头像和名字对不上」这类查不出来的怪事。
# 登录期间只有一个请求，所以一直没暴露；资料页会同时拉 /v1/me 与 /v1/me/bio，
# 第一天就会踩到。
#
# authed=true 时带上内存里的 access token。**token 只出现在请求头里**，
# 不进日志、不进错误信息 —— 错误串会被 IssueReport 收走并贴进聊天窗口。
func _request(
	method: int,
	path: String,
	payload: Variant = null,
	authed: bool = false,
	allow_refresh: bool = true,
) -> Dictionary:
	var headers := PackedStringArray(["Content-Type: application/json", client_header_line()])
	if authed:
		# 令牌快过期就先续，免得这一趟白跑一次 401（见「令牌续期」那一节）。
		if allow_refresh and _token_needs_refresh():
			await refresh_session()
		if _access_token.is_empty():
			# 本地就能判定的失败，不必往返一次。用 401 是为了让调用方的
			# 处理路径与「服务端说令牌无效」完全一致。
			return {"code": 401, "error": "尚未登录"}
		headers.append("Authorization: Bearer %s" % _access_token)

	var http := HTTPRequest.new()
	http.timeout = AccountConfig.REQUEST_TIMEOUT_SEC
	add_child(http)

	var url := AccountConfig.endpoint(path)
	var body_text := "" if payload == null else JSON.stringify(payload)
	var err := http.request(url, headers, method, body_text)
	if err != OK:
		http.queue_free()
		return {"code": 0, "error": "请求发不出去（%s）" % error_string(err)}

	var result: Array = await http.request_completed
	http.queue_free()
	var outcome := int(result[0])
	var code := int(result[1])
	var raw := (result[3] as PackedByteArray).get_string_from_utf8()

	if outcome != HTTPRequest.RESULT_SUCCESS:
		# 连不上后端最常见：本机没起服务、真机上填了 127.0.0.1、明文被 Android 拦。
		return {"code": 0, "error": "连不上账号服务器（result=%d）" % outcome}

	# ⚠️ **不是所有响应体都是 JSON。**
	#
	# 后端 500 时 Starlette 回的是纯文本 "Internal Server Error"；
	# Caddy 的 502 回的是一段 HTML。直接丢给 JSON.parse_string 的话，
	# 引擎会在控制台刷一条红色 Parse JSON failed —— 而真正的信息
	# （HTTP 500）反倒被那条红字盖住，查错的人会往 JSON 的方向走很远。
	#
	# 用 JSON.new().parse() 而不是 parse_string()：前者把失败作为返回值给我们，
	# 后者会直接往引擎日志里打。
	var body: Dictionary = {}
	if not raw.is_empty():
		var json := JSON.new()
		if json.parse(raw) == OK:
			body = normalize_list_response(path, json.data)

	# **2xx 都算成功，不只是 200。**
	#
	# 原本只认 200。交友接口里有一批 204（删好友、拒绝请求、拉黑…），
	# 它们会掉进下面的错误分支 —— 表现是「操作其实成功了，界面却报失败」，
	# 而重试一次又会得到 404（因为第一次真的删掉了）。
	#
	# ⚠️ body 仍然只接受 Dictionary。**返回顶层数组的接口会静默变成空**，
	# 所以后端那边一律把列表包进对象（有测试钉着）。
	if code >= 200 and code < 300:
		return {"code": code, "body": body}

	# 401 且这一趟还没重试过：令牌被提前吊销、或者本机时钟不准。续一次、重试一次。
	# 服务端的 401 出在令牌校验那一步，业务逻辑还没跑 —— 所以连 POST 重试也是安全的。
	if code == 401 and authed and allow_refresh:
		var refreshed: bool = await refresh_session()
		if refreshed:
			return await _request(method, path, payload, authed, false)

	# 后端的 detail 已经脱敏（backend 那边有测试钉着不含 token），可以直接显示。
	# 拿不到 detail（响应体不是 JSON）时**不要把原文回显给玩家** ——
	# 那可能是一整页 HTML 或一段服务器内部信息。只报状态码。
	if body.has("detail"):
		return {"code": code, "error": str(body["detail"])}
	if code >= 500:
		return {"code": code, "error": "服务器出错了（HTTP %d），稍后再试" % code}
	return {"code": code, "error": "请求失败（HTTP %d）" % code}


# 登录那两个调用的薄封装。保留它是为了让登录路径一个字都不用改 ——
# 那段有 refresh/anonymous 的顺序纪律，不该在重构 HTTP 层时被顺手动到。
func _post(path: String, payload: Dictionary) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, path, payload, false)
