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
    static let relayURL = URL(string: "ws://127.0.0.1:8090/ws")!

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
        ws.connect(to: Self.relayURL)
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
        case .authOk:    agents = Self.parseAgents(frame.body)
        case .presence:  applyPresence(frame.body)
        case .ui:        applyUI(frame)
        case .patch:     applyPatch(frame)
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
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].messages.append(UIMessage(localUserText: trimmed))
        }
        sendFrame(t: "input", id: "in_\(UUID().uuidString)", sid: sessionId,
                  body: .object(["kind": .string("text"), "text": .string(trimmed)]))
    }

    func sendAction(_ action: ComponentAction, for messageId: String, sessionId: String) {
        var obj: [String: JSONValue] = [
            "msg_id": .string(messageId),
            "action_id": .string(action.id)
        ]
        if let v = action.value { obj["value"] = v }
        sendFrame(t: "action", id: "act_\(UUID().uuidString)", sid: sessionId, body: .object(obj))
    }

    // MARK: - 出站封装

    private func sendFrame(t: String, id: String, sid: String?, body: JSONValue) {
        guard let bodyData = try? JSONEncoder().encode(body),
              let bodyStr = String(data: bodyData, encoding: .utf8) else { return }
        let sidPart = sid.map { "\"sid\":\"\($0)\"," } ?? ""
        ws.sendRaw("{\"v\":1,\"t\":\"\(t)\",\"id\":\"\(id)\",\(sidPart)\"from\":\"client\",\"body\":\(bodyStr)}")
    }
}
