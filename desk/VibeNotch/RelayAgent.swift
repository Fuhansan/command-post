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
    static let account = "demo"
    // 每个 claude 会话(终端)= 一个独立协议 sid = entry.id → 手机端分成多个任务。

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
    private var retry = 0
    private var started = false

    init(store: SessionStore, pending: PendingDecisionStore) {
        self.store = store
        self.pending = pending
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        // 任一会话/待决变化 → 同步到服务器
        store.$sessions
            .sink { [weak self] _ in self?.syncToServer() }
            .store(in: &cancellables)
        pending.$pendingIDs
            .sink { [weak self] _ in self?.syncToServer() }
            .store(in: &cancellables)
        connect()
    }

    func stop() {
        cancellables.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        started = false
    }

    // MARK: - 连接 / 鉴权

    private func connect() {
        let t = session.webSocketTask(with: Self.relayURL)
        task = t
        t.resume()
        receiveLoop()
        sendAuth()
        retry = 0
        lastSent.removeAll()
        knownSids.removeAll()
        syncToServer()   // 连上后补发当前所有会话
    }

    private func sendAuth() {
        let name = Host.current().localizedName ?? "工作 Mac"
        sendJSON([
            "v": 1, "t": "auth", "id": "h_agent", "from": "agent",
            "body": [
                "token": "agent",
                "account": Self.account,
                "device": ["id": "agent_mac", "platform": "mac", "name": name],
                "caps": ["protocol": 1]
            ]
        ])
    }

    // MARK: - 上行:会话 → 协议组件

    /// 每个会话 → **多条独立消息**(prompt / 每句 AI 文本 / 每个文件 / 每条命令 / 待批准),
    /// 各自一条 `ui` 帧。手机端据此渲染成真正的对话:每条消息独立一行、各带头像。
    private func syncToServer() {
        let activeSids = Set(store.sessions.map(\.id))
        // 整会话消失 → 删除该会话所有消息
        for sid in knownSids where !activeSids.contains(sid) {
            sendSessionRemove(sid: sid)
            for k in Array(lastSent.keys) where k.hasPrefix("m:\(sid):") { lastSent[k] = nil }
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
                let body: [String: Any] = ["role": m.role, "session": meta, "root": m.root]
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

    /// 任务元信息 —— 手机首页任务行用(title/副标题/状态/是否需处理)。
    private func sessionMeta(_ e: SessionEntry) -> [String: Any] {
        let isPending = pending.pendingIDs.contains(e.id)
        let subtitle = e.promptSummary ?? e.toolDetail ?? e.lastReplyBlock ?? ""
        return [
            "title": e.terminal.displayName,
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

        // 用户 prompt:先把粘贴的图片渲染成缩略图消息,再发去掉图片引用后的文本气泡。
        if let p = e.promptSummary, !p.isEmpty {
            let imgs = extractImagePaths(p)
            var shownImage = false
            for (k, path) in imgs.enumerated() {
                if let data = thumbnailBase64(path: path) {
                    shownImage = true
                    out.append(Msg(id: "\(pfx)img\(k)", role: "user",
                                   root: imageComp(data: data, source: path), fallback: "图片"))
                }
            }
            let textOnly = (shownImage ? stripImages(p) : cleanPrompt(p))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !textOnly.isEmpty {
                out.append(Msg(id: "\(pfx)prompt", role: "user",
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

        // 待批准命令
        if pending.pendingIDs.contains(sid) {
            out.append(Msg(id: "\(pfx)pending", role: "agent", root: permCard(e), fallback: "需要批准"))
        } else if out.isEmpty, case .waiting(let msg) = e.state {
            out.append(Msg(id: "\(pfx)wait", role: "agent",
                           root: bubble(role: "agent", msg), fallback: msg))
        }
        return out
    }

    /// 待批准卡(允许/拒绝)。
    private func permCard(_ e: SessionEntry) -> [String: Any] {
        var kids: [[String: Any]] = [text("请求执行以下命令:", color: "secondary", style: "caption")]
        if let td = e.toolDetail { kids.append(code(td)) }
        kids.append([
            "type": "button_group",
            "props": ["buttons": [
                button(label: "拒绝", style: "default", actionId: "perm_deny", value: e.id),
                button(label: "允许", style: "danger", actionId: "perm_allow", value: e.id)
            ]]
        ])
        return card(title: "需要你处理", icon: "exclamationmark.circle.fill", style: "danger", children: kids)
    }

    /// 读不到图时:把 [Image: …] 换成简洁标记。
    private func cleanPrompt(_ p: String) -> String {
        cap(p.replacingOccurrences(of: #"\[Image:[^\]]*\]"#, with: "📷 [图片]", options: .regularExpression), 1000)
    }

    /// 把 [Image: …] 整段去掉(已用缩略图展示时)。
    private func stripImages(_ p: String) -> String {
        p.replacingOccurrences(of: #"\[Image:[^\]]*\]"#, with: "", options: .regularExpression)
    }

    /// 从 prompt 抽出粘贴图片的本地路径(`[Image: source: /path]` 或 image-cache 路径)。
    private func extractImagePaths(_ p: String) -> [String] {
        var paths: [String] = []
        let patterns = [#"\[Image:[^\]]*?source:\s*([^\]\s]+)\]"#,
                        #"(/[^\s\]]+?\.(?:png|jpe?g|gif|webp|heic))"#]
        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            let ns = p as NSString
            for m in re.matches(in: p, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let path = ns.substring(with: m.range(at: 1))
                if !paths.contains(path) { paths.append(path) }
            }
            if !paths.isEmpty { break }   // 优先用 [Image:] 格式,命中就不再用宽松匹配
        }
        return paths
    }

    private func imageComp(data: String, source: String) -> [String: Any] {
        ["type": "image", "props": [
            "data": data, "mime": "image/jpeg",
            "source": source, "name": (source as NSString).lastPathComponent
        ]]
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
        guard (obj["t"] as? String) == "action",
              let body = obj["body"] as? [String: Any] else { return }
        let actionId = body["action_id"] as? String ?? ""
        // sid 优先取 value;回退用 msg_id("sess:<sid>")
        let sid = (body["value"] as? String)
            ?? (body["msg_id"] as? String).map { $0.replacingOccurrences(of: "msg:", with: "") }
            ?? ""
        guard !sid.isEmpty else { return }
        switch actionId {
        case "perm_allow": onRemoteDecision?(sid, .allow)
        case "perm_deny":  onRemoteDecision?(sid, .deny)
        default: break
        }
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
        retry += 1
        let delay = min(pow(2.0, Double(retry)), 30)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.connect()
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
