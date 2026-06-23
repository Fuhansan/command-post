import Foundation

/// 解析 Codex 的转录(`~/.codex/sessions/.../rollout-*.jsonl`)。
/// 格式是事件流:每行 `{timestamp, type, payload}`,对话主体在
/// `type=response_item` 的 payload 里(message / reasoning / 各种 *_call)。
/// 本回合 = 最后一条**真实用户消息**之后的内容。
enum CodexTranscriptReader {

    /// 按文件路径解析 Codex JSONL,供 WebConsole/Relay 的历史窗口复用。
    static func parseTranscriptFile(path: String)
        -> [(role: String, kind: AgentMessage.Kind, text: String)] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [(String, AgentMessage.Kind, String)] = []
        for line in content.split(separator: "\n") {
            out.append(contentsOf: parseTranscriptLine(String(line)))
        }
        return out
    }

    /// 只解析文件「尾部一窗」。Codex 的带图 response_item 可能很大,所以 UI 文本优先取
    /// event_msg.user_message/agent_message;这些行只含文字和本地图片路径,不会被 base64 撑爆。
    static func parseTranscriptWindow(path: String, endByte: UInt64?, windowBytes: Int = 512 * 1024)
        -> (messages: [(role: String, kind: AgentMessage.Kind, text: String, ord: Int)], earliest: Int, hasEarlier: Bool) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return ([], 0, false) }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let end = min(endByte ?? fileSize, fileSize)
        let start = end > UInt64(windowBytes) ? end - UInt64(windowBytes) : 0
        try? fh.seek(toOffset: start)
        let bytes = [UInt8]((try? fh.read(upToCount: Int(end - start))) ?? Data())

        var i = 0
        if start > 0 { i = (bytes.firstIndex(of: 0x0A)).map { $0 + 1 } ?? bytes.count }
        var out: [(String, AgentMessage.Kind, String, Int)] = []
        var firstKept: Int? = nil
        while i < bytes.count {
            var j = i
            while j < bytes.count && bytes[j] != 0x0A { j += 1 }
            if j > i, let lineStr = String(bytes: bytes[i..<j], encoding: .utf8) {
                let lineByteStart = Int(start) + i
                let msgs = parseTranscriptLine(lineStr)
                if !msgs.isEmpty {
                    if firstKept == nil { firstKept = lineByteStart }
                    for (k, m) in msgs.enumerated() {
                        out.append((m.role, m.kind, m.text, lineByteStart * 16 + min(k, 15)))
                    }
                }
            }
            i = j + 1
        }
        let earliest = firstKept ?? Int(start)
        return (out, earliest, earliest > 0)
    }

    /// 解析 Codex JSONL 单行,抽出 WebConsole 可展示的文本/工具消息。
    static func parseTranscriptLine(_ line: String)
        -> [(role: String, kind: AgentMessage.Kind, text: String)] {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return [] }

        if type == "event_msg" {
            switch payload["type"] as? String {
            case "user_message":
                let text = visibleUserMessage(payload["message"] as? String)
                return text.isEmpty ? [] : [("user", .text, text)]
            case "agent_message":
                let text = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? [] : [("assistant", .text, text)]
            default:
                return []
            }
        }

        guard type == "response_item", let kind = payload["type"] as? String else { return [] }
        switch kind {
        case "function_call":
            let name = payload["name"] as? String ?? "tool"
            let summary = functionCallSummary(name: name, payload: payload)
            return [("assistant", .tool, "\(displayToolName(name)): \(summary)")]
        case "custom_tool_call":
            let name = payload["name"] as? String ?? "tool"
            let summary = (payload["input"] as? String) ?? compactJSON(payload["input"]) ?? ""
            return [("assistant", .tool, "\(displayToolName(name)): \(trim(summary, maxLen: 800))")]
        default:
            return []
        }
    }

    static func firstUserPrompt(path: String) -> String? {
        readPrompt(path: path, fromEnd: false)
    }

    static func lastUserPrompt(transcriptPath: String, maxLen: Int = 4000) -> String? {
        readPrompt(path: transcriptPath, fromEnd: true, maxLen: maxLen)
    }

    /// 当前回合的步骤(assistant 文本 + 工具调用),供 VibeNotch 翻成手机消息。
    static func currentTurnSteps(transcriptPath: String) -> [TurnStep] {
        guard let data = readTail(path: transcriptPath, maxBytes: 512 * 1024),
              let text = String(data: data, encoding: .utf8) else { return [] }

        // 收集所有 response_item 的 payload(尾部可能截到半行,跳过解析失败的)
        var items: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "response_item",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            items.append(payload)
        }
        guard !items.isEmpty else { return [] }

        // 找最后一条真实用户消息的位置(过滤 developer / <environment_context> 等系统块)
        var startIdx = 0
        for (i, p) in items.enumerated() where isRealUserMessage(p) { startIdx = i + 1 }

        var steps: [TurnStep] = []
        for p in items[startIdx...] {
            guard let kind = p["type"] as? String else { continue }
            switch kind {
            case "message":
                if (p["role"] as? String) == "assistant" {
                    let t = contentText(p["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { steps.append(.text(t)) }
                }
            case "function_call", "custom_tool_call":
                let name = (p["name"] as? String) ?? "tool"
                let args = (p["arguments"] as? String) ?? compactJSON(p["arguments"])
                steps.append(.tool(name: name, input: args))
            case "local_shell_call", "exec_command", "shell_call":
                let cmd = shellCommand(from: p)
                steps.append(.tool(name: "Shell", input: cmd))
            default:
                break   // reasoning / 其它忽略
            }
        }
        return steps
    }

    private static func readPrompt(path: String, fromEnd: Bool, maxLen: Int = 4000) -> String? {
        let data: Data?
        if fromEnd {
            data = readTail(path: path, maxBytes: 512 * 1024)
        } else {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            data = try? h.read(upToCount: 512 * 1024)
            try? h.close()
        }
        guard let data, let blob = String(data: data, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n").map(String.init)
        let scan: [String] = fromEnd ? Array(lines.reversed()) : lines
        for line in scan {
            for item in parseTranscriptLine(line) where item.role == "user" && item.kind == .text {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return trim(text, maxLen: maxLen) }
            }
        }
        return nil
    }

    /// 真实用户消息:role=user 且内容不是 <environment_context>/<permissions…> 这类系统块。
    private static func isRealUserMessage(_ p: [String: Any]) -> Bool {
        guard (p["type"] as? String) == "message", (p["role"] as? String) == "user" else { return false }
        let t = contentText(p["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.hasPrefix("<")
    }

    /// content 可能是字符串,或 [{type, text}] 数组 → 取出可见文本。
    private static func contentText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for it in arr {
            if let t = it["text"] as? String { parts.append(t) }
        }
        return parts.joined(separator: "\n")
    }

    private static func shellCommand(from p: [String: Any]) -> String {
        if let action = p["action"] as? [String: Any] {
            if let cmd = action["command"] as? [String] { return cmd.joined(separator: " ") }
            if let cmd = action["command"] as? String { return cmd }
        }
        if let cmd = p["command"] as? [String] { return cmd.joined(separator: " ") }
        if let cmd = p["command"] as? String { return cmd }
        return ""
    }

    private static func visibleUserMessage(_ raw: String?) -> String {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.hasPrefix("<") ? "" : text
    }

    private static func functionCallSummary(name: String, payload: [String: Any]) -> String {
        let args = payload["arguments"]
        if name == "exec_command", let s = args as? String,
           let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return trim(obj["cmd"] as? String ?? obj["command"] as? String ?? s, maxLen: 800)
        }
        return trim((args as? String) ?? compactJSON(args) ?? "", maxLen: 800)
    }

    private static func displayToolName(_ name: String) -> String {
        switch name {
        case "exec_command": return "Bash"
        case "apply_patch": return "Patch"
        default: return name
        }
    }

    private static func compactJSON(_ v: Any?) -> String? {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    private static func trim(_ s: String, maxLen: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > maxLen ? String(t.prefix(maxLen)) + "..." : t
    }

    /// 读文件尾部 maxBytes(转录会越来越大,只读尾部够拿当前回合)。
    private static func readTail(path: String, maxBytes: Int) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
        if size > maxBytes {
            try? h.seek(toOffset: UInt64(size - maxBytes))
        }
        return try? h.readToEnd()
    }
}
