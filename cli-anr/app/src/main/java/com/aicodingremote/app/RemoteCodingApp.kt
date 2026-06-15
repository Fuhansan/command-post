package com.aicodingremote.app

import android.app.Application
import com.aicodingremote.app.auth.SecureStore
import com.aicodingremote.app.networking.ServerConfig

/**
 * Application 入口。仅持有跨 Activity 的轻量单例(SecureStore)。
 * RelayClient / AppState 作为 ViewModel 由 MainActivity 管理生命周期。
 */
class RemoteCodingApp : Application() {

    lateinit var secureStore: SecureStore
        private set

    override fun onCreate() {
        super.onCreate()
        secureStore = SecureStore(this)
        ServerConfig.init(this)
    }
}
