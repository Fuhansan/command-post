import AppKit
import SwiftUI

/// 持有 Agent 控制台窗口(stream-json 新架构的桌面入口)。
/// 仿 SettingsWindowController:LSUIElement 应用自管 NSWindow,从菜单栏唤起。
@MainActor
final class AgentConsoleWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentConsoleWindowController()

    private var window: NSWindow?
    /// 由 AppDelegate 注入的共享会话管理器。
    weak var manager: AgentSessionManager?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let manager else { return }
        let host = NSHostingController(rootView: AgentConsoleRootView(manager: manager))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "Agent 控制台(stream-json)"
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 860, height: 540))
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}
