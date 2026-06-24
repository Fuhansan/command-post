package com.aicodingremote.app.rendering.renderers

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material3.Icon
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.models.Component
import com.aicodingremote.app.models.arrayValue
import com.aicodingremote.app.models.bool
import com.aicodingremote.app.models.double
import com.aicodingremote.app.models.doubleValue
import com.aicodingremote.app.models.get
import com.aicodingremote.app.models.string
import com.aicodingremote.app.models.stringValue

/** PROTOCOL §5.2 —— 普通文本 / markdown 文本。 */
@Composable
fun TextRenderer(component: Component) {
    val p = component.props
    val text = p.string("text")
    val isMarkdown = p.bool("markdown")
    if (isMarkdown) {
        MarkdownText(text)
    } else {
        val style = p.string("style", "body")
        val mono = p.bool("mono")
        val bold = p.bool("bold")
        val size = when (style) {
            "heading" -> 17.sp
            "caption" -> 13.sp
            else -> 15.sp
        }
        val weight = if (bold || style == "heading") FontWeight.SemiBold else FontWeight.Normal
        val fg: Color = p["color"]?.stringValue?.let { Theme.named(it, default = Theme.text) }
            ?: if (style == "caption") Theme.textSec else Theme.text
        val fill = p.bool("fill", default = true)
        Text(
            text = text,
            color = fg,
            fontSize = size,
            fontWeight = weight,
            fontFamily = if (mono) FontFamily.Monospace else null,
            modifier = if (fill) Modifier.fillMaxWidth() else Modifier,
        )
    }
}

/** PROTOCOL §5.2 —— 会话气泡。user → 右侧蓝气泡;agent → 左侧悬浮卡。 */
@Composable
fun BubbleRenderer(component: Component) {
    val p = component.props
    val text = p.string("text")
    val isMarkdown = p.bool("markdown")
    val isUser = p.string("role", "agent") == "user"

    if (isUser) {
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(Theme.blueBtn.copy(alpha = 0.22f))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            if (isMarkdown) MarkdownText(text)
            else Text(text, color = Theme.text, fontSize = 15.sp)
        }
    } else {
        val shape = RoundedCornerShape(Theme.rCard)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(Theme.card, shape)
                .border(1.dp, Theme.stroke, shape)
                .padding(14.dp),
        ) {
            if (isMarkdown) MarkdownText(text)
            else Text(text, color = Theme.text, fontSize = 15.sp)
        }
    }
}

/** PROTOCOL §5.2 —— 代码块(标题栏 + 复制按钮 + 横向滚动单色代码)。 */
@Composable
fun CodeRenderer(component: Component) {
    val code = component.props.string("code")
    val language = component.props["language"]?.stringValue
    val copyable = component.props.bool("copyable", default = true)
    val shape = RoundedCornerShape(10.dp)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Theme.field, shape)
            .border(1.dp, Theme.stroke, shape)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (language != null || copyable) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (language != null) {
                    Text(language, color = Theme.textTer, fontSize = 11.sp)
                }
                Spacer(Modifier.weight(1f))
                if (copyable) {
                    CopyButton(text = code, label = "复制")
                }
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            Text(
                text = code,
                color = Theme.text,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
            )
        }
    }
}

/** PROTOCOL §5.2 —— 状态徽章(自由色名)。 */
@Composable
fun BadgeRenderer(component: Component) {
    val text = component.props.string("text")
    val color = Theme.named(component.props["color"]?.stringValue, default = Theme.textSec)
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.16f))
            .padding(horizontal = 9.dp, vertical = 4.dp),
    ) {
        Text(text, color = color, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

/** PROTOCOL §5.2 —— 键值对表格(左 secondary,右 primary)。 */
@Composable
fun KeyValueRenderer(component: Component) {
    val items = component.props["items"]?.arrayValue ?: emptyList()
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items.forEach { item ->
            Row(verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth()) {
                Text(item.string("k"), color = Theme.textSec, fontSize = 13.sp)
                Spacer(Modifier.weight(1f))
                Text(
                    item.string("v"),
                    color = Theme.text,
                    fontSize = 13.sp,
                    textAlign = TextAlign.End,
                )
            }
        }
    }
}

/**
 * PROTOCOL §5.2 —— 进度条。
 * - 有 `value`(0..1) → 线性进度条;
 * - 无 `value` → 圆形 spinner(对位 iOS 无限转圈)。
 */
@Composable
fun ProgressRenderer(component: Component) {
    val label = component.props["label"]?.stringValue
    val value = component.props.double("value") ?: component.props["value"]?.doubleValue
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (label != null) Text(label, color = Theme.textSec, fontSize = 13.sp)
        if (value != null) {
            LinearProgressIndicator(
                progress = { value.toFloat().coerceIn(0f, 1f) },
                color = Theme.blue,
                trackColor = Theme.cardHi,
                modifier = Modifier.fillMaxWidth().height(6.dp),
            )
        } else {
            // 无限转圈(不知道何时结束):对位 iOS 默认 ProgressView() 的小转圈。
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(
                    color = Theme.blue,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

/**
 * PROTOCOL §5.2 —— 图片。三链路兼容(对位 iOS):
 * - `{id}`:控制通道只给 id,按 id 经 HTTP 拉(新链路,主流);
 * - `{data}`:内联 base64(旧链路);
 * - `{url}` / `{thumbUrl}`:外链(更旧)。
 */
@Composable
fun ImageRenderer(component: Component) {
    val p = component.props
    val shape = RoundedCornerShape(16.dp)
    val frame = Modifier
        .sizeIn(maxWidth = 240.dp, maxHeight = 300.dp)
        .shadow(6.dp, shape)
        .clip(shape)
        .border(0.5.dp, Theme.stroke.copy(alpha = 0.5f), shape)

    val id = p["id"]?.stringValue
    val dataStr = p["data"]?.stringValue
    val url = p["url"]?.stringValue ?: p["thumbUrl"]?.stringValue
    val alt = p["alt"]?.stringValue

    when {
        !id.isNullOrEmpty() -> {
            // 新链路:按 id 拉 — 复用 ChatRenderers 里的 IdAsyncImage(走相同的 LruCache)
            IdAsyncImage(id = id, maxW = 240.dp, maxH = 300.dp, contentDescription = alt)
        }
        dataStr != null -> {
            val bitmap = remember(dataStr) {
                runCatching {
                    val bytes = Base64.decode(dataStr, Base64.DEFAULT)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }.getOrNull()
            }
            if (bitmap != null) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = alt,
                    modifier = frame,
                    contentScale = ContentScale.Fit,
                    filterQuality = FilterQuality.Medium,
                )
            } else {
                ImagePlaceholder()
            }
        }
        url != null -> {
            AsyncImage(
                model = url,
                contentDescription = alt,
                modifier = frame,
                contentScale = ContentScale.Fit,
            )
        }
        else -> ImagePlaceholder()
    }
}

@Composable
private fun ImagePlaceholder() {
    Box(
        modifier = Modifier
            .size(width = 120.dp, height = 90.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Theme.cardHi),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Default.Photo, null, tint = Theme.textTer, modifier = Modifier.size(28.dp))
    }
}

/** PROTOCOL §5.2 —— 文件 diff(filename + hunks)。 */
@Composable
fun DiffRenderer(component: Component) {
    val filename = component.props["filename"]?.stringValue
    val hunks = component.props["hunks"]?.arrayValue ?: emptyList()
    val shape = RoundedCornerShape(10.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Theme.field, shape)
            .border(1.dp, Theme.stroke, shape)
            .padding(10.dp),
    ) {
        if (filename != null) {
            Text(
                filename,
                color = Theme.textSec,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 6.dp),
            )
        }
        hunks.forEach { hunk ->
            val op = hunk.string("op", "ctx")
            val text = hunk.string("text")
            val (sign, fg, bg) = when (op) {
                "add" -> Triple("+ ", Theme.green, Theme.green.copy(alpha = 0.14f))
                "del" -> Triple("- ", Theme.coral, Theme.coral.copy(alpha = 0.14f))
                else -> Triple("  ", Theme.textSec, Color.Transparent)
            }
            Text(
                sign + text,
                color = fg,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(bg)
                    .padding(horizontal = 4.dp),
            )
        }
    }
}
