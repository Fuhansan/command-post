import Foundation

/// 一条快捷斜杠指令(命令 + 说明,用于输入「/」时的气泡提示)。
struct QuickCommand: Identifiable {
    let cmd: String
    let desc: String
    var id: String { cmd }
}

/// 各 coding CLI 的客户端元数据:
///  - launchCommand:手机「+」新建会话时电脑端要跑的命令
///  - quickCommands:输入框打「/」时弹出的快捷指令,**仅放「直接执行型」**(点一下直接发送)。
///    像 /model /agents 这类会弹 TUI 选择器、手机没法导航的,暂不放进来。
///
/// 加新 CLI(aider 等)= 往 `all` 里加一条;会话按 `RelaySession.cli` 取对应这条。
struct CLIKind: Identifiable {
    let id: String              // "claude" | "codex" —— 与 Agent 下发的 cli 字段一致
    let displayName: String
    let launchCommand: String
    let quickCommands: [QuickCommand]

    static let all: [CLIKind] = [
        CLIKind(id: "claude", displayName: "Claude Code", launchCommand: "claude", quickCommands: [
            .init(cmd: "/clear",   desc: "清空对话上下文"),
            .init(cmd: "/compact", desc: "压缩上下文,避免超限"),
            .init(cmd: "/cost",    desc: "查看本次用量/花费"),
            .init(cmd: "/status",  desc: "查看当前状态"),
            .init(cmd: "/init",    desc: "生成 CLAUDE.md"),
            .init(cmd: "/help",    desc: "帮助"),
            .init(cmd: "/exit",    desc: "退出"),
        ]),
        CLIKind(id: "codex", displayName: "Codex", launchCommand: "codex", quickCommands: [
            .init(cmd: "/new",     desc: "开始新对话"),
            .init(cmd: "/init",    desc: "生成 AGENTS.md"),
            .init(cmd: "/compact", desc: "压缩上下文"),
            .init(cmd: "/diff",    desc: "查看 git diff"),
            .init(cmd: "/status",  desc: "查看当前状态"),
            .init(cmd: "/mcp",     desc: "查看 MCP 服务器"),
        ]),
    ]

    static func by(id: String) -> CLIKind? { all.first { $0.id == id } }
}
