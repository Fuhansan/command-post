import Foundation

/// Tracks one in-flight HookConnection per session that is awaiting an
/// allow/deny decision. UI observes `pendingIDs` to know which rows render
/// the permission card.
@MainActor
final class PendingDecisionStore: ObservableObject {
    @Published private(set) var pendingIDs: Set<String> = []
    /// 每个会话最近一次审批的结果("allow"/"deny"/"timeout")。
    /// RelayAgent 据此把手机端的审批卡原地改成「已允许/已拒绝」,而不是让卡片消失。
    @Published private(set) var lastDecisions: [String: String] = [:]
    private var connections: [String: HookConnection] = [:]
    private var watchdogs: [String: Task<Void, Never>] = [:]

    /// Fired when a pending decision times out without user action. The
    /// connection is already dismissed (claude proceeds with empty stdout =
    /// its default permission flow). The callback should also clear the
    /// session's `.waiting` state so the notch can collapse normally.
    var onTimeout: ((String) -> Void)?

    /// How long to wait for a user decision before giving up.
    static let decisionTimeout: TimeInterval = 45

    func add(sid: String, conn: HookConnection) {
        // Replace any prior pending for the same session — claude can only have
        // one outstanding tool call per session at a time.
        connections[sid]?.dismiss()
        watchdogs[sid]?.cancel()
        connections[sid] = conn
        lastDecisions[sid] = nil   // 新一轮审批,清掉上次结果
        pendingIDs.insert(sid)
        watchdogs[sid] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.decisionTimeout * 1_000_000_000))
            guard let self else { return }
            guard self.connections[sid] === conn else { return }
            self.lastDecisions[sid] = "timeout"
            self.cancel(sid: sid)
            self.onTimeout?(sid)
        }
    }

    func resolve(sid: String, decision: PermissionDecision) {
        watchdogs[sid]?.cancel()
        watchdogs[sid] = nil
        guard let conn = connections.removeValue(forKey: sid) else { return }
        conn.respond(json: decision.hookOutput)
        if case .allow = decision { lastDecisions[sid] = "allow" } else { lastDecisions[sid] = "deny" }
        pendingIDs.remove(sid)
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
