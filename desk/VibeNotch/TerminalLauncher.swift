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
        // (该提示早于 hook,手机接不到)。信任 claude 实际启动的目录:
        // 命令里 cd 的目标 > 默认目录 > 家目录(都没有时终端默认在家目录起)。
        var trustDirs: [String] = []
        if let cdTarget = leadingCdPath(in: cmd) { trustDirs.append(cdTarget) }
        if !dir.isEmpty { trustDirs.append(dir) }
        if trustDirs.isEmpty { trustDirs.append(NSHomeDirectory()) }
        // 按命令工具名路由到对应适配器做信任预置(claude→ClaudeTrust;其他工具各自实现)
        if let tool = mainTool(in: cmd), let agent = CodingAgents.forCommand(tool) {
            agent.preTrust(directories: trustDirs)
        } else {
            ClaudeAgent().preTrust(directories: trustDirs)   // 默认按 claude 处理
        }

        // 干净的新终端 PATH 可能指不到装 claude/codex 的那个 nvm node 版本。
        // 关键:只补**装了该命令的那一个** node 版本的 bin(不是所有版本)——
        // 否则 PATH 里 node 版本错配,会让交互式 claude 的插件/LSP 子进程跑在
        // 错误 node 版本上而初始化失败、不写转录(手动启动时是单版本,所以正常)。
        // 命令跑在 **tmux** 会话里(关键):VibeNotch 下发指令靠 `tmux send-keys` 直写 pty,
        // 不再模拟键盘,所以锁屏 / 显示休眠也能注入。会话名 vn_<时间戳> 唯一;
        // -A=没有则建。cd 在 tmux 之前执行,pane 即在该目录起。
        // 顺序:代理 → PATH → cd → tmux 跑命令
        let session = "vn_\(Int(Date().timeIntervalSince1970))"
        let full = "\(proxyPart)export PATH=\"\(pathPrefix(forCommand: cmd))$PATH\"; \(cdPart)tmux new-session -A -s \(session) \(shellQuote(cmd))"

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

    /// 从命令里取要运行的工具名(跳过开头的 cd…&&,取真正的可执行名)。
    private static func mainTool(in command: String) -> String? {
        var c = command.trimmingCharacters(in: .whitespaces)
        // 去掉开头的 cd ... (&& | ;)
        if c.hasPrefix("cd ") {
            for sep in ["&&", ";"] {
                if let r = c.range(of: sep) { c = String(c[r.upperBound...]).trimmingCharacters(in: .whitespaces); break }
            }
        }
        // 去掉前面的 VAR=val 赋值
        while let sp = c.firstIndex(of: " "), c[..<sp].contains("="), !c[..<sp].contains("/") {
            c = String(c[c.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }
        let tool = c.split(whereSeparator: { $0 == " " }).first.map(String.init)
        // 绝对/相对路径形式取最后一段
        return tool.map { ($0 as NSString).lastPathComponent }
    }

    /// 只补**装了该命令工具的那一个** nvm 版本的 bin + 常用目录(保持 node 单版本一致)。
    /// 找不到具体版本时回退所有版本(至少能找到命令)。
    private static func pathPrefix(forCommand command: String) -> String {
        let home = NSHomeDirectory()
        let nvmRoot = "\(home)/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvmRoot)) ?? []).sorted(by: >)
        var dirs: [String] = []

        if let tool = mainTool(in: command) {
            // 找第一个 bin 里有这个工具的版本,只用它
            if let v = versions.first(where: {
                FileManager.default.fileExists(atPath: "\(nvmRoot)/\($0)/bin/\(tool)")
            }) {
                dirs.append("\(nvmRoot)/\(v)/bin")
            }
        }
        if dirs.isEmpty {
            // 工具不在任何 nvm 版本(或解析不出)→ 回退:补所有版本,至少能跑起来
            for v in versions {
                let bin = "\(nvmRoot)/\(v)/bin"
                if FileManager.default.fileExists(atPath: bin) { dirs.append(bin) }
            }
        }
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"] {
            if FileManager.default.fileExists(atPath: d) { dirs.append(d) }
        }
        return dirs.isEmpty ? "" : dirs.joined(separator: ":") + ":"
    }
}
