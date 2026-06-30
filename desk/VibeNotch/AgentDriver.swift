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
    var op: ToolOp? = nil     // 结构化动作(供 web 时间线渲染:读取/编辑/新建/命令)
}

/// 一条 diff 行(编辑动作展开时用)。kind: add / del / ctx。
struct DiffLine: Equatable { let kind: String; let text: String }

/// 结构化动作(对应设计稿「动作时间线」一行)。颜色/图标由前端按 kind 映射。
struct ToolOp: Equatable {
    enum Kind: String { case read, edit, write, bash, other }
    var kind: Kind
    var file: String = ""           // 文件名(basename)
    var dir: String = ""            // 展示目录(相对工作目录)
    var add: Int? = nil             // +N
    var del: Int? = nil             // −N
    var sameFile: Bool = false      // 与上一条同文件(展示「同一文件」)
    var command: String? = nil      // bash 命令
    var diff: [DiffLine] = []       // 编辑动作的 diff(可展开)
    var output: [String] = []       // bash 输出(tool_result 回填,可展开)
    var label: String? = nil        // other 类工具的中文动作名(搜索/获取/任务…)
}

/// 行级 LCS diff:返回带 add/del/ctx 标记的行 + 增删计数。供编辑动作算 +N/−N 与展开 diff。
/// 体量过大(行数乘积超阈值)时退化为「全删旧+全增新」,只给计数不给逐行,避免卡 UI。
func lineDiff(_ oldS: String, _ newS: String) -> (lines: [DiffLine], add: Int, del: Int) {
    let a = oldS.isEmpty ? [] : oldS.components(separatedBy: "\n")
    let b = newS.isEmpty ? [] : newS.components(separatedBy: "\n")
    let n = a.count, m = b.count
    if n == 0 && m == 0 { return ([], 0, 0) }
    if n * m > 250_000 {   // 退化:不做逐行 LCS
        var lines = a.map { DiffLine(kind: "del", text: $0) }
        lines += b.map { DiffLine(kind: "add", text: $0) }
        return (lines, b.count, a.count)
    }
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
    }
    var lines: [DiffLine] = []; var add = 0, del = 0; var i = 0, j = 0
    while i < n && j < m {
        if a[i] == b[j] { lines.append(DiffLine(kind: "ctx", text: a[i])); i += 1; j += 1 }
        else if dp[i + 1][j] >= dp[i][j + 1] { lines.append(DiffLine(kind: "del", text: a[i])); del += 1; i += 1 }
        else { lines.append(DiffLine(kind: "add", text: b[j])); add += 1; j += 1 }
    }
    while i < n { lines.append(DiffLine(kind: "del", text: a[i])); del += 1; i += 1 }
    while j < m { lines.append(DiffLine(kind: "add", text: b[j])); add += 1; j += 1 }
    return (lines, add, del)
}

/// 文件目录,尽量相对工作目录展示(如 ai-coding-remote/src/api);不在其下则取末两级。
func relDir(_ path: String, workdir: String) -> String {
    guard !path.isEmpty else { return "" }
    let parent = (path as NSString).deletingLastPathComponent
    if !workdir.isEmpty, parent == workdir || parent.hasPrefix(workdir + "/") {
        let base = (workdir as NSString).lastPathComponent
        let rel = String(parent.dropFirst(workdir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? base : base + "/" + rel
    }
    let comps = parent.components(separatedBy: "/").filter { !$0.isEmpty }
    return comps.suffix(2).joined(separator: "/")
}

/// 非读写/命令类工具的中文动作名(other)。
func otherToolLabel(_ name: String) -> String {
    switch name {
    case "Grep", "Glob": return "搜索"
    case "WebFetch": return "获取"
    case "WebSearch": return "联网"
    case "Task": return "任务"
    default: return name
    }
}

/// 从 claude 工具名 + input 构造结构化动作。driver(实时)与转录解析共用,保证两条链路一致。
/// 返回 nil 表示该工具不展示为动作(交互/计划类由别处处理)。
func claudeToolOp(name: String, input: [String: Any], workdir: String) -> ToolOp? {
    let fileOf: (String) -> String = { $0.isEmpty ? "" : ($0 as NSString).lastPathComponent }
    switch name {
    case "Read", "NotebookRead":
        let p = (input["file_path"] ?? input["notebook_path"]) as? String ?? ""
        var op = ToolOp(kind: .read); op.file = fileOf(p); op.dir = relDir(p, workdir: workdir); return op
    case "Edit", "MultiEdit", "NotebookEdit", "Write", "Create":
        let p = (input["file_path"] ?? input["notebook_path"]) as? String ?? ""
        let isNew = (name == "Write" || name == "Create")
        var op = ToolOp(kind: isNew ? .write : .edit); op.file = fileOf(p); op.dir = relDir(p, workdir: workdir)
        if isNew {
            let r = lineDiff("", input["content"] as? String ?? ""); op.add = r.add; op.del = 0; op.diff = r.lines
        } else if name == "MultiEdit", let edits = input["edits"] as? [[String: Any]] {
            var add = 0, del = 0; var diff: [DiffLine] = []
            for e in edits { let r = lineDiff(e["old_string"] as? String ?? "", e["new_string"] as? String ?? ""); add += r.add; del += r.del; diff += r.lines }
            op.add = add; op.del = del; op.diff = diff
        } else {
            let r = lineDiff(input["old_string"] as? String ?? "", input["new_string"] as? String ?? ""); op.add = r.add; op.del = r.del; op.diff = r.lines
        }
        return op
    case "Bash":
        let cmd = input["command"] as? String ?? ""
        var op = ToolOp(kind: .bash); op.command = cmd
        op.file = cmd.split(separator: " ").first.map(String.init) ?? "bash"
        op.dir = workdir.isEmpty ? "" : (workdir as NSString).lastPathComponent
        return op
    default:
        let summary = (input["file_path"] ?? input["path"] ?? input["command"]
                       ?? input["pattern"] ?? input["url"] ?? input["prompt"] ?? input["query"]) as? String ?? ""
        var op = ToolOp(kind: .other); op.label = otherToolLabel(name); op.file = summary; return op
    }
}

struct FileEditInfo: Equatable {
    let path: String
    let additions: Int        // +N 行(hunks 细节后续补)
}

/// 一个可切换的模型。`id` 是切换时传给 agent 的值(claude 用稳定别名 opus/sonnet/haiku;
/// codex 用 model/list 返回的真实 slug);`label` 是展示名。动态获取,避免写死随版本过时。
struct AgentModel: Equatable {
    let id: String
    let label: String
    var contextWindow: Int = 200_000   // 上下文窗口 token(标称;claude 4.x 均 200K)。挂在模型上,换模型自动跟着变。
}

/// driver 把原生协议翻译成的统一事件。上层据此增量更新会话模型。
enum SessionEvent {
    case status(SessionStatus)
    case sessionId(String)                                  // 供 --resume
    case model(String)                                      // 当前模型(从流里读到)
    case availableModels([AgentModel])                      // 可切换模型列表(动态获取)
    case usage(contextTokens: Int, contextWindow: Int?)      // 当前上下文占用(最新回合 prompt 侧),覆盖不累加;Codex 可同时回窗口
    case messageDelta(msgId: String, role: String, text: String)  // AI 文本(可流式拼接)
    case messageComplete(msgId: String)
    case toolCall(ToolCallInfo)                             // 工具调用展示
    case toolOutput(id: String, lines: [String])           // 工具结果回填(bash 输出,按 tool_use_id 配对)
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
    /// 子进程 pid —— 用于把外部 hook 事件(按 _ppid 父链)关联回本会话(Path A 权限通道)。
    var ownerPID: pid_t? { get }
    /// 注入一个权限审批请求(claude:由 PreToolUse hook 路由进来)。driver 据此发出
    /// `pendingRequest(.permission)`,并在 `respond` 时调用 `decide` 写回 allow/deny 解除阻塞。
    func injectPermission(toolName: String, detail: String, decide: @escaping (PermissionDecision) -> Void)
    /// 统一事件流 —— 上层唯一消费点。driver 是事件源,天然解耦,一个崩了不连累别的会话。
    var events: AsyncStream<SessionEvent> { get }

    /// 启动会话。resume 非空 → 恢复指定会话(--resume);continueLast → 继续该目录最近会话(--continue)。
    /// model 非空 → 指定模型(--model,如 opus/sonnet/haiku)。
    func start(workdir: String, resume: String?, continueLast: Bool, model: String?) async throws
    /// 发用户输入(文本 + 图片)。
    func send(_ input: UserInput)
    /// 回答一个待决项(权限放行/拒绝、或选择题选项)。optionIds 取自 PendingRequest.options。
    /// 返回 false 表示 driver 已经没有这个待决项,上层不能把 UI 乐观标记为已处理。
    @discardableResult
    func respond(to requestId: String, choose optionIds: [String]) -> Bool
    /// 中断当前轮(Ctrl+C)。
    func interrupt()
    /// 结束会话(杀子进程)。
    func stop()
}

extension AgentDriver {
    /// 默认:不支持权限注入的 driver 兜底拒绝(避免 hook 永久阻塞)。
    func injectPermission(toolName: String, detail: String, decide: @escaping (PermissionDecision) -> Void) {
        decide(.deny)
    }
}
