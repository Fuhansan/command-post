import SwiftUI

/// PROTOCOL §5.2 —— 内容 / 叶子组件(深色皮肤)。

struct TextRenderer: View {
    let component: Component
    var body: some View {
        let p = component.props
        let text = p.string("text")
        let isMarkdown = p.bool("markdown")
        if isMarkdown {
            MarkdownText(text: text)   // 完整 markdown 渲染(深色主题)
        } else {
            plain(p, text)
        }
    }

    @ViewBuilder
    private func plain(_ p: JSONValue, _ text: String) -> some View {
        let style = p.string("style", default: "body")
        let mono = p.bool("mono")
        let bold = p.bool("bold")
        let size = Self.size(style)
        let weight: Font.Weight = (bold || style == "heading") ? .semibold : .regular
        let font: Font = mono
            ? .system(size: size, weight: weight, design: .monospaced)
            : .system(size: size, weight: weight)
        let fg: Color = p["color"]?.stringValue.map { Theme.named($0, default: Theme.text) }
            ?? (style == "caption" ? Theme.textSec : Theme.text)
        // fill=true 让文本块撑满一行(默认);行内小元素(如要点圆点)设 fill=false 保持紧凑。
        let fill = p.bool("fill", default: true)

        Text(text)
            .font(font)
            .foregroundStyle(fg)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
    }

    static func size(_ style: String) -> CGFloat {
        switch style {
        case "heading": return 17
        case "caption": return 13
        default:        return 15
        }
    }
}

/// 会话文本块。agent → 左侧悬浮卡(配合外侧头像);user → 右对齐蓝气泡。
struct BubbleRenderer: View {
    let component: Component
    var body: some View {
        let p = component.props
        let textStr = p.string("text")
        let isMarkdown = p.bool("markdown")
        let isUser = p.string("role", default: "agent") == "user"

        let content = Group {
            if isMarkdown, let attr = try? AttributedString(markdown: textStr) {
                Text(attr)
            } else {
                Text(textStr)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(Theme.text)
        .multilineTextAlignment(.leading)
        .lineSpacing(2)

        if isUser {
            // 右对齐由 TaskDetailView 的 user 分支统一处理,这里只出气泡本体。
            content
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.blueBtn.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .cardStyle()
        }
    }
}

struct CodeRenderer: View {
    let component: Component
    @State private var copied = false

    var body: some View {
        let code = component.props.string("code")
        let language = component.props["language"]?.stringValue
        let copyable = component.props.bool("copyable", default: true)

        VStack(alignment: .leading, spacing: 6) {
            if language != nil || copyable {
                HStack {
                    if let language { Text(language).font(.system(size: 11)).foregroundStyle(Theme.textTer) }
                    Spacer()
                    if copyable {
                        Button {
                            UIPasteboard.general.string = code
                            copied = true
                        } label: {
                            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11)).foregroundStyle(Theme.textSec)
                        }.buttonStyle(.plain)
                    }
                }
            }
            // 自动换行显示完整命令(不再横向滚动只露开头)—— 审批时能一眼看清整条命令。
            Text(code).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.field)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct BadgeRenderer: View {
    let component: Component
    var body: some View {
        let text = component.props.string("text")
        let color = Theme.named(component.props["color"]?.stringValue, default: Theme.textSec)
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct KeyValueRenderer: View {
    let component: Component
    var body: some View {
        let items = component.props["items"]?.arrayValue ?? []
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top) {
                    Text(item.string("k")).font(.system(size: 13)).foregroundStyle(Theme.textSec)
                    Spacer()
                    Text(item.string("v")).font(.system(size: 13)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

struct ProgressRenderer: View {
    let component: Component
    var body: some View {
        let label = component.props["label"]?.stringValue
        let value = component.props.double("value")
        VStack(alignment: .leading, spacing: 6) {
            if let label { Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSec) }
            if let value {
                ProgressView(value: max(0, min(1, value))).tint(Theme.blue)
            } else {
                ProgressView().tint(Theme.blue)   // 无限转圈
            }
        }
    }
}

struct ImageRenderer: View {
    let component: Component
    var body: some View {
        let p = component.props
        // 优先内联 base64(Mac 本地图片经 agent 缩略图内联);否则走 url。
        if let dataStr = p["data"]?.stringValue,
           let data = Data(base64Encoded: dataStr), let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFit()
                .frame(maxWidth: 240, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke.opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        } else if let urlString = p["url"]?.stringValue ?? p["thumbUrl"]?.stringValue,
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Image(systemName: "photo").foregroundStyle(Theme.textTer)
                default: ProgressView().tint(Theme.blue)
                }
            }
            .frame(maxWidth: 220, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(Theme.textTer)
                .frame(width: 120, height: 90).background(Theme.cardHi)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct DiffRenderer: View {
    let component: Component
    var body: some View {
        let filename = component.props["filename"]?.stringValue
        let hunks = component.props["hunks"]?.arrayValue ?? []
        VStack(alignment: .leading, spacing: 0) {
            if let filename {
                Text(filename).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSec)
                    .padding(.bottom, 6)
            }
            ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                let op = hunk.string("op", default: "ctx")
                Text((op == "add" ? "+ " : op == "del" ? "- " : "  ") + hunk.string("text"))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(Self.bg(op))
                    .foregroundStyle(Self.fg(op))
            }
        }
        .padding(10)
        .background(Theme.field)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    static func bg(_ op: String) -> Color {
        op == "add" ? Theme.green.opacity(0.14) : op == "del" ? Theme.coral.opacity(0.14) : .clear
    }
    static func fg(_ op: String) -> Color {
        op == "add" ? Theme.green : op == "del" ? Theme.coral : Theme.textSec
    }
}
