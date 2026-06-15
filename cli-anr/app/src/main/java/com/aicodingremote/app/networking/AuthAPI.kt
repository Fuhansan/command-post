package com.aicodingremote.app.networking

import com.aicodingremote.app.auth.SessionAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * 登录 REST(服务器 8080)。对位 iOS `AuthAPI`。
 * Google idToken → 本系统 {account, token};或邮箱密码直登。
 *
 * 端点(沿用设置页服务器 IP,端口固定 8080):
 *   POST /api/auth/login         {account, password}      → AuthResult
 *   POST /api/auth/google        {idToken}                → AuthResult
 *   POST /api/auth/set-password  {token, password}        → 204/200
 *   POST /api/pair/claim         {code, token}            → 200
 */
object AuthAPI {

    /** 登录返回。Google 路径会带 hasPassword:"true"/"false"(是否已设密码)。 */
    @Serializable
    data class AuthResult(
        val account: String,
        val token: String,
        val name: String? = null,
        val hasPassword: String? = null,
    )

    /** 服务端错误(带可展示文案)。 */
    class AuthException(message: String) : Exception(message)

    private val json = Json { ignoreUnknownKeys = true }
    private val jsonMedia = "application/json".toMediaType()

    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(12, TimeUnit.SECONDS)
        .build()

    /** REST 基地址:沿用设置页的服务器 IP,端口固定 8080(Spring MVC)。 */
    private fun baseURL(): String = "${ServerConfig.restBaseURL()}/api/auth"

    /** 邮箱密码登录(日常主力:不依赖 Google,只连你自己的服务器)。 */
    suspend fun login(account: String, password: String): AuthResult =
        postForResult(
            "${baseURL()}/login",
            buildJson("account" to account, "password" to password),
            "登录失败",
        )

    /** 用 Google idToken 换本系统会话令牌。 */
    suspend fun loginWithGoogle(idToken: String): AuthResult =
        postForResult(
            "${baseURL()}/google",
            buildJson("idToken" to idToken),
            "登录失败",
        )

    /** 设置密码:用 Google 登录拿到的 token 给账号设密码,之后可邮箱密码登录。 */
    suspend fun setPassword(token: String, password: String) {
        post(
            "${baseURL()}/set-password",
            buildJson("token" to token, "password" to password),
            "设置密码失败",
        )
    }

    /** 认领电脑端的配对码:把 VibeNotch 绑到当前登录账号下。 */
    suspend fun claimPair(code: String) {
        val token = SessionAuth.token ?: throw AuthException("请先登录")
        post(
            "${ServerConfig.restBaseURL()}/api/pair/claim",
            buildJson("code" to code, "token" to token),
            "配对失败",
        )
    }

    // MARK: - 内部

    private suspend fun postForResult(url: String, body: String, failPrefix: String): AuthResult =
        withContext(Dispatchers.IO) {
            val raw = post(url, body, failPrefix)
            json.decodeFromString(AuthResult.serializer(), raw)
        }

    /** 发 POST;非 200 抛带服务端 error 文案的 [AuthException],成功返回响应体文本。 */
    private suspend fun post(url: String, body: String, failPrefix: String): String =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(url)
                .post(body.toRequestBody(jsonMedia))
                .build()
            http.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    val msg = parseError(text) ?: "$failPrefix(${resp.code})"
                    throw AuthException(msg)
                }
                text
            }
        }

    private fun parseError(text: String): String? = try {
        (json.parseToJsonElement(text) as? JsonObject)
            ?.get("error")?.let { (it as? JsonPrimitive)?.contentOrNull }
    } catch (_: Throwable) {
        null
    }

    private fun buildJson(vararg pairs: Pair<String, String>): String =
        pairs.joinToString(prefix = "{", postfix = "}", separator = ",") { (k, v) ->
            "\"$k\":\"${escape(v)}\""
        }

    private fun escape(s: String): String =
        s.replace("\\", "\\\\").replace("\"", "\\\"")
}
