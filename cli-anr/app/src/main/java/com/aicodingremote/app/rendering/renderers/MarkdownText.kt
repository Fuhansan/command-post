package com.aicodingremote.app.rendering.renderers

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.designsystem.Theme
import com.halilibo.richtext.commonmark.Markdown
import com.halilibo.richtext.ui.material3.RichText

/**
 * Markdown 文本渲染(对位 iOS `MarkdownText`,基于 swift-markdown-ui)。
 *
 * 用 `compose-richtext` 提供 GFM 全支持:
 * - 段落 / 行内强调 / 行内代码 / 链接
 * - 代码块
 * - 引用
 * - 表格
 * - 任务列表 / 嵌套列表
 * - 标题分级
 * - 分隔线
 *
 * Material3 主题色板已经在 `RemoteCodingTheme` 里配过(深色),
 * RichText material3 包会从那里继承文字/链接颜色,无需在这里逐个 hook。
 * 后续要进一步对齐 iOS 的字号/段距(em-based heading 等),
 * 在这里加 RichTextStyle 参数即可。
 */
@Composable
fun MarkdownText(text: String) {
    CompositionLocalProvider(LocalContentColor provides Theme.text) {
        RichText(modifier = Modifier.fillMaxWidth()) {
            Markdown(content = text)
        }
    }
}
