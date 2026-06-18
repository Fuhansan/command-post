import SwiftUI
import AppKit

/// Phase 2 桌面「类终端」:左=会话列表(子任务),右=消息流 + 待响应选项 + 输入框。
/// 直接接 `AgentSessionManager`(stream-json 新架构),与旧 hook 路径并存、互不影响。
struct AgentConsoleRootView: View {
    @ObservedObject var manager: AgentSessionManager
    @ObservedObject var store: SessionStore
    @State private var selectedProject: String?
    @State private var selectedSessionId: String?
    @State private var projectsCollapsed = false
    @State private var draft: String = ""
    @State private var manualTranscript: [String: [AgentMessage]] = [:]   // 手动会话只读对话缓存
    // IDEA 式标签页:会话 + 打开的文件;左栏文件树展开态。
    @State private var openFiles: [URL] = []
    @State private var activeTab: ConsoleTab = .session
    @State private var expandedDirs: Set<String> = []
    @State private var fileCache: [String: String] = [:]   // 文件内容缓存
    private let topInset: CGFloat = 28   // 统一标题栏:各栏内容顶部留出标题栏高度(背景延伸到顶)

    /// 某 cwd 是否属于该项目(等于或在其子目录下)。
    private func inProject(_ cwd: String, _ proj: String) -> Bool {
        cwd == proj || cwd.hasPrefix(proj + "/")
    }
    /// 该项目下的手动(hook)会话。
    private func hookSessions(_ proj: String) -> [SessionEntry] {
        store.sessions.filter { inProject($0.cwd, proj) }
    }
    /// 排除「当前活跃会话(console + 手动)」后的可恢复历史 —— 活着的会话不该出现在历史里。
    private func resumableHistory(_ proj: String) -> [HistoryEntry] {
        var live = Set(store.sessions.map { $0.id })
        for s in manager.sessions { if let cid = s.agentSessionId, !cid.isEmpty { live.insert(cid) } }
        return (manager.historyByProject[proj] ?? []).filter { !live.contains($0.id) }
    }

    // 三栏:项目栏(可收缩) | 会话列表 | 对话 + 底部状态栏。
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if !projectsCollapsed {
                    projectsRail.frame(minWidth: 180, maxWidth: 240)
                }
                sessionColumn.frame(minWidth: 240, maxWidth: 340)
                rightPane.frame(minWidth: 460)
            }
            Divider().overlay(CT.hairline)
            statusBar
        }
        .background(CT.bg)
        .preferredColorScheme(.light)
        .frame(minWidth: 940, minHeight: 580)
        .onChange(of: selectedProject) { _, p in
            // 切项目 → 默认选中该项目第一个会话(没有则清空,右侧显示新建提示)。
            selectedSessionId = p.flatMap { proj in manager.sessions.first { $0.workdir == proj }?.id }
        }
    }

    /// 底部状态栏(视觉):连接状态 + 自动审批 + 编码。
    private var statusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(CT.success).frame(width: 7, height: 7)
                Text("已连接到 Agent").font(.system(size: 11)).foregroundStyle(CT.sub)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(CT.success).frame(width: 6, height: 6)
                Text("自动审批:安全命令").font(.system(size: 11)).foregroundStyle(CT.sub)
            }
            Text("UTF-8").font(.system(size: 11)).foregroundStyle(CT.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(CT.panel)
    }

    // MARK: - 左:项目栏(可收缩)

    private var projectsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("项目").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CT.faint).textCase(.uppercase).tracking(0.5)
                Spacer()
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(CT.sub)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
                    .onTapGesture { openProject() }
                    .help("打开项目")
            }
            .padding(.horizontal, 14).padding(.top, topInset + 8).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(manager.projects, id: \.self) { projectRow($0) }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 200)

            if let proj = selectedProject {
                Divider().overlay(CT.hairline).padding(.vertical, 6)
                HStack(spacing: 4) {
                    Text("目录").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CT.faint).textCase(.uppercase).tracking(0.5)
                    Text((proj as NSString).lastPathComponent)
                        .font(.system(size: 11)).foregroundStyle(CT.sub).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(FileTreeRow.children(of: URL(fileURLWithPath: proj)), id: \.self) { url in
                            FileTreeRow(url: url, depth: 0, expanded: $expandedDirs, onOpen: openFile)
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .background(CT.panel)
    }

    private func projectRow(_ proj: String) -> some View {
        let sel = selectedProject == proj
        let sessions = manager.sessions.filter { $0.workdir == proj }
        let needsResp = sessions.contains { !$0.pending.isEmpty
            || $0.messages.contains { $0.kind == .permission && $0.permState == nil } }
        let working = sessions.contains { $0.status == .working || $0.status == .starting }
        let dot: Color = sessions.isEmpty ? CT.faint : (working ? CT.success : CT.accent)
        return Button { selectedProject = proj } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill").font(.system(size: 12))
                    .foregroundStyle(sel ? CT.accent : CT.faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text((proj as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(CT.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(dot).frame(width: 5, height: 5)
                        Text(sessions.isEmpty ? "未打开会话" : "\(sessions.count) 个会话")
                            .font(.system(size: 11)).foregroundStyle(CT.sub)
                        if needsResp { Text("· 待响应").font(.system(size: 11)).foregroundStyle(.orange) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(sel ? CT.sel : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .contextMenu {
            Button("关闭项目") {
                manager.closeProject(proj)
                if selectedProject == proj { selectedProject = nil }
            }
        }
    }

    // MARK: - 中:会话(任务)列表

    private var sessionColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { projectsCollapsed.toggle() } label: {
                    Image(systemName: projectsCollapsed ? "sidebar.left" : "sidebar.leading")
                        .foregroundStyle(CT.sub)
                }
                .buttonStyle(.plain).focusEffectDisabled().help(projectsCollapsed ? "展开项目栏" : "收起项目栏")
                if let proj = selectedProject {
                    Text((proj as NSString).lastPathComponent)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(CT.text).lineLimit(1)
                } else {
                    Text("选择项目").font(.system(size: 13)).foregroundStyle(CT.sub)
                }
                Spacer()
                if let proj = selectedProject { newSessionMenu(proj) }
            }
            .padding(.horizontal, 12).padding(.top, topInset + 6).padding(.bottom, 10)
            Divider().overlay(CT.hairline)
            if let proj = selectedProject {
                let consoleSessions = manager.sessions.filter { $0.workdir == proj }
                let manualSessions = hookSessions(proj)
                let history = resumableHistory(proj)
                if consoleSessions.isEmpty && manualSessions.isEmpty && history.isEmpty {
                    startInline(proj)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(consoleSessions) { sessionCard($0) }
                            ForEach(manualSessions) { manualCard($0) }
                            ForEach(history, id: \.id) { historyCard($0, proj) }
                        }
                        .padding(10)
                    }
                }
            } else {
                Spacer()
            }
        }
        .background(CT.panel)
        .task(id: selectedProject) {
            if let p = selectedProject { manager.loadHistoryList(for: p) }
        }
    }

    /// 干净白卡外壳(对齐设计图):标题 + 状态行(点+文字+可选标签)+ 右侧相对时间;选中=蓝框浅蓝底。
    private func cleanCard<S: View>(selected: Bool, title: String, time: String,
                                    @ViewBuilder status: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CT.text).lineLimit(1)
            HStack(spacing: 5) {
                status()
                Spacer(minLength: 6)
                Text(time).font(.system(size: 11)).foregroundStyle(CT.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? CT.sel : CT.bg)
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(selected ? CT.accent : CT.hairline, lineWidth: selected ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }

    /// 类型小标签(非默认会话才显示:Codex / 手动 / 历史)。
    private func typeChip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color.opacity(0.13)).clipShape(Capsule())
    }

    /// 相对时间:今天=HH:mm,昨天,N 天前,更早=MM-dd。
    private func relTime(_ d: Date) -> String {
        guard d > .distantPast else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "\(days) 天前" }
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d)
    }

    /// 会话卡(console)。
    private func sessionCard(_ s: AgentSession) -> some View {
        let sel = selectedSessionId == s.id
        let needsResp = !s.pending.isEmpty
            || s.messages.contains { $0.kind == .permission && $0.permState == nil }
        return Button { selectedSessionId = s.id } label: {
            cleanCard(selected: sel, title: s.title, time: relTime(s.startedAt)) {
                Circle().fill(statusColor(s.status)).frame(width: 6, height: 6)
                Text(statusText(s.status)).font(.system(size: 11)).foregroundStyle(CT.sub)
                if s.agent == .codex { typeChip("Codex", CT.indigo) }
                if needsResp { Text("· 待响应").font(.system(size: 11)).foregroundStyle(.orange) }
            }
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .contextMenu {
            Button("结束会话") {
                manager.closeSession(s.id)
                if selectedSessionId == s.id { selectedSessionId = nil }
            }
        }
    }

    /// 手动会话卡:橙色「手动」标签 —— 你在 IDE/终端里自己跑的,只读 + 可唤起窗口。
    private func manualCard(_ e: SessionEntry) -> some View {
        let sel = selectedSessionId == e.id
        let dot: Color = {
            switch e.state {
            case .working: return CT.success
            case .waiting: return CT.orange
            default:       return CT.faint
            }
        }()
        return Button { selectedSessionId = e.id } label: {
            cleanCard(selected: sel, title: manualTitle(e), time: relTime(e.lastActivityAt)) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(e.terminal.displayName).font(.system(size: 11)).foregroundStyle(CT.sub)
                typeChip("手动", CT.orange)
            }
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .contextMenu { Button("唤起 \(e.terminal.displayName)") { raiseWindow(e) } }
    }

    /// 历史会话卡:灰「历史」标签 —— 已结束、可恢复。点击=选中只读浏览(不重启),
    /// 进去后点屏幕才恢复。
    private func historyCard(_ h: HistoryEntry, _ proj: String) -> some View {
        let sel = selectedSessionId == h.id
        return Button { selectedSessionId = h.id } label: {
            cleanCard(selected: sel, title: h.label, time: relTime(h.mtime)) {
                Circle().fill(CT.faint).frame(width: 6, height: 6)
                Text("已结束").font(.system(size: 11)).foregroundStyle(CT.sub)
                typeChip("历史", CT.faint)
            }
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    /// 新建会话菜单:继续最近 / 全新 / 从历史恢复。
    private func newSessionMenu(_ proj: String) -> some View {
        Menu {
            Button { start(proj, continueLast: true) } label: {
                Label("继续最近的会话", systemImage: "clock.arrow.circlepath") }
            Button { start(proj) } label: { Label("全新会话", systemImage: "plus.bubble") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("新建会话").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(CT.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(CT.bg)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(CT.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .task(id: proj) { manager.loadHistoryList(for: proj) }
    }

    /// 项目下还没有会话时,会话栏内联显示「继续最近 / 全新 / 历史」。
    private func startInline(_ proj: String) -> some View {
        let history = resumableHistory(proj)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button { start(proj, continueLast: true) } label: {
                    Label("继续最近的会话", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { start(proj) } label: {
                    Label("全新会话", systemImage: "plus.bubble").frame(maxWidth: .infinity) }
                if !history.isEmpty {
                    Text("从历史恢复:").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(history, id: \.id) { h in
                        Button { start(proj, resume: h.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                                Text(h.label).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain).focusEffectDisabled().padding(6)
                        .background(Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(10)
        }
        .task(id: proj) { manager.loadHistoryList(for: proj) }
    }

    // MARK: - 右:标签页(会话 + 文件,IDEA 式)

    private var rightPane: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(CT.hairline)
            switch activeTab {
            case .session:        conversationPane
            case .file(let url):  fileViewer(url)
            }
        }
        .background(CT.bg)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tabChip(title: "会话", icon: "bubble.left.and.bubble.right",
                        active: activeTab == .session, closable: false,
                        onTap: { activeTab = .session }, onClose: {})
                ForEach(openFiles, id: \.self) { url in
                    tabChip(title: url.lastPathComponent, icon: "doc.text",
                            active: activeTab == .file(url), closable: true,
                            onTap: { activeTab = .file(url) }, onClose: { closeFile(url) })
                }
            }
            .padding(.horizontal, 8).padding(.top, topInset).padding(.bottom, 4)
        }
    }

    private func tabChip(title: String, icon: String, active: Bool, closable: Bool,
                         onTap: @escaping () -> Void, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(active ? CT.accent : CT.sub)
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? CT.text : CT.sub).lineLimit(1)
            if closable {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(CT.faint)
                    .frame(width: 12, height: 12).contentShape(Rectangle()).onTapGesture { onClose() }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(active ? CT.sel : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(active ? CT.accent.opacity(0.4) : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle()).onTapGesture { onTap() }
    }

    private func fileViewer(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(CT.sub)
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(CT.text)
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11)).foregroundStyle(CT.faint).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(CT.bg)
            Divider().overlay(CT.hairline)
            ScrollView([.vertical, .horizontal]) {
                Text(fileCache[url.path] ?? "加载中…")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(CT.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(CT.bg)
        }
        .task(id: url) { await loadFile(url) }
    }

    private func openFile(_ url: URL) {
        if !openFiles.contains(url) { openFiles.append(url) }
        activeTab = .file(url)
    }
    private func closeFile(_ url: URL) {
        openFiles.removeAll { $0 == url }
        if activeTab == .file(url) { activeTab = openFiles.last.map { .file($0) } ?? .session }
    }
    private func loadFile(_ url: URL) async {
        guard fileCache[url.path] == nil else { return }
        let content = await Task.detached(priority: .userInitiated) { () -> String in
            guard let data = try? Data(contentsOf: url) else { return "(无法读取)" }
            if data.count > 2_000_000 { return "(文件过大 \(data.count / 1024)KB,暂不预览)" }
            return String(data: data, encoding: .utf8) ?? "(二进制文件,无法以文本预览)"
        }.value
        fileCache[url.path] = content
    }

    // MARK: - 右:对话

    @ViewBuilder
    private var conversationPane: some View {
        if let sid = selectedSessionId, let s = manager.sessions.first(where: { $0.id == sid }) {
            conversation(s)
        } else if let sid = selectedSessionId, let e = store.sessions.first(where: { $0.id == sid }) {
            manualPane(e)
        } else if let sid = selectedSessionId, let proj = selectedProject,
                  let h = (manager.historyByProject[proj] ?? []).first(where: { $0.id == sid }) {
            historyBrowsePane(h, proj)
        } else {
            VStack(spacing: 10) {
                Image(systemName: selectedProject == nil ? "folder" : "bubble.left.and.bubble.right")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text(selectedProject == nil ? "选择左侧项目,或「打开项目」开始"
                                            : "选择一个会话,或用右上「+」新建")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 手动会话:只读对话 + 唤起 IDE/终端

    /// 手动会话标题:转录首句,没有则提示。
    private func manualTitle(_ e: SessionEntry) -> String {
        if let p = e.transcriptPath, let s = AgentSessionManager.firstUserPrompt(path: p) {
            return String(s.prefix(40))
        }
        return e.promptSummary.map { String($0.prefix(40)) } ?? "手动会话"
    }

    private func manualPane(_ e: SessionEntry) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manualTitle(e)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(e.cwd).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Label("手动", systemImage: "hand.raised.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                Button { raiseWindow(e) } label: {
                    Label("唤起 \(e.terminal.displayName)", systemImage: "arrow.up.forward.app")
                }.controlSize(.small).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .background(CT.bg)
            Divider().overlay(CT.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(manualTranscript[e.id] ?? []) { m in messageRow(m, sid: e.id) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .defaultScrollAnchor(.bottom)
            Divider()
            Text("手动会话:在 \(e.terminal.displayName) 里输入,这里只读。点上方按钮唤起那个窗口。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .task(id: e.id) { await loadManualTranscript(e) }
    }

    /// 唤起手动会话对应的终端/IDE 窗口(沿 ownerPID 父链找到 app 进程并激活)。
    private func raiseWindow(_ e: SessionEntry) {
        let start = e.ownerPID ?? e.terminalPID
        guard let start, start > 1,
              let appPid = ProcessUtils.findTerminal(startPid: start).pid,
              let app = NSRunningApplication(processIdentifier: appPid) else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    /// 后台解析转录 → 只读对话(缓存,避免每次重渲染重读)。
    private func loadManualTranscript(_ e: SessionEntry) async {
        guard manualTranscript[e.id] == nil, let path = e.transcriptPath else { return }
        let parsed = await Task.detached(priority: .userInitiated) {
            AgentSessionManager.parseTranscriptFile(path: path)
        }.value
        let msgs = parsed.enumerated().map { i, t in
            AgentMessage(id: "mh\(i)", role: t.role, kind: t.kind, text: t.text, ord: i)
        }
        manualTranscript[e.id] = msgs
    }

    // MARK: - 历史会话:只读浏览 + 点击屏幕恢复

    private func historyBrowsePane(_ h: HistoryEntry, _ proj: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(CT.text).lineLimit(1)
                    Text("历史会话 · 只读").font(.system(size: 11)).foregroundStyle(CT.sub)
                }
                Spacer()
                Label("只读", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(CT.faint)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .background(CT.bg)
            Divider().overlay(CT.hairline)
            ZStack(alignment: .bottom) {
                // 只读浏览:滚轮正常滚动看历史;点空白处恢复(不再用覆盖层挡滚动)。
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(manualTranscript[h.id] ?? []) { m in messageRow(m, sid: h.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .padding(.bottom, 44)   // 给底部浮动按钮留位
                }
                .defaultScrollAnchor(.bottom)
                .background(CT.panel.opacity(0.45))   // 淡色底示意只读锁定
                .contentShape(Rectangle())
                .onTapGesture { start(proj, resume: h.id) }
                // 浮动「恢复会话」按钮(可点)
                Button { start(proj, resume: h.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open.fill").font(.system(size: 11))
                        Text("点击恢复会话").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(CT.accent).clipShape(Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .padding(.bottom, 16)
            }
        }
        .task(id: h.id) { await loadHistoryTranscript(h, proj) }
    }

    /// 后台解析历史转录 → 只读对话(复用 manualTranscript 缓存,按 id 键)。
    private func loadHistoryTranscript(_ h: HistoryEntry, _ proj: String) async {
        guard manualTranscript[h.id] == nil else { return }
        let path = AgentSessionManager.historyTranscriptPath(workdir: proj, id: h.id)
        let parsed = await Task.detached(priority: .userInitiated) {
            AgentSessionManager.parseTranscriptFile(path: path)
        }.value
        manualTranscript[h.id] = parsed.enumerated().map { i, t in
            AgentMessage(id: "mh\(i)", role: t.role, kind: t.kind, text: t.text, ord: i)
        }
    }

    private func start(_ proj: String, resume: String? = nil, continueLast: Bool = false) {
        // 新建后立即选中它,右侧切到该会话对话。
        selectedSessionId = manager.newSession(agent: .claude, workdir: proj,
                                               resume: resume, continueLast: continueLast)
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
            .buttonStyle(.plain).focusEffectDisabled().help("点击复制完整 session id:\(sid)")
        } else {
            Text("id 待生成").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func conversation(_ s: AgentSession) -> some View {
        VStack(spacing: 0) {
            // 顶栏:工具图标 + 标题 + 路径 + 书签/复制/更多
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(CT.accent)
                Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(CT.text).lineLimit(1)
                Text(s.workdir).font(.system(size: 11)).foregroundStyle(CT.sub)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                headerIcon("bookmark") {}
                headerIcon("doc.on.doc") {
                    if let id = s.agentSessionId {
                        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(id, forType: .string)
                    }
                }
                Menu {
                    Button("结束会话") { manager.closeSession(s.id); selectedSessionId = nil }
                } label: { Image(systemName: "ellipsis").foregroundStyle(CT.sub) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .background(CT.bg)
            Divider().overlay(CT.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(s.messages) { m in messageRow(m, sid: s.id) }
                        ForEach(s.pending) { req in pendingCard(sid: s.id, req: req) }
                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .background(CT.bg)
                .defaultScrollAnchor(.bottom)
                .onChange(of: s.messages.count) { _, _ in proxy.scrollTo("BOTTOM", anchor: .bottom) }
                .onChange(of: s.pending.count) { _, _ in proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            Divider().overlay(CT.hairline)
            // 输入栏
            HStack(spacing: 10) {
                TextField("输入指令(支持 / 命令、@ 资源、↑ 历史)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...6)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(CT.panel)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(CT.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onSubmit { submit(s.id) }
                let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { submit(s.id) } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 14)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(empty ? CT.faint : CT.accent).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).focusEffectDisabled().keyboardShortcut(.return, modifiers: .command).disabled(empty)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(CT.bg)
        }
    }

    private func headerIcon(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13)).foregroundStyle(CT.sub)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    @ViewBuilder
    private func messageRow(_ m: AgentMessage, sid: String) -> some View {
        switch m.kind {
        case .text where m.role == "user":
            HStack { Spacer(minLength: 60)
                Text(m.text).font(.system(size: 13)).foregroundStyle(CT.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(CT.userBubble).clipShape(RoundedRectangle(cornerRadius: 12)) }
        case .text:
            HStack(alignment: .top, spacing: 9) {
                avatar(m.role == "system" ? "exclamationmark.triangle.fill" : "sparkle",
                       m.role == "system" ? .orange : CT.accent)
                Text(m.text).font(.system(size: 13)).foregroundStyle(CT.text).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        case .tool:
            toolCard(m.text)
        case .file:
            HStack(alignment: .top, spacing: 9) {
                avatar("doc.text.fill", CT.success)
                Text(m.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(CT.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CT.toolBg).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case .permission:
            permissionCard(m, sid: sid)
        }
    }

    private func avatar(_ system: String, _ color: Color) -> some View {
        Image(systemName: system).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 22, height: 22).background(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 工具卡:工具名 + 命令代码块(m.text = "Bash: <命令>")。
    private func toolCard(_ text: String) -> some View {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let name = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "工具"
        let cmd = parts.count > 1 ? parts[1] : ""
        return HStack(alignment: .top, spacing: 9) {
            avatar("terminal.fill", CT.text.opacity(0.75))
            VStack(alignment: .leading, spacing: 7) {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(CT.text)
                if !cmd.isEmpty {
                    Text(cmd).font(.system(size: 12, design: .monospaced)).foregroundStyle(CT.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(CT.toolBg).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(CT.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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

/// 右侧标签页:会话 或 某个文件。
enum ConsoleTab: Hashable { case session; case file(URL) }

/// 控制台浅色配色(对齐高保真设计)。
private enum CT {
    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    static let bg       = hex(0xFFFFFF)   // 对话区底
    static let panel    = hex(0xF7F8FA)   // 左/中栏底
    static let accent   = hex(0x3B82F6)   // 主蓝
    static let text     = hex(0x1F2328)   // 主文字
    static let sub      = hex(0x6B7280)   // 次文字
    static let faint    = hex(0x9AA1AC)   // 更淡
    static let hairline = Color.black.opacity(0.08)
    static let sel      = hex(0x3B82F6).opacity(0.10)   // 选中底
    static let userBubble = hex(0xEAF1FE)  // 用户气泡
    static let toolBg   = hex(0xF3F4F6)   // 代码/工具底
    static let success  = hex(0x16A34A)   // 绿
    static let indigo   = hex(0x7C5CD6)   // Codex 会话类型色
    static let orange   = hex(0xE8810C)   // 手动会话类型色
}

/// 文件树一行(递归):文件夹可展开,文件点击 → onOpen。用 AnyView 断递归类型。
struct FileTreeRow: View {
    let url: URL
    let depth: Int
    @Binding var expanded: Set<String>
    let onOpen: (URL) -> Void

    private var isDir: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    private var isOpen: Bool { expanded.contains(url.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isDir {
                    if isOpen { expanded.remove(url.path) } else { expanded.insert(url.path) }
                } else { onOpen(url) }
            } label: {
                HStack(spacing: 5) {
                    if isDir {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(CT.faint).frame(width: 9)
                    } else {
                        Color.clear.frame(width: 9, height: 1)
                    }
                    Image(systemName: isDir ? "folder.fill" : "doc")
                        .font(.system(size: 11)).foregroundStyle(isDir ? CT.accent.opacity(0.85) : CT.sub)
                    Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(CT.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 12 + 4).padding(.vertical, 3).padding(.trailing, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()

            if isDir && isOpen {
                ForEach(FileTreeRow.children(of: url), id: \.self) { child in
                    AnyView(FileTreeRow(url: child, depth: depth + 1, expanded: $expanded, onOpen: onOpen))
                }
            }
        }
    }

    /// 目录内容:文件夹在前,按名称自然排序;跳过隐藏文件。
    static func children(of dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}
