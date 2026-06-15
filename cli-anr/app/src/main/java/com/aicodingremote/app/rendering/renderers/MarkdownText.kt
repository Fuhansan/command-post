package com.aicodingremote.app.rendering.renderers

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.designsystem.Theme

/**
 * 轻量 markdown 渲染器(粗体 / 行内代码 / 标题 / 无序列表 / 链接形态保留)。
 *
 * 不是完整 GFM —— 复杂代码块走 `code` 组件,引用 / 表格暂留 TODO(对应 iOS 端 MarkdownUI 的能力差距)。
 * 这层只保证 agent 喂 `markdown:true` 的常见富文本不至于退化成纯字符串。
 */
@Composable
fun MarkdownText(text: String) {
    val annotated = remember(text) { parseMarkdown(text) }
    Text(
        text = annotated,
        color = Theme.text,
        fontSize = 15.sp,
        lineHeight = 22.sp,
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun parseMarkdown(input: String): AnnotatedString = buildAnnotatedString {
    val lines = input.split("\n")
    lines.forEachIndexed { idx, raw ->
        when {
            raw.startsWith("### ") -> withStyle(SpanStyle(fontSize = 14.sp, fontWeight = FontWeight.Bold)) {
                appendInline(raw.removePrefix("### "))
            }
            raw.startsWith("## ") -> withStyle(SpanStyle(fontSize = 15.sp, fontWeight = FontWeight.Bold)) {
                appendInline(raw.removePrefix("## "))
            }
            raw.startsWith("# ") -> withStyle(SpanStyle(fontSize = 17.sp, fontWeight = FontWeight.Bold)) {
                appendInline(raw.removePrefix("# "))
            }
            raw.startsWith("> ") -> withStyle(SpanStyle(color = Theme.textSec, fontStyle = FontStyle.Italic)) {
                append("│ ")
                appendInline(raw.removePrefix("> "))
            }
            raw.startsWith("- ") || raw.startsWith("* ") -> {
                append("• ")
                appendInline(raw.drop(2))
            }
            else -> appendInline(raw)
        }
        if (idx < lines.lastIndex) append("\n")
    }
}

/** 解析行内强调:`**bold**` / `__bold__` / `*italic*` / `_italic_` / `` `code` `` 。 */
private fun AnnotatedString.Builder.appendInline(line: String) {
    var i = 0
    while (i < line.length) {
        val c = line[i]
        when {
            line.startsWith("**", i) || line.startsWith("__", i) -> {
                val token = line.substring(i, i + 2)
                val end = line.indexOf(token, i + 2)
                if (end > i + 1) {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                        appendInline(line.substring(i + 2, end))
                    }
                    i = end + 2
                    continue
                }
            }
            c == '`' -> {
                val end = line.indexOf('`', i + 1)
                if (end > i) {
                    withStyle(
                        SpanStyle(
                            fontFamily = FontFamily.Monospace,
                            background = Theme.cardHi,
                            color = Theme.text,
                        ),
                    ) {
                        append(line.substring(i + 1, end))
                    }
                    i = end + 1
                    continue
                }
            }
            (c == '*' || c == '_') && i + 1 < line.length && line[i + 1] != c -> {
                val end = line.indexOf(c, i + 1)
                if (end > i) {
                    withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                        append(line.substring(i + 1, end))
                    }
                    i = end + 1
                    continue
                }
            }
        }
        append(c)
        i++
    }
}
