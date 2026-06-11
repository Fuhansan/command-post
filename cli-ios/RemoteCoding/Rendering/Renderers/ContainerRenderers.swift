import SwiftUI

/// PROTOCOL §5.2 —— 布局 / 容器组件(深色皮肤)。

struct StackRenderer: View {
    let component: Component
    var body: some View {
        let spacing = component.props.double("spacing").map { CGFloat($0) } ?? 10
        let padding = component.props.double("padding").map { CGFloat($0) } ?? 0
        VStack(alignment: .leading, spacing: spacing) {
            ChildrenView(children: component.children)
        }
        .padding(padding)
    }
}

struct RowRenderer: View {
    let component: Component
    var body: some View {
        let spacing = component.props.double("spacing").map { CGFloat($0) } ?? 8
        HStack(alignment: Self.align(component.props.string("align", default: "center")), spacing: spacing) {
            ChildrenView(children: component.children)
        }
    }
    static func align(_ s: String) -> VerticalAlignment {
        switch s {
        case "top":    return .top
        case "bottom": return .bottom
        default:       return .center
        }
    }
}

/// 卡片容器。默认中性深色卡;`style` / `tint` 只染图标、标题与边框,卡身始终保持深色。
struct CardRenderer: View {
    let component: Component
    @State private var collapsed: Bool

    init(component: Component) {
        self.component = component
        _collapsed = State(initialValue: component.props.bool("collapsed"))
    }

    var body: some View {
        let p = component.props
        let title = p["title"]?.stringValue
        let icon = p["icon"]?.stringValue
        let style = p.string("style", default: "default")
        let collapsible = p.bool("collapsible")
        let accent = Self.accent(style)
        // tint 优先于 style 决定图标色;default 风格图标走次要灰。
        let iconTint = p["tint"]?.stringValue.map { Theme.named($0) } ?? (style == "default" ? Theme.textSec : accent)
        let strokeColor = style == "default" ? Theme.stroke : accent.opacity(0.85)
        let glow = p.bool("glow", default: style != "default")

        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 14)).foregroundStyle(iconTint)
                    }
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if collapsible {
                        Button { withAnimation { collapsed.toggle() } } label: {
                            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !collapsed {
                ChildrenView(children: component.children)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard).stroke(strokeColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rCard))
        .shadow(color: glow ? accent.opacity(0.22) : .clear, radius: glow ? 12 : 0)
    }

    static func accent(_ style: String) -> Color {
        switch style {
        case "warning": return Theme.gold
        case "danger":  return Theme.coral
        case "success": return Theme.green
        case "info":    return Theme.blue
        default:        return Theme.textSec
        }
    }
}
