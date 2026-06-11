import Foundation

enum SessionState: Equatable {
    case idle
    case working(currentTool: String?, since: Date)
    case waiting(message: String)
    case done(summary: String, finishedAt: Date)
}

/// One ordered milestone within a turn: either a chunk of assistant prose, or
/// a tool invocation. The DetailCard renders these in order so the user sees
/// the full timeline (text → Bash(cmd) → text → Edit(file) → …).
enum TurnStep: Equatable {
    case text(String)
    case tool(name: String, input: String?)
}

struct SessionEntry: Identifiable, Equatable {
    let id: String
    var state: SessionState
    var cwd: String
    var promptSummary: String?
    var transcriptPath: String? = nil   // 当前会话转录路径(算文件改动 +N 行数用)
    var turnSteps: [TurnStep]
    var toolDetail: String?
    var terminal: TerminalKind
    var terminalPID: pid_t?
    /// claude/shell 进程 pid(= hook 的 $PPID)。终端被关/强杀时它会消失,
    /// 用于「无 SessionEnd 的异常退出」检测(见 SessionStore.removeDeadSessions)。
    var ownerPID: pid_t? = nil
    var startedAt: Date
    var lastActivityAt: Date = Date()

    /// Compact-row display — the most recent text block, for line 2.
    var lastReplyBlock: String? {
        for step in turnSteps.reversed() {
            if case .text(let s) = step { return s }
        }
        return nil
    }
}
