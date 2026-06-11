import MarkdownUI
import SwiftUI

// MARK: - Markdown 文本(深色主题:加粗/行内代码/列表/代码块/链接等)

struct MarkdownText: View {
    let text: String
    var body: some View {
        Markdown(text)
            .markdownTextStyle { ForegroundColor(Theme.text); FontSize(15) }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced); FontSize(13.5)
                ForegroundColor(Theme.text); BackgroundColor(Theme.cardHi)
            }
            .markdownTextStyle(\.link) { ForegroundColor(Theme.blue) }
            .markdownBlockStyle(\.codeBlock) { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced); FontSize(12.5); ForegroundColor(Theme.text)
                        }
                        .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                configuration.label
                    .padding(.leading, 12)
                    .overlay(Rectangle().fill(Theme.stroke).frame(width: 3), alignment: .leading)
                    .foregroundStyle(Theme.textSec)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 语言样式(文件图标 / 渐变色)

enum LangStyle {
    static func icon(forPath path: String) -> String {
        switch ext(path) {
        case "swift": return "swift"
        case "md", "txt": return "doc.text"
        case "json", "yml", "yaml": return "curlybraces"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
    static func colors(forPath path: String) -> [Color] {
        switch ext(path) {
        case "swift":            return [Color(hex: 0xF05138), Color(hex: 0xFF7043)]
        case "ts", "tsx":        return [Color(hex: 0x3178C6), Color(hex: 0x4F9CD9)]
        case "js", "jsx", "mjs": return [Color(hex: 0xD9B400), Color(hex: 0xF2D44E)]
        case "py":               return [Color(hex: 0x3776AB), Color(hex: 0x4B8BBE)]
        case "go":               return [Color(hex: 0x00ADD8), Color(hex: 0x4FD1E0)]
        case "rs":               return [Color(hex: 0xB7410E), Color(hex: 0xD2691E)]
        case "java", "kt":       return [Color(hex: 0xCC5C2E), Color(hex: 0xE08252)]
        default:                 return [Color(hex: 0x6E59C7), Color(hex: 0x9277E0)]
        }
    }
    static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }
}

/// 按消息根组件类型决定左侧头像(图标 + 渐变)。
/// 注:分组消息根是 `stack`(文本+卡片)→ 走默认 ✦ 头像,代表「一段 AI 操作」。
func messageAvatarStyle(for root: Component) -> (icon: String, colors: [Color]) {
    switch root.type {
    case "file":    let p = root.props.string("path"); return (LangStyle.icon(forPath: p), LangStyle.colors(forPath: p))
    case "command": return ("terminal", [Color(hex: 0x16A394), Color(hex: 0x37C9B5)])
    case "image":   return ("photo", [Color(hex: 0x4A4F5A), Color(hex: 0x6B7280)])
    case "card":
        return root.props.string("style") == "danger"
            ? ("exclamationmark.circle.fill", [Color(hex: 0xEE4F2E), Color(hex: 0xFF7A5C)])
            : ("sparkles", [Color(hex: 0x7C5CD6), Color(hex: 0xA886F0)])
    default:        return ("sparkles", [Color(hex: 0x7C5CD6), Color(hex: 0xA886F0)])   // AI 文本/stack
    }
}

/// 消息左侧头像:圆角渐变方块 + 图标。
struct MessageAvatar: View {
    let icon: String
    let colors: [Color]
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 34, height: 34)
            .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
    }
}

// MARK: - 文件改动卡(语言图标在外侧头像;卡内:文件名 + 路径 + +N + 折叠 diff)

struct FileRenderer: View {
    let component: Component
    @State private var expanded = false   // 默认折叠

    var body: some View {
        let p = component.props
        let path = p.string("path")
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let adds = p["additions"]?.intValue ?? 0
        let hunks = p["hunks"]?.arrayValue ?? []

        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        if !dir.isEmpty {
                            Text(shorten(dir)).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textSec).lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 8)
                    if adds > 0 {
                        Text("+\(adds)").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.green)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.green.opacity(0.16)).clipShape(Capsule())
                    }
                    if !hunks.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded, !hunks.isEmpty {
                DiffLinesView(hunks: hunks)
                    .padding(.top, 12)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func shorten(_ dir: String) -> String {
        let home = NSHomeDirectory()
        var s = dir
        if s.hasPrefix(home) { s = "~" + s.dropFirst(home.count) }
        let parts = s.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(3).joined(separator: "/") + "/" : s + "/"
    }
}

/// 带行号 + 红删绿增背景的 diff(对齐设计稿)。
struct DiffLinesView: View {
    let hunks: [JSONValue]

    private struct DLine: Identifiable {
        let id = UUID()
        let num: String
        let sign: String
        let text: String
        let fg: Color
        let bg: Color
        let numColor: Color
    }

    var body: some View {
        let lines = build()
        VStack(alignment: .leading, spacing: 0) {
            // hunk 头(取首个上下文/删除行作提示)
            Text("@@ 改动 @@").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTer)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardHi)
            ForEach(lines) { ln in
                HStack(alignment: .top, spacing: 0) {
                    Text(ln.num).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ln.numColor)
                        .frame(width: 30, alignment: .trailing)
                        .padding(.trailing, 8)
                    Text(ln.sign).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(ln.fg).frame(width: 12, alignment: .leading)
                    Text(ln.text).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ln.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2).padding(.horizontal, 8)
                .background(ln.bg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
    }

    private func build() -> [DLine] {
        var oldN = 1, newN = 1
        return hunks.map { h in
            let op = h.string("op", default: "ctx")
            let text = h.string("text")
            switch op {
            case "add":
                defer { newN += 1 }
                return DLine(num: "\(newN)", sign: "+", text: text,
                             fg: Theme.green, bg: Theme.green.opacity(0.12), numColor: Theme.green.opacity(0.8))
            case "del":
                defer { oldN += 1 }
                return DLine(num: "\(oldN)", sign: "-", text: text,
                             fg: Theme.coral, bg: Theme.coral.opacity(0.12), numColor: Theme.coral.opacity(0.8))
            default:
                defer { oldN += 1; newN += 1 }
                return DLine(num: "\(newN)", sign: " ", text: text,
                             fg: Theme.textSec, bg: .clear, numColor: Theme.textTer)
            }
        }
    }
}

// MARK: - 图文消息(用户粘贴图 + 文字 → 一个统一气泡:图在上、文字在下)

struct PhotoMsgRenderer: View {
    let component: Component
    private let maxW: CGFloat = 234
    private let maxH: CGFloat = 280
    private let radius: CGFloat = 20
    private let pad: CGFloat = 4          // 气泡内图片四周留白(iMessage 风)

    var body: some View {
        let p = component.props
        let uis = decodeImages(p["images"]?.arrayValue ?? [])
        let text = p.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
        // 气泡宽度:跟随图片(单图按宽高比),无图则用文字宽度。
        let imgW = uis.first.map { fitted($0.size).width } ?? (maxW - pad * 2)
        let bubbleW = imgW + pad * 2

        VStack(alignment: .leading, spacing: text.isEmpty ? 0 : 7) {
            ForEach(Array(uis.enumerated()), id: \.offset) { _, ui in
                let s = fitted(ui.size)
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: s.width, height: s.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius - pad, style: .continuous))
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 15)).foregroundStyle(.white)
                    .multilineTextAlignment(.leading).lineSpacing(2)
                    .frame(width: imgW, alignment: .leading)
                    .padding(.horizontal, 6).padding(.bottom, 4)
            }
        }
        .padding(pad)
        .frame(width: bubbleW)
        .background(Theme.blueBtn)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
    }

    /// base64 → UIImage(去掉解码失败项)。
    private func decodeImages(_ arr: [JSONValue]) -> [UIImage] {
        arr.compactMap { v in
            guard let s = v.stringValue, let d = Data(base64Encoded: s) else { return nil }
            return UIImage(data: d)
        }
    }

    /// 在 (maxW-2pad) × maxH 内按宽高比缩放,既不裁切也不留黑边。
    private func fitted(_ size: CGSize) -> CGSize {
        let boxW = maxW - pad * 2
        guard size.width > 0, size.height > 0 else { return CGSize(width: boxW, height: boxW) }
        let scale = min(boxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - 工具 chip(Read/Grep 等,紧凑无头像)

struct ToolChipRenderer: View {
    let component: Component
    var body: some View {
        let p = component.props
        let name = p.string("name")
        let input = p["input"]?.stringValue
        let color = Theme.named(p["color"]?.stringValue, default: Theme.textSec)
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(color.opacity(0.16)).clipShape(Capsule())
            if let input, !input.isEmpty {
                Text(input).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSec).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 运行命令卡

struct CommandRenderer: View {
    let component: Component
    @State private var copied = false

    var body: some View {
        let cmd = component.props.string("command")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("运行命令").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
                Spacer()
                Button {
                    UIPasteboard.general.string = cmd; copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSec)
                }.buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text("$ " + cmd).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.text)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(fill: Theme.field)
    }
}
