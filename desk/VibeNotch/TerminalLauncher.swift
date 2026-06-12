import AppKit

/// 在 Terminal.app 里新开窗口运行命令(手机「新建会话」用)。
/// 命令跑起来后,VibeNotch 的 hook 会捕获新 claude 会话,正常出现在手机上。
enum TerminalLauncher {

    static func run(command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        // 转义双引号与反斜杠,安全嵌入 AppleScript 字符串
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let apple = NSAppleScript(source: script) {
                apple.executeAndReturnError(&error)
            }
            if let error {
                vlog("launch terminal failed: \(error)")
                // 可能是「自动化」权限未授予 —— 触发系统授权弹窗
            }
        }
    }
}
