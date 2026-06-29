import AppKit
import ApplicationServices
import Foundation

/// Multi-window-aware activator for IDEs (PyCharm, VS Code, etc.) where one
/// process hosts many project windows. Plain `NSRunningApplication.activate`
/// only brings the *app* forward — not the specific project window the user's
/// session lives in. We use the Accessibility API to enumerate the app's
/// windows and raise the one whose title matches the session's cwd.
enum WindowActivator {
    /// True if VibeNotch has Accessibility permission. AX calls silently fail
    /// without it; we use this to decide whether to even attempt window-level
    /// activation vs. falling back to whole-app activation.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Trigger the system Accessibility permission prompt if not already
    /// granted. Safe to call repeatedly — only prompts the first time.
    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Activate the specific window of `pid` whose AX title best matches the
    /// project rooted at `cwd`. Returns true if a matching window was raised;
    /// false if no match (caller should fall back to whole-app activation).
    @MainActor
    static func activateWindow(pid: pid_t, cwd: String) -> Bool {
        guard isAccessibilityTrusted else { return false }

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return false
        }

        // 选不出最匹配的(比如会话 cwd 是项目子目录、标题里没有该层名)→ 不放弃,
        // 退而用第一个窗口。我们已经确定 pid 就是这台 IDE,激活它任一窗口也好过直接丢消息。
        let target = bestMatch(windows: windows, cwd: cwd) ?? windows.first!

        // 若窗口被最小化(Cmd+M,缩进 Dock)→ 先还原,否则 raise 无效。
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // Raise + make-main brings the window to the front of the app's stack;
        // app.activate then brings the app itself forward. Order matters: raise
        // first so when activate fires the right window is already on top.
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        // 关键:手机触发时 VibeNotch 在后台,现代 macOS(14+)禁止后台 App 用 NSRunningApplication
        // .activate 抢前台(.activateIgnoringOtherApps 已失效),目标 App 不会成为 active → 模拟按键打飞。
        // 但**有辅助功能权限的 App 可以走 AX 把目标置前台**(kAXFrontmost),这条后台也生效 ——
        // 刘海点按之所以能用,是因为那时 VibeNotch 本就是 active;这里补上后台也能置前的能力。
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        return true
    }

    /// Best-effort focus for Electron-style chat inputs. This is used after
    /// activating Codex.app so remote phone input lands in the composer rather
    /// than whichever non-editable element happened to be focused.
    @MainActor
    static func focusEditableText(pid: pid_t) -> Bool {
        guard isAccessibilityTrusted else { return false }

        let app = AXUIElementCreateApplication(pid)
        var roots: [AXUIElement] = []
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focusedRef {
            let focused = focusedRef as! AXUIElement
            roots.append(focused)
        }
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            roots.append(contentsOf: windows)
        }

        for root in roots {
            if let target = firstEditableText(in: root, depth: 0) {
                AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return true
            }
        }
        return false
    }

    /// 把某个 App 强制带到前台 —— 后台触发(手机)也生效。
    /// 现代 macOS 禁止后台 App 用 NSRunningApplication.activate 抢前台,但有辅助功能权限的 App
    /// 可以走 AX 设 kAXFrontmost(后台也允许);再补一个 activate 兜住非 AX 的常规路径。
    @MainActor
    static func bringAppFrontmost(pid: pid_t) {
        if isAccessibilityTrusted {
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    /// Focus the **terminal** text area inside an IDE window (IntelliJ/VS Code/…).
    /// Plain `focusEditableText` grabs the first editable element — in an IDE that's
    /// usually the code editor, not the terminal where claude runs. Here we collect
    /// every editable element, score them (terminal-ish title/description ↑, editor ↓),
    /// focus the best, and log all candidates so we can refine targeting if it misses.
    @MainActor
    @discardableResult
    static func focusTerminalText(pid: pid_t) -> Bool {
        guard isAccessibilityTrusted else { return false }
        let app = AXUIElementCreateApplication(pid)

        var roots: [AXUIElement] = []
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let f = focusedRef { roots.append(f as! AXUIElement) }
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let ws = windowsRef as? [AXUIElement] { roots.append(contentsOf: ws) }

        var cands: [(el: AXUIElement, score: Int, desc: String)] = []
        var budget = 6000   // 界面树可能很大,限节点数避免卡主线程
        for root in roots { collectEditable(root, depth: 0, budget: &budget, into: &cands) }
        guard !cands.isEmpty else { vlog("focusTerminal: 没找到可编辑元素 pid=\(pid)"); return false }

        for c in cands.prefix(12) { vlog("focusTerminal cand score=\(c.score) \(c.desc)") }
        let best = cands.max { $0.score < $1.score }!
        AXUIElementSetAttributeValue(best.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        vlog("focusTerminal → 聚焦 score=\(best.score) \(best.desc)")
        return true
    }

    /// JetBrains 专用聚焦终端:IntelliJ 的内置终端**不暴露给辅助功能**(AX 树里只有代码编辑器,
    /// 没有终端),所以没法靠遍历 AX 聚焦它。改用 IntelliJ 自己的快捷键 **⌥F12「激活终端工具窗」**:
    /// 仅当当前焦点是「代码编辑器」时才按(此时终端必然没聚焦 → ⌥F12 会聚焦它,不会误触发隐藏);
    /// 焦点不在编辑器(大概率已在终端)则不动,直接打字。返回是否按了 ⌥F12。
    @MainActor
    @discardableResult
    static func focusJetBrainsTerminal(pid: pid_t) -> Bool {
        guard isAccessibilityTrusted else { return false }
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            vlog("jbTerminal: 读不到焦点元素 → 直接打字")
            return false
        }
        let el = focused as! AXUIElement
        let desc = axStr(el, kAXDescriptionAttribute as String)
        let role = axStr(el, kAXRoleAttribute as String)
        let inEditor = desc.contains("Editor") || desc.contains("编辑器")
        vlog("jbTerminal: 焦点 role=\(role) desc=\(desc) → \(inEditor ? "在编辑器,⌥F12 切终端" : "非编辑器,直接打字")")
        guard inEditor else { return false }   // 已在终端/其它面板 → 不动
        pressOptionF12()
        return true
    }

    /// 模拟 ⌥F12(Option+F12):IntelliJ 默认「激活终端」工具窗的快捷键。
    private static func pressOptionF12() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let f12: CGKeyCode = 0x6F   // kVK_F12
        if let down = CGEvent(keyboardEventSource: src, virtualKey: f12, keyDown: true) {
            down.flags = .maskAlternate
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: f12, keyDown: false) {
            up.flags = .maskAlternate
            up.post(tap: .cghidEventTap)
        }
    }

    private static func axStr(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    /// 自身或祖先(上溯几层)的标题/描述里提到「终端 / terminal」→ 该可编辑元素更可能是终端面板。
    private static func ancestorMentionsTerminal(_ el: AXUIElement) -> Bool {
        var cur: AXUIElement? = el
        var up = 0
        while let c = cur, up < 6 {
            let hay = (axStr(c, kAXTitleAttribute as String) + " " +
                       axStr(c, kAXDescriptionAttribute as String) + " " +
                       axStr(c, kAXRoleDescriptionAttribute as String)).lowercased()
            if hay.contains("terminal") || hay.contains("终端") { return true }
            var parentRef: CFTypeRef?
            cur = AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parentRef) == .success
                ? (parentRef as! AXUIElement) : nil
            up += 1
        }
        return false
    }

    private static func collectEditable(_ el: AXUIElement, depth: Int, budget: inout Int,
                                        into out: inout [(el: AXUIElement, score: Int, desc: String)]) {
        guard depth < 16, budget > 0 else { return }
        budget -= 1
        let role = axStr(el, kAXRoleAttribute as String)
        if role == "AXTextArea" || role == "AXTextField" {
            let rd = axStr(el, kAXRoleDescriptionAttribute as String)
            let title = axStr(el, kAXTitleAttribute as String)
            let desc = axStr(el, kAXDescriptionAttribute as String)
            let ident = axStr(el, "AXIdentifier")
            let hay = "\(rd) \(title) \(desc) \(ident)".lowercased()
            var score = 0
            if hay.contains("terminal") || hay.contains("终端") { score += 100 }
            else if ancestorMentionsTerminal(el) { score += 60 }
            if hay.contains("editor") || hay.contains("编辑") { score -= 80 }   // 躲开代码编辑器
            out.append((el, score, "role=\(role) rd=\(rd) title=\(title) desc=\(desc) id=\(ident)"))
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let kids = childrenRef as? [AXUIElement] else { return }
        for k in kids { collectEditable(k, depth: depth + 1, budget: &budget, into: &out) }
    }

    /// Score each window by how well its title matches the cwd, return the best.
    /// Tie-break: prefer windows that contain the full project name as a token.
    private static func bestMatch(windows: [AXUIElement], cwd: String) -> AXUIElement? {
        let projectName = (cwd as NSString).lastPathComponent
        guard !projectName.isEmpty, projectName != "/" else {
            return windows.first
        }
        let cwdLower = cwd.lowercased()
        let nameLower = projectName.lowercased()
        // cwd 的各级目录名(IDE 项目常开在某个上层目录,会话 cwd 可能是其子目录 →
        // 标题里出现的是项目根名而非 cwd 末级名,这里逐级比对兜住这种情况)。
        let cwdComps = cwdLower.split(separator: "/").map(String.init).filter { $0.count >= 3 }

        var best: (window: AXUIElement, score: Int)? = nil
        for w in windows {
            let title = windowTitle(w)?.lowercased() ?? ""
            guard !title.isEmpty else { continue }
            var score = 0
            if title.contains(cwdLower) { score += 100 }       // full path mentioned
            if title.contains(nameLower) { score += 50 }       // project name mentioned
            // JetBrains often formats titles "Name – path" — boost windows
            // that start with the project name (most likely the right one).
            if title.hasPrefix(nameLower) { score += 25 }
            // cwd 是项目子目录:标题里出现 cwd 任一上层目录名(取最长匹配,越深越像同一项目)。
            for comp in cwdComps where title.contains(comp) { score = max(score, 30 + comp.count); break }
            if score > 0 {
                if best == nil || score > best!.score {
                    best = (w, score)
                }
            }
        }
        return best?.window
    }

    private static func windowTitle(_ window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard r == .success else { return nil }
        return titleRef as? String
    }

    private static func firstEditableText(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" {
            return element
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = firstEditableText(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
