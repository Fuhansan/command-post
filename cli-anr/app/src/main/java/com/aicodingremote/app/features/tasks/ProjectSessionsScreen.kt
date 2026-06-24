package com.aicodingremote.app.features.tasks

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.app.LocalRelayClient
import com.aicodingremote.app.designsystem.Avatar
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.models.ProjectHistory

/**
 * 屏:项目内会话列表。统一卡片:进行中的会话 + 可恢复的历史会话。点卡片即进入(历史先 resume 再进)。
 * 对位 iOS `ProjectSessionsView`。
 */
@Composable
fun ProjectSessionsScreen(
    workdir: String,
    onBack: () -> Unit,
    onOpenSession: (String) -> Unit,
) {
    val relay = LocalRelayClient.current
    val project = remember(relay.projects.toList(), workdir) {
        relay.projects.firstOrNull { it.workdir == workdir }
    }
    val name = project?.name ?: workdir.substringAfterLast('/').ifEmpty { workdir }

    // 进行中的会话(归属本项目:cwd 等于或在 workdir 子目录下,最长前缀匹配)。
    val active = relay.sessions.filter {
        relay.project(forCwd = it.cwd)?.workdir == workdir
    }
    // 可恢复的历史(排除当前已在跑的 claude 会话,避免和「进行中」重复)。
    val dormant = remember(active, project) {
        val liveIds = active.map { it.agentSessionId }.filter { it.isNotEmpty() }.toSet()
        (project?.history ?: emptyList()).filter { it.id !in liveIds }
    }

    // 等新会话出现就程序化进入:开始操作前快照当前 sid 集合,新出现的 sid 即视为我们这次开的。
    var awaitingSids by remember { mutableStateOf<Set<String>?>(null) }

    // 监听 active 集合变化,有新 sid 出现且我们在等就跳转。用 snapshotFlow 才能拿到稳定快照。
    LaunchedEffect(workdir) {
        snapshotFlow {
            relay.sessions
                .filter { relay.project(forCwd = it.cwd)?.workdir == workdir }
                .map { it.id }
                .sorted()
        }.collect { _ ->
            val snap = awaitingSids ?: return@collect
            val cur = relay.sessions
                .filter { relay.project(forCwd = it.cwd)?.workdir == workdir }
                .map { it.id }
            val fresh = cur.firstOrNull { it !in snap }
            if (fresh != null) {
                awaitingSids = null
                onOpenSession(fresh)
            }
        }
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
                NavBar(
                    name = name,
                    workdir = workdir,
                    onBack = onBack,
                    onAdd = {
                        awaitingSids = active.map { it.id }.toSet()
                        relay.consoleNewSession(workdir)
                    },
                )
            }
            if (awaitingSids != null) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Default.HourglassEmpty, contentDescription = null, tint = Theme.textSec, modifier = Modifier.size(14.dp))
                        Text("正在打开会话…", color = Theme.textSec, fontSize = 13.sp)
                    }
                }
            }
            if (active.isEmpty() && dormant.isEmpty()) {
                item {
                    Text(
                        "这个项目还没有会话。点右上角「+」开一个全新会话。",
                        color = Theme.textSec,
                        fontSize = 13.sp,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    )
                }
            }
            // 进行中:点开即进对话
            items(active, key = { "a:${it.id}" }) { s ->
                SessionCard(s, onClick = { onOpenSession(s.id) })
            }
            // 历史:点卡片 → resume → 程序化进入
            items(dormant, key = { "h:${it.id}" }) { h ->
                HistoryCard(
                    history = h,
                    onClick = {
                        awaitingSids = active.map { it.id }.toSet()
                        relay.consoleResume(workdir = workdir, historyId = h.id)
                    },
                )
            }
        }
    }
}

@Composable
private fun NavBar(name: String, workdir: String, onBack: () -> Unit, onAdd: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .clip(CircleShape)
                .background(Theme.cardHi)
                .clickable(onClick = onBack),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                contentDescription = "返回",
                tint = Theme.text,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, color = Theme.text, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                shortMacPath(workdir),
                color = Theme.textSec,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(Theme.blueBtn)
                .clickable(onClick = onAdd),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.Add, contentDescription = "新建会话", tint = Color.White, modifier = Modifier.size(18.dp))
        }
    }
}

/**
 * 历史会话卡片:同款框样式,只用一个「可恢复」标签标识类型 + 展示 id。
 * 对位 iOS `HistoryCard`。
 */
@Composable
private fun HistoryCard(history: ProjectHistory, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle(stroke = Theme.stroke)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(letter = history.label.firstOrNull()?.toString() ?: "?", color = Theme.textTer)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                history.label,
                color = Theme.text,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "id ${history.id.take(8)}",
                color = Theme.textTer,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        Box(
            modifier = Modifier
                .clip(CircleShape)
                .background(Theme.gold.copy(alpha = 0.15f))
                .padding(horizontal = 8.dp, vertical = 3.dp),
        ) {
            Text("可恢复", color = Theme.gold, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        }
    }
}
