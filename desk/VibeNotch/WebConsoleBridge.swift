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
        // 自定义 scheme:把 dist 文件喂给 WKWebView(避免 file:// 下 ES module 被 CORS 拦)。
        if let dist = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist")?
            .deletingLastPathComponent() {
            cfg.setURLSchemeHandler(DistSchemeHandler(root: dist), forURLScheme: "app")
        }
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "agent")
        webView.navigationDelegate = self
        loadFrontend()

        manager.$sessions.sink { [weak self] _ in self?.schedulePush() }.store(in: &cancellables)
        manager.$projects.sink { [weak self] _ in self?.schedulePush() }.store(in: &cancellables)
        manager.$historyByProject.sink { [weak self] _ in self?.schedulePush() }.store(in: &cancellables)
        store.$sessions.sink { [weak self] _ in self?.schedulePush() }.store(in: &cancellables)
    }

    private func loadFrontend() {
        guard Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist") != nil,
              let url = URL(string: "app://local/index.html") else {
            webView.loadHTMLString("<h2 style='font-family:sans-serif;padding:40px'>未找到 web 控制台前端(dist 未打包)</h2>", baseURL: nil)
            return
        }
        webView.load(URLRequest(url: url))
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
        case "openProject":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "打开项目"
            if panel.runModal() == .OK, let url = panel.url { manager?.openProject(url.path) }
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
        case "raiseWindow":
            if let id = obj["id"] as? String { raiseWindow(manualId: id) }
        case "listDir":
            if let path = obj["path"] as? String {
                let entries = DirCache.children(URL(fileURLWithPath: path)).map {
                    ["name": $0.url.lastPathComponent, "path": $0.url.path, "isDir": $0.isDir] as [String: Any]
                }
                pushJSON(type: "dirList", payload: ["path": path, "entries": entries])
            }
        case "loadFile":
            if let path = obj["path"] as? String { loadFile(path: path) }
        case "loadTranscript":
            // 历史/手动会话只读浏览:解析转录,推回消息。
            guard let id = obj["id"] as? String, let kind = obj["kind"] as? String else { return }
            let path: String?
            if kind == "history", let wd = obj["workdir"] as? String {
                path = AgentSessionManager.historyTranscriptPath(workdir: wd, id: id)
            } else {
                path = store?.sessions.first { $0.id == id }?.transcriptPath
            }
            loadTranscript(id: id, path: path)
        default:
            break
        }
    }

    private func raiseWindow(manualId: String) {
        guard let e = store?.sessions.first(where: { $0.id == manualId }),
              let start = e.ownerPID ?? e.terminalPID, start > 1,
              let appPid = ProcessUtils.findTerminal(startPid: start).pid,
              let app = NSRunningApplication(processIdentifier: appPid) else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private func loadFile(path: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let url = URL(fileURLWithPath: path)
            var text = "(无法读取)"; var truncated = false
            if let data = try? Data(contentsOf: url) {
                if data.prefix(8000).contains(0) { text = "(二进制文件,无法预览)" }
                else if data.count > 2_000_000 {
                    text = String(decoding: data.prefix(2_000_000), as: UTF8.self); truncated = true
                } else { text = String(decoding: data, as: UTF8.self) }
            }
            let t = text, tr = truncated
            await MainActor.run { self?.pushJSON(type: "fileContent", payload: ["path": path, "text": t, "truncated": tr]) }
        }
    }

    private func loadTranscript(id: String, path: String?) {
        guard let path else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = AgentSessionManager.parseTranscriptFile(path: path)
            let msgs = items.enumerated().map { i, t -> [String: Any] in
                ["id": "h\(i)", "role": t.role, "kind": t.kind.rawValue, "text": t.text, "ord": i]
            }
            await MainActor.run { self?.pushJSON(type: "transcript", payload: ["id": id, "messages": msgs]) }
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
        let projects = manager.projects.map { proj -> [String: Any] in
            manager.loadHistoryList(for: proj)   // 懒加载历史(已缓存则跳过)
            let hist = (manager.historyByProject[proj] ?? []).map {
                ["id": $0.id, "label": $0.label, "mtime": $0.mtime.timeIntervalSince1970 * 1000]
            }
            return ["workdir": proj, "name": (proj as NSString).lastPathComponent, "history": hist]
        }
        let sessions = manager.sessions.map { sessionDTO($0) }
        let manual = (store?.sessions ?? []).map { manualDTO($0) }
        pushJSON(type: "state", payload: ["projects": projects, "sessions": sessions, "manual": manual])
    }

    private func manualDTO(_ e: SessionEntry) -> [String: Any] {
        let title = e.transcriptPath.flatMap { AgentSessionManager.firstUserPrompt(path: $0) }
            .map { String($0.prefix(40)) } ?? (e.promptSummary.map { String($0.prefix(40)) } ?? "手动会话")
        return [
            "id": e.id, "title": title, "cwd": e.cwd,
            "terminal": e.terminal.displayName,
            "state": manualState(e.state),
            "lastActivityAt": e.lastActivityAt.timeIntervalSince1970 * 1000,
        ]
    }
    private func manualState(_ s: SessionState) -> String {
        switch s {
        case .working: return "working"; case .waiting: return "waiting"; case .done: return "done"
        default: return "idle"
        }
    }

    private func sessionDTO(_ s: AgentSession) -> [String: Any] {
        // 标题用首条用户消息(s.title 是目录名,不能当会话标题);没有则「新会话」。
        let title = s.messages.first { $0.kind == .text && $0.role == "user" }
            .map { String($0.text.prefix(40)) } ?? "新会话"
        return [
            "id": s.id, "title": title, "workdir": s.workdir,
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

/// 把打包进 app 的 dist/ 文件用 app:// scheme 喂给 WKWebView。
final class DistSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFinish(); return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let fileURL = root.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        guard let data = try? Data(contentsOf: fileURL) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(resp); task.didFinish(); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": Self.mime(fileURL.pathExtension),
                                                  "Access-Control-Allow-Origin": "*"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
