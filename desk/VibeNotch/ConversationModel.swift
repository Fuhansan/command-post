import Foundation

// ConversationHub 的标准会话模型 + 身份层(见 docs/message-hub.md v2 §3、§4)。
// 纯值类型,不含渲染、不含副作用。出口(RelayAgent / WebConsoleBridge / 刘海)各自把这些
// 渲染成自己的形态(ui 帧 / transcript JSON / SwiftUI);模型只描述「是什么」,不描述「长什么样」。

/// 会话来源。统一术语:terminal = 前台终端 hook 会话;console = VibeNotch 自己 spawn 的 stream-json 会话。
enum ConvSource: String, Equatable, Codable {
    case terminal   // 旧称 hook / manual
    case console
}

enum ConvAgent: String, Equatable, Codable {
    case claude
    case codex
}

enum ConvRole: String, Equatable, Codable {
    case user
    case agent
}

/// 消息语义类型(与渲染无关)。
enum ConvMsgKind: String, Equatable, Codable {
    case text          // 一段(可 markdown)文本
    case tool          // 结构化工具动作(读取/编辑/命令…)→ 见 op
    case file          // 文件编辑(历史里 codex 的简化形态)
    case permission    // 待批准/已决定卡 → 见 pending
    case ask           // TUI 选择题(AskUserQuestion / ExitPlanMode)→ 见 pending
    case bubble        // 普通气泡(waiting 提示 / 就绪占位 等)
    case photo         // 图片 + 说明(用户 prompt 带图)→ 见 images
}

// MARK: - 身份层(§4):全端唯一的会话 id / 消息 id

/// 规范会话身份。`key`:terminal=claude/codex session_id(转录文件名);console=agentSessionId 或内部 id。
struct ConvID: Hashable, Codable {
    let source: ConvSource
    let key: String
    /// 稳定字符串形态(日志/字典键用)。前缀仅标明来源,出口若要自己的传输前缀自行再加。
    var stable: String { "\(source.rawValue):\(key)" }
}

/// 规范消息身份。`slot` 取值:`t<turn>:<位置>`(当前/某轮)或 `h<idx>`(历史回填)。
/// 同一条逻辑消息无论谁看、看几次、流式更新多少次,id 不变 → 出口可安全做「同 id 替换」。
struct ConvMsgID: Hashable, Codable {
    let conv: ConvID
    let slot: String
    var stable: String { "m:\(conv.key):\(slot)" }
}

/// 图片引用 —— 只带 id/元信息,绝不内联字节(项目铁律,§10.1)。字节由出口经 HTTP 各自拉。
struct ConvImageRef: Equatable, Codable {
    let id: String
    var name: String? = nil
    var kind: String? = nil   // 扩展名(PNG/JPG…)
    var size: String? = nil   // 人类可读大小
}

/// 待决策态(权限卡 / 选择题)。决策可来自手机/网页/终端/超时,统一收敛到这里(§9)。
enum ConvPending: Equatable, Codable {
    case awaiting                 // 等待决策
    case decided(String)          // allow / deny / 已选项 label
    case timeout                  // hook 超时按默认放行
    case expired                  // 连接丢弃/会话结束,卡作废
}

// MARK: - 标准消息 / 会话(§3)

struct ConvMessage: Equatable {
    let id: ConvMsgID
    /// 全局逻辑序:历史取负、当前轮 = turn*1000 + 轮内位置。出口按此排序,不受到达时序影响。
    var ord: Int
    var role: ConvRole
    var kind: ConvMsgKind
    var text: String = ""
    var op: ToolOp? = nil
    var images: [ConvImageRef]? = nil
    var model: String? = nil
    var pending: ConvPending? = nil
    var ts: Date? = nil
    /// 出口降级展示用的纯文本(通知/折叠态)。
    var fallback: String = ""
}

struct Conversation: Equatable {
    let id: ConvID
    let source: ConvSource
    var cwd: String
    var agent: ConvAgent
    var state: SessionState
    var turn: Int
    var hasMore: Bool             // 历史还能往前翻(分页)
    var messages: [ConvMessage]   // 已规范化、已过滤、已排好 ord 的全量(不分窗;窗口在出口边缘,§8)
}

// MARK: - 下行增量协议(§6)

/// 枢纽对外只发增量;首次/重连由出口主动要一次全量 snapshot。
enum ConvDelta: Equatable {
    case upsertConversation(Conversation)        // 新会话 / 元数据(state/turn/hasMore)变化
    case removeConversation(ConvID)
    case upsertMessage(ConvID, ConvMessage)       // 新增,或同 id 内容更新(流式)
    case removeMessage(ConvID, ConvMsgID)         // 当前轮某条消失(被中断 / 待批准已处理)
}

// MARK: - 上行命令(§7,仅「会话内容」命令;视图/桌面/auth 不进枢纽)

enum ConvCommand: Equatable {
    case input(ConvID, text: String, images: [ConvImageRef])
    case interrupt(ConvID)
    case decidePermission(ConvMsgID, allow: Bool)
    case answerChoice(ConvMsgID, optionIndex: Int)
}
