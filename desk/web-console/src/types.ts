export type MsgKind = 'text' | 'tool' | 'file' | 'permission'

export interface MsgImage { id: string; ext?: string }   // 通道只带 id;web 按 app://__img/<id> 取字节

export type OpKind = 'read' | 'edit' | 'write' | 'bash' | 'other'
export interface DiffLine { k: string; t: string }        // k: add | del | ctx
export interface ToolOp {                                 // 结构化动作(时间线一行)
  kind: OpKind
  file: string
  dir: string
  add?: number
  del?: number
  sameFile?: boolean
  command?: string
  diff?: DiffLine[]
  output?: string[]
  label?: string                                          // other 类工具的中文动作名
}
export interface Msg {
  id: string
  role: string          // user | assistant | system
  kind: MsgKind
  text: string
  ord: number
  images?: MsgImage[]
  permState?: string | null   // null=待处理 allow/deny=已处理
  permReqId?: string | null
  op?: ToolOp                  // kind==='tool' 时携带
  model?: string              // 产生该回合的模型(完整 id)
  ts?: number                 // 消息时间(epoch ms)
}

export interface PendingOption { id: string; label: string }
export interface Pending { id: string; title: string; detail?: string; options: PendingOption[] }

export interface Session {
  id: string
  key?: string           // 稳定 key(claude session_id),供重命名/隐藏
  title: string
  workdir: string
  agent: string          // claude | codex
  status: string         // starting|idle|working|waitingInput|needsResponse|done|error
  model?: string         // 当前模型(完整 id,如 claude-opus-4-8)
  models?: { id: string; label: string }[]   // 可切换模型(driver 动态获取,不写死)
  contextTokens?: number // 当前上下文占用 token(最新回合,覆盖刷新)
  contextWindow?: number // 当前模型上下文窗口(默认 200000)
  historyEarliest?: number
  historyHasEarlier?: boolean
  agentSessionId?: string
  startedAt?: number
  messages: Msg[]
  pending: Pending[]
}

export interface Entry { name: string; path: string; isDir: boolean }
export interface FileBody { text: string; truncated: boolean }

export interface History { id: string; key?: string; label: string; mtime: number; agent?: string }
export interface Project { workdir: string; name: string; history: History[] }

export interface Manual {
  id: string
  key?: string
  title: string
  cwd: string
  terminal: string
  agent: string         // claude | codex
  state: string         // working|waiting|done|idle
  lastActivityAt: number
  pendingPerm?: boolean  // 终端会话被 hook 扣住的权限审批(如 git push)→ 控制台显示允许/拒绝
  pendingDetail?: string // 待审批的命令/操作详情
}

export interface Conn { host: string; paired: boolean; account: string; loggedIn: boolean; state: string; text: string }
// 偏好设置(原菜单栏「设置」搬到控制台设置页):中转地址 + 开机启动 + 静音
export interface Prefs { host: string; launchAtLogin: boolean; muted: boolean }

export interface HiddenEntry { key: string; title: string }
export interface AppState {
  projects: Project[]
  sessions: Session[]
  manual: Manual[]
  hidden: HiddenEntry[]
  defaultWorkdir?: string       // 默认工作目录:新建会话建在这,其会话归默认文件夹
  defaultRoots?: string[]       // 默认目录 + 归属目录:这些根下的会话(非导入项目)归默认文件夹
  defaultSessionDirs?: string[] // 「会话归属目录」用户登记列表(设置页展示,不在项目栏成文件夹)
}

export interface UsageTotals {
  requests: number; cost: number
  input: number; output: number; tokens: number
  cacheWrite: number; cacheRead: number; cacheTokens: number
}
export interface UsageSeries { name: string; cost: number[]; token: number[]; req: number[] }
export interface UsageData {
  range: number
  totals: UsageTotals
  days: string[]          // x 轴标签(MM-DD)
  series: UsageSeries[]   // 按模型,每个 measure 一条 per-day 数组
}
