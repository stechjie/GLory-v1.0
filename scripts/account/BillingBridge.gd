extends RefCounted

# 平台付款的 GDScript 一侧：Google Play / Apple StoreKit 2。
#
# 安卓插件在 android_plugins/glory_billing/（GloryBillingPlugin.kt）。这里只负责：
#   1. 这台设备在哪个平台付款、能不能付（直发的 APK 付不了，要去 Play 下载）；
#   2. 查当地价格、弹付款页、查没完成的付款，把插件的结果翻成几种固定状态；
#   3. 启动 / 回到前台时把没完成的付款逐张交给账号服务器（recover）。
#
# 不做 autoload、不 preload 任何资源、不声明 class_name：同 SignInBridge 文件头那两条理由
# （战斗服务器也会加载账号脚本；全局类名要先重建缓存才能打服务器包）。
#
# 🔴 付款凭证只在内存里转一手：不打印、不存盘。到没到账只认账号服务器的答复 ——
# 客户端永远不自己说「到账了」。

const SINGLETON := "GloryBilling"
const APPLE_SINGLETON := "GloryAppleBilling"
const POLL_SEC := 0.2
const QUERY_TIMEOUT_SEC := 30.0
# 付款页开着的时候玩家可能在输卡号、切去电子钱包 App 付款。等太短会把正常付款判成失败；
# 等满了也不算失败（回 timeout）—— 那笔付款下次 recover 会拿到。
const PURCHASE_TIMEOUT_SEC := 900.0

# 门禁换成替身用（tools/iap_check）。替身要有插件那五个方法。
static var bridge_override: Object = null
static var _recovering := false


static func _bridge() -> Object:
	if bridge_override != null:
		return bridge_override
	if Engine.has_singleton(APPLE_SINGLETON):
		return Engine.get_singleton(APPLE_SINGLETON)
	if Engine.has_singleton(SINGLETON):
		return Engine.get_singleton(SINGLETON)
	return null


# 这台设备在哪个平台付款。"" = 现在付不了。
static func platform() -> String:
	var bridge := _bridge()
	if bridge == null:
		return ""
	return "apple" if bridge.has_method("beginFinishTransaction") else "google"


static func can_make_payments() -> bool:
	var bridge := _bridge()
	if bridge == null:
		return false
	return bool(bridge.call("canMakePayments")) if platform() == "apple" else installed_from_play()


# 直发的 APK 用不了 Play 结算：钻石商店据此不给购买按钮，提示去 Play 下载（docs/充值系统设计.md 第十节）。
static func installed_from_play() -> bool:
	var bridge := _bridge()
	return bridge != null and bridge.has_method("installedFromPlay") and bool(bridge.call("installedFromPlay"))


# {档位编号: "RM 4.90"}。查不到的档不在里面 —— 钻石商店不给它购买按钮，不自己编一个价格。
static func prices(tree: SceneTree, ids: Array) -> Dictionary:
	var bridge := _bridge()
	if bridge == null or ids.is_empty():
		return {}
	var result := await _wait(tree, bridge, int(bridge.call("beginQueryProducts", ",".join(PackedStringArray(ids)))),
		QUERY_TIMEOUT_SEC)
	var out := {}
	if str(result.get("state", "")) == "ok":
		for raw in result.get("products", []):
			if raw is Dictionary and str(raw.get("price", "")) != "":
				out[str(raw.get("id", ""))] = str(raw["price"])
	else:
		push_warning("[BILLING] 查价格失败：%s" % str(result.get("error", result.get("state", ""))))
	return out


# 弹 Google 付款页。返回 {"state": …} 之一：
#   purchased      付了（带 token）—— 交给账号服务器核实，**还不算到账**
#   pending        付款待完成（便利店付现金这类）—— 钱到了 Google 会通知服务器
#   cancelled      玩家自己关了付款页
#   already_owned  这一档有一笔付了还没处理完的 —— 先 recover 那一笔
#   busy           已经有一个付款页开着
#   timeout        等太久没结果 —— 不算失败，下次 recover
#   error          带 error（只进日志）
static func purchase(tree: SceneTree, product_id: String, account_id: String, order_id: String) -> Dictionary:
	var bridge := _bridge()
	if bridge == null:
		return {"state": "error", "error": "no billing bridge"}
	var result := await _wait(tree, bridge, int(bridge.call("beginPurchase", product_id, account_id, order_id)),
		PURCHASE_TIMEOUT_SEC)
	var state := str(result.get("state", ""))
	if state == "pending_payment":
		return {"state": "pending"}
	if state != "ok":
		if state == "error":
			push_warning("[BILLING] 付款失败：%s" % str(result.get("error", "")))
		return result
	# 付款页只会带回这一笔；保险起见按订单号挑，挑不到就取第一张。
	var purchases: Array = result.get("purchases", [])
	var picked: Dictionary = {}
	for raw in purchases:
		if raw is Dictionary and str(raw.get("order_id", "")) == order_id:
			picked = raw
	if picked.is_empty() and not purchases.is_empty() and purchases[0] is Dictionary:
		picked = purchases[0]
	if picked.is_empty() or str(picked.get("token", "")).is_empty():
		return {"state": "error", "error": "purchase without token"}
	if platform() == "apple" and (str(picked.get("order_id", "")) != order_id
			or str(picked.get("product", "")) != product_id
			or str(picked.get("transaction_id", "")).is_empty()):
		return {"state": "timeout"} # 不交错单，不 finish；稍后从 StoreKit 补交原订单。
	return {"state": str(picked.get("state", "unknown")), "token": str(picked["token"]),
		"order_id": str(picked.get("order_id", "")), "transaction_id": str(picked.get("transaction_id", ""))}


# Apple 必须先收到此订单的服务器终态。5xx、断网、pending、错单均留给 StoreKit 重投。
# cancelled/refunded 也必须来自验签接口（包括测试单限额），不能只凭客户端猜测。
static func finish_if_confirmed(tree: SceneTree, transaction_id: String, order_id: String, result: Dictionary) -> bool:
	if platform() != "apple" or transaction_id.is_empty() or int(result.get("code", 0)) / 100 != 2:
		return false
	var body = result.get("body", {})
	if not (body is Dictionary) or str(body.get("order_id", "")) != order_id:
		return false
	if str(body.get("status", "")) not in ["credited", "cancelled", "refunded"]:
		return false
	var bridge := _bridge()
	var finished := await _wait(tree, bridge, int(bridge.call("beginFinishTransaction", transaction_id)), QUERY_TIMEOUT_SEC)
	return str(finished.get("state", "")) == "ok"


# 没完成（没消耗）的付款：[{token, product, order_id, state}]。查不到就是空数组。
static func unfinished(tree: SceneTree) -> Array:
	var bridge := _bridge()
	if bridge == null:
		return []
	var result := await _wait(tree, bridge, int(bridge.call("beginQueryPurchases")), QUERY_TIMEOUT_SEC)
	if str(result.get("state", "")) != "ok":
		push_warning("[BILLING] 查未完成的付款失败：%s" % str(result.get("error", result.get("state", ""))))
		return []
	var out := []
	for raw in result.get("purchases", []):
		if raw is Dictionary:
			out.append(raw)
	return out


# 启动、回到前台时调：把已经付了钱、还没处理完的付款逐张交给账号服务器（docs/充值系统设计.md 第六节）。
# confirm = func(order_id: String, token: String) -> Dictionary（AccountManager.confirm_google_purchase）。
# 待付款的那种不交：钱还没到，服务器等 Google 的实时通知。返回这次交了几张。
#
# 不做进门条件：一个外部服务慢不能让全员进不去（同宠物归属那条）。
static func recover(tree: SceneTree, confirm: Callable) -> int:
	if _recovering or _bridge() == null:
		return 0
	_recovering = true
	var sent := 0
	var waiting: Array = await unfinished(tree)
	for raw in waiting:
		var item: Dictionary = raw
		var order_id := str(item.get("order_id", ""))
		var token := str(item.get("token", ""))
		# 没有订单号的付款不是从我们的建单接口来的，服务器也认不出它是哪张单 —— 不交。
		if str(item.get("state", "")) != "purchased" or order_id.is_empty() or token.is_empty():
			continue
		var result: Dictionary = await confirm.call(order_id, token)
		await finish_if_confirmed(tree, str(item.get("transaction_id", "")), order_id, result)
		sent += 1
	_recovering = false
	return sent


static func _wait(tree: SceneTree, bridge: Object, request_id: int, timeout_sec: float) -> Dictionary:
	if request_id < 0:
		return {"state": "error", "error": "bridge refused the request"}
	var waited := 0.0
	while waited < timeout_sec:
		await tree.create_timer(POLL_SEC).timeout
		waited += POLL_SEC
		var result := _parse(str(bridge.call("poll", request_id)))
		if str(result.get("state", "")) != "pending":
			return result
	return {"state": "timeout"}


static func _parse(raw: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw) != OK or not (json.data is Dictionary):
		return {"state": "error", "error": "bad bridge response"}
	return json.data
