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
    // MARK: - 服务器地址(可在设置页修改,存 UserDefaults)

    static let urlDefaultsKey = "relay.serverURL"
    static let defaultURLString = "ws://127.0.0.1:8090/ws"

    /// 当前生效的服务器地址(设置页保存的值,缺省回退默认)。
    static func currentURL() -> URL {
        let raw = UserDefaults.standard.string(forKey: urlDefaultsKey) ?? defaultURLString
        return URL(string: normalizeURL(raw)) ?? URL(string: defaultURLString)!
    }

    /// 宽容解析用户输入:`192.168.1.5` / `192.168.1.5:8090` / `ws://host/ws` /
    /// `wss://example.com` 都行——自动补全 ws:// 前缀、8090 端口、/ws 路径。
    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return defaultURLString }
        if !s.hasPrefix("ws://") && !s.hasPrefix("wss://") { s = "ws://" + s }
        guard var comp = URLComponents(string: s) else { return defaultURLString }
        if comp.port == nil { comp.port = 8090 }
        if comp.path.isEmpty || comp.path == "/" { comp.path = "/ws" }
        return comp.string ?? defaultURLString
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

    func disconnect() {
        account = nil
        agents = []
        sessions = []
        ws.disconnect()
    }

    func session(id: String) -> RelaySession? {
        sessions.first { $0.id == id }
    }

    private func sendAuth() {
        guard let account else { return }
        let body = JSONValue.object([
            "token": .string("ios"),
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
        default:         break
        }
    }

    private static func parseAgents(_ body: JSONValue?) -> [AgentInfo] {
        (body?["agents"]?.arrayValue ?? []).map {
            AgentInfo(id: $0.string("id"), name: $0.string("name", default: "Agent"),
                      online: $0["online"]?.boolValue ?? true)
        }
    }

    private func applyPresence(_ body: JSONValue?) {
        guard let body, let id = body["agent_id"]?.stringValue else { return }
        let online = body["online"]?.boolValue ?? false
        let name = body["name"]?.stringValue
        if let idx = agents.firstIndex(where: { $0.id == id }) {
            agents[idx] = AgentInfo(id: id, name: name ?? agents[idx].name, online: online)
        } else if online {
            agents.append(AgentInfo(id: id, name: name ?? id, online: true))
        }
    }

    /// PROTOCOL §5 —— ui 帧按 `sid` 归入对应会话;`body.session` 为任务元信息(首页行用)。
    private func applyUI(_ frame: Frame) {
        guard let sid = frame.sid, let msg = UIMessage(frame: frame) else { return }
        let meta = frame.body?["session"]
        let idx = sessions.firstIndex(where: { $0.id == sid })
        var s = idx.map { sessions[$0] }
            ?? RelaySession(id: sid, title: "会话", terminal: "", cwd: "", subtitle: "",
                            status: "working", needsAction: false, messages: [])
        if let meta {
            s.title = meta["title"]?.stringValue ?? s.title
            s.terminal = meta["terminal"]?.stringValue ?? s.terminal
            s.cwd = meta["cwd"]?.stringValue ?? s.cwd
            s.subtitle = meta["subtitle"]?.stringValue ?? s.subtitle
            s.status = meta["status"]?.stringValue ?? s.status
            s.needsAction = meta["needsAction"]?.boolValue ?? s.needsAction
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
        if op == "reset" {   // agent 进程重启 → 清空全部会话,作废旧数据
            sessions.removeAll()
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

    /// 图文输入:图片(base64)+ 可选文字一起发往电脑端,注入对应终端。本地先回显一条图文气泡。
    func sendImageInput(images: [StagedImagePayload], text: String, sessionId: String) {
        guard !images.isEmpty else { return sendInput(text: text, sessionId: sessionId) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameId = "in_\(UUID().uuidString)"
        var msg = UIMessage(localUserImages: images, text: trimmed)
        msg.status = .sending; msg.upstreamId = frameId
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].messages.append(msg)
        }
        sendReliable(t: "input", id: frameId, sid: sessionId, localMsgId: msg.id,
                     body: .object([
                       "kind": .string("image"),
                       "text": .string(trimmed),
                       "images": .array(images.map { .object(["data": .string($0.data), "ext": .string($0.ext)]) })
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
