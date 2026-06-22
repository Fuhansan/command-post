import AppKit

/// 把文字「打」进当前聚焦的终端窗口(CGEvent 模拟键盘,任意终端/IDE 通用)。
/// **仅作非 tmux 会话的回退**:调用前需先激活目标窗口(jumpToTerminal),要求辅助
/// 功能权限,且**锁屏时无效**(macOS 不向锁屏后的 App 投递模拟按键)。
/// 想锁屏也能控,会话要跑在 tmux 里(走 TmuxBridge)。
enum TerminalTyper {

    /// 模拟键入 text,然后按回车提交。换行替换为空格,避免中途提交。
    static func type(_ text: String, thenReturn: Bool = true) {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        // keyboardSetUnicodeString 单事件上限约 20 个 UTF-16 单元,分块发送
        let units = Array(clean.utf16)
        var i = 0
        while i < units.count {
            let n = min(20, units.count - i)
            var chunk = Array(units[i..<i+n])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            i += n
        }
        if thenReturn {
            // 稍等 TUI 消化输入再回车
            usleep(120_000)
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}
