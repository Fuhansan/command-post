import SwiftUI

/// PROTOCOL §10 —— 交互动作回传通道(经 Environment 注入,由 ChatView 提供具体实现)。
struct ComponentActionKey: EnvironmentKey {
    static let defaultValue: (ComponentAction) -> Void = { _ in }
}
extension EnvironmentValues {
    var onComponentAction: (ComponentAction) -> Void {
        get { self[ComponentActionKey.self] }
        set { self[ComponentActionKey.self] = newValue }
    }
}

/// PROTOCOL §10 —— 渲染器注册表 / 递归分发器。
/// 新增组件类型 = 在此加一个 case + 一个渲染器文件,碰不到旧代码。
/// 未知 `type` 一律走 `UnknownRenderer`,绝不崩溃(原则 2)。
struct ComponentView: View {
    let component: Component

    var body: some View {
        switch component.type {
        // 布局 / 容器
        case "stack":        StackRenderer(component: component)
        case "row":          RowRenderer(component: component)
        case "card":         CardRenderer(component: component)
        case "spacer":       Spacer(minLength: 0)
        case "divider":      Divider().overlay(Theme.stroke)
        // 内容
        case "text":         TextRenderer(component: component)
        case "bubble":       BubbleRenderer(component: component)
        case "code":         CodeRenderer(component: component)
        case "badge":        BadgeRenderer(component: component)
        case "keyvalue":     KeyValueRenderer(component: component)
        case "progress":     ProgressRenderer(component: component)
        case "image":        ImageRenderer(component: component)
        case "diff":         DiffRenderer(component: component)
        case "file":         FileRenderer(component: component)
        case "command":      CommandRenderer(component: component)
        case "toolchip":     ToolChipRenderer(component: component)
        case "toolop":       ToolOpRenderer(component: component)
        case "tooltimeline": ToolTimelineRenderer(component: component)
        case "photomsg":     PhotoMsgRenderer(component: component)
        case "choices":      ChoicesRenderer(component: component)
        // 交互
        case "button":       ButtonRenderer(component: component)
        case "button_group": ButtonGroupRenderer(component: component)
        case "select":       SelectRenderer(component: component)
        case "text_input":   TextInputRenderer(component: component)
        case "toggle":       ToggleRenderer(component: component)
        // 兜底
        default:             UnknownRenderer(component: component)
        }
    }
}

/// 渲染子组件列表的小工具。
struct ChildrenView: View {
    let children: [Component]
    var body: some View {
        ForEach(children) { child in
            ComponentView(component: child)
        }
    }
}
