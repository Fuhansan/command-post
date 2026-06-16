import Foundation

/// 通过 tmux 把指令写进会话的 pty —— **不走 GUI 模拟键盘**,所以锁屏 / 显示休眠
/// 都能注入(只要系统不深度休眠)。
///
/// 反查思路:VibeNotch 知道会话进程的 pid(来自 hook 的 ownerPID),从它沿父链
/// 往上,匹配 `tmux list-panes` 的 pane_pid,命中即得该 pane 的 session 名,
/// 再 `tmux send-keys -t <session>` 写入。
enum TmuxBridge {

    /// tmux 可执行路径(GUI App 的 PATH 可能没有 homebrew 目录,逐个找)。
    static let tmuxPath: String? = {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    static var isAvailable: Bool { tmuxPath != nil }

    /// 按会话进程 pid 反查它所在的 tmux session 名;不在任何 tmux pane 里返回 nil。
    static func sessionName(forPid pid: pid_t) -> String? {
        guard let panes = listPanes() else { return nil }   // [pane_pid: session]
        // 从 pid 沿父链上溯,第一个命中 pane_pid 的就是目标 pane
        var cur = pid
        var depth = 0
        while cur > 1 && depth < 32 {
            if let s = panes[cur] { return s }
            guard let info = ProcessUtils.procInfo(pid: cur) else { return nil }
            cur = info.ppid
            depth += 1
        }
        return nil
    }

    /// 把文字写进会话并回车提交。换行换成空格,避免中途提交。成功返回 true。
    @discardableResult
    static func sendText(_ text: String, toPid pid: pid_t) -> Bool {
        guard let session = sessionName(forPid: pid) else { return false }
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        // -l:字面量发送(中文/路径/特殊字符原样进),再单独发回车
        guard run(["send-keys", "-t", session, "-l", clean]) else { return false }
        return run(["send-keys", "-t", session, "Enter"])
    }

    /// 选择题:发一个数字键,不回车(与原 GUI 注入行为一致)。
    @discardableResult
    static func sendDigit(_ digit: String, toPid pid: pid_t) -> Bool {
        guard let session = sessionName(forPid: pid) else { return false }
        return run(["send-keys", "-t", session, "-l", digit])
    }

    /// 结束会话:杀掉该 pane 所在的整个 tmux session(进程随之退出)。
    @discardableResult
    static func killSession(forPid pid: pid_t) -> Bool {
        guard let session = sessionName(forPid: pid) else { return false }
        return run(["kill-session", "-t", session])
    }

    // MARK: - 底层

    /// pane_pid → session_name 全表。
    private static func listPanes() -> [pid_t: String]? {
        guard let out = capture(["list-panes", "-a", "-F", "#{pane_pid} #{session_name}"]) else { return nil }
        var map: [pid_t: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { continue }
            map[pid] = String(parts[1])
        }
        return map
    }

    @discardableResult
    private static func run(_ args: [String]) -> Bool {
        capture(args) != nil
    }

    /// 跑一条 tmux 命令,返回 stdout(失败返回 nil)。
    private static func capture(_ args: [String]) -> String? {
        guard let tmux = tmuxPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
    }
}
