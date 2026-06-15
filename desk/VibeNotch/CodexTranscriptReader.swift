import Foundation

/// 解析 Codex 的转录(`~/.codex/sessions/.../rollout-*.jsonl`)。
/// 格式是事件流:每行 `{timestamp, type, payload}`,对话主体在
/// `type=response_item` 的 payload 里(message / reasoning / 各种 *_call)。
/// 本回合 = 最后一条**真实用户消息**之后的内容。
enum CodexTranscriptReader {

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

    private static func compactJSON(_ v: Any?) -> String? {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
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
