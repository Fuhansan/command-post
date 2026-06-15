package com.aicodingremote.app.auth

/**
 * Google 登录配置(Android 侧)。
 *
 * iOS 用 GoogleSignIn-iOS SDK + Info.plist 里的 GIDClientID 直接取 idToken;Android 要走
 * Credential Manager / Play Services,且依赖一个 **Web 类型** 的 OAuth Client ID(服务端
 * `auth.google.client-id` 必须与拿到的 idToken 的 `aud` 一致)。
 *
 * 在 [WEB_CLIENT_ID] 为空时,Google 按钮做优雅降级:UI 完整,点击仅提示需先配置。
 */
object GoogleSignInConfig {

    /** Web 类型 OAuth Client ID,需与服务端 auth.google.client-id 完全一致。空 = 未配置。 */
    const val WEB_CLIENT_ID: String = "575013344055-q59cve71hadhq71ruetau131aq3vh5nq.apps.googleusercontent.com"

    /** 是否已具备发起 Google 登录的条件。 */
    val isConfigured: Boolean get() = WEB_CLIENT_ID.isNotEmpty()
}
