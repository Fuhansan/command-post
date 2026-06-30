import Foundation

/// Tracks one in-flight HookConnection per session that is awaiting an
/// allow/deny decision. UI observes `pendingIDs` to know which rows render
/// the permission card.
@MainActor
final class PendingDecisionStore: ObservableObject {
    @Published private(set) var pendingIDs: Set<String> = []

    /// 决定事件流(追加式,带单调 seq)。RelayAgent 按 seq 消费,把对应的审批卡
    /// 改成「已允许/已拒绝/超时」。用事件流而非「最新状态」,是为了同一会话
    /// 连续多次审批时每一次的结果都不丢(新请求不会覆盖上一次的结果)。
    struct DecisionEvent { let seq: Int; let sid: String; let decision: String }
    @Published private(set) var decisionEvents: [DecisionEvent] = []
    private var decisionSeq = 0

    private func emitDecision(_ sid: String, _ decision: String) {
        decisionSeq += 1
        decisionEvents.append(DecisionEvent(seq: decisionSeq, sid: sid, decision: decision))
        if decisionEvents.count > 200 { decisionEvents.removeFirst(decisionEvents.count - 200) }
    }
    private var connections: [String: HookConnection] = [:]
    private var watchdogs: [String: Task<Void, Never>] = [:]

    /// Fired when a pending decision times out without user action. The
    /// connection is already dismissed (claude proceeds with empty stdout =
    /// its default permission flow). The callback should also clear the
    /// session's `.waiting` state so the notch can collapse normally.
    var onTimeout: ((String) -> Void)?

    /// How long to wait for a user decision before giving up. Keep this aligned with
    /// the hook script/settings timeout so desktop approval does not expire first.
    static let decisionTimeout: TimeInterval = 86_400

    func add(sid: String, conn: HookConnection) {
        // Replace any prior pending for the same session — claude can only have
        // one outstanding tool call per session at a time.
        connections[sid]?.dismiss()
        watchdogs[sid]?.cancel()
        connections[sid] = conn
        pendingIDs.insert(sid)
        watchdogs[sid] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.decisionTimeout * 1_000_000_000))
            guard let self else { return }
            guard self.connections[sid] === conn else { return }
            self.emitDecision(sid, "timeout")
            self.cancel(sid: sid)
            self.onTimeout?(sid)
        }
    }

    func detail(sid: String) -> String? {
        guard let event = connections[sid]?.event else { return nil }
        return event.toolInput?.command
            ?? event.toolInput?.filePath
            ?? event.toolInput?.path
            ?? event.toolInput?.url
            ?? event.toolName
    }

    @discardableResult
    func resolve(sid: String, decision: PermissionDecision) -> Bool {
        watchdogs[sid]?.cancel()
        watchdogs[sid] = nil
        guard let conn = connections.removeValue(forKey: sid) else { return false }
        let ok = conn.respond(json: decision.hookOutput)
        if ok {
            if case .allow = decision { emitDecision(sid, "allow") } else { emitDecision(sid, "deny") }
        } else {
            emitDecision(sid, "timeout")
        }
        pendingIDs.remove(sid)
        return ok
    }

    func cancel(sid: String) {
        watchdogs[sid]?.cancel()
        watchdogs[sid] = nil
        guard let conn = connections.removeValue(forKey: sid) else { return }
        conn.dismiss()
        pendingIDs.remove(sid)
    }

    func dismissAll() {
        for (_, w) in watchdogs { w.cancel() }
        watchdogs.removeAll()
        for (_, conn) in connections { conn.dismiss() }
        connections.removeAll()
        pendingIDs.removeAll()
    }

    func first() -> String? { pendingIDs.first }
}
