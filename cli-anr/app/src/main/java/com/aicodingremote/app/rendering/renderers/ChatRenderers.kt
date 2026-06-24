package com.aicodingremote.app.rendering.renderers

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.SaveAlt
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.models.Component
import com.aicodingremote.app.models.arrayValue
import com.aicodingremote.app.models.get
import com.aicodingremote.app.models.intValue
import com.aicodingremote.app.models.objectValue
import com.aicodingremote.app.models.string
import com.aicodingremote.app.models.stringValue
import kotlinx.serialization.json.JsonElement

// MARK: - 语言样式(文件图标 / 渐变色)

object LangStyle {
    fun icon(path: String): ImageVector = when (path.substringAfterLast('.', "").lowercase()) {
        "swift" -> Icons.Default.Code
        "md", "txt" -> Icons.AutoMirrored.Filled.Article
        "json", "yml", "yaml" -> Icons.Default.DataObject
        else -> Icons.Default.Code
    }

    fun colors(path: String): List<Color> = when (path.substringAfterLast('.', "").lowercase()) {
        "swift" -> listOf(Color(0xFFF05138), Color(0xFFFF7043))
        "ts", "tsx" -> listOf(Color(0xFF3178C6), Color(0xFF4F9CD9))
        "js", "jsx", "mjs" -> listOf(Color(0xFFD9B400), Color(0xFFF2D44E))
        "py" -> listOf(Color(0xFF3776AB), Color(0xFF4B8BBE))
        "go" -> listOf(Color(0xFF00ADD8), Color(0xFF4FD1E0))
        "rs" -> listOf(Color(0xFFB7410E), Color(0xFFD2691E))
        "java", "kt" -> listOf(Color(0xFFCC5C2E), Color(0xFFE08252))
        else -> listOf(Color(0xFF6E59C7), Color(0xFF9277E0))
    }
}

/** 一条消息的左侧头像样式(图标 + 渐变色)。 */
data class AvatarStyle(val icon: ImageVector, val colors: List<Color>)

private val DEFAULT_AVATAR = AvatarStyle(
    Icons.Default.AutoAwesome,
    listOf(Color(0xFF7C5CD6), Color(0xFFA886F0)),
)

/** 按消息根组件类型决定左侧头像。 */
fun messageAvatarStyle(root: Component): AvatarStyle = when (root.type) {
    "file" -> {
        val p = root.props.string("path")
        AvatarStyle(LangStyle.icon(p), LangStyle.colors(p))
    }
    "command" -> AvatarStyle(Icons.Default.Terminal, listOf(Color(0xFF16A394), Color(0xFF37C9B5)))
    "image" -> AvatarStyle(Icons.Default.Photo, listOf(Color(0xFF4A4F5A), Color(0xFF6B7280)))
    "card" -> if (root.props.string("style") == "danger") {
        AvatarStyle(Icons.Default.Error, listOf(Color(0xFFEE4F2E), Color(0xFFFF7A5C)))
    } else DEFAULT_AVATAR
    else -> DEFAULT_AVATAR // AI 文本 / stack
}

/** 消息左侧头像:圆角渐变方块 + 图标。 */
@Composable
fun MessageAvatar(style: AvatarStyle) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Brush.linearGradient(style.colors)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            style.icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(15.dp),
        )
    }
}

// MARK: - file 卡(可折叠 diff)

@Composable
fun FileRenderer(component: Component) {
    val p = component.props
    val path = p.string("path")
    val name = path.substringAfterLast('/')
    val dir = if ('/' in path) path.substringBeforeLast('/') else ""
    val adds = p["additions"]?.intValue ?: 0
    val hunks = p["hunks"]?.arrayValue ?: emptyList()
    var expanded by rememberSaveable(component.uid) { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle()
            .padding(14.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = hunks.isNotEmpty()) { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(name, color = Theme.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (dir.isNotEmpty()) {
                    Text(
                        shortenPath(dir),
                        color = Theme.textSec,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (adds > 0) {
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Theme.green.copy(alpha = 0.16f))
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                ) {
                    Text("+$adds", color = Theme.green, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                }
            }
            if (hunks.isNotEmpty()) {
                Icon(
                    if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                    contentDescription = if (expanded) "折叠" else "展开",
                    tint = Theme.textSec,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        AnimatedVisibility(
            visible = expanded && hunks.isNotEmpty(),
            enter = expandVertically() + fadeIn(),
            exit = shrinkVertically() + fadeOut(),
        ) {
            Column {
                Spacer(Modifier.height(12.dp))
                DiffLinesView(hunks)
            }
        }
    }
}

private fun shortenPath(dir: String): String {
    val home = System.getProperty("user.home").orEmpty()
    var s = dir
    if (home.isNotEmpty() && s.startsWith(home)) s = "~" + s.drop(home.length)
    val parts = s.split('/').filter { it.isNotEmpty() }
    return if (parts.size > 3) "…/" + parts.takeLast(3).joinToString("/") + "/"
    else "$s/"
}

/** 带行号 + 红删绿增背景的 diff(对齐 cli-ios `DiffLinesView`)。 */
@Composable
fun DiffLinesView(hunks: List<JsonElement>) {
    val lines = remember(hunks) { buildDiffLines(hunks) }
    val shape = RoundedCornerShape(8.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .border(1.dp, Theme.stroke, shape),
    ) {
        Text(
            "@@ 改动 @@",
            color = Theme.textTer,
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
            modifier = Modifier
                .fillMaxWidth()
                .background(Theme.cardHi)
                .padding(horizontal = 10.dp, vertical = 5.dp),
        )
        lines.forEach { ln ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(ln.bg)
                    .padding(vertical = 2.dp, horizontal = 8.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    ln.num,
                    color = ln.numColor,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    textAlign = TextAlign.End,
                    modifier = Modifier.width(30.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    ln.sign,
                    color = ln.fg,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.width(12.dp),
                )
                Text(
                    ln.text,
                    color = ln.fg,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

private data class DLine(
    val num: String,
    val sign: String,
    val text: String,
    val fg: Color,
    val bg: Color,
    val numColor: Color,
)

private fun buildDiffLines(hunks: List<JsonElement>): List<DLine> {
    var oldN = 1
    var newN = 1
    return hunks.map { h ->
        val op = h.string("op", "ctx")
        val text = h.string("text")
        when (op) {
            "add" -> DLine(
                num = newN.toString(),
                sign = "+",
                text = text,
                fg = Theme.green,
                bg = Theme.green.copy(alpha = 0.12f),
                numColor = Theme.green.copy(alpha = 0.8f),
            ).also { newN += 1 }
            "del" -> DLine(
                num = oldN.toString(),
                sign = "-",
                text = text,
                fg = Theme.coral,
                bg = Theme.coral.copy(alpha = 0.12f),
                numColor = Theme.coral.copy(alpha = 0.8f),
            ).also { oldN += 1 }
            else -> DLine(
                num = newN.toString(),
                sign = " ",
                text = text,
                fg = Theme.textSec,
                bg = Color.Transparent,
                numColor = Theme.textTer,
            ).also { oldN += 1; newN += 1 }
        }
    }
}

// MARK: - 图文消息(用户粘贴图 + 文字 → 一个统一气泡:图在上、文字在下)

/**
 * PROTOCOL §5 —— `photomsg`:用户粘贴的图片 + 可选文字合并为一个紫框气泡。
 * 顶部文件信息栏 + 等比缩放图片 + 文字 + 时间/双勾。base64 解码结果做进程级缓存,
 * 列表重组时不再重复解码(消灭闪烁,对位 iOS NSCache 做法)。
 *
 * 对位 iOS `PhotoMsgRenderer`。
 */
@Composable
fun PhotoMsgRenderer(component: Component) {
    val cardW = 272.dp
    val pad = 10.dp
    val maxImgH = 300.dp

    val p = component.props
    val items = remember(component.uid) { decodePhotoItems(p["images"]?.arrayValue ?: emptyList()) }
    val text = p.string("text").trim()
    val time = p.string("time")
    val imgW = cardW - pad * 2
    val shape = RoundedCornerShape(16.dp)

    Column(
        modifier = Modifier
            .width(cardW)
            .shadow(6.dp, shape)
            .clip(shape)
            .background(Theme.card, shape)
            .border(1.dp, Theme.purple.copy(alpha = 0.45f), shape)
            .padding(pad),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        items.firstOrNull()?.let { PhotoHeaderRow(it, total = items.size) }
        items.forEach { item ->
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (item.id != null) {
                    // 新链路:按 id 异步拉图(通道只传 id)
                    IdAsyncImage(
                        id = item.id,
                        maxW = imgW,
                        maxH = maxImgH,
                        contentDescription = item.name,
                    )
                } else if (item.bitmap != null) {
                    val (w, h) = fittedSize(item.width, item.height, imgW, maxImgH)
                    Image(
                        bitmap = item.bitmap.asImageBitmap(),
                        contentDescription = item.name,
                        modifier = Modifier
                            .width(w)
                            .height(h)
                            .clip(RoundedCornerShape(10.dp)),
                        contentScale = ContentScale.Crop,
                        filterQuality = FilterQuality.Medium,
                    )
                }
            }
        }
        if (text.isNotEmpty()) {
            Text(
                text,
                color = Theme.text,
                fontSize = 15.sp,
                lineHeight = 19.sp,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (time.isNotEmpty()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(time, color = Theme.textTer, fontSize = 11.sp)
                Spacer(Modifier.width(4.dp))
                DoubleCheck(Theme.blue)
            }
        }
    }
}

/** 顶部文件信息栏:图标 + 「Screenshot · PNG」 + 文件名·大小(id 图无名/大小时显示张数)。 */
@Composable
private fun PhotoHeaderRow(item: PhotoItem, total: Int) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(Theme.cardHi),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.Photo, null, tint = Theme.textSec, modifier = Modifier.size(15.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                if (item.kind.isEmpty()) "图片" else "Screenshot · ${item.kind}",
                color = Theme.text,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            val sub = listOf(item.name, item.size).filter { it.isNotEmpty() }.joinToString(" · ")
            Text(
                if (sub.isEmpty()) "$total 张" else sub,
                color = Theme.textSec,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(
            Icons.Default.SaveAlt,
            contentDescription = null,
            tint = Theme.textSec,
            modifier = Modifier.size(14.dp),
        )
    }
}

/**
 * 按 id 异步拉图(对位 iOS `IdAsyncImage`)。命中进程级 bitmap 缓存避免重复请求。
 * URL: `{REST_BASE}/api/image/{id}`,带 Bearer token。
 * 404/失败 → 显示「图片已过期」占位(对位 iOS clock.badge.xmark)。
 */
@Composable
internal fun IdAsyncImage(
    id: String,
    maxW: Dp,
    maxH: Dp,
    contentDescription: String? = null,
) {
    // null = loading;Result.failure = 失败;Result.success(bm) = 已加载
    val state by produceState<Result<Bitmap>?>(initialValue = idBitmapCache.get(id)?.let { Result.success(it) }, key1 = id) {
        if (value?.isSuccess == true) return@produceState
        value = withContext(Dispatchers.IO) {
            runCatching {
                val urlStr = "${com.aicodingremote.app.networking.ServerConfig.restBaseURL()}/api/image/$id"
                val conn = java.net.URL(urlStr).openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 15_000
                conn.readTimeout = 30_000
                com.aicodingremote.app.auth.SessionAuth.token?.let {
                    conn.setRequestProperty("Authorization", "Bearer $it")
                }
                if (conn.responseCode != 200) throw java.io.IOException("HTTP ${conn.responseCode}")
                conn.inputStream.use { BitmapFactory.decodeStream(it) }
                    ?: throw java.io.IOException("decode failed")
            }.onSuccess { idBitmapCache.put(id, it) }
        }
    }
    val shape = RoundedCornerShape(10.dp)
    when {
        state?.isSuccess == true -> {
            val bm = state!!.getOrNull()!!
            val (w, h) = fittedSize(bm.width, bm.height, maxW, maxH)
            Image(
                bitmap = bm.asImageBitmap(),
                contentDescription = contentDescription,
                modifier = Modifier.width(w).height(h).clip(shape),
                contentScale = ContentScale.Crop,
                filterQuality = FilterQuality.Medium,
            )
        }
        state?.isFailure == true -> {
            // 图片已过期(server 端 24h TTL 清掉后 → 404)。对位 iOS `clock.badge.xmark`。
            Column(
                modifier = Modifier
                    .width(150.dp)
                    .height(100.dp)
                    .clip(shape)
                    .background(Theme.cardHi),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(
                    Icons.Default.HourglassEmpty,
                    contentDescription = null,
                    tint = Theme.textTer,
                    modifier = Modifier.size(22.dp),
                )
                Spacer(Modifier.height(6.dp))
                Text("图片已过期", color = Theme.textSec, fontSize = 12.sp)
            }
        }
        else -> {
            Box(
                modifier = Modifier
                    .width(maxW.coerceAtMost(120.dp))
                    .height(90.dp)
                    .clip(shape)
                    .background(Theme.cardHi),
                contentAlignment = Alignment.Center,
            ) {
                androidx.compose.material3.CircularProgressIndicator(
                    color = Theme.blue,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

/** 按 id 拉到的 bitmap 进程级缓存,scroll 重组时不重复请求。 */
private val idBitmapCache = object : android.util.LruCache<String, Bitmap>(16) {}

/** Telegram 式双勾(已电脑端确认)。 */
@Composable
private fun DoubleCheck(color: Color) {
    Box {
        Icon(Icons.Default.Check, null, tint = color, modifier = Modifier.size(11.dp))
        Icon(
            Icons.Default.Check,
            null,
            tint = color,
            modifier = Modifier
                .size(11.dp)
                .offset(x = 4.dp),
        )
    }
}

/**
 * 一张图片(新旧两种格式):
 * - 新格式: 只带 [id] + 可选名/类型,实际像素按 id 经 HTTP 异步拉(对位 iOS IdAsyncImage)
 * - 旧格式: 带 [bitmap](base64 内联解码)
 */
private data class PhotoItem(
    val id: String? = null,
    val bitmap: Bitmap? = null,
    val width: Int = 0,
    val height: Int = 0,
    val name: String,
    val kind: String,
    val size: String,
)

/** base64 解码缓存(进程级),消灭列表重组时的重复解码闪烁。对位 iOS `NSCache`。 */
private val photoBitmapCache = object : android.util.LruCache<String, Bitmap>(16) {}

/**
 * 兼容两种 images 元素:对象 {data,name,kind,size} 或纯 base64 字符串(旧格式)。
 */
/**
 * 兼容 3 种 images 元素:
 * - `{id, ext, name?}`(新,通道只传 id,按 id HTTP 拉图,对位 iOS 新链路)
 * - `{data, name, kind, size}`(旧,base64 内联)
 * - 纯 base64 字符串(更旧,远古手机)
 */
private fun decodePhotoItems(arr: List<JsonElement>): List<PhotoItem> = arr.mapNotNull { v ->
    val obj = v.objectValue

    // 新格式:只有 id,真正的像素 IdAsyncImage 异步拉。
    if (obj != null) {
        val id = obj["id"]?.stringValue
        if (!id.isNullOrEmpty()) {
            return@mapNotNull PhotoItem(
                id = id,
                bitmap = null,
                name = obj["name"]?.stringValue ?: "",
                kind = (obj["ext"]?.stringValue ?: "").uppercase(),
                size = "",
            )
        }
    }

    // 旧格式:base64 内联(本地回显 / 历史 photomsg)。
    val b64 = if (obj != null) obj["data"]?.stringValue else v.stringValue
    b64 ?: return@mapNotNull null
    val name = obj?.get("name")?.stringValue ?: ""
    val kind = obj?.get("kind")?.stringValue ?: ""
    val size = obj?.get("size")?.stringValue ?: ""
    val key = "${b64.length}:${b64.take(48)}"
    val bitmap = photoBitmapCache.get(key) ?: runCatching {
        val bytes = Base64.decode(b64, Base64.DEFAULT)
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }.getOrNull()?.also { photoBitmapCache.put(key, it) } ?: return@mapNotNull null
    PhotoItem(
        id = null,
        bitmap = bitmap,
        width = bitmap.width,
        height = bitmap.height,
        name = name,
        kind = kind,
        size = size,
    )
}

/** 在 boxW × maxH 内按宽高比缩放,不裁切不留黑边。 */
private fun fittedSize(w: Int, h: Int, boxW: Dp, maxH: Dp): Pair<Dp, Dp> {
    if (w <= 0 || h <= 0) return boxW to boxW
    val scale = minOf(boxW.value / w, maxH.value / h)
    return (w * scale).dp to (h * scale).dp
}

// MARK: - 工具 chip(Read/Grep 等,紧凑无头像)

@Composable
fun ToolChipRenderer(component: Component) {
    val p = component.props
    val name = p.string("name")
    val input = p["input"]?.stringValue
    val color = Theme.named(p["color"]?.stringValue, default = Theme.textSec)
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .clip(CircleShape)
                .background(color.copy(alpha = 0.16f))
                .padding(horizontal = 9.dp, vertical = 3.dp),
        ) {
            Text(name, color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
        if (!input.isNullOrEmpty()) {
            Text(
                input,
                color = Theme.textSec,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

// MARK: - 运行命令卡

@Composable
fun CommandRenderer(component: Component) {
    val cmd = component.props.string("command")
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle(fill = Theme.field)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("运行命令", color = Theme.textSec, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            CopyButton(text = cmd, label = "复制")
        }
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            Text(
                text = "$ $cmd",
                color = Theme.text,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
            )
        }
    }
}
