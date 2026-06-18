import Foundation
import Combine

// MARK: - 统一会话模型(上层唯一依赖,agent 无关)

/// 一条会话里的一条消息(统一)。Phase 1 先支撑文本/工具/文件三类,渲染细节 Phase 3 再丰富。
struct AgentMessage: Identifiable, Equatable {
    enum Kind: String { case text, tool, file, permission }
    let id: String
    var role: String          // user / assistant / system
    var kind: Kind
    var text: String          // permission 时 = 命令/操作详情
    var ord: Int              // 逻辑顺序号(到达递增)
    /// permission 卡的处理结果:nil=待处理(显示允许/拒绝按钮);"allow"/"deny"=已处理(显示徽标)。
    var permState: String? = nil
    var permReqId: String? = nil   // 关联 driver 的权限请求 id,回写时用
}

/// 一个会话(统一模型)。SessionManager 维护,上层(桌面 UI / RelayAgent / 手机)消费。
struct AgentSession: Identifiable, Equatable {
    let id: String                    // VibeNotch 内部会话 id
    let agent: AgentKind
    var workdir: String
    var title: String
    var status: SessionStatus
    var messages: [AgentMessage]
    var pending: [PendingRequest]     // 待你响应(权限/选项合一)
    var agentSessionId: String?       // agent 报告的 session_id(供 resume)
    var startedAt: Date = Date()      // 会话开始时间(列表展示相对时间)

    static func == (l: AgentSession, r: AgentSession) -> Bool {
        l.id == r.id && l.status == r.status && l.messages == r.messages &&
        l.pending == r.pending && l.title == r.title && l.agentSessionId == r.agentSessionId
    }
}

/// 历史会话条目(供「从历史恢复」列表)。
struct HistoryEntry: Identifiable, Equatable {
    let id: String       // claude session_id(= 转录文件名)
    let label: String    // 首句,做标签
    var mtime: Date = .distantPast   // 转录最后修改时间(列表展示相对时间)
}

// MARK: - 会话管理器

/// 多会话宿主:每会话一个 `AgentDriver` 子进程,消费其事件流更新统一模型。
/// 取代旧的「hook 采集 + 反查 pid」——会话由它主动 spawn,天然隔离、可控。
@MainActor
final class AgentSessionManager: ObservableObject {

    @Published private(set) var sessions: [AgentSession] = []

    private struct Managed {
        let driver: AgentDriver
        var consumeTask: Task<Void, Never>?
    }
    private var managed: [String: Managed] = [:]
    private var ordCounter = 0

    /// 历史列表缓存(按项目)。解析转录较重,缓存避免每次切项目/重渲染都重算。
    @Published private(set) var historyByProject: [String: [HistoryEntry]] = [:]
    private var historyLoading: Set<String> = []

    /// 异步加载某项目历史(off-main 解析,回主线程填缓存)。已缓存且非强制则跳过,保证切项目秒开。
    func loadHistoryList(for workdir: String, force: Bool = false) {
        if !force && historyByProject[workdir] != nil { return }
        if historyLoading.contains(workdir) { return }
        historyLoading.insert(workdir)
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = Self.listHistory(workdir: workdir)
            await MainActor.run {
                self?.historyByProject[workdir] = items
                self?.historyLoading.remove(workdir)
            }
        }
    }
    /// 让某项目历史失效(会话结束/新建会改变转录),下次访问重算。
    private func invalidateHistory(_ workdir: String) { historyByProject[workdir] = nil }

    /// 已打开的项目(工作目录)列表,新→旧,持久化。左侧以项目为中心。
    @Published private(set) var projects: [String] = []
    private static let projectsURL = URL(fileURLWithPath:
        NSString(string: "~/.vibenotch/console-projects.json").expandingTildeInPath)

    /// 打开一个项目(加入左侧列表,置顶)。不自动开会话——点项目时再选 continue/history/fresh。
    func openProject(_ workdir: String) {
        projects.removeAll { $0 == workdir }
        projects.insert(workdir, at: 0)
        persistProjects()
    }
    /// 关闭项目:连同它的活跃会话一起结束,并移出列表。
    func closeProject(_ workdir: String) {
        for s in sessions where s.workdir == workdir { closeSession(s.id) }
        projects.removeAll { $0 == workdir }
        persistProjects()
    }
    /// 某项目当前的活跃会话(若有)。
    func activeSession(for workdir: String) -> AgentSession? {
        sessions.first { $0.workdir == workdir }
    }
    private func persistProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: Self.projectsURL, options: .atomic)
        }
    }
    private func loadProjects() {
        if let data = try? Data(contentsOf: Self.projectsURL),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            projects = arr
        }
    }

    /// driver 工厂:按 agent 类型造对应适配器(codex 后续加分支)。
    private func makeDriver(_ agent: AgentKind) -> AgentDriver {
        switch agent {
        case .claude: return ClaudeStreamJSONDriver()
        case .codex:  return ClaudeStreamJSONDriver()   // TODO: CodexDriver(Phase 后续)
        }
    }

    /// 新建会话:spawn driver 子进程,开始消费事件。返回会话 id。
    /// resume 非空 → claude --resume <id> 恢复既有会话;restoreId 非空 → 沿用旧的 VibeNotch
    /// 会话 id(崩溃恢复时保持 id 稳定,手机端不混乱)。
    @discardableResult
    func newSession(agent: AgentKind, workdir: String, resume: String? = nil,
                    continueLast: Bool = false, restoreId: String? = nil) -> String {
        let sid = restoreId ?? "s_\(Int(Date().timeIntervalSince1970 * 1000))_\(sessions.count)"
        vlog("console new: workdir=\((workdir as NSString).lastPathComponent) resume=\(resume ?? "-") cont=\(continueLast) sid=\(sid)")
        if !projects.contains(workdir) { projects.append(workdir); persistProjects() }
        let driver = makeDriver(agent)
        let title = (workdir as NSString).lastPathComponent
        sessions.append(AgentSession(id: sid, agent: agent, workdir: workdir, title: title,
                                     status: .starting, messages: [], pending: [], agentSessionId: resume))
        var m = Managed(driver: driver, consumeTask: nil)
        m.consumeTask = Task { [weak self] in
            for await ev in driver.events {
                await self?.apply(ev, to: sid)
            }
        }
        managed[sid] = m
        Task {
            do { try await driver.start(workdir: workdir, resume: resume, continueLast: continueLast) }
            catch { await self.apply(.error("启动失败: \(error)"), to: sid) }
        }
        // 历史回填:不依赖 init —— claude 在 stream-json 下要等首条输入才吐 init,
        // 但恢复/继续时我们已知 id(resume),或可取本目录最近转录(continue),直接读历史显示。
        let historyId = resume ?? (continueLast ? Self.listHistory(workdir: workdir, limit: 1).first?.id : nil)
        if let historyId { loadHistory(sessionId: historyId, into: sid) }
        return sid
    }

    // MARK: - 恢复:启动只恢复项目列表;会话由用户在项目里选 continue/resume 再开

    func restoreSessions() {
        loadProjects()
    }

    /// 后台读 claude 转录(~/.claude/projects/<目录>/<id>.jsonl)重建历史消息,回主线程填入。
    /// resume/continue 不重放历史,所以靠这个把之前的对话显示回来。
    private func loadHistory(sessionId: String, into sid: String, attempt: Int = 0) {
        Task.detached(priority: .utility) { [weak self] in
            let found = Self.findTranscript(sessionId: sessionId)
            let items = Self.parseTranscript(sessionId: sessionId)
            let shouldRetry: Bool = await MainActor.run {
                guard let self else { return false }
                // 会话已被关 / 已注入过历史 → 停。
                guard let s = self.sessions.first(where: { $0.id == sid }), s.messages.isEmpty else { return false }
                if !items.isEmpty {
                    vlog("console history: sid=\(sid) id=\(sessionId.prefix(8)) 注入 \(items.count) 条")
                    self.injectHistory(items, into: sid)
                    return false
                }
                // 读到 0 条:转录可能还没写完/还没出现(claude 边聊边写)→ 重试几次。
                vlog("console history: sid=\(sid) id=\(sessionId.prefix(8)) 转录=\(found ?? "无") 条数=0 attempt=\(attempt)")
                return attempt < 6
            }
            guard shouldRetry else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.loadHistory(sessionId: sessionId, into: sid, attempt: attempt + 1)
        }
    }

    private func injectHistory(_ items: [(role: String, kind: AgentMessage.Kind, text: String)], into sid: String) {
        mutate(sid) { s in
            guard s.messages.isEmpty else { vlog("console history: sid=\(sid) 已有消息,跳过注入"); return }
            s.messages = items.enumerated().map { i, it in
                AgentMessage(id: "h\(i)", role: it.role, kind: it.kind, text: it.text, ord: i)
            }
        }
        ordCounter = max(ordCounter, items.count + 1)   // 后续新消息排在历史之后
    }

    /// 解析转录 JSONL → (role, kind, 文本)。user 文本 / assistant 文本 / assistant 工具调用。
    nonisolated private static func parseTranscript(sessionId: String)
        -> [(role: String, kind: AgentMessage.Kind, text: String)] {
        guard let path = findTranscript(sessionId: sessionId) else { return [] }
        return parseTranscriptFile(path: path)
    }

    /// 按文件路径解析转录(供 RelayAgent 给 hook 会话做历史回填复用)。
    nonisolated static func parseTranscriptFile(path: String)
        -> [(role: String, kind: AgentMessage.Kind, text: String)] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [(String, AgentMessage.Kind, String)] = []
        for line in content.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = o["type"] as? String,
                  let msg = o["message"] as? [String: Any] else { continue }
            if type == "user" {
                if let s = msg["content"] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(("user", .text, s))
                } else if let blocks = msg["content"] as? [[String: Any]] {
                    for b in blocks where (b["type"] as? String) == "text" {
                        if let t = b["text"] as? String, !t.isEmpty { out.append(("user", .text, t)) }
                    }
                }
            } else if type == "assistant", let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.isEmpty { out.append(("assistant", .text, t)) }
                    case "tool_use":
                        let name = b["name"] as? String ?? "?"
                        let input = b["input"] as? [String: Any] ?? [:]
                        let sm = (input["command"] ?? input["file_path"] ?? input["path"]
                                  ?? input["pattern"] ?? input["url"]) as? String ?? ""
                        out.append(("assistant", .tool, "\(name): \(sm)"))
                    default: break
                    }
                }
            }
        }
        return out
    }

    /// 列出某工作目录下的历史会话(供「新建时从历史恢复」选择)。新→旧。
    nonisolated static func listHistory(workdir: String, limit: Int = 30) -> [HistoryEntry] {
        let enc = String(workdir.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = NSString(string: "~/.claude/projects/\(enc)").expandingTildeInPath
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        // 先按 mtime 排序、截断,再只对前 limit 个解析首句(避免解析全部转录)。
        var metas: [(id: String, full: String, mtime: Date)] = []
        for f in files where f.hasSuffix(".jsonl") {
            let full = "\(dir)/\(f)"
            let mtime = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date ?? .distantPast
            metas.append((String(f.dropLast(6)), full, mtime))
        }
        return metas.sorted { $0.mtime > $1.mtime }.prefix(limit).map {
            HistoryEntry(id: $0.id,
                         label: firstUserPrompt(path: $0.full).map { String($0.prefix(48)) } ?? $0.id,
                         mtime: $0.mtime)
        }
    }

    /// 读转录里第一条用户文本(历史列表的标签 / 会话标题)。只读文件头部 —— 首句几乎都在最前,避免读取大转录全文。
    nonisolated static func firstUserPrompt(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 256 * 1024)) ?? Data()
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["type"] as? String) == "user", let m = o["message"] as? [String: Any] else { continue }
            if let s = (m["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
            if let blocks = m["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "text" {
                    if let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        return t
                    }
                }
            }
        }
        return nil
    }

    /// 按 sessionId 在 ~/.claude/projects 下递归找转录文件(不必算目录编码)。
    nonisolated private static func findTranscript(sessionId: String) -> String? {
        let base = NSString(string: "~/.claude/projects").expandingTildeInPath
        guard let en = FileManager.default.enumerator(atPath: base) else { return nil }
        for case let f as String in en where f.hasSuffix("\(sessionId).jsonl") {
            return "\(base)/\(f)"
        }
        return nil
    }

    func send(_ sid: String, text: String, imagePaths: [String] = []) {
        guard let d = managed[sid]?.driver else { return }
        // 本地立即回显用户消息
        mutate(sid) { s in s.messages.append(self.userEcho(text)) }
        d.send(UserInput(text: text, imagePaths: imagePaths))
    }

    func respond(_ sid: String, requestId: String, choose: [String]) {
        guard let d = managed[sid]?.driver else { return }
        let allow = choose.contains("allow")
        mutate(sid) { s in
            // 权限审批卡(消息):就地标记结果(命令+✓已允许/✕已拒绝),不删,留在对话里。
            if let i = s.messages.firstIndex(where: { $0.kind == .permission && $0.permReqId == requestId }) {
                s.messages[i].permState = allow ? "allow" : "deny"
            }
            // 选择题(pending):留一条「已选择」记录,再移除待决卡。
            if let req = s.pending.first(where: { $0.id == requestId }),
               req.kind == .choice || req.kind == .planConfirm {
                let picked = req.options.filter { choose.contains($0.id) }.map(\.label).joined(separator: "、")
                s.messages.append(AgentMessage(id: "resolved_\(requestId)", role: "assistant", kind: .text,
                    text: "✓ 已选择:" + (picked.isEmpty ? choose.joined(separator: ",") : picked), ord: self.nextOrd()))
            }
            s.pending.removeAll { $0.id == requestId }
        }
        d.respond(to: requestId, choose: choose)
    }

    func interrupt(_ sid: String) { managed[sid]?.driver.interrupt() }

    /// 手机回传:批准/拒绝该会话当前的权限待决项。
    func respondPermission(_ sid: String, allow: Bool) {
        // 权限审批卡是 messages 里一条 .permission 消息(permState==nil 为待处理)。
        guard let s = sessions.first(where: { $0.id == sid }),
              let m = s.messages.first(where: { $0.kind == .permission && $0.permState == nil }),
              let reqId = m.permReqId else { return }
        respond(sid, requestId: reqId, choose: [allow ? "allow" : "deny"])
    }

    /// 手机回传:回答该会话当前的选择题待决项(optionIndex 为 1 起的选项序号)。
    func respondChoice(_ sid: String, optionIndex: Int) {
        guard let s = sessions.first(where: { $0.id == sid }),
              let req = s.pending.first(where: { $0.kind == .choice || $0.kind == .planConfirm }) else { return }
        let i = optionIndex - 1
        guard i >= 0, i < req.options.count else { return }
        respond(sid, requestId: req.id, choose: [req.options[i].id])
    }

    /// Path A 权限通道入口:AppDelegate 收到 PreToolUse hook 时调用。
    /// 若该 hook 属于本管理器 spawn 的某个会话(按 ownerPID 父链匹配)→ 接管并返回 true:
    /// - AskUserQuestion / ExitPlanMode:hook 层直接放行(交互由 stream 的 tool_use 处理);
    /// - 其它工具:注入 .permission 待响应,审批走控制台/手机,decide 写回解除 hook 阻塞。
    /// 不属于本管理器(用户自己终端里的 claude)→ 返回 false,走旧路径。
    func handleConsolePreToolUse(ownerPID: pid_t, toolName: String, detail: String,
                                 decide: @escaping (PermissionDecision) -> Void) -> Bool {
        guard let driver = driver(forOwnerPID: ownerPID) else { return false }
        if toolName == "AskUserQuestion" || toolName == "ExitPlanMode" {
            decide(.allow)   // 放行,让 stream 里的 tool_use→tool_result 处理交互
        } else if PolicyConstants.readOnlyTools.contains(toolName) {
            decide(.allow)   // 只读/安全工具直接放行,不弹审批(Read/Grep 等不打断)
        } else if toolName == "Bash", !PolicyConstants.bashNeedsApproval(detail) {
            decide(.allow)   // 黑名单策略:Bash 默认放行,只有删除/git push/delete/install 才弹审批
        } else {
            driver.injectPermission(toolName: toolName, detail: detail, decide: decide)
        }
        return true
    }

    /// 该 ownerPID(hook 的 _ppid)是否属于本管理器 spawn 的控制台会话。
    func isConsoleSession(ownerPID: pid_t) -> Bool { driver(forOwnerPID: ownerPID) != nil }

    /// 沿 ownerPID 父链上溯,匹配某会话 driver 的 ownerPID(claude 子进程 pid)。
    private func driver(forOwnerPID pid: pid_t) -> AgentDriver? {
        var cur = pid, depth = 0
        while cur > 1 && depth < 32 {
            for m in managed.values where m.driver.ownerPID == cur { return m.driver }
            guard let info = ProcessUtils.procInfo(pid: cur) else { return nil }
            cur = info.ppid; depth += 1
        }
        return nil
    }

    func closeSession(_ sid: String) {
        let wd = sessions.first { $0.id == sid }?.workdir
        managed[sid]?.consumeTask?.cancel()
        managed[sid]?.driver.stop()
        managed[sid] = nil
        sessions.removeAll { $0.id == sid }
        // 结束的会话会成为/更新历史条目 → 让该项目历史缓存失效,下次进开始面板重算。
        if let wd { invalidateHistory(wd) }
    }

    // MARK: - 事件 → 模型

    private func apply(_ ev: SessionEvent, to sid: String) {
        switch ev {
        case .status(let st):
            mutate(sid) { $0.status = st }
        case .sessionId(let aid):
            mutate(sid) { $0.agentSessionId = aid }
            loadHistory(sessionId: aid, into: sid)   // resume/continue 时把历史读回来(空会话无害)
        case .messageDelta(let msgId, let role, let text):
            mutate(sid) { s in
                if let i = s.messages.firstIndex(where: { $0.id == msgId }) {
                    s.messages[i].text += text
                } else {
                    s.messages.append(AgentMessage(id: msgId, role: role, kind: .text,
                                                   text: text, ord: self.nextOrd()))
                }
            }
        case .messageComplete:
            break
        case .toolCall(let t):
            mutate(sid) { s in
                s.messages.append(AgentMessage(id: t.id, role: "assistant", kind: .tool,
                                               text: "\(t.name): \(t.summary)", ord: self.nextOrd()))
            }
        case .fileEdit(let f):
            mutate(sid) { s in
                s.messages.append(AgentMessage(id: "file_\(f.path)_\(self.nextOrd())", role: "assistant",
                                               kind: .file, text: f.path, ord: self.ordCounter))
            }
        case .pendingRequest(let req):
            mutate(sid) { s in
                if req.kind == .permission {
                    // 权限:就地把对应的命令消息(Bash: …)变成一张审批卡(命令+按钮);
                    // 找不到对应命令消息(时序/罕见)则新追加一条。处理后原地变徽标,不消失。
                    let detail = req.detail ?? ""
                    let match = s.messages.lastIndex(where: { m in
                        m.kind == .tool && m.permReqId == nil && (detail.isEmpty || m.text.contains(detail))
                    }) ?? s.messages.lastIndex(where: { $0.kind == .tool && $0.permReqId == nil })
                    if let i = match {
                        s.messages[i].kind = .permission
                        s.messages[i].permReqId = req.id
                        if !detail.isEmpty { s.messages[i].text = detail }
                    } else {
                        s.messages.append(AgentMessage(id: "perm_\(req.id)", role: "assistant",
                            kind: .permission, text: detail.isEmpty ? req.title : detail,
                            ord: self.nextOrd(), permReqId: req.id))
                    }
                } else {
                    if !s.pending.contains(where: { $0.id == req.id }) { s.pending.append(req) }
                }
                s.status = .needsResponse
            }
        case .pendingResolved(let id):
            mutate(sid) { s in s.pending.removeAll { $0.id == id } }
        case .turnComplete:
            break
        case .error(let msg):
            mutate(sid) { s in
                s.status = .error
                s.messages.append(AgentMessage(id: "err_\(self.nextOrd())", role: "system",
                                               kind: .text, text: "⚠️ \(msg)", ord: self.ordCounter))
            }
        }
    }

    // MARK: - 工具

    private func userEcho(_ text: String) -> AgentMessage {
        AgentMessage(id: "u_\(nextOrd())", role: "user", kind: .text, text: text, ord: ordCounter)
    }
    private func nextOrd() -> Int { ordCounter += 1; return ordCounter }

    private func mutate(_ sid: String, _ f: (inout AgentSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == sid }) else { return }
        f(&sessions[i])
    }
}
