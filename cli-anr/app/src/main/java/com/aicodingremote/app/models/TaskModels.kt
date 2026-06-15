package com.aicodingremote.app.models

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.QuestionAnswer
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.aicodingremote.app.designsystem.Theme

/**
 * 任务状态(对应设计图的徽章与状态色)。
 * 与 iOS `TaskStatus` 一一对应。
 */
enum class TaskStatus(
    val label: String,
    val color: Color,
    val icon: ImageVector,
) {
    WaitingApproval("等待审批", Theme.coral, Icons.Default.HourglassEmpty),
    WaitingInput("等待输入", Theme.gold, Icons.Default.QuestionAnswer),
    Running("运行中", Theme.blue, Icons.Default.PlayCircle),
    Completed("已完成", Theme.green, Icons.Default.CheckCircle),
    Failed("执行失败", Theme.coral, Icons.Default.Warning),
}

/** 操作按钮风格(对位 iOS `ActionStyle`)。 */
enum class ActionStyle(val bg: Color, val fg: Color) {
    Coral(Theme.coral, Color.White),
    Gold(Theme.gold, Color(0xD9000000)), // 0.85 alpha black
    Blue(Theme.blueBtn, Color.White),
}

/** 通知大类(对位 iOS `NotiKind`)。 */
enum class NotiKind(val icon: ImageVector, val color: Color) {
    Completed(Icons.Default.CheckCircle, Theme.green),
    WaitingInput(Icons.AutoMirrored.Filled.Chat, Theme.gold),
    Failed(Icons.Default.Error, Theme.coral),
}

data class AppNotification(
    val id: String,
    val kind: NotiKind,
    val title: String,
    val subtitle: String,
    val time: String,
    val unread: Boolean,
)
