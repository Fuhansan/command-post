package com.aicodingremote.app.rendering.renderers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.designsystem.IconResolver
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.models.Component
import com.aicodingremote.app.models.bool
import com.aicodingremote.app.models.double
import com.aicodingremote.app.models.get
import com.aicodingremote.app.models.string
import com.aicodingremote.app.models.stringValue
import com.aicodingremote.app.rendering.ChildrenView

/** PROTOCOL §5.2 —— 纵向排列容器。`align="trailing"` 时子项右对齐(用户侧)。 */
@Composable
fun StackRenderer(component: Component) {
    val spacing = component.props.double("spacing")?.dp ?: 10.dp
    val padding = component.props.double("padding")?.dp ?: 0.dp
    val align = if (component.props.string("align") == "trailing") Alignment.End else Alignment.Start
    Column(
        verticalArrangement = Arrangement.spacedBy(spacing),
        horizontalAlignment = align,
        modifier = Modifier.fillMaxWidth().padding(padding),
    ) {
        ChildrenView(component.children)
    }
}

/** PROTOCOL §5.2 —— 横向排列容器。 */
@Composable
fun RowRenderer(component: Component) {
    val spacing = component.props.double("spacing")?.dp ?: 8.dp
    val align = when (component.props.string("align", "center")) {
        "top" -> Alignment.Top
        "bottom" -> Alignment.Bottom
        else -> Alignment.CenterVertically
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(spacing),
        verticalAlignment = align,
    ) {
        ChildrenView(component.children)
    }
}

/**
 * 卡片容器。默认中性深色卡;`style` / `tint` 只染图标、标题与边框,卡身始终保持深色。
 * `glow=true` 时四周加阴影,模拟 iOS `.shadow(...)`。
 */
@Composable
fun CardRenderer(component: Component) {
    val p = component.props
    val title = p["title"]?.stringValue
    val icon = p["icon"]?.stringValue
    val style = p.string("style", "default")
    val collapsible = p.bool("collapsible")
    val accent = cardAccent(style)
    val iconTint = p["tint"]?.stringValue?.let { Theme.named(it) }
        ?: if (style == "default") Theme.textSec else accent
    val strokeColor = if (style == "default") Theme.stroke else accent.copy(alpha = 0.85f)
    val glow = p.bool("glow", default = style != "default")

    var collapsed by rememberSaveable(component.uid) { mutableStateOf(p.bool("collapsed")) }
    val shape = RoundedCornerShape(Theme.rCard)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (glow) it.shadow(12.dp, shape, ambientColor = accent, spotColor = accent) else it }
            .clip(shape)
            .background(Theme.card, shape)
            .border(1.dp, strokeColor, shape)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (title != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (icon != null) {
                    Icon(IconResolver.resolve(icon), null, tint = iconTint, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(8.dp))
                }
                Text(title, color = Theme.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                if (collapsible) {
                    IconButton(onClick = { collapsed = !collapsed }, modifier = Modifier.size(24.dp)) {
                        Icon(
                            if (collapsed) Icons.Default.KeyboardArrowDown else Icons.Default.KeyboardArrowUp,
                            contentDescription = if (collapsed) "展开" else "折叠",
                            tint = Theme.textSec,
                            modifier = Modifier.size(13.dp),
                        )
                    }
                }
            }
        }
        if (!collapsed) {
            ChildrenView(component.children)
        }
    }
}

private fun cardAccent(style: String): Color = when (style) {
    "warning" -> Theme.gold
    "danger" -> Theme.coral
    "success" -> Theme.green
    "info" -> Theme.blue
    else -> Theme.textSec
}
