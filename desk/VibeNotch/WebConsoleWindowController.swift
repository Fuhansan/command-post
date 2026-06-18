import AppKit

/// Web 控制台窗口:内嵌 WKWebView(React 前端),统一标题栏。
@MainActor
final class WebConsoleWindowController: NSObject, NSWindowDelegate {
    static let shared = WebConsoleWindowController()

    private var window: NSWindow?
    private var bridge: WebConsoleBridge?
    weak var manager: AgentSessionManager?
    weak var store: SessionStore?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let manager, let store else { return }
        let bridge = WebConsoleBridge(manager: manager, store: store)
        self.bridge = bridge

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Agent 控制台 (Web)"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        if let content = w.contentView {
            bridge.webView.frame = content.bounds
            bridge.webView.autoresizingMask = [.width, .height]
            content.addSubview(bridge.webView)
        }
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil; self.bridge = nil }
    }
}
