package com.aicodingremote.app.networking

import com.aicodingremote.app.auth.SessionAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
 * 图片上传 REST(服务器 8080)。对位 iOS `ImageAPI`。
 *
 * 手机把图片字节用 HTTP 上传换回一个 id,WebSocket 控制通道只传这个 id,
 * 不再把 base64 塞进帧里(避免撑大流量、挤心跳、重传整图)。
 */
object ImageAPI {

    private val jpegMedia = "image/jpeg".toMediaType()

    // 上传走单独超时:30s 足够大多数手机图,但比鉴权(12s)宽。
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * 上传一张 JPEG,返回服务器分配的 id(如 img_1a2b3c)。
     * 服务器 IP 沿用设置页,端口固定 8080(Spring MVC,与 WS 的 8090 分开)。
     */
    suspend fun upload(jpeg: ByteArray): String = withContext(Dispatchers.IO) {
        val url = "${ServerConfig.restBaseURL()}/api/image/upload?ext=jpg"
        val builder = Request.Builder()
            .url(url)
            .post(jpeg.toRequestBody(jpegMedia))
        SessionAuth.token?.let { builder.header("Authorization", "Bearer $it") }
        http.newCall(builder.build()).execute().use { resp ->
            if (!resp.isSuccessful) throw java.io.IOException("upload failed: ${resp.code}")
            val text = resp.body?.string().orEmpty()
            val obj = json.parseToJsonElement(text) as? JsonObject
                ?: throw java.io.IOException("upload: bad json")
            (obj["id"] as? JsonPrimitive)?.contentOrNull
                ?: throw java.io.IOException("upload: missing id")
        }
    }
}
