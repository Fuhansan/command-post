package com.aicodingremote.app.app

import androidx.compose.runtime.staticCompositionLocalOf
import com.aicodingremote.app.models.ComponentAction
import com.aicodingremote.app.networking.RelayClient

/**
 * 全局依赖通过 CompositionLocal 注入,对位 iOS 的 `@EnvironmentObject`。
 *
 * - [LocalAppState]:登录态;
 * - [LocalRelayClient]:中转单例;
 * - [LocalOnComponentAction]:交互组件 action 回传通道,由会话详情页提供具体实现。
 */
val LocalAppState = staticCompositionLocalOf<AppState> { error("AppState not provided") }
val LocalRelayClient = staticCompositionLocalOf<RelayClient> { error("RelayClient not provided") }
val LocalOnComponentAction = staticCompositionLocalOf<(ComponentAction) -> Unit> { { } }
