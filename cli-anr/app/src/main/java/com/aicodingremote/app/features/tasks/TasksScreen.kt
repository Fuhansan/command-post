package com.aicodingremote.app.features.tasks

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.app.LocalRelayClient
import com.aicodingremote.app.designsystem.Avatar
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.designsystem.darkFieldColors
import com.aicodingremote.app.models.ProjectInfo
import com.aicodingremote.app.networking.ConnectionState
import com.aicodingremote.app.networking.RelayClient
import com.aicodingremote.app.networking.RelaySession
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 屏 1 —— 任务列表(首页)。统一列表:项目卡(可下钻)+ 单任务卡(手动会话)。
 * 对位 iOS `TasksView`。
 *
 * @param onOpenSession 点单任务卡进会话详情
 * @param onOpenProject 点项目卡进 ProjectSessions
 */
@Composable
fun TasksScreen(onOpenSession: (String) -> Unit, onOpenProject: (String) -> Unit) {
    val relay = LocalRelayClient.current
    val connection = relay.connection
    val agentOnline = relay.agents.any { it.online }
    val scope = rememberCoroutineScope()
    var showLaunch by remember { mutableStateOf(false) }
    var launchCmd by remember { mutableStateOf("claude") }
    var launched by remember { mutableStateOf(false) }

    // 单任务 = 手动敲的 claude 且 cwd 不属于任何已打开项目(含子目录)。
    // 属于项目的折叠进项目,不重复。
    val singleTasks = remember(relay.sessions.toList(), relay.projects.toList()) {
        relay.sessions.filter { s -> s.isManual && relay.project(forCwd = s.cwd) == null }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg),
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            contentPadding = PaddingValues(vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Header(
                    connection = connection,
                    agentOnline = agentOnline,
                    onLaunch = {
                        launchCmd = "claude"
                        launched = false
                        showLaunch = true
                    },
                )
            }
            if (relay.projects.isEmpty() && singleTasks.isEmpty()) {
                item { EmptyState() }
            } else {
                items(relay.projects, key = { "p:${it.workdir}" }) { proj ->
                    val inProject = relay.sessions.filter {
                        relay.project(forCwd = it.cwd)?.workdir == proj.workdir
                    }
                    ProjectRow(
                        project = proj,
                        sessions = inProject,
                        onClick = { onOpenProject(proj.workdir) },
                    )
                }
                items(singleTasks, key = { "s:${it.id}" }) { s ->
                    SessionCard(s, onClick = { onOpenSession(s.id) })
                }
            }
        }
        if (showLaunch) {
            LaunchCommandSheet(
                command = launchCmd,
                launched = launched,
                onCommandChange = { launchCmd = it },
                onRun = {
                    val cmd = launchCmd.trim()
                    if (cmd.isNotEmpty() && !launched) {
                        relay.launchCommand(cmd)
                        launched = true
                        scope.launch {
                            delay(900)
                            showLaunch = false
                        }
                    }
                },
                onDismiss = { showLaunch = false },
            )
        }
    }
}

@Composable
private fun Header(connection: ConnectionState, agentOnline: Boolean, onLaunch: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Brush.linearGradient(listOf(Theme.blueBtn, Theme.blue))),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("AI Coding Remote", color = Theme.text, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(6.dp).clip(CircleShape).background(statusColor(connection)),
                )
                Spacer(Modifier.width(5.dp))
                Text(statusText(connection, agentOnline), color = Theme.textSec, fontSize = 13.sp)
            }
        }
        Box(
            modifier = Modifier
                .size(38.dp)
                .clip(CircleShape)
                .background(if (agentOnline) Theme.blueBtn else Theme.cardHi)
                .clickable(enabled = agentOnline, onClick = onLaunch),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.Add,
                contentDescription = "新建会话",
                tint = if (agentOnline) Color.White else Theme.textTer,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun LaunchCommandSheet(
    command: String,
    launched: Boolean,
    onCommandChange: (String) -> Unit,
    onRun: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val canRun = command.trim().isNotEmpty() && !launched
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = Theme.bg) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("在电脑上新建会话", color = Theme.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Text(
                "电脑会打开一个终端窗口运行下面的命令。想进某个项目就带上 cd,例如:\ncd ~/proj && claude",
                color = Theme.textSec,
                fontSize = 13.sp,
            )
            OutlinedTextField(
                value = command,
                onValueChange = onCommandChange,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("要运行的命令") },
                minLines = 1,
                maxLines = 4,
                textStyle = TextStyle(color = Theme.text, fontSize = 15.sp, fontFamily = FontFamily.Monospace),
                colors = darkFieldColors(),
            )
            Button(
                onClick = onRun,
                enabled = canRun,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (launched) Theme.green else Theme.blueBtn,
                    contentColor = Color.White,
                    disabledContainerColor = if (launched) Theme.green else Theme.cardHi,
                    disabledContentColor = if (launched) Color.White else Theme.textTer,
                ),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(
                        if (launched) Icons.Default.CheckCircle else Icons.Default.PlayArrow,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(
                        if (launched) "已发送,等终端启动…" else "在电脑上运行",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

private fun statusColor(c: ConnectionState): Color = when (c) {
    is ConnectionState.Connected -> Theme.green
    is ConnectionState.Connecting, is ConnectionState.Reconnecting -> Theme.gold
    else -> Theme.textTer
}

private fun statusText(c: ConnectionState, agentOnline: Boolean): String = when (c) {
    is ConnectionState.Connected -> if (agentOnline) "已连接 · 电脑在线" else "已连接中转 · 等待电脑"
    is ConnectionState.Connecting -> "连接中…"
    is ConnectionState.Reconnecting -> "重连中…"
    is ConnectionState.Failed -> "连接失败"
    is ConnectionState.Disconnected -> "未连接"
}

@Composable
private fun EmptyState() {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Default.Terminal, null, tint = Theme.textTer, modifier = Modifier.size(40.dp))
        Text("还没有项目或会话", color = Theme.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "在电脑 VibeNotch「打开项目」,或在终端运行 Claude Code,就会出现在这里",
            color = Theme.textSec,
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
        )
    }
}

/** 把 Mac 绝对路径里的 /Users/<name>/ 缩成 ~/。对位 iOS `shortMacPath`。 */
fun shortMacPath(p: String): String =
    p.replace(Regex("""^/Users/[^/]+/"""), "~/")

/**
 * 首页「项目」一行:项目名 + 目录 + 会话数 / 历史数。对位 iOS `ProjectRow`。
 */
@Composable
internal fun ProjectRow(project: ProjectInfo, sessions: List<RelaySession>, onClick: () -> Unit) {
    val needsAction = sessions.any { it.needsAction }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle(stroke = if (needsAction) Theme.coral.copy(alpha = 0.7f) else Theme.stroke)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Brush.linearGradient(listOf(Theme.blueBtn, Theme.blue))),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Folder, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(project.name, color = Theme.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    shortMacPath(project.workdir),
                    color = Theme.textSec,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (needsAction) {
                Pill(text = "需处理", bg = Theme.coral, fg = Color.White)
                Spacer(Modifier.width(6.dp))
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Theme.textTer,
                modifier = Modifier.size(13.dp),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("${sessions.size} 进行中", color = Theme.textSec, fontSize = 12.sp)
            if (project.history.isNotEmpty()) {
                Text("·", color = Theme.textTer, fontSize = 12.sp)
                Text("${project.history.size} 条历史", color = Theme.textTer, fontSize = 12.sp)
            }
        }
    }
}

/** 任务行(一个 claude 会话):项目名 + 终端 + 目录。对位 iOS `SessionCard`。 */
@Composable
internal fun SessionCard(s: RelaySession, onClick: () -> Unit) {
    val hasTerminal = s.terminal.isNotEmpty() && s.terminal != "?"
    val hasCwd = s.cwd.isNotEmpty() && s.cwd != "?"
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle(stroke = if (s.needsAction) Theme.coral.copy(alpha = 0.7f) else Theme.stroke)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Avatar(letter = s.title.firstOrNull()?.toString() ?: "?", color = Theme.purple)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(s.title, color = Theme.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (hasTerminal) {
                        Text(s.terminal, color = Theme.textSec, fontSize = 12.sp)
                        Text("·", color = Theme.textTer, fontSize = 12.sp)
                    }
                    Text(
                        SessionStatusUI.label(s.status),
                        color = SessionStatusUI.color(s.status),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    if (s.agentSessionId.isNotEmpty()) {
                        Text("·", color = Theme.textTer, fontSize = 12.sp)
                        Text(
                            "id ${s.agentSessionId.take(8)}",
                            color = Theme.textTer,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }
            if (s.needsAction) {
                Pill(text = "需处理", bg = Theme.coral, fg = Color.White)
            }
        }
        if (s.isManual) {
            // 手动会话:用户自己敲的 claude,反控走 GUI 模拟,电脑锁屏后无法操作。
            Row(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Theme.gold.copy(alpha = 0.15f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(Icons.Default.PanTool, contentDescription = null, tint = Theme.gold, modifier = Modifier.size(10.dp))
                Text("手动 · 锁屏不可控", color = Theme.gold, fontSize = 11.sp, fontWeight = FontWeight.Medium)
            }
        }
        if (hasCwd) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Icon(Icons.Default.Folder, contentDescription = null, tint = Theme.textTer, modifier = Modifier.size(11.dp))
                Text(
                    shortMacPath(s.cwd),
                    color = Theme.textSec,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (s.subtitle.isNotEmpty()) {
            Text(s.subtitle, color = Theme.textSec, fontSize = 14.sp, maxLines = 2)
        }
    }
}

@Composable
internal fun Pill(text: String, bg: Color, fg: Color) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(bg)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Text(text, color = fg, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}
