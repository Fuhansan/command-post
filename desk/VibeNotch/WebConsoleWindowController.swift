import AppKit

/// 顶部原生透明拖动条。盖在 WKWebView 之上、贴顶占满设计标题栏那一条(高 40px),普通 NSView 的
/// `mouseDownCanMoveWindow` 行为稳定 → 拖它即拖窗口,100% 可靠。右侧留出宽度给网页里的主题/头像
/// 按钮(不遮挡),原生红绿灯在标题栏层之上也不受影响。
private final class TitleDragBar: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Web 控制台窗口:内嵌 WKWebView(React 前端),统一标题栏。
@MainActor
final class WebConsoleWindowController: NSObject, NSWindowDelegate {
    static let shared = WebConsoleWindowController()

    /// 标题栏高度,须与前端 TitleBar 的 h-[40px] 一致。右侧 rightReserve 留给主题/头像按钮。
    private static let titleBarHeight: CGFloat = 40
    private static let rightReserve: CGFloat = 104

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

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        // 最小尺寸:再小顶栏会被控件挤满、没有空白可拖区(也挤坏两栏布局)。
        w.minSize = NSSize(width: 940, height: 640)
        w.title = "Agent 控制台"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        // 拖动由下面的原生 TitleDragBar 负责;WKWebView 本身不可拖(DraggableWebView 返回 false)。
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 1)
        if let content = w.contentView {
            bridge.webView.frame = content.bounds
            bridge.webView.autoresizingMask = [.width, .height]
            content.addSubview(bridge.webView)
            // 顶部拖动条:贴顶、高 = 设计标题栏(40),宽 = 窗宽 - 右侧预留(给主题/头像按钮让位)。
            let h = Self.titleBarHeight, w2 = content.bounds.width - Self.rightReserve
            let bar = TitleDragBar(frame: NSRect(x: 0, y: content.bounds.height - h, width: max(0, w2), height: h))
            bar.autoresizingMask = [.width, .minYMargin]   // 贴顶、随窗宽拉伸(右侧预留固定)
            content.addSubview(bar)
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
