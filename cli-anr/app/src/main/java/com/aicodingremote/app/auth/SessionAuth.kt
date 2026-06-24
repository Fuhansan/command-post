package com.aicodingremote.app.auth

/**
 * 进程级会话令牌持有者。对位 iOS `AppState.sessionToken`(静态),
 * 让不持有 [SecureStore] 的 [com.aicodingremote.app.networking.RelayClient] 也能在
 * WS auth 帧里携带当前 token。
 *
 * 由 [com.aicodingremote.app.app.AppState] 在初始化 / 登录 / 登出时写入,内存缓存即可:
 * token 的持久化由 SecureStore 负责,这里只是供网络层即时读取的镜像。
 */
object SessionAuth {
    /** 当前会话令牌(WS auth 时携带,服务器据此解析账号);未登录为 null。 */
    @Volatile
    var token: String? = null
}
