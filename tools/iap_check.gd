extends Node

# 充值的客户端一侧（docs/充值系统设计.md 第九节）。
#
# 守的都是**静默失效**或**钱的口径**：
#   - 插件包不是照着现在的源码打的 → 装上去跑的是旧桥接；
#   - 导出插件交给 Gradle 的结算库版本和编译用的对不上 → 第一次点购买就崩；
#   - 单例名 / 方法名 / 清单里的插件名有一处对不上 → 钻石商店悄悄说「这台设备不能充值」；
#   - 客户端自己消耗了付款 → 服务器那边一出错，钱就没了；
#   - 503 / 断网被显示成「失败」→ 玩家以为没付成又买一次（钱多半已经扣了）；
#   - 客户端还留着一份档位表 → 和服务器两份真相；
#   - 两个入口的信号没人接 → 点钻石没反应（10-27 查出来就是这样）。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/iap_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BillingBridge := preload("res://scripts/account/BillingBridge.gd")
const DiamondStore := preload("res://scenes/menu/DiamondStoreDialog.gd")

const CHECK_NAME := "iap"

const AAR_PATH := "res://addons/glory_billing/bin/GloryBilling.aar"
const PLUGIN_DIR := "res://android_plugins/glory_billing"
const KOTLIN_PATH := "res://android_plugins/glory_billing/src/com/glory/billing/GloryBillingPlugin.kt"
const GRADLE_PATH := "res://android_plugins/glory_billing/build.gradle.kts"
const MANIFEST_PATH := "res://android_plugins/glory_billing/AndroidManifest.xml"
const EXPORT_PLUGIN_PATH := "res://addons/glory_billing/glory_billing_plugin.gd"
# 与 build_aar.ps1 的 $projectFiles 一致，外加 src/ 下全部 .kt。
const PLUGIN_PROJECT_FILES := ["AndroidManifest.xml", "proguard.txt", "build.gradle.kts", "settings.gradle.kts", "gradle.properties"]
# BillingBridge 调的五个方法，Kotlin 那边必须都有（@UsedByGodot）。
const BRIDGE_METHODS := ["installedFromPlay", "beginQueryProducts", "beginPurchase", "beginQueryPurchases", "poll"]
const BILLING_ARTIFACT := "com.android.billingclient:billing"

var _h: CheckHarness


class FakeBridge extends RefCounted:
	var from_play := true
	var replies: Array[String] = []
	var purchase_args: Array = []
	var queried_ids := ""

	func installedFromPlay() -> bool:
		return from_play

	func beginQueryProducts(ids: String) -> int:
		queried_ids = ids
		return 1

	func beginPurchase(product_id: String, account_id: String, profile_id: String) -> int:
		purchase_args = [product_id, account_id, profile_id]
		return 2

	func beginQueryPurchases() -> int:
		return 3

	func poll(_request_id: int) -> String:
		if replies.is_empty():
			return '{"state":"pending"}'
		return replies.pop_front()


class FakeAppleBridge extends FakeBridge:
	var finished: Array[String] = []
	var allowed := true

	func canMakePayments() -> bool:
		return allowed

	func beginFinishTransaction(transaction_id: String) -> int:
		finished.append(transaction_id)
		return 4


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_aar_matches_source()
	_case_dependency_versions_agree()
	_case_plugin_wiring()
	_case_kotlin_never_logs_or_consumes()
	_case_unavailable_without_plugin()
	await _case_bridge_flows()
	await _case_recover_resubmits_only_paid_orders()
	await _case_apple_flows()
	_case_outcome_texts()
	_case_bonus_text()
	_case_no_client_tier_table()
	_case_entrances_wired()
	BillingBridge.bridge_override = null
	_h.finish(get_tree())


# --- 插件包与源码 -----------------------------------------------------------------

func _case_aar_matches_source() -> void:
	var zr := ZIPReader.new()
	if not _h.expect(zr.open(AAR_PATH) == OK, "aar_missing",
			"没有 %s —— 跑一次 android_plugins/glory_billing/build_aar.ps1" % AAR_PATH):
		return
	var recorded := ""
	if zr.get_files().has("glory_billing_source.sha256"):
		recorded = zr.read_file("glory_billing_source.sha256").get_string_from_utf8().strip_edges()
	zr.close()
	var actual := _source_digest()
	_h.expect(not actual.is_empty() and recorded == actual, "aar_stale",
		("插件包不是照着现在的源码打的（包里 %s…，源码 %s…）。改了 Kotlin / 清单 / Gradle 配置 / 保留规则之后"
			+ "要重跑 android_plugins/glory_billing/build_aar.ps1。") % [recorded.left(12), actual.left(12)])


# 与 build_aar.ps1 完全同一个算法：「相对路径:sha256」逐行、按码点排序、\n 连接，再 SHA-256。
func _source_digest() -> String:
	var rel := PackedStringArray(PLUGIN_PROJECT_FILES)
	_collect_sources(PLUGIN_DIR.path_join("src"), "src", rel)
	rel.sort()
	var lines := PackedStringArray()
	for path in rel:
		var sha := FileAccess.get_sha256(PLUGIN_DIR.path_join(path))
		if sha.is_empty():
			return ""
		lines.append("%s:%s" % [path, sha])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(lines).to_utf8_buffer())
	return ctx.finish().hex_encode()


func _collect_sources(dir_path: String, rel_prefix: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect_sources(dir_path.path_join(sub), rel_prefix + "/" + sub, out)
	for file in dir.get_files():
		if file.ends_with(".kt"):
			out.append(rel_prefix + "/" + file)


func _case_dependency_versions_agree() -> void:
	var compiled := _version_in(FileAccess.get_file_as_string(GRADLE_PATH), BILLING_ARTIFACT)
	var shipped := _version_in(FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH), BILLING_ARTIFACT)
	_h.expect(not compiled.is_empty() and compiled == shipped, "dependency_version_mismatch",
		"%s：编译用 %s，出包交给 Gradle 的是 %s。两边必须一样，不然第一次点购买就可能崩" % [BILLING_ARTIFACT, compiled, shipped])
	# Google 规定新包和更新不能再用 7（docs/充值系统设计.md 第五节）。
	_h.expect(int(compiled.get_slice(".", 0)) >= 8, "billing_library_too_old",
		"Play 结算库是 %s：Google 不收用 8 以下版本的新包和更新" % compiled)


static func _version_in(text: String, artifact: String) -> String:
	var re := RegEx.new()
	re.compile("\"" + artifact.replace(".", "\\.") + ":([^\"]+)\"")
	var found := re.search(text)
	return "" if found == null else found.get_string(1)


func _case_plugin_wiring() -> void:
	var kotlin := FileAccess.get_file_as_string(KOTLIN_PATH)
	var manifest := FileAccess.get_file_as_string(MANIFEST_PATH)
	var project := FileAccess.get_file_as_string("res://project.godot")
	var export_plugin := FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH)
	_h.expect(manifest.contains("org.godotengine.plugin.v2." + BillingBridge.SINGLETON)
			and manifest.contains("com.glory.billing.GloryBillingPlugin"),
		"manifest_plugin_name", "清单里的插件名必须是 org.godotengine.plugin.v2.%s，Godot 才找得到它" % BillingBridge.SINGLETON)
	_h.expect(kotlin.contains("getPluginName(): String = \"%s\"" % BillingBridge.SINGLETON),
		"singleton_name_mismatch", "Kotlin 的 getPluginName 与 BillingBridge.SINGLETON 对不上：Engine.has_singleton 永远是 false")
	for method in BRIDGE_METHODS:
		var re := RegEx.new()
		re.compile("@UsedByGodot\\s+fun " + method + "\\(")
		_h.expect(re.search(kotlin) != null, "bridge_method_missing",
			"Kotlin 桥接缺 @UsedByGodot fun %s —— BillingBridge 调它会直接报错" % method)
	_h.expect(project.contains("res://addons/glory_billing/plugin.cfg"), "export_plugin_disabled",
		"project.godot 没启用 addons/glory_billing：出包时不会带上插件，钻石商店永远说「这台设备不能充值」")
	_h.expect(export_plugin.contains("\"glory_billing/bin/GloryBilling.aar\""), "export_plugin_aar_path",
		"导出插件交出的 AAR 路径与 build_aar.ps1 的产物对不上")


# 付款凭证能拿去查这笔付款：日志里绝不能有它。消耗只能由服务器做：入没入账只有服务器知道。
func _case_kotlin_never_logs_or_consumes() -> void:
	var kotlin := FileAccess.get_file_as_string(KOTLIN_PATH)
	for line in kotlin.split("\n"):
		if line.contains("Log."):
			_h.expect(not line.to_lower().contains("token"), "kotlin_logs_token",
				"桥接的日志行里出现了付款凭证：%s" % line.strip_edges())
	for call in ["consumeAsync", "acknowledgePurchase"]:
		_h.expect(not kotlin.contains(call), "client_consumes",
			"桥接里出现了 %s：客户端自己消耗 / 确认的话，服务器那边一出错钱就没了（docs/充值系统设计.md 第五节）" % call)


func _case_unavailable_without_plugin() -> void:
	BillingBridge.bridge_override = null
	if Engine.has_singleton(BillingBridge.SINGLETON):
		_h.note("这台机器上真有 GloryBilling 单例，跳过「没有插件」那一项")
		return
	_h.expect(BillingBridge.platform() == "" and not BillingBridge.installed_from_play(), "platform_without_plugin",
		"没有插件时 platform() 必须是空：钻石商店据此说「这台设备暂时还不能充值」，而不是弹一个点不动的按钮")


# --- 桥接的几种结果 ---------------------------------------------------------------

func _case_bridge_flows() -> void:
	var fake := FakeBridge.new()
	BillingBridge.bridge_override = fake
	_h.expect(BillingBridge.platform() == "google", "platform_google", "有插件时 platform() 应是 google")

	fake.replies = ['{"state":"ok","products":[{"id":"diamond_pack_1","price":"RM 4.90"},{"id":"diamond_pack_2","price":""}]}']
	var prices: Dictionary = await BillingBridge.prices(get_tree(), ["diamond_pack_1", "diamond_pack_2"])
	_h.expect(fake.queried_ids == "diamond_pack_1,diamond_pack_2", "prices_ids", "查价格要把档位编号用逗号连起来交给插件")
	_h.expect(prices == {"diamond_pack_1": "RM 4.90"}, "prices_skip_missing",
		"查不到价格的档不能出现（钻石商店不给它购买按钮，不自己编价格）：%s" % str(prices))

	fake.replies = ['{"state":"ok","purchases":[{"token":"tok-1","state":"purchased","order_id":"order-1","product":"diamond_pack_1"}]}']
	var paid: Dictionary = await BillingBridge.purchase(get_tree(), "diamond_pack_1", "acct", "order-1")
	_h.expect(fake.purchase_args == ["diamond_pack_1", "acct", "order-1"], "purchase_args",
		"付款要把档位、玩家散列、订单号原样交给插件（服务器靠后两个核对凭证是这张单的）：%s" % str(fake.purchase_args))
	_h.expect(paid.get("state") == "purchased" and paid.get("token") == "tok-1", "purchase_ok", "付了款要带回凭证：%s" % str(paid))

	fake.replies = ['{"state":"ok","purchases":[{"token":"tok-2","state":"pending","order_id":"order-2"}]}']
	paid = await BillingBridge.purchase(get_tree(), "diamond_pack_1", "acct", "order-2")
	_h.expect(paid.get("state") == "pending", "purchase_pending", "待付款要原样报 pending，不能当成付了：%s" % str(paid))

	for reply in ['{"state":"cancelled"}', '{"state":"already_owned"}', '{"state":"error","error":"6: boom"}']:
		fake.replies = [reply]
		paid = await BillingBridge.purchase(get_tree(), "diamond_pack_1", "acct", "order-3")
		var expected := str(JSON.parse_string(reply)["state"])
		_h.expect(paid.get("state") == expected, "purchase_state_" + expected, "插件说 %s 就要原样报 %s：%s" % [expected, expected, str(paid)])

	fake.replies = ['{"state":"ok","purchases":[]}']
	paid = await BillingBridge.purchase(get_tree(), "diamond_pack_1", "acct", "order-4")
	_h.expect(paid.get("state") == "error", "purchase_without_token", "插件说成功却没给凭证，不能当成付了：%s" % str(paid))


func _case_recover_resubmits_only_paid_orders() -> void:
	var fake := FakeBridge.new()
	BillingBridge.bridge_override = fake
	fake.replies = [JSON.stringify({"state": "ok", "purchases": [
		{"token": "tok-a", "state": "purchased", "order_id": "order-a"},
		{"token": "tok-b", "state": "pending", "order_id": "order-b"},
		{"token": "tok-c", "state": "purchased", "order_id": ""},
	]})]
	var sent: Array = []
	var confirm := func(order_id: String, token: String) -> Dictionary:
		sent.append([order_id, token])
		return {"code": 200}
	var count := await BillingBridge.recover(get_tree(), confirm)
	_h.expect(count == 1 and sent == [["order-a", "tok-a"]], "recover_filters",
		"补交只交已付款、带我们订单号的那几张（待付款等服务器收 Google 通知；没订单号的服务器认不出）：%s" % str(sent))


# --- 钻石商店给玩家看的话 ----------------------------------------------------------

func _case_apple_flows() -> void:
	var fake := FakeAppleBridge.new()
	BillingBridge.bridge_override = fake
	_h.expect(BillingBridge.platform() == "apple" and BillingBridge.can_make_payments(),
		"apple_platform", "Apple 单例必须选择 apple 通道")
	fake.allowed = false
	_h.expect(not BillingBridge.can_make_payments(), "apple_restricted", "受限设备不能开始购买")
	fake.allowed = true
	fake.replies = ['{"state":"pending_payment"}']
	var paid: Dictionary = await BillingBridge.purchase(get_tree(), "diamond_pack_1", "", "apple-order")
	_h.expect(paid.get("state") == "pending", "apple_ask_to_buy", "Ask to Buy 待批准不能被当作失败或轮询未完成")
	var proof := {"token": "apple-jws", "state": "purchased", "order_id": "apple-order",
		"product": "diamond_pack_1", "transaction_id": "apple-tx"}
	fake.replies = [JSON.stringify({"state": "ok", "purchases": [proof]})]
	paid = await BillingBridge.purchase(get_tree(), "diamond_pack_1", "", "apple-order")
	_h.expect(paid.get("transaction_id") == "apple-tx" and fake.finished.is_empty(),
		"apple_not_finished_on_purchase", "购买成功只提交凭证，不能提前结束交易")
	var credited := {"code": 200, "body": {"order_id": "apple-order", "status": "credited"}}
	for response in [{"code": 503}, {"code": 0}, {"code": 403}, {"code": 429},
			{"code": 200, "body": {"order_id": "apple-order", "status": "pending"}},
			{"code": 200, "body": {"order_id": "other-order", "status": "credited"}},
			{"code": 200, "body": []}]:
		_h.expect(not await BillingBridge.finish_if_confirmed(get_tree(), "apple-tx", "apple-order", response),
			"apple_keep_unfinished", "未确认入账或错单不可结束交易")
	_h.expect(fake.finished.is_empty(), "apple_no_early_finish", "断网、限流、处理中均保留交易")
	var waiting := JSON.stringify({"state": "ok", "purchases": [proof]})
	var sent: Array = []
	var confirm := func(order_id: String, token: String) -> Dictionary:
		sent.append([order_id, token])
		return credited
	fake.replies = [waiting, '{"state":"ok"}']
	var count := await BillingBridge.recover(get_tree(), confirm)
	_h.expect(count == 1 and sent == [["apple-order", "apple-jws"]] and fake.finished == ["apple-tx"],
		"apple_recover_finish", "丢回执重交原单，服务器确认后才能结束 Apple 交易")
	for status in ["credited", "cancelled", "refunded"]:
		fake.replies = ['{"state":"ok"}']
		var done := await BillingBridge.finish_if_confirmed(get_tree(), "apple-tx", "apple-order",
			{"code": 200, "body": {"order_id": "apple-order", "status": status}})
		_h.expect(done, "apple_finish_" + status, "已验签终态应该清理 StoreKit 队列")
	proof["order_id"] = "another-order"
	fake.replies = [JSON.stringify({"state": "ok", "purchases": [proof]})]
	paid = await BillingBridge.purchase(get_tree(), "diamond_pack_1", "", "apple-order")
	_h.expect(paid.get("state") == "timeout", "apple_mismatched_order", "错单不能发给当前单或提前结束")
	_h.expect(not DiamondStore.guest_warning_text(false).contains("Google"), "apple_guest_warning", "Apple 游客提示应使用本平台文案")
	BillingBridge.bridge_override = null


func _case_outcome_texts() -> void:
	var credited := DiamondStore.outcome_of(200, {"status": "credited", "credited": 1000}, "", false)
	_h.expect(credited["kind"] == "credited" and str(credited["text"]).contains("1,000"), "outcome_credited",
		"入了账要说多少钻：%s" % str(credited))
	_h.expect(DiamondStore.outcome_of(200, {"status": "pending"}, "", false)["kind"] == "processing",
		"outcome_pending", "服务器说 pending 是「处理中」")
	var limited := DiamondStore.outcome_of(200, {"status": "cancelled", "note": "test_daily_limit"}, "", false)
	_h.expect(limited["kind"] == "cancelled" and str(limited["text"]).contains("测试"), "outcome_test_limit",
		"测试单超上限要说清楚是测试单上限，不然测的人以为付款坏了：%s" % str(limited))
	for code in [0, 500, 502, 503]:
		_h.expect(DiamondStore.outcome_of(code, {}, "连不上", false)["kind"] == "processing", "outcome_outage_%d" % code,
			"🔴 HTTP %d 必须显示「处理中」而不是失败：钱多半已经扣了，玩家会以为没付成又买一次" % code)
	var mismatch := DiamondStore.outcome_of(409, {}, "付款凭证和这张单对不上", false)
	_h.expect(mismatch["kind"] == "failed" and mismatch["text"] == "付款凭证和这张单对不上", "outcome_rejected",
		"服务器明确拒绝（4xx）才算失败，并照抄服务器的话：%s" % str(mismatch))


func _case_bonus_text() -> void:
	_h.expect(DiamondStore.bonus_text({"diamond": 500, "bonus": 60, "first_bonus": true}, false).contains("双倍"),
		"bonus_first", "这一档还有首充要标双倍")
	_h.expect(DiamondStore.bonus_text({"diamond": 500, "bonus": 60, "first_bonus": false}, false).contains("60"),
		"bonus_regular", "首充用过之后显示平时加送")
	_h.expect(DiamondStore.bonus_text({"diamond": 50, "bonus": 0, "first_bonus": false}, false).is_empty(),
		"bonus_none", "没有加送的档不写东西")
	_h.expect(DiamondStore.guest_warning_text(false).contains("Google"), "guest_warning",
		"游客付款前要提醒绑定 Google（docs/充值系统设计.md 第一节）")


# --- 档位只有服务器一份、入口都接上了 ------------------------------------------------

func _case_no_client_tier_table() -> void:
	_h.expect(not FileAccess.file_exists("res://data/diamond_products.json"), "client_tier_table",
		"data/diamond_products.json 还在：档位以服务器 data/iap_products.json 为准，客户端再留一份就是两份真相")
	for path in ["res://scenes/menu/DiamondStoreDialog.gd", "res://scenes/menu/ShopScreen.gd"]:
		_h.expect(not FileAccess.get_file_as_string(path).contains("diamond_products"), "client_tier_reference",
			"%s 还在读客户端的档位表" % path)


func _case_entrances_wired() -> void:
	var main := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	_h.expect(main.contains("_menu.diamond_shop_requested.connect(_show_diamond_store)"), "menu_entrance",
		"主菜单钻石条的信号没人接：点了没反应（10-27 之前就是这样）")
	_h.expect(main.contains("screen.diamond_store_requested.connect("), "shop_entrance",
		"商城页「+」和钻石页按钮的信号没人接：点了没反应")
	_h.expect(main.contains("AccountManager.recover_purchases()"), "recover_wired",
		"没有地方补交没完成的付款：付了钱但回执丢了的那笔要等 3 天后 Google 自动退款")
