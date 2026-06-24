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
            // 段落:行距 + 段距(避免默认贴在一起)
            .markdownBlockStyle(\.paragraph) { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: 0, bottom: 8)
            }
            // 标题分级(对齐 web .md:h1 1.3 / h2 1.18 / h3 1.06 / 其余递减)
            .markdownBlockStyle(\.heading1) { c in
                c.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.3)); ForegroundColor(Theme.text) }
                    .relativeLineSpacing(.em(0.1)).markdownMargin(top: 18, bottom: 7)
            }
            .markdownBlockStyle(\.heading2) { c in
                c.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.18)); ForegroundColor(Theme.text) }
                    .relativeLineSpacing(.em(0.1)).markdownMargin(top: 16, bottom: 6)
            }
            .markdownBlockStyle(\.heading3) { c in
                c.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.06)); ForegroundColor(Theme.text) }
                    .relativeLineSpacing(.em(0.1)).markdownMargin(top: 14, bottom: 5)
            }
            .markdownBlockStyle(\.heading4) { c in
                c.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)); ForegroundColor(Theme.text) }
                    .markdownMargin(top: 12, bottom: 4)
            }
            .markdownBlockStyle(\.heading5) { c in
                c.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(0.92)); ForegroundColor(Theme.textSec) }
                    .markdownMargin(top: 12, bottom: 4)
            }
            .markdownBlockStyle(\.heading6) { c in
                c.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(0.85)); ForegroundColor(Theme.textSec) }
                    .markdownMargin(top: 12, bottom: 4)
            }
            // 列表项:项与项之间留点距离
            .markdownBlockStyle(\.listItem) { configuration in
                configuration.label.markdownMargin(top: .em(0.2))
            }
            // 表格:描边 + 隔行底色 + 表头加粗(默认无边框,会糊成一团)
            .markdownBlockStyle(\.table) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: Theme.stroke))
                    .markdownTableBackgroundStyle(.alternatingRows(Theme.card, Theme.field))
                    .markdownMargin(top: 2, bottom: 10)
            }
            .markdownBlockStyle(\.tableCell) { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 { FontWeight(.semibold) }
                        ForegroundColor(Theme.text)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5).padding(.horizontal, 11)
                    .relativeLineSpacing(.em(0.2))
            }
            // 分隔线
            .markdownBlockStyle(\.thematicBreak) {
                Divider().overlay(Theme.stroke).markdownMargin(top: 14, bottom: 14)
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
    private let cardW: CGFloat = 272
    private let pad: CGFloat = 10        // 卡片内边距
    private let maxImgH: CGFloat = 300

    private struct Item {
        let id: String?       // 新:按 id 拉(通道只给 id)
        let image: UIImage?   // 旧:base64 内联
        let name: String
        let kind: String
        let size: String
    }

    var body: some View {
        let p = component.props
        let items = decodeItems(p["images"]?.arrayValue ?? [])
        let text = p.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
        let time = p.string("time")
        let imgW = cardW - pad * 2

        VStack(alignment: .leading, spacing: 9) {
            if let first = items.first { headerRow(first, count: items.count) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let id = item.id {
                    IdAsyncImage(id: id, corner: 10, maxW: imgW, maxH: maxImgH, fill: true)
                        .frame(maxWidth: .infinity)
                } else if let ui = item.image {
                    let s = fitted(ui.size, boxW: imgW)
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: s.width, height: s.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity)   // 窄图水平居中
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 15)).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !time.isEmpty {
                HStack(spacing: 4) {
                    Spacer()
                    Text(time).font(.system(size: 11)).foregroundStyle(Theme.textTer)
                    ZStack(alignment: .leading) {   // Telegram 式双勾
                        Image(systemName: "checkmark")
                        Image(systemName: "checkmark").offset(x: 4)
                    }
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.blue)
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(pad)
        .frame(width: cardW)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Theme.purple.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    /// 顶部文件信息栏:图标 + 「Screenshot · PNG」 + 文件名·大小(id 图没有名/大小时显示张数)。
    private func headerRow(_ item: Item, count: Int) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.cardHi)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "photo")
                    .font(.system(size: 15)).foregroundStyle(Theme.textSec))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind.isEmpty ? "图片" : "Screenshot · \(item.kind)")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                let sub = [item.name, item.size].filter { !$0.isEmpty }.joined(separator: " · ")
                Text(sub.isEmpty ? "\(count) 张" : sub)
                    .font(.system(size: 11)).foregroundStyle(Theme.textSec)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 14)).foregroundStyle(Theme.textSec)
        }
    }

    /// 兼容:{id,ext}(新,按 id 拉)/ {data,name,kind,size}(旧 base64)/ 纯 base64 字符串(更旧)。
    private static let imageCache = NSCache<NSString, UIImage>()

    private func decodeItems(_ arr: [JSONValue]) -> [Item] {
        arr.compactMap { v in
            if let obj = v.objectValue {
                if let id = obj["id"]?.stringValue, !id.isEmpty {
                    return Item(id: id, image: nil, name: obj["name"]?.stringValue ?? "",
                                kind: (obj["ext"]?.stringValue ?? "").uppercased(), size: "")
                }
                if let s = obj["data"]?.stringValue, let ui = cachedDecode(s) {
                    return Item(id: nil, image: ui, name: obj["name"]?.stringValue ?? "",
                                kind: obj["kind"]?.stringValue ?? "", size: obj["size"]?.stringValue ?? "")
                }
                return nil
            }
            if let s = v.stringValue, let ui = cachedDecode(s) {
                return Item(id: nil, image: ui, name: "", kind: "", size: "")
            }
            return nil
        }
    }
    private func cachedDecode(_ s: String) -> UIImage? {
        let key = "\(s.count):\(s.prefix(48))" as NSString
        if let c = Self.imageCache.object(forKey: key) { return c }
        guard let d = Data(base64Encoded: s), let ui = UIImage(data: d) else { return nil }
        Self.imageCache.setObject(ui, forKey: key)
        return ui
    }

    /// 在 boxW × maxImgH 内按宽高比缩放,不裁切不留黑边。
    private func fitted(_ size: CGSize, boxW: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: boxW, height: boxW) }
        let scale = min(boxW / size.width, maxImgH / size.height)
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
