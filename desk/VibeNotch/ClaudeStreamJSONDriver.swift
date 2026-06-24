import Foundation

/// claude 适配器:把 `claude` 当长驻子进程,用 stdin/stdout 上的 **stream-json** 双向驱动。
///
/// 已 Phase 0 实测(2.1.173):双向流、多轮上下文、session_id/resume、选项卡
/// (AskUserQuestion 走 tool_use→tool_result)、PreToolUse hook 在 headless 下能阻塞+控权限。
///
/// 本类实现「发消息 / 选项卡 / 状态 / 生命周期」主链路。**权限审批(Path A 的 UDS hook)**
/// 复用 VibeNotch 现有 UDSServer,在下一增量接入(见 `respond` 的 .permission 分支 TODO)。
final class ClaudeStreamJSONDriver: AgentDriver {

    let kind: AgentKind = .claude
    let capabilities = AgentCapabilities(
        nativeChoice: true,            // AskUserQuestion 原生
        permission: .hook,             // Path A:PreToolUse hook 阻塞审批
        multimodalInput: true,         // base64 image block 喂 stdin
        resume: true
    )

    private(set) var sessionId: String?
    var ownerPID: pid_t? { proc?.processIdentifier }
    let events: AsyncStream<SessionEvent>
    private let emit: AsyncStream<SessionEvent>.Continuation

    /// 权限审批回写器:reqId → 调用即写回 allow/deny 解除 PreToolUse hook 阻塞。
    private var permDeciders: [String: (PermissionDecision) -> Void] = [:]

    private var proc: Process?
    private var stdinHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "claude.driver.write")
    private var outBuffer = Data()
    /// 记录最近一次 assistant 文本块的 msgId,便于 messageComplete 配对。
    private var lastAssistantMsgId: String?
    private var lastModel: String?

    /// default = 权限走 PreToolUse hook(Path A,控制台默认);bypassPermissions = 全放行(测试用)。
    private let permissionMode: String

    init(permissionMode: String = "default") {
        self.permissionMode = permissionMode
        var c: AsyncStream<SessionEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    // MARK: - 生命周期

    func start(workdir: String, resume: String?, continueLast: Bool, model: String?) async throws {
        guard let bin = Self.claudeBinary() else {
            emit.yield(.error("找不到 claude 可执行文件"))
            throw DriverError.binaryNotFound
        }
        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose",
                    "--permission-mode", permissionMode]
        if let model, !model.isEmpty { args += ["--model", model] }
        if continueLast { args += ["--continue"] }
        else if let resume, !resume.isEmpty { args += ["--resume", resume] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        p.environment = Self.childEnvironment()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe            // stream-json 下 stderr 也并进来(verbose 噪声靠解析过滤)
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.feed(d)
        }
        p.terminationHandler = { [weak self] _ in
            self?.emit.yield(.status(.done))
            self?.emit.finish()
        }
        proc = p
        emit.yield(.status(.starting))
        try p.run()
    }

    func stop() {
        proc?.terminationHandler = nil
        if proc?.isRunning == true { proc?.terminate() }
        emit.finish()
    }

    func interrupt() {
        // stream-json 有 interrupt 控制消息;先用 SIGINT 占位(Phase 后续替换为控制帧)。
        if let pid = proc?.processIdentifier, proc?.isRunning == true {
            kill(pid, SIGINT)
        }
    }

    // MARK: - 上行:发消息 / 回答待决项

    func send(_ input: UserInput) {
        // 图片不内联 base64:已落盘的文件路径作为文字引用发给 Claude,让它用 Read 工具查看。
        // (像素仍会在 Claude 读取时进入上下文,但发送体积/user 消息保持精简,符合「发地址」)
        var text = input.text
        if !input.imagePaths.isEmpty {
            let refs = input.imagePaths.map { "图片: \($0)" }.joined(separator: "\n")
            let head = input.text.isEmpty ? "用户发来图片,请用 Read 工具查看后回答:" : "\n\n(用户附带图片,请用 Read 工具查看)"
            text = input.text.isEmpty ? "\(head)\n\(refs)" : "\(input.text)\(head)\n\(refs)"
        }
        guard !text.isEmpty else { return }
        writeJSON(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]])
    }

    /// Path A 权限通道:PreToolUse hook(经 AppDelegate/SessionManager 按 ppid 路由进来)→
    /// 发出 pendingRequest(.permission),记下回写器;respond 时调用它解除 hook 阻塞。
    func injectPermission(toolName: String, detail: String, decide: @escaping (PermissionDecision) -> Void) {
        let reqId = "perm_" + UUID().uuidString
        permDeciders[reqId] = decide
        emit.yield(.pendingRequest(PendingRequest(
            id: reqId, kind: .permission, title: "审批请求",
            detail: detail.isEmpty ? toolName : "\(toolName): \(detail)",
            options: [.init(id: "allow", label: "允许", detail: nil),
                      .init(id: "deny", label: "拒绝", detail: nil)],
            multiSelect: false)))
    }

    func respond(to requestId: String, choose optionIds: [String]) {
        // ① 权限审批:写回 hook 解除阻塞,不走 stdin。
        if let decide = permDeciders.removeValue(forKey: requestId) {
            decide(optionIds.contains("allow") ? .allow : .deny)
            emit.yield(.pendingResolved(id: requestId))
            return
        }
        // ② 选项卡(AskUserQuestion/ExitPlanMode):回 tool_result,tool_use_id = requestId。
        let answer = optionIds.joined(separator: ", ")
        writeJSON(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": requestId, "content": answer]
        ]]])
        emit.yield(.pendingResolved(id: requestId))
    }

    // MARK: - 下行:stream-json 解析 → 统一事件

    private func feed(_ data: Data) {
        outBuffer.append(data)
        while let nl = outBuffer.firstIndex(of: 0x0A) {
            let lineData = outBuffer.subdata(in: outBuffer.startIndex..<nl)
            outBuffer.removeSubrange(outBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }   // 非 JSON 行(verbose 噪声)直接丢
            handle(obj)
        }
    }

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "system":
            if (o["subtype"] as? String) == "init" {
                if let sid = o["session_id"] as? String { sessionId = sid; emit.yield(.sessionId(sid)) }
                emit.yield(.status(.idle))
            }
        case "assistant":
            emit.yield(.status(.working))
            handleAssistant(o)
        case "user":
            // tool_result 回流(含权限拒绝信息);此处暂只用于状态,渲染细节后续补。
            break
        case "result":
            let r = o["result"] as? String
            emit.yield(.turnComplete(result: r))
            emit.yield(.status(.waitingInput))   // 回合结束 = 空闲挂起等输入
        default:
            break
        }
    }

    private func handleAssistant(_ o: [String: Any]) {
        guard let msg = o["message"] as? [String: Any] else { return }
        if let m = msg["model"] as? String, m != lastModel, m != "<synthetic>" {
            lastModel = m; emit.yield(.model(m))
        }
        let msgId = (msg["id"] as? String) ?? UUID().uuidString
        guard let blocks = msg["content"] as? [[String: Any]] else { return }
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String, !t.isEmpty {
                    lastAssistantMsgId = msgId
                    emit.yield(.messageDelta(msgId: msgId, role: "assistant", text: t))
                }
            case "tool_use":
                handleToolUse(b)
            default:
                break   // thinking 等暂忽略
            }
        }
    }

    private func handleToolUse(_ b: [String: Any]) {
        let name = b["name"] as? String ?? "?"
        let id = b["id"] as? String ?? UUID().uuidString
        let input = b["input"] as? [String: Any] ?? [:]
        switch name {
        case "AskUserQuestion":
            if let req = Self.choiceRequest(id: id, input: input) { emit.yield(.pendingRequest(req)) }
        case "ExitPlanMode":
            let plan = input["plan"] as? String
            emit.yield(.pendingRequest(PendingRequest(
                id: id, kind: .planConfirm, title: "计划待确认", detail: plan,
                options: [.init(id: "approve", label: "同意", detail: nil),
                          .init(id: "keep", label: "继续讨论", detail: nil)],
                multiSelect: false)))
        case "Edit", "Write", "MultiEdit":
            if let path = input["file_path"] as? String {
                emit.yield(.fileEdit(FileEditInfo(path: path, additions: 0)))
            }
            emit.yield(.toolCall(ToolCallInfo(id: id, name: name, summary: (input["file_path"] as? String) ?? "")))
        case "Bash":
            emit.yield(.toolCall(ToolCallInfo(id: id, name: "Bash", summary: (input["command"] as? String) ?? "")))
        default:
            let summary = (input["file_path"] ?? input["path"] ?? input["command"]
                           ?? input["pattern"] ?? input["url"] ?? input["prompt"]) as? String ?? ""
            emit.yield(.toolCall(ToolCallInfo(id: id, name: name, summary: summary)))
        }
    }

    /// AskUserQuestion 的 input → 统一 PendingRequest(.choice)。取第一题。
    private static func choiceRequest(id: String, input: [String: Any]) -> PendingRequest? {
        guard let q = (input["questions"] as? [[String: Any]])?.first else { return nil }
        let opts = (q["options"] as? [[String: Any]] ?? []).enumerated().map { i, o in
            PendingRequest.Option(id: o["label"] as? String ?? "\(i + 1)",
                                  label: o["label"] as? String ?? "选项\(i + 1)",
                                  detail: o["description"] as? String)
        }
        return PendingRequest(
            id: id, kind: .choice,
            title: q["header"] as? String ?? "请选择",
            detail: q["question"] as? String,
            options: opts,
            multiSelect: (q["multiSelect"] as? Bool) ?? false)
    }

    // MARK: - 工具

    private func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        writeQueue.async { [weak self] in
            self?.stdinHandle?.write(Data((line + "\n").utf8))
        }
    }

    private static func imageBlock(path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let media = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                     "gif": "image/gif", "webp": "image/webp"][ext] ?? "image/png"
        return ["type": "image",
                "source": ["type": "base64", "media_type": media, "data": data.base64EncodedString()]]
    }

    /// 解析 claude 可执行路径。GUI App 的 PATH 不含 nvm,且启动时非交互 shell 可能没初始化
    /// nvm → 单靠 `zsh -lc command -v` 不稳。所以:落盘记忆 → 常见路径 → **直接搜 nvm 目录**
    /// → 交互/登录 shell 兜底。只缓存成功结果(不永久缓存失败)。
    private static var cachedBinary: String?
    private static let pathMemo = NSString(string: "~/.vibenotch/claude-path").expandingTildeInPath

    /// claude 子进程的环境变量。GUI App(launchd 启动)的环境过于精简——缺 `USER`、缺终端里
    /// 的 `https_proxy` 等。**`USER` 缺失会让 claude 读不到 macOS 钥匙串里的订阅凭据 → API 返回
    /// 403「Not logged in」**(实测根因)。这里抓一次登录+交互 shell 的完整 env(含
    /// USER/HOME/PATH/代理),以当前进程 env 打底,缓存复用,确保与用户终端里跑 claude 一致。
    private static var cachedEnv: [String: String]?
    private static func childEnvironment() -> [String: String] {
        if let c = cachedEnv { return c }
        var env = ProcessInfo.processInfo.environment
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "env"]   // 登录+交互:确保 .zprofile/.zshrc 的代理、PATH 都加载
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let s = String(data: data, encoding: .utf8) {
                for line in s.split(separator: "\n") {
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let k = String(line[line.startIndex..<eq])
                    if !k.isEmpty { env[k] = String(line[line.index(after: eq)...]) }
                }
            }
        }
        // 兜底:钥匙串读凭据强依赖 USER;HOME 也确保有,否则连 ~/.claude 都找不到。
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        cachedEnv = env
        return env
    }

    private static func claudeBinary() -> String? {
        let fm = FileManager.default
        if let c = cachedBinary, fm.isExecutableFile(atPath: c) { return c }
        if let found = resolveBinary() {
            cachedBinary = found
            try? found.write(toFile: pathMemo, atomically: true, encoding: .utf8)
            return found
        }
        return nil
    }

    private static func resolveBinary() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // 1. 上次成功落盘的路径
        if let saved = try? String(contentsOfFile: pathMemo, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty, fm.isExecutableFile(atPath: saved) { return saved }
        // 2. 常见固定路径
        var candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
        // 3. 直接搜 nvm 各 node 版本(新版本优先)
        let nvmBase = "\(home)/.nvm/versions/node"
        if let vers = try? fm.contentsOfDirectory(atPath: nvmBase) {
            for v in vers.sorted().reversed() { candidates.append("\(nvmBase)/\(v)/bin/claude") }
        }
        for p in candidates where fm.isExecutableFile(atPath: p) { return p }
        // 4. 交互/登录 shell 兜底(交互优先,确保 nvm 初始化)
        for args in [["-ilc", "command -v claude"], ["-lc", "command -v claude"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let path = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    enum DriverError: Error { case binaryNotFound }
}
