import Combine
import Darwin
import Foundation

struct SessionTransition {
    let sessionId: String
    let from: SessionState?
    let to: SessionState
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionEntry] = []
    let transitions = PassthroughSubject<SessionTransition, Never>()

    /// Sessions with no event/transcript activity for longer than this are
    /// auto-removed by `pruneIdle` — covers terminals (e.g. PyCharm) that
    /// were quit without firing a SessionEnd hook.
    static let idleRemovalSeconds: TimeInterval = 2 * 60 * 60

    func apply(_ event: HookEvent) {
        guard let sid = event.sessionId else { return }
        let cwd = event.cwd ?? "?"
        let resolved = resolveTerminalFull(event: event)
        let terminal = resolved.kind
        let terminalPID = resolved.pid
        let prevState = sessions.first(where: { $0.id == sid })?.state

        // App restart safety: if no entry exists yet, try to backfill the
        // latest prompt from the transcript so the row doesn't show "Done"
        // alone after the user's older prompt fell off our memory.
        if !sessions.contains(where: { $0.id == sid }), let path = event.transcriptPath {
            if let prevPrompt = TranscriptReader.lastUserPrompt(transcriptPath: path) {
                let backfill = SessionEntry(
                    id: sid,
                    state: .idle,
                    cwd: cwd,
                    promptSummary: prevPrompt,
                    turnSteps: TranscriptReader.currentTurnSteps(transcriptPath: path),
                    toolDetail: nil,
                    terminal: terminal,
                    terminalPID: terminalPID,
                    startedAt: Date()
                )
                sessions.append(backfill)
            }
        }

        switch event.hookEventName {
        case "SessionStart":
            upsert(id: sid) { entry in
                if entry == nil {
                    entry = SessionEntry(
                        id: sid,
                        state: .idle,
                        cwd: cwd,
                        turnSteps: [],
                        toolDetail: nil,
                        terminal: terminal,
                        terminalPID: terminalPID,
                        startedAt: Date()
                    )
                } else {
                    entry?.terminal = terminal
                    if let p = terminalPID { entry?.terminalPID = p }
                }
            }

        case "UserPromptSubmit":
            vlog("UPS sid=\(sid.prefix(8)) prompt=\((event.prompt ?? "<nil>").prefix(40))")
            upsert(id: sid) { entry in
                let summary = event.prompt?.trimmedForDisplay()
                entry = ensure(entry, sid: sid, cwd: cwd, terminal: terminal, terminalPID: terminalPID)
                entry?.state = .working(currentTool: nil, since: Date())
                entry?.promptSummary = summary
                entry?.toolDetail = nil
                entry?.turnSteps = []  // new turn — discard last turn's reply
            }

        case "PreToolUse":
            upsert(id: sid) { entry in
                entry = ensure(entry, sid: sid, cwd: cwd, terminal: terminal, terminalPID: terminalPID)
                let since: Date = {
                    if case .working(_, let s) = entry?.state { return s }
                    return Date()
                }()
                entry?.toolDetail = formatToolDetail(name: event.toolName, input: event.toolInput)
                if let tool = event.toolName, PolicyConstants.dangerousTools.contains(tool) {
                    entry?.state = .waiting(message: "Run \(tool)?")
                } else {
                    entry?.state = .working(currentTool: event.toolName, since: since)
                }
            }

        case "PostToolUse":
            break

        case "Notification":
            upsert(id: sid) { entry in
                entry = ensure(entry, sid: sid, cwd: cwd, terminal: terminal, terminalPID: terminalPID)
                entry?.state = .waiting(message: event.message ?? "Waiting for input")
            }

        case "Stop":
            // Don't try to read transcript here — at Stop time the assistant
            // text is often not yet flushed. AppDelegate's reply-refresh
            // poller fills in `turnSteps` over the following seconds.
            // Keep `turnSteps` intact so the timeline persists after Stop.
            upsert(id: sid) { entry in
                entry = ensure(entry, sid: sid, cwd: cwd, terminal: terminal, terminalPID: terminalPID)
                entry?.state = .done(summary: "Done", finishedAt: Date())
                entry?.toolDetail = nil
            }

        case "SessionEnd":
            sessions.removeAll { $0.id == sid }

        default:
            break
        }

        // 记录 owner 进程(claude/shell 的 ppid),供异常退出检测用
        if let p = event.ppid, p > 1, let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].ownerPID = pid_t(p)
        }
        // 记录转录路径,供 RelayAgent 计算文件改动行数
        if let tp = event.transcriptPath, let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].transcriptPath = tp
        }

        touchActivity(sid: sid)

        if let updated = sessions.first(where: { $0.id == sid }), updated.state != prevState {
            transitions.send(
                SessionTransition(sessionId: sid, from: prevState, to: updated.state)
            )
        }
    }

    /// Replace the running ordered list of turn steps (text + tool use).
    func updateTurnSteps(sessionId: String, steps: [TurnStep]) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].turnSteps != steps else { return }
        sessions[idx].turnSteps = steps
        sessions[idx].lastActivityAt = Date()
    }

    /// Remove sessions idle for longer than `maxIdleSeconds`. Returns the IDs
    /// dropped so callers can clean up any per-session state (e.g. reply polls).
    @discardableResult
    func pruneIdle(maxIdleSeconds: TimeInterval) -> [String] {
        let cutoff = Date().addingTimeInterval(-maxIdleSeconds)
        let dropped = sessions.filter { $0.lastActivityAt < cutoff }.map(\.id)
        guard !dropped.isEmpty else { return [] }
        sessions.removeAll { dropped.contains($0.id) }
        return dropped
    }

    /// 移除「owner 进程已不存在」的会话 —— 处理终端被关/强杀、没有 SessionEnd 的异常退出。
    /// 三重保险,绝不误删正在用的会话:
    ///  1. 只看 ownerPID 已知的(未知不动);
    ///  2. 仅 `kill(pid,0)==ESRCH`(确知进程不存在,EPERM 等不算);
    ///  3. 且该会话最近 `minIdle` 秒内**没有任何活动**(刚收到事件的绝不删)。
    @discardableResult
    func removeDeadSessions(minIdle: TimeInterval = 12) -> [String] {
        let cutoff = Date().addingTimeInterval(-minIdle)
        let dead = sessions.filter { entry in
            guard let pid = entry.ownerPID else { return false }
            guard entry.lastActivityAt < cutoff else { return false }   // 最近还活跃 → 不删
            return kill(pid, 0) != 0 && errno == ESRCH                  // 进程确实不存在
        }.map(\.id)
        guard !dead.isEmpty else { return [] }
        sessions.removeAll { dead.contains($0.id) }
        return dead
    }

    private func touchActivity(sid: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }
        sessions[idx].lastActivityAt = Date()
    }

    /// Force a session to .working — used by AppDelegate after the user
    /// allowed/denied a permission so the row leaves the orange .waiting state.
    /// Emits a transition so AppDelegate's auto-expand logic stays consistent.
    func markRunning(sessionId: String, tool: String? = nil) {
        let prevState = sessions.first(where: { $0.id == sessionId })?.state
        upsert(id: sessionId) { entry in
            guard entry != nil else { return }
            let since: Date = {
                if case .working(_, let s) = prevState { return s }
                return Date()
            }()
            entry?.state = .working(currentTool: tool, since: since)
        }
        touchActivity(sid: sessionId)
        if let updated = sessions.first(where: { $0.id == sessionId }), updated.state != prevState {
            transitions.send(
                SessionTransition(sessionId: sessionId, from: prevState, to: updated.state)
            )
        }
    }

    private func resolveTerminal(event: HookEvent) -> TerminalKind {
        resolveTerminalFull(event: event).kind
    }

    private func resolveTerminalFull(event: HookEvent) -> (kind: TerminalKind, pid: pid_t?) {
        if let p = event.ppid, p > 1 {
            return ProcessUtils.findTerminal(startPid: pid_t(p))
        }
        return (.unknown, nil)
    }

    private func formatToolDetail(name: String?, input: ToolInputView?) -> String? {
        guard let name else { return nil }
        switch name {
        case "Edit", "Write", "Read", "NotebookEdit":
            if let p = input?.filePath ?? input?.path {
                return "\(name) \(shortenPath(p))"
            }
        case "Bash":
            if let cmd = input?.command {
                return cmd.trimmedForDisplay(maxLen: 60)
            }
        case "Grep":
            if let p = input?.pattern {
                return "Grep \(p.trimmedForDisplay(maxLen: 40))"
            }
        case "Glob":
            if let p = input?.pattern {
                return "Glob \(p)"
            }
        case "WebFetch":
            if let u = input?.url { return "WebFetch \(u)" }
        case "Task":
            if let pr = input?.prompt {
                return "Task: \(pr.trimmedForDisplay(maxLen: 50))"
            }
        default:
            break
        }
        return name
    }

    private func shortenPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        var s = p
        if s.hasPrefix(home) {
            s = "~" + s.dropFirst(home.count)
        }
        let parts = s.split(separator: "/")
        if parts.count > 4 {
            return "…/\(parts.suffix(3).joined(separator: "/"))"
        }
        return s
    }

    private func upsert(id: String, _ mutate: (inout SessionEntry?) -> Void) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            var existing: SessionEntry? = sessions[idx]
            mutate(&existing)
            if let updated = existing {
                sessions[idx] = updated
            } else {
                sessions.remove(at: idx)
            }
        } else {
            var fresh: SessionEntry? = nil
            mutate(&fresh)
            if let f = fresh {
                sessions.append(f)
            }
        }
    }

    private func ensure(_ entry: SessionEntry?, sid: String, cwd: String, terminal: TerminalKind = .unknown, terminalPID: pid_t? = nil) -> SessionEntry {
        if let e = entry { return e }
        return SessionEntry(
            id: sid,
            state: .idle,
            cwd: cwd,
            turnSteps: [],
            toolDetail: nil,
            terminal: terminal,
            terminalPID: terminalPID,
            startedAt: Date()
        )
    }
}

extension String {
    /// Trims leading/trailing whitespace + newlines but preserves the rest of
    /// the multiline content. Long bodies are capped so we don't keep huge
    /// transcripts in memory.
    func trimmedForDisplay(maxLen: Int = 4000) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLen { return trimmed }
        return String(trimmed.prefix(maxLen)) + "…"
    }
}
