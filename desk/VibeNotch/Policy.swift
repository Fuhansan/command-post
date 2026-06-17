import Foundation

enum PolicyConstants {
    /// Tool names that, when invoked via PreToolUse, route through the notch
    /// for explicit allow/deny. Other tools fall through to claude's default
    /// permission flow (the App returns empty stdout).
    static let dangerousTools: Set<String> = ["Bash", "Write", "WebFetch"]

    /// 只读/安全工具:控制台会话里这些**不弹审批**(直接放行),避免 Read/Grep 频繁打断。
    /// 其余(Bash/Edit/Write/WebFetch/未知…)才弹审批。
    static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep", "LS", "WebSearch", "TodoWrite", "NotebookRead", "BashOutput"
    ]
}

enum PermissionDecision {
    case allow
    case deny

    /// JSON written back over the hook socket; claude reads this from stdout.
    var hookOutput: String {
        switch self {
        case .allow:
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#
        case .deny:
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied via VibeNotch"}}"#
        }
    }
}
