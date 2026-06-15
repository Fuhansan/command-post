import Foundation
import Combine

/// 一个会话(任务)= 一个 claude 终端会话,按协议 `sid` 区分。
struct RelaySession: Identifiable {
    let id: String              // sid
    var title: String           // 项目名(cwd 末段)
    var terminal: String        // 终端/IDE 名
    var cwd: String             // 项目工作目录
    var subtitle: String        // prompt 摘要 / 当前活动
    var status: String          // idle | working | waiting | done | ended
    var needsAction: Bool       // 是否有待批准的命令
    var pendingKind: String     // ""|perm(待审批,可批量)|question(待选择,需进会话)
    var pendingDetail: String   // 待办摘要(命令 / 题目)
    var agentId: String         // 来自哪台电脑(多机同账号时区分;reset 按机清理)
    var messages: [UIMessage]   // 该会话的下行富消息
}

/// 应用级中转连接(单例,经 environmentObject 注入)。
/// 客户端唯一真实数据源,无任何本地模拟数据。下行按 `sid` 分组成多个任务。
@MainActor
final class RelayClient: ObservableObject {
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var sessions: [RelaySession] = []

    /// 中转地址。iOS 模拟器可直连宿主机 127.0.0.1;真机改成电脑的局域网 IP。
    // MARK: - 服务器地址(设置页只填 IP + 端口,其余固定拼接)

    static let hostKey = "relay.serverHost"
    static let portKey = "relay.serverPort"
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8090

    static var savedHost: String {
        UserDefaults.standard.string(forKey: hostKey) ?? defaultHost
    }
    static var savedPort: Int {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return p > 0 ? p : defaultPort
    }

    /// 由 IP/主机 + 端口拼出最终地址:ws://<host>:<port>/ws。
    static func buildURL(host: String, port: Int) -> URL? {
        let h = sanitizeHost(host)
        guard !h.isEmpty, (1...65535).contains(port) else { return nil }
        return URL(string: "ws://\(h):\(port)/ws")
    }

    /// 当前生效的服务器地址。
    static func currentURL() -> URL {
        buildURL(host: savedHost, port: savedPort) ?? URL(string: "ws://\(defaultHost):\(defaultPort)/ws")!
    }

    /// 清洗主机输入:容忍用户粘贴完整 URL —— 去掉 scheme、路径、自带端口。
    static func sanitizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ws://", "wss://", "http://", "https://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.lastIndex(of: ":"), !s.contains("]") { s = String(s[..<colon]) }   // 非 IPv6 时去掉端口
        return s
    }

    /// 连通性测试:握手 + WS 协议层 ping,返回是否可达与往返耗时。
    static func testServer(host: String, port: Int) async -> (ok: Bool, message: String) {
        guard let url = buildURL(host: host, port: port) else { return (false, "地址无效") }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let start = Date()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        task.sendPing { err in
                            if let err { cont.resume(throwing: err) } else { cont.resume() }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw URLError(.timedOut)
                }
                try await group.next()
                group.cancelAll()
            }
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            return (true, "连通正常 · \(ms)ms")
        } catch {
            return (false, "无法连接")
        }
    }

    private let ws = WebSocketClient()
    private var account: String?

    init() {
        ws.onFrame = { [weak self] frame in self?.ingest(frame) }
        ws.onConnect = { [weak self] in self?.sendAuth() }
        ws.$state.assign(to: &$connection)
    }

    // MARK: - 连接

    func connect(account: String) {
        guard self.account != account || connection == .disconnected else { return }
        self.account = account
        sessions = []
        agents = []
        ws.connect(to: Self.currentURL())
    }

    /// 设置页修改服务器地址后调用:断开并按新地址重连(沿用当前账号)。
    func reconnectToCurrentServer() {
        guard account != nil else { return }
        ws.disconnect()
        sessions = []
        agents = []
        ws.connect(to: Self.currentURL())
    }

    /// 手动断开(保留登录态与账号,不自动重连;设置页「重连」恢复)。
    func manualDisconnect() {
        ws.disconnect()
        sessions = []
        agents = []
    }

    func disconnect() {
        account = nil
        agents = []
        sessions = []
        ws.disconnect()
    }

    func session(id: String) -> RelaySession? {
        sessions.first { $0.id == id }
    }

    /// 跨会话待办数(通知 Tab 角标)。
    var pendingCount: Int { sessions.filter { !$0.pendingKind.isEmpty }.count }

    private func sendAuth() {
        guard let account else { return }
        let body = JSONValue.object([
            // 登录后的会话令牌:服务器优先据此解析账号(未登录回退 account 会合)
            "token": .string(AppState.sessionToken ?? "ios"),
            "account": .string(account),
            "device": .object([
                "id": .string("ios_device"),
                "platform": .string("ios"),
                "name": .string("我的 iPhone")
            ]),
            "caps": .object(["protocol": .number(1)])
        ])
        sendFrame(t: "auth", id: "h_ios", sid: nil, body: body)
    }

    // MARK: - 下行摄入

    private func ingest(_ frame: Frame) {
        switch frame.t {
        case .authOk:
            agents = Self.parseAgents(frame.body)
            flushPending()   // 重连成功 → 补发断线期间未确认的上行
        case .presence:  applyPresence(frame.body)
        case .ui:        applyUI(frame)
        case .patch:     applyPatch(frame)
        case .ack:       applyAck(frame)
        case .error:
            // 致命错误(如令牌失效被服务器拒绝)→ 停止自动重连,避免风暴;
            // 用户重新登录后会以新令牌重连。
            if frame.body?["fatal"]?.boolValue == true {
                ws.disconnect()
            }
        default:         break
        }
    }

    private static func parseAgents(_ body: JSONValue?) -> [AgentInfo] {
        var seen = Set<String>()
        var out: [AgentInfo] = []
        for a in body?["agents"]?.arrayValue ?? [] {
            let id = a.string("id")
            guard !id.isEmpty, seen.insert(id).inserted else { continue }   // 同 id 去重
            out.append(AgentInfo(id: id, name: a.string("name", default: "Agent"),
                                 online: a["online"]?.boolValue ?? true,
                                 suspended: a["suspended"]?.boolValue ?? false))
        }
        return out
    }

    /// 断开某台电脑(服务器挂起它并踢下线;它的会话随 reset/离线清除)。
    func suspendAgent(_ agent: AgentInfo) {
        sendFrame(t: "ctl", id: "ctl_\(UUID().uuidString)", sid: nil,
                  body: .object(["op": .string("agent_suspend"),
                                 "agent": .string(agent.id),
                                 "name": .string(agent.name)]))
        if let i = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[i] = AgentInfo(id: agent.id, name: agent.name, online: false, suspended: true)
        }
    }

    /// 恢复某台电脑:解除挂起 → 显示「重连中」,电脑下一次探测(≤10s)上线;
    /// 30s 仍未回来则落回离线(电脑可能根本没开机)。
    func resumeAgent(_ agent: AgentInfo) {
        sendFrame(t: "ctl", id: "ctl_\(UUID().uuidString)", sid: nil,
                  body: .object(["op": .string("agent_resume"),
                                 "agent": .string(agent.id)]))
        if let i = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[i] = AgentInfo(id: agent.id, name: agent.name,
                                  online: false, suspended: false, resuming: true)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self,
                  let i = self.agents.firstIndex(where: { $0.id == agent.id }),
                  self.agents[i].resuming, !self.agents[i].online else { return }
            self.agents[i].resuming = false   // 超时:显示离线
        }
    }

    private func applyPresence(_ body: JSONValue?) {
        guard let body, let id = body["agent_id"]?.stringValue else { return }
        let online = body["online"]?.boolValue ?? false
        let name = body["name"]?.stringValue
        if let idx = agents.firstIndex(where: { $0.id == id }) {
            // 离线且非挂起/非重连中 → 该电脑已下线,直接移除(不在列表里残留僵尸)
            if !online && !agents[idx].suspended && !agents[idx].resuming {
                agents.remove(at: idx)
            } else {
                let susp = online ? false : agents[idx].suspended
                let resuming = online ? false : agents[idx].resuming
                agents[idx] = AgentInfo(id: id, name: name ?? agents[idx].name,
                                        online: online, suspended: susp, resuming: resuming)
            }
        } else if online {
            agents.append(AgentInfo(id: id, name: name ?? id, online: true))
        }
        // 客户端隔离(双保险):电脑离线 → 它的会话立即移除,不再展示旧数据。
        // 服务端同时会代发该设备的 reset 并清快照;电脑重连后会全量重推。
        if !online {
            sessions.removeAll { $0.agentId == id }
        }
    }

    /// PROTOCOL §5 —— ui 帧按 `sid` 归入对应会话;`body.session` 为任务元信息(首页行用)。
    private func applyUI(_ frame: Frame) {
        guard let sid = frame.sid, let msg = UIMessage(frame: frame) else { return }
        let meta = frame.body?["session"]
        let idx = sessions.firstIndex(where: { $0.id == sid })
        var s = idx.map { sessions[$0] }
            ?? RelaySession(id: sid, title: "会话", terminal: "", cwd: "", subtitle: "",
                            status: "working", needsAction: false,
                            pendingKind: "", pendingDetail: "", agentId: "", messages: [])
        if let meta {
            s.agentId = meta["agent"]?.stringValue ?? s.agentId
            s.title = meta["title"]?.stringValue ?? s.title
            s.terminal = meta["terminal"]?.stringValue ?? s.terminal
            s.cwd = meta["cwd"]?.stringValue ?? s.cwd
            s.subtitle = meta["subtitle"]?.stringValue ?? s.subtitle
            s.status = meta["status"]?.stringValue ?? s.status
            s.needsAction = meta["needsAction"]?.boolValue ?? s.needsAction
            s.pendingKind = meta["pendingKind"]?.stringValue ?? s.pendingKind
            s.pendingDetail = meta["pendingDetail"]?.stringValue ?? s.pendingDetail
        }
        if msg.role == "user" {
            // 正式的用户消息(经 agent 从转录回传)到达 → 移除发送时的本地回显,
            // 否则同一条消息显示两遍(本地一条 + 正式一条)。发送失败的保留(重试入口)。
            s.messages.removeAll { $0.seq == .max && $0.role == "user" && $0.status != .failed }
        }
        if let mIdx = s.messages.firstIndex(where: { $0.id == msg.id }) {
            s.messages[mIdx] = msg
        } else {
            s.messages.append(msg)
        }
        if let idx { sessions[idx] = s } else { sessions.append(s) }
    }

    /// PROTOCOL §7 —— patch:
    /// op=remove + scope=session → 删整个会话;op=remove(带消息 id)→ 删该条消息;op=replace → 替换根组件。
    private func applyPatch(_ frame: Frame) {
        guard let body = frame.body else { return }
        let op = body.string("op", default: "replace")
        if op == "reset" {   // 某台电脑的 agent 重启/退出配对 → 只清它的会话(老格式不带 agent 则全清)
            if let agentId = body["agent"]?.stringValue, !agentId.isEmpty {
                sessions.removeAll { $0.agentId == agentId || $0.agentId.isEmpty }
            } else {
                sessions.removeAll()
            }
            return
        }
        guard let sid = frame.sid else { return }
        if op == "remove" {
            if body.string("scope") == "session" {
                sessions.removeAll { $0.id == sid }
            } else if let id = frame.id, let sIdx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[sIdx].messages.removeAll { $0.id == id }
            }
            return
        }
        guard let id = frame.id,
              let sIdx = sessions.firstIndex(where: { $0.id == sid }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == id }) else { return }
        if op == "replace", let value = body["value"] {
            sessions[sIdx].messages[mIdx].root = Component(json: value)
        }
    }

    // MARK: - 上行(都带所属会话 sid)

    func sendInput(text: String, sessionId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let frameId = "in_\(UUID().uuidString)"
        var msg = UIMessage(localUserText: trimmed)
        msg.status = .sending; msg.upstreamId = frameId
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].messages.append(msg)
        }
        sendReliable(t: "input", id: frameId, sid: sessionId, localMsgId: msg.id,
                     body: .object(["kind": .string("text"), "text": .string(trimmed)]))
    }

    /// 图文回显:即时在气泡里显示(缩略图,仅本地展示),先不发送。
    /// 返回本地消息 id,供图片上传完成后关联发送 / 更新投递状态。
    func beginImageEcho(thumbs: [StagedImagePayload], text: String, sessionId: String) -> String {
        var msg = UIMessage(localUserImages: thumbs, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        msg.status = .sending
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].messages.append(msg)
        }
        return msg.id
    }

    /// 图片上传换回 id 后,发送图文输入帧 —— 控制通道**只带图片 id**,不带 base64。
    /// 电脑端 VibeNotch 凭 id 经 HTTP 把图拉下来再注入。
    func sendImageRefs(refs: [(id: String, ext: String)], text: String, sessionId: String, localMsgId: String) {
        guard !refs.isEmpty else {
            // 全部上传失败 → 标记失败,气泡可手动重发(此时无 pendingFrame,重发走重新上传由 UI 兜底)
            setStatus(.failed, localMsgId: localMsgId, sessionId: sessionId)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameId = "in_\(UUID().uuidString)"
        // 把上行帧 id 记到回显消息上(重发/对账用)
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == localMsgId }) {
            sessions[sIdx].messages[mIdx].upstreamId = frameId
        }
        sendReliable(t: "input", id: frameId, sid: sessionId, localMsgId: localMsgId,
                     body: .object([
                       "kind": .string("image"),
                       "text": .string(trimmed),
                       "images": .array(refs.map { .object(["id": .string($0.id), "ext": .string($0.ext)]) })
                     ]))
    }

    /// 新建会话:请求电脑端开一个 Terminal.app 窗口运行命令(默认 claude)。
    /// 命令跑起来后,新 claude 会话会经 hook 正常出现在任务列表。
    func launchCommand(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        sendReliable(t: "action", id: "act_\(UUID().uuidString)", sid: "system", localMsgId: nil,
                     body: .object([
                       "action_id": .string("launch_command"),
                       "value": .string(cmd)
                     ]))
    }

    /// 结束任务:请求电脑端关闭该 claude 会话(终止进程),随后会话经正常移除链路从手机消失。
    func endSession(sessionId: String) {
        sendReliable(t: "action", id: "act_\(UUID().uuidString)", sid: sessionId, localMsgId: nil,
                     body: .object([
                       "msg_id": .string("sess:\(sessionId)"),
                       "action_id": .string("session_close"),
                       "value": .string(sessionId)
                     ]))
    }

    func sendAction(_ action: ComponentAction, for messageId: String, sessionId: String) {
        var obj: [String: JSONValue] = [
            "msg_id": .string(messageId),
            "action_id": .string(action.id)
        ]
        if let v = action.value { obj["value"] = v }
        sendReliable(t: "action", id: "act_\(UUID().uuidString)", sid: sessionId,
                     localMsgId: nil, body: .object(obj))
    }

    /// 手动重发一条「发送失败」的消息(气泡上点重试)。
    func retryUpstream(messageId: String, sessionId: String) {
        guard let entry = pendingFrames.first(where: { $0.value.localMsgId == messageId }) else { return }
        var p = entry.value
        p.attempts = 0
        pendingFrames[entry.key] = p
        setStatus(.sending, localMsgId: messageId, sessionId: sessionId)
        transmit(entry.key)
    }

    // MARK: - 可靠上行(待确认队列 + 超时重发 + 两段 ack)

    /// 一条等待确认的上行帧。重发用同一帧 id —— agent 端按 id 幂等去重。
    private struct PendingFrame {
        let text: String          // 已序列化的帧原文
        let sessionId: String
        let localMsgId: String?   // 关联的本地回显消息(状态展示)
        var attempts: Int = 0
    }
    private var pendingFrames: [String: PendingFrame] = [:]
    private var ackTimeouts: [String: Task<Void, Never>] = [:]
    private static let maxAttempts = 3

    private func sendReliable(t: String, id: String, sid: String, localMsgId: String?, body: JSONValue) {
        guard let text = frameText(t: t, id: id, sid: sid, body: body) else { return }
        pendingFrames[id] = PendingFrame(text: text, sessionId: sid, localMsgId: localMsgId)
        transmit(id)
    }

    private func transmit(_ frameId: String) {
        guard var p = pendingFrames[frameId] else { return }
        p.attempts += 1
        pendingFrames[frameId] = p
        ws.sendRaw(p.text)
        scheduleAckTimeout(frameId, attempt: p.attempts)
    }

    /// 超时未收到 delivered ack → 重发(指数退避 5/10/20s);耗尽次数 → 标记失败。
    private func scheduleAckTimeout(_ frameId: String, attempt: Int) {
        ackTimeouts[frameId]?.cancel()
        let delay = 5.0 * pow(2.0, Double(attempt - 1))
        ackTimeouts[frameId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, let p = self.pendingFrames[frameId] else { return }
            if p.attempts >= Self.maxAttempts {
                self.ackTimeouts[frameId] = nil
                if let mid = p.localMsgId { self.setStatus(.failed, localMsgId: mid, sessionId: p.sessionId) }
                // pendingFrames 保留,供手动重试
            } else {
                self.transmit(frameId)
            }
        }
    }

    /// 处理服务器/代理端回的 ack:server 级 → 单勾;delivered 级 → 双勾并出队。
    private func applyAck(_ frame: Frame) {
        guard let ackId = frame.body?["ack_id"]?.stringValue,
              let p = pendingFrames[ackId] else { return }
        let stage = frame.body?["stage"]?.stringValue ?? "server"
        if stage == "delivered" {
            ackTimeouts[ackId]?.cancel(); ackTimeouts[ackId] = nil
            pendingFrames[ackId] = nil
            if let mid = p.localMsgId { setStatus(.delivered, localMsgId: mid, sessionId: p.sessionId) }
        } else {
            if let mid = p.localMsgId { setStatus(.sent, localMsgId: mid, sessionId: p.sessionId) }
        }
    }

    /// 重连认证成功后补发所有未确认的上行(重置重试次数)。
    private func flushPending() {
        for id in pendingFrames.keys {
            pendingFrames[id]?.attempts = 0
            transmit(id)
        }
    }

    private func setStatus(_ status: DeliveryStatus, localMsgId: String, sessionId: String) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == localMsgId }) else { return }
        sessions[sIdx].messages[mIdx].status = status
    }

    // MARK: - 出站封装

    private func frameText(t: String, id: String, sid: String?, body: JSONValue) -> String? {
        guard let bodyData = try? JSONEncoder().encode(body),
              let bodyStr = String(data: bodyData, encoding: .utf8) else { return nil }
        let sidPart = sid.map { "\"sid\":\"\($0)\"," } ?? ""
        return "{\"v\":1,\"t\":\"\(t)\",\"id\":\"\(id)\",\(sidPart)\"from\":\"client\",\"body\":\(bodyStr)}"
    }

    private func sendFrame(t: String, id: String, sid: String?, body: JSONValue) {
        if let text = frameText(t: t, id: id, sid: sid, body: body) { ws.sendRaw(text) }
    }
}
