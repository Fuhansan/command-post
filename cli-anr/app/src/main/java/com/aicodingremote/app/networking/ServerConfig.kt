package com.aicodingremote.app.networking

import android.content.Context
import android.content.SharedPreferences

/**
 * 中转服务器地址配置。对位 iOS `RelayClient` 里的 `savedHost`/`savedPort`(UserDefaults 静态)。
 *
 * 设置页只填 IP + 端口,其余固定拼接:
 *   WS:   ws://<host>:<port>/ws
 *   REST: http://<host>:8080/...(登录 / 版本检查,端口固定 8080)
 *
 * Android 没有 iOS 的全局 UserDefaults 静态,这里用一个进程级单例 + SharedPreferences。
 * 需在进程启动时调用一次 [init](见 RemoteCodingApp),之后任意层(RelayClient / AuthAPI /
 * UpdateChecker)都能无 Context 读取。
 */
object ServerConfig {

    const val DEFAULT_HOST = "127.0.0.1"
    const val DEFAULT_PORT = 8090
    const val REST_PORT = 8080

    private const val PREFS = "relay_server"
    private const val HOST_KEY = "relay.serverHost"
    private const val PORT_KEY = "relay.serverPort"

    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        if (prefs == null) {
            prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        }
    }

    var savedHost: String
        get() = prefs?.getString(HOST_KEY, null) ?: DEFAULT_HOST
        set(value) { prefs?.edit()?.putString(HOST_KEY, sanitizeHost(value))?.apply() }

    var savedPort: Int
        get() = (prefs?.getInt(PORT_KEY, 0) ?: 0).let { if (it > 0) it else DEFAULT_PORT }
        set(value) { prefs?.edit()?.putInt(PORT_KEY, value)?.apply() }

    /** 由 IP/主机 + 端口拼出最终地址:ws://<host>:<port>/ws。无效返回 null。 */
    fun buildURL(host: String, port: Int): String? {
        val h = sanitizeHost(host)
        if (h.isEmpty() || port !in 1..65535) return null
        return "ws://$h:$port/ws"
    }

    /** 当前生效的服务器地址。 */
    fun currentURL(): String =
        buildURL(savedHost, savedPort) ?: "ws://$DEFAULT_HOST:$DEFAULT_PORT/ws"

    /** REST 基地址:沿用设置页的服务器 IP,端口固定 8080(Spring MVC)。 */
    fun restBaseURL(): String = "http://${savedHost}:$REST_PORT"

    /**
     * 清洗主机输入:容忍用户粘贴完整 URL —— 去掉 scheme、路径、自带端口。
     */
    fun sanitizeHost(raw: String): String {
        var s = raw.trim()
        for (prefix in listOf("ws://", "wss://", "http://", "https://")) {
            if (s.startsWith(prefix)) s = s.removePrefix(prefix)
        }
        s.indexOf('/').let { if (it >= 0) s = s.substring(0, it) }
        // 非 IPv6 时去掉端口
        if (!s.contains("]")) {
            s.lastIndexOf(':').let { if (it >= 0) s = s.substring(0, it) }
        }
        return s
    }
}
