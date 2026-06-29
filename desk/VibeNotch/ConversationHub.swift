import Foundation
import Combine

/// 消息枢纽(见 docs/message-hub.md v2)。P1 范围:只承接 **terminal(hook)会话当前轮的
/// 原子步骤推导**(文字 + 工具 op),即出口分组/渲染的**输入**。把 RelayAgent.buildMessages 里
/// 那段「turnSteps → 工具 op」的推导(含噪音过滤、读/编辑去重、diff 计算)搬到这里**单一来源**。
///
/// 暂不承接(后续子步,见 doc §13):prompt/历史回填(P1 后续)、权限/选择题生命周期(P3.5)、
/// console 源(P3)。这些目前仍由各出口自行处理。
///
/// 设计约束:派生投影,不独立 mutate(§5.1);与 agent 无关的步骤,agent 差异下沉在 turnSteps 适配器。
/// @MainActor:与 SessionStore / RelayAgent 同 actor,store 变更在主线程投递,读写都在主线程。
@MainActor
final class ConversationHub: ObservableObject {
    private weak var store: SessionStore?
    private var cancellables: Set<AnyCancellable> = []

    /// 当前所有会话的规范化投影,键 = ConvID.stable。出口订阅它取数据。
    @Published private(set) var conversations: [String: Conversation] = [:]

    /// hook 历史回填(当前轮之前的消息)。沿用 RelayAgent 原有的 (role, kind, text) 形态,出口零改造。
    typealias HistItem = (role: String, kind: AgentMessage.Kind, text: String)
    private var historyBySession: [String: [HistItem]] = [:]
    /// 历史按「转录大小+mtime」缓存(与 turnSteps 一致):转录没增长就不重解析;增长了就重算
    /// → 历史随轮次推进**实时更新**(不再像旧版那样冻结到重连)。键 = transcriptPath。
    private var historyCache: [String: (size: UInt64, mtime: TimeInterval, hist: [HistItem])] = [:]

    init(store: SessionStore) {
        self.store = store
        store.$sessions
            .sink { [weak self] sessions in self?.rebuild(sessions) }
            .store(in: &cancellables)
        rebuild(store.sessions)
    }

    /// 某 terminal 会话当前轮的 AI 原子步骤(供 RelayAgent 分组、Web 原子渲染)。
    func terminalSteps(sessionId: String) -> [ConvMessage] {
        (conversations[ConvID(source: .terminal, key: sessionId).stable]?.messages ?? [])
            .filter { $0.role == .agent }
    }

    /// 当前轮的用户 prompt(已过滤系统注入;text=原始 prompt,images=粘贴图片的路径 id)。
    func terminalPrompt(sessionId: String) -> ConvMessage? {
        (conversations[ConvID(source: .terminal, key: sessionId).stable]?.messages ?? [])
            .first { $0.role == .user }
    }

    /// 某 terminal 会话「当前轮之前」的历史消息(已规范化的边界:最后一条用户消息为界)。
    func terminalHistory(sessionId: String) -> [HistItem] {
        historyBySession[sessionId] ?? []
    }

    // MARK: - 投影(派生,不 mutate 源)

    private func rebuild(_ sessions: [SessionEntry]) {
        var next: [String: Conversation] = [:]
        var nextHist: [String: [HistItem]] = [:]
        for e in sessions {
            let conv = Self.projectTerminal(e)
            next[conv.id.stable] = conv
            nextHist[e.id] = computeHistory(e)
        }
        historyBySession = nextHist
        if next != conversations { conversations = next }
    }

    /// 解析转录得到「当前轮之前」的历史(忠实搬自 RelayAgent.hookHistory,缓存改为 size+mtime)。
    private func computeHistory(_ e: SessionEntry) -> [HistItem] {
        guard let path = e.transcriptPath else { return [] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let c = historyCache[path], c.size == size, c.mtime == mtime { return c.hist }
        let all = AgentSessionManager.parseTranscriptFile(path: path)
        // 边界 = 最后一条用户消息(当前轮起点);之前的才是历史,避免与实时管线重复。
        let boundary = all.lastIndex { $0.role == "user" } ?? all.count
        let hist = Array(all.prefix(boundary))
        historyCache[path] = (size, mtime, hist)
        return hist
    }

    /// terminal 会话 → 规范会话(P1:messages 只含当前轮原子步骤)。nonisolated 纯函数,便于测试/复用。
    static func projectTerminal(_ e: SessionEntry) -> Conversation {
        let agent: ConvAgent = (e.transcriptPath.flatMap { CodingAgents.forTranscript($0)?.id } == "codex") ? .codex : .claude
        let id = ConvID(source: .terminal, key: e.id)
        var msgs: [ConvMessage] = []
        if let pm = promptMessage(e, convID: id) { msgs.append(pm) }   // 用户 prompt(role=.user)
        msgs.append(contentsOf: stepMessages(e, convID: id))           // AI 步骤(role=.agent)
        return Conversation(id: id, source: .terminal, cwd: e.cwd, agent: agent,
                            state: e.state, turn: 1, hasMore: false, messages: msgs)
    }

    /// 用户 prompt → 用户消息(过滤系统注入)。枢纽只给原料:text=原始 prompt,images=粘贴图片路径 id;
    /// 文本清洗(cleanPrompt/stripImages)与图片解码是出口渲染的事,留在出口。
    private static func promptMessage(_ e: SessionEntry, convID: ConvID) -> ConvMessage? {
        guard let p = e.promptSummary, !p.isEmpty, !AgentSessionManager.isSystemInjected(p) else { return nil }
        let paths = extractImagePaths(p, sessionId: e.id)
        let imgs = paths.map { ConvImageRef(id: $0) }
        return ConvMessage(id: ConvMsgID(conv: convID, slot: "user"), ord: 0,
                           role: .user, kind: paths.isEmpty ? .text : .photo,
                           text: p, images: imgs.isEmpty ? nil : imgs)
    }

    /// 从 prompt 抽出粘贴图片的本地路径(忠实搬自 RelayAgent.extractImagePaths)。
    /// `[Image #N]` → ~/.claude/image-cache/<sid>/N.<ext>;兼容显式 source 路径与裸路径。
    private static func extractImagePaths(_ p: String, sessionId: String) -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        let cacheDir = NSString(string: "~/.claude/image-cache").expandingTildeInPath + "/" + sessionId
        if let re = try? NSRegularExpression(pattern: #"\[Image\s*#(\d+)\]"#) {
            let ns = p as NSString
            for m in re.matches(in: p, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let n = ns.substring(with: m.range(at: 1))
                for ext in ["png", "jpg", "jpeg", "gif", "webp"] {
                    let path = "\(cacheDir)/\(n).\(ext)"
                    if fm.fileExists(atPath: path) { if !paths.contains(path) { paths.append(path) }; break }
                }
            }
        }
        if !paths.isEmpty { return paths }
        let patterns = [#"\[Image:[^\]]*?source:\s*([^\]\s]+)\]"#,
                        #"(/[^\s\]]+?\.(?:png|jpe?g|gif|webp|heic))"#]
        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            let ns = p as NSString
            for m in re.matches(in: p, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let path = ns.substring(with: m.range(at: 1))
                if !paths.contains(path) { paths.append(path) }
            }
            if !paths.isEmpty { break }
        }
        return paths
    }

    /// 当前轮 turnSteps → 原子消息(忠实搬运 buildMessages 的工具 op 计算 + 过滤 + 去重)。
    /// 被用户中断的整轮 → 空(与现状一致)。
    private static func stepMessages(_ e: SessionEntry, convID: ConvID) -> [ConvMessage] {
        if let path = e.transcriptPath, TranscriptReader.currentTurnInterrupted(transcriptPath: path) {
            return []
        }
        let diffs = e.transcriptPath.map { TranscriptReader.fileEditDiffs(transcriptPath: $0) } ?? [:]
        let editNames = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Create"]
        let readNames = ["Read", "NotebookRead"]
        var seenFiles = Set<String>()
        var out: [ConvMessage] = []
        var ord = 0

        func push(_ kind: ConvMsgKind, text: String = "", op: ToolOp? = nil) {
            let mid = ConvMsgID(conv: convID, slot: "t1:s\(ord)")
            out.append(ConvMessage(id: mid, ord: ord, role: .agent, kind: kind, text: text, op: op))
            ord += 1
        }

        for step in e.turnSteps {
            switch step {
            case .text(let s):
                guard !s.isEmpty else { break }
                push(.text, text: s)          // 原文不截断:截断/markdown 是出口渲染的事
            case .tool(let name, let input):
                if AgentSessionManager.isNoisyTool(name) { break }   // 噪音工具不展示
                var op: ToolOp? = nil
                if editNames.contains(name) || readNames.contains(name) {
                    if let path = input, !path.isEmpty {
                        let isEdit = editNames.contains(name)
                        if !isEdit || !seenFiles.contains(path) {     // 编辑去重;读取不去重
                            if isEdit { seenFiles.insert(path) }
                            var o = ToolOp(kind: (name == "Write" || name == "Create") ? .write : isEdit ? .edit : .read)
                            o.file = (path as NSString).lastPathComponent
                            o.dir = relDir(path, workdir: e.cwd)
                            let hunks = diffs[path] ?? []
                            if !hunks.isEmpty {
                                var add = 0, del = 0; var dl: [DiffLine] = []
                                for h in hunks {
                                    let k = h["op"] ?? "ctx"
                                    for ln in (h["text"] ?? "").components(separatedBy: "\n") {
                                        dl.append(DiffLine(kind: k, text: ln))
                                        if k == "add" { add += 1 } else if k == "del" { del += 1 }
                                    }
                                }
                                o.diff = dl; o.add = add; o.del = del
                            }
                            op = o
                        }
                        // 被去重的编辑:无消息(与现状一致)
                    }
                } else if name == "Bash" {
                    var o = ToolOp(kind: .bash); o.command = input
                    o.file = (input ?? "").split(separator: " ").first.map(String.init) ?? "bash"
                    o.dir = (e.cwd as NSString).lastPathComponent
                    op = o
                } else {
                    var o = ToolOp(kind: .other); o.label = otherToolLabel(name); o.file = input ?? ""
                    op = o
                }
                if let op { push(.tool, op: op) }
            }
        }
        return out
    }
}
