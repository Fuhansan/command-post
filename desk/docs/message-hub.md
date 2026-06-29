# ConversationHub —— 消息枢纽设计 (v2)

> 状态:设计已定稿,准备实施。范围=桌面端 VibeNotch 内部。
> 目标读者:维护 RelayAgent / WebConsoleBridge / 会话渲染的人。

## 0. 一句话

两个**源**(hook 终端会话 = `SessionStore`,console 会话 = `AgentSessionManager`)经一个**双向枢纽**规范化成**一份标准会话模型 + 一套稳定身份**;所有**出口**(iOS 的 `ui` 帧 / Web 的本地桥 / 刘海 SwiftUI)只做**渲染 + 传输去重**,不再各自推导;所有**入口命令**(输入/中断/审批/答题)经枢纽**统一路由**回正确的源。

---

## 1. 背景:今天的分叉(为什么要做)

同一条会话,每个出口各自从源 store 重新推导消息,各写一套 dedup / 排序 / 噪音过滤 / 历史窗口:

| 出口 | 下行(消息推导) | 上行(命令路由) |
|---|---|---|
| RelayAgent → iOS | `hookHistory`(93)+`buildMessages`(688)+`consoleMessages`(526),共 ~16 处 | `input`/`action`/`pause`/`resume`,审批走 `pending.decisionEvents`,console 走 `agentManager.respond*` |
| WebConsoleBridge → Web | `manualDTO`/`sessionDTO` + 一次性 `loadTranscript`(`parseTranscriptWindow`) | `send`/`interrupt`/`respond`/`closeSession`/… |
| NotchViews → 刘海 | 直接读 `store.sessions`/`s.state`/`s.messages` | —— |

**已知由此产生的 bug(都是同一病根):**
- hook 会话正文在 Web 控制台**冻结**(只 `loadTranscript` 一次,不随活动刷新)。iOS 不冻结(RelayAgent 随 store 变化重推)。
- 用户消息一度**沉底**(`liveOrd` 首次出现序 vs 位置序不一致)。
- 隐藏名单**错杀**活会话、manual/console **去重错位** —— 都是会话身份不统一。

**规范化原料已经是 static、可复用(不用重写,搬进枢纽即可):**
`parseTranscriptWindow` / `parseTranscriptFile`(claude 一份在 `AgentSessionManager`、codex 一份在 `CodexTranscriptReader`)、`CodingAgent.turnSteps`、`isNoisyTool`、`isSystemInjected`。

---

## 2. 目标 / 非目标

**目标**
1. **单一身份**:会话 id、消息 id、轮次/ord 由枢纽定义一次,全端一致。
2. **单一下行模型**:噪音过滤、历史窗口、ord/turn、待批准卡只算一次。
3. **单一上行路由**:会话内容命令(输入/中断/审批/答题)统一 `dispatch`。
4. **出口变薄**:只渲染 + per-client 传输去重,不含推导。
5. **修复**:hook 会话 Web 实时化(顺带,见 P2)。

**非目标(明确不做)**
- 不做跨设备聚合(那是服务器按账户维度 MQ 的事,枢纽只管本机会话)。
- 不改 iOS `ComponentView` / Web `MsgList` 的**渲染**。
- 不改 console 的**逐 token 流式**来源(stdout 流照旧)。
- 视图/桌面命令(`raiseWindow`/`hide`/`theme`/项目管理/auth)**不进枢纽**,留在各 bridge。

---

## 3. 标准模型(枢纽内,全端唯一)

```swift
struct Conversation {
    let id: ConvID                 // 规范会话身份(见 §4)
    let source: Source             // .terminal(hook) | .console
    let cwd: String
    let agent: Agent               // .claude | .codex
    var state: SessionState        // .working/.waiting/.done/.idle(沿用现有枚举)
    var turn: Int
    var hasMore: Bool              // 历史还能往前翻(分页用)
    var messages: [ConvMessage]    // 已规范化、已过滤、已排好 ord(全量,不分窗)
}

struct ConvMessage {
    let id: ConvMsgID              // 稳定消息身份(见 §4)
    let ord: Int                   // 全局逻辑序:历史取负、当前轮 = turn*1000 + 轮内位置
    let role: Role                 // .user | .agent
    let kind: Kind                 // .text | .tool | .file | .permission | .ask | .bubble | .status
    var text: String              // 可变(流式时同 id 内容增长)
    var op: ToolOp?               // 结构化动作(diff/目录/命令)
    var images: [ImageRef]?       // 只放 image id,绝不内联字节(§10.1)
    var model: String?
    var pending: PendingState?     // 待批准/待答题的决策态(见 §9)
    var ts: Date?
}
```

> 渲染差异留在出口:iOS 把 `ConvMessage` 渲成组件树帧;Web 渲成 `transcript` JSON;刘海渲成 SwiftUI。**模型只描述"是什么",不描述"长什么样"。**

---

## 4. 身份层(一等目标)

枢纽定义**唯一**的 id 方案,取代现在的 `"c:"`/`"m:sid:t.."`/`"m:sid:h.."`/`agentSessionId`/内部 id 混用:

- **ConvID(会话)**:`{ source, key }`。
  - `.terminal` → key = claude/codex `session_id`(转录文件名)。
  - `.console` → key = `agentSessionId`(没有则内部 id),对外**不再手工加 `"c:"` 前缀**,前缀仅在需要时由出口在自己的传输层加。
- **ConvMsgID(消息)**:`{ convID, slot }`,`slot` 取值:
  - `t<turn>:<位置>` 当前/历史轮消息;
  - `h<idx>` 历史回填(枢纽内统一成负 ord,不再各出口各算)。
- **稳定性约定**:同一条逻辑消息,无论谁在看、看几次、流式更新多少次,`ConvMsgID` 不变 → 出口可安全做"同 id 替换"。

> 隐藏名单、去重、补发**全部以 ConvID/ConvMsgID 为准**,从根上消除之前的错杀/错位。

---

## 5. 架构总览

```
   源(响应式)                 枢纽(派生投影 + 路由)                出口(薄渲染)
 ┌──────────────┐                                              ┌────────────────────┐
 │ SessionStore │─┐        ┌──────────────────────────┐    ┌──▶│ RelayAgent → iOS    │
 │  (terminal)  │ │  订阅   │  ConversationHub          │ 增量│   (ui 帧 + per-client│
 └──────────────┘ ├───────▶│  - 规范化(过滤/ord/窗口) │────┤   传输去重)          │
 ┌──────────────┐ │        │  - @Published conv + delta│    └────────────────────┘
 │ AgentSession │ │        │  - dispatch(command)      │    ┌────────────────────┐
 │  Manager     │─┘        │      ↑ 上行路由            │◀───│ WebConsoleBridge→Web│
 │  (console)   │          └──────────┬───────────────┘ 命令│   (transcript JSON) │
 └──────────────┘                     │                     └────────────────────┘
        ▲                             │ 路由回源                ┌────────────────────┐
        └─────────────────────────────┘                        │ NotchViews(可选)  │
            input/interrupt/审批/答题                            └────────────────────┘
```

**关键约束 §5.1 —— 枢纽是"派生投影",不是第三个 store。**
枢纽**不独立 mutate** 会话状态;它对两个源 store 做响应式投影 + 缓存。源变 → 枢纽重算(增量)→ 发 delta。绝不出现"枢纽里的状态和源 store 漂移"。上行命令也不直接改枢纽,而是路由回**源**,源变了再反映到枢纽。

---

## 6. 下行:增量协议(snapshot + delta)

枢纽对每个会话维护规范化全量,对外发**增量**(不是每次全量重推):

```swift
enum ConvDelta {
    case upsertConversation(Conversation)        // 新会话/元数据(state/turn/hasMore)变化
    case removeConversation(ConvID)
    case upsertMessage(ConvID, ConvMessage)       // 新增或同 id 内容更新(流式)
    case removeMessage(ConvID, ConvMsgID)         // 当前轮消失(被中断/待批准已处理)
}
```

- 出口订阅 delta 流。**首次/重连**:出口向枢纽要一次 `snapshot()`(全量),之后吃增量。
- **per-client 已发去重留在出口**(不同客户端连接时机不同):RelayAgent 现有 `lastSent[id]=sig`、WebConsoleBridge 现有 `lastManualSig` 继续在各自边缘做"我给这个连接发到哪了"。
- 枢纽发 delta 只代表"数据变了",**不假设任何一个客户端的已发状态**。

---

## 7. 上行:命令路由(限会话内容命令)

```swift
enum ConvCommand {
    case input(ConvID, text: String, images: [ImageRef])
    case interrupt(ConvID)
    case decidePermission(ConvID, msgId: ConvMsgID, allow: Bool)
    case answerChoice(ConvID, msgId: ConvMsgID, optionIndex: Int)
}
func dispatch(_ cmd: ConvCommand)
```

枢纽按 `ConvID.source` 路由到源适配器:
- `.terminal` → 现有路径:放行 hook / 按键注入(`AppDelegate.decide` / TerminalTyper)。
- `.console` → `AgentSessionManager.respond*` / `sendInput` / `interrupt`。

**边界(明确不进枢纽,留在各 bridge):**
会话生命周期(`newSession`/`closeSession`/`resume`/`switchModel`/`rename`)、视图/桌面(`raiseWindow`/`hide`/`unhide`/`theme`/`setHost`)、项目管理、auth。这些不是"会话内容",硬塞进枢纽只会让它臃肿。

> 收益:消除"手机能停、网页停不了"这类上行不一致;审批/答题决策**任意客户端**触发都走同一路由 + 同一身份。

---

## 8. 窗口与分页(留在出口边缘)

- 枢纽持有**全量**规范化消息(历史按需扩展窗口的能力在枢纽:`loadEarlier(ConvID, before:)`)。
- 但**"当前展示窗口大小 / 滚动位置 / 已加载到哪"是 per-client 的**(iOS 与 Web 各不相同),留在出口:RelayAgent `hookWindow`/`consoleWindow`、Web 前端自己的分页 cursor。
- `hasMore` 由枢纽算并放进 `Conversation`,出口据此显示"加载更早"。

---

## 9. 权限 / 待答题生命周期(复杂度最高点)

权限卡(Allow/Deny)、AskUserQuestion/ExitPlanMode 是**交互 + 有时效(hook 超时)+ 任意客户端可决策**的特殊消息:

- 建模为 `ConvMessage.kind = .permission/.ask`,`pending: PendingState`(`.awaiting` / `.decided(allow/deny/option)` / `.timeout` / `.expired`)。
- **决策来源多元**:手机点、网页点、终端里本地选、hook 超时自动放行 —— 全部经 `dispatch(decidePermission/answerChoice)` 收敛,枢纽更新源(`PendingDecisionStore` / `agentManager`)→ 投影出 `.decided` → delta 给所有客户端(其它端的卡同步变成"已允许/已拒绝")。
- 这块在 P 阶段**单独拎出来**做、单独测,不和普通文本消息混。

---

## 10. 约束与边界

1. **图片只传 id**:`ConvMessage.images` 只放 image id;字节由出口经 HTTP(`ImageRelay`)各自拉。枢纽**绝不内联 base64**(项目铁律)。
2. **claude/codex 差异下沉**:两套转录解析留在 agent 适配器(`CodingAgent`/`CodexTranscriptReader`)喂枢纽;枢纽以上**与 agent 无关**。
3. **重连/补发三层记忆**:枢纽(桌面派生)+ 服务器 `Hub.java` snapshot(离线补发)+ 客户端本地。约定:枢纽对**本机出口**补发(snapshot);服务器对**跨网络重连/离线**补发;客户端只展示。三层不互相猜测对方状态。
4. **桌面本机范围**:枢纽只管这台 Mac 的会话。跨设备是服务器账户维度的事。
5. **术语统一**:源类型统一叫 `terminal`(=hook)与 `console`;代码/注释/协议字段不再混用 manual/hook/terminal/console。

---

## 11. 优化

- **增量重算**:store 一轮变很多次。历史用缓存(现有 `hookHistoryCache`),**只重算当前轮(尾部)**;按 ConvID dirty 标记;runloop 合并多次变更再发一批 delta。
- **解析放主线程外**:转录解析保持 `nonisolated static`,算完再跳主线程 publish,别卡刘海动画。
- **delta 而非全量**:出口少各自 diff;但 per-client 已发去重仍在边缘(§6)。

---

## 12. 验证夹具(给重构兜底)

为保证迁移"行为不变",先搭**golden 帧对比**:
- 录一个真实会话(hook + console 各一)的当前出口产物:RelayAgent 的 `ui` 帧序列、WebConsoleBridge 的 `transcript`/`manualUpsert` 序列。
- 迁移后用枢纽产出,**逐条 diff**(id / ord / body / fallback)。P1 的验收 = iOS 帧**逐字段一致**。
- 之所以先搭:历史上被"重构回退"坑过,这个夹具让每个 P 阶段都能客观判定"没回退"。

---

## 13. 迁移分期(每步可验、不大爆炸)

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P1** | 建 `ConversationHub` + 标准模型 + 身份层;把 RelayAgent 的 **hook 推导**(`hookHistory`+`buildMessages`)**搬进**枢纽(搬不重写);RelayAgent 改读枢纽 delta。搭 §12 夹具。 | iOS 上 hook 会话 ui 帧**逐字段不变**(golden diff 通过);手机端表现零变化。 |
| **P2** | WebConsoleBridge 的 hook 内容改读枢纽、随 delta 推。 | **Web 控制台 hook 会话实时**(原 bug 修复);与 iOS 同源;①console②历史/样式不变。 |
| **P3** | console 源(`consoleMessages`/`sessionDTO`)也搬进枢纽。 | console 会话两端同源;**逐 token 流式保住**。 |
| **P3.5** | 上行 `dispatch` 收敛(input/interrupt/审批/答题);权限生命周期(§9)。 | 手机/网页/终端三处决策一致;无"能停/停不了"分叉。 |
| **P4(可选)** | NotchViews 读枢纽。 | 刘海摘要不变。 |

> 想稳:做到 **P2** 就已经"bug 修了 + 枢纽地基立了",P3 起按需推进。

---

## 14. 文件改动地图(预估)

- **新增** `VibeNotch/ConversationHub.swift`:模型 + 身份 + 投影 + delta + dispatch。
- **新增** `VibeNotch/ConversationModel.swift`:`Conversation`/`ConvMessage`/`ConvID`/`ConvMsgID`/`ConvDelta`/`ConvCommand`。
- **改** `RelayAgent.swift`:`hookHistory`/`buildMessages` 逻辑搬走;改为订阅枢纽 delta → 渲染 ui 帧;保留 `seq`/`lastSent` 传输层。
- **改** `WebConsoleBridge.swift`(P2):hook 内容改读枢纽随推;保留 `loadTranscript` 仅供②历史。
- **复用不动**:`parseTranscriptWindow`/`parseTranscriptFile`/`turnSteps`/`isNoisyTool`/`isSystemInjected`(被枢纽调用)。
- **新增(测试)** golden 夹具脚本/录制样本。
