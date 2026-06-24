package com.aicodingremote.app.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 全局设计令牌(对齐 cli-ios `Theme`,深色主题)。
 *
 * 颜色与圆角必须与 cli-ios 完全一致 —— 两端 UI 由同一份协议下发,色卡保持像素级对齐。
 */
object Theme {
    // 背景层
    val bg     = Color(0xFF0A0B0E)
    val card   = Color(0xFF16181E)
    val cardHi = Color(0xFF1C1F26)
    val field  = Color(0xFF101216)
    val stroke = Color(0xFF262A32)

    // 文字
    val text    = Color(0xFFF2F3F5)
    val textSec = Color(0xFF8B919C)
    val textTer = Color(0xFF5C616B)

    // 强调 / 状态
    val blue    = Color(0xFF3B82F6)
    val blueBtn = Color(0xFF2B6CF6)
    val coral   = Color(0xFFEE4F2E) // 主操作 / 危险
    val gold    = Color(0xFFC8990F) // 等待输入 / 回复
    val green   = Color(0xFF2FBE4F)
    val orange  = Color(0xFFF0A23C)
    val purple  = Color(0xFF5B5BD6)

    // 圆角
    val rCard: Dp = 16.dp
    val rBtn: Dp = 12.dp

    /**
     * 协议里的颜色名(`color`/`tint`/`style`)→ 深色令牌。未知名走 [default]。
     * 这是「服务端只发语义色名、客户端决定深色具体值」的落点。
     */
    fun named(name: String?, default: Color = textSec): Color = when (name) {
        "green", "success" -> green
        "red", "coral", "danger" -> coral
        "blue", "primary", "info" -> blue
        "gold", "warning" -> gold
        "orange" -> orange
        "purple" -> purple
        "text", "primaryText" -> text
        "secondary", "textSec" -> textSec
        "tertiary", "textTer" -> textTer
        else -> default
    }
}

/**
 * 应用主题包装。Material3 仅用作 Compose 控件的最底色板,我们绝大多数控件都按
 * cli-ios 重新画过,所以这层主要给 OutlinedTextField / Switch 这种系统控件兜底。
 */
@Composable
fun RemoteCodingTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Theme.blue,
            onPrimary = Color.White,
            background = Theme.bg,
            onBackground = Theme.text,
            surface = Theme.card,
            onSurface = Theme.text,
            surfaceVariant = Theme.cardHi,
            onSurfaceVariant = Theme.textSec,
            outline = Theme.stroke,
            error = Theme.coral,
        ),
        content = content,
    )
}

/**
 * 标准卡片容器外观(对位 iOS `cardStyle()` modifier):圆角 + 填充 + 描边。
 * 注意顺序:先按形状裁切 → 填底色 → 描边,这样圆角外的描边不会溢出。
 */
fun Modifier.cardStyle(
    fill: Color = Theme.card,
    stroke: Color = Theme.stroke,
    radius: Dp = Theme.rCard,
): Modifier {
    val shape = RoundedCornerShape(radius)
    return this
        .clip(shape)
        .background(fill, shape)
        .border(1.dp, stroke, shape)
}
