package com.aicodingremote.app.networking

import android.util.Log
import com.aicodingremote.app.models.Frame
import com.aicodingremote.app.models.FrameType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.pow

/**
 * PROTOCOL §2 —— 连接状态。
 */
sealed class ConnectionState {
    object Disconnected : ConnectionState()
    object Connecting : ConnectionState()
    object Connected : ConnectionState()
    object Reconnecting : ConnectionState()
    data class Failed(val message: String) : ConnectionState()
}

/**
 * PROTOCOL §2 —— 出站长连接客户端(OkHttp WebSocket)。
 *
 * - 负责:连接 / 收发文本帧 / 心跳(OkHttp pingInterval)/ 断线指数退避重连。
 * - 回调统一切到 [Dispatchers.Main.immediate],下游(RelayClient)直接改 Compose 状态不需要再切。
 *
 * 与 cli-ios 的 `WebSocketClient` 在行为上等价。
 */
class WebSocketClient(
    private val onState: (ConnectionState) -> Unit,
) {
    var onFrame: ((Frame) -> Unit)? = null
    var onConnect: (() -> Unit)? = null

    private val http: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // WS 长连不超时
        .build()

    private var ws: WebSocket? = null
    private var url: String? = null
    private var retry = 0
    private var manualClose = false   // 用户主动断开 → 不自动重连,等手动重连

    private var heartbeatJob: Job? = null
    @Volatile private var lastPongAt = System.currentTimeMillis()

    // 所有回调切到主线程,避免 Compose 状态在 OkHttp dispatcher 上被修改。
    private val callbackScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun connect(url: String) {
        this.url = url
        this.manualClose = false
        emit(ConnectionState.Connecting)
        val req = Request.Builder().url(url).build()
        ws = http.newWebSocket(req, listener)
    }

    fun disconnect() {
        manualClose = true
        stopHeartbeat()
        ws?.close(NORMAL_CLOSURE, null)
        ws = null
        emit(ConnectionState.Disconnected)
    }

    /**
     * 应用层心跳:25s 一次 ping;70s 没收到 pong 视为僵死连接(切网/锁屏后的
     * TCP 黑洞,send 不报错只有心跳能发现),主动断开走重连。
     * 与 OkHttp 协议层 pingInterval 互补:这里是应用层帧,服务器/agent 回应用层 pong。
     */
    private fun startHeartbeat() {
        stopHeartbeat()
        lastPongAt = System.currentTimeMillis()
        heartbeatJob = callbackScope.launch {
            while (isActive) {
                delay(25_000)
                if (System.currentTimeMillis() - lastPongAt > 70_000) {
                    stopHeartbeat()
                    ws?.cancel()
                    ws = null
                    if (!manualClose) scheduleReconnect()
                    return@launch
                }
                val ts = System.currentTimeMillis()
                ws?.send("{\"v\":1,\"t\":\"ping\",\"id\":\"p_android\",\"ts\":$ts}")
            }
        }
    }

    private fun stopHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
    }

    /** 发送一条已序列化好的 JSON 文本帧。 */
    fun sendRaw(text: String) {
        val sent = ws?.send(text) ?: false
        if (!sent) Log.w(TAG, "send dropped (no open socket): $text")
    }

    // MARK: - 内部

    private fun emit(state: ConnectionState) {
        callbackScope.launch { onState(state) }
    }

    private fun scheduleReconnect() {
        val u = url ?: return
        retry += 1
        val delaySec = min(2.0.pow(retry.toDouble()), 30.0) // 指数退避,封顶 30s
        emit(ConnectionState.Reconnecting)
        callbackScope.launch {
            delay((delaySec * 1000).toLong())
            if (!manualClose) connect(u)
        }
    }

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            emit(ConnectionState.Connected)
            retry = 0
            callbackScope.launch {
                startHeartbeat()
                onConnect?.invoke()   // 上层据此发 auth 帧(首连与重连都会触发)
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val frame = Frame.decode(text) ?: return
            if (frame.t is FrameType.Pong) {
                lastPongAt = System.currentTimeMillis()   // 心跳回应,不上抛
                return
            }
            callbackScope.launch { onFrame?.invoke(frame) }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.w(TAG, "ws failure", t)
            stopHeartbeat()
            if (manualClose) {
                emit(ConnectionState.Disconnected)   // 用户主动断开,保持断开态
            } else {
                emit(ConnectionState.Failed(t.localizedMessage ?: "WS error"))
                scheduleReconnect()
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(NORMAL_CLOSURE, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            stopHeartbeat()
            emit(ConnectionState.Disconnected)
            if (!manualClose) scheduleReconnect()
        }
    }

    private companion object {
        const val TAG = "WS"
        const val NORMAL_CLOSURE = 1000
    }
}
