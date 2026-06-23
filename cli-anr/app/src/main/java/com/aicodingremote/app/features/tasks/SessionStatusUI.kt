package com.aicodingremote.app.features.tasks

import androidx.compose.ui.graphics.Color
import com.aicodingremote.app.designsystem.Theme

/**
 * 会话状态字符串(来自协议 `body.session.status`)→ 展示标签 / 颜色。
 * 对位 iOS `SessionStatusUI`。
 */
object SessionStatusUI {
    fun label(s: String): String = when (s) {
        "idle" -> "空闲"
        "working" -> "运行中"
        "waiting" -> "等待确认"     // 真有审批/选择待你处理(needsAction)
        "suspended" -> "会话挂起"   // 空闲等你输入,无待办 —— 不催你
        "done" -> "完成"
        "ended" -> "已结束"
        else -> s
    }

    fun color(s: String): Color = when (s) {
        "working" -> Theme.blue
        "waiting" -> Theme.gold      // 黄:需要你处理
        "suspended" -> Theme.textSec // 灰:仅挂起,不需处理
        "done" -> Theme.green
        "ended" -> Theme.textTer
        else -> Theme.textSec
    }
}
