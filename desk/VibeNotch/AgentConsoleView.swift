import SwiftUI
import AppKit

/// Phase 2 桌面「类终端」:左=会话列表(子任务),右=消息流 + 待响应选项 + 输入框。
/// 直接接 `AgentSessionManager`(stream-json 新架构),与旧 hook 路径并存、互不影响。
struct AgentConsoleRootView: View {
    @ObservedObject var manager: AgentSessionManager
    @State private var selectedProject: String?
    @State private var draft: String = ""

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 200, maxWidth: 270)
            console.frame(minWidth: 520)
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    // MARK: - 左:项目列表

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button(action: openProject) {
                Label("打开项目", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(8)

            List(selection: $selectedProject) {
                ForEach(manager.projects, id: \.self) { proj in
                    projectRow(proj).tag(proj)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func projectRow(_ proj: String) -> some View {
        let s = manager.activeSession(for: proj)
        let needsResp = s.map { !$0.pending.isEmpty
            || $0.messages.contains { $0.kind == .permission && $0.permState == nil } } ?? false
        return VStack(alignment: .leading, spacing: 2) {
            Text((proj as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
            HStack(spacing: 4) {
                if let s {
                    Circle().fill(statusColor(s.status)).frame(width: 7, height: 7)
                    Text(statusText(s.status)).font(.system(size: 11)).foregroundStyle(.secondary)
                    if needsResp { Text("● 待响应").font(.system(size: 11)).foregroundStyle(.orange) }
                } else {
                    Text("未打开会话").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("关闭项目") {
                manager.closeProject(proj)
                if selectedProject == proj { selectedProject = nil }
            }
        }
    }

    // MARK: - 右:会话对话 / 开始面板

    @ViewBuilder
    private var console: some View {
        if let proj = selectedProject {
            if let s = manager.activeSession(for: proj) {
                conversation(s)
            } else {
                startPanel(proj)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("选择左侧项目,或「打开项目」开始").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 项目无活跃会话 → 选择:继续最近(--continue)/ 全新 / 从历史恢复(--resume)。
    /// 历史列表走 manager 的项目级缓存,异步加载,切项目秒开不卡。
    private func startPanel(_ proj: String) -> some View {
        let history = manager.historyByProject[proj] ?? []
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text((proj as NSString).lastPathComponent).font(.system(size: 15, weight: .semibold))
                Text(proj).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { start(proj, continueLast: true) } label: {
                    Label("继续最近的会话", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.borderedProminent)
                Button { start(proj) } label: { Label("全新会话", systemImage: "plus.bubble") }
            }
            if !history.isEmpty {
                Text("从历史恢复:").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(history, id: \.id) { h in
                            Button { start(proj, resume: h.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                                    Text(h.label).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain).padding(6)
                            .background(Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: proj) { manager.loadHistoryList(for: proj) }
    }

    private func start(_ proj: String, resume: String? = nil, continueLast: Bool = false) {
        manager.newSession(agent: .claude, workdir: proj, resume: resume, continueLast: continueLast)
        // 活跃会话出现后 console 自动切到对话(由 manager.activeSession 驱动)
    }

    /// 顶栏 session_id 徽标:显示短 id,点一下复制完整 id(方便排查时直接发出来)。
    @ViewBuilder
    private func sessionIdBadge(_ s: AgentSession) -> some View {
        if let sid = s.agentSessionId, !sid.isEmpty {
            Button {
                let pb = NSPasteboard.general; pb.clearContents(); pb.setString(sid, forType: .string)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "number").font(.system(size: 9))
                    Text(sid.prefix(8)).font(.system(size: 11, design: .monospaced))
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.gray.opacity(0.12)).clipShape(Capsule())
            }
            .buttonStyle(.plain).help("点击复制完整 session id:\(sid)")
        } else {
            Text("id 待生成").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func conversation(_ s: AgentSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(s.title).font(.system(size: 13, weight: .semibold))
                Text(s.workdir).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                sessionIdBadge(s)
                Button("结束会话") { manager.closeSession(s.id) }.controlSize(.small)
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(s.messages) { m in messageRow(m, sid: s.id) }
                        ForEach(s.pending) { req in pendingCard(sid: s.id, req: req) }
                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: s.messages.count) { _, _ in proxy.scrollTo("BOTTOM", anchor: .bottom) }
                .onChange(of: s.pending.count) { _, _ in proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("输入指令…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5).onSubmit { submit(s.id) }
                Button(action: { submit(s.id) }) { Image(systemName: "paperplane.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func messageRow(_ m: AgentMessage, sid: String) -> some View {
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
        case .permission:
            permissionCard(m, sid: sid)
        }
    }

    /// 审批卡:就长在命令位置。待处理=命令+允许/拒绝;处理后原地变命令+✓已允许/✕已拒绝。
    private func permissionCard(_ m: AgentMessage, sid: String) -> some View {
        let resolved = m.permState
        let accent: Color = resolved == nil ? .orange : (resolved == "allow" ? .green : .red)
        return VStack(alignment: .leading, spacing: 8) {
            Label("需要你处理", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            Text(m.text).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Color.black.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 6))
            if resolved == nil {
                HStack(spacing: 8) {
                    Button("拒绝") { manager.respond(sid, requestId: m.permReqId ?? "", choose: ["deny"]) }
                    Button("允许") { manager.respond(sid, requestId: m.permReqId ?? "", choose: ["allow"]) }
                        .buttonStyle(.borderedProminent)
                }.controlSize(.small)
            } else {
                Label(resolved == "allow" ? "✓ 已允许" : "✕ 已拒绝",
                      systemImage: resolved == "allow" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            }
        }
        .padding(10)
        .background(accent.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 10))
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

    private func submit(_ sid: String) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        manager.send(sid, text: t)
        draft = ""
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开项目"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manager.openProject(url.path)
        selectedProject = url.path
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
