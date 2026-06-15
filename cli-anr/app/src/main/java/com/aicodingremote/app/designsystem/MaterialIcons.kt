package com.aicodingremote.app.designsystem

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.automirrored.filled.Assignment
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.QuestionAnswer
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * 协议下发的图标名(借用 SF Symbols 的命名空间)→ Material Icons 映射。
 *
 * 这是 iOS↔Android 视觉对齐的关键一层。两端共享同一份协议里的图标名,
 * 各自把名字翻译成本平台的图标库。新增名字时同步两端,保证一致性。
 */
object IconResolver {
    fun resolve(name: String?): ImageVector = when (name) {
        "terminal", "terminal.fill" -> Icons.Default.Terminal
        "chevron.left" -> Icons.AutoMirrored.Filled.KeyboardArrowLeft
        "chevron.right" -> Icons.AutoMirrored.Filled.KeyboardArrowRight
        "chevron.down" -> Icons.Default.KeyboardArrowDown
        "chevron.up" -> Icons.Default.KeyboardArrowUp
        "chevron.up.chevron.down" -> Icons.Default.UnfoldMore
        "chevron.left.forwardslash.chevron.right" -> Icons.Default.Code
        "ellipsis" -> Icons.Default.MoreHoriz
        "ellipsis.bubble" -> Icons.AutoMirrored.Filled.Chat
        "paperplane.fill" -> Icons.AutoMirrored.Filled.Send
        "bell" -> Icons.Default.Notifications
        "bell.slash" -> Icons.Default.NotificationsOff
        "checklist" -> Icons.AutoMirrored.Filled.Assignment
        "desktopcomputer" -> Icons.Default.Computer
        "gearshape" -> Icons.Default.Settings
        "checkmark" -> Icons.Default.Check
        "checkmark.circle", "checkmark.circle.fill" -> Icons.Default.CheckCircle
        "hourglass" -> Icons.Default.HourglassEmpty
        "bubble.left.and.text.bubble.right" -> Icons.Default.QuestionAnswer
        "bubble.left.fill" -> Icons.AutoMirrored.Filled.Chat
        "play.circle" -> Icons.Default.PlayCircle
        "play.fill" -> Icons.Default.PlayArrow
        "exclamationmark.triangle", "exclamationmark.triangle.fill" -> Icons.Default.Warning
        "exclamationmark.circle.fill" -> Icons.Default.Error
        "doc.text" -> Icons.AutoMirrored.Filled.Article
        "doc.on.doc" -> Icons.Default.ContentCopy
        "curlybraces" -> Icons.Default.DataObject
        "questionmark.square.dashed" -> Icons.Default.QuestionMark
        "photo" -> Icons.Default.Photo
        "sparkles" -> Icons.Default.AutoAwesome
        "swift" -> Icons.Default.Code
        "line.3.horizontal.decrease" -> Icons.Default.FilterList
        "wifi" -> Icons.Default.Wifi
        "g.circle.fill" -> Icons.Default.AccountCircle
        "arrow.down.circle.fill" -> Icons.Default.ArrowCircleDown
        null, "" -> Icons.Default.QuestionMark
        else -> Icons.Default.QuestionMark
    }
}
