import Foundation
import Combine

// MARK: - 统一会话模型(上层唯一依赖,agent 无关)

/// 一条会话里的一条消息(统一)。Phase 1 先支撑文本/工具/文件三类,渲染细节 Phase 3 再丰富。
struct AgentMessage: Identifiable, Equatable {
    enum Kind: String { case text, tool, file }
    let id: String
    var role: String          // user / assistant / system
    var kind: Kind
    var text: String
    var ord: Int              // 逻辑顺序号(到达递增)
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

    static func == (l: AgentSession, r: AgentSession) -> Bool {
        l.id == r.id && l.status == r.status && l.messages == r.messages &&
        l.pending == r.pending && l.title == r.title && l.agentSessionId == r.agentSessionId
    }
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

    /// driver 工厂:按 agent 类型造对应适配器(codex 后续加分支)。
    private func makeDriver(_ agent: AgentKind) -> AgentDriver {
        switch agent {
        case .claude: return ClaudeStreamJSONDriver()
        case .codex:  return ClaudeStreamJSONDriver()   // TODO: CodexDriver(Phase 后续)
        }
    }

    /// 新建会话:spawn driver 子进程,开始消费事件。返回会话 id。
    @discardableResult
    func newSession(agent: AgentKind, workdir: String, resume: String? = nil) -> String {
        let sid = "s_\(Int(Date().timeIntervalSince1970 * 1000))_\(sessions.count)"
        let driver = makeDriver(agent)
        let title = (workdir as NSString).lastPathComponent
        sessions.append(AgentSession(id: sid, agent: agent, workdir: workdir, title: title,
                                     status: .starting, messages: [], pending: [], agentSessionId: nil))
        var m = Managed(driver: driver, consumeTask: nil)
        m.consumeTask = Task { [weak self] in
            for await ev in driver.events {
                await self?.apply(ev, to: sid)
            }
        }
        managed[sid] = m
        Task {
            do { try await driver.start(workdir: workdir, resume: resume) }
            catch { await self.apply(.error("启动失败: \(error)"), to: sid) }
        }
        return sid
    }

    func send(_ sid: String, text: String, imagePaths: [String] = []) {
        guard let d = managed[sid]?.driver else { return }
        // 本地立即回显用户消息
        mutate(sid) { s in s.messages.append(self.userEcho(text)) }
        d.send(UserInput(text: text, imagePaths: imagePaths))
    }

    func respond(_ sid: String, requestId: String, choose: [String]) {
        guard let d = managed[sid]?.driver else { return }
        mutate(sid) { s in s.pending.removeAll { $0.id == requestId } }
        d.respond(to: requestId, choose: choose)
    }

    func interrupt(_ sid: String) { managed[sid]?.driver.interrupt() }

    /// 手机回传:批准/拒绝该会话当前的权限待决项。
    func respondPermission(_ sid: String, allow: Bool) {
        guard let s = sessions.first(where: { $0.id == sid }),
              let req = s.pending.first(where: { $0.kind == .permission }) else { return }
        respond(sid, requestId: req.id, choose: [allow ? "allow" : "deny"])
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
        managed[sid]?.consumeTask?.cancel()
        managed[sid]?.driver.stop()
        managed[sid] = nil
        sessions.removeAll { $0.id == sid }
    }

    // MARK: - 事件 → 模型

    private func apply(_ ev: SessionEvent, to sid: String) {
        switch ev {
        case .status(let st):
            mutate(sid) { $0.status = st }
        case .sessionId(let aid):
            mutate(sid) { $0.agentSessionId = aid }
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
                if !s.pending.contains(where: { $0.id == req.id }) { s.pending.append(req) }
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
