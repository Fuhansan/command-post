package com.aicodingremote.app.features.more

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.BuildConfig
import com.aicodingremote.app.app.LocalAppState
import com.aicodingremote.app.app.LocalRelayClient
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.designsystem.darkFieldColors
import com.aicodingremote.app.models.AgentInfo
import com.aicodingremote.app.networking.AuthAPI
import com.aicodingremote.app.networking.ConnectionState
import com.aicodingremote.app.networking.RelayClient
import com.aicodingremote.app.networking.ServerConfig
import com.aicodingremote.app.networking.UpdateChecker
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 屏 4 —— 设备页:在线电脑列表(断开 / 重连)+ 配对新电脑(输入电脑端显示的 6 位配对码)。
 * 对位 iOS `DevicesView`。
 */
@Composable
fun DevicesScreen() {
    val relay = LocalRelayClient.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var claiming by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Pair<Boolean, String>?>(null) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Text("设备", color = Theme.text, fontSize = 24.sp, fontWeight = FontWeight.Bold)

            // 已连接的电脑
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .cardStyle()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("电脑代理", color = Theme.textSec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                if (relay.agents.isEmpty()) {
                    Text("暂无在线电脑", color = Theme.textTer, fontSize = 14.sp)
                } else {
                    relay.agents.forEach { agent ->
                        AgentRow(relay, agent)
                    }
                }
            }

            // 配对新电脑
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .cardStyle()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("配对新电脑", color = Theme.textSec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    "在电脑上打开 VibeNotch 设置 → 点「配对手机」,把显示的 6 位码填到这里",
                    color = Theme.textTer,
                    fontSize = 12.sp,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    OutlinedTextField(
                        value = code,
                        onValueChange = { code = it.filter { c -> c.isDigit() }.take(6) },
                        modifier = Modifier.weight(1f),
                        placeholder = { Text("6 位配对码", color = Theme.textTer) },
                        singleLine = true,
                        textStyle = TextStyle(
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            fontFamily = FontFamily.Monospace,
                        ),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        shape = RoundedCornerShape(12.dp),
                        colors = darkFieldColors(),
                    )
                    val canClaim = !claiming && code.trim().length == 6
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .background(if (canClaim) Theme.blueBtn else Theme.blueBtn.copy(alpha = 0.4f))
                            .clickable(enabled = canClaim) {
                                claiming = true
                                result = null
                                val c = code.trim()
                                scope.launch {
                                    result = try {
                                        AuthAPI.claimPair(c)
                                        code = ""
                                        true to "✓ 配对成功,电脑将自动以你的账号上线"
                                    } catch (e: Throwable) {
                                        false to (e.message ?: "配对失败")
                                    }
                                    claiming = false
                                }
                            }
                            .padding(horizontal = 18.dp, vertical = 14.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (claiming) "配对中…" else "配对",
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
                result?.let { r ->
                    Text(r.second, color = if (r.first) Theme.green else Theme.coral, fontSize = 13.sp)
                }
            }
        }
    }
}

/** 单台电脑行:状态点 + 名称 + 断开 / 重连入口。对位 iOS DevicesView 里的 agent 行。 */
@Composable
private fun AgentRow(relay: RelayClient, agent: AgentInfo) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            Icons.Default.Computer,
            contentDescription = null,
            tint = if (agent.online) Theme.green else Theme.textTer,
            modifier = Modifier.size(18.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(agent.name, color = Theme.text, fontSize = 15.sp)
            Text(
                when {
                    agent.online -> "在线"
                    agent.resuming -> "重连中,等待电脑回应…"
                    agent.suspended -> "已断开(挂起)"
                    else -> "离线"
                },
                color = when {
                    agent.online -> Theme.green
                    agent.resuming -> Theme.blue
                    agent.suspended -> Theme.gold
                    else -> Theme.textTer
                },
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        when {
            agent.online -> Text(
                "断开",
                color = Theme.coral,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { relay.suspendAgent(agent) },
            )
            agent.resuming -> CircularProgressIndicator(
                color = Theme.blue,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
            agent.suspended -> Text(
                "重连",
                color = Theme.blue,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { relay.resumeAgent(agent) },
            )
        }
    }
}

/**
 * 屏 5 —— 设置页:中转服务器(IP+端口 + 连通性测试 + 保存重连 + 手动断开)、账号(退出登录)、
 * 关于(版本 + 检查更新 + 更新提示)。对位 iOS `SettingsView`。
 *
 * @param updater 版本检查器(无 CompositionLocal,由 MainScreen 注入;对位 iOS `@EnvironmentObject updater`)。
 */
@Composable
fun SettingsScreen(updater: UpdateChecker) {
    val appState = LocalAppState.current
    val relay = LocalRelayClient.current
    val scope = rememberCoroutineScope()

    var host by remember { mutableStateOf(ServerConfig.savedHost) }
    var portText by remember { mutableStateOf(ServerConfig.savedPort.toString()) }
    var savedFlash by remember { mutableStateOf(false) }
    var testing by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<Pair<Boolean, String>?>(null) }
    var checkingUpdate by remember { mutableStateOf(false) }

    val port = portText.toIntOrNull() ?: 0
    val inputValid = ServerConfig.sanitizeHost(host).isNotEmpty() && port in 1..65535

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Text("设置", color = Theme.text, fontSize = 24.sp, fontWeight = FontWeight.Bold)

            // 中转服务器:只填 IP + 端口,地址内部拼接
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .cardStyle()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("中转服务器", color = Theme.textSec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SettingField(
                        value = host,
                        onValueChange = { host = it },
                        prompt = "IP / 主机名,如 100.64.0.5",
                        keyboard = KeyboardType.Uri,
                        modifier = Modifier.weight(1f),
                    )
                    SettingField(
                        value = portText,
                        onValueChange = { portText = it.filter { c -> c.isDigit() }.take(5) },
                        prompt = "端口",
                        keyboard = KeyboardType.Number,
                        modifier = Modifier.width(90.dp),
                    )
                }
                ServerConfig.buildURL(host, port)?.let { url ->
                    Text(
                        "实际连接: $url",
                        color = Theme.textTer,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    // 测试连通性
                    Box(
                        modifier = Modifier
                            .cardStyle(fill = Theme.cardHi, stroke = Theme.stroke, radius = 10.dp)
                            .clickable(enabled = inputValid && !testing) {
                                testing = true
                                testResult = null
                                val h = host
                                val p = port
                                scope.launch {
                                    testResult = RelayClient.testServer(h, p)
                                    testing = false
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            if (testing) {
                                CircularProgressIndicator(
                                    color = Theme.text,
                                    strokeWidth = 2.dp,
                                    modifier = Modifier.size(14.dp),
                                )
                            }
                            Text(
                                if (testing) "测试中…" else "测试连通",
                                color = Theme.text,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }

                    // 保存并重连
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (savedFlash) Theme.green else Theme.blueBtn)
                            .clickable(enabled = inputValid) {
                                ServerConfig.savedHost = ServerConfig.sanitizeHost(host)
                                ServerConfig.savedPort = port
                                host = ServerConfig.savedHost
                                relay.reconnectToCurrentServer()
                                savedFlash = true
                                scope.launch {
                                    delay(1_500)
                                    savedFlash = false
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (savedFlash) "✓ 已保存" else "保存并重连",
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }

                    ConnectionBadge(relay.connection)
                }
                testResult?.let { r ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        Icon(
                            if (r.first) Icons.Default.CheckCircle else Icons.Default.Cancel,
                            contentDescription = null,
                            tint = if (r.first) Theme.green else Theme.coral,
                            modifier = Modifier.size(13.dp),
                        )
                        Text(r.second, color = if (r.first) Theme.green else Theme.coral, fontSize = 13.sp)
                    }
                }
                // 手动断开 / 重连
                val connected = relay.connection is ConnectionState.Connected
                Text(
                    if (connected) "断开连接" else "重新连接",
                    color = if (connected) Theme.coral else Theme.blue,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier
                        .padding(top = 2.dp)
                        .clickable {
                            if (connected) relay.manualDisconnect() else relay.reconnectToCurrentServer()
                        },
                )
            }

            // 账号
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .cardStyle()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("账号", color = Theme.textSec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    appState.account,
                    color = Theme.text,
                    fontSize = 15.sp,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    "退出登录",
                    color = Theme.coral,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .clickable { appState.logout() },
                )
            }

            // 关于 / 版本
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .cardStyle()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("关于", color = Theme.textSec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "版本 ${UpdateChecker.currentVersion} (${BuildConfig.VERSION_CODE})",
                        color = Theme.text,
                        fontSize = 15.sp,
                    )
                    Spacer(Modifier.weight(1f))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                        modifier = Modifier.clickable(enabled = !checkingUpdate) {
                            checkingUpdate = true
                            scope.launch {
                                updater.check(manual = true)
                                checkingUpdate = false
                            }
                        },
                    ) {
                        if (checkingUpdate) {
                            CircularProgressIndicator(
                                color = Theme.blue,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(14.dp),
                            )
                        }
                        Text(
                            if (checkingUpdate) "检查中…" else "检查更新",
                            color = Theme.blue,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
                when (val st = updater.status) {
                    is UpdateChecker.Status.UpToDate -> StatusLabel(
                        Icons.Default.CheckCircle,
                        "已是最新版本",
                        Theme.green,
                    )
                    is UpdateChecker.Status.UpdateAvailable -> StatusLabel(
                        Icons.Default.ArrowCircleUp,
                        "发现新版本 ${st.info.latest},点上方「检查更新」查看公告",
                        Theme.gold,
                    )
                    else -> Unit
                }
            }
        }
    }
}

@Composable
private fun SettingField(
    value: String,
    onValueChange: (String) -> Unit,
    prompt: String,
    keyboard: KeyboardType,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        placeholder = { Text(prompt, color = Theme.textTer) },
        singleLine = true,
        textStyle = TextStyle(fontSize = 15.sp, fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        shape = RoundedCornerShape(12.dp),
        colors = darkFieldColors(),
    )
}

@Composable
private fun ConnectionBadge(connection: ConnectionState) {
    val color = when (connection) {
        is ConnectionState.Connected -> Theme.green
        is ConnectionState.Connecting, is ConnectionState.Reconnecting -> Theme.gold
        else -> Theme.coral
    }
    val text = when (connection) {
        is ConnectionState.Connected -> "已连接"
        is ConnectionState.Connecting -> "连接中…"
        is ConnectionState.Reconnecting -> "重连中…"
        is ConnectionState.Failed -> "连接失败"
        is ConnectionState.Disconnected -> "未连接"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            Modifier
                .size(7.dp)
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(color),
        )
        Text(text, color = Theme.textSec, fontSize = 13.sp)
    }
}

@Composable
private fun StatusLabel(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, color: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        Text(text, color = color, fontSize = 13.sp)
    }
}
