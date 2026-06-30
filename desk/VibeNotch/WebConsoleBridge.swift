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
    private weak var pending: PendingDecisionStore?   // 终端会话审批扣留处(权限 allow/deny),供控制台渲染+应答
    private var cancellables = Set<AnyCancellable>()
    private var ready = false
    // 增量推送状态:记录每个会话上次推送的 JSON 指纹,只推变化的那个(流式时关键)。
    private var lastSessionSig: [String: String] = [:]   // 控制台会话 id → sig
    private var lastManualSig: [String: String] = [:]    // hook 会话 id → sig
    private var lastProjectsSig: String?
    private var sessionsScheduled = false
    private var manualScheduled = false
    private var manualContentScheduled = false
    private var lastManualContentSig: [String: String] = [:]
    private var manualTxStat: [String: (size: UInt64, mtime: TimeInterval)] = [:]
    private var focusedManualId: String?   // 前端当前打开的(终端/hook)会话;只给它读转录推正文,其余不加载
    private let pushQueue = DispatchQueue(label: "webconsole.push.serialize")   // 推送序列化放后台,保序
    private var projectsScheduled = false
    private var pollTimer: Timer?

    init(manager: AgentSessionManager, store: SessionStore, relayAgent: RelayAgent?, pending: PendingDecisionStore? = nil) {
        self.manager = manager
        self.store = store
        self.relayAgent = relayAgent
        self.pending = pending
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
        // 默认工作目录 / 归属目录 一变,立刻重推项目(否则改了设置 web 不刷新,散会话归不进 workplace)。
        AppSettings.shared.$defaultWorkdir.sink { [weak self] _ in self?.scheduleProjects() }.store(in: &cancellables)
        AppSettings.shared.$defaultSessionDirs.sink { [weak self] _ in self?.scheduleProjects() }.store(in: &cancellables)
        store.$sessions.sink { [weak self] _ in self?.scheduleManual(); self?.scheduleManualContent() }.store(in: &cancellables)
        // 终端会话审批一来/一走,重推 manual(控制台据此显示/收起审批卡)。
        pending?.$pendingIDs.sink { [weak self] _ in self?.scheduleManual() }.store(in: &cancellables)
        // 定时轮询活跃会话转录:入队/内容增长不触发 hook 事件,光等 store 变化会延迟几秒。
        // 0.3s 看一眼(size+mtime 缓存,没长大就跳过),让「排队中」几乎即时显示。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.scheduleManualContent() }
        relayAgent?.$connState.sink { [weak self] _ in self?.pushConn() }.store(in: &cancellables)
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
            ready = true; pushState(); pushConn(); pushPrefs()
        case "setHost":
            if let host = obj["host"] as? String { AgentServer.host = host; pushConn(); pushPrefs() }
        case "setLaunchAtLogin":
            if let v = obj["value"] as? Bool { AppSettings.shared.launchAtLogin = v; pushPrefs() }
        case "setMute":
            if let v = obj["value"] as? Bool { AppSettings.shared.muted = v; pushPrefs() }
        case "removeProject":
            if let wd = obj["workdir"] as? String { manager?.removeProject(wd) }
        case "pickDefaultWorkdir":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "设为默认工作目录"
            if panel.runModal() == .OK, let url = panel.url {
                AppSettings.shared.defaultWorkdir = url.path   // 观察者自动重推;散会话据此归入 workplace
                scheduleProjects()
            }
        case "addDefaultSessionDir":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "归属到默认文件夹"
            if panel.runModal() == .OK, let url = panel.url {
                var dirs = AppSettings.shared.defaultSessionDirs
                if !dirs.contains(url.path) { dirs.append(url.path); AppSettings.shared.defaultSessionDirs = dirs }
                scheduleProjects()
            }
        case "removeDefaultSessionDir":
            if let dir = obj["dir"] as? String {
                AppSettings.shared.defaultSessionDirs.removeAll { $0 == dir }
                scheduleProjects()
            }
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
        case "loadSessionHistory":
            if let sid = obj["sid"] as? String {
                manager?.loadEarlierHistory(for: sid, beforeByte: (obj["beforeByte"] as? NSNumber)?.uint64Value)
            }
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
        case "termPermission":
            // 控制台对终端会话审批的应答 → 回写被 hook 扣住的连接(allow/deny),和手机同一套。
            if let sid = obj["sid"] as? String {
                let allow = obj["allow"] as? Bool ?? false
                let ok = pending?.resolve(sid: sid, decision: allow ? .allow : .deny) ?? false
                if ok {
                    store?.markRunning(sessionId: sid)
                    vlog("web console permission \(allow ? "allow" : "deny") sid=\(sid.prefix(8))")
                } else {
                    vlog("web console permission failed: no live hook sid=\(sid.prefix(8))")
                }
                scheduleManual()
            }
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

        case "focusSession":
            // 前端打开了某(终端/hook)会话 → 只给它读转录、推实时正文;切走 / 打开的是控制台会话
            // (走进程流,不读转录)则置 nil,其余会话一律不加载正文。
            focusedManualId = obj["id"] as? String
            scheduleManualContent()

        // ── 账号登录:登录页 UI 在 React;调用走桥接(和会话/项目同一套),原生帮忙发请求 ──
        // 每个请求带 reqId,结果经 "authResult" push 回带同一 reqId,前端 await 对应 promise。
        case "checkAccount":
            let r = reqId(obj); let acc = account(obj)
            runAuth(r) { let c = try await DeviceLogin.check(account: acc); return ["exists": c.exists, "hasPassword": c.hasPassword] }
        case "login":
            let r = reqId(obj); let acc = account(obj); let pw = obj["password"] as? String ?? ""
            runAuth(r) { ["account": try await DeviceLogin.login(account: acc, password: pw)] }
        case "sendCode":
            let r = reqId(obj); let acc = account(obj)
            runAuth(r) { try await DeviceLogin.sendCode(account: acc); return [:] }
        case "loginWithCode":
            let r = reqId(obj); let acc = account(obj); let code = obj["code"] as? String ?? ""
            runAuth(r) { ["account": try await DeviceLogin.loginWithCode(account: acc, code: code)] }
        case "sendRegisterCode":
            let r = reqId(obj); let acc = account(obj)
            runAuth(r) { try await DeviceLogin.sendRegisterCode(account: acc); return [:] }
        case "register":
            let r = reqId(obj); let acc = account(obj); let code = obj["code"] as? String ?? ""; let pw = obj["password"] as? String ?? ""
            runAuth(r) { ["account": try await DeviceLogin.register(account: acc, code: code, password: pw)] }
        case "sendForgotCode":
            let r = reqId(obj); let acc = account(obj)
            runAuth(r) { try await DeviceLogin.sendForgotCode(account: acc); return [:] }
        case "resetPassword":
            let r = reqId(obj); let acc = account(obj); let code = obj["code"] as? String ?? ""; let pw = obj["password"] as? String ?? ""
            runAuth(r) { try await DeviceLogin.resetPassword(account: acc, code: code, password: pw); return [:] }
        case "logout":
            AgentCredentials.clear()
            NotificationCenter.default.post(name: .relayCredentialsChanged, object: nil)
            pushConn()

        default:
            break
        }
    }

    private func reqId(_ obj: [String: Any]) -> String { obj["reqId"] as? String ?? "" }
    private func account(_ obj: [String: Any]) -> String {
        (obj["account"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 跑一个登录类异步请求,结果(成功 payload + ok / 失败 error)经 authResult push 回带 reqId。
    private func runAuth(_ reqId: String, _ work: @escaping () async throws -> [String: Any]) {
        Task { [weak self] in
            var payload: [String: Any]
            do { payload = try await work(); payload["ok"] = true }
            catch { payload = ["ok": false, "error": (error as NSError).localizedDescription] }
            payload["reqId"] = reqId
            await MainActor.run { self?.pushJSON(type: "authResult", payload: payload); self?.pushConn() }
        }
    }

    private func raiseWindow(manualId: String) {
        guard let e = store?.sessions.first(where: { $0.id == manualId }),
              let start = e.ownerPID ?? e.terminalPID, start > 1,
              let appPid = ProcessUtils.findTerminal(startPid: start).pid else { return }
        // 控制台跑在后台:.activateIgnoringOtherApps 在 macOS 14+ 已失效(no-op)。
        // 用 AX kAXFrontmost(jumpToTerminal 同款,已验证可从后台把 JetBrains/终端带到前台)。
        if let app = NSRunningApplication(processIdentifier: appPid), app.isHidden { app.unhide() }
        WindowActivator.bringAppFrontmost(pid: appPid)
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

    /// 把转录窗口解析成前端 transcript msg 数组(loadTranscript 与「活跃会话实时推」共用)。
    /// nonisolated:可在后台线程解析,算完再回主线程推。
    nonisolated private static func buildTranscriptMsgs(path: String, endByte: UInt64?, windowBytes: Int = 1024 * 1024)
        -> (msgs: [[String: Any]], queued: [[String: Any]], earliest: Int, hasEarlier: Bool) {
        // 窗口 1MB:装得下整张图片行(单张内联 base64 可达 ~650KB)以便建索引。文字解析仍快——
        // 图片不再在此解码(只登记位置),真要看时 scheme handler 后台现切现解,所以窗口大也不卡。
        let win = AgentSessionManager.parseTranscriptWindow(path: path, endByte: endByte, windowBytes: windowBytes)
        let imgMap = AgentSessionManager.transcriptImages(path: path, endByte: endByte, windowBytes: windowBytes)
        let msgs = win.messages.map { m -> [String: Any] in
            var d: [String: Any] = ["id": "h\(m.ord)", "role": m.role, "kind": m.kind.rawValue, "text": m.text, "ord": m.ord]
            var imgs = imgMap[m.ord] ?? []                        // Claude 历史内联图片索引
            for im in AgentSessionManager.localImageDTOs(in: m.text) where !imgs.contains(where: { $0["id"] == im["id"] }) {
                imgs.append(im)
            }
            if !imgs.isEmpty { d["images"] = imgs }
            if let op = m.op { d["op"] = toolOpJSON(op) }         // 结构化动作(diff/目录)
            if let mo = m.model, !mo.isEmpty { d["model"] = mo }
            if let ts = m.ts { d["ts"] = ts }
            return d
        }
        return (msgs, win.queued, win.earliest, win.hasEarlier)
    }

    private func loadTranscript(id: String, path: String?, beforeByte: UInt64?) {
        guard let path else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = Self.buildTranscriptMsgs(path: path, endByte: beforeByte)
            let usage = AgentSessionManager.lastContextUsage(path: path)
            await MainActor.run {
                self?.pushJSON(type: "transcript", payload: [
                    "id": id, "messages": r.msgs, "queued": r.queued, "earliest": r.earliest, "hasEarlier": r.hasEarlier,
                    "contextTokens": usage.tokens, "contextWindow": usage.window ?? 200_000,
                ])
            }
        }
    }

    /// 活跃 hook 会话(working/waiting)的正文:随 store 变化重新解析转录尾窗 → 推 `transcript`
    /// (前端按 id 替换合并 → 实时更新)。修复「前台终端会话正文冻结」:与 iOS 同样跟随活动。
    /// 指纹去重避免没变化时空推;只对活跃会话做,idle/done 用户打开时 loadTranscript 一次即可。
    private func pushManualContent() {
        // 只给「前端当前打开的那个会话」读转录推正文 —— 没打开的会话一律不加载(列表只要标题/元数据)。
        guard ready, let focus = focusedManualId,
              let e = store?.sessions.first(where: { $0.id == focus }),
              let tp = e.transcriptPath else { return }
        // 转录没增长就跳过:stat 很廉价,只在文件真长大时才解析,避免重复解析堆积。
        let attrs = try? FileManager.default.attributesOfItem(atPath: tp)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let s = manualTxStat[e.id], s.size == size, s.mtime == mtime { return }
        manualTxStat[e.id] = (size, mtime)
        let sid = e.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = Self.buildTranscriptMsgs(path: tp, endByte: nil)
            // 手动会话走转录解析,没有实时 .usage 事件 → 从转录尾部最近一条 assistant 的 usage 算上下文占用。
            let usage = AgentSessionManager.lastContextUsage(path: tp)
            await MainActor.run {
                guard let self, self.ready else { return }
                guard let sig = self.jsonSig(["m": r.msgs, "q": r.queued, "c": usage.tokens, "w": usage.window ?? 200_000]) else { return }   // 排队/容量变化也要推
                guard self.lastManualContentSig[sid] != sig else { return }
                self.lastManualContentSig[sid] = sig
                self.pushJSON(type: "transcript", payload: [
                    "id": sid, "messages": r.msgs, "queued": r.queued, "earliest": r.earliest, "hasEarlier": r.hasEarlier,
                    "contextTokens": usage.tokens, "contextWindow": usage.window ?? 200_000,
                ])
            }
        }
    }
    private func scheduleManualContent() {
        guard ready, !manualContentScheduled else { return }
        manualContentScheduled = true
        Task { @MainActor in self.manualContentScheduled = false; self.pushManualContent() }
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

    private static var ensuredDefaultRoot: String?
    /// 默认工作目录:桌面设置里设了就用它;没设则回退 ~/.vibenotch/workplace(并建好目录)。
    /// 新建会话建在这;它 + 用户登记的「会话归属目录」共同决定哪些会话归到默认文件夹。
    private func normPath(_ s: String) -> String {
        var p = (s.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
    private func resolvedDefaultWorkdir() -> String {
        let set = AppSettings.shared.defaultWorkdir.trimmingCharacters(in: .whitespaces)
        if !set.isEmpty { return normPath(set) }
        if let c = Self.ensuredDefaultRoot { return c }
        let p = NSString(string: "~/.vibenotch/workplace").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        Self.ensuredDefaultRoot = p
        return p
    }

    private func projectsPayload(_ manager: AgentSessionManager) -> [String: Any] {
        let meta = SessionMetaStore.shared
        // 默认工作目录始终在列表里(供散会话归类 + 新建会话,且不可移除)。
        let def = resolvedDefaultWorkdir()
        // 「会话归属目录」:用户登记的、希望其会话归到默认文件夹的目录(不想导入成独立项目)。
        let funnelDirs = AppSettings.shared.defaultSessionDirs.map { normPath($0) }
        let roots = ([def] + funnelDirs).reduce(into: [String]()) { acc, p in if !acc.contains(p) { acc.append(p) } }
        var wds = manager.projects
        // 默认根 + 归属目录都进列表(为了把它们各自的历史也加载、带给前端);前端按 defaultRoots 决定「不渲染成文件夹、历史并进默认组」。
        for r in roots where !wds.contains(r) { wds.insert(r, at: 0) }
        let projects = wds.map { proj -> [String: Any] in
            manager.loadHistoryList(for: proj)   // 懒加载历史(已缓存则跳过)
            let hist = (manager.historyByProject[proj] ?? []).compactMap { h -> [String: Any]? in
                if meta.isHidden(h.id) { return nil }
                return ["id": h.id, "key": h.id, "label": meta.title(for: h.id) ?? h.label,
                        "mtime": h.mtime.timeIntervalSince1970 * 1000, "agent": h.agent.rawValue]
            }
            return ["workdir": proj, "name": (proj as NSString).lastPathComponent, "history": hist]
        }
        let hidden = meta.hiddenEntries().map { ["key": $0.key, "title": $0.title] }
        // defaultRoots = 默认目录 + 归属目录:前端据此「不把它们渲染成文件夹、把它们的历史并进默认组」。
        return ["projects": projects, "hidden": hidden, "defaultWorkdir": def,
                "defaultRoots": roots, "defaultSessionDirs": funnelDirs]
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
            "defaultWorkdir": proj["defaultWorkdir"] ?? "",
            "defaultRoots": proj["defaultRoots"] ?? [], "defaultSessionDirs": proj["defaultSessionDirs"] ?? [],
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
            "loggedIn": !(AgentCredentials.account ?? "").isEmpty,
            "state": connKey(st),
            "text": connText(st),
        ])
    }
    /// 偏好设置(原菜单栏「设置」搬到 web 控制台设置页):中转地址 + 开机启动 + 静音。
    private func pushPrefs() {
        guard ready else { return }
        pushJSON(type: "prefs", payload: [
            "host": AgentServer.host,
            "launchAtLogin": AppSettings.shared.launchAtLogin,
            "muted": AppSettings.shared.muted,
        ])
    }

    private func connKey(_ s: RelayAgent.ConnState) -> String {
        switch s {
        case .unpaired: return "unpaired"; case .connecting: return "connecting"
        case .online: return "online"; case .pausedByPhone: return "paused"
        case .suspendedByPhone: return "suspended"
        case .rejected: return "rejected"; case .offline: return "offline"
        }
    }
    private func connText(_ s: RelayAgent.ConnState) -> String {
        switch s {
        case .online:           return "已连接中转服务器"
        case .connecting:       return "连接中…"
        case .pausedByPhone:    return "已被手机端暂停 —— 在手机「设备」页点「恢复」即可继续(连接保持)"
        case .suspendedByPhone: return "已被手机端挂起 —— 10s 后自动重试"
        case .rejected(let c):  return "被服务器拒绝(\(c)),请重新配对"
        case .unpaired:         return "未配对,离线"
        case .offline:          return "离线,自动重连中…"
        }
    }
    /// 会话的稳定 key:优先 claude session_id(跨重启/与历史统一),没有则用内部 id。
    private func sessionKey(_ s: AgentSession) -> String {
        if let a = s.agentSessionId, !a.isEmpty { return a }
        return s.id
    }

    private func manualDTO(_ e: SessionEntry) -> [String: Any]? {
        let meta = SessionMetaStore.shared
        if meta.isHidden(e.id) {
            // 隐藏=归档。但若这个终端会话又活跃了(在 JetBrains/终端里 resume/继续干活),
            // 说明用户重新需要它 → 取消归档并照常显示(否则它一直隐身,前台终端唤不起来)。
            let live = manualState(e.state) == "working" || manualState(e.state) == "waiting"
            if live { meta.unhide(e.id) } else { return nil }
        }
        let agent = e.transcriptPath.flatMap { CodingAgents.forTranscript($0)?.id } ?? "claude"
        let base = e.promptSummary.map { String($0.prefix(40)) }
            ?? e.transcriptPath.flatMap { AgentSessionManager.firstUserPrompt(path: $0) }.map { String($0.prefix(40)) }
            ?? "手动会话"
        let isPendingPerm = pending?.pendingIDs.contains(e.id) ?? false
        return [
            "id": e.id, "key": e.id, "title": meta.title(for: e.id) ?? base, "cwd": e.cwd,
            "terminal": e.terminal.displayName,
            "agent": agent,
            "state": isPendingPerm ? "waiting" : manualState(e.state),
            "lastActivityAt": e.lastActivityAt.timeIntervalSince1970 * 1000,
            // 终端会话被 hook 扣住的权限审批(如 git push):控制台据此渲染允许/拒绝卡,点击经 termPermission 回写。
            "pendingPerm": isPendingPerm,
            "pendingDetail": (isPendingPerm ? pending?.detail(sid: e.id) : nil) ?? e.toolDetail ?? "",
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
            "contextTokens": s.contextTokens,
            "contextWindow": s.contextWindow,
            "historyEarliest": s.historyEarliest,
            "historyHasEarlier": s.historyHasEarlier,
            "agentSessionId": s.agentSessionId ?? "",
            "startedAt": s.startedAt.timeIntervalSince1970 * 1000,
            "messages": s.messages.map { msgDTO($0) },
            "pending": s.pending.map { pendingDTO($0) },
        ]
    }
    private func msgDTO(_ m: AgentMessage) -> [String: Any] {
        var d: [String: Any] = ["id": m.id, "role": m.role, "kind": m.kind.rawValue, "text": m.text, "ord": m.ord]
        var imgs = m.images.map { ["id": $0.id, "ext": $0.ext] }
        for im in AgentSessionManager.localImageDTOs(in: m.text) where !imgs.contains(where: { $0["id"] == im["id"] }) {
            imgs.append(im)
        }
        if !imgs.isEmpty {
            // 通道只带 id;web 用 app://__img/<id>.<ext> 按 id 取字节(scheme handler 本地缓存命中/本地文件命中或回源)
            d["images"] = imgs
        }
        if let ps = m.permState { d["permState"] = ps }
        if let pr = m.permReqId { d["permReqId"] = pr }
        if let op = m.op { d["op"] = toolOpJSON(op) }
        if let mo = m.model, !mo.isEmpty { d["model"] = mo }
        if let ts = m.ts { d["ts"] = ts }
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
        // payload 是已构建好的值快照(字典/数组/字符串,非可变模型引用)→ 序列化放后台串行队列,
        // 只把 evaluateJavaScript 留主线程。大 payload 不再卡主线程;串行队列保证推送顺序不乱。
        let wrapped: [String: Any] = ["type": type, "payload": payload]
        pushQueue.async { [weak self] in
            guard let data = try? JSONSerialization.data(withJSONObject: wrapped),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript("window.__agent && window.__agent.push(\(json))", completionHandler: nil)
            }
        }
    }
}

/// 结构化动作 → JSON(msgDTO 与转录加载共用;放文件作用域,供 off-main 转录解析直接调)。
func toolOpJSON(_ op: ToolOp) -> [String: Any] {
    var d: [String: Any] = ["kind": op.kind.rawValue, "file": op.file, "dir": op.dir]
    if let a = op.add { d["add"] = a }
    if let de = op.del { d["del"] = de }
    if op.sameFile { d["sameFile"] = true }
    if let c = op.command { d["command"] = c }
    if !op.diff.isEmpty { d["diff"] = op.diff.map { ["k": $0.kind, "t": $0.text] } }
    if !op.output.isEmpty { d["output"] = op.output }
    if let l = op.label { d["label"] = l }
    return d
}

/// 把打包进 app 的 dist/ 文件用 app:// scheme 喂给 WKWebView。
final class DistSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    init(root: URL) { self.root = root }
    // 图片在后台线程取/解时,task 可能已被取消(img 移出 DOM)。记下已 stop 的 task,回调前判一下,避免崩。
    private let lock = NSLock()
    private var stopped = Set<ObjectIdentifier>()
    private func isStopped(_ t: WKURLSchemeTask) -> Bool { lock.lock(); defer { lock.unlock() }; return stopped.contains(ObjectIdentifier(t)) }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFinish(); return }
        var path = url.path
        if path.hasPrefix("/__img/") {
            // 会话图片:按 id 取字节。**放后台线程**现切现解(历史图 base64 很大),不阻塞主线程 →
            // 文字消息先渲染、图片异步随后出。优先本地转录索引(ensureFromIndex),再回源下载。
            let name = String(path.dropFirst("/__img/".count))   // <id>.<ext>
            let id = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let local = id.isEmpty ? nil : (ImageRelay.ensureFromIndex(id: id, ext: ext) ?? ImageRelay.localFilePath(id: id) ?? ImageRelay.ensureCached(id: id, ext: ext))
                let data = local.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                guard let self, !self.isStopped(task) else { return }
                if let data {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": Self.mime(ext), "Access-Control-Allow-Origin": "*"])!
                    task.didReceive(resp); task.didReceive(data); task.didFinish()
                } else {
                    let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                    task.didReceive(resp); task.didFinish()
                }
            }
            return
        }
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
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { lock.lock(); stopped.insert(ObjectIdentifier(task)); lock.unlock() }

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
