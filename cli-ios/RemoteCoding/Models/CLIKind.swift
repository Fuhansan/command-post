import Foundation

/// 各 coding CLI 的客户端元数据:
///  - launchCommand:手机「+」新建会话时电脑端要跑的命令
///  - quickCommands:会话里的快捷指令栏,**仅放「直接执行型」**(点一下直接发送)。
///    像 /model /agents /plugins 这类会弹 TUI 选择器、手机没法导航的,暂不放进来。
///
/// 加新 CLI(aider 等)= 往 `all` 里加一条;会话按 `RelaySession.cli` 取对应这条。
struct CLIKind: Identifiable {
    let id: String              // "claude" | "codex" —— 与 Agent 下发的 cli 字段一致
    let displayName: String
    let launchCommand: String
    let quickCommands: [String]

    static let all: [CLIKind] = [
        CLIKind(id: "claude", displayName: "Claude Code", launchCommand: "claude",
                quickCommands: ["/clear", "/compact", "/cost", "/status", "/help", "/init", "/exit"]),
        CLIKind(id: "codex", displayName: "Codex", launchCommand: "codex",
                quickCommands: ["/new", "/init", "/compact", "/diff", "/status", "/mcp"]),
    ]

    static func by(id: String) -> CLIKind? { all.first { $0.id == id } }
}
