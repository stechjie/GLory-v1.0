extends RefCounted

# 系统登录弹窗（Android Google、iOS Apple / Google）的 GDScript 一侧。
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
# 判断插件方法一律走它：安卓插件的方法 has_method() 查不到（见 NativeBridge.gd）。
const NativeBridge := preload("res://scripts/account/NativeBridge.gd")

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
	return bridge != null and NativeBridge.supports(bridge, "isGoogleAvailable") and bool(bridge.call("isGoogleAvailable"))


static func apple_available() -> bool:
	var bridge := _bridge()
	return bridge != null and NativeBridge.supports(bridge, "isAppleAvailable") and bool(bridge.call("isAppleAvailable"))


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
	return await sign_in(tree, "google")


static func sign_in_apple(tree: SceneTree) -> Dictionary:
	return await sign_in(tree, "apple")


static func sign_in(tree: SceneTree, provider: String) -> Dictionary:
	if provider != "google" and provider != "apple":
		return {"ok": false, "error": "不支持的登录方式"}
	var name := "Apple" if provider == "apple" else "Google"
	var bridge := _bridge()
	var begin_method := "beginAppleSignIn" if provider == "apple" else "beginGoogleSignIn"
	if bridge == null or not NativeBridge.supports(bridge, begin_method) or not NativeBridge.supports(bridge, "pollSignIn"):
		return {"ok": false, "error": "这台设备不支持 %s 登录" % name}
	var nonce := new_nonce()
	var request_id: int
	if provider == "apple":
		request_id = int(bridge.call(begin_method, nonce.sha256_text()))
	else:
		request_id = int(bridge.call(begin_method, AccountConfig.GOOGLE_WEB_CLIENT_ID, nonce.sha256_text()))
	if request_id < 0:
		return {"ok": false, "error": "打不开 %s 登录" % name}
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000)
	while Time.get_ticks_msec() < deadline:
		await tree.create_timer(POLL_SEC).timeout
		var result := _parse(str(bridge.call("pollSignIn", request_id)))
		var state := str(result.get("state", ""))
		if state == "pending":
			continue
		match state:
			"ok":
				var token := str(result.get("id_token", ""))
				if token.is_empty():
					return {"ok": false, "error": "%s 没有返回登录信息" % name}
				var signed := {"ok": true, "id_token": token, "nonce": nonce}
				if provider == "apple":
					signed["authorization_code"] = str(result.get("authorization_code", ""))
				return signed
			"cancelled":
				return {"ok": false, "cancelled": true}
			"no_account":
				return {"ok": false, "error": "这台手机上还没有 Google 账号，请先在系统设置里添加"}
			_:
				# 不记录原生错误原文：SDK 的错误可能包含授权回调参数。
				var detail := str(result.get("error", result.get("state", "")))
				return {"ok": false, "error": failure_text(detail) if provider == "google" else "Apple 登录失败，请稍后再试"}
	if NativeBridge.supports(bridge, "cancelSignIn"):
		bridge.call("cancelSignIn", request_id)
	return {"ok": false, "error": "%s 登录等待超时，请再试一次" % name}


# 「这个安装包没在 Google 登记」单独说：它不是「稍后再试」能好的，而且只有测试包会碰到 ——
# 编辑器一键出的调试包（包名、签名都对不上）就是这样（2026-10-22 真机踩到）。
# 16 = Account reauth failed（签名指纹不对），28444 = Developer console is not set up correctly。
static func failure_text(detail: String) -> String:
	if detail.contains("[16]") or detail.contains("28444") or detail.contains("Developer console"):
		return "这个安装包还不能用 Google 登录（包名或签名没在 Google 登记），请用正式包"
	return "Google 登录失败，请稍后再试"


static func _parse(raw: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw) != OK or not (json.data is Dictionary):
		return {"state": "error", "error": "bad bridge response"}
	return json.data
