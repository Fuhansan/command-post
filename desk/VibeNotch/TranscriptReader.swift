import Foundation

/// Parses a Claude Code session transcript JSONL file and returns the most
/// recent assistant text response. Returns nil if the file is missing or
/// contains no assistant text. Reads only the tail of the file for efficiency.
enum TranscriptReader {
    /// Returns the text of the LAST real user prompt in the transcript
    /// (entries with type=user AND a promptId — tool_results are excluded).
    /// Used to backfill `promptSummary` when the App restarts mid-session.
    static func lastUserPrompt(transcriptPath: String, maxLen: Int = 4000) -> String? {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            // String content = real user prompt — done.
            if let str = message["content"] as? String {
                if let formatted = Self.format(str, maxLen: maxLen) { return formatted }
                continue
            }
            // Array content: a real prompt may use text blocks; tool_result
            // entries also live here but only have `tool_result` blocks. Keep
            // walking back when we don't find any text block.
            if let arr = message["content"] as? [[String: Any]] {
                for item in arr {
                    if (item["type"] as? String) == "text",
                       let text = item["text"] as? String,
                       let formatted = Self.format(text, maxLen: maxLen) {
                        return formatted
                    }
                }
            }
            // Not a real prompt; keep searching upward.
        }
        return nil
    }

    /// Returns the latest assistant text response that appears AFTER the most
    /// recent user prompt in the file. This guarantees the reply belongs to
    /// the current turn — earlier-turn text is never returned. Returns nil
    /// when the file hasn't yet been flushed with an assistant text for the
    /// current turn (the caller should retry).
    /// Returns the ordered timeline of THIS turn — every assistant text block
    /// AND every tool_use, in the order they appear. Powers the milestone
    /// view in DetailCard.
    static func currentTurnSteps(transcriptPath: String) -> [TurnStep] {
        // 1MB 尾部:工具输出很大的长回合(几十次工具调用)也能容下本轮起点;
        // 真超过 1MB(极长回合)时下面有兜底,不会丢最新回复。
        guard let data = readTail(path: transcriptPath, maxBytes: 1024 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return [] }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            var isRealPrompt = false
            if message["content"] is String { isRealPrompt = true }
            else if let arr = message["content"] as? [[String: Any]] {
                for item in arr where (item["type"] as? String) == "text" {
                    isRealPrompt = true; break
                }
            }
            if isRealPrompt {
                lastUserIdx = i
                break
            }
        }
        // 兜底:尾部窗口里找不到真实用户提问 = 这一整轮的内容就超过了 1MB,
        // 起始提问已滚出窗口。此时整个尾部都属于当前回合(中间没有新提问),
        // 从头解析所有 assistant 步骤,保证最新回复(如收尾文字)不被丢掉。
        let startIdx = lastUserIdx.map { $0 + 1 } ?? 0

        var steps: [TurnStep] = []
        for line in lines[startIdx...] {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content {
                switch item["type"] as? String {
                case "text":
                    if let text = item["text"] as? String,
                       let formatted = Self.format(text, maxLen: 4000) {
                        steps.append(.text(formatted))
                    }
                case "tool_use":
                    let name = (item["name"] as? String) ?? "?"
                    let input = item["input"] as? [String: Any]
                    steps.append(.tool(name: name, input: Self.toolInputSummary(name: name, input: input)))
                default:
                    break
                }
            }
        }
        return steps
    }

    /// 本轮是否被用户中断(Ctrl+C/Esc)。判据:最后一条真实 user prompt 之后,
    /// 出现了中断标记(user 消息带 `interruptedMessageId` 或文本以 `[Request interrupted` 开头)。
    static func currentTurnInterrupted(transcriptPath: String) -> Bool {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return false }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // 最后一条真实 prompt(跳过中断标记本身)
        var lastPromptIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let m = userMessage(line) else { continue }
            if isInterruptMarker(m) { continue }
            if isRealPromptMsg(m) { lastPromptIdx = i; break }
        }
        guard let pidx = lastPromptIdx, pidx + 1 < lines.count else { return false }
        for line in lines[(pidx + 1)...] {
            if let m = userMessage(line), isInterruptMarker(m) { return true }
        }
        return false
    }

    private static func userMessage(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (o["type"] as? String) == "user",
              let m = o["message"] as? [String: Any] else { return nil }
        return m
    }

    private static func isInterruptMarker(_ msg: [String: Any]) -> Bool {
        if msg["interruptedMessageId"] != nil { return true }
        if let s = msg["content"] as? String, s.hasPrefix("[Request interrupted") { return true }
        if let arr = msg["content"] as? [[String: Any]] {
            for item in arr where (item["type"] as? String) == "text" {
                if let t = item["text"] as? String, t.hasPrefix("[Request interrupted") { return true }
            }
        }
        return false
    }

    private static func isRealPromptMsg(_ msg: [String: Any]) -> Bool {
        if msg["content"] is String { return true }
        if let arr = msg["content"] as? [[String: Any]] {
            return arr.contains { ($0["type"] as? String) == "text" }
        }
        return false
    }

    /// 当前一轮里每个被改文件的新增行数(近似 +N):Write 数 content 行,Edit 数 new_string 行,
    /// MultiEdit 累加各 edit 的 new_string 行。同一文件多次编辑累加。
    static func fileEditAdditions(transcriptPath: String) -> [String: Int] {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return [:] }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  let message = obj["message"] as? [String: Any] else { continue }
            var real = false
            if message["content"] is String { real = true }
            else if let arr = message["content"] as? [[String: Any]] {
                real = arr.contains { ($0["type"] as? String) == "text" }
            }
            if real { lastUserIdx = i; break }
        }
        guard let userIdx = lastUserIdx else { return [:] }

        var result: [String: Int] = [:]
        func addLines(_ s: Any?) -> Int {
            guard let str = s as? String, !str.isEmpty else { return 0 }
            return str.split(whereSeparator: \.isNewline).count
        }
        for line in lines[(userIdx + 1)...] {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content where (item["type"] as? String) == "tool_use" {
                let name = item["name"] as? String ?? ""
                guard let input = item["input"] as? [String: Any] else { continue }
                let path = (input["file_path"] as? String) ?? (input["path"] as? String)
                guard let p = path else { continue }
                switch name {
                case "Write":
                    result[p, default: 0] += addLines(input["content"])
                case "Edit":
                    result[p, default: 0] += addLines(input["new_string"])
                case "MultiEdit":
                    if let edits = input["edits"] as? [[String: Any]] {
                        for ed in edits { result[p, default: 0] += addLines(ed["new_string"]) }
                    }
                default:
                    break
                }
            }
        }
        return result
    }

    /// 当前一轮每个文件的 diff hunks(供手机展示实际改了哪些代码)。
    /// Edit: old_string→del, new_string→add;Write: content→add;MultiEdit: 各 edit 累加。
    /// 返回 path → [{op:add|del, text}],按文件首次出现顺序无关(调用方自行排序)。
    /// 文件未变(size+mtime)→ 返回缓存,避免 RelayAgent 每次 syncToServer 都读 256KB+解析(P3)。
    private static var diffsCache: [String: (size: UInt64, mtime: TimeInterval, diffs: [String: [[String: String]]])] = [:]
    static func fileEditDiffs(transcriptPath: String) -> [String: [[String: String]]] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let c = diffsCache[transcriptPath], c.size == size, c.mtime == mtime { return c.diffs }
        let diffs = computeFileEditDiffs(transcriptPath: transcriptPath)
        diffsCache[transcriptPath] = (size, mtime, diffs)
        return diffs
    }
    private static func computeFileEditDiffs(transcriptPath: String) -> [String: [[String: String]]] {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return [:] }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  let message = obj["message"] as? [String: Any] else { continue }
            var real = false
            if message["content"] is String { real = true }
            else if let arr = message["content"] as? [[String: Any]] {
                real = arr.contains { ($0["type"] as? String) == "text" }
            }
            if real { lastUserIdx = i; break }
        }
        guard let userIdx = lastUserIdx else { return [:] }

        var result: [String: [[String: String]]] = [:]
        func push(_ path: String, _ op: String, _ text: Any?) {
            guard let str = text as? String else { return }
            for raw in str.split(whereSeparator: \.isNewline) {
                let s = String(raw)
                let t = s.count > 200 ? String(s.prefix(200)) + "…" : s
                result[path, default: []].append(["op": op, "text": t])
            }
        }
        for line in lines[(userIdx + 1)...] {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content where (item["type"] as? String) == "tool_use" {
                let name = item["name"] as? String ?? ""
                guard let input = item["input"] as? [String: Any] else { continue }
                guard let path = (input["file_path"] as? String) ?? (input["path"] as? String) else { continue }
                switch name {
                case "Edit":
                    push(path, "del", input["old_string"])
                    push(path, "add", input["new_string"])
                case "Write":
                    push(path, "add", input["content"])
                case "MultiEdit":
                    if let edits = input["edits"] as? [[String: Any]] {
                        for ed in edits { push(path, "del", ed["old_string"]); push(path, "add", ed["new_string"]) }
                    }
                default:
                    break
                }
            }
        }
        return result
    }

    private static func toolInputSummary(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch name {
        case "Edit", "Write", "Read", "NotebookEdit":
            return (input["file_path"] as? String) ?? (input["path"] as? String)
        case "Bash":
            guard let cmd = input["command"] as? String else { return nil }
            let line = cmd.split(whereSeparator: \.isNewline).first.map(String.init) ?? cmd
            return line.count > 80 ? String(line.prefix(80)) + "…" : line
        case "Grep", "Glob":
            return input["pattern"] as? String
        case "WebFetch":
            return input["url"] as? String
        case "Task":
            return input["prompt"] as? String
        default:
            return nil
        }
    }

    /// Legacy plain text helper (kept for reply-poll comparison).
    static func currentTurnReplyBlocks(transcriptPath: String, perBlockMaxLen: Int = 4000) -> [String] {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return [] }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            var isRealPrompt = false
            if message["content"] is String {
                isRealPrompt = true
            } else if let arr = message["content"] as? [[String: Any]] {
                for item in arr where (item["type"] as? String) == "text" {
                    isRealPrompt = true
                    break
                }
            }
            if isRealPrompt {
                lastUserIdx = i
                break
            }
        }
        guard let userIdx = lastUserIdx else { return [] }

        var blocks: [String] = []
        for line in lines[(userIdx + 1)...] {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content {
                if (item["type"] as? String) == "text",
                   let text = item["text"] as? String,
                   let formatted = Self.format(text, maxLen: perBlockMaxLen) {
                    blocks.append(formatted)
                }
            }
        }
        return blocks
    }

    static func currentTurnReply(transcriptPath: String, maxLen: Int = 4000) -> String? {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Find the LAST REAL user prompt. Tool results also have type=user
        // and `promptId`, but their content is a tool_result block array
        // without text — we must skip those to avoid using them as the
        // turn boundary (which would hide intermediate assistant text).
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            var isRealPrompt = false
            if message["content"] is String {
                isRealPrompt = true
            } else if let arr = message["content"] as? [[String: Any]] {
                for item in arr where (item["type"] as? String) == "text" {
                    isRealPrompt = true
                    break
                }
            }
            if isRealPrompt {
                lastUserIdx = i
                break
            }
        }
        guard let userIdx = lastUserIdx else { return nil }

        // Walk lines AFTER the user prompt; find the LAST assistant text.
        var bestText: String? = nil
        for line in lines[(userIdx + 1)...] {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content {
                if (item["type"] as? String) == "text",
                   let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        bestText = trimmed  // keep updating — LAST text wins
                    }
                }
            }
        }
        return Self.format(bestText, maxLen: maxLen)
    }

    private static func format(_ s: String?, maxLen: Int) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxLen {
            return String(trimmed.prefix(maxLen)) + "…"
        }
        return trimmed
    }

    /// Truncates the result to `maxLen` chars (with an ellipsis) and strips
    /// to first non-empty line.
    static func lastAssistantReply(transcriptPath: String, maxLen: Int = 220) -> String? {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024) else {
            return nil
        }
        guard let blob = String(data: data, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant" else { continue }
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }

            // Walk content blocks from the end; first text block wins.
            for item in content.reversed() {
                guard (item["type"] as? String) == "text",
                      let text = item["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // Collapse multi-line text into a single space-joined string —
                // the row renderer wraps it into 2 visual lines as needed.
                let collapsed = trimmed
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if collapsed.count > maxLen {
                    return String(collapsed.prefix(maxLen)) + "…"
                }
                return collapsed
            }
        }
        return nil
    }

    /// Reads up to `maxBytes` from the END of the file. Used to bound work for
    /// long-running sessions whose transcripts grow into the megabytes.
    private static func readTail(path: String, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }
}
