import AppKit

/// Web 控制台窗口:内嵌 WKWebView(React 前端),统一标题栏。
@MainActor
final class WebConsoleWindowController: NSObject, NSWindowDelegate {
    static let shared = WebConsoleWindowController()

    private var window: NSWindow?
    private var bridge: WebConsoleBridge?
    weak var manager: AgentSessionManager?
    weak var store: SessionStore?
    weak var relayAgent: RelayAgent?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let manager, let store else { return }
        let bridge = WebConsoleBridge(manager: manager, store: store, relayAgent: relayAgent)
        self.bridge = bridge

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Agent 控制台 (Web)"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 1)   // 与网页顶栏同色,标题栏条连成一条
        if let content = w.contentView {
            // 顶部留 28pt 给原生标题栏(可拖动窗口);webview 从下方开始,不盖住拖拽区。
            let inset: CGFloat = 28
            bridge.webView.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - inset)
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
