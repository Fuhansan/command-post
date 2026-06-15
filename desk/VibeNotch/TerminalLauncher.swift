import AppKit

/// 在 Terminal.app 里新开窗口运行命令(手机「新建会话」用)。
/// 命令跑起来后,VibeNotch 的 hook 会捕获新 claude 会话,正常出现在手机上。
enum TerminalLauncher {

    /// - command: 要运行的命令(如 claude)
    /// - workdir: 默认工作目录;非空时先 cd 进去再跑命令(命令自带 cd 则二者叠加,以命令为准)
    /// - proxy: 代理设置命令(如 export https_proxy=…),非空时在命令最前执行(大陆用户需要)
    static func run(command: String, workdir: String = "", proxy: String = "") {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        // 代理前缀(大陆用户跑 claude 要先设代理,否则连不上 Anthropic)
        let proxyTrim = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyPart = proxyTrim.isEmpty ? "" : "\(proxyTrim); "

        // 默认工作目录:展开 ~ 后 cd 进去(目录不存在则 shell 自然报错,不影响命令本身)
        let dir = (workdir as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cdPart = dir.isEmpty ? "" : "cd \(shellQuote(dir)); "

        // 预置信任:避免新会话卡在「Do you trust the files in this folder?」
        // (该提示早于 hook,手机接不到)。信任默认目录 + 命令里 cd 的目标。
        var trustDirs: [String] = []
        if !dir.isEmpty { trustDirs.append(dir) }
        if let cdTarget = leadingCdPath(in: cmd) { trustDirs.append(cdTarget) }
        ClaudeTrust.trust(directories: trustDirs)

        // 干净的新终端 PATH 可能指不到装 claude/codex 的那个 nvm node 版本
        // (用户的工具常装在某个特定 node 版本里)→ 把所有 nvm 版本的 bin
        // 与常用工具目录都补进 PATH,保证 claude/codex 等能被找到。
        // 顺序:代理 → PATH → cd → 命令
        let full = "\(proxyPart)export PATH=\"\(extraPathPrefix())$PATH\"; \(cdPart)\(cmd)"

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

    /// 从命令里抽出开头的 `cd <path>`(支持 `cd x &&` / `cd x;` / 单双引号包裹),
    /// 用于预置信任。抽不到返回 nil。
    private static func leadingCdPath(in command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard c.hasPrefix("cd ") else { return nil }
        var rest = String(c.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        // 取到第一个 && / ; / | 之前
        for sep in ["&&", ";", "|"] {
            if let r = rest.range(of: sep) { rest = String(rest[..<r.lowerBound]) }
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if (rest.hasPrefix("\"") && rest.hasSuffix("\"")) || (rest.hasPrefix("'") && rest.hasSuffix("'")) {
            rest = String(rest.dropFirst().dropLast())
        }
        return rest.isEmpty ? nil : rest
    }

    /// 单引号包裹路径,内部单引号转义,安全用于 shell。
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
