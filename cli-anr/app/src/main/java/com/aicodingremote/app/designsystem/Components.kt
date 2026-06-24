package com.aicodingremote.app.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldColors
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.models.AppNotification
import com.aicodingremote.app.models.TaskStatus

/** 字母头像(圆角方块)。对位 iOS `Avatar`。 */
@Composable
fun Avatar(
    letter: String,
    color: Color,
    size: Dp = 44.dp,
) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(Brush.linearGradient(listOf(color, color.copy(alpha = 0.78f)))),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = letter,
            color = Color.White,
            fontWeight = FontWeight.Bold,
            fontSize = (size.value * 0.42f).sp,
        )
    }
}

/** 状态徽章(图标 + 文字,半透明底色)。对位 iOS `StatusBadge`。 */
@Composable
fun StatusBadge(status: TaskStatus) {
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(status.color.copy(alpha = 0.14f))
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(status.icon, contentDescription = null, tint = status.color, modifier = Modifier.size(11.dp))
        Text(status.label, color = status.color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 通用区块卡头部(图标 + 标题)。对位 iOS `SectionHeader`。 */
@Composable
fun SectionHeader(
    icon: ImageVector,
    title: String,
    tint: Color = Theme.textSec,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Text(
            title,
            color = if (tint == Theme.textSec) Theme.text else tint,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.weight(1f))
    }
}

/** 通用区块卡容器。对位 iOS `SectionCard`。 */
@Composable
fun SectionCard(
    icon: ImageVector,
    title: String,
    tint: Color = Theme.textSec,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SectionHeader(icon = icon, title = title, tint = tint)
        content()
    }
}

/** 通知行。对位 iOS `NotificationRow`。 */
@Composable
fun NotificationRow(noti: AppNotification) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle()
            .padding(14.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            noti.kind.icon,
            contentDescription = null,
            tint = noti.kind.color,
            modifier = Modifier.size(18.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(noti.title, color = Theme.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(noti.subtitle, color = Theme.textSec, fontSize = 13.sp)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(noti.time, color = Theme.textTer, fontSize = 12.sp)
            if (noti.unread) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(Theme.blue))
            }
        }
    }
}

/** 中性(描边)按钮 —— 复用组件。对位 iOS `NeutralButton`。 */
@Composable
fun NeutralButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Button(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .height(46.dp),
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Theme.cardHi,
            contentColor = Theme.text,
        ),
        border = androidx.compose.foundation.BorderStroke(1.dp, Theme.stroke),
    ) {
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 顶部「更多」图标按钮(详情页右上的 ellipsis)。 */
@Composable
fun MoreIcon(tint: Color = Theme.text) {
    Icon(Icons.Default.MoreHoriz, contentDescription = "更多", tint = tint, modifier = Modifier.size(20.dp))
}

/** 暗色输入框配色(供 OutlinedTextField 复用)。 */
@Composable
fun darkFieldColors(): TextFieldColors = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Theme.text,
    unfocusedTextColor = Theme.text,
    focusedBorderColor = Theme.blue,
    unfocusedBorderColor = Theme.stroke,
    focusedContainerColor = Theme.field,
    unfocusedContainerColor = Theme.field,
    cursorColor = Theme.blue,
    focusedPlaceholderColor = Theme.textTer,
    unfocusedPlaceholderColor = Theme.textTer,
)
