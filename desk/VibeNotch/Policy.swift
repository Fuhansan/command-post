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

    /// 安全的只读 Bash 命令名:全局自动放行,不弹审批(导航/查看类,不改文件、不联网)。
    static let safeBashCommands: Set<String> = [
        "cd", "ls", "pwd", "echo", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg",
        "find", "which", "type", "file", "stat", "du", "df", "env", "printenv", "date", "whoami",
        "hostname", "uname", "tree", "basename", "dirname", "realpath", "sort", "uniq", "cut",
        "tr", "column", "nl", "tac", "less", "more", "true", "false", "test"
    ]
    /// 安全的 git 子命令(只读)。
    static let safeGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "branch", "remote", "rev-parse", "describe",
        "blame", "ls-files", "shortlog", "tag"
    ]

    /// 一条 Bash 命令是否「全是安全只读命令」→ 可全局自动放行。
    /// 按 shell 连接符(; | && ||)分段,每段首命令都得在白名单;含命令替换/写文件重定向则不放行。
    static func isSafeBashCommand(_ command: String) -> Bool {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return false }
        if cmd.contains("`") || cmd.contains("$(") || cmd.contains(">") { return false }
        let segments = cmd.components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return false }
        for seg in segments {
            let tokens = seg.split(separator: " ").map(String.init)
            guard let first = tokens.first else { return false }
            if first == "git" {
                guard let sub = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }),
                      safeGitSubcommands.contains(sub) else { return false }
            } else if !safeBashCommands.contains(first) {
                return false
            }
        }
        return true
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
