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

export interface History { id: string; label: string; mtime: number }
export interface Project { workdir: string; name: string; history: History[] }

export interface Manual {
  id: string
  title: string
  cwd: string
  terminal: string
  agent: string         // claude | codex(hook 会话目前都是 claude)
  state: string         // working|waiting|done|idle
  lastActivityAt: number
}

export interface AppState {
  projects: Project[]
  sessions: Session[]
  manual: Manual[]
}

export interface UsageTotals {
  input: number; output: number; cacheRead: number; cacheCreation: number
  tokens: number; requests: number; cost: number; cacheHit: number
}
export interface UsageModel { name: string; tokens: number; requests: number; cost: number }
export interface UsageData {
  days: number
  totals: UsageTotals
  daily: { day: string; tokens: number }[]
  models: UsageModel[]
}
