import AppKit

/// 在 Terminal.app 里新开窗口运行命令(手机「新建会话」用)。
/// 命令跑起来后,VibeNotch 的 hook 会捕获新 claude 会话,正常出现在手机上。
enum TerminalLauncher {

    static func run(command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        // 干净的新终端 PATH 可能指不到装 claude/codex 的那个 nvm node 版本
        // (用户的工具常装在某个特定 node 版本里)→ 把所有 nvm 版本的 bin
        // 与常用工具目录都补进 PATH,保证 claude/codex 等能被找到。
        let full = "export PATH=\"\(extraPathPrefix())$PATH\"; \(cmd)"

        let escaped = full
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
                vlog("launch terminal failed: \(error)")   // 多半是「自动化」权限未授予
            }
        }
    }

    /// 所有 nvm node 版本的 bin + 常用工具目录,拼成 "a:b:c:" 前缀(末尾带冒号)。
    private static func extraPathPrefix() -> String {
        let home = NSHomeDirectory()
        var dirs: [String] = []

        // 所有 nvm node 版本的 bin(claude/codex 等可能装在任一版本里)
        let nvmVersions = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            for v in entries.sorted(by: >) {   // 新版本优先
                let bin = "\(nvmVersions)/\(v)/bin"
                if FileManager.default.fileExists(atPath: bin) { dirs.append(bin) }
            }
        }
        // 常用工具目录
        for d in ["/opt/homebrew/bin", "/usr/local/bin",
                  "\(home)/.local/bin", "\(home)/.cargo/bin"] {
            if FileManager.default.fileExists(atPath: d) { dirs.append(d) }
        }
        return dirs.isEmpty ? "" : dirs.joined(separator: ":") + ":"
    }
}
