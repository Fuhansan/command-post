export type MsgKind = 'text' | 'tool' | 'file' | 'permission'

export interface Msg {
  id: string
  role: string          // user | assistant | system
  kind: MsgKind
  text: string
  ord: number
  permState?: string | null   // null=待处理 allow/deny=已处理
  permReqId?: string | null
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
  agentSessionId?: string
  startedAt?: number
  messages: Msg[]
  pending: Pending[]
}

export interface Entry { name: string; path: string; isDir: boolean }
export interface FileBody { text: string; truncated: boolean }

export interface History { id: string; key?: string; label: string; mtime: number }
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
}

export interface PairState { phase: 'idle' | 'fetching' | 'waiting' | 'done' | 'failed'; code?: string; account?: string; error?: string }
export interface Conn { host: string; paired: boolean; account: string; state: string; text: string; pair: PairState }

export interface HiddenEntry { key: string; title: string }
export interface AppState {
  projects: Project[]
  sessions: Session[]
  manual: Manual[]
  hidden: HiddenEntry[]
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
