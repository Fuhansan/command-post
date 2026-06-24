package com.aicodingremote.app.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import com.aicodingremote.app.auth.SecureStore
import com.aicodingremote.app.auth.SessionAuth

/**
 * 全局应用状态:登录态 + 中转配对账号。对位 iOS `AppState`。
 *
 * - `account` 即用户邮箱,RelayClient 据此与 Agent 配对,冷启动也能恢复。
 * - 登录走真实鉴权(AuthAPI):外部换得 {account, token} 后调用 [login] 落库置位。
 */
class AppState(private val store: SecureStore) : ViewModel() {

    var isLoggedIn by mutableStateOf(store.token() != null)
        private set

    var userEmail by mutableStateOf(store.account())
        private set

    init {
        // 冷启动时把已持久化的 token 镜像到内存,供网络层握手携带。
        SessionAuth.token = store.token()
    }

    /** 中转配对账号(= 登录邮箱)。无邮箱时回落 demo,避免握手时为空。 */
    val account: String get() = userEmail ?: "demo"

    /** 登录成功(邮箱密码 / Google 换到本系统 token 后调用)。 */
    fun login(account: String, token: String) {
        userEmail = account
        store.saveAccount(account)
        store.saveToken(token)
        SessionAuth.token = token
        isLoggedIn = true
    }

    fun logout() {
        store.clearToken()
        store.clearAccount()
        SessionAuth.token = null
        userEmail = null
        isLoggedIn = false
    }
}
