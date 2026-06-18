import AppKit
import WebKit
import Combine

/// Web 控制台桥接:持有 WKWebView,订阅会话模型变化推给 JS,接收 JS 命令调模型。
/// 点对点桥接,无本地服务/端口。
@MainActor
final class WebConsoleBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private weak var manager: AgentSessionManager?
    private weak var store: SessionStore?
    private var cancellables = Set<AnyCancellable>()
    private var ready = false
    private var pushScheduled = false

    init(manager: AgentSessionManager, store: SessionStore) {
        self.manager = manager
        self.store = store
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "agent")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")   // 透明,让 web 背景生效
        loadFrontend()

        manager.$sessions.sink { [weak self] _ in self?.schedulePush() }.store(in: &cancellables)
        manager.$projects.sink { [weak self] _ in self?.schedulePush() }.store(in: &cancellables)
    }

    private func loadFrontend() {
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist") else {
            webView.loadHTMLString("<h2 style='font-family:sans-serif;padding:40px'>未找到 web 控制台前端(dist 未打包)</h2>", baseURL: nil)
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    // MARK: - JS → Swift

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let str = message.body as? String,
              let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true; pushState()
        case "newSession":
            guard let wd = obj["workdir"] as? String, !wd.isEmpty else { return }
            _ = manager?.newSession(agent: .claude, workdir: wd,
                                    resume: obj["resume"] as? String,
                                    continueLast: obj["continueLast"] as? Bool ?? false)
        case "closeSession":
            if let sid = obj["sid"] as? String { manager?.closeSession(sid) }
        case "send":
            if let sid = obj["sid"] as? String, let text = obj["text"] as? String { manager?.send(sid, text: text) }
        case "respond":
            if let sid = obj["sid"] as? String, let req = obj["reqId"] as? String,
               let choose = obj["choose"] as? [String] { manager?.respond(sid, requestId: req, choose: choose) }
        default:
            break
        }
    }

    // MARK: - Swift → JS

    /// 合并高频变化,下一个 runloop 统一推一次全量,避免流式时疯狂 evaluateJavaScript。
    private func schedulePush() {
        guard ready, !pushScheduled else { return }
        pushScheduled = true
        Task { @MainActor in self.pushScheduled = false; self.pushState() }
    }

    private func pushState() {
        guard ready, let manager else { return }
        let projects = manager.projects.map { ["workdir": $0, "name": ($0 as NSString).lastPathComponent] }
        let sessions = manager.sessions.map { sessionDTO($0) }
        pushJSON(type: "state", payload: ["projects": projects, "sessions": sessions])
    }

    private func sessionDTO(_ s: AgentSession) -> [String: Any] {
        [
            "id": s.id, "title": s.title, "workdir": s.workdir,
            "agent": s.agent.rawValue, "status": statusKey(s.status),
            "agentSessionId": s.agentSessionId ?? "",
            "startedAt": s.startedAt.timeIntervalSince1970 * 1000,
            "messages": s.messages.map { msgDTO($0) },
            "pending": s.pending.map { pendingDTO($0) },
        ]
    }
    private func msgDTO(_ m: AgentMessage) -> [String: Any] {
        var d: [String: Any] = ["id": m.id, "role": m.role, "kind": m.kind.rawValue, "text": m.text, "ord": m.ord]
        if let ps = m.permState { d["permState"] = ps }
        if let pr = m.permReqId { d["permReqId"] = pr }
        return d
    }
    private func pendingDTO(_ p: PendingRequest) -> [String: Any] {
        ["id": p.id, "title": p.title, "detail": p.detail ?? "",
         "options": p.options.map { ["id": $0.id, "label": $0.label] }]
    }
    private func statusKey(_ s: SessionStatus) -> String {
        switch s {
        case .starting: return "starting"; case .idle: return "idle"; case .working: return "working"
        case .waitingInput: return "waitingInput"; case .needsResponse: return "needsResponse"
        case .done: return "done"; case .error: return "error"
        }
    }

    private func pushJSON(type: String, payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__agent && window.__agent.push(\(json))", completionHandler: nil)
    }
}
