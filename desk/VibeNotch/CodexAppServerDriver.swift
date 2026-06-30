import Foundation

/// Codex adapter backed by `codex app-server`（默认 stdio:// 传输）。
///
/// This is the structured protocol used by the Codex app/IDE surfaces. It is
/// closer to an app-level JSON-RPC server than Claude's per-process stream-json:
/// a thread is created once, every user message starts a turn, and server
/// requests are used for approvals.
final class CodexAppServerDriver: AgentDriver {
    let kind: AgentKind = .codex
    let capabilities = AgentCapabilities(
        nativeChoice: false,
        permission: .sandbox,
        multimodalInput: true,
        resume: true
    )

    private(set) var sessionId: String?
    var ownerPID: pid_t? { proc?.processIdentifier }
    let events: AsyncStream<SessionEvent>
    private let emit: AsyncStream<SessionEvent>.Continuation

    private var proc: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private let writeQueue = DispatchQueue(label: "codex.appserver.write")
    private let stateQueue = DispatchQueue(label: "codex.appserver.state")
    private var requestCounter = 0
    private var responseHandlers: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var serverRequests: [String: ServerRequest] = [:]
    private var threadId: String?
    private var activeTurnId: String?
    private var currentWorkdir: String = NSHomeDirectory()
    private var streamedIds = Set<String>()   // 已逐 token 流过的 agentMessage id(item/completed 去重,避免文本翻倍)
    private var currentModel: String?
    private var stopped = false

    private struct ServerRequest {
        let method: String
        let params: [String: Any]
        let responseId: Any
    }

    init() {
        var c: AsyncStream<SessionEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    func start(workdir: String, resume: String?, continueLast: Bool, model: String?) async throws {
        currentWorkdir = workdir
        currentModel = model
        guard let bin = Self.codexBinary() else {
            emit.yield(.error("找不到 codex 可执行文件"))
            throw DriverError.binaryNotFound
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // codex 0.130+ 的 app-server 默认就是 stdio:// 传输；旧的 `--stdio` 参数已移除
        // （传它会报 "unexpected argument '--stdio' found" 直接退出 → 会话起不来）。
        p.arguments = ["app-server"]
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        p.environment = Self.childEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.feed(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(separator: "\n").prefix(3) {
                vlog("codex app-server stderr: \(line.prefix(240))")
            }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.failPending(DriverError.processExited)
            if !self.stopped { self.emit.yield(.status(.done)) }
            self.emit.finish()
        }
        proc = p
        emit.yield(.status(.starting))
        try p.run()

        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "VibeNotch", "version": "0.0.1"],
                "capabilities": ["experimentalApi": true],
            ]
        )

        let resp: [String: Any]
        if let resume, !resume.isEmpty {
            resp = try await request(
                method: "thread/resume",
                params: baseThreadParams(extra: ["threadId": resume, "excludeTurns": true])
            )
        } else {
            resp = try await request(method: "thread/start", params: baseThreadParams())
        }
        applyThreadResponse(resp)
        emit.yield(.status(.waitingInput))

        // 可切换模型:异步问 app-server 的 model/list,拿真实 slug + 展示名(动态,不写死、不会过时)。
        // model/list 偶尔较慢/超时,放后台不阻塞会话就绪;拿到再推给上层。
        Task { [weak self] in
            guard let self else { return }
            guard let resp = try? await self.request(method: "model/list", params: ["includeHidden": false]),
                  let data = resp["data"] as? [[String: Any]] else { return }
            let models = data.compactMap { m -> AgentModel? in
                guard let slug = m["model"] as? String, !slug.isEmpty,
                      !((m["hidden"] as? Bool) ?? false) else { return nil }
                let label = (m["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
                return AgentModel(id: slug, label: label)
            }
            if !models.isEmpty { self.emit.yield(.availableModels(models)) }
        }

        if continueLast {
            emit.yield(.messageDelta(
                msgId: "codex_continue_hint",
                role: "system",
                text: "Codex app-server 已启动。请发送下一条消息继续。"
            ))
        }
    }

    func stop() {
        stopped = true
        failPending(DriverError.cancelled)
        proc?.terminationHandler = nil
        proc?.terminate()
        emit.finish()
    }

    func interrupt() {
        let ids = stateQueue.sync { (threadId, activeTurnId) }
        guard let tid = ids.0, let turn = ids.1 else { return }
        Task { _ = try? await request(method: "turn/interrupt", params: ["threadId": tid, "turnId": turn]) }
    }

    func send(_ input: UserInput) {
        let parts = codexInput(input)
        guard !parts.isEmpty else { return }
        let tid = stateQueue.sync { threadId }
        guard let tid else {
            emit.yield(.error("Codex thread 尚未初始化"))
            return
        }
        emit.yield(.status(.working))
        var params: [String: Any] = [
            "threadId": tid,
            "input": parts,
            "cwd": currentWorkdir,
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
        ]
        if let currentModel, !currentModel.isEmpty { params["model"] = currentModel }
        Task { [weak self] in
            do {
                let resp = try await self?.request(method: "turn/start", params: params)
                if let turn = ((resp?["turn"] as? [String: Any])?["id"] as? String) {
                    self?.stateQueue.async { self?.activeTurnId = turn }
                }
            } catch {
                self?.emit.yield(.error("Codex turn 启动失败: \(error.localizedDescription)"))
            }
        }
    }

    @discardableResult
    func respond(to requestId: String, choose optionIds: [String]) -> Bool {
        let req = stateQueue.sync { serverRequests.removeValue(forKey: requestId) }
        guard let req else {
            vlog("codex app-server respond failed: missing request id=\(requestId) choose=\(optionIds)")
            return false
        }
        let allow = optionIds.contains("allow") || optionIds.contains("accept")
        let result: [String: Any]
        switch req.method {
        case "item/commandExecution/requestApproval":
            result = commandApprovalResult(params: req.params, allow: allow)
        case "item/fileChange/requestApproval":
            result = simpleApprovalResult(params: req.params, allow: allow)
        case "item/tool/requestUserInput":
            let answers = toolAnswers(params: req.params, chosen: optionIds)
            result = ["answers": answers]
        case "item/permissions/requestApproval":
            result = allow ? ["permissions": req.params["permissions"] ?? [:], "scope": "turn"]
                           : ["permissions": [:], "scope": "turn"]
        default:
            result = [:]
        }
        vlog("codex app-server respond method=\(req.method) id=\(requestId) result=\(compactJSON(result) ?? "{}")")
        sendResponse(id: req.responseId, result: result)
        emit.yield(.pendingResolved(id: requestId))
        return true
    }

    // MARK: - JSON-RPC

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID()
        return try await withCheckedThrowingContinuation { cont in
            stateQueue.async {
                self.responseHandlers[id] = { result in cont.resume(with: result) }
                self.writeJSON(["id": id, "method": method, "params": params])
            }
        }
    }

    private func sendResponse(id: Any, result: [String: Any]) {
        writeJSON(["id": id, "result": result])
    }

    private func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        writeQueue.async { [weak self] in
            self?.stdinHandle?.write(Data((line + "\n").utf8))
        }
    }

    private func feed(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        if let method = obj["method"] as? String {
            handleMethod(method, params: obj["params"] as? [String: Any] ?? [:], requestId: obj["id"])
            return
        }

        guard let id = obj["id"] else { return }
        let key = String(describing: id)
        if let err = obj["error"] as? [String: Any] {
            let msg = errorMessage(err, fallback: "Codex app-server request failed")
            resolveResponse(id: key, result: .failure(DriverError.server(msg)))
            return
        }
        resolveResponse(id: key, result: .success(obj["result"] as? [String: Any] ?? [:]))
    }

    private func handleMethod(_ method: String, params: [String: Any], requestId: Any?) {
        switch method {
        case "thread/started":
            if let t = params["thread"] as? [String: Any] { applyThread(t) }
        case "thread/status/changed":
            handleThreadStatus(params)
        case "thread/tokenUsage/updated":
            handleTokenUsage(params["tokenUsage"] as? [String: Any])
        case "turn/started":
            if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
                stateQueue.async { self.activeTurnId = id }
                emit.yield(.status(.working))
            }
        case "turn/completed":
            handleTurnCompleted(params)
        case "item/agentMessage/delta":
            let id = params["itemId"] as? String ?? params["turnId"] as? String ?? UUID().uuidString
            if let delta = params["delta"] as? String, !delta.isEmpty {
                streamedIds.insert(id)
                emit.yield(.messageDelta(msgId: id, role: "assistant", text: delta))
            }
        case "item/started", "item/completed":
            if let item = params["item"] as? [String: Any] { handleItem(item, completed: method == "item/completed") }
        case "item/fileChange/patchUpdated":
            handlePatchUpdated(params)
        case "turn/diff/updated":
            if let diff = params["diff"] as? String, !diff.isEmpty {
                emit.yield(.toolCall(ToolCallInfo(id: "diff_\(params["turnId"] ?? UUID().uuidString)", name: "Diff", summary: "\(diff.count) chars")))
            }
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "item/tool/requestUserInput":
            if let id = requestId {
                handleServerRequest(rawId: id, method: method, params: params)
            }
        case "error":
            let msg = errorMessage(params, fallback: "Codex app-server error")
            vlog("codex app-server error event: \(compactJSON(params) ?? msg)")
            if hasErrorDetails(params) { emit.yield(.error(msg)) }
        default:
            break
        }
    }

    private func resolveResponse(id: String, result: Result<[String: Any], Error>) {
        let h = stateQueue.sync { responseHandlers.removeValue(forKey: id) }
        h?(result)
    }

    private func failPending(_ error: Error) {
        let handlers = stateQueue.sync {
            let h = responseHandlers
            responseHandlers.removeAll()
            return h
        }
        for h in handlers.values { h(.failure(error)) }
    }

    private func nextRequestID() -> String {
        stateQueue.sync {
            requestCounter += 1
            return "c\(requestCounter)"
        }
    }

    // MARK: - Event mapping

    private func applyThreadResponse(_ resp: [String: Any]) {
        if let m = resp["model"] as? String { emit.yield(.model(m)) }
        if let t = resp["thread"] as? [String: Any] { applyThread(t) }
    }

    private func applyThread(_ thread: [String: Any]) {
        guard let id = thread["id"] as? String else { return }
        stateQueue.async { self.threadId = id }
        sessionId = id
        emit.yield(.sessionId(id))
    }

    private func handleThreadStatus(_ params: [String: Any]) {
        guard let st = params["status"] as? [String: Any],
              let type = st["type"] as? String else { return }
        switch type {
        case "idle":
            emit.yield(.status(.waitingInput))
        case "active":
            let flags = st["activeFlags"] as? [String] ?? []
            emit.yield(.status(flags.isEmpty ? .working : .needsResponse))
        case "systemError":
            emit.yield(.status(.error))
        default:
            break
        }
    }

    private func handleTurnCompleted(_ params: [String: Any]) {
        if let turn = params["turn"] as? [String: Any],
           let err = turn["error"] as? [String: Any] {
            emit.yield(.error(err["message"] as? String ?? "Codex turn failed"))
            emit.yield(.status(.error))
        } else {
            emit.yield(.turnComplete(result: nil))
            emit.yield(.status(.waitingInput))
        }
        stateQueue.async { self.activeTurnId = nil }
    }

    private func handleTokenUsage(_ usage: [String: Any]?) {
        guard let usage,
              let last = usage["last"] as? [String: Any],
              let input = Self.intValue(last["inputTokens"]) else { return }
        emit.yield(.usage(
            contextTokens: input,
            contextWindow: Self.intValue(usage["modelContextWindow"])
        ))
    }

    private func handleItem(_ item: [String: Any], completed: Bool) {
        guard let type = item["type"] as? String else { return }
        let id = item["id"] as? String ?? UUID().uuidString
        switch type {
        case "agentMessage":
            guard completed else { return }
            // 已逐 token 流过就别再把整段 text 追加一遍(否则翻倍);没流过的才补全文
            if !streamedIds.contains(id), let text = item["text"] as? String, !text.isEmpty {
                emit.yield(.messageDelta(msgId: id, role: "assistant", text: text))
            }
            emit.yield(.messageComplete(msgId: id))
            streamedIds.remove(id)
        case "commandExecution":
            let cmd = item["command"] as? String ?? ""
            guard !cmd.isEmpty else { return }
            var op = ToolOp(kind: .bash); op.command = cmd
            op.file = cmd.split(separator: " ").first.map(String.init) ?? "bash"
            emit.yield(.toolCall(ToolCallInfo(id: id, name: "Shell", summary: cmd, op: op)))
            // 完成时回填输出(codex 各版本字段名不一,挨个兜底)。
            if completed, let out = (item["aggregatedOutput"] ?? item["output"] ?? item["stdout"]) as? String, !out.isEmpty {
                var lines = out.components(separatedBy: "\n")
                if lines.count > 40 { lines = Array(lines.prefix(40)) + ["… 已省略"] }
                emit.yield(.toolOutput(id: id, lines: lines))
            }
        case "fileChange":
            for path in fileChangePaths(item) {
                emit.yield(.fileEdit(FileEditInfo(path: path, additions: 0)))
            }
        case "mcpToolCall":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "tool"
            var op = ToolOp(kind: .other); op.label = server; op.file = tool
            emit.yield(.toolCall(ToolCallInfo(id: id, name: server, summary: tool, op: op)))
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "tool"
            var op = ToolOp(kind: .other); op.label = "工具"; op.file = tool
            emit.yield(.toolCall(ToolCallInfo(id: id, name: tool, summary: compactJSON(item["arguments"]) ?? "", op: op)))
        case "webSearch":
            let q = item["query"] as? String ?? ""
            var op = ToolOp(kind: .other); op.label = "联网"; op.file = q
            emit.yield(.toolCall(ToolCallInfo(id: id, name: "WebSearch", summary: q, op: op)))
        case "imageGeneration", "image_generation", "image_generation_end", "imageGenerationResult":
            guard completed, let path = imagePath(from: item), !path.isEmpty else { return }
            emit.yield(.messageDelta(msgId: id, role: "assistant", text: "图片已生成:\n\(path)"))
            emit.yield(.messageComplete(msgId: id))
        default:
            break
        }
    }

    private func handlePatchUpdated(_ params: [String: Any]) {
        for path in fileChangePaths(params) {
            emit.yield(.fileEdit(FileEditInfo(path: path, additions: 0)))
        }
    }

    private func handleServerRequest(rawId: Any, method: String, params: [String: Any]) {
        let id = String(describing: rawId)
        stateQueue.sync { self.serverRequests[id] = ServerRequest(method: method, params: params, responseId: rawId) }
        let decisions = (params["availableDecisions"] as? [String])?.joined(separator: ",") ?? "-"
        vlog("codex app-server pending method=\(method) id=\(id) rawIdType=\(type(of: rawId)) decisions=\(decisions)")
        let detail: String
        let title: String
        var options = [
            PendingRequest.Option(id: "allow", label: "允许", detail: nil),
            PendingRequest.Option(id: "deny", label: "拒绝", detail: nil),
        ]
        var kind: PendingRequest.Kind = .permission
        switch method {
        case "item/commandExecution/requestApproval":
            title = "命令审批"
            detail = params["command"] as? String ?? params["reason"] as? String ?? "Codex 请求执行命令"
        case "item/fileChange/requestApproval":
            title = "文件修改审批"
            detail = params["reason"] as? String ?? params["grantRoot"] as? String ?? "Codex 请求修改文件"
        case "item/permissions/requestApproval":
            title = "权限审批"
            detail = params["reason"] as? String ?? compactJSON(params["permissions"]) ?? "Codex 请求额外权限"
        case "item/tool/requestUserInput":
            let q = (params["questions"] as? [[String: Any]])?.first
            title = q?["header"] as? String ?? "请选择"
            detail = q?["question"] as? String ?? ""
            options = ((q?["options"] as? [[String: Any]]) ?? []).map {
                PendingRequest.Option(id: $0["label"] as? String ?? "", label: $0["label"] as? String ?? "选项", detail: $0["description"] as? String)
            }
            kind = .choice
        default:
            title = "Codex 待确认"
            detail = ""
        }
        emit.yield(.pendingRequest(PendingRequest(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            options: options,
            multiSelect: false
        )))
    }

    private func commandApprovalResult(params: [String: Any], allow: Bool) -> [String: Any] {
        let decisions = availableDecisions(params)
        guard allow else {
            return ["decision": firstDecision(in: decisions, from: ["decline", "cancel"]) ?? "decline"]
        }
        let decision = firstDecision(in: decisions, from: [
            "accept",
            "acceptForSession",
            "acceptWithExecpolicyAmendment",
            "applyNetworkPolicyAmendment",
        ]) ?? "accept"
        var result: [String: Any] = ["decision": decision]
        if decision == "acceptWithExecpolicyAmendment",
           let amendment = params["proposedExecpolicyAmendment"] {
            result["execpolicy_amendment"] = amendment
        }
        if decision == "applyNetworkPolicyAmendment",
           let amendment = networkPolicyAmendment(params) {
            result["network_policy_amendment"] = amendment
        }
        return result
    }

    private func simpleApprovalResult(params: [String: Any], allow: Bool) -> [String: Any] {
        let decisions = availableDecisions(params)
        let decision = allow
            ? (firstDecision(in: decisions, from: ["accept", "acceptForSession"]) ?? "accept")
            : (firstDecision(in: decisions, from: ["decline", "cancel"]) ?? "decline")
        return ["decision": decision]
    }

    private func availableDecisions(_ params: [String: Any]) -> [String] {
        params["availableDecisions"] as? [String] ?? []
    }

    private func firstDecision(in available: [String], from candidates: [String]) -> String? {
        guard !available.isEmpty else { return candidates.first }
        return candidates.first { available.contains($0) }
    }

    private func networkPolicyAmendment(_ params: [String: Any]) -> Any? {
        if let one = params["proposedNetworkPolicyAmendment"] { return one }
        guard let many = params["proposedNetworkPolicyAmendments"] as? [[String: Any]] else { return nil }
        return many.first(where: { amendmentLooksAllow($0) }) ?? many.first
    }

    private func amendmentLooksAllow(_ amendment: [String: Any]) -> Bool {
        for key in ["effect", "access", "decision", "action", "policy"] {
            if let value = amendment[key] as? String, value.lowercased().contains("allow") { return true }
        }
        return compactJSON(amendment)?.lowercased().contains("allow") ?? false
    }

    private func codexInput(_ input: UserInput) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if !input.text.isEmpty { out.append(["type": "text", "text": input.text]) }
        for p in input.imagePaths { out.append(["type": "localImage", "path": p]) }
        return out
    }

    private func baseThreadParams(extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = [
            "cwd": currentWorkdir,
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "sandbox": "workspace-write",
        ]
        if let currentModel, !currentModel.isEmpty { p["model"] = currentModel }
        for (k, v) in extra { p[k] = v }
        return p
    }

    private func fileChangePaths(_ obj: [String: Any]) -> [String] {
        let changes = obj["changes"] as? [[String: Any]] ?? []
        return changes.compactMap { $0["path"] as? String }
    }

    private func imagePath(from obj: [String: Any]) -> String? {
        for key in ["saved_path", "savedPath", "path", "file_path", "filePath"] {
            if let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func toolAnswers(params: [String: Any], chosen: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for q in params["questions"] as? [[String: Any]] ?? [] {
            guard let id = q["id"] as? String else { continue }
            out[id] = ["answers": chosen]
        }
        return out
    }

    private func compactJSON(_ v: Any?) -> String? {
        guard let v, JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    private func errorMessage(_ obj: [String: Any], fallback: String) -> String {
        if let msg = obj["message"] as? String, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return msg
        }
        var parts: [String] = []
        for key in ["code", "type", "reason", "detail"] {
            if let v = obj[key] {
                parts.append("\(key)=\(shortValue(v))")
            }
        }
        if let err = obj["error"] {
            parts.append("error=\(shortValue(err))")
        }
        if let data = obj["data"] {
            parts.append("data=\(shortValue(data))")
        }
        return parts.isEmpty ? fallback : "\(fallback): \(parts.joined(separator: " · "))"
    }

    private func hasErrorDetails(_ obj: [String: Any]) -> Bool {
        ["message", "code", "type", "reason", "detail", "error", "data"].contains { key in
            guard let value = obj[key] else { return false }
            if let s = value as? String { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }

    private func shortValue(_ v: Any, maxLen: Int = 300) -> String {
        let s = (compactJSON(v) ?? String(describing: v)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > maxLen ? String(s.prefix(maxLen)) + "..." : s
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    // MARK: - Binary / environment

    private static var cachedBinary: String?
    private static let pathMemo = NSString(string: "~/.vibenotch/codex-path").expandingTildeInPath

    private static func codexBinary() -> String? {
        let fm = FileManager.default
        if let c = cachedBinary, fm.isExecutableFile(atPath: c) { return c }
        if let memo = try? String(contentsOfFile: pathMemo, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           fm.isExecutableFile(atPath: memo) {
            cachedBinary = memo
            return memo
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.nvm/versions/node/v18.20.8/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for p in candidates where fm.isExecutableFile(atPath: p) {
            try? p.write(toFile: pathMemo, atomically: true, encoding: .utf8)
            cachedBinary = p
            return p
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v codex"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               fm.isExecutableFile(atPath: s) {
                try? s.write(toFile: pathMemo, atomically: true, encoding: .utf8)
                cachedBinary = s
                return s
            }
        }
        return nil
    }

    private static var cachedEnv: [String: String]?
    private static func childEnvironment() -> [String: String] {
        if let c = cachedEnv { return c }
        var env = ProcessInfo.processInfo.environment
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "env"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
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
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        cachedEnv = env
        return env
    }

    private enum DriverError: LocalizedError {
        case binaryNotFound
        case processExited
        case cancelled
        case server(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "找不到 codex 可执行文件"
            case .processExited: return "Codex app-server 已退出"
            case .cancelled: return "请求已取消"
            case .server(let msg): return msg
            }
        }
    }
}
