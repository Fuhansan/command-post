package com.aicodingremote.app.models

/**
 * 一条快捷斜杠指令(命令 + 说明,用于输入「/」时的气泡提示)。
 * 对位 iOS `QuickCommand`。
 */
data class QuickCommand(
    val cmd: String,
    val desc: String,
) {
    val id: String get() = cmd
}

/**
 * 各 coding CLI 的客户端元数据。对位 iOS `CLIKind`:
 *  - [launchCommand]:手机「+」新建会话时电脑端要跑的命令
 *  - [quickCommands]:输入框打「/」时弹出的快捷指令,**仅放「直接执行型」**(点一下直接发送)。
 *    像 /model /agents 这类会弹 TUI 选择器、手机没法导航的,暂不放进来。
 *
 * 加新 CLI(aider 等)= 往 [all] 里加一条;会话按 `RelaySession.cli` 取对应这条。
 */
data class CLIKind(
    val id: String,             // "claude" | "codex" —— 与 Agent 下发的 cli 字段一致
    val displayName: String,
    val launchCommand: String,
    val quickCommands: List<QuickCommand>,
) {
    companion object {
        val all: List<CLIKind> = listOf(
            CLIKind(
                id = "claude",
                displayName = "Claude Code",
                launchCommand = "claude",
                quickCommands = listOf(
                    QuickCommand("/clear",   "清空对话上下文"),
                    QuickCommand("/compact", "压缩上下文,避免超限"),
                    QuickCommand("/cost",    "查看本次用量/花费"),
                    QuickCommand("/status",  "查看当前状态"),
                    QuickCommand("/init",    "生成 CLAUDE.md"),
                    QuickCommand("/help",    "帮助"),
                    QuickCommand("/exit",    "退出"),
                ),
            ),
            CLIKind(
                id = "codex",
                displayName = "Codex",
                launchCommand = "codex",
                quickCommands = listOf(
                    QuickCommand("/new",     "开始新对话"),
                    QuickCommand("/init",    "生成 AGENTS.md"),
                    QuickCommand("/compact", "压缩上下文"),
                    QuickCommand("/diff",    "查看 git diff"),
                    QuickCommand("/status",  "查看当前状态"),
                    QuickCommand("/mcp",     "查看 MCP 服务器"),
                ),
            ),
        )

        fun by(id: String): CLIKind? = all.firstOrNull { it.id == id }
    }
}
