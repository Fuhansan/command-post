import AppKit
import WebKit
import Combine

/// WKWebView 本身**不可**拖动窗口——否则整块网页都成「可拖背景」,把按钮点击/文本选择全吞掉
/// (回归 bug)。窗口拖动改由顶部的原生透明拖动条 `TitleDragBar` 负责(见 WebConsoleWindowController),
/// 普通 NSView 的 `mouseDownCanMoveWindow` 行为稳定可靠,不受 WKWebView 内部子视图/异步消息影响。
final class DraggableWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Web 控制台桥接:持有 WKWebView,订阅会话模型变化推给 JS,接收 JS 命令调模型。
/// 点对点桥接,无本地服务/端口。
@MainActor
final class WebConsoleBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private weak var manager: AgentSessionManager?
    private weak var store: SessionStore?
    private weak var relayAgent: RelayAgent?
    private let pairing = PairingController()
    private var cancellables = Set<AnyCancellable>()
    private var ready = false
    // 增量推送状态:记录每个会话上次推送的 JSON 指纹,只推变化的那个(流式时关键)。
    private var lastSessionSig: [String: String] = [:]   // 控制台会话 id → sig
    private var lastManualSig: [String: String] = [:]    // hook 会话 id → sig
    private var lastProjectsSig: String?
    private var sessionsScheduled = false
    private var manualScheduled = false
    private var projectsScheduled = false

    init(manager: AgentSessionManager, store: SessionStore, relayAgent: RelayAgent?) {
        self.manager = manager
        self.store = store
        self.relayAgent = relayAgent
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        // 自定义 scheme:把 dist 文件喂给 WKWebView(避免 file:// 下 ES module 被 CORS 拦)。
        if let dist = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist")?
            .deletingLastPathComponent() {
            cfg.setURLSchemeHandler(DistSchemeHandler(root: dist), forURLScheme: "app")
        }
        webView = DraggableWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "agent")
        webView.navigationDelegate = self
        loadFrontend()

        manager.$sessions.sink { [weak self] _ in self?.scheduleSessions() }.store(in: &cancellables)
        manager.$projects.sink { [weak self] _ in self?.scheduleProjects() }.store(in: &cancellables)
        manager.$historyByProject.sink { [weak self] _ in self?.scheduleProjects() }.store(in: &cancellables)
        store.$sessions.sink { [weak self] _ in self?.scheduleManual() }.store(in: &cancellables)
        relayAgent?.$connState.sink { [weak self] _ in self?.pushConn() }.store(in: &cancellables)
        pairing.$state.sink { [weak self] _ in self?.pushConn() }.store(in: &cancellables)
    }

    private func loadFrontend() {
        guard Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist") != nil,
              let url = URL(string: "app://local/index.html") else {
            webView.loadHTMLString("<h2 style='font-family:sans-serif;padding:40px'>未找到 web 控制台前端(dist 未打包)</h2>", baseURL: nil)
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// 链接点击:把 http(s) 外链交给系统默认浏览器,取消 webview 内导航(否则会把控制台页面顶掉)。
    /// 仅放行前端自身的 `app://` 资源加载。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - JS → Swift

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let str = message.body as? String,
              let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true; pushState(); pushConn()
        case "setHost":
            if let host = obj["host"] as? String { AgentServer.host = host; pushConn() }
        case "pairStart":
            pairing.start()
        case "pairCancel":
            pairing.cancel(); pushConn()
        case "unpair":
            AgentCredentials.clear()
            NotificationCenter.default.post(name: .relayCredentialsChanged, object: nil)
            pushConn()
        case "openProject":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "打开项目"
            if panel.runModal() == .OK, let url = panel.url { manager?.openProject(url.path) }
        case "newSession":
            guard let wd = obj["workdir"] as? String, !wd.isEmpty else { return }
            guard let rawAgent = obj["agent"] as? String,
                  let agent = AgentKind(rawValue: rawAgent) else {
                NSLog("VibeNotch: newSession ignored because agent is missing")
                return
            }
            _ = manager?.newSession(agent: agent, workdir: wd,
                                    resume: obj["resume"] as? String,
                                    continueLast: obj["continueLast"] as? Bool ?? false)
        case "closeSession":
            if let sid = obj["sid"] as? String { manager?.closeSession(sid) }
        case "switchModel":
            if let sid = obj["sid"] as? String, let model = obj["model"] as? String {
                manager?.switchModel(sid, to: model)
            }
        case "renameSession":
            if let key = obj["key"] as? String, let title = obj["title"] as? String {
                SessionMetaStore.shared.rename(key, to: title); pushState()
            }
        case "hideSession":
            if let key = obj["key"] as? String { SessionMetaStore.shared.hide(key); pushState() }
        case "unhideSession":
            if let key = obj["key"] as? String { SessionMetaStore.shared.unhide(key); pushState() }
        case "send":
            if let sid = obj["sid"] as? String, let text = obj["text"] as? String {
                let imgs = obj["images"] as? [[String: Any]] ?? []
                if imgs.isEmpty { manager?.send(sid, text: text) }
                else { sendWithImages(sid: sid, text: text, images: imgs) }
            }
        case "prepareImage":
            if let attachId = obj["attachId"] as? String, let name = obj["name"] as? String, let data = obj["data"] as? String {
                prepareImage(attachId: attachId, name: name, b64: data)
            }
        case "interrupt":
            if let sid = obj["sid"] as? String { manager?.interrupt(sid) }
        case "respond":
            if let sid = obj["sid"] as? String, let req = obj["reqId"] as? String,
               let choose = obj["choose"] as? [String] { manager?.respond(sid, requestId: req, choose: choose) }
        case "theme":
            // 跟随网页主题给原生标题栏条着色,避免深色模式露出白边。
            let dark = obj["dark"] as? Bool ?? false
            // 与网页顶栏(--bg-elev)同色,让原生标题栏条和顶栏连成一条。
            webView.window?.backgroundColor = dark
                ? NSColor(calibratedWhite: 0.114, alpha: 1)
                : NSColor(calibratedWhite: 1.0, alpha: 1)
        case "raiseWindow":
            if let id = obj["id"] as? String { raiseWindow(manualId: id) }
        case "listDir":
            if let path = obj["path"] as? String {
                let entries = DirCache.children(URL(fileURLWithPath: path)).map {
                    ["name": $0.url.lastPathComponent, "path": $0.url.path, "isDir": $0.isDir] as [String: Any]
                }
                pushJSON(type: "dirList", payload: ["path": path, "entries": entries])
            }
        case "loadUsage":
            let days = (obj["days"] as? NSNumber)?.intValue ?? 14
            Task { [weak self] in
                let payload = await UsageScanner.shared.aggregate(days: days)
                await MainActor.run { self?.pushJSON(type: "usage", payload: payload) }
            }
        case "loadFile":
            if let path = obj["path"] as? String { loadFile(path: path) }
        case "loadTranscript":
            // 历史/手动会话只读浏览:分窗懒加载(末尾一窗 / beforeByte 之前一窗)。
            guard let id = obj["id"] as? String, let kind = obj["kind"] as? String else { return }
            let path: String?
            if kind == "history", let wd = obj["workdir"] as? String {
                path = AgentSessionManager.historyTranscriptPath(workdir: wd, id: id)
            } else {
                path = store?.sessions.first { $0.id == id }?.transcriptPath
            }
            let before = (obj["beforeByte"] as? NSNumber)?.uint64Value
            loadTranscript(id: id, path: path, beforeByte: before)
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

    private func loadTranscript(id: String, path: String?, beforeByte: UInt64?) {
        guard let path else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let win = AgentSessionManager.parseTranscriptWindow(path: path, endByte: beforeByte)
            let imgMap = AgentSessionManager.transcriptImages(path: path, endByte: beforeByte)
            let msgs = win.messages.map { m -> [String: Any] in
                var d: [String: Any] = ["id": "h\(m.ord)", "role": m.role, "kind": m.kind.rawValue, "text": m.text, "ord": m.ord]
                if let imgs = imgMap[m.ord] { d["images"] = imgs }   // 历史图片(thumb/url 都是 data URL)
                return d
            }
            await MainActor.run {
                self?.pushJSON(type: "transcript", payload: [
                    "id": id, "messages": msgs, "earliest": win.earliest, "hasEarlier": win.hasEarlier,
                ])
            }
        }
    }

    // MARK: - Swift → JS

    // 合并高频变化,下一个 runloop 各自推一次(分片:会话/手动/项目互不牵连)。
    private func scheduleSessions() {
        guard ready, !sessionsScheduled else { return }
        sessionsScheduled = true
        Task { @MainActor in self.sessionsScheduled = false; self.pushSessionsIncremental() }
    }
    private func scheduleManual() {
        guard ready, !manualScheduled else { return }
        manualScheduled = true
        Task { @MainActor in self.manualScheduled = false; self.pushManualIncremental() }
    }
    private func scheduleProjects() {
        guard ready, !projectsScheduled else { return }
        projectsScheduled = true
        Task { @MainActor in self.projectsScheduled = false; self.pushProjects() }
    }

    /// 控制台会话:逐个比对指纹,只推变化的会话(`sessionUpsert`),消失的发 `sessionRemove`。
    /// 流式输出时只有正在说话的那个会话被序列化+推送,而不是整份 state。
    private func pushSessionsIncremental() {
        guard ready, let manager else { return }
        var live = Set<String>()
        for s in manager.sessions {
            guard let dto = sessionDTO(s), let sig = jsonSig(dto) else { continue }
            live.insert(s.id)
            if lastSessionSig[s.id] != sig {
                lastSessionSig[s.id] = sig
                pushJSON(type: "sessionUpsert", payload: dto)
            }
        }
        for id in lastSessionSig.keys where !live.contains(id) {
            lastSessionSig.removeValue(forKey: id)
            pushJSON(type: "sessionRemove", payload: ["id": id])
        }
    }

    /// hook(手动)会话:同样逐个增量。
    private func pushManualIncremental() {
        guard ready else { return }
        var live = Set<String>()
        for e in store?.sessions ?? [] {
            guard let dto = manualDTO(e), let sig = jsonSig(dto) else { continue }
            live.insert(e.id)
            if lastManualSig[e.id] != sig {
                lastManualSig[e.id] = sig
                pushJSON(type: "manualUpsert", payload: dto)
            }
        }
        for id in lastManualSig.keys where !live.contains(id) {
            lastManualSig.removeValue(forKey: id)
            pushJSON(type: "manualRemove", payload: ["id": id])
        }
    }

    /// 项目 + 隐藏名单:变化较少,整体推,但指纹无变化时跳过(避免会话刷新时白推)。
    private func pushProjects() {
        guard ready, let manager else { return }
        let payload = projectsPayload(manager)
        guard let sig = jsonSig(payload), sig != lastProjectsSig else { return }
        lastProjectsSig = sig
        pushJSON(type: "projects", payload: payload)
    }

    private func projectsPayload(_ manager: AgentSessionManager) -> [String: Any] {
        let meta = SessionMetaStore.shared
        let projects = manager.projects.map { proj -> [String: Any] in
            manager.loadHistoryList(for: proj)   // 懒加载历史(已缓存则跳过)
            let hist = (manager.historyByProject[proj] ?? []).compactMap { h -> [String: Any]? in
                if meta.isHidden(h.id) { return nil }
                return ["id": h.id, "key": h.id, "label": meta.title(for: h.id) ?? h.label,
                        "mtime": h.mtime.timeIntervalSince1970 * 1000]
            }
            return ["workdir": proj, "name": (proj as NSString).lastPathComponent, "history": hist]
        }
        let hidden = meta.hiddenEntries().map { ["key": $0.key, "title": $0.title] }
        return ["projects": projects, "hidden": hidden]
    }

    /// 初次/重连:推一次全量 state,并把各会话指纹种好,后续走增量。
    private func pushState() {
        guard ready, let manager else { return }
        let proj = projectsPayload(manager)
        let sessions = manager.sessions.compactMap { sessionDTO($0) }
        let manual = (store?.sessions ?? []).compactMap { manualDTO($0) }
        // 种指纹,使随后的增量推送能正确 diff(避免全量后又逐个重推)。
        lastSessionSig.removeAll()
        for s in manager.sessions { if let d = sessionDTO(s), let sig = jsonSig(d) { lastSessionSig[s.id] = sig } }
        lastManualSig.removeAll()
        for e in store?.sessions ?? [] { if let d = manualDTO(e), let sig = jsonSig(d) { lastManualSig[e.id] = sig } }
        lastProjectsSig = jsonSig(proj)
        pushJSON(type: "state", payload: [
            "projects": proj["projects"] ?? [], "sessions": sessions,
            "manual": manual, "hidden": proj["hidden"] ?? [],
        ])
    }

    private func jsonSig(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: - 连接 / 配对

    private func pushConn() {
        guard ready else { return }
        let st = relayAgent?.connState ?? .offline
        pushJSON(type: "conn", payload: [
            "host": AgentServer.host,
            "paired": RelayAgent.isPaired,
            "account": AgentCredentials.account ?? "",
            "state": connKey(st),
            "text": connText(st),
            "pair": pairDTO(pairing.state),
        ])
    }
    private func connKey(_ s: RelayAgent.ConnState) -> String {
        switch s {
        case .unpaired: return "unpaired"; case .connecting: return "connecting"
        case .online: return "online"; case .suspendedByPhone: return "suspended"
        case .rejected: return "rejected"; case .offline: return "offline"
        }
    }
    private func connText(_ s: RelayAgent.ConnState) -> String {
        switch s {
        case .online:           return "已连接中转服务器"
        case .connecting:       return "连接中…"
        case .suspendedByPhone: return "已被手机端断开 —— 在手机「设备」页点「重连」恢复"
        case .rejected(let c):  return "被服务器拒绝(\(c)),请重新配对"
        case .unpaired:         return "未配对,离线"
        case .offline:          return "离线,自动重连中…"
        }
    }
    private func pairDTO(_ s: PairingController.State) -> [String: Any] {
        switch s {
        case .idle:               return ["phase": "idle"]
        case .fetching:           return ["phase": "fetching"]
        case .waiting(let code):  return ["phase": "waiting", "code": code]
        case .done(let account):  return ["phase": "done", "account": account]
        case .failed(let msg):    return ["phase": "failed", "error": msg]
        }
    }

    /// 会话的稳定 key:优先 claude session_id(跨重启/与历史统一),没有则用内部 id。
    private func sessionKey(_ s: AgentSession) -> String {
        if let a = s.agentSessionId, !a.isEmpty { return a }
        return s.id
    }

    private func manualDTO(_ e: SessionEntry) -> [String: Any]? {
        let meta = SessionMetaStore.shared
        if meta.isHidden(e.id) { return nil }
        let agent = e.transcriptPath.flatMap { CodingAgents.forTranscript($0)?.id } ?? "claude"
        let base = e.promptSummary.map { String($0.prefix(40)) }
            ?? e.transcriptPath.flatMap { AgentSessionManager.firstUserPrompt(path: $0) }.map { String($0.prefix(40)) }
            ?? "手动会话"
        return [
            "id": e.id, "key": e.id, "title": meta.title(for: e.id) ?? base, "cwd": e.cwd,
            "terminal": e.terminal.displayName,
            "agent": agent,
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

    private func sessionDTO(_ s: AgentSession) -> [String: Any]? {
        let key = sessionKey(s)
        let meta = SessionMetaStore.shared
        if meta.isHidden(key) { return nil }
        // 标题优先用户自定义,其次首条用户消息(s.title 是目录名,不能当会话标题);没有则「新会话」。
        let base = s.messages.first { $0.kind == .text && $0.role == "user" }
            .map { String($0.text.prefix(40)) } ?? "新会话"
        return [
            "id": s.id, "key": key, "title": meta.title(for: key) ?? base, "workdir": s.workdir,
            "agent": s.agent.rawValue, "status": statusKey(s.status),
            "model": s.model ?? "",
            "models": s.availableModels.map { ["id": $0.id, "label": $0.label] },
            "agentSessionId": s.agentSessionId ?? "",
            "startedAt": s.startedAt.timeIntervalSince1970 * 1000,
            "messages": s.messages.map { msgDTO($0) },
            "pending": s.pending.map { pendingDTO($0) },
        ]
    }
    private func msgDTO(_ m: AgentMessage) -> [String: Any] {
        var d: [String: Any] = ["id": m.id, "role": m.role, "kind": m.kind.rawValue, "text": m.text, "ord": m.ord]
        if !m.images.isEmpty {
            // 通道只带 id;web 用 app://__img/<id>.<ext> 按 id 取字节(scheme handler 本地缓存命中或回源)
            d["images"] = m.images.map { ["id": $0.id, "ext": $0.ext] }
        }
        if let ps = m.permState { d["permState"] = ps }
        if let pr = m.permReqId { d["permReqId"] = pr }
        return d
    }

    /// 桌面控制台带图发送:web 传 base64 → 落盘(喂 agent)+ 上传服务器拿 id(给手机展示)→ 入会话回显。
    /// 全图不进 relay 消息,只带 id + 小缩略图。
    /// 粘贴即上传:不等发送,先把图传服务器拿 id + 落本地缓存,完成回推 imageReady。
    private func prepareImage(attachId: String, name: String, b64: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = Data(base64Encoded: b64) else { return }
            let raw = (name as NSString).pathExtension.lowercased()
            let ext = raw.isEmpty ? "png" : raw
            var id = "", outExt = ext
            if let up = ImageRelay.upload(data, ext: ext) { id = up.id; outExt = up.ext; ImageRelay.saveById(id: id, ext: outExt, data: data) }
            else if let local = ImageRelay.cacheBase64(b64, ext: ext) { id = local }
            guard !id.isEmpty else { return }
            await MainActor.run { self?.pushJSON(type: "imageReady", payload: ["attachId": attachId, "id": id, "ext": outExt]) }
        }
    }

    private func sendWithImages(sid: String, text: String, images: [[String: Any]]) {
        Task.detached(priority: .userInitiated) { [weak self] in
            var refs: [ImageRef] = []
            for img in images {
                var id = "", ext = "png"
                if let preId = img["id"] as? String, !preId.isEmpty {   // 粘贴时已预上传:只需确保本地缓存(给 agent 当路径)
                    id = preId; ext = (img["ext"] as? String) ?? "png"
                    _ = ImageRelay.ensureCached(id: id, ext: ext)
                } else if let b64 = img["data"] as? String, let data = Data(base64Encoded: b64) {   // 没预传:现传
                    let name = (img["name"] as? String) ?? "image"
                    let raw = (name as NSString).pathExtension.lowercased()
                    ext = raw.isEmpty ? "png" : raw
                    if let up = ImageRelay.upload(data, ext: ext) { id = up.id; ext = up.ext; ImageRelay.saveById(id: id, ext: ext, data: data) }
                    else if let local = ImageRelay.cacheBase64(b64, ext: ext) { id = local }
                }
                guard !id.isEmpty else { continue }
                refs.append(ImageRef(id: id, ext: ext, localPath: ImageRelay.cachePath(id: id, ext: ext)))
            }
            await MainActor.run { self?.manager?.send(sid, text: text, images: refs) }
        }
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
        let fileURL: URL
        if path.hasPrefix("/__img/") {
            // 会话图片:按 id 取字节(本地缓存命中或回源下载)。通道里只有这个 id。
            let name = String(path.dropFirst("/__img/".count))   // <id>.<ext>
            let id = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard !id.isEmpty, let local = ImageRelay.ensureCached(id: id, ext: ext) else {
                let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                task.didReceive(resp); task.didFinish(); return
            }
            fileURL = URL(fileURLWithPath: local)
        } else {
            if path.isEmpty || path == "/" { path = "/index.html" }
            fileURL = root.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        }
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
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
