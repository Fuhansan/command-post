import Foundation

/// 「Coding CLI 适配器」扩展点。
///
/// VibeNotch 本身只负责「收 hook 事件 → 翻成协议推手机」这条主流程,
/// 而**每种 coding CLI 的差异**(转录格式怎么解析拿回复、信任怎么预置、
/// 命令名)都收敛到一个 `CodingAgent` 适配器里。
///
/// 加一个新工具(codex / aider / …)= 写一个 `CodingAgent` 实现 + 注册到
/// `CodingAgents.all`,**不碰主流程**。
///
/// 路由方式:
///   - 读回复时:按 `transcript_path` 判定(`.claude/` → claude,`.codex/` → codex)
///   - 启动会话时:按命令首词判定(`claude` / `codex`)
protocol CodingAgent {
    /// 工具标识,如 "claude" / "codex"。
    var id: String { get }

    /// 这个命令(首词,如 `claude`)是不是本工具?(launch 预置信任时用)
    func handlesCommand(tool: String) -> Bool

    /// 这个转录路径是不是本工具产生的?(读回复时用)
    func handlesTranscript(path: String) -> Bool

    /// 解析本工具的转录文件,拿到本回合的步骤(AI 文本 + 工具动作)。
    func turnSteps(transcriptPath: String) -> [TurnStep]

    /// 新建会话启动前,把目录预置成「已信任」,避免卡在工具自己的信任确认。
    /// 工具没有这种机制就空实现。
    func preTrust(directories: [String])
}

extension CodingAgent {
    func preTrust(directories: [String]) {}
}

/// 适配器注册表 + 路由。
enum CodingAgents {
    /// 已支持的工具。加新工具就往这里加一个适配器。
    static let all: [CodingAgent] = [
        ClaudeAgent(),
        CodexAgent(),   // 解析 ~/.codex/sessions 的事件流转录拿回复
    ]

    /// 按转录路径找适配器(读回复用)。
    static func forTranscript(_ path: String) -> CodingAgent? {
        all.first { $0.handlesTranscript(path: path) }
    }

    /// 按命令首词找适配器(预置信任用)。
    static func forCommand(_ tool: String) -> CodingAgent? {
        all.first { $0.handlesCommand(tool: tool) }
    }

    /// 读回复的统一入口:路由到对应适配器;没有匹配的工具(如还没实现的)→ 空。
    static func turnSteps(transcriptPath: String) -> [TurnStep] {
        forTranscript(transcriptPath)?.turnSteps(transcriptPath: transcriptPath) ?? []
    }
}

/// 第一个适配器:Claude Code。把原有的 TranscriptReader / ClaudeTrust 逻辑收进来,
/// 行为与之前完全一致。
struct ClaudeAgent: CodingAgent {
    let id = "claude"
    func handlesCommand(tool: String) -> Bool { tool == "claude" }
    func handlesTranscript(path: String) -> Bool { path.contains("/.claude/") }
    func turnSteps(transcriptPath: String) -> [TurnStep] {
        TranscriptReader.currentTurnSteps(transcriptPath: transcriptPath)
    }
    func preTrust(directories: [String]) {
        ClaudeTrust.trust(directories: directories)
    }
}

/// 第二个适配器:Codex。hook 已能接进 VibeNotch(~/.codex/hooks.json),
/// 会话/prompt 已显示;这里补上解析它的事件流转录拿回复。
struct CodexAgent: CodingAgent {
    let id = "codex"
    func handlesCommand(tool: String) -> Bool { tool == "codex" }
    func handlesTranscript(path: String) -> Bool { path.contains("/.codex/") }
    func turnSteps(transcriptPath: String) -> [TurnStep] {
        CodexTranscriptReader.currentTurnSteps(transcriptPath: transcriptPath)
    }
    // codex 默认在沙箱里运行,无 claude 那种文件夹信任弹窗 → 无需预置(空实现)。
}
