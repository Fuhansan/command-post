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

    /// 黑名单策略:默认全放行,只有这几类危险命令才弹审批。
    /// 删除类(rm 等)。
    static let deleteCommands: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm"]

    /// 一条 Bash 命令是否「需要审批」。默认 false(放行);命中危险命令才 true。
    /// 危险:删除(rm/rmdir/unlink/shred)、git push、含 delete/--delete、install/uninstall。
    /// 对整条命令的所有 token 扫描(按空白与 shell 元字符切分),能抓到管道/替换/xargs 里藏的危险命令。
    static func bashNeedsApproval(_ command: String) -> Bool {
        let tokens = command
            .components(separatedBy: CharacterSet(charactersIn: " \t\n;|&()`\"'"))
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }
        for t in tokens {
            if deleteCommands.contains(t) { return true }
            if t == "install" || t == "uninstall" { return true }
            if t == "delete" || t == "--delete" || t == "-delete" { return true }
        }
        // git push(任意位置出现 git 且其后有 push)
        if tokens.contains("git") && tokens.contains("push") { return true }
        return false
    }
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
