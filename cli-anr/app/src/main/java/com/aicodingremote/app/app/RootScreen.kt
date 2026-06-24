package com.aicodingremote.app.app

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import com.aicodingremote.app.features.auth.LoginScreen
import com.aicodingremote.app.networking.RelayClient
import com.aicodingremote.app.networking.UpdateChecker

/**
 * 根视图:按登录态切登录页 / 主框架,并把 RelayClient 的连接生命周期挂在登录态上。
 * 对位 iOS `RootView`。
 *
 * 额外承担版本门禁(对位 iOS RootView 的 updater 逻辑):
 *   - status == ForceUpdate → 全屏拦截,不可进入任何界面;
 *   - showAnnouncement      → 弹可选更新公告(底部弹层);
 *   - 启动时静默 check() 一次。
 */
@Composable
fun RootScreen(appState: AppState, relay: RelayClient, updater: UpdateChecker) {
    CompositionLocalProvider(
        LocalAppState provides appState,
        LocalRelayClient provides relay,
    ) {
        LaunchedEffect(appState.isLoggedIn) {
            if (appState.isLoggedIn) relay.connect(appState.account)
            else relay.disconnect()
        }
        // 启动静默检查版本/公告(对位 iOS `.task { await updater.check() }`)。
        LaunchedEffect(Unit) { updater.check() }

        val status = updater.status
        when {
            status is UpdateChecker.Status.ForceUpdate ->
                ForceUpdateScreen(status.info)   // 低于最低可用版本:全屏拦截
            appState.isLoggedIn -> MainScreen(updater)
            else -> LoginScreen()
        }

        // 可选更新公告(对位 iOS `.sheet(isPresented: $updater.showAnnouncement)`)。
        if (updater.showAnnouncement && status is UpdateChecker.Status.UpdateAvailable) {
            AnnouncementSheet(
                info = status.info,
                onDismiss = { updater.showAnnouncement = false },
            )
        }
    }
}
