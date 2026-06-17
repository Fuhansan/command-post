import Foundation

/// 多 agent 适配器架构的**契约层**。
///
/// 设计要点(见架构稿):
/// - 上层(SessionManager / 桌面 UI / RelayAgent / 手机)**只依赖本文件**的统一模型,
///   接 claude 还是 codex 无感。
/// - 每个 agent 一个 `AgentDriver` 实现,把各自的原生协议(claude stream-json /
///   codex exec --json …)翻译成统一的 `SessionEvent` 事件流。
/// - 三类交互(发消息 / 选项卡 / 权限)在上层只剩两个动作:`send` 和 `respond`;
///   「权限」和「选项卡」合并成同一个 `PendingRequest`,机制差异下沉到各 driver。

// MARK: - 基础枚举

enum AgentKind: String, Codable {
    case claude
    case codex
}

/// 会话状态(统一)。`waitingInput` = 空闲挂起(等你输入,不催);
/// `needsResponse` = 有待响应的 PendingRequest(权限/选项,需要你拍板)。
enum SessionStatus: String, Codable {
    case starting
    case idle
    case working
    case waitingInput
    case needsResponse
    case done
    case error
}

// MARK: - 输入

/// 一条用户输入:文本 + 本地图片路径(driver 决定是 base64 内联还是路径引用)。
struct UserInput {
    var text: String
    var imagePaths: [String]
    init(text: String, imagePaths: [String] = []) {
        self.text = text
        self.imagePaths = imagePaths
    }
}

// MARK: - 待响应请求(★权限与选项卡合一)

/// 「有个东西等你拍板」—— 权限审批与选择题在上层是同一种交互。
/// driver 负责把各自的原生形式(claude tool_use(AskUserQuestion) / PreToolUse hook /
/// codex sandbox approval)翻译成它,并在 `respond` 时翻译回去。
struct PendingRequest: Identifiable, Equatable {
    enum Kind: String, Codable {
        case permission   // 工具权限审批:options 通常是 [允许, 拒绝]
        case choice       // 选择题(AskUserQuestion):options 是各选项
        case planConfirm  // 计划确认(ExitPlanMode)
    }

    struct Option: Identifiable, Equatable {
        let id: String        // 回写时用的标识(选项序号 / allow|deny)
        let label: String
        let detail: String?
    }

    let id: String            // 唯一 id(claude 用 tool_use_id;权限用一次性 id)
    let kind: Kind
    let title: String         // "审批请求" / 问题标题
    let detail: String?       // 命令详情 / 问题描述
    let options: [Option]
    let multiSelect: Bool
}

// MARK: - 事件(driver → 上层的唯一出口)

struct ToolCallInfo: Equatable {
    let id: String
    let name: String          // Bash / Read / Edit …
    let summary: String       // 命令 / 路径等一句话摘要
}

struct FileEditInfo: Equatable {
    let path: String
    let additions: Int        // +N 行(hunks 细节后续补)
}

/// driver 把原生协议翻译成的统一事件。上层据此增量更新会话模型。
enum SessionEvent {
    case status(SessionStatus)
    case sessionId(String)                                  // 供 --resume
    case messageDelta(msgId: String, role: String, text: String)  // AI 文本(可流式拼接)
    case messageComplete(msgId: String)
    case toolCall(ToolCallInfo)                             // 工具调用展示
    case fileEdit(FileEditInfo)                             // 文件改动卡
    case pendingRequest(PendingRequest)                    // 待你响应(权限/选项)
    case pendingResolved(id: String)                       // 该待决项已回答/超时
    case turnComplete(result: String?)
    case error(String)
}

// MARK: - 能力声明(★诚实面对 claude/codex 不对等)

/// 各 agent 能力不同,显式声明,上层据此决定 UI,不假装一致。
struct AgentCapabilities {
    enum Permission: String {
        case hook       // claude:PreToolUse hook 阻塞审批(Path A)
        case sandbox    // codex:沙箱 + approval
        case none       // 不支持程序化拦截
    }
    var nativeChoice: Bool        // 选项卡是否原生(claude tool_use)
    var permission: Permission
    var multimodalInput: Bool     // 图片能否喂入
    var resume: Bool
}

// MARK: - 适配器协议

/// 驱动一个 agent 会话。每个 agent(claude/codex…)一个实现。
protocol AgentDriver: AnyObject {
    var kind: AgentKind { get }
    var capabilities: AgentCapabilities { get }
    /// agent 报告的会话 id(供 resume);未知时为 nil。
    var sessionId: String? { get }
    /// 统一事件流 —— 上层唯一消费点。driver 是事件源,天然解耦,一个崩了不连累别的会话。
    var events: AsyncStream<SessionEvent> { get }

    /// 启动会话(在 workdir 起子进程;resume 非空则恢复既有会话)。
    func start(workdir: String, resume: String?) async throws
    /// 发用户输入(文本 + 图片)。
    func send(_ input: UserInput)
    /// 回答一个待决项(权限放行/拒绝、或选择题选项)。optionIds 取自 PendingRequest.options。
    func respond(to requestId: String, choose optionIds: [String])
    /// 中断当前轮(Ctrl+C)。
    func interrupt()
    /// 结束会话(杀子进程)。
    func stop()
}
