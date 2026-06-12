import AppKit
import Combine
import DynamicNotchKit
import ServiceManagement
import SwiftUI

typealias VibeNotch = DynamicNotch<NotchExpandedView, NotchCompactSummary, NotchCompactSummary>

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in self.rebuildDisplaySubmenu() }
    }

    private var notch: VibeNotch?
    private var statusItem: NSStatusItem?
    private var hoverObserver: AnyCancellable?
    private var transitionsCancellable: AnyCancellable?
    private var pendingTask: Task<Void, Never>?
    private var udsServer: UDSServer?
    private var collapseDebounceTimer: Timer?
    private var lastHoverState: Bool = false
    private static let hoverCollapseGrace: TimeInterval = 0.20
    let store = SessionStore()
    let pendingStore = PendingDecisionStore()
    private var relayAgent: RelayAgent?
    private var autoExpandUntil: Date?
    private var expiryTimer: Timer?
    private var idleSweepTimer: Timer?
    private var livenessSweepTimer: Timer?
    private var replyRefreshTasks: [String: Task<Void, Never>] = [:]
    /// 被扣住的 AskUserQuestion hook 连接(sid → conn):手机经 hook 直接回答,
    /// 超时或用户选「改在电脑上回答」才放行到终端 TUI。
    private var questionGates: [String: HookConnection] = [:]
    private var questionGateTimers: [String: Task<Void, Never>] = [:]
    private static let questionGateTimeoutSeconds: TimeInterval = 280
    private var questionGateWatchTimer: Timer?

    private static let doneAutoExpandSeconds: TimeInterval = 5
    private static let waitingAutoExpandSeconds: TimeInterval = 8
    private static let pendingDecisionTimeoutSeconds: TimeInterval = 45
    private static let idleSweepIntervalSeconds: TimeInterval = 5 * 60
    private static let livenessSweepIntervalSeconds: TimeInterval = 5

    static let socketPath: String = {
        NSString(string: "~/.vibenotch/sock").expandingTildeInPath
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        pendingStore.onTimeout = { [weak self] sid in
            self?.handlePendingTimeout(sessionId: sid)
        }
        // Touch AppSettings.shared so it loads ~/.vibenotch/settings.json and
        // syncs `muted` into SoundPlayer before any transition can fire.
        _ = AppSettings.shared
        vlog("launched")
        vlog("screens count=\(NSScreen.screens.count)")
        for (i, s) in NSScreen.screens.enumerated() {
            vlog("screen[\(i)] name=\(s.localizedName) frame=\(s.frame) safeAreaTop=\(s.safeAreaInsets.top)")
        }
        setupStatusItem()
        vlog("status item ok")
        setupNotch()
        vlog("setupNotch returned")
        setupUDS()
        installHooks()
        startIdleSweep()
        startLivenessSweep()
        setupRelayAgent()
        startQuestionGateWatch()
    }

    /// 每 2s 巡检被扣住的问题连接:hook 脚本被 claude 超时杀掉(POLLHUP)→
    /// 立即收尾并让手机卡片翻成「已转电脑作答」,而不是等用户提交才发现失效。
    private func startQuestionGateWatch() {
        questionGateWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.questionGates.isEmpty else { return }
                for (sid, conn) in self.questionGates where conn.isPeerClosed {
                    vlog("question gate peer closed(被 claude 超时杀掉)→ 转电脑作答 sid=\(sid.prefix(8))")
                    self.questionGateTimers[sid]?.cancel(); self.questionGateTimers[sid] = nil
                    self.questionGates[sid] = nil
                    self.relayAgent?.questionGateExpired(sid: sid)
                }
            }
        }
    }

    /// 快速清扫:每 5 秒检查各会话的 owner 进程是否还活着,移除已死的(终端被关/强杀、
    /// 没有 SessionEnd 的异常退出)。移除后 store.$sessions 变化 → RelayAgent 推删除给手机。
    private func startLivenessSweep() {
        livenessSweepTimer?.invalidate()
        livenessSweepTimer = Timer.scheduledTimer(
            withTimeInterval: Self.livenessSweepIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let dead = self.store.removeDeadSessions()
                guard !dead.isEmpty else { return }
                vlog("liveness-sweep removed \(dead.count): \(dead.map { $0.prefix(8) }.joined(separator: ","))")
                for sid in dead {
                    self.cancelReplyRefresh(sessionId: sid)
                    self.pendingStore.cancel(sid: sid)
                }
            }
        }
    }

    /// 放行被扣住的问题 → 终端 TUI 正常弹题。
    private func releaseQuestionGate(sid: String) {
        questionGateTimers[sid]?.cancel(); questionGateTimers[sid] = nil
        questionGates.removeValue(forKey: sid)?.dismiss()
    }

    /// 经 hook 把手机的选择精确回传给 Claude(deny + 明确说明这是用户的回答)。
    /// 返回 false = hook 已放行,调用方走按键回退。
    private func answerQuestionViaGate(sid: String, question: String, labels: String) -> Bool {
        guard let conn = questionGates.removeValue(forKey: sid) else { return false }
        questionGateTimers[sid]?.cancel(); questionGateTimers[sid] = nil
        let reason = "(这不是拒绝)用户已通过手机客户端回答了该问题。问题「\(question)」的答案是: \(labels)。请将其作为用户的正式回答继续执行,不要重新提问。"
        let payload: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8), conn.respond(json: json) else {
            // 连接已死(hook 被 claude 超时杀掉,TUI 已弹题)→ 让调用方走回退
            vlog("question gate respond failed(连接已死) sid=\(sid.prefix(8))")
            return false
        }
        store.clearPendingQuestion(sessionId: sid)   // 不会再有 PostToolUse,这里直接收尾
        return true
    }

    /// 接入 AI Coding Remote 中转：把会话推给手机,并把手机的 Allow/Deny 接到 decide()。
    private func setupRelayAgent() {
        let agent = RelayAgent(store: store, pending: pendingStore)
        agent.onRemoteDecision = { [weak self] sid, decision in
            guard let self else { return }
            // 仅当该会话确实在等待决定时才处理(防止手机误点已过期的卡)。
            guard self.pendingStore.pendingIDs.contains(sid) else {
                vlog("relay decision ignored: sid=\(sid.prefix(8)) not pending")
                return
            }
            vlog("relay remote \(decision == .allow ? "allow" : "deny") sid=\(sid.prefix(8))")
            self.decide(sessionId: sid, decision: decision)
        }
        agent.onRemoteClose = { [weak self] sid in
            guard let self else { return }
            guard let entry = self.store.sessions.first(where: { $0.id == sid }) else {
                vlog("relay close ignored: sid=\(sid.prefix(8)) unknown")
                return
            }
            vlog("relay remote close sid=\(sid.prefix(8)) ownerPID=\(entry.ownerPID.map(String.init) ?? "-")")
            self.pendingStore.cancel(sid: sid)   // 丢弃挂起的审批连接(若有)
            if let pid = entry.ownerPID {
                kill(pid, SIGTERM)   // 结束 claude 进程 → SessionEnd hook → 会话移除并同步到手机
            } else {
                // 不知道进程号(罕见)→ 直接移除会话,保证手机端也消失
                self.store.removeSession(sessionId: sid)
            }
        }
        agent.onRemoteInput = { [weak self] sid, text, imagePaths in
            guard let self else { return }
            guard self.store.sessions.contains(where: { $0.id == sid }) else {
                vlog("relay input ignored: sid=\(sid.prefix(8)) unknown")
                return
            }
            if !WindowActivator.isAccessibilityTrusted {
                WindowActivator.requestAccessibilityIfNeeded()
                vlog("relay input: AX not trusted — prompted, dropping input")
                return
            }
            // 组装注入文本:用户文字 + 图片路径(claude 会自己读路径里的图)
            var parts: [String] = []
            if !text.isEmpty { parts.append(text) }
            if !imagePaths.isEmpty {
                parts.append(imagePaths.count == 1 && text.isEmpty
                             ? "请查看这张图片: \(imagePaths[0])"
                             : imagePaths.map { "图片: \($0)" }.joined(separator: " "))
            }
            let message = parts.joined(separator: " ")
            vlog("relay input sid=\(sid.prefix(8)) len=\(message.count) imgs=\(imagePaths.count)")
            // 必须确认激活了目标终端窗口才打字,否则会敲进用户当前聚焦的任意应用
            guard self.jumpToTerminal(sessionId: sid) else {
                vlog("relay input dropped: terminal activation failed sid=\(sid.prefix(8))")
                return
            }
            // 等窗口激活、输入焦点就位后再打字
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                TerminalTyper.type(message)
            }
        }
        agent.onRemoteAnswer = { [weak self] sid, digits, isMulti, labels in
            guard let self else { return }
            guard let entry = self.store.sessions.first(where: { $0.id == sid }),
                  let pq = entry.pendingQuestion else {
                vlog("relay answer ignored: sid=\(sid.prefix(8)) 没有待答问题")
                return
            }
            // 路径一(首选):hook 还扣着 → 把答案精确回传给 Claude,零按键注入
            if self.answerQuestionViaGate(sid: sid, question: pq.questions.first?.question ?? "", labels: labels) {
                vlog("relay answer via hook: sid=\(sid.prefix(8)) labels=\(labels)")
                return
            }
            // 路径二(回退):hook 已放行(超时/转电脑后又在手机点)→ 单选注入数字键;
            // 多选按键时序不可靠,不注入,提示在电脑完成
            guard !isMulti else {
                vlog("relay answer dropped: 多选已放行到终端,不做按键注入 sid=\(sid.prefix(8))")
                self.relayAgent?.questionAnswerFailed(sid: sid)   // 卡片提示改在电脑作答
                return
            }
            if !WindowActivator.isAccessibilityTrusted {
                WindowActivator.requestAccessibilityIfNeeded()
                return
            }
            guard self.jumpToTerminal(sessionId: sid) else { return }
            if let d = digits.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    TerminalTyper.type(d, thenReturn: false)
                }
            }
        }
        agent.onRemoteAnswerLocal = { [weak self] sid in
            guard let self else { return }
            vlog("question → 用户选择在电脑上回答 sid=\(sid.prefix(8))")
            self.releaseQuestionGate(sid: sid)
            self.jumpToTerminal(sessionId: sid)   // 把终端带到前台,题目马上弹出
        }
        agent.start()
        relayAgent = agent
        SettingsWindowController.shared.relayAgent = agent

        // 手机配对成功 / 退出登录 → 以新账号身份重连中转
        NotificationCenter.default.addObserver(forName: .relayCredentialsChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                vlog("relay credentials changed → reconnect as \(RelayAgent.account)")
                self?.relayAgent?.restart()
            }
        }
    }

    /// Periodically drop sessions whose hook stream has gone silent (e.g. the
    /// host terminal was force-quit, so no SessionEnd ever arrived). Threshold
    /// is `SessionStore.idleRemovalSeconds`.
    private func startIdleSweep() {
        idleSweepTimer?.invalidate()
        idleSweepTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleSweepIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let dropped = self.store.pruneIdle(
                    maxIdleSeconds: SessionStore.idleRemovalSeconds
                )
                guard !dropped.isEmpty else { return }
                vlog("idle-sweep removed \(dropped.count) session(s): \(dropped.map { $0.prefix(8) }.joined(separator: ","))")
                for sid in dropped {
                    self.cancelReplyRefresh(sessionId: sid)
                    self.pendingStore.cancel(sid: sid)
                }
            }
        }
    }

    private func installHooks() {
        do {
            try HookInstaller.install()
        } catch {
            vlog("hook install failed: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleSweepTimer?.invalidate()
        idleSweepTimer = nil
        livenessSweepTimer?.invalidate()
        livenessSweepTimer = nil
        pendingStore.dismissAll()
        relayAgent?.stop()
        udsServer?.stop()
    }

    private func setupUDS() {
        let path = AppDelegate.socketPath
        let server = UDSServer(path: path)
        server.onEvent = { [weak self] conn in
            self?.handleConnection(conn)
        }
        do {
            try server.start()
            vlog("UDS listening at \(path)")
        } catch {
            vlog("UDS start failed: \(error)")
        }
        udsServer = server
    }

    /// Routes an incoming hook connection. Dangerous PreToolUse events are
    /// enrolled in `pendingStore`; everything else is dismissed immediately.
    private func handleConnection(_ conn: HookConnection) {
        let event = conn.event
        let term: String = {
            guard let p = event.ppid, p > 1 else { return "?" }
            return ProcessUtils.findTerminalKind(startPid: pid_t(p)).displayName
        }()
        vlog("EVENT \(event.hookEventName) session=\(event.sessionId?.prefix(8) ?? "?") tool=\(event.toolName ?? "-") ppid=\(event.ppid.map(String.init) ?? "-") term=\(term)")
        store.apply(event)

        // 每个工具/停止事件来时立即读一次转录,不等下一次 800ms 轮询 → 执行完一步即时显示
        // (刘海 + 手机两端都受益,因为 RelayAgent 订阅 store 变化即时推送)。
        if let sid = event.sessionId, let path = event.transcriptPath {
            switch event.hookEventName {
            case "PreToolUse", "PostToolUse", "Stop", "Notification":
                store.updateTurnSteps(sessionId: sid, steps: TranscriptReader.currentTurnSteps(transcriptPath: path))
            default:
                break
            }
        }

        // Start polling the transcript as soon as a new turn begins so that
        // intermediate assistant text (between tool calls) surfaces live, not
        // only after Stop. The poll auto-cancels on the next UPS.
        if event.hookEventName == "UserPromptSubmit",
           let sid = event.sessionId,
           let path = event.transcriptPath {
            scheduleReplyRefresh(sessionId: sid, transcriptPath: path)
        }
        // Also start a poll on Stop in case the App was launched mid-turn and
        // missed the UPS (e.g. App restart while claude was thinking).
        if event.hookEventName == "Stop",
           let sid = event.sessionId,
           let path = event.transcriptPath,
           replyRefreshTasks[sid] == nil {
            scheduleReplyRefresh(sessionId: sid, transcriptPath: path)
        }

        if event.hookEventName == "PreToolUse",
           let tool = event.toolName,
           PolicyConstants.dangerousTools.contains(tool),
           let sid = event.sessionId {
            vlog("pending permission: sid=\(sid.prefix(8)) tool=\(tool)")
            pendingStore.add(sid: sid, conn: conn)
        } else if event.hookEventName == "PreToolUse",
                  event.toolName == "AskUserQuestion",
                  let sid = event.sessionId {
            // 扣住问题:手机可经 hook 字节级精确回答(不模拟按键);
            // 超时 / 用户选「改在电脑上回答」→ 放行,终端正常弹题。
            vlog("question gate hold: sid=\(sid.prefix(8))")
            questionGates[sid]?.dismiss()
            questionGateTimers[sid]?.cancel()
            questionGates[sid] = conn
            questionGateTimers[sid] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.questionGateTimeoutSeconds * 1_000_000_000))
                guard let self, self.questionGates[sid] === conn else { return }
                vlog("question gate timeout → 放行到终端 sid=\(sid.prefix(8))")
                self.releaseQuestionGate(sid: sid)
            }
        } else {
            conn.dismiss()
        }
    }

    /// Polls the transcript every 800ms for the CURRENT-turn assistant text
    /// (anything after the latest user prompt). Runs indefinitely so that
    /// intermediate text Claude writes between tool calls also surfaces — the
    /// only ways out are: next UserPromptSubmit (cancel) or App termination.
    func scheduleReplyRefresh(sessionId: String, transcriptPath: String) {
        replyRefreshTasks[sessionId]?.cancel()
        let task = Task { @MainActor [weak self] in
            var lastSteps: [TurnStep] = []
            let started = Date()
            while !Task.isCancelled {
                guard let self else { return }
                let steps = TranscriptReader.currentTurnSteps(transcriptPath: transcriptPath)
                if steps != lastSteps {
                    lastSteps = steps
                    self.store.updateTurnSteps(sessionId: sessionId, steps: steps)
                    vlog("reply-poll @\(Int(Date().timeIntervalSince(started) * 1000))ms sid=\(sessionId.prefix(8)) steps=\(steps.count)")
                }
                try? await Task.sleep(nanoseconds: 400 * 1_000_000)
            }
        }
        replyRefreshTasks[sessionId] = task
    }

    /// Cancels any in-flight reply poll for a session — invoked when the next
    /// UserPromptSubmit arrives so we don't accidentally backfill the new
    /// turn's row with stale reply data.
    func cancelReplyRefresh(sessionId: String) {
        replyRefreshTasks[sessionId]?.cancel()
        replyRefreshTasks[sessionId] = nil
    }

    /// IDE-style terminals — files opened from a session whose terminal is
    /// one of these will be launched IN that IDE (via its NSRunningApplication
    /// bundle URL). Plain shells fall back to the system default app.
    private static let ideTerminalKinds: Set<TerminalKind> = [
        .vscode, .cursor, .windsurf, .jetbrains, .xcode,
    ]

    /// Open a file referenced by a tool chip in the timeline. Routes to the
    /// session's owning IDE when applicable, otherwise the user's default app.
    func openFile(sessionId: String, path: String) {
        guard let entry = store.sessions.first(where: { $0.id == sessionId }) else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        if Self.ideTerminalKinds.contains(entry.terminal),
           let pid = entry.terminalPID,
           let app = NSRunningApplication(processIdentifier: pid),
           let bundleURL = app.bundleURL {
            vlog("openFile \(path) → \(app.localizedName ?? "?")")
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: bundleURL, configuration: cfg) { _, error in
                if let error {
                    vlog("openFile IDE failed: \(error.localizedDescription) — fallback default")
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
            }
        } else {
            vlog("openFile \(path) → default app")
            NSWorkspace.shared.open(url)
        }
    }

    /// Activate the terminal app behind a session row, if we know its PID.
    /// For multi-window IDEs (PyCharm hosts N project windows in 1 process),
    /// `app.activate` brings the app forward but not the *right* window.
    /// We first try the Accessibility path to raise the window whose title
    /// matches the session's cwd; whole-app activate is the fallback.
    @discardableResult
    func jumpToTerminal(sessionId: String) -> Bool {
        guard let entry = store.sessions.first(where: { $0.id == sessionId }) else { return false }
        guard let pid = entry.terminalPID else {
            vlog("jump: no terminalPID for sid=\(sessionId.prefix(8))")
            return false
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            vlog("jump: NSRunningApplication(pid=\(pid)) not found — terminal may have quit")
            return false
        }

        if Self.ideTerminalKinds.contains(entry.terminal) {
            if !WindowActivator.isAccessibilityTrusted {
                WindowActivator.requestAccessibilityIfNeeded()
                vlog("jump: AX not trusted — prompting; falling back to whole-app activate")
            } else if WindowActivator.activateWindow(pid: pid, cwd: entry.cwd) {
                vlog("jump: sid=\(sessionId.prefix(8)) → pid=\(pid) (\(app.localizedName ?? "?")) AX-window-match cwd=\(entry.cwd)")
                return true
            } else {
                vlog("jump: sid=\(sessionId.prefix(8)) AX no window match for cwd=\(entry.cwd) — falling back")
            }
        }

        let ok = app.activate(options: [.activateAllWindows])
        vlog("jump: sid=\(sessionId.prefix(8)) → pid=\(pid) (\(app.localizedName ?? "?")) ok=\(ok)")
        return ok
    }

    /// 45-second watchdog tripped without an Allow/Deny click. Connection is
    /// already dismissed by `PendingDecisionStore`; here we flip the row out
    /// of `.waiting` so the notch can collapse on hover-out.
    func handlePendingTimeout(sessionId: String) {
        vlog("pending timeout sid=\(sessionId.prefix(8)) — clearing waiting state")
        store.markRunning(sessionId: sessionId)
    }

    /// Called by the UI when the user clicks Allow / Deny on a row.
    /// Keeps the notch open for 2 seconds afterwards so the user sees the
    /// row transition from orange → blue before we collapse.
    func decide(sessionId: String, decision: PermissionDecision) {
        vlog("user decided \(decision == .allow ? "allow" : "deny") for sid=\(sessionId.prefix(8))")
        pendingStore.resolve(sid: sessionId, decision: decision)
        store.markRunning(sessionId: sessionId)
        autoExpandUntil = Date().addingTimeInterval(2)
        rescheduleExpiryTimer()
        decideExpansion()
    }

    private var settingsObserver: AnyCancellable?

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "note.text", accessibilityDescription: "VibeNotch")
            let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            button.image = img?.withSymbolConfiguration(cfg)
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        item.menu = menu
        statusItem = item

        rebuildStatusMenu()

        // Live language switch: rebuild status menu + retitle settings window.
        settingsObserver = AppSettings.shared.$language
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.rebuildStatusMenu()
                    SettingsWindowController.shared.refreshTitle()
                }
            }
    }

    /// Rebuild the entire status menu from scratch — cheaper than tracking
    /// individual NSMenuItem references when locale changes.
    private func rebuildStatusMenu() {
        guard let menu = statusMenu else { return }
        let locale = L10n.resolved(from: AppSettings.shared.language)
        menu.removeAllItems()

        menu.addItem({
            let mi = NSMenuItem(
                title: L10n.t(.menuSettings, locale: locale),
                action: #selector(openSettings),
                keyEquivalent: ","
            )
            mi.keyEquivalentModifierMask = [.command]
            return mi
        }())

        menu.addItem(.separator())

        let displayParent = NSMenuItem(
            title: L10n.t(.menuDisplayOn, locale: locale),
            action: nil,
            keyEquivalent: ""
        )
        let displayMenu = NSMenu(title: L10n.t(.menuDisplayOn, locale: locale))
        displayParent.submenu = displayMenu
        menu.addItem(displayParent)
        displaySubmenu = displayMenu

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: L10n.t(.menuQuit, locale: locale),
                action: #selector(quit),
                keyEquivalent: ""
            )
        )

        rebuildDisplaySubmenu()
    }

    private var statusMenu: NSMenu?
    private var displaySubmenu: NSMenu?

    /// Rebuild the "Display on" submenu from the current screen list.
    /// Called on menu open + when screens change so unplugged monitors vanish.
    private func rebuildDisplaySubmenu() {
        guard let menu = displaySubmenu else { return }
        menu.removeAllItems()
        let locale = L10n.resolved(from: AppSettings.shared.language)

        let stored = UserDefaults.standard.string(forKey: Self.preferredScreenKey)
        let auto = NSMenuItem(
            title: L10n.t(.menuDisplayAuto, locale: locale),
            action: #selector(selectAutoScreen),
            keyEquivalent: ""
        )
        auto.state = stored == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        for screen in NSScreen.screens {
            let title = screen.safeAreaInsets.top > 0
                ? "\(screen.localizedName) \(L10n.t(.menuDisplayNotchSuffix, locale: locale))"
                : screen.localizedName
            let mi = NSMenuItem(
                title: title,
                action: #selector(selectScreen(_:)),
                keyEquivalent: ""
            )
            mi.representedObject = screen.localizedName
            mi.state = (stored == screen.localizedName) ? .on : .off
            menu.addItem(mi)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static let preferredScreenKey = "VibeNotch.preferredScreenName"

    /// "Auto" → notch screen if available, else main. Otherwise the screen
    /// whose `localizedName` the user picked from the status-bar submenu.
    private var preferredScreen: NSScreen {
        if let stored = UserDefaults.standard.string(forKey: Self.preferredScreenKey),
           let match = NSScreen.screens.first(where: { $0.localizedName == stored }) {
            return match
        }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    @objc private func selectAutoScreen() {
        UserDefaults.standard.removeObject(forKey: Self.preferredScreenKey)
        rebindNotchToPreferredScreen()
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: Self.preferredScreenKey)
        rebindNotchToPreferredScreen()
    }

    /// Tear down the notch on its old screen and re-show on the newly chosen
    /// one. On a non-notch screen DynamicNotchKit renders the floating top-
    /// center bar, so we keep it expanded (the notch shape doesn't exist).
    private func rebindNotchToPreferredScreen() {
        guard let n = notch else { return }
        let screen = preferredScreen
        vlog("rebind screen → \(screen.localizedName) hasNotch=\(screen.safeAreaInsets.top > 0)")
        Task { @MainActor in
            await n.hide()
            await n.compact(on: screen)
        }
    }

    private func setupNotch() {
        let screen = preferredScreen
        vlog("screen=\(screen.localizedName) frame=\(screen.frame) hasNotch=\(screen.safeAreaInsets.top > 0)")

        let store = self.store
        let pending = self.pendingStore
        let n = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .notch,
            expanded: { [weak self] in
                NotchExpandedView(
                    store: store,
                    pending: pending,
                    onDecide: { sid, decision in
                        self?.decide(sessionId: sid, decision: decision)
                    },
                    onJump: { sid in
                        self?.jumpToTerminal(sessionId: sid)
                    },
                    onOpenFile: { sid, path in
                        self?.openFile(sessionId: sid, path: path)
                    }
                )
            },
            compactLeading: { NotchCompactSummary(store: store, position: .leading) },
            compactTrailing: { NotchCompactSummary(store: store, position: .trailing) }
        )
        notch = n

        hoverObserver = n.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                self?.handleHoverChange(hovering)
            }

        transitionsCancellable = store.transitions
            .sink { [weak self] transition in
                self?.handleTransition(transition)
            }

        Task { @MainActor in
            await n.compact(on: screen)
        }
    }

    /// Expand immediately on hover-true; debounce hover-false by 200ms so the
    /// rapid true/false flicker caused by SwiftUI re-layout during the
    /// expand/compact transition doesn't ping-pong the notch. We snapshot the
    /// observed hover bit ourselves so `decideExpansion` is decoupled from
    /// `notch.isHovering`'s instantaneous (and noisy) value.
    private func handleHoverChange(_ hovering: Bool) {
        collapseDebounceTimer?.invalidate()
        collapseDebounceTimer = nil
        if hovering {
            lastHoverState = true
            decideExpansion()
        } else {
            collapseDebounceTimer = Timer.scheduledTimer(
                withTimeInterval: Self.hoverCollapseGrace,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.lastHoverState = false
                    self?.decideExpansion()
                }
            }
        }
    }

    private func handleTransition(_ t: SessionTransition) {
        var wasWaiting = false
        if let from = t.from, case .waiting(_) = from { wasWaiting = true }

        SoundPlayer.shared.playForTransition(to: t.to)

        switch t.to {
        case .done:
            autoExpandUntil = Date().addingTimeInterval(Self.doneAutoExpandSeconds)
            vlog("auto-expand: done +5s (sid=\(t.sessionId.prefix(8)))")
        case .waiting:
            autoExpandUntil = Date().addingTimeInterval(Self.waitingAutoExpandSeconds)
            vlog("auto-expand: waiting +\(Int(Self.waitingAutoExpandSeconds))s (sid=\(t.sessionId.prefix(8)))")
        case .working:
            if wasWaiting {
                autoExpandUntil = nil
                vlog("auto-expand: cleared (was waiting → working sid=\(t.sessionId.prefix(8)))")
            }
        case .idle:
            break
        }

        rescheduleExpiryTimer()
        decideExpansion()
    }

    private func rescheduleExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let until = autoExpandUntil, until != .distantFuture else { return }
        let interval = until.timeIntervalSinceNow
        if interval <= 0 {
            autoExpandUntil = nil
            return
        }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.autoExpandUntil = nil
                self?.decideExpansion()
            }
        }
    }

    private func decideExpansion() {
        guard let n = notch else { return }
        let autoOn: Bool = {
            guard let until = autoExpandUntil else { return false }
            return until > Date()
        }()
        let screen = preferredScreen
        let shouldExpand = lastHoverState || autoOn
        vlog("decide: hover=\(lastHoverState) autoOn=\(autoOn) shouldExpand=\(shouldExpand)")
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            if shouldExpand {
                await n.expand(on: screen)
            } else {
                await n.compact(on: screen)
            }
        }
    }
}
