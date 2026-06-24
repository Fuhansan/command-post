package com.aicodingremote.app.rendering.renderers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.models.Component

/**
 * PROTOCOL 原则 2 / §10 —— 未知组件类型的兜底渲染。绝不崩溃。
 *
 * 与 iOS 端语义一致:这里只在「连兜底文本都没有」时出现;
 * 消息级 `fallbackText` 在 `TaskDetailScreen` 的 MessageRow 上层处理。
 */
@Composable
fun UnknownRenderer(component: Component) {
    val shape = RoundedCornerShape(10.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Theme.cardHi, shape)
            .border(1.dp, Theme.stroke, shape)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            Icons.Default.QuestionMark,
            contentDescription = null,
            tint = Theme.textTer,
            modifier = Modifier.size(14.dp),
        )
        Text(
            "不支持的组件「${component.type}」,请更新 App",
            color = Theme.textTer,
            fontSize = 13.sp,
        )
    }
}
