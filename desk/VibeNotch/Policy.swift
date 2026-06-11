import Foundation

enum PolicyConstants {
    /// Tool names that, when invoked via PreToolUse, route through the notch
    /// for explicit allow/deny. Other tools fall through to claude's default
    /// permission flow (the App returns empty stdout).
    static let dangerousTools: Set<String> = ["Bash", "Write", "WebFetch"]
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
