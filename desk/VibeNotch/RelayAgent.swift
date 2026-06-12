import AppKit
import Combine
import Foundation

/// 把 VibeNotch 接到 AI Coding Remote 中转服务器，成为协议里的 **Agent**。
///
/// 上行：订阅 `SessionStore` / `PendingDecisionStore`，把每个 Claude Code 会话翻译成
/// 协议 `ui` 组件树推给手机(状态、prompt、危险命令的 Allow/Deny 卡)。
/// 下行：手机点 Allow/Deny → 服务器转 `action` 帧 → 这里回调 `onRemoteDecision`
///       → `AppDelegate.decide()` → 解除 claude 阻塞。这就是「手机控制电脑」的落点。
///
/// v1：account 写死 demo;不处理手机文本 input(TODO)。
@MainActor
final class RelayAgent: NSObject, ObservableObject {

    static let relayURL = URL(string: "ws://127.0.0.1:8090/ws")!
    /// 本机 Agent 的稳定唯一标识(多台电脑同账号时区分会话/快照/在线状态)。
    static let deviceId: String = {
        let key = "agent.deviceId"
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let v = "mac_" + String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    /// 配对账号:只来自手机配对授权的凭据。未配对 = 无账号 = 不连服务器(第一道防线)。
    static var account: String { AgentCredentials.account ?? "" }
    /// 是否已与手机配对。
    static var isPaired: Bool { !(AgentCredentials.token ?? "").isEmpty }
    // 每个 claude 会话(终端)= 一个独立协议 sid = entry.id → 手机端分成多个任务。

    /// 手机请求结束任务(关闭该 claude 会话)。由 AppDelegate 接到进程终止逻辑。
    var onRemoteClose: ((String) -> Void)?
    /// 手机发来的输入(文字 + 已落盘的图片路径)。由 AppDelegate 注入对应终端。
    var onRemoteInput: ((String, String, [String]) -> Void)?
    /// 手机回传的远程决定(allow/deny)。由 AppDelegate 接到 `decide(sessionId:decision:)`。
    var onRemoteDecision: ((String, PermissionDecision) -> Void)?

    private let store: SessionStore
    private let pending: PendingDecisionStore

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)
    private var cancellables = Set<AnyCancellable>()
    private var seq = 0
    private var lastSent: [String: String] = [:]   // 消息 id → 内容签名,去重
    private var knownSids: Set<String> = []         // 已推送过的会话,用于检测会话整体消失
    private var imageCache: [String: String?] = [:] // 图片路径 → 缩略图 base64(nil=读取失败,避免重复尝试)
    private var turnCount: [String: Int] = [:]      // 会话 → 当前轮次(prompt 变化即 +1),消息 id 带轮次 → 客户端累积历史
    private var turnPrompt: [String: String] = [:]  // 会话 → 上次见到的 prompt,用于检测新一轮
    /// 一次审批请求 = 一条记录 = 一张独立卡片(id 带轮内序号)。
    /// 同一轮多次审批时,每次都是新卡追加在会话末尾,旧卡保留各自的结果。
    private struct PermRecord {
        let pfx: String       // 请求发生时的轮次前缀
        let idx: Int          // 轮内序号(同轮第几次审批)
        var detail: String?   // 请求的命令
        var decision: String? // nil=待决定;"allow"/"deny"/"timeout"/"expired"
    }
    private var permRecords: [String: [PermRecord]] = [:]  // 会话 → 审批记录
    private var appliedDecisionSeq = 0                     // 已消费的决定事件水位
    private var msgTime: [String: String] = [:]            // 消息 → 首次出现时间(HH:mm),保证时间戳稳定不漂移
    private var seenFrameIds: Set<String> = []              // 已处理的上行帧 id(幂等去重)
    private var seenFrameOrder: [String] = []               // 同上,FIFO 容量控制
    private var lastPongAt = Date()                         // 最近一次 pong,用于检测僵死连接
    private var heartbeatTimer: Timer?

    /// 消息首次出现的时间;之后同 id 始终返回同一值。
    private func stamp(for msgId: String) -> String {
        if let t = msgTime[msgId] { return t }
        let t = Self.hhmm.string(from: Date())
        msgTime[msgId] = t
        return t
    }
    private var retry = 0
    private var started = false
    private var firstConnect = true   // 进程内首次连接(区分进程重启 vs 网络重连)

    init(store: SessionStore, pending: PendingDecisionStore) {
        self.store = store
        self.pending = pending
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        // 任一会话/待决变化 → 同步到服务器。
        // 注:@Published 在 willSet 触发(值改变之前),直接同步会读到旧状态、漏掉删除。
        // 用 Task{@MainActor} 延到本次修改完成后再读 store.sessions(新状态)。
        store.$sessions
            .sink { [weak self] _ in Task { @MainActor in self?.syncToServer() } }
            .store(in: &cancellables)
        pending.$pendingIDs
            .sink { [weak self] _ in Task { @MainActor in self?.syncToServer() } }
            .store(in: &cancellables)
        pending.$decisionEvents
            .sink { [weak self] _ in Task { @MainActor in self?.syncToServer() } }
            .store(in: &cancellables)
        connect()
    }

    func stop() {
        cancellables.removeAll()
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        started = false
    }

    // MARK: - 连接 / 鉴权

    private func connect() {
        // 第一道防线:未配对(无凭据)不连接服务器。配对成功后经
        // credentialsChanged 通知 → restart() 再进来。
        guard Self.isPaired else {
            vlog("relay: 未配对,保持离线(在 VibeNotch 设置里配对手机)")
            return
        }
        let t = session.webSocketTask(with: Self.relayURL)
        t.maximumMessageSize = 8 << 20   // 手机上行图片帧可达数百 KB,默认 1MB 太紧
        task = t
        t.resume()
        receiveLoop()
        sendAuth()
        startHeartbeat()
        retry = 0
        lastSent.removeAll()
        knownSids.removeAll()
        // 进程刚启动(非网络重连)→ 让服务器+手机清掉上个进程实例的残留消息,
        // 避免重启后轮次重置导致旧 id(如 t2:img0/prompt)与新 id 并存的孤儿气泡。
        if firstConnect {
            firstConnect = false
            sendReset()
        }
        syncToServer()   // 连上后补发当前所有会话
    }

    /// 清空本账号在服务器与手机端的全部会话(agent 进程重启时调用)。
    private func sendReset() {
        seq += 1
        send(jsonString(["v": 1, "t": "patch", "id": "reset", "seq": seq,
                         "from": "agent", "body": ["op": "reset", "agent": Self.deviceId]]))
    }

    private func sendAuth() {
        let name = Host.current().localizedName ?? "工作 Mac"
        sendJSON([
            "v": 1, "t": "auth", "id": "h_agent", "from": "agent",
            "body": [
                // 配对授权拿到的 token:服务器据此解析账号(无有效 token 会被拒绝)
                "token": AgentCredentials.token ?? "",
                "account": Self.account,
                "device": ["id": Self.deviceId, "platform": "mac", "name": name],
                "caps": ["protocol": 1]
            ]
        ])
    }

    /// 凭据变化(配对成功/退出)→ 先以旧身份清掉本机数据,再以新身份重连。
    func restart() {
        sendReset()   // 旧账号的手机立刻看到本机会话消失(+ presence 离线)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)   // 给 reset 帧出门的时间
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.connect()
        }
    }

    // MARK: - 上行:会话 → 协议组件

    /// 每个会话 → **多条独立消息**(prompt / 每句 AI 文本 / 每个文件 / 每条命令 / 待批准),
    /// 各自一条 `ui` 帧。手机端据此渲染成真正的对话:每条消息独立一行、各带头像。
    private func syncToServer() {
        // 先消费新的审批决定事件:把结果写进对应记录(该会话最早一条未决定的)。
        for ev in pending.decisionEvents where ev.seq > appliedDecisionSeq {
            if var recs = permRecords[ev.sid],
               let i = recs.firstIndex(where: { $0.decision == nil }) {
                recs[i].decision = ev.decision
                permRecords[ev.sid] = recs
            }
            appliedDecisionSeq = max(appliedDecisionSeq, ev.seq)
        }

        let activeSids = Set(store.sessions.map(\.id))
        // 整会话消失 → 删除该会话所有消息
        for sid in knownSids where !activeSids.contains(sid) {
            sendSessionRemove(sid: sid)
            for k in Array(lastSent.keys) where k.hasPrefix("m:\(sid):") { lastSent[k] = nil }
            for k in Array(msgTime.keys) where k.hasPrefix("m:\(sid):") { msgTime[k] = nil }
            permRecords[sid] = nil
        }
        knownSids = activeSids

        for e in store.sessions {
            // 轮次:prompt 变化 = 新一轮 → 递增。消息 id 带轮次,使客户端**累积历史**而非替换刷新。
            let prompt = e.promptSummary ?? ""
            if !prompt.isEmpty, turnPrompt[e.id] != prompt {
                turnPrompt[e.id] = prompt
                turnCount[e.id, default: 0] += 1
            }
            let turn = max(turnCount[e.id] ?? 0, 1)

            let meta = sessionMeta(e)
            let msgs = buildMessages(e, turn: turn)
            let currentIds = Set(msgs.map { $0.id })
            // 只清理**当前轮**消失的消息(流式变化/待批准已处理);过去轮永久保留为历史。
            let turnPrefix = "m:\(e.id):t\(turn):"
            for k in Array(lastSent.keys) where k.hasPrefix(turnPrefix) && !currentIds.contains(k) {
                sendMessageRemove(sid: e.id, msgId: k)
                lastSent[k] = nil
            }
            // 变化的消息才推
            for m in msgs {
                let body: [String: Any] = ["role": m.role, "session": meta, "root": m.root,
                                           "time": stamp(for: m.id)]
                let sig = jsonString(body)
                guard lastSent[m.id] != sig else { continue }
                lastSent[m.id] = sig
                seq += 1
                send(jsonString([
                    "v": 1, "t": "ui", "id": m.id, "sid": e.id, "seq": seq, "from": "agent",
                    "fallbackText": m.fallback, "body": body
                ]))
            }
        }
    }

    /// 删除整个会话(及其所有消息)。
    private func sendSessionRemove(sid: String) {
        seq += 1
        send(jsonString(["v": 1, "t": "patch", "id": "m:\(sid)", "sid": sid, "seq": seq,
                         "from": "agent", "body": ["op": "remove", "scope": "session"]]))
    }

    /// 删除会话内某一条消息。
    private func sendMessageRemove(sid: String, msgId: String) {
        seq += 1
        send(jsonString(["v": 1, "t": "patch", "id": msgId, "sid": sid, "seq": seq,
                         "from": "agent", "body": ["op": "remove"]]))
    }

    /// 任务元信息 —— 手机首页任务行用(项目名/目录/终端/副标题/状态/是否需处理)。
    private func sessionMeta(_ e: SessionEntry) -> [String: Any] {
        let isPending = pending.pendingIDs.contains(e.id)
        let subtitle = e.promptSummary ?? e.toolDetail ?? e.lastReplyBlock ?? ""
        let cwd = e.cwd
        let base = (cwd as NSString).lastPathComponent
        // 标题优先用项目名(cwd 末段);取不到再退回终端名。
        let project = (base.isEmpty || base == "?" || base == "/") ? e.terminal.displayName : base
        return [
            "agent": Self.deviceId,                // 来自哪台电脑
            "title": project,                     // 项目名(主标题)
            "terminal": e.terminal.displayName,    // 终端 / IDE
            "cwd": cwd,                            // 项目工作目录
            "subtitle": subtitle,
            "status": isPending ? "waiting" : statusKey(e.state),
            "needsAction": isPending
        ]
    }

    private func statusKey(_ s: SessionState) -> String {
        switch s {
        case .idle: return "idle"
        case .working: return "working"
        case .waiting: return "waiting"
        case .done: return "done"
        }
    }

    private struct Msg { let id: String; let role: String; let root: [String: Any]; let fallback: String }

    /// 一个会话某一轮 → 多条独立消息(id 带轮次,跨轮累积)。
    private func buildMessages(_ e: SessionEntry, turn: Int) -> [Msg] {
        let sid = e.id
        // 本轮被用户中断(Ctrl+C/Esc)→ 整轮不展示,手机端会把这轮已推的消息删掉。
        if let path = e.transcriptPath, TranscriptReader.currentTurnInterrupted(transcriptPath: path) {
            return []
        }
        let pfx = "m:\(sid):t\(turn):"
        let diffs = e.transcriptPath.map { TranscriptReader.fileEditDiffs(transcriptPath: $0) } ?? [:]
        var out: [Msg] = []

        // 用户 prompt:图片 + 文字 → 一个 `photomsg` 统一气泡(文件信息栏 + 图 + 说明,同一张卡片)。
        if let p = e.promptSummary, !p.isEmpty {
            var imageItems: [[String: Any]] = []
            let imgPaths = extractImagePaths(p, sessionId: sid)
            for path in imgPaths {
                guard let data = thumbnailBase64(path: path) else { continue }
                var item: [String: Any] = ["data": data]
                let url = URL(fileURLWithPath: path)
                item["name"] = "image_" + Self.fileStamp.string(from: Date()) + "." + url.pathExtension.lowercased()
                item["kind"] = url.pathExtension.uppercased()
                if let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int {
                    item["size"] = Self.humanSize(bytes)
                }
                imageItems.append(item)
            }
            let hasImage = !imageItems.isEmpty
            var textOnly = (hasImage ? stripImages(p) : cleanPrompt(p))
            if hasImage {
                // 路径已经以缩略图展示,从文字里清掉裸路径和注入时加的「图片:」标记
                for path in imgPaths { textOnly = textOnly.replacingOccurrences(of: path, with: "") }
                for marker in ["请查看这张图片:", "图片:"] {
                    textOnly = textOnly.replacingOccurrences(of: marker, with: "")
                }
            }
            textOnly = textOnly.trimmingCharacters(in: .whitespacesAndNewlines)

            if hasImage {
                var props: [String: Any] = ["images": imageItems,
                                            "time": stamp(for: "\(pfx)user")]
                if !textOnly.isEmpty { props["text"] = cap(textOnly, 1000) }
                out.append(Msg(id: "\(pfx)user", role: "user",
                               root: ["type": "photomsg", "props": props],
                               fallback: cap(textOnly.isEmpty ? "图片" : textOnly, 120)))
            } else if !textOnly.isEmpty {
                out.append(Msg(id: "\(pfx)user", role: "user",
                               root: bubble(role: "user", cap(textOnly, 1000)), fallback: cap(textOnly, 120)))
            }
        }

        // AI 当前一轮:按「一段分析文本 + 其后的工具动作」分组,每组 = 一条消息(一个头像)。
        // 这样「AI 分析完才开始写代码/跑命令」呈现为一个整体,而不是拆成一堆碎气泡。
        var groups: [(fallback: String, blocks: [[String: Any]])] = []
        var current: (fallback: String, blocks: [[String: Any]])? = nil
        var seenFiles = Set<String>()
        func flush() { if let c = current { groups.append(c) }; current = nil }

        for step in e.turnSteps {
            switch step {
            case .text(let s):
                let t = cap(s, 1500)
                guard !t.isEmpty else { break }
                flush()   // 新的分析段 → 开新组
                current = (cap(t, 120), [text(t, markdown: true, style: "body")])   // markdown 文本(无气泡框)
            case .tool(let name, let input):
                var block: [String: Any]? = nil
                switch name {
                case "Edit", "Write", "MultiEdit":
                    if let path = input, !seenFiles.contains(path) {
                        seenFiles.insert(path)
                        block = fileComp(path: path, hunks: diffs[path] ?? [])
                    }
                case "Bash":
                    block = commandComp(input ?? "")
                default:
                    block = toolChipComp(name: name, input: input)
                }
                if let block {
                    if current == nil { current = ("AI 操作", []) }
                    current?.blocks.append(block)
                }
            }
        }
        flush()

        for (gi, g) in groups.enumerated() {
            let root: [String: Any] = g.blocks.count == 1
                ? g.blocks[0]
                : ["type": "stack", "props": ["spacing": 10], "children": g.blocks]
            out.append(Msg(id: "\(pfx)g\(gi)", role: "agent", root: root, fallback: g.fallback))
        }

        // 审批:每次请求 = 一条独立记录 = 一张独立卡(id 带轮内序号)。
        // 决定后卡片原地变「已允许/已拒绝」;同轮再次审批 → 追加新卡,不复用旧卡。
        var recs = permRecords[sid] ?? []
        if pending.pendingIDs.contains(sid) {
            if let i = recs.indices.last, recs[i].decision == nil, recs[i].pfx == pfx {
                // 同一请求仍在挂起:刷新命令详情即可
                if let td = e.toolDetail { recs[i].detail = td }
            } else {
                let idx = recs.filter { $0.pfx == pfx }.count
                recs.append(PermRecord(pfx: pfx, idx: idx, detail: e.toolDetail, decision: nil))
            }
        } else if let i = recs.indices.last, recs[i].decision == nil {
            // 不再挂起且没有决定事件(连接被丢弃,如会话结束)→ 标记失效
            recs[i].decision = "expired"
        }
        permRecords[sid] = recs
        for r in recs where r.pfx == pfx {
            if let d = r.decision {
                out.append(Msg(id: "\(pfx)perm\(r.idx)", role: "agent",
                               root: permResolvedCard(detail: r.detail, decision: d),
                               fallback: d == "allow" ? "已允许" : "已拒绝"))
            } else {
                out.append(Msg(id: "\(pfx)perm\(r.idx)", role: "agent",
                               root: permCard(detail: r.detail, sid: sid), fallback: "需要批准"))
            }
        }
        if recs.contains(where: { $0.pfx == pfx }) {
            // 有审批卡时不再追加 waiting 提示
        } else if out.isEmpty, case .waiting(let msg) = e.state {
            out.append(Msg(id: "\(pfx)wait", role: "agent",
                           root: bubble(role: "agent", msg), fallback: msg))
        }
        return out
    }

    /// 待批准卡(允许/拒绝)。
    private func permCard(detail: String?, sid: String) -> [String: Any] {
        var kids: [[String: Any]] = [text("请求执行以下命令:", color: "secondary", style: "caption")]
        if let detail { kids.append(code(detail)) }
        kids.append([
            "type": "button_group",
            "props": ["buttons": [
                button(label: "拒绝", style: "default", actionId: "perm_deny", value: sid),
                button(label: "允许", style: "danger", actionId: "perm_allow", value: sid)
            ]]
        ])
        return card(title: "需要你处理", icon: "exclamationmark.circle.fill", style: "danger", children: kids)
    }

    /// 已处理的审批卡:按钮换成结果徽标,卡片留在历史里。
    private func permResolvedCard(detail: String?, decision: String) -> [String: Any] {
        let (label, color, icon, style): (String, String, String, String)
        switch decision {
        case "allow":   (label, color, icon, style) = ("✓ 已允许", "success", "checkmark.circle.fill", "default")
        case "deny":    (label, color, icon, style) = ("✕ 已拒绝", "danger", "xmark.circle.fill", "default")
        case "timeout": (label, color, icon, style) = ("已超时,按默认流程处理", "secondary", "clock.fill", "default")
        default:        (label, color, icon, style) = ("已失效", "secondary", "minus.circle.fill", "default")
        }
        var kids: [[String: Any]] = [text("请求执行以下命令:", color: "secondary", style: "caption")]
        if let detail { kids.append(code(detail)) }
        kids.append(badge(label, color: color))
        return card(title: "审批请求", icon: icon, style: style, children: kids)
    }

    /// 读不到图时:把 [Image …] 换成简洁标记。
    private func cleanPrompt(_ p: String) -> String {
        cap(p.replacingOccurrences(of: #"\[Image[^\]]*\]"#, with: "📷 [图片]", options: .regularExpression), 1000)
    }

    /// 把 [Image …] 整段去掉(已用缩略图展示时)。
    private func stripImages(_ p: String) -> String {
        p.replacingOccurrences(of: #"\[Image[^\]]*\]"#, with: "", options: .regularExpression)
    }

    /// 从 prompt 抽出粘贴图片的本地路径。Claude Code 真实格式是 `[Image #N]`(只有编号),
    /// 图片实际在 `~/.claude/image-cache/<sessionId>/<N>.<ext>`,据此构造路径。
    /// 兼容带显式路径的 `[Image: source: /path]` 与裸路径。
    private func extractImagePaths(_ p: String, sessionId: String) -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        let cacheDir = NSString(string: "~/.claude/image-cache").expandingTildeInPath + "/" + sessionId

        // 1) [Image #N] → image-cache/<sid>/N.<ext>
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

        // 2) 兜底:显式路径
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

    private func imageComp(data: String, source: String) -> [String: Any] {
        ["type": "image", "props": [
            "data": data, "mime": "image/jpeg",
            "source": source, "name": (source as NSString).lastPathComponent
        ]]
    }

    static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"; return f
    }()
    static func humanSize(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
        return "\(bytes) B"
    }

    /// 读图 → 缩略图(最长边 640)→ JPEG → base64。结果缓存,避免重复编码。
    private func thumbnailBase64(path: String, maxDim: CGFloat = 640) -> String? {
        if let cached = imageCache[path] { return cached }
        let result: String? = {
            guard let img = NSImage(contentsOfFile: path), img.size.width > 0 else { return nil }
            let s = img.size
            let scale = min(1, maxDim / max(s.width, s.height))
            let w = Int(s.width * scale), h = Int(s.height * scale)
            guard w > 0, h > 0,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = NSSize(width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
            return jpeg.base64EncodedString()
        }()
        imageCache[path] = result   // 缓存(含 nil,失败也不再重试)
        return result
    }

    // MARK: - 下行:摄入 action

    private func ingest(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let t = obj["t"] as? String
        if t == "pong" { lastPongAt = Date(); return }
        guard t == "input" || t == "action" else { return }

        // 可靠投递:回 delivered 级 ack;按帧 id 去重(重发的帧只 ack 不重复执行,
        // 杜绝重复注入终端/重复审批)。
        if let fid = obj["id"] as? String, !fid.isEmpty {
            sendJSON(["v": 1, "t": "ack", "id": "ack_\(fid)", "from": "agent",
                      "body": ["ack_id": fid, "stage": "delivered"]])
            if seenFrameIds.contains(fid) { return }
            seenFrameIds.insert(fid)
            seenFrameOrder.append(fid)
            if seenFrameOrder.count > 500 {
                seenFrameIds.remove(seenFrameOrder.removeFirst())
            }
        }

        if t == "input" {
            ingestInput(obj)
            return
        }
        guard let body = obj["body"] as? [String: Any] else { return }
        let actionId = body["action_id"] as? String ?? ""
        // sid 优先取 value;回退用 msg_id("sess:<sid>")
        let sid = (body["value"] as? String)
            ?? (body["msg_id"] as? String).map { $0.replacingOccurrences(of: "msg:", with: "") }
            ?? ""
        guard !sid.isEmpty else { return }
        switch actionId {
        case "perm_allow":    onRemoteDecision?(sid, .allow)
        case "perm_deny":     onRemoteDecision?(sid, .deny)
        case "session_close": onRemoteClose?(sid)
        default: break
        }
    }

    /// 手机输入帧:{kind:"text"|"image", text, images:[{data,ext}]}。
    /// 图片落盘到 ~/.vibenotch/inbox/<sid>/,路径交给 AppDelegate 一并注入终端。
    private func ingestInput(_ obj: [String: Any]) {
        guard let sid = obj["sid"] as? String,
              let body = obj["body"] as? [String: Any] else { return }
        let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var paths: [String] = []
        if let images = body["images"] as? [[String: Any]] {
            let dir = (NSString(string: "~/.vibenotch/inbox/\(sid)")).expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (i, img) in images.enumerated() {
                guard let b64 = img["data"] as? String,
                      let data = Data(base64Encoded: b64) else { continue }
                let ext = (img["ext"] as? String ?? "jpg").lowercased()
                let path = "\(dir)/\(Int(Date().timeIntervalSince1970))_\(i).\(ext)"
                guard FileManager.default.createFile(atPath: path, contents: data) else { continue }
                paths.append(path)
            }
        }
        guard !text.isEmpty || !paths.isEmpty else { return }
        onRemoteInput?(sid, text, paths)
    }

    // MARK: - 收发底层

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg { self.ingest(s) }
                    self.receiveLoop()
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        retry += 1
        let delay = min(pow(2.0, Double(retry)), 30)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.connect()
        }
    }

    /// 应用层心跳:25s 一次 ping;70s 没收到 pong 视为僵死连接,强制重建。
    /// (半开连接下 TCP 发送不报错,只有靠心跳能发现。)
    private func startHeartbeat() {
        lastPongAt = Date()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPongAt) > 70 {
                    vlog("relay heartbeat: pong 超时,重建连接")
                    self.task?.cancel(with: .goingAway, reason: nil)
                    self.scheduleReconnect()
                    return
                }
                self.sendJSON(["v": 1, "t": "ping", "id": "p_agent",
                               "ts": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private func send(_ json: String) {
        guard !json.isEmpty else { return }
        task?.send(.string(json)) { err in
            if let err { vlog("relay send error: \(err)") }
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        send(s)
    }

    // MARK: - 组件构造小工具

    private func card(title: String, icon: String, style: String,
                      collapsible: Bool = false, collapsed: Bool = false,
                      children: [[String: Any]]) -> [String: Any] {
        var props: [String: Any] = ["title": title, "icon": icon, "style": style]
        if collapsible { props["collapsible"] = true; props["collapsed"] = collapsed }
        return ["type": "card", "props": props, "children": children]
    }

    private func text(_ s: String, color: String? = nil, mono: Bool = false,
                      bold: Bool = false, fill: Bool? = nil, markdown: Bool = false,
                      style: String = "body") -> [String: Any] {
        var props: [String: Any] = ["text": s, "style": style]
        if let color { props["color"] = color }
        if mono { props["mono"] = true }
        if bold { props["bold"] = true }
        if let fill { props["fill"] = fill }
        if markdown { props["markdown"] = true }
        return ["type": "text", "props": props]
    }

    private func bubble(role: String, _ s: String) -> [String: Any] {
        ["type": "bubble", "props": ["role": role, "text": s]]
    }

    /// 文件改动 → `file` 语义组件(路径 + 新增行数 + diff hunks);客户端按设计稿渲染。
    private func fileComp(path: String, hunks: [[String: String]]) -> [String: Any] {
        let adds = hunks.filter { $0["op"] == "add" }.count
        return ["type": "file", "props": [
            "path": path,
            "additions": adds,
            "hunks": Array(hunks.prefix(80))
        ]]
    }

    /// 运行命令 → `command` 语义组件。
    private func commandComp(_ cmd: String) -> [String: Any] {
        ["type": "command", "props": ["command": cap(cmd, 400)]]
    }

    private func cap(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }

    /// 工具调用 chip(Read/Grep 等)→ 紧凑 `toolchip` 组件,手机端无头像、不占满行。
    private func toolChipComp(name: String, input: String?) -> [String: Any] {
        var props: [String: Any] = ["name": name, "color": toolColor(name)]
        if let input, !input.trimmingCharacters(in: .whitespaces).isEmpty {
            props["input"] = cap(input, 100)
        }
        return ["type": "toolchip", "props": props]
    }

    private func toolColor(_ name: String) -> String {
        switch name {
        case "Bash":                       return "orange"
        case "Edit", "Write", "MultiEdit": return "green"
        case "Read", "NotebookEdit":       return "blue"
        case "Grep", "Glob":               return "purple"
        case "WebFetch", "WebSearch":      return "gold"
        default:                            return "secondary"
        }
    }

    private func badge(_ s: String, color: String) -> [String: Any] {
        ["type": "badge", "props": ["text": s, "color": color]]
    }

    private func code(_ s: String) -> [String: Any] {
        ["type": "code", "props": ["code": s, "language": "bash"]]
    }

    private func button(label: String, style: String, actionId: String, value: String) -> [String: Any] {
        ["type": "button",
         "props": ["label": label, "style": style],
         "action": ["id": actionId, "value": value]]
    }

}
