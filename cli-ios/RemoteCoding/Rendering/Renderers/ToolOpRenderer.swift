import SwiftUI

/// 动作 kind → 中文 verb / 颜色 / SF 图标(对齐桌面端配色)。
func opMeta(_ kind: String, label: String?) -> (verb: String, color: Color, icon: String) {
    switch kind {
    case "read":  return ("读取", Theme.textSec, "doc.text")
    case "edit":  return ("编辑", Theme.orange, "pencil")
    case "write": return ("新建", Theme.green, "doc.badge.plus")
    case "bash":  return ("命令", Theme.purple, "terminal")
    default:      return (label ?? "工具", Theme.textSec, "wrench.and.screwdriver")
    }
}

/// 单条动作行内容(verb 药丸 + 文件名 + 目录 + +增/−删,点开看 diff/终端)。
/// 不带卡片/竖轨——`ToolOpRenderer`(单个)包卡片,`ToolTimelineRenderer`(多个)在左侧加竖轨。
struct OpRowView: View {
    let p: JSONValue
    @State private var expanded = false

    var body: some View {
        let kind = p.string("kind")
        let m = opMeta(kind, label: p["label"]?.stringValue)
        let file = p.string("file")
        let dir = p.string("dir")
        let sameFile = p["sameFile"]?.boolValue ?? false
        let add = p["add"]?.intValue
        let del = p["del"]?.intValue
        let command = p["command"]?.stringValue
        let output = (p["output"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
        let diff = p["diff"]?.arrayValue ?? []
        let isBash = kind == "bash"
        let hasDiff = kind == "edit" && !diff.isEmpty
        let hasOut = isBash && command != nil
        let expandable = hasDiff || hasOut

        VStack(alignment: .leading, spacing: 0) {
            Button { if expandable { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } } label: {
                HStack(spacing: 8) {
                    Text(m.verb).font(.system(size: 11, weight: .semibold)).foregroundStyle(m.color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(m.color.opacity(0.16)).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(file).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    if sameFile {
                        Text("同一文件").font(.system(size: 11)).foregroundStyle(Theme.textTer).lineLimit(1)
                    } else if !dir.isEmpty {
                        Text(dir).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTer).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 6)
                    if let add, add > 0 { Text("+\(add)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.green) }
                    if let del, del > 0 { Text("−\(del)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.coral) }
                    if expandable {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTer)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded && hasOut {
                VStack(alignment: .leading, spacing: 2) {
                    Text("$ " + (command ?? "")).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.green).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(output.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textSec).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 8)
            }
            if expanded && hasDiff {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.enumerated()), id: \.offset) { _, d in
                        let k = d["k"]?.stringValue ?? "ctx"
                        let st = Self.diffStyle(k)
                        Text(st.sign + (d["t"]?.stringValue ?? "")).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(st.fg).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 1).background(st.bg)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 8)
            }
        }
    }

    static func diffStyle(_ k: String) -> (fg: Color, bg: Color, sign: String) {
        switch k {
        case "add": return (Theme.green, Theme.green.opacity(0.12), "+ ")
        case "del": return (Theme.coral, Theme.coral.opacity(0.12), "− ")
        default:    return (Theme.textSec, .clear, "  ")
        }
    }
}

/// 单个动作行(包卡片)。
struct ToolOpRenderer: View {
    let component: Component
    var body: some View {
        OpRowView(p: component.props)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }
}

/// 连续动作 → 带竖轨 + 节点图标的时间线(对齐桌面端)。props.ops = [op props…]。
/// 竖轨用 overlay 贴着内容高度画(由内容决定行高),避免 maxHeight 把行撑开导致间距过大。
struct ToolTimelineRenderer: View {
    let component: Component
    var body: some View {
        let ops = component.props["ops"]?.arrayValue ?? []
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ops.enumerated()), id: \.offset) { i, op in
                let m = opMeta(op.string("kind"), label: op["label"]?.stringValue)
                let last = i == ops.count - 1
                OpRowView(p: op)
                    .padding(.leading, 32)
                    .padding(.bottom, last ? 0 : 10)
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .top) {
                            // 竖线:从节点中心往下贯穿到本行底部(含行间距),连到下一个节点
                            if !last {
                                Rectangle().fill(Theme.stroke).frame(width: 1.5)
                                    .frame(maxHeight: .infinity).padding(.top, 11)
                            }
                            RoundedRectangle(cornerRadius: 6).fill(m.color.opacity(0.18))
                                .frame(width: 22, height: 22)
                                .overlay(Image(systemName: m.icon).font(.system(size: 11, weight: .medium)).foregroundStyle(m.color))
                        }
                        .frame(width: 22)
                    }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
