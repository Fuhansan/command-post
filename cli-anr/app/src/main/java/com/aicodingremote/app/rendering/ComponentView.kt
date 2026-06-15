package com.aicodingremote.app.rendering

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.models.Component
import com.aicodingremote.app.rendering.renderers.BadgeRenderer
import com.aicodingremote.app.rendering.renderers.BubbleRenderer
import com.aicodingremote.app.rendering.renderers.ButtonGroupRenderer
import com.aicodingremote.app.rendering.renderers.ButtonRenderer
import com.aicodingremote.app.rendering.renderers.CardRenderer
import com.aicodingremote.app.rendering.renderers.ChoicesRenderer
import com.aicodingremote.app.rendering.renderers.CodeRenderer
import com.aicodingremote.app.rendering.renderers.CommandRenderer
import com.aicodingremote.app.rendering.renderers.DiffRenderer
import com.aicodingremote.app.rendering.renderers.FileRenderer
import com.aicodingremote.app.rendering.renderers.ImageRenderer
import com.aicodingremote.app.rendering.renderers.KeyValueRenderer
import com.aicodingremote.app.rendering.renderers.PhotoMsgRenderer
import com.aicodingremote.app.rendering.renderers.ProgressRenderer
import com.aicodingremote.app.rendering.renderers.RowRenderer
import com.aicodingremote.app.rendering.renderers.SelectRenderer
import com.aicodingremote.app.rendering.renderers.StackRenderer
import com.aicodingremote.app.rendering.renderers.TextInputRenderer
import com.aicodingremote.app.rendering.renderers.TextRenderer
import com.aicodingremote.app.rendering.renderers.ToggleRenderer
import com.aicodingremote.app.rendering.renderers.ToolChipRenderer
import com.aicodingremote.app.rendering.renderers.UnknownRenderer

/**
 * PROTOCOL §10 —— 渲染器注册表 / 递归分发器。
 *
 * - 新增组件类型 = 在此加一个 case + 一个渲染器文件,碰不到旧代码。
 * - 未知 `type` 一律走 [UnknownRenderer],绝不崩溃(原则 2)。
 *
 * 与 cli-ios `ComponentView` 一一对应。
 */
@Composable
fun ComponentView(component: Component) {
    when (component.type) {
        // 布局 / 容器
        "stack" -> StackRenderer(component)
        "row" -> RowRenderer(component)
        "card" -> CardRenderer(component)
        "spacer" -> Spacer(Modifier.height(0.dp))
        "divider" -> HorizontalDivider(color = Theme.stroke)
        // 内容
        "text" -> TextRenderer(component)
        "bubble" -> BubbleRenderer(component)
        "code" -> CodeRenderer(component)
        "badge" -> BadgeRenderer(component)
        "keyvalue" -> KeyValueRenderer(component)
        "progress" -> ProgressRenderer(component)
        "image" -> ImageRenderer(component)
        "diff" -> DiffRenderer(component)
        "file" -> FileRenderer(component)
        "command" -> CommandRenderer(component)
        "toolchip" -> ToolChipRenderer(component)
        "photomsg" -> PhotoMsgRenderer(component)
        // 交互
        "button" -> ButtonRenderer(component)
        "button_group" -> ButtonGroupRenderer(component)
        "choices" -> ChoicesRenderer(component)
        "select" -> SelectRenderer(component)
        "text_input" -> TextInputRenderer(component)
        "toggle" -> ToggleRenderer(component)
        // 兜底
        else -> UnknownRenderer(component)
    }
}

/** 渲染子组件列表的小工具(与 iOS `ChildrenView` 对应)。 */
@Composable
fun ChildrenView(children: List<Component>) {
    children.forEach { ComponentView(it) }
}
