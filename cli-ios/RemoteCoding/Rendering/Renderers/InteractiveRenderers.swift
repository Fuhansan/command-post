import SwiftUI

/// PROTOCOL §5.2 / §6 —— 交互组件(深色皮肤)。点击后经 Environment 回传 action。

struct ButtonRenderer: View {
    let component: Component
    /// 点击后的本地即时反馈(组内共享):点过 → 高亮所点项 + 转圈,其余禁用。
    var pressed: Binding<Int?>? = nil
    var index: Int = 0

    @Environment(\.onComponentAction) private var onAction

    var body: some View {
        let label = component.props.string("label", default: "确定")
        let style = component.props.string("style", default: "default")
        let icon = component.props["icon"]?.stringValue
        let isPressed = pressed?.wrappedValue == index
        let anyPressed = pressed?.wrappedValue != nil
        Button {
            guard !anyPressed else { return }   // 防重复点击
            pressed?.wrappedValue = index       // 立即本地反馈,不等服务器
            if let action = component.action { onAction(action) }
        } label: {
            HStack(spacing: 6) {
                if isPressed {
                    ProgressView().controlSize(.mini).tint(Self.fg(style))
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                }
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Self.fg(style))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Self.bg(style))
            .overlay(RoundedRectangle(cornerRadius: Theme.rBtn).stroke(Self.border(style), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rBtn))
            .opacity(anyPressed && !isPressed ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: pressed?.wrappedValue)
    }

    static func bg(_ s: String) -> Color {
        switch s {
        case "primary": return Theme.blueBtn
        case "danger":  return Theme.coral
        default:        return Theme.cardHi
        }
    }
    static func fg(_ s: String) -> Color { s == "default" ? Theme.text : .white }
    static func border(_ s: String) -> Color { s == "default" ? Theme.stroke : .clear }
}

struct ButtonGroupRenderer: View {
    let component: Component
    @State private var pressed: Int? = nil   // 本地点击态;agent 重发新卡片后视图重建自动复位

    var body: some View {
        let buttons = component.props["buttons"]?.arrayValue ?? []
        HStack(spacing: 10) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { i, json in
                ButtonRenderer(component: Component(json: json), pressed: $pressed, index: i)
            }
        }
    }
}

struct SelectRenderer: View {
    let component: Component
    @Environment(\.onComponentAction) private var onAction
    @State private var selected: String?

    var body: some View {
        let options = component.props["options"]?.arrayValue ?? []
        let placeholder = component.props.string("placeholder", default: "请选择")
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button(opt.string("label")) {
                    selected = opt.string("label")
                    if let base = component.action {
                        onAction(ComponentAction(json: .object([
                            "id": .string(base.id),
                            "value": opt["value"] ?? .string(opt.string("label"))
                        ]))!)
                    }
                }
            }
        } label: {
            HStack {
                Text(selected ?? placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(selected == nil ? Theme.textTer : Theme.text)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.textSec)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: Theme.rBtn).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rBtn))
        }
    }
}

struct TextInputRenderer: View {
    let component: Component
    @Environment(\.onComponentAction) private var onAction
    @State private var text = ""

    var body: some View {
        let placeholder = component.props.string("placeholder", default: "")
        let submitLabel = component.props.string("submitLabel", default: "发送")
        HStack(spacing: 10) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.textTer), axis: .vertical)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: Theme.rBtn).stroke(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rBtn))
            Button(submitLabel) {
                guard let base = component.action else { return }
                onAction(ComponentAction(json: .object([
                    "id": .string(base.id),
                    "value": .string(text)
                ]))!)
                text = ""
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(text.isEmpty ? Theme.textTer : .white)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(text.isEmpty ? Theme.cardHi : Theme.blueBtn)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rBtn))
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
        }
    }
}

struct ToggleRenderer: View {
    let component: Component
    @Environment(\.onComponentAction) private var onAction
    @State private var isOn: Bool

    init(component: Component) {
        self.component = component
        _isOn = State(initialValue: component.props.bool("value"))
    }

    var body: some View {
        Toggle(component.props.string("label"), isOn: $isOn)
            .font(.system(size: 14))
            .foregroundStyle(Theme.text)
            .tint(Theme.blue)
            .onChange(of: isOn) { _, newValue in
                guard let base = component.action else { return }
                onAction(ComponentAction(json: .object([
                    "id": .string(base.id),
                    "value": .bool(newValue)
                ]))!)
            }
    }
}
