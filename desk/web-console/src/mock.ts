// 前端 mock:后端(VibeNotch Swift 桥)暂无 git/worktree 与多 Provider 能力,
// 这里按设计稿造演示数据撑起 UI。等后端补能力后,把 mockGit / PROVIDERS 换成真实推送即可。
import type { Project } from './types'

export type GitStatus = 'running' | 'done' | 'manual'
export interface GitBranch {
  name: string
  ahead: number
  behind: number
  current?: boolean
  session: string   // 该分支对应的 worktree 会话描述
  status: GitStatus
}
export interface GitInfo {
  initialized: boolean
  branch: string    // 当前分支
  dirty: number     // 未提交更改数(staged + unstaged)
  branches: GitBranch[]
}

// 用 workdir 派生稳定的伪随机,保证每个项目的 mock 始终一致
function hash(s: string): number {
  let h = 0
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0
  return Math.abs(h)
}

const FEATS = ['feat/redis-cache', 'fix/login-timeout', 'refactor/auth', 'feat/ui-redesign', 'chore/deps']
const SESSION_DESC: Record<GitStatus, string> = {
  running: '优化代码性能并添加缓存',
  manual: '待确认的变更',
  done: '主干 · 已完成',
}

export function mockGit(p: Project): GitInfo {
  const h = hash(p.workdir)
  // 约 1/6 的项目当作未初始化 git —— 撑起「无 Git」+ git init 引导流程
  if (h % 6 === 0) return { initialized: false, branch: '', dirty: 0, branches: [] }
  const f1 = FEATS[h % FEATS.length]
  const f2 = FEATS[(h >> 4) % FEATS.length]
  const branches: GitBranch[] = [
    { name: 'main', ahead: 0, behind: 0, session: SESSION_DESC.done, status: 'done' },
    { name: f1, ahead: 2 + (h % 3), behind: 0, current: true, session: SESSION_DESC.running, status: 'running' },
  ]
  if (f2 !== f1) branches.push({ name: f2, ahead: 1, behind: h % 2, session: SESSION_DESC.manual, status: 'manual' })
  return { initialized: true, branch: f1, dirty: 1 + (h % 5), branches }
}

export interface Provider {
  id: string
  name: string
  vendor: string
  initial: string
  iconBg: string
  iconFg: string
  online: boolean
  key: string
  models: string[]
}
// Claude 与 Codex 已经通过 VibeNotch 接入;其余仍是设计稿里的「规划中」占位。
export const PROVIDERS: Provider[] = [
  { id: 'claude', name: 'Claude', vendor: 'Anthropic · 经 VibeNotch', initial: 'C', iconBg: '#ece6dd', iconFg: '#b8612d', online: true, key: 'sk-ant-•••••3f2a', models: ['Opus 4.8', 'Sonnet 4.6', 'Haiku 4.5'] },
  { id: 'codex', name: 'Codex', vendor: 'OpenAI · 经 VibeNotch', initial: 'O', iconBg: '#dce9e3', iconFg: '#1a7d5a', online: true, key: 'sk-•••••9b1c', models: ['GPT-5 Codex', 'GPT-5'] },
  { id: 'local', name: 'Local', vendor: 'Ollama · 本地', initial: 'L', iconBg: '#e3e3ec', iconFg: '#5562c9', online: false, key: '—', models: ['llama3.1', 'qwen2.5-coder'] },
]
