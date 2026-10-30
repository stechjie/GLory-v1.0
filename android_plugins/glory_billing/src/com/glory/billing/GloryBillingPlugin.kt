package com.glory.billing

import android.os.Build
import android.util.Log
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject

/**
 * Google Play 结算的安卓桥接（docs/充值系统设计.md 第九节）。
 *
 * 只做三件事，都不联我们的服务器：查档位的当地价格、弹 Google 付款页、查还没完成的付款。
 * 付款凭证交给 GDScript（scripts/account/BillingBridge.gd），由它交给账号服务器核实、入账、消耗 ——
 * **这里不消耗、不确认**：入没入账只有服务器知道，客户端自己消耗的话，服务器那边一出错钱就没了。
 *
 * 结果用轮询交出去（begin… 发起 → poll 取），同 GlorySignIn：结算库的回调在主线程，
 * Godot 在它自己的线程上来取，中间只隔一把锁。
 *
 * 付款时把两个值塞给 Google（BillingFlowParams）：obfuscatedAccountId = 玩家编号的散列、
 * obfuscatedProfileId = 我们的订单号。Google 把它们存在这笔付款上，账号服务器查单时比对 ——
 * 一张凭证拿到别的号、别的单上交都对不上。
 *
 * 🔴 付款凭证（purchaseToken）能拿去查这笔付款：**绝不写进日志**，只交给 GDScript。
 */
class GloryBillingPlugin(godot: Godot) : GodotPlugin(godot), PurchasesUpdatedListener {

    companion object {
        private const val TAG = "GloryBilling"
        private const val PLAY_STORE = "com.android.vending"
    }

    private val lock = Any()
    private var nextRequest = 0
    // 请求编号 → 结果 JSON。pending 的留着，取走一次有结论的就删掉。
    private val results = HashMap<Int, String>()
    // 正在进行的那一次付款（Google 一次只弹一个付款页）。0 = 没有。
    private var purchaseRequest = 0

    private var client: BillingClient? = null
    private var connecting = false
    private val waiting = ArrayList<(BillingResult) -> Unit>()

    override fun getPluginName(): String = "GloryBilling"

    /**
     * 这个包是不是从 Google Play 装的。直发的 APK 用不了 Play 结算，钻石商店据此显示「去 Play 下载」。
     * 判据是安装来源（installer package），不是签名：签名对了但从别处装的，付款页一样弹不出来。
     */
    @UsedByGodot
    fun installedFromPlay(): Boolean {
        val act = activity ?: return false
        return try {
            val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                act.packageManager.getInstallSourceInfo(act.packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                act.packageManager.getInstallerPackageName(act.packageName)
            }
            installer == PLAY_STORE
        } catch (e: Exception) {
            false
        }
    }

    /** 查档位的当地价格。idsCsv = "diamond_pack_1,diamond_pack_2"。结果 {"state":"ok","products":[…]}。 */
    @UsedByGodot
    fun beginQueryProducts(idsCsv: String): Int {
        val id = newRequest()
        val ids = idsCsv.split(",").map { it.trim() }.filter { it.isNotEmpty() }
        withClient(id) { billing ->
            queryDetails(billing, ids) { result, details ->
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    finish(id, failure(result))
                    return@queryDetails
                }
                val out = JSONArray()
                for (item in details) {
                    val offer = item.oneTimePurchaseOfferDetails ?: continue
                    out.put(JSONObject()
                        .put("id", item.productId)
                        .put("price", offer.formattedPrice)
                        .put("micros", offer.priceAmountMicros)
                        .put("currency", offer.priceCurrencyCode))
                }
                finish(id, state("ok").put("products", out))
            }
        }
        return id
    }

    /**
     * 弹 Google 付款页。accountId / profileId 见类注释。结果：
     * ok（带 purchases）/ cancelled / already_owned（这一档有一笔付了还没消耗的，先补交那一笔）/ busy / error。
     */
    @UsedByGodot
    fun beginPurchase(productId: String, accountId: String, profileId: String): Int {
        val id = newRequest()
        synchronized(lock) {
            if (purchaseRequest != 0) {
                results[id] = state("busy").toString()
                return id
            }
            purchaseRequest = id
        }
        withClient(id) { billing ->
            queryDetails(billing, listOf(productId)) { result, details ->
                val item = details.firstOrNull()
                if (result.responseCode != BillingClient.BillingResponseCode.OK || item == null) {
                    endPurchase(id, if (item == null && result.responseCode == BillingClient.BillingResponseCode.OK)
                        JSONObject().put("state", "error").put("error", "product_not_found: $productId")
                    else failure(result))
                    return@queryDetails
                }
                val act = activity
                if (act == null) {
                    endPurchase(id, JSONObject().put("state", "error").put("error", "no_activity"))
                    return@queryDetails
                }
                // 结算库 8 起一次性商品可以有多个「购买选项」，付款时必须带上选中那个的 offer token。
                // 我们每档只有一个，取「向后兼容」的那个（Play 后台默认第一个建的就是）。
                val offerToken = item.oneTimePurchaseOfferDetails?.offerToken
                if (offerToken == null) {
                    endPurchase(id, JSONObject().put("state", "error").put("error", "no_purchase_option: $productId"))
                    return@queryDetails
                }
                val params = BillingFlowParams.newBuilder()
                    .setProductDetailsParamsList(listOf(
                        BillingFlowParams.ProductDetailsParams.newBuilder()
                            .setProductDetails(item).setOfferToken(offerToken).build()))
                    .setObfuscatedAccountId(accountId)
                    .setObfuscatedProfileId(profileId)
                    .build()
                act.runOnUiThread {
                    val launched = billing.launchBillingFlow(act, params)
                    // OK = 付款页弹出来了，结果等 onPurchasesUpdated。
                    if (launched.responseCode != BillingClient.BillingResponseCode.OK) {
                        endPurchase(id, fromResponse(launched, null))
                    }
                }
            }
        }
        return id
    }

    /** 还没完成（没消耗）的付款。启动、回到前台时查一遍，逐张交给账号服务器。结果 {"state":"ok","purchases":[…]}。 */
    @UsedByGodot
    fun beginQueryPurchases(): Int {
        val id = newRequest()
        withClient(id) { billing ->
            val params = QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build()
            billing.queryPurchasesAsync(params) { result, purchases ->
                finish(id, if (result.responseCode == BillingClient.BillingResponseCode.OK)
                    state("ok").put("purchases", toJson(purchases)) else failure(result))
            }
        }
        return id
    }

    /** pending / ok / cancelled / already_owned / busy / error / unknown。 */
    @UsedByGodot
    fun poll(requestId: Int): String {
        synchronized(lock) {
            val result = results[requestId] ?: return state("unknown").toString()
            if (JSONObject(result).optString("state") != "pending") {
                results.remove(requestId)
            }
            return result
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        val id = synchronized(lock) { purchaseRequest }
        if (id == 0) {
            // 不是这次付款页带来的（比如便利店付现金的那笔这时才到）：GDScript 下次查未完成的付款会拿到它。
            Log.i(TAG, "purchase update without a pending request -> ${result.responseCode}")
            return
        }
        endPurchase(id, fromResponse(result, purchases))
    }

    // --- 连接 ----------------------------------------------------------------------------

    private fun withClient(id: Int, then: (BillingClient) -> Unit) {
        val act = activity
        if (act == null) {
            failRequest(id, JSONObject().put("state", "error").put("error", "no_activity"))
            return
        }
        act.runOnUiThread {
            val ready = client
            if (ready != null && ready.isReady) {
                then(ready)
                return@runOnUiThread
            }
            waiting.add { setup ->
                val billing = client
                if (setup.responseCode == BillingClient.BillingResponseCode.OK && billing != null) {
                    then(billing)
                } else {
                    failRequest(id, failure(setup))
                }
            }
            if (connecting) {
                return@runOnUiThread
            }
            connecting = true
            val billing = client ?: BillingClient.newBuilder(act)
                .setListener(this)
                .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
                .build()
                .also { client = it }
            billing.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    connecting = false
                    val callbacks = ArrayList(waiting)
                    waiting.clear()
                    callbacks.forEach { it(result) }
                }

                override fun onBillingServiceDisconnected() {
                    // 下一次请求会重新连。正在等的那几个没收到 onBillingSetupFinished 的话，由 GDScript 那边超时。
                    connecting = false
                }
            })
        }
    }

    private fun queryDetails(billing: BillingClient, ids: List<String>,
                             then: (BillingResult, List<ProductDetails>) -> Unit) {
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(ids.map {
                QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(it).setProductType(BillingClient.ProductType.INAPP).build()
            })
            .build()
        billing.queryProductDetailsAsync(params) { result, queried ->
            then(result, queried.productDetailsList)
        }
    }

    // --- 结果 ----------------------------------------------------------------------------

    private fun newRequest(): Int = synchronized(lock) {
        val next = ++nextRequest
        results[next] = state("pending").toString()
        next
    }

    private fun failRequest(id: Int, result: JSONObject) {
        if (synchronized(lock) { purchaseRequest == id }) endPurchase(id, result) else finish(id, result)
    }

    private fun endPurchase(id: Int, result: JSONObject) {
        synchronized(lock) {
            if (purchaseRequest == id) purchaseRequest = 0
        }
        finish(id, result)
    }

    private fun finish(id: Int, result: JSONObject) {
        // 只记结论，不记凭证。
        Log.i(TAG, "request #$id -> ${result.optString("state")} ${result.optString("error")}")
        synchronized(lock) {
            results[id] = result.toString()
        }
    }

    private fun fromResponse(result: BillingResult, purchases: List<Purchase>?): JSONObject =
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> state("ok").put("purchases", toJson(purchases ?: emptyList()))
            BillingClient.BillingResponseCode.USER_CANCELED -> state("cancelled")
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> state("already_owned")
            else -> failure(result)
        }

    private fun toJson(purchases: List<Purchase>): JSONArray {
        val out = JSONArray()
        for (purchase in purchases) {
            val ids = purchase.accountIdentifiers
            out.put(JSONObject()
                .put("token", purchase.purchaseToken)
                .put("product", purchase.products.firstOrNull() ?: "")
                .put("state", when (purchase.purchaseState) {
                    Purchase.PurchaseState.PURCHASED -> "purchased"
                    Purchase.PurchaseState.PENDING -> "pending"
                    else -> "unknown"
                })
                .put("order_id", ids?.obfuscatedProfileId ?: "")
                .put("account_id", ids?.obfuscatedAccountId ?: ""))
        }
        return out
    }

    // 结算库的错误码原样带出去（GDScript 只拿它分类和记日志），debugMessage 截短。
    private fun failure(result: BillingResult): JSONObject =
        JSONObject().put("state", "error").put("code", result.responseCode)
            .put("error", "${result.responseCode}: ${result.debugMessage}".take(300))

    private fun state(value: String): JSONObject = JSONObject().put("state", value)
}
