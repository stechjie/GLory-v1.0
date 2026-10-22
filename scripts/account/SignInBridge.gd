extends RefCounted

# 系统登录弹窗（Google；Apple 在 iOS 那一期）的 GDScript 一侧（docs/三方登录设计.md 第六节）。
#
# 安卓插件在 android_plugins/glory_signin/（GlorySignInPlugin.kt）。这里只负责：
#   1. 这台设备能不能用（插件在不在、有没有 Google 服务）—— 不能用的按钮一律不显示；
#   2. 弹窗、等结果，把身份证明连同 nonce 原文一起交给 AccountManager。
#
# 不做 autoload、不 preload 任何资源、不声明 class_name：战斗服务器也会加载账号脚本，
# 而它的包里不带导入资源（踩过两次）；全局类名还要先重建缓存才能打服务器包（AccountConfig 顶部）。
#
# 🔴 身份证明是凭证（一小时内能拿它登录）：只在内存里转一手，不打印、不存盘。

const AccountConfig := preload("res://scripts/account/AccountConfig.gd")

const SINGLETON := "GlorySignIn"
const POLL_SEC := 0.2
# 系统弹窗开着的时候玩家可能在挑账号、甚至临时去加一个账号。等太短会把正常操作判成失败。
const TIMEOUT_SEC := 180.0

# 门禁换成替身用（tools/account_provider_check）。替身要有插件那三个方法。
static var bridge_override: Object = null


static func _bridge() -> Object:
	if bridge_override != null:
		return bridge_override
	if Engine.has_singleton(SINGLETON):
		return Engine.get_singleton(SINGLETON)
	return null


static func google_available() -> bool:
	var bridge := _bridge()
	return bridge != null and bool(bridge.call("isGoogleAvailable"))


# iOS 那一期才有。先恒为 false：按钮不显示，启动页也不会因为它多出一个选项。
static func apple_available() -> bool:
	return false


static func any_available() -> bool:
	return google_available() or apple_available()


# 一次性的随机串。原文交给账号服务器，SHA-256 交给 Google，Supabase 核对两者
# （防止别人截到一张身份证明之后拿去重放）。
static func new_nonce() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()


# 弹 Google 登录。返回：
#   {"ok": true, "id_token": …, "nonce": 原文}
#   {"ok": false, "cancelled": true}            玩家自己关了弹窗，什么都不用提示
#   {"ok": false, "error": "给人看的一句话"}
static func sign_in_google(tree: SceneTree) -> Dictionary:
	var bridge := _bridge()
	if bridge == null:
		return {"ok": false, "error": "这台设备不支持 Google 登录"}
	var nonce := new_nonce()
	var request_id := int(bridge.call("beginGoogleSignIn", AccountConfig.GOOGLE_WEB_CLIENT_ID, nonce.sha256_text()))
	if request_id < 0:
		return {"ok": false, "error": "打不开 Google 登录"}
	var waited := 0.0
	while waited < TIMEOUT_SEC:
		await tree.create_timer(POLL_SEC).timeout
		waited += POLL_SEC
		var result := _parse(str(bridge.call("pollSignIn", request_id)))
		var state := str(result.get("state", ""))
		if state == "pending":
			continue
		match state:
			"ok":
				var token := str(result.get("id_token", ""))
				if token.is_empty():
					return {"ok": false, "error": "Google 没有返回登录信息"}
				return {"ok": true, "id_token": token, "nonce": nonce}
			"cancelled":
				return {"ok": false, "cancelled": true}
			"no_account":
				return {"ok": false, "error": "这台手机上还没有 Google 账号，请先在系统设置里添加"}
			_:
				# 插件给的原因只进日志（里面不会有身份证明），玩家看一句人话。
				push_warning("[SIGNIN] Google 登录失败：%s" % str(result.get("error", result.get("state", ""))))
				return {"ok": false, "error": "Google 登录失败，请稍后再试"}
	return {"ok": false, "error": "Google 登录等待超时，请再试一次"}


static func _parse(raw: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw) != OK or not (json.data is Dictionary):
		return {"state": "error", "error": "bad bridge response"}
	return json.data
