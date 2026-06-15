package com.aicodingremote.app.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Assignment
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.features.more.DevicesScreen
import com.aicodingremote.app.features.more.SettingsScreen
import com.aicodingremote.app.features.notifications.NotificationsScreen
import com.aicodingremote.app.features.tasks.TaskDetailScreen
import com.aicodingremote.app.features.tasks.TasksScreen
import com.aicodingremote.app.networking.UpdateChecker

/**
 * 主框架:底部 4 Tab(任务 / 通知 / 设备 / 设置)+ 详情页;
 * 详情页时隐藏底部栏(对位 iOS `.toolbar(.hidden, for: .tabBar)`)。
 */
@Composable
fun MainScreen(updater: UpdateChecker) {
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val showBottom = currentRoute?.startsWith(Route.SESSION_PREFIX) != true
    // 通知 Tab 角标 = 跨会话待办数(对位 iOS `.badge(relay.pendingCount)`)。
    val relay = LocalRelayClient.current

    Scaffold(
        containerColor = Theme.bg,
        bottomBar = {
            if (showBottom) {
                NavigationBar(containerColor = Theme.bg, tonalElevation = 0.dp) {
                    TabItem(nav, currentRoute, Route.TASKS, "任务", Icons.AutoMirrored.Filled.Assignment)
                    TabItem(nav, currentRoute, Route.NOTIFICATIONS, "通知", Icons.Default.Notifications, badge = relay.pendingCount)
                    TabItem(nav, currentRoute, Route.DEVICES, "设备", Icons.Default.Computer)
                    TabItem(nav, currentRoute, Route.SETTINGS, "设置", Icons.Default.Settings)
                }
            }
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .background(Theme.bg)
                .padding(padding),
        ) {
            NavHost(navController = nav, startDestination = Route.TASKS) {
                composable(Route.TASKS) {
                    TasksScreen(onOpen = { sid -> nav.navigate(Route.session(sid)) })
                }
                composable(Route.NOTIFICATIONS) {
                    NotificationsScreen(onOpen = { sid -> nav.navigate(Route.session(sid)) })
                }
                composable(Route.DEVICES) { DevicesScreen() }
                composable(Route.SETTINGS) { SettingsScreen(updater) }
                composable(Route.SESSION) { entry ->
                    val sid = entry.arguments?.getString("sid").orEmpty()
                    TaskDetailScreen(sessionId = sid, onBack = { nav.popBackStack() })
                }
            }
        }
    }
}

private object Route {
    const val TASKS = "tasks"
    const val NOTIFICATIONS = "notifications"
    const val DEVICES = "devices"
    const val SETTINGS = "settings"
    const val SESSION_PREFIX = "session/"
    const val SESSION = "session/{sid}"
    fun session(sid: String) = "$SESSION_PREFIX$sid"
}

@Composable
private fun RowScope.TabItem(
    nav: NavHostController,
    currentRoute: String?,
    route: String,
    label: String,
    icon: ImageVector,
    badge: Int? = null,
) {
    NavigationBarItem(
        selected = currentRoute == route,
        onClick = {
            if (currentRoute != route) {
                nav.navigate(route) {
                    popUpTo(nav.graph.startDestinationId) { saveState = true }
                    launchSingleTop = true
                    restoreState = true
                }
            }
        },
        icon = {
            if (badge != null && badge > 0) {
                BadgedBox(badge = { Badge { Text(badge.toString()) } }) {
                    Icon(icon, contentDescription = label)
                }
            } else {
                Icon(icon, contentDescription = label)
            }
        },
        label = { Text(label) },
        colors = NavigationBarItemDefaults.colors(
            selectedIconColor = Theme.blue,
            selectedTextColor = Theme.blue,
            unselectedIconColor = Theme.textSec,
            unselectedTextColor = Theme.textSec,
            indicatorColor = Theme.cardHi,
        ),
    )
}
