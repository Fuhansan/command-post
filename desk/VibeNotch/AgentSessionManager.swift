import Foundation
import Combine

// MARK: - 统一会话模型(上层唯一依赖,agent 无关)

/// 一张随消息发出的图片。通道里只带 id;字节按 id 走 HTTP 拉。本地按 id 缓存供 driver 当路径喂 agent。
struct ImageRef: Equatable {
    let id: String        // 图片 id(/api/image/<id> 或本地缓存 key)
    let ext: String
    let localPath: String // 本地按 id 缓存路径(driver 读它喂 agent)
}

/// 一条会话里的一条消息(统一)。Phase 1 先支撑文本/工具/文件三类,渲染细节 Phase 3 再丰富。
struct AgentMessage: Identifiable, Equatable {
    enum Kind: String { case text, tool, file, permission }
    let id: String
    var role: String          // user / assistant / system
    var kind: Kind
    var text: String          // permission 时 = 命令/操作详情
    var ord: Int              // 逻辑顺序号(到达递增)
    var images: [ImageRef] = []   // 用户消息附带的图片
    /// permission 卡的处理结果:nil=待处理(显示允许/拒绝按钮);"allow"/"deny"=已处理(显示徽标)。
    var permState: String? = nil
    var permReqId: String? = nil   // 关联 driver 的权限请求 id,回写时用
    var op: ToolOp? = nil          // 结构化动作(kind=.tool 时;供 web 时间线渲染)
    var model: String? = nil       // 产生该回合的模型(完整 id,头部展示用)
    var ts: Double? = nil          // 该消息时间(epoch ms,头部展示相对时间)
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
    var model: String? = nil          // 当前模型(从流里读到 / 用户切换)
    var availableModels: [AgentModel] = []   // 可切换模型列表(driver 动态获取)

    static func == (l: AgentSession, r: AgentSession) -> Bool {
        l.id == r.id && l.status == r.status && l.messages == r.messages &&
        l.pending == r.pending && l.title == r.title && l.agentSessionId == r.agentSessionId &&
        l.model == r.model && l.availableModels == r.availableModels
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
    /// 移除项目:仅从项目栏移出(不结束会话,非破坏式);活跃会话仍在后台跑。
    func removeProject(_ workdir: String) {
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

    /// driver 工厂:按 agent 类型造对应适配器。
    private func makeDriver(_ agent: AgentKind) -> AgentDriver {
        switch agent {
        case .claude: return ClaudeStreamJSONDriver()
        case .codex:  return CodexAppServerDriver()
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
        // 自动加项目:只在「孤儿」工作目录时才加——既不在已有项目下,也不在归属目录/默认根下。
        // 否则会被对应项目文件夹 / 默认文件夹收纳,不该污染项目列表(以前无脑加导致什么都变成项目)。
        let inProj: (String) -> Bool = { root in workdir == root || workdir.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        let underExisting = projects.contains(where: inProj)
        let funnelRoots = AppSettings.shared.defaultSessionDirs.map { ($0 as NSString).expandingTildeInPath }
            + [AppSettings.shared.defaultWorkdir.isEmpty ? NSString(string: "~/.vibenotch/workplace").expandingTildeInPath : (AppSettings.shared.defaultWorkdir as NSString).expandingTildeInPath]
        let underFunnel = funnelRoots.contains(where: inProj)
        if !underExisting && !underFunnel { projects.append(workdir); persistProjects() }
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
            do { try await driver.start(workdir: workdir, resume: resume, continueLast: continueLast, model: nil) }
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

    /// 某项目下某会话 id 的转录路径(供桌面历史只读浏览)。
    nonisolated static func historyTranscriptPath(workdir: String, id: String) -> String {
        let enc = String(workdir.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return NSString(string: "~/.claude/projects/\(enc)/\(id).jsonl").expandingTildeInPath
    }

    /// 按文件路径解析转录(供 RelayAgent 给 hook 会话做历史回填复用)。
    nonisolated static func parseTranscriptFile(path: String)
        -> [(role: String, kind: AgentMessage.Kind, text: String)] {
        if path.contains("/.codex/") { return CodexTranscriptReader.parseTranscriptFile(path: path) }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [(String, AgentMessage.Kind, String)] = []
        for line in content.split(separator: "\n") {
            out.append(contentsOf: parseTranscriptLine(String(line)).map { (role: $0.role, kind: $0.kind, text: $0.text) })
        }
        return out
    }

    /// 解析转录中的一行(jsonl),抽出可显示的消息;一行的多个 block 可产生多条。
    nonisolated static func parseTranscriptLine(_ line: String)
        -> [(role: String, kind: AgentMessage.Kind, text: String, op: ToolOp?, model: String?, ts: Double?)] {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = o["type"] as? String,
              let msg = o["message"] as? [String: Any] else { return [] }
        let cwd = o["cwd"] as? String ?? ""
        let ts = parseISOms(o["timestamp"])
        let model = msg["model"] as? String
        var out: [(String, AgentMessage.Kind, String, ToolOp?, String?, Double?)] = []
        if type == "user" {
            if (o["isMeta"] as? Bool) == true { return [] }   // 元数据条目(非真实对话)整条跳过
            if let s = msg["content"] as? String {
                let t = s.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !isSystemInjected(t) { out.append(("user", .text, s, nil, nil, ts)) }
            } else if let blocks = msg["content"] as? [[String: Any]] {
                var added = false
                for b in blocks where (b["type"] as? String) == "text" {
                    // 按 block 过滤:丢掉系统/harness 注入块(任务通知/系统提醒/本地命令回显…),保留同条里你真正的文本
                    if let t = b["text"] as? String, !t.isEmpty, !isSystemInjected(t) { out.append(("user", .text, t, nil, nil, ts)); added = true }
                }
                // 纯图片消息:占位一条空文本(图片由 transcriptImages 按 ord 补上),否则历史里整条消失
                if !added, blocks.contains(where: { ($0["type"] as? String) == "image" }) {
                    out.append(("user", .text, "", nil, nil, ts))
                }
            }
        } else if type == "assistant", let blocks = msg["content"] as? [[String: Any]] {
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    if let t = b["text"] as? String, !t.isEmpty { out.append(("assistant", .text, t, nil, model, ts)) }
                case "tool_use":
                    let name = b["name"] as? String ?? "?"
                    if Self.isNoisyTool(name) { break }   // 任务/待办类:转录回填也跳过(与实时链路一致)
                    let input = b["input"] as? [String: Any] ?? [:]
                    let op = claudeToolOp(name: name, input: input, workdir: cwd)   // 与实时链路同一构造器 → diff/目录一致
                    let sm = (input["command"] ?? input["file_path"] ?? input["path"]
                              ?? input["pattern"] ?? input["url"]) as? String ?? ""
                    out.append(("assistant", .tool, "\(name): \(sm)", op, model, ts))
                default: break
                }
            }
        }
        return out
    }

    /// 系统/harness 注入到 user 轮的非真实输入(任务通知、系统提醒、本地命令回显、诊断等)。
    /// 转录里这些虽然 type=user,但不是用户真正的话,要过滤掉,避免聊天里冒出多余气泡。
    /// 任务/待办类工具 = 纯流程噪音(TodoWrite / Task*),不进会话模型。
    /// 这样手机协议、桌面 web 控制台、转录回填三条链路统一不展示,保证「桌面转录 = 手机协议」。
    nonisolated static func isNoisyTool(_ name: String) -> Bool {
        switch name {
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "TaskStop":
            return true
        default:
            return false
        }
    }

    nonisolated static func isSystemInjected(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = ["<task-notification", "<system-reminder", "<local-command-stdout", "<local-command-caveat",
                    "<command-name", "<command-message", "<command-args", "<command-contents",
                    "<bash-input", "<bash-stdout", "<bash-stderr", "<user-prompt-submit-hook",
                    "<new-diagnostics", "<persisted-output"]
        return tags.contains { t.hasPrefix($0) }
    }

    /// ISO8601 时间串 → epoch 毫秒(转录里每行带 timestamp,如 2026-06-24T19:02:16.123Z)。
    nonisolated static func parseISOms(_ v: Any?) -> Double? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        let f2 = ISO8601DateFormatter()
        return f2.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
    }

    /// 只解析文件「尾部一窗」(默认末尾 256KB),供历史/手动会话懒加载,避免读+推+渲染整份大转录。
    /// endByte 省略 = 到文件末尾;传值 = 解析该字节偏移之前的一窗(「加载更早」)。
    /// ord = 该消息所在行的起始字节偏移(全局单调,跨窗稳定排序/去重);earliest = 本窗最早一条消息所在行的偏移。
    nonisolated static func parseTranscriptWindow(path: String, endByte: UInt64?, windowBytes: Int = 1024 * 1024)
        -> (messages: [(role: String, kind: AgentMessage.Kind, text: String, ord: Int, op: ToolOp?, model: String?, ts: Double?)], queued: [String], earliest: Int, hasEarlier: Bool) {
        if path.contains("/.codex/") {
            let r = CodexTranscriptReader.parseTranscriptWindow(path: path, endByte: endByte)
            return (r.messages.map { ($0.role, $0.kind, $0.text, $0.ord, nil as ToolOp?, nil as String?, nil as Double?) }, [], r.earliest, r.hasEarlier)
        }
        guard let fh = FileHandle(forReadingAtPath: path) else { return ([], [], 0, false) }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let end = min(endByte ?? fileSize, fileSize)
        let start = end > UInt64(windowBytes) ? end - UInt64(windowBytes) : 0
        try? fh.seek(toOffset: start)
        let bytes = [UInt8]((try? fh.read(upToCount: Int(end - start))) ?? Data())
        // start>0:丢弃可能被切断的首行残片(从第一个换行后开始)。
        var i = 0
        if start > 0 { i = (bytes.firstIndex(of: 0x0A)).map { $0 + 1 } ?? bytes.count }
        var out: [(String, AgentMessage.Kind, String, Int, ToolOp?, String?, Double?)] = []
        var firstKept: Int? = nil
        // 「工作中发的消息」被 Claude Code 记成 queue-operation(enqueue/dequeue/remove),不是 type:user。
        // FIFO 跟踪:enqueue 入队、dequeue(已处理→会另有 type:user)/remove(撤销)出队。末尾剩下的=当前仍在排队。
        var pendingQueue: [String] = []
        while i < bytes.count {
            var j = i
            while j < bytes.count && bytes[j] != 0x0A { j += 1 }
            if j > i, let lineStr = String(bytes: bytes[i..<j], encoding: .utf8) {
                let lineByteStart = Int(start) + i
                if lineStr.contains("\"type\":\"queue-operation\"") {
                    if let d = lineStr.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        let op = o["operation"] as? String
                        if op == "enqueue", let c = (o["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !c.isEmpty, !isSystemInjected(c) {
                            pendingQueue.append(c)
                        } else if op == "dequeue" || op == "remove" {
                            if !pendingQueue.isEmpty { pendingQueue.removeFirst() }
                        }
                    }
                } else {
                    let msgs = parseTranscriptLine(lineStr)
                    if !msgs.isEmpty {
                        if firstKept == nil { firstKept = lineByteStart }
                        for (k, m) in msgs.enumerated() {
                            out.append((m.role, m.kind, m.text, lineByteStart * 16 + min(k, 15), m.op, m.model, m.ts))
                        }
                    }
                }
            }
            i = j + 1
        }
        // pendingQueue = 当前仍在排队的消息(工作中发的、还没被处理)→ 单独返回,前端在「排队中」区显示。
        let earliest = firstKept ?? Int(start)
        return (out, pendingQueue, earliest, earliest > 0)
    }

    /// 历史图片:扫与 parseTranscriptWindow 同一窗,返回 ord → 图片([{thumb,url}],都是 data URL)。
    /// 不动主解析链(Codex/手机端不受影响),桥按 ord 合并进历史消息 DTO。Codex 图片是 localImage 路径,暂不处理。
    nonisolated static func transcriptImages(path: String, endByte: UInt64?, windowBytes: Int = 1024 * 1024) -> [Int: [[String: String]]] {
        guard !path.contains("/.codex/"), let fh = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let end = min(endByte ?? fileSize, fileSize)
        let start = end > UInt64(windowBytes) ? end - UInt64(windowBytes) : 0
        try? fh.seek(toOffset: start)
        let bytes = [UInt8]((try? fh.read(upToCount: Int(end - start))) ?? Data())
        var i = 0
        if start > 0 { i = (bytes.firstIndex(of: 0x0A)).map { $0 + 1 } ?? bytes.count }
        var result: [Int: [[String: String]]] = [:]
        while i < bytes.count {
            var j = i
            while j < bytes.count && bytes[j] != 0x0A { j += 1 }
            if j > i, let lineStr = String(bytes: bytes[i..<j], encoding: .utf8),
               let imgs = userImagesInLine(lineStr) {
                // 与 parseTranscriptWindow 的 ord 对齐:用户图文消息是该行第 0 条
                result[(Int(start) + i) * 16 + 0] = imgs
            }
            i = j + 1
        }
        return result
    }

    private nonisolated static func userImagesInLine(_ line: String) -> [[String: String]]? {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (o["type"] as? String) == "user",
              let msg = o["message"] as? [String: Any],
              let blocks = msg["content"] as? [[String: Any]] else { return nil }
        var imgs: [[String: String]] = []
        for b in blocks where (b["type"] as? String) == "image" {
            guard let src = b["source"] as? [String: Any], let data = src["data"] as? String, !data.isEmpty else { continue }
            let mt = (src["media_type"] as? String) ?? "image/png"
            let ext = mt.hasSuffix("png") ? "png" : mt.hasSuffix("webp") ? "webp" : mt.hasSuffix("gif") ? "gif" : "jpg"
            // 历史图落本地缓存、用内容 hash 当本地 id;通道只带这个 id,桌面 web 按 app://__img/<id> 取
            guard let id = ImageRelay.cacheBase64(data, ext: ext) else { continue }
            imgs.append(["id": id, "ext": ext])
        }
        return imgs.isEmpty ? nil : imgs
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
        if path.contains("/.codex/") { return CodexTranscriptReader.firstUserPrompt(path: path) }
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
        // 本地立即回显用户消息 + 乐观置 working:发出去就显示「思考中」,不等 agent 首 token
        mutate(sid) { s in s.messages.append(self.userEcho(text)); s.status = .working }
        d.send(UserInput(text: text, imagePaths: imagePaths))
    }

    /// 带图发送:images 已落盘 + (尽量)上传服务器。driver 读本地路径喂 agent,回显/relay 带缩略图与 id。
    func send(_ sid: String, text: String, images: [ImageRef]) {
        guard let d = managed[sid]?.driver else { return }
        mutate(sid) { s in s.messages.append(self.userEcho(text, images: images)); s.status = .working }
        d.send(UserInput(text: text, imagePaths: images.map { $0.localPath }))
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
        // 结束的会话会成为历史条目。**重载**历史(不是清空)—— 清空会让历史卡瞬间全没;
        // force 重载保留旧值、后台解析完再替换,结束的会话随即作为历史卡回到列表。
        if let wd { loadHistoryList(for: wd, force: true) }
    }

    /// 终端用 `--continue`/`--resume` 抢占了某个控制台会话(同 session_id,但 hook 事件来自终端、
    /// 不是本管理器 spawn 的进程)。「只保活一个进程」:杀掉控制台那个 claude(进程 A)、移除控制台
    /// 会话条目 → 前端按 session_id 去重(App.tsx consoleSids)会让同 id 的终端会话**原地接上**:
    /// 卡片从「控制台」翻牌成「终端」,不消失、不重复。调用方在 `store.apply(event)` 之后调它,
    /// 终端会话此时已落地 → 翻牌零空窗。每个 hook 事件都会调一次,未命中廉价返回 false。
    @discardableResult
    func handoffToTerminal(agentSessionId aid: String) -> Bool {
        guard let s = sessions.first(where: { $0.agentSessionId == aid }) else { return false }
        let sid = s.id
        vlog("console handoff→terminal: sid=\(sid) aid=\(aid.prefix(8)) 杀进程A,让位给终端")
        managed[sid]?.consumeTask?.cancel()
        managed[sid]?.driver.stop()
        managed[sid] = nil
        sessions.removeAll { $0.id == sid }
        return true
    }

    /// 会话中途切模型:停掉当前 driver,用新模型 `--resume` 当前会话重起(上下文保留,短暂重连)。
    /// 没有 agentSessionId(还没开聊)时则直接以新模型重起,消息此时为空,无损。
    func switchModel(_ sid: String, to model: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }
        let s = sessions[idx]
        if s.model == model { return }
        let resumeId = s.agentSessionId
        vlog("console switchModel: sid=\(sid) -> \(model) resume=\(resumeId ?? "-")")
        managed[sid]?.consumeTask?.cancel()
        managed[sid]?.driver.stop()
        let driver = makeDriver(s.agent)
        sessions[idx].model = model
        sessions[idx].status = .starting
        var m = Managed(driver: driver, consumeTask: nil)
        m.consumeTask = Task { [weak self] in
            for await ev in driver.events { await self?.apply(ev, to: sid) }
        }
        managed[sid] = m
        Task {
            do { try await driver.start(workdir: s.workdir, resume: resumeId, continueLast: false, model: model) }
            catch { await self.apply(.error("切换模型失败: \(error)"), to: sid) }
        }
    }

    // MARK: - 事件 → 模型

    private func apply(_ ev: SessionEvent, to sid: String) {
        switch ev {
        case .status(let st):
            mutate(sid) { $0.status = st }
        case .sessionId(let aid):
            mutate(sid) { $0.agentSessionId = aid }
            loadHistory(sessionId: aid, into: sid)   // resume/continue 时把历史读回来(空会话无害)
        case .model(let m):
            mutate(sid) { $0.model = m }
        case .availableModels(let ms):
            mutate(sid) { $0.availableModels = ms }
        case .messageDelta(let msgId, let role, let text):
            mutate(sid) { s in
                if let i = s.messages.firstIndex(where: { $0.id == msgId }) {
                    s.messages[i].text += text
                } else {
                    s.messages.append(AgentMessage(id: msgId, role: role, kind: .text,
                                                   text: text, ord: self.nextOrd(),
                                                   model: s.model, ts: Date().timeIntervalSince1970 * 1000))
                }
            }
        case .messageComplete:
            break
        case .toolCall(let t):
            if Self.isNoisyTool(t.name) { break }   // 任务/待办类:不入会话(噪音)
            mutate(sid) { s in
                s.messages.append(AgentMessage(id: t.id, role: "assistant", kind: .tool,
                                               text: "\(t.name): \(t.summary)", ord: self.nextOrd(), op: t.op,
                                               model: s.model, ts: Date().timeIntervalSince1970 * 1000))
            }
        case .toolOutput(let id, let lines):
            mutate(sid) { s in
                if let i = s.messages.firstIndex(where: { $0.id == id }) { s.messages[i].op?.output = lines }
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

    private func userEcho(_ text: String, images: [ImageRef] = []) -> AgentMessage {
        AgentMessage(id: "u_\(nextOrd())", role: "user", kind: .text, text: text, ord: ordCounter, images: images)
    }
    private func nextOrd() -> Int { ordCounter += 1; return ordCounter }

    private func mutate(_ sid: String, _ f: (inout AgentSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == sid }) else { return }
        f(&sessions[i])
    }
}
