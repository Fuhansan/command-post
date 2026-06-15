package com.aicodingremote.app.features.notifications

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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.app.LocalRelayClient
import com.aicodingremote.app.designsystem.Avatar
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.models.ComponentAction
import com.aicodingremote.app.networking.RelayClient
import com.aicodingremote.app.networking.RelaySession
import kotlinx.serialization.json.JsonPrimitive

/**
 * 屏 3 —— 通知 / 跨会话待办中心。
 * 「待审批」聚合所有会话的命令审批,可逐个或一键批量允许 / 拒绝;
 * 「待选择」(选择题 / 计划确认)必须逐个作答,点击跳进对应会话。
 * 对位 iOS `NotificationsView`。
 *
 * @param onOpen 跳进某会话详情(由 MainScreen 注入导航;对位 iOS `NavigationLink(value:)`)。
 */
@Composable
fun NotificationsScreen(onOpen: (String) -> Unit) {
    val relay = LocalRelayClient.current
    val permSessions = relay.sessions.filter { it.pendingKind == "perm" }
    val questionSessions = relay.sessions.filter { it.pendingKind == "question" }

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
            Header(relay.pendingCount)
            if (permSessions.isEmpty() && questionSessions.isEmpty()) {
                EmptyState()
            } else {
                if (permSessions.isNotEmpty()) PermSection(relay, permSessions, onOpen)
                if (questionSessions.isNotEmpty()) QuestionSection(questionSessions, onOpen)
            }
        }
    }
}

@Composable
private fun Header(pendingCount: Int) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("通知", color = Theme.text, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        if (pendingCount > 0) {
            Text(
                "$pendingCount 项待处理",
                color = Theme.gold,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

// MARK: - 待审批(可批量)

@Composable
private fun PermSection(
    relay: RelayClient,
    permSessions: List<RelaySession>,
    onOpen: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("待审批", color = Theme.textSec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            if (permSessions.size > 1) {
                Text(
                    "全部拒绝",
                    color = Theme.textSec,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable { permSessions.forEach { deny(relay, it) } },
                )
                Spacer(Modifier.width(12.dp))
                Text(
                    "全部允许",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Theme.coral)
                        .clickable { permSessions.forEach { allow(relay, it) } }
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }
        permSessions.forEach { s ->
            PermCard(relay, s, onOpen)
        }
    }
}

@Composable
private fun PermCard(relay: RelayClient, s: RelaySession, onOpen: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle(stroke = Theme.coral.copy(alpha = 0.5f))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onOpen(s.id) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Avatar(letter = s.title.firstOrNull()?.toString() ?: "?", color = Theme.purple)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(s.title, color = Theme.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text("请求执行命令", color = Theme.gold, fontSize = 12.sp)
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Theme.textTer,
                modifier = Modifier.size(12.dp),
            )
        }
        if (s.pendingDetail.isNotEmpty()) {
            Text(
                s.pendingDetail,
                color = Theme.textSec,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 3,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(Theme.field)
                    .padding(8.dp),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .cardStyle(fill = Theme.cardHi, stroke = Theme.stroke, radius = 10.dp)
                    .clickable { deny(relay, s) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("拒绝", color = Theme.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Theme.coral)
                    .clickable { allow(relay, s) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("允许", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

// MARK: - 待选择(逐个作答,跳进会话)

@Composable
private fun QuestionSection(
    questionSessions: List<RelaySession>,
    onOpen: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            "待选择(需逐个作答)",
            color = Theme.textSec,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
        )
        questionSessions.forEach { s ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .cardStyle(stroke = Theme.gold.copy(alpha = 0.5f))
                    .clickable { onOpen(s.id) }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Avatar(letter = s.title.firstOrNull()?.toString() ?: "?", color = Theme.purple)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(s.title, color = Theme.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        s.pendingDetail.ifEmpty { "等待你选择" },
                        color = Theme.textSec,
                        fontSize = 13.sp,
                        maxLines = 2,
                    )
                }
                Text(
                    "去作答",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Theme.blueBtn)
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun EmptyState() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 60.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            Icons.Default.NotificationsOff,
            contentDescription = null,
            tint = Theme.textTer,
            modifier = Modifier.size(40.dp),
        )
        Text("暂无待处理事项", color = Theme.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "所有会话的审批请求与选择题会聚合在这里",
            color = Theme.textSec,
            fontSize = 13.sp,
        )
    }
}

private fun allow(relay: RelayClient, s: RelaySession) {
    relay.sendAction(
        ComponentAction(id = "perm_allow", value = JsonPrimitive(s.id)),
        messageId = "sess:${s.id}",
        sessionId = s.id,
    )
}

private fun deny(relay: RelayClient, s: RelaySession) {
    relay.sendAction(
        ComponentAction(id = "perm_deny", value = JsonPrimitive(s.id)),
        messageId = "sess:${s.id}",
        sessionId = s.id,
    )
}
