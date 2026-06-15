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
        "waiting" -> "等待确认"
        "done" -> "完成"
        "ended" -> "已结束"
        else -> s
    }

    fun color(s: String): Color = when (s) {
        "working" -> Theme.blue
        "waiting" -> Theme.gold
        "done" -> Theme.green
        "ended" -> Theme.textTer
        else -> Theme.textSec
    }
}
