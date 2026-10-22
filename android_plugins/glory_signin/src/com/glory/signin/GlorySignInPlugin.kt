package com.glory.signin

import android.util.Log
import androidx.core.content.ContextCompat
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONObject

/**
 * 用 Google 登录的安卓桥接（docs/三方登录设计.md 第六节）。
 *
 * 只做一件事：弹出系统的「用 Google 账号登录」，拿回一张身份证明（id_token）交给 GDScript
 * （scripts/account/SignInBridge.gd）。拿它去换登录状态是账号服务器的事，这里不联网。
 *
 * 用 Credential Manager 的回调接口（getCredentialAsync），不用协程版：协程库在包里只是
 * LiveKit 顺带进来的，不该让登录依赖语音的依赖。
 *
 * 结果用轮询交出去（beginGoogleSignIn 发起 → pollSignIn 取），同 GloryVoice 的 getStatus：
 * 系统弹窗的回调在主线程，Godot 在它自己的线程上来取，中间只隔一把锁，不用操心信号跨线程。
 *
 * 🔴 身份证明是凭证（一小时内能拿它登录）：**绝不写进日志**，只交给 GDScript。
 */
class GlorySignInPlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "GlorySignIn"
    }

    private val lock = Any()
    private var nextRequest = 0
    // 请求编号 → 结果 JSON。pending 的留着，取走一次有结论的就删掉。
    private val results = HashMap<Int, String>()

    override fun getPluginName(): String = "GlorySignIn"

    /** 这台手机能不能用 Google 登录。没有 Google 服务（比如新款华为）就是 false，按钮不显示。 */
    @UsedByGodot
    fun isGoogleAvailable(): Boolean {
        val context = activity ?: return false
        return GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
    }

    /**
     * 弹出 Google 选账号。返回请求编号（-1 = 发不起来），结果用 pollSignIn 取。
     *
     * serverClientId 是 Web 客户端编号（不是安卓客户端的）：拿到的身份证明 aud 就是它，
     * Supabase 只认这一个。nonce 是 GDScript 算好的 SHA-256，原文留在那边交给账号服务器。
     */
    @UsedByGodot
    fun beginGoogleSignIn(serverClientId: String, nonce: String): Int {
        val act = activity ?: return -1
        val id = synchronized(lock) {
            val next = ++nextRequest
            results[next] = state("pending").toString()
            next
        }
        val option = GetSignInWithGoogleOption.Builder(serverClientId).setNonce(nonce).build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        act.runOnUiThread {
            try {
                CredentialManager.create(act).getCredentialAsync(
                    act, request, null, ContextCompat.getMainExecutor(act),
                    object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                        override fun onResult(result: GetCredentialResponse) = finish(id, fromResponse(result))
                        override fun onError(e: GetCredentialException) = finish(id, fromError(e))
                    })
            } catch (e: RuntimeException) {
                finish(id, failure("start_failed", e))
            }
        }
        return id
    }

    /** pending / ok（带 id_token）/ cancelled / no_account / error / unknown。 */
    @UsedByGodot
    fun pollSignIn(requestId: Int): String {
        synchronized(lock) {
            val result = results[requestId] ?: return state("unknown").toString()
            if (JSONObject(result).optString("state") != "pending") {
                results.remove(requestId)
            }
            return result
        }
    }

    private fun finish(id: Int, result: JSONObject) {
        // 只记结论，不记身份证明。
        Log.i(TAG, "sign-in #$id -> ${result.optString("state")} ${result.optString("error")}")
        synchronized(lock) {
            results[id] = result.toString()
        }
    }

    private fun fromResponse(response: GetCredentialResponse): JSONObject {
        val credential = response.credential
        if (credential !is CustomCredential ||
            credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
            return JSONObject().put("state", "error").put("error", "unexpected credential type")
        }
        return try {
            val google = GoogleIdTokenCredential.createFrom(credential.data)
            JSONObject().put("state", "ok").put("id_token", google.idToken)
        } catch (e: GoogleIdTokenParsingException) {
            failure("parse_failed", e)
        }
    }

    private fun fromError(e: GetCredentialException): JSONObject = when (e) {
        // 玩家自己关掉了弹窗：不是错误，界面上什么都不用说。
        is GetCredentialCancellationException -> state("cancelled")
        // 手机上一个 Google 账号都没有。
        is NoCredentialException -> state("no_account")
        // 最常见的是签名指纹没登记（Google Cloud 里少了这个包的安卓客户端）：
        // 报错里会有 "Developer console is not set up correctly"。
        else -> failure(e.type, e)
    }

    private fun failure(kind: String, e: Exception): JSONObject =
        JSONObject().put("state", "error").put("error", "$kind: ${e.message ?: e.javaClass.simpleName}".take(300))

    private fun state(value: String): JSONObject = JSONObject().put("state", value)
}
