import Foundation

/// Decoded form of a single Claude Code hook event payload.
/// Only the fields VibeNotch needs are decoded; everything else is ignored.
struct HookEvent: Codable {
    let hookEventName: String
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
    let prompt: String?
    let toolName: String?
    let toolInput: ToolInputView?
    let message: String?
    let source: String?
    let reason: String?
    let ppid: Int?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case prompt
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case source
        case reason
        case ppid = "_ppid"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        sessionId = try? c.decode(String.self, forKey: .sessionId)
        cwd = try? c.decode(String.self, forKey: .cwd)
        transcriptPath = try? c.decode(String.self, forKey: .transcriptPath)
        prompt = try? c.decode(String.self, forKey: .prompt)
        toolName = try? c.decode(String.self, forKey: .toolName)
        toolInput = try? c.decode(ToolInputView.self, forKey: .toolInput)
        message = try? c.decode(String.self, forKey: .message)
        source = try? c.decode(String.self, forKey: .source)
        reason = try? c.decode(String.self, forKey: .reason)
        ppid = try? c.decode(Int.self, forKey: .ppid)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hookEventName, forKey: .hookEventName)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(message, forKey: .message)
    }
}

/// Best-effort decode of `tool_input` for the tools VibeNotch displays subtitles for.
/// All fields optional; mismatched types are silently swallowed.
struct ToolInputView: Codable {
    let filePath: String?
    let command: String?
    let pattern: String?
    let url: String?
    let prompt: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case command
        case pattern
        case url
        case prompt
        case path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try? c.decode(String.self, forKey: .filePath)
        command = try? c.decode(String.self, forKey: .command)
        pattern = try? c.decode(String.self, forKey: .pattern)
        url = try? c.decode(String.self, forKey: .url)
        prompt = try? c.decode(String.self, forKey: .prompt)
        path = try? c.decode(String.self, forKey: .path)
    }

    func encode(to encoder: Encoder) throws { /* not needed */ }
}
