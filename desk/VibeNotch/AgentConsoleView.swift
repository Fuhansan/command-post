import SwiftUI
import AppKit

/// Phase 2 桌面「类终端」:左=会话列表(子任务),右=消息流 + 待响应选项 + 输入框。
/// 直接接 `AgentSessionManager`(stream-json 新架构),与旧 hook 路径并存、互不影响。
struct AgentConsoleRootView: View {
    @ObservedObject var manager: AgentSessionManager
    @State private var selected: String?
    @State private var draft: String = ""

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, maxWidth: 240)
            console.frame(minWidth: 520)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: - 左:会话列表

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button(action: newSession) {
                Label("新建会话", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(8)

            List(selection: $selected) {
                ForEach(manager.sessions) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(statusColor(s.status)).frame(width: 7, height: 7)
                            Text(statusText(s.status)).font(.system(size: 11)).foregroundStyle(.secondary)
                            if !s.pending.isEmpty {
                                Text("● 待响应").font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(s.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - 右:类终端

    @ViewBuilder
    private var console: some View {
        if let sid = selected, let s = manager.sessions.first(where: { $0.id == sid }) {
            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text(s.title).font(.system(size: 13, weight: .semibold))
                    Text(s.workdir).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("结束") { manager.closeSession(sid); selected = nil }
                        .controlSize(.small)
                }
                .padding(8)
                Divider()

                // 消息流
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(s.messages) { m in messageRow(m) }
                            // 待响应:权限/选项合一,渲染成按钮
                            ForEach(s.pending) { req in pendingCard(sid: sid, req: req) }
                            Color.clear.frame(height: 1).id("BOTTOM")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .onChange(of: s.messages.count) { _, _ in proxy.scrollTo("BOTTOM", anchor: .bottom) }
                    .onChange(of: s.pending.count) { _, _ in proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
                Divider()

                // 输入框
                HStack(spacing: 8) {
                    TextField("输入指令…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .onSubmit(submit)
                    Button(action: submit) { Image(systemName: "paperplane.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(8)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("选择左侧会话,或「新建会话」开始").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func messageRow(_ m: AgentMessage) -> some View {
        switch m.kind {
        case .text where m.role == "user":
            HStack { Spacer(minLength: 60)
                Text(m.text).padding(8).background(Color.blue.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 10)) }
        case .text:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: m.role == "system" ? "exclamationmark.triangle" : "sparkle")
                    .foregroundStyle(m.role == "system" ? .orange : .purple)
                Text(m.text).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        case .tool:
            Label(m.text, systemImage: "terminal").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary).padding(.leading, 4)
        case .file:
            Label(m.text, systemImage: "doc.text").font(.system(size: 12))
                .foregroundStyle(.green).padding(.leading, 4)
        }
    }

    private func pendingCard(sid: String, req: PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(req.title).font(.system(size: 13, weight: .semibold))
            if let d = req.detail { Text(d).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                ForEach(req.options) { opt in
                    Button(opt.label) { manager.respond(sid, requestId: req.id, choose: [opt.id]) }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 动作

    private func submit() {
        guard let sid = selected else { return }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        manager.send(sid, text: t)
        draft = ""
    }

    private func newSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "在此目录开会话"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selected = manager.newSession(agent: .claude, workdir: url.path)
    }

    private func statusColor(_ s: SessionStatus) -> Color {
        switch s {
        case .working: return .blue
        case .needsResponse: return .orange
        case .waitingInput, .idle: return .gray
        case .done: return .green
        case .error: return .red
        case .starting: return .yellow
        }
    }
    private func statusText(_ s: SessionStatus) -> String {
        switch s {
        case .starting: return "启动中"; case .idle: return "就绪"; case .working: return "运行中"
        case .waitingInput: return "挂起"; case .needsResponse: return "待响应"
        case .done: return "结束"; case .error: return "错误"
        }
    }
}
