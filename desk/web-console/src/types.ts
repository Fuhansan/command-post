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
  agentSessionId?: string
  startedAt?: number
  messages: Msg[]
  pending: Pending[]
}

export interface History { id: string; label: string; mtime: number }
export interface Project { workdir: string; name: string; history: History[] }

export interface Manual {
  id: string
  title: string
  cwd: string
  terminal: string
  state: string         // working|waiting|done|idle
  lastActivityAt: number
}

export interface AppState {
  projects: Project[]
  sessions: Session[]
  manual: Manual[]
}
